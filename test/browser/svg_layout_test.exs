defmodule Browser.SvgLayoutTest do
  use ExUnit.Case, async: true

  alias Browser.{Images, Layout, Page, Svg}

  defp measure(text, _style), do: String.length(text) * 7

  defp lay(html, opts \\ [], width \\ 400) do
    page = Page.build("<style>body{margin:0} p,div{margin:0}</style>" <> html, "about:home")
    opts = Keyword.put_new(opts, :svg_defs, page.svg_defs)
    Layout.layout(page.nodes, width, &measure/2, 600, opts)
  end

  defp svgs(items), do: Enum.filter(items, &(&1.type == :svg))

  describe "inline <svg>" do
    test "is a replaced element sized by its attributes" do
      {items, height} = lay(~s|<svg width="120" height="40"><rect width="10" height="10"/></svg>|)
      assert [%{w: 120, h: 40, ops: [%{kind: :path}]}] = svgs(items)
      assert height >= 40
    end

    test "its drawing is relative to its own box and scaled by the viewBox" do
      {items, _} =
        lay(
          ~s|<svg width="100" height="50" viewBox="0 0 10 5"><rect width="10" height="5"/></svg>|
        )

      assert [%{ops: [%{segments: [{:M, +0.0, +0.0}, {:L, 100.0, +0.0} | _]}]}] = svgs(items)
    end

    test "CSS sizes win over attributes" do
      {items, _} =
        lay(
          ~s|<svg width="120" height="40" style="width:60px"><rect width="1" height="1"/></svg>|
        )

      assert [%{w: 60}] = svgs(items)
    end

    test "with only a viewBox it fills the width and keeps the ratio" do
      {items, _} = lay(~s|<svg viewBox="0 0 200 50"><rect width="1" height="1"/></svg>|, [], 400)
      # the page keeps a 4px margin on each side
      assert [%{w: 392, h: 98}] = svgs(items)
    end

    test "with a CSS width and a viewBox the height follows" do
      {items, _} = lay(~s|<svg viewBox="0 0 200 50" style="width:100px"></svg>|)
      assert [%{w: 100, h: 25}] = svgs(items)
    end

    test "with nothing it is 300x150" do
      {items, _} = lay(~s|<svg><rect width="1" height="1"/></svg>|)
      assert [%{w: 300, h: 150}] = svgs(items)
    end

    test "percentage widths refer to the container" do
      {items, _} = lay(~s|<svg width="50%" height="20"></svg>|)
      assert [%{w: 196, h: 20}] = svgs(items)
    end

    test "sits in a line with text" do
      {items, _} = lay(~s|<p>hello <svg width="20" height="20"></svg> world</p>|)
      [svg] = svgs(items)
      hello = Enum.find(items, &(Map.get(&1, :text) == "hello"))
      world = Enum.find(items, &(Map.get(&1, :text) == "world"))
      assert hello.x < svg.x and svg.x < world.x
      assert hello.y <= svg.y + svg.h
    end

    test "inside a link it is clickable" do
      {items, _} = lay(~s|<a href="/x"><svg width="20" height="20"></svg></a>|)
      assert [%{href: href}] = svgs(items)
      assert href =~ "/x"
      assert Browser.UI.link_at(Browser.UI.links(items), 5, 5) =~ "/x"
    end

    test "display none and visibility hidden" do
      {items, _} = lay(~s|<svg width="9" height="9" style="display:none"></svg>|)
      assert svgs(items) == []
      {items, _} = lay(~s|<svg width="9" height="9" style="visibility:hidden"></svg>|)
      assert [%{hidden: true}] = svgs(items)
    end

    test "the CSS color is what currentColor draws" do
      {items, _} =
        lay(
          ~s|<svg width="9" height="9" style="color:#336699"><rect width="9" height="9" fill="currentColor"/></svg>|
        )

      assert [%{ops: [%{fill: %{paint: {:color, {51, 102, 153, 255}}}}]}] = svgs(items)
    end

    test "stylesheet rules reach the shapes" do
      {items, _} =
        lay(
          ~s|<style>.r{fill:#ff0000}</style><svg width="9" height="9"><rect class="r" width="9" height="9"/></svg>|
        )

      assert [%{ops: [%{fill: %{paint: {:color, {255, 0, 0, 255}}}}]}] = svgs(items)
    end

    test "a hidden sprite still provides symbols" do
      html =
        ~s|<svg style="display:none"><symbol id="s" viewBox="0 0 10 10"><rect width="10" height="10" fill="#00ff00"/></symbol></svg>| <>
          ~s|<svg width="20" height="20"><use href="#s"/></svg>|

      {items, _} = lay(html)
      assert [%{w: 20, ops: [%{fill: %{paint: {:color, {0, 255, 0, 255}}}}]}] = svgs(items)
    end

    test "sprite content takes its colour from the use, not from where it was defined" do
      html =
        ~s|<style>.i { fill: currentColor; color: #0000ff }</style>| <>
          ~s|<svg width="0" height="0" fill="none"><symbol id="s"><rect width="9" height="9"/></symbol></svg>| <>
          ~s|<svg class="i" width="20" height="20"><use href="#s"/></svg>|

      {items, _} = lay(html)
      assert [%{w: 20, ops: [%{fill: %{paint: {:color, {0, 0, 255, 255}}}}]}] = svgs(items)
    end

    test "is laid out as a flex item, sized by logical properties" do
      html =
        ~s|<style>header{display:flex;align-items:center} #logo{block-size:5em;flex:none}</style>| <>
          ~s|<header><svg id="logo" viewBox="0 0 800 400"><rect width="9" height="9"/></svg><h1>x</h1></header>|

      {items, _} = lay(html)
      assert [%{h: 80, w: 160}] = svgs(items)
    end

    test "a zero-size sprite does not take room" do
      {items, height} = lay(~s|<svg width="0" height="0"><symbol id="s"></symbol></svg><p>x</p>|)
      assert height < 40
      assert Enum.any?(items, &(Map.get(&1, :text) == "x"))
    end
  end

  describe "<img> with an svg source" do
    @scene Svg.from_source(~s|<svg viewBox="0 0 40 20"><rect width="40" height="20"/></svg>|)
           |> elem(1)

    test "is drawn at the image's own size" do
      {items, _} = lay(~s|<img src="a.svg">|, images: %{"about:a.svg" => {:svg, 40, 20, @scene}})
      assert [%{w: 40, h: 20, ops: [_]}] = svgs(items)
    end

    test "scales with a width attribute" do
      {items, _} =
        lay(~s|<img src="a.svg" width="80">|, images: %{"about:a.svg" => {:svg, 40, 20, @scene}})

      assert [%{w: 80, h: 40, ops: [%{segments: [_, {:L, 80.0, +0.0} | _]}]}] = svgs(items)
    end

    test "has no item while it loads" do
      {items, _} = lay(~s|<img src="a.svg">|, images: %{})
      assert svgs(items) == []
    end
  end

  describe "backgrounds" do
    @scene2 Svg.from_source(
              ~s|<svg viewBox="0 0 10 10" width="10" height="10"><rect width="10" height="10"/></svg>|
            )
            |> elem(1)

    test "an svg background becomes a layer with a display list at the tile's size" do
      html =
        ~s|<div style="width:100px;height:50px;background:url(a.svg) no-repeat center / contain">x</div>|

      {items, _} = lay(html, images: %{"about:a.svg" => {:svg, 10, 10, @scene2}})
      assert [%{layers: [layer]}] = Enum.filter(items, &(&1.type == :bgimage))
      assert layer.kind == :svg
      assert layer.tile == {29, 0, 50, 50}
      assert [%{segments: [_, {:L, 50.0, +0.0} | _]}] = layer.ops
    end

    test "tiles repeat at the intrinsic size" do
      html = ~s|<div style="width:100px;height:50px;background:url(a.svg)">x</div>|
      {items, _} = lay(html, images: %{"about:a.svg" => {:svg, 10, 10, @scene2}})

      assert [%{layers: [%{kind: :svg, tile: {4, 0, 10, 10}}]}] =
               Enum.filter(items, &(&1.type == :bgimage))
    end
  end

  describe "sniffing and fetching" do
    @svg ~s|<svg xmlns="http://www.w3.org/2000/svg" width="5" height="5"><rect width="5" height="5"/></svg>|

    test "sniff finds svg, with or without a prolog" do
      assert Images.sniff(@svg) == :svg
      assert Images.sniff("<?xml version=\"1.0\"?>\n<!-- c -->\n" <> @svg) == :svg
      assert Images.sniff("\n  " <> @svg) == :svg
    end

    test "html that mentions svg is not an image" do
      assert Images.sniff("<!doctype html><html><body>" <> @svg <> "</body></html>") == :unknown
      assert Images.sniff("<html><svg></svg></html>") == :unknown
    end

    test "fetch parses data URLs" do
      url = "data:image/svg+xml;utf8," <> @svg
      assert {:ok, %{width: 5.0}, :svg} = Images.fetch(url, "http://x.test/")

      b64 = "data:image/svg+xml;base64," <> Base.encode64(@svg)
      assert {:ok, %{width: 5.0}, :svg} = Images.fetch(b64, "http://x.test/")
    end

    test "a percent sign in an unencoded data URL does not crash" do
      url =
        ~s|data:image/svg+xml;utf8,<svg width="100%" height="5"><rect width="100%" height="5"/></svg>|

      assert {:ok, _scene, :svg} = Images.fetch(url, "http://x.test/")
    end

    test "fetch reads local files for local pages" do
      assert {:ok, scene, :svg} =
               Images.fetch(
                 "file://" <> Path.expand("test/fixtures/images/logo.svg"),
                 "file:///x.html"
               )

      assert Svg.intrinsic(scene) == {120.0, 60.0}
    end

    test "data that is not an image fails" do
      assert {:error, _} = Images.fetch("data:image/svg+xml;utf8,not an image", "http://x.test/")
    end
  end

  describe "pages" do
    test "a top-level svg is shown as a picture" do
      assert Page.document(~s|<svg width="5" height="5"></svg>|, "http://x.test/a.svg") =~ "<img"
    end
  end
end
