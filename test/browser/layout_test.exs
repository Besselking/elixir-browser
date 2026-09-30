defmodule Browser.LayoutTest do
  use ExUnit.Case, async: true
  alias Browser.{HTML, Layout}

  defp measure(text, style), do: String.length(text) * div(style.size, 2)

  defp run(html, width \\ 400), do: html |> HTML.parse() |> Layout.layout(width, &measure/2)
  defp texts(items), do: for(%{type: :text, text: t} <- items, do: t)

  test "emits words in order and skips script/style/head" do
    {items, _} = run("<head><title>x</title></head><style>a{}</style><p>hello <b>big</b> world</p>")
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
    assert %{size: 28, bold: true} = Enum.find(items, &(&1.text == "T"))
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
end
