defmodule Browser.JS.NumberFormat do
  @moduledoc """
  `Number.prototype.toFixed`, `toExponential`, `toPrecision` and `toString(radix)`, computed
  exactly: a float is a ratio of integers, so rounding to a number of digits is integer
  arithmetic and there is no binary rounding error in the digits.
  """

  alias Browser.JS.{Interp, Num}

  @doc "`x.toFixed(digits)`, `x` a finite or non-finite number, `digits` already an integer."
  def to_fixed(x, d) do
    if d < 0 or d > 100,
      do: Interp.throw_error("RangeError", "toFixed() digits argument must be between 0 and 100")

    if x in [:nan, :infinity, :neg_infinity] or abs(x) >= 1.0e21 do
      Num.to_string(x)
    else
      {sign, ax} = split_sign(x)
      {a, b} = ratio(ax)
      n = round_div(a * pow10(d), b)
      digits = n |> Integer.to_string() |> String.pad_leading(d + 1, "0")

      body =
        if d == 0 do
          digits
        else
          {int, frac} = String.split_at(digits, String.length(digits) - d)
          int <> "." <> frac
        end

      sign <> body
    end
  end

  @doc "`x.toExponential(f)`: `f` is an integer, or `:undefined` for as many digits as needed."
  def to_exponential(x, _f) when x in [:nan, :infinity, :neg_infinity], do: Num.to_string(x)

  def to_exponential(x, f) do
    if f != :undefined and (f < 0 or f > 100), do: range_error("toExponential", 0)

    {sign, ax} = split_sign(x)

    {digits, e} =
      cond do
        ax == 0 -> {String.duplicate("0", if(f == :undefined, do: 1, else: f + 1)), 0}
        f == :undefined -> shortest(ax)
        true -> digits_exp(ax, f + 1)
      end

    {first, rest} = String.split_at(digits, 1)
    m = if rest == "", do: first, else: first <> "." <> rest
    sign <> m <> exp_suffix(e)
  end

  @doc "`x.toPrecision(p)`: `p` is an integer, or `:undefined` for `ToString(x)`."
  def to_precision(x, :undefined), do: Num.to_string(x)

  def to_precision(x, _p) when x in [:nan, :infinity, :neg_infinity], do: Num.to_string(x)

  def to_precision(x, p) do
    if p < 1 or p > 100, do: range_error("toPrecision", 1)

    {sign, ax} = split_sign(x)

    {digits, e} =
      if ax == 0, do: {String.duplicate("0", p), 0}, else: digits_exp(ax, p)

    body =
      cond do
        e < -6 or e >= p ->
          {first, rest} = String.split_at(digits, 1)
          if(rest == "", do: first, else: first <> "." <> rest) <> exp_suffix(e)

        e == p - 1 ->
          digits

        e >= 0 ->
          {int, frac} = String.split_at(digits, e + 1)
          int <> "." <> frac

        true ->
          "0." <> String.duplicate("0", -(e + 1)) <> digits
      end

    sign <> body
  end

  @doc "`x.toString(radix)` for a radix other than 10."
  def to_radix(x, _r) when x in [:nan, :infinity, :neg_infinity], do: Num.to_string(x)

  def to_radix(x, r) do
    {sign, ax} = split_sign(x)
    int = trunc(ax)
    int_s = int |> Integer.to_string(r) |> String.downcase()
    frac = ax - int

    frac_s =
      if frac == 0 do
        ""
      else
        "." <> fraction_digits(frac, r, 52, [])
      end

    sign <> int_s <> frac_s
  end

  defp fraction_digits(_frac, _r, 0, acc), do: acc |> Enum.reverse() |> to_string()

  defp fraction_digits(frac, r, left, acc) do
    v = frac * r
    d = trunc(v)
    acc = [Integer.to_string(d, r) |> String.downcase() | acc]
    rest = v - d

    if rest == 0,
      do: acc |> Enum.reverse() |> to_string(),
      else: fraction_digits(rest, r, left - 1, acc)
  end

  # ── helpers ────────────────────────────────────────────────

  defp split_sign(x) when x < 0, do: {"-", -x}
  defp split_sign(x), do: {"", x * 1.0}

  defp range_error(name, min),
    do: Interp.throw_error("RangeError", "#{name}() argument must be between #{min} and 100")

  defp pow10(k), do: Integer.pow(10, k)

  defp ratio(x) when is_float(x), do: Float.ratio(x)
  defp ratio(x), do: {x, 1}

  # round half up
  defp round_div(num, den), do: div(2 * num + den, 2 * den)

  # `p` significant digits of `ax` > 0, as {digit string, decimal exponent of the first digit}
  defp digits_exp(ax, p) do
    {a, b} = ratio(ax)
    e0 = ax |> :math.log10() |> Float.floor() |> trunc()
    digits_exp(a, b, p, e0)
  end

  defp digits_exp(a, b, p, e) do
    {n, e} = scaled(a, b, p, e)

    # n = 10^(p-1) may be the rounding of something just below it: the next exponent down can be
    # the closer representation
    if n == pow10(p - 1) do
      {n2, e2} = scaled(a, b, p, e - 1)

      if n2 < pow10(p) and error(a, b, p, n2, e2) < error(a, b, p, n, e) do
        {Integer.to_string(n2), e2}
      else
        {Integer.to_string(n), e}
      end
    else
      {Integer.to_string(n), e}
    end
  end

  defp scaled(a, b, p, e) do
    k = p - 1 - e

    n =
      if k >= 0,
        do: round_div(a * pow10(k), b),
        else: round_div(a, b * pow10(-k))

    cond do
      n >= pow10(p) -> scaled(a, b, p, e + 1)
      n < pow10(p - 1) -> scaled(a, b, p, e - 1)
      true -> {n, e}
    end
  end

  # |n * 10^(e-p+1) - a/b| * b * 10^s, an integer
  defp error(a, b, p, n, e) do
    s = max(0, p - e + 1)
    abs(n * pow10(e - p + 1 + s) * b - a * pow10(s))
  end

  # the shortest digits that round-trip, as {digits, exponent of the first digit}
  defp shortest(ax) do
    s = :erlang.float_to_binary(ax, [:short])

    {mant, exp} =
      case String.split(s, "e") do
        [m, e] -> {m, String.to_integer(e)}
        [m] -> {m, 0}
      end

    [int, frac] =
      case String.split(mant, ".") do
        [i, f] -> [i, f]
        [i] -> [i, ""]
      end

    all = int <> frac
    lead = String.length(all) - String.length(String.trim_leading(all, "0"))
    digits = all |> String.trim_leading("0") |> String.trim_trailing("0")
    digits = if digits == "", do: "0", else: digits
    {digits, String.length(int) - 1 - lead + exp}
  end

  defp exp_suffix(e), do: "e" <> if(e >= 0, do: "+", else: "-") <> Integer.to_string(abs(e))
end
