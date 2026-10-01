defmodule Browser.Shadows do
  @moduledoc """
  CSS `box-shadow`: parsing, and the geometry for drawing it.

  The window toolkit can't blur, so a blurred shadow is drawn as a stack of translucent
  shapes between a larger and a smaller one: the middle is solid and the edge fades out
  over `blur` pixels on each side, which is about what a Gaussian blur of radius `blur`
  looks like. `outer_layers/3` and `inset_layers/3` produce those shapes.
  """

  alias Browser.{Backgrounds, Color}

  @type shadow :: %{
          dx: float,
          dy: float,
          blur: float,
          spread: float,
          color: {0..255, 0..255, 0..255, 0..255},
          inset?: boolean
        }

  @doc """
  Parses a `box-shadow` value into a list of shadows (first = on top). `fs` is the font size
  for `em` lengths and `current` the colour for shadows without one (and `currentcolor`),
  as `{r, g, b, a}`. `none` and invalid shadows give nothing.
  """
  def parse(value, fs, current) do
    value
    |> Backgrounds.split_top()
    |> Enum.flat_map(fn layer ->
      case shadow(layer, fs, current) do
        nil -> []
        s -> [s]
      end
    end)
  end

  defp shadow(layer, fs, current) do
    toks = tokens(layer)
    inset? = Enum.any?(toks, &(String.downcase(&1) == "inset"))
    rest = Enum.reject(toks, &(String.downcase(&1) == "inset"))

    {lengths, colors} = Enum.split_with(rest, &length_px(&1, fs))
    nums = Enum.map(lengths, &length_px(&1, fs))

    color =
      case colors do
        [] -> current
        [c] -> color(c, current)
        _ -> :invalid
      end

    case {nums, color} do
      {[dx, dy | tail], c} when c != nil and c != :invalid and length(tail) <= 2 ->
        [blur, spread] = tail ++ List.duplicate(0.0, 2 - length(tail))

        if blur < 0,
          do: nil,
          else: %{dx: dx, dy: dy, blur: blur, spread: spread, color: c, inset?: inset?}

      _ ->
        nil
    end
  end

  defp color(token, current) do
    case Color.parse_alpha(token) do
      :current -> current
      other -> other
    end
  end

  defp tokens(layer),
    do: ~r/[\w-]*\((?:[^()]|\([^()]*\))*\)|\S+/ |> Regex.scan(layer) |> List.flatten()

  defp length_px(tok, fs) do
    case Regex.run(~r/\A([+-]?(?:\d+\.?\d*|\.\d+))(px|em|rem|pt|cm|mm|in)?\z/, tok) do
      [_, n, unit] -> number(n) * scale(unit, fs)
      [_, n] -> if number(n) == 0.0, do: 0.0
      _ -> nil
    end
  end

  defp scale("px", _), do: 1.0
  defp scale("em", fs), do: fs
  defp scale("rem", _), do: 16.0
  defp scale("pt", _), do: 4 / 3
  defp scale("in", _), do: 96.0
  defp scale("cm", _), do: 96 / 2.54
  defp scale("mm", _), do: 96 / 25.4

  defp number(n) do
    n = if String.starts_with?(n, ["+", "-"]), do: n, else: "+" <> n
    n = Regex.replace(~r/\A([+-])\./, n, "\\g{1}0.")
    n = if String.contains?(n, "."), do: n, else: n <> ".0"
    n |> String.trim_leading("+") |> String.to_float()
  end

  # -- blur --------------------------------------------------------------------------

  @max_layers 12

  @doc """
  The translucent layers that approximate a blur: `[%{inflate, alpha}]`, outermost first.
  `inflate` is how much bigger than the unblurred shape (negative: smaller) the layer is, and
  `alpha` its opacity (0..255); stacked, the middle reaches `alpha_total`.
  """
  def blur_layers(blur, spread, alpha_total) when blur <= 0 do
    [%{inflate: spread, alpha: alpha_total}]
  end

  def blur_layers(blur, spread, alpha_total) do
    n = blur |> round() |> max(2) |> min(@max_layers)
    # n layers whose combined opacity (1 - (1-a)^n) equals alpha_total
    a = 1 - :math.pow(1 - alpha_total / 255, 1 / n)

    for i <- 0..(n - 1) do
      %{inflate: spread + blur - 2 * blur * i / (n - 1), alpha: max(round(a * 255), 1)}
    end
  end

  # -- shapes --------------------------------------------------------------------------

  @doc """
  What to fill for an outer shadow of a box `{x, y, w, h}` with corner `radii`
  (`{tl, tr, br, bl}` of `{rx, ry}`, or nil): `[%{rect, radii, color}]` drawn in order. The
  shape follows the box's corners, grown by the spread, and is offset by the shadow.
  """
  def outer_layers(shadow, {x, y, w, h}, radii) do
    {r, g, b, a} = shadow.color

    for %{inflate: grow, alpha: alpha} <- blur_layers(shadow.blur, shadow.spread, a),
        {rw, rh} = {w + 2 * grow, h + 2 * grow},
        rw > 0 and rh > 0 do
      %{
        rect: {round(x + shadow.dx - grow), round(y + shadow.dy - grow), round(rw), round(rh)},
        radii: grow_radii(radii, grow),
        color: {r, g, b, alpha}
      }
    end
  end

  @doc """
  Like `outer_layers/3` for an `inset` shadow: each layer is a frame, the box minus a hole.
  `hole` is `nil` when the hole has vanished and the whole box is shadow.
  """
  def inset_layers(shadow, {x, y, w, h}, radii) do
    {r, g, b, a} = shadow.color

    for %{inflate: grow, alpha: alpha} <- blur_layers(shadow.blur, shadow.spread, a) do
      {hw, hh} = {w - 2 * grow, h - 2 * grow}

      hole =
        if hw > 0 and hh > 0 do
          %{
            rect:
              {round(x + shadow.dx + grow), round(y + shadow.dy + grow), round(hw), round(hh)},
            radii: grow_radii(radii, -grow)
          }
        end

      %{hole: hole, color: {r, g, b, alpha}}
    end
  end

  # a corner that was square stays square, others grow or shrink with the spread
  defp grow_radii(nil, _by), do: nil

  defp grow_radii(radii, by) do
    radii
    |> Tuple.to_list()
    |> Enum.map(fn {rx, ry} ->
      if rx > 0 and ry > 0, do: {max(round(rx + by), 0), max(round(ry + by), 0)}, else: {0, 0}
    end)
    |> List.to_tuple()
  end
end
