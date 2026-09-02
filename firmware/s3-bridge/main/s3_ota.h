#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef bool (*s3_ota_send_fn)(const uint8_t *mac, const uint8_t *data, size_t len);

void s3_ota_init(s3_ota_send_fn send_fn);
bool s3_ota_try_handle(const uint8_t src_mac[6], const uint8_t *data, size_t len);

