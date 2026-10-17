# Nationen, Ruf, Quests und Eroberung – Entwurf

Stand: 2026-10-17. Dieses Dokument beschreibt die nächste große Ausbaustufe von Open Sea Pirates (OSP).
Es gliedert sich in vier Bausteine, die in dieser Reihenfolge gebaut werden und nach jedem Baustein ein
spielbares Spiel ergeben. Was Daniel entschieden hat, steht unter „Entschieden". Alles, was mit **Annahme**
markiert ist, ist ein Vorschlag des Entwurfsautors, der im Spieltest nachjustiert werden darf.

## 1. Absicht

OSP ist ein Echtzeit-Piratenspiel im Browser für kleine Gruppen (Freunde, 2–10 gleichzeitig, bis 60
möglich) mit unendlicher, aus einem Seed berechneter Welt. Heute gibt es Gefechte, Beute, Häfen mit Shop
und dauerhafte Spielstände. Es fehlen **Beziehungen zur Welt**: Ein Händlerschiff zu versenken kostet
nichts, ein Hafen ist immer ein sicherer Ort, und es gibt keinen Grund, bestimmte Gebiete zu meiden oder
zu suchen.

Ziel ist, dass Taten Folgen haben. Wer Handelsschiffe einer Nation plündert, wird von ihr gejagt und aus
ihren Häfen vertrieben. Wer für eine Nation arbeitet, gewinnt ihr Vertrauen. Und wer mit Freunden
zusammenspielt, kann Häfen für seine Nation erobern. Das gibt dem Spiel Richtung und einen Grund, es
über den Abend hinaus zu spielen.

## 2. Ziele, Nicht-Ziele, Anti-Ziele

**Ziele**
- Fünf Nationen mit Gebieten, Flaggen und je einem kleinen Startbonus; Wahl der Nation beim ersten Beitritt.
- Ruf je Nation, der durch Taten sinkt oder steigt und das Verhalten von Häfen und Jägern ändert.
- Quests in Häfen (Lieferung, Jagd, Wiedergutmachung) mit Gold und Ruf als Belohnung.
- Eroberbare Häfen, die nur im Team realistisch zu halten sind, mit Rückfall der Gebiete nach einiger Zeit.
- Jeder Baustein ist einzeln spielbar und einzeln deploybar; spätere Bausteine dürfen früheren nichts kaputt machen.

**Nicht-Ziele (erste Version)**
- Keine Verfeindungen oder Bündnisse zwischen Nationen: Ein Abschuss senkt nur den Ruf bei der Nation des versenkten Schiffs.
- Kein Wechsel der Heimatnation nach der Wahl.
- Kein Crew-/Gruppen-System: Teamspiel entsteht allein dadurch, dass mehrere Spieler derselben Nation am selben Hafen kämpfen.
- Keine Handelswirtschaft mit Waren und Laderaum: Fracht gibt es nur als Teil einer Lieferquest.
- Keine Steuern, Hafenausbauten oder sonstige Boni aus eroberten Gebieten.
- Keine Rangliste und keine Rekorde über Sitzungen.

**Anti-Ziele (würden das Ergebnis zum Fehlschlag machen, auch wenn es technisch läuft)**
- **Abwärtsspirale:** Ein Spieler mit schlechtem Ruf kann nicht mehr normal spielen, weil jede Verteidigung den Ruf weiter senkt.
- **Aussperrung:** Ein Spieler kann nie wieder in einen Hafen, weil er überall Feind ist.
- **Gebiete-Monopol:** Eine Gruppe dreht die ganze Welt zu einer Nation, oder eine verlorene Eroberung ist nicht mehr rückgängig zu machen.
- **Verlorene Spielstände:** Gespeicherter Weltzustand (Eroberungen) geht bei Absturz, Neustart oder Deploy verloren oder wird beschädigt.
- **Geheimnisse an Clients:** Das Spieler-Token (der Schlüssel zum Profil) taucht in neuen Nachrichten auf. Clients bekommen immer nur `Osp.State.public_id/1`.

## 3. Rahmenbedingungen (Bestand, nicht ändern)

