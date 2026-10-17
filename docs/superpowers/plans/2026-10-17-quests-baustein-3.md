# Quests (Baustein 3) – Bauplan

> **Für ausführende Agenten:** Benötigter Sub-Skill: `superpowers:subagent-driven-development` (empfohlen) oder `superpowers:executing-plans`. Schritte nutzen Checkboxen (`- [ ]`).

**Ziel:** Häfen bieten Quests an (Lieferung, Jagd, und bei Gesucht eine Wiedergutmachungsquest); der Spieler nimmt bis zu zwei an, erfüllt und gibt sie im Hafen ab und bekommt Gold und Ruf. Die Übergangszahlung der Wiedergutmachung (300 Gold) aus Baustein 2 entfällt.

**Architektur:** Neues reines Modul `Osp.Quests` (Angebote deterministisch aus Seed, Hafen und 30-Minuten-Fenster; Quest-Daten, Fortschritt, Ablauf, Prüfung geladener Quests). Aktive Quests liegen im Schiff (`ship.quests`) und im Profil (`"quests"`). `Osp.State` nimmt an, schreibt Fortschritt fort (Abschüsse), gibt ab und scheitert bei Tod; der Socket bekommt die Nachricht `quest`; der Client zeigt Angebote im Hafen und ein Quest-Log mit grober Richtung (Pfeil, Himmelsrichtung, gerundete Entfernung).

**Tech-Stack:** Elixir (reine Module, ExUnit), Client in ES-Modulen ohne Build.

**Spec:** `docs/superpowers/specs/2026-10-17-nationen-ruf-quests-design.md` (Baustein 3, Abschnitte 4 und 9). Baustein 1 (Nationen) und 2 (Ruf) sind umgesetzt. Eroberung (Baustein 4) ist **nicht** Teil dieses Plans.

## Globale Vorgaben

- Elixir läuft nur auf dem Server: `./mx test` bzw. `./mx precommit` (Warnungen = Fehler); Ausgangsstand 226 Tests grün.
- Spiellogik in reinen Modulen mit Tests; `Osp.World` und `Osp.Web.Socket` sind Hülle. Konstanten oben im Modul.
- **Angebote:** 3 je Hafen, ohne Speicher erzeugt aus `(Seed, Hafen, Zeitfenster von 30 Minuten)` deterministisch; Zeitfenster = `div(state.time, 1_800_000)`. Angenommene Quests stehen im Profil.
- **Lieferung:** Ware im Hafen übernehmen, zu einem anderen Hafen **40–120 WE** entfernt bringen; Belohnung Gold nach Entfernung (`40 + round(1,2 · Entfernung)`) und **Ruf +4** bei der Nation des Auftraggebers; Stirbt der Spieler, ist die Ware weg und die Quest gescheitert.
- **Jagd:** 2–3 Jäger einer **anderen** Nation versenken; Belohnung Gold (`70 · Anzahl`) und **Ruf +6** bei der Nation des Auftraggebers; der Rufverlust bei der Nation der Jäger gilt weiterhin (Baustein 2), die Notwehr-Ausnahme gilt auch hier: ein Jäger, der den Spieler beschossen hat, kostet keinen Ruf, **zählt aber für die Quest**.
- **Wiedergutmachung:** nur bei Gesucht (Ruf ≤ −40) bei der Nation des Hafens: Lieferung zu einem anderen Hafen **derselben** Nation oder Jagd auf Jäger einer dritten Nation; **kein Gold**, **Ruf +25** bei der Nation des Hafens. Sie ersetzt die Zahlung aus Baustein 2 (`:atone`, `"atone"`, `Reputation.atone_cost/0`, `atone_gain/0` entfallen).
- **Ablauf:** höchstens **2 aktive Quests**; jede läuft nach **30 Minuten Spielzeit** ab (Rest in Millisekunden, zählt nur für lebende Spieler, auch bei Neustart erhalten); Erfüllen und Abgeben im Hafen, Belohnung sofort. Lieferung: Abgabe im Zielhafen; Jagd: Abgabe im Hafen des Auftraggebers.
- **Grobe Richtung:** Jede aktive Quest zeigt dem Spieler eine **grobe** Richtung, keinen exakten Punkt: Der Server schickt einen auf 10 WE gerundeten Hinweispunkt `hx, hy` (Lieferung: Zielhafen; Jagd: nächster Hafen der Zielnation, solange noch Jäger fehlen; danach und bei fertiger Lieferung der Abgabehafen). Der Client zeigt im Quest-Log Pfeil, Himmelsrichtung (N, NO, O, …) und auf 10 WE gerundete Entfernung. Einen automatischen exakten Wegpunkt gibt es **nicht**; Wegpunkte setzt der Spieler weiter selbst per Klick.
- **Hafen bei Gesucht:** Abgeben (`turn_in`) und Annehmen der Wiedergutmachungsquests sind im gesperrten Hafen erlaubt; alle anderen Käufe bleiben gesperrt. Angedockte Schiffe werden nicht beschossen.
- Das Spieler-Token geht nie an Clients (`Osp.State.public_id/1`); neue Client-Nachrichten nur über feste Whitelists; Namen im Client nur per `textContent`.
- Profil: `@version` in `Osp.Profile` wird erhöht; alte Profile ohne Quests werden verlustfrei gelesen; geladene Quests werden **streng geprüft** (feste Arten, Nationen, Hafen-IDs, begrenzte Zahlen).
- Doku (`README.md`, `CLAUDE.md`, `docs/decisions.md`, Roadmap) wird mitgepflegt.

