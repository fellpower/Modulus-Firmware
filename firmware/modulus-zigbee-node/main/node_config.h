#pragma once
#include <stdbool.h>
#include <stdint.h>
#define MOD_NODE_CHANNEL_MAX 12
#define MOD_NODE_CHANNEL_INITIAL 4
#define MOD_NODE_NAME_MAX 32
#define MOD_NODE_CHANNEL_NAME_MAX 24
#define MOD_NODE_POLL_DEFAULT_S 15
#define MOD_NODE_POLL_MIN_S 15
#define MOD_NODE_POLL_MAX_S 3600
typedef enum { MOD_NODE_CH_DISABLED=0, MOD_NODE_CH_SWITCH=1, MOD_NODE_CH_DIGITAL_OUTPUT=2,
 MOD_NODE_CH_DIGITAL_INPUT=3, MOD_NODE_CH_DS18B20=4 } mod_node_channel_type_t;
typedef struct { uint8_t type; int8_t gpio; bool active_low; bool pull_up; bool boot_on;
 char name[MOD_NODE_CHANNEL_NAME_MAX]; } mod_node_channel_t;
typedef struct { uint16_t schema_version; char device_name[MOD_NODE_NAME_MAX]; uint8_t channel_count;
 int8_t status_led_gpio; bool status_led_active_low;
 mod_node_channel_t channel[MOD_NODE_CHANNEL_MAX];
 uint16_t poll_interval_s[MOD_NODE_CHANNEL_MAX];
 uint8_t sensor_rom[MOD_NODE_CHANNEL_MAX][8]; } mod_node_config_t;
void mod_node_config_load(mod_node_config_t *cfg);
bool mod_node_config_save(const mod_node_config_t *cfg);
bool mod_node_config_valid(const mod_node_config_t *cfg);
bool mod_node_gpio_allowed(int gpio);
bool mod_node_status_led_gpio_allowed(int gpio);
