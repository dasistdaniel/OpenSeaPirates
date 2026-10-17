# Handout: "Open Sea Pirates" (OSP) – offene Piraten-Welt im Browser

> Komplett-Neubau (kein Weiterbau des bisherigen Prototyps). Dieses Dokument enthält Spielidee, Regeln,
> Architektur-Empfehlung, Zahlenwerte als Startpunkt, Meilensteine, Risiken und die Erkenntnisse aus dem
> Prototyp "Pirate Battle". Es ist so geschrieben, dass man es einem neuen Projekt (oder einer KI) direkt
> als Auftrag geben kann.

> **Stand:** Das Spiel ist nach diesem Handout gebaut (M1–M6 weitgehend umgesetzt). Wo sich Regeln
> geändert haben, gilt `docs/decisions.md` (u. a. Segelstufen, Gefechtsfluss, Zoom/Wegpunkte,
> Powerups verworfen). Dieses Dokument bleibt die Ausgangsidee.

---

## 1. Vision in drei Sätzen
Ein Browser-Spiel für kleine Gruppen: Man segelt mit einem Piratenschiff durch eine **unendliche,
prozedurale Welt** aus Inseln, Riffen und Häfen. Man sucht Gefechte (gegen andere Spieler und NPC-Schiffe),
verdient **Gold** durch Abschüsse und Beute und gibt es in **Häfen/Shops** für Schiffs-Upgrades aus.
Alles läuft in **Echtzeit** mit direkter Steuerung (WASD + Breitseiten), kein Rundenspiel, kein Racer: träge
Segelschiffe, bei denen **Wind und Ausrichtung der Breitseite** zählen.

**Spielgefühl-Leitplanken**
- Langsam und schwer (Segelschiff), nicht schnell und twitchy.
- Positionieren > Zielen: man dreht das Schiff, damit die Breitseite trifft.
- Wind ist ein echter Faktor (Rückenwind schneller, Gegenwind langsamer).
- Man kann auch einfach nur herumschippern und Dinge entdecken; Kampf ist optional, aber lohnend.
- Kleine Gruppen (2–20 gleichzeitig) müssen sich lebendig anfühlen → NPCs sind Pflicht, nicht Zugabe.

---

## 2. Spielschleife (Core Loop)
1. **Beitreten** → Schiff spawnt zufällig im Wasser, **1–2 Bildschirmbreiten** von einem anderen Spieler entfernt
   (gibt es keinen, zufälliger Punkt nahe einem Hafen).
2. **Erkunden/Segeln** → Insel, Riffe, Häfen, Beute-Truhen, NPC-Schiffe, andere Spieler.
3. **Kämpfen** → Breitseiten; Ziel ist Beute und Gold.
4. **Gold einsammeln** (Drops vom Wasser) → in einen **Hafen** fahren.
5. **Aufrüsten** → Rumpf, Kanonen, Segel, Reparatur.
6. Zurück auf See, stärkere Gegner suchen.

Kurzfristiges Ziel: Abschüsse/Beute. Mittelfristig: bessere Ausrüstung. Langfristig: Rangliste, Titel,
Ruf (siehe Ausbaustufen).

---

## 3. Steuerung
| Taste | Aktion |
|---|---|
| `W` / `↑` | Segel setzen (beschleunigen) |
| `A` / `D` (`←` / `→`) | Ruder links / rechts |
| `Q` | Breitseite links (Backbord) |
| `E` | Breitseite rechts (Steuerbord) |
| `Leertaste` | beide Seiten feuern |
| `1` `2` `3` | Munition: Kugeln / Kettenkugel / Brandgeschoss |
| `S` | Segelstufe weiter (voll → Beisegel → gerafft) |
| `F` | im Hafen andocken / Shop öffnen |
| Mausrad, Klick | Zoom, Wegpunkte setzen/entfernen |
| `H`, `M` | Hilfe, Ton an/aus |

(Die große Karte mit `Tab` wurde nicht gebaut; die Online-Liste zeigt Spieler mit Richtung.)

