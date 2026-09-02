#include "s3_ota_shim.h"
#include "s3_ota_protocol.h"
#include "espnow_stack.h"
#include "c6_espnow_proto.h"
#include "storage_shim.h"

#include <dirent.h>
#include <stdio.h>
#include <stdlib.h>
#include <strings.h>
#include <string.h>
#include <sys/stat.h>

#include "esp_app_desc.h"
#include "esp_app_format.h"
#include "esp_crc.h"
#include "esp_log.h"
#include "esp_random.h"
#include "freertos/FreeRTOS.h"
#include "freertos/portmacro.h"
#include "freertos/semphr.h"
#include "freertos/task.h"

#define OTA_USB_ROOT "/usb"
#define OTA_MAX_IMAGE_SIZE (3U * 1024U * 1024U)
#define OTA_REPLY_TIMEOUT_MS 2500U
#define OTA_DATA_RETRIES 3

static modulus_s3_ota_snapshot_t s_state = {
    .phase = MODULUS_S3_OTA_IDLE,
    .status = "Open this page to scan for ESP32-S3 app images. Nothing flashes automatically.",
};
static portMUX_TYPE s_lock = portMUX_INITIALIZER_UNLOCKED;
static SemaphoreHandle_t s_reply_sem;
static mod_s3_ota_packet_t s_reply_packet;
static uint8_t s_wait_command;
static uint32_t s_wait_session;
static uint32_t s_wait_sequence;
static bool s_worker_running;
static bool s_registered;
static char s_armed_path[192];
static size_t s_armed_size;
static char s_file_paths[MODULUS_S3_OTA_MAX_FILES][192];

static void state_status(modulus_s3_ota_phase_t phase, const char *text)
{
    taskENTER_CRITICAL(&s_lock);
    s_state.phase = phase;
    snprintf(s_state.status, sizeof(s_state.status), "%s", text);
    taskEXIT_CRITICAL(&s_lock);
}

static bool safe_bin_name(const char *name)
{
    if (!name || !name[0] || strlen(name) >= MODULUS_S3_OTA_NAME_LEN ||
        strstr(name, "..") || strchr(name, '/') || strchr(name, '\\')) return false;
    const size_t n = strlen(name);
    return n > 4 && strcasecmp(name + n - 4, ".bin") == 0;
}

static bool image_path(char *out, size_t out_len, const char *root, const char *name)
{
    const size_t root_len = root ? strlen(root) : 0;
    const size_t name_len = name ? strlen(name) : 0;
    if (!name || root_len + 1U + name_len + 1U > out_len) return false;
    memcpy(out, root, root_len);
    out[root_len] = '/';
    memcpy(out + root_len + 1U, name, name_len + 1U);
    return true;
}

static esp_err_t inspect_s3_image(const char *path, size_t *size_out, esp_app_desc_t *desc_out);

static bool scan_root(modulus_s3_ota_snapshot_t *next,
                      char paths[MODULUS_S3_OTA_MAX_FILES][192],
                      const char *root, const char *label)
{
    DIR *dir = opendir(root);
    if (!dir) return false;
    struct dirent *entry;
    while ((entry = readdir(dir)) != NULL && next->file_count < MODULUS_S3_OTA_MAX_FILES) {
        if (!safe_bin_name(entry->d_name)) continue;
        char path[192];
        size_t size = 0;
        esp_app_desc_t desc = {0};
        if (!image_path(path, sizeof(path), root, entry->d_name)) continue;
        if (inspect_s3_image(path, &size, &desc) != ESP_OK) continue;
        const uint8_t index = next->file_count;
        snprintf(next->files[index], sizeof(next->files[index]), "%.3s: %.90s", label, entry->d_name);
        snprintf(paths[index], sizeof(paths[index]), "%s", path);
        next->file_count++;
    }
    closedir(dir);
    return true;
}

