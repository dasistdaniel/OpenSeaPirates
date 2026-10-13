defmodule Osp.CombatTest do
  use ExUnit.Case, async: true

  alias Osp.{Combat, State}

  @seed 4

  # Offenes Wasser rund um (bx, by) suchen
  defp open_water do
    Enum.find_value(0..200, fn k ->
      x = k * 9.0
      y = k * 5.0
      if Osp.Spawn.clear?(@seed, x, y, 7.0), do: {x, y}
    end)
  end

  # Zwei Spieler: a bei (bx, by) blickt nach Osten (Kurs 0), b zwei WE südlich (Bildschirm: unten)
  # = Steuerbord (rechts) von a. Beide ohne Schonzeit.
  defp scene(opts \\ []) do
    {bx, by} = open_water()
    state = State.new(@seed, 0)
    state = state |> State.join("a", "Anna") |> State.join("b", "Ben")

    place = fn st, id, x, y, heading ->
      State.update_ship(st, id, fn s ->
        %{s | x: x, y: y, heading: heading, speed: 0.0, invuln_until: 0, reload_l: 0, reload_r: 0}
      end)
    end

    state
    |> place.("a", bx, by, 0.0)
    |> place.("b", bx + Keyword.get(opts, :dx, 0.0), by + Keyword.get(opts, :dy, 2.0), 0.0)
  end

  defp run(state, ms) do
    Enum.reduce(1..div(ms, 25), {state, []}, fn _, {s, ev} ->
      {s, more} = State.tick(s, 25)
      {s, ev ++ more}
    end)
  end

  defp put(state, id, fields), do: State.update_ship(state, id, &Map.merge(&1, Map.new(fields)))

  test "E (rechts) feuert 3 Kugeln nach rechts, Q nach links (Kurs Ost, y wächst nach unten)" do
    {s, ev} = State.fire(scene(), "a", :right)
    assert [{:fire, "a", :right, _, _}] = ev
    assert length(s.balls) == 3
    assert Enum.all?(s.balls, &(&1.vy > 4.0 and abs(&1.vx) < 0.5))

    {s, _} = State.fire(scene(), "a", :left)
    assert Enum.all?(s.balls, &(&1.vy < -4.0))
  end

  test "Ladezeit je Seite: gleiche Seite gesperrt, andere frei, nach Ablauf wieder möglich" do
    {s, _} = State.fire(scene(), "a", :right)
    assert {^s, []} = State.fire(s, "a", :right)
    {s2, ev} = State.fire(s, "a", :left)
    assert ev != [] and length(s2.balls) == 6

    {s3, _} = run(s, Combat.reload_ms() + 50)
    assert {_, [{:fire, "a", :right, _, _}]} = State.fire(s3, "a", :right)
  end

  test "Treffer: Schaden, Gutschrift beim Schützen, Ereignis" do
    {s, _} = State.fire(scene(), "a", :right)
    {s, ev} = run(s, 700)

    assert Enum.any?(ev, &match?({:hit, "b", "a", _, _, _}, &1))
    assert s.ships["b"].hp < 12.0
    assert s.ships["a"].damage > 0
  end

  test "Falsche Seite verfehlt" do
    {s, _} = State.fire(scene(), "a", :left)
    {s, _} = run(s, 700)
    assert s.ships["b"].hp == 12.0
  end

  test "Schonzeit nach dem Auftauchen: kein Schaden" do
    s = put(scene(), "b", invuln_until: 5_000)
    {s, ev} = Combat.hurt(s, "b", 5.0, "a", 0.0, 0.0)
    assert ev == [] and s.ships["b"].hp == 12.0
  end

  test "Abschuss: Kill zählt, Opfer taucht nach 3 s mit Schonzeit wieder auf" do
    s = put(scene(), "b", hp: 1.0)
    {s, ev} = Combat.hurt(s, "b", 2.0, "a", 3.0, 0.0)
    assert Enum.any?(ev, &match?({:kill, "a", "b", _, _}, &1))
    refute s.ships["b"].alive?
    assert s.ships["a"].kills == 1 and s.ships["b"].deaths == 1

    {s, ev} = run(s, Combat.respawn_ms() + 100)
    assert s.ships["b"].alive?
    assert Enum.any?(ev, &match?({:respawn, "b", _, _}, &1))
    assert s.ships["b"].hp == 12.0
    assert s.ships["b"].invuln_until > s.time
  end

  test "Powerup einsammeln (nur eines), Leertaste ohne Powerup tut nichts" do
    s = scene()
    a = s.ships["a"]

    s = %{
      s
      | powerups: [
          %{id: 90, type: :repair, x: a.x + 0.1, y: a.y, born: 0},
          %{id: 91, type: :boost, x: a.x + 0.2, y: a.y, born: 0}
        ],
        pu_at: 10_000_000
    }

    {s, ev} = run(s, 50)
    assert [{:pickup, "a", _, _, _}] = Enum.filter(ev, &match?({:pickup, _, _, _, _}, &1))
    assert s.ships["a"].power != nil
    assert length(s.powerups) == 1

    assert {^s, []} = State.use_power(s, "b")
  end

  test "Powerups wirken: Reparatur, Schild, Boost, Torpedo, Salve" do
    base = scene()

    {s, _} = State.use_power(put(base, "a", power: :repair, hp: 5.0), "a")
    assert s.ships["a"].hp == 10.0 and s.ships["a"].power == nil

    s = put(base, "b", shield_until: 99_999)
    {s, _} = Combat.hurt(s, "b", 4.0, "a", 0.0, 0.0)
    assert s.ships["b"].hp == 10.0

    {s, _} = State.use_power(put(base, "a", power: :boost), "a")
    s = State.set_input(s, "a", %{up?: true})
    {s, _} = run(s, 1_500)
    assert s.ships["a"].speed > Osp.Sailing.max_speed() * 1.2

    # Torpedo fliegt geradeaus: b liegt voraus (Ost)
    t = put(base, "b", x: base.ships["a"].x + 3.0, y: base.ships["a"].y)
    {t, _} = State.use_power(put(t, "a", power: :torpedo), "a")
    {t, _} = run(t, 500)
    assert t.ships["b"].hp == 8.0

    {v, _} = State.use_power(put(base, "a", power: :volley), "a")
    assert length(v.balls) == 10
  end

  test "Kugeln stoppen an Land (Splash)" do
    seed = @seed
    # Küste entlang y = 0 suchen
    shore =
      Enum.find(8..400, fn x ->
        Osp.Terrain.land?(seed, x * 1.0, 0.0) and
          Enum.all?(1..4, &(not Osp.Terrain.land?(seed, (x - &1) * 1.0, 0.0)))
      end)

    s = State.new(seed, 0)

    s = %{
      s
      | balls: [
          %{
            id: 1,
            owner: "x",
            x: shore - 3.0,
            y: 0.0,
            vx: 6.0,
            vy: 0.0,
            ttl: 5_000,
            dmg: 1.0,
            r: 0.08,
            kind: 0
          }
        ]
    }

    {s, ev} = run(s, 1_000)
    assert s.balls == []
    assert Enum.any?(ev, &match?({:splash, _, _}, &1))
  end

  test "NPC-Händler: langsamer, flieht nach Beschuss, taucht nach dem Abschuss wieder auf" do
    {bx, by} = open_water()
    s = State.new(@seed, 1)
    s = State.join(s, "a", "Anna")

    s =
      s
      |> State.update_ship("npc-1", &%{&1 | x: bx + 4.0, y: by, heading: 0.0})
      |> State.update_ship("a", &%{&1 | x: bx, y: by, invuln_until: 0})

    {s, _} = Combat.hurt(s, "npc-1", 1.0, "a", bx, by)
    assert %{from: "a"} = s.ships["npc-1"].flee

    {s, _} = run(s, 4_000)
    npc = s.ships["npc-1"]
    assert npc.speed <= Osp.Sailing.max_speed() * 0.6 * 1.4 + 0.01

    {s, ev} = Combat.hurt(put(s, "npc-1", hp: 0.5), "npc-1", 1.0, "a", npc.x, npc.y)
    assert Enum.any?(ev, &match?({:kill, "a", "npc-1", _, _}, &1))
    refute s.ships["npc-1"].alive?

    {s, _} = run(s, 8_200)
    assert s.ships["npc-1"].alive?
  end

  test "Powerups tauchen in der Nähe von Spielern auf und verschwinden nach langer Zeit" do
    {s, _} = run(scene(), 12_000)
    assert s.powerups != []
    assert length(s.powerups) <= 3

    a = s.ships["a"]

    assert Enum.all?(
             s.powerups,
             &(:math.sqrt((&1.x - a.x) * (&1.x - a.x) + (&1.y - a.y) * (&1.y - a.y)) < 40)
           )
  end

  test "Schnappschuss: eigener Status, Kugeln und Ereignisse nur aus der Umgebung" do
    {s, _} = State.fire(scene(), "a", :right)
    a = s.ships["a"]

    events = [{:fire, "a", :right, a.x, a.y}, {:fire, "z", :left, a.x + 500.0, a.y}]
    snap = State.snapshot_for(s, "a", events)

    assert snap.t == "snap" and snap.you == "a"
    assert %{rl: 0, rr: rr, pw: nil, k: 0, d: 0, rs: 0} = snap.me
    assert rr > 0
    assert length(snap.balls) == 3
    assert [["fire", "a", "right", _, _]] = snap.ev
    assert {:ok, _} = Jason.encode(snap)
    assert State.snapshot_for(s, "gibtsnicht", []) == nil
  end
end
