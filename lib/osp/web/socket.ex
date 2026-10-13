defmodule Osp.Web.Socket do
  @moduledoc """
  WebSocket-Verbindung eines Spielers (Behaviour `WebSock`).

  **Client → Server** (JSON-Text):

    * `{"t":"join","token":"...","name":"..."}` – beitreten (genau einmal, zuerst)
    * `{"t":"input","u":bool,"l":bool,"r":bool}` – Tastenzustand
    * `{"t":"chunk","cx":int,"cy":int}` – Geländeblock anfordern
    * `{"t":"fire","side":"left"|"right"}` – Breitseite (Q = links, E = rechts)

  **Server → Client:**

    * Text `{"t":"welcome", ...}` – nach dem Beitritt (`you`, `chunk`, `res`, `land`)
    * Text `{"t":"snap", ...}` – Schnappschuss, ca. 20× pro Sekunde
    * Binär `<<1, cx::signed-32, cy::signed-32, höhen::binary>>` – Chunk (`Osp.Terrain.chunk/3`)

  Die Identität ist vorerst ein anonymes Token aus dem Browser (`localStorage`); später kommen
  Konten dazu. Chunk-Anfragen sind mengenbegrenzt.
  """

  @behaviour WebSock

  alias Osp.{Terrain, World}

  @main_world "main"
  @max_name 20
  @chunk_burst 120
  @chunk_per_sec 60

  def main_world, do: @main_world

  @impl true
  def init(_opts) do
    {:ok, %{world: @main_world, id: nil, tokens: @chunk_burst, refilled: now()}}
  end

  @impl true
  def handle_in({text, [opcode: :text]}, state) do
    case Jason.decode(text) do
      {:ok, msg} when is_map(msg) -> handle_msg(msg, state)
      _ -> {:ok, state}
    end
  end

  def handle_in(_other, state), do: {:ok, state}

  @impl true
  def handle_info({:osp_snap, snap}, state), do: {:push, {:text, Jason.encode!(snap)}, state}

  def handle_info(_other, state), do: {:ok, state}

  # --- Nachrichten ---------------------------------------------------------------

  defp handle_msg(%{"t" => "join", "token" => token} = msg, %{id: nil} = state)
       when is_binary(token) do
    token = String.slice(token, 0, 64)

    if valid_token?(token) and World.alive?(state.world) do
      name = clean_name(msg["name"], token)
      {:ok, info} = World.join(state.world, token, name, self())

      reply =
        %{t: "welcome", you: info.id, chunk: info.chunk, res: info.resolution, land: info.land}

      {:push, {:text, Jason.encode!(reply)}, %{state | id: token}}
    else
      {:stop, :normal, 1008, state}
    end
  end

  defp handle_msg(%{"t" => "input"} = msg, %{id: id} = state) when id != nil do
    World.input(state.world, id, %{
      up?: msg["u"] == true,
      left?: msg["l"] == true,
      right?: msg["r"] == true
    })

    {:ok, state}
  end

  defp handle_msg(%{"t" => "fire", "side" => side}, %{id: id} = state)
       when id != nil and side in ["left", "right"] do
    World.fire(state.world, id, if(side == "left", do: :left, else: :right))
    {:ok, state}
  end

  defp handle_msg(%{"t" => "chunk", "cx" => cx, "cy" => cy}, %{id: id} = state)
       when id != nil and is_integer(cx) and is_integer(cy) and abs(cx) < 1_000_000 and
              abs(cy) < 1_000_000 do
    state = refill(state)

    if state.tokens >= 1 do
      seed = World.seed(state.world)
      frame = <<1, cx::signed-32, cy::signed-32, Terrain.chunk(seed, cx, cy)::binary>>
      {:push, {:binary, frame}, %{state | tokens: state.tokens - 1}}
    else
      {:ok, state}
    end
  end

  defp handle_msg(_other, state), do: {:ok, state}

  # --- Hilfen ----------------------------------------------------------------------

  defp valid_token?(token),
    do: byte_size(token) >= 8 and String.match?(token, ~r/^[A-Za-z0-9_-]+$/)

  defp clean_name(name, token) do
    cleaned =
      if is_binary(name),
        do:
          name
          |> String.replace(~r/[[:cntrl:]]/u, "")
          |> String.trim()
          |> String.slice(0, @max_name),
        else: ""

    if cleaned == "", do: "Pirat " <> String.slice(token, 0, 4), else: cleaned
  end

  # Token-Bucket: @chunk_per_sec nachfüllen, höchstens @chunk_burst
  defp refill(state) do
    t = now()
    add = (t - state.refilled) / 1000 * @chunk_per_sec
    %{state | tokens: min(state.tokens + add, @chunk_burst), refilled: t}
  end

  defp now, do: System.monotonic_time(:millisecond)
end
