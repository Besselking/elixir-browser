defmodule Browser.MediaQueryTest do
  use ExUnit.Case, async: true
  alias Browser.MediaQuery, as: MQ

  defp env(w \\ 1000, h \\ 800), do: %{type: "screen", width: w, height: h, dppx: 1.0}
  defp ok?(q, e \\ env()), do: MQ.eval(MQ.parse(q), e)

  test "media types" do
    assert ok?("")
    assert ok?("all")
    assert ok?("screen")
    refute ok?("print")
    refute ok?("speech")
    assert ok?("not print")
    refute ok?("not screen")
    assert ok?("only screen")
  end

  test "width features" do
    assert ok?("(min-width: 1000px)")
    refute ok?("(min-width: 1001px)")
    assert ok?("(max-width: 1000px)")
    refute ok?("(max-width: 999px)")
    assert ok?("(width: 1000px)")
    assert ok?("screen and (min-width: 500px) and (max-width: 1200px)")
    refute ok?("print and (min-width: 500px)")
  end

  test "em and rem lengths are 16px" do
    assert ok?("(min-width: 62.5em)")
    refute ok?("(min-width: 62.5625rem)")
  end

  test "comma is OR" do
    assert ok?("print, (min-width: 500px)")
    refute ok?("print, (min-width: 5000px)")
  end

  test "range syntax" do
    assert ok?("(width >= 1000px)")
    refute ok?("(width > 1000px)")
    assert ok?("(400px <= width <= 1200px)")
    refute ok?("(400px <= width < 1000px)")
    assert ok?("(500px < width)")
  end

  test "or between features" do
    assert ok?("(max-width: 100px) or (min-width: 900px)")
    refute ok?("(max-width: 100px) or (min-width: 1100px)")
  end

  test "discrete features use browser defaults" do
    assert ok?("(prefers-color-scheme: light)")
    refute ok?("(prefers-color-scheme: dark)")
    assert ok?("(hover: hover)")
    assert ok?("(pointer: fine)")
    assert ok?("(prefers-reduced-motion: no-preference)")
    refute ok?("(prefers-reduced-motion: reduce)")
    assert ok?("(orientation: landscape)")
    assert ok?("(orientation: portrait)", env(600, 900))
    assert ok?("(scripting: none)")
    refute ok?("(scripting)")
    assert ok?("(color)")
  end

  test "resolution" do
    assert ok?("(min-resolution: 1dppx)")
    refute ok?("(min-resolution: 2dppx)")
    assert ok?("(-webkit-min-device-pixel-ratio: 1)")
    refute ok?("(-webkit-min-device-pixel-ratio: 1.5)")
  end

  test "unknown features and malformed queries never match" do
    refute ok?("(frobnicate: 3)")
    refute ok?("(min-width: 1px) and banana")
    refute ok?("screen and min-width: 1px")
  end
end
