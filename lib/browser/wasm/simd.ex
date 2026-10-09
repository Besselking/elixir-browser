defmodule Browser.Wasm.Simd do
  @moduledoc """
  The 128-bit SIMD instructions of WebAssembly.

  A `v128` is an unsigned 128-bit integer. Lane 0 is in the lowest bits, like the byte order
  of the memory. A float lane is the bit pattern of the float: the arithmetic uses the
  functions of `Browser.Wasm.Num` on the decoded lanes.
  """

  import Bitwise
  alias Browser.Wasm.{Memory, Num}

  @mask128 (1 <<< 128) - 1

  defp bits(shape) when shape in [:i8x16], do: 8
  defp bits(:i16x8), do: 16
  defp bits(shape) when shape in [:i32x4, :f32x4], do: 32
  defp bits(shape) when shape in [:i64x2, :f64x2], do: 64

  defp mask(b), do: (1 <<< b) - 1

  defp sx(x, b), do: if(x >= 1 <<< (b - 1), do: x - (1 <<< b), else: x)

  @doc "The lanes of `v` as unsigned integers of `b` bits, lane 0 first."
  def lanes(v, b) do
    bin = <<v::little-128>>
    for <<x::little-size(^b) <- bin>>, do: x
  end

  @doc "The inverse of `lanes/2`."
  def pack(list, b) do
    <<v::little-128>> = for x <- list, into: <<>>, do: <<x::little-size(b)>>
    v
  end

  # ── execution ──────────────────────────────────────────────

  @doc "Runs the instruction `{shape, op}` on its arguments (in the order of the parameters)."
  def exec(:v128, op, args, _), do: v128(op, args)

  def exec(:i8x16, :swizzle, [a, s], _) do
    la = List.to_tuple(lanes(a, 8))
    pack(for(i <- lanes(s, 8), do: if(i < 16, do: elem(la, i), else: 0)), 8)
  end

  def exec(:i8x16, :shuffle, [a, b], idx) do
    l = List.to_tuple(lanes(a, 8) ++ lanes(b, 8))
    pack(for(i <- idx, do: elem(l, i)), 8)
  end

  def exec(shape, op, args, imm) when shape in [:f32x4, :f64x2], do: float(shape, op, args, imm)
  def exec(shape, op, args, imm), do: int(shape, bits(shape), op, args, imm)

  defp v128(:not, [a]), do: bxor(a, @mask128)
  defp v128(:and, [a, b]), do: band(a, b)
  defp v128(:andnot, [a, b]), do: band(a, bxor(b, @mask128))
  defp v128(:or, [a, b]), do: bor(a, b)
  defp v128(:xor, [a, b]), do: bxor(a, b)
  defp v128(:bitselect, [a, b, c]), do: bor(band(a, c), band(b, bxor(c, @mask128)))
  defp v128(:any_true, [a]), do: if(a != 0, do: 1, else: 0)

  # ── integer lanes ──────────────────────────────────────────

  defp int(_, b, :splat, [x], _), do: pack(List.duplicate(x &&& mask(b), div(128, b)), b)

  defp int(_, b, :extract_lane_u, [v], i), do: Enum.at(lanes(v, b), i)
  defp int(_, b, :extract_lane_s, [v], i), do: sx(Enum.at(lanes(v, b), i), b) &&& 0xFFFFFFFF
  defp int(_, b, :extract_lane, [v], i), do: Enum.at(lanes(v, b), i)

  defp int(_, b, :replace_lane, [v, x], i),
    do: pack(List.replace_at(lanes(v, b), i, x &&& mask(b)), b)

  defp int(_, b, :all_true, [v], _), do: if(Enum.all?(lanes(v, b), &(&1 != 0)), do: 1, else: 0)

  defp int(_, b, :bitmask, [v], _) do
    lanes(v, b)
    |> Enum.with_index()
    |> Enum.reduce(0, fn {x, i}, acc -> acc ||| (x >>> (b - 1)) <<< i end)
  end

  defp int(_, b, :abs, [v], _), do: map(v, b, fn x -> abs(sx(x, b)) &&& mask(b) end)
  defp int(_, b, :neg, [v], _), do: map(v, b, fn x -> -x &&& mask(b) end)

  defp int(_, 8, :popcnt, [v], _), do: map(v, 8, fn x -> Num.unop(:i32_popcnt, x) end)

  defp int(_, b, :shl, [v, s], _), do: map(v, b, fn x -> x <<< (s &&& b - 1) &&& mask(b) end)
  defp int(_, b, :shr_u, [v, s], _), do: map(v, b, fn x -> x >>> (s &&& b - 1) end)

  defp int(_, b, :shr_s, [v, s], _),
    do: map(v, b, fn x -> sx(x, b) >>> (s &&& b - 1) &&& mask(b) end)

  defp int(_, b, :add, [x, y], _), do: zip(x, y, b, fn p, q -> p + q &&& mask(b) end)
  defp int(_, b, :sub, [x, y], _), do: zip(x, y, b, fn p, q -> p - q &&& mask(b) end)
  defp int(_, b, :mul, [x, y], _), do: zip(x, y, b, fn p, q -> p * q &&& mask(b) end)

  defp int(_, b, :add_sat_u, [x, y], _), do: zip(x, y, b, fn p, q -> min(p + q, mask(b)) end)
  defp int(_, b, :sub_sat_u, [x, y], _), do: zip(x, y, b, fn p, q -> max(p - q, 0) end)

  defp int(_, b, :add_sat_s, [x, y], _),
    do: zip(x, y, b, fn p, q -> clamp_s(sx(p, b) + sx(q, b), b) end)

  defp int(_, b, :sub_sat_s, [x, y], _),
    do: zip(x, y, b, fn p, q -> clamp_s(sx(p, b) - sx(q, b), b) end)

  defp int(_, b, :min_u, [x, y], _), do: zip(x, y, b, &min/2)
  defp int(_, b, :max_u, [x, y], _), do: zip(x, y, b, &max/2)

  defp int(_, b, :min_s, [x, y], _),
    do: zip(x, y, b, fn p, q -> if sx(p, b) <= sx(q, b), do: p, else: q end)

  defp int(_, b, :max_s, [x, y], _),
    do: zip(x, y, b, fn p, q -> if sx(p, b) >= sx(q, b), do: p, else: q end)

  defp int(_, b, :avgr_u, [x, y], _), do: zip(x, y, b, fn p, q -> (p + q + 1) >>> 1 end)

  defp int(_, 16, :q15mulr_sat_s, [x, y], _),
    do: zip(x, y, 16, fn p, q -> clamp_s((sx(p, 16) * sx(q, 16) + 0x4000) >>> 15, 16) end)

  defp int(_, b, op, [x, y], _)
       when op in [:eq, :ne, :lt_s, :lt_u, :gt_s, :gt_u, :le_s, :le_u, :ge_s, :ge_u] do
    zip(x, y, b, fn p, q -> if compare(op, p, q, b), do: mask(b), else: 0 end)
  end

  # the lanes of the arguments are twice as wide, and saturate
  defp int(_, b, {:narrow, sign}, [x, y], _) do
    src = lanes(x, 2 * b) ++ lanes(y, 2 * b)

    pack(
      for(
        v <- src,
        do: if(sign == :s, do: clamp_s(sx(v, 2 * b), b), else: clamp_u(sx(v, 2 * b), b))
      ),
      b
    )
  end

  defp int(_, b, {:extend, half, sign}, [x], _) do
    half_of(x, b, half) |> Enum.map(&ext(&1, div(b, 2), sign, b)) |> pack(b)
  end

  defp int(_, b, {:extmul, half, sign}, [x, y], _) do
    sb = div(b, 2)

    Enum.zip_with(half_of(x, b, half), half_of(y, b, half), fn p, q ->
      ext(p, sb, sign, b) * ext(q, sb, sign, b) &&& mask(b)
    end)
    |> pack(b)
  end

  defp int(_, b, {:extadd_pairwise, sign}, [x], _) do
    sb = div(b, 2)

    lanes(x, sb)
    |> Enum.chunk_every(2)
    |> Enum.map(fn [p, q] -> ext(p, sb, sign, b) + ext(q, sb, sign, b) &&& mask(b) end)
    |> pack(b)
  end

  defp int(_, 32, :dot_i16x8_s, [x, y], _) do
    Enum.zip_with(lanes(x, 16), lanes(y, 16), fn p, q -> sx(p, 16) * sx(q, 16) end)
    |> Enum.chunk_every(2)
    |> Enum.map(fn [p, q] -> p + q &&& mask(32) end)
    |> pack(32)
  end

  defp int(:i32x4, 32, {:trunc_sat, sign}, [x], _) do
    lanes(x, 32)
    |> Enum.map(
      &Num.unop(
        if(sign == :s, do: :i32_trunc_sat_f32_s, else: :i32_trunc_sat_f32_u),
        Num.f32_from_bits(&1)
      )
    )
    |> pack(32)
  end

  defp int(:i32x4, 32, {:trunc_sat_zero, sign}, [x], _) do
    op = if sign == :s, do: :i32_trunc_sat_f64_s, else: :i32_trunc_sat_f64_u

    lanes(x, 64)
    |> Enum.map(&Num.unop(op, Num.f64_from_bits(&1)))
    |> Kernel.++([0, 0])
    |> pack(32)
  end

  defp compare(:eq, p, q, _), do: p == q
  defp compare(:ne, p, q, _), do: p != q
  defp compare(:lt_u, p, q, _), do: p < q
  defp compare(:gt_u, p, q, _), do: p > q
  defp compare(:le_u, p, q, _), do: p <= q
  defp compare(:ge_u, p, q, _), do: p >= q
  defp compare(:lt_s, p, q, b), do: sx(p, b) < sx(q, b)
  defp compare(:gt_s, p, q, b), do: sx(p, b) > sx(q, b)
  defp compare(:le_s, p, q, b), do: sx(p, b) <= sx(q, b)
  defp compare(:ge_s, p, q, b), do: sx(p, b) >= sx(q, b)

  defp clamp_s(v, b),
    do: v |> max(-(1 <<< (b - 1))) |> min((1 <<< (b - 1)) - 1) |> Bitwise.band(mask(b))

  defp clamp_u(v, b), do: v |> max(0) |> min(mask(b))

  # a lane of `sb` bits widened to `b` bits
  defp ext(x, sb, :s, b), do: sx(x, sb) &&& mask(b)
  defp ext(x, _, :u, _), do: x

  # the low or high half of the lanes of the narrower type
  defp half_of(x, b, half) do
    l = lanes(x, div(b, 2))
    n = div(128, b)
    if half == :low, do: Enum.take(l, n), else: Enum.drop(l, n)
  end

  defp map(v, b, f), do: v |> lanes(b) |> Enum.map(f) |> pack(b)
  defp zip(x, y, b, f), do: Enum.zip_with(lanes(x, b), lanes(y, b), f) |> pack(b)

  # ── float lanes ────────────────────────────────────────────

  defp to_f(:f32x4), do: &Num.f32_from_bits/1
  defp to_f(:f64x2), do: &Num.f64_from_bits/1
  defp from_f(:f32x4), do: &Num.f32_to_bits/1
  defp from_f(:f64x2), do: &Num.f64_to_bits/1
  defp ty(:f32x4), do: :f32
  defp ty(:f64x2), do: :f64

  defp float(shape, :splat, [x], _) do
    b = bits(shape)
    pack(List.duplicate(from_f(shape).(x), div(128, b)), b)
  end

  defp float(shape, :extract_lane, [v], i), do: to_f(shape).(Enum.at(lanes(v, bits(shape)), i))

  defp float(shape, :replace_lane, [v, x], i),
    do: pack(List.replace_at(lanes(v, bits(shape)), i, from_f(shape).(x)), bits(shape))

  defp float(shape, op, [v], _) when op in [:abs, :neg, :sqrt, :ceil, :floor, :trunc, :nearest] do
    name = unop_name(ty(shape), op)
    map_f(shape, v, &Num.unop(name, &1))
  end

  defp float(shape, op, [x, y], _) when op in [:add, :sub, :mul, :div, :min, :max] do
    name = binop_name(ty(shape), op)
    zip_f(shape, x, y, &Num.binop(name, &1, &2))
  end

  defp float(shape, :pmin, [x, y], _),
    do:
      zip_f(shape, x, y, fn p, q ->
        if Num.binop(binop_name(ty(shape), :lt), q, p) == 1, do: q, else: p
      end)

  defp float(shape, :pmax, [x, y], _),
    do:
      zip_f(shape, x, y, fn p, q ->
        if Num.binop(binop_name(ty(shape), :lt), p, q) == 1, do: q, else: p
      end)

  defp float(shape, op, [x, y], _) when op in [:eq, :ne, :lt, :gt, :le, :ge] do
    name = binop_name(ty(shape), op)
    b = bits(shape)
    f = to_f(shape)

    Enum.zip_with(lanes(x, b), lanes(y, b), fn p, q ->
      if Num.binop(name, f.(p), f.(q)) == 1, do: mask(b), else: 0
    end)
    |> pack(b)
  end

  defp float(:f32x4, {:convert, sign}, [v], _) do
    op = if sign == :s, do: :f32_convert_i32_s, else: :f32_convert_i32_u
    lanes(v, 32) |> Enum.map(&Num.f32_to_bits(Num.unop(op, &1))) |> pack(32)
  end

  defp float(:f64x2, {:convert_low, sign}, [v], _) do
    op = if sign == :s, do: :f64_convert_i32_s, else: :f64_convert_i32_u

    lanes(v, 32) |> Enum.take(2) |> Enum.map(&Num.f64_to_bits(Num.unop(op, &1))) |> pack(64)
  end

  defp float(:f32x4, :demote_f64x2_zero, [v], _) do
    lanes(v, 64)
    |> Enum.map(&Num.f32_to_bits(Num.unop(:f32_demote_f64, Num.f64_from_bits(&1))))
    |> Kernel.++([0, 0])
    |> pack(32)
  end

  defp float(:f64x2, :promote_low_f32x4, [v], _) do
    lanes(v, 32)
    |> Enum.take(2)
    |> Enum.map(&Num.f64_to_bits(Num.unop(:f64_promote_f32, Num.f32_from_bits(&1))))
    |> pack(64)
  end

  defp map_f(shape, v, f) do
    b = bits(shape)
    to = to_f(shape)
    from = from_f(shape)
    lanes(v, b) |> Enum.map(&from.(f.(to.(&1)))) |> pack(b)
  end

  defp zip_f(shape, x, y, f) do
    b = bits(shape)
    to = to_f(shape)
    from = from_f(shape)
    Enum.zip_with(lanes(x, b), lanes(y, b), &from.(f.(to.(&1), to.(&2)))) |> pack(b)
  end

  for t <- [:f32, :f64], op <- [:abs, :neg, :sqrt, :ceil, :floor, :trunc, :nearest] do
    defp unop_name(unquote(t), unquote(op)), do: unquote(:"#{t}_#{op}")
  end

  for t <- [:f32, :f64],
      op <- [:add, :sub, :mul, :div, :min, :max, :eq, :ne, :lt, :gt, :le, :ge] do
    defp binop_name(unquote(t), unquote(op)), do: unquote(:"#{t}_#{op}")
  end

  # ── memory ─────────────────────────────────────────────────

  @doc """
  Runs a SIMD memory instruction on the stack (top first) and returns the new stack. `off` is
  the static offset.
  """
  def mem(:load, _, m, off, [base | st]), do: [read(m, base + off, 16) | st]
  def mem(:store, _, m, off, [v, base | st]), do: write(m, base + off, v, 16, st)

  def mem({:load_ext, sb, sign}, _, m, off, [base | st]) do
    <<bin::binary-8>> = Memory.read(m, base + off, 8)
    b = 2 * sb

    v =
      for(<<x::little-size(^sb) <- bin>>, do: ext(x, sb, sign, b))
      |> pack(b)

    [v | st]
  end

  def mem({:load_splat, b}, _, m, off, [base | st]) do
    <<x::little-size(^b)>> = Memory.read(m, base + off, div(b, 8))
    [pack(List.duplicate(x, div(128, b)), b) | st]
  end

  def mem({:load_zero, b}, _, m, off, [base | st]) do
    <<x::little-size(^b)>> = Memory.read(m, base + off, div(b, 8))
    [x | st]
  end

  def mem({:load_lane, b}, lane, m, off, [v, base | st]) do
    <<x::little-size(^b)>> = Memory.read(m, base + off, div(b, 8))
    [pack(List.replace_at(lanes(v, b), lane, x), b) | st]
  end

  def mem({:store_lane, b}, lane, m, off, [v, base | st]) do
    x = Enum.at(lanes(v, b), lane)
    write(m, base + off, x, div(b, 8), st)
  end

  defp read(m, addr, n) do
    bits = n * 8
    <<v::little-size(^bits)>> = Memory.read(m, addr, n)
    v
  end

  defp write(m, addr, v, n, st) do
    Memory.write(m, addr, <<v::little-size(n * 8)>>)
    st
  end
end
