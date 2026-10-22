defmodule Browser.CountersTest do
  use ExUnit.Case, async: true
  alias Browser.{Counters, Layout, Page}

  defp measure(text, style), do: String.length(text) * div(style.size, 2)

  defp words(html) do
    page = Page.build("<style>body{margin:0} li{list-style:none}</style>" <> html, "about:home")
    {items, _} = Layout.layout(page.nodes, 400, &measure/2)
    for %{type: :text, text: t} <- items, do: t
  end

  test "counter() numbers the elements in document order" do
    css =
      "<style>body{counter-reset:n} h2::before{counter-increment:n;content:counter(n) '. '}</style>"

    assert words(css <> "<h2>A</h2><h2>B</h2><h2>C</h2>") == ["1.", "A", "2.", "B", "3.", "C"]
  end

  test "counters() joins the nested counters, and a reset on a sibling starts over" do
    css =
      "<style>ol{counter-reset:item} li{counter-increment:item} li::before{content:counters(item, '.') ' '}</style>"

    html = "<ol><li>a<ol><li>b</li><li>c</li></ol></li><li>d</li></ol>"
    assert words(css <> html) == ["1", "a", "1.1", "b", "1.2", "c", "2", "d"]
  end

  test "counter styles and a start value" do
    css =
      "<style>div{counter-reset:x 4} p{counter-increment:x 2} p::before{content:counter(x, upper-roman) ' ' counter(x, lower-alpha) ' '}</style>"

    assert words(css <> "<div><p>a</p><p>b</p></div>") == ["VI", "f", "a", "VIII", "h", "b"]
  end

  test "counter-set and the text without a counter" do
    css = "<style>p::before{content:counter(k) ' '} .s{counter-set:k 7}</style>"
    assert words(css <> "<p>a</p><p class=s>b</p>") == ["0", "a", "7", "b"]
  end

  test "number formats" do
    assert Counters.format(27, "lower-alpha") == "aa"
    assert Counters.format(1994, "upper-roman") == "MCMXCIV"
    assert Counters.format(5, "decimal-leading-zero") == "05"
  end
end
