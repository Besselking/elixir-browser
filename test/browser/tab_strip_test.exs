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
end