static esp_err_t inspect_s3_image(const char *path, size_t *size_out, esp_app_desc_t *desc_out)
{
    struct stat st = {0};
    if (stat(path, &st) != 0 || st.st_size <= 0 || (uint64_t)st.st_size > OTA_MAX_IMAGE_SIZE)
        return ESP_ERR_INVALID_SIZE;
    FILE *f = fopen(path, "rb");
    if (!f) return ESP_ERR_NOT_FOUND;
    esp_image_header_t hdr = {0};
    esp_image_segment_header_t seg = {0};
    esp_app_desc_t desc = {0};
    const bool ok = fread(&hdr, 1, sizeof(hdr), f) == sizeof(hdr) &&
                    fread(&seg, 1, sizeof(seg), f) == sizeof(seg) &&
                    fread(&desc, 1, sizeof(desc), f) == sizeof(desc);
    fclose(f);
    if (!ok || hdr.magic != ESP_IMAGE_HEADER_MAGIC || hdr.chip_id != ESP_CHIP_ID_ESP32S3 ||
        desc.magic_word != ESP_APP_DESC_MAGIC_WORD) return ESP_ERR_INVALID_ARG;
    *size_out = (size_t)st.st_size;
    *desc_out = desc;
    return ESP_OK;
}

static void ota_event(uint8_t evt, const uint8_t *body, uint16_t len, void *ctx)
{
    (void)ctx;
    if (evt != ESPNOW_EVT_RECV || !body || len < 6 + MOD_S3_OTA_HEADER_SIZE) return;
    const mod_s3_ota_packet_t *packet = (const mod_s3_ota_packet_t *)(body + 6);
    if (packet->magic != MOD_S3_OTA_MAGIC || packet->version != MOD_S3_OTA_VERSION ||
        packet->type != MOD_S3_OTA_REPLY || packet->payload_len < sizeof(mod_s3_ota_reply_t) ||
        len != 6 + MOD_S3_OTA_HEADER_SIZE + packet->payload_len) return;
    const mod_s3_ota_reply_t *reply = (const mod_s3_ota_reply_t *)packet->payload;
    if (reply->command != s_wait_command || packet->session != s_wait_session ||
        packet->sequence != s_wait_sequence) return;
    memcpy(&s_reply_packet, packet, MOD_S3_OTA_HEADER_SIZE + packet->payload_len);
    if (s_reply_sem) xSemaphoreGive(s_reply_sem);
}

static void ensure_registered(void)
{
    if (!s_reply_sem) s_reply_sem = xSemaphoreCreateBinary();
    if (!s_registered) {
        modulus_espnow_stack_register();
        modulus_espnow_stack_set_aux_evt_hook(ota_event, NULL);
        s_registered = true;
    }
}

static bool send_wait(mod_s3_ota_packet_t *packet, mod_s3_ota_status_t *status_out)
{
    ensure_registered();
    if (!s_reply_sem) return false;
    (void)xSemaphoreTake(s_reply_sem, 0);
    s_wait_command = packet->type;
    s_wait_session = packet->session;
    s_wait_sequence = packet->sequence;
    if (!modulus_espnow_stack_send_configured_peer((const uint8_t *)packet,
            MOD_S3_OTA_HEADER_SIZE + packet->payload_len)) return false;
    if (xSemaphoreTake(s_reply_sem, pdMS_TO_TICKS(OTA_REPLY_TIMEOUT_MS)) != pdTRUE) return false;
    const mod_s3_ota_reply_t *reply = (const mod_s3_ota_reply_t *)s_reply_packet.payload;
    if (status_out) *status_out = (mod_s3_ota_status_t)reply->status;
    return true;
}

static bool probe_s3(char *version, size_t version_len)
{
    mod_s3_ota_packet_t packet = {0};
    packet.magic = MOD_S3_OTA_MAGIC;
    packet.version = MOD_S3_OTA_VERSION;
    packet.type = MOD_S3_OTA_PROBE;
    packet.session = esp_random();
    mod_s3_ota_status_t status = MOD_S3_OTA_BUSY;
    if (!send_wait(&packet, &status) || status != MOD_S3_OTA_OK) return false;
    const mod_s3_ota_reply_t *reply = (const mod_s3_ota_reply_t *)s_reply_packet.payload;
    snprintf(version, version_len, "%s", reply->app_version);
    return true;
}

void modulus_s3_ota_get_snapshot(modulus_s3_ota_snapshot_t *out)
{
    if (!out) return;
    taskENTER_CRITICAL(&s_lock);
    *out = s_state;
    taskEXIT_CRITICAL(&s_lock);
}

