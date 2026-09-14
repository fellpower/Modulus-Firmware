/*
 * ESP32-S3 ESP-NOW <-> UART Bridge — ESP-NOW link
 *
 * Tab5 -> inbound queue -> worker -> uart_bridge_send -> grblHAL
 * grblHAL -> uart_rx_task -> outbound queue -> worker -> espnow_send_to_tab5
 */
#include "espnow_link.h"
#include "uart_bridge.h"
#include "halt_gpio.h"
#include "bridge_config.h"
#include "bridge_nvs.h"
#include "bridge_protocol.h"
#include "s3_ota.h"

#include <atomic>
#include <cstring>
#include <cstdio>

#include <esp_mac.h>
#include <esp_now.h>
#include <esp_wifi.h>
#include <esp_log.h>
#include <freertos/FreeRTOS.h>
#include <freertos/queue.h>
#include <freertos/semphr.h>
#include <freertos/task.h>

static const char* TAG = "espnow";

/* 2.4 GHz channels 1-13 (Tab5 probe set); ch 14 is JP-only and unused here. */
static constexpr uint8_t kChannelMin = 1;
static constexpr uint8_t kChannelMax = 13;
static constexpr uint8_t kBroadcastMac[6] = {0xff, 0xff, 0xff, 0xff, 0xff, 0xff};

typedef struct {
    uint16_t len;
    uint8_t  data[ESPNOW_MAX_PAYLOAD];
} inbound_pkt_t;

static uint8_t               s_channel = ESPNOW_DEFAULT_CHANNEL;
static uint8_t               s_tab5_mac[6] = {};
static bool                  s_tab5_known = false;
static char                  s_mac_str[18] = "not seen yet";
static bool                  s_espnow_ready = false;
static std::atomic<uint32_t> s_rx_count{0};
static std::atomic<uint32_t> s_tx_count{0};
static std::atomic<uint32_t> s_fail_count{0};
static std::atomic<uint32_t> s_inbound_drops{0};
static std::atomic<uint32_t> s_outbound_drops{0};
static SemaphoreHandle_t     s_tx_lock = nullptr; /* mutex: one in-flight send */
static SemaphoreHandle_t     s_tx_done = nullptr; /* binary: send-cb completion */
static SemaphoreHandle_t     s_peer_mu = nullptr; /* mutex: MAC / peer table */
static QueueHandle_t         s_inbound_q = nullptr;
static QueueHandle_t         s_outbound_q = nullptr;
static bool                  s_inbound_worker_started = false;
static bool                  s_outbound_worker_started = false;
static bool                  s_heartbeat_task_started = false;
static bool                  s_channel_hunt_task_started = false;
static std::atomic<bool>     s_channel_hunting{false};
static std::atomic<bool>     s_channel_latch_pending{false};
static std::atomic<uint32_t> s_last_link_ok_tick{0};
/* MOD_ACK / peer learn must not block inside esp_now recv cb. */
static portMUX_TYPE          s_ack_spin = portMUX_INITIALIZER_UNLOCKED;
static bool                  s_ack_pending = false;
static uint8_t               s_ack_mac[6] = {};
static portMUX_TYPE          s_learn_spin = portMUX_INITIALIZER_UNLOCKED;
static bool                  s_learn_pending = false;
static uint8_t               s_learn_mac[6] = {};

static void mac_to_str(const uint8_t* mac, char* out)
{
    snprintf(out, 18, "%02X:%02X:%02X:%02X:%02X:%02X",
             mac[0], mac[1], mac[2], mac[3], mac[4], mac[5]);
}

static bool channel_ok(uint8_t ch)
{
    return ch >= kChannelMin && ch <= kChannelMax;
}

