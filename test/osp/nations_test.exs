defmodule Osp.NationsTest do
  use ExUnit.Case, async: true

  alias Osp.{Nations, Ports}

  @seed 4

  defp some_port, do: @seed |> Ports.near(0.0, 0.0, 400.0) |> hd()

  test "all/0: fünf Nationen in fester Reihenfolge, info/1 vollständig" do
    assert Nations.all() == [:spain, :england, :france, :netherlands, :portugal]

    for n <- Nations.all() do
      info = Nations.info(n)
      assert is_binary(info.name) and info.name != ""
      assert is_binary(info.adjective) and info.adjective != ""
      assert info.color =~ ~r/^#[0-9a-f]{6}$/
      assert is_binary(info.bonus_text) and info.bonus_text != ""
    end
  end

  test "parse/1 akzeptiert nur die fünf bekannten Namen" do
    assert Nations.parse("spain") == {:ok, :spain}
    assert Nations.parse("portugal") == {:ok, :portugal}

    for bad <- ["xyz", "", 5, nil, ["spain"], %{}, :spain],
        do: assert(Nations.parse(bad) == :error)
  end

  test "cell_nation/3: deterministisch, je 150-WE-Zelle gleich, alle fünf kommen vor" do
    assert Nations.cell_nation(@seed, 10.0, 10.0) == Nations.cell_nation(@seed, 10.0, 10.0)
    assert Nations.cell_nation(@seed, 10.0, 10.0) == Nations.cell_nation(@seed, 140.0, 140.0)

    found =
      for i <- 0..39, j <- 0..39, uniq: true, do: Nations.cell_nation(@seed, i * 150.0, j * 150.0)

    assert Enum.sort(found) == Enum.sort(Nations.all())
  end

  test "of_port/2 ist die Zellnation der Hafenposition" do
    port = some_port()
    assert Nations.of_port(@seed, port) == Nations.cell_nation(@seed, port.x, port.y)
  end

  test "at/3 am Ankerplatz ist die Nation des Hafens" do
    port = some_port()
    assert Nations.at(@seed, port.x + 0.5, port.y) == Nations.of_port(@seed, port)
  end

  test "nearest_port_of/4 findet für jede Nation einen Hafen binnen 1500 WE" do
    for n <- Nations.all() do
      assert %{} = port = Nations.nearest_port_of(@seed, n, {0.0, 0.0}, 1500.0)
      assert Nations.of_port(@seed, port) == n
      assert :math.sqrt(port.x * port.x + port.y * port.y) <= 1500.0
    end
  end

  test "nearest_port_of/4: kein Hafen im Radius ergibt nil" do
    {x, y} =
      Enum.find_value(0..300, fn k ->
        x = k * 7.3 + 0.5
        y = k * 3.1 + 0.5
        if Ports.near(@seed, x, y, 1.0) == [], do: {x, y}
      end)

    assert Nations.nearest_port_of(@seed, :spain, {x, y}, 1.0) == nil
  end

  test "bonus/1: feste Werte je Nation, sonst neutral" do
    neutral = %{hp: 0, dmg: 1.0, turn: 1.0, speed: 1.0, repair: 1.0}
    assert Nations.bonus(nil) == neutral
    assert Nations.bonus(:spain) == %{neutral | hp: 2}
    assert Nations.bonus(:england) == %{neutral | dmg: 1.08}
    assert Nations.bonus(:france) == %{neutral | turn: 1.06}
    assert Nations.bonus(:portugal) == %{neutral | speed: 1.05}
    assert Nations.bonus(:netherlands) == %{neutral | repair: 0.75}
  end
end
