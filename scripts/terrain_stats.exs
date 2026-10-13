# Landanteil, Inselgröße und Spawn-Qualität über viele Seeds messen:  ./mx run scripts/terrain_stats.exs
alias Osp.Terrain

for seed <- [1, 2, 3, 42, 1234] do
  n = 40_000
  rng = :rand.seed_s(:exsss, seed)

  {land, _} =
    Enum.reduce(1..n, {0, rng}, fn _, {acc, r} ->
      {a, r} = :rand.uniform_s(r)
      {b, r} = :rand.uniform_s(r)
      x = (a - 0.5) * 600
      y = (b - 0.5) * 600
      {if(Terrain.land?(seed, x, y), do: acc + 1, else: acc), r}
    end)

  # Hafen-/Spawnqualität: wie oft findet Spawn offenes Wasser
  spawned =
    for k <- 1..200 do
      {x, y, _h, _} = Osp.Spawn.pick(seed, [{0.0, 0.0}], [{0.0, 0.0}], :rand.seed_s(:exsss, k))
      Osp.Spawn.clear?(seed, x, y)
    end

  IO.puts(
    "seed #{seed}: Land #{Float.round(land / n * 100, 1)} %, Spawn ok #{Enum.count(spawned, & &1)}/200"
  )
end

# ASCII-Ausschnitt 120x50 WE
seed = 1

for j <- 0..49 do
  line =
    for i <- 0..119, into: "" do
      h = Terrain.height(seed, i - 60, j - 25)

      cond do
        h >= 0.74 -> "#"
        h >= Terrain.land_level() -> "+"
        h >= 0.58 -> "."
        true -> " "
      end
    end

  IO.puts(line)
end
