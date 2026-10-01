defmodule Browser.BackgroundsTest do
  use ExUnit.Case, async: true
  alias Browser.Backgrounds, as: B

  describe "split_top/1" do
    test "splits on top-level commas only" do
      assert B.split_top("a, b(c, d), 'e,f', g") == ["a", "b(c, d)", "'e,f'", "g"]
      assert B.split_top("  one  ") == ["one"]
      assert B.split_top("") == []
      assert B.split_top("a,,b") == ["a", "b"]
    end
  end

  describe "absolutize/2" do
    test "resolves quoted and bare urls against the base" do
      base = "https://x.test/css/site.css"

      assert B.absolutize("url(a.png)", base) == ~s|url("https://x.test/css/a.png")|
      assert B.absolutize(~s|url( "../b.png" )|, base) == ~s|url("https://x.test/b.png")|

      assert B.absolutize("url('/c.png') no-repeat", base) ==
               ~s|url("https://x.test/c.png") no-repeat|

      assert B.absolutize("url(https://cdn.test/d.png)", base) ==
               ~s|url("https://cdn.test/d.png")|
    end

    test "data urls and fragments stay, several urls are all rewritten" do
      base = "https://x.test/"

      assert B.absolutize("url(data:image/png;base64,AAA=)", base) ==
               ~s|url("data:image/png;base64,AAA=")|

      assert B.absolutize("url(#grad)", base) == ~s|url("#grad")|

      assert B.absolutize("url(a.png), url(b.png)", base) ==
               ~s|url("https://x.test/a.png"), url("https://x.test/b.png")|
    end

    test "values without urls are untouched" do
      assert B.absolutize("linear-gradient(red, blue)", "https://x.test/") ==
               "linear-gradient(red, blue)"
    end
  end

  describe "parse_images/1" do
    test "none and urls, quoted or not" do
      assert B.parse_images("none") == [:none]
      assert B.parse_images("url(a.png)") == [{:url, "a.png"}]

      assert B.parse_images(~s|url("a b.png"), url('c.png')|) == [
               {:url, "a b.png"},
               {:url, "c.png"}
             ]
    end

    test "urls() lists the urls" do
      assert B.urls([{:url, "a"}, :none, {:linear, {:angle, +0.0}, []}, {:url, "b"}]) == [
               "a",
               "b"
             ]
    end

    test "a linear gradient defaults to top-to-bottom" do
      assert [
               {:linear, {:angle, 180.0},
                [%{color: {255, 0, 0, 255}, pos: nil}, %{color: {0, 0, 255, 255}, pos: nil}]}
             ] =
               B.parse_images("linear-gradient(red, blue)")
    end

    test "angles in different units" do
      for {css, deg} <- [
            {"45deg", 45.0},
            {"0.25turn", 90.0},
            {"1.5708rad", 90.0},
            {"100grad", 90.0},
            {"-30deg", -30.0}
          ] do
        assert [{:linear, {:angle, a}, _}] = B.parse_images("linear-gradient(#{css}, red, blue)")
        assert_in_delta a, deg, 0.01
      end
    end

    test "side and corner directions" do
      assert [{:linear, {:to, [:right]}, _}] =
               B.parse_images("linear-gradient(to right, red, blue)")

      assert [{:linear, {:to, [:top, :left]}, _}] =
               B.parse_images("linear-gradient(to top left, red, blue)")
    end

    test "stops with positions, two positions and alpha colours" do
      [{:linear, _, stops}] =
        B.parse_images("linear-gradient(to right, #fff 10%, rgba(0,0,0,.5) 20px 40px, blue)")

      assert [
               %{color: {255, 255, 255, 255}, pos: {:pct, 0.1}},
               %{color: {0, 0, 0, 128}, pos: {:px, 20.0}},
               %{color: {0, 0, 0, 128}, pos: {:px, 40.0}},
               %{color: {0, 0, 255, 255}, pos: nil}
             ] = stops
    end

    test "transparent and currentcolor stops" do
      [{:linear, _, stops}] = B.parse_images("linear-gradient(transparent, currentcolor)")
      assert [%{color: {0, 0, 0, 0}}, %{color: :current}] = stops
    end

    test "colour hints are skipped, a single stop is not a gradient" do
      assert [{:linear, _, [_, _]}] = B.parse_images("linear-gradient(red, 30%, blue)")
      assert B.parse_images("linear-gradient(red)") == [:none]
    end

    test "unsupported gradients read as none" do
      assert B.parse_images("repeating-linear-gradient(red, blue 10px)") == [:none]
      assert B.parse_images("conic-gradient(red, blue)") == [:none]
      assert B.parse_images("image-set(url(a.png) 1x)") == [:none]
    end

    test "radial gradients: defaults, shape, size and position" do
      assert [
               {:radial,
                %{shape: :ellipse, size: :farthest_corner, at: {{:pct, 0.5}, {:pct, 0.5}}},
                [_, _]}
             ] =
               B.parse_images("radial-gradient(red, blue)")

      assert [{:radial, %{shape: :circle, size: :closest_side}, _}] =
               B.parse_images("radial-gradient(circle closest-side, red, blue)")

      assert [{:radial, %{shape: :circle, size: {:radii, [50.0]}}, _}] =
               B.parse_images("radial-gradient(50px, red, blue)")

      assert [{:radial, %{at: {{:pct, +0.0}, {:pct, 1.0}}}, _}] =
               B.parse_images("radial-gradient(circle at left bottom, red, blue)")
    end

    test "layers keep their order and may mix kinds" do
      assert [{:url, "a.png"}, {:linear, _, _}, :none] =
               B.parse_images("url(a.png), linear-gradient(red, blue), none")
    end
  end

  describe "parse_repeat/1" do
    test "keywords" do
      assert B.parse_repeat("repeat") == [{:repeat, :repeat}]
      assert B.parse_repeat("no-repeat") == [{:no_repeat, :no_repeat}]
      assert B.parse_repeat("repeat-x") == [{:repeat, :no_repeat}]
      assert B.parse_repeat("repeat-y") == [{:no_repeat, :repeat}]
      assert B.parse_repeat("repeat no-repeat") == [{:repeat, :no_repeat}]
      assert B.parse_repeat("space round") == [{:repeat, :repeat}]

      assert B.parse_repeat("repeat-x, no-repeat") == [
               {:repeat, :no_repeat},
               {:no_repeat, :no_repeat}
             ]
    end
  end

  describe "parse_position/1" do
    test "keywords and lengths" do
      assert B.parse_position("left top") == [{{:pct, +0.0}, {:pct, +0.0}}]
      assert B.parse_position("top left") == [{{:pct, +0.0}, {:pct, +0.0}}]
      assert B.parse_position("right bottom") == [{{:pct, 1.0}, {:pct, 1.0}}]
      assert B.parse_position("center") == [{{:pct, 0.5}, {:pct, 0.5}}]
      assert B.parse_position("center top") == [{{:pct, 0.5}, {:pct, +0.0}}]
      assert B.parse_position("top") == [{{:pct, 0.5}, {:pct, +0.0}}]
      assert B.parse_position("left") == [{{:pct, +0.0}, {:pct, 0.5}}]
      assert B.parse_position("10px 20px") == [{10.0, 20.0}]
      assert B.parse_position("25% 75%") == [{{:pct, 0.25}, {:pct, 0.75}}]
      assert B.parse_position("10px") == [{10.0, {:pct, 0.5}}]
    end

    test "a keyword with a length" do
      assert B.parse_position("left 10px") == [{{:pct, +0.0}, 10.0}]
      assert B.parse_position("10px bottom") == [{10.0, {:pct, 1.0}}]
      assert B.parse_position("center 5px") == [{{:pct, 0.5}, 5.0}]
    end

    test "offsets from the edges" do
      assert B.parse_position("right 10px bottom 20px") == [
               {{:from_end, 10.0}, {:from_end, 20.0}}
             ]

      assert B.parse_position("left 5px top 6px") == [{5.0, 6.0}]
    end

    test "one value per layer" do
      assert B.parse_position("left top, 5px 6px") == [{{:pct, +0.0}, {:pct, +0.0}}, {5.0, 6.0}]
    end
  end

  describe "parse_size/1" do
    test "keywords, lengths, percentages and auto" do
      assert B.parse_size("cover") == [:cover]
      assert B.parse_size("contain") == [:contain]
      assert B.parse_size("auto") == [{:auto, :auto}]
      assert B.parse_size("50px") == [{50.0, :auto}]
      assert B.parse_size("50% 20px") == [{{:pct, 0.5}, 20.0}]
      assert B.parse_size("auto 10px, cover") == [{:auto, 10.0}, :cover]
    end
  end

  describe "shorthand/1" do
    test "colour only resets everything else" do
      assert B.shorthand("#fff") == %{
               color: "#fff",
               image: "none",
               repeat: "repeat",
               position: "0% 0%",
               size: "auto"
             }

      assert B.shorthand("none") == %{
               color: "transparent",
               image: "none",
               repeat: "repeat",
               position: "0% 0%",
               size: "auto"
             }
    end

    test "image, repeat and colour in any order" do
      s = B.shorthand("#eee url(a.png) no-repeat")
      assert %{color: "#eee", image: "url(a.png)", repeat: "no-repeat"} = s
      s = B.shorthand("no-repeat url(a.png) red")
      assert %{color: "red", image: "url(a.png)", repeat: "no-repeat"} = s
    end

    test "position and size around the slash" do
      s = B.shorthand("url(a.png) center top / cover no-repeat")
      assert %{position: "center top", size: "cover", repeat: "no-repeat"} = s
      s = B.shorthand("url(a.png) 10px 20px/50% auto")
      assert %{position: "10px 20px", size: "50% auto"} = s
      s = B.shorthand("url(a.png) center/contain")
      assert %{position: "center", size: "contain"} = s
    end

    test "a colour after the size is still the colour, not part of the size" do
      s = B.shorthand("url(a.png) center / contain no-repeat #123")
      assert %{color: "#123", size: "contain", position: "center", repeat: "no-repeat"} = s
      s = B.shorthand("url(a.png) 0 0 / 20px 10px #fff repeat-x")
      assert %{color: "#fff", size: "20px 10px", repeat: "repeat-x"} = s
      s = B.shorthand("red url(a.png) center / 50%")
      assert %{color: "red", size: "50%"} = s
    end

    test "gradients and their colours are not mistaken for each other" do
      s = B.shorthand("linear-gradient(to right, red 10%, blue) left top / 20px 20px repeat-x")

      assert %{
               image: "linear-gradient(to right, red 10%, blue)",
               repeat: "repeat-x",
               position: "left top",
               size: "20px 20px"
             } = s

      assert s.color == "transparent"
    end

    test "attachment and box keywords are ignored" do
      s = B.shorthand("url(a.png) fixed padding-box border-box")
      assert %{image: "url(a.png)", repeat: "repeat", position: "0% 0%"} = s
    end

    test "layers: the colour comes from the last one" do
      s = B.shorthand("url(a.png) top left no-repeat, linear-gradient(red, blue), #ddd")
      assert s.image == "url(a.png), linear-gradient(red, blue), none"
      assert s.repeat == "no-repeat, repeat, repeat"
      assert s.position == "top left, 0% 0%, 0% 0%"
      assert s.color == "#ddd"
    end
  end

  describe "linear_line/3" do
    defp near(actual, expected),
      do:
        Enum.zip(Tuple.to_list(actual), Tuple.to_list(expected))
        |> Enum.all?(fn {a, e} -> abs(a - e) < 0.01 end)

    test "to bottom runs from the top edge to the bottom edge" do
      assert near(B.linear_line({:angle, 180.0}, 100, 50), {50.0, +0.0, 50.0, 50.0})
      assert near(B.linear_line({:to, [:bottom]}, 100, 50), {50.0, +0.0, 50.0, 50.0})
    end

    test "to right, to left, to top" do
      assert near(B.linear_line({:to, [:right]}, 100, 50), {+0.0, 25.0, 100.0, 25.0})
      assert near(B.linear_line({:to, [:left]}, 100, 50), {100.0, 25.0, +0.0, 25.0})
      assert near(B.linear_line({:angle, +0.0}, 100, 50), {50.0, 50.0, 50.0, +0.0})
    end

    test "a 45 degree line is as long as needed to reach the corners" do
      {x1, y1, x2, y2} = B.linear_line({:angle, 90.0 + 45}, 100, 100)
      # the line's length is |w sin a| + |h cos a| = 141.4 for a square
      assert_in_delta :math.sqrt((x2 - x1) ** 2 + (y2 - y1) ** 2), 141.42, 0.1
      assert near({(x1 + x2) / 2, (y1 + y2) / 2}, {50.0, 50.0})
    end

    test "corner directions point at the corner and cross the other corners at 50%" do
      {x1, y1, x2, y2} = B.linear_line({:to, [:top, :right]}, 200, 100)
      assert x2 > x1 and y2 < y1
      # the midpoint is the centre, and the other two corners lie on the 50% line
      assert near({(x1 + x2) / 2, (y1 + y2) / 2}, {100.0, 50.0})
      {dx, dy} = {x2 - x1, y2 - y1}
      projection = fn {px, py} -> ((px - x1) * dx + (py - y1) * dy) / (dx * dx + dy * dy) end
      assert_in_delta projection.({0, 0}), 0.5, 0.001
      assert_in_delta projection.({200, 100}), 0.5, 0.001
    end

    test "an empty box doesn't crash" do
      assert {_, _, _, _} = B.linear_line({:to, [:bottom, :right]}, 0, 0)
    end
  end

  describe "normalize_stops/3" do
    defp stop(color, pos), do: %{color: color, pos: pos}
    @red {255, 0, 0, 255}
    @blue {0, 0, 255, 255}

    test "ends default to 0 and 1, the rest are spread evenly" do
      stops = [stop(@red, nil), stop(@blue, nil), stop(@red, nil), stop(@blue, nil)]
      assert [{p0, _}, {p1, _}, {p2, _}, {p3, _}] = B.normalize_stops(stops, 100, @red)
      assert {p0, p3} == {+0.0, 1.0}
      assert_in_delta p1, 1 / 3, 0.001
      assert_in_delta p2, 2 / 3, 0.001
    end

    test "percentages and lengths" do
      stops = [stop(@red, {:px, 10.0}), stop(@blue, {:pct, 0.75})]
      assert [{0.1, @red}, {0.75, @blue}] = B.normalize_stops(stops, 100, @red)
    end

    test "unpositioned stops between positioned ones are spread between them" do
      stops = [
        stop(@red, {:pct, +0.0}),
        stop(@blue, nil),
        stop(@red, nil),
        stop(@blue, {:pct, 0.6})
      ]

      assert [{+0.0, _}, {a, _}, {b, _}, {0.6, _}] = B.normalize_stops(stops, 100, @red)
      assert_in_delta a, 0.2, 0.001
      assert_in_delta b, 0.4, 0.001
    end

    test "positions never go backwards" do
      stops = [stop(@red, {:pct, 0.5}), stop(@blue, {:pct, 0.2}), stop(@red, {:pct, 1.0})]
      assert [{0.5, _}, {0.5, _}, {1.0, _}] = B.normalize_stops(stops, 100, @red)
    end

    test "hard stops (two stops at one position) are kept" do
      stops = [
        stop(@red, {:pct, +0.0}),
        stop(@red, {:pct, 0.5}),
        stop(@blue, {:pct, 0.5}),
        stop(@blue, {:pct, 1.0})
      ]

      assert [{+0.0, _}, {0.5, @red}, {0.5, @blue}, {1.0, _}] =
               B.normalize_stops(stops, 100, @red)
    end

    test "currentcolor takes the given colour" do
      assert [{+0.0, @blue}, {1.0, @red}] =
               B.normalize_stops([stop(:current, nil), stop(@red, nil)], 10, @blue)
    end
  end

  describe "radial_geometry/3" do
    defp radial(shape, size, at \\ {{:pct, 0.5}, {:pct, 0.5}}),
      do: %{shape: shape, size: size, at: at}

    test "the default is an ellipse reaching the corners from the centre" do
      {cx, cy, rx, ry} = B.radial_geometry(radial(:ellipse, :farthest_corner), 200, 100)
      assert {cx, cy} == {100.0, 50.0}
      assert_in_delta rx, 100 * :math.sqrt(2), 0.01
      assert_in_delta ry, 50 * :math.sqrt(2), 0.01
    end

    test "circles: sides and corners" do
      assert {_, _, 50.0, 50.0} = B.radial_geometry(radial(:circle, :closest_side), 200, 100)
      assert {_, _, 100.0, 100.0} = B.radial_geometry(radial(:circle, :farthest_side), 200, 100)
      {_, _, r, r} = B.radial_geometry(radial(:circle, :farthest_corner), 200, 100)
      assert_in_delta r, :math.sqrt(100 * 100 + 50 * 50), 0.01
    end

    test "explicit radii and a position" do
      assert {_, _, 30.0, 30.0} = B.radial_geometry(radial(:circle, {:radii, [30.0]}), 200, 100)

      assert {_, _, 40.0, 20.0} =
               B.radial_geometry(radial(:ellipse, {:radii, [40.0, 20.0]}), 200, 100)

      assert {+0.0, 100.0, _, _} =
               B.radial_geometry(
                 radial(:circle, :closest_side, {{:pct, +0.0}, {:pct, 1.0}}),
                 200,
                 100
               )

      assert {20.0, 10.0, _, _} =
               B.radial_geometry(radial(:circle, :closest_side, {20.0, 10.0}), 200, 100)
    end
  end

  describe "paint_layers/5" do
    @area {10, 20, 200, 100}
    @clip {10, 20, 200, 100}

    defp spec(images, extra \\ %{}),
      do: Map.merge(%{images: images, repeat: [], position: [], size: []}, extra)

    defp sizes, do: %{"a.png" => {:ok, 40, 20}, "bad.png" => :failed}
    defp layers(spec), do: B.paint_layers(spec, @area, @clip, sizes(), {0, 0, 0, 255})

    test "an image at its own size in the top-left corner, repeating" do
      assert [%{kind: :image, url: "a.png", tile: {10, 20, 40, 20}, repeat: {:repeat, :repeat}}] =
               layers(spec([{:url, "a.png"}]))
    end

    test "images that aren't loaded, failed or unknown are skipped" do
      assert layers(spec([{:url, "bad.png"}, {:url, "loading.png"}, :none])) == []
      assert B.paint_layers(spec([{:url, "a.png"}]), @area, @clip, nil, nil) == []
    end

    test "position: keywords, percentages and offsets from the end" do
      pos = fn p ->
        hd(layers(spec([{:url, "a.png"}], %{position: [p], repeat: [{:no_repeat, :no_repeat}]}))).tile
      end

      assert pos.({{:pct, +0.0}, {:pct, +0.0}}) == {10, 20, 40, 20}
      assert pos.({{:pct, 1.0}, {:pct, 1.0}}) == {170, 100, 40, 20}
      assert pos.({{:pct, 0.5}, {:pct, 0.5}}) == {90, 60, 40, 20}
      assert pos.({5.0, 7.0}) == {15, 27, 40, 20}
      assert pos.({{:from_end, 10.0}, {:from_end, 5.0}}) == {160, 95, 40, 20}
    end

    test "size: cover, contain, lengths, percentages" do
      tile = fn s -> hd(layers(spec([{:url, "a.png"}], %{size: [s]}))).tile end
      # area 200x100, picture 40x20 (ratio 2): both fit exactly
      assert tile.(:cover) == {10, 20, 200, 100}
      assert tile.(:contain) == {10, 20, 200, 100}
      assert tile.({100.0, :auto}) == {10, 20, 100, 50}
      assert tile.({:auto, 10.0}) == {10, 20, 20, 10}
      assert tile.({{:pct, 0.5}, {:pct, 0.5}}) == {10, 20, 100, 50}
      assert tile.({30.0, 30.0}) == {10, 20, 30, 30}
    end

    test "cover and contain differ for another aspect ratio" do
      sizes = %{"tall.png" => {:ok, 10, 40}}

      cover =
        B.paint_layers(spec([{:url, "tall.png"}], %{size: [:cover]}), @area, @clip, sizes, nil)

      contain =
        B.paint_layers(spec([{:url, "tall.png"}], %{size: [:contain]}), @area, @clip, sizes, nil)

      assert [%{tile: {10, 20, 200, 800}}] = cover
      assert [%{tile: {10, 20, 25, 100}}] = contain
    end

    test "layers are returned bottom first, and the shorter lists cycle" do
      images = [{:url, "a.png"}, {:linear, {:angle, 180.0}, [stop(@red, nil), stop(@blue, nil)]}]
      [first, second] = layers(spec(images, %{repeat: [{:no_repeat, :no_repeat}]}))
      assert first.kind == :linear and second.kind == :image

      assert first.repeat == {:no_repeat, :no_repeat} and
               second.repeat == {:no_repeat, :no_repeat}
    end

    test "a linear gradient fills the positioning area by default" do
      images = [{:linear, {:to, [:right]}, [stop(@red, nil), stop({0, 0, 255, 255}, nil)]}]

      assert [
               %{
                 kind: :linear,
                 tile: {10, 20, 200, 100},
                 line: {x1, y1, x2, y2},
                 stops: [{+0.0, @red}, {1.0, _}]
               }
             ] = layers(spec(images))

      assert {x1, y1, x2, y2} == {+0.0, 50.0, 200.0, 50.0}
    end

    test "a sized gradient is a tile" do
      images = [{:linear, {:angle, 180.0}, [stop(@red, nil), stop(@blue, nil)]}]

      assert [%{tile: {10, 20, 20, 20}, line: line}] =
               layers(spec(images, %{size: [{20.0, 20.0}]}))

      assert near(line, {10.0, +0.0, 10.0, 20.0})
    end

    test "a radial gradient carries centre, radii and stops relative to its tile" do
      images = [{:radial, radial(:circle, :closest_side), [stop(@red, nil), stop(@blue, nil)]}]

      assert [
               %{
                 kind: :radial,
                 center: {100.0, 50.0},
                 radii: {50.0, 50.0},
                 stops: [{+0.0, _}, {1.0, _}]
               }
             ] = layers(spec(images))
    end

    test "currentcolor stops take the element colour" do
      images = [{:linear, {:angle, 180.0}, [stop(:current, nil), stop(@blue, nil)]}]
      assert [%{stops: [{+0.0, {0, 0, 0, 255}}, _]}] = layers(spec(images))
    end

    test "empty tiles are skipped" do
      images = [{:linear, {:angle, 180.0}, [stop(@red, nil), stop(@blue, nil)]}]
      assert layers(spec(images, %{size: [{+0.0, 10.0}]})) == []
    end
  end

  describe "tiles/3" do
    test "no-repeat is one tile at its position" do
      assert B.tiles({5, 6, 10, 10}, {:no_repeat, :no_repeat}, {0, 0, 100, 100}) == [{5, 6}]
    end

    test "repeat-x fills a row, starting before the clip if needed" do
      assert B.tiles({5, 6, 40, 10}, {:repeat, :no_repeat}, {0, 0, 100, 100}) == [
               {-35, 6},
               {5, 6},
               {45, 6},
               {85, 6}
             ]
    end

    test "repeat both ways covers the clip area" do
      tiles = B.tiles({0, 0, 50, 50}, {:repeat, :repeat}, {0, 0, 100, 100})
      assert Enum.sort(tiles) == [{0, 0}, {0, 50}, {50, 0}, {50, 50}]
    end

    test "tiles that miss the clip are not listed, and offsets work in both directions" do
      # the tile at -40 reaches into the clip with its right 10px
      assert B.tiles({210, 0, 50, 50}, {:repeat, :no_repeat}, {0, 0, 100, 50}) == [
               {-40, 0},
               {10, 0},
               {60, 0}
             ]

      assert B.tiles({-130, 0, 50, 50}, {:repeat, :no_repeat}, {0, 0, 100, 50}) == [
               {-30, 0},
               {20, 0},
               {70, 0}
             ]
    end

    test "a pathological 1px tile is capped" do
      assert length(B.tiles({0, 0, 1, 1}, {:repeat, :repeat}, {0, 0, 5000, 5000})) == 4000
    end
  end
end
