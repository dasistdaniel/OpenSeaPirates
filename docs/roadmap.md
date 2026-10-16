# Roadmap bis "fertig" (Stand nach M4)

**Ziel:** Ein Spiel, das du mit Freunden dauerhaft online betreiben kannst – ohne dass bei jedem Deploy
alles verloren geht, ohne dass es unter Last bricht, und das du ohne KI-Hilfe weiterpflegen kannst.

Aufwand: S = Stunden, M = ein Abend, L = mehrere Tage.

## A. Muss (ohne das ist es kein fertiges Spiel)

| # | Aufgabe | Aufwand | Notiz |
|---|---|---|---|
| A1 | ✅ erledigt: **Persistenz:** Gold, Bank, Klasse, Upgrades, Munition, Name und Statistik überleben Neustart/Deploy | M–L | Anonymes Token (`osp-token`) ist schon die Identität. Speicher: SQLite (Ecto) oder einfacher eine Datei/DETS je Spieler. Docker-Volume nötig (`docker-compose.yml`). Beim Beitritt laden, bei Änderung/Verlassen/alle 30 s speichern. |
| A2 | ✅ erledigt (`./deploy backup`, Sicherung vor jedem Deploy, Repo auf Forgejo `daniel/OpenSeaPirates`): **Backup & Betrieb:** Volume sichern, Logs, Neustart-Verhalten, Git-Remote (Forgejo läuft auf dem Server, Port 3000) | S–M | Repo ist nur lokal; jetzt auf Forgejo/GitHub pushen! |
| A3 | **Spieltest mit Freunden + Balancing:** Jäger-Stärke, Preise, Einkommen pro Minute, Tempo | M (laufend) | Alle Zahlen stehen in `ships.ex`, `shop.ex`, `combat.ex`, `state.ex`, `director.ex`. Gold-Rate messen (Logs). |
| A4 | ✅ erledigt (Raten-Limit mit Trennung, Obergrenze 60 Spieler, eindeutige Namen): **Missbrauchsschutz:** Raten-Limit für Eingaben und `fire`, Name-Duplikate, Chat gibt es noch nicht | S–M | Chunk-Anfragen sind schon begrenzt, Eingaben nicht. |
| A5 | ✅ erledigt (Hilfe mit H, Lautstärke, Credits): **Credits und Hilfe:** Kenney-Lizenz im Footer, kurzer Hilfe-Dialog (Tasten, Ziel), Lautstärke-Einstellung | S | `priv/static/index.html`, Lizenz liegt in `priv/static/images/`. |

## B. Sollte (macht es rund)

| # | Aufgabe | Aufwand | Notiz |
|---|---|---|---|
| B1 | ✅ gemessen und Engpass behoben, siehe `docs/performance.md`: **Leistung messen (M5):** Lasttest mit 30–50 Bots, Tickzeit; Spatial Hash für Kugeln/Treffer; Schnappschuss-Größe | M–L | Heute prüft jede Kugel jedes Schiff (O(n²)). Für Freundesrunde (< 10) egal, für mehr nötig. |
| B2 | **Rangliste und "Wer ist online":** Abschüsse, Gold-Rekord | M | Setzt A1 voraus. |
| B3 | ✅ Händler wehren sich (Entern offen): **Händler schießen zurück / Entern:** Händler sind zu leichte Beute | M | `hunter.ex` als Vorlage. |
| B4 | **Mine** (vom M2-Plan) und weitere Sondermunition | S–M | `combat.ex`. |
| B5 | **Sichtbarer Schaden:** Rauch bei wenig HP, Wrackteile beim Untergang | S–M | Kenney-Effekte vorhanden. |
| B6 | **Reconnect-Komfort:** Hinweis "Verbindung verloren", Schiff 10 s geschützt (ist drin), Auto-Rejoin testen | S | `net.js`. |
| B7 | **Stabilität:** Jäger hängen an Küsten fest; Director-Dichte prüfen | S–M | Beobachtung im Spiel. |

## C. Kann (Ausbau, wenn Zeit bleibt)

Handel mit Waren zwischen Häfen · Ruf/Kopfgeld · Schiffs-Kosmetik (Flagge, Segelzeichen) · Crew und Offiziere ·
Wetter/Stürme · Biome mit Schwierigkeitsstufen · Welt pro Raum · Chat · Musik und echte Sounds.
(Ideen ausführlich in `docs/upgrades.md`.)

## D. Übergabe (damit es ohne Claude weiterläuft)

- Alles Wichtige steht in `README.md`, `CLAUDE.md`, `docs/handout.md`, `docs/decisions.md`, `docs/upgrades.md`.
- Tests laufen mit `./mx test` (78 Tests); vor jedem Commit `./mx precommit`. Deploy: `./deploy`.
- Spiellogik ist in reinen Modulen (`state.ex`, `combat.ex`, `shop.ex`, ...) mit Tests; wer Elixir kann, findet
  sich schnell zurecht. Konstanten stehen oben in den Modulen.
- Elixir-Grundlagen für Änderungen: die Module sind klein und kommentiert; Client ist reines JavaScript ohne Build.

## Vorgeschlagene Reihenfolge (30 Tage)

1. **Woche 1:** A1 (Persistenz), A2 (Git-Remote und Backup), A5 (Credits/Hilfe), A4 (Raten-Limit).
2. **Woche 2:** A3 (Spieltest mit Freunden, Balancing), B7 (Stabilität), B6, B5.
3. **Woche 3:** B1 (Leistung/Last), B2 (Rangliste), B3 (Händler wehren sich), B4 (Mine).
4. **Woche 4:** Feinschliff nach Spieltests, Teile aus C, Doku auf den neuesten Stand.
