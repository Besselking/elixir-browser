defmodule Browser.Calc do
  @moduledoc """
  Evaluates CSS math: `calc()`, `min()`, `max()` and `clamp()`, with nesting.

  `eval/2` takes the function's text, e.g. `"calc(.25rem*6)"`, and `units`, a function from a
  unit name (`"rem"`, `"em"`, ...) to its size in px or nil. The result is `{:px, n}`,
  `{:pct, fraction}`, `{:calc, px, fraction}` (a length plus a percentage, which depends on a
  size that isn't known here) or `{:num, n}` (a plain number), or `:error` when it can't be
  worked out: an unknown unit or a bad expression.
  """

  @functions ~w(calc min max clamp)

  @doc "The size in px of one `unit` for text of `fs` px under a root font size of `root` px."
  def unit_px("px", _fs, _root), do: 1.0
  def unit_px("em", fs, _root), do: fs
  def unit_px("rem", _fs, root), do: root
  def unit_px("pt", _fs, _root), do: 4 / 3
  def unit_px("pc", _fs, _root), do: 16.0
  def unit_px("in", _fs, _root), do: 96.0
  def unit_px("cm", _fs, _root), do: 96 / 2.54
  def unit_px("mm", _fs, _root), do: 96 / 25.4
  def unit_px(u, fs, _root) when u in ["ex", "ch"], do: fs / 2
  def unit_px(_unit, _fs, _root), do: nil

  @doc "True when `value` is one of the math functions."
  def math?(value), do: Regex.match?(~r/\A(?:calc|min|max|clamp|-webkit-calc)\(/i, value)

  def eval(text, units) do
    with {:ok, value, rest} <- expr(String.trim(text), units),
         "" <- String.trim(rest) do
      {:ok, value}
    else
      _ -> :error
    end
  end

  # expr := term (("+" | "-") term)*
  defp expr(s, units) do
    with {:ok, left, rest} <- term(s, units), do: more_terms(left, rest, units)
  end

  defp more_terms(left, s, units) do
    case String.trim_leading(s) do
      <<op, rest::binary>> when op in [?+, ?-] ->
        with {:ok, right, rest} <- term(String.trim_leading(rest), units),
             {:ok, value} <- add(left, right, if(op == ?+, do: 1, else: -1)) do
          more_terms(value, rest, units)
        end

      _ ->
        {:ok, left, s}
    end
  end

  # term := factor (("*" | "/") factor)*
  defp term(s, units) do
    with {:ok, left, rest} <- factor(s, units), do: more_factors(left, rest, units)
  end

  defp more_factors(left, s, units) do
    case String.trim_leading(s) do
      <<op, rest::binary>> when op in [?*, ?/] ->
        with {:ok, right, rest} <- factor(String.trim_leading(rest), units),
             {:ok, value} <- scale(left, right, op) do
          more_factors(value, rest, units)
        end

      _ ->
        {:ok, left, s}
    end
  end

  defp factor("(" <> rest, units) do
    with {:ok, value, rest} <- expr(rest, units),
         ")" <> rest <- String.trim_leading(rest) do
      {:ok, value, rest}
    else
      _ -> :error
    end
  end

  defp factor(<<?-, rest::binary>>, units) do
    case factor(rest, units) do
      {:ok, value, rest} -> {:ok, negate(value), rest}
      other -> other
    end
  end

  defp factor(<<?+, rest::binary>>, units), do: factor(rest, units)

  defp factor(s, units) do
    cond do
      m = Regex.run(~r/\A(-webkit-calc|calc|min|max|clamp)\(/i, s) ->
        [whole, name] = m

        function(
          String.downcase(name),
          binary_part(s, byte_size(whole), byte_size(s) - byte_size(whole)),
          units
        )

      m = Regex.run(~r/\A((?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?)(%|[a-zA-Z]*)/, s) ->
        [whole, n, unit] = m
        rest = binary_part(s, byte_size(whole), byte_size(s) - byte_size(whole))
        number(n, String.downcase(unit), units, rest)

      true ->
        :error
    end
  end

  defp number(n, unit, units, rest) do
    n = to_float(n)

    case unit do
      "" ->
        {:ok, {:num, n}, rest}

      "%" ->
        {:ok, {:pct, n / 100}, rest}

      unit ->
        case units.(unit) do
          px when is_number(px) -> {:ok, {:px, n * px}, rest}
          _ -> :error
        end
    end
  end

  defp to_float(n) do
    n = if String.starts_with?(n, "."), do: "0" <> n, else: n
    n = if String.contains?(n, [".", "e", "E"]), do: n, else: n <> ".0"

    n =
      String.replace(n, [".e", ".E"], fn
        ".e" -> ".0e"
        ".E" -> ".0E"
      end)

    n |> Float.parse() |> elem(0)
  end

  # function arguments, comma separated, up to the closing paren
  defp function(name, s, units) when name in @functions or name == "-webkit-calc" do
    with {:ok, args, rest} <- args(s, units, []) do
      case {name, args} do
        {n, [v]} when n in ["calc", "-webkit-calc"] -> {:ok, v, rest}
        {"min", [_ | _]} -> pick(args, &Enum.min/1, rest)
        {"max", [_ | _]} -> pick(args, &Enum.max/1, rest)
        {"clamp", [lo, v, hi]} -> clamp(lo, v, hi, rest)
        _ -> :error
      end
    end
  end

  defp args(s, units, acc) do
    with {:ok, value, rest} <- expr(String.trim_leading(s), units) do
      case String.trim_leading(rest) do
        "," <> rest -> args(rest, units, [value | acc])
        ")" <> rest -> {:ok, Enum.reverse([value | acc]), rest}
        _ -> :error
      end
    end
  end

  defp pick(args, fun, rest) do
    case same_kind(args) do
      {kind, numbers} -> {:ok, {kind, fun.(numbers)}, rest}
      nil -> :error
    end
  end

  defp clamp(lo, v, hi, rest) do
    case same_kind([lo, v, hi]) do
      {kind, [l, x, h]} -> {:ok, {kind, x |> max(l) |> min(h)}, rest}
      nil -> :error
    end
  end

  defp same_kind([{kind, _} | _] = values) do
    if Enum.all?(values, &(tuple_size(&1) == 2 and elem(&1, 0) == kind)),
      do: {kind, Enum.map(values, &elem(&1, 1))}
  end

  defp same_kind(_), do: nil

  defp add({kind, a}, {kind, b}, sign), do: {:ok, {kind, a + sign * b}}

  # a length and a percentage together: `{:calc, px, fraction}`, worked out once the size
  # the percentage refers to is known
  defp add(a, b, sign) do
    with {pa, fa} <- linear(a), {pb, fb} <- linear(b) do
      {:ok, {:calc, pa + sign * pb, fa + sign * fb}}
    else
      _ -> :error
    end
  end

  defp linear({:px, n}), do: {n, 0.0}
  defp linear({:pct, f}), do: {0.0, f}
  defp linear({:calc, n, f}), do: {n, f}
  defp linear(_), do: nil

  defp scale({:num, a}, {kind, b}, ?*), do: {:ok, {kind, a * b}}
  defp scale({kind, a}, {:num, b}, ?*), do: {:ok, {kind, a * b}}
  defp scale({kind, a}, {:num, b}, ?/) when b != 0 and b != 0.0, do: {:ok, {kind, a / b}}
  defp scale({:num, a}, {:calc, p, f}, ?*), do: {:ok, {:calc, a * p, a * f}}
  defp scale({:calc, p, f}, {:num, b}, ?*), do: {:ok, {:calc, p * b, f * b}}

  defp scale({:calc, p, f}, {:num, b}, ?/) when b != 0 and b != 0.0,
    do: {:ok, {:calc, p / b, f / b}}

  defp scale(_, _, _), do: :error

  defp negate({:calc, p, f}), do: {:calc, -p, -f}
  defp negate({kind, n}), do: {kind, -n}
end
