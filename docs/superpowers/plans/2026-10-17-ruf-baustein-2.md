# Ruf und Folgen (Baustein 2) – Bauplan

> **Für ausführende Agenten:** Benötigter Sub-Skill: `superpowers:subagent-driven-development` (empfohlen) oder `superpowers:executing-plans`. Schritte nutzen Checkboxen (`- [ ]`).

**Ziel:** Ruf je Nation, der durch Abschüsse sinkt, Häfen und Jäger verändert: Bei schlechtem Ruf sperrt der Hafen Shop und Bank, die Schutzzone entfällt, ein Fort schießt und zwei Jäger kommen; Jäger greifen erst ab „Misstrauisch" an.

**Architektur:** Neues reines Modul `Osp.Reputation` (Stufen, Änderungen, Rückgang). Der Ruf lebt im Schiff (`ship.rep`) und im Profil (`"rep"`). `Osp.State` wendet Ruf-Änderungen bei Abschüssen an, entscheidet über Jäger-Aggression und Hafen-Zugang; ein neues reines Modul `Osp.Fort` lässt Häfen auf Gesuchte schießen. Der Client zeigt Ruf, die Sperre im Hafen und die Fort-Warnung.

**Tech-Stack:** Elixir (reine Module, ExUnit), Client in ES-Modulen ohne Build.

**Spec:** `docs/superpowers/specs/2026-10-17-nationen-ruf-quests-design.md` (Baustein 2, Abschnitte 4 und 9). Baustein 1 (Nationen) ist umgesetzt. Quests (Baustein 3) und Eroberung (Baustein 4) sind **nicht** Teil dieses Plans.

## Globale Vorgaben

- Elixir läuft nur auf dem Server: `./mx test` bzw. `./mx precommit` (Warnungen = Fehler); Ausgangsstand 151 Tests grün.
- Spiellogik in reinen Modulen mit Tests; `Osp.World` und `Osp.Web.Socket` sind Hülle. Konstanten oben im Modul.
- Ruf nur bei der Nation des versenkten Schiffs, **keine Verfeindungen** zwischen Nationen.
- Stufen: **Gesucht** ≤ −40, **Misstrauisch** −39 bis −10, **Neutral** −9 bis +29, **Freund** ≥ +30. Wertebereich −100 bis +100.
- Start: Heimatnation +20, alle anderen 0. Rückgang zur 0 um 1 je 10 Minuten Spielzeit.
- Rufverlust: Händler versenkt −8, Jäger −5, nur beim Spieler mit dem letzten Treffer. **Selbstverteidigung:** Ein Jäger, der den Spieler in den letzten 15 s beschossen hat oder gerade auf ihn Jagd macht, kostet beim Versenken nichts. Ein Händler, den der Spieler zuerst angegriffen hat, zählt nicht als Notwehr.
- Jäger greifen **erst ab Misstrauisch** an (Ruf −10 oder schlechter bei ihrer Nation). Händler bleiben friedlich, bis sie getroffen werden.
- Bei Gesucht im Hafen: Andocken geht, Shop/Bank/Reparatur gesperrt, nur die Wiedergutmachung wird angeboten; keine Schutzzone für diesen Spieler bei diesem Hafen; Alarm (zwei Jäger der Nation, einmal je Besuch, danach 3 Minuten Pause) und Fort (erster Schuss gezielt und fast sicher, spätere ausweichbar; 3 HP Schaden, Nachladen 5 s, Warnung vor dem ersten Schuss). Angedockte Schiffe werden nicht beschossen.
- Übergangs-Wiedergutmachung (bis Baustein 3): bei Gesucht gegen **300 Gold** (nur getragenes Gold) **+25 Ruf** bei dieser Nation. Das Gesucht-Spiel darf nie dauerhaft aussperren: der Rufrückgang bleibt der zweite Ausweg.
- Das Spieler-Token geht nie an Clients (`Osp.State.public_id/1`); neue Client-Nachrichten nur über feste Whitelists; Namen im Client nur per `textContent`.
- Profil-Format: `@version` in `Osp.Profile` wird erhöht, alte Profile (auch solche mit Nation, aber ohne Ruf) werden verlustfrei gelesen.
- Doku (`README.md`, `CLAUDE.md`, `docs/decisions.md`, Roadmap) wird mitgepflegt.

