defmodule Osp.Hunter do
  @moduledoc """
  KI der Piratenjäger und kämpfender Händler (rein). Statt den Gegner endlos zu umkreisen, fährt
  sie **Angriffsläufe** in drei Phasen (gemerkt in `ship.run`, `%{phase:, at:}`):

    * `:approach` – direkt auf den Gegner zu, bis er nah genug ist
    * `:pass` – Gegner querab halten und die Breitseite abgeben; endet, sobald die dem Gegner
      zugewandte Seite abgefeuert hat (oder er hinter dem Schiff liegt bzw. zu viel Zeit verging)
    * `:break` – vom Gegner wegdrehen und nachladen; sind Abstand und Kanonen bereit, folgt der
      nächste Anlauf

  Ohne Ziel patrouilliert das Schiff wie `Osp.Wander`. Land voraus wird umfahren. Ob nachgeladen
  ist, prüft `Osp.Combat.fire/3`; `fires` ist eine Liste aus `:left | :right`.
  """

  alias Osp.Wander

  @pi :math.pi()
  @range 4.2
  # Ab diesem Abstand beginnt der Vorbeilauf, ab diesem Abstand und mit geladenen Kanonen der nächste Anlauf
  @pass_dist 5.5
  @return_dist 7.5
  @pass_max_ms 6_000
  @break_max_ms 9_000

  @type target :: %{x: float(), y: float()} | nil
  @type run :: %{phase: :approach | :pass | :break, at: integer()} | nil

  @doc """
  Ohne Gegner patrouillieren (`{keys, [], wander_target, rng}`). Mit Gegner ein zustandsloser
  Einzelschritt von `attack/4` (der Lauf beginnt jedes Mal neu); das Spiel nutzt `attack/4`.
  """
  @spec think(map(), target(), term(), (number(), number() -> boolean()), :rand.state(), any()) ::
          {map(), [:left | :right], term(), :rand.state()}
  def think(ship, nil, wander_target, solid?, rng, _opts) do
    {keys, target, rng} = Wander.think(ship, wander_target, solid?, rng)
    {keys, [], target, rng}
  end

  def think(ship, enemy, wander_target, solid?, rng, _opts) do
    {keys, fires, _run} = attack(Map.put(ship, :run, nil), enemy, solid?, 0)
    {keys, fires, wander_target, rng}
  end

  @doc """
  Ein Denkschritt im Kampf gegen `enemy` zum Spielzeitpunkt `time` (ms): `{keys, fires, run}`.
  `run` ist der neue Laufzustand für `ship.run`.
  """
  @spec attack(map(), map(), (number(), number() -> boolean()), integer()) ::
          {map(), [:left | :right], run()}
  def attack(ship, enemy, solid?, time) do
    to = :math.atan2(enemy.y - ship.y, enemy.x - ship.x)
    dist = :math.sqrt(:math.pow(enemy.x - ship.x, 2) + :math.pow(enemy.y - ship.y, 2))
    rel = norm(to - ship.heading)

    lead = lead(ship)
    run = advance(Map.get(ship, :run) || start(dist, time), ship, dist, rel, time)
    want = steer(run.phase, ship, to, dist, lead)
    want = if blocked_ahead?(ship, solid?), do: Wander.escape_heading(ship, solid?), else: want

    diff = norm(want - ship.heading)
    keys = %{up?: true, left?: diff < -0.1, right?: diff > 0.1}
    {keys, fire_sides(rel, dist, lead), run}
  end

  defp start(dist, time),
    do: %{phase: if(dist <= @pass_dist, do: :pass, else: :approach), at: time}

  defp advance(%{phase: :approach} = run, _ship, dist, _rel, time),
    do: if(dist <= @pass_dist, do: %{phase: :pass, at: time}, else: run)

  defp advance(%{phase: :pass, at: at} = run, ship, dist, rel, time) do
    if abs(rel) > @pi / 2 + 0.8 or dist < 1.0 or facing_side_empty?(ship, rel) or
         time - at > @pass_max_ms,
       do: %{phase: :break, at: time},
       else: run
  end

  defp advance(%{phase: :break, at: at} = run, ship, dist, _rel, time) do
    if (dist > @return_dist and loaded?(ship)) or time - at > @break_max_ms,
      do: %{phase: :approach, at: time},
      else: run
  end

  defp advance(_other, _ship, dist, _rel, time), do: start(dist, time)

  defp steer(:approach, _ship, to, _dist, _lead), do: to
  defp steer(:break, _ship, to, _dist, _lead), do: to + @pi

  # Querab: auf der Seite, wo die kleinere Kursänderung nötig ist, leicht zum Gegner hin (zu weit)
  # oder von ihm weg (zu nah)
  defp steer(:pass, ship, to, dist, lead) do
    a = to + @pi / 2
    b = to - @pi / 2
    sign = if abs(norm(a - ship.heading)) <= abs(norm(b - ship.heading)), do: 1, else: -1

    bias =
      cond do
        dist > 3.6 -> 0.35
        dist < 2.4 -> -0.35
        true -> 0.0
      end

    to + sign * (@pi / 2 - lead - bias)
  end

  # Kugeln erben 80 % der Fahrt des Schiffs: sie fliegen leicht nach vorn, der Gegner soll also
  # etwas vor der Querabrichtung liegen
  defp lead(ship), do: :math.atan(0.8 * Map.get(ship, :speed, 0.0) / 6.0)

  # Wer nur Pech hat und gerade eine Seite geladen hat, schießt trotzdem, sobald der Gegner im Bogen liegt
  defp fire_sides(rel, dist, lead) do
    cond do
      dist > @range -> []
      abs(rel - (@pi / 2 - lead)) < 0.15 -> [:right]
      abs(rel + (@pi / 2 - lead)) < 0.15 -> [:left]
      true -> []
    end
  end

  defp loaded?(ship), do: Map.get(ship, :reload_l, 0) <= 0 or Map.get(ship, :reload_r, 0) <= 0

  # Die Seite zum Gegner hat abgefeuert: dieser Vorbeilauf ist erledigt
  defp facing_side_empty?(ship, rel) do
    key = if rel >= 0, do: :reload_r, else: :reload_l
    Map.get(ship, key, 0) > 0
  end

  defp blocked_ahead?(ship, solid?) do
    solid?.(
      ship.x + :math.cos(ship.heading) * 2.2,
      ship.y + :math.sin(ship.heading) * 2.2
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
