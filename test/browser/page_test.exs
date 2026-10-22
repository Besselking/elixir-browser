defmodule Browser.PageTest do
  use ExUnit.Case, async: true
  alias Browser.Page

  @dir Path.expand("../../priv/demo/images", __DIR__)

  defp texts(nodes) do
    Enum.flat_map(nodes, fn
      {:text, t} -> [t]
      {:element, _, _, kids} -> texts(kids)
    end)
  end

  describe "document/2" do
    test "markup is shown as it is" do
      assert Page.document("<p>hi</p>", "http://x.test/") == "<p>hi</p>"
      assert Page.document("plain text with é", "http://x.test/") == "plain text with é"
    end

    test "a picture becomes a page that shows it" do
      png = File.read!(Path.join(@dir, "badge.png"))
      html = Page.document(png, "http://x.test/pics/a&b.png")
      assert html =~ ~s(<img src="http://x.test/pics/a&amp;b.png")
      assert html =~ "<title>a&amp;b.png</title>"
    end

    test "other binary files are explained instead of dumped" do
      html = Page.document(<<0, 1, 2, 3, "PK">>, "http://x.test/archive.zip")
      assert html =~ "This file can't be shown"
      assert html =~ "6 bytes"
      refute html =~ <<0>>
    end

    test "a NUL after the first kilobyte doesn't make text binary" do
      body = String.duplicate("a", 2000) <> <<0>>
      assert Page.document(body, "http://x.test/") == body
    end
  end

  describe "load/3" do
    test "loading a picture file gives an image page with the picture to fetch" do
      url = "file://" <> Path.join(@dir, "photo.jpg")
      assert {:ok, page} = Page.load(url)
      assert page.image_urls == [url]
      assert page.title == "photo.jpg"
    end

    test "loading a binary file gives the explanation page" do
      path = Path.join(System.tmp_dir!(), "page_test_#{System.unique_integer([:positive])}.bin")
      File.write!(path, <<0, 0, 0, 0>>)
      assert {:ok, page} = Page.load("file://" <> path)
      assert Enum.any?(texts(page.nodes), &(&1 =~ "binary file"))
      File.rm!(path)
    end

    test "errors pass through" do
      assert {:error, _} = Page.load("file:///no/such/file.html")
    end
  end

  describe "all_image_urls/1" do
    @url "http://h.test/dir/p.html"

    test "includes background images from style elements, style attributes and external rules" do
      html = """
      <html><head><style>body { background: url(bg.png) } .x { background-image: linear-gradient(red, blue), url("/deep/y.png") }</style></head>
      <body><img src="a.png"><div class="x">t</div>
      <div style="background: url('inline.png')">u</div></body></html>
      """

      page = Page.build(html, @url)

      assert Page.all_image_urls(page) |> Enum.sort() ==
               Enum.sort([
                 "http://h.test/dir/a.png",
                 "http://h.test/dir/bg.png",
                 "http://h.test/deep/y.png",
                 "http://h.test/dir/inline.png"
               ])
    end

    test "no duplicates, and nothing for pages without pictures" do
      page =
        Page.build(
          ~s|<style>p { background: url(a.png) }</style><p>x</p><img src="a.png"><p>y</p>|,
          @url
        )

      assert Page.all_image_urls(page) == ["http://h.test/dir/a.png"]
      assert Page.all_image_urls(Page.build("<p>no pictures</p>", @url)) == []
    end

    test "backgrounds that only apply at some widths follow the media queries" do
      html =
        "<style>@media (min-width: 800px) { p { background-image: url(wide.png) } }</style><p>x</p>"

      narrow = Page.build(html, @url, %{type: "screen", width: 500, height: 600, dppx: 1.0})
      wide = Page.restyle(narrow, %{type: "screen", width: 1000, height: 600, dppx: 1.0})
      assert Page.all_image_urls(narrow) == []
      assert Page.all_image_urls(wide) == ["http://h.test/dir/wide.png"]
    end
  end

  describe "restyling" do
    @narrow %{type: "screen", width: 500, height: 600, dppx: 1.0}
    @wide %{type: "screen", width: 1000, height: 600, dppx: 1.0}
    @html "<style>@media (min-width: 800px) { p { color: red } }</style><p>x</p>"

    test "a size seen before comes from the cache with the same result" do
      narrow = Page.build(@html, @url, @narrow)
      wide = Page.restyle(narrow, @wide)
      assert map_size(wide.style_cache) == 2
      back = Page.restyle(wide, @narrow)
      assert back.nodes == narrow.nodes
      assert Page.restyle(back, @wide).nodes == wide.nodes
      assert map_size(back.style_cache) == 2
    end

    test "every render is a new version of the page" do
      page = Page.build(@html, @url, @narrow)
      assert page.ver != nil
      assert Page.render(page, page.form_state).ver != page.ver
      assert Page.restyle(page, @wide).ver != page.ver
    end
  end

  describe "from_raw/3" do
    test "indexes the controls again and keeps the values written into the tree" do
      page = Page.build(~s|<input value=a><p>x</p>|, @url, @narrow)
      assert map_size(page.forms.controls) == 1

      raw = [
        {:element, "input", [{"value", "typed"}], []},
        {:element, "p", [], [{:text, "changed"}]},
        {:element, "input", [{"type", "checkbox"}, {"checked", ""}], []}
      ]

      changed = Page.from_raw(page, raw, @narrow)
      assert map_size(changed.forms.controls) == 2
      assert changed.forms.controls[0].value == "typed"
      assert changed.forms.controls[1].checked
      assert changed.form_state == %{}
      assert changed.ver != page.ver
    end

    test "scripts? looks for a script element" do
      assert Page.scripts?(Page.build("<script>1</script>", @url))
      refute Page.scripts?(Page.build("<p>no</p>", @url))
    end

    test "scripts? is true for an iframe with a srcdoc or a src" do
      assert Page.scripts?(Page.build("<iframe srcdoc='<p>x</p>'></iframe>", @url))
      assert Page.scripts?(Page.build("<div><iframe src='a.html'></iframe></div>", @url))
      refute Page.scripts?(Page.build("<iframe></iframe>", @url))
      refute Page.scripts?(Page.build("<iframe src='about:blank'></iframe>", @url))
    end
  end

  describe "viewport units" do
    defp page_height(page), do: div_height(page.nodes)

    defp div_height(nodes) do
      Enum.find_value(nodes, fn
        {:element, "div", attrs, _} ->
          attrs |> List.keyfind("@computed", 0) |> elem(1) |> Map.get("height")

        {:element, _, _, kids} ->
          div_height(kids)

        _ ->
          nil
      end)
    end

    test "restyle follows the window size, only for pages that use them" do
      html = ~s|<body style="margin:0"><div style="height: 50vh">x</div></body>|
      env = fn w, h -> %{type: "screen", width: w, height: h, dppx: 1.0} end
      page = Page.build(html, "about:home", env.(800, 600))
      assert page.viewport_units
      assert page_height(Page.restyle(page, env.(800, 400))) == 200.0

      plain = Page.build("<div>x</div>", "about:home", env.(800, 600))
      refute plain.viewport_units
      assert Page.restyle(plain, env.(800, 400)) == plain
    end

    test "a new style attribute with viewport units makes restyle follow the window size" do
      env = fn w, h -> %{type: "screen", width: w, height: h, dppx: 1.0} end
      page = Page.build(~s|<body style="margin:0"><p>x</p></body>|, "about:home", env.(800, 600))
      refute page.viewport_units

      # a script adds the element and no sheet: the sheets of the tree are the same
      html = ~s|<body style="margin:0"><p>x</p><div style="height: 50vh">x</div></body>|
      raw = Page.build(html, "about:home", env.(800, 600)).raw
      page = Page.from_raw(page, raw, env.(800, 600))
      assert page.viewport_units
      assert page_height(page) == 300.0
      assert page_height(Page.restyle(page, env.(800, 400))) == 200.0
    end
  end

  describe "base href" do
    test "relative addresses resolve against it" do
      html = ~s|<head><base href="/"><img src="a.png"></head><body><img src="b/c.png"></body>|

      page =
        Page.build(html, "http://t.test/x/y/page", %{
          type: "screen",
          width: 800,
          height: 600,
          dppx: 1.0
        })

      assert page.base == "http://t.test/"
      assert page.url == "http://t.test/x/y/page"
      assert "http://t.test/a.png" in page.image_urls
      assert "http://t.test/b/c.png" in page.image_urls
    end

    test "without one, the page's own address is the base" do
      page =
        Page.build("<p>x</p>", "http://t.test/x/y", %{
          type: "screen",
          width: 800,
          height: 600,
          dppx: 1.0
        })

      assert page.base == "http://t.test/x/y"
    end
  end

  describe "incremental restyle" do
    @env %{type: "screen", width: 800, height: 600, dppx: 1.0}

    @html """
    <style>
      .on .x { color: red } .on + .b { color: blue } li:last-child { color: green }
      .on { font-size: 20px } .on span { font-weight: bold }
    </style>
    <div class="a" id="a"><p class="x">one</p><span class="x">two</span></div>
    <div class="b" id="b"><p class="x">three</p></div>
    <ul><li>1</li><li>2</li></ul>
    """

    defp set_attr(nodes, id, name, value) when is_list(nodes),
      do: Enum.map(nodes, &set_attr(&1, id, name, value))

    defp set_attr({:element, tag, attrs, kids}, id, name, value) do
      attrs =
        if {"id", id} in attrs,
          do: List.keystore(attrs, name, 0, {name, value}),
          else: attrs

      {:element, tag, attrs, set_attr(kids, id, name, value)}
    end

    defp set_attr(other, _, _, _), do: other

    test "a changed tree styles the same as a fresh one" do
      page = Page.build(@html, "about:x", @env)

      for {id, name, value} <- [
            {"a", "class", "a on"},
            {"b", "class", "b on"},
            {"a", "style", "color: pink"},
            {"b", "hidden", ""}
          ] do
        raw = set_attr(page.raw, id, name, value)
        fresh = Page.from_raw(%{page | memo: nil}, raw, @env)
        incremental = Page.from_raw(page, raw, @env)
        assert incremental.pruned == fresh.pruned
        assert incremental.pruned != page.pruned
        # and once more from the result
        assert Page.from_raw(incremental, raw, @env).pruned == fresh.pruned
      end
    end

    @hosts """
    <style>p { color: red } x-a { margin-left: 3px }</style>
    <x-a id="h1"><div><p>one</p></div></x-a>
    <x-a id="h2"><div><p>two</p></div></x-a>
    <section id="s"><div><p>three</p></div></section>
    <div id="end"></div>
    """

    defp edit(nodes, id, fun) when is_list(nodes), do: Enum.map(nodes, &edit(&1, id, fun))

    defp edit({:element, tag, attrs, kids} = el, id, fun) do
      if {"id", id} in attrs, do: fun.(el), else: {:element, tag, attrs, edit(kids, id, fun)}
    end

    defp edit(other, _id, _fun), do: other

    # the element gets a shadow tree called `name` with `kids` in front of its own
    defp shadow(raw, id, name, kids),
      do:
        edit(raw, id, fn {:element, tag, attrs, old} ->
          {:element, tag, attrs ++ [{"data-b-frame", name}], kids ++ old}
        end)

    defp append(raw, id, kids),
      do: edit(raw, id, fn {:element, tag, attrs, old} -> {:element, tag, attrs, old ++ kids} end)

    defp style(css), do: {:element, "style", [], [{:text, css}]}
    defp para(text), do: {:element, "div", [], [{:element, "p", [], [{:text, text}]}]}

    # the computed style of the `<p>` with the text `text`
    defp p_style(nodes, text) when is_list(nodes), do: Enum.find_value(nodes, &p_style(&1, text))
    defp p_style({:element, "p", attrs, [{:text, text}]}, text), do: Map.new(attrs)["@computed"]
    defp p_style({:element, _, _, kids}, text), do: p_style(kids, text)
    defp p_style(_other, _text), do: nil

    # whether the memo entry of the `<p>` with the text `text` is the one `before` had
    defp memo_kept?(before, later, text) do
      [{:element, _, attrs, _}] = find_p(before.raw, text)

      {_, nid} = List.keyfind(attrs, "@nid", 0)
      {_, old} = before.memo
      {_, new} = later.memo
      :erts_debug.same(Map.fetch!(old, nid), Map.fetch!(new, nid))
    end

    defp find_p(nodes, text) when is_list(nodes), do: Enum.flat_map(nodes, &find_p(&1, text))
    defp find_p({:element, "p", _, [{:text, text}]} = p, text), do: [p]
    defp find_p({:element, _, _, kids}, text), do: find_p(kids, text)
    defp find_p(_other, _text), do: []

    # (`h1` has a shadow tree with a sheet, `h2` one with no sheet)
    defp hosts_page do
      page = Page.build(@hosts, "about:x", @env)

      raw =
        page.raw
        |> shadow("h1", "s1", [style("p { font-size: 30px }"), para("in1")])
        |> shadow("h2", "s2", [para("in2")])

      Page.from_raw(page, raw, @env)
    end

    defp assert_fresh(page, raw) do
      fresh = Page.from_raw(%{page | memo: nil}, raw, @env)
      incremental = Page.from_raw(page, raw, @env)
      assert incremental.pruned == fresh.pruned
      assert incremental.nodes == fresh.nodes
      incremental
    end

    test "a new shadow tree with sheets keeps the memo, and styles as a fresh tree" do
      page = hosts_page()
      css = "@media (min-width: 500px) { p { color: blue } } :host { padding-left: 5px }"
      raw = append(page.raw, "end", [{:element, "x-a", [{"id", "h3"}], []}])
      page = Page.from_raw(page, raw, @env)
      raw = shadow(page.raw, "h3", "s3", [style(css), para("in3")])

      incremental = assert_fresh(page, raw)
      assert memo_kept?(page, incremental, "three")
      assert p_style(incremental.pruned, "in3")["color"] == {0, 0, 255}
      assert p_style(incremental.pruned, "three")["color"] == {255, 0, 0}
    end

    test "a new sheet in a shadow tree that was there makes a new memo" do
      page = hosts_page()

      for {id, text} <- [{"h1", "in1"}, {"h2", "in2"}] do
        raw = append(page.raw, id, [style("p { color: blue }")])
        incremental = assert_fresh(page, raw)
        refute memo_kept?(page, incremental, "three")
        assert p_style(incremental.pruned, text)["color"] == {0, 0, 255}
      end
    end

    test "a new sheet of the page makes a new memo" do
      page = hosts_page()
      raw = append(page.raw, "end", [style("p { color: blue }")])
      incremental = assert_fresh(page, raw)
      refute memo_kept?(page, incremental, "three")
      assert p_style(incremental.pruned, "three")["color"] == {0, 0, 255}
    end

    test "a new shadow tree with @property or a cascade layer makes a new memo" do
      page = hosts_page()
      raw = append(page.raw, "end", [{:element, "x-a", [{"id", "h3"}], []}])
      page = Page.from_raw(page, raw, @env)

      for css <- [
            "@property --w { syntax: \"*\"; inherits: true; initial-value: 4px } p { color: blue }",
            "@layer base { p { color: blue } }"
          ] do
        raw = shadow(page.raw, "h3", "s3", [style(css), para("in3")])
        incremental = assert_fresh(page, raw)
        refute memo_kept?(page, incremental, "three")
      end
    end

    test "a kept memo holds only for the media query results it was made with" do
      page = hosts_page()
      wide = "@media (min-width: 500px) { p { color: green } }"
      raw = append(page.raw, "end", [style(wide), {:element, "x-a", [{"id", "h3"}], []}])
      page = Page.from_raw(page, raw, @env)
      css = "@media (max-width: 500px) { p { color: blue } }"
      raw = shadow(page.raw, "h3", "s3", [style(css), para("in3")])
      narrow = %{@env | width: 400}
      incremental = Page.from_raw(page, raw, narrow)
      assert incremental.pruned == Page.from_raw(%{page | memo: nil}, raw, narrow).pruned
      assert p_style(incremental.pruned, "three")["color"] == {255, 0, 0}
      assert p_style(incremental.pruned, "in3")["color"] == {0, 0, 255}
      # (at the width the memo was made for, it is kept)
      assert memo_kept?(page, assert_fresh(page, raw), "three")
    end

    test "a page can be sent to another process" do
      page = Page.build(@html, "about:x", @env)
      me = self()
      spawn(fn -> send(me, {:page, page}) end)
      assert_receive {:page, ^page}, 1000
    end

    # A layout for the scripts starts in a process of its own from `layout_base/2`. The memo goes
    # with the base only when the tree has the same sheets: else `from_raw/4` does not use it.
    test "the base of a layout keeps the memo only for a tree with the same sheets" do
      page = Page.build(@html, "about:x", @env)
      assert page.memo != nil

      same = set_attr(page.raw, "a", "class", "a on")
      {base, refs} = Page.layout_base(page, same)
      assert base.memo == page.memo
      assert {base.raw, base.nodes, base.pruned} == {nil, nil, nil}

      assert Page.from_raw(base, same, @env, refs).pruned ==
               Page.from_raw(page, same, @env).pruned

      other = same ++ [{:element, "style", [], [{:text, ".b { color: teal }"}]}]
      {base, refs} = Page.layout_base(page, other)
      assert base.memo == nil
      laid = Page.from_raw(base, other, @env, refs)
      assert laid.pruned == Page.from_raw(%{page | memo: nil}, other, @env).pruned
      assert laid.sheet_refs == refs
    end

    # A layout for the scripts sends its style state back. When the tree kept the sheets of the
    # base, the rules and the parsed sheets are not in it: the receiver keeps its own.
    test "a style state of a tree with the sheets of its base has no rules, and the receiver keeps its own" do
      page = Page.build(@html, "about:x", @env)
      raw = set_attr(page.raw, "a", "class", "a on")
      {base, refs} = Page.layout_base(page, raw)
      laid = Page.from_raw(base, raw, @env, refs)
      state = Page.style_state(laid, base)
      assert Map.keys(state) |> Enum.sort() == [:memo, :sheet_refs, :viewport_units]

      adopted = Page.adopt_style_state(page, state)
      assert :erts_debug.same(adopted.rules, page.rules)
      assert adopted.sheet_cache == page.sheet_cache
      assert adopted.memo == laid.memo

      # (the next tree styles from it as a fresh tree)
      raw = set_attr(raw, "b", "class", "b on")

      assert Page.from_raw(adopted, raw, @env).pruned ==
               Page.from_raw(%{page | memo: nil}, raw, @env).pruned
    end

    test "a style state of a tree with other sheets has the rules again" do
      page = Page.build(@html, "about:x", @env)
      other = page.raw ++ [{:element, "style", [], [{:text, ".b { color: teal }"}]}]
      {base, refs} = Page.layout_base(page, other)
      laid = Page.from_raw(base, other, @env, refs)
      state = Page.style_state(laid, base)
      assert state.rules == laid.rules
      assert state.sheet_refs == refs

      adopted = Page.adopt_style_state(page, state)
      assert {adopted.rules, adopted.sheet_refs, adopted.memo} == {laid.rules, refs, laid.memo}

      # A state without the rules does not go into a page with other sheets: its memo was made
      # with other rules. (The page that the session has may have changed since the run started)
      raw = set_attr(page.raw, "a", "class", "a on")
      {base, refs} = Page.layout_base(page, raw)
      slim = Page.style_state(Page.from_raw(base, raw, @env, refs), base)
      refute Map.has_key?(slim, :rules)
      assert Page.adopt_style_state(adopted, slim) == adopted
    end

    # The sheets of two pages differ only in the text of one `<style>`: a state without the rules
    # of the one does not go into the other (its memo was made with other rules)
    test "a style state without the rules does not go into a page whose sheet has other text" do
      red = Page.build(~s(<style>p { color: red }</style><p id="a">x</p>), "about:x", @env)
      blue = Page.build(~s(<style>p { color: blue }</style><p id="a">x</p>), "about:x", @env)
      raw = set_attr(red.raw, "a", "class", "on")
      {base, refs} = Page.layout_base(red, raw)
      slim = Page.style_state(Page.from_raw(base, raw, @env, refs), base)
      refute Map.has_key?(slim, :rules)
      assert slim.sheet_refs != blue.sheet_refs
      assert Page.adopt_style_state(blue, slim) == blue
      assert Page.adopt_style_state(red, slim).memo == slim.memo
    end

    # (a new shadow tree with its own sheet: `from_raw/4` can keep the memo, so the base has it)
    test "the base of a layout keeps the memo when only a new shadow tree adds a sheet" do
      page = hosts_page()

      page =
        Page.from_raw(
          page,
          append(page.raw, "end", [{:element, "x-a", [{"id", "h3"}], []}]),
          @env
        )

      raw = shadow(page.raw, "h3", "s3", [style("p { color: blue }"), para("in3")])
      {base, refs} = Page.layout_base(page, raw)
      assert base.memo == page.memo
      laid = Page.from_raw(base, raw, @env, refs)
      assert laid.pruned == Page.from_raw(%{page | memo: nil}, raw, @env).pruned
      assert memo_kept?(page, laid, "three")
    end
  end

  describe "fragments" do
    test "the top of the element a fragment names" do
      html =
        ~s|<body><div style="height: 300px">top</div><h2 id="sponsors">Sponsors</h2><a name="old">x</a></body>|

      env = %{type: "screen", width: 800, height: 600, dppx: 1.0}
      page = Page.build(html, "http://t.test/", env)
      measure = fn text, style -> String.length(text) * style.size * 0.5 end
      {items, _} = Browser.Layout.layout(page.nodes, 800, measure, 600)
      rects = Browser.Nids.rects(items, Browser.Nids.parents(page.pruned))

      assert Browser.Nids.anchor_y(page.pruned, rects, "sponsors") > 250

      assert Browser.Nids.anchor_y(page.pruned, rects, "old") >
               Browser.Nids.anchor_y(page.pruned, rects, "sponsors")

      assert Browser.Nids.anchor_y(page.pruned, rects, "nothing") == nil
    end

    test "scroll-margin-top and the page's scroll-padding-top keep the element clear of a header" do
      html =
        ~s|<html><head><style>html { scroll-padding-top: 10px } h2 { scroll-margin-top: 32px }</style></head><body><div style="height: 300px">top</div><h2 id="s">S</h2></body></html>|

      env = %{type: "screen", width: 800, height: 600, dppx: 1.0}
      page = Page.build(html, "http://t.test/", env)
      measure = fn text, style -> String.length(text) * style.size * 0.5 end
      {items, _} = Browser.Layout.layout(page.nodes, 800, measure, 600)
      rects = Browser.Nids.rects(items, Browser.Nids.parents(page.pruned))
      %{} = rects

      heading_top =
        items |> Enum.find(&(&1.type == :text and &1.text == "S")) |> Map.fetch!(:y)

      assert_in_delta Browser.Nids.anchor_y(page.pruned, rects, "s"), heading_top - 42, 8
    end

    test "a plain block with an id starts at its own top, padding included" do
      html =
        ~s|<div style="height: 300px">top</div><section id="s" style="padding-top: 80px"><h2>Sponsors</h2></section>|

      env = %{type: "screen", width: 800, height: 600, dppx: 1.0}
      page = Page.build(html, "http://t.test/", env)
      measure = fn text, style -> String.length(text) * style.size * 0.5 end
      {items, _} = Browser.Layout.layout(page.nodes, 800, measure, 600)
      rects = Browser.Nids.rects(items, Browser.Nids.parents(page.pruned))

      heading =
        items |> Enum.find(&(&1.type == :text and &1.text == "Sponsors")) |> Map.fetch!(:y)

      assert_in_delta Browser.Nids.anchor_y(page.pruned, rects, "s"), 300, 8
      assert heading > 370
    end

    test "a url is split into the address and its fragment" do
      assert Browser.Fetch.split_fragment("http://a.test/x?y=1#sec") ==
               {"http://a.test/x?y=1", "sec"}

      assert Browser.Fetch.split_fragment("http://a.test/x") == {"http://a.test/x", nil}
    end
  end

  test "every inline style block counts, however many there are" do
    styles = for i <- 1..40, into: "", do: "<style>.s#{i}{color:red}</style>"
    page = Page.build(styles <> ~s|<style>.late{display:none}</style><p class="late">x</p>|, @url)
    assert Enum.any?(page.rules, &(inspect(&1.selector) =~ "late"))
  end

  describe "@import" do
    setup do
      dir = Path.join(System.tmp_dir!(), "import_test_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      {:ok, dir: dir, base: "file://" <> dir <> "/page.html"}
    end

    defp rule_colors(page) do
      for %{origin: :author, decls: decls} <- page.rules, {"color", v, _} <- decls, do: v
    end

    test "imported sheets come before the importing one", %{dir: dir, base: base} do
      File.write!(Path.join(dir, "a.css"), "p { color: red }")
      File.write!(Path.join(dir, "b.css"), "p { color: blue }")

      html =
        ~s|<style>@import url(a.css); @import "b.css"; p { color: green }</style><p>x</p>|

      assert rule_colors(Page.build(html, base)) == ["red", "blue", "green"]
    end

    test "an @import after another rule is ignored", %{dir: dir, base: base} do
      File.write!(Path.join(dir, "late.css"), "p { color: red }")
      html = ~s|<style>p { color: green } @import url(late.css);</style><p>x</p>|
      assert rule_colors(Page.build(html, base)) == ["green"]
    end

    test "imports nest and a media list wraps the imported rules", %{dir: dir, base: base} do
      File.write!(Path.join(dir, "inner.css"), "p { color: red }")
      File.write!(Path.join(dir, "outer.css"), "@import 'inner.css'; p { color: blue }")
      html = ~s|<style>@import url(outer.css) print;</style><p>x</p>|
      page = Page.build(html, base)
      assert rule_colors(page) == ["red", "blue"]
      assert page.rules |> Enum.filter(&(&1.origin == :author)) |> Enum.all?(&(&1.media != []))
    end
  end

  # what archiveofourown.org needs: its sheets for phones have a `media` attribute, its menus
  # open on `:hover` and hang below their button, its search field is `width: auto`
  describe "a page like archiveofourown.org" do
    defp measure(text, style), do: String.length(text) * div(round(style.size), 2)

    defp lay(page, width \\ 1000) do
      {items, _} = Browser.Layout.layout(page.nodes, width, &measure/2, 600)
      items
    end

    defp word(items, text), do: Enum.find(items, &(Map.get(&1, :text) == text))

    defp nid_of(nodes, id) do
      Enum.find_value(nodes, fn
        {:element, _, attrs, kids} ->
          if List.keyfind(attrs, "id", 0) == {"id", id},
            do: elem(List.keyfind(attrs, "@nid", 0), 1),
            else: nid_of(kids, id)

        _ ->
          nil
      end)
    end

    defp chain(page, id) do
      parents = Browser.Nids.parents(page.pruned)
      page.pruned |> nid_of(id) |> Stream.iterate(&parents[&1]) |> Enum.take_while(& &1)
    end

    test "a sheet with a media attribute applies only where its query holds" do
      html = """
      <style>p { color: rgb(0, 0, 255) }</style>
      <style media="only screen and (max-width: 42em), handheld">p { color: rgb(255, 0, 0) }</style>
      <p>x</p>
      """

      color = fn width ->
        env = %{Browser.Style.default_env() | width: width}
        word(lay(Page.build(html, "about:blank", env), width), "x").color
      end

      assert color.(1000) == {0, 0, 255}
      assert color.(500) == {255, 0, 0}
    end

    test "two floats of 50% sit side by side in a box whose width is odd" do
      html = """
      <div style="width: 1092px"><div style="float: left; width: 36%">
      <ul style="float: left; width: 100%; margin: 0; padding: 0">
      <li style="float: left; width: 50%">One</li><li style="float: left; width: 50%">Two</li>
      </ul></div></div>
      """

      items = lay(Page.build(html, "about:blank"), 1200)
      assert word(items, "One").y == word(items, "Two").y
    end

    test "a text field with display: inline or width: auto keeps its size" do
      html = """
      <style>input { width: 100% } p input { width: auto; display: inline }</style>
      <div style="float: right"><p><input id=f type=text> <input id=g type=text size=5></p></div>
      """

      page = Page.build(html, "about:blank")
      rects = Browser.Nids.rects(lay(page), Browser.Nids.parents(page.pruned))
      {_, _, w, _} = rects[nid_of(page.pruned, "f")]
      {_, _, w5, _} = rects[nid_of(page.pruned, "g")]
      assert w > 150
      assert w5 < w and w5 > 30
    end

    test "a menu opens on :hover, below its button, without widening it" do
      html = """
      <style>
      ul { list-style: none; margin: 0; padding: 0 }
      .menu { display: none; position: absolute; z-index: 55; width: 300px; background: #ddd }
      .dropdown:hover .menu { display: block }
      .menu li, .menu a { position: relative; left: 1px }
      </style>
      <ul><li id=d class=dropdown style="float: left; position: relative">
      <a id=b style="display: inline-block; padding: 6px">Fandoms</a>
      <ul class=menu><li><a>Anime</a></li></ul>
      </li><li style="float: left"><a>Browse</a></li></ul>
      """

      page = Page.build(html, "about:blank")
      before = lay(page)
      refute word(before, "Anime")
      assert Page.hover_changes?(page, chain(page, "d"))
      refute Page.hover_changes?(page, chain(page, "b") -- chain(page, "d"))

      hovered = Page.set_hover(page, chain(page, "d"), Browser.Style.default_env())
      items = lay(hovered)
      anime = word(items, "Anime")
      fandoms = word(items, "Fandoms")
      assert anime.y >= fandoms.y + fandoms.h
      assert word(items, "Browse").x == word(before, "Browse").x

      # the entries paint above the menu's background
      bg = Enum.find(items, &(&1.type == :rect and &1.w == 300))
      assert anime.pz > bg.pz

      assert lay(Page.set_hover(hovered, [], Browser.Style.default_env())) |> word("Anime") == nil
    end
  end

  describe "start_videos/1" do
    test "autoplay videos play, videos with controls are opened, the rest wait" do
      page =
        Browser.Page.build(
          ~s(<video src="a.mp4" autoplay></video><video src="b.mp4" controls></video>) <>
            ~s(<video src="c.mp4" controls preload="none"></video><video src="d.mp4"></video>) <>
            ~s(<video controls></video>),
          "http://example.test/"
        )

      assert [{_, :play}, {_, :preload}] = Browser.Page.start_videos(page)
    end
  end
end
