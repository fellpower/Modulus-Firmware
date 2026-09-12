<p align="center">
  <img src="assets/modulus-firmware-hero.png" alt="Modulus Firmware — Tab5 CNC pendant" width="720">
</p>

<p align="center">
  <a href="README.md">English</a> · <strong>Deutsch</strong>
</p>

# Modulus Firmware – OTA für Tab5

**Version:** 3.1.3-ota<br>
**Autor:** D. McLean / BufferRoot  
**Feature-Branch:** `feature/tab5-ota`
**Plattform:** M5Stack Tab5 (ESP32-P4 + ESP32-C6)  
**Lizenz:** [MIT](LICENSE)

Modulus ist eine CNC-Pendant-Firmware für das M5Stack Tab5. Der ESP32-P4 führt
Oberfläche und Steuerungslogik aus; der ESP32-C6 stellt WLAN, BLE und ESP-NOW
über ESP-Hosted/SDIO bereit. Das Pendant ersetzt nicht die Maschinensteuerung
und nicht den hardwareseitigen Not-Aus.

## Warum es diesen OTA-Feature-Branch gibt

Modulus verteilt seine Aufgaben auf mehrere Prozessoren. Für Updates des
ESP32-C6 im Tab5 und der ESP32-S3-Bridge war bisher jeweils ein separater
USB-/Bootloader-Zugang nötig. Dieser Branch ergänzt **C6 Update** und
**S3 Update** im M Panel. C6-App-Images werden intern über ESP-Hosted/SDIO
übertragen, S3-App-Images per ESP-NOW. Beide Updater lesen ausschließlich das
Stammverzeichnis eines FAT-formatierten USB-A-Sticks. Die microSD-Unterstützung
war beim Entwickeln und Testen hilfreich, wurde aber aus den Updatemenüs
entfernt: In vielen eingebauten Gehäusen ist der Kartenslot nicht erreichbar,
und zwei mögliche Updatequellen machten den Ablauf unnötig uneindeutig. Andere
microSD-Funktionen von Modulus bleiben unverändert.

Der Ablauf lautet **zuerst P4, danach C6 und/oder S3**. Der XIAO ESP32-S3
benötigt einmalig das OTA-fähige Vollimage per USB; alle späteren Updates nutzen
nur das App-Image. Beide Seiten prüfen den ESP-Chiptyp und verlangen eine bewusste
Freigabe. Nach erfolgreicher C6-Aktivierung startet der P4 nach drei Sekunden
automatisch neu, um ESP-Hosted/SDIO wieder zu synchronisieren. Ein C6-Image kann nicht
versehentlich über die S3-Seite geflasht werden und umgekehrt. Beide OTA-Wege
wurden auf echter Hardware erfolgreich getestet.

> [!IMPORTANT]
> **OTA muss zuerst durch einen einmaligen kabelgebundenen Flash vorbereitet
> werden.** Zuerst das P4-Paket per USB flashen, damit das Tab5 die OTA-Menüs
> erhält. Ein neuer oder bereits anders geflashter XIAO ESP32-S3 muss danach
> einmal per USB bei Offset `0x0` mit
> `modulus-xiao-s3-first-flash-for-ota-*.bin` geflasht werden. Dadurch werden
> OTA-Empfänger und Dual-Slot-Partitionstabelle installiert. Erst anschließend
> funktionieren spätere S3-Updates mit `modulus-xiao-s3-ota-app-*.bin` über
> **M Panel → S3 Update**. Das First-Flash-/Vollimage niemals im OTA-Menü wählen.

Beim Tab5-C6 stellt die originale ESP-Hosted-Firmware Slave-OTA bereits bereit.
Trotzdem muss zuerst die OTA-fähige P4-Firmware installiert sein, damit
**C6 Update** verfügbar ist. Startet der C6 nicht mehr oder antwortet nicht über
SDIO, muss zunächst das vollständige C6-Paket über dessen USB-Bootloader
wiederhergestellt werden.

## Architektur in Kurzform

