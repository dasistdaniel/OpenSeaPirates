defmodule Osp.Ports do
  @moduledoc """
  Häfen der Welt (deterministisch aus dem Seed, pro Chunk höchstens einer).

  Ein Hafen ist ein Ankerplatz im offenen Wasser an einer Küste: `%{id, name, x, y, land}` mit
  `land` = Richtung (Bogenmaß) zur nächsten Küste, dorthin zeigt der Steg. Rund um den Ankerplatz
  liegt eine **Schutzzone** (`safe_radius/0`): kein Schaden, Kanonen gesperrt, Kugeln verschwinden.
  Andocken geht innerhalb von `dock_radius/0`.

  Ergebnisse je Chunk werden im ETS-Cache (`Osp.PortCache`) gemerkt, damit Abfragen im Kampf billig
  bleiben; die Ergebnisse selbst hängen nur von Seed und Chunk ab.
  """

  alias Osp.{Spawn, Terrain}

  @chance 0.16
  @safe_radius 3.5
  @dock_radius 2.8
  @tries 40

  @names [
    "Tortuga",
    "Port Royal",
    "Nassau",
    "Havanna",
    "Cartagena",
    "Santiago",
    "Barbados",
    "Tobago",
    "Curaçao",
    "Antigua",
    "Santa Marta",
    "Maracaibo",
    "Veracruz",
    "Campeche",
    "Kingston",
    "Trinidad",
    "Montserrat",
    "Grenada",
    "Dominica",
    "Martinique",
    "Cayenne",
    "Belize",
    "Roatán",
    "Bluefields"
  ]

  def safe_radius, do: @safe_radius
  def dock_radius, do: @dock_radius

  @doc "Hafen im Chunk `{cx, cy}` oder `nil`."
  @spec in_chunk(integer(), integer(), integer()) :: map() | nil
  def in_chunk(seed, cx, cy) do
    key = {seed, cx, cy}

    case Osp.PortCache.get(key) do
      {:ok, port} ->
        port

      :miss ->
        port = compute(seed, cx, cy)
        Osp.PortCache.put(key, port)
        port
    end
  end

  @doc "Alle Häfen, deren Ankerplatz höchstens `r` WE von `(x, y)` entfernt ist."
  @spec near(integer(), number(), number(), number()) :: [map()]
  def near(seed, x, y, r) do
    {c0x, c0y} = Terrain.chunk_of(x - r, y - r)
    {c1x, c1y} = Terrain.chunk_of(x + r, y + r)

    for cx <- c0x..c1x,
        cy <- c0y..c1y,
        port = in_chunk(seed, cx, cy),
        dist(port, x, y) <= r,
        do: port
  end

  @doc "Liegt `(x, y)` in der Schutzzone eines Hafens?"
  @spec safe?(integer(), number(), number()) :: boolean()
  def safe?(seed, x, y), do: near(seed, x, y, @safe_radius) != []

  @doc "Der nächste Hafen in Andockreichweite oder `nil`."
  @spec dockable(integer(), number(), number()) :: map() | nil
  def dockable(seed, x, y) do
    seed |> near(x, y, @dock_radius) |> Enum.min_by(&dist(&1, x, y), fn -> nil end)
  end

  # --- Erzeugung ---------------------------------------------------------------------------

  defp compute(seed, cx, cy) do
    if frac({:port, seed, cx, cy}) > @chance do
      nil
    else
      x0 = cx * Terrain.chunk_size()
      y0 = cy * Terrain.chunk_size()

      Enum.find_value(0..(@tries - 1), fn k ->
        x = x0 + 3.0 + frac({:px, seed, cx, cy, k}) * 10.0
        y = y0 + 3.0 + frac({:py, seed, cx, cy, k}) * 10.0

        with true <- Spawn.clear?(seed, x, y, 1.4),
             land when land != nil <- coast_direction(seed, x, y) do
          %{
            id: "port:#{cx},#{cy}",
            name: Enum.at(@names, :erlang.phash2({:name, seed, cx, cy}, length(@names))),
            x: Float.round(x, 2),
            y: Float.round(y, 2),
            land: Float.round(land, 3)
          }
        else
          _ -> nil
        end
      end)
    end
  end

  # Richtung zur nächsten Küste (Land in 2,6–4,6 WE), sonst nil
  defp coast_direction(seed, x, y) do
    for k <- 0..15, r <- [2.6, 3.4, 4.2], reduce: nil do
      nil ->
        a = k * :math.pi() / 8
        if Terrain.land?(seed, x + :math.cos(a) * r, y + :math.sin(a) * r), do: a

      found ->
        found
    end
  end

  defp frac(term), do: :erlang.phash2(term, 1_000_000) / 999_999
  defp dist(port, x, y), do: :math.sqrt(:math.pow(port.x - x, 2) + :math.pow(port.y - y, 2))
end
