# C6-Legacy-OTA mit Factory-Version 1.4.1 testen

Dieser Test benötigt eine **neu gebaute P4-Firmware ab Commit 69ca844** auf
`feature/tab5-ota`. Die vorhandenen Release-BINs v3.1.3-ota enthalten den Fix
nicht, auch nach Ergänzung der Full-Images im ZIP. Die nachfolgenden Schritte
beschreiben den Hardwaretest; er wurde noch nicht durchgeführt.

## Vorbereitung

- CNC stillsetzen. Verbindungsdaten notieren und einen Wiederherstellungsweg bereithalten.
- P4 aus dem aktuellen Branch mit `scripts/build_tab5.ps1` bauen und per
  `scripts/flash_tab5.ps1 -Port COM_P4` installieren. Platzhalter ersetzen.
- Den Build erst ausführen, wenn die vorhandenen lokalen Änderungen geprüft sind;
  Release-Dateien und Test-Build getrennt halten. Keine Release-BIN als Fix-Build ausgeben.
- Die Modulus-C6-App `modulus-tab5-c6-ota-app-v3.1.3-ota.bin` und das
  Wiederherstellungsimage `modulus-tab5-c6-full-v3.1.3-ota.bin` aus dem Release laden.
- Für einen reproduzierbaren Factory-Ausgangszustand das originale M5Stack-Full-Image
  direkt auf den C6 schreiben. Ein Downgrade nur der App stellt die ursprüngliche
  Partitionstabelle und OTA-Auswahl nicht zuverlässig wieder her.

## Originaldatei und Anschluss

- [Originales M5Stack-Image 1.4.1 herunterladen](https://raw.githubusercontent.com/m5stack/M5Tab5-UserDemo/main/platforms/tab5/wifi_c6_fw/ESP32C6-WiFi-SDIO-Interface-V1.4.1-96bea3a_0x0.bin).
- SHA256 der geprüften Datei:
  `1173bf86ab86c8dbd3f9863d10b15c2e46f57000b2b77c803e2b79bd0a3fa38e`.
- Der C6 wird über den **internen Programmieranschluss mit USB-TTL-Downloader**
  geflasht. M5Stack zeigt den passenden ESP32 Downloader und den Anschluss hier:
  [Offizielle C6-Wiederherstellungsanleitung](https://docs.m5stack.com/en/guide/restore_factory/m5tab5_c6_wifi).
- Die normale Tab5-USB-C-Buchse ist der P4-Zugang. Der dortige Downloadmodus
  versetzt nicht einfach den C6 in den Programmiermodus.
- Den COM-Port des Downloaders verwenden, unten beispielhaft `COM6`.
- Optional zuerst den aktuellen 4-MB-C6-Flash sichern; das Backup kann Einstellungen
  enthalten und bleibt lokal:

```powershell
python -m esptool --chip esp32c6 -p COM6 read-flash 0x0 0x400000 c6-before-legacy-test.bin
```

## 1. C6 auf Factory 1.4.1 setzen

Im Ordner mit der Originaldatei, bei verbundenem C6-Downloader:

```powershell
python -m esptool --chip esp32c6 -p COM6 write-flash 0x0 ESP32C6-WiFi-SDIO-Interface-V1.4.1-96bea3a_0x0.bin
```

Verifikation abwarten, anschließend Tab5 vollständig neu starten. Das Full-Image
überschreibt unter anderem NVS und OTA-Startdaten im abgedeckten Bereich.
Es enthält die ursprüngliche OTA-Partitionierung. Kein zusätzliches `erase-flash`
ist für diesen Ablauf vorgesehen.

## 2. Alten Updateweg testen

- Auf der **neuen Test-P4-Firmware** M Panel → C6 Update öffnen und Refresh drücken.
- Die laufende Version muss **1.4.1** anzeigen. Der App-Descriptor der Originaldatei
  enthält den Git-Stand `96bea3a`; das ist nicht die maßgebliche Laufzeit-Versionsabfrage.
- Falls der C6 nicht antwortet: keine weiteren Flash-Versuche im Menü starten;
  P4-Startlog sichern. Dann liegt bereits ein Verbindungs-/Versionsabfrageproblem vor,
  das durch die Aktivierungsumschaltung allein nicht behoben ist.
- `modulus-tab5-c6-ota-app-v3.1.3-ota.bin` ins Stammverzeichnis eines FAT32-Sticks
  kopieren, an Tab5 USB-A anschließen, Refresh USB → Datei → Check image → Flash C6.
- Erwarteter Logeintrag: `Running C6 1.4.1: legacy auto-restart OTA completion`.
- Der C6 wird über OTAEnd aktiviert; ein zusätzlicher OTAActivate-Aufruf entfällt.
  P4-Neustart nach acht Sekunden abwarten und Versorgung angeschlossen lassen.
- Danach erneut die C6-Version abfragen: erwartet wird **2.11.4**, die Version
  des ESP-Hosted-Anteils im Modulus-C6-Release. ESP-NOW-Verbindung prüfen.

## 3. Neuen Updateweg gegenprüfen

- Dieselbe Modulus-C6-App noch einmal über das Menü installieren.
- Erwarteter Logeintrag: `Running C6 2.11.4: explicit activation OTA completion`.
- Diesmal folgt auf OTAEnd die explizite Aktivierung; P4-Neustart nach drei Sekunden.
- Erneut Version 2.11.4, Dashboard und Funkverbindung prüfen.

## Wiederherstellung bei Problemen

Mit dem internen C6-Downloader die Modulus-Full-BIN schreiben:

```powershell
python -m esptool --chip esp32c6 -p COM6 write-flash --flash-mode dio --flash-freq 80m --flash-size 4MB 0x0 modulus-tab5-c6-full-v3.1.3-ota.bin
```

Danach Tab5 neu starten. Full-BINs niemals im OTA-Menü auswählen.
Für die Auswertung das P4-Startlog, erkannte Version, gewählten Modus,
Fehlerphase und Version nach dem Neustart festhalten.
