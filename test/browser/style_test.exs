defmodule Browser.StyleTest do
  use ExUnit.Case, async: true
  alias Browser.{HTML, Page, Style}

  defp prune(html, css \\ "") do
    nodes = HTML.parse(html)
    idx = Style.index([{:ua, Style.ua_css()}, {:author, css}])
    Style.prune(nodes, idx)
  end

  defp tags(nodes) do
    Enum.flat_map(nodes, fn
      {:element, tag, _, kids} -> [tag | tags(kids)]
      _ -> []
    end)
  end

  test "hidden attribute hides an element and its subtree" do
    assert tags(prune("<div><p hidden>x<b>y</b></p><i>z</i></div>")) == ["div", "i"]
  end

  test "input type=hidden is hidden" do
    assert tags(prune(~s(<form><input type="hidden"><input type="text"></form>))) ==
             ["form", "input"]
  end

  test "author display:none by tag, class and id" do
    css = "b { display: none } .gone { display: none } #x { display: none }"
    html = ~s(<p><b>1</b><i class="gone">2</i><u id="x">3</u><s>4</s></p>)
    assert tags(prune(html, css)) == ["p", "s"]
  end

  test "later rule of equal specificity wins; higher specificity wins regardless of order" do
    assert tags(prune("<p>a</p>", "p { display: none } p { display: block }")) == ["p"]
    assert tags(prune(~s(<p class="a">a</p>), ".a { display: none } p { display: block }")) == []
  end

  test "author display overrides the UA [hidden] rule" do
    assert tags(prune("<p hidden>a</p>", "p { display: block }")) == ["p"]
  end

  test "inline style beats stylesheet; !important beats inline" do
    assert tags(prune(~s(<p style="display:none">a</p>), "p { display: block }")) == []
    assert tags(prune(~s(<p style="display:block">a</p>), "p { display: none }")) == ["p"]
    assert tags(prune(~s(<p style="display:block">a</p>), "p { display: none !important }")) == []
  end

  test "descendant and child selectors" do
    css = ".menu li { display: none } .bar > span { display: none }"

    html =
      ~s(<div class="menu"><ul><li>a</li></ul></div><li>b</li>) <>
        ~s(<div class="bar"><span>c</span><p><span>d</span></p></div>)

    assert tags(prune(html, css)) == ["div", "ul", "li", "div", "p", "span"]
  end

  test "sibling combinators and :first-child" do
    css = "h1 + p { display: none } li:first-child { display: none }"
    assert tags(prune("<h1>t</h1><p>a</p><p>b</p>", css)) == ["h1", "p"]
    assert tags(prune("<ul><li>a</li><li>b</li></ul>", css)) == ["ul", "li"]
  end

  test "display value is case-insensitive and trimmed" do
    assert tags(prune("<p>a</p>", "p { display:  NONE }")) == []
  end

  test "sheet_refs finds style elements and stylesheet links, honouring media" do
    nodes =
      HTML.parse("""
      <head>
      <style>p { color: red }</style>
      <link rel="stylesheet" href="/a.css">
      <link rel="stylesheet alternate" href="/b.css">
      <link rel="icon" href="/f.ico">
      <link rel="stylesheet" href="/print.css" media="print">
      <link rel="stylesheet" href="/s.css" media="screen and (min-width: 1px)">
      </head>
      """)

    assert Style.sheet_refs(nodes) ==
             [{:style, "p { color: red }"}, {:link, "/a.css"}, {:link, "/s.css"}]
  end

  test "Page.build applies embedded <style> and returns the title" do
    html = """
    <html><head><title>T</title><style>.x { display: none }</style></head>
    <body><p class="x">gone</p><p>kept</p></body></html>
    """

    page = Page.build(html, "about:home")
    assert page.title == "T"
    assert tags(page.nodes) |> Enum.count(&(&1 == "p")) == 1
  end
end
