defmodule Browser.Svg.PathData do
  @moduledoc """
  The `d` attribute of an SVG `<path>`.

  `parse/1` turns the path data into absolute segments, using only four kinds so the
  painter stays simple:

    * `{:M, x, y}`: start a subpath
    * `{:L, x, y}`: a line
    * `{:C, x1, y1, x2, y2, x, y}`: a cubic bezier (quadratic curves and elliptical arcs
      are converted to cubics)
    * `:Z`: close the subpath

  Following the SVG rules, parsing stops at the first error and what came before it is
  kept, so a path with a typo still draws up to the typo.
  """

  @type segment ::
          {:M, float, float}
          | {:L, float, float}
          | {:C, float, float, float, float, float, float}
          | :Z

  @doc "Absolute segments for path data, or `[]` for empty or unusable data."
  @spec parse(String.t()) :: [segment]
  def parse(d) when is_binary(d) do
    d
    |> String.trim()
    |> commands(%{cx: 0.0, cy: 0.0, sx: 0.0, sy: 0.0, last: nil, cmd: nil}, [])
    |> Enum.reverse()
  end

  # -- reading commands ----------------------------------------------------------------

  defp commands("", _st, acc), do: acc

  defp commands(<<c, rest::binary>>, st, acc) when c in ~c"MmLlHhVvCcSsQqTtAaZz" do
    if acc == [] and c not in ~c"Mm" do
      # a path must start with a moveto
      []
    else
      run(<<c>>, skip(rest), %{st | cmd: <<c>>}, acc)
    end
  end

  defp commands(<<c, _::binary>> = data, %{cmd: cmd} = st, acc)
       when cmd != nil and cmd not in ["Z", "z"] do
    # numbers with no new command letter repeat the previous command
    if c in ~c"+-.0123456789", do: run(cmd, data, st, acc), else: acc
  end

  defp commands(_other, _st, acc), do: acc

  # one command letter and as many argument groups as follow it
  defp run(<<letter>>, data, st, acc) do
    lower = letter + if(letter in ?A..?Z, do: 32, else: 0)
    relative? = letter in ?a..?z

    case lower do
      ?z ->
        commands(data, %{st | cx: st.sx, cy: st.sy, last: nil}, [:Z | acc])

      _ ->
        arity = arity(lower)

        case numbers(data, lower, arity) do
          {:ok, args, rest} ->
            {segments, st} = apply_command(lower, relative?, args, st, acc)
            # after a moveto the following pairs are linetos
            next_cmd =
              case {lower, relative?} do
                {?m, true} -> "l"
                {?m, false} -> "L"
                _ -> <<letter>>
              end

            acc = Enum.reverse(segments) ++ acc
            continue(rest, %{st | cmd: next_cmd}, acc)

          :error ->
            acc
        end
    end
  end

  # more arguments for the same command, a new command, or the end
  defp continue(rest, st, acc) do
    rest = skip(rest)

    case rest do
      "" ->
        acc

      <<c, _::binary>> when c in ~c"MmLlHhVvCcSsQqTtAaZz" ->
        commands(rest, st, acc)

      <<c, _::binary>> when c in ~c"+-.0123456789" ->
        run(st.cmd, rest, st, acc)

      _ ->
        acc
    end
  end

  defp arity(?m), do: 2
  defp arity(?l), do: 2
  defp arity(?h), do: 1
  defp arity(?v), do: 1
  defp arity(?c), do: 6
  defp arity(?s), do: 4
  defp arity(?q), do: 4
  defp arity(?t), do: 2
  defp arity(?a), do: 7

  # -- numbers -------------------------------------------------------------------------

  defp skip(data), do: String.trim_leading(data, " ") |> skip_more()

  defp skip_more(data) do
    case data do
      <<c, rest::binary>> when c in [?\s, ?\t, ?\n, ?\r, ?,] -> skip_more(rest)
      _ -> data
    end
  end

  # `n` numbers; in an arc, arguments 4 and 5 are flags: a single 0 or 1, which may be
  # written without separators ("a1 1 0 00 1 1")
  defp numbers(data, cmd, n), do: numbers(skip(data), cmd, n, 0, [])
  defp numbers(rest, _cmd, n, n, acc), do: {:ok, Enum.reverse(acc), rest}

  defp numbers(data, cmd, n, i, acc) do
    result = if cmd == ?a and i in [3, 4], do: flag(data), else: number(data)

    case result do
      {value, rest} -> numbers(skip(rest), cmd, n, i + 1, [value | acc])
      :error -> :error
    end
  end

  defp flag(<<?0, rest::binary>>), do: {0, rest}
  defp flag(<<?1, rest::binary>>), do: {1, rest}
  defp flag(_), do: :error

  defp number(data) do
    case Regex.run(~r/\A[+-]?(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?/, data) do
      [text] ->
        {to_float(text), binary_part(data, byte_size(text), byte_size(data) - byte_size(text))}

      nil ->
        :error
    end
  end

  defp to_float(text) do
    text = if String.starts_with?(text, ["+", "-"]), do: text, else: "+" <> text
    text = Regex.replace(~r/\A([+-])\./, text, "\\g{1}0.")
    # Float.parse needs a digit after the point ("1.e3" is valid in SVG)
    text = Regex.replace(~r/\.(?=[eE]|\z)/, text, ".0")
    {f, _} = Float.parse(text)
    f
  end

  # -- turning one command into segments -------------------------------------------------

  defp apply_command(?m, rel?, [x, y], st, _acc) do
    {x, y} = absolute(rel?, st, x, y)
    {[{:M, x, y}], %{st | cx: x, cy: y, sx: x, sy: y, last: nil}}
  end

  defp apply_command(?l, rel?, [x, y], st, _acc) do
    {x, y} = absolute(rel?, st, x, y)
    {[{:L, x, y}], %{st | cx: x, cy: y, last: nil}}
  end

  defp apply_command(?h, rel?, [x], st, _acc) do
    x = if rel?, do: st.cx + x, else: x
    {[{:L, x, st.cy}], %{st | cx: x, last: nil}}
  end

  defp apply_command(?v, rel?, [y], st, _acc) do
    y = if rel?, do: st.cy + y, else: y
    {[{:L, st.cx, y}], %{st | cy: y, last: nil}}
  end

  defp apply_command(?c, rel?, [x1, y1, x2, y2, x, y], st, _acc) do
    {x1, y1} = absolute(rel?, st, x1, y1)
    {x2, y2} = absolute(rel?, st, x2, y2)
    {x, y} = absolute(rel?, st, x, y)
    {[{:C, x1, y1, x2, y2, x, y}], %{st | cx: x, cy: y, last: {:cubic, x2, y2}}}
  end

  defp apply_command(?s, rel?, [x2, y2, x, y], st, _acc) do
    # the first control point mirrors the previous cubic's second one
    {x1, y1} =
      case st.last do
        {:cubic, lx, ly} -> {2 * st.cx - lx, 2 * st.cy - ly}
        _ -> {st.cx, st.cy}
      end

    {x2, y2} = absolute(rel?, st, x2, y2)
    {x, y} = absolute(rel?, st, x, y)
    {[{:C, x1, y1, x2, y2, x, y}], %{st | cx: x, cy: y, last: {:cubic, x2, y2}}}
  end

  defp apply_command(?q, rel?, [qx, qy, x, y], st, _acc) do
    {qx, qy} = absolute(rel?, st, qx, qy)
    {x, y} = absolute(rel?, st, x, y)
    {[quad(st.cx, st.cy, qx, qy, x, y)], %{st | cx: x, cy: y, last: {:quad, qx, qy}}}
  end

  defp apply_command(?t, rel?, [x, y], st, _acc) do
    {qx, qy} =
      case st.last do
        {:quad, lx, ly} -> {2 * st.cx - lx, 2 * st.cy - ly}
        _ -> {st.cx, st.cy}
      end

    {x, y} = absolute(rel?, st, x, y)
    {[quad(st.cx, st.cy, qx, qy, x, y)], %{st | cx: x, cy: y, last: {:quad, qx, qy}}}
  end

  defp apply_command(?a, rel?, [rx, ry, rot, large, sweep, x, y], st, _acc) do
    {x, y} = absolute(rel?, st, x, y)
    segments = arc(st.cx, st.cy, rx, ry, rot, large == 1, sweep == 1, x, y)
    {segments, %{st | cx: x, cy: y, last: nil}}
  end

  defp absolute(true, st, x, y), do: {st.cx + x, st.cy + y}
  defp absolute(false, _st, x, y), do: {x, y}

  # a quadratic curve as the equivalent cubic
  defp quad(x0, y0, qx, qy, x, y) do
    {:C, x0 + 2 / 3 * (qx - x0), y0 + 2 / 3 * (qy - y0), x + 2 / 3 * (qx - x),
     y + 2 / 3 * (qy - y), x, y}
  end

  # -- arcs ----------------------------------------------------------------------------

  @doc """
  An elliptical arc from `(x1, y1)` to `(x2, y2)` as segments (the SVG implementation notes,
  F.6): a line when a radius is zero, radii scaled up when they are too small, otherwise
  cubic beziers of at most a quarter turn each.
  """
  def arc(x1, y1, rx, ry, rot, large?, sweep?, x2, y2) do
    cond do
      x1 == x2 and y1 == y2 ->
        []

      rx == 0 or ry == 0 ->
        [{:L, x2, y2}]

      true ->
        ellipse_arc(x1, y1, abs(rx), abs(ry), rot * :math.pi() / 180, large?, sweep?, x2, y2)
    end
  end

  defp ellipse_arc(x1, y1, rx, ry, phi, large?, sweep?, x2, y2) do
    {sin, cos} = {:math.sin(phi), :math.cos(phi)}
    {dx, dy} = {(x1 - x2) / 2, (y1 - y2) / 2}
    {x1p, y1p} = {cos * dx + sin * dy, -sin * dx + cos * dy}

    lambda = x1p * x1p / (rx * rx) + y1p * y1p / (ry * ry)

    {rx, ry} =
      if lambda > 1, do: {rx * :math.sqrt(lambda), ry * :math.sqrt(lambda)}, else: {rx, ry}

    num = rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p
    den = rx * rx * y1p * y1p + ry * ry * x1p * x1p
    coef = if den == 0, do: 0.0, else: :math.sqrt(max(num / den, 0.0))
    coef = if large? == sweep?, do: -coef, else: coef

    {cxp, cyp} = {coef * rx * y1p / ry, -coef * ry * x1p / rx}
    {cx, cy} = {cos * cxp - sin * cyp + (x1 + x2) / 2, sin * cxp + cos * cyp + (y1 + y2) / 2}

    theta = angle(1.0, 0.0, (x1p - cxp) / rx, (y1p - cyp) / ry)
    delta = angle((x1p - cxp) / rx, (y1p - cyp) / ry, (-x1p - cxp) / rx, (-y1p - cyp) / ry)
    two_pi = 2 * :math.pi()

    delta =
      cond do
        not sweep? and delta > 0 -> delta - two_pi
        sweep? and delta < 0 -> delta + two_pi
        true -> delta
      end

    count = max(ceil(abs(delta) / (:math.pi() / 2) - 1.0e-9), 1)
    step = delta / count
    t = 4 / 3 * :math.tan(step / 4)

    for i <- 0..(count - 1) do
      a = theta + i * step
      b = a + step
      {sa, ca, sb, cb} = {:math.sin(a), :math.cos(a), :math.sin(b), :math.cos(b)}

      place = fn ux, uy ->
        {px, py} = {ux * rx, uy * ry}
        {cos * px - sin * py + cx, sin * px + cos * py + cy}
      end

      {c1x, c1y} = place.(ca - t * sa, sa + t * ca)
      {c2x, c2y} = place.(cb + t * sb, sb - t * cb)
      # the last piece ends exactly where the arc was asked to
      {ex, ey} = if i == count - 1, do: {x2, y2}, else: place.(cb, sb)
      {:C, c1x, c1y, c2x, c2y, ex, ey}
    end
  end

  # the signed angle from vector u to vector v
  defp angle(ux, uy, vx, vy) do
    dot = ux * vx + uy * vy
    len = :math.sqrt((ux * ux + uy * uy) * (vx * vx + vy * vy))
    a = :math.acos(max(min(dot / len, 1.0), -1.0))
    if ux * vy - uy * vx < 0, do: -a, else: a
  end
end
