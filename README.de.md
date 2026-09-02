<p align="center">
  <img src="assets/modulus-firmware-hero.png" alt="Modulus Firmware — Tab5 CNC pendant" width="720">
</p>

<p align="center">
  <a href="README.md">English</a> · <strong>Deutsch</strong>
</p>

# Modulus Firmware – OTA für Tab5

**Version:** 3.1.0  
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
übertragen, S3-App-Images per ESP-NOW. Als Quelle funktionieren ein
FAT-formatierter USB-A-Stick oder eine microSD-Karte.

Der Ablauf lautet **zuerst P4, danach C6 und/oder S3**. Der XIAO ESP32-S3
benötigt einmalig das OTA-fähige Vollimage per USB; alle späteren Updates nutzen
nur das App-Image. Beide Seiten prüfen den ESP-Chiptyp, verlangen eine bewusste
Freigabe und starten das Ziel erst auf Tastendruck neu. Ein C6-Image kann nicht
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

## Voraussetzungen

- ESP-IDF 6.0.1 und esptool
- USB-Verbindung zum Tab5-P4 (Beispiel: `COM5`)
- FAT-formatierter USB-Stick (empfohlen) oder FAT32-microSD-Karte
- Passende Builds für P4 sowie das jeweilige C6- oder S3-Ziel

Die COM-Portnummer kann auf deinem Rechner abweichen.

## Empfohlene Flash-Reihenfolge

### 1. ESP32-P4 zuerst flashen

Dieser Feature-Branch muss auf dem P4 laufen, bevor C6 oder S3 über das Tab5
aktualisiert werden können. Baue ihn mit:

```powershell
.\scripts\build_tab5.ps1
```

> [!IMPORTANT]
> Für den Tab5-P4 immer das Build-Skript verwenden. Ein direktes
> `idf.py build` wendet die nötigen ESP-IDF-6-/ESP-Hosted-Patches nicht an.

Flashe danach den vollständigen P4-Satz aus dem erzeugten Paket:

```powershell
cd path\to\tab5-p4
esptool.py --chip esp32p4 -p COM5 --before default-reset --after hard-reset write_flash `
  --flash-mode dio --flash-freq 40m --flash-size 16MB `
  0x2000 bootloader.bin `
  0x8000 partition-table.bin `
  0x10000 modulus_tab5.bin
```

Tab5 vollständig aus- und wieder einschalten. Warte auf das normale Dashboard
und prüfe, ob **M Panel → C6 Update** und **M Panel → S3 Update** vorhanden sind.

### 2. C6-Anwendungsdatei erzeugen

Baue die C6-Firmware mit:

```powershell
.\scripts\build_tab5_c6_modulus.ps1
```

Die für OTA benötigte Datei ist:

```text
firmware/tab5-c6/build/network_adapter.bin
```

Sie darf umbenannt werden, zum Beispiel in
`modulus-c6-ota-2.12.12.bin`. Entscheidend ist ihr Inhalt, nicht der Dateiname.

### 3. ESP32-C6 über das Tab5 aktualisieren

1. USB-Stick oder SD-Karte als FAT formatieren.
2. **Nur** `network_adapter.bin` beziehungsweise die umbenannte OTA-Datei in
   das Stammverzeichnis des Datenträgers kopieren.
3. USB-Stick (empfohlen) oder SD-Karte in das laufende Tab5 einsetzen.
4. **M Panel → C6 Update** öffnen.
5. **Refresh drives** drücken, `USB:`- oder `SD:`-Datei auswählen und **Check image** drücken.
6. Prüfen, dass ein ESP32-C6-Application-Image erkannt und akzeptiert wird.
7. **Flash C6** drücken und die Sicherheitsabfrage bestätigen.
8. Während des Fortschrittsbalkens weder Strom noch Quelldatenträger entfernen.
9. Nach erfolgreicher Aktivierung **Restart Modulus** drücken.
10. Prüfen, ob Dashboard und C6-/ESP-NOW-Verbindung wieder verfügbar sind.

