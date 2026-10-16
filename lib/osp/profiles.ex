defmodule Osp.Profiles do
  @moduledoc """
  Speicher für Spielstände (`Osp.Profile`) je Spieler-Token.

  Alles liegt im Speicher (schnell) und wird zusätzlich in **eine JSON-Datei** geschrieben
  (`profiles.json` im Datenverzeichnis, siehe `OSP_DATA_DIR`): höchstens alle 5 s, wenn sich
  etwas geändert hat, sowie beim geordneten Beenden. Geschrieben wird atomar (temporäre Datei, dann
  umbenennen), die vorherige Fassung bleibt als `profiles.json.bak` liegen. Ohne Datenverzeichnis
  (Tests, Entwicklung ohne Volume) bleibt alles im Speicher.

  Für ein paar hundert Spieler reicht das völlig; bei deutlich mehr wäre eine Datenbank der nächste
  Schritt (die Schnittstelle `get/1` und `put/2` bliebe gleich).
  """

  use GenServer

  require Logger

  alias Osp.Profile

  @flush_ms 5_000
  @file_name "profiles.json"

  # --- API ----------------------------------------------------------------------

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Gespeicherter Stand zum Token oder `nil`."
  def get(id, server \\ __MODULE__), do: GenServer.call(server, {:get, id})

  @doc "Stand speichern (asynchron; wird bald auf die Platte geschrieben)."
  def put(id, profile, server \\ __MODULE__), do: GenServer.cast(server, {:put, id, profile})

  @doc "Sofort auf die Platte schreiben (Tests, Backup)."
  def flush(server \\ __MODULE__), do: GenServer.call(server, :flush)

  @doc "Anzahl gespeicherter Spieler."
  def count(server \\ __MODULE__), do: GenServer.call(server, :count)

  # --- Server -------------------------------------------------------------------

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    dir = Keyword.get(opts, :dir, Application.get_env(:osp, :data_dir))
    path = dir && Path.join(dir, @file_name)

    state = %{path: path, profiles: load(path), dirty?: false}
    Process.send_after(self(), :flush, @flush_ms)
    {:ok, state}
  end

  @impl true
  def handle_call({:get, id}, _from, state), do: {:reply, Map.get(state.profiles, id), state}
  def handle_call(:count, _from, state), do: {:reply, map_size(state.profiles), state}
  def handle_call(:flush, _from, state), do: {:reply, :ok, write(state)}

  @impl true
  def handle_cast({:put, id, profile}, state) do
    profile = Profile.decode(profile)

    if Map.get(state.profiles, id) == profile,
      do: {:noreply, state},
      else: {:noreply, %{state | profiles: Map.put(state.profiles, id, profile), dirty?: true}}
  end

  @impl true
  def handle_info(:flush, state) do
    Process.send_after(self(), :flush, @flush_ms)
    {:noreply, write(state)}
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state), do: write(state)

  # --- Datei ---------------------------------------------------------------------

  defp load(nil), do: %{}

  defp load(path) do
    with {:ok, bin} <- File.read(path),
         {:ok, %{"profiles" => %{} = map}} <- Jason.decode(bin) do
      Map.new(map, fn {id, p} -> {id, Profile.decode(p)} end)
    else
      {:error, :enoent} ->
        %{}

      other ->
        Logger.error(
          "Profile konnten nicht geladen werden (#{inspect(other)}); starte leer. " <>
            "Sicherung: #{path}.bak"
        )

        %{}
    end
  end

  defp write(%{path: nil} = state), do: %{state | dirty?: false}
  defp write(%{dirty?: false} = state), do: state

  defp write(%{path: path} = state) do
    File.mkdir_p!(Path.dirname(path))
    tmp = path <> ".tmp"
    json = Jason.encode!(%{"version" => 1, "profiles" => state.profiles})

    with :ok <- File.write(tmp, json),
         _ <- File.cp(path, path <> ".bak"),
         :ok <- File.rename(tmp, path) do
      %{state | dirty?: false}
    else
      error ->
        Logger.error("Profile konnten nicht gespeichert werden: #{inspect(error)}")
        state
    end
  end
end