Eingabe wird **als Tastenzustand** an den Server gesendet (nicht als einzelne Ereignisse), Q/E/F als
Ereignisse. Beim Fenster-Blur alle Tasten freigeben.

---

## 4. Schiff, Physik und Wind (Startwerte)
Alle Maße in **Welteinheiten (WE)**; 1 WE ≈ Kantenlänge eines Geländefelds. Ein Bildschirm zeigt horizontal 26 WE (Höhe je nach Seitenverhältnis, ca. 12–15 WE).

| Wert | Startwert | Bemerkung |
|---|---|---|
| Schiffsradius (Treffer/Kollision) | 0,36 WE | |
| Segelstufen (S) | gerafft ×0,65 Tempo / ×1,4 Wendigkeit; Beisegel ×1,25 / ×0,7 | |
| Höchsttempo (Basis, ohne Wind) | 2,0 WE/s | Wind: 2,8 mit, 1,2 gegen den Wind; M1-Spieltest: 1,4 war zu langsam |
| Beschleunigung | 1,5 WE/s² | |
| Auslaufen ohne Segel | 0,7 WE/s² | |
| Wenden | 1,4 rad/s | bei Stillstand 45 % davon (Ruderwirkung braucht Fahrt); Ruderlegen kostet Fahrt (`@turn_drag` 1,2) |
| Wind | 6 Richtungen, dreht alle 30 s um 60° (oder stufenlos) | |
| Windeinfluss auf Höchsttempo | `1 + 0,4·cos(Kurs − Windrichtung)` | Rückenwind +40 %, Gegenwind −40 % |
| Aufprall Fels/Riff | bremst auf 35 %; ab Tempo > 0,9 WE/s 0,5 Schaden (Pause 0,7 s) | |

Wind soll im HUD als Kompass mit Prozent-Bonus sichtbar sein. Optional: Windfeld variiert langsam räumlich
(später), zunächst global pro Welt.

**Wichtig aus dem Prototyp:** Kurs als Winkel (Bogenmaß) im Bildschirm-Koordinatensystem (y nach unten),
"rechts" = Kurs + 90°. Q/E-Seitenzuordnung und Sprite-Orientierung (Kenney-Schiffe zeigen mit dem Bug
nach unten → Rotation = Kurs − 90°) mit Tests absichern.

---

## 5. Waffen und Kampf
### 5.1 Breitseiten
- Je Seite eigener Nachladetimer (**3,0 s**, Kugelschaden 1,5; Treffer von vorn/hinten zählen doppelt), Taste `Q`/`E`.
- Eine Salve = **3 Kugeln** nebeneinander am Rumpf, senkrecht zum Kurs; Kugel übernimmt 80 % der
  Schiffsgeschwindigkeit in Fahrtrichtung.
- Kugel: Tempo 6 WE/s, Lebensdauer 0,75 s (**Reichweite ≈ 4,5 WE**), Schaden 1,5 (Sondermunition 0,75 bzw. 0,9), Trefferradius 0,08 WE.
- Kugeln stoppen an Inseln (Splash-Effekt), nicht an Riffen.
- Kein Friendly Fire im Team-Modus (falls es Crews gibt).
- **Längsfeuer** (umgesetzt): Treffer von Bug oder Heck (Kugel fliegt entlang der Schiffsachse) machen doppelten Schaden.

### 5.2 Schiffswerte
- Rumpf (HP): 12 (Startschiff)
- Respawn bei Tod an zufälligem sicheren Punkt (siehe §8), **2 s Schonzeit**.
- Treffer-Feedback: Explosion, Zahlen, Splitter, Rauch unter 50 % HP (schwarz unter 25 %), Wrackteile beim Untergang.

### 5.3 Powerups – verworfen
Schwimmende Powerups (Torpedo, Boost, Schild, ...) wurden in M2 ausprobiert und wieder entfernt, weil sie
thematisch nicht passen. Stattdessen kommen Fähigkeiten über **Ausrüstung und Munition aus dem Shop**
(siehe docs/upgrades.md), die man mit Gold kauft und fest am Schiff hat.

