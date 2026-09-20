/*
 * ESP32-S3 ESP-NOW ↔ UART Bridge - USB shell entry (UART0 or USB Serial/JTAG).
 * See bridge_config.h for full command list.
 */
#include "bridge_config.h"
#include "bridge_board.h"
#include "espnow_link.h"
#include "uart_bridge.h"
#include "halt_gpio.h"
#include "status_rgb.h"

#include <nvs_flash.h>
#include <esp_event.h>
#include <esp_netif.h>
#include <esp_ota_ops.h>
#include <esp_app_desc.h>
#include <esp_heap_caps.h>
#include <esp_system.h>
#include <esp_timer.h>
#include <esp_wifi.h>
#include <esp_core_dump.h>
#include <driver/usb_serial_jtag.h>
#include <freertos/FreeRTOS.h>
#include <freertos/task.h>
#include <driver/uart.h>
#include <cstdio>
#include <cstring>
#include <cstdlib>
#include <cstdarg>

static int shell_printf(const char* format, ...)
{
    char buf[768];
    va_list args;
    va_start(args, format);
    const int needed = vsnprintf(buf, sizeof(buf), format, args);
    va_end(args);
    if (needed <= 0) return needed;
    const size_t count = static_cast<size_t>(needed) < sizeof(buf)
                             ? static_cast<size_t>(needed)
                             : sizeof(buf) - 1;
    return usb_serial_jtag_write_bytes(buf, count, pdMS_TO_TICKS(100));
}

#define printf shell_printf

static bool print_boot_self_check()
{
    bool espnow_ok = espnow_self_check();
    bool uart_ok = uart_bridge_self_check();
    bool all_ok = espnow_ok && uart_ok;
    ESP_LOGI("main", "self-check ESP-NOW=%s UART=%s",
             espnow_ok ? "PASS" : "FAIL", uart_ok ? "PASS" : "FAIL");
    return all_ok;
}

static void print_link_health()
{
    const char* mac = espnow_tab5_mac_str();
    uint32_t fails = espnow_fail_count();
    uint32_t drops = espnow_inbound_drops();
    uint32_t pending = espnow_inbound_pending();
    uint32_t odrops = espnow_outbound_drops();
    uint32_t owait = espnow_outbound_pending();
    uint32_t overruns = uart_bridge_rx_overruns();
    const char* health = "OK";

    if (strcmp(mac, "not seen yet") == 0) {
        health = "WAIT - no Tab5 peer yet";
    } else if (fails > 100 || drops > 50 || overruns > 0 ||
               pending > (ESPNOW_QUEUE_DEPTH / 2)) {
        health = "FAULT - check channel / power / Tab5";
    } else if (fails > 0 || drops > 0 || odrops > 0 || pending > 8 || owait > 8) {
        health = "DEGRADED";
    }

    printf("  Link health      : %s\r\n", health);
    if (espnow_tx_count() > 0) {
        uint32_t pct = (fails * 100U) / (espnow_tx_count() + fails);
        printf("  ESP-NOW fail rate: %lu%% (%lu ok / %lu fail)\r\n",
               (unsigned long)pct,
               (unsigned long)espnow_tx_count(),
               (unsigned long)fails);
    }
    printf("  Inbound queue    : %lu waiting, %lu drops\r\n",
           (unsigned long)pending, (unsigned long)drops);
    printf("  Outbound queue   : %lu waiting, %lu drops (oldest)\r\n",
           (unsigned long)owait, (unsigned long)odrops);
    printf("  UART RX buffered : %u bytes\r\n",
           (unsigned)uart_bridge_rx_buffered());
    if (overruns > 0) {
        printf("  UART RX overrun  : %lu (FIFO/ring)\r\n",
               (unsigned long)overruns);
    }
    if (uart_bridge_uart_tx_fails() > 0) {
        printf("  UART TX fails    : %lu\r\n",
               (unsigned long)uart_bridge_uart_tx_fails());
    }
}

