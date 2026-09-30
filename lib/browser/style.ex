defmodule Browser.Style do
  @moduledoc """
  Stylesheet collection, cascade and pruning.

  Only the properties in `@props` are cascaded; adding one makes `declared/2`
  compute it. `prune/2` removes elements that are not rendered (`display:none`,
  or clipped to zero height) and attaches each remaining element's computed
  style to its attributes under the reserved key `"@computed"` (a map of
  property => value) for layout to read.
  """

  alias Browser.{CSS, MediaQuery}

  @props ~w(display visibility height max-height overflow-x overflow-y)
  @inherited ~w(visibility)
  @clips ~w(hidden clip scroll auto)

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

  @default_env %{type: "screen", width: 1024, height: 768, dppx: 1.0}

  def default_env, do: @default_env

  @doc "Parses `[{origin, css}]` (origin `:ua` or `:author`, in cascade order) into rules."
  def parse_sheets(sheets) do
    Enum.flat_map(sheets, fn {origin, css} ->
      for rule <- CSS.parse(css),
          decls = relevant(rule.decls),
          decls != [],
          do: %{rule | decls: decls} |> Map.put(:origin, origin)
    end)
  end

  @doc "The distinct media query lists used by `rules`."
  def media_queries(rules), do: rules |> Enum.flat_map(& &1.media) |> Enum.uniq()

  @doc "Media query results for `env`; changes exactly when the active rule set would."
  def media_key(queries, env), do: Enum.map(queries, &MediaQuery.eval(&1, env))

  @doc "Builds a rule index, keeping only rules whose media conditions hold in `env`."
  def index_rules(rules, env) do
    rules
    |> Enum.filter(fn rule -> Enum.all?(rule.media, &MediaQuery.eval(&1, env)) end)
    |> Enum.with_index()
    |> Enum.reduce(%{}, fn {rule, order}, idx ->
      rule = Map.put(rule, :order, order)
      Map.update(idx, key(rule), [rule], &[rule | &1])
    end)
  end

  @doc "Convenience: `parse_sheets/1` followed by `index_rules/2`."
  def index(sheets, env \\ @default_env), do: sheets |> parse_sheets() |> index_rules(env)

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

  defp relevant(decls) do
    decls |> Enum.flat_map(&expand/1) |> Enum.filter(fn {p, _, _} -> p in @props end)
  end

  defp expand({"overflow", value, imp}) do
    case String.split(value) do
      [a] -> [{"overflow-x", a, imp}, {"overflow-y", a, imp}]
      [a, b] -> [{"overflow-x", a, imp}, {"overflow-y", b, imp}]
      _ -> []
    end
  end

  defp expand(decl), do: [decl]

  defp inline_decls(attrs) do
    case List.keyfind(attrs, "style", 0) do
      {_, css} -> css |> CSS.parse_declarations() |> relevant()
      nil -> []
    end
  end

  # important declarations reverse the origin order (UA !important wins overall)
  defp rank(:ua, false), do: 0
  defp rank(:author, false), do: 1
  defp rank(:author, true), do: 2
  defp rank(:ua, true), do: 3

  # -- pruning -------------------------------------------------------------------

  @doc """
  Removes elements that are not rendered, with their subtrees, and attaches
  computed styles (see moduledoc).
  """
  def prune(nodes, idx), do: prune_children(nodes, nil, idx)

  defp prune_children(nodes, parent, idx) do
    count = Enum.count(nodes, &match?({:element, _, _, _}, &1))

    {out, _} =
      Enum.reduce(nodes, {[], {0, []}}, fn
        {:text, _} = t, {acc, state} ->
          {[t | acc], state}

        {:element, tag, attrs, kids}, {acc, {i, prev}} ->
          ctx = context(tag, attrs, parent, prev, i, count)
          computed = compute(idx, ctx, parent)
          ctx = Map.put(ctx, :computed, computed)

          acc =
            if not_rendered?(computed) do
              acc
            else
              attrs = if computed == %{}, do: attrs, else: [{"@computed", computed} | attrs]
              [{:element, tag, attrs, prune_children(kids, ctx, idx)} | acc]
            end

          {acc, {i + 1, [ctx | prev]}}
      end)

    Enum.reverse(out)
  end

  defp compute(idx, ctx, parent) do
    inherited =
      case parent do
        %{computed: c} -> Map.take(c, @inherited)
        nil -> %{}
      end

    declared =
      idx
      |> declared(ctx)
      |> Map.new(fn {k, v} -> {k, normalize(v)} end)
      |> resolve_keywords(inherited)

    Map.merge(inherited, declared)
  end

  defp normalize(v), do: v |> String.trim() |> String.downcase()

  # `inherit` takes the parent's value; `initial`/`unset` drop the declaration
  defp resolve_keywords(declared, inherited) do
    Enum.reduce(declared, %{}, fn
      {k, "inherit"}, acc -> if(v = inherited[k], do: Map.put(acc, k, v), else: acc)
      {_k, v}, acc when v in ["initial", "unset", "revert"] -> acc
      {k, v}, acc -> Map.put(acc, k, v)
    end)
  end

  defp not_rendered?(c), do: c["display"] == "none" or collapsed?(c)

  # a clipping box with zero height shows none of its content
  defp collapsed?(c) do
    (Map.get(c, "overflow-x", "visible") in @clips or Map.get(c, "overflow-y", "visible") in @clips) and
      (zero?(c["height"]) or zero?(c["max-height"]))
  end

  defp zero?(nil), do: false

  defp zero?(v),
    do: Regex.match?(~r/\A\+?(0+\.?0*|\.0+)(px|em|rem|%|pt|vh|vw|ch|ex|cm|mm|in)?\z/, v)

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
