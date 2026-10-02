defmodule Browser.UILinkTest do
  use ExUnit.Case, async: true

  alias Browser.UI

  defp link(href, x, y, w, h, extra \\ %{}),
    do: Map.merge(%{type: :text, href: href, x: x, y: y, w: w, h: h}, extra)

  test "finds the link under the pointer, the first painted wins" do
    items = [
      %{type: :rect, x: 0, y: 0, w: 500, h: 500},
      link("/a", 10, 10, 50, 16),
      link("/b", 10, 10, 50, 16),
      link("/far", 10, 1000, 50, 16)
    ]

    index = UI.links(items)
    assert UI.link_at(index, 20, 15) == "/a"
    assert UI.link_at(index, 20, 1005) == "/far"
    assert UI.link_at(index, 200, 15) == nil
    assert UI.link_at(index, 20, 500) == nil
  end

  test "a link taller than a band is found anywhere along it" do
    index = UI.links([link("/tall", 0, 10, 20, 300)])
    for y <- [10, 100, 200, 313], do: assert(UI.link_at(index, 5, y) == "/tall")
    assert UI.link_at(index, 5, 320) == nil
  end

  test "a link scrolled out of its clip box is not hit" do
    clip = %{x: 0, y: 0, w: 100, h: 20}
    index = UI.links([link("/c", 10, 40, 30, 10, %{clip: clip})])
    assert UI.link_at(index, 15, 45) == nil
  end

  describe "sticky and fixed items" do
    @sticky %{top: 0, y0: 100}

    test "stick_shift: nothing, until the page has scrolled past a sticky box" do
      assert UI.stick_shift(%{}, 500) == 0
      assert UI.stick_shift(%{stick: @sticky}, 50) == 0
      assert UI.stick_shift(%{stick: @sticky}, 100) == 0
      assert UI.stick_shift(%{stick: @sticky}, 250) == 150
    end

    test "stick_shift keeps a sticky box `top` px from the top of the window" do
      stick = %{top: 20, y0: 100}
      assert UI.stick_shift(%{stick: stick}, 80) == 0
      # scrolled 300: the box would be at 100 - 300 = -200; it is held at 20
      assert UI.stick_shift(%{stick: stick}, 300) == 220
    end

    test "the shift is whole pixels even when positions are fractional" do
      assert UI.stick_shift(%{stick: %{top: 0.0, y0: 52}}, 460) == 408
      assert is_integer(UI.stick_shift(%{stick: %{top: 0.5, y0: 52}}, 460))
    end

    test "a fixed item follows the window all the way" do
      assert UI.stick_shift(%{stick: :fixed}, 0) == 0
      assert UI.stick_shift(%{stick: :fixed}, 640) == 640
    end

    test "links of sticky items are not in the normal index" do
      items = [link("/a", 0, 0, 40, 16, %{stick: @sticky}), link("/b", 0, 30, 40, 16)]
      index = UI.links(items)
      assert UI.link_at(index, 10, 5) == nil
      assert UI.link_at(index, 10, 35) == "/b"
    end

    test "sticky_hit finds a link where the box has been drawn, not where it was laid out" do
      items = [
        %{type: :rect, x: 0, y: 100, w: 500, h: 40, stick: @sticky},
        link("/home", 10, 110, 40, 16, %{stick: @sticky})
      ]

      # scrolled 300: the header is at the top of the window
      assert UI.sticky_hit(items, 20, 12, 300) == {:link, "/home"}
      # not where it was laid out
      assert UI.sticky_hit(items, 20, 112 - 300 + 400, 300) == nil
      # before the page scrolls to it, it is where it was laid out
      assert UI.sticky_hit(items, 20, 112, 0) == {:link, "/home"}
    end

    test "the rest of a stuck box covers the page below it" do
      items = [%{type: :rect, x: 0, y: 100, w: 500, h: 40, stick: @sticky}]
      assert UI.sticky_hit(items, 300, 20, 300) == :cover
      assert UI.sticky_hit(items, 300, 60, 300) == nil
    end

    test "a fixed box is where it was laid out, in the window" do
      items = [link("/x", 10, 600, 40, 16, %{stick: :fixed})]
      assert UI.sticky_hit(items, 20, 605, 1000) == {:link, "/x"}
      assert UI.sticky_hit(items, 20, 5, 1000) == nil
    end

    test "controls come with the page y their items have, for placing the caret" do
      items = [%{type: :rect, x: 0, y: 100, w: 200, h: 24, cid: 7, stick: @sticky}]
      assert UI.sticky_hit(items, 50, 10, 300) == {:control, 7, 10 + 300 - 200}
    end

    test "nothing sticky, nothing found" do
      assert UI.sticky_hit([], 5, 5, 0) == nil
    end
  end
end
