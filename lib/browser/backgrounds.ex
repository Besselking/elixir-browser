defmodule Browser.Backgrounds do
  @moduledoc """
  CSS background images: parsing, and the geometry for painting them.

  Values are comma-separated lists of layers (the first layer is on top). Parsed:

    * `parse_images/1` -> `:none | {:url, url} | {:linear, dir, stops} | {:radial, opts, stops}`
      (repeating and conic gradients are not supported and read as `:none`)
    * `parse_repeat/1` -> `{x, y}` with `:repeat | :no_repeat`
    * `parse_position/1` -> `{x, y}`, each px, `{:pct, fraction}` or `{:from_end, px}`
    * `parse_size/1` -> `:cover | :contain | {w, h}`, each `:auto`, px or `{:pct, f}`
    * `shorthand/1` splits `background` into those longhands (as CSS text)

  `paint_layers/6` turns parsed layers plus the box geometry into what the painter
  draws, and `tiles/3` lists the positions of a repeated tile.
  """

  alias Browser.{Color, Fetch}

  # -- helpers ---------------------------------------------------------------------

  @doc "Splits on commas outside parentheses and quotes; trims and drops empty parts."
  def split_top(value) do
    {parts, cur, _depth, _quote} =
      value
      |> String.to_charlist()
      |> Enum.reduce({[], [], 0, nil}, fn c, {parts, cur, depth, quote} ->
        cond do
          quote != nil -> {parts, [c | cur], depth, if(c == quote, do: nil, else: quote)}
          c in [?", ?'] -> {parts, [c | cur], depth, c}
          c == ?( -> {parts, [c | cur], depth + 1, nil}
          c == ?) -> {parts, [c | cur], max(depth - 1, 0), nil}
          c == ?, and depth == 0 -> {[to_string(Enum.reverse(cur)) | parts], [], 0, nil}
          true -> {parts, [c | cur], depth, nil}
        end
      end)

    [to_string(Enum.reverse(cur)) | parts]
    |> Enum.reverse()
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  # whitespace-separated tokens, keeping function calls and quoted strings whole
  defp tokens(layer) do
    ~r/[\w-]*\((?:[^()]|\([^()]*\))*\)|"[^"]*"|'[^']*'|\S+/
    |> Regex.scan(layer)
    |> List.flatten()
  end

  # px for a CSS length; nil if it isn't one
  defp length_px(tok) do
    case Regex.run(~r/\A([+-]?(?:\d+\.?\d*|\.\d+))(px|em|rem|pt|cm|mm|in)?\z/, tok) do
      [_, n, unit] -> to_float(n) * unit_scale(unit)
      [_, n] -> if to_float(n) == 0.0, do: 0.0
      _ -> nil
    end
  end

  defp unit_scale("px"), do: 1.0
  defp unit_scale("em"), do: 16.0
  defp unit_scale("rem"), do: 16.0
  defp unit_scale("pt"), do: 4 / 3
  defp unit_scale("in"), do: 96.0
  defp unit_scale("cm"), do: 96 / 2.54
  defp unit_scale("mm"), do: 96 / 25.4

  defp to_float(n) do
    n = if String.starts_with?(n, ["+", "-"]), do: n, else: "+" <> n
    n = Regex.replace(~r/\A([+-])\./, n, "\\g{1}0.")
    n = if String.contains?(n, "."), do: n, else: n <> ".0"
    n |> String.trim_leading("+") |> String.to_float()
  end

  # a length or percentage: px float or {:pct, fraction}
  defp dimension(tok) do
    case Regex.run(~r/\A([+-]?(?:\d+\.?\d*|\.\d+))%\z/, tok) do
      [_, n] -> {:pct, to_float(n) / 100}
      nil -> length_px(tok)
    end
  end

  # -- urls ------------------------------------------------------------------------

  @doc """
  Rewrites every `url(...)` in `css` to `url("<absolute>")`, resolving against `base`.
  Data URLs and fragments are left alone.
  """
  def absolutize(css, base) do
    Regex.replace(~r/url\(\s*(?:"([^"]*)"|'([^']*)'|([^)\s]*))\s*\)/i, css, fn _all,
                                                                               dq,
                                                                               sq,
                                                                               bare ->
      url = Enum.find([dq, sq, bare], "", &(&1 != ""))

      cond do
        url == "" -> "url(\"\")"
        String.starts_with?(url, ["data:", "#"]) -> "url(\"#{url}\")"
        true -> "url(\"#{Fetch.resolve(base, url)}\")"
      end
    end)
  end

  # -- images ----------------------------------------------------------------------

  def parse_images(value), do: value |> split_top() |> Enum.map(&parse_image/1)

  @doc "Every `url(...)` image in a parsed image list."
  def urls(images), do: for({:url, u} <- images, do: u)

  defp parse_image(str) do
    s = String.trim(str)
    lower = String.downcase(s)

    cond do
      lower == "none" ->
        :none

      m = Regex.run(~r/\Aurl\(\s*(?:"([^"]*)"|'([^']*)'|([^)\s]*))\s*\)\z/i, s) ->
        [_ | caps] = m
        {:url, Enum.find(caps, "", &(&1 != ""))}

      m = Regex.run(~r/\A(repeating-)?linear-gradient\((.*)\)\z/is, s) ->
        if Enum.at(m, 1) == "", do: linear(Enum.at(m, 2)), else: :none

      m = Regex.run(~r/\A(repeating-)?radial-gradient\((.*)\)\z/is, s) ->
        if Enum.at(m, 1) == "", do: radial(Enum.at(m, 2)), else: :none

      true ->
        :none
    end
  end

  defp linear(inner) do
    [first | rest] = args = split_top(inner)

    {dir, stop_args} =
      case direction(first) do
        nil -> {{:angle, 180.0}, args}
        dir -> {dir, rest}
      end

    with [_, _ | _] = stops <- stops(stop_args), do: {:linear, dir, stops}, else: (_ -> :none)
  end

  defp direction(arg) do
    cond do
      m = Regex.run(~r/\A([+-]?(?:\d+\.?\d*|\.\d+))(deg|turn|rad|grad)\z/i, arg) ->
        n = to_float(Enum.at(m, 1))

        {:angle,
         case String.downcase(Enum.at(m, 2)) do
           "deg" -> n
           "turn" -> n * 360
           "rad" -> n * 180 / :math.pi()
           "grad" -> n * 0.9
         end}

      m = Regex.run(~r/\Ato\s+(top|bottom|left|right)(?:\s+(top|bottom|left|right))?\z/i, arg) ->
        sides =
          m
          |> tl()
          |> Enum.reject(&(&1 == ""))
          |> Enum.map(&(&1 |> String.downcase() |> String.to_atom()))

        {:to, sides}

      true ->
        nil
    end
  end

  defp radial(inner) do
    [first | rest] = args = split_top(inner)

    {opts, stop_args} =
      if Regex.match?(~r/\A(circle|ellipse|closest-|farthest-|at\s|\d)/i, first),
        do: {radial_opts(first), rest},
        else: {radial_opts(""), args}

    with [_, _ | _] = stops <- stops(stop_args), do: {:radial, opts, stops}, else: (_ -> :none)
  end

  defp radial_opts(arg) do
    lower = String.downcase(arg)
    [shape_size | at] = String.split(lower, ~r/\bat\b/, parts: 2)
    toks = String.split(shape_size)

    size =
      cond do
        "closest-side" in toks -> :closest_side
        "farthest-side" in toks -> :farthest_side
        "closest-corner" in toks -> :closest_corner
        true -> :farthest_corner
      end

    radii = for t <- toks, px = length_px(t), do: px

    shape =
      if "circle" in toks or (length(radii) == 1 and "ellipse" not in toks),
        do: :circle,
        else: :ellipse

    at =
      case at do
        [pos] -> position_pair(tokens(pos))
        [] -> {{:pct, 0.5}, {:pct, 0.5}}
      end

    %{shape: shape, size: if(radii != [], do: {:radii, radii}, else: size), at: at}
  end

  # "red 10% 20%" -> two stops; unparsable arguments (colour hints, junk) are skipped
  defp stops(args), do: Enum.flat_map(args, &stop/1)

  defp stop(arg) do
    case Regex.run(
           ~r/\A\s*(rgba?\([^)]*\)|hsla?\([^)]*\)|light-dark\(.*\)|#[0-9a-fA-F]+|[a-zA-Z]+)\s*(.*)\z/s,
           arg
         ) do
      [_, color, rest] ->
        case Color.parse_alpha(color) do
          nil ->
            []

          c ->
            positions = rest |> String.split() |> Enum.map(&dimension/1) |> Enum.take(2)

            case positions do
              [] -> [%{color: c, pos: nil}]
              ps -> for p <- ps, do: %{color: c, pos: stop_pos(p)}
            end
        end

      _ ->
        []
    end
  end

  defp stop_pos({:pct, _} = p), do: p
  defp stop_pos(px) when is_number(px), do: {:px, px}
  defp stop_pos(_), do: nil

  # -- repeat, position, size ------------------------------------------------------

  def parse_repeat(value), do: value |> split_top() |> Enum.map(&repeat_layer/1)

  defp repeat_layer(layer) do
    case layer |> String.downcase() |> String.split() do
      ["repeat-x"] -> {:repeat, :no_repeat}
      ["repeat-y"] -> {:no_repeat, :repeat}
      [one] -> {repeat_mode(one), repeat_mode(one)}
      [x, y | _] -> {repeat_mode(x), repeat_mode(y)}
      [] -> {:repeat, :repeat}
    end
  end

  # `space` and `round` are drawn like `repeat`
  defp repeat_mode("no-repeat"), do: :no_repeat
  defp repeat_mode(_), do: :repeat

  def parse_position(value), do: value |> split_top() |> Enum.map(&position_layer/1)

  defp position_layer(layer), do: layer |> String.downcase() |> tokens() |> position_pair()

  @doc false
  def position_pair(toks) do
    case toks do
      [] -> {0.0, 0.0}
      [a] -> single_position(a)
      [a, b] -> two_positions(a, b)
      _ -> edge_positions(toks)
    end
  end

  defp axis_keyword("left"), do: {:x, {:pct, 0.0}}
  defp axis_keyword("right"), do: {:x, {:pct, 1.0}}
  defp axis_keyword("top"), do: {:y, {:pct, 0.0}}
  defp axis_keyword("bottom"), do: {:y, {:pct, 1.0}}
  defp axis_keyword("center"), do: {:both, {:pct, 0.5}}
  defp axis_keyword(_), do: nil

  defp single_position(tok) do
    case axis_keyword(tok) do
      {:y, v} -> {{:pct, 0.5}, v}
      {_, v} -> {v, {:pct, 0.5}}
      nil -> {dimension(tok) || 0.0, {:pct, 0.5}}
    end
  end

  # "top left" and "left top" both work; lengths take the order x y
  defp two_positions(a, b) do
    case {axis_keyword(a), axis_keyword(b)} do
      {{:y, y}, {kind, x}} when kind in [:x, :both] -> {x, y}
      {{kind, x}, {:x, _}} when kind in [:x, :both] -> {x, {:pct, 0.5}}
      {{kind, x}, {kind2, y}} when kind in [:x, :both] and kind2 in [:y, :both] -> {x, y}
      {{:both, x}, nil} -> {x, dimension(b) || 0.0}
      {{:x, x}, nil} -> {x, dimension(b) || 0.0}
      {{:y, y}, nil} -> {dimension(b) || 0.0, y}
      {nil, {:y, y}} -> {dimension(a) || 0.0, y}
      {nil, {:both, y}} -> {dimension(a) || 0.0, y}
      {nil, _} -> {dimension(a) || 0.0, dimension(b) || 0.0}
      _ -> {0.0, 0.0}
    end
  end

  # "right 10px bottom 20px": an edge keyword may be followed by an offset from it
  defp edge_positions(toks) do
    {x, y, _} =
      Enum.reduce(toks, {{:pct, 0.0}, {:pct, 0.0}, nil}, fn tok, {x, y, edge} ->
        case axis_keyword(tok) do
          {:x, {:pct, 1.0}} -> {{:from_end, 0.0}, y, :x_end}
          {:y, {:pct, 1.0}} -> {x, {:from_end, 0.0}, :y_end}
          {:x, v} -> {v, y, :x}
          {:y, v} -> {x, v, :y}
          {:both, v} -> {v, y, :x}
          nil -> offset(tok, x, y, edge)
        end
      end)

    {x, y}
  end

  defp offset(tok, x, y, edge) do
    n = length_px(tok) || 0.0

    case edge do
      :x_end -> {{:from_end, n}, y, nil}
      :y_end -> {x, {:from_end, n}, nil}
      :x -> {n, y, nil}
      :y -> {x, n, nil}
      nil -> {x, y, nil}
    end
  end

  def parse_size(value), do: value |> split_top() |> Enum.map(&size_layer/1)

  defp size_layer(layer) do
    case layer |> String.downcase() |> String.split() do
      ["cover"] -> :cover
      ["contain"] -> :contain
      [w] -> {size_dim(w), :auto}
      [w, h | _] -> {size_dim(w), size_dim(h)}
      [] -> {:auto, :auto}
    end
  end

  defp size_dim("auto"), do: :auto
  defp size_dim(tok), do: dimension(tok) || :auto

  # -- the shorthand ---------------------------------------------------------------

  @repeat_words ~w(repeat repeat-x repeat-y no-repeat space round)
  @ignored_words ~w(scroll fixed local border-box padding-box content-box)

  @doc """
  Splits a `background` value into longhand CSS text:
  `%{color:, image:, repeat:, position:, size:}`. Anything the shorthand doesn't set
  gets its initial value, as in CSS.
  """
  def shorthand(value) do
    layers = value |> split_top() |> Enum.map(&shorthand_layer/1)
    last = List.last(layers) || %{color: nil}

    %{
      color: last.color || "transparent",
      image: join(layers, :image),
      repeat: join(layers, :repeat),
      position: join(layers, :position),
      size: join(layers, :size)
    }
  end

  defp join(layers, key), do: layers |> Enum.map(&Map.fetch!(&1, key)) |> Enum.join(", ")

  defp shorthand_layer(layer) do
    toks = layer |> String.replace(~r"/(?![^(]*\))", " / ") |> tokens()

    {acc, _} =
      Enum.reduce(
        toks,
        {%{color: nil, image: "none", repeat: "repeat", position: [], size: [], phase: :pos},
         nil},
        &shorthand_token/2
      )

    %{
      color: acc.color,
      image: acc.image,
      repeat: acc.repeat,
      position:
        if(acc.position == [],
          do: "0% 0%",
          else: acc.position |> Enum.reverse() |> Enum.join(" ")
        ),
      size: if(acc.size == [], do: "auto", else: acc.size |> Enum.reverse() |> Enum.join(" "))
    }
  end

  # a length in `ch`, which the style turns into pixels before this module sees it
  defp ch?(tok), do: Regex.match?(~r/\A[+-]?(?:\d+\.?\d*|\.\d+)ch\z/, tok)

  defp shorthand_token("/", {acc, x}), do: {%{acc | phase: :size}, x}

  defp shorthand_token(tok, {acc, x}) do
    lower = String.downcase(tok)

    cond do
      lower in @ignored_words ->
        {acc, x}

      lower in @repeat_words ->
        {%{acc | repeat: lower}, x}

      Regex.match?(~r/\A(url|[\w-]*gradient)\(/i, tok) or lower == "none" ->
        {%{acc | image: tok}, x}

      # after the slash only size values belong to the size; a colour can still follow
      acc.phase == :size and
          (lower in ~w(auto cover contain) or dimension(lower) != nil or ch?(lower)) ->
        {%{acc | size: [lower | acc.size]}, x}

      acc.phase == :pos and
          (lower in ~w(left right top bottom center auto cover contain) or dimension(lower) != nil or
             ch?(lower)) ->
        {%{acc | position: [lower | acc.position]}, x}

      Color.parse(tok) != nil ->
        {%{acc | color: tok}, x}

      true ->
        {acc, x}
    end
  end

  # -- gradients -------------------------------------------------------------------

  @doc """
  The gradient line of a linear gradient over a `w` x `h` box, `{x1, y1, x2, y2}` in the
  box's own coordinates (0% at the start, 100% at the end).
  """
  def linear_line(dir, w, h) do
    {dx, dy} =
      case dir do
        {:angle, deg} ->
          rad = deg * :math.pi() / 180
          {:math.sin(rad), -:math.cos(rad)}

        {:to, [side]} ->
          side_vector(side)

        {:to, sides} ->
          # a corner: the line is perpendicular to the diagonal through the other corners
          sx = if :right in sides, do: 1, else: -1
          sy = if :bottom in sides, do: 1, else: -1
          len = :math.sqrt(h * h + w * w)
          if len == 0.0, do: {0.0, 1.0}, else: {sx * h / len, sy * w / len}
      end

    half = (abs(w * dx) + abs(h * dy)) / 2
    {cx, cy} = {w / 2, h / 2}
    {cx - dx * half, cy - dy * half, cx + dx * half, cy + dy * half}
  end

  defp side_vector(:top), do: {0.0, -1.0}
  defp side_vector(:bottom), do: {0.0, 1.0}
  defp side_vector(:left), do: {-1.0, 0.0}
  defp side_vector(:right), do: {1.0, 0.0}

  @doc """
  Colour stops as `[{fraction, {r, g, b, a}}]` along a gradient line of `length` px:
  positions are made increasing, and stops without one are spread evenly. `current` is
  the colour for `currentcolor` stops.
  """
  def normalize_stops(stops, length, current) do
    n = length(stops)

    positioned =
      stops
      |> Enum.with_index()
      |> Enum.map(fn {s, i} ->
        pos =
          case s.pos do
            {:pct, f} -> f
            {:px, px} -> if length > 0, do: px / length, else: 0.0
            nil -> if(i == 0, do: 0.0, else: if(i == n - 1, do: 1.0))
          end

        {pos, if(s.color == :current, do: current, else: s.color)}
      end)

    positioned |> monotonic() |> spread()
  end

  defp monotonic(stops) do
    {out, _} =
      Enum.map_reduce(stops, nil, fn {pos, color}, max ->
        pos = if pos && max, do: max(pos, max), else: pos
        {{pos, color}, pos || max}
      end)

    out
  end

  # stops without a position share the space between their positioned neighbours
  defp spread(stops) do
    stops
    |> Enum.with_index()
    |> Enum.map(fn
      {{pos, color}, _} when pos != nil ->
        {pos, color}

      {{nil, color}, i} ->
        {prev_i, prev} = neighbour(stops, i, -1)
        {next_i, next} = neighbour(stops, i, 1)
        {prev + (next - prev) * (i - prev_i) / (next_i - prev_i), color}
    end)
  end

  defp neighbour(stops, i, step) do
    j = i + step

    case Enum.at(stops, j) do
      {pos, _} when pos != nil -> {j, pos}
      _ -> neighbour(stops, j, step)
    end
  end

  @doc """
  Centre and radii of a radial gradient over a `w` x `h` box: `{cx, cy, rx, ry}`.
  """
  def radial_geometry(%{shape: shape, size: size, at: {ax, ay}}, w, h) do
    cx = place(ax, w)
    cy = place(ay, h)
    {left, right, top, bottom} = {cx, w - cx, cy, h - cy}

    {rx, ry} =
      case {shape, size} do
        {_, {:radii, [r]}} ->
          {r, r}

        {_, {:radii, [rx, ry | _]}} ->
          {rx, ry}

        {:circle, :closest_side} ->
          r = Enum.min([left, right, top, bottom])
          {r, r}

        {:circle, :farthest_side} ->
          r = Enum.max([left, right, top, bottom])
          {r, r}

        {:circle, :closest_corner} ->
          r = corner(Enum.min([left, right]), Enum.min([top, bottom]))
          {r, r}

        {:circle, :farthest_corner} ->
          r = corner(Enum.max([left, right]), Enum.max([top, bottom]))
          {r, r}

        {:ellipse, :closest_side} ->
          {Enum.min([left, right]), Enum.min([top, bottom])}

        {:ellipse, :farthest_side} ->
          {Enum.max([left, right]), Enum.max([top, bottom])}

        # corner sizes keep the ratio of the corresponding side sizes
        {:ellipse, :closest_corner} ->
          scale_ellipse(Enum.min([left, right]), Enum.min([top, bottom]))

        {:ellipse, :farthest_corner} ->
          scale_ellipse(Enum.max([left, right]), Enum.max([top, bottom]))
      end

    {cx, cy, max(rx, 0.001), max(ry, 0.001)}
  end

  defp corner(dx, dy), do: :math.sqrt(dx * dx + dy * dy)
  defp scale_ellipse(sx, sy), do: {sx * :math.sqrt(2), sy * :math.sqrt(2)}

  defp place({:pct, f}, size), do: f * size
  defp place({:from_end, px}, size), do: size - px
  defp place(px, _size) when is_number(px), do: px

  # -- painting geometry -----------------------------------------------------------

  @doc """
  The layers to paint, bottom first. `spec` holds the parsed lists (`images`, `repeat`,
  `position`, `size`; the shorter lists repeat to match `images`), `area` is the box the
  images are positioned in and `clip` the box they are painted into, both
  `{x, y, w, h}`. `sizes` maps image urls to `{:ok, w, h}` or `{:svg, w, h, scene}` (images not loaded yet are
  skipped) and `current` is the colour for `currentcolor`.

  A layer is `%{kind: :image | :svg | :linear | :radial, tile: {x, y, w, h}, repeat: {rx, ry},
  clip: clip, ...}` where gradient geometry is relative to the tile's top-left corner.
  """
  def paint_layers(spec, area, clip, sizes, current) do
    {ax, ay, aw, ah} = area

    spec.images
    |> Enum.with_index()
    |> Enum.flat_map(fn {image, i} ->
      pick = fn list, default ->
        if list == [], do: default, else: Enum.at(list, rem(i, length(list)))
      end

      size = pick.(spec.size, {:auto, :auto})
      pos = pick.(spec.position, {0.0, 0.0})
      repeat = pick.(spec.repeat, {:repeat, :repeat})

      with {kind, payload, intrinsic} <- image_content(image, sizes),
           {tw, th} when tw >= 1 and th >= 1 <- tile_size(size, {aw, ah}, intrinsic) do
        tx = ax + place_offset(elem(pos, 0), aw - tw)
        ty = ay + place_offset(elem(pos, 1), ah - th)

        layer = %{
          kind: kind,
          tile: {round(tx), round(ty), round(tw), round(th)},
          repeat: repeat,
          clip: clip
        }

        [Map.merge(layer, finish(kind, payload, tw, th, current))]
      else
        _ -> []
      end
    end)
    |> Enum.reverse()
  end

  # {kind, payload, intrinsic size}; nil for what can't be painted (yet)
  defp image_content({:url, url}, sizes) do
    case sizes && Map.get(sizes, url) do
      {:ok, w, h} ->
        {:image, url, {w, h}}

      # a picture with a viewBox but no width or height has only a shape: `auto` sizes it to fit
      {:svg, w, h, %{width: sw, height: sh} = scene} ->
        {:svg, scene, if(is_number(sw) or is_number(sh), do: {w, h}, else: {w, h, :ratio})}

      {:svg, w, h, scene} ->
        {:svg, scene, {w, h}}

      _ ->
        nil
    end
  end

  defp image_content({:linear, dir, stops}, _sizes), do: {:linear, {dir, stops}, nil}
  defp image_content({:radial, opts, stops}, _sizes), do: {:radial, {opts, stops}, nil}
  defp image_content(_, _sizes), do: nil

  defp finish(:image, url, _tw, _th, _current), do: %{url: url}

  # vector images are drawn at the tile's size, so they stay sharp
  defp finish(:svg, scene, tw, th, current),
    do: %{ops: Browser.Svg.render(scene, tw, th, current: current)}

  defp finish(:linear, {dir, stops}, tw, th, current) do
    {x1, y1, x2, y2} = linear_line(dir, tw, th)
    len = :math.sqrt((x2 - x1) ** 2 + (y2 - y1) ** 2)
    %{line: {x1, y1, x2, y2}, stops: normalize_stops(stops, len, current)}
  end

  defp finish(:radial, {opts, stops}, tw, th, current) do
    {cx, cy, rx, ry} = radial_geometry(opts, tw, th)
    %{center: {cx, cy}, radii: {rx, ry}, stops: normalize_stops(stops, rx, current)}
  end

  defp place_offset({:pct, f}, free), do: f * free
  defp place_offset({:from_end, px}, free), do: free - px
  defp place_offset(px, _free) when is_number(px), do: px

  # the size of one tile in the positioning area; gradients have no intrinsic size
  defp tile_size({:auto, :auto}, area, {iw, ih, :ratio}), do: tile_size(:contain, area, {iw, ih})
  defp tile_size(size, area, {iw, ih, :ratio}), do: tile_size(size, area, {iw, ih})

  defp tile_size(size, {aw, ah}, intrinsic) do
    case {size, intrinsic} do
      {:cover, {iw, ih}} ->
        scaled({iw, ih}, max(aw / iw, ah / ih))

      {:contain, {iw, ih}} ->
        scaled({iw, ih}, min(aw / iw, ah / ih))

      {s, nil} when s in [:cover, :contain] ->
        {aw, ah}

      {{w, h}, nil} ->
        {dim(w, aw, aw), dim(h, ah, ah)}

      {{:auto, :auto}, {iw, ih}} ->
        {iw, ih}

      {{w, :auto}, {iw, ih}} ->
        tw = dim(w, aw, iw)
        {tw, tw * ih / iw}

      {{:auto, h}, {iw, ih}} ->
        th = dim(h, ah, ih)
        {th * iw / ih, th}

      {{w, h}, _} ->
        {dim(w, aw, aw), dim(h, ah, ah)}
    end
  end

  defp scaled({iw, ih}, f), do: {iw * f, ih * f}

  defp dim(:auto, _area, fallback), do: fallback
  defp dim({:pct, f}, area, _fallback), do: f * area
  defp dim(px, _area, _fallback) when is_number(px), do: px

  @max_tiles 4_000

  @doc """
  Top-left corners of the tiles to draw: the `tile` `{x, y, w, h}` repeated as `repeat`
  says, as far as it intersects `clip` (`{x, y, w, h}`), at most #{@max_tiles}.
  """
  def tiles({tx, ty, tw, th}, {rx, ry}, {cx, cy, cw, ch}) do
    xs = starts(tx, tw, cx, cw, rx)
    ys = starts(ty, th, cy, ch, ry)

    for(y <- ys, x <- xs, do: {x, y}) |> Enum.take(@max_tiles)
  end

  defp starts(t, _size, _c, _csize, :no_repeat), do: [t]

  defp starts(t, size, c, csize, :repeat) do
    first = t - ceil_div(t - c, size) * size
    Enum.take_while(Stream.iterate(first, &(&1 + size)), &(&1 < c + csize))
  end

  defp ceil_div(a, b), do: -Integer.floor_div(-a, b)
end