## Review-Fokus

Eingaben und Zustände, die der Entwurf andeutet, aber keine Aufgabe von selbst prüft, am wahrscheinlichsten zuerst:

1. **Abwärtsspirale:** Ein Gesuchter, der sich gegen angreifende Jäger wehrt, verliert dabei keinen Ruf (Task 3).
2. **Altes Profil mit Nation, aber ohne Ruf** startet mit +20 bei der Heimatnation und 0 sonst, nichts geht verloren (Task 2).
3. **Wiedergutmachung ohne Gold** und **bei nicht gesuchtem Ruf** wird abgelehnt, ohne Abbruch und ohne Gold-Abzug (Task 5).
4. **NPCs im Schutzbereich:** NPC-Schiffe und Spieler anderer Hafen-Nationen werden durch die neue Schutzzonen-Regel nicht verwundbar (Task 5).
5. **Fort und angedockte/tote Schiffe:** Das Fort schießt weder auf angedockte noch auf tote Schiffe oder Spieler außerhalb der Reichweite, und nie auf Spieler ohne Gesucht-Status (Task 6).

---

## Dateiübersicht

- Neu `lib/osp/reputation.ex` (Stufen, Änderungen, Rückgang), `lib/osp/fort.ex` (Fort-Logik, rein).
- Ändern `lib/osp/profile.ex`, `lib/osp/state.ex` (Ruf-Feld, Kill-Folgen, Jäger-Aggression, Schutz je Schiff, Hafen-Sperre, Wiedergutmachung, Fort-/Alarm-Anbindung, Schnappschuss), `lib/osp/combat.ex` (Schutz je Schiff, Ruf bei Abschuss, Fort-Kugeln), `lib/osp/shop.ex` (Hafen-Ansicht bei Sperre), `lib/osp/director.ex` (mehr Jäger um Gesuchte), `lib/osp/web/socket.ex` (`buy` mit `atone`), `lib/osp/world.ex` (Ruf bei neuer Nation).
- Client: `priv/static/js/main.js`, `shop.js`, `render.js`, `priv/static/index.html`, `css/osp.css`.
- Tests: neu `test/osp/reputation_test.exs`, `test/osp/hostile_port_test.exs`, `test/osp/fort_test.exs`, erweitert die Tests, die ihre Erwartungen durch die neuen Regeln ändern (siehe Tasks).

---

### Task 1: `Osp.Reputation` (rein)

**Dateien:**
- Neu: `lib/osp/reputation.ex`
- Test: `test/osp/reputation_test.exs`

**Schnittstellen:**
- Erzeugt: `standing(integer()) :: :wanted | :suspicious | :neutral | :friend`; `get(rep :: %{atom() => integer()}, nation :: atom()) :: integer()` (fehlend = 0); `add(rep, nation, delta :: integer()) :: rep` (begrenzt −100..100); `penalty(kind :: :merchant | :hunter | atom()) :: non_neg_integer()` (8 / 5 / 0); `decay(rep) :: rep` (jeden Wert um 1 zur 0); `start(nation :: atom() | nil) :: rep` (Heimatnation 20, sonst alle 0, Karte mit allen fünf Nationen); `atone_cost/0 :: 300`, `atone_gain/0 :: 25`; `hunts?(integer()) :: boolean()` (Jäger greifen an: `rep <= -10`); `label(standing) :: String.t()` deutsch („Gesucht", „Misstrauisch", „Neutral", „Freund").
- Verbraucht: `Osp.Nations.all/0`.

- [ ] **Schritt 1: Failing Tests** in `test/osp/reputation_test.exs`:
  - `standing/1` an den Grenzen: `-100, -41 → :wanted`? Nein: `-40 → :wanted`, `-41 → :wanted`, `-39 → :suspicious`, `-10 → :suspicious`, `-9 → :neutral`, `0 → :neutral`, `29 → :neutral`, `30 → :friend`, `100 → :friend`.
  - `add/3` begrenzt: `add(rep, :spain, 500)` ergibt 100, `add(rep, :spain, -500)` ergibt −100; `get/2` einer fehlenden Nation ist 0; andere Nationen bleiben unverändert (keine Verfeindung).
  - `penalty(:merchant) == 8`, `penalty(:hunter) == 5`, `penalty(:player) == 0`.
  - `decay/1`: `%{spain: 20, england: -5, france: 0}` → `%{spain: 19, england: -4, france: 0}`; 0 bleibt 0, springt nie über 0.
  - `start(:france)` hat alle fünf Nationen als Schlüssel, `france: 20`, sonst 0; `start(nil)` alles 0.
  - `hunts?(-10) == true`, `hunts?(-9) == false`, `hunts?(20) == false`.

