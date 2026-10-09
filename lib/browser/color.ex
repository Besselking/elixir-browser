defmodule Browser.Color do
  @moduledoc """
  CSS color parsing.

  `parse/1` returns `{r, g, b}` (alpha is blended over white, since pages are
  painted on a white canvas), `:transparent`, `:current` for `currentcolor`,
  or `nil` if the value isn't a color we understand.

  `parse_alpha/1` keeps the alpha instead, for things painted over other things
  (gradient stops, shadows): `{r, g, b, a}` with `a` from 0 (clear) to 255.
  """

  @named %{
    "black" => {0, 0, 0},
    "silver" => {192, 192, 192},
    "gray" => {128, 128, 128},
    "grey" => {128, 128, 128},
    "white" => {255, 255, 255},
    "maroon" => {128, 0, 0},
    "red" => {255, 0, 0},
    "purple" => {128, 0, 128},
    "fuchsia" => {255, 0, 255},
    "magenta" => {255, 0, 255},
    "green" => {0, 128, 0},
    "lime" => {0, 255, 0},
    "olive" => {128, 128, 0},
    "yellow" => {255, 255, 0},
    "navy" => {0, 0, 128},
    "blue" => {0, 0, 255},
    "teal" => {0, 128, 128},
    "aqua" => {0, 255, 255},
    "cyan" => {0, 255, 255},
    "orange" => {255, 165, 0},
    "pink" => {255, 192, 203},
    "brown" => {165, 42, 42},
    "gold" => {255, 215, 0},
    "indigo" => {75, 0, 130},
    "violet" => {238, 130, 238},
    "coral" => {255, 127, 80},
    "crimson" => {220, 20, 60},
    "tomato" => {255, 99, 71},
    "salmon" => {250, 128, 114},
    "khaki" => {240, 230, 140},
    "turquoise" => {64, 224, 208},
    "tan" => {210, 180, 140},
    "beige" => {245, 245, 220},
    "ivory" => {255, 255, 240},
    "lavender" => {230, 230, 250},
    "orchid" => {218, 112, 214},
    "plum" => {221, 160, 221},
    "sienna" => {160, 82, 45},
    "chocolate" => {210, 105, 30},
    "firebrick" => {178, 34, 34},
    "darkred" => {139, 0, 0},
    "darkgreen" => {0, 100, 0},
    "darkblue" => {0, 0, 139},
    "darkgray" => {169, 169, 169},
    "darkgrey" => {169, 169, 169},
    "dimgray" => {105, 105, 105},
    "dimgrey" => {105, 105, 105},
    "lightgray" => {211, 211, 211},
    "lightgrey" => {211, 211, 211},
    "gainsboro" => {220, 220, 220},
    "whitesmoke" => {245, 245, 245},
    "snow" => {255, 250, 250},
    "lightblue" => {173, 216, 230},
    "skyblue" => {135, 206, 235},
    "steelblue" => {70, 130, 180},
    "royalblue" => {65, 105, 225},
    "dodgerblue" => {30, 144, 255},
    "midnightblue" => {25, 25, 112},
    "cornflowerblue" => {100, 149, 237},
    "lightgreen" => {144, 238, 144},
    "limegreen" => {50, 205, 50},
    "forestgreen" => {34, 139, 34},
    "seagreen" => {46, 139, 87},
    "darkorange" => {255, 140, 0},
    "lightyellow" => {255, 255, 224},
    "goldenrod" => {218, 165, 32},
    "slategray" => {112, 128, 144},
    "slategrey" => {112, 128, 144},
    "rebeccapurple" => {102, 51, 153},
    "hotpink" => {255, 105, 180},
    "deeppink" => {255, 20, 147},
    "aliceblue" => {240, 248, 255},
    "azure" => {240, 255, 255},
    "honeydew" => {240, 255, 240},
    "mintcream" => {245, 255, 250},
    "linen" => {250, 240, 230},
    "wheat" => {245, 222, 179}
  }

  @spec parse(String.t()) :: {0..255, 0..255, 0..255} | :transparent | :current | nil
  def parse(str) when is_binary(str) do
    case raw(str) do
      {:rgba, _r, _g, _b, +0.0} -> :transparent
      {:rgba, r, g, b, a} -> {blend(r, a), blend(g, a), blend(b, a)}
      other -> other
    end
  end

  @spec parse_alpha(String.t()) :: {0..255, 0..255, 0..255, 0..255} | :current | nil
  def parse_alpha(str) when is_binary(str) do
    case raw(str) do
      {:rgba, r, g, b, a} -> {r, g, b, round(a * 255)}
      other -> other
    end
  end

  @doc """
  Like `parse_alpha/1` but in the shape layout paints with: `{r, g, b}` when opaque,
  `{r, g, b, a}` (a 1..254) when translucent, `:transparent`, `:current`, or nil.
  Backgrounds and borders keep their alpha this way instead of being blended over white.
  """
  def parse_rgba(str) when is_binary(str) do
    case raw(str) do
      {:rgba, r, g, b, a} when a >= 1.0 -> {r, g, b}
      {:rgba, _r, _g, _b, a} when a <= 0.0 -> :transparent
      {:rgba, r, g, b, a} -> {r, g, b, max(round(a * 255), 1)}
      other -> other
    end
  end

  # blend a channel over white
  defp blend(c, a), do: round(c * a + 255 * (1 - a))

  # a page repeats a few colour strings over and over (a canvas sets one for every shape), so
  # parsed ones are kept in the process dictionary, up to a limit
  defp raw(str) do
    key = {:js_memo, {:color, str}}

    case :erlang.get(key) do
      :undefined ->
        parsed = raw_parse(str)
        n = :erlang.get({:js_memo, :color_n})

        if n == :undefined or n < 4096 do
          :erlang.put({:js_memo, :color_n}, if(n == :undefined, do: 1, else: n + 1))
          :erlang.put(key, parsed)
        end

        parsed

      parsed ->
        parsed
    end
  end

  defp raw_parse(str) do
    s = str |> String.trim() |> String.downcase()

    cond do
      s == "transparent" -> {:rgba, 0, 0, 0, 0.0}
      s == "currentcolor" -> :current
      String.starts_with?(s, "#") -> s |> binary_part(1, byte_size(s) - 1) |> hex()
      m = Regex.run(~r/\A(rgba?|hsla?)\((.*)\)\z/s, s) -> func(Enum.at(m, 1), Enum.at(m, 2))
      m = Regex.run(~r/\Alight-dark\((.*)\)\z/s, s) -> m |> Enum.at(1) |> first_arg() |> raw()
      m = Regex.run(~r/\A(oklch|oklab)\((.*)\)\z/s, s) -> oklab_func(Enum.at(m, 1), Enum.at(m, 2))
      m = Regex.run(~r/\Acolor-mix\((.*)\)\z/s, s) -> color_mix(Enum.at(m, 1))
      true -> named(s)
    end
  end

  # -- oklab / oklch ---------------------------------------------------------------

  defp oklab_func(name, args) do
    parts = args |> String.replace("/", " ") |> String.split()

    case parts do
      [l, c1, c2 | alpha] ->
        with lightness when is_number(lightness) <- ok_number(l, 1.0),
             {:ok, alpha} <- ok_alpha(alpha) do
          if name == "oklch" do
            chroma = ok_number(c1, 0.4)
            hue = hue(c2)

            if is_number(chroma) and is_number(hue) do
              rad = hue * :math.pi() / 180
              oklab_to_rgba(lightness, chroma * :math.cos(rad), chroma * :math.sin(rad), alpha)
            end
          else
            a = ok_number(c1, 0.4)
            b = ok_number(c2, 0.4)
            if is_number(a) and is_number(b), do: oklab_to_rgba(lightness, a, b, alpha)
          end
        else
          _ -> nil
        end

      _ ->
        nil
    end
  end

  # a number, or a percentage of `full`
  defp ok_number("none", _full), do: 0.0

  defp ok_number(tok, full) do
    case number(tok) do
      {n, true} -> n / 100 * full
      {n, false} -> n
      nil -> nil
    end
  end

  defp ok_alpha([]), do: {:ok, 1.0}
  defp ok_alpha([a]), do: {:ok, alpha(a)}
  defp ok_alpha(_), do: :error

  defp oklab_to_rgba(l, a, b, alpha) do
    l_ = :math.pow(l + 0.3963377774 * a + 0.2158037573 * b, 3)
    m_ = :math.pow(l - 0.1055613458 * a - 0.0638541728 * b, 3)
    s_ = :math.pow(l - 0.0894841775 * a - 1.2914855480 * b, 3)

    r = 4.0767416621 * l_ - 3.3077115913 * m_ + 0.2309699292 * s_
    g = -1.2684380046 * l_ + 2.6097574011 * m_ - 0.3413193965 * s_
    bl = -0.0041960863 * l_ - 0.7034186147 * m_ + 1.7076147010 * s_

    rgba(gamma(r) * 255, gamma(g) * 255, gamma(bl) * 255, alpha)
  end

  defp gamma(v) do
    v = clamp(v, 0.0, 1.0)
    if v <= 0.0031308, do: 12.92 * v, else: 1.055 * :math.pow(v, 1 / 2.4) - 0.055
  end

  # -- color-mix() -----------------------------------------------------------------

  # Mixed in premultiplied sRGB whatever space is named: close enough for the usual
  # `color-mix(in oklab, <color> 40%, transparent)` of an opacity modifier.
  defp color_mix(args) do
    with [_space, first, second] <- split_commas(args),
         {c1, p1} <- mix_part(first),
         {c2, p2} <- mix_part(second),
         {:rgba, r1, g1, b1, a1} <- raw(c1),
         {:rgba, r2, g2, b2, a2} <- raw(c2) do
      {p1, p2} =
        case {p1, p2} do
          {nil, nil} -> {50.0, 50.0}
          {p, nil} -> {p, 100.0 - p}
          {nil, p} -> {100.0 - p, p}
          both -> both
        end

      total = p1 + p2

      if total > 0 do
        {w1, w2} = {p1 / total, p2 / total}
        alpha = a1 * w1 + a2 * w2

        if alpha == 0.0 do
          {:rgba, 0, 0, 0, 0.0}
        else
          mix = fn x1, x2 -> (x1 * a1 * w1 + x2 * a2 * w2) / alpha end
          rgba(mix.(r1, r2), mix.(g1, g2), mix.(b1, b2), alpha * min(total, 100.0) / 100)
        end
      end
    else
      _ -> nil
    end
  end

  # "<color> [percent]" or "[percent] <color>" -> {color text, percent | nil}
  defp mix_part(text) do
    case Regex.run(~r/\A\s*(?:([\d.]+)%\s*)?(.*?)(?:\s*([\d.]+)%)?\s*\z/s, text) do
      [_, pre, color, post] ->
        pct = if pre != "", do: pre, else: post
        {color, if(pct != "", do: pct |> leading_zero() |> Float.parse() |> elem(0))}

      [_, pre, color] ->
        {color, if(pre != "", do: pre |> leading_zero() |> Float.parse() |> elem(0))}

      _ ->
        nil
    end
  end

  defp split_commas(args) do
    {parts, cur, _} =
      args
      |> String.graphemes()
      |> Enum.reduce({[], "", 0}, fn
        ",", {parts, cur, 0} -> {[cur | parts], "", 0}
        "(", {parts, cur, d} -> {parts, cur <> "(", d + 1}
        ")", {parts, cur, d} -> {parts, cur <> ")", d - 1}
        c, {parts, cur, d} -> {parts, cur <> c, d}
      end)

    Enum.reverse([cur | parts])
  end

  defp named(s) do
    case Map.get(@named, s) do
      {r, g, b} -> {:rgba, r, g, b, 1.0}
      nil -> nil
    end
  end

  defp first_arg(args) do
    # split at the first top-level comma
    {head, _} =
      args
      |> String.graphemes()
      |> Enum.reduce_while({"", 0}, fn
        ",", {acc, 0} -> {:halt, {acc, 0}}
        "(", {acc, d} -> {:cont, {acc <> "(", d + 1}}
        ")", {acc, d} -> {:cont, {acc <> ")", d - 1}}
        c, {acc, d} -> {:cont, {acc <> c, d}}
      end)

    head
  end

  # -- hex -----------------------------------------------------------------------

  defp hex(h) do
    if Regex.match?(~r/\A[0-9a-f]+\z/, h) do
      case byte_size(h) do
        3 -> h |> String.graphemes() |> Enum.map(&(&1 <> &1)) |> Enum.join() |> hex()
        4 -> h |> String.graphemes() |> Enum.map(&(&1 <> &1)) |> Enum.join() |> hex()
        6 -> rgba(pair(h, 0), pair(h, 2), pair(h, 4), 1.0)
        8 -> rgba(pair(h, 0), pair(h, 2), pair(h, 4), pair(h, 6) / 255)
        _ -> nil
      end
    end
  end

  defp pair(h, at), do: h |> binary_part(at, 2) |> String.to_integer(16)

  # -- rgb() / hsl() ---------------------------------------------------------------

  defp func(name, args) do
    parts = args |> String.replace(["/", ","], " ") |> String.split()

    case {String.starts_with?(name, "rgb"), parts} do
      {true, [r, g, b | alpha]} ->
        with_alpha(alpha, &rgba(channel(r), channel(g), channel(b), &1))

      {false, [h, s, l | alpha]} ->
        with_alpha(alpha, &hsl(hue(h), pct(s), pct(l), &1))

      _ ->
        nil
    end
  end

  defp with_alpha([], fun), do: fun.(1.0)
  defp with_alpha([a], fun), do: fun.(alpha(a))
  defp with_alpha(_, _), do: nil

  defp channel(tok) do
    case number(tok) do
      {n, true} -> n * 255 / 100
      {n, false} -> n
      nil -> nil
    end
  end

  defp pct(tok) do
    case number(tok) do
      {n, _} -> n / 100
      nil -> nil
    end
  end

  defp hue(tok) do
    case number(String.replace(tok, ~r/deg\z/, "")) do
      {n, _} -> n
      nil -> nil
    end
  end

  defp alpha(tok) do
    case number(tok) do
      {n, true} -> n / 100
      {n, false} -> n
      nil -> 1.0
    end
  end

  # -> {float, percent?} | nil
  defp number(tok) do
    pct? = String.ends_with?(tok, "%")

    case tok |> String.trim_trailing("%") |> leading_zero() |> Float.parse() do
      {n, ""} -> {n, pct?}
      _ -> nil
    end
  end

  # CSS allows ".5" and "-.5", which Float.parse/1 rejects
  defp leading_zero("." <> _ = num), do: "0" <> num
  defp leading_zero("+." <> rest), do: "+0." <> rest
  defp leading_zero("-." <> rest), do: "-0." <> rest
  defp leading_zero(num), do: num

  defp hsl(h, s, l, a) when is_number(h) and is_number(s) and is_number(l) do
    h = :math.fmod(h, 360) / 360
    h = if h < 0, do: h + 1, else: h
    s = clamp(s, 0, 1)
    l = clamp(l, 0, 1)
    q = if l < 0.5, do: l * (1 + s), else: l + s - l * s
    p = 2 * l - q

    rgba(
      hue_to_rgb(p, q, h + 1 / 3) * 255,
      hue_to_rgb(p, q, h) * 255,
      hue_to_rgb(p, q, h - 1 / 3) * 255,
      a
    )
  end

  defp hsl(_, _, _, _), do: nil

  defp hue_to_rgb(p, q, t) do
    t =
      cond do
        t < 0 -> t + 1
        t > 1 -> t - 1
        true -> t
      end

    cond do
      t < 1 / 6 -> p + (q - p) * 6 * t
      t < 1 / 2 -> q
      t < 2 / 3 -> p + (q - p) * (2 / 3 - t) * 6
      true -> p
    end
  end

  defp clamp(n, lo, hi), do: n |> max(lo) |> min(hi)

  defp rgba(r, g, b, a) when is_number(r) and is_number(g) and is_number(b) do
    {:rgba, round(clamp(r, 0, 255)), round(clamp(g, 0, 255)), round(clamp(b, 0, 255)),
     clamp(a * 1.0, 0, 1)}
  end

  defp rgba(_, _, _, _), do: nil
end
