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
end
