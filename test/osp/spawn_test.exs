defmodule Osp.SpawnTest do
  use ExUnit.Case, async: true

  alias Osp.Spawn

  defp dist({ax, ay}, {bx, by}), do: :math.sqrt((ax - bx) * (ax - bx) + (ay - by) * (ay - by))

  test "ohne andere Spieler: offenes Wasser nahe dem Ursprung" do
    for k <- 1..50 do
      {x, y, _h, _} = Spawn.pick(1, [], [], :rand.seed_s(:exsss, k))
      assert Spawn.clear?(1, x, y)
      assert dist({x, y}, {0, 0}) < 60
    end
  end

  test "mit Spielern: 20-40 WE von einem entfernt, nie näher als 12 WE an irgendeinem" do
    others = [{100.0, 50.0}, {110.0, 60.0}]

    for k <- 1..50 do
      {x, y, _h, _} = Spawn.pick(2, others, others, :rand.seed_s(:exsss, k))
      assert Spawn.clear?(2, x, y)
      nearest = others |> Enum.map(&dist({x, y}, &1)) |> Enum.min()
      assert nearest >= 12.0
      assert Enum.any?(others, fn o -> dist({x, y}, o) >= 20.0 and dist({x, y}, o) <= 40.5 end)
    end
  end

  test "deterministisch bei gleichem Zufallszustand, Kurs liegt in -π..π" do
    a = Spawn.pick(3, [{0.0, 0.0}], [{0.0, 0.0}], :rand.seed_s(:exsss, 9))
    b = Spawn.pick(3, [{0.0, 0.0}], [{0.0, 0.0}], :rand.seed_s(:exsss, 9))
    assert elem(a, 0) == elem(b, 0) and elem(a, 1) == elem(b, 1) and elem(a, 2) == elem(b, 2)
    assert elem(a, 2) >= -:math.pi() and elem(a, 2) <= :math.pi()
  end
end
