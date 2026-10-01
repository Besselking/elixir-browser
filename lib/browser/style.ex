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

  @props ~w(display visibility overflow-x overflow-y position top left right bottom
            width height min-height max-height min-width max-width box-sizing clip clip-path
            text-indent opacity margin-right padding-right vertical-align
            border-top-width border-right-width border-bottom-width border-left-width
            border-top-style border-right-style border-bottom-style border-left-style
            border-top-color border-right-color border-bottom-color border-left-color
            color background-color font-size font-weight font-style font-family
            text-decoration-line text-align list-style-type flex-direction
            margin-top margin-bottom margin-left padding-top padding-bottom padding-left)
  @inherited ~w(visibility text-indent color font-size font-weight font-style font-family
                text-decoration-line text-align list-style-type)
  @clips ~w(hidden clip scroll auto)
  @default_fs 16.0

  @shorthands %{
    "margin" => ~w(margin-top margin-right margin-bottom margin-left),
    "padding" => ~w(padding-top padding-right padding-bottom padding-left),
    "overflow" => ~w(overflow-x overflow-y),
    "list-style" => ~w(list-style-type),
    "text-decoration" => ~w(text-decoration-line),
    "font" => ~w(font-style font-weight font-size font-family),
    "background" => ~w(background-color),
    "border-width" =>
      ~w(border-top-width border-right-width border-bottom-width border-left-width),
    "border-style" =>
      ~w(border-top-style border-right-style border-bottom-style border-left-style),
    "border-color" =>
      ~w(border-top-color border-right-color border-bottom-color border-left-color),
    "border-top" => ~w(border-top-width border-top-style border-top-color),
    "border-right" => ~w(border-right-width border-right-style border-right-color),
    "border-bottom" => ~w(border-bottom-width border-bottom-style border-bottom-color),
    "border-left" => ~w(border-left-width border-left-style border-left-color),
    "border" => ~w(border-top-width border-top-style border-top-color
         border-right-width border-right-style border-right-color
         border-bottom-width border-bottom-style border-bottom-color
         border-left-width border-left-style border-left-color)
  }

  @border_styles ~w(none hidden dotted dashed solid double groove ridge inset outset)

  # user-agent defaults; author rules and inline styles override them
  @ua_css """
  [hidden], input[type=hidden], area, base, datalist, noembed, param, rp, template { display: none }
  html { font-size: 16px; color: #000000; font-weight: normal; font-style: normal }
  address, article, aside, blockquote, body, center, details, dialog, dd, div, dl, dt,
  fieldset, figcaption, figure, footer, form, h1, h2, h3, h4, h5, h6, header, hgroup, hr,
  html, legend, main, menu, nav, ol, p, pre, section, summary, ul, table, caption, tr,
  thead, tbody, tfoot { display: block }
  li { display: list-item }
  body { margin: 8px }
  p, dl, pre, figure { margin: 1em 0 }
  ul, ol { margin: 1em 0; padding-left: 40px }
  ul { list-style-type: disc }
  ol { list-style-type: decimal }
  ul ul, ol ul { list-style-type: circle }
  ul ul ul, ol ul ul, ul ol ul, ol ol ul { list-style-type: square }
  ul ul, ul ol, ol ul, ol ol { margin-top: 0; margin-bottom: 0 }
  blockquote { margin: 1em 40px }
  dd { margin-left: 40px }
  hr { margin: 8px 0 }
  h1 { font-size: 2em; margin: .67em 0 }
  h2 { font-size: 1.5em; margin: .83em 0 }
  h3 { font-size: 1.17em; margin: 1em 0 }
  h4 { margin: 1.33em 0 }
  h5 { font-size: .83em; margin: 1.67em 0 }
  h6 { font-size: .67em; margin: 2.33em 0 }
  h1, h2, h3, h4, h5, h6, b, strong, th { font-weight: bold }
  i, em, cite, dfn, var, address { font-style: italic }
  code, kbd, samp, tt, pre { font-family: monospace }
  small, sub, sup { font-size: smaller }
  big { font-size: larger }
  a[href] { color: #0000ee; text-decoration: underline }
  u, ins { text-decoration: underline }
  s, strike, del { text-decoration: line-through }
  center, th { text-align: center }
  button { display: inline-block; padding: 1px 6px; border: 1px solid #767676; background-color: #efefef; text-align: center }
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
    decls
    |> Enum.flat_map(&expand/1)
    |> Enum.filter(fn {p, _, _} -> p in @props or String.starts_with?(p, "--") end)
  end

  # Shorthands become longhands so the cascade can order them against each
  # other. A shorthand whose value uses var() can't be split until the
  # variables are known, so each longhand carries the raw value and is
  # resolved per element: `{:sh, shorthand, raw_value, longhand}`.
  defp expand({prop, value, imp}) when is_map_key(@shorthands, prop) do
    longs = @shorthands[prop]

    if String.contains?(value, "var(") do
      for long <- longs, do: {long, {:sh, prop, value, long}, imp}
    else
      for {long, v} <- split_shorthand(prop, value), do: {long, v, imp}
    end
  end

  defp expand(decl), do: [decl]

  @keywords ~w(inherit initial unset revert)

  defp split_shorthand(prop, value) do
    v = value |> String.trim() |> String.downcase()
    longs = @shorthands[prop]

    if v in @keywords do
      for long <- longs, do: {long, v}
    else
      do_split(prop, v, tokens(v))
    end
  end

  # width/style/color in any order; unspecified parts take their initial values
  defp border_parts(toks) do
    Enum.reduce(toks, {"medium", "none", "currentcolor"}, fn tok, {w, st, c} ->
      cond do
        tok in @border_styles -> {w, tok, c}
        tok in ~w(thin medium thick) or Regex.match?(~r/\A[+-]?[\d.]/, tok) -> {tok, st, c}
        Browser.Color.parse(tok) != nil -> {w, st, tok}
        true -> {w, st, c}
      end
    end)
  end

  defp tokens(v), do: ~r/[\w-]*\((?:[^()]|\([^()]*\))*\)|\S+/ |> Regex.scan(v) |> List.flatten()

  defp do_split(box, _v, toks)
       when box in ["margin", "padding", "border-width", "border-style", "border-color"] do
    [t, r, b, l] =
      case toks do
        [a] -> [a, a, a, a]
        [a, b] -> [a, b, a, b]
        [a, b, c] -> [a, b, c, b]
        [a, b, c, d | _] -> [a, b, c, d]
        [] -> List.duplicate("0", 4)
      end

    Enum.zip(@shorthands[box], [t, r, b, l])
  end

  defp do_split("border", _v, toks) do
    {w, st, c} = border_parts(toks)

    for side <- ~w(top right bottom left),
        {suffix, val} <- [{"width", w}, {"style", st}, {"color", c}],
        do: {"border-#{side}-#{suffix}", val}
  end

  defp do_split("border-" <> side, _v, toks) when side in ~w(top right bottom left) do
    {w, st, c} = border_parts(toks)
    [{"border-#{side}-width", w}, {"border-#{side}-style", st}, {"border-#{side}-color", c}]
  end

  defp do_split("overflow", _v, toks) do
    case toks do
      [a] -> [{"overflow-x", a}, {"overflow-y", a}]
      [a, b | _] -> [{"overflow-x", a}, {"overflow-y", b}]
      [] -> []
    end
  end

  defp do_split("list-style", _v, toks) do
    skip = ["inside", "outside"]

    case Enum.find(toks, &(&1 == "none")) ||
           Enum.find(toks, &(&1 not in skip and not String.starts_with?(&1, "url("))) do
      nil -> []
      type -> [{"list-style-type", type}]
    end
  end

  defp do_split("text-decoration", _v, toks) do
    lines = Enum.filter(toks, &(&1 in ~w(none underline overline line-through blink)))
    if lines == [], do: [], else: [{"text-decoration-line", Enum.join(lines, " ")}]
  end

  defp do_split("background", _v, toks) do
    color = Enum.find(toks, &(Browser.Color.parse(&1) != nil))
    [{"background-color", color || "transparent"}]
  end

  defp do_split("font", v, _toks) do
    size =
      "[\\d.]+(?:px|em|rem|pt|%)|xx-small|x-small|small|medium|large|x-large|xx-large|smaller|larger"

    re = Regex.compile!("(?<![\\w.-])(#{size})(?:/\\S+)?\\s+(.+)\\z", "s")

    case Regex.run(re, v, return: :index) do
      [{start, _}, {s0, sl}, {f0, fl}] ->
        prefix = v |> binary_part(0, start) |> String.split()
        size_v = binary_part(v, s0, sl)
        family = binary_part(v, f0, fl)

        weight =
          Enum.find(
            prefix,
            "normal",
            &(&1 in ~w(bold bolder lighter) or Regex.match?(~r/\A[1-9]00\z/, &1))
          )

        style = if Enum.any?(prefix, &(&1 in ~w(italic oblique))), do: "italic", else: "normal"

        [
          {"font-style", style},
          {"font-weight", weight},
          {"font-size", size_v},
          {"font-family", family}
        ]

      _ ->
        []
    end
  end

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

  # -- pruning / computed style ----------------------------------------------------

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
          ctx = context(tag, attrs, kids, parent, prev, i, count)
          {computed, custom} = compute(idx, ctx, parent)
          root = if parent, do: parent.root_fs, else: computed["font-size"] || @default_fs

          ctx =
            ctx
            |> Map.put(:computed, computed)
            |> Map.put(:custom, custom)
            |> Map.put(:root_fs, root)

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

  # -> {computed_map, custom_properties}
  defp compute(idx, ctx, parent) do
    {pc, parent_custom, parent_root} =
      case parent do
        nil -> {%{}, %{}, nil}
        p -> {p.computed, p.custom, p.root_fs}
      end

    inherited = Map.take(pc, @inherited)

    {customs, normals} =
      idx |> declared(ctx) |> Enum.split_with(fn {k, _} -> String.starts_with?(k, "--") end)

    custom = if customs == [], do: parent_custom, else: Map.merge(parent_custom, Map.new(customs))

    resolved = resolve_vars(normals, custom)

    pfs = Map.get(inherited, "font-size", @default_fs)

    fs =
      case resolved do
        %{"font-size" => v} -> font_size(v, pfs, parent_root || @default_fs) || pfs
        _ -> pfs
      end

    color =
      case resolved do
        %{"color" => v} -> color_value(v, inherited["color"]) || inherited["color"]
        _ -> inherited["color"]
      end

    env = %{fs: fs, root: parent_root || fs, color: color}

    typed =
      for {k, v} <- resolved, k not in ["font-size", "color"], reduce: %{} do
        acc ->
          case typed(k, v, env, pc) do
            {:ok, val} -> Map.put(acc, k, val)
            :skip -> acc
          end
      end

    base = Map.merge(inherited, typed)

    base =
      if Map.has_key?(resolved, "font-size") or Map.has_key?(inherited, "font-size"),
        do: Map.put(base, "font-size", fs),
        else: base

    base = if color, do: Map.put(base, "color", color), else: base
    # a fully transparent element (and, approximately, its subtree) takes space but isn't painted
    base = if base["opacity"] == 0.0, do: Map.put(base, "visibility", "hidden"), else: base
    {base, custom}
  end

  # substitute var() and finish pending shorthands; -> %{prop => normalized string}
  defp resolve_vars(decls, custom) do
    Enum.reduce(decls, %{}, fn
      {prop, {:sh, short, raw, long}}, acc ->
        with {:ok, v} <- substitute(raw, custom, 0),
             {^long, val} <- List.keyfind(split_shorthand(short, v), long, 0) do
          Map.put(acc, prop, normalize(val))
        else
          _ -> acc
        end

      {prop, value}, acc ->
        case substitute(value, custom, 0) do
          {:ok, v} -> Map.put(acc, prop, normalize(v))
          :error -> acc
        end
    end)
  end

  defp normalize(v), do: v |> String.trim() |> String.downcase()

  @doc false
  def substitute(value, _custom, depth) when depth > 16,
    do: if(String.contains?(value, "var("), do: :error, else: {:ok, value})

  def substitute(value, custom, depth) do
    case :binary.match(value, "var(") do
      :nomatch ->
        {:ok, value}

      {pos, 4} ->
        before = binary_part(value, 0, pos)
        rest = binary_part(value, pos + 4, byte_size(value) - pos - 4)
        {inner, after_} = take_parens(rest)
        {name, fallback} = split_comma(inner)
        name = name |> String.trim() |> String.downcase()

        replacement =
          case custom do
            %{^name => v} -> substitute(v, custom, depth + 1)
            _ when fallback != nil -> substitute(fallback, custom, depth + 1)
            _ -> :error
          end

        with {:ok, r} <- replacement,
             {:ok, tail} <- substitute(after_, custom, depth + 1) do
          {:ok, before <> String.trim(r) <> tail}
        end
    end
  end

  # `rest` follows an opening paren: -> {inside, after_closing_paren}
  defp take_parens(rest), do: take_parens(rest, rest, 1, 0)
  defp take_parens(<<>>, whole, _d, _n), do: {whole, ""}
  defp take_parens(<<?(, r::binary>>, w, d, n), do: take_parens(r, w, d + 1, n + 1)

  defp take_parens(<<?), r::binary>>, w, d, n) do
    if d == 1, do: {binary_part(w, 0, n), r}, else: take_parens(r, w, d - 1, n + 1)
  end

  defp take_parens(<<_, r::binary>>, w, d, n), do: take_parens(r, w, d, n + 1)

  defp split_comma(s), do: split_comma(s, s, 0, 0)
  defp split_comma(<<>>, s, _d, _n), do: {s, nil}
  defp split_comma(<<?(, r::binary>>, s, d, n), do: split_comma(r, s, d + 1, n + 1)
  defp split_comma(<<?), r::binary>>, s, d, n), do: split_comma(r, s, d - 1, n + 1)

  defp split_comma(<<?,, _::binary>>, s, 0, n),
    do: {binary_part(s, 0, n), binary_part(s, n + 1, byte_size(s) - n - 1)}

  defp split_comma(<<_, r::binary>>, s, d, n), do: split_comma(r, s, d, n + 1)

  # -- typed values --------------------------------------------------------------------

  defp typed(prop, v, _env, pc) when v in @keywords do
    if v == "inherit" and Map.has_key?(pc, prop), do: {:ok, pc[prop]}, else: :skip
  end

  defp typed("background-color", v, env, _pc) do
    case color_value(v, env.color) do
      nil -> :skip
      c -> {:ok, c}
    end
  end

  # left/right margins keep `auto` (used for centering); top/bottom auto is zero
  defp typed(prop, "auto", _env, _pc) when prop in ~w(margin-left margin-right), do: {:ok, :auto}

  defp typed(prop, v, env, _pc)
       when prop in ~w(margin-top margin-bottom margin-left margin-right
                       padding-top padding-bottom padding-left padding-right) do
    cond do
      v == "auto" -> {:ok, 0.0}
      px = length(v, env) -> {:ok, max(px, 0.0)}
      true -> :skip
    end
  end

  @size_props ~w(width height min-height max-height min-width max-width top left right bottom)

  # px as a float, {:pct, fraction}, or no entry for auto/none/unsupported values
  defp typed(prop, v, env, _pc) when prop in @size_props do
    cond do
      m = Regex.run(~r/\A([+-]?(?:\d+\.?\d*|\.\d+))%\z/, v) ->
        {:ok, {:pct, m |> Enum.at(1) |> to_float() |> Kernel./(100)}}

      px = length(v, env) ->
        {:ok, px}

      true ->
        :skip
    end
  end

  @border_widths ~w(border-top-width border-right-width border-bottom-width border-left-width)
  @border_colors ~w(border-top-color border-right-color border-bottom-color border-left-color)

  defp typed(prop, v, env, _pc) when prop in @border_widths do
    px =
      case v do
        "thin" -> 1.0
        "medium" -> 3.0
        "thick" -> 5.0
        _ -> length(v, env)
      end

    if px && px >= 0, do: {:ok, px}, else: :skip
  end

  defp typed(prop, v, env, _pc) when prop in @border_colors do
    case color_value(v, env.color) do
      nil -> :skip
      c -> {:ok, c}
    end
  end

  defp typed("text-indent", v, env, _pc) do
    if px = length(v, env), do: {:ok, px}, else: :skip
  end

  defp typed("opacity", v, _env, _pc) do
    case Float.parse(v) do
      {n, ""} -> {:ok, n |> max(0.0) |> min(1.0)}
      _ -> :skip
    end
  end

  defp typed("font-weight", v, _env, _pc) do
    bold? =
      v in ["bold", "bolder"] or
        (Regex.match?(~r/\A\d+\z/, v) and String.to_integer(v) >= 600)

    {:ok, if(bold?, do: "bold", else: "normal")}
  end

  defp typed("font-style", v, _env, _pc),
    do: {:ok, if(v in ["italic", "oblique"], do: "italic", else: "normal")}

  defp typed(_prop, v, _env, _pc), do: {:ok, v}

  defp color_value(v, current) do
    case Browser.Color.parse(v) do
      :current -> current
      c -> c
    end
  end

  @font_keywords %{
    "xx-small" => 9.0,
    "x-small" => 10.0,
    "small" => 13.0,
    "medium" => 16.0,
    "large" => 18.0,
    "x-large" => 24.0,
    "xx-large" => 32.0,
    "xxx-large" => 48.0
  }

  defp font_size(v, pfs, root) do
    cond do
      Map.has_key?(@font_keywords, v) ->
        @font_keywords[v]

      v == "smaller" ->
        pfs / 1.2

      v == "larger" ->
        pfs * 1.2

      v == "inherit" ->
        pfs

      m = Regex.run(~r/\A([\d.]+)%\z/, v) ->
        pfs * String.to_float(normalize_num(Enum.at(m, 1))) / 100

      true ->
        length(v, %{fs: pfs, root: root})
    end
  end

  defp to_float(n),
    do: n |> String.trim_leading("+") |> normalize_num_signed() |> String.to_float()

  defp normalize_num(n), do: if(String.contains?(n, "."), do: n, else: n <> ".0")

  # a CSS length in px, or nil if unsupported (percentages, calc(), viewport units)
  defp length(v, env) do
    case Regex.run(~r/\A([+-]?(?:\d+\.?\d*|\.\d+))([a-z]*)\z/, v) do
      [_, n, unit] ->
        n = n |> String.trim_leading("+") |> normalize_num_signed() |> String.to_float()

        case unit do
          "" -> if n == 0.0, do: 0.0
          "px" -> n
          "em" -> n * env.fs
          "rem" -> n * env.root
          "pt" -> n * 4 / 3
          "pc" -> n * 16
          "in" -> n * 96
          "cm" -> n * 96 / 2.54
          "mm" -> n * 96 / 25.4
          u when u in ["ex", "ch"] -> n * env.fs / 2
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp normalize_num_signed(n) do
    n =
      if String.starts_with?(n, ["-.", "."]),
        do: String.replace(n, ".", "0.", global: false),
        else: n

    if String.contains?(n, "."), do: n, else: n <> ".0"
  end

  # -- visibility helpers -----------------------------------------------------------------

  defp not_rendered?(c), do: c["display"] == "none" or collapsed?(c) or visually_hidden?(c)

  # a clipping box with zero height or width shows none of its content
  defp collapsed?(c) do
    clips?(c) and (zero?(c["height"]) or zero?(c["max-height"]) or zero?(c["width"]))
  end

  defp clips?(c),
    do:
      Map.get(c, "overflow-x", "visible") in @clips or
        Map.get(c, "overflow-y", "visible") in @clips

  defp zero?(v), do: v == 0.0 or v == {:pct, 0.0}

  # Boxes that exist only for assistive technology, or that are pushed far off
  # screen, are not shown: clipped to nothing, 1x1 clipping boxes, huge offsets.
  defp visually_hidden?(c) do
    positioned? = c["position"] in ["absolute", "fixed"]

    (positioned? and (empty_clip?(c["clip"]) or empty_clip_path?(c["clip-path"]))) or
      (clips?(c) and tiny?(c["width"]) and tiny?(c["height"])) or
      (c["position"] in ["absolute", "fixed", "relative"] and offscreen?(c)) or
      (clips?(c) and is_number(c["text-indent"]) and c["text-indent"] <= -1000)
  end

  defp tiny?(v), do: is_number(v) and v <= 1.0

  defp offscreen?(c) do
    Enum.any?(["left", "top"], fn k -> is_number(c[k]) and c[k] <= -1000 end) or
      Enum.any?(["left", "top"], fn k -> is_number(c[k]) and c[k] >= 10_000 end)
  end

  # clip: rect(top, right, bottom, left) with an empty area
  defp empty_clip?(nil), do: false

  defp empty_clip?(v) do
    case Regex.run(~r/\Arect\(\s*(.*?)\s*\)\z/, v) do
      [_, args] ->
        case args |> String.split(~r/[\s,]+/, trim: true) |> Enum.map(&clip_px/1) do
          [t, r, b, l] when is_number(t) and is_number(r) and is_number(b) and is_number(l) ->
            b <= t or r <= l

          _ ->
            false
        end

      nil ->
        false
    end
  end

  defp clip_px("auto"), do: :auto
  defp clip_px(v), do: length(v, %{fs: 16.0, root: 16.0})

  defp empty_clip_path?(nil), do: false

  defp empty_clip_path?(v) do
    case Regex.run(~r/\Ainset\(\s*(\d+(?:\.\d+)?)%/, v) do
      [_, n] -> to_float(n) >= 50.0
      nil -> Regex.match?(~r/\Acircle\(\s*0(?:px|%)?\s*[\s)]/, v)
    end
  end

  defp context(tag, attrs, kids, parent, prev, i, count) do
    %{
      tag: tag,
      attrs: attrs,
      id:
        case(List.keyfind(attrs, "id", 0),
          do: (
            {_, v} -> v
            nil -> nil
          )
        ),
      classes: attrs |> attr("class") |> String.split(),
      parent: parent,
      prev: prev,
      first?: i == 0,
      last?: i == count - 1,
      index: i + 1,
      count: count,
      empty?: kids == []
    }
  end
end
