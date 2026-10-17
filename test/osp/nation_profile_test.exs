defmodule Osp.NationProfileTest do
  use ExUnit.Case, async: true

  alias Osp.{Profile, Ships, Shop, State}

  defp ship(extra \\ %{}) do
    base = State.join(State.new(4, 0), "tok-aaaa-bbbb", "Anna").ships["tok-aaaa-bbbb"]
    Map.merge(base, extra)
  end

  describe "Profil" do
    test "decode/1: gültige Nation bleibt, alles andere wird nil" do
      assert Profile.decode(%{"nation" => "france"})["nation"] == "france"

      for bad <- ["xyz", 7, nil, ["spain"], %{}],
          do: assert(Profile.decode(%{"nation" => bad})["nation"] == nil)

      assert Profile.decode(%{})["nation"] == nil
      assert Profile.new()["nation"] == nil
    end

    test "altes Profil ohne Nation geht verlustfrei durch decode/1" do
      old = %{"v" => 1, "name" => "Anna", "gold" => 123, "bank" => 50, "class" => "klipper"}
      p = Profile.decode(old)
      assert %{"gold" => 123, "bank" => 50, "class" => "klipper", "nation" => nil} = p
      assert p["v"] == 3
    end

    test "from_ship/1 und apply/2: Nation macht den Rundlauf" do
      s = ship(%{nation: :spain})
      assert Profile.from_ship(s)["nation"] == "spain"
      assert Profile.from_ship(ship())["nation"] == nil

      applied = Profile.apply(ship(), Profile.decode(%{"nation" => "spain"}))
      assert applied.nation == :spain
      assert applied.max_hp == 14 and applied.hp == 14.0
    end
  end

  describe "Boni in den Schiffswerten" do
    defp stats(nation),
      do: Ships.stats(%{class: :schaluppe, upgrades: Ships.fresh().upgrades, nation: nation})

    test "jede Nation wirkt auf genau ihren Wert" do
      assert stats(:spain).max_hp == 14
      assert_in_delta stats(:england).dmg_mult, 1.08, 1.0e-9
      assert_in_delta stats(:france).turn_mult, 1.06, 1.0e-9
      assert_in_delta stats(:portugal).speed_mult, 1.05, 1.0e-9
    end

    test "ohne Nation oder mit Niederlande bleiben die Basiswerte" do
      none = Ships.stats(%{class: :schaluppe, upgrades: Ships.fresh().upgrades})
      assert none.max_hp == 12 and none.dmg_mult == 1.0
      assert none.speed_mult == 1.0 and none.turn_mult == 1.0
      assert stats(:netherlands).max_hp == 12
    end
  end

  describe "Reparaturpreis" do
    test "Niederländer zahlen 3 Gold je HP, sonst 4" do
      assert Shop.repair_price_per_hp(%{nation: :netherlands}) == 3
      assert Shop.repair_price_per_hp(%{nation: :spain}) == 4
      assert Shop.repair_price_per_hp(%{}) == 4
    end

    test "repair/1, repair_cost/1 und die Hafen-Ansicht nutzen denselben Preis" do
      s = ship(%{gold: 100, hp: 8.0, nation: :netherlands})
      assert Shop.repair_cost(s) == 12
      assert {:ok, repaired} = Shop.repair(s)
      assert repaired.gold == 100 - 12 and repaired.hp == 12.0
      assert Shop.view(s, "Hafen").repair == %{cost: 12, per_hp: 3}

      plain = ship(%{gold: 100, hp: 8.0})
      assert {:ok, r2} = Shop.repair(plain)
      assert r2.gold == 100 - 16
    end
  end
end
