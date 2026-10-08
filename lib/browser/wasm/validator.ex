defmodule Browser.Wasm.Validator do
  @moduledoc """
  Validates a decoded module with the algorithm of the WebAssembly specification and, in the
  same walk, turns every function body into flat code for `Browser.Wasm.Interp`: a tuple of
  instructions where every branch has its target `pc`, the number of values it keeps and the
  number of values it drops.
  """

  alias Browser.Wasm.{Error, Ops}

  @sigs Ops.signatures()
  @simd Ops.simd_signatures()
  @loads Map.new(Ops.loads(), fn {_, kind, t, a} -> {kind, {t, a}} end)
  @stores Map.new(Ops.stores(), fn {_, kind, t, a} -> {kind, {t, a}} end)
  @max_pages 65536

  defp err(msg), do: Error.fail(:compile, msg)

  @doc "Validates `mod`. Returns it with a `:compiled` list (one entry per defined function)."
  def validate(mod) do
    types = List.to_tuple(mod.types)
    ntypes = tuple_size(types)

    imp = fn kind -> for %{desc: {^kind, d}} <- mod.imports, do: d end

    for %{desc: {:func, t}} <- mod.imports, t >= ntypes, do: err("unknown type")
    for t <- mod.funcs, t >= ntypes, do: err("unknown type")
    for %{desc: {:tag, t}} <- mod.imports, t >= ntypes, do: err("unknown type")
    for t <- mod.tags, t >= ntypes, do: err("unknown type")

    tag_types =
      for(t <- imp.(:tag) ++ mod.tags, do: elem(types, t))
      |> tap(fn ts -> for {_, r} <- ts, r != [], do: err("non-empty tag result type") end)
      |> List.to_tuple()

    func_types =
      for(t <- imp.(:func) ++ mod.funcs, do: elem(types, t))
      |> List.to_tuple()

    tables = (imp.(:table) ++ mod.tables) |> Enum.map(&check_table/1) |> List.to_tuple()
    mems = (imp.(:mem) ++ mod.mems) |> Enum.map(&check_mem/1)
    imported_globals = imp.(:global)
    globals = (imported_globals ++ Enum.map(mod.globals, & &1.type)) |> List.to_tuple()

    c = %{
      types: types,
      funcs: func_types,
      tables: tables,
      nmems: length(mems),
      tags: tag_types,
      globals: globals,
      elems: mod.elems |> Enum.map(& &1.type) |> List.to_tuple(),
      ndatas: mod.data_count,
      refs: MapSet.new()
    }

    c = %{c | refs: collect_refs(mod)}

    # globals
    nimp = length(imported_globals)

    mod.globals
    |> Enum.with_index()
    |> Enum.each(fn {g, i} ->
      {t, _} = g.type
      const_expr(%{c | globals: take_globals(c.globals, nimp + i)}, g.init, t)
    end)

    # exports
    names = Enum.map(mod.exports, & &1.name)
    if length(names) != length(Enum.uniq(names)), do: err("duplicate export name")

    for e <- mod.exports do
      limit =
        case e.kind do
          :func -> tuple_size(c.funcs)
          :table -> tuple_size(c.tables)
          :mem -> c.nmems
          :global -> tuple_size(c.globals)
          :tag -> tuple_size(c.tags)
        end

      if e.index >= limit, do: err("unknown #{e.kind}")
    end

    # start
    if mod.start do
      case mod.start < tuple_size(c.funcs) && elem(c.funcs, mod.start) do
        false -> err("unknown function")
        {[], []} -> :ok
        _ -> err("start function")
      end
    end

    # elements
    for e <- mod.elems do
      case e.mode do
        {:active, t, off} ->
          if t >= tuple_size(c.tables), do: err("unknown table")
          {_, rt} = elem(c.tables, t)
          if rt != e.type, do: err("type mismatch")
          const_expr(c, off, :i32)

        _ ->
          :ok
      end

      for init <- e.inits, do: const_expr(c, init, e.type)
    end

    # data
    for d <- mod.datas do
      case d.mode do
        {:active, m, off} ->
          if m >= c.nmems, do: err("unknown memory")
          const_expr(c, off, :i32)

        _ ->
          :ok
      end
    end

    defined_types = Enum.map(mod.funcs, &elem(types, &1))

    compiled =
      for {code, {params, results}} <- Enum.zip(mod.codes, defined_types) do
        compile_func(c, params, code.locals, results, code.body)
      end

    Map.put(mod, :compiled, compiled)
  end

  defp take_globals(tuple, n), do: tuple |> Tuple.to_list() |> Enum.take(n) |> List.to_tuple()

  defp check_table({{min, max}, _} = table) do
    if max && min > max, do: err("size minimum must not be greater than maximum")
    table
  end

  defp check_mem({min, max}) do
    if min > @max_pages or (max && max > @max_pages),
      do: err("memory size must be at most 65536 pages (4GiB)")

    if max && min > max, do: err("size minimum must not be greater than maximum")
    :ok
  end

  defp collect_refs(mod) do
    from_exports = for %{kind: :func, index: i} <- mod.exports, do: i

    from_exprs = fn exprs ->
      for expr <- exprs, {:ref_func, i} <- expr, do: i
    end

    from_elems = from_exprs.(Enum.flat_map(mod.elems, & &1.inits))
    from_globals = from_exprs.(Enum.map(mod.globals, & &1.init))
    MapSet.new(from_exports ++ from_elems ++ from_globals)
  end

  # ── constant expressions ───────────────────────────────────

  defp const_expr(c, expr, type) do
    stack =
      Enum.reduce(expr, [], fn
        {:i32_const, _}, st ->
          [:i32 | st]

        {:i64_const, _}, st ->
          [:i64 | st]

        {:f32_const, _}, st ->
          [:f32 | st]

        {:f64_const, _}, st ->
          [:f64 | st]

        {:simd_const, _}, st ->
          [:v128 | st]

        {:ref_null, t}, st ->
          [t | st]

        {:ref_func, i}, st ->
          if i >= tuple_size(c.funcs), do: err("unknown function")
          [:funcref | st]

        {:global_get, i}, st ->
          if i >= tuple_size(c.globals), do: err("unknown global")
          {t, mut} = elem(c.globals, i)
          if mut == :var, do: err("constant expression required")
          [t | st]

        op, [b, a | st] when op in [:i32_add, :i32_sub, :i32_mul] and a == :i32 and b == :i32 ->
          [:i32 | st]

        op, [b, a | st] when op in [:i64_add, :i64_sub, :i64_mul] and a == :i64 and b == :i64 ->
          [:i64 | st]

        _, _ ->
          err("constant expression required")
      end)

    if stack != [type], do: err("type mismatch")
  end

  # ── function bodies ────────────────────────────────────────

  defp compile_func(c, params, locals, results, body) do
    c = Map.put(c, :locals, List.to_tuple(params ++ locals))
    label = 0

    frame = %{kind: :func, ins: [], outs: results, height: 0, unreachable: false, label: label}
    s = %{vals: [], h: 0, ctrls: [frame], out: [], pc: 0, nlabel: 1, labels: %{}}
    s = walk(c, s, body)
    s = end_ctrl(s)
    s = emit(s, {:return, length(results)})
    labels = s.labels
    code = s.out |> Enum.reverse() |> Enum.map(&resolve(&1, labels)) |> List.to_tuple()

    %{
      nparams: length(params),
      zeros: Enum.map(locals, &zero/1),
      nres: length(results),
      code: code
    }
  end

  defp zero(:i32), do: 0
  defp zero(:i64), do: 0
  defp zero(:f32), do: 0.0
  defp zero(:f64), do: 0.0
  defp zero(:v128), do: 0
  defp zero(_), do: :null

  defp resolve({:br, {:L, l}, 0, 0}, labels), do: {:jump, Map.fetch!(labels, l)}
  defp resolve({:br, {:L, l}, a, d}, labels), do: {:br, Map.fetch!(labels, l), a, d}
  defp resolve({:br_if, {:L, l}, 0, 0}, labels), do: {:jump_if, Map.fetch!(labels, l)}
  defp resolve({:br_if, {:L, l}, a, d}, labels), do: {:br_if, Map.fetch!(labels, l), a, d}
  defp resolve({:jump, {:L, l}}, labels), do: {:jump, Map.fetch!(labels, l)}
  defp resolve({:jump_unless, {:L, l}}, labels), do: {:jump_unless, Map.fetch!(labels, l)}

  defp resolve({:br_table, targets, {:L, dl, da, dd}}, labels) do
    ts = for {:L, l, a, d} <- targets, do: {Map.fetch!(labels, l), a, d}
    {:br_table, List.to_tuple(ts), {Map.fetch!(labels, dl), da, dd}}
  end

  defp resolve({:try_table, handlers, np, {:L, end_l}}, labels) do
    hs =
      for {tag, ref?, {:L, l, arity, drop}} <- handlers,
          do: {tag, ref?, Map.fetch!(labels, l), arity, drop}

    {:try_table, hs, np, Map.fetch!(labels, end_l)}
  end

  defp resolve(other, _), do: other

  defp emit(s, ins), do: %{s | out: [ins | s.out], pc: s.pc + 1}
  defp push(s, t), do: %{s | vals: [t | s.vals], h: s.h + 1}
  defp push_all(s, ts), do: Enum.reduce(ts, s, &push(&2, &1))

  defp pop(s) do
    [f | _] = s.ctrls

    if s.h == f.height do
      if f.unreachable, do: {:unknown, s}, else: err("type mismatch")
    else
      [t | rest] = s.vals
      {t, %{s | vals: rest, h: s.h - 1}}
    end
  end

  defp pop(s, expect) do
    {t, s} = pop(s)

    cond do
      t == :unknown -> {expect, s}
      expect == :unknown -> {t, s}
      t == expect -> {t, s}
      true -> err("type mismatch")
    end
  end

  defp pop_all(s, types) do
    types |> Enum.reverse() |> Enum.reduce(s, fn t, s -> elem(pop(s, t), 1) end)
  end

  defp unreachable(s) do
    [f | rest] = s.ctrls
    drop = s.h - f.height
    %{s | vals: Enum.drop(s.vals, drop), h: f.height, ctrls: [%{f | unreachable: true} | rest]}
  end

  defp new_label(s), do: {s.nlabel, %{s | nlabel: s.nlabel + 1}}
  defp define(s, l), do: %{s | labels: Map.put(s.labels, l, s.pc)}

  defp push_ctrl(s, kind, ins, outs, label) do
    f = %{kind: kind, ins: ins, outs: outs, height: s.h, unreachable: false, label: label}
    push_all(%{s | ctrls: [f | s.ctrls]}, ins)
  end

  defp check_end(s) do
    [f | _] = s.ctrls
    s = pop_all(s, f.outs)
    if s.h != f.height, do: err("type mismatch")
    s
  end

  defp end_ctrl(s) do
    s = check_end(s)
    [f | rest] = s.ctrls
    s = %{s | ctrls: rest}
    s = if f.kind == :loop, do: s, else: define(s, f.label)
    push_all(s, f.outs)
  end

  defp label_types(%{kind: :loop, ins: ins}), do: ins
  defp label_types(f), do: f.outs

  defp frame(s, depth) do
    Enum.at(s.ctrls, depth) || err("unknown label")
  end

  defp blocktype(_, :empty), do: {[], []}
  defp blocktype(_, {:val, t}), do: {[], [t]}

  defp blocktype(c, {:type, i}) do
    if i >= tuple_size(c.types), do: err("unknown type")
    elem(c.types, i)
  end

  defp walk(c, s, body), do: Enum.reduce(body, s, &ins(c, &2, &1))

  defp ins(_, s, :nop), do: s
  defp ins(_, s, :unreachable), do: s |> emit(:unreachable) |> unreachable()

  defp ins(c, s, {kind, bt, body}) when kind in [:block, :loop] do
    {ins, outs} = blocktype(c, bt)
    s = pop_all(s, ins)
    {l, s} = new_label(s)
    s = if kind == :loop, do: define(s, l), else: s
    s = push_ctrl(s, kind, ins, outs, l)
    s |> then(&walk(c, &1, body)) |> end_ctrl()
  end

  defp ins(c, s, {:if, bt, then, els}) do
    {ins, outs} = blocktype(c, bt)
    {_, s} = pop(s, :i32)
    s = pop_all(s, ins)
    {end_l, s} = new_label(s)
    {else_l, s} = new_label(s)
    s = emit(s, {:jump_unless, {:L, else_l}})
    s = push_ctrl(s, :if, ins, outs, end_l)
    s = walk(c, s, then)

    if els do
      s = check_end(s)
      s = emit(s, {:jump, {:L, end_l}})
      s = define(s, else_l)
      [f | rest] = s.ctrls
      s = %{s | ctrls: [%{f | unreachable: false} | rest]}
      s = push_all(s, ins)
      s |> then(&walk(c, &1, els)) |> end_ctrl()
    else
      if ins != outs, do: err("type mismatch")
      s = end_ctrl(s)
      define(s, else_l)
    end
  end

  defp ins(_, s, {:br, depth}) do
    f = frame(s, depth)
    types = label_types(f)
    target = {:br, {:L, f.label}, length(types), max(0, s.h - f.height - length(types))}
    s |> pop_all(types) |> then(&emit(&1, target)) |> unreachable()
  end

  defp ins(_, s, {:br_if, depth}) do
    {_, s} = pop(s, :i32)
    f = frame(s, depth)
    types = label_types(f)
    target = {:br_if, {:L, f.label}, length(types), max(0, s.h - f.height - length(types))}
    s |> pop_all(types) |> push_all(types) |> then(&emit(&1, target))
  end

  defp ins(_, s, {:br_table, labels, default}) do
    {_, s} = pop(s, :i32)
    df = frame(s, default)
    arity = length(label_types(df))

    target = fn depth ->
      f = frame(s, depth)
      types = label_types(f)
      if length(types) != arity, do: err("type mismatch")
      pop_all(s, types)
      {:L, f.label, arity, max(0, s.h - f.height - arity)}
    end

    targets = Enum.map(labels, target)
    {:L, dl, da, dd} = target.(default)
    s = pop_all(s, label_types(df))
    s |> emit({:br_table, targets, {:L, dl, da, dd}}) |> unreachable()
  end

  defp ins(c, s, {:throw, t}) do
    if t >= tuple_size(c.tags), do: err("unknown tag")
    {params, _} = elem(c.tags, t)
    s |> pop_all(params) |> emit({:throw, t, length(params)}) |> unreachable()
  end

  defp ins(_, s, :throw_ref) do
    {_, s} = pop(s, :exnref)
    s |> emit(:throw_ref) |> unreachable()
  end

  defp ins(c, s, {:try_table, bt, catches, body}) do
    {ins, outs} = blocktype(c, bt)

    handlers =
      for clause <- catches do
        {tag, ref?, label, types} = catch_target(c, clause)
        f = frame(s, label)
        if label_types(f) != types, do: err("type mismatch")
        # the stack is cut back to the height at the try_table, so the values are all there is
        drop = max(0, s.h - length(ins) - f.height)
        {tag, ref?, {:L, f.label, length(types), drop}}
      end

    s = pop_all(s, ins)
    {l, s} = new_label(s)
    {end_l, s} = new_label(s)
    s = emit(s, {:try_table, handlers, length(ins), {:L, end_l}})
    s = push_ctrl(s, :block, ins, outs, l)
    s = walk(c, s, body)
    s = define(s, end_l)
    s = emit(s, :try_end)
    end_ctrl(s)
  end

  defp ins(_, s, :return) do
    [f | _] = Enum.reverse(s.ctrls)
    s |> pop_all(f.outs) |> emit({:return, length(f.outs)}) |> unreachable()
  end

  defp ins(c, s, {:call, i}) do
    if i >= tuple_size(c.funcs), do: err("unknown function")
    {params, results} = elem(c.funcs, i)
    s |> pop_all(params) |> push_all(results) |> emit({:call, i, length(params)})
  end

  defp ins(c, s, {:return_call, i}) do
    if i >= tuple_size(c.funcs), do: err("unknown function")
    {params, results} = elem(c.funcs, i)
    check_tail(s, results)
    s |> pop_all(params) |> emit({:return_call, i, length(params)}) |> unreachable()
  end

  defp ins(c, s, {:return_call_indirect, ti, tbl}) do
    if tbl >= tuple_size(c.tables), do: err("unknown table")
    {_, rt} = elem(c.tables, tbl)
    if rt != :funcref, do: err("type mismatch")
    if ti >= tuple_size(c.types), do: err("unknown type")
    {params, results} = elem(c.types, ti)
    check_tail(s, results)
    {_, s} = pop(s, :i32)

    s
    |> pop_all(params)
    |> emit({:return_call_indirect, ti, tbl, length(params)})
    |> unreachable()
  end

  defp ins(c, s, {:call_indirect, ti, tbl}) do
    if tbl >= tuple_size(c.tables), do: err("unknown table")
    {_, rt} = elem(c.tables, tbl)
    if rt != :funcref, do: err("type mismatch")
    if ti >= tuple_size(c.types), do: err("unknown type")
    {params, results} = elem(c.types, ti)
    {_, s} = pop(s, :i32)
    s |> pop_all(params) |> push_all(results) |> emit({:call_indirect, ti, tbl, length(params)})
  end

  defp ins(_, s, :drop) do
    {_, s} = pop(s)
    emit(s, :drop)
  end

  defp ins(_, s, :select) do
    {_, s} = pop(s, :i32)
    {t1, s} = pop(s)
    {t2, s} = pop(s)

    if t1 in [:funcref, :externref, :exnref] or t2 in [:funcref, :externref, :exnref],
      do: err("type mismatch")

    if t1 != :unknown and t2 != :unknown and t1 != t2, do: err("type mismatch")
    s |> push(if(t1 == :unknown, do: t2, else: t1)) |> emit(:select)
  end

  defp ins(_, s, {:select_t, t}) do
    {_, s} = pop(s, :i32)
    {_, s} = pop(s, t)
    {_, s} = pop(s, t)
    s |> push(t) |> emit(:select)
  end

  defp ins(c, s, {:local_get, i}) do
    s |> push(local(c, i)) |> emit({:lget, i})
  end

  defp ins(c, s, {:local_set, i}) do
    {_, s} = pop(s, local(c, i))
    emit(s, {:lset, i})
  end

  defp ins(c, s, {:local_tee, i}) do
    t = local(c, i)
    {_, s} = pop(s, t)
    s |> push(t) |> emit({:ltee, i})
  end

  defp ins(c, s, {:global_get, i}) do
    if i >= tuple_size(c.globals), do: err("unknown global")
    {t, _} = elem(c.globals, i)
    s |> push(t) |> emit({:gget, i})
  end

  defp ins(c, s, {:global_set, i}) do
    if i >= tuple_size(c.globals), do: err("unknown global")
    {t, mut} = elem(c.globals, i)
    if mut != :var, do: err("global is immutable")
    {_, s} = pop(s, t)
    emit(s, {:gset, i})
  end

  defp ins(c, s, {:table_get, t}) do
    rt = table_type(c, t)
    {_, s} = pop(s, :i32)
    s |> push(rt) |> emit({:table_get, t})
  end

  defp ins(c, s, {:table_set, t}) do
    rt = table_type(c, t)
    {_, s} = pop(s, rt)
    {_, s} = pop(s, :i32)
    emit(s, {:table_set, t})
  end

  defp ins(c, s, {:table_size, t}) do
    table_type(c, t)
    s |> push(:i32) |> emit({:table_size, t})
  end

  defp ins(c, s, {:table_grow, t}) do
    rt = table_type(c, t)
    {_, s} = pop(s, :i32)
    {_, s} = pop(s, rt)
    s |> push(:i32) |> emit({:table_grow, t})
  end

  defp ins(c, s, {:table_fill, t}) do
    rt = table_type(c, t)
    s = pop_all(s, [:i32, rt, :i32])
    emit(s, {:table_fill, t})
  end

  defp ins(c, s, {:table_copy, d, src}) do
    dt = table_type(c, d)
    if table_type(c, src) != dt, do: err("type mismatch")
    s |> pop_all([:i32, :i32, :i32]) |> emit({:table_copy, d, src})
  end

  defp ins(c, s, {:table_init, e, t}) do
    rt = table_type(c, t)
    if e >= tuple_size(c.elems), do: err("unknown elem segment")
    if elem(c.elems, e) != rt, do: err("type mismatch")
    s |> pop_all([:i32, :i32, :i32]) |> emit({:table_init, e, t})
  end

  defp ins(c, s, {:elem_drop, e}) do
    if e >= tuple_size(c.elems), do: err("unknown elem segment")
    emit(s, {:elem_drop, e})
  end

  defp ins(c, s, {:load, kind, align, offset, m}) do
    mem(c, m)
    {t, natural} = Map.fetch!(@loads, kind)
    if align > natural, do: err("alignment must not be larger than natural")
    {_, s} = pop(s, :i32)
    s |> push(t) |> emit({:load, kind, offset, m})
  end

  defp ins(c, s, {:store, kind, align, offset, m}) do
    mem(c, m)
    {t, natural} = Map.fetch!(@stores, kind)
    if align > natural, do: err("alignment must not be larger than natural")
    s = pop_all(s, [:i32, t])
    emit(s, {:store, kind, offset, m})
  end

  defp ins(c, s, {:memory_size, m}) do
    mem(c, m)
    s |> push(:i32) |> emit({:memory_size, m})
  end

  defp ins(c, s, {:memory_grow, m}) do
    mem(c, m)
    {_, s} = pop(s, :i32)
    s |> push(:i32) |> emit({:memory_grow, m})
  end

  defp ins(c, s, {:memory_init, d, m}) do
    mem(c, m)
    data_idx(c, d)
    s |> pop_all([:i32, :i32, :i32]) |> emit({:memory_init, d, m})
  end

  defp ins(c, s, {:data_drop, d}) do
    data_idx(c, d)
    emit(s, {:data_drop, d})
  end

  defp ins(c, s, {:memory_copy, d, src}) do
    mem(c, d)
    mem(c, src)
    s |> pop_all([:i32, :i32, :i32]) |> emit({:memory_copy, d, src})
  end

  defp ins(c, s, {:memory_fill, m}) do
    mem(c, m)
    s |> pop_all([:i32, :i32, :i32]) |> emit({:memory_fill, m})
  end

  defp ins(_, s, {:simd_const, v}), do: s |> push(:v128) |> emit({:const, v})

  defp ins(_, s, {:simd, shape, op, imm}) do
    {params, result, kind} = Map.fetch!(@simd, {shape, op})

    case kind do
      {:lane, n} -> if imm >= n, do: err("invalid lane index")
      :shuffle -> if Enum.any?(imm, &(&1 >= 32)), do: err("invalid lane index")
      nil -> :ok
    end

    s = pop_all(s, params)
    emit(push(s, result), {:simd, shape, op, imm, length(params)})
  end

  defp ins(c, s, {:simd_mem, shape, op, align, offset, m, lane}) do
    mem(c, m)
    {params, result, kind} = Map.fetch!(@simd, {shape, op})

    {natural, lanes} =
      case kind do
        {:mem, a} -> {a, nil}
        {:mem_lane, a, n} -> {a, n}
      end

    if align > natural, do: err("alignment must not be larger than natural")
    if lanes != nil and lane >= lanes, do: err("invalid lane index")
    s = pop_all(s, params)
    s = if result, do: push(s, result), else: s
    emit(s, {:simd_mem, op, offset, m, lane})
  end

  defp ins(_, s, {:i32_const, v}), do: s |> push(:i32) |> emit({:const, v})
  defp ins(_, s, {:i64_const, v}), do: s |> push(:i64) |> emit({:const, v})
  defp ins(_, s, {:f32_const, v}), do: s |> push(:f32) |> emit({:const, v})
  defp ins(_, s, {:f64_const, v}), do: s |> push(:f64) |> emit({:const, v})
  defp ins(_, s, {:ref_null, t}), do: s |> push(t) |> emit({:const, :null})

  defp ins(_, s, :ref_is_null) do
    {t, s} = pop(s)
    unless t in [:funcref, :externref, :exnref, :unknown], do: err("type mismatch")
    s |> push(:i32) |> emit(:ref_is_null)
  end

  defp ins(c, s, {:ref_func, i}) do
    if i >= tuple_size(c.funcs), do: err("unknown function")
    unless MapSet.member?(c.refs, i), do: err("undeclared function reference")
    s |> push(:funcref) |> emit({:ref_func, i})
  end

  defp ins(_, s, op) when is_atom(op) do
    case Map.fetch(@sigs, op) do
      {:ok, {params, result}} ->
        s = pop_all(s, params)
        kind = if length(params) == 1, do: :un, else: :bin
        s |> push(result) |> emit({kind, op})

      :error ->
        err("illegal opcode")
    end
  end

  # a tail call returns the results of the callee, so they must be the results of the function
  defp check_tail(s, results) do
    [f | _] = Enum.reverse(s.ctrls)
    if f.outs != results, do: err("type mismatch")
  end

  defp catch_target(c, {kind, t, l}) when kind in [:catch, :catch_ref] do
    if t >= tuple_size(c.tags), do: err("unknown tag")
    {params, _} = elem(c.tags, t)
    ref? = kind == :catch_ref
    {t, ref?, l, if(ref?, do: params ++ [:exnref], else: params)}
  end

  defp catch_target(_, {:catch_all, l}), do: {:all, false, l, []}
  defp catch_target(_, {:catch_all_ref, l}), do: {:all, true, l, [:exnref]}

  defp local(c, i) do
    if i >= tuple_size(c.locals), do: err("unknown local")
    elem(c.locals, i)
  end

  defp table_type(c, t) do
    if t >= tuple_size(c.tables), do: err("unknown table")
    {_, rt} = elem(c.tables, t)
    rt
  end

  defp mem(c, m), do: if(m >= c.nmems, do: err("unknown memory"))

  defp data_idx(c, d) do
    if c.ndatas == nil, do: err("data count section required")
    if d >= c.ndatas, do: err("unknown data segment")
  end
end
