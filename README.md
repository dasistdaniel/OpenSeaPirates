# Open Sea Pirates (OSP)

Offene, prozedurale Piraten-Welt im Browser für kleine Gruppen: Man segelt durch eine unendliche Welt
aus Inseln und Häfen, kämpft mit Breitseiten gegen Piratenjäger, Händler und andere Spieler, sammelt
Gold und rüstet in Häfen auf. Konzept: [docs/handout.md](docs/handout.md), Technik-Entscheidungen und
Spielregeln mit Zahlen: [docs/decisions.md](docs/decisions.md), offene Punkte: [docs/roadmap.md](docs/roadmap.md).

Stack: Elixir (Plug + Bandit + WebSock, kein Phoenix) und ein Canvas-2D-Client aus reinen ES-Modulen
ohne Build-Schritt. Der Vorgänger "Pirate Battle" (Phoenix LiveView) ist eingefroren und nicht Teil
dieses Repos.

## Spielstand (Funktionen)

- **Welt:** unendlich, Chunks aus einem Seed, Wind (dreht alle 30 s), Minikarte, Zoom (Mausrad) und
  Wegpunkte (Mausklick).
- **Nationen:** fünf Nationen mit Gebieten (aus Seed und Häfen), Flagge vor dem Namen, Wahl der
  Heimatnation beim ersten Beitritt mit kleinem Bonus, Start im Heimatgebiet. „Neu anfangen“ auf dem Beitrittsbildschirm setzt den Spielstand zurück und erlaubt eine neue Nation.
- **Ruf:** je Nation −100..+100; Abschüsse von Händlern und Jägern senken ihn (Notwehr gegen
  angreifende Jäger nicht). Jäger greifen ab Ruf −10 an. Bei Gesucht (≤ −40) sperrt der Hafen Shop und
  Bank (nur Wiedergutmachung gegen Gold), die Schutzzone entfällt, das Fort schießt und zwei Jäger
  kommen.
- **Quests:** Häfen bieten Lieferungen und Jagden an (bis zu 2 aktiv, 30 Minuten Spielzeit), Quest-Log
  mit grober Richtung, Gold und Ruf als Belohnung; bei Gesucht ist ein Auftrag die Wiedergutmachung.
- **Eroberung:** Häfen fremder Nationen können im Team erobert werden (Fort, Verteidiger-Wellen,
  Fortschrittsbalken); Hinterland bleibt dauerhaft, Randlagen fallen nach 30 Minuten zurück. Eroberungen
  stehen in `territory.json` im Volume (zusammen mit `profiles.json` sichern).
- **Segeln:** WASD, drei Segelstufen (Taste S: voll, Beisegel, gerafft), Kurven kosten Fahrt.
- **Kampf:** Breitseiten Q/E (beide Seiten: Leertaste), lange Ladezeit, Längsfeuer zählt doppelt,
  Sondermunition (Kettenkugel, Brandgeschoss, Tasten 1–3).
- **NPCs:** `Osp.Director` hält Händler (bewaffnet), Jäger und Banden um die Spieler; NPCs fahren
  Angriffsläufe statt zu kreisen.
- **Wirtschaft:** Gold als Beute, 30 % Verlust beim Tod (Bank ist sicher), Häfen mit Shop (fünf
  Schiffsklassen, Upgrades, Munition, Reparatur, Bank), Schutzzonen um Häfen.
- **Mehrspieler:** Online-Liste mit Abschüssen, Gold, Richtung und Entfernung; Pfeile am Bildrand und
  auf der Minikarte; Reconnect-Wächter im Client.
- **Persistenz:** Spielstände je Token in `profiles.json` (Docker-Volume `osp-data` unter `/data`),
  überleben Neustart und Deploy.
- **Schutz:** Raten-Limit, höchstens 60 Spieler, eindeutige Namen; Clients sehen nie das Token
  (`Osp.State.public_id/1`).
- **Ton und Optik:** WebAudio-Synthese (Brandung, Wind, Möwen, Kanonen), animierte Wellen, Rauch bei
  Schaden, Wrackteile.

Powerups wurden bewusst wieder entfernt (passen nicht zum Thema).

## Steuerung

| Eingabe | Aktion |
|---|---|
| `W` `A` `D` / Pfeile | Segel setzen, Ruder links/rechts |
| `Q` / `E`, `Leertaste` | Breitseite links / rechts, beide Seiten |
| `1` `2` `3` | Kugeln / Kettenkugel / Brandgeschoss |
| `S` | Segelstufe weiter: voll → Beisegel → gerafft → voll |
| `F`, `Esc` | im Hafen andocken, ablegen |
| Mausrad | Zoom (12–44 WE Bildbreite); über der Minikarte deren Ausschnitt (±42 bis ±336 WE) |
| Klick auf die Minikarte | Wegpunkt setzen (auch weit entfernt), Rechtsklick entfernt den nächsten |
| Linksklick / Rechtsklick | Wegpunkt setzen oder entfernen / nächsten entfernen |
| `H`, `M` | Hilfe, Ton aus/an |

## Entwickeln

Es gibt lokal kein Elixir; `./mx` synchronisiert den Quellordner auf den Server (`daniel@192.168.178.20`)
und führt `mix` in einem Docker-Container aus.

