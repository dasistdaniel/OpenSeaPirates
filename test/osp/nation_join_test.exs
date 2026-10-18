defmodule Osp.NationJoinTest do
  use ExUnit.Case, async: true

  alias Osp.{Nations, Ports, Profile, Profiles, Spawn, State, World}
  alias Osp.Web.Socket

  @seed 4

  defp token, do: "tok-" <> Integer.to_string(System.unique_integer([:positive])) <> "-xxxx"

  defp start_world do
    id = "n" <> Integer.to_string(System.unique_integer([:positive]))
    start_supervised!({World, id: id, seed: @seed, bots: 0, tick_ms: 25}, id: id)
    id
  end

  defp socket(world) do
    {:ok, state} = Socket.init([])
    %{state | world: world}
  end

  defp send_json(state, map), do: Socket.handle_in({Jason.encode!(map), [opcode: :text]}, state)

  defp join(state, tok, extra \\ %{}),
    do: send_json(state, Map.merge(%{t: "join", token: tok, name: "Anna"}, extra))

  describe "Socket: Nationswahl" do
    test "neues Token ohne Nation: nation_required mit fünf Nationen, Wahl danach tritt bei" do
      w = start_world()
      tok = token()

      assert {:push, {:text, json}, st} = join(socket(w), tok)

      assert %{"t" => "error", "reason" => "nation_required", "nations" => nations} =
               Jason.decode!(json)

      assert st.id == nil
      assert Enum.map(nations, & &1["id"]) == ~w(spain england france netherlands portugal)

      assert Enum.all?(
               nations,
               &(is_binary(&1["name"]) and &1["color"] =~ "#" and &1["bonus"] != "")
             )

      assert {:push, {:text, json2}, st} = join(st, tok, %{nation: "england"})
      assert %{"t" => "welcome"} = Jason.decode!(json2)
      assert st.id == tok
      assert World.state(w).ships[tok].nation == :england
    end

    test "ungültige Nation vom Client wird abgelehnt, nie ein Absturz" do
      w = start_world()

      for bad <- ["xyz", 7, ["spain"], %{}, "", nil, true] do
        assert {:push, {:text, json}, st} = join(socket(w), token(), %{nation: bad})
        assert %{"reason" => "nation_required"} = Jason.decode!(json)
        assert st.id == nil
      end
    end

    test "bestehendes Profil mit Nation: mitgeschickte andere Nation ändert nichts" do
      w = start_world()
      tok = token()
      Profiles.put(tok, Profile.decode(%{"nation" => "france", "gold" => 5}))

      assert {:push, {:text, json}, _} = join(socket(w), tok, %{nation: "spain"})
      assert %{"t" => "welcome"} = Jason.decode!(json)
      ship = World.state(w).ships[tok]
      assert ship.nation == :france and ship.gold == 5
    end

    test "bestehendes Profil mit Nation braucht keine Wahl" do
      w = start_world()
      tok = token()
      Profiles.put(tok, Profile.decode(%{"nation" => "portugal"}))
      assert {:push, {:text, json}, _} = join(socket(w), tok)
      assert %{"t" => "welcome"} = Jason.decode!(json)
    end

    test "altes Profil ohne Nation: Wahl nötig, Gold und Klasse bleiben erhalten" do
      w = start_world()
      tok = token()
      Profiles.put(tok, %{"v" => 1, "gold" => 123, "bank" => 9, "class" => "klipper"})

      assert {:push, {:text, json}, st} = join(socket(w), tok)
      assert %{"reason" => "nation_required"} = Jason.decode!(json)

      assert {:push, {:text, _}, _} = join(st, tok, %{nation: "spain"})
      ship = World.state(w).ships[tok]
      assert ship.gold == 123 and ship.bank == 9 and ship.class == :klipper
      assert ship.nation == :spain
    end
  end

  describe "Neu anfangen" do
    defp played(tok) do
      Profiles.put(
        tok,
        Profile.decode(%{
          "nation" => "france",
          "gold" => 500,
          "bank" => 200,
          "class" => "klipper",
          "kills" => 7
        })
      )
    end

    test "reset ohne Nation fragt nur nach der Nation, nichts geht verloren" do
      w = start_world()
      tok = token()
      played(tok)

      assert {:push, {:text, json}, st} = join(socket(w), tok, %{reset: true})
      assert %{"reason" => "nation_required"} = Jason.decode!(json)
      assert st.id == nil
      assert Profiles.get(tok)["gold"] == 500
    end

    test "nach der Wahl: neues Profil mit der neuen Nation, alles andere zurückgesetzt" do
      w = start_world()
      tok = token()
      played(tok)

      {:push, _, st} = join(socket(w), tok, %{reset: true})
      assert {:push, {:text, json}, st} = join(st, tok, %{nation: "england"})
      assert %{"t" => "welcome"} = Jason.decode!(json)
      assert st.id == tok

      ship = World.state(w).ships[tok]
      assert ship.nation == :england
      assert ship.gold == 0 and ship.bank == 0 and ship.class == :schaluppe and ship.kills == 0
    end

    test "Abbruch nach der Frage (neue Verbindung ohne reset): altes Profil gilt weiter" do
      w = start_world()
      tok = token()
      played(tok)

      {:push, _, _} = join(socket(w), tok, %{reset: true})
      assert {:push, {:text, json}, _} = join(socket(w), tok)
      assert %{"t" => "welcome"} = Jason.decode!(json)
      assert World.state(w).ships[tok].gold == 500
    end

    test "während das Schiff in der Welt ist: wird entfernt und neu erzeugt" do
      w = start_world()
      tok = token()
      played(tok)
      {:push, _, _} = join(socket(w), tok)
      assert World.state(w).ships[tok].gold == 500

      {:push, _, st} = join(socket(w), tok, %{reset: true})
      {:push, _, _} = join(st, tok, %{nation: "spain"})
      assert World.state(w).ships[tok].gold == 0
      assert World.state(w).ships[tok].nation == :spain
    end
  end

  describe "World.join/5" do
    test "nation: setzt die Heimatnation" do
      w = start_world()
      tok = token()
      {:ok, _} = World.join(w, tok, "Anna", self(), nation: :spain)
      assert World.state(w).ships[tok].nation == :spain
    end

    test "ohne Wunsch und ohne Profil: gültige Nation aus dem Token-Hash" do
      w = start_world()
      tok = token()
      {:ok, _} = World.join(w, tok, "Anna")
      assert World.state(w).ships[tok].nation in Nations.all()
    end

    test "Beitritt speichert die Nation sofort im Profil" do
      w = start_world()
      tok = token()
      {:ok, _} = World.join(w, tok, "Anna", self(), nation: :portugal)
      assert Profiles.get(tok)["nation"] == "portugal"
    end

    test "Wiederverbinden ändert die Nation nicht" do
      w = start_world()
      tok = token()
      {:ok, _} = World.join(w, tok, "Anna", self(), nation: :spain)
      {:ok, _} = World.join(w, tok, "Anna", self(), nation: :england)
      assert World.state(w).ships[tok].nation == :spain
    end
  end

  describe "Spawn im Heimatgebiet" do
    defp near_home_port?(state, ship, nation) do
      ship.x
      |> then(&Ports.near(state.seed, &1, ship.y, 25.0))
      |> Enum.any?(fn p ->
        d = :math.sqrt(:math.pow(p.x - ship.x, 2) + :math.pow(p.y - ship.y, 2))
        Nations.of_port(state.seed, p) == nation and d > Ports.safe_radius()
      end)
    end

    test "neues Schiff startet nahe einem Hafen seiner Nation, außerhalb der Schutzzone" do
      for nation <- Nations.all() do
        st =
          State.join(
            State.new(@seed, 0),
            "t-aaaaaaaa",
            "A",
            Profile.decode(%{"nation" => Atom.to_string(nation)})
          )

        ship = st.ships["t-aaaaaaaa"]
        assert ship.nation == nation
        assert near_home_port?(st, ship, nation)
        assert Spawn.clear?(@seed, ship.x, ship.y)
      end
    end

    test "Wiederauftauchen: wieder im Heimatgebiet" do
      st =
        State.join(
          State.new(@seed, 0),
          "t-aaaaaaaa",
          "A",
          Profile.decode(%{"nation" => "england"})
        )

      {_st, x, y, _h} = State.respawn_point(st, "t-aaaaaaaa")
      assert near_home_port?(st, %{x: x, y: y}, :england)
    end

    test "spawn_for/5 fällt ohne Hafen im Radius oder ohne Nation auf den alten Spawn zurück" do
      st = State.new(@seed, 0)
      rng = :rand.seed_s(:exsss, 7)

      {x, y, _h, _} = State.spawn_for(st, :england, {0.0, 0.0}, rng, max_radius: 1.0)
      assert Spawn.clear?(@seed, x, y)

      {x2, y2, _h, _} = State.spawn_for(st, nil, {0.0, 0.0}, rng)
      assert Spawn.clear?(@seed, x2, y2)
    end
  end
end
