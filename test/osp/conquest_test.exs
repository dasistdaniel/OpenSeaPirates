defmodule Osp.ConquestTest do
  use ExUnit.Case, async: true

  alias Osp.{Combat, Conquest, Fort, Nations, Profile, State}

  @seed 4
  @wall 10_000_000_000

  defp port, do: Nations.nearest_port_of(@seed, :england, {0.0, 0.0}, 1500.0)

  # Punkt auf der Seeseite des Hafens, `d` WE vom Anker, `k` Schritte seitlich versetzt
  defp spot(p, d, k \\ 0) do
    {cx, cy} = {:math.cos(p.land), :math.sin(p.land)}
    {p.x - cx * d - cy * k * 0.6, p.y - cy * d + cx * k * 0.6}
  end

  defp new_state(opts \\ []), do: %{State.new(@seed, 0, opts) | wall_ms: @wall}

  # Spieler mit Heimatnation `nation` (Atom), Token `tok`, an `{x, y}`
  defp join(st, tok, nation, {x, y}, extra \\ %{}) do
    st
    |> State.join(tok, "N-#{tok}", Profile.decode(%{"nation" => Atom.to_string(nation)}))
    |> State.update_ship(tok, fn s ->
      Map.merge(
        %{s | x: x, y: y, speed: 0.0, heading: 0.0, invuln_until: 0, reload_l: 0, reload_r: 0},
        extra
      )
    end)
  end

  defp run(state, ms) do
    Enum.reduce(1..div(ms, 25), {state, []}, fn _, {s, ev} ->
      {s, more} = State.tick(s, 25)
      {s, ev ++ more}
    end)
  end

  defp ev?(events, pattern_fun), do: Enum.any?(events, pattern_fun)

  describe "protected?/2" do
    test "Wanduhr: direkt nach der Eroberung ja, nach 20 Minuten nein, Uhr zurück weiterhin ja" do
      st = %{new_state() | captured_at: %{"port:1,1" => 1_000}}
      assert Conquest.protected?(%{st | wall_ms: 1_000 + 1_000_000}, "port:1,1")
      refute Conquest.protected?(%{st | wall_ms: 1_000 + 1_200_000}, "port:1,1")
      assert Conquest.protected?(%{st | wall_ms: 500}, "port:1,1")
      refute Conquest.protected?(st, "port:2,2")
    end
  end

  describe "attacker?/3" do
    test "nur lebende, nicht angedockte Spieler mit fremder Heimatnation" do
      p = port()

      st =
        new_state()
        |> join("a-fr", :france, spot(p, 5.0))
        |> join("a-en", :england, spot(p, 5.0, 1))

      fr = st.ships["a-fr"]
      en = st.ships["a-en"]

      assert Conquest.attacker?(st, fr, p)
      refute Conquest.attacker?(st, en, p)
      refute Conquest.attacker?(st, %{fr | alive?: false}, p)
      refute Conquest.attacker?(st, %{fr | docked: %{id: "x", name: "T", nation: :england}}, p)
      refute Conquest.attacker?(st, %{fr | kind: :hunter}, p)
      refute Conquest.attacker?(st, %{fr | nation: nil}, p)
    end

    test "gegenüber dem neuen Besitzer zählt dessen Nation" do
      p = port()

      st =
        new_state(territory: %{p.id => %{owner: :france, since: 1}})
        |> join("a-fr", :france, spot(p, 5.0))

      refute Conquest.attacker?(st, st.ships["a-fr"], p)
    end
  end

  describe "Angriffsbeginn" do
    test "Schuss eines Fremden in 8 WE startet den Angriff mit Ereignis" do
      p = port()
      {x, y} = spot(p, 6.5)
      st = new_state() |> join("a-fr", :france, {x, y})
      {st, ev} = Conquest.hostile_act(st, "a-fr", x, y)
      assert Map.has_key?(st.assaults, p.id)
      assert ev?(ev, &match?({:assault, _, :england, _, _}, &1))
      assert st.assaults[p.id].first_nation == :france
    end

    test "über Combat.fire: Breitseite im Umkreis startet den Angriff" do
      p = port()
      st = new_state() |> join("a-fr", :france, spot(p, 6.5))
      {st, ev} = State.fire(st, "a-fr", :right)
      assert Map.has_key?(st.assaults, p.id)
      assert ev?(ev, &match?({:assault, _, _, _, _}, &1))
    end

    test "kein Angriff durch Heimatspieler, Gesuchte-Weg, weite Entfernung, Schutzzeit, NPCs" do
      p = port()
      {x, y} = spot(p, 6.5)
      home = new_state() |> join("h", :england, {x, y})
      assert {^home, []} = Conquest.hostile_act(home, "h", x, y)

      far = new_state() |> join("a", :france, spot(p, 30.0))
      {fx, fy} = spot(p, 30.0)
      assert {^far, []} = Conquest.hostile_act(far, "a", fx, fy)

      prot = %{new_state() | captured_at: %{p.id => @wall - 1_000}} |> join("a", :france, {x, y})
      assert {^prot, []} = Conquest.hostile_act(prot, "a", x, y)

      npc = new_state() |> State.add_npc(:hunter, "J", x, y, 0.0, 0, :france)
      assert {^npc, []} = Conquest.hostile_act(npc, "npc-1", x, y)
    end

    test "ein Besuch ohne Schuss startet nichts, das Fort schießt nicht auf Gäste" do
      p = port()
      st = new_state() |> join("a-fr", :france, spot(p, 5.0))
      {st, ev} = run(st, 5_000)
      assert st.assaults == %{}
      assert st.balls == [] and st.ships["a-fr"].hp == st.ships["a-fr"].max_hp
      refute ev?(ev, &match?({:fire, "fort:" <> _, _, _, _}, &1))
    end
  end

  describe "Fort und Schutz im Angriff" do
    defp assault(st, tok) do
      s = st.ships[tok]
      {st, _} = Conquest.hostile_act(st, tok, s.x, s.y)
      st
    end

    test "schießt auf alle Fremden in Reichweite, nicht auf Heimatspieler; Nachladen 2 s" do
      p = port()

      st =
        new_state()
        |> join("a-fr", :france, spot(p, 5.0))
        |> join("h-en", :england, spot(p, 5.0, 3))
        |> assault("a-fr")

      {st, ev} = run(st, 4_500)
      fires = for {:fire, "fort:" <> _, :fort, _, _} <- ev, do: :f
      assert length(fires) >= 2
      assert st.ships["h-en"].hp == st.ships["h-en"].max_hp
      assert st.ships["a-fr"].hp < st.ships["a-fr"].max_hp
    end

    test "Nachladezeit im Angriff 2000 ms" do
      p = port()
      st = new_state() |> join("a-fr", :france, spot(p, 5.0)) |> assault("a-fr")

      st = %{
        st
        | time: 2_000,
          forts: %{
            p.id => %{cooldown_until: 0, seen: %{"a-fr" => 0}, shots: %{}, alarm_until: %{}}
          }
      }

      {st, _} = Fort.step(st)
      assert st.forts[p.id].cooldown_until == 2_000 + Conquest.cooldown_ms()
      assert Conquest.cooldown_ms() == 2_000
    end

    test "Angreifer sind in der Zone ungeschützt und dürfen feuern, Heimatspieler bleiben geschützt" do
      p = port()
      {zx, zy} = spot(p, 2.0)

      st =
        new_state()
        |> join("a-fr", :france, spot(p, 5.0))
        |> join("zone-fr", :france, {zx, zy})
        |> join("zone-en", :england, spot(p, 2.0, 2))
        |> assault("a-fr")

      assert State.safe_for?(st, st.ships["zone-fr"]) == false
      assert State.safe_for?(st, st.ships["zone-en"]) == true
      assert {_, [{:fire, "zone-fr", _, _, _} | _]} = State.fire(st, "zone-fr", :right)
    end
  end

  describe "Fortschritt" do
    defp progress(st, p), do: st.assaults[p.id].progress

    test "ein Angreifer ohne Verteidiger: +1,5 %/s, zwei Angreifer doppelt" do
      p = port()
      one = new_state() |> join("a1", :france, spot(p, 5.0)) |> assault("a1")
      # keine Verteidiger: der erste Schub wird entfernt
      one = clear_defenders(one)
      {one, _} = run_keep(one, 10_000, p)
      assert_in_delta progress(one, p), 15.0, 1.0

      two =
        new_state()
        |> join("a1", :france, spot(p, 5.0))
        |> join("a2", :france, spot(p, 5.0, 2))
        |> assault("a1")

      two = clear_defenders(two)
      {two, _} = run_keep(two, 10_000, p)
      assert_in_delta progress(two, p), 30.0, 2.0
    end

    # Schritt für Schritt: Verteidiger-Welle und Fort-Schaden sollen den Fortschritt nicht stören
    defp run_keep(st, ms, p) do
      Enum.reduce(1..div(ms, 25), {st, []}, fn _, {s, ev} ->
        s = keep_alive(s, p)
        {s, more} = Conquest.step(s, 25)
        {s, ev ++ more}
      end)
    end

    defp keep_alive(s, p) do
      # Angreifer unverwundbar und Verteidiger entfernt halten, um nur die Fortschrittsrechnung zu prüfen
      ships =
        Map.new(s.ships, fn
          {id, %{kind: :player} = sh} -> {id, %{sh | hp: sh.max_hp * 1.0}}
          other -> other
        end)

      clear_defenders(%{
        s
        | ships: ships,
          assaults: Map.update!(s.assaults, p.id, &%{&1 | wave_at: s.time + 100_000})
      })
    end

    defp clear_defenders(s),
      do: %{s | ships: Map.reject(s.ships, fn {_, sh} -> sh.kind == :hunter end)}

    test "mit lebendem Verteidiger steht der Fortschritt still" do
      p = port()
      st = new_state() |> join("a1", :france, spot(p, 5.0)) |> assault("a1") |> clear_defenders()
      {x, y} = spot(p, 15.0)
      st = State.add_npc(st, :hunter, "Wache", x, y, 0.0, 0, :england)
      st = %{st | assaults: Map.update!(st.assaults, p.id, &%{&1 | wave_at: st.time + 1_000_000})}
      {st, _} = Conquest.step(st, 25)
      {st, _} = Conquest.step(%{st | time: st.time + 5_000}, 25)
      assert progress(st, p) == 0.0
    end

    test "Jäger anderer Nationen oder außerhalb 40 WE zählen nicht als Verteidiger" do
      p = port()
      st = new_state() |> join("a1", :france, spot(p, 5.0)) |> assault("a1") |> clear_defenders()
      {x, y} = spot(p, 15.0)
      st = State.add_npc(st, :hunter, "Fremd", x, y, 0.0, 0, :spain)
      {fx, fy} = spot(p, 60.0)
      st = State.add_npc(st, :hunter, "Fern", fx, fy, 0.0, 0, :england)
      st = %{st | assaults: Map.update!(st.assaults, p.id, &%{&1 | wave_at: st.time + 1_000_000})}
      {st, _} = Conquest.step(st, 1_000)
      assert progress(st, p) > 1.0
    end

    test "ohne Angreifer sinkt er um 0,5 %/s bis 0; der Angriff endet nach 60 s ohne Handlung" do
      p = port()
      st = new_state() |> join("a1", :france, spot(p, 5.0)) |> assault("a1") |> clear_defenders()

      st = %{
        st
        | assaults:
            Map.update!(st.assaults, p.id, &%{&1 | progress: 20.0, wave_at: st.time + 1_000_000})
      }

      st = State.update_ship(st, "a1", &%{&1 | alive?: false})

      {st, _} = Conquest.step(st, 10_000)
      assert_in_delta progress(st, p), 15.0, 0.1

      {st, _} = Conquest.step(st, 40_000)
      assert progress(st, p) == 0.0
      assert Map.has_key?(st.assaults, p.id)

      {st, ev} = Conquest.step(%{st | time: st.time + 61_000}, 25)
      assert st.assaults == %{}
      assert ev?(ev, &match?({:assault_end, _, _, _}, &1))
    end
  end

  describe "Verteidiger-Wellen" do
    test "zwei Jäger der Besitzer-Nation gleich zu Beginn, dann alle 45 s, höchstens sechs" do
      p = port()
      st = new_state() |> join("a1", :france, spot(p, 5.0))
      {st, _} = Conquest.hostile_act(st, "a1", spot(p, 5.0) |> elem(0), spot(p, 5.0) |> elem(1))

      hunters = fn s ->
        s.ships |> Map.values() |> Enum.filter(&(&1.kind == :hunter and &1.nation == :england))
      end

      {st, _} = Conquest.step(st, 25)
      assert length(hunters.(st)) == 2

      {st, _} = Conquest.step(%{st | time: st.time + 44_000}, 25)
      assert length(hunters.(st)) == 2

      {st, _} = Conquest.step(%{st | time: st.time + 2_000}, 25)
      assert length(hunters.(st)) == 4

      st =
        Enum.reduce(1..5, st, fn _, s ->
          elem(Conquest.step(%{s | time: s.time + 50_000}, 25), 0)
        end)

      assert length(hunters.(st)) <= 6
    end
  end

  describe "Eroberung" do
    defp ready_to_capture(st, p),
      do: %{
        st
        | assaults:
            Map.update!(st.assaults, p.id, &%{&1 | progress: 99.9, wave_at: st.time + 1_000_000})
      }

    test "bei 100 % gewinnt die Nation mit den meisten Angreifern in der Zone" do
      p = port()

      st =
        new_state()
        |> join("f1", :france, spot(p, 5.0))
        |> join("f2", :france, spot(p, 5.0, 2))
        |> join("s1", :spain, spot(p, 5.0, 4))
        |> assault("f1")
        |> clear_defenders()

      st = ready_to_capture(st, p)
      {st, ev} = Conquest.step(st, 100)
      assert st.owners[p.id] == :france
      assert st.captured_at[p.id] == @wall
      assert ev?(ev, &match?({:captured, _, :france, :england, @wall, _, _}, &1))
      refute Map.has_key?(st.assaults, p.id)
      assert Conquest.protected?(st, p.id)
    end

    test "Gleichstand: die Nation der ersten Angriffshandlung" do
      p = port()

      st =
        new_state()
        |> join("s1", :spain, spot(p, 5.0))
        |> join("f1", :france, spot(p, 5.0, 2))
        |> assault("s1")
        |> clear_defenders()

      {st, _} = Conquest.step(ready_to_capture(st, p), 100)
      assert st.owners[p.id] == :spain
    end

    test "Belohnung genau einmal: 300 Gold und Ruf +10 bei der Heimatnation, nur Angreifer in der Zone" do
      p = port()
      {fx, fy} = spot(p, 7.5)

      st =
        new_state()
        |> join("f1", :france, spot(p, 5.0))
        |> join("far", :france, {fx, fy})
        |> join("dead", :france, spot(p, 5.0, 2), %{alive?: false})
        |> join("dock", :france, spot(p, 5.0, 3), %{
          docked: %{id: "x", name: "T", nation: :england}
        })
        |> assault("f1")
        |> clear_defenders()

      {st, ev} = Conquest.step(ready_to_capture(st, p), 100)
      assert st.ships["f1"].gold == 300 and st.ships["f1"].rep.france == 30
      for id <- ["far", "dead", "dock"], do: assert(st.ships[id].gold == 0, id)
      assert ev?(ev, &match?({:rep, "f1", :france, 10, _, _, _}, &1))

      {st2, ev2} = Conquest.step(st, 100)
      assert st2.ships["f1"].gold == 300
      refute ev?(ev2, &match?({:captured, _, _, _, _, _, _}, &1))
    end

    test "Eroberung durch die Ausgangsnation entfernt die Abweichung" do
      p = port()

      st =
        new_state(territory: %{p.id => %{owner: :spain, since: 1}})
        |> then(&%{&1 | captured_at: %{p.id => 1}})
        |> join("e1", :england, spot(p, 5.0))
        |> assault("e1")
        |> clear_defenders()

      {st, _} = Conquest.step(ready_to_capture(st, p), 100)
      refute Map.has_key?(st.owners, p.id)
      refute Map.has_key?(st.captured_at, p.id)
      assert State.port_nation(st, p) == :england
    end
  end

  test "Einzelspieler (Schaluppe, 12 HP) erobert nichts: in 120 s tot oder nicht am Ziel" do
    p = port()
    st = new_state() |> join("solo", :france, spot(p, 5.0)) |> assault("solo")
    {st, ev} = run(st, 120_000)
    assert st.owners == %{}
    refute ev?(ev, &match?({:captured, _, _, _, _, _, _}, &1))
  end

  test "Fort und Verteidiger lassen Heimatspieler und Schutzzeit-Häfen in Ruhe" do
    p = port()

    st =
      %{new_state() | captured_at: %{p.id => @wall - 1_000}} |> join("a", :france, spot(p, 5.0))

    {st, _} = State.fire(st, "a", :right)
    assert st.assaults == %{}
    _ = Combat
  end

  describe "Rückfall" do
    @min 60_000

    defp all_ports, do: Osp.Ports.near(@seed, 0.0, 0.0, 1500.0)

    defp other_than(nations), do: Enum.find(Nations.all(), &(&1 not in nations))

    test "neighbors/2: ohne den Hafen selbst, nur bis 90 WE" do
      a = Enum.find(all_ports(), &(Conquest.neighbors(@seed, &1) != []))
      ns = Conquest.neighbors(@seed, a)
      refute Enum.any?(ns, &(&1.id == a.id))

      assert Enum.all?(
               ns,
               &(:math.sqrt(:math.pow(&1.x - a.x, 2) + :math.pow(&1.y - a.y, 2)) <= 90.0)
             )
    end

    test "stable?/3: alle Nachbarn gleicher Besitzer ja, ein anderer nein, ohne Nachbarn ja" do
      a = Enum.find(all_ports(), &(Conquest.neighbors(@seed, &1) != []))
      ns = Conquest.neighbors(@seed, a)
      x = other_than(Enum.map([a | ns], &Nations.base_of_port(@seed, &1)))

      all_x = Map.new([a | ns], &{&1.id, x})
      assert Conquest.stable?(@seed, a, all_x)
      assert Conquest.stable?(@seed, a, Map.delete(all_x, hd(ns).id)) == false

      isolated = Enum.find(all_ports(), &(Conquest.neighbors(@seed, &1) == []))
      if isolated, do: assert(Conquest.stable?(@seed, isolated, %{isolated.id => x}))
    end

    # Ein Hafen, dessen Nachbarn alle einer anderen Nation (als `x`) gehören, ist nie stabil
    defp unstable_port do
      Enum.find(all_ports(), &(Conquest.neighbors(@seed, &1) != []))
    end

    test "reversions/4: Randlage nach 31 Minuten ja, nach 29 nein; Binnenlage bleibt; Uhr zurück nichts" do
      a = unstable_port()
      ns = Conquest.neighbors(@seed, a)
      x = other_than(Enum.map([a | ns], &Nations.base_of_port(@seed, &1)))

      edge = %{a.id => x}
      assert Conquest.reversions(@seed, edge, %{a.id => 0}, 31 * @min) == [a.id]
      assert Conquest.reversions(@seed, edge, %{a.id => 0}, 29 * @min) == []

      inner = Map.new([a | ns], &{&1.id, x})
      since = Map.new([a | ns], &{&1.id, 0})
      refute a.id in Conquest.reversions(@seed, inner, since, 500 * @min)

      assert Conquest.reversions(@seed, edge, %{a.id => 10_000_000}, 5_000) == []
    end

    test "keine Kette im selben Durchlauf: entschieden wird nach dem Stand am Anfang" do
      # a hat mindestens zwei Nachbarn; b hat nur a als Nachbarn
      pair =
        Enum.find_value(all_ports(), fn a ->
          ns = Conquest.neighbors(@seed, a)

          Enum.find_value(ns, fn b ->
            if length(ns) >= 2 and Enum.map(Conquest.neighbors(@seed, b), & &1.id) == [a.id],
              do: {a, b}
          end)
        end)

      assert {a, b} = pair
      others = Conquest.neighbors(@seed, a) |> Enum.reject(&(&1.id == b.id))
      x = other_than(Enum.map([a, b | others], &Nations.base_of_port(@seed, &1)))

      owners = %{a.id => x, b.id => x}
      since = %{a.id => 0, b.id => 0}

      # a hat Nachbarn mit anderer Nation: instabil; b hat nur a (gleicher Besitzer): stabil
      first = Conquest.reversions(@seed, owners, since, 40 * @min)
      assert first == [a.id]

      # nächster Durchlauf mit dem neuen Stand: jetzt ist b allein und instabil
      second =
        Conquest.reversions(@seed, Map.delete(owners, a.id), Map.delete(since, a.id), 41 * @min)

      assert second == [b.id]
    end
  end
end
