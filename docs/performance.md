# Leistung (Lasttest)

Messung ohne Netzwerk mit `./mx run scripts/load_test.exs` (optional mit Spielerzahlen als Argumenten).
Je Lauf 200 Takte à 50 ms mit Bots (fahren, drehen, feuern) und dem Director (Händler, Jäger).
**Takt** = Rechenzeit des Welt-Prozesses (Eingaben, Simulation, Schnappschüsse bauen); Budget 50 ms.
Die JSON-Kodierung läuft in Produktion in den Socket-Prozessen (parallel) und zählt nicht zum Takt.

Auf dem Server gemessen (ein Kern für die Welt):

| Spieler | verteilt (Takt Ø / p95) | dicht beieinander (Takt Ø / p95) | Schnappschuss je Spieler |
|---:|---|---|---|
| 5 | 2,0 / 3,1 ms | 1,1 / 1,6 ms | 0,9 / 2,0 kB |
| 10 | 3,8 / 6,7 ms | 2,1 / 3,9 ms | 0,9 / 3,0 kB |
| 20 | 6,8 / 11,2 ms | 4,3 / 7,2 ms | 0,7 / 5,4 kB |
| 40 | 12,9 / 20,6 ms | 9,7 / 16,2 ms | 0,6 / 9,8 kB |
| 60 (Obergrenze) | 21,9 / 34,7 ms | 17,4 / 27,6 ms | 0,6 / 14,1 kB |

**Fazit:** Bis 40 Spieler bleibt der Takt unter 25 ms (komfortabel), bei 60 (der eingestellten Obergrenze)
im Spitzenfall (p95) bei ca. 35 ms – noch unter dem Budget, aber ohne große Reserve. Für Freundesrunden
(< 20 Spieler) ist die Welt sehr entspannt.

## Gefundener und behobener Engpass

Vorher kostete der Bau der Schnappschüsse bei dicht beieinander fahrenden Spielern quadratisch viel
(jeder Spieler baute Einträge für alle Schiffe neu): 60 Spieler im Pulk = **125 ms** pro Takt, also
Zeitlupe. Jetzt werden Schiffe, Kugeln, Beute und Ereignisse **einmal je Takt** vorbereitet
(`State.snapshot_context/2`) und je Spieler nur noch nach Entfernung gefiltert: **17 ms**. Dazu rundet
der Code ohne `Float.round`, das war auffallend langsam.

## Was noch kostet und was man tun könnte

- **Simulation (~75 % des Takts bei vielen Spielern):** v. a. die Küstenkollision (je Schiff und Schritt bis
  zu 9 Geländeabfragen, jede mit fünf Rauschstufen). Hebel: Höhenwerte je Chunk zwischenspeichern oder Schiffe
  fernab von Land überspringen. Erst nötig bei dauerhaft > 40 Spielern.
- **Treffer:** jede Kugel prüft jedes Schiff (O(Kugeln × Schiffe)). Hebel: Gitter (Spatial Hash).
- **Bandbreite:** ein Pulk von 20 Spielern sendet ca. 2 MB/s (20 Hz × 20 Spieler × 5,4 kB) – das ist bei einem
  normalen Heimanschluss die eigentliche Grenze, nicht die CPU. Hebel: kürzere Feldnamen, Namen/Klasse nur
  beim Erscheinen senden, niedrigere Rate für entfernte Schiffe. WebSocket-Kompression (permessage-deflate)
  ist bei Bandit standardmäßig aktiv, wenn der Browser sie anbietet.
- Eine einzige Welt läuft in einem Prozess (ein Kern). Für mehr als ~100 Spieler müsste man die Welt in
  Regionen teilen (aufwendig; für Freundesrunden nicht nötig).