static void save_tab5_mac(void)
{
    bridge_nvs_t nvs = bridge_nvs_open(NVS_READWRITE);
    if (!nvs.ok) return;
    esp_err_t err = nvs_set_blob(nvs.h, NVS_KEY_TAB5_MAC, s_tab5_mac, 6);
    if (err == ESP_OK) err = nvs_commit(nvs.h);
    bridge_nvs_close(&nvs);
    if (err != ESP_OK) {
        ESP_LOGW(TAG, "save Tab5 MAC: %s", esp_err_to_name(err));
    }
}

static bool load_tab5_mac(void)
{
    bridge_nvs_t nvs = bridge_nvs_open(NVS_READONLY);
    if (!nvs.ok) return false;
    size_t sz = 6;
    esp_err_t err = nvs_get_blob(nvs.h, NVS_KEY_TAB5_MAC, s_tab5_mac, &sz);
    bridge_nvs_close(&nvs);
    return err == ESP_OK && sz == 6;
}

static bool save_channel_nvs(uint8_t ch)
{
    bridge_nvs_t nvs = bridge_nvs_open(NVS_READWRITE);
    if (!nvs.ok) return false;
    esp_err_t err = nvs_set_u8(nvs.h, NVS_KEY_CHANNEL, ch);
    if (err == ESP_OK) err = nvs_commit(nvs.h);
    bridge_nvs_close(&nvs);
    return err == ESP_OK;
}

static void apply_peer_rate_11m(const uint8_t* mac)
{
    esp_now_rate_config_t cfg = {};
    cfg.phymode = WIFI_PHY_MODE_11B;
    cfg.rate = WIFI_PHY_RATE_11M_L;
    cfg.ersu = false;
    cfg.dcm = false;
    const esp_err_t err = esp_now_set_peer_rate_config(mac, &cfg);
    if (err != ESP_OK) {
        ESP_LOGW(TAG, "peer rate 11M: %s", esp_err_to_name(err));
    }
}

/* Caller holds s_peer_mu. */
static void register_tab5_peer_locked(const uint8_t* mac)
{
    if (esp_now_is_peer_exist(mac)) {
        esp_now_del_peer(mac);
    }

    esp_now_peer_info_t pi = {};
    memcpy(pi.peer_addr, mac, 6);
    /* Channel 0 follows the STA interface's current channel.  The recovery
     * task deliberately hops 1..13; pinning the peer to the startup channel
     * makes every outbound hunt packet fail after the first hop. */
    pi.channel = 0;
    pi.ifidx   = WIFI_IF_STA;
    pi.encrypt = false;

    esp_err_t err = esp_now_add_peer(&pi);
    if (err == ESP_OK) {
        apply_peer_rate_11m(mac);
        ESP_LOGI(TAG, "Tab5 peer registered: %s current-channel rate11M", s_mac_str);
    } else {
        ESP_LOGW(TAG, "add_peer failed: %s", esp_err_to_name(err));
    }
}

static void learn_tab5_mac(const uint8_t* mac)
{
    if (!s_peer_mu) return;

    xSemaphoreTake(s_peer_mu, portMAX_DELAY);
    const bool latch_channel = s_channel_latch_pending.exchange(false, std::memory_order_acq_rel);
    if (s_tab5_known && memcmp(s_tab5_mac, mac, 6) == 0 && !latch_channel) {
        xSemaphoreGive(s_peer_mu);
        return;
    }

    const bool first = !s_tab5_known;
    memcpy(s_tab5_mac, mac, 6);
    mac_to_str(s_tab5_mac, s_mac_str);
    s_tab5_known = true;
    register_tab5_peer_locked(s_tab5_mac);
    xSemaphoreGive(s_peer_mu);

    save_tab5_mac();
    if (latch_channel) {
        (void)save_channel_nvs(s_channel);
        ESP_LOGW(TAG, "ESP-NOW reacquired Tab5 on channel %u", (unsigned)s_channel);
    }
    ESP_LOGI(TAG, "%s Tab5 MAC: %s", first ? "Learned" : "Updated", s_mac_str);
}