- [ ] **Schritt 2: Ausführen, Fehlschlag prüfen** — `./mx test test/osp/reputation_test.exs`. Erwartung: `Osp.Reputation` fehlt.
- [ ] **Schritt 3: Implementieren** `lib/osp/reputation.ex` mit den Signaturen; Moduldoc deutsch mit Verweis auf das Spec.
- [ ] **Schritt 4: Ausführen** — Erwartung: alle grün.
- [ ] **Schritt 5: Commit** — `git add lib/osp/reputation.ex test/osp/reputation_test.exs && git commit -m "feat: Osp.Reputation (Stufen, Aenderungen, Rueckgang)"`.

---

### Task 2: Ruf im Schiff, Profil, Schnappschuss, Rückgang

**Dateien:**
- Ändern: `lib/osp/profile.ex`, `lib/osp/state.ex` (`new_ship/6`, `snapshot_for/3`, `step/2`), `lib/osp/world.ex` (`with_nation/3`)
- Test: `test/osp/reputation_test.exs` (erweitert) oder neu `test/osp/reputation_state_test.exs`

**Schnittstellen:**
- Verbraucht: `Reputation.start/1`, `Reputation.decay/1`, `Nations.parse/1`.
- Erzeugt: Schiffsfeld `rep :: %{atom() => integer()}` (immer alle fünf Nationen); Profil-Schlüssel `"rep"` (Map `"spain" => int` …, Werte begrenzt auf −100..100); Schnappschuss `me.rp :: [integer()]` in der Reihenfolge von `Nations.all/0`; `State.rep_of(ship, nation) :: integer()`; `State.add_rep(state, id, nation, delta) :: {state, events}` (Ereignis `{:rep, id, nation, delta, new_value, x, y}`; kein Ereignis bei `delta == 0` oder unbekanntem Schiff).

- [ ] **Schritt 1: Failing Tests:**
  - `Profile.decode(%{"rep" => %{"spain" => 500, "xyz" => 9, "france" => "x"}})["rep"]` hat genau die fünf Nationsschlüssel, `spain == 100`, fehlende/ungültige Werte `0`; `Profile.new()["rep"]` alles 0.
  - **Altes Profil** mit `"nation" => "france"` und ohne `"rep"` führt über `Profile.apply/2` zu `ship.rep.france == 20`, alle anderen 0; ein Profil mit ausdrücklichem `"rep"` überschreibt das nicht (`france: -50` bleibt −50). `from_ship/1` und `apply/2` machen den Rundlauf. Das Profil ganz ohne Nation ergibt alles 0.
  - `World.join(w, id, "Anna", self(), nation: :spain)` ohne Profil: `World.state(w).ships[id].rep.spain == 20` (neue Nation setzt den Startruf).
  - `State.add_rep/4`: erhöht/senkt und begrenzt, liefert das Ereignis; `delta 0` oder unbekannte ID ändert nichts und liefert `[]`.
  - Schnappschuss: `snap.me.rp` ist eine Liste von fünf Zahlen in `Nations.all/0`-Reihenfolge; JSON-kodierbar.
  - Rückgang: Nach 10 Minuten Spielzeit (`State.tick` auf `time == 600_000`, direkt über `%{state | time: 599_975}` und einen Tick) ist `rep` jedes Spielers um 1 zur 0 verschoben; davor nicht.

