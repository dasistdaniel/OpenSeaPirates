defmodule Osp.PortCache do
  @moduledoc """
  ETS-Cache für `Osp.Ports.in_chunk/3` (Ergebnis je `{seed, cx, cy}`). Gehört einem eigenen Prozess,
  damit die Tabelle so lange lebt wie die Anwendung. Lesen und Schreiben gehen direkt auf die Tabelle.
  """

  use GenServer

  @table __MODULE__
  @max 50_000

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  def get(key) do
    case :ets.lookup(@table, key) do
      [{^key, value}] -> {:ok, value}
      [] -> :miss
    end
  end

  def put(key, value) do
    # Notbremse gegen unbegrenztes Wachstum (die Welt ist unendlich)
    if :ets.info(@table, :size) > @max, do: :ets.delete_all_objects(@table)
    :ets.insert(@table, {key, value})
    :ok
  end

  @impl true
  def init(nil) do
    :ets.new(@table, [:named_table, :public, read_concurrency: true])
    {:ok, nil}
  end
end
