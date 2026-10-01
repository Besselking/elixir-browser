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
      assert word(items, "right").x > word(items, "left").x + word(items, "left").w

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
      assert inner.color == {221, 221, 221} and inner.h <= 30
    end
  end

  describe "absolute positioning" do
    alias Browser.Page

    defp abs_layout(html, width \\ 400, view_h \\ 600) do
      page = Page.build("<style>body{margin:0} p,div{margin:0}</style>" <> html, "about:home")
      Layout.layout(page.nodes, width, &measure/2, view_h)
    end

    defp wd(items, text), do: Enum.find(items, &(Map.get(&1, :text) == text))

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

    for fixture <- ~w(sample hidden positioning) do
      test "#{fixture}.html lays out on integer pixels" do
        html = File.read!("test/fixtures/#{unquote(fixture)}.html")
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
end