## Review-Fokus

Eingaben und Zustände, die der Entwurf andeutet, aber keine Aufgabe von selbst prüft, am wahrscheinlichsten zuerst:

1. **Ungültiges Annehmen:** gefälschte oder veraltete Angebots-IDs, dasselbe Angebot zweimal, eine dritte Quest, Annehmen ohne angedockt zu sein, Wiedergutmachung ohne Gesucht-Status (Task 3, Task 4).
2. **Beschädigte oder manipulierte gespeicherte Quests** (unbekannte Art, riesige Zahlen, falsche Hafen-IDs, fremde Typen) laden sicher und werden bereinigt (Task 2).
3. **Scheitern und Ablauf:** Lieferung scheitert beim Tod, Jagd bleibt; abgelaufene Quests geben nichts; Rest-Zeit zählt nicht für Tote (Task 3).
4. **Abgabe:** am falschen Hafen passiert nichts, doppeltes Abgeben ist unmöglich, die Belohnung kommt genau einmal, Ruf wird begrenzt (Task 3).
5. **Jagd-Zählung:** nur Jäger der Zielnation zählen, nicht Händler oder andere Nationen, auch Notwehr-Abschüsse zählen, NPC-Tod ohne Spieler als Killer zählt nicht (Task 3).

---

## Dateiübersicht

- Neu `lib/osp/quests.ex`, `test/osp/quests_test.exs`, `test/osp/quests_state_test.exs`.
- Ändern `lib/osp/ports.ex` (`by_id/2`), `lib/osp/profile.ex` (`"quests"`), `lib/osp/state.ex` (Schiffsfeld, Annehmen/Abgeben/Aufgeben, Fortschritt, Tod, Ablauf, Hafen-Ansichten, Schnappschuss), `lib/osp/combat.ex` (Fortschritt bei Abschuss, Scheitern bei Tod), `lib/osp/shop.ex` (Ansichten mit Quests, `atone` entfällt), `lib/osp/reputation.ex` (Atone-Konstanten entfallen), `lib/osp/world.ex`, `lib/osp/web/socket.ex` (`quest`-Nachricht, `atone` entfällt).
- Client: `priv/static/js/shop.js`, `main.js`, `render.js`, `priv/static/index.html`, `css/osp.css`.
- Angepasst: `test/osp/hostile_port_test.exs` (Wiedergutmachung durch Quests ersetzt), weitere Tests, die `atone` erwähnen.

---

### Task 1: `Osp.Quests` und `Osp.Ports.by_id/2` (rein)

**Dateien:**
- Neu: `lib/osp/quests.ex`
- Ändern: `lib/osp/ports.ex`
- Test: `test/osp/quests_test.exs`

