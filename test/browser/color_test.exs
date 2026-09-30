defmodule Browser.ColorTest do
  use ExUnit.Case, async: true
  alias Browser.Color

  test "hex forms" do
    assert Color.parse("#fff") == {255, 255, 255}
    assert Color.parse("#36c") == {51, 102, 204}
    assert Color.parse("#3366CC") == {51, 102, 204}
    assert Color.parse("#00000000") == :transparent
    assert Color.parse("#ggg") == nil
    assert Color.parse("#12345") == nil
  end

  test "rgb and rgba, comma and space syntax, percentages" do
    assert Color.parse("rgb(255, 0, 0)") == {255, 0, 0}
    assert Color.parse("rgb(0 128 255)") == {0, 128, 255}
    assert Color.parse("rgb(100%, 0%, 0%)") == {255, 0, 0}
    assert Color.parse("rgba(0, 0, 0, 0)") == :transparent
    assert Color.parse("rgb(0 0 0 / 50%)") == {128, 128, 128}
  end

  test "alpha is blended over white" do
    assert Color.parse("rgba(0,0,0,0.5)") == {128, 128, 128}
    assert Color.parse("#00000080") == {127, 127, 127}
  end

  test "hsl" do
    assert Color.parse("hsl(0, 100%, 50%)") == {255, 0, 0}
    assert Color.parse("hsl(120 100% 25%)") == {0, 128, 0}
    assert Color.parse("hsl(0, 0%, 100%)") == {255, 255, 255}
  end

  test "keywords and names" do
    assert Color.parse("Red") == {255, 0, 0}
    assert Color.parse(" transparent ") == :transparent
    assert Color.parse("currentColor") == :current
    assert Color.parse("rebeccapurple") == {102, 51, 153}
    assert Color.parse("notacolor") == nil
    assert Color.parse("var(--x)") == nil
  end

  test "light-dark uses the light value" do
    assert Color.parse("light-dark(#fff, #000)") == {255, 255, 255}
  end
end