- [ ] **Schritt 2: Ausführen, Fehlschlag prüfen** — `./mx test`.
- [ ] **Schritt 3: Implementieren:** `Profile` (`@version 3`, Feld in `new/0`, `from_ship/1`, `decode/1`, `apply/2`; fehlendes `"rep"` ergibt `Reputation.start(nation)`); `State.new_ship/6` bekommt `rep: Reputation.start(nil)`; `State.step/2` ruft alle 600 000 ms `Reputation.decay/1` für lebende Spieler auf (nach dem Muster von `update_territory/1`); `World.with_nation/3` setzt bei neu gewählter Nation `"rep"` auf `Reputation.start(nation)` (als String-Map).
- [ ] **Schritt 4: Ausführen** — `./mx test`. Erwartung: alle grün.
- [ ] **Schritt 5: Commit** — `git commit -am "feat: Ruf im Schiff, Profil, Schnappschuss und Rueckgang"`.

---

### Task 3: Ruf sinkt bei Abschüssen (mit Selbstverteidigung)

**Dateien:**
- Ändern: `lib/osp/combat.ex` (`kill/2`), `lib/osp/state.ex` (`fight/6`, `think_npcs`, `new_ship/6`)
- Test: `test/osp/reputation_state_test.exs`, `test/osp/combat_test.exs` (falls Erwartungen ändern)

**Schnittstellen:**
- Verbraucht: `State.add_rep/4`, `Reputation.penalty/1`, `Nations` (NPC-Feld `nation`).
- Erzeugt: NPC-Feld `hunting :: {player_id, time_ms} | nil` (nur Jäger; wird in jedem Denkschritt eines kämpfenden Jägers auf `{enemy.id, state.time}` gesetzt); Regel in `Combat.kill/2`: Stirbt ein NPC mit `nation != nil` und ist der Killer ein lebender Spieler (`last_hit_by`), sinkt dessen Ruf bei `npc.nation` um `Reputation.penalty(npc.kind)`, **außer** Selbstverteidigung: `npc.kind == :hunter` und `npc.hunting == {killer, t}` mit `state.time - t <= 15_000`, oder der Jäger hat den Killer in den letzten 15 s getroffen (Feld auf dem Opfer: Treffer-Zeitpunkt `attacked_at :: %{npc_id => time}` am Spielerschiff, gesetzt in `Combat.hurt/6` wenn ein NPC einen Spieler trifft). Ereignis `{:rep, …}` (aus Task 2) kommt mit zurück.

- [ ] **Schritt 1: Failing Tests:**
  - Spieler versenkt einen Händler der Nation `:france`: `rep.france` sinkt um 8; die anderen vier Nationen bleiben gleich (keine Verfeindung); Ereignis `{:rep, killer_id, :france, -8, new, _, _}`.
  - Spieler versenkt einen Jäger, der nicht auf ihn Jagd macht: −5.
  - **Selbstverteidigung:** Ein Jäger, dessen `hunting` auf den Spieler zeigt (frisch gesetzt), wird versenkt: kein Rufverlust, kein Ereignis. Dasselbe, wenn der Jäger den Spieler vor 10 s getroffen hat (`attacked_at`). Vor 20 s getroffen und kein `hunting`: Rufverlust −5.
  - **Händler wehrt sich** nach einem Angriff des Spielers: Versenken kostet −8 (kein Notwehr-Fall).
  - NPC-Tod ohne Spieler als Killer (Riff, Brand ohne Spieler) ändert keinen Ruf; ein NPC ohne Nation (`nil`) kostet nichts.
  - Ruf bleibt im Bereich: Spieler mit `rep.france == -100` verliert nicht weiter.
  - Bestehende Gefechts-/Beute-Tests laufen weiter (die Beute und `kills` ändern sich nicht).

- [ ] **Schritt 2: Ausführen, Fehlschlag prüfen** — `./mx test test/osp/reputation_state_test.exs`.
- [ ] **Schritt 3: Implementieren** wie in den Schnittstellen. `State.fight/6` setzt `hunting` für Jäger (nicht für Händler); wenn ein Jäger keinen Gegner hat, wird `hunting` auf `nil` gesetzt.
- [ ] **Schritt 4: Ausführen** — `./mx test`. Erwartung: alle grün.
- [ ] **Schritt 5: Commit** — `git commit -am "feat: Rufverlust bei Abschuessen, Selbstverteidigung"`.

---

### Task 4: Jäger greifen erst ab „Misstrauisch" an, mehr Jäger um Gesuchte

