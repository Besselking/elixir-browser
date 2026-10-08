defmodule Browser.TabStrip do
  @moduledoc """
  The row of tabs above the address bar: where each tab and its close box are (pure, so it can
  be tested without a window), and how the strip is painted. The painter runs in a wx callback
  process and reads what to draw from an ETS table; `put/2` fills it.
  """

  @table :browser_tabs
  @height 30
  @pad 4
  @max_w 220
  @min_w 70
  @plus_w 28
  @close 16
  @max_chars 80

  def height, do: @height

  @doc "Creates the table the painter reads."
  def init do
    :ets.new(@table, [:named_table, :public])
    put([], 0)
  end

  @doc "Sets what is drawn: each tab's `{title, loading?}` and the index of the active tab."
  def put(titles, active), do: :ets.insert(@table, {:tabs, titles, active})

  @doc "The `{x, width}` of each of `count` tabs in a strip `width` px wide."
  def layout(count, width) do
    each = ((width - @pad * 2 - @plus_w) / max(count, 1)) |> trunc() |> min(@max_w) |> max(@min_w)
    for i <- 0..(count - 1)//1, do: {@pad + i * each, each}
  end

  @doc "The `{x, width}` of the new-tab button."
  def plus(count, width) do
    case List.last(layout(count, width)) do
      {x, w} -> {x + w + 2, @plus_w}
      nil -> {@pad, @plus_w}
    end
  end

  @doc "What is at `{x, y}`: `{:tab, i}`, `{:close, i}`, `:new` or `nil`."
  def hit(count, width, x, y) when y >= 0 and y < @height do
    tabs = layout(count, width)

    case Enum.find_index(tabs, fn {tx, tw} -> x >= tx and x < tx + tw end) do
      nil ->
        {px, pw} = plus(count, width)
        if x >= px and x < px + pw, do: :new

      i ->
        {tx, tw} = Enum.at(tabs, i)
        if x >= tx + tw - @close - 8, do: {:close, i}, else: {:tab, i}
    end
  end

  def hit(_count, _width, _x, _y), do: nil

  @doc "Cuts `title` to what a tab can show."
  def clip(title) do
    title = title |> to_string() |> String.replace(~r/\s+/, " ")
    if String.length(title) > @max_chars, do: String.slice(title, 0, @max_chars), else: title
  end

  # -- painting (runs in the wx callback process) -------------------------------------------

  @doc false
  def paint(panel) do
    dc = :wxPaintDC.new(panel)
    [{:tabs, titles, active}] = :ets.lookup(@table, :tabs)
    {width, _} = :wxWindow.getClientSize(panel)

    colors = colors()
    Process.put(:tab_colors, colors)
    :wxDC.setBackground(dc, :wxBrush.new(colors.strip))
    :wxDC.clear(dc)
    :wxDC.setPen(dc, :wxPen.new(colors.line))

    titles
    |> Enum.zip(layout(length(titles), width))
    |> Enum.with_index()
    |> Enum.each(fn {{{title, loading?}, {x, w}}, i} ->
      paint_tab(dc, title, loading?, x, w, i == active)
    end)

    {px, pw} = plus(length(titles), width)
    :wxDC.setTextForeground(dc, colors.text)
    {tw, th} = :wxDC.getTextExtent(dc, ~c"+")
    :wxDC.drawText(dc, ~c"+", {px + div(pw - tw, 2), div(@height - th, 2)})

    :wxDC.setPen(dc, :wxPen.new(colors.line))
    :wxDC.drawLine(dc, {0, @height - 1}, {width, @height - 1})
    :wxPaintDC.destroy(dc)
    :ok
  end

  defp paint_tab(dc, title, loading?, x, w, active?) do
    top = if active?, do: 3, else: 5
    c = Process.get(:tab_colors)
    bg = if active?, do: c.active, else: c.inactive
    :wxDC.setBrush(dc, :wxBrush.new(bg))
    :wxDC.drawRoundedRectangle(dc, {x, top, w - 2, @height - top + 6}, 6.0)
    if active?, do: erase_bottom(dc, x, w)

    :wxDC.setTextForeground(dc, c.text)
    # a dot before the title while the tab's page is loading
    dot = if loading?, do: 14, else: 0

    if loading? do
      :wxDC.setBrush(dc, :wxBrush.new({70, 130, 230}))
      :wxDC.setPen(dc, :wxPen.new({70, 130, 230}))
      :wxDC.drawCircle(dc, {x + 15, div(@height, 2) + 1}, 4)
    end

    avail = w - @close - 22 - dot
    :wxDC.setClippingRegion(dc, {x + 8 + dot, 0, max(avail, 1), @height})
    {_, th} = :wxDC.getTextExtent(dc, ~c"Ag")
    text = fit(dc, clip(title), avail)
    :wxDC.drawText(dc, String.to_charlist(text), {x + 10 + dot, div(@height - th, 2) + 1})
    :wxDC.destroyClippingRegion(dc)

    # the close box: a cross
    cx = x + w - @close - 4
    cy = div(@height - 8, 2) + 1
    :wxDC.setPen(dc, :wxPen.new(c.text, width: 1))
    :wxDC.drawLine(dc, {cx + 4, cy}, {cx + 12, cy + 8})
    :wxDC.drawLine(dc, {cx + 12, cy}, {cx + 4, cy + 8})
    :wxDC.setPen(dc, :wxPen.new(c.line))
  end

  # the active tab is open at the bottom, into the page's toolbar
  defp erase_bottom(dc, x, w) do
    c = Process.get(:tab_colors)
    :wxDC.setPen(dc, :wxPen.new(c.active))
    :wxDC.drawLine(dc, {x + 1, @height - 1}, {x + w - 2, @height - 1})
    :wxDC.setPen(dc, :wxPen.new(c.line))
  end

  # wxSYS_COLOUR_BTNFACE, BTNSHADOW and BTNTEXT: the toolbar's colours, so the strip follows
  # the system theme (dark mode) like the address bar does
  @face 15
  @shadow 16
  @btn_text 18

  @doc "The strip's colours for a toolbar face colour, shadow and text colour."
  def palette({fr, fg, fb}, line, text) do
    dark? = 0.299 * fr + 0.587 * fg + 0.114 * fb < 128
    shade = fn k -> {round(fr * k), round(fg * k), round(fb * k)} end
    # the strip is a step away from the toolbar, inactive tabs are in between
    {strip, inactive} =
      if dark?, do: {shade.(0.55), shade.(0.78)}, else: {shade.(0.92), shade.(0.96)}

    %{strip: strip, inactive: inactive, active: {fr, fg, fb}, line: line, text: text}
  end

  defp colors do
    [face, line, text] =
      for id <- [@face, @shadow, @btn_text], do: :wxSystemSettings.getColour(id) |> rgb()

    palette(face, line, text)
  end

  defp rgb({r, g, b, _a}), do: {r, g, b}
  defp rgb({r, g, b}), do: {r, g, b}

  # the title shortened with an ellipsis to `avail` px
  defp fit(dc, text, avail) do
    {tw, _} = :wxDC.getTextExtent(dc, String.to_charlist(text))

    if tw <= avail or text == "" do
      text
    else
      text
      |> String.slice(0, max(trunc(String.length(text) * avail / tw) - 1, 1))
      |> Kernel.<>("…")
    end
  end
end
