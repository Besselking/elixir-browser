defmodule Browser.ReTest do
  use ExUnit.Case, async: true

  import Browser.Re, only: [re: 1, split_words: 1, compiled: 2]

  test "re/1 gives the same regex as the literal, and keeps it for the next call" do
    first = re(~r/\A[+-]?\d+\z/i)
    assert Regex.source(first) == "\\A[+-]?\\d+\\z"
    assert Regex.opts(first) == [:caseless]
    assert Regex.match?(first, "-12")
    refute Regex.match?(first, "12px")
    assert :persistent_term.get({Browser.Re, "\\A[+-]?\\d+\\z", ~c"i"}) == first
    assert re(~r/\A[+-]?\d+\z/i) == first
  end

  test "re/1 takes only a literal with no interpolation" do
    assert_raise ArgumentError, fn ->
      Code.eval_string(~S|import Browser.Re; unit = "px"; re(~r/\d+#{unit}/)|)
    end
  end

  test "compiled/2 gives the regex that Regex.compile!/2 gives, and keeps it under the key of re/1" do
    source = "\\A\\x{4E00}+\\z"
    first = compiled(source, ~c"u")
    assert Regex.source(first) == Regex.source(Regex.compile!(source, "u"))
    assert Regex.opts(first) == Regex.opts(Regex.compile!(source, "u"))
    assert Regex.match?(first, "\u4E00\u4E00")
    assert compiled(source, ~c"u") == first
    assert re(~r/\A\x{4E00}+\z/u) == first
  end

  test "the literals that took the place of interpolated regexes are the same regexes" do
    for q <- [?", ?'] do
      new =
        if q == ?", do: re(~r/\A(?:[^\\\n"]|\\.)*(.?)/s), else: re(~r/\A(?:[^\\\n']|\\.)*(.?)/s)

      old = ~r/\A(?:[^\\\n#{<<q>>}]|\\.)*(.?)/s
      assert {Regex.source(new), Regex.opts(new)} == {Regex.source(old), Regex.opts(old)}
    end

    for name <- ["script", "style"] do
      new = if name == "script", do: re(~r/<\/script\s*>/i), else: re(~r/<\/style\s*>/i)
      old = ~r/<\/#{name}\s*>/i
      assert {Regex.source(new), Regex.opts(new)} == {Regex.source(old), Regex.opts(old)}
    end

    for unit <- ["ch", "ex"] do
      new =
        if unit == "ch",
          do: re(~r/(?<![\w.])([+-]?(?:\d+\.?\d*|\.\d+))ch\b/i),
          else: re(~r/(?<![\w.])([+-]?(?:\d+\.?\d*|\.\d+))ex\b/i)

      old = ~r/(?<![\w.])([+-]?(?:\d+\.?\d*|\.\d+))#{unit}\b/i
      assert {Regex.source(new), Regex.opts(new)} == {Regex.source(old), Regex.opts(old)}
    end
  end

  test "split_words/1 gives the words that String.split/1 gives" do
    # every code point that String.split/1 splits at, the no-break spaces that it keeps, and
    # some letters, in many orders
    chars =
      Enum.map(
        [?\s, ?\t, ?\n, ?\v, ?\f, ?\r, 0x1C, 0x85, 0xA0, 0x1680, 0x2000, 0x2006, 0x2007, 0x2008] ++
          [0x200A, 0x200B, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, ?a, ?b, ?-, 0xE9, 0x4E00],
        &<<&1::utf8>>
      )

    :rand.seed(:exsss, {1, 2, 3})

    for _ <- 1..3000 do
      text = Enum.map_join(1..:rand.uniform(12), fn _ -> Enum.random(chars) end)
      assert split_words(text) == String.split(text), inspect(text)
    end

    assert split_words("") == []
    assert split_words("  todo-item   completed ") == ["todo-item", "completed"]
    # (not valid UTF-8: the same bytes as String.split/1 too)
    assert split_words(<<0xFF, ?\s, 0xC3>>) == String.split(<<0xFF, ?\s, 0xC3>>)
  end
end
