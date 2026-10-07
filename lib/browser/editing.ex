defmodule Browser.Editing do
  @moduledoc """
  Editable regions (`contenteditable`) on the screen side: where the caret is, what is
  highlighted, and which place in the text a click is.

  The document's text and line breaks inside an editing host are numbered for the layout (see
  `Browser.JS.DOM`): every text node is an `@t` element with its own `@nid`, and every `<br>` has
  a zero-width stand-in. So the laid out text items say which text node they belong to
  (`item.nid`), and a position in the document is a text node number and an offset into its
  text (in code points of the raw text, white space and all). The editing script reports the
  selection that way (`Browser.JS.Runtime` replies carry it as `sel`).

  `index/1` reads the styled tree once; the other functions work on the laid out `items`.
  """

  alias Browser.Selection

  @doc """
  What the styled tree says about editing: `%{hosts: [nid], order: %{host => [text nid]}, text:
  %{text nid => raw text}, host_of: %{text nid => host}, stand_in: %{br nid => text nid}}`.
  """
  def index(tree) do
    acc = %{hosts: [], order: %{}, text: %{}, host_of: %{}, stand_in: %{}}
    acc = walk(tree, acc)

    %{
      acc
      | hosts: Enum.reverse(acc.hosts),
        order: Map.new(acc.order, fn {h, l} -> {h, Enum.reverse(l)} end)
    }
  end

  defp walk(nodes, acc) when is_list(nodes), do: Enum.reduce(nodes, acc, &walk/2)
  defp walk({:text, _}, acc), do: acc

  defp walk({:element, "@t", attrs, kids}, acc) do
    with {_, nid} <- List.keyfind(attrs, "@nid", 0),
         {_, host} <- List.keyfind(attrs, "@ed", 0) do
      text = for {:text, t} <- kids, into: "", do: t

      acc = %{
        acc
        | text: Map.put(acc.text, nid, text),
          host_of: Map.put(acc.host_of, nid, host),
          order: Map.update(acc.order, host, [nid], &[nid | &1])
      }

      case List.keyfind(attrs, "@z", 0) do
        {_, br} -> %{acc | stand_in: Map.put(acc.stand_in, br, nid)}
        nil -> acc
      end
    else
      _ -> acc
    end
  end

  defp walk({:element, _tag, attrs, kids}, acc) do
    acc =
      case {List.keyfind(attrs, "@edhost", 0), List.keyfind(attrs, "@nid", 0)} do
        {{_, _}, {_, nid}} -> %{acc | hosts: [nid | acc.hosts]}
        _ -> acc
      end

    walk(kids, acc)
  end

  @doc "The editing host a text node (or a line break's number) belongs to, or nil."
  def host_of(index, nid),
    do: Map.get(index.host_of, nid) || Map.get(index.host_of, index.stand_in[nid])

  # -- raw text and items ----------------------------------------------------------

  @doc """
  Where each laid out item of a text node starts and ends in the node's raw text:
  `[{item, from, to}]` in reading order, offsets in code points. White space the layout
  collapsed lies between the items.
  """
  def segments(text, items) do
    chars = String.to_charlist(text)
    items = Enum.sort_by(items, &{&1.y, &1.x})

    {segs, _} =
      Enum.map_reduce(items, {chars, 0}, fn item, {rest, cursor} ->
        want = String.to_charlist(item.text)
        {rest, cursor} = skip_white(rest, cursor, want)
        n = length(want)
        {{item, cursor, cursor + n}, {Enum.drop(rest, n), cursor + n}}
      end)

    segs
  end

  defp skip_white([c | rest], cursor, [w | _] = want)
       when c in [?\s, ?\t, ?\n, ?\r, ?\f] and c != w,
       do: skip_white(rest, cursor + 1, want)

  defp skip_white(rest, cursor, _want), do: {rest, cursor}

  @doc "The items of `items` that belong to text node `nid`."
  def items_of(items, nid),
    do: Enum.filter(items, &(&1.type == :text and Map.get(&1, :nid) == nid))

  @doc """
  Where the caret is for the position `{nid, offset}`: `%{x:, y:, h:, color:}` in page
  coordinates, or nil when the node has nothing drawn. `measure` is the `(text, style) -> width`
  function.
  """
  def caret_rect(index, items, {nid, offset}, measure) do
    nid = Map.get(index.stand_in, nid, nid)

    with text when is_binary(text) <- index.text[nid],
         [_ | _] = segs <- segments(text, items_of(items, nid)) do
      {item, from, _to} =
        Enum.find(segs, List.last(segs), fn {_item, _from, to} -> offset <= to end)

      col = (offset - from) |> max(0) |> min(String.length(item.text))
      prefix = item.text |> String.to_charlist() |> Enum.take(col) |> List.to_string()
      x = item.x + if(prefix == "", do: 0, else: measure.(prefix, item))
      %{x: round(x), y: item.y, h: round(item.h * 1.25), color: item.color}
    else
      _ -> nil
    end
  end

  @doc """
  The caret of an empty host (nothing drawn for it): at the start of its content box, from the
  box `rect` (`{x, y, w, h}`), the border and padding in the host's computed style.
  """
  def empty_caret(tree, host, {x, y, _w, _h}) do
    case find(tree, host) do
      {:element, _tag, attrs, _kids} ->
        c =
          with {_, c} when is_map(c) <- List.keyfind(attrs, "@computed", 0),
               do: c,
               else: (_ -> %{})

        size = num(c["font-size"], 16)
        left = num(c["border-left-width"], 0) + num(c["padding-left"], 0)
        top = num(c["border-top-width"], 0) + num(c["padding-top"], 0)

        %{
          x: round(x + left),
          y: round(y + top),
          h: round(size * 1.25),
          color: c["color"] || {0, 0, 0}
        }

      nil ->
        nil
    end
  end

  defp num(v, _default) when is_number(v), do: v
  defp num(_, default), do: default

  defp find(nodes, nid) when is_list(nodes), do: Enum.find_value(nodes, &find(&1, nid))
  defp find({:text, _}, _nid), do: nil

  defp find({:element, _tag, attrs, kids} = el, nid) do
    case List.keyfind(attrs, "@nid", 0) do
      {_, ^nid} -> el
      _ -> find(kids, nid)
    end
  end

  # -- clicks and highlights -------------------------------------------------------

  @doc "The selectable text items of an editing host in reading order (see `Browser.Selection.texts/1`)."
  def texts(index, items, host) do
    mine = MapSet.new(Map.get(index.order, host, []))

    items
    |> Enum.filter(&(&1.type == :text and MapSet.member?(mine, Map.get(&1, :nid))))
    |> Selection.texts()
  end

  @doc """
  The position `{text nid, offset}` nearest to page point `{x, y}` among the text of `host`, or
  nil when it has none drawn. Stand-ins of line breaks give `{br number, 0}`'s text node.
  """
  def point_at(index, items, host, x, y, measure) do
    case texts(index, items, host) do
      [] ->
        nil

      texts ->
        {i, col} = Selection.point_at(texts, x, y, measure)
        item = Enum.at(texts, i)
        nid = item.nid
        text = index.text[nid] || ""

        from =
          case Enum.find(segments(text, items_of(items, nid)), fn {it, _, _} -> it == item end) do
            {_, from, _} -> from
            nil -> 0
          end

        {nid, from + col}
    end
  end

  @doc """
  The selection of `host` between positions `from` and `to` (`{text nid, offset}`, either order)
  as a range of `Browser.Selection` over `texts(index, items, host)`: `{range, texts}` or nil.
  """
  def selection_range(index, items, host, from, to) do
    texts = texts(index, items, host)
    a = to_text_pos(index, items, texts, from)
    b = to_text_pos(index, items, texts, to)

    if a && b do
      {first, last} = if a <= b, do: {a, b}, else: {b, a}
      if first == last, do: nil, else: {{first, last}, texts}
    end
  end

  # `{index in texts, column}` for a position
  defp to_text_pos(index, items, texts, {nid, offset}) do
    nid = Map.get(index.stand_in, nid, nid)
    text = index.text[nid] || ""
    segs = segments(text, items_of(items, nid))

    with [_ | _] <- segs,
         {item, from, _to} <- Enum.find(segs, List.last(segs), fn {_, _, to} -> offset <= to end),
         i when i != nil <- Enum.find_index(texts, &(&1 == item)) do
      {i, (offset - from) |> max(0) |> min(String.length(item.text))}
    else
      _ -> nil
    end
  end

  @doc """
  The overlay for the editor: the highlight of the selection and the caret.
  `sel` is `%{anchor: {nid, offset}, focus: {nid, offset}, host: nid}`; `rect` is the host's box
  (for the caret of an empty host).
  """
  def overlay(index, tree, items, sel, rect_of, measure) do
    host = sel.host

    case selection_range(index, items, host, sel.anchor, sel.focus) do
      {range, texts} ->
        Selection.rects(texts, range, measure)

      nil ->
        if sel.anchor == sel.focus do
          case caret_rect(index, items, sel.focus, measure) ||
                 (rect_of.(host) && empty_caret(tree, host, rect_of.(host))) do
            nil -> []
            c -> [Map.merge(%{type: :caret, w: 1}, c)]
          end
        else
          []
        end
    end
  end
end