---|---|
| Torpedo | schneller Schuss geradeaus, 4 Schaden, Tempo 8 WE/s, Reichweite 8 WE |
| Mine | wird hinter dem Schiff ausgesetzt, scharf nach 0,8 s, 4 Schaden im Radius 1,3 WE, Lebensdauer 25 s |
| Boost | 2,5 s schneller |
| Schild | 5 s halber Schaden |
| Reparatur | +5 HP |
| Salve | beide Seiten gleichzeitig, je 5 Kugeln, ohne Nachladezeit |

Spawn auf zufälligen Wasserfeldern in der Nähe von Spielern/Gefechten (nicht überall in der unendlichen Welt),
Maximalzahl pro Gebiet begrenzt.

---

## 6. Welt
### 6.1 Prozedurale Generierung (Chunks)
- **Seed** pro Welt. Terrain wird **deterministisch** aus `(seed, x, y)` berechnet, nichts davon wird
  gespeichert. Server und Client sehen dieselbe Welt, weil der **Server Chunks schickt** (Tile-Arrays);
  der Client muss den Generator nicht kennen.
- Chunk = 16×16 Geländefelder (jedes Feld ≈ 1 WE breit). Der Server hält die Chunks im Umkreis aller
  Spieler im Speicher (LRU-Cache), erzeugt sie bei Bedarf.
- Geländeklassen: `tiefes Wasser`, `flaches Wasser/Riff`, `Insel` (Sand/Gras/Palmen als Deko), `Hafen`.
- Erzeugung: 2D-Value-/Simplex-Noise (mehrere Oktaven) → Höhe `h`.
  `h < 0.35` tiefes Wasser, `0.35–0.45` Riff, `> 0.45` Insel. Zusätzlich Maske, damit Inseln nicht zu groß werden.
- **Biome/Regionen** (später, aus niedrigfrequentem Noise): ruhige Gewässer (Einsteiger), Riffgebiete,
  Sturmzonen, gefährliche Zonen mit stärkeren NPCs. Schwierigkeit steigt mit der Entfernung vom Startgebiet.
- **Häfen:** pro Chunk Wahrscheinlichkeit aus `hash(seed, chunk)`, mind. Abstand zueinander; Hafen =
  Inselrand mit Anleger und **Schutzzone** (Radius 3 WE, kein PvP, keine Mines).
- **Garantien:** Spawn- und Hafengebiete sind befahrbar und nicht eingeschlossen (Flood-Fill im Chunk-Umkreis).
- Kollisionsmodell: Geländefeld-Raster. Insel/Riff-Felder sind Kreise (Insel r≈0,92, Riff r≈0,45 um das
  Feldzentrum) → einfach, robust, ausreichend gut.

### 6.2 Karte/HUD
- Kamera folgt dem Schiff, Zoom fest (optional 2 Stufen).
- **Minimap** (Ausschnitt ±40 WE): entdeckte Häfen, Spieler/NPCs in Radar-Reichweite.
- Große Karte mit "Nebel des Krieges" (nur besuchte Chunks), Hafen-Markierungen.

---

## 7. NPCs und Beute (Ersatz für "leere Welt")
**Das ist der wichtigste Gameplay-Baustein**, wenn nur wenige Spieler online sind.
| Typ | Verhalten | Beute |
|---|---|---|
| **Händler** | langsam, fährt Routen zwischen Häfen, flieht bei Beschuss, schießt schwach | viel Gold, Waren |
| **Piratenjäger** | patrouilliert, greift Spieler im Radius an (Breitseite, hält Abstand) | mittleres Gold |
| **Bande** (2–3 Schiffe) | greift gemeinsam an | gutes Gold + Waren |
| **Boss** (später) | großes Schiff, mehr HP, besondere Waffe | seltene Upgrades |

- NPC-Dichte: pro Spieler-Umgebung (Radius ≈ 40 WE) Ziel ~3–6 NPC-Schiffe, Spawn außerhalb der Sicht,
  Despawn weit weg.
