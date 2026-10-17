defmodule Osp.Quests do
  @moduledoc """
  Quests (rein): Angebote der Häfen, Quest-Zustand, Fortschritt, Ablauf und die strenge Prüfung
  gespeicherter Quests.

  **Angebote** entstehen **ohne Speicher** aus `{Seed, Hafen, Zeitfenster}` (`window/1`, 30 Minuten):
  `offers/3` liefert drei (Lieferung, Jagd, dritte per Hash), `atonement_offers/3` zwei
  Wiedergutmachungsangebote (nur für Gesuchte). Eine **Lieferung** führt zu einem anderen Hafen 40–120 WE
  entfernt, eine **Jagd** verlangt 2–3 Jäger einer anderen Nation. Angenommene Quests liegen im Schiff
  und Profil (`to_json/1`, `from_json/1`).

  Siehe `docs/superpowers/specs/2026-10-17-nationen-ruf-quests-design.md`.
  """

  alias Osp.{Nations, Ports}

  @window_ms 1_800_000
  @ttl_ms 1_800_000
  @max_active 2
  @min_dist 40.0
  @max_dist 120.0
  @max_gold 100_000
  @id_re ~r/^q:(port:-?\d{1,7},-?\d{1,7}):(\d{1,6}):(\d)$/
  @port_re ~r/^port:-?\d{1,7},-?\d{1,7}$/

  @type offer :: map()
  @type quest :: map()

  def ttl_ms, do: @ttl_ms
  def max_active, do: @max_active

  @doc "Zeitfenster (30 Minuten) zur Spielzeit in ms."
  @spec window(non_neg_integer()) :: non_neg_integer()
  def window(time_ms), do: div(time_ms, @window_ms)

  # --- Angebote --------------------------------------------------------------------------

  @doc "Die drei Angebote des Hafens im Zeitfenster (deterministisch)."
  @spec offers(integer(), map(), non_neg_integer()) :: [offer()]
  def offers(seed, port, window) do
    for idx <- 0..2, do: make_offer(seed, port, window, idx, false)
  end

  @doc "Zwei Wiedergutmachungsangebote (Ruf +25, kein Gold); Ziele nur in der Nation des Hafens."
  @spec atonement_offers(integer(), map(), non_neg_integer()) :: [offer()]
  def atonement_offers(seed, port, window) do
    for idx <- 3..4, do: make_offer(seed, port, window, idx, true)
  end

  @doc "Sucht ein Angebot per ID (Wiedergutmachung nur, wenn `wanted?`)."
  @spec find_offer(integer(), map(), non_neg_integer(), term(), boolean()) ::
          {:ok, offer()} | :error
  def find_offer(seed, port, window, id, wanted?) when is_binary(id) do
    pool =
      offers(seed, port, window) ++
        if(wanted?, do: atonement_offers(seed, port, window), else: [])

    case Enum.find(pool, &(&1.id == id)) do
      nil -> :error
      offer -> {:ok, offer}
    end
  end

  def find_offer(_seed, _port, _window, _id, _wanted?), do: :error

  defp make_offer(seed, port, window, idx, atone?) do
    nation = Nations.of_port(seed, port)

    kind =
      cond do
        idx in [0, 3] -> :delivery
        idx in [1, 4] -> :hunt
        true -> if hash(seed, port, window, idx, :kind, 2) == 0, do: :delivery, else: :hunt
      end

    base = %{
      id: "q:#{port.id}:#{window}:#{idx}",
      from: port.id,
      nation: nation,
      atone?: atone?
    }

    case kind == :delivery and delivery_target(seed, port, window, idx, nation, atone?) do
      %{} = target -> delivery(base, port, target, atone?)
      _ -> hunt(base, seed, port, window, idx, nation, atone?)
    end
  end

  defp delivery_target(seed, port, window, idx, nation, atone?) do
    targets =
      seed
      |> Ports.near(port.x, port.y, @max_dist)
      |> Enum.filter(fn t ->
        d = distance(port, t)

        t.id != port.id and d >= @min_dist and d <= @max_dist and
          (not atone? or Nations.of_port(seed, t) == nation)
      end)
      |> Enum.sort_by(& &1.id)

    if targets == [],
      do: nil,
      else: Enum.at(targets, hash(seed, port, window, idx, :target, length(targets)))
  end

  defp delivery(base, port, target, atone?) do
    dist = round(distance(port, target))

    Map.merge(base, %{
      kind: :delivery,
      to: target.id,
      to_name: target.name,
      dist: dist,
      target_nation: nil,
      need: 1,
      gold: if(atone?, do: 0, else: 40 + round(1.2 * dist)),
      rep: if(atone?, do: 25, else: 4)
    })
  end

  defp hunt(base, seed, port, window, idx, nation, atone?) do
    others = Nations.all() -- [nation]
    need = 2 + hash(seed, port, window, idx, :need, 2)

    Map.merge(base, %{
      kind: :hunt,
      to: nil,
      to_name: nil,
      dist: nil,
      target_nation: Enum.at(others, hash(seed, port, window, idx, :nation, length(others))),
      need: need,
      gold: if(atone?, do: 0, else: 70 * need),
      rep: if(atone?, do: 25, else: 6)
    })
  end

  defp hash(seed, port, window, idx, salt, n),
    do: :erlang.phash2({:quest, seed, port.id, window, idx, salt}, n)

  defp distance(a, b), do: :math.sqrt(:math.pow(a.x - b.x, 2) + :math.pow(a.y - b.y, 2))

  # --- Zustand ---------------------------------------------------------------------------

  @doc "Aus einem angenommenen Angebot eine aktive Quest (ohne Anzeigefelder, mit 30 Minuten Zeit)."
  @spec to_quest(offer()) :: quest()
  def to_quest(offer) do
    offer
    |> Map.take([:id, :kind, :from, :nation, :to, :target_nation, :need, :gold, :rep, :atone?])
    |> Map.merge(%{have: 0, left_ms: @ttl_ms})
  end

  @doc "Ein versenktes Schiff der Nation `victim_nation` zählt bei Jagden mit dieser Zielnation."
  @spec kill(quest(), atom()) :: quest()
  def kill(%{kind: :hunt, target_nation: n, have: have, need: need} = q, n) when have < need,
    do: %{q | have: have + 1}

  def kill(quest, _victim_nation), do: quest

  @doc "Kann die Quest im Hafen `port_id` abgegeben werden?"
  @spec complete?(quest(), String.t()) :: boolean()
  def complete?(%{kind: :delivery, to: to}, port_id), do: to == port_id

  def complete?(%{kind: :hunt, have: have, need: need, from: from}, port_id),
    do: have >= need and from == port_id

  @doc "Zieht `ms` ab; `{aktive, abgelaufene}`."
  @spec tick([quest()], non_neg_integer()) :: {[quest()], [quest()]}
  def tick(quests, ms) do
    quests
    |> Enum.map(&%{&1 | left_ms: &1.left_ms - ms})
    |> Enum.split_with(&(&1.left_ms > 0))
  end

  # --- Hinweis (grobe Richtung) --------------------------------------------------------------

  @doc """
  Ungerundeter Hinweispunkt `{x, y}` für den Spieler bei `{px, py}`: Lieferung → Zielhafen; Jagd mit
  fehlenden Abschüssen → nächster Hafen der Zielnation (bis 400 WE); sonst der Abgabehafen. `nil`, wenn
  es keinen passenden Hafen gibt.
  """
  @spec hint(integer(), quest(), {number(), number()}) :: {number(), number()} | nil
  def hint(seed, %{kind: :delivery, to: to}, _pos), do: port_xy(Ports.by_id(seed, to))

  def hint(seed, %{kind: :hunt, have: have, need: need, target_nation: tn}, pos) when have < need,
    do: port_xy(Nations.nearest_port_of(seed, tn, pos, 400.0))

  def hint(seed, %{from: from}, _pos), do: port_xy(Ports.by_id(seed, from))

  defp port_xy(nil), do: nil
  defp port_xy(port), do: {port.x, port.y}

  @doc "Hinweis auf Vielfache von 10 WE runden (der Spieler soll nur die grobe Richtung kennen)."
  @spec round_hint({number(), number()}) :: {integer(), integer()}
  def round_hint({x, y}), do: {round(x / 10) * 10, round(y / 10) * 10}

  # --- Speicherformat --------------------------------------------------------------------

  @doc "JSON-taugliche Map (String-Schlüssel); Hinweise und Anzeigefelder werden nicht gespeichert."
  @spec to_json(quest()) :: map()
  def to_json(q) do
    %{
      "id" => q.id,
      "kind" => Atom.to_string(q.kind),
      "nation" => Atom.to_string(q.nation),
      "to" => q.to,
      "tn" => q.target_nation && Atom.to_string(q.target_nation),
      "need" => q.need,
      "have" => q.have,
      "gold" => q.gold,
      "rep" => q.rep,
      "at" => q.atone?,
      "left" => q.left_ms
    }
  end

  @doc "Prüft eine gespeicherte Quest streng; Unsinn ergibt `:error`, Zahlen werden begrenzt."
  @spec from_json(term()) :: {:ok, quest()} | :error
  def from_json(%{} = raw) do
    with id when is_binary(id) <- raw["id"],
         [_, from, _window, _idx] <- Regex.run(@id_re, id),
         {:ok, kind} <- kind(raw["kind"]),
         {:ok, nation} <- Nations.parse(raw["nation"]),
         {:ok, to, tn, need} <- target(kind, raw, from, nation),
         have when is_integer(have) and have >= 0 and have <= need <- raw["have"],
         left when is_integer(left) and left > 0 <- raw["left"],
         gold when is_integer(gold) <- raw["gold"],
         rep when is_integer(rep) <- raw["rep"],
         at when is_boolean(at) <- raw["at"] do
      {:ok,
       %{
         id: id,
         kind: kind,
         from: from,
         nation: nation,
         to: to,
         target_nation: tn,
         need: need,
         gold: gold |> max(0) |> min(@max_gold),
         rep: rep |> max(0) |> min(100),
         atone?: at,
         have: have,
         left_ms: min(left, @ttl_ms)
       }}
    else
      _ -> :error
    end
  end

  def from_json(_other), do: :error

  defp kind("delivery"), do: {:ok, :delivery}
  defp kind("hunt"), do: {:ok, :hunt}
  defp kind(_), do: :error

  defp target(:delivery, raw, from, _nation) do
    to = raw["to"]

    if is_binary(to) and Regex.match?(@port_re, to) and to != from and raw["need"] == 1 and
         raw["tn"] == nil,
       do: {:ok, to, nil, 1},
       else: :error
  end

  defp target(:hunt, raw, _from, nation) do
    need = raw["need"]

    with true <- is_integer(need) and need >= 1 and need <= 3,
         nil <- raw["to"],
         {:ok, tn} <- Nations.parse(raw["tn"]),
         true <- tn != nation do
      {:ok, nil, tn, need}
    else
      _ -> :error
    end
  end
end
