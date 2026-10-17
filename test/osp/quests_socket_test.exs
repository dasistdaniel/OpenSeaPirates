defmodule Osp.QuestsSocketTest do
  use ExUnit.Case, async: true

  alias Osp.{Nations, Quests, State, World}
  alias Osp.Web.Socket

  @seed 4

  defp start_world do
    id = "q" <> Integer.to_string(System.unique_integer([:positive]))
    start_supervised!({World, id: id, seed: @seed, bots: 0, tick_ms: 25}, id: id)
    id
  end

  defp send_json(state, map), do: Socket.handle_in({Jason.encode!(map), [opcode: :text]}, state)

  defp join(world) do
    tok = "tok-qs-" <> Integer.to_string(System.unique_integer([:positive])) <> "-x"
    {:ok, st} = Socket.init([])

    {:push, _, st} =
      send_json(%{st | world: world}, %{t: "join", token: tok, name: "A", nation: "france"})

    {st, tok}
  end

  defp home, do: Nations.nearest_port_of(@seed, :england, {0.0, 0.0}, 1500.0)

  # Das Schiff des Spielers an den englischen Hafen setzen und andocken
  defp dock!(world, tok) do
    p = home()

    :sys.replace_state(GenServer.whereis(World.via(world)), fn s ->
      sim = State.update_ship(s.sim, tok, &%{&1 | x: p.x + 1.0, y: p.y, speed: 0.0})
      {sim, :ok} = State.dock(sim, tok)
      %{s | sim: sim}
    end)

    p
  end

  defp first_offer(p), do: hd(Quests.offers(@seed, p, 0))
  defp quests(world, tok), do: World.state(world).ships[tok].quests

  defp flush do
    receive do
      {:osp_shop, _} -> flush()
      {:osp_snap, _} -> flush()
    after
      0 -> :ok
    end
  end

  test "accept mit gültiger ID: Quest entsteht, Hafen-Ansicht mit aktiver Quest kommt zurück" do
    w = start_world()
    {st, tok} = join(w)
    p = dock!(w, tok)
    offer = first_offer(p)
    flush()

    assert {:ok, _} = send_json(st, %{t: "quest", op: "accept", id: offer.id})
    assert_receive {:osp_shop, %{quests: %{active: [%{id: id}]}}}, 1_000
    assert id == offer.id
    assert [%{id: ^id}] = quests(w, tok)
  end

  test "accept ohne angedockt: Fehler not_docked, keine Quest" do
    w = start_world()
    {st, tok} = join(w)
    flush()
    p = home()
    assert {:ok, _} = send_json(st, %{t: "quest", op: "accept", id: first_offer(p).id})
    assert_receive {:osp_shop, %{open: false, error: "not_docked"}}, 1_000
    assert quests(w, tok) == []
  end

  test "ungültige IDs und Felder werden verworfen, ohne Absturz und ohne Antwort" do
    w = start_world()
    {st, tok} = join(w)
    dock!(w, tok)
    flush()

    long = String.duplicate("a", 100)

    for bad <- [
          "x",
          "q:port:1,1:0:0; drop",
          long,
          5,
          nil,
          ["q:port:1,1:0:0"],
          %{},
          "q:port:99999999999,1:0:0",
          "q:port:1,1:0:12"
        ] do
      assert {:ok, %{id: ^tok}} = send_json(st, %{t: "quest", op: "accept", id: bad})
    end

    assert {:ok, %{id: ^tok}} = send_json(st, %{t: "quest", op: "accept"})
    assert {:ok, %{id: ^tok}} = send_json(st, %{t: "quest", op: "unbekannt"})
    assert {:ok, %{id: ^tok}} = send_json(st, %{t: "quest"})
    assert {:ok, %{id: ^tok}} = send_json(st, %{t: "quest", op: "abandon", id: 5})
    assert quests(w, tok) == []
    refute_receive {:osp_shop, _}, 100
    assert Process.alive?(GenServer.whereis(World.via(w)))
  end

  test "turn_in ohne erfüllte Quest: Fehler nothing" do
    w = start_world()
    {st, tok} = join(w)
    dock!(w, tok)
    flush()
    assert {:ok, _} = send_json(st, %{t: "quest", op: "turn_in"})
    assert_receive {:osp_shop, %{error: "nothing"}}, 1_000
  end

  test "abandon entfernt die Quest" do
    w = start_world()
    {st, tok} = join(w)
    p = dock!(w, tok)
    offer = first_offer(p)
    flush()
    {:ok, _} = send_json(st, %{t: "quest", op: "accept", id: offer.id})
    assert_receive {:osp_shop, %{quests: %{active: [_]}}}, 1_000

    assert {:ok, _} = send_json(st, %{t: "quest", op: "abandon", id: offer.id})
    assert_receive {:osp_shop, %{quests: %{active: []}}}, 1_000
    assert quests(w, tok) == []
  end

  test "turn_in nach erfüllter Jagd: Ereignis geht hinaus, Gold kommt an" do
    w = start_world()
    {st, tok} = join(w)
    p = dock!(w, tok)

    hunt =
      Enum.find_value(0..200, fn win ->
        Enum.find(Quests.offers(@seed, p, win), &(&1.kind == :hunt))
      end)

    # fertige Jagd direkt im Zustand ablegen (Angebot aus Fenster 0 oder später: Zeit passend setzen)
    win = hunt.id |> String.split(":") |> Enum.at(-2) |> String.to_integer()

    :sys.replace_state(GenServer.whereis(World.via(w)), fn s ->
      q = %{Quests.to_quest(hunt) | have: hunt.need}
      sim = %{s.sim | time: win * 1_800_000}
      %{s | sim: State.update_ship(sim, tok, &%{&1 | quests: [q]})}
    end)

    flush()
    assert {:ok, _} = send_json(st, %{t: "quest", op: "turn_in"})
    assert_receive {:osp_shop, %{quests: %{active: []}}}, 1_000
    assert World.state(w).ships[tok].gold == hunt.gold
  end
end
