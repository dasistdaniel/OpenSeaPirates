# Eroberung (Baustein 4) – Bauplan

> **Für ausführende Agenten:** Benötigter Sub-Skill: `superpowers:subagent-driven-development` (empfohlen) oder `superpowers:executing-plans`. Schritte nutzen Checkboxen (`- [ ]`).

**Ziel:** Spieler einer Nation können Häfen anderer Nationen erobern. Das Gebiet des Hafens wechselt, bleibt aber nur dauerhaft, wenn der Hafen ausschließlich von Häfen der Eroberer-Nation umgeben ist; sonst fällt er nach 30 Minuten zurück. Es soll sehr schwer und alleine kaum möglich sein.

**Architektur:** Neues Modul `Osp.Territory` (Prozess nach dem Vorbild von `Osp.Profiles`, Datei `territory.json` im Volume) speichert die Abweichungen vom Ausgangszustand (`Hafen-ID → Besitzer, Zeitpunkt`). `Osp.State` hält sie als Wert (`owners`, `captured_at`) und bleibt rein; `Osp.Nations` und alle Aufrufer berücksichtigen sie. Ein neues reines Modul `Osp.Conquest` rechnet Angriff (Fortschritt, Verteidiger, Eroberung) und Rückfall; `Osp.Fort` schießt im Angriff schneller. `Osp.World` lädt beim Start, setzt die Wanduhrzeit und schreibt Änderungen zurück.

**Tech-Stack:** Elixir (reine Module, ExUnit, ein GenServer), Client in ES-Modulen ohne Build.

**Spec:** `docs/superpowers/specs/2026-10-17-nationen-ruf-quests-design.md` (Baustein 4, Abschnitte 4 und 9). Nationen, Ruf und Quests (Bausteine 1–3) sind umgesetzt.

## Globale Vorgaben

