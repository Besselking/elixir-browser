defmodule Browser.Scrollbars do
  @moduledoc """
  The scrollbars of the page and of the boxes that scroll (`Browser.Scrollers`).

  They are drawn over the content and take no room from the layout. A bar is a map
  `%{id, axis, track, thumb, max, pos, view, clip}` with `track` and `thumb` as `{x, y, w, h}` in
  window coordinates; `id` is `:page` or the id of a scroller, whose bars are cut to `clip`
  (where it shows its content: page x, window y).
  """

  alias Browser.Scrollers

  @bar 12
  @inset 2
  @min_thumb 24
  @page_step 40

  @doc "Width of a bar."
  def size, do: @bar

  @doc """
  The bars to show. `view` is `%{w, h, scroll, scroll_x, height, content_w}`: the size of the
  window, how far the page is scrolled, and how big the page is.
  """
  def bars(view, scrollers, soff) do
    page_bars(view) ++ scroller_bars(view, scrollers, soff)
  end

  defp page_bars(view) do
    max_y = max(view.height - view.h, 0)
    max_x = max(view.content_w - view.w, 0)

    pair(:page, {0, 0, view.w, view.h}, {max_x, max_y}, {view.scroll_x, view.scroll}, nil)
  end

  defp scroller_bars(view, scrollers, soff) do
    for {sid, s} <- scrollers,
        {xk, yk} = s.ov,
        s.max_x > 0 or s.max_y > 0,
        r = Scrollers.visible(scrollers, soff, sid),
        r.w > 0 and r.h > 0,
        bar <-
          pair(
            sid,
            {r.x - view.scroll_x, r.y - view.scroll, r.w, r.h},
            {if(xk, do: s.max_x, else: 0), if(yk, do: s.max_y, else: 0)},
            Map.get(soff, sid, {0, 0}),
            %{r | y: r.y - view.scroll}
          ) do
      bar
    end
  end

  # the bars of a region `{x, y, w, h}`: a vertical one at the right edge when it scrolls
  # down, a horizontal one at the bottom when it scrolls sideways, shortened to leave
  # the corner
  defp pair(id, {x, y, w, h}, {max_x, max_y}, {pos_x, pos_y}, clip) do
    both? = max_x > 0 and max_y > 0
    corner = if both?, do: @bar, else: 0

    vertical =
      if max_y > 0 and w >= @bar do
        [bar(id, :y, {x + w - @bar, y, @bar, h - corner}, h, max_y, pos_y, clip)]
      else
        []
      end

    horizontal =
      if max_x > 0 and h >= @bar do
        [bar(id, :x, {x, y + h - @bar, w - corner, @bar}, w, max_x, pos_x, clip)]
      else
        []
      end

    vertical ++ horizontal
  end

  defp bar(id, axis, {x, y, w, h} = track, view, max, pos, clip) do
    len = if axis == :y, do: h, else: w
    len = max(len, 1)
    thumb_len = (len * view / (view + max)) |> round() |> max(@min_thumb) |> min(len)
    at = round(pos / max * (len - thumb_len))

    thumb =
      case axis do
        :y -> {x + @inset, y + at, w - 2 * @inset, thumb_len}
        :x -> {x + at, y + @inset, thumb_len, h - 2 * @inset}
      end

    %{id: id, axis: axis, track: track, thumb: thumb, max: max, pos: pos, view: view, clip: clip}
  end

  @doc """
  What is at window position `{x, y}`: `{:thumb, bar}`, `{:track, bar, direction}` (-1 towards
  the start, 1 towards the end) or nil. The last bar drawn is on top.
  """
  def hit(bars, x, y) do
    bars
    |> Enum.reverse()
    |> Enum.find_value(fn bar ->
      cond do
        inside?(bar.thumb, x, y) -> {:thumb, bar}
        inside?(bar.track, x, y) -> {:track, bar, direction(bar, x, y)}
        true -> nil
      end
    end)
  end

  defp inside?({bx, by, bw, bh}, x, y), do: x >= bx and x < bx + bw and y >= by and y < by + bh

  defp direction(%{axis: :y, thumb: {_, ty, _, _}}, _x, y), do: if(y < ty, do: -1, else: 1)
  defp direction(%{axis: :x, thumb: {tx, _, _, _}}, x, _y), do: if(x < tx, do: -1, else: 1)

  @doc "How far a click on the track beside the thumb scrolls: a page less a little."
  def page(bar), do: max(bar.view - @page_step, div(bar.view, 2))

  @doc "Where the offset of `bar` is when the mouse is at window position `{x, y}` holding the thumb `grab` px from its start."
  def offset_at(%{axis: axis, track: {tx, ty, tw, th}, thumb: {_, _, thw, thh}} = bar, x, y, grab) do
    {start, len, thumb} =
      if axis == :y, do: {ty, th, thh}, else: {tx, tw, thw}

    room = max(len - thumb, 1)
    mouse = if axis == :y, do: y, else: x
    (mouse - grab - start) / room * bar.max
  end

  @doc "How far from its start the mouse holds the thumb."
  def grab(%{axis: :y, thumb: {_, ty, _, _}}, _x, y), do: y - ty
  def grab(%{axis: :x, thumb: {tx, _, _, _}}, x, _y), do: x - tx

  @doc "Whether the page (its `items`) has a dark background, which wants light bars."
  def dark_page?(items) do
    case items do
      [%{type: :canvas, color: color} | _] when is_tuple(color) and tuple_size(color) >= 3 ->
        0.299 * elem(color, 0) + 0.587 * elem(color, 1) + 0.114 * elem(color, 2) < 128

      _ ->
        false
    end
  end

  @doc """
  The items that draw `bars` in the overlay, at fixed places of the window (`scroll_x` is
  added because items are drawn at page x). `dragging` is the id and axis of the bar being
  dragged. `dark?` (see `dark_page?/1`) picks light bars instead of dark ones.
  """
  def items(bars, scroll_x, dragging, dark?) do
    Enum.flat_map(bars, fn bar ->
      held? = dragging == {bar.id, bar.axis}

      [
        piece(bar.track, scroll_x, bar.clip, track_color(dark?), 0),
        piece(bar.thumb, scroll_x, bar.clip, thumb_color(dark?, held?), div(@bar - 2 * @inset, 2))
      ]
    end)
  end

  defp piece({x, y, w, h}, scroll_x, clip, color, round) do
    r = {round, round}

    %{
      type: :rect,
      x: x + scroll_x,
      y: y,
      w: w,
      h: h,
      color: color,
      radius: {r, r, r, r},
      border: nil,
      stick: :fixed,
      scrollbar: true
    }
    |> then(&if(clip, do: Map.put(&1, :clip, clip), else: &1))
  end

  defp track_color(true), do: {255, 255, 255, 28}
  defp track_color(false), do: {0, 0, 0, 28}

  defp thumb_color(true, held?), do: {255, 255, 255, if(held?, do: 190, else: 130)}
  defp thumb_color(false, held?), do: {0, 0, 0, if(held?, do: 190, else: 135)}
end
