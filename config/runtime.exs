import Config

# Laufzeit-Konfiguration (alle Umgebungen, auch im Release)
#
#   PORT              HTTP-Port im Container (4000)
#   OSP_SEED          Seed der Hauptwelt (Zahl); ohne Angabe zufällig bei jedem Start
#   OSP_BOTS          Anzahl fester NPC-Händler beim Start (0; den Rest macht der Director)
#   OSP_DATA_DIR      Verzeichnis für die Spielstände (profiles.json); im Container /data (Volume)
#   OSP_ORIGINS       erlaubte WebSocket-Origins, kommasepariert (z. B. https://osp.example.com);
#                     ohne Angabe wird nicht geprüft
#
# Leere Werte (z. B. aus docker-compose) zählen als nicht gesetzt.
env = fn name ->
  case System.get_env(name) do
    nil -> nil
    value -> if String.trim(value) == "", do: nil, else: String.trim(value)
  end
end

if port = env.("PORT") do
  config :osp, port: String.to_integer(port)
end

if seed = env.("OSP_SEED") do
  config :osp, seed: String.to_integer(seed)
end

if bots = env.("OSP_BOTS") do
  config :osp, bots: String.to_integer(bots)
end

if dir = env.("OSP_DATA_DIR") do
  config :osp, data_dir: dir
end

if origins = env.("OSP_ORIGINS") do
  config :osp,
    allowed_origins: origins |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
end