**Schnittstellen:**
- Erzeugt (`Osp.Ports`): `by_id(seed, "port:cx,cy") :: map() | nil` (Hafen aus der ID, `nil` bei fehlendem Hafen oder ungültiger ID; keine Atome, keine Ausnahmen bei Unsinn).
- Erzeugt (`Osp.Quests`):
  - Typen `offer :: %{id: String.t(), kind: :delivery | :hunt, from: String.t(), nation: atom(), to: String.t() | nil, to_name: String.t() | nil, dist: integer() | nil, target_nation: atom() | nil, need: pos_integer(), gold: non_neg_integer(), rep: pos_integer(), atone?: boolean()}` und `quest :: Map aus offer plus have: non_neg_integer(), left_ms: pos_integer()` (ohne `to_name`/`dist`, mit `tx`, `ty` für Lieferungen kommt erst im Schnappschuss, nicht hier).
  - `window(time_ms) :: non_neg_integer()` (30-Minuten-Fenster), `ttl_ms/0 :: 1_800_000`, `max_active/0 :: 2`.
  - `offers(seed, port :: map(), window) :: [offer]` (genau 3, `atone?: false`), `atonement_offers(seed, port, window) :: [offer]` (genau 2, `atone?: true`, `gold: 0`, `rep: 25`, Auftraggeber-Nation = Nation des Hafens).
  - `find_offer(seed, port, window, id, wanted? :: boolean()) :: {:ok, offer} | :error` (sucht in `offers` und, wenn `wanted?`, in `atonement_offers`).
  - `to_quest(offer) :: quest`, `kill(quest, victim_nation :: atom()) :: quest` (Jagd: `have + 1` begrenzt auf `need`, nur wenn `victim_nation == target_nation`), `complete?(quest, docked_port_id) :: boolean()` (Lieferung: Hafen == `to`; Jagd: `have >= need` und Hafen == `from`), `tick(quests, ms) :: {kept, expired}` (zieht `ms` ab, `left_ms <= 0` läuft ab), `to_json(quest) :: map()` (String-Schlüssel) und `from_json(term()) :: {:ok, quest} | :error` (streng).
- Verbraucht: `Osp.Nations.of_port/2`, `Osp.Nations.all/0`, `Osp.Ports.near/4`, `Osp.Ports.by_id/2`.

- [ ] **Schritt 1: Failing Tests** in `test/osp/quests_test.exs` (Seed `4`, ein Hafen aus `Ports.near(4, 0.0, 0.0, 400.0)`):
  - `Ports.by_id(4, port.id) == port`; `by_id(4, "unsinn")`, `by_id(4, "port:x,y")`, `by_id(4, "port:99999999,1")` (kein Hafen), `by_id(4, nil)`, `by_id(4, 5)` ergeben `nil` ohne Ausnahme.
  - `offers/3`: genau 3 Angebote; **deterministisch** (zweimal gleich); anderes Fenster ergibt andere Angebote (mindestens eine Abweichung über 5 Fenster); IDs haben das Muster `q:<port.id>:<window>:<index>`; Lieferungen: `to` ist ein anderer Hafen, `dist` liegt in 40..120 und passt zur Luftlinie (±1), `gold == 40 + round(1.2 * dist)`, `rep == 4`; Jagden: `need` in 2..3, `target_nation != nation`, `gold == 70 * need`, `rep == 6`; `nation == Nations.of_port(4, port)`; `atone?` immer `false`.
  - `atonement_offers/3`: genau 2, `atone?: true`, `gold == 0`, `rep == 25`; Lieferungen haben als Ziel einen Hafen **derselben** Nation (`Nations.of_port` gleich `nation`), Jagden eine Nation ungleich `nation`.
  - `find_offer/5`: findet ein echtes Angebot; fremde/veraltete/gefälschte IDs und IDs eines anderen Fensters ergeben `:error`; Wiedergutmachungsangebote nur mit `wanted? == true`.
  - `to_quest/1`: `have == 0`, `left_ms == 1_800_000`; `kill/2`: zählt nur bei passender Nation, nie über `need`, ändert Lieferungen nicht.
  - `complete?/2`: Lieferung am Zielhafen ja, am Auftraggeber-Hafen nein; Jagd mit `have < need` nein, mit `have == need` am Auftraggeber-Hafen ja, am falschen Hafen nein.
  - `tick/2`: zieht Zeit ab; `left_ms` ≤ 0 landet in `expired`.
  - `to_json/1` → `from_json/1` Rundlauf ist gleich; `from_json/1` lehnt ab: unbekannte `kind`, unbekannte Nation, ungültige Hafen-ID, `need` 0 oder 1000, `have` > `need`, negative oder riesige `gold`/`rep`/`left_ms` (werden begrenzt: `gold` ≤ 100 000, `rep` ≤ 100, `left_ms` ≤ `ttl_ms`), Nicht-Maps, fehlende Felder.

