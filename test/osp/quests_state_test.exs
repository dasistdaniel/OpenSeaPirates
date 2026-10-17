defmodule Osp.QuestsStateTest do
  use ExUnit.Case, async: true

  alias Osp.{Nations, Ports, Profile, Quests, State}

  @seed 4
  @tok "geheimes-token-quest-1"

  defp port, do: @seed |> Ports.near(0.0, 0.0, 400.0) |> hd()

  defp offer(kind) do
    p = port()

    Enum.find_value(0..60, fn w ->
      Enum.find(Quests.offers(@seed, p, w), &(&1.kind == kind))
    end)
  end

  defp quest(kind), do: Quests.to_quest(offer(kind))

  defp scene(quests \\ [], extra \\ %{}) do
    p = port()

    st =
      State.new(@seed, 0)
      |> State.join(@tok, "Anna", Profile.decode(%{"nation" => "france"}))
      |> State.update_ship(@tok, fn s ->
        Map.merge(
          %{s | x: p.x + 20.0, y: p.y, speed: 0.0, invuln_until: 0, quests: quests},
          extra
        )
      end)

    {st, p}
  end

  # Zustand so setzen, dass der nächste 25-ms-Schritt auf einen 500-ms-Takt fällt
  defp at_cycle(st, time_ms) do
    {st, ev} = State.tick(%{st | time: time_ms - 25}, 25)
    {st, ev}
  end

  describe "Profil" do
    test "gültige Quests bleiben, mehr als zwei werden gekürzt" do
      js = for k <- [:delivery, :hunt, :delivery], do: Quests.to_json(quest(k))

      three =
        js
        |> Enum.with_index()
        |> Enum.map(fn {j, i} -> Map.put(j, "id", "q:port:1,1:#{i}:0") end)

      assert length(Profile.decode(%{"quests" => Enum.take(three, 1)})["quests"]) == 1
      assert length(Profile.decode(%{"quests" => three})["quests"]) == 2
    end

    test "Müll wird bereinigt oder verworfen, Duplikate ebenfalls" do
      good = Quests.to_json(quest(:hunt))

      junk = [
        "x",
        5,
        nil,
        [],
        %{},
        Map.put(good, "kind", "piraterie"),
        Map.put(good, "need", 1000),
        Map.put(good, "id", "unsinn"),
        good,
        good
      ]

      assert [%{"id" => id}] = Profile.decode(%{"quests" => junk})["quests"]
      assert id == good["id"]
      assert Profile.decode(%{"quests" => "kaputt"})["quests"] == []
      assert Profile.decode(%{"quests" => %{"a" => 1}})["quests"] == []
    end

    test "fehlendes quests ergibt []; altes Profil lädt verlustfrei" do
      assert Profile.decode(%{})["quests"] == []
      assert Profile.new()["quests"] == []

      old = %{
        "v" => 3,
        "nation" => "france",
        "gold" => 77,
        "class" => "brigg",
        "rep" => %{"france" => 5}
      }

      ship = State.join(State.new(@seed, 0), @tok, "A", old).ships[@tok]
      assert ship.gold == 77 and ship.class == :brigg and ship.rep.france == 5
      assert ship.quests == []
    end

    test "Rundlauf from_ship -> apply" do
      q = quest(:delivery)
      {st, _} = scene([q])
      saved = Profile.from_ship(st.ships[@tok])
      assert [%{"id" => _}] = saved["quests"]

      again =
        State.join(State.new(@seed, 0), "tok-quest-zwei-1", "B", saved).ships["tok-quest-zwei-1"]

      assert again.quests == [q]
    end

    test "neue Schiffe haben keine Quests" do
      assert State.join(State.new(@seed, 0), @tok, "A").ships[@tok].quests == []
    end
  end

  describe "Ablaufzeit" do
    test "alle 500 ms um 500 kleiner; abgelaufen: entfernt mit Ereignis" do
      {st, _} = scene([%{quest(:delivery) | left_ms: 1_200}])
      {st, ev} = at_cycle(st, 500)
      assert [%{left_ms: 700}] = st.ships[@tok].quests
      assert ev == [] or not Enum.any?(ev, &match?({:quest_lost, _, _, _, _}, &1))

      {st, _} = at_cycle(st, 1_000)
      assert [%{left_ms: 200}] = st.ships[@tok].quests

      {st, ev} = at_cycle(st, 1_500)
      assert st.ships[@tok].quests == []
      assert Enum.any?(ev, &match?({:quest_lost, @tok, :expired, _, _}, &1))
    end

    test "zwischen den Takten läuft nichts ab" do
      {st, _} = scene([%{quest(:delivery) | left_ms: 1_200}])
      {st, _} = State.tick(%{st | time: 100}, 25)
      assert [%{left_ms: 1_200}] = st.ships[@tok].quests
    end

    test "tote Spieler verlieren keine Zeit" do
      {st, _} = scene([%{quest(:hunt) | left_ms: 600}], %{alive?: false})
      {st, ev} = at_cycle(st, 500)
      assert [%{left_ms: 600}] = st.ships[@tok].quests
      refute Enum.any?(ev, &match?({:quest_lost, _, _, _, _}, &1))
    end

    test "Spieler ohne Quests: nichts passiert" do
      {st, _} = scene()
      {st2, ev} = at_cycle(st, 500)
      assert st2.ships[@tok].quests == []
      refute Enum.any?(ev, &match?({:quest_lost, _, _, _, _}, &1))
    end
  end

  describe "Hinweis" do
    test "Lieferung zeigt auf den Zielhafen, fertige Jagd auf den Abgabehafen" do
      d = quest(:delivery)
      to = Ports.by_id(@seed, d.to)
      assert Quests.hint(@seed, d, {0.0, 0.0}) == {to.x, to.y}

      h = %{quest(:hunt) | have: 2, need: 2}
      from = Ports.by_id(@seed, h.from)
      assert Quests.hint(@seed, h, {0.0, 0.0}) == {from.x, from.y}
    end

    test "Jagd mit fehlenden Abschüssen: nächster Hafen der Zielnation" do
      h = quest(:hunt)
      {x, y} = {10.0, 10.0}
      {hx, hy} = Quests.hint(@seed, h, {x, y})
      near = Nations.nearest_port_of(@seed, h.target_nation, {x, y}, 400.0)
      assert {hx, hy} == {near.x, near.y}
    end

    test "round_hint/1: Vielfache von 10, höchstens 5 WE daneben" do
      {rx, ry} = Quests.round_hint({123.4, -56.7})
      assert {rx, ry} == {120, -60}
      assert rem(rx, 10) == 0 and rem(ry, 10) == 0
      assert abs(rx - 123.4) <= 5 and abs(ry + 56.7) <= 5
    end
  end

  describe "Schnappschuss" do
    test "me.q trägt Ziel, gerundeten Hinweis und Restsekunden" do
      d = %{quest(:delivery) | left_ms: 90_100}
      {st, _} = scene([d])
      {st, _} = at_cycle(st, 500)
      snap = State.snapshot_for(st, @tok, [])
      assert [q] = snap.me.q
      to = Ports.by_id(@seed, d.to)

      assert q.id == d.id and q.k == "delivery" and q.to == to.name
      assert q.n == Atom.to_string(d.nation) and q.need == 1 and q.have == 0
      assert q.left == 90
      assert rem(q.hx, 10) == 0 and rem(q.hy, 10) == 0
      assert abs(q.hx - to.x) <= 5.0 and abs(q.hy - to.y) <= 5.0
      assert q.gold == d.gold and q.rep == d.rep and q.at == false
      assert {:ok, _} = Jason.encode(snap)
      refute Jason.encode!(snap) =~ "geheimes-token"
    end

    test "Jagd trägt Zielnation, Fortschritt und Hinweis; Hinweis ändert sich nicht zwischen 500-ms-Takten" do
      h = %{quest(:hunt) | have: 1}
      {st, _} = scene([h])
      {st, _} = at_cycle(st, 500)
      [q1] = State.snapshot_for(st, @tok, []).me.q
      assert q1.k == "hunt" and q1.tn == Atom.to_string(h.target_nation)
      assert q1.have == 1 and q1.need == h.need and q1.to == nil

      moved = State.update_ship(st, @tok, &%{&1 | x: &1.x + 300.0})
      {moved, _} = State.tick(%{moved | time: 600}, 25)
      [q2] = State.snapshot_for(moved, @tok, []).me.q
      assert {q2.hx, q2.hy} == {q1.hx, q1.hy}
    end

    test "ohne Quests ist me.q leer" do
      {st, _} = scene()
      assert State.snapshot_for(st, @tok, []).me.q == []
    end

    test "quest_lost geht als Liste mit öffentlicher Kennung hinaus" do
      {st, _} = scene()
      p = st.ships[@tok]
      snap = State.snapshot_for(st, @tok, [{:quest_lost, @tok, :death, p.x, p.y}])
      pub = State.public_id(@tok)
      assert [["quest_lost", ^pub, "death", _, _]] = snap.ev
    end
  end
end
