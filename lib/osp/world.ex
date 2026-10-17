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
  Gibt `{:ok, info}` mit `%{id, chunk, resolution, land}` zurück. `opts[:nation]` ist die gewählte
  Heimatnation für einen Spieler ohne gespeicherte Nation (eine vorhandene bleibt); ohne Angabe und
  ohne Profil gilt eine Nation aus dem Token-Hash (Tests, Bots).
  """
  def join(world, id, name, pid \\ self(), opts \\ []),
    do: GenServer.call(via(world), {:join, id, name, pid, opts})

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

  @doc "Segelstufe wählen: `:reefed`, `:full` oder `:studding`."
  def sail(world, id, mode), do: GenServer.cast(via(world), {:sail, id, mode})

  @doc """
  Quest-Aktion: `{:accept, angebots_id}`, `:turn_in` oder `{:abandon, quest_id}`. Antwort (Hafen-Ansicht
  oder Fehler) kommt als `{:osp_shop, map}`.
  """
  def quest(world, id, op), do: GenServer.cast(via(world), {:quest, id, op})

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
      max_players: Keyword.get(opts, :max_players, 60),
      saved: %{},
      ticks: 0,
      tick_ms: Keyword.get(opts, :tick_ms, @tick_ms)
    }

    Process.send_after(self(), :tick, state.tick_ms)
    {:ok, state}
  end

  @impl true
  def handle_call({:join, id, name, pid, opts}, _from, state) do
    # Neue Spieler nur bis zur Obergrenze; wer schon in der Welt ist (Wiederverbinden), darf immer
    if Map.has_key?(state.sim.ships, id) or State.player_count(state.sim) < state.max_players do
      {state, info} = do_join(state, id, name, pid, opts)
      state = save_ship(state, id)
      # Wer angedockt wiederkommt (Verbindung abgerissen), bekommt die Hafen-Ansicht erneut
      if view = State.shop_view(state.sim, id), do: reply_shop(state, id, view)
      {:reply, {:ok, info}, state}
    else
      {:reply, {:error, :full}, state}
    end
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

  def handle_cast({:sail, id, mode}, state),
    do: {:noreply, %{state | sim: State.set_sail(state.sim, id, mode)}}

  def handle_cast({:quest, id, {:accept, offer_id}}, state) do
    {sim, result} = State.accept_quest(state.sim, id, offer_id)
    state = %{state | sim: sim}

    case result do
      {:ok, view} -> reply_shop(state, id, view)
      {:error, reason} -> reply_shop(state, id, error_view(sim, id, reason))
    end

    {:noreply, state}
  end

  def handle_cast({:quest, id, :turn_in}, state) do
    {sim, result} = State.turn_in(state.sim, id)
    state = %{state | sim: sim}

    case result do
      {:ok, view, events} ->
        reply_shop(state, id, view)
        {:noreply, %{state | pending: state.pending ++ events}}

      {:error, reason} ->
        reply_shop(state, id, error_view(sim, id, reason))
        {:noreply, state}
    end
  end

  def handle_cast({:quest, id, {:abandon, quest_id}}, state) do
    {sim, result} = State.abandon_quest(state.sim, id, quest_id)
    state = %{state | sim: sim}

    # Ist der Spieler angedockt, bekommt er die aktualisierte Ansicht
    with :ok <- result,
         view when view != nil <- State.shop_view(sim, id),
         do: reply_shop(state, id, view)

    {:noreply, state}
  end

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

  defp do_join(state, id, name, pid, opts) do
    state = detach(state, id)
    ref = Process.monitor(pid)
    profile = with_nation(Profiles.get(id), id, opts[:nation])
    sim = State.join(state.sim, id, name, profile)

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

    {state, info}
  end

  # Das Profil mit Heimatnation: eine gespeicherte bleibt, sonst die gewählte, sonst aus dem Token-Hash
  defp with_nation(profile, id, wanted) do
    decoded = Profile.decode(profile)

    if decoded["nation"] do
      decoded
    else
      nation = wanted || Enum.at(Osp.Nations.all(), :erlang.phash2({:nation, id}, 5))

      decoded
      |> Map.put("nation", Atom.to_string(nation))
      |> Map.put(
        "rep",
        Map.new(Osp.Reputation.start(nation), fn {n, v} -> {Atom.to_string(n), v} end)
      )
    end
  end

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

  # Aktuelle Hafen-Ansicht (oder „geschlossen") mit dem Fehlergrund
  defp error_view(sim, id, reason) do
    view = State.shop_view(sim, id) || %{t: "shop", open: false}
    Map.put(view, :error, Atom.to_string(reason))
  end

  defp reply_shop(state, id, view) do
    if pid = state.pids[id], do: send(pid, {:osp_shop, view})
    :ok
  end

  defp send_snapshots(%{pids: pids}, _events) when map_size(pids) == 0, do: :ok

  defp send_snapshots(state, events) do
    # gemeinsame Teile einmal für alle berechnen, dann je Spieler nur nach Entfernung filtern
    ctx = State.snapshot_context(state.sim, events)

    for {id, pid} <- state.pids, snap = State.snapshot_for(state.sim, id, ctx), snap != nil do
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
