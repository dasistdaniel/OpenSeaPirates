defmodule Osp.Nations do
  @moduledoc """
  Die fünf Nationen und ihre Gebiete (rein, aus dem Seed berechnet, nichts wird gespeichert).

  **Gebiete:** Die Welt ist in rechteckige Zellen von 150 × 150 WE geteilt; jede Zelle gehört per Hash
  einer Nation (`cell_nation/3`). Ein Hafen erbt die Nation der Zelle, in der er liegt (`of_port/2`).
  Die Nation eines **beliebigen Punkts** ist die des nächsten Hafens (`at/3`): so entstehen
  unregelmäßige Grenzen, und derselbe Mechanismus trägt später die Eroberung, bei der nur der
  Besitzer einzelner Häfen wechselt. Gibt es im Suchradius keinen Hafen, gilt die Zellnation.

  **Boni:** Jede Nation gibt dem Schiff ihrer Spieler einen kleinen Vorteil (`bonus/1`), den
  `Osp.Ships.stats/1` und `Osp.Shop` einrechnen. Siehe
  `docs/superpowers/specs/2026-10-17-nationen-ruf-quests-design.md`.
  """

  alias Osp.{Ports, Terrain}

  @order [:spain, :england, :france, :netherlands, :portugal]
  @cell 150.0
  @radii [30.0, 60.0, 120.0]

  @info %{
    spain: %{
      name: "Spanien",
      adjective: "spanische",
      color: "#e0a526",
      bonus_text: "Rumpf +2 HP"
    },
    england: %{
      name: "England",
      adjective: "englische",
      color: "#d94b4b",
      bonus_text: "Kanonenschaden +8 %"
    },
    france: %{
      name: "Frankreich",
      adjective: "französische",
      color: "#4f7fe0",
      bonus_text: "Wendigkeit +6 %"
    },
    netherlands: %{
      name: "Niederlande",
      adjective: "niederländische",
      color: "#ee8a2e",
      bonus_text: "Reparatur 25 % günstiger"
    },
    portugal: %{
      name: "Portugal",
      adjective: "portugiesische",
      color: "#3fae6a",
      bonus_text: "Tempo +5 %"
    }
  }

  @neutral %{hp: 0, dmg: 1.0, turn: 1.0, speed: 1.0, repair: 1.0}
  @bonuses %{
    spain: %{@neutral | hp: 2},
    england: %{@neutral | dmg: 1.08},
    france: %{@neutral | turn: 1.06},
    netherlands: %{@neutral | repair: 0.75},
    portugal: %{@neutral | speed: 1.05}
  }

  @doc "Alle Nationen in fester Reihenfolge."
  @spec all() :: [atom()]
  def all, do: @order

  @doc "Anzeigedaten einer Nation: Name, Adjektiv, Farbe, Bonustext."
  @spec info(atom()) :: map()
  def info(nation), do: Map.fetch!(@info, nation)

  @doc "Nation aus einem Netzwert (nur die festen Namen, nie ein neues Atom)."
  @spec parse(term()) :: {:ok, atom()} | :error
  def parse(value) when is_binary(value) do
    case Enum.find(@order, &(Atom.to_string(&1) == value)) do
      nil -> :error
      nation -> {:ok, nation}
    end
  end

  def parse(_other), do: :error

  @doc "Bonus einer Nation (`nil` ohne Nation: alles neutral)."
  @spec bonus(atom() | nil) :: map()
  def bonus(nation), do: Map.get(@bonuses, nation, @neutral)

  @doc "Ausgangsnation der 150-WE-Zelle um `(x, y)`."
  @spec cell_nation(integer(), number(), number()) :: atom()
  def cell_nation(seed, x, y) do
    idx = :erlang.phash2({:nation, seed, floor(x / @cell), floor(y / @cell)}, length(@order))
    Enum.at(@order, idx)
  end

  @doc "Nation eines Hafens (Zellnation seiner Position)."
  @spec of_port(integer(), map()) :: atom()
  def of_port(seed, %{x: x, y: y}), do: cell_nation(seed, x, y)

  @doc "Nation des Gebiets an `(x, y)`: die des nächsten Hafens, sonst die Zellnation."
  @spec at(integer(), number(), number()) :: atom()
  def at(seed, x, y) do
    near =
      Enum.find_value(@radii, fn r ->
        case Ports.near(seed, x, y, r) do
          [] -> nil
          ports -> Enum.min_by(ports, &dist(&1, x, y))
        end
      end)

    if near, do: of_port(seed, near), else: cell_nation(seed, x, y)
  end

  @doc """
  Nächster Hafen der Nation `nation` im Umkreis `max_radius` WE um `{x, y}` oder `nil`. Sucht Ringe
  von Chunks nach außen und bricht beim ersten Ring mit Treffer ab.
  """
  @spec nearest_port_of(integer(), atom(), {number(), number()}, number()) :: map() | nil
  def nearest_port_of(seed, nation, {x, y}, max_radius) do
    {cx0, cy0} = Terrain.chunk_of(x, y)
    max_ring = ceil(max_radius / Terrain.chunk_size()) + 1

    Enum.find_value(0..max_ring, fn ring ->
      hits =
        for cx <- (cx0 - ring)..(cx0 + ring),
            cy <- (cy0 - ring)..(cy0 + ring),
            max(abs(cx - cx0), abs(cy - cy0)) == ring,
            port = Ports.in_chunk(seed, cx, cy),
            port != nil,
            of_port(seed, port) == nation,
            d = dist(port, x, y),
            d <= max_radius,
            do: {d, port}

      if hits == [], do: nil, else: hits |> Enum.min_by(&elem(&1, 0)) |> elem(1)
    end)
  end

  defp dist(port, x, y), do: :math.sqrt(:math.pow(port.x - x, 2) + :math.pow(port.y - y, 2))
end