- KI-Grundlage (bewährt im Prototyp): Gegner so anfahren, dass er **querab** liegt (Breitseitenwinkel ±90°),
  feuern wenn im Bogen und in Reichweite; Land voraus → abdrehen.
- **Beute/Loot:** Gold als **schwimmende Münzstapel** (Drops), Truhen, Waren. Einsammeln durch Überfahren.

---

## 8. Spawn und Tod
- **Spawn:** Zufälliger Wasserpunkt, dessen nächster Spieler **20–40 WE** entfernt ist (1–2 Bildschirme),
  nicht in Sichtweite von Gegnern kleiner als 12 WE, nicht auf Land/Riff; Schonzeit 2–3 s.
  Existiert kein anderer Spieler: nahe einem Hafen starten.
- **Tod:** Respawn nach 3 s. Verlust: **Teil des mitgeführten Golds** (z. B. 30 %) fällt als Beute-Drops
  an der Todesstelle ab; Upgrades bleiben. Killer bekommt Gold-Bonus.
- Disconnect: Schiff bleibt **10 s** in der Welt (Schutzwirkung "Schutzblase", sonst Exploit); danach aus der Welt.

---

## 9. Ökonomie und Upgrades
### 9.1 Gold
- NPC-Händler 30–80, Piratenjäger 40–100, Bande 150–300; Spieler-Abschuss 100 + 25 % von dessen getragenem Gold.
- Gold muss **getragen** werden und kann beim Tod teilweise verloren gehen. In einem Hafen kann man
  Gold **einlagern** (sicher, zählt für Rangliste) oder direkt ausgeben.

### 9.2 Hafen/Shop (LiveView- oder HTML-Overlay)
Andocken: im Hafenradius, Tempo < 0,3 WE/s, Taste `F`. Dann Shop:
| Kategorie | Stufen | Effekt (Startwerte) |
|---|---|---|
| **Rumpf** | 1–5 | HP 12 → 14 → 17 → 21 → 26 |
| **Kanonen** | 1–5 | Schaden/Kugel 1 → 1,2 → 1,4 → 1,7 → 2; Nachladen 1,8 → 1,2 s |
| **Segel** | 1–5 | Höchsttempo 1,4 → 1,55 → 1,7 → 1,85 → 2,0 |
| **Takelage** | 1–3 | Wendigkeit +10 % je Stufe |
| **Reparatur** | – | volle HP gegen Gold (billig im Hafen) |
| **Schiffsklasse** (später) | Schaluppe → Brigg → Fregatte | mehr Kanonen pro Seite, mehr HP, langsamer |
Kosten: 100 / 250 / 500 / 1000 / 2000 Gold je Stufe (Kategorie-Faktor 1–1,5). Zahlen sind Startwerte und
**müssen im Spieltest balanciert werden** (Inflation durch NPC-Farmen im Auge behalten).

### 9.3 Schutzzonen
Im Hafenradius (3 WE): kein Schaden, Kanonen gesperrt, Kugeln verschwinden. Verhindert Camping.

---

## 10. Technik-Architektur (Empfehlung für den Neubau)
### 10.1 Stack
**Server: Elixir/Phoenix** (OTP passt zu vielen kleinen Prozessen, einfaches Deployment als Release in einem
Container). **Client:** TypeScript + Canvas 2D (oder PixiJS/Phaser für Sprites, Partikel, Kamera),
Build per esbuild/Vite. Menüs, Lobby, Shop als normales HTML (LiveView geeignet oder reines JS-Frontend).
**Netzwerk:** eigener WebSocket (Phoenix Channel oder `WebSock` direkt mit Bandit), **nicht** LiveView für
die Spielschleife (im Prototyp ging es per `push_event` bis ~6 Spieler gut, skaliert aber mit AOI-Filterung
besser über Channels/binär).
**Persistenz:** SQLite (Ecto) für Konten/Gold/Upgrades – eine Datei im Docker-Volume reicht für kleine
Communities; Postgres bei Wachstum.

