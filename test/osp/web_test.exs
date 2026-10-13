defmodule Osp.WebTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias Osp.Web.{Router, Socket}

  test "/health antwortet 200" do
    conn = conn(:get, "/health") |> Router.call(Router.init([]))
    assert conn.status == 200
  end

  test "/ liefert die Startseite, Assets werden ausgeliefert, Unbekanntes ist 404" do
    conn = conn(:get, "/") |> Router.call(Router.init([]))
    assert conn.status == 200

    js = conn(:get, "/js/main.js") |> Router.call(Router.init([]))
    assert js.status == 200

    assert (conn(:get, "/nichts") |> Router.call(Router.init([]))).status == 404
  end

  describe "WebSocket-Protokoll (Callbacks direkt)" do
    setup do
      id = "w" <> Integer.to_string(System.unique_integer([:positive]))
      start_supervised!({Osp.World, id: id, seed: 4, bots: 0}, id: id)
      {:ok, state} = Socket.init([])
      {:ok, state: %{state | world: id}}
    end

    defp send_json(state, map), do: Socket.handle_in({Jason.encode!(map), [opcode: :text]}, state)

    test "join liefert welcome; ungültiges Token beendet die Verbindung", %{state: state} do
      assert {:push, {:text, json}, state} =
               send_json(state, %{t: "join", token: "abcdefgh1234", name: "  Anna  "})

      assert %{"t" => "welcome", "you" => "abcdefgh1234", "chunk" => 16, "res" => 2} =
               Jason.decode!(json)

      assert state.id == "abcdefgh1234"

      {:ok, fresh} = Socket.init([])
      assert {:stop, :normal, 1008, _} = send_json(fresh, %{t: "join", token: "x!", name: "A"})
    end

    test "ohne join werden input und chunk ignoriert", %{state: state} do
      assert {:ok, ^state} = send_json(state, %{t: "input", u: true})
      assert {:ok, ^state} = send_json(state, %{t: "chunk", cx: 0, cy: 0})
    end

    test "chunk antwortet binär im Protokollformat, Anfragen sind begrenzt", %{state: state} do
      {:push, _, state} = send_json(state, %{t: "join", token: "abcdefgh1234", name: "A"})

      assert {:push, {:binary, frame}, state} = send_json(state, %{t: "chunk", cx: -3, cy: 5})
      assert <<1, -3::signed-32, 5::signed-32, heights::binary>> = frame
      assert byte_size(heights) == Osp.Terrain.edge() * Osp.Terrain.edge()

      # Burst aufbrauchen: irgendwann kommt keine Antwort mehr
      {_state, replies} =
        Enum.reduce(1..100, {state, 0}, fn _, {st, n} ->
          case send_json(st, %{t: "chunk", cx: 0, cy: 0}) do
            {:push, _, st} -> {st, n + 1}
            {:ok, st} -> {st, n}
          end
        end)

      assert replies < 100
    end

    test "Schnappschuss wird als JSON-Text weitergereicht", %{state: state} do
      snap = %{t: "snap", time: 1, w: 0.0, wi: 5, you: "a", ships: []}
      assert {:push, {:text, json}, _} = Socket.handle_info({:osp_snap, snap}, state)
      assert %{"t" => "snap", "time" => 1} = Jason.decode!(json)
    end
  end
end
