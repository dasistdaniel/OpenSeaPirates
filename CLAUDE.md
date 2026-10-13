# OSP – Hinweise für die Arbeit am Projekt

- Konzept/Roadmap: `docs/handout.md`; Entscheidungen: `docs/decisions.md`. Meilensteine in Reihenfolge, jeder spielbar.
- Elixir läuft nur auf dem Server: immer `./mx ...` benutzen (`./mx precommit` vor jedem Commit).
- Spiellogik als **reine Module** (`Osp.Sailing`, `Osp.Spawn`, `Osp.Terrain`, ...) mit Tests; der
  `World`-Prozess und der Socket sind nur Hülle.
- Konstanten (Tempo, Wind, Reichweiten) zentral an den Modulköpfen halten; Werte siehe Handout §4/§5.
- Client ohne Build (ES-Module in `priv/static/js`). Eingaben als Tastenzustand senden.
- Richtungen: Kurs im Bogenmaß, Bildschirmkoordinaten (y nach unten), rechts = Kurs + 90°;
  Kenney-Schiffe zeigen mit dem Bug nach unten (Sprite-Rotation = Kurs − 90°).
- Sprache: UI und Kommentare Deutsch, Code-Bezeichner Englisch.
- Dev-Server `./mx serve` auf Port 4001; Produktion `./deploy` (Port 4100) nur auf ausdrücklichen Wunsch.
