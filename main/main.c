// Experimental original Solos HUD relay: iPhone (Wi-Fi) -> ESP32 -> RFCOMM.
// Target: original ESP32 (BT Classic), ESP-IDF v5.3.x.
// Only attempts Bluetooth when a user explicitly chooses a target device.
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <stdbool.h>
#include <string.h>
#include <ctype.h>
#include <inttypes.h>
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/semphr.h"
#include "esp_err.h"
#include "esp_log.h"
#include "esp_event.h"
#include "nvs_flash.h"
#include "esp_wifi.h"
#include "esp_netif.h"
#include "esp_http_server.h"
#include "esp_bt.h"
#include "esp_bt_main.h"
#include "esp_bt_device.h"
#include "esp_gap_bt_api.h"
#include "esp_spp_api.h"

#define AP_SSID "SOLOS-HUD-BRIDGE"
#define AP_PASS "Solos-HUD-2026"
#define MAX_DEVICES 24
#define MAX_PACKET (32 * 1024)
#define BT_CHUNK 480
static const char *TAG = "solos_bridge";
extern const unsigned char phone_html_start[] asm("_binary_phone_html_start");
extern const unsigned char phone_html_end[] asm("_binary_phone_html_end");

typedef struct { char mac[18]; char name[50]; } found_device_t;
static found_device_t discovered[MAX_DEVICES];
static int num_discovered = 0;
static volatile bool discovering = false;
static volatile bool spp_ready = false;
static volatile bool bt_connected = false;
static volatile bool bt_connecting = false;
static volatile uint32_t spp_handle = 0;
static volatile bool write_error = false;
static volatile bool congested = false;
static volatile unsigned frames_sent = 0;
static volatile int active_channel = 0;
static esp_bd_addr_t selected_bda = {0};
static char selected_mac[18] = "";
static char stage[64] = "starting";
static SemaphoreHandle_t write_done;
static SemaphoreHandle_t write_gate;
static SemaphoreHandle_t state_lock;

