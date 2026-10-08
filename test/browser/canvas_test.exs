defmodule Browser.CanvasTest do
  use ExUnit.Case, async: true
  alias Browser.Canvas

  # the pixels of a PNG written by `Canvas.to_png/1`, as rows of {r, g, b, a}
  defp decode(png) do
    <<0x89, "PNG\r\n", 0x1A, 0x0A, rest::binary>> = png
    {w, h, idat} = chunks(rest, nil, nil, <<>>)
    raw = :zlib.uncompress(idat)
    row_bytes = w * 4

    for y <- 0..(h - 1) do
      <<0, row::binary-size(^row_bytes)>> = binary_part(raw, y * (row_bytes + 1), row_bytes + 1)
      for <<r, g, b, a <- row>>, do: {r, g, b, a}
    end
  end

  defp chunks(
         <<len::32, type::binary-size(4), data::binary-size(len), crc::32, rest::binary>>,
         w,
         h,
         idat
       ) do
    assert :erlang.crc32(type <> data) == crc

    case type do
      "IHDR" ->
        <<w::32, h::32, 8, 6, 0, 0, 0>> = data
        chunks(rest, w, h, idat)

      "IDAT" ->
        chunks(rest, w, h, idat <> data)

      "IEND" ->
        {w, h, idat}
    end
  end

  test "a new surface is transparent" do
    assert decode(Canvas.to_png(Canvas.new(2, 1))) == [[{0, 0, 0, 0}, {0, 0, 0, 0}]]
  end

  @black {:color, {0, 0, 0, 255}}
  @px_black {0, 0, 0, 255}
  @px_clear {0, 0, 0, 0}

  defp fill(c, x, y, w, h, paint \\ @black), do: Canvas.fill_rect(c, x, y, w, h, paint, 1.0)

  @line %{width: 1.0, cap: :butt, join: :miter, miter: 10.0, dash: nil}

  test "fillRect paints and clearRect erases" do
    c =
      Canvas.new(3, 3)
      |> fill(0, 0, 3, 3)
      |> Canvas.clear_rect(1, 1, 1, 1)

    # a part cannot be cut out of a vector item: the rectangle stays
    assert length(Canvas.ops(c)) == 1

    c = Canvas.clear_rect(c, 0, 0, 3, 3)
    assert Canvas.ops(c) == []
  end

  test "rectangles are clipped to the surface and may have a negative size" do
    red = {:color, {255, 0, 0, 255}}
    c = Canvas.new(2, 2) |> fill(5, 5, -4, -4, red)
    assert decode(Canvas.to_png(c)) == [[@px_clear, @px_clear], [@px_clear, {255, 0, 0, 255}]]
  end

  test "a translucent colour blends over what is there" do
    c =
      Canvas.new(1, 1)
      |> fill(0, 0, 1, 1)
      |> fill(0, 0, 1, 1, {:color, {255, 255, 255, 128}})

    assert [[{r, r, r, 255}]] = decode(Canvas.to_png(c))
    assert r in 127..129
  end

  test "strokeRect draws a line centred on the edge" do
    c = Canvas.new(4, 4) |> Canvas.stroke_rect(1.5, 1.5, 1, 1, @black, @line, 1.0)
    pixels = decode(Canvas.to_png(c))
    assert {0, 0, 0, a} = Enum.at(Enum.at(pixels, 1), 1)
    assert a > 150
    assert {0, 0, 0, b} = Enum.at(Enum.at(pixels, 2), 2)
    assert b > 150
    assert Enum.at(Enum.at(pixels, 0), 0) == @px_clear
  end

  test "a filled triangle covers its inside and leaves the outside" do
    c =
      Canvas.new(10, 10)
      |> Canvas.move_to(0, 0)
      |> Canvas.line_to(10, 0)
      |> Canvas.line_to(0, 10)
      |> Canvas.close_path()
      |> Canvas.fill(@black, :nonzero, 1.0)

    pixels = decode(Canvas.to_png(c))
    assert pixels |> Enum.at(1) |> Enum.at(1) == @px_black
    assert pixels |> Enum.at(8) |> Enum.at(8) == @px_clear
    # the edge pixel is partly covered
    assert {0, 0, 0, a} = pixels |> Enum.at(4) |> Enum.at(5)
    assert a in 100..160
  end

  test "a circle drawn with arc is filled around its centre" do
    c =
      Canvas.new(20, 20)
      |> Canvas.begin_path()
      |> Canvas.arc(10, 10, 6, 0, 2 * :math.pi(), false)
      |> Canvas.fill(@black, :nonzero, 1.0)

    pixels = decode(Canvas.to_png(c))
    assert pixels |> Enum.at(10) |> Enum.at(10) == @px_black
    assert {0, 0, 0, a} = pixels |> Enum.at(10) |> Enum.at(15)
    assert a > 200
    assert pixels |> Enum.at(10) |> Enum.at(17) == @px_clear
    assert pixels |> Enum.at(1) |> Enum.at(1) == @px_clear
  end

  test "evenodd leaves a hole where two rectangles overlap" do
    c =
      Canvas.new(10, 10)
      |> Canvas.rect(0, 0, 10, 10)
      |> Canvas.rect(3, 3, 4, 4)
      |> Canvas.fill(@black, :evenodd, 1.0)

    pixels = decode(Canvas.to_png(c))
    assert pixels |> Enum.at(5) |> Enum.at(5) == @px_clear
    assert pixels |> Enum.at(1) |> Enum.at(1) == @px_black
  end

  test "a stroked line has the width asked for" do
    c =
      Canvas.new(10, 10)
      |> Canvas.move_to(0, 5)
      |> Canvas.line_to(10, 5)
      |> Canvas.stroke(@black, %{@line | width: 4.0}, 1.0)

    pixels = decode(Canvas.to_png(c))
    column = for row <- pixels, do: row |> Enum.at(5) |> elem(3)
    assert column == [0, 0, 0, 255, 255, 255, 255, 0, 0, 0]
  end

  test "a linear gradient runs from one colour to the other" do
    paint = {:linear, {0.0, 0.0, 10.0, 0.0}, [{0.0, {0, 0, 0, 255}}, {1.0, {255, 255, 255, 255}}]}
    c = Canvas.new(10, 1) |> fill(0, 0, 10, 1, paint)
    [[{first, _, _, _} | _] = row] = decode(Canvas.to_png(c))
    {last, _, _, _} = List.last(row)
    assert first < 40 and last > 215
  end

  test "transforms move what is drawn, save and restore bring the old one back" do
    c =
      Canvas.new(10, 10)
      |> Canvas.save()
      |> Canvas.translate(5, 5)
      |> fill(0, 0, 2, 2)

    {c, _} = Canvas.restore(c)
    c = fill(c, 0, 0, 1, 1)
    pixels = decode(Canvas.to_png(c))
    assert pixels |> Enum.at(5) |> Enum.at(5) == @px_black
    assert pixels |> Enum.at(0) |> Enum.at(0) == @px_black
    assert pixels |> Enum.at(2) |> Enum.at(2) == @px_clear
  end

  test "the clip limits what is drawn" do
    c =
      Canvas.new(10, 10)
      |> Canvas.rect(0, 0, 5, 10)
      |> Canvas.clip()
      |> fill(0, 0, 10, 10)

    pixels = decode(Canvas.to_png(c))
    assert pixels |> Enum.at(2) |> Enum.at(2) == @px_black
    assert pixels |> Enum.at(2) |> Enum.at(7) == @px_clear
  end

  test "text becomes a text item at the given point" do
    style = %{
      paint: @black,
      alpha: 1.0,
      font: "bold 20px Arial",
      align: :middle,
      baseline: :alphabetic
    }

    c = Canvas.new(100, 50) |> Canvas.translate(10, 10) |> Canvas.text("Hi", 40, 30, style)

    assert [%{kind: :text, x: 50.0, y: 40.0, size: 20.0, bold: true, anchor: :middle}] =
             Canvas.ops(c)
  end

  test "font strings are read" do
    assert %{
             size: 12.0,
             bold: true,
             italic: true,
             mono: false,
             family: "Helvetica Neue, sans-serif"
           } =
             Canvas.parse_font("italic bold 12px/1.4 Helvetica Neue, sans-serif")

    assert %{size: 16.0, mono: true} = Canvas.parse_font("12pt 'Courier New', monospace")
    assert %{bold: true, size: 14.0} = Canvas.parse_font("600 14px sans-serif")
  end

  test "scaled_ops follows the size of the box" do
    c = Canvas.new(10, 10) |> fill(1, 1, 2, 2)
    [op] = Canvas.scaled_ops(Canvas.ops(c), 2.0, 3.0)
    assert op.segments |> hd() == {:M, 2.0, 3.0}
  end
end
