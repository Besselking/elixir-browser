defmodule Browser.JS.Num do
  @moduledoc """
  JavaScript's Number type on the BEAM.

  A number is a float, or one of `:nan`, `:infinity`, `:neg_infinity` (the BEAM has no
  non-finite floats). Integers are tolerated as inputs and treated as their float value.
  """

  import Bitwise

  @type t :: float | integer | :nan | :infinity | :neg_infinity

  @doc "Number::toString (radix 10)."
  def to_string(:nan), do: "NaN"
  def to_string(:infinity), do: "Infinity"
  def to_string(:neg_infinity), do: "-Infinity"
  def to_string(n) when is_integer(n), do: Integer.to_string(n)
  def to_string(f) when f == 0, do: "0"
  def to_string(f) when f < 0, do: "-" <> __MODULE__.to_string(-f)

  def to_string(f) when f < 9.007199254740992e15 and f == trunc(f),
    do: Integer.to_string(trunc(f))

  def to_string(f) do
    {digits, n} = digits(f)
    k = byte_size(digits)

    cond do
      k <= n and n <= 21 -> digits <> String.duplicate("0", n - k)
      0 < n and n <= 21 -> binary_part(digits, 0, n) <> "." <> binary_part(digits, n, k - n)
      -6 < n and n <= 0 -> "0." <> String.duplicate("0", -n) <> digits
      true -> exponent_form(digits, n - 1)
    end
  end

  defp exponent_form(digits, e) do
    sign = if e < 0, do: "-", else: "+"

    mantissa =
      if byte_size(digits) == 1,
        do: digits,
        else: String.first(digits) <> "." <> binary_part(digits, 1, byte_size(digits) - 1)

    mantissa <> "e" <> sign <> Integer.to_string(abs(e))
  end

  # shortest round-trip digits of a positive float, and the decimal point position `n`
  # such that the value is 0.DIGITS × 10^n
  defp digits(f) do
    s = Float.to_string(f)

    {mantissa, exp} =
      case String.split(s, "e") do
        [m, e] -> {m, String.to_integer(e)}
        [m] -> {m, 0}
      end

    [int, frac] = String.split(mantissa, ".")

    {ds, n} =
      if int != "0" do
        {int <> frac, byte_size(int)}
      else
        stripped = String.trim_leading(frac, "0")
        {stripped, -(byte_size(frac) - byte_size(stripped))}
      end

    ds = String.trim_trailing(ds, "0")
    {if(ds == "", do: "0", else: ds), n + exp}
  end

  @doc "ToNumber on a string."
  def parse(s) do
    s = String.trim(s)

    cond do
      s == "" ->
        0.0

      s in ["Infinity", "+Infinity"] ->
        :infinity

      s == "-Infinity" ->
        :neg_infinity

      Regex.match?(~r/\A0[xX][0-9a-fA-F]+\z/, s) ->
        String.to_integer(binary_part(s, 2, byte_size(s) - 2), 16) * 1.0

      Regex.match?(~r/\A0[oO][0-7]+\z/, s) ->
        String.to_integer(binary_part(s, 2, byte_size(s) - 2), 8) * 1.0

      Regex.match?(~r/\A0[bB][01]+\z/, s) ->
        String.to_integer(binary_part(s, 2, byte_size(s) - 2), 2) * 1.0

      Regex.match?(~r/\A[+-]?(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?\z/, s) ->
        float(s)

      true ->
        :nan
    end
  end

  @doc "The longest numeric prefix (what parseFloat reads), or `:nan`."
  def parse_prefix(s) do
    case Regex.run(
           ~r/\A([+-]?(?:Infinity|\d+\.?\d*(?:[eE][+-]?\d+)?|\.\d+(?:[eE][+-]?\d+)?))/,
           Browser.JS.Interp.js_trim_start(s)
         ) do
      [_, m] -> parse(m)
      _ -> :nan
    end
  end

  defp float(s) do
    s = if String.starts_with?(s, "+"), do: String.slice(s, 1..-1//1), else: s
    s = Regex.replace(~r/\A(-?)\./, s, "\\g{1}0.")
    s = if Regex.match?(~r/\A-?\d+\z/, s), do: s <> ".0", else: s

    s =
      Regex.replace(~r/(\d)(e|E)/, s, fn _, d, e ->
        if String.contains?(s, "."), do: d <> e, else: d <> ".0" <> e
      end)

    s = Regex.replace(~r/\.(e|E)/, s, ".0\\1")

    case Float.parse(s) do
      {f, _} -> f
      :error -> out_of_range(s)
    end
  rescue
    ArgumentError -> out_of_range(s)
  end

  # a float literal out of range: huge exponents overflow, tiny ones underflow
  defp out_of_range(s) do
    cond do
      not Regex.match?(~r/\A[+-]?(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?\z/, s) -> :nan
      not Regex.match?(~r/[1-9]/, hd(String.split(s, ~r/[eE]/))) -> 0.0
      Regex.match?(~r/[eE]-/, s) -> if String.starts_with?(s, "-"), do: -0.0, else: 0.0
      String.starts_with?(s, "-") -> :neg_infinity
      true -> :infinity
    end
  end

  @doc "ToInt32."
  def int32(n) when n in [:nan, :infinity, :neg_infinity], do: 0

  def int32(n) do
    x = band(trunc(n), 0xFFFFFFFF)
    if x >= 0x80000000, do: x - 0x100000000, else: x
  end

  def uint32(n), do: band(int32(n), 0xFFFFFFFF)

  # far from the overflow limit a float add cannot raise, so it needs no `guard`
  def add(a, b)
      when is_float(a) and is_float(b) and a < 1.0e300 and a > -1.0e300 and b < 1.0e300 and
             b > -1.0e300,
      do: a + b

  def add(:nan, _), do: :nan
  def add(_, :nan), do: :nan
  def add(:infinity, :neg_infinity), do: :nan
  def add(:neg_infinity, :infinity), do: :nan
  def add(a, _) when is_atom(a), do: a
  def add(_, b) when is_atom(b), do: b
  def add(a, b), do: guard(fn -> a + b end, sign(a))

  def sub(a, b), do: add(a, neg(b))

  def neg(:nan), do: :nan
  def neg(:infinity), do: :neg_infinity
  def neg(:neg_infinity), do: :infinity
  def neg(n), do: -n * 1.0

  def mul(a, b)
      when is_float(a) and is_float(b) and a < 1.0e150 and a > -1.0e150 and b < 1.0e150 and
             b > -1.0e150,
      do: a * b

  def mul(:nan, _), do: :nan
  def mul(_, :nan), do: :nan

  def mul(a, b) when is_atom(a) or is_atom(b) do
    cond do
      a == 0 or b == 0 -> :nan
      sign(a) * sign(b) > 0 -> :infinity
      true -> :neg_infinity
    end
  end

  def mul(a, b), do: guard(fn -> a * b end, sign(a) * sign(b))

  def div(:nan, _), do: :nan
  def div(_, :nan), do: :nan
  def div(a, b) when is_atom(a) and is_atom(b), do: :nan
  def div(a, b) when is_atom(a), do: if(sign(b) < 0, do: neg(a), else: a)
  def div(_, b) when is_atom(b), do: 0.0

  def div(a, b) when b == 0 do
    cond do
      a == 0 -> :nan
      sign(a) * sign(b) > 0 -> :infinity
      true -> :neg_infinity
    end
  end

  def div(a, b), do: guard(fn -> a / b end, sign(a) * sign(b))

  def mod(a, _) when a in [:nan, :infinity, :neg_infinity], do: :nan
  def mod(_, :nan), do: :nan
  def mod(a, b) when is_atom(b), do: a
  def mod(_, b) when b == 0, do: :nan
  def mod(a, b), do: :math.fmod(a * 1.0, b * 1.0)

  def pow(_, b) when b == 0, do: 1.0
  def pow(:nan, _), do: :nan
  def pow(_, :nan), do: :nan

  def pow(a, :infinity),
    do: if(abs_gt1(a), do: :infinity, else: if(abs_eq1(a), do: :nan, else: 0.0))

  def pow(a, :neg_infinity),
    do: if(abs_gt1(a), do: 0.0, else: if(abs_eq1(a), do: :nan, else: :infinity))

  def pow(:infinity, b), do: if(b > 0, do: :infinity, else: 0.0)

  def pow(:neg_infinity, b),
    do:
      if(b > 0,
        do: if(odd?(b), do: :neg_infinity, else: :infinity),
        else: if(odd?(b), do: -0.0, else: 0.0)
      )

  def pow(a, b) when a < 0 and b != trunc(b), do: :nan

  def pow(a, b),
    do: guard(fn -> :math.pow(a * 1.0, b * 1.0) end, if(sign(a) < 0 and odd?(b), do: -1, else: 1))

  defp abs_gt1(a), do: a == :infinity or a == :neg_infinity or abs(a) > 1
  defp abs_eq1(a), do: not is_atom(a) and abs(a) == 1
  defp odd?(b), do: b == trunc(b) and rem(trunc(b), 2) != 0

  @doc "Orders two numbers: `:lt | :eq | :gt`, or `:nan` when either is NaN."
  def compare(:nan, _), do: :nan
  def compare(_, :nan), do: :nan
  def compare(a, a) when is_atom(a), do: :eq
  def compare(:neg_infinity, _), do: :lt
  def compare(_, :infinity), do: :lt
  def compare(:infinity, _), do: :gt
  def compare(_, :neg_infinity), do: :gt
  def compare(a, b) when a < b, do: :lt
  def compare(a, b) when a > b, do: :gt
  def compare(_, _), do: :eq

  def equal?(a, b), do: compare(a, b) == :eq

  def shift(op, a, b) do
    l = int32(a)
    n = band(uint32(b), 31)

    case op do
      "<<" -> int32(l <<< n)
      ">>" -> l >>> n
      ">>>" -> uint32(a) >>> n
    end
    |> Kernel.*(1.0)
  end

  def bitop(op, a, b) do
    x = int32(a)
    y = int32(b)

    case op do
      "&" -> band(x, y)
      "|" -> bor(x, y)
      "^" -> bxor(x, y)
    end
    |> int32()
    |> Kernel.*(1.0)
  end

  defp sign(:infinity), do: 1
  defp sign(:neg_infinity), do: -1
  defp sign(n) when n < 0, do: -1

  defp sign(n) when n == 0,
    do: if(match?(<<1::1, _::63>>, <<n * 1.0::float-64>>), do: -1, else: 1)

  defp sign(_), do: 1

  # float overflow raises on the BEAM; JavaScript saturates to Infinity
  defp guard(fun, sign) do
    fun.() * 1.0
  rescue
    ArithmeticError -> if sign < 0, do: :neg_infinity, else: :infinity
  end
end
