defmodule Browser.Canvas do
  @moduledoc """
  The pixels behind a script's `<canvas>` 2D context: a RGBA surface that scripts fill with
  rectangles, and its PNG encoding for `toDataURL`.

  Only axis-aligned rectangles are drawn (`fillRect`, `clearRect`, `strokeRect`), without
  anti-aliasing: the edges of a rectangle snap to whole pixels. This is enough for pages that
  draw blocks of colour, such as QR codes, and then show the result as an image.
  """

  @max_pixels 16_000_000

  defstruct w: 300, h: 150, rows: %{}

  @type color :: {0..255, 0..255, 0..255, 0..255}
  @type t :: %__MODULE__{w: pos_integer, h: pos_integer, rows: %{integer => binary}}

  @doc "A transparent surface; sizes are clamped to 1 and to #{@max_pixels} pixels in all."
  @spec new(number, number) :: t
  def new(w, h) do
    w = w |> trunc() |> max(1)
    h = h |> trunc() |> max(1)
    if w * h > @max_pixels, do: %__MODULE__{w: 1, h: 1}, else: %__MODULE__{w: w, h: h}
  end

  @doc "Paints `color` over the rectangle (alpha-blended), or replaces the pixels when `mode` is `:replace`."
  @spec fill_rect(t, number, number, number, number, color, :over | :replace) :: t
  def fill_rect(%__MODULE__{} = c, x, y, w, h, color, mode \\ :over) do
    # a negative size draws to the left of or above the origin
    {x, w} = if w < 0, do: {x + w, -w}, else: {x, w}
    {y, h} = if h < 0, do: {y + h, -h}, else: {y, h}
    x0 = x |> round() |> max(0)
    x1 = (x + w) |> round() |> min(c.w)
    y0 = y |> round() |> max(0)
    y1 = (y + h) |> round() |> min(c.h)

    if x1 <= x0 or y1 <= y0 or (mode == :over and elem(color, 3) == 0) do
      c
    else
      rows =
        Enum.reduce(y0..(y1 - 1), c.rows, fn row, rows ->
          Map.put(
            rows,
            row,
            paint_row(Map.get(rows, row) || blank_row(c.w), x0, x1 - x0, color, mode)
          )
        end)

      %{c | rows: rows}
    end
  end

  @doc "Outlines the rectangle with a line `line_width` wide, centred on its edges."
  @spec stroke_rect(t, number, number, number, number, number, color) :: t
  def stroke_rect(c, x, y, w, h, line_width, color) do
    lw = max(line_width, 0)
    half = lw / 2

    if lw == 0 do
      c
    else
      c
      |> fill_rect(x - half, y - half, w + lw, lw, color)
      |> fill_rect(x - half, y + h - half, w + lw, lw, color)
      |> fill_rect(x - half, y + half, lw, h - lw, color)
      |> fill_rect(x + w - half, y + half, lw, h - lw, color)
    end
  end

  @doc "Makes the rectangle transparent."
  @spec clear_rect(t, number, number, number, number) :: t
  def clear_rect(c, x, y, w, h), do: fill_rect(c, x, y, w, h, {0, 0, 0, 0}, :replace)

  @doc "The surface as a PNG file."
  @spec to_png(t) :: binary
  def to_png(%__MODULE__{w: w, h: h, rows: rows}) do
    blank = blank_row(w)

    raw =
      for y <- 0..(h - 1), into: <<>> do
        <<0, Map.get(rows, y, blank)::binary>>
      end

    ihdr = <<w::32, h::32, 8, 6, 0, 0, 0>>

    <<0x89, "PNG\r\n", 0x1A, 0x0A>> <>
      chunk("IHDR", ihdr) <> chunk("IDAT", :zlib.compress(raw)) <> chunk("IEND", <<>>)
  end

  @doc "A `data:` URL holding the PNG."
  @spec to_data_url(t) :: String.t()
  def to_data_url(c), do: "data:image/png;base64," <> Base.encode64(to_png(c))

  defp chunk(type, data) do
    body = type <> data
    <<byte_size(data)::32, body::binary, :erlang.crc32(body)::32>>
  end

  defp blank_row(w), do: :binary.copy(<<0, 0, 0, 0>>, w)

  defp paint_row(row, x, n, {r, g, b, 255}, _mode),
    do: splice(row, x, n, :binary.copy(<<r, g, b, 255>>, n))

  defp paint_row(row, x, n, color, :replace),
    do: splice(row, x, n, :binary.copy(pixel(color), n))

  defp paint_row(row, x, n, {r, g, b, a}, :over) do
    over =
      for <<dr, dg, db, da <- binary_part(row, x * 4, n * 4)>>, into: <<>> do
        out_a = a + da * (255 - a) / 255
        mix = fn s, d -> round((s * a + d * da * (255 - a) / 255) / out_a) end
        <<mix.(r, dr), mix.(g, dg), mix.(b, db), round(out_a)>>
      end

    splice(row, x, n, over)
  end

  defp pixel({r, g, b, a}), do: <<r, g, b, a>>

  defp splice(row, x, n, bytes) do
    {skip, len} = {x * 4, n * 4}
    <<head::binary-size(^skip), _::binary-size(^len), tail::binary>> = row
    <<head::binary, bytes::binary, tail::binary>>
  end
end