| Ziel | Aufgabe |
|------|---------|
| **ESP32-P4** | Tab5-Oberfläche, MPG und Steuerung; enthält C6- und S3-Updater |
| **ESP32-C6** | WLAN, BLE und ESP-NOW über ESP-Hosted/SDIO |
| **ESP32-S3** | ESP-NOW-Bridge im Schaltschrank zur CNC-UART |
| **NanoH2** | Optionaler Zigbee-Koordinator |

## Fertige Full-Images für v3.1.3-ota

Die drei BINs direkt aus [Release v3.1.3-ota](https://github.com/fellpower/Modulus-Firmware/releases/tag/v3.1.3-ota)
herunterladen. Ein lokaler Neubau oder Entpacken ist zum Flashen nicht nötig.

| Ziel | Einzelne BIN | Flash-Adresse |
|------|--------------|---------------|
| Tab5 P4 | `modulus-tab5-p4-full-v3.1.3-ota.bin` | `0x0` |
| Tab5 C6 | `modulus-tab5-c6-full-v3.1.3-ota.bin` | `0x0` |
| XIAO ESP32-S3 | `modulus-xiao-s3-full-v3.1.3-ota.bin` | `0x0` |

Die Images enthalten Bootloader, Partitionstabelle, gegebenenfalls OTA-Startdaten
und Anwendung aus den vorhandenen Release-Einzeldateien. Der P4-Bootloader liegt
innerhalb der BIN weiterhin bei `0x2000`, die XIAO-S3-App bei `0x20000`.
**Die vollständige BIN wird trotzdem immer bei `0x0` geschrieben.**
Lücken sind mit `0xFF` gefüllt. Das Schreiben kann Einstellungen/NVS und die
OTA-Auswahl im beschriebenen Adressbereich zurücksetzen. Für spätere C6-/S3-Updates
sind deshalb die App-only-Dateien vorgesehen.

## Flashen per USB

- Python und esptool installieren: `python -m pip install esptool==5.3.1`.
- USB-Datenkabel verwenden, Terminal im Downloadordner öffnen.
- COM-Port im Geräte-Manager prüfen; `COM5`, `COM6` und `COM8` sind Beispiele.
- Den USB-Bootloader des richtigen Chips verbinden. Der P4-USB-Anschluss flasht
  den C6 nicht direkt. Bei Bedarf den jeweiligen BOOT-/Downloadmodus aktivieren.
- Reihenfolge: P4 zuerst; C6 bei kabelgebundener Installation/Wiederherstellung;
  danach XIAO S3 einmalig für OTA vorbereiten.
- Nur den Befehl für das gerade angeschlossene Ziel ausführen:

```powershell
python -m esptool --chip esp32p4 -p COM5 write-flash --flash-mode dio --flash-freq 40m --flash-size 16MB 0x0 modulus-tab5-p4-full-v3.1.3-ota.bin
python -m esptool --chip esp32c6 -p COM6 write-flash --flash-mode dio --flash-freq 80m --flash-size 4MB 0x0 modulus-tab5-c6-full-v3.1.3-ota.bin
python -m esptool --chip esp32s3 -p COM8 write-flash --flash-mode dio --flash-freq 80m --flash-size 8MB 0x0 modulus-xiao-s3-full-v3.1.3-ota.bin
```

Im grafischen Flashtool ebenfalls genau eine BIN bei `0x0` auswählen und
Chip/Flash-Einstellungen passend setzen. Verifikation abwarten, dann neu starten.
Ein zusätzliches `erase-flash` gehört nicht zu diesem Ablauf.
Das bisherige `modulus-xiao-s3-first-flash-for-ota-v3.1.3-ota.bin` ist mit dem
neuen XIAO-Full-Image inhaltsgleich. Nicht mit dem generischen S3-Bridge-Paket verwechseln.

## C6-Kompatibilität in nachfolgenden Quellcode-Builds

Der Branch fragt die **laufende C6-Version unmittelbar vor dem Schreiben** ab.
Unter 2.6.0 (auch 1.4.1) aktiviert `OTAEnd` das Image und plant den C6-Neustart;
ein zusätzliches `OTAActivate` entfällt. Der P4 wartet acht Sekunden bis zu seinem
Neustart. Ab 2.6.0 wird explizit aktiviert, danach startet der P4 wie bisher nach
drei Sekunden neu. Bei unbekannter oder nicht lesbarer Version wird nichts geschrieben.
Eine funktionierende ESP-Hosted-Verbindung und geeignete C6-OTA-Partition bleiben
nötig. Eine verlorene Abschluss-/Aktivierungsantwort wird als unbestätigter Zustand
gemeldet, nicht als sicher ausgebliebene Aktivierung.

**Diese Änderung gilt bisher nur für den Quellcode. Die Release-BINs v3.1.3-ota
wurden nicht neu gebaut und behalten den bisherigen Ablauf.**
Regressionstest: `python scripts/test_c6_ota.py` (benötigt Zig).
Der Hardwaretest mit Factory-Firmware 1.4.1 steht noch aus.

## Spätere Updates über USB-Stick und OTA

- P4 normal starten und **M Panel → C6 Update / S3 Update** prüfen.
- Passende Release-Datei herunterladen:
  `modulus-tab5-c6-ota-app-v3.1.3-ota.bin` oder
  `modulus-xiao-s3-ota-app-v3.1.3-ota.bin`.
- Nur die App-BIN ins Stammverzeichnis eines FAT32-Sticks kopieren.
- Stick in USB-A des Tab5 stecken; microSD wird im OTA-Menü nicht angeboten.
- Passende Update-Seite öffnen, **Refresh USB**, Datei auswählen.
- **Check image** beim C6 beziehungsweise **Check S3 image** beim S3 drücken.
- **Flash C6** beziehungsweise **Flash S3** bestätigen. CNC im Leerlauf lassen;
  Stromversorgung und Stick während des Updates nicht entfernen.
- Nach C6-Aktivierung startet der P4 nach drei Sekunden automatisch neu.
- Nach erfolgreicher S3-Prüfung **Restart S3** drücken.
- Dashboard und ESP-NOW-Verbindung prüfen. Falls Einstellungen zurückgesetzt
  wurden, S3-MAC und passenden Funkkanal unter **Settings → Wireless** neu setzen.

**Full-Images gehören ausschließlich zum kabelgebundenen Flash bei `0x0`, niemals
ins OTA-Menü.** Der XIAO braucht die vollständige USB-Erstinstallation einmalig.
Startet der C6 nicht mehr oder antwortet nicht über SDIO, das C6-Full-Image über
seinen USB-Bootloader wiederherstellen.

## Full-Images ohne Neubau reproduzieren

Aus dem Release `MANIFEST.json` sowie die ZIPs für `tab5-p4`, `tab5-c6` und
`s3-xiao` herunterladen. Manifest in `dist/flash-images/v3.1.3-ota-source/` ablegen
und die ZIPs darunter mit ihren Zielordnern und `flasher_args.json` entpacken.

```powershell
.\scripts\package_flash_images.ps1 -Version 3.1.3-ota
```

Das Skript prüft Größe und SHA256 jeder Eingabedatei gegen das Release-Manifest
und übernimmt die Flash-Adressen aus `flasher_args.json`. Es führt ausschließlich
vorhandene BINs zusammen. Ausgabe: drei Full-BINs, `SHA256SUMS-full.txt` und
`FLASH-full.md` unter `dist/flash-images/v3.1.3-ota-full/`.
Mit `-SourceRoot` und `-OutRoot` lassen sich andere Ordner angeben; bereits
vorhandene Ausgabe-BINs werden nicht überschrieben. Die Images reichen bis zum
Ende der enthaltenen Anwendung, nicht bis zum Ende des gesamten Flash-Speichers.
[Prüfsummen der drei Full-Images](FULL-IMAGES-v3.1.3-ota.sha256).

[Deutsche stichpunktartige Videoanleitung](VIDEOANLEITUNG.de.md).
Weitere Architektur- und Build-Informationen stehen in der [englischen README](README.md).
NanoH2 und generische S3-Bridge bleiben separate Release-Pakete mit eigener `FLASH.md`.

## Sicherheit

Der Pendant-E-Stop an GPIO16 ist nur eine zusätzliche Softwarefunktion. Er ist
kein sicherheitsgerichteter Abschaltkreis und kann bei ausgefallener
Funkverbindung die Maschine nicht stoppen. Der echte Maschinen-Not-Aus bleibt
immer die primäre Sicherheitseinrichtung.
