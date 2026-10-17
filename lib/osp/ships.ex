defmodule Osp.Ships do
  @moduledoc """
  Schiffsklassen und Upgrades (reine Daten und Rechnung, siehe docs/upgrades.md).

  Ein Spielerschiff hat `class` (Atom) und `upgrades` (`%{cannons: 0..3, hull: 0..3, sails: 0..3}`).
  `stats/1` rechnet daraus (und aus dem Bonus der Heimatnation `ship.nation`, siehe `Osp.Nations`)
  die Werte, mit denen Physik und Kampf arbeiten.
  """

  @order [:schaluppe, :klipper, :brigg, :fregatte, :galeone]

  # hp: Rumpfpunkte; cannons: Kugeln je Breitseite; speed/turn: Faktor auf Höchsttempo/Wendigkeit;
  # radius: Treffer-/Kollisionsradius in WE; price: Kaufpreis in Gold
  @classes %{
    schaluppe: %{
      name: "Schaluppe",
      hp: 12,
      cannons: 3,
      speed: 1.00,
      turn: 1.00,
      radius: 0.31,
      price: 0,
      blurb: "Klein und wendig. Dein Startschiff."
    },
    klipper: %{
      name: "Klipper",
      hp: 14,
      cannons: 3,
      speed: 1.15,
      turn: 1.10,
      radius: 0.34,
      price: 350,
      blurb: "Schnellster Segler, kaum Panzerung."
    },
    brigg: %{
      name: "Brigg",
      hp: 18,
      cannons: 4,
      speed: 0.95,
      turn: 0.95,
      radius: 0.37,
      price: 600,
      blurb: "Solider Allrounder mit vier Kanonen je Seite."
    },
    fregatte: %{
      name: "Fregatte",
      hp: 28,
      cannons: 5,
      speed: 0.85,
      turn: 0.80,
      radius: 0.45,
      price: 1_400,
      blurb: "Kampfschiff: viel Rumpf, fünf Kanonen, träge."
    },
    galeone: %{
      name: "Galeone",
      hp: 32,
      cannons: 6,
      speed: 0.75,
      turn: 0.70,
      radius: 0.52,
      price: 2_400,
      blurb: "Schwerer Gigant, sechs Kanonen, schwer zu wenden."
    }
  }

  # Stufen 0..3; `effect` je Stufe, `prices` für den Kauf von Stufe 1..3
  @upgrades %{
    cannons: %{
      label: "Kanonen",
      what: "Schaden je Kugel",
      effect: [1.0, 1.3, 1.6, 2.0],
      prices: [150, 350, 700]
    },
    hull: %{
      label: "Rumpf",
      what: "zusätzliche HP",
      effect: [0, 3, 6, 10],
      prices: [120, 300, 600]
    },
    sails: %{
      label: "Segel",
      what: "Tempo und Wendigkeit",
      effect: [1.0, 1.08, 1.16, 1.25],
      prices: [150, 350, 700]
    }
  }

  @tradein 0.5

  def order, do: @order
  def classes, do: @classes
  def class(id), do: Map.fetch!(@classes, id)
  def upgrades, do: @upgrades
  def tradein_rate, do: @tradein
  def upgrade_slots, do: Map.keys(@upgrades)

  @doc "Startwerte für ein neues Spielerschiff."
  def fresh, do: %{class: :schaluppe, upgrades: %{cannons: 0, hull: 0, sails: 0}}

  @doc "Werte eines Spielerschiffs aus Klasse und Upgrades."
  @spec stats(map()) :: map()
  def stats(%{class: class, upgrades: up} = ship) do
    c = class(class)
    bonus = Osp.Nations.bonus(Map.get(ship, :nation))

    %{
      max_hp: c.hp + Enum.at(@upgrades.hull.effect, up.hull) + bonus.hp,
      cannons: c.cannons,
      dmg_mult: Enum.at(@upgrades.cannons.effect, up.cannons) * bonus.dmg,
      speed_mult: c.speed * Enum.at(@upgrades.sails.effect, up.sails) * bonus.speed,
      turn_mult: c.turn * Enum.at(@upgrades.sails.effect, up.sails) * bonus.turn,
      radius: c.radius
    }
  end

  @doc "Preis für die nächste Stufe des Slots oder `nil` bei Höchststufe."
  def next_price(slot, level), do: Enum.at(Map.fetch!(@upgrades, slot).prices, level)

  def max_level, do: 3

  # Segelstufen (Taste S): Tempo- und Wendigkeitsfaktor je Stufe
  #   gerafft  – kleineres Segel: langsamer, dafür wendiger
  #   voll     – Normalzustand
  #   beisegel – Zusatzsegel: schneller, dafür träger beim Drehen
  @sails %{
    reefed: %{label: "Segel gerafft", speed: 0.65, turn: 1.4},
    full: %{label: "Volle Segel", speed: 1.0, turn: 1.0},
    studding: %{label: "Beisegel gesetzt", speed: 1.25, turn: 0.7}
  }

  def sails, do: @sails
  def sail(mode), do: Map.fetch!(@sails, mode)
end
