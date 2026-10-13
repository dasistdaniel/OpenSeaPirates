defmodule Osp.HunterTest do
  use ExUnit.Case, async: true

  alias Osp.Hunter

  @pi :math.pi()
  defp water(_x, _y), do: false
  defp ship(opts \\ []), do: Map.merge(%{x: 0.0, y: 0.0, heading: 0.0, speed: 1.0}, Map.new(opts))
  defp rng, do: :rand.seed_s(:exsss, 3)

  test "Gegner genau steuerbord (unten bei Kurs Ost): feuert rechts, nicht links" do
    {keys, fires, _, _} = Hunter.think(ship(), %{x: 0.0, y: 3.0}, nil, &water/2, rng(), nil)
    assert fires == [:right]
    assert keys.up?
  end

  test "Gegner backbord: feuert links" do
    {_, fires, _, _} = Hunter.think(ship(), %{x: 0.0, y: -3.0}, nil, &water/2, rng(), nil)
    assert fires == [:left]
  end

  test "Gegner voraus oder weit weg: kein Schuss, Kurs auf den Gegner" do
    {_, fires, _, _} = Hunter.think(ship(), %{x: 3.0, y: 0.0}, nil, &water/2, rng(), nil)
    assert fires == []

    {keys, fires, _, _} =
      Hunter.think(ship(heading: @pi), %{x: 20.0, y: 0.0}, nil, &water/2, rng(), nil)

    assert fires == []
    # Gegner liegt hinten: er dreht
    assert keys.left? or keys.right?
  end

  test "ohne Gegner patrouilliert er und schießt nicht" do
    {keys, fires, target, _} = Hunter.think(ship(), nil, nil, &water/2, rng(), nil)
    assert fires == [] and keys.up? and target != nil
  end

  test "Land voraus: er dreht ab statt stur auf den Gegner zu" do
    land = fn x, _y -> x > 1.5 end
    {keys, _, _, _} = Hunter.think(ship(), %{x: 12.0, y: 0.0}, nil, land, rng(), nil)
    assert keys.right?
  end
end
