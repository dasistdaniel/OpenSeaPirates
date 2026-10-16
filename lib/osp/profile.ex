defmodule Osp.Profile do
  @moduledoc """
  Dauerhafter Spielstand eines Spielers (rein): was beim Beitreten wiederhergestellt wird.

  Gespeichert werden Name, Gold (getragen), Bank, Schiffsklasse, Upgrades, Munition und Statistik –
  nicht Position, Kampfzustand oder angedockt. Das Format ist JSON-tauglich (Strings, Zahlen,
  Maps); `decode/1` prüft jeden Wert gegen feste Listen und Grenzen, damit eine kaputte oder
  manipulierte Datei nie das Spiel zum Absturz bringt (unbekannte Klasse → Startschiff usw.).
  """

  alias Osp.{Ships, Shop}

  @version 1
  @max_gold 100_000_000
  @classes Map.new(Ships.order(), &{Atom.to_string(&1), &1})
  @slots %{"cannons" => :cannons, "hull" => :hull, "sails" => :sails}

  @doc "Stand eines frischen Spielers."
  def new do
    %{
      "v" => @version,
      "name" => "",
      "gold" => 0,
      "bank" => 0,
      "class" => "schaluppe",
      "upgrades" => %{"cannons" => 0, "hull" => 0, "sails" => 0},
      "ammo" => %{"chain" => 0, "fire" => 0},
      "kills" => 0,
      "deaths" => 0
    }
  end

  @doc "Spielstand aus einem Spielerschiff (JSON-tauglich)."
  @spec from_ship(map()) :: map()
  def from_ship(ship) do
    %{
      "v" => @version,
      "name" => ship.name,
      "gold" => ship.gold,
      "bank" => ship.bank,
      "class" => Atom.to_string(ship.class),
      "upgrades" => Map.new(ship.upgrades, fn {slot, level} -> {Atom.to_string(slot), level} end),
      "ammo" => %{
        "chain" => Map.get(ship.ammo, :chain, 0),
        "fire" => Map.get(ship.ammo, :fire, 0)
      },
      "kills" => ship.kills,
      "deaths" => ship.deaths
    }
  end

  @doc """
  Prüft und bereinigt einen geladenen Spielstand (aus JSON). Gibt immer einen gültigen Stand zurück;
  `nil` oder Unsinn ergibt den Stand eines neuen Spielers.
  """
  @spec decode(term()) :: map()
  def decode(%{} = raw) do
    up = if is_map(raw["upgrades"]), do: raw["upgrades"], else: %{}
    ammo = if is_map(raw["ammo"]), do: raw["ammo"], else: %{}

    %{
      "v" => @version,
      "name" => if(is_binary(raw["name"]), do: String.slice(raw["name"], 0, 20), else: ""),
      "gold" => int(raw["gold"], 0, @max_gold),
      "bank" => int(raw["bank"], 0, @max_gold),
      "class" => if(Map.has_key?(@classes, raw["class"]), do: raw["class"], else: "schaluppe"),
      "upgrades" => Map.new(@slots, fn {key, _} -> {key, int(up[key], 0, Ships.max_level())} end),
      "ammo" => %{
        "chain" => int(ammo["chain"], 0, Shop.ammo_max()),
        "fire" => int(ammo["fire"], 0, Shop.ammo_max())
      },
      "kills" => int(raw["kills"], 0, 1_000_000_000),
      "deaths" => int(raw["deaths"], 0, 1_000_000_000)
    }
  end

  def decode(_other), do: new()

  @doc """
  Spielstand auf ein frisch erzeugtes Spielerschiff anwenden: Klasse, Upgrades, Gold, Bank, Munition
  und Statistik; Werte (HP, Radius) werden daraus neu berechnet, das Schiff startet mit vollem Rumpf.
  """
  @spec apply(map(), map()) :: map()
  def apply(ship, profile) do
    p = decode(profile)

    base = %{
      ship
      | class: Map.fetch!(@classes, p["class"]),
        upgrades: Map.new(@slots, fn {key, slot} -> {slot, p["upgrades"][key]} end),
        gold: p["gold"],
        bank: p["bank"],
        ammo: %{chain: p["ammo"]["chain"], fire: p["ammo"]["fire"]},
        kills: p["kills"],
        deaths: p["deaths"]
    }

    stats = Ships.stats(base)
    %{base | max_hp: stats.max_hp, hp: stats.max_hp * 1.0, radius: stats.radius}
  end

  defp int(v, lo, hi) when is_integer(v), do: v |> max(lo) |> min(hi)
  defp int(v, lo, hi) when is_float(v), do: v |> round() |> int(lo, hi)
  defp int(_v, lo, _hi), do: lo
end
