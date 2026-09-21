#pragma once
#include <stdint.h>
#include "esp_err.h"
#define MOD_NODE_TEMP_INVALID INT16_MIN
/* Selects a stable OneWire search-order index on a shared, externally powered bus. */
esp_err_t mod_node_temperature_read(int gpio, uint8_t sensor_index,
                                    const uint8_t wanted_rom[8], uint8_t found_rom[8],
                                    int16_t *centi_c);
