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
    uint32_t value;       /* BEGIN: image size; REPLY: bytes written */
    uint32_t payload_crc; /* DATA payload CRC32, zero otherwise */
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
    /* Optional UART pin-selection extension. Keep all fields above stable. */
    uint8_t board_profile_id;
    uint64_t uart_tx_gpio_mask;
    uint64_t uart_rx_gpio_mask;
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

/* Stable wire IDs. Append only; do not renumber existing profiles. */
typedef enum {
    MOD_S3_BOARD_UNKNOWN = 0,
    MOD_S3_BOARD_MINI1 = 1,
    MOD_S3_BOARD_WS_S3_ZERO = 2,
    MOD_S3_BOARD_S3_SUPERMINI = 3,
    MOD_S3_BOARD_QTPY_S3 = 4,
    MOD_S3_BOARD_FEATHER_S3 = 5,
    MOD_S3_BOARD_FEATHER_S3_NP = 6,
    MOD_S3_BOARD_XIAO = 7,
    MOD_S3_BOARD_XIAO_PLUS = 8,
    MOD_S3_BOARD_UM_FEATHERS3 = 9,
    MOD_S3_BOARD_UM_TINYS3 = 10,
    MOD_S3_BOARD_S3_DEVKITM1 = 11,
} mod_s3_board_profile_id_t;

#if defined(__cplusplus)
static_assert(offsetof(mod_s3_ota_reply_t, capabilities) == 36, "S3 reply capability offset changed");
static_assert(offsetof(mod_s3_ota_reply_t, uart_tx_gpio) == 37, "S3 reply TX offset changed");
static_assert(offsetof(mod_s3_ota_reply_t, uart_rx_gpio) == 38, "S3 reply RX offset changed");
static_assert(offsetof(mod_s3_ota_reply_t, uart_baud) == 40, "S3 reply baud offset changed");
static_assert(offsetof(mod_s3_ota_reply_t, uart_test_result) == 44, "S3 reply test offset changed");
static_assert(offsetof(mod_s3_ota_reply_t, board_profile_id) == 45, "S3 reply base layout changed");
static_assert(offsetof(mod_s3_ota_reply_t, uart_tx_gpio_mask) == 46, "S3 reply TX mask offset changed");
static_assert(offsetof(mod_s3_ota_reply_t, uart_rx_gpio_mask) == 54, "S3 reply RX mask offset changed");
static_assert(sizeof(mod_s3_ota_reply_t) == 62, "S3 reply extension layout changed");
#else
_Static_assert(offsetof(mod_s3_ota_reply_t, capabilities) == 36, "S3 reply capability offset changed");
_Static_assert(offsetof(mod_s3_ota_reply_t, uart_tx_gpio) == 37, "S3 reply TX offset changed");
_Static_assert(offsetof(mod_s3_ota_reply_t, uart_rx_gpio) == 38, "S3 reply RX offset changed");
_Static_assert(offsetof(mod_s3_ota_reply_t, uart_baud) == 40, "S3 reply baud offset changed");
_Static_assert(offsetof(mod_s3_ota_reply_t, uart_test_result) == 44, "S3 reply test offset changed");
_Static_assert(offsetof(mod_s3_ota_reply_t, board_profile_id) == 45, "S3 reply base layout changed");
_Static_assert(offsetof(mod_s3_ota_reply_t, uart_tx_gpio_mask) == 46, "S3 reply TX mask offset changed");
_Static_assert(offsetof(mod_s3_ota_reply_t, uart_rx_gpio_mask) == 54, "S3 reply RX mask offset changed");
_Static_assert(sizeof(mod_s3_ota_reply_t) == 62, "S3 reply extension layout changed");
#endif

typedef enum {
    MOD_S3_UART_TEST_NOT_RUN = 0,
    MOD_S3_UART_TEST_GRBL_OK,
    MOD_S3_UART_TEST_DATA_UNRECOGNIZED,
    MOD_S3_UART_TEST_NO_RESPONSE,
    MOD_S3_UART_TEST_TX_ERROR,
    MOD_S3_UART_TEST_BUSY,
} mod_s3_uart_test_result_t;

#define MOD_S3_OTA_HEADER_SIZE ((uint16_t)offsetof(mod_s3_ota_packet_t, payload))
