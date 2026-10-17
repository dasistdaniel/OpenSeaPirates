defmodule Osp.HarborTest do
  use ExUnit.Case, async: true

  alias Osp.{Combat, Ports, Ships, Shop, State, Terrain}

  @seed 4

  # --- Häfen --------------------------------------------------------------------

  defp all_ports(range \\ -8..8) do
    for cx <- range, cy <- range, port = Ports.in_chunk(@seed, cx, cy), do: port
  end

  defp some_port, do: hd(all_ports())

  test "Häfen sind deterministisch und liegen im Wasser an einer Küste" do
    ports = all_ports()
    assert ports != []
    assert ports == all_ports()

    for p <- ports do
      assert Osp.Spawn.clear?(@seed, p.x, p.y, 1.4)
      assert p.name != ""
      # in Richtung `land` liegt in 2,6–4,6 WE Land
      assert Enum.any?([2.6, 3.4, 4.2], fn r ->
               Terrain.land?(@seed, p.x + :math.cos(p.land) * r, p.y + :math.sin(p.land) * r)
             end)
    end
  end

  test "Etwa jeder zehnte Chunk hat einen Hafen (5-25 %)" do
    n = 17 * 17
    share = length(all_ports()) / n
    assert share > 0.05 and share < 0.25
  end

  test "Schutzzone und Andockreichweite" do
    p = some_port()
    assert Ports.safe?(@seed, p.x, p.y)
    assert Ports.safe?(@seed, p.x + 3.0, p.y)
    refute Ports.safe?(@seed, p.x + 4.5, p.y)
    assert %{id: id} = Ports.dockable(@seed, p.x + 1.0, p.y)
    assert id == p.id
    assert Ports.dockable(@seed, p.x + 3.2, p.y) == nil
  end

  # --- Klassen und Laden ---------------------------------------------------------

  test "Klassenwerte und Upgrades wirken in stats/1" do
    base = Ships.fresh()
    assert %{max_hp: 12, cannons: 3, dmg_mult: 1.0, speed_mult: 1.0} = Ships.stats(base)

    fre = %{class: :fregatte, upgrades: %{cannons: 3, hull: 2, sails: 1}}
    s = Ships.stats(fre)
    assert s.max_hp == 28 + 6
    assert s.cannons == 5
    assert s.dmg_mult == 2.0
    assert_in_delta s.speed_mult, 0.85 * 1.08, 1.0e-9
    assert_in_delta s.turn_mult, 0.80 * 1.08, 1.0e-9
  end

  # --- Shop ---------------------------------------------------------------------

  defp ship(opts) do
    st = State.join(State.new(@seed, 0), "a", "Anna")
    Map.merge(st.ships["a"], Map.new(opts))
  end

  test "Schiff kaufen: Inzahlungnahme 50 %, volle HP, neuer Radius" do
    s = ship(gold: 1_000, hp: 3.0)
    assert Shop.class_cost(s, :brigg) == 600
    assert {:ok, s2} = Shop.buy_class(s, :brigg)
    assert s2.class == :brigg and s2.gold == 400
    assert s2.max_hp == 18 and s2.hp == 18.0 and s2.radius == 0.37

    # Brigg -> Fregatte: 1400 - 300
    s3 = %{s2 | gold: 2_000}
    assert Shop.class_cost(s3, :fregatte) == 1_100
    assert {:ok, %{class: :fregatte, gold: 900}} = Shop.buy_class(s3, :fregatte)

    assert Shop.buy_class(s, :galeone) == {:error, :no_gold}
    assert Shop.buy_class(s, :schaluppe) == {:error, :same_class}
    assert Shop.buy_class(s, :titanic) == {:error, :unknown}
  end

  test "Upgrades: Stufen, Preise, Höchststufe, Rumpf gibt zusätzliche HP" do
    s = ship(gold: 2_000)
    assert {:ok, s} = Shop.buy_upgrade(s, :hull)
    assert s.upgrades.hull == 1 and s.gold == 1_880
    assert s.max_hp == 15 and s.hp == 15.0

    {:ok, s} = Shop.buy_upgrade(s, :hull)
    {:ok, s} = Shop.buy_upgrade(s, :hull)
    assert s.upgrades.hull == 3 and s.max_hp == 22
    assert Shop.buy_upgrade(s, :hull) == {:error, :max_level}
    assert Shop.buy_upgrade(ship(gold: 10), :cannons) == {:error, :no_gold}
    assert Shop.buy_upgrade(s, :unsinn) == {:error, :unknown}
  end

  test "Munition: Pakete, Lagergrenze, Preise" do
    s = ship(gold: 1_000)
    {:ok, s} = Shop.buy_ammo(s, :chain)
    assert s.ammo.chain == 10 and s.gold == 960
    {:ok, s} = Shop.buy_ammo(s, :fire)
    assert s.ammo.fire == 10 and s.gold == 900

    s = Enum.reduce(1..3, s, fn _, acc -> elem(Shop.buy_ammo(acc, :chain), 1) end)
    assert s.ammo.chain == 40
    assert Shop.buy_ammo(s, :chain) == {:error, :full}
    assert Shop.buy_ammo(ship(gold: 1), :fire) == {:error, :no_gold}
    assert Shop.buy_ammo(s, :zauber) == {:error, :unknown}
  end

  test "Reparatur: 4 Gold je HP, teilweise wenn das Gold nicht reicht" do
    s = ship(gold: 100, hp: 4.0)
    assert Shop.repair_cost(s) == 32
    assert {:ok, s2} = Shop.repair(s)
    assert s2.hp == 12.0 and s2.gold == 68

    assert {:ok, s3} = Shop.repair(ship(gold: 10, hp: 4.0))
    assert s3.hp == 6.0 and s3.gold == 2
    assert Shop.repair(ship(gold: 100)) == {:error, :full}
    assert Shop.repair(ship(gold: 2, hp: 1.0)) == {:error, :no_gold}
  end

  test "Bank: einzahlen, abheben, alles, Fehler" do
    s = ship(gold: 100)
    {:ok, s} = Shop.deposit(s, 40)
    assert s.gold == 60 and s.bank == 40
    {:ok, s} = Shop.deposit(s, :all)
    assert s.gold == 0 and s.bank == 100
    {:ok, s} = Shop.withdraw(s, 30)
    assert s.gold == 30 and s.bank == 70
    {:ok, s} = Shop.withdraw(s, :all)
    assert s.gold == 100 and s.bank == 0

    assert Shop.deposit(s, 500) == {:error, :no_gold}
    assert Shop.withdraw(s, 1) == {:error, :no_bank_gold}
    assert Shop.deposit(s, 0) == {:error, :amount}
    assert Shop.withdraw(s, -5) == {:error, :amount}
  end

  test "Hafen-Ansicht ist JSON-fähig und beschreibt Klassen, Slots, Munition, Reparatur" do
    view = Shop.view(ship(gold: 500, hp: 6.0), "Tortuga")
    assert {:ok, _} = Jason.encode(view)
    assert view.port == "Tortuga" and view.gold == 500
    assert length(view.classes) == 5
    assert Enum.find(view.classes, & &1.current).id == "schaluppe"
    assert length(view.upgrades) == 3
    assert length(view.ammo) == 2
    assert view.repair.cost == 24
  end

  # --- Andocken und Schutzzone im Weltzustand --------------------------------------------

  defp at_port(opts \\ []) do
    p = some_port()
    st = State.join(State.new(@seed, 0), "a", "Anna")

    st =
      State.update_ship(st, "a", fn s ->
        %{
          s
          | x: p.x + 1.0,
            y: p.y,
            speed: Keyword.get(opts, :speed, 0.0),
            invuln_until: 0,
            gold: 500
        }
      end)

    {st, p}
  end

  test "Andocken: nur am Hafen und langsam; angedockt steht das Schiff still" do
    st = State.join(State.new(@seed, 0), "a", "Anna")
    st = State.update_ship(st, "a", &%{&1 | x: 400.0, y: 400.0})
    assert {_, {:error, :no_port}} = State.dock(st, "a")

    {st, _p} = at_port(speed: 1.5)
    assert {_, {:error, :too_fast}} = State.dock(st, "a")

    {st, p} = at_port()
    {st, :ok} = State.dock(st, "a")
    assert st.ships["a"].docked == %{id: p.id, name: p.name}
    assert {_, {:error, :docked}} = State.dock(st, "a")

    st = State.set_input(st, "a", %{up?: true})
    {st, _} = State.tick(st, 1_000)
    assert_in_delta st.ships["a"].x, p.x + 1.0, 1.0e-6

    {st, :ok} = State.undock(st, "a")
    assert st.ships["a"].docked == nil
    assert {_, {:error, :not_docked}} = State.undock(st, "a")
  end

  test "Shop nur angedockt, Käufe wirken im Weltzustand" do
    {st, _} = at_port()
    assert {_, {:error, :not_docked}} = State.shop(st, "a", {:upgrade, :hull})

    {st, :ok} = State.dock(st, "a")
    {st, {:ok, view}} = State.shop(st, "a", {:upgrade, :hull})
    assert view.upgrades |> Enum.find(&(&1.slot == "hull")) |> Map.get(:level) == 1
    assert st.ships["a"].gold == 380

    {st, {:error, :no_gold}} = State.shop(st, "a", {:class, :galeone})
    {st, {:ok, _}} = State.shop(st, "a", {:deposit, 80})
    assert st.ships["a"].bank == 80 and st.ships["a"].gold == 300
    assert State.shop_view(st, "a").bank == 80
  end

  test "Schutzzone: kein Schaden, keine Breitseite, Kugeln verschwinden" do
    {st, p} = at_port()
    {st, ev} = Combat.hurt(st, "a", 5.0, nil, p.x, p.y)
    assert ev == [] and st.ships["a"].hp == 12.0

    assert {^st, []} = Combat.fire(st, "a", :right)

    st = %{
      st
      | balls: [
          %{
            id: 1,
            owner: "x",
            owner_kind: :player,
            x: p.x + 2.0,
            y: p.y,
            vx: 0.0,
            vy: 0.0,
            ttl: 5_000,
            dmg: 1.0,
            r: 0.08,
            ammo: :ball
          }
        ]
    }

    {st, _} = State.tick(st, 100)
    assert st.balls == []
  end

  test "Angedockt kann man nicht feuern, auch außerhalb der Schutzzone nicht" do
    {st, _} = at_port()
    {st, :ok} = State.dock(st, "a")
    assert {_, []} = Combat.fire(st, "a", :left)
  end

  # --- Klassen und Munition im Kampf ------------------------------------------------------

  defp duel(attacker_fields \\ []) do
    {bx, by} = open_water()
    st = State.new(@seed, 0) |> State.join("a", "Anna") |> State.join("b", "Ben")

    st =
      st
      |> State.update_ship(
        "a",
        &Map.merge(%{&1 | x: bx, y: by, heading: 0.0, invuln_until: 0}, Map.new(attacker_fields))
      )
      |> State.update_ship("b", &%{&1 | x: bx, y: by + 2.0, heading: 0.0, invuln_until: 0})

    st
  end

  defp open_water do
    Enum.find_value(0..200, fn k ->
      x = k * 9.0 + 1000.0
      y = k * 5.0 + 1000.0
      if Osp.Spawn.clear?(@seed, x, y, 7.0) and not Ports.safe?(@seed, x, y), do: {x, y}
    end)
  end

  defp run(st, ms), do: Enum.reduce(1..div(ms, 25), st, fn _, s -> elem(State.tick(s, 25), 0) end)

  test "Klasse und Kanonen-Upgrade: mehr Kugeln und mehr Schaden je Salve" do
    st = duel(class: :fregatte, upgrades: %{cannons: 3, hull: 0, sails: 0})
    {st, _} = Combat.fire(st, "a", :right)
    assert length(st.balls) == 5
    assert Enum.all?(st.balls, &(&1.dmg == 3.0))
  end

  test "Kettenkugel: halber Schaden, verlangsamt das Ziel; Vorrat wird verbraucht" do
    st = duel(ammo: %{chain: 2}, ammo_sel: :chain)
    {st, _} = Combat.fire(st, "a", :right)
    assert st.ships["a"].ammo.chain == 1
    assert Enum.all?(st.balls, &(&1.ammo == :chain and &1.dmg == 0.75))

    st = run(st, 700)
    assert st.ships["b"].hp < 12.0
    assert st.ships["b"].slow_until > st.time

    # Wirkung: Höchsttempo halbiert
    st = State.set_input(st, "b", %{up?: true})

    st =
      run(%{st | ships: Map.update!(st.ships, "b", &%{&1 | slow_until: st.time + 10_000})}, 4_000)

    assert st.ships["b"].speed <= Osp.Sailing.max_speed() * 0.5 * 1.4 + 0.01
  end

  test "Brandgeschoss: Ziel brennt 3 s mit 1 Schaden pro Sekunde, nur einmal gleichzeitig" do
    st = duel(ammo: %{fire: 3}, ammo_sel: :fire)
    {st, _} = Combat.fire(st, "a", :right)
    st = run(st, 700)
    assert st.ships["b"].burn_until > st.time
    hp_after_hit = st.ships["b"].hp

    st = run(st, 3_400)
    assert st.ships["b"].hp <= hp_after_hit - 2.0
    assert st.ships["b"].burn_until <= st.time
    assert st.ships["a"].damage >= 2.0
  end

  test "Ohne Vorrat fällt die Sondermunition auf Vollkugeln zurück" do
    st = duel(ammo_sel: :fire)
    {st, _} = Combat.fire(st, "a", :right)
    assert Enum.all?(st.balls, &(&1.ammo == :ball and &1.dmg == 1.5))
  end

  test "Munitionswahl nur für bekannte Arten" do
    st = duel()
    assert State.select_ammo(st, "a", :chain).ships["a"].ammo_sel == :chain
    assert State.select_ammo(st, "a", :zauber).ships["a"].ammo_sel == :ball
  end

  test "Klasse beeinflusst Tempo und Wendigkeit, Spielerschiff trägt Klassenwerte" do
    fast = duel(class: :klipper) |> State.set_input("a", %{up?: true}) |> run(4_000)
    slow = duel(class: :galeone) |> State.set_input("a", %{up?: true}) |> run(4_000)
    assert fast.ships["a"].speed > slow.ships["a"].speed * 1.3
  end

  test "Schnappschuss: Häfen in der Nähe, Hafenstatus und Munition" do
    {st, p} = at_port()
    snap = State.snapshot_for(st, "a", [])
    assert Enum.any?(snap.ports, fn [id, _, _, _, _, _] -> id == p.id end)
    assert snap.me.np == p.name and snap.me.dk == nil
    assert %{c: 0, f: 0} = snap.me.am
    assert snap.me.b == 0 and snap.me.as == "ball"
    [ship] = snap.ships
    assert ship.cl == "schaluppe" and ship.dk == false and ship.rd == 0.31

    {st, :ok} = State.dock(st, "a")
    snap = State.snapshot_for(st, "a", [])
    assert snap.me.dk == p.name
    assert {:ok, _} = Jason.encode(snap)
  end

  test "Tod behält Klasse, Upgrades und Bank; nur 30 % des getragenen Golds gehen verloren" do
    st = duel(class: :brigg, gold: 100, bank: 500, upgrades: %{cannons: 1, hull: 0, sails: 0})
    st = State.update_ship(st, "a", &%{&1 | hp: 0.5})
    {st, _} = Combat.hurt(st, "a", 2.0, "b", 0.0, 0.0)
    a = st.ships["a"]
    refute a.alive?
    assert a.class == :brigg and a.bank == 500 and a.upgrades.cannons == 1 and a.gold == 70
  end

  test "Gleiche Namen werden unterscheidbar (Anna, Anna 2, ...), der eigene Name bleibt" do
    st = State.new(4, 0)
    st = State.join(st, "a", "Anna")
    st = State.join(st, "b", "Anna")
    st = State.join(st, "c", "Anna")

    assert {st.ships["a"].name, st.ships["b"].name, st.ships["c"].name} ==
             {"Anna", "Anna 2", "Anna 3"}

    # erneutes Beitreten desselben Spielers mit seinem Namen ändert ihn nicht
    st = State.join(st, "a", "Anna")
    assert st.ships["a"].name == "Anna"
    assert State.player_count(st) == 3
  end
end
