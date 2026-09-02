#include "s3_ota.h"
#include "s3_ota_protocol.h"

#include <cstdio>
#include <cstring>

#include <esp_app_desc.h>
#include <esp_app_format.h>
#include <esp_crc.h>
#include <esp_log.h>
#include <esp_ota_ops.h>
#include <esp_system.h>
#include <freertos/FreeRTOS.h>
#include <freertos/queue.h>
#include <freertos/task.h>

static const char *TAG = "s3_ota";

typedef struct {
    uint8_t mac[6];
    uint16_t len;
    uint8_t bytes[MOD_S3_OTA_HEADER_SIZE + MOD_S3_OTA_DATA_MAX];
} ota_queue_item_t;

static QueueHandle_t s_queue;
static s3_ota_send_fn s_send;
static esp_ota_handle_t s_handle;
static const esp_partition_t *s_partition;
static uint32_t s_session;
static uint32_t s_expected_seq;
static uint32_t s_image_size;
static uint32_t s_written;
static uint32_t s_last_payload_crc;
static uint16_t s_last_payload_len;
static bool s_active;

static void reset_session(bool abort_flash)
{
    if (abort_flash && s_active) (void)esp_ota_abort(s_handle);
    s_handle = 0;
    s_partition = nullptr;
    s_session = 0;
    s_expected_seq = 0;
    s_image_size = 0;
    s_written = 0;
    s_last_payload_crc = 0;
    s_last_payload_len = 0;
    s_active = false;
}

static void send_reply(const uint8_t mac[6], const mod_s3_ota_packet_t *request,
                       mod_s3_ota_status_t status)
{
    if (!s_send || !request) return;
    mod_s3_ota_packet_t packet = {};
    packet.magic = MOD_S3_OTA_MAGIC;
    packet.version = MOD_S3_OTA_VERSION;
    packet.type = MOD_S3_OTA_REPLY;
    packet.session = request->session;
    packet.sequence = request->sequence;
    packet.value = s_written;
    mod_s3_ota_reply_t reply = {};
    reply.command = request->type;
    reply.status = status;
    const esp_app_desc_t *desc = esp_app_get_description();
    if (desc) snprintf(reply.app_version, sizeof(reply.app_version), "%s", desc->version);
    packet.payload_len = sizeof(reply);
    memcpy(packet.payload, &reply, sizeof(reply));
    (void)s_send(mac, reinterpret_cast<const uint8_t *>(&packet),
                 MOD_S3_OTA_HEADER_SIZE + packet.payload_len);
}

static mod_s3_ota_status_t begin_update(const mod_s3_ota_packet_t *packet)
{
    if (s_active) reset_session(true);
    if (packet->value == 0) return MOD_S3_OTA_BAD_IMAGE;
    s_partition = esp_ota_get_next_update_partition(nullptr);
    if (!s_partition || packet->value > s_partition->size) return MOD_S3_OTA_BAD_IMAGE;
    const esp_err_t err = esp_ota_begin(s_partition, packet->value, &s_handle);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "esp_ota_begin: %s", esp_err_to_name(err));
        reset_session(false);
        return MOD_S3_OTA_FLASH_ERROR;
    }
    s_active = true;
    s_session = packet->session;
    s_image_size = packet->value;
    s_expected_seq = 0;
    s_written = 0;
    ESP_LOGW(TAG, "OTA session %lu started (%lu bytes -> %s)",
             (unsigned long)s_session, (unsigned long)s_image_size, s_partition->label);
    return MOD_S3_OTA_OK;
}

static mod_s3_ota_status_t write_data(const mod_s3_ota_packet_t *packet)
{
    if (!s_active || packet->session != s_session)
        return MOD_S3_OTA_BAD_STATE;
    if (packet->payload_len == 0 || packet->payload_len > MOD_S3_OTA_DATA_MAX)
        return MOD_S3_OTA_BAD_PACKET;
    const uint32_t crc = esp_crc32_le(UINT32_MAX, packet->payload, packet->payload_len);
    if (crc != packet->payload_crc) return MOD_S3_OTA_BAD_PACKET;
    /* The host retries when an ESP-NOW reply is lost. Acknowledge the exact
     * previous block again without writing it twice. */
    if (s_expected_seq > 0 && packet->sequence == s_expected_seq - 1 &&
        packet->payload_len == s_last_payload_len && packet->payload_crc == s_last_payload_crc)
        return MOD_S3_OTA_OK;
    if (packet->sequence != s_expected_seq) return MOD_S3_OTA_BAD_STATE;
    if (s_written + packet->payload_len > s_image_size) return MOD_S3_OTA_BAD_PACKET;
    if (s_written == 0) {
        if (packet->payload_len < sizeof(esp_image_header_t)) return MOD_S3_OTA_BAD_IMAGE;
        const esp_image_header_t *header = reinterpret_cast<const esp_image_header_t *>(packet->payload);
        if (header->magic != ESP_IMAGE_HEADER_MAGIC || header->chip_id != ESP_CHIP_ID_ESP32S3)
            return MOD_S3_OTA_BAD_IMAGE;
    }
    const esp_err_t err = esp_ota_write(s_handle, packet->payload, packet->payload_len);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "esp_ota_write: %s", esp_err_to_name(err));
        reset_session(true);
        return MOD_S3_OTA_FLASH_ERROR;
    }
    s_written += packet->payload_len;
    s_last_payload_crc = packet->payload_crc;
    s_last_payload_len = packet->payload_len;
    s_expected_seq++;
    return MOD_S3_OTA_OK;
}

