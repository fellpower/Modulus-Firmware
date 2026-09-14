#include "nano_ota.h"
#include "zb_proto.h"

#include "esp_app_format.h"
#include "esp_crc.h"
#include "esp_log.h"
#include "esp_ota_ops.h"
#include "esp_system.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

static const char *TAG = "nano_ota";
static esp_ota_handle_t s_handle;
static const esp_partition_t *s_partition;
static uint32_t s_size;
static uint32_t s_written;
static uint32_t s_last_offset;
static uint32_t s_last_crc;
static uint16_t s_last_len;
static bool s_active;
static bool s_reboot_armed;

static uint32_t be32(const uint8_t *p)
{
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) |
           ((uint32_t)p[2] << 8) | p[3];
}

static void reset_session(bool abort_write)
{
    if (abort_write && s_active) (void)esp_ota_abort(s_handle);
    s_handle = 0;
    s_partition = NULL;
    s_size = 0;
    s_written = 0;
    s_last_offset = 0;
    s_last_crc = 0;
    s_last_len = 0;
    s_active = false;
    s_reboot_armed = false;
}

static void reboot_task(void *unused)
{
    (void)unused;
    vTaskDelay(pdMS_TO_TICKS(400));
    esp_restart();
}

void nano_ota_confirm_running(void)
{
    esp_err_t err = esp_ota_mark_app_valid_cancel_rollback();
    if (err != ESP_OK && err != ESP_ERR_NOT_SUPPORTED) {
        ESP_LOGW(TAG, "Confirm running image: %s", esp_err_to_name(err));
    }
}

bool nano_ota_handle(uint8_t cmd, const uint8_t *args, uint16_t len, uint8_t *reason)
{
    if (cmd < ZIGBEE_CMD_OTA_BEGIN || cmd > ZIGBEE_CMD_OTA_REBOOT) return false;
    if (!reason) return true;
    *reason = 0;

    if (cmd == ZIGBEE_CMD_OTA_BEGIN) {
        if (len != 4) { *reason = 1; return true; }
        reset_session(true);
        s_size = be32(args);
        s_partition = esp_ota_get_next_update_partition(NULL);
        if (!s_partition || !s_size || s_size > s_partition->size) {
            reset_session(false); *reason = 2; return true;
        }
        esp_err_t err = esp_ota_begin(s_partition, s_size, &s_handle);
        if (err != ESP_OK) {
            ESP_LOGE(TAG, "Begin: %s", esp_err_to_name(err));
            reset_session(false); *reason = 3; return true;
        }
        s_active = true;
        ESP_LOGW(TAG, "Started: %lu bytes -> %s", (unsigned long)s_size, s_partition->label);
        return true;
    }

    if (cmd == ZIGBEE_CMD_OTA_DATA) {
        if (!s_active || len <= 8) { *reason = 4; return true; }
        uint32_t offset = be32(args);
        uint32_t crc = be32(args + 4);
        const uint8_t *data = args + 8;
        uint16_t data_len = len - 8;
        /* The P4 retries a command with a fresh link sequence if the ACK was
         * lost. Acknowledge the exact preceding block without writing twice. */
        if (s_written && offset == s_last_offset && data_len == s_last_len && crc == s_last_crc) {
            return true;
        }
        if (offset != s_written || s_written + data_len > s_size) { *reason = 5; return true; }
        if (esp_crc32_le(UINT32_MAX, data, data_len) != crc) { *reason = 6; return true; }
        if (offset == 0) {
            if (data_len < sizeof(esp_image_header_t)) { *reason = 7; return true; }
            const esp_image_header_t *header = (const esp_image_header_t *)data;
            if (header->magic != ESP_IMAGE_HEADER_MAGIC || header->chip_id != ESP_CHIP_ID_ESP32H2) {
                *reason = 7; return true;
            }
        }
        esp_err_t err = esp_ota_write(s_handle, data, data_len);
        if (err != ESP_OK) {
            ESP_LOGE(TAG, "Write: %s", esp_err_to_name(err));
            reset_session(true); *reason = 3; return true;
        }
        s_written += data_len;
        s_last_offset = offset;
        s_last_crc = crc;
        s_last_len = data_len;
        return true;
    }

    if (cmd == ZIGBEE_CMD_OTA_END) {
        if (len || !s_active || s_written != s_size) { *reason = 4; return true; }
        esp_err_t err = esp_ota_end(s_handle);
        s_active = false;
        if (err == ESP_OK) err = esp_ota_set_boot_partition(s_partition);
        if (err != ESP_OK) {
            ESP_LOGE(TAG, "Validate/activate: %s", esp_err_to_name(err));
            reset_session(false); *reason = 7; return true;
        }
        s_reboot_armed = true;
        ESP_LOGW(TAG, "Image verified; reboot armed");
        return true;
    }

    if (len || !s_reboot_armed) { *reason = 4; return true; }
    if (xTaskCreate(reboot_task, "nano_ota_reboot", 2048, NULL, 4, NULL) != pdPASS) *reason = 3;
    return true;
}
