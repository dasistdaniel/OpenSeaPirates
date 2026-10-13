defmodule Osp.TerrainTest do
  use ExUnit.Case, async: true

  alias Osp.Terrain

  test "gleicher Seed liefert dieselbe Welt, anderer Seed eine andere" do
    assert Terrain.height(7, 12.3, -4.5) == Terrain.height(7, 12.3, -4.5)
    assert Terrain.chunk(7, 2, -3) == Terrain.chunk(7, 2, -3)
    refute Terrain.chunk(7, 2, -3) == Terrain.chunk(8, 2, -3)
  end

  test "Höhen liegen in 0..1" do
    for x <- -200..200//37, y <- -200..200//41 do
      h = Terrain.height(3, x * 1.0, y * 1.0)
      assert h >= 0.0 and h <= 1.0
    end
  end

  test "Landanteil ist sinnvoll (10-25 %)" do
    {land, n} =
      for x <- -300..300//7, y <- -300..300//7, reduce: {0, 0} do
        {l, n} -> {if(Terrain.land?(5, x * 1.0, y * 1.0), do: l + 1, else: l), n + 1}
      end

    assert land / n > 0.10 and land / n < 0.25
  end

  test "Chunk hat edge² Bytes und passt nahtlos an die Nachbarn" do
    e = Terrain.edge()
    left = Terrain.chunk(11, 0, 0)
    right = Terrain.chunk(11, 1, 0)
    below = Terrain.chunk(11, 0, 1)
    assert byte_size(left) == e * e

    # rechte Randspalte des linken Chunks == linke Randspalte des rechten
    for j <- 0..(e - 1) do
      assert :binary.at(left, j * e + (e - 1)) == :binary.at(right, j * e)
    end

    # untere Randzeile == obere Randzeile des Chunks darunter
    for i <- 0..(e - 1) do
      assert :binary.at(left, (e - 1) * e + i) == :binary.at(below, i)
    end
  end

  test "Chunk-Werte entsprechen height/3 an den Stützstellen" do
    seed = 9
    chunk = Terrain.chunk(seed, -2, 3)
    e = Terrain.edge()
    x0 = -2 * Terrain.chunk_size()
    y0 = 3 * Terrain.chunk_size()
    res = Terrain.resolution()

    for {i, j} <- [{0, 0}, {5, 7}, {32, 32}, {17, 3}] do
      h = Terrain.height(seed, x0 + i / res, y0 + j / res)
      assert :binary.at(chunk, j * e + i) == round(h * 255)
    end
  end

  test "chunk_of rechnet Weltpunkte in Chunks um (auch negativ)" do
    assert Terrain.chunk_of(0.0, 0.0) == {0, 0}
    assert Terrain.chunk_of(15.99, 16.0) == {0, 1}
    assert Terrain.chunk_of(-0.01, -16.01) == {-1, -2}
  end
end
