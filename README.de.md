<p align="center">
  <img src="assets/modulus-firmware-hero.png" alt="Modulus Firmware – Tab5 CNC-Pendant" width="720">
</p>

<p align="center">
  <a href="https://www.youtube.com/watch?v=mvP2etHl_e0">
    <img src="https://img.youtube.com/vi/mvP2etHl_e0/maxresdefault.jpg" alt="Modulus-Projektvideo auf YouTube ansehen" width="720">
  </a>
</p>

<p align="center"><strong><a href="https://www.youtube.com/watch?v=mvP2etHl_e0">Modulus-Projektvideo ansehen</a></strong></p>

[English](README.md) · **Deutsch**

# Modulus Firmware

**Release:** v3.1.5-ota · **Branch:** `feature/tab5-ota` · **Lizenz:** [MIT](LICENSE)

**Danksagung:** Besonderer Dank an **Sae** und **Miklos** für die wiederholten
Tests der Tab5 ↔ S3-Funkverbindung und die Diagnose-Logs, die zur festen
Kanalsteuerung geführt haben.

Modulus macht das M5Stack Tab5 zum CNC-Pendant. Der P4 übernimmt Oberfläche und
Steuerungslogik, der C6 WLAN und ESP-NOW. Eine S3-Bridge verbindet das Pendant mit
der CNC-Steuerung. NanoH2 ist der optionale Zigbee-Hub.

## Verbindungs- und Pinübersicht

Die Grafik zeigt die kabelgebundenen Busse, Funkstrecken, Versorgung und die
aktuell verwendeten GPIOs von Tab5, NanoH2, S3-Bridge und externem Zigbee-Node.
Die dargestellte Relaisanbindung über den ULN2803A ist geplant und noch nicht
an der Hardware getestet.

![Modulus Verbindungs- und Pinübersicht](assets/modulus-connection-pin-overview.png)

## Erstinstallation

Die aktuellen Dateien stehen immer im [neuesten GitHub-Release](https://github.com/fellpower/Modulus-Firmware/releases/latest).
Der Reiter **Releases** enthält die Installationsdateien, Anleitung und Prüfsummen.

- Das **Full-Image** enthält alles für eine saubere Installation, löscht alte
  Einstellungen und wird bei Adresse `0x0` geschrieben.
- Für den Tab5 wird `modulus-tab5-full.bin` verwendet.
- Für den S3 wird passend zum Board `modulus-s3-generic-full.bin` oder
  `modulus-s3-xiao-full.bin` verwendet.
- Die S3-**OTA-Images** sind für spätere Aktualisierungen über das S3-Menü gedacht.

Das Ziel über seinen normalen USB-Anschluss verbinden und die passende einzelne
Full-BIN an Adresse `0x0` schreiben. Beispiel für den XIAO (`COM8` durch seinen
tatsächlichen Port ersetzen):

```powershell
python -m esptool --chip esp32s3 -p COM8 erase-flash
python -m esptool --chip esp32s3 -p COM8 write-flash 0x0 modulus-s3-xiao-full.bin
```

Für einen generischen S3 das Generic-Full-Image verwenden. Die vollständigen
Tab5- und S3-Befehle stehen in `FLASH-README.md` im Release.

## Spätere S3-Updates

Das passende `modulus-s3-*-ota.bin` aus dem neuesten Release ins Hauptverzeichnis des Sticks kopieren.
**M Panel → S3 → Firmware Update → Refresh USB → Check S3 image → Flash S3**.
Nach erfolgreicher Prüfung **Restart S3** drücken. Bei Bedarf S3-MAC und
passenden Funkkanal unter Settings → Wireless eintragen.

## S3-RGB-Status-LED

| LED-Anzeige | Bedeutung |
|-------------|-----------|
| Grün dauerhaft | Die ESP-NOW-Verbindung zum Tab5 steht |
| Kurz Cyan/Blaugrün | UART-Daten wurden zur CNC-Steuerung gesendet oder von ihr empfangen; die Anzeige bleibt etwa 140 ms aktiv |
| Orange | ESP-NOW-Sendefehler |
| Violett blinkend | Suche nach dem eingestellten Funkkanal |
| Blau blinkend | Keine Verbindung; die normale Verbindungssuche läuft |
| Dunkles Amber | Der S3 startet noch |

Die S3-Bridge wertet den Maschinenzustand der CNC **nicht** aus. Insbesondere
bedeutet eine cyan- beziehungsweise blaugrüne Anzeige während eines Alarms nur,
dass UART-Daten übertragen werden. Sie ist keine Alarmanzeige des S3. Sobald die
Verbindung steht und kein UART-Verkehr stattfindet, leuchtet die LED wieder
dauerhaft grün.

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
