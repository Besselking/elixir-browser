defmodule Browser.Wasm.Validator do
  @moduledoc """
  Validates a decoded module with the algorithm of the WebAssembly specification and, in the
  same walk, turns every function body into flat code for `Browser.Wasm.Interp`: a tuple of
  instructions where every branch has its target `pc`, the number of values it keeps and the
  number of values it drops.
  """

  alias Browser.Wasm.{Error, Ops, Types}

  @sigs Ops.signatures()
  @simd Ops.simd_signatures()
  @atomic Ops.atomic_signatures()
  @loads Map.new(Ops.loads(), fn {_, kind, t, a} -> {kind, {t, a}} end)
  @stores Map.new(Ops.stores(), fn {_, kind, t, a} -> {kind, {t, a}} end)
  @max_pages 65536
  @max_pages64 281_474_976_710_656

  defp err(msg), do: Error.fail(:compile, msg)

  @doc "Validates `mod`. Returns it with a `:compiled` list (one entry per defined function)."
  def validate(mod) do
    types = List.to_tuple(mod.types)
    keys = List.to_tuple(mod.type_keys)
    ntypes = tuple_size(types)
    check_type_defs(mod.type_keys)

    imp = fn kind -> for %{desc: {^kind, d}} <- mod.imports, do: d end

    for %{desc: {:func, t}} <- mod.imports, t >= ntypes, do: err("unknown type")
    for t <- mod.funcs, t >= ntypes, do: err("unknown type")
    for %{desc: {:tag, t}} <- mod.imports, t >= ntypes, do: err("unknown type")
    for t <- mod.tags, t >= ntypes, do: err("unknown type")

    for t <- imp.(:func) ++ mod.funcs, do: func_type!(types, t)

    tag_types =
      for(t <- imp.(:tag) ++ mod.tags, do: func_type!(types, t))
      |> tap(fn ts -> for {_, r} <- ts, r != [], do: err("non-empty tag result type") end)
      |> List.to_tuple()

    func_types =
      for(t <- imp.(:func) ++ mod.funcs, do: elem(types, t))
      |> List.to_tuple()

    func_keys = for(t <- imp.(:func) ++ mod.funcs, do: elem(keys, t)) |> List.to_tuple()

    tables = (imp.(:table) ++ mod.tables) |> Enum.map(&check_table/1) |> List.to_tuple()
    mems = (imp.(:mem) ++ mod.mems) |> Enum.map(&check_mem/1)
    imported_globals = imp.(:global)
    globals = (imported_globals ++ Enum.map(mod.globals, & &1.type)) |> List.to_tuple()

    c = %{
      types: types,
      keys: keys,
      fkeys: func_keys,
      funcs: func_types,
      tables: tables,
      nmems: length(mems),
      memtypes: mems |> Enum.map(&elem(&1, 3)) |> List.to_tuple(),
      tags: tag_types,
      globals: globals,
      elems: mod.elems |> Enum.map(& &1.type) |> List.to_tuple(),
      ndatas: mod.data_count,
      refs: MapSet.new()
    }

    c = %{c | refs: collect_refs(mod)}

    # table initial values
    for {{_, rt}, init} <- Enum.zip(mod.tables, mod.table_inits) do
      cond do
        init != nil ->
          const_expr(%{c | globals: take_globals(c.globals, length(imported_globals))}, init, rt)

        not Types.nullable?(rt) ->
          err("type mismatch")

        true ->
          :ok
      end
    end

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
          {{_, _, addr}, rt} = elem(c.tables, t)
          unless Types.sub?(e.type, rt), do: err("type mismatch")
          const_expr(c, off, addr)

        _ ->
          :ok
      end

      for init <- e.inits, do: const_expr(c, init, e.type)
    end

    # data
    for d <- mod.datas do
      case d.mode do
        {:active, m, off} ->
          const_expr(c, off, mem(c, m))

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

  defp check_table({{min, max, _}, _} = table) do
    if max && min > max, do: err("size minimum must not be greater than maximum")
    table
  end

  defp check_mem({min, max, shared, addr} = type) do
    if shared and max == nil, do: err("shared memory must have maximum")
    limit = if addr == :i64, do: @max_pages64, else: @max_pages

    if min > limit or (max && max > limit),
      do: err("memory size must be at most 65536 pages (4GiB)")

    if max && min > max, do: err("size minimum must not be greater than maximum")
    type
  end

  defp func_type!(types, t) do
    case elem(types, t) do
      {p, r} = ft when is_list(p) and is_list(r) -> ft
      _ -> err("type mismatch")
    end
  end

  # the declared subtypes: a supertype is an earlier, non-final type that the subtype matches
  defp check_type_defs(keys) do
    for {group, i} = key <- keys do
      {_, supers, _} = elem(group, i)
      if length(supers) > 1, do: err("sub type")
      for {:rel, j} <- supers, j >= i, do: err("unknown type")

      %{supers: sups, comp: comp} = Types.definition(key)

      for {:ct, sk} <- sups do
        sd = Types.definition(sk)
        if sd.final, do: err("sub type")
        unless Types.comp_match?(comp, sd.comp), do: err("sub type")
      end
    end
  end

  defp collect_refs(mod) do
    from_exports = for %{kind: :func, index: i} <- mod.exports, do: i

    from_exprs = fn exprs ->
      for expr <- exprs, {:ref_func, i} <- expr, do: i
    end

    from_elems = from_exprs.(Enum.flat_map(mod.elems, & &1.inits))
    from_globals = from_exprs.(Enum.map(mod.globals, & &1.init))
    from_tables = from_exprs.(Enum.reject(mod.table_inits, &is_nil/1))
    MapSet.new(from_exports ++ from_elems ++ from_globals ++ from_tables)
  end

  # ── constant expressions ───────────────────────────────────

  @const_atoms [
    :i32_add,
    :i32_sub,
    :i32_mul,
    :i64_add,
    :i64_sub,
    :i64_mul,
    :ref_i31,
    :any_convert_extern,
    :extern_convert_any
  ]

  defp const_expr(c, expr, type) do
    for i <- expr, do: check_const(c, i)
    c = Map.put(c, :locals, {})

    frame = %{
      kind: :func,
      ins: [],
      outs: [type],
      height: 0,
      unreachable: false,
      label: 0,
      inits: MapSet.new()
    }

    s = %{
      vals: [],
      h: 0,
      ctrls: [frame],
      out: [],
      pc: 0,
      nlabel: 1,
      labels: %{},
      xl: 0,
      inits: MapSet.new()
    }

    s |> then(&walk(c, &1, expr)) |> check_end()
    :ok
  end

  defp check_const(_, i) when i in @const_atoms, do: :ok

  defp check_const(c, {:global_get, i}) do
    if i >= tuple_size(c.globals), do: err("unknown global")
    {_, mut} = elem(c.globals, i)
    if mut == :var, do: err("constant expression required")
  end

  defp check_const(_, {k, _})
       when k in [
              :i32_const,
              :i64_const,
              :f32_const,
              :f64_const,
              :simd_const,
              :ref_null,
              :ref_func,
              :struct_new,
              :struct_new_default,
              :array_new,
              :array_new_default
            ],
       do: :ok

  defp check_const(_, {:array_new_fixed, _, _}), do: :ok
  defp check_const(_, _), do: err("constant expression required")

  # ── function bodies ────────────────────────────────────────

  defp compile_func(c, params, locals, results, body) do
    c = Map.put(c, :locals, List.to_tuple(params ++ locals))
    label = 0

    inits = MapSet.new(0..(length(params) - 1)//1)

    frame = %{
      kind: :func,
      ins: [],
      outs: results,
      height: 0,
      unreachable: false,
      label: label,
      inits: inits
    }

    s = %{
      vals: [],
      h: 0,
      ctrls: [frame],
      out: [],
      pc: 0,
      nlabel: 1,
      labels: %{},
      xl: 0,
      inits: inits
    }

    s = walk(c, s, body)
    s = end_ctrl(s)
    s = emit(s, {:return, length(results)})
    labels = s.labels
    code = s.out |> Enum.reverse() |> Enum.map(&resolve(&1, labels)) |> List.to_tuple()

    %{
      nparams: length(params),
      zeros: Enum.map(locals, &zero/1) ++ List.duplicate(:null, s.xl),
      nres: length(results),
      code: code
    }
  end

  defp zero(:i32), do: 0
  defp zero(:i64), do: 0
  defp zero(:f32), do: 0.0
  defp zero(:f64), do: 0.0
  defp zero(:v128), do: 0
  defp zero(s) when s in [:i8, :i16], do: 0
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

  defp resolve({k, {:L, l}, a, d}, labels) when k in [:br_on_null, :br_on_non_null],
    do: {k, Map.fetch!(labels, l), a, d}

  defp resolve({k, {:L, l}, a, d, n, h}, labels) when k in [:br_on_cast, :br_on_cast_fail],
    do: {k, Map.fetch!(labels, l), a, d, n, h}

  defp resolve(other, _), do: other

  defp update_top(s, fun), do: %{s | ctrls: [fun.(hd(s.ctrls)) | tl(s.ctrls)]}
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
      Types.sub?(t, expect) -> {t, s}
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
    f = %{
      kind: kind,
      ins: ins,
      outs: outs,
      height: s.h,
      unreachable: false,
      label: label,
      inits: s.inits
    }

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
    s = %{s | ctrls: rest, inits: f.inits}
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
    func_type!(c.types, i)
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
      s = %{s | ctrls: [%{f | unreachable: false} | rest], inits: f.inits}
      s = push_all(s, ins)
      s |> then(&walk(c, &1, els)) |> end_ctrl()
    else
      unless length(ins) == length(outs) and
               Enum.all?(Enum.zip(ins, outs), fn {a, b} -> Types.sub?(a, b) end),
             do: err("type mismatch")

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
        lt = label_types(f)

        unless length(lt) == length(types) and
                 Enum.all?(Enum.zip(types, lt), fn {a, b} -> Types.sub?(a, b) end),
               do: err("type mismatch")

        # the stack is cut back to the height at the try_table, so the values are all there is
        drop = max(0, s.h - length(ins) - f.height)
        {tag, ref?, {:L, f.label, length(types), drop}}
      end

    s = pop_all(s, ins)
    {l, s} = new_label(s)
    {end_l, s} = new_label(s)
    s = emit(s, {:try_table, handlers, length(ins), {:L, end_l}})
    s = push_ctrl(s, :block, ins, outs, l)
    s = update_top(s, &Map.put(&1, :try, true))
    s = walk(c, s, body)
    s = define(s, end_l)
    s = emit(s, :try_end)
    end_ctrl(s)
  end

  # the legacy try: a try_table whose handlers sit after the body; each one first stores the
  # exception in a hidden local, for `rethrow`
  defp ins(c, s, {:try, bt, body, catches, delegate}) do
    {ins, outs} = blocktype(c, bt)

    for {t, _} <- catches, t != :all, t >= tuple_size(c.tags), do: err("unknown tag")

    if delegate != nil and delegate >= length(s.ctrls), do: err("unknown label")

    skip =
      if delegate, do: s.ctrls |> Enum.take(delegate) |> Enum.count(&Map.get(&1, :try)), else: 0

    s = pop_all(s, ins)
    {l, s} = new_label(s)
    {end_l, s} = new_label(s)
    clauses = if delegate, do: [{:delegate, nil}], else: catches
    {hlabels, s} = Enum.map_reduce(clauses, s, fn _, s -> new_label(s) end)

    params =
      for {t, _} <- clauses,
          do: if(t in [:all, :delegate], do: [], else: elem(elem(c.tags, t), 0))

    handlers =
      for {{t, _}, hl, ps} <- Enum.zip([clauses, hlabels, params]) do
        {if(t == :delegate, do: :all, else: t), true, {:L, hl, length(ps) + 1, 0}}
      end

    hidden = tuple_size(c.locals) + s.xl
    s = if catches == [], do: s, else: %{s | xl: s.xl + 1}

    s = emit(s, {:try_table, handlers, length(ins), {:L, end_l}})
    s = push_ctrl(s, :block, ins, outs, l)
    s = update_top(s, &Map.put(&1, :try, true))
    s = walk(c, s, body)
    s = define(s, end_l)
    s = emit(s, :try_end)

    cond do
      clauses == [] ->
        end_ctrl(s)

      delegate ->
        s = s |> check_end() |> emit({:jump, {:L, l}}) |> define(hd(hlabels))
        s = emit(s, {:throw_ref_skip, skip})
        s = push_all(s, outs)
        end_ctrl(s)

      true ->
        s = s |> check_end() |> emit({:jump, {:L, l}})
        last = length(clauses) - 1

        clauses
        |> Enum.zip(hlabels)
        |> Enum.zip(params)
        |> Enum.with_index()
        |> Enum.reduce(s, fn {{{{_, hbody}, hl}, ps}, i}, s ->
          s = define(s, hl)

          s = %{s | inits: hd(s.ctrls).inits}

          s =
            update_top(
              s,
              &(&1
                |> Map.put(:try, false)
                |> Map.put(:unreachable, false)
                |> Map.put(:catch_local, hidden))
            )

          s = s |> push_all(ps) |> emit({:lset, hidden})
          s = walk(c, s, hbody)

          if i == last do
            end_ctrl(s)
          else
            s |> check_end() |> emit({:jump, {:L, l}})
          end
        end)
    end
  end

  defp ins(_, s, {:rethrow, depth}) do
    case Map.get(frame(s, depth), :catch_local) do
      nil -> err("invalid rethrow label")
      hidden -> s |> emit({:lget, hidden}) |> emit(:throw_ref) |> unreachable()
    end
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
    {{_, _, addr}, rt} = elem(c.tables, tbl)
    unless Types.sub?(rt, :funcref), do: err("type mismatch")
    if ti >= tuple_size(c.types), do: err("unknown type")
    {params, results} = func_type!(c.types, ti)
    check_tail(s, results)
    {_, s} = pop(s, addr)

    s
    |> pop_all(params)
    |> emit({:return_call_indirect, ti, tbl, length(params)})
    |> unreachable()
  end

  defp ins(c, s, {:call_indirect, ti, tbl}) do
    if tbl >= tuple_size(c.tables), do: err("unknown table")
    {{_, _, addr}, rt} = elem(c.tables, tbl)
    unless Types.sub?(rt, :funcref), do: err("type mismatch")
    if ti >= tuple_size(c.types), do: err("unknown type")
    {params, results} = func_type!(c.types, ti)
    {_, s} = pop(s, addr)
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

    if (t1 != :unknown and Types.ref_type?(t1)) or (t2 != :unknown and Types.ref_type?(t2)),
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
    t = local(c, i)

    unless Types.defaultable?(t) or MapSet.member?(s.inits, i), do: err("uninitialized local")
    s |> push(t) |> emit({:lget, i})
  end

  defp ins(c, s, {:local_set, i}) do
    {_, s} = pop(s, local(c, i))
    emit(%{s | inits: MapSet.put(s.inits, i)}, {:lset, i})
  end

  defp ins(c, s, {:local_tee, i}) do
    t = local(c, i)
    {_, s} = pop(s, t)
    s |> push(t) |> emit({:ltee, i}) |> then(&%{&1 | inits: MapSet.put(&1.inits, i)})
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
    {_, s} = pop(s, table_addr(c, t))
    s |> push(rt) |> emit({:table_get, t})
  end

  defp ins(c, s, {:table_set, t}) do
    rt = table_type(c, t)
    {_, s} = pop(s, rt)
    {_, s} = pop(s, table_addr(c, t))
    emit(s, {:table_set, t})
  end

  defp ins(c, s, {:table_size, t}) do
    s |> push(table_addr(c, t)) |> emit({:table_size, t})
  end

  defp ins(c, s, {:table_grow, t}) do
    rt = table_type(c, t)
    addr = table_addr(c, t)
    {_, s} = pop(s, addr)
    {_, s} = pop(s, rt)
    s |> push(addr) |> emit({:table_grow, t})
  end

  defp ins(c, s, {:table_fill, t}) do
    rt = table_type(c, t)
    addr = table_addr(c, t)
    s = pop_all(s, [addr, rt, addr])
    emit(s, {:table_fill, t})
  end

  defp ins(c, s, {:table_copy, d, src}) do
    dt = table_type(c, d)
    unless Types.sub?(table_type(c, src), dt), do: err("type mismatch")
    da = table_addr(c, d)
    sa = table_addr(c, src)
    n = if da == :i64 and sa == :i64, do: :i64, else: :i32
    s |> pop_all([da, sa, n]) |> emit({:table_copy, d, src})
  end

  defp ins(c, s, {:table_init, e, t}) do
    rt = table_type(c, t)
    if e >= tuple_size(c.elems), do: err("unknown elem segment")
    unless Types.sub?(elem(c.elems, e), rt), do: err("type mismatch")
    s |> pop_all([table_addr(c, t), :i32, :i32]) |> emit({:table_init, e, t})
  end

  defp ins(c, s, {:elem_drop, e}) do
    if e >= tuple_size(c.elems), do: err("unknown elem segment")
    emit(s, {:elem_drop, e})
  end

  defp ins(c, s, {:load, kind, align, offset, m}) do
    a = mem(c, m, offset)
    {t, natural} = Map.fetch!(@loads, kind)
    if align > natural, do: err("alignment must not be larger than natural")
    {_, s} = pop(s, a)
    s |> push(t) |> emit({:load, kind, offset, m})
  end

  defp ins(c, s, {:store, kind, align, offset, m}) do
    a = mem(c, m, offset)
    {t, natural} = Map.fetch!(@stores, kind)
    if align > natural, do: err("alignment must not be larger than natural")
    s = pop_all(s, [a, t])
    emit(s, {:store, kind, offset, m})
  end

  defp ins(c, s, {:memory_size, m}) do
    s |> push(mem(c, m)) |> emit({:memory_size, m})
  end

  defp ins(c, s, {:memory_grow, m}) do
    a = mem(c, m)
    {_, s} = pop(s, a)
    s |> push(a) |> emit({:memory_grow, m})
  end

  defp ins(c, s, {:memory_init, d, m}) do
    a = mem(c, m)
    data_idx(c, d)
    s |> pop_all([a, :i32, :i32]) |> emit({:memory_init, d, m})
  end

  defp ins(c, s, {:data_drop, d}) do
    data_idx(c, d)
    emit(s, {:data_drop, d})
  end

  defp ins(c, s, {:memory_copy, d, src}) do
    da = mem(c, d)
    sa = mem(c, src)
    n = if da == :i64 and sa == :i64, do: :i64, else: :i32
    s |> pop_all([da, sa, n]) |> emit({:memory_copy, d, src})
  end

  defp ins(c, s, {:memory_fill, m}) do
    a = mem(c, m)
    s |> pop_all([a, :i32, a]) |> emit({:memory_fill, m})
  end

  defp ins(_, s, {:atomic_fence}), do: emit(s, {:atomic_fence})

  defp ins(c, s, {:atomic, sub, op, width, align, offset, m}) do
    a = mem(c, m, offset)
    {params, result} = Map.fetch!(@atomic, sub)
    natural = %{1 => 0, 2 => 1, 4 => 2, 8 => 3}[width]
    if align != natural, do: err("atomic alignment must be natural")
    s = pop_all(s, [a | tl(params)])
    s = if result, do: push(s, result), else: s
    emit(s, {:atomic, op, width, offset, m, length(params)})
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
    a = mem(c, m, offset)
    {params, result, kind} = Map.fetch!(@simd, {shape, op})

    {natural, lanes} =
      case kind do
        {:mem, a} -> {a, nil}
        {:mem_lane, a, n} -> {a, n}
      end

    if align > natural, do: err("alignment must not be larger than natural")
    if lanes != nil and lane >= lanes, do: err("invalid lane index")
    s = pop_all(s, [a | tl(params)])
    s = if result, do: push(s, result), else: s
    emit(s, {:simd_mem, op, offset, m, lane})
  end

  defp ins(_, s, {:i32_const, v}), do: s |> push(:i32) |> emit({:const, v})
  defp ins(_, s, {:i64_const, v}), do: s |> push(:i64) |> emit({:const, v})
  defp ins(_, s, {:f32_const, v}), do: s |> push(:f32) |> emit({:const, v})
  defp ins(_, s, {:f64_const, v}), do: s |> push(:f64) |> emit({:const, v})
  defp ins(_, s, {:ref_null, ht}), do: s |> push(Types.ref(true, ht)) |> emit({:const, :null})

  defp ins(_, s, :ref_is_null) do
    {t, s} = pop(s)
    unless t == :unknown or Types.ref_type?(t), do: err("type mismatch")
    s |> push(:i32) |> emit(:ref_is_null)
  end

  defp ins(c, s, {:ref_func, i}) do
    if i >= tuple_size(c.funcs), do: err("unknown function")
    unless MapSet.member?(c.refs, i), do: err("undeclared function reference")
    s |> push(Types.ref(false, {:ct, elem(c.fkeys, i)})) |> emit({:ref_func, i})
  end

  # ── function references ────────────────────────────────────

  defp ins(c, s, {:call_ref, t}) do
    {params, results} = ref_func_type(c, t)
    {_, s} = pop(s, Types.ref(true, {:ct, elem(c.keys, t)}))
    s |> pop_all(params) |> push_all(results) |> emit({:call_ref, length(params)})
  end

  defp ins(c, s, {:return_call_ref, t}) do
    {params, results} = ref_func_type(c, t)
    check_tail(s, results)
    {_, s} = pop(s, Types.ref(true, {:ct, elem(c.keys, t)}))
    s |> pop_all(params) |> emit({:return_call_ref, length(params)}) |> unreachable()
  end

  defp ins(_, s, :ref_as_non_null) do
    {t, s} = pop_ref(s)
    s |> push(non_null(t)) |> emit(:ref_as_non_null)
  end

  defp ins(_, s, {:br_on_null, depth}) do
    {t, s} = pop_ref(s)
    f = frame(s, depth)
    types = label_types(f)
    drop = max(0, s.h - f.height - length(types))
    s = s |> pop_all(types) |> push_all(types)
    s |> push(non_null(t)) |> emit({:br_on_null, {:L, f.label}, length(types), drop})
  end

  defp ins(_, s, {:br_on_non_null, depth}) do
    f = frame(s, depth)
    types = label_types(f)
    if types == [], do: err("type mismatch")
    {t, s} = pop_ref(s)
    drop = max(0, s.h + 1 - f.height - length(types))
    prefix = Enum.drop(types, -1)
    unless Types.sub?(non_null(t), List.last(types)) or t == :unknown, do: err("type mismatch")
    s = s |> pop_all(prefix) |> push_all(prefix)
    emit(s, {:br_on_non_null, {:L, f.label}, length(types), drop})
  end

  defp ins(_, s, :ref_eq) do
    eq = {:ref, true, :eq}
    s |> pop_all([eq, eq]) |> push(:i32) |> emit(:ref_eq)
  end

  # ── structs ────────────────────────────────────────────────

  defp ins(c, s, {:struct_new, t}) do
    fields = struct_fields(c, t)
    s = pop_all(s, Enum.map(fields, fn {st, _} -> unpack(st) end))
    s |> push(type_ref(c, t, false)) |> emit({:struct_new, elem(c.keys, t), packs(fields)})
  end

  defp ins(c, s, {:struct_new_default, t}) do
    fields = struct_fields(c, t)

    for {st, _} <- fields,
        not packed?(st) and not Types.defaultable?(st),
        do: err("type mismatch")

    zeros = fields |> Enum.map(fn {st, _} -> zero(st) end) |> List.to_tuple()
    s |> push(type_ref(c, t, false)) |> emit({:struct_new_default, elem(c.keys, t), zeros})
  end

  defp ins(c, s, {kind, t, f}) when kind in [:struct_get, :struct_get_s, :struct_get_u] do
    {st, _} = struct_field(c, t, f)
    if kind == :struct_get == packed?(st), do: err("type mismatch")
    {_, s} = pop(s, type_ref(c, t, true))
    s |> push(unpack(st)) |> emit({:struct_get, f, extension(kind, st)})
  end

  defp ins(c, s, {:struct_set, t, f}) do
    {st, mut} = struct_field(c, t, f)
    if mut != :var, do: err("field is immutable")
    s = pop_all(s, [type_ref(c, t, true), unpack(st)])
    emit(s, {:struct_set, f, pack(st)})
  end

  # ── arrays ─────────────────────────────────────────────────

  defp ins(c, s, {:array_new, t}) do
    {st, _} = array_field(c, t)
    s = pop_all(s, [unpack(st), :i32])
    s |> push(type_ref(c, t, false)) |> emit({:array_new, elem(c.keys, t), pack(st)})
  end

  defp ins(c, s, {:array_new_default, t}) do
    {st, _} = array_field(c, t)
    if not packed?(st) and not Types.defaultable?(st), do: err("type mismatch")
    {_, s} = pop(s, :i32)
    s |> push(type_ref(c, t, false)) |> emit({:array_new_default, elem(c.keys, t), zero(st)})
  end

  defp ins(c, s, {:array_new_fixed, t, n}) do
    {st, _} = array_field(c, t)
    s = pop_all(s, List.duplicate(unpack(st), n))
    s |> push(type_ref(c, t, false)) |> emit({:array_new_fixed, elem(c.keys, t), pack(st), n})
  end

  defp ins(c, s, {:array_new_data, t, d}) do
    {st, _} = array_field(c, t)
    unless numeric_storage?(st), do: err("array type is not numeric or vector")
    data_idx(c, d)
    s = pop_all(s, [:i32, :i32])
    s |> push(type_ref(c, t, false)) |> emit({:array_new_data, elem(c.keys, t), st, d})
  end

  defp ins(c, s, {:array_new_elem, t, e}) do
    {st, _} = array_field(c, t)
    elem_seg(c, e, st)
    s = pop_all(s, [:i32, :i32])
    s |> push(type_ref(c, t, false)) |> emit({:array_new_elem, elem(c.keys, t), e})
  end

  defp ins(c, s, {kind, t}) when kind in [:array_get, :array_get_s, :array_get_u] do
    {st, _} = array_field(c, t)
    if kind == :array_get == packed?(st), do: err("type mismatch")
    s = pop_all(s, [type_ref(c, t, true), :i32])
    s |> push(unpack(st)) |> emit({:array_get, extension(kind, st)})
  end

  defp ins(c, s, {:array_set, t}) do
    {st, mut} = array_field(c, t)
    if mut != :var, do: err("array is immutable")
    s = pop_all(s, [type_ref(c, t, true), :i32, unpack(st)])
    emit(s, {:array_set, pack(st)})
  end

  defp ins(_, s, :array_len) do
    {_, s} = pop(s, {:ref, true, :array})
    s |> push(:i32) |> emit(:array_len)
  end

  defp ins(c, s, {:array_fill, t}) do
    {st, mut} = array_field(c, t)
    if mut != :var, do: err("array is immutable")
    s = pop_all(s, [type_ref(c, t, true), :i32, unpack(st), :i32])
    emit(s, {:array_fill, pack(st)})
  end

  defp ins(c, s, {:array_copy, t1, t2}) do
    {st1, mut} = array_field(c, t1)
    {st2, _} = array_field(c, t2)
    if mut != :var, do: err("array is immutable")

    unless Types.sub?(unpack(st2), unpack(st1)) and packed?(st1) == packed?(st2) and
             (not packed?(st1) or st1 == st2),
           do: err("array types do not match")

    s = pop_all(s, [type_ref(c, t1, true), :i32, type_ref(c, t2, true), :i32, :i32])
    emit(s, {:array_copy, pack(st1)})
  end

  defp ins(c, s, {:array_init_data, t, d}) do
    {st, mut} = array_field(c, t)
    if mut != :var, do: err("array is immutable")
    unless numeric_storage?(st), do: err("array type is not numeric or vector")
    data_idx(c, d)
    s = pop_all(s, [type_ref(c, t, true), :i32, :i32, :i32])
    emit(s, {:array_init_data, st, d})
  end

  defp ins(c, s, {:array_init_elem, t, e}) do
    {st, mut} = array_field(c, t)
    if mut != :var, do: err("array is immutable")
    elem_seg(c, e, st)
    s = pop_all(s, [type_ref(c, t, true), :i32, :i32, :i32])
    emit(s, {:array_init_elem, e})
  end

  # ── i31, casts, conversions ────────────────────────────────

  defp ins(_, s, :ref_i31) do
    {_, s} = pop(s, :i32)
    s |> push({:ref, false, :i31}) |> emit(:ref_i31)
  end

  defp ins(_, s, kind) when kind in [:i31_get_s, :i31_get_u] do
    {_, s} = pop(s, {:ref, true, :i31})
    s |> push(:i32) |> emit(kind)
  end

  defp ins(_, s, {:ref_test, nullable, ht}) do
    {_, s} = pop(s, Types.ref(true, Types.top(ht)))
    s |> push(:i32) |> emit({:ref_test, nullable, ht})
  end

  defp ins(_, s, {:ref_cast, nullable, ht}) do
    {_, s} = pop(s, Types.ref(true, Types.top(ht)))
    s |> push(Types.ref(nullable, ht)) |> emit({:ref_cast, nullable, ht})
  end

  defp ins(_, s, {kind, depth, {n1, h1}, {n2, h2}})
       when kind in [:br_on_cast, :br_on_cast_fail] do
    rt1 = Types.ref(n1, h1)
    rt2 = Types.ref(n2, h2)
    unless Types.sub?(rt2, rt1), do: err("type mismatch")
    diff = Types.ref(n1 and not n2, h1)
    f = frame(s, depth)
    types = label_types(f)
    if types == [], do: err("type mismatch")
    carried = if kind == :br_on_cast, do: rt2, else: diff
    unless Types.sub?(carried, List.last(types)), do: err("type mismatch")
    {_, s} = pop(s, rt1)
    drop = max(0, s.h + 1 - f.height - length(types))
    prefix = Enum.drop(types, -1)
    s = s |> pop_all(prefix) |> push_all(prefix)
    s = push(s, if(kind == :br_on_cast, do: diff, else: rt2))
    emit(s, {kind, {:L, f.label}, length(types), drop, n2, h2})
  end

  defp ins(_, s, :any_convert_extern) do
    {t, s} = pop(s, :externref)
    s |> push(Types.ref(nullable_or(t), :any)) |> emit(:any_convert_extern)
  end

  defp ins(_, s, :extern_convert_any) do
    {t, s} = pop(s, {:ref, true, :any})
    s |> push(Types.ref(nullable_or(t), :extern)) |> emit(:extern_convert_any)
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

  defp table_addr(c, t) do
    if t >= tuple_size(c.tables), do: err("unknown table")
    {{_, _, addr}, _} = elem(c.tables, t)
    addr
  end

  # ── helpers for references and aggregates ─────────────────

  defp ref_func_type(c, t) do
    if t >= tuple_size(c.types), do: err("unknown type")
    func_type!(c.types, t)
  end

  defp pop_ref(s) do
    {t, s} = pop(s)
    unless t == :unknown or Types.ref_type?(t), do: err("type mismatch")
    {t, s}
  end

  defp non_null(:unknown), do: :unknown
  defp non_null(t), do: Types.with_null(t, false)

  defp nullable_or(:unknown), do: true
  defp nullable_or(t), do: Types.nullable?(t)

  defp type_ref(c, t, nullable), do: Types.ref(nullable, {:ct, elem(c.keys, t)})

  defp struct_fields(c, t) do
    if t >= tuple_size(c.types), do: err("unknown type")

    case elem(c.types, t) do
      {:struct, fields} -> fields
      _ -> err("type mismatch")
    end
  end

  defp struct_field(c, t, f) do
    fields = struct_fields(c, t)
    if f >= length(fields), do: err("unknown field")
    Enum.at(fields, f)
  end

  defp array_field(c, t) do
    if t >= tuple_size(c.types), do: err("unknown type")

    case elem(c.types, t) do
      {:array, field} -> field
      _ -> err("type mismatch")
    end
  end

  defp packed?(st), do: st in [:i8, :i16]
  defp unpack(st) when st in [:i8, :i16], do: :i32
  defp unpack(st), do: st
  defp pack(st) when st in [:i8, :i16], do: st
  defp pack(_), do: nil
  defp packs(fields), do: fields |> Enum.map(fn {st, _} -> pack(st) end) |> List.to_tuple()
  defp numeric_storage?(st), do: st in [:i8, :i16, :i32, :i64, :f32, :f64, :v128]

  defp extension(:struct_get, _), do: nil
  defp extension(:array_get, _), do: nil
  defp extension(kind, st) when kind in [:struct_get_s, :array_get_s], do: {:s, bits(st)}
  defp extension(kind, st) when kind in [:struct_get_u, :array_get_u], do: {:u, bits(st)}
  defp bits(:i8), do: 8
  defp bits(:i16), do: 16

  # an element segment whose type matches the element type of an array
  defp elem_seg(c, e, st) do
    if e >= tuple_size(c.elems), do: err("unknown elem segment")
    unless Types.sub?(elem(c.elems, e), st), do: err("type mismatch")
  end

  # the address type of memory `m`
  defp mem(c, m) do
    if m >= c.nmems, do: err("unknown memory")
    elem(c.memtypes, m)
  end

  defp mem(c, m, offset) do
    a = mem(c, m)
    if a == :i32 and offset >= 4_294_967_296, do: err("offset out of range")
    a
  end

  defp data_idx(c, d) do
    if c.ndatas == nil, do: err("data count section required")
    if d >= c.ndatas, do: err("unknown data segment")
  end
end
