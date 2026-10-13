# Open Sea Pirates (OSP)

Offene, prozedurale Piraten-Welt im Browser: Echtzeit-Segeln (WASD, Wind), später Breitseiten (Q/E),
Gold, Häfen und Shops. Konzept, Regeln und Roadmap: [docs/handout.md](docs/handout.md),
Technik-Entscheidungen: [docs/decisions.md](docs/decisions.md).

**Stand: M2 "Kampf"** (auf M1 "Segeln in der Welt" aufgebaut): unendliche Welt (Chunks aus Seed), Kamera,
Wind, Schiffsphysik mit Geländekollision, Spawn nahe anderer Schiffe, Minikarte; Breitseiten (Q/E) mit
Nachladezeit, Treffer, Tod und Wiederauftauchen mit Schonzeit, Powerups (Torpedo, Boost, Schild,
Reparatur, Salve, Leertaste), NPC-Händler als Ziele.

## Entwickeln

Es gibt lokal kein Elixir; `./mx` synchronisiert den Quellordner auf den Server (`daniel@192.168.178.20`)
und führt `mix` in einem Docker-Container aus.

```bash
./mx test               # Tests
./mx precommit          # Kompilieren (Warnungen = Fehler), Format, Tests
./mx run scripts/terrain_stats.exs   # Landanteil/Spawn-Qualität messen, ASCII-Karte
./mx serve              # Dev-Server im Hintergrund: http://192.168.178.20:4001
./mx logs | ./mx stop
```

## Produktion

Ein Container, ein Port (`HOST_PORT`, Standard 4200), kein Reverse Proxy enthalten – TLS macht der
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
lib/osp/combat.ex       Breitseiten, Kugeln, Treffer, Tod, Powerups (rein)
lib/osp/state.ex        Reiner Weltzustand und Zeitschritt
lib/osp/world.ex        Welt-Prozess (Hülle um State): 20 Hz, Schnappschüsse mit Umkreis (AOI)
lib/osp/web/            HTTP (Bandit/Plug) und WebSocket-Protokoll
priv/static/            Client (ES-Module, Canvas 2D, kein Build-Schritt)
```

Grafik: [Kenney Pirate Pack](https://kenney.nl/assets/pirate-pack) (CC0), Lizenztext unter
`priv/static/images/`.
