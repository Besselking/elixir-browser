defmodule Browser.Reftest.Raster do
  @moduledoc """
  A small software painter for reftests: turns laid-out items into a pixel grid without a
  window, so two pages can be compared exactly and the comparison runs anywhere.

  It paints what the layout decides, not what a font rasteriser would: backgrounds and borders
  (square corners, every border style solid), and text as one block per character. The Ahem
  font that most layout tests use is exactly that, an em square for every glyph; for other
  fonts a block's colour depends on its character, so text only matches text that is the same.
  Pictures (`<img>` and background images, from the decoded `pictures` map) are scaled by
  nearest neighbour and blended on; shadows, gradients and rounded corners are left out.
  """

  @doc "A `width` x `height` grid of `color`: a tuple of rows, each a binary of RGB triples."
  def new(width, height, color) do
    row = :binary.copy(pixel(color), width)
    List.to_tuple(List.duplicate(row, height))
  end

  @doc """
  Paints `items` (from `Browser.Layout.layout/5`) on a fresh grid. `pictures` maps the urls
  of the page's pictures to decoded ones (`Browser.Reftest.Picture`).
  """
  def paint(items, width, height, pictures \\ %{}) do
    canvas = Enum.find_value(items, {255, 255, 255}, &(&1.type == :canvas && &1.color))

    Enum.reduce(items, new(width, height, canvas), fn item, grid ->
      draw(grid, item, width, height, pictures)
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

  defp draw(grid, %{type: :rect} = r, w, h, _pics) do
    clip = clip_box(r, w, h)
    grid = if r.color, do: fill(grid, r.x, r.y, r.w, r.h, r.color, clip), else: grid
    borders(grid, r, clip)
  end

  defp draw(grid, %{type: :hr} = r, w, h, _pics),
    do: fill(grid, r.x, r.y, r.w, 1, {170, 170, 170}, clip_box(r, w, h))

  defp draw(grid, %{type: :image} = i, w, h, pics) do
    case Map.get(pics, i.url) do
      nil -> grid
      picture -> blit(grid, picture, i.x, i.y, i.w, i.h, clip_box(i, w, h))
    end
  end

  # background images: each layer's tiles, inside the layer's clip and the item's
  defp draw(grid, %{type: :bgimage} = b, w, h, pics) do
    {ix0, iy0, ix1, iy1} = clip_box(b, w, h)

    Enum.reduce(b.layers, grid, fn
      %{
        kind: :image,
        url: url,
        tile: {_, _, tw, th} = tile,
        repeat: repeat,
        clip: {cx, cy, cw, ch} = lc
      },
      grid ->
        case Map.get(pics, url) do
          nil ->
            grid

          picture ->
            clip = {max(ix0, cx), max(iy0, cy), min(ix1, cx + cw), min(iy1, cy + ch)}

            tile
            |> Browser.Backgrounds.tiles(repeat, lc)
            |> Enum.reduce(grid, fn {x, y}, grid -> blit(grid, picture, x, y, tw, th, clip) end)
        end

      _other, grid ->
        grid
    end)
  end

  defp draw(grid, %{type: :text, hidden: true}, _w, _h, _pics), do: grid

  defp draw(grid, %{type: :text} = t, w, h, _pics), do: text(grid, t, clip_box(t, w, h))

  defp draw(grid, _item, _w, _h, _pics), do: grid

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
    ls = Map.get(t, :ls, 0)

    wsp = Map.get(t, :wsp, 0)

    {grid, advance_x} =
      t.text
      |> String.graphemes()
      |> Enum.reduce({grid, 0.0}, fn ch, {g, off} ->
        cadv = Browser.Reftest.char_advance(ch, adv)
        gw = if cadv == adv, do: gw, else: max(round(cadv * size) - if(ahem?, do: 0, else: 1), 1)

        g =
          if String.trim(ch) == "" or cadv == 0.0,
            do: g,
            else: fill(g, t.x + round(off), gy, gw, gh, ink(g, t, off, gy, ch, ahem?), clip)

        {g, off + cadv * size + ls + if(ch in [" ", "\u00A0"], do: wsp, else: 0)}
      end)

    width = round(advance_x)

    grid =
      if Map.get(t, :underline),
        do: fill(grid, t.x, t.y + round(t.h * 0.9), width, 1, t.color, clip),
        else: grid

    if Map.get(t, :strike),
      do: fill(grid, t.x, t.y + div(t.h, 2), width, 1, t.color, clip),
      else: grid
  end

  # text in the colour of what it is on is how tests hide their labels: it must not show up
  # in the colour the salt gives a character
  defp ink(grid, t, off, gy, ch, ahem?) do
    x = max(t.x + round(off), 0)

    with true <- gy >= 0 and gy < tuple_size(grid),
         row = elem(grid, gy),
         true <- byte_size(row) >= (x + 1) * 3,
         <<_::binary-size(^x * 3), under::binary-size(3), _::binary>> <- row,
         true <- under == pixel(t.color) do
      t.color
    else
      _ -> glyph_color(t.color, ch, t, ahem?)
    end
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
    <<code::utf8, _::binary>> = ch

    salt =
      code * 31 + if(Map.get(t, :bold), do: 7, else: 0) + if(Map.get(t, :italic), do: 13, else: 0)

    {rem(r + salt, 256), rem(g + salt * 3, 256), rem(b + salt * 5, 256)}
  end

  defp glyph_color(color, _ch, _t, false), do: color

  # -- pixels -------------------------------------------------------------------------------

  defp pixel({r, g, b}), do: <<r, g, b>>
  defp pixel({r, g, b, _a}), do: <<r, g, b>>
  defp pixel(_), do: <<255, 255, 255>>

  # `picture` scaled to `w` x `h` at `x`, `y` (nearest neighbour), blended onto the grid
  defp blit(grid, _picture, _x, _y, w, h, _clip) when w <= 0 or h <= 0, do: grid

  defp blit(grid, picture, x, y, w, h, {cx0, cy0, cx1, cy1}) do
    x0 = max(x, cx0)
    y0 = max(y, cy0)
    x1 = min(x + w, cx1)
    y1 = min(y + h, cy1)

    if x1 <= x0 or y1 <= y0 do
      grid
    else
      rows = List.to_tuple(picture.rows)
      before = x0 * 3
      len = (x1 - x0) * 3

      Enum.reduce(y0..(y1 - 1)//1, grid, fn row, g ->
        src = elem(rows, div((row - y) * picture.h, h))
        <<pre::binary-size(^before), old::binary-size(^len), post::binary>> = elem(g, row)

        mixed =
          for xx <- x0..(x1 - 1)//1, reduce: {old, []} do
            {<<o::binary-size(3), rest::binary>>, acc} ->
              <<r, gr, b, a>> = binary_part(src, div((xx - x) * picture.w, w) * 4, 4)
              {rest, [blend(o, r, gr, b, a) | acc]}
          end
          |> elem(1)
          |> Enum.reverse()

        put_elem(g, row, IO.iodata_to_binary([pre, mixed, post]))
      end)
    end
  end

  defp blend(_old, r, g, b, 255), do: <<r, g, b>>
  defp blend(old, _r, _g, _b, 0), do: old

  defp blend(<<or_, og, ob>>, r, g, b, a),
    do:
      <<div(r * a + or_ * (255 - a), 255), div(g * a + og * (255 - a), 255),
        div(b * a + ob * (255 - a), 255)>>

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
