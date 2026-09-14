#include "node_temperature.h"
#include "node_temperature_decode.h"
#include "node_config.h"
#include "onewire_bus.h"
#include "onewire_device.h"
#include "ds18b20.h"
#include "driver/gpio.h"
#include <string.h>

esp_err_t mod_node_temperature_read(int gpio, int16_t *centi_c)
{
    *centi_c = MOD_NODE_TEMP_INVALID;
    if (!mod_node_gpio_allowed(gpio)) return ESP_ERR_INVALID_ARG;
    onewire_bus_handle_t bus = NULL;
    onewire_device_iter_handle_t iter = NULL;
    ds18b20_device_handle_t sensor = NULL;
    onewire_bus_config_t cfg = {.bus_gpio_num = gpio};
    onewire_bus_rmt_config_t rmt = {.max_rx_bytes = 10};
    esp_err_t err = onewire_new_bus_rmt(&cfg, &rmt, &bus);
    if (err != ESP_OK) return err;
    /* Release the RMT pair after every sample: twelve configured channels
     * must not require twelve simultaneously allocated RMT peripherals. */
    if ((err = onewire_new_device_iter(bus, &iter)) != ESP_OK) goto done;
    onewire_device_t dev, extra;
    if ((err = onewire_device_iter_get_next(iter, &dev)) != ESP_OK) goto done;
    uint8_t rom[8];
    memcpy(rom, &dev.address, sizeof(rom));
    if (rom[0] != 0x28 || mod_node_crc8(rom, 7) != rom[7]) {
        err = ESP_ERR_INVALID_RESPONSE; goto done;
    }
    err = onewire_device_iter_get_next(iter, &extra);
    if (err == ESP_OK) { err = ESP_ERR_NOT_SUPPORTED; goto done; }
    if (err != ESP_ERR_NOT_FOUND) goto done;
    ds18b20_config_t ds_cfg = {};
    if ((err = ds18b20_new_device_from_enumeration(&dev, &ds_cfg, &sensor)) != ESP_OK) goto done;
    if ((err = ds18b20_set_resolution(sensor, DS18B20_RESOLUTION_12B)) != ESP_OK) goto done;
    if ((err = ds18b20_trigger_temperature_conversion(sensor)) != ESP_OK) goto done;
    /* Require a completed conversion, not just a successful write. */
    uint8_t ready = 0;
    if ((err = onewire_bus_read_bit(bus, &ready)) != ESP_OK) goto done;
    if (!ready) { err = ESP_ERR_TIMEOUT; goto done; }
    if ((err = onewire_bus_reset(bus)) != ESP_OK) goto done;
    uint8_t command[10] = {0x55}; /* MATCH ROM + READ SCRATCHPAD */
    memcpy(command + 1, rom, 8); command[9] = 0xbe;
    if ((err = onewire_bus_write_bytes(bus, command, sizeof(command))) != ESP_OK) goto done;
    uint8_t scratch[9];
    if ((err = onewire_bus_read_bytes(bus, scratch, sizeof(scratch))) != ESP_OK) goto done;
    if (!mod_node_temperature_decode(scratch, centi_c)) err = ESP_ERR_INVALID_RESPONSE;
done:
    if (sensor) ds18b20_del_device(sensor);
    if (iter) onewire_del_device_iter(iter);
    onewire_bus_del(bus);
    gpio_reset_pin((gpio_num_t)gpio);
    return err;
}
