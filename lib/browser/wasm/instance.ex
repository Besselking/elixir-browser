defmodule Browser.Wasm.Instance do
  @moduledoc "Makes an instance of a validated module: links the imports, creates the state, runs segments and the start function."

  alias Browser.Wasm.{Error, Func, Global, Interp, Memory, Table, Tag}

  defp link_error(msg), do: Error.fail(:link, msg)

  @doc """
  Instantiates `mod`. `resolve` is `(module_name, field, import_desc) -> value | nil` and gives the
  function, table, memory or global for each import. Returns `%{id: id, exports: [{name, kind, value}]}`.
  Raises `Browser.Wasm.Error` with kind `:link` or `:trap`.
  """
  def instantiate(mod, resolve) do
    id = make_ref()
    types = List.to_tuple(mod.types)

    imported =
      for imp <- mod.imports do
        desc =
          case imp.desc do
            {:func, t} -> {:func, elem(types, t)}
            {:tag, t} -> {:tag, elem(types, t)}
            other -> other
          end

        value = resolve.(imp.module, imp.name, desc)
        check_import(imp, value, types)
        {elem(imp.desc, 0), value}
      end

    imp_of = fn kind -> for {^kind, v} <- imported, do: v end
    imported_funcs = imp_of.(:func)

    defined_funcs =
      mod.funcs
      |> Enum.with_index()
      |> Enum.map(fn {t, i} ->
        %Func{id: make_ref(), type: elem(types, t), impl: {:wasm, id, i}}
      end)

    funcs = List.to_tuple(imported_funcs ++ defined_funcs)

    tables =
      (imp_of.(:table) ++
         for({{min, max, addr}, type} <- mod.tables, do: Table.new(type, min, max, :null, addr)))
      |> List.to_tuple()

    mems =
      (imp_of.(:mem) ++
         for({min, max, shared, addr} <- mod.mems, do: Memory.new(min, max, shared, addr)))
      |> List.to_tuple()

    globals =
      Enum.reduce(mod.globals, List.to_tuple(imp_of.(:global)), fn g, acc ->
        {t, m} = g.type
        value = eval(g.init, funcs, acc)
        Tuple.insert_at(acc, tuple_size(acc), Global.new(t, m == :var, value))
      end)

    tags =
      (imp_of.(:tag) ++ for(t <- mod.tags, do: Tag.new(elem(types, t))))
      |> List.to_tuple()

    exports =
      for e <- mod.exports do
        value =
          case e.kind do
            :func -> elem(funcs, e.index)
            :table -> elem(tables, e.index)
            :mem -> elem(mems, e.index)
            :global -> elem(globals, e.index)
            :tag -> elem(tags, e.index)
          end

        {e.name, e.kind, value}
      end

    inst = %{
      id: id,
      types: types,
      funcs: funcs,
      tables: tables,
      mems: mems,
      globals: globals,
      tags: tags,
      tr: false,
      code: List.to_tuple(mod.compiled)
    }

    Process.put({:wasm_instance, id}, inst)

    elems = for e <- mod.elems, do: Enum.map(e.inits, &eval(&1, funcs, globals))
    datas = for d <- mod.datas, do: d.bytes
    Process.put({:wasm_segments, id}, %{elems: List.to_tuple(elems), datas: List.to_tuple(datas)})

    # active segments, in order; each one is dropped afterwards
    mod.elems
    |> Enum.with_index()
    |> Enum.each(fn {e, i} ->
      case e.mode do
        {:active, t, off} ->
          [o] = [eval(off, funcs, globals)]
          Table.init(elem(tables, t), o, Enum.at(elems, i))
          drop(id, :elems, i)

        :declarative ->
          drop(id, :elems, i)

        :passive ->
          :ok
      end
    end)

    mod.datas
    |> Enum.with_index()
    |> Enum.each(fn {d, i} ->
      case d.mode do
        {:active, m, off} ->
          o = eval(off, funcs, globals)
          mem = elem(mems, m)

          if o + byte_size(d.bytes) > Memory.size(mem) * Memory.page_size(),
            do: Error.fail(:trap, "out of bounds memory access")

          if d.bytes != <<>>, do: Memory.write(mem, o, d.bytes)
          drop(id, :datas, i)

        :passive ->
          :ok
      end
    end)

    if mod.start, do: Interp.invoke(elem(funcs, mod.start), [], 0)

    %{id: id, exports: exports, memories: mems, tables: tables, globals: globals}
  end

  defp drop(id, key, i) do
    segs = Interp.segments(id)
    empty = if key == :elems, do: [], else: <<>>
    Process.put({:wasm_segments, id}, Map.update!(segs, key, &put_elem(&1, i, empty)))
  end

  defp eval(expr, funcs, globals) do
    [v] =
      Enum.reduce(expr, [], fn
        {c, v}, st when c in [:i32_const, :i64_const, :f32_const, :f64_const] ->
          [v | st]

        {:simd_const, v}, st ->
          [v | st]

        {:ref_null, _}, st ->
          [:null | st]

        {:ref_func, i}, st ->
          [elem(funcs, i) | st]

        {:global_get, i}, st ->
          [Global.get(elem(globals, i)) | st]

        :i32_add, [b, a | st] ->
          [Bitwise.band(a + b, 0xFFFFFFFF) | st]

        :i32_sub, [b, a | st] ->
          [Bitwise.band(a - b, 0xFFFFFFFF) | st]

        :i32_mul, [b, a | st] ->
          [Bitwise.band(a * b, 0xFFFFFFFF) | st]

        :i64_add, [b, a | st] ->
          [Bitwise.band(a + b, 0xFFFFFFFFFFFFFFFF) | st]

        :i64_sub, [b, a | st] ->
          [Bitwise.band(a - b, 0xFFFFFFFFFFFFFFFF) | st]

        :i64_mul, [b, a | st] ->
          [Bitwise.band(a * b, 0xFFFFFFFFFFFFFFFF) | st]
      end)

    v
  end

  # ── import checks ──────────────────────────────────────────

  defp check_import(imp, nil, _), do: link_error("unknown import #{imp.module}.#{imp.name}")

  defp check_import(%{desc: {:func, t}}, %Func{} = f, types) do
    if f.type != elem(types, t), do: link_error("incompatible import type")
  end

  defp check_import(%{desc: {:table, {{min, max, addr}, type}}}, %Table{} = t, _) do
    if t.type != type or t.addr != addr or Table.size(t) < min or limit_mismatch(max, t.max),
      do: link_error("incompatible import type")
  end

  defp check_import(%{desc: {:mem, {min, max, shared, addr}}}, %Memory{} = m, _) do
    if Memory.size(m) < min or limit_mismatch(max, m.max) or m.shared != shared or
         m.addr != addr,
       do: link_error("incompatible import type")
  end

  defp check_import(%{desc: {:tag, t}}, %Tag{} = tag, types) do
    if tag.type != elem(types, t), do: link_error("incompatible import type")
  end

  defp check_import(%{desc: {:global, {type, mut}}}, %Global{} = g, _) do
    if g.type != type or (g.mut and mut == :const) or (not g.mut and mut == :var),
      do: link_error("incompatible import type")
  end

  defp check_import(_, _, _), do: link_error("incompatible import type")

  defp limit_mismatch(nil, _), do: false
  defp limit_mismatch(_, nil), do: true
  defp limit_mismatch(want, have), do: have > want
end
