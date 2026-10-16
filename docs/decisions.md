# Technik-Entscheidungen

| Thema | Entscheidung | Warum |
|---|---|---|
| Server | Elixir, **Plug + Bandit + WebSock** (kein Phoenix) | Es gibt keine HTML-Seiten-Logik, nur Statik, `/health` und einen WebSocket. Weniger Abhängigkeiten, volle Kontrolle über das Protokoll. Phoenix kann später dazukommen (Konten/Admin). |
| Spielschleife | Ein `World`-GenServer je Welt, 20 Hz, Schritte à 25 ms | Einfach, deterministisch testbar; Physik in reinen Modulen (`Sailing`, `Spawn`, `Wander`). |
| Gelände | Stetiges Höhenfeld aus Value-Noise (`:erlang.phash2`), Land ab 0,66 | Unendlich ohne Speicher, organische Küsten; Kollision fragt direkt das Feld ab. Chunks (16×16 WE, 33×33 Bytes) gehen nur zur Darstellung an den Client. |
| Client | Canvas 2D, ES-Module, **kein Build** | Wenige Entities, schnell zu iterieren. Renderer ist getrennt (`render.js`), falls PixiJS später nötig wird. |
| Transport | JSON-Text für Schnappschüsse, Binär nur für Chunks | Lesbar beim Entwickeln; Umstieg auf Binärformat nach Lasttest (M5). |
| Identität | Anonymes Token aus `localStorage` | Reicht bis zu Konten (M6). Reconnect behält das Schiff 10 s. |
| Umkreis (AOI) | 45 WE um das eigene Schiff | Minikarte reicht 42 WE; echte Räumlichkeit (Spatial Hash) folgt in M5. |
| Welten | Eine Hauptwelt `main`; Welt-Registry ist schon pro ID | Welt pro Raum später ohne Umbau möglich. |
| Dev-Betrieb | `./mx` (SSH + Docker) | Kein Elixir lokal. Dev-Server auf Port 4001 (4000 belegt das Schwesterprojekt Pirating). |
| Welt-Aufbau | `Osp.State` (rein) + `Osp.World` (Prozess-Hülle) | Spiellogik ohne Prozess testbar (41 Tests); Combat/Sailing/Spawn sind reine Module. |
| Powerups | Entfernt (M2 ausprobiert) | Passen thematisch nicht; Fähigkeiten kommen über Shop-Ausrüstung (docs/upgrades.md). |
| NPCs | `Osp.Director` (alle 2 s, je Spieler: Soll 2 Händler, 1 Jäger, 18 % Bande); Spawn 28–45 WE entfernt, Despawn ab 100 WE | Welt wirkt lebendig, egal wie wenige Spieler da sind; Kosten bleiben konstant pro Spieler. |
| Beute | NPCs lassen Kopfgeld als Münzhaufen fallen; Spieler verliert 30 % getragenes Gold beim Tod; Einsammeln durch Überfahren | Risiko/Gewinn: Gold bleibt umkämpft; Bank folgt mit den Häfen (M4). |
| Respawn | Neue Schiffe starten möglichst >36 WE von Piratenjägern | Kein Spawnkill durch Jäger. |
| Häfen | Ein Hafen je Chunk mit 16 % Chance, Ankerplatz im Wasser an einer Küste; Schutzzone 3,5 WE, Andocken ab 2,8 WE und Tempo < 0,7 | Deterministisch aus dem Seed, kein Speicher; Ergebnis je Chunk im ETS-Cache (`PortCache`). |
| Schiffe | Fünf Klassen aus Kenney-Einzelteilen, vorberechnete PNGs (`scripts/ship_sprites.py`) je Klasse und Farbe | Browser muss nichts zusammensetzen; Klasse und Upgrades gelten dauerhaft (nur Gold beim Tod geht verloren). |
| Shop | Regeln und Preise ausschließlich im Server (`Osp.Shop`); Client zeigt nur die Ansicht | Kein Cheaten über den Client; eine Stelle für Balancing. |
| Persistenz | Ein GenServer (`Osp.Profiles`) mit JSON-Datei im Volume `/data`, Schreiben alle 5 s bei Änderung und beim Beenden, atomar mit `.bak`; Inhalt wird beim Laden gegen feste Listen geprüft (`Osp.Profile.decode/1`) | Kein Datenbankserver, keine native Abhängigkeit, lesbar und leicht zu sichern; reicht für Hunderte Spieler. Spätere Datenbank hinter derselben Schnittstelle (`get/put`). |
| Händler | 14 HP, 4 Kanonen je Seite (Nachladen 2,6 s), Aussehen Handelsgaleone, Kopfgeld 50–120; friedlich, bis sie getroffen werden, dann Angreifer querab und Feuer; Flucht bei < 40 % HP oder wenn der Angreifer > 14 WE weg ist | Händler waren zu leichte Beute; historisch waren Handelsschiffe oft schwer bewaffnet. Für Neulinge bleibt es überlebbar (zwei volle Breitseiten = 8 Schaden bei 12 HP). |