### 10.2 Prozesse
```
Application
├─ WorldSupervisor (DynamicSupervisor)
│   └─ World (GenServer je Welt/Raum): tick 20 Hz, hält Entities, Spatial Hash
│        ├─ ChunkCache (ETS, LRU): Tile-Arrays je Chunk
│        └─ NPC-Director: Spawn/Despawn nach Spielerumgebung
├─ Registry (Welt-ID → Pid)
├─ PlayerChannel (je Verbindung): Input → World, Snapshots ← World
└─ Repo (Ecto): Konten, Gold, Upgrades, Rangliste
```
- **World-Tick (50 ms):** Eingaben anwenden → Physik (Substeps à 20 ms, damit nichts durch Inseln "tunnelt")
  → Kugeln → Treffer → Tod/Respawn → Loot → NPC-KI → AOI-Snapshots.
- **Spatial Hash:** Gitter (Zelle ≈ 8 WE). Kollisions- und Sichtabfragen nur in Nachbarzellen.
- **AOI (Area of Interest):** Snapshot je Spieler nur mit Entities im Umkreis (≈ 25 WE), alle 50–100 ms,
  mit Delta (nur Änderungen) oder zumindest gerundeten Zahlen; Chunks beim Betreten des Umkreises nachladen.
- **Client:** hält die letzten 2–3 Snapshots, **interpoliert 100 ms verzögert**; Kugeln per Geschwindigkeit
  extrapoliert; lokale Effekte (Partikel, Ton) aus Ereignissen.
- **Server-autoritativ:** Client sendet nur Eingaben; keine Positions-Vertrauensübergabe.

### 10.3 Skalierung (ehrlich)
- Eine World-Instanz trägt realistisch **~30–60 Spieler + NPCs**, wenn Kollision räumlich indexiert ist und
  Snapshots gefiltert werden. Messen mit Lasttest (§13).
- Mehr Spieler → Welt in **Regions-Prozesse** teilen (Übergabe an Regionsgrenzen). Aufwändig; nur bei Bedarf.
- **Eine Welt je Raum/Crew** (Seed pro Welt) ist die einfachste Betriebsform; eine globale Welt später.

### 10.4 Persistenz und Konten
- Konto = **anonymes Token** im Browser (langlebiges Cookie) + Anzeigename + Avatar; optional später
  Registrierung (E-Mail/Passwort oder OAuth).
- Gespeichert: Name, Avatar, Gold (getragen/eingelagert), Upgrade-Stufen, Statistik (Abschüsse, Tode).
- Welt selbst ist zustandslos (Seed), Loot/NPCs sind flüchtig.
- Docker-Volume für DB; tägliche Sicherung per Skript.

### 10.5 Deployment
Ein Container (multi-stage Release), ein Port, Reverse-Proxy macht TLS (WebSocket-Upgrade durchreichen!).
Healthcheck `/health`. Volume für die Datenbank. Konfiguration per Umgebungsvariablen
(`PHX_HOST`, Schema, `SECRET_KEY_BASE`, DB-Pfad).

---

## 11. Protokoll (Skizze)
**Client → Server:** `input {u,l,r}` (bei Änderung), `fire {side}`, `use`, `dock`, `buy {kategorie}`,
`undock`.
**Server → Client:**
- `welcome {you, seed, world_params}`
- `chunk {cx, cy, tiles}` (bei Bedarf)
- `snap {t, ships[], balls[], mines[], loot[], pickups[], npcs[], wind, events[]}` (AOI-gefiltert)
- `shop {angebote, gold}` beim Andocken; `gold {getragen, eingelagert}`
- `death {killer, verlorenes_gold}`, `respawn {pos}`
Zahlen auf 2 Nachkommastellen runden, Ereignisse als kurze Arrays; später binär (MessagePack/eigenes Format).

---