static void print_status()
{
    const bridge_board_t *b = bridge_board_get();
    printf("\r\n=== S3 ESP-NOW <-> UART Bridge ===\r\n");
    printf("  Board            : %s  [%s]  %s\r\n", b->id, b->vendor, b->name);
    print_link_health();
    printf("  ESP-NOW channel  : %d\r\n",    espnow_get_channel());
    printf("  Tab5 MAC         : %s\r\n",    espnow_tab5_mac_str());
    printf("  ESP-NOW RX pkts  : %lu\r\n",   (unsigned long)espnow_rx_count());
    printf("  ESP-NOW TX pkts  : %lu\r\n",   (unsigned long)espnow_tx_count());
    printf("  ESP-NOW TX fails : %lu\r\n",   (unsigned long)espnow_fail_count());
    printf("  UART port        : UART%d\r\n", UART_PORT_NUM);
    printf("  UART baud        : %lu\r\n",   (unsigned long)uart_bridge_baud());
    printf("  UART TX GPIO     : %d\r\n",    uart_bridge_tx_gpio());
    printf("  UART RX GPIO     : %d\r\n",    uart_bridge_rx_gpio());
    printf("  Batch trigger    : %lu ms (idle coalesce)\r\n",
           (unsigned long)uart_bridge_batch_ms());
    if (b->led_tx < 0) {
        printf("  Activity LEDs    : n/a (WS2812 not GPIO-driven)\r\n");
    } else {
        printf("  Activity LEDs    : %s\r\n", uart_bridge_led_enabled() ? "on" : "off");
        if (b->led_tx == b->led_rx) {
            printf("  User LED         : GPIO%d (%s)\r\n", b->led_tx,
                   b->led_on ? "active high" : "active low");
        } else {
            printf("  LED TX           : GPIO%d\r\n", b->led_tx);
            printf("  LED RX           : GPIO%d\r\n", b->led_rx);
        }
    }
    printf("  HALT_host        : GPIO%d (%s)\r\n", halt_gpio_pin(),
           halt_gpio_is_asserted() ? "ASSERTED" : "released");
    printf("  Bytes -> grblHAL : %lu\r\n",   (unsigned long)uart_bridge_bytes_tx());
    printf("  Bytes -> Tab5    : %lu\r\n",   (unsigned long)uart_bridge_bytes_rx());
    printf("================================\r\n\r\n");
}

static void print_help()
{
    printf("\r\nCommands:\r\n");
    printf("  channel <1-13>               - ESP-NOW channel (live apply)\r\n");
    printf("  baud <115200|230400|460800|921600>  - UART baud rate\r\n");
    printf("  txgpio <n>                   - UART TX GPIO (board default %d)\r\n",
           bridge_board_get()->uart_tx);
    printf("  rxgpio <n>                   - UART RX GPIO (board default %d)\r\n",
           bridge_board_get()->uart_rx);
    printf("  board                         - list boards (grouped by vendor)\r\n");
    printf("  board <id>                    - set pinout (saved)\r\n");
    printf("  uartping                     - UART wiring test (? to grblHAL, not ESP-NOW)\r\n");
    printf("  mpgactivate                  - send 0x8B MPG mode toggle to grblHAL\r\n");
    printf("  batchms <1-20>               - UART->ESP-NOW idle coalesce (ms)\r\n");
    printf("  led on|off                   - activity LED pulses\r\n");
    printf("  stats reset                  - clear traffic / fail counters\r\n");
    printf("  status                       - config, counters, link health\r\n");
    printf("  diag                         - copyable build/crash/link diagnostics\r\n");
    printf("  trace on|off                 - live 2 s ESP-NOW channel/link log\r\n");
    printf("  log                          - print saved ~2 min link history\r\n");
    printf("  log clear                    - clear saved link history\r\n");
    printf("  coredump clear               - erase saved crash image after collection\r\n");
    printf("  help                         - this list\r\n\r\n");
}

