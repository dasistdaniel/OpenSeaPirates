defmodule Osp.Reputation do
  @moduledoc """
  Ruf bei den fünf Nationen (rein). Jeder Spieler hat je Nation eine Zahl von −100 bis +100
  (`%{atom() => integer()}`, siehe `start/1`); sie sinkt, wenn er Schiffe dieser Nation versenkt, und
  steigt bei Wiedergutmachung. Es gibt keine Verfeindungen: nur der Ruf bei der Nation des
  versenkten Schiffs ändert sich.

  Stufen: **Gesucht** ≤ −40, **Misstrauisch** −39 bis −10, **Neutral** −9 bis +29, **Freund** ≥ +30.
  Jäger greifen ab Misstrauisch an (`hunts?/1`). Siehe
  `docs/superpowers/specs/2026-10-17-nationen-ruf-quests-design.md`.
  """

  alias Osp.Nations

  @min -100
  @max 100
  @wanted -40
  @suspicious -10
  @friend 30
  @home_start 20

  @type rep :: %{atom() => integer()}

  @doc "Stufe zu einem Rufwert."
  @spec standing(integer()) :: :wanted | :suspicious | :neutral | :friend
  def standing(value) when value <= @wanted, do: :wanted
  def standing(value) when value <= @suspicious, do: :suspicious
  def standing(value) when value >= @friend, do: :friend
  def standing(_value), do: :neutral

  @doc "Deutscher Name einer Stufe."
  def label(:wanted), do: "Gesucht"
  def label(:suspicious), do: "Misstrauisch"
  def label(:neutral), do: "Neutral"
  def label(:friend), do: "Freund"

  @doc "Greifen Jäger einer Nation bei diesem Ruf an? (ab Misstrauisch)"
  @spec hunts?(integer()) :: boolean()
  def hunts?(value), do: value <= @suspicious

  @doc "Ruf bei einer Nation (fehlend = 0)."
  @spec get(rep(), atom()) :: integer()
  def get(rep, nation), do: Map.get(rep, nation, 0)

  @doc "Ruf bei einer Nation um `delta` ändern, begrenzt auf −100..100; andere Nationen bleiben."
  @spec add(rep(), atom(), integer()) :: rep()
  def add(rep, nation, delta),
    do: Map.put(rep, nation, rep |> get(nation) |> Kernel.+(delta) |> clamp())

  @doc "Rufverlust für das Versenken eines Schiffs dieser Art: Händler 8, Jäger 5, sonst 0."
  @spec penalty(atom()) :: non_neg_integer()
  def penalty(:merchant), do: 8
  def penalty(:hunter), do: 5
  def penalty(_other), do: 0

  @doc "Jeder Wert nähert sich um 1 der 0 (Zeit heilt langsam)."
  @spec decay(rep()) :: rep()
  def decay(rep), do: Map.new(rep, fn {nation, v} -> {nation, v - sign(v)} end)

  @doc "Startruf: Heimatnation +20, alle anderen 0 (ohne Nation alles 0), mit allen fünf Nationen."
  @spec start(atom() | nil) :: rep()
  def start(home) do
    Map.new(Nations.all(), fn n -> {n, if(n == home, do: @home_start, else: 0)} end)
  end

  defp clamp(v), do: v |> max(@min) |> min(@max)
  defp sign(v) when v > 0, do: 1
  defp sign(v) when v < 0, do: -1
  defp sign(_), do: 0
end