**Dateien:**
- Ändern: `lib/osp/state.ex` (`nearest_player/3`, Jäger-Zweig in `think_npcs/1`), `lib/osp/director.ex`
- Test: `test/osp/director_test.exs`, `test/osp/combat_test.exs` (Jäger-Tests), neu `test/osp/reputation_state_test.exs`

**Schnittstellen:**
- Verbraucht: `Reputation.hunts?/1`, `Reputation.standing/1`, `State.rep_of/2`.
- Erzeugt: Jäger wählen als Ziel nur lebende Spieler außerhalb der Schonzeit mit `Reputation.hunts?(State.rep_of(player, hunter.nation))`; `Osp.Director.step/1`: Hat ein Spieler Gesucht-Status bei der Nation seines Gebiets (`ship.terr`), will der Director um ihn **zwei** statt einen Jäger.

- [ ] **Schritt 1: Failing Tests:**
  - Jäger der Nation `:england`, Spieler mit `rep.england == 0` in Reichweite: der Jäger greift **nicht** an (kein `:fire`-Ereignis in 15 s, Spieler unverletzt), obwohl er nah ist. Bei `rep.england == -10`: er greift an und feuert. Bei `-9`: nicht. Bei `rep.england == 50` (Freund): nicht.
  - Der Ruf bei einer **anderen** Nation zählt nicht: Spieler mit `rep.france == -80`, Jäger `:england`: kein Angriff.
  - `Director`: Spieler mit `rep.england == -40` und `terr == :england`: Der Director lässt in mehreren Schritten insgesamt zwei Jäger in 60 WE entstehen; bei `-39` bleibt es bei einem (jeweils unter der Obergrenze `@max_humans`).
  - Die bestehenden Jäger-Tests (`Piratenjäger greifen Spieler an und schießen` in `combat_test.exs`) setzen ab jetzt den Ruf des Spielers bei der Jäger-Nation explizit auf `-20`; Ledger-Eintrag, weil sich die Erwartung wegen der neuen Regel ändert.

- [ ] **Schritt 2: Ausführen, Fehlschlag prüfen.**
- [ ] **Schritt 3: Implementieren** (Filter in `nearest_player/3` für Jäger; `nearest_player` für andere Aufrufer bleibt unverändert; Director-Ziel je Spieler 1 oder 2).
- [ ] **Schritt 4: Ausführen** — `./mx test`; danach `./mx run scripts/load_test.exs` (60 Spieler im Rahmen von `docs/performance.md`).
- [ ] **Schritt 5: Commit** — `git commit -am "feat: Jaeger greifen erst ab Misstrauisch an"`.

---

### Task 5: Schutzzone je Schiff, gesperrter Hafen, Wiedergutmachung

**Dateien:**
- Ändern: `lib/osp/state.ex` (`dock/2`, `shop/3`, `shop_view/2`, neue `safe_for?/2`), `lib/osp/combat.ex` (die vier Stellen mit `Ports.safe?/3`), `lib/osp/shop.ex` (`atone/1`, Hafen-Ansicht bei Sperre), `lib/osp/web/socket.ex` (`buy` mit `what: "atone"`)
- Test: neu `test/osp/hostile_port_test.exs`; angepasst `test/osp/harbor_test.exs` bei Bedarf

**Schnittstellen:**
- Verbraucht: `Reputation.standing/1`, `Reputation.atone_cost/0`, `Reputation.atone_gain/0`, `Nations.of_port/2`, `State.add_rep/4`.
- Erzeugt:
  - `State.safe_for?(state, ship | nil) :: boolean()`: `true`, wenn die Position in einer Hafen-Schutzzone liegt **und** das Schiff dort geschützt ist. Ungeschützt (`false`) sind Spieler mit Status `:wanted` bei der Nation **dieses** Hafens (`Nations.of_port`); bei `nil` (z. B. Fort-Kugel ohne Schiff) ist nichts geschützt.
  - `docked` bekommt die Nation: `%{id, name, nation}`.
  - `Shop.atone(ship) :: {:ok, ship} | {:error, :no_gold | :not_wanted}` verkürzt: reine Preisprüfung; die Rufänderung macht `State.shop/3` mit `Reputation.atone_gain/0` für die Nation des Hafens (Aktion `:atone`).
  - `State.shop/3` bei Gesucht-Status bei der Hafen-Nation: Aktionen außer `:atone` ergeben `{:error, :hostile}`; `shop_view/2` und `State.dock/2` liefern dann `%{t: "shop", open: true, port: name, hostile: true, nation: "england", rep: integer, atone: %{cost: 300, gain: 25}, gold: integer}`.
  - Socket: `{"t":"buy","what":"atone"}` über die feste Zuordnung, andere Werte wie bisher.