static mod_s3_ota_status_t finish_update(const mod_s3_ota_packet_t *packet)
{
    if (!s_active || packet->session != s_session || s_written != s_image_size)
        return MOD_S3_OTA_BAD_STATE;
    esp_err_t err = esp_ota_end(s_handle); /* validates the complete ESP image */
    s_active = false;
    if (err == ESP_OK) err = esp_ota_set_boot_partition(s_partition);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "OTA validation/activation: %s", esp_err_to_name(err));
        reset_session(false);
        return MOD_S3_OTA_BAD_IMAGE;
    }
    ESP_LOGW(TAG, "OTA image verified; restart command required to boot %s", s_partition->label);
    return MOD_S3_OTA_OK;
}

static void reboot_task(void *)
{
    vTaskDelay(pdMS_TO_TICKS(350));
    esp_restart();
}

static void ota_worker(void *)
{
    ota_queue_item_t item;
    for (;;) {
        if (xQueueReceive(s_queue, &item, portMAX_DELAY) != pdTRUE) continue;
        const mod_s3_ota_packet_t *packet = reinterpret_cast<const mod_s3_ota_packet_t *>(item.bytes);
        mod_s3_ota_status_t status = MOD_S3_OTA_OK;
        switch (packet->type) {
        case MOD_S3_OTA_PROBE:
            break;
        case MOD_S3_OTA_BEGIN:
            status = begin_update(packet);
            break;
        case MOD_S3_OTA_DATA:
            status = write_data(packet);
            break;
        case MOD_S3_OTA_END:
            status = finish_update(packet);
            break;
        case MOD_S3_OTA_ABORT:
            reset_session(true);
            break;
        case MOD_S3_OTA_REBOOT:
            send_reply(item.mac, packet, MOD_S3_OTA_OK);
            xTaskCreate(reboot_task, "s3_reboot", 2048, nullptr, 4, nullptr);
            continue;
        default:
            status = MOD_S3_OTA_BAD_PACKET;
            break;
        }
        send_reply(item.mac, packet, status);
    }
}

void s3_ota_init(s3_ota_send_fn send_fn)
{
    s_send = send_fn;
    s_queue = xQueueCreate(4, sizeof(ota_queue_item_t));
    ESP_ERROR_CHECK(s_queue ? ESP_OK : ESP_ERR_NO_MEM);
    xTaskCreatePinnedToCore(ota_worker, "s3_ota", 6144, nullptr, 8, nullptr, 1);
    ESP_LOGI(TAG, "OTA receiver ready");
}

bool s3_ota_try_handle(const uint8_t src_mac[6], const uint8_t *data, size_t len)
{
    if (!src_mac || !data || len < MOD_S3_OTA_HEADER_SIZE || !s_queue) return false;
    const mod_s3_ota_packet_t *packet = reinterpret_cast<const mod_s3_ota_packet_t *>(data);
    if (packet->magic != MOD_S3_OTA_MAGIC) return false;
    if (packet->version != MOD_S3_OTA_VERSION || packet->payload_len > MOD_S3_OTA_DATA_MAX ||
        len != MOD_S3_OTA_HEADER_SIZE + packet->payload_len) {
        return true; /* OTA magic: consume malformed control traffic, never forward to CNC UART. */
    }
    ota_queue_item_t item = {};
    memcpy(item.mac, src_mac, 6);
    item.len = static_cast<uint16_t>(len);
    memcpy(item.bytes, data, len);
    if (xQueueSend(s_queue, &item, 0) != pdTRUE) {
        ESP_LOGW(TAG, "OTA queue full");
    }
    return true;
}
