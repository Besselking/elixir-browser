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

  describe "parse_alpha/1" do
    test "keeps the alpha channel, 0..255" do
      assert Color.parse_alpha("rgba(0, 0, 0, 0.5)") == {0, 0, 0, 128}
      assert Color.parse_alpha("rgb(10 20 30 / 25%)") == {10, 20, 30, 64}
      assert Color.parse_alpha("#ff000080") == {255, 0, 0, 128}
      assert Color.parse_alpha("#f008") == {255, 0, 0, 136}
      assert Color.parse_alpha("hsla(0, 100%, 50%, 0.1)") == {255, 0, 0, 26}
    end

    test "opaque colours have alpha 255, transparent has 0" do
      assert Color.parse_alpha("#369") == {51, 102, 153, 255}
      assert Color.parse_alpha("red") == {255, 0, 0, 255}
      assert Color.parse_alpha("rgb(1,2,3)") == {1, 2, 3, 255}
      assert Color.parse_alpha("transparent") == {0, 0, 0, 0}
      assert Color.parse_alpha("rgba(9,9,9,0)") == {9, 9, 9, 0}
    end

    test "numbers without a leading zero" do
      assert Color.parse_alpha("rgba(0,0,0,.5)") == {0, 0, 0, 128}
      assert Color.parse_alpha("rgb(0 0 0 / .25)") == {0, 0, 0, 64}
      assert Color.parse("rgba(0, 0, 0, .5)") == {128, 128, 128}
      assert Color.parse_alpha("hsla(120, 100%, 25%, .5)") == {0, 128, 0, 128}
    end

    test "currentcolor and garbage" do
      assert Color.parse_alpha("currentColor") == :current
      assert Color.parse_alpha("nope") == nil
      assert Color.parse_alpha("var(--x)") == nil
    end

    test "light-dark takes the light value" do
      assert Color.parse_alpha("light-dark(rgba(1,2,3,.5), #000)") == {1, 2, 3, 128}
    end

    test "parse/1 still blends the same colours over white" do
      assert Color.parse("rgba(0, 0, 0, 0.5)") == {128, 128, 128}
      assert Color.parse("rgba(9,9,9,0)") == :transparent
    end
  end
end