/*
 * Serialize all esp_now_send calls (UART path + MOD_ACK).
 * Binary s_tx_done starts empty; on_sent Gives; we wait after send.
 * Drain stale Give so a prior timeout cannot complete this wait early.
 */
static bool espnow_send_chunk(const uint8_t* mac, const uint8_t* data, size_t len)
{
    if (!mac || !data || len == 0 || len > ESPNOW_MAX_PAYLOAD) {
        return false;
    }
    if (!s_espnow_ready || !s_tx_lock || !s_tx_done) {
        return false;
    }

    if (xSemaphoreTake(s_tx_lock, pdMS_TO_TICKS(ESPNOW_TX_LOCK_MS)) != pdTRUE) {
        s_fail_count.fetch_add(1, std::memory_order_relaxed);
        return false;
    }

    (void)xSemaphoreTake(s_tx_done, 0);

    const esp_err_t err = esp_now_send(mac, data, len);
    if (err != ESP_OK) {
        xSemaphoreGive(s_tx_lock);
        s_fail_count.fetch_add(1, std::memory_order_relaxed);
        ESP_LOGW(TAG, "esp_now_send: %s", esp_err_to_name(err));
        return false;
    }

    if (xSemaphoreTake(s_tx_done, pdMS_TO_TICKS(ESPNOW_TX_WAIT_MS)) != pdTRUE) {
        ESP_LOGW(TAG, "TX timeout — dropping chunk (%u bytes)", (unsigned)len);
        s_fail_count.fetch_add(1, std::memory_order_relaxed);
        xSemaphoreGive(s_tx_lock);
        return false;
    }

    xSemaphoreGive(s_tx_lock);
    return true;
}

static void defer_learn_mac(const uint8_t* mac)
{
    taskENTER_CRITICAL(&s_learn_spin);
    memcpy(s_learn_mac, mac, 6);
    s_learn_pending = true;
    taskEXIT_CRITICAL(&s_learn_spin);
}

static void apply_deferred_learn(void)
{
    uint8_t mac[6];
    bool do_it = false;
    taskENTER_CRITICAL(&s_learn_spin);
    if (s_learn_pending) {
        memcpy(mac, s_learn_mac, 6);
        s_learn_pending = false;
        do_it = true;
    }
    taskEXIT_CRITICAL(&s_learn_spin);
    if (do_it) learn_tab5_mac(mac);
}

static void request_mod_ack(const uint8_t* dest_mac)
{
    taskENTER_CRITICAL(&s_ack_spin);
    memcpy(s_ack_mac, dest_mac, 6);
    s_ack_pending = true;
    taskEXIT_CRITICAL(&s_ack_spin);
}

static void flush_pending_mod_ack(void)
{
    uint8_t mac[6];
    bool send = false;
    taskENTER_CRITICAL(&s_ack_spin);
    if (s_ack_pending) {
        memcpy(mac, s_ack_mac, 6);
        s_ack_pending = false;
        send = true;
    }
    taskEXIT_CRITICAL(&s_ack_spin);
    if (!send) return;

    static const uint8_t ack[] = BRIDGE_MOD_ACK;
    if (!espnow_send_chunk(mac, ack, BRIDGE_MOD_ACK_LEN)) {
        ESP_LOGW(TAG, "MOD_ACK send failed");
    }
}

static bool enqueue_inbound(const uint8_t* data, int len)
{
    if (!s_inbound_q || len <= 0 || len > ESPNOW_MAX_PAYLOAD) {
        return false;
    }

    inbound_pkt_t pkt = {};
    pkt.len = (uint16_t)len;
    memcpy(pkt.data, data, (size_t)len);

    if (xQueueSend(s_inbound_q, &pkt, 0) == pdTRUE) {
        return true;
    }

    s_inbound_drops.fetch_add(1, std::memory_order_relaxed);
    return false;
}