static void addr_to_text(const uint8_t *addr, char out[18]) {
    snprintf(out, 18, "%02X:%02X:%02X:%02X:%02X:%02X", addr[0], addr[1], addr[2], addr[3], addr[4], addr[5]);
}
static bool text_to_addr(const char *s, uint8_t addr[6]) {
    unsigned a[6];
    if (sscanf(s, "%2x:%2x:%2x:%2x:%2x:%2x", &a[0], &a[1], &a[2], &a[3], &a[4], &a[5]) != 6) return false;
    for (int i = 0; i < 6; i++) addr[i] = (uint8_t)a[i];
    return true;
}
static void safe_name(char dst[50], const uint8_t *src, int n) {
    int j = 0;
    for (int i = 0; i < n && j < 49; i++) {
        char c = (char)src[i];
        if (!c) break;
        dst[j++] = (isalnum((unsigned char)c) || c == ' ' || c == '-' || c == '_') ? c : ' ';
    }
    dst[j] = 0;
}
static void add_discovered(const uint8_t *mac, const char *name) {
    char addr[18]; addr_to_text(mac, addr);
    xSemaphoreTake(state_lock, portMAX_DELAY);
    int index = -1;
    for (int i = 0; i < num_discovered; i++) if (!strcmp(discovered[i].mac, addr)) index = i;
    if (index < 0 && num_discovered < MAX_DEVICES) index = num_discovered++;
    if (index >= 0) {
        snprintf(discovered[index].mac, 18, "%s", addr);
        if (name && *name) snprintf(discovered[index].name, 50, "%s", name);
        else if (!discovered[index].name[0]) snprintf(discovered[index].name, 50, "Unknown Classic device");
    }
    xSemaphoreGive(state_lock);
}
static void bt_gap_callback(esp_bt_gap_cb_event_t evt, esp_bt_gap_cb_param_t *p) {
    switch (evt) {
    case ESP_BT_GAP_DISC_RES_EVT: {
        char name[50] = "";
        for (int i = 0; i < p->disc_res.num_prop; i++) {
            esp_bt_gap_dev_prop_t *prop = &p->disc_res.prop[i];
            if (prop->type == ESP_BT_GAP_DEV_PROP_BDNAME && prop->val) {
                safe_name(name, (const uint8_t *)prop->val, prop->len);
            }
        }
        add_discovered(p->disc_res.bda, name);
        break;
    }
    case ESP_BT_GAP_DISC_STATE_CHANGED_EVT:
        discovering = (p->disc_st_chg.state == ESP_BT_GAP_DISCOVERY_STARTED);
        break;
    case ESP_BT_GAP_PIN_REQ_EVT: {
        // Legacy Solos models may request a PIN. This can be changed if required.
        esp_bt_pin_code_t pin = {'0','0','0','0'};
        esp_bt_gap_pin_reply(p->pin_req.bda, true, 4, pin);
        break;
    }
    case ESP_BT_GAP_CFM_REQ_EVT:
        // Only intentional local connections should cause confirmation.
        if (bt_connecting && !memcmp(p->cfm_req.bda, selected_bda, 6))
            esp_bt_gap_ssp_confirm_reply(p->cfm_req.bda, true);
        else esp_bt_gap_ssp_confirm_reply(p->cfm_req.bda, false);
        break;
    default: break;
    }
}
static void connect_channel(uint8_t channel) {
    active_channel = channel;
    snprintf(stage, sizeof(stage), "connecting RFCOMM ch %u", channel);
    esp_err_t err = esp_spp_connect(ESP_SPP_SEC_AUTHENTICATE, ESP_SPP_ROLE_MASTER, channel, selected_bda);
    if (err != ESP_OK) {
        bt_connecting = false;
        snprintf(stage, sizeof(stage), "RFCOMM connect request failed (%d)", (int)err);
    }
}
static void spp_callback(esp_spp_cb_event_t evt, esp_spp_cb_param_t *p) {
    switch (evt) {
    case ESP_SPP_INIT_EVT:
        spp_ready = p->init.status == ESP_SPP_SUCCESS;
        snprintf(stage, sizeof(stage), "%s", spp_ready ? "ready for discovery" : "SPP initialization failed");
        break;
    case ESP_SPP_DISCOVERY_COMP_EVT:
        if (!bt_connecting) break;
        if (p->disc_comp.status == ESP_SPP_SUCCESS && p->disc_comp.scn_num > 0) {
            // Service discovery may not return vendor-specific Solos 0x11A0;
            // when absent fall back to channel 1 as in Android project.
            connect_channel(p->disc_comp.scn[0]);
        } else {
            ESP_LOGW(TAG, "SPP service not advertised; attempting legacy channel 1");
            connect_channel(1);
        }
        break;
    case ESP_SPP_OPEN_EVT:
        bt_connecting = false;
        if (p->open.status == ESP_SPP_SUCCESS) {
            bt_connected = true;
            spp_handle = p->open.handle;
            snprintf(stage, sizeof(stage), "RFCOMM socket open");
            ESP_LOGI(TAG, "Connected on channel %d", active_channel);
        } else {
            bt_connected = false;
            snprintf(stage, sizeof(stage), "RFCOMM rejected: code %d", (int)p->open.status);
        }
        break;
    case ESP_SPP_CLOSE_EVT:
        bt_connected = false;
        bt_connecting = false;
        spp_handle = 0;
        snprintf(stage, sizeof(stage), "RFCOMM disconnected");
        if (write_done) xSemaphoreGive(write_done);
        break;
    case ESP_SPP_WRITE_EVT:
        congested = p->write.cong;
        write_error = p->write.status != ESP_SPP_SUCCESS;
        if (write_done) xSemaphoreGive(write_done);
        break;
    case ESP_SPP_CONG_EVT:
        congested = p->cong.cong;
        if (!congested && write_done) xSemaphoreGive(write_done);
        break;
    default: break;
    }
}
static bool bt_send_packet(const uint8_t *bytes, int length) {
    if (!bt_connected || length < 1 || length > MAX_PACKET) return false;
    if (xSemaphoreTake(write_gate, pdMS_TO_TICKS(100)) != pdTRUE) return false;
    uint32_t handle = spp_handle;
    bool ok = true;
    int offset = 0;
    while (offset < length && bt_connected && handle == spp_handle) {
        while (congested && bt_connected) {
            if (xSemaphoreTake(write_done, pdMS_TO_TICKS(2500)) != pdTRUE) { ok = false; break; }
        }
        if (!ok || !bt_connected) break;
        int n = (length - offset < BT_CHUNK) ? (length - offset) : BT_CHUNK;
        xSemaphoreTake(write_done, 0); // discard prior signal
        write_error = false;
        esp_err_t err = esp_spp_write(handle, n, (uint8_t *)bytes + offset);
        if (err != ESP_OK || xSemaphoreTake(write_done, pdMS_TO_TICKS(3000)) != pdTRUE || write_error) {
            ok = false; break;
        }
        offset += n;
    }
    if (offset < length) ok = false;
    if (ok) frames_sent++;
    xSemaphoreGive(write_gate);
    return ok;
}
static esp_err_t send_json(httpd_req_t *req, const char *data) {
    httpd_resp_set_type(req, "application/json");
    httpd_resp_set_hdr(req, "Cache-Control", "no-store");
    return httpd_resp_sendstr(req, data);
}
static esp_err_t failure(httpd_req_t *req, const char *why, const char *code) {
    httpd_resp_set_status(req, code ? code : "400 Bad Request");
    char buf[160]; snprintf(buf, sizeof(buf), "{\"error\":\"%s\"}", why);
    return send_json(req, buf);
}
static esp_err_t page_handler(httpd_req_t *req) {
    httpd_resp_set_type(req, "text/html; charset=utf-8");
    httpd_resp_set_hdr(req, "Cache-Control", "no-store");
    return httpd_resp_send(req, (const char *)phone_html_start, phone_html_end - phone_html_start);
}
static esp_err_t status_handler(httpd_req_t *req) {
    char out[256];
    snprintf(out, sizeof(out), "{\"connected\":%s,\"connecting\":%s,\"state\":\"%s\",\"peer\":\"%s\",\"channel\":%d,\"frames\":%u}",
        bt_connected ? "true" : "false", bt_connecting ? "true" : "false", stage, selected_mac, active_channel, frames_sent);
    return send_json(req, out);
}
static esp_err_t scan_handler(httpd_req_t *req) {
    if (!spp_ready) return failure(req, "Bluetooth Classic has not initialized", "503 Service Unavailable");
    if (bt_connected || bt_connecting) return failure(req, "Disconnect the glasses before scanning", "409 Conflict");
    if (discovering) return send_json(req, "{\"scanning\":true}");
    xSemaphoreTake(state_lock, portMAX_DELAY);
    memset(discovered, 0, sizeof(discovered)); num_discovered = 0;
    xSemaphoreGive(state_lock);
    esp_err_t e = esp_bt_gap_start_discovery(ESP_BT_INQ_MODE_GENERAL_INQUIRY, 10, 0);
    if (e != ESP_OK) return failure(req, "Bluetooth inquiry could not start", "503 Service Unavailable");
    discovering = true;
    return send_json(req, "{\"scanning\":true}");
}
static esp_err_t devices_handler(httpd_req_t *req) {
    char out[4400]; int n = snprintf(out, sizeof(out), "{\"scanning\":%s,\"devices\":[", discovering ? "true" : "false");
    xSemaphoreTake(state_lock, portMAX_DELAY);
    for (int i = 0; i < num_discovered && n < sizeof(out) - 180; i++)
        n += snprintf(out + n, sizeof(out) - n, "%s{\"mac\":\"%s\",\"name\":\"%s\"}",
            i ? "," : "", discovered[i].mac, discovered[i].name);
    xSemaphoreGive(state_lock);
    snprintf(out + n, sizeof(out) - n, "]}");
    return send_json(req, out);
}
static esp_err_t connect_handler(httpd_req_t *req) {
    if (!spp_ready) return failure(req, "Bluetooth Classic is not ready", "503 Service Unavailable");
    if (bt_connected || bt_connecting) return failure(req, "Already connected or connecting; power-cycle bridge to reset", "409 Conflict");
    if (req->content_len < 17 || req->content_len > 25) return failure(req, "Expected Bluetooth MAC", NULL);
    char mac[27] = {0};
    int n = httpd_req_recv(req, mac, req->content_len);
    if (n < 17 || !text_to_addr(mac, selected_bda)) return failure(req, "Invalid Bluetooth MAC", NULL);
    addr_to_text(selected_bda, selected_mac);
    bt_connecting = true;
    if (discovering) esp_bt_gap_cancel_discovery();
    snprintf(stage, sizeof(stage), "discovering Bluetooth service");
    esp_err_t e = esp_spp_start_discovery(selected_bda);
    if (e != ESP_OK) connect_channel(1);
    return send_json(req, "{\"message\":\"Started Bluetooth service discovery; check status in a few seconds\"}");
}
static esp_err_t wake_handler(httpd_req_t *req) {
    const uint8_t packet[10] = {0x1d,0x60,0x04,0,0,0,0,0,0,0};
    if (!bt_connected) return failure(req, "Bluetooth RFCOMM not connected", "409 Conflict");
    if (!bt_send_packet(packet, sizeof(packet))) return failure(req, "Bluetooth wake send failed", "503 Service Unavailable");
    return send_json(req, "{\"ok\":true}");
}
static esp_err_t packet_handler(httpd_req_t *req) {
    if (!bt_connected) return failure(req, "Bluetooth RFCOMM not connected; select your glasses first", "409 Conflict");
    int len = req->content_len;
    if (len < 24 || len > MAX_PACKET) return failure(req, "Invalid packet size (24 to 32768 bytes)", NULL);
    uint8_t *buf = malloc(len);
    if (!buf) return failure(req, "Not enough ESP32 memory", "503 Service Unavailable");
    int got = 0;
    while (got < len) {
        int n = httpd_req_recv(req, (char *)buf + got, len - got);
        if (n <= 0) { free(buf); return failure(req, "Failed to read phone packet", "400 Bad Request"); }
        got += n;
    }
    uint32_t payload = ((uint32_t)buf[6]) | ((uint32_t)buf[7] << 8) | ((uint32_t)buf[8] << 16) | ((uint32_t)buf[9] << 24);
    if (buf[0] != 0x1d || buf[1] != 0x60 || buf[2] != 5 || buf[3] != 0 || payload != (uint32_t)len - 10) {
        free(buf); return failure(req, "Not a valid Solos IMAGE packet", NULL);
    }
    bool ok = bt_send_packet(buf, len);
    free(buf);
    if (!ok) return failure(req, "Bluetooth send timed out / congested", "503 Service Unavailable");
    return send_json(req, "{\"ok\":true}");
}
static void run_http(void) {
    httpd_config_t conf = HTTPD_DEFAULT_CONFIG();
    conf.max_uri_handlers = 9;
    conf.stack_size = 8192;
    conf.recv_wait_timeout = 15;
    conf.send_wait_timeout = 15;
    httpd_handle_t httpd = NULL;
    ESP_ERROR_CHECK(httpd_start(&httpd, &conf));
#define URI(path,verb,func) do { httpd_uri_t route = {.uri=path,.method=verb,.handler=func,.user_ctx=NULL}; ESP_ERROR_CHECK(httpd_register_uri_handler(httpd, &route)); } while (0)
    URI("/", HTTP_GET, page_handler);
    URI("/api/status", HTTP_GET, status_handler);
    URI("/api/scan", HTTP_POST, scan_handler);
    URI("/api/devices", HTTP_GET, devices_handler);
    URI("/api/connect", HTTP_POST, connect_handler);
    URI("/api/wake", HTTP_POST, wake_handler);
    URI("/api/send", HTTP_POST, packet_handler);
#undef URI
}
static void run_wifi(void) {
    ESP_ERROR_CHECK(esp_netif_init());
    ESP_ERROR_CHECK(esp_event_loop_create_default());
    esp_netif_create_default_wifi_ap();
    wifi_init_config_t cfg = WIFI_INIT_CONFIG_DEFAULT();
    ESP_ERROR_CHECK(esp_wifi_init(&cfg));
    wifi_config_t ap = {0};
    memcpy(ap.ap.ssid, AP_SSID, strlen(AP_SSID));
    ap.ap.ssid_len = strlen(AP_SSID);
    memcpy(ap.ap.password, AP_PASS, strlen(AP_PASS));
    ap.ap.authmode = WIFI_AUTH_WPA2_PSK;
    ap.ap.max_connection = 2;
    ap.ap.channel = 6;
    ESP_ERROR_CHECK(esp_wifi_set_mode(WIFI_MODE_AP));
    ESP_ERROR_CHECK(esp_wifi_set_config(WIFI_IF_AP, &ap));
    ESP_ERROR_CHECK(esp_wifi_start());
    ESP_LOGI(TAG, "Connect iPhone Wi-Fi to %s, then open http://192.168.4.1", AP_SSID);
}
static void run_bluetooth(void) {
    // Classic-only frees BLE controller memory, saving space for frame buffers.
    ESP_ERROR_CHECK(esp_bt_controller_mem_release(ESP_BT_MODE_BLE));
    esp_bt_controller_config_t cfg = BT_CONTROLLER_INIT_CONFIG_DEFAULT();
    ESP_ERROR_CHECK(esp_bt_controller_init(&cfg));
    ESP_ERROR_CHECK(esp_bt_controller_enable(ESP_BT_MODE_CLASSIC_BT));
    ESP_ERROR_CHECK(esp_bluedroid_init());
    ESP_ERROR_CHECK(esp_bluedroid_enable());
    ESP_ERROR_CHECK(esp_bt_dev_set_device_name("Solos HUD Bridge"));
    ESP_ERROR_CHECK(esp_bt_gap_register_callback(bt_gap_callback));
    ESP_ERROR_CHECK(esp_spp_register_callback(spp_callback));
    ESP_ERROR_CHECK(esp_spp_init(ESP_SPP_MODE_CB));
}
void app_main(void) {
    esp_err_t err = nvs_flash_init();
    if (err == ESP_ERR_NVS_NO_FREE_PAGES || err == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        ESP_ERROR_CHECK(nvs_flash_erase());
        err = nvs_flash_init();
    }
    ESP_ERROR_CHECK(err);
    state_lock = xSemaphoreCreateMutex();
    write_gate = xSemaphoreCreateMutex();
    write_done = xSemaphoreCreateBinary();
    configASSERT(state_lock && write_gate && write_done);
    run_bluetooth();
    run_wifi();
    run_http();
    ESP_LOGI(TAG, "Experimental bridge running; no firmware changes to glasses");
}