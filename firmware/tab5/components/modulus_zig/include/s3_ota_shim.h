#pragma once

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define MODULUS_S3_OTA_MAX_FILES 8
#define MODULUS_S3_OTA_NAME_LEN 96
#define MODULUS_S3_OTA_STATUS_LEN 160

typedef enum {
    MODULUS_S3_OTA_IDLE = 0,
    MODULUS_S3_OTA_READY,
    MODULUS_S3_OTA_ARMED,
    MODULUS_S3_OTA_FLASHING,
    MODULUS_S3_OTA_SUCCESS,
    MODULUS_S3_OTA_ERROR,
} modulus_s3_ota_phase_t;

typedef struct {
    modulus_s3_ota_phase_t phase;
    uint8_t file_count;
    uint8_t selected;
    uint8_t progress;
    bool s3_connected;
    bool uart_config_supported;
    bool uart_config_busy;
    int8_t uart_tx_gpio;
    int8_t uart_rx_gpio;
    uint32_t uart_baud;
    char s3_version[32];
    char image_version[32];
    char files[MODULUS_S3_OTA_MAX_FILES][MODULUS_S3_OTA_NAME_LEN];
    char status[MODULUS_S3_OTA_STATUS_LEN];
} modulus_s3_ota_snapshot_t;

void modulus_s3_ota_refresh(void);
void modulus_s3_ota_select(uint8_t index);
void modulus_s3_ota_arm_selected(void);
void modulus_s3_ota_start(void);
void modulus_s3_ota_restart(void);
void modulus_s3_ota_get_snapshot(modulus_s3_ota_snapshot_t *out);
void modulus_s3_uart_config_refresh(void);
void modulus_s3_uart_config_apply(int8_t tx_gpio, int8_t rx_gpio, uint32_t baud);

#ifdef __cplusplus
}
#endif

