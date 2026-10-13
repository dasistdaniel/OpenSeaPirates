import Config

# Weltparameter (Standardwerte; zur Laufzeit per Umgebungsvariablen überschreibbar, siehe runtime.exs)
config :osp,
  start_server: true,
  start_main_world: true,
  # Feste NPC-Händler beim Start (Standard 0: der Director bevölkert die Welt um die Spieler)
  bots: 0,
  director: true,
  seed: nil,
  allowed_origins: nil,
  port: 4000

config :logger, :default_formatter, format: "$time $metadata[$level] $message\n"

import_config "#{config_env()}.exs"
