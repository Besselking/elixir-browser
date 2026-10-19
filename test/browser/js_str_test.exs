defmodule Browser.JSStrTest do
  use ExUnit.Case, async: true

  alias Browser.JS.Str

  # the characters long strings are made of: one, two, three and four bytes, and a lone surrogate
  @parts [
    "a",
    "é",
    "€",
    "😀",
    "bc",
    "\n",
    "漢字",
    Str.from_units([0xD83D]),
    Str.from_units([0xDE00])
  ]

  defp random_string(seed, size) do
    :rand.seed(:exsss, {seed, seed, seed})
    Str.join(for _ <- 1..size, do: Enum.random(@parts))
  end

  defp naive_slice(s, from, count) do
    s |> Str.units() |> Enum.drop(from) |> Enum.take(count) |> Str.from_units()
  end

  # `ascii?/1` takes seven bytes at a time, then one at a time: a byte above 127 at any place
  # must be seen, in a short string and in a long one (which is kept for the next call)
  test "ascii? sees a byte above 127 at every place" do
    for len <- Enum.concat(0..22, [63, 64, 65, 70, 71, 72]),
        pos <- -1..(len - 1)//1,
        b <- [0x80, 0xC3, 0xFF] do
      s =
        for i <- 0..(len - 1)//1,
            into: <<>>,
            do: if(i == pos, do: <<b>>, else: <<?a + rem(i, 26)>>)

      assert Str.ascii?(s) == (pos == -1), inspect({len, pos, b})
    end

    # 0x7F is the last ASCII byte
    assert Str.ascii?(String.duplicate("\x7F", 15))
    assert Str.ascii?("")
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

  # Characters for the case tests: ASCII (letters, digits, controls), Latin-1, and other scripts.
  # Some have special casing: ß becomes SS, İ becomes i with a dot above, ŉ and ﬁ become two
  # letters, Σ has a final form. A lone surrogate is not valid UTF-8.
  @case_parts [
    ?A..?Z,
    ?a..?z,
    ?0..?9,
    [?\s, ?\t, ?\n, 0, 0x7F, ?-, ?_, ?@, ?[, ?`, ?{],
    0xC0..0xFF,
    [0xDF, 0xB5, 0x130, 0x131, 0x149, 0x17F, 0x1C5, 0x3A3, 0x3C2, 0x390, 0x1E9E, 0x2126],
    [0x212A, 0xFB01, 0x587, 0x10400, 0x10428, 0x1F600, 0x301, 0x10A0, 0x13A0, 0xFF21]
  ]

  defp case_string(size, kinds) do
    for _ <- 1..size//1, into: "" do
      case Enum.random(kinds) do
        :lone -> Str.from_units([Enum.random(0xD800..0xDFFF)])
        k -> <<Enum.random(Enum.at(@case_parts, k))::utf8>>
      end
    end
  end

  test "downcase and upcase give the same result as String.downcase and String.upcase" do
    :rand.seed(:exsss, {7, 7, 7})
    ascii = [0, 1, 2, 3]
    latin1 = ascii ++ [4]
    all = latin1 ++ [5, 6, :lone]

    for kinds <- [[0], [1], [1, 2, 3], ascii, latin1, all, [5], [6]], _ <- 1..400 do
      s = case_string(:rand.uniform(40) - 1, kinds)
      assert Str.downcase(s) == String.downcase(s), inspect(s)
      assert Str.upcase(s) == String.upcase(s), inspect(s)
    end

    for s <- ["", "ß", "İ", "ﬁ", "ΌΣΟΣ", "ǅ", "straße", "İstanbul", "ÿ", "DIV", "div"] do
      assert Str.downcase(s) == String.downcase(s)
      assert Str.upcase(s) == String.upcase(s)
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