## 12. Grafik und Audio
- **Grafik:** Kenney "Pirate Pack" (CC0): Schiffe (6 Farben × 3 Schadenszustände), Inseln/Felsen/Palmen,
  Explosionen, Feuer, Kanonenkugeln. Eigene **Avatare im 16-Bit-Pixelstil** (6 Porträts, selbst gezeichnet, per
  Skript erzeugt) – Stil: C64/EGA-Palette, Dithering, 32×32.
- **Darstellung:** Pixel-scharf (`image-rendering: pixelated`), UI dunkel (Slate), Akzent Gold/Amber.
- **Ton:** WebAudio-Synth (Kanonendonner, Treffer, Versenken, Einsammeln); später echte Samples (CC0),
  Musik optional. Stummschaltung (M), Einstellung merken.
- **Effekte:** Kielwasser, Splash, Rauch bei niedriger HP, Explosionsring, Schadenszahlen, Wind-Kompass.

---

## 13. Tests und Qualität
- **Reine Simulation** ohne I/O → leicht testbar (ExUnit/Property-Tests): Physik, Wind, Trefferlogik,
  Q/E-Seitenzuordnung, Nachladen, Tod/Respawn, Gold-Verteilung.
- **Generator-Tests:** gleicher Seed → gleiche Chunks; Hafen/Spawn befahrbar; Landanteil in Spanne.
- **AOI-/Spatial-Hash-Tests:** nur nahe Entities im Snapshot.
- **Lasttest-Skript:** 30–50 simulierte Schiffe/NPCs, Tickzeit messen (**Ziel < 10 ms bei 20 Hz**).
- **Browser-Smoketest:** Tasten halten (W), tippen (A/D), Q/E, Seitenwechsel, Reconnect.
- `mix precommit` (Format, Warnungen als Fehler, Tests) als Pflicht vor jedem Commit.

---

## 14. Meilensteine (jede Stufe spielbar)
1. **M1 – Segeln in der Welt:** Chunk-Generator, Kamera, Wind, Physik, Spawn nahe anderer Spieler, Minimap.
   *Test: "Herumschippern macht Spaß?"*
2. **M2 – Kampf:** Breitseiten, Treffer, Tod/Respawn, NPC-Händler als Ziel (Powerups ausprobiert und verworfen).
3. **M3 – Leben in der Welt:** NPC-Director, Piratenjäger/Banden, Loot-Drops, Gold im HUD.
4. **M4 – Häfen + Shop:** Hafen-Generierung, Andocken, Upgrades (nur Sitzung), Schutzzonen.
5. **M5 – Performance:** Spatial Hash, AOI-Snapshots, Lasttest, Binärprotokoll falls nötig.
6. **M6 – Persistenz:** Konten-Token, SQLite, Gold/Upgrades speichern, Rangliste, Reconnect-Schutz.
7. **M7 – Ausbau:** Biome, Schiffsklassen, Bosse, Crews/Teams, Events (Sturm), Handelsrouten, Quests.

---

## 15. Risiken und Gegenmaßnahmen
| Risiko | Gegenmaßnahme |
|---|---|
| Welt wirkt leer | NPCs und Loot als Kernfeature (M3), Spawn nahe Spielern |
| Zu schnelles/zu zähes Spielgefühl | Geschwindigkeits-Konstanten zentral, früh mit Freunden testen |
| Performance bei vielen Schiffen | Spatial Hash + AOI vor dem Feature-Ausbau (M5 früh planen) |
| Economy-Inflation / Bot-Farming | wenige Stufen, Gold-Verlust beim Tod, NPC-Respawn-Limits, Einlagern |
| Frust durch Camping/Spawnkill | Schutzzonen, Spawn-Schonzeit, Spawn-Abstand |
| Datenverlust | Volume + Backup, Migrationen mit Ecto |
| Cheating | Server-autoritativ, Eingaben validieren, Ratenbegrenzung |
| Scope-Explosion | strikt nach Meilensteinen; jede Stufe vor der nächsten spielen |

---

