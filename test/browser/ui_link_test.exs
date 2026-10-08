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

    test "a sticky box stops when it reaches the bottom of its block" do
      stick = %{top: 0, y0: 100, h: 50, limit: 400}
      assert UI.stick_shift(%{stick: stick}, 200) == 100
      # the box bottom (150 + shift) may not pass 400: at most 250
      assert UI.stick_shift(%{stick: stick}, 250) == 150
      assert UI.stick_shift(%{stick: stick}, 300) == 200
      assert UI.stick_shift(%{stick: stick}, 350) == 250
      assert UI.stick_shift(%{stick: stick}, 900) == 250
    end

    test "a box taller than its block does not stick at all" do
      assert UI.stick_shift(%{stick: %{top: 0, y0: 100, h: 300, limit: 350}}, 500) == 0
    end

    test "without a limit it sticks to the end" do
      assert UI.stick_shift(%{stick: %{top: 0, y0: 100, h: 50, limit: nil}}, 5000) == 4900
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

    test "where sticky boxes overlap, the one painted last (the last in the list) is hit" do
      stick = %{top: 0, y0: 0}

      items = [
        link("/under", 10, 10, 40, 16, %{stick: stick}),
        link("/over", 10, 10, 40, 16, %{stick: stick})
      ]

      assert UI.sticky_hit(items, 20, 15, 0) == {:link, "/over"}
    end

    test "nothing sticky, nothing found" do
      assert UI.sticky_hit([], 5, 5, 0) == nil
    end
  end

  describe "transformed items" do
    alias Browser.Transform

    # a 100 x 40 box at (0, 100), turned a quarter turn about its centre (50, 120)
    @turn Transform.matrix(%{"transform" => "rotate(90deg)"}, {0, 100, 100, 40})

    test "a link is found where the box is drawn, not where it was laid out" do
      items = [link("/a", 0, 100, 100, 40, %{xform: [@turn]})]
      # the quarter turn puts the right end of the box at the bottom: (50, 170)
      assert UI.sticky_hit(items, 50, 165, 0) == {:link, "/a"}
      # the middle of the old left end is now at the top, not at (5, 120)
      assert UI.sticky_hit(items, 5, 120, 0) == nil
    end

    test "not in the ordinary index" do
      items = [link("/a", 0, 100, 100, 40, %{xform: [@turn]})]
      assert UI.link_at(UI.links(items), 20, 110) == nil
    end

    test "a transformed box does not cover what is under it" do
      items = [%{type: :rect, x: 0, y: 100, w: 100, h: 40, xform: [@turn]}]
      assert UI.sticky_hit(items, 50, 120, 0) == nil
    end

    test "controls get the position they have in the box" do
      items = [%{type: :rect, x: 0, y: 100, w: 100, h: 40, cid: 3, xform: [@turn]}]
      assert {:control, 3, py} = UI.sticky_hit(items, 50, 165, 0)
      # the point where the box is, before it was turned: its right end
      assert_in_delta py, 120.0, 1.0e-6
    end

    test "boxes with two transformations are undone one after the other" do
      double = {2.0, 0.0, 0.0, 2.0, 0.0, 0.0}
      items = [link("/b", 0, 0, 10, 10, %{xform: [@turn, double]})]
      assert UI.sticky_hit(items, 1000, 1000, 0) == nil
    end

    test "a box that cannot be undone is never hit" do
      flat = {0.0, 0.0, 0.0, 0.0, 0.0, 0.0}
      assert UI.sticky_hit([link("/c", 0, 0, 10, 10, %{xform: [flat]})], 5, 5, 0) == nil
    end
  end
end

defmodule Browser.UIPageIndexTest do
  use ExUnit.Case, async: true
  alias Browser.UI

  defp box(y, h, extra \\ %{}), do: Map.merge(%{type: :rect, x: 0, y: y, w: 10, h: h}, extra)

  test "items are listed in the bands they reach, with their page order" do
    items = [box(0, 10), box(300, 10), box(0, 1000)]
    %{bands: bands} = UI.index_page(items)
    ids = fn b -> bands |> elem(b) |> Enum.map(&elem(&1, 1)) |> Enum.sort() end
    assert ids.(0) == [0, 2]
    assert ids.(1) == [1, 2]
    assert ids.(tuple_size(bands) - 1) == [2]
  end

  test "the canvas and sticky items are kept apart, sticky ones by z-index" do
    canvas = %{type: :canvas, color: {1, 2, 3}}
    a = box(0, 5, %{stick: :fixed, z: 5})
    b = box(0, 5, %{stick: :fixed, z: 1})
    page = UI.index_page([canvas, a, box(0, 5), b])
    assert page.canvas == canvas
    assert page.sticky == [b, a]
    assert [{_, 1}] = elem(page.bands, 0)
  end

  test "an empty page has one empty band" do
    assert %{bands: {[]}, sticky: [], canvas: nil} = UI.index_page([])
  end

  test "item_at finds the topmost element's item and skips unnumbered or sticky ones" do
    items = [
      %{type: :rect, x: 0, y: 0, w: 500, h: 500, nid: 1},
      %{type: :image, url: "http://t/p.png", x: 10, y: 10, w: 50, h: 40, nid: 2},
      %{type: :rect, x: 0, y: 0, w: 500, h: 500},
      %{type: :text, x: 10, y: 10, w: 50, h: 16, nid: 3, stick: %{}}
    ]

    assert UI.item_at(items, 20, 20).nid == 2
    assert UI.item_at(items, 200, 200).nid == 1
    assert UI.item_at(items, 900, 900) == nil
  end

  describe "nid_at" do
    test "the topmost numbered item at the point; markers and hidden items do not count" do
      items = [
        %{type: :rect, nid: 1, x: 0, y: 0, w: 500, h: 500},
        %{type: :text, nid: 2, x: 10, y: 10, w: 50, h: 16},
        %{type: :box, nid: 3, x: 0, y: 0, w: 500, h: 40},
        %{type: :text, nid: 4, x: 10, y: 10, w: 50, h: 16, hidden: true}
      ]

      assert UI.nid_at(items, 20, 15, 0) == 2
      assert UI.nid_at(items, 200, 200, 0) == 1
      assert UI.nid_at(items, 900, 900, 0) == nil
      # scrolled down 100: the window point is that much further down the page, past the text
      assert UI.nid_at(items, 20, 15, 100) == 1
    end

    test "a fixed item is where the window is, not where the page is" do
      items = [%{type: :rect, nid: 7, x: 0, y: 0, w: 500, h: 40, stick: :fixed}]
      assert UI.nid_at(items, 20, 20, 300) == 7
    end
  end
end
