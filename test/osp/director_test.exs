defmodule Osp.DirectorTest do
  use ExUnit.Case, async: true

  alias Osp.{Director, State}

  @seed 4

  defp world do
    State.new(@seed, 0, director?: true) |> State.join("a", "Anna")
  end

  defp run(state, ms) do
    Enum.reduce(1..div(ms, 25), state, fn _, s -> elem(State.tick(s, 25), 0) end)
  end

  defp dist(a, b), do: :math.sqrt(:math.pow(a.x - b.x, 2) + :math.pow(a.y - b.y, 2))
  defp npcs(s, kind), do: for({_, x} <- s.ships, x.kind == kind, do: x)

  test "ohne Director passiert nichts" do
    s = State.new(@seed, 0) |> State.join("a", "Anna")
    s = run(s, 10_000)
    assert npcs(s, :merchant) == [] and npcs(s, :hunter) == []
  end

  test "Director bevölkert die Umgebung: Händler und Jäger tauchen außerhalb der Sicht auf" do
    s = run(world(), 12_000)
    me = s.ships["a"]

    assert length(npcs(s, :merchant)) >= 2
    assert length(npcs(s, :hunter)) >= 1

    for n <- npcs(s, :merchant) ++ npcs(s, :hunter) do
      assert n.bounty > 0
      assert n.name != ""
      assert dist(me, n) <= 100.0
    end
  end

  test "frisch aufgetauchte NPCs liegen weit genug weg (>= 20 WE)" do
    s = world()
    s = State.update_ship(s, "a", &%{&1 | invuln_until: 0})
    me = s.ships["a"]
    s = Director.step(%{s | dir_at: 0})
    [npc | _] = npcs(s, :merchant)
    assert dist(me, npc) >= 26.0
  end

  test "zu weit entfernte NPCs verschwinden still" do
    s = world()
    s = State.add_npc(s, :merchant, "Weit weg", 900.0, 900.0, 0.0)
    assert length(npcs(s, :merchant)) == 1
    s = Director.step(%{s | dir_at: 0})
    far = for n <- npcs(s, :merchant), n.name == "Weit weg", do: n
    assert far == []
  end

  test "Zahl der NPCs bleibt begrenzt, auch nach langer Zeit" do
    s = run(world(), 60_000)
    assert length(npcs(s, :merchant)) <= 4
    assert length(npcs(s, :hunter)) <= 5
  end
end
