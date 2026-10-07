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

    test "a page can be sent to another process" do
      page = Page.build(@html, "about:x", @env)
      me = self()
      spawn(fn -> send(me, {:page, page}) end)
      assert_receive {:page, ^page}, 1000
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
end
