defmodule Osp.ConquestStateTest do
  use ExUnit.Case, async: true

  alias Osp.{Fort, Nations, Profile, Quests, State, Territory, World}

  @seed 4
  @tok "geheimes-token-conq-1"

  defp port, do: Nations.nearest_port_of(@seed, :england, {0.0, 0.0}, 1500.0)

  defp territory(owner \\ :spain, since \\ 5), do: %{port().id => %{owner: owner, since: since}}

  # Spieler (Heimat Frankreich) am Hafen, mit Rufwerten und optional Eroberung des Hafens durch Spanien
  defp scene(rep \\ %{}, terr \\ territory()) do
    p = port()

    State.new(@seed, 0, territory: terr)
    |> State.join(@tok, "Anna", Profile.decode(%{"nation" => "france"}))
    |> State.update_ship(@tok, fn s ->
      %{s | x: p.x + 1.0, y: p.y, speed: 0.0, invuln_until: 0, rep: Map.merge(s.rep, rep)}
    end)
  end

  describe "State.new/3 mit Eroberungen" do
    test "territory setzt owners und captured_at, sonst leer" do
      st = State.new(@seed, 0, territory: territory(:spain, 99))
      assert st.owners == %{port().id => :spain}
      assert st.captured_at == %{port().id => 99}

      plain = State.new(@seed, 0)
      assert plain.owners == %{} and plain.captured_at == %{} and plain.wall_ms == 0
    end

    test "port_nation/2 folgt dem Besitzer, sonst der Ausgangsnation" do
      st = State.new(@seed, 0, territory: territory())
      assert State.port_nation(st, port()) == :spain
      assert State.port_nation(State.new(@seed, 0), port()) == :england
    end
  end

  describe "Nation des Hafens folgt dem Besitzer" do
    test "Schnappschuss: Hafeneintrag und Gebiet unter dem Spieler" do
      st = scene()
      {st, _} = State.tick(%{st | time: 475}, 25)
      snap = State.snapshot_for(st, @tok, [])
      entry = Enum.find(snap.ports, fn [id | _] -> id == port().id end)
      assert Enum.at(entry, 5) == "spain"
      assert snap.me.tn == "spain"
    end

    test "NPCs am Hafen tragen die neue Nation" do
      st = State.new(@seed, 0, territory: territory())
      p = port()
      st = State.add_npc(st, :merchant, "H", p.x + 0.5, p.y, 0.0)
      assert st.ships |> Map.values() |> hd() |> Map.fetch!(:nation) == :spain
    end

    test "Spawn: Spieler der neuen Nation starten dort, Spieler der alten nicht mehr" do
      st = State.new(@seed, 0, territory: territory())
      rng = :rand.seed_s(:exsss, 3)
      p = port()

      {x, y, _, _} = State.spawn_for(st, :spain, {p.x, p.y}, rng, max_radius: 30.0)
      assert :math.sqrt(:math.pow(x - p.x, 2) + :math.pow(y - p.y, 2)) <= 30.0

      # England hat hier keinen Hafen mehr im Umkreis von 1 WE: der Hafen zählt nicht für England
      assert Nations.nearest_port_of(@seed, :england, {p.x, p.y}, 1.0, st.owners) == nil
    end

    test "Andocken: docked.nation ist der Besitzer" do
      st = scene()
      {st, :ok} = State.dock(st, @tok)
      assert st.ships[@tok].docked.nation == :spain
    end
  end

  describe "Gesucht und Besitzerwechsel" do
    test "bei der alten Nation Gesuchte werden nicht mehr gesperrt oder beschossen" do
      st = scene(%{england: -80})
      {st, :ok} = State.dock(st, @tok)
      view = State.shop_view(st, @tok)
      refute Map.get(view, :hostile)
      assert {_, {:error, reason}} = State.shop(st, @tok, {:deposit, 0})
      refute reason == :hostile

      # Fort: kein Schuss, keine Warnung (Spieler ist nicht angedockt)
      undocked = State.update_ship(st, @tok, &%{&1 | docked: nil})
      {st2, ev} = Fort.step(%{undocked | time: 2_000})
      assert st2.balls == []
      refute Enum.any?(ev, &match?({:fort_warn, _, _, _, _}, &1))
    end

    test "bei der neuen Nation Gesuchte werden gesperrt und beschossen" do
      st = scene(%{spain: -80})
      {docked, :ok} = State.dock(st, @tok)
      assert State.shop_view(docked, @tok).hostile == true
      assert {_, {:error, :hostile}} = State.shop(docked, @tok, {:deposit, 10})

      {_, ev} = Fort.step(%{st | time: 2_000})
      assert Enum.any?(ev, &match?({:fort_warn, _, @tok, _, _}, &1))
    end

    test "Schutzzone: für bei der neuen Nation Gesuchte ungeschützt, für bei der alten nicht" do
      wanted_new = scene(%{spain: -80})
      assert State.safe_for?(wanted_new, wanted_new.ships[@tok]) == false

      wanted_old = scene(%{england: -80})
      assert State.safe_for?(wanted_old, wanted_old.ships[@tok]) == true
    end
  end

  describe "Quests nach dem Besitzerwechsel" do
    test "Angebote des Hafens tragen die neue Nation" do
      st = scene()
      {st, :ok} = State.dock(st, @tok)
      view = State.shop_view(st, @tok)
      assert Enum.all?(view.quests.offers, &(&1.n == "spain"))

      direct = Quests.offers(@seed, port(), 0, %{port().id => :spain})
      assert Enum.all?(direct, &(&1.nation == :spain))
      assert Enum.all?(Quests.offers(@seed, port(), 0), &(&1.nation == :england))
    end

    test "angenommene Quest mit alter Nation bleibt abgebbar und gibt Ruf bei der alten Nation" do
      p = port()

      offer =
        Enum.find_value(0..60, fn w ->
          Enum.find(Quests.offers(@seed, p, w), &(&1.kind == :hunt))
        end)

      q = %{Quests.to_quest(offer) | nation: :england, have: offer.need}

      st = scene()
      st = State.update_ship(st, @tok, &%{&1 | quests: [q]})
      {st, :ok} = State.dock(st, @tok)
      assert {st, {:ok, _view, _ev}} = State.turn_in(st, @tok)
      assert st.ships[@tok].rep.england == offer.rep
      assert st.ships[@tok].quests == []
    end
  end

  describe "World" do
    test "lädt gespeicherte Eroberungen und setzt die Wanduhr" do
      tname = :"terr_w_#{System.unique_integer([:positive])}"
      start_supervised!({Territory, name: tname, dir: nil}, id: tname)
      Territory.put(port().id, :spain, 7, tname)
      _ = Territory.all(tname)

      id = "w" <> Integer.to_string(System.unique_integer([:positive]))

      start_supervised!({World, id: id, seed: @seed, bots: 0, tick_ms: 25, territory: tname},
        id: id
      )

      first = World.state(id)
      assert first.owners == %{port().id => :spain}
      assert first.captured_at == %{port().id => 7}

      # nach dem ersten Takt (Schnappschuss kommt an) steht die Wanduhr
      {:ok, _} = World.join(id, "p-wall", "A")
      assert_receive {:osp_snap, _}, 1_000
      later = World.state(id)
      assert later.wall_ms > 0
      assert later.wall_ms >= first.wall_ms
    end
  end
end
