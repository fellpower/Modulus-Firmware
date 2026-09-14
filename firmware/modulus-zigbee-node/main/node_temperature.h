#pragma once
#include <stdint.h>
#include "esp_err.h"
#define MOD_NODE_TEMP_INVALID INT16_MIN
/* Exactly one externally powered DS18B20 per GPIO; retries on the next poll. */
esp_err_t mod_node_temperature_read(int gpio, int16_t *centi_c);
