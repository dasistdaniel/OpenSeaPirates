# Seeds finden, bei denen ein Hafen nahe dem Ursprung liegt (Spawn ist in Ursprungsnähe):
#   ./mx run scripts/find_seed.exs
for seed <- 1..400 do
  ports =
    for cx <- -2..1, cy <- -2..1, p = Osp.Ports.in_chunk(seed, cx, cy), do: p

  near = Enum.filter(ports, fn p -> :math.sqrt(p.x * p.x + p.y * p.y) < 28 end)

  if near != [] do
    p = hd(near)
    # Weg frei? Gerade Linie zum Hafen ohne Land
    clear? =
      Enum.all?(0..40, fn k ->
        t = k / 40
        not Osp.Terrain.land?(seed, p.x * t, p.y * t)
      end)

    if clear?, do: IO.puts("seed #{seed}: #{p.name} bei (#{p.x}, #{p.y})")
  end
end
