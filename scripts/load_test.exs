# Lasttest ohne Netzwerk: wie viel Rechenzeit kostet ein Takt der Welt (Simulation + Schnappschüsse
# für alle Spieler + JSON), je nach Spielerzahl und Dichte?
#
#   ./mx run scripts/load_test.exs            # Standardlauf
#   ./mx run scripts/load_test.exs 20 60      # nur diese Spielerzahlen
#
# "Takt" = Rechenzeit des Welt-Prozesses (Eingaben, Simulation, Schnappschüsse bauen). Budget 50 ms:
# unter ~25 ms komfortabel, über 50 ms hinkt die Welt. Die JSON-Kodierung (Σ über alle Spieler) läuft in
# Produktion parallel in den Socket-Prozessen und zählt nicht zum Takt.

alias Osp.{State, Terrain}

defmodule LoadTest do
  @tick_ms 50
  @ticks 200

  # Spieler an den Start setzen: :cluster = alle auf engem Raum (alle sehen sich, viel Kampf),
  # :spread = weit verteilt (jeder sieht nur NPCs)
  def world(n, layout, director?) do
    seed = 4
    state = State.new(seed, 0, director?: director?)

    state =
      Enum.reduce(1..n, state, fn i, st ->
        State.join(st, "p#{i}", "Spieler #{i}")
      end)

    place(state, n, layout)
  end

  defp place(state, n, layout) do
    Enum.reduce(1..n, state, fn i, st ->
      {x, y} =
        case layout do
          :cluster ->
            a = i / n * 2 * :math.pi()
            {12.0 * :math.cos(a) + 60.0, 12.0 * :math.sin(a) + 60.0}

          :spread ->
            a = i * 2.399963
            r = 90.0 * :math.sqrt(i)
            {r * :math.cos(a), r * :math.sin(a)}
        end

      State.update_ship(st, "p#{i}", fn s ->
        %{s | x: x, y: y, invuln_until: 0, heading: i * 0.7}
      end)
    end)
  end

  # Ein Takt: Eingaben (Bots), Schüsse, Simulation, Schnappschüsse mit JSON für alle Spieler
  def run(n, layout, director?) do
    state = world(n, layout, director?)
    players = for i <- 1..n, do: "p#{i}"

    {times, _} =
      Enum.map_reduce(1..@ticks, state, fn tick, st ->
        t0 = System.monotonic_time(:microsecond)

        # simple Spieler-KI: fahren, wechselnd drehen, regelmäßig beide Seiten feuern
        st =
          Enum.reduce(players, st, fn id, acc ->
            n_id = String.to_integer(String.trim_leading(id, "p"))
            turn = rem(div(tick + n_id * 7, 40), 3)
            keys = %{up?: true, left?: turn == 1, right?: turn == 2}
            acc = State.set_input(acc, id, keys)

            if rem(tick + n_id, 30) == 0 do
              {acc, _} = State.fire(acc, id, :left)
              {acc, _} = State.fire(acc, id, :right)
              acc
            else
              acc
            end
          end)

        t1 = System.monotonic_time(:microsecond)
        {st, events} = State.tick(st, @tick_ms)
        t2 = System.monotonic_time(:microsecond)

        # Schnappschüsse bauen (das macht der Welt-Prozess) ...
        ctx = State.snapshot_context(st, events)
        snaps = for id <- players, snap = State.snapshot_for(st, id, ctx), do: snap
        t3 = System.monotonic_time(:microsecond)

        # ... und als JSON kodieren (das macht in Produktion je Spieler dessen Socket-Prozess,
        # also parallel auf mehreren Kernen und nicht im Takt der Welt)
        {bytes, count} =
          Enum.reduce(snaps, {0, 0}, fn snap, {b, c} ->
            {b + byte_size(Jason.encode!(snap)), c + 1}
          end)

        t4 = System.monotonic_time(:microsecond)

        {%{
           input: t1 - t0,
           sim: t2 - t1,
           snap: t3 - t2,
           total: t3 - t0,
           encode: t4 - t3,
           bytes: if(count > 0, do: div(bytes, count), else: 0),
           ships: map_size(st.ships),
           balls: length(st.balls)
         }, st}
      end)

    # die ersten Takte (Aufwärmen, Cache) nicht mitzählen
    times = Enum.drop(times, 20)
    totals = times |> Enum.map(& &1.total) |> Enum.sort()

    %{
      n: n,
      layout: layout,
      director?: director?,
      avg_ms: avg(totals) / 1000,
      p95_ms: Enum.at(totals, round(length(totals) * 0.95) - 1) / 1000,
      max_ms: List.last(totals) / 1000,
      sim_ms: avg(Enum.map(times, & &1.sim)) / 1000,
      snap_ms: avg(Enum.map(times, & &1.snap)) / 1000,
      encode_ms: avg(Enum.map(times, & &1.encode)) / 1000,
      kb_per_snap: avg(Enum.map(times, & &1.bytes)) / 1000,
      ships: times |> List.last() |> Map.get(:ships),
      balls_max: times |> Enum.map(& &1.balls) |> Enum.max()
    }
  end

  defp avg([]), do: 0.0
  defp avg(list), do: Enum.sum(list) / length(list)

  def report(r) do
    verdict =
      cond do
        r.p95_ms > 50 -> "ZU LANGSAM"
        r.p95_ms > 25 -> "grenzwertig"
        true -> "ok"
      end

    IO.puts(
      "#{String.pad_leading(Integer.to_string(r.n), 3)} Spieler #{String.pad_trailing(Atom.to_string(r.layout), 7)} " <>
        "Schiffe #{String.pad_leading(Integer.to_string(r.ships), 3)} · " <>
        "Takt Ø #{fmt(r.avg_ms)} ms · p95 #{fmt(r.p95_ms)} ms · max #{fmt(r.max_ms)} ms " <>
        "(Sim #{fmt(r.sim_ms)} + Bauen #{fmt(r.snap_ms)}) · JSON in Sockets Σ #{fmt(r.encode_ms)} ms · " <>
        "#{fmt(r.kb_per_snap)} kB/Schnappschuss · " <>
        "Kugeln max #{r.balls_max} → #{verdict}"
    )
  end

  defp fmt(x), do: :erlang.float_to_binary(x * 1.0, decimals: 1) |> String.pad_leading(5)
end

counts =
  case System.argv() do
    [] -> [5, 10, 20, 40, 60]
    args -> Enum.map(args, &String.to_integer/1)
  end

IO.puts(
  "Lasttest: #{length(counts)} Stufen, Takt 50 ms, 200 Takte je Lauf (inkl. Director-NPCs)\n"
)

for layout <- [:spread, :cluster], n <- counts do
  LoadTest.run(n, layout, true) |> LoadTest.report()
end