- [ ] **Schritt 2: Ausführen, Fehlschlag prüfen** — `./mx test test/osp/quests_test.exs`. Erwartung: `Osp.Quests` fehlt.
- [ ] **Schritt 3: Implementieren.** Erzeugung über `:erlang.phash2({:quest, seed, port.id, window, index, salt}, n)`, Zielhafen aus `Ports.near(seed, port.x, port.y, 120)` gefiltert auf Abstand ≥ 40 und ungleich dem eigenen Hafen, Auswahl per Hash; fehlt ein Ziel, wird das Angebot zur Jagd. Die dritte Angebotsart ist abwechselnd Lieferung/Jagd je Index (`0` Lieferung, `1` Jagd, `2` per Hash). `Ports.by_id/2` zerlegt die ID mit einer festen Regel (`~r/^port:(-?\d{1,7}),(-?\d{1,7})$/`) und fragt `in_chunk/3`.
- [ ] **Schritt 4: Ausführen** — Erwartung: alle grün.
- [ ] **Schritt 5: Commit** — `git add lib/osp/quests.ex lib/osp/ports.ex test/osp/quests_test.exs && git commit -m "feat: Osp.Quests (Angebote, Fortschritt, Pruefung)"`.

---

### Task 2: Quests im Schiff, Profil, Schnappschuss, Ablaufzeit

**Dateien:**
- Ändern: `lib/osp/profile.ex`, `lib/osp/state.ex` (`new_ship/6`, `step/2`, `snapshot_for/3`, `event_entry/1`)
- Test: `test/osp/quests_state_test.exs`

**Schnittstellen:**
- Verbraucht: `Quests.from_json/1`, `Quests.to_json/1`, `Quests.tick/2`, `Quests.max_active/0`, `Ports.by_id/2`.
- Erzeugt: Schiffsfeld `quests :: [quest]`; Profil-Schlüssel `"quests"` (Liste von JSON-Maps, höchstens 2, ungültige Einträge werden verworfen); Schnappschuss `me.q :: [%{id, k, n, to, hx, hy, tn, need, have, gold, rep, at, left}]` (`k`: `"delivery"`/`"hunt"`, `n`: Nation des Auftraggebers, `to`: Name des Zielhafens bei Lieferungen sonst `nil`, `hx`/`hy`: **grober Hinweispunkt**, auf 10 WE gerundet, oder `nil`, wenn kein Hafen gefunden wird, `tn`: Zielnation bei Jagd sonst `nil`, `at`: Wiedergutmachung, `left`: Restsekunden); `Osp.Quests.hint(seed, quest, {x, y}) :: {number(), number()} | nil` (reine Berechnung des ungerundeten Punkts: Lieferung → Zielhafen (`Ports.by_id/2`); Jagd mit `have < need` → `Nations.nearest_port_of(seed, target_nation, {x, y}, 400.0)`; sonst Abgabehafen `from`) und `Osp.Quests.round_hint({x, y}) :: {integer(), integer()}` (auf Vielfache von 10); Schiffsfeld je Quest `hint :: {x, y} | nil` (nur im Speicher, **nicht** im Profil, `to_json/1` lässt es weg), alle 500 ms zusammen mit der Gebietsnation neu berechnet; Ereignis `{:quest_lost, player_id, :expired | :death, x, y}` → `["quest_lost", public_id, "expired"|"death", x, y]`.

