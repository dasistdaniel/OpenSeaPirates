defmodule Osp.Wander do
  @moduledoc """
  Einfacher Wander-Bot (Platzhalter für spätere NPC-Schiffe): fährt zu zufälligen Zielpunkten,
  weicht Land aus und wählt ein neues Ziel, wenn er angekommen ist oder festhängt.

  Rein: `think/5` bekommt Schiff, Ziel, Gelände, Zufallszustand und optional einen Punkt, vor dem
  geflohen wird, und liefert Tasten, Ziel, RNG.
  """

  alias Osp.Sailing

  @pi :math.pi()
  @lookahead 2.2

  @type target :: {float(), float()} | nil

  @spec think(
          map(),
          target(),
          (number(), number() -> boolean()),
          :rand.state(),
          {float(), float()} | nil
        ) :: {Sailing.keys(), target(), :rand.state()}
  def think(ship, target, solid?, rng, flee \\ nil) do
    {target, rng} =
      if target == nil or dist(ship, target) < 2.0, do: new_target(ship, rng), else: {target, rng}

    ahead_x = ship.x + :math.cos(ship.heading) * @lookahead
    ahead_y = ship.y + :math.sin(ship.heading) * @lookahead

    want =
      if solid?.(ahead_x, ahead_y) or
           solid?.(ship.x + :math.cos(ship.heading) * 1.0, ship.y + :math.sin(ship.heading) * 1.0) do
        # Land voraus: nach rechts abdrehen
        ship.heading + 1.2
      else
        case flee do
          {fx, fy} ->
            # weg vom Angreifer
            :math.atan2(ship.y - fy, ship.x - fx)

          nil ->
            {tx, ty} = target
            :math.atan2(ty - ship.y, tx - ship.x)
        end
      end

    diff = norm(want - ship.heading)
    keys = %{up?: true, left?: diff < -0.1, right?: diff > 0.1}
    {keys, target, rng}
  end

  defp new_target(ship, rng) do
    {a, rng} = :rand.uniform_s(rng)
    {d, rng} = :rand.uniform_s(rng)
    angle = a * 2 * @pi
    dist = 15.0 + d * 35.0
    {{ship.x + :math.cos(angle) * dist, ship.y + :math.sin(angle) * dist}, rng}
  end

  defp dist(ship, {tx, ty}),
    do: :math.sqrt((tx - ship.x) * (tx - ship.x) + (ty - ship.y) * (ty - ship.y))

  # Winkel in [-π, π)
  defp norm(a) do
    a = :math.fmod(a + @pi, 2 * @pi)
    a = if a < 0, do: a + 2 * @pi, else: a
    a - @pi
  end
end
