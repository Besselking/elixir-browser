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

  @doc "Sets what is drawn: the tab titles and the index of the active tab."
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

    :wxDC.setBackground(dc, :wxBrush.new({218, 221, 227}))
    :wxDC.clear(dc)
    :wxDC.setPen(dc, :wxPen.new({170, 174, 182}))

    titles
    |> Enum.zip(layout(length(titles), width))
    |> Enum.with_index()
    |> Enum.each(fn {{title, {x, w}}, i} -> paint_tab(dc, title, x, w, i == active) end)

    {px, pw} = plus(length(titles), width)
    :wxDC.setTextForeground(dc, {60, 60, 60})
    {tw, th} = :wxDC.getTextExtent(dc, ~c"+")
    :wxDC.drawText(dc, ~c"+", {px + div(pw - tw, 2), div(@height - th, 2)})

    :wxDC.setPen(dc, :wxPen.new({170, 174, 182}))
    :wxDC.drawLine(dc, {0, @height - 1}, {width, @height - 1})
    :wxPaintDC.destroy(dc)
    :ok
  end

  defp paint_tab(dc, title, x, w, active?) do
    top = if active?, do: 3, else: 5
    bg = if active?, do: {255, 255, 255}, else: {200, 204, 212}
    :wxDC.setBrush(dc, :wxBrush.new(bg))
    :wxDC.drawRoundedRectangle(dc, {x, top, w - 2, @height - top + 6}, 6.0)
    if active?, do: erase_bottom(dc, x, w)

    :wxDC.setTextForeground(dc, {30, 30, 30})
    avail = w - @close - 22
    :wxDC.setClippingRegion(dc, {x + 8, 0, max(avail, 1), @height})
    {_, th} = :wxDC.getTextExtent(dc, ~c"Ag")
    text = fit(dc, clip(title), avail)
    :wxDC.drawText(dc, String.to_charlist(text), {x + 10, div(@height - th, 2) + 1})
    :wxDC.destroyClippingRegion(dc)

    # the close box: a cross
    cx = x + w - @close - 4
    cy = div(@height - 8, 2) + 1
    :wxDC.setPen(dc, :wxPen.new({90, 90, 90}, width: 1))
    :wxDC.drawLine(dc, {cx + 4, cy}, {cx + 12, cy + 8})
    :wxDC.drawLine(dc, {cx + 12, cy}, {cx + 4, cy + 8})
    :wxDC.setPen(dc, :wxPen.new({170, 174, 182}))
  end

  # the active tab is open at the bottom, into the page's toolbar
  defp erase_bottom(dc, x, w) do
    :wxDC.setPen(dc, :wxPen.new({255, 255, 255}))
    :wxDC.drawLine(dc, {x + 1, @height - 1}, {x + w - 2, @height - 1})
    :wxDC.setPen(dc, :wxPen.new({170, 174, 182}))
  end

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