static void inbound_worker(void*)
{
    inbound_pkt_t pkt;
    for (;;) {
        apply_deferred_learn();
        flush_pending_mod_ack();
        if (xQueueReceive(s_inbound_q, &pkt, pdMS_TO_TICKS(20)) == pdTRUE) {
            uart_bridge_send(pkt.data, pkt.len);
        }
    }
}

static void outbound_worker(void*)
{
    inbound_pkt_t pkt;
    for (;;) {
        apply_deferred_learn();
        flush_pending_mod_ack();
        if (xQueueReceive(s_outbound_q, &pkt, pdMS_TO_TICKS(20)) == pdTRUE) {
            (void)espnow_send_to_tab5(pkt.data, pkt.len);
        }
    }
}

static void on_recv(const esp_now_recv_info_t* info,
                    const uint8_t* data, int len)
{
    if (!info || len <= 0 || !data) {
        return;
    }

    s_last_link_ok_tick.store((uint32_t)xTaskGetTickCount(), std::memory_order_release);
    if (s_channel_hunting.exchange(false, std::memory_order_acq_rel)) {
        s_channel_latch_pending.store(true, std::memory_order_release);
    }

    if (s3_ota_try_handle(info->src_addr, data, static_cast<size_t>(len))) {
        defer_learn_mac(info->src_addr);
        return;
    }

    if (len == BRIDGE_MOD_PROBE_LEN &&
        memcmp(data, BRIDGE_MOD_PROBE, BRIDGE_MOD_PROBE_LEN) == 0) {
        defer_learn_mac(info->src_addr);
        request_mod_ack(info->src_addr);
        return;
    }

    if (len == BRIDGE_MOD_HALT_LEN &&
        memcmp(data, BRIDGE_MOD_HALT_ON, BRIDGE_MOD_HALT_LEN) == 0) {
        defer_learn_mac(info->src_addr);
        halt_gpio_set(true);
        return;
    }

    if (len == BRIDGE_MOD_HALT_LEN &&
        memcmp(data, BRIDGE_MOD_HALT_OFF, BRIDGE_MOD_HALT_LEN) == 0) {
        defer_learn_mac(info->src_addr);
        halt_gpio_set(false);
        return;
    }

    defer_learn_mac(info->src_addr);

    s_rx_count.fetch_add(1, std::memory_order_relaxed);
    ESP_LOGD(TAG, "RX %d bytes from Tab5 -> queue", len);

    if (!enqueue_inbound(data, len)) {
        ESP_LOGW(TAG, "inbound queue full — dropped %d bytes", len);
    }
}

static void on_sent(const esp_now_send_info_t* info, esp_now_send_status_t status)
{
    if (status == ESP_NOW_SEND_SUCCESS) {
        s_tx_count.fetch_add(1, std::memory_order_relaxed);
        const bool tab5_unicast = info && s_tab5_known &&
                                  memcmp(info->des_addr, s_tab5_mac, 6) == 0;
        if (tab5_unicast) {
            s_last_link_ok_tick.store((uint32_t)xTaskGetTickCount(), std::memory_order_release);
        }
        if (tab5_unicast && s_channel_hunting.exchange(false, std::memory_order_acq_rel)) {
            /* Persist a channel found by an outbound hunt as well as one found
             * by an inbound Tab5 probe. NVS work remains outside the callback. */
            s_channel_latch_pending.store(true, std::memory_order_release);
            defer_learn_mac(info->des_addr);
        }
    } else {
        s_fail_count.fetch_add(1, std::memory_order_relaxed);
        if (info) {
            ESP_LOGD(TAG, "TX failed to %02X:%02X:%02X:%02X:%02X:%02X",
                     info->des_addr[0], info->des_addr[1], info->des_addr[2],
                     info->des_addr[3], info->des_addr[4], info->des_addr[5]);
        }
    }
    if (s_tx_done) {
        xSemaphoreGive(s_tx_done);
    }
}

