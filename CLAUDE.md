# OSP – Hinweise für die Arbeit am Projekt

- Überblick und Befehle: `README.md`. Konzept: `docs/handout.md` (Ausgangsidee, teils überholt),
  **aktuelle Regeln und Zahlen: `docs/decisions.md`**, offene Punkte: `docs/roadmap.md`.
- Elixir läuft nur auf dem Server: immer `./mx ...` benutzen (`./mx precommit` vor jedem Commit).
- Spiellogik als **reine Module** (`Osp.Sailing`, `Osp.Combat`, `Osp.Hunter`, `Osp.Shop`, ...) mit
  Tests; der `World`-Prozess und der Socket sind nur Hülle. Neue Regel = reine Funktion plus Test.
- Konstanten (Tempo, Wind, Ladezeit, Schaden, Preise) stehen oben in den Modulen: `sailing.ex`
  (`@turn_drag`, Tempo), `combat.ex` (Ladezeiten, Schaden, Längsfeuer), `ships.ex` (Klassen, Upgrades,
  Segelstufen), `shop.ex` (Preise), `director.ex` (NPC-Dichte), `state.ex` (NPC-Werte).
- Client ohne Build (ES-Module in `priv/static/js`). Eingaben als Tastenzustand senden. Namen aus dem
  Netz nur per `textContent` einsetzen, nie als HTML.
- Nationen und Gebiete: `Osp.Nations` (rein); die Heimatnation steht im Profil und in `ship.nation`,
  Boni rechnet `Osp.Ships.stats/1` ein. Geplanter Ausbau (Ruf, Quests, Eroberung) mit Plan unter
  `docs/superpowers/specs` und `docs/superpowers/plans`.
- **Nie das Spieler-Token an Clients schicken:** nach außen immer `Osp.State.public_id/1`.
- Richtungen: Kurs im Bogenmaß, Bildschirmkoordinaten (y nach unten), rechts = Kurs + 90°;
  Kenney-Schiffe zeigen mit dem Bug nach unten (Sprite-Rotation = Kurs − 90°).
- Sprache: UI und Kommentare Deutsch, Code-Bezeichner Englisch.
- Dev-Server `./mx serve` auf Port 4001; Produktion `./deploy` (Port 4100) nur auf ausdrücklichen Wunsch.
- Bash-Heredocs mit vielen Anführungszeichen brechen leicht; größere Änderungen besser als Skriptdatei
  schreiben und ausführen.
