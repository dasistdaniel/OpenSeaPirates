defmodule Osp.PersistenceTest do
  use ExUnit.Case, async: true

  alias Osp.{Profile, Profiles, State, World}

  @tmp System.tmp_dir!()

  defp tmp_dir do
    dir = Path.join(@tmp, "osp_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  defp start_profiles(dir) do
    name = :"profiles_#{System.unique_integer([:positive])}"
    start_supervised!({Profiles, name: name, dir: dir}, id: name)
    name
  end

  defp upgraded_ship do
    st = State.join(State.new(4, 0), "a", "Anna")

    State.update_ship(st, "a", fn s ->
      %{
        s
        | gold: 321,
          bank: 1_234,
          class: :fregatte,
          upgrades: %{cannons: 2, hull: 3, sails: 1},
          ammo: %{chain: 7, fire: 12},
          kills: 5,
          deaths: 2
      }
    end).ships["a"]
  end

  # --- Profile (rein) -------------------------------------------------------------------

  test "Spielstand aus dem Schiff und zurück: alles bleibt erhalten, Werte werden neu berechnet" do
    profile = Profile.from_ship(upgraded_ship())
    assert {:ok, _} = Jason.encode(profile)
    assert profile["class"] == "fregatte" and profile["gold"] == 321 and profile["bank"] == 1_234

    st = State.join(State.new(4, 0), "b", "Ben", profile)
    s = st.ships["b"]
    assert s.class == :fregatte and s.upgrades == %{cannons: 2, hull: 3, sails: 1}
    assert s.gold == 321 and s.bank == 1_234 and s.ammo == %{chain: 7, fire: 12}
    assert s.kills == 5 and s.deaths == 2
    # Fregatte 28 HP + Rumpf Stufe 3 (+10), voller Rumpf beim Start
    assert s.max_hp == 38 and s.hp == 38.0 and s.radius == 0.45
  end

  test "Kaputte oder manipulierte Spielstände werden bereinigt statt abzustürzen" do
    evil = %{
      "name" => String.duplicate("x", 500),
      "gold" => -50,
      "bank" => 1.0e30,
      "class" => "titanic",
      "upgrades" => %{"cannons" => 99, "hull" => -3, "sails" => "viel"},
      "ammo" => %{"chain" => 5_000, "fire" => nil},
      "kills" => "viele"
    }

    p = Profile.decode(evil)
    assert String.length(p["name"]) == 20
    assert p["gold"] == 0 and p["bank"] == 100_000_000
    assert p["class"] == "schaluppe"
    assert p["upgrades"] == %{"cannons" => 3, "hull" => 0, "sails" => 0}
    assert p["ammo"] == %{"chain" => 40, "fire" => 0}
    assert p["kills"] == 0

    for junk <- [nil, 42, "text", [], %{}] do
      assert %{"class" => "schaluppe", "gold" => 0} = Profile.decode(junk)
    end

    # auch Anwenden auf ein Schiff mit Unsinn geht
    st = State.join(State.new(4, 0), "c", "Cem", evil)
    assert st.ships["c"].class == :schaluppe and st.ships["c"].gold == 0
  end

  # --- Profiles (Datei) ---------------------------------------------------------------------

  test "Speichern und Neustart: Stände kommen aus der JSON-Datei zurück" do
    dir = tmp_dir()
    first = start_profiles(dir)
    Profiles.put("alice", Profile.from_ship(upgraded_ship()), first)
    assert Profiles.get("alice", first)["gold"] == 321
    :ok = Profiles.flush(first)

    assert File.exists?(Path.join(dir, "profiles.json"))

    assert %{"profiles" => %{"alice" => %{"bank" => 1_234}}} =
             dir |> Path.join("profiles.json") |> File.read!() |> Jason.decode!()

    second = start_profiles(dir)
    assert Profiles.get("alice", second)["class"] == "fregatte"
    assert Profiles.count(second) == 1
    assert Profiles.get("unbekannt", second) == nil
  end

  test "Kaputte Datei: Sicherung wird geladen, die kaputte Datei bleibt als .corrupt erhalten" do
    dir = tmp_dir()
    p = start_profiles(dir)
    Profiles.put("a", Profile.new(), p)
    :ok = Profiles.flush(p)
    Profiles.put("a", %{Profile.new() | "gold" => 5}, p)
    :ok = Profiles.flush(p)
    assert File.exists?(Path.join(dir, "profiles.json.bak"))

    File.write!(Path.join(dir, "profiles.json"), "{ das ist kein json")
    q = start_profiles(dir)
    # Stand aus der Sicherung (vorletzter Schreibvorgang)
    assert Profiles.get("a", q)["gold"] == 0
    assert File.read!(Path.join(dir, "profiles.json.corrupt")) == "{ das ist kein json"

    # ohne brauchbare Sicherung: leer starten, kein Absturz
    dir2 = tmp_dir()
    File.write!(Path.join(dir2, "profiles.json"), "kaputt")
    r = start_profiles(dir2)
    assert Profiles.count(r) == 0
  end

  test "Gleicher Stand wird nicht erneut geschrieben, ohne Verzeichnis bleibt alles im Speicher" do
    p = start_profiles(nil)
    Profiles.put("x", Profile.new(), p)
    assert Profiles.get("x", p) == Profile.new()
    assert :ok = Profiles.flush(p)
  end

  # --- Gesamtablauf über die Welt -------------------------------------------------------------

  defp start_world do
    id = "pw" <> Integer.to_string(System.unique_integer([:positive]))
    start_supervised!({World, id: id, seed: 4, bots: 0, tick_ms: 25}, id: id)
    id
  end

  test "Spieler verlässt die Welt, kommt in einer neuen Welt zurück und hat alles wieder" do
    token = "persist-" <> Integer.to_string(System.unique_integer([:positive]))
    w1 = start_world()
    {:ok, _} = World.join(w1, token, "Anna")

    :sys.replace_state(GenServer.whereis(World.via(w1)), fn s ->
      ship = %{s.sim.ships[token] | gold: 777, bank: 50, class: :brigg, kills: 3}
      %{s | sim: State.put_ship(s.sim, token, ship)}
    end)

    World.leave(w1, token)
    _ = World.state(w1)
    assert %{"gold" => 777, "class" => "brigg"} = Profiles.get(token)

    w2 = start_world()
    {:ok, _} = World.join(w2, token, "Anna")
    ship = World.state(w2).ships[token]
    assert ship.gold == 777 and ship.bank == 50 and ship.class == :brigg and ship.kills == 3
  end

  test "Verbindungsabbruch speichert sofort; Autosave sichert Änderungen im laufenden Betrieb" do
    token = "auto-" <> Integer.to_string(System.unique_integer([:positive]))
    w = start_world()
    {:ok, _} = World.join(w, token, "Ben")

    :sys.replace_state(GenServer.whereis(World.via(w)), fn s ->
      ship = %{s.sim.ships[token] | gold: 40}
      %{s | sim: State.put_ship(s.sim, token, ship)}
    end)

    # ca. 100 Ticks à 25 ms abwarten
    for _ <- 1..140, do: assert_receive({:osp_snap, _}, 500)
    assert Profiles.get(token)["gold"] == 40
  end

  test "Neuer Spieler ohne gespeicherten Stand startet frisch" do
    w = start_world()

    {:ok, _} =
      World.join(w, "frisch-" <> Integer.to_string(System.unique_integer([:positive])), "Neu")

    [ship] = for {_, s} <- World.state(w).ships, s.kind == :player, do: s
    assert ship.class == :schaluppe and ship.gold == 0 and ship.bank == 0
  end
end
