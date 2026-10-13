defmodule Osp.Hunter do
  @moduledoc """
  KI der Piratenjäger (rein): sucht sich einen Spieler in der Nähe, bringt ihn **querab** (die
  Breitseite zeigt auf ihn), hält Abstand und feuert, sobald er im Schussbogen und in Reichweite
  liegt. Ohne Ziel patrouilliert er wie `Osp.Wander`. Land voraus wird umfahren.

  `think/6` liefert `{keys, fires, wander_target, rng}`; `fires` ist eine Liste aus `:left | :right`.
  Ob nachgeladen ist, prüft `Osp.Combat.fire/3`.
  """

  alias Osp.Wander

  @pi :math.pi()
  @range 4.2
  @lookahead 2.2

  @type target :: %{x: float(), y: float()} | nil

  @spec think(map(), target(), term(), (number(), number() -> boolean()), :rand.state(), any()) ::
          {map(), [:left | :right], term(), :rand.state()}
  def think(ship, nil, wander_target, solid?, rng, _opts) do
    {keys, target, rng} = Wander.think(ship, wander_target, solid?, rng)
    {keys, [], target, rng}
  end

  def think(ship, enemy, wander_target, solid?, rng, _opts) do
    to = :math.atan2(enemy.y - ship.y, enemy.x - ship.x)
    dist = :math.sqrt(:math.pow(enemy.x - ship.x, 2) + :math.pow(enemy.y - ship.y, 2))

    # Seite wählen, auf der die kleinere Kursänderung nötig ist; dann leicht zum Gegner hin
    # (zu weit weg) oder von ihm weg (zu nah) halten, damit er in Schussweite kreist statt zu
    # tangential zu fahren
    a = to + @pi / 2
    b = to - @pi / 2
    sign = if abs(norm(a - ship.heading)) <= abs(norm(b - ship.heading)), do: 1, else: -1

    bias =
      cond do
        dist > 3.6 -> 0.35
        dist < 2.4 -> -0.35
        true -> 0.0
      end

    abeam = to + sign * (@pi / 2 - bias)
    want = if dist > @range + 1.5, do: to, else: abeam

    want =
      if blocked_ahead?(ship, solid?), do: ship.heading + 1.2, else: want

    diff = norm(want - ship.heading)
    keys = %{up?: true, left?: diff < -0.1, right?: diff > 0.1}

    rel = norm(to - ship.heading)

    fires =
      cond do
        dist > @range -> []
        abs(rel - @pi / 2) < 0.45 -> [:right]
        abs(rel + @pi / 2) < 0.45 -> [:left]
        true -> []
      end

    {keys, fires, wander_target, rng}
  end

  defp blocked_ahead?(ship, solid?) do
    solid?.(
      ship.x + :math.cos(ship.heading) * @lookahead,
      ship.y + :math.sin(ship.heading) * @lookahead
    ) or
      solid?.(ship.x + :math.cos(ship.heading), ship.y + :math.sin(ship.heading))
  end

  # Winkel in [-π, π)
  defp norm(a) do
    a = :math.fmod(a + @pi, 2 * @pi)
    a = if a < 0, do: a + 2 * @pi, else: a
    a - @pi
  end
end
