#include "nano_ota_shim.h"
#include "storage_shim.h"
#include "zb_link_proto.h"
#include "zb_uart_host.h"

#include <dirent.h>
#include <stdio.h>
#include <stdlib.h>
#include <strings.h>
#include <string.h>
#include <sys/stat.h>
#include "esp_app_desc.h"
#include "esp_app_format.h"
#include "esp_crc.h"
#include "freertos/FreeRTOS.h"
#include "freertos/portmacro.h"
#include "freertos/task.h"

#define USB_ROOT "/usb"
#define DATA_SIZE 240
#define IMAGE_MAX (1856U * 1024U)
static modulus_nano_ota_snapshot_t s = {.status="Open this page to scan USB. Nothing flashes automatically."};
static portMUX_TYPE lock = portMUX_INITIALIZER_UNLOCKED;
static bool running;
static char paths[MODULUS_NANO_OTA_MAX_FILES][192];
static char versions[MODULUS_NANO_OTA_MAX_FILES][32];
static char armed[192];
static size_t armed_size;

static void put32(uint8_t *p, uint32_t v) { p[0]=v>>24; p[1]=v>>16; p[2]=v>>8; p[3]=v; }
static void set_status(modulus_nano_ota_phase_t p, const char *text) {
    taskENTER_CRITICAL(&lock); s.phase=p; snprintf(s.status,sizeof(s.status),"%s",text); taskEXIT_CRITICAL(&lock);
}
static bool safe_name(const char *n) {
    if (!n || !*n || strlen(n)>=MODULUS_NANO_OTA_NAME_LEN || strstr(n,"..") || strchr(n,'/') || strchr(n,'\\')) return false;
    size_t z=strlen(n); return z>4 && strcasecmp(n+z-4,".bin")==0;
}
static bool inspect(const char *path, size_t *size, esp_app_desc_t *desc) {
    struct stat st={0}; if (stat(path,&st) || st.st_size<=0 || (uint64_t)st.st_size>IMAGE_MAX) return false;
    FILE *f=fopen(path,"rb"); if (!f) return false;
    esp_image_header_t h={0}; esp_image_segment_header_t seg={0}; esp_app_desc_t d={0};
    bool ok=fread(&h,1,sizeof(h),f)==sizeof(h) && fread(&seg,1,sizeof(seg),f)==sizeof(seg) && fread(&d,1,sizeof(d),f)==sizeof(d);
    fclose(f); if (!ok || h.magic!=ESP_IMAGE_HEADER_MAGIC || h.chip_id!=ESP_CHIP_ID_ESP32H2 || d.magic_word!=ESP_APP_DESC_MAGIC_WORD) return false;
    *size=st.st_size; *desc=d; return true;
}
void modulus_nano_ota_get_snapshot(modulus_nano_ota_snapshot_t *out) {
    if (!out) return;
    taskENTER_CRITICAL(&lock);
    *out = s;
    taskEXIT_CRITICAL(&lock);
    /* Link readiness changes independently of USB scans and UI actions. */
    out->nano_connected = modulus_zb_uart_ready();
}
void modulus_nano_ota_refresh(void) {
    if (running) return;
    modulus_nano_ota_snapshot_t n={.phase=MODULUS_NANO_OTA_READY};
    /* Refresh is an explicit user action: actively prove both UART directions
     * with a harmless sequenced command instead of trusting passive traffic. */
    const uint8_t probe[] = {ZIGBEE_CMD_GET_STATE};
    n.nano_connected=modulus_zb_uart_send_cmd_sync(probe,sizeof(probe));
    snprintf(n.nano_version,sizeof(n.nano_version),"UART OTA v1");
    memset(paths,0,sizeof(paths)); memset(versions,0,sizeof(versions));
    DIR *d=modulus_storage_usb_volume_mounted()?opendir(USB_ROOT):NULL;
    if(d){struct dirent *e;while((e=readdir(d)) && n.file_count<MODULUS_NANO_OTA_MAX_FILES){
        if(!safe_name(e->d_name)) continue;
        char p[192];
        const size_t name_len = strlen(e->d_name);
        if (sizeof(USB_ROOT) + name_len >= sizeof(p)) continue;
        memcpy(p, USB_ROOT "/", sizeof(USB_ROOT));
        memcpy(p + sizeof(USB_ROOT), e->d_name, name_len + 1);
        size_t z;
        esp_app_desc_t a={0};
        if(!inspect(p,&z,&a)) continue;
        uint8_t i=n.file_count++;snprintf(n.files[i],sizeof(n.files[i]),"USB: %.90s",e->d_name);snprintf(paths[i],sizeof(paths[i]),"%s",p);snprintf(versions[i],sizeof(versions[i]),"%s",a.version);
    }closedir(d);}
    if(n.file_count)snprintf(n.image_version,sizeof(n.image_version),"%s",versions[0]);
    if(!n.nano_connected){n.phase=MODULUS_NANO_OTA_ERROR;snprintf(n.status,sizeof(n.status),"NanoH2 is not responding over UART.");}
    else if(!d){n.phase=MODULUS_NANO_OTA_ERROR;snprintf(n.status,sizeof(n.status),"Insert a FAT USB drive, wait for mount, then refresh.");}
    else if(!n.file_count)snprintf(n.status,sizeof(n.status),"No valid ESP32-H2 app images found in USB root.");
    else snprintf(n.status,sizeof(n.status),"%u NanoH2 image(s) found. Select and check one.",n.file_count);
    taskENTER_CRITICAL(&lock);s=n;armed[0]=0;armed_size=0;taskEXIT_CRITICAL(&lock);
}
void modulus_nano_ota_select(uint8_t i){taskENTER_CRITICAL(&lock);if(!running&&i<s.file_count){s.selected=i;s.phase=MODULUS_NANO_OTA_READY;snprintf(s.image_version,sizeof(s.image_version),"%s",versions[i]);snprintf(s.status,sizeof(s.status),"Selected %s. Check before flashing.",s.files[i]);armed[0]=0;}taskEXIT_CRITICAL(&lock);}
void modulus_nano_ota_arm_selected(void){modulus_nano_ota_snapshot_t n;modulus_nano_ota_get_snapshot(&n);if(running||!n.nano_connected||n.selected>=n.file_count)return;size_t z;esp_app_desc_t d={0};if(!inspect(paths[n.selected],&z,&d)){set_status(MODULUS_NANO_OTA_ERROR,"Rejected: not a valid ESP32-H2 app image.");return;}taskENTER_CRITICAL(&lock);snprintf(armed,sizeof(armed),"%s",paths[n.selected]);armed_size=z;s.phase=MODULUS_NANO_OTA_ARMED;s.progress=0;snprintf(s.status,sizeof(s.status),"Checked %.48s, version %.24s, %u bytes. Flash armed.",n.files[n.selected],d.version,(unsigned)z);taskEXIT_CRITICAL(&lock);}
static void worker(void *arg){(void)arg;char path[192];size_t total;taskENTER_CRITICAL(&lock);snprintf(path,sizeof(path),"%s",armed);total=armed_size;s.phase=MODULUS_NANO_OTA_FLASHING;s.progress=0;taskEXIT_CRITICAL(&lock);modulus_zb_uart_set_ota_mode(true);
    FILE *f=fopen(path,"rb");uint8_t cmd[1+8+DATA_SIZE];bool ok=f!=NULL;size_t sent=0;if(ok){cmd[0]=ZIGBEE_CMD_OTA_BEGIN;put32(cmd+1,total);ok=modulus_zb_uart_send_cmd_sync(cmd,5);}
    while(ok&&sent<total){size_t z=total-sent;if(z>DATA_SIZE)z=DATA_SIZE;if(fread(cmd+9,1,z,f)!=z){ok=false;break;}cmd[0]=ZIGBEE_CMD_OTA_DATA;put32(cmd+1,sent);put32(cmd+5,esp_crc32_le(UINT32_MAX,cmd+9,z));ok=modulus_zb_uart_send_cmd_sync(cmd,9+z);if(ok){sent+=z;taskENTER_CRITICAL(&lock);s.progress=(uint8_t)(sent*100U/total);taskEXIT_CRITICAL(&lock);}}
    if(ok){cmd[0]=ZIGBEE_CMD_OTA_END;ok=modulus_zb_uart_send_cmd_sync(cmd,1);}if(f)fclose(f);
    if(ok){cmd[0]=ZIGBEE_CMD_OTA_REBOOT;ok=modulus_zb_uart_send_cmd_sync(cmd,1);}
    if(ok){taskENTER_CRITICAL(&lock);s.phase=MODULUS_NANO_OTA_SUCCESS;s.progress=100;s.nano_connected=false;snprintf(s.status,sizeof(s.status),"NanoH2 image verified. Restarting into the new OTA slot.");taskEXIT_CRITICAL(&lock);}else{char msg[160];snprintf(msg,sizeof(msg),"NanoH2 OTA failed at %u/%u bytes; current slot remains active.",(unsigned)sent,(unsigned)total);set_status(MODULUS_NANO_OTA_ERROR,msg);}modulus_zb_uart_set_ota_mode(false);running=false;vTaskDelete(NULL);}
void modulus_nano_ota_start(void){modulus_nano_ota_snapshot_t n;modulus_nano_ota_get_snapshot(&n);if(running||n.phase!=MODULUS_NANO_OTA_ARMED||!armed[0])return;running=true;if(xTaskCreate(worker,"nano_ota_host",8192,NULL,4,NULL)!=pdPASS){running=false;set_status(MODULUS_NANO_OTA_ERROR,"Could not start NanoH2 update worker.");}}
void modulus_nano_ota_restart(void){uint8_t cmd=ZIGBEE_CMD_OTA_REBOOT;if(s.phase==MODULUS_NANO_OTA_SUCCESS)(void)modulus_zb_uart_send_cmd(&cmd,1);}
