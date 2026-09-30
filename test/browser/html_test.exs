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
end
