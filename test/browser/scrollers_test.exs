defmodule Browser.ScrollersTest do
  use ExUnit.Case, async: true
  alias Browser.{Layout, Page, Scrollbars, Scrollers}

  @reset "<style>body{margin:0} p,div{margin:0}</style>"

  defp measure(text, style), do: String.length(text) * div(style.size, 2)

  defp run(html, width \\ 400) do
    {items, _} = layout(html, width, scrollers: true)
    Scrollers.index(items)
  end

  defp layout(html, width, opts) do
    page = Page.build(@reset <> html, "about:home")
    Layout.layout(page.nodes, width, &measure/2, 600, opts)
  end

  defp y_of(items, text), do: Enum.find(items, &(Map.get(&1, :text) == text)).y

  @box ~s(<div style="height:40px;overflow:auto"><p>l1</p><p>l2</p><p>l3</p><p>l4</p></div><p>after</p>)

  test "a box with overflow auto is a scroller that can scroll as far as its content reaches" do
    {items, scrollers} = run(@box)
    assert [{_sid, s}] = Map.to_list(scrollers)
    assert s.h == 40
    assert s.max_y > 0
    assert s.max_x == 0
    assert s.ov == {:auto, :auto}
    refute Enum.any?(items, &(&1.type == :scroller))
  end

  test "layout leaves the scrollers out unless asked" do
    {items, _} = layout(@box, 400, [])
    refute Enum.any?(items, &(&1.type == :scroller))
  end

  test "overflow hidden and visible do not scroll" do
    {_, none} = run(~s(<div style="height:40px;overflow:hidden"><p>a</p><p>b</p><p>c</p></div>))
    assert none == %{}
  end

  test "scrolling moves the content and its clip but not what is outside" do
    {items, scrollers} = run(@box)
    [{sid, s}] = Map.to_list(scrollers)
    soff = Scrollers.clamp(scrollers, %{sid => {0, 20}})
    moved = Scrollers.apply(items, scrollers, soff)

    assert y_of(moved, "l1") == y_of(items, "l1") - 20
    assert y_of(moved, "after") == y_of(items, "after")

    # what is scrolled out of the box is clipped away by the box, which stays where it is
    l1 = Enum.find(moved, &(Map.get(&1, :text) == "l1"))
    assert l1.clip.y == s.y
    assert l1.clip.h == s.h
  end

  test "the offset stays within what the content reaches" do
    {_, scrollers} = run(@box)
    [{sid, s}] = Map.to_list(scrollers)
    assert Scrollers.clamp(scrollers, %{sid => {50, 9999}}) == %{sid => {0, s.max_y}}
    assert Scrollers.clamp(scrollers, %{sid => {0, -5}}) == %{}
    assert Scrollers.clamp(scrollers, %{:nope => {0, 5}}) == %{}
  end

  test "overflow scroll on x scrolls sideways" do
    {_, scrollers} =
      run(
        ~s(<div style="width:100px;overflow-x:scroll"><pre>#{String.duplicate("w", 60)}</pre></div>)
      )

    [{_, s}] = Map.to_list(scrollers)
    assert s.max_x > 0
  end

  test "the wheel goes to the innermost scroller under the pointer, then the ones around it" do
    html =
      ~s(<div id="o" style="height:80px;overflow:auto"><div id="i" style="height:40px;overflow:auto"><p>a</p><p>b</p><p>c</p><p>d</p></div><p>x</p><p>y</p><p>z</p><p>w</p><p>v</p></div>)

    {_, scrollers} = run(html)
    assert map_size(scrollers) == 2
    {inner, _} = Enum.find(scrollers, fn {_, s} -> s.outer != [] end)
    {outer, _} = Enum.find(scrollers, fn {_, s} -> s.outer == [] end)
    s = scrollers[inner]
    assert Scrollers.at(scrollers, %{}, s.x + 2, s.y + 2) == [inner, outer]
    assert Scrollers.at(scrollers, %{}, 395, 590) == []

    # at its end the inner one cannot scroll on, the outer one can
    soff = %{inner => {0, s.max_y}}
    refute Scrollers.can_scroll?(scrollers, soff, inner, :y, 10)
    assert Scrollers.can_scroll?(scrollers, soff, inner, :y, -10)
    assert Scrollers.can_scroll?(scrollers, soff, outer, :y, 10)
  end

  test "an inner scroller moves with the one around it" do
    html =
      ~s(<div style="height:80px;overflow:auto"><p>top</p><div style="height:40px;overflow:auto"><p>a</p><p>b</p><p>c</p><p>d</p></div><p>x</p><p>y</p><p>z</p><p>w</p><p>v</p></div>)

    {items, scrollers} = run(html)
    {outer, _} = Enum.find(scrollers, fn {_, s} -> s.outer == [] end)
    {inner, _} = Enum.find(scrollers, fn {_, s} -> s.outer != [] end)
    soff = %{outer => {0, 30}, inner => {0, 10}}
    moved = Scrollers.apply(items, scrollers, soff)
    assert y_of(moved, "a") == y_of(items, "a") - 40
    assert y_of(moved, "x") == y_of(items, "x") - 30
    # (and is cut off where the box around it shows its content)
    assert Scrollers.visible(scrollers, soff, inner).y ==
             max(scrollers[inner].y - 30, scrollers[outer].y)
  end

  describe "scrollbars" do
    @view %{w: 400, h: 300, scroll: 0, scroll_x: 0, height: 300, content_w: 400}

    test "the page has none when it fits" do
      assert Scrollbars.bars(@view, %{}, %{}) == []
    end

    test "the thumb is as long as the share of the page the window shows" do
      [bar] = Scrollbars.bars(%{@view | height: 900, scroll: 300}, %{}, %{})
      assert %{id: :page, axis: :y, track: {388, 0, 12, 300}, max: 600} = bar
      {_, ty, _, th} = bar.thumb
      assert th == 100
      assert ty == 100
    end

    test "both bars leave the corner free" do
      bars = Scrollbars.bars(%{@view | height: 900, content_w: 800}, %{}, %{})
      assert [%{axis: :y, track: {_, _, _, 288}}, %{axis: :x, track: {_, _, 388, _}}] = bars
    end

    test "clicks find the thumb or the track on either side of it" do
      [bar] = bars = Scrollbars.bars(%{@view | height: 900, scroll: 300}, %{}, %{})
      assert {:thumb, ^bar} = Scrollbars.hit(bars, 394, 150)
      assert {:track, ^bar, -1} = Scrollbars.hit(bars, 394, 20)
      assert {:track, ^bar, 1} = Scrollbars.hit(bars, 394, 280)
      assert Scrollbars.hit(bars, 100, 150) == nil
    end

    test "dragging the thumb scrolls in proportion" do
      [bar] = Scrollbars.bars(%{@view | height: 900, scroll: 300}, %{}, %{})
      grab = Scrollbars.grab(bar, 394, 150)
      assert Scrollbars.offset_at(bar, 394, 200, grab) == 300.0 + 50 / 200 * 600
      assert Scrollbars.offset_at(bar, 394, 0, grab) < 0
    end

    test "a scroller has bars at its edge, cut to where it shows its content" do
      {_, scrollers} = run(@box)
      [{sid, s}] = Map.to_list(scrollers)
      [bar] = Scrollbars.bars(@view, scrollers, %{})
      assert bar.id == sid
      assert bar.axis == :y
      {x, y, w, h} = bar.track
      assert {x + w, y, h} == {s.x + s.w, s.y, s.h}
      assert bar.clip == %{x: s.x, y: s.y, w: s.w, h: s.h}
    end

    test "the items are drawn over the window, not scrolled with the page" do
      [bar] = Scrollbars.bars(%{@view | height: 900}, %{}, %{})
      [track, thumb] = Scrollbars.items([bar], 50, nil, false)
      assert %{stick: :fixed, x: 438, y: 0} = track
      assert thumb.w == 8
    end
  end
end
