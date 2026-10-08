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

  # ── SIMD (0xFD prefix) ─────────────────────────────────────

  @simd_ty %{i8x16: :i32, i16x8: :i32, i32x4: :i32, i64x2: :i64, f32x4: :f32, f64x2: :f64}
  @simd_lanes %{i8x16: 16, i16x8: 8, i32x4: 4, i64x2: 2, f32x4: 4, f64x2: 2}
  @log2_bytes %{8 => 0, 16 => 1, 32 => 2, 64 => 3}
  @cmp_64 ~w(eq ne lt_s gt_s le_s ge_s)a

  @i8x16 [
    {0x60, :abs},
    {0x61, :neg},
    {0x62, :popcnt},
    {0x63, :all_true},
    {0x64, :bitmask},
    {0x65, {:narrow, :s}},
    {0x66, {:narrow, :u}},
    {0x6B, :shl},
    {0x6C, :shr_s},
    {0x6D, :shr_u},
    {0x6E, :add},
    {0x6F, :add_sat_s},
    {0x70, :add_sat_u},
    {0x71, :sub},
    {0x72, :sub_sat_s},
    {0x73, :sub_sat_u},
    {0x76, :min_s},
    {0x77, :min_u},
    {0x78, :max_s},
    {0x79, :max_u},
    {0x7B, :avgr_u}
  ]
  @i16x8 [
    {0x7C, {:extadd_pairwise, :s}},
    {0x7D, {:extadd_pairwise, :u}},
    {0x80, :abs},
    {0x81, :neg},
    {0x82, :q15mulr_sat_s},
    {0x83, :all_true},
    {0x84, :bitmask},
    {0x85, {:narrow, :s}},
    {0x86, {:narrow, :u}},
    {0x8B, :shl},
    {0x8C, :shr_s},
    {0x8D, :shr_u},
    {0x8E, :add},
    {0x8F, :add_sat_s},
    {0x90, :add_sat_u},
    {0x91, :sub},
    {0x92, :sub_sat_s},
    {0x93, :sub_sat_u},
    {0x95, :mul},
    {0x96, :min_s},
    {0x97, :min_u},
    {0x98, :max_s},
    {0x99, :max_u},
    {0x9B, :avgr_u}
  ]
  @i32x4 [
    {0x7E, {:extadd_pairwise, :s}},
    {0x7F, {:extadd_pairwise, :u}},
    {0xA0, :abs},
    {0xA1, :neg},
    {0xA3, :all_true},
    {0xA4, :bitmask},
    {0xAB, :shl},
    {0xAC, :shr_s},
    {0xAD, :shr_u},
    {0xAE, :add},
    {0xB1, :sub},
    {0xB5, :mul},
    {0xB6, :min_s},
    {0xB7, :min_u},
    {0xB8, :max_s},
    {0xB9, :max_u},
    {0xBA, :dot_i16x8_s},
    {0xF8, {:trunc_sat, :s}},
    {0xF9, {:trunc_sat, :u}},
    {0xFC, {:trunc_sat_zero, :s}},
    {0xFD, {:trunc_sat_zero, :u}}
  ]
  @i64x2 [
    {0xC0, :abs},
    {0xC1, :neg},
    {0xC3, :all_true},
    {0xC4, :bitmask},
    {0xCB, :shl},
    {0xCC, :shr_s},
    {0xCD, :shr_u},
    {0xCE, :add},
    {0xD1, :sub},
    {0xD5, :mul}
  ]
  @f32x4 [
    {0x67, :ceil},
    {0x68, :floor},
    {0x69, :trunc},
    {0x6A, :nearest},
    {0xE0, :abs},
    {0xE1, :neg},
    {0xE3, :sqrt},
    {0xE4, :add},
    {0xE5, :sub},
    {0xE6, :mul},
    {0xE7, :div},
    {0xE8, :min},
    {0xE9, :max},
    {0xEA, :pmin},
    {0xEB, :pmax},
    {0xFA, {:convert, :s}},
    {0xFB, {:convert, :u}}
  ]
  @f64x2 [
    {0x74, :ceil},
    {0x75, :floor},
    {0x7A, :trunc},
    {0x94, :nearest},
    {0xEC, :abs},
    {0xED, :neg},
    {0xEF, :sqrt},
    {0xF0, :add},
    {0xF1, :sub},
    {0xF2, :mul},
    {0xF3, :div},
    {0xF4, :min},
    {0xF5, :max},
    {0xF6, :pmin},
    {0xF7, :pmax},
    {0xFE, {:convert_low, :s}},
    {0xFF, {:convert_low, :u}}
  ]
  @v128 [
    {0x4D, :not},
    {0x4E, :and},
    {0x4F, :andnot},
    {0x50, :or},
    {0x51, :xor},
    {0x52, :bitselect},
    {0x53, :any_true}
  ]
  @lane_ops [
    {0x15, :i8x16, :extract_lane_s},
    {0x16, :i8x16, :extract_lane_u},
    {0x17, :i8x16, :replace_lane},
    {0x18, :i16x8, :extract_lane_s},
    {0x19, :i16x8, :extract_lane_u},
    {0x1A, :i16x8, :replace_lane},
    {0x1B, :i32x4, :extract_lane},
    {0x1C, :i32x4, :replace_lane},
    {0x1D, :i64x2, :extract_lane},
    {0x1E, :i64x2, :replace_lane},
    {0x1F, :f32x4, :extract_lane},
    {0x20, :f32x4, :replace_lane},
    {0x21, :f64x2, :extract_lane},
    {0x22, :f64x2, :replace_lane}
  ]

  @doc """
  The SIMD instructions: `{sub opcode, shape, op, params, result, immediate}`. The shape of
  a plain instruction is its lane type (`:i8x16` ... `:f64x2`) or `:v128`. A `nil` result is
  no result. The immediate is `nil`, `{:lane, count}`, `:shuffle`, `:const`, `{:mem, align}` or
  `{:mem_lane, align, count}`.
  """
  def simd do
    ext =
      for {sub, bits, sign} <- [
            {1, 8, :s},
            {2, 8, :u},
            {3, 16, :s},
            {4, 16, :u},
            {5, 32, :s},
            {6, 32, :u}
          ] do
        {sub, :v128, {:load_ext, bits, sign}, [:i32], :v128, {:mem, 3}}
      end

    splat_load =
      for {sub, bits} <- [{7, 8}, {8, 16}, {9, 32}, {0xA, 64}] do
        {sub, :v128, {:load_splat, bits}, [:i32], :v128, {:mem, @log2_bytes[bits]}}
      end

    zero_load =
      for {sub, bits} <- [{0x5C, 32}, {0x5D, 64}] do
        {sub, :v128, {:load_zero, bits}, [:i32], :v128, {:mem, @log2_bytes[bits]}}
      end

    lane_load =
      for {sub, bits} <- [{0x54, 8}, {0x55, 16}, {0x56, 32}, {0x57, 64}] do
        imm = {:mem_lane, @log2_bytes[bits], div(128, bits)}
        {sub, :v128, {:load_lane, bits}, [:i32, :v128], :v128, imm}
      end

    lane_store =
      for {sub, bits} <- [{0x58, 8}, {0x59, 16}, {0x5A, 32}, {0x5B, 64}] do
        imm = {:mem_lane, @log2_bytes[bits], div(128, bits)}
        {sub, :v128, {:store_lane, bits}, [:i32, :v128], nil, imm}
      end

    special = [
      {0x00, :v128, :load, [:i32], :v128, {:mem, 4}},
      {0x0B, :v128, :store, [:i32, :v128], nil, {:mem, 4}},
      {0x0C, :v128, :const, [], :v128, :const},
      {0x0D, :i8x16, :shuffle, [:v128, :v128], :v128, :shuffle}
    ]

    splats =
      for {sub, shape} <- [
            {0x0F, :i8x16},
            {0x10, :i16x8},
            {0x11, :i32x4},
            {0x12, :i64x2},
            {0x13, :f32x4},
            {0x14, :f64x2}
          ] do
        {sub, shape, :splat, [@simd_ty[shape]], :v128, nil}
      end

    lane_ops =
      for {sub, shape, op} <- @lane_ops do
        ty = @simd_ty[shape]
        {params, result} = if op == :replace_lane, do: {[:v128, ty], :v128}, else: {[:v128], ty}
        {sub, shape, op, params, result, {:lane, @simd_lanes[shape]}}
      end

    ext_ops = fn lo ->
      for {off, half, sign} <- [{0, :low, :s}, {1, :high, :s}, {2, :low, :u}, {3, :high, :u}] do
        {lo + off, {:extend, half, sign}}
      end
    end

    extmul = fn lo ->
      for {off, half, sign} <- [{0, :low, :s}, {1, :high, :s}, {2, :low, :u}, {3, :high, :u}] do
        {lo + off, {:extmul, half, sign}}
      end
    end

    cmps =
      for(
        {shape, base} <- [i8x16: 0x23, i16x8: 0x2D, i32x4: 0x37],
        {op, i} <- Enum.with_index(@i_cmp),
        do: {base + i, shape, op}
      ) ++
        for(
          {shape, base} <- [f32x4: 0x41, f64x2: 0x47],
          {op, i} <- Enum.with_index(@f_cmp),
          do: {base + i, shape, op}
        ) ++
        for {op, i} <- Enum.with_index(@cmp_64), do: {0xD6 + i, :i64x2, op}

    groups = [
      {:v128, @v128},
      {:i8x16, [{0x0E, :swizzle}] ++ @i8x16},
      {:i16x8, @i16x8 ++ ext_ops.(0x87) ++ extmul.(0x9C)},
      {:i32x4, @i32x4 ++ ext_ops.(0xA7) ++ extmul.(0xBC)},
      {:i64x2, @i64x2 ++ ext_ops.(0xC7) ++ extmul.(0xDC)},
      {:f32x4, [{0x5E, :demote_f64x2_zero}] ++ @f32x4},
      {:f64x2, [{0x5F, :promote_low_f32x4}] ++ @f64x2}
    ]

    plain =
      cmps ++ for({shape, rows} <- groups, {sub, op} <- rows, do: {sub, shape, op})

    plain =
      for {sub, shape, op} <- plain do
        {params, result} = simd_sig(op)
        {sub, shape, op, params, result, nil}
      end

    ext ++
      splat_load ++ zero_load ++ lane_load ++ lane_store ++ special ++ splats ++ lane_ops ++ plain
  end

  defp simd_sig(op) when op in [:all_true, :bitmask, :any_true], do: {[:v128], :i32}
  defp simd_sig(op) when op in [:shl, :shr_s, :shr_u], do: {[:v128, :i32], :v128}
  defp simd_sig(:bitselect), do: {[:v128, :v128, :v128], :v128}

  defp simd_sig(op) do
    head = if is_tuple(op), do: elem(op, 0), else: op

    unary =
      head in [
        :not,
        :abs,
        :neg,
        :popcnt,
        :sqrt,
        :ceil,
        :floor,
        :trunc,
        :nearest,
        :extend,
        :extadd_pairwise,
        :convert,
        :convert_low,
        :trunc_sat,
        :trunc_sat_zero,
        :demote_f64x2_zero,
        :promote_low_f32x4
      ]

    if unary, do: {[:v128], :v128}, else: {[:v128, :v128], :v128}
  end

  @doc "`{shape, op} => {params, result, immediate}` for every SIMD instruction."
  def simd_signatures,
    do: Map.new(simd(), fn {_, shape, op, p, r, imm} -> {{shape, op}, {p, r, imm}} end)

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