## 16. Offene Entscheidungen (Empfehlung)
- **Welt-Modell:** eine Welt je Raum (Empfehlung) vs. eine globale Welt.
- **Konten:** anonymes Token zuerst (Empfehlung), echte Registrierung später.
- **Tod-Strafe:** Teilverlust des Golds (Empfehlung) vs. Totalverlust vs. keine Strafe.
- **PvP:** immer an außer in Häfen (Empfehlung) vs. Opt-in-Zonen.
- **Client-Tech:** Canvas 2D (einfach) vs. PixiJS (Partikel/Kamera/Performance, Empfehlung bei vielen Entities).
- **Sprache der UI:** Deutsch (bisher) – Texte zentral halten, damit später übersetzbar.

---

## 17. Lehren aus dem Prototyp "Pirate Battle"
Aus dem laufenden Projekt (Elixir/Phoenix LiveView, Karten- und Arcade-Modus):
1. **Echtzeit-Eingabe:** Tastenzustand senden, nicht per `click()` auslösen (LiveReload fängt Klicks ab,
   solange bestimmte Tasten gehalten werden); `pushEvent` direkt, `preventDefault` bei Leertaste, `e.repeat`
   ignorieren, bei `blur` alles loslassen.
2. **Orientierung testen:** Sprite-Bug-Richtung und Links/Rechts-Seiten (y nach unten!) früh visuell prüfen.
3. **Reine Simulation + dünne Hülle:** Spiellogik als pure Funktionen (`tick/2`) lieferte schnelle, stabile
   Tests (~140 Tests); Prozess/LiveView nur Transport.
4. **Schnappschuss-Protokoll funktioniert:** 25 ms Tick, 50 ms Snapshot, Client interpoliert um ~90 ms.
5. **Pacing mit Spielern testen:** Tempo, Nachladezeit und Wind wurden nach Spielgefühl mehrfach korrigiert
   ("kein Racer") – Konstanten gesammelt an einer Stelle halten.
6. **Wind als Mechanik** gefiel: Kompass im HUD mit Prozent-Bonus ist verständlich.
7. **Bots sind essentiell** (Test, Mitspieler, später NPCs). Einfache Strategie "Gegner querab halten" reicht.
8. **Grafik:** Kenney-Schiffe + Pixel-Avatare wirken stimmig; Avatare selbst per Skript (Pillow) gezeichnet,
   Hintergrund mit ausreichend Kontrast zur Figur wählen.
9. **Betrieb:** Single-Container-Deployment hinter eigenem Reverse-Proxy, WebSocket-Upgrade muss
   durchgereicht werden; Health-Endpoint; Release-Build per Multi-Stage-Dockerfile.
10. **Chat-Eingabefelder** in LiveView werden nach dem Senden nicht automatisch geleert, wenn sich der
    Assign nicht ändert – bei Neubau mit Client-Framework kein Thema, sonst per Hook leeren.

---

## 18. Auftragsvorlage für den Neubau (kopierbar)
> Baue "Open Sea Pirates (OSP)": ein Browser-Echtzeitspiel mit einer unendlichen prozeduralen Piratenwelt (Chunks aus
> Seed, Inseln/Riffe/Häfen), Steuerung W/A/D, Q/E Breitseiten, Wind-Mechanik
> (Rückenwind +40 %, Gegenwind −40 %). Server-autoritativ in Elixir (World-Prozess mit 20 Hz, Spatial Hash,
> AOI-Snapshots), Client Canvas/PixiJS mit Kamera, Minimap und Interpolation. NPC-Schiffe (Händler,
> Piratenjäger), Gold-Drops, Häfen mit Shop und Upgrades (Rumpf, Kanonen, Segel), Schutzzonen. Spawn
> 1–2 Bildschirme vom nächsten Spieler. Persistenz (Konten per Token, Gold, Upgrades) mit SQLite in einem
> Docker-Volume. Gehe nach den Meilensteinen M1–M7 vor, jede Stufe lauffähig, mit Tests für die reine
> Simulation und Lasttest vor M5.

Ende des Handouts.
