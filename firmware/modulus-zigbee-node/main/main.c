#include "node_config.h"
#include "node_protocol.h"
#include "node_temperature.h"
#include <string.h>
#include "driver/gpio.h"
#include "esp_log.h"
#include "esp_ota_ops.h"
#include "esp_system.h"
#include "esp_zigbee_core.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "ha/esp_zigbee_ha_standard.h"
#include "nvs_flash.h"

#define FIRST_CHANNEL_EP 10
#define PROTOCOL_VERSION 4
static const char *TAG = "modulus_node";
static mod_node_config_t s_cfg;
/* Active channel hardware is immutable until Apply and restart. */
static mod_node_config_t s_runtime;
static volatile TickType_t s_hub_seen;

static void status_led_set(bool connected) {
    if (s_cfg.status_led_gpio < 0) return;
    gpio_set_level((gpio_num_t)s_cfg.status_led_gpio,
                   s_cfg.status_led_active_low ? !connected : connected);
}

static void status_led_reconfigure(int8_t old_gpio, bool old_active_low)
{
    if (old_gpio >= 0 && mod_node_status_led_gpio_allowed(old_gpio)) {
        gpio_set_level((gpio_num_t)old_gpio, old_active_low ? 1 : 0);
        gpio_reset_pin((gpio_num_t)old_gpio);
    }
    if (s_cfg.status_led_gpio >= 0 && mod_node_status_led_gpio_allowed(s_cfg.status_led_gpio)) {
        gpio_config_t io = {.pin_bit_mask = 1ULL << s_cfg.status_led_gpio, .mode = GPIO_MODE_OUTPUT};
        if (gpio_config(&io) == ESP_OK) status_led_set(s_hub_seen != 0);
    }
}

static bool is_output(const mod_node_channel_t *c) { return c->type == MOD_NODE_CH_SWITCH || c->type == MOD_NODE_CH_DIGITAL_OUTPUT; }
static void output_set(unsigned i, bool on) {
    if (i < s_runtime.channel_count && is_output(&s_runtime.channel[i]) && s_runtime.channel[i].gpio >= 0)
        gpio_set_level((gpio_num_t)s_runtime.channel[i].gpio, s_runtime.channel[i].active_low ? !on : on);
}

static void config_reply(const esp_zb_zcl_custom_cluster_command_message_t *req,
                         uint8_t command, const uint8_t *data, uint8_t size) {
    uint8_t wire[97];
    if (size > 96) size = 96;
    wire[0] = size;
    if (size) memcpy(wire + 1, data, size);
    esp_zb_zcl_custom_cluster_cmd_resp_t rsp = {
        .zcl_basic_cmd = {.dst_addr_u.addr_short = req->info.src_address.u.short_addr,
                          .dst_endpoint = req->info.src_endpoint, .src_endpoint = MOD_NODE_CONFIG_EP},
        .address_mode = ESP_ZB_APS_ADDR_MODE_16_ENDP_PRESENT,
        .profile_id = ESP_ZB_AF_HA_PROFILE_ID, .cluster_id = MOD_NODE_CONFIG_CLUSTER,
        .direction = ESP_ZB_ZCL_CMD_DIRECTION_TO_CLI, .dis_default_resp = 1,
        .custom_cmd_id = command,
        .data = {.type = ESP_ZB_ZCL_ATTR_TYPE_OCTET_STRING, .size = size + 1, .value = wire},
    };
    uint8_t tsn = esp_zb_zcl_custom_cluster_cmd_resp(&rsp);
    ESP_LOGI(TAG, "Config response cmd=0x%02x bytes=%u tsn=%u", command, size, tsn);
}
static void status_reply(const esp_zb_zcl_custom_cluster_command_message_t *req, uint8_t cmd, uint8_t status) {
    uint8_t data[] = {cmd, status};
    config_reply(req, MOD_NODE_RSP_STATUS, data, sizeof(data));
}

