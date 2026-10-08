defmodule Browser.Wasm.Ops do
  @moduledoc """
  The table of the numeric and memory instructions: opcode, name and type signature.
  The decoder and the validator both read it.
  """

  @i_cmp ~w(eq ne lt_s lt_u gt_s gt_u le_s le_u ge_s ge_u)a
  @f_cmp ~w(eq ne lt gt le ge)a
  @i_un ~w(clz ctz popcnt)a
  @i_bin ~w(add sub mul div_s div_u rem_s rem_u and or xor shl shr_s shr_u rotl rotr)a
  @f_un ~w(abs neg ceil floor trunc nearest sqrt)a
  @f_bin ~w(add sub mul div min max copysign)a

  # {opcode, name, params, result}
  @numeric [
             [{0x45, :i32_eqz, [:i32], :i32}, {0x50, :i64_eqz, [:i64], :i32}],
             for(
               {op, i} <- Enum.with_index(@i_cmp),
               do: {0x46 + i, :"i32_#{op}", [:i32, :i32], :i32}
             ),
             for(
               {op, i} <- Enum.with_index(@i_cmp),
               do: {0x51 + i, :"i64_#{op}", [:i64, :i64], :i32}
             ),
             for(
               {op, i} <- Enum.with_index(@f_cmp),
               do: {0x5B + i, :"f32_#{op}", [:f32, :f32], :i32}
             ),
             for(
               {op, i} <- Enum.with_index(@f_cmp),
               do: {0x61 + i, :"f64_#{op}", [:f64, :f64], :i32}
             ),
             for({op, i} <- Enum.with_index(@i_un), do: {0x67 + i, :"i32_#{op}", [:i32], :i32}),
             for(
               {op, i} <- Enum.with_index(@i_bin),
               do: {0x6A + i, :"i32_#{op}", [:i32, :i32], :i32}
             ),
             for({op, i} <- Enum.with_index(@i_un), do: {0x79 + i, :"i64_#{op}", [:i64], :i64}),
             for(
               {op, i} <- Enum.with_index(@i_bin),
               do: {0x7C + i, :"i64_#{op}", [:i64, :i64], :i64}
             ),
             for({op, i} <- Enum.with_index(@f_un), do: {0x8B + i, :"f32_#{op}", [:f32], :f32}),
             for(
               {op, i} <- Enum.with_index(@f_bin),
               do: {0x92 + i, :"f32_#{op}", [:f32, :f32], :f32}
             ),
             for({op, i} <- Enum.with_index(@f_un), do: {0x99 + i, :"f64_#{op}", [:f64], :f64}),
             for(
               {op, i} <- Enum.with_index(@f_bin),
               do: {0xA0 + i, :"f64_#{op}", [:f64, :f64], :f64}
             ),
             [
               {0xA7, :i32_wrap_i64, [:i64], :i32},
               {0xA8, :i32_trunc_f32_s, [:f32], :i32},
               {0xA9, :i32_trunc_f32_u, [:f32], :i32},
               {0xAA, :i32_trunc_f64_s, [:f64], :i32},
               {0xAB, :i32_trunc_f64_u, [:f64], :i32},
               {0xAC, :i64_extend_i32_s, [:i32], :i64},
               {0xAD, :i64_extend_i32_u, [:i32], :i64},
               {0xAE, :i64_trunc_f32_s, [:f32], :i64},
               {0xAF, :i64_trunc_f32_u, [:f32], :i64},
               {0xB0, :i64_trunc_f64_s, [:f64], :i64},
               {0xB1, :i64_trunc_f64_u, [:f64], :i64},
               {0xB2, :f32_convert_i32_s, [:i32], :f32},
               {0xB3, :f32_convert_i32_u, [:i32], :f32},
               {0xB4, :f32_convert_i64_s, [:i64], :f32},
               {0xB5, :f32_convert_i64_u, [:i64], :f32},
               {0xB6, :f32_demote_f64, [:f64], :f32},
               {0xB7, :f64_convert_i32_s, [:i32], :f64},
               {0xB8, :f64_convert_i32_u, [:i32], :f64},
               {0xB9, :f64_convert_i64_s, [:i64], :f64},
               {0xBA, :f64_convert_i64_u, [:i64], :f64},
               {0xBB, :f64_promote_f32, [:f32], :f64},
               {0xBC, :i32_reinterpret_f32, [:f32], :i32},
               {0xBD, :i64_reinterpret_f64, [:f64], :i64},
               {0xBE, :f32_reinterpret_i32, [:i32], :f32},
               {0xBF, :f64_reinterpret_i64, [:i64], :f64},
               {0xC0, :i32_extend8_s, [:i32], :i32},
               {0xC1, :i32_extend16_s, [:i32], :i32},
               {0xC2, :i64_extend8_s, [:i64], :i64},
               {0xC3, :i64_extend16_s, [:i64], :i64},
               {0xC4, :i64_extend32_s, [:i64], :i64}
             ]
           ]
           |> List.flatten()

  # the 0xFC 0..7 saturating truncations
  @sat [
    {0, :i32_trunc_sat_f32_s, [:f32], :i32},
    {1, :i32_trunc_sat_f32_u, [:f32], :i32},
    {2, :i32_trunc_sat_f64_s, [:f64], :i32},
    {3, :i32_trunc_sat_f64_u, [:f64], :i32},
    {4, :i64_trunc_sat_f32_s, [:f32], :i64},
    {5, :i64_trunc_sat_f32_u, [:f32], :i64},
    {6, :i64_trunc_sat_f64_s, [:f64], :i64},
    {7, :i64_trunc_sat_f64_u, [:f64], :i64}
  ]

  # {opcode, kind, value type, natural alignment (log2 of bytes)}
  @loads [
    {0x28, :i32, :i32, 2},
    {0x29, :i64, :i64, 3},
    {0x2A, :f32, :f32, 2},
    {0x2B, :f64, :f64, 3},
    {0x2C, :i32_8s, :i32, 0},
    {0x2D, :i32_8u, :i32, 0},
    {0x2E, :i32_16s, :i32, 1},
    {0x2F, :i32_16u, :i32, 1},
    {0x30, :i64_8s, :i64, 0},
    {0x31, :i64_8u, :i64, 0},
    {0x32, :i64_16s, :i64, 1},
    {0x33, :i64_16u, :i64, 1},
    {0x34, :i64_32s, :i64, 2},
    {0x35, :i64_32u, :i64, 2}
  ]
  @stores [
    {0x36, :i32, :i32, 2},
    {0x37, :i64, :i64, 3},
    {0x38, :f32, :f32, 2},
    {0x39, :f64, :f64, 3},
    {0x3A, :i32_8, :i32, 0},
    {0x3B, :i32_16, :i32, 1},
    {0x3C, :i64_8, :i64, 0},
    {0x3D, :i64_16, :i64, 1},
    {0x3E, :i64_32, :i64, 2}
  ]

  def numeric, do: @numeric
  def sat, do: @sat
  def loads, do: @loads
  def stores, do: @stores

  @doc "`name => {params, result}` for every numeric and saturating instruction."
  def signatures,
    do:
      Map.new(@numeric ++ for({_, nm, p, r} <- @sat, do: {0, nm, p, r}), fn {_, nm, p, r} ->
        {nm, {p, r}}
      end)
end
