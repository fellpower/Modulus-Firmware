# Zigbee node recovery

During development, an unchanged Zigbee node was observed to lose stable normal
application communication after a Tab5 UI/firmware change. The yellow status LED
became intermittent and the node was no longer consistently available. A causal
connection to the UI change was not established.

The following recovery restored normal operation in that case. It removes the
node's persisted Zigbee network state, installs a known complete node image, and
then joins the node to the current coordinator network again.

1. Connect the Zigbee node directly by USB and determine its serial port.
2. Erase the node flash:

   ```powershell
   python -m esptool --chip esp32c6 --port <NODE_COM_PORT> erase-flash
   ```

3. Flash a known `modulus-zigbee-node-full.bin` at address `0x0`:

   ```powershell
   python -m esptool --chip esp32c6 --port <NODE_COM_PORT> --baud 460800 write-flash 0x0 modulus-zigbee-node-full.bin
   ```

4. Pair the node with the current NanoH2 network again.

The node persists Zigbee network state in flash. A complete erase removes old or
stale state and restored operation in this observed case; this does not prove
that persisted state caused the original failure.

> **Do not full-flash the NanoH2 for this node recovery.** A NanoH2 full image can
> erase the coordinator network and its pairings. Use the NanoH2 OTA/app update
> for routine updates when the network must be preserved.

## Wiederherstellung eines Zigbee-Nodes

Während der Entwicklung wurde beobachtet, dass ein unveränderter Zigbee-Node
nach einer Änderung an Tab5-Oberfläche/Firmware die normale
Applikationskommunikation nicht mehr stabil hielt. Die gelbe Status-LED leuchtete
nur noch zeitweise und der Node war nicht mehr zuverlässig verfügbar. Ein
ursächlicher Zusammenhang mit der UI-Änderung wurde nicht nachgewiesen.

In diesem Fall stellte das vollständige Löschen des Nodes, das Flashen eines
bekannten Full-Images bei Adresse `0x0` und das anschließende erneute Pairing mit
dem aktuellen NanoH2-Netz den stabilen Betrieb wieder her. Die Befehle stehen
oben; `<NODE_COM_PORT>` ist durch den tatsächlichen Port zu ersetzen.

Der Node speichert seinen Zigbee-Netzwerkzustand im Flash. Das vollständige
Löschen entfernt alten oder inkonsistenten Zustand und war hier erfolgreich. Es
beweist jedoch nicht, dass dieser Zustand die ursprüngliche Störung verursacht
hat.

> **Für diese Node-Wiederherstellung den NanoH2 nicht vollständig flashen.** Ein
> NanoH2-Full-Image kann Coordinator-Netzwerk und Pairings löschen. Normale
> NanoH2-Aktualisierungen als OTA-/App-Update durchführen, wenn das Netzwerk
> erhalten bleiben soll.
