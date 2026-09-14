#pragma once
#include <stdbool.h>
#include <stdint.h>

static inline uint8_t mod_node_crc8(const uint8_t *data, unsigned count)
{
    uint8_t crc = 0;
    while (count--) {
        uint8_t b = *data++;
        for (unsigned j = 0; j < 8; ++j) {
            uint8_t mix = (crc ^ b) & 1;
            crc >>= 1;
            if (mix) crc ^= 0x8c;
            b >>= 1;
        }
    }
    return crc;
}

static inline bool mod_node_temperature_decode(const uint8_t s[9], int16_t *centi_c)
{
    *centi_c = INT16_MIN;
    if (mod_node_crc8(s, 8) != s[8]) return false;
    /* We explicitly request 12-bit operation. Reject all-zero/bad scratchpads. */
    if (s[4] != 0x7f || s[5] != 0xff || s[7] != 0x10) return false;
    if (s[0] == 0x50 && s[1] == 0x05 && s[6] == 0x0c) return false;
    int32_t raw = (int16_t)((uint16_t)s[0] | ((uint16_t)s[1] << 8));
    if (raw < -55 * 16 || raw > 125 * 16) return false;
    const int32_t scaled = raw * 100;
    *centi_c = (int16_t)((scaled + (scaled < 0 ? -8 : 8)) / 16);
    return true;
}
