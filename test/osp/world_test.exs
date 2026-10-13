defmodule Osp.WorldTest do
  use ExUnit.Case, async: true

  alias Osp.World

  defp start_world(opts \\ []) do
    id = "t" <> Integer.to_string(System.unique_integer([:positive]))
    defaults = [id: id, seed: 4, bots: 0, tick_ms: 25]
    start_supervised!({World, Keyword.merge(defaults, opts)}, id: id)
    id
  end

  defp flush do
    receive do
      {:osp_snap, _} -> flush()
    after
      0 -> :ok
    end
  end

  test "Beitritt liefert Weltparameter, Schnappschüsse kommen laufend an" do
    w = start_world()
    assert {:ok, %{id: "p1", chunk: 16, resolution: 2, land: land}} = World.join(w, "p1", "Anna")
    assert land > 0.5

    assert_receive {:osp_snap, %{t: "snap", you: "p1", ships: [%{i: "p1", n: "Anna"}]}}, 500
  end

  test "Eingabe bewegt das Schiff" do
    w = start_world()
    {:ok, _} = World.join(w, "p1", "Anna")
    start = World.state(w).ships["p1"]

    World.input(w, "p1", %{up?: true, left?: false, right?: false})
    for _ <- 1..30, do: assert_receive({:osp_snap, _}, 500)

    moved = World.state(w).ships["p1"]
    assert moved.speed > 0.3
    assert :math.sqrt(:math.pow(moved.x - start.x, 2) + :math.pow(moved.y - start.y, 2)) > 0.2
  end

  test "zweiter Spieler startet 12-40 WE vom ersten (1-2 Bildschirme)" do
    w = start_world()
    {:ok, _} = World.join(w, "p1", "Anna")
    {:ok, _} = World.join(w, "p2", "Ben")
    %{ships: %{"p1" => a, "p2" => b}} = World.state(w)
    d = :math.sqrt(:math.pow(a.x - b.x, 2) + :math.pow(a.y - b.y, 2))
    assert d >= 12.0 and d <= 41.0
  end

  test "Schnappschuss enthält nur Schiffe in der Umgebung (AOI)" do
    w = start_world()
    {:ok, _} = World.join(w, "p1", "Anna")
    {:ok, _} = World.join(w, "p2", "Ben")

    # p2 weit weg setzen
    :sys.replace_state(GenServer.whereis(World.via(w)), fn s ->
      far = %{s.ships["p2"] | x: s.ships["p1"].x + 500.0}
      %{s | ships: Map.put(s.ships, "p2", far)}
    end)

    flush()
    assert_receive {:osp_snap, %{you: "p1", ships: ships}}, 500
    assert Enum.map(ships, & &1.i) == ["p1"]
  end

  test "Wiederverbinden mit gleichem Token behält das Schiff; Verlassen entfernt es" do
    w = start_world()
    {:ok, _} = World.join(w, "p1", "Anna")
    pos = World.state(w).ships["p1"]
    {:ok, _} = World.join(w, "p1", "Anna2")
    again = World.state(w).ships["p1"]
    assert {again.x, again.y} == {pos.x, pos.y}
    assert again.name == "Anna2"

    World.leave(w, "p1")
    refute Map.has_key?(World.state(w).ships, "p1")
  end

  test "Verbindungsabbruch: Schiff bleibt in der Schonfrist, steht aber ohne Eingabe" do
    w = start_world()
    parent = self()

    pid =
      spawn(fn ->
        {:ok, _} = World.join(w, "p1", "Anna", self())
        World.input(w, "p1", %{up?: true, left?: false, right?: false})
        send(parent, :joined)
        Process.sleep(:infinity)
      end)

    assert_receive :joined, 500
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 500

    ship = World.state(w).ships["p1"]
    assert ship.gone_at != nil
    assert ship.input == %{up?: false, left?: false, right?: false}
  end

  test "Wander-Bots segeln selbst und stranden nicht an Land" do
    w = start_world(bots: 3)
    {:ok, _} = World.join(w, "p1", "Anna")

    for _ <- 1..200, do: assert_receive({:osp_snap, _}, 500)

    %{ships: ships, seed: seed} = World.state(w)
    bots = for {"bot-" <> _, s} <- ships, do: s
    assert length(bots) == 3
    assert Enum.any?(bots, &(&1.speed > 0.3))
    for b <- bots, do: refute(Osp.Terrain.land?(seed, b.x, b.y))
  end

  test "echtes Gelände: Schiff fährt gegen eine Insel und bleibt davor" do
    w = start_world()
    {:ok, _} = World.join(w, "p1", "Anna")
    seed = World.seed(w)

    # erste Küste entlang der Zeile y = 0 suchen, 4 WE davor starten, Kurs Ost
    shore =
      Enum.find(8..400, fn x ->
        Osp.Terrain.land?(seed, x * 1.0, 0.0) and
          Enum.all?(1..6, &(not Osp.Terrain.land?(seed, (x - &1) * 1.0, 0.0)))
      end)

    assert shore
    start_x = shore - 4.0

    :sys.replace_state(GenServer.whereis(World.via(w)), fn s ->
      ship = %{s.ships["p1"] | x: start_x, y: 0.0, heading: 0.0, speed: 0.0}
      %{s | ships: Map.put(s.ships, "p1", ship)}
    end)

    World.input(w, "p1", %{up?: true, left?: false, right?: false})
    for _ <- 1..300, do: assert_receive({:osp_snap, _}, 500)

    ship = World.state(w).ships["p1"]
    refute Osp.Terrain.land?(seed, ship.x, ship.y)
    assert ship.x > start_x
    assert ship.x < shore
  end
end
