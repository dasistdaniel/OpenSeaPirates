defmodule Osp.SailsTest do
  use ExUnit.Case, async: true

  alias Osp.{Ships, State}

  @seed 4

  defp open_water do
    Enum.find_value(0..200, fn k ->
      x = k * 9.0 + 2000.0
      y = k * 5.0 + 2000.0
      if Osp.Spawn.clear?(@seed, x, y, 7.0) and not Osp.Ports.safe?(@seed, x, y), do: {x, y}
    end)
  end

  defp scene(mode) do
    {bx, by} = open_water()

    State.new(@seed, 0)
    |> State.join("a", "Anna")
    |> State.update_ship("a", &%{&1 | x: bx, y: by, heading: 0.0, speed: 0.0, invuln_until: 0})
    |> State.set_sail("a", mode)
  end

  defp run(st, ms), do: Enum.reduce(1..div(ms, 25), st, fn _, s -> elem(State.tick(s, 25), 0) end)

  test "Segelstufen: Tempo gerafft < voll < Beisegel (ungefähr 0,65 / 1 / 1,25)" do
    speed = fn mode ->
      scene(mode)
      |> State.set_input("a", %{up?: true})
      |> run(6_000)
      |> then(& &1.ships["a"].speed)
    end

    reefed = speed.(:reefed)
    full = speed.(:full)
    studding = speed.(:studding)

    assert reefed < full and full < studding
    assert_in_delta reefed / full, 0.65, 0.04
    assert_in_delta studding / full, 1.25, 0.04
  end

  test "Segelstufen: Wendigkeit gerafft > voll > Beisegel" do
    turned = fn mode ->
      st =
        scene(mode)
        |> State.update_ship("a", &%{&1 | speed: 1.0})
        |> State.set_input("a", %{right?: true})

      start = st.ships["a"].heading
      run(st, 1_000).ships["a"].heading - start
    end

    reefed = turned.(:reefed)
    full = turned.(:full)
    studding = turned.(:studding)

    assert reefed > full and full > studding
    assert studding > 0.0
  end

  test "Zweimal dieselbe Stufe wählen geht zurück auf volle Segel (Client schaltet um), Standard ist voll" do
    st = scene(:full)
    assert st.ships["a"].sail == :full
    assert State.set_sail(st, "a", :reefed).ships["a"].sail == :reefed
    assert State.set_sail(State.set_sail(st, "a", :reefed), "a", :full).ships["a"].sail == :full
  end

  test "Ungültige Stufen, Unbekannte und tote Schiffe ändern nichts" do
    st = scene(:full)
    assert State.set_sail(st, "a", :hyperspeed) == st
    assert State.set_sail(st, "niemand", :reefed) == st

    dead = State.update_ship(st, "a", &%{&1 | alive?: false})
    assert State.set_sail(dead, "a", :studding).ships["a"].sail == :full
  end

  test "Schnappschuss meldet die Segelstufe (Schiffe und eigener Status)" do
    st = scene(:studding)
    snap = State.snapshot_for(st, "a", [])
    assert snap.me.sa == "studding"
    assert [%{sa: "studding"}] = snap.ships
    assert {:ok, _} = Jason.encode(snap)
  end

  test "Segel-Daten sind vollständig" do
    for mode <- [:reefed, :full, :studding] do
      assert %{label: label, speed: s, turn: t} = Ships.sail(mode)
      assert is_binary(label) and s > 0 and t > 0
    end

    # gerafft: langsamer aber wendiger, Beisegel: schneller aber träger
    assert Ships.sail(:reefed).speed < 1 and Ships.sail(:reefed).turn > 1
    assert Ships.sail(:studding).speed > 1 and Ships.sail(:studding).turn < 1
  end
end
