defmodule Browser.JSStrTest do
  use ExUnit.Case, async: true

  alias Browser.JS.Str

  # the characters long strings are made of: one, two, three and four bytes, and a lone surrogate
  @parts ["a", "é", "€", "😀", "bc", "\n", "漢字", Str.from_units([0xD83D]), Str.from_units([0xDE00])]

  defp random_string(seed, size) do
    :rand.seed(:exsss, {seed, seed, seed})
    Str.join(for _ <- 1..size, do: Enum.random(@parts))
  end

  defp naive_slice(s, from, count) do
    s |> Str.units() |> Enum.drop(from) |> Enum.take(count) |> Str.from_units()
  end

  test "length, byte offsets and slices of long strings agree with the code unit list" do
    for seed <- 1..6 do
      s = random_string(seed, 700 * seed)
      units = Str.units(s)
      assert Str.length(s) == length(units)

      for _ <- 1..60 do
        from = :rand.uniform(length(units) + 4) - 3
        count = :rand.uniform(300)
        assert Str.slice(s, from, count) == naive_slice(s, max(from, 0), count)
        assert Str.slice(s, from, nil) == units |> Enum.drop(max(from, 0)) |> Str.from_units()
      end

      for _ <- 1..60 do
        n = :rand.uniform(length(units) + 4) - 3
        bytes = Str.byte_offset(s, n)
        assert bytes == slow_offset(s, n)
        assert Str.units_before(s, bytes) <= max(n, 0)
      end
    end
  end

  test "an index of one string survives work on other strings" do
    a = random_string(10, 900)
    b = random_string(11, 900)
    la = Str.length(a)
    lb = Str.length(b)

    for _ <- 1..5 do
      assert Str.length(a) == la
      assert Str.length(b) == lb
      assert Str.slice(a, 100, 50) == naive_slice(a, 100, 50)
      assert Str.slice(b, 100, 50) == naive_slice(b, 100, 50)
    end
  end

  # the byte offset by walking the whole string
  defp slow_offset(s, n) do
    if n <= 0, do: 0, else: walk(s, n, 0)
  end

  defp walk(s, n, acc) when n <= 0 or acc >= byte_size(s), do: acc

  defp walk(s, n, acc) do
    b = :binary.at(s, acc)

    {size, weight} =
      cond do
        b < 0x80 -> {1, 1}
        b < 0xE0 -> {2, 1}
        b < 0xF0 -> {3, 1}
        true -> {4, 2}
      end

    if weight > n, do: acc, else: walk(s, n - weight, acc + size)
  end
end
