defmodule Osp.Conquest do
  @moduledoc """
  Eroberung von Häfen (rein, arbeitet auf `Osp.State`).

  Spieler mit **fremder Heimatnation** können einen Hafen angreifen. Der **Angriff** beginnt mit der
  ersten Breitseite (oder dem Versenken eines Verteidigers) innerhalb von `radius_hit/0` um den Anker
  eines ungeschützten Hafens (`hostile_act/4`). Solange er läuft:

    * schießt das Fort auf alle Fremden in Reichweite, schneller als sonst (`Osp.Fort`),
    * sind die Angreifer in der Schutzzone ungeschützt (`Osp.State.safe_at?/4`),
    * erscheinen alle 45 s zwei Verteidiger (Jäger der Besitzer-Nation, höchstens 6),
    * steigt der **Fortschritt** um 1,5 % je Sekunde und Angreifer (lebende, nicht angedockte Spieler mit
      fremder Heimatnation in `radius_zone/0`), **aber nur**, solange kein Verteidiger lebt; ohne Angreifer
      sinkt er um 0,5 % je Sekunde.

  Bei 100 % wechselt der Hafen zur Nation, die unter den Angreifern in der Zone die meisten stellt
  (Gleichstand: die der ersten Angriffshandlung); jeder Angreifer in der Zone bekommt Gold und Ruf bei
  seiner Heimatnation. Danach gilt `protection_ms/0` (Wanduhr) Schutz. Der Rückfall nicht gehaltener
  Häfen steht in `reversions/4`. Siehe `docs/superpowers/plans/2026-10-17-eroberung-baustein-4.md`.

  Angriffszustand: `state.assaults :: %{hafen_id => %{progress, last_act, wave_at, first_nation}}`.
  Ereignisse: `{:assault, port_id, owner, x, y}`, `{:captured, port_id, new_owner, old_owner, wall_ms, x, y}`,
  `{:assault_end, port_id, x, y}` (dazu die `{:rep, ...}` der Belohnung).
  """

  alias Osp.{Nations, Ports, Spawn, State}

  @radius_hit 8.0
  @radius_zone 6.0
  @radius_defenders 40.0
  @gain_per_s 1.5
  @drain_per_s 0.5
  @wave_ms 45_000
  @wave_size 2
  @max_defenders 6
  @protection_ms 1_200_000
  @idle_end_ms 60_000
  @reward_gold 300
  @reward_rep 10
  @cooldown_ms 2_000

  def radius_hit, do: @radius_hit
  def radius_zone, do: @radius_zone
  def radius_defenders, do: @radius_defenders
  def protection_ms, do: @protection_ms
  def cooldown_ms, do: @cooldown_ms

  @doc "Läuft für den Hafen gerade die Schutzzeit nach einer Eroberung? (Wanduhr, nie negativ)"
  @spec protected?(State.t(), String.t()) :: boolean()
  def protected?(state, port_id) do
    case Map.get(state.captured_at, port_id) do
      nil -> false
      since -> max(state.wall_ms - since, 0) < @protection_ms
    end
  end

  @doc "Läuft ein Angriff auf diesen Hafen? `nil` oder der Zustand."
  def assault_on(state, port_id), do: Map.get(state.assaults, port_id)

  @doc "Ist das Schiff ein möglicher Angreifer dieses Hafens? Lebender, nicht angedockter Spieler mit fremder Heimatnation."
  @spec attacker?(State.t(), map(), map()) :: boolean()
  def attacker?(state, ship, port) do
    ship.kind == :player and ship.alive? and ship.docked == nil and ship.nation != nil and
      ship.nation != State.port_nation(state, port)
  end

  @doc """
  Angriffshandlung eines Spielers an `(x, y)` (Breitseite, Abschuss eines Verteidigers): startet einen
  Angriff auf jeden ungeschützten Hafen mit fremder Nation im Umkreis von `radius_hit/0` oder hält einen
  laufenden wach. `{state, events}`.
  """
  @spec hostile_act(State.t(), term(), number(), number()) :: {State.t(), list()}
  def hostile_act(state, ship_id, x, y) do
    case state.ships[ship_id] do
      %{kind: :player} = ship ->
        state.seed
        |> Ports.near(x, y, @radius_hit)
        |> Enum.reduce({state, []}, fn port, {st, ev} -> act_on(st, ev, ship, port) end)

      _ ->
        {state, []}
    end
  end

  defp act_on(state, events, ship, port) do
    cond do
      protected?(state, port.id) or not attacker?(state, ship, port) ->
        {state, events}

      Map.has_key?(state.assaults, port.id) ->
        {put_in(state.assaults[port.id].last_act, state.time), events}

      true ->
        assault = %{
          progress: 0.0,
          last_act: state.time,
          wave_at: state.time,
          first_nation: ship.nation
        }

        owner = State.port_nation(state, port)

        {%{state | assaults: Map.put(state.assaults, port.id, assault)},
         events ++ [{:assault, port.id, owner, port.x, port.y}]}
    end
  end

  @doc "Ein Zeitschritt von `ms` für alle laufenden Angriffe; `{state, events}`."
  @spec step(State.t(), non_neg_integer()) :: {State.t(), list()}
  def step(%{assaults: assaults} = state, _ms) when map_size(assaults) == 0, do: {state, []}

  def step(state, ms) do
    Enum.reduce(Map.keys(state.assaults), {state, []}, fn id, {st, ev} ->
      {st, more} = port_step(st, id, ms)
      {st, ev ++ more}
    end)
  end

  defp port_step(state, port_id, ms) do
    assault = state.assaults[port_id]

    case Ports.by_id(state.seed, port_id) do
      nil ->
        {%{state | assaults: Map.delete(state.assaults, port_id)}, []}

      port ->
        if protected?(state, port_id) do
          {%{state | assaults: Map.delete(state.assaults, port_id)}, []}
        else
          advance(state, port, assault, ms)
        end
    end
  end

  defp advance(state, port, assault, ms) do
    owner = State.port_nation(state, port)
    attackers = attackers_in_zone(state, port)
    defenders = defenders(state, port, owner)
    dt = ms / 1000

    progress =
      cond do
        attackers != [] and defenders == 0 ->
          assault.progress + @gain_per_s * length(attackers) * dt

        attackers == [] ->
          assault.progress - @drain_per_s * dt

        true ->
          assault.progress
      end
      |> max(0.0)
      |> min(100.0)

    assault = %{assault | progress: progress}
    state = %{state | assaults: Map.put(state.assaults, port.id, assault)}
    {state, assault} = maybe_wave(state, port, owner, attackers, defenders, assault)

    cond do
      progress >= 100.0 ->
        capture(state, port, assault, attackers, owner)

      progress <= 0.0 and state.time - assault.last_act >= @idle_end_ms ->
        end_assault(state, port)

      true ->
        {put_assault(state, port.id, assault), []}
    end
  end

  defp put_assault(state, port_id, assault),
    do: %{state | assaults: Map.put(state.assaults, port_id, assault)}

  defp end_assault(state, port),
    do:
      {%{state | assaults: Map.delete(state.assaults, port.id)},
       [{:assault_end, port.id, port.x, port.y}]}

  # Alle 45 s zwei Verteidiger, solange weniger als `@max_defenders` leben
  defp maybe_wave(state, port, owner, attackers, defenders, assault) do
    if state.time >= assault.wave_at do
      room = @max_defenders - defenders
      state = spawn_defenders(state, port, owner, attackers, min(@wave_size, max(room, 0)))
      {state, %{assault | wave_at: state.time + @wave_ms}}
    else
      {state, assault}
    end
  end

  defp spawn_defenders(state, _port, _owner, _attackers, 0), do: state

  defp spawn_defenders(state, port, owner, attackers, n) do
    center = centroid(attackers, port)

    Enum.reduce(1..n, state, fn _, st ->
      others = for {_, s} <- st.ships, s.alive?, do: {s.x, s.y}

      case Spawn.pick_around(st.seed, others, center, 10.0, 20.0, st.rng) do
        nil ->
          st

        {x, y, heading, rng} ->
          State.add_npc(%{st | rng: rng}, :hunter, "Wache #{st.next_id}", x, y, heading, 0, owner)
      end
    end)
  end

  defp centroid([], port), do: {port.x, port.y}

  defp centroid(attackers, _port) do
    n = length(attackers)
    {Enum.sum(Enum.map(attackers, & &1.x)) / n, Enum.sum(Enum.map(attackers, & &1.y)) / n}
  end

  defp attackers_in_zone(state, port) do
    for {_id, s} <- state.ships,
        attacker?(state, s, port),
        dist(s.x, s.y, port.x, port.y) <= @radius_zone,
        do: s
  end

  defp defenders(state, port, owner) do
    Enum.count(state.ships, fn {_id, s} ->
      s.kind == :hunter and s.alive? and s.nation == owner and
        dist(s.x, s.y, port.x, port.y) <= @radius_defenders
    end)
  end

  # Der Hafen wechselt zum Gewinner; Belohnung für alle Angreifer in der Zone
  defp capture(state, port, assault, attackers, old_owner) do
    winner = winner(attackers, assault.first_nation)

    {owners, captured_at} =
      if winner == Nations.base_of_port(state.seed, port),
        do: {Map.delete(state.owners, port.id), Map.delete(state.captured_at, port.id)},
        else:
          {Map.put(state.owners, port.id, winner),
           Map.put(state.captured_at, port.id, state.wall_ms)}

    state = %{
      state
      | owners: owners,
        captured_at: captured_at,
        assaults: Map.delete(state.assaults, port.id)
    }

    {state, rep_events} =
      Enum.reduce(attackers, {state, []}, fn a, {st, ev} ->
        st = State.update_ship(st, a.id, &%{&1 | gold: &1.gold + @reward_gold})
        {st, more} = State.add_rep(st, a.id, a.nation, @reward_rep)
        {st, ev ++ more}
      end)

    {state, [{:captured, port.id, winner, old_owner, state.wall_ms, port.x, port.y} | rep_events]}
  end

  # Die Nation mit den meisten Angreifern; bei Gleichstand die der ersten Angriffshandlung, sonst die
  # nach der festen Reihenfolge der Nationen
  defp winner(attackers, first) do
    counts = Enum.frequencies_by(attackers, & &1.nation)
    best = counts |> Map.values() |> Enum.max(fn -> 0 end)
    leaders = for {n, c} <- counts, c == best, do: n

    cond do
      first in leaders -> first
      leaders != [] -> Enum.find(Nations.all(), &(&1 in leaders))
      true -> first
    end
  end

  defp dist(ax, ay, bx, by), do: :math.sqrt((ax - bx) * (ax - bx) + (ay - by) * (ay - by))
end