- Elixir mit Plug, Bandit und WebSock (kein Phoenix); Client in reinen ES-Modulen ohne Build-Schritt.
- Spiellogik in **reinen Modulen** (`Osp.State`, `Osp.Combat`, `Osp.Ports`, ...), `Osp.World` ist nur die Prozess-Hülle (20 Hz).
- Die Welt wird deterministisch aus dem Seed berechnet (`Osp.Terrain`, `Osp.Ports`). Häfen: höchstens einer je Chunk (16×16 WE), Wahrscheinlichkeit 16 %, Namen aus einer festen Liste.
- Heute sind Häfen Schutzzonen (`Osp.Ports.safe?/3`): kein Schaden, kein Feuer, Kugeln verschwinden. Andocken im Radius 2,8 WE bei Tempo < 0,7.
- Spielstände: `Osp.Profile` (JSON je Token in `profiles.json`, Docker-Volume `osp-data`), geprüft in `Profile.decode/1` gegen feste Listen. Atomar geschrieben, mit `.bak`.
- NPCs (`Osp.Director`): Händler und Jäger erscheinen um Spieler. Jäger greifen heute **alle** Spieler im Umkreis an.
- Alle Zahlen sind Startwerte; Balancing im Spieltest. Konstanten stehen oben in den Modulen.
- Bestehende Spieler haben Profile **ohne** Nation und Ruf. Das muss ohne Datenverlust und ohne Abbruch beim Laden funktionieren (Migration in `Profile.decode/1`).
- Der Server rechnet autoritativ; der Client schickt nur Eingaben und Wünsche. Neue Nachrichten brauchen feste Whitelists wie die bestehenden (`@classes`, `@ammo`).
- Ressourcen: Daniel hat noch wenige Wochen Zeit, danach läuft das Projekt ohne KI-Unterstützung weiter. Die Doku (`README.md`, `CLAUDE.md`, `docs/decisions.md`) wird pro Baustein mitgepflegt.

## 4. Entschieden (Daniel)

- **Nationen:** fünf; Flagge klein vor dem Namen; Gebiete auf der unendlichen Welt (aus dem Seed); Nation beim Start wählbar, mit kleinen Startboni.
- **Ruf:** Das Versenken von Handelsschiffen einer Nation senkt den Ruf bei dieser Nation, ebenso das Versenken ihrer Jäger. **Nur** bei dieser Nation, keine Folgen für andere. Ausnahme **Selbstverteidigung**: Ein Jäger, der den Spieler angreift, senkt beim Versenken den Ruf nicht.
- **Schlechter Ruf im Hafen:** Andocken bleibt möglich, aber der Hafen **verkauft nichts mehr**; es gibt nur noch eine Wiedergutmachungsquest. Die **Schutzzone entfällt** für solche Spieler: Der Hafen alarmiert etwa **zwei Jäger** der Nation, oder das **Fort schießt selbst**. Der **erste Treffer** des Forts trifft fast immer, alle weiteren je nachdem, wie gut der Spieler reagiert und ausweicht.
- **Jäger** machen Jagd auf Segler mit schlechtem Ruf: Sie greifen erst ab der Stufe **Misstrauisch** (Ruf −10 oder schlechter) an.
- **Quests** gibt es in Häfen: Handelsware liefern und Piratenjäger jagen; Belohnung Gold.
- **Eroberung:** Häfen können für die eigene Nation erobert werden und erweitern damit das Gebiet. Es soll **sehr schwer** sein und kaum alleine möglich (Teambildung).
- **Rückfall:** Eroberte Gebiete fallen nach einiger Zeit an die ursprüngliche Nation zurück, **wenn sie an deren Gebiet grenzen**. Ist ein eroberter Hafen nur von Häfen der Eroberer-Nation umgeben, bleibt er (zunächst) dauerhaft.

## 5. Die vier Bausteine

### Baustein 1: Nationen und Gebiete

**Gebiete (Annahme):** Jeder Hafen hat eine Ausgangsnation: Die Welt wird in große rechteckige Zellen von
etwa 150×150 WE geteilt, jede Zelle bekommt per Hash aus dem Seed eine der fünf Nationen, und ein Hafen
erbt die Nation der Zelle, in der er liegt. Die Nation eines **beliebigen Punkts** ist die Nation des
**nächsten Hafens** (Voronoi über die Häfen). So entstehen unregelmäßige Grenzen, und derselbe Mechanismus
trägt später die Eroberung (Baustein 4), weil dort nur die Besitzer einzelner Häfen wechseln.
Zellgröße und „nächster Hafen"-Suche sind einstellbar; eine Funktion `Osp.Nations.at(seed, x, y)` liefert
die Nation, `Osp.Nations.of_port(seed, port)` die des Hafens (ohne Eroberung = Ausgangsnation).
Ergebnisse werden wie bei den Häfen in ETS gemerkt.

**Nationen (Annahme):** Spanien, England, Frankreich, Niederlande, Portugal; je eine eigene Farbe und ein
kleines Flaggenbild (selbst gezeichnet, wie die Avatare, per Skript erzeugt).

