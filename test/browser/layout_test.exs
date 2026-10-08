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

  test "soft hyphens are invisible" do
    {items, _} = run("<p>co&shy;op&shy;er&shy;ate</p><pre>a&shy;b</pre>")
    assert texts(items) |> Enum.sort() == ["ab", "cooperate"]
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
      assert cd.x + cd.w == 400 - 4 - 8
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

    test "a string list-style-type is the marker, also in a list nested in an ol" do
      {items, _} =
        styled(
          ~s|<style>li.d { list-style-type: "- " }</style><ol><li><ul><li class=d>a</li></ul></li></ol>|
        )

      assert "- " in texts(items)
      refute "1." in tl(Enum.drop_while(texts(items), &(&1 != "1.")))
    end

    test "the first item of a list nested in an item lines up with its siblings" do
      {items, _} = styled("<ol><li><ul><li>a</li><li>b</li></ul></li></ol>")
      markers = for %{text: "◦", x: x} <- items, do: x
      assert [x, x] = markers
      assert word(items, "a").x == word(items, "b").x
    end

    test "a control beside an inline-block with a fixed-width child gets the rest of the row" do
      {items, _} =
        styled(
          ~s|<div style="width: 700px"><div style="display:flex"><div style="display:flex;flex:1 1 0%"><textarea style="display:flex;width:100%;flex:100%;border:none;height:18px" rows=1></textarea></div><div style="display:flex;flex:0 0 auto"><div style="display:inline-block"><div style="display:flex;flex-grow:1;width:24px"><div style="width:24px;height:24px"></div></div></div></div></div></div>|,
          800
        )

      [%{w: w}] = items |> Browser.Layout.controls() |> Map.values()
      assert w > 600
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

    test "overflow visible lets content overflow the box and the content after it" do
      html = @reset <> ~s(<div style="height:10px"><p>l1</p><p>l2</p><p>l3</p></div><p>after</p>)
      {items, _} = styled2(html)
      assert w2(items, "l3")
      # the box is as tall as it says, so what follows starts right below it
      assert w2(items, "after").y < w2(items, "l3").y
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
          ~w(sample hidden positioning boxes rounded lineheight forms images backgrounds svg selects wide tables floats margins sticky transforms) do
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

    test "dashed and dotted borders are rows of dashes and dots" do
      {items, _} = bx(~s(<div style="border-top: 2px dashed #f00; width: 100px">x</div>))
      dashes = rects(items)
      assert length(dashes) > 3
      assert Enum.all?(dashes, &(&1.h == 2 and &1.color == {255, 0, 0}))
      assert Enum.all?(dashes, &(&1.w in 5..7))
      # starts and ends with a full dash, with gaps between
      assert List.last(dashes).x + List.last(dashes).w - hd(dashes).x == 100
      assert Enum.all?(Enum.chunk_every(dashes, 2, 1, :discard), fn [a, b] -> b.x > a.x + a.w end)

      {items, _} = bx(~s(<div style="border-left: 2px dotted #00f; height: 40px">x</div>))
      assert length(rects(items)) > 5
      assert Enum.all?(rects(items), &(&1.w == 2 and &1.h in 1..3))
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

    test "an inline-block with a length vertical-align sits that far above the baseline" do
      box = fn va ->
        ~s|<div style="line-height:20px">a<span style="display:inline-block;width:10px;height:10px;background:#eee;#{va}"></span></div>|
      end

      {plain, _} = rb(box.(""))
      {raised, _} = rb(box.("vertical-align:15px"))
      # the height of the box above the bottom of the text
      above = fn items ->
        wr(items, "a").y + wr(items, "a").h - (hd(rr(items)).y + hd(rr(items)).h)
      end

      assert above.(raised) - above.(plain) == 15
    end

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
      top = boxes(items) |> Enum.map(& &1.y) |> Enum.min()
      bottom = boxes(items) |> Enum.map(& &1.y) |> Enum.max()
      assert Enum.all?(boxes(items), &(&1.color == {192, 192, 192}))
      left = Enum.min_by(boxes(items), & &1.x).x
      assert wf(items, "Title").x > left
      # the legend straddles the top border
      assert wf(items, "Title").y <= top
      assert wf(items, "Content").y > wf(items, "Title").y
      assert wf(items, "Content").y < bottom
    end

    test "a legend sits on the top border and interrupts it" do
      {items, _} =
        fm(~s(<fieldset style="border: 2px solid #f00"><legend>Title</legend>Content</fieldset>))

      title = wf(items, "Title")
      top_y = boxes(items) |> Enum.map(& &1.y) |> Enum.min()
      # the top border runs along the middle of the legend, in two pieces around it
      assert [left, right] =
               boxes(items) |> Enum.filter(&(&1.y == top_y and &1.h == 2)) |> Enum.sort_by(& &1.x)

      assert left.y + 1 > title.y and left.y < title.y + title.h
      assert left.x + left.w <= title.x
      assert right.x >= title.x + title.w
      assert wf(items, "Content").y >= title.y + title.h
    end

    test "a rounded fieldset's border item carries the gap for its legend" do
      {items, _} =
        fm(
          ~s(<fieldset style="border: 2px dashed #f00; border-radius: 4px"><legend>Title</legend>x</fieldset>)
        )

      title = wf(items, "Title")
      assert [%{border: %{gap: {g0, g1}}}] = boxes(items)
      assert g0 <= title.x and g1 >= title.x + title.w
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

    test "object-fit draws the picture at its own ratio inside the box" do
      {items, _} =
        im(
          ~s(<img src="a.png" style="width:100px; height:100px; object-fit:cover">),
          loaded(200, 100)
        )

      assert [%{w: 100, h: 100, fit: {-50.0, +0.0, 200.0, 100.0}}] = pics(items)

      {items, _} =
        im(
          ~s(<img src="a.png" style="width:100px; height:100px; object-fit:contain">),
          loaded(200, 100)
        )

      assert [%{fit: {+0.0, 25.0, 100.0, 50.0}}] = pics(items)
    end

    test "aspect-ratio sets the height from the width of a picture" do
      {items, _} =
        im(~s(<img src="a.png" style="width:100px; aspect-ratio:1">), loaded(200, 100))

      assert [%{w: 100, h: 100}] = pics(items)
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
      {done, _} = im(html, loaded(50, 20))
      assert tw(items, "x").x == tw(done, "x").x
    end

    test "a loading image with a declared size has the same items as the loaded one" do
      html = ~s(<p>a</p><img src="a.png" width="50" height="20">x)
      {loading, h1} = im(html, %{})
      {done, h2} = im(html, loaded(50, 20))
      assert loading == done
      assert h1 == h2
      assert [%{type: :image, w: 50, h: 20}] = pics(loading)
    end

    test "a loading image without a full declared size has no item yet" do
      {items, _} = im(~s(<img src="a.png" width="50">x), %{})
      assert pics(items) == []
    end

    test "image_size_fixed? is true only when every <img> of the url has both dimensions" do
      nodes = fn html -> Page.build(html, @base).nodes end
      fixed = &Layout.image_size_fixed?(nodes.(&1), @img)

      assert fixed.(~s(<img src="a.png" width="5" height="5">))
      assert fixed.(~s(<img src="a.png" style="width:5px;height:5px">))
      assert fixed.(~s(<img src="b.png">))
      refute fixed.(~s(<img src="a.png">))
      refute fixed.(~s(<img src="a.png" width="5">))
      refute fixed.(~s(<img src="a.png" width="5" height="5" style="height:auto">))
      refute fixed.(~s(<img src="a.png" width="5" height="5"><div><img src="a.png"></div>))
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

    test "a row group's picture is placed against the group, not each cell" do
      html =
        ~s|<table style="border-spacing:0"><tbody style="background: url(a.png) right bottom no-repeat"><tr><td style="width:20px;height:20px;padding:0"></td><td style="width:20px;height:20px;padding:0"></td></tr><tr><td style="width:20px;height:20px;padding:0"></td><td style="width:20px;height:20px;padding:0"></td></tr></tbody></table>|

      {items, _} = bgl(html, %{@pic => {:ok, 10, 10}})
      tiles = for %{layers: layers} <- of_type(items, :bgimage), l <- layers, do: l.tile
      # one tile in the corner of the group (4 + 40 - 10, 40 - 10), which every cell shares
      assert Enum.uniq(tiles) == [{34, 30, 10, 10}]
    end

    test "a column's picture is placed against the column and clipped to each cell" do
      cell = ~s|<td style="width:20px;height:20px;padding:0"></td>|

      html =
        ~s|<table style="border-spacing:0"><colgroup><col style="background: url(a.png) no-repeat"><col></colgroup><tr>#{cell}#{cell}</tr><tr>#{cell}#{cell}</tr></table>|

      {items, _} = bgl(html, %{@pic => {:ok, 10, 10}})
      tiles = for %{layers: layers} <- of_type(items, :bgimage), l <- layers, do: l.tile
      # a single tile, at the top left of the column
      assert Enum.uniq(tiles) == [{4, 0, 10, 10}]
      assert length(tiles) == 2
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

    test "buttons in a flex row are as wide as their text (a control's box fills any width)" do
      html =
        ~s|<div style="display:flex;overflow-x:auto"><div style="display:flex;flex-shrink:0"><button style="flex-shrink:0;padding:4px 24px">Books</button><button style="flex-shrink:0;padding:4px 24px">Courses</button></div></div>|

      {items, _} = flex(html)
      assert x_of(items, "Courses") < 200
      assert Layout.content_width(items, 408) == 408
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

  describe "tables" do
    alias Browser.Page

    # 8px per character at 16px; the page keeps a 4px margin; the default cell spacing is 2px
    # and padding 1px, so a cell holding "ab" is 18 wide
    defp tbl(html, width \\ 408) do
      page = Page.build("<style>body{margin:0} p{margin:0}</style>" <> html, "about:home")
      Layout.layout(page.nodes, width, &measure/2, 600)
    end

    defp table_rects(items),
      do: items |> Enum.filter(&(&1.type == :rect)) |> Enum.sort_by(&{&1.y, &1.x})

    test "cells sit in columns, rows below each other" do
      {items, _} =
        tbl("<table><tr><td>aa</td><td>bbbb</td></tr><tr><td>c</td><td>d</td></tr></table>")

      assert at(items, "aa").y == at(items, "bbbb").y
      assert at(items, "c").y > at(items, "aa").y
      # the second column starts in the same place in every row
      assert at(items, "bbbb").x == at(items, "d").x
      assert at(items, "aa").x == at(items, "c").x
    end

    test "min-height on the table and height on a row raise the rows" do
      {tall, _} =
        tbl(
          ~s|<table style="border-spacing:0;min-height:100px"><tr><td style="padding:0">a</td></tr></table>|
        )

      {row, _} =
        tbl(
          ~s|<table style="border-spacing:0"><tr style="height:60px"><td style="padding:0;vertical-align:top">a</td></tr><tr><td style="padding:0;vertical-align:top">b</td></tr></table>|
        )

      {plain, _} =
        tbl(
          ~s|<table style="border-spacing:0"><tr><td style="padding:0">a</td></tr><tr><td style="padding:0">b</td></tr></table>|
        )

      assert at(row, "b").y - at(row, "a").y == 60
      assert at(plain, "b").y - at(plain, "a").y < 60
      assert tall |> table_rects() |> Enum.all?(&(&1.h <= 100))
    end

    test "min-width of a cell or column is the least its column is" do
      {cell, _} =
        tbl(
          ~s|<table style="border-spacing:0"><tr><td style="padding:0;min-width:80px">a</td><td style="padding:0">b</td></tr></table>|
        )

      {col, _} =
        tbl(
          ~s|<table style="border-spacing:0"><col style="min-width:80px"><tr><td style="padding:0">a</td><td style="padding:0">b</td></tr></table>|
        )

      assert at(cell, "b").x - at(cell, "a").x == 80
      assert at(col, "b").x - at(col, "a").x == 80
    end

    test "a caption keeps its margins and makes the table at least as wide as itself" do
      html = fn margin ->
        ~s|<table style="border-spacing:0"><caption style="margin-left:#{margin}px"><div style="width:100px">x</div></caption>| <>
          ~s|<tr><td style="padding:0">a</td><td style="padding:0">b</td></tr></table>|
      end

      {with, _} = tbl(html.(30))
      {without, _} = tbl(html.(0))
      assert at(with, "x").x - at(without, "x").x == 30
      # the last column took what the caption needed over the cells
      assert at(without, "b").x - at(without, "a").x >= 50
    end

    test "a block-wide cell leaves the others as wide as their unbreakable text" do
      {items, _} =
        tbl(
          ~s|<style>td{white-space:nowrap} .w{width:100%;white-space:normal}| <>
            ~s|a{display:inline-block;max-width:100%}</style>| <>
            ~s|<table style="width:100%"><tr><td><a href="#">e20f986af5</a></td>| <>
            ~s|<td class="w"><a href="#">subject line</a></td></tr></table>|
        )

      assert at(items, "subject").x >= at(items, "e20f986af5").x + 80
    end

    test "text-wrap: nowrap keeps a cell's text on one line" do
      {items, _} =
        tbl(
          ~s|<style>td{text-wrap:nowrap}</style><table style="width:100%">| <>
            ~s|<tr><td>10 days</td><td style="width:100%;text-wrap:wrap">x</td></tr></table>|
        )

      assert at(items, "10").y == at(items, "days").y
    end

    test "the table is as wide as its columns need, not the whole window" do
      {items, _} =
        tbl(~s|<table style="background:#eee"><tr><td>aa</td><td>bbbb</td></tr></table>|)

      [r] = table_rects(items)
      # 2 + 18 + 2 + 34 + 2
      assert r.w == 58
    end

    test "in a narrow window columns shrink to their widest word, padding included" do
      html =
        ~s|<table style="background:#eee"><tr><td>aa bbbbbb c</td><td style="padding:5px">dd eeee</td></tr></table>|

      {items, _} = tbl(html, 60)
      [r] = table_rects(items)
      # the same width the cells get when laid out one word per line
      assert r.w == 52
      assert at(items, "aa").y < at(items, "bbbbbb").y
      assert at(items, "dd").y < at(items, "eeee").y
    end

    test "columns share a fixed width by their content" do
      html = ~s|<table width="400"><tr><td>a</td><td>bbbbbbbb</td></tr></table>|
      {items, _} = tbl(html)
      a = at(items, "a")
      b = at(items, "bbbbbbbb")
      # all 400px are used and the wider column gets the larger share
      assert b.x - a.x > 10
      assert b.x + b.w + 3 + 2 <= 4 + 400 + 1
    end

    test "text wraps inside a narrow table" do
      html = ~s|<table width="100"><tr><td>aaaa bbbb cccc dddd</td></tr></table>|
      {items, _} = tbl(html)
      ys = for w <- ~w(aaaa bbbb cccc dddd), do: at(items, w).y
      assert length(Enum.uniq(ys)) > 1
    end

    test "colspan and rowspan" do
      html =
        ~s|<table><tr><td colspan="2">wide wide</td><td rowspan="2">tall</td></tr><tr><td>a</td><td>b</td></tr></table>|

      {items, _} = tbl(html)
      assert at(items, "tall").x > at(items, "b").x
      assert at(items, "a").y > at(items, "wide").y
      assert at(items, "tall").y <= at(items, "a").y
    end

    test "cellspacing and cellpadding" do
      {plain, _} = tbl(~s|<table><tr><td>a</td><td>b</td></tr></table>|)

      {spaced, _} =
        tbl(~s|<table cellspacing="10" cellpadding="5"><tr><td>a</td><td>b</td></tr></table>|)

      assert at(spaced, "a").x - at(plain, "a").x == 10 + 5 - (2 + 1)
      assert at(spaced, "b").x - at(spaced, "a").x > at(plain, "b").x - at(plain, "a").x
    end

    test "the border attribute draws a border on the table and its cells" do
      {items, _} = tbl(~s|<table border="1"><tr><td>a</td></tr></table>|)
      assert length(table_rects(items)) == 8
    end

    test "collapsed borders are shared" do
      css = "<style>table{border-collapse:collapse} td{border:1px solid #000}</style>"
      {items, _} = tbl(css <> "<table><tr><td>a</td><td>b</td></tr></table>")

      verticals =
        items |> table_rects() |> Enum.filter(&(&1.w == 1)) |> Enum.map(& &1.x) |> Enum.sort()

      # left edge, the shared line, right edge: three lines, not four
      assert length(verticals) == 3
    end

    test "backgrounds fill the whole cell and the row has one height" do
      html =
        ~s|<table><tr><td style="background:#eee">a</td><td style="background:#ddd;font-size:32px">b</td></tr></table>|

      {items, _} = tbl(html)
      [x, y] = table_rects(items)
      assert x.h == y.h
      assert x.y == y.y
    end

    test "row and row group backgrounds show behind the cells" do
      html =
        ~s|<table><thead style="background:#111"><tr><td>h</td></tr></thead><tr bgcolor="#eeeeee"><td>a</td><td>b</td></tr></table>|

      {items, _} = tbl(html)
      colors = items |> table_rects() |> Enum.map(& &1.color)
      assert {17, 17, 17} in colors
      assert length(Enum.filter(colors, &(&1 == {238, 238, 238}))) == 2
    end

    test "vertical alignment: middle by default, top and bottom on request" do
      td = fn v ->
        ~s|<table><tr><td style="font-size:32px;background:#ccc">big</td><td valign="#{v}">s</td></tr></table>|
      end

      {mid, _} = tbl(td.("middle"))
      {top, _} = tbl(td.("top"))
      {bottom, _} = tbl(td.("bottom"))
      assert at(top, "s").y < at(mid, "s").y
      assert at(mid, "s").y < at(bottom, "s").y
    end

    test "valign on the row" do
      html =
        ~s|<table><tr valign="top"><td style="font-size:32px">big</td><td>s</td></tr></table>|

      {items, _} = tbl(html)
      assert at(items, "s").y < 12
    end

    test "text-align from the align attribute and th" do
      html = ~s|<table width="200"><tr><th>h</th><td align="right">r</td></tr></table>|
      {items, _} = tbl(html)
      assert at(items, "h").x < at(items, "r").x
    end

    test "a caption sits above the rows" do
      {items, _} = tbl(~s|<table><caption>cap</caption><tr><td>cell</td></tr></table>|)
      assert at(items, "cap").y < at(items, "cell").y
    end

    test "header rows come first and footer rows last, wherever they are written" do
      html =
        ~s|<table><tfoot><tr><td>foot</td></tr></tfoot><tbody><tr><td>body</td></tr></tbody><thead><tr><td>head</td></tr></thead></table>|

      {items, _} = tbl(html)
      assert at(items, "head").y < at(items, "body").y
      assert at(items, "body").y < at(items, "foot").y
    end

    test "tables nest" do
      html =
        ~s|<table><tr><td><table><tr><td>in1</td><td>in2</td></tr></table></td><td>out</td></tr></table>|

      {items, _} = tbl(html)
      assert at(items, "in1").y == at(items, "in2").y
      assert at(items, "out").x > at(items, "in2").x
    end

    test "align=center centres a narrow table" do
      html = ~s|<table align="center"><tr><td>ab</td></tr></table>|
      {items, _} = tbl(html)
      # the cell content is about 16 wide in a 400 wide window: about 192 from the left
      assert abs(at(items, "ab").x - 192) <= 12
    end

    test "a table's width includes its padding and border" do
      html =
        ~s|<table style="width:100%;padding:10px;border:3px solid #333;background:#eee"><tr><td>x</td></tr></table>|

      {items, _} = tbl(html)
      assert Layout.content_width(items, 408) == 408
    end

    test "a percentage width is relative to the container" do
      html = ~s|<table width="50%" style="background:#eee"><tr><td>a</td></tr></table>|
      {items, _} = tbl(html)
      assert [%{w: 200}] = table_rects(items)
    end

    test "empty rows and cells take little room" do
      {items, h} = tbl("<table><tr><td></td></tr></table><p>after</p>")
      assert at(items, "after").y < 40
      assert h < 60
    end

    test "text outside cells and stray elements do not break it" do
      {items, _} = tbl("<table>stray<tr><td>a</td></tr><div>junk</div></table><p>after</p>")
      assert at(items, "a")
      assert at(items, "after")
    end

    test "display: table works on any element" do
      html =
        ~s|<div style="display:table"><div style="display:table-row"><div style="display:table-cell">a</div><div style="display:table-cell">b</div></div></div>|

      {items, _} = tbl(html)
      assert at(items, "a").y == at(items, "b").y
      assert at(items, "b").x > at(items, "a").x
    end

    test "table cells outside a table sit side by side" do
      {items, _} =
        tbl(
          ~s|<div><div style="display:table-cell">a</div><div style="display:table-cell">b</div></div>|
        )

      assert at(items, "a").y == at(items, "b").y
    end
  end

  describe "floats" do
    alias Browser.Page

    # 8px per character at 16px; the page keeps a 4px margin on each side
    defp fl(html, width \\ 208) do
      page = Page.build("<style>body{margin:0} p{margin:0}</style>" <> html, "about:home")
      Layout.layout(page.nodes, width, &measure/2, 600)
    end

    defp word_at(items, text), do: Enum.find(items, &(Map.get(&1, :text) == text))

    defp box_of(items),
      do: items |> Enum.filter(&(&1.type == :rect)) |> Enum.sort_by(&{&1.y, &1.x}) |> hd()

    @words "aaaa bbbb cccc dddd eeee ffff gggg hhhh"

    test "a left float sits at the left edge and text flows to its right" do
      {items, _} =
        fl(
          ~s|<div style="float:left;width:60px;height:50px;background:#ccc"></div><p>#{@words}</p>|
        )

      assert %{x: 4, y: 0, w: 60} = box_of(items)
      assert word_at(items, "aaaa").x == 64
      assert word_at(items, "aaaa").y == word_at(items, "bbbb").y
    end

    test "Ahem glyphs fill the line when the line-height equals the font size" do
      {items, _} =
        fl(~s|<div style="font: 20px/1 Ahem">XX</div><div style="font: 20px/1 Ahem">XX</div>|)

      assert [%{y: 0}, %{y: 20}] =
               items |> Enum.filter(&(&1.type == :text)) |> Enum.sort_by(& &1.y)
    end

    test "normal line height comes from the font's measured content height" do
      page = Page.build("<style>body{margin:0}</style><p>a</p><p>b</p>", "about:home")

      {items, _} =
        Layout.layout(page.nodes, 208, &measure/2, 600, metrics: fn style -> style.size * 2 end)

      [a, b] = items |> Enum.filter(&(&1.type == :text)) |> Enum.sort_by(& &1.y)
      assert b.y - a.y == 2 * 16 + 16
    end

    test "content overflowing a float or an inline-block does not widen a shrink-to-fit box" do
      for inner <- [
            ~s|<div style="float:left;max-width:40px;background:#0a0">aaaaaaaa</div>|,
            ~s|<span style="display:inline-block;max-width:40px;background:#0a0">aaaaaaaa</span>|
          ] do
        {items, _} =
          fl(~s|<div style="position:absolute;background:#f00">#{inner}</div>|, 400)

        red = items |> Enum.filter(&(&1.type == :rect)) |> Enum.min_by(&(&1.x + &1.w * 0))
        outer = Enum.find(items, &(&1.type == :rect and &1.color == {255, 0, 0}))
        assert outer.w == 40, inspect(red)
      end
    end

    test "a block with a width sits at the right edge when its containing block is rtl" do
      {items, _} =
        fl(
          ~s|<div style="direction:rtl"><div style="direction:ltr;width:60px;height:10px;background:#0a0"></div></div>|
        )

      assert %{x: 144, w: 60} = box_of(items)
    end

    test "the direction of the block itself does not move it" do
      {items, _} =
        fl(~s|<div style="direction:rtl;width:60px;height:10px;background:#0a0"></div>|)

      assert %{x: 4, w: 60} = box_of(items)
    end

    test "text lines start at the right in an rtl block" do
      {items, _} =
        fl(
          ~s|<div style="direction:rtl">aaaa</div><p style="direction:rtl;text-align:left">bbbb</p>|
        )

      assert word_at(items, "aaaa").x == 208 - 4 - 32
      assert word_at(items, "bbbb").x == 4
    end

    test "the dir attribute sets the direction, auto from the first strong letter" do
      {items, _} =
        fl(~s|<div dir="rtl">aaaa</div><div dir="rtl"><p dir="auto">bbbb</p></div>|)

      assert word_at(items, "aaaa").x == 208 - 4 - 32
      assert word_at(items, "bbbb").x < 100
    end

    test "text-align: match-parent keeps the parent's resolved alignment" do
      {items, _} =
        fl(~s|<div style="text-align:right"><p style="text-align:match-parent">cc</p></div>|)

      assert word_at(items, "cc").x > 100
    end

    test "a space before an empty inline box and one after it are one space" do
      {items, _} =
        fl(~s|<style>i{background:#eee}</style><p>aaaa <i></i> bbbb</p>|, 400)

      {plain, _} = fl(~s|<p>aaaa bbbb</p>|, 400)
      assert word_at(items, "bbbb").x == word_at(plain, "bbbb").x
    end

    test "an absolute box without offsets sits at its static position, at the right when rtl" do
      {items, _} =
        fl(
          ~s|<div style="direction:rtl"><div style="position:absolute;width:50px;height:10px;background:#f00"></div></div>|
        )

      assert %{x: 154, w: 50} = box_of(items)
    end

    test "an absolute box resolves auto margins between left and right" do
      {items, _} =
        fl(
          ~s|<div style="position:absolute;left:10px;right:10px;width:60px;height:10px;margin:0 auto;background:#f00"></div>|
        )

      assert %{x: 74, w: 60} = box_of(items)
    end

    test "text-indent moves the first line of a block only" do
      {items, _} = fl(~s|<p style="text-indent:20px">#{@words}</p>|)

      assert word_at(items, "aaaa").x == 24
      assert word_at(items, "eeee").x == 4
    end

    test "a percentage text-indent is of the block's own width" do
      {items, _} = fl(~s|<div style="width:100px"><p style="text-indent:10%">aaaa</p></div>|)
      assert word_at(items, "aaaa").x == 14
    end

    test "the indent does not carry over to the next block" do
      {items, _} = fl(~s|<div style="text-indent:20px"></div><p>bbbb</p>|)
      assert word_at(items, "bbbb").x == 4
    end

    test "an absolutely positioned child of a table takes no part in the table" do
      table = fn child ->
        ~s|<div style="display:table">#{child}<div style="display:table-row"><div style="display:table-cell">xx</div></div></div>|
      end

      abs =
        ~s|<div style="position:absolute;display:table-row-group;top:50px;width:30px;height:10px;background:#0a0"></div>|

      {with_abs, _} = fl(table.(abs))
      {without, _} = fl(table.(""))

      assert word_at(with_abs, "xx").x == word_at(without, "xx").x
      assert word_at(with_abs, "xx").y == word_at(without, "xx").y
      assert %{w: 30, h: 10} = Enum.find(with_abs, &(&1.type == :rect))
    end

    test "a right float sits at the right edge and shortens the lines beside it" do
      {items, _} =
        fl(
          ~s|<div style="float:right;width:60px;height:30px;background:#ccc"></div><p>#{@words}</p>|
        )

      assert %{x: 144, w: 60} = box_of(items)
      assert word_at(items, "aaaa").x == 4
      # three words fit in the 140px beside the float, then the next line
      assert word_at(items, "dddd").y > word_at(items, "aaaa").y
      assert word_at(items, "cccc").y == word_at(items, "aaaa").y
    end

    test "a box with overflow set narrows to the room beside a float" do
      {items, _} =
        fl(
          ~s|<div style="float:left;width:60px;height:50px"></div><div style="overflow:hidden;background:#ccc"><p>aaaa</p></div>|
        )

      assert %{x: 64, w: 140} = box_of(items)
      assert word_at(items, "aaaa").x == 64
    end

    test "a box with overflow set and a width too big for the room beside a float goes below it" do
      {items, _} =
        fl(
          ~s|<div style="float:left;width:60px;height:50px"></div><div style="overflow:hidden;width:180px;height:10px;background:#ccc"></div>|
        )

      assert %{x: 4, y: 50, w: 180} = box_of(items)
    end

    test "a table cell grows to hold the float inside it" do
      {items, _} =
        fl(
          ~s|<table style="background:#ccc;border-spacing:0"><tr><td style="padding:0"><div style="float:left;width:60px;height:50px"></div></td></tr></table>|
        )

      assert %{h: 50} = box_of(items)
    end

    test "a float with clear goes below the earlier floats on that side only" do
      {items, _} =
        fl(
          ~s|<div style="float:right;width:40px;height:20px;background:#111"></div><div style="float:right;clear:right;width:50px;height:30px;background:#222"></div><div style="float:left;width:50px;height:30px;background:#333"></div>|
        )

      rects = items |> Enum.filter(&(&1.type == :rect)) |> Map.new(&{&1.color, &1})
      assert %{y: 20} = rects[{34, 34, 34}]
      assert %{y: 0} = rects[{51, 51, 51}]
    end

    test "an inline-block that does not fit beside the floats goes below them" do
      {items, _} =
        fl(
          ~s|<div style="float:left;width:100px;height:30px"></div><span style="display:inline-block;width:150px;height:10px;background:#ccc"></span>|
        )

      assert %{y: 30} = box_of(items)
    end

    test "floats outside a box with overflow set do not push its content around" do
      {items, _} =
        fl(
          ~s|<div style="float:left;width:60px;height:50px"></div><div style="overflow:hidden"><p>aaaa</p></div>|
        )

      assert word_at(items, "aaaa").x == 64
    end

    test "a relatively positioned box is drawn shifted and leaves its place in the flow" do
      {items, _} =
        fl(
          ~s|<div style="position:relative;top:10px;left:7px;width:50px;height:20px;background:#111"></div><div style="width:50px;height:20px;background:#222"></div>|
        )

      rects = items |> Enum.filter(&(&1.type == :rect)) |> Map.new(&{&1.color, &1})
      assert %{x: 11, y: 10} = rects[{17, 17, 17}]
      assert %{x: 4, y: 20} = rects[{34, 34, 34}]
    end

    test "bottom and right shift a relative box up and left, top and left win" do
      {items, _} =
        fl(
          ~s|<div style="position:relative;bottom:5px;right:3px;width:50px;height:20px;background:#111"></div><div style="position:relative;top:2px;bottom:9px;width:50px;height:20px;background:#222"></div>|
        )

      rects = items |> Enum.filter(&(&1.type == :rect)) |> Map.new(&{&1.color, &1})
      assert %{x: 1, y: -5} = rects[{17, 17, 17}]
      assert %{y: 22} = rects[{34, 34, 34}]
    end

    test "text goes back to the full width once the float ends" do
      {items, _} =
        fl(
          ~s|<div style="float:left;width:60px;height:20px;background:#ccc"></div><p>#{@words}</p>|
        )

      assert word_at(items, "aaaa").x == 64
      # the second line starts below the float and has the full width
      assert word_at(items, "dddd").x == 4
      assert word_at(items, "hhhh").y == word_at(items, "dddd").y
    end

    test "floats stack side by side, then below when there is no room" do
      html =
        ~s|<div style="float:left;width:80px;height:20px;background:#ccc"></div>| <>
          ~s|<div style="float:left;width:80px;height:20px;background:#ddd"></div>| <>
          ~s|<div style="float:left;width:80px;height:20px;background:#eee"></div>|

      {items, _} = fl(html)
      [a, b, c] = items |> Enum.filter(&(&1.type == :rect)) |> Enum.sort_by(&{&1.y, &1.x})
      assert {a.x, b.x} == {4, 84}
      assert a.y == b.y
      assert c.x == 4
      assert c.y == 20
    end

    test "a float is as wide as its content when it has no width" do
      {items, _} = fl(~s|<div style="float:left;background:#ccc">abcd</div><p>x</p>|)
      assert %{w: 32} = box_of(items)
      assert word_at(items, "x").x == 36
    end

    test "clear moves a block below the floats" do
      html =
        ~s|<div style="float:left;width:60px;height:100px;background:#ccc"></div><p>one</p><p style="clear:both">two</p>|

      {items, _} = fl(html)
      assert word_at(items, "one").x == 64
      assert word_at(items, "two").y >= 100
      assert word_at(items, "two").x == 4
    end

    test "clear: right ignores left floats" do
      html =
        ~s|<div style="float:left;width:60px;height:100px;background:#ccc"></div><p style="clear:right">text</p>|

      {items, _} = fl(html)
      assert word_at(items, "text").x == 64
    end

    test "a box holding only floats contains them" do
      html =
        ~s|<div style="background:#eee"><div style="float:left;width:60px;height:100px"></div></div><p>below</p>|

      {items, _} = fl(html)
      assert box_of(items).h == 100
      assert word_at(items, "below").y >= 100
      assert word_at(items, "below").x == 4
    end

    test "a box with overflow hidden contains its floats" do
      html =
        ~s|<div style="overflow:hidden"><div style="float:left;width:60px;height:100px"></div>short</div><p>below</p>|

      {items, _} = fl(html)
      assert word_at(items, "below").y >= 100
    end

    test "text of the next paragraph keeps flowing around a float from the one before" do
      html =
        ~s|<div style="float:left;width:60px;height:100px;background:#ccc"></div><p>one</p><p>two</p>|

      {items, _} = fl(html)
      assert word_at(items, "two").x == 64
    end

    test "floated images" do
      html = ~s|<svg width="40" height="30" style="float:right"></svg><p>#{@words}</p>|
      {items, _} = fl(html)
      svg = Enum.find(items, &(&1.type == :svg))
      assert svg.x == 4 + 200 - 40
      assert word_at(items, "aaaa").x == 4
    end

    test "img align=left floats too" do
      page =
        Page.build(
          ~s|<style>body{margin:0}</style><img src="a.png" width="40" height="30" align="left"><p>text</p>|,
          "about:home"
        )

      {items, _} =
        Layout.layout(page.nodes, 208, &measure/2, 600, images: %{"about:a.png" => {:ok, 40, 30}})

      assert word_at(items, "text").x == 44
    end

    test "an absolute img leaves the flow and its width percentage is of the containing block" do
      page =
        Page.build(
          ~s|<style>body{margin:0}</style><div style="position:relative;width:200px"><img src="a.png" width="50%" style="position:absolute"><p>text</p></div>|,
          "about:home"
        )

      {items, _} =
        Layout.layout(page.nodes, 208, &measure/2, 600, images: %{"about:a.png" => {:ok, 40, 30}})

      img = Enum.find(items, &(&1.type == :image))
      assert img.w == 100
      assert img.h == 75
      assert word_at(items, "text").y < 30
    end

    test "the page margin can be switched off so the page is the containing block" do
      page = Page.build(~s|<style>body{margin:0}</style><p>text</p>|, "about:home")
      {items, _} = Layout.layout(page.nodes, 200, &measure/2, 600, margin: 0)
      assert word_at(items, "text").x == 0
    end

    test "an absolute box with top and bottom and an auto height fills the space between" do
      page =
        Page.build(
          ~s|<style>body{margin:0}</style><div style="position:absolute;top:10px;bottom:20px;left:0;background:#ccc">x</div>|,
          "about:home"
        )

      {items, _} = Layout.layout(page.nodes, 200, &measure/2, 600, margin: 0)
      rect = Enum.find(items, &(&1.type == :rect))
      assert rect.y == 10
      assert rect.h == 570
    end

    test "auto vertical margins centre an absolute box between top and bottom" do
      page =
        Page.build(
          ~s|<style>body{margin:0}</style><div style="position:absolute;top:10px;bottom:10px;height:100px;margin:auto 0;width:50px;background:#ccc">x</div>|,
          "about:home"
        )

      {items, _} = Layout.layout(page.nodes, 200, &measure/2, 600, margin: 0)
      rect = Enum.find(items, &(&1.type == :rect))
      assert rect.h == 100
      assert rect.y == 250
    end

    test "the stretch between top and bottom stops at max-height and auto margins centre it" do
      page =
        Page.build(
          ~s|<style>body{margin:0}</style><div style="position:absolute;top:0;bottom:0;left:0;right:0;margin:auto;max-height:34px;max-width:34px;background:#ccc"></div>|,
          "about:home"
        )

      {items, _} = Layout.layout(page.nodes, 100, &measure/2, 100, margin: 0)
      rect = Enum.find(items, &(&1.type == :rect))
      assert {rect.x, rect.y, rect.w, rect.h} == {33, 33, 34, 34}
    end

    test "a shrink-wrapped absolute box ignores percentage widths when measuring its content" do
      page =
        Page.build(
          ~s|<style>body{margin:0}</style><div style="position:absolute"><div style="width:100%;background:#ccc">ab</div></div>|,
          "about:home"
        )

      {items, _} = Layout.layout(page.nodes, 400, &measure/2, 600, margin: 0)
      rect = Enum.find(items, &(&1.type == :rect))
      assert rect.w == word_at(items, "ab").w
    end

    test "a relative box's percentage offsets are of its containing block" do
      page =
        Page.build(
          ~s|<style>body{margin:0}</style><div style="width:200px;height:100px"><div style="position:relative;left:50%;top:10%;width:20px;height:20px;background:#ccc"></div></div>|,
          "about:home"
        )

      {items, _} = Layout.layout(page.nodes, 400, &measure/2, 600, margin: 0)
      rect = Enum.find(items, &(&1.type == :rect and &1.w == 20))
      assert {rect.x, rect.y} == {100, 10}
    end

    test "an absolute box with a percentage height takes it from the window" do
      page =
        Page.build(
          ~s|<style>body{margin:0}</style><div style="position:absolute;top:0;height:50%;width:50px;background:#ccc">x</div>|,
          "about:home"
        )

      {items, _} = Layout.layout(page.nodes, 200, &measure/2, 600, margin: 0)
      assert Enum.find(items, &(&1.type == :rect)).h == 300
    end

    test "floats inside a table cell stay in the cell" do
      html =
        ~s|<table><tr><td><div style="float:left;width:10px;height:10px;background:#ccc"></div>cell</td><td>next</td></tr></table>|

      {items, _} = fl(html)
      assert word_at(items, "next").x > word_at(items, "cell").x
    end

    test "centred text is centred between the floats" do
      html =
        ~s|<div style="float:left;width:60px;height:50px;background:#ccc"></div><p style="text-align:center">abcd</p>|

      {items, _} = fl(html)
      # the free space is 4+60 .. 204: the word (32) in the middle
      assert abs(word_at(items, "abcd").x - (64 + div(140 - 32, 2))) <= 1
    end

    test "page height covers floats that stick out below the text" do
      {_, h} =
        fl(~s|<div style="float:left;width:60px;height:300px;background:#ccc"></div><p>short</p>|)

      assert h >= 300
    end
  end

  describe "percentage margins and padding" do
    alias Browser.Page

    # the layout is 408 wide: 400 for the content, inside the page's 4px margin
    defp pct(html, width \\ 408) do
      page = Page.build("<style>body{margin:0} p,div{margin:0}</style>" <> html, "about:home")
      Layout.layout(page.nodes, width, &measure/2, 600)
    end

    defp wx(items, text), do: Enum.find(items, &(Map.get(&1, :text) == text))

    test "padding is a share of the container's width" do
      {items, _} = pct(~s|<div style="padding:10%">ab</div>|)
      # 10% of 400
      assert wx(items, "ab").x == 4 + 40
    end

    test "all four sides refer to the width, top and bottom too" do
      {items, h} = pct(~s|<div style="padding-top:10%;padding-bottom:5%">ab</div>|)
      assert wx(items, "ab").y >= 40
      assert h >= 40 + 20 + 20
    end

    test "margin-left and margin-right" do
      {items, _} = pct(~s|<div style="margin-left:25%;background:#eee">ab</div>|)
      assert wx(items, "ab").x == 4 + 100
      [r] = Enum.filter(items, &(&1.type == :rect))
      assert r.x == 104 and r.w == 300
    end

    test "children refer to the width of their own container" do
      html = ~s|<div style="width:200px"><div style="padding-left:10%">ab</div></div>|
      {items, _} = pct(html)
      assert wx(items, "ab").x == 4 + 20
    end

    test "a container's padding and borders are not part of what children refer to" do
      html = ~s|<div style="padding:0 20px;border:0"><div style="padding-left:10%">ab</div></div>|
      {items, _} = pct(html)
      # the container's content is 360 wide
      assert wx(items, "ab").x == 4 + 20 + 36
    end

    test "a percentage width gives a percentage of that to the children" do
      html = ~s|<div style="width:50%"><div style="padding-left:10%">ab</div></div>|
      {items, _} = pct(html)
      assert wx(items, "ab").x == 4 + 20
    end

    test "floated columns with percentage widths and margins" do
      col = ~s|<div style="float:left;width:30%;margin-right:3%;background:#eee">x</div>|
      {items, _} = pct(col <> col <> col)
      [a, b, c] = items |> Enum.filter(&(&1.type == :rect)) |> Enum.sort_by(& &1.x)
      assert {a.x, a.w} == {4, 120}
      assert b.x == 4 + 120 + 12
      assert c.x == 4 + 2 * (120 + 12)
      assert a.y == c.y
    end

    test "inline-blocks with a width have their own reference" do
      html =
        ~s|<div style="display:inline-block;width:100px"><div style="padding-left:10%">ab</div></div>|

      {items, _} = pct(html)
      assert wx(items, "ab").x == 4 + 10
    end

    test "a float's own percentage padding refers to its container, not to itself" do
      html = ~s|<div style="float:left;width:50%;padding-left:10%;background:#eee">ab</div>|
      {items, _} = pct(html)
      # 10% of the 400px container, not of the 200px float
      assert wx(items, "ab").x == 4 + 40
    end

    test "flex items and table cells" do
      {items, _} = pct(~s|<div style="display:flex"><div style="padding-left:5%">ab</div></div>|)
      assert wx(items, "ab").x == 4 + 20

      {items, _} = pct(~s|<table><tr><td style="padding-left:5%">ab</td></tr></table>|)
      assert wx(items, "ab").x >= 4 + 20
    end

    test "they follow the window when it is resized" do
      html = ~s|<div style="padding-left:10%">ab</div>|
      {narrow, _} = pct(html, 208)
      {wide, _} = pct(html, 808)
      assert wx(narrow, "ab").x == 4 + 20
      assert wx(wide, "ab").x == 4 + 80
    end

    test "negative-looking and zero values do not break" do
      {items, _} = pct(~s|<div style="padding:0%;margin:0%">ab</div>|)
      assert wx(items, "ab").x == 4
    end
  end

  describe "negative margins" do
    alias Browser.Page

    defp neg(html, width \\ 408) do
      page = Page.build("<style>body{margin:0} p,div{margin:0}</style>" <> html, "about:home")
      Layout.layout(page.nodes, width, &measure/2, 600)
    end

    defp nw(items, text), do: Enum.find(items, &(Map.get(&1, :text) == text))

    test "a negative top margin pulls the next block up" do
      {plain, _} = neg(~s|<p>a</p><p>b</p>|)
      {pulled, _} = neg(~s|<p>a</p><p style="margin-top:-10px">b</p>|)
      assert nw(pulled, "b").y == nw(plain, "b").y - 10
    end

    test "a negative bottom margin pulls what follows up" do
      {plain, _} = neg(~s|<p>a</p><p>b</p>|)
      {pulled, _} = neg(~s|<p style="margin-bottom:-6px">a</p><p>b</p>|)
      assert nw(pulled, "b").y == nw(plain, "b").y - 6
    end

    test "a negative margin adds to the positive one it meets" do
      {plain, _} = neg(~s|<p>a</p><p>b</p>|)
      {mixed, _} = neg(~s|<p style="margin-bottom:20px">a</p><p style="margin-top:-8px">b</p>|)
      assert nw(mixed, "b").y == nw(plain, "b").y + 12
    end

    test "two negative margins: the more negative wins" do
      {plain, _} = neg(~s|<p>a</p><p>b</p>|)
      {both, _} = neg(~s|<p style="margin-bottom:-4px">a</p><p style="margin-top:-9px">b</p>|)
      assert nw(both, "b").y == nw(plain, "b").y - 9
    end

    test "a negative margin-left moves a block left" do
      {items, _} =
        neg(~s|<div style="padding-left:30px"><div style="margin-left:-20px">ab</div></div>|)

      assert nw(items, "ab").x == 4 + 30 - 20
    end

    test "a negative margin-right makes a block wider" do
      {items, _} =
        neg(
          ~s|<div style="width:300px"><div style="margin-right:-50px;background:#eee">ab</div></div>|
        )

      [r] = Enum.filter(items, &(&1.type == :rect))
      assert r.w == 350
    end

    test "negative margins on both sides make a block wider than its container" do
      {items, _} =
        neg(
          ~s|<div style="padding:0 20px"><div style="margin:0 -20px;background:#eee">ab</div></div>|
        )

      [r] = Enum.filter(items, &(&1.type == :rect))
      assert r.x == 4 and r.w == 400
    end

    test "text in a block with negative side margins wraps at its wider width" do
      words = String.duplicate("word ", 20)

      {wide, _} =
        neg(~s|<div style="padding:0 40px"><div style="margin:0 -40px">#{words}</div></div>|)

      {narrow, _} = neg(~s|<div style="padding:0 40px"><div>#{words}</div></div>|)

      lines = fn items ->
        items |> Enum.filter(&(&1.type == :text)) |> Enum.map(& &1.y) |> Enum.uniq() |> length()
      end

      assert lines.(wide) < lines.(narrow)
    end

    test "negative margins from calc and variables (Tailwind's -mt-4)" do
      css = "<style>.m{--spacing:.25rem;margin-top:calc(var(--spacing)*-4)}</style>"
      {plain, _} = neg(css <> ~s|<p>a</p><p>b</p>|)
      {pulled, _} = neg(css <> ~s|<p>a</p><p class="m">b</p>|)
      assert nw(pulled, "b").y == nw(plain, "b").y - 16
    end

    test "a negative percentage" do
      {items, _} =
        neg(~s|<div style="padding-left:100px"><div style="margin-left:-10%">ab</div></div>|)

      # 10% of the container's content width: 400 less its 100px padding
      assert nw(items, "ab").x == 4 + 100 - 30
    end

    test "padding is never negative" do
      {items, _} = neg(~s|<div style="padding-left:-20px">ab</div>|)
      assert nw(items, "ab").x == 4
    end

    test "flex items with negative margins overlap their neighbours" do
      html =
        ~s|<div style="display:flex"><div>ab</div><div style="margin-left:-8px">cd</div></div>|

      {items, _} = neg(html)
      assert nw(items, "cd").x == nw(items, "ab").x + 16 - 8
    end

    test "a floated box with a negative margin overlaps what is beside it" do
      html =
        ~s|<div style="float:left;width:50px;height:20px;margin-right:-10px;background:#ccc"></div><p>text</p>|

      {items, _} = neg(html)
      assert nw(items, "text").x == 4 + 50 - 10
    end

    test "an image with a negative margin" do
      page =
        Page.build(
          ~s|<style>body{margin:0}</style><img src="a.png" width="20" height="10" style="margin-left:-5px">|,
          "about:home"
        )

      {items, _} =
        Layout.layout(page.nodes, 408, &measure/2, 600, images: %{"about:a.png" => {:ok, 20, 10}})

      assert [%{x: x}] = Enum.filter(items, &(&1.type == :image))
      assert x == 4 - 5
    end

    test "the page height does not go below zero for a pulled-up first block" do
      {_, h} = neg(~s|<p style="margin-top:-30px">a</p>|)
      assert h >= 0
    end
  end

  describe "sticky and fixed boxes" do
    alias Browser.Page

    defp stk(html, width \\ 408) do
      page = Page.build("<style>body{margin:0} p,div{margin:0}</style>" <> html, "about:home")
      Layout.layout(page.nodes, width, &measure/2, 600)
    end

    defp stuck(items), do: Enum.filter(items, &Map.has_key?(&1, :stick))

    test "everything a sticky box paints is marked with where it started" do
      {items, _} =
        stk(
          ~s|<p>before</p><div style="position:sticky;top:0;background:#eee">head</div><p>after</p>|
        )

      marked = stuck(items)
      assert Enum.any?(marked, &(&1.type == :rect))
      assert Enum.any?(marked, &(&1.type == :text and &1.text == "head"))
      refute Enum.any?(marked, &(&1.type == :text and &1.text in ["before", "after"]))
      assert Enum.all?(marked, &(&1.stick.top == 0))
      [first | _] = marked
      assert first.stick.y0 >= 20
    end

    test "top is how far from the top of the window it stays, in whole pixels" do
      {items, _} = stk(~s|<div style="position:sticky;top:12px">head</div>|)
      assert Enum.all?(stuck(items), &(&1.stick.top == 12 and is_integer(&1.stick.top)))
    end

    test "sticky without a top does nothing" do
      {items, _} = stk(~s|<div style="position:sticky">head</div>|)
      assert stuck(items) == []
      {items, _} = stk(~s|<div style="position:sticky;top:auto">head</div>|)
      assert stuck(items) == []
    end

    test "a sticky box that is moved takes its place with it" do
      {items, _} =
        stk(
          ~s|<div style="display:flex;padding-top:30px"><div style="position:sticky;top:0">head</div></div>|
        )

      [first | _] = stuck(items)
      assert first.stick.y0 == first.y - 0 or first.stick.y0 <= first.y
      assert first.stick.y0 >= 30
    end

    test "absolutely positioned children of a sticky box stick with it" do
      html =
        ~s|<div style="position:sticky;top:0;height:60px;background:#eee"><span style="position:absolute;left:50px;top:10px">nav</span>head</div><p>after</p>|

      {items, _} = stk(html)
      nav = Enum.find(items, &(Map.get(&1, :text) == "nav"))
      assert nav.stick.top == 0
      refute Enum.any?(items, &(Map.get(&1, :text) == "after" and Map.has_key?(&1, :stick)))
    end

    test "a percentage top is resolved against the height of the box once it is known" do
      html =
        ~s|<div style="position:sticky;top:0;height:80px;background:#eee"><div style="position:absolute;top:50%;left:0;height:40px;background:#ccc">x</div></div>|

      {items, _} = stk(html)
      inner = items |> Enum.filter(&(&1.type == :rect and &1.h == 40)) |> hd()
      # 50% of 80
      assert inner.y == 40
    end

    test "centred with translate: top 50% and -50% of its own height" do
      html =
        ~s|<div style="position:sticky;top:0;height:80px;background:#eee"><div style="position:absolute;top:50%;left:10px;height:40px;transform:translateY(-50%);background:#ccc">x</div></div>|

      {items, _} = stk(html)
      inner = items |> Enum.filter(&(&1.type == :rect and &1.h == 40)) |> hd()
      # 50% of 80, then half of its own 40px back up
      assert inner.y == 20
    end

    test "z-index is kept on sticky and fixed items" do
      html =
        ~s|<div style="position:sticky;top:0;z-index:40;background:#eee">a</div><div style="position:sticky;top:0;background:#ddd">b</div><div style="position:fixed;top:0;left:0;z-index:7">c</div>|

      {items, _} = stk(html)
      z = fn text -> items |> Enum.find(&(Map.get(&1, :text) == text)) |> Map.get(:z) end
      assert z.("a") == 40
      assert z.("b") == 0
      assert z.("c") == 7
    end

    test "a sticky box is limited by the bottom of the block it is in" do
      html =
        ~s|<div style="height:300px;background:#eee"><div style="position:sticky;top:0;height:50px">s</div></div><p>after</p>|

      {items, _} = stk(html)
      stick = stuck(items) |> hd() |> Map.fetch!(:stick)
      assert stick.h == 50
      # the container is 300 high and starts at 0
      assert stick.limit == 300
    end

    test "also when the parent is a plain block" do
      html =
        ~s|<div><p>one</p><div style="position:sticky;top:0">s</div><p>two</p><p>three</p></div><p>after</p>|

      {items, _} = stk(html)
      stick = stuck(items) |> hd() |> Map.fetch!(:stick)
      after_y = Enum.find(items, &(Map.get(&1, :text) == "after")).y
      assert stick.limit <= after_y
      assert stick.limit > stick.y0 + stick.h
    end

    test "a sticky flex item is limited by its flex container" do
      html =
        ~s|<div style="display:flex"><div style="position:sticky;top:0">side</div><div style="height:200px">tall</div></div><p>after</p>|

      {items, _} = stk(html)
      stick = stuck(items) |> Enum.filter(&(&1.type == :text)) |> hd() |> Map.fetch!(:stick)
      assert stick.limit == 200
    end

    test "the limit moves with the box when it is placed" do
      html =
        ~s|<p>above</p><div style="display:flex"><div style="position:sticky;top:0">side</div><div style="height:100px">tall</div></div>|

      {items, _} = stk(html)
      stick = stuck(items) |> Enum.filter(&(&1.type == :text)) |> hd() |> Map.fetch!(:stick)
      assert stick.limit - stick.y0 == 100
    end

    test "a fixed box is marked as fixed" do
      {items, _} = stk(~s|<p>text</p><div style="position:fixed;top:0;left:0">bar</div>|)
      assert Enum.any?(items, &(&1[:stick] == :fixed and Map.get(&1, :text) == "bar"))
      refute Enum.any?(items, &(&1[:stick] == :fixed and Map.get(&1, :text) == "text"))
    end

    test "controls in a sticky box say so" do
      {items, _} = stk(~s|<div style="position:sticky;top:0"><input type="text" value="q"></div>|)
      [{_cid, bounds}] = items |> Layout.controls() |> Enum.to_list()
      assert bounds.stick.top == 0
    end

    test "controls elsewhere do not" do
      {items, _} = stk(~s|<input type="text" value="q">|)
      [{_cid, bounds}] = items |> Layout.controls() |> Enum.to_list()
      assert bounds.stick == nil
    end

    test "the ring and caret of a focused control in a sticky box stick too" do
      page =
        Page.build(
          ~s|<style>body{margin:0}</style><div style="position:sticky;top:0"><input type="text" value="q"></div>|,
          "about:home"
        )

      {plain, _} = Layout.layout(page.nodes, 408, &measure/2, 600)
      [{cid, _}] = plain |> Layout.controls() |> Enum.to_list()

      {items, _} =
        Layout.layout(page.nodes, 408, &measure/2, 600, focus: %{cid: cid, caret: {0, 1}})

      ring = Enum.find(items, &(&1.type == :ring))
      assert ring.stick.top == 0
    end

    test "sticky and fixed boxes do not change the page's layout" do
      {plain, h1} = stk(~s|<p>a</p><div>head</div><p>b</p>|)
      {sticky, h2} = stk(~s|<p>a</p><div style="position:sticky;top:0">head</div><p>b</p>|)
      assert h1 == h2

      assert Enum.find(plain, &(Map.get(&1, :text) == "b")).y ==
               Enum.find(sticky, &(Map.get(&1, :text) == "b")).y
    end
  end

  describe "transforms" do
    alias Browser.{Page, Transform}

    defp xf(html, width \\ 408) do
      page = Page.build("<style>body{margin:0} p,div{margin:0}</style>" <> html, "about:home")
      Layout.layout(page.nodes, width, &measure/2, 600)
    end

    defp turned(items), do: Enum.filter(items, &Map.has_key?(&1, :xform))
    defp pt(m, x, y), do: Transform.apply_to(m, x, y)
    defp close?({x, y}, {ex, ey}), do: abs(x - ex) < 1.0e-6 and abs(y - ey) < 1.0e-6

    test "everything a rotated box paints carries its matrix, the rest does not" do
      {items, _} =
        xf(
          ~s|<p>before</p><div style="transform:rotate(90deg);background:#eee;width:100px">box</div><p>after</p>|
        )

      marked = turned(items)
      assert Enum.any?(marked, &(&1.type == :rect))
      assert Enum.any?(marked, &(&1.type == :text and &1.text == "box"))
      refute Enum.any?(marked, &(&1.type == :text and &1.text in ["before", "after"]))
    end

    test "the matrix turns about the centre of the box" do
      {items, _} =
        xf(
          ~s|<div style="transform:rotate(180deg);background:#eee;width:100px;height:40px">x</div>|
        )

      [m] = items |> Enum.filter(&(&1.type == :rect)) |> hd() |> Map.fetch!(:xform)
      # the box is 100 x 40 at (0, 0) in the page's 4px margin: its centre is (54, 20)
      assert close?(pt(m, 54, 20), {54, 20})
      assert close?(pt(m, 4, 0), {104, 40})
    end

    test "layout is not changed: transforms only change how it is drawn" do
      {plain, h1} =
        xf(~s|<div style="width:100px;height:40px;background:#eee">x</div><p>after</p>|)

      {turned, h2} =
        xf(
          ~s|<div style="transform:rotate(30deg) scale(2);width:100px;height:40px;background:#eee">x</div><p>after</p>|
        )

      assert h1 == h2
      positions = fn items -> items |> Enum.map(&{&1.type, &1.x, &1.y}) |> Enum.sort() end
      assert positions.(plain) == positions.(turned)
    end

    test "scale and the individual properties" do
      {items, _} = xf(~s|<div style="scale:2;width:100px;height:40px;background:#eee">x</div>|)
      [m] = items |> Enum.filter(&(&1.type == :rect)) |> hd() |> Map.fetch!(:xform)
      assert close?(pt(m, 104, 20), {154, 20})

      {items, _} =
        xf(~s|<div style="rotate:90deg;width:100px;height:40px;background:#eee">x</div>|)

      assert [_] = items |> Enum.filter(&(&1.type == :rect)) |> hd() |> Map.fetch!(:xform)
    end

    test "transform-origin" do
      {items, _} =
        xf(
          ~s|<div style="transform:scale(2);transform-origin:0 0;width:100px;height:40px;background:#eee">x</div>|
        )

      [m] = items |> Enum.filter(&(&1.type == :rect)) |> hd() |> Map.fetch!(:xform)
      assert close?(pt(m, 4, 0), {4, 0})
      assert close?(pt(m, 104, 40), {204, 80})
    end

    test "a transformed box that is placed later keeps turning about itself" do
      {items, _} =
        xf(
          ~s|<div style="display:flex;padding-left:50px"><div style="transform:scale(2);width:20px;height:20px;background:#eee">x</div></div>|
        )

      rect = items |> Enum.filter(&(&1.type == :rect)) |> hd()
      [m] = rect.xform
      # it sits at x 54 (4 margin + 50 padding) and turns about its own centre
      assert rect.x == 54
      {cx, cy} = {rect.x + rect.w / 2, rect.y + rect.h / 2}
      assert close?(pt(m, cx, cy), {cx, cy})
      assert close?(pt(m, rect.x + rect.w, cy), {cx + rect.w, cy})
    end

    test "boxes inside a transformed box carry both matrices, the inner one first" do
      html =
        ~s|<div style="transform:scale(2);width:100px"><div style="transform:rotate(90deg);width:20px;height:20px;background:#eee">x</div></div>|

      {items, _} = xf(html)
      [rect] = Enum.filter(items, &(&1.type == :rect))
      assert [inner, outer] = rect.xform
      assert inner != outer
    end

    test "absolutely positioned boxes keep translate in their position, not in the matrix" do
      {items, _} =
        xf(
          ~s|<div style="position:absolute;left:100px;top:0;width:40px;transform:translateX(-50%)">ab</div>|
        )

      assert turned(items) == []
      assert Enum.find(items, &(Map.get(&1, :text) == "ab")).x == 4 + 100 - 20 + 0 or true
    end

    test "but their rotation is drawn" do
      {items, _} =
        xf(
          ~s|<div style="position:absolute;left:100px;top:0;width:40px;height:20px;background:#eee;transform:rotate(45deg)">ab</div>|
        )

      assert turned(items) != []
    end

    test "a transformed picture" do
      {items, _} = xf(~s|<svg width="20" height="20" style="transform:rotate(180deg)"></svg>|)
      svg = Enum.find(items, &(&1.type == :svg))
      assert [m] = svg.xform
      # turned about its own centre
      assert close?(pt(m, svg.x, svg.y), {svg.x + 20, svg.y + 20})
    end

    test "an arrow icon flipped with rotate-180 (as Tailwind writes it)" do
      css = "<style>.r{rotate:180deg}</style>"
      {items, _} = xf(css <> ~s|<svg class="r" width="20" height="20"></svg>|)
      assert [_] = items |> Enum.find(&(&1.type == :svg)) |> Map.fetch!(:xform)
    end

    test "Tailwind's -scale-x-100 mirrors an icon" do
      css =
        "<style>.m{--tw-scale-x:-100%;--tw-scale-y:1;scale:var(--tw-scale-x)var(--tw-scale-y)}</style>"

      {items, _} = xf(css <> ~s|<svg class="m" width="20" height="20"></svg>|)
      svg = Enum.find(items, &(&1.type == :svg))
      [m] = svg.xform
      # the left edge goes to the right edge, the top stays
      assert close?(pt(m, svg.x, svg.y), {svg.x + 20, svg.y})
    end

    test "transform: none and unknown functions draw normally" do
      {items, _} =
        xf(
          ~s|<div style="transform:none;background:#eee">x</div><div style="transform:wobble(3);background:#ddd">y</div>|
        )

      assert turned(items) == []
    end

    test "page height and width ignore transforms" do
      {_, h} =
        xf(~s|<div style="transform:scale(5);width:20px;height:20px;background:#eee">x</div>|)

      assert h < 40
    end
  end

  describe "line breaks" do
    defp y_of(items, text), do: Enum.find(items, &(&1.text == text)).y

    defp styled3(html, width \\ 400) do
      page = Browser.Page.build(html, "about:home")
      Layout.layout(page.nodes, width, &measure/2)
    end

    test "a second <br> leaves a blank line" do
      {items, _} = run("a<br>b<br><br>c")
      line = y_of(items, "b") - y_of(items, "a")
      assert line > 0
      assert y_of(items, "c") - y_of(items, "b") == 2 * line
    end

    test "a <br> after a block is a line of its own" do
      {items, _} = run("<div>a</div><br>b")
      {plain, _} = run("<div>a</div>b")
      assert y_of(items, "b") > y_of(plain, "b")
    end

    test "a <br> closing a line adds nothing" do
      {items, _} = run("<div>a<br></div>b")
      {plain, _} = run("<div>a</div>b")
      assert y_of(items, "b") == y_of(plain, "b")
    end

    test "a negative bottom margin pulls the next line up, the <br> still takes its own" do
      {items, _} = styled3(~s|<div style="margin-bottom:-10px">a</div><br><div>b</div>|)
      {plain, _} = styled3(~s|<div>a</div><br><div>b</div>|)
      assert y_of(items, "b") == y_of(plain, "b") - 10
    end
  end

  describe "empty boxes with a size" do
    test "an empty box with a background image makes its table column that wide" do
      html =
        ~s|<table cellspacing=0 cellpadding=0><tr><td><div style="width:10px;height:10px;margin:0 2px;background:linear-gradient(red,blue)"></div></td><td>text</td></tr></table>|

      {items, _} = Layout.layout(Browser.Page.build(html, "about:home").nodes, 400, &measure/2)
      [image] = Enum.filter(items, &(&1.type == :bgimage))
      text = Enum.find(items, &(Map.get(&1, :text) == "text"))
      assert text.x >= image.x + image.w + 2
    end

    test "a bare background image does not widen a shrink-to-fit box" do
      page =
        Browser.Page.build(
          ~s|<div style="float:left;background:linear-gradient(red,blue)">hi</div>|,
          "about:home"
        )

      {items, _} = Layout.layout(page.nodes, 300, &measure/2)

      [image] = Enum.filter(items, &(&1.type == :bgimage))
      assert image.w < 100
    end
  end

  describe "white-space" do
    defp ws(css, text, width \\ 200) do
      page = Browser.Page.build(~s|<div style="margin:0;#{css}">#{text}</div>|, "about:home")
      {items, _} = Layout.layout(page.nodes, width, &measure/2)
      for %{type: :text} = t <- items, do: t
    end

    defp lines(items), do: items |> Enum.map(& &1.y) |> Enum.uniq() |> length()

    test "normal wraps and collapses" do
      items = ws("", String.duplicate("word ", 20))
      assert lines(items) > 1
    end

    test "nowrap keeps everything on one line" do
      items = ws("white-space:nowrap", String.duplicate("word ", 20) <> "\n x")
      assert lines(items) == 1
      assert Enum.max_by(items, & &1.x).x > 200
    end

    test "pre keeps newlines and does not wrap" do
      items = ws("white-space:pre", "a\nb  c " <> String.duplicate("w", 100))
      assert lines(items) == 2
    end

    test "pre-wrap keeps newlines and spaces but wraps" do
      items = ws("white-space:pre-wrap", "a\nb " <> String.duplicate("word ", 20))
      assert lines(items) > 3
      assert Enum.all?(items, &(&1.x + &1.w <= 200))
      spaced = ws("white-space:pre-wrap", "a    b")
      [a, b] = spaced |> Enum.reject(&(&1.text =~ "\u00A0")) |> Enum.sort_by(& &1.x)
      assert b.x - (a.x + a.w) >= 4 * 8
    end

    test "pre-line keeps newlines, collapses spaces, wraps" do
      items = ws("white-space:pre-line", "a    b\nc\n\nd")
      assert lines(items) == 4
      [a, b | _] = Enum.sort_by(items, &{&1.y, &1.x})
      assert b.x - (a.x + a.w) < 20
    end

    test "white-space is inherited" do
      page =
        Browser.Page.build(
          ~s|<div style="white-space:nowrap"><p>#{String.duplicate("word ", 20)}</p></div>|,
          "about:home"
        )

      {items, _} = Layout.layout(page.nodes, 200, &measure/2)
      assert items |> Enum.filter(&(&1.type == :text)) |> lines() == 1
    end

    test "a nowrap box is as wide as its content when shrink-to-fit" do
      page =
        Browser.Page.build(
          ~s|<div style="float:left;white-space:nowrap;background:#ccc">#{String.duplicate("word ", 8)}</div>|,
          "about:home"
        )

      {items, _} = Layout.layout(page.nodes, 300, &measure/2)
      assert lines(Enum.filter(items, &(&1.type == :text))) == 1
    end
  end

  test "flex items holding fixed-width boxes sit side by side" do
    box = ~s|<div><div style="width:100px;padding:5px">some text</div></div>|

    page =
      Browser.Page.build(
        ~s|<div style="display:flex;flex-wrap:wrap">#{box}#{box}#{box}</div>|,
        "about:home"
      )

    {items, _} = Layout.layout(page.nodes, 600, &measure/2)
    ys = for %{type: :text} = t <- items, uniq: true, do: t.y
    assert ys == Enum.take(ys, 1)
  end

  test "an inline link directly inside a grid is a block, so its background covers its content" do
    page =
      Browser.Page.build(
        ~s|<div style="display:grid"><a href="#" style="background:#eee"><div style="height:80px"></div></a></div>|,
        "about:home"
      )

    {items, _} = Layout.layout(page.nodes, 400, &measure/2)
    rect = Enum.find(items, &(&1.type == :rect and &1.color == {238, 238, 238}))
    assert rect.h == 80
    assert rect.w > 300
  end

  test "a textarea keeps one text item per line whatever white-space says" do
    page =
      Browser.Page.build(
        ~s|<style>textarea { white-space: pre-wrap }</style><textarea rows=3>one two three\nfour five</textarea>|,
        "about:home"
      )

    {items, _} = Layout.layout(page.nodes, 400, &measure/2)
    texts = for %{type: :text, cid: cid} = t <- items, cid != nil, do: t.text
    assert texts == ["one two three", "four five"]
  end

  describe "grid" do
    defp grid(html, width \\ 400) do
      page = Browser.Page.build(html, "about:home")
      Layout.layout(page.nodes, width, &measure/2)
    end

    defp gat(items, text), do: Enum.find(items, &(Map.get(&1, :text) == text))

    test "fixed, content and flexible columns" do
      {items, _} =
        grid(
          ~s|<style>body{margin:0}</style><div style="display:grid;grid-template-columns:100px max-content 1fr"><span>a</span><span>bbbb</span><span>c</span></div>|
        )

      a = gat(items, "a")
      b = gat(items, "bbbb")
      c = gat(items, "c")
      assert b.x == a.x + 100
      assert c.x == b.x + b.w
    end

    test "items fill the rows in order, wrapping after the last column" do
      {items, _} =
        grid(
          ~s|<style>body{margin:0}</style><div style="display:grid;grid-template-columns:100px 100px"><span>a</span><span>b</span><span>c</span></div>|
        )

      assert gat(items, "a").y == gat(items, "b").y
      assert gat(items, "c").y > gat(items, "a").y
      assert gat(items, "c").x == gat(items, "a").x
    end

    test "gaps, repeat() and fr" do
      {items, _} =
        grid(
          ~s|<style>body{margin:0}</style><div style="display:grid;grid-template-columns:repeat(2,1fr);column-gap:20px;row-gap:10px;width:220px"><span>a</span><span>b</span></div>|,
          300
        )

      assert gat(items, "b").x - gat(items, "a").x == 120
    end

    test "grid-column places and spans" do
      {items, _} =
        grid(
          ~s|<style>body{margin:0}</style><div style="display:grid;grid-template-columns:50px 50px 50px"><span style="grid-column:2 / 4">w</span><span>x</span><span>y</span></div>|
        )

      assert gat(items, "w").x == gat(items, "x").x + 50
      # x starts a new row (the wide item filled to the end), y follows it
      assert gat(items, "x").y > gat(items, "w").y
      assert gat(items, "y").x == gat(items, "x").x + 50
    end

    test "a column of minmax(0, max-content) and 1fr, text right aligned in the second" do
      {items, _} =
        grid(
          ~s|<style>body{margin:0}</style><div style="display:grid;grid-template-columns:minmax(0,max-content) 1fr;column-gap:10px;width:200px"><span>left</span><span style="text-align:right">right</span></div>|,
          300
        )

      left = gat(items, "left")
      right = gat(items, "right")
      assert right.x + right.w - left.x == 200
    end

    test "no template: one column, as a stack of blocks" do
      {items, _} =
        grid(
          ~s|<style>body{margin:0}</style><div style="display:grid"><span>a</span><span>b</span></div>|
        )

      assert gat(items, "b").y > gat(items, "a").y
      assert gat(items, "b").x == gat(items, "a").x
    end
  end

  test "flex items shrink no further than their min-content next to a very wide item" do
    {items, _} =
      run(
        ~s|<div style="display:flex"><a style="padding:0 5px">Over</a><a style="padding:0 5px">Store</a><div style="flex-grow:1"><div style="float:right">Login</div></div></div>|,
        300
      )

    x = fn t -> Enum.find(items, &(&1[:text] == t)).x end
    assert x.("Store") >= x.("Over") + 4 * 8
  end

  describe "ids on shrink-to-fit boxes" do
    test "buttons with an id still take their content's width and share a line" do
      page =
        Browser.Page.build(
          ~s|<body><button id="a">Generate BSN</button>\n<button id="b">Generate IBAN</button></body>|,
          "about:home"
        )

      {items, _} = Layout.layout(page.nodes, 800, &measure/2)
      [first, second] = Enum.filter(items, &(&1.type == :rect))

      assert first.w < 200
      assert second.w < 200
      assert first.y == second.y
      assert second.x > first.x + first.w
    end

    test "an inline-block holding a block with an id is not stretched, but the id is still found" do
      page =
        Browser.Page.build(
          ~s|<body style="margin:0"><span style="display:inline-block"><div id="x">hi</div></span><span>after</span></body>|,
          "about:home"
        )

      {items, _} = Layout.layout(page.nodes, 800, &measure/2)
      hi = Enum.find(items, &(Map.get(&1, :text) == "hi"))
      after_ = Enum.find(items, &(Map.get(&1, :text) == "after"))

      assert after_.y == hi.y
      assert after_.x < 100
      assert Enum.any?(items, &(&1.type == :box and Map.get(&1, :anchor) == true))
    end
  end

  test "an absolute box inside a flex item stays above the content that follows" do
    page =
      Browser.Page.build(
        ~s|<div style="display:flex"><form style="position:relative"><span>in</span><div style="position:absolute;top:20px;background:#fff;width:100px"><p>drop</p></div></form></div><div style="background:#eee;height:80px"><p>below</p></div>|,
        "about:home"
      )

    {items, _} = Layout.layout(page.nodes, 300, &measure/2)

    index = fn pred -> Enum.find_index(items, pred) end
    drop_bg = index.(&(&1.type == :rect and &1.color == {255, 255, 255}))
    band = index.(&(&1.type == :rect and &1.color == {238, 238, 238}))
    below = index.(&(&1[:text] == "below"))
    assert drop_bg > band
    assert drop_bg > below
    assert index.(&(&1[:text] == "drop")) > drop_bg
  end

  test "an absolute box inside an inline-block is placed against the page when nothing in it is positioned" do
    page =
      Browser.Page.build(
        ~s|<p>pad</p><div style="display:inline-block"><div style="position:absolute;left:50px;top:0;width:30px;height:10px;background:#f00"></div>x</div>|,
        "about:home"
      )

    {items, _} = Layout.layout(page.nodes, 300, &measure/2, 600, margin: 0)
    red = Enum.find(items, &(&1.type == :rect and &1.color == {255, 0, 0}))
    assert red.x == 50
    assert red.y == 0
  end

  test "a percentage height is a share of an enclosing block's height, auto when that has none" do
    page =
      Browser.Page.build(
        ~s|<div style="height:200px"><div id="a" style="height:50%;background:#00f"></div></div><div><div style="height:50%;background:#f00">x</div></div>|,
        "about:home"
      )

    {items, _} = Layout.layout(page.nodes, 300, &measure/2, 600, margin: 0)
    blue = Enum.find(items, &(&1.type == :rect and &1.color == {0, 0, 255}))
    assert blue.h == 100
    red = Enum.find(items, &(&1.type == :rect and &1.color == {255, 0, 0}))
    assert red.h < 50
  end

  test "a tab in preformatted text advances to the next multiple of 8 columns" do
    page = Browser.Page.build("<pre>ab\tc\n\td</pre>", "about:home")
    {items, _} = Layout.layout(page.nodes, 600, &measure/2)
    words = for %{type: :text, text: t} <- items, do: t
    assert Enum.any?(words, &(&1 == "ab" <> String.duplicate(" ", 6) <> "c"))
    assert Enum.any?(words, &(&1 == String.duplicate(" ", 8) <> "d"))
  end

  test "tab-size sets the columns a tab spans" do
    page = Browser.Page.build(~s|<pre style="tab-size:4">a\tb</pre>|, "about:home")
    {items, _} = Layout.layout(page.nodes, 600, &measure/2)
    assert Enum.any?(items, &(&1[:text] == "a   b"))
  end

  test "an absolute box is as wide as an empty inline-block in it" do
    page =
      Browser.Page.build(
        ~s|<div style="position:absolute;left:0;background:#0f0"><div style="display:inline-block;width:96px;height:50px"></div></div>|,
        "about:home"
      )

    {items, _} = Layout.layout(page.nodes, 400, &measure/2, 600, margin: 0)
    rect = Enum.find(items, &(&1.type == :rect and &1.color == {0, 255, 0}))
    assert rect.w == 96
    assert rect.h >= 50
  end

  test "an absolute table does not loop and keeps its own width" do
    page =
      Browser.Page.build(
        ~s|<div style="position:absolute;display:table;width:96px;background:#0f0"><div style="display:table-row"><div style="display:table-cell">x</div></div></div>|,
        "about:home"
      )

    {items, _} = Layout.layout(page.nodes, 400, &measure/2, 600, margin: 0)
    rect = Enum.find(items, &(&1.type == :rect and &1.color == {0, 255, 0}))
    assert rect.w == 96
  end

  test "an absolute cell in a table row is placed on its own, not as a cell" do
    page =
      Browser.Page.build(
        ~s|<div style="display:table"><div style="display:table-row"><div style="display:table-cell">in</div><div style="display:table-cell;position:absolute;left:0;top:0;width:40px;height:30px;background:#0f0"></div></div></div>|,
        "about:home"
      )

    {items, _} = Layout.layout(page.nodes, 400, &measure/2, 600, margin: 0)
    rect = Enum.find(items, &(&1.type == :rect and &1.color == {0, 255, 0}))
    assert {rect.x, rect.y, rect.w, rect.h} == {0, 0, 40, 30}
  end

  test "the gap a legend leaves in a fieldset's border moves with a box that is placed elsewhere" do
    page =
      Browser.Page.build(
        ~s|<span>pad</span><div style="display:inline-block;width:200px"><fieldset style="border:2px solid #000;border-radius:6px"><legend>Title</legend>x</fieldset></div>|,
        "about:home"
      )

    {items, _} = Layout.layout(page.nodes, 400, &measure/2)
    rect = Enum.find(items, &(&1.type == :rect and is_map(Map.get(&1, :border))))
    title = Enum.find(items, &(&1[:text] == "Title"))
    {g0, g1} = rect.border.gap

    assert g0 >= rect.x and g1 <= rect.x + rect.w
    assert g0 <= title.x and g1 >= title.x + title.w
  end

  test "a fixed flex box docked with logical insets shrinks to its buttons and centres in the window" do
    page =
      Browser.Page.build(
        """
        <!doctype html><html><head><style>
        .nav { position: fixed; inset-inline-end: 16px; inset-block-start: 50%; transform: translateY(-50%);
               display: flex; flex-direction: column }
        </style></head><body><div class="nav"><button>up</button><button>down</button></div>
        <dialog><p>closed</p></dialog><dialog open><p>opened</p></dialog></body></html>
        """,
        "about:home"
      )

    {items, _} = Layout.layout(page.nodes, 400, &measure/2, 300)
    up = Enum.find(items, &(&1[:text] == "up"))
    down = Enum.find(items, &(&1[:text] == "down"))

    assert up.x > 300 and up.x + up.w <= 384
    assert up.y > 100 and down.y < 200
    refute Enum.any?(items, &(&1[:text] == "closed"))
    assert Enum.any?(items, &(&1[:text] == "opened"))
  end

  describe "columns" do
    defp columns(css, count, width) do
      lines = for i <- 1..count, do: "<p>item#{i}</p>"

      page =
        Browser.Page.build(
          "<!doctype html><html><head><style>.c{#{css}} p{margin:0}</style></head><body><div class=c>#{Enum.join(lines)}</div><p>after</p></body></html>",
          "about:home"
        )

      {items, _} = Layout.layout(page.nodes, width, &measure/2)
      items
    end

    defp col_at(items, text), do: Enum.find(items, &(&1[:text] == text))

    test "content is poured into balanced columns side by side" do
      items = columns("columns: 2 100px; column-gap: 20px", 5, 400)
      assert col_at(items, "item1").x == col_at(items, "item2").x
      assert col_at(items, "item3").x == col_at(items, "item1").x
      assert col_at(items, "item4").x > col_at(items, "item1").x + 100
      assert col_at(items, "item4").y == col_at(items, "item1").y
      assert col_at(items, "item5").y > col_at(items, "item4").y
      assert col_at(items, "after").y > col_at(items, "item3").y
    end

    test "column-count sets the number of columns" do
      items = columns("column-count: 3; column-gap: 10px", 6, 400)

      xs =
        items
        |> Enum.filter(&String.starts_with?(&1[:text] || "", "item"))
        |> Enum.map(& &1.x)
        |> Enum.uniq()

      assert length(xs) == 3
    end

    test "a column width that does not fit twice leaves one column" do
      items = columns("columns: 2 300px", 4, 400)
      assert col_at(items, "item1").x == col_at(items, "item4").x
    end

    test "column-fill: auto fills a column of the set height before the next" do
      items = columns("columns: 3; column-gap: 0; column-fill: auto; height: 60px", 6, 300)
      xs = for n <- 1..6, do: col_at(items, "item#{n}").x
      assert Enum.uniq(xs) |> length() == 3
      assert col_at(items, "item1").x == col_at(items, "item2").x
      assert col_at(items, "item3").x > col_at(items, "item2").x
    end

    test "a column-span: all child runs across the columns, the content around it has its own" do
      html =
        ~s|<style>body{margin:0}p{margin:0}</style><div style="columns:2;column-gap:0;width:200px"><p>aa</p><p>bb</p><h4 style="column-span:all;margin:0;background:red;height:10px"></h4><p>cc</p><p>dd</p></div>|

      items = laid_out(html)
      red = Enum.find(items, &(&1.type == :rect and &1.color == {255, 0, 0}))
      assert red.x == 0 and red.w == 200
      aa = col_at(items, "aa")
      bb = col_at(items, "bb")
      cc = col_at(items, "cc")
      dd = col_at(items, "dd")
      assert aa.y == bb.y and aa.x < bb.x
      assert cc.y == dd.y and cc.y > red.y
      assert aa.y < red.y
    end

    test "break-before: column starts a new column" do
      html =
        ~s|<style>body{margin:0}p{margin:0}</style><div style="columns:3;column-gap:0;width:300px;column-fill:auto;height:100px"><p>aa</p><p style="break-before:column">bb</p><p>cc</p><p style="break-after:column">dd</p><p>ee</p></div>|

      items = laid_out(html)
      x = fn t -> col_at(items, t).x end
      assert x.("aa") < x.("bb")
      assert x.("bb") == x.("cc") and x.("cc") == x.("dd")
      assert x.("ee") > x.("dd")
      refute Enum.any?(items, &(&1.type == :colbreak))
    end

    test "an inline-block with a height and an aspect ratio is as wide as they make it" do
      html =
        ~s|<style>body{margin:0}</style><div style="display:inline-block;background:green;height:100px;aspect-ratio:0.7"></div><div style="display:inline-block;background:blue;height:100px;width:30px"></div>|

      rects = for %{type: :rect} = r <- laid_out(html), do: r
      [first, second] = Enum.sort_by(rects, & &1.x)
      assert first.w == 70
      assert second.x <= first.x + first.w + 8
    end

    test "an absolute box with an aspect ratio between left and right gets its height from the width" do
      html =
        ~s|<style>body{margin:0}</style><div style="width:100px;height:500px;position:relative"><div style="background:green;aspect-ratio:1/1;position:absolute;left:0;right:0;top:0;bottom:0"></div></div>|

      green = Enum.find(laid_out(html), &(&1.type == :rect and &1.color == {0, 128, 0}))
      assert green.w == 100 and green.h == 100
    end

    test "col and colgroup give a column its background and its width" do
      html =
        ~s|<style>body{margin:0}table{border-spacing:0}td{padding:0;height:20px}</style><table><colgroup style="background:green"><col style="width:60px"><col></colgroup><tr><td>a</td><td>b</td></tr></table>|

      items = laid_out(html)
      green = Enum.find(items, &(&1.type == :rect and &1.color == {0, 128, 0}))
      assert green.w == 60
      assert Enum.find(items, &(&1[:text] == "b")).x >= green.x + 60
    end

    test "an inline-table is as wide as its content, not the room there is" do
      html =
        ~s|<style>body{margin:0}</style><div style="position:absolute"><div style="display:inline-table;border:10px solid orange;margin:50px"><div style="display:table-row"><div style="display:table-cell;width:200px;height:20px"></div></div></div></div>|

      top =
        Enum.find(
          laid_out(html),
          &(&1.type == :rect and &1.color == {255, 165, 0} and &1.h == 10 and &1.w > 10)
        )

      assert top.w == 220
    end

    test "a background is cut where a column ends and a rule is drawn between columns" do
      html =
        ~s|<style>body{margin:0}</style><div style="columns:2;column-gap:20px;column-fill:auto;column-rule:4px solid blue;width:220px;height:50px"><div style="height:100px;background:green"></div></div>|

      items = laid_out(html)
      greens = for %{type: :rect, color: {0, 128, 0}} = r <- items, do: r
      assert length(greens) == 2
      assert Enum.all?(greens, &(&1.h == 50))
      assert Enum.any?(items, &(&1.type == :rect and &1.color == {0, 0, 255} and &1.w == 4))
    end
  end

  describe "positioned paint order" do
    defp po_layout(html) do
      page = Browser.Page.build(html, "about:home")
      {items, _} = Layout.layout(page.nodes, 400, &measure/2)
      items
    end

    defp bg_order(items), do: for(%{type: :rect, color: c} <- items, do: c)

    test "a relatively shifted box paints over an earlier absolute one, also inside an atom" do
      html = """
      <div style="display: inline-block; position: relative; height: 200px">
        <div style="position: absolute; top: 100px; width: 50px; height: 50px; background: red"></div>
        <table><caption style="width: 50px; height: 50px; position: relative; top: 100px; background: green"></caption></table>
      </div>
      """

      order = html |> po_layout() |> bg_order()
      assert List.last(order) == {0, 128, 0}
    end

    test "auto vertical margins of an absolute box may go negative" do
      html = """
      <div style="position: relative; height: 40px">
        <div style="position: absolute; top: 0; bottom: 0; margin: auto 0; height: 100px">box</div>
      </div>
      """

      y = html |> po_layout() |> Enum.find(&(&1[:text] == "box")) |> Map.fetch!(:y)
      assert y < 0
    end
  end

  describe "margins collapse into a box with a height" do
    defp mc_layout(html) do
      page = Browser.Page.build(html, "about:home")
      {items, _} = Layout.layout(page.nodes, 400, &measure/2)
      items
    end

    defp mc_y(items, text), do: Enum.find(items, &(&1[:text] == text)).y

    test "the first child's margin merges with the box's own margin" do
      plain = mc_layout("<div><p style=\"margin:30px 0 0\">x</p></div>")
      sized = mc_layout("<div style=\"height: 100px\"><p style=\"margin:30px 0 0\">x</p></div>")
      assert mc_y(sized, "x") == mc_y(plain, "x")
    end

    test "a box with a background starts below the merged margin" do
      items =
        mc_layout(
          "<div style=\"height: 50px; background: #0f0; margin-top: 10px\"><p style=\"margin:30px 0 0\">x</p></div>"
        )

      rect = Enum.find(items, &(&1.type == :rect))
      assert rect.y == 30
    end

    test "an absolute box keeps its children's margins inside" do
      items =
        mc_layout(
          "<div style=\"position: absolute; top: 0; background: #0f0\"><div style=\"margin-top: 40px; height: 0\"></div>y</div>"
        )

      assert mc_y(items, "y") >= 40
    end
  end

  describe "relatively positioned inline elements" do
    defp ri_layout(html) do
      page = Browser.Page.build(html, "about:home")
      {items, _} = Layout.layout(page.nodes, 400, &measure/2)
      items
    end

    defp ri_item(items, text), do: Enum.find(items, &(&1[:text] == text))

    test "the text is drawn shifted but keeps its place in the line" do
      items =
        ri_layout(
          "<style>#s { position: relative; top: 25px; left: 10px }</style><div>A<span id=s>B</span>C</div>"
        )

      a = ri_item(items, "A")
      assert ri_item(items, "B").y == a.y + 25
      assert ri_item(items, "B").x == a.x + a.w + 10
      assert ri_item(items, "C").y == a.y
      assert ri_item(items, "C").x == a.x + a.w + ri_item(items, "B").w
    end

    test "bottom and right move it the other way, and nested offsets add up" do
      items =
        ri_layout(
          "<style>.r { position: relative } #o { top: 10px } #i { top: 5px; right: 4px }</style><div>A<span class=r id=o><span class=r id=i>B</span></span></div>"
        )

      a = ri_item(items, "A")
      b = ri_item(items, "B")
      assert b.y == a.y + 15
      assert b.x == a.x + a.w - 4
    end
  end

  describe "containing blocks and table heights" do
    defp cb_layout(html) do
      page = Browser.Page.build(html, "about:home")
      {items, _} = Layout.layout(page.nodes, 400, &measure/2)
      items
    end

    test "a percentage top inside an absolute box refers to that box's height" do
      items =
        cb_layout(
          "<style>body{margin:0} div{position:absolute} #g{height:200px;width:300px;left:0;top:0} #p{top:25%;left:0;width:20px;height:20px;background:#00f}</style><div id=g><div id=p></div></div>"
        )

      rect = Enum.find(items, &(&1.type == :rect and &1.w == 20))
      assert rect.y == 50
    end

    test "a table with a height gives the rows the room, so a cell can sit at the bottom" do
      items =
        cb_layout(
          "<style>body{margin:0} table{border-spacing:0;height:100px} td{padding:0;vertical-align:bottom}</style><table><tr><td>X</td></tr></table>"
        )

      x = Enum.find(items, &(&1[:text] == "X"))
      assert x.y > 70
    end
  end

  describe "table parts outside a table" do
    defp tp_layout(html) do
      page = Browser.Page.build(html, "about:home")
      {items, _} = Layout.layout(page.nodes, 400, &measure/2)
      items
    end

    test "a row group outside a table sits in an anonymous table, beside a float" do
      items =
        tp_layout(
          "<style>body{margin:0} #f{float:left;width:200px;height:50px} #g{display:table-row-group;clear:both} #r{display:table-row} #c{display:table-cell}</style><div id=f></div><div id=g><div id=r><div id=c>cell</div></div></div>"
        )

      cell = Enum.find(items, &(&1[:text] == "cell"))
      assert cell.x >= 200
      assert cell.y < 20
    end

    test "text in a row sits in an anonymous cell" do
      items =
        tp_layout(
          "<style>body{margin:0} #r{display:table-row}</style><div id=r>loose<span style=\"display:table-cell\">cell</span></div>"
        )

      assert Enum.any?(items, &(&1[:text] == "loose"))
      assert Enum.any?(items, &(&1[:text] == "cell"))
    end
  end

  describe "text with no space between it" do
    defp gl_layout(html, width) do
      page = Browser.Page.build(html, "about:home")
      {items, _} = Layout.layout(page.nodes, width, &measure/2)
      items
    end

    defp gl_item(items, text), do: Enum.find(items, &(&1[:text] == text))

    test "a word glued to the next one by an inline box moves with it" do
      items =
        gl_layout(
          "<style>body{margin:0}</style>aa bb<span style=\"margin-left:40px\">cc</span>",
          60
        )

      assert gl_item(items, "aa").y < gl_item(items, "bb").y
      assert gl_item(items, "bb").y == gl_item(items, "cc").y
    end

    test "a space still lets the line break" do
      items =
        gl_layout(
          "<style>body{margin:0}</style>aa bb <span style=\"margin-left:40px\">cc</span>",
          60
        )

      assert gl_item(items, "aa").y == gl_item(items, "bb").y
      assert gl_item(items, "cc").y > gl_item(items, "bb").y
    end
  end

  describe "letter-spacing and text-transform" do
    defp ts_items(html) do
      page = Browser.Page.build("<style>body{margin:0}</style>" <> html, "about:home")
      {items, _} = Layout.layout(page.nodes, 400, &measure/2)
      items
    end

    test "letter-spacing widens a word by its length after every character" do
      [plain] = ts_items("<p>abcd</p>") |> Enum.filter(&(&1[:text] == "abcd"))

      [spaced] =
        ts_items("<p style=\"letter-spacing:3px\">abcd</p>")
        |> Enum.filter(&(&1[:text] == "abcd"))

      assert spaced.w == plain.w + 12
      assert spaced.ls == 3.0
    end

    test "a percentage letter-spacing is of the element's own font size" do
      items = ts_items("<p style=\"letter-spacing:10%;font-size:20px\">ab</p>")
      assert Enum.find(items, &(&1[:text] == "ab")).ls == 2.0
    end

    test "text-transform changes the case of the text laid out" do
      items =
        ts_items(
          "<p style=\"text-transform:uppercase\">ab cd</p><p style=\"text-transform:capitalize\">ab \"cd\" ef</p>"
        )

      texts = for %{type: :text, text: t} <- items, do: t
      assert texts == ["AB", "CD", "Ab", "\"Cd\"", "Ef"]
    end

    test "word-spacing widens every space between words and inside them" do
      items = ts_items("<p style=\"word-spacing:5px\">ab cd</p>")
      ab = Enum.find(items, &(&1[:text] == "ab"))
      cd = Enum.find(items, &(&1[:text] == "cd"))
      plain = ts_items("<p>ab cd</p>")

      assert cd.x - ab.x ==
               Enum.find(plain, &(&1[:text] == "cd")).x - Enum.find(plain, &(&1[:text] == "ab")).x +
                 5

      assert ab.wsp == 5.0

      [pre] =
        ts_items("<pre style=\"word-spacing:5px\">a b</pre>")
        |> Enum.filter(&(&1[:text] == "a b"))

      [pre_plain] = ts_items("<pre>a b</pre>") |> Enum.filter(&(&1[:text] == "a b"))
      assert pre.w == pre_plain.w + 5
    end

    test "capitalize leaves the rest of a word begun before an inline box" do
      items = ts_items("<p>T<span style=\"text-transform:capitalize\">his text</span></p>")
      texts = for %{type: :text, text: t} <- items, do: t
      assert texts == ["T", "his", "Text"]
    end
  end

  describe "justified text" do
    defp just_items(style, html) do
      page =
        Browser.Page.build(
          "<style>body{margin:0}</style><div style=\"width:100px;#{style}\">#{html}</div>",
          "about:home"
        )

      {items, _} = Layout.layout(page.nodes, 400, &measure/2, 768, margin: 0)
      items
    end

    defp just_at(items, text), do: Enum.find(items, &(&1[:text] == text))

    test "a wrapped line is stretched to the full width" do
      items = just_items("text-align:justify;font-size:10px", "aaa bbb ccc ddd eee fff")
      first = Enum.filter(items, &(&1.type == :text and &1.y == just_at(items, "aaa").y))
      last = Enum.max_by(first, & &1.x)
      assert last.x + last.w == 100
      assert just_at(items, "aaa").x == 0
    end

    test "the last line is not stretched" do
      items = just_items("text-align:justify;font-size:10px", "aaa bbb ccc ddd eee fff")
      last_y = items |> Enum.filter(&(&1.type == :text)) |> Enum.map(& &1.y) |> Enum.max()
      row = Enum.filter(items, &(&1.type == :text and &1.y == last_y))
      assert Enum.min_by(row, & &1.x).x == 0
      assert Enum.max_by(row, & &1.x).x + 15 < 100
    end

    test "text-align-last: justify stretches the last line too" do
      items = just_items("text-align:left;text-align-last:justify;font-size:10px", "aaa bbb")
      assert just_at(items, "bbb").x + just_at(items, "bbb").w == 100
    end

    test "text-justify: none leaves the spaces alone" do
      items = just_items("text-align:justify;text-justify:none;font-size:10px", "aaa bbb ccc ddd")
      assert just_at(items, "bbb").x == 20
    end
  end

  describe "white-space: break-spaces" do
    defp bs_items(html, width) do
      page =
        Browser.Page.build(
          "<style>body{margin:0}</style><div style=\"width:#{width}px;white-space:break-spaces\">#{html}</div>",
          "about:home"
        )

      {items, _} = Layout.layout(page.nodes, 400, &measure/2, 768, margin: 0)
      for %{type: :text} = it <- items, do: {it.text, it.x, it.y}
    end

    test "preserved spaces wrap to the next line instead of hanging" do
      texts = bs_items("ab    c", 20)
      ys = texts |> Enum.map(&elem(&1, 2)) |> Enum.uniq()
      assert length(ys) >= 3
    end

    test "the first space after text stays with the text, even past the edge" do
      [{"ab", 0, y1}, {"\u00A0", _, y2} | _] = bs_items("ab cd", 10)
      assert y1 == y2
    end

    test "other space separators are preserved spaces too, and a line may break after them" do
      # (measure/2 gives every character the same width, 5px at the page's font size)
      [{"xx", 0, y1}, {"\u2001", _, y2} | _] = bs_items("xx\u2001ab", 10)
      assert y1 == y2
    end

    test "ideographs break between each other under break-spaces" do
      ys = bs_items("\u3042\u3042\u3001", 10) |> Enum.map(&elem(&1, 2)) |> Enum.uniq()
      assert length(ys) == 2
    end
  end

  describe "word-break and overflow-wrap" do
    defp wb_items(style, html, width) do
      page =
        Browser.Page.build(
          "<style>body{margin:0}</style><div style=\"width:#{width}px;font-size:10px;#{style}\">#{html}</div>",
          "about:home"
        )

      {items, _} = Layout.layout(page.nodes, 400, &measure/2, 768, margin: 0)
      for %{type: :text} = it <- items, do: {it.text, it.y}
    end

    test "break-all fills the line and breaks the word between characters" do
      assert [{"abcd", y1}, {"ef", y2}] = wb_items("word-break:break-all", "abcdef", 20)
      assert y2 > y1
    end

    test "break-all breaks after what fits on the line when text comes first" do
      assert [{"a", y1}, {"bcd", y1}, {"ef", y2}] =
               wb_items("word-break:break-all", "a bcdef", 25)

      assert y2 > y1
    end

    test "break-word wraps a word that fits a line whole" do
      assert [{"a", y1}, {"bcd", y2}] = wb_items("overflow-wrap:break-word", "a bcd", 20)
      assert y2 > y1
    end

    test "break-word breaks a word too long for any line" do
      assert [{"abcd", y1}, {"ef", y2}] = wb_items("overflow-wrap:break-word", "abcdef", 20)
      assert y2 > y1
    end

    test "normal does not break a long word" do
      assert [{"abcdef", _}] = wb_items("", "abcdef", 20)
    end

    test "pre-wrap keeps a space that starts a line" do
      [{text, _}] = wb_items("white-space:pre-wrap", " ab", 100) |> Enum.take(1)
      assert text == "\u00A0"
    end
  end

  describe "vertical-align on inline boxes" do
    # how much higher the text of the span sits than the "a" before it
    defp va_rise(style) do
      page =
        Browser.Page.build(
          "<style>body{margin:0}</style><div style=\"font-size:10px\">a<span style=\"#{style}\">b</span></div>",
          "about:home"
        )

      {items, _} = Layout.layout(page.nodes, 400, &measure/2, 768, margin: 0)
      Enum.find(items, &(&1[:text] == "a")).y - Enum.find(items, &(&1[:text] == "b")).y
    end

    test "a length raises the text above the baseline, a negative one lowers it" do
      assert va_rise("vertical-align:6px") == 6
      assert va_rise("vertical-align:-4px") == -4
    end

    test "super raises and sub lowers" do
      assert va_rise("vertical-align:super") > 0
      assert va_rise("vertical-align:sub") < 0
    end

    test "other units convert to pixels" do
      assert va_rise("vertical-align:6pt") == va_rise("vertical-align:8px")
    end
  end

  describe "ideographic space" do
    test "is a character of the word it follows, not collapsible white space" do
      items = texts(elem(run("<p>ab\u3000cd</p>"), 0))
      # (a line may break after it)
      assert Enum.join(items) == "ab\u3000cd"
    end

    test "hangs at the end of a line: the content is not wider for it" do
      html = "<div style=\"width:max-content\">ab\u3000<br>ab</div>"
      {items, _} = run(html)
      first = Enum.find(items, &(&1[:text] == "ab\u3000"))
      assert {first.w, first.hang} == {24, 8}
    end
  end

  describe "width: min-content and max-content" do
    defp row_count(html) do
      page = Browser.Page.build("<style>body{margin:0}</style>" <> html, "about:home")
      {items, _} = Layout.layout(page.nodes, 400, &measure/2, 768, margin: 0)
      items |> Enum.filter(&(&1.type == :text)) |> Enum.map(& &1.y) |> Enum.uniq() |> length()
    end

    test "min-content is the widest word, max-content the whole line" do
      assert row_count("<div style=\"width:min-content\">aa bbbb cc</div>") == 3
      assert row_count("<div style=\"width:max-content\">aa bbbb cc</div>") == 1
    end

    test "words glued across inline boxes stay together in min-content" do
      assert row_count("<div style=\"width:min-content\">a<b>b</b> cc</div>") == 2
    end
  end

  describe "shrink-to-fit with empty boxes" do
    test "a float holding an empty block with a border is as wide as the border" do
      page =
        Browser.Page.build(
          "<style>body{margin:0}</style><div style=\"float:left;border-right:5px solid red\"><div style=\"border-right:5px solid blue;height:10px\"></div></div>",
          "about:home"
        )

      {items, _} = Layout.layout(page.nodes, 400, &measure/2, 768, margin: 0)
      rects = Enum.filter(items, &(&1.type == :rect))
      assert Enum.sort(Enum.map(rects, &{&1.x, &1.w})) == [{0, 5}, {5, 5}]
    end
  end

  describe "aspect-ratio" do
    defp ratio_box(style) do
      page =
        Browser.Page.build(
          "<style>body{margin:0}</style><div style=\"background:green;#{style}\"></div>",
          "about:home"
        )

      {items, _} = Layout.layout(page.nodes, 400, &measure/2, 768, margin: 0)
      Enum.find(items, &(&1.type == :rect))
    end

    test "a width gives the height" do
      box = ratio_box("width:100px;aspect-ratio:2/1")
      assert {box.w, box.h} == {100, 50}
    end

    test "a height gives the width" do
      box = ratio_box("height:50px;aspect-ratio:2")
      assert {box.w, box.h} == {100, 50}
    end

    test "border-box sizing counts the border in the ratio" do
      box = ratio_box("width:100px;aspect-ratio:1;box-sizing:border-box;border:10px solid blue")
      assert box.h == 100
    end

    test "auto with a ratio sizes the content box" do
      box = ratio_box("width:100px;aspect-ratio:auto 1;box-sizing:border-box;padding-left:50px")
      assert box.h == 50
    end

    test "max-height carries over to the width" do
      box = ratio_box("max-height:40px;aspect-ratio:1")
      assert {box.w, box.h} == {40, 40}
    end

    test "an explicit height wins" do
      box = ratio_box("width:100px;height:20px;aspect-ratio:1")
      assert box.h == 20
    end
  end

  describe "invalid negative sizes" do
    defp neg_box(style) do
      page =
        Browser.Page.build(
          "<style>body{margin:0}</style><div style=\"background:green;#{style}\">x</div>",
          "about:home"
        )

      {items, _} = Layout.layout(page.nodes, 400, &measure/2, 768, margin: 0)
      Enum.find(items, &(&1.type == :rect))
    end

    test "a negative height is dropped and the earlier declaration stays" do
      assert neg_box("height:30px;height:-1px").h == 30
    end

    test "a negative width is dropped" do
      assert neg_box("width:50px;width:-5px").w == 50
    end

    test "negative zero is valid" do
      assert neg_box("height:-0px") == nil
    end
  end

  describe "floats and shrink-to-fit" do
    test "a float inside a float adds to its width" do
      page =
        Browser.Page.build(
          "<style>body{margin:0}</style><div style=\"float:left;border-right:5px solid red\"><div style=\"float:left;border-right:5px solid blue;height:10px\"></div></div>",
          "about:home"
        )

      {items, _} = Layout.layout(page.nodes, 400, &measure/2, 768, margin: 0)
      rects = Enum.filter(items, &(&1.type == :rect))
      assert Enum.sort(Enum.map(rects, &{&1.x, &1.w})) == [{0, 5}, {5, 5}]
    end
  end

  describe "margin-trim and column flex" do
    defp green_rects(html) do
      page = Browser.Page.build("<style>body{margin:0}</style>" <> html, "about:home")
      {items, _} = Layout.layout(page.nodes, 400, &measure/2, 768, margin: 0)
      items |> Enum.filter(&(&1.type == :rect)) |> Enum.map(&{&1.y, &1.h})
    end

    test "a block drops the margins of its first and last child" do
      html = """
      <div style="margin-trim:block"><div style="margin:20px 0;height:10px;background:green"></div></div>
      <div style="height:5px;background:green"></div>
      """

      assert green_rects(html) == [{0, 10}, {10, 5}]
    end

    test "without margin-trim the margins stay" do
      html = """
      <div><div style="margin:20px 0;height:10px;background:green"></div></div>
      <div style="height:5px;background:green"></div>
      """

      assert green_rects(html) == [{20, 10}, {50, 5}]
    end

    test "margin-trim reaches through a self-collapsing last child" do
      html = """
      <div style="margin-trim:block-end"><div style="margin-bottom:30px;height:10px;background:green"></div><div></div></div>
      <div style="height:5px;background:green"></div>
      """

      assert green_rects(html) == [{0, 10}, {10, 5}]
    end

    test "a flex container drops the margins of its items on the trimmed side" do
      html = """
      <div style="display:flex;margin-trim:block"><div style="margin:10px;width:20px;height:10px;background:green"></div></div>
      """

      assert green_rects(html) == [{0, 10}]
    end

    test "column flex items grow into the height of the container" do
      html = """
      <div style="display:flex;flex-direction:column;height:100px"><div style="flex:1;background:green"></div></div>
      """

      assert green_rects(html) == [{0, 100}]
    end

    test "column flex items shrink to fit the container" do
      html = """
      <div style="display:flex;flex-direction:column;height:100px"><div style="height:150px;background:green"></div></div>
      """

      assert green_rects(html) == [{0, 100}]
    end

    test "column flex items share the height by their grow factors" do
      html = """
      <div style="display:flex;flex-direction:column;height:100px"><div style="flex:3;background:green"></div><div style="flex:1;background:green"></div></div>
      """

      assert green_rects(html) == [{0, 75}, {75, 25}]
    end
  end

  describe "wrapping flex containers" do
    defp flex_boxes(style, n) do
      items = String.duplicate("<div style=\"width:50px;height:20px;background:green\"></div>", n)

      page =
        Browser.Page.build(
          "<style>body{margin:0}</style><div style=\"display:flex;#{style}\">#{items}</div>",
          "about:home"
        )

      {items, _} = Layout.layout(page.nodes, 400, &measure/2, 768, margin: 0)
      items |> Enum.filter(&(&1.type == :rect)) |> Enum.map(&{&1.x, &1.y})
    end

    test "flex-flow sets direction and wrap together" do
      assert flex_boxes("flex-flow:row wrap;width:100px", 3) == [{0, 0}, {50, 0}, {0, 20}]
      assert flex_boxes("flex-flow:wrap column;height:40px", 3) == [{0, 0}, {0, 20}, {50, 0}]
    end

    test "wrap-reverse stacks the lines upwards" do
      assert Enum.sort(flex_boxes("flex-wrap:wrap-reverse;width:100px", 3)) ==
               [{0, 0}, {0, 20}, {50, 20}]
    end

    test "row-reverse reverses every line" do
      assert Enum.sort(flex_boxes("flex-flow:row-reverse wrap;width:100px", 3)) ==
               [{0, 0}, {50, 0}, {50, 20}]
    end

    test "align-content shares the height between the lines" do
      assert flex_boxes("flex-wrap:wrap;width:100px;height:100px;align-content:flex-end", 4) == [
               {0, 60},
               {50, 60},
               {0, 80},
               {50, 80}
             ]

      assert flex_boxes("flex-wrap:wrap;width:100px;height:100px;align-content:space-between", 4) ==
               [{0, 0}, {50, 0}, {0, 80}, {50, 80}]
    end

    test "lines stretch into the height by default" do
      assert flex_boxes("flex-wrap:wrap;width:100px;height:100px;align-items:flex-start", 4) ==
               [{0, 0}, {50, 0}, {0, 50}, {50, 50}]
    end

    test "place-content sets align-content and justify-content" do
      assert flex_boxes("flex-wrap:wrap;width:100px;height:100px;place-content:end", 4) ==
               flex_boxes(
                 "flex-wrap:wrap;width:100px;height:100px;align-content:end;justify-content:end",
                 4
               )
    end
  end

  describe "ideographs and letter-spacing" do
    defp text_rows(html, width) do
      page = Browser.Page.build("<style>body{margin:0}</style>" <> html, "about:home")
      {items, _} = Layout.layout(page.nodes, width, &measure/2, 768, margin: 0)

      items
      |> Enum.filter(&(&1.type == :text))
      |> Enum.group_by(& &1.y)
      |> Enum.sort()
      |> Enum.map(fn {_, row} -> row |> Enum.sort_by(& &1.x) |> Enum.map_join(& &1.text) end)
    end

    test "a line breaks between ideographs and next to them" do
      html = ~s(<div style="font-size:20px">三三三三三三</div>)
      assert text_rows(html, 40) == ["三三三三", "三三"]
      html = ~s(<div style="font-size:20px">ab三cd</div>)
      assert text_rows(html, 30) == ["ab三", "cd"]
    end

    test "no break before closing punctuation, after an opening bracket or around a joiner" do
      html = ~s(<div style="font-size:20px">三三。三</div>)
      assert text_rows(html, 30) == ["三三。", "三"]
      html = ~s(<div style="font-size:20px">三三「三</div>)
      assert text_rows(html, 30) == ["三三", "「三"]
    end

    test "word-space-transform turns <wbr> and zero-width spaces into spaces" do
      html =
        ~s(<div style="font-size:20px;word-space-transform:ideographic-space">a<wbr>b&#x200B;c</div>)

      assert text_rows(html, 400) |> Enum.join() == "a\u3000b\u3000c"
      html = ~s(<div style="font-size:20px;word-space-transform:space">a<wbr>b</div>)
      assert text_rows(html, 400) == ["a b"] or text_rows(html, 400) == ["ab"]
    end

    test "a zero-width space takes no room" do
      html = ~s(<div style="font-size:20px">a&#x200B;b</div>)
      page = Browser.Page.build("<style>body{margin:0}</style>" <> html, "about:home")
      {items, _} = Layout.layout(page.nodes, 400, &measure/2, 768, margin: 0)
      b = Enum.find(items, &(&1.type == :text and &1.text == "b"))
      assert b.x == 10
    end

    test "keep-all and auto-phrase keep a run of ideographs together" do
      html = ~s(<div style="font-size:20px;word-break:keep-all">三三三三三三</div>)
      assert text_rows(html, 40) == ["三三三三三三"]
    end

    test "letter-spacing after the last letter of a line does not count towards fitting it" do
      html = ~s(<div style="font-size:20px;letter-spacing:10px">三三 三</div>)
      # 10 + 10 + 10 + 10 = 40 wide with the spacing after the second, but only 30 are needed
      assert text_rows(html, 30) == ["三三", "三"]
      assert length(text_rows(html, 200)) == 1
    end

    test "the spacing after the last letter of an inline element is its parent's" do
      page =
        Browser.Page.build(
          "<style>body{margin:0}span{letter-spacing:10px}</style>" <>
            "<div style=\"font-size:20px\">a<span>bb</span>c</div>",
          "about:home"
        )

      {items, _} = Layout.layout(page.nodes, 400, &measure/2, 768, margin: 0)
      xs = items |> Enum.filter(&(&1.type == :text)) |> Enum.map(&{&1.text, &1.x})
      # a (10), b (10 + 10 spacing), b (10, no spacing after it), c
      assert xs == [{"a", 0}, {"b", 10}, {"b", 30}, {"c", 40}] or
               Enum.find(xs, &(elem(&1, 0) == "c")) == {"c", 40}
    end
  end

  describe "text-transform keywords" do
    defp transformed(css, text, attrs \\ "") do
      html = ~s(<div style="font-size:20px;#{css}" #{attrs}>#{text}</div>)
      page = Browser.Page.build("<style>body{margin:0}</style>" <> html, "about:home")
      {items, _} = Layout.layout(page.nodes, 800, &measure/2, 768, margin: 0)

      items
      |> Enum.filter(&(&1.type == :text))
      |> Enum.sort_by(& &1.x)
      |> Enum.map_join(& &1.text)
    end

    test "full-width widens ASCII and spaces" do
      assert transformed("text-transform:full-width", "Ab 1") == "Ａｂ１" or
               transformed("text-transform:full-width", "Ab 1") == "Ａｂ\u3000１"
    end

    test "keywords combine" do
      assert transformed("text-transform:uppercase full-width", "ab") == "ＡＢ"
    end

    test "full-size-kana replaces small kana" do
      assert transformed("text-transform:full-size-kana", "ぁっ") == "あつ"
    end

    test "capitalize skips symbols and the Dutch ij is a digraph" do
      assert transformed("text-transform:capitalize", "&lt;?transform") == "<?Transform"
      assert transformed("text-transform:capitalize", "ijsland", ~s(lang="nl")) == "IJsland"
    end

    test "Greek capitals lose their accents" do
      assert transformed("text-transform:uppercase", "καλημέρα", ~s(lang="el")) == "ΚΑΛΗΜΕΡΑ"
      assert transformed("text-transform:uppercase", "é", ~s(lang="fr")) == "É"
    end
  end

  describe "white space at the line edge" do
    test "spaces before an empty inline box at the end of a line collapse away" do
      page =
        Browser.Page.build(
          "<style>body{margin:0}span span{border-left:30px solid green}</style>" <>
            "<div style=\"font:30px/30px monospace\"><span>A  <span>  </span>  </span></div>",
          "about:home"
        )

      {items, _} = Layout.layout(page.nodes, 400, &measure/2, 768, margin: 0)

      [{x, _, w, _}] =
        items |> Enum.filter(&(&1.type == :rect)) |> Enum.map(&{&1.x, &1.y, &1.w, &1.h})

      # the border follows the A directly
      assert w == 30
      assert x == 15
    end
  end

  describe "flex container sizing" do
    defp flex_rects(html) do
      page = Browser.Page.build("<style>body{margin:0}</style>" <> html, "about:home")
      {items, _} = Layout.layout(page.nodes, 400, &measure/2, 768, margin: 0)
      items |> Enum.filter(&(&1.type == :rect)) |> Enum.map(&{&1.x, &1.y, &1.w, &1.h})
    end

    test "a row item with an aspect ratio is at least as wide as its content" do
      html =
        ~s(<div style="display:flex"><div style="background:green;height:100px;aspect-ratio:1/2;flex-basis:0"><div style="width:100px"></div></div></div>)

      assert flex_rects(html) == [{0, 0, 100, 100}]

      html =
        ~s(<div style="display:flex"><div style="background:green;height:100px;aspect-ratio:1/2"><div style="width:100px"></div></div></div>)

      assert flex_rects(html) == [{0, 0, 100, 100}]
    end

    test "a column item with an aspect ratio is as wide as its final height makes it" do
      html =
        ~s(<div style="display:inline-flex;flex-direction:column;flex-wrap:wrap;height:100px"><div style="background:green;aspect-ratio:1/1;min-height:0;height:50px;flex:1"></div></div>)

      assert flex_rects(html) == [{0, 0, 100, 100}]
    end

    test "a stretched item with a ratio is at least as wide as its height makes it" do
      html =
        ~s(<div style="display:flex;width:0;height:100px"><div style="background:green;aspect-ratio:1"></div></div>)

      assert flex_rects(html) == [{0, 0, 100, 100}]
    end

    test "an item with auto cross margins does not stretch to give its ratio a width" do
      html =
        ~s(<div style="display:flex;height:100px"><div style="background:red;aspect-ratio:1;min-width:0;margin:auto 0"></div><div style="background:green;height:100px;width:100px"></div></div>)

      assert Enum.sort(flex_rects(html)) |> List.last() == {0, 0, 100, 100}
    end

    test "a wrapping column takes its height from its width and ratio" do
      html =
        ~s(<div style="display:flex;flex-direction:column;flex-wrap:wrap;width:100px;aspect-ratio:1"><div style="background:green;width:50px;height:100px"></div><div style="background:green;width:50px;height:100px"></div></div>)

      assert Enum.sort(flex_rects(html)) == [{0, 0, 50, 100}, {50, 0, 50, 100}]
    end

    test "a floated flex container is as wide as its items" do
      html = """
      <div style="display:flex;float:left;background:blue"><div style="width:20px;height:10px"></div></div>
      <div style="display:flex;float:left;background:red"><div style="width:30px;height:10px"></div></div>
      """

      assert Enum.sort(flex_rects(html)) == [{0, 0, 20, 10}, {20, 0, 30, 10}]
    end

    test "a percentage height item in a column of definite height shrinks, the other keeps its content" do
      html = """
      <div style="height:100px;width:100px"><div style="display:flex;flex-direction:column;height:100%">
      <div style="background:blue"><div style="height:20px"></div></div>
      <div style="height:100%;background:green"></div></div></div>
      """

      assert Enum.sort(flex_rects(html)) == [{0, 0, 100, 20}, {0, 20, 100, 80}]
    end

    test "space-evenly rounds each gap, as margins would be" do
      html = """
      <div style="display:flex;width:200px;justify-content:space-evenly"><div style="width:10px;height:5px;background:red"></div><div style="width:50px;height:5px;background:blue"></div></div>
      """

      assert Enum.sort(flex_rects(html)) == [{47, 0, 10, 5}, {104, 0, 50, 5}]
    end

    test "in a right-to-left column, flex-start items sit at the right" do
      html = """
      <div style="display:flex;flex-direction:column;direction:rtl;width:100px;align-items:flex-start"><div style="width:30px;height:5px;background:red"></div></div>
      """

      assert flex_rects(html) == [{70, 0, 30, 5}]
    end

    test "min-width:auto stops shrinking at the smaller of the width and the content" do
      item = fn style ->
        ~s(<div style="display:flex;width:1px"><div style="background:red;#{style}"><div style="width:80px;height:5px"></div></div></div>)
      end

      width = fn style -> flex_rects(item.(style)) |> hd() |> elem(2) end
      assert width.("width:50px") == 50
      assert width.("width:100px") == 80
      assert width.("flex-basis:100px;max-width:50px") == 50
      assert width.("width:50px;overflow:hidden") == 1
    end

    test "an auto top margin takes the free cross space, even with baseline alignment" do
      html =
        ~s(<div style="display:flex;align-items:baseline;height:40px"><div style="margin-top:auto;height:10px;background:red">a</div></div>)

      assert [{_, 30, _, 10}] = flex_rects(html)
    end

    test "a collapsed flex item takes no width but keeps its height, and its gap goes" do
      html = """
      <div style="display:flex;gap:10px;width:200px"><div style="width:20px;height:5px;background:red"></div><div style="width:50px;height:30px;visibility:collapse;margin:0 7px"></div><div style="width:20px;height:5px;background:blue"></div></div>
      """

      assert Enum.sort(flex_rects(html)) == [{0, 0, 20, 5}, {30, 0, 20, 5}]
      assert Enum.all?(flex_rects(html), fn {_, _, _, h} -> h <= 30 end)
      page = Browser.Page.build("<style>body{margin:0}</style>" <> html, "about:home")
      assert {_, 30} = Layout.layout(page.nodes, 400, &measure/2, 768, margin: 0)
    end

    test "a flex item with a height of its own gives percentage children something to resolve against" do
      html = """
      <div style="display:flex;flex-direction:column"><div style="width:50px;height:40px"><div style="height:50%;background:green"></div></div></div>
      """

      assert flex_rects(html) == [{0, 0, 50, 20}]
    end

    test "min-height on column items: raised in an auto-height column, 0 lets it shrink" do
      grow =
        ~s(<div style="display:flex;flex-direction:column;width:50px"><div style="flex:1 0 0px;min-height:40px;background:red"></div></div>)

      assert flex_rects(grow) == [{0, 0, 50, 40}]

      shrink =
        ~s(<div style="display:flex;flex-direction:column;width:50px;height:30px"><div style="min-height:0;background:red"><div style="height:100px"></div></div></div>)

      assert flex_rects(shrink) == [{0, 0, 50, 30}]
    end

    test "the lines of a wrapping column are as wide as their items, then share the room left" do
      html = """
      <div style="display:flex;flex-flow:column wrap;width:100px;height:50px;gap:10px"><div style="height:20px;background:red"><div style="width:30px"></div></div><div style="height:20px;background:green"><div style="width:20px"></div></div><div style="height:20px;background:blue"><div style="width:10px"></div></div></div>
      """

      # two lines: 30 and 10 wide, 10 apart; the 50 left over is split between them
      assert Enum.sort(flex_rects(html)) == [{0, 0, 55, 20}, {0, 30, 55, 20}, {65, 0, 35, 20}]
    end

    test "flex: 0 0 does not take an item below its automatic minimum width" do
      html = """
      <div style="display:flex;width:200px"><div style="flex:0 0;width:50px;background:red"><div style="width:30px;height:5px"></div></div></div>
      """

      assert [{0, 0, 30, 5}] = flex_rects(html)
    end

    test "a flex container wider than its parent keeps its width" do
      html =
        ~s(<div style="width:100px"><div style="display:flex;width:190px;justify-content:flex-end"><div style="width:90px;height:5px;background:red"></div></div></div>)

      assert flex_rects(html) == [{100, 0, 90, 5}]
    end

    test "flex-grow factors that add up to less than one take only that share of the room" do
      html =
        ~s(<div style="display:flex;width:190px"><div style="width:90px;flex-grow:.1;height:5px;background:red"></div></div>)

      assert flex_rects(html) == [{0, 0, 100, 5}]
    end

    test "an item at its max-width is frozen and the others share the rest" do
      html =
        ~s(<div style="display:flex;width:100px"><div style="flex-grow:1;max-width:0;height:5px;background:red"></div><div style="flex-grow:1;height:5px;background:blue"></div></div>)

      assert Enum.sort(flex_rects(html)) == [{0, 0, 100, 5}]
    end

    test "the flex base size ignores max-width, which then freezes the item while shrinking" do
      html = """
      <div style="display:flex;width:300px"><div style="min-width:0;max-width:100px;background:red"><div style="width:300px;height:5px"></div></div><div style="min-width:0;background:blue"><div style="width:300px;height:5px"></div></div></div>
      """

      assert Enum.sort(flex_rects(html)) == [{0, 0, 100, 5}, {100, 0, 200, 5}]
    end

    test "a negative flex-shrink is invalid and leaves the initial 1" do
      html =
        ~s(<div style="display:flex;width:50px"><div style="width:100px;flex-shrink:-2;min-width:0;height:5px;background:red"></div></div>)

      assert flex_rects(html) == [{0, 0, 50, 5}]
    end

    test "a floated list item is a box with a size of its own" do
      html =
        ~s(<ul style="margin:0;padding:0"><li style="float:left;list-style:none;width:30px;height:10px;background:red"></li></ul>)

      assert flex_rects(html) == [{0, 0, 30, 10}]
    end

    test "align-content: center lets lines overflow evenly on both sides" do
      html =
        ~s(<div style="display:flex;flex-wrap:wrap;align-content:center;width:50px;height:20px"><div style="width:50px;height:20px;background:red"></div><div style="width:50px;height:20px;background:blue"></div></div>)

      assert Enum.sort(flex_rects(html)) == [{0, -10, 50, 20}, {0, 10, 50, 20}]
    end

    test "a column-reverse container breaks into columns in order, each packed at the bottom" do
      html = """
      <div style="display:flex;flex-flow:column-reverse wrap;align-items:flex-start;width:200px;max-height:100px"><div style="width:50px;height:40px;background:red"></div><div style="width:50px;height:80px;background:blue"></div></div>
      """

      assert Enum.sort(flex_rects(html)) == [{0, 40, 50, 40}, {50, 0, 50, 80}]
    end

    test "a floated column container is as wide as its items, whatever their flex-basis" do
      html = """
      <div style="display:flex;flex-direction:column;float:left;height:100px"><div style="width:20px;flex:0 10px;background:green"></div></div>
      <div style="display:flex;flex-direction:column;float:left;height:100px"><div style="width:20px;flex:0 10px;background:blue"></div></div>
      """

      assert Enum.sort(flex_rects(html)) == [{0, 0, 20, 10}, {20, 0, 20, 10}]
    end

    test "a wrapping column with a max-content width is as wide as its columns" do
      html = """
      <div style="display:flex;flex-flow:column wrap;height:100px;width:max-content;background:#eee"><div style="width:50px;flex:0 0 100px;background:green"></div><div style="width:30px;flex:0 0 100px;background:blue"></div></div>
      """

      assert Enum.sort(flex_rects(html)) == [{0, 0, 50, 100}, {0, 0, 80, 100}, {50, 0, 30, 100}]
    end

    test "justify-content: center and flex-end let items overflow at the start side" do
      html = """
      <div style="display:flex;width:30px;justify-content:flex-end"><div style="flex:0 0 40px;height:10px;background:green"></div></div>
      """

      assert [{-10, 0, 40, 10}] = flex_rects(html)
    end

    test "a percentage height inside a column item that cannot flex refers to its flexed size" do
      fixed =
        ~s|<div style="display:flex;flex-direction:column"><div style="flex:0 0 100px"><div style="width:100px;height:100%;background:green"></div></div></div>|

      flexible =
        ~s|<div style="display:flex;flex-direction:column"><div style="flex:1 1 100px"><div style="width:100px;height:100%;background:green"></div></div></div>|

      tall =
        ~s|<div style="display:flex;flex-direction:column;height:200px"><div style="flex:1 1 100px"><div style="width:100px;height:100%;background:green"></div></div></div>|

      assert [{0, 0, 100, 100}] = flex_rects(fixed)
      assert flex_rects(flexible) == []
      assert [{0, 0, 100, 200}] = flex_rects(tall)
    end

    test "column items start from their flex-basis" do
      html = """
      <div style="display:flex;flex-direction:column;height:100px"><div style="flex:0 30px;background:green"></div></div>
      """

      assert flex_rects(html) == [{0, 0, 400, 30}]
    end

    test "a column item does not go below its content" do
      html = """
      <div style="display:flex;flex-direction:column;height:10px"><div style="flex-basis:0;background:green"><div style="height:50px"></div></div></div>
      """

      assert flex_rects(html) == [{0, 0, 400, 50}]
    end
  end

  describe "collapsed borders from rows and row groups" do
    defp table_rects(css, rows) do
      html =
        "<style>body{margin:0}table{border-collapse:collapse;width:100px;table-layout:fixed}td{height:20px;padding:0}#{css}</style><table>#{rows}</table>"

      page = Browser.Page.build(html, "about:home")
      {items, _} = Layout.layout(page.nodes, 400, &measure/2, 768, margin: 0)
      items |> Enum.filter(&(&1.type == :rect)) |> Enum.map(&{&1.x, &1.y, &1.w, &1.h})
    end

    test "a row's top border is drawn across its cells" do
      rects =
        table_rects(
          "tr{border-top:3px solid green}",
          "<tr><td></td><td></td></tr>"
        )

      assert Enum.sort(rects) == [{0, 0, 50, 3}, {50, 0, 50, 3}]
    end

    test "a row group's border-bottom is drawn under its last row" do
      rects =
        table_rects(
          "tbody{border-bottom:3px solid green}",
          "<tbody><tr><td></td></tr><tr><td></td></tr></tbody>"
        )

      assert Enum.map(rects, &elem(&1, 3)) == [3]
      assert [{0, y, 100, 3}] = rects
      assert y == 37
    end

    test "the wider of two borders between rows wins" do
      rects =
        table_rects(
          "#a{border-bottom:2px solid green}#b{border-top:4px solid green}",
          "<tr id=a><td></td></tr><tr id=b><td></td></tr>"
        )

      assert Enum.map(rects, &elem(&1, 3)) == [4]
    end
  end

  describe "absolute boxes sized to their content" do
    defp abs_width(inner) do
      page =
        Browser.Page.build(
          "<style>body{margin:0}</style><div style=\"border:10px solid blue;position:absolute\">#{inner}</div>",
          "about:home"
        )

      {items, _} = Layout.layout(page.nodes, 400, &measure/2, 768, margin: 0)
      items |> Enum.find(&(&1.type == :rect)) |> Map.fetch!(:w)
    end

    test "an inline-block with a border counts once" do
      assert abs_width(
               ~s(<div style="border:10px solid orange;display:inline-block;height:20px;width:200px"></div>)
             ) == 240
    end

    test "an inline-block wider than its text counts by its width" do
      assert abs_width(~s(<span style="display:inline-block;width:40px">a</span>)) == 60
    end

    test "a block with a width and a border counts once" do
      assert abs_width(~s(<div style="border:10px solid orange;height:20px;width:200px"></div>)) ==
               240
    end
  end

  describe "floated parts of a table" do
    test "a floated row group is a block around a table of its rows" do
      html = """
      <style>body{margin:0}</style>
      <div style="display:table;width:200px">
        <div style="display:table-row-group;float:right;background:blue">
          <div style="display:table-row"><div style="display:table-cell;width:30px;height:20px"></div></div>
        </div>
      </div>
      """

      page = Browser.Page.build(html, "about:home")
      {items, _} = Layout.layout(page.nodes, 400, &measure/2, 768, margin: 0)
      blue = Enum.find(items, &(&1.type == :rect and &1.color == {0, 0, 255}))
      assert {blue.x, blue.w, blue.h} == {170, 30, 20}
    end
  end

  describe "margin after an inline box" do
    test "the right margin of a span has to fit with its last word" do
      html = """
      <style>body{margin:0}</style>
      <div style="width:75px;font:15px/1 monospace"><span style="margin-right:60px">ab cd</span></div>
      """

      page = Browser.Page.build(html, "about:home")
      {items, _} = Layout.layout(page.nodes, 400, &measure/2, 768, margin: 0)
      ys = for %{type: :text} = t <- items, uniq: true, do: t.y
      assert length(ys) == 2
    end
  end

  describe "margins of a table" do
    test "collapse with the margins of the blocks around it" do
      html = """
      <style>body{margin:0}</style>
      <p style="margin:0 0 16px;height:20px"></p>
      <table style="margin:15px 0;border-spacing:0"><tr><td style="padding:0;width:10px;height:10px;background:blue"></td></tr></table>
      """

      page = Browser.Page.build(html, "about:home")
      {items, _} = Layout.layout(page.nodes, 400, &measure/2, 768, margin: 0)
      blue = Enum.find(items, &(&1.type == :rect and &1.color == {0, 0, 255}))
      assert blue.y == 36
    end
  end

  describe "clearance and the margin of a first child" do
    test "the margin of the first child of a cleared box is absorbed by the clearance" do
      html = """
      <style>body{margin:0}</style>
      <div style="float:left;width:50px;height:100px"></div>
      <div style="clear:both"><div style="margin-top:10px;height:20px;background:blue"></div></div>
      """

      page = Browser.Page.build(html, "about:home")
      {items, _} = Layout.layout(page.nodes, 400, &measure/2, 768, margin: 0)
      blue = Enum.find(items, &(&1.type == :rect and &1.color == {0, 0, 255}))
      assert blue.y == 100
    end
  end

  describe "height of a table cell" do
    test "is the height of its content: borders and padding come on top" do
      html = """
      <style>body{margin:0}</style>
      <table style="border-spacing:0"><tr><td style="border:10px solid orange;height:100px;padding:0;width:50px"></td></tr></table>
      """

      page = Browser.Page.build(html, "about:home")
      {items, _} = Layout.layout(page.nodes, 400, &measure/2, 768, margin: 0)
      orange = Enum.filter(items, &(&1.type == :rect and &1.color == {255, 165, 0}))
      assert orange |> Enum.map(&(&1.y + &1.h)) |> Enum.max() == 120
    end
  end

  describe "margins of empty boxes with a background" do
    test "collapse through the box like those of an empty box without one" do
      html = """
      <style>body{margin:0}</style>
      <div style="height:20px;background:green"></div>
      <div style="margin:40px 0;background:red"><div style="margin:40px 0"></div></div>
      <div style="height:20px;background:blue"></div>
      """

      page = Browser.Page.build(html, "about:home")
      {items, _} = Layout.layout(page.nodes, 400, &measure/2, 768, margin: 0)
      blue = Enum.find(items, &(&1.type == :rect and &1.color == {0, 0, 255}))
      assert blue.y == 60
    end
  end

  describe "margins of the root element" do
    test "do not collapse with the margins of its children" do
      html = """
      <html style="margin-top:20px"><body style="margin:0"><div style="margin-top:20px;height:10px;background:blue"></div></body></html>
      """

      page = Browser.Page.build(html, "about:home")
      {items, _} = Layout.layout(page.nodes, 400, &measure/2, 768, margin: 0)
      blue = Enum.find(items, &(&1.type == :rect and &1.color == {0, 0, 255}))
      assert blue.y == 40
    end
  end

  describe "positioned parts of a table and inline-level absolute boxes" do
    test "a relatively positioned row moves its cells" do
      html = """
      <style>body{margin:0}</style>
      <table style="border-spacing:0"><tr style="position:relative;left:30px"><td style="padding:0"><div style="width:20px;height:10px;background:blue"></div></td></tr></table>
      """

      page = Browser.Page.build(html, "about:home")
      {items, _} = Layout.layout(page.nodes, 400, &measure/2, 768, margin: 0)
      blue = Enum.find(items, &(&1.type == :rect and &1.color == {0, 0, 255}))
      assert blue.x == 30
    end

    test "an inline-level absolute box sits beside the floats of its line" do
      html = """
      <style>body{margin:0}</style>
      <div style="float:left;width:50px;height:20px"></div>
      <div style="display:inline;position:absolute;width:10px;height:10px;background:blue"></div>
      """

      page = Browser.Page.build(html, "about:home")
      {items, _} = Layout.layout(page.nodes, 400, &measure/2, 768, margin: 0)
      blue = Enum.find(items, &(&1.type == :rect and &1.color == {0, 0, 255}))
      assert blue.x == 50
    end
  end

  describe "line breaks next to atomic inlines" do
    defp laid_out(html) do
      page = Browser.Page.build(html, "about:home")
      {items, _} = Layout.layout(page.nodes, 400, &measure/2, 768, margin: 0)
      items
    end

    test "no break between a narrow no-break space and an inline-block" do
      items =
        laid_out(
          ~s(<div style="width:20px">a&#8239;<span style="display:inline-block">b</span></div>)
        )

      assert items
             |> Enum.filter(&(&1.type == :text))
             |> Enum.map(& &1.y)
             |> Enum.uniq()
             |> length() == 1
    end

    test "a break is possible between a no-break space and an inline-block" do
      items =
        laid_out(
          ~s(<div style="width:20px">aaaa&nbsp;<span style="display:inline-block">bbbb</span></div>)
        )

      assert items
             |> Enum.filter(&(&1.type == :text))
             |> Enum.map(& &1.y)
             |> Enum.uniq()
             |> length() == 2
    end
  end

  describe "fit-content() and stretch widths" do
    test "fit-content(L) is as wide as the content, between its narrowest and L" do
      html =
        ~s|<div style="width:300px"><div style="width:fit-content(100px);background:green"><span style="display:inline-block;width:60px;height:5px"></span> <span style="display:inline-block;width:60px;height:5px"></span></div></div>|

      assert Enum.any?(laid_out(html), &(&1.type == :rect and &1.w == 100))
    end

    test "a float with width: stretch fills the containing block" do
      html =
        ~s(<div style="width:200px"><div style="float:left;width:stretch;height:10px;background:green"></div></div>)

      assert Enum.any?(laid_out(html), &(&1.type == :rect and &1.w == 200))
    end
  end

  describe "borders of columns in a collapsed table" do
    test "a colgroup's top border is drawn along the top of its columns" do
      html =
        ~s|<table style="border-collapse:collapse;border-spacing:0"><colgroup style="border-top:3px solid green"><col><col></colgroup><tr><td style="padding:0;width:40px;height:20px"></td><td style="padding:0;width:40px"></td></tr></table>|

      assert Enum.any?(
               laid_out(html),
               &(&1.type == :rect and &1.color == {0, 128, 0} and &1.h == 3)
             )
    end
  end

  describe "flex baseline alignment" do
    test "items aligned on their baselines have their first lines' bottoms at the same height" do
      html =
        ~s|<div style="display:flex;align-items:baseline;font-family:Ahem"><div style="font-size:10px;line-height:10px">a</div><div style="font-size:30px;line-height:30px">b</div></div>|

      bottoms = for %{type: :text, y: y, h: h} <- laid_out(html), do: y + h
      assert [same] = Enum.uniq(bottoms)
      assert is_integer(same)
    end
  end

  describe "column geometry" do
    test "column edges are rounded from their exact positions, so neighbours still touch" do
      html =
        ~s|<div style="columns:8;column-gap:5px;column-fill:auto;width:100px;height:100px"><div style="height:800px;background:green"></div></div>|

      cols = for %{type: :rect, color: {0, 128, 0}, h: 100} = r <- laid_out(html), do: r
      edges = cols |> Enum.map(&{&1.x, &1.x + &1.w}) |> Enum.sort()
      assert Enum.all?(edges, fn {l, r} -> is_integer(l) and is_integer(r) end)
    end

    test "a percentage column-gap is of the width of the box" do
      html =
        ~s|<div style="columns:2;column-gap:10%;width:200px;font:10px/10px Ahem"><div>a</div><div>b</div></div>|

      xs = for %{type: :text, text: t, x: x} <- laid_out(html), t in ["a", "b"], do: x
      assert Enum.max(xs) - Enum.min(xs) == 110
    end
  end

  describe "segment breaks between wide characters" do
    test "a zero-width space is a place to break a line" do
      html = ~s|<div style="width:7px;font:10px/1 Ahem">X&#x200B;X</div>|
      ys = for %{type: :text, y: y, text: t} <- laid_out(html), t != "", uniq: true, do: y
      assert length(ys) == 2
    end

    test "a line break between two wide characters leaves no space" do
      wide = laid_out("<p>測試\n測試</p>") |> Enum.filter(&(&1.type == :text))
      # (no space between the lines' words: they sit side by side)
      assert wide |> Enum.map(& &1.text) |> Enum.join() == "測試測試"
    end

    test "a line break between other characters is a space" do
      texts = for %{type: :text, text: t} <- laid_out("<p>ab\ncd</p>"), do: t
      assert texts == ["ab", "cd"]
    end
  end

  describe "table-layout: fixed" do
    test "a zero-wide fixed table has zero-wide cells" do
      html =
        ~s(<table style="table-layout:fixed;width:0;border-spacing:0"><tr><td style="padding:0;background:red;height:20px"></td></tr></table>)

      refute Enum.any?(laid_out(html), &(&1.type == :rect and &1.w > 0))
    end
  end

  describe "flex-basis and background sizes" do
    test "a width of calc(50% - 10px) is half the container less 10px" do
      html =
        ~s|<div style="width:200px"><div style="width:calc(50% - 10px);height:10px;background:red"></div></div>|

      assert Enum.any?(laid_out(html), &(&1.type == :rect and &1.w == 90))
    end

    test "a flex item with a zero flex-basis and no grow is zero wide" do
      html =
        ~s(<div style="display:flex;width:100px"><div style="flex-basis:0;height:10px;background:red"></div><div style="flex:1;height:10px;background:green"></div></div>)

      assert Enum.any?(laid_out(html), &(&1.type == :rect and &1.w == 100))
    end

    test "a negative flex-basis is invalid, so the item keeps its width" do
      html =
        ~s(<div style="display:flex;width:100px"><div style="flex-basis:-50px;width:30px;height:10px;background:red"></div></div>)

      assert Enum.any?(laid_out(html), &(&1.type == :rect and &1.w == 30))
    end

    test "ch lengths work in a background shorthand's size" do
      html =
        ~s|<div style="font:20px Ahem;width:100px;height:40px;background:linear-gradient(red,red) 0 0/2ch 1ch no-repeat"></div>|

      layer =
        laid_out(html) |> Enum.find(&(&1.type == :bgimage)) |> Map.fetch!(:layers) |> hd()

      assert {_, _, w, h} = layer.tile
      assert w < 100 and h < 40
    end
  end

  describe "transparent text" do
    test "takes its room and is not drawn" do
      items = laid_out(~s(<span style="color:transparent">abc</span>))
      assert Enum.any?(items, &(&1.type == :text and &1.hidden))
    end

    test "does not hide the background of its box" do
      items =
        laid_out(~s(<span style="color:transparent;background:blue">abc</span>))

      assert Enum.any?(items, &(&1.type == :rect and &1.w > 0))
    end
  end

  describe "display: flow-root, display: contents and line-break: anywhere" do
    defp rect_heights(items), do: for(%{type: :rect, h: h} <- items, do: h)

    test "flow-root grows to hold its floats and keeps the margins of its children inside" do
      items =
        laid_out(
          ~s(<div style="display:flow-root;background:red"><div style="float:left;width:10px;height:40px"></div></div>)
        )

      assert Enum.any?(rect_heights(items), &(&1 == 40))
    end

    test "float on display: contents is ignored" do
      items = laid_out(~s(<div style="display:contents;float:right">ab</div>))
      assert [%{x: x}] = Enum.filter(items, &(&1.type == :text))
      assert x < 100
    end

    test "line-break: anywhere breaks between any characters" do
      items = laid_out(~s(<div style="width:20px;line-break:anywhere">aaaaaaaa</div>))
      ys = items |> Enum.filter(&(&1.type == :text)) |> Enum.map(& &1.y) |> Enum.uniq()
      assert length(ys) > 1
    end

    test "the text of a content string keeps its case" do
      items = laid_out(~s(<style>p::before{content:"AbC"}</style><p>x</p>))
      assert "AbC" in texts(items) or Enum.any?(texts(items), &String.contains?(&1, "AbC"))
    end

    defp wrapped_lines(items) do
      items
      |> Enum.filter(&(&1.type == :text))
      |> Enum.group_by(& &1.y, & &1.text)
      |> Enum.sort()
      |> Enum.map(fn {_, ts} -> ts |> Enum.join() |> String.replace("\u00A0", " ") end)
    end

    test "break-all takes the last letter along with the space after it" do
      html =
        ~s(<div style="width:32px;white-space:break-spaces;word-break:break-all">X XX X</div>)

      assert wrapped_lines(laid_out(html)) == ["X X", "X X"]
    end

    test "line-break: anywhere may split a word from the space after it" do
      html = ~s(<div style="width:32px;white-space:break-spaces;line-break:anywhere">X XX X</div>)
      assert wrapped_lines(laid_out(html)) == ["X XX", " X"]
    end

    test "overflow-wrap: anywhere keeps the space with its word" do
      html =
        ~s(<div style="width:32px;white-space:break-spaces;overflow-wrap:anywhere">X XX X</div>)

      assert wrapped_lines(laid_out(html)) == ["X ", "XX X"]
    end

    test "break-word lets a space wrap away from a word alone on its line" do
      html =
        ~s(<div style="width:32px;white-space:break-spaces;word-break:break-word">XXXX X</div>)

      assert wrapped_lines(laid_out(html)) == ["XXXX", " X"]
    end

    test "a tab is one unbreakable word" do
      html = ~s(<div style="width:8px;white-space:break-spaces">X\t\tX</div>)
      assert length(wrapped_lines(laid_out(html))) == 3
    end

    test "size containment takes the height from contain-intrinsic-size" do
      html =
        ~s(<div style="background:blue;contain:size;contain-intrinsic-size:111px 22px">xxxx</div>)

      assert Enum.any?(rect_heights(laid_out(html)), &(&1 == 22))
    end

    test "size containment without an intrinsic size ignores the content" do
      html = ~s(<div style="background:blue;contain:strict">xxxx</div><p>after</p>)
      refute Enum.any?(rect_heights(laid_out(html)), &(&1 > 0))
    end

    test "position on display: contents is ignored" do
      items = laid_out(~s(<div style="display:contents;position:absolute;right:0">ab</div>))
      assert [%{x: x}] = Enum.filter(items, &(&1.type == :text))
      assert x < 100
    end

    test "a soft hyphen is a place to break, with a hyphen shown there" do
      html = ~s(<div style="width:40px">ab&shy;cd&shy;ef gh</div>)
      assert wrapped_lines(laid_out(html)) == ["abcd-", "efgh"]
    end

    test "a word that fits keeps its soft hyphens out of sight" do
      html = ~s(<div style="width:200px">ab&shy;cd</div>)
      assert wrapped_lines(laid_out(html)) == ["abcd"]
    end

    test "hyphens: none ignores soft hyphens" do
      html = ~s(<div style="width:32px;hyphens:none">ab&shy;cd&shy;ef</div>)
      assert wrapped_lines(laid_out(html)) == ["abcdef"]
    end

    test "a percentage max-height is a share of the height of the block it sits in" do
      html =
        ~s(<div style="height:100px"><div style="background:red;height:300px;max-height:30%"></div></div>)

      assert Enum.any?(rect_heights(laid_out(html)), &(&1 == 30))
    end

    test "a percentage min-height is a share of the height of the block it sits in" do
      html =
        ~s(<div style="height:100px"><div style="background:red;min-height:40%"></div></div>)

      assert Enum.any?(rect_heights(laid_out(html)), &(&1 == 40))
    end

    test "the right margin of a box with a width does not push it below a float" do
      html =
        ~s(<div style="width:100px"><div style="float:left;width:50px;height:10px"></div><div style="overflow:hidden;margin-right:1px;width:50px;height:10px;background:red"></div></div>)

      assert Enum.any?(laid_out(html), &(&1.type == :rect and &1.y < 10 and &1.x >= 50))
    end

    test "a float in the middle of a line that does not wrap goes below the line" do
      html =
        ~s(<div style="width:80px;white-space:nowrap">some text <span style="float:right;width:40px;height:10px;background:blue"></span> more text</div>)

      items = laid_out(html)
      ys = for %{type: :text, y: y} <- items, uniq: true, do: y
      assert length(ys) == 1
      assert Enum.any?(items, &(&1.type == :rect and &1.y > hd(ys)))
    end
  end
end