> [!WARNING]
> Kein Full-/Merged-Image, Release-ZIP, `bootloader.bin`,
> `partition-table.bin` oder `ota_data_initial.bin` im OTA-Menü auswählen.
> Diese Dateien sind für feste Flash-Adressen bestimmt und keine gültigen
> OTA-Anwendungsimages.

## C6-Wiederherstellung per USB

Dieser Weg ist nur nötig, wenn der C6 nicht mehr weit genug startet, um
ESP-Hosted/SDIO-OTA anzubieten. Verbinde den C6-Bootloader per USB und flashe
den vollständigen Satz an seine festen Adressen:

```powershell
cd path\to\tab5-c6
esptool.py --chip esp32c6 -p COM6 --before default-reset --after hard-reset write_flash `
  --flash-mode dio --flash-freq 80m --flash-size 4MB `
  0x0 bootloader.bin `
  0x8000 partition-table.bin `
  0xd000 ota_data_initial.bin `
  0x10000 network_adapter.bin
```

Falls kein Port erscheint, beim Anschließen des C6-USB die **BOOT**-Taste
gedrückt halten. Danach das Tab5 vollständig neu starten.

## Weitere Firmwareziele

- **S3-Bridge:** verbindet ESP-NOW mit der UART der CNC-Steuerung.
- **NanoH2:** optionaler Zigbee-Hub; Zigbee-Only-Firmware niemals auf den C6
  des Tab5 flashen.

### S3-OTA auf einem XIAO ESP32-S3 aktivieren und testen

Für OTA braucht der S3 einmalig die neue Dual-Slot-Partitionstabelle und den
OTA-Empfänger. Das vollständige Image wird einmal per USB bei Offset `0x0`
installiert:

```powershell
python -m esptool --chip esp32s3 -p COM8 erase-flash
python -m esptool --chip esp32s3 -p COM8 write-flash 0x0 modulus-xiao-s3-bridge-first-flash-for-ota.bin
```

Falls durch das Löschen die Einstellungen verloren gingen, anschließend die
S3-MAC-Adresse und den ESP-NOW-Kanal unter **Settings → Wireless** erneut
eintragen. Danach nur `modulus-xiao-s3-bridge-ota-app.bin` in das Stammverzeichnis
eines FAT-formatierten USB-Sticks (empfohlen) oder der SD-Karte kopieren und
**M Panel → S3 Update** öffnen. Datei auswählen,
**Check S3 image**, **Flash S3** und nach erfolgreicher Prüfung **Restart S3**
drücken. Für den ersten Test darf dasselbe App-Image noch einmal per OTA
installiert werden.

Währenddessen muss die CNC im Leerlauf bleiben; Stromversorgung und das
Quelllaufwerk nicht entfernen. Die S3-Seite akzeptiert ausschließlich ESP32-S3-App-Images,
die C6-Seite ausschließlich ESP32-C6-App-Images. Vollständige/zusammengeführte
Images werden von beiden OTA-Seiten absichtlich abgewiesen und gehören nur per
USB an Offset `0x0`.

Sowohl **C6 Update** als auch **S3 Update** durchsuchen den USB-A-Massenspeicher
und die microSD-Karte. Treffer werden mit `USB:` beziehungsweise `SD:`
gekennzeichnet. Wenn das Gehäuse den SD-Slot verdeckt, ist USB-A der empfohlene
Wartungsweg: FAT-formatierten Stick einstecken, kurz auf den Mount warten und
**Refresh drives** drücken.

Falls das serielle Befehlsmenü beim Start nicht sichtbar war, eine leere
Eingabe mit Enter senden. Das Menü mit `uartping`, Konfiguration und Diagnose
wird dann erneut ausgegeben.

Die vollständige Architektur-, Build- und Entwicklerdokumentation befindet
sich in der [englischen README](README.md).

## Sicherheit

Der Pendant-E-Stop an GPIO16 ist nur eine zusätzliche Softwarefunktion. Er ist
kein sicherheitsgerichteter Abschaltkreis und kann bei ausgefallener
Funkverbindung die Maschine nicht stoppen. Der echte Maschinen-Not-Aus bleibt
immer die primäre Sicherheitseinrichtung.
