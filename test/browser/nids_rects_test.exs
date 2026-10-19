defmodule Browser.NidsRectsTest do
  use ExUnit.Case, async: true
  alias Browser.Nids

  # html (0) > body (1) > box (2) that clips > strip (3)
  @parents %{0 => nil, 1 => 0, 2 => 1, 3 => 2}

  test "what an ancestor clips does not widen html and body, but the elements keep their boxes" do
    items = [
      %{nid: 2, x: 0, y: 0, w: 400, h: 100, type: :box},
      %{nid: 3, x: 0, y: 0, w: 10_000, h: 100, type: :rect, clip: %{x: 0, y: 0, w: 400, h: 100}}
    ]

    rects = Nids.rects(items, @parents)
    assert rects[0] == {0, 0, 400, 100}
    assert rects[1] == {0, 0, 400, 100}
    assert rects[3] == {0, 0, 10_000, 100}
    assert rects[2] == {0, 0, 10_000, 100}
  end

  test "an item with no clip widens everything it is in" do
    items = [%{nid: 3, x: 5, y: 6, w: 700, h: 20, type: :rect}]
    rects = Nids.rects(items, @parents)
    assert rects[1] == {5, 6, 700, 20}
  end
end
