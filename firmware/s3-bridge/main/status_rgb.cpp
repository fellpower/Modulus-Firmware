#include "status_rgb.h"
#include "bridge_board.h"
#include "espnow_link.h"
#include "uart_bridge.h"

#include <led_strip.h>
#include <freertos/FreeRTOS.h>
#include <freertos/task.h>
#include <esp_log.h>
#include <atomic>

static const char *TAG = "status_rgb";
static led_strip_handle_t s_strip;
static int s_gpio = -1;
static std::atomic<bool> s_runtime_ready{false};

static void set_rgb(uint8_t red, uint8_t green, uint8_t blue)
{
    if (!s_strip) return;
    (void)led_strip_set_pixel(s_strip, 0, red, green, blue);
    (void)led_strip_refresh(s_strip);
}

static void bind_board_led()
{
    const int gpio = bridge_board_get()->rgb_gpio;
    if (gpio == s_gpio) return;
    if (s_strip) {
        (void)led_strip_clear(s_strip);
        (void)led_strip_del(s_strip);
        s_strip = nullptr;
    }
    s_gpio = gpio;
    if (gpio < 0) return;

    led_strip_config_t strip = {};
    strip.strip_gpio_num = gpio;
    strip.max_leds = 1;
    strip.led_model = LED_MODEL_WS2812;
    strip.color_component_format = LED_STRIP_COLOR_COMPONENT_FMT_GRB;
    led_strip_rmt_config_t rmt = {};
    rmt.clk_src = RMT_CLK_SRC_DEFAULT;
    rmt.resolution_hz = 10000000;
    if (led_strip_new_rmt_device(&strip, &rmt, &s_strip) != ESP_OK) {
        s_strip = nullptr;
        ESP_LOGW(TAG, "WS2812 init failed on GPIO%d", gpio);
        return;
    }
    set_rgb(4, 1, 0); /* boot: very dim amber */
    ESP_LOGI(TAG, "WS2812 status LED on GPIO%d", gpio);
}

static void status_task(void *)
{
    uint32_t last_bytes = 0;
    uint32_t last_fails = 0;
    TickType_t activity_until = 0;
    TickType_t error_until = 0;
    for (;;) {
        bind_board_led();
        const TickType_t now = xTaskGetTickCount();
        const uint32_t bytes = uart_bridge_bytes_tx() + uart_bridge_bytes_rx();
        const uint32_t fails = espnow_fail_count();
        if (bytes != last_bytes) activity_until = now + pdMS_TO_TICKS(140);
        if (fails != last_fails && espnow_last_link_age_ms() < 5000) {
            error_until = now + pdMS_TO_TICKS(500);
        }
        last_bytes = bytes;
        last_fails = fails;

        if (!s_runtime_ready.load(std::memory_order_acquire)) {
            set_rgb(4, 1, 0);                   /* startup incomplete: amber */
        } else if (now < activity_until) {
            set_rgb(0, 3, 5);                   /* CNC traffic: cyan */
        } else if (now < error_until) {
            set_rgb(6, 1, 0);                   /* link error: orange */
        } else if (!espnow_channel_hunting() && espnow_last_link_age_ms() < 5000) {
            set_rgb(0, 5, 0);                   /* connected: green */
        } else if (espnow_channel_hunting() &&
                   ((now / pdMS_TO_TICKS(300)) & 1U) == 0) {
            set_rgb(4, 0, 5);                   /* active channel hunt: violet */
        } else if (espnow_channel_hunting()) {
            set_rgb(0, 0, 0);
        } else if (((now / pdMS_TO_TICKS(300)) & 1U) == 0) {
            set_rgb(0, 1, 5);                   /* searching: blue blink */
        } else {
            set_rgb(0, 0, 0);
        }
        vTaskDelay(pdMS_TO_TICKS(70));
    }
}

void status_rgb_mark_runtime_ready()
{
    s_runtime_ready.store(true, std::memory_order_release);
}

void status_rgb_start()
{
    bind_board_led();
    /* Keep the task alive even when the boot profile has no RGB LED: a later
     * `board ...` command can select one without requiring a reboot. */
    (void)xTaskCreatePinnedToCore(status_task, "status_rgb", 3072,
                                  nullptr, 3, nullptr, 1);
}
