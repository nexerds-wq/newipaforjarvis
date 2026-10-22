# Solos iPhone HUD — ESP32 Wi-Fi/Bluetooth Classic bridge (experimental)

This is **not a phone-only unlock** of Bluetooth Classic. The original Kopin/Solos display uses Bluetooth Classic RFCOMM, which a normal iPhone application cannot open. This project uses a compatible **original ESP32 (ESP32-WROOM-32 or ESP32-DevKitC)** to receive Solos image packets over Wi-Fi and forward them to the original glasses over Classic Bluetooth. Your Windows PC **does not need any Bluetooth adapter**; it only needs a USB connection to program the ESP32.

## Hardware required

- Original Solos display glasses (not modern AirGo models)
- An **original ESP32** development board that supports Bluetooth Classic, and a USB cable to flash it
- An iPhone (Safari web app is served from the ESP32 itself)
- Windows PC for the initial firmware upload (USB only, no PC Bluetooth)

**Not compatible:** ESP32-C3, ESP32-C6, ESP32-S3, ESP8266; those lack the Bluetooth Classic radio required for the Solos RFCOMM transport.

## Use

1. Install [Espressif ESP-IDF v5.3](https://docs.espressif.com/projects/esp-idf/en/v5.3.3/esp32/get-started/index.html) on Windows, or use GitHub Actions to build the firmware binary and flash with `esptool`.
2. Open an ESP-IDF terminal in this project directory. Run `idf.py set-target esp32` then `idf.py -p COM5 flash monitor` (replace COM5 with the board's actual USB serial port).
3. The ESP32 broadcasts Wi-Fi **SOLOS-HUD-BRIDGE**, password **Solos-HUD-2026**. Change these two hard-coded strings in `main/main.c` before building if you want a different SSID/password.
4. Connect the iPhone to that Wi-Fi network, **stay on it even though it has no Internet**, and visit **http://192.168.4.1** in Safari.
5. Put the original Solos glasses in pairing/discoverable mode. If the iPhone holds an audio connection to them, disconnect the glasses from the iPhone temporarily so the ESP32 can establish its own RFCOMM link.
6. In the web page, tap **Scan nearby Classic Bluetooth**, select the glasses, and tap **Connect**. If they don't show, use their Bluetooth Classic MAC address obtained elsewhere.
7. Only after the status says **RFCOMM socket open**, tap **Wake display** and **Send HUD to glasses**.

## Limitations / troubleshooting

- **Untested on actual Solos hardware.** Compilation alone cannot verify device authentication, RFCOMM channel, or display response.
- The Android source opens service UUID `000011A0-0000-1000-8000-00805F9B34FB` and falls back to RFCOMM channel 1. This project attempts SPP discovery and then channel 1; some glasses may use a different channel or require a separate pairing handshake.
- The iPhone can remain connected to its own Bluetooth headphones; the glasses may need to be disconnected from their iPhone Bluetooth audio connection while the ESP32 is attached.
- Safari is a **phone controller**, not a sideloaded IPA. Its HUD is drawn on the phone and forwarded via the relay.
- The web page intentionally avoids JavaScript geolocation: iOS browsers normally require HTTPS for that API; this bridge uses local HTTP.
- A `200 OK` after sending means the bytes were handed to the Bluetooth Classic stack, **not** that the Solos firmware displayed them.
- Auto refresh every 3 s is deliberately conservative. The Solos headset may have strict timing/buffer limits.
- If pairing fails, examine serial output with `idf.py monitor`. Default legacy PIN is `0000`. Bluetooth pairing confirmation is automatically accepted only for the user-selected peer. This remains a prototype, not a security-hardened product.
- Some firmware versions may reject the RFCOMM service or the phone's frame encoding.

## File layout

- `main/main.c` — ESP32 Bluetooth Classic client, Wi-Fi access point, HTTP relay
- `main/phone.html` — iPhone Safari HUD controller; renders binary RLE565 protocol frames
- `.github/workflows/build-esp32.yml` — optional GitHub Actions firmware build

## Protocol references

- [Solos Android Bluetooth sender code](https://github.com/StudentBroken/solos-hud/blob/main/solos_hud/android/app/src/main/kotlin/com/xumic/solos_hud/SolosBluetoothPlugin.kt)
- [Solos 428×240 image encoding code](https://github.com/StudentBroken/solos-hud/blob/main/solos_hud/lib/core/solos_protocol.dart)
- [Espressif SPP initiator documentation](https://docs.espressif.com/projects/esp-idf/en/v5.3.3/esp32/api-reference/bluetooth/esp_spp.html)