defmodule Browser.Canvas.Raster do
  @moduledoc """
  Turns the display list of a `Browser.Canvas` into pixels, for `toDataURL`.

  It is a small scanline filler: paths are flattened to polygons and filled with four
  sub-scanlines per pixel row and exact horizontal coverage, by the non-zero or even-odd rule.
  A stroke is the union of one quad per segment, with discs at the joins and round caps.
  Solid colours and linear and radial gradients are supported. Text is not drawn (there is no
  font here). A `fillRect` that is aligned to the pixel grid keeps hard edges.

  The result is `%{row => binary}` with RGBA pixels; a row that is not in the map is transparent.
  """

  @sub 4
  @disc_sides 16

  @spec render(pos_integer, pos_integer, [map]) :: %{integer => binary}
  def render(w, h, ops), do: Enum.reduce(ops, %{}, &paint(&1, &2, w, h))

  defp paint(
         %{kind: :path, rect: {x0, y0, x1, y1}, fill: %{paint: {:color, color}}} = op,
         rows,
         w,
         h
       ) do
    {cx0, cy0, cx1, cy1} = clip_box(op, w, h)

    fill_box(
      rows,
      w,
      max(round(x0), cx0),
      max(round(y0), cy0),
      min(round(x1), cx1),
      min(round(y1), cy1),
      color
    )
  end

  defp paint(%{kind: :path} = op, rows, w, h) do
    clip = clip_box(op, w, h)

    rows =
      case op.fill do
        nil ->
          rows

        %{paint: paint, rule: rule} ->
          fill_polys(rows, polygons(op.segments), rule, paint, clip, w)
      end

    case op.stroke do
      nil ->
        rows

      stroke ->
        fill_polys(
          rows,
          stroke_polys(op.segments, stroke, op.open?),
          :nonzero,
          stroke.paint,
          clip,
          w
        )
    end
  end

  # text has no glyphs here
  defp paint(_op, rows, _w, _h), do: rows

  defp clip_box(%{clip: nil}, w, h), do: {0, 0, w, h}

  defp clip_box(%{clip: {x0, y0, x1, y1}}, w, h),
    do: {max(round(x0), 0), max(round(y0), 0), min(round(x1), w), min(round(y1), h)}

  # -- hard-edged boxes ----------------------------------------------------------------------

  defp fill_box(rows, _w, x0, y0, x1, y1, _color) when x1 <= x0 or y1 <= y0, do: rows

  defp fill_box(rows, _w, _x0, _y0, _x1, _y1, {_, _, _, 0}), do: rows

  defp fill_box(rows, w, x0, y0, x1, y1, color) do
    Enum.reduce(y0..(y1 - 1), rows, fn y, rows ->
      row = Map.get(rows, y) || blank(w)
      n = x1 - x0
      skip = x0 * 4
      len = n * 4
      <<head::binary-size(^skip), mid::binary-size(^len), tail::binary>> = row

      mid =
        case color do
          {r, g, b, 255} -> :binary.copy(<<r, g, b, 255>>, n)
          _ -> for(<<d::binary-size(4) <- mid>>, into: <<>>, do: over(d, color, 1.0))
        end

      Map.put(rows, y, <<head::binary, mid::binary, tail::binary>>)
    end)
  end

  defp blank(w), do: :binary.copy(<<0, 0, 0, 0>>, w)

  # -- flattening ----------------------------------------------------------------------------

  # [{closed?, [{x, y}]}]
  defp flatten(segments) do
    {paths, cur, _pos, _start} =
      Enum.reduce(segments, {[], nil, nil, nil}, fn
        {:M, x, y}, {paths, cur, _pos, _start} ->
          {finish(paths, cur, false), [{x, y}], {x, y}, {x, y}}

        {:L, x, y}, {paths, cur, _pos, start} ->
          {paths, [{x, y} | cur || [start]], {x, y}, start}

        {:C, x1, y1, x2, y2, x, y}, {paths, cur, {px, py}, start} ->
          pts = bezier({px, py}, {x1, y1}, {x2, y2}, {x, y})
          {paths, Enum.reverse(pts, cur || [start]), {x, y}, start}

        :Z, {paths, cur, _pos, start} ->
          {finish(paths, cur, true), nil, start, start}
      end)

    paths |> finish(cur, false) |> Enum.reverse()
  end

  defp finish(paths, nil, _closed), do: paths
  defp finish(paths, [_], _closed), do: paths
  defp finish(paths, cur, closed), do: [{closed, Enum.reverse(cur)} | paths]

  defp bezier({x0, y0}, {x1, y1}, {x2, y2}, {x3, y3}) do
    len = dist({x0, y0}, {x1, y1}) + dist({x1, y1}, {x2, y2}) + dist({x2, y2}, {x3, y3})
    n = len |> Kernel./(3) |> ceil() |> max(4) |> min(48)

    for i <- 1..n do
      t = i / n
      u = 1 - t

      {u * u * u * x0 + 3 * u * u * t * x1 + 3 * u * t * t * x2 + t * t * t * x3,
       u * u * u * y0 + 3 * u * u * t * y1 + 3 * u * t * t * y2 + t * t * t * y3}
    end
  end

  defp dist({ax, ay}, {bx, by}), do: :math.sqrt((ax - bx) * (ax - bx) + (ay - by) * (ay - by))

  defp polygons(segments), do: for({_closed, pts} <- flatten(segments), length(pts) > 1, do: pts)

  # -- strokes ---------------------------------------------------------------------------

  defp stroke_polys(segments, stroke, _open?) do
    hw = stroke.width / 2

    Enum.flat_map(flatten(segments), fn {closed, pts} ->
      pts = dedupe(pts)

      pts =
        if closed and length(pts) > 1 and hd(pts) != List.last(pts),
          do: pts ++ [hd(pts)],
          else: pts

      case pts do
        [p] ->
          if stroke.cap == :round, do: [disc(p, hw)], else: []

        _ ->
          last = length(pts) - 2

          quads =
            pts
            |> Enum.chunk_every(2, 1, :discard)
            |> Enum.with_index()
            |> Enum.map(fn {[a, b], i} ->
              a =
                if i == 0 and not closed and stroke.cap == :square, do: extend(a, b, hw), else: a

              b =
                if i == last and not closed and stroke.cap == :square,
                  do: extend(b, a, hw),
                  else: b

              quad(a, b, hw)
            end)

          inner = if closed, do: pts, else: pts |> tl() |> Enum.drop(-1)
          ends = if not closed and stroke.cap == :round, do: [hd(pts), List.last(pts)], else: []

          joins =
            if stroke.join == :round or stroke.width >= 3 or ends != [],
              do: Enum.map(inner ++ ends, &disc(&1, hw)),
              else: []

          quads ++ joins
      end
    end)
  end

  defp dedupe(pts) do
    pts
    |> Enum.chunk_while(
      nil,
      fn p, prev -> if prev == p, do: {:cont, p}, else: {:cont, p, p} end,
      fn _ -> {:cont, nil} end
    )
  end

  # `a` moved `by` away from `b`
  defp extend({ax, ay}, {bx, by}, by_len) do
    {dx, dy} = {ax - bx, ay - by}
    len = :math.sqrt(dx * dx + dy * dy)
    if len == 0, do: {ax, ay}, else: {ax + dx / len * by_len, ay + dy / len * by_len}
  end

  defp quad({ax, ay}, {bx, by}, hw) do
    {dx, dy} = {bx - ax, by - ay}
    len = :math.sqrt(dx * dx + dy * dy)
    {nx, ny} = {-dy / len * hw, dx / len * hw}
    [{ax + nx, ay + ny}, {bx + nx, by + ny}, {bx - nx, by - ny}, {ax - nx, ay - ny}]
  end

  defp disc({cx, cy}, r) do
    for i <- 0..(@disc_sides - 1) do
      a = 2 * :math.pi() * i / @disc_sides
      {cx + r * :math.cos(a), cy + r * :math.sin(a)}
    end
  end

  # -- filling polygons ----------------------------------------------------------------------

  defp fill_polys(rows, polys, rule, paint, {cx0, cy0, cx1, cy1}, w) do
    edges = edges(polys)

    if edges == [] or cx1 <= cx0 or cy1 <= cy0 do
      rows
    else
      ymin = edges |> Enum.map(&elem(&1, 1)) |> Enum.min() |> floor() |> max(cy0)
      ymax = edges |> Enum.map(&elem(&1, 3)) |> Enum.max() |> ceil() |> min(cy1)

      Enum.reduce(ymin..(ymax - 1)//1, rows, fn y, rows ->
        active = Enum.filter(edges, fn {_, ya, _, yb, _} -> ya < y + 1 and yb > y end)

        case coverage(active, y, rule, cx0, cx1) do
          [] -> rows
          cov -> blend_row(rows, y, cov, paint, w)
        end
      end)
    end
  end

  # {x_top, y_top, x_bottom, y_bottom, direction} for the non-horizontal edges of closed polygons
  defp edges(polys) do
    Enum.flat_map(polys, fn pts ->
      pts
      |> Enum.zip(tl(pts) ++ [hd(pts)])
      |> Enum.flat_map(fn {{x0, y0}, {x1, y1}} ->
        cond do
          y0 == y1 -> []
          y0 < y1 -> [{x0, y0, x1, y1, 1}]
          true -> [{x1, y1, x0, y0, -1}]
        end
      end)
    end)
  end

  defp coverage(active, y, rule, cx0, cx1) do
    acc =
      Enum.reduce(0..(@sub - 1), %{}, fn i, acc ->
        sy = y + (i + 0.5) / @sub

        xs =
          for {x0, ya, x1, yb, dir} <- active, ya <= sy, sy < yb do
            {x0 + (sy - ya) * (x1 - x0) / (yb - ya), dir}
          end

        xs |> Enum.sort() |> spans(rule) |> Enum.reduce(acc, &add_span(&1, &2, cx0, cx1))
      end)

    acc |> Enum.sort() |> Enum.map(fn {px, cov} -> {px, min(cov, 1.0)} end)
  end

  defp spans(xs, :evenodd), do: pair_up(xs)

  defp spans(xs, _nonzero), do: nonzero(xs, 0, nil, [])

  defp pair_up([{a, _}, {b, _} | rest]), do: [{a, b} | pair_up(rest)]
  defp pair_up(_), do: []

  defp nonzero([], _wind, _from, acc), do: acc

  defp nonzero([{x, dir} | rest], wind, from, acc) do
    new = wind + dir

    cond do
      wind == 0 and new != 0 -> nonzero(rest, new, x, acc)
      wind != 0 and new == 0 -> nonzero(rest, 0, nil, [{from, x} | acc])
      true -> nonzero(rest, new, from, acc)
    end
  end

  defp add_span({xa, xb}, acc, cx0, cx1) do
    {xa, xb} = {max(xa, cx0 * 1.0), min(xb, cx1 * 1.0)}

    if xb <= xa do
      acc
    else
      Enum.reduce(floor(xa)..(ceil(xb) - 1), acc, fn px, acc ->
        overlap = min(xb, px + 1.0) - max(xa, px * 1.0)
        Map.update(acc, px, overlap / @sub, &(&1 + overlap / @sub))
      end)
    end
  end

  # -- blending ------------------------------------------------------------------------------

  defp blend_row(rows, y, cov, paint, w) do
    row = Map.get(rows, y) || blank(w)

    {iodata, pos} =
      Enum.reduce(cov, {[], 0}, fn {px, c}, {acc, pos} ->
        at = px * 4
        <<dst::binary-size(4)>> = binary_part(row, at, 4)
        src = color_at(paint, px + 0.5, y + 0.5)
        {[acc, binary_part(row, pos, at - pos), over(dst, src, c)], at + 4}
      end)

    Map.put(rows, y, IO.iodata_to_binary([iodata, binary_part(row, pos, byte_size(row) - pos)]))
  end

  # source `{r, g, b, a}` with extra coverage `cov` over the destination pixel
  defp over(<<dr, dg, db, da>>, {r, g, b, a}, cov) do
    a = a * cov
    out_a = a + da * (255 - a) / 255

    if out_a <= 0 do
      <<0, 0, 0, 0>>
    else
      mix = fn s, d -> round((s * a + d * da * (255 - a) / 255) / out_a) end
      <<mix.(r, dr), mix.(g, dg), mix.(b, db), round(out_a)>>
    end
  end

  defp color_at({:color, color}, _x, _y), do: color

  defp color_at({:linear, {x1, y1, x2, y2}, stops}, x, y) do
    {dx, dy} = {x2 - x1, y2 - y1}
    len2 = dx * dx + dy * dy
    t = if len2 == 0, do: 0.0, else: ((x - x1) * dx + (y - y1) * dy) / len2
    stop_color(stops, t)
  end

  defp color_at({:radial, {cx, cy, r, _fx, _fy}, stops}, x, y),
    do: stop_color(stops, dist({x, y}, {cx, cy}) / max(r, 1.0e-6))

  defp stop_color([{_, c}], _t), do: c
  defp stop_color([{o, c} | _], t) when t <= o, do: c

  defp stop_color([{o0, c0}, {o1, c1} | rest], t) do
    cond do
      t <= o1 and o1 > o0 -> mix(c0, c1, (t - o0) / (o1 - o0))
      t <= o1 -> c1
      true -> stop_color([{o1, c1} | rest], t)
    end
  end

  defp stop_color([], _t), do: {0, 0, 0, 0}

  defp mix({r0, g0, b0, a0}, {r1, g1, b1, a1}, f),
    do:
      {round(r0 + (r1 - r0) * f), round(g0 + (g1 - g0) * f), round(b0 + (b1 - b0) * f),
       round(a0 + (a1 - a0) * f)}
end