static void config_command(const esp_zb_zcl_custom_cluster_command_message_t *req) {
    if (req->info.status != ESP_ZB_ZCL_STATUS_SUCCESS || req->info.cluster != MOD_NODE_CONFIG_CLUSTER ||
        req->info.src_address.addr_type != ESP_ZB_ZCL_ADDR_TYPE_SHORT) return;
    s_hub_seen = xTaskGetTickCount();
    status_led_set(true);
    ESP_LOGI(TAG, "Config request cmd=0x%02x bytes=%u from=0x%04x ep=%u",
             (unsigned)req->info.command.id, (unsigned)req->data.size,
             req->info.src_address.u.short_addr, req->info.src_endpoint);
    const uint8_t *p = req->data.value;
    size_t n = req->data.size;
    if (p && n && p[0] == n - 1) { p++; n--; }
    switch (req->info.command.id) {
    case 0x00: break; /* Nano coordinator heartbeat; no reply required. */
    case MOD_NODE_CMD_GET_INFO: {
        uint8_t len = (uint8_t)strnlen(s_cfg.device_name, MOD_NODE_NAME_MAX - 1);
        uint8_t data[6 + MOD_NODE_NAME_MAX] = {PROTOCOL_VERSION, s_cfg.channel_count, MOD_NODE_CHANNEL_MAX, len,
            (uint8_t)s_cfg.status_led_gpio, s_cfg.status_led_active_low ? 1 : 0};
        memcpy(data + 6, s_cfg.device_name, len);
        config_reply(req, MOD_NODE_RSP_INFO, data, 6 + len);
        break;
    }
    case MOD_NODE_CMD_GET_CHANNEL: {
        if (!p || n < 1 || p[0] >= s_cfg.channel_count) { status_reply(req, req->info.command.id, 2); break; }
        uint8_t i = p[0], len = (uint8_t)strnlen(s_cfg.channel[i].name, MOD_NODE_CHANNEL_NAME_MAX - 1);
        const mod_node_channel_t *c = &s_cfg.channel[i];
        uint8_t data[16 + MOD_NODE_CHANNEL_NAME_MAX] = {i, c->type, (uint8_t)c->gpio,
            (uint8_t)((c->active_low ? 1 : 0) | (c->pull_up ? 2 : 0) | (c->boot_on ? 4 : 0)), len};
        memcpy(data + 5, c->name, len);
        data[5 + len] = (uint8_t)(s_cfg.poll_interval_s[i] >> 8);
        data[6 + len] = (uint8_t)s_cfg.poll_interval_s[i];
        data[7 + len] = i >= s_runtime.channel_count ||
            memcmp(c, &s_runtime.channel[i], sizeof(*c)) != 0 ||
            s_cfg.poll_interval_s[i] != s_runtime.poll_interval_s[i];
        memcpy(data + 8 + len, s_cfg.sensor_rom[i], 8);
        config_reply(req, MOD_NODE_RSP_CHANNEL, data, 16 + len);
        break;
    }
    case MOD_NODE_CMD_SET_NAME: {
        if (!p || n < 2 || p[0] == 0 || p[0] >= MOD_NODE_NAME_MAX || n < (size_t)p[0] + 1) { status_reply(req, req->info.command.id, 2); break; }
        mod_node_config_t next = s_cfg;
        memcpy(next.device_name, p + 1, p[0]); next.device_name[p[0]] = 0;
        if (!mod_node_config_save(&next)) { status_reply(req, req->info.command.id, 3); break; }
        s_cfg = next; status_reply(req, req->info.command.id, 0); break;
    }
    case MOD_NODE_CMD_SET_CHANNEL: {
        if (!p || n < 5 || p[0] >= MOD_NODE_CHANNEL_MAX || p[1] > MOD_NODE_CH_DS18B20 ||
            p[4] >= MOD_NODE_CHANNEL_NAME_MAX || n < (size_t)p[4] + 5) { status_reply(req, req->info.command.id, 2); break; }
        mod_node_config_t next = s_cfg; uint8_t i = p[0];
        if (next.channel_count <= i) next.channel_count = i + 1;
        mod_node_channel_t *c = &next.channel[i];
        const uint8_t old_type = c->type;
        const int8_t old_gpio = c->gpio;
        c->type = p[1]; c->gpio = (int8_t)p[2]; c->active_low = (p[3] & 1) != 0;
        c->pull_up = (p[3] & 2) != 0; c->boot_on = (p[3] & 4) != 0;
        memcpy(c->name, p + 5, p[4]); c->name[p[4]] = 0;
        /* Moving a channel to another bus or away from DS18B20 explicitly
         * releases its old physical sensor binding. */
        if (c->type != MOD_NODE_CH_DS18B20 || old_type != MOD_NODE_CH_DS18B20 || old_gpio != c->gpio)
            memset(next.sensor_rom[i], 0, 8);
        if (!mod_node_config_save(&next)) { status_reply(req, req->info.command.id, 3); break; }
        s_cfg = next; status_reply(req, req->info.command.id, 0); break;
    }
    case MOD_NODE_CMD_SET_POLL: { /* channel, seconds big-endian */
        if (!p || n != 3 || p[0] >= s_cfg.channel_count) { status_reply(req, 0x15, 2); break; }
        mod_node_config_t next = s_cfg;
        next.poll_interval_s[p[0]] = ((uint16_t)p[1] << 8) | p[2];
        if (!mod_node_config_save(&next)) { status_reply(req, 0x15, 2); break; }
        s_cfg = next; status_reply(req, 0x15, 0); break;
    }
    case MOD_NODE_CMD_APPLY_REBOOT:
        status_reply(req, req->info.command.id, 0);
        esp_zb_scheduler_alarm((esp_zb_callback_t)esp_restart, 0, 300);
        break;
    case MOD_NODE_CMD_SET_STATUS_LED: {
        if (!p || n < 2) { status_reply(req, req->info.command.id, 2); break; }
        mod_node_config_t next = s_cfg;
        next.status_led_gpio = (int8_t)p[0]; next.status_led_active_low = (p[1] & 1) != 0;
        bool active_conflict = false;
        for (unsigned i=0; i<s_runtime.channel_count; ++i)
            if (s_runtime.channel[i].type != MOD_NODE_CH_DISABLED && next.status_led_gpio >= 0 &&
                s_runtime.channel[i].gpio == next.status_led_gpio) active_conflict = true;
        if (active_conflict || !mod_node_config_save(&next)) { status_reply(req, req->info.command.id, 3); break; }
        int8_t old_gpio = s_cfg.status_led_gpio; bool old_active_low = s_cfg.status_led_active_low;
        s_cfg = next; status_led_reconfigure(old_gpio, old_active_low);
        status_reply(req, req->info.command.id, 0); break;
    }
    default: status_reply(req, req->info.command.id, 1); break;
    }
}

