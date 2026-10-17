defmodule Osp.Territory do
  @moduledoc """
  Speicher der **eroberten Häfen**: nur die Abweichungen vom Ausgangszustand (`Osp.Nations.base_of_port/2`)
  werden gehalten, als `%{hafen_id => %{owner: atom, since: ms}}` (`since` = Wanduhrzeit der Eroberung,
  für Schutzzeit und Rückfall).

  Wie `Osp.Profiles`: alles im Speicher und in **einer JSON-Datei** (`territory.json` im Datenverzeichnis,
  siehe `OSP_DATA_DIR`), höchstens alle 5 s bei Änderung und beim Beenden, atomar mit `.bak`; eine
  kaputte Datei wird zu `.corrupt` umbenannt und die Sicherung geladen. Geladene Einträge werden streng
  geprüft (Hafen-ID-Muster, Nationsnamen, begrenzte Zeit), Unsinn wird verworfen. Ohne Datenverzeichnis
  (Tests, Entwicklung) bleibt alles im Speicher.
  """

  use GenServer

  require Logger

  alias Osp.Nations

  @flush_ms 5_000
  @file_name "territory.json"
  @id_re ~r/^port:-?\d{1,7},-?\d{1,7}$/
  # 1. Januar 2100 in ms: Obergrenze für gespeicherte Zeitpunkte
  @max_since 4_102_444_800_000

  # --- API ----------------------------------------------------------------------

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Alle eroberten Häfen: `%{hafen_id => %{owner: atom, since: ms}}`."
  def all(server \\ __MODULE__), do: GenServer.call(server, :all)

  @doc "Hafen gehört jetzt `owner` (seit `since` ms Wanduhr). Ungültige Eingaben werden ignoriert."
  def put(port_id, owner, since, server \\ __MODULE__),
    do: GenServer.cast(server, {:put, port_id, owner, since})

  @doc "Abweichung für den Hafen entfernen (er fällt an seine Ausgangsnation zurück)."
  def delete(port_id, server \\ __MODULE__), do: GenServer.cast(server, {:delete, port_id})

  @doc "Sofort auf die Platte schreiben (Tests, Beenden)."
  def flush(server \\ __MODULE__), do: GenServer.call(server, :flush)

  # --- Server -------------------------------------------------------------------

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    dir = Keyword.get(opts, :dir, Application.get_env(:osp, :data_dir))
    path = dir && Path.join(dir, @file_name)

    state = %{path: path, ports: load(path), dirty?: false}
    Process.send_after(self(), :flush, @flush_ms)
    {:ok, state}
  end

  @impl true
  def handle_call(:all, _from, state), do: {:reply, state.ports, state}
  def handle_call(:flush, _from, state), do: {:reply, :ok, write(state)}

  @impl true
  def handle_cast({:put, port_id, owner, since}, state) do
    case entry(port_id, owner_name(owner), since) do
      {:ok, id, value} ->
        if Map.get(state.ports, id) == value,
          do: {:noreply, state},
          else: {:noreply, %{state | ports: Map.put(state.ports, id, value), dirty?: true}}

      :error ->
        {:noreply, state}
    end
  end

  def handle_cast({:delete, port_id}, state) do
    if Map.has_key?(state.ports, port_id),
      do: {:noreply, %{state | ports: Map.delete(state.ports, port_id), dirty?: true}},
      else: {:noreply, state}
  end

  @impl true
  def handle_info(:flush, state) do
    Process.send_after(self(), :flush, @flush_ms)
    {:noreply, write(state)}
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state), do: write(state)

  # --- Prüfung -------------------------------------------------------------------

  defp owner_name(owner) when is_atom(owner) and owner != nil,
    do: if(owner in Nations.all(), do: Atom.to_string(owner), else: nil)

  defp owner_name(_other), do: nil

  # Ein Eintrag aus Cast oder Datei; `owner` kommt als String (Nationsname)
  defp entry(id, owner, since) when is_binary(id) and is_binary(owner) and is_number(since) do
    with true <- Regex.match?(@id_re, id),
         {:ok, nation} <- Nations.parse(owner) do
      {:ok, id, %{owner: nation, since: since |> round() |> max(0) |> min(@max_since)}}
    else
      _ -> :error
    end
  end

  defp entry(_id, _owner, _since), do: :error

  # --- Datei ---------------------------------------------------------------------

  defp load(nil), do: %{}

  # Erst die Hauptdatei, bei Fehlern die Sicherung (.bak); eine kaputte Hauptdatei wird nicht
  # überschrieben, sondern zu `.corrupt` umbenannt.
  defp load(path) do
    case read(path) do
      {:ok, ports} ->
        ports

      :missing ->
        case read(path <> ".bak") do
          {:ok, ports} -> ports
          _ -> %{}
        end

      {:error, reason} ->
        Logger.error(
          "Eroberungen in #{path} unlesbar (#{inspect(reason)}); versuche die Sicherung."
        )

        File.rename(path, path <> ".corrupt")

        case read(path <> ".bak") do
          {:ok, ports} ->
            Logger.warning("Eroberungen aus #{path}.bak wiederhergestellt.")
            ports

          _ ->
            %{}
        end
    end
  end

  defp read(path) do
    case File.read(path) do
      {:error, :enoent} ->
        :missing

      {:error, reason} ->
        {:error, reason}

      {:ok, bin} ->
        case Jason.decode(bin) do
          {:ok, %{"ports" => %{} = map}} -> {:ok, decode(map)}
          other -> {:error, other}
        end
    end
  end

  defp decode(map) do
    for {id, raw} <- map,
        %{} <- [raw],
        {:ok, key, value} <- [entry(id, raw["owner"], raw["since"])],
        into: %{},
        do: {key, value}
  end

  defp write(%{path: nil} = state), do: %{state | dirty?: false}
  defp write(%{dirty?: false} = state), do: state

  defp write(%{path: path} = state) do
    File.mkdir_p!(Path.dirname(path))
    tmp = path <> ".tmp"

    ports =
      Map.new(state.ports, fn {id, %{owner: owner, since: since}} ->
        {id, %{"owner" => Atom.to_string(owner), "since" => since}}
      end)

    json = Jason.encode!(%{"v" => 1, "ports" => ports})

    with :ok <- File.write(tmp, json),
         _ <- File.cp(path, path <> ".bak"),
         :ok <- File.rename(tmp, path) do
      %{state | dirty?: false}
    else
      error ->
        Logger.error("Eroberungen konnten nicht gespeichert werden: #{inspect(error)}")
        state
    end
  end
end
