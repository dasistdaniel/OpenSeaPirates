defmodule Osp.Director do
  @moduledoc """
  Hält die unendliche Welt um die Spieler herum lebendig (rein, arbeitet auf `Osp.State`).

  Alle 2 s und für jeden lebenden Spieler: Fehlen in seinem Umkreis (60 WE) Händler (Soll 2) oder
  Jäger (Soll 1, manchmal als Bande aus 2), taucht ein Schiff **außerhalb der Sichtweite**
  (28–45 WE) auf. NPCs, die zu weit von allen Spielern entfernt sind (> 100 WE), verschwinden
  still. Kopfgeld und Verhalten gehören zu den Schiffen selbst, siehe `Osp.State.add_npc/7`.
  """

  alias Osp.{Reputation, Spawn, State}

  @every_ms 2_000
  @near 60.0
  @despawn 100.0
  @ring {28.0, 45.0}
  @want_merchants 2
  @want_hunters 1
  @band_chance 0.18
  @max_humans 8

  @spec step(State.t()) :: State.t()
  def step(%{director?: false} = state), do: state
  def step(%{time: t, dir_at: at} = state) when t < at, do: state

  def step(state) do
    state = %{state | dir_at: state.time + @every_ms}
    humans = state.ships |> Map.values() |> Enum.filter(&(&1.kind == :player and &1.alive?))

    state
    |> despawn(humans)
    |> then(fn st -> Enum.reduce(Enum.take(humans, @max_humans), st, &populate(&2, &1)) end)
  end

  defp despawn(state, humans) do
    far =
      for {id, s} <- state.ships,
          s.kind != :player,
          humans == [] or Enum.all?(humans, &(dist(&1, s) > @despawn)),
          do: id

    Enum.reduce(far, state, &State.remove_npc(&2, &1))
  end

  defp populate(state, human) do
    near = for {_, s} <- state.ships, s.kind != :player, s.alive?, dist(human, s) <= @near, do: s
    merchants = Enum.count(near, &(&1.kind == :merchant))
    hunters = Enum.count(near, &(&1.kind == :hunter))

    cond do
      merchants < @want_merchants -> spawn_one(state, human, :merchant)
      hunters < want_hunters(human) -> spawn_hunters(state, human)
      true -> state
    end
  end

  @doc """
  Wie viele Jäger um einen Spieler sollen es sein? Einer; **zwei**, wenn er bei der Nation des
  Gebiets, in dem er gerade fährt (`ship.terr`), Gesucht ist.
  """
  @spec want_hunters(map()) :: pos_integer()
  def want_hunters(%{terr: terr} = human) when terr != nil do
    if Reputation.standing(State.rep_of(human, terr)) == :wanted, do: @want_hunters + 1, else: @want_hunters
  end

  def want_hunters(_human), do: @want_hunters

  defp spawn_hunters(state, human) do
    {r, rng} = :rand.uniform_s(state.rng)
    state = %{state | rng: rng}

    if r < @band_chance do
      state |> spawn_one(human, :hunter, "Bande", 30) |> spawn_one(human, :hunter, "Bande", 30)
    else
      spawn_one(state, human, :hunter)
    end
  end

  defp spawn_one(state, human, kind, label \\ nil, bonus \\ 0) do
    others = for {_, s} <- state.ships, s.alive?, do: {s.x, s.y}
    {near, far} = @ring

    case Spawn.pick_around(state.seed, others, {human.x, human.y}, near, far, state.rng) do
      nil ->
        state

      {x, y, heading, rng} ->
        name = "#{label || if(kind == :merchant, do: "Händler", else: "Jäger")} #{state.next_id}"
        State.add_npc(%{state | rng: rng}, kind, name, x, y, heading, bonus)
    end
  end

  defp dist(a, b), do: :math.sqrt(:math.pow(a.x - b.x, 2) + :math.pow(a.y - b.y, 2))
end