static void print_diag()
{
    const esp_app_desc_t *app = esp_app_get_description();
    uint8_t primary = 0;
    wifi_second_chan_t secondary = WIFI_SECOND_CHAN_NONE;
    (void)esp_wifi_get_channel(&primary, &secondary);
    printf("\r\n=== MODULUS S3 DIAGNOSTICS ===\r\n");
    printf("  App version       : %s\r\n", app ? app->version : "unknown");
    printf("  ELF SHA256        : ");
    if (app) for (unsigned i = 0; i < sizeof(app->app_elf_sha256); ++i) printf("%02x", app->app_elf_sha256[i]);
    printf("\r\n  Board             : %s\r\n", bridge_board_get()->id);
    printf("  Reset reason      : %d\r\n", (int)esp_reset_reason());
    size_t core_addr = 0;
    size_t core_size = 0;
    const esp_err_t core_rc = esp_core_dump_image_get(&core_addr, &core_size);
    if (core_rc == ESP_OK) {
        printf("  Saved coredump    : yes, address 0x%08x, %u bytes\r\n",
               (unsigned)core_addr, (unsigned)core_size);
    } else {
        printf("  Saved coredump    : no\r\n");
    }
    printf("  Uptime            : %llu ms\r\n", (unsigned long long)(esp_timer_get_time() / 1000));
    printf("  Heap free/min     : %u / %u bytes\r\n", (unsigned)esp_get_free_heap_size(),
           (unsigned)esp_get_minimum_free_heap_size());
    printf("  Radio channel     : %u\r\n", (unsigned)primary);
    printf("  Channel hunting   : %s\r\n", espnow_channel_hunting() ? "yes" : "no");
    printf("  Last link age     : %lu ms\r\n", (unsigned long)espnow_last_link_age_ms());
    printf("  Last RX/TX-ok age : %lu / %lu ms\r\n", (unsigned long)espnow_last_rx_age_ms(),
           (unsigned long)espnow_last_tx_ok_age_ms());
    printf("  Tab5 MAC          : %s\r\n", espnow_tab5_mac_str());
    printf("  RX/TX/fail        : %lu / %lu / %lu\r\n", (unsigned long)espnow_rx_count(),
           (unsigned long)espnow_tx_count(), (unsigned long)espnow_fail_count());
    printf("  All radio RX      : %lu (includes probes/control)\r\n",
           (unsigned long)espnow_air_rx_count());
    printf("  Queue in/out/drop : %lu / %lu / %lu+%lu\r\n",
           (unsigned long)espnow_inbound_pending(), (unsigned long)espnow_outbound_pending(),
           (unsigned long)espnow_inbound_drops(), (unsigned long)espnow_outbound_drops());
    printf("  UART baud TX/RX   : %lu GPIO%d/GPIO%d\r\n", (unsigned long)uart_bridge_baud(),
           uart_bridge_tx_gpio(), uart_bridge_rx_gpio());
    printf("=== END DIAGNOSTICS ===\r\n");
}

