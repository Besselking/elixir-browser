defmodule Browser.Svg.PathDataTest do
  use ExUnit.Case, async: true
  alias Browser.Svg.PathData

  defp parse(d), do: PathData.parse(d)

  defp near?(a, b), do: abs(a - b) < 1.0e-6

  describe "lines and moves" do
    test "absolute commands" do
      assert parse("M 10 20 L 30 40 L 50 60 Z") == [
               {:M, 10.0, 20.0},
               {:L, 30.0, 40.0},
               {:L, 50.0, 60.0},
               :Z
             ]
    end

    test "relative commands are measured from the current point" do
      assert parse("m10 10 l5 5 l-3 2") == [{:M, 10.0, 10.0}, {:L, 15.0, 15.0}, {:L, 12.0, 17.0}]
    end

    test "h and v, absolute and relative" do
      assert parse("M0 0 H10 V5 h-4 v3") ==
               [
                 {:M, +0.0, +0.0},
                 {:L, 10.0, +0.0},
                 {:L, 10.0, 5.0},
                 {:L, 6.0, 5.0},
                 {:L, 6.0, 8.0}
               ]
    end

    test "extra pairs after a moveto are linetos (relative stays relative)" do
      assert parse("M1 2 3 4 5 6") == [{:M, 1.0, 2.0}, {:L, 3.0, 4.0}, {:L, 5.0, 6.0}]
      assert parse("m1 2 3 4 5 6") == [{:M, 1.0, 2.0}, {:L, 4.0, 6.0}, {:L, 9.0, 12.0}]
    end

    test "implicit repetition of other commands" do
      assert parse("M0 0 L1 1 2 2 3 3") == [
               {:M, +0.0, +0.0},
               {:L, 1.0, 1.0},
               {:L, 2.0, 2.0},
               {:L, 3.0, 3.0}
             ]

      assert parse("M0 0 h1 2 3") == [
               {:M, +0.0, +0.0},
               {:L, 1.0, +0.0},
               {:L, 3.0, +0.0},
               {:L, 6.0, +0.0}
             ]
    end

    test "close returns to the start of the subpath, and drawing can continue from there" do
      assert parse("M10 10 L20 10 L20 20 z l5 5") ==
               [{:M, 10.0, 10.0}, {:L, 20.0, 10.0}, {:L, 20.0, 20.0}, :Z, {:L, 15.0, 15.0}]
    end

    test "several subpaths" do
      assert parse("M0 0 L1 1 M5 5 L6 6") == [
               {:M, +0.0, +0.0},
               {:L, 1.0, 1.0},
               {:M, 5.0, 5.0},
               {:L, 6.0, 6.0}
             ]
    end
  end

  describe "number syntax" do
    test "commas, any whitespace and no separator before a sign" do
      assert parse("M10,20L30-40") == [{:M, 10.0, 20.0}, {:L, 30.0, -40.0}]
      assert parse("M 10\n20\tL 1 ,2") == [{:M, 10.0, 20.0}, {:L, 1.0, 2.0}]
    end

    test "numbers that run together at a second decimal point" do
      assert parse("M.5.5L1.5.5") == [{:M, 0.5, 0.5}, {:L, 1.5, 0.5}]
      assert parse("M0 0l.1.2") == [{:M, +0.0, +0.0}, {:L, 0.1, 0.2}]
    end

    test "exponents and plain signs" do
      assert parse("M1e2 -2.5E-1 L+3 +4") == [{:M, 100.0, -0.25}, {:L, 3.0, 4.0}]
      assert parse("M1.e1 2.") == [{:M, 10.0, 2.0}]
    end

    test "leading and trailing space" do
      assert parse("  M1 2  ") == [{:M, 1.0, 2.0}]
    end
  end

  describe "curves" do
    test "cubic, absolute and relative" do
      assert parse("M0 0 C1 2 3 4 5 6") == [{:M, +0.0, +0.0}, {:C, 1.0, 2.0, 3.0, 4.0, 5.0, 6.0}]

      assert parse("M10 10 c1 2 3 4 5 6") == [
               {:M, 10.0, 10.0},
               {:C, 11.0, 12.0, 13.0, 14.0, 15.0, 16.0}
             ]
    end

    test "smooth cubic mirrors the previous control point" do
      assert [_, _, {:C, x1, y1, 7.0, 6.0, 8.0, 8.0}] = parse("M0 0 C1 1 3 4 5 5 S7 6 8 8")
      assert {x1, y1} == {7.0, 6.0}
    end

    test "smooth cubic without a previous cubic starts at the current point" do
      assert [_, {:C, +0.0, +0.0, 3.0, 4.0, 5.0, 6.0}] = parse("M0 0 S3 4 5 6")
    end

    test "quadratic curves become the equivalent cubic" do
      [_, {:C, c1x, c1y, c2x, c2y, 6.0, +0.0}] = parse("M0 0 Q3 6 6 0")
      assert near?(c1x, 2.0) and near?(c1y, 4.0) and near?(c2x, 4.0) and near?(c2y, 4.0)
    end

    test "smooth quadratic reflects the previous control point" do
      [_, _, {:C, c1x, c1y, _, _, 12.0, +0.0}] = parse("M0 0 Q3 6 6 0 T12 0")
      # reflected control point is (9, -6): the first cubic control is 2/3 of the way to it
      assert near?(c1x, 6 + 2 / 3 * (9 - 6)) and near?(c1y, 0 + 2 / 3 * (-6 - 0))
    end

    test "T after something that isn't a quadratic uses the current point" do
      [_, {:C, c1x, c1y, c2x, c2y, 6.0, +0.0}] = parse("M0 0 T6 0")
      # the control point is the current point (0,0), so both cubic controls lie on the line
      assert {c1x, c1y} == {+0.0, +0.0}
      assert near?(c2x, 2.0) and near?(c2y, +0.0)
    end
  end

  describe "arcs" do
    defp end_point(segments) do
      case List.last(segments) do
        {:L, x, y} -> {x, y}
        {:C, _, _, _, _, x, y} -> {x, y}
      end
    end

    test "a quarter circle ends where asked and stays on the circle" do
      segments = PathData.arc(10.0, +0.0, 10.0, 10.0, 0, false, true, +0.0, 10.0)
      assert length(segments) == 1
      assert {x, y} = end_point(segments)
      assert near?(x, +0.0) and near?(y, 10.0)
      # the circle's centre is (0, 0): the middle of the bezier is on it
      [{:C, x1, y1, x2, y2, ex, ey}] = segments
      mid_x = 0.125 * 10 + 0.375 * x1 + 0.375 * x2 + 0.125 * ex
      mid_y = 0.125 * 0 + 0.375 * y1 + 0.375 * y2 + 0.125 * ey
      assert_in_delta :math.sqrt(mid_x * mid_x + mid_y * mid_y), 10.0, 0.03
    end

    test "sweep direction picks the side the arc bulges to" do
      [{:C, a1x, a1y, _, _, _, _}] =
        PathData.arc(+0.0, +0.0, 10.0, 10.0, 0, false, true, 10.0, 10.0)

      [{:C, b1x, b1y, _, _, _, _}] =
        PathData.arc(+0.0, +0.0, 10.0, 10.0, 0, false, false, 10.0, 10.0)

      # clockwise (sweep) leaves to the right and up; counter-clockwise goes down first
      assert a1x > a1y
      assert b1y > b1x
    end

    test "the large-arc flag chooses the longer way round: three or four pieces instead of one or two" do
      small = PathData.arc(10.0, +0.0, 10.0, 10.0, 0, false, true, +0.0, 10.0)
      large = PathData.arc(10.0, +0.0, 10.0, 10.0, 0, true, true, +0.0, 10.0)
      assert length(small) == 1
      assert length(large) == 3
    end

    test "a semicircle has two pieces and every point is on the circle" do
      segments = PathData.arc(+0.0, +0.0, 5.0, 5.0, 0, false, true, 10.0, +0.0)
      assert length(segments) == 2

      for {:C, _, _, _, _, x, y} <- segments do
        assert_in_delta :math.sqrt((x - 5) ** 2 + y * y), 5.0, 0.001
      end
    end

    test "radii that are too small are scaled up so the arc still fits" do
      segments = PathData.arc(+0.0, +0.0, 1.0, 1.0, 0, false, true, 10.0, +0.0)
      {x, y} = end_point(segments)
      assert near?(x, 10.0) and near?(y, +0.0)
      # it became a half circle of radius 5
      for {:C, _, _, _, _, px, py} <- segments,
          do: assert_in_delta(:math.sqrt((px - 5) ** 2 + py * py), 5.0, 0.001)
    end

    test "a zero radius is a straight line" do
      assert PathData.arc(+0.0, +0.0, +0.0, 5.0, 0, false, true, 10.0, 10.0) == [{:L, 10.0, 10.0}]
      assert PathData.arc(+0.0, +0.0, 5.0, +0.0, 0, false, true, 10.0, 10.0) == [{:L, 10.0, 10.0}]
    end

    test "the same start and end point draws nothing" do
      assert PathData.arc(3.0, 3.0, 5.0, 5.0, 0, false, true, 3.0, 3.0) == []
    end

    test "a rotated ellipse reaches its end point" do
      segments = PathData.arc(+0.0, +0.0, 10.0, 5.0, 30, false, true, 12.0, 4.0)
      {x, y} = end_point(segments)
      assert near?(x, 12.0) and near?(y, 4.0)
    end

    test "negative radii are taken as positive" do
      assert PathData.arc(10.0, +0.0, -10.0, -10.0, 0, false, true, +0.0, 10.0) ==
               PathData.arc(10.0, +0.0, 10.0, 10.0, 0, false, true, +0.0, 10.0)
    end

    test "in path data, with relative coordinates and flags packed without separators" do
      assert [{:M, 10.0, +0.0}, {:C, _, _, _, _, ex, ey}] = parse("M10 0 a10 10 0 01-10 10")
      assert near?(ex, +0.0) and near?(ey, 10.0)
      assert [{:M, _, _}, {:C, _, _, _, _, ex, ey}] = parse("M10 0 A10 10 0 0 1 0 10")
      assert near?(ex, +0.0) and near?(ey, 10.0)
    end

    test "a full circle drawn as two arcs" do
      segments = parse("M0 5 A5 5 0 1 1 10 5 A5 5 0 1 1 0 5 Z")
      assert List.last(segments) == :Z

      for {:C, _, _, _, _, x, y} <- segments,
          do: assert_in_delta(:math.sqrt((x - 5) ** 2 + (y - 5) ** 2), 5.0, 0.001)
    end
  end

  describe "bad data" do
    test "empty and blank data" do
      assert parse("") == []
      assert parse("   ") == []
    end

    test "a path must start with a moveto" do
      assert parse("L10 10") == []
      assert parse("10 10 L1 1") == []
    end

    test "parsing stops at the first error and keeps what came before" do
      assert parse("M0 0 L10 10 L20 x L30 30") == [{:M, +0.0, +0.0}, {:L, 10.0, 10.0}]
      assert parse("M0 0 L10") == [{:M, +0.0, +0.0}]
      assert parse("M0 0 L1 1 Q1 2") == [{:M, +0.0, +0.0}, {:L, 1.0, 1.0}]
    end

    test "an arc with an invalid flag stops" do
      assert parse("M0 0 L1 1 A1 1 0 2 1 5 5") == [{:M, +0.0, +0.0}, {:L, 1.0, 1.0}]
    end

    test "unknown letters stop the path" do
      assert parse("M0 0 L1 1 X 5 5 L9 9") == [{:M, +0.0, +0.0}, {:L, 1.0, 1.0}]
    end

    test "a real icon path parses to its outline" do
      d =
        "M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm0 18c-4.41 0-8-3.59-8-8s3.59-8 8-8 8 3.59 8 8-3.59 8-8 8z"

      segments = parse(d)
      assert hd(segments) == {:M, 12.0, 2.0}
      assert Enum.count(segments, &(&1 == :Z)) == 2
      assert Enum.count(segments, &match?({:M, _, _}, &1)) == 2

      assert Enum.all?(segments, fn
               :Z -> true
               seg -> seg |> Tuple.to_list() |> tl() |> Enum.all?(&is_float/1)
             end)
    end
  end
end
