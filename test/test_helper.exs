if Code.ensure_loaded?(Dotenvy) do
  cwd = File.cwd!()

  [".env", ".env.test"]
  |> Enum.map(&Path.absname(&1, cwd))
  |> Enum.filter(&File.exists?/1)
  |> Enum.flat_map(&Dotenvy.source!/1)
  |> Enum.each(fn {key, value} ->
    if System.get_env(key) in [nil, ""] do
      System.put_env(key, value)
    end
  end)
end

ExUnit.configure(exclude: [live: true])
ExUnit.start()
