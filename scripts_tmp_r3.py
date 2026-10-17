def sub(p, pairs):
    s = open(p, encoding='utf-8').read()
    for a, b in pairs:
        assert a in s, (p, a)
        s = s.replace(a, b, 1)
    open(p, 'w', encoding='utf-8').write(s)


sub('lib/osp/combat.ex', [
    ('  alias Osp.{Ports, Ships, State, Terrain}', '  alias Osp.{Ports, Reputation, Ships, State, Terrain}'),
    ('''  @burn_tick_ms 1_000
''', '''  @burn_tick_ms 1_000
  # Notwehr: ein Jäger, der den Spieler in den letzten 15 s beschossen hat oder auf ihn Jagd macht
  @self_defense_ms 15_000
'''),
    ('''      s = %{s | hp: s.hp - amount, last_hit_by: by || s.last_hit_by, flee: flee || s.flee}
      state = State.put_ship(state, victim_id, s)
''', '''      s = %{
        s
        | hp: s.hp - amount,
          last_hit_by: by || s.last_hit_by,
          flee: flee || s.flee,
          attacked_at: note_attack(state, s, by)
      }

      state = State.put_ship(state, victim_id, s)
'''),
    ('''  # Wirkung der Sondermunition auf ein getroffenes (überlebendes) Schiff''', '''  # Trifft ein NPC einen Spieler, merkt sich dieser Zeit und Angreifer (für die Notwehr-Regel)
  defp note_attack(state, %{kind: :player, attacked_at: marks}, by) when by != nil do
    case state.ships[by] do
      %{kind: kind} when kind != :player -> Map.put(marks, by, state.time)
      _ -> marks
    end
  end

  defp note_attack(_state, s, _by), do: Map.get(s, :attacked_at, %{})

  # Wirkung der Sondermunition auf ein getroffenes (überlebendes) Schiff'''),
    ('''    {state, [{:kill, killer, id, s.x, s.y}]}
  end''', '''    {state, rep_events} = punish(state, s, killer)
    {state, [{:kill, killer, id, s.x, s.y}] ++ rep_events}
  end

  # Ruf: Wer ein Schiff einer Nation versenkt, verliert Ruf bei dieser Nation (Händler 8, Jäger 5) –
  # außer in Notwehr gegen einen Jäger, der ihn gerade angegriffen hat
  defp punish(state, victim, killer_id) do
    with true <- victim.kind in [:merchant, :hunter],
         nation when nation != nil <- victim.nation,
         %{kind: :player, alive?: true} = killer <- killer_id && state.ships[killer_id],
         penalty when penalty > 0 <- Reputation.penalty(victim.kind),
         false <- self_defense?(state, victim, killer) do
      State.add_rep(state, killer_id, nation, -penalty)
    else
      _ -> {state, []}
    end
  end

  defp self_defense?(_state, %{kind: :merchant}, _killer), do: false

  defp self_defense?(state, hunter, killer) do
    recent? = fn t -> is_integer(t) and state.time - t <= @self_defense_ms end

    case hunter.hunting do
      {id, t} when id == killer.id -> recent?.(t) or recent?.(Map.get(killer.attacked_at, hunter.id))
      _ -> recent?.(Map.get(killer.attacked_at, hunter.id))
    end
  end'''),
])

sub('lib/osp/state.ex', [
    ('''      rep: Reputation.start(nil),''', '''      rep: Reputation.start(nil),
      hunting: nil,
      attacked_at: %{},'''),
    ('''              {keys, [], target, rng} = Hunter.think(ship, nil, acc.targets[id], solid?, acc.rng, nil)

              acc = %{
                acc
                | ships: Map.put(acc.ships, id, %{ship | input: keys, run: nil}),''', '''              {keys, [], target, rng} = Hunter.think(ship, nil, acc.targets[id], solid?, acc.rng, nil)

              acc = %{
                acc
                | ships: Map.put(acc.ships, id, %{ship | input: keys, run: nil, hunting: nil}),'''),
    ('''    {keys, fires, run} = Hunter.attack(ship, enemy, solid?, acc.time)
    acc = %{acc | ships: Map.put(acc.ships, id, %{ship | input: keys, run: run})}''', '''    {keys, fires, run} = Hunter.attack(ship, enemy, solid?, acc.time)

    # Jäger merken, auf wen sie gerade Jagd machen (Notwehr-Regel beim Ruf); Händler nie
    hunting = if ship.kind == :hunter, do: {enemy.id, acc.time}, else: nil
    acc = %{acc | ships: Map.put(acc.ships, id, %{ship | input: keys, run: run, hunting: hunting})}'''),
])