- Elixir läuft nur auf dem Server: `./mx test` bzw. `./mx precommit` (Warnungen = Fehler); Ausgangsstand 276 Tests grün.
- Spiellogik in reinen Modulen mit Tests; `Osp.World`, `Osp.Web.Socket` und `Osp.Territory` sind Hülle bzw. Speicher. Konstanten oben im Modul.
- **Wer erobern darf:** nur Spieler, deren **Heimatnation nicht die des Hafens** ist. Heimatspieler und Gäste ohne Angriff werden **nie** vom Fort beschossen (außer Gesuchten wie bisher).
- **Besitz:** Nur Abweichungen vom Ausgangszustand (`Osp.Nations.of_port/2` ohne Eroberung) werden gespeichert, in `territory.json` im Daten-Volume: atomar geschrieben, mit `.bak`, defekte Datei wird beiseite gelegt (`.corrupt`) und die Sicherung geladen; geladene Werte werden gegen feste Listen geprüft (Hafen-ID-Muster, Nationsnamen, begrenzte Zahlen). Ohne Datenverzeichnis (Tests, Entwicklung) bleibt es im Speicher.
- **Angriff (Annahme des Planes, siehe unten):** Ein Angriff auf einen ungeschützten Hafen beginnt, wenn ein Spieler mit fremder Heimatnation innerhalb von **8 WE** um den Anker eine Breitseite abfeuert oder dort einen Verteidiger versenkt; er dauert, solange der Fortschritt über 0 liegt oder die letzte Angriffshandlung weniger als **60 s** zurückliegt.
- **Fort im Angriff:** Es schießt auf **alle** Spieler mit fremder Heimatnation in 8 WE um den Anker (nicht angedockt, nicht tot, nicht unverwundbar), Nachladen **2 000 ms** statt 5 000 ms, Schaden 3, sonst wie in `Osp.Fort` (Vorhalt nur beim ersten Schuss auf einen Spieler). Angreifer sind in der Zone ungeschützt und dürfen feuern.
- **Fortschritt:** 0–100 %; steigt um **1,5 % pro Sekunde und Angreifer** (lebende Spieler mit fremder Heimatnation in 6 WE um den Anker, nicht angedockt), **nur** solange kein Verteidiger lebt (Jäger der Besitzer-Nation innerhalb von 40 WE um den Anker); ohne Angreifer sinkt er um **0,5 % pro Sekunde**.
- **Verteidiger:** je 45 s zwei Jäger der Besitzer-Nation, 10–20 WE um die Angreifer, höchstens 6 gleichzeitig (gezählt wie oben).
- **Eroberung bei 100 %:** Der Hafen wechselt zur Nation, die unter den Angreifern in der Zone die meisten stellt (Gleichstand: die Nation, die zuerst angegriffen hat). Jeder Angreifer in der Zone bekommt **300 Gold** und **Ruf +10** bei seiner Heimatnation. Danach **20 Minuten Schutzzeit** (Wanduhr), in der der Hafen nicht angegriffen werden kann; die Schutzzone gilt dann normal.
- **Rückfall:** Nachbarn eines Hafens sind alle Häfen im Umkreis von **90 WE**. Ein eroberter Hafen bleibt, wenn **alle** Nachbarn der Eroberer-Nation gehören; hat er mindestens einen Nachbarn mit anderer Nation, fällt er nach **30 Minuten** (Wanduhr, auch über Neustarts) an die Ausgangsnation zurück. Prüfung einmal pro Minute; je Durchlauf entscheidet jeder Hafen genau einmal mit dem Stand vom Beginn des Durchlaufs (keine Ketten innerhalb eines Durchlaufs). Ist der neue Besitzer gleich der Ausgangsnation, wird die Abweichung entfernt.
- Wanduhrzeit kommt von außen (`state.wall_ms`, von `Osp.World` je Takt aus `System.os_time(:millisecond)` gesetzt); ein Zurückspringen der Uhr darf nie zu Absturz oder sofortigem Rückfall führen (Zeitdifferenzen werden auf ≥ 0 begrenzt).
- Das Spieler-Token geht nie an Clients (`Osp.State.public_id/1`); Namen im Client nur per `textContent`.
- Doku (`README.md`, `CLAUDE.md`, `docs/decisions.md`, Roadmap) wird mitgepflegt.