bool espnow_send_to_tab5(const uint8_t* data, size_t len)
{
    if (!s_espnow_ready || !data || len == 0 || !s_peer_mu) {
        return false;
    }

    uint8_t mac[6];
    xSemaphoreTake(s_peer_mu, portMAX_DELAY);
    if (!s_tab5_known) {
        xSemaphoreGive(s_peer_mu);
        return false;
    }
    memcpy(mac, s_tab5_mac, 6);
    xSemaphoreGive(s_peer_mu);

    size_t offset = 0;
    while (offset < len) {
        const size_t chunk = (len - offset > ESPNOW_MAX_PAYLOAD)
                                 ? ESPNOW_MAX_PAYLOAD
                                 : (len - offset);
        if (!espnow_send_chunk(mac, data + offset, chunk)) {
            return false;
        }
        offset += chunk;
    }
    return true;
}

bool espnow_queue_to_tab5(const uint8_t* data, size_t len)
{
    if (!s_outbound_q || !data || len == 0 || len > ESPNOW_MAX_PAYLOAD) {
        return false;
    }

    inbound_pkt_t pkt = {};
    pkt.len = (uint16_t)len;
    memcpy(pkt.data, data, len);

    if (xQueueSend(s_outbound_q, &pkt, 0) == pdTRUE) {
        return true;
    }

    inbound_pkt_t junk;
    (void)xQueueReceive(s_outbound_q, &junk, 0);
    s_outbound_drops.fetch_add(1, std::memory_order_relaxed);
    return xQueueSend(s_outbound_q, &pkt, 0) == pdTRUE;
}

void espnow_init()
{
    bridge_nvs_t nvs = bridge_nvs_open(NVS_READONLY);
    if (nvs.ok) {
        uint8_t ch = 0;
        if (nvs_get_u8(nvs.h, NVS_KEY_CHANNEL, &ch) == ESP_OK && channel_ok(ch)) {
            s_channel = ch;
        }
        bridge_nvs_close(&nvs);
    }

    if (load_tab5_mac()) {
        mac_to_str(s_tab5_mac, s_mac_str);
        s_tab5_known = true;
        ESP_LOGI(TAG, "Tab5 MAC restored from NVS: %s ch%d", s_mac_str, s_channel);
    }

    wifi_init_config_t wcfg = WIFI_INIT_CONFIG_DEFAULT();
    ESP_ERROR_CHECK(esp_wifi_init(&wcfg));
    ESP_ERROR_CHECK(esp_wifi_set_storage(WIFI_STORAGE_RAM));
    ESP_ERROR_CHECK(esp_wifi_set_mode(WIFI_MODE_STA));
    ESP_ERROR_CHECK(esp_wifi_start());
    ESP_ERROR_CHECK(esp_wifi_set_ps(WIFI_PS_NONE));
    ESP_ERROR_CHECK(esp_wifi_set_max_tx_power(78));
    ESP_ERROR_CHECK(esp_wifi_set_channel(s_channel, WIFI_SECOND_CHAN_NONE));

    uint8_t my_mac[6];
    esp_read_mac(my_mac, ESP_MAC_WIFI_STA);
    ESP_LOGI(TAG, "S3 MAC %02X:%02X:%02X:%02X:%02X:%02X channel %u",
             my_mac[0], my_mac[1], my_mac[2], my_mac[3], my_mac[4], my_mac[5],
             (unsigned)s_channel);

    s_tx_lock = xSemaphoreCreateMutex();
    s_tx_done = xSemaphoreCreateBinary();
    s_peer_mu = xSemaphoreCreateMutex();
    ESP_ERROR_CHECK((s_tx_lock && s_tx_done && s_peer_mu) ? ESP_OK : ESP_ERR_NO_MEM);

    s_inbound_q = xQueueCreate(ESPNOW_QUEUE_DEPTH, sizeof(inbound_pkt_t));
    ESP_ERROR_CHECK(s_inbound_q ? ESP_OK : ESP_ERR_NO_MEM);
    s_outbound_q = xQueueCreate(ESPNOW_OUTBOUND_DEPTH, sizeof(inbound_pkt_t));
    ESP_ERROR_CHECK(s_outbound_q ? ESP_OK : ESP_ERR_NO_MEM);

    ESP_ERROR_CHECK(esp_now_init());
    ESP_ERROR_CHECK(esp_now_register_recv_cb(on_recv));
    ESP_ERROR_CHECK(esp_now_register_send_cb(on_sent));

    /* Broadcast discovery follows the channel selected by the recovery hunt. */
    esp_now_peer_info_t broadcast = {};
    memcpy(broadcast.peer_addr, kBroadcastMac, sizeof(kBroadcastMac));
    broadcast.channel = 0;
    broadcast.ifidx = WIFI_IF_STA;
    broadcast.encrypt = false;
    ESP_ERROR_CHECK(esp_now_add_peer(&broadcast));

    if (s_tab5_known) {
        xSemaphoreTake(s_peer_mu, portMAX_DELAY);
        register_tab5_peer_locked(s_tab5_mac);
        xSemaphoreGive(s_peer_mu);
    }

    s_espnow_ready = true;
    s3_ota_init(espnow_send_chunk);
    ESP_LOGI(TAG, "ESP-NOW initialised (channel %d)", s_channel);
}

