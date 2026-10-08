defmodule Browser.Wasm.Num do
  @moduledoc """
  The numeric instructions of WebAssembly.

  An `i32` or `i64` is an unsigned integer. An `f32` or `f64` is an Elixir float, or
  `:infinity`, `:neg_infinity` or `{:nan, bits}` (the bit pattern of the NaN, so that
  `reinterpret`, `copysign` and the memory instructions keep payloads). A negative zero is
  `-0.0`.
  """

  import Bitwise
  alias Browser.Wasm.Error

  @nan32 {:nan, 0x7FC00000}
  @nan64 {:nan, 0x7FF8000000000000}
  # 2^128 - 2^103: from here on a double rounds to an f32 infinity
  @f32_limit 3.4028235677973366e38

  def trap(msg), do: Error.fail(:trap, msg)

  # ── float representation ───────────────────────────────────

  def f32_from_bits(bits) do
    case bits do
      0x7F800000 ->
        :infinity

      0xFF800000 ->
        :neg_infinity

      _ when (bits &&& 0x7F800000) == 0x7F800000 ->
        {:nan, bits}

      _ ->
        <<f::float-32>> = <<bits::32>>
        f
    end
  end

  def f64_from_bits(bits) do
    case bits do
      0x7FF0000000000000 ->
        :infinity

      0xFFF0000000000000 ->
        :neg_infinity

      _ when (bits &&& 0x7FF0000000000000) == 0x7FF0000000000000 ->
        {:nan, bits}

      _ ->
        <<f::float-64>> = <<bits::64>>
        f
    end
  end

  def f32_to_bits(:infinity), do: 0x7F800000
  def f32_to_bits(:neg_infinity), do: 0xFF800000
  def f32_to_bits({:nan, b}), do: b

  def f32_to_bits(f) do
    <<b::32>> = <<f::float-32>>
    b
  end

  def f64_to_bits(:infinity), do: 0x7FF0000000000000
  def f64_to_bits(:neg_infinity), do: 0xFFF0000000000000
  def f64_to_bits({:nan, b}), do: b

  def f64_to_bits(f) do
    <<b::64>> = <<f::float-64>>
    b
  end

  @doc "Rounds a finite double to the nearest f32 (a double holding the f32 value)."
  def round32(x) when is_float(x) do
    cond do
      x >= @f32_limit ->
        :infinity

      x <= -@f32_limit ->
        :neg_infinity

      true ->
        <<r::float-32>> = <<x::float-32>>
        r
    end
  end

  def round32(:infinity), do: :infinity
  def round32(:neg_infinity), do: :neg_infinity
  def round32({:nan, _}), do: @nan32

  defp signbit(x) when is_float(x) do
    <<s::1, _::63>> = <<x::float-64>>
    s
  end

  defp class(x) when is_float(x), do: :fin
  defp class({:nan, _}), do: :nan
  defp class(_), do: :inf

  defp sign_of(:infinity), do: 0
  defp sign_of(:neg_infinity), do: 1
  defp sign_of(x), do: signbit(x)

  defp inf(0), do: :infinity
  defp inf(1), do: :neg_infinity

  defp zero(0), do: 0.0
  defp zero(1), do: -0.0

  defp iszero(x), do: is_float(x) and x == 0.0

  # ── f64 arithmetic with the special values ─────────────────

  def fadd(a, b) when is_float(a) and is_float(b) do
    a + b
  rescue
    ArithmeticError -> inf(signbit(a))
  end

  def fadd(a, b) do
    case {class(a), class(b)} do
      {:nan, _} -> @nan64
      {_, :nan} -> @nan64
      {:inf, :inf} -> if sign_of(a) == sign_of(b), do: a, else: @nan64
      {:inf, _} -> a
      {_, :inf} -> b
    end
  end

  def fsub(a, b) when is_float(a) and is_float(b) do
    a - b
  rescue
    ArithmeticError -> inf(signbit(a))
  end

  def fsub(a, b) do
    case {class(a), class(b)} do
      {:nan, _} -> @nan64
      {_, :nan} -> @nan64
      {:inf, :inf} -> if sign_of(a) != sign_of(b), do: a, else: @nan64
      {:inf, _} -> a
      {_, :inf} -> inf(1 - sign_of(b))
    end
  end

  def fmul(a, b) when is_float(a) and is_float(b) do
    a * b
  rescue
    ArithmeticError -> inf(Bitwise.bxor(signbit(a), signbit(b)))
  end

  def fmul(a, b) do
    case {class(a), class(b)} do
      {:nan, _} ->
        @nan64

      {_, :nan} ->
        @nan64

      _ ->
        if iszero(a) or iszero(b), do: @nan64, else: inf(Bitwise.bxor(sign_of(a), sign_of(b)))
    end
  end

  def fdiv(a, b) when is_float(a) and is_float(b) do
    cond do
      b == 0.0 and a == 0.0 -> @nan64
      b == 0.0 -> inf(Bitwise.bxor(signbit(a), signbit(b)))
      true -> a / b
    end
  rescue
    ArithmeticError -> inf(Bitwise.bxor(signbit(a), signbit(b)))
  end

  def fdiv(a, b) do
    case {class(a), class(b)} do
      {:nan, _} -> @nan64
      {_, :nan} -> @nan64
      {:inf, :inf} -> @nan64
      {:inf, _} -> inf(Bitwise.bxor(sign_of(a), sign_of(b)))
      {_, :inf} -> zero(Bitwise.bxor(sign_of(a), sign_of(b)))
    end
  end

  defp key(x) when is_float(x), do: {1, x}
  defp key(:infinity), do: {2, 0}
  defp key(:neg_infinity), do: {0, 0}

  defp isnan(x), do: match?({:nan, _}, x)

  defp fmin(a, b, nan) do
    cond do
      isnan(a) or isnan(b) -> nan
      key(a) < key(b) -> a
      key(a) > key(b) -> b
      iszero(a) -> if signbit(a) == 1, do: a, else: b
      true -> a
    end
  end

  defp fmax(a, b, nan) do
    cond do
      isnan(a) or isnan(b) -> nan
      key(a) > key(b) -> a
      key(a) < key(b) -> b
      iszero(a) -> if signbit(a) == 0, do: a, else: b
      true -> a
    end
  end

  defp fcmp(op, a, b) do
    if isnan(a) or isnan(b) do
      if op == :ne, do: 1, else: 0
    else
      ka = key(a)
      kb = key(b)

      r =
        case op do
          :eq -> ka == kb
          :ne -> ka != kb
          :lt -> ka < kb
          :gt -> ka > kb
          :le -> ka <= kb
          :ge -> ka >= kb
        end

      if r, do: 1, else: 0
    end
  end

  defp fceil(x) when is_float(x), do: :math.ceil(x)
  defp fceil(x), do: if(isnan(x), do: @nan64, else: x)
  defp ffloor(x) when is_float(x), do: :math.floor(x)
  defp ffloor(x), do: if(isnan(x), do: @nan64, else: x)

  defp ftrunc(x) when is_float(x), do: if(x >= 0, do: :math.floor(x), else: :math.ceil(x))
  defp ftrunc(x), do: if(isnan(x), do: @nan64, else: x)

  defp fnearest(x) when is_float(x) do
    f = :math.floor(x)
    d = x - f

    r =
      cond do
        d < 0.5 -> f
        d > 0.5 -> f + 1.0
        rem(trunc(f), 2) == 0 -> f
        true -> f + 1.0
      end

    if r == 0.0 and signbit(x) == 1, do: -0.0, else: r
  end

  defp fnearest(x), do: if(isnan(x), do: @nan64, else: x)

  defp fsqrt(x) when is_float(x) do
    cond do
      x == 0.0 -> x
      x < 0 -> @nan64
      true -> :math.sqrt(x)
    end
  end

  defp fsqrt(:infinity), do: :infinity
  defp fsqrt(_), do: @nan64

  defp abs_bits(:f32, x), do: f32_from_bits(f32_to_bits(x) &&& 0x7FFFFFFF)
  defp abs_bits(:f64, x), do: f64_from_bits(f64_to_bits(x) &&& 0x7FFFFFFFFFFFFFFF)
  defp neg_bits(:f32, x), do: f32_from_bits(bxor(f32_to_bits(x), 0x80000000))
  defp neg_bits(:f64, x), do: f64_from_bits(bxor(f64_to_bits(x), 0x8000000000000000))

  defp copysign(:f32, a, b),
    do: f32_from_bits((f32_to_bits(a) &&& 0x7FFFFFFF) ||| (f32_to_bits(b) &&& 0x80000000))

  defp copysign(:f64, a, b),
    do:
      f64_from_bits(
        (f64_to_bits(a) &&& 0x7FFFFFFFFFFFFFFF) ||| (f64_to_bits(b) &&& 0x8000000000000000)
      )

  # ── integer helpers ────────────────────────────────────────

  defp bitlen(n), do: bitlen(n, 0)
  defp bitlen(0, c), do: c
  defp bitlen(n, c) when n >= 0x10000, do: bitlen(n >>> 16, c + 16)
  defp bitlen(n, c), do: bitlen(n >>> 1, c + 1)

  defp popcnt(0, c), do: c
  defp popcnt(n, c), do: popcnt(n &&& n - 1, c + 1)

  # rounds a non-negative integer to `p` significant bits (ties to even) and returns a float
  defp round_int(0, _), do: 0.0

  defp round_int(n, p) do
    len = bitlen(n)

    if len <= p do
      n * 1.0
    else
      shift = len - p
      q = n >>> shift
      rem = n &&& (1 <<< shift) - 1
      half = 1 <<< (shift - 1)
      q = if rem > half or (rem == half and (q &&& 1) == 1), do: q + 1, else: q
      (q <<< shift) * 1.0
    end
  end

  defp int_to_float(n, p) when n < 0, do: -round_int(-n, p)
  defp int_to_float(n, p), do: round_int(n, p)

  defp trunc_int(x, bits, signed) do
    case x do
      {:nan, _} ->
        trap("invalid conversion to integer")

      v when v in [:infinity, :neg_infinity] ->
        trap("integer overflow")

      _ ->
        t = trunc(x)
        {lo, hi} = range(bits, signed)
        if t < lo or t > hi, do: trap("integer overflow"), else: t &&& (1 <<< bits) - 1
    end
  end

  defp sat_int(x, bits, signed) do
    {lo, hi} = range(bits, signed)

    t =
      case x do
        {:nan, _} -> 0
        :infinity -> hi
        :neg_infinity -> lo
        _ -> x |> trunc() |> max(lo) |> min(hi)
      end

    t &&& (1 <<< bits) - 1
  end

  defp range(bits, true), do: {-(1 <<< (bits - 1)), (1 <<< (bits - 1)) - 1}
  defp range(bits, false), do: {0, (1 <<< bits) - 1}

  defp sext(v, from, mask) do
    sign = 1 <<< (from - 1)
    v = v &&& (1 <<< from) - 1
    if(v >= sign, do: v - (1 <<< from), else: v) &&& mask
  end

  # ── unary ──────────────────────────────────────────────────

  def unop(:i32_eqz, a), do: if(a == 0, do: 1, else: 0)
  def unop(:i64_eqz, a), do: if(a == 0, do: 1, else: 0)
  def unop(:i32_clz, a), do: 32 - bitlen(a)
  def unop(:i64_clz, a), do: 64 - bitlen(a)
  def unop(:i32_ctz, a), do: if(a == 0, do: 32, else: bitlen(a &&& -a) - 1)
  def unop(:i64_ctz, a), do: if(a == 0, do: 64, else: bitlen(a &&& -a) - 1)
  def unop(:i32_popcnt, a), do: popcnt(a, 0)
  def unop(:i64_popcnt, a), do: popcnt(a, 0)

  def unop(:f32_abs, a), do: abs_bits(:f32, a)
  def unop(:f64_abs, a), do: abs_bits(:f64, a)
  def unop(:f32_neg, a), do: neg_bits(:f32, a)
  def unop(:f64_neg, a), do: neg_bits(:f64, a)
  def unop(:f32_ceil, a), do: round32(fceil(a))
  def unop(:f64_ceil, a), do: fceil(a)
  def unop(:f32_floor, a), do: round32(ffloor(a))
  def unop(:f64_floor, a), do: ffloor(a)
  def unop(:f32_trunc, a), do: round32(ftrunc(a))
  def unop(:f64_trunc, a), do: ftrunc(a)
  def unop(:f32_nearest, a), do: round32(fnearest(a))
  def unop(:f64_nearest, a), do: fnearest(a)
  def unop(:f32_sqrt, a), do: round32(fsqrt(a))
  def unop(:f64_sqrt, a), do: fsqrt(a)

  def unop(:i32_wrap_i64, a), do: a &&& 0xFFFFFFFF
  def unop(:i64_extend_i32_s, a), do: sext(a, 32, 0xFFFFFFFFFFFFFFFF)
  def unop(:i64_extend_i32_u, a), do: a
  def unop(:i32_extend8_s, a), do: sext(a, 8, 0xFFFFFFFF)
  def unop(:i32_extend16_s, a), do: sext(a, 16, 0xFFFFFFFF)
  def unop(:i64_extend8_s, a), do: sext(a, 8, 0xFFFFFFFFFFFFFFFF)
  def unop(:i64_extend16_s, a), do: sext(a, 16, 0xFFFFFFFFFFFFFFFF)
  def unop(:i64_extend32_s, a), do: sext(a, 32, 0xFFFFFFFFFFFFFFFF)

  def unop(:i32_trunc_f32_s, a), do: trunc_int(a, 32, true)
  def unop(:i32_trunc_f32_u, a), do: trunc_int(a, 32, false)
  def unop(:i32_trunc_f64_s, a), do: trunc_int(a, 32, true)
  def unop(:i32_trunc_f64_u, a), do: trunc_int(a, 32, false)
  def unop(:i64_trunc_f32_s, a), do: trunc_int(a, 64, true)
  def unop(:i64_trunc_f32_u, a), do: trunc_int(a, 64, false)
  def unop(:i64_trunc_f64_s, a), do: trunc_int(a, 64, true)
  def unop(:i64_trunc_f64_u, a), do: trunc_int(a, 64, false)
  def unop(:i32_trunc_sat_f32_s, a), do: sat_int(a, 32, true)
  def unop(:i32_trunc_sat_f32_u, a), do: sat_int(a, 32, false)
  def unop(:i32_trunc_sat_f64_s, a), do: sat_int(a, 32, true)
  def unop(:i32_trunc_sat_f64_u, a), do: sat_int(a, 32, false)
  def unop(:i64_trunc_sat_f32_s, a), do: sat_int(a, 64, true)
  def unop(:i64_trunc_sat_f32_u, a), do: sat_int(a, 64, false)
  def unop(:i64_trunc_sat_f64_s, a), do: sat_int(a, 64, true)
  def unop(:i64_trunc_sat_f64_u, a), do: sat_int(a, 64, false)

  def unop(:f32_convert_i32_s, a), do: round32(int_to_float(sext(a, 32, -1), 24))
  def unop(:f32_convert_i32_u, a), do: round32(int_to_float(a, 24))
  def unop(:f32_convert_i64_s, a), do: round32(int_to_float(sext(a, 64, -1), 24))
  def unop(:f32_convert_i64_u, a), do: round32(int_to_float(a, 24))
  def unop(:f64_convert_i32_s, a), do: int_to_float(sext(a, 32, -1), 53)
  def unop(:f64_convert_i32_u, a), do: int_to_float(a, 53)
  def unop(:f64_convert_i64_s, a), do: int_to_float(sext(a, 64, -1), 53)
  def unop(:f64_convert_i64_u, a), do: int_to_float(a, 53)
  def unop(:f32_demote_f64, a), do: round32(a)
  def unop(:f64_promote_f32, {:nan, _}), do: @nan64
  def unop(:f64_promote_f32, a), do: a
  def unop(:i32_reinterpret_f32, a), do: f32_to_bits(a)
  def unop(:i64_reinterpret_f64, a), do: f64_to_bits(a)
  def unop(:f32_reinterpret_i32, a), do: f32_from_bits(a)
  def unop(:f64_reinterpret_i64, a), do: f64_from_bits(a)

  # ── binary ─────────────────────────────────────────────────

  for {bits, t} <- [{32, :i32}, {64, :i64}] do
    mask = (1 <<< bits) - 1
    sign = 1 <<< (bits - 1)
    mod = 1 <<< bits
    name = fn op -> :"#{t}_#{op}" end

    def binop(unquote(name.(:add)), a, b), do: a + b &&& unquote(mask)
    def binop(unquote(name.(:sub)), a, b), do: a - b &&& unquote(mask)
    def binop(unquote(name.(:mul)), a, b), do: a * b &&& unquote(mask)
    def binop(unquote(name.(:and)), a, b), do: a &&& b
    def binop(unquote(name.(:or)), a, b), do: a ||| b
    def binop(unquote(name.(:xor)), a, b), do: bxor(a, b)

    def binop(unquote(name.(:div_u)), a, b) do
      if b == 0, do: trap("integer divide by zero"), else: div(a, b)
    end

    def binop(unquote(name.(:rem_u)), a, b) do
      if b == 0, do: trap("integer divide by zero"), else: rem(a, b)
    end

    def binop(unquote(name.(:div_s)), a, b) do
      if b == 0, do: trap("integer divide by zero")
      sa = if a >= unquote(sign), do: a - unquote(mod), else: a
      sb = if b >= unquote(sign), do: b - unquote(mod), else: b
      if sa == -unquote(sign) and sb == -1, do: trap("integer overflow")
      div(sa, sb) &&& unquote(mask)
    end

    def binop(unquote(name.(:rem_s)), a, b) do
      if b == 0, do: trap("integer divide by zero")
      sa = if a >= unquote(sign), do: a - unquote(mod), else: a
      sb = if b >= unquote(sign), do: b - unquote(mod), else: b
      rem(sa, sb) &&& unquote(mask)
    end

    def binop(unquote(name.(:shl)), a, b), do: a <<< (b &&& unquote(bits - 1)) &&& unquote(mask)
    def binop(unquote(name.(:shr_u)), a, b), do: a >>> (b &&& unquote(bits - 1))

    def binop(unquote(name.(:shr_s)), a, b) do
      sa = if a >= unquote(sign), do: a - unquote(mod), else: a
      sa >>> (b &&& unquote(bits - 1)) &&& unquote(mask)
    end

    def binop(unquote(name.(:rotl)), a, b) do
      k = b &&& unquote(bits - 1)
      (a <<< k ||| a >>> (unquote(bits) - k)) &&& unquote(mask)
    end

    def binop(unquote(name.(:rotr)), a, b) do
      k = b &&& unquote(bits - 1)
      (a >>> k ||| a <<< (unquote(bits) - k)) &&& unquote(mask)
    end

    def binop(unquote(name.(:eq)), a, b), do: if(a == b, do: 1, else: 0)
    def binop(unquote(name.(:ne)), a, b), do: if(a != b, do: 1, else: 0)
    def binop(unquote(name.(:lt_u)), a, b), do: if(a < b, do: 1, else: 0)
    def binop(unquote(name.(:gt_u)), a, b), do: if(a > b, do: 1, else: 0)
    def binop(unquote(name.(:le_u)), a, b), do: if(a <= b, do: 1, else: 0)
    def binop(unquote(name.(:ge_u)), a, b), do: if(a >= b, do: 1, else: 0)

    for {op, cmp} <- [lt_s: :<, gt_s: :>, le_s: :<=, ge_s: :>=] do
      def binop(unquote(name.(op)), a, b) do
        sa = if a >= unquote(sign), do: a - unquote(mod), else: a
        sb = if b >= unquote(sign), do: b - unquote(mod), else: b
        if unquote(cmp)(sa, sb), do: 1, else: 0
      end
    end
  end

  for t <- [:f32, :f64] do
    wrap = if t == :f32, do: &__MODULE__.round32/1, else: & &1
    nan = if t == :f32, do: Macro.escape(@nan32), else: Macro.escape(@nan64)

    for {op, fun} <- [add: :fadd, sub: :fsub, mul: :fmul, div: :fdiv] do
      if t == :f32 do
        def binop(unquote(:"#{t}_#{op}"), a, b), do: round32(unquote(fun)(a, b))
      else
        def binop(unquote(:"#{t}_#{op}"), a, b), do: unquote(fun)(a, b)
      end
    end

    _ = wrap

    def binop(unquote(:"#{t}_min"), a, b), do: fmin(a, b, unquote(nan))
    def binop(unquote(:"#{t}_max"), a, b), do: fmax(a, b, unquote(nan))
    def binop(unquote(:"#{t}_copysign"), a, b), do: copysign(unquote(t), a, b)

    for op <- [:eq, :ne, :lt, :gt, :le, :ge] do
      def binop(unquote(:"#{t}_#{op}"), a, b), do: fcmp(unquote(op), a, b)
    end
  end
end
