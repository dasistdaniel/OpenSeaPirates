defmodule Osp.Profile do
  @moduledoc """
  Dauerhafter Spielstand eines Spielers (rein): was beim Beitreten wiederhergestellt wird.

  Gespeichert werden Name, Gold (getragen), Bank, Schiffsklasse, Upgrades, Munition und Statistik –
  nicht Position, Kampfzustand oder angedockt. Das Format ist JSON-tauglich (Strings, Zahlen,
  Maps); `decode/1` prüft jeden Wert gegen feste Listen und Grenzen, damit eine kaputte oder
  manipulierte Datei nie das Spiel zum Absturz bringt (unbekannte Klasse → Startschiff usw.).
  """

  alias Osp.{Nations, Quests, Reputation, Ships, Shop}

  @version 4
  @max_gold 100_000_000
  @classes Map.new(Ships.order(), &{Atom.to_string(&1), &1})
  @slots %{"cannons" => :cannons, "hull" => :hull, "sails" => :sails}

  @doc "Stand eines frischen Spielers."
  def new do
    %{
      "v" => @version,
      "name" => "",
      "nation" => nil,
      "rep" => rep_strings(Reputation.start(nil)),
      "quests" => [],
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
      "nation" => ship |> Map.get(:nation) |> nation_string(),
      "rep" => ship |> Map.get(:rep, Reputation.start(nil)) |> rep_strings(),
      "quests" => ship |> Map.get(:quests, []) |> Enum.map(&Quests.to_json/1),
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
      "nation" => raw["nation"] |> Nations.parse() |> nation_from_parse(),
      "rep" => decode_rep(raw["rep"]),
      "quests" => decode_quests(raw["quests"]),
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
      | nation: nation_atom(p["nation"]),
        rep: rep_atoms(p["rep"], nation_atom(p["nation"])),
        quests: for(j <- p["quests"], {:ok, q} <- [Quests.from_json(j)], do: q),
        class: Map.fetch!(@classes, p["class"]),
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

  # Gespeicherte Quests: nur gültige (streng geprüft), keine doppelten IDs, höchstens zwei
  defp decode_quests(list) when is_list(list) do
    list
    |> Enum.flat_map(fn raw ->
      case Quests.from_json(raw) do
        {:ok, q} -> [Quests.to_json(q)]
        :error -> []
      end
    end)
    |> Enum.uniq_by(& &1["id"])
    |> Enum.take(Quests.max_active())
  end

  defp decode_quests(_other), do: []

  # Ruf als Map mit String-Schlüsseln (JSON); fehlt er im gespeicherten Stand ganz, bleibt `nil` und
  # `apply/2` setzt den Startruf der Heimatnation (altes Profil)
  defp decode_rep(%{} = raw) do
    Map.new(Nations.all(), fn n ->
      key = Atom.to_string(n)
      v = raw[key]
      {key, if(is_number(v), do: int(v, -100, 100), else: 0)}
    end)
  end

  defp decode_rep(_other), do: nil

  defp rep_strings(rep), do: Map.new(rep, fn {n, v} -> {Atom.to_string(n), v} end)

  defp rep_atoms(nil, home), do: Reputation.start(home)

  defp rep_atoms(%{} = rep, _home),
    do: Map.new(Nations.all(), fn n -> {n, Map.get(rep, Atom.to_string(n), 0)} end)

  defp nation_string(nil), do: nil
  defp nation_string(nation), do: Atom.to_string(nation)

  defp nation_from_parse({:ok, nation}), do: Atom.to_string(nation)
  defp nation_from_parse(:error), do: nil

  defp nation_atom(string) do
    case Nations.parse(string) do
      {:ok, nation} -> nation
      :error -> nil
    end
  end

  defp int(v, lo, hi) when is_integer(v), do: v |> max(lo) |> min(hi)
  defp int(v, lo, hi) when is_float(v), do: v |> round() |> int(lo, hi)
  defp int(_v, lo, _hi), do: lo
end
