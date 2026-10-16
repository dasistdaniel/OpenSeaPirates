defmodule Osp.RadarTest do
  use ExUnit.Case, async: true

  alias Osp.{State, Wander}

  @token_a "geheimes-token-anna"

  defp scene do
    State.new(4, 0)
    |> State.join(@token_a, "Anna")
    |> State.join("geheimes-token-ben", "Ben")
  end

  test "öffentliche Kennung: Hash für Spieler, NPCs unverändert, nil bleibt nil" do
    assert State.public_id("npc-7") == "npc-7"
    assert State.public_id(nil) == nil
    pub = State.public_id(@token_a)
    assert String.starts_with?(pub, "p")
    refute pub == @token_a
    assert pub == State.public_id(@token_a)
    refute pub == State.public_id("geheimes-token-ben")
  end

  test "Schnappschuss verrät das Token nie (Schiffe, Spielerliste, Ereignisse)" do
    st = scene()
    a = st.ships[@token_a]

    events = [
      {:fire, @token_a, :left, a.x, a.y},
      {:kill, "geheimes-token-ben", @token_a, a.x, a.y}
    ]

    json = st |> State.snapshot_for(@token_a, events) |> Jason.encode!()
    refute json =~ "geheimes-token"
  end

  test "Spielerliste: alle lebenden Spieler mit Name, Position, Abschüssen und Gold; nur alle 0,5 s" do
    st =
      scene()
      |> State.update_ship(@token_a, &%{&1 | kills: 3, gold: 40, bank: 100})

    snap = State.snapshot_for(st, @token_a, [])
    assert length(snap.pl) == 2
    pub = State.public_id(@token_a)
    assert [^pub, "Anna", _color, _x, _y, 3, 140] = Enum.find(snap.pl, &(hd(&1) == pub))

    # Tote Spieler stehen nicht in der Liste
    dead = State.update_ship(st, "geheimes-token-ben", &%{&1 | alive?: false})
    assert length(State.snapshot_for(dead, @token_a, []).pl) == 1

    # zwischen den Takten kein pl
    later = %{st | time: 25}
    refute Map.has_key?(State.snapshot_for(later, @token_a, []), :pl)
    assert {:ok, _} = Jason.encode(snap)
  end

  test "Land voraus: Ausweichkurs führt in freies Wasser, auch nach links" do
    # Mauer rechts bei x > 10
    solid? = fn x, _y -> x > 10.0 end
    ship = %{x: 9.4, y: 0.0, heading: 0.0}
    h = Wander.escape_heading(ship, solid?)
    refute solid?.(ship.x + :math.cos(h) * 2.2, ship.y + :math.sin(h) * 2.2)

    # Mauer oben (y < 0): wer nach oben schaut, kommt nach unten frei
    top? = fn _x, y -> y < 0.0 end
    up = %{x: 0.0, y: 0.6, heading: -:math.pi() / 2}
    h2 = Wander.escape_heading(up, top?)
    refute top?.(up.x + :math.cos(h2) * 2.2, up.y + :math.sin(h2) * 2.2)
  end

  test "festgefahrener Kurs: freiste Richtung zeigt von der Küste weg" do
    solid? = fn x, _y -> x > 10.0 end
    ship = %{x: 9.8, y: 0.0, heading: 0.0}
    h = Wander.free_heading(ship, solid?)
    assert :math.cos(h) < 0.2
  end

  test "ohne Land vor sich behält free_heading den Kurs" do
    ship = %{x: 0.0, y: 0.0, heading: 1.0}
    assert Wander.free_heading(ship, fn _, _ -> false end) == 1.0
  end
end
