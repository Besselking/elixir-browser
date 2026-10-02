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
end
