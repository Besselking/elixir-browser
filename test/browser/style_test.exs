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

  describe "clipping and visibility" do
    test "zero height with overflow hidden removes the subtree" do
      css = ".c { height: 0; overflow: hidden }"
      assert tags(prune(~s(<div class="c"><p>x</p></div><i>y</i>), css)) == ["i"]
    end

    test "two-value overflow shorthand clips if either axis clips" do
      css = ".c { height: 0; opacity: 0; overflow: hidden auto }"
      assert tags(prune(~s(<div class="c"><p>x</p></div>), css)) == []
    end

    test "max-height zero works like height zero" do
      assert tags(prune(~s(<div class="c">x</div>), ".c { max-height: 0px; overflow-y: scroll }")) == []
    end

    test "zero height without clipping keeps the content" do
      assert tags(prune(~s(<div class="c"><p>x</p></div>), ".c { height: 0 }")) == ["div", "p"]
    end

    test "overflow hidden with a non-zero height keeps the content" do
      css = ".c { height: 10px; overflow: hidden }"
      assert tags(prune(~s(<div class="c"><p>x</p></div>), css)) == ["div", "p"]
    end

    defp computed_of(nodes, tag) do
      Enum.find_value(nodes, fn
        {:element, ^tag, attrs, _} -> List.keyfind(attrs, "@computed", 0, {nil, %{}}) |> elem(1)
        {:element, _, _, kids} -> computed_of(kids, tag)
        _ -> nil
      end)
    end

    test "visibility is inherited and can be overridden by descendants" do
      css = ".h { visibility: hidden } .v { visibility: visible }"
      nodes = prune(~s(<div class="h"><p>a</p><b class="v">b</b></div><i>c</i>), css)
      assert computed_of(nodes, "p")["visibility"] == "hidden"
      assert computed_of(nodes, "b")["visibility"] == "visible"
      assert computed_of(nodes, "i") == %{}
    end

    test "inherit keyword takes the parent's value" do
      css = ".h { visibility: hidden } b { visibility: inherit }"
      nodes = prune(~s(<div class="h"><b>b</b></div>), css)
      assert computed_of(nodes, "b")["visibility"] == "hidden"
    end

    test "layout keeps the space of visibility:hidden text but marks it hidden and unclickable" do
      css = ".h { visibility: hidden }"
      nodes = prune(~s(<p>a <a class="h" href="/x">b</a> c</p>), css)
      {items, _} = Browser.Layout.layout(nodes, 400, fn t, _ -> String.length(t) * 7 end)
      b = Enum.find(items, &(&1.text == "b"))
      c = Enum.find(items, &(&1.text == "c"))
      assert b.hidden and b.href == nil
      refute c.hidden
      assert c.x > b.x + b.w
    end
  end

  describe "media queries" do
    @css "p { display: none } @media (min-width: 800px) { p { display: block } }"

    defp prune_at(width, html, css) do
      env = %{type: "screen", width: width, height: 600, dppx: 1.0}
      Style.prune(HTML.parse(html), Style.index([{:author, css}], env))
    end

    test "rules inside @media apply only when the query matches" do
      assert tags(prune_at(1000, "<p>a</p>", @css)) == ["p"]
      assert tags(prune_at(500, "<p>a</p>", @css)) == []
    end

    test "rules nested in @supports and @layer are applied" do
      css = "@supports (display: grid) { @layer x { p { display: none } } }"
      assert tags(prune_at(1000, "<p>a</p><i>b</i>", css)) == ["i"]
    end

    test "Page.restyle only re-cascades when a query result changes" do
      html = "<style>#{@css}</style><p>a</p>"
      env = fn w -> %{type: "screen", width: w, height: 600, dppx: 1.0} end
      page = Page.build(html, "about:home", env.(1000))
      assert tags(page.nodes) |> Enum.count(&(&1 == "p")) == 1

      assert Page.restyle(page, env.(900)) == page
      narrow = Page.restyle(page, env.(500))
      assert tags(narrow.nodes) |> Enum.count(&(&1 == "p")) == 0
      assert Page.restyle(narrow, env.(1000)).nodes == page.nodes
    end
  end
end
