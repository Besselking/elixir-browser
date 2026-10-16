defmodule Browser.ReTest do
  use ExUnit.Case, async: true

  import Browser.Re, only: [re: 1]

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
end
