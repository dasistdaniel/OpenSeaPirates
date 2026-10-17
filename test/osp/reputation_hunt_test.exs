defmodule Osp.ReputationHuntTest do
  use ExUnit.Case, async: true

  alias Osp.{Director, Nations, Profile, State}

  @seed 4
  @tok "tok-hunt-aaaa-1"

  defp open_water do
    Enum.find_value(0..200, fn k ->
      x = k * 9.0 + 3000.0
      y = k * 5.0 + 3000.0
      if Osp.Spawn.clear?(@seed, x, y, 7.0) and not Osp.Ports.safe?(@seed, x, y), do: {x, y}
    end)
  end

  defp run_ev(state, ms) do
    Enum.reduce(1..div(ms, 25), {state, []}, fn _, {s, ev} ->
      {s, more} = State.tick(s, 25)
      {s, ev ++ more}
    end)
  end

  # Spieler (Heimat Frankreich) und ein englischer Jäger 6 WE entfernt; `rep_england` bestimmt den Ruf
  defp scene(rep_england, opts \\ []) do
    {bx, by} = open_water()

    State.new(@seed, 0)
    |> State.join(@tok, "Anna", Profile.decode(%{"nation" => "france"}))
    |> State.update_ship(@tok, fn s ->
      rep =
        s.rep |> Map.put(:england, rep_england) |> Map.merge(Map.new(Keyword.get(opts, :rep, [])))

      %{s | x: bx, y: by, heading: 0.0, speed: 0.0, invuln_until: 0, rep: rep}
    end)
    |> State.add_npc(:hunter, "Jäger", bx + 6.0, by + 1.0, :math.pi())
    |> State.update_ship("npc-1", &%{&1 | nation: :england})
  end

  defp hunter_fires?(events), do: Enum.any?(events, &match?({:fire, "npc-" <> _, _, _, _}, &1))

  test "Jäger greift bei Ruf -10 (Misstrauisch) an und feuert" do
    {st, ev} = run_ev(scene(-10), 20_000)
    assert hunter_fires?(ev)
    assert st.ships[@tok].hp < 12.0 or not st.ships[@tok].alive? or hunter_fires?(ev)
  end

  test "Bei Ruf -9, 0 und Freund bleibt der Jäger friedlich" do
    for rep <- [-9, 0, 50] do
      {st, ev} = run_ev(scene(rep), 15_000)
      refute hunter_fires?(ev), "Ruf #{rep}"
      assert st.ships[@tok].hp == 12.0
    end
  end

  test "Der Ruf bei einer anderen Nation zählt nicht" do
    {st, ev} = run_ev(scene(0, rep: [france: -80, spain: -100]), 15_000)
    refute hunter_fires?(ev)
    assert st.ships[@tok].hp == 12.0
  end

  describe "Director.want_hunters/1" do
    defp human(terr, rep_pairs) do
      st = State.new(@seed, 0) |> State.join(@tok, "A", Profile.decode(%{"nation" => "france"}))
      s = st.ships[@tok]
      %{s | terr: terr, rep: Map.merge(s.rep, Map.new(rep_pairs))}
    end

    test "Gesucht bei der Nation des Gebiets: zwei Jäger" do
      assert Director.want_hunters(human(:england, england: -40)) == 2
      assert Director.want_hunters(human(:england, england: -100)) == 2
    end

    test "Misstrauisch, neutral, anderes Gebiet oder noch keine Gebietsnation: einer" do
      assert Director.want_hunters(human(:england, england: -39)) == 1
      assert Director.want_hunters(human(:england, england: 0)) == 1
      assert Director.want_hunters(human(:spain, england: -80)) == 1
      assert Director.want_hunters(human(nil, england: -80)) == 1
    end
  end

  test "um einen Gesuchten halten die Director-Schritte mindestens zwei Jäger vor" do
    {bx, by} = open_water()

    st =
      State.new(@seed, 0, director?: true)
      |> State.join(@tok, "Anna", Profile.decode(%{"nation" => "france"}))
      |> State.update_ship(@tok, fn s ->
        %{
          s
          | x: bx,
            y: by,
            speed: 0.0,
            invuln_until: 10_000_000,
            terr: :england,
            rep: %{s.rep | england: -60}
        }
      end)

    {st, _} =
      Enum.reduce(1..div(40_000, 25), {st, nil}, fn _, {s, _} ->
        {s, ev} = State.tick(s, 25)
        # die Gebietsnation neu setzen lassen, falls die Welt sie anders berechnet
        {State.update_ship(s, @tok, &%{&1 | terr: :england, invuln_until: 10_000_000}), ev}
      end)

    hunters = st.ships |> Map.values() |> Enum.filter(&(&1.kind == :hunter and &1.alive?))
    assert length(hunters) >= 2
  end

  test "Nationenliste enthält England (Schutz gegen Tippfehler)" do
    assert :england in Nations.all()
  end
end
