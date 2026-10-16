defmodule Osp.State do
  @moduledoc """
  Reiner Zustand einer Welt (ohne Prozesse): Schiffe, Kugeln, Beute, Wind, Zufall.
  `Osp.World` ist nur die Hülle (Takt, Verbindungen, Versand); alles Spielerische steht hier und in
  `Osp.Combat`, `Osp.Sailing`, `Osp.Spawn`, `Osp.Wander` – dadurch ohne Prozess testbar.

  Schiffe haben `kind`: `:player`, `:merchant` (Händler: langsam, flieht, trägt viel Gold) oder
  `:hunter` (Piratenjäger: greift Spieler an). NPCs verschwinden beim Untergang und lassen ihr
  Kopfgeld (`bounty`) als Beute fallen; `Osp.Director` hält die Welt um Spieler herum bevölkert.
  """

  alias Osp.{Combat, Director, Hunter, Ports, Sailing, Ships, Shop, Spawn, Terrain, Wander}

  @step_ms 25
  @aoi 45.0
  @wind_every_ms 30_000
  @grace_ms 10_000
  @merchant_hp 6
  @hunter_hp 10
  @merchant_speed 0.6
  @hunter_speed 0.9
  @hunter_aggro 28.0

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
            next_id: 1

  @type t :: %__MODULE__{}

  def aoi, do: @aoi
  def idle, do: %{up?: false, left?: false, right?: false}

  @doc """
  Neue Welt mit `merchants` festen NPC-Händlern. `director?: true` lässt `Osp.Director` laufend
  Händler, Jäger und Banden um die Spieler herum auftauchen und weit entfernte verschwinden.
  """
  @spec new(integer(), non_neg_integer(), keyword()) :: t()
  def new(seed, merchants \\ 0, opts \\ []) do
    rng = :rand.seed_s(:exsss, seed)
    {dir, rng} = :rand.uniform_s(6, rng)

    state = %__MODULE__{
      seed: seed,
      rng: rng,
      wind: dir - 1,
      director?: Keyword.get(opts, :director?, false)
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
        :merchant -> {:klipper, Ships.fresh().upgrades}
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
      class: class,
      upgrades: upgrades,
      color: color,
      gold: 0,
      bank: 0,
      bounty: 0,
      ammo: %{},
      ammo_sel: :ball,
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
      flee: nil
    }
  end

  @doc """
  Spieler tritt bei oder verbindet sich neu (Schiff bleibt dann, wo es ist). Ein gespeicherter
  `profile` (`Osp.Profile`) stellt Klasse, Upgrades, Gold, Bank, Munition und Statistik eines neuen
  Schiffs wieder her.
  """
  @spec join(t(), term(), String.t(), map() | nil) :: t()
  def join(state, id, name, profile \\ nil) do
    if Map.has_key?(state.ships, id) do
      update_ship(state, id, &%{&1 | name: name, gone_at: nil})
    else
      {x, y, heading, rng} = pick_spawn(state)
      state = %{state | rng: rng}
      ship = %{new_ship(id, name, :player, x, y, heading) | invuln_until: state.time + 2_000}
      ship = if profile, do: Osp.Profile.apply(ship, profile), else: ship
      put_ship(state, id, ship)
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

  # Startpunkt nahe anderer Schiffe, aber möglichst weit weg von Piratenjägern (sonst stirbt man
  # direkt nach dem Auftauchen wieder); nach ein paar Versuchen gilt der letzte Vorschlag.
  defp pick_spawn(state), do: pick_spawn(state, 8)

  defp pick_spawn(state, tries) do
    others = for {_, s} <- state.ships, s.alive?, do: {s.x, s.y}
    hunters = for {_, s} <- state.ships, s.alive?, s.kind == :hunter, do: {s.x, s.y}
    {x, y, heading, rng} = Spawn.pick(state.seed, others, others, state.rng)

    safe? =
      Enum.all?(hunters, fn {hx, hy} ->
        :math.sqrt((x - hx) * (x - hx) + (y - hy) * (y - hy)) > @hunter_aggro + 8
      end)

    if safe? or tries <= 1,
      do: {x, y, heading, rng},
      else: pick_spawn(%{state | rng: rng}, tries - 1)
  end

  @doc "NPC-Schiff (`:merchant` oder `:hunter`) in die Welt setzen; Kopfgeld wird gewürfelt."
  def add_npc(state, kind, name, x, y, heading, bonus \\ 0) do
    id = "npc-#{state.next_id}"
    {r, rng} = :rand.uniform_s(state.rng)

    {lo, hi} = if kind == :merchant, do: {30, 80}, else: {40, 100}
    bounty = lo + round(r * (hi - lo)) + bonus

    ship = %{new_ship(id, name, kind, x, y, heading) | bounty: bounty}

    %{
      put_ship(%{state | rng: rng, next_id: state.next_id + 1}, id, ship)
      | targets: Map.put(state.targets, id, nil)
    }
  end

  @doc "NPC samt Steuerzustand entfernen (Untergang oder zu weit weg)."
  def remove_npc(state, id),
    do: %{state | ships: Map.delete(state.ships, id), targets: Map.delete(state.targets, id)}

  @doc "Neuer Startpunkt für ein wiederauftauchendes Schiff: `{state, x, y, heading}`."
  def respawn_point(state, _id) do
    {x, y, heading, rng} = pick_spawn(state)
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
      ship = %{s | docked: %{id: port.id, name: port.name}, speed: 0.0, input: idle()}
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
      %{docked: %{name: port}, alive?: true} = ship ->
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
          {:ok, ship} -> {put_ship(state, id, ship), {:ok, Shop.view(ship, port)}}
          {:error, reason} -> {state, {:error, reason}}
        end

      _ ->
        {state, {:error, :not_docked}}
    end
  end

  @doc "Aktuelle Hafen-Ansicht des Spielers oder `nil`."
  def shop_view(state, id) do
    case state.ships[id] do
      %{docked: %{name: port}} = ship -> Shop.view(ship, port)
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
    {expire(state), npc_events ++ events}
  end

  # Tempo- und Wendigkeitsfaktoren: Spieler aus Klasse/Upgrades, NPCs aus ihrer Art; Kettenkugel bremst
  defp speed_opts(ship, t) do
    {cap, turn} =
      case ship.kind do
        :merchant -> {@merchant_speed, 1.0}
        :hunter -> {@hunter_speed, 1.0}
        :player -> {Ships.stats(ship).speed_mult, Ships.stats(ship).turn_mult}
      end

    slow = if ship.slow_until > t, do: 0.5, else: 1.0
    [cap_mult: cap * slow, turn_mult: turn]
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
          enemy = nearest_player(acc, ship, @hunter_aggro)

          {keys, fires, target, rng} =
            Hunter.think(ship, enemy, acc.targets[id], solid?, acc.rng, nil)

          acc = %{
            acc
            | ships: Map.put(acc.ships, id, %{ship | input: keys}),
              targets: Map.put(acc.targets, id, target),
              rng: rng
          }

          Enum.reduce(fires, {acc, ev}, fn side, {a, e} ->
            {a, more} = Combat.fire(a, id, side)
            {a, e ++ more}
          end)

        %{alive?: true} = ship ->
          flee =
            with %{from: from, until: until} <- ship.flee,
                 true <- until > acc.time,
                 %{alive?: true} = attacker <- acc.ships[from] do
              {attacker.x, attacker.y}
            else
              _ -> nil
            end

          {keys, target, rng} = Wander.think(ship, acc.targets[id], solid?, acc.rng, flee)

          {%{
             acc
             | ships: Map.put(acc.ships, id, %{ship | input: keys}),
               targets: Map.put(acc.targets, id, target),
               rng: rng
           }, ev}

        _ ->
          {acc, ev}
      end
    end)
  end

  # Nächster lebender Spieler im Umkreis `radius` (nicht in der Schonzeit)
  defp nearest_player(state, ship, radius) do
    state.ships
    |> Map.values()
    |> Enum.filter(&(&1.kind == :player and &1.alive? and &1.invuln_until <= state.time))
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
  Sicht für einen Spieler: Schiffe, Kugeln und Ereignisse im Umkreis (`aoi/0`) plus
  eigener Status. `nil`, wenn es das Schiff nicht gibt.
  """
  @spec snapshot_for(t(), term(), list()) :: map() | nil
  def snapshot_for(state, id, events) do
    case state.ships[id] do
      nil ->
        nil

      me ->
        near? = fn x, y -> (x - me.x) * (x - me.x) + (y - me.y) * (y - me.y) <= @aoi * @aoi end
        t = state.time

        %{
          t: "snap",
          time: t,
          w: Float.round(Sailing.wind_angle(state.wind), 3),
          wi: max(state.wind_at - t, 0),
          you: id,
          ships:
            for {_, s} <- state.ships, near?.(s.x, s.y) do
              %{
                i: s.id,
                n: s.name,
                c: s.color,
                x: r2(s.x),
                y: r2(s.y),
                h: r2(s.heading),
                v: r2(s.speed),
                hp: Float.round(max(s.hp, 0.0), 1),
                mh: s.max_hp,
                a: s.alive?,
                iv: s.invuln_until > t,
                k: s.kills,
                kd: Atom.to_string(s.kind),
                cl: Atom.to_string(s.class),
                rd: s.radius,
                dk: s.docked != nil,
                bu: s.burn_until > t,
                sl: s.slow_until > t
              }
            end,
          balls:
            for b <- state.balls, near?.(b.x, b.y) do
              [b.id, r2(b.x), r2(b.y), r2(b.vx), r2(b.vy)]
            end,
          ports:
            for p <- Ports.near(state.seed, me.x, me.y, @aoi) do
              [p.id, p.x, p.y, p.name, p.land]
            end,
          loot:
            for p <- state.loot, near?.(p.x, p.y) do
              [p.id, r2(p.x), r2(p.y), p.gold]
            end,
          me: %{
            g: me.gold,
            b: me.bank,
            am: %{c: Map.get(me.ammo, :chain, 0), f: Map.get(me.ammo, :fire, 0)},
            as: Atom.to_string(me.ammo_sel),
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
          ev: for(e <- events, enc = encode(e, near?), enc != nil, do: enc)
        }
    end
  end

  # Ereignisse als kurze JSON-Arrays; nur wenn sie im Umkreis liegen
  defp encode({:fire, id, side, x, y}, near?),
    do: if(near?.(x, y), do: ["fire", id, to_string(side), r2(x), r2(y)])

  defp encode({:loot, id, gold, x, y}, near?),
    do: if(near?.(x, y), do: ["loot", id, gold, r2(x), r2(y)])

  defp encode({:respawn, id, x, y}, near?),
    do: if(near?.(x, y), do: ["respawn", id, r2(x), r2(y)])

  defp encode({:splash, x, y}, near?), do: if(near?.(x, y), do: ["splash", r2(x), r2(y)])

  defp encode({:hit, v, by, amount, x, y}, near?),
    do: if(near?.(x, y), do: ["hit", v, by, amount, r2(x), r2(y)])

  defp encode({:kill, killer, v, x, y}, near?),
    do: if(near?.(x, y), do: ["kill", killer, v, r2(x), r2(y)])

  defp encode(_other, _near?), do: nil

  defp r2(x), do: Float.round(x * 1.0, 2)
end
