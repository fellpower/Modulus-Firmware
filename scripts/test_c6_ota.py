"""Host regression tests for the real C6 OTA shim; no firmware build or hardware.
Run: python scripts/test_c6_ota.py (requires zig on PATH).
ESP-Hosted and FreeRTOS are mocked; file reads and the worker are real.
"""
from pathlib import Path
import os
import subprocess

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'dist' / 'tests' / 'c6-ota'
OUT.mkdir(parents=True, exist_ok=True)
STUB = r'''
#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
typedef int esp_err_t;
#define ESP_OK 0
#define ESP_FAIL -1
#define ESP_ERR_NO_MEM 1
#define ESP_ERR_NOT_FOUND 2
#define ESP_ERR_INVALID_SIZE 3
#define ESP_ERR_INVALID_ARG 4
#define ESP_IMAGE_HEADER_MAGIC 0xe9
#define ESP_CHIP_ID_ESP32C6 13
#define ESP_APP_DESC_MAGIC_WORD 0xabcd5432
/* Only image scanner fields are needed; worker tests use a pre-armed file. */
typedef struct { unsigned magic, chip_id; } esp_image_header_t;
typedef struct { unsigned size; } esp_image_segment_header_t;
typedef struct { unsigned magic_word; char version[32]; } esp_app_desc_t;
typedef struct { uint32_t major1, minor1, patch1; } esp_hosted_coprocessor_fwver_t;
typedef int portMUX_TYPE;
#define portMUX_INITIALIZER_UNLOCKED 0
#define taskENTER_CRITICAL(x) ((void)(x))
#define taskEXIT_CRITICAL(x) ((void)(x))
#define pdMS_TO_TICKS(x) (x)
#define pdPASS 1
#define ESP_LOGI(...) ((void)0)
#define ESP_LOGE(...) ((void)0)
#define ESP_LOGW(...) ((void)0)
int esp_hosted_get_coprocessor_fwversion(esp_hosted_coprocessor_fwver_t *);
int esp_hosted_slave_ota_begin(void);
int esp_hosted_slave_ota_write(uint8_t *, uint32_t);
int esp_hosted_slave_ota_end(void);
int esp_hosted_slave_ota_activate(void);
const char *esp_err_to_name(int);
void esp_restart(void);
void vTaskDelay(unsigned);
void vTaskDelete(void *);
int xTaskCreate(void (*)(void *), const char *, unsigned, void *, unsigned, void *);
'''
(OUT / 'stub.h').write_text(STUB)
for header in ['esp_app_desc.h', 'esp_app_format.h', 'esp_err.h', 'esp_hosted.h',
               'esp_hosted_api_types.h', 'esp_hosted_ota.h', 'esp_log.h', 'esp_system.h',
               'freertos/FreeRTOS.h', 'freertos/portmacro.h', 'freertos/task.h']:
    p = OUT / header
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text('#include "stub.h"\n')
HARNESS = r'''
#include <assert.h>
#include <stdio.h>
#include <string.h>
#include "SOURCE"
static esp_hosted_coprocessor_fwver_t running;
static char calls[100];
static int fault, writes, restarted;
static unsigned delay_ms;
static void record(char c) { size_t n = strlen(calls); calls[n] = c; calls[n+1] = 0; }
int esp_hosted_get_coprocessor_fwversion(esp_hosted_coprocessor_fwver_t *v) {
    record('V'); *v = running; return fault == 1 ? ESP_FAIL : ESP_OK;
}
int esp_hosted_slave_ota_begin(void) { record('B'); return fault == 2 ? ESP_FAIL : ESP_OK; }
int esp_hosted_slave_ota_write(uint8_t *b, uint32_t n) {
    record('W'); writes++;
    const bool modern = running.major1 > 2 || (running.major1 == 2 && running.minor1 >= 6);
    assert(n == (modern ? (writes == 1 ? 4096 : 904) : (writes < 5 ? 1024 : 904)));
    if (!modern) assert(n + 64 < 4096); /* RPC envelope must fit old receiver. */
    for (uint32_t i=0; i<n; i++) assert(b[i] == 0xa5);
    return fault == 3 ? ESP_FAIL : ESP_OK;
}
int esp_hosted_slave_ota_end(void) {
    record('E'); return fault == 4 ? ESP_FAIL : ESP_OK;
}
int esp_hosted_slave_ota_activate(void) {
    record('A'); assert(running.major1 > 2 || (running.major1 == 2 && running.minor1 >= 6));
    return fault == 5 ? ESP_FAIL : ESP_OK;
}
const char *esp_err_to_name(int e) { (void)e; return "mock error"; }
void esp_restart(void) { record('R'); restarted++; }
void vTaskDelay(unsigned ms) { record('D'); delay_ms = ms; }
void vTaskDelete(void *p) { (void)p; record('X'); }
int xTaskCreate(void (*fn)(void *), const char *name, unsigned stack, void *arg, unsigned pri, void *handle) {
    (void)name; (void)stack; (void)pri; (void)handle; fn(arg); return pdPASS;
}
bool modulus_storage_usb_volume_mounted(void) { return true; }
static void run(unsigned major, unsigned minor, unsigned patch, int failure, const char *expected) {
    running = (esp_hosted_coprocessor_fwver_t){major, minor, patch};
    calls[0] = 0; writes = 0; restarted = 0; delay_ms = 0; fault = failure;
    s_state = (modulus_c6_ota_snapshot_t){.phase = MODULUS_C6_OTA_ARMED, .c6_connected = true};
    /* Stale UI deliberately claims a modern slave. Worker must query again. */
    strcpy(s_state.c6_version, "9.9.9");
    strcpy(s_armed_path, failure == 6 ? "missing.bin" : "input.bin");
    s_armed_size = failure == 7 ? 6000 : 5000;
    s_worker_running = false;
    modulus_c6_ota_start();
    assert(strcmp(calls, expected) == 0);
    assert(!s_worker_running);
    if (!failure && major) {
        assert(s_state.phase == MODULUS_C6_OTA_SUCCESS);
        assert(s_state.progress == 100 && restarted == 1);
        assert(delay_ms == (major > 2 || (major == 2 && minor >= 6) ? 3000 : 8000));
    } else {
        assert(s_state.phase == MODULUS_C6_OTA_ERROR);
        assert(restarted == 0 && delay_ms == 0);
    }
}
int main(void) {
    FILE *f = fopen("input.bin", "wb"); assert(f);
    for (int i=0; i<5000; i++) fputc(0xa5, f);
    fclose(f);
    run(1,4,1,0,"VBWWWWWEDRX");
    run(2,5,99,0,"VBWWWWWEDRX");
    run(2,6,0,0,"VBWWEADRX");
    run(2,11,4,0,"VBWWEADRX");
    run(3,0,0,0,"VBWWEADRX");
    run(2,11,4,1,"VX"); assert(strstr(s_state.status,"Nothing written"));
    run(0,0,0,0,"VX");
    run(1,4,1,2,"VBX"); assert(strstr(s_state.status,"begin failed"));
    run(1,4,1,3,"VBWX"); assert(strstr(s_state.status,"transfer failed"));
    run(1,4,1,4,"VBWWWWWEX"); assert(strstr(s_state.status,"Activation unconfirmed"));
    run(2,6,0,4,"VBWWEX"); assert(strstr(s_state.status,"Activation not requested"));
    run(2,6,0,5,"VBWWEAX"); assert(strstr(s_state.status,"Activation unconfirmed"));
    run(2,6,0,6,"VX"); assert(strstr(s_state.status,"open image failed"));
    run(1,4,1,7,"VBWWWWX"); assert(strstr(s_state.status,"read image failed"));
    puts("PASS: 14 C6 OTA scenarios (versions, order, delays, failures, partial input)");
    return 0;
}
'''
source = ROOT / 'firmware/tab5/components/modulus_zig/c6_ota_shim.c'
(OUT / 'test.c').write_text(HARNESS.replace('SOURCE', source.as_posix()))
env = os.environ.copy()
env['ZIG_LOCAL_CACHE_DIR'] = str(OUT / 'zig-local-cache')
env['ZIG_GLOBAL_CACHE_DIR'] = str(OUT / 'zig-global-cache')
exe = OUT / ('test.exe' if os.name == 'nt' else 'test')
subprocess.run(['zig', 'cc', '-std=c11', '-Wall', '-Wextra', '-Werror',
                '-Wno-unused-variable', '-I', str(OUT), '-I', str(source.parent / 'include'),
                str(OUT / 'test.c'), '-o', str(exe)], check=True, cwd=OUT, env=env)
subprocess.run([str(exe)], check=True, cwd=OUT)