- [ ] **Schritt 1: Failing Tests (`quests_state_test.exs`):**
  - `Profile.decode(%{"quests" => ...})`: gültige Quests bleiben, **mehr als zwei** werden auf zwei gekürzt; Müll (`"x"`, `5`, Quests mit unbekannter Art, riesigen Zahlen, ungültiger Hafen-ID, Duplikate derselben ID) wird bereinigt oder verworfen; fehlendes `"quests"` ergibt `[]`; **altes Profil** (Version 3, ohne Quests) lädt verlustfrei (Gold, Klasse, Ruf bleiben); `Profile.new()["quests"] == []`.
  - Rundlauf: `from_ship/1` → `apply/2` erhält die Quests eines Schiffs.
  - `State.new_ship`: neue Schiffe haben `quests: []`.
  - Ablaufzeit: Spieler mit einer Quest (`left_ms: 1_500`), nach 500 ms (`state.time` auf Vielfaches von 500 gesetzt und `State.tick`): `left_ms` um 500 kleiner; nach Ablauf ist die Quest entfernt und das Ereignis `{:quest_lost, id, :expired, _, _}` kommt; **tote Spieler** verlieren keine Zeit; Spieler ohne Quests: Schiff unverändert, keine Ereignisse.
  - `Quests.hint/3`: Lieferung zeigt auf den Zielhafen, Jagd mit fehlenden Abschüssen auf den nächsten Hafen der Zielnation (Test: kein näherer Hafen dieser Nation innerhalb 400 WE), fertige Jagd auf den Abgabehafen, ein Punkt ohne Hafen der Nation in 400 WE ergibt `nil`; `round_hint/1` rundet auf Vielfache von 10 und weicht höchstens 5 WE je Achse vom Original ab.
  - Schnappschuss `me.q`: Lieferung trägt `to` und den **gerundeten** Hinweis `hx`, `hy` (Vielfache von 10, nie der exakte Hafenort, solange er kein Vielfaches von 10 ist) und `left` in Sekunden (aufgerundet); Jagd trägt `tn`, `need`/`have` und einen Hinweis; der Hinweis wird nur alle 500 ms neu berechnet (nach 25 ms ändert er sich bei bewegtem Schiff nicht); JSON-kodierbar; enthält nie das Token.
  - Ereignis `quest_lost` geht als Liste mit öffentlicher Kennung hinaus.

- [ ] **Schritt 2: Ausführen, Fehlschlag prüfen.**
- [ ] **Schritt 3: Implementieren** (`Profile` `@version 4`, `State.step/2` zieht alle 500 ms `500` Millisekunden von den Quests lebender Spieler ab, nach dem Muster von `update_territory/1`).
- [ ] **Schritt 4: Ausführen** — `./mx test`. Erwartung: alle grün.
- [ ] **Schritt 5: Commit** — `git commit -am "feat: Quests im Schiff, Profil, Schnappschuss und Ablaufzeit"`.

---

### Task 3: Annehmen, Abgeben, Aufgeben, Fortschritt, Scheitern; Wiedergutmachung ersetzt

**Dateien:**
- Ändern: `lib/osp/state.ex` (`accept_quest/3`, `turn_in/2`, `abandon_quest/3`, `shop/3`, `shop_view/2`, Hafen-Ansichten), `lib/osp/combat.ex` (`kill/2`: Fortschritt und Scheitern), `lib/osp/shop.ex` (Ansichten mit `quests`, `hostile_view/3` ohne `atone`), `lib/osp/reputation.ex` (Atone-Konstanten entfernen)
- Test: neu `test/osp/quests_flow_test.exs`; angepasst `test/osp/hostile_port_test.exs`, `test/osp/reputation_test.exs`

**Schnittstellen:**
- Verbraucht: `Quests.*`, `State.add_rep/4`, `Nations.of_port/2`, `Ports.by_id/2`.
- Erzeugt:
  - `State.accept_quest(state, id, offer_id :: String.t()) :: {state, {:ok, view} | {:error, reason}}`. Fehler: `:not_docked`, `:full` (schon zwei aktive), `:unknown_offer` (Angebot nicht im aktuellen Fenster des angedockten Hafens, gefälscht), `:duplicate` (dieselbe Angebots-ID schon aktiv), `:not_wanted` (Wiedergutmachungsangebot ohne Gesucht-Status). Bei Erfolg wird die Quest (`Quests.to_quest/1`) angehängt und die neue Hafen-Ansicht (mit Quests) geliefert.
  - `State.turn_in(state, id) :: {state, {:ok, view, events} | {:error, :not_docked | :nothing}}`: gibt **alle** am angedockten Hafen erfüllten Quests ab (`Quests.complete?/2`); je Quest: Gold dazu, `add_rep(state, id, quest.nation, quest.rep)`, Quest entfernt, Ereignis `{:quest_done, id, gold, rep, nation, x, y}` (→ `["quest_done", public_id, gold, rep, nation, x, y]`); genau einmal; `{:error, :nothing}`, wenn nichts erfüllt ist.
  - `State.abandon_quest(state, id, quest_id) :: {state, :ok | {:error, :unknown}}` (überall erlaubt, keine Belohnung).
  - `shop/3` kennt `:atone` nicht mehr (ergibt `{:error, :unknown}` über `trade/6`); `shop_view/2` und alle Antworten tragen `quests: %{offers: [offer_json], active: [quest_json], atone: [offer_json]}` (`atone` nur bei Gesucht); **gesperrter Hafen** erlaubt weiterhin nur Quests (`accept_quest`, `turn_in`).
  - Fortschritt in `Combat.kill/2`: stirbt ein NPC (`kind: :hunter`) mit `nation`, und der Killer ist ein lebender Spieler, wird bei **jeder** Jagdquest des Killers mit `target_nation == nation` `Quests.kill/2` angewendet; **auch bei Notwehr**; Händler, andere Nationen und Tod ohne Spieler zählen nicht. Stirbt ein **Spieler**, scheitern seine Lieferquests (`kind: :delivery`) mit Ereignis `{:quest_lost, id, :death, x, y}`; Jagdquests bleiben.
