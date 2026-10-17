defmodule Osp.Web.Socket do
  @moduledoc """
  WebSocket-Verbindung eines Spielers (Behaviour `WebSock`).

  **Client → Server** (JSON-Text):

    * `{"t":"join","token":"...","name":"...","nation":"spain"}` – beitreten (genau einmal, zuerst);
      `nation` ist nur nötig, solange das Profil noch keine Heimatnation hat
    * `{"t":"input","u":bool,"l":bool,"r":bool}` – Tastenzustand
    * `{"t":"chunk","cx":int,"cy":int}` – Geländeblock anfordern
    * `{"t":"fire","side":"left"|"right"}` – Breitseite (Q = links, E = rechts)
    * `{"t":"dock"}` / `{"t":"undock"}` – im Hafen andocken (F) / ablegen
    * `{"t":"buy","what":"class"|"upgrade"|"ammo"|"repair","id":"..."}` – im Hafen kaufen
    * `{"t":"bank","op":"deposit"|"withdraw","amount":int|"all"}` – Gold einlagern/abheben
    * `{"t":"ammo","kind":"ball"|"chain"|"fire"}` – Munition wählen (1/2/3)
    * `{"t":"sail","mode":"reefed"|"full"|"studding"}` – Segelstufe (S schaltet reihum)
    * `{"t":"quest","op":"accept"|"abandon","id":"q:port:10,1:5:0"}` / `{"t":"quest","op":"turn_in"}` –
      Quest annehmen (angedockt), aufgeben, im Hafen abgeben

  **Server → Client:**

    * Text `{"t":"welcome", ...}` – nach dem Beitritt (`you`, `seed`, `chunk`, `res`, `land`); nach
      einem Wiederverbinden kommt es erneut, ist das Schiff angedockt, folgt die Hafen-Ansicht
    * Text `{"t":"error","reason":"full"}` – Beitritt abgelehnt (Welt voll)
    * Text `{"t":"error","reason":"nation_required","nations":[…]}` – das Profil hat noch keine Nation:
      die Verbindung bleibt offen, der Client wählt und schickt `join` erneut mit `nation`
    * Text `{"t":"snap", ...}` – Schnappschuss, ca. 20× pro Sekunde
    * Text `{"t":"shop", ...}` – Hafen-Ansicht (`open: true` mit Angeboten) oder `open: false`,
      optional mit `error`
    * Binär `<<1, cx::signed-32, cy::signed-32, höhen::binary>>` – Chunk (`Osp.Terrain.chunk/3`)

  Die Identität ist vorerst ein anonymes Token aus dem Browser (`localStorage`); später kommen
  Konten dazu. Chunk-Anfragen sind mengenbegrenzt.
  """

  @behaviour WebSock

  alias Osp.{Nations, Profile, Profiles, Terrain, World}

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
  @sails %{"reefed" => :reefed, "full" => :full, "studding" => :studding}

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
      nation = chosen_nation(msg["nation"])

      if stored_nation(token) == nil and nation == nil do
        {:push, {:text, Jason.encode!(nation_required())}, state}
      else
        do_join(token, name, nation, state)
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

  defp handle_msg(%{"t" => "sail", "mode" => mode}, %{id: id} = state)
       when id != nil and mode in ["reefed", "full", "studding"] do
    World.sail(state.world, id, @sails[mode])
    {:ok, state}
  end

  # Quests: annehmen (Angebots-ID), abgeben, aufgeben (Quest-ID); IDs nur in fester Form
  defp handle_msg(%{"t" => "quest", "op" => "accept", "id" => qid}, %{id: id} = state)
       when id != nil do
    if valid_quest_id?(qid), do: World.quest(state.world, id, {:accept, qid})
    {:ok, state}
  end

  defp handle_msg(%{"t" => "quest", "op" => "abandon", "id" => qid}, %{id: id} = state)
       when id != nil do
    if valid_quest_id?(qid), do: World.quest(state.world, id, {:abandon, qid})
    {:ok, state}
  end

  defp handle_msg(%{"t" => "quest", "op" => "turn_in"}, %{id: id} = state) when id != nil do
    World.quest(state.world, id, :turn_in)
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

  defp do_join(token, name, nation, state) do
    case World.join(state.world, token, name, self(), nation: nation) do
      {:ok, info} ->
        reply = %{
          t: "welcome",
          you: Osp.State.public_id(info.id),
          seed: World.seed(state.world),
          chunk: info.chunk,
          res: info.resolution,
          land: info.land
        }

        {:push, {:text, Jason.encode!(reply)}, %{state | id: token}}

      {:error, reason} ->
        # z. B. :full – der Client zeigt den Grund und gibt auf
        {:push, {:text, Jason.encode!(%{t: "error", reason: Atom.to_string(reason)})}, state}
    end
  end

  # Gewählte Nation aus dem Netz: nur die festen Namen, sonst nil
  defp chosen_nation(value) do
    case Nations.parse(value) do
      {:ok, nation} -> nation
      :error -> nil
    end
  end

  # Heimatnation aus dem gespeicherten Profil (nil bei neuen Spielern und alten Profilen)
  defp stored_nation(token) do
    case Profiles.get(token) do
      %{} = profile -> profile |> Profile.decode() |> Map.get("nation")
      _ -> nil
    end
  end

  defp nation_required do
    %{
      t: "error",
      reason: "nation_required",
      nations:
        for n <- Nations.all() do
          info = Nations.info(n)
          %{id: Atom.to_string(n), name: info.name, color: info.color, bonus: info.bonus_text}
        end
    }
  end

  # Einkaufswünsche aus dem Netz nur über feste Zuordnungen in Atome übersetzen
  defp buy_action("class", c), do: if(@classes[c], do: {:class, @classes[c]})
  defp buy_action("upgrade", s), do: if(@slots[s], do: {:upgrade, @slots[s]})
  defp buy_action("ammo", k) when k in ["chain", "fire"], do: {:ammo, @ammo[k]}
  defp buy_action("repair", _), do: :repair
  defp buy_action(_, _), do: nil

  defp valid_quest_id?(qid) when is_binary(qid) and byte_size(qid) <= 64,
    do: String.match?(qid, ~r/^q:port:-?\d{1,7},-?\d{1,7}:\d{1,6}:\d$/)

  defp valid_quest_id?(_other), do: false

  defp valid_token?(token),
    do:
      byte_size(token) >= 8 and String.match?(token, ~r/^[A-Za-z0-9_-]+$/) and
        not String.starts_with?(token, "npc-")

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
