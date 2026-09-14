#pragma once
#include <stdbool.h>
#include <stdint.h>

#define MODULUS_NANO_OTA_MAX_FILES 8
#define MODULUS_NANO_OTA_NAME_LEN 96
#define MODULUS_NANO_OTA_STATUS_LEN 160

typedef enum { MODULUS_NANO_OTA_IDLE, MODULUS_NANO_OTA_READY,
    MODULUS_NANO_OTA_ARMED, MODULUS_NANO_OTA_FLASHING,
    MODULUS_NANO_OTA_SUCCESS, MODULUS_NANO_OTA_ERROR } modulus_nano_ota_phase_t;

typedef struct {
    modulus_nano_ota_phase_t phase;
    uint8_t file_count, selected, progress;
    bool nano_connected;
    char nano_version[24], image_version[32];
    char files[MODULUS_NANO_OTA_MAX_FILES][MODULUS_NANO_OTA_NAME_LEN];
    char status[MODULUS_NANO_OTA_STATUS_LEN];
} modulus_nano_ota_snapshot_t;

void modulus_nano_ota_refresh(void);
void modulus_nano_ota_select(uint8_t index);
void modulus_nano_ota_arm_selected(void);
void modulus_nano_ota_start(void);
void modulus_nano_ota_restart(void);
void modulus_nano_ota_get_snapshot(modulus_nano_ota_snapshot_t *out);