static esp_err_t action_handler(esp_zb_core_action_callback_id_t id, const void *message) {
    if (!message) return ESP_OK;
    ESP_LOGD(TAG, "Zigbee callback 0x%x", (unsigned)id);
    if (id == ESP_ZB_CORE_CMD_CUSTOM_CLUSTER_REQ_CB_ID) { config_command(message); return ESP_OK; }
    if (id != ESP_ZB_CORE_SET_ATTR_VALUE_CB_ID) return ESP_OK;
    const esp_zb_zcl_set_attr_value_message_t *m = message;
    if (m->info.status == ESP_ZB_ZCL_STATUS_SUCCESS && m->info.cluster == ESP_ZB_ZCL_CLUSTER_ID_ON_OFF &&
        m->attribute.id == ESP_ZB_ZCL_ATTR_ON_OFF_ON_OFF_ID && m->attribute.data.value && m->info.dst_endpoint >= FIRST_CHANNEL_EP) {
        unsigned i = m->info.dst_endpoint - FIRST_CHANNEL_EP;
        if (i < s_cfg.channel_count) output_set(i, *(const bool *)m->attribute.data.value);
    }
    return ESP_OK;
}
static void retry_steering(uint8_t mode) { ESP_ERROR_CHECK(esp_zb_bdb_start_top_level_commissioning(mode)); }
void esp_zb_app_signal_handler(esp_zb_app_signal_t *s) {
    esp_zb_app_signal_type_t t = *(s->p_app_signal); esp_err_t e = s->esp_err_status;
    switch (t) {
    case ESP_ZB_ZDO_SIGNAL_SKIP_STARTUP: ESP_ERROR_CHECK(esp_zb_bdb_start_top_level_commissioning(ESP_ZB_BDB_MODE_INITIALIZATION)); break;
    case ESP_ZB_BDB_SIGNAL_DEVICE_FIRST_START: case ESP_ZB_BDB_SIGNAL_DEVICE_REBOOT:
        status_led_set(false);
        if (e == ESP_OK && esp_zb_bdb_is_factory_new()) {
            ESP_ERROR_CHECK(esp_zb_bdb_start_top_level_commissioning(ESP_ZB_BDB_MODE_NETWORK_STEERING));
        }
        break;
    case ESP_ZB_BDB_SIGNAL_STEERING:
        if (e == ESP_OK) {
            status_led_set(false);
            ESP_LOGI(TAG, "Joined PAN 0x%04x channel %u", esp_zb_get_pan_id(), esp_zb_get_current_channel());
        } else {
            status_led_set(false);
            esp_zb_scheduler_alarm((esp_zb_callback_t)retry_steering, ESP_ZB_BDB_MODE_NETWORK_STEERING, 1000);
        }
        break;
    default: break;
    }
}

