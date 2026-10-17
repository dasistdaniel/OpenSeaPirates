defmodule Osp.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        Osp.PortCache,
        Osp.Profiles,
        Osp.Territory,
        {Registry, keys: :unique, name: Osp.WorldRegistry},
        {DynamicSupervisor, name: Osp.WorldSupervisor, strategy: :one_for_one}
      ] ++ server() ++ main_world()

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
  defp main_world do
    if Application.get_env(:osp, :start_main_world) do
      [
        Supervisor.child_spec(
          {Task,
           fn ->
             {:ok, _} =
               Osp.World.start(
                 id: Osp.Web.Socket.main_world(),
                 seed: Application.get_env(:osp, :seed),
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
