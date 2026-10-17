defmodule Osp.ReputationKillTest do
  use ExUnit.Case, async: true

  alias Osp.{Combat, Nations, Profile, State}

  @seed 4
  @tok "tok-kill-aaaa-1"

  defp open_water do
    Enum.find_value(0..200, fn k ->
      x = k * 9.0 + 3000.0
      y = k * 5.0 + 3000.0
      if Osp.Spawn.clear?(@seed, x, y, 7.0) and not Osp.Ports.safe?(@seed, x, y), do: {x, y}
    end)
  end

  # Spieler (Heimat Frankreich) und ein englischer NPC der Art `kind` 3 WE südlich
  defp scene(kind, opts \\ []) do
    {bx, by} = open_water()

    st =
      State.new(@seed, 0)
      |> State.join(@tok, "Anna", Profile.decode(%{"nation" => "france"}))
      |> State.update_ship(@tok, &%{&1 | x: bx, y: by, heading: 0.0, speed: 0.0, invuln_until: 0})
      |> State.add_npc(kind, "NPC", bx, by + 3.0, 0.0)
      |> State.update_ship("npc-1", fn s ->
        %{s | nation: Keyword.get(opts, :nation, :england), invuln_until: 0}
      end)

    st
  end

  defp kill(st, by \\ @tok) do
    npc = st.ships["npc-1"]
    Combat.hurt(st, "npc-1", 1000.0, by, npc.x, npc.y)
  end

  defp rep_events(events), do: Enum.filter(events, &match?({:rep, _, _, _, _, _, _}, &1))

  test "Händler versenkt: -8 nur bei seiner Nation, andere unverändert, Ereignis" do
    {st, ev} = kill(scene(:merchant))
    rep = st.ships[@tok].rep
    assert rep.england == -8
    assert rep.france == 20
    assert rep |> Map.drop([:england, :france]) |> Map.values() |> Enum.all?(&(&1 == 0))
    assert [{:rep, @tok, :england, -8, -8, _, _}] = rep_events(ev)
    assert st.ships[@tok].kills == 1
  end

  test "Jäger ohne Jagd auf den Spieler: -5" do
    {st, _} = kill(scene(:hunter))
    assert st.ships[@tok].rep.england == -5
  end

  test "Selbstverteidigung: Jäger, der gerade Jagd auf den Spieler macht, kostet nichts" do
    st = scene(:hunter)
    st = State.update_ship(st, "npc-1", &%{&1 | hunting: {@tok, st.time}})
    {st, ev} = kill(st)
    assert st.ships[@tok].rep.england == 0
    assert rep_events(ev) == []
    assert st.ships[@tok].kills == 1
  end

  test "Selbstverteidigung: Jäger hat den Spieler vor 10 s getroffen -> nichts, vor 20 s -> -5" do
    st = scene(:hunter)
    recent = State.update_ship(st, @tok, &%{&1 | attacked_at: %{"npc-1" => st.time - 10_000}})
    {r1, _} = kill(%{recent | time: st.time})
    assert r1.ships[@tok].rep.england == 0

    old = State.update_ship(st, @tok, &%{&1 | attacked_at: %{"npc-1" => st.time - 20_000}})
    {r2, _} = kill(old)
    assert r2.ships[@tok].rep.england == -5
  end

  test "Veraltetes hunting (über 15 s) zählt nicht als Notwehr" do
    st = scene(:hunter)
    st = %{st | time: 100_000}
    st = State.update_ship(st, "npc-1", &%{&1 | hunting: {@tok, 80_000}})
    {st, _} = kill(st)
    assert st.ships[@tok].rep.england == -5
  end

  test "Händler wehrt sich nach Angriff des Spielers: kein Notwehr-Fall, -8" do
    st = scene(:merchant)
    st = State.update_ship(st, @tok, &%{&1 | attacked_at: %{"npc-1" => st.time}})
    st = State.update_ship(st, "npc-1", &%{&1 | hunting: {@tok, st.time}})
    {st, _} = kill(st)
    assert st.ships[@tok].rep.england == -8
  end

  test "Hunting eines Jägers auf einen anderen Spieler ist keine Notwehr" do
    st = scene(:hunter)
    st = State.update_ship(st, "npc-1", &%{&1 | hunting: {"anderer-spieler", st.time}})
    {st, _} = kill(st)
    assert st.ships[@tok].rep.england == -5
  end

  test "Kein Killer (Riff, Brand): keine Rufänderung" do
    {st, ev} = kill(scene(:merchant), nil)
    assert st.ships[@tok].rep.england == 0
    assert rep_events(ev) == []
  end

  test "NPC ohne Nation kostet nichts" do
    {st, ev} = kill(scene(:merchant, nation: nil))
    assert st.ships[@tok].rep.england == 0
    assert rep_events(ev) == []
  end

  test "Rufboden: bei -100 sinkt nichts weiter, kein Ereignis" do
    st = scene(:merchant)
    st = State.update_ship(st, @tok, &%{&1 | rep: %{&1.rep | england: -100}})
    {st, ev} = kill(st)
    assert st.ships[@tok].rep.england == -100
    assert rep_events(ev) == []
  end

  test "Tote Spieler als Killer verlieren keinen Ruf mehr" do
    st = scene(:merchant)
    st = State.update_ship(st, @tok, &%{&1 | alive?: false})
    {st, ev} = kill(st)
    assert st.ships[@tok].rep.england == 0
    assert rep_events(ev) == []
  end

  describe "Zustandsfelder in der Simulation" do
    defp run(state, ms),
      do: Enum.reduce(1..div(ms, 25), state, fn _, s -> elem(State.tick(s, 25), 0) end)

    test "kämpfender Jäger setzt hunting auf den Spieler" do
      st = scene(:hunter)
      # der Jäger gehört zu England; der Spieler ist dort bereits Misstrauisch oder schlechter
      st = State.update_ship(st, @tok, &%{&1 | rep: %{&1.rep | england: -20}})
      st = run(st, 2_000)
      assert %{hunting: {@tok, _t}} = st.ships["npc-1"]
    end

    test "ein Jäger ohne Gegner hat hunting nil; Händler setzen es nie" do
      st = scene(:hunter)
      st = State.update_ship(st, @tok, &%{&1 | x: &1.x + 500.0})
      st = run(st, 1_000)
      assert st.ships["npc-1"].hunting == nil

      m = scene(:merchant)
      {m, _} = Combat.hurt(m, "npc-1", 1.0, @tok, 0.0, 0.0)
      m = run(m, 2_000)
      assert m.ships["npc-1"].hunting == nil
    end

    test "Treffer eines NPC auf den Spieler wird als attacked_at vermerkt" do
      st = scene(:hunter)
      npc = st.ships["npc-1"]
      {st, _} = Combat.hurt(st, @tok, 1.0, "npc-1", npc.x, npc.y)
      assert st.ships[@tok].attacked_at["npc-1"] == st.time

      # Treffer eines Spielers oder Treffer ohne Urheber legt nichts an
      {st2, _} = Combat.hurt(st, @tok, 1.0, nil, 0.0, 0.0)
      assert map_size(st2.ships[@tok].attacked_at) == 1
    end
  end

  test "Nationen-Reihenfolge ist stabil (Schutz gegen Tippfehler in den Tests)" do
    assert :england in Nations.all()
  end
end
