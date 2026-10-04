defmodule Browser.Reftest.Raster do
  @moduledoc """
  A small software painter for reftests: turns laid-out items into a pixel grid without a
  window, so two pages can be compared exactly and the comparison runs anywhere.

  It paints what the layout decides, not what a font rasteriser would: backgrounds and borders
  (square corners, every border style solid), and text as one block per character. The Ahem
  font that most layout tests use is exactly that, an em square for every glyph; for other
  fonts a block's colour depends on its character, so text only matches text that is the same.
  Pictures, shadows and gradients are left out.
  """

  @doc "A `width` x `height` grid of `color`: a tuple of rows, each a binary of RGB triples."
  def new(width, height, color) do
    row = :binary.copy(pixel(color), width)
    List.to_tuple(List.duplicate(row, height))
  end

  @doc "Paints `items` (from `Browser.Layout.layout/5`) on a fresh grid."
  def paint(items, width, height) do
    canvas = Enum.find_value(items, {255, 255, 255}, &(&1.type == :canvas && &1.color))

    Enum.reduce(items, new(width, height, canvas), fn item, grid ->
      draw(grid, item, width, height)
    end)
  end

  @doc "How many pixels differ and the first place (`{x, y}`), or `nil` when the grids match."
  def diff(a, b) when tuple_size(a) == tuple_size(b) do
    a
    |> Tuple.to_list()
    |> Enum.zip(Tuple.to_list(b))
    |> Enum.with_index()
    |> Enum.reduce(nil, fn
      {{same, same}, _y}, acc ->
        acc

      {{ra, rb}, y}, acc ->
        {count, first_x} = row_diff(ra, rb, 0, 0, nil)
        {total, first} = acc || {0, {first_x, y}}
        {total + count, first}
    end)
  end

  def diff(_, _), do: {:infinity, {0, 0}}

  defp row_diff(<<p::binary-size(3), ra::binary>>, <<p::binary-size(3), rb::binary>>, x, n, f),
    do: row_diff(ra, rb, x + 1, n, f)

  defp row_diff(<<_::binary-size(3), ra::binary>>, <<_::binary-size(3), rb::binary>>, x, n, f),
    do: row_diff(ra, rb, x + 1, n + 1, f || x)

  defp row_diff(_, _, _, n, f), do: {n, f}

  @doc "The grid as a binary PPM picture."
  def ppm(grid, width) do
    rows = Tuple.to_list(grid)
    ["P6\n#{width} #{length(rows)}\n255\n" | rows] |> IO.iodata_to_binary()
  end

  # -- items ------------------------------------------------------------------------------

  defp draw(grid, %{type: :rect} = r, w, h) do
    clip = clip_box(r, w, h)
    grid = if r.color, do: fill(grid, r.x, r.y, r.w, r.h, r.color, clip), else: grid
    borders(grid, r, clip)
  end

  defp draw(grid, %{type: :hr} = r, w, h),
    do: fill(grid, r.x, r.y, r.w, 1, {170, 170, 170}, clip_box(r, w, h))

  defp draw(grid, %{type: :image} = i, w, h) do
    c = :erlang.phash2(Map.get(i, :url))

    fill(
      grid,
      i.x,
      i.y,
      i.w,
      i.h,
      {rem(c, 200) + 30, rem(div(c, 200), 200) + 30, 120},
      clip_box(i, w, h)
    )
  end

  defp draw(grid, %{type: :text, hidden: true}, _w, _h), do: grid

  defp draw(grid, %{type: :text} = t, w, h), do: text(grid, t, clip_box(t, w, h))

  defp draw(grid, _item, _w, _h), do: grid

  defp clip_box(%{clip: %{x: x, y: y, w: cw, h: ch}}, w, h),
    do: {max(x, 0), max(y, 0), min(x + cw, w), min(y + ch, h)}

  defp clip_box(_item, w, h), do: {0, 0, w, h}

  defp borders(grid, %{border: %{w: {bt, br, bb, bl}, c: {tc, rc, bc, lc}}} = r, clip) do
    grid
    |> side(r.x, r.y, r.w, bt, tc, clip)
    |> side(r.x, r.y + r.h - bb, r.w, bb, bc, clip)
    |> side(r.x, r.y, bl, r.h, lc, clip)
    |> side(r.x + r.w - br, r.y, br, r.h, rc, clip)
  end

  defp borders(grid, _r, _clip), do: grid

  defp side(grid, _x, _y, w, h, _c, _clip) when w <= 0 or h <= 0, do: grid
  defp side(grid, _x, _y, _w, _h, nil, _clip), do: grid
  defp side(grid, x, y, w, h, c, clip), do: fill(grid, x, y, w, h, c, clip)

  # -- text ---------------------------------------------------------------------------------

  defp text(grid, t, clip) do
    size = t.size
    ahem? = String.contains?(to_string(Map.get(t, :family)), "ahem")
    adv = advance(t)
    {gw, gh, gy} = glyph_box(t, size, ahem?, adv)

    {grid, _} =
      t.text
      |> String.graphemes()
      |> Enum.reduce({grid, 0}, fn ch, {g, i} ->
        x = t.x + round(i * adv * size)

        g =
          if String.trim(ch) == "",
            do: g,
            else: fill(g, x, gy, gw, gh, glyph_color(t.color, ch, t, ahem?), clip)

        {g, i + 1}
      end)

    width = round(String.length(t.text) * adv * size)

    grid =
      if Map.get(t, :underline),
        do: fill(grid, t.x, t.y + round(t.h * 0.9), width, 1, t.color, clip),
        else: grid

    if Map.get(t, :strike),
      do: fill(grid, t.x, t.y + div(t.h, 2), width, 1, t.color, clip),
      else: grid
  end

  # the advance per character, in em (as `Browser.Reftest.measure/2` has it)
  defp advance(t) do
    cond do
      String.contains?(to_string(Map.get(t, :family)), "ahem") -> 1.0
      Map.get(t, :mono) -> 0.6
      true -> 0.52
    end
  end

  defp glyph_box(t, size, true, adv), do: {round(adv * size), size, t.y + div(t.h - size, 2)}

  defp glyph_box(t, size, false, adv),
    do: {max(round(adv * size) - 1, 1), max(round(size * 0.7), 1), t.y + round(t.h * 0.15)}

  defp glyph_color(color, _ch, _t, true), do: color

  defp glyph_color({r, g, b}, ch, t, false) do
    <<code::utf8>> = ch

    salt =
      code * 31 + if(Map.get(t, :bold), do: 7, else: 0) + if(Map.get(t, :italic), do: 13, else: 0)

    {rem(r + salt, 256), rem(g + salt * 3, 256), rem(b + salt * 5, 256)}
  end

  defp glyph_color(color, _ch, _t, false), do: color

  # -- pixels -------------------------------------------------------------------------------

  defp pixel({r, g, b}), do: <<r, g, b>>
  defp pixel({r, g, b, _a}), do: <<r, g, b>>
  defp pixel(_), do: <<255, 255, 255>>

  defp opaque?({_, _, _, a}), do: a >= 128
  defp opaque?(_), do: true

  defp fill(grid, x, y, w, h, color, {cx0, cy0, cx1, cy1}) do
    x0 = max(x, cx0)
    y0 = max(y, cy0)
    x1 = min(x + w, cx1)
    y1 = min(y + h, cy1)

    if x1 <= x0 or y1 <= y0 or not opaque?(color) do
      grid
    else
      px = :binary.copy(pixel(color), x1 - x0)
      before = x0 * 3
      len = (x1 - x0) * 3

      Enum.reduce(y0..(y1 - 1)//1, grid, fn row, g ->
        <<pre::binary-size(^before), _::binary-size(^len), post::binary>> = elem(g, row)
        put_elem(g, row, <<pre::binary, px::binary, post::binary>>)
      end)
    end
  end
end
