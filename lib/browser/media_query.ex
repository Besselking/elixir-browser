defmodule Browser.MediaQuery do
  @moduledoc """
  Media query parsing and evaluation.

  `parse/1` turns an `@media` prelude into a list of alternative queries
  (comma = OR). `eval/2` tests that list against an environment
  `%{type: "screen", width: px, height: px, dppx: float}`.

  Supported: media types, `and`, `not`/`only`, `or` between features,
  `(feature: value)`, `(min-/max-feature: value)`, boolean `(feature)` and the
  level-4 range syntax (`(width >= 600px)`, `(400px <= width <= 700px)`).
  Unknown features make their query false, as the spec requires.
  """

  @discrete %{
    "orientation" => :orientation,
    "prefers-color-scheme" => "light",
    "prefers-reduced-motion" => "no-preference",
    "prefers-contrast" => "no-preference",
    "prefers-reduced-data" => "no-preference",
    "prefers-reduced-transparency" => "no-preference",
    "hover" => "hover",
    "any-hover" => "hover",
    "pointer" => "fine",
    "any-pointer" => "fine",
    "scripting" => "none",
    "display-mode" => "browser",
    "forced-colors" => "none",
    "inverted-colors" => "none",
    "update" => "fast",
    "overflow-block" => "scroll",
    "overflow-inline" => "scroll"
  }

  # -- parsing -------------------------------------------------------------------

  def parse(prelude) do
    prelude = prelude |> String.downcase() |> String.trim()

    if prelude == "" do
      [%{type: "all", negate: false, features: []}]
    else
      prelude
      |> String.split(~r/,(?![^()]*\))/)
      |> Enum.flat_map(&parse_query/1)
    end
  end

  # one comma-separated query; top-level ` or ` yields several alternatives
  defp parse_query(q) do
    q
    |> String.trim()
    |> String.split(~r/\)\s+or\s+\(/)
    |> reglue()
    |> Enum.map(&parse_single/1)
  end

  # the split above eats the parens around the `or` operands; put them back
  defp reglue([one]), do: [one]

  defp reglue([first | rest]) do
    [first <> ")" | Enum.map(Enum.slice(rest, 0..-2//1), &("(" <> &1 <> ")")) ++ ["(" <> List.last(rest)]]
  end

  defp parse_single(q) do
    {negate, q} =
      case q do
        "not " <> r -> {true, String.trim(r)}
        "only " <> r -> {false, String.trim(r)}
        _ -> {false, q}
      end

    [head | rest] = String.split(q, ~r/\s+and\s+/)

    {type, feature_strs} =
      if String.starts_with?(head, "("), do: {"all", [head | rest]}, else: {head, rest}

    features = Enum.map(feature_strs, &parse_feature/1)

    if Regex.match?(~r/\A[a-z-]+\z/, type) and Enum.all?(features, &(&1 != :invalid)),
      do: %{type: type, negate: negate, features: List.flatten(features)},
      else: %{type: "not all", negate: false, features: []}
  end

  defp parse_feature("(" <> rest) do
    if String.ends_with?(rest, ")"),
      do: rest |> String.trim_trailing(")") |> String.trim() |> feature(),
      else: :invalid
  end

  defp parse_feature(_), do: :invalid

  defp feature(inner) do
    cond do
      String.contains?(inner, ":") ->
        [name, value] = String.split(inner, ":", parts: 2)
        name = String.trim(name)
        value = value |> String.trim() |> value()

        case Regex.run(~r/\A(?:-webkit-)?(min|max)-(.+)\z/, name, capture: :all_but_first) do
          ["min", base] -> [{base_name(name, base), :gte, value}]
          ["max", base] -> [{base_name(name, base), :lte, value}]
          nil -> [{name, :eq, value}]
        end

      Regex.match?(~r/[<>=]/, inner) ->
        range(inner)

      Regex.match?(~r/\A[a-z-]+\z/, inner) ->
        [{inner, :bool, nil}]

      true ->
        :invalid
    end
  end

  defp base_name("-webkit-" <> _, "device-pixel-ratio"), do: "-webkit-device-pixel-ratio"
  defp base_name(_, base), do: base

  defp range(inner) do
    case ~r/(<=|>=|<|>|=)/ |> Regex.split(inner, include_captures: true) |> Enum.map(&String.trim/1) do
      [a, op, b] ->
        if name?(a), do: [{a, op(op), value(b)}], else: [{b, op(flip(op)), value(a)}]

      [a, op1, b, op2, c] ->
        [{b, op(flip(op1)), value(a)}, {b, op(op2), value(c)}]

      _ ->
        :invalid
    end
  end

  defp name?(s), do: Regex.match?(~r/\A[a-z-]+\z/, s)

  defp flip("<"), do: ">"
  defp flip(">"), do: "<"
  defp flip("<="), do: ">="
  defp flip(">="), do: "<="
  defp flip("="), do: "="

  defp op("<"), do: :lt
  defp op(">"), do: :gt
  defp op("<="), do: :lte
  defp op(">="), do: :gte
  defp op("="), do: :eq

  # numbers (lengths -> px, ratios, resolutions -> dppx) or a keyword string
  defp value(raw) do
    cond do
      m = Regex.run(~r/\A(\d+(?:\.\d+)?)\s*\/\s*(\d+(?:\.\d+)?)\z/, raw) ->
        [_, a, b] = m
        num(a) / max(num(b), 1.0e-9)

      m = Regex.run(~r/\A([+-]?[\d.]+)(px|em|rem|pt|cm|mm|in|dppx|x|dpi|dpcm)?\z/, raw) ->
        [_, n, unit] = pad(m)
        n = num(n)

        case unit do
          u when u in ["", "px", "dppx", "x"] -> n
          u when u in ["em", "rem"] -> n * 16
          "pt" -> n * 96 / 72
          "in" -> n * 96
          "cm" -> n * 96 / 2.54
          "mm" -> n * 96 / 25.4
          "dpi" -> n / 96
          "dpcm" -> n * 2.54 / 96
        end

      true ->
        raw
    end
  end

  defp pad([a, b]), do: [a, b, ""]
  defp pad(l), do: l

  defp num(s) do
    case Float.parse(s) do
      {f, _} -> f
      :error -> 0.0
    end
  end

  # -- evaluation ----------------------------------------------------------------

  @doc "True if any alternative in `queries` matches `env`."
  def eval(queries, env), do: Enum.any?(queries, &query?(&1, env))

  defp query?(%{type: type, negate: negate, features: features}, env) do
    type_ok = type in ["all", env.type]
    (type_ok and Enum.all?(features, &feature?(&1, env))) != negate
  end

  defp feature?({name, :bool, nil}, env) do
    case metric(name, env) do
      nil -> false
      n when is_number(n) -> n != 0
      s -> s != "none"
    end
  end

  defp feature?({name, op, val}, env) do
    case metric(name, env) do
      nil -> false
      m when is_number(m) and is_number(val) -> compare(op, m, val)
      m when is_binary(m) and is_binary(val) -> op == :eq and m == val
      _ -> false
    end
  end

  defp compare(:eq, a, b), do: abs(a - b) < 1.0e-6
  defp compare(:gte, a, b), do: a >= b
  defp compare(:gt, a, b), do: a > b
  defp compare(:lte, a, b), do: a <= b
  defp compare(:lt, a, b), do: a < b

  defp metric(name, env) when name in ["width", "device-width"], do: env.width
  defp metric(name, env) when name in ["height", "device-height"], do: env.height
  defp metric(name, env) when name in ["aspect-ratio", "device-aspect-ratio"], do: env.width / max(env.height, 1)

  defp metric(name, env) when name in ["resolution", "device-pixel-ratio", "-webkit-device-pixel-ratio"],
    do: env.dppx

  defp metric("color", _), do: 8
  defp metric(name, _) when name in ["color-index", "monochrome", "grid"], do: 0

  defp metric(name, env) do
    case @discrete[name] do
      :orientation -> if env.height >= env.width, do: "portrait", else: "landscape"
      other -> other
    end
  end
end
