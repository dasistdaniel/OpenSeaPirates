defmodule Osp.WorldSeed do
  @moduledoc """
  Der Seed der Hauptwelt. Die Welt (Gelände, Häfen, Gebiete) ist komplett aus dem Seed berechnet, und
  Eroberungen (`Osp.Territory`) verweisen auf Hafen-IDs dieser Welt. Der Seed muss deshalb Neustarts und
  Deploys überleben:

    * `OSP_SEED` gesetzt: dieser Wert gilt (wird nicht gespeichert),
    * sonst steht er in `seed.txt` im Datenverzeichnis (`OSP_DATA_DIR`, Volume): vorhanden = weiterverwenden,
      fehlt oder ist ungültig = einmal würfeln und dort speichern,
    * ohne Datenverzeichnis (Tests, Entwicklung): zufällig bei jedem Start.

  Eine andere Welt gibt es nur, wenn `seed.txt` gelöscht oder geändert wird (dann auch `territory.json` neu).
  """

  @file_name "seed.txt"
  @max 1_000_000_000

  @doc "Seed der Hauptwelt bestimmen (siehe Moduldoc)."
  @spec resolve(String.t() | nil, integer() | nil) :: pos_integer()
  def resolve(_dir, seed) when is_integer(seed), do: seed
  def resolve(nil, _configured), do: random()

  def resolve(dir, _configured) do
    path = Path.join(dir, @file_name)

    case read(path) do
      {:ok, seed} ->
        seed

      :error ->
        seed = random()
        write(path, seed)
        seed
    end
  end

  defp random, do: :rand.uniform(@max)

  defp read(path) do
    with {:ok, text} <- File.read(path),
         {seed, ""} <- text |> String.trim() |> Integer.parse(),
         true <- seed >= 1 and seed <= @max do
      {:ok, seed}
    else
      _ -> :error
    end
  end

  defp write(path, seed) do
    File.mkdir_p!(Path.dirname(path))
    tmp = path <> ".tmp"
    File.write!(tmp, Integer.to_string(seed) <> "\n")
    File.rename!(tmp, path)
  end
end
