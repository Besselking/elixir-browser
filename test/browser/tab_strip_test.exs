defmodule Browser.TabStripTest do
  use ExUnit.Case, async: true
  alias Browser.TabStrip

  test "tabs share the strip, up to a maximum and down to a minimum" do
    assert [{4, 220}] = TabStrip.layout(1, 960)
    [{x0, w0}, {x1, _}] = TabStrip.layout(2, 960)
    assert x1 == x0 + w0
    assert {_, 70} = List.last(TabStrip.layout(30, 960))
  end

  test "hit finds a tab, its close box and the new tab button" do
    [{x0, w0}, {x1, _}] = TabStrip.layout(2, 960)
    assert {:tab, 0} = TabStrip.hit(2, 960, x0 + 10, 15)
    assert {:close, 0} = TabStrip.hit(2, 960, x0 + w0 - 10, 15)
    assert {:tab, 1} = TabStrip.hit(2, 960, x1 + 10, 15)
    {px, _} = TabStrip.plus(2, 960)
    assert :new = TabStrip.hit(2, 960, px + 5, 15)
    assert nil == TabStrip.hit(2, 960, 900, 15)
    assert nil == TabStrip.hit(2, 960, x0 + 10, 40)
  end

  test "titles are cut to a sane length on one line" do
    assert TabStrip.clip("a\n  b") == "a b"
    assert String.length(TabStrip.clip(String.duplicate("x", 500))) == 80
  end

  test "the palette follows the toolbar colour, light or dark" do
    light = TabStrip.palette({240, 240, 240}, {160, 160, 160}, {0, 0, 0})
    assert light.active == {240, 240, 240}
    assert elem(light.strip, 0) < 240

    dark = TabStrip.palette({40, 40, 40}, {90, 90, 90}, {230, 230, 230})
    assert dark.active == {40, 40, 40}
    assert elem(dark.strip, 0) < 40
    assert dark.text == {230, 230, 230}
  end

  test "index_at is the tab under x, clamped to the ends" do
    [{x0, _}, {x1, w1}, {x2, _}] = TabStrip.layout(3, 960)
    assert 0 == TabStrip.index_at(3, 960, 0)
    assert 0 == TabStrip.index_at(3, 960, x0 + 5)
    assert 1 == TabStrip.index_at(3, 960, x1 + w1 - 1)
    assert 2 == TabStrip.index_at(3, 960, x2 + 5)
    assert 2 == TabStrip.index_at(3, 960, 5000)
  end
end
