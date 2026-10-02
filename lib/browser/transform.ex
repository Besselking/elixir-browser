defmodule Browser.Transform do
  @moduledoc """
  CSS transforms as affine matrices.

  A matrix is `{a, b, c, d, e, f}` and maps a point to `{a*x + c*y + e, b*x + d*y + f}` (the
  same as SVG and CSS `matrix()`).

  `matrix/3` reads the transform properties of an element's computed style (`transform`,
  `translate`, `rotate`, `scale` and `transform-origin`) for a border box of a given size and
  position, and gives the matrix that maps page coordinates to where the box is drawn: the
  transformations are applied about the box's `transform-origin` (its centre by default).
  """

  alias Browser.Calc

  @identity {1.0, 0.0, 0.0, 1.0, 0.0, 0.0}

  @doc "The properties that can transform an element."
  def props, do: ~w(transform translate rotate scale)

  @doc "True when the computed style `c` asks for any transformation."
  def transformed?(c) do
    Enum.any?(props(), fn prop ->
      case c[prop] do
        v when is_binary(v) -> String.trim(v) not in ["", "none"]
        _ -> false
      end
    end)
  end

  @doc """
  The matrix for `c` on the box `{x, y, w, h}`, or nil when it does nothing (or can't be
  worked out). Option `translate: false` leaves out translations, for boxes whose placement
  already took them into account.
  """
  def matrix(c, {x, y, w, h}, opts \\ []) do
    fs = if is_number(c["font-size"]), do: c["font-size"], else: 16.0
    units = &Calc.unit_px(&1, fs, 16.0)
    translate? = Keyword.get(opts, :translate, true)

    # the individual properties come first (translate, rotate, scale), then `transform`
    steps =
      [
        if(translate?, do: property_translate(c["translate"], w, h, units)),
        property_rotate(c["rotate"]),
        property_scale(c["scale"]),
        function_list(c["transform"], w, h, units, translate?)
      ]

    m = steps |> Enum.reject(&is_nil/1) |> Enum.reduce(@identity, &multiply(&2, &1))

    if m == @identity or not valid?(m) do
      nil
    else
      {ox, oy} = origin(c["transform-origin"], w, h, units)
      ox = x + ox
      oy = y + oy
      # move the origin to (0, 0), transform, move back
      multiply({1.0, 0.0, 0.0, 1.0, ox, oy}, multiply(m, {1.0, 0.0, 0.0, 1.0, -ox, -oy}))
    end
  end

  # a matrix that squashes everything flat can't be drawn
  defp valid?({a, b, c, d, _e, _f}), do: abs(a * d - b * c) > 1.0e-9

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

  @doc "The matrix as seen after the item it applies to has moved by `{dx, dy}`."
  def moved({a, b, c, d, e, f}, dx, dy) do
    {a, b, c, d, e + dx - (a * dx + c * dy), f + dy - (b * dx + d * dy)}
  end

  @doc "The matrix that undoes `m`, or nil when there is none."
  def invert({a, b, c, d, e, f}) do
    det = a * d - b * c

    if abs(det) < 1.0e-12 do
      nil
    else
      {d / det, -b / det, -c / det, a / det, (c * f - d * e) / det, (b * e - a * f) / det}
    end
  end

  @doc """
  The point at which an item, drawn through `matrices` (the innermost box first), appears
  under `{x, y}`: undoes the outermost transformation first. Nil when it can't be undone.
  """
  def unapply(matrices, x, y) do
    Enum.reduce_while(Enum.reverse(matrices), {x, y}, fn m, {px, py} ->
      case invert(m) do
        nil -> {:halt, nil}
        inverse -> {:cont, apply_to(inverse, px, py)}
      end
    end)
  end

  @doc "Where the matrix takes the point."
  def apply_to({a, b, c, d, e, f}, x, y), do: {a * x + c * y + e, b * x + d * y + f}

  # -- the individual properties -------------------------------------------------------------

  defp property_translate(nil, _w, _h, _units), do: nil

  defp property_translate(value, w, h, units) do
    case words(value) do
      [x] -> translation(x, "0", w, h, units)
      [x, y | _] -> translation(x, y, w, h, units)
      _ -> nil
    end
  end

  defp property_rotate(nil), do: nil

  defp property_rotate(value) do
    # `rotate: 45deg`, or an axis and an angle (`z 45deg`, only z is drawn)
    case words(value) do
      [angle] -> rotation(angle)
      ["z", angle] -> rotation(angle)
      _ -> nil
    end
  end

  defp property_scale(nil), do: nil

  defp property_scale(value) do
    case words(value) |> Enum.map(&scale_factor/1) do
      [sx] when is_number(sx) -> {sx, 0.0, 0.0, sx, 0.0, 0.0}
      [sx, sy | _] when is_number(sx) and is_number(sy) -> {sx, 0.0, 0.0, sy, 0.0, 0.0}
      _ -> nil
    end
  end

  # -- the transform function list ----------------------------------------------------------------

  defp function_list(nil, _w, _h, _units, _translate?), do: nil
  defp function_list("none", _w, _h, _units, _translate?), do: nil

  defp function_list(text, w, h, units, translate?) do
    functions = Regex.scan(~r/([a-zA-Z0-9]+)\s*\(((?:[^()]|\([^()]*\))*)\)/, text)

    if functions == [] do
      nil
    else
      Enum.reduce_while(functions, @identity, fn [_, name, args], acc ->
        case function(String.downcase(name), split_args(args), w, h, units, translate?) do
          :error -> {:halt, nil}
          m -> {:cont, multiply(acc, m)}
        end
      end)
    end
  end

  defp function("translate", args, w, h, units, translate?) do
    case args do
      [x] -> translation(x, "0", w, h, units, translate?)
      [x, y] -> translation(x, y, w, h, units, translate?)
      _ -> :error
    end
  end

  defp function("translatex", [x], w, h, units, t?), do: translation(x, "0", w, h, units, t?)
  defp function("translatey", [y], w, h, units, t?), do: translation("0", y, w, h, units, t?)

  defp function("translate3d", [x, y, _z], w, h, units, t?),
    do: translation(x, y, w, h, units, t?)

  defp function("scale", [s], _w, _h, _units, _t?), do: scaling(scale_factor(s), scale_factor(s))

  defp function("scale", [sx, sy], _w, _h, _units, _t?),
    do: scaling(scale_factor(sx), scale_factor(sy))

  defp function("scalex", [s], _w, _h, _units, _t?), do: scaling(scale_factor(s), 1.0)
  defp function("scaley", [s], _w, _h, _units, _t?), do: scaling(1.0, scale_factor(s))

  defp function("scale3d", [sx, sy, _], _w, _h, _units, _t?),
    do: scaling(scale_factor(sx), scale_factor(sy))

  defp function(name, [angle], _w, _h, _units, _t?) when name in ["rotate", "rotatez"],
    do: rotation(angle) || :error

  defp function("skewx", [angle], _w, _h, _units, _t?), do: skewing(angle, "0deg")
  defp function("skewy", [angle], _w, _h, _units, _t?), do: skewing("0deg", angle)
  defp function("skew", [x], _w, _h, _units, _t?), do: skewing(x, "0deg")
  defp function("skew", [x, y], _w, _h, _units, _t?), do: skewing(x, y)

  defp function("matrix", args, _w, _h, _units, _t?) do
    nums = Enum.map(args, &number/1)

    case nums do
      [a, b, c, d, e, f]
      when is_number(a) and is_number(b) and is_number(c) and is_number(d) and is_number(e) and
             is_number(f) ->
        {a, b, c, d, e, f}

      _ ->
        :error
    end
  end

  defp function(_name, _args, _w, _h, _units, _t?), do: :error

  defp translation(x, y, w, h, units, translate? \\ true) do
    if translate? do
      with tx when is_number(tx) <- length(x, w, units),
           ty when is_number(ty) <- length(y, h, units) do
        {1.0, 0.0, 0.0, 1.0, tx, ty}
      else
        _ -> :error
      end
    else
      @identity
    end
  end

  defp scaling(sx, sy) when is_number(sx) and is_number(sy), do: {sx, 0.0, 0.0, sy, 0.0, 0.0}
  defp scaling(_, _), do: :error

  defp rotation(angle) do
    case angle_rad(angle) do
      nil ->
        nil

      r ->
        {cos, sin} = {:math.cos(r), :math.sin(r)}
        {cos, sin, -sin, cos, 0.0, 0.0}
    end
  end

  defp skewing(ax, ay) do
    with rx when is_number(rx) <- angle_rad(ax),
         ry when is_number(ry) <- angle_rad(ay) do
      {1.0, :math.tan(ry), :math.tan(rx), 1.0, 0.0, 0.0}
    else
      _ -> :error
    end
  end

  # -- transform-origin ---------------------------------------------------------------------------

  # -> {x, y} offsets within the box; the centre by default
  defp origin(nil, w, h, _units), do: {w / 2, h / 2}

  defp origin(value, w, h, units) do
    case words(value) do
      [a] -> origin_pair(a, "center", w, h, units)
      [a, b | _] -> origin_pair(a, b, w, h, units)
      _ -> {w / 2, h / 2}
    end
  end

  defp origin_pair(a, b, w, h, units) do
    # keywords may come in either order: `top left`
    {a, b} = if a in ["top", "bottom"] or b in ["left", "right"], do: {b, a}, else: {a, b}
    {origin_value(a, w, units, w / 2), origin_value(b, h, units, h / 2)}
  end

  defp origin_value("left", _size, _units, _default), do: 0.0
  defp origin_value("top", _size, _units, _default), do: 0.0
  defp origin_value("center", size, _units, _default), do: size / 2
  defp origin_value("right", size, _units, _default), do: size * 1.0
  defp origin_value("bottom", size, _units, _default), do: size * 1.0

  defp origin_value(text, size, units, default) do
    case length(text, size, units) do
      n when is_number(n) -> n
      _ -> default
    end
  end

  # -- values -------------------------------------------------------------------------------------

  defp words(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> then(&Regex.scan(~r/[\w.%-]*\((?:[^()]|\([^()]*\))*\)|\S+/, &1))
    |> List.flatten()
  end

  defp split_args(args) do
    args |> String.split(",") |> Enum.map(&String.trim/1)
  end

  # a length in px; a percentage is of `size`
  defp length(text, size, units) do
    text = String.trim(text)

    case Calc.eval("calc(" <> text <> ")", units) do
      {:ok, {:px, n}} -> n
      {:ok, {:pct, f}} -> f * size
      {:ok, {:num, n}} when n == 0 -> 0.0
      _ -> nil
    end
  end

  # `1.2`, or `120%`
  defp scale_factor(text) do
    case Calc.eval("calc(" <> String.trim(text) <> ")", fn _ -> nil end) do
      {:ok, {:num, n}} -> n
      {:ok, {:pct, f}} -> f
      _ -> nil
    end
  end

  defp number(text) do
    case Calc.eval("calc(" <> String.trim(text) <> ")", fn _ -> nil end) do
      {:ok, {:num, n}} -> n
      _ -> nil
    end
  end

  # deg, rad, grad, turn; a bare 0 is allowed
  defp angle_rad(text) do
    case Regex.run(
           ~r/\A\s*([+-]?(?:\d+\.?\d*|\.\d+)(?:e[+-]?\d+)?)(deg|rad|grad|turn)?\s*\z/i,
           text
         ) do
      [_, n] -> if(float(n) == 0.0, do: 0.0)
      [_, n, unit] -> to_rad(float(n), String.downcase(unit))
      nil -> calc_angle(text)
    end
  end

  # `calc(...)` of angles is rare: only the plain forms above are understood, plus `calc(1turn)`
  defp calc_angle(text) do
    case Regex.run(~r/\Acalc\(\s*(.+)\s*\)\z/i, String.trim(text)) do
      [_, inner] when inner != text -> angle_rad(inner)
      _ -> nil
    end
  end

  defp to_rad(n, "deg"), do: n * :math.pi() / 180
  defp to_rad(n, "rad"), do: n
  defp to_rad(n, "grad"), do: n * :math.pi() / 200
  defp to_rad(n, "turn"), do: n * 2 * :math.pi()

  defp float(text) do
    text = if String.starts_with?(text, ["+", "-"]), do: text, else: "+" <> text
    text = Regex.replace(~r/\A([+-])\./, text, "\\g{1}0.")
    text = if String.contains?(text, [".", "e", "E"]), do: text, else: text <> ".0"
    text = Regex.replace(~r/\.(?=[eE])/, text, ".0")
    {f, _} = text |> String.trim_leading("+") |> Float.parse()
    f
  end
end
