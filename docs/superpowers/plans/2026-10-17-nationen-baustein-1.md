# Nationen und Gebiete (Baustein 1) – Bauplan

> **Für ausführende Agenten:** Benötigter Sub-Skill: `superpowers:subagent-driven-development` (empfohlen) oder `superpowers:executing-plans`. Schritte nutzen Checkboxen (`- [ ]`).

**Ziel:** Fünf Nationen mit Gebieten, Flaggen, Nationswahl beim ersten Beitritt, kleinen Startboni und Spawn im Heimatgebiet; sonst bleibt der Spielverlauf unverändert.

**Architektur:** Neues reines Modul `Osp.Nations` (Gebiet aus Seed und Häfen, Boni). Die Heimatnation steht im Profil und im Schiff (`ship.nation`); `Osp.Ships.stats/1` rechnet den Bonus ein, `Osp.State` nutzt sie beim Spawn. Schnappschüsse tragen Nationen als Strings, der Client zeigt Flaggen, Wahlbildschirm und Gebietsmeldung.

**Tech-Stack:** Elixir (Plug, Bandit, WebSock), reine Module mit ExUnit; Client in reinen ES-Modulen ohne Build; Python/Pillow für die Flaggenbilder.

**Spec:** `docs/superpowers/specs/2026-10-17-nationen-ruf-quests-design.md` (Baustein 1 und die Festlegungen in Abschnitt 9). Ruf, Quests und Eroberung sind **nicht** Teil dieses Plans.

## Globale Vorgaben

- Elixir läuft nur auf dem Server: immer `./mx test` bzw. `./mx precommit` (Warnungen = Fehler, Format, Tests); Ausgangsstand: 118 Tests grün.
- Spiellogik als reine Module mit Tests; `Osp.World` und `Osp.Web.Socket` bleiben Hülle. Konstanten oben in den Modulen.
- Welt deterministisch aus dem Seed; Häfen höchstens einer je Chunk (16×16 WE).
- Spielstände: `Osp.Profile.decode/1` prüft jeden Wert gegen feste Listen; Format-Version `@version` wird erhöht, alte Profile werden ohne Verlust gelesen.
- Neue Client-Nachrichten und Werte nur über feste Whitelists (wie `@classes`, `@ammo` am Socket); Namen im Client nur per `textContent`.
- Clients bekommen **nie** das Spieler-Token, nur `Osp.State.public_id/1`.
- Bestehende Tests rufen `World.join(w, "p1", "Anna")` und `State.join/3` ohne Nation auf; sie müssen unverändert weiterlaufen.
- UI und Kommentare Deutsch, Code-Bezeichner Englisch. Doku (`README.md`, `CLAUDE.md`, `docs/decisions.md`) wird mitgepflegt.
- Nationen: Spanien, England, Frankreich, Niederlande, Portugal (Atome `:spain, :england, :france, :netherlands, :portugal`, in dieser Reihenfolge).
- Gebiets-Zellen etwa 150×150 WE, Suchradius für „nächster Hafen" 120 WE.
- Startboni: Spanien Rumpf +2 HP · England Kanonenschaden +8 % · Frankreich Wendigkeit +6 % · Niederlande Reparatur 25 % günstiger · Portugal Tempo +5 %.

## Review-Fokus

Eingaben und Zustände, die der Entwurf andeutet, aber keine Aufgabe von selbst prüft, am wahrscheinlichsten zuerst:

1. **Altes Profil ohne Nation** wird geladen, ohne Verlust von Gold, Klasse, Upgrades (Task 2, Task 3).
2. **Ungültige Nation vom Client** („xyz", Zahl, Liste) wird abgelehnt und löst nie einen Absturz aus (Task 3).
3. **Bestehendes Profil mit Nation:** Eine mitgeschickte andere Nation ändert sie nicht (Task 3).
4. **Nation ohne Hafen in Reichweite:** Der Spawn fällt auf das bisherige Verhalten zurück statt zu hängen oder abzustürzen (Task 3).
5. **Rechenaufwand:** Die Gebietsabfrage läuft nicht je Tick und Schiff, sondern höchstens alle 500 ms je Spieler; der Lasttest bleibt im Budget (Task 4).

---

## Dateiübersicht

- Neu `lib/osp/nations.ex`: Nationsdaten, Gebiete, Boni.
- Ändern `lib/osp/ships.ex` (`stats/1` mit Bonus), `lib/osp/shop.ex` (Reparaturpreis), `lib/osp/profile.ex` (Feld `"nation"`).
- Ändern `lib/osp/state.ex` (Schiffsfeld `nation`, Spawn, NPC-Nation, Gebietsnation, Schnappschuss), `lib/osp/world.ex` (`join/5`), `lib/osp/web/socket.ex` (Join-Nachricht, Fehler `nation_required`).
- Neu `scripts/nation_flags.py` → `priv/static/images/flags/<nation>.png`.
- Ändern `priv/static/index.html`, `css/osp.css`, `js/main.js`, `js/net.js`, `js/render.js`, `js/minimap.js`.
- Tests: neu `test/osp/nations_test.exs`; erweitert `harbor_test.exs`/`persistence_test.exs`/`web_test.exs`/`world_test.exs`.

---

### Task 1: `Osp.Nations` (reines Modul)

**Dateien:**
- Neu: `lib/osp/nations.ex`
- Test: `test/osp/nations_test.exs`

**Schnittstellen:**
- Erzeugt: `all() :: [atom()]`; `info(atom()) :: %{name: String.t(), adjective: String.t(), color: String.t(), bonus_text: String.t()}`; `parse(term()) :: {:ok, atom()} | :error` (nur die fünf Strings `"spain"` … `"portugal"`); `cell_nation(seed, x, y) :: atom()`; `of_port(seed, port_map) :: atom()`; `at(seed, x, y) :: atom()`; `nearest_port_of(seed, nation, {x, y}, max_radius) :: map() | nil`; `bonus(atom() | nil) :: %{hp: 0 | 2, dmg: float(), turn: float(), speed: float(), repair: float()}` (Standard für `nil`: 0, 1.0, 1.0, 1.0, 1.0).
- Verbraucht: `Osp.Ports.near/4`, `Osp.Ports.in_chunk/3`, `Osp.Terrain.chunk_of/2`, `Osp.Terrain.chunk_size/0`.

- [ ] **Schritt 1: Failing Tests schreiben** in `test/osp/nations_test.exs` (Seed `4`):
  - `all/0` hat die fünf Atome in der Reihenfolge der Vorgaben; `info/1` liefert für jede Nation nicht-leere Strings und `color` als `"#rrggbb"`.
  - `parse("spain") == {:ok, :spain}`; `parse("xyz")`, `parse(5)`, `parse(nil)`, `parse(["spain"]) == :error`.
  - `cell_nation/3` ist deterministisch, gleich für alle Punkte derselben 150-WE-Zelle (z. B. `(10,10)` und `(140,140)`) und unterscheidet sich über ein Raster von 40×40 Zellen so, dass **alle fünf** Nationen vorkommen.
  - `of_port/2` eines Hafens (gefunden mit `Ports.near(4, 0, 0, 200)`) ist gleich `cell_nation/3` seiner Position.
  - `at/3` direkt am Ankerplatz eines Hafens (Abstand 0,5) liefert `of_port/2`; ein Punkt mit weit und breit keinem Hafen im Radius liefert `cell_nation/3` (Beleg: gefundener Punkt mit `Ports.near(4, x, y, 120) == []`, z. B. durch Suche auf einem groben Raster).
  - `nearest_port_of/4` findet für **jede** Nation einen Hafen innerhalb 1500 WE um den Ursprung, dessen `of_port/2` genau diese Nation ist; mit Radius `1.0` und ohne Hafen nahe dem Ursprung gibt es `nil`.
  - `bonus/1`: `bonus(:spain).hp == 2`, `bonus(:england).dmg == 1.08`, `bonus(:france).turn == 1.06`, `bonus(:portugal).speed == 1.05`, `bonus(:netherlands).repair == 0.75`, `bonus(nil)` = Standardwerte; alle anderen Felder jeder Nation sind neutral.

- [ ] **Schritt 2: Tests ausführen, Fehlschlag prüfen** — `./mx test test/osp/nations_test.exs`. Erwartung: Compilerfehler, `Osp.Nations` fehlt.

- [ ] **Schritt 3: Modul in `lib/osp/nations.ex` schreiben** mit den Signaturen oben. Entscheidungen: Zellnation = `:erlang.phash2({:nation, seed, floor(x / 150), floor(y / 150)}, 5)` als Index in `all/0`. `at/3` sucht mit `Ports.near/4` in den Radien 30, 60, 120 und nimmt den nächsten Hafen; ohne Treffer gilt `cell_nation/3`. `nearest_port_of/4` läuft Chunk-Ringe um den Startchunk nach außen (Ring 0, 1, 2, …) und gibt den Hafen mit kleinstem Abstand im ersten Ring mit passendem Treffer zurück, bis `max_radius` überschritten ist. Moduldoc auf Deutsch mit Verweis auf das Spec.

- [ ] **Schritt 4: Tests ausführen** — `./mx test test/osp/nations_test.exs`. Erwartung: alle grün. Schlägt „alle fünf Nationen im Raster" fehl, Zellformel prüfen, nicht den Test aufweichen.

- [ ] **Schritt 5: Commit** — `git add lib/osp/nations.ex test/osp/nations_test.exs && git commit -m "feat: Osp.Nations (Gebiete, Boni)"`.

---

### Task 2: Profil, Schiffswerte, Reparatur

**Dateien:**
- Ändern: `lib/osp/profile.ex`, `lib/osp/ships.ex:stats/1`, `lib/osp/shop.ex:repair/1,repair_cost/1`, `lib/osp/state.ex:new_ship/6` (Feld `nation: nil`)
- Test: `test/osp/persistence_test.exs`, `test/osp/harbor_test.exs`

**Schnittstellen:**
- Verbraucht: `Osp.Nations.parse/1`, `Osp.Nations.bonus/1`.
- Erzeugt: Profil-Schlüssel `"nation"` (`String.t() | nil`, nur `"spain"` … `"portugal"`, sonst `nil`); Schiffsfeld `nation :: atom() | nil`; `Osp.Ships.stats/1` liest `Map.get(ship, :nation)` und liefert `max_hp` (+`hp`-Bonus), `dmg_mult` (·`dmg`), `speed_mult` (·`speed`), `turn_mult` (·`turn`); `Osp.Shop.repair_price_per_hp(ship) :: number()` (4 · `repair`-Bonus, gerundet auf ganze Gold, mindestens 1).

- [ ] **Schritt 1: Failing Tests schreiben:**
  - `persistence_test.exs`: `Profile.decode(%{"nation" => "france"})["nation"] == "france"`; ungültig (`"xyz"`, `7`, `nil`, fehlend) ergibt `nil`; `Profile.new()["nation"] == nil`; **altes Profil** (Stand `"v" => 1`, ohne `"nation"`, mit Gold 123, Klasse `"klipper"`) bleibt nach `decode/1` verlustfrei und liefert `nation == nil`; `from_ship(ship)` mit `nation: :spain` ergibt `"nation" => "spain"`, mit `nation: nil` ergibt `nil`; Rundlauf `from_ship |> apply` erhält die Nation.
  - `harbor_test.exs`: `Ships.stats(%{class: :schaluppe, upgrades: …, nation: :spain}).max_hp == 14` (12 + 2), `:england` → `dmg_mult` 1,08, `:france` → `turn_mult` = 1,06, `:portugal` → `speed_mult` = 1,05, `nation: nil` unverändert (Test existiert, muss grün bleiben); Reparatur: Niederländer zahlt 3 Gold pro HP statt 4 (`Shop.repair_price_per_hp(%{nation: :netherlands}) == 3`), sonst 4, `Shop.repair_cost/1` und `Shop.repair/1` benutzen denselben Preis (Test: Spieler mit 100 Gold und 4 fehlenden HP zahlt 12).
  - Profil-Anwendung: `Profile.apply(ship, profile_mit_nation_spain)` setzt `ship.nation == :spain` und `max_hp` mit Bonus.

- [ ] **Schritt 2: Tests ausführen, Fehlschlag prüfen** — `./mx test test/osp/persistence_test.exs test/osp/harbor_test.exs`.

- [ ] **Schritt 3: Implementieren:** In `Profile`: `@version 2`, Feld in `new/0`, `from_ship/1`, `decode/1` (über `Nations.parse/1`, Ergebnis wieder als String oder `nil`) und `apply/2` (setzt `ship.nation`, danach `Ships.stats/1` wie bisher). `Ships.stats/1` multipliziert mit `Nations.bonus(Map.get(ship, :nation))`. `Shop.repair/1` und `repair_cost/1` verwenden `repair_price_per_hp/1`; `Shop.view/2` und die Anzeige verwenden denselben Preis (das alte `repair_price_per_hp/0` entfällt oder wird zu dieser Funktion, alle Aufrufer anpassen).

- [ ] **Schritt 4: Tests ausführen** — `./mx test`. Erwartung: alle bestehenden Tests grün plus die neuen.

- [ ] **Schritt 5: Commit** — `git commit -am "feat: Heimatnation im Profil, Boni in Schiffswerten und Reparatur"`.

---

### Task 3: Beitritt mit Nationswahl und Spawn im Heimatgebiet

**Dateien:**
- Ändern: `lib/osp/state.ex` (`join/4`, `pick_spawn`, `respawn_point/2`), `lib/osp/world.ex` (`join/5`, `do_join/4`), `lib/osp/web/socket.ex`
- Test: `test/osp/world_test.exs`, `test/osp/web_test.exs`, `test/osp/nations_test.exs`

**Schnittstellen:**
- Verbraucht: `Nations.parse/1`, `Nations.nearest_port_of/4`, `Nations.info/1`, `Nations.all/0`, `Profile.decode/1`, `Spawn.pick_around/6`.
- Erzeugt: `World.join(world, id, name, pid \\ self(), opts \\ [])` mit `opts[:nation] :: atom() | nil`; Antwort `{:ok, info}` unverändert. Join-Nachricht `{"t":"join","token":…,"name":…,"nation":"spain"}` (Feld optional). Fehlerantwort `{"t":"error","reason":"nation_required","nations":[{"id":"spain","name":"Spanien","color":"#…","bonus":"Rumpf +2 HP"},…]}` (Verbindung bleibt offen, `state.id` bleibt `nil`).

- [ ] **Schritt 1: Failing Tests schreiben:**
  - `web_test.exs`: Join mit **neuem** Token ohne Nation ergibt `{:push, {:text, json}, state}` mit `reason == "nation_required"`, fünf Einträgen in `nations` und `state.id == nil`; derselbe `state` kann danach mit `"nation" => "england"` beitreten und bekommt `welcome`; Join mit ungültiger Nation (`"xyz"`, `7`, `["spain"]`, `%{}`) ergibt weiterhin `nation_required`, nie einen Absturz; Join mit **bestehendem Profil mit Nation** (`Profiles.put` vorher) ignoriert eine andere mitgeschickte Nation (das Schiff trägt die gespeicherte).
  - `world_test.exs`: `World.join(w, "p1", "Anna", self(), nation: :spain)` → `World.state(w).ships["p1"].nation == :spain`; ohne `nation:` und ohne Profil bekommt das Schiff **trotzdem** eine gültige Nation aus dem Token-Hash (bestehende Tests bleiben so unverändert); Beitritt mit altem Profil ohne Nation und ohne Wunsch behält Gold und Klasse und bekommt eine Hash-Nation; Wiederverbinden (Schiff existiert) ändert die Nation nicht.
  - Spawn (in `world_test.exs` oder `nations_test.exs` über `State`): Neues Schiff mit Nation `:england` auf Welt-Seed 4 steht nach `State.join/4` höchstens 25 WE von einem Hafen entfernt, dessen `Nations.of_port/2` `:england` ist (und über 3,5 WE, also außerhalb der Schutzzone); Wiederauftauchen nach dem Tod (`State.respawn_point/2`) ebenso. Nation ohne Hafen im Suchradius: `State.spawn_for(state, :england, {0.0, 0.0}, rng, max_radius: 1.0)` (kein Hafen in 1 WE) fällt auf `Spawn.pick/4` zurück und liefert gültiges offenes Wasser (`Spawn.clear?/3`); `spawn_for(state, nil, …)` verhält sich wie bisher.

- [ ] **Schritt 2: Tests ausführen, Fehlschlag prüfen** — `./mx test test/osp/web_test.exs test/osp/world_test.exs`.

- [ ] **Schritt 3: Implementieren:**
  - `State.join/4`: Nation aus `profile["nation"]` via `Nations.parse/1` an `pick_spawn/2` und (über `Profile.apply/2`) ans Schiff. Neue Funktion `State.spawn_for(state, nation | nil, reference :: {x, y}, rng, opts \ []) :: {x, y, heading, rng}` (`opts[:max_radius]`, Standard 1500): bei Nation zuerst `Nations.nearest_port_of(seed, nation, reference, max_radius)` (Referenz: Ursprung beim ersten Beitritt, Todesort beim Wiederauftauchen), dann `Spawn.pick_around(seed, others, {port.x, port.y}, 6.0, 18.0, rng)`; bei `nil` oder ohne Treffer das bisherige `Spawn.pick/4`. Die bestehende Jäger-Meidung (bis zu 8 Versuche) bleibt.
  - `World.do_join/5`: Profil laden (`Profiles.get(id)`); ist `profile["nation"]` leer, `opts[:nation]` oder sonst eine Nation aus `:erlang.phash2({:nation, id}, 5)` setzen; hat das Profil bereits eine Nation, bleibt sie.
  - `Socket`: neues Join-Feld über `Nations.parse/1`; **nur am Socket** (nicht in `World`) gilt: Fehlt dem Profil (`Profiles.get(token)`) die Nation und ist keine gültige mitgeschickt, kommt `nation_required` und es wird nicht beigetreten. Die Liste `nations` kommt aus `Nations.all/0` und `Nations.info/1`.

- [ ] **Schritt 4: Tests ausführen** — `./mx test`. Erwartung: alle grün (Ausgangs-Tests unverändert).

- [ ] **Schritt 5: Commit** — `git commit -am "feat: Nationswahl beim Beitritt, Spawn im Heimatgebiet"`.

---

### Task 4: Nationen in Schnappschüssen und bei NPCs

**Dateien:**
- Ändern: `lib/osp/state.ex` (`add_npc/7`, `step/2`, `ship_entry/2`, `snapshot_for/3`, Hafenliste)
- Test: `test/osp/nations_test.exs` oder neu `test/osp/territory_snapshot_test.exs`, `test/osp/radar_test.exs` (Token-Test bleibt)

**Schnittstellen:**
- Verbraucht: `Nations.at/3`, `Nations.of_port/2`.
- Erzeugt: Schiffsfeld `terr :: atom()` (Nation des Gebiets unter dem Spieler, alle 500 ms neu); Ship-Eintrag im Schnappschuss `na :: String.t()` (Spieler: Heimatnation, NPC: Nation des Gebiets bei der Erzeugung, ohne Nation `""`); Hafen-Eintrag `[id, x, y, name, land, nation_string]`; `me.tn :: String.t()` (Gebietsnation).

- [ ] **Schritt 1: Failing Tests schreiben:**
  - `add_npc/7` im Gebiet von `:france` (Position an einem französischen Hafen) trägt `nation == :france`.
  - Snapshot: `ship_entry` enthält `na` (z. B. `"spain"` für ein Spielerschiff mit Nation `:spain`, `""` ohne); `snap.ports` hat sechs Elemente je Eintrag, das sechste ist die Nation; `snap.me.tn` stimmt nach einem Takt über 500 ms mit `Nations.at/3` an der Position überein.
  - Die Gebietsnation wird **nicht** jeden Takt berechnet: nach `State.tick(state, 25)` bei `rem(time, 500) != 0` bleibt `terr` gleich, selbst wenn das Schiff verschoben wurde; nach 500 ms ist sie aktualisiert.
  - Das JSON des Schnappschusses enthält weiterhin nie das Token (bestehender Test in `radar_test.exs`, mit Nation im Szenario).

- [ ] **Schritt 2: Tests ausführen, Fehlschlag prüfen** — `./mx test test/osp/radar_test.exs`.

- [ ] **Schritt 3: Implementieren** wie in den Schnittstellen. `terr` wird in `State.step/2` nur bei `rem(state.time, 500) == 0` für lebende Spieler neu gesetzt (ein Abruf von `Nations.at/3` je Spieler und 500 ms). NPCs bekommen ihre Nation bei `add_npc/7` einmal aus `Nations.at/3` an ihrer Startposition.

- [ ] **Schritt 4: Tests und Lasttest** — `./mx test`; danach `./mx run scripts/load_test.exs`. Erwartung: alle Tests grün; der Lasttest bleibt in der Größenordnung von `docs/performance.md` (60 Spieler gedrängt unter 20 ms je Takt); bei deutlich schlechteren Werten Abruf-Häufigkeit oder Suchradien prüfen.

- [ ] **Schritt 5: Commit** — `git commit -am "feat: Nationen in Schnappschuessen, NPCs und Gebietsnation"`.

---

### Task 5: Flaggenbilder

**Dateien:**
- Neu: `scripts/nation_flags.py`, `priv/static/images/flags/{spain,england,france,netherlands,portugal}.png`

**Schnittstellen:**
- Erzeugt: je Nation ein PNG, 16×11 Pixel, im Pixelstil (wie die Piratenporträts selbst gezeichnet, ohne Fremdmaterial; keine Staatsflaggen-Nachbildung nötig: eigene, erkennbare Farbkombinationen; Farben passend zu `Nations.info/1.color`).

- [ ] **Schritt 1: Skript schreiben** (`python scripts/nation_flags.py priv/static/images/flags`), das die fünf Bilder erzeugt: Spanien rot-gelb-rot, England weiß mit rotem Kreuz, Frankreich drei senkrechte Streifen, Niederlande drei waagerechte Streifen, Portugal grün-rot geteilt; nur Pillow.

- [ ] **Schritt 2: Ausführen und Bilder ansehen** — fünf Dateien entstehen, jede 16×11, nicht leer; zusammen vergrößert in einer Probe betrachtet (kein Test nötig).

- [ ] **Schritt 3: Commit** — `git add scripts/nation_flags.py priv/static/images/flags && git commit -m "feat: Flaggenbilder der fuenf Nationen"`.

---

### Task 6: Client – Wahl, Flaggen, Gebietsanzeige

**Dateien:**
- Ändern: `priv/static/index.html`, `priv/static/css/osp.css`, `priv/static/js/net.js`, `priv/static/js/main.js`, `priv/static/js/render.js`, `priv/static/js/minimap.js`
- Test: Browser-Prüfung (kein Testframework im Client)

**Schnittstellen:**
- Verbraucht: Fehlerantwort `nation_required` (Task 3), Felder `na`, Hafen-Nation, `me.tn` (Task 4), Flaggenbilder (Task 5).
- Erzeugt: `Net.connect(name, nation?)` sendet `nation` im Join; ein Wahlbildschirm mit den fünf Nationen aus `msg.nations`.

- [ ] **Schritt 1: Wahlbildschirm:** Antwortet der Server mit `nation_required`, bleibt die Verbindung offen (`net.wanted` bleibt `true`), und ein Overlay zeigt die Nationen (Flagge, Name, Bonustext, aus `msg.nations`, Namen per `textContent`). Klick sendet erneut `join` mit `nation`. Der gewählte Wert wird nicht lokal gespeichert (er liegt im Profil).

- [ ] **Schritt 2: Flaggen:** `render.js` lädt `/images/flags/<nation>.png` lazy (Cache wie bei den Schiffsbildern) und zeichnet sie vor Schiffsnamen (`s.na`), vor Hafennamen (Hafen-Nation) und in der Online-Liste nicht nötig. Fehlt das Bild oder ist `na` leer, wird nichts gezeichnet.

- [ ] **Schritt 3: Gebietsanzeige:** Unter dem Windkompass steht „Gewässer: <Name>" (Nation aus `me.tn`, Namen aus einer kleinen Tabelle im Client, die die Server-Antwort `nations` übernimmt oder fest in `main.js` steht – feste Tabelle genügt). Wechselt `me.tn`, erscheint 4 s lang eine Meldung „Du betrittst <adjective> Gewässer". Die Minikarte färbt Hafenmarker nach Nation; **Flächen-Tönung entfällt** (Abweichung vom Spec-Entwurf mit Begründung: Flächen kennt der Client nicht, nur Häfen; wird im Spieltest bewertet).

- [ ] **Schritt 4: Browser-Prüfung** — Dev-Server mit `./mx serve`; mit neuem Token (localStorage leeren) beitreten: Wahlbildschirm erscheint, Wahl führt zum Spiel, Flagge vor dem Namen, Gebietsmeldung beim Segeln über eine Grenze; Wiederbeitritt desselben Tokens zeigt **keinen** Wahlbildschirm. Zusätzlich eine Konsole ohne Fehler. `./mx stop`.

- [ ] **Schritt 5: Commit** — `git commit -am "feat: Nationswahl, Flaggen und Gebietsanzeige im Client"`.

---

### Task 7: Doku und Abschluss

**Dateien:**
- Ändern: `docs/decisions.md`, `README.md`, `CLAUDE.md`, `docs/roadmap.md`, `priv/static/index.html` (Hilfetext)

- [ ] **Schritt 1:** Neue Zeilen in `docs/decisions.md` (Gebiete aus Zellen und nächstem Hafen, Boni, Spawn im Heimatgebiet, Wahl nur beim ersten Beitritt, Tönung als Hafenmarker), `README.md` (Funktionsliste, Aufbau mit `lib/osp/nations.ex`, 118 → neue Testzahl), `CLAUDE.md` (Hinweis auf `Osp.Nations`), Roadmap (Nationen erledigt, Ruf als nächster Baustein), Hilfe im Spiel (kurzer Absatz zu Nationen und Heimatgebiet).

- [ ] **Schritt 2:** `./mx precommit` (alle Tests grün, keine Warnungen), danach alles committen und mit Daniel den Deploy abstimmen (`./deploy`, `git push`).

- [ ] **Schritt 3: Commit** — `git commit -am "docs: Nationen (Baustein 1)"`.