void espnow_flush_pending_ack()
{
    apply_deferred_learn();
    flush_pending_mod_ack();
}

static void heartbeat_task(void*)
{
    static const uint8_t heartbeat[] = BRIDGE_MOD_HEARTBEAT;
    for (;;) {
        /* Side-band liveness only: never enters either UART queue. The normal
         * ESP-NOW TX mutex serializes it with CNC traffic and OTA packets. */
        (void)espnow_send_to_tab5(heartbeat, BRIDGE_MOD_HEARTBEAT_LEN);
        vTaskDelay(pdMS_TO_TICKS(2000));
    }
}

static void channel_hunt_task(void*)
{
    uint8_t candidate = s_channel;
    for (;;) {
        const uint32_t now = (uint32_t)xTaskGetTickCount();
        const uint32_t last = s_last_link_ok_tick.load(std::memory_order_acquire);
        if ((uint32_t)(now - last) < pdMS_TO_TICKS(5000)) {
            s_channel_hunting.store(false, std::memory_order_release);
            vTaskDelay(pdMS_TO_TICKS(250));
            continue;
        }

        s_channel_hunting.store(true, std::memory_order_release);
        candidate = candidate >= kChannelMax ? kChannelMin : (uint8_t)(candidate + 1);
        /* Do not move the radio while another task waits for an ESP-NOW TX
         * callback. Channel hunting must never corrupt normal CNC traffic. */
        if (xSemaphoreTake(s_tx_lock, pdMS_TO_TICKS(50)) == pdTRUE) {
            if (esp_wifi_set_channel(candidate, WIFI_SECOND_CHAN_NONE) == ESP_OK) {
                s_channel = candidate;
            }
            xSemaphoreGive(s_tx_lock);
        }
        /* Probe the saved Tab5 on every candidate. A two-second heartbeat
         * alone only overlaps one of thirteen short dwell windows by chance. */
        static const uint8_t heartbeat[] = BRIDGE_MOD_HEARTBEAT;
        (void)espnow_send_to_tab5(heartbeat, BRIDGE_MOD_HEARTBEAT_LEN);
        (void)espnow_send_chunk(kBroadcastMac, heartbeat, BRIDGE_MOD_HEARTBEAT_LEN);
        /* Tab5 repeats discovery on its AP channel for five seconds, so a
         * 180 ms dwell guarantees several rendezvous opportunities. */
        vTaskDelay(pdMS_TO_TICKS(180));
    }
}

