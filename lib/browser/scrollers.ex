defmodule Browser.Scrollers do
  @moduledoc """
  Boxes with `overflow: scroll | auto` that scroll their own content.

  The layout puts every such box in as a `:scroller` item (`Layout.layout/5` with `scrollers:
  true`) and tags what is inside it with `sc` (the scrollers it is in, innermost first) and
  `clips` (every clip it got, `{rect, k, scroller}`, where `k` is how many scrollers the item was
  in when that clip was made). Scrolling needs no new layout: `apply/3` moves the items of a
  scroller by its offset, and its clips with them, except the clips of the boxes that
  lie outside it.

  `soff` is the scroll offset of each scroller by id: `%{id => {x, y}}` (what is not in it is
  not scrolled).
  """

  alias Browser.Layout

  @drawn ~w(text rect image svg hr bgimage)a

  @doc """
  Splits the `:scroller` items out of a layout's `items`: `{items, scrollers}`, where
  `scrollers` is `%{id => %{x, y, w, h, ov, outer, clips, max_x, max_y}}`: the padding box of
  the scroller (as laid out), which axes scroll, the scrollers around it, the clips it is
  under, and how far its content reaches past it.
  """
  def index(items) do
    case Enum.split_with(items, &(&1.type == :scroller)) do
      {[], rest} ->
        {rest, %{}}

      {scrollers, rest} ->
        extents = extents(rest)

        map =
          Map.new(scrollers, fn s ->
            {ex, ey} = Map.get(extents, s.sid, {0, 0})
            {xk, yk} = s.ov

            {s.sid,
             %{
               x: s.x,
               y: s.y,
               w: s.w,
               h: s.h,
               ov: s.ov,
               outer: Map.get(s, :sc, []),
               clips: Map.get(s, :clips, []),
               max_x: if(xk, do: max(ex + s.pr - (s.x + s.w), 0), else: 0),
               max_y: if(yk, do: max(ey + s.pb - (s.y + s.h), 0), else: 0)
             }}
          end)

        {rest, map}
    end
  end

  # how far right and down what is drawn in each scroller reaches (inside the clips of the
  # boxes in it)
  defp extents(items) do
    Enum.reduce(items, %{}, fn
      %{sc: sc, clips: clips, type: type} = item, acc when type in @drawn ->
        if Map.get(item, :hidden, false) or Map.get(item, :stick) == :fixed do
          acc
        else
          rect = {item.x, item.y, item.x + Map.get(item, :w, 0), item.y + Map.get(item, :h, 0)}

          sc
          |> Enum.with_index()
          |> Enum.reduce(acc, fn {sid, j}, acc ->
            bounded =
              Enum.reduce(clips, rect, fn
                {_, _, ^sid}, r -> r
                {c, k, _}, r when k <= j -> cut(r, c)
                _, r -> r
              end)

            {_, _, x1, y1} = bounded
            Map.update(acc, sid, {x1, y1}, fn {ex, ey} -> {max(ex, x1), max(ey, y1)} end)
          end)
        end

      _, acc ->
        acc
    end)
  end

  defp cut({x0, y0, x1, y1}, c),
    do: {max(x0, c.x), max(y0, c.y), min(x1, c.x + c.w), min(y1, c.y + c.h)}

  @doc "`soff` kept to what the `scrollers` can scroll: unknown ones and zeros are dropped."
  def clamp(scrollers, soff) do
    for {sid, {x, y}} <- soff, s = scrollers[sid], reduce: %{} do
      acc ->
        pos = {x |> max(0) |> min(s.max_x), y |> max(0) |> min(s.max_y)}
        if pos == {0, 0}, do: acc, else: Map.put(acc, sid, pos)
    end
  end

  @doc "The items as they are drawn when the scrollers are at `soff`."
  def apply(items, _scrollers, soff) when soff == %{}, do: items

  def apply(items, _scrollers, soff) do
    Enum.map(items, fn
      %{sc: sc, clips: clips} = item ->
        {dx, dy} = moved(soff, sc)

        cond do
          Map.get(item, :stick) == :fixed -> item
          dx == 0 and dy == 0 -> item
          true -> relocate(item, clips, sc, soff, dx, dy)
        end

      item ->
        item
    end)
  end

  defp relocate(item, clips, sc, soff, dx, dy) do
    clips = shift_clips(clips, sc, soff)
    moved = Layout.shift(item, dx, dy)
    %{moved | clips: clips, clip: merge(clips)}
  end

  # the clips of what is inside a scroller move with it, the clips of the boxes around it do not
  defp shift_clips(clips, sc, soff) do
    for {r, k, sid} <- clips do
      {dx, dy} = moved(soff, Enum.drop(sc, if(sid, do: k + 1, else: k)))
      {%{r | x: r.x + dx, y: r.y + dy}, k, sid}
    end
  end

  defp merge(clips) do
    clips
    |> Enum.map(&elem(&1, 0))
    |> Enum.reduce(fn b, a ->
      x = max(a.x, b.x)
      y = max(a.y, b.y)

      %{
        x: x,
        y: y,
        w: max(min(a.x + a.w, b.x + b.w) - x, 0),
        h: max(min(a.y + a.h, b.y + b.h) - y, 0)
      }
    end)
  end

  # how far what is in all of the scrollers `ids` has moved
  defp moved(soff, ids) do
    Enum.reduce(ids, {0, 0}, fn id, {dx, dy} ->
      {sx, sy} = Map.get(soff, id, {0, 0})
      {dx - sx, dy - sy}
    end)
  end

  @doc """
  Where the scroller shows its content on the page (`%{x, y, w, h}`), with the scrollers at
  `soff`.
  """
  def visible(scrollers, soff, sid) do
    s = Map.fetch!(scrollers, sid)
    {dx, dy} = moved(soff, s.outer)
    rect = %{x: s.x + dx, y: s.y + dy, w: s.w, h: s.h}

    case shift_clips(s.clips, s.outer, soff) do
      [] -> rect
      clips -> merge([{rect, 0, nil} | clips])
    end
  end

  @doc """
  The scrollers at page position `{x, y}`, innermost first (the one under the point, then those
  it is in).
  """
  def at(scrollers, soff, x, y) do
    scrollers
    |> Enum.filter(fn {sid, _} ->
      r = visible(scrollers, soff, sid)
      x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h
    end)
    |> Enum.max_by(fn {_, s} -> length(s.outer) end, fn -> nil end)
    |> case do
      nil -> []
      {sid, s} -> [sid | s.outer]
    end
  end

  @doc "Whether the scroller can scroll `delta` px along `axis` (`:x` or `:y`) from where it is."
  def can_scroll?(scrollers, soff, sid, axis, delta) do
    s = scrollers[sid]
    {sx, sy} = Map.get(soff, sid, {0, 0})

    {kind, pos, max} =
      case axis do
        :x -> {elem(s.ov, 0), sx, s.max_x}
        :y -> {elem(s.ov, 1), sy, s.max_y}
      end

    kind != nil and ((delta < 0 and pos > 0) or (delta > 0 and pos < max))
  end
end
