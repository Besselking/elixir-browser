defmodule Browser.ImageBoxTest do
  use ExUnit.Case, async: true
  alias Browser.ImageBox

  defp size(intrinsic, attrs \\ %{}, css \\ %{}, avail \\ 800),
    do: ImageBox.size(intrinsic, attrs, css, avail)

  test "no size given: the picture's own size" do
    assert size({120, 80}) == {120, 80}
  end

  test "nothing known yet: zero" do
    assert size(nil) == {0, 0}
  end

  test "attributes set the size; with one, the other follows the aspect ratio" do
    assert size({120, 80}, %{w: 60, h: 60}) == {60, 60}
    assert size({120, 80}, %{w: 60}) == {60, 40}
    assert size({120, 80}, %{h: 40}) == {60, 40}
  end

  test "css wins over attributes" do
    assert size({120, 80}, %{w: 60, h: 60}, %{w: 30.0, h: 30.0}) == {30, 30}
    assert size({120, 80}, %{w: 60}, %{w: 90.0}) == {90, 60}
  end

  test "an explicit auto ignores the attribute, so the ratio decides (img { height: auto })" do
    assert size({120, 80}, %{w: 60, h: 60}, %{h: :auto}) == {60, 40}
    assert size({120, 80}, %{w: 60, h: 60}, %{w: :auto}) == {90, 60}
    assert size({120, 80}, %{w: 60, h: 60}, %{w: :auto, h: :auto}) == {120, 80}
    # the usual responsive recipe, with a container narrower than the picture
    assert size({400, 200}, %{w: 400, h: 200}, %{maxw: {:pct, 1.0}, h: :auto}, 250) == {250, 125}
  end

  test "percentage widths refer to the container, height follows the ratio" do
    assert size({120, 80}, %{}, %{w: {:pct, 0.5}}, 400) == {200, 133}
    assert size({120, 80}, %{}, %{w: {:pct, 1.0}}, 600) == {600, 400}
  end

  test "percentage heights are ignored" do
    assert size({120, 80}, %{}, %{h: {:pct, 0.5}}, 400) == {120, 80}
  end

  test "without a picture the attributes' ratio is used" do
    assert size(nil, %{w: 200, h: 100}) == {200, 100}
    assert size(nil, %{w: 200}) == {200, 0}
    # the height attribute still applies unless CSS says `height: auto`
    assert size(nil, %{w: 200, h: 100}, %{w: 100.0}) == {100, 100}
    assert size(nil, %{w: 200, h: 100}, %{w: 100.0, h: :auto}) == {100, 50}
  end

  test "max-width limits and an automatic height keeps the ratio" do
    assert size({400, 200}, %{}, %{maxw: {:pct, 1.0}}, 300) == {300, 150}
    assert size({400, 200}, %{}, %{maxw: 100.0}) == {100, 50}
    assert size({400, 200}, %{}, %{w: 400.0, maxw: 100.0}) == {100, 50}
  end

  test "a fixed height is kept when the width is limited" do
    assert size({400, 200}, %{}, %{h: 150.0, maxw: 100.0}) == {100, 150}
  end

  test "min-width raises and scales" do
    assert size({40, 20}, %{}, %{minw: 100.0}) == {100, 50}
    assert size({400, 200}, %{}, %{minw: 100.0}) == {400, 200}
  end

  test "max-height and min-height keep the ratio of an automatic width" do
    assert size({400, 200}, %{}, %{maxh: 100.0}) == {200, 100}
    assert size({40, 20}, %{}, %{minh: 40.0}) == {80, 40}
    assert size({400, 200}, %{}, %{w: 300.0, maxh: 100.0}) == {300, 100}
  end

  test "results are whole, non-negative pixels" do
    assert size({100, 30}, %{w: 33}) == {33, 10}
    assert size({100, 100}, %{w: -5}) == {0, 0}
    assert size({3, 2}, %{}, %{w: {:pct, 0.333}}, 100) == {33, 22}
  end

  test "a degenerate picture doesn't divide by zero" do
    assert size({0, 0}, %{w: 50}) == {50, 0}
    assert size({100, 0}, %{h: 20}) == {100, 20}
  end

  test "fixed?: both dimensions given, by attributes or css" do
    assert ImageBox.fixed?(%{w: 5, h: 5}, %{})
    assert ImageBox.fixed?(%{w: 5}, %{h: 7.0})
    assert ImageBox.fixed?(%{}, %{w: {:pct, 0.5}, h: 7.0})
    refute ImageBox.fixed?(%{w: 5}, %{})
    refute ImageBox.fixed?(%{w: 5, h: 5}, %{h: :auto})
    refute ImageBox.fixed?(%{}, %{})
  end

  test "a declared aspect-ratio gives the height of a picture with only a width" do
    assert size({120, 80}, %{}, %{w: 90.0, ratio: {1.0, :sizing}}) == {90, 90}
    # `auto 1` keeps the picture's own ratio when it has one
    assert size({120, 80}, %{}, %{w: 90.0, ratio: {1.0, :content}}) == {90, 60}
    assert size(nil, %{}, %{w: 90.0, ratio: {1.0, :content}}) == {90, 90}
  end

  describe "fit/4" do
    test "fill (and unknown sizes) draw into the whole box" do
      assert ImageBox.fit({200, 100}, {100, 100}, nil, nil) == nil
      assert ImageBox.fit({200, 100}, {100, 100}, "fill", nil) == nil
      assert ImageBox.fit(nil, {100, 100}, "cover", nil) == nil
    end

    test "contain keeps the ratio inside the box and centres it" do
      assert ImageBox.fit({200, 100}, {100, 100}, "contain", nil) == {0.0, 25.0, 100.0, 50.0}
    end

    test "cover fills the box, cropping the long side around the centre" do
      assert ImageBox.fit({200, 100}, {100, 100}, "cover", nil) == {-50.0, 0.0, 200.0, 100.0}
    end

    test "object-position moves the picture" do
      pos = {{:pct, 0.0}, {:pct, 0.0}}
      assert ImageBox.fit({200, 100}, {100, 100}, "cover", pos) == {0.0, 0.0, 200.0, 100.0}
    end

    test "none keeps the size, scale-down only shrinks" do
      assert ImageBox.fit({40, 40}, {100, 100}, "none", nil) == {30.0, 30.0, 40.0, 40.0}
      assert ImageBox.fit({40, 40}, {100, 100}, "scale-down", nil) == {30.0, 30.0, 40.0, 40.0}
      assert ImageBox.fit({200, 200}, {100, 100}, "scale-down", nil) == {0.0, 0.0, 100.0, 100.0}
    end
  end
end