- [ ] **Schritt 1: Failing Tests (`hostile_port_test.exs`):**
  - `safe_for?`: Spieler mit `rep.england == 0` in der Zone eines englischen Hafens: `true`; mit `-40`: `false`; mit `-40` bei **England**, aber Zone eines **französischen** Hafens (anderer Hafen-Nation): `true`; außerhalb jeder Zone: `false`; NPC-Schiff in der Zone: `true`; `nil`: `false`.
  - Kampf: Gesuchter in englischer Zone **kann feuern** und **kann beschädigt werden** (`Combat.hurt` wirkt), Nicht-Gesuchter nicht (bestehende Schutztests laufen weiter); Kugeln eines Gesuchten verschwinden in der Zone nicht, Kugeln eines Nicht-Gesuchten wie bisher.
  - Andocken eines Gesuchten gelingt; `shop_view` ist die Sperr-Ansicht mit `hostile: true` und `atone`; Kaufaktionen (`{:class, :klipper}`, `{:upgrade, :hull}`, `{:ammo, :chain}`, `:repair`, `{:deposit, 10}`, `{:withdraw, 10}`) liefern `{:error, :hostile}` und ändern Gold, Bank, Klasse und Schiff nicht.
  - Wiedergutmachung: Gesuchter mit 300+ Gold zahlt genau 300, Ruf steigt um 25 (nur bei dieser Nation, andere unverändert, Grenze +100), neue Ansicht; mit weniger Gold `{:error, :no_gold}` ohne Abzug; bei Status ungleich `:wanted` `{:error, :not_wanted}` ohne Abzug; kein Fehler bei Gold genau 300; mehrmals hintereinander (zweiter Aufruf nach Statuswechsel) wirkt nicht mehr, sobald der Ruf über −40 liegt.
  - Nach der Wiedergutmachung auf −15 (Misstrauisch) ist der Hafen **wieder offen** (Shop-Ansicht normal, Kauf möglich).
  - Socket-Test: `buy` mit `what: "atone"` wird angenommen, unbekannte `what`-Werte ändern nichts; das JSON der Ansicht enthält nie das Token.

- [ ] **Schritt 2: Ausführen, Fehlschlag prüfen.**
- [ ] **Schritt 3: Implementieren:** Die vier Stellen in `Combat` (`fire/3`, `move_balls/3` für Kugeln mit Besitzer-Schiff `state.ships[ball.owner]`, `hurt/6`, `burn/1`) rufen `State.safe_for?/2` statt `Ports.safe?/3` direkt auf. Kugel-Regel: Eine Kugel verschwindet in einer Zone nur, wenn ihr Besitzer dort geschützt ist (Besitzer-Schiff vorhanden und `safe_for?`); Fort-Kugeln (Besitzer ist keine Schiff-ID) verschwinden nie.
- [ ] **Schritt 4: Ausführen** — `./mx test`. Erwartung: alle grün, Schutztests unverändert.
- [ ] **Schritt 5: Commit** — `git commit -am "feat: Schutzzone je Schiff, gesperrter Hafen, Wiedergutmachung"`.

---

### Task 6: Fort und Alarm

**Dateien:**
- Neu: `lib/osp/fort.ex`
- Ändern: `lib/osp/state.ex` (Zustandsfeld `forts`, `step/2`, `add_npc/7` um optionale Nation), `lib/osp/combat.ex` (Kugel-Besitzer `"fort:<id>"`, Ereignis-Anbindung)
- Test: `test/osp/fort_test.exs`

