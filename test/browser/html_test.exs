defmodule Browser.HTMLTest do
  use ExUnit.Case, async: true
  alias Browser.HTML

  test "nests elements and decodes entities" do
    assert [{:element, "p", [], [{:text, "a & b "}, {:element, "b", [], [{:text, "c"}]}]}] =
             HTML.parse("<p>a &amp; b <b>c</b></p>")
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
end
