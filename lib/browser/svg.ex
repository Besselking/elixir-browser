defmodule Browser.Svg do
  @moduledoc """
  A small SVG renderer.

  `from_source/1` (an `.svg` file) and `from_element/1` (an `<svg>` inside an HTML page)
  give a *scene*; `render/4` draws a scene into a `w` x `h` box and returns a display list
  for the painter, in coordinates relative to the box:

    * `%{kind: :path, segments: [...], fill: nil | %{paint:, rule:}, stroke: nil | %{...}}`
      with segments as in `Browser.Svg.PathData` (absolute, after all transforms)
    * `%{kind: :text, x:, y:, text:, size:, color:, anchor:, bold:, italic:, mono:}`

  A paint is `{:color, {r, g, b, a}}`, `{:linear, {x1, y1, x2, y2}, stops}` or
  `{:radial, {cx, cy, r, fx, fy}, stops}`, with stops as `[{offset, {r, g, b, a}}]`.

  Supported: `path`, `rect`, `circle`, `ellipse`, `line`, `polyline`, `polygon`, `text`, `g`,
  `a`, `switch`, nested `svg`, `use` / `symbol`, gradients (with `href` inheritance,
  `gradientUnits` and `gradientTransform`), `transform`, `viewBox` with
  `preserveAspectRatio`, fill/stroke with opacities, `currentColor`, caps, joins and dashes.
  Clipping, masks, filters, patterns, markers and embedded images are ignored.

  Style comes from the element's computed CSS (`"@computed"`, so page stylesheets and
  presentation attributes apply, see `Browser.Style`), falling back to the attributes.
  """

  alias Browser.{Color, HTML, Style}
  alias Browser.Svg.PathData

  @default_size {300.0, 150.0}

  @inheritable ~w(fill stroke stroke-width fill-opacity stroke-opacity fill-rule stroke-linecap
                  stroke-linejoin stroke-miterlimit stroke-dasharray text-anchor font-size
                  font-weight font-style font-family)

  # -- scenes -------------------------------------------------------------------------

  @doc "Parses an `.svg` document: `{:ok, scene}` or `:error` if it holds no `<svg>`."
  def from_source(text) when is_binary(text) do
    text =
      text
      |> String.replace_invalid()
      |> String.replace_prefix("﻿", "")
      |> then(&Regex.replace(~r/<!\[CDATA\[(.*?)\]\]>/s, &1, "\\1"))

    nodes = HTML.parse(text)

    case find(nodes, "svg") do
      nil ->
        :error

      svg ->
        css = svg |> descendants("style") |> Enum.map_join("\n", &text_of/1)
        index = Style.index([{:ua, Style.ua_css()}, {:author, css}])

        case Style.prune([svg], index) do
          [styled] -> {:ok, from_element(styled)}
          [] -> :error
        end
    end
  end

  @doc """
  A scene for an `<svg>` element (ideally one with computed styles). `defs` holds elements
  elsewhere in the page that `<use>` and gradients may refer to (see `collect_ids/1`).
  """
  def from_element({:element, "svg", attrs, _kids} = el, defs \\ %{}) do
    %{
      root: el,
      ids: Map.merge(defs, collect_ids(el)),
      viewbox: attrs |> attr_value("viewbox") |> viewbox(),
      width: attrs |> attr_value("width") |> plength(),
      height: attrs |> attr_value("height") |> plength(),
      par: attrs |> attr_value("preserveaspectratio") |> preserve_aspect_ratio()
    }
  end

  @doc """
  The size the document asks for, `{w, h}` in px: its `width`/`height`, else its `viewBox`,
  else the default 300x150. A missing dimension follows the other and the aspect ratio.
  """
  def intrinsic(%{width: w, height: h, viewbox: vb}) do
    w = if is_number(w), do: w
    h = if is_number(h), do: h

    case {w, h, vb} do
      {w, h, _} when w != nil and h != nil -> {w, h}
      {w, nil, {_, _, vw, vh}} when w != nil and vw > 0 -> {w, w * vh / vw}
      {nil, h, {_, _, vw, vh}} when h != nil and vh > 0 -> {h * vw / vh, h}
      {nil, nil, {_, _, vw, vh}} when vw > 0 and vh > 0 -> {vw, vh}
      _ -> @default_size
    end
  end

  # -- tree helpers ----------------------------------------------------------------------

  defp find(nodes, tag) when is_list(nodes), do: Enum.find_value(nodes, &find(&1, tag))
  defp find({:element, tag, _, _} = el, tag), do: el
  defp find({:element, _, _, kids}, tag), do: find(kids, tag)
  defp find(_, _), do: nil

  defp descendants({:element, _, _, kids}, tag) do
    Enum.flat_map(kids, fn
      {:element, ^tag, _, _} = el -> [el | descendants(el, tag)]
      {:element, _, _, _} = el -> descendants(el, tag)
      _ -> []
    end)
  end

  defp text_of({:element, _, _, kids}) do
    Enum.map_join(kids, fn
      {:text, t} -> t
      {:element, _, _, _} = el -> text_of(el)
    end)
  end

  @doc """
  What `<use>` and gradients in any inline `<svg>` of a page may refer to: the ids inside
  the page's `<svg>` elements. Sprite sheets are often hidden (`display: none`) and so are
  missing from the styled tree; `raw` has them, `styled` has the computed styles.
  """
  def defs(raw, styled), do: Map.merge(svg_ids(raw), svg_ids(styled))

  defp svg_ids(nodes) do
    Enum.reduce(nodes, %{}, fn
      {:element, "svg", _, _} = el, acc -> Map.merge(acc, collect_ids(el), fn _, a, _ -> a end)
      {:element, _, _, kids}, acc -> Map.merge(acc, svg_ids(kids), fn _, a, _ -> a end)
      _, acc -> acc
    end)
  end

  @doc """
  Every element with an `id` under `nodes`, as `%{id => element}` (first one wins).

  What an element got only by inheriting from its parent is taken out of its computed
  style: referenced content inherits from the `<use>` that draws it instead.
  """
  def collect_ids(nodes), do: nodes |> List.wrap() |> Enum.reduce(%{}, &collect_ids(&1, &2, nil))

  defp collect_ids({:text, _}, acc, _parent), do: acc

  defp collect_ids({:element, _, attrs, kids} = el, acc, parent) do
    acc =
      case attr_value(attrs, "id") do
        nil -> acc
        id -> Map.put_new(acc, id, strip_inherited(el, parent))
      end

    own = computed_of(attrs)
    Enum.reduce(kids, acc, &collect_ids(&1, &2, own))
  end

  defp computed_of(attrs) do
    case List.keyfind(attrs, "@computed", 0) do
      {_, map} when is_map(map) -> map
      _ -> nil
    end
  end

  @inherited_props @inheritable ++ ["color", "visibility"]

  defp strip_inherited({:element, tag, attrs, kids}, parent) do
    own = computed_of(attrs)

    attrs =
      case own do
        nil -> attrs
        map -> List.keyreplace(attrs, "@computed", 0, {"@computed", drop_inherited(map, parent)})
      end

    {:element, tag, attrs, Enum.map(kids, &strip_inherited(&1, own))}
  end

  defp strip_inherited(other, _parent), do: other

  defp drop_inherited(map, nil), do: Map.drop(map, @inherited_props)

  defp drop_inherited(map, parent) do
    Enum.reduce(@inherited_props, map, fn key, acc ->
      if Map.get(acc, key) == Map.get(parent, key), do: Map.delete(acc, key), else: acc
    end)
  end

  defp attr_value(attrs, name) do
    case List.keyfind(attrs, name, 0) do
      {_, v} when is_binary(v) -> v
      _ -> nil
    end
  end

  # -- parsing small values --------------------------------------------------------------

  defp viewbox(nil), do: nil

  defp viewbox(text) do
    case text |> String.split(~r/[\s,]+/, trim: true) |> Enum.map(&number/1) do
      [x, y, w, h]
      when is_number(x) and is_number(y) and is_number(w) and is_number(h) and w > 0 and h > 0 ->
        {x, y, w, h}

      _ ->
        nil
    end
  end

  defp preserve_aspect_ratio(nil), do: {:mid, :mid, :meet}

  defp preserve_aspect_ratio(text) do
    parts = text |> String.downcase() |> String.split()
    parts = if hd_or(parts) == "defer", do: tl(parts), else: parts

    case parts do
      ["none" | _] ->
        :none

      [align | rest] ->
        {x, y} = alignment(align)
        {x, y, if(rest == ["slice"], do: :slice, else: :meet)}

      [] ->
        {:mid, :mid, :meet}
    end
  end

  defp hd_or([h | _]), do: h
  defp hd_or([]), do: nil

  defp alignment(align) do
    x =
      if String.contains?(align, "xmin"),
        do: :min,
        else: if(String.contains?(align, "xmax"), do: :max, else: :mid)

    y =
      if String.contains?(align, "ymin"),
        do: :min,
        else: if(String.contains?(align, "ymax"), do: :max, else: :mid)

    {x, y}
  end

  defp number(nil), do: nil

  defp number(text) do
    case Regex.run(~r/\A\s*([+-]?(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?)\s*\z/, text) do
      [_, n] -> to_float(n)
      nil -> nil
    end
  end

  defp to_float(n) do
    case Float.parse(n) do
      {f, ""} -> f
      _ -> to_float_slow(n)
    end
  end

  defp to_float_slow(n) do
    n = if String.starts_with?(n, ["+", "-"]), do: n, else: "+" <> n
    n = Regex.replace(~r/\A([+-])\./, n, "\\g{1}0.")
    n = Regex.replace(~r/\.(?=[eE]|\z)/, n, ".0")
    n = if String.contains?(n, [".", "e", "E"]), do: n, else: n <> ".0"
    {f, _} = Float.parse(String.trim_leading(n, "+"))
    f
  end

  # a length: px float, {:pct, fraction}, or nil
  defp plength(nil), do: nil

  defp plength(text) do
    case Regex.run(
           ~r/\A\s*([+-]?(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?)\s*(px|pt|pc|em|rem|ex|in|cm|mm|%)?\s*\z/,
           text
         ) do
      [_, n, "%"] -> {:pct, to_float(n) / 100}
      [_, n, unit] -> to_float(n) * unit_scale(unit)
      [_, n] -> to_float(n)
      nil -> nil
    end
  end

  defp unit_scale("px"), do: 1.0
  defp unit_scale("pt"), do: 4 / 3
  defp unit_scale("pc"), do: 16.0
  defp unit_scale("em"), do: 16.0
  defp unit_scale("rem"), do: 16.0
  defp unit_scale("ex"), do: 8.0
  defp unit_scale("in"), do: 96.0
  defp unit_scale("cm"), do: 96 / 2.54
  defp unit_scale("mm"), do: 96 / 25.4

  # px for a length given the size `base` percentages refer to
  defp px(nil, _base, default), do: default
  defp px({:pct, f}, base, _default), do: f * base
  defp px(n, _base, _default) when is_number(n), do: n

  # -- matrices -----------------------------------------------------------------------------
  # {a, b, c, d, e, f}: x' = a*x + c*y + e, y' = b*x + d*y + f

  @identity {1.0, 0.0, 0.0, 1.0, 0.0, 0.0}

  @doc "The matrix for a `transform` attribute, or the identity."
  def parse_transform(nil), do: @identity

  def parse_transform(text) do
    ~r/([a-zA-Z]+)\s*\(([^)]*)\)/
    |> Regex.scan(text)
    |> Enum.reduce(@identity, fn [_, name, args], acc ->
      nums = args |> String.split(~r/[\s,]+/, trim: true) |> Enum.map(&number/1)

      if Enum.any?(nums, &is_nil/1),
        do: acc,
        else: multiply(acc, one_transform(String.downcase(name), nums))
    end)
  end

  defp one_transform("matrix", [a, b, c, d, e, f]), do: {a, b, c, d, e, f}
  defp one_transform("translate", [tx]), do: {1.0, 0.0, 0.0, 1.0, tx, 0.0}
  defp one_transform("translate", [tx, ty]), do: {1.0, 0.0, 0.0, 1.0, tx, ty}
  defp one_transform("scale", [s]), do: {s, 0.0, 0.0, s, 0.0, 0.0}
  defp one_transform("scale", [sx, sy]), do: {sx, 0.0, 0.0, sy, 0.0, 0.0}
  defp one_transform("rotate", [a]), do: rotation(a)

  defp one_transform("rotate", [a, cx, cy]) do
    {1.0, 0.0, 0.0, 1.0, cx, cy}
    |> multiply(rotation(a))
    |> multiply({1.0, 0.0, 0.0, 1.0, -cx, -cy})
  end

  defp one_transform("skewx", [a]), do: {1.0, 0.0, :math.tan(rad(a)), 1.0, 0.0, 0.0}
  defp one_transform("skewy", [a]), do: {1.0, :math.tan(rad(a)), 0.0, 1.0, 0.0, 0.0}
  defp one_transform(_name, _args), do: @identity

  defp rotation(a) do
    {c, s} = {:math.cos(rad(a)), :math.sin(rad(a))}
    {c, s, -s, c, 0.0, 0.0}
  end

  defp rad(deg), do: deg * :math.pi() / 180

  @doc "`multiply(m1, m2)` applies `m2` first, then `m1`."
  def multiply({a1, b1, c1, d1, e1, f1}, {a2, b2, c2, d2, e2, f2}) do
    {
      a1 * a2 + c1 * b2,
      b1 * a2 + d1 * b2,
      a1 * c2 + c1 * d2,
      b1 * c2 + d1 * d2,
      a1 * e2 + c1 * f2 + e1,
      b1 * e2 + d1 * f2 + f1
    }
  end

  defp point({a, b, c, d, e, f}, x, y), do: {a * x + c * y + e, b * x + d * y + f}

  # how much the matrix scales lengths, on average
  defp scale_factor({a, b, c, d, _, _}), do: :math.sqrt(abs(a * d - b * c))

  defp transform_segments(segments, m) do
    Enum.map(segments, fn
      {:M, x, y} ->
        {x, y} = point(m, x, y)
        {:M, x, y}

      {:L, x, y} ->
        {x, y} = point(m, x, y)
        {:L, x, y}

      {:C, x1, y1, x2, y2, x, y} ->
        {x1, y1} = point(m, x1, y1)
        {x2, y2} = point(m, x2, y2)
        {x, y} = point(m, x, y)
        {:C, x1, y1, x2, y2, x, y}

      :Z ->
        :Z
    end)
  end

  # the box around all points of the segments (control points included), or nil
  defp bounds(segments) do
    points =
      Enum.flat_map(segments, fn
        {:M, x, y} -> [{x, y}]
        {:L, x, y} -> [{x, y}]
        {:C, x1, y1, x2, y2, x, y} -> [{x1, y1}, {x2, y2}, {x, y}]
        :Z -> []
      end)

    case points do
      [] ->
        nil

      _ ->
        xs = Enum.map(points, &elem(&1, 0))
        ys = Enum.map(points, &elem(&1, 1))
        {x0, y0} = {Enum.min(xs), Enum.min(ys)}
        {x0, y0, Enum.max(xs) - x0, Enum.max(ys) - y0}
    end
  end

  # -- rendering ------------------------------------------------------------------------------

  @doc """
  The display list for `scene` drawn into a `w` x `h` box. Options: `current:` the colour for
  `currentColor`, as `{r, g, b, a}` (default black).
  """
  def render(scene, w, h, opts \\ []) do
    current = Keyword.get(opts, :current, {0, 0, 0, 255})
    vb = view_box(scene, w, h)
    {_, _, vw, vh} = vb

    state = %{
      m: fit(scene.par, vb, w, h),
      current: current_color(scene.root, current),
      opacity: 1.0,
      ids: scene.ids,
      viewport: {vw, vh},
      inherit: %{},
      depth: 0
    }

    scene.root |> children_of() |> Enum.flat_map(&node(&1, state))
  end

  # the user-space rectangle shown in the box
  defp view_box(scene, w, h) do
    case {scene.viewbox, scene.width, scene.height} do
      {{_, _, _, _} = vb, _, _} ->
        vb

      {nil, sw, sh} when is_number(sw) and is_number(sh) and sw > 0 and sh > 0 ->
        {0.0, 0.0, sw, sh}

      _ ->
        {0.0, 0.0, w * 1.0, h * 1.0}
    end
  end

  defp current_color(el, default) do
    case prop(el, "color") do
      {r, g, b} -> {r, g, b, 255}
      _ -> default
    end
  end

  defp children_of({:element, _, _, kids}), do: kids

  defp fit(:none, {minx, miny, vw, vh}, w, h) do
    {sx, sy} = {w / vw, h / vh}
    {sx, 0.0, 0.0, sy, -minx * sx, -miny * sy}
  end

  defp fit({ax, ay, mode}, {minx, miny, vw, vh}, w, h) do
    s = if mode == :slice, do: max(w / vw, h / vh), else: min(w / vw, h / vh)
    tx = align(ax) * (w - vw * s) - minx * s
    ty = align(ay) * (h - vh * s) - miny * s
    {s, 0.0, 0.0, s, tx, ty}
  end

  defp align(:min), do: 0.0
  defp align(:mid), do: 0.5
  defp align(:max), do: 1.0

  # -- nodes -----------------------------------------------------------------------------------

  @skipped ~w(defs lineargradient radialgradient stop clippath mask marker pattern symbol style
              title desc metadata script filter foreignobject image)

  defp node({:text, _}, _state), do: []
  defp node({:element, tag, _, _}, _state) when tag in @skipped, do: []

  defp node({:element, tag, attrs, kids} = el, state) do
    state = enter(el, state)

    cond do
      prop(el, "display") == "none" -> []
      tag in ~w(g svg a switch) -> Enum.flat_map(kids, &node(&1, state))
      tag == "use" -> use_element(attrs, state)
      prop(el, "visibility") in ["hidden", "collapse"] -> []
      tag == "text" -> text(el, state)
      tag in ~w(path rect circle ellipse line polyline polygon) -> shape(el, state)
      true -> []
    end
  end

  # the element's own transform and opacity apply to it and everything inside
  defp enter({:element, _tag, attrs, _kids} = el, state) do
    m = multiply(state.m, parse_transform(attr_value(attrs, "transform")))
    opacity = state.opacity * (opacity_of(el, "opacity", state) || 1.0)

    inherit =
      Enum.reduce(@inheritable, state.inherit, fn name, acc ->
        case prop(el, name) do
          nil -> acc
          v -> Map.put(acc, name, v)
        end
      end)

    %{state | m: m, opacity: opacity, current: current_color(el, state.current), inherit: inherit}
  end

  defp opacity_of(el, name, state) do
    case p(el, name, state) do
      v when is_float(v) -> v
      v when is_binary(v) -> clamp01(number(v) || percent(v))
      _ -> nil
    end
  end

  defp percent(v) do
    case plength(v) do
      {:pct, f} -> f
      _ -> nil
    end
  end

  defp clamp01(nil), do: nil
  defp clamp01(v), do: v |> max(0.0) |> min(1.0)

  # an inherited property: the element's own value, else what the nearest `use` (or parent) set
  defp p(el, name, state), do: prop(el, name) || Map.get(state.inherit, name)

  # computed CSS first, then the attribute
  defp prop({:element, _, attrs, _}, name) do
    case List.keyfind(attrs, "@computed", 0) do
      {_, %{^name => v}} -> v
      _ -> attr_value(attrs, name)
    end
  end

  # -- use -----------------------------------------------------------------------------------------

  defp use_element(attrs, %{depth: depth} = state) when depth < 8 do
    ref = attr_value(attrs, "href") || attr_value(attrs, "xlink:href")

    with "#" <> id <- ref,
         %{^id => {:element, tag, rattrs, rkids}} <- state.ids do
      {x, y} =
        {px(plength(attr_value(attrs, "x")), 0, 0.0), px(plength(attr_value(attrs, "y")), 0, 0.0)}

      state = %{state | m: multiply(state.m, {1.0, 0.0, 0.0, 1.0, x, y}), depth: depth + 1}
      target = {:element, tag, rattrs, rkids}

      case tag do
        t when t in ~w(symbol svg) ->
          state = enter(target, state)
          Enum.flat_map(rkids, &node(&1, state))

        _ ->
          node(target, state)
      end
    else
      _ -> []
    end
  end

  defp use_element(_attrs, _state), do: []

  # -- shapes --------------------------------------------------------------------------------------

  defp shape({:element, tag, attrs, _} = el, state) do
    {vw, vh} = state.viewport
    a = fn name -> attr_value(attrs, name) end
    len = fn name, base -> px(plength(a.(name)), base, 0.0) end
    diag = :math.sqrt((vw * vw + vh * vh) / 2)

    segments =
      case tag do
        "path" ->
          PathData.parse(a.("d") || "")

        "rect" ->
          rect(
            len.("x", vw),
            len.("y", vh),
            len.("width", vw),
            len.("height", vh),
            a.("rx"),
            a.("ry"),
            vw,
            vh
          )

        "circle" ->
          ellipse(len.("cx", vw), len.("cy", vh), len.("r", diag), len.("r", diag))

        "ellipse" ->
          ellipse(len.("cx", vw), len.("cy", vh), len.("rx", vw), len.("ry", vh))

        "line" ->
          [{:M, len.("x1", vw), len.("y1", vh)}, {:L, len.("x2", vw), len.("y2", vh)}]

        "polyline" ->
          poly(a.("points"), false)

        "polygon" ->
          poly(a.("points"), true)
      end

    draw(el, segments, tag, state)
  end

  defp rect(_x, _y, w, h, _rx, _ry, _vw, _vh) when w <= 0 or h <= 0, do: []

  defp rect(x, y, w, h, rx_attr, ry_attr, vw, vh) do
    rx = px(plength(rx_attr), vw, nil)
    ry = px(plength(ry_attr), vh, nil)
    {rx, ry} = {rx || ry || 0.0, ry || rx || 0.0}
    {rx, ry} = {min(max(rx, 0.0), w / 2), min(max(ry, 0.0), h / 2)}

    if rx == 0.0 or ry == 0.0 do
      [{:M, x, y}, {:L, x + w, y}, {:L, x + w, y + h}, {:L, x, y + h}, :Z]
    else
      [{:M, x + rx, y}, {:L, x + w - rx, y}] ++
        PathData.arc(x + w - rx, y, rx, ry, 0, false, true, x + w, y + ry) ++
        [{:L, x + w, y + h - ry}] ++
        PathData.arc(x + w, y + h - ry, rx, ry, 0, false, true, x + w - rx, y + h) ++
        [{:L, x + rx, y + h}] ++
        PathData.arc(x + rx, y + h, rx, ry, 0, false, true, x, y + h - ry) ++
        [{:L, x, y + ry}] ++
        PathData.arc(x, y + ry, rx, ry, 0, false, true, x + rx, y) ++ [:Z]
    end
  end

  defp ellipse(_cx, _cy, rx, ry) when rx <= 0 or ry <= 0, do: []

  defp ellipse(cx, cy, rx, ry) do
    [{:M, cx + rx, cy}] ++
      PathData.arc(cx + rx, cy, rx, ry, 0, false, true, cx, cy + ry) ++
      PathData.arc(cx, cy + ry, rx, ry, 0, false, true, cx - rx, cy) ++
      PathData.arc(cx - rx, cy, rx, ry, 0, false, true, cx, cy - ry) ++
      PathData.arc(cx, cy - ry, rx, ry, 0, false, true, cx + rx, cy) ++ [:Z]
  end

  defp poly(nil, _close?), do: []

  defp poly(points, close?) do
    nums = points |> String.split(~r/[\s,]+/, trim: true) |> Enum.map(&number/1)

    pairs =
      nums
      |> Enum.take_while(&is_number/1)
      |> Enum.chunk_every(2, 2, :discard)
      |> Enum.map(fn [x, y] -> {x, y} end)

    case pairs do
      [{x, y} | rest] when rest != [] ->
        [{:M, x, y}] ++
          Enum.map(rest, fn {px, py} -> {:L, px, py} end) ++ if(close?, do: [:Z], else: [])

      _ ->
        []
    end
  end

  # -- painting a shape ----------------------------------------------------------------------------

  defp draw(_el, [], _tag, _state), do: []

  defp draw(el, segments, tag, state) do
    box = bounds(segments)
    final = transform_segments(segments, state.m)
    open? = tag in ["line", "polyline"] or not Enum.any?(segments, &(&1 == :Z))

    fill =
      if tag == "line",
        do: nil,
        else: paint(el, "fill", "black", box, state, "fill-opacity")

    stroke = stroke(el, box, state)

    fill_op = fill && %{paint: fill, rule: fill_rule(el, state)}

    cond do
      fill == nil and stroke == nil ->
        []

      stroke != nil and stroke.dash != nil ->
        # the toolkit has no dashed pens: the stroke becomes a path of its own, cut into dashes
        dashed = dash_segments(final, stroke.dash)

        List.wrap(
          fill_op &&
            %{kind: :path, segments: final, open?: open?, fill: fill_op, stroke: nil}
        ) ++
          [
            %{
              kind: :path,
              segments: dashed,
              open?: true,
              fill: nil,
              stroke: %{stroke | dash: nil}
            }
          ]

      true ->
        [%{kind: :path, segments: final, open?: open?, fill: fill_op, stroke: stroke}]
    end
  end

  # -- dashes ---------------------------------------------------------------------------------

  @flatten_steps 16

  @doc """
  Cuts a path into dashes: `pattern` is the on/off lengths (repeated, doubled when odd).
  Curves are flattened first. The result is a list of open sub-paths.
  """
  def dash_segments(segments, pattern) do
    pattern = if rem(length(pattern), 2) == 1, do: pattern ++ pattern, else: pattern

    segments
    |> flatten()
    |> Enum.flat_map(&dash_polyline(&1, pattern))
    |> List.flatten()
  end

  # [[{x, y}, ...]]: one point list per sub-path, closed ones end where they started
  defp flatten(segments) do
    {paths, current, _start} =
      Enum.reduce(segments, {[], [], nil}, fn
        {:M, x, y}, {paths, cur, _} ->
          {push(paths, cur), [{x, y}], {x, y}}

        {:L, x, y}, {paths, cur, start} ->
          {paths, [{x, y} | cur], start}

        :Z, {paths, [_ | _] = cur, start} ->
          {paths, [start | cur], start}

        :Z, acc ->
          acc

        {:C, x1, y1, x2, y2, x, y}, {paths, [{x0, y0} | _] = cur, start} ->
          pts =
            for i <- 1..@flatten_steps do
              t = i / @flatten_steps
              u = 1 - t

              {u * u * u * x0 + 3 * u * u * t * x1 + 3 * u * t * t * x2 + t * t * t * x,
               u * u * u * y0 + 3 * u * u * t * y1 + 3 * u * t * t * y2 + t * t * t * y}
            end

          {paths, Enum.reverse(pts) ++ cur, start}

        _, acc ->
          acc
      end)

    paths |> push(current) |> Enum.reverse()
  end

  defp push(paths, cur) when length(cur) < 2, do: paths
  defp push(paths, cur), do: [Enum.reverse(cur) | paths]

  defp dash_polyline(points, pattern) do
    state = %{pattern: pattern, index: 0, left: hd(pattern), on?: true, run: [], out: []}
    state = walk_dashes(points, state)
    state = if state.on? and length(state.run) >= 2, do: flush_run(state), else: state
    Enum.reverse(state.out)
  end

  defp flush_run(state) do
    [{x, y} | rest] = Enum.reverse(state.run)
    run = [{:M, x, y} | Enum.map(rest, fn {px, py} -> {:L, px, py} end)]
    %{state | out: [run | state.out], run: []}
  end

  defp walk_dashes([{x0, y0}, {x1, y1} | rest], state) do
    len = :math.sqrt((x1 - x0) * (x1 - x0) + (y1 - y0) * (y1 - y0))

    state = if state.on? and state.run == [], do: %{state | run: [{x0, y0}]}, else: state

    cond do
      len == 0 ->
        walk_dashes([{x1, y1} | rest], state)

      len <= state.left ->
        state = %{state | left: state.left - len}
        state = if state.on?, do: %{state | run: [{x1, y1} | state.run]}, else: state
        walk_dashes([{x1, y1} | rest], state)

      true ->
        t = state.left / len
        {mx, my} = {x0 + (x1 - x0) * t, y0 + (y1 - y0) * t}
        index = rem(state.index + 1, length(state.pattern))

        state =
          if state.on?,
            do: flush_run(%{state | run: [{mx, my} | state.run]}),
            else: %{state | run: [{mx, my}]}

        state = %{state | on?: not state.on?, index: index, left: Enum.at(state.pattern, index)}
        walk_dashes([{mx, my}, {x1, y1} | rest], state)
    end
  end

  defp walk_dashes(_points, state), do: state

  defp fill_rule(el, state),
    do: if(p(el, "fill-rule", state) == "evenodd", do: :evenodd, else: :nonzero)

  defp stroke(el, box, state) do
    with paint when paint != nil <- paint(el, "stroke", "none", box, state, "stroke-opacity") do
      width = px(plength(p(el, "stroke-width", state)), elem(state.viewport, 0), 1.0)

      if width > 0 do
        %{
          paint: paint,
          width: width * scale_factor(state.m),
          cap: cap(p(el, "stroke-linecap", state)),
          join: join(p(el, "stroke-linejoin", state)),
          miter: number(p(el, "stroke-miterlimit", state)) || 4.0,
          dash: dashes(p(el, "stroke-dasharray", state), scale_factor(state.m))
        }
      end
    end
  end

  defp cap("round"), do: :round
  defp cap("square"), do: :square
  defp cap(_), do: :butt

  defp join("round"), do: :round
  defp join("bevel"), do: :bevel
  defp join(_), do: :miter

  defp dashes(nil, _scale), do: nil
  defp dashes("none", _scale), do: nil

  defp dashes(text, scale) do
    nums = text |> String.split(~r/[\s,]+/, trim: true) |> Enum.map(&plength/1)

    if nums != [] and Enum.all?(nums, &is_number/1) and Enum.sum(nums) > 0,
      do: Enum.map(nums, &(&1 * scale))
  end

  # -- paints ----------------------------------------------------------------------------------------

  defp paint(el, name, default, box, state, opacity_name) do
    value = p(el, name, state) || default
    alpha = state.opacity * (opacity_of(el, opacity_name, state) || 1.0)
    resolve_paint(String.trim(value), box, state, alpha)
  end

  defp resolve_paint("none", _box, _state, _alpha), do: nil

  defp resolve_paint("url(" <> _ = value, box, state, alpha) do
    case Regex.run(~r/\Aurl\(\s*["']?#([^"')\s]+)["']?\s*\)\s*(.*)\z/s, value) do
      [_, id, fallback] ->
        case gradient(id, box, state, alpha) do
          nil ->
            if fallback == "",
              do: nil,
              else: resolve_paint(String.trim(fallback), box, state, alpha)

          paint ->
            paint
        end

      _ ->
        nil
    end
  end

  defp resolve_paint(value, _box, state, alpha) do
    color =
      case String.downcase(value) do
        "currentcolor" -> state.current
        "inherit" -> state.current
        _ -> Color.parse_alpha(value)
      end

    case color do
      {r, g, b, a} -> {:color, {r, g, b, round(a * alpha)}}
      _ -> nil
    end
  end

  # -- gradients -------------------------------------------------------------------------------------------

  defp gradient(id, box, state, alpha) do
    with %{^id => {:element, tag, attrs, kids}} when tag in ["lineargradient", "radialgradient"] <-
           state.ids,
         [_ | _] = stops <- gradient_stops({:element, tag, attrs, kids}, state, alpha) do
      chain = chain({:element, tag, attrs, kids}, state.ids, 5)

      get = fn name ->
        Enum.find_value(chain, fn {:element, _, a, _} -> attr_value(a, name) end)
      end

      units = if get.("gradientunits") == "userSpaceOnUse", do: :user, else: :bbox
      gt = parse_transform(get.("gradienttransform"))

      with {:ok, to_user} <- units_matrix(units, box) do
        m = state.m |> multiply(to_user) |> multiply(gt)
        build_gradient(tag, get, units, m, state, stops)
      else
        _ -> nil
      end
    else
      _ -> nil
    end
  end

  # the gradient element and the ones it inherits from through href
  defp chain(el, ids, depth), do: chain(el, ids, depth, [])

  defp chain({:element, _, attrs, _} = el, ids, depth, acc) when depth > 0 do
    acc = acc ++ [el]
    ref = attr_value(attrs, "href") || attr_value(attrs, "xlink:href")

    case ref && String.trim_leading(ref, "#") do
      nil -> acc
      id -> if next = Map.get(ids, id), do: chain(next, ids, depth - 1, acc), else: acc
    end
  end

  defp chain(_el, _ids, _depth, acc), do: acc

  defp units_matrix(:user, _box), do: {:ok, @identity}
  defp units_matrix(:bbox, {x, y, w, h}) when w > 0 and h > 0, do: {:ok, {w, 0.0, 0.0, h, x, y}}
  defp units_matrix(:bbox, _), do: :error

  defp build_gradient("lineargradient", get, units, m, state, stops) do
    {vw, vh} = state.viewport
    coord = fn name, default, base -> gradient_coord(get.(name), default, units, base) end
    {x1, y1} = point(m, coord.("x1", 0.0, vw), coord.("y1", 0.0, vh))
    {x2, y2} = point(m, coord.("x2", 1.0, vw), coord.("y2", 0.0, vh))
    {:linear, {x1, y1, x2, y2}, stops}
  end

  defp build_gradient("radialgradient", get, units, m, state, stops) do
    {vw, vh} = state.viewport
    coord = fn name, default, base -> gradient_coord(get.(name), default, units, base) end
    {cx, cy} = {coord.("cx", 0.5, vw), coord.("cy", 0.5, vh)}
    r = coord.("r", 0.5, :math.sqrt((vw * vw + vh * vh) / 2))
    {fx, fy} = {coord.("fx", cx, vw), coord.("fy", cy, vh)}
    {tcx, tcy} = point(m, cx, cy)
    {tfx, tfy} = point(m, fx, fy)
    {:radial, {tcx, tcy, r * scale_factor(m), tfx, tfy}, stops}
  end

  # a coordinate in bounding-box units (0..1, or a percentage) or in user units
  defp gradient_coord(nil, default, _units, _base), do: default

  defp gradient_coord(text, default, units, base) do
    case plength(text) do
      {:pct, f} -> if units == :bbox, do: f, else: f * base
      n when is_number(n) -> n
      nil -> default
    end
  end

  defp gradient_stops(el, state, alpha) do
    stops_el =
      el
      |> chain(state.ids, 5)
      |> Enum.find(fn {:element, _, _, kids} ->
        Enum.any?(kids, &match?({:element, "stop", _, _}, &1))
      end)

    case stops_el do
      nil ->
        []

      {:element, _, _, kids} ->
        kids
        |> Enum.filter(&match?({:element, "stop", _, _}, &1))
        |> Enum.map(&stop(&1, state, alpha))
        |> Enum.reject(&is_nil/1)
        |> monotonic()
    end
  end

  defp stop({:element, _, attrs, _} = el, state, alpha) do
    offset =
      case attr_value(attrs, "offset") |> plength() do
        {:pct, f} -> f
        n when is_number(n) -> n
        nil -> 0.0
      end

    color = prop(el, "stop-color") || "black"
    opacity = clamp01(number(prop(el, "stop-opacity") || "1")) || 1.0

    resolved =
      case String.downcase(color) do
        "currentcolor" -> state.current
        _ -> Color.parse_alpha(color)
      end

    case resolved do
      {r, g, b, a} -> {clamp01(offset), {r, g, b, round(a * opacity * alpha)}}
      _ -> nil
    end
  end

  defp monotonic(stops) do
    {out, _} =
      Enum.map_reduce(stops, 0.0, fn {offset, color}, max ->
        offset = max(offset, max)
        {{offset, color}, offset}
      end)

    out
  end

  # -- text --------------------------------------------------------------------------------------------------

  defp text({:element, _, attrs, _} = el, state) do
    {vw, vh} = state.viewport
    content = el |> text_of() |> String.split() |> Enum.join(" ")

    paint = paint(el, "fill", "black", nil, state, "fill-opacity")

    {x, y} =
      {px(plength(attr_value(attrs, "x")), vw, 0.0), px(plength(attr_value(attrs, "y")), vh, 0.0)}

    {tx, ty} = point(state.m, x, y)

    size =
      case p(el, "font-size", state) do
        n when is_number(n) -> n
        s when is_binary(s) -> px(plength(s), 16.0, 16.0)
        _ -> 16.0
      end

    with {:color, color} <- paint, true <- content != "" do
      [
        %{
          kind: :text,
          x: tx,
          y: ty,
          text: content,
          size: size * scale_factor(state.m),
          color: color,
          anchor: anchor(p(el, "text-anchor", state)),
          bold:
            p(el, "font-weight", state) in ["bold", "bolder"] or
              (number(p(el, "font-weight", state) || "") || 0) >= 600,
          italic: p(el, "font-style", state) in ["italic", "oblique"],
          mono: mono?(p(el, "font-family", state)),
          family: p(el, "font-family", state)
        }
      ]
    else
      _ -> []
    end
  end

  defp anchor("middle"), do: :middle
  defp anchor("end"), do: :end
  defp anchor(_), do: :start

  defp mono?(nil), do: false

  defp mono?(family) do
    first =
      family
      |> String.split(",")
      |> hd()
      |> String.trim()
      |> String.trim("\"")
      |> String.trim("'")
      |> String.downcase()

    first in ~w(monospace courier menlo monaco consolas)
  end
end
