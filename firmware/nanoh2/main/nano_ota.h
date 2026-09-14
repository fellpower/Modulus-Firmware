#pragma once

#include <stdbool.h>
#include <stdint.h>

/* Handle Modulus UART OTA commands. Returns true when cmd is an OTA command.
 * reason is zero for ACK or a stable non-zero NAK reason. */
bool nano_ota_handle(uint8_t cmd, const uint8_t *args, uint16_t len, uint8_t *reason);

/* Confirm a pending app after it has booted far enough to initialize NVS. */
void nano_ota_confirm_running(void);
