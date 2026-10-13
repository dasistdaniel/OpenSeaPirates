import Config

# Laufzeit-Konfiguration (alle Umgebungen, auch im Release)
#
#   PORT              HTTP-Port im Container (4000)
#   OSP_SEED          Seed der Hauptwelt (Zahl); ohne Angabe zufällig bei jedem Start
#   OSP_BOTS          Anzahl Wander-Bots in der Hauptwelt (3)
#   OSP_ORIGINS       erlaubte WebSocket-Origins, kommasepariert (z. B. https://osp.example.com);
#                     ohne Angabe wird nicht geprüft
if port = System.get_env("PORT") do
  config :osp, port: String.to_integer(port)
end

if seed = System.get_env("OSP_SEED") do
  config :osp, seed: String.to_integer(seed)
end

if bots = System.get_env("OSP_BOTS") do
  config :osp, bots: String.to_integer(bots)
end

if origins = System.get_env("OSP_ORIGINS") do
  config :osp,
    allowed_origins: origins |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
end
