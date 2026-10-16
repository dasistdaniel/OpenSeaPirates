defmodule Osp.Sailing do
  @moduledoc """
  Schiffsphysik (rein): Tempo, Wenden, Wind und Kollision mit dem Gelände.

  Ein Schiff ist eine Map mit `:x`, `:y`, `:heading` (Bogenmaß, Bildschirmkoordinaten: y nach
  unten, Kurs wächst im Uhrzeigersinn, "rechts" ist Kurs + 90°) und `:speed` (WE/s).

  Gelände wird als Funktion `solid?.(x, y)` übergeben (Land ja/nein), damit die Physik ohne
  `Osp.Terrain` testbar ist.
  """

  @pi :math.pi()

  # Startwerte, siehe docs/handout.md §4
  @ship_r 0.36
  @max_speed 2.0
  @accel 1.5
  @coast 0.7
  @turn 1.4
  @wind_effect 0.4
  @bump_speed 0.35
  # Ruderlegen kostet Fahrt: bei voll eingeschlagenem Ruder gehen pro Sekunde 120 % des Tempos
  # verloren (Beschleunigung gleicht einen Teil aus). Dauerkreisen macht langsam, Vorbeifahrten lohnen.
  @turn_drag 1.2

  def ship_radius, do: @ship_r
  def max_speed, do: @max_speed

  @type keys :: %{up?: boolean(), left?: boolean(), right?: boolean()}
  @type ship :: %{x: float(), y: float(), heading: float(), speed: float()}

  @doc "Tempofaktor durch den Wind: 1,4 mit dem Wind, 0,6 dagegen, 1,0 quer."
  @spec wind_factor(float(), float()) :: float()
  def wind_factor(heading, wind_angle), do: 1.0 + @wind_effect * :math.cos(heading - wind_angle)

  @doc "Windrichtung (Bogenmaß) zu einem Richtungsindex 0..5; der Wind weht dorthin."
  @spec wind_angle(0..5) :: float()
  def wind_angle(dir), do: -dir * @pi / 3

  @doc """
  Ein Zeitschritt `dt` (Sekunden) für ein Schiff. `opts`: `:cap_mult` (Faktor aufs Höchsttempo,
  z. B. Händler 0,6), `:turn_mult` (Faktor auf die Wendigkeit) und `:accel_mult` (Beschleunigung).
  Der Rumpfradius kommt aus `ship.radius` (sonst #{@ship_r} WE).
  """
  @spec step(ship(), keys(), float(), float(), (number(), number() -> boolean()), keyword()) ::
          ship()
  def step(ship, keys, dt, wind_angle, solid?, opts \\ []) do
    cap_mult = Keyword.get(opts, :cap_mult, 1.0)
    accel = @accel * Keyword.get(opts, :accel_mult, 1.0)
    turn_mult = Keyword.get(opts, :turn_mult, 1.0)
    r = Map.get(ship, :radius, @ship_r)
    turn = (if(keys.right?, do: 1, else: 0) - if(keys.left?, do: 1, else: 0)) * 1.0
    grip = 0.45 + 0.55 * min(1.0, ship.speed / @max_speed)
    heading = ship.heading + turn * @turn * turn_mult * grip * dt

    cap = @max_speed * cap_mult * wind_factor(heading, wind_angle)

    speed =
      cond do
        keys.up? and ship.speed > cap -> max(ship.speed - 2 * dt, cap)
        keys.up? -> min(ship.speed + accel * dt, cap)
        true -> max(ship.speed - if(ship.speed > cap, do: 2, else: @coast) * dt, 0.0)
      end

    speed = speed * (1.0 - min(@turn_drag * abs(turn) * dt, 0.5))

    nx = ship.x + :math.cos(heading) * speed * dt
    ny = ship.y + :math.sin(heading) * speed * dt
    ship = %{ship | heading: heading, speed: speed}

    cond do
      not blocked?(solid?, nx, ny, r) ->
        %{ship | x: nx, y: ny}

      true ->
        case push_out(solid?, nx, ny, r) do
          {px, py} -> %{ship | x: px, y: py, speed: speed * @bump_speed}
          nil -> %{ship | speed: speed * @bump_speed}
        end
    end
  end

  @doc "Berührt das Schiff an `(x, y)` Land? (Mittelpunkt + 8 Punkte auf dem Rumpfkreis)"
  @spec blocked?((number(), number() -> boolean()), number(), number(), number()) :: boolean()
  def blocked?(solid?, x, y, r \\ @ship_r), do: blocked_points(solid?, x, y, r) != []

  defp blocked_points(solid?, x, y, r) do
    for {dx, dy} <- sample_offsets(), solid?.(x + dx * r, y + dy * r), do: {dx, dy}
  end

  @offsets (for k <- 0..7 do
              a = k * @pi / 4
              {:math.cos(a), :math.sin(a)}
            end) ++ [{0.0, 0.0}]
  defp sample_offsets, do: @offsets

  # Schiff aus dem Land schieben: weg von den berührenden Punkten, in kleinen Schritten
  defp push_out(solid?, x, y, r), do: push_out(solid?, x, y, r, 24)
  defp push_out(_solid?, _x, _y, _r, 0), do: nil

  defp push_out(solid?, x, y, r, n) do
    case blocked_points(solid?, x, y, r) do
      [] ->
        {x, y}

      pts ->
        {sx, sy} = Enum.reduce(pts, {0.0, 0.0}, fn {dx, dy}, {ax, ay} -> {ax + dx, ay + dy} end)
        len = :math.sqrt(sx * sx + sy * sy)

        if len < 1.0e-6,
          do: nil,
          else: push_out(solid?, x - sx / len * 0.04, y - sy / len * 0.04, r, n - 1)
    end
  end
end
