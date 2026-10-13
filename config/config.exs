import Config

# Weltparameter (Standardwerte; zur Laufzeit per Umgebungsvariablen überschreibbar, siehe runtime.exs)
config :osp,
  start_server: true,
  start_main_world: true,
  # Anzahl NPC-Händler in der Hauptwelt (Ziele und Leben auf See)
  bots: 3,
  seed: nil,
  allowed_origins: nil,
  port: 4000

config :logger, :default_formatter, format: "$time $metadata[$level] $message\n"

import_config "#{config_env()}.exs"
