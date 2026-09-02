#include "c6_ota_shim.h"
#include "storage_shim.h"

#include <dirent.h>
#include <stdio.h>
#include <stdlib.h>
#include <strings.h>
#include <string.h>
#include <sys/stat.h>

#include "esp_app_desc.h"
#include "esp_app_format.h"
#include "esp_err.h"
#include "esp_hosted.h"
#include "esp_hosted_api_types.h"
#include "esp_hosted_ota.h"
#include "esp_log.h"
#include "esp_system.h"
#include "freertos/FreeRTOS.h"
#include "freertos/portmacro.h"
#include "freertos/task.h"

#define OTA_USB_ROOT "/usb"
#define OTA_CHUNK_SIZE 4096
#define OTA_MAX_IMAGE_SIZE (4U * 1024U * 1024U)

static const char *TAG = "c6_ota";
static modulus_c6_ota_snapshot_t s_state = {
    .phase = MODULUS_C6_OTA_IDLE,
    .status = "Open this page to scan a USB drive. Nothing is flashed automatically.",
};
static portMUX_TYPE s_lock = portMUX_INITIALIZER_UNLOCKED;
static bool s_worker_running;
static char s_armed_path[192];
static size_t s_armed_size;
static char s_file_paths[MODULUS_C6_OTA_MAX_FILES][192];

static void state_status(modulus_c6_ota_phase_t phase, const char *text)
{
    taskENTER_CRITICAL(&s_lock);
    s_state.phase = phase;
    snprintf(s_state.status, sizeof(s_state.status), "%s", text);
    taskEXIT_CRITICAL(&s_lock);
}

