#pragma once

#include <stddef.h>
#include <stdint.h>

/* Private Modulus S3 OTA control plane carried inside ESP-NOW payloads.
 * The magic keeps firmware traffic separate from transparent CNC UART data. */
#define MOD_S3_OTA_MAGIC        0x53334f54U /* "S3OT" */
#define MOD_S3_OTA_VERSION      1U
#define MOD_S3_OTA_DATA_MAX     1024U

typedef enum {
    MOD_S3_OTA_PROBE  = 1,
    MOD_S3_OTA_BEGIN  = 2,
    MOD_S3_OTA_DATA   = 3,
    MOD_S3_OTA_END    = 4,
    MOD_S3_OTA_ABORT  = 5,
    MOD_S3_OTA_REBOOT = 6,
    MOD_S3_OTA_REPLY  = 0x80,
} mod_s3_ota_type_t;

typedef enum {
    MOD_S3_OTA_OK = 0,
    MOD_S3_OTA_BAD_PACKET,
    MOD_S3_OTA_BAD_STATE,
    MOD_S3_OTA_BAD_IMAGE,
    MOD_S3_OTA_FLASH_ERROR,
    MOD_S3_OTA_BUSY,
} mod_s3_ota_status_t;

#pragma pack(push, 1)
typedef struct {
    uint32_t magic;
    uint8_t version;
    uint8_t type;
    uint16_t payload_len;
    uint32_t session;
    uint32_t sequence;
    uint32_t value;       /* BEGIN: image size; REPLY: bytes written */
    uint32_t payload_crc; /* DATA payload CRC32, zero otherwise */
    uint8_t payload[MOD_S3_OTA_DATA_MAX];
} mod_s3_ota_packet_t;

typedef struct {
    uint8_t command;
    uint8_t status;
    uint16_t reserved;
    char app_version[32];
} mod_s3_ota_reply_t;
#pragma pack(pop)

#define MOD_S3_OTA_HEADER_SIZE ((uint16_t)offsetof(mod_s3_ota_packet_t, payload))
