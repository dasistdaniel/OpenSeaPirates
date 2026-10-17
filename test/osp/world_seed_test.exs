defmodule Osp.WorldSeedTest do
  use ExUnit.Case, async: true

  alias Osp.{Territory, WorldSeed}

  defp tmp_dir do
    dir = Path.join(System.tmp_dir!(), "osp_seed_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  test "ein eingestellter Seed gewinnt und wird nicht gespeichert" do
    dir = tmp_dir()
    assert WorldSeed.resolve(dir, 777) == 777
    refute File.exists?(Path.join(dir, "seed.txt"))
  end

  test "ohne Einstellung: einmal würfeln, speichern und bei jedem Start wieder lesen" do
    dir = tmp_dir()
    seed = WorldSeed.resolve(dir, nil)
    assert is_integer(seed) and seed >= 1 and seed <= 1_000_000_000
    assert File.read!(Path.join(dir, "seed.txt")) |> String.trim() == Integer.to_string(seed)

    for _ <- 1..5, do: assert(WorldSeed.resolve(dir, nil) == seed)
  end

  test "eine vorhandene Datei bestimmt die Welt (z. B. die bisherige Welt weiterverwenden)" do
    dir = tmp_dir()
    File.write!(Path.join(dir, "seed.txt"), "844057685\n")
    assert WorldSeed.resolve(dir, nil) == 844_057_685
  end

  test "ungültiger Dateiinhalt: neu würfeln und die Datei ersetzen, kein Absturz" do
    for junk <- ["", "abc", "-5", "0", "12.5", "99999999999999999999", "1 2"] do
      dir = tmp_dir()
      File.write!(Path.join(dir, "seed.txt"), junk)
      seed = WorldSeed.resolve(dir, nil)
      assert seed >= 1 and seed <= 1_000_000_000
      assert File.read!(Path.join(dir, "seed.txt")) |> String.trim() == Integer.to_string(seed)
    end
  end

  test "ohne Datenverzeichnis: zufällig, nichts wird geschrieben" do
    seed = WorldSeed.resolve(nil, nil)
    assert seed >= 1 and seed <= 1_000_000_000
  end

  describe "Territory mit Seed" do
    @file_name "territory.json"

    defp start(dir, seed) do
      name = :"terr_s_#{System.unique_integer([:positive])}"
      start_supervised!({Territory, name: name, dir: dir, seed: seed}, id: name)
      name
    end

    test "die Datei trägt den Seed; derselbe Seed lädt die Einträge" do
      dir = tmp_dir()
      t = start(dir, 42)
      Territory.put("port:1,2", :france, 5, t)
      :ok = Territory.flush(t)

      assert dir |> Path.join(@file_name) |> File.read!() |> Jason.decode!() |> Map.fetch!("seed") ==
               42

      stop_supervised!(t)

      t2 = start(dir, 42)
      assert Territory.all(t2) == %{"port:1,2" => %{owner: :france, since: 5}}
    end

    test "anderer Seed: Einträge gehören zu einer anderen Welt und werden nicht geladen, Datei bleibt erhalten" do
      dir = tmp_dir()
      t = start(dir, 42)
      Territory.put("port:1,2", :france, 5, t)
      :ok = Territory.flush(t)
      stop_supervised!(t)

      t2 = start(dir, 99)
      assert Territory.all(t2) == %{}
      kept = dir |> File.ls!() |> Enum.filter(&String.contains?(&1, "seed-42"))
      assert kept != []
    end

    test "Dateien ohne Seed-Feld (älterer Stand) werden weiter geladen" do
      dir = tmp_dir()

      File.write!(
        Path.join(dir, @file_name),
        Jason.encode!(%{
          "v" => 1,
          "ports" => %{"port:1,2" => %{"owner" => "spain", "since" => 3}}
        })
      )

      t = start(dir, 7)
      assert Territory.all(t) == %{"port:1,2" => %{owner: :spain, since: 3}}
    end
  end
end
