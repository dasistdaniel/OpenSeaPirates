def sub(p, pairs):
    s = open(p, encoding='utf-8').read()
    for a, b in pairs:
        assert a in s, (p, a)
        s = s.replace(a, b, 1)
    open(p, 'w', encoding='utf-8').write(s)


sub('lib/osp/world.ex', [
    ('''  @doc "Spieler verlässt die Welt sofort."''', '''  @doc """
  Quest-Aktion: `{:accept, angebots_id}`, `:turn_in` oder `{:abandon, quest_id}`. Antwort (Hafen-Ansicht
  oder Fehler) kommt als `{:osp_shop, map}`.
  """
  def quest(world, id, op), do: GenServer.cast(via(world), {:quest, id, op})

  @doc "Spieler verlässt die Welt sofort."'''),
    ('''  def handle_cast({:leave, id}, state) do''', '''  def handle_cast({:quest, id, {:accept, offer_id}}, state) do
    {sim, result} = State.accept_quest(state.sim, id, offer_id)
    state = %{state | sim: sim}

    case result do
      {:ok, view} -> reply_shop(state, id, view)
      {:error, reason} -> reply_shop(state, id, error_view(sim, id, reason))
    end

    {:noreply, state}
  end

  def handle_cast({:quest, id, :turn_in}, state) do
    {sim, result} = State.turn_in(state.sim, id)
    state = %{state | sim: sim}

    case result do
      {:ok, view, events} ->
        reply_shop(state, id, view)
        {:noreply, %{state | pending: state.pending ++ events}}

      {:error, reason} ->
        reply_shop(state, id, error_view(sim, id, reason))
        {:noreply, state}
    end
  end

  def handle_cast({:quest, id, {:abandon, quest_id}}, state) do
    {sim, result} = State.abandon_quest(state.sim, id, quest_id)
    state = %{state | sim: sim}

    # Ist der Spieler angedockt, bekommt er die aktualisierte Ansicht
    with :ok <- result, view when view != nil <- State.shop_view(sim, id), do: reply_shop(state, id, view)
    {:noreply, state}
  end

  def handle_cast({:leave, id}, state) do'''),
    ('''  defp reply_shop(state, id, view) do''', '''  # Aktuelle Hafen-Ansicht (oder „geschlossen") mit dem Fehlergrund
  defp error_view(sim, id, reason) do
    view = State.shop_view(sim, id) || %{t: "shop", open: false}
    Map.put(view, :error, Atom.to_string(reason))
  end

  defp reply_shop(state, id, view) do'''),
])

sub('lib/osp/web/socket.ex', [
    ('''  defp handle_msg(%{"t" => "buy", "what" => what} = msg, %{id: id} = state) when id != nil do''', '''  # Quests: annehmen (Angebots-ID), abgeben, aufgeben (Quest-ID); IDs nur in fester Form
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

  defp handle_msg(%{"t" => "buy", "what" => what} = msg, %{id: id} = state) when id != nil do'''),
    ('''  defp valid_token?(token),''', '''  defp valid_quest_id?(qid) when is_binary(qid) and byte_size(qid) <= 64,
    do: String.match?(qid, ~r/^q:port:-?\\d{1,7},-?\\d{1,7}:\\d{1,6}:\\d$/)

  defp valid_quest_id?(_other), do: false

  defp valid_token?(token),'''),
    ('''    * `{"t":"sail","mode":"reefed"|"full"|"studding"}` – Segelstufe (S schaltet reihum)''', '''    * `{"t":"sail","mode":"reefed"|"full"|"studding"}` – Segelstufe (S schaltet reihum)
    * `{"t":"quest","op":"accept"|"abandon","id":"q:port:10,1:5:0"}` / `{"t":"quest","op":"turn_in"}` –
      Quest annehmen (angedockt), aufgeben, im Hafen abgeben'''),
])