- Entfernt: `Shop.hostile_view/3` ohne `atone`; `Reputation.atone_cost/0`, `atone_gain/0`; `State.atone/6`, Socket-Zuordnung `"atone"`.

- [ ] **Schritt 1: Failing Tests (`quests_flow_test.exs`, Seed 4, Hafen der Nation `:england`):**
  - **Annehmen:** angedockt, gültiges Angebot (`Quests.offers/3` mit `Quests.window(state.time)`), Spieler hat dann eine Quest mit `have 0`; zweites Angebot ebenfalls; **drittes** `{:error, :full}`; dasselbe Angebot nochmals `{:error, :duplicate}`; gefälschte ID, ID eines anderen Fensters und ID eines anderen Hafens `{:error, :unknown_offer}`; nicht angedockt `{:error, :not_docked}`; Wiedergutmachungsangebot mit Ruf 0 `{:error, :not_wanted}`, mit Ruf −50 angenommen. Nichts davon ändert Gold, Ruf, Klasse oder andere Quests des Spielers bei einem Fehler.
  - **Abgeben, Lieferung:** am Zielhafen angedockt: Gold `+gold`, `rep.<Auftraggeber-Nation> +4` (nur diese Nation), Quest weg, Ereignisse `{:quest_done, …}` und `{:rep, …}`; am falschen Hafen `{:error, :nothing}` und nichts ändert sich; **zweites Abgeben** `{:error, :nothing}`; Ruf wird bei +100 begrenzt (Gold kommt trotzdem).
  - **Abgeben, Jagd:** erst mit `have == need` am Hafen des Auftraggebers; vorher `{:error, :nothing}`.
  - **Wiedergutmachung durch Quests:** Gesuchter Spieler (Ruf −50) nimmt im gesperrten Hafen eine Wiedergutmachungsquest an (`{:ok, view}` mit `hostile: true`), erfüllt sie, bekommt **kein Gold** und `+25` Ruf bei der Hafen-Nation; Ruf −25 → der Hafen ist wieder offen (Ansicht ohne `hostile`). Bei gesperrtem Hafen bleiben Kauf, Reparatur und Bank gesperrt (`{:error, :hostile}`), `turn_in` und `accept_quest` funktionieren.
  - **Jagd-Zählung:** Spieler mit Jagdquest (Ziel `:france`) versenkt (a) einen französischen Jäger → `have 1`; (b) einen französischen **Händler** → unverändert; (c) einen englischen Jäger → unverändert; (d) einen französischen Jäger in **Notwehr** (`hunting` auf den Spieler) → `have` steigt, **Ruf unverändert** (Baustein 2); (e) NPC-Tod ohne Spieler (`by` ist `nil`) → unverändert; (f) mit `have == need` zählt es nicht über `need` hinaus.
  - **Scheitern:** Spielertod entfernt Lieferquests und meldet `{:quest_lost, id, :death, …}`; Jagdquests bleiben mit gleichem `have`.
  - **Aufgeben:** `abandon_quest/3` entfernt die Quest ohne Belohnung und ohne Ruf-/Goldänderung, überall (nicht nur angedockt); unbekannte ID `{:error, :unknown}`.
  - **Atone entfernt:** `State.shop(state, id, :atone)` ändert Gold und Ruf nicht (`{:error, :unknown}`); bestehende Tests, die die 300-Gold-Zahlung erwarten, sind durch Quest-Tests ersetzt (Ledger-Eintrag), `reputation_test.exs` enthält keine Atone-Tests mehr.
  - **Ansichten:** `quests.offers` hat 3 Einträge; `quests.atone` nur bei Gesucht (2 Einträge); `quests.active` entspricht `ship.quests`; JSON-tauglich, ohne Token.

