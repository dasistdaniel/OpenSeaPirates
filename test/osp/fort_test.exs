defmodule Osp.FortTest do
  use ExUnit.Case, async: true

  alias Osp.{Fort, Nations, Profile, Spawn, State}

  @seed 4
  @tok "geheimes-token-fort-1"

  # Ein englischer Hafen und ein Punkt auf seiner Seeseite (gegenüber der Küste), `d` WE vom Anker
  defp spot do
    port = Nations.nearest_port_of(@seed, :england, {0.0, 0.0}, 1500.0)

    Enum.find_value([5.0, 4.5, 5.5, 4.0, 6.0, 6.5], fn d ->
      x = port.x - :math.cos(port.land) * d
      y = port.y - :math.sin(port.land) * d
      mid = {(port.x + x) / 2, (port.y + y) / 2}

      if Spawn.clear?(@seed, x, y, 0.8) and Spawn.clear?(@seed, elem(mid, 0), elem(mid, 1), 0.8),
        do: {port, x, y, d}
    end)
  end

  # Spieler (Heimat Frankreich), bei England `rep`, am Punkt `{x, y}`; Zeit so, dass der Schuss fällig ist
  defp scene(rep \\ -60, extra \\ %{}, at \\ nil) do
    {port, x, y, _d} = spot()
    {px, py} = at || {x, y}

    st =
      State.new(@seed, 0)
      |> State.join(@tok, "Anna", Profile.decode(%{"nation" => "france"}))
      |> State.update_ship(@tok, fn s ->
        Map.merge(
          %{
            s
            | x: px,
              y: py,
              speed: 0.0,
              heading: 0.0,
              invuln_until: 0,
              rep: %{s.rep | england: rep}
          },
          extra
        )
      end)

    {st, port}
  end

  defp seen_long_ago(state, port, shots \\ %{}) do
    %{
      state
      | time: 2_000,
        forts: %{
          port.id => %{cooldown_until: 0, seen: %{@tok => 0}, shots: shots, alarm_until: %{}}
        }
    }
  end

  defp tick(state, ms),
    do:
      Enum.reduce(1..div(ms, 25), {state, []}, fn _, {s, ev} ->
        {s, more} = State.tick(s, 25)
        {s, ev ++ more}
      end)

  defp fort_fires(ev), do: Enum.filter(ev, &match?({:fire, "fort:" <> _, :fort, _, _}, &1))
  defp fort_balls(st), do: Enum.filter(st.balls, &(&1.owner_kind == :fort))

  describe "Ablauf" do
    test "Warnung sofort, erster Schuss frühestens nach 1,5 s, Kugel mit Fort-Besitzer und Schaden 3" do
      {st, port} = scene()
      {st, ev} = tick(st, 25)
      assert Enum.any?(ev, &match?({:fort_warn, _, @tok, _, _}, &1))
      assert fort_balls(st) == []

      {st, ev} = tick(st, 1_300)
      assert fort_fires(ev) == []

      {st, ev} = tick(st, 400)
      assert [{:fire, owner, :fort, _, _}] = fort_fires(ev)
      assert owner == "fort:" <> port.id
      assert [%{owner: ^owner, dmg: 3.0, owner_kind: :fort}] = fort_balls(st)
    end

    test "stehendes Ziel: der erste Schuss trifft (3 HP)" do
      {st, _} = scene()
      {st, _} = tick(st, 3_500)
      assert st.ships[@tok].hp == 9.0
    end

    test "Nachladen: zwischen zwei Schüssen mindestens 5 s" do
      {st, _} = scene()

      {_st, times} =
        Enum.reduce(1..div(14_000, 25), {st, []}, fn _, {s, acc} ->
          {s, ev} = State.tick(s, 25)
          {s, if(fort_fires(ev) != [], do: acc ++ [s.time], else: acc)}
        end)

      assert length(times) >= 2

      for {a, b} <- Enum.zip(times, tl(times)),
          do: assert(b - a >= 5_000, "Abstand #{b - a} ms")
    end
  end

  describe "Vorhalt" do
    test "fire_velocity/3: mit Vorhalt ein Treffer, ohne Vorhalt knapp daneben" do
      port = %{x: 0.0, y: 0.0}
      target = %{x: 0.0, y: 6.0, heading: 0.0, speed: 1.5}

      miss = fn lead? ->
        {vx, vy} = Fort.fire_velocity(port, target, lead?)

        for k <- 0..300 do
          t = k * 0.01
          {bx, by} = {vx * t, vy * t}
          {tx, ty} = {target.x + 1.5 * t, target.y}
          :math.sqrt((bx - tx) * (bx - tx) + (by - ty) * (by - ty))
        end
        |> Enum.min()
      end

      assert miss.(true) < 0.3
      assert miss.(false) > 0.8
    end

    test "erster Schuss auf einen Spieler mit Vorhalt, spätere auf die aktuelle Position" do
      {st, port} = scene(-60, %{speed: 1.5, heading: 0.0})
      first = seen_long_ago(st, port)
      {st1, _} = Fort.step(first)
      [ball1] = fort_balls(st1)
      p = first.ships[@tok]
      assert {ball1.vx, ball1.vy} == Fort.fire_velocity(port, p, true)

      second = seen_long_ago(st, port, %{@tok => 1})
      {st2, _} = Fort.step(second)
      [ball2] = fort_balls(st2)
      assert {ball2.vx, ball2.vy} == Fort.fire_velocity(port, p, false)
    end

    test "Kugelgeschwindigkeit ist 6 WE/s" do
      {vx, vy} =
        Fort.fire_velocity(%{x: 1.0, y: 1.0}, %{x: 4.0, y: 5.0, heading: 0.3, speed: 1.0}, true)

      assert_in_delta :math.sqrt(vx * vx + vy * vy), 6.0, 1.0e-9
    end
  end

  describe "Nachladezeit" do
    test "ein Schuss je 5 s und Fort" do
      {st, port} = scene()
      st = seen_long_ago(st, port)
      {st, ev1} = Fort.step(st)
      assert length(fort_fires(ev1)) == 1

      {st, ev2} = Fort.step(%{st | time: 2_100})
      assert fort_fires(ev2) == []
      assert length(fort_balls(st)) == 1

      {st, ev3} = Fort.step(%{st | time: 7_100})
      assert length(fort_fires(ev3)) == 1
      assert length(fort_balls(st)) == 2
    end
  end

  describe "keine Schüsse" do
    defp quiet?(st, port) do
      {st2, ev} = Fort.step(seen_long_ago(st, port))
      fort_balls(st2) == [] and fort_fires(ev) == []
    end

    test "angedockt, tot, unverwundbar, Misstrauisch, zu weit weg" do
      {docked, port} = scene(-60, %{docked: %{id: "x", name: "Test", nation: :england}})
      assert quiet?(docked, port)

      {dead, _} = scene(-60, %{alive?: false})
      assert quiet?(dead, port)

      {invuln, _} = scene(-60, %{invuln_until: 10_000_000})
      assert quiet?(invuln, port)

      {suspicious, _} = scene(-39)
      assert quiet?(suspicious, port)

      {far, _} = scene(-60, %{}, {port.x + 30.0, port.y + 30.0})
      assert quiet?(far, port)
    end

    test "Gesucht bei England, aber der Hafen in Reichweite ist französisch" do
      french = Nations.nearest_port_of(@seed, :france, {0.0, 0.0}, 1500.0)
      {st, _} = scene(-80, %{}, {french.x + 3.0, french.y})
      {st2, ev} = Fort.step(%{st | time: 2_000})
      assert fort_balls(st2) == [] and fort_fires(ev) == []
      refute Enum.any?(ev, &match?({:fort_warn, _, _, _, _}, &1))
    end

    test "ohne Gesuchte rechnet das Fort nichts" do
      st = State.new(@seed, 0) |> State.join(@tok, "A", Profile.decode(%{"nation" => "france"}))
      assert {^st, []} = Fort.step(st)
    end
  end

  describe "Alarm" do
    test "Betreten der Schutzzone ruft zwei Jäger der Hafen-Nation, 10–20 WE vom Spieler" do
      {port, _, _, _} = spot()
      {st, _} = scene(-60, %{}, {port.x + 1.0, port.y})
      before = map_size(st.ships)
      {st, _} = Fort.step(%{st | time: 100})

      hunters = st.ships |> Map.values() |> Enum.filter(&(&1.kind == :hunter))
      assert length(hunters) == 2 and map_size(st.ships) == before + 2
      assert Enum.all?(hunters, &(&1.nation == :england))
      p = st.ships[@tok]

      for h <- hunters do
        d = :math.sqrt(:math.pow(h.x - p.x, 2) + :math.pow(h.y - p.y, 2))
        assert d >= 9.9 and d <= 20.5
      end
    end

    test "nicht in der Zone, nur in Reichweite: Warnung und Schüsse, aber kein Alarm" do
      {st, _} = scene()
      {st, _} = tick(st, 2_000)
      assert st.ships |> Map.values() |> Enum.count(&(&1.kind == :hunter)) == 0
    end

    test "Pause 3 Minuten je Spieler und Hafen, danach wieder" do
      {port, _, _, _} = spot()
      {st, _} = scene(-60, %{}, {port.x + 1.0, port.y})
      hunters = fn s -> s.ships |> Map.values() |> Enum.count(&(&1.kind == :hunter)) end

      {st, _} = Fort.step(%{st | time: 100})
      assert hunters.(st) == 2

      # gleiche Anwesenheit: kein neuer Alarm
      {st, _} = Fort.step(%{st | time: 200})
      assert hunters.(st) == 2

      # hinausfahren (außer Reichweite), nach 60 s zurück: noch Pause
      out = State.update_ship(st, @tok, &%{&1 | x: port.x + 50.0, y: port.y})
      {out, _} = Fort.step(%{out | time: 30_000})
      back = State.update_ship(out, @tok, &%{&1 | x: port.x + 1.0, y: port.y})
      {back, _} = Fort.step(%{back | time: 60_000})
      assert hunters.(back) == 2

      # nach Ablauf der Pause wieder
      {later, _} = Fort.step(%{back | time: 200_000})
      assert hunters.(later) == 4
    end
  end

  test "Fort-Kugeln verletzen keine NPCs" do
    {st, port} = scene(0)
    target = %{x: port.x + 3.0, y: port.y}

    st =
      st
      |> State.add_npc(:hunter, "Jäger", target.x, target.y, 0.0, 0, :england)
      |> State.update_ship("npc-1", &%{&1 | invuln_until: 0})

    ball = %{
      id: 99,
      owner: "fort:" <> port.id,
      owner_kind: :fort,
      x: port.x,
      y: port.y,
      vx: 6.0,
      vy: 0.0,
      ttl: 1_500,
      dmg: 3.0,
      r: 0.08,
      ammo: :ball
    }

    st = %{st | balls: [ball]}
    {st, _} = tick(st, 800)
    assert st.ships["npc-1"].hp == st.ships["npc-1"].max_hp
  end

  test "Schnappschuss mit Fort-Ereignissen: kein Token, Ereignisse als Listen" do
    {st, port} = scene()
    p = st.ships[@tok]

    events = [
      {:fort_warn, port.id, @tok, p.x, p.y},
      {:fire, "fort:" <> port.id, :fort, port.x, port.y}
    ]

    snap = State.snapshot_for(st, @tok, events)
    json = Jason.encode!(snap)
    refute json =~ "geheimes-token"
    pub = State.public_id(@tok)
    assert [["fort_warn", _, ^pub, _, _], ["fire", "fort:" <> _, "fort", _, _]] = snap.ev
  end
end