**Schnittstellen:**
- Verbraucht: `State.safe_for?/2` (Task 5), `Nations.of_port/2`, `Ports.near/4`, `Reputation.standing/1`.
- Erzeugt: `Osp.Fort.step(state) :: {state, events}` (rein; nach `Combat.step/2` in `State.step/2` aufgerufen). Zustand `state.forts :: %{String.t() => map()}` je Hafen-ID (`%{cooldown_until, warned: %{player_id => time}, alarm_until: %{player_id => time}}`). Regeln: Für jeden lebenden, **nicht angedockten** Spieler mit `:wanted` bei der Nation eines Hafens, der in `Fort.range/0` (8 WE) um den Ankerplatz liegt:
  - **Warnung:** erste Sichtung → Ereignis `{:fort_warn, port_id, player_id, x, y}`; erst nach 1 500 ms darf der erste Schuss fallen.
  - **Schuss:** eine Kugel (Besitzer `"fort:<port_id>"`, Besitzerart `:fort`, Schaden 3, Geschwindigkeit 6 WE/s, Lebensdauer 1 500 ms), Nachladen 5 000 ms je Fort. Der **erste** Schuss auf einen Spieler zielt mit **Vorhalt** (Zielpunkt = Position + Geschwindigkeitsvektor × Flugzeit), spätere ohne Vorhalt auf die aktuelle Position. Dazu Ereignis `{:fire, "fort:<port_id>", :fort, x, y}`.
  - **Alarm:** Betritt ein Gesuchter die Zone (innerhalb `Ports.safe_radius/0`), kommen **zwei Jäger** der Hafen-Nation (`State.add_npc/8` mit expliziter Nation, 10–20 WE vom Spieler); danach 180 000 ms Pause je Spieler und Hafen.
  - Nie auf Tote, Angedockte, Nicht-Gesuchte oder Spieler außerhalb von `Fort.range/0`.
- Erzeugt: `State.add_npc(state, kind, name, x, y, heading, bonus \\ 0, nation \\ nil)` (Nation überschreibt `Nations.at/3`); `Combat.hit_ship/2` lässt Fort-Kugeln (Besitzerart `:fort`) nur Spieler treffen.

- [ ] **Schritt 1: Failing Tests (`fort_test.exs`, Seed 4, Hafen aus `Nations.nearest_port_of/4`):**
  - Gesuchter (−40) in 6 WE vom Hafen, nicht angedockt: sofort Ereignis `:fort_warn`; vor 1 500 ms **keine** Fort-Kugel; danach genau eine Kugel mit Besitzer `"fort:" <> port.id`, Schaden 3.
  - **Erster Schuss trifft:** Ein Spieler, der mit konstanter Geschwindigkeit (1,5 WE/s) und Kurs fährt, wird vom ersten Fort-Schuss getroffen (Test bis zur Kugelauflösung simulieren, Spieler verliert 3 HP); ein Ausweicher, der nach der Warnung 90° abdreht, wird vom ersten Schuss **nicht** sicher getroffen (zweiter Test, Ergebnis mit festem Seed deterministisch; wenn die Geometrie keine Aussage liefert, stattdessen testen, dass die zweite Salve **ohne Vorhalt** auf die aktuelle Position zielt: Kugel-Richtung gleich Vektor zur Position).
  - Nachladen: zwischen zwei Schüssen mindestens 5 000 ms.
  - **Keine Schüsse:** auf angedockte Spieler, tote Spieler, Spieler mit Status ungleich `:wanted` (auch Misstrauisch), Spieler außerhalb von 8 WE, und kein Schuss, wenn die Hafen-Nation nicht die Nation ist, bei der der Spieler gesucht wird (Spieler gesucht bei England, Hafen französisch).
  - **Alarm:** Betreten der Zone löst zwei Jäger der Hafen-Nation aus (Anzahl der NPCs steigt um 2, beide mit `nation == Hafen-Nation`, in 10–20 WE vom Spieler); ein zweiter Betritt innerhalb 180 000 ms löst keinen neuen Alarm aus, danach wieder.
  - Fort-Kugeln verletzen **keine NPCs**; Schnappschuss mit Fort-Ereignissen enthält nie das Token.
  - Lasttest: `./mx run scripts/load_test.exs` bleibt im Rahmen von `docs/performance.md` (Fort-Prüfung nur für Gesuchte nahe Häfen).

- [ ] **Schritt 2: Ausführen, Fehlschlag prüfen.**
- [ ] **Schritt 3: Implementieren** `Osp.Fort` und die Anbindung in `State.step/2`; Zufall nur über `state.rng`.
- [ ] **Schritt 4: Ausführen** — `./mx test`. Erwartung: alle grün.
- [ ] **Schritt 5: Commit** — `git add lib/osp/fort.ex test/osp/fort_test.exs lib/osp && git commit -m "feat: Fort und Alarm bei Gesuchten"`.

