defmodule Browser.Style do
  @moduledoc """
  Stylesheet collection, cascade and pruning.

  Only the properties in `@props` are cascaded for now (`display`); adding a
  property here makes `declared/2` compute it too. `prune/2` removes elements
  whose computed `display` is `none` before layout.
  """

  alias Browser.CSS

  @props ~w(display)

  @ua_css """
  [hidden], input[type=hidden], area, base, datalist, noembed, param, rp, template { display: none }
  """

  def ua_css, do: @ua_css

  # -- finding stylesheets -------------------------------------------------------

  @doc "Stylesheet references in document order: `{:style, css}` or `{:link, href}`."
  def sheet_refs(nodes), do: nodes |> refs([]) |> Enum.reverse()

  defp refs(nodes, acc), do: Enum.reduce(nodes, acc, &ref/2)

  defp ref({:text, _}, acc), do: acc

  defp ref({:element, "style", attrs, kids}, acc) do
    if media_ok?(attrs) do
      css = for {:text, t} <- kids, into: "", do: t
      [{:style, css} | acc]
    else
      acc
    end
  end

  defp ref({:element, "link", attrs, _}, acc) do
    rel = attrs |> attr("rel") |> String.downcase() |> String.split()
    href = attr(attrs, "href")

    if "stylesheet" in rel and "alternate" not in rel and href != "" and
         not List.keymember?(attrs, "disabled", 0) and media_ok?(attrs),
       do: [{:link, href} | acc],
       else: acc
  end

  defp ref({:element, _, _, kids}, acc), do: refs(kids, acc)

  defp media_ok?(attrs) do
    case attr(attrs, "media") |> String.downcase() |> String.trim() do
      "" -> true
      media -> String.contains?(media, ["all", "screen"])
    end
  end

  defp attr(attrs, name), do: List.keyfind(attrs, name, 0, {nil, ""}) |> elem(1)

  # -- rule index ----------------------------------------------------------------

  @doc """
  Builds a rule index from `[{origin, css}]` in cascade order, where origin is
  `:ua` or `:author`.
  """
  def index(sheets) do
    sheets
    |> Enum.flat_map(fn {origin, css} ->
      for rule <- CSS.parse(css),
          decls = Enum.filter(rule.decls, fn {p, _, _} -> p in @props end),
          decls != [],
          do: %{rule | decls: decls} |> Map.put(:origin, origin)
    end)
    |> Enum.with_index()
    |> Enum.reduce(%{}, fn {rule, order}, idx ->
      Map.update(idx, key(rule), [Map.put(rule, :order, order)], &[Map.put(rule, :order, order) | &1])
    end)
  end

  # bucket by the rightmost compound so lookups only test plausible rules
  defp key(%{selector: [{cmp, _} | _]}) do
    cond do
      cmp.id -> {:id, cmp.id}
      cmp.classes != [] -> {:class, hd(cmp.classes)}
      is_binary(cmp.tag) -> {:tag, cmp.tag}
      true -> :other
    end
  end

  # -- cascade -------------------------------------------------------------------

  @doc "Declared (cascaded) values for the element `ctx`: `%{property => value}`."
  def declared(idx, ctx) do
    candidates =
      Map.get(idx, {:tag, ctx.tag}, []) ++
        Map.get(idx, :other, []) ++
        if(ctx.id, do: Map.get(idx, {:id, ctx.id}, []), else: []) ++
        Enum.flat_map(ctx.classes, &Map.get(idx, {:class, &1}, []))

    from_rules =
      for rule <- candidates,
          CSS.matches?(rule.selector, ctx),
          {prop, value, important?} <- rule.decls do
        {prop, {rank(rule.origin, important?), {0, rule.specificity}, rule.order}, value}
      end

    from_inline =
      for {prop, value, important?} <- inline_decls(ctx.attrs) do
        {prop, {rank(:author, important?), {1, {0, 0, 0}}, 0}, value}
      end

    (from_rules ++ from_inline)
    |> Enum.reduce(%{}, fn {prop, k, v}, acc ->
      case acc do
        %{^prop => {k0, _}} when k0 > k -> acc
        _ -> Map.put(acc, prop, {k, v})
      end
    end)
    |> Map.new(fn {prop, {_k, v}} -> {prop, v} end)
  end

  defp inline_decls(attrs) do
    case List.keyfind(attrs, "style", 0) do
      {_, css} -> Enum.filter(CSS.parse_declarations(css), fn {p, _, _} -> p in @props end)
      nil -> []
    end
  end

  # important declarations reverse the origin order (UA !important wins overall)
  defp rank(:ua, false), do: 0
  defp rank(:author, false), do: 1
  defp rank(:author, true), do: 2
  defp rank(:ua, true), do: 3

  # -- pruning -------------------------------------------------------------------

  @doc "Removes every element whose computed `display` is `none` (with its subtree)."
  def prune(nodes, idx), do: prune_children(nodes, nil, idx)

  defp prune_children(nodes, parent, idx) do
    count = Enum.count(nodes, &match?({:element, _, _, _}, &1))

    {out, _} =
      Enum.reduce(nodes, {[], {0, []}}, fn
        {:text, _} = t, {acc, state} ->
          {[t | acc], state}

        {:element, tag, attrs, kids}, {acc, {i, prev}} ->
          ctx = context(tag, attrs, parent, prev, i, count)

          acc =
            if hidden?(idx, ctx),
              do: acc,
              else: [{:element, tag, attrs, prune_children(kids, ctx, idx)} | acc]

          {acc, {i + 1, [ctx | prev]}}
      end)

    Enum.reverse(out)
  end

  defp hidden?(idx, ctx) do
    case declared(idx, ctx) do
      %{"display" => display} -> display |> String.downcase() |> String.trim() == "none"
      _ -> false
    end
  end

  defp context(tag, attrs, parent, prev, i, count) do
    %{
      tag: tag,
      attrs: attrs,
      id: case(List.keyfind(attrs, "id", 0), do: ({_, v} -> v; nil -> nil)),
      classes: attrs |> attr("class") |> String.split(),
      parent: parent,
      prev: prev,
      first?: i == 0,
      last?: i == count - 1
    }
  end
end
