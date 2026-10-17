defmodule Osp.State do
  @moduledoc """
  Reiner Zustand einer Welt (ohne Prozesse): Schiffe, Kugeln, Beute, Wind, Zufall.
  `Osp.World` ist nur die Hülle (Takt, Verbindungen, Versand); alles Spielerische steht hier und in
  `Osp.Combat`, `Osp.Sailing`, `Osp.Spawn`, `Osp.Wander` – dadurch ohne Prozess testbar.

  Schiffe haben `kind`: `:player`, `:merchant` (Händler: langsam, schwer bewaffnet, wehrt sich
  gegen Angreifer, flieht erst bei schwerem Schaden, trägt viel Gold) oder
  `:hunter` (Piratenjäger: greift Spieler an). NPCs verschwinden beim Untergang und lassen ihr
  Kopfgeld (`bounty`) als Beute fallen; `Osp.Director` hält die Welt um Spieler herum bevölkert.
  """

  alias Osp.{
    Combat,
    Conquest,
    Director,
    Fort,
    Hunter,
    Nations,
    Ports,
    Quests,
    Reputation,
    Sailing,
    Ships,
    Shop,
    Spawn,
    Terrain,
    Wander
  }

  @step_ms 25
  @aoi 45.0
  @wind_every_ms 30_000
  @grace_ms 10_000
  @merchant_hp 14
  @hunter_hp 10
  @merchant_speed 0.6
  @hunter_speed 0.9
  @hunter_aggro 28.0
  # Händler kämpfen nur gegen den, der sie angreift, solange er nah ist und der Rumpf hält
  @merchant_fight_range 14.0
  @merchant_flee_hp 0.4
  @max_name 20

  defstruct seed: 0,
            time: 0,
            acc: 0,
            ships: %{},
            targets: %{},
            balls: [],
            loot: [],
            director?: false,
            dir_at: 0,
            wind: 0,
            wind_at: @wind_every_ms,
            rng: nil,
            forts: %{},
            # Eroberte Häfen: Besitzer (Hafen-ID => Nation) und Zeitpunkt (Wanduhr ms) der Eroberung;
            # `wall_ms` setzt die Hülle (`Osp.World`) je Takt
            owners: %{},
            captured_at: %{},
            assaults: %{},
            rev_at: 0,
            wall_ms: 0,
            next_id: 1

  @type t :: %__MODULE__{}

  def aoi, do: @aoi

  @doc "Nation eines Hafens im Spielzustand: der Besitzer nach einer Eroberung, sonst die Ausgangsnation."
  @spec port_nation(t(), map()) :: atom()
  def port_nation(state, port), do: Nations.of_port(state.seed, port, state.owners)

  @doc """
  Öffentliche Kennung eines Schiffs für alle Nachrichten an Clients. Spieler-IDs sind geheime Tokens
  (sie öffnen das gespeicherte Profil) und dürfen andere nie erreichen; daher ein Hash. NPCs behalten
  ihre ID (`"npc-…"`; Spieler-Tokens mit diesem Präfix werden am Socket abgelehnt).
  """
  def public_id(nil), do: nil
  def public_id("npc-" <> _ = id), do: id
  def public_id("fort:" <> _ = id), do: id
  def public_id(id), do: "p" <> Integer.to_string(:erlang.phash2({:osp, id}, 4_294_967_296))
  def idle, do: %{up?: false, left?: false, right?: false}

  @doc """
  Neue Welt mit `merchants` festen NPC-Händlern. `director?: true` lässt `Osp.Director` laufend
  Händler, Jäger und Banden um die Spieler herum auftauchen und weit entfernte verschwinden.
  """
  @spec new(integer(), non_neg_integer(), keyword()) :: t()
  def new(seed, merchants \\ 0, opts \\ []) do
    rng = :rand.seed_s(:exsss, seed)
    {dir, rng} = :rand.uniform_s(6, rng)

    territory = Keyword.get(opts, :territory, %{})

    state = %__MODULE__{
      seed: seed,
      rng: rng,
      wind: dir - 1,
      director?: Keyword.get(opts, :director?, false),
      owners: Map.new(territory, fn {id, %{owner: owner}} -> {id, owner} end),
      captured_at: Map.new(territory, fn {id, %{since: since}} -> {id, since} end)
    }

    Enum.reduce(1..merchants//1, state, fn n, st ->
      {x, y, heading, rng} = pick_spawn(st)
      add_npc(%{st | rng: rng}, :merchant, "Händler #{n}", x, y, heading)
    end)
  end

  # --- Schiffe ----------------------------------------------------------------------

  def put_ship(state, id, ship), do: %{state | ships: Map.put(state.ships, id, ship)}
  def update_ship(state, id, fun), do: %{state | ships: Map.update!(state.ships, id, fun)}

  defp new_ship(id, name, kind, x, y, heading) do
    # Spieler: Klasse und Upgrades bestimmen die Werte; NPCs bekommen ein festes Aussehen
    {class, upgrades} =
      case kind do
        :player -> {Ships.fresh().class, Ships.fresh().upgrades}
        :merchant -> {:galeone, Ships.fresh().upgrades}
        :hunter -> {:brigg, Ships.fresh().upgrades}
      end

    base = %{class: class, upgrades: upgrades}
    stats = Ships.stats(base)

    hp =
      case kind do
        :merchant -> @merchant_hp
        :hunter -> @hunter_hp
        :player -> stats.max_hp
      end

    # Spieler: gelb/blau/rot/grün; Händler weiß, Jäger schwarz (sofort unterscheidbar)
    color =
      case kind do
        :merchant -> 5
        :hunter -> 4
        :player -> :erlang.phash2(id, 4)
      end

    %{
      id: id,
      name: name,
      kind: kind,
      nation: nil,
      terr: nil,
      rep: Reputation.start(nil),
      quests: [],
      hunting: nil,
      attacked_at: %{},
      class: class,
      upgrades: upgrades,
      color: color,
      gold: 0,
      bank: 0,
      bounty: 0,
      ammo: %{},
      ammo_sel: :ball,
      sail: :full,
      docked: nil,
      slow_until: 0,
      burn_until: 0,
      burn_next: 0,
      burn_by: nil,
      radius: stats.radius,
      x: x,
      y: y,
      heading: heading,
      speed: 0.0,
      input: idle(),
      gone_at: nil,
      hp: hp * 1.0,
      max_hp: hp,
      alive?: true,
      respawn_at: 0,
      invuln_until: 0,
      reload_l: 0,
      reload_r: 0,
      kills: 0,
      deaths: 0,
      damage: 0.0,
      last_hit_by: nil,
      flee: nil,
      run: nil,
      stuck: 0
    }
  end

  @doc """
  Spieler tritt bei oder verbindet sich neu (Schiff bleibt dann, wo es ist). Ein gespeicherter
  `profile` (`Osp.Profile`) stellt Klasse, Upgrades, Gold, Bank, Munition und Statistik eines neuen
  Schiffs wieder her.
  """
  @spec join(t(), term(), String.t(), map() | nil) :: t()
  def join(state, id, name, profile \\ nil) do
    name = unique_name(state, id, name)

    if Map.has_key?(state.ships, id) do
      update_ship(state, id, &%{&1 | name: name, gone_at: nil})
    else
      nation = profile_nation(profile)
      {x, y, heading, rng} = pick_spawn(state, nation, {0.0, 0.0})
      state = %{state | rng: rng}
      ship = %{new_ship(id, name, :player, x, y, heading) | invuln_until: state.time + 2_000}
      ship = if profile, do: Osp.Profile.apply(ship, profile), else: ship
      put_ship(state, id, ship)
    end
  end

  @doc "Anzahl Spielerschiffe (ohne NPCs)."
  def player_count(state), do: Enum.count(state.ships, fn {_, s} -> s.kind == :player end)

  # Gleiche Namen bekommen eine Zahl (\"Anna\", \"Anna 2\", ...), damit man sie unterscheiden kann
  defp unique_name(state, id, name) do
    taken = for {other, s} <- state.ships, other != id, s.kind == :player, do: s.name
    base = String.slice(name, 0, @max_name - 3)

    if name not in taken do
      name
    else
      Enum.find_value(2..99, fn n -> if "#{base} #{n}" not in taken, do: "#{base} #{n}" end) ||
        name
    end
  end

  @doc "Ruf des Schiffs bei einer Nation (0 ohne Eintrag)."
  def rep_of(ship, nation), do: Reputation.get(Map.get(ship, :rep, %{}), nation)

  @doc """
  Ruf eines Spielers bei `nation` um `delta` ändern (begrenzt). Gibt `{state, events}` zurück mit
  `{:rep, id, nation, angewandte_änderung, neuer_wert, x, y}`; ohne tatsächliche Änderung oder für
  Unbekannte keine Änderung und keine Ereignisse.
  """
  @spec add_rep(t(), term(), atom(), integer()) :: {t(), list()}
  def add_rep(state, id, nation, delta) do
    case state.ships[id] do
      nil ->
        {state, []}

      ship ->
        old = rep_of(ship, nation)
        rep = Reputation.add(ship.rep, nation, delta)
        new = Reputation.get(rep, nation)

        if new == old do
          {state, []}
        else
          {put_ship(state, id, %{ship | rep: rep}),
           [{:rep, id, nation, new - old, new, ship.x, ship.y}]}
        end
    end
  end

  def leave(state, id), do: %{state | ships: Map.delete(state.ships, id)}

  def set_input(state, id, keys) do
    case state.ships do
      %{^id => ship} ->
        keys = %{
          up?: keys[:up?] == true,
          left?: keys[:left?] == true,
          right?: keys[:right?] == true
        }

        put_ship(state, id, %{ship | input: keys})

      _ ->
        state
    end
  end

  @doc "Verbindung weg: Schiff bleibt noch kurz in der Welt, ohne Eingabe."
  def mark_gone(state, id) do
    case state.ships do
      %{^id => ship} -> put_ship(state, id, %{ship | input: idle(), gone_at: state.time})
      _ -> state
    end
  end

  defp profile_nation(%{} = profile) do
    case Nations.parse(profile["nation"]) do
      {:ok, nation} -> nation
      :error -> nil
    end
  end

  defp profile_nation(_other), do: nil

  @doc """
  Startpunkt für ein Schiff der Heimatnation `nation`: nahe dem Hafen dieser Nation, der `reference`
  am nächsten liegt (6–18 WE vom Ankerplatz, also außerhalb der Schutzzone). Ohne Nation oder ohne
  Hafen im Umkreis (`opts[:max_radius]`, Standard 1500 WE) gilt der bisherige Start nahe anderer
  Schiffe (`Osp.Spawn.pick/4`). `{x, y, heading, rng}`.
  """
  def spawn_for(state, nation, reference, rng, opts \\ []) do
    others = for {_, s} <- state.ships, s.alive?, do: {s.x, s.y}
    max_radius = Keyword.get(opts, :max_radius, 1500.0)

    with true <- nation != nil,
         %{} = port <-
           Nations.nearest_port_of(state.seed, nation, reference, max_radius, state.owners),
         {_, _, _, _} = spot <-
           Spawn.pick_around(state.seed, others, {port.x, port.y}, 6.0, 18.0, rng) do
      spot
    else
      _ -> Spawn.pick(state.seed, others, others, rng)
    end
  end

  # Startpunkt (Heimatgebiet, sonst nahe anderer Schiffe), aber möglichst weit weg von Piratenjägern
  # (sonst stirbt man direkt nach dem Auftauchen wieder); nach ein paar Versuchen gilt der letzte
  # Vorschlag.
  defp pick_spawn(state), do: pick_spawn(state, nil, {0.0, 0.0})
  defp pick_spawn(state, nation, reference), do: pick_spawn(state, nation, reference, 8)

  defp pick_spawn(state, nation, reference, tries) do
    hunters = for {_, s} <- state.ships, s.alive?, s.kind == :hunter, do: {s.x, s.y}
    {x, y, heading, rng} = spawn_for(state, nation, reference, state.rng)

    safe? =
      Enum.all?(hunters, fn {hx, hy} ->
        :math.sqrt((x - hx) * (x - hx) + (y - hy) * (y - hy)) > @hunter_aggro + 8
      end)

    if safe? or tries <= 1,
      do: {x, y, heading, rng},
      else: pick_spawn(%{state | rng: rng}, nation, reference, tries - 1)
  end

  @doc "NPC-Schiff (`:merchant` oder `:hunter`) in die Welt setzen; Kopfgeld wird gewürfelt."
  def add_npc(state, kind, name, x, y, heading, bonus \\ 0, nation \\ nil) do
    id = "npc-#{state.next_id}"
    {r, rng} = :rand.uniform_s(state.rng)

    {lo, hi} = if kind == :merchant, do: {50, 120}, else: {40, 100}
    bounty = lo + round(r * (hi - lo)) + bonus

    ship = %{
      new_ship(id, name, kind, x, y, heading)
      | bounty: bounty,
        nation: nation || Nations.at(state.seed, x, y, state.owners)
    }

    %{
      put_ship(%{state | rng: rng, next_id: state.next_id + 1}, id, ship)
      | targets: Map.put(state.targets, id, nil)
    }
  end

  @doc "NPC samt Steuerzustand entfernen (Untergang oder zu weit weg)."
  def remove_npc(state, id),
    do: %{state | ships: Map.delete(state.ships, id), targets: Map.delete(state.targets, id)}

  @doc "Neuer Startpunkt für ein wiederauftauchendes Schiff: `{state, x, y, heading}`."
  def respawn_point(state, id) do
    ship = state.ships[id]

    {x, y, heading, rng} =
      pick_spawn(state, ship && ship.nation, (ship && {ship.x, ship.y}) || {0.0, 0.0})

    {%{state | rng: rng}, x, y, heading}
  end

  # --- Eingaben für den Kampf (dünn, damit die Hülle nur State kennt) --------------------

  def fire(state, id, side), do: Combat.fire(state, id, side)

  # --- Hafen: Andocken, Shop, Munition ----------------------------------------------------

  @doc """
  Andocken: nur lebende Spieler, langsam (< 0,7 WE/s) und in Reichweite eines Hafens. Das Schiff
  bleibt dann stehen. `{state, :ok | {:error, grund}}`, Gründe `:no_port`, `:too_fast`, `:docked`.
  """
  def dock(state, id) do
    with %{alive?: true, kind: :player, docked: nil} = s <- state.ships[id],
         %{} = port <- Ports.dockable(state.seed, s.x, s.y) || {:error, :no_port},
         true <- s.speed < 0.7 or {:error, :too_fast} do
      dock = %{id: port.id, name: port.name, nation: port_nation(state, port)}
      ship = %{s | docked: dock, speed: 0.0, input: idle()}
      {put_ship(state, id, ship), :ok}
    else
      %{docked: %{}} -> {state, {:error, :docked}}
      {:error, _} = err -> {state, err}
      _ -> {state, {:error, :no_port}}
    end
  end

  def undock(state, id) do
    case state.ships[id] do
      %{docked: %{}} = s -> {put_ship(state, id, %{s | docked: nil}), :ok}
      _ -> {state, {:error, :not_docked}}
    end
  end

  @doc """
  Hafengeschäft im angedockten Zustand. `action`: `{:class, atom}`, `{:upgrade, slot}`,
  `{:ammo, kind}`, `:repair`, `{:deposit, n | :all}`, `{:withdraw, n | :all}`.
  `{state, {:ok, shop_view} | {:error, grund}}`.
  """
  def shop(state, id, action) do
    case state.ships[id] do
      %{docked: %{} = dock, alive?: true} = ship ->
        nation = Map.get(dock, :nation)
        hostile? = hostile_to?(ship, nation)

        if hostile?,
          do: {state, {:error, :hostile}},
          else: trade(state, id, ship, action)

      _ ->
        {state, {:error, :not_docked}}
    end
  end

  defp trade(state, id, ship, action) do
    result =
      case action do
        {:class, c} -> Shop.buy_class(ship, c)
        {:upgrade, slot} -> Shop.buy_upgrade(ship, slot)
        {:ammo, kind} -> Shop.buy_ammo(ship, kind)
        :repair -> Shop.repair(ship)
        {:deposit, n} -> Shop.deposit(ship, n)
        {:withdraw, n} -> Shop.withdraw(ship, n)
        _ -> {:error, :unknown}
      end

    case result do
      {:ok, ship} ->
        state = put_ship(state, id, ship)
        {state, {:ok, view_for(state, state.ships[id])}}

      {:error, reason} ->
        {state, {:error, reason}}
    end
  end

  # Hafen-Ansicht des angedockten Spielers: bei Gesucht die Sperr-Ansicht, sonst die normale, jeweils
  # mit den Quests (Angebote des Hafens, aktive, bei Gesucht die Wiedergutmachungsangebote)
  defp view_for(state, %{docked: %{name: port} = dock} = ship) do
    nation = Map.get(dock, :nation)

    base =
      if hostile_to?(ship, nation),
        do: Shop.hostile_view(ship, port, nation),
        else: Shop.view(ship, port, nation)

    Map.put(base, :quests, quests_view(state, ship, hostile_to?(ship, nation)))
  end

  defp quests_view(state, %{docked: %{id: port_id}} = ship, wanted?) do
    case Ports.by_id(state.seed, port_id) do
      nil ->
        %{offers: [], atone: [], active: Enum.map(ship.quests, &quest_view/1)}

      port ->
        window = Quests.window(state.time)

        %{
          offers:
            for(o <- Quests.offers(state.seed, port, window, state.owners), do: offer_view(o)),
          atone:
            if(wanted?,
              do:
                for(
                  o <- Quests.atonement_offers(state.seed, port, window, state.owners),
                  do: offer_view(o)
                ),
              else: []
            ),
          active: Enum.map(ship.quests, &quest_view/1)
        }
    end
  end

  defp offer_view(o) do
    %{
      id: o.id,
      k: Atom.to_string(o.kind),
      n: Atom.to_string(o.nation),
      to: o.to_name,
      dist: o.dist,
      tn: o.target_nation && Atom.to_string(o.target_nation),
      need: o.need,
      gold: o.gold,
      rep: o.rep,
      at: o.atone?
    }
  end

  # --- Quests: annehmen, abgeben, aufgeben ------------------------------------------------------

  @doc """
  Quest aus dem Angebot `offer_id` des angedockten Hafens annehmen. `{state, {:ok, hafen_ansicht}}`
  oder `{state, {:error, grund}}` mit `:not_docked`, `:unknown_offer`, `:not_wanted` (Wiedergutmachung
  ohne Gesucht-Status), `:duplicate`, `:full`. Bei Fehlern ändert sich nichts.
  """
  def accept_quest(state, id, offer_id) do
    with %{kind: :player, alive?: true, docked: %{id: port_id} = dock} = ship <- state.ships[id],
         %{} = port <- Ports.by_id(state.seed, port_id),
         wanted? = hostile_to?(ship, Map.get(dock, :nation)),
         window = Quests.window(state.time),
         {:ok, offer} <- find_offer(state, port, window, offer_id, wanted?),
         :ok <- check_accept(ship, offer, wanted?) do
      ship = %{ship | quests: ship.quests ++ [Quests.to_quest(offer)]}
      state = put_ship(state, id, ship)
      {state, {:ok, view_for(state, ship)}}
    else
      {:error, reason} -> {state, {:error, reason}}
      _ -> {state, {:error, :not_docked}}
    end
  end

  # Angebot suchen; ein Wiedergutmachungsangebot ohne Gesucht-Status meldet :not_wanted statt :unknown_offer
  defp find_offer(state, port, window, offer_id, wanted?) do
    %{seed: seed, owners: owners} = state

    case Quests.find_offer(seed, port, window, offer_id, wanted?, owners) do
      {:ok, offer} ->
        {:ok, offer}

      :error ->
        case Quests.find_offer(seed, port, window, offer_id, true, owners) do
          {:ok, _} -> {:error, :not_wanted}
          :error -> {:error, :unknown_offer}
        end
    end
  end

  defp check_accept(ship, offer, _wanted?) do
    cond do
      Enum.any?(ship.quests, &(&1.id == offer.id)) -> {:error, :duplicate}
      length(ship.quests) >= Quests.max_active() -> {:error, :full}
      true -> :ok
    end
  end

  @doc """
  Alle am angedockten Hafen erfüllten Quests abgeben: Gold, Ruf (bei der Nation des Auftraggebers),
  Quest entfernt. `{state, {:ok, ansicht, ereignisse}}` oder `{state, {:error, :not_docked | :nothing}}`.
  """
  def turn_in(state, id) do
    case state.ships[id] do
      %{kind: :player, alive?: true, docked: %{id: port_id}} = ship ->
        {done, rest} = Enum.split_with(ship.quests, &Quests.complete?(&1, port_id))

        if done == [] do
          {state, {:error, :nothing}}
        else
          gold = done |> Enum.map(& &1.gold) |> Enum.sum()
          state = put_ship(state, id, %{ship | gold: ship.gold + gold, quests: rest})

          {state, events} =
            Enum.reduce(done, {state, []}, fn q, {st, ev} ->
              {st, rep_ev} = add_rep(st, id, q.nation, q.rep)
              done_ev = {:quest_done, id, q.gold, q.rep, q.nation, ship.x, ship.y}
              {st, ev ++ [done_ev] ++ rep_ev}
            end)

          {state, {:ok, view_for(state, state.ships[id]), events}}
        end

      _ ->
        {state, {:error, :not_docked}}
    end
  end

  @doc "Quest aufgeben (überall, ohne Belohnung)."
  def abandon_quest(state, id, quest_id) do
    case state.ships[id] do
      %{quests: quests} = ship ->
        if Enum.any?(quests, &(&1.id == quest_id)) do
          {put_ship(state, id, %{ship | quests: Enum.reject(quests, &(&1.id == quest_id))}), :ok}
        else
          {state, {:error, :unknown}}
        end

      _ ->
        {state, {:error, :unknown}}
    end
  end

  @doc """
  Ein Spieler hat ein Schiff versenkt: Jagdquests mit passender Zielnation zählen den Abschuss (auch
  bei Notwehr; nur Jäger mit Nation, nur durch lebende Spieler).
  """
  def quest_kill(state, killer_id, %{kind: :hunter, nation: nation}) when nation != nil do
    case killer_id && state.ships[killer_id] do
      %{kind: :player, alive?: true, quests: [_ | _] = quests} = killer ->
        put_ship(state, killer_id, %{killer | quests: Enum.map(quests, &Quests.kill(&1, nation))})

      _ ->
        state
    end
  end

  def quest_kill(state, _killer_id, _victim), do: state

  @doc "Ein Spieler ist gestorben: seine Lieferquests scheitern (die Ware ist weg), Jagdquests bleiben."
  def fail_deliveries(state, id) do
    case state.ships[id] do
      %{quests: [_ | _] = quests} = ship ->
        {lost, kept} = Enum.split_with(quests, &(&1.kind == :delivery))
        events = for _ <- lost, do: {:quest_lost, id, :death, ship.x, ship.y}
        {put_ship(state, id, %{ship | quests: kept}), events}

      _ ->
        {state, []}
    end
  end

  # Ist dieser Spieler bei dieser Nation Gesucht? (nur Spieler; NPCs nie)
  defp hostile_to?(%{kind: :player} = ship, nation) when nation != nil,
    do: Reputation.standing(rep_of(ship, nation)) == :wanted

  defp hostile_to?(_ship, _nation), do: false

  @doc """
  Schützt die Schutzzone eines Hafens dieses Schiff an `(x, y)`? Ja, wenn ein Hafen in Reichweite
  liegt, dessen Nation das Schiff nicht als Gesuchten führt. Ohne Schiff (z. B. Fort-Kugel) nie.
  """
  @spec safe_at?(t(), number(), number(), map() | nil) :: boolean()
  def safe_at?(_state, _x, _y, nil), do: false

  def safe_at?(state, x, y, ship) do
    state.seed
    |> Ports.near(x, y, Ports.safe_radius())
    |> Enum.any?(fn port ->
      not (hostile_to?(ship, port_nation(state, port)) or
             (Map.has_key?(state.assaults, port.id) and Conquest.attacker?(state, ship, port)))
    end)
  end

  @doc "Wie `safe_at?/4` an der Position des Schiffs selbst."
  @spec safe_for?(t(), map() | nil) :: boolean()
  def safe_for?(_state, nil), do: false
  def safe_for?(state, ship), do: safe_at?(state, ship.x, ship.y, ship)

  @doc "Aktuelle Hafen-Ansicht des Spielers oder `nil`."
  def shop_view(state, id) do
    case state.ships[id] do
      %{docked: %{}} = ship -> view_for(state, ship)
      _ -> nil
    end
  end

  @doc "Munitionsart wählen (`:ball`, `:chain`, `:fire`)."
  def select_ammo(state, id, kind) when kind in [:ball, :chain, :fire] do
    case state.ships[id] do
      nil -> state
      ship -> put_ship(state, id, %{ship | ammo_sel: kind})
    end
  end

  def select_ammo(state, _id, _kind), do: state

  @doc "Segelstufe wählen: `:reefed` (gerafft), `:full` (voll), `:studding` (Beisegel)."
  def set_sail(state, id, mode) when mode in [:reefed, :full, :studding] do
    case state.ships[id] do
      %{alive?: true, kind: :player} = ship -> put_ship(state, id, %{ship | sail: mode})
      _ -> state
    end
  end

  def set_sail(state, _id, _mode), do: state

  # --- Zeitschritt --------------------------------------------------------------------

  @doc "Spielzeit um `dt_ms` voranbringen (in Schritten à #{@step_ms} ms). `{state, events}`."
  @spec tick(t(), non_neg_integer()) :: {t(), list()}
  def tick(state, dt_ms) do
    total = state.acc + dt_ms
    steps = div(total, @step_ms)
    state = %{state | acc: rem(total, @step_ms)}

    Enum.reduce(1..steps//1, {state, []}, fn _, {s, ev} ->
      {s, more} = step(s, @step_ms)
      {s, ev ++ more}
    end)
  end

  defp step(state, ms) do
    state = %{state | time: state.time + ms}
    state = turn_wind(state)
    state = update_territory(state)
    state = decay_reputation(state)
    {state, quest_events} = update_quests(state)
    {state, npc_events} = think_npcs(state)
    state = Director.step(state)
    solid? = fn x, y -> Terrain.land?(state.seed, x, y) end
    wind = Sailing.wind_angle(state.wind)

    ships =
      Map.new(state.ships, fn {id, s} ->
        if s.alive? and s.docked == nil do
          moved = Sailing.step(s, s.input, ms / 1000, wind, solid?, speed_opts(s, state.time))
          {id, Map.merge(s, Map.take(moved, [:x, :y, :heading, :speed]))}
        else
          {id, s}
        end
      end)

    {state, events} = Combat.step(%{state | ships: ships}, ms)
    {state, fort_events} = Fort.step(state)
    {state, conquest_events} = Conquest.step(state, ms)
    {state, revert_events} = Conquest.revert_step(state)

    {expire(state),
     npc_events ++ events ++ fort_events ++ conquest_events ++ revert_events ++ quest_events}
  end

  # Tempo- und Wendigkeitsfaktoren: Spieler aus Klasse/Upgrades, NPCs aus ihrer Art; Kettenkugel bremst
  defp speed_opts(ship, t) do
    {cap, turn} =
      case ship.kind do
        :merchant -> {@merchant_speed, 1.0}
        :hunter -> {@hunter_speed, 1.0}
        :player -> player_factors(ship)
      end

    slow = if ship.slow_until > t, do: 0.5, else: 1.0
    [cap_mult: cap * slow, turn_mult: turn]
  end

  # Klasse und Upgrades mal Segelstufe (gerafft / voll / Beisegel)
  defp player_factors(ship) do
    stats = Ships.stats(ship)
    sail = Ships.sail(ship.sail)
    {stats.speed_mult * sail.speed, stats.turn_mult * sail.turn}
  end

  # Gebietsnation unter jedem lebenden Spieler: nur alle 500 ms (die Suche nach dem nächsten Hafen
  # ist deutlich teurer als ein Zeitschritt)
  defp update_territory(%{time: t} = state) when rem(t, 500) != 0, do: state

  defp update_territory(state) do
    ships =
      Map.new(state.ships, fn
        {id, %{kind: :player, alive?: true} = s} ->
          {id, %{s | terr: Nations.at(state.seed, s.x, s.y, state.owners)}}

        other ->
          other
      end)

    %{state | ships: ships}
  end

  # Quests lebender Spieler: alle 500 ms 500 ms Zeit abziehen (Abgelaufene entfernen, melden) und
  # Zielhafen-Name und groben Hinweis neu bestimmen
  defp update_quests(%{time: t} = state) when rem(t, 500) != 0, do: {state, []}

  defp update_quests(state) do
    Enum.reduce(state.ships, {state, []}, fn
      {id, %{kind: :player, alive?: true, quests: [_ | _] = quests} = s}, {st, ev} ->
        {kept, expired} = Quests.tick(quests, 500)
        kept = Enum.map(kept, &quest_info(st, &1, {s.x, s.y}))
        lost = for _ <- expired, do: {:quest_lost, id, :expired, s.x, s.y}
        {put_ship(st, id, %{s | quests: kept}), ev ++ lost}

      _other, acc ->
        acc
    end)
  end

  # Anzeigedaten einer Quest (nicht im Profil): Name des Zielhafens und gerundeter Hinweis
  defp quest_info(%{seed: seed, owners: owners}, quest, pos) do
    to_name =
      case quest.to && Ports.by_id(seed, quest.to) do
        %{name: name} -> name
        _ -> nil
      end

    hint =
      case Quests.hint(seed, quest, pos, owners) do
        nil -> nil
        point -> Quests.round_hint(point)
      end

    quest |> Map.put(:to_name, to_name) |> Map.put(:hint, hint)
  end

  # Ruf nähert sich alle 10 Minuten Spielzeit um 1 der 0 (für lebende Spieler)
  @rep_decay_ms 600_000
  defp decay_reputation(%{time: t} = state) when rem(t, @rep_decay_ms) != 0, do: state

  defp decay_reputation(state) do
    ships =
      Map.new(state.ships, fn
        {id, %{kind: :player, alive?: true} = s} -> {id, %{s | rep: Reputation.decay(s.rep)}}
        other -> other
      end)

    %{state | ships: ships}
  end

  defp turn_wind(%{time: t, wind_at: at} = state) when t >= at,
    do: %{state | wind: Integer.mod(state.wind - 1, 6), wind_at: at + @wind_every_ms}

  defp turn_wind(state), do: state

  # NPCs denken alle 200 ms; Jäger feuern dabei auch (Ereignisse gehen mit zurück)
  defp think_npcs(%{time: t} = state) when rem(t, 200) != 0, do: {state, []}

  defp think_npcs(state) do
    solid? = fn x, y -> Terrain.land?(state.seed, x, y) end

    Enum.reduce(Map.keys(state.targets), {state, []}, fn id, {acc, ev} ->
      case acc.ships[id] do
        %{alive?: true, kind: :hunter} = ship ->
          ship = unstick(ship, solid?)

          # Jäger greifen nur Spieler an, die bei ihrer Nation mindestens Misstrauisch sind
          hostile? = fn p -> Reputation.hunts?(rep_of(p, ship.nation)) end

          case nearest_player(acc, ship, @hunter_aggro, hostile?) do
            nil ->
              {keys, [], target, rng} =
                Hunter.think(ship, nil, acc.targets[id], solid?, acc.rng, nil)

              acc = %{
                acc
                | ships: Map.put(acc.ships, id, %{ship | input: keys, run: nil, hunting: nil}),
                  targets: Map.put(acc.targets, id, target),
                  rng: rng
              }

              {acc, ev}

            enemy ->
              fight(acc, ev, id, ship, enemy, solid?)
          end

        %{alive?: true, kind: :merchant} = ship ->
          think_merchant(acc, ev, id, unstick(ship, solid?), solid?)

        _ ->
          {acc, ev}
      end
    end)
  end

  # Hängt ein NPC (an einer Küste, in einer Bucht) länger als ~0,8 s fast ohne Fahrt fest, richtet er
  # sich zur freiesten Richtung aus, statt dieselbe Kurve immer wieder in die Küste zu fahren.
  defp unstick(ship, solid?) do
    if ship.speed < 0.15 do
      if ship.stuck >= 3,
        do: %{ship | stuck: 0, heading: Wander.free_heading(ship, solid?)},
        else: %{ship | stuck: ship.stuck + 1}
    else
      %{ship | stuck: 0}
    end
  end

  # Händler: friedlich, bis jemand sie trifft. Dann stellen sie den Angreifer querab und feuern
  # (wie ein Jäger, nur mit mehr Kanonen); bei schwerem Schaden oder wenn der Angreifer weit weg ist,
  # drehen sie ab und fliehen.
  defp think_merchant(acc, ev, id, ship, solid?) do
    attacker =
      with %{from: from, until: until} <- ship.flee,
           true <- until > acc.time,
           %{alive?: true} = a <- acc.ships[from] do
        a
      else
        _ -> nil
      end

    close? =
      attacker != nil and
        :math.sqrt(:math.pow(attacker.x - ship.x, 2) + :math.pow(attacker.y - ship.y, 2)) <=
          @merchant_fight_range

    if close? and ship.hp / ship.max_hp > @merchant_flee_hp do
      fight(acc, ev, id, ship, attacker, solid?)
    else
      flee = attacker && {attacker.x, attacker.y}
      {keys, target, rng} = Wander.think(ship, acc.targets[id], solid?, acc.rng, flee)

      {%{
         acc
         | ships: Map.put(acc.ships, id, %{ship | input: keys, run: nil}),
           targets: Map.put(acc.targets, id, target),
           rng: rng
       }, ev}
    end
  end

  # Kampf eines NPCs gegen `enemy`: Angriffslauf (`Osp.Hunter.attack/4`), danach feuern
  defp fight(acc, ev, id, ship, enemy, solid?) do
    {keys, fires, run} = Hunter.attack(ship, enemy, solid?, acc.time)

    # Jäger merken, auf wen sie gerade Jagd machen (Notwehr-Regel beim Ruf); Händler nie
    hunting = if ship.kind == :hunter, do: {enemy.id, acc.time}, else: nil

    acc = %{
      acc
      | ships: Map.put(acc.ships, id, %{ship | input: keys, run: run, hunting: hunting})
    }

    Enum.reduce(fires, {acc, ev}, fn side, {a, e} ->
      {a, more} = Combat.fire(a, id, side)
      {a, e ++ more}
    end)
  end

  # Nächster lebender Spieler im Umkreis `radius` (nicht in der Schonzeit), den `wanted?` zulässt
  defp nearest_player(state, ship, radius, wanted?) do
    state.ships
    |> Map.values()
    |> Enum.filter(
      &(&1.kind == :player and &1.alive? and &1.invuln_until <= state.time and wanted?.(&1))
    )
    |> Enum.map(&{:math.sqrt(:math.pow(&1.x - ship.x, 2) + :math.pow(&1.y - ship.y, 2)), &1})
    |> Enum.filter(fn {d, _} -> d <= radius end)
    |> Enum.min_by(fn {d, _} -> d end, fn -> nil end)
    |> case do
      {_, p} -> p
      nil -> nil
    end
  end

  # Getrennte Spieler nach der Schonfrist entfernen
  defp expire(state) do
    gone =
      for {id, %{gone_at: at}} <- state.ships, at != nil, state.time - at >= @grace_ms, do: id

    Enum.reduce(gone, state, &leave(&2, &1))
  end

  # --- Schnappschuss -------------------------------------------------------------------

  @doc """
  Die Teile eines Schnappschusses, die für alle Spieler gleich sind, **einmal je Takt** berechnet:
  jedes Schiff, jede Kugel, jeder Münzhaufen und jedes Ereignis mit Position und fertigem Eintrag.
  Das spart bei vielen Spielern auf engem Raum den Löwenanteil der Rechenzeit
  (statt n² Eintragsbauten nur n); `snapshot_for/3` filtert danach nur noch nach Entfernung.
  """
  @spec snapshot_context(t(), list()) :: map()
  def snapshot_context(state, events) do
    t = state.time

    %{
      time: t,
      w: r3(Sailing.wind_angle(state.wind)),
      wi: max(state.wind_at - t, 0),
      ships: for({_, s} <- state.ships, do: {s.x, s.y, ship_entry(s, t)}),
      players: players_list(state),
      balls: for(b <- state.balls, do: {b.x, b.y, [b.id, r2(b.x), r2(b.y), r2(b.vx), r2(b.vy)]}),
      loot: for(p <- state.loot, do: {p.x, p.y, [p.id, r2(p.x), r2(p.y), p.gold]}),
      events: for(e <- events, entry = event_entry(e), do: entry)
    }
  end

  @doc """
  Sicht für einen Spieler: Schiffe, Kugeln, Beute, Häfen und Ereignisse im Umkreis (`aoi/0`) plus
  eigener Status. `ctx_or_events` ist der gemeinsame Kontext (`snapshot_context/2`) oder – bequem
  für Tests – direkt die Ereignisliste. `nil`, wenn es das Schiff nicht gibt.
  """
  @spec snapshot_for(t(), term(), map() | list()) :: map() | nil
  def snapshot_for(state, id, events) when is_list(events),
    do: snapshot_for(state, id, snapshot_context(state, events))

  def snapshot_for(state, id, ctx) do
    case state.ships[id] do
      nil ->
        nil

      me ->
        aoi2 = @aoi * @aoi
        near? = fn x, y -> (x - me.x) * (x - me.x) + (y - me.y) * (y - me.y) <= aoi2 end
        t = ctx.time

        %{
          t: "snap",
          time: t,
          w: ctx.w,
          wi: ctx.wi,
          you: public_id(id),
          ships: for({x, y, e} <- ctx.ships, near?.(x, y), do: e),
          balls: for({x, y, e} <- ctx.balls, near?.(x, y), do: e),
          ports:
            for p <- Ports.near(state.seed, me.x, me.y, @aoi) do
              [p.id, p.x, p.y, p.name, p.land, Atom.to_string(port_nation(state, p))]
            end,
          loot: for({x, y, e} <- ctx.loot, near?.(x, y), do: e),
          me: %{
            g: me.gold,
            b: me.bank,
            am: %{c: Map.get(me.ammo, :chain, 0), f: Map.get(me.ammo, :fire, 0)},
            as: Atom.to_string(me.ammo_sel),
            sa: Atom.to_string(me.sail),
            tn: nation_string(me.terr),
            rp: for(n <- Nations.all(), do: Reputation.get(me.rep, n)),
            q: Enum.map(me.quests, &quest_view/1),
            dk: me.docked && me.docked.name,
            np:
              case Ports.dockable(state.seed, me.x, me.y) do
                nil -> nil
                port -> port.name
              end,
            rl: me.reload_l,
            rr: me.reload_r,
            k: me.kills,
            d: me.deaths,
            rs: if(me.alive?, do: 0, else: max(me.respawn_at - t, 0))
          },
          ev: for({x, y, e} <- ctx.events, near?.(x, y), do: e)
        }
        |> put_players(ctx)
    end
  end

  # Alle Spieler der Welt (für Rangliste und Richtungsanzeige), nur alle 0,5 s im Schnappschuss:
  # [Kennung, Name, Farbe, x, y, Abschüsse, Gold (getragen + Bank)]
  defp players_list(state) do
    for {_, s} <- state.ships, s.kind == :player, s.alive? do
      [public_id(s.id), s.name, s.color, r1(s.x), r1(s.y), s.kills, s.gold + s.bank]
    end
  end

  defp put_players(snap, %{time: t, players: players}) when rem(t, 500) == 0,
    do: Map.put(snap, :pl, players)

  defp put_players(snap, _ctx), do: snap

  defp ship_entry(s, t) do
    %{
      i: public_id(s.id),
      n: s.name,
      c: s.color,
      x: r2(s.x),
      y: r2(s.y),
      h: r2(s.heading),
      v: r2(s.speed),
      hp: r1(max(s.hp, 0.0)),
      mh: s.max_hp,
      a: s.alive?,
      iv: s.invuln_until > t,
      k: s.kills,
      kd: Atom.to_string(s.kind),
      cl: Atom.to_string(s.class),
      rd: s.radius,
      dk: s.docked != nil,
      bu: s.burn_until > t,
      sl: s.slow_until > t,
      sa: Atom.to_string(s.sail),
      na: nation_string(s.nation)
    }
  end

  # Eine aktive Quest für den Schnappschuss (grobe Richtung, keine exakten Koordinaten)
  defp quest_view(q) do
    {hx, hy} = Map.get(q, :hint) || {nil, nil}

    %{
      id: q.id,
      k: Atom.to_string(q.kind),
      n: Atom.to_string(q.nation),
      to: Map.get(q, :to_name),
      hx: hx,
      hy: hy,
      tn: q.target_nation && Atom.to_string(q.target_nation),
      need: q.need,
      have: q.have,
      gold: q.gold,
      rep: q.rep,
      at: q.atone?,
      left: ceil(q.left_ms / 1000)
    }
  end

  # Nation für Nachrichten: Name oder "" (keine)
  defp nation_string(nil), do: ""
  defp nation_string(nation), do: Atom.to_string(nation)

  # Ereignisse als kurze JSON-Arrays mit Position (für den Umkreis-Filter)
  defp event_entry({:fire, id, side, x, y}),
    do: {x, y, ["fire", public_id(id), to_string(side), r2(x), r2(y)]}

  defp event_entry({:loot, id, gold, x, y}),
    do: {x, y, ["loot", public_id(id), gold, r2(x), r2(y)]}

  defp event_entry({:respawn, id, x, y}), do: {x, y, ["respawn", public_id(id), r2(x), r2(y)]}
  defp event_entry({:splash, x, y}), do: {x, y, ["splash", r2(x), r2(y)]}

  defp event_entry({:hit, v, by, amount, x, y}),
    do: {x, y, ["hit", public_id(v), public_id(by), amount, r2(x), r2(y)]}

  defp event_entry({:quest_done, id, gold, rep, nation, x, y}),
    do: {x, y, ["quest_done", public_id(id), gold, rep, Atom.to_string(nation), r2(x), r2(y)]}

  defp event_entry({:quest_lost, id, reason, x, y}),
    do: {x, y, ["quest_lost", public_id(id), Atom.to_string(reason), r2(x), r2(y)]}

  defp event_entry({:fort_warn, port_id, player_id, x, y}),
    do: {x, y, ["fort_warn", port_id, public_id(player_id), r2(x), r2(y)]}

  defp event_entry({:rep, id, nation, delta, value, x, y}),
    do: {x, y, ["rep", public_id(id), Atom.to_string(nation), delta, value, r2(x), r2(y)]}

  defp event_entry({:rake, x, y}), do: {x, y, ["rake", r2(x), r2(y)]}

  defp event_entry({:kill, killer, v, x, y}),
    do: {x, y, ["kill", public_id(killer), public_id(v), r2(x), r2(y)]}

  defp event_entry(_other), do: nil

  # Runden ohne Float.round (deutlich schneller); Erlang-round rundet .5 von Null weg
  defp r1(x), do: round(x * 10.0) / 10
  defp r2(x), do: round(x * 100.0) / 100
  defp r3(x), do: round(x * 1000.0) / 1000
end
