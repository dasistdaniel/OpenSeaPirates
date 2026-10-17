defmodule Osp.QuestsFlowTest do
  use ExUnit.Case, async: true

  alias Osp.{Combat, Nations, Ports, Profile, Quests, State}

  @seed 4
  @tok "geheimes-token-flow-1"
  @win_ms 1_800_000

  defp home, do: Nations.nearest_port_of(@seed, :england, {0.0, 0.0}, 1500.0)

  # Ein Zeitfenster, in dem der Hafen sowohl eine Lieferung als auch eine Jagd anbietet
  defp window do
    p = home()

    Enum.find(0..200, fn w ->
      offers = Quests.offers(@seed, p, w)
      Enum.any?(offers, &(&1.kind == :delivery)) and Enum.any?(offers, &(&1.kind == :hunt))
    end)
  end

  defp offers do
    Quests.offers(@seed, home(), window())
  end

  defp delivery, do: Enum.find(offers(), &(&1.kind == :delivery))
  defp hunt, do: Enum.find(offers(), &(&1.kind == :hunt))

  # Spieler (Heimat Frankreich), angedockt im englischen Heimathafen, Ruf bei England `rep`
  defp docked(rep \\ 0, extra \\ %{}) do
    p = home()

    st =
      State.new(@seed, 0)
      |> State.join(@tok, "Anna", Profile.decode(%{"nation" => "france"}))
      |> then(&%{&1 | time: window() * @win_ms})
      |> State.update_ship(@tok, fn s ->
        Map.merge(
          %{s | x: p.x + 1.0, y: p.y, speed: 0.0, invuln_until: 0, rep: %{s.rep | england: rep}},
          extra
        )
      end)

    {st, :ok} = State.dock(st, @tok)
    st
  end

  defp ship(st), do: st.ships[@tok]

  defp unchanged?(a, b) do
    sa = a.ships[@tok]
    sb = b.ships[@tok]

    {sa.gold, sa.bank, sa.class, sa.rep, sa.quests} ==
      {sb.gold, sb.bank, sb.class, sb.rep, sb.quests}
  end

  describe "Annehmen" do
    test "gültiges Angebot wird Quest; zwei gehen, die dritte nicht" do
      st = docked()
      d = delivery()
      h = hunt()

      assert {st, {:ok, view}} = State.accept_quest(st, @tok, d.id)
      assert [%{id: id, have: 0}] = ship(st).quests
      assert id == d.id
      assert [%{id: ^id}] = view.quests.active

      assert {st, {:ok, _}} = State.accept_quest(st, @tok, h.id)
      assert length(ship(st).quests) == 2

      third = offers() |> Enum.find(&(&1.id not in [d.id, h.id]))
      assert {same, {:error, :full}} = State.accept_quest(st, @tok, third.id)
      assert unchanged?(same, st)
    end

    test "dasselbe Angebot zweimal: :duplicate" do
      st = docked()
      {st, {:ok, _}} = State.accept_quest(st, @tok, delivery().id)
      assert {same, {:error, :duplicate}} = State.accept_quest(st, @tok, delivery().id)
      assert unchanged?(same, st)
    end

    test "gefälscht, anderes Fenster, anderer Hafen: :unknown_offer; ohne Andocken: :not_docked" do
      st = docked()
      p = home()
      w = window()

      for bad <- [
            "unsinn",
            "q:#{p.id}:#{w}:9",
            "q:#{p.id}:#{w + 1}:0",
            "q:port:12345,1:#{w}:0",
            nil,
            5
          ] do
        assert {same, {:error, :unknown_offer}} = State.accept_quest(st, @tok, bad)
        assert unchanged?(same, st)
      end

      {st2, :ok} = State.undock(st, @tok)
      assert {same, {:error, :not_docked}} = State.accept_quest(st2, @tok, delivery().id)
      assert unchanged?(same, st2)
    end

    test "Wiedergutmachungsangebot nur bei Gesucht" do
      p = home()
      atone = hd(Quests.atonement_offers(@seed, p, window()))

      st = docked(0)
      assert {same, {:error, :not_wanted}} = State.accept_quest(st, @tok, atone.id)
      assert unchanged?(same, st)

      wanted = docked(-50)
      assert {wanted, {:ok, view}} = State.accept_quest(wanted, @tok, atone.id)
      assert view.hostile == true
      assert [%{atone?: true}] = ship(wanted).quests
    end
  end

  describe "Abgeben" do
    defp deliver_ready do
      d = delivery()
      st = docked()
      {st, {:ok, _}} = State.accept_quest(st, @tok, d.id)
      to = Ports.by_id(@seed, d.to)

      st =
        st
        |> State.update_ship(@tok, &%{&1 | docked: nil, x: to.x + 1.0, y: to.y, speed: 0.0})
        |> State.dock(@tok)
        |> elem(0)

      {st, d, to}
    end

    test "Lieferung am Zielhafen: Gold, Ruf nur bei der Auftraggeber-Nation, Quest weg, Ereignisse" do
      {st, d, _} = deliver_ready()
      gold = ship(st).gold
      assert {st, {:ok, view, ev}} = State.turn_in(st, @tok)
      s = ship(st)
      assert s.gold == gold + d.gold and s.quests == []
      assert s.rep[d.nation] == d.rep and s.rep.france == 20
      assert view.quests.active == []
      pub = {:quest_done, @tok, d.gold, d.rep, d.nation}

      assert Enum.any?(ev, fn e ->
               match?({:quest_done, @tok, _, _, _, _, _}, e) and elem(e, 2) == elem(pub, 2)
             end)

      assert Enum.any?(ev, &match?({:rep, @tok, _, _, _, _, _}, &1))
    end

    test "am falschen Hafen oder ein zweites Mal: :nothing, nichts ändert sich" do
      st = docked()
      {st, {:ok, _}} = State.accept_quest(st, @tok, delivery().id)
      assert {same, {:error, :nothing}} = State.turn_in(st, @tok)
      assert unchanged?(same, st)

      {st, _, _} = deliver_ready()
      {st, {:ok, _, _}} = State.turn_in(st, @tok)
      after_once = st
      assert {same, {:error, :nothing}} = State.turn_in(st, @tok)
      assert unchanged?(same, after_once)
    end

    test "nicht angedockt: :not_docked" do
      {st, _, _} = deliver_ready()
      st = State.update_ship(st, @tok, &%{&1 | docked: nil})
      assert {_, {:error, :not_docked}} = State.turn_in(st, @tok)
    end

    test "Ruf wird bei +100 begrenzt, Gold kommt trotzdem" do
      {st, d, _} = deliver_ready()
      st = State.update_ship(st, @tok, &%{&1 | rep: Map.put(&1.rep, d.nation, 98)})
      gold = ship(st).gold
      {st, {:ok, _, _}} = State.turn_in(st, @tok)
      assert ship(st).rep[d.nation] == 100
      assert ship(st).gold == gold + d.gold
    end

    test "Jagd: erst fertig am Hafen des Auftraggebers abgebbar" do
      h = hunt()
      st = docked()
      {st, {:ok, _}} = State.accept_quest(st, @tok, h.id)
      assert {_, {:error, :nothing}} = State.turn_in(st, @tok)

      st =
        State.update_ship(st, @tok, fn s ->
          %{s | quests: Enum.map(s.quests, &%{&1 | have: &1.need})}
        end)

      gold = ship(st).gold
      assert {st, {:ok, _, _}} = State.turn_in(st, @tok)
      assert ship(st).gold == gold + h.gold and ship(st).quests == []
      assert ship(st).rep[h.nation] == h.rep
    end
  end

  describe "Wiedergutmachung durch Quest" do
    test "kein Gold, +25 Ruf bei der Hafen-Nation; danach ist der Hafen wieder offen" do
      p = home()
      atone = Enum.find(Quests.atonement_offers(@seed, p, window()), &(&1.kind == :hunt))
      st = docked(-50, %{gold: 50})
      {st, {:ok, view}} = State.accept_quest(st, @tok, atone.id)
      assert view.hostile == true

      # gesperrt bleibt gesperrt
      assert {_, {:error, :hostile}} = State.shop(st, @tok, {:deposit, 10})

      st =
        State.update_ship(st, @tok, fn s ->
          %{s | quests: Enum.map(s.quests, &%{&1 | have: &1.need})}
        end)

      gold = ship(st).gold
      {st, {:ok, view2, _}} = State.turn_in(st, @tok)
      assert ship(st).gold == gold
      assert ship(st).rep.england == -25
      assert Map.get(view2, :hostile) in [nil, false]
      assert {_, {:ok, _}} = State.shop(st, @tok, {:deposit, 10})
    end

    test ":atone gibt es nicht mehr (offen: unbekannt, gesperrt: gesperrt)" do
      st = docked(0, %{gold: 500})
      assert {same, {:error, :unknown}} = State.shop(st, @tok, :atone)
      assert same.ships[@tok].gold == 500

      st = docked(-50, %{gold: 500})
      assert {same, {:error, :hostile}} = State.shop(st, @tok, :atone)
      assert same.ships[@tok].gold == 500 and same.ships[@tok].rep.england == -50
    end
  end

  describe "Jagd-Zählung" do
    defp hunt_state do
      p = home()
      q = %{Quests.to_quest(hunt()) | target_nation: :france, nation: :england, need: 2}
      st = docked(0, %{quests: [q]}) |> State.undock(@tok) |> elem(0)
      {st, p}
    end

    defp kill(st, kind, nation, by \\ @tok) do
      s = ship(st)
      st = State.add_npc(st, kind, "NPC", s.x + 3.0, s.y, 0.0, 0, nation)
      id = st.ships |> Map.keys() |> Enum.find(&String.starts_with?(&1, "npc-"))
      Combat.hurt(st, id, 1000.0, by, s.x, s.y)
    end

    defp have(st), do: hd(ship(st).quests).have

    test "französischer Jäger zählt; Händler, englischer Jäger und Tod ohne Spieler nicht" do
      {st, _} = hunt_state()
      {st1, _} = kill(st, :hunter, :france)
      assert have(st1) == 1

      {st2, _} = kill(st, :merchant, :france)
      assert have(st2) == 0

      {st3, _} = kill(st, :hunter, :england)
      assert have(st3) == 0

      {st4, _} = kill(st, :hunter, :france, nil)
      assert have(st4) == 0
    end

    test "Notwehr zählt für die Quest, kostet aber keinen Ruf" do
      {st, _} = hunt_state()
      s = ship(st)
      st = State.add_npc(st, :hunter, "J", s.x + 3.0, s.y, 0.0, 0, :france)
      id = st.ships |> Map.keys() |> Enum.find(&String.starts_with?(&1, "npc-"))
      st = State.update_ship(st, id, &%{&1 | hunting: {@tok, st.time}})
      {st, _} = Combat.hurt(st, id, 1000.0, @tok, s.x, s.y)
      assert have(st) == 1
      assert ship(st).rep.france == 20
    end

    test "nie über need hinaus" do
      {st, _} = hunt_state()
      {st, _} = kill(st, :hunter, :france)
      {st, _} = kill(st, :hunter, :france)
      {st, _} = kill(st, :hunter, :france)
      assert have(st) == 2
    end
  end

  describe "Scheitern und Aufgeben" do
    test "Tod entfernt Lieferungen mit Ereignis, Jagden bleiben" do
      d = Quests.to_quest(delivery())
      h = %{Quests.to_quest(hunt()) | have: 1}
      st = docked(0, %{quests: [d, h]}) |> State.undock(@tok) |> elem(0)
      # außerhalb der Schutzzone, sonst bleibt der Spieler unverletzt
      st = State.update_ship(st, @tok, &%{&1 | x: &1.x + 40.0})
      {st, ev} = Combat.hurt(st, @tok, 1000.0, "npc-x", 0.0, 0.0)
      assert [%{kind: :hunt, have: 1}] = ship(st).quests
      assert Enum.any?(ev, &match?({:quest_lost, @tok, :death, _, _}, &1))
    end

    test "Aufgeben ohne Belohnung, überall; Unbekanntes meldet :unknown" do
      st = docked()
      {st, {:ok, _}} = State.accept_quest(st, @tok, delivery().id)
      st = State.undock(st, @tok) |> elem(0)
      before = ship(st)
      assert {st, :ok} = State.abandon_quest(st, @tok, delivery().id)
      assert ship(st).quests == []
      assert ship(st).gold == before.gold and ship(st).rep == before.rep
      assert {_, {:error, :unknown}} = State.abandon_quest(st, @tok, "q:port:1,1:0:0")
    end
  end

  describe "Ansichten" do
    test "drei Angebote, Wiedergutmachung nur bei Gesucht, aktive wie im Schiff; kein Token im JSON" do
      st = docked()
      view = State.shop_view(st, @tok)
      assert length(view.quests.offers) == 3
      assert view.quests.atone == []
      assert view.quests.active == []
      refute Jason.encode!(view) =~ "geheimes-token"

      wanted = docked(-50)
      wv = State.shop_view(wanted, @tok)
      assert wv.hostile == true
      assert length(wv.quests.atone) == 2
      assert Enum.all?(wv.quests.atone, &(&1.at == true and &1.gold == 0 and &1.rep == 25))
    end
  end
end
