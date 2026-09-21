#include <assert.h>
#include <stdio.h>
#include <string.h>
#include "../main/node_config.c"
#include "../main/node_temperature_decode.h"

static unsigned char blob[1024];
static size_t blob_size;
int nvs_open(const char *n, int m, nvs_handle_t *h) { (void)n; (void)m; *h=1; return 0; }
int nvs_get_blob(nvs_handle_t h, const char *k, void *p, size_t *n) {
    (void)h; (void)k;
    if (!p) { *n=blob_size; return 0; }
    if (*n<blob_size) return -1;
    memcpy(p,blob,blob_size); *n=blob_size; return 0;
}
int nvs_set_blob(nvs_handle_t h, const char *k, const void *p, size_t n) {
    (void)h; (void)k; assert(n<=sizeof(blob)); memcpy(blob,p,n); blob_size=n; return 0;
}
int nvs_commit(nvs_handle_t h) { (void)h; return 0; }
void nvs_close(nvs_handle_t h) { (void)h; }

static void sample(int raw, int expected) {
    uint8_t s[9]={(uint8_t)raw,(uint8_t)(raw>>8),0,0,0x7f,0xff,0,0x10,0};
    s[8]=mod_node_crc8(s,8);
    int16_t value;
    assert(mod_node_temperature_decode(s,&value)); assert(value==expected);
    s[0]^=1;
    assert(!mod_node_temperature_decode(s,&value)); assert(value==INT16_MIN);
}
int main(void) {
    sample(0,0); sample(1,6); sample(-1,-6); sample(401,2506);
    sample(-161,-1006); sample(-880,-5500); sample(2000,12500);
    sample(1360,8500); /* A completed real 85 C sample is valid. */
    uint8_t bad[9]={0}; int16_t value;
    assert(!mod_node_temperature_decode(bad,&value));
    uint8_t startup[9]={0x50,0x05,0,0,0x7f,0xff,0x0c,0x10,0};
    startup[8]=mod_node_crc8(startup,8);
    assert(!mod_node_temperature_decode(startup,&value));
    startup[0]=0xd1; startup[1]=7; startup[6]=0; startup[8]=mod_node_crc8(startup,8);
    assert(!mod_node_temperature_decode(startup,&value)); /* 125.0625 C */

    mod_node_config_t cfg, loaded;
    mod_node_config_load(&cfg); assert(cfg.poll_interval_s[0]==15);
    cfg.channel[0].type=MOD_NODE_CH_DS18B20; cfg.channel[0].gpio=22;
    cfg.channel[1].type=MOD_NODE_CH_DS18B20; cfg.channel[1].gpio=23;
    cfg.poll_interval_s[0]=60; cfg.poll_interval_s[1]=3600;
    assert(mod_node_config_save(&cfg)); mod_node_config_load(&loaded);
    assert(loaded.poll_interval_s[0]==60 && loaded.poll_interval_s[1]==3600);
    assert(loaded.sensor_rom[0][0]==0);
    cfg.poll_interval_s[0]=14; assert(!mod_node_config_save(&cfg));
    cfg.poll_interval_s[0]=3601; assert(!mod_node_config_save(&cfg));
    cfg.poll_interval_s[0]=15;
    cfg.channel[1].gpio=22; assert(mod_node_config_save(&cfg)); /* shared OneWire bus */
    cfg.channel[1].type=MOD_NODE_CH_SWITCH; assert(!mod_node_config_save(&cfg));
    cfg.channel[1].gpio=15; assert(!mod_node_config_save(&cfg));
    cfg.channel[1].gpio=12; assert(!mod_node_config_save(&cfg));
    cfg.channel[1].gpio=3; assert(!mod_node_config_save(&cfg));
    cfg.channel[1].gpio=14; assert(!mod_node_config_save(&cfg));
    cfg.channel[1].gpio=23; assert(mod_node_config_valid(&cfg));
    cfg.channel[1].type=5; assert(!mod_node_config_valid(&cfg));
    cfg.channel[1].type=MOD_NODE_CH_DIGITAL_INPUT;
    cfg.channel[1].pull_up=true; cfg.channel[1].active_low=true;
    assert(mod_node_config_valid(&cfg));

    mod_node_config_v3_t old={0};
    old.schema_version=3; strcpy(old.device_name,"Existing node"); old.channel_count=4;
    old.status_led_gpio=15; old.status_led_active_low=true;
    memcpy(old.channel,cfg.channel,sizeof(old.channel));
    nvs_set_blob(1,"config",&old,sizeof(old)); mod_node_config_load(&loaded);
    assert(!strcmp(loaded.device_name,"Existing node")); assert(loaded.channel[0].gpio==22);
    assert(loaded.poll_interval_s[0]==15 && loaded.status_led_active_low);
    assert(loaded.schema_version==5);
    mod_node_config_v2_t older={0}; older.schema_version=2; older.channel_count=4;
    strcpy(older.device_name,"Older node"); memcpy(older.channel,cfg.channel,sizeof(older.channel));
    nvs_set_blob(1,"config",&older,sizeof(older)); mod_node_config_load(&loaded);
    assert(!strcmp(loaded.device_name,"Older node")); assert(loaded.poll_interval_s[3]==15);
    assert(loaded.status_led_gpio==15);
    older.channel[1].gpio=22;
    nvs_set_blob(1,"config",&older,sizeof(older)); mod_node_config_load(&loaded);
    assert(loaded.channel[0].gpio==-1); /* Bad persisted conflicts fall back safely. */
    puts("PASS: signed temperatures, CRC, startup/range errors, poll bounds, GPIO conflicts, persistence and v2/v3 migration");
}
