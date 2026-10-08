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
            contain contain-intrinsic-size contain-intrinsic-width contain-intrinsic-height
            contain-intrinsic-inline-size contain-intrinsic-block-size
            width height min-height max-height min-width max-width box-sizing aspect-ratio margin-trim clip clip-path
            text-indent opacity margin-right padding-right vertical-align
            border-top-width border-right-width border-bottom-width border-left-width
            border-top-style border-right-style border-bottom-style border-left-style
            border-top-color border-right-color border-bottom-color border-left-color
            border-top-left-radius border-top-right-radius border-bottom-right-radius
            border-bottom-left-radius line-height
            background-image background-repeat background-position background-size box-shadow
            color background-color font-size font-weight font-style font-family
            text-decoration-line text-align direction list-style-type flex-direction
            margin-top margin-bottom margin-left padding-top padding-bottom padding-left
            scroll-margin-top scroll-padding-top object-fit object-position
            fill stroke stroke-width fill-opacity stroke-opacity fill-rule stroke-linecap
            stroke-linejoin stroke-miterlimit stroke-dasharray stop-color stop-opacity text-anchor
            transition transition-property pointer-events transform translate
            flex-wrap justify-content align-content align-items align-self flex-grow flex-shrink flex-basis content
            row-gap column-gap column-count column-width column-fill column-span break-before break-after column-rule-width column-rule-style column-rule-color order border-spacing border-collapse table-layout float clear rotate scale transform-origin z-index white-space text-wrap text-wrap-mode tab-size letter-spacing word-spacing word-space-transform text-transform text-align-last text-justify word-break line-break overflow-wrap word-wrap hyphens
            grid-template-columns grid-column grid-column-start grid-column-end justify-items justify-self)
  @inherited ~w(border-spacing border-collapse visibility text-indent color font-size font-weight font-style font-family
                text-decoration-line text-align direction list-style-type line-height
                fill stroke stroke-width fill-opacity stroke-opacity fill-rule stroke-linecap
                stroke-linejoin stroke-miterlimit stroke-dasharray text-anchor pointer-events white-space text-wrap text-wrap-mode tab-size letter-spacing word-spacing word-space-transform text-transform text-align-last text-justify word-break line-break overflow-wrap word-wrap hyphens)

  @doc false
  def inherited_props, do: @inherited

  # SVG presentation attributes: they act like author rules of the lowest priority
  @svg_tags ~w(svg g path rect circle ellipse line polyline polygon text tspan use stop
               lineargradient radialgradient symbol defs)
  @svg_attrs ~w(fill stroke stroke-width fill-opacity stroke-opacity fill-rule stroke-linecap
                stroke-linejoin stroke-miterlimit stroke-dasharray stop-color stop-opacity
                text-anchor opacity visibility display color font-size font-weight font-style
                font-family)
  @clips ~w(hidden clip scroll auto)
  @default_fs 16.0

  @shorthands %{
    "margin" => ~w(margin-top margin-right margin-bottom margin-left),
    "padding" => ~w(padding-top padding-right padding-bottom padding-left),
    "overflow" => ~w(overflow-x overflow-y),
    "list-style" => ~w(list-style-type),
    "text-decoration" => ~w(text-decoration-line),
    "font" => ~w(font-style font-weight font-size line-height font-family),
    "background" =>
      ~w(background-color background-image background-repeat background-position background-size),
    "border-width" =>
      ~w(border-top-width border-right-width border-bottom-width border-left-width),
    "border-style" =>
      ~w(border-top-style border-right-style border-bottom-style border-left-style),
    "border-color" =>
      ~w(border-top-color border-right-color border-bottom-color border-left-color),
    "border-radius" =>
      ~w(border-top-left-radius border-top-right-radius border-bottom-right-radius
         border-bottom-left-radius),
    "column-rule" => ~w(column-rule-width column-rule-style column-rule-color),
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
  dialog:not([open]), [hidden], input[type=hidden], area, base, datalist, noembed, param, rp, template { display: none }
  canvas, audio, video, iframe, object, embed, applet { display: none }
  html { font-size: 16px; color: #000000; font-weight: normal; font-style: normal }
  address, article, aside, blockquote, body, center, details, dialog, dd, div, dl, dt,
  fieldset, figcaption, figure, footer, form, h1, h2, h3, h4, h5, h6, header, hgroup, hr,
  html, legend, main, menu, nav, ol, p, pre, section, summary, ul { display: block }
  table { display: table; border-spacing: 2px; box-sizing: border-box }
  caption { display: table-caption; text-align: center }
  thead, tbody, tfoot { display: table-row-group; vertical-align: middle }
  tr { display: table-row; vertical-align: middle }
  td, th { display: table-cell; padding: 1px; vertical-align: inherit }
  colgroup { display: table-column-group }
  col { display: table-column }
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
  center { text-align: -webkit-center }
  th { text-align: center }
  input, select, textarea, button { display: inline-block; font-size: 13.3333px; font-weight: normal; font-style: normal; color: #000000; text-align: left; line-height: normal; text-decoration: none; text-indent: 0; margin: 0; padding: 1px 2px; border: 1px solid #767676; border-radius: 2px; background-color: #ffffff; overflow: hidden }
  input { width: 170px }
  input[type=checkbox], input[type=radio] { width: 13px; height: 13px; margin: 3px 3px 3px 4px; padding: 0; text-align: center; line-height: 13px; font-size: 10px }
  input[type=checkbox] { border-radius: 2px }
  input[type=radio] { border-radius: 50% }
  input[type=checkbox][checked] { background-color: #0075ff; border-color: #0075ff; color: #ffffff }
  input[type=radio][checked] { border-color: #0075ff; color: #0075ff }
  input[type=submit], input[type=button], input[type=reset], input[type=file], button { width: auto; padding: 1px 6px; text-align: center; background-color: #efefef; border-radius: 3px }
  textarea { width: 160px; height: 36px; padding: 2px }
  select { padding: 0 4px; border-radius: 3px; box-sizing: border-box }
  input[disabled], select[disabled], textarea[disabled], button[disabled] { color: #6d6d6d; background-color: #efefef; border-color: #b8b8b8 }
  fieldset { margin: 0 2px; padding: .35em .75em .625em; border: 1px solid #c0c0c0 }
  legend { padding: 0 2px }
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
    Enum.flat_map(sheets, fn sheet ->
      {origin, css, base} =
        case sheet do
          {origin, css} -> {origin, css, nil}
          {origin, css, base} -> {origin, css, base}
        end

      for rule <- CSS.parse(css),
          decls = rule.decls |> absolutize_urls(base) |> relevant(),
          decls != [],
          do: %{rule | decls: decls} |> Map.put(:origin, origin)
    end)
  end

  # url() in a stylesheet is relative to the stylesheet, not to the page
  defp absolutize_urls(decls, nil), do: decls

  defp absolutize_urls(decls, base) do
    Enum.map(decls, fn {prop, value, important?} ->
      if String.contains?(value, "url("),
        do: {prop, Browser.Backgrounds.absolutize(value, base), important?},
        else: {prop, value, important?}
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
    |> Enum.reduce(
      %{
        viewport: {env.width, env.height},
        font_units: Map.get(env, :font_units),
        pseudo: MapSet.new()
      },
      fn {rule, order}, idx ->
        idx = note_pseudo(idx, rule)
        rule = Map.put(rule, :order, order)
        Map.update(idx, {Map.get(rule, :pseudo), key(rule)}, [rule], &[rule | &1])
      end
    )
  end

  # which pseudo-elements have a rule that gives them `content` (the others make no box)
  defp note_pseudo(idx, %{pseudo: which, decls: decls}) when which != nil do
    if Enum.any?(decls, fn {p, v, _} -> p == "content" and v not in ["none", "normal"] end),
      do: %{idx | pseudo: MapSet.put(idx.pseudo, which)},
      else: idx
  end

  defp note_pseudo(idx, _rule), do: idx

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
  def declared(idx, ctx, pseudo \\ nil) do
    # rules are bucketed by the pseudo-element they are for, and then by their rightmost compound
    candidates =
      Map.get(idx, {pseudo, {:tag, ctx.tag}}, []) ++
        Map.get(idx, {pseudo, :other}, []) ++
        if(ctx.id, do: Map.get(idx, {pseudo, {:id, ctx.id}}, []), else: []) ++
        Enum.flat_map(ctx.classes, &Map.get(idx, {pseudo, {:class, &1}}, []))

    from_rules =
      for rule <- candidates,
          Map.get(rule, :pseudo) == pseudo,
          CSS.matches?(rule.selector, ctx),
          {prop, value, important?} <- rule.decls do
        {prop, {rank(rule.origin, important?), {0, rule.specificity}, rule.order}, value}
      end

    # inline styles and presentational attributes belong to the element, not its generated boxes
    own = if pseudo, do: %{attrs: [], tag: nil}, else: ctx

    from_inline =
      for {prop, value, important?} <- inline_decls(own.attrs) do
        {prop, {rank(:author, important?), {1, {0, 0, 0}}, 0}, value}
      end

    # presentational attributes (size, cols, rows) rank below every author rule
    from_hints =
      for {prop, value} <- dir_hint(own) ++ hints(own) do
        {prop, {rank(:author, false), {-1, {0, 0, 0}}, -1}, value}
      end

    (from_hints ++ from_rules ++ from_inline)
    |> Enum.reduce(%{}, fn {prop, k, v}, acc ->
      case acc do
        %{^prop => {k0, _}} when k0 > k -> acc
        _ -> Map.put(acc, prop, {k, v})
      end
    end)
    |> Map.new(fn {prop, {_k, v}} -> {prop, v} end)
  end

  # sizes that cannot be negative: a negative value is invalid and the declaration is dropped
  @non_negative ~w(width height min-height max-height min-width max-width flex-basis)

  defp relevant(decls) do
    decls
    |> Enum.flat_map(&expand/1)
    |> Enum.filter(fn {p, v, _} ->
      (p in @props or String.starts_with?(p, "--")) and not negative_size?(p, v) and
        not invalid_color?(p, v) and not percent_width?(p, v)
    end)
  end

  # a colour that is not one is dropped before the cascade, so an earlier declaration still
  # applies (`color: green; color: invalidValue`)
  defp invalid_color?(prop, v) when prop in ["color", "background-color"] and is_binary(v) do
    lower = v |> String.trim() |> String.downcase()

    not (lower in ~w(inherit initial unset revert) or String.contains?(lower, "var(") or
           Browser.Color.parse_alpha(lower) != nil)
  end

  defp invalid_color?(_prop, _v), do: false

  # a border or rule width is no percentage: such a declaration is dropped
  defp percent_width?(prop, v) when is_binary(v) do
    String.ends_with?(prop, "-width") and
      (String.starts_with?(prop, "border-") or String.starts_with?(prop, "column-rule")) and
      String.ends_with?(String.trim(v), "%")
  end

  defp percent_width?(_prop, _v), do: false

  # a negative width, height, min/max size or padding is invalid: the declaration is dropped
  # before the cascade, so an earlier value still applies
  defp negative_size?(prop, "-" <> rest) when is_binary(rest) do
    (prop in @non_negative or String.starts_with?(prop, "padding-")) and
      match?({n, _} when n > 0, Float.parse(String.replace_prefix(rest, ".", "0.")))
  end

  defp negative_size?(_prop, _v), do: false

  # Shorthands become longhands so the cascade can order them against each
  # other. A shorthand whose value uses var() can't be split until the
  # variables are known, so each longhand carries the raw value and is
  # resolved per element: `{:sh, shorthand, raw_value, longhand}`.
  # logical properties, for the horizontal left-to-right writing mode
  @logical %{
    "block-size" => "height",
    "inline-size" => "width",
    "min-block-size" => "min-height",
    "max-block-size" => "max-height",
    "min-inline-size" => "min-width",
    "max-inline-size" => "max-width",
    "margin-block-start" => "margin-top",
    "margin-block-end" => "margin-bottom",
    "margin-inline-start" => "margin-left",
    "margin-inline-end" => "margin-right",
    "padding-block-start" => "padding-top",
    "padding-block-end" => "padding-bottom",
    "padding-inline-start" => "padding-left",
    "padding-inline-end" => "padding-right",
    "inset-block-start" => "top",
    "inset-block-end" => "bottom",
    "inset-inline-start" => "left",
    "inset-inline-end" => "right"
  }
  @logical_pairs %{
    "margin-block" => {"margin-top", "margin-bottom"},
    "margin-inline" => {"margin-left", "margin-right"},
    "padding-block" => {"padding-top", "padding-bottom"},
    "padding-inline" => {"padding-left", "padding-right"},
    "inset-block" => {"top", "bottom"},
    "inset-inline" => {"left", "right"}
  }

  defp expand({"flex", value, imp}) do
    {grow, shrink, basis} =
      case value |> String.trim() |> String.downcase() |> tokens() do
        ["none"] -> {"0", "0", "auto"}
        ["auto"] -> {"1", "1", "auto"}
        [one] -> if number?(one), do: {one, "1", "0%"}, else: {"1", "1", one}
        [a, b] -> if number?(b), do: {a, b, "0%"}, else: {a, "1", b}
        [a, b, c | _] -> {a, b, c}
        [] -> {"0", "1", "auto"}
      end

    [{"flex-grow", grow, imp}, {"flex-shrink", shrink, imp}, {"flex-basis", basis, imp}]
  end

  # `flex-flow: <direction> || <wrap>`: what is not given is the initial value
  defp expand({"flex-flow", value, imp}) do
    toks = value |> String.trim() |> String.downcase() |> tokens()
    dir = Enum.find(toks, &(&1 in ~w(row row-reverse column column-reverse))) || "row"
    wrap = Enum.find(toks, &(&1 in ~w(nowrap wrap wrap-reverse))) || "nowrap"
    [{"flex-direction", dir, imp}, {"flex-wrap", wrap, imp}]
  end

  # `place-content`/`place-items`/`place-self`: the alignment, then the justification (the
  # alignment again when only one is given)
  defp expand({"place-" <> what, value, imp}) when what in ~w(content items self) do
    {a, j} =
      case tokens(String.trim(value)) do
        [a] -> {a, a}
        [a, j | _] -> {a, j}
        [] -> {"", ""}
      end

    if a == "",
      do: [],
      else: [{"align-" <> what, a, imp}, {"justify-" <> what, j, imp}]
  end

  # `columns: <width> || <count>`, in either order, either of them `auto`
  defp expand({"columns", value, imp}) do
    for t <- tokens(String.trim(value)), t != "auto" do
      if Regex.match?(~r/\A\d+\z/, t),
        do: {"column-count", t, imp},
        else: {"column-width", t, imp}
    end
  end

  defp expand({"gap", value, imp}) do
    case tokens(String.trim(value)) do
      [a] -> [{"row-gap", a, imp}, {"column-gap", a, imp}]
      [a, b | _] -> [{"row-gap", a, imp}, {"column-gap", b, imp}]
      [] -> []
    end
  end

  # inset: top, right, bottom, left, the way margin takes its values
  defp expand({"inset", value, imp}) do
    case tokens(String.trim(value)) do
      [a] ->
        for p <- ~w(top right bottom left), do: {p, a, imp}

      [a, b] ->
        [{"top", a, imp}, {"right", b, imp}, {"bottom", a, imp}, {"left", b, imp}]

      [a, b, c] ->
        [{"top", a, imp}, {"right", b, imp}, {"bottom", c, imp}, {"left", b, imp}]

      [a, b, c, d | _] ->
        [{"top", a, imp}, {"right", b, imp}, {"bottom", c, imp}, {"left", d, imp}]

      [] ->
        []
    end
  end

  defp expand({prop, value, imp}) when is_map_key(@logical, prop),
    do: expand({@logical[prop], value, imp})

  defp expand({prop, value, imp}) when is_map_key(@logical_pairs, prop) do
    {first, second} = @logical_pairs[prop]

    case tokens(String.trim(value)) do
      [a] -> [{first, a, imp}, {second, a, imp}]
      [a, b] -> [{first, a, imp}, {second, b, imp}]
      _ -> []
    end
  end

  defp expand({prop, value, imp}) when is_map_key(@shorthands, prop) do
    longs = @shorthands[prop]

    if has_var?(value) do
      for long <- longs, do: {long, {:sh, prop, value, long}, imp}
    else
      for {long, v} <- split_shorthand(prop, value), do: {long, v, imp}
    end
  end

  defp expand(decl), do: [decl]

  @keywords ~w(inherit initial unset revert)

  defp split_shorthand(prop, value) do
    v = value |> String.trim() |> downcase_outside_urls()
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

  defp corner_values(toks) do
    case toks do
      [a] -> [a, a, a, a]
      [a, b] -> [a, b, a, b]
      [a, b, c] -> [a, b, c, b]
      [a, b, c, d | _] -> [a, b, c, d]
      [] -> List.duplicate("0", 4)
    end
  end

  defp number?(token), do: Regex.match?(~r/\A[+-]?(\d+\.?\d*|\.\d+)\z/, token)

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

  # `h1 h2 h3 h4 / v1 v2 v3 v4`: corners in the order top-left, top-right,
  # bottom-right, bottom-left, each as "horizontal vertical"
  defp do_split("border-radius", v, _toks) do
    [h | rest] = String.split(v, "/", parts: 2)
    hs = h |> tokens() |> corner_values()
    vs = if rest == [], do: hs, else: rest |> hd() |> tokens() |> corner_values()

    for {long, {a, b}} <- Enum.zip(@shorthands["border-radius"], Enum.zip(hs, vs)),
        do: {long, "#{a} #{b}"}
  end

  defp do_split("border", _v, toks) do
    {w, st, c} = border_parts(toks)

    for side <- ~w(top right bottom left),
        {suffix, val} <- [{"width", w}, {"style", st}, {"color", c}],
        do: {"border-#{side}-#{suffix}", val}
  end

  defp do_split("column-rule", _v, toks) do
    {w, st, c} = border_parts(toks)
    [{"column-rule-width", w}, {"column-rule-style", st}, {"column-rule-color", c}]
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

  defp do_split("background", v, _toks) do
    parts = Browser.Backgrounds.shorthand(v)

    [
      {"background-color", parts.color},
      {"background-image", parts.image},
      {"background-repeat", parts.repeat},
      {"background-position", parts.position},
      {"background-size", parts.size}
    ]
  end

  defp do_split("font", v, _toks) do
    size =
      "[\\d.]+(?:px|em|rem|pt|%)|xx-small|x-small|small|medium|large|x-large|xx-large|smaller|larger"

    re = Regex.compile!("(?<![\\w.-])(#{size})(?:/(\\S+))?\\s+(.+)\\z", "s")

    case Regex.run(re, v, return: :index) do
      [{start, _}, {s0, sl}, lh, {f0, fl}] ->
        prefix = v |> binary_part(0, start) |> String.split()
        size_v = binary_part(v, s0, sl)
        family = binary_part(v, f0, fl)

        line_height =
          with {l0, ll} when l0 >= 0 <- lh, do: binary_part(v, l0, ll), else: (_ -> "normal")

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
          {"line-height", line_height},
          {"font-family", family}
        ]

      _ ->
        []
    end
  end

  # the `dir` attribute sets the direction; `auto` takes it from the first strong letter
  defp dir_hint(%{attrs: attrs} = ctx) do
    case attrs |> attr("dir") |> String.downcase() do
      d when d in ["ltr", "rtl"] -> [{"direction", d}]
      "auto" -> [{"direction", auto_direction(Map.get(ctx, :kids, []))}]
      _ -> []
    end
  end

  defp auto_direction(kids) do
    text =
      kids
      |> Stream.flat_map(fn
        {:text, t} -> [t]
        {:element, tag, _, k} when tag not in ["script", "style"] -> [auto_text(k)]
        _ -> []
      end)
      |> Enum.join()

    if Regex.match?(~r/^[^\p{L}]*[\p{Hebrew}\p{Arabic}\p{Syriac}\p{Thaana}]/u, text),
      do: "rtl",
      else: "ltr"
  end

  defp auto_text(kids) do
    for {:text, t} <- kids, into: "", do: t
  end

  defp hints(%{tag: "input", attrs: attrs}) do
    type = attrs |> attr("type") |> String.downcase()

    with true <- Browser.Forms.text_like?(type),
         {n, ""} when n > 0 <- Integer.parse(attr(attrs, "size")) do
      [{"width", "#{n * 8}px"}]
    else
      _ -> []
    end
  end

  defp hints(%{tag: "textarea", attrs: attrs}) do
    for {name, prop, unit} <- [{"cols", "width", 8}, {"rows", "height", 18}],
        {n, ""} when n > 0 <- [Integer.parse(attr(attrs, name))],
        do: {prop, "#{n * unit}px"}
  end

  # <img align="left|right"> floats; hspace/vspace are margins
  defp hints(%{tag: "img", attrs: attrs}) do
    float =
      case attrs |> attr("align") |> String.downcase() do
        a when a in ["left", "right"] -> [{"float", a}]
        _ -> []
      end

    margin = fn name, props ->
      case attrs |> attr(name) |> Integer.parse() do
        {n, _} when n > 0 -> for p <- props, do: {p, "#{n}px"}
        _ -> []
      end
    end

    float ++
      margin.("hspace", ["margin-left", "margin-right"]) ++
      margin.("vspace", ["margin-top", "margin-bottom"])
  end

  @table_tags ~w(table tr td th thead tbody tfoot)
  @table_border_color "#808080"

  # presentational attributes of tables: width, bgcolor, border, cellspacing, cellpadding,
  # align and valign (what HTML 4 pages use instead of CSS)
  defp hints(%{tag: tag, attrs: attrs} = ctx) when tag in @table_tags do
    size = fn name, prop ->
      case attrs |> attr(name) |> String.trim() do
        "" ->
          []

        v ->
          if Regex.match?(~r/\A\d+(\.\d+)?%?\z/, v),
            do: [{prop, if(String.ends_with?(v, "%"), do: v, else: v <> "px")}],
            else: []
      end
    end

    background =
      case attrs |> attr("bgcolor") |> String.trim() do
        "" ->
          []

        v ->
          [
            {"background-color",
             if(Regex.match?(~r/\A[0-9a-fA-F]{6}\z/, v), do: "#" <> v, else: v)}
          ]
      end

    align =
      case attrs |> attr("align") |> String.downcase() do
        a when a in ["left", "center", "right"] and tag != "table" -> [{"text-align", a}]
        _ -> []
      end

    valign =
      case attrs |> attr("valign") |> String.downcase() do
        v when v in ["top", "middle", "bottom"] -> [{"vertical-align", v}]
        "baseline" -> [{"vertical-align", "top"}]
        _ -> []
      end

    own =
      case tag do
        "table" ->
          table_own_hints(attrs)

        t when t in ["td", "th"] ->
          size.("width", "width") ++ size.("height", "height") ++ cell_hints(ctx)

        _ ->
          []
      end

    own ++ background ++ align ++ valign
  end

  defp hints(%{tag: tag, attrs: attrs}) when tag in @svg_tags do
    for {name, value} <- attrs, name in @svg_attrs, is_binary(value) do
      value = String.trim(value)

      if name == "font-size" and Regex.match?(~r/\A[+-]?(\d+\.?\d*|\.\d+)\z/, value),
        do: {name, value <> "px"},
        else: {name, value}
    end
  end

  defp hints(_ctx), do: []

  defp table_own_hints(attrs) do
    size = fn name, prop ->
      case attrs |> attr(name) |> String.trim() do
        v when v != "" ->
          if Regex.match?(~r/\A\d+(\.\d+)?%?\z/, v),
            do: [{prop, if(String.ends_with?(v, "%"), do: v, else: v <> "px")}],
            else: []

        _ ->
          []
      end
    end

    border =
      if List.keymember?(attrs, "border", 0) do
        n =
          attrs
          |> attr("border")
          |> Integer.parse()
          |> then(fn
            {n, _} -> n
            :error -> 1
          end)

        if n > 0,
          do: border_hints(n),
          else: []
      else
        []
      end

    spacing =
      case attrs |> attr("cellspacing") |> Integer.parse() do
        {n, _} when n >= 0 -> [{"border-spacing", "#{n}px"}]
        _ -> []
      end

    align =
      case attrs |> attr("align") |> String.downcase() do
        "center" -> [{"margin-left", "auto"}, {"margin-right", "auto"}]
        "right" -> [{"margin-left", "auto"}]
        _ -> []
      end

    size.("width", "width") ++ size.("height", "height") ++ border ++ spacing ++ align
  end

  # what a cell takes from its table: cellpadding, and a border when the table has one
  defp cell_hints(ctx) do
    case table_ancestor(ctx) do
      nil ->
        []

      %{attrs: attrs} ->
        padding =
          case attrs |> attr("cellpadding") |> Integer.parse() do
            {n, _} when n >= 0 ->
              for side <- ~w(top right bottom left), do: {"padding-#{side}", "#{n}px"}

            _ ->
              []
          end

        border =
          if List.keymember?(attrs, "border", 0) do
            n =
              attrs
              |> attr("border")
              |> Integer.parse()
              |> then(fn
                {n, _} -> n
                :error -> 1
              end)

            if n > 0, do: border_hints(1), else: []
          else
            []
          end

        padding ++ border
    end
  end

  defp border_hints(n) do
    for side <- ~w(top right bottom left),
        {part, value} <- [{"width", "#{n}px"}, {"style", "solid"}, {"color", @table_border_color}],
        do: {"border-#{side}-#{part}", value}
  end

  defp table_ancestor(%{parent: nil}), do: nil
  defp table_ancestor(%{parent: %{tag: "table"} = table}), do: table
  defp table_ancestor(%{parent: parent}), do: table_ancestor(parent)
  defp table_ancestor(_), do: nil

  # the same `style` attribute is on many elements of a page (and on one of them every time the
  # page is styled again), so its parse is kept for the run
  defp inline_decls(attrs) do
    case List.keyfind(attrs, "style", 0) do
      {_, css} ->
        case Process.get(:style_inline) do
          %{^css => decls} ->
            decls

          cache ->
            decls = css |> CSS.parse_declarations() |> relevant()
            if cache, do: Process.put(:style_inline, Map.put(cache, css, decls))
            decls
        end

      nil ->
        []
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
  def prune(nodes, idx) do
    Process.delete(:style_memo)
    Process.put(:style_share, %{})
    Process.put(:style_inline, %{})
    pruned = prune_children(nodes, nil, idx)
    Process.delete(:style_share)
    Process.delete(:style_inline)
    pruned
  end

  @doc """
  `prune/2` that reuses what an earlier run (`memo`, as it returned it) worked out for elements
  that did not change: `{pruned, memo}`. An element is taken over when it and everything below
  it is as before (`"@nid"` tells which element is which), its place among its siblings is the
  same, no element before it changed, and what it inherits from its parent is the same. The
  elements that changed, and the ones their selectors can reach, are styled afresh.
  """
  def prune(nodes, idx, memo) do
    Process.put(:style_memo, memo || %{})
    Process.put(:style_share, %{})
    Process.put(:style_inline, %{})
    pruned = prune_children(nodes, nil, idx)
    Process.delete(:style_share)
    Process.delete(:style_inline)
    {pruned, Process.delete(:style_memo)}
  end

  defp prune_children(nodes, parent, idx) do
    count = Enum.count(nodes, &match?({:element, _, _, _}, &1))
    tags_same? = same_shape?(parent, nodes)
    prune_list(nodes, parent, idx, count, 0, [], [], {tags_same?, true})
  end

  # What the memo keeps per element is plain data: contexts link to their parent, their
  # earlier siblings and their later ones, and copying such a term (into another process, say)
  # takes it apart into a tree that grows with every sibling.

  # the elements among the children are the ones there were
  defp same_shape?(nil, _nodes), do: true

  defp same_shape?(parent, nodes) do
    case memo_get(parent.attrs) do
      {%{shape: old}, _} -> old == shape(nodes)
      nil -> false
    end
  end

  defp shape(nodes), do: for({:element, tag, _, _} <- nodes, do: tag)

  defp memo_get(attrs) do
    with memo when is_map(memo) <- Process.get(:style_memo),
         {_, nid} when is_integer(nid) <- List.keyfind(attrs, "@nid", 0) do
      Map.get(memo, nid)
    else
      _ -> nil
    end
  end

  defp memo_put(%{attrs: attrs} = ctx, kids, node) do
    with memo when is_map(memo) <- Process.get(:style_memo),
         {_, nid} when is_integer(nid) <- List.keyfind(attrs, "@nid", 0) do
      entry = %{
        tag: ctx.tag,
        attrs: attrs,
        kids: :erlang.phash2(kids, 4_294_967_296),
        shape: shape(kids),
        index: ctx.index,
        count: ctx.count,
        computed: ctx.computed,
        custom: ctx.custom,
        root_fs: ctx.root_fs,
        chain_same: ctx.chain_same,
        parent: parent_sig(ctx.parent)
      }

      Process.put(:style_memo, Map.put(memo, nid, {entry, node}))
    end

    :ok
  end

  defp parent_sig(nil), do: nil
  defp parent_sig(p), do: {p.computed, p.custom, p.root_fs}

  defp parent_same?(nil, nil), do: true
  defp parent_same?(nil, _), do: false
  defp parent_same?(_, nil), do: false

  defp parent_same?(p, sig),
    do: p.chain_same and {p.computed, p.custom, p.root_fs} == sig

  defp prune_list([], _parent, _idx, _count, _i, _prev, acc, _flags), do: Enum.reverse(acc)

  defp prune_list([{:text, _} = t | rest], parent, idx, count, i, prev, acc, flags),
    do: prune_list(rest, parent, idx, count, i, prev, [t | acc], flags)

  defp prune_list(
         [{:element, tag, attrs, kids} | rest],
         parent,
         idx,
         count,
         i,
         prev,
         acc,
         {tags_same?, clean}
       ) do
    old = memo_get(attrs)
    same_self? = match?({%{tag: ^tag, attrs: ^attrs}, _}, old)

    reusable? =
      same_self? and tags_same? and clean and old != nil and
        elem(old, 0).kids == :erlang.phash2(kids, 4_294_967_296) and
        elem(old, 0).index == i + 1 and elem(old, 0).count == count and
        parent_same?(parent, elem(old, 0).parent)

    next_flags = {tags_same?, clean and same_self?}

    if reusable? do
      {e, onode} = old

      ctx =
        tag
        |> CSS.context(attrs, kids, parent, prev, i, count, rest)
        |> Map.merge(%{
          computed: e.computed,
          custom: e.custom,
          root_fs: e.root_fs,
          chain_same: true
        })

      acc = if onode == :hidden, do: acc, else: [onode | acc]
      prune_list(rest, parent, idx, count, i + 1, [ctx | prev], acc, next_flags)
    else
      ctx = CSS.context(tag, attrs, kids, parent, prev, i, count, rest)
      {computed, custom} = compute(idx, ctx, parent)
      computed = computed |> blockify_grid_item(parent) |> flex_item_align(parent)
      root = if parent, do: parent.root_fs, else: computed["font-size"] || @default_fs

      ctx =
        ctx
        |> Map.put(:computed, computed)
        |> Map.put(:custom, custom)
        |> Map.put(:root_fs, root)
        |> Map.put(:chain_same, same_self? and (parent == nil or parent.chain_same))

      {acc, node} =
        if not_rendered?(computed) do
          {acc, :hidden}
        else
          {computed, attrs} = marker(idx, ctx, computed, attrs)
          attrs = if computed == %{}, do: attrs, else: [{"@computed", computed} | attrs]
          kids = prune_children(kids, ctx, idx)
          kids = generated(idx, ctx, :before) ++ kids ++ generated(idx, ctx, :after)
          node = {:element, tag, attrs, kids}
          {[node | acc], node}
        end

      memo_put(ctx, kids_of(tag, attrs, kids), node)
      prune_list(rest, parent, idx, count, i + 1, [ctx | prev], acc, next_flags)
    end
  end

  defp kids_of(_tag, _attrs, kids), do: kids

  # `::marker { content }` of list items (the text drawn instead of the bullet or number) and
  # summaries. A summary's marker may depend on whether its `<details>` is open, so both are
  # kept: `"@marker"` is `{closed_text, open_text}`.
  defp marker(idx, %{tag: "li"} = ctx, computed, attrs) do
    case marker_text(idx, ctx, ctx) do
      nil -> {computed, attrs}
      text -> {Map.put(computed, "marker-content", text), attrs}
    end
  end

  defp marker(
         idx,
         %{tag: "summary", parent: %{tag: "details", attrs: pattrs} = parent} = ctx,
         computed,
         attrs
       ) do
    toggled = fn open? ->
      pattrs = List.keydelete(pattrs, "open", 0)
      pattrs = if open?, do: [{"open", ""} | pattrs], else: pattrs
      %{ctx | parent: %{parent | attrs: pattrs}}
    end

    closed = marker_text(idx, toggled.(false), ctx)
    open = marker_text(idx, toggled.(true), ctx)

    if closed == nil and open == nil,
      do: {computed, attrs},
      else: {computed, [{"@marker", {closed, open}} | attrs]}
  end

  # A checkbox or radio button has no children for `::before`/`::after` to go beside, so
  # their text replaces what it shows: `"@content"` is `{unchecked_text, checked_text}`.
  defp marker(idx, %{tag: "input", attrs: iattrs} = ctx, computed, attrs) do
    type = iattrs |> attr("type") |> String.downcase()

    if type in ["checkbox", "radio"] and pseudo_any?(idx, [:before, :after]) do
      toggled = fn checked? ->
        iattrs = List.keydelete(iattrs, "checked", 0)
        %{ctx | attrs: if(checked?, do: [{"checked", ""} | iattrs], else: iattrs)}
      end

      text = fn checked? ->
        before = pseudo_text(idx, toggled.(checked?), ctx, :before)
        after_ = pseudo_text(idx, toggled.(checked?), ctx, :after)
        if before || after_, do: (before || "") <> (after_ || "")
      end

      case {text.(false), text.(true)} do
        {nil, nil} -> {computed, attrs}
        content -> {unboxed(computed), [{"@content", content} | attrs]}
      end
    else
      {computed, attrs}
    end
  end

  defp marker(_idx, _ctx, computed, attrs), do: {computed, attrs}

  # text drawn instead of the native box: the box's fixed 13px height (a user-agent value) and
  # its clipping would cut it
  defp unboxed(computed) do
    ["height", "line-height"]
    |> Enum.reduce(computed, fn k, c -> if c[k] == 13.0, do: Map.delete(c, k), else: c end)
    |> Map.drop(["overflow-x", "overflow-y"])
  end

  defp pseudo_any?(idx, which),
    do: Enum.any?(which, &MapSet.member?(Map.get(idx, :pseudo, MapSet.new()), &1))

  # spaces don't collapse in a marker
  defp marker_text(idx, match_ctx, ctx) do
    with text when is_binary(text) <- pseudo_text(idx, match_ctx, ctx, :marker),
         do: String.replace(text, " ", "\u00A0")
  end

  # the `content` text of a pseudo-element: matched against `match_ctx`, inheriting from `ctx`
  defp pseudo_text(idx, match_ctx, ctx, which) do
    if MapSet.member?(Map.get(idx, :pseudo, MapSet.new()), which) do
      {computed, _} = compute(idx, match_ctx, ctx, which)
      content_text(computed["content"], ctx.attrs)
    end
  end

  # The box `::before` / `::after` makes: a `span` holding the `content` text, styled by the
  # pseudo-element rules. Nothing is made without `content` (or with `none`/`normal`), for
  # `display: none`, or for elements whose content is not their children.
  @no_pseudo ~w(input select textarea img br hr svg video canvas iframe option)

  defp generated(_idx, %{tag: tag}, _which) when tag in @no_pseudo, do: []

  defp generated(idx, ctx, which) do
    if MapSet.member?(Map.get(idx, :pseudo, MapSet.new()), which),
      do: generate(idx, ctx, which),
      else: []
  end

  defp generate(idx, ctx, which) do
    {computed, _custom} = compute(idx, ctx, ctx, which)

    with text when is_binary(text) <- content_text(computed["content"], ctx.attrs),
         false <- not_rendered?(computed) do
      kids = if text == "", do: [], else: [{:text, text}]
      [{:element, "span", [{"@computed", Map.delete(computed, "content")}], kids}]
    else
      _ -> []
    end
  end

  # the text of a `content` value: strings, `attr()` and quotes joined; nil for no box
  defp content_text(value, attrs) when is_binary(value) do
    value = String.trim(value)

    parts =
      Regex.scan(
        ~r/"((?:[^"\\]|\\.)*)"|'((?:[^'\\]|\\.)*)'|attr\(\s*([\w-]+)\s*\)|open-quote|close-quote/su,
        value
      )

    if value in ["", "none", "normal"] or parts == [] do
      nil
    else
      Enum.map_join(parts, fn
        [_, s] -> css_string(s)
        [_, "", s] -> css_string(s)
        [_, "", "", name] -> attr(attrs, String.downcase(name))
        ["open-quote"] -> "“"
        ["close-quote"] -> "”"
        _ -> ""
      end)
    end
  end

  defp content_text(_value, _attrs), do: nil

  # `\201C` and `\"` in a CSS string
  defp css_string(s) do
    Regex.replace(~r/\\(?:([0-9a-fA-F]{1,6})\s?|(.))/su, s, fn
      _, hex, "" ->
        cp = String.to_integer(hex, 16)
        if cp in 1..0xD7FF or cp in 0xE000..0x10FFFF, do: <<cp::utf8>>, else: "\uFFFD"

      _, _, char ->
        char
    end)
  end

  # Grid is laid out as a stack of blocks, so what sits directly in a grid container is
  # block-level, as it is in a real grid (an inline link wrapping a logo becomes a block box).
  defp blockify_grid_item(computed, %{computed: %{"display" => d}})
       when d in ["grid", "inline-grid"] do
    case computed["display"] do
      v when v in [nil, "inline", "inline-block"] -> Map.put(computed, "display", "block")
      "inline-flex" -> Map.put(computed, "display", "flex")
      "inline-grid" -> Map.put(computed, "display", "grid")
      "inline-table" -> Map.put(computed, "display", "table")
      _ -> computed
    end
  end

  defp blockify_grid_item(computed, _parent), do: computed

  # `vertical-align` does not apply to flex items (they are blockified)
  defp flex_item_align(computed, %{computed: %{"display" => d}})
       when d in ["flex", "inline-flex"],
       do: Map.delete(computed, "vertical-align")

  defp flex_item_align(computed, _parent), do: computed

  # -> {computed_map, custom_properties}
  #
  # What an element computes to follows from what the cascade declared for it and what its parent
  # computed to (and whether it is a table). Most elements of a page, a row of list items or the
  # cells of a grid, have both the same as another element, so those are worked out once.
  defp compute(idx, ctx, parent, pseudo \\ nil) do
    {pc, parent_custom, parent_root} =
      case parent do
        nil -> {%{}, %{}, nil}
        p -> {p.computed, p.custom, p.root_fs}
      end

    decl = declared(idx, ctx, pseudo)

    case Process.get(:style_share) do
      nil ->
        compute_declared(idx, ctx.tag, decl, pc, parent_custom, parent_root)

      shared ->
        key = {decl, ctx.tag == "table", pc, parent_custom, parent_root}

        case shared do
          %{^key => result} ->
            result

          _ ->
            result = compute_declared(idx, ctx.tag, decl, pc, parent_custom, parent_root)
            shared = if map_size(shared) >= 20_000, do: %{}, else: shared
            Process.put(:style_share, Map.put(shared, key, result))
            result
        end
    end
  end

  # what `ex` (the x-height) and `ch` (the advance of a "0") are as a factor of the font size,
  # asked of whatever measures fonts (`:font_units` of the environment); without one they are
  # a guess
  defp font_units(idx, resolved, inherited, fs) do
    case Map.get(idx, :font_units) do
      nil ->
        {0.5, 0.6}

      units ->
        pick = fn key -> Map.get(resolved, key) || inherited[key] end

        units.(%{
          size: fs,
          family: to_string(pick.("font-family")),
          bold: pick.("font-weight") == "bold",
          italic: pick.("font-style") == "italic"
        })
    end
  end

  defp compute_declared(idx, tag, decl, pc, parent_custom, parent_root) do
    inherited = Map.take(pc, @inherited)

    {customs, normals} = Enum.split_with(decl, fn {k, _} -> String.starts_with?(k, "--") end)

    custom = if customs == [], do: parent_custom, else: resolve_customs(customs, parent_custom)

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

    {vw, vh} = Map.get(idx, :viewport, {1024, 768})
    {ex, ch} = font_units(idx, resolved, inherited, fs)

    env = %{
      fs: fs,
      root: parent_root || fs,
      color: color,
      vw: vw / 100,
      vh: vh / 100,
      ex: ex,
      ch: ch
    }

    typed =
      for {k, v} <- resolved, k not in ["font-size", "color"], reduce: %{} do
        acc ->
          case typed(k, v, env, pc) do
            {:ok, val} -> Map.put(acc, k, val)
            :skip -> acc
          end
      end

    base = Map.merge(inherited, typed) |> size_containment(resolved, env)

    # `<center>` centres blocks and tables, but its text alignment stops at a table
    base =
      if tag == "table" and base["text-align"] == "-webkit-center",
        do: Map.put(base, "text-align", "left"),
        else: base

    base =
      if Map.has_key?(resolved, "font-size") or Map.has_key?(inherited, "font-size"),
        do: Map.put(base, "font-size", fs),
        else: base

    base = if color, do: Map.put(base, "color", color), else: base

    # the overflow of the root element, or of `<body>` when that has none, belongs to the
    # viewport, which this browser always scrolls: neither box clips its own content
    base =
      if tag in ["html", "body"], do: Map.drop(base, ["overflow-x", "overflow-y"]), else: base

    # a fully transparent element (and, approximately, its subtree) takes space but isn't painted
    base =
      cond do
        base["opacity"] != 0.0 -> base
        # without scripts a reveal animation never runs: what would fade in shows its end state
        # (it starts displaced too: the end state is in place)
        reveal?(base) -> Map.drop(base, ["opacity", "transform", "translate", "rotate", "scale"])
        true -> Map.put(base, "visibility", "hidden")
      end

    {base, custom}
  end

  # `contain: size` (or `strict`): the content does not size the box, `contain-intrinsic-*` does
  # (zero when it is not given). Only the height of a block and a width asked for from the
  # content are known here.
  defp size_containment(base, resolved, env) do
    contain = String.split(Map.get(resolved, "contain", ""))

    if "size" in contain or "strict" in contain do
      {iw, ih} = intrinsic_size(resolved, env)

      base =
        if Map.get(base, "height", :auto) == :auto, do: Map.put(base, "height", ih), else: base

      if Map.get(base, "width") in [:maxc, :fit, :minc],
        do: Map.put(base, "width", iw),
        else: base
    else
      base
    end
  end

  defp intrinsic_size(resolved, env) do
    {w, h} =
      case resolved |> Map.get("contain-intrinsic-size", "") |> intrinsic_lengths(env) do
        [w, h] -> {w, h}
        [w] -> {w, w}
        _ -> {0.0, 0.0}
      end

    pick = fn key, default ->
      case resolved |> Map.get(key, "") |> intrinsic_lengths(env) do
        [v | _] -> v
        _ -> default
      end
    end

    w = pick.("contain-intrinsic-inline-size", w)
    h = pick.("contain-intrinsic-block-size", h)
    {pick.("contain-intrinsic-width", w), pick.("contain-intrinsic-height", h)}
  end

  # `none`, and the `auto` of `auto 10px` (the size last rendered), count for nothing
  defp intrinsic_lengths(value, env) do
    value
    |> String.split()
    |> Enum.reject(&(&1 in ["auto", "none"]))
    |> Enum.map(&(length(&1, env) || 0.0))
  end

  # `opacity: 0` with a transition on opacity, on something that takes clicks: a scripted
  # fade-in (a hidden menu or dialog turns pointer events off as well)
  defp reveal?(c) do
    c["pointer-events"] != "none" and
      Enum.any?(["transition", "transition-property"], fn k ->
        is_binary(c[k]) and Regex.match?(~r/(\A|[\s,])opacity(\z|[\s,])/, c[k])
      end)
  end

  # substitute var() and finish pending shorthands; -> %{prop => normalized string}
  defp resolve_vars(decls, custom) do
    Enum.reduce(decls, %{}, fn
      {prop, {:sh, short, raw, long}}, acc ->
        with {:ok, v} <- substitute(raw, custom, 0),
             {^long, val} <- List.keyfind(split_shorthand(short, v), long, 0) do
          Map.put(acc, prop, normalize(prop, val))
        else
          _ -> acc
        end

      {prop, value}, acc ->
        case substitute(value, custom, 0) do
          {:ok, v} -> Map.put(acc, prop, normalize(prop, v))
          :error -> acc
        end
    end)
  end

  # values are case-insensitive keywords, except the paths inside url() and quoted strings
  # the text of a string is kept in `content`, `quotes` and the counter properties
  @string_props ~w(content quotes counter-reset counter-increment counter-set list-style-type
                   list-style)

  defp normalize(prop, v) do
    v = String.trim(v)

    cond do
      prop in @string_props -> downcase_outside_strings(v)
      String.contains?(v, "url(") -> v
      true -> String.downcase(v)
    end
  end

  defp downcase_outside_strings(v) do
    ~r/"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|url\([^)]*\)/is
    |> Regex.split(v, include_captures: true)
    |> Enum.map_join(fn part ->
      if Regex.match?(~r/\A(?:"|'|url\()/i, part), do: part, else: String.downcase(part)
    end)
  end

  # keywords of a shorthand are folded to lower case; the address in a `url()` is left alone
  defp downcase_outside_urls(v) do
    if String.contains?(v, "url(") do
      ~r/url\((?:"[^"]*"|'[^']*'|[^)]*)\)/i
      |> Regex.split(v, include_captures: true)
      |> Enum.map_join(fn part ->
        if Regex.match?(~r/\Aurl\(/i, part), do: part, else: String.downcase(part)
      end)
    else
      String.downcase(v)
    end
  end

  defp has_var?(value), do: Regex.match?(~r/var\(/i, value)

  @doc false
  def substitute(value, _custom, depth) when depth > 16,
    do: if(has_var?(value), do: :error, else: {:ok, value})

  def substitute(value, custom, depth) do
    case Regex.run(~r/var\(/i, value, return: :index) do
      nil ->
        {:ok, value}

      [{pos, 4}] ->
        before = binary_part(value, 0, pos)
        rest = binary_part(value, pos + 4, byte_size(value) - pos - 4)
        {inner, after_} = take_parens(rest)
        {name, fallback} = split_comma(inner)
        name = name |> String.trim() |> Browser.CSS.unescape()

        replacement =
          case custom do
            %{^name => v} -> substitute(v, custom, depth + 1)
            _ when fallback != nil -> substitute(fallback, custom, depth + 1)
            _ -> :error
          end

        with {:ok, r} <- replacement,
             {:ok, tail} <- substitute(after_, custom, depth + 1) do
          # a substituted value is its own token(s): `var(--a)var(--b)` is two values, not one
          {:ok, before <> " " <> String.trim(r) <> " " <> tail}
        end
    end
  end

  # Custom properties are computed per element: `var()` inside one is substituted against that
  # element's own values, a cycle makes every property in it guaranteed-invalid (dropped), and
  # `initial` / `inherit` / `unset` are taken literally. -> the custom properties in effect
  defp resolve_customs(own, parent) do
    own =
      Map.new(own, fn {k, v} ->
        case v |> String.trim() |> String.downcase() do
          "initial" -> {k, :invalid}
          kw when kw in ["inherit", "unset"] -> {k, Map.get(parent, k, :invalid)}
          _ -> {k, v}
        end
      end)

    refs =
      Map.new(own, fn
        {k, v} when is_binary(v) ->
          names =
            ~r/var\(\s*(--[^\s,)]*)/i
            |> Regex.scan(v, capture: :all_but_first)
            |> Enum.map(fn [n] -> Browser.CSS.unescape(n) end)

          {k, Enum.filter(names, &is_map_key(own, &1))}

        {k, _} ->
          {k, []}
      end)

    cyclic = for k <- Map.keys(own), reaches?(refs, refs[k], k, MapSet.new()), do: k
    own = Enum.reduce(cyclic, own, &Map.put(&2, &1, :invalid))

    final =
      settle(
        own,
        Map.drop(parent, Map.keys(own)),
        parent,
        Map.new(own, fn {k, _} -> {k, refs[k]} end)
      )

    Map.reject(final, fn {_, v} -> v == :invalid end)
  end

  # a substituted value that is a wide keyword acts as that keyword
  defp wide_keyword(value, name, parent) do
    case String.downcase(value) do
      "initial" -> :invalid
      kw when kw in ["inherit", "unset"] -> Map.get(parent, name, :invalid)
      _ -> value
    end
  end

  defp reaches?(_refs, [], _target, _seen), do: false

  defp reaches?(refs, [n | rest], target, seen) do
    cond do
      n == target -> true
      MapSet.member?(seen, n) -> reaches?(refs, rest, target, seen)
      true -> reaches?(refs, refs[n] ++ rest, target, MapSet.put(seen, n))
    end
  end

  # resolve what no longer waits on another own property, until nothing is left
  defp settle(pending, done, _parent, _refs) when map_size(pending) == 0, do: done

  defp settle(pending, done, parent, refs) do
    ready = for {k, _} <- pending, Enum.all?(refs[k], &(not is_map_key(pending, &1))), do: k
    ready = if ready == [], do: Map.keys(pending), else: ready

    done =
      Enum.reduce(ready, done, fn k, acc ->
        case pending[k] do
          v when is_binary(v) ->
            case substitute(v, Map.reject(acc, fn {_, x} -> x == :invalid end), 0) do
              {:ok, r} -> Map.put(acc, k, wide_keyword(String.trim(r), k, parent))
              :error -> Map.put(acc, k, :invalid)
            end

          other ->
            Map.put(acc, k, other)
        end
      end)

    settle(Map.drop(pending, ready), done, parent, refs)
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
    case color_value_rgba(v, env.color) do
      nil -> :skip
      c -> {:ok, c}
    end
  end

  # left/right margins keep `auto` (used for centering); top/bottom auto is zero
  defp typed(prop, "auto", _env, _pc)
       when prop in ~w(margin-left margin-right margin-top margin-bottom),
       do: {:ok, :auto}

  # margins may be negative: they pull a box over its neighbours or out of its container
  defp typed(prop, v, env, _pc)
       when prop in ~w(margin-top margin-bottom margin-left margin-right) do
    cond do
      v == "auto" -> {:ok, 0.0}
      px = length(v, env) -> {:ok, px}
      # a percentage is of the containing block's width, known only to layout
      pct = percentage(v) -> {:ok, {:pct, pct}}
      true -> :skip
    end
  end

  defp typed(prop, v, env, _pc)
       when prop in ~w(padding-top padding-bottom padding-left padding-right) do
    cond do
      px = length(v, env) -> {:ok, max(px, 0.0)}
      pct = percentage(v) -> {:ok, {:pct, max(pct, 0.0)}}
      true -> :skip
    end
  end

  @size_props ~w(width height min-height max-height min-width max-width top left right bottom scroll-margin-top scroll-padding-top)

  # px as a float, {:pct, fraction}, no entry for none/unsupported values, and `:auto`
  # for an explicit `width: auto` / `height: auto` (which, unlike no declaration,
  # overrides the size attributes of images)
  defp typed(prop, "auto", _env, _pc) when prop in ["width", "height"], do: {:ok, :auto}

  # fit-content: as wide as the content wants (a block that sizes itself like an inline-block)
  defp typed("width", "min-content", _env, _pc), do: {:ok, :minc}
  defp typed("width", "max-content", _env, _pc), do: {:ok, :maxc}

  # stretch: fill the containing block; a block already does, so layout only looks at it for
  # boxes that would otherwise shrink to fit
  defp typed(prop, v, _env, _pc)
       when prop in ["width", "min-width"] and
              v in ["stretch", "-webkit-fill-available", "-moz-available"],
       do: {:ok, if(prop == "width", do: :stretch, else: 0.0)}

  # fit-content(<length-percentage>): as wide as the content, but at least its narrowest and
  # at most the length
  defp typed("width", "fit-content(" <> rest, env, _pc) do
    arg = rest |> String.trim_trailing(")") |> String.trim()

    cond do
      pct = percentage(arg) -> {:ok, {:fitc, {:pct, pct}}}
      px = length(arg, env) -> {:ok, {:fitc, px}}
      true -> :skip
    end
  end

  defp typed(prop, v, _env, _pc)
       when prop in ["width", "height", "max-height"] and
              v in [
                "fit-content",
                "max-content",
                "min-content",
                "-webkit-fit-content",
                "-moz-fit-content"
              ],
       do: {:ok, :fit}

  defp typed(prop, v, env, _pc) when prop in @size_props do
    cond do
      Browser.Calc.math?(v) ->
        case Browser.Calc.eval(v, &unit_px(&1, env)) do
          {:ok, {:pct, f}} -> {:ok, {:pct, f}}
          {:ok, {:px, n}} -> {:ok, n}
          {:ok, {:calc, _, _} = mixed} when prop in ~w(width min-width max-width) -> {:ok, mixed}
          _ -> :skip
        end

      m = Regex.run(~r/\A([+-]?(?:\d+\.?\d*|\.\d+))%\z/, v) ->
        {:ok, {:pct, m |> Enum.at(1) |> to_float() |> Kernel./(100)}}

      px = length(v, env) ->
        {:ok, px}

      true ->
        :skip
    end
  end

  @border_widths ~w(border-top-width border-right-width border-bottom-width border-left-width
                    column-rule-width)
  @border_colors ~w(border-top-color border-right-color border-bottom-color border-left-color
                    column-rule-color)

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
    case color_value_rgba(v, env.color) do
      nil -> :skip
      c -> {:ok, c}
    end
  end

  @radii ~w(border-top-left-radius border-top-right-radius border-bottom-right-radius
            border-bottom-left-radius)

  # `h` or `h v`, each a length or percentage -> {h, v} (px floats / {:pct, f})
  defp typed(prop, v, env, _pc) when prop in @radii do
    parsed =
      v
      |> String.split()
      |> Enum.map(fn tok ->
        case Regex.run(~r/\A([+-]?(?:\d+\.?\d*|\.\d+))%\z/, tok) do
          [_, n] -> {:pct, to_float(n) / 100}
          nil -> length(tok, env)
        end
      end)

    case parsed do
      [h] -> radius_pair(h, h)
      [h, vv] -> radius_pair(h, vv)
      _ -> :skip
    end
  end

  # `normal`, a number (a factor of the font size, inherited as such), or a
  # length/percentage (resolved against this element's font size to px)
  # one length for both directions, or horizontal then vertical
  defp typed("border-spacing", v, env, _pc) do
    case v |> tokens() |> Enum.map(&length(&1, env)) do
      [h] when is_number(h) -> {:ok, {max(h, 0.0), max(h, 0.0)}}
      [h, vv | _] when is_number(h) and is_number(vv) -> {:ok, {max(h, 0.0), max(vv, 0.0)}}
      _ -> :skip
    end
  end

  defp typed("column-gap", "normal", _env, _pc), do: {:ok, :normal}

  defp typed(prop, v, env, _pc) when prop in ["row-gap", "column-gap"] do
    px = if v == "normal", do: 0.0, else: length(v, env)

    cond do
      px && px >= 0 -> {:ok, px}
      pct = percentage(v) -> if pct >= 0, do: {:ok, {:pct, pct}}, else: :skip
      true -> :skip
    end
  end

  defp typed("column-count", v, _env, _pc) do
    case Integer.parse(v) do
      {n, ""} when n >= 1 -> {:ok, n}
      _ -> :skip
    end
  end

  defp typed("column-width", v, env, _pc) do
    px = length(v, env)
    if px && px > 0, do: {:ok, px}, else: :skip
  end

  defp typed("line-height", v, env, _pc) do
    cond do
      v == "normal" ->
        {:ok, :normal}

      Regex.match?(~r/\A\+?(\d+\.?\d*|\.\d+)\z/, v) ->
        {:ok, {:num, to_float(v)}}

      m = Regex.run(~r/\A\+?(\d+\.?\d*|\.\d+)%\z/, v) ->
        {:ok, {:px, env.fs * to_float(Enum.at(m, 1)) / 100}}

      (px = length(v, env)) && px >= 0 ->
        {:ok, {:px, px}}

      true ->
        :skip
    end
  end

  defp typed("background-image", v, _env, _pc), do: {:ok, Browser.Backgrounds.parse_images(v)}
  defp typed("background-repeat", v, _env, _pc), do: {:ok, Browser.Backgrounds.parse_repeat(v)}

  defp typed("background-position", v, env, _pc),
    do: {:ok, Browser.Backgrounds.parse_position(font_units_to_px(v, env))}

  defp typed("background-size", v, env, _pc),
    do: {:ok, Browser.Backgrounds.parse_size(font_units_to_px(v, env))}

  defp typed("box-shadow", "none", _env, _pc), do: {:ok, []}

  defp typed("box-shadow", v, env, _pc) do
    {r, g, b} = if match?({_, _, _}, env.color), do: env.color, else: {0, 0, 0}
    {:ok, Browser.Shadows.parse(v, env.fs, {r, g, b, 255})}
  end

  # a length or percentage; the keywords stay as they are
  defp typed("vertical-align", v, env, _pc) do
    cond do
      px = length(v, env) -> {:ok, px}
      pct = percentage(v) -> {:ok, {:pct, pct}}
      true -> {:ok, v}
    end
  end

  defp typed(prop, "normal", _env, _pc) when prop in ["letter-spacing", "word-spacing"],
    do: {:ok, 0.0}

  defp typed("word-spacing", v, env, _pc) do
    if px = length(v, env), do: {:ok, px}, else: :skip
  end

  # a percentage is of the font size, as the em it is a hundredth of; it stays one when
  # inherited, and each element takes its own font size
  defp typed("letter-spacing", v, env, _pc) do
    cond do
      px = length(v, env) -> {:ok, px}
      pct = percentage(v) -> {:ok, {:pct, pct}}
      true -> :skip
    end
  end

  defp typed("text-indent", v, env, _pc) do
    cond do
      px = length(v, env) -> {:ok, px}
      pct = percentage(v) -> {:ok, {:pct, pct}}
      true -> :skip
    end
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

  # `em` in a background's position or size is the element's font size
  # em and ch lengths of a background position or size, as pixels
  defp font_units_to_px(v, env) do
    ch = env.fs * Map.get(env, :ch, 0.6)

    v
    |> ems_to_px(env.fs)
    |> then(
      &Regex.replace(~r/(?<![\w.])([+-]?(?:\d+\.?\d*|\.\d+))ch\b/i, &1, fn _, n ->
        {f, _} = Float.parse(if String.starts_with?(n, "."), do: "0" <> n, else: n)
        "#{Float.round(f * ch, 3)}px"
      end)
    )
  end

  defp ems_to_px(v, fs) do
    Regex.replace(~r/(?<![\w.])([+-]?(?:\d+\.?\d*|\.\d+))em\b/i, v, fn _, n ->
      {f, _} = Float.parse(if String.starts_with?(n, "."), do: "0" <> n, else: n)
      "#{Float.round(f * fs, 3)}px"
    end)
  end

  defp radius_pair(h, v) do
    if valid_radius?(h) and valid_radius?(v), do: {:ok, {h, v}}, else: :skip
  end

  defp valid_radius?({:pct, f}), do: f >= 0
  defp valid_radius?(n) when is_number(n), do: n >= 0
  defp valid_radius?(_), do: false

  # backgrounds and borders keep their alpha: `{r, g, b, a}` when translucent
  defp color_value_rgba(v, current) do
    case Browser.Color.parse_rgba(v) do
      :current -> current
      c -> c
    end
  end

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
    if Browser.Calc.math?(v), do: math_length(v, env), else: plain_length(v, env)
  end

  # calc(), min(), max(), clamp(): a length, or nil when it can't be resolved to px
  defp math_length(v, env) do
    case Browser.Calc.eval(v, &unit_px(&1, env)) do
      {:ok, {:px, n}} -> n
      {:ok, {:num, n}} when n == 0 -> 0.0
      _ -> nil
    end
  end

  defp unit_px(unit, env) do
    case viewport_unit(unit, env) do
      nil when unit in ["ex", "ch"] -> env.fs * Map.get(env, unit_key(unit), 0.5)
      nil -> Browser.Calc.unit_px(unit, env.fs, env.root)
      px -> px
    end
  end

  defp unit_key("ex"), do: :ex
  defp unit_key("ch"), do: :ch

  # one viewport unit in px (1vw is a hundredth of the window's width)
  defp viewport_unit(unit, env) do
    vw = Map.get(env, :vw)
    vh = Map.get(env, :vh)

    cond do
      vw == nil -> nil
      unit in ["vw", "dvw", "svw", "lvw"] -> vw
      unit in ["vh", "dvh", "svh", "lvh"] -> vh
      unit == "vmin" -> min(vw, vh)
      unit == "vmax" -> max(vw, vh)
      true -> nil
    end
  end

  defp plain_length(v, env) do
    case scan_num(v) do
      {n, unit} when is_float(n) ->
        if lower?(unit), do: length_value(n, unit, env), else: nil

      _ ->
        nil
    end
  end

  # `[+-]? (digits [. digits?] | . digits)` at the start of `text`: {float, rest}, or nil. By
  # hand, as every length of every element of a page goes through here.
  defp scan_num(<<s, rest::binary>>) when s in [?+, ?-] do
    with {n, after_num} <- scan_unsigned(rest), do: {if(s == ?-, do: -n, else: n), after_num}
  end

  defp scan_num(text), do: scan_unsigned(text)

  defp scan_unsigned(text) do
    {int, after_int} = scan_digits(text, 0)

    {frac, after_frac} =
      case after_int do
        <<?., more::binary>> ->
          {n, rest} = scan_digits(more, 0)
          {binary_part(more, 0, n), rest}

        _ ->
          {"", after_int}
      end

    if int == 0 and frac == "" do
      nil
    else
      whole = if int == 0, do: "0", else: binary_part(text, 0, int)
      {n, _} = Float.parse(whole <> "." <> if(frac == "", do: "0", else: frac))
      {n, after_frac}
    end
  end

  defp scan_digits(<<c, rest::binary>>, n) when c in ?0..?9, do: scan_digits(rest, n + 1)
  defp scan_digits(rest, n), do: {n, rest}

  defp lower?(<<c, rest::binary>>) when c in ?a..?z, do: lower?(rest)
  defp lower?(""), do: true
  defp lower?(_), do: false

  defp length_value(n, unit, env) do
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
      "ex" -> n * env.fs * Map.get(env, :ex, 0.5)
      # the width of a "0": near 0.6em in the monospace fonts that `ch` is mostly used with
      "ch" -> n * env.fs * Map.get(env, :ch, 0.6)
      u -> if px = viewport_unit(u, env), do: n * px
    end
  end

  # "12.5%" -> 0.125, nil when it is not a percentage
  defp percentage(v) do
    case scan_num(v) do
      {n, "%"} -> n / 100
      _ -> nil
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
end
