defmodule Browser.Container do
  @moduledoc """
  `@container` queries.

  An element with `container-type: size | inline-size` is a query container. A rule in an
  `@container (min-width: 400px)` block applies to the elements below the nearest container (or
  the nearest one with the given name) while the size of that container fits the query.

  The size of a container is known only when the page is laid out, so a page with such rules is
  styled and laid out, the sizes of its containers are read from the layout, and when they
  differ from the sizes the style used, the page is styled again with them (see
  `Browser.Page.settle/3`). The sizes are in the process dictionary under
  `:style_container_sizes` (`%{nid => {width, height}}`, the content boxes) while the cascade
  runs.
  """

  alias Browser.{MediaQuery, Style}

  @doc "Do all the `{name, query}` of `cq` hold for the element of `ctx`?"
  def match?(cq, ctx) do
    sizes = Process.get(:style_container_sizes, %{})
    Enum.all?(cq, fn {name, query} -> holds?(find(Map.get(ctx, :parent), name), query, sizes) end)
  end

  defp find(nil, _name), do: nil

  defp find(ancestor, name) do
    c = Map.get(ancestor, :computed) || %{}

    if c["container-type"] in ["size", "inline-size"] and named?(c["container-name"], name),
      do: ancestor,
      else: find(Map.get(ancestor, :parent), name)
  end

  defp named?(_names, nil), do: true
  defp named?(names, name) when is_binary(names), do: name in String.split(names)
  defp named?(_names, _name), do: false

  defp holds?(nil, _query, _sizes), do: false

  defp holds?(container, query, sizes) do
    with {_, nid} when is_integer(nid) <- List.keyfind(container.attrs, "@nid", 0),
         %{^nid => {w, h}} <- sizes do
      env = %{Style.default_env() | width: w, height: h}
      MediaQuery.eval(parse(query), env)
    else
      _ -> false
    end
  end

  # (`inline-size` and `block-size` are the width and the height of a horizontal page)
  defp parse(query) do
    key = {:style_container_query, query}

    case Process.get(key) do
      nil ->
        parsed =
          query
          |> String.replace("inline-size", "width")
          |> String.replace("block-size", "height")
          |> MediaQuery.parse()

        Process.put(key, parsed)
        parsed

      parsed ->
        parsed
    end
  end

  @doc """
  The content size of the container that an element whose parent is `parent` is in, as
  `{width, height, container_type}`, or nil when there is none or its size is not known yet.
  """
  def box(parent) do
    with %{} = container <- find(parent, nil),
         {_, nid} when is_integer(nid) <- List.keyfind(container.attrs, "@nid", 0),
         %{^nid => {w, h}} <- Process.get(:style_container_sizes, %{}) do
      {w, h, container.computed["container-type"]}
    else
      _ -> nil
    end
  end

  @doc """
  The sizes of the containers in a styled tree from its laid out `items` (which have `:bounds`
  items when laid out with `boxes: true`): `%{nid => {width, height}}` of the content boxes.
  """
  def sizes(nodes, items) do
    containers = containers(nodes, %{})

    if containers == %{} do
      %{}
    else
      for %{type: :bounds, nid: nid, w: w, h: h} <- items,
          c = containers[nid],
          into: %{} do
        {nid, content_box(c, w, h)}
      end
    end
  end

  defp containers(nodes, acc) when is_list(nodes), do: Enum.reduce(nodes, acc, &containers/2)
  defp containers({:text, _}, acc), do: acc

  defp containers({:element, _tag, attrs, kids}, acc) do
    acc =
      with {_, nid} when is_integer(nid) <- List.keyfind(attrs, "@nid", 0),
           {_, %{"container-type" => type} = c} when type in ["size", "inline-size"] <-
             List.keyfind(attrs, "@computed", 0) do
        Map.put(acc, nid, c)
      else
        _ -> acc
      end

    containers(kids, acc)
  end

  defp containers(_other, acc), do: acc

  defp content_box(c, w, h) do
    insets_w = side(c, "left") + side(c, "right")
    insets_h = side(c, "top") + side(c, "bottom")
    {max(w - insets_w, 0), max(h - insets_h, 0)}
  end

  defp side(c, edge) do
    num(c["padding-" <> edge]) + num(c["border-#{edge}-width"])
  end

  defp num(v) when is_number(v), do: v
  defp num(_), do: 0
end
