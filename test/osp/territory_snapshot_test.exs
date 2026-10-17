defmodule Osp.TerritorySnapshotTest do
  use ExUnit.Case, async: true

  alias Osp.{Nations, Ports, State}

  @seed 4
  @tok "geheimes-token-nation"

  defp home_port(nation), do: Nations.nearest_port_of(@seed, nation, {0.0, 0.0}, 1500.0)

  defp scene(nation) do
    port = home_port(nation)

    st =
      State.new(@seed, 0)
      |> State.join(@tok, "Anna", %{"nation" => Atom.to_string(nation)})
      |> State.update_ship(@tok, &%{&1 | x: port.x + 6.0, y: port.y, speed: 0.0})

    {st, port}
  end

  defp run(state, ms),
    do: Enum.reduce(1..div(ms, 25), state, fn _, s -> elem(State.tick(s, 25), 0) end)

  test "NPCs tragen die Nation des Gebiets, in dem sie erscheinen" do
    port = home_port(:france)
    st = State.add_npc(State.new(@seed, 0), :merchant, "Händler", port.x + 0.5, port.y, 0.0)
    npc = st.ships |> Map.values() |> hd()
    assert npc.nation == :france
    assert npc.nation == Nations.at(@seed, npc.x, npc.y)
  end

  test "Schiffseintrag: na ist die Nation als String, leer ohne Nation" do
    {st, _} = scene(:spain)
    snap = State.snapshot_for(st, @tok, [])
    assert [%{na: "spain"}] = snap.ships

    plain = State.new(@seed, 0) |> State.join("t-plain-1", "Ben")
    assert [%{na: ""}] = State.snapshot_for(plain, "t-plain-1", []).ships
  end

  test "Hafeneinträge haben als sechstes Element die Nation des Hafens" do
    {st, port} = scene(:england)
    snap = State.snapshot_for(st, @tok, [])
    assert snap.ports != []

    for [_id, _x, _y, _name, _land, nation, _progress, _protected] = entry <- snap.ports do
      assert length(entry) == 8
      assert nation in ~w(spain england france netherlands portugal)
    end

    mine = Enum.find(snap.ports, fn [id | _] -> id == port.id end)
    assert Enum.at(mine, 5) == "england"
  end

  test "Gebietsnation wird nur alle 500 ms neu berechnet" do
    {st, port} = scene(:spain)
    st = run(st, 500)
    assert st.ships[@tok].terr == Nations.at(@seed, port.x + 6.0, port.y)
    assert State.snapshot_for(st, @tok, []).me.tn == Atom.to_string(st.ships[@tok].terr)

    # weit weg gesetzt, aber noch nicht neu berechnet
    far = {port.x + 700.0, port.y + 700.0}
    moved = State.update_ship(st, @tok, &%{&1 | x: elem(far, 0), y: elem(far, 1)})
    before = moved.ships[@tok].terr
    st2 = run(moved, 25)
    assert st2.ships[@tok].terr == before

    # nach dem nächsten 500-ms-Takt stimmt sie mit der Position überein
    st3 = run(st2, 500)
    assert st3.ships[@tok].terr == Nations.at(@seed, elem(far, 0), elem(far, 1))
  end

  test "Gebietsnation ohne Berechnung: me.tn ist leer" do
    {st, _} = scene(:spain)
    assert State.snapshot_for(st, @tok, []).me.tn == ""
  end

  test "Schnappschuss mit Nationen enthält nie das Token" do
    {st, _} = scene(:portugal)
    st = run(st, 500)
    json = st |> State.snapshot_for(@tok, []) |> Jason.encode!()
    refute json =~ "geheimes-token"
    assert Ports.near(@seed, st.ships[@tok].x, st.ships[@tok].y, 45.0) != []
  end
end
