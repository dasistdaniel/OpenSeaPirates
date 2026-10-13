import Config

# Weltparameter (Standardwerte; zur Laufzeit per Umgebungsvariablen überschreibbar, siehe runtime.exs)
config :osp,
  start_server: true,
  start_main_world: true,
  # Anzahl Wander-Bots in der Hauptwelt (Leben in der Welt, bis es echte NPCs gibt)
  bots: 3,
  seed: nil,
  allowed_origins: nil,
  port: 4000

config :logger, :default_formatter, format: "$time $metadata[$level] $message\n"

import_config "#{config_env()}.exs"
