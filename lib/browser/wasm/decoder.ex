defmodule Browser.Wasm.Decoder do
  @moduledoc """
  Reads a WebAssembly binary into a module map. Function bodies come out as nested instruction
  lists (`{:block, blocktype, body}`, `{:loop, ...}`, `{:if, blocktype, then, else}`); the
  validator turns them into flat code.
  """

  import Bitwise
  alias Browser.Wasm.{Error, Num, Ops}

  @numeric Map.new(Ops.numeric(), fn {op, name, _, _} -> {op, name} end)
  @sat Map.new(Ops.sat(), fn {op, name, _, _} -> {op, name} end)
  @loads Map.new(Ops.loads(), fn {op, kind, _, _} -> {op, kind} end)
  @stores Map.new(Ops.stores(), fn {op, kind, _, _} -> {op, kind} end)

  defp fail(msg), do: Error.fail(:compile, msg)

  @doc "Decodes `bin`. Raises `Browser.Wasm.Error` (kind `:compile`) when it is malformed."
  def decode(bin) when is_binary(bin) do
    case bin do
      <<0, "asm", 1, 0, 0, 0, rest::binary>> ->
        mod = %{
          types: [],
          imports: [],
          funcs: [],
          tables: [],
          mems: [],
          globals: [],
          tags: [],
          exports: [],
          start: nil,
          elems: [],
          datas: [],
          data_count: nil,
          codes: [],
          customs: []
        }

        mod = sections(rest, mod, 0)

        if length(mod.funcs) != length(mod.codes),
          do: fail("function and code section have inconsistent lengths")

        if mod.data_count && mod.data_count != length(mod.datas),
          do: fail("data count and data section have inconsistent lengths")

        mod

      <<0, "asm", _::binary-size(4), _::binary>> ->
        fail("unknown binary version")

      _ ->
        if byte_size(bin) >= 4 and binary_part(bin, 0, 4) == <<0, "asm">>,
          do: fail("unexpected end"),
          else: fail("magic header not detected")
    end
  end

  # ── sections ───────────────────────────────────────────────

  defp rank(1), do: 1
  defp rank(2), do: 2
  defp rank(3), do: 3
  defp rank(4), do: 4
  defp rank(5), do: 5
  defp rank(13), do: 5.5
  defp rank(6), do: 6
  defp rank(7), do: 7
  defp rank(8), do: 8
  defp rank(9), do: 9
  defp rank(12), do: 10
  defp rank(10), do: 11
  defp rank(11), do: 12
  defp rank(_), do: fail("malformed section id")

  defp sections(<<>>, mod, _), do: finish(mod)

  defp sections(<<id, rest::binary>>, mod, last) do
    {size, rest} = u32(rest)
    if size > byte_size(rest), do: fail("unexpected end of section or function")
    <<payload::binary-size(^size), rest::binary>> = rest

    if id == 0 do
      sections(rest, custom(payload, mod), last)
    else
      r = rank(id)
      if r <= last, do: fail("junk after last section")
      sections(rest, section(id, payload, mod), r)
    end
  end

  defp finish(mod) do
    %{mod | customs: Enum.reverse(mod.customs)}
  end

  defp custom(payload, mod) do
    {name, data} = name(payload)
    %{mod | customs: [{name, data} | mod.customs]}
  end

  defp whole({v, <<>>}), do: v
  defp whole({_, _}), do: fail("section size mismatch")

  defp section(1, p, mod), do: %{mod | types: whole(vec(p, &functype/1))}
  defp section(2, p, mod), do: %{mod | imports: whole(vec(p, &import_entry/1))}
  defp section(3, p, mod), do: %{mod | funcs: whole(vec(p, &u32/1))}
  defp section(4, p, mod), do: %{mod | tables: whole(vec(p, &table_type/1))}
  defp section(5, p, mod), do: %{mod | mems: whole(vec(p, &mem_type/1))}
  defp section(13, p, mod), do: %{mod | tags: whole(vec(p, &tag/1))}
  defp section(6, p, mod), do: %{mod | globals: whole(vec(p, &global/1))}
  defp section(7, p, mod), do: %{mod | exports: whole(vec(p, &export/1))}
  defp section(8, p, mod), do: %{mod | start: whole(u32(p))}
  defp section(9, p, mod), do: %{mod | elems: whole(vec(p, &elem/1))}
  defp section(12, p, mod), do: %{mod | data_count: whole(u32(p))}
  defp section(10, p, mod), do: %{mod | codes: whole(vec(p, &code/1))}
  defp section(11, p, mod), do: %{mod | datas: whole(vec(p, &data/1))}

  defp vec(bin, fun) do
    {n, rest} = u32(bin)
    if n > byte_size(rest), do: fail("unexpected end")
    vec_items(rest, n, fun, [])
  end

  defp vec_items(rest, 0, _, acc), do: {Enum.reverse(acc), rest}

  defp vec_items(rest, n, fun, acc) do
    {v, rest} = fun.(rest)
    vec_items(rest, n - 1, fun, [v | acc])
  end

  # ── leb128 ─────────────────────────────────────────────────

  def u32(bin), do: uleb(bin, 32)
  def u64(bin), do: uleb(bin, 64)
  def s32(bin), do: sleb(bin, 32)
  def s33(bin), do: sleb(bin, 33)
  def s64(bin), do: sleb(bin, 64)

  defp uleb(bin, bits), do: uleb(bin, bits, 0, 0, div(bits + 6, 7))

  defp uleb(<<>>, _, _, _, _), do: fail("unexpected end")

  defp uleb(<<b, rest::binary>>, bits, acc, i, max) do
    acc = acc ||| (b &&& 0x7F) <<< (7 * i)

    cond do
      b < 0x80 and i == max - 1 and b >>> (bits - 7 * i) != 0 -> fail("integer too large")
      b < 0x80 -> {acc, rest}
      i == max - 1 -> fail("integer representation too long")
      true -> uleb(rest, bits, acc, i + 1, max)
    end
  end

  defp sleb(bin, bits), do: sleb(bin, bits, 0, 0, div(bits + 6, 7))

  defp sleb(<<>>, _, _, _, _), do: fail("unexpected end")

  defp sleb(<<b, rest::binary>>, bits, acc, i, max) do
    acc = acc ||| (b &&& 0x7F) <<< (7 * i)

    cond do
      b >= 0x80 and i == max - 1 ->
        fail("integer representation too long")

      b >= 0x80 ->
        sleb(rest, bits, acc, i + 1, max)

      true ->
        if i == max - 1 do
          used = bits - 7 * i
          spare = (b &&& 0x7F) >>> (used - 1)
          top = (1 <<< (8 - used)) - 1
          if spare != 0 and spare != top, do: fail("integer too large")
        end

        acc = if (b &&& 0x40) != 0, do: acc - (1 <<< (7 * (i + 1))), else: acc
        {acc, rest}
    end
  end

  # ── types ──────────────────────────────────────────────────

  defp valtype(<<0x7F, r::binary>>), do: {:i32, r}
  defp valtype(<<0x7E, r::binary>>), do: {:i64, r}
  defp valtype(<<0x7D, r::binary>>), do: {:f32, r}
  defp valtype(<<0x7C, r::binary>>), do: {:f64, r}
  defp valtype(<<0x7B, _::binary>>), do: fail("v128 is not supported")
  defp valtype(<<0x70, r::binary>>), do: {:funcref, r}
  defp valtype(<<0x6F, r::binary>>), do: {:externref, r}
  defp valtype(<<0x69, r::binary>>), do: {:exnref, r}
  defp valtype(<<>>), do: fail("unexpected end")
  defp valtype(_), do: fail("malformed value type")

  defp reftype(<<0x70, r::binary>>), do: {:funcref, r}
  defp reftype(<<0x6F, r::binary>>), do: {:externref, r}
  defp reftype(<<0x69, r::binary>>), do: {:exnref, r}
  defp reftype(<<>>), do: fail("unexpected end")
  defp reftype(_), do: fail("malformed reference type")

  defp functype(<<0x60, r::binary>>) do
    {params, r} = vec(r, &valtype/1)
    {results, r} = vec(r, &valtype/1)
    {{params, results}, r}
  end

  defp functype(<<>>), do: fail("unexpected end")
  defp functype(_), do: fail("integer representation too long")

  defp limits(<<0, r::binary>>) do
    {min, r} = u32(r)
    {{min, nil}, r}
  end

  defp limits(<<1, r::binary>>) do
    {min, r} = u32(r)
    {max, r} = u32(r)
    {{min, max}, r}
  end

  defp limits(<<>>), do: fail("unexpected end")
  defp limits(_), do: fail("integer too large")

  defp table_type(bin) do
    {t, r} = reftype(bin)
    {lim, r} = limits(r)
    {{lim, t}, r}
  end

  defp mem_type(bin), do: limits(bin)

  defp tag(<<0, r::binary>>), do: u32(r)
  defp tag(<<>>), do: fail("unexpected end")
  defp tag(_), do: fail("malformed tag attribute")

  defp global_type(bin) do
    {t, r} = valtype(bin)

    case r do
      <<0, r::binary>> -> {{t, :const}, r}
      <<1, r::binary>> -> {{t, :var}, r}
      <<>> -> fail("unexpected end")
      _ -> fail("malformed mutability")
    end
  end

  defp name(bin) do
    {n, r} = u32(bin)
    if n > byte_size(r), do: fail("unexpected end")
    <<s::binary-size(^n), r::binary>> = r
    unless String.valid?(s), do: fail("malformed UTF-8 encoding")
    {s, r}
  end

  defp import_entry(bin) do
    {m, r} = name(bin)
    {n, r} = name(r)

    {desc, r} =
      case r do
        <<0, r::binary>> ->
          {t, r} = u32(r)
          {{:func, t}, r}

        <<1, r::binary>> ->
          {t, r} = table_type(r)
          {{:table, t}, r}

        <<2, r::binary>> ->
          {t, r} = mem_type(r)
          {{:mem, t}, r}

        <<3, r::binary>> ->
          {t, r} = global_type(r)
          {{:global, t}, r}

        <<4, r::binary>> ->
          {t, r} = tag(r)
          {{:tag, t}, r}

        <<>> ->
          fail("unexpected end")

        _ ->
          fail("malformed import kind")
      end

    {%{module: m, name: n, desc: desc}, r}
  end

  defp export(bin) do
    {n, r} = name(bin)

    case r do
      <<k, r::binary>> when k in 0..4 ->
        {i, r} = u32(r)
        {%{name: n, kind: Enum.at([:func, :table, :mem, :global, :tag], k), index: i}, r}

      <<>> ->
        fail("unexpected end")

      _ ->
        fail("malformed export kind")
    end
  end

  defp global(bin) do
    {type, r} = global_type(bin)
    {init, r} = const_expr(r)
    {%{type: type, init: init}, r}
  end

  defp const_expr(bin) do
    {ins, term, r} = seq(bin, [])
    if term != :end, do: fail("END opcode expected")
    {ins, r}
  end

  defp elem(bin) do
    {flag, r} = u32(bin)
    if flag > 7, do: fail("malformed elements segment kind")
    passive_or_decl = (flag &&& 3) != 0
    explicit_table = (flag &&& 3) == 2
    exprs = (flag &&& 4) != 0

    {table, r} = if explicit_table, do: u32(r), else: {0, r}

    {offset, r} =
      if passive_or_decl and not explicit_table, do: {nil, r}, else: const_expr(r)

    {type, r} =
      cond do
        flag in [0, 4] ->
          {:funcref, r}

        exprs ->
          reftype(r)

        true ->
          case r do
            <<0, r::binary>> -> {:funcref, r}
            <<>> -> fail("unexpected end")
            _ -> fail("malformed element kind")
          end
      end

    {inits, r} =
      if exprs do
        vec(r, fn b -> const_expr(b) end)
      else
        {idx, r} = vec(r, &u32/1)
        {Enum.map(idx, &[{:ref_func, &1}]), r}
      end

    mode =
      cond do
        flag in [1, 5] -> :passive
        flag in [3, 7] -> :declarative
        true -> {:active, table, offset}
      end

    {%{mode: mode, type: type, inits: inits}, r}
  end

  defp data(bin) do
    {flag, r} = u32(bin)

    {mode, r} =
      case flag do
        0 ->
          {off, r} = const_expr(r)
          {{:active, 0, off}, r}

        1 ->
          {:passive, r}

        2 ->
          {mi, r} = u32(r)
          {off, r} = const_expr(r)
          {{:active, mi, off}, r}

        _ ->
          fail("integer representation too long")
      end

    {n, r} = u32(r)
    if n > byte_size(r), do: fail("unexpected end")
    <<bytes::binary-size(^n), r::binary>> = r
    {%{mode: mode, bytes: bytes}, r}
  end

  defp code(bin) do
    {size, r} = u32(bin)
    if size > byte_size(r), do: fail("unexpected end")
    <<body::binary-size(^size), r::binary>> = r
    {groups, rest} = vec(body, &local_group/1)
    total = Enum.reduce(groups, 0, fn {n, _}, a -> a + n end)
    if total > 50_000, do: fail("too many locals")
    locals = Enum.flat_map(groups, fn {n, t} -> List.duplicate(t, n) end)
    {ins, term, rest} = seq(rest, [])
    if term != :end, do: fail("END opcode expected")
    if rest != <<>>, do: fail("section size mismatch")
    {%{locals: locals, body: ins}, r}
  end

  defp local_group(bin) do
    {n, r} = u32(bin)
    {t, r} = valtype(r)
    {{n, t}, r}
  end

  # ── instructions ───────────────────────────────────────────

  defp seq(<<>>, _), do: fail("unexpected end")
  defp seq(<<0x0B, r::binary>>, acc), do: {Enum.reverse(acc), :end, r}
  defp seq(<<0x05, r::binary>>, acc), do: {Enum.reverse(acc), :else, r}

  defp seq(bin, acc) do
    {ins, r} = instr(bin)
    seq(r, [ins | acc])
  end

  defp blocktype(<<0x40, r::binary>>), do: {:empty, r}

  defp blocktype(<<b, _::binary>> = bin) when b in [0x7F, 0x7E, 0x7D, 0x7C, 0x70, 0x6F, 0x69] do
    {t, r} = valtype(bin)
    {{:val, t}, r}
  end

  defp blocktype(bin) do
    {i, r} = s33(bin)
    if i < 0, do: fail("malformed block type")
    {{:type, i}, r}
  end

  defp instr(<<0x00, r::binary>>), do: {:unreachable, r}
  defp instr(<<0x01, r::binary>>), do: {:nop, r}

  defp instr(<<op, r::binary>>) when op in [0x02, 0x03] do
    {bt, r} = blocktype(r)
    {body, term, r} = seq(r, [])
    if term != :end, do: fail("END opcode expected")
    {{if(op == 2, do: :block, else: :loop), bt, body}, r}
  end

  defp instr(<<0x04, r::binary>>) do
    {bt, r} = blocktype(r)
    {then, term, r} = seq(r, [])

    case term do
      :end ->
        {{:if, bt, then, nil}, r}

      :else ->
        {els, term, r} = seq(r, [])
        if term != :end, do: fail("END opcode expected")
        {{:if, bt, then, els}, r}
    end
  end

  defp instr(<<0x08, r::binary>>), do: idx(:throw, r)
  defp instr(<<0x0A, r::binary>>), do: {:throw_ref, r}

  defp instr(<<0x1F, r::binary>>) do
    {bt, r} = blocktype(r)
    {catches, r} = vec(r, &catch_clause/1)
    {body, term, r} = seq(r, [])
    if term != :end, do: fail("END opcode expected")
    {{:try_table, bt, catches, body}, r}
  end

  defp instr(<<0x0C, r::binary>>), do: idx(:br, r)
  defp instr(<<0x0D, r::binary>>), do: idx(:br_if, r)

  defp instr(<<0x0E, r::binary>>) do
    {labels, r} = vec(r, &u32/1)
    {default, r} = u32(r)
    {{:br_table, labels, default}, r}
  end

  defp instr(<<0x0F, r::binary>>), do: {:return, r}
  defp instr(<<0x10, r::binary>>), do: idx(:call, r)
  defp instr(<<0x12, r::binary>>), do: idx(:return_call, r)

  defp instr(<<0x13, r::binary>>) do
    {t, r} = u32(r)
    {tbl, r} = u32(r)
    {{:return_call_indirect, t, tbl}, r}
  end

  defp instr(<<0x11, r::binary>>) do
    {t, r} = u32(r)
    {tbl, r} = u32(r)
    {{:call_indirect, t, tbl}, r}
  end

  defp instr(<<0x1A, r::binary>>), do: {:drop, r}
  defp instr(<<0x1B, r::binary>>), do: {:select, r}

  defp instr(<<0x1C, r::binary>>) do
    {ts, r} = vec(r, &valtype/1)
    if length(ts) != 1, do: fail("invalid result arity")
    {{:select_t, hd(ts)}, r}
  end

  defp instr(<<0x20, r::binary>>), do: idx(:local_get, r)
  defp instr(<<0x21, r::binary>>), do: idx(:local_set, r)
  defp instr(<<0x22, r::binary>>), do: idx(:local_tee, r)
  defp instr(<<0x23, r::binary>>), do: idx(:global_get, r)
  defp instr(<<0x24, r::binary>>), do: idx(:global_set, r)
  defp instr(<<0x25, r::binary>>), do: idx(:table_get, r)
  defp instr(<<0x26, r::binary>>), do: idx(:table_set, r)

  defp instr(<<op, r::binary>>) when is_map_key(@loads, op) do
    {a, o, m, r} = memarg(r)
    {{:load, Map.fetch!(@loads, op), a, o, m}, r}
  end

  defp instr(<<op, r::binary>>) when is_map_key(@stores, op) do
    {a, o, m, r} = memarg(r)
    {{:store, Map.fetch!(@stores, op), a, o, m}, r}
  end

  defp instr(<<0x3F, r::binary>>), do: idx(:memory_size, r)
  defp instr(<<0x40, r::binary>>), do: idx(:memory_grow, r)

  defp instr(<<0x41, r::binary>>) do
    {v, r} = s32(r)
    {{:i32_const, v &&& 0xFFFFFFFF}, r}
  end

  defp instr(<<0x42, r::binary>>) do
    {v, r} = s64(r)
    {{:i64_const, v &&& 0xFFFFFFFFFFFFFFFF}, r}
  end

  defp instr(<<0x43, bits::little-32, r::binary>>), do: {{:f32_const, Num.f32_from_bits(bits)}, r}
  defp instr(<<0x44, bits::little-64, r::binary>>), do: {{:f64_const, Num.f64_from_bits(bits)}, r}
  defp instr(<<op, _::binary>>) when op in [0x43, 0x44], do: fail("unexpected end")

  defp instr(<<0xD0, r::binary>>) do
    {t, r} = reftype(r)
    {{:ref_null, t}, r}
  end

  defp instr(<<0xD1, r::binary>>), do: {:ref_is_null, r}
  defp instr(<<0xD2, r::binary>>), do: idx(:ref_func, r)

  defp instr(<<0xFC, r::binary>>) do
    {sub, r} = u32(r)

    cond do
      Map.has_key?(@sat, sub) ->
        {Map.fetch!(@sat, sub), r}

      sub == 8 ->
        {d, r} = u32(r)
        {m, r} = u32(r)
        {{:memory_init, d, m}, r}

      sub == 9 ->
        idx(:data_drop, r)

      sub == 10 ->
        {d, r} = u32(r)
        {src, r} = u32(r)
        {{:memory_copy, d, src}, r}

      sub == 11 ->
        idx(:memory_fill, r)

      sub == 12 ->
        {e, r} = u32(r)
        {t, r} = u32(r)
        {{:table_init, e, t}, r}

      sub == 13 ->
        idx(:elem_drop, r)

      sub == 14 ->
        {d, r} = u32(r)
        {s, r} = u32(r)
        {{:table_copy, d, s}, r}

      sub == 15 ->
        idx(:table_grow, r)

      sub == 16 ->
        idx(:table_size, r)

      sub == 17 ->
        idx(:table_fill, r)

      true ->
        fail("illegal opcode")
    end
  end

  defp instr(<<op, r::binary>>) when is_map_key(@numeric, op), do: {Map.fetch!(@numeric, op), r}
  defp instr(<<>>), do: fail("unexpected end")
  defp instr(_), do: fail("illegal opcode")

  defp catch_clause(<<k, r::binary>>) when k in [0, 1] do
    {t, r} = u32(r)
    {l, r} = u32(r)
    {{if(k == 0, do: :catch, else: :catch_ref), t, l}, r}
  end

  defp catch_clause(<<k, r::binary>>) when k in [2, 3] do
    {l, r} = u32(r)
    {{if(k == 2, do: :catch_all, else: :catch_all_ref), l}, r}
  end

  defp catch_clause(<<>>), do: fail("unexpected end")
  defp catch_clause(_), do: fail("malformed catch clause")

  defp idx(name, bin) do
    {i, r} = u32(bin)
    {{name, i}, r}
  end

  defp memarg(bin) do
    {a, r} = u32(bin)
    if a >= 128, do: fail("malformed memop flags")
    {m, r} = if (a &&& 64) != 0, do: u32(r), else: {0, r}
    {o, r} = u32(r)
    {a &&& 63, o, m, r}
  end
end