void espnow_start_inbound_worker()
{
    if (s_inbound_q && !s_inbound_worker_started) {
        xTaskCreatePinnedToCore(inbound_worker, "espnow_in",
                                4096, nullptr, 6, nullptr, 1);
        s_inbound_worker_started = true;
    }
    if (s_outbound_q && !s_outbound_worker_started) {
        xTaskCreatePinnedToCore(outbound_worker, "espnow_out",
                                4096, nullptr, 6, nullptr, 1);
        s_outbound_worker_started = true;
    }
    if (!s_heartbeat_task_started) {
        if (xTaskCreatePinnedToCore(heartbeat_task, "espnow_hb",
                                    3072, nullptr, 4, nullptr, 1) == pdPASS) {
            s_heartbeat_task_started = true;
        } else {
            ESP_LOGW(TAG, "heartbeat task create failed");
        }
    }
    if (!s_channel_hunt_task_started) {
        if (xTaskCreatePinnedToCore(channel_hunt_task, "espnow_hunt",
                                    3072, nullptr, 4, nullptr, 1) == pdPASS) {
            s_channel_hunt_task_started = true;
        } else {
            ESP_LOGW(TAG, "channel hunt task create failed");
        }
    }
}

bool espnow_set_channel(uint8_t ch)
{
    if (!channel_ok(ch) || !s_espnow_ready || !s_peer_mu) {
        return false;
    }
    if (esp_wifi_set_channel(ch, WIFI_SECOND_CHAN_NONE) != ESP_OK) {
        return false;
    }

    s_channel = ch;
    if (!save_channel_nvs(ch)) {
        ESP_LOGW(TAG, "channel NVS save failed (live ch=%d)", ch);
    }

    xSemaphoreTake(s_peer_mu, portMAX_DELAY);
    if (s_tab5_known) {
        register_tab5_peer_locked(s_tab5_mac);
    }
    xSemaphoreGive(s_peer_mu);
    return true;
}

bool espnow_self_check()
{
    if (!s_espnow_ready || !s_inbound_q || !s_outbound_q || !s_tx_lock ||
        !s_tx_done || !s_peer_mu || !s_inbound_worker_started ||
        !s_outbound_worker_started) {
        return false;
    }

    uint8_t primary = 0;
    wifi_second_chan_t second = WIFI_SECOND_CHAN_NONE;
    if (esp_wifi_get_channel(&primary, &second) != ESP_OK) {
        return false;
    }
    return primary == s_channel;
}

void espnow_reset_stats()
{
    s_rx_count.store(0, std::memory_order_relaxed);
    s_tx_count.store(0, std::memory_order_relaxed);
    s_fail_count.store(0, std::memory_order_relaxed);
    s_inbound_drops.store(0, std::memory_order_relaxed);
    s_outbound_drops.store(0, std::memory_order_relaxed);
}

uint8_t espnow_get_channel()
{
    return s_channel;
}

const char* espnow_tab5_mac_str()
{
    return s_mac_str;
}

uint32_t espnow_rx_count()
{
    return s_rx_count.load(std::memory_order_relaxed);
}

uint32_t espnow_tx_count()
{
    return s_tx_count.load(std::memory_order_relaxed);
}

uint32_t espnow_fail_count()
{
    return s_fail_count.load(std::memory_order_relaxed);
}

uint32_t espnow_inbound_drops()
{
    return s_inbound_drops.load(std::memory_order_relaxed);
}

uint32_t espnow_inbound_pending()
{
    return s_inbound_q ? uxQueueMessagesWaiting(s_inbound_q) : 0;
}

uint32_t espnow_outbound_drops()
{
    return s_outbound_drops.load(std::memory_order_relaxed);
}

uint32_t espnow_outbound_pending()
{
    return s_outbound_q ? uxQueueMessagesWaiting(s_outbound_q) : 0;
}

bool espnow_channel_hunting()
{
    return s_channel_hunting.load(std::memory_order_acquire);
}

uint32_t espnow_last_link_age_ms()
{
    const uint32_t last = s_last_link_ok_tick.load(std::memory_order_acquire);
    return (uint32_t)(xTaskGetTickCount() - last) * portTICK_PERIOD_MS;
}