---

### Task 7: Client – Ruf, gesperrter Hafen, Fort-Warnung

**Dateien:**
- Ändern: `priv/static/js/main.js`, `priv/static/js/shop.js`, `priv/static/js/render.js`, `priv/static/index.html`, `priv/static/css/osp.css`
- Test: Browser-Prüfung

**Schnittstellen:**
- Verbraucht: `me.rp` (fünf Zahlen in der Reihenfolge der Nationen), `me.tn`, Hafen-Ansicht mit `hostile`, Ereignisse `rep` und `fort_warn`.
- Erzeugt: `{"t":"buy","what":"atone"}`.

- [ ] **Schritt 1: Ruf anzeigen:** Unter „Gewässer: …" steht der Ruf bei der Nation des Gebiets mit Stufe, z. B. „Ruf +12 (Neutral)"; Stufen im Client nach `Reputation.standing/1` (≤ −40 Gesucht, ≤ −10 Misstrauisch, ≥ 30 Freund, sonst Neutral). Im Hafen (Shop-Ansicht) alle fünf Nationen mit Wert.
- [ ] **Schritt 2: Rufmeldung:** Ereignis `["rep", id, nation, delta, value, x, y]` mit `id == myId` zeigt „Ruf <Nation> −8" (Text, wie die Goldmeldung); bei Wechsel in „Misstrauisch" oder „Gesucht" eine einmalige Warnung („Die Jäger Englands suchen dich").
- [ ] **Schritt 3: Gesperrter Hafen:** `shop.js` zeigt bei `hostile: true` statt der Angebote einen Hinweis („<Nation> verkauft dir nichts mehr") und den Knopf „Wiedergutmachung: 300 🪙 → Ruf +25" (deaktiviert ohne genug Gold); Fehler `hostile`/`no_gold`/`not_wanted` mit deutschen Texten in `ERRORS`. Namen und Texte nur per `textContent`.
- [ ] **Schritt 4: Fort:** Ereignis `["fort_warn", port_id, player_id, x, y]` für den eigenen Spieler zeigt „Das Fort eröffnet das Feuer" (4 s, rot); im Abschussfeed heißt ein Besitzer, der mit `fort:` beginnt, „Fort".
- [ ] **Schritt 5: Browser-Prüfung** — mit zwei Spielern (zweiter Spieler per WebSocket-Hilfe im Browser wie bei früheren Prüfungen): Ruf-Anzeige erscheint; ein per Konsole gesetzter schlechter Ruf (`window.osp`-Hilfsmittel nicht nötig: über den Server-Test-Weg, z. B. Händler versenken) zeigt die Warnung und die Sperr-Ansicht im Hafen; Konsole ohne Fehler; `./mx stop`.
- [ ] **Schritt 6: Commit** — `git commit -am "feat: Ruf, gesperrter Hafen und Fort-Warnung im Client"`.

---

### Task 8: Doku und Abschluss

**Dateien:**
- Ändern: `docs/decisions.md`, `README.md`, `CLAUDE.md`, `docs/roadmap.md`, Hilfetext in `priv/static/index.html`

- [ ] **Schritt 1:** Neue Zeilen in `docs/decisions.md` (Ruf und Stufen, Rufverlust und Selbstverteidigung, Jäger ab Misstrauisch, Schutzzone je Schiff, gesperrter Hafen mit Wiedergutmachung 300 Gold/+25, Fort und Alarm), `README.md` (Funktionsliste, neue Module `reputation.ex`, `fort.ex`, Testzahl), `CLAUDE.md` (Hinweis auf `Osp.Reputation`, `safe_for?`), Roadmap (Baustein 2 erledigt, Baustein 3 als nächster), Hilfe im Spiel (kurzer Absatz zu Ruf und Fort).
- [ ] **Schritt 2:** `./mx precommit` (alle Tests grün, keine Warnungen), committen; Deploy und Push mit Daniel abstimmen.
- [ ] **Schritt 3: Commit** — `git commit -am "docs: Ruf (Baustein 2)"`.