**Anzeige:** Flagge vor dem Namen eines Schiffs (Spieler: Heimatnation, NPC: Nation des Gebiets, in dem
es erschien), am Hafennamen, Farbtönung der Gebiete auf der Minikarte und eine Meldung beim Betreten eines
fremden Gebiets („Du betrittst englische Gewässer").

**Nationswahl:** Beim **ersten** Beitritt wählt der Spieler eine Nation im Startbildschirm; sie steht danach
im Profil (`"nation"`). Bestehende Profile ohne Nation bekommen die Wahl beim nächsten Beitritt.

**Startbonus (Annahme, klein und gleichwertig, nur solange die Heimatnation gilt):**
Spanien Rumpf +2 HP · England Kanonenschaden +8 % · Frankreich Wendigkeit +6 % ·
Niederlande Reparatur 25 % günstiger · Portugal Tempo +5 %.

**Spawn (Annahme):** Neue Schiffe und Wiederauftauchen starten im Gebiet der Heimatnation, nahe einem
Hafen, nicht mehr bevorzugt 20–40 WE neben einem anderen Spieler. Die Online-Liste mit Richtungspfeil hilft
Freunden verschiedener Nationen, sich zu finden. Die Regel „möglichst weit von Jägern" bleibt.

**Ergebnis nach Baustein 1:** Nationen, Flaggen, Gebiete, Wahl und Boni sind sichtbar; sonst ändert sich
am Spielverlauf noch nichts.

### Baustein 2: Ruf und Folgen

**Ruf (Annahme):** Ganzzahl von −100 bis +100 je Nation, gespeichert im Profil (`"rep"`). Start: Heimatnation
+20, alle anderen 0. Stufen: **Gesucht** ≤ −40, **Misstrauisch** −39 bis −10, **Neutral** −9 bis +29,
**Freund** ≥ +30. Der Ruf nähert sich langsam wieder der 0 (Annahme: +1 pro 10 Minuten Spielzeit), damit
nichts für immer festgeschrieben ist.

**Ruf sinkt (Annahme):** Händler einer Nation versenkt −8, Jäger −5; nur beim Spieler, der den letzten
Treffer gesetzt hat (wie bei `kills`). **Selbstverteidigung:** Hat der versenkte Jäger den Spieler in den
letzten 15 s beschossen oder war er in diesem Moment auf ihn aufgeschaltet, sinkt nichts. Ein Händler, den
der Spieler zuerst angegriffen hat und der sich wehrt, zählt **nicht** als Notwehr.

**Hafen bei schlechtem Ruf (Gesucht):**
- Andocken geht; Shop, Bank und Reparatur sind gesperrt; angeboten wird nur die Wiedergutmachungsquest.
- **Keine Schutzzone** für diesen Spieler bei diesem Hafen: Er kann beschossen werden, und er darf in der
  Zone feuern. Für alle anderen bleibt die Zone wie heute. (`Osp.Ports.safe?/3` braucht dafür das Schiff,
  nicht nur die Position.)
- **Alarm:** Beim Betreten der Zone ruft der Hafen zwei Jäger seiner Nation (einmal je Besuch, danach
  Pause 3 Minuten). Zusätzlich schießt das **Fort**: Der erste Schuss ist gezielt und trifft fast sicher,
  danach folgen im Abstand von einigen Sekunden Schüsse, die einer Ausweichbewegung des Schiffs
  entkommen können. Ein Fort-Treffer ist spürbar, aber nicht sofort tödlich (Annahme: 3 HP, Nachladen 5 s).
  Eine Warnmeldung („Das Fort eröffnet das Feuer") kommt vor dem ersten Schuss.

**Jäger (Änderung am Verhalten, von Daniel entschieden):** Jäger tragen die Nation des Gebiets. Sie greifen
**erst ab Misstrauisch an**, also Spieler mit Ruf **−10 oder schlechter** bei ihrer Nation. Neutrale und
befreundete Spieler lassen sie in Ruhe, auch in fremden Gewässern. Folge: Jäger sind keine Dauergefahr
mehr, sondern eine Folge eigener Taten; frühes Spiel besteht aus Händlern, Quests und Beute. Spieler mit
Gesucht-Status ziehen zusätzlich mehr Jäger an: Der `Osp.Director` hält um sie mehr Jäger dieser Nation
vor (Annahme: Soll 2 statt 1). Händler bleiben friedlich, bis sie getroffen werden (wie heute), und
tragen ebenfalls eine Nation. Jagdquests (Baustein 3) liefern die Jäger als Ziel, auch für Spieler, die
sonst keinen Ärger haben.

**Ergebnis nach Baustein 2:** Taten ändern den Ruf, Häfen und Jäger reagieren, die Abwärtsspirale ist
durch die Selbstverteidigung und den Ruf-Rückgang entschärft. Die Wiedergutmachungsquest selbst kommt mit
Baustein 3; bis dahin muss es einen einfachen Weg zurück geben (Annahme: gegen eine Gold-Zahlung im
Hafen, die nur bei Gesucht angeboten wird und ersetzt wird, sobald Baustein 3 fertig ist).

### Baustein 3: Quests

**Angebote (Annahme):** Jeder Hafen bietet 3 Quests an. Sie werden **ohne Speicher** aus
`(Seed, Hafen, Zeitfenster von 30 Minuten)` erzeugt (deterministisch), sodass ein Neustart nichts verliert.
Angenommene Quests stehen im Profil.

**Typen**
- **Lieferung:** Man übernimmt Handelsware im Hafen und bringt sie zu einem anderen Hafen im selben oder
  einem Nachbargebiet (Annahme: 40–120 WE entfernt). Belohnung: Gold nach Entfernung und Ruf +4 bei der
  Nation des Auftraggebers. Stirbt der Spieler, ist die Ware weg und die Quest gescheitert.
- **Jagd:** Man versenkt 2–3 Jäger einer anderen Nation. Belohnung: Gold und Ruf +6 bei der Nation des
  Auftraggebers. Der Ruf-Verlust bei der Nation der Jäger gilt **weiterhin**, Selbstverteidigung
  ausgenommen (das ist die Söldner-Entscheidung des Spiels).
- **Wiedergutmachung:** Nur bei Gesucht. Wie eine Lieferung oder Jagd, ohne Gold, mit großem Rufgewinn
  (Annahme: +25) und bei der Nation, bei der man Feind ist. Ersetzt die Übergangslösung aus Baustein 2.

**Ablauf (Annahme):** Bis zu 2 aktive Quests je Spieler. Quest-Log im HUD; der Zielhafen wird automatisch
als Wegpunkt gesetzt (der Wegpunkt-Mechanismus im Client existiert bereits). Quests laufen nach 30 Minuten
Spielzeit ab. Erfüllen und Abgeben im Hafen; Belohnung sofort.

**Ergebnis nach Baustein 3:** Ein vollständiger Kreislauf: Quest holen, ausführen, Ruf und Gold
bekommen, bei Ruf-Absturz mit der Wiedergutmachungsquest zurückkehren.

### Baustein 4: Eroberung

Das ist der einzige Baustein mit **gespeichertem Weltzustand**. Er darf gestrichen werden, ohne die
anderen zu beeinträchtigen.

**Besitz (Annahme):** Die Karte `Hafen → Besitzer-Nation` der Abweichungen vom Ausgangszustand wird von
einem eigenen Prozess (`Osp.Territory`, nach dem Vorbild von `Osp.Profiles`) in `territory.json` im
Volume gehalten: atomar geschrieben, mit `.bak`, defekte Datei wird beiseite gelegt. `Osp.Nations.at/3`
und `of_port/2` berücksichtigen diese Abweichungen. Der reine `Osp.State` bekommt die aktuelle Karte als
Wert und bleibt rein.

**Angriff (Annahme):** Nur Spieler, deren Heimatnation nicht die des Hafens ist, können erobern.
- Jeder Hafen hat ein Fort mit starken Kanonen (feuert auf feindliche Schiffe in der Zone, siehe Baustein 2).
- **Eroberungsfortschritt** 0–100 %: Er steigt, solange mindestens ein Angreifer in der Zone ist und
  **kein** Verteidiger (Jäger der Nation) lebt (Annahme: +1,5 % pro Sekunde und Angreifer). Ohne Angreifer
  sinkt er langsam. Verteidiger erscheinen in Wellen (Annahme: je 45 s zwei Jäger, höchstens 6 gleichzeitig).
- Das Fort allein tötet ein einzelnes Schiff in kurzer Zeit; mehrere Spieler verteilen das Feuer. So ist es
  alleine praktisch nicht zu schaffen, im Team aber machbar (Zahlen im Spieltest).
- Nach der Eroberung wechselt der Hafen die Nation (die des Eroberers); **Schutzzeit** 20 Minuten ohne
  erneute Eroberung (Annahme). Der Eroberer bekommt Gold und Ruf bei seiner Nation.

**Rückfall (entschieden, Zahlen Annahme):** Ein eroberter Hafen A hat Nachbarn = Häfen im Umkreis von
etwa 90 WE. Sind alle diese Nachbarn im Besitz der Eroberer-Nation, bleibt er dauerhaft. Hat er
mindestens einen Nachbarn mit einer **anderen** Nation, fällt er nach **30 Minuten** (echte Zeit, zählt
auch bei Neustart) an die Ausgangsnation zurück. Die Prüfung läuft einmal pro Minute. Der Rückfall
verändert die Nachbarschaft anderer Häfen und kann Ketten auslösen; die Prüfung muss daher mit dem Stand
aus dem Speicher rechnen und je Durchlauf nur einmal pro Hafen entscheiden.

**Ergebnis nach Baustein 4:** Gebiete verändern sich durch Spieler, bleiben aber dank Rückfall im
Gleichgewicht.

## 6. Daten und Protokoll (Überblick)

- **Profil** (`Osp.Profile`): neue Felder `"nation"` (String oder nil), `"rep"` (Map Nation → Ganzzahl),
  `"quests"` (Liste aktiver Quests). `decode/1` prüft alles gegen feste Listen und Grenzen; fehlende Felder
  ergeben die Standardwerte. Das Format-`v` wird erhöht, alte Profile werden ohne Verlust gelesen.
- **Schnappschuss:** Schiff-Eintrag bekommt die Nation des Schiffs; Hafen-Eintrag die aktuelle Besitzer-Nation;
  `me` bekommt `rep` (alle fünf Werte), aktive Quests und Fortschritt. Alles über `public_id`, nie Tokens.
- **Neue Client-Nachrichten** (mit Whitelist am Socket): Nationswahl beim Beitritt, Quest annehmen,
  Quest abgeben, Wiedergutmachung wählen. Raten-Limit wie bei den bestehenden Nachrichten.
- **Ereignisse:** Ruf-Änderung, Fort-Warnung, Eroberung (Meldung an alle im Umkreis).

## 7. Tests (Anforderungen)

- Reine Funktionen für Gebiete, Ruf-Änderungen (inkl. Selbstverteidigung), Rufstufen, Quest-Erzeugung,
  Fortschritt, Rückfallregel; alle mit Tests, ohne Prozess.
- Profil-Migration: altes Profil ohne Nation und Ruf wird geladen.
- Kein Token in Schnappschüssen (Test existiert, muss für neue Felder weiterlaufen).
- Fort trifft den ersten Schuss, spätere Schüsse sind ausweichbar (Test mit festem Zufall).
- Eroberung: Fortschritt, Verteidiger, Schutzzeit, Rückfall bei Randlage, Bestand bei Binnenlage, defekte Datei.
- Lasttest (`scripts/load_test.exs`) muss weiterhin unter dem Tick-Budget bleiben; die Nation-Suche je Punkt
  darf nicht je Tick für jedes Schiff teuer sein (Ergebnis merken).

## 8. Dem Bauenden überlassen

Konkrete Zahlen (siehe Annahmen), Aufbau der Module und Dateinamen, Gestaltung von Startbildschirm,
Quest-Log und Eroberungsanzeige, Gestaltung der Flaggen, Texte, Rangfolge der Meldungen, und wie genau
Voronoi über Häfen berechnet und gemerkt wird. Reihenfolge der Bausteine ist festgelegt; innerhalb eines
Bausteins frei.

## 9. Kleinere Festlegungen des Entwurfsautors (zum Prüfen)

Diese Punkte hat der Entwurfsautor beim Gegenlesen als Lücke gefunden und selbst festgelegt; sie ändern
nichts an der Grundidee.

- **Gebiet ohne Hafen in der Nähe:** Gibt es im Suchradius (Annahme 120 WE) keinen Hafen, gilt die Nation der
  150-WE-Zelle des Punkts. So ist `Osp.Nations.at/3` für jeden Punkt definiert.
- **Angedockte Schiffe:** Ein angedocktes Schiff wird vom Fort nicht beschossen (sonst könnte man in
  feindlichen Häfen nicht einmal die Wiedergutmachungsquest annehmen). Das Fort feuert wieder, sobald das
  Schiff ablegt.
- **Wiedergutmachung abholen:** Die Quest gibt es im Hafen der Nation, bei der man Gesucht ist; Ziel ist ein
  anderer Hafen **derselben** Nation (Lieferung) oder Jäger einer dritten Nation (Jagd).
- **Quests und Selbstverteidigung:** Die Selbstverteidigungsregel gilt auch für Jagdquests. Ein Jäger, der
  den Spieler beschossen hat, kostet keinen Ruf, zählt aber trotzdem für die Quest.
- **Ruf der Eroberer-Nation nach der Eroberung:** Der Rufverlust bei der angegriffenen Nation entsteht
  durch die versenkten Schiffe, nicht durch die Eroberung selbst.
