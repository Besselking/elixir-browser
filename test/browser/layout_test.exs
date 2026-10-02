defmodule Browser.LayoutTest do
  use ExUnit.Case, async: true
  alias Browser.{HTML, Layout}

  defp measure(text, style), do: String.length(text) * div(style.size, 2)

  defp run(html, width \\ 400), do: html |> HTML.parse() |> Layout.layout(width, &measure/2)
  defp texts(items), do: for(%{type: :text, text: t} <- items, do: t)

  test "emits words in order and skips script/style/head" do
    {items, _} =
      run("<head><title>x</title></head><style>a{}</style><p>hello <b>big</b> world</p>")

    assert texts(items) |> Enum.sort() == ["big", "hello", "world"]
  end

  test "wraps long text" do
    {items, _} = run("<p>" <> String.duplicate("word ", 40) <> "</p>", 200)
    ys = items |> Enum.map(& &1.y) |> Enum.uniq()
    assert length(ys) > 1
    assert Enum.all?(items, &(&1.x + &1.w <= 200))
  end

  test "paragraphs are separated vertically" do
    {items, _} = run("<p>a</p><p>b</p>")
    [a] = Enum.filter(items, &(&1.text == "a"))
    [b] = Enum.filter(items, &(&1.text == "b"))
    assert b.y > a.y + 14
  end

  test "headings are larger and bold; links carry href" do
    {items, _} = run(~s(<h1>T</h1><a href="/x">l</a>))
    assert %{size: 32, bold: true} = Enum.find(items, &(&1.text == "T"))
    assert %{href: "/x"} = Enum.find(items, &(&1.text == "l"))
  end

  test "list items get markers and are indented" do
    {items, _} = run("<ul><li>a</li><li>b</li></ul><ol><li>c</li></ol>")
    assert "•" in texts(items)
    assert "1." in texts(items)
    assert Enum.find(items, &(&1.text == "a")).x > 12
  end

  test "inline elements glue without spaces" do
    {items, _} = run("<p>foo<b>bar</b></p>")
    [foo] = Enum.filter(items, &(&1.text == "foo"))
    [bar] = Enum.filter(items, &(&1.text == "bar"))
    assert bar.x == foo.x + foo.w
  end

  test "title extraction" do
    assert Layout.title(HTML.parse("<head><title> A\n B </title></head>")) == "A B"
  end

  test "space between words of one link is covered by the link" do
    {items, _} = run(~s(<a href="/x">foo bar</a> baz))
    foo = Enum.find(items, &(&1.text == "foo"))
    bar = Enum.find(items, &(&1.text == "bar"))
    baz = Enum.find(items, &(&1.text == "baz"))
    assert foo.x + foo.w == bar.x
    assert baz.x > bar.x + bar.w
  end

  describe "styled layout" do
    alias Browser.Page

    # runs the full cascade so UA + author CSS apply
    defp styled(html, width \\ 400) do
      page = Page.build(html, "about:home")
      Layout.layout(page.nodes, width, &measure/2)
    end

    defp word(items, text), do: Enum.find(items, &(Map.get(&1, :text) == text))

    test "color, size, weight from CSS reach the items" do
      {items, _} =
        styled(
          "<style>.x { color: #ff0000; font-size: 20px; font-weight: bold }</style><p class=x>hi</p>"
        )

      assert %{color: {255, 0, 0}, size: 20, bold: true} = word(items, "hi")
    end

    test "links are blue and underlined by default, author CSS can remove it" do
      {items, _} = styled(~s(<a href="/x">a</a>))
      assert %{color: {0, 0, 238}, underline: true} = word(items, "a")

      {items, _} =
        styled(~s(<style>a { text-decoration: none; color: #36c }</style><a href="/x">a</a>))

      assert %{color: {51, 102, 204}, underline: false, href: "/x"} = word(items, "a")
    end

    test "underlined text is bridged across spaces" do
      {items, _} = styled("<u>foo bar</u>")
      assert word(items, "foo").x + word(items, "foo").w == word(items, "bar").x
    end

    test "text-align centers and right-aligns lines" do
      {items, _} =
        styled(~s(<p style="text-align:center">ab</p><p style="text-align:right">cd</p>), 400)

      ab = word(items, "ab")
      cd = word(items, "cd")
      assert_in_delta ab.x + ab.w / 2, 200, 4
      assert cd.x + cd.w == 400 - 4
    end

    test "block backgrounds become rects placed before the text" do
      {items, _} = styled(~s(<div style="background:#eee; padding: 5px"><p>hi</p></div>))
      assert [%{type: :rect, color: {238, 238, 238}} = rect | _] = items
      hi = word(items, "hi")
      assert hi.y > rect.y and hi.y < rect.y + rect.h
      assert rect.h > 16
    end

    test "adjacent vertical margins collapse to the larger one" do
      {a, _} = styled("<style>p { margin: 0 }</style><p>a</p><p>b</p>")
      {b, _} = styled("<style>p { margin: 0 } p + p { margin-top: 30px }</style><p>a</p><p>b</p>")
      {c, _} = styled("<style>p { margin: 20px 0 }</style><p>a</p><p>b</p>")
      gap = fn items -> word(items, "b").y - word(items, "a").y end
      assert gap.(b) - gap.(a) == 30
      assert gap.(c) - gap.(a) == 20
    end

    test "margin-left and padding-left indent content" do
      {items, _} =
        styled(~s(<div style="margin-left: 30px; padding-left: 10px">x</div><div>y</div>))

      assert word(items, "x").x - word(items, "y").x == 40
    end

    test "list-style none removes markers; default lists have them" do
      {items, _} = styled("<ul><li>a</li></ul>")
      assert "•" in texts(items)
      {items, _} = styled("<style>ul { list-style: none }</style><ul><li>a</li></ul>")
      refute "•" in texts(items)
      {items, _} = styled("<ol><li>a</li><li>b</li></ol>")
      assert ["1.", "2."] -- texts(items) == []
    end

    test "a marker stays on the line of a block-level first child" do
      {items, _} = styled("<ul><li><div>text</div></li></ul>")
      assert word(items, "•").y == word(items, "text").y
    end

    test "display:inline list items flow on one line" do
      css = "<style>ul { list-style: none; margin: 0; padding: 0 } li { display: inline }</style>"
      {items, _} = styled(css <> "<ul><li>a</li><li>b</li></ul>")
      assert word(items, "a").y == word(items, "b").y
    end

    test "flex rows lay block children side by side" do
      css = "<style>.row { display: flex }</style>"
      {items, _} = styled(css <> ~s(<div class="row"><div>left</div><div>right</div></div>))
      assert word(items, "left").y == word(items, "right").y
      # flex items are flush: no whitespace between them
      assert word(items, "right").x == word(items, "left").x + word(items, "left").w

      {items, _} =
        styled(
          css <> ~s(<div class="row" style="flex-direction:column"><div>l</div><div>r</div></div>)
        )

      assert word(items, "r").y > word(items, "l").y
    end

    test "display overrides the tag: a div can be inline, a span can be block" do
      {items, _} =
        styled(~s(<div style="display:inline">a</div><div style="display:inline">b</div>))

      assert word(items, "a").y == word(items, "b").y

      {items, _} =
        styled(~s(<span style="display:block">a</span><span style="display:block">b</span>))

      assert word(items, "b").y > word(items, "a").y
    end

    test "zero font-size hides text" do
      {items, _} = styled(~s(<p>a<span style="font-size:0">b</span>c</p>))
      assert word(items, "b").hidden
      refute word(items, "a").hidden
    end

    test "a translucent background is painted with its alpha" do
      {items, _} = styled(~s|<p style="background: rgb(0 0 0 / 25%)">x</p>|)
      assert [%{color: {0, 0, 0, 64}}] = Enum.filter(items, &(&1.type == :rect))
    end

    test "web fonts that are not loaded are skipped, the first known font decides" do
      {items, _} =
        styled(
          ~s|<p style='font-family: "DM Mono", "DM Mono fallback", ui-monospace, monospace'>a</p>| <>
            ~s|<p style='font-family: "DM Sans", sans-serif, monospace'>b</p>| <>
            ~s|<p style='font-family: "Fancy Face"'>c</p>| <>
            ~s|<p style='font-family: "DM Mono-abc123", "DM Mono-abc123 fallback: Arial", sans-serif, ui-monospace'>d</p>|
        )

      assert word(items, "a").mono
      refute word(items, "b").mono
      refute word(items, "c").mono
      # a web font named "mono" stands for a monospace font, even before a generic sans-serif
      assert word(items, "d").mono
    end

    test "monospace family is detected from the first family" do
      {items, _} =
        styled(
          ~s(<p style="font-family: Menlo, serif">a</p><p style="font-family: Helvetica, monospace">b</p>)
        )

      assert word(items, "a").mono
      refute word(items, "b").mono
    end
  end

  describe "sizes and clipping" do
    alias Browser.Page

    defp styled2(html, width \\ 400, view_h \\ 600) do
      page = Page.build(html, "about:home")
      Layout.layout(page.nodes, width, &measure/2, view_h)
    end

    defp w2(items, text), do: Enum.find(items, &(Map.get(&1, :text) == text))

    @reset "<style>body{margin:0} p,div{margin:0}</style>"

    test "a fixed height pads a short box" do
      {items, _} = styled2(@reset <> ~s(<div style="height:100px">a</div><p>b</p>))
      assert w2(items, "b").y - w2(items, "a").y >= 100 - 20
    end

    test "overflow hidden clips content below the height" do
      html =
        @reset <>
          ~s(<div style="height:40px; overflow:hidden"><p>l1</p><p>l2</p><p>l3</p><p>l4</p></div><p>after</p>)

      {items, _} = styled2(html)
      assert w2(items, "l1")
      refute w2(items, "l4")
      assert w2(items, "after").y < 80
    end

    test "overflow visible lets content overflow, following content is not overlapped" do
      html = @reset <> ~s(<div style="height:10px"><p>l1</p><p>l2</p><p>l3</p></div><p>after</p>)
      {items, _} = styled2(html)
      assert w2(items, "l3")
      assert w2(items, "after").y > w2(items, "l3").y
    end

    test "max-height clips and min-height pads" do
      {items, _} =
        styled2(
          @reset <>
            ~s(<div style="max-height:30px;overflow:hidden"><p>a</p><p>b</p><p>c</p></div><p>z</p>)
        )

      refute w2(items, "c")
      assert w2(items, "z").y < 60

      {items, _} = styled2(@reset <> ~s(<div style="min-height:100px">a</div><p>z</p>))
      assert w2(items, "z").y >= 100
    end

    test "background rects are clamped to the clipped height and sit under inner rects" do
      html =
        @reset <>
          ~s(<div style="background:#eee; height:30px; overflow:hidden"><div style="background:#ddd"><p>a</p><p>b</p><p>c</p></div></div>)

      {items, _} = styled2(html)
      rects = Enum.filter(items, &(&1.type == :rect))
      assert [outer, inner] = rects
      assert outer.color == {238, 238, 238} and outer.h == 30
      assert inner.color == {221, 221, 221}
      # the inner rect is cut off by the outer box's clip rectangle
      assert inner.clip.y + inner.clip.h <= outer.y + outer.h
    end
  end

  describe "absolute positioning" do
    alias Browser.Page

    defp abs_layout(html, width \\ 400, view_h \\ 600) do
      page = Page.build("<style>body{margin:0} p,div{margin:0}</style>" <> html, "about:home")
      Layout.layout(page.nodes, width, &measure/2, view_h)
    end

    defp wd(items, text), do: Enum.find(items, &(Map.get(&1, :text) == text))

    test "translate moves an absolute box, percentages by its own size" do
      base = ~s|position:absolute; top:100px; left:200px; width:100px; height:40px|
      {plain, _} = abs_layout(~s|<div style="#{base}">hi</div>|)
      at = wd(plain, "hi")

      {moved, _} = abs_layout(~s|<div style="#{base}; transform: translate(-50%, 10px)">hi</div>|)
      assert %{x: x, y: y} = wd(moved, "hi")
      assert {x, y} == {at.x - 50, at.y + 10}

      {moved, _} = abs_layout(~s|<div style="#{base}; transform: translateY(-110%)">hi</div>|)
      assert wd(moved, "hi").y == at.y - 44
      assert wd(moved, "hi").x == at.x
    end

    test "the translate property, as Tailwind writes it" do
      base = ~s|position:absolute; top:100px; left:200px; width:100px; height:40px|
      {plain, _} = abs_layout(~s|<div style="#{base}">hi</div>|)

      css =
        "<style>.t{--tw-translate-x:calc(calc(1/2*100%)*-1);--tw-translate-y:0;translate:var(--tw-translate-x)var(--tw-translate-y)}</style>"

      {moved, _} = abs_layout(css <> ~s|<div class="t" style="#{base}">hi</div>|)
      assert wd(moved, "hi").x == wd(plain, "hi").x - 50
      assert wd(moved, "hi").y == wd(plain, "hi").y
    end

    test "an absolute box extends the scrollable page" do
      {_, h} = abs_layout(~s|<p>x</p><div style="position:absolute; top:900px; left:0">far</div>|)
      assert h >= 900
    end

    test "absolute elements take no space in the flow" do
      {items, _} =
        abs_layout(
          ~s(<p>a</p><div style="position:absolute; top:200px; left:50px">box</div><p>b</p>)
        )

      a = wd(items, "a")
      b = wd(items, "b")
      assert b.y - a.y < 30
    end

    test "top/left are relative to the page without a positioned ancestor" do
      {items, _} =
        abs_layout(~s(<p>a</p><div style="position:absolute; top:200px; left:50px">box</div>))

      box = wd(items, "box")
      assert box.x == 50
      assert box.y > 195 and box.y < 230
    end

    test "top/left are relative to the nearest positioned ancestor" do
      html =
        ~s(<p>above</p><div style="position:relative; margin-left:100px">) <>
          ~s(<p>inside</p><span style="position:absolute; top:0; left:10px">tip</span></div>)

      {items, _} = abs_layout(html)
      inside = wd(items, "inside")
      tip = wd(items, "tip")
      assert tip.x == 114
      assert abs(tip.y - inside.y) < 5
    end

    test "right aligns the element's right edge to the containing block" do
      {items, _} =
        abs_layout(~s(<div style="position:absolute; top:0; right:20px">hello</div>), 400)

      hello = wd(items, "hello")
      assert hello.x + hello.w == 400 - 20
    end

    test "explicit and percentage widths wrap the content" do
      {items, _} =
        abs_layout(
          ~s(<div style="position:absolute; top:0; left:0; width:80px">one two three four five six</div>)
        )

      texts = for %{type: :text} = i <- items, do: i
      assert Enum.all?(texts, &(&1.x + &1.w <= 80))
      assert length(Enum.uniq_by(texts, & &1.y)) > 1

      {items, _} =
        abs_layout(
          ~s(<div style="position:absolute; top:0; left:0; width:50%">one two three four five six seven eight nine ten</div>),
          400
        )

      assert Enum.all?(for(%{type: :text} = i <- items, do: i.x + i.w), &(&1 <= 200))
    end

    test "bottom is relative to the viewport for page-level elements" do
      {items, _} =
        abs_layout(~s(<div style="position:absolute; bottom:10px; left:0">foot</div>), 400, 600)

      foot = wd(items, "foot")
      assert foot.y > 600 - 10 - 40 and foot.y < 600
    end

    test "bottom inside a positioned box with a height is resolved when the box closes" do
      html =
        ~s(<div style="position:relative; height:100px; margin-left:20px"><p>top</p>) <>
          ~s(<span style="position:absolute; bottom:5px; left:6px">low</span></div><p>after</p>)

      {items, _} = abs_layout(html)
      top = wd(items, "top")
      low = wd(items, "low")
      assert low.x == 4 + 20 + 6
      # near the bottom of the 100px box, well below the first line
      assert low.y > top.y + 50 and low.y < top.y + 100
    end

    test "bottom inside a positioned box without a fixed height uses the content height" do
      html =
        ~s(<div style="position:relative"><p>one</p><p>two</p><span style="position:absolute; bottom:0">low</span></div>)

      {items, _} = abs_layout(html)
      assert wd(items, "low").y >= wd(items, "two").y - 2
    end

    test "fixed uses the page origin even inside a positioned ancestor" do
      html =
        ~s(<div style="position:relative; margin-left:100px"><p>x</p>) <>
          ~s(<div style="position:fixed; top:5px; left:7px">fx</div></div>)

      {items, _} = abs_layout(html)
      assert wd(items, "fx").x == 7
    end

    test "absolute elements are painted after the flow, with their own background first" do
      {items, _} =
        abs_layout(
          ~s(<p>flow</p><div style="position:absolute; top:0; left:0; background:#ff0">pop</div>)
        )

      types = Enum.map(items, &{&1.type, Map.get(&1, :text)})
      assert List.last(types) == {:text, "pop"}

      assert Enum.find_index(types, &(&1 == {:rect, nil})) <
               Enum.find_index(types, &(&1 == {:text, "pop"}))

      assert Enum.find_index(types, &(&1 == {:text, "flow"})) <
               Enum.find_index(types, &(&1 == {:text, "pop"}))

      [rect] = Enum.filter(items, &(&1.type == :rect))
      pop = wd(items, "pop")
      assert rect.w <= pop.w + 2
    end

    test "static position when no offsets are given" do
      {items, _} =
        abs_layout(~s(<p>before</p><div style="position:absolute">here</div><p>after</p>))

      assert wd(items, "here").x == 4
      assert wd(items, "here").y > wd(items, "before").y
    end

    test "hidden and display:none absolute elements leave nothing" do
      {items, _} =
        abs_layout(
          ~s(<div style="position:absolute; visibility:hidden">h</div><div style="position:absolute; display:none">n</div><p>k</p>)
        )

      refute wd(items, "h")
      refute wd(items, "n")
      assert wd(items, "k")
    end
  end

  describe "geometry invariants" do
    alias Browser.Page

    for fixture <-
          ~w(sample hidden positioning boxes rounded lineheight forms images backgrounds svg selects wide) do
      test "#{fixture}.html lays out on integer pixels" do
        html = File.read!("priv/demo/#{unquote(fixture)}.html")
        page = Page.build(html, "about:home")

        for width <- [300, 640, 1100], view_h <- [400, 800] do
          {items, height} = Layout.layout(page.nodes, width, &measure/2, view_h)
          assert is_integer(height)

          for item <- items, key <- [:x, :y, :w, :h], Map.has_key?(item, key) do
            assert is_integer(Map.fetch!(item, key)),
                   "#{key} of #{inspect(item)} is not an integer (width #{width})"
          end
        end
      end
    end
  end

  describe "widths, centering and borders" do
    alias Browser.Page

    defp bx(html, width \\ 400) do
      page = Page.build("<style>body{margin:0} p,div{margin:0}</style>" <> html, "about:home")
      Layout.layout(page.nodes, width, &measure/2, 600)
    end

    defp wb(items, text), do: Enum.find(items, &(Map.get(&1, :text) == text))
    defp rects(items), do: Enum.filter(items, &(&1.type == :rect))

    test "a width limits the content and wraps text inside it" do
      {items, _} = bx(~s(<div style="width:100px">one two three four five six seven</div>))
      texts = for %{type: :text} = i <- items, do: i
      assert Enum.all?(texts, &(&1.x + &1.w <= 4 + 100))
      assert length(Enum.uniq_by(texts, & &1.y)) > 1
    end

    test "percentage widths are relative to the container" do
      {items, _} = bx(~s(<div style="width:50%; background:#eee">x</div>), 408)
      [r] = rects(items)
      assert r.w == 200
    end

    test "max-width caps, min-width raises" do
      {items, _} = bx(~s(<div style="max-width:120px; background:#eee">x</div>))
      assert [%{w: 120}] = rects(items)
      # a block is as wide as its container; min-width only matters when that is narrower
      {items, _} = bx(~s(<div style="min-width:300px; background:#eee">x</div>), 250)
      assert [%{w: 300}] = rects(items)
    end

    test "margin auto centers a box with a width" do
      {items, _} = bx(~s(<div style="width:100px; margin:0 auto; background:#eee">x</div>), 408)
      [r] = rects(items)
      assert r.x == 4 + 150 and r.w == 100
      assert wb(items, "x").x == r.x
    end

    test "max-width with margin auto centers like a page container" do
      {items, _} =
        bx(
          ~s(<div style="max-width:200px; margin-left:auto; margin-right:auto"><p>hello</p></div>),
          408
        )

      assert wb(items, "hello").x == 4 + 100
    end

    test "only margin-left auto pushes the box to the right" do
      {items, _} =
        bx(~s(<div style="width:100px; margin-left:auto; background:#eee">x</div>), 408)

      assert [%{x: 304, w: 100}] = rects(items)
    end

    test "margin-right narrows the content" do
      {items, _} = bx(~s(<div style="margin-right:300px">aaa bbb ccc ddd eee fff ggg</div>))
      assert Enum.all?(for(%{type: :text} = i <- items, do: i.x + i.w), &(&1 <= 4 + 100))
    end

    test "content-box adds padding and border to the width; border-box includes them" do
      pad = "padding: 10px; border: 2px solid #000; background:#eee; width:100px;"
      {items, _} = bx(~s(<div style="#{pad}">x</div>))
      [bg | _] = rects(items)
      assert bg.w == 100 + 20 + 4

      {items, _} = bx(~s(<div style="#{pad} box-sizing:border-box">x</div>))
      [bg | _] = rects(items)
      assert bg.w == 100
    end

    test "borders become rects in their colors and take space" do
      {plain, _} = bx(~s(<div>x</div><p>after</p>))

      {items, _} =
        bx(~s(<div style="border:3px solid #f00">x</div><p>after</p>))

      assert length(rects(items)) == 4
      assert Enum.all?(rects(items), &(&1.color == {255, 0, 0}))
      x = wb(items, "x")
      assert x.x == wb(plain, "x").x + 3
      assert x.y == wb(plain, "x").y + 3
      assert wb(items, "after").y - wb(plain, "after").y == 6
    end

    test "per-side borders and style none/missing style draw nothing" do
      {items, _} = bx(~s(<div style="border-bottom: 2px solid #00f">x</div>))
      assert [%{color: {0, 0, 255}, h: 2, w: w}] = rects(items)
      assert w > 100

      {items, _} =
        bx(
          ~s(<div style="border: 2px #000">x</div><div style="border:none; background:#eee">y</div>)
        )

      assert length(rects(items)) == 1
    end

    test "borders and background paint in that order, under inner rects" do
      {items, _} =
        bx(
          ~s(<div style="border:1px solid #000; background:#eee"><div style="background:#ddd">x</div></div>)
        )

      assert [outer_bg, _, _, _, _, inner] = rects(items)
      assert outer_bg.color == {238, 238, 238}
      assert inner.color == {221, 221, 221}
    end

    test "overflow hidden attaches clip rectangles; nested clips intersect" do
      html =
        ~s(<div style="width:100px; overflow:hidden"><div style="height:20px; overflow:hidden">) <>
          ~s(<p style="white-space:pre">averyveryverylongunbreakableword</p></div></div>)

      {items, _} = bx(html)
      word = wb(items, "averyveryverylongunbreakableword")
      assert word.clip.w <= 100
      assert word.clip.h <= 20
      assert word.x + word.w > word.clip.x + word.clip.w
    end

    test "items outside a clip carry it, items outside any clip do not" do
      {items, _} = bx(~s(<p>free</p><div style="height:30px; overflow:hidden">boxed</div>))
      refute Map.has_key?(wb(items, "free"), :clip)
      assert Map.has_key?(wb(items, "boxed"), :clip)
    end

    test "absolute elements size from width/extra and respect max-width" do
      {items, _} =
        bx(
          ~s(<div style="position:absolute; top:0; left:0; width:100px; padding:10px; background:#eee">x</div>)
        )

      assert [%{w: 120}] = rects(items)

      {items, _} =
        bx(
          ~s(<div style="position:absolute; top:0; left:0; max-width:60px; background:#eee">aaa bbb ccc ddd eee fff</div>)
        )

      assert [%{w: w}] = rects(items)
      assert w <= 60
    end

    test "list item text wraps under the text, not under the marker" do
      {items, _} =
        bx(
          ~s(<ul style="padding-left:30px"><li>aaa bbb ccc ddd eee fff ggg hhh iii jjj kkk lll mmm nnn</li></ul>),
          200
        )

      marker = wb(items, "•")
      lines = for %{type: :text, text: t} = i <- items, t != "•", do: i
      assert Enum.all?(lines, &(&1.x >= marker.x + 10))
    end
  end

  describe "canvas background" do
    alias Browser.Page

    defp page_items(html) do
      page = Page.build(html, "about:home")
      {items, _} = Layout.layout(page.nodes, 400, &measure/2, 600)
      items
    end

    test "the body background becomes the canvas colour" do
      items = page_items("<html><body style=\"background:#123456\"><p>x</p></body></html>")
      assert [%{type: :canvas, color: {18, 52, 86}} | _] = items
    end

    test "the html background wins over the body's" do
      items =
        page_items(
          "<html style=\"background:#111\"><body style=\"background:#eee\"><p>x</p></body></html>"
        )

      assert [%{type: :canvas, color: {17, 17, 17}} | _] = items
    end

    test "no background, no canvas item" do
      refute Enum.any?(page_items("<html><body><p>x</p></body></html>"), &(&1.type == :canvas))
    end
  end

  describe "inline-block" do
    alias Browser.Page

    defp ib(html, width \\ 400) do
      page = Page.build("<style>body{margin:0} p,div{margin:0}</style>" <> html, "about:home")
      Layout.layout(page.nodes, width, &measure/2, 600)
    end

    defp wi(items, text), do: Enum.find(items, &(Map.get(&1, :text) == text))
    defp rs(items), do: Enum.filter(items, &(&1.type == :rect))

    test "inline-blocks sit side by side on one line" do
      html =
        ~s(<span style="display:inline-block; width:100px; background:#eee">a</span>) <>
          ~s(<span style="display:inline-block; width:100px; background:#ddd">b</span>)

      {items, _} = ib(html)
      [r1, r2] = rs(items)
      assert r1.w == 100 and r2.w == 100
      assert r2.x == r1.x + 100
      assert wi(items, "a").y == wi(items, "b").y
    end

    test "padding and border take space inside the unit" do
      html =
        ~s(<span style="display:inline-block; padding:5px 8px; border:2px solid #000; background:#eee">hi</span>)

      {items, _} = ib(html)
      # background + 4 border sides
      assert length(rs(items)) == 5
      bg = hd(rs(items))
      hi = wi(items, "hi")
      assert hi.x == bg.x + 2 + 8
      assert bg.w == 2 + 8 + hi.w + 8 + 2
      assert hi.y >= bg.y + 2 + 5
    end

    test "shrink-to-fit width follows the content, not the container" do
      {items, _} = ib(~s(<span style="display:inline-block; background:#eee">short</span>), 800)
      [bg] = rs(items)
      assert bg.w == wi(items, "short").w
    end

    test "shrink-to-fit is capped by the available width and wraps the text" do
      text = String.duplicate("word ", 40)
      {items, _} = ib(~s(<span style="display:inline-block; background:#eee">#{text}</span>), 208)
      [bg] = rs(items)
      assert bg.w <= 200
      assert length(Enum.uniq(for %{type: :text} = t <- items, do: t.y)) > 1
    end

    test "inline-blocks wrap onto the next line when they don't fit" do
      box = ~s(<span style="display:inline-block; width:90px; background:#eee">x</span>)
      {items, _} = ib(String.duplicate(box, 5), 208)
      ys = items |> rs() |> Enum.map(& &1.y) |> Enum.uniq()
      assert length(ys) == 3

      assert items |> rs() |> Enum.group_by(& &1.y) |> Map.values() |> Enum.map(&length/1) == [
               2,
               2,
               1
             ]
    end

    test "text inside aligns to the baseline of the surrounding text" do
      html =
        ~s(before <span style="display:inline-block; padding:10px; border:2px solid #000">inside</span> after)

      {items, _} = ib(html)
      before = wi(items, "before")
      inside = wi(items, "inside")
      after_ = wi(items, "after")
      assert before.y + before.h == inside.y + inside.h
      assert after_.y + after_.h == inside.y + inside.h
    end

    test "the line grows to hold a tall inline-block, and the next line starts below it" do
      html =
        ~s(<span style="display:inline-block; height:80px; background:#eee">tall</span><p>next</p>)

      {items, _} = ib(html)
      [bg] = rs(items)
      assert bg.h == 80
      assert wi(items, "next").y >= bg.y + 80
    end

    test "margins separate inline-blocks" do
      html =
        ~s(<span style="display:inline-block; width:50px; margin-right:20px; background:#eee">a</span>) <>
          ~s(<span style="display:inline-block; width:50px; background:#ddd">b</span>)

      {items, _} = ib(html)
      [r1, r2] = rs(items)
      assert r2.x == r1.x + 50 + 20
    end

    test "vertical margins are part of the unit's height" do
      html =
        ~s(<span style="display:inline-block; margin:10px 0; background:#eee">m</span><p>n</p>)

      {items, _} = ib(html)
      [bg] = rs(items)
      plain_h = bg.h
      assert wi(items, "n").y >= bg.y + plain_h + 10
    end

    test "min-width and max-width apply to the unit" do
      {items, _} =
        ib(~s(<span style="display:inline-block; min-width:120px; background:#eee">a</span>))

      assert [%{w: 120}] = rs(items)

      text = String.duplicate("word ", 20)

      {items, _} =
        ib(~s(<span style="display:inline-block; max-width:80px; background:#eee">#{text}</span>))

      assert [%{w: w}] = rs(items)
      assert w <= 80
    end

    test "box-sizing border-box includes padding and border in the width" do
      html =
        ~s(<span style="display:inline-block; width:100px; padding:10px; border:1px solid #000; box-sizing:border-box; background:#eee">a</span>)

      {items, _} = ib(html)
      assert hd(rs(items)).w == 100
    end

    test "text-align on the parent positions inline-blocks" do
      html =
        ~s(<div style="text-align:center"><span style="display:inline-block; width:100px; background:#eee">a</span></div>)

      {items, _} = ib(html, 408)
      [bg] = rs(items)
      assert bg.x == 4 + 150
    end

    test "block content inside an inline-block" do
      html = ~s(<span style="display:inline-block; width:100px"><p>one</p><p>two</p></span>)
      {items, _} = ib(html)
      assert wi(items, "two").y > wi(items, "one").y
    end

    test "links inside an inline-block keep their href and move with it" do
      html =
        ~s(pad <span style="display:inline-block; margin-left:40px"><a href="/x">link</a></span>)

      {items, _} = ib(html)
      link = wi(items, "link")
      assert link.href == "/x"
      assert link.x > 40
    end

    test "absolute children are positioned relative to a relative inline-block" do
      html =
        ~s(<span style="display:inline-block; position:relative; width:100px; height:50px; margin-left:60px">in) <>
          ~s(<span style="position:absolute; top:0; right:0">tag</span></span>)

      {items, _} = ib(html)
      tag = wi(items, "tag")
      # gutter + margin-left + width
      assert tag.x + tag.w == 4 + 60 + 100
    end

    test "inline-flex lays out children in a row inside the unit" do
      html = ~s(<span style="display:inline-flex"><div>a</div><div>b</div></span>)
      {items, _} = ib(html)
      assert wi(items, "a").y == wi(items, "b").y
    end

    test "button gets a box by default" do
      {items, _} = ib("<button>Go</button> text")
      # background and border merged into one rounded rect
      assert [%{radius: _, border: %{w: {1, 1, 1, 1}}, color: {239, 239, 239}}] = rs(items)
      go = wi(items, "Go")
      text = wi(items, "text")
      assert go.y + go.h == text.y + text.h
    end

    test "empty inline-block with a size still takes room" do
      html =
        ~s(a<span style="display:inline-block; width:30px; height:10px; background:#eee"></span>b)

      {items, _} = ib(html)
      assert wi(items, "b").x >= wi(items, "a").x + wi(items, "a").w + 30
    end
  end

  describe "inline-block refinements" do
    alias Browser.Page

    defp rb(html, width \\ 400) do
      page = Page.build("<style>body{margin:0} p,div{margin:0}</style>" <> html, "about:home")
      Layout.layout(page.nodes, width, &measure/2, 600)
    end

    defp wr(items, text), do: Enum.find(items, &(Map.get(&1, :text) == text))
    defp rr(items), do: Enum.filter(items, &(&1.type == :rect))

    test "centered text doesn't inflate a shrink-to-fit unit" do
      html =
        ~s(<span style="display:inline-block; text-align:center; background:#eee">tiny</span>)

      {items, _} = rb(html, 800)
      [bg] = rr(items)
      assert bg.w == wr(items, "tiny").w
    end

    test "buttons shrink to their label plus padding and border" do
      {items, _} = rb("<button>Go</button>", 800)
      [bg | _] = rr(items)
      go = wr(items, "Go")
      assert bg.w == go.w + 2 * 6 + 2 * 1
    end

    test "vertical-align top, middle and bottom position atoms against the line" do
      tall = ~s(<span style="display:inline-block; height:60px; background:#eee">T</span>)

      for {valign, check} <- [
            {"top", fn small, big -> small.y == big.y end},
            {"bottom", fn small, big -> small.y + small.h == big.y + big.h end},
            {"middle", fn small, big -> small.y > big.y and small.y + small.h < big.y + big.h end}
          ] do
        html =
          tall <>
            ~s(<span style="display:inline-block; vertical-align:#{valign}; background:#ddd">s</span>)

        {items, _} = rb(html)
        [big, small] = rr(items)
        assert big.h == 60
        assert check.(small, big), "#{valign}: #{inspect({small, big})}"
      end
    end

    test "floating atoms can make the line taller but never shorter" do
      html =
        ~s(<span style="display:inline-block; vertical-align:top; height:100px; background:#eee">a</span>) <>
          ~s(<span style="display:inline-block; height:10px; background:#ddd">b</span><p>next</p>)

      {items, _} = rb(html)
      assert wr(items, "next").y >= 100
    end
  end

  describe "inline element boxes" do
    alias Browser.Page

    defp il(html, width \\ 400) do
      page = Page.build("<style>body{margin:0} p,div{margin:0}</style>" <> html, "about:home")
      Layout.layout(page.nodes, width, &measure/2, 600)
    end

    defp wl(items, text), do: Enum.find(items, &(Map.get(&1, :text) == text))
    defp rl(items), do: Enum.filter(items, &(&1.type == :rect))

    test "a background paints behind the text, including horizontal padding" do
      {items, _} =
        il(~s(a <b style="background:#ff0; padding:0 6px; font-weight:normal">mid</b> z))

      [bg] = rl(items)
      mid = wl(items, "mid")
      assert bg.x == mid.x - 6
      assert bg.w == mid.w + 12
      assert bg.color == {255, 255, 0}
    end

    test "padding, border and margin push the neighbouring text" do
      {plain, _} = il("a <span>mid</span> z")

      {items, _} =
        il(~s(a <span style="padding:0 5px; border:2px solid #000; margin:0 3px">mid</span> z))

      # left margin + border + padding in front of the text
      assert wl(items, "mid").x - wl(plain, "mid").x == 3 + 2 + 5
      # and the same on the right pushes the following text
      assert wl(items, "z").x - wl(plain, "z").x == 2 * (3 + 2 + 5)
    end

    test "all four borders on a single-line fragment" do
      {items, _} = il(~s(<span style="border:2px solid #f00; padding:1px 4px">hi</span>))
      assert length(rl(items)) == 4
      assert Enum.all?(rl(items), &(&1.color == {255, 0, 0}))
      [top, bottom, left, right] = rl(items)
      assert top.h == 2 and bottom.h == 2 and left.w == 2 and right.w == 2
      assert top.w == bottom.w
      assert right.x == top.x + top.w - 2
      # the box wraps the text vertically with padding and border around it
      hi = wl(items, "hi")
      assert top.y < hi.y and bottom.y + bottom.h > hi.y + hi.h
    end

    test "vertical padding and borders don't change the line height" do
      {plain, _} = il("<span>a</span><p>next</p>")

      {items, _} =
        il(
          ~s(<span style="padding:10px 0; border:3px solid #000; background:#eee">a</span><p>next</p>)
        )

      assert wl(items, "next").y == wl(plain, "next").y
    end

    test "padding alone produces no rects" do
      {items, _} = il(~s(<span style="padding:0 10px">x</span>))
      assert rl(items) == []
    end

    test "a box wrapping over two lines gets two fragments with the right edges" do
      text = String.duplicate("word ", 12)

      {items, _} =
        il(
          ~s(<span style="border:2px solid #00f; padding:0 3px; background:#eef">#{text}</span>),
          160
        )

      bgs = Enum.filter(rl(items), &(&1.color == {238, 238, 255}))
      assert length(bgs) >= 3
      blues = Enum.filter(rl(items), &(&1.color == {0, 0, 255}))
      lefts = Enum.filter(blues, &(&1.w == 2 and &1.h > 2))
      rights = Enum.filter(blues, &(&1.w == 2 and &1.h > 2))
      # exactly one left border (first fragment) and one right border (last fragment)
      assert length(lefts) == 2
      assert length(rights) == 2
      first = Enum.min_by(bgs, & &1.y)
      last = Enum.max_by(bgs, & &1.y)
      assert Enum.any?(lefts, &(&1.x == first.x and &1.y == first.y))
      assert Enum.any?(rights, &(&1.x + &1.w == last.x + last.w and &1.y == last.y))
      # continuation fragments start at the line start, flush with the first line
      assert Enum.all?(bgs -- [first], &(&1.x == 4))
    end

    test "borders exist only where the box starts and ends (slice)" do
      text = String.duplicate("word ", 12)

      {items, _} =
        il(
          ~s(<span style="border-left:4px solid #0a0; border-right:4px solid #a00">#{text}</span>),
          160
        )

      greens = Enum.filter(rl(items), &(&1.color == {0, 170, 0}))
      reds = Enum.filter(rl(items), &(&1.color == {170, 0, 0}))
      assert length(greens) == 1
      assert length(reds) == 1
      assert hd(greens).y < hd(reds).y
    end

    test "a box whose first word wraps doesn't leave a stub at the end of the previous line" do
      long = String.duplicate("a", 20)

      {items, _} =
        il(~s(#{long} <span style="background:#ff0; padding:0 8px">#{long}</span>), 240)

      [bg] = rl(items)
      texts = for %{type: :text} = t <- items, do: t
      second_line = texts |> Enum.map(& &1.y) |> Enum.max()
      boxed = Enum.filter(texts, &(&1.y == second_line))
      # one fragment, on the second line, wrapped around the moved word with its padding
      assert bg.x == 4
      assert Enum.all?(boxed, &(&1.x >= bg.x + 8))
      assert bg.y > Enum.min(Enum.map(texts, & &1.y))
    end

    test "background is painted before the borders of the same box" do
      {items, _} = il(~s(<span style="background:#ff0; border:2px solid #000">x</span>))
      assert [%{color: {255, 255, 0}}, %{color: {0, 0, 0}} | _] = rl(items)
    end

    test "boxes at the start of a line include their leading padding" do
      {items, _} =
        il(
          ~s(<p><span style="background:#ff0; padding:0 7px; border-left:2px solid #000">go</span> on</p>)
        )

      [bg | _] = rl(items)
      assert bg.x == 4
      assert wl(items, "go").x == 4 + 2 + 7
    end

    test "nested boxes paint outer first and keep their own extents" do
      html =
        ~s(<span style="background:#ddd; padding:0 10px">out <span style="background:#ff0; padding:0 4px">in</span> er</span>)

      {items, _} = il(html)
      [outer, inner] = rl(items)
      assert outer.color == {221, 221, 221} and inner.color == {255, 255, 0}
      assert outer.x < inner.x and outer.x + outer.w > inner.x + inner.w
    end

    test "boxes continue across a line break and across block-free inline children" do
      {items, _} = il(~s(<span style="background:#ff0">one<br>two <b>three</b></span>))
      bgs = rl(items)
      assert length(bgs) == 2
      assert Enum.at(bgs, 1).y > Enum.at(bgs, 0).y
      assert Enum.at(bgs, 1).w >= wl(items, "two").w + wl(items, "three").w
    end

    test "inline boxes paint above a block background but under text" do
      {items, _} =
        il(~s(<div style="background:#eee">x <span style="background:#ff0">y</span></div>))

      assert [%{color: {238, 238, 238}}, %{color: {255, 255, 0}}] = rl(items)
      assert Enum.find_index(items, &(&1.type == :text)) > 1
    end

    test "visibility hidden keeps the space but paints nothing" do
      {plain, _} = il("a <span>b</span> c")

      {items, _} =
        il(~s(a <span style="visibility:hidden; background:#ff0; padding:0 5px">b</span> c))

      assert rl(items) == []
      assert wl(items, "c").x - wl(plain, "c").x == 10
    end

    test "links with a background keep their href and position" do
      {items, _} = il(~s(<a href="/go" style="background:#eef; padding:2px 8px">go</a>))
      link = wl(items, "go")
      assert link.href == "/go"
      [bg] = rl(items)
      assert bg.x < link.x and bg.x + bg.w > link.x + link.w
    end

    test "inline boxes work inside inline-blocks and absolute elements" do
      html =
        ~s(<span style="display:inline-block; width:200px">a <i style="background:#ff0; padding:0 4px">b</i></span>) <>
          ~s(<div style="position:absolute; top:100px; left:10px">c <i style="background:#0ff">d</i></div>)

      {items, _} = il(html)
      assert Enum.any?(rl(items), &(&1.color == {255, 255, 0}))
      cyan = Enum.find(rl(items), &(&1.color == {0, 255, 255}))
      assert cyan.y > 90
    end

    test "text-align centers a line including the inline box fragment" do
      {items, _} =
        il(
          ~s(<div style="text-align:center"><span style="background:#ff0; padding:0 10px">mid</span></div>),
          408
        )

      [bg] = rl(items)
      assert_in_delta bg.x + bg.w / 2, 4 + 200, 1
    end

    test "list items with inline boxes" do
      {items, _} =
        il(~s(<ul><li>x <code style="background:#eee; padding:0 3px">code</code></li></ul>))

      [bg] = rl(items)
      code = wl(items, "code")
      assert bg.x < code.x
      assert wl(items, "•").y == code.y
    end
  end

  describe "rounded boxes" do
    alias Browser.Page

    defp rd(html, width \\ 400) do
      page = Page.build("<style>body{margin:0} p,div{margin:0}</style>" <> html, "about:home")
      Layout.layout(page.nodes, width, &measure/2, 600)
    end

    defp rects_of(items), do: Enum.filter(items, &(&1.type == :rect))

    test "a rounded box is a single rect carrying its radii" do
      {items, _} = rd(~s(<div style="background:#eee; border-radius:6px">x</div>))
      assert [%{color: {238, 238, 238}, radius: r, border: nil} = rect] = rects_of(items)
      assert r == {{6, 6}, {6, 6}, {6, 6}, {6, 6}}
      assert rect.w == 392 and rect.h > 10
    end

    test "borders are merged into the rounded rect instead of separate rects" do
      {items, _} = rd(~s(<div style="border:2px solid #f00; border-radius:5px">x</div>))

      assert [%{color: nil, border: %{w: {2, 2, 2, 2}, c: {red, red, red, red}}}] =
               rects_of(items)

      assert red == {255, 0, 0}
    end

    test "boxes without a radius keep plain rects" do
      {items, _} = rd(~s(<div style="background:#eee; border:1px solid #000">x</div>))
      assert length(rects_of(items)) == 5
      refute Enum.any?(rects_of(items), &Map.has_key?(&1, :radius))
    end

    test "percentages are relative to the box: 50% makes a pill or circle" do
      {items, _} =
        rd(~s(<div style="width:100px; height:40px; background:#eee; border-radius:50%">x</div>))

      [%{radius: r}] = rects_of(items)
      assert r == {{50, 20}, {50, 20}, {50, 20}, {50, 20}}

      {items, _} =
        rd(
          ~s(<div style="width:100px; height:40px; background:#eee; border-radius:50px/50%">x</div>)
        )

      [%{radius: r}] = rects_of(items)
      assert r == {{50, 20}, {50, 20}, {50, 20}, {50, 20}}
    end

    test "radii that don't fit are scaled down together" do
      {items, _} =
        rd(
          ~s(<div style="width:60px; height:100px; background:#eee; border-radius:200px">x</div>)
        )

      [%{radius: {{a, b}, _, _, _}}] = rects_of(items)
      assert a == 30 and b == 30
    end

    test "a corner with a zero radius on one axis is square" do
      {items, _} =
        rd(~s(<div style="background:#eee; border-radius:10px 0 / 10px 5px 10px 5px">x</div>))

      [%{radius: r}] = rects_of(items)
      assert elem(r, 1) == {0, 0}
      assert elem(r, 0) == {10, 10}
    end

    test "different radii per corner" do
      {items, _} = rd(~s(<div style="background:#eee; border-radius:1px 2px 3px 4px">x</div>))
      [%{radius: r}] = rects_of(items)
      assert r == {{1, 1}, {2, 2}, {3, 3}, {4, 4}}
    end

    test "a radius without background or border draws nothing" do
      {items, _} = rd(~s(<div style="border-radius:8px">x</div>))
      assert rects_of(items) == []
    end

    test "inline boxes get rounded fragments, with square edges where the box continues" do
      text = String.duplicate("word ", 12)

      {items, _} =
        rd(
          ~s(<span style="background:#ff0; border-radius:6px; padding:0 4px">#{text}</span>),
          160
        )

      rects = rects_of(items)
      assert length(rects) >= 3
      first = Enum.min_by(rects, & &1.y)
      last = Enum.max_by(rects, & &1.y)
      middle = rects -- [first, last]
      assert {tl, tr, br, bl} = first.radius
      assert tl != {0, 0} and bl != {0, 0} and tr == {0, 0} and br == {0, 0}
      assert {tl, tr, br, bl} = last.radius
      assert tl == {0, 0} and bl == {0, 0} and tr != {0, 0} and br != {0, 0}
      assert Enum.all?(middle, &(not Map.has_key?(&1, :radius)))
    end

    test "a single-line inline box is rounded on both ends" do
      {items, _} =
        rd(~s(<span style="background:#ff0; border-radius:50px; padding:0 8px">pill</span>))

      [%{radius: r, h: h}] = rects_of(items)
      assert Enum.all?(Tuple.to_list(r), &(&1 == {div(h, 2), div(h, 2)}))
    end

    test "inline fragments lose the border on the cut side" do
      text = String.duplicate("word ", 12)

      {items, _} =
        rd(~s(<span style="border:2px solid #00f; border-radius:4px">#{text}</span>), 160)

      [first | _] = items |> rects_of() |> Enum.sort_by(& &1.y)
      assert %{w: {2, 0, 2, 2}} = first.border
    end

    test "rounded inline-blocks and absolute boxes" do
      html =
        ~s(<span style="display:inline-block; background:#eee; border-radius:8px; padding:4px">a</span>) <>
          ~s(<div style="position:absolute; top:50px; left:10px; background:#ddd; border-radius:3px">b</div>)

      {items, _} = rd(html)
      assert length(Enum.filter(rects_of(items), &Map.has_key?(&1, :radius))) == 2
    end

    test "clipping boxes attach their clip to rounded rects inside" do
      html =
        ~s(<div style="width:50px; height:20px; overflow:hidden"><div style="background:#eee; border-radius:6px; width:200px">x</div></div>)

      {items, _} = rd(html)
      [%{radius: _, clip: clip}] = rects_of(items)
      assert clip.w == 50
    end
  end

  describe "line-height" do
    alias Browser.Page

    defp lt(html, width \\ 400) do
      page = Page.build("<style>body{margin:0} p,div{margin:0}</style>" <> html, "about:home")
      Layout.layout(page.nodes, width, &measure/2, 600)
    end

    defp wt(items, text), do: Enum.find(items, &(Map.get(&1, :text) == text))

    # y distance between the first words of two successive lines
    defp pitch(html, width) do
      {items, _} = lt(html, width)
      lines = for %{type: :text} = t <- items, do: t
      ys = lines |> Enum.map(& &1.y) |> Enum.uniq() |> Enum.sort()
      [a, b | _] = ys
      b - a
    end

    @two_lines ~s(<p style="LH">one two three four five six seven eight nine ten eleven twelve</p>)

    test "normal keeps the built-in spacing" do
      assert pitch(String.replace(@two_lines, "LH", ""), 120) == round(16 * 1.35)
    end

    test "px, number, em and percentage line heights set the pitch" do
      for {lh, expected} <- [
            {"line-height: 30px", 30},
            {"line-height: 2", 32},
            {"line-height: 1.5", 24},
            {"line-height: 2em", 32},
            {"line-height: 150%", 24},
            {"line-height: 1", 16}
          ] do
        assert pitch(String.replace(@two_lines, "LH", lh), 120) == expected, lh
      end
    end

    test "a block with one line is as tall as its line-height" do
      for lh <- [10, 22, 40, 64] do
        {items, h} = lt(~s(<div style="line-height:#{lh}px; background:#eee">x</div>))
        [bg] = Enum.filter(items, &(&1.type == :rect))
        assert bg.h == lh
        assert h >= lh
      end
    end

    test "leading is split above and below: text stays centred as the line grows" do
      centre = fn lh ->
        {items, _} = lt(~s(<div style="line-height:#{lh}px; background:#eee">x</div>))
        [bg] = Enum.filter(items, &(&1.type == :rect))
        x = wt(items, "x")
        {x.y + div(x.h, 2) - bg.y, lh}
      end

      {c1, _} = centre.(22)
      {c2, _} = centre.(62)
      # 40px more line height moves the text 20px down
      assert c2 - c1 == 20
    end

    test "line-height centres a label vertically in a fixed-height box" do
      html =
        ~s(<div style="width:64px; height:64px; line-height:64px; background:#e55; text-align:center">ok</div>)

      {items, _} = lt(html)
      [bg] = Enum.filter(items, &(&1.type == :rect))
      ok = wt(items, "ok")
      mid = ok.y + div(ok.h, 2)
      assert abs(mid - (bg.y + 32)) <= 4
    end

    test "line-height is inherited by nested elements" do
      html =
        ~s(<div style="line-height:40px"><p>a b c d e f g h i j k l m n o p q r s t u v w x y z</p></div>)

      assert pitch(html, 100) == 40
    end

    test "the tallest line-height on a line wins" do
      {items, _} =
        lt(~s(<p>small <span style="line-height:60px">tall</span> text</p><p>next</p>))

      # the first paragraph is one 60px line, so the next one starts at 60 or below
      assert wt(items, "next").y >= 60
    end

    test "a number follows each element's own font size" do
      {items, _} =
        lt(
          ~s(<div style="line-height:1.5"><span style="font-size:32px">big</span></div><p>next</p>)
        )

      # 1.5 x 32px = 48px line, so the next paragraph starts at 48 or below
      assert wt(items, "next").y >= 48
    end

    test "line-height does not change the width of text" do
      {a, _} = lt(~s(<p>hello world</p>))
      {b, _} = lt(~s(<p style="line-height:50px">hello world</p>))
      assert wt(a, "world").x == wt(b, "world").x
    end

    test "lines with inline-blocks and inline boxes follow the same rule" do
      html =
        ~s(<div style="line-height:40px">a <span style="display:inline-block; background:#eee">b</span> ) <>
          ~s(<span style="background:#ff0">c</span></div><p>next</p>)

      {items, _} = lt(html)
      assert wt(items, "next").y >= 40
      assert wt(items, "a").y + wt(items, "a").h == wt(items, "c").y + wt(items, "c").h
    end

    test "list items and inline-block contents use their own line-height" do
      html =
        ~s(<ul style="line-height:30px"><li>a b c d e f g h i j k l m n o p q r s t u v w x y z</li></ul>)

      assert pitch(html, 100) == 30
    end

    test "line-height 0 collapses lines but keeps them drawn in order" do
      {items, h} = lt(~s(<p style="line-height:0">a</p><p style="line-height:0">b</p>))
      assert wt(items, "b").y >= wt(items, "a").y
      assert is_integer(h)
    end
  end

  describe "form controls" do
    alias Browser.Page

    defp fm(html, width \\ 500) do
      page = Page.build("<style>body{margin:0} p,div{margin:0}</style>" <> html, "about:home")
      Layout.layout(page.nodes, width, &measure/2, 600)
    end

    defp wf(items, text), do: Enum.find(items, &(Map.get(&1, :text) == text))
    defp boxes(items), do: Enum.filter(items, &(&1.type == :rect))

    test "a text input is a white bordered box showing its value" do
      {items, _} = fm(~s(<input type="text" value="hello">))
      [box] = boxes(items)
      assert %{color: {255, 255, 255}, border: %{w: {1, 1, 1, 1}}, radius: _} = box
      # 170px content + 2 x 2px padding + 2 x 1px border
      assert box.w == 176
      hello = wf(items, "hello")
      assert hello.x == box.x + 1 + 2
      assert hello.color == {0, 0, 0}
    end

    test "controls don't inherit the page's text colour or size" do
      {items, _} =
        fm(~s(<div style="color:#f00; font-size:30px"><input value="v"> <b>b</b></div>))

      assert wf(items, "v").color == {0, 0, 0}
      assert wf(items, "v").size == 13
      assert wf(items, "b").color == {255, 0, 0}
    end

    test "a placeholder is grey and disappears once there is a value" do
      {items, _} = fm(~s(<input placeholder="Search here">))
      assert wf(items, "Search here").color == {117, 117, 117}
      {items, _} = fm(~s(<input placeholder="Search here" value="typed">))
      assert wf(items, "typed").color == {0, 0, 0}
      refute wf(items, "Search here")
    end

    test "passwords are masked" do
      {items, _} = fm(~s(<input type="password" value="secret">))
      assert wf(items, "••••••")
      refute wf(items, "secret")
    end

    test "size sets the width; page CSS overrides the attribute; the attribute overrides defaults" do
      {items, _} = fm(~s(<input size="10">))
      assert hd(boxes(items)).w == 10 * 8 + 6

      {items, _} = fm(~s(<style>input { width: 50px }</style><input size="10">))
      assert hd(boxes(items)).w == 50 + 6

      {items, _} = fm(~s(<input size="10" style="width:90px">))
      assert hd(boxes(items)).w == 90 + 6
    end

    test "an empty input is as tall as a filled one, with its box on the text baseline" do
      {a, _} = fm(~s(before <input> after))
      {b, _} = fm(~s(before <input value="x"> after))
      assert hd(boxes(a)).h == hd(boxes(b)).h
      before = wf(a, "before")
      after_ = wf(a, "after")
      assert (before.y + before.h - (after_.y + after_.h)) in -1..1
    end

    test "checkboxes are small squares, blue when checked" do
      {items, _} = fm(~s(<input type="checkbox"><input type="checkbox" checked>))
      [off, on] = boxes(items)
      assert off.w == 15 and off.h == 15
      assert off.color == {255, 255, 255}
      assert on.color == {0, 117, 255}
      assert wf(items, "✓").color == {255, 255, 255}
    end

    test "radio buttons are circles" do
      {items, _} = fm(~s(<input type="radio">))
      [box] = boxes(items)
      assert box.radius == {{7, 7}, {7, 7}, {7, 7}, {7, 7}}
    end

    test "a checked radio's dot is a round box centred in the circle" do
      {items, _} = fm(~s(<input type="radio" checked>))
      [box, dot] = boxes(items)
      assert dot.w == 7 and dot.h == 7
      assert dot.radius == {{3, 3}, {3, 3}, {3, 3}, {3, 3}}
      # equal space on all four sides, inside the 1px border
      assert dot.x - (box.x + 1) == box.x + box.w - 1 - (dot.x + dot.w)
      assert dot.y - (box.y + 1) == box.y + box.h - 1 - (dot.y + dot.h)
      # and no stray text glyph
      refute Enum.any?(items, &(&1.type == :text and &1.text == "●"))
    end

    test "buttons show their label and fit it" do
      {items, _} =
        fm(~s(<input type="submit" value="Send"> <input type="reset"> <button>Go</button>))

      assert wf(items, "Send") && wf(items, "Reset") && wf(items, "Go")
      [send, reset, go] = boxes(items)
      assert send.color == {239, 239, 239}
      # sized by their label plus padding and border, not the 170px of a text field
      assert send.w == wf(items, "Send").w + 12 + 2
      assert reset.w < 100 and go.w < 100
    end

    test "a select shows the selected option and an arrow; the other options don't render" do
      html =
        ~s(<select><option>One</option><option selected>Two</option><option>Three</option></select>)

      {items, _} = fm(html)
      assert wf(items, "Two") && wf(items, "▾")
      refute wf(items, "One")
      refute wf(items, "Three")
      assert [%{radius: _}] = boxes(items)
    end

    test "a textarea has its default size and keeps its line breaks" do
      {items, _} = fm("<textarea>first line\nsecond line</textarea>")
      [box] = boxes(items)
      assert box.w == 160 + 4 + 2
      assert box.h == 36 + 4 + 2
      assert wf(items, "second line").y > wf(items, "first line").y
    end

    test "cols and rows size a textarea" do
      {items, _} = fm(~s(<textarea cols="30" rows="4">x</textarea>))
      [box] = boxes(items)
      assert box.w == 30 * 8 + 6
      assert box.h == 4 * 18 + 6
    end

    test "long values are clipped inside the box" do
      {items, _} = fm(~s(<input value="#{String.duplicate("wide ", 60)}" size="5">))
      [box] = boxes(items)
      # the input never grows to fit its text: the text is clipped to the padding box
      assert box.w == 5 * 8 + 6
      assert Enum.all?(items, fn it -> it.type != :text or Map.has_key?(it, :clip) end)
    end

    test "disabled controls are greyed" do
      {items, _} = fm(~s(<input value="v" disabled><button disabled>b</button>))
      [input, button] = boxes(items)
      assert input.color == {239, 239, 239} and button.color == {239, 239, 239}
      assert wf(items, "v").color == {109, 109, 109}
    end

    test "hidden inputs take no room" do
      {plain, _} = fm("a <b>b</b>")
      {items, _} = fm(~s(a <input type="hidden" name="t" value="secret"><b>b</b>))
      assert wf(items, "b").x == wf(plain, "b").x
      assert boxes(items) == []
    end

    test "a label and its control share a line" do
      {items, _} =
        fm(~s(<label>Name <input value="x"></label><label>Mail <input value="y"></label>))

      assert wf(items, "Name").y == wf(items, "Mail").y
      assert length(boxes(items)) == 2
    end

    test "controls sit side by side and wrap like inline-blocks" do
      {items, _} = fm(String.duplicate(~s(<input value="v">), 4), 400)
      ys = items |> boxes() |> Enum.map(& &1.y) |> Enum.uniq()
      assert length(ys) == 2
    end

    test "a fieldset is a bordered block with padding" do
      {items, _} = fm(~s(<fieldset><legend>Title</legend>Content</fieldset>))
      # four border strips, in the UA's grey
      assert [%{y: top}, %{y: bottom} | _] = boxes(items)
      assert Enum.all?(boxes(items), &(&1.color == {192, 192, 192}))
      left = Enum.min_by(boxes(items), & &1.x).x
      assert wf(items, "Title").x > left
      assert wf(items, "Title").y > top
      assert wf(items, "Content").y > wf(items, "Title").y
      assert wf(items, "Content").y < bottom
    end

    test "a login-style form lays out and stays on integer pixels" do
      html = """
      <form><fieldset><legend>Sign in</legend>
      <label>User <input name="u" placeholder="name"></label><br>
      <label>Pass <input type="password" value="hunter2"></label><br>
      <label><input type="checkbox" checked> Remember me</label><br>
      <select><option>A</option><option selected>Beta</option></select>
      <textarea rows="2">note</textarea>
      <input type="submit" value="Go"></fieldset></form>
      """

      for width <- [200, 500] do
        {items, height} = fm(html, width)
        assert is_integer(height)

        for it <- items, key <- [:x, :y, :w, :h], Map.has_key?(it, key) do
          assert is_integer(Map.fetch!(it, key)), "#{key} of #{inspect(it)}"
        end
      end
    end
  end

  describe "focus, caret and control bounds" do
    alias Browser.Page

    defp fx(html, opts \\ [], width \\ 500) do
      page = Page.build("<style>body{margin:0} p,div{margin:0}</style>" <> html, "about:home")
      Layout.layout(page.nodes, width, &measure/2, 600, opts)
    end

    defp tx(items, text), do: Enum.find(items, &(Map.get(&1, :text) == text))

    test "controls tag their text and boxes with an id; other content has none" do
      {items, _} = fx(~s(plain <input value="v"><input value="w">))
      assert Map.get(tx(items, "plain"), :cid) == nil
      assert tx(items, "v").cid == 0
      assert tx(items, "w").cid == 1
      assert [%{cid: 0}, %{cid: 1}] = Enum.filter(items, &(&1.type == :rect))
    end

    test "controls/1 gives each control's border box" do
      {items, _} = fx(~s(<input value="v"><textarea>t</textarea>))
      bounds = Layout.controls(items)
      assert Map.keys(bounds) |> Enum.sort() == [0, 1]
      assert bounds[0].w == 176 and bounds[0].h > 15
      assert bounds[1].w == 166 and bounds[1].h == 42
      assert bounds[0].x < bounds[1].x
    end

    test "no focus option, no ring and no caret" do
      {items, _} = fx(~s(<input value="v">))
      refute Enum.any?(items, &(&1.type in [:ring, :caret]))
    end

    test "focus adds a ring around the control's box" do
      {items, _} = fx(~s(<input value="v">), focus: %{cid: 0, caret: {0, 0}})
      [ring] = Enum.filter(items, &(&1.type == :ring))
      box = Layout.controls(items)[0]
      assert {ring.x, ring.y, ring.w, ring.h} == {box.x - 2, box.y - 2, box.w + 4, box.h + 4}
      assert ring.cid == 0
      # rounded like the control, grown by the ring width
      assert ring.radius == {{4, 4}, {4, 4}, {4, 4}, {4, 4}}
    end

    test "the ring only goes around the focused control" do
      {items, _} = fx(~s(<input value="a"><input value="b">), focus: %{cid: 1, caret: {0, 0}})
      [ring] = Enum.filter(items, &(&1.type == :ring))
      assert ring.x > Layout.controls(items)[0].x + 100
    end

    test "the caret sits between characters, measured with the control's font" do
      {items, _} = fx(~s(<input value="hello">), focus: %{cid: 0, caret: {0, 3}})
      [caret] = Enum.filter(items, &(&1.type == :caret))
      text = tx(items, "hello")
      # measure/2 here is length * size / 2 per character
      assert caret.x == text.x + 3 * div(text.size, 2)
      assert caret.y == text.y and caret.w == 1
      assert caret.h > text.h

      {items, _} = fx(~s(<input value="hello">), focus: %{cid: 0, caret: {0, 0}})
      assert Enum.find(items, &(&1.type == :caret)).x == tx(items, "hello").x

      {items, _} = fx(~s(<input value="hello">), focus: %{cid: 0, caret: {0, 5}})
      c = Enum.find(items, &(&1.type == :caret))
      assert c.x == tx(items, "hello").x + tx(items, "hello").w
    end

    test "an empty control's caret is at the start of its text line" do
      {items, _} = fx(~s(<input>), focus: %{cid: 0, caret: {0, 0}})
      assert [%{type: :caret}] = Enum.filter(items, &(&1.type == :caret))
      {items, _} = fx(~s(<input placeholder="Search">), focus: %{cid: 0, caret: {0, 0}})
      assert Enum.find(items, &(&1.type == :caret)).x == tx(items, "Search").x
    end

    test "a textarea's caret is on the right line and column" do
      {items, _} =
        fx("<textarea rows=\"3\">one\ntwo\nthree</textarea>", focus: %{cid: 0, caret: {2, 2}})

      caret = Enum.find(items, &(&1.type == :caret))
      three = tx(items, "three")
      assert caret.y == three.y
      assert caret.x == three.x + 2 * div(three.size, 2)
    end

    test "a caret line past the end of the text is dropped" do
      {items, _} = fx(~s(<input value="x">), focus: %{cid: 0, caret: {5, 0}})
      refute Enum.any?(items, &(&1.type == :caret))
    end

    test "a caret inside a clipping control keeps the clip" do
      {items, _} = fx(~s(<input value="x" size="3">), focus: %{cid: 0, caret: {0, 1}})
      assert Map.has_key?(Enum.find(items, &(&1.type == :caret)), :clip)
    end

    test "focusing a missing control changes nothing" do
      {plain, _} = fx(~s(<input value="v">))
      {items, _} = fx(~s(<input value="v">), focus: %{cid: 9, caret: {0, 0}})
      assert length(items) == length(plain)
    end

    test "blank lines in preformatted text take a line; a final newline does not" do
      {items, _} = fx("<pre>a\n\nb</pre>")
      ys = items |> Enum.filter(&(&1.type == :text and &1.text != "\u200B")) |> Enum.map(& &1.y)
      [ya, yb] = ys
      assert yb - ya >= 2 * 20

      {items, h1} = fx("<pre>a\nb\n</pre>")
      {_, h2} = fx("<pre>a\nb</pre>")
      assert h1 == h2
      assert length(Enum.filter(items, &(&1.type == :text))) == 2
    end
  end

  describe "images" do
    alias Browser.Page

    @base "http://example.test/dir/page.html"
    @img "http://example.test/dir/a.png"

    defp im(html, images, width \\ 500) do
      page = Page.build("<style>body{margin:0} p,div{margin:0}</style>" <> html, @base)
      Layout.layout(page.nodes, width, &measure/2, 600, images: images)
    end

    defp loaded(w, h), do: %{@img => {:ok, w, h}}
    defp pics(items), do: Enum.filter(items, &(&1.type == :image))
    defp tw(items, text), do: Enum.find(items, &(Map.get(&1, :text) == text))

    test "a loaded image takes its own size and carries its url" do
      {items, _} = im(~s(<img src="a.png">), loaded(120, 80))
      assert [%{url: @img, w: 120, h: 80, x: 4}] = pics(items)
    end

    test "the page collects the urls to fetch" do
      page =
        Page.build(~s(<img src="a.png"><p><img src="/b.jpg" alt="b"><img src="a.png"></p>), @base)

      assert page.image_urls == [@img, "http://example.test/b.jpg"]
    end

    test "width and height attributes size it; one attribute keeps the ratio" do
      {items, _} = im(~s(<img src="a.png" width="60" height="60">), loaded(120, 80))
      assert [%{w: 60, h: 60}] = pics(items)
      {items, _} = im(~s(<img src="a.png" width="60">), loaded(120, 80))
      assert [%{w: 60, h: 40}] = pics(items)
    end

    test "css width and height win over the attributes" do
      {items, _} =
        im(
          ~s(<img src="a.png" width="60" height="60" style="width:30px; height:20px">),
          loaded(120, 80)
        )

      assert [%{w: 30, h: 20}] = pics(items)
    end

    test "the responsive recipe: max-width 100% and height auto" do
      html =
        ~s(<style>img { max-width: 100%; height: auto }</style><img src="a.png" width="400" height="200">)

      {items, _} = im(html, loaded(400, 200), 208)
      assert [%{w: 200, h: 100}] = pics(items)
      {items, _} = im(html, loaded(400, 200), 1000)
      assert [%{w: 400, h: 200}] = pics(items)
    end

    test "percentage widths follow the container and keep the ratio" do
      {items, _} = im(~s(<img src="a.png" style="width:50%">), loaded(120, 80), 408)
      assert [%{w: 200, h: 133}] = pics(items)
    end

    test "an image sits on the text baseline" do
      {items, _} = im(~s(before <img src="a.png"> after), loaded(40, 40))
      [pic] = pics(items)
      before = tw(items, "before")
      after_ = tw(items, "after")
      assert pic.y + pic.h == before.y + before.h
      assert before.y + before.h == after_.y + after_.h
    end

    test "a tall image makes its line taller; the next line starts below it" do
      {items, _} = im(~s(<img src="a.png"><p>next</p>), loaded(50, 100))
      [pic] = pics(items)
      assert tw(items, "next").y >= pic.y + pic.h
    end

    test "images flow and wrap like inline boxes" do
      img = ~s(<img src="a.png" width="90" height="10">)
      {items, _} = im(String.duplicate(img, 5), loaded(10, 10), 208)
      ys = items |> pics() |> Enum.map(& &1.y) |> Enum.uniq()
      assert length(ys) == 3
    end

    test "margins separate images" do
      {items, _} =
        im(~s(<img src="a.png" style="margin:0 10px"><img src="a.png">), loaded(20, 20))

      [a, b] = pics(items)
      assert b.x == a.x + 20 + 10
      assert a.x == 4 + 10
    end

    test "border, padding and background draw around the picture" do
      html = ~s(<img src="a.png" style="border:2px solid #f00; padding:3px; background:#eee">)
      {items, _} = im(html, loaded(40, 30))
      [pic] = pics(items)
      assert pic.x == 4 + 2 + 3 and pic.w == 40 and pic.h == 30
      rects = Enum.filter(items, &(&1.type == :rect))
      assert length(rects) == 5
      bg = hd(rects)
      assert bg.w == 40 + 6 + 4 and bg.h == 30 + 6 + 4
      assert pic.y == bg.y + 2 + 3
    end

    test "a border radius on an image box gives a rounded box" do
      {items, _} =
        im(~s(<img src="a.png" style="border:1px solid #000; border-radius:6px">), loaded(40, 30))

      assert [%{radius: {{6, 6}, _, _, _}}] = Enum.filter(items, &(&1.type == :rect))
    end

    test "an image in a link carries the href" do
      {items, _} = im(~s(<a href="/go"><img src="a.png"></a>), loaded(20, 20))
      assert [%{href: "/go"}] = pics(items)
    end

    test "display:block puts the image on its own line; auto margins position it" do
      html = ~s(text<img src="a.png" style="display:block; margin:10px auto">more)
      {items, _} = im(html, loaded(100, 40), 408)
      [pic] = pics(items)
      assert pic.x == 4 + 150
      assert tw(items, "more").y > pic.y + pic.h
      assert tw(items, "text").y + 16 <= pic.y

      {items, _} =
        im(~s(<img src="a.png" style="display:block; margin-left:auto">), loaded(100, 40), 408)

      assert [%{x: 304}] = pics(items)
    end

    test "vertical margins of a block image collapse with the text around it" do
      {a, _} =
        im(
          ~s(<p>a</p><img src="a.png" style="display:block; margin:30px 0"><p>b</p>),
          loaded(10, 10)
        )

      {b, _} = im(~s(<p>a</p><img src="a.png" style="display:block"><p>b</p>), loaded(10, 10))
      assert hd(pics(a)).y - tw(a, "a").y > hd(pics(b)).y - tw(b, "a").y + 20
    end

    test "vertical-align moves an image against the line" do
      html =
        ~s(<span style="font-size:30px">big text</span><img src="a.png" style="vertical-align: top">)

      {items, _} = im(html, loaded(10, 10))
      assert hd(pics(items)).y <= tw(items, "big").y
    end

    test "a hidden image keeps its space but isn't painted" do
      {plain, _} = im(~s(<img src="a.png" width="30" height="10">x), loaded(30, 10))

      {items, _} =
        im(
          ~s(<img src="a.png" width="30" height="10" style="visibility:hidden">x),
          loaded(30, 10)
        )

      assert [%{hidden: true}] = pics(items)
      assert tw(items, "x").x == tw(plain, "x").x
    end

    test "while an image loads its declared size is reserved" do
      html = ~s(<img src="a.png" width="50" height="20">x)
      {items, _} = im(html, %{"http://example.test/other.png" => {:ok, 1, 1}})
      assert pics(items) == []
      {done, _} = im(html, loaded(50, 20))
      assert tw(items, "x").x == tw(done, "x").x
    end

    test "an empty image map means everything is still loading, not that images are off" do
      {items, _} = im(~s(a<img src="a.png" alt="alt">b), %{})
      refute tw(items, "[alt]")
      assert pics(items) == []
      {items, _} = im(~s(<img src="a.png" width="20" height="20">x), %{})
      {plain, _} = im(~s(x), %{})
      assert tw(items, "x").x == tw(plain, "x").x + 20
    end

    test "while an image loads without declared size it takes no room" do
      {items, _} = im(~s(a<img src="a.png">b), %{"http://example.test/other.png" => {:ok, 1, 1}})
      assert pics(items) == []
      assert tw(items, "a") && tw(items, "b")
    end

    test "a failed image shows its alt text, or nothing without one" do
      {items, _} = im(~s(<img src="a.png" alt="A picture">), %{@img => :failed})
      assert pics(items) == []
      assert tw(items, "[A") && tw(items, "picture]")
      {items, _} = im(~s(x<img src="a.png">y), %{@img => :failed})
      assert Enum.filter(items, &(&1.type == :text)) |> length() == 2
    end

    test "without image information the alt text is shown, as before" do
      page = Page.build(~s(<img src="a.png" alt="Alt text">), @base)
      {items, _} = Layout.layout(page.nodes, 400, &measure/2)
      assert tw(items, "[Alt")
    end

    test "an image with no src shows its alt text" do
      {items, _} = im(~s(<img alt="nothing here">), loaded(10, 10))
      assert tw(items, "[nothing")
    end

    test "images work inside inline-blocks and absolute boxes" do
      html =
        ~s(<span style="display:inline-block; background:#eee"><img src="a.png"></span>) <>
          ~s(<div style="position:absolute; top:100px; left:10px"><img src="a.png"></div>)

      {items, _} = im(html, loaded(30, 20))
      assert [a, b] = Enum.sort_by(pics(items), & &1.y)
      assert a.w == 30 and b.y >= 100 and b.x == 10
    end

    test "geometry is whole pixels at every size" do
      html =
        ~s(<img src="a.png" style="width:33%; border:1px solid #000; padding:1px"> t <img src="a.png" width="7">)

      for w <- [200, 333, 777] do
        {items, h} = im(html, loaded(101, 53), w)
        assert is_integer(h)

        for it <- items, key <- [:x, :y, :w, :h], Map.has_key?(it, key) do
          assert is_integer(Map.fetch!(it, key)), "#{key} of #{inspect(it)} at #{w}"
        end
      end
    end
  end

  describe "background images and shadows" do
    alias Browser.Page

    @pic "http://example.test/dir/a.png"

    defp bgl(html, images \\ nil, width \\ 400) do
      page =
        Page.build(
          "<style>body{margin:0} p,div{margin:0}</style>" <> html,
          "http://example.test/dir/p.html"
        )

      Layout.layout(page.nodes, width, &measure/2, 600, images: images)
    end

    defp kinds(items), do: Enum.map(items, & &1.type)
    defp of_type(items, type), do: Enum.filter(items, &(&1.type == type))

    test "a gradient background is an item with its layer, no image info needed" do
      {items, _} =
        bgl(
          ~s|<div style="background: linear-gradient(to right, red, blue); height: 40px">x</div>|
        )

      [%{layers: [layer], x: 4, w: 392, h: 40}] = of_type(items, :bgimage)
      assert %{kind: :linear, tile: {4, 0, 392, 40}, line: {x1, y1, x2, y2}} = layer
      assert {x1, y1, x2, y2} == {0.0, 20.0, 392.0, 20.0}
      assert [{+0.0, {255, 0, 0, 255}}, {1.0, {0, 0, 255, 255}}] = layer.stops
    end

    test "an image layer appears once its size is known" do
      html = ~s|<div style="background: url(a.png) no-repeat; height: 30px">x</div>|
      {loading, _} = bgl(html, %{})
      assert of_type(loading, :bgimage) == []
      {failed, _} = bgl(html, %{@pic => :failed})
      assert of_type(failed, :bgimage) == []

      {items, _} = bgl(html, %{@pic => {:ok, 20, 10}})

      assert [
               %{
                 layers: [
                   %{
                     kind: :image,
                     url: @pic,
                     tile: {4, 0, 20, 10},
                     repeat: {:no_repeat, :no_repeat}
                   }
                 ]
               }
             ] = of_type(items, :bgimage)
    end

    test "positioning, size and repeat apply" do
      html =
        ~s|<div style="background: url(a.png) right bottom / 40px auto no-repeat; height: 60px; width: 200px">x</div>|

      {items, _} = bgl(html, %{@pic => {:ok, 20, 10}})
      [%{layers: [layer]}] = of_type(items, :bgimage)
      # 40px wide, 20px tall, in the bottom-right corner of the 200x60 box at x=4
      assert layer.tile == {4 + 160, 40, 40, 20}
    end

    test "images are positioned in the padding box and painted into the border box" do
      html =
        ~s|<div style="background: url(a.png) no-repeat; border: 5px solid #000; padding: 3px; width: 50px; height: 20px">x</div>|

      {items, _} = bgl(html, %{@pic => {:ok, 10, 10}})
      [%{layers: [layer]} = item] = of_type(items, :bgimage)
      assert layer.tile == {4 + 5, 5, 10, 10}
      assert layer.clip == {4, 0, item.w, item.h}
      assert item.w == 50 + 6 + 10
    end

    test "layers are returned bottom first" do
      html =
        ~s|<div style="background: url(a.png) no-repeat, linear-gradient(red, blue); height: 30px">x</div>|

      {items, _} = bgl(html, %{@pic => {:ok, 10, 10}})
      [%{layers: [bottom, top]}] = of_type(items, :bgimage)
      assert bottom.kind == :linear and top.kind == :image
    end

    test "paint order of a decorated box: shadow, colour, images, inset shadow, borders" do
      html =
        ~s|<div style="box-shadow: 0 2px 4px #000, inset 0 0 3px #00f; background: #eee linear-gradient(red, blue); border: 1px solid #333; height: 20px">x</div>|

      {items, _} = bgl(html)
      boxes = items |> Enum.reject(&(&1.type == :text))
      assert kinds(boxes) == [:shadow, :rect, :bgimage, :inset_shadow, :rect, :rect, :rect, :rect]
      assert [%{color: {238, 238, 238}} | _] = of_type(items, :rect)
    end

    test "a rounded box keeps its borders above images and inset shadows" do
      html =
        ~s|<div style="background: #eee linear-gradient(red, blue); box-shadow: inset 0 0 4px #000; border: 2px solid #f00; border-radius: 8px; height: 20px">x</div>|

      {items, _} = bgl(html)
      boxes = Enum.reject(items, &(&1.type == :text))
      assert kinds(boxes) == [:rect, :bgimage, :inset_shadow, :rect]
      [fill, _, _, frame] = boxes
      assert fill.color == {238, 238, 238} and fill.border == nil
      assert frame.color == nil and frame.border.w == {2, 2, 2, 2}
      assert fill.radius == frame.radius
    end

    test "outer shadows: layers, blur fade, spread and the box's rounding" do
      {items, _} =
        bgl(
          ~s|<div style="box-shadow: 0 4px 8px 2px rgba(0,0,0,.4); border-radius: 6px; height: 40px">x</div>|
        )

      [%{layers: layers, radius: radii} = shadow] = of_type(items, :shadow)
      assert length(layers) == 8
      assert {{6, 6}, _, _, _} = radii
      # the item's box covers every layer
      for %{rect: {x, y, w, h}} <- layers do
        assert x >= shadow.x and y >= shadow.y and x + w <= shadow.x + shadow.w and
                 y + h <= shadow.y + shadow.h
      end

      # the outermost layer is bigger than the box by spread + blur, moved down by 4
      %{rect: {x, y, w, h}} = hd(layers)
      assert {x, y, w, h} == {4 - 10, 0 + 4 - 10, 392 + 20, 40 + 20}
    end

    test "a box with a shadow but no colour or border still gets the shadow" do
      {items, _} = bgl(~s(<div style="box-shadow: 2px 2px #000">x</div>))
      assert [%{type: :shadow}] = of_type(items, :shadow)
      assert of_type(items, :rect) == []
    end

    test "several outer shadows: the first is painted last, on top" do
      {items, _} =
        bgl(~s(<div style="box-shadow: 1px 1px #f00, 5px 5px #00f; height: 10px">x</div>))

      [first, second] = of_type(items, :shadow)
      assert [%{color: {0, 0, 255, 255}}] = first.layers
      assert [%{color: {255, 0, 0, 255}}] = second.layers
    end

    test "box-shadow none and an empty list draw nothing" do
      {items, _} = bgl(~s(<div style="box-shadow: none; background: #eee">x</div>))
      assert of_type(items, :shadow) == []
    end

    test "shadows of an element inside a clipping box are clipped with it" do
      html =
        ~s(<div style="width:50px; height:20px; overflow:hidden"><div style="box-shadow: 0 0 6px #000; width: 30px; height: 10px">x</div></div>)

      {items, _} = bgl(html)
      assert %{clip: %{w: 50}} = hd(of_type(items, :shadow))
    end

    test "the body's gradient becomes the canvas, and the body doesn't paint it again" do
      html = ~s|<html><body style="background: linear-gradient(red, blue)"><p>x</p></body></html>|
      {items, _} = bgl(html)
      [%{type: :canvas, layers: [layer]} | rest] = items
      assert layer.kind == :linear
      assert of_type(rest, :bgimage) == []
    end

    test "the canvas covers the whole window even when the content is short" do
      html = ~s|<html><body style="background: #123 url(a.png) repeat-x"><p>x</p></body></html>|
      {[canvas | _], height} = bgl(html, %{@pic => {:ok, 10, 10}})
      assert canvas.color == {17, 34, 51}
      assert canvas.h == 600 and canvas.w == 400 and height < 100

      assert [%{kind: :image, repeat: {:repeat, :no_repeat}, clip: {0, 0, 400, 600}}] =
               canvas.layers
    end

    test "when html has a background too, the body keeps its own" do
      html =
        ~s|<html style="background: #111"><body style="background: linear-gradient(red, blue)"><p>x</p></body></html>|

      {items, _} = bgl(html)
      assert [%{type: :canvas, color: {17, 17, 17}, layers: []} | rest] = items
      assert [%{type: :bgimage}] = of_type(rest, :bgimage)
    end

    test "inside an inline-block, shadows and images still go behind the text and above the colour" do
      html =
        ~s|<span style="display:inline-block"><div style="box-shadow: 0 2px 4px #000; background: #eee linear-gradient(red, blue); width: 60px; height: 30px">x</div></span>|

      {items, _} = bgl(html)
      assert kinds(items) == [:shadow, :rect, :bgimage, :text]
    end

    test "decorations inside an inline-block move with it" do
      deco =
        "background: url(a.png) no-repeat, linear-gradient(red, blue); box-shadow: 0 2px 4px #000, inset 0 0 3px #00f;"

      plain = ~s|<div style="#{deco} width: 60px; height: 30px">x</div>|

      boxed =
        ~s|<span style="display:inline-block; margin-left: 40px"><div style="#{deco} width: 60px; height: 30px">x</div></span>|

      {a, _} = bgl(plain, %{@pic => {:ok, 10, 10}})
      {b, _} = bgl(boxed, %{@pic => {:ok, 10, 10}})

      for type <- [:bgimage, :shadow, :inset_shadow] do
        [one] = of_type(a, type)
        [two] = of_type(b, type)
        assert two.x == one.x + 40, "#{type} item"
        # what is inside the item moved by the same amount
        case type do
          :bgimage ->
            for {l1, l2} <- Enum.zip(one.layers, two.layers) do
              assert elem(l2.tile, 0) == elem(l1.tile, 0) + 40
              assert elem(l2.clip, 0) == elem(l1.clip, 0) + 40
              assert elem(l2.tile, 1) == elem(l1.tile, 1)
            end

          :shadow ->
            for {l1, l2} <- Enum.zip(one.layers, two.layers),
                do: assert(elem(l2.rect, 0) == elem(l1.rect, 0) + 40)

          :inset_shadow ->
            for {l1, l2} <- Enum.zip(one.layers, two.layers),
                do: assert(elem(l2.hole.rect, 0) == elem(l1.hole.rect, 0) + 40)
        end
      end
    end

    test "geometry stays on whole pixels" do
      html =
        ~s|<div style="background: url(a.png) 33.3% 66.6% / 33% auto, radial-gradient(circle at 20% 30%, red, blue); box-shadow: 1.5px 2.5px 7.3px 1.2px #000; border-radius: 7%; height: 33.3px; width: 77.7%">x</div>|

      for w <- [200, 333, 777] do
        {items, h} = bgl(html, %{@pic => {:ok, 21, 13}}, w)
        assert is_integer(h)

        for it <- items,
            key <- [:x, :y, :w, :h],
            Map.has_key?(it, key),
            do: assert(is_integer(Map.fetch!(it, key)))

        for %{layers: layers} <- of_type(items, :bgimage),
            %{tile: {x, y, tw, th}} <- layers,
            do: assert(Enum.all?([x, y, tw, th], &is_integer/1))

        for %{layers: layers} <- of_type(items, :shadow),
            %{rect: {x, y, sw, sh}} <- layers,
            do: assert(Enum.all?([x, y, sw, sh], &is_integer/1))
      end
    end
  end

  describe "control bounds" do
    alias Browser.Page

    test "a field without background or border still has its full box" do
      html =
        ~s|<style>body{margin:0} input{display:block;width:100%;border:none;padding:0;background:none}</style>| <>
          ~s|<input type="text" value="">|

      page = Page.build(html, "about:home")
      {items, _} = Layout.layout(page.nodes, 400, &measure/2, 600)
      [bounds] = Map.values(Layout.controls(items))
      assert bounds.w >= 390
      assert bounds.h > 5
    end
  end

  describe "controls wider than the box that clips them" do
    alias Browser.Page

    @clipped ~s|<style>body{margin:0} .w{display:inline-block;overflow:hidden;width:100px} select{display:block;width:140%;border:none;padding:0 10px}</style>| <>
               ~s|<div class="w"><select><option>A</option></select></div><div class="w"><select><option>B</option></select></div>|

    test "selects size their border box" do
      page = Page.build(@clipped, "about:home")
      {items, _} = Layout.layout(page.nodes, 600, &measure/2, 600)

      assert [%{w: 140}, %{w: 140}] =
               items |> Layout.controls() |> Enum.sort() |> Enum.map(&elem(&1, 1))
    end

    test "the focus ring stays inside the clipping box" do
      page = Page.build(@clipped, "about:home")
      {plain, _} = Layout.layout(page.nodes, 600, &measure/2, 600)
      [{cid, _} | _] = plain |> Layout.controls() |> Enum.sort()
      {items, _} = Layout.layout(page.nodes, 600, &measure/2, 600, focus: %{cid: cid, caret: nil})
      [ring] = Enum.filter(items, &(&1.type == :ring))
      # the box is 100 wide at x 4; the ring is 2px outside the visible part of the field
      assert ring.x + ring.w <= 4 + 100 + 2
    end
  end

  describe "selection in a focused field" do
    alias Browser.Page

    defp field_items(html, focus) do
      page = Page.build("<style>body{margin:0}</style>" <> html, "about:home")
      {plain, _} = Layout.layout(page.nodes, 400, &measure/2, 600)
      [{cid, _} | _] = plain |> Layout.controls() |> Enum.sort()

      {items, _} =
        Layout.layout(page.nodes, 400, &measure/2, 600, focus: Map.put(focus, :cid, cid))

      {items, cid}
    end

    test "a single-line field highlights the selected characters" do
      {items, cid} =
        field_items(~s|<input type="text" value="hello world">|, %{
          caret: {0, 7},
          sel: {{0, 2}, {0, 7}}
        })

      [text] = Enum.filter(items, &(&1.type == :text and &1.cid == cid))
      [sel] = Enum.filter(items, &(&1.type == :selection))
      assert sel.cid == cid
      assert sel.x == text.x + measure("he", text)
      assert sel.w == measure("llo w", text)
    end

    test "no selection, no highlight" do
      {items, _} = field_items(~s|<input type="text" value="hello">|, %{caret: {0, 2}, sel: nil})
      assert Enum.filter(items, &(&1.type == :selection)) == []
    end

    test "a textarea highlights each line of the selection" do
      {items, _} =
        field_items(
          ~s|<textarea rows="4">one two\nthree\nfour</textarea>|,
          %{caret: {2, 2}, sel: {{0, 4}, {2, 2}}}
        )

      sels = Enum.filter(items, &(&1.type == :selection))
      assert length(sels) == 3
      [first, second, third] = Enum.sort_by(sels, & &1.y)
      # 3, 5 and 2 characters of the same width each
      assert first.w * 5 == second.w * 3
      assert third.w * 5 == second.w * 2
    end
  end

  describe "content width" do
    alias Browser.Page

    defp content(html, width \\ 400) do
      page = Page.build("<style>body{margin:0}</style>" <> html, "about:home")
      {items, _} = Layout.layout(page.nodes, width, &measure/2, 600)
      Layout.content_width(items, width)
    end

    test "is the window for ordinary pages" do
      assert content("<p>hello world</p>") == 400
    end

    test "a wide box makes the page wider" do
      assert content(~s|<div style="width:900px;background:#eee">x</div>|) >= 900
    end

    test "so do wide pictures and unbreakable text" do
      assert content(~s|<svg width="1200" height="10"></svg>|) >= 1200
      assert content(~s|<pre>#{String.duplicate("x", 200)}</pre>|) > 400
    end

    test "what overflow hidden clips does not" do
      html =
        ~s|<div style="width:100px;overflow:hidden"><div style="width:900px;background:#eee">x</div></div>|

      assert content(html) == 400
    end
  end

  describe "flexbox" do
    alias Browser.Page

    # 8px per character (see measure/2 at 16px); the page keeps a 4px margin on both sides
    defp flex(html, width \\ 408) do
      page = Page.build("<style>body{margin:0} div,p{margin:0}</style>" <> html, "about:home")
      {items, h} = Layout.layout(page.nodes, width, &measure/2, 600)
      {items, h}
    end

    defp at(items, text), do: Enum.find(items, &(Map.get(&1, :text) == text))
    defp x_of(items, text), do: at(items, text).x - 4

    test "items sit side by side, flush" do
      {items, _} = flex(~s|<div style="display:flex"><div>ab</div><div>cd</div></div>|)
      assert x_of(items, "ab") == 0
      assert x_of(items, "cd") == 16
      assert at(items, "ab").y == at(items, "cd").y
    end

    test "gap" do
      {items, _} = flex(~s|<div style="display:flex;gap:10px"><div>ab</div><div>cd</div></div>|)
      assert x_of(items, "cd") == 26
    end

    test "flex-grow shares the free space" do
      {items, _} =
        flex(
          ~s|<div style="display:flex"><div style="flex:1">a</div><div style="flex:1">b</div></div>|
        )

      assert x_of(items, "b") == 200
    end

    test "grow factors weight the share" do
      {items, _} =
        flex(
          ~s|<div style="display:flex"><div style="flex:1">a</div><div style="flex:3">b</div></div>|
        )

      assert x_of(items, "b") == 100
    end

    test "a fixed item and a growing one" do
      {items, _} =
        flex(
          ~s|<div style="display:flex"><div style="width:100px">a</div><div style="flex:1">b</div></div>|
        )

      assert x_of(items, "b") == 100
    end

    test "justify-content" do
      row = fn j ->
        ~s|<div style="display:flex;justify-content:#{j}"><div>ab</div><div>cd</div></div>|
      end

      # 400 wide, content 32
      {items, _} = flex(row.("flex-end"))
      assert x_of(items, "ab") == 368
      {items, _} = flex(row.("center"))
      assert x_of(items, "ab") == 184
      {items, _} = flex(row.("space-between"))
      assert x_of(items, "ab") == 0
      assert x_of(items, "cd") == 384
      {items, _} = flex(row.("space-around"))
      assert x_of(items, "ab") == 92
      {items, _} = flex(row.("space-evenly"))
      assert round(x_of(items, "ab")) == 123
    end

    test "auto margins push items apart" do
      {items, _} =
        flex(
          ~s|<div style="display:flex"><div>ab</div><div style="margin-left:auto">cd</div></div>|
        )

      assert x_of(items, "ab") == 0
      assert x_of(items, "cd") == 384
    end

    test "align-items places items across the line" do
      html = fn a ->
        ~s|<div style="display:flex;align-items:#{a}"><div style="height:80px;background:#eee">a</div><div style="height:40px;background:#ddd">b</div></div>|
      end

      tops = fn a ->
        {items, _} = flex(html.(a))
        [x, y] = items |> Enum.filter(&(&1.type == :rect)) |> Enum.sort_by(& &1.x)
        {y.y - x.y, y.h}
      end

      assert tops.("flex-start") == {0, 40}
      assert tops.("center") == {20, 40}
      assert tops.("flex-end") == {40, 40}
      assert tops.("stretch") == {0, 40}
    end

    test "items stretch to the height of the line" do
      html =
        ~s|<div style="display:flex"><div style="background:#eee;font-size:32px">tall</div><div style="background:#ddd">s</div></div>|

      {items, _} = flex(html)
      [a, b] = items |> Enum.filter(&(&1.type == :rect)) |> Enum.sort_by(& &1.x)
      assert a.h == b.h
    end

    test "too much content shrinks items" do
      html =
        ~s|<div style="display:flex"><div style="width:300px">a</div><div style="width:300px">b</div></div>|

      {items, _} = flex(html)
      assert x_of(items, "b") == 200
    end

    test "flex-shrink: 0 keeps the size" do
      html =
        ~s|<div style="display:flex"><div style="width:300px;flex-shrink:0">a</div><div style="width:300px">b</div></div>|

      {items, _} = flex(html)
      assert x_of(items, "b") == 300
    end

    test "wrapping starts a new line" do
      html =
        ~s|<div style="display:flex;flex-wrap:wrap;gap:0"><div style="width:150px">a</div><div style="width:150px">b</div><div style="width:150px">c</div></div>|

      {items, _} = flex(html)
      assert at(items, "a").y == at(items, "b").y
      assert at(items, "c").y > at(items, "a").y
      assert x_of(items, "c") == 0
    end

    test "columns stack, with a gap" do
      {items, _} =
        flex(
          ~s|<div style="display:flex;flex-direction:column;gap:10px"><div>a</div><div>b</div></div>|
        )

      assert at(items, "b").y - at(items, "a").y > 10
      assert x_of(items, "a") == 0 and x_of(items, "b") == 0
    end

    test "columns align items: start shrinks to the content, center centres" do
      html = fn a ->
        ~s|<div style="display:flex;flex-direction:column;align-items:#{a}"><div style="background:#eee">ab</div></div>|
      end

      {items, _} = flex(html.("stretch"))
      assert [%{w: 400}] = Enum.filter(items, &(&1.type == :rect))
      {items, _} = flex(html.("flex-start"))
      assert [%{w: 16}] = Enum.filter(items, &(&1.type == :rect))
      {items, _} = flex(html.("center"))
      assert [%{x: 196, w: 16}] = Enum.filter(items, &(&1.type == :rect))
    end

    test "nested flex containers" do
      html =
        ~s|<div style="display:flex;justify-content:space-between"><div style="display:flex;gap:8px"><div>a</div><div>b</div></div><div>c</div></div>|

      {items, _} = flex(html)
      assert x_of(items, "b") == 16
      assert x_of(items, "c") == 392
    end

    test "an inline-flex link in a container is as wide as its content, not spread out" do
      html =
        ~s|<div style="display:flex;justify-content:space-between"><a href="/" style="display:inline-flex;justify-content:center;padding:0 10px"><span>logo</span></a><div>menu</div></div>|

      {items, _} = flex(html)
      # "logo" (32px) sits after the link's 10px padding; the link ends right after it
      assert x_of(items, "logo") == 10
      assert x_of(items, "menu") == 400 - 32
    end

    test "buttons side by side keep their own width" do
      html =
        ~s|<div style="display:flex;gap:8px"><a style="display:inline-flex;padding:4px;background:#eee">go</a><a style="display:inline-flex;padding:4px;background:#ddd">stop</a></div>|

      {items, _} = flex(html)
      [a, b] = items |> Enum.filter(&(&1.type == :rect)) |> Enum.sort_by(& &1.x)
      assert a.w == 16 + 8
      assert b.x == a.x + a.w + 8
    end

    test "a row with a height of its own centres items inside it" do
      html =
        ~s|<div style="display:flex;align-items:center;height:80px"><div style="background:#eee;height:40px">a</div></div>|

      {items, h} = flex(html)
      [r] = Enum.filter(items, &(&1.type == :rect))
      assert r.y == 20
      # the row is 80 high; the page adds its 4px margin below
      assert h == 84
    end

    test "box-sizing: border-box takes the padding out of the row's height" do
      html =
        ~s|<div style="display:flex;align-items:center;height:80px;padding:10px 0;box-sizing:border-box"><div style="background:#eee;height:40px">a</div></div>|

      {items, h} = flex(html)
      [r] = Enum.filter(items, &(&1.type == :rect))
      assert r.y == 20
      assert h == 84
    end

    test "width: fit-content makes a block as wide as its content" do
      {items, _} = flex(~s|<div style="width:fit-content;background:#eee">abcd</div><p>x</p>|)
      assert [%{w: 32}] = Enum.filter(items, &(&1.type == :rect))
      # and the next block starts on a line of its own
      assert at(items, "x").y > at(items, "abcd").y
    end

    test "fit-content as a flex item in a column that stretches" do
      html =
        ~s|<div style="display:flex;flex-direction:column"><div style="width:fit-content;background:#eee">ab</div></div>|

      {items, _} = flex(html)
      assert [%{w: 16}] = Enum.filter(items, &(&1.type == :rect))
    end

    test "text directly in a container is an item" do
      {items, _} = flex(~s|<div style="display:flex;gap:10px">hello<div>x</div></div>|)
      assert x_of(items, "x") == 40 + 10
    end

    test "order" do
      {items, _} =
        flex(
          ~s|<div style="display:flex"><div style="order:2">a</div><div style="order:1">b</div></div>|
        )

      assert x_of(items, "b") < x_of(items, "a")
    end

    test "row-reverse" do
      {items, _} =
        flex(
          ~s|<div style="display:flex;flex-direction:row-reverse"><div>a</div><div>b</div></div>|
        )

      assert x_of(items, "b") < x_of(items, "a")
    end

    test "a flex container's own padding and background wrap its items" do
      html = ~s|<div style="display:flex;padding:10px;background:#eee"><div>a</div></div>|
      {items, _} = flex(html)
      assert x_of(items, "a") == 10
      assert [%{w: 400}] = Enum.filter(items, &(&1.type == :rect))
    end

    test "images and svg are items" do
      html =
        ~s|<div style="display:flex;gap:10px"><svg width="30" height="20"></svg><div>x</div></div>|

      {items, _} = flex(html)
      assert x_of(items, "x") == 40
    end
  end
end
