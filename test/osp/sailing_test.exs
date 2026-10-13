defmodule Osp.SailingTest do
  use ExUnit.Case, async: true

  alias Osp.Sailing

  @pi :math.pi()
  @none %{up?: false, left?: false, right?: false}

  defp water(_x, _y), do: false

  defp ship(opts \\ []),
    do: Map.merge(%{x: 0.0, y: 0.0, heading: 0.0, speed: 0.0}, Map.new(opts))

  # `wind`: Windwinkel; Standard quer zum Kurs 0 (kein Bonus)
  defp run(ship, keys, seconds, wind \\ @pi / 2, solid \\ &water/2) do
    Enum.reduce(1..round(seconds * 40), ship, fn _, s ->
      Sailing.step(s, keys, 0.025, wind, solid)
    end)
  end

  test "W beschleunigt bis zum Höchsttempo, ohne W rollt das Schiff aus" do
    s = run(ship(), %{@none | up?: true}, 4.0)
    assert_in_delta s.speed, Sailing.max_speed(), 0.01
    assert s.x > 3.0

    s = run(s, @none, 6.0)
    assert s.speed == 0.0
  end

  test "D dreht im Uhrzeigersinn (Kurs wächst), A dagegen" do
    s = run(ship(speed: 1.0), %{@none | up?: true, right?: true}, 0.5)
    assert s.heading > 0.3
    s = run(ship(speed: 1.0), %{@none | up?: true, left?: true}, 0.5)
    assert s.heading < -0.3
  end

  test "Wind: Rückenwind schneller, Gegenwind langsamer, quer normal" do
    keys = %{@none | up?: true}
    tail = run(ship(), keys, 5.0, 0.0).speed
    head = run(ship(), keys, 5.0, @pi).speed
    side = run(ship(), keys, 5.0, @pi / 2).speed

    assert_in_delta tail, Sailing.max_speed() * 1.4, 0.02
    assert_in_delta head, Sailing.max_speed() * 0.6, 0.02
    assert_in_delta side, Sailing.max_speed(), 0.02

    assert_in_delta Sailing.wind_factor(0.0, 0.0), 1.4, 1.0e-9
    assert_in_delta Sailing.wind_factor(0.0, @pi), 0.6, 1.0e-9
  end

  test "Windrichtungen: 0 = Ost, 1 = Nordost (y nach oben ist negativ)" do
    assert Sailing.wind_angle(0) == 0.0
    assert_in_delta Sailing.wind_angle(1), -@pi / 3, 1.0e-9
    assert_in_delta Sailing.wind_angle(3), -@pi, 1.0e-9
  end

  test "Land hält das Schiff auf: es fährt nicht hinein" do
    # alles rechts von x = 5 ist Land
    land = fn x, _y -> x > 5.0 end
    s = run(ship(), %{@none | up?: true}, 12.0, @pi / 2, land)

    refute Sailing.blocked?(land, s.x, s.y)
    assert s.x < 5.0 - Sailing.ship_radius() + 0.05
    assert s.x > 4.0
  end

  test "schräg ans Ufer: Schiff gleitet entlang statt festzukleben" do
    land = fn x, _y -> x > 5.0 end
    start = ship(x: 4.0, y: 0.0, heading: @pi / 4, speed: 1.0)
    s = run(start, %{@none | up?: true}, 6.0, @pi / 2, land)
    assert s.y > 1.0
    refute Sailing.blocked?(land, s.x, s.y)
  end
end