```bash
./mx test               # Tests (334)
./mx precommit          # Kompilieren (Warnungen = Fehler), Format, Tests; vor jedem Commit
./mx deps.update bandit # beliebige mix-Aufgaben, hier ein Abhängigkeits-Update (mix.lock kommt zurück)
./mx run scripts/load_test.exs    # Lasttest ohne Netzwerk (Takt-Zeit je Spielerzahl), siehe docs/performance.md
./mx run scripts/terrain_stats.exs   # Landanteil/Spawn-Qualität messen, ASCII-Karte
./mx serve              # Dev-Server im Hintergrund: http://192.168.178.20:4001
                        # (OSP_SEED=12 ./mx serve: feste Welt; scripts/find_seed.exs findet Seeds mit nahem Hafen)
./mx logs | ./mx stop   # Log folgen (Strg+C beendet nur das Log) / Dev-Server stoppen
```

Flaggen neu erzeugen: `python scripts/nation_flags.py priv/static/images/flags`.

Vorschaubild für geteilte Links neu erzeugen: `python scripts/preview_image.py priv/static/images/preview.jpg`.

Schiffsbilder neu erzeugen (aus dem Kenney Pirate Pack): `python scripts/ship_sprites.py <pack.zip> priv/static/images/ships`
(pro Klasse und Farbe drei Bilder: voll, `_reefed`, `_studding`; Segelgrößen in `SAIL_SCALE`).

## Produktion

Ein Container, ein Port (`HOST_PORT`, Standard 4100), kein Reverse Proxy enthalten – TLS macht der
Betreiber (WebSocket-Upgrade auf `/ws` durchreichen). Konfiguration über `.env` (siehe `.env.example`).

```bash
./deploy          # Quellen syncen, bauen, starten, auf /health warten (sichert vorher profiles.json)
./deploy logs | ./deploy stop
./deploy backup    # Spielstände nach ~/osp-backups auf dem Server kopieren
./deploy cron      # Sicherung alle 6 Stunden per Cron einrichten (14 Tage aufbewahrt, Log: ~/osp-backups/backup.log)
```

Wiederherstellen: die Dateien aus `~/osp-backups` nach `/data/profiles.json`, `/data/territory.json` und `/data/seed.txt` im Volume `osp-data` kopieren
(Container stoppen, kopieren, starten). Ein defektes `profiles.json` wird beim Start nach `.corrupt`
verschoben und `profiles.json.bak` geladen.

## Aufbau

```
lib/osp/terrain.ex      Höhenfeld (Seed → Welt), Chunks für den Client
lib/osp/sailing.ex      Schiffsphysik: Tempo, Wenden (kostet Fahrt), Wind, Kollision (rein)
lib/osp/spawn.ex        Startpunkt 20–40 WE von anderen (rein)
lib/osp/nations.ex      Nationen, Gebiete (Zelle + nächster Hafen), Boni (rein)
lib/osp/reputation.ex   Ruf je Nation: Stufen, Änderungen, Rückgang (rein)
lib/osp/fort.ex         Forts der Häfen: Warnung, Schüsse mit Vorhalt, Alarm (rein)
lib/osp/quests.ex       Quests: Angebote aus Seed/Hafen/Zeitfenster, Fortschritt, Prüfung (rein)
lib/osp/conquest.ex     Eroberung: Angriff, Verteidiger, Fortschritt, Rückfall (rein)
lib/osp/territory.ex    Speicher der eroberten Häfen (territory.json)
lib/osp/world_seed.ex   Seed der Hauptwelt, gespeichert in seed.txt (die Welt bleibt über Neustarts gleich)
lib/osp/wander.ex       Wander-Bot, Ausweichkurs, Befreien festgefahrener NPCs (rein)
lib/osp/combat.ex       Breitseiten, Kugeln, Längsfeuer, Treffer, Tod, Beute (rein)
lib/osp/state.ex        Reiner Weltzustand, Zeitschritt, NPC-Steuerung, Schnappschüsse, öffentliche IDs
lib/osp/director.ex     Bevölkert die Welt um Spieler (Händler, Jäger, Banden), räumt Ferne auf
lib/osp/hunter.ex       Kampf-KI der NPCs: Angriffsläufe (Anflug, Vorbeilauf, Abdrehen)
lib/osp/ships.ex        Schiffsklassen, Upgrade-Stufen, Segelstufen (Daten und stats/1)
lib/osp/shop.ex         Hafengeschäfte: Schiff, Upgrades, Munition, Reparatur, Bank (rein)
lib/osp/profile.ex      Spielstand eines Spielers (prüfen, auf Schiff anwenden)
lib/osp/profiles.ex     Speicher: GenServer + atomare JSON-Datei, Sicherung .bak
lib/osp/ports.ex        Häfen aus dem Seed (pro Chunk), Schutzzone, Andockreichweite
lib/osp/port_cache.ex   ETS-Cache dafür
lib/osp/world.ex        Welt-Prozess (Hülle um State): 20 Hz, Schnappschüsse mit Umkreis (AOI), Autosave
lib/osp/web/            HTTP (Bandit/Plug) und WebSocket-Protokoll (socket.ex beschreibt alle Nachrichten)
priv/static/js/         Client: main (Verdrahtung), net, chunks, snapshots, render, minimap, input,
                        audio, shop, waypoints, nations
scripts/                Lasttest, Gelände-Statistik, Seed-Suche, Schiffsbilder
test/osp/               ExUnit-Tests der reinen Module und des Protokolls
```

Grafik: [Kenney Pirate Pack](https://kenney.nl/assets/pirate-pack) (CC0), Lizenztext unter
`priv/static/images/`.

Lizenz: Code unter der [MIT-Lizenz](LICENSE). Die Grafiken stehen unter ihren eigenen Lizenzen (siehe oben).