static void status_task(void *arg) {
    (void)arg;
    for (;;) {
        const TickType_t now = xTaskGetTickCount();
        if (s_hub_seen == 0 || now - s_hub_seen > pdMS_TO_TICKS(6000)) status_led_set(false);
        vTaskDelay(pdMS_TO_TICKS(500));
    }
}

static void report_digital_input(unsigned i, bool value)
{
    esp_zb_lock_acquire(portMAX_DELAY);
    esp_zb_zcl_set_attribute_val(FIRST_CHANNEL_EP + i,
        ESP_ZB_ZCL_CLUSTER_ID_BINARY_INPUT, ESP_ZB_ZCL_CLUSTER_SERVER_ROLE,
        ESP_ZB_ZCL_ATTR_BINARY_INPUT_PRESENT_VALUE_ID, &value, false);
    if (esp_zb_bdb_dev_joined()) {
        esp_zb_zcl_report_attr_cmd_t report = {
            .zcl_basic_cmd = {.dst_addr_u.addr_short = 0, .dst_endpoint = 1,
                              .src_endpoint = FIRST_CHANNEL_EP + i},
            .address_mode = ESP_ZB_APS_ADDR_MODE_16_ENDP_PRESENT,
            .clusterID = ESP_ZB_ZCL_CLUSTER_ID_BINARY_INPUT,
            .direction = ESP_ZB_ZCL_CMD_DIRECTION_TO_CLI,
            .dis_default_resp = 1,
            .attributeID = ESP_ZB_ZCL_ATTR_BINARY_INPUT_PRESENT_VALUE_ID,
        };
        esp_err_t err = esp_zb_zcl_report_attr_cmd_req(&report);
        if (err != ESP_OK) ESP_LOGW(TAG, "Digital input report: %s", esp_err_to_name(err));
    }
    esp_zb_lock_release();
}

