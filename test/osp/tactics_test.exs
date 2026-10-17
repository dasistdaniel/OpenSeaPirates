defmodule Osp.TacticsTest do
  use ExUnit.Case, async: true

  alias Osp.{Combat, Hunter, Sailing, State}

  @seed 4
  @pi :math.pi()

  defp open_water do
    Enum.find_value(0..200, fn k ->
      x = k * 9.0
      y = k * 5.0
      if Osp.Spawn.clear?(@seed, x, y, 7.0), do: {x, y}
    end)
  end

  # a blickt nach Osten bei (bx, by); b steht 2 WE südlich (steuerbord) mit dem Kurs `b_heading`
  defp duel(b_heading) do
    {bx, by} = open_water()
    st = State.new(@seed, 0) |> State.join("a", "Anna") |> State.join("b", "Ben")

    place = fn st, id, x, y, h ->
      State.update_ship(st, id, fn s ->
        %{s | x: x, y: y, heading: h, speed: 0.0, invuln_until: 0, reload_l: 0, reload_r: 0}
      end)
    end

    st |> place.("a", bx, by, 0.0) |> place.("b", bx, by + 2.0, b_heading)
  end

  defp run(state, ms) do
    Enum.reduce(1..div(ms, 25), {state, []}, fn _, {s, ev} ->
      {s, more} = State.tick(s, 25)
      {s, ev ++ more}
    end)
  end

  describe "Ruderlegen kostet Fahrt" do
    @none %{up?: false, left?: false, right?: false}
    defp sail(keys, seconds) do
      Enum.reduce(1..round(seconds * 40), %{x: 0.0, y: 0.0, heading: 0.0, speed: 0.0}, fn _, s ->
        Sailing.step(s, keys, 0.025, @pi / 2, fn _, _ -> false end)
      end)
    end

    test "Dauerkreisen ist deutlich langsamer als Geradeausfahrt" do
      straight = sail(%{@none | up?: true}, 6.0).speed
      circling = sail(%{@none | up?: true, right?: true}, 6.0).speed
      assert straight > 1.95
      assert circling < straight * 0.7
      assert circling > 0.5
    end

    test "ohne Ruder gibt es keinen Abzug" do
      assert_in_delta sail(%{@none | up?: true}, 4.0).speed, Sailing.max_speed(), 0.01
    end
  end

  describe "Längsfeuer" do
    test "Breitseite quer auf die Seite des Ziels: normaler Schaden (3 Kugeln × 1,5)" do
      {st, ev} = run(elem(State.fire(duel(0.0), "a", :right), 0), 800)
      assert_in_delta st.ships["b"].hp, 12.0 - 4.5, 0.01
      refute Enum.any?(ev, &match?({:rake, _, _}, &1))
    end

    test "Treffer entlang der Schiffsachse (Ziel quer zur Salve) zählt doppelt und meldet :rake" do
      {st, ev} = run(elem(State.fire(duel(@pi / 2), "a", :right), 0), 800)
      assert_in_delta st.ships["b"].hp, 12.0 - 9.0, 0.01
      assert Enum.any?(ev, &match?({:rake, _, _}, &1))
    end

    test "Schnappschuss meldet das Längsfeuer-Ereignis" do
      st = duel(0.0)
      snap = State.snapshot_for(st, "a", [{:rake, 10.0, 20.0}])
      assert [["rake", 10.0, 20.0]] = snap.ev
    end
  end

  describe "Salven" do
    test "lange Ladezeit, kräftiger Schaden" do
      assert Combat.reload_ms() == 3_000
      {st, _} = State.fire(duel(0.0), "a", :right)
      assert st.ships["a"].reload_r == 3_000
      assert Enum.all?(st.balls, &(&1.dmg == 1.5))
    end
  end

  describe "Angriffslauf" do
    defp water(_x, _y), do: false

    defp npc(opts),
      do:
        Map.merge(
          %{x: 0.0, y: 0.0, heading: 0.0, speed: 1.5, reload_l: 0, reload_r: 0},
          Map.new(opts)
        )

    test "weit weg: Anflug direkt auf den Gegner" do
      {keys, fires, run} = Hunter.attack(npc([]), %{x: 20.0, y: 0.0}, &water/2, 0)
      assert run.phase == :approach and fires == [] and keys.up?
    end

    test "nah: Vorbeilauf; abgefeuert (zugewandte Seite leer) beendet er ihn und dreht ab" do
      enemy = %{x: 0.0, y: 3.5}
      {_, _, run} = Hunter.attack(npc([]), enemy, &water/2, 0)
      assert run.phase == :pass

      # rechte Seite (zum Gegner) hat gefeuert -> Abdrehen
      {_, _, run2} = Hunter.attack(npc(run: run, reload_r: 3_000), enemy, &water/2, 500)
      assert run2.phase == :break
    end

    test "Abdrehen: weg vom Gegner; erst mit Abstand und geladenen Kanonen folgt der nächste Anlauf" do
      brk = %{phase: :break, at: 0}
      near = %{x: 0.0, y: 4.0}
      far = %{x: 0.0, y: 9.0}

      {keys, _, run} = Hunter.attack(npc(run: brk, heading: @pi / 2), near, &water/2, 1_000)
      # Gegner liegt unten, das Schiff blickt nach unten: es muss wenden
      assert run.phase == :break and (keys.left? or keys.right?)

      {_, _, still} =
        Hunter.attack(npc(run: brk, reload_l: 2_000, reload_r: 2_000), far, &water/2, 1_000)

      assert still.phase == :break

      {_, _, again} = Hunter.attack(npc(run: brk), far, &water/2, 1_000)
      assert again.phase == :approach
    end

    test "Zeitlimit: kein endloses Kreisen im Vorbeilauf" do
      pass = %{phase: :pass, at: 0}
      {_, _, run} = Hunter.attack(npc(run: pass), %{x: 0.0, y: 3.5}, &water/2, 7_000)
      assert run.phase == :break
    end

    test "feuert mit Vorhalt: Ziel leicht vor der Querabrichtung" do
      # bei Tempo 1,5 liegt der ideale Winkel etwa 0,24 rad vor dem rechten Winkel
      lead = :math.atan(0.8 * 1.5 / 6.0)
      ang = @pi / 2 - lead
      enemy = %{x: :math.cos(ang) * 3.5, y: :math.sin(ang) * 3.5}
      {_, fires, _} = Hunter.attack(npc([]), enemy, &water/2, 0)
      assert fires == [:right]

      # exakt querab schießt er noch nicht: Kugeln flögen am Ziel vorbei
      {_, fires, _} = Hunter.attack(npc([]), %{x: 0.0, y: 3.5}, &water/2, 0)
      assert fires == []
    end
  end

  test "im Spiel: Jäger fahren Läufe (wechseln Phasen) statt dauerhaft in einer zu bleiben" do
    {bx, by} = open_water()
    st = State.new(@seed, 0) |> State.join("a", "Anna")
    # Misstrauisch bei allen Nationen: Jäger greifen an
    rep = Map.new(Osp.Nations.all(), &{&1, -20})

    st =
      State.update_ship(st, "a", &%{&1 | x: bx, y: by, invuln_until: 0, heading: 0.0, rep: rep})

    st = State.add_npc(st, :hunter, "Jäger", bx + 7.0, by + 1.0, @pi)

    {_st, phases} =
      Enum.reduce(1..div(40_000, 25), {st, MapSet.new()}, fn i, {s, set} ->
        {s, _} = State.tick(s, 25)
        h = s.ships["npc-1"]
        {s, if((rem(i, 20) == 0 and h) && h.run, do: MapSet.put(set, h.run.phase), else: set)}
      end)

    assert MapSet.size(phases) >= 2
  end
end
