defmodule Browser.Wasm.Interp do
  @moduledoc """
  Runs the flat code that `Browser.Wasm.Validator` makes. The operand stack is a list (top
  first), the locals are a tuple. A call is a recursive call of `invoke/3`; the depth is
  limited like a real stack.
  """

  import Bitwise
  alias Browser.Wasm.{Atomic, Func, Global, Memory, Num, Simd, Table}

  @max_depth 10_000

  defp trap(msg), do: Num.trap(msg)

  # counts a step against the budget of the JavaScript runtime that runs this code, if any, so
  # that a loop in a module cannot hang the page
  defp tick do
    case Process.get(:js_steps) do
      nil -> :ok
      n when n <= 0 -> throw(:js_limit)
      n -> Process.put(:js_steps, n - 1)
    end
  end

  defp back(to, pc) when to <= pc, do: tick()
  defp back(_, _), do: :ok

  @doc "The instance record of an instance id."
  def instance(id), do: Process.get({:wasm_instance, id})

  @doc "The data and element segments that are not dropped yet."
  def segments(id), do: Process.get({:wasm_segments, id})

  @doc "Calls a function instance with a list of arguments; returns the list of results."
  def invoke(func, args, depth \\ 0)
  def invoke(%Func{impl: {:host, fun}}, args, _), do: fun.(args)

  def invoke(%Func{impl: {:wasm, iid, idx}}, args, depth) do
    if depth > @max_depth, do: trap("call stack exhausted")
    tick()
    inst = instance(iid)
    fc = elem(inst.code, idx)
    locals = List.to_tuple(args ++ fc.zeros)
    run(fc.code, 0, [], locals, inst, depth + 1)
  end

  defp run(code, pc, stack, locals, inst, depth) do
    case elem(code, pc) do
      {:const, v} ->
        run(code, pc + 1, [v | stack], locals, inst, depth)

      {:lget, i} ->
        run(code, pc + 1, [elem(locals, i) | stack], locals, inst, depth)

      {:lset, i} ->
        [v | st] = stack
        run(code, pc + 1, st, put_elem(locals, i, v), inst, depth)

      {:ltee, i} ->
        [v | _] = stack
        run(code, pc + 1, stack, put_elem(locals, i, v), inst, depth)

      {:bin, op} ->
        [b, a | st] = stack
        run(code, pc + 1, [Num.binop(op, a, b) | st], locals, inst, depth)

      {:un, op} ->
        [a | st] = stack
        run(code, pc + 1, [Num.unop(op, a) | st], locals, inst, depth)

      {:jump, to} ->
        back(to, pc)
        go(code, to, stack, locals, inst, depth)

      {:jump_unless, to} ->
        [c | st] = stack
        go(code, if(c == 0, do: to, else: pc + 1), st, locals, inst, depth)

      {:jump_if, to} ->
        [c | st] = stack
        if c != 0, do: back(to, pc)
        go(code, if(c == 0, do: pc + 1, else: to), st, locals, inst, depth)

      {:br, to, arity, drop} ->
        back(to, pc)
        go(code, to, branch(stack, arity, drop), locals, inst, depth)

      {:br_if, to, arity, drop} ->
        [c | st] = stack

        if c == 0 do
          run(code, pc + 1, st, locals, inst, depth)
        else
          back(to, pc)
          go(code, to, branch(st, arity, drop), locals, inst, depth)
        end

      {:br_table, targets, default} ->
        [i | st] = stack

        {to, arity, drop} =
          if i < tuple_size(targets), do: elem(targets, i), else: default

        back(to, pc)
        go(code, to, branch(st, arity, drop), locals, inst, depth)

      {:return, n} ->
        stack |> Enum.take(n) |> Enum.reverse()

      {:call, idx, np} ->
        {args, rest} = Enum.split(stack, np)

        case call(inst, locals, elem(inst.funcs, idx), Enum.reverse(args), depth) do
          {:__exc, _, _} = exc -> exc
          results -> run(code, pc + 1, push_results(results, rest), locals, inst, depth)
        end

      {:return_call, idx, np} ->
        {args, _} = Enum.split(stack, np)
        tail_call(elem(inst.funcs, idx), Enum.reverse(args), depth)

      {:return_call_indirect, ti, tbl, np} ->
        [i | st] = stack
        f = indirect(inst, ti, tbl, i)
        {args, _} = Enum.split(st, np)
        tail_call(f, Enum.reverse(args), depth)

      {:call_indirect, ti, tbl, np} ->
        [i | st] = stack
        f = indirect(inst, ti, tbl, i)
        {args, rest} = Enum.split(st, np)

        case call(inst, locals, f, Enum.reverse(args), depth) do
          {:__exc, _, _} = exc -> exc
          results -> run(code, pc + 1, push_results(results, rest), locals, inst, depth)
        end

      {:throw, t, np} ->
        {args, _} = Enum.split(stack, np)
        raise_exc({:wasm_exception, elem(inst.tags, t), Enum.reverse(args)}, inst, locals)

      :throw_ref ->
        case stack do
          [{:exn, tag, vals} | _] -> raise_exc({:wasm_exception, tag, vals}, inst, locals)
          _ -> trap("null exception reference")
        end

      {:throw_ref_skip, n} ->
        [{:exn, tag, vals} | _] = stack
        raise_exc_skip({:wasm_exception, tag, vals}, n, inst, locals)

      {:try_table, handlers, np, hi} ->
        nested = %{inst | tr: {pc + 1, hi}}

        case run(code, pc + 1, stack, locals, nested, depth) do
          {:__exit, to, st, locals2} ->
            go(code, to, st, locals2, inst, depth)

          {:__exc_skip, n, exc, locals2} ->
            raise_exc_skip(exc, n - 1, inst, locals2)

          {:__exc, {:wasm_exception, tag, vals} = exc, locals2} ->
            case find_handler(handlers, inst, tag) do
              nil ->
                raise_exc(exc, inst, locals2)

              {ref?, to, arity, drop} ->
                pushed = push_results(vals, Enum.drop(stack, np))
                pushed = if ref?, do: [{:exn, tag, vals} | pushed], else: pushed
                go(code, to, branch(pushed, arity, drop), locals2, inst, depth)
            end

          results ->
            results
        end

      :try_end ->
        {:__exit, pc + 1, stack, locals}

      :drop ->
        run(code, pc + 1, tl(stack), locals, inst, depth)

      :select ->
        [c, b, a | st] = stack
        run(code, pc + 1, [if(c != 0, do: a, else: b) | st], locals, inst, depth)

      :unreachable ->
        trap("unreachable")

      {:gget, i} ->
        run(code, pc + 1, [Global.get(elem(inst.globals, i)) | stack], locals, inst, depth)

      {:gset, i} ->
        [v | st] = stack
        Global.set(elem(inst.globals, i), v)
        run(code, pc + 1, st, locals, inst, depth)

      {:load, kind, off, m} ->
        [base | st] = stack
        v = load(elem(inst.mems, m), kind, base + off)
        run(code, pc + 1, [v | st], locals, inst, depth)

      {:store, kind, off, m} ->
        [v, base | st] = stack
        store(elem(inst.mems, m), kind, base + off, v)
        run(code, pc + 1, st, locals, inst, depth)

      {:simd, shape, op, imm, n} ->
        {args, st} = Enum.split(stack, n)
        r = Simd.exec(shape, op, Enum.reverse(args), imm)
        run(code, pc + 1, [r | st], locals, inst, depth)

      {:atomic, op, width, off, m, n} ->
        {args, st} = Enum.split(stack, n)

        st =
          case Atomic.exec(op, width, off, elem(inst.mems, m), Enum.reverse(args)) do
            :none -> st
            r -> [r | st]
          end

        run(code, pc + 1, st, locals, inst, depth)

      {:atomic_fence} ->
        run(code, pc + 1, stack, locals, inst, depth)

      {:simd_mem, op, off, m, lane} ->
        st = Simd.mem(op, lane, elem(inst.mems, m), off, stack)
        run(code, pc + 1, st, locals, inst, depth)

      {:memory_size, m} ->
        run(code, pc + 1, [Memory.size(elem(inst.mems, m)) | stack], locals, inst, depth)

      {:memory_grow, m} ->
        [d | st] = stack
        mem = elem(inst.mems, m)
        r = Memory.grow(mem, d)
        mask = if mem.addr == :i64, do: 0xFFFFFFFFFFFFFFFF, else: 0xFFFFFFFF
        run(code, pc + 1, [r &&& mask | st], locals, inst, depth)

      :ref_is_null ->
        [v | st] = stack
        run(code, pc + 1, [if(v == :null, do: 1, else: 0) | st], locals, inst, depth)

      {:ref_func, i} ->
        run(code, pc + 1, [elem(inst.funcs, i) | stack], locals, inst, depth)

      other ->
        st = bulk(other, stack, inst)
        run(code, pc + 1, st, locals, inst, depth)
    end
  end

  # a branch; inside a try_table, one that leaves its code ends the nested run
  defp go(code, to, stack, locals, %{tr: tr} = inst, depth) do
    case tr do
      {lo, hi} when to < lo or to > hi -> {:__exit, to, stack, locals}
      _ -> run(code, to, stack, locals, inst, depth)
    end
  end

  # a call; in a try_table an exception comes back as a value, so the locals are not lost
  defp call(%{tr: false}, _, f, args, depth), do: invoke(f, args, depth)

  defp call(_, locals, f, args, depth) do
    invoke(f, args, depth)
  catch
    :throw, {:wasm_exception, _, _} = exc -> {:__exc, exc, locals}
  end

  # a delegate: skip the next `n` enclosing try blocks
  defp raise_exc_skip(exc, 0, inst, locals), do: raise_exc(exc, inst, locals)
  defp raise_exc_skip(exc, _, %{tr: false}, _), do: throw(exc)
  defp raise_exc_skip(exc, n, _, locals), do: {:__exc_skip, n, exc, locals}

  defp raise_exc(exc, %{tr: false}, _), do: throw(exc)
  defp raise_exc(exc, _, locals), do: {:__exc, exc, locals}

  defp find_handler(handlers, inst, tag) do
    Enum.find_value(handlers, fn {t, ref?, to, arity, drop} ->
      if t == :all or elem(inst.tags, t) == tag, do: {ref?, to, arity, drop}
    end)
  end

  defp indirect(inst, ti, tbl, i) do
    table = elem(inst.tables, tbl)
    if i >= Table.size(table), do: trap("undefined element")

    f =
      case Table.get(table, i) do
        :null -> trap("uninitialized element")
        f -> f
      end

    if f.type != elem(inst.types, ti), do: trap("indirect call type mismatch")
    f
  end

  # runs the callee in place of the caller: the depth does not grow
  defp tail_call(%Func{impl: {:wasm, iid, idx}}, args, depth) do
    tick()
    inst = instance(iid)
    fc = elem(inst.code, idx)
    run(fc.code, 0, [], List.to_tuple(args ++ fc.zeros), inst, depth)
  end

  defp tail_call(func, args, depth), do: invoke(func, args, depth)

  defp branch(stack, 0, 0), do: stack
  defp branch(stack, 0, drop), do: Enum.drop(stack, drop)

  defp branch(stack, arity, drop) do
    {vals, rest} = Enum.split(stack, arity)
    vals ++ Enum.drop(rest, drop)
  end

  defp push_results(results, stack), do: Enum.reduce(results, stack, &[&1 | &2])

  # ── tables, segments, bulk memory ──────────────────────────

  defp bulk({:table_get, t}, [i | st], inst), do: [Table.get(elem(inst.tables, t), i) | st]

  defp bulk({:table_set, t}, [v, i | st], inst) do
    Table.set(elem(inst.tables, t), i, v)
    st
  end

  defp bulk({:table_size, t}, st, inst), do: [Table.size(elem(inst.tables, t)) | st]

  defp bulk({:table_grow, t}, [n, v | st], inst) do
    table = elem(inst.tables, t)
    mask = if table.addr == :i64, do: 0xFFFFFFFFFFFFFFFF, else: 0xFFFFFFFF
    [Table.grow(table, n, v) &&& mask | st]
  end

  defp bulk({:table_fill, t}, [n, v, i | st], inst) do
    Table.fill(elem(inst.tables, t), i, v, n)
    st
  end

  defp bulk({:table_copy, d, s}, [n, src, dst | st], inst) do
    Table.copy(elem(inst.tables, d), dst, elem(inst.tables, s), src, n)
    st
  end

  defp bulk({:table_init, e, t}, [n, src, dst | st], inst) do
    segs = segments(inst.id)
    items = elem(segs.elems, e)
    if src + n > length(items), do: trap("out of bounds table access")
    table = elem(inst.tables, t)
    if dst + n > Table.size(table), do: trap("out of bounds table access")
    Table.init(table, dst, items |> Enum.drop(src) |> Enum.take(n))
    st
  end

  defp bulk({:elem_drop, e}, st, inst) do
    segs = segments(inst.id)
    Process.put({:wasm_segments, inst.id}, %{segs | elems: put_elem(segs.elems, e, [])})
    st
  end

  defp bulk({:memory_init, d, m}, [n, src, dst | st], inst) do
    segs = segments(inst.id)
    bytes = elem(segs.datas, d)
    mem = elem(inst.mems, m)
    if src + n > byte_size(bytes), do: trap("out of bounds memory access")
    if dst + n > Memory.size(mem) * Memory.page_size(), do: trap("out of bounds memory access")
    if n > 0, do: Memory.write(mem, dst, binary_part(bytes, src, n))
    st
  end

  defp bulk({:data_drop, d}, st, inst) do
    segs = segments(inst.id)
    Process.put({:wasm_segments, inst.id}, %{segs | datas: put_elem(segs.datas, d, <<>>)})
    st
  end

  defp bulk({:memory_copy, d, s}, [n, src, dst | st], inst) do
    Memory.copy(elem(inst.mems, d), dst, elem(inst.mems, s), src, n)
    st
  end

  defp bulk({:memory_fill, m}, [n, v, dst | st], inst) do
    Memory.fill(elem(inst.mems, m), dst, v &&& 0xFF, n)
    st
  end

  # ── loads and stores ───────────────────────────────────────

  defp load(m, kind, a), do: decode(kind, Memory.read(m, a, width(kind)))

  defp width(k) when k in [:i32, :f32, :i64_32u, :i64_32s], do: 4
  defp width(k) when k in [:i64, :f64], do: 8
  defp width(k) when k in [:i32_8u, :i64_8u, :i32_8s, :i64_8s], do: 1
  defp width(_), do: 2

  defp decode(:i32, <<v::little-32>>), do: v
  defp decode(:i64, <<v::little-64>>), do: v
  defp decode(:f32, <<v::little-32>>), do: Num.f32_from_bits(v)
  defp decode(:f64, <<v::little-64>>), do: Num.f64_from_bits(v)
  defp decode(k, <<v::8>>) when k in [:i32_8u, :i64_8u], do: v
  defp decode(k, <<v::little-16>>) when k in [:i32_16u, :i64_16u], do: v
  defp decode(:i64_32u, <<v::little-32>>), do: v
  defp decode(:i32_8s, <<v::signed-8>>), do: v &&& 0xFFFFFFFF
  defp decode(:i32_16s, <<v::little-signed-16>>), do: v &&& 0xFFFFFFFF
  defp decode(:i64_8s, <<v::signed-8>>), do: v &&& 0xFFFFFFFFFFFFFFFF
  defp decode(:i64_16s, <<v::little-signed-16>>), do: v &&& 0xFFFFFFFFFFFFFFFF
  defp decode(:i64_32s, <<v::little-signed-32>>), do: v &&& 0xFFFFFFFFFFFFFFFF

  defp store(m, k, a, v) when k in [:i32, :i64_32], do: Memory.write(m, a, <<v::little-32>>)
  defp store(m, :i64, a, v), do: Memory.write(m, a, <<v::little-64>>)
  defp store(m, :f32, a, v), do: Memory.write(m, a, <<Num.f32_to_bits(v)::little-32>>)
  defp store(m, :f64, a, v), do: Memory.write(m, a, <<Num.f64_to_bits(v)::little-64>>)
  defp store(m, k, a, v) when k in [:i32_8, :i64_8], do: Memory.write(m, a, <<v::8>>)
  defp store(m, k, a, v) when k in [:i32_16, :i64_16], do: Memory.write(m, a, <<v::little-16>>)
end