static void handle_command(const char* line)
{
    char cmd[32] = {};
    char arg[32] = {};
    sscanf(line, "%31s %31s", cmd, arg);

    if (strcmp(cmd, "status") == 0) {
        print_status();

    } else if (strcmp(cmd, "diag") == 0) {
        print_diag();

    } else if (strcmp(cmd, "coredump") == 0) {
        if (strcmp(arg, "clear") == 0) {
            const esp_err_t rc = esp_core_dump_image_erase();
            printf("  Saved coredump erase: %s\r\n", esp_err_to_name(rc));
        } else {
            printf("  Use: coredump clear\r\n");
            return;
        }

    } else if (strcmp(cmd, "help") == 0) {
        print_help();

    } else if (strcmp(cmd, "channel") == 0) {
        int ch = atoi(arg);
        if (ch < 1 || ch > 13) {
            printf("  Error: channel must be 1-13\r\n");
            return;
        }
        if (espnow_set_channel((uint8_t)ch)) {
            printf("  Channel set to %d; old link proof cleared, 5 s verify window\r\n", ch);
        } else {
            printf("  Error: failed to apply channel %d\r\n", ch);
        }

    } else if (strcmp(cmd, "trace") == 0) {
        if (strcmp(arg, "on") == 0) {
            espnow_trace_set(true);
            printf("  Live link trace on (one line every 2 s)\r\n");
        } else if (strcmp(arg, "off") == 0) {
            espnow_trace_set(false);
            printf("  Live link trace off\r\n");
        } else {
            printf("  Use: trace on|off (currently %s)\r\n",
                   espnow_trace_enabled() ? "on" : "off");
        }

    } else if (strcmp(cmd, "log") == 0) {
        if (strcmp(arg, "clear") == 0) {
            espnow_log_clear();
            printf("  Link history cleared\r\n");
        } else {
            espnow_log_print();
        }

    } else if (strcmp(cmd, "baud") == 0) {
        uint32_t baud = (uint32_t)atol(arg);
        if (baud != 115200 && baud != 230400 && baud != 460800 && baud != 921600) {
            printf("  Error: supported rates: 115200 / 230400 / 460800 / 921600\r\n");
            return;
        }
        uart_bridge_reinit(baud, uart_bridge_tx_gpio(), uart_bridge_rx_gpio());
        printf("  Baud set to %lu\r\n", (unsigned long)baud);

    } else if (strcmp(cmd, "txgpio") == 0) {
        int gpio = atoi(arg);
        if (gpio < 0 || gpio > 48) {
            printf("  Error: invalid GPIO number\r\n");
            return;
        }
        uart_bridge_reinit(uart_bridge_baud(), gpio, uart_bridge_rx_gpio());
        printf("  TX GPIO set to %d\r\n", gpio);

    } else if (strcmp(cmd, "rxgpio") == 0) {
        int gpio = atoi(arg);
        if (gpio < 0 || gpio > 48) {
            printf("  Error: invalid GPIO number\r\n");
            return;
        }
        uart_bridge_reinit(uart_bridge_baud(), uart_bridge_tx_gpio(), gpio);
        printf("  RX GPIO set to %d\r\n", gpio);

    } else if (strcmp(cmd, "board") == 0) {
        if (arg[0] == '\0') {
            bridge_board_print_list();
        } else {
            int rc = bridge_board_set(arg);
            if (rc == -1) {
                printf("  Unknown id '%s' — type 'board' for the list\r\n", arg);
                return;
            }
        }

    } else if (strcmp(cmd, "uartping") == 0) {
        /* UART-only path - does not exercise Tab5 / ESP-NOW */
        const char* probe = "?\n";
        uart_bridge_send((const uint8_t*)probe, 2);
        printf("  Sent '?' to grblHAL (UART only - not ESP-NOW path)...\r\n");
        uint32_t before = uart_bridge_bytes_rx();
        vTaskDelay(pdMS_TO_TICKS(500));
        uint32_t after  = uart_bridge_bytes_rx();
        uint32_t delta  = after - before;
        if (delta > 0)
            printf("  grblHAL replied: %lu byte(s) received\r\n", (unsigned long)delta);
        else
            printf("  No response - check wiring (TX=GPIO%d -> grblHAL RX, RX=GPIO%d <- grblHAL TX) and baud (%lu)\r\n",
                   uart_bridge_tx_gpio(), uart_bridge_rx_gpio(), (unsigned long)uart_bridge_baud());

    } else if (strcmp(cmd, "mpgactivate") == 0) {
        uart_bridge_mpg_activate();
        printf("  Sent 0x8B - MPG mode toggle (controller must be IDLE/ALARM/ESTOP)\r\n");

    } else if (strcmp(cmd, "batchms") == 0) {
        int ms = atoi(arg);
        if (ms < 1 || ms > 20) {
            printf("  Error: batchms must be 1-20\r\n");
            return;
        }
        uart_bridge_set_batch_ms((uint32_t)ms);
        printf("  Batch trigger set to %d ms\r\n", ms);

    } else if (strcmp(cmd, "led") == 0) {
        if (strcmp(arg, "on") == 0) {
            uart_bridge_set_led_enabled(true);
            printf("  Activity LEDs on\r\n");
        } else if (strcmp(arg, "off") == 0) {
            uart_bridge_set_led_enabled(false);
            printf("  Activity LEDs off\r\n");
        } else {
            printf("  Error: use 'led on' or 'led off'\r\n");
            return;
        }

    } else if (strcmp(cmd, "stats") == 0) {
        if (strcmp(arg, "reset") == 0) {
            espnow_reset_stats();
            uart_bridge_reset_stats();
            printf("  Traffic / fail counters cleared\r\n");
        } else {
            printf("  Use: stats reset\r\n");
            return;
        }

    } else if (cmd[0] != '\0') {
        printf("  Unknown command '%s' - type 'help'\r\n", cmd);
    }
    printf("> ");
    fflush(stdout);
}

