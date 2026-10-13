defmodule Osp.Spawn do
  @moduledoc """
  Startpunkt für ein neues Schiff (rein, mit übergebenem Zufallszustand).

  Gibt es andere Spieler, landet man **20–40 WE** (1–2 Bildschirme) von einem davon entfernt,
  aber nie näher als 12 WE an irgendeinem Schiff. Gibt es keine, startet man in Ursprungsnähe.
  Der Punkt ist immer offenes Wasser mit Platz um das Schiff.
  """

  alias Osp.Terrain

  @min_gap 12.0
  @near 20.0
  @far 40.0
  @clearance 2.0
  @tries 60

  @doc """
  `others`: Positionen `[{x, y}]` aller Schiffe, `humans`: Positionen der Spieler (Ziel der Nähe).
  Gibt `{x, y, heading, rng}` zurück.
  """
  @spec pick(integer(), [{float(), float()}], [{float(), float()}], :rand.state()) ::
          {float(), float(), float(), :rand.state()}
  def pick(seed, others, humans, rng) do
    {found, rng} = search(seed, others, humans, rng, @tries)

    {{x, y}, rng} =
      case found do
        nil -> fallback(seed, rng)
        point -> {point, rng}
      end

    {heading, rng} = :rand.uniform_s(rng)
    {x, y, heading * 2 * :math.pi() - :math.pi(), rng}
  end

  @doc "Offenes Wasser mit Abstand `r` rundum?"
  @spec clear?(integer(), number(), number(), number()) :: boolean()
  def clear?(seed, x, y, r \\ @clearance) do
    limit = Terrain.land_level() - 0.03

    Enum.all?(
      [{0, 0}, {r, 0}, {-r, 0}, {0, r}, {0, -r}, {r * 0.7, r * 0.7}, {-r * 0.7, -r * 0.7}],
      fn {dx, dy} -> Terrain.height(seed, x + dx, y + dy) < limit end
    )
  end

  defp search(_seed, _others, _humans, rng, 0), do: {nil, rng}

  defp search(seed, others, humans, rng, tries) do
    {{x, y}, rng} = candidate(humans, rng)

    ok? =
      clear?(seed, x, y) and
        Enum.all?(others, fn {ox, oy} -> dist(x, y, ox, oy) >= @min_gap end)

    if ok?, do: {{x, y}, rng}, else: search(seed, others, humans, rng, tries - 1)
  end

  # Mit Spielern: Ring um einen zufälligen Spieler. Ohne: Scheibe um den Ursprung.
  defp candidate([], rng) do
    {a, rng} = :rand.uniform_s(rng)
    {r, rng} = :rand.uniform_s(rng)
    angle = a * 2 * :math.pi()
    dist = :math.sqrt(r) * 12.0
    {{:math.cos(angle) * dist, :math.sin(angle) * dist}, rng}
  end

  defp candidate(humans, rng) do
    {i, rng} = :rand.uniform_s(length(humans), rng)
    {bx, by} = Enum.at(humans, i - 1)
    {a, rng} = :rand.uniform_s(rng)
    {d, rng} = :rand.uniform_s(rng)
    angle = a * 2 * :math.pi()
    dist = @near + d * (@far - @near)
    {{bx + :math.cos(angle) * dist, by + :math.sin(angle) * dist}, rng}
  end

  # Letzter Ausweg: Spirale um den Ursprung bis zu offenem Wasser
  defp fallback(seed, rng) do
    point =
      Enum.find_value(0..400, {0.0, 0.0}, fn k ->
        a = k * 2.399963
        r = :math.sqrt(k) * 2.5
        x = :math.cos(a) * r
        y = :math.sin(a) * r
        if clear?(seed, x, y), do: {x, y}
      end)

    {point, rng}
  end

  defp dist(ax, ay, bx, by), do: :math.sqrt((ax - bx) * (ax - bx) + (ay - by) * (ay - by))
end
