defmodule Osp.World do
  @moduledoc """
  Eine Spielwelt (ein Prozess): hält alle Schiffe, rechnet im festen Takt (20 Hz) und schickt
  jedem verbundenen Spieler einen Schnappschuss mit den Schiffen in seiner Umgebung.

  Nachrichten an Spieler-Prozesse (meist das WebSocket):

    * `{:osp_snap, map}` – Schnappschuss:
      `%{t: "snap", time, w, wi, you, ships: [%{i, n, c, x, y, h, v}]}` (Zahlen gerundet)

  Die Welt ist unendlich; das Gelände steckt im Seed (`Osp.Terrain`) und wird nicht gehalten.
  Verbindet ein Spieler neu, startet er nahe anderer Spieler (`Osp.Spawn`). Bricht die Verbindung
  ab, bleibt das Schiff noch `@grace_ms` in der Welt (kein Verschwinden per Disconnect).
  """

  use GenServer, restart: :temporary

  alias Osp.{Sailing, Spawn, Terrain, Wander}

  @registry Osp.WorldRegistry
  @tick_ms 50
  @step_ms 25
  @aoi 45.0
  @wind_every_ms 30_000
  @grace_ms 10_000
  @colors 6

  # --- API ----------------------------------------------------------------------

  def start_link(opts) do
    id = Keyword.fetch!(opts, :id)
    GenServer.start_link(__MODULE__, opts, name: via(id))
  end

  @doc "Startet eine Welt unter dem Welt-Supervisor."
  def start(opts), do: DynamicSupervisor.start_child(Osp.WorldSupervisor, {__MODULE__, opts})

  def via(id), do: {:via, Registry, {@registry, id}}
  def alive?(id), do: Registry.lookup(@registry, id) != []

  @doc """
  Spieler tritt bei (oder verbindet sich neu). `pid` bekommt die Schnappschüsse.
  Gibt `{:ok, info}` mit `%{id, chunk, resolution, land}` zurück.
  """
  def join(world, id, name, pid \\ self()), do: GenServer.call(via(world), {:join, id, name, pid})

  @doc "Tastenzustand setzen: `%{up?: bool, left?: bool, right?: bool}`."
  def input(world, id, keys), do: GenServer.cast(via(world), {:input, id, keys})

  @doc "Spieler verlässt die Welt sofort."
  def leave(world, id), do: GenServer.cast(via(world), {:leave, id})

  @doc "Gelände-Seed der Welt."
  def seed(world), do: GenServer.call(via(world), :seed)

  @doc "Interner Zustand (Tests)."
  def state(world), do: GenServer.call(via(world), :state)

  # --- Server -------------------------------------------------------------------

  @impl true
  def init(opts) do
    seed = opts[:seed] || :rand.uniform(1_000_000_000)
    rng = :rand.seed_s(:exsss, seed)
    {dir, rng} = :rand.uniform_s(6, rng)

    state = %{
      id: Keyword.fetch!(opts, :id),
      seed: seed,
      time: 0,
      acc: 0,
      ships: %{},
      pids: %{},
      refs: %{},
      bots: %{},
      wind: dir - 1,
      wind_at: @wind_every_ms,
      rng: rng,
      tick_ms: Keyword.get(opts, :tick_ms, @tick_ms)
    }

    state = Enum.reduce(1..max(Keyword.get(opts, :bots, 0), 0)//1, state, &add_bot(&2, &1))
    Process.send_after(self(), :tick, state.tick_ms)
    {:ok, state}
  end

  @impl true
  def handle_call({:join, id, name, pid}, _from, state) do
    state = detach(state, id)
    ref = Process.monitor(pid)

    state =
      if Map.has_key?(state.ships, id) do
        # Wiederverbinden: Schiff bleibt wo es ist
        update_in(state.ships[id], &%{&1 | name: name, gone_at: nil})
      else
        {x, y, heading, rng} = pick_spawn(state)
        ship = new_ship(id, name, x, y, heading)
        %{state | ships: Map.put(state.ships, id, ship), rng: rng}
      end

    state = %{state | pids: Map.put(state.pids, id, pid), refs: Map.put(state.refs, ref, id)}

    info = %{
      id: id,
      chunk: Terrain.chunk_size(),
      resolution: Terrain.resolution(),
      land: Terrain.land_level()
    }

    {:reply, {:ok, info}, state}
  end

  def handle_call(:seed, _from, state), do: {:reply, state.seed, state}
  def handle_call(:state, _from, state), do: {:reply, state, state}

  @impl true
  def handle_cast({:input, id, keys}, state) do
    case state.ships do
      %{^id => ship} ->
        keys = %{
          up?: keys[:up?] == true,
          left?: keys[:left?] == true,
          right?: keys[:right?] == true
        }

        {:noreply, %{state | ships: Map.put(state.ships, id, %{ship | input: keys})}}

      _ ->
        {:noreply, state}
    end
  end

  def handle_cast({:leave, id}, state), do: {:noreply, remove(state, id)}

  @impl true
  def handle_info(:tick, state) do
    state = advance(state, state.tick_ms)
    send_snapshots(state)
    Process.send_after(self(), :tick, state.tick_ms)
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.pop(state.refs, ref) do
      {nil, _} ->
        {:noreply, state}

      {id, refs} ->
        state = %{state | refs: refs, pids: Map.delete(state.pids, id)}

        # Schiff bleibt noch kurz im Wasser (Schutz vor "Disconnect-Flucht"), ohne Eingabe
        ships =
          case state.ships do
            %{^id => ship} ->
              Map.put(state.ships, id, %{ship | input: idle(), gone_at: state.time})

            ships ->
              ships
          end

        {:noreply, %{state | ships: ships}}
    end
  end

  def handle_info(_other, state), do: {:noreply, state}

  # --- Simulation ---------------------------------------------------------------

  defp advance(state, dt_ms) do
    total = state.acc + dt_ms
    steps = div(total, @step_ms)
    state = %{state | acc: rem(total, @step_ms)}
    Enum.reduce(1..steps//1, state, fn _, s -> step(s, @step_ms) end)
  end

  defp step(state, ms) do
    state = %{state | time: state.time + ms}
    state = turn_wind(state)
    state = think_bots(state)
    solid? = fn x, y -> Terrain.land?(state.seed, x, y) end
    wind = Sailing.wind_angle(state.wind)

    ships =
      Map.new(state.ships, fn {id, ship} ->
        moved = Sailing.step(ship, ship.input, ms / 1000, wind, solid?)
        {id, Map.merge(ship, Map.take(moved, [:x, :y, :heading, :speed]))}
      end)

    expire(%{state | ships: ships})
  end

  defp turn_wind(%{time: t, wind_at: at} = state) when t >= at,
    do: %{state | wind: Integer.mod(state.wind - 1, 6), wind_at: at + @wind_every_ms}

  defp turn_wind(state), do: state

  # Bots denken alle 200 ms
  defp think_bots(%{time: t} = state) when rem(t, 200) != 0, do: state

  defp think_bots(state) do
    solid? = fn x, y -> Terrain.land?(state.seed, x, y) end

    Enum.reduce(Map.keys(state.bots), state, fn id, acc ->
      ship = acc.ships[id]
      {keys, target, rng} = Wander.think(ship, acc.bots[id], solid?, acc.rng)

      %{
        acc
        | ships: Map.put(acc.ships, id, %{ship | input: keys}),
          bots: Map.put(acc.bots, id, target),
          rng: rng
      }
    end)
  end

  # Getrennte Spieler nach der Schonfrist entfernen
  defp expire(state) do
    gone =
      for {id, %{gone_at: at}} <- state.ships, at != nil, state.time - at >= @grace_ms, do: id

    Enum.reduce(gone, state, &remove(&2, &1))
  end

  # --- Schiffe, Spawn, Bots -------------------------------------------------------

  defp new_ship(id, name, x, y, heading) do
    %{
      id: id,
      name: name,
      color: :erlang.phash2(id, @colors),
      x: x,
      y: y,
      heading: heading,
      speed: 0.0,
      input: idle(),
      gone_at: nil
    }
  end

  defp idle, do: %{up?: false, left?: false, right?: false}

  defp pick_spawn(state) do
    # Auch Bots zählen als Gegenüber: Neue Schiffe starten in der Nähe von irgendjemandem
    others = for {_, s} <- state.ships, do: {s.x, s.y}
    Spawn.pick(state.seed, others, others, state.rng)
  end

  defp add_bot(state, n) do
    id = "bot-#{n}"
    {x, y, heading, rng} = pick_spawn(state)
    ship = new_ship(id, "Bot #{n}", x, y, heading)

    %{
      state
      | ships: Map.put(state.ships, id, ship),
        bots: Map.put(state.bots, id, nil),
        rng: rng
    }
  end

  defp detach(state, id) do
    {refs, drop} = Enum.split_with(state.refs, fn {_ref, rid} -> rid != id end)
    for {ref, _} <- drop, do: Process.demonitor(ref, [:flush])
    %{state | refs: Map.new(refs)}
  end

  defp remove(state, id) do
    state = detach(state, id)
    %{state | ships: Map.delete(state.ships, id), pids: Map.delete(state.pids, id)}
  end

  # --- Schnappschüsse ------------------------------------------------------------

  defp send_snapshots(%{pids: pids} = state) when map_size(pids) == 0, do: state

  defp send_snapshots(state) do
    wind = Float.round(Sailing.wind_angle(state.wind), 3)
    wi = max(state.wind_at - state.time, 0)

    for {id, pid} <- state.pids, me = state.ships[id], me != nil do
      ships =
        for {_, s} <- state.ships, near?(me, s) do
          %{
            i: s.id,
            n: s.name,
            c: s.color,
            x: r2(s.x),
            y: r2(s.y),
            h: r2(s.heading),
            v: r2(s.speed)
          }
        end

      send(
        pid,
        {:osp_snap, %{t: "snap", time: state.time, w: wind, wi: wi, you: id, ships: ships}}
      )
    end

    state
  end

  defp near?(a, b), do: (a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y) <= @aoi * @aoi

  defp r2(x), do: Float.round(x * 1.0, 2)
end
