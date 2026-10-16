defmodule Browser.SheetCacheTest do
  # not async: the test clears the shared table
  use ExUnit.Case, async: false
  alias Browser.{SheetCache, Style}

  @b1 "http://one.test/css/main.css"
  @b2 "http://two.test/other/dir/main.css"

  # a sheet above the size limit of the cache, with `extra` at the end
  defp sheet(extra) do
    tag = System.unique_integer([:positive])

    body =
      for i <- 1..300, into: "", do: ".c#{tag}-#{i} { color: red; margin: #{i}px; }\n"

    body <> extra
  end

  # the rules with an empty table (the cache gives nothing) for each base
  defp uncached(css, base) do
    SheetCache.clear()
    rules = Style.parse_sheet(:author, css, base)
    SheetCache.clear()
    rules
  end

  for {name, extra, url?} <- [
        {"no url", ".x { background-image: linear-gradient(red, blue); }", false},
        {"url(", ".x { background-image: url(img/a.png); }", true},
        {"escaped \\75 rl(", ~S".x { background-image: \75 rl(img/a.png); }", false}
      ] do
    test "a cached sheet with #{name} gives the rules of an uncached parse for each base" do
      css = sheet(unquote(extra))
      assert byte_size(css) > 8 * 1024
      off1 = uncached(css, @b1)
      off2 = uncached(css, @b2)

      # (the first parse fills the cache, the others read it)
      assert Style.parse_sheet(:author, css, @b1) == off1
      assert Style.parse_sheet(:author, css, @b2) == off2
      assert Style.parse_sheet(:author, css, @b1) == off1

      if unquote(url?) do
        assert off1 != off2
        assert SheetCache.get({:author, css, {:base, @b1}}) == off1
        assert SheetCache.get({:author, css, nil}) == nil
      else
        assert off1 == off2
        assert SheetCache.get({:author, css, nil}) == off1
      end

      assert Style.parse_sheet(:author, css, nil) == uncached(css, nil)
    end
  end

  test "a sheet with url( parsed without an address first gives the right rules for an address" do
    css = sheet(".x { background-image: url(img/a.png); }")
    off = uncached(css, @b1)
    none = uncached(css, nil)
    assert off != none
    assert Style.parse_sheet(:author, css, nil) == none
    assert Style.parse_sheet(:author, css, @b1) == off
    assert Style.parse_sheet(:author, css, nil) == none
  end

  test "the same text at two addresses with an unnamed @layer gives two layers" do
    css = sheet("@layer { p { color: red } }\n@layer named { p { color: green } }\n")
    sheets = [{:author, css, @b1}, {:author, css, @b2}]
    p = fn -> Style.prune(Browser.HTML.parse("<p>x</p>"), Style.index(sheets)) end

    # (the layers are: unnamed, named, unnamed. The last one wins)
    for _ <- 1..2 do
      [{:element, "p", attrs, _}] = for {:element, "p", _, _} = n <- find(p.()), do: n
      assert {"@computed", %{"color" => {255, 0, 0}}} = List.keyfind(attrs, "@computed", 0)
    end

    assert SheetCache.get({:author, css, nil}) == nil
  end

  # all the elements of `nodes`, at any depth
  defp find(nodes) do
    Enum.flat_map(nodes, fn
      {:element, _, _, kids} = n -> [n | find(kids)]
      _ -> []
    end)
  end

  test "a sheet in the table is not parsed again" do
    plain = sheet("")
    url = sheet(".x { background-image: url(img/a.png); }")
    SheetCache.put({:author, plain, nil}, [:kept])
    SheetCache.put({:author, url, {:base, @b1}}, [:kept])
    assert Style.parse_sheet(:author, plain, @b2) == [:kept]
    assert Style.parse_sheet(:author, url, @b1) == [:kept]
    assert Style.parse_sheet(:author, url, @b2) != [:kept]
  end

  test "the table keeps more than one sheet" do
    [a, b] = for _ <- 1..2, do: sheet("")
    Style.parse_sheet(:author, a, nil)
    Style.parse_sheet(:author, b, nil)
    assert SheetCache.get({:author, a, nil}) != nil
    assert SheetCache.get({:author, b, nil}) != nil
  end

  test "a small sheet does not go into the cache" do
    css = ".small-#{System.unique_integer([:positive])} { color: red }"
    assert [_] = Style.parse_sheet(:author, css, @b1)
    assert SheetCache.get({:author, css, nil}) == nil
  end

  test "the origin is part of the key" do
    css = sheet("")
    author = Style.parse_sheet(:author, css, nil)
    ua = Style.parse_sheet(:ua, css, nil)
    assert Enum.all?(author, &(&1.origin == :author))
    assert Enum.all?(ua, &(&1.origin == :ua))
  end
end
