#include "node_config.h"
#include "nvs.h"
#include <stdio.h>
#include <string.h>
#define CFG_SCHEMA 4
#define CFG_NS "modnode"
typedef struct { uint16_t schema_version; char device_name[MOD_NODE_NAME_MAX]; uint8_t channel_count;
 mod_node_channel_t channel[MOD_NODE_CHANNEL_MAX]; } mod_node_config_v2_t;
typedef struct { uint16_t schema_version; char device_name[MOD_NODE_NAME_MAX]; uint8_t channel_count;
 int8_t status_led_gpio; bool status_led_active_low;
 mod_node_channel_t channel[MOD_NODE_CHANNEL_MAX]; } mod_node_config_v3_t;
bool mod_node_gpio_allowed(int gpio) {
    /* XIAO ESP32-C6 D0-D10 headers. Keep RF-switch GPIO3/14,
     * boot/strapping, USB, flash and the status LED away from channels. */
    switch (gpio) {
    case 0: case 1: case 2: case 16: case 17: case 18:
    case 19: case 20: case 21: case 22: case 23: return true;
    default: return false;
    }
}
bool mod_node_status_led_gpio_allowed(int gpio) {
    return gpio == 15 || mod_node_gpio_allowed(gpio);
}
static void defaults(mod_node_config_t *cfg) {
    memset(cfg,0,sizeof(*cfg)); cfg->schema_version=CFG_SCHEMA; strcpy(cfg->device_name,"Modulus Zigbee Node"); cfg->channel_count=4; cfg->status_led_gpio=15; cfg->status_led_active_low=true;
    for(int i=0;i<MOD_NODE_CHANNEL_MAX;i++) cfg->poll_interval_s[i]=MOD_NODE_POLL_DEFAULT_S;
    for(int i=0;i<4;i++){ cfg->channel[i].type=MOD_NODE_CH_SWITCH; cfg->channel[i].gpio=-1; snprintf(cfg->channel[i].name,sizeof(cfg->channel[i].name),"Switch %d",i+1); }
}
void mod_node_config_load(mod_node_config_t *cfg) {
    defaults(cfg); nvs_handle_t h; if(nvs_open(CFG_NS,NVS_READONLY,&h)!=ESP_OK)return; size_t n=0;
    if(nvs_get_blob(h,"config",NULL,&n)==ESP_OK && n==sizeof(mod_node_config_v2_t)) {
        mod_node_config_v2_t old;
        if(nvs_get_blob(h,"config",&old,&n)==ESP_OK && old.schema_version==2 && old.channel_count<=MOD_NODE_CHANNEL_MAX) {
            memcpy(cfg->device_name,old.device_name,sizeof(cfg->device_name)); cfg->channel_count=old.channel_count;
            memcpy(cfg->channel,old.channel,sizeof(cfg->channel));
        }
        if (!mod_node_config_valid(cfg)) defaults(cfg);
        nvs_close(h); return;
    }
    if(n==sizeof(mod_node_config_v3_t)) {
        mod_node_config_v3_t old;
        if(nvs_get_blob(h,"config",&old,&n)==ESP_OK && old.schema_version==3) {
            memcpy(cfg->device_name,old.device_name,sizeof(cfg->device_name));
            cfg->channel_count=old.channel_count;
            cfg->status_led_gpio=old.status_led_gpio;
            cfg->status_led_active_low=old.status_led_active_low;
            memcpy(cfg->channel,old.channel,sizeof(cfg->channel));
        }
        if (!mod_node_config_valid(cfg)) defaults(cfg);
        nvs_close(h); return;
    }
    n=sizeof(*cfg); mod_node_config_t v;
    if(nvs_get_blob(h,"config",&v,&n)==ESP_OK&&n==sizeof(v)&&v.schema_version==CFG_SCHEMA&&mod_node_config_valid(&v)) {
        *cfg=v;
    }
    nvs_close(h);
}
bool mod_node_config_valid(const mod_node_config_t *cfg) {
    if(!cfg||!cfg->device_name[0]||cfg->channel_count>MOD_NODE_CHANNEL_MAX) return false;
    if (!memchr(cfg->device_name,0,sizeof(cfg->device_name))) return false;
    for (int i=0;i<cfg->channel_count;i++) {
        if (cfg->channel[i].type>MOD_NODE_CH_DS18B20 || cfg->channel[i].gpio < -1 ||
            !memchr(cfg->channel[i].name,0,sizeof(cfg->channel[i].name)) ||
            cfg->poll_interval_s[i]<MOD_NODE_POLL_MIN_S || cfg->poll_interval_s[i]>MOD_NODE_POLL_MAX_S) return false;
    }
    if (cfg->status_led_gpio < -1) return false;
    bool used[31]={0};
    if(cfg->status_led_gpio >= 0) { if(!mod_node_status_led_gpio_allowed(cfg->status_led_gpio)) return false; used[cfg->status_led_gpio]=true; }
    for(int i=0;i<cfg->channel_count;i++){int g=cfg->channel[i].gpio;if(cfg->channel[i].type==0||g<0)continue;if(!mod_node_gpio_allowed(g)||used[g])return false;used[g]=true;}
    return true;
}
bool mod_node_config_save(const mod_node_config_t *cfg) {
    if (!mod_node_config_valid(cfg)) return false;
    nvs_handle_t h;if(nvs_open(CFG_NS,NVS_READWRITE,&h)!=ESP_OK)return false;esp_err_t e=nvs_set_blob(h,"config",cfg,sizeof(*cfg));if(e==ESP_OK)e=nvs_commit(h);nvs_close(h);return e==ESP_OK;
}
