defmodule Osp.TerritoryTest do
  use ExUnit.Case, async: true

  alias Osp.Territory

  @file_name "territory.json"

  defp tmp_dir do
    dir = Path.join(System.tmp_dir!(), "osp_territory_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  defp start(dir, tag \\ :a) do
    name = :"terr_#{System.unique_integer([:positive])}"
    pid = start_supervised!({Territory, name: name, dir: dir}, id: {name, tag})
    {name, pid}
  end

  defp read(dir), do: dir |> Path.join(@file_name) |> File.read!() |> Jason.decode!()

  test "put/delete wirken, flush schreibt die erwartete Form" do
    dir = tmp_dir()
    {t, _} = start(dir)
    assert Territory.all(t) == %{}

    Territory.put("port:1,2", :france, 1_700_000_000_000, t)
    Territory.put("port:3,4", :spain, 5, t)
    assert Territory.all(t)["port:1,2"] == %{owner: :france, since: 1_700_000_000_000}

    Territory.delete("port:3,4", t)
    :ok = Territory.flush(t)

    assert %{"v" => 1, "ports" => ports} = read(dir)
    assert ports == %{"port:1,2" => %{"owner" => "france", "since" => 1_700_000_000_000}}
  end

  test "Neustart lädt die gespeicherten Einträge" do
    dir = tmp_dir()
    {t, pid} = start(dir)
    Territory.put("port:1,2", :england, 42, t)
    :ok = Territory.flush(t)
    stop_supervised!({t, :a})
    refute Process.alive?(pid)

    {t2, _} = start(dir, :b)
    assert Territory.all(t2) == %{"port:1,2" => %{owner: :england, since: 42}}
  end

  test "zweites Schreiben legt eine Sicherung (.bak) der vorherigen Fassung an" do
    dir = tmp_dir()
    {t, _} = start(dir)
    Territory.put("port:1,2", :england, 1, t)
    :ok = Territory.flush(t)
    Territory.put("port:5,6", :spain, 2, t)
    :ok = Territory.flush(t)

    bak = dir |> Path.join(@file_name <> ".bak") |> File.read!() |> Jason.decode!()
    assert Map.keys(bak["ports"]) == ["port:1,2"]
    assert dir |> read() |> Map.fetch!("ports") |> map_size() == 2
  end

  describe "defekte Dateien" do
    test "kein JSON: nach .corrupt verschoben, Sicherung geladen" do
      dir = tmp_dir()

      good =
        Jason.encode!(%{
          "v" => 1,
          "ports" => %{"port:1,2" => %{"owner" => "france", "since" => 7}}
        })

      File.write!(Path.join(dir, @file_name <> ".bak"), good)
      File.write!(Path.join(dir, @file_name), "{ das ist kein json")

      {t, _} = start(dir)
      assert Territory.all(t) == %{"port:1,2" => %{owner: :france, since: 7}}
      assert File.exists?(Path.join(dir, @file_name <> ".corrupt"))
    end

    test "leer, falscher Typ oder ohne Sicherung: leerer Zustand, kein Absturz" do
      for content <- ["", "[]", "5", "null", ~s({"v":1,"ports":"x"}), ~s({"v":1})] do
        dir = tmp_dir()
        File.write!(Path.join(dir, @file_name), content)
        {t, pid} = start(dir, content)
        assert Process.alive?(pid)
        assert Territory.all(t) == %{}
      end
    end

    test "manipulierte Einträge werden verworfen oder begrenzt, gültige bleiben" do
      dir = tmp_dir()

      ports = %{
        "port:1,2" => %{"owner" => "france", "since" => 100},
        "port:3,4" => %{"owner" => "atlantis", "since" => 1},
        "x" => %{"owner" => "spain", "since" => 1},
        "port:x,y" => %{"owner" => "spain", "since" => 1},
        "port:5,6" => %{"owner" => "spain", "since" => "gestern"},
        "port:7,8" => "kein map",
        "port:9,9" => %{"owner" => "spain", "since" => 99_999_999_999_999_999},
        "port:10,10" => %{"owner" => "spain", "since" => -5},
        "port:99999999999,1" => %{"owner" => "spain", "since" => 1}
      }

      File.write!(Path.join(dir, @file_name), Jason.encode!(%{"v" => 1, "ports" => ports}))
      {t, _} = start(dir)
      all = Territory.all(t)

      assert all["port:1,2"] == %{owner: :france, since: 100}
      refute Map.has_key?(all, "port:3,4")
      refute Map.has_key?(all, "x")
      refute Map.has_key?(all, "port:x,y")
      refute Map.has_key?(all, "port:5,6")
      refute Map.has_key?(all, "port:7,8")
      refute Map.has_key?(all, "port:99999999999,1")
      assert all["port:9,9"].since <= 4_102_444_800_000
      assert all["port:10,10"].since == 0
    end
  end

  test "put mit unbekannter Nation oder ungültiger ID wird abgelehnt" do
    {t, _} = start(tmp_dir())
    Territory.put("port:1,2", :atlantis, 1, t)
    Territory.put("unsinn", :france, 1, t)
    Territory.put(nil, :france, 1, t)
    Territory.put("port:1,2", :france, "x", t)
    assert Territory.all(t) == %{}
  end

  test "ohne :dir bleibt alles im Speicher" do
    name = :"terr_mem_#{System.unique_integer([:positive])}"
    start_supervised!({Territory, name: name, dir: nil}, id: name)
    Territory.put("port:1,2", :france, 3, name)
    assert Territory.all(name) == %{"port:1,2" => %{owner: :france, since: 3}}
    assert :ok = Territory.flush(name)
  end
end
