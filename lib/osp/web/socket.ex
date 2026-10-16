defmodule Osp.Web.Socket do
  @moduledoc """
  WebSocket-Verbindung eines Spielers (Behaviour `WebSock`).

  **Client → Server** (JSON-Text):

    * `{"t":"join","token":"...","name":"..."}` – beitreten (genau einmal, zuerst)
    * `{"t":"input","u":bool,"l":bool,"r":bool}` – Tastenzustand
    * `{"t":"chunk","cx":int,"cy":int}` – Geländeblock anfordern
    * `{"t":"fire","side":"left"|"right"}` – Breitseite (Q = links, E = rechts)
    * `{"t":"dock"}` / `{"t":"undock"}` – im Hafen andocken (F) / ablegen
    * `{"t":"buy","what":"class"|"upgrade"|"ammo"|"repair","id":"..."}` – im Hafen kaufen
    * `{"t":"bank","op":"deposit"|"withdraw","amount":int|"all"}` – Gold einlagern/abheben
    * `{"t":"ammo","kind":"ball"|"chain"|"fire"}` – Munition wählen (1/2/3)

  **Server → Client:**

    * Text `{"t":"welcome", ...}` – nach dem Beitritt (`you`, `chunk`, `res`, `land`)
    * Text `{"t":"error","reason":"full"}` – Beitritt abgelehnt (Welt voll)
    * Text `{"t":"snap", ...}` – Schnappschuss, ca. 20× pro Sekunde
    * Text `{"t":"shop", ...}` – Hafen-Ansicht (`open: true` mit Angeboten) oder `open: false`,
      optional mit `error`
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
  # Alle anderen Nachrichten (Steuerung, Schüsse, Hafen): 50/s, Stoß bis 80; wer dauerhaft weit
  # darüber liegt, wird getrennt
  @act_burst 80
  @act_per_sec 50
  @act_drop_limit 400

  @classes %{
    "schaluppe" => :schaluppe,
    "klipper" => :klipper,
    "brigg" => :brigg,
    "fregatte" => :fregatte,
    "galeone" => :galeone
  }
  @slots %{"cannons" => :cannons, "hull" => :hull, "sails" => :sails}
  @ammo %{"ball" => :ball, "chain" => :chain, "fire" => :fire}

  def main_world, do: @main_world

  @impl true
  def init(_opts) do
    t = now()

    {:ok,
     %{
       world: @main_world,
       id: nil,
       tokens: @chunk_burst,
       refilled: t,
       act: @act_burst * 1.0,
       act_at: t,
       dropped: 0
     }}
  end

  @impl true
  def handle_in({text, [opcode: :text]}, state) do
    case Jason.decode(text) do
      {:ok, msg} when is_map(msg) -> throttled(msg, state)
      _ -> {:ok, state}
    end
  end

  def handle_in(_other, state), do: {:ok, state}

  @impl true
  def handle_info({:osp_snap, snap}, state), do: {:push, {:text, Jason.encode!(snap)}, state}

  def handle_info({:osp_shop, view}, state), do: {:push, {:text, Jason.encode!(view)}, state}
  def handle_info(_other, state), do: {:ok, state}

  # --- Raten-Begrenzung ---------------------------------------------------------------

  # Beitritt und Chunks haben eigene Regeln; alles andere teilt sich einen Eimer
  defp throttled(%{"t" => t} = msg, state) when t in ["join", "chunk"], do: handle_msg(msg, state)

  defp throttled(msg, state) do
    now = now()
    tokens = min(state.act + (now - state.act_at) / 1000 * @act_per_sec, @act_burst * 1.0)

    cond do
      tokens >= 1 ->
        handle_msg(msg, %{state | act: tokens - 1, act_at: now})

      state.dropped + 1 > @act_drop_limit ->
        {:stop, :normal, 1008, state}

      true ->
        {:ok, %{state | act: tokens, act_at: now, dropped: state.dropped + 1}}
    end
  end

  # --- Nachrichten ---------------------------------------------------------------

  defp handle_msg(%{"t" => "join", "token" => token} = msg, %{id: nil} = state)
       when is_binary(token) do
    token = String.slice(token, 0, 64)

    if valid_token?(token) and World.alive?(state.world) do
      name = clean_name(msg["name"], token)

      case World.join(state.world, token, name, self()) do
        {:ok, info} ->
          reply =
            %{
              t: "welcome",
              you: info.id,
              chunk: info.chunk,
              res: info.resolution,
              land: info.land
            }

          {:push, {:text, Jason.encode!(reply)}, %{state | id: token}}

        {:error, reason} ->
          # z. B. :full – der Client zeigt den Grund und gibt auf
          {:push, {:text, Jason.encode!(%{t: "error", reason: Atom.to_string(reason)})}, state}
      end
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

  defp handle_msg(%{"t" => "dock"}, %{id: id} = state) when id != nil do
    World.dock(state.world, id)
    {:ok, state}
  end

  defp handle_msg(%{"t" => "undock"}, %{id: id} = state) when id != nil do
    World.undock(state.world, id)
    {:ok, state}
  end

  defp handle_msg(%{"t" => "ammo", "kind" => kind}, %{id: id} = state)
       when id != nil and kind in ["ball", "chain", "fire"] do
    World.ammo(state.world, id, @ammo[kind])
    {:ok, state}
  end

  defp handle_msg(%{"t" => "buy", "what" => what} = msg, %{id: id} = state) when id != nil do
    case buy_action(what, msg["id"]) do
      nil -> :ok
      action -> World.shop(state.world, id, action)
    end

    {:ok, state}
  end

  defp handle_msg(%{"t" => "bank", "op" => op} = msg, %{id: id} = state)
       when id != nil and op in ["deposit", "withdraw"] do
    amount = msg["amount"]

    amount =
      cond do
        amount == "all" -> :all
        is_integer(amount) and amount > 0 and amount < 10_000_000 -> amount
        true -> nil
      end

    if amount do
      World.shop(state.world, id, {if(op == "deposit", do: :deposit, else: :withdraw), amount})
    end

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

  # Einkaufswünsche aus dem Netz nur über feste Zuordnungen in Atome übersetzen
  defp buy_action("class", c), do: if(@classes[c], do: {:class, @classes[c]})
  defp buy_action("upgrade", s), do: if(@slots[s], do: {:upgrade, @slots[s]})
  defp buy_action("ammo", k) when k in ["chain", "fire"], do: {:ammo, @ammo[k]}
  defp buy_action("repair", _), do: :repair
  defp buy_action(_, _), do: nil

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
