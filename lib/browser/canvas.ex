defmodule Browser.Canvas do
  @moduledoc """
  The state behind a script's `<canvas>` 2D context.

  A canvas keeps a *display list* of what the script drew, in the same form as the display list
  of an inline `<svg>` (see `Browser.Svg`): `%{kind: :path, ...}` and `%{kind: :text, ...}` items
  in canvas pixels, after all transforms. The painter draws that list over the box of the
  element, so a canvas is sharp at any scale and drawing costs one list entry, not a pixel
  loop. Every item also holds `clip` (the clip box when it was drawn, or `nil`) and `bb`, its
  bounding box.

  The pixels are only made on request (`to_png/1`, by `Browser.Canvas.Raster`).

  This module is pure: the context object in `Browser.JS.Dom` keeps the style properties
  (`fillStyle`, `lineWidth`, ...) and passes them to each call. It holds the parts that the
  standard stores per drawing state apart from them: the transform and the clip.

  Left out: compositing modes other than source-over, shadows, filters, rotated text, clips
  with a shape (the bounding box of the shape clips instead) and `clearRect` of part of
  earlier drawing (it removes the items that lie fully inside the rectangle).
  """

  alias Browser.Svg

  @max_pixels 16_000_000
  @max_ops 20_000
  @ident {1.0, 0.0, 0.0, 1.0, 0.0, 0.0}

  defstruct w: 300,
            h: 150,
            ops: [],
            n: 0,
            ctm: @ident,
            clip: nil,
            path: [],
            cur: nil,
            start: nil,
            stack: []

  @type matrix :: {float, float, float, float, float, float}
  @type paint :: {:color, tuple} | {:linear, tuple, list} | {:radial, tuple, list}
  @type t :: %__MODULE__{}

  @doc "A transparent surface; sizes are clamped to 1 and to #{@max_pixels} pixels in all."
  @spec new(number, number) :: t
  def new(w, h) do
    w = w |> trunc() |> max(1)
    h = h |> trunc() |> max(1)
    if w * h > @max_pixels, do: %__MODULE__{w: 1, h: 1}, else: %__MODULE__{w: w, h: h}
  end

  @doc "The display list, in drawing order."
  @spec ops(t) :: [map]
  def ops(%__MODULE__{ops: ops}), do: Enum.reverse(ops)

  # -- transform and state -------------------------------------------------------------------

  @doc "The current transform `{a, b, c, d, e, f}`."
  def matrix(%__MODULE__{ctm: m}), do: m

  @doc "Multiplies the transform by `m` (the new one applies first)."
  def transform(c, {a, b, c1, d, e, f}),
    do: %{c | ctm: Svg.multiply(c.ctm, {a * 1.0, b * 1.0, c1 * 1.0, d * 1.0, e * 1.0, f * 1.0})}

  @doc "Replaces the transform."
  def set_transform(c, {a, b, c1, d, e, f}),
    do: %{c | ctm: {a * 1.0, b * 1.0, c1 * 1.0, d * 1.0, e * 1.0, f * 1.0}}

  def reset_transform(c), do: %{c | ctm: @ident}
  def translate(c, x, y), do: transform(c, {1, 0, 0, 1, x, y})
  def scale(c, x, y), do: transform(c, {x, 0, 0, y, 0, 0})

  def rotate(c, angle) do
    {s, co} = {:math.sin(angle), :math.cos(angle)}
    transform(c, {co, s, -s, co, 0, 0})
  end

  @doc "Pushes the transform and clip, with `props` (the script-visible style) to give back."
  def save(c, props \\ nil), do: %{c | stack: [{c.ctm, c.clip, props} | c.stack]}

  @doc "Pops the last `save/2`: `{canvas, props}`, or the canvas as it is with `props` nil."
  def restore(%__MODULE__{stack: []} = c), do: {c, nil}

  def restore(%__MODULE__{stack: [{ctm, clip, props} | rest]} = c),
    do: {%{c | ctm: ctm, clip: clip, stack: rest}, props}

  @doc "Intersects the clip with the bounding box of the current path."
  def clip(%__MODULE__{path: []} = c), do: %{c | clip: {0.0, 0.0, 0.0, 0.0}}

  def clip(c) do
    case bounds(Enum.reverse(c.path)) do
      nil -> c
      box -> %{c | clip: intersect(c.clip, box)}
    end
  end

  defp intersect(nil, box), do: box
  defp intersect(box, nil), do: box

  defp intersect({ax0, ay0, ax1, ay1}, {bx0, by0, bx1, by1}) do
    {x0, y0, x1, y1} = {max(ax0, bx0), max(ay0, by0), min(ax1, bx1), min(ay1, by1)}
    if x1 < x0 or y1 < y0, do: {x0, y0, x0, y0}, else: {x0, y0, x1, y1}
  end

  defp pt(%{ctm: {a, b, c, d, e, f}}, x, y), do: {a * x + c * y + e, b * x + d * y + f}

  defp scale_factor(%{ctm: {a, b, c, d, _, _}}), do: :math.sqrt(abs(a * d - b * c))

  defp axis_aligned?(%{ctm: {_, b, c, _, _, _}}), do: abs(b) < 1.0e-9 and abs(c) < 1.0e-9

  defp unproject(%{ctm: {a, b, c, d, e, f}}, {x, y}) do
    det = a * d - b * c

    if abs(det) < 1.0e-12,
      do: nil,
      else: {(d * (x - e) - c * (y - f)) / det, (a * (y - f) - b * (x - e)) / det}
  end

  # -- building the current path -----------------------------------------------------------

  def begin_path(c), do: %{c | path: [], cur: nil, start: nil}

  def move_to(c, x, y) do
    {dx, dy} = pt(c, x, y)
    %{c | path: [{:M, dx, dy} | c.path], cur: {dx, dy}, start: {dx, dy}}
  end

  def line_to(%{cur: nil} = c, x, y), do: move_to(c, x, y)

  def line_to(c, x, y) do
    {dx, dy} = pt(c, x, y)
    c = reopen(c)
    %{c | path: [{:L, dx, dy} | c.path], cur: {dx, dy}}
  end

  def close_path(%{path: []} = c), do: c
  def close_path(%{path: [:Z | _]} = c), do: c
  def close_path(c), do: %{c | path: [:Z | c.path], cur: c.start}

  def bezier_to(%{cur: nil} = c, x1, y1, x2, y2, x, y),
    do: c |> move_to(x1, y1) |> bezier_to(x1, y1, x2, y2, x, y)

  def bezier_to(c, x1, y1, x2, y2, x, y) do
    {d1x, d1y} = pt(c, x1, y1)
    {d2x, d2y} = pt(c, x2, y2)
    {dx, dy} = pt(c, x, y)
    c = reopen(c)
    %{c | path: [{:C, d1x, d1y, d2x, d2y, dx, dy} | c.path], cur: {dx, dy}}
  end

  def quad_to(%{cur: nil} = c, x1, y1, x, y), do: c |> move_to(x1, y1) |> quad_to(x1, y1, x, y)

  def quad_to(c, x1, y1, x, y) do
    {qx, qy} = pt(c, x1, y1)
    {dx, dy} = pt(c, x, y)
    {px, py} = c.cur
    k = 2 / 3
    c = reopen(c)

    seg =
      {:C, px + k * (qx - px), py + k * (qy - py), dx + k * (qx - dx), dy + k * (qy - dy), dx, dy}

    %{c | path: [seg | c.path], cur: {dx, dy}}
  end

  @doc "A closed rectangle subpath."
  def rect(c, x, y, w, h) do
    c
    |> move_to(x, y)
    |> line_to(x + w, y)
    |> line_to(x + w, y + h)
    |> line_to(x, y + h)
    |> close_path()
  end

  @doc "A rectangle with rounded corners; `radii` is `[tl, tr, br, bl]`."
  def round_rect(c, x, y, w, h, radii) do
    {x, w} = if w < 0, do: {x + w, -w}, else: {x, w}
    {y, h} = if h < 0, do: {y + h, -h}, else: {y, h}
    [tl, tr, br, bl] = fit_radii(radii, w, h)
    k = 0.5523

    c
    |> move_to(x + tl, y)
    |> line_to(x + w - tr, y)
    |> bezier_to(x + w - tr * (1 - k), y, x + w, y + tr * (1 - k), x + w, y + tr)
    |> line_to(x + w, y + h - br)
    |> bezier_to(x + w, y + h - br * (1 - k), x + w - br * (1 - k), y + h, x + w - br, y + h)
    |> line_to(x + bl, y + h)
    |> bezier_to(x + bl * (1 - k), y + h, x, y + h - bl * (1 - k), x, y + h - bl)
    |> line_to(x, y + tl)
    |> bezier_to(x, y + tl * (1 - k), x + tl * (1 - k), y, x + tl, y)
    |> close_path()
  end

  defp fit_radii(radii, w, h) do
    radii = Enum.map(radii, &(max(&1, 0.0) * 1.0))

    f =
      Enum.min([
        1.0,
        ratio(w, Enum.at(radii, 0) + Enum.at(radii, 1)),
        ratio(w, Enum.at(radii, 2) + Enum.at(radii, 3)),
        ratio(h, Enum.at(radii, 1) + Enum.at(radii, 2)),
        ratio(h, Enum.at(radii, 3) + Enum.at(radii, 0))
      ])

    Enum.map(radii, &(&1 * f))
  end

  defp ratio(_len, sum) when sum <= 0, do: 1.0
  defp ratio(len, sum), do: len / sum

  @doc "An elliptical arc (`arc` is the case `rx == ry`, `rotation == 0`)."
  def ellipse(c, cx, cy, rx, ry, rotation, a0, a1, ccw?) do
    sweep = sweep(a0, a1, ccw?)
    pieces = max(ceil(abs(sweep) / (:math.pi() / 2)), 1)
    step = sweep / pieces
    {sr, cr} = {:math.sin(rotation), :math.cos(rotation)}

    local = fn t ->
      {x, y} = {rx * :math.cos(t), ry * :math.sin(t)}
      {cx + x * cr - y * sr, cy + x * sr + y * cr}
    end

    tangent = fn t ->
      {x, y} = {-rx * :math.sin(t), ry * :math.cos(t)}
      {x * cr - y * sr, x * sr + y * cr}
    end

    {sx, sy} = local.(a0)
    c = line_to(c, sx, sy)
    k = 4 / 3 * :math.tan(step / 4)

    Enum.reduce(0..(pieces - 1), c, fn i, c ->
      {t0, t1} = {a0 + i * step, a0 + (i + 1) * step}
      {p0x, p0y} = local.(t0)
      {p1x, p1y} = local.(t1)
      {d0x, d0y} = tangent.(t0)
      {d1x, d1y} = tangent.(t1)
      bezier_to(c, p0x + k * d0x, p0y + k * d0y, p1x - k * d1x, p1y - k * d1y, p1x, p1y)
    end)
  end

  def arc(c, cx, cy, r, a0, a1, ccw?), do: ellipse(c, cx, cy, r, r, 0.0, a0, a1, ccw?)

  # the angle covered, signed: positive goes clockwise on the screen
  defp sweep(a0, a1, false) do
    two_pi = 2 * :math.pi()
    if a1 - a0 >= two_pi, do: two_pi, else: positive_mod(a1 - a0, two_pi)
  end

  defp sweep(a0, a1, true) do
    two_pi = 2 * :math.pi()
    if a0 - a1 >= two_pi, do: -two_pi, else: -positive_mod(a0 - a1, two_pi)
  end

  defp positive_mod(x, m) do
    r = x - m * Float.floor(x / m)
    if r < 0, do: r + m, else: r
  end

  @doc "`arcTo`: an arc of radius `r` rounding the corner at `(x1, y1)` towards `(x2, y2)`."
  def arc_to(%{cur: nil} = c, x1, y1, _x2, _y2, _r), do: move_to(c, x1, y1)

  def arc_to(c, x1, y1, x2, y2, r) do
    case unproject(c, c.cur) do
      nil ->
        line_to(c, x1, y1)

      {x0, y0} ->
        {d0x, d0y} = {x1 - x0, y1 - y0}
        {d2x, d2y} = {x2 - x1, y2 - y1}
        cross = d0x * d2y - d0y * d2x
        {l0, l2} = {:math.sqrt(d0x * d0x + d0y * d0y), :math.sqrt(d2x * d2x + d2y * d2y)}

        if l0 == 0 or l2 == 0 or r == 0 or abs(cross) < 1.0e-9 * l0 * l2 do
          line_to(c, x1, y1)
        else
          {u0x, u0y} = {-d0x / l0, -d0y / l0}
          {u2x, u2y} = {d2x / l2, d2y / l2}
          angle = :math.acos(max(-1.0, min(1.0, u0x * u2x + u0y * u2y)))
          dist = r / :math.tan(angle / 2)
          {t0x, t0y} = {x1 + u0x * dist, y1 + u0y * dist}
          {t2x, t2y} = {x1 + u2x * dist, y1 + u2y * dist}
          {bx, by} = {u0x + u2x, u0y + u2y}
          bl = :math.sqrt(bx * bx + by * by)
          centre = r / :math.sin(angle / 2)
          {cx, cy} = {x1 + bx / bl * centre, y1 + by / bl * centre}
          start = :math.atan2(t0y - cy, t0x - cx)
          stop = :math.atan2(t2y - cy, t2x - cx)

          c
          |> line_to(t0x, t0y)
          |> arc(cx, cy, r, start, stop, cross < 0)
        end
    end
  end

  # a segment after `closePath` starts a new subpath where the last one began
  defp reopen(%{path: [:Z | _], start: {sx, sy}} = c), do: %{c | path: [{:M, sx, sy} | c.path]}
  defp reopen(c), do: c

  @doc "Runs `fun` with `path` (a `Path2D`, in canvas space) as the current path, then puts the old path back."
  def with_path(c, %__MODULE__{path: local}, fun) do
    mapped = Enum.map(local, &map_segment(&1, c.ctm))
    saved = {c.path, c.cur, c.start}
    c = fun.(%{c | path: mapped})
    {path, cur, start} = saved
    %{c | path: path, cur: cur, start: start}
  end

  @doc "A path object from absolute segments (as `Browser.Svg.PathData.parse/1` makes them)."
  def from_segments(segments) do
    cur =
      segments
      |> Enum.reverse()
      |> Enum.find_value(fn
        {:M, x, y} -> {x, y}
        {:L, x, y} -> {x, y}
        {:C, _, _, _, _, x, y} -> {x, y}
        :Z -> nil
      end)

    %__MODULE__{path: Enum.reverse(segments), cur: cur, start: cur}
  end

  @doc "Adds the subpaths of `other` to the path, moved by `m`."
  def add_path(c, %__MODULE__{path: other}, m) do
    mapped = Enum.map(other, &map_segment(&1, Svg.multiply(c.ctm, m)))
    %{c | path: mapped ++ c.path, cur: nil, start: nil}
  end

  # -- drawing ---------------------------------------------------------------------------

  @doc "Paints the current path. `alpha` is the global alpha."
  def fill(c, paint, rule, alpha) do
    case c.path do
      [] ->
        c

      path ->
        segments = Enum.reverse(path)
        fill = %{paint: shade(c, paint, alpha), rule: rule}
        push(c, path_item(segments, fill, nil))
    end
  end

  @doc """
  Outlines the current path. `style` has `width`, `cap` (`:butt | :round | :square`),
  `join` (`:miter | :round | :bevel`), `miter` and `dash` (a list of lengths or `nil`).
  """
  def stroke(c, paint, style, alpha) do
    case c.path do
      [] -> c
      path -> stroke_segments(c, Enum.reverse(path), paint, style, alpha)
    end
  end

  defp stroke_segments(c, segments, paint, style, alpha) do
    k = scale_factor(c)
    width = style.width * k

    if width <= 0 or k == 0 do
      c
    else
      dash = style[:dash] && Enum.map(style.dash, &(&1 * k))

      stroke = %{
        paint: shade(c, paint, alpha),
        width: width,
        cap: style.cap,
        join: style.join,
        miter: style.miter,
        dash: nil
      }

      segments = if dash, do: Svg.dash_segments(segments, dash), else: segments
      push(c, path_item(segments, nil, stroke, dash != nil))
    end
  end

  @doc "Paints a rectangle without touching the current path."
  def fill_rect(c, x, y, w, h, paint, alpha) when w != 0 and h != 0 do
    segments = rect_segments(c, x, y, w, h)
    fill = %{paint: shade(c, paint, alpha), rule: :nonzero}
    item = path_item(segments, fill, nil)

    item =
      if axis_aligned?(c) do
        {x0, y0} = pt(c, x, y)
        {x1, y1} = pt(c, x + w, y + h)
        Map.put(item, :rect, {min(x0, x1), min(y0, y1), max(x0, x1), max(y0, y1)})
      else
        item
      end

    push(c, item)
  end

  def fill_rect(c, _x, _y, _w, _h, _paint, _alpha), do: c

  @doc "Outlines a rectangle without touching the current path."
  def stroke_rect(c, x, y, w, h, paint, style, alpha),
    do: stroke_segments(c, rect_segments(c, x, y, w, h), paint, style, alpha)

  defp rect_segments(c, x, y, w, h) do
    {x0, y0} = pt(c, x, y)
    {x1, y1} = pt(c, x + w, y)
    {x2, y2} = pt(c, x + w, y + h)
    {x3, y3} = pt(c, x, y + h)
    [{:M, x0, y0}, {:L, x1, y1}, {:L, x2, y2}, {:L, x3, y3}, :Z]
  end

  @doc """
  Makes the rectangle transparent. Items that lie wholly inside it are removed; the others
  stay (a part cannot be cut out of a vector item).
  """
  def clear_rect(c, x, y, w, h) do
    if axis_aligned?(c) do
      {x0, y0} = pt(c, x, y)
      {x1, y1} = pt(c, x + w, y + h)
      {x0, x1} = {min(x0, x1), max(x0, x1)}
      {y0, y1} = {min(y0, y1), max(y0, y1)}

      if x0 <= 0 and y0 <= 0 and x1 >= c.w and y1 >= c.h do
        %{c | ops: [], n: 0}
      else
        ops =
          Enum.reject(c.ops, fn %{bb: {bx0, by0, bx1, by1}} ->
            bx0 >= x0 and by0 >= y0 and bx1 <= x1 and by1 <= y1
          end)

        %{c | ops: ops, n: length(ops)}
      end
    else
      c
    end
  end

  @doc """
  Draws text. `style` has `paint`, `font` (a CSS font string), `align` (`:start | :middle |
  :end`), `baseline` and `alpha`. Text under a rotation is left out.
  """
  def text(c, text, x, y, style) do
    {_a, b, cc, _d, _e, _f} = c.ctm

    if text == "" or abs(b) > 1.0e-6 or abs(cc) > 1.0e-6 or scale_factor(c) == 0 do
      c
    else
      font = parse_font(style.font)
      k = scale_factor(c)
      size = font.size * k
      {dx, dy} = pt(c, x, y)
      width = text_width(text, font) * k

      color =
        case shade(c, style.paint, style.alpha) do
          {:color, color} -> color
          {_, _, [{_, color} | _]} -> color
        end

      {left, right} =
        case style.align do
          :middle -> {dx - width / 2, dx + width / 2}
          :end -> {dx - width, dx}
          _ -> {dx, dx + width}
        end

      item = %{
        kind: :text,
        x: dx,
        y: dy + baseline_shift(style.baseline, size),
        text: text,
        size: size,
        color: color,
        anchor: style.align,
        bold: font.bold,
        italic: font.italic,
        mono: font.mono,
        family: font.family,
        clip: c.clip,
        bb: {left, dy - size, right, dy + size}
      }

      push_item(c, item)
    end
  end

  defp baseline_shift(:top, size), do: 0.8 * size
  defp baseline_shift(:hanging, size), do: 0.7 * size
  defp baseline_shift(:middle, size), do: 0.3 * size
  defp baseline_shift(:bottom, size), do: -0.2 * size
  defp baseline_shift(:ideographic, size), do: -0.2 * size
  defp baseline_shift(_alphabetic, _size), do: 0.0

  @doc "Draws the display list of another canvas with its top-left corner at `(dx, dy)`."
  def draw_canvas(c, %__MODULE__{} = src, sx, sy, sw, sh, dx, dy, dw, dh, alpha)
      when sw > 0 and sh > 0 do
    kx = dw / sw
    ky = dh / sh

    m =
      Svg.multiply({1.0, 0.0, 0.0, 1.0, dx - sx * kx, dy - sy * ky}, {kx, 0.0, 0.0, ky, 0.0, 0.0})

    m = Svg.multiply(c.ctm, m)
    box = {sx, sy, sx + sw, sy + sh}

    Enum.reduce(ops(src), c, fn op, c ->
      op = place(op, m)
      op = put_in_clip(op, c, m, box)
      push_item(c, scale_alpha(op, alpha))
    end)
  end

  def draw_canvas(c, _src, _sx, _sy, _sw, _sh, _dx, _dy, _dw, _dh, _alpha), do: c

  defp put_in_clip(op, c, m, box) do
    {x0, y0, x1, y1} = intersect(op.clip, box)
    {ax, ay} = tp(m, x0, y0)
    {bx, by} = tp(m, x1, y1)
    %{op | clip: intersect(c.clip, {min(ax, bx), min(ay, by), max(ax, bx), max(ay, by)})}
  end

  defp tp({a, b, c, d, e, f}, x, y), do: {a * x + c * y + e, b * x + d * y + f}

  defp scale_alpha(op, a) when a >= 1.0, do: op

  defp scale_alpha(%{kind: :text} = op, a), do: %{op | color: color_alpha(op.color, a)}

  defp scale_alpha(%{kind: :path} = op, a) do
    %{
      op
      | fill: op.fill && %{op.fill | paint: paint_alpha(op.fill.paint, a)},
        stroke: op.stroke && %{op.stroke | paint: paint_alpha(op.stroke.paint, a)}
    }
  end

  # the item with all coordinates moved by the matrix
  defp place(%{kind: :path} = op, m) do
    k = :math.sqrt(abs(elem(m, 0) * elem(m, 3) - elem(m, 1) * elem(m, 2)))
    segments = Enum.map(op.segments, &map_segment(&1, m))

    %{
      op
      | segments: segments,
        fill: op.fill && %{op.fill | paint: map_paint(op.fill.paint, m, k)},
        stroke:
          op.stroke &&
            %{op.stroke | paint: map_paint(op.stroke.paint, m, k), width: op.stroke.width * k},
        bb: bounds(segments) |> grow(op.stroke && op.stroke.width * k / 2)
    }
    |> Map.delete(:rect)
  end

  defp place(%{kind: :text} = op, m) do
    k = :math.sqrt(abs(elem(m, 0) * elem(m, 3) - elem(m, 1) * elem(m, 2)))
    {x, y} = tp(m, op.x, op.y)
    {x0, y0} = tp(m, elem(op.bb, 0), elem(op.bb, 1))
    {x1, y1} = tp(m, elem(op.bb, 2), elem(op.bb, 3))

    %{
      op
      | x: x,
        y: y,
        size: op.size * k,
        bb: {min(x0, x1), min(y0, y1), max(x0, x1), max(y0, y1)}
    }
  end

  defp map_segment({:M, x, y}, m), do: tp(m, x, y) |> then(fn {x, y} -> {:M, x, y} end)
  defp map_segment({:L, x, y}, m), do: tp(m, x, y) |> then(fn {x, y} -> {:L, x, y} end)

  defp map_segment({:C, x1, y1, x2, y2, x, y}, m) do
    {x1, y1} = tp(m, x1, y1)
    {x2, y2} = tp(m, x2, y2)
    {x, y} = tp(m, x, y)
    {:C, x1, y1, x2, y2, x, y}
  end

  defp map_segment(:Z, _m), do: :Z

  defp map_paint({:color, _} = p, _m, _k), do: p

  defp map_paint({:linear, {x1, y1, x2, y2}, stops}, m, _k) do
    {x1, y1} = tp(m, x1, y1)
    {x2, y2} = tp(m, x2, y2)
    {:linear, {x1, y1, x2, y2}, stops}
  end

  defp map_paint({:radial, {cx, cy, r, fx, fy}, stops}, m, k) do
    {cx, cy} = tp(m, cx, cy)
    {fx, fy} = tp(m, fx, fy)
    {:radial, {cx, cy, r * k, fx, fy}, stops}
  end

  @doc """
  The display list scaled by `kx`, `ky`, for a canvas shown in a box of another size than
  its bitmap. Without a scale (`1`, `1`) the list is returned as it is.
  """
  def scaled_ops(ops, kx, ky) when abs(kx - 1.0) < 1.0e-9 and abs(ky - 1.0) < 1.0e-9, do: ops

  def scaled_ops(ops, kx, ky) do
    m = {kx * 1.0, 0.0, 0.0, ky * 1.0, 0.0, 0.0}

    Enum.map(ops, fn op ->
      op = place(op, m)
      clip = op.clip

      %{op | clip: clip && scale_box(clip, kx, ky)}
    end)
  end

  defp scale_box({x0, y0, x1, y1}, kx, ky), do: {x0 * kx, y0 * ky, x1 * kx, y1 * ky}

  # -- items ---------------------------------------------------------------------------------

  defp path_item(segments, fill, stroke, open? \\ nil) do
    open? =
      if open? == nil, do: not Enum.any?(segments, &(&1 == :Z)), else: open?

    %{
      kind: :path,
      segments: segments,
      open?: open?,
      fill: fill,
      stroke: stroke,
      bb: segments |> bounds() |> grow(stroke && stroke.width / 2)
    }
  end

  defp grow(nil, _), do: nil
  defp grow(box, nil), do: box
  defp grow({x0, y0, x1, y1}, r), do: {x0 - r - 1, y0 - r - 1, x1 + r + 1, y1 + r + 1}

  defp push(c, item), do: push_item(c, Map.merge(item, %{clip: c.clip}))

  defp push_item(c, %{bb: nil}), do: c

  defp push_item(c, %{bb: {x0, y0, x1, y1}, clip: clip} = item) do
    visible = intersect(clip, {0.0, 0.0, c.w * 1.0, c.h * 1.0})

    if x1 < elem(visible, 0) or y1 < elem(visible, 1) or x0 > elem(visible, 2) or
         y0 > elem(visible, 3) do
      c
    else
      ops = [item | c.ops]
      n = c.n + 1

      if n > @max_ops,
        do: %{c | ops: Enum.take(ops, div(@max_ops * 3, 4)), n: div(@max_ops * 3, 4)},
        else: %{c | ops: ops, n: n}
    end
  end

  # the box around all points of the segments (control points included), or nil
  defp bounds(segments) do
    Enum.reduce(segments, nil, fn
      {:M, x, y}, box -> extend(box, x, y)
      {:L, x, y}, box -> extend(box, x, y)
      {:C, x1, y1, x2, y2, x, y}, box -> box |> extend(x1, y1) |> extend(x2, y2) |> extend(x, y)
      :Z, box -> box
    end)
  end

  defp extend(nil, x, y), do: {x, y, x, y}
  defp extend({x0, y0, x1, y1}, x, y), do: {min(x0, x), min(y0, y), max(x1, x), max(y1, y)}

  # -- paints ------------------------------------------------------------------------------

  # a paint in canvas space (gradient points as the script gave them) as a paint in the
  # pixels of the canvas, with the global alpha applied
  defp shade(c, paint, alpha) do
    m = c.ctm
    k = scale_factor(c)
    paint |> map_paint(m, k) |> paint_alpha(alpha)
  end

  defp paint_alpha(paint, a) when a >= 1.0, do: paint
  defp paint_alpha({:color, color}, a), do: {:color, color_alpha(color, a)}

  defp paint_alpha({kind, geometry, stops}, a),
    do: {kind, geometry, Enum.map(stops, fn {o, color} -> {o, color_alpha(color, a)} end)}

  defp color_alpha({r, g, b, al}, a), do: {r, g, b, round(al * a)}

  # -- fonts and text ----------------------------------------------------------------------

  @doc """
  Reads a CSS font shorthand (`"italic bold 12px/1.2 Helvetica, sans-serif"`) into
  `%{size:, bold:, italic:, mono:, family:}`; the size is in px.
  """
  def parse_font(text) when is_binary(text) do
    tokens = String.split(text)

    {before, rest} = Enum.split_while(tokens, &(size_token(&1) == nil))

    case rest do
      [size_text | family] ->
        {size, _} = size_token(size_text)
        family = Enum.join(family, " ")

        %{
          size: size,
          bold: Enum.any?(before, &bold_token?/1),
          italic: Enum.any?(before, &(&1 in ["italic", "oblique"])),
          mono: mono?(family),
          family: if(family == "", do: nil, else: family)
        }

      [] ->
        %{size: 10.0, bold: false, italic: false, mono: false, family: nil}
    end
  end

  defp bold_token?(t),
    do: t in ["bold", "bolder"] or (String.match?(t, ~r/^\d+$/) and String.to_integer(t) >= 600)

  defp size_token(token) do
    case Regex.run(~r{^(\d*\.?\d+)(px|pt|em|rem|%|pc|in|cm|mm)(?:/.*)?$}, token) do
      [_, n, unit] -> {to_f(n) * unit_px(unit), unit}
      _ -> nil
    end
  end

  defp to_f(n) do
    {f, _} = Float.parse(if String.starts_with?(n, "."), do: "0" <> n, else: n)
    f
  end

  defp unit_px("pt"), do: 4 / 3
  defp unit_px("em"), do: 16.0
  defp unit_px("rem"), do: 16.0
  defp unit_px("%"), do: 0.16
  defp unit_px("pc"), do: 16.0
  defp unit_px("in"), do: 96.0
  defp unit_px("cm"), do: 96 / 2.54
  defp unit_px("mm"), do: 96 / 25.4
  defp unit_px(_), do: 1.0

  defp mono?(family) do
    first = family |> String.split(",") |> hd() |> String.downcase()
    String.contains?(first, ["mono", "courier", "consolas", "menlo"])
  end

  # Helvetica advance widths of the ASCII characters (space to ~), in 1/1000 em
  @widths [
    278,
    278,
    355,
    556,
    556,
    889,
    667,
    191,
    333,
    333,
    389,
    584,
    278,
    333,
    278,
    278,
    556,
    556,
    556,
    556,
    556,
    556,
    556,
    556,
    556,
    556,
    278,
    278,
    584,
    584,
    584,
    556,
    1015,
    667,
    667,
    722,
    722,
    667,
    611,
    778,
    722,
    278,
    500,
    667,
    556,
    833,
    722,
    778,
    667,
    778,
    722,
    667,
    611,
    722,
    667,
    944,
    667,
    667,
    611,
    278,
    278,
    278,
    469,
    556,
    333,
    556,
    556,
    500,
    556,
    556,
    278,
    556,
    556,
    222,
    222,
    500,
    222,
    833,
    556,
    556,
    556,
    556,
    333,
    500,
    278,
    556,
    500,
    722,
    500,
    500,
    500,
    334,
    260,
    334,
    584
  ]
  @width_table @widths |> Enum.with_index(32) |> Map.new(fn {w, i} -> {i, w} end)

  @doc "A guess at the width of `text` in the font, in px (the metrics of Helvetica)."
  def text_width(text, %{size: size, bold: bold, mono: mono}) do
    units =
      for <<cp::utf8 <- text>>, reduce: 0 do
        acc ->
          acc +
            cond do
              mono -> 600
              cp in 32..126 -> Map.fetch!(@width_table, cp)
              cp < 32 -> 0
              cp in 0x300..0x36F -> 0
              cp >= 0x2E80 -> 1000
              true -> 556
            end
      end

    units * size / 1000 * if(bold and not mono, do: 1.06, else: 1.0)
  end

  # -- pixels --------------------------------------------------------------------------------

  @doc "The surface as a PNG file."
  @spec to_png(t) :: binary
  def to_png(%__MODULE__{w: w, h: h} = c) do
    rows = Browser.Canvas.Raster.render(w, h, ops(c))
    blank = :binary.copy(<<0, 0, 0, 0>>, w)

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
end
