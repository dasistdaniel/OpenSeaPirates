defmodule Osp.ReputationTest do
  use ExUnit.Case, async: true

  alias Osp.Reputation

  test "standing/1 an den Grenzen" do
    assert Reputation.standing(-100) == :wanted
    assert Reputation.standing(-41) == :wanted
    assert Reputation.standing(-40) == :wanted
    assert Reputation.standing(-39) == :suspicious
    assert Reputation.standing(-10) == :suspicious
    assert Reputation.standing(-9) == :neutral
    assert Reputation.standing(0) == :neutral
    assert Reputation.standing(29) == :neutral
    assert Reputation.standing(30) == :friend
    assert Reputation.standing(100) == :friend
  end

  test "add/3 begrenzt auf -100..100 und ändert nur die genannte Nation" do
    rep = Reputation.start(:france)
    assert Reputation.add(rep, :spain, 500).spain == 100
    assert Reputation.add(rep, :spain, -500).spain == -100
    changed = Reputation.add(rep, :england, -8)
    assert changed.england == -8
    assert %{changed | england: 0} == rep
  end

  test "get/2: fehlende Nation ist 0" do
    assert Reputation.get(%{}, :spain) == 0
    assert Reputation.get(%{spain: 7}, :spain) == 7
  end

  test "penalty/1: Händler 8, Jäger 5, sonst 0" do
    assert Reputation.penalty(:merchant) == 8
    assert Reputation.penalty(:hunter) == 5
    assert Reputation.penalty(:player) == 0
  end

  test "decay/1: jeder Wert um 1 zur 0, nie darüber hinaus" do
    assert Reputation.decay(%{spain: 20, england: -5, france: 0}) ==
             %{spain: 19, england: -4, france: 0}

    assert Reputation.decay(%{spain: 1, england: -1}) == %{spain: 0, england: 0}
  end

  test "start/1: alle fünf Nationen, Heimat +20, sonst 0" do
    rep = Reputation.start(:france)
    assert Map.keys(rep) |> Enum.sort() == Enum.sort(Osp.Nations.all())
    assert rep.france == 20
    assert rep |> Map.delete(:france) |> Map.values() |> Enum.all?(&(&1 == 0))
    assert Reputation.start(nil) |> Map.values() |> Enum.all?(&(&1 == 0))
  end

  test "hunts?/1 ab -10" do
    assert Reputation.hunts?(-10)
    refute Reputation.hunts?(-9)
    refute Reputation.hunts?(20)
  end

  test "label/1 deutsch" do
    assert Reputation.label(:wanted) == "Gesucht"
    assert Reputation.label(:suspicious) == "Misstrauisch"
    assert Reputation.label(:neutral) == "Neutral"
    assert Reputation.label(:friend) == "Freund"
  end
end
