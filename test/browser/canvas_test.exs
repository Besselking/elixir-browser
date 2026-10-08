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

  test "fillRect paints and clearRect erases" do
    black = {0, 0, 0, 255}
    clear = {0, 0, 0, 0}

    c =
      Canvas.new(3, 3)
      |> Canvas.fill_rect(0, 0, 3, 3, black)
      |> Canvas.clear_rect(1, 1, 1, 1)

    assert decode(Canvas.to_png(c)) == [
             [black, black, black],
             [black, clear, black],
             [black, black, black]
           ]
  end

  test "rectangles are clipped to the surface and may have a negative size" do
    red = {255, 0, 0, 255}
    c = Canvas.new(2, 2) |> Canvas.fill_rect(5, 5, -4, -4, red)
    assert decode(Canvas.to_png(c)) == [[{0, 0, 0, 0}, {0, 0, 0, 0}], [{0, 0, 0, 0}, red]]
  end

  test "a translucent colour blends over what is there" do
    c =
      Canvas.new(1, 1)
      |> Canvas.fill_rect(0, 0, 1, 1, {0, 0, 0, 255})
      |> Canvas.fill_rect(0, 0, 1, 1, {255, 255, 255, 128})

    assert [[{r, r, r, 255}]] = decode(Canvas.to_png(c))
    assert r in 127..129
  end

  test "strokeRect draws a line centred on the edge" do
    black = {0, 0, 0, 255}
    c = Canvas.new(4, 4) |> Canvas.stroke_rect(1.5, 1.5, 1, 1, 1, black)
    pixels = decode(Canvas.to_png(c))
    assert Enum.at(Enum.at(pixels, 1), 1) == black
    assert Enum.at(Enum.at(pixels, 2), 2) == black
    assert Enum.at(Enum.at(pixels, 0), 0) == {0, 0, 0, 0}
  end
end