static bool safe_bin_name(const char *name)
{
    if (!name || !name[0] || strlen(name) >= MODULUS_C6_OTA_NAME_LEN ||
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

static esp_err_t inspect_image(const char *path, size_t *size_out, esp_app_desc_t *desc_out);

static bool scan_root(modulus_c6_ota_snapshot_t *next,
                      char paths[MODULUS_C6_OTA_MAX_FILES][192],
                      const char *root, const char *label)
{
    DIR *dir = opendir(root);
    if (!dir) return false;
    struct dirent *entry;
    while ((entry = readdir(dir)) != NULL && next->file_count < MODULUS_C6_OTA_MAX_FILES) {
        if (!safe_bin_name(entry->d_name)) continue;
        char path[192];
        size_t image_size = 0;
        esp_app_desc_t image_desc = {0};
        if (!image_path(path, sizeof(path), root, entry->d_name)) continue;
        if (inspect_image(path, &image_size, &image_desc) != ESP_OK) continue;
        const uint8_t index = next->file_count;
        snprintf(next->files[index], sizeof(next->files[index]), "%.3s: %.90s", label, entry->d_name);
        snprintf(paths[index], sizeof(paths[index]), "%s", path);
        next->file_count++;
    }
    closedir(dir);
    return true;
}

static esp_err_t inspect_image(const char *path, size_t *size_out, esp_app_desc_t *desc_out)
{
    struct stat st = {0};
    if (stat(path, &st) != 0 || st.st_size <= 0 || (uint64_t)st.st_size > OTA_MAX_IMAGE_SIZE) {
        return ESP_ERR_INVALID_SIZE;
    }
    FILE *f = fopen(path, "rb");
    if (!f) return ESP_ERR_NOT_FOUND;
    esp_image_header_t hdr = {0};
    esp_image_segment_header_t seg = {0};
    esp_app_desc_t desc = {0};
    const bool read_ok = fread(&hdr, 1, sizeof(hdr), f) == sizeof(hdr) &&
                         fread(&seg, 1, sizeof(seg), f) == sizeof(seg) &&
                         fread(&desc, 1, sizeof(desc), f) == sizeof(desc);
    fclose(f);
    if (!read_ok || hdr.magic != ESP_IMAGE_HEADER_MAGIC ||
        hdr.chip_id != ESP_CHIP_ID_ESP32C6 || desc.magic_word != ESP_APP_DESC_MAGIC_WORD) {
        return ESP_ERR_INVALID_ARG;
    }
    *size_out = (size_t)st.st_size;
    *desc_out = desc;
    return ESP_OK;
}

void modulus_c6_ota_get_snapshot(modulus_c6_ota_snapshot_t *out)
{
    if (!out) return;
    taskENTER_CRITICAL(&s_lock);
    *out = s_state;
    taskEXIT_CRITICAL(&s_lock);
}

void modulus_c6_ota_refresh(void)
{
    if (s_worker_running) return;
    modulus_c6_ota_snapshot_t next = { .phase = MODULUS_C6_OTA_READY };
    const bool usb_mounted = modulus_storage_usb_volume_mounted();
    esp_hosted_coprocessor_fwver_t ver = {0};
    if (esp_hosted_get_coprocessor_fwversion(&ver) == ESP_OK) {
        next.c6_connected = true;
        snprintf(next.c6_version, sizeof(next.c6_version), "%lu.%lu.%lu",
                 (unsigned long)ver.major1, (unsigned long)ver.minor1, (unsigned long)ver.patch1);
    }
    char paths[MODULUS_C6_OTA_MAX_FILES][192] = {{0}};
    const bool usb_open = usb_mounted && scan_root(&next, paths, OTA_USB_ROOT, "USB");
    if (!next.c6_connected) {
        next.phase = MODULUS_C6_OTA_ERROR;
        snprintf(next.status, sizeof(next.status), "C6 is not responding over ESP-Hosted/SDIO.");
    } else if (!usb_open) {
        next.phase = MODULUS_C6_OTA_ERROR;
        snprintf(next.status, sizeof(next.status), "Insert a FAT USB drive, wait for it to mount, then refresh.");
    } else if (next.file_count == 0) {
        snprintf(next.status, sizeof(next.status), "No valid ESP32-C6 app images found in the USB drive root.");
    } else {
        snprintf(next.status, sizeof(next.status), "%u C6 firmware image(s) found. Select one and check it.", next.file_count);
    }
    taskENTER_CRITICAL(&s_lock);
    s_state = next;
    memcpy(s_file_paths, paths, sizeof(s_file_paths));
    s_armed_path[0] = 0;
    s_armed_size = 0;
    taskEXIT_CRITICAL(&s_lock);
}

void modulus_c6_ota_select(uint8_t index)
{
    taskENTER_CRITICAL(&s_lock);
    if (!s_worker_running && index < s_state.file_count) {
        s_state.selected = index;
        s_state.phase = MODULUS_C6_OTA_READY;
        snprintf(s_state.status, sizeof(s_state.status), "Selected %s. Check the image before flashing.", s_state.files[index]);
        s_armed_path[0] = 0;
        s_armed_size = 0;
    }
    taskEXIT_CRITICAL(&s_lock);
}

void modulus_c6_ota_arm_selected(void)
{
    modulus_c6_ota_snapshot_t snap;
    modulus_c6_ota_get_snapshot(&snap);
    if (s_worker_running || !snap.c6_connected || snap.selected >= snap.file_count) return;
    char path[sizeof(s_armed_path)];
    taskENTER_CRITICAL(&s_lock);
    snprintf(path, sizeof(path), "%s", s_file_paths[snap.selected]);
    taskEXIT_CRITICAL(&s_lock);
    size_t size = 0;
    esp_app_desc_t desc = {0};
    const esp_err_t err = inspect_image(path, &size, &desc);
    if (err != ESP_OK) {
        state_status(MODULUS_C6_OTA_ERROR, "Rejected: not a valid ESP32-C6 application image.");
        return;
    }
    taskENTER_CRITICAL(&s_lock);
    snprintf(s_armed_path, sizeof(s_armed_path), "%s", path);
    s_armed_size = size;
    s_state.phase = MODULUS_C6_OTA_ARMED;
    s_state.progress = 0;
    snprintf(s_state.status, sizeof(s_state.status), "Checked: %.48s, version %.24s, %u bytes. Flash is now armed.",
             snap.files[snap.selected], desc.version, (unsigned)size);
    taskEXIT_CRITICAL(&s_lock);
    ESP_LOGW(TAG, "C6 OTA armed only: %s (%u bytes)", path, (unsigned)size);
}

static void ota_worker(void *arg)
{
    (void)arg;
    char path[sizeof(s_armed_path)];
    size_t image_size;
    taskENTER_CRITICAL(&s_lock);
    snprintf(path, sizeof(path), "%s", s_armed_path);
    image_size = s_armed_size;
    s_state.phase = MODULUS_C6_OTA_FLASHING;
    s_state.progress = 0;
    snprintf(s_state.status, sizeof(s_state.status), "Flashing C6. Do not remove power or the source drive.");
    taskEXIT_CRITICAL(&s_lock);

    FILE *f = fopen(path, "rb");
    uint8_t *buf = malloc(OTA_CHUNK_SIZE);
    bool ota_started = false;
    esp_err_t err = (f && buf) ? esp_hosted_slave_ota_begin() : ESP_ERR_NO_MEM;
    if (err == ESP_OK) ota_started = true;
    size_t sent = 0;
    while (err == ESP_OK && sent < image_size) {
        size_t want = image_size - sent;
        if (want > OTA_CHUNK_SIZE) want = OTA_CHUNK_SIZE;
        if (fread(buf, 1, want, f) != want) { err = ESP_FAIL; break; }
        err = esp_hosted_slave_ota_write(buf, (uint32_t)want);
        if (err != ESP_OK) break;
        sent += want;
        taskENTER_CRITICAL(&s_lock);
        s_state.progress = (uint8_t)((sent * 100U) / image_size);
        taskEXIT_CRITICAL(&s_lock);
    }
    if (ota_started) {
        const esp_err_t end_err = esp_hosted_slave_ota_end();
        if (err == ESP_OK) err = end_err;
    }
    if (err == ESP_OK && sent == image_size) err = esp_hosted_slave_ota_activate();
    if (f) fclose(f);
    free(buf);

    if (err == ESP_OK && sent == image_size) {
        taskENTER_CRITICAL(&s_lock);
        s_state.phase = MODULUS_C6_OTA_SUCCESS;
        s_state.progress = 100;
        s_state.c6_connected = false;
        snprintf(s_state.status, sizeof(s_state.status), "C6 firmware activated successfully. Restart Modulus to reconnect.");
        taskEXIT_CRITICAL(&s_lock);
    } else {
        char msg[MODULUS_C6_OTA_STATUS_LEN];
        snprintf(msg, sizeof(msg), "C6 update failed at %u/%u bytes: %s. The image was not activated.",
                 (unsigned)sent, (unsigned)image_size, esp_err_to_name(err));
        state_status(MODULUS_C6_OTA_ERROR, msg);
    }
    s_worker_running = false;
    vTaskDelete(NULL);
}

void modulus_c6_ota_start(void)
{
    modulus_c6_ota_snapshot_t snap;
    modulus_c6_ota_get_snapshot(&snap);
    if (s_worker_running || snap.phase != MODULUS_C6_OTA_ARMED || !s_armed_path[0]) return;
    s_worker_running = true;
    if (xTaskCreate(ota_worker, "c6_ota", 8192, NULL, 4, NULL) != pdPASS) {
        s_worker_running = false;
        state_status(MODULUS_C6_OTA_ERROR, "Could not start the C6 update worker.");
    }
}

void modulus_c6_ota_restart(void)
{
    modulus_c6_ota_snapshot_t snap;
    modulus_c6_ota_get_snapshot(&snap);
    if (snap.phase == MODULUS_C6_OTA_SUCCESS) esp_restart();
}
