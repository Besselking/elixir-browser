defmodule Browser.UI do
  @moduledoc "wx widgets: window construction, painting, font metrics and hit testing."

  require Record
  Record.defrecord(:wx, Record.extract(:wx, from_lib: "wx/include/wx.hrl"))
  Record.defrecord(:wxMouse, Record.extract(:wxMouse, from_lib: "wx/include/wx.hrl"))
  Record.defrecord(:wxCommand, Record.extract(:wxCommand, from_lib: "wx/include/wx.hrl"))
  Record.defrecord(:wxSize, Record.extract(:wxSize, from_lib: "wx/include/wx.hrl"))
  Record.defrecord(:wxKey, Record.extract(:wxKey, from_lib: "wx/include/wx.hrl"))

  @view :browser_view
  @images :browser_images
  @wx_default 70
  @wx_teletype 76
  @wx_normal 90
  @wx_italic 93
  @expand 8192
  @all 240
  @te_process_enter 1024
  @horizontal 4
  @vertical 8

  defstruct [:frame, :url, :back, :forward, :reload, :panel, :status, :cursors]

  def build do
    :ets.new(@view, [:named_table, :public])
    :ets.new(@images, [:named_table, :public])
    :ets.insert(@view, {:view, [], 0, true})

    wx = :wx.new()
    frame = :wxFrame.new(wx, -1, ~c"Elixir Browser", size: {960, 720})

    toolbar = :wxPanel.new(frame)
    back = :wxButton.new(toolbar, -1, label: ~c"◀", size: {40, -1})
    forward = :wxButton.new(toolbar, -1, label: ~c"▶", size: {40, -1})
    reload = :wxButton.new(toolbar, -1, label: ~c"⟳", size: {40, -1})
    url = :wxTextCtrl.new(toolbar, -1, style: @te_process_enter)

    row = :wxBoxSizer.new(@horizontal)
    for b <- [back, forward, reload], do: :wxSizer.add(row, b, border: 3, flag: @all)
    :wxSizer.add(row, url, proportion: 1, border: 3, flag: @all)
    :wxWindow.setSizer(toolbar, row)

    # FULL_REPAINT_ON_RESIZE | WANTS_CHARS (Tab, Enter and arrows arrive as char events)
    panel = :wxPanel.new(frame, style: 65536 + 262_144)
    :wxWindow.setBackgroundColour(panel, {255, 255, 255})
    :wxWindow.setBackgroundStyle(panel, :wxe_util.get_const(:wxBG_STYLE_PAINT))

    status = :wxStatusBar.new(frame)
    :wxFrame.setStatusBar(frame, status)

    col = :wxBoxSizer.new(@vertical)
    :wxSizer.add(col, toolbar, flag: @expand)
    :wxSizer.add(col, panel, proportion: 1, flag: @expand)
    :wxWindow.setSizer(frame, col)

    :wxFrame.connect(frame, :close_window)
    :wxTextCtrl.connect(url, :command_text_enter)
    for b <- [back, forward, reload], do: :wxButton.connect(b, :command_button_clicked)
    :wxPanel.connect(panel, :left_down)
    :wxPanel.connect(panel, :motion)
    :wxPanel.connect(panel, :mousewheel)
    :wxPanel.connect(panel, :size)
    :wxPanel.connect(panel, :char)
    :wxPanel.connect(panel, :paint, callback: fn _ev, _obj -> paint(panel) end)

    :wxFrame.show(frame)
    :wxWindow.setFocus(panel)

    %__MODULE__{
      frame: frame,
      url: url,
      back: back,
      forward: forward,
      reload: reload,
      panel: panel,
      status: status,
      cursors: Map.new([arrow: 1, hand: 6, text: 7], fn {k, id} -> {k, :wxCursor.new(id)} end)
    }
  end

  @doc "Hands the painter what to draw; `caret_on` is the blink state of the text caret."
  def publish(items, scroll, caret_on \\ true),
    do: :ets.insert(@view, {:view, items, scroll, caret_on})

  @doc """
  Like `publish/3`, then asks wx to repaint. In `:diff` mode (same scroll offset) only the
  area covered by items that differ from the previous view, or by the caret when it
  blinks, is invalidated; anything else repaints the whole panel.
  """
  def update(%{panel: panel}, items, scroll, caret_on, mode \\ :full) do
    [{:view, old_items, old_scroll, old_caret}] = :ets.lookup(@view, :view)
    publish(items, scroll, caret_on)

    dirty =
      if mode == :diff and old_scroll == scroll,
        do: diff_items(old_items, items, old_caret != caret_on, nil),
        else: :full

    case dirty do
      :none ->
        :ok

      :full ->
        :wxWindow.refresh(panel)

      {x, y, w, h} ->
        {cw, ch} = :wxWindow.getClientSize(panel)

        if w * h * 2 > cw * ch,
          do: :wxWindow.refresh(panel),
          else: :wxWindow.refreshRect(panel, {x, y - scroll, w, h})
    end
  end

  # bounding box (page coordinates) of what differs between two item lists, `:none` if
  # nothing, `:full` when the lists can't be compared item by item
  defp diff_items([same | old], [same | new], flip?, acc) do
    acc = if flip? and same.type == :caret, do: union(acc, bbox(same)), else: acc
    diff_items(old, new, flip?, acc)
  end

  defp diff_items([%{type: :canvas} | _], _, _, _), do: :full
  defp diff_items(_, [%{type: :canvas} | _], _, _), do: :full

  defp diff_items([a | old], [b | new], flip?, acc),
    do: diff_items(old, new, flip?, acc |> union(bbox(a)) |> union(bbox(b)))

  defp diff_items([], [], _, nil), do: :none
  defp diff_items([], [], _, acc), do: acc
  defp diff_items(_, _, _, _), do: :full

  defp union(nil, r), do: r

  defp union({x1, y1, w1, h1}, {x2, y2, w2, h2}) do
    x = min(x1, x2)
    y = min(y1, y2)
    {x, y, max(x1 + w1, x2 + w2) - x, max(y1 + h1, y2 + h2) - y}
  end

  # Everything an item can touch when drawn: shadows spread past their box, text runs a
  # line taller than its font size, the rest gets a little slack for antialiasing.
  defp bbox(%{type: :shadow, layers: [_ | _] = layers}) do
    layers
    |> Enum.map(fn %{rect: {x, y, w, h}} -> {x - 2, y - 2, w + 4, h + 4} end)
    |> Enum.reduce(&union/2)
  end

  defp bbox(%{type: :text, x: x, y: y, w: w, h: h}), do: {x - 6, y - 4, w + 12, h * 2 + 8}

  defp bbox(%{x: x, y: y, w: w} = item), do: {x - 4, y - 4, w + 8, Map.get(item, :h, 40) + 8}

  defp bbox(_), do: {0, 0, 1_000_000, 1_000_000}

  def client_width(%{panel: panel}), do: panel |> :wxWindow.getClientSize() |> elem(0)
  def client_height(%{panel: panel}), do: panel |> :wxWindow.getClientSize() |> elem(1)

  # -- fonts ---------------------------------------------------------------

  defp font(%{size: size, bold: bold, italic: italic, mono: mono}) do
    key = {:font, size, bold, italic, mono}

    case Process.get(key) do
      nil ->
        weight = :wxe_util.get_const(if bold, do: :wxFONTWEIGHT_BOLD, else: :wxFONTWEIGHT_NORMAL)

        f =
          :wxFont.new(
            size,
            if(mono, do: @wx_teletype, else: @wx_default),
            if(italic, do: @wx_italic, else: @wx_normal),
            weight
          )

        Process.put(key, f)
        f

      f ->
        f
    end
  end

  # widths cached per font; each uncached measurement is two synchronous wx calls
  # (~100us), and a relayout asks for the same text hundreds of times
  @measure_cache_limit 50_000

  @doc """
  Returns a `(text, style) -> width` function backed by a wx client DC. Widths are
  memoized (in the calling process), so only text that changed costs a wx round trip.
  """
  def measurer(%{panel: panel}) do
    dc = :wxClientDC.new(panel)
    cache = :ets.new(:measure_cache, [:set, :private])

    fn text, %{size: size, bold: bold, italic: italic, mono: mono} = style ->
      key = {text, size, bold, italic, mono}

      case :ets.lookup(cache, key) do
        [{_, w}] ->
          w

        [] ->
          :wxDC.setFont(dc, font(style))
          {w, _h} = :wxDC.getTextExtent(dc, String.to_charlist(text))
          if :ets.info(cache, :size) >= @measure_cache_limit, do: :ets.delete_all_objects(cache)
          :ets.insert(cache, {key, w})
          w
      end
    end
  end

  # -- painting (runs in wx callback process) --------------------------------

  defp paint(panel) do
    [{:view, items, scroll, caret_on}] = :ets.lookup(@view, :view)
    dc = :wxPaintDC.new(panel)

    canvas =
      case items do
        [%{type: :canvas, color: color} | _] when color != nil -> color
        _ -> {255, 255, 255}
      end

    :wxDC.setBackground(dc, :wxBrush.new(canvas))
    :wxDC.clear(dc)
    draw_canvas_layers(dc, items, scroll)
    # only the invalidated part of the window is drawn into, so items outside it are skipped
    {cx, cy, cw, ch} = :wxDC.getClippingBox(dc)

    for item <- items,
        item.type != :canvas,
        item.type != :caret or caret_on,
        not Map.get(item, :hidden, false),
        item.y - scroll < cy + ch,
        item.y + Map.get(item, :h, 40) + 40 - scroll > cy,
        item.x - 40 < cx + cw,
        item.x + Map.get(item, :w, 100_000) + 40 > cx do
      y = item.y - scroll
      clip = Map.get(item, :clip)
      if clip, do: :wxDC.setClippingRegion(dc, {clip.x, clip.y - scroll, clip.w, clip.h})
      draw(dc, item, y, scroll)
      if clip, do: :wxDC.destroyClippingRegion(dc)
    end

    :wxPaintDC.destroy(dc)
    :ok
  end

  # -- shadows and background images --------------------------------------------------

  @no_radii {{0, 0}, {0, 0}, {0, 0}, {0, 0}}

  # an outer shadow: translucent shapes stacked from the biggest to the smallest, which
  # fades the edge like a blur
  defp draw(dc, %{type: :shadow} = item, _y, scroll) do
    gc = :wxGraphicsContext.create(dc)
    clip_to(gc, item, scroll)

    for %{rect: {x, y, w, h}, radii: radii, color: color} <- item.layers do
      :wxGraphicsContext.setBrush(gc, :wxBrush.new(color))
      path = :wxGraphicsContext.createPath(gc)
      outline(path, x, y - scroll, w, h, radii || @no_radii)
      :wxGraphicsContext.fillPath(gc, path)
    end

    :wxGraphicsContext.destroy(gc)
  end

  # an inset shadow: inside the box, frames (the box minus a hole) stacked from the
  # smallest hole to the biggest
  defp draw(dc, %{type: :inset_shadow} = item, y, scroll) do
    gc = :wxGraphicsContext.create(dc)
    clip_to(gc, item, scroll)
    :wxGraphicsContext.clip(gc, item.x, y, item.w, item.h)

    for %{hole: hole, color: color} <- item.layers do
      :wxGraphicsContext.setBrush(gc, :wxBrush.new(color))
      path = :wxGraphicsContext.createPath(gc)
      outline(path, item.x, y, item.w, item.h, item.radius || @no_radii)

      if hole do
        %{rect: {hx, hy, hw, hh}, radii: hradii} = hole
        outline(path, hx, hy - scroll, hw, hh, hradii || @no_radii)
      end

      # odd-even: what is inside the box but outside the hole
      :wxGraphicsContext.fillPath(gc, path, [{:fillStyle, 1}])
    end

    :wxGraphicsContext.destroy(gc)
  end

  defp draw(dc, %{type: :bgimage} = item, _y, scroll) do
    gc = :wxGraphicsContext.create(dc)
    clip_to(gc, item, scroll)
    Enum.each(item.layers, &draw_layer(gc, &1, item.radius, scroll))
    :wxGraphicsContext.destroy(gc)
  end

  # a decoded picture, scaled to its box
  defp draw(dc, %{type: :image} = item, y, scroll) do
    case :ets.lookup(@images, item.url) do
      [{_url, bitmap}] ->
        gc = :wxGraphicsContext.create(dc)

        if clip = Map.get(item, :clip),
          do: :wxGraphicsContext.clip(gc, clip.x, clip.y - scroll, clip.w, clip.h)

        :wxGraphicsContext.drawBitmap(gc, bitmap, item.x, y, item.w, item.h)
        :wxGraphicsContext.destroy(gc)

      [] ->
        :ok
    end
  end

  # a vector picture: its display list is relative to the item's top-left corner
  defp draw(dc, %{type: :svg} = item, y, scroll) do
    gc = :wxGraphicsContext.create(dc)
    clip_to(gc, item, scroll)
    :wxGraphicsContext.clip(gc, item.x, y, item.w, item.h)
    draw_svg(gc, item.ops, item.x, y)
    :wxGraphicsContext.destroy(gc)
  end

  # the focus ring: a 2px line around the control, following its rounded corners
  defp draw(dc, %{type: :ring} = item, y, _scroll) do
    gc = :wxGraphicsContext.create(dc)
    radii = item.radius || {{0, 0}, {0, 0}, {0, 0}, {0, 0}}
    c = item.color
    borders(gc, item.x, y, item.w, item.h, radii, %{w: {2, 2, 2, 2}, c: {c, c, c, c}})
    :wxGraphicsContext.destroy(gc)
  end

  defp draw(dc, %{type: :caret} = item, y, _scroll) do
    :wxDC.setPen(dc, :wxPen.new(item.color))
    :wxDC.drawLine(dc, {item.x, y}, {item.x, y + item.h})
  end

  # Boxes with rounded corners are drawn as paths on a graphics context: the
  # background fills a rounded outline, each border side is a straight strip and
  # each corner a ring segment in the colour of the thicker adjacent side.
  defp draw(dc, %{type: :rect, radius: radius} = item, y, scroll) when radius != nil do
    gc = :wxGraphicsContext.create(dc)

    if clip = Map.get(item, :clip),
      do: :wxGraphicsContext.clip(gc, clip.x, clip.y - scroll, clip.w, clip.h)

    if item.color do
      :wxGraphicsContext.setBrush(gc, :wxBrush.new(item.color))
      path = :wxGraphicsContext.createPath(gc)
      outline(path, item.x, y, item.w, item.h, radius)
      :wxGraphicsContext.fillPath(gc, path)
    end

    if item.border, do: borders(gc, item.x, y, item.w, item.h, radius, item.border)
    :wxGraphicsContext.destroy(gc)
  end

  defp draw(dc, %{type: :rect} = item, y, _scroll) do
    :wxDC.setPen(dc, :wxPen.new({0, 0, 0}, style: 106))
    :wxDC.setBrush(dc, :wxBrush.new(item.color))
    :wxDC.drawRectangle(dc, {item.x, y}, {item.w, item.h})
  end

  defp draw(dc, %{type: :hr} = item, y, _scroll) do
    :wxDC.setPen(dc, :wxPen.new({170, 170, 170}))
    :wxDC.drawLine(dc, {item.x, y}, {item.x + item.w, y})
  end

  defp draw(dc, %{type: :text} = item, y, _scroll) do
    :wxDC.setFont(dc, font(item))
    :wxDC.setTextForeground(dc, item.color)
    :wxDC.drawText(dc, String.to_charlist(item.text), {item.x, y})
    :wxDC.setPen(dc, :wxPen.new(item.color))

    if item.underline,
      do: :wxDC.drawLine(dc, {item.x, y + item.h + 2}, {item.x + item.w, y + item.h + 2})

    if item.strike,
      do:
        :wxDC.drawLine(
          dc,
          {item.x, y + div(item.h, 2) + 2},
          {item.x + item.w, y + div(item.h, 2) + 2}
        )
  end

  defp clip_to(gc, item, scroll) do
    if clip = Map.get(item, :clip),
      do: :wxGraphicsContext.clip(gc, clip.x, clip.y - scroll, clip.w, clip.h)
  end

  # the root element's background layers cover the whole window and scroll with the page
  defp draw_canvas_layers(dc, [%{type: :canvas, layers: [_ | _] = layers} | _], scroll) do
    gc = :wxGraphicsContext.create(dc)
    Enum.each(layers, &draw_layer(gc, &1, nil, scroll))
    :wxGraphicsContext.destroy(gc)
  end

  defp draw_canvas_layers(_dc, _items, _scroll), do: :ok

  # One background layer: a picture or gradient, repeated as the layer says, and
  # clipped to the area it paints into.
  defp draw_layer(gc, layer, radii, scroll) do
    {cx, cy, cw, ch} = layer.clip
    :wxGraphicsContext.clip(gc, cx, cy - scroll, cw, ch)
    tiles = Browser.Backgrounds.tiles(layer.tile, layer.repeat, layer.clip)
    {_, _, tw, th} = layer.tile

    case layer.kind do
      :image ->
        case :ets.lookup(@images, layer.url) do
          [{_url, bitmap}] ->
            for {x, y} <- tiles,
                do: :wxGraphicsContext.drawBitmap(gc, bitmap, x, y - scroll, tw, th)

          [] ->
            :ok
        end

      :svg ->
        for {x, y} <- tiles do
          :wxGraphicsContext.clip(gc, x, y - scroll, tw, th)
          draw_svg(gc, layer.ops, x, y - scroll)
          :wxGraphicsContext.resetClip(gc)
          :wxGraphicsContext.clip(gc, cx, cy - scroll, cw, ch)
        end

      :linear ->
        {x1, y1, x2, y2} = layer.line
        stops = gradient_stops(layer.stops)

        for {x, y} <- tiles do
          brush =
            :wxGraphicsContext.createLinearGradientBrush(
              gc,
              x + x1,
              y + y1 - scroll,
              x + x2,
              y + y2 - scroll,
              stops
            )

          fill_tile(gc, brush, {x, y - scroll, tw, th}, layer.clip, radii, scroll)
        end

      :radial ->
        {ox, oy} = layer.center
        {rx, ry} = layer.radii
        stops = gradient_stops(layer.stops)

        for {x, y} <- tiles do
          radial_tile(gc, stops, {x + ox, y + oy - scroll}, {rx, ry}, {x, y - scroll, tw, th})
        end
    end
  end

  # -- vector pictures ----------------------------------------------------------------

  # Pen widths are whole pixels, so strokes are drawn in a space four times as big and
  # scaled back down: quarter-pixel precision.
  @stroke_scale 4

  defp draw_svg(gc, ops, ox, oy) do
    Enum.each(ops, fn
      %{kind: :path} = op ->
        if op.fill, do: svg_fill(gc, op, ox, oy)
        if op.stroke, do: svg_stroke(gc, op, ox, oy)

      %{kind: :text} = op ->
        svg_text(gc, op, ox, oy)
    end)
  end

  defp svg_path(gc, segments, ox, oy, k) do
    path = :wxGraphicsContext.createPath(gc)

    Enum.each(segments, fn
      {:M, x, y} ->
        :wxGraphicsPath.moveToPoint(path, (ox + x) * k, (oy + y) * k)

      {:L, x, y} ->
        :wxGraphicsPath.addLineToPoint(path, (ox + x) * k, (oy + y) * k)

      {:C, x1, y1, x2, y2, x, y} ->
        :wxGraphicsPath.addCurveToPoint(
          path,
          {(ox + x1) * k, (oy + y1) * k},
          {(ox + x2) * k, (oy + y2) * k},
          {(ox + x) * k, (oy + y) * k}
        )

      :Z ->
        :wxGraphicsPath.closeSubpath(path)
    end)

    path
  end

  defp svg_fill(gc, %{fill: %{paint: paint, rule: rule}, segments: segments}, ox, oy) do
    :wxGraphicsContext.setBrush(gc, svg_brush(gc, paint, ox, oy))
    path = svg_path(gc, segments, ox, oy, 1)
    :wxGraphicsContext.fillPath(gc, path, [{:fillStyle, if(rule == :evenodd, do: 1, else: 2)}])
  end

  defp svg_brush(_gc, {:color, color}, _ox, _oy), do: :wxBrush.new(color)

  defp svg_brush(gc, {:linear, {x1, y1, x2, y2}, stops}, ox, oy) do
    :wxGraphicsContext.createLinearGradientBrush(
      gc,
      ox + x1,
      oy + y1,
      ox + x2,
      oy + y2,
      gradient_stops(stops)
    )
  end

  defp svg_brush(gc, {:radial, {cx, cy, r, fx, fy}, stops}, ox, oy) do
    :wxGraphicsContext.createRadialGradientBrush(
      gc,
      ox + fx,
      oy + fy,
      ox + cx,
      oy + cy,
      max(r, 0.01),
      gradient_stops(stops)
    )
  end

  # pens can't be gradients: a gradient stroke takes its first colour
  defp stroke_color({:color, color}), do: color
  defp stroke_color({_, _, [{_, color} | _]}), do: color

  defp svg_stroke(gc, %{stroke: stroke, segments: segments}, ox, oy) do
    k = @stroke_scale
    pen = :wxPen.new(stroke_color(stroke.paint), [{:width, max(round(stroke.width * k), 1)}])

    :wxPen.setCap(
      pen,
      case stroke.cap do
        :round -> 130
        :square -> 131
        :butt -> 132
      end
    )

    :wxPen.setJoin(
      pen,
      case stroke.join do
        :bevel -> 120
        :miter -> 121
        :round -> 122
      end
    )

    :wxGraphicsContext.setPen(gc, pen)
    :wxGraphicsContext.scale(gc, 1 / k, 1 / k)
    :wxGraphicsContext.strokePath(gc, svg_path(gc, segments, ox, oy, k))
    :wxGraphicsContext.scale(gc, k * 1.0, k * 1.0)
  end

  # SVG gives the baseline, anchored at the start, middle or end of the text
  defp svg_text(gc, op, ox, oy) do
    f = font(%{size: max(round(op.size), 1), bold: op.bold, italic: op.italic, mono: op.mono})
    :wxGraphicsContext.setFont(gc, f, op.color)
    str = String.to_charlist(op.text)
    {w, h, descent, _} = :wxGraphicsContext.getTextExtent(gc, str)

    x =
      case op.anchor do
        :start -> op.x
        :middle -> op.x - w / 2
        :end -> op.x - w
      end

    :wxGraphicsContext.drawText(gc, str, ox + x, oy + op.y - (h - descent))
  end

  # a lone gradient that fills its whole area follows the box's rounded corners
  defp fill_tile(gc, brush, {x, y, w, h}, {cx, cy, cw, ch}, radii, scroll) do
    :wxGraphicsContext.setBrush(gc, brush)
    path = :wxGraphicsContext.createPath(gc)

    if radii && {x, y, w, h} == {cx, cy - scroll, cw, ch},
      do: outline(path, x, y, w, h, radii),
      else: :wxGraphicsPath.addRectangle(path, x, y, w, h)

    :wxGraphicsContext.fillPath(gc, path)
  end

  # a radial gradient is circular; an ellipse is drawn as a circle in a stretched space
  defp radial_tile(gc, stops, {cx, cy}, {rx, ry}, {x, y, w, h}) do
    if abs(rx - ry) < 0.5 do
      brush = :wxGraphicsContext.createRadialGradientBrush(gc, cx, cy, cx, cy, rx, stops)
      :wxGraphicsContext.setBrush(gc, brush)
      path = :wxGraphicsContext.createPath(gc)
      :wxGraphicsPath.addRectangle(path, x, y, w, h)
      :wxGraphicsContext.fillPath(gc, path)
    else
      k = rx / ry
      :wxGraphicsContext.translate(gc, cx, cy)
      :wxGraphicsContext.scale(gc, 1.0, ry / rx)
      brush = :wxGraphicsContext.createRadialGradientBrush(gc, 0.0, 0.0, 0.0, 0.0, rx, stops)
      :wxGraphicsContext.setBrush(gc, brush)
      path = :wxGraphicsContext.createPath(gc)
      :wxGraphicsPath.addRectangle(path, x - cx, (y - cy) * k, w, h * k)
      :wxGraphicsContext.fillPath(gc, path)
      :wxGraphicsContext.scale(gc, 1.0, k)
      :wxGraphicsContext.translate(gc, -cx, -cy)
    end
  end

  # [{position, {r, g, b, a}}] as gradient stops; the ends are the first and last colours
  defp gradient_stops(stops) do
    [{_, first} | _] = stops
    {_, last} = List.last(stops)
    gs = :wxGraphicsGradientStops.new([{:startCol, first}, {:endCol, last}])
    Enum.each(stops, fn {pos, color} -> :wxGraphicsGradientStops.add(gs, color, pos) end)
    gs
  end

  # a quarter ellipse is approximated by a cubic bezier with this handle length
  @kappa 0.5523

  defp outline(path, x, y, w, h, {{tlx, tly}, {trx, try_}, {brx, bry}, {blx, bly}}) do
    k = 1 - @kappa
    :wxGraphicsPath.moveToPoint(path, x + tlx, y)
    :wxGraphicsPath.addLineToPoint(path, x + w - trx, y)

    :wxGraphicsPath.addCurveToPoint(
      path,
      x + w - trx * k,
      y,
      x + w,
      y + try_ * k,
      x + w,
      y + try_
    )

    :wxGraphicsPath.addLineToPoint(path, x + w, y + h - bry)

    :wxGraphicsPath.addCurveToPoint(
      path,
      x + w,
      y + h - bry * k,
      x + w - brx * k,
      y + h,
      x + w - brx,
      y + h
    )

    :wxGraphicsPath.addLineToPoint(path, x + blx, y + h)

    :wxGraphicsPath.addCurveToPoint(
      path,
      x + blx * k,
      y + h,
      x,
      y + h - bly * k,
      x,
      y + h - bly
    )

    :wxGraphicsPath.addLineToPoint(path, x, y + tly)
    :wxGraphicsPath.addCurveToPoint(path, x, y + tly * k, x + tlx * k, y, x + tlx, y)
    :wxGraphicsPath.closeSubpath(path)
  end

  defp borders(gc, x, y, w, h, radii, %{w: {bt, br, bb, bl}, c: {tc, rc, bc, lc}}) do
    {{tlx, tly}, {trx, try_}, {brx, bry}, {blx, bly}} = radii

    # straight parts of the four sides
    strip(gc, tc, x + tlx, y, w - tlx - trx, bt)
    strip(gc, bc, x + blx, y + h - bb, w - blx - brx, bb)
    strip(gc, lc, x, y + tly, bl, h - tly - bly)
    strip(gc, rc, x + w - br, y + try_, br, h - try_ - bry)

    # corners: local coordinates run from the corner point inwards along (dx, dy)
    corner(gc, pick(tc, bt, lc, bl), x, y, 1, 1, {tlx, tly}, bl, bt)
    corner(gc, pick(tc, bt, rc, br), x + w, y, -1, 1, {trx, try_}, br, bt)
    corner(gc, pick(bc, bb, rc, br), x + w, y + h, -1, -1, {brx, bry}, br, bb)
    corner(gc, pick(bc, bb, lc, bl), x, y + h, 1, -1, {blx, bly}, bl, bb)
  end

  # colour of the thicker of the two sides meeting at a corner (horizontal wins ties)
  defp pick(hc, ht, vc, vt), do: if(ht >= vt, do: hc || vc, else: vc || hc)

  defp strip(_gc, nil, _x, _y, _w, _h), do: :ok
  defp strip(_gc, _c, _x, _y, w, h) when w <= 0 or h <= 0, do: :ok

  defp strip(gc, color, x, y, w, h) do
    :wxGraphicsContext.setBrush(gc, :wxBrush.new(color))
    path = :wxGraphicsContext.createPath(gc)
    :wxGraphicsPath.addRectangle(path, x, y, w, h)
    :wxGraphicsContext.fillPath(gc, path)
  end

  defp corner(_gc, nil, _cx, _cy, _dx, _dy, _r, _bv, _bh), do: :ok
  defp corner(_gc, _c, _cx, _cy, _dx, _dy, {rx, ry}, _bv, _bh) when rx <= 0 or ry <= 0, do: :ok

  # `bv` is the thickness of the vertical side at this corner, `bh` of the horizontal
  defp corner(gc, color, cx, cy, dx, dy, {rx, ry}, bv, bh) do
    k = 1 - @kappa
    irx = max(rx - bv, 0)
    iry = max(ry - bh, 0)
    m = fn u, v -> {cx + dx * u, cy + dy * v} end
    {ox1, oy1} = m.(0, ry)
    {ox2, oy2} = m.(rx, 0)
    {c1x, c1y} = m.(0, ry * k)
    {c2x, c2y} = m.(rx * k, 0)
    {ax, ay} = m.(bv + irx, bh)
    {bx, by} = m.(bv, bh + iry)
    {d1x, d1y} = m.(bv + irx - irx * @kappa, bh)
    {d2x, d2y} = m.(bv, bh + iry - iry * @kappa)

    :wxGraphicsContext.setBrush(gc, :wxBrush.new(color))
    path = :wxGraphicsContext.createPath(gc)
    :wxGraphicsPath.moveToPoint(path, ox1, oy1)
    :wxGraphicsPath.addCurveToPoint(path, c1x, c1y, c2x, c2y, ox2, oy2)
    :wxGraphicsPath.addLineToPoint(path, ax, ay)
    :wxGraphicsPath.addCurveToPoint(path, d1x, d1y, d2x, d2y, bx, by)
    :wxGraphicsPath.closeSubpath(path)
    :wxGraphicsContext.fillPath(gc, path)
  end

  # -- hit testing -------------------------------------------------------------

  @link_band 64

  @doc """
  Indexes the links of a laid out page by horizontal band, so `link_at/3` looks at the few
  links near the pointer instead of every item. Each band keeps its links in paint order.
  """
  def links(items) do
    items
    |> Enum.reduce(%{}, fn
      %{type: type, href: href} = it, acc
      when type in [:text, :image, :svg] and is_binary(href) ->
        first = band(it.y)
        last = band(it.y + it.h + 4)
        Enum.reduce(first..last//1, acc, fn b, acc -> Map.update(acc, b, [it], &[it | &1]) end)

      _, acc ->
        acc
    end)
    |> Map.new(fn {b, its} -> {b, Enum.reverse(its)} end)
  end

  @doc "The href of the first link in the index `links` (see `links/1`) at page position `{x, y}`, or nil."
  def link_at(links, x, y) do
    links
    |> Map.get(band(y), [])
    |> Enum.find_value(fn it ->
      if inside?(x, y, it.x, it.y, it.w, it.h + 4) and clipped_in?(it, x, y), do: it.href
    end)
  end

  defp band(y), do: floor(y / @link_band)

  defp inside?(px, py, x, y, w, h), do: px >= x and px <= x + w and py >= y and py <= y + h

  # a link scrolled out of its clipping box can't be clicked
  defp clipped_in?(%{clip: c}, x, y), do: inside?(x, y, c.x, c.y, c.w, c.h)
  defp clipped_in?(_, _, _), do: true

  def set_url_text(%{url: url}, text), do: :wxTextCtrl.setValue(url, String.to_charlist(text))
  def set_title(%{frame: f}, title), do: :wxFrame.setTitle(f, String.to_charlist(title))
  def set_status(%{frame: f}, text), do: :wxFrame.setStatusText(f, String.to_charlist(text))
  def enable(widget, bool), do: :wxWindow.enable(widget, enable: bool)
  def refresh(%{panel: p}), do: :wxWindow.refresh(p)

  @doc "Sets the mouse cursor over the page: `:arrow`, `:hand` or `:text`."
  def set_cursor(%{panel: p, cursors: cursors}, kind) do
    kind = if kind in [true, :hand], do: :hand, else: if(kind == :text, do: :text, else: :arrow)
    :wxWindow.setCursor(p, Map.fetch!(cursors, kind))
  end

  @doc "Moves keyboard focus to the page, so key events reach it."
  def focus_page(%{panel: p}), do: :wxWindow.setFocus(p)

  # -- images ------------------------------------------------------------------------

  @doc """
  Decodes image bytes (PNG, JPEG, GIF or BMP) into a bitmap the painter can draw, kept
  under `url`. Returns `{:ok, width, height}` or `:error`. The toolkit reads from files,
  so the bytes pass through a temporary one.
  """
  def load_image(url, bytes, format) do
    path =
      Path.join(System.tmp_dir!(), "browser-pic-#{System.unique_integer([:positive])}.#{format}")

    try do
      File.write!(path, bytes)
      image = :wxImage.new(String.to_charlist(path))

      if :wxImage.isOk(image) do
        {w, h} = {:wxImage.getWidth(image), :wxImage.getHeight(image)}
        bitmap = :wxBitmap.new(image)
        :wxImage.destroy(image)
        :ets.insert(@images, {url, bitmap})
        if w > 0 and h > 0, do: {:ok, w, h}, else: :error
      else
        :error
      end
    rescue
      _ -> :error
    after
      File.rm(path)
    end
  end

  # -- controls --------------------------------------------------------------------

  @doc "The id of the form control at page position `{x, y}` (the smallest if they nest), or nil."
  def control_at(controls, x, y) do
    controls
    |> Enum.filter(fn {_cid, b} ->
      x >= b.x and x <= b.x + b.w and y >= b.y and y <= b.y + b.h
    end)
    |> Enum.min_by(fn {_cid, b} -> b.w * b.h end, fn -> nil end)
    |> case do
      nil -> nil
      {cid, _} -> cid
    end
  end

  # -- keyboard and clipboard ------------------------------------------------------

  @doc "Reads a wx key event into the plain map `Browser.Interact.key/1` expects."
  def key_event(
        wxKey(
          keyCode: code,
          uniChar: char,
          controlDown: ctrl,
          metaDown: meta,
          shiftDown: shift,
          altDown: alt
        )
      ) do
    %{code: code, char: char, ctrl?: ctrl, meta?: meta, shift?: shift, alt?: alt}
  end

  @doc "The text on the clipboard, or \"\"."
  def clipboard_text do
    clip = :wxClipboard.get()

    if :wxClipboard.open(clip) do
      data = :wxTextDataObject.new()
      text = if :wxClipboard.getData(clip, data), do: :wxTextDataObject.getText(data), else: []
      :wxClipboard.close(clip)
      List.to_string(text)
    else
      ""
    end
  end

  # -- select popup ----------------------------------------------------------------

  @menu_base 1000

  @doc """
  Pops up a menu of `labels` at page position `{x, y}` (the chosen one is ticked). The
  choice arrives as a `command_menu_selected` event whose id is `menu_base() + index`.
  """
  def popup_menu(%{panel: p}, {x, y}, labels, selected) do
    menu = :wxMenu.new()

    labels
    |> Enum.with_index()
    |> Enum.each(fn {label, i} ->
      text = if i == selected, do: "✓ " <> label, else: "   " <> label
      :wxMenu.append(menu, @menu_base + i, String.to_charlist(text))
    end)

    :wxMenu.connect(menu, :command_menu_selected)
    :wxWindow.popupMenu(p, menu, x, y)
    :ok
  end

  def menu_base, do: @menu_base
end