- [ ] **Schritt 2: Ausführen, Fehlschlag prüfen.**
- [ ] **Schritt 3: Implementieren** wie in den Schnittstellen. Der angedockte Hafen kommt aus `ship.docked` (`id`, `name`, `nation`), der Hafen selbst über `Ports.by_id/2`.
- [ ] **Schritt 4: Ausführen** — `./mx test`; danach `./mx run scripts/load_test.exs` (Takt im Rahmen von `docs/performance.md`).
- [ ] **Schritt 5: Commit** — `git commit -am "feat: Quests annehmen, abgeben, aufgeben; Wiedergutmachung als Quest"`.

---

### Task 4: Protokoll (Socket und Welt)

**Dateien:**
- Ändern: `lib/osp/world.ex`, `lib/osp/web/socket.ex`
- Test: `test/osp/web_test.exs` oder neu `test/osp/quests_socket_test.exs`

**Schnittstellen:**
- Verbraucht: `State.accept_quest/3`, `State.turn_in/2`, `State.abandon_quest/3`.
- Erzeugt: `World.quest(world, id, op)` mit `op :: {:accept, String.t()} | :turn_in | {:abandon, String.t()}` (Cast); Antworten für `accept` und `turn_in` kommen als `{:osp_shop, view}` an den Spieler, Fehler als `view` mit `error` wie bei `buy`; Ereignisse aus `turn_in` laufen mit dem nächsten Takt an alle (`pending`). Socket-Nachricht `{"t":"quest","op":"accept","id":"q:port:10,1:5:0"}`, `{"t":"quest","op":"turn_in"}`, `{"t":"quest","op":"abandon","id":"…"}`; IDs nur, wenn sie `~r/^q:port:-?\d{1,7},-?\d{1,7}:\d{1,6}:\d$/` und höchstens 64 Zeichen lang sind (sonst ignoriert); unbekannte `op` ändern nichts.

- [ ] **Schritt 1: Failing Tests:** Socket-Join, dann `accept` mit gültiger ID: `{:ok, state}` und der Welt-Zustand zeigt die Quest, sobald das Schiff angedockt ist (Schiff per `:sys.replace_state` am Hafen andocken); `accept` ohne angedockt: keine Quest, Antwort enthält `error: "not_docked"`; ID mit Unsinn (`"x"`, `"q:port:1,1:0:0; drop"`, 100 Zeichen, Zahl, `nil`, Liste) wird verworfen ohne Absturz; `turn_in` ohne erfüllte Quest: `error: "nothing"`; unbekannte `op` und fehlende Felder ändern nichts; Raten-Limit gilt wie bei den anderen Nachrichten (kein eigener Eimer nötig).
- [ ] **Schritt 2: Ausführen, Fehlschlag prüfen.**
- [ ] **Schritt 3: Implementieren** (feste Whitelist am Socket, Antworten über `reply_shop`).
- [ ] **Schritt 4: Ausführen** — `./mx test`. Erwartung: alle grün.
- [ ] **Schritt 5: Commit** — `git commit -am "feat: Quest-Nachrichten im Protokoll"`.

---

### Task 5: Client – Angebote, Quest-Log mit grober Richtung, Meldungen

**Dateien:**
- Ändern: `priv/static/js/shop.js`, `main.js`, `render.js`, `priv/static/index.html`, `priv/static/css/osp.css`
- Test: Browser-Prüfung

**Schnittstellen:**
- Verbraucht: Hafen-Ansicht `quests: {offers, active, atone}`, Schnappschuss `me.q`, Ereignisse `quest_done`, `quest_lost`.
- Erzeugt: Nachrichten `{"t":"quest","op":"accept","id":…}`, `{"t":"quest","op":"turn_in"}`, `{"t":"quest","op":"abandon","id":…}`.

