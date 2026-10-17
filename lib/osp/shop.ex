defmodule Osp.Shop do
  @moduledoc """
  Hafen-Geschäfte (rein, auf einem Spielerschiff = Map): Schiff kaufen, Ausrüstung aufrüsten,
  Munition kaufen, reparieren, Bank. Jede Aktion gibt `{:ok, ship}` oder `{:error, grund}` zurück.

  Gründe: `:no_gold`, `:max_level`, `:same_class`, `:unknown`, `:full` (nichts zu reparieren bzw.
  Munitionslager voll), `:amount` (ungültiger Betrag), `:no_bank_gold`.
  """

  alias Osp.{Nations, Reputation, Ships}

  @ammo %{
    chain: %{
      label: "Kettenkugel",
      pack: 10,
      price: 40,
      what: "verlangsamt das Ziel 3 s (halber Schaden)"
    },
    fire: %{
      label: "Brandgeschoss",
      pack: 10,
      price: 60,
      what: "setzt das Ziel 3 s in Brand (1/s)"
    }
  }
  @ammo_max 40
  @repair_per_hp 4

  def ammo_kinds, do: @ammo
  def ammo_max, do: @ammo_max
  @doc "Gold je HP bei der Reparatur; Niederländer zahlen weniger (Nationsbonus), mindestens 1."
  def repair_price_per_hp(ship),
    do: max(round(@repair_per_hp * Osp.Nations.bonus(Map.get(ship, :nation)).repair), 1)

  # --- Schiffe --------------------------------------------------------------------

  @doc "Gold, das ein Schiffswechsel kostet (Neupreis abzüglich 50 % des Werts des alten Schiffs)."
  def class_cost(ship, class) do
    max(Ships.class(class).price - round(Ships.class(ship.class).price * Ships.tradein_rate()), 0)
  end

  def buy_class(ship, class) do
    cond do
      not Map.has_key?(Ships.classes(), class) ->
        {:error, :unknown}

      class == ship.class ->
        {:error, :same_class}

      class_cost(ship, class) > ship.gold ->
        {:error, :no_gold}

      true ->
        {:ok, ship |> pay(class_cost(ship, class)) |> Map.put(:class, class) |> restat(:full)}
    end
  end

  # --- Ausrüstung ----------------------------------------------------------------

  def buy_upgrade(ship, slot) do
    if slot in Ships.upgrade_slots() do
      level = ship.upgrades[slot]

      case Ships.next_price(slot, level) do
        nil ->
          {:error, :max_level}

        price when price > ship.gold ->
          {:error, :no_gold}

        price ->
          ship = %{ship | upgrades: Map.put(ship.upgrades, slot, level + 1)}
          {:ok, ship |> pay(price) |> restat(:keep)}
      end
    else
      {:error, :unknown}
    end
  end

  # --- Munition --------------------------------------------------------------------

  def buy_ammo(ship, kind) do
    case @ammo[kind] do
      nil ->
        {:error, :unknown}

      %{pack: pack, price: price} ->
        have = Map.get(ship.ammo, kind, 0)

        cond do
          have >= @ammo_max ->
            {:error, :full}

          price > ship.gold ->
            {:error, :no_gold}

          true ->
            {:ok,
             %{pay(ship, price) | ammo: Map.put(ship.ammo, kind, min(have + pack, @ammo_max))}}
        end
    end
  end

  # --- Reparatur ----------------------------------------------------------------------

  @doc "Repariert so viel, wie das Gold reicht (4 Gold je HP, siehe `repair_price_per_hp/1`)."
  def repair(ship) do
    missing = ship.max_hp * 1.0 - ship.hp

    cond do
      missing <= 0.0 ->
        {:error, :full}

      ship.gold < repair_price_per_hp(ship) ->
        {:error, :no_gold}

      true ->
        price = repair_price_per_hp(ship)
        hp = min(ceil(missing), div(ship.gold, price))
        {:ok, %{pay(ship, hp * price) | hp: min(ship.hp + hp, ship.max_hp * 1.0)}}
    end
  end

  def repair_cost(ship),
    do: ceil(max(ship.max_hp * 1.0 - ship.hp, 0.0)) * repair_price_per_hp(ship)

  # --- Bank --------------------------------------------------------------------------

  def deposit(ship, :all), do: deposit(ship, ship.gold)

  def deposit(ship, amount) when is_integer(amount) and amount > 0 do
    if amount <= ship.gold,
      do: {:ok, %{ship | gold: ship.gold - amount, bank: ship.bank + amount}},
      else: {:error, :no_gold}
  end

  def deposit(_ship, _), do: {:error, :amount}

  def withdraw(ship, :all), do: withdraw(ship, ship.bank)

  def withdraw(ship, amount) when is_integer(amount) and amount > 0 do
    if amount <= ship.bank,
      do: {:ok, %{ship | gold: ship.gold + amount, bank: ship.bank - amount}},
      else: {:error, :no_bank_gold}
  end

  def withdraw(_ship, _), do: {:error, :amount}

  # --- Anzeige -------------------------------------------------------------------------

  @doc """
  Sperr-Ansicht für einen Spieler, der bei der Nation des Hafens Gesucht ist: nichts wird verkauft,
  angeboten ist nur die Wiedergutmachung (`Osp.Reputation.atone_cost/0`, `atone_gain/0`).
  """
  def hostile_view(ship, port_name, nation) do
    %{
      t: "shop",
      open: true,
      hostile: true,
      port: port_name,
      nation: Atom.to_string(nation),
      rep: Reputation.get(ship.rep, nation),
      reps: reps(ship),
      atone: %{cost: Reputation.atone_cost(), gain: Reputation.atone_gain()},
      gold: ship.gold
    }
  end

  # Ruf bei allen Nationen in der Reihenfolge von `Osp.Nations.all/0`
  defp reps(ship), do: for(n <- Nations.all(), do: Reputation.get(ship.rep, n))

  @doc "Alles, was die Hafen-Oberfläche braucht (JSON-fähig); `nation` ist die des Hafens."
  def view(ship, port_name, nation \\ nil) do
    %{
      t: "shop",
      open: true,
      port: port_name,
      nation: if(nation, do: Atom.to_string(nation), else: ""),
      reps: reps(ship),
      gold: ship.gold,
      bank: ship.bank,
      class: Atom.to_string(ship.class),
      hp: Float.round(ship.hp * 1.0, 1),
      max_hp: ship.max_hp,
      classes:
        for id <- Ships.order() do
          c = Ships.class(id)

          %{
            id: Atom.to_string(id),
            name: c.name,
            hp: c.hp,
            cannons: c.cannons,
            speed: round(c.speed * 100),
            turn: round(c.turn * 100),
            blurb: c.blurb,
            cost: class_cost(ship, id),
            current: id == ship.class
          }
        end,
      upgrades:
        for {slot, u} <- Enum.sort(Ships.upgrades()) do
          level = ship.upgrades[slot]

          %{
            slot: Atom.to_string(slot),
            label: u.label,
            what: u.what,
            level: level,
            max: Ships.max_level(),
            price: Ships.next_price(slot, level),
            now: Enum.at(u.effect, level),
            next: Enum.at(u.effect, level + 1)
          }
        end,
      ammo:
        for {kind, a} <- Enum.sort(@ammo) do
          %{
            kind: Atom.to_string(kind),
            label: a.label,
            what: a.what,
            have: Map.get(ship.ammo, kind, 0),
            pack: a.pack,
            price: a.price,
            max: @ammo_max
          }
        end,
      repair: %{cost: repair_cost(ship), per_hp: repair_price_per_hp(ship)}
    }
  end

  # --- Hilfen ---------------------------------------------------------------------------

  defp pay(ship, price), do: %{ship | gold: ship.gold - price}

  # Werte neu aus Klasse/Upgrades; `:full` = frisches Schiff mit vollem Rumpf, `:keep` = HP bleiben,
  # zusätzliche Rumpfpunkte kommen dazu
  defp restat(ship, mode) do
    s = Ships.stats(ship)

    hp =
      case mode do
        :full -> s.max_hp * 1.0
        :keep -> min(ship.hp + (s.max_hp - ship.max_hp), s.max_hp * 1.0)
      end

    %{ship | max_hp: s.max_hp, hp: hp, radius: s.radius}
  end
end
