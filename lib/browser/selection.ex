defmodule Browser.Selection do
  @moduledoc """
  Selecting and copying page text. Everything here works on laid out items, so it needs
  no window.

  `texts/1` gives the selectable text items in reading order (line by line, left to
  right). A *position* is `{index, offset}`: a character offset into the text of the
  `index`th of those items. A selection is `{from, to}` with `from <= to`.

    * `point_at/4` finds the position under a point of the page
    * `rects/3` the highlight rectangles of a selection
    * `text/2` the text it copies
    * `word_at/2` and `all/1` give the selection of a word and of the whole page
  """

  # the box of a text item is as tall as the caret in a text field
  @line_factor 1.25

  @doc "The selectable text items of `items` in reading order (form control text is left out)."
  def texts(items) do
    items
    |> Enum.filter(
      &(&1.type == :text and Map.get(&1, :cid) == nil and not Map.get(&1, :hidden, false))
    )
    |> Enum.sort_by(&{&1.y, &1.x})
    |> Enum.map(&{&1, nil})
    |> group_lines()
    |> Enum.flat_map(fn {_span, entries} ->
      entries |> Enum.sort_by(fn {item, _} -> item.x end) |> Enum.map(&elem(&1, 0))
    end)
  end

  # Groups `{item, extra}` entries sorted by y into lines `{{top, bottom}, entries}`: an item
  # belongs to the line when the middle of its box lies inside the line's vertical extent
  # (words of different sizes share a line).
  defp group_lines(entries) do
    {done, current} =
      Enum.reduce(entries, {[], nil}, fn {item, _} = entry, {done, cur} ->
        mid = item.y + height(item) / 2
        span = {item.y, item.y + height(item)}

        case cur do
          {{top, bottom}, members} when mid >= top and mid < bottom ->
            {done, {{min(top, item.y), max(bottom, elem(span, 1))}, [entry | members]}}

          {line_span, members} ->
            {[{line_span, Enum.reverse(members)} | done], {span, [entry]}}

          nil ->
            {done, {span, [entry]}}
        end
      end)

    case current do
      nil -> []
      {span, members} -> Enum.reverse([{span, Enum.reverse(members)} | done])
    end
  end

  defp height(item), do: item.h * @line_factor

  # -- positions ---------------------------------------------------------------------

  @doc """
  The position nearest to page point `{x, y}`: in the line under `y` (the first or last
  line when `y` is above or below the text), at the character boundary nearest to `x`.
  `measure` is the `(text, style) -> width` function.
  """
  def point_at(texts, x, y, measure)
  def point_at([], _x, _y, _measure), do: nil

  def point_at(texts, x, y, measure) do
    indexed = Enum.with_index(texts)
    line = line_for(indexed, y)
    {item, index} = item_for(line, x)
    {index, offset_at(item, x, measure)}
  end

  # the items (with their index) of the line `y` falls in, else of the nearest line;
  # sorted by x
  defp line_for(indexed, y) do
    lines = group_lines(indexed)

    {_span, entries} =
      Enum.find(lines, fn {{top, bottom}, _} -> y >= top and y < bottom end) ||
        Enum.min_by(lines, fn {{top, bottom}, _} -> if y < top, do: top - y, else: y - bottom end)

    Enum.sort_by(entries, fn {item, _} -> item.x end)
  end

  # the item of a line (sorted by x) that `x` belongs to: the one containing it, else the
  # nearer neighbour of the gap, else the first or last
  defp item_for(entries, x) do
    case Enum.find(entries, fn {item, _} -> x >= item.x and x <= item.x + item.w end) do
      nil ->
        {first, _} = hd(entries)
        {last, _} = List.last(entries)

        cond do
          x < first.x ->
            hd(entries)

          x > last.x + last.w ->
            List.last(entries)

          true ->
            entries
            |> Enum.chunk_every(2, 1, :discard)
            |> Enum.find_value(fn [{a, _} = ea, {b, _} = eb] ->
              if x > a.x + a.w and x < b.x,
                do: if(x - (a.x + a.w) <= b.x - x, do: ea, else: eb)
            end)
        end

      entry ->
        entry
    end
  end

  # the character boundary of the item's text nearest to x
  defp offset_at(item, x, measure) do
    chars = String.graphemes(item.text)

    cond do
      x <= item.x ->
        0

      x >= item.x + item.w ->
        length(chars)

      true ->
        {best, _} =
          0..length(chars)
          |> Enum.map(fn k -> {k, abs(x - (item.x + width(item, chars, k, measure)))} end)
          |> Enum.min_by(&elem(&1, 1))

        best
    end
  end

  defp width(_item, _chars, 0, _measure), do: 0
  defp width(item, chars, k, measure), do: measure.(chars |> Enum.take(k) |> Enum.join(), item)

  # -- selections --------------------------------------------------------------------

  @doc "Orders two positions: `{from, to}`, or nil when they are the same."
  def range(a, b) when a == b, do: nil
  def range(a, b), do: if(a <= b, do: {a, b}, else: {b, a})

  @doc "Whether page point `{x, y}` is on visible selectable text (inside any box that clips it)."
  def over_text?(texts, x, y) do
    Enum.any?(texts, fn item ->
      x >= item.x and x < item.x + item.w and y >= item.y and y < item.y + height(item) and
        visible_at?(item, x, y)
    end)
  end

  defp visible_at?(%{clip: %{x: cx, y: cy, w: cw, h: ch}}, x, y),
    do: x >= cx and x < cx + cw and y >= cy and y < cy + ch

  defp visible_at?(_item, _x, _y), do: true

  @doc "The selection of everything."
  def all([]), do: nil

  def all(texts) do
    last = length(texts) - 1
    {{0, 0}, {last, String.length(Enum.at(texts, last).text)}}
  end

  @doc "The selection of the word (run of non-space characters) at `position`, or nil."
  def word_at(texts, {index, offset}) do
    chars = texts |> Enum.at(index) |> Map.fetch!(:text) |> String.graphemes()
    space? = fn c -> String.trim(c) == "" end

    # a position on a boundary belongs to the character after it, else the one before
    at =
      if offset < length(chars) and not space?.(Enum.at(chars, offset)),
        do: offset,
        else: offset - 1

    if at < 0 or at >= length(chars) or space?.(Enum.at(chars, at)) do
      nil
    else
      from =
        chars
        |> Enum.take(at)
        |> Enum.reverse()
        |> Enum.take_while(&(not space?.(&1)))
        |> length()

      to = chars |> Enum.drop(at) |> Enum.take_while(&(not space?.(&1))) |> length()
      {{index, at - from}, {index, at + to}}
    end
  end

  @doc """
  The selection of the paragraph at `position`: the lines around it up to the blank space
  that `text/2` would copy as a paragraph break.
  """
  def paragraph_at(texts, {index, _offset}) do
    t = List.to_tuple(texts)
    last = tuple_size(t) - 1
    first_i = walk(t, index, -1, last)
    last_i = walk(t, index, 1, last)
    {{first_i, 0}, {last_i, String.length(elem(t, last_i).text)}}
  end

  # the index of the paragraph's first (step -1) or last (step 1) item
  defp walk(t, i, step, last) do
    next = i + step

    cond do
      next < 0 or next > last -> i
      paragraph_break?(elem(t, min(i, next)), elem(t, max(i, next))) -> i
      true -> walk(t, next, step, last)
    end
  end

  defp paragraph_break?(prev, item), do: separator(prev, item) == "\n\n"

  # -- output --------------------------------------------------------------------------

  @doc """
  Highlight rectangles `%{x, y, w, h}` (and the item's `clip`, when it has one) covering
  the selection. The gap between two selected items on one line is covered as well.
  """
  def rects(_texts, nil, _measure), do: []

  def rects(texts, {{from_i, from_o}, {to_i, to_o}}, measure) do
    texts = List.to_tuple(texts)

    for i <- from_i..to_i//1,
        item = elem(texts, i),
        chars = String.graphemes(item.text),
        s = if(i == from_i, do: from_o, else: 0),
        e = if(i == to_i, do: to_o, else: length(chars)),
        e > s do
      x0 = item.x + width(item, chars, s, measure)

      x1 =
        cond do
          e < length(chars) ->
            item.x + width(item, chars, e, measure)

          # up to the next selected item of the same line
          i < to_i and same_line?(item, elem(texts, i + 1)) ->
            max(elem(texts, i + 1).x, item.x + item.w)

          true ->
            item.x + item.w
        end

      rect = %{
        type: :selection,
        x: round(x0),
        y: item.y,
        w: max(round(x1 - x0), 1),
        h: round(height(item))
      }

      if clip = Map.get(item, :clip), do: Map.put(rect, :clip, clip), else: rect
    end
  end

  defp same_line?(a, b) do
    mid = b.y + height(b) / 2
    mid >= a.y and mid < a.y + height(a)
  end

  @doc "The text a selection copies: words as laid out, one line break per line, a blank line between paragraphs."
  def text(_texts, nil), do: ""

  def text(texts, {{from_i, from_o}, {to_i, to_o}}) do
    texts = List.to_tuple(texts)

    pieces =
      for i <- from_i..to_i//1, item = elem(texts, i) do
        chars = String.graphemes(item.text)
        s = if i == from_i, do: from_o, else: 0
        e = if i == to_i, do: to_o, else: length(chars)
        {item, chars |> Enum.slice(s, max(e - s, 0)) |> Enum.join()}
      end

    pieces
    |> Enum.reject(fn {_, t} -> t == "" end)
    |> Enum.reduce({"", nil}, fn {item, t}, {acc, prev} ->
      {acc <> separator(prev, item) <> t, item}
    end)
    |> elem(0)
    |> String.trim()
  end

  defp separator(nil, _item), do: ""

  defp separator(prev, item) do
    cond do
      same_line?(prev, item) ->
        if item.x - (prev.x + prev.w) > 1.5, do: " ", else: ""

      item.y - (prev.y + height(prev)) > prev.h * 0.5 ->
        "\n\n"

      true ->
        "\n"
    end
  end
end
