defmodule Osp.QuestsTest do
  use ExUnit.Case, async: true

  alias Osp.{Nations, Ports, Quests}

  @seed 4

  defp port, do: @seed |> Ports.near(0.0, 0.0, 400.0) |> hd()

  defp dist(a, b), do: :math.sqrt(:math.pow(a.x - b.x, 2) + :math.pow(a.y - b.y, 2))

  describe "Ports.by_id/2" do
    test "findet den Hafen zur ID" do
      p = port()
      assert Ports.by_id(@seed, p.id) == p
    end

    test "Unsinn ergibt nil ohne Ausnahme" do
      for bad <- ["unsinn", "port:x,y", "port:99999999,1", "port:1,1; drop", "", nil, 5, [], %{}] do
        assert Ports.by_id(@seed, bad) == nil
      end
    end

    test "ID eines Chunks ohne Hafen ergibt nil" do
      {cx, cy} =
        Enum.find_value(0..200, fn k -> if Ports.in_chunk(@seed, k, 0) == nil, do: {k, 0} end)

      assert Ports.by_id(@seed, "port:#{cx},#{cy}") == nil
    end
  end

  describe "offers/3" do
    test "genau drei, deterministisch, mit dem Muster der ID" do
      p = port()
      offers = Quests.offers(@seed, p, 5)
      assert length(offers) == 3
      assert offers == Quests.offers(@seed, p, 5)
      assert Enum.map(offers, & &1.id) == for(i <- 0..2, do: "q:#{p.id}:5:#{i}")
      assert Enum.all?(offers, &(&1.from == p.id and &1.nation == Nations.of_port(@seed, p)))
      assert Enum.all?(offers, &(&1.atone? == false))
    end

    test "andere Fenster ergeben andere Angebote" do
      p = port()
      all = for w <- 0..4, do: Quests.offers(@seed, p, w) |> Enum.map(&Map.drop(&1, [:id]))
      assert length(Enum.uniq(all)) > 1
    end

    test "Lieferungen: anderer Hafen 40–120 WE, Gold und Ruf nach Regel" do
      deliveries =
        for w <- 0..30,
            o <- Quests.offers(@seed, port(), w),
            o.kind == :delivery,
            do: o

      assert deliveries != []

      for o <- deliveries do
        to = Ports.by_id(@seed, o.to)
        assert to && to.id != o.from
        assert o.dist >= 40 and o.dist <= 120
        assert_in_delta dist(port(), to), o.dist, 1.0
        assert o.gold == 40 + round(1.2 * o.dist)
        assert o.rep == 4 and o.need == 1 and o.target_nation == nil
        assert o.to_name == to.name
      end
    end

    test "Jagden: 2–3 Jäger einer anderen Nation, Gold und Ruf nach Regel" do
      hunts = for w <- 0..30, o <- Quests.offers(@seed, port(), w), o.kind == :hunt, do: o
      assert hunts != []

      for o <- hunts do
        assert o.need in 2..3
        assert o.target_nation in Nations.all() and o.target_nation != o.nation
        assert o.gold == 70 * o.need and o.rep == 6
        assert o.to == nil
      end
    end
  end

  describe "atonement_offers/3" do
    test "genau zwei, ohne Gold, Ruf +25, Lieferziel in derselben Nation" do
      p = port()

      for w <- 0..30 do
        offers = Quests.atonement_offers(@seed, p, w)
        assert length(offers) == 2
        assert Enum.all?(offers, &(&1.atone? and &1.gold == 0 and &1.rep == 25))
        assert Enum.all?(offers, &(&1.nation == Nations.of_port(@seed, p)))

        for o <- offers do
          if o.kind == :delivery do
            assert Nations.of_port(@seed, Ports.by_id(@seed, o.to)) == o.nation
          else
            assert o.target_nation != o.nation
          end
        end
      end
    end
  end

  describe "find_offer/5" do
    test "echte Angebote werden gefunden, Wiedergutmachung nur mit wanted?" do
      p = port()
      [first | _] = Quests.offers(@seed, p, 3)
      assert {:ok, ^first} = Quests.find_offer(@seed, p, 3, first.id, false)

      [atone | _] = Quests.atonement_offers(@seed, p, 3)
      assert Quests.find_offer(@seed, p, 3, atone.id, false) == :error
      assert {:ok, ^atone} = Quests.find_offer(@seed, p, 3, atone.id, true)
    end

    test "gefälscht, veraltet oder fremd: :error" do
      p = port()
      [first | _] = Quests.offers(@seed, p, 3)
      assert Quests.find_offer(@seed, p, 4, first.id, true) == :error
      assert Quests.find_offer(@seed, p, 3, "q:#{p.id}:3:9", true) == :error
      assert Quests.find_offer(@seed, p, 3, "unsinn", true) == :error
      assert Quests.find_offer(@seed, p, 3, nil, true) == :error
      assert Quests.find_offer(@seed, p, 3, 5, true) == :error
      other = %{p | id: "port:12345,1"}
      assert Quests.find_offer(@seed, other, 3, first.id, true) == :error
    end
  end

  describe "Quest-Zustand" do
    defp hunt_quest,
      do: %{
        id: "q:port:1,1:0:1",
        kind: :hunt,
        from: "port:1,1",
        nation: :england,
        to: nil,
        target_nation: :france,
        need: 2,
        gold: 140,
        rep: 6,
        atone?: false
      }

    defp delivery_quest,
      do: %{
        id: "q:port:1,1:0:0",
        kind: :delivery,
        from: "port:1,1",
        nation: :england,
        to: "port:2,2",
        target_nation: nil,
        need: 1,
        gold: 100,
        rep: 4,
        atone?: false
      }

    test "to_quest/1: have 0, 30 Minuten Zeit" do
      q = Quests.to_quest(hunt_quest())
      assert q.have == 0 and q.left_ms == 1_800_000
      assert Quests.ttl_ms() == 1_800_000 and Quests.max_active() == 2
    end

    test "kill/2 zählt nur Jagd, nur die Zielnation, nie über need" do
      q = Quests.to_quest(hunt_quest())
      assert Quests.kill(q, :france).have == 1
      assert Quests.kill(q, :spain).have == 0
      assert Quests.kill(Quests.kill(Quests.kill(q, :france), :france), :france).have == 2

      d = Quests.to_quest(delivery_quest())
      assert Quests.kill(d, :france) == d
    end

    test "complete?/2: Lieferung am Ziel, Jagd fertig am Auftraggeber" do
      d = Quests.to_quest(delivery_quest())
      assert Quests.complete?(d, "port:2,2")
      refute Quests.complete?(d, "port:1,1")

      h = Quests.to_quest(hunt_quest())
      refute Quests.complete?(h, "port:1,1")
      done = %{h | have: 2}
      assert Quests.complete?(done, "port:1,1")
      refute Quests.complete?(done, "port:2,2")
    end

    test "tick/2 zieht Zeit ab, abgelaufene wandern in expired" do
      a = %{Quests.to_quest(delivery_quest()) | left_ms: 1_000}
      b = %{Quests.to_quest(hunt_quest()) | left_ms: 400}
      {kept, expired} = Quests.tick([a, b], 500)
      assert [%{left_ms: 500}] = kept
      assert [%{kind: :hunt}] = expired
    end
  end

  describe "JSON" do
    test "Rundlauf" do
      for q <- [Quests.to_quest(hunt_q()), Quests.to_quest(del_q())] do
        assert {:ok, ^q} = q |> Quests.to_json() |> Quests.from_json()
      end
    end

    defp hunt_q,
      do: %{
        id: "q:port:1,1:0:1",
        kind: :hunt,
        from: "port:1,1",
        nation: :england,
        to: nil,
        target_nation: :france,
        need: 2,
        gold: 140,
        rep: 6,
        atone?: false
      }

    defp del_q,
      do: %{
        id: "q:port:1,1:0:0",
        kind: :delivery,
        from: "port:1,1",
        nation: :england,
        to: "port:2,2",
        target_nation: nil,
        need: 1,
        gold: 100,
        rep: 4,
        atone?: false
      }

    defp good, do: Quests.to_json(Quests.to_quest(hunt_q()))

    test "lehnt Ungültiges ab" do
      for bad <- [
            "x",
            5,
            nil,
            [],
            %{},
            Map.put(good(), "kind", "piraterie"),
            Map.put(good(), "nation", "atlantis"),
            Map.put(good(), "tn", "atlantis"),
            Map.put(good(), "tn", "england"),
            Map.put(good(), "id", "q:unsinn"),
            Map.put(good(), "need", 0),
            Map.put(good(), "need", 1000),
            Map.put(good(), "have", 5),
            Map.put(good(), "have", -1),
            Map.put(good(), "left", 0),
            Map.put(good(), "left", "viel"),
            Map.delete(good(), "kind"),
            Map.put(Quests.to_json(Quests.to_quest(del_q())), "to", "port:x,y"),
            Map.put(Quests.to_json(Quests.to_quest(del_q())), "to", "port:1,1")
          ] do
        assert Quests.from_json(bad) == :error, inspect(bad)
      end
    end

    test "begrenzt riesige Zahlen" do
      big =
        good()
        |> Map.put("gold", 999_999_999_999)
        |> Map.put("rep", 5_000)
        |> Map.put("left", 99_999_999_999)

      assert {:ok, q} = Quests.from_json(big)
      assert q.gold == 100_000 and q.rep == 100 and q.left_ms == 1_800_000
      assert {:ok, neg} = Quests.from_json(Map.put(good(), "gold", -50))
      assert neg.gold == 0
    end
  end
end
