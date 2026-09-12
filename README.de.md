<p align="center">
  <img src="assets/modulus-firmware-hero.png" alt="Modulus Firmware – Tab5 CNC-Pendant" width="720">
</p>

[English](README.md) · **Deutsch**

# Modulus Firmware

**Release:** v3.1.3-ota · **Branch:** `feature/tab5-ota` · **Lizenz:** [MIT](LICENSE)

Modulus macht das M5Stack Tab5 zum CNC-Pendant. Der P4 übernimmt Oberfläche und
Steuerungslogik, der C6 WLAN und ESP-NOW. Eine S3-Bridge verbindet das Pendant mit
der CNC-Steuerung. NanoH2 ist der optionale Zigbee-Hub.

## Erstinstallation

Die fertigen Dateien stehen im [Release v3.1.3-ota](https://github.com/fellpower/Modulus-Firmware-C6-OTA/releases/tag/v3.1.3-ota).

- Das **Full-Image** enthält alles für die einmalige Erstinstallation und wird
  bei Adresse `0x0` geschrieben. Full-Images gibt es für P4 und XIAO S3.
- Das **App-Image** ist für spätere Aktualisierungen über die OTA-Menüs gedacht.
- Für den **C6 gibt es genau eine Release-Datei**:
  `modulus-tab5-c6-app-v3.1.3-ota.bin`. Sie wird immer über das C6-Menü des
  Tab5 installiert, auch beim Wechsel von der Factory-Version 1.4.1.
- Den C6 anschließend direkt über das Tab5 aktualisieren, wie unten beschrieben.

Das aktuelle P4-Full-Image enthält den getesteten Kompatibilitätsweg für einen
C6 mit der Factory-Version ESP-Hosted 1.4.1. Der Wechsel von 1.4.1 zur
Modulus-C6-Firmware wurde auf dem Tab5 erfolgreich getestet.

Das Ziel über seinen normalen USB-Anschluss verbinden und die passende einzelne
Full-BIN an Adresse `0x0` schreiben. Beispiel für den XIAO (`COM8` durch seinen
tatsächlichen Port ersetzen):

```powershell
python -m esptool --chip esp32s3 -p COM8 write-flash 0x0 modulus-xiao-s3-full-v3.1.3-ota.bin
```

NanoH2 und generische S3-Bridge haben eigene Pakete mit `FLASH.md`.

## C6 über das Tab5 aktualisieren

Für diesen Weg brauchst du einen FAT32-USB-Stick. Der C6 wird vollständig aus
Modulus aktualisiert; dieses Release beschreibt keinen separaten C6-Flashweg.

1. Tab5 mit aktuellem P4-Build starten.
2. `modulus-tab5-c6-app-v3.1.3-ota.bin` ins **Hauptverzeichnis** des FAT32-Sticks kopieren.
   Im Gesamt-ZIP liegt diese Datei im Ordner `ota/`.
3. Stick in Tab5 USB-A stecken.
4. **M Panel → C6 → Firmware Update** öffnen.
5. **Refresh USB** drücken, Datei auswählen, **Check image** drücken.
6. **Flash C6** drücken und bestätigen.
7. Stromversorgung und Stick angeschlossen lassen, bis das Update und der automatische P4-Neustart beendet sind.
8. C6-Version und ESP-NOW-Verbindung kontrollieren.

Die P4-Firmware fragt die **laufende C6-Version** ab und wählt automatisch den
passenden Ablauf. Bei alten Versionen wie 1.4.1 werden kleinere Blöcke verwendet;
der P4 startet nach acht Sekunden neu. Ab ESP-Hosted 2.6.0 wird explizit aktiviert,
danach startet der P4 nach drei Sekunden. Eine manuelle Moduswahl ist nicht nötig.

Das gilt bei funktionierender ESP-Hosted-Verbindung und geeigneter OTA-Partition.
Eine pauschale Garantie für jede fremde oder zukünftige C6-Firmware gibt es nicht.
Bei nicht lesbarer Version beginnt kein Schreibvorgang.

**Nur die C6-App-BIN gehört ins OTA-Menü.** Keine Full-BIN und kein ZIP
auswählen. microSD ist keine OTA-Quelle.

## Warum zwei Versionsnummern angezeigt werden

| Anzeige | Bedeutung |
|---------|-----------|
| **Modulus release: v3.1.3-ota** | Installiertes Modulus-Release |
| **ESP-Hosted (C6): 2.11.4** | Vom Funkprozessor gemeldete ESP-Hosted-Version |

Die Datei `modulus-tab5-c6-app-v3.1.3-ota.bin` gehört zum Modulus-Release
v3.1.3-ota und meldet trotzdem korrekt ESP-Hosted **2.11.4**.
Der C6 meldet seine ESP-Hosted-Komponentenversion separat. Gleiche
ESP-Hosted-Versionen beweisen nicht, dass zwei Firmwaredateien denselben Build enthalten.

## Spätere S3-Updates

`modulus-xiao-s3-app-v3.1.3-ota.bin` ins Hauptverzeichnis des Sticks kopieren.
**M Panel → S3 → Firmware Update → Refresh USB → Check S3 image → Flash S3**.
Nach erfolgreicher Prüfung **Restart S3** drücken. Bei Bedarf S3-MAC und
passenden Funkkanal unter Settings → Wireless eintragen.

## Aus dem Quellcode bauen

ESP-IDF 6.0.1 und Zig 0.16 verwenden. P4 über `scripts/build_tab5.ps1` bauen;
das Skript wendet die nötigen ESP-IDF-/ESP-Hosted-Patches an. Kein direktes
`idf.py build` für den ersten P4-Build verwenden.

C6: `scripts/build_tab5_c6_modulus.ps1`, anschließend `network_adapter.bin` über
das Tab5-Menü installieren. Regressionstest: `python scripts/test_c6_ota.py`.
Weitere Architektur- und Entwicklerdetails stehen in der [englischen README](README.md).

## Sicherheit

Updates nur bei stillstehender Maschine durchführen. Der echte Maschinen-Not-Aus
bleibt die primäre Sicherheitseinrichtung; der Pendant-Not-Aus ersetzt ihn nicht.