void modulus_s3_ota_refresh(void)
{
    if (s_worker_running) return;
    modulus_s3_ota_snapshot_t next = { .phase = MODULUS_S3_OTA_READY };
    const bool usb_mounted = modulus_storage_usb_volume_mounted();
    next.s3_connected = probe_s3(next.s3_version, sizeof(next.s3_version));
    char paths[MODULUS_S3_OTA_MAX_FILES][192] = {{0}};
    const bool usb_open = usb_mounted && scan_root(&next, paths, OTA_USB_ROOT, "USB");
    if (!next.s3_connected) {
        next.phase = MODULUS_S3_OTA_ERROR;
        snprintf(next.status, sizeof(next.status), "S3 bridge not responding. Check peer MAC/channel and first-flash firmware.");
    } else if (!usb_open) {
        next.phase = MODULUS_S3_OTA_ERROR;
        snprintf(next.status, sizeof(next.status), "Insert a FAT USB drive, wait for it to mount, then refresh.");
    } else if (next.file_count == 0) {
        snprintf(next.status, sizeof(next.status), "No valid ESP32-S3 app images found in the USB drive root.");
    } else {
        snprintf(next.status, sizeof(next.status), "%u verified S3 image(s) found. Select one and check it.", next.file_count);
    }
    taskENTER_CRITICAL(&s_lock);
    s_state = next;
    memcpy(s_file_paths, paths, sizeof(s_file_paths));
    s_armed_path[0] = 0;
    s_armed_size = 0;
    taskEXIT_CRITICAL(&s_lock);
}

void modulus_s3_ota_select(uint8_t index)
{
    taskENTER_CRITICAL(&s_lock);
    if (!s_worker_running && index < s_state.file_count) {
        s_state.selected = index;
        s_state.phase = MODULUS_S3_OTA_READY;
        snprintf(s_state.status, sizeof(s_state.status), "Selected %s. Check the image before flashing.", s_state.files[index]);
        s_armed_path[0] = 0;
        s_armed_size = 0;
    }
    taskEXIT_CRITICAL(&s_lock);
}

void modulus_s3_ota_arm_selected(void)
{
    modulus_s3_ota_snapshot_t snap;
    modulus_s3_ota_get_snapshot(&snap);
    if (s_worker_running || !snap.s3_connected || snap.selected >= snap.file_count) return;
    char path[sizeof(s_armed_path)];
    taskENTER_CRITICAL(&s_lock);
    snprintf(path, sizeof(path), "%s", s_file_paths[snap.selected]);
    taskEXIT_CRITICAL(&s_lock);
    size_t size = 0;
    esp_app_desc_t desc = {0};
    if (inspect_s3_image(path, &size, &desc) != ESP_OK) {
        state_status(MODULUS_S3_OTA_ERROR, "Rejected: not a valid ESP32-S3 application image.");
        return;
    }
    taskENTER_CRITICAL(&s_lock);
    snprintf(s_armed_path, sizeof(s_armed_path), "%s", path);
    s_armed_size = size;
    s_state.phase = MODULUS_S3_OTA_ARMED;
    s_state.progress = 0;
    snprintf(s_state.status, sizeof(s_state.status), "Checked ESP32-S3 image: %.48s, version %.24s, %u bytes. Flash is armed.",
             snap.files[snap.selected], desc.version, (unsigned)size);
    taskEXIT_CRITICAL(&s_lock);
}

static void send_abort(uint32_t session)
{
    mod_s3_ota_packet_t packet = { .magic = MOD_S3_OTA_MAGIC, .version = MOD_S3_OTA_VERSION,
        .type = MOD_S3_OTA_ABORT, .session = session };
    mod_s3_ota_status_t ignored;
    (void)send_wait(&packet, &ignored);
}

