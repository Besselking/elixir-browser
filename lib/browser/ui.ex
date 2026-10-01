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

  defstruct [:frame, :url, :back, :forward, :reload, :panel, :status]

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
      status: status
    }
  end

  @doc "Hands the painter what to draw; `caret_on` is the blink state of the text caret."
  def publish(items, scroll, caret_on \\ true),
    do: :ets.insert(@view, {:view, items, scroll, caret_on})

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

  @doc "Returns a `(text, style) -> width` function backed by a wx client DC."
  def measurer(%{panel: panel}) do
    dc = :wxClientDC.new(panel)

    fn text, style ->
      :wxDC.setFont(dc, font(style))
      {w, _h} = :wxDC.getTextExtent(dc, String.to_charlist(text))
      w
    end
  end

  # -- painting (runs in wx callback process) --------------------------------

  defp paint(panel) do
    [{:view, items, scroll, caret_on}] = :ets.lookup(@view, :view)
    dc = :wxPaintDC.new(panel)

    canvas =
      case items do
        [%{type: :canvas, color: color} | _] -> color
        _ -> {255, 255, 255}
      end

    :wxDC.setBackground(dc, :wxBrush.new(canvas))
    :wxDC.clear(dc)
    {_, h} = :wxWindow.getClientSize(panel)

    for item <- items,
        item.type != :canvas,
        item.type != :caret or caret_on,
        not Map.get(item, :hidden, false),
        item.y - scroll < h,
        item.y + Map.get(item, :h, 40) + 40 - scroll > 0 do
      y = item.y - scroll
      clip = Map.get(item, :clip)
      if clip, do: :wxDC.setClippingRegion(dc, {clip.x, clip.y - scroll, clip.w, clip.h})
      draw(dc, item, y, scroll)
      if clip, do: :wxDC.destroyClippingRegion(dc)
    end

    :wxPaintDC.destroy(dc)
    :ok
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

  def link_at(items, x, y) do
    Enum.find_value(items, fn
      %{type: type, href: href} = it when type in [:text, :image] and is_binary(href) ->
        if inside?(x, y, it.x, it.y, it.w, it.h + 4) and clipped_in?(it, x, y), do: href

      _ ->
        nil
    end)
  end

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
  def set_cursor(%{panel: p}, kind) do
    id =
      case kind do
        true -> 6
        :hand -> 6
        :text -> 7
        _ -> 1
      end

    :wxWindow.setCursor(p, :wxCursor.new(id))
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