- [ ] **Schritt 1: Angebote im Hafen:** `shop.js` zeigt unter „Aufträge" die drei Angebote (Text aus den Feldern: „Lieferung nach <Hafen> (<Entfernung> WE)" bzw. „Versenke <need> Jäger von <Nation>", Belohnung Gold und Ruf, Nation des Auftraggebers mit Flagge), „Annehmen" je Angebot (deaktiviert bei zwei aktiven), die aktiven Quests mit „Abgeben" und „Aufgeben"; im **gesperrten Hafen** stattdessen die Wiedergutmachungsangebote (`quests.atone`) und die aktiven Quests (Abgeben), der Knopf „Wiedergutmachung 300 🪙" und die Preis-Texte aus Baustein 2 entfallen. Fehlertexte für `full`, `duplicate`, `unknown_offer`, `nothing`, `not_wanted`. Alles per `textContent` bzw. aus Server-Konstanten.
- [ ] **Schritt 2: Quest-Log im HUD:** `main.js`/`index.html` zeigen links unter dem Hilfeknopf die aktiven Quests: Titel, Fortschritt „1/3" bei Jagd, Zielhafen bei Lieferung, Restzeit mm:ss und eine **grobe Richtung**: ein Pfeil (gedreht zum Hinweispunkt `hx, hy`), die Himmelsrichtung (N, NO, O, SO, S, SW, W, NW; Norden ist oben, y wächst nach unten) und die auf 10 WE gerundete Entfernung („ca. 80 WE"); ohne Hinweis (`hx` ist `nil`) steht „Richtung unbekannt". Die Richtung aktualisiert sich mit dem eigenen Schiff, der Hinweispunkt selbst nur alle 500 ms. **Kein** automatischer Wegpunkt.
- [ ] **Schritt 3: Meldungen:** `quest_done` mit eigener Kennung zeigt „Auftrag erfüllt: +<gold> Gold, Ruf <Nation> +<n>" (`flash`), `quest_lost` „Auftrag gescheitert: Ware verloren" bzw. „Auftrag abgelaufen". Der Münzton `coin` läuft bei Abgabe.
- [ ] **Schritt 4: Browser-Prüfung** mit `./mx serve`: Beitritt, Hafen andocken (F), Angebote erscheinen; Annehmen einer Quest zeigt das Quest-Log; eine Lieferung setzt einen Wegpunkt; die Sperr-Ansicht mit Wiedergutmachungsangeboten lässt sich mit einer nachgestellten Nachricht prüfen (`window.osp.shop.update({t:"shop", open:true, hostile:true, port:"Test", nation:"england", rep:-50, reps:[0,-50,20,0,0], gold:0, quests:{offers:[], active:[], atone:[{id:"q:port:1,1:0:0", k:"hunt", n:"england", tn:"spain", need:2, gold:0, rep:25, at:true}]}})`). Das Quest-Log lässt sich ohne Spielzustand prüfen, indem man in der Browser-Konsole einen Schnappschuss nachstellt (`window.osp.snaps.latest.me.q = [{id:"q:port:1,1:0:0", k:"delivery", n:"england", to:"Test", hx:100, hy:-40, need:1, have:0, gold:120, rep:4, at:false, left:900}]`); der Pfeil zeigt dann Richtung (100, −40) relativ zum Schiff. Konsole ohne Fehler; danach `./mx stop`.
- [ ] **Schritt 5: Commit** — `git commit -am "feat: Quest-Angebote, Quest-Log mit grober Richtung im Client"`.

---

### Task 6: Doku und Abschluss

**Dateien:**
- Ändern: `docs/decisions.md`, `README.md`, `CLAUDE.md`, `docs/roadmap.md`, Hilfetext in `priv/static/index.html`

- [ ] **Schritt 1:** Neue Zeilen in `docs/decisions.md` (Angebote aus Seed und Zeitfenster, Typen und Zahlen, zwei aktive, Ablauf in Spielzeit, Scheitern bei Tod, Abgabeorte, Wiedergutmachung als Quest und das Entfernen der 300-Gold-Zahlung, Jagd zählt auch bei Notwehr), `README.md` (Funktionsliste, neues Modul `quests.ex`, Testzahl), `CLAUDE.md` (Hinweis auf `Osp.Quests`), Roadmap (Baustein 3 erledigt, Baustein 4 als nächster), Hilfe im Spiel (kurzer Absatz zu Aufträgen).
- [ ] **Schritt 2:** `./mx precommit` (alle Tests grün, keine Warnungen), committen; Deploy und Push mit Daniel abstimmen.
- [ ] **Schritt 3: Commit** — `git commit -am "docs: Quests (Baustein 3)"`.
