defmodule Browser.Nids do
  @moduledoc """
  Gives every element of a page a number (the `"@nid"` attribute) that the scripts' document and
  the layout share: the layout reports where each numbered element ended up, and scripts ask for
  it by number (`getBoundingClientRect` and friends).

  The first indexing numbers the elements in document order; later trees come from the scripts,
  which keep the numbers they have and number what they add.
  """

  @doc "Numbers the elements that have no number yet."
  def index(raw) do
    {raw, _} = number(raw, max_nid(raw, -1) + 1)
    raw
  end

  defp number(nodes, n) when is_list(nodes), do: Enum.map_reduce(nodes, n, &number/2)
  defp number({:text, _} = t, n), do: {t, n}

  defp number({:element, tag, attrs, kids}, n) do
    {attrs, n} =
      case List.keyfind(attrs, "@nid", 0) do
        nil -> {attrs ++ [{"@nid", n}], n + 1}
        _ -> {attrs, n}
      end

    {kids, n} = number(kids, n)
    {{:element, tag, attrs, kids}, n}
  end

  @doc "The largest number in use, or `none`."
  def max_nid(nodes, none) when is_list(nodes),
    do: Enum.reduce(nodes, none, &max(max_nid(&1, none), &2))

  def max_nid({:text, _}, none), do: none

  def max_nid({:element, _tag, attrs, kids}, none) do
    own =
      case List.keyfind(attrs, "@nid", 0) do
        {_, n} when is_integer(n) -> n
        _ -> none
      end

    max(own, max_nid(kids, none))
  end

  @doc "`%{nid => parent nid}` for the numbered elements of a (styled) tree."
  def parents(nodes), do: parents(nodes, nil, %{})

  defp parents(nodes, parent, acc) when is_list(nodes),
    do: Enum.reduce(nodes, acc, &parents(&1, parent, &2))

  defp parents({:text, _}, _parent, acc), do: acc

  defp parents({:element, _tag, attrs, kids}, parent, acc) do
    case List.keyfind(attrs, "@nid", 0) do
      {_, nid} -> parents(kids, nid, Map.put(acc, nid, parent))
      nil -> parents(kids, parent, acc)
    end
  end

  @doc """
  `%{nid => {x, y, w, h}}`: the box around everything drawn for an element and its
  descendants, from the laid out `items` (the ones tagged with the number of the element
  they belong to).
  """
  def rects(items, parents) do
    items
    |> Enum.reduce(%{}, fn
      %{nid: nid, x: x, y: y, w: w, h: h} = item, acc when is_integer(nid) and is_number(w) ->
        full = {x, y, x + w, y + h}
        grow(acc, nid, parents, full, visible(full, Map.get(item, :clip)))

      _, acc ->
        acc
    end)
    |> Map.new(fn {nid, {x0, y0, x1, y1}} -> {nid, {x0, y0, x1 - x0, y1 - y0}} end)
  end

  # the part of a box that the clip of its ancestors leaves (nil: none of it)
  defp visible(box, nil), do: box

  defp visible({x0, y0, x1, y1}, %{x: cx, y: cy, w: cw, h: ch}) do
    {a, b, c, d} = {max(x0, cx), max(y0, cy), min(x1, cx + cw), min(y1, cy + ch)}
    if c > a and d > b, do: {a, b, c, d}
  end

  defp visible(box, _), do: box

  defp grow(acc, nil, _parents, _full, _visible), do: acc

  defp grow(acc, nid, parents, full, visible) do
    # (what a box with `overflow: hidden` clips does not widen `html` and `body`: they are as
    # wide as the inside of the clips, whatever a slider of 10000 px holds)
    parent = Map.get(parents, nid)
    root? = parent == nil or Map.get(parents, parent) == nil
    box = if root?, do: visible, else: full

    acc =
      case {box, acc} do
        {nil, _} ->
          acc

        {{x0, y0, x1, y1}, %{^nid => {a, b, c, d}}} ->
          Map.put(acc, nid, {min(a, x0), min(b, y0), max(c, x1), max(d, y1)})

        {b, _} ->
          Map.put(acc, nid, b)
      end

    grow(acc, parent, parents, full, visible)
  end

  @doc """
  The top of the element a `#fragment` names (the element with that `id`, or an `<a>` with that
  `name`), in page coordinates, or nil when there is none. An element nothing was drawn for
  takes the top of the next one that was.
  """
  def anchor_y(pruned, rects, fragment) do
    order = preorder(pruned, [])

    order =
      Enum.drop_while(order, fn {_nid, id, name, tag, _} ->
        not anchor?(fragment, id, name, tag)
      end)

    Enum.find_value(order, fn {nid, _, _, _, margin} ->
      case rects do
        # `scroll-margin-top` of the element and `scroll-padding-top` of the page keep it clear of
        # a fixed header
        %{^nid => {_x, y, _w, _h}} -> max(y - margin - root_padding(pruned), 0)
        _ -> nil
      end
    end)
  end

  defp root_padding(pruned) do
    case Enum.find(pruned, &match?({:element, "html", _, _}, &1)) do
      {:element, _, attrs, _} -> length_of(attrs, "scroll-padding-top")
      nil -> 0
    end
  end

  defp length_of(attrs, prop) do
    with {_, computed} when is_map(computed) <- List.keyfind(attrs, "@computed", 0),
         n when is_number(n) <- Map.get(computed, prop) do
      n
    else
      _ -> 0
    end
  end

  defp anchor?(fragment, id, name, tag), do: id == fragment or (tag == "a" and name == fragment)

  defp preorder(nodes, acc) do
    nodes |> collect([]) |> Enum.reverse() |> Kernel.++(acc)
  end

  # numbered elements in document order, newest first
  defp collect(nodes, rev) when is_list(nodes), do: Enum.reduce(nodes, rev, &collect/2)
  defp collect({:text, _}, rev), do: rev

  defp collect({:element, tag, attrs, kids}, rev) do
    rev =
      case List.keyfind(attrs, "@nid", 0) do
        {_, nid} ->
          [
            {nid, attr(attrs, "id"), attr(attrs, "name"), tag,
             length_of(attrs, "scroll-margin-top")}
            | rev
          ]

        nil ->
          rev
      end

    collect(kids, rev)
  end

  defp attr(attrs, name) do
    case List.keyfind(attrs, name, 0) do
      {_, v} -> v
      nil -> nil
    end
  end
end
