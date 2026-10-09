defmodule Browser.Shard do
  @moduledoc """
  Splits a list of test files into shards, so that several machines (CI jobs) can each run a
  part of a suite. The files are sorted and dealt out one by one, so that every shard gets a
  similar mix of slow and fast directories.
  """

  @doc "Parses `\"2/4\"` into `{2, 4}`. Raises on anything else."
  def parse!(text) do
    with [n, m] <- String.split(text, "/"),
         {n, ""} <- Integer.parse(n),
         {m, ""} <- Integer.parse(m),
         true <- m >= 1 and n >= 1 and n <= m do
      {n, m}
    else
      _ -> raise ArgumentError, "--shard wants N/M with 1 <= N <= M, got #{inspect(text)}"
    end
  end

  @doc "The files of shard `n` of `m` (1-based)."
  def take(files, {n, m}) do
    files
    |> Enum.sort()
    |> Enum.with_index()
    |> Enum.filter(fn {_, i} -> rem(i, m) == n - 1 end)
    |> Enum.map(&elem(&1, 0))
  end
end
