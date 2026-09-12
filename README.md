<p align="center">
  <img src="assets/modulus-firmware-hero.png" alt="Modulus Firmware — Tab5 CNC pendant" width="720">
</p>

<p align="center">
  <strong>English</strong> · <a href="README.de.md">Deutsch</a>
</p>

# Modulus Firmware

**Version:** 3.1.3-ota<br>
**Author:** D. McLean / BufferRoot  
**Platform:** M5Stack Tab5 (ESP32-P4 + ESP32-C6)  
**Stack:** Zig 0.16 + ESP-IDF 6  
**Hackster:** [Modulus pendant](https://www.hackster.io/BufferRoot/modulus-the-ultimate-universal-smart-cnc-pendant-2587ed) · [M5Stack GIC 2026](https://m5stack.com/global-innovation-contest-2026)  
**License:** [MIT](LICENSE)

**One Device, One Software. Real control for any machine — no lag, no brand lock-in, no compromise.**

## Why this OTA feature branch exists

Modulus runs across multiple processors, but the Tab5's ESP32-C6 radio and the
cabinet ESP32-S3 bridge traditionally required separate USB/bootloader access.
This branch adds guarded **C6 Update** and **S3 Update** pages to M Panel. C6
application images travel over the internal ESP-Hosted/SDIO link; S3
application images travel over ESP-NOW. Both updater pages read the root of a
FAT-formatted USB-A drive and reject images built for the wrong chip. microSD
support was useful during development, but was removed from the updater UI
because the slot is inaccessible in many installed enclosures and presenting
two maintenance sources made the workflow unnecessarily ambiguous. Other
Modulus microSD features are unchanged.

The maintenance sequence is **P4 first, then C6 and/or S3**: install the P4
firmware containing the OTA UI, boot Modulus normally, and select the matching
updater. The XIAO ESP32-S3 needs the OTA-capable full image once over USB; later
updates use only its application image. Image inspection, explicit arming,
progress feedback, and a guarded restart keep every write deliberate. After a
successful C6 activation, the P4 restarts automatically after three seconds to
resynchronize the ESP-Hosted/SDIO link.
Nothing is flashed automatically.

The complete C6 and XIAO S3 OTA paths, including an S3 update from USB-A and a
successful boot from its second OTA slot, have been verified on real hardware.

> [!IMPORTANT]
> **OTA must be enabled by a one-time wired flash first.** Flash the P4 package
> over USB so the Tab5 has the OTA menus. A new or previously installed XIAO
> ESP32-S3 must then be flashed once over USB at offset `0x0` with
> `modulus-xiao-s3-first-flash-for-ota-*.bin`. This installs the OTA receiver
> and dual-slot partition table. Only after that first flash can subsequent S3
> updates use `modulus-xiao-s3-ota-app-*.bin` through **M Panel → S3 Update**.
> Do not send the first-flash/full image through the OTA menu.

For the Tab5 C6, the stock ESP-Hosted firmware already provides slave OTA. The
P4 OTA-enabled firmware still has to be installed first before **C6 Update** is
available. If the C6 no longer boots or answers over SDIO, restore its complete
flash package over the C6 USB bootloader before using OTA again.

Handheld DRO + MPG **client** on Tab5 — Zig dual-core anti-lag firmware talking to grblHAL (and other engines) over ESP-NOW or RS-485. It does not replace your motion controller.

Most M5 projects cram UI and radio onto one busy chip. Modulus uses Tab5 as designed: **P4** dual-core HMI/control, **C6** for Wi-Fi/BLE/ESP-NOW, **NanoH2** for Zigbee — so motion RF and shop-IoT RF never fight.

---

## Four-firmware architecture

```
                 [Operator touch UI + MPG wheel]
                              │
                              ▼
┌──────────────────── ESP32-P4 (Tab5 main MCU) ────────────────────┐
│  Core 0: LVGL 720p Material 3 UI · settings · audio (async)      │
│  Core 1: heap-free ~100 Hz MPG poll · envelope · command stream  │
└─────────┬──────────────────────┬───────────────────────┬─────────┘
          │ SDIO2                │ UART GPIO6/7          │ UART1
          ▼                      ▼                       ▼
┌───────────────────┐  ┌───────────────────┐  ┌───────────────────┐
│ ESP32-C6          │  │ NanoH2 (ESP32-H2) │  │ SIT3088 RS-485    │
│ Wi-Fi 6 / BLE /   │  │ ZBOSS Zigbee hub  │  │ wired field bus   │
│ ESP-NOW           │  │ shop automation   │  │                   │
└─────────┬─────────┘  └───────────────────┘  └───────────────────┘
          │ ESP-NOW
          ▼
┌───────────────────┐
│ ESP32-S3 bridge   │ ── UART ──► CNC controller (e.g. grblHAL)
└───────────────────┘
```

| Target | Job |
|--------|-----|
| **P4** | Core 0 = UI · Core 1 = heap-free ~100 Hz MPG / envelope / streams |
| **C6** | Wi-Fi 6, BLE, ESP-NOW only (never Zigbee-exclusive builds) |
| **NanoH2** | Zigbee coordinator @ 460800 baud UART — vacuums, lights, fans |
| **S3 bridge** | Cabinet ESP-NOW → UART to controller |

**Why Zig:** no GC. Core 1 never touches the allocator, so a heavy Core 0 frame cannot stall the handwheel. Error unions + `defer` for deterministic transport cleanup. Zig owns state/jog/ABI (`src/modulus/`); C shims own IDF/BSP/LVGL.

---

## Anti-lag design

| Shop failure | Fix |
|--------------|-----|
| UI redraw delays jog | Dual-core — Core 1 never blocks on LVGL |
| Wi-Fi reconnect freezes pendant | ESP-NOW is connectionless — drop bad frame, run next |
| Bridge backlog under RF hit | Bounded S3 queue — stale frames drop (50 ms TTL) |
| 10 clicks ≠ 10 steps | `envelope.zig` clamp + NVS divider/polarity before send |
| UI refresh starves Core 0 | Dashboard timer floor ≥ 33 ms (never 16 ms under `sw_rotate`) |

**Bench numbers** (grblHAL + ESP-NOW + S3):

| Metric | Value |
|--------|-------|
| Wheel-to-motion latency | **2 ms** |
| MPG poll (Core 1) | ~100 Hz |
| ESP-NOW RTT (P4↔S3) | **25 ms** |
| Late-frame drop TTL | 50 ms |
| UI refresh floor @ 720p | ≥ 33 ms |
| ESP-NOW PHY default | 24M OFDM |
| Cold boot → live DRO | ~16 s |
| Runtime per pack | 8–10+ h (NP-F hot-swap) |

---

## Features

| Feature | Notes |
|---------|--------|
| Live multi-axis DRO + MPG | ExtEncoder; 0.001–1.0 mm detent steps |
| Overrides / hold / cycle / macros | Native commands — no HID keyboard hacks |
| Multi-engine client | grblHAL, Grbl, FluidNC, LinuxCNC, Mach3/4, Masso |
| Multi-transport | ESP-NOW, RS-485, USB serial, WebSocket, Telnet, BLE |
| Zigbee shop IoT | NanoH2 hub — Run can start dust extraction; Hold/Alarm spins down |
| Material 3 UI | Dark/light + accents · 10 settings tabs · Quick Settings · PIN lock |
| Power | INA226 (%, V, A, W) · NP-F hot-swap · PMIC soft shutdown |

**Honest status:** pendant stack complete; **grblHAL over ESP-NOW (Tab5↔S3) field-verified**. Full motion soak + live Zigbee soak still open. Other engines/transports implemented, not all field-verified. Keep the machine E-Stop in reach.

### Transports (`cnc_conn`)

✅ field-verified · 🔧 implemented · ⏳ planned

| Transport | Path | Status |
|-----------|------|--------|
| ESP-NOW | C6 → air → S3 → UART | ✅ |
| RS-485 | UART1 TX20 / RX21 / DE34 | 🔧 |
| USB serial | Direct USB / UART | 🔧 |
| WebSocket | C6 Wi-Fi | 🔧 |
| Telnet | C6 Wi-Fi | 🔧 |
| BLE | NimBLE on C6 | 🔧 |
| I2C | Bus peer | 🔧 |
| CAN | via COMMU | ⏳ |

### Motion engines (`cnc_proto`)

| Engine | Typical transport | Status |
|--------|-------------------|--------|
| grblHAL | ESP-NOW / RS-485 | ✅ |
| Classic Grbl | RS-485 / serial | 🔧 |
| FluidNC | WebSocket | 🔧 |
| LinuxCNC | Telnet | 🔧 |
| Mach3 / Mach4 | Telnet | 🔧 |
| Masso | WebSocket / UDP | 🔧 |

### Safety

Pendant E-Stop is a **convenience layer**, not a safety-rated cutoff. It rides the active link (GPIO16 NO → feed-hold `!` then soft reset). **If the wireless link is down, pendant E-Stop will not stop the machine.** Machine mushroom E-Stop is primary. Software: `envelope.zig` soft limits, zero-while-running confirm, link-offline warnings, low-battery MPG lockout.

**Out of scope (roadmap):** SC2356 camera UI · on-screen FFT · OTA dual-partition · PCNT GPIO quadrature (replace I²C ExtEncoder).

---

## Directory layout

```
src/modulus/         Zig: state, jog math, cnc_proto, envelope, ABI
firmware/tab5/       P4 app: IDF/BSP/LVGL C shims + modulus_zig
firmware/tab5-c6/    C6 ESP-Hosted wireless slave
firmware/nanoh2/     H2 Zigbee coordinator (ZBOSS)
firmware/s3-bridge/  ESP-NOW → UART bridge
cad/                 STL + CAD (enclosure / mounts)
schematics/          Schematics + wiring diagrams
assets/              README media (hero image)
scripts/             Build / flash helpers
tools/               NVS manifest generator (used by zig build)
LICENSE              MIT
```

---

## Prebuilt flash images — v3.1.3-ota

Download the three full images from the existing
[release v3.1.3-ota](https://github.com/fellpower/Modulus-Firmware/releases/tag/v3.1.3-ota).
No local firmware build or ZIP extraction is needed to flash these BINs.

| Target | Single USB flash image | Address |
|--------|------------------------|---------|
| Tab5 P4 | `modulus-tab5-p4-full-v3.1.3-ota.bin` | `0x0` |
| Tab5 C6 | `modulus-tab5-c6-full-v3.1.3-ota.bin` | `0x0` |
| XIAO ESP32-S3 | `modulus-xiao-s3-full-v3.1.3-ota.bin` | `0x0` |

These combine the released bootloader, partition table, initial OTA data (C6/S3)
and application. The P4 bootloader remains at `0x2000` inside its full image;
the XIAO S3 application remains at `0x20000`. Always flash the **full BIN at `0x0`**.
Unused gaps are filled with `0xFF`; writing a full image can reset NVS/settings
and OTA selection within its address range. Use app-only OTA for later C6/S3 updates.

### USB installation / recovery

Install esptool with `python -m pip install esptool==5.3.1`. Open a terminal in
the download folder. Replace the example COM ports with the actual target ports.
Use a USB data cable and connect the correct processor's USB bootloader: the
Tab5 P4 port does not directly flash the C6. The C6 requires its internal
programming connector and a USB-TTL downloader; see the
[M5Stack C6 recovery guide](https://docs.m5stack.com/en/guide/restore_factory/m5tab5_c6_wifi).
If necessary, enter the target's
BOOT/download mode before connecting. Flash P4 first, then C6 if recovery or a
wired installation is needed, then XIAO S3.

```powershell
python -m esptool --chip esp32p4 -p COM5 write-flash --flash-mode dio --flash-freq 40m --flash-size 16MB 0x0 modulus-tab5-p4-full-v3.1.3-ota.bin
python -m esptool --chip esp32c6 -p COM6 write-flash --flash-mode dio --flash-freq 80m --flash-size 4MB 0x0 modulus-tab5-c6-full-v3.1.3-ota.bin
python -m esptool --chip esp32s3 -p COM8 write-flash --flash-mode dio --flash-freq 80m --flash-size 8MB 0x0 modulus-xiao-s3-full-v3.1.3-ota.bin
```

Run only the command matching the connected chip. A GUI flasher likewise needs
one file, address `0x0`, and the matching chip/settings. Wait for verification,
then restart the board. A separate `erase-flash` is not part of this procedure.
The older `modulus-xiao-s3-first-flash-for-ota-v3.1.3-ota.bin` is equivalent to
the new XIAO full image. This XIAO image is not the generic S3 bridge package.

### C6 compatibility in subsequent source builds

The branch queries the **running C6 firmware immediately before writing**.
Below 2.6.0 (including 1.4.1), legacy `OTAEnd` activates the image and schedules
the C6 reboot; no `OTAActivate` is sent. The P4 waits eight seconds before
restarting. From 2.6.0 onward, explicit activation is followed by the existing
three-second P4 restart delay. Unknown/unreadable versions stop before any write.
A working ESP-Hosted connection and suitable C6 OTA partition remain necessary.
A lost completion/activation response is reported as uncertain, not as proof
that activation did not happen.

**This change is source-only: existing v3.1.3-ota release BINs have not been
rebuilt and retain the previous behavior.** Run the host regression test with
`python scripts/test_c6_ota.py` (requires Zig). Hardware validation with factory
1.4.1 is still required.

### Later C6/S3 updates through Tab5

1. Boot the P4 and confirm **M Panel → C6 Update / S3 Update** are available.
2. Download `modulus-tab5-c6-ota-app-v3.1.3-ota.bin` or
   `modulus-xiao-s3-ota-app-v3.1.3-ota.bin` from the same release.
3. Copy the matching **app-only** BIN to the root of a FAT32 USB drive and insert
   it into the Tab5 USB-A port. microSD is not an OTA source.
4. Open the matching update page, press **Refresh USB**, select the file and
   **Check image** (C6) / **Check S3 image** (S3).
5. Confirm **Flash C6** / **Flash S3**. Keep the machine idle and power/stick connected.
6. C6 activation restarts the P4 automatically after three seconds. For S3,
   select **Restart S3** after successful verification.

Never select a full BIN, bootloader, partition table, OTA-data file or ZIP in
an OTA menu. The XIAO needs its USB full-image installation once before S3 OTA.
If C6 cannot boot or answer over SDIO, use the C6 USB full image above.

After flashing, check the dashboard and ESP-NOW connection. Set the S3 MAC and
matching channel under **Settings → Wireless** again if settings were reset.
NanoH2 and generic S3 packages remain available separately in the release;
follow their included `FLASH.md`.

### Reproduce the full images without rebuilding

Download `MANIFEST.json` and the three release ZIPs
`modulus-tab5-p4-v3.1.3-ota.zip`, `modulus-tab5-c6-v3.1.3-ota.zip`, and
`modulus-s3-xiao-v3.1.3-ota.zip`. Place the manifest in
`dist/flash-images/v3.1.3-ota-source/` and extract each ZIP below that directory,
retaining its target folder and `flasher_args.json`.

```powershell
.\scripts\package_flash_images.ps1 -Version 3.1.3-ota
```

The script validates input sizes and SHA256 against the release manifest and
uses the recorded flash offsets. It only merges existing bytes with esptool;
it never builds firmware or falls back to local build directories. It produces
exactly the three full BINs, `SHA256SUMS-full.txt`, and `FLASH-full.md` under
`dist/flash-images/v3.1.3-ota-full/`. Use `-SourceRoot` and `-OutRoot` to change
folders; existing output BINs are rejected. These files are not padded to the
entire flash-chip capacity. Compare hashes with the [recorded full-image checksums](FULL-IMAGES-v3.1.3-ota.sha256).

The all-firmware ZIP also contains the three full BINs directly in its root,
plus the original per-target files, OTA apps and licenses. To update an existing
bundle without rebuilding, download its ZIP, release `MANIFEST.json`,
`FLASH-INSTRUCTIONS-EN-DE.md`, and `SHA256SUMS.txt` into a source folder, then run:

```powershell
python scripts/update_all_firmware_bundle.py --source dist/release-refresh/source --full-images dist/flash-images/v3.1.3-ota-full --output dist/release-refresh/upload
```

Use an empty output folder. The helper checks the original bundle and full BINs,
updates internal and external checksums/manifest, and writes a replacement ZIP.
Upload all four output files together when updating the existing release.

German hardware test procedure: [C6 legacy OTA test](C6-LEGACY-TEST.de.md).

German recording notes: [Videoanleitung](VIDEOANLEITUNG.de.md).

---

## Build from source

**Prerequisites:** Zig **0.16+** · ESP-IDF **6.0**

```bash
git clone https://github.com/BufferRoot/Modulus-Firmware.git
cd Modulus-Firmware
zig build test        # host logic + ABI parity
zig build tab5-lib    # freestanding Zig library
```

| Target | Command |
|--------|---------|
| Tab5 P4 | `.\scripts\build_tab5.ps1` then `.\scripts\flash_tab5.ps1 -Port COM5` |
| Tab5 C6 + P4 | `.\scripts\flash_tab5_dual.ps1 -C6Port COM6 -P4Port COM5` *(never `-ZigbeeExclusive`)* |
| NanoH2 | `idf.py -C firmware/nanoh2 flash` (hold BUTTON; enable EXT5V) |
| S3 bridge | `.\scripts\build_s3_bridge.ps1 -Action flash -Port COM8` |
| S3 XIAO | same image: USB shell `board xiao` (or factory ` -Board xiao`) then flash |

> **Use the build scripts — plain `idf.py build` is not supported for Tab5 P4.**
>
> `scripts/build_tab5.ps1` runs `scripts/patch_tab5_idf6_deps.ps1` first, which
> patches the *managed components* for ESP-IDF 6: `esp_hosted`'s CMakeLists for
> the moved `sdmmc` headers, a retry-safe `gpio_reset_pin` before GPIO
> reconfigure, and the Modulus SDIO diagnostics/drain constants. Those files
> live under `managed_components/`, which is gitignored and regenerated by the
> component manager — so the patches are reapplied on every build and are lost
> after `idf.py fullclean` or a dependency re-solve.
>
> Running `idf.py build` directly gives an image that either fails to compile or
> boots with a broken SDIO link to the C6 (`sdmmc_send_cmd returned 0x107`).
>
> `dependencies.lock` **is tracked** for every firmware. Do not delete it to
> "get newer components": an unpinned re-solve pulls releases that assume a
> newer IDF than 6.0.1 and the build breaks
> ([#2](https://github.com/BufferRoot/Modulus-Firmware/issues/2)).

Merge the existing release files into full BINs: `.\scripts\package_flash_images.ps1` (see above).

### Updating the Tab5 C6 from Modulus

The Tab5 **M Panel → C6 Update** page updates the ESP32-C6 over the internal
ESP-Hosted SDIO connection. Copy an ESP32-C6 **application image** (`.bin`) to
the root of a FAT32-formatted USB drive, insert it into USB-A, and open the page. For builds
from this repository, that application is
`firmware/tab5-c6/build/network_adapter.bin`. Use
**Refresh USB**, select the file, then **Check image**. Modulus verifies the ESP
image header and ESP32-C6 chip ID before enabling **Flash C6**.

Flashing never starts automatically. Keep power and the USB drive connected while
the progress bar is active. After successful activation, the P4 automatically
restarts after three seconds so it can reconnect to the updated C6 firmware.

Use an ESP-Hosted slave application image compatible with the host component
version pinned in `firmware/tab5/dependencies.lock`. Do not use a full-flash,
merged, bootloader, or partition-table image.

Recovery: if the C6 update is interrupted and SDIO no longer starts, restore a
C6 full image through the C6 USB bootloader at `0x0` (see above). The P4 OTA page cannot repair a C6 that no longer boots far
enough to provide ESP-Hosted OTA.

### Pinout (Tab5)

| Signal | Pin | Note |
|--------|-----|------|
| RS-485 TX / RX / DE | GPIO 20 / 21 / 34 | onboard SIT3088 |
| ExtEncoder MPG | Grove Port A (I2C) | powered via `EXT5V_EN` |
| Hardware E-Stop | GPIO16 (M5-Bus pin 2) | NO to GND, pull-up |
| NanoH2 UART | GPIO 6 TX / 7 RX | 460800 baud |

---

## BOM (short)

Tab5 · ExtEncoder + wheel · industrial NO E-Stop · Stamp NanoH2 · ESP32-S3 cabinet bridge · NP-F pack(s) · optional COMMU Module Extend.

Mechanical files: [`cad/`](cad/) · Wiring / schematics: [`schematics/`](schematics/).
