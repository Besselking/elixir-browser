defmodule Browser.ShadowsTest do
  use ExUnit.Case, async: true
  alias Browser.Shadows

  @black {0, 0, 0, 255}

  defp parse(value, fs \\ 16.0, current \\ @black), do: Shadows.parse(value, fs, current)

  describe "parse/3" do
    test "offsets only: no blur, no spread, current colour" do
      assert [%{dx: 2.0, dy: 3.0, blur: +0.0, spread: +0.0, color: @black, inset?: false}] =
               parse("2px 3px")
    end

    test "blur, spread and colour in either order" do
      assert [%{dx: +0.0, dy: 4.0, blur: 8.0, spread: -2.0, color: {255, 0, 0, 255}}] =
               parse("0 4px 8px -2px red")

      assert [%{blur: 8.0, spread: 2.0, color: {255, 0, 0, 255}}] = parse("red 0 0 8px 2px")
    end

    test "alpha colours" do
      assert [%{color: {0, 0, 0, 51}}] = parse("0 1px 2px rgba(0,0,0,.2)")
      assert [%{color: {0, 0, 0, 38}}] = parse("0 0 5px #00000026")
    end

    test "inset, in front or behind" do
      assert [%{inset?: true, blur: 3.0}] = parse("inset 0 1px 3px #000")
      assert [%{inset?: true}] = parse("0 1px 3px #000 inset")
    end

    test "several shadows keep their order" do
      assert [%{dx: 1.0}, %{dx: 2.0, inset?: true}, %{dx: 3.0}] =
               parse("1px 0 red, inset 2px 0 blue, 3px 0")
    end

    test "em lengths follow the font size, currentcolor takes the given colour" do
      assert [%{dx: 20.0, dy: 10.0, color: {9, 8, 7, 255}}] =
               parse("2em 1em currentcolor", 10.0, {9, 8, 7, 255})
    end

    test "none, empty and invalid shadows give nothing" do
      assert parse("none") == []
      assert parse("") == []
      assert parse("5px") == []
      assert parse("1px 2px 3px 4px 5px red") == []
      assert parse("1px 2px -3px red") == []
      assert parse("1px 2px red blue") == []
      assert parse("banana") == []
    end

    test "an invalid shadow in a list doesn't drop the others" do
      assert [%{dx: 1.0}, %{dx: 3.0}] = parse("1px 1px, junk, 3px 3px")
    end
  end

  describe "blur_layers/3" do
    test "no blur is a single solid layer at the spread" do
      assert Shadows.blur_layers(+0.0, 4.0, 200) == [%{inflate: 4.0, alpha: 200}]
      assert Shadows.blur_layers(-1.0, +0.0, 255) == [%{inflate: +0.0, alpha: 255}]
    end

    test "a blur is a stack from large to small around the spread" do
      layers = Shadows.blur_layers(6.0, 2.0, 128)
      assert length(layers) == 6
      inflates = Enum.map(layers, & &1.inflate)
      assert hd(inflates) == 8.0 and List.last(inflates) == -4.0
      assert inflates == Enum.sort(inflates, :desc)
    end

    test "stacked, the layers add up to the shadow's opacity" do
      for blur <- [2.0, 5.0, 12.0, 40.0], total <- [255, 128, 40] do
        layers = Shadows.blur_layers(blur, +0.0, total)
        covered = 1 - Enum.reduce(layers, 1.0, fn %{alpha: a}, acc -> acc * (1 - a / 255) end)

        assert_in_delta covered * 255,
                        total,
                        max(6.0, total * 0.12),
                        "blur #{blur} alpha #{total}"
      end
    end

    test "the number of layers is capped" do
      assert length(Shadows.blur_layers(500.0, +0.0, 255)) == 12
      assert length(Shadows.blur_layers(0.5, +0.0, 255)) == 2
    end

    test "every layer is at least faintly visible" do
      assert Enum.all?(Shadows.blur_layers(10.0, +0.0, 3), &(&1.alpha >= 1))
    end
  end

  describe "outer_layers/3" do
    defp shadow(attrs),
      do:
        Map.merge(
          %{dx: +0.0, dy: +0.0, blur: +0.0, spread: +0.0, color: {0, 0, 0, 100}, inset?: false},
          attrs
        )

    test "an unblurred shadow is the box shape moved by the offset" do
      assert [%{rect: {13, 24, 100, 50}, color: {0, 0, 0, 100}, radii: nil}] =
               Shadows.outer_layers(shadow(%{dx: 3.0, dy: 4.0}), {10, 20, 100, 50}, nil)
    end

    test "the spread grows every side" do
      assert [%{rect: {5, 15, 110, 60}}] =
               Shadows.outer_layers(shadow(%{spread: 5.0}), {10, 20, 100, 50}, nil)

      assert [%{rect: {15, 25, 90, 40}}] =
               Shadows.outer_layers(shadow(%{spread: -5.0}), {10, 20, 100, 50}, nil)
    end

    test "corners that were round follow the spread, square ones stay square" do
      radii = {{8, 8}, {0, 0}, {8, 8}, {0, 0}}

      assert [%{radii: {{13, 13}, {0, 0}, {13, 13}, {0, 0}}}] =
               Shadows.outer_layers(shadow(%{spread: 5.0}), {0, 0, 100, 50}, radii)

      assert [%{radii: {{3, 3}, _, _, _}}] =
               Shadows.outer_layers(shadow(%{spread: -5.0}), {0, 0, 100, 50}, radii)

      assert [%{radii: {{0, 0}, _, _, _}}] =
               Shadows.outer_layers(shadow(%{spread: -20.0}), {0, 0, 100, 50}, radii)
    end

    test "a blur gives several layers, the outermost first and bigger than the box" do
      layers = Shadows.outer_layers(shadow(%{blur: 8.0}), {10, 20, 100, 50}, nil)
      assert length(layers) == 8
      [{ox, oy, ow, oh} | _] = Enum.map(layers, & &1.rect)
      assert ox < 10 and oy < 20 and ow > 100 and oh > 50
      widths = Enum.map(layers, fn %{rect: {_, _, w, _}} -> w end)
      assert widths == Enum.sort(widths, :desc)
    end

    test "layers that shrink to nothing are dropped" do
      layers = Shadows.outer_layers(shadow(%{blur: 20.0}), {0, 0, 10, 10}, nil)
      assert Enum.all?(layers, fn %{rect: {_, _, w, h}} -> w > 0 and h > 0 end)
      assert layers != []
    end

    test "all coordinates are whole numbers" do
      for %{rect: {x, y, w, h}} <-
            Shadows.outer_layers(shadow(%{dx: 0.5, blur: 7.3, spread: 1.2}), {3, 4, 101, 57}, nil),
          do: assert(Enum.all?([x, y, w, h], &is_integer/1))
    end
  end

  describe "inset_layers/3" do
    test "an unblurred inset shadow is a frame around a hole moved by the offset" do
      assert [%{hole: %{rect: {10, 22, 100, 50}}, color: {0, 0, 0, 100}}] =
               Shadows.inset_layers(shadow(%{dy: 2.0}), {10, 20, 100, 50}, nil)
    end

    test "the spread shrinks the hole" do
      assert [%{hole: %{rect: {15, 25, 90, 40}}}] =
               Shadows.inset_layers(shadow(%{spread: 5.0}), {10, 20, 100, 50}, nil)
    end

    test "a hole that has vanished means the whole box is shadow" do
      assert [%{hole: nil}] = Shadows.inset_layers(shadow(%{spread: 30.0}), {0, 0, 40, 40}, nil)
    end

    test "inner corners shrink by the spread" do
      radii = {{10, 10}, {10, 10}, {10, 10}, {10, 10}}

      assert [%{hole: %{radii: {{6, 6}, _, _, _}}}] =
               Shadows.inset_layers(shadow(%{spread: 4.0}), {0, 0, 100, 50}, radii)
    end

    test "a blur gives frames with growing holes" do
      layers = Shadows.inset_layers(shadow(%{blur: 6.0}), {0, 0, 100, 50}, nil)
      assert length(layers) == 6
      widths = for %{hole: %{rect: {_, _, w, _}}} <- layers, do: w
      assert widths == Enum.sort(widths, :asc)
    end
  end
end
