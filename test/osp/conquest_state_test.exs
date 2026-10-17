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

  describe "Rückfall im Spielzustand" do
    defp edge_port_state(wall_ms, rev_at \\ 0) do
      a =
        Osp.Ports.near(@seed, 0.0, 0.0, 1500.0)
        |> Enum.find(&(Osp.Conquest.neighbors(@seed, &1) != []))

      ns = Osp.Conquest.neighbors(@seed, a)

      x =
        Enum.find(
          Nations.all(),
          &(&1 not in Enum.map([a | ns], fn p -> Nations.base_of_port(@seed, p) end))
        )

      st = State.new(@seed, 0, territory: %{a.id => %{owner: x, since: 0}})
      {%{st | wall_ms: wall_ms, rev_at: rev_at}, a, x}
    end

    test "Randlage nach 31 Minuten: Eintrag entfernt, Ereignis, Ausgangsnation gilt wieder" do
      {st, a, x} = edge_port_state(31 * 60_000)
      {st, ev} = State.tick(st, 25)
      assert st.owners == %{} and st.captured_at == %{}
      back = Nations.base_of_port(@seed, a)
      assert Enum.any?(ev, &match?({:reverted, _, ^back, ^x, _, _}, &1))
      assert State.port_nation(st, a) == back
    end

    test "geprüft wird nur alle 60 s, nicht jeden Schritt" do
      {st, _a, _x} = edge_port_state(31 * 60_000, 31 * 60_000 - 5_000)
      {st, ev} = State.tick(st, 25)
      assert map_size(st.owners) == 1
      refute Enum.any?(ev, &match?({:reverted, _, _, _, _, _}, &1))

      {st, ev} = State.tick(%{st | wall_ms: st.rev_at + 60_001}, 25)
      assert st.owners == %{}
      assert Enum.any?(ev, &match?({:reverted, _, _, _, _, _}, &1))
    end

    test "29 Minuten: bleibt; Uhr springt zurück: kein Absturz, kein Rückfall" do
      {st, _, _} = edge_port_state(29 * 60_000)
      {st, _} = State.tick(st, 25)
      assert map_size(st.owners) == 1

      {st2, _, _} = edge_port_state(31 * 60_000, 40 * 60_000)
      {st2, ev} = State.tick(st2, 25)
      assert map_size(st2.owners) == 1 and st2.rev_at == 31 * 60_000
      refute Enum.any?(ev, &match?({:reverted, _, _, _, _, _}, &1))
    end
  end

  describe "Speichern über die Welt" do
    defp tmp_dir do
      dir = Path.join(System.tmp_dir!(), "osp_conq_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)
      dir
    end

    defp start_world_with(tname, id) do
      start_supervised!({World, id: id, seed: @seed, bots: 0, tick_ms: 25, territory: tname},
        id: id
      )
    end

    defp wait_until(id, fun, tries \\ 80) do
      cond do
        fun.(World.state(id)) ->
          :ok

        tries == 0 ->
          flunk("Bedingung nicht erreicht")

        true ->
          assert_receive {:osp_snap, _}, 1_000
          wait_until(id, fun, tries - 1)
      end
    end

    test "Eroberung im laufenden Spiel landet in der Datei; Neustart behält sie, Rückfall löscht sie" do
      dir = tmp_dir()
      tname = :"terr_c_#{System.unique_integer([:positive])}"
      start_supervised!({Territory, name: tname, dir: dir}, id: tname)

      id = "wc" <> Integer.to_string(System.unique_integer([:positive]))
      start_world_with(tname, id)

      p = port()
      tok = "tok-conq-" <> Integer.to_string(System.unique_integer([:positive])) <> "-x"
      {:ok, _} = World.join(id, tok, "Anna", self(), nation: :france)

      # Angriff bei 99,9 % mit Angreifer in der Zone, ohne Verteidiger
      :sys.replace_state(GenServer.whereis(World.via(id)), fn w ->
        {cx, cy} = {:math.cos(p.land), :math.sin(p.land)}

        sim =
          State.update_ship(
            w.sim,
            tok,
            &%{&1 | x: p.x - cx * 5.0, y: p.y - cy * 5.0, speed: 0.0, invuln_until: 0}
          )

        t = sim.time

        sim = %{
          sim
          | assaults: %{
              p.id => %{
                progress: 99.99,
                last_act: t,
                wave_at: t + 1_000_000,
                first_nation: :france
              }
            }
        }

        %{w | sim: sim}
      end)

      wait_until(id, &Map.has_key?(&1.owners, p.id))
      assert World.state(id).owners[p.id] == :france

      :ok = Territory.flush(tname)
      saved = dir |> Path.join("territory.json") |> File.read!() |> Jason.decode!()
      assert saved["ports"][p.id]["owner"] == "france"
      assert saved["ports"][p.id]["since"] > 0

      # Neustart: neuer Territory-Prozess und neue Welt mit derselben Datei
      stop_supervised!(id)
      stop_supervised!(tname)
      t2 = :"terr_c2_#{System.unique_integer([:positive])}"
      start_supervised!({Territory, name: t2, dir: dir}, id: t2)
      id2 = "wc2" <> Integer.to_string(System.unique_integer([:positive]))
      start_world_with(t2, id2)
      assert World.state(id2).owners[p.id] == :france
      assert World.state(id2).captured_at[p.id] == saved["ports"][p.id]["since"]
    end

    test "Rückfall löscht den Eintrag aus dem Speicher" do
      dir = tmp_dir()
      tname = :"terr_r_#{System.unique_integer([:positive])}"
      start_supervised!({Territory, name: tname, dir: dir}, id: tname)

      {_st, a, x} = edge_port_state(0)
      Territory.put(a.id, x, 0, tname)
      assert Map.has_key?(Territory.all(tname), a.id)

      id = "wr" <> Integer.to_string(System.unique_integer([:positive]))
      start_world_with(tname, id)
      {:ok, _} = World.join(id, "tok-rev-aaaa-1", "A", self(), nation: :france)

      # die echte Wanduhr (nach 1970 gemessen) liegt weit über 30 Minuten nach `since: 0`
      wait_until(id, &(not Map.has_key?(&1.owners, a.id)))
      _ = Territory.all(tname)
      refute Map.has_key?(Territory.all(tname), a.id)
    end
  end
end
