defmodule Osp.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Seed der Hauptwelt: eingestellt, sonst aus seed.txt im Datenverzeichnis, sonst einmal gewürfelt
    seed =
      Osp.WorldSeed.resolve(
        Application.get_env(:osp, :data_dir),
        Application.get_env(:osp, :seed)
      )

    children =
      [
        Osp.PortCache,
        Osp.Profiles,
        {Osp.Territory, seed: seed},
        {Registry, keys: :unique, name: Osp.WorldRegistry},
        {DynamicSupervisor, name: Osp.WorldSupervisor, strategy: :one_for_one}
      ] ++ server() ++ main_world(seed)

    Supervisor.start_link(children, strategy: :one_for_one, name: Osp.Supervisor)
  end

  defp server do
    if Application.get_env(:osp, :start_server) do
      [{Bandit, plug: Osp.Web.Router, scheme: :http, port: Application.get_env(:osp, :port)}]
    else
      []
    end
  end

  # Die Hauptwelt, in die alle ohne Raum-Angabe verbunden werden
  defp main_world(seed) do
    if Application.get_env(:osp, :start_main_world) do
      [
        Supervisor.child_spec(
          {Task,
           fn ->
             {:ok, _} =
               Osp.World.start(
                 id: Osp.Web.Socket.main_world(),
                 seed: seed,
                 bots: Application.get_env(:osp, :bots, 0),
                 director: Application.get_env(:osp, :director, false)
               )
           end},
          restart: :temporary
        )
      ]
    else
      []
    end
  end
end
