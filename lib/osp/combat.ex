defmodule Osp.Combat do
  @moduledoc """
  Kampf (rein, arbeitet auf `Osp.State`): Breitseiten, Kugeln, Treffer, Tod und Wiederauftauchen,
  Powerups. Zahlen siehe docs/handout.md §5 (alle in WE, ms bzw. WE/s).

  Funktionen geben `{state, events}` zurück. Ereignisse (Tupel) gehen an die Clients:

    * `{:fire, id, side, x, y}`, `{:power, id, type, x, y}`, `{:pickup, id, type, x, y}`
    * `{:hit, victim, by, amount, x, y}`, `{:kill, killer, victim, x, y}`
    * `{:splash, x, y}`, `{:respawn, id, x, y}`
  """

  alias Osp.{Spawn, State, Terrain}

  @reload_ms 1_800
  @ball_speed 6.0
  @ball_ttl 750
  @ball_r 0.08
  @respawn_ms 3_000
  @merchant_respawn_ms 8_000
  @invuln_ms 2_000
  @pickup_r 0.55
  @powers [:torpedo, :boost, :shield, :repair, :volley]
  @powerup_every_ms 3_000
  @powerup_near 3
  @powerup_ttl_ms 90_000

  def reload_ms, do: @reload_ms
  def powers, do: @powers
  def respawn_ms, do: @respawn_ms

  # --- Eingaben -------------------------------------------------------------------

  @doc "Seitliche Breitseite (`:left` = Backbord/Q, `:right` = Steuerbord/E)."
  @spec fire(State.t(), term(), :left | :right) :: {State.t(), list()}
  def fire(state, id, side) when side in [:left, :right] do
    case state.ships[id] do
      %{alive?: true} = s ->
        key = if side == :left, do: :reload_l, else: :reload_r

        if Map.fetch!(s, key) > 0 do
          {state, []}
        else
          state = State.put_ship(state, id, Map.put(s, key, @reload_ms))
          state = broadside(state, s, side, 3, 0.22)
          {state, [{:fire, id, side, s.x, s.y}]}
        end

      _ ->
        {state, []}
    end
  end

  @doc "Eingesammeltes Powerup auslösen (Leertaste)."
  @spec use_power(State.t(), term()) :: {State.t(), list()}
  def use_power(state, id) do
    case state.ships[id] do
      %{alive?: true, power: power} = s when power != nil ->
        state = State.put_ship(state, id, %{s | power: nil})
        {apply_power(state, s, power), [{:power, id, power, s.x, s.y}]}

      _ ->
        {state, []}
    end
  end

  defp apply_power(state, s, :torpedo) do
    {dx, dy} = {:math.cos(s.heading), :math.sin(s.heading)}
    v = 8.0 + s.speed

    add_ball(state, %{
      owner: s.id,
      x: s.x + dx * 0.5,
      y: s.y + dy * 0.5,
      vx: dx * v,
      vy: dy * v,
      ttl: 1_000,
      dmg: 4.0,
      r: 0.2,
      kind: 1
    })
  end

  defp apply_power(state, s, :boost),
    do: State.put_ship(state, s.id, %{state.ships[s.id] | boost_until: state.time + 2_500})

  defp apply_power(state, s, :shield),
    do: State.put_ship(state, s.id, %{state.ships[s.id] | shield_until: state.time + 5_000})

  defp apply_power(state, s, :repair),
    do: State.put_ship(state, s.id, %{state.ships[s.id] | hp: min(s.hp + 5, s.max_hp * 1.0)})

  defp apply_power(state, s, :volley) do
    state |> broadside(s, :left, 5, 0.2) |> broadside(s, :right, 5, 0.2)
  end

  # `n` Kugeln seitlich vom Rumpf, entlang des Rumpfs verteilt
  defp broadside(state, s, side, n, spacing) do
    angle = s.heading + if(side == :right, do: :math.pi() / 2, else: -:math.pi() / 2)
    {px, py} = {:math.cos(angle), :math.sin(angle)}
    {hx, hy} = {:math.cos(s.heading), :math.sin(s.heading)}

    Enum.reduce(0..(n - 1), state, fn i, st ->
      along = (i - (n - 1) / 2) * spacing

      add_ball(st, %{
        owner: s.id,
        x: s.x + px * 0.3 + hx * along,
        y: s.y + py * 0.3 + hy * along,
        vx: px * @ball_speed + hx * s.speed * 0.8,
        vy: py * @ball_speed + hy * s.speed * 0.8,
        ttl: @ball_ttl,
        dmg: 1.0,
        r: @ball_r,
        kind: 0
      })
    end)
  end

  defp add_ball(state, ball) do
    %{
      state
      | balls: [Map.put(ball, :id, state.next_id) | state.balls],
        next_id: state.next_id + 1
    }
  end

  # --- Zeitschritt ----------------------------------------------------------------

  @doc "Nachladen, Kugeln, Einsammeln, Wiederauftauchen, Powerup-Spawn für einen Schritt."
  @spec step(State.t(), non_neg_integer()) :: {State.t(), list()}
  def step(state, ms) do
    state = reload(state, ms)
    {state, e1} = move_balls(state, ms / 1000, ms)
    {state, e2} = pickups(state)
    {state, e3} = respawns(state)
    state = spawn_powerups(state)
    {state, e1 ++ e2 ++ e3}
  end

  defp reload(state, ms) do
    ships =
      Map.new(state.ships, fn {id, s} ->
        {id, %{s | reload_l: max(s.reload_l - ms, 0), reload_r: max(s.reload_r - ms, 0)}}
      end)

    %{state | ships: ships}
  end

  # --- Kugeln ---------------------------------------------------------------------

  defp move_balls(state, dt, ms) do
    {keep, state, events} =
      Enum.reduce(state.balls, {[], state, []}, fn ball, {keep, st, ev} ->
        ball = %{ball | x: ball.x + ball.vx * dt, y: ball.y + ball.vy * dt, ttl: ball.ttl - ms}

        cond do
          ball.ttl <= 0 ->
            {keep, st, ev}

          Terrain.land?(st.seed, ball.x, ball.y) ->
            {keep, st, [{:splash, ball.x, ball.y} | ev]}

          true ->
            case hit_ship(st, ball) do
              nil ->
                {[ball | keep], st, ev}

              victim ->
                {st, more} = hurt(st, victim, ball.dmg, ball.owner, ball.x, ball.y)
                {keep, st, more ++ ev}
            end
        end
      end)

    {%{state | balls: Enum.reverse(keep)}, Enum.reverse(events)}
  end

  defp hit_ship(state, ball) do
    Enum.find_value(state.ships, fn {id, s} ->
      r = Osp.Sailing.ship_radius() + ball.r

      if s.alive? and id != ball.owner and s.invuln_until <= state.time and
           (s.x - ball.x) * (s.x - ball.x) + (s.y - ball.y) * (s.y - ball.y) < r * r,
         do: id
    end)
  end

  # --- Schaden, Tod ----------------------------------------------------------------

  @doc "Schaden an `victim` (halbiert mit Schild, keiner bei Schonzeit). Gibt `{state, events}`."
  def hurt(state, victim_id, amount, by, x, y) do
    s = state.ships[victim_id]

    if s == nil or not s.alive? or s.invuln_until > state.time do
      {state, []}
    else
      amount = if s.shield_until > state.time, do: amount * 0.5, else: amount
      lost = min(amount, s.hp)
      flee = if s.kind == :merchant and by != nil, do: %{from: by, until: state.time + 8_000}
      s = %{s | hp: s.hp - amount, last_hit_by: by || s.last_hit_by, flee: flee || s.flee}
      state = State.put_ship(state, victim_id, s)

      state =
        if by && by != victim_id && state.ships[by],
          do: State.update_ship(state, by, &%{&1 | damage: &1.damage + lost}),
          else: state

      events = [{:hit, victim_id, by, Float.round(amount * 1.0, 1), x, y}]

      if s.hp <= 0 do
        {state, died} = kill(state, victim_id)
        {state, events ++ died}
      else
        {state, events}
      end
    end
  end

  defp kill(state, id) do
    s = state.ships[id]
    killer = s.last_hit_by
    delay = if s.kind == :merchant, do: @merchant_respawn_ms, else: @respawn_ms

    state =
      State.update_ship(state, id, fn v ->
        %{
          v
          | alive?: false,
            respawn_at: state.time + delay,
            deaths: v.deaths + 1,
            power: nil,
            speed: 0.0,
            input: State.idle()
        }
      end)

    state =
      if killer && killer != id && state.ships[killer],
        do: State.update_ship(state, killer, &%{&1 | kills: &1.kills + 1}),
        else: state

    {state, [{:kill, killer, id, s.x, s.y}]}
  end

  # --- Powerups ---------------------------------------------------------------------

  defp pickups(state) do
    Enum.reduce(Map.keys(state.ships), {state, []}, fn id, {st, ev} ->
      s = st.ships[id]

      with true <- s.alive? and s.power == nil and s.kind == :player,
           pu when pu != nil <-
             Enum.find(st.powerups, fn p ->
               (p.x - s.x) * (p.x - s.x) + (p.y - s.y) * (p.y - s.y) < @pickup_r * @pickup_r
             end) do
        st = %{st | powerups: Enum.reject(st.powerups, &(&1.id == pu.id))}
        st = State.update_ship(st, id, &%{&1 | power: pu.type})
        {st, ev ++ [{:pickup, id, pu.type, s.x, s.y}]}
      else
        _ -> {st, ev}
      end
    end)
  end

  # Powerups tauchen in der Nähe von Spielern auf (nicht überall in der unendlichen Welt)
  defp spawn_powerups(%{time: t, pu_at: at} = state) when t >= at do
    state = %{state | pu_at: t + @powerup_every_ms}
    state = %{state | powerups: Enum.filter(state.powerups, &(t - &1.born < @powerup_ttl_ms))}
    humans = for {_, s} <- state.ships, s.kind == :player, s.alive?, do: s

    if humans == [] do
      state
    else
      {i, rng} = :rand.uniform_s(length(humans), state.rng)
      h = Enum.at(humans, i - 1)
      {a, rng} = :rand.uniform_s(rng)
      {d, rng} = :rand.uniform_s(rng)
      {j, rng} = :rand.uniform_s(length(@powers), rng)
      angle = a * 2 * :math.pi()
      dist = 6.0 + d * 20.0
      x = h.x + :math.cos(angle) * dist
      y = h.y + :math.sin(angle) * dist

      near =
        Enum.count(state.powerups, fn p ->
          (p.x - h.x) * (p.x - h.x) + (p.y - h.y) * (p.y - h.y) < 40 * 40
        end)

      state = %{state | rng: rng}

      if near < @powerup_near and Spawn.clear?(state.seed, x, y, 0.8) do
        pu = %{id: state.next_id, type: Enum.at(@powers, j - 1), x: x, y: y, born: t}
        %{state | powerups: [pu | state.powerups], next_id: state.next_id + 1}
      else
        state
      end
    end
  end

  defp spawn_powerups(state), do: state

  # --- Wiederauftauchen ----------------------------------------------------------------

  defp respawns(state) do
    Enum.reduce(Map.keys(state.ships), {state, []}, fn id, {st, ev} ->
      s = st.ships[id]

      if not s.alive? and st.time >= s.respawn_at do
        {st, x, y, heading} = State.respawn_point(st, id)

        s = %{
          s
          | alive?: true,
            hp: s.max_hp * 1.0,
            x: x,
            y: y,
            heading: heading,
            speed: 0.0,
            invuln_until: st.time + @invuln_ms,
            reload_l: 600,
            reload_r: 600,
            shield_until: 0,
            boost_until: 0,
            last_hit_by: nil,
            flee: nil
        }

        {State.put_ship(st, id, s), ev ++ [{:respawn, id, x, y}]}
      else
        {st, ev}
      end
    end)
  end
end
