defmodule Browser.Color do
  @moduledoc """
  CSS color parsing.

  `parse/1` returns `{r, g, b}` (alpha is blended over white, since pages are
  painted on a white canvas), `:transparent`, `:current` for `currentcolor`,
  or `nil` if the value isn't a color we understand.
  """

  @named %{
    "black" => {0, 0, 0}, "silver" => {192, 192, 192}, "gray" => {128, 128, 128},
    "grey" => {128, 128, 128}, "white" => {255, 255, 255}, "maroon" => {128, 0, 0},
    "red" => {255, 0, 0}, "purple" => {128, 0, 128}, "fuchsia" => {255, 0, 255},
    "magenta" => {255, 0, 255}, "green" => {0, 128, 0}, "lime" => {0, 255, 0},
    "olive" => {128, 128, 0}, "yellow" => {255, 255, 0}, "navy" => {0, 0, 128},
    "blue" => {0, 0, 255}, "teal" => {0, 128, 128}, "aqua" => {0, 255, 255},
    "cyan" => {0, 255, 255}, "orange" => {255, 165, 0}, "pink" => {255, 192, 203},
    "brown" => {165, 42, 42}, "gold" => {255, 215, 0}, "indigo" => {75, 0, 130},
    "violet" => {238, 130, 238}, "coral" => {255, 127, 80}, "crimson" => {220, 20, 60},
    "tomato" => {255, 99, 71}, "salmon" => {250, 128, 114}, "khaki" => {240, 230, 140},
    "turquoise" => {64, 224, 208}, "tan" => {210, 180, 140}, "beige" => {245, 245, 220},
    "ivory" => {255, 255, 240}, "lavender" => {230, 230, 250}, "orchid" => {218, 112, 214},
    "plum" => {221, 160, 221}, "sienna" => {160, 82, 45}, "chocolate" => {210, 105, 30},
    "firebrick" => {178, 34, 34}, "darkred" => {139, 0, 0}, "darkgreen" => {0, 100, 0},
    "darkblue" => {0, 0, 139}, "darkgray" => {169, 169, 169}, "darkgrey" => {169, 169, 169},
    "dimgray" => {105, 105, 105}, "dimgrey" => {105, 105, 105}, "lightgray" => {211, 211, 211},
    "lightgrey" => {211, 211, 211}, "gainsboro" => {220, 220, 220}, "whitesmoke" => {245, 245, 245},
    "snow" => {255, 250, 250}, "lightblue" => {173, 216, 230}, "skyblue" => {135, 206, 235},
    "steelblue" => {70, 130, 180}, "royalblue" => {65, 105, 225}, "dodgerblue" => {30, 144, 255},
    "midnightblue" => {25, 25, 112}, "cornflowerblue" => {100, 149, 237},
    "lightgreen" => {144, 238, 144}, "limegreen" => {50, 205, 50}, "forestgreen" => {34, 139, 34},
    "seagreen" => {46, 139, 87}, "darkorange" => {255, 140, 0}, "lightyellow" => {255, 255, 224},
    "goldenrod" => {218, 165, 32}, "slategray" => {112, 128, 144}, "slategrey" => {112, 128, 144},
    "rebeccapurple" => {102, 51, 153}, "hotpink" => {255, 105, 180}, "deeppink" => {255, 20, 147},
    "aliceblue" => {240, 248, 255}, "azure" => {240, 255, 255}, "honeydew" => {240, 255, 240},
    "mintcream" => {245, 255, 250}, "linen" => {250, 240, 230}, "wheat" => {245, 222, 179}
  }

  @spec parse(String.t()) :: {0..255, 0..255, 0..255} | :transparent | :current | nil
  def parse(str) when is_binary(str) do
    s = str |> String.trim() |> String.downcase()

    cond do
      s == "transparent" -> :transparent
      s == "currentcolor" -> :current
      String.starts_with?(s, "#") -> s |> binary_part(1, byte_size(s) - 1) |> hex()
      m = Regex.run(~r/\A(rgba?|hsla?)\((.*)\)\z/s, s) -> func(Enum.at(m, 1), Enum.at(m, 2))
      m = Regex.run(~r/\Alight-dark\((.*)\)\z/s, s) -> m |> Enum.at(1) |> first_arg() |> parse()
      true -> Map.get(@named, s)
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
      {true, [r, g, b | alpha]} -> with_alpha(alpha, &rgba(channel(r), channel(g), channel(b), &1))
      {false, [h, s, l | alpha]} -> with_alpha(alpha, &hsl(hue(h), pct(s), pct(l), &1))
      _ -> nil
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

    case tok |> String.trim_trailing("%") |> Float.parse() do
      {n, ""} -> {n, pct?}
      _ -> nil
    end
  end

  defp hsl(h, s, l, a) when is_number(h) and is_number(s) and is_number(l) do
    h = :math.fmod(h, 360) / 360
    h = if h < 0, do: h + 1, else: h
    s = clamp(s, 0, 1)
    l = clamp(l, 0, 1)
    q = if l < 0.5, do: l * (1 + s), else: l + s - l * s
    p = 2 * l - q
    rgba(hue_to_rgb(p, q, h + 1 / 3) * 255, hue_to_rgb(p, q, h) * 255, hue_to_rgb(p, q, h - 1 / 3) * 255, a)
  end

  defp hsl(_, _, _, _), do: nil

  defp hue_to_rgb(p, q, t) do
    t = cond do t < 0 -> t + 1; t > 1 -> t - 1; true -> t end

    cond do
      t < 1 / 6 -> p + (q - p) * 6 * t
      t < 1 / 2 -> q
      t < 2 / 3 -> p + (q - p) * (2 / 3 - t) * 6
      true -> p
    end
  end

  defp clamp(n, lo, hi), do: n |> max(lo) |> min(hi)

  # blend over white
  defp rgba(r, g, b, a) when is_number(r) and is_number(g) and is_number(b) do
    a = clamp(a * 1.0, 0, 1)

    if a == 0 do
      :transparent
    else
      mix = fn c -> round(clamp(c, 0, 255) * a + 255 * (1 - a)) end
      {mix.(r), mix.(g), mix.(b)}
    end
  end

  defp rgba(_, _, _, _), do: nil
end
