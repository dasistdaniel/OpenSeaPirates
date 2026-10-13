defmodule Osp.Web.Router do
  @moduledoc """
  HTTP: statische Dateien (`priv/static`), `/health` und der WebSocket `/ws` fürs Spiel.
  """

  use Plug.Router

  plug(Plug.Static,
    at: "/",
    from: {:osp, "priv/static"},
    only: ~w(css js images favicon.ico),
    cache_control_for_etags: "no-cache"
  )

  plug(:match)
  plug(:dispatch)

  get "/health" do
    send_resp(conn, 200, "ok")
  end

  get "/" do
    conn
    |> put_resp_content_type("text/html")
    |> put_resp_header("cache-control", "no-cache")
    |> send_file(200, Application.app_dir(:osp, "priv/static/index.html"))
  end

  get "/ws" do
    if origin_allowed?(conn) do
      conn
      |> WebSockAdapter.upgrade(Osp.Web.Socket, [], timeout: 60_000, max_frame_size: 16_384)
      |> halt()
    else
      send_resp(conn, 403, "origin not allowed")
    end
  end

  match _ do
    send_resp(conn, 404, "not found")
  end

  # Ohne OSP_ORIGINS wird nicht geprüft; sonst muss der Origin-Header in der Liste stehen.
  defp origin_allowed?(conn) do
    case Application.get_env(:osp, :allowed_origins) do
      nil -> true
      allowed -> get_req_header(conn, "origin") |> Enum.any?(&(&1 in allowed))
    end
  end
end
