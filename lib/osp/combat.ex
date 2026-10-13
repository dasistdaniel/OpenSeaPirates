defmodule Osp.Combat do
  @moduledoc """
  Kampf (rein, arbeitet auf `Osp.State`): Breitseiten, Kugeln, Treffer, Tod und Wiederauftauchen.
  Zahlen siehe docs/handout.md §5 (alle in WE, ms bzw. WE/s).

  Funktionen geben `{state, events}` zurück. Ereignisse (Tupel) gehen an die Clients:

    * `{:fire, id, side, x, y}`
    * `{:hit, victim, by, amount, x, y}`, `{:kill, killer, victim, x, y}`
    * `{:splash, x, y}`, `{:respawn, id, x, y}`
  """

  alias Osp.{State, Terrain}

  @reload_ms 1_800
  @ball_speed 6.0
  @ball_ttl 750
  @ball_r 0.08
  @respawn_ms 3_000
  @merchant_respawn_ms 8_000
  @invuln_ms 2_000

  def reload_ms, do: @reload_ms
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
        r: @ball_r
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

  @doc "Nachladen, Kugeln und Wiederauftauchen für einen Schritt."
  @spec step(State.t(), non_neg_integer()) :: {State.t(), list()}
  def step(state, ms) do
    state = reload(state, ms)
    {state, e1} = move_balls(state, ms / 1000, ms)
    {state, e2} = respawns(state)
    {state, e1 ++ e2}
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

  @doc "Schaden an `victim` (keiner bei Schonzeit). Gibt `{state, events}`."
  def hurt(state, victim_id, amount, by, x, y) do
    s = state.ships[victim_id]

    if s == nil or not s.alive? or s.invuln_until > state.time do
      {state, []}
    else
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