static void digital_input_task(void *arg)
{
    (void)arg;
    bool candidate[MOD_NODE_CHANNEL_MAX] = {0};
    bool stable[MOD_NODE_CHANNEL_MAX] = {0};
    uint8_t consecutive[MOD_NODE_CHANNEL_MAX] = {0};
    bool initialized[MOD_NODE_CHANNEL_MAX] = {0};
    TickType_t last_report[MOD_NODE_CHANNEL_MAX] = {0};
    for (;;) {
        for (unsigned i = 0; i < s_runtime.channel_count; ++i) {
            const mod_node_channel_t *c = &s_runtime.channel[i];
            if (c->type != MOD_NODE_CH_DIGITAL_INPUT) continue;
            bool value = gpio_get_level((gpio_num_t)c->gpio) != 0;
            if (c->active_low) value = !value;
            if (value != candidate[i]) {
                candidate[i] = value;
                consecutive[i] = 1;
            } else if (consecutive[i] < 3) {
                consecutive[i]++;
            }
            /* Three equal 20 ms samples suppress contact bounce and noise.
             * The first report is deliberately delayed by the same 60 ms. */
            const TickType_t now = xTaskGetTickCount();
            if (consecutive[i] == 3 && (!initialized[i] || stable[i] != candidate[i] ||
                now - last_report[i] >= pdMS_TO_TICKS(10000))) {
                initialized[i] = true;
                stable[i] = candidate[i];
                last_report[i] = now;
                report_digital_input(i, stable[i]);
            }
        }
        vTaskDelay(pdMS_TO_TICKS(20));
    }
}

static void temperature_task(void *arg) {
    (void)arg;
    TickType_t last[MOD_NODE_CHANNEL_MAX] = {0};
    bool sampled[MOD_NODE_CHANNEL_MAX] = {false};
    for (;;) {
        for (unsigned i=0; i<s_runtime.channel_count; ++i) {
            if (s_runtime.channel[i].type != MOD_NODE_CH_DS18B20) continue;
            TickType_t now = xTaskGetTickCount();
            if (sampled[i] && now-last[i] < pdMS_TO_TICKS(s_runtime.poll_interval_s[i]*1000u)) continue;
            sampled[i] = true; last[i] = now;
            int16_t value = MOD_NODE_TEMP_INVALID;
            uint8_t sensor_index = 0;
            for (unsigned j=0; j<i; ++j) {
                if (s_runtime.channel[j].type == MOD_NODE_CH_DS18B20 &&
                    s_runtime.channel[j].gpio == s_runtime.channel[i].gpio) sensor_index++;
            }
            uint8_t found_rom[8] = {0};
            esp_err_t err = mod_node_temperature_read(s_runtime.channel[i].gpio, sensor_index,
                s_runtime.sensor_rom[i], found_rom, &value);
            bool was_unbound=true; for(int b=0;b<8;b++) was_unbound &= s_runtime.sensor_rom[i][b]==0;
            if (err==ESP_OK && was_unbound) {
                memcpy(s_runtime.sensor_rom[i], found_rom, 8);
                memcpy(s_cfg.sensor_rom[i], found_rom, 8);
                if (!mod_node_config_save(&s_cfg)) ESP_LOGW(TAG, "Could not persist sensor ROM for channel %u", i+1);
                else ESP_LOGI(TAG, "Bound channel %u to DS18B20 %02x%02x..%02x%02x", i+1,
                    found_rom[0], found_rom[1], found_rom[6], found_rom[7]);
            }
            if (err != ESP_OK) ESP_LOGW(TAG, "Temperature channel %u GPIO%d: %s", i+1, s_runtime.channel[i].gpio, esp_err_to_name(err));
            esp_zb_lock_acquire(portMAX_DELAY);
            esp_zb_zcl_set_attribute_val(FIRST_CHANNEL_EP+i, 0x0402, ESP_ZB_ZCL_CLUSTER_SERVER_ROLE, 0, &value, false);
            if (esp_zb_bdb_dev_joined()) {
                esp_zb_zcl_report_attr_cmd_t report = {
                    .zcl_basic_cmd = {.dst_addr_u.addr_short=0, .dst_endpoint=1, .src_endpoint=FIRST_CHANNEL_EP+i},
                    .address_mode=ESP_ZB_APS_ADDR_MODE_16_ENDP_PRESENT, .clusterID=0x0402,
                    .direction=ESP_ZB_ZCL_CMD_DIRECTION_TO_CLI, .dis_default_resp=1, .attributeID=0};
                esp_err_t sent = esp_zb_zcl_report_attr_cmd_req(&report);
                if (sent != ESP_OK) ESP_LOGW(TAG, "Temperature report: %s", esp_err_to_name(sent));
            }
            esp_zb_lock_release();
        }
        vTaskDelay(pdMS_TO_TICKS(100));
    }
}

