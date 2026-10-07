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
      last?: Keyword.get(opts, :last?, true),
      index: Keyword.get(opts, :index, 1),
      count: Keyword.get(opts, :count, 1),
      empty?: Keyword.get(opts, :empty?, false)
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
    rules = CSS.parse("a:hover, b, c::selection, d:nth-child(2), e:is(a b) { x: y }")
    assert Enum.map(rules, fn %{selector: [{c, nil}]} -> c.tag end) == ["a", "b", "d"]
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

  test "state pseudo-classes never match, so :not() of them always does" do
    el = ctx("a", [{"href", "/x"}])
    refute sm?("a:hover", el)
    refute sm?("a:focus", el)
    assert sm?("a:not(:focus)", el)
    assert sm?("a:not(:hover):not(:visited)", el)
    assert sm?("a:link", el)
    refute sm?("span:link", el)
  end

  test ":is(), :where() and :not() take selector lists" do
    el = ctx("p", [{"class", "b"}])
    assert sm?(":is(p, div).b", el)
    assert sm?(":where(.a, .b)", el)
    refute sm?(":is(.a, .c)", el)
    refute sm?("p:not(.a, .b)", el)
    assert sm?("p:not(.a, .c)", el)
    assert {:ok, %{spec: {0, 1, 0}}} = CSS.parse_selector(":is(.a, p)")
    assert {:ok, %{spec: {1, 0, 0}}} = CSS.parse_selector(":is(#a, .b)")
    assert {:ok, %{spec: {0, 0, 0}}} = CSS.parse_selector(":where(#a)")
    assert {:ok, %{spec: {0, 1, 1}}} = CSS.parse_selector("p:not(.x)")
  end

  test ":nth-child and friends" do
    at = fn i, n -> ctx("li", [], index: i, count: n, first?: i == 1, last?: i == n) end

    assert sm?("li:nth-child(2)", at.(2, 5))
    refute sm?("li:nth-child(2)", at.(3, 5))
    assert sm?("li:nth-child(odd)", at.(3, 5))
    refute sm?("li:nth-child(odd)", at.(2, 5))
    assert sm?("li:nth-child(even)", at.(4, 5))
    assert sm?("li:nth-child(2n+1)", at.(5, 5))
    assert sm?("li:nth-child(-n+2)", at.(2, 5))
    refute sm?("li:nth-child(-n+2)", at.(3, 5))
    assert sm?("li:nth-child(n+3)", at.(3, 5))
    refute sm?("li:nth-child(n+3)", at.(2, 5))
    assert sm?("li:nth-last-child(1)", at.(5, 5))
    assert sm?("li:nth-last-child(2)", at.(4, 5))
    assert :error = CSS.parse_selector("li:nth-child(foo)")
  end

  test ":nth-of-type, :first-of-type and :empty" do
    a = ctx("b", [], index: 1, count: 3)
    p = ctx("p", [], index: 2, count: 3, prev: [a])
    p2 = ctx("p", [], index: 3, count: 3, prev: [p, a])
    assert sm?("p:first-of-type", p)
    refute sm?("p:first-of-type", p2)
    assert sm?("p:nth-of-type(2)", p2)
    assert sm?("p:empty", ctx("p", [], empty?: true))
    refute sm?("p:empty", ctx("p"))
  end

  test "::before and ::after (and the one-colon forms) mark the rule as styling a generated box" do
    rules = CSS.parse("a::before, b:after, ::after, c:hover::before { x: y } d { x: y }")
    assert Enum.map(rules, & &1.pseudo) == [:before, :after, :after, :before, nil]
    assert [%{pseudo: :marker}] = CSS.parse("li::marker { content: \"> \" }")
    assert [{%{tag: "a"}, nil}] = hd(rules).selector
    assert [{%{tag: :any}, nil}] = Enum.at(rules, 2).selector
  end

  test ":has() takes relative selectors; ones that can't match are dropped from it" do
    assert {:ok, %{spec: {0, 1, 2}}} = CSS.parse_selector("li:has(a.active)")
    assert {:ok, _} = CSS.parse_selector("li:has(> a, + b, ~ c d)")

    assert {:ok, %{parts: [{%{pseudos: [{:has, []}]}, nil}]}} =
             CSS.parse_selector(":has(a:hover)")
  end

  test "unsupported selectors are still dropped" do
    assert :error = CSS.parse_selector("p::selection")
    assert :error = CSS.parse_selector("p:has(")
    assert :error = CSS.parse_selector("p:is(a b)")
  end

  describe "escapes in selectors" do
    defp classes_of(css) do
      [rule] = CSS.parse(css)
      [{cmp, nil}] = rule.selector
      cmp.classes
    end

    test "backslash-escaped characters in class names" do
      assert classes_of(~S|.text-\[2\.25rem\]{color:red}|) == ["text-[2.25rem]"]
      assert classes_of(~S|.md\:flex{color:red}|) == ["md:flex"]
      assert classes_of(~S|.w-1\/2{color:red}|) == ["w-1/2"]
    end

    test "hex escapes" do
      assert classes_of(~S|.\31 0{color:red}|) == ["10"]
      assert classes_of(~S|.a\2c b{color:red}|) == ["a,b"]
    end

    test "an escaped comma or bracket does not split a selector list" do
      assert [_, _] = CSS.parse(~S|.a\,b, .c\[d\]{color:red}|)
      assert [rule] = CSS.parse(~S|.\[\&\>svg\]\:h-full{color:red}|)
      assert rule.decls == [{"color", "red", false}]
    end

    test "escaped selectors match elements with the plain class" do
      [rule] = CSS.parse(~S|.text-\[2\.25rem\]{font-size:2.25rem}|)

      ctx = %{
        tag: "h1",
        id: nil,
        classes: ["text-[2.25rem]"],
        attrs: [],
        parent: nil,
        prev: [],
        index: 0,
        count: 1
      }

      assert CSS.matches?(rule.selector, ctx)
    end
  end

  describe "@supports conditions" do
    test "and, or, not and nested groups" do
      assert CSS.supports?("(display: grid) and (color: red)")
      assert CSS.supports?("(display: grid) or (--a: b)")
      refute CSS.supports?("not (display: grid)")
      refute CSS.supports?("(display: grid) and (not (color: red))")
    end

    test "unknown properties and bad names are not supported" do
      refute CSS.supports?("(nope: 1)")
      refute CSS.supports?("(--: a)")
      assert CSS.supports?("(--a: a)")
      assert CSS.supports?("(-webkit-box-orient: vertical)")
    end

    test "var() needs a clean fallback and braces may nest in values" do
      assert CSS.supports?("(color: var(--a))")
      assert CSS.supports?("(color: { [ var(--a) ] })")
      refute CSS.supports?("(color: var(--a,!))")
      refute CSS.supports?("(color: var(--a) !important !important)")
    end

    test "selector() and a prelude with braces" do
      assert CSS.supports?("selector(a > b)")
      refute CSS.supports?("selector(a >)")

      css =
        "@supports (color: { [ var(--a) ] }) { p { x: 1 } } @supports (nope: 1) { q { x: 2 } }"

      assert [%{decls: [{"x", "1", false}]}] = CSS.parse(css)
    end
  end

  describe "custom property declarations" do
    test "names are case-sensitive and may be escaped" do
      css = "p { --Ab: 1; --\\61 : 2; -\\2d c: 3; --: 4; --d: 5 !important !important }"

      assert [%{decls: [{"--Ab", "1", false}, {"--a", "2", false}, {"--c", "3", false}]}] =
               CSS.parse(css)
    end

    test "unbalanced brackets drop the declaration" do
      assert [%{decls: [{"--a", "ok", false}]}] = CSS.parse("p { --a: ok; --b: red) }")
    end
  end
end
