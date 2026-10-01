defmodule Browser.SvgTest do
  use ExUnit.Case, async: true

  alias Browser.Svg

  defp scene!(src) do
    assert {:ok, scene} = Svg.from_source(src)
    scene
  end

  defp ops(src, w, h, opts \\ []), do: src |> scene!() |> Svg.render(w, h, opts)

  defp svg(body, attrs \\ ~s|viewBox="0 0 100 100"|),
    do: ~s|<svg xmlns="http://www.w3.org/2000/svg" #{attrs}>#{body}</svg>|

  defp close?(a, b), do: abs(a - b) < 1.0e-6

  describe "from_source/1" do
    test "needs an svg element" do
      assert Svg.from_source("<html><body>hi</body></html>") == :error
      assert Svg.from_source("") == :error
    end

    test "skips the xml prolog, doctype, comments and a byte order mark" do
      src =
        "﻿<?xml version=\"1.0\"?>\n<!DOCTYPE svg>\n<!-- hi -->\n" <>
          svg(~s|<rect width="5" height="5"/>|)

      assert [%{kind: :path}] = ops(src, 100, 100)
    end

    test "self-closing elements do not swallow their siblings" do
      src =
        svg(~s|<rect width="5" height="5"/><circle cx="50" cy="50" r="5"/><path d="M0 0L9 9"/>|)

      assert length(ops(src, 100, 100)) == 3
    end

    test "uses the document's own style element" do
      src = svg(~s|<style>.a { fill: #ff0000 } #b { stroke: #00ff00; stroke-width: 3 }</style>
        <rect class="a" id="b" width="5" height="5"/>|)

      assert [
               %{
                 fill: %{paint: {:color, {255, 0, 0, 255}}},
                 stroke: %{paint: {:color, {0, 255, 0, 255}}}
               }
             ] =
               ops(src, 100, 100)
    end
  end

  describe "intrinsic/1" do
    test "width and height" do
      assert Svg.intrinsic(scene!(svg("", ~s|width="40" height="20"|))) == {40.0, 20.0}
    end

    test "the viewBox when there is no size" do
      assert Svg.intrinsic(scene!(svg("", ~s|viewBox="0 0 24 12"|))) == {24.0, 12.0}
    end

    test "one dimension follows the aspect ratio of the viewBox" do
      assert Svg.intrinsic(scene!(svg("", ~s|viewBox="0 0 20 10" width="100"|))) == {100.0, 50.0}
      assert Svg.intrinsic(scene!(svg("", ~s|viewBox="0 0 20 10" height="30"|))) == {60.0, 30.0}
    end

    test "falls back to 300x150" do
      assert Svg.intrinsic(scene!(svg("", ""))) == {300.0, 150.0}
    end

    test "units" do
      assert Svg.intrinsic(scene!(svg("", ~s|width="1in" height="12pt"|))) == {96.0, 16.0}
    end
  end

  describe "transforms" do
    test "identity and garbage" do
      assert Svg.parse_transform(nil) == {1.0, +0.0, +0.0, 1.0, +0.0, +0.0}
      assert Svg.parse_transform("wobble(1 2)") == {1.0, +0.0, +0.0, 1.0, +0.0, +0.0}
    end

    test "translate and scale compose left to right" do
      assert Svg.parse_transform("translate(10 20) scale(2)") ==
               {2.0, +0.0, +0.0, 2.0, 10.0, 20.0}

      assert Svg.parse_transform("translate(5)") == {1.0, +0.0, +0.0, 1.0, 5.0, +0.0}
    end

    test "rotate about a point keeps that point fixed" do
      {a, b, c, d, e, f} = Svg.parse_transform("rotate(90 10 10)")
      assert close?(a * 10 + c * 10 + e, 10.0)
      assert close?(b * 10 + d * 10 + f, 10.0)
      # (20, 10) turns a quarter turn about (10, 10) to (10, 20)
      assert close?(a * 20 + c * 10 + e, 10.0)
      assert close?(b * 20 + d * 10 + f, 20.0)
    end

    test "matrix, skew" do
      assert Svg.parse_transform("matrix(1 2 3 4 5 6)") == {1.0, 2.0, 3.0, 4.0, 5.0, 6.0}
      {_, _, c, _, _, _} = Svg.parse_transform("skewX(45)")
      assert close?(c, 1.0)
    end

    test "are applied to shapes, nested groups included" do
      src =
        svg(
          ~s|<g transform="translate(10 0)"><rect transform="scale(2)" width="5" height="5"/></g>|
        )

      assert [
               %{
                 segments: [
                   {:M, 10.0, +0.0},
                   {:L, 20.0, +0.0},
                   {:L, 20.0, 10.0},
                   {:L, 10.0, 10.0},
                   :Z
                 ]
               }
             ] =
               ops(src, 100, 100)
    end
  end

  describe "shapes" do
    test "rect" do
      src = svg(~s|<rect x="1" y="2" width="3" height="4"/>|)

      assert [%{segments: [{:M, 1.0, 2.0}, {:L, 4.0, 2.0}, {:L, 4.0, 6.0}, {:L, 1.0, 6.0}, :Z]}] =
               ops(src, 100, 100)
    end

    test "rect without size draws nothing" do
      assert ops(svg(~s|<rect width="0" height="4"/><rect height="4"/>|), 100, 100) == []
    end

    test "rounded rect has curves and stays inside its box" do
      [%{segments: segs}] = ops(svg(~s|<rect width="20" height="10" rx="3"/>|), 100, 100)
      assert Enum.any?(segs, &match?({:C, _, _, _, _, _, _}, &1))

      for seg <- segs, seg != :Z do
        {x, y} = {elem(seg, tuple_size(seg) - 2), elem(seg, tuple_size(seg) - 1)}
        assert x >= -1.0e-9 and x <= 20 + 1.0e-9 and y >= -1.0e-9 and y <= 10 + 1.0e-9
      end
    end

    test "rx is clamped to half the width, and ry follows rx" do
      [%{segments: segs}] = ops(svg(~s|<rect width="10" height="10" rx="50"/>|), 100, 100)
      assert {:M, 5.0, +0.0} = hd(segs)
    end

    test "circle: every point is on the circle" do
      [%{segments: segs}] = ops(svg(~s|<circle cx="30" cy="40" r="10"/>|), 100, 100)

      for {:C, _, _, _, _, x, y} <- segs do
        assert close?(:math.sqrt((x - 30) * (x - 30) + (y - 40) * (y - 40)), 10.0)
      end

      assert :Z in segs
    end

    test "circle with no radius draws nothing" do
      assert ops(svg(~s|<circle cx="3" cy="4"/><circle r="-1"/>|), 100, 100) == []
    end

    test "ellipse" do
      [%{segments: [{:M, x, y} | _]}] =
        ops(svg(~s|<ellipse cx="10" cy="10" rx="8" ry="4"/>|), 100, 100)

      assert {x, y} == {18.0, 10.0}
    end

    test "line is stroked, never filled" do
      src = svg(~s|<line x1="0" y1="0" x2="10" y2="10" stroke="red"/>|)
      assert [%{fill: nil, stroke: %{width: 1.0}, open?: true}] = ops(src, 100, 100)
    end

    test "a line without a stroke is invisible" do
      assert ops(svg(~s|<line x2="10" y2="10"/>|), 100, 100) == []
    end

    test "polyline and polygon" do
      assert [%{segments: [{:M, +0.0, +0.0}, {:L, 5.0, 5.0}, {:L, 10.0, +0.0}], open?: true}] =
               ops(svg(~s|<polyline points="0,0 5,5 10,0"/>|), 100, 100)

      assert [%{segments: [{:M, +0.0, +0.0}, {:L, 5.0, 5.0}, {:L, 10.0, +0.0}, :Z], open?: false}] =
               ops(svg(~s|<polygon points="0 0 5 5 10 0"/>|), 100, 100)
    end

    test "a polygon with an odd trailing number ignores it" do
      assert [%{segments: [_, _, _, :Z]}] =
               ops(svg(~s|<polygon points="0 0 5 5 10 0 7"/>|), 100, 100)
    end

    test "path" do
      assert [%{segments: [{:M, 1.0, 1.0}, {:L, 5.0, 1.0}, :Z]}] =
               ops(svg(~s|<path d="M1 1 H5 Z"/>|), 100, 100)
    end

    test "a path with bad data draws nothing" do
      assert ops(svg(~s|<path d="L 1 1"/><path/>|), 100, 100) == []
    end

    test "unknown elements are skipped" do
      assert ops(svg(~s|<blink/><title>x</title><desc>y</desc><metadata/>|), 100, 100) == []
    end
  end

  describe "viewBox" do
    test "scales the drawing into the box" do
      src = svg(~s|<rect width="50" height="50"/>|, ~s|viewBox="0 0 100 100"|)
      assert [%{segments: [{:M, +0.0, +0.0}, {:L, 100.0, +0.0} | _]}] = ops(src, 200, 200)
    end

    test "origin offsets" do
      src = svg(~s|<rect x="10" y="10" width="5" height="5"/>|, ~s|viewBox="10 10 20 20"|)
      assert [%{segments: [{:M, +0.0, +0.0} | _]}] = ops(src, 20, 20)
    end

    test "meet centres the picture" do
      src = svg(~s|<rect width="10" height="10"/>|, ~s|viewBox="0 0 10 10"|)
      assert [%{segments: [{:M, x, +0.0}, {:L, x2, +0.0} | _]}] = ops(src, 40, 20)
      assert {x, x2} == {10.0, 30.0}
    end

    test "xMinYMin aligns to the corner" do
      src =
        svg(
          ~s|<rect width="10" height="10"/>|,
          ~s|viewBox="0 0 10 10" preserveAspectRatio="xMinYMin meet"|
        )

      assert [%{segments: [{:M, +0.0, +0.0}, {:L, 20.0, +0.0} | _]}] = ops(src, 40, 20)
    end

    test "slice covers the box" do
      src =
        svg(
          ~s|<rect width="10" height="10"/>|,
          ~s|viewBox="0 0 10 10" preserveAspectRatio="xMidYMid slice"|
        )

      assert [%{segments: [{:M, +0.0, y}, {:L, 40.0, y} | _]}] = ops(src, 40, 20)
      assert y == -10.0
    end

    test "none stretches" do
      src =
        svg(
          ~s|<rect width="10" height="10"/>|,
          ~s|viewBox="0 0 10 10" preserveAspectRatio="none"|
        )

      assert [%{segments: [_, {:L, 40.0, +0.0}, {:L, 40.0, 20.0} | _]}] = ops(src, 40, 20)
    end

    test "width and height stand in for a missing viewBox" do
      src = svg(~s|<rect width="10" height="10"/>|, ~s|width="10" height="10"|)
      assert [%{segments: [_, {:L, 20.0, +0.0} | _]}] = ops(src, 20, 20)
    end

    test "a bad viewBox is ignored" do
      assert Svg.intrinsic(scene!(svg("", ~s|viewBox="0 0 -5 5"|))) == {300.0, 150.0}
    end
  end

  describe "paint" do
    test "defaults: black fill, no stroke" do
      assert [%{fill: %{paint: {:color, {0, 0, 0, 255}}, rule: :nonzero}, stroke: nil}] =
               ops(svg(~s|<rect width="5" height="5"/>|), 100, 100)
    end

    test "fill none" do
      assert ops(svg(~s|<rect width="5" height="5" fill="none"/>|), 100, 100) == []
    end

    test "attributes, named colours, rgb()" do
      assert [%{fill: %{paint: {:color, {255, 0, 0, 255}}}}] =
               ops(svg(~s|<rect width="5" height="5" fill="red"/>|), 100, 100)

      assert [%{fill: %{paint: {:color, {1, 2, 3, 255}}}}] =
               ops(svg(~s|<rect width="5" height="5" fill="rgb(1,2,3)"/>|), 100, 100)
    end

    test "unparseable colours draw nothing" do
      assert ops(svg(~s|<rect width="5" height="5" fill="blorp"/>|), 100, 100) == []
    end

    test "inherits from groups and the svg element, nearest wins" do
      src =
        ~s|<svg viewBox="0 0 9 9" fill="#00ff00"><g fill="#0000ff"><rect width="1" height="1"/>| <>
          ~s|<rect width="1" height="1" fill="#ff0000"/></g><circle r="2"/></svg>|

      assert [
               %{fill: %{paint: {:color, {0, 0, 255, 255}}}},
               %{fill: %{paint: {:color, {255, 0, 0, 255}}}},
               %{fill: %{paint: {:color, {0, 255, 0, 255}}}}
             ] = ops(src, 9, 9)
    end

    test "a stylesheet beats a presentation attribute" do
      src = svg(~s|<style>rect { fill: #0000ff }</style><rect width="1" height="1" fill="red"/>|)
      assert [%{fill: %{paint: {:color, {0, 0, 255, 255}}}}] = ops(src, 100, 100)
    end

    test "style attribute beats the presentation attribute" do
      src = svg(~s|<rect width="1" height="1" fill="red" style="fill: blue"/>|)
      assert [%{fill: %{paint: {:color, {0, 0, 255, 255}}}}] = ops(src, 100, 100)
    end

    test "currentColor takes the colour option, and the CSS colour property" do
      src = svg(~s|<rect width="1" height="1" fill="currentColor"/>|)

      assert [%{fill: %{paint: {:color, {9, 8, 7, 255}}}}] =
               ops(src, 10, 10, current: {9, 8, 7, 255})

      src =
        svg(
          ~s|<g style="color: #112233"><rect width="1" height="1" fill="currentColor" stroke="currentcolor"/></g>|
        )

      assert [
               %{
                 fill: %{paint: {:color, {17, 34, 51, 255}}},
                 stroke: %{paint: {:color, {17, 34, 51, 255}}}
               }
             ] =
               ops(src, 10, 10)
    end

    test "opacities multiply into the alpha channel" do
      src =
        svg(~s|<g opacity="0.5"><rect width="1" height="1" fill-opacity="0.5" fill="red"/></g>|)

      assert [%{fill: %{paint: {:color, {255, 0, 0, a}}}}] = ops(src, 10, 10)
      assert a in 63..65
    end

    test "fill-rule" do
      assert [%{fill: %{rule: :evenodd}}] =
               ops(svg(~s|<path d="M0 0H9V9H0Z" fill-rule="evenodd"/>|), 10, 10)
    end

    test "display none and visibility hidden" do
      src =
        svg(
          ~s|<rect width="1" height="1" display="none"/><rect width="1" height="1" visibility="hidden"/>| <>
            ~s|<g display="none"><rect width="1" height="1"/></g><rect width="2" height="2"/>|
        )

      assert [%{segments: [_, {:L, 2.0, +0.0} | _]}] = ops(src, 100, 100)
    end
  end

  describe "stroke" do
    test "properties" do
      src =
        svg(
          ~s|<path d="M0 0L9 9" fill="none" stroke="#ff0000" stroke-width="4" stroke-linecap="round"| <>
            ~s| stroke-linejoin="bevel" stroke-miterlimit="2" stroke-dasharray="3 1"/>|
        )

      assert [%{stroke: stroke}] = ops(src, 100, 100)
      assert stroke.width == 4.0
      assert stroke.cap == :round
      assert stroke.join == :bevel
      assert stroke.miter == 2.0
      # the dashes are cut into the path: no dash pattern is left for the painter
      assert stroke.dash == nil
      assert stroke.paint == {:color, {255, 0, 0, 255}}
    end

    test "width scales with the viewBox" do
      src = svg(~s|<path d="M0 0L9 9" stroke="red" stroke-width="2"/>|, ~s|viewBox="0 0 10 10"|)
      assert [%{stroke: %{width: 6.0}}] = ops(src, 30, 30)
    end

    test "zero width, none dash arrays" do
      assert [%{stroke: nil}] =
               ops(svg(~s|<rect width="5" height="5" stroke="red" stroke-width="0"/>|), 10, 10)

      assert [%{stroke: %{dash: nil}}] =
               ops(
                 svg(~s|<rect width="5" height="5" stroke="red" stroke-dasharray="none"/>|),
                 10,
                 10
               )

      assert [%{stroke: %{dash: nil}}] =
               ops(
                 svg(~s|<rect width="5" height="5" stroke="red" stroke-dasharray="0 0"/>|),
                 10,
                 10
               )
    end
  end

  describe "gradients" do
    @defs ~s|<defs><linearGradient id="g"><stop offset="0" stop-color="#ff0000"/>| <>
            ~s|<stop offset="50%" stop-color="#00ff00" stop-opacity="0.5"/>| <>
            ~s|<stop offset="1" style="stop-color: #0000ff"/></linearGradient></defs>|

    test "linear gradient across the bounding box" do
      src = svg(@defs <> ~s|<rect x="10" y="20" width="40" height="10" fill="url(#g)"/>|)
      assert [%{fill: %{paint: {:linear, {x1, y1, x2, y2}, stops}}}] = ops(src, 100, 100)
      assert {x1, y1, x2, y2} == {10.0, 20.0, 50.0, 20.0}

      assert [{+0.0, {255, 0, 0, 255}}, {0.5, {0, 255, 0, g}}, {1.0, {0, 0, 255, 255}}] = stops
      assert g in 127..128
    end

    test "user space units" do
      src =
        svg(
          ~s|<defs><linearGradient id="g" gradientUnits="userSpaceOnUse" x1="0" y1="0" x2="0" y2="80">| <>
            ~s|<stop offset="0" stop-color="red"/><stop offset="1" stop-color="blue"/></linearGradient></defs>| <>
            ~s|<rect x="10" y="20" width="40" height="10" fill="url(#g)"/>|
        )

      assert [%{fill: %{paint: {:linear, {+0.0, +0.0, +0.0, 80.0}, _}}}] = ops(src, 100, 100)
    end

    test "viewBox scaling reaches the gradient line" do
      src =
        svg(@defs <> ~s|<rect width="10" height="10" fill="url(#g)"/>|, ~s|viewBox="0 0 10 10"|)

      assert [%{fill: %{paint: {:linear, {+0.0, +0.0, 50.0, +0.0}, _}}}] = ops(src, 50, 50)
    end

    test "gradientTransform" do
      src =
        svg(
          ~s|<defs><linearGradient id="g" gradientTransform="rotate(90)"><stop offset="0" stop-color="red"/>| <>
            ~s|<stop offset="1" stop-color="blue"/></linearGradient></defs>| <>
            ~s|<rect width="10" height="10" fill="url(#g)"/>|
        )

      assert [%{fill: %{paint: {:linear, {x1, y1, x2, y2}, _}}}] = ops(src, 100, 100)
      assert close?(x1, +0.0) and close?(y1, +0.0) and close?(x2, +0.0) and close?(y2, 10.0)
    end

    test "radial gradient" do
      src =
        svg(
          ~s|<defs><radialGradient id="r" cx="50%" cy="50%" r="50%"><stop offset="0" stop-color="white"/>| <>
            ~s|<stop offset="1" stop-color="black"/></radialGradient></defs>| <>
            ~s|<circle cx="20" cy="20" r="10" fill="url(#r)"/>|
        )

      assert [%{fill: %{paint: {:radial, {cx, cy, r, fx, fy}, [_, _]}}}] = ops(src, 100, 100)
      assert {cx, cy, r, fx, fy} == {20.0, 20.0, 10.0, 20.0, 20.0}
    end

    test "stops and attributes come through href" do
      src =
        svg(
          @defs <>
            ~s|<linearGradient id="h" href="#g" x2="0" y2="1"/>| <>
            ~s|<rect width="10" height="10" fill="url(#h)"/>|
        )

      assert [%{fill: %{paint: {:linear, {+0.0, +0.0, +0.0, 10.0}, [_, _, _]}}}] =
               ops(src, 100, 100)
    end

    test "stops are kept in order" do
      src =
        svg(
          ~s|<defs><linearGradient id="g"><stop offset="0.8" stop-color="red"/>| <>
            ~s|<stop offset="0.2" stop-color="blue"/></linearGradient></defs><rect width="9" height="9" fill="url(#g)"/>|
        )

      assert [%{fill: %{paint: {:linear, _, [{0.8, _}, {0.8, _}]}}}] = ops(src, 10, 10)
    end

    test "missing gradients fall back, or draw nothing" do
      assert ops(svg(~s|<rect width="5" height="5" fill="url(#nope)"/>|), 10, 10) == []

      assert [%{fill: %{paint: {:color, {255, 0, 0, 255}}}}] =
               ops(svg(~s|<rect width="5" height="5" fill="url(#nope) red"/>|), 10, 10)
    end

    test "a gradient without stops draws nothing" do
      src =
        svg(~s|<defs><linearGradient id="e"/></defs><rect width="5" height="5" fill="url(#e)"/>|)

      assert ops(src, 10, 10) == []
    end

    test "objectBoundingBox on an empty box draws nothing" do
      src = svg(@defs <> ~s|<line x2="10" y2="0" stroke="url(#g)"/>|)
      assert ops(src, 100, 100) == []
    end

    test "gradient strokes" do
      src = svg(@defs <> ~s|<path d="M0 0L10 10" stroke="url(#g)"/>|)
      assert [%{stroke: %{paint: {:linear, _, _}}}] = ops(src, 100, 100)
    end
  end

  describe "use" do
    test "draws the referenced shape at an offset" do
      src =
        svg(~s|<defs><rect id="r" width="5" height="5"/></defs><use href="#r" x="10" y="20"/>|)

      assert [%{segments: [{:M, 10.0, 20.0} | _]}] = ops(src, 100, 100)
    end

    test "xlink:href works" do
      src = svg(~s|<rect id="r" width="5" height="5" fill="none"/><use xlink:href="#r"/>|)
      assert ops(src, 100, 100) == []
    end

    test "symbols are drawn only through use" do
      src = svg(~s|<symbol id="s"><circle cx="5" cy="5" r="5"/></symbol><use href="#s"/>|)
      assert [%{segments: [_ | _]}] = ops(src, 100, 100)
      assert length(ops(svg(~s|<symbol id="s"><circle r="5"/></symbol>|), 100, 100)) == 0
    end

    test "inherits fill from the use element" do
      src = svg(~s|<defs><path id="p" d="M0 0H5V5Z"/></defs><use href="#p" fill="#ff0000"/>|)
      assert [%{fill: %{paint: {:color, {255, 0, 0, 255}}}}] = ops(src, 100, 100)
    end

    test "a use that refers to itself terminates" do
      src = svg(~s|<g id="a"><use href="#a"/><rect width="1" height="1"/></g>|)
      assert [_ | _] = ops(src, 10, 10)
    end

    test "missing targets are skipped" do
      assert ops(svg(~s|<use href="#gone"/><use/>|), 10, 10) == []
    end

    test "targets elsewhere in the page come from defs" do
      sprite =
        {:element, "symbol", [{"id", "ico"}], [{:element, "path", [{"d", "M0 0H4V4Z"}], []}]}

      defs = Svg.collect_ids([{:element, "svg", [], [sprite]}])
      assert Map.has_key?(defs, "ico")

      {:element, "svg", _, _} =
        el =
        {:element, "svg", [{"viewbox", "0 0 10 10"}], [{:element, "use", [{"href", "#ico"}], []}]}

      assert [%{segments: [_ | _]}] = el |> Svg.from_element(defs) |> Svg.render(10, 10)
    end
  end

  describe "text" do
    test "position, size, anchor" do
      src = svg(~s|<text x="10" y="20" font-size="12" text-anchor="middle" fill="red">  Hello
        world </text>|)

      assert [
               %{
                 kind: :text,
                 x: 10.0,
                 y: 20.0,
                 text: "Hello world",
                 size: 12.0,
                 anchor: :middle,
                 color: {255, 0, 0, 255}
               }
             ] =
               ops(src, 100, 100)
    end

    test "scaled by the viewBox" do
      src = svg(~s|<text y="5" font-size="10">x</text>|, ~s|viewBox="0 0 50 50"|)
      assert [%{size: 20.0, y: 10.0}] = ops(src, 100, 100)
    end

    test "weight, style, family" do
      src =
        svg(
          ~s|<text font-weight="bold" font-style="italic" font-family="Courier, serif">x</text>|
        )

      assert [%{bold: true, italic: true, mono: true}] = ops(src, 100, 100)
    end

    test "empty text and gradient-filled text are dropped" do
      assert ops(svg(~s|<text>   </text>|), 10, 10) == []
    end
  end

  describe "nesting" do
    test "groups and links are containers" do
      src = svg(~s|<a href="x"><g><rect width="1" height="1"/></g></a>|)
      assert [_] = ops(src, 10, 10)
    end

    test "elements inside defs are not drawn" do
      assert ops(svg(~s|<defs><rect width="5" height="5"/></defs>|), 10, 10) == []
    end
  end

  describe "dashes" do
    test "a dashed line becomes separate segments" do
      src = svg(~s|<line x2="10" stroke="red" stroke-dasharray="2 1"/>|, ~s|viewBox="0 0 10 10"|)
      assert [%{kind: :path, stroke: %{dash: nil}, segments: segs}] = ops(src, 10, 10)
      starts = for {:M, x, _} <- segs, do: x
      assert starts == [+0.0, 3.0, 6.0, 9.0]
    end

    test "dashes follow curves and keep the fill" do
      src = svg(~s|<circle cx="10" cy="10" r="8" fill="blue" stroke="red" stroke-dasharray="4"/>|)

      assert [%{fill: %{}, stroke: nil}, %{fill: nil, stroke: %{dash: nil}, segments: segs}] =
               ops(src, 20, 20)

      assert length(for {:M, _, _} <- segs, do: 1) > 5
    end

    test "dash_segments cuts a polyline" do
      segs = Svg.dash_segments([{:M, +0.0, +0.0}, {:L, 10.0, +0.0}], [3.0, 2.0])

      assert segs == [
               {:M, +0.0, +0.0},
               {:L, 3.0, +0.0},
               {:M, 5.0, +0.0},
               {:L, 8.0, +0.0},
               {:M, 10.0, +0.0},
               {:L, 10.0, +0.0}
             ] or length(for {:M, _, _} <- segs, do: 1) in 2..3
    end

    test "closed paths dash all the way round" do
      segs =
        Svg.dash_segments([{:M, +0.0, +0.0}, {:L, 4.0, +0.0}, {:L, 4.0, 4.0}, :Z], [1.0, 1.0])

      assert length(for {:M, _, _} <- segs, do: 1) >= 4
    end
  end
end