static void zigbee_task(void *arg) {
    (void)arg;
    esp_zb_cfg_t z = {.esp_zb_role = ESP_ZB_DEVICE_TYPE_ROUTER, .install_code_policy = false, .nwk_cfg.zczr_cfg = {.max_children = 16}};
    esp_zb_init(&z); esp_zb_ep_list_t *eps = esp_zb_ep_list_create();
    static uint8_t version = PROTOCOL_VERSION;
    esp_zb_attribute_list_t *attrs = esp_zb_zcl_attr_list_create(MOD_NODE_CONFIG_CLUSTER);
    ESP_ERROR_CHECK(esp_zb_custom_cluster_add_custom_attr(attrs, 0, ESP_ZB_ZCL_ATTR_TYPE_U8, ESP_ZB_ZCL_ATTR_ACCESS_READ_ONLY, &version));
    esp_zb_cluster_list_t *config_clusters = esp_zb_zcl_cluster_list_create();
    ESP_ERROR_CHECK(esp_zb_cluster_list_add_custom_cluster(config_clusters, attrs, ESP_ZB_ZCL_CLUSTER_SERVER_ROLE));
    esp_zb_endpoint_config_t config_ep = {.endpoint = MOD_NODE_CONFIG_EP, .app_profile_id = ESP_ZB_AF_HA_PROFILE_ID, .app_device_id = 0xFFF0, .app_device_version = 1};
    ESP_ERROR_CHECK(esp_zb_ep_list_add_ep(eps, config_clusters, config_ep));
    for (unsigned i = 0; i < s_cfg.channel_count; i++) {
        if (s_runtime.channel[i].type == MOD_NODE_CH_DS18B20) {
            esp_zb_temperature_sensor_cfg_t temp = ESP_ZB_DEFAULT_TEMPERATURE_SENSOR_CONFIG();
            temp.temp_meas_cfg.measured_value=MOD_NODE_TEMP_INVALID;
            temp.temp_meas_cfg.min_value=-5500;
            temp.temp_meas_cfg.max_value=12500;
            esp_zb_cluster_list_t *clusters = esp_zb_temperature_sensor_clusters_create(&temp);
            esp_zb_endpoint_config_t ep = {.endpoint=FIRST_CHANNEL_EP+i,
                .app_profile_id=ESP_ZB_AF_HA_PROFILE_ID, .app_device_id=0x0302, .app_device_version=1};
            ESP_ERROR_CHECK(esp_zb_ep_list_add_ep(eps, clusters, ep));
            continue;
        }
        if (s_runtime.channel[i].type == MOD_NODE_CH_DIGITAL_INPUT) {
            esp_zb_binary_input_cluster_cfg_t input = {
                .out_of_service = false, .status_flags = 0, .present_value = false};
            esp_zb_cluster_list_t *clusters = esp_zb_zcl_cluster_list_create();
            ESP_ERROR_CHECK(esp_zb_cluster_list_add_binary_input_cluster(clusters,
                esp_zb_binary_input_cluster_create(&input), ESP_ZB_ZCL_CLUSTER_SERVER_ROLE));
            esp_zb_endpoint_config_t ep = {.endpoint = FIRST_CHANNEL_EP + i,
                .app_profile_id = ESP_ZB_AF_HA_PROFILE_ID,
                .app_device_id = ESP_ZB_HA_SIMPLE_SENSOR_DEVICE_ID, .app_device_version = 1};
            ESP_ERROR_CHECK(esp_zb_ep_list_add_ep(eps, clusters, ep));
            continue;
        }
        if (!is_output(&s_runtime.channel[i])) continue;
        esp_zb_on_off_light_cfg_t light = ESP_ZB_DEFAULT_ON_OFF_LIGHT_CONFIG(); light.on_off_cfg.on_off = s_cfg.channel[i].boot_on;
        esp_zb_cluster_list_t *clusters = esp_zb_on_off_light_clusters_create(&light);
        esp_zb_endpoint_config_t ep = {.endpoint = FIRST_CHANNEL_EP + i, .app_profile_id = ESP_ZB_AF_HA_PROFILE_ID,
            .app_device_id = s_runtime.channel[i].type == MOD_NODE_CH_DIGITAL_OUTPUT ?
                ESP_ZB_HA_ON_OFF_OUTPUT_DEVICE_ID : ESP_ZB_HA_ON_OFF_LIGHT_DEVICE_ID,
            .app_device_version = 1};
        ESP_ERROR_CHECK(esp_zb_ep_list_add_ep(eps, clusters, ep));
    }
    ESP_ERROR_CHECK(esp_zb_device_register(eps)); esp_zb_core_action_handler_register(action_handler);
    esp_zb_set_primary_network_channel_set(ESP_ZB_TRANSCEIVER_ALL_CHANNELS_MASK); ESP_ERROR_CHECK(esp_zb_start(false));
    configASSERT(xTaskCreate(temperature_task, "node_temp", 4096, NULL, 3, NULL) == pdPASS);
    configASSERT(xTaskCreate(digital_input_task, "node_input", 3072, NULL, 3, NULL) == pdPASS);
    esp_zb_stack_main_loop();
}
void app_main(void) {
    esp_err_t e = nvs_flash_init(); if (e == ESP_ERR_NVS_NO_FREE_PAGES || e == ESP_ERR_NVS_NEW_VERSION_FOUND) { ESP_ERROR_CHECK(nvs_flash_erase()); e = nvs_flash_init(); } ESP_ERROR_CHECK(e);
    (void)esp_ota_mark_app_valid_cancel_rollback(); mod_node_config_load(&s_cfg); s_runtime = s_cfg;
    if (s_cfg.status_led_gpio >= 0 && mod_node_status_led_gpio_allowed(s_cfg.status_led_gpio)) {
        gpio_config_t status_led = {.pin_bit_mask = 1ULL << s_cfg.status_led_gpio, .mode = GPIO_MODE_OUTPUT};
        ESP_ERROR_CHECK(gpio_config(&status_led));
    }
    status_led_set(false);
    xTaskCreate(status_task, "node_status", 2048, NULL, 4, NULL);
    for (unsigned i = 0; i < s_cfg.channel_count; i++) { mod_node_channel_t *c = &s_cfg.channel[i]; if (!is_output(c) || c->gpio < 0 || !mod_node_gpio_allowed(c->gpio)) continue;
        gpio_config_t io = {.pin_bit_mask = 1ULL << c->gpio, .mode = GPIO_MODE_OUTPUT}; output_set(i, c->boot_on); ESP_ERROR_CHECK(gpio_config(&io)); }
    for (unsigned i = 0; i < s_runtime.channel_count; ++i) {
        mod_node_channel_t *c = &s_runtime.channel[i];
        if (c->type != MOD_NODE_CH_DIGITAL_INPUT || c->gpio < 0) continue;
        gpio_config_t io = {.pin_bit_mask = 1ULL << c->gpio, .mode = GPIO_MODE_INPUT,
            .pull_up_en = c->pull_up ? GPIO_PULLUP_ENABLE : GPIO_PULLUP_DISABLE,
            .pull_down_en = GPIO_PULLDOWN_DISABLE};
        ESP_ERROR_CHECK(gpio_config(&io));
    }
    esp_zb_platform_config_t p = {.radio_config = {.radio_mode = ZB_RADIO_MODE_NATIVE}, .host_config = {.host_connection_mode = ZB_HOST_CONNECTION_MODE_NONE}};
    ESP_ERROR_CHECK(esp_zb_platform_config(&p)); ESP_LOGI(TAG, "%s: %u channels", s_cfg.device_name, s_cfg.channel_count); xTaskCreate(zigbee_task, "zigbee", 7168, NULL, 5, NULL);
}