static void ota_worker(void *arg)
{
    (void)arg;
    char path[sizeof(s_armed_path)];
    size_t image_size;
    taskENTER_CRITICAL(&s_lock);
    snprintf(path, sizeof(path), "%s", s_armed_path);
    image_size = s_armed_size;
    s_state.phase = MODULUS_S3_OTA_FLASHING;
    s_state.progress = 0;
    snprintf(s_state.status, sizeof(s_state.status), "Flashing S3 over ESP-NOW. Keep the CNC idle; do not remove power or USB.");
    taskEXIT_CRITICAL(&s_lock);

    uint32_t session = esp_random();
    if (session == 0) session = 1;
    mod_s3_ota_packet_t *packet = calloc(1, sizeof(*packet));
    FILE *f = fopen(path, "rb");
    bool ok = packet && f;
    mod_s3_ota_status_t remote = MOD_S3_OTA_BUSY;
    if (ok) {
        packet->magic = MOD_S3_OTA_MAGIC;
        packet->version = MOD_S3_OTA_VERSION;
        packet->type = MOD_S3_OTA_BEGIN;
        packet->session = session;
        packet->value = (uint32_t)image_size;
        ok = send_wait(packet, &remote) && remote == MOD_S3_OTA_OK;
    }
    size_t sent = 0;
    uint32_t seq = 0;
    while (ok && sent < image_size) {
        size_t want = image_size - sent;
        if (want > MOD_S3_OTA_DATA_MAX) want = MOD_S3_OTA_DATA_MAX;
        memset(packet, 0, MOD_S3_OTA_HEADER_SIZE);
        if (fread(packet->payload, 1, want, f) != want) { ok = false; break; }
        packet->magic = MOD_S3_OTA_MAGIC;
        packet->version = MOD_S3_OTA_VERSION;
        packet->type = MOD_S3_OTA_DATA;
        packet->payload_len = (uint16_t)want;
        packet->session = session;
        packet->sequence = seq;
        packet->payload_crc = esp_crc32_le(UINT32_MAX, packet->payload, want);
        bool acked = false;
        for (int retry = 0; retry < OTA_DATA_RETRIES && !acked; retry++)
            acked = send_wait(packet, &remote) && remote == MOD_S3_OTA_OK;
        if (!acked) { ok = false; break; }
        sent += want;
        seq++;
        taskENTER_CRITICAL(&s_lock);
        s_state.progress = (uint8_t)((sent * 100U) / image_size);
        taskEXIT_CRITICAL(&s_lock);
    }
    if (ok) {
        memset(packet, 0, MOD_S3_OTA_HEADER_SIZE);
        packet->magic = MOD_S3_OTA_MAGIC;
        packet->version = MOD_S3_OTA_VERSION;
        packet->type = MOD_S3_OTA_END;
        packet->session = session;
        packet->sequence = seq;
        ok = send_wait(packet, &remote) && remote == MOD_S3_OTA_OK;
    }
    if (!ok) send_abort(session);
    if (f) fclose(f);
    free(packet);

    if (ok && sent == image_size) {
        taskENTER_CRITICAL(&s_lock);
        s_state.phase = MODULUS_S3_OTA_SUCCESS;
        s_state.progress = 100;
        snprintf(s_state.status, sizeof(s_state.status), "S3 image verified and selected. Press Restart S3 to boot it.");
        taskEXIT_CRITICAL(&s_lock);
    } else {
        char msg[MODULUS_S3_OTA_STATUS_LEN];
        snprintf(msg, sizeof(msg), "S3 update failed at %u/%u bytes (remote status %u). Old firmware remains bootable.",
                 (unsigned)sent, (unsigned)image_size, (unsigned)remote);
        state_status(MODULUS_S3_OTA_ERROR, msg);
    }
    s_worker_running = false;
    vTaskDelete(NULL);
}

void modulus_s3_ota_start(void)
{
    modulus_s3_ota_snapshot_t snap;
    modulus_s3_ota_get_snapshot(&snap);
    if (s_worker_running || snap.phase != MODULUS_S3_OTA_ARMED || !s_armed_path[0]) return;
    s_worker_running = true;
    if (xTaskCreate(ota_worker, "s3_ota_host", 8192, NULL, 4, NULL) != pdPASS) {
        s_worker_running = false;
        state_status(MODULUS_S3_OTA_ERROR, "Could not start the S3 update worker.");
    }
}

void modulus_s3_ota_restart(void)
{
    modulus_s3_ota_snapshot_t snap;
    modulus_s3_ota_get_snapshot(&snap);
    if (snap.phase != MODULUS_S3_OTA_SUCCESS) return;
    mod_s3_ota_packet_t packet = { .magic = MOD_S3_OTA_MAGIC, .version = MOD_S3_OTA_VERSION,
        .type = MOD_S3_OTA_REBOOT, .session = esp_random() };
    mod_s3_ota_status_t status;
    if (send_wait(&packet, &status) && status == MOD_S3_OTA_OK)
        state_status(MODULUS_S3_OTA_READY, "Restart command accepted. Wait for the S3 bridge to reconnect.");
    else
        state_status(MODULUS_S3_OTA_ERROR, "S3 restart command was not acknowledged.");
}
