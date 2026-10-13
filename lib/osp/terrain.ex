defmodule Osp.Terrain do
  @moduledoc """
  Prozedurales Gelände der unendlichen Welt: ein stetiges Höhenfeld `height(seed, x, y)` in 0..1
  (mehrere Oktaven Value-Noise). Land ist, wo die Höhe `land_level/0` erreicht.

  Alles ist rein und deterministisch (gleicher Seed → gleiche Welt), nichts wird gespeichert.
  Koordinaten sind Welteinheiten (WE); `x` wächst nach rechts, `y` nach unten.

  Der Client bekommt Gelände als **Chunks**: `chunk/3` liefert die Höhen eines 16×16-WE-Blocks mit
  zwei Stützstellen je WE (33×33 Bytes, inklusive Randreihe, damit Nachbarn nahtlos passen).
  Der Server selbst fragt für Kollisionen direkt `height/3` ab.
  """

  @land 0.66
  @chunk 16
  @res 2
  @edge @chunk * @res + 1

  # Oktaven: {Wellenlänge in WE, Gewicht}
  @octaves [{64.0, 0.4}, {22.0, 1.0}, {11.0, 0.55}, {5.5, 0.28}, {3.0, 0.12}]
  @weight Enum.sum(for {_, w} <- @octaves, do: w)

  @doc "Höhe ab der Land beginnt."
  def land_level, do: @land
  def chunk_size, do: @chunk
  @doc "Stützstellen je WE im Chunk."
  def resolution, do: @res
  @doc "Stützstellen je Chunk-Kante (inkl. Randreihe)."
  def edge, do: @edge

  @doc "Höhe 0..1 an einem Weltpunkt."
  @spec height(integer(), number(), number()) :: float()
  def height(seed, x, y) do
    sum =
      @octaves
      |> Enum.with_index()
      |> Enum.reduce(0.0, fn {{wavelength, w}, i}, acc ->
        acc + w * value_noise(seed + i * 7919, x / wavelength, y / wavelength)
      end)

    # Summe von Value-Noise ist um 0,5 verteilt; leicht spreizen, damit Land/Meer klar getrennt sind
    sum
    |> Kernel./(@weight)
    |> then(&(0.5 + (&1 - 0.5) * 1.35))
    |> max(0.0)
    |> min(1.0)
  end

  @doc "Land (befestigt) an einem Weltpunkt?"
  @spec land?(integer(), number(), number()) :: boolean()
  def land?(seed, x, y), do: height(seed, x, y) >= @land

  @doc "Chunk-Koordinaten eines Weltpunkts."
  @spec chunk_of(number(), number()) :: {integer(), integer()}
  def chunk_of(x, y), do: {floor(x / @chunk), floor(y / @chunk)}

  @doc """
  Höhen eines Chunks als Binary (`edge/0`² Bytes, Zeile für Zeile von oben, Wert = Höhe·255).
  """
  @spec chunk(integer(), integer(), integer()) :: binary()
  def chunk(seed, cx, cy) do
    x0 = cx * @chunk
    y0 = cy * @chunk

    for j <- 0..(@edge - 1), i <- 0..(@edge - 1), into: <<>> do
      h = height(seed, x0 + i / @res, y0 + j / @res)
      <<round(h * 255)>>
    end
  end

  # --- Value-Noise ---------------------------------------------------------------

  defp value_noise(seed, x, y) do
    ix = floor(x)
    iy = floor(y)
    fx = smooth(x - ix)
    fy = smooth(y - iy)

    a = lattice(seed, ix, iy)
    b = lattice(seed, ix + 1, iy)
    c = lattice(seed, ix, iy + 1)
    d = lattice(seed, ix + 1, iy + 1)

    top = a + (b - a) * fx
    bottom = c + (d - c) * fx
    top + (bottom - top) * fy
  end

  defp smooth(t), do: t * t * (3.0 - 2.0 * t)

  # :erlang.phash2 ist über Versionen und Knoten hinweg stabil (portable hash)
  defp lattice(seed, ix, iy), do: :erlang.phash2({seed, ix, iy}, 1_000_000) / 999_999
end
