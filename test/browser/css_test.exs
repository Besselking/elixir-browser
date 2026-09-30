defmodule Browser.CSSTest do
  use ExUnit.Case, async: true
  alias Browser.CSS

  defp ctx(tag, attrs \\ [], opts \\ []) do
    %{
      tag: tag,
      attrs: attrs,
      id: attrs |> List.keyfind("id", 0) |> then(&(&1 && elem(&1, 1))),
      classes: attrs |> List.keyfind("class", 0, {nil, ""}) |> elem(1) |> String.split(),
      parent: opts[:parent],
      prev: opts[:prev] || [],
      first?: Keyword.get(opts, :first?, true),
      last?: Keyword.get(opts, :last?, true)
    }
  end

  defp sel(str) do
    {:ok, %{parts: parts}} = CSS.parse_selector(str)
    parts
  end

  defp sm?(selector, ctx), do: CSS.matches?(sel(selector), ctx)

  test "parses rules, declarations and !important; ignores comments" do
    css =
      "/* c */ p, .a > b { color: red; DISPLAY : none !important ; } @media print { p { x: y } } i{a:b}"

    rules = CSS.parse(css)
    assert length(rules) == 4
    assert hd(rules).decls == [{"color", "red", false}, {"display", "none", true}]
    assert List.last(rules).decls == [{"a", "b", false}]
    assert [_] = Enum.at(rules, 2).media
  end

  test "skips at-rules with blocks and statements" do
    css =
      "@import url(x.css); @font-face { font-family: x; src: url(y) } @keyframes k { from { a: b } } p { d: e }"

    assert [%{decls: [{"d", "e", false}], media: []}] = CSS.parse(css)
  end

  test "enters @supports and @layer, but not negated @supports" do
    css = """
    @supports (display: grid) { a { x: 1 } }
    @supports not (display: grid) { b { x: 2 } }
    @layer base { c { x: 3 } }
    @layer a, b;
    """

    assert [%{decls: [{"x", "1", false}]}, %{decls: [{"x", "3", false}]}] = CSS.parse(css)
  end

  test "nested @media conditions accumulate" do
    css = "@media screen { @media (min-width: 10px) { a { x: y } } b { x: y } }"
    assert [%{media: [_, _]}, %{media: [_]}] = CSS.parse(css)
  end

  test "drops selectors that cannot be evaluated but keeps the rest of the list" do
    rules = CSS.parse("a:hover, b, c::before, d:nth-child(2) { x: y }")
    assert [%{selector: [{%{tag: "b"}, nil}]}] = rules
  end

  test "strings and braces inside values don't break parsing" do
    css = ~s(a { content: "}" ; color: red } b { x: y })
    assert [%{decls: d1}, %{decls: [{"x", "y", false}]}] = CSS.parse(css)
    assert {"color", "red", false} in d1
  end

  test "specificity" do
    assert {:ok, %{spec: {1, 1, 1}}} = CSS.parse_selector("div#a.b")
    assert {:ok, %{spec: {0, 2, 3}}} = CSS.parse_selector("ul li:first-child a[href]")
    assert {:ok, %{spec: {0, 1, 0}}} = CSS.parse_selector(":not(.x)")
    assert {:ok, %{spec: {0, 0, 0}}} = CSS.parse_selector("*")
  end

  test "type, class, id, universal" do
    el = ctx("div", [{"id", "main"}, {"class", "a b"}])
    assert sm?("div", el)
    assert sm?(".a.b", el)
    assert sm?("#main", el)
    assert sm?("*", el)
    assert sm?("div#main.a", el)
    refute sm?("span", el)
    refute sm?(".c", el)
  end

  test "attribute selectors" do
    el =
      ctx("a", [
        {"href", "https://x.org/a.pdf"},
        {"lang", "en-US"},
        {"rel", "nofollow me"},
        {"hidden", ""}
      ])

    assert sm?("[href]", el)
    assert sm?("[hidden]", el)
    assert sm?("[lang|=en]", el)
    assert sm?("[rel~=me]", el)
    assert sm?("[href^='https']", el)
    assert sm?("[href$=\".pdf\"]", el)
    assert sm?("[href*=x]", el)
    assert sm?("[lang=EN-us i]", el)
    refute sm?("[lang=EN-us]", el)
    refute sm?("[title]", el)
  end

  test "combinators" do
    ul = ctx("ul", [{"class", "nav"}])
    li1 = ctx("li", [], parent: ul, first?: true, last?: false)
    li2 = ctx("li", [], parent: ul, prev: [li1], first?: false, last?: true)
    span = ctx("span", [], parent: li2)

    assert sm?("ul span", span)
    assert sm?(".nav li span", span)
    assert sm?("li > span", span)
    refute sm?("ul > span", span)
    assert sm?("li + li", li2)
    refute sm?("li + li", li1)
    assert sm?("li ~ li", li2)
  end

  test "pseudo-classes" do
    html = ctx("html")
    body = ctx("body", [], parent: html)
    assert sm?(":root", html)
    refute sm?(":root", body)
    assert sm?("body:first-child", body)
    assert sm?("body:only-child", body)
    refute sm?("p:last-child", ctx("p", [], last?: false))
    assert sm?("p:not(.x)", ctx("p"))
    refute sm?("p:not(.x)", ctx("p", [{"class", "x"}]))
  end
end
