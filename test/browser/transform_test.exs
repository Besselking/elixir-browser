defmodule Browser.TransformTest do
  use ExUnit.Case, async: true

  alias Browser.Transform

  # a 100 x 50 box at (10, 20): its centre is (60, 45)
  @box {10, 20, 100, 50}

  defp m(c, opts \\ []), do: Transform.matrix(c, @box, opts)

  defp near({x, y}, {ex, ey}), do: abs(x - ex) < 1.0e-6 and abs(y - ey) < 1.0e-6

  defp point(matrix, x, y), do: Transform.apply_to(matrix, x, y)

  test "transformed?/1" do
    assert Transform.transformed?(%{"transform" => "rotate(5deg)"})
    assert Transform.transformed?(%{"scale" => "2"})
    refute Transform.transformed?(%{"transform" => "none"})
    refute Transform.transformed?(%{"transform" => ""})
    refute Transform.transformed?(%{})
  end

  test "nothing to do gives nil" do
    assert m(%{}) == nil
    assert m(%{"transform" => "none"}) == nil
    assert m(%{"transform" => "scale(1)"}) == nil
    assert m(%{"transform" => "rotate(0deg)"}) == nil
  end

  test "rotation turns about the centre of the box" do
    matrix = m(%{"transform" => "rotate(90deg)"})
    # the centre stays where it is
    assert near(point(matrix, 60, 45), {60, 45})
    # a point to the right of the centre goes below it
    assert near(point(matrix, 110, 45), {60, 95})
  end

  test "half a turn flips about the centre" do
    matrix = m(%{"transform" => "rotate(180deg)"})
    assert near(point(matrix, 10, 20), {110, 70})
    assert near(point(m(%{"transform" => "rotate(0.5turn)"}), 10, 20), {110, 70})
    assert near(point(m(%{"transform" => "rotate(3.141592653589793rad)"}), 10, 20), {110, 70})
    assert near(point(m(%{"transform" => "rotate(200grad)"}), 10, 20), {110, 70})
  end

  test "scale grows about the centre" do
    matrix = m(%{"transform" => "scale(2)"})
    assert near(point(matrix, 60, 45), {60, 45})
    assert near(point(matrix, 110, 45), {160, 45})
    matrix = m(%{"transform" => "scale(2, 0.5)"})
    assert near(point(matrix, 110, 70), {160, 57.5})
    assert near(point(m(%{"transform" => "scaleX(3)"}), 110, 45), {210, 45})
    assert near(point(m(%{"transform" => "scaleY(3)"}), 60, 70), {60, 120})
  end

  test "scale as a percentage" do
    assert near(point(m(%{"transform" => "scale(150%)"}), 110, 45), {135, 45})
  end

  test "translate, in px and as a share of the box" do
    assert near(point(m(%{"transform" => "translate(5px, 7px)"}), 0, 0), {5, 7})
    assert near(point(m(%{"transform" => "translateX(10px)"}), 0, 0), {10, 0})
    assert near(point(m(%{"transform" => "translateY(-10%)"}), 0, 0), {0, -5})
    assert near(point(m(%{"transform" => "translate(50%, 100%)"}), 0, 0), {50, 50})
  end

  test "translate can be left out, for boxes placed with it" do
    assert m(%{"transform" => "translate(5px, 7px)"}, translate: false) == nil

    matrix = m(%{"transform" => "translate(5px, 7px) rotate(90deg)"}, translate: false)
    assert near(point(matrix, 110, 45), {60, 95})
  end

  test "a list applies from the right to the points: the last function first" do
    matrix = m(%{"transform" => "translate(100px, 0) scale(2)"})
    # scale about the centre first (110 -> 160), then 100px to the right
    assert near(point(matrix, 110, 45), {260, 45})
  end

  test "the individual properties" do
    assert near(point(m(%{"rotate" => "90deg"}), 110, 45), {60, 95})
    assert near(point(m(%{"scale" => "2"}), 110, 45), {160, 45})
    assert near(point(m(%{"scale" => "2 1"}), 110, 70), {160, 70})
    assert near(point(m(%{"translate" => "10px 20px"}), 0, 0), {10, 20})
    assert near(point(m(%{"translate" => "10px"}), 0, 0), {10, 0})
  end

  test "translate, rotate and scale come before transform" do
    both = m(%{"rotate" => "90deg", "transform" => "scale(2)"})
    # scale 2 first (110 -> 160), then the quarter turn about the centre
    assert near(point(both, 110, 45), {60, 145})
  end

  test "transform-origin" do
    corner = m(%{"transform" => "rotate(180deg)", "transform-origin" => "left top"})
    assert near(point(corner, 110, 70), {-90, -30})

    pct = m(%{"transform" => "scale(2)", "transform-origin" => "0 0"})
    assert near(point(pct, 20, 30), {30, 40})

    px = m(%{"transform" => "scale(2)", "transform-origin" => "10px 20px"})
    # the origin is 10px right and 20px down in the box, i.e. at (20, 40) on the page
    assert near(point(px, 20, 40), {20, 40})
    assert near(point(px, 30, 50), {40, 60})

    bottom = m(%{"transform" => "scale(2)", "transform-origin" => "bottom right"})
    assert near(point(bottom, 110, 70), {110, 70})

    assert near(
             point(m(%{"transform" => "scale(2)", "transform-origin" => "100% 100%"}), 110, 70),
             {110, 70}
           )

    assert near(
             point(m(%{"transform" => "scale(2)", "transform-origin" => "right"}), 110, 45),
             {110, 45}
           )
  end

  test "skew and matrix" do
    sk = m(%{"transform" => "skewX(45deg)"})
    # 25px below the centre moves 25px to the right
    assert near(point(sk, 60, 70), {85, 70})
    assert near(point(m(%{"transform" => "matrix(1, 0, 0, 1, 5, 6)"}), 0, 0), {5, 6})
  end

  test "em and rem lengths" do
    assert near(point(m(%{"transform" => "translateX(2em)", "font-size" => 10.0}), 0, 0), {20, 0})
    assert near(point(m(%{"transform" => "translateX(1rem)"}), 0, 0), {16, 0})
  end

  test "unknown or broken functions give nil, not a crash" do
    assert m(%{"transform" => "wobble(3)"}) == nil
    assert m(%{"transform" => "rotate(banana)"}) == nil
    assert m(%{"transform" => "scale()"}) == nil
    assert m(%{"transform" => "matrix(1,2,3)"}) == nil
  end

  test "a flat matrix collapses the box" do
    assert m(%{"transform" => "scale(0)"}) == :collapsed
    assert m(%{"transform" => "scaleX(0)"}) == :collapsed
  end

  test "moved/3 keeps the transformation the same for the item that moved" do
    matrix = m(%{"transform" => "rotate(90deg)"})
    shifted = Transform.moved(matrix, 30, 40)
    # the same box 30 right and 40 down is turned about its own (moved) centre
    assert near(point(shifted, 110 + 30, 45 + 40), {60 + 30, 95 + 40})
    assert near(point(shifted, 60 + 30, 45 + 40), {60 + 30, 45 + 40})
  end

  test "multiply/2 applies the second matrix first" do
    translate = {1.0, 0.0, 0.0, 1.0, 10.0, 0.0}
    scale = {2.0, 0.0, 0.0, 2.0, 0.0, 0.0}
    assert near(point(Transform.multiply(translate, scale), 1, 1), {12, 2})
    assert near(point(Transform.multiply(scale, translate), 1, 1), {22, 2})
  end

  test "invert/1 undoes a matrix" do
    matrix = m(%{"transform" => "rotate(30deg) scale(2, 3) translate(5px, 6px)"})
    inverse = Transform.invert(matrix)
    {x, y} = point(matrix, 33, 44)
    assert near(point(inverse, x, y), {33, 44})
  end

  test "a flat matrix has no inverse" do
    assert Transform.invert({0.0, 0.0, 0.0, 0.0, 1.0, 1.0}) == nil
  end

  test "unapply/3 undoes the outermost transformation first" do
    inner = {1.0, 0.0, 0.0, 1.0, 10.0, 0.0}
    outer = {2.0, 0.0, 0.0, 2.0, 0.0, 0.0}
    # an item at (1, 1) is moved 10 right by the inner box, then doubled by the outer one
    {x, y} = point(Transform.multiply(outer, inner), 1, 1)
    assert near({x, y}, {22, 2})
    assert near(Transform.unapply([inner, outer], x, y), {1, 1})
    assert Transform.unapply([{0.0, 0.0, 0.0, 0.0, 0.0, 0.0}], 1, 1) == nil
  end
end
