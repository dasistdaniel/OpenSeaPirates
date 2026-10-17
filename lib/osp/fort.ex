defmodule Osp.Fort do
  @moduledoc """
  Die Forts der Häfen (rein, arbeitet auf `Osp.State`). Ein Fort schießt auf Spieler, die bei der
  Nation des Hafens **Gesucht** sind, nicht angedockt und in `range/0` um den Ankerplatz fahren:

    * **Warnung** bei der ersten Sichtung (`{:fort_warn, port_id, player_id, x, y}`); der erste Schuss
      fällt frühestens 1,5 s danach.
    * **Schuss:** eine Kugel (Besitzer `"fort:<port_id>"`, Art `:fort`, Schaden 3, Tempo 6 WE/s, Reichweite
      9 WE), Nachladen 5 s je Fort. Der **erste** Schuss auf einen Spieler zielt mit **Vorhalt** (trifft
      fast sicher), spätere auf die aktuelle Position (ausweichbar).
    * **Alarm:** Betritt der Gesuchte die Schutzzone, kommen zwei Jäger der Hafen-Nation; danach 3 Minuten
      Pause je Spieler und Hafen.

  Angedockte, tote und unverwundbare Spieler und alle, die nicht Gesucht sind, bleiben unbehelligt.
  Zustand je Hafen in `state.forts` (`%{port_id => %{cooldown_until, seen, shots, alarm_until}}`).
  """

  alias Osp.{Conquest, Ports, Reputation, Spawn, State}

  @range 8.0
  @warn_ms 1_500
  @cooldown_ms 5_000
  @ball_speed 6.0
  @ball_ttl 1_500
  @ball_dmg 3.0
  @alarm_pause_ms 180_000
  @alarm_hunters 2

  def range, do: @range

  @doc "Ein Zeitschritt für alle Forts; `{state, events}`."
  @spec step(State.t()) :: {State.t(), list()}
  def step(state) do
    pairs = hostile_pairs(state)

    cond do
      pairs == [] and map_size(state.forts) == 0 -> {state, []}
      true -> run(state, pairs)
    end
  end

  @doc """
  Geschwindigkeit `{vx, vy}` einer Fort-Kugel vom Hafen `port` auf `target` (`%{x, y, heading, speed}`).
  Mit `lead? = true` wird der Treffpunkt der Zielbewegung vorausberechnet, sonst auf die aktuelle
  Position gezielt.
  """
  @spec fire_velocity(map(), map(), boolean()) :: {float(), float()}
  def fire_velocity(port, target, lead?) do
    {ax, ay} =
      if lead? do
        vx = :math.cos(target.heading) * target.speed
        vy = :math.sin(target.heading) * target.speed
        t0 = dist(port.x, port.y, target.x, target.y) / @ball_speed
        t1 = dist(port.x, port.y, target.x + vx * t0, target.y + vy * t0) / @ball_speed
        {target.x + vx * t1, target.y + vy * t1}
      else
        {target.x, target.y}
      end

    d = max(dist(port.x, port.y, ax, ay), 1.0e-6)
    {(ax - port.x) / d * @ball_speed, (ay - port.y) / d * @ball_speed}
  end

  # --- Schritt -------------------------------------------------------------------------

  # Alle Paare {Hafen, Spieler}: Spieler lebt, ist nicht angedockt, ist in Reichweite und bei der Nation
  # dieses Hafens Gesucht
  defp hostile_pairs(state) do
    assaults? = state.assaults != %{}

    for {_id, p} <- state.ships,
        p.kind == :player and p.alive? and p.docked == nil,
        assaults? or wanted_somewhere?(p),
        port <- Ports.near(state.seed, p.x, p.y, @range),
        wanted_at?(state, p, port) or assault_attacker?(state, p, port),
        do: {port, p}
  end

  defp wanted_at?(state, p, port),
    do: Reputation.standing(State.rep_of(p, State.port_nation(state, port))) == :wanted

  # Im Angriff schießt das Fort auf alle Fremden, nicht nur auf Gesuchte
  defp assault_attacker?(state, p, port),
    do: Map.has_key?(state.assaults, port.id) and Conquest.attacker?(state, p, port)

  defp wanted_somewhere?(p),
    do: Enum.any?(p.rep, fn {_n, v} -> Reputation.standing(v) == :wanted end)

  defp run(state, pairs) do
    by_port = Enum.group_by(pairs, fn {port, _} -> port.id end, fn {port, p} -> {port, p} end)

    # alte Einträge für Häfen ohne Spieler in der Nähe aufräumen
    forts =
      state.forts
      |> Enum.map(fn {pid, f} -> {pid, prune(f, by_port[pid], state.time)} end)
      |> Enum.reject(fn {_pid, f} -> idle?(f, state.time) end)
      |> Map.new()

    state = %{state | forts: forts}

    Enum.reduce(by_port, {state, []}, fn {port_id, list}, {st, ev} ->
      [{port, _} | _] = list
      fort = Map.get(st.forts, port_id, new_fort())
      {st, fort, more} = port_step(st, port, Enum.map(list, &elem(&1, 1)), fort)
      {%{st | forts: Map.put(st.forts, port_id, fort)}, ev ++ more}
    end)
  end

  defp new_fort, do: %{cooldown_until: 0, seen: %{}, shots: %{}, alarm_until: %{}}

  # Spieler, die nicht mehr in Reichweite sind, verlieren ihren „gesehen"-Eintrag (neue Warnung beim
  # nächsten Besuch); abgelaufene Alarmpausen verfallen
  defp prune(fort, current, time) do
    present = MapSet.new((current || []) |> Enum.map(fn {_port, p} -> p.id end))

    %{
      fort
      | seen: Map.filter(fort.seen, fn {id, _} -> MapSet.member?(present, id) end),
        shots: Map.filter(fort.shots, fn {id, _} -> MapSet.member?(present, id) end),
        alarm_until: Map.filter(fort.alarm_until, fn {_id, until} -> until > time end)
    }
  end

  defp idle?(fort, time),
    do: fort.seen == %{} and fort.alarm_until == %{} and fort.cooldown_until <= time

  defp port_step(state, port, players, fort) do
    t = state.time

    # Warnung bei der ersten Sichtung
    {fort, events} =
      Enum.reduce(players, {fort, []}, fn p, {f, ev} ->
        if Map.has_key?(f.seen, p.id),
          do: {f, ev},
          else:
            {%{f | seen: Map.put(f.seen, p.id, t)}, ev ++ [{:fort_warn, port.id, p.id, p.x, p.y}]}
      end)

    # Alarm: Betreten der Schutzzone ruft Jäger der Hafen-Nation
    {state, fort, alarm_events} =
      Enum.reduce(players, {state, fort, []}, fn p, {st, f, ev} ->
        in_zone? = dist(port.x, port.y, p.x, p.y) <= Ports.safe_radius()
        pause_over? = Map.get(f.alarm_until, p.id, 0) <= t

        # Alarm (zwei Jäger) nur für Gesuchte; im Angriff sorgen die Verteidiger-Wellen dafür
        if in_zone? and pause_over? and wanted_at?(st, p, port) do
          st = alarm(st, port, p)
          {st, %{f | alarm_until: Map.put(f.alarm_until, p.id, t + @alarm_pause_ms)}, ev}
        else
          {st, f, ev}
        end
      end)

    # Schuss: ein Schuss je Fort, auf den nächsten Spieler, der lange genug gesehen ist
    {state, fort, shot_events} = maybe_shoot(state, port, players, fort)
    {state, fort, events ++ alarm_events ++ shot_events}
  end

  defp maybe_shoot(state, port, players, fort) do
    t = state.time

    candidates =
      for p <- players,
          p.invuln_until <= t,
          t - Map.fetch!(fort.seen, p.id) >= @warn_ms,
          do: p

    if fort.cooldown_until > t or candidates == [] do
      {state, fort, []}
    else
      target = Enum.min_by(candidates, &dist(port.x, port.y, &1.x, &1.y))
      first? = Map.get(fort.shots, target.id, 0) == 0
      {vx, vy} = fire_velocity(port, target, first?)

      ball = %{
        id: state.next_id,
        owner: "fort:" <> port.id,
        owner_kind: :fort,
        x: port.x,
        y: port.y,
        vx: vx,
        vy: vy,
        ttl: @ball_ttl,
        dmg: @ball_dmg,
        r: 0.08,
        ammo: :ball
      }

      state = %{state | balls: [ball | state.balls], next_id: state.next_id + 1}

      fort = %{
        fort
        | cooldown_until: t + cooldown(state, port),
          shots: Map.update(fort.shots, target.id, 1, &(&1 + 1))
      }

      {state, fort, [{:fire, ball.owner, :fort, port.x, port.y}]}
    end
  end

  # Im Angriff lädt das Fort schneller nach
  defp cooldown(state, port),
    do: if(Map.has_key?(state.assaults, port.id), do: Conquest.cooldown_ms(), else: @cooldown_ms)

  # Zwei Jäger der Nation des Hafens 10–20 WE um den Spieler
  defp alarm(state, port, player) do
    nation = State.port_nation(state, port)

    Enum.reduce(1..@alarm_hunters, state, fn _, st ->
      others = for {_, s} <- st.ships, s.alive?, do: {s.x, s.y}

      case Spawn.pick_around(st.seed, others, {player.x, player.y}, 10.0, 20.0, st.rng) do
        nil ->
          st

        {x, y, heading, rng} ->
          State.add_npc(
            %{st | rng: rng},
            :hunter,
            "Jäger #{st.next_id}",
            x,
            y,
            heading,
            0,
            nation
          )
      end
    end)
  end

  defp dist(ax, ay, bx, by), do: :math.sqrt((ax - bx) * (ax - bx) + (ay - by) * (ay - by))
end
