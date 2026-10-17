defmodule Osp.ReputationStateTest do
  use ExUnit.Case, async: true

  alias Osp.{Nations, Profile, Reputation, State, World}

  @seed 4
  @tok "tok-rep-aaaa-1"

  defp scene(nation \\ :france) do
    State.new(@seed, 0)
    |> State.join(@tok, "Anna", Profile.decode(%{"nation" => Atom.to_string(nation)}))
  end

  describe "Profil" do
    test "decode/1: rep wird auf die fünf Nationen und -100..100 begrenzt" do
      p =
        Profile.decode(%{
          "rep" => %{"spain" => 500, "xyz" => 9, "france" => "x", "england" => -500}
        })

      assert p["rep"] |> Map.keys() |> Enum.sort() ==
               ~w(england france netherlands portugal spain)

      assert p["rep"]["spain"] == 100
      assert p["rep"]["england"] == -100
      assert p["rep"]["france"] == 0
      assert p["rep"]["portugal"] == 0
    end

    test "Profile.new/0: alle fünf Werte 0" do
      assert Profile.new()["rep"] |> Map.values() |> Enum.all?(&(&1 == 0))
      assert map_size(Profile.new()["rep"]) == 5
    end

    test "altes Profil mit Nation, ohne rep: Heimat +20, sonst 0; nichts geht verloren" do
      old = %{"v" => 2, "nation" => "france", "gold" => 77, "class" => "brigg"}
      ship = State.join(State.new(@seed, 0), @tok, "A", old).ships[@tok]
      assert ship.rep.france == 20
      assert ship.rep |> Map.delete(:france) |> Map.values() |> Enum.all?(&(&1 == 0))
      assert ship.gold == 77 and ship.class == :brigg
    end

    test "ausdrückliches rep überschreibt den Startruf" do
      p = %{"nation" => "france", "rep" => %{"france" => -50}}
      assert State.join(State.new(@seed, 0), @tok, "A", p).ships[@tok].rep.france == -50
    end

    test "Profil ganz ohne Nation: alles 0" do
      ship = State.join(State.new(@seed, 0), @tok, "A", %{"gold" => 5}).ships[@tok]
      assert ship.rep |> Map.values() |> Enum.all?(&(&1 == 0))
    end

    test "Rundlauf from_ship -> decode -> apply" do
      ship = scene().ships[@tok]
      ship = %{ship | rep: Reputation.add(ship.rep, :england, -15)}

      again =
        State.join(State.new(@seed, 0), "tok-rep-aaaa-2", "B", Profile.from_ship(ship)).ships[
          "tok-rep-aaaa-2"
        ]

      assert again.rep == ship.rep
    end
  end

  describe "World" do
    test "neue Nation setzt den Startruf" do
      id = "w" <> Integer.to_string(System.unique_integer([:positive]))
      start_supervised!({World, id: id, seed: @seed, bots: 0, tick_ms: 25}, id: id)
      tok = "tok-rep-" <> Integer.to_string(System.unique_integer([:positive])) <> "-x"
      {:ok, _} = World.join(id, tok, "Anna", self(), nation: :spain)
      assert World.state(id).ships[tok].rep.spain == 20
    end
  end

  describe "State.add_rep/4 und rep_of/2" do
    test "senkt, begrenzt und meldet das Ereignis" do
      {st, ev} = State.add_rep(scene(), @tok, :england, -8)
      assert State.rep_of(st.ships[@tok], :england) == -8
      assert [{:rep, @tok, :england, -8, -8, _x, _y}] = ev

      {st2, ev2} = State.add_rep(st, @tok, :england, -500)
      assert State.rep_of(st2.ships[@tok], :england) == -100
      assert [{:rep, @tok, :england, -92, -100, _, _}] = ev2
    end

    test "delta 0, am Limit oder unbekannte ID: nichts ändert sich, kein Ereignis" do
      st = scene()
      assert {^st, []} = State.add_rep(st, @tok, :england, 0)
      assert {^st, []} = State.add_rep(st, "gibtsnicht", :england, -5)

      {low, _} = State.add_rep(st, @tok, :england, -500)
      assert {^low, []} = State.add_rep(low, @tok, :england, -5)
    end
  end

  describe "Schnappschuss" do
    test "me.rp: fünf Zahlen in der Reihenfolge der Nationen, JSON-tauglich" do
      st = scene()
      {st, _} = State.add_rep(st, @tok, :england, -8)
      snap = State.snapshot_for(st, @tok, [])
      assert length(snap.me.rp) == 5
      assert Enum.at(snap.me.rp, Enum.find_index(Nations.all(), &(&1 == :england))) == -8
      assert Enum.at(snap.me.rp, Enum.find_index(Nations.all(), &(&1 == :france))) == 20
      assert {:ok, _} = Jason.encode(snap)
    end

    test "rep-Ereignis geht als Liste mit Nation als String hinaus" do
      st = scene()
      s = st.ships[@tok]
      snap = State.snapshot_for(st, @tok, [{:rep, @tok, :england, -8, -8, s.x, s.y}])
      pub = State.public_id(@tok)
      assert [["rep", ^pub, "england", -8, -8, _, _]] = snap.ev
    end
  end

  describe "Rückgang" do
    defp run(state, ms),
      do: Enum.reduce(1..div(ms, 25), state, fn _, s -> elem(State.tick(s, 25), 0) end)

    test "alle 10 Minuten Spielzeit um 1 zur 0, davor nicht" do
      st = scene()
      {st, _} = State.add_rep(st, @tok, :england, -8)
      st = %{st | time: 599_900}
      st = run(st, 50)
      assert st.ships[@tok].rep.england == -8 and st.ships[@tok].rep.france == 20

      st = run(st, 75)
      assert st.ships[@tok].rep.england == -7 and st.ships[@tok].rep.france == 19
    end
  end
end
