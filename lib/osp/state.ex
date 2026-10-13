defmodule Osp.State do
  @moduledoc """
  Reiner Zustand einer Welt (ohne Prozesse): Schiffe, Kugeln, Powerups, Wind, Zufall.
  `Osp.World` ist nur die Hülle (Takt, Verbindungen, Versand); alles Spielerische steht hier und in
  `Osp.Combat`, `Osp.Sailing`, `Osp.Spawn`, `Osp.Wander` – dadurch ohne Prozess testbar.

  Schiffe haben `kind` `:player` oder `:merchant` (NPC-Händler: langsam, flieht bei Beschuss).
  """

  alias Osp.{Combat, Sailing, Spawn, Terrain, Wander}

  @step_ms 25
  @aoi 45.0
  @wind_every_ms 30_000
  @grace_ms 10_000
  @colors 6
  @player_hp 12
  @merchant_hp 6
  @merchant_speed 0.6

  defstruct seed: 0,
            time: 0,
            acc: 0,
            ships: %{},
            targets: %{},
            balls: [],
            powerups: [],
            wind: 0,
            wind_at: @wind_every_ms,
            rng: nil,
            next_id: 1,
            pu_at: 0

  @type t :: %__MODULE__{}

  def aoi, do: @aoi
  def idle, do: %{up?: false, left?: false, right?: false}

  @doc "Neue Welt mit `merchants` NPC-Händlern."
  @spec new(integer(), non_neg_integer()) :: t()
  def new(seed, merchants \\ 0) do
    rng = :rand.seed_s(:exsss, seed)
    {dir, rng} = :rand.uniform_s(6, rng)
    state = %__MODULE__{seed: seed, rng: rng, wind: dir - 1}
    Enum.reduce(1..merchants//1, state, &add_merchant(&2, &1))
  end

  # --- Schiffe ----------------------------------------------------------------------

  def put_ship(state, id, ship), do: %{state | ships: Map.put(state.ships, id, ship)}
  def update_ship(state, id, fun), do: %{state | ships: Map.update!(state.ships, id, fun)}

  defp new_ship(id, name, kind, x, y, heading) do
    hp = if kind == :merchant, do: @merchant_hp, else: @player_hp

    %{
      id: id,
      name: name,
      kind: kind,
      color: :erlang.phash2(id, @colors),
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
      shield_until: 0,
      boost_until: 0,
      reload_l: 0,
      reload_r: 0,
      power: nil,
      kills: 0,
      deaths: 0,
      damage: 0.0,
      last_hit_by: nil,
      flee: nil
    }
  end

  @doc "Spieler tritt bei oder verbindet sich neu (Schiff bleibt dann, wo es ist)."
  @spec join(t(), term(), String.t()) :: t()
  def join(state, id, name) do
    if Map.has_key?(state.ships, id) do
      update_ship(state, id, &%{&1 | name: name, gone_at: nil})
    else
      {x, y, heading, rng} = pick_spawn(state)
      state = %{state | rng: rng}
      ship = %{new_ship(id, name, :player, x, y, heading) | invuln_until: state.time + 2_000}
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

  defp pick_spawn(state) do
    others = for {_, s} <- state.ships, s.alive?, do: {s.x, s.y}
    Spawn.pick(state.seed, others, others, state.rng)
  end

  defp add_merchant(state, n) do
    id = "npc-#{n}"
    {x, y, heading, rng} = pick_spawn(state)
    ship = new_ship(id, "Händler #{n}", :merchant, x, y, heading)
    %{put_ship(%{state | rng: rng}, id, ship) | targets: Map.put(state.targets, id, nil)}
  end

  @doc "Neuer Startpunkt für ein wiederauftauchendes Schiff: `{state, x, y, heading}`."
  def respawn_point(state, _id) do
    {x, y, heading, rng} = pick_spawn(state)
    {%{state | rng: rng}, x, y, heading}
  end

  # --- Eingaben für den Kampf (dünn, damit die Hülle nur State kennt) --------------------

  def fire(state, id, side), do: Combat.fire(state, id, side)
  def use_power(state, id), do: Combat.use_power(state, id)

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
    state = state |> turn_wind() |> think_npcs()
    solid? = fn x, y -> Terrain.land?(state.seed, x, y) end
    wind = Sailing.wind_angle(state.wind)

    ships =
      Map.new(state.ships, fn {id, s} ->
        if s.alive? do
          moved = Sailing.step(s, s.input, ms / 1000, wind, solid?, speed_opts(s, state.time))
          {id, Map.merge(s, Map.take(moved, [:x, :y, :heading, :speed]))}
        else
          {id, s}
        end
      end)

    {state, events} = Combat.step(%{state | ships: ships}, ms)
    {expire(state), events}
  end

  defp speed_opts(%{kind: :merchant}, _t), do: [cap_mult: @merchant_speed]

  defp speed_opts(%{boost_until: b}, t) when b > t, do: [cap_mult: 1.9, accel_mult: 2.0]
  defp speed_opts(_s, _t), do: []

  defp turn_wind(%{time: t, wind_at: at} = state) when t >= at,
    do: %{state | wind: Integer.mod(state.wind - 1, 6), wind_at: at + @wind_every_ms}

  defp turn_wind(state), do: state

  # NPCs denken alle 200 ms
  defp think_npcs(%{time: t} = state) when rem(t, 200) != 0, do: state

  defp think_npcs(state) do
    solid? = fn x, y -> Terrain.land?(state.seed, x, y) end

    Enum.reduce(Map.keys(state.targets), state, fn id, acc ->
      ship = acc.ships[id]

      if ship.alive? do
        flee =
          with %{from: from, until: until} <- ship.flee,
               true <- until > acc.time,
               %{alive?: true} = attacker <- acc.ships[from] do
            {attacker.x, attacker.y}
          else
            _ -> nil
          end

        {keys, target, rng} = Wander.think(ship, acc.targets[id], solid?, acc.rng, flee)

        %{
          acc
          | ships: Map.put(acc.ships, id, %{ship | input: keys}),
            targets: Map.put(acc.targets, id, target),
            rng: rng
        }
      else
        acc
      end
    end)
  end

  # Getrennte Spieler nach der Schonfrist entfernen
  defp expire(state) do
    gone =
      for {id, %{gone_at: at}} <- state.ships, at != nil, state.time - at >= @grace_ms, do: id

    Enum.reduce(gone, state, &leave(&2, &1))
  end

  # --- Schnappschuss -------------------------------------------------------------------

  @doc """
  Sicht für einen Spieler: Schiffe, Kugeln, Powerups und Ereignisse im Umkreis (`aoi/0`) plus
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
                sh: s.shield_until > t,
                bo: s.boost_until > t,
                iv: s.invuln_until > t,
                k: s.kills,
                m: s.kind == :merchant
              }
            end,
          balls:
            for b <- state.balls, near?.(b.x, b.y) do
              [b.id, r2(b.x), r2(b.y), r2(b.vx), r2(b.vy), b.kind]
            end,
          powerups:
            for p <- state.powerups, near?.(p.x, p.y) do
              [p.id, r2(p.x), r2(p.y), Atom.to_string(p.type)]
            end,
          me: %{
            rl: me.reload_l,
            rr: me.reload_r,
            pw: me.power && Atom.to_string(me.power),
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

  defp encode({:power, id, type, x, y}, near?),
    do: if(near?.(x, y), do: ["power", id, to_string(type), r2(x), r2(y)])

  defp encode({:pickup, id, type, x, y}, near?),
    do: if(near?.(x, y), do: ["pickup", id, to_string(type), r2(x), r2(y)])

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
