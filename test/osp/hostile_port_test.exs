defmodule Osp.HostilePortTest do
  use ExUnit.Case, async: true

  alias Osp.{Combat, Nations, Profile, Shop, State, World}
  alias Osp.Web.Socket

  @seed 4
  @tok "tok-host-aaaa-1"

  defp port_of(nation), do: Nations.nearest_port_of(@seed, nation, {0.0, 0.0}, 1500.0)

  # Spieler (Heimat Frankreich) 1 WE vom Anker eines Hafens der Nation `nation`, Ruf bei England `rep`
  defp scene(rep, nation \\ :england, extra \\ %{}) do
    port = port_of(nation)

    st =
      State.new(@seed, 0)
      |> State.join(@tok, "Anna", Profile.decode(%{"nation" => "france"}))
      |> State.update_ship(@tok, fn s ->
        Map.merge(
          %{
            s
            | x: port.x + 1.0,
              y: port.y,
              speed: 0.0,
              invuln_until: 0,
              rep: %{s.rep | england: rep}
          },
          extra
        )
      end)

    {st, port}
  end

  describe "safe_for?/2" do
    test "ungeschützt nur für Gesuchte bei der Nation dieses Hafens" do
      {st, _} = scene(0)
      assert State.safe_for?(st, st.ships[@tok])

      {st, _} = scene(-40)
      refute State.safe_for?(st, st.ships[@tok])

      {st, _} = scene(-39)
      assert State.safe_for?(st, st.ships[@tok])
    end

    test "Gesucht bei England schützt in der Zone eines französischen Hafens weiterhin" do
      {st, _} = scene(-80, :france)
      assert State.safe_for?(st, st.ships[@tok])
    end

    test "außerhalb jeder Zone ist niemand geschützt; NPCs in der Zone schon; nil nie" do
      {st, port} = scene(0)
      far = %{st.ships[@tok] | x: port.x + 100.0, y: port.y + 100.0}
      refute State.safe_for?(st, far)
      assert State.safe_for?(st, %{st.ships[@tok] | kind: :hunter, rep: %{}})
      refute State.safe_for?(st, nil)
    end

    test "safe_at?/4 mit Position: Kugelort zählt, nicht der Schiffsort" do
      {st, port} = scene(-60)
      refute State.safe_at?(st, port.x + 1.0, port.y, st.ships[@tok])
      assert State.safe_at?(st, port.x + 1.0, port.y, %{st.ships[@tok] | rep: %{england: 0}})
      refute State.safe_at?(st, port.x + 1.0, port.y, nil)
    end
  end

  describe "Kampf in der Zone" do
    test "Gesuchter darf feuern und wird verletzt, ein Unbescholtener nicht" do
      {wanted, _} = scene(-60)
      {st, ev} = State.fire(wanted, @tok, :right)
      assert [{:fire, @tok, :right, _, _}] = ev
      assert length(st.balls) == 3

      {hurt, _} = Combat.hurt(wanted, @tok, 2.0, "npc-x", 0.0, 0.0)
      assert hurt.ships[@tok].hp == 10.0

      {clean, _} = scene(0)
      assert {^clean, []} = State.fire(clean, @tok, :right)
      {same, []} = Combat.hurt(clean, @tok, 2.0, "npc-x", 0.0, 0.0)
      assert same.ships[@tok].hp == 12.0
    end

    defp ball(owner, x, y),
      do: %{
        id: 1,
        owner: owner,
        x: x,
        y: y,
        vx: 0.0,
        vy: 0.0,
        ttl: 700,
        dmg: 1.5,
        r: 0.08,
        ammo: :ball,
        owner_kind: if(String.starts_with?(owner, "fort:"), do: :fort, else: :player)
      }

    test "Kugeln eines Gesuchten und Fort-Kugeln verschwinden in der Zone nicht, andere schon" do
      {st, port} = scene(-60)
      at = {port.x + 2.0, port.y}
      {x, y} = at

      keep = %{st | balls: [ball(@tok, x, y), ball("fort:" <> port.id, x, y)]}
      {after_keep, _} = State.tick(keep, 25)
      assert length(after_keep.balls) == 2

      # derselbe Schuss von einem Unbescholtenen verschwindet
      {clean, _} = scene(0)
      vanish = %{clean | balls: [ball(@tok, x, y)]}
      {after_vanish, _} = State.tick(vanish, 25)
      assert after_vanish.balls == []
    end
  end

  describe "Hafen bei Gesucht" do
    test "Andocken gelingt, die Ansicht ist die Sperr-Ansicht" do
      {st, port} = scene(-50)
      assert {st, :ok} = State.dock(st, @tok)
      assert %{id: id, nation: :england} = st.ships[@tok].docked
      assert id == port.id

      assert %{
               t: "shop",
               open: true,
               hostile: true,
               nation: "england",
               rep: -50,
               gold: 0
             } = State.shop_view(st, @tok)
    end

    test "Kauf, Reparatur und Bank sind gesperrt und ändern nichts" do
      {st, _} = scene(-50, :england, %{gold: 1_000, bank: 500, hp: 5.0})
      {st, :ok} = State.dock(st, @tok)
      before = st.ships[@tok]

      for action <- [
            {:class, :klipper},
            {:upgrade, :hull},
            {:ammo, :chain},
            :repair,
            {:deposit, 10},
            {:withdraw, 10}
          ] do
        assert {same, {:error, :hostile}} = State.shop(st, @tok, action)
        assert same.ships[@tok] == before
      end
    end

    test "Hafen-Ansichten tragen die fünf Rufwerte und die Nation" do
      {st, _} = scene(-50)
      {st, :ok} = State.dock(st, @tok)
      assert %{reps: reps, nation: "england"} = State.shop_view(st, @tok)
      assert length(reps) == 5

      {ok_st, _} = scene(5)
      {ok_st, :ok} = State.dock(ok_st, @tok)
      view = State.shop_view(ok_st, @tok)
      assert length(view.reps) == 5 and view.nation == "england"
    end

    test "Shop.hostile_view/3 JSON-tauglich, ohne Token" do
      {st, _} = scene(-50)
      {st, :ok} = State.dock(st, @tok)
      json = st |> State.shop_view(@tok) |> Jason.encode!()
      refute json =~ "geheimes"
      assert Shop.hostile_view(st.ships[@tok], "Test", :england).hostile == true
    end
  end

  describe "Socket" do
    defp socket(world) do
      {:ok, state} = Socket.init([])
      %{state | world: world}
    end

    defp send_json(state, map), do: Socket.handle_in({Jason.encode!(map), [opcode: :text]}, state)

    test "buy mit unbekanntem what ändert nichts; atone gibt es nicht mehr" do
      id = "h" <> Integer.to_string(System.unique_integer([:positive]))
      start_supervised!({World, id: id, seed: @seed, bots: 0, tick_ms: 25}, id: id)
      tok = "tok-sock-" <> Integer.to_string(System.unique_integer([:positive])) <> "-x"

      {:push, _, st} =
        send_json(socket(id), %{t: "join", token: tok, name: "A", nation: "france"})

      assert {:ok, st} = send_json(st, %{t: "buy", what: "atone"})
      assert {:ok, _} = send_json(st, %{t: "buy", what: "unbekannt"})
      assert World.state(id).ships[tok].gold == 0
    end
  end
end
