defmodule Browser.UI do
  @moduledoc "wx widgets: window construction, painting, font metrics and hit testing."

  require Record
  Record.defrecord(:wx, Record.extract(:wx, from_lib: "wx/include/wx.hrl"))
  Record.defrecord(:wxMouse, Record.extract(:wxMouse, from_lib: "wx/include/wx.hrl"))
  Record.defrecord(:wxCommand, Record.extract(:wxCommand, from_lib: "wx/include/wx.hrl"))
  Record.defrecord(:wxSize, Record.extract(:wxSize, from_lib: "wx/include/wx.hrl"))
  Record.defrecord(:wxKey, Record.extract(:wxKey, from_lib: "wx/include/wx.hrl"))

  @view :browser_view
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
    :ets.insert(@view, {:view, [], 0})

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

    panel = :wxPanel.new(frame, style: 65536)
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
    :wxPanel.connect(panel, :key_down)
    :wxPanel.connect(panel, :paint, callback: fn _ev, _obj -> paint(panel) end)

    :wxFrame.show(frame)
    :wxWindow.setFocus(panel)

    %__MODULE__{frame: frame, url: url, back: back, forward: forward, reload: reload,
                panel: panel, status: status}
  end

  def publish(items, scroll), do: :ets.insert(@view, {:view, items, scroll})

  def client_width(%{panel: panel}), do: panel |> :wxWindow.getClientSize() |> elem(0)
  def client_height(%{panel: panel}), do: panel |> :wxWindow.getClientSize() |> elem(1)

  # -- fonts ---------------------------------------------------------------

  defp font(%{size: size, bold: bold, italic: italic, mono: mono}) do
    key = {:font, size, bold, italic, mono}

    case Process.get(key) do
      nil ->
        weight = :wxe_util.get_const(if bold, do: :wxFONTWEIGHT_BOLD, else: :wxFONTWEIGHT_NORMAL)
        f = :wxFont.new(size, if(mono, do: @wx_teletype, else: @wx_default),
                        if(italic, do: @wx_italic, else: @wx_normal), weight)
        Process.put(key, f)
        f

      f -> f
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
    [{:view, items, scroll}] = :ets.lookup(@view, :view)
    dc = :wxPaintDC.new(panel)
    :wxDC.setBackground(dc, :wxBrush.new({255, 255, 255}))
    :wxDC.clear(dc)
    {_, h} = :wxWindow.getClientSize(panel)

    for item <- items, not Map.get(item, :hidden, false),
        item.y - scroll < h, item.y + Map.get(item, :h, 40) + 40 - scroll > 0 do
      y = item.y - scroll

      case item do
        %{type: :rect} ->
          :wxDC.setPen(dc, :wxPen.new({0, 0, 0}, style: 106))
          :wxDC.setBrush(dc, :wxBrush.new(item.color))
          :wxDC.drawRectangle(dc, {item.x, y}, {item.w, item.h})

        %{type: :hr} ->
          :wxDC.setPen(dc, :wxPen.new({170, 170, 170}))
          :wxDC.drawLine(dc, {item.x, y}, {item.x + item.w, y})

        %{type: :text} ->
          :wxDC.setFont(dc, font(item))
          :wxDC.setTextForeground(dc, item.color)
          :wxDC.drawText(dc, String.to_charlist(item.text), {item.x, y})
          :wxDC.setPen(dc, :wxPen.new(item.color))

          if item.underline,
            do: :wxDC.drawLine(dc, {item.x, y + item.h + 2}, {item.x + item.w, y + item.h + 2})

          if item.strike,
            do: :wxDC.drawLine(dc, {item.x, y + div(item.h, 2) + 2}, {item.x + item.w, y + div(item.h, 2) + 2})
      end
    end

    :wxPaintDC.destroy(dc)
    :ok
  end

  # -- hit testing -------------------------------------------------------------

  def link_at(items, x, y) do
    Enum.find_value(items, fn
      %{type: :text, href: href} = it when is_binary(href) ->
        if x >= it.x and x <= it.x + it.w and y >= it.y and y <= it.y + it.h + 4, do: href

      _ -> nil
    end)
  end

  def set_url_text(%{url: url}, text), do: :wxTextCtrl.setValue(url, String.to_charlist(text))
  def set_title(%{frame: f}, title), do: :wxFrame.setTitle(f, String.to_charlist(title))
  def set_status(%{frame: f}, text), do: :wxFrame.setStatusText(f, String.to_charlist(text))
  def enable(widget, bool), do: :wxWindow.enable(widget, enable: bool)
  def refresh(%{panel: p}), do: :wxWindow.refresh(p)
  def set_cursor(%{panel: p}, hand?) do
    :wxWindow.setCursor(p, :wxCursor.new(if hand?, do: 6, else: 1))
  end
end
