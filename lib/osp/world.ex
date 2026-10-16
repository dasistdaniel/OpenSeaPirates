defmodule Osp.World do
  @moduledoc """
  Eine Spielwelt (ein Prozess): Hülle um den reinen Zustand `Osp.State`. Rechnet im festen Takt
  (20 Hz), verwaltet die Verbindungen und schickt jedem Spieler einen Schnappschuss mit allem in
  seiner Umgebung.

  Nachrichten an Spieler-Prozesse (meist das WebSocket):

    * `{:osp_snap, map}` – Schnappschuss, siehe `Osp.State.snapshot_for/3`

  Die Welt ist unendlich; das Gelände steckt im Seed (`Osp.Terrain`). Verbindet ein Spieler neu,
  startet er nahe anderer Schiffe (`Osp.Spawn`). Bricht die Verbindung ab, bleibt das Schiff noch
  10 s in der Welt (kein Entkommen per Disconnect).
  """

  use GenServer, restart: :temporary

  alias Osp.{Profile, Profiles, State, Terrain}

  @registry Osp.WorldRegistry
  @tick_ms 50

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

  @doc "Breitseite: `:left` (Q) oder `:right` (E)."
  def fire(world, id, side), do: GenServer.cast(via(world), {:fire, id, side})

  @doc "Andocken (Taste F nahe einem Hafen): Antwort kommt als `{:osp_shop, map}` an den Spieler."
  def dock(world, id), do: GenServer.cast(via(world), {:dock, id})

  @doc "Ablegen."
  def undock(world, id), do: GenServer.cast(via(world), {:undock, id})

  @doc """
  Hafengeschäft (`Osp.State.shop/3`); die neue Hafen-Ansicht (oder ein Fehler) kommt als
  `{:osp_shop, map}`.
  """
  def shop(world, id, action), do: GenServer.cast(via(world), {:shop, id, action})

  @doc "Munitionsart wählen: `:ball`, `:chain` oder `:fire`."
  def ammo(world, id, kind), do: GenServer.cast(via(world), {:ammo, id, kind})

  @doc "Spieler verlässt die Welt sofort."
  def leave(world, id), do: GenServer.cast(via(world), {:leave, id})

  @doc "Gelände-Seed der Welt."
  def seed(world), do: GenServer.call(via(world), :seed)

  @doc "Reiner Weltzustand (`Osp.State`), für Tests."
  def state(world), do: GenServer.call(via(world), :state)

  # --- Server -------------------------------------------------------------------

  @impl true
  def init(opts) do
    seed = opts[:seed] || :rand.uniform(1_000_000_000)

    state = %{
      id: Keyword.fetch!(opts, :id),
      sim:
        State.new(seed, Keyword.get(opts, :bots, 0),
          director?: Keyword.get(opts, :director, false)
        ),
      pids: %{},
      refs: %{},
      pending: [],
      saved: %{},
      ticks: 0,
      tick_ms: Keyword.get(opts, :tick_ms, @tick_ms)
    }

    Process.send_after(self(), :tick, state.tick_ms)
    {:ok, state}
  end

  @impl true
  def handle_call({:join, id, name, pid}, _from, state) do
    state = detach(state, id)
    ref = Process.monitor(pid)
    sim = State.join(state.sim, id, name, Profiles.get(id))

    state = %{
      state
      | sim: sim,
        pids: Map.put(state.pids, id, pid),
        refs: Map.put(state.refs, ref, id)
    }

    info = %{
      id: id,
      chunk: Terrain.chunk_size(),
      resolution: Terrain.resolution(),
      land: Terrain.land_level()
    }

    {:reply, {:ok, info}, state}
  end

  def handle_call(:seed, _from, state), do: {:reply, state.sim.seed, state}
  def handle_call(:state, _from, state), do: {:reply, state.sim, state}

  @impl true
  def handle_cast({:input, id, keys}, state),
    do: {:noreply, %{state | sim: State.set_input(state.sim, id, keys)}}

  def handle_cast({:fire, id, side}, state) do
    {sim, events} = State.fire(state.sim, id, side)
    {:noreply, %{state | sim: sim, pending: state.pending ++ events}}
  end

  def handle_cast({:dock, id}, state) do
    {sim, result} = State.dock(state.sim, id)
    state = %{state | sim: sim}

    case result do
      :ok ->
        reply_shop(state, id, State.shop_view(sim, id))

      {:error, reason} ->
        reply_shop(state, id, %{t: "shop", open: false, error: Atom.to_string(reason)})
    end

    {:noreply, state}
  end

  def handle_cast({:undock, id}, state) do
    {sim, _} = State.undock(state.sim, id)
    reply_shop(state, id, %{t: "shop", open: false})
    {:noreply, %{state | sim: sim}}
  end

  def handle_cast({:shop, id, action}, state) do
    {sim, result} = State.shop(state.sim, id, action)

    case result do
      {:ok, view} ->
        reply_shop(state, id, view)

      {:error, reason} ->
        view = State.shop_view(sim, id) || %{t: "shop", open: false}
        reply_shop(state, id, Map.put(view, :error, Atom.to_string(reason)))
    end

    {:noreply, %{state | sim: sim}}
  end

  def handle_cast({:ammo, id, kind}, state),
    do: {:noreply, %{state | sim: State.select_ammo(state.sim, id, kind)}}

  def handle_cast({:leave, id}, state) do
    state = state |> save_ship(id) |> detach(id)
    {:noreply, %{state | sim: State.leave(state.sim, id), pids: Map.delete(state.pids, id)}}
  end

  @impl true
  def handle_info(:tick, state) do
    {sim, events} = State.tick(state.sim, state.tick_ms)
    state = autosave(state, state.sim, sim)
    state = %{state | sim: sim}
    # Ereignisse aus Eingaben (Feuer, Powerup) gehen mit dem nächsten Takt an alle
    send_snapshots(state, state.pending ++ events)
    Process.send_after(self(), :tick, state.tick_ms)
    {:noreply, %{state | pending: []}}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.pop(state.refs, ref) do
      {nil, _} ->
        {:noreply, state}

      {id, refs} ->
        state = save_ship(state, id)

        {:noreply,
         %{
           state
           | refs: refs,
             pids: Map.delete(state.pids, id),
             sim: State.mark_gone(state.sim, id)
         }}
    end
  end

  def handle_info(_other, state), do: {:noreply, state}

  # --- Spielstände speichern ---------------------------------------------------------

  # Alle 5 s geänderte Spielstände sichern; verschwundene Spieler (Schonfrist abgelaufen) ein
  # letztes Mal mit ihrem Stand von vor dem Entfernen.
  defp autosave(state, old_sim, new_sim) do
    gone =
      for {id, s} <- old_sim.ships, s.kind == :player, not Map.has_key?(new_sim.ships, id), do: s

    state = Enum.reduce(gone, state, &save(&2, &1))
    ticks = state.ticks + 1

    if rem(ticks, 100) == 0 do
      players = for {_, s} <- new_sim.ships, s.kind == :player, do: s
      %{Enum.reduce(players, state, &save(&2, &1)) | ticks: ticks}
    else
      %{state | ticks: ticks}
    end
  end

  defp save_ship(state, id) do
    case state.sim.ships[id] do
      %{kind: :player} = ship -> save(state, ship)
      _ -> state
    end
  end

  # Nur schreiben, wenn sich der Stand seit dem letzten Speichern geändert hat
  defp save(state, ship) do
    profile = Profile.from_ship(ship)

    if state.saved[ship.id] == profile do
      state
    else
      Profiles.put(ship.id, profile)
      %{state | saved: Map.put(state.saved, ship.id, profile)}
    end
  end

  # --- Hilfen ----------------------------------------------------------------------

  defp reply_shop(state, id, view) do
    if pid = state.pids[id], do: send(pid, {:osp_shop, view})
    :ok
  end

  defp send_snapshots(%{pids: pids}, _events) when map_size(pids) == 0, do: :ok

  defp send_snapshots(state, events) do
    for {id, pid} <- state.pids, snap = State.snapshot_for(state.sim, id, events), snap != nil do
      send(pid, {:osp_snap, snap})
    end

    :ok
  end

  defp detach(state, id) do
    {keep, drop} = Enum.split_with(state.refs, fn {_ref, rid} -> rid != id end)
    for {ref, _} <- drop, do: Process.demonitor(ref, [:flush])
    %{state | refs: Map.new(keep)}
  end
end
