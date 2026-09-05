#pragma once

#include <stddef.h>
#include <stdint.h>

#define MOD_S3_OTA_MAGIC        0x53334f54U
#define MOD_S3_OTA_VERSION      1U
#define MOD_S3_OTA_DATA_MAX     1024U

typedef enum {
    MOD_S3_OTA_PROBE  = 1,
    MOD_S3_OTA_BEGIN  = 2,
    MOD_S3_OTA_DATA   = 3,
    MOD_S3_OTA_END    = 4,
    MOD_S3_OTA_ABORT  = 5,
    MOD_S3_OTA_REBOOT = 6,
    MOD_S3_CTRL_GET_UART = 7,
    MOD_S3_CTRL_SET_UART = 8,
    MOD_S3_CTRL_TEST_UART = 9,
    MOD_S3_OTA_REPLY  = 0x80,
} mod_s3_ota_type_t;

typedef enum {
    MOD_S3_OTA_OK = 0,
    MOD_S3_OTA_BAD_PACKET,
    MOD_S3_OTA_BAD_STATE,
    MOD_S3_OTA_BAD_IMAGE,
    MOD_S3_OTA_FLASH_ERROR,
    MOD_S3_OTA_BUSY,
    MOD_S3_OTA_BAD_CONFIG,
    MOD_S3_OTA_NVS_ERROR,
} mod_s3_ota_status_t;

#pragma pack(push, 1)
typedef struct {
    uint32_t magic;
    uint8_t version;
    uint8_t type;
    uint16_t payload_len;
    uint32_t session;
    uint32_t sequence;
    uint32_t value;
    uint32_t payload_crc;
    uint8_t payload[MOD_S3_OTA_DATA_MAX];
} mod_s3_ota_packet_t;

typedef struct {
    uint8_t command;
    uint8_t status;
    uint16_t reserved;
    char app_version[32];
    uint8_t capabilities;
    int8_t uart_tx_gpio;
    int8_t uart_rx_gpio;
    uint8_t reserved2;
    uint32_t uart_baud;
    uint8_t uart_test_result;
} mod_s3_ota_reply_t;

typedef struct {
    int8_t tx_gpio;
    int8_t rx_gpio;
    uint16_t reserved;
    uint32_t baud;
} mod_s3_uart_config_t;
#pragma pack(pop)

#define MOD_S3_CAP_UART_CONFIG 0x01U
#define MOD_S3_CAP_UART_TEST   0x02U

typedef enum {
    MOD_S3_UART_TEST_NOT_RUN = 0,
    MOD_S3_UART_TEST_GRBL_OK,
    MOD_S3_UART_TEST_DATA_UNRECOGNIZED,
    MOD_S3_UART_TEST_NO_RESPONSE,
    MOD_S3_UART_TEST_TX_ERROR,
    MOD_S3_UART_TEST_BUSY,
} mod_s3_uart_test_result_t;

#define MOD_S3_OTA_HEADER_SIZE ((uint16_t)offsetof(mod_s3_ota_packet_t, payload))

