defmodule Osp.Combat do
  @moduledoc """
  Kampf (rein, arbeitet auf `Osp.State`): Breitseiten, Kugeln, Treffer, Tod und Wiederauftauchen.
  Zahlen siehe docs/handout.md §5 (alle in WE, ms bzw. WE/s).

  Funktionen geben `{state, events}` zurück. Ereignisse (Tupel) gehen an die Clients:

    * `{:fire, id, side, x, y}`
    * `{:hit, victim, by, amount, x, y}`, `{:kill, killer, victim, x, y}`
    * `{:splash, x, y}`, `{:respawn, id, x, y}`, `{:loot, id, gold, x, y}` (Beute eingesammelt)
  """

  alias Osp.{Ports, Reputation, Ships, State, Terrain}

  # Lange Ladezeit, dafür kräftige Salven: jede Breitseite zählt, Dauerkreisen lohnt nicht
  @reload_ms 3_000
  @ball_speed 6.0
  @ball_ttl 750
  @ball_r 0.08
  @hunter_reload_ms 4_000
  @merchant_reload_ms 3_200
  # Längsfeuer: Treffer von vorn oder hinten (Kugel fliegt entlang der Schiffsachse) zählen doppelt
  @rake_cos 0.7
  @rake_mult 2.0
  @respawn_ms 3_000
  @invuln_ms 2_000
  @loot_r 0.75
  @loot_ttl_ms 60_000
  @death_loss 0.3
  @pile 25
  @slow_ms 3_000
  @burn_ms 3_000
  @burn_tick_ms 1_000
  # Notwehr: ein Jäger, der den Spieler in den letzten 15 s beschossen hat oder auf ihn Jagd macht
  @self_defense_ms 15_000

  def reload_ms, do: @reload_ms
  def respawn_ms, do: @respawn_ms

  # --- Eingaben -------------------------------------------------------------------

  @doc """
  Seitliche Breitseite (`:left` = Backbord/Q, `:right` = Steuerbord/E). Nicht im Hafen (angedockt
  oder in der Schutzzone). Kugeln je Salve und Schaden kommen aus Klasse und Upgrades, die gewählte
  Sondermunition (`ammo_sel`) wird je Salve um eins verbraucht, sonst Vollkugeln.
  """
  @spec fire(State.t(), term(), :left | :right) :: {State.t(), list()}
  def fire(state, id, side) when side in [:left, :right] do
    case state.ships[id] do
      %{alive?: true, docked: nil} = s ->
        key = if side == :left, do: :reload_l, else: :reload_r

        cond do
          Map.fetch!(s, key) > 0 -> {state, []}
          State.safe_for?(state, s) -> {state, []}
          true -> shoot(state, s, side, key)
        end

      _ ->
        {state, []}
    end
  end

  defp shoot(state, s, side, key) do
    reload =
      case s.kind do
        :hunter -> @hunter_reload_ms
        :merchant -> @merchant_reload_ms
        _ -> @reload_ms
      end

    {ammo, s} = take_ammo(s)
    s = Map.put(s, key, reload)
    state = State.put_ship(state, s.id, s)
    {cannons, dmg_mult} = weapon(s)
    dmg = dmg_mult * ammo_damage(ammo)
    spacing = min(0.22, 0.75 / max(cannons - 1, 1))
    state = broadside(state, s, side, cannons, spacing, dmg, ammo)
    {state, [{:fire, s.id, side, s.x, s.y}]}
  end

  # Kugeln je Salve und Schadensfaktor: Spieler nach Klasse/Upgrades, NPCs fest
  defp weapon(%{kind: :player} = s) do
    st = Ships.stats(s)
    {st.cannons, st.dmg_mult}
  end

  # Händler sind gut bewaffnet (4 Kanonen je Seite), Jäger leichter (3)
  defp weapon(%{kind: :merchant}), do: {4, 1.0}
  defp weapon(_npc), do: {3, 1.0}

  defp take_ammo(%{ammo_sel: sel} = s) when sel in [:chain, :fire] do
    have = Map.get(s.ammo, sel, 0)

    if have > 0,
      do: {sel, %{s | ammo: Map.put(s.ammo, sel, have - 1)}},
      else: {:ball, s}
  end

  defp take_ammo(s), do: {:ball, s}

  defp ammo_damage(:chain), do: 0.75
  defp ammo_damage(:fire), do: 0.9
  defp ammo_damage(:ball), do: 1.5

  # `n` Kugeln seitlich vom Rumpf, entlang des Rumpfs verteilt
  defp broadside(state, s, side, n, spacing, dmg, ammo) do
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
        dmg: dmg,
        r: @ball_r,
        ammo: ammo,
        owner_kind: s.kind
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

  @doc "Nachladen, Kugeln, Beute einsammeln und Wiederauftauchen für einen Schritt."
  @spec step(State.t(), non_neg_integer()) :: {State.t(), list()}
  def step(state, ms) do
    state = reload(state, ms)
    {state, e0} = burn(state)
    {state, e1} = move_balls(state, ms / 1000, ms)
    {state, e2} = loot_pickups(state)
    state = %{state | loot: Enum.filter(state.loot, &(state.time - &1.born < @loot_ttl_ms))}
    {state, e3} = respawns(state)
    {state, e0 ++ e1 ++ e2 ++ e3}
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

          zone_stops?(st, ball) ->
            {keep, st, ev}

          true ->
            case hit_ship(st, ball) do
              nil ->
                {[ball | keep], st, ev}

              victim ->
                rake? = raking?(st.ships[victim], ball)
                dmg = if rake?, do: ball.dmg * @rake_mult, else: ball.dmg
                {st, more} = hurt(st, victim, dmg, ball.owner, ball.x, ball.y)
                st = if more == [], do: st, else: ammo_effect(st, victim, ball)
                more = if rake? and more != [], do: more ++ [{:rake, ball.x, ball.y}], else: more
                {keep, st, more ++ ev}
            end
        end
      end)

    {%{state | balls: Enum.reverse(keep)}, Enum.reverse(events)}
  end

  # Flog die Kugel (fast) entlang der Schiffsachse, traf sie Bug oder Heck?
  defp raking?(ship, ball) do
    speed = :math.sqrt(ball.vx * ball.vx + ball.vy * ball.vy)

    speed > 0 and
      abs((ball.vx * :math.cos(ship.heading) + ball.vy * :math.sin(ship.heading)) / speed) >=
        @rake_cos
  end

  # Schutzzone: Kugeln geschützter Schiffe verschwinden; Kugeln von Gesuchten (dort ungeschützt) und
  # Fort-Kugeln nicht; ist der Schütze schon weg, gilt die Zone wie bisher
  defp zone_stops?(_state, %{owner_kind: :fort}), do: false

  defp zone_stops?(state, ball) do
    case state.ships[ball.owner] do
      nil -> Ports.safe?(state.seed, ball.x, ball.y)
      owner -> State.safe_at?(state, ball.x, ball.y, owner)
    end
  end

  defp hit_ship(state, ball) do
    Enum.find_value(state.ships, fn {id, s} ->
      r = s.radius + ball.r

      if s.alive? and id != ball.owner and s.invuln_until <= state.time and
           (ball.owner_kind == :player or s.kind == :player) and
           (s.x - ball.x) * (s.x - ball.x) + (s.y - ball.y) * (s.y - ball.y) < r * r,
         do: id
    end)
  end

  # --- Schaden, Tod ----------------------------------------------------------------

  @doc "Schaden an `victim` (keiner bei Schonzeit). Gibt `{state, events}`."
  def hurt(state, victim_id, amount, by, x, y) do
    s = state.ships[victim_id]

    if s == nil or not s.alive? or s.invuln_until > state.time or
         State.safe_for?(state, s) do
      {state, []}
    else
      lost = min(amount, s.hp)
      flee = if s.kind == :merchant and by != nil, do: %{from: by, until: state.time + 8_000}

      s = %{
        s
        | hp: s.hp - amount,
          last_hit_by: by || s.last_hit_by,
          flee: flee || s.flee,
          attacked_at: note_attack(state, s, by)
      }

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

  # Trifft ein NPC einen Spieler, merkt sich dieser Zeit und Angreifer (für die Notwehr-Regel)
  defp note_attack(state, %{kind: :player, attacked_at: marks}, by) when by != nil do
    case state.ships[by] do
      %{kind: kind} when kind != :player -> Map.put(marks, by, state.time)
      _ -> marks
    end
  end

  defp note_attack(_state, s, _by), do: Map.get(s, :attacked_at, %{})

  # Wirkung der Sondermunition auf ein getroffenes (überlebendes) Schiff
  defp ammo_effect(state, victim, %{ammo: :chain}) do
    case state.ships[victim] do
      nil -> state
      s -> State.put_ship(state, victim, %{s | slow_until: state.time + @slow_ms})
    end
  end

  defp ammo_effect(state, victim, %{ammo: :fire, owner: owner}) do
    case state.ships[victim] do
      %{burn_until: until} = s when until <= state.time ->
        State.put_ship(state, victim, %{
          s
          | burn_until: state.time + @burn_ms,
            burn_next: state.time + @burn_tick_ms,
            burn_by: owner
        })

      _ ->
        state
    end
  end

  defp ammo_effect(state, _victim, _ball), do: state

  # Brennende Schiffe: jede Sekunde 1 Schaden, bis die Zeit um ist (nicht im Hafen)
  defp burn(state) do
    Enum.reduce(Map.keys(state.ships), {state, []}, fn id, {st, ev} ->
      s = st.ships[id]

      cond do
        s == nil or s.burn_until <= st.time ->
          {st, ev}

        State.safe_for?(st, s) ->
          {State.put_ship(st, id, %{s | burn_until: 0}), ev}

        st.time >= s.burn_next ->
          st = State.put_ship(st, id, %{s | burn_next: s.burn_next + @burn_tick_ms})
          {st, more} = hurt(st, id, 1.0, s.burn_by, s.x, s.y)
          {st, ev ++ more}

        true ->
          {st, ev}
      end
    end)
  end

  defp kill(state, id) do
    s = state.ships[id]
    killer = s.last_hit_by

    state =
      if killer && killer != id && state.ships[killer],
        do: State.update_ship(state, killer, &%{&1 | kills: &1.kills + 1}),
        else: state

    state =
      case s.kind do
        :player ->
          # Ein Teil des getragenen Golds geht verloren und liegt als Beute im Wasser
          lost = round(s.gold * @death_loss)

          state
          |> State.update_ship(id, fn v ->
            %{
              v
              | alive?: false,
                respawn_at: state.time + @respawn_ms,
                deaths: v.deaths + 1,
                gold: v.gold - lost,
                speed: 0.0,
                input: State.idle()
            }
          end)
          |> drop_loot(s.x, s.y, lost)

        _npc ->
          # NPCs verschwinden mit dem Untergang und lassen ihr Kopfgeld fallen
          state |> State.remove_npc(id) |> drop_loot(s.x, s.y, s.bounty)
      end

    {state, rep_events} = punish(state, s, killer)
    state = State.quest_kill(state, killer, s)

    {state, quest_events} =
      if s.kind == :player, do: State.fail_deliveries(state, id), else: {state, []}

    {state, [{:kill, killer, id, s.x, s.y}] ++ rep_events ++ quest_events}
  end

  # Ruf: Wer ein Schiff einer Nation versenkt, verliert Ruf bei dieser Nation (Händler 8, Jäger 5) –
  # außer in Notwehr gegen einen Jäger, der ihn gerade angegriffen hat
  defp punish(state, victim, killer_id) do
    with true <- victim.kind in [:merchant, :hunter],
         nation when nation != nil <- victim.nation,
         %{kind: :player, alive?: true} = killer <- killer_id && state.ships[killer_id],
         penalty when penalty > 0 <- Reputation.penalty(victim.kind),
         false <- self_defense?(state, victim, killer) do
      State.add_rep(state, killer_id, nation, -penalty)
    else
      _ -> {state, []}
    end
  end

  defp self_defense?(_state, %{kind: :merchant}, _killer), do: false

  defp self_defense?(state, hunter, killer) do
    recent? = fn t -> is_integer(t) and state.time - t <= @self_defense_ms end

    case hunter.hunting do
      {id, t} when id == killer.id ->
        recent?.(t) or recent?.(Map.get(killer.attacked_at, hunter.id))

      _ ->
        recent?.(Map.get(killer.attacked_at, hunter.id))
    end
  end

  # --- Beute --------------------------------------------------------------------------

  @doc "Lässt `amount` Gold als Münzhaufen (je höchstens #{@pile}) um `(x, y)` im Wasser treiben."
  def drop_loot(state, _x, _y, amount) when amount <= 0, do: state

  def drop_loot(state, x, y, amount) do
    piles = amount |> Kernel./(@pile) |> Float.ceil() |> trunc() |> max(1) |> min(6)
    each = div(amount, piles)
    extra = amount - each * piles

    Enum.reduce(0..(piles - 1), state, fn i, st ->
      {a, rng} = :rand.uniform_s(st.rng)
      {d, rng} = :rand.uniform_s(rng)
      angle = a * 2 * :math.pi()
      dist = if piles == 1, do: 0.0, else: 0.3 + d * 0.5
      px = x + :math.cos(angle) * dist
      py = y + :math.sin(angle) * dist
      gold = each + if(i == 0, do: extra, else: 0)

      # Kein Münzhaufen im Land: dann direkt am Todesort
      {px, py} = if Terrain.land?(st.seed, px, py), do: {x, y}, else: {px, py}
      pile = %{id: st.next_id, x: px, y: py, gold: gold, born: st.time}
      %{st | rng: rng, loot: [pile | st.loot], next_id: st.next_id + 1}
    end)
  end

  defp loot_pickups(state) do
    Enum.reduce(Map.keys(state.ships), {state, []}, fn id, {st, ev} ->
      s = st.ships[id]

      with true <- s.alive? and s.kind == :player,
           piles when piles != [] <-
             Enum.filter(st.loot, fn p ->
               (p.x - s.x) * (p.x - s.x) + (p.y - s.y) * (p.y - s.y) < @loot_r * @loot_r
             end) do
        gold = piles |> Enum.map(& &1.gold) |> Enum.sum()
        ids = Enum.map(piles, & &1.id)
        st = %{st | loot: Enum.reject(st.loot, &(&1.id in ids))}
        st = State.update_ship(st, id, &%{&1 | gold: &1.gold + gold})
        {st, ev ++ [{:loot, id, gold, s.x, s.y}]}
      else
        _ -> {st, ev}
      end
    end)
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
