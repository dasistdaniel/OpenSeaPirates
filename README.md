# Open Sea Pirates (OSP)

Offene, prozedurale Piraten-Welt im Browser: Echtzeit-Segeln (WASD, Wind), später Breitseiten (Q/E),
Gold, Häfen und Shops. Konzept, Regeln und Roadmap: [docs/handout.md](docs/handout.md),
Technik-Entscheidungen: [docs/decisions.md](docs/decisions.md).

**Stand: M4 "Häfen und Shop"**: Häfen an den Küsten (Schutzzone, Taste F zum Andocken) mit Shop –
fünf Schiffsklassen, Upgrades für Kanonen/Rumpf/Segel, Sondermunition (Kettenkugel, Brandgeschoss,
Tasten 1–3), Reparatur und Bank. Davor M3 "Leben in der Welt" (auf M1 "Segeln" und M2 "Kampf" aufgebaut): NPC-Händler und
Piratenjäger (auch als Bande) tauchen um die Spieler herum auf, Abschüsse lassen Gold als Beute
fallen, Gold im HUD, 30 % Verlust beim Tod. Davor: unendliche Welt (Chunks aus Seed), Kamera,
Wind, Schiffsphysik mit Geländekollision, Spawn nahe anderer Schiffe, Minikarte; Breitseiten (Q/E) mit
Nachladezeit, Treffer, Tod und Wiederauftauchen mit Schonzeit, NPC-Händler als Ziele.
Powerups wurden bewusst wieder entfernt (passen nicht zum Thema).

## Entwickeln

Es gibt lokal kein Elixir; `./mx` synchronisiert den Quellordner auf den Server (`daniel@192.168.178.20`)
und führt `mix` in einem Docker-Container aus.

```bash
./mx test               # Tests
./mx precommit          # Kompilieren (Warnungen = Fehler), Format, Tests
./mx run scripts/terrain_stats.exs   # Landanteil/Spawn-Qualität messen, ASCII-Karte
./mx serve              # Dev-Server im Hintergrund: http://192.168.178.20:4001
                        # (OSP_SEED=12 ./mx serve: feste Welt; scripts/find_seed.exs findet Seeds mit nahem Hafen)
./mx logs | ./mx stop
```

## Produktion

Ein Container, ein Port (`HOST_PORT`, Standard 4100), kein Reverse Proxy enthalten – TLS macht der
Betreiber (WebSocket-Upgrade auf `/ws` durchreichen). Konfiguration über `.env` (siehe `.env.example`).

```bash
./deploy          # Quellen syncen, bauen, starten, auf /health warten
./deploy logs | ./deploy stop
```

## Aufbau

```
lib/osp/terrain.ex      Höhenfeld (Seed → Welt), Chunks für den Client
lib/osp/sailing.ex      Schiffsphysik: Tempo, Wenden, Wind, Kollision (rein)
lib/osp/spawn.ex        Startpunkt 20–40 WE von anderen (rein)
lib/osp/wander.ex       Wander-Bot (rein)
lib/osp/combat.ex       Breitseiten, Kugeln, Treffer, Tod (rein)
lib/osp/state.ex        Reiner Weltzustand und Zeitschritt
lib/osp/director.ex     Bevölkert die Welt um Spieler (Händler, Jäger, Banden), räumt Ferne auf
lib/osp/hunter.ex       KI der Piratenjäger (querab halten, feuern)
lib/osp/ships.ex        Schiffsklassen und Upgrade-Stufen (Daten und stats/1)
lib/osp/shop.ex         Hafengeschäfte: Schiff, Upgrades, Munition, Reparatur, Bank (rein)
lib/osp/ports.ex        Häfen aus dem Seed (pro Chunk), Schutzzone, Andockreichweite
lib/osp/port_cache.ex   ETS-Cache dafür
lib/osp/world.ex        Welt-Prozess (Hülle um State): 20 Hz, Schnappschüsse mit Umkreis (AOI)
lib/osp/web/            HTTP (Bandit/Plug) und WebSocket-Protokoll
priv/static/            Client (ES-Module, Canvas 2D, kein Build-Schritt)
```

Grafik: [Kenney Pirate Pack](https://kenney.nl/assets/pirate-pack) (CC0), Lizenztext unter
`priv/static/images/`.
