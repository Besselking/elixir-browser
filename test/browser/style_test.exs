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
      assert tags(prune(~s(<div class="c">x</div>), ".c { max-height: 0px; overflow-y: scroll }")) ==
               []
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
      refute Map.has_key?(computed_of(nodes, "i"), "visibility")
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

  describe "computed values" do
    defp comp(html, css, tag) do
      nodes = prune(html, css)
      Enum.find_value([nodes], fn n -> computed_of(n, tag) end)
    end

    test "color and font-size inherit; em resolves against the parent" do
      css = "div { color: #ff0000; font-size: 20px } span { font-size: 0.5em }"
      html = "<div><b>x</b><span>y</span></div>"
      assert comp(html, css, "b")["color"] == {255, 0, 0}
      assert comp(html, css, "b")["font-size"] == 20.0
      assert comp(html, css, "span")["font-size"] == 10.0
    end

    test "rem uses the root font size; keywords and percentages" do
      css =
        "html { font-size: 10px } p { font-size: 2rem } i { font-size: 150% } u { font-size: large }"

      html = "<html><body><p>a<i>b</i></p><u>c</u></body></html>"
      assert comp(html, css, "p")["font-size"] == 20.0
      assert comp(html, css, "i")["font-size"] == 30.0
      assert comp(html, css, "u")["font-size"] == 18.0
    end

    test "UA defaults: headings, links, bold, monospace" do
      html = ~s(<h2>a</h2><a href="/x">b</a><b>c</b><code>d</code>)
      assert comp(html, "", "h2")["font-size"] == 24.0
      assert comp(html, "", "h2")["font-weight"] == "bold"
      assert comp(html, "", "a")["color"] == {0, 0, 238}
      assert comp(html, "", "a")["text-decoration-line"] == "underline"
      assert comp(html, "", "b")["font-weight"] == "bold"
      assert comp(html, "", "code")["font-family"] == "monospace"
    end

    test "author rules override UA defaults" do
      css = "a { text-decoration: none; color: green } b { font-weight: 400 }"
      html = ~s(<a href="/x">a</a><b>b</b>)
      assert comp(html, css, "a")["text-decoration-line"] == "none"
      assert comp(html, css, "a")["color"] == {0, 128, 0}
      assert comp(html, css, "b")["font-weight"] == "normal"
    end

    test "margin and padding shorthands expand to px, auto is zero" do
      css = "p { margin: 1em 2px 3px; padding: 4px 8px } div { margin: 0 auto }"
      c = comp("<p>a</p><div>b</div>", css, "p")
      assert {c["margin-top"], c["margin-bottom"], c["margin-left"]} == {16.0, 3.0, 2.0}
      assert {c["padding-top"], c["padding-left"]} == {4.0, 8.0}
      d = comp("<p>a</p><div>b</div>", css, "div")
      assert {d["margin-top"], d["margin-left"]} == {0.0, 0.0}
    end

    test "longhand after shorthand wins, shorthand after longhand wins" do
      css = "p { margin: 10px; margin-top: 1px } div { margin-top: 1px; margin: 10px }"
      html = "<p>a</p><div>b</div>"
      assert comp(html, css, "p")["margin-top"] == 1.0
      assert comp(html, css, "div")["margin-top"] == 10.0
    end

    test "background shorthand extracts the color" do
      css = "p { background: #eee url(x.png) no-repeat } div { background: none }"
      assert comp("<p>a</p><div>b</div>", css, "p")["background-color"] == {238, 238, 238}
      assert comp("<p>a</p><div>b</div>", css, "div")["background-color"] == :transparent
    end

    test "font shorthand" do
      css = "p { font: italic bold 12px/1.5 Arial, sans-serif }"
      c = comp("<p>a</p>", css, "p")
      assert {c["font-style"], c["font-weight"], c["font-size"]} == {"italic", "bold", 12.0}
      assert c["font-family"] == "arial, sans-serif"
    end

    test "custom properties: declared, inherited, fallback, nested" do
      css = """
      :root { --brand: #0000ff; --alias: var(--brand); --pad: 6px }
      p { color: var(--alias); padding: var(--pad) 2px; margin-top: var(--missing, 7px) }
      div { --brand: #00ff00 }
      i { color: var(--brand) }
      b { color: var(--nope) }
      """

      html = "<html><body><p>a</p><div><i>b</i></div><b>c</b></body></html>"
      p = comp(html, css, "p")
      assert p["color"] == {0, 0, 255}
      assert {p["padding-top"], p["padding-left"], p["margin-top"]} == {6.0, 2.0, 7.0}
      assert comp(html, css, "i")["color"] == {0, 255, 0}
      # unresolvable var() drops the declaration (color falls back to the inherited black)
      assert comp(html, css, "b")["color"] == {0, 0, 0}
    end

    test "custom properties inside var() with nested fallback" do
      css = "p { color: var(--a, var(--b, red)) }"
      assert comp("<p>a</p>", css, "p")["color"] == {255, 0, 0}
    end

    test "currentcolor and inherit" do
      css =
        "div { color: #00f } p { background-color: currentcolor; margin-top: inherit } div { margin-top: 9px }"

      c = comp("<div><p>a</p></div>", css, "p")
      assert c["background-color"] == {0, 0, 255}
      assert c["margin-top"] == 9.0
    end

    test "list-style shorthand and inheritance" do
      css = "ul { list-style: none }"
      assert comp("<ul><li><b>a</b></li></ul>", css, "b")["list-style-type"] == "none"
    end

    test "text-align is inherited" do
      assert comp("<div style=\"text-align:center\"><p>a</p></div>", "", "p")["text-align"] ==
               "center"
    end
  end

  describe "visually hidden patterns" do
    @sr_only_cases [
      {"clip rect 1px", "position:absolute; clip: rect(1px, 1px, 1px, 1px)"},
      {"clip rect zero, spaces", "position:absolute; clip: rect(0 0 0 0)"},
      {"clip-path inset 50%", "position:absolute; clip-path: inset(50%)"},
      {"clip-path circle 0", "position:fixed; clip-path: circle(0)"},
      {"1x1 clipped box", "width:1px; height:1px; overflow:hidden"},
      {"offscreen left", "position:absolute; left:-9999px"},
      {"offscreen top, relative", "position:relative; top:-10000px"},
      {"far right", "position:absolute; left:100000px"},
      {"zero width clip", "width:0; overflow:hidden"},
      {"text-indent image replacement", "text-indent:-9999px; overflow:hidden"}
    ]

    for {name, decls} <- @sr_only_cases do
      test "#{name} is not rendered" do
        assert tags(prune(~s(<p style="#{unquote(decls)}">x</p><i>y</i>))) == ["i"]
      end
    end

    test "a visible absolutely positioned element is kept" do
      assert tags(prune(~s(<p style="position:absolute; top:10px; left:5px">x</p>))) == ["p"]
    end

    test "clip without positioning, a normal clip rect and clip: auto are kept" do
      assert tags(prune(~s|<p style="clip: rect(1px,1px,1px,1px)">x</p>|)) == ["p"]

      assert tags(prune(~s|<p style="position:absolute; clip: rect(0,10px,10px,0)">x</p>|)) == [
               "p"
             ]

      assert tags(prune(~s(<p style="position:absolute; clip: auto">x</p>))) == ["p"]
    end

    test ":not(:focus) skip-link pattern" do
      css =
        ".skip:not(:focus) { position: absolute !important; clip: rect(1px,1px,1px,1px); width: 1px; height: 1px; overflow: hidden }"

      assert tags(prune(~s(<a class="skip" href="#c">Jump</a><i>y</i>), css)) == ["i"]
    end

    test "opacity zero keeps the space but hides painting" do
      nodes = prune(~s(<p style="opacity:0">x</p>))
      assert computed_of(nodes, "p")["visibility"] == "hidden"
      assert computed_of(prune(~s(<p style="opacity:.5">x</p>)), "p")["visibility"] == nil
    end

    test "sizes and offsets are typed: px, percentages, auto is absent" do
      html =
        ~s(<p style="position:absolute; top:5px; left:10%; width:2em; height:auto; max-height:none">x</p>)

      c = computed_of(prune(html), "p")
      assert {c["top"], c["left"], c["width"]} == {5.0, {:pct, 0.1}, 32.0}
      refute Map.has_key?(c, "height")
      refute Map.has_key?(c, "max-height")
      assert c["position"] == "absolute"
    end
  end
end