static void shell_task(void* arg)
{
    char line[64];
    int  pos = 0;

    printf("\r\nS3 bridge ready (%s). Type 'diag' or 'help'.\r\n",
           bridge_board_get()->id);
    printf("> ");
    fflush(stdout);

    while (1) {
        uint8_t byte = 0;
        if (usb_serial_jtag_read_bytes(&byte, 1, pdMS_TO_TICKS(20)) != 1) continue;
        const int ch = byte;

        if (ch == '\r' || ch == '\n') {
            if (pos == 0) {
                /* Most terminals send CRLF.  The CR already executed the
                 * command; silently ignore the following LF instead of
                 * flooding the console with a second help/menu block. */
                continue;
            }
            line[pos] = '\0';
            pos = 0;
            printf("\r\n");
            handle_command(line);
        } else if ((ch == 127 || ch == 8) && pos > 0) {
            /* Backspace */
            pos--;
            printf("\b \b");
            fflush(stdout);
        } else if (ch >= 0x20 && pos < (int)(sizeof(line) - 1)) {
            line[pos++] = (char)ch;
            const uint8_t echo = (uint8_t)ch;
            (void)usb_serial_jtag_write_bytes(&echo, 1, pdMS_TO_TICKS(20));
            fflush(stdout);
        }
    }
}

// ── app_main ─────────────────────────────────────────────────────────────────
extern "C" void app_main()
{
    if (!usb_serial_jtag_is_driver_installed()) {
        usb_serial_jtag_driver_config_t usb_cfg = USB_SERIAL_JTAG_DRIVER_CONFIG_DEFAULT();
        usb_cfg.tx_buffer_size = 2048;
        usb_cfg.rx_buffer_size = 512;
        ESP_ERROR_CHECK(usb_serial_jtag_driver_install(&usb_cfg));
    }

    /* This CH343 board's application UART can stop draining while Wi-Fi is
     * starting.  Keep background logging off so diagnostics can be requested
     * explicitly without blocking radio/task startup. */
    esp_log_level_set("*", ESP_LOG_NONE);

    /* NVS - must initialise before any component reads settings */
    esp_err_t err = nvs_flash_init();
    if (err == ESP_ERR_NVS_NO_FREE_PAGES ||
        err == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        ESP_ERROR_CHECK(nvs_flash_erase());
        err = nvs_flash_init();
    }
    ESP_ERROR_CHECK(err);

    /* Default event loop - required by esp_wifi/esp_now */
    ESP_ERROR_CHECK(esp_event_loop_create_default());
    ESP_ERROR_CHECK(esp_netif_init());

    /* Initialise ESP-NOW link first (WiFi STA, channel, peer auto-learn).
     * Must complete before the UART RX task starts so that esp_now_send()
     * is never called before esp_now_init() has run. */
    espnow_init();

    bridge_board_init();
    status_rgb_start();
    halt_gpio_init();

    /* Initialise UART bridge (sets up driver + RX task) */
    uart_bridge_init();
    status_rgb_mark_runtime_ready();

    const bool boot_self_check_ok = print_boot_self_check();

    /* An OTA image becomes permanent only after its radio/UART self-check has
     * completed. A crash before this point lets the bootloader roll it back. */
    if (boot_self_check_ok) {
        ESP_ERROR_CHECK_WITHOUT_ABORT(esp_ota_mark_app_valid_cancel_rollback());
    } else {
        ESP_LOGE("main", "Boot self-check failed; OTA image remains pending for rollback");
    }

    /* Launch interactive shell on UART0 / USB-CDC */
    xTaskCreatePinnedToCore(shell_task, "shell", 4096, NULL, 3, NULL, 1);
}
