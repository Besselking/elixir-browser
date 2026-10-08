defmodule Browser.HTMLTest do
  use ExUnit.Case, async: true
  alias Browser.HTML

  test "nests elements and decodes entities" do
    assert [{:element, "p", [], [{:text, "a & b "}, {:element, "b", [], [{:text, "c"}]}]}] =
             HTML.parse("<p>a &amp; b <b>c</b></p>")
  end

  test "aside, figure and fieldset close an open paragraph" do
    for tag <- ~w(aside figure fieldset details) do
      assert [{:element, "p", _, _}, {:element, ^tag, _, _}] =
               HTML.parse("<p>a<#{tag}>b</#{tag}>")
    end
  end

  test "the newline right after <pre> is dropped, except in XML documents" do
    assert [
             {:element, "html", _,
              [_, {:element, "body", _, [{:element, "pre", _, [{:text, "a\nb"}]}]}]}
           ] =
             HTML.parse_document("<pre>\na\nb</pre>")

    assert [
             {:element, "html", _,
              [_, {:element, "body", _, [{:element, "pre", _, [{:text, "\na"}]}]}]}
           ] =
             HTML.parse_document("<pre>\na</pre>", xml: true)
  end

  test "void elements don't swallow siblings" do
    assert [{:element, "p", _, [{:text, "a"}, {:element, "br", [], []}, {:text, "b"}]}] =
             HTML.parse("<p>a<br>b</p>")
  end

  test "parses attributes in all quoting styles" do
    [{:element, "a", attrs, _}] = HTML.parse(~s(<a href="x" id='y' data=z hidden>t</a>))
    assert attrs == [{"href", "x"}, {"id", "y"}, {"data", "z"}, {"hidden", ""}]
  end

  test "unclosed p and li are implicitly closed" do
    assert [{:element, "p", _, _}, {:element, "p", _, _}] = HTML.parse("<p>a<p>b")

    assert [{:element, "ul", _, [{:element, "li", _, _}, {:element, "li", _, _}]}] =
             HTML.parse("<ul><li>a<li>b</ul>")
  end

  test "nested lists keep inner li separate" do
    [{:element, "ul", _, [{:element, "li", _, kids}]}] =
      HTML.parse("<ul><li>a<ul><li>b</ul></ul>")

    assert Enum.any?(kids, &match?({:element, "ul", _, _}, &1))
  end

  test "comments and doctype are dropped, script contents are not parsed" do
    nodes = HTML.parse("<!doctype html><!-- hi --><script>if (a<b) {}</script>x")
    assert [{:element, "script", _, _}, {:text, "x"}] = nodes
  end

  test "stray close tags are ignored" do
    assert [{:text, "a"}, {:text, "b"}] = HTML.parse("a</div>b")
  end

  describe "table parts close each other" do
    defp cells(html) do
      [{:element, "table", _, kids}] = HTML.parse(html)
      kids
    end

    test "unclosed cells and rows" do
      [{:element, "tr", _, tds1}, {:element, "tr", _, tds2}] =
        cells("<table><tr><td>a<td>b<tr><td>c<td>d</table>")

      assert for({:element, "td", _, [{:text, t}]} <- tds1, do: t) == ["a", "b"]
      assert for({:element, "td", _, [{:text, t}]} <- tds2, do: t) == ["c", "d"]
    end

    test "th and td mix, sections close each other" do
      [{:element, "thead", _, [head]}, {:element, "tbody", _, [body]}] =
        cells("<table><thead><tr><th>h1<th>h2<tbody><tr><td>x</table>")

      assert {:element, "tr", _, [{:element, "th", _, _}, {:element, "th", _, _}]} = head
      assert {:element, "tr", _, [{:element, "td", _, _}]} = body
    end

    test "a nested table keeps its own cells" do
      html = "<table><tr><td><table><tr><td>in</table><td>out</table>"
      [{:element, "tr", _, [outer1, outer2]}] = cells(html)
      assert {:element, "td", _, [{:element, "table", _, _}]} = outer1
      assert {:element, "td", _, [{:text, "out"}]} = outer2
    end
  end

  test "decodes the full named entity table" do
    assert [{:text, "a\u00ADb"}] = HTML.parse("a&shy;b")
    assert [{:text, "\u00A9 \u2212 \u{1D504}"}] = HTML.parse("&copy; &minus; &Afr;")
    assert [{:text, "\u2265\u20D2"}] = HTML.parse("&nvge;")
  end

  test "legacy entities decode without a semicolon, unknown ones stay" do
    assert HTML.decode("&amp") == "&"
    assert HTML.decode("&bogus; &#65 &#x42;") == "&bogus; A B"
  end

  describe "whole pages" do
    test "get the html, head and body elements their tags leave out" do
      assert [
               {:element, "html", [],
                [
                  {:element, "head", [], [{:element, "title", [], [text: "t"]}]},
                  {:element, "body", [], [{:element, "p", [], [text: "hi"]}]}
                ]}
             ] = HTML.parse_document("<!DOCTYPE html><title>t</title><p>hi</p>")
    end

    test "keep an explicit body" do
      assert [{:element, "html", [], [{:element, "head", [], []}, {:element, "body", _, _}]}] =
               HTML.parse_document("<html><head></head><body class=a>x</body></html>")
    end

    test "style text loses the CDATA markers of XHTML pages" do
      assert [{:element, "style", [], [text: css]}] =
               HTML.parse("<style><![CDATA[ div { color: red } ]]></style>")

      assert css == " div { color: red } "
    end
  end
end