**Annahmen des Planes (bewusst vom Bauenden gewählt, im Spiel zu prüfen):** Der Angriff beginnt mit dem ersten Schuss in der Zone (der Entwurf sagt nur „Fort feuert auf feindliche Schiffe"); Belohnung 300 Gold und Ruf +10 je Angreifer; Rückfall-Prüfung sofort, wenn ein stabiler Hafen später instabil wird; Fortschritt und laufende Angriffe werden **nicht** gespeichert (nach einem Neustart beginnt jeder Angriff von vorn).

## Review-Fokus

Eingaben und Zustände, die der Entwurf andeutet, aber keine Aufgabe von selbst prüft, am wahrscheinlichsten zuerst:

1. **Neustart und beschädigte Datei:** gespeicherte Eroberungen kommen zurück; eine defekte, leere oder manipulierte `territory.json` (unbekannte Nation, ungültige Hafen-ID, riesige Zahlen) bricht den Start nie ab (Task 1).
2. **Kein Zwangsangriff auf Unbeteiligte:** Heimatspieler, Gäste ohne Schuss, Spieler im Schutzzeitraum und angedockte Schiffe werden vom Fort nicht beschossen; Quests, Shop und Spawn nutzen den neuen Besitzer (Task 2, Task 3).
3. **Unfaire Eroberung:** Ein Einzelspieler kommt gegen Fort und Verteidiger praktisch nicht durch; Fortschritt steht still, solange ein Verteidiger lebt; mehrere Nationen als Angreifer ergeben genau einen Gewinner (Task 3).
4. **Rückfall:** stabile Binnenlage bleibt, Randlage fällt nach 30 Minuten, Eroberung der Ausgangsnation entfernt die Abweichung, keine Kette im selben Durchlauf, Uhr-Rücksprung ist harmlos (Task 4).
5. **Folgen des Besitzerwechsels:** Gesuchte bei der neuen Besitzer-Nation werden gesperrt (Shop, Fort), bei der alten nicht mehr; Quests des Hafens entstehen mit der neuen Nation; laufende Quests mit alter Nation bleiben abgebbar (Task 2).

---

## Dateiübersicht

- Neu `lib/osp/territory.ex` (Speicher-Prozess), `lib/osp/conquest.ex` (reine Regeln), Tests `test/osp/territory_test.exs`, `test/osp/conquest_test.exs`, `test/osp/conquest_state_test.exs`.
- Ändern `lib/osp/nations.ex` (Überschreibungen), `lib/osp/state.ex` (Felder `owners`, `captured_at`, `wall_ms`, `assaults`; Aufrufer; Schutz; Schnappschuss), `lib/osp/fort.ex`, `lib/osp/quests.ex`, `lib/osp/world.ex`, `lib/osp/application.ex`, `config/runtime.exs` (nur falls der Pfad dort gebraucht wird).
- Client: `priv/static/js/render.js`, `main.js`, `minimap.js` (Besitzerfarbe kommt schon über die Nation im Hafeneintrag), `index.html`.

---

### Task 1: `Osp.Territory` (Speicher) und besitzerbewusste `Osp.Nations`

**Dateien:**
- Neu: `lib/osp/territory.ex`, `test/osp/territory_test.exs`
- Ändern: `lib/osp/nations.ex`, `lib/osp/application.ex`, `test/osp/nations_test.exs`

**Schnittstellen:**
- Erzeugt (`Osp.Territory`, nach `Osp.Profiles`): `start_link(opts)` (`:name`, `:dir`), `all(server \\ __MODULE__) :: %{String.t() => %{owner: atom(), since: integer()}}`, `put(port_id, owner :: atom(), since :: integer(), server \\ __MODULE__) :: :ok` (Cast), `delete(port_id, server \\ __MODULE__) :: :ok` (Cast), `flush(server \\ __MODULE__) :: :ok`; Datei `territory.json` (`{"v":1,"ports":{"port:1,2":{"owner":"france","since":1700000000000}}}`).
- Erzeugt (`Osp.Nations`, abwärtskompatibel durch Standardwert `%{}`): `of_port(seed, port, owners \\ %{}) :: atom()` (Eintrag in `owners` gewinnt, sonst Zellnation), `base_of_port(seed, port) :: atom()` (wie bisher `of_port/2` ohne Eroberung), `at(seed, x, y, owners \\ %{})`, `nearest_port_of(seed, nation, {x, y}, max_radius, owners \\ %{})` (`owners :: %{port_id => atom}`).
- Verbraucht: `Osp.Ports.*`, Datenverzeichnis aus `Application.get_env(:osp, :data_dir)` wie bei `Osp.Profiles`.

- [ ] **Schritt 1: Failing Tests:**
  - `nations_test.exs`: `of_port(seed, port, %{port.id => :spain})` ist `:spain`, ohne Eintrag unverändert `of_port/2`; `base_of_port/2` ignoriert nichts und gleicht `of_port/2` ohne Überschreibung; `at/4` am Anker eines Hafens mit Überschreibung liefert den Besitzer; `nearest_port_of/5` findet für die neue Besitzer-Nation den überschriebenen Hafen und für die alte Nation **nicht mehr** diesen Hafen (der Rückgabewert ist ein anderer Hafen oder `nil`); alle bisherigen Tests laufen unverändert.
  - `territory_test.exs`: `put/3` und `delete/2` wirken (`all/0`, nach `flush/0`); Datei nach `flush` hat die erwartete Form; Neustart mit derselben Datei lädt die Einträge; atomares Schreiben mit `.bak`; **defekte Datei** (kein JSON, leere Datei, falscher Typ) wird nach `.corrupt` verschoben und `.bak` geladen, sonst leer; **manipulierte Einträge** (unbekannte Nation, ungültige Hafen-ID wie `"x"` oder `"port:x,y"`, `since` als Text oder riesige/negative Zahl, Eintrag kein Map) werden verworfen oder begrenzt, gültige bleiben; ohne `:dir` nur im Speicher; `put` mit unbekannter Nation wird abgelehnt (kein Eintrag).
- [ ] **Schritt 2: Ausführen, Fehlschlag prüfen** — `./mx test test/osp/nations_test.exs test/osp/territory_test.exs`.
- [ ] **Schritt 3: Implementieren.** `Osp.Territory` folgt `Osp.Profiles` (Schreibverzögerung 5 s bei Änderung, beim Beenden schreiben; Prüfregeln streng wie `Osp.Quests.from_json/1`). Im `Osp.Application` wird `Osp.Territory` vor den Welten gestartet.
- [ ] **Schritt 4: Ausführen** — `./mx test`. Erwartung: alle grün.
- [ ] **Schritt 5: Commit** — `git add lib test && git commit -m "feat: Osp.Territory (Speicher) und besitzerbewusste Osp.Nations"`.

---

### Task 2: Besitzer im Spielzustand (alle Aufrufer) und Laden in der Welt

**Dateien:**
- Ändern: `lib/osp/state.ex`, `lib/osp/fort.ex`, `lib/osp/quests.ex`, `lib/osp/world.ex`
- Test: neu `test/osp/conquest_state_test.exs` (erster Teil), angepasste Aufrufer-Tests

**Schnittstellen:**
- Verbraucht: `Nations.of_port/3`, `Nations.at/4`, `Nations.nearest_port_of/5`, `Territory.all/1`.
- Erzeugt: `State`-Felder `owners :: %{String.t() => atom()}`, `captured_at :: %{String.t() => integer()}`, `wall_ms :: integer()` (Standard `0`); `State.port_nation(state, port) :: atom()` (`Nations.of_port(state.seed, port, state.owners)`); `State.new(seed, bots, opts)` nimmt `territory: %{port_id => %{owner:, since:}}` (Standard `%{}`); `Osp.Quests.offers/4`, `atonement_offers/4`, `find_offer/6` bekommen als letzten Parameter `owners \\ %{}` und nutzen ihn für die Nation des Hafens und der Lieferziele; `World.init/1` lädt `Territory.all/1` und setzt `wall_ms` je Takt aus `System.os_time(:millisecond)` (vor `State.tick/2`).
- Alle bisherigen `Nations.of_port/2`- und `Nations.at/3`-Aufrufe im Spielcode (Fort, Quests, State: Spawn, Andocken, Schutzzone, Gebiet unter dem Spieler, Hafeneinträge im Schnappschuss, Hinweis der Jagd) nutzen die Besitzer-Variante mit `state.owners`.

- [ ] **Schritt 1: Failing Tests:**
  - `State.new/3` mit `territory: %{port.id => %{owner: :spain, since: 5}}` setzt `owners`/`captured_at`; ohne Option beide leer.
  - Der Hafeneintrag im Schnappschuss, `me.tn` (nach 500 ms), die Nation eines neu erzeugten NPC an diesem Hafen und der Spawn für Spieler der Nation (`spawn_for/5` findet den Hafen für die **neue** Nation, nicht mehr für die alte) folgen dem Besitzer.
  - `State.dock/2` setzt `docked.nation` auf den Besitzer; ein bei der **alten** Nation Gesuchter wird dort nicht mehr gesperrt (Shop offen) und nicht mehr beschossen, ein bei der **neuen** Gesuchter schon (Fort schießt, Shop gesperrt).
  - Quests: Angebote des Hafens tragen die neue Nation als `nation`; eine schon angenommene Quest mit alter Nation bleibt abgebbar und gibt Ruf bei der alten Nation (kein Absturz, keine Änderung der Quest).
  - Ohne Überschreibungen verhält sich alles wie vorher (bestehende Tests unverändert grün).
  - `World`: Welt startet mit einem Territory-Prozess (Test mit eigenem Namen), der einen Eintrag enthält; `World.state/1` zeigt `owners` mit diesem Eintrag; `wall_ms` wächst von Takt zu Takt.
- [ ] **Schritt 2: Ausführen, Fehlschlag prüfen.**
- [ ] **Schritt 3: Implementieren.** `World` bekommt die Option `:territory` (Prozessname, Standard `Osp.Territory`) für Tests.
- [ ] **Schritt 4: Ausführen** — `./mx test`; danach `./mx run scripts/load_test.exs` (60 Spieler im Rahmen von `docs/performance.md`).
- [ ] **Schritt 5: Commit** — `git commit -am "feat: Hafenbesitzer im Spielzustand und in allen Aufrufern"`.

---

### Task 3: Angriff, Verteidiger, Fort im Angriff, Eroberung

**Dateien:**
- Neu: `lib/osp/conquest.ex`, `test/osp/conquest_test.exs`
- Ändern: `lib/osp/state.ex` (Feld `assaults`, `step/2`, `safe_at?/4`, Schuss-Hook), `lib/osp/fort.ex`, `lib/osp/combat.ex` (Angriffshandlung bei Breitseite und Abschuss von Verteidigern)
- Test: `test/osp/conquest_state_test.exs` (zweiter Teil)

**Schnittstellen:**
- Verbraucht: `State.port_nation/2`, `Fort`, `Combat`, `Spawn.pick_around/6`, `State.add_npc/8`, `State.add_rep/4`.
- Erzeugt (`Osp.Conquest`, rein): Konstanten `radius_hit/0 :: 8.0`, `radius_zone/0 :: 6.0`, `radius_defenders/0 :: 40.0`, `gain_per_s/0 :: 1.5`, `drain_per_s/0 :: 0.5`, `wave_ms/0 :: 45_000`, `max_defenders/0 :: 6`, `protection_ms/0 :: 1_200_000`, `reward_gold/0 :: 300`, `reward_rep/0 :: 10`, `cooldown_ms/0 :: 2_000`; `protected?(state, port_id) :: boolean()` (Wanduhr: `wall_ms - captured_at < protection_ms`, nie negativ); `assault_on(state, port_id) :: map() | nil`; `attacker?(state, ship, port) :: boolean()` (Spieler lebt, nicht angedockt, `ship.nation != port_nation`, kein Verbündeter-Sonderfall); `step(state) :: {state, events}` (je 25-ms-Schritt aus `State.step/2` nach `Fort.step/1`); `hostile_act(state, ship_id, x, y) :: state` (markiert Angriffshandlung: nur wenn ein ungeschützter Hafen mit anderer Nation als der Heimatnation des Schiffs im Umkreis `radius_hit/0` liegt); Zustand je Angriff `state.assaults :: %{port_id => %{progress: float, last_act: integer, wave_at: integer, first_nation: atom}}`; Ereignisse `{:assault, port_id, owner_nation, x, y}` (Beginn), `{:captured, port_id, new_owner, old_owner, since_ms, x, y}` (Eroberung), `{:assault_end, port_id, x, y}`.
- Erzeugt (`Osp.Fort`/`State`): Fort-Hostilität = Gesucht **oder** (Angriff läuft und Spieler mit fremder Heimatnation); Nachladen `Conquest.cooldown_ms/0` im Angriff; `State.safe_at?/4`: ein Angreifer eines laufenden Angriffs ist in der Zone dieses Hafens **ungeschützt**.
- Regeln siehe Globale Vorgaben; Verteidiger werden mit `State.add_npc/8` (`:hunter`, Nation = Besitzer) erzeugt; sie zählen als Verteidiger, solange sie leben und im Umkreis von 40 WE um den Anker sind.

- [ ] **Schritt 1: Failing Tests (reine Teile in `conquest_test.exs`, Zusammenspiel in `conquest_state_test.exs`; Seed 4, ein englischer Hafen, Angreifer-Spieler mit Heimat Frankreich):**
  - `protected?/2`: direkt nach einer Eroberung ja, nach 20 Minuten nein, bei `wall_ms` kleiner als `captured_at` (Uhr zurück) weiter ja und ohne Absturz; ohne Eintrag nein.
  - `attacker?/3`: Spieler mit fremder Heimatnation: ja; Heimatnation gleich Besitzer: nein; tot, angedockt: nein; NPC: nein; Spieler ohne Nation: nein (nie Zwangsangriff ohne Heimat).
  - **Angriffsbeginn:** Eine Breitseite von Angreifer innerhalb 8 WE des Ankers startet den Angriff (Ereignis `:assault`, `assaults` hat den Hafen); eine Breitseite des **Heimatspielers**, eines Gesuchten (anderer Weg), außerhalb 8 WE oder im **Schutzzeitraum** startet nichts. Der Besuch ohne Schuss startet nichts (Fort schießt nicht auf Gäste).
  - **Fort im Angriff:** schießt auf alle Spieler fremder Heimatnation in Reichweite (nicht auf Heimatspieler, Angedockte, Tote, Unverwundbare); Nachladen 2 000 ms; **Angreifer in der Zone sind ungeschützt** und dürfen feuern; Heimatspieler bleiben in der Zone geschützt.
  - **Fortschritt:** ein Angreifer ohne Verteidiger: +1,5 %/s (nach 10 s etwa 15 %), zwei Angreifer doppelt; **mit lebendem Verteidiger** im Umkreis 40 WE steht er still; ohne Angreifer sinkt er um 0,5 %/s bis 0; Angriff endet (`:assault_end`), wenn der Fortschritt 0 ist und 60 s keine Angriffshandlung war.
  - **Verteidiger-Wellen:** alle 45 s zwei Jäger der Besitzer-Nation (10–20 WE von den Angreifern), nie mehr als sechs lebende im Umkreis; Jäger anderer Nationen zählen nicht.
  - **Eroberung:** bei 100 % wechselt der Hafen zur Nation mit den meisten Angreifern in der Zone (Test: 2 Franzosen gegen 1 Spanier → Frankreich; Gleichstand → die Nation der ersten Angriffshandlung); `owners` und `captured_at` aktualisiert, Ereignis `:captured`, jeder Angreifer in der Zone **+300 Gold, Ruf +10** bei seiner Heimatnation (genau einmal, keine Belohnung für Angedockte, Tote oder Spieler außerhalb 6 WE), der Angriffszustand ist entfernt, `protected?` ist wahr.
  - **Einzelspieler:** Ein einzelnes Schiff der Klasse Schaluppe (12 HP) mit Vollkugeln, das im Angriff in 8 WE bleibt, ist ohne Gegenwehr-Taktik nach weniger als 30 s Spielzeit tot oder hat den Hafen nicht erobert (Simulation von 120 s: Eroberung findet nicht statt).
  - **Kein Neubesitz von sich selbst:** Hat der Hafen die Ausgangsnation des Siegers, wird die Überschreibung entfernt (nicht auf den Besitzer gleichen Wertes gesetzt).
- [ ] **Schritt 2: Ausführen, Fehlschlag prüfen.**
- [ ] **Schritt 3: Implementieren** `Osp.Conquest` und die Anbindungen; Zufall nur über `state.rng`.
- [ ] **Schritt 4: Ausführen** — `./mx test`; danach `./mx run scripts/load_test.exs`.
- [ ] **Schritt 5: Commit** — `git add lib test && git commit -m "feat: Angriff, Verteidiger und Eroberung von Haefen"`.

---

### Task 4: Rückfall und Speichern in der Welt

**Dateien:**
- Ändern: `lib/osp/conquest.ex`, `lib/osp/state.ex` (`step/2`: Prüfung je Minute), `lib/osp/world.ex`
- Test: `test/osp/conquest_test.exs` (Rückfall), `test/osp/conquest_state_test.exs`, `test/osp/world_test.exs`

**Schnittstellen:**
- Erzeugt (`Osp.Conquest`): `neighbors(seed, port) :: [map()]` (Häfen in 90 WE ohne den Hafen selbst); `stable?(seed, port, owners) :: boolean()` (alle Nachbarn haben denselben Besitzer wie der Hafen); `reversions(seed, owners, captured_at, wall_ms) :: [String.t()]` (Hafen-IDs, die zurückfallen: Eintrag älter als 30 Minuten und nicht `stable?`; Entscheidung aus dem Stand am Anfang, ohne Folgeeffekte im selben Aufruf); `State`-Schritt alle 60 000 ms Wanduhr (`wall_ms`-Takt) wendet `reversions/4` an, entfernt die Einträge und gibt `{:reverted, port_id, nation_back, old_owner, x, y}` zurück.
- Erzeugt (`Osp.World`): nach jedem Takt werden `:captured`-Ereignisse mit `Territory.put/4` und `:reverted`-Ereignisse mit `Territory.delete/2` gespeichert; beim Beenden `Territory.flush/1` (nur wenn nötig).

- [ ] **Schritt 1: Failing Tests:**
  - `neighbors/2` ohne den Hafen selbst, nur bis 90 WE; `stable?/3`: alle Nachbarn gleicher Besitzer → ja; ein Nachbar mit anderem Besitzer → nein; Hafen ohne Nachbarn → ja (nichts, was ihn zurückholt).
  - `reversions/4`: Randlage und 31 Minuten → fällt zurück; 29 Minuten → bleibt; Binnenlage (alle Nachbarn gleich) → bleibt auch nach Stunden; **Kette:** zwei benachbarte eroberte Häfen A (Eroberer X) und B (Eroberer X), B fällt zurück, A hat mit B zusammen einen anderen Nachbarn: im selben Durchlauf entscheidet jeder nur nach dem Anfangsstand; im nächsten Durchlauf berücksichtigt A den neuen Stand; **Uhr zurück** (`wall_ms` kleiner als `captured_at`): kein Rückfall, kein Absturz.
  - State: Nach dem Rückfall ist `owners` ohne den Hafen, Ausgangsnation gilt wieder (`Nations.of_port`), das Ereignis `{:reverted, …}` kommt; Rückfall-Prüfung läuft nur alle 60 s (nicht jeden Schritt).
  - World: Eine Eroberung im laufenden Spiel erscheint nach `Territory.flush/1` in der Datei; ein **Neustart** der Welt mit derselben Datei zeigt den Hafen weiter beim Eroberer (inkl. `captured_at`, sodass Schutzzeit und Rückfall-Uhr weiterlaufen); ein Rückfall löscht den Eintrag aus der Datei.
- [ ] **Schritt 2: Ausführen, Fehlschlag prüfen.**
- [ ] **Schritt 3: Implementieren** (Wanduhr-Takt in `State.step/2` über `wall_ms`, nicht über die Spielzeit).
- [ ] **Schritt 4: Ausführen** — `./mx test`. Erwartung: alle grün.
- [ ] **Schritt 5: Commit** — `git commit -am "feat: Rueckfall der Haefen und Speichern der Eroberungen"`.

---

### Task 5: Schnappschuss, Protokoll und Client

**Dateien:**
- Ändern: `lib/osp/state.ex` (`snapshot_for/3`, `event_entry/1`), `priv/static/js/render.js`, `main.js`, `priv/static/index.html`, `priv/static/css/osp.css`
- Test: `test/osp/conquest_state_test.exs`, Browser-Prüfung

**Schnittstellen:**
- Erzeugt: Hafeneintrag im Schnappschuss `[id, x, y, name, land, nation_string, progress, protected]` (`progress`: `nil` oder 0..100 gerundet, `protected`: Wahrheitswert); Ereignisse `["assault", port_id, nation, x, y]`, `["captured", port_id, new_owner, old_owner, x, y]`, `["reverted", port_id, nation_back, x, y]`, `["assault_end", port_id, x, y]`.
- Verbraucht: `Conquest.assault_on/2`, `Conquest.protected?/2`.

- [ ] **Schritt 1: Failing Tests:** Hafeneintrag mit sieben Elementen; `progress` zeigt den Wert eines laufenden Angriffs (gerundet) und sonst `nil`; `protected` ist wahr nach einer Eroberung; JSON-tauglich, kein Token; die vier Ereignisse gehen als Listen mit Nation als String hinaus (nur im Umkreis des Beobachters wie die anderen); der bestehende Test auf sechs Elemente wird auf acht angepasst.
- [ ] **Schritt 2: Ausführen, Fehlschlag prüfen.**
- [ ] **Schritt 3: Implementieren** (Server). Client: über dem Hafennamen ein Fortschrittsbalken in der Farbe des Angreifers, solange `progress` gesetzt ist, mit dem Text „wird erobert"; ein Schildsymbol bei `protected`; Meldungen per `flash`: „Angriff auf <Hafen>" beim eigenen Schuss, „<Hafen> erobert!" (Eroberer-Nation, bei eigener Nation grün), „<Hafen> fällt an <Nation> zurück", „Angriff abgebrochen"; Ton `kill` bei Eroberung. Hilfetext erklärt Eroberung kurz (Team nötig, Verteidiger, Schutzzeit, Rückfall).
- [ ] **Schritt 4: Browser-Prüfung** mit `./mx serve`: Beitritt, Hafeneintrag und Balken lassen sich ohne Spielzustand nachstellen (`window.osp.snaps.latest.ports[0][6] = 40` im Dev-Aufruf per eingespeistem Schnappschuss wie bei früheren Prüfungen); Meldungen über nachgestellte Ereignisse. Konsole ohne Fehler; danach `./mx stop`.
- [ ] **Schritt 5: Commit** — `git commit -am "feat: Eroberungsanzeige, Meldungen und Schnappschuss"`.

---

### Task 6: Doku und Abschluss

**Dateien:**
- Ändern: `docs/decisions.md`, `README.md`, `CLAUDE.md`, `docs/roadmap.md`, Hilfetext in `priv/static/index.html`

- [ ] **Schritt 1:** Neue Zeilen in `docs/decisions.md` (Besitz als gespeicherte Abweichungen mit `territory.json`, Angriff und Fort, Fortschritt und Verteidiger, Eroberung und Belohnung, Schutzzeit, Rückfallregel mit Wanduhr, Annahmen des Planes), `README.md` (Funktionsliste, neue Module `territory.ex`, `conquest.ex`, Testzahl, Wiederherstellung von `territory.json` zusammen mit `profiles.json`), `CLAUDE.md` (Hinweis auf `Osp.Conquest`, `State.port_nation/2`), Roadmap (Baustein 4 erledigt, Betrieb: `territory.json` ins Backup aufnehmen), `deploy`-Skript und `docs` prüfen: Backup soll **beide** Dateien sichern.
- [ ] **Schritt 2:** `./mx precommit` (alle Tests grün, keine Warnungen), committen; Deploy und Push mit Daniel abstimmen.
- [ ] **Schritt 3: Commit** — `git commit -am "docs: Eroberung (Baustein 4)"`.
