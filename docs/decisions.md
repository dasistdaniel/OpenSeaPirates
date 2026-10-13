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
