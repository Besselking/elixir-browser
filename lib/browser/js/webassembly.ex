defmodule Browser.JS.WebAssembly do
  @moduledoc """
  The JavaScript `WebAssembly` object. The classes (`Module`, `Instance`, `Memory`, `Table`,
  `Global`, the error types and the promise functions) are written in JavaScript (`@source`)
  on top of the natives in this module, which convert values between JavaScript and the engine
  (`Browser.Wasm`) and keep a memory and its `ArrayBuffer` in step.

  A memory's bytes live in the engine as pages. `memory.buffer` is an `ArrayBuffer` that holds a
  copy; the two are synchronised whenever control passes between JavaScript and WebAssembly
  code (a call of an export, a call of an import), because nothing else can see the difference.
  """

  import Bitwise
  import Browser.JS.Interp, except: [get: 2, put: 3, deref: 1]
  alias Browser.JS.{Interp, Parser, TypedArrays}
  alias Browser.Wasm
  alias Browser.Wasm.{Error, Func, Global, Memory, Num, Table}

  defp arg(args, i), do: Enum.at(args, i, :undefined)
  defp heap(id), do: Interp.deref(id)

  @doc """
  Declares `WebAssembly` in the global scope. Building it takes a few milliseconds, so the
  global is an accessor that does it on the first use and then turns itself into a value.
  """
  def install(scope) do
    getter = native("get WebAssembly", fn _, _ -> build(scope) end)

    {:ok, {:program, [{:expr, expr}]}} =
      Parser.parse("""
      (function (get) {
        Object.defineProperty(globalThis, 'WebAssembly', {
          get: get,
          set: function (v) { Object.defineProperty(globalThis, 'WebAssembly', { value: v, writable: true, configurable: true }); },
          configurable: true
        });
      })
      """)

    call(Interp.ev(expr, scope), :undefined, [getter])
    :ok
  end

  defp build(scope) do
    w = new_object()

    for {name, arity, fun} <- natives() do
      {:obj, id} = f = native(name, fun)
      store(id, Map.put(heap(id), :arity, arity * 1.0))
      put_hidden(w, name, f)
    end

    case program() do
      {:ok, ast} -> call(Interp.ev(ast, scope), :undefined, [w])
      {:error, msg} -> throw({:syntax, "webassembly: " <> msg})
    end
  end

  defp program do
    case :persistent_term.get({__MODULE__, :ast}, nil) do
      nil ->
        with {:ok, {:program, [{:expr, expr}]}} <- Parser.parse("(" <> source() <> ")") do
          :persistent_term.put({__MODULE__, :ast}, {:ok, expr})
          {:ok, expr}
        end

      cached ->
        cached
    end
  end

  # ── errors ─────────────────────────────────────────────────

  defp throw_js(kind, msg) do
    ctor = Process.get({:wasm_error, kind})
    throw({:js_error, construct(ctor, [msg])})
  end

  defp raise_js(%Error{kind: :compile, message: m}), do: throw_js("CompileError", m)
  defp raise_js(%Error{kind: :link, message: m}), do: throw_js("LinkError", m)

  defp raise_js(%Error{kind: :trap, message: "call stack exhausted"}),
    do: throw_error("RangeError", "Maximum call stack size exceeded")

  defp raise_js(%Error{kind: :trap, message: m}), do: throw_js("RuntimeError", m)

  defp guard(fun) do
    fun.()
  rescue
    e in Error -> raise_js(e)
  end

  # ── values ─────────────────────────────────────────────────

  defp to_wasm(:i32, v) do
    case to_num(v) do
      n when is_number(n) -> trunc(n) &&& 0xFFFFFFFF
      _ -> 0
    end
  end

  defp to_wasm(:i64, v) do
    {:bigint, n} = Browser.JS.BigInt.to_bigint(v)
    n &&& 0xFFFFFFFFFFFFFFFF
  end

  defp to_wasm(:f32, v) do
    case to_num(v) do
      :nan -> {:nan, 0x7FC00000}
      n when is_number(n) -> Num.round32(n * 1.0)
      inf -> inf
    end
  end

  defp to_wasm(:f64, v) do
    case to_num(v) do
      :nan -> {:nan, 0x7FF8000000000000}
      n when is_number(n) -> n * 1.0
      inf -> inf
    end
  end

  defp to_wasm(:externref, v), do: v
  defp to_wasm(:funcref, :null), do: :null

  defp to_wasm(:funcref, {:obj, id}) do
    case Process.get({:wasm_fn_of, id}) do
      %Func{} = f -> f
      _ -> throw_error("TypeError", "the value is not null or an exported WebAssembly function")
    end
  end

  defp to_wasm(:funcref, _),
    do: throw_error("TypeError", "the value is not null or an exported WebAssembly function")

  defp to_js(:i32, v), do: if(v >= 0x80000000, do: v - 0x100000000, else: v) * 1.0

  defp to_js(:i64, v),
    do: {:bigint, if(v >= 0x8000000000000000, do: v - 0x10000000000000000, else: v)}

  defp to_js(t, {:nan, _}) when t in [:f32, :f64], do: :nan
  defp to_js(t, v) when t in [:f32, :f64], do: v
  defp to_js(:funcref, :null), do: :null
  defp to_js(:funcref, %Func{} = f), do: wrap_func(f)
  defp to_js(:externref, v), do: v

  defp results_to_js([], _), do: :undefined
  defp results_to_js([t], [v]), do: to_js(t, v)
  defp results_to_js(ts, vs), do: new_array(Enum.zip_with(ts, vs, &to_js/2))

  # the value argument of a table call; a missing one is the default of the element type
  defp table_value(t, args, i) do
    if length(args) > i do
      to_wasm(t.type, arg(args, i))
    else
      if t.type == :externref, do: :undefined, else: :null
    end
  end

  defp zero(:i32), do: 0
  defp zero(:i64), do: 0
  defp zero(t) when t in [:f32, :f64], do: 0.0
  defp zero(_), do: :null

  # ── functions ──────────────────────────────────────────────

  defp wrap_func(%Func{} = f) do
    case Process.get({:wasm_fobj, f.id}) do
      nil ->
        {:obj, id} = obj = native(func_name(f), fn _this, args -> call_export(f, args) end)
        store(id, Map.put(heap(id), :arity, length(elem(f.type, 0)) * 1.0))
        Process.put({:wasm_fobj, f.id}, obj)
        Process.put({:wasm_fn_of, id}, f)
        obj

      obj ->
        obj
    end
  end

  defp func_name(%Func{impl: {:wasm, iid, _}} = f) do
    inst = Wasm.Interp.instance(iid)
    idx = inst.funcs |> Tuple.to_list() |> Enum.find_index(&(&1.id == f.id))
    Integer.to_string(idx || 0)
  end

  defp func_name(_), do: "0"

  defp call_export(%Func{type: {params, results}} = f, args) do
    vals =
      params |> Enum.with_index() |> Enum.map(fn {t, i} -> to_wasm(t, arg(args, i)) end)

    pull_all()

    try do
      out = Wasm.invoke(f, vals)
      push_all()
      results_to_js(results, out)
    rescue
      e in Error ->
        push_all()
        raise_js(e)
    catch
      kind, val ->
        push_all()
        :erlang.raise(kind, val, __STACKTRACE__)
    end
  end

  defp host_func(type, jsfn) do
    {params, results} = type

    Func.host(type, fn args ->
      push_all()

      try do
        js_args = Enum.zip_with(params, args, &to_js/2)
        r = call(jsfn, :undefined, js_args)
        host_results(results, r)
      after
        pull_all()
      end
    end)
  end

  defp host_results([], _), do: []
  defp host_results([t], r), do: [to_wasm(t, r)]

  defp host_results(ts, r) do
    vals = iterate(r)

    if length(vals) != length(ts),
      do: throw_error("TypeError", "multi-return length mismatch")

    Enum.zip_with(ts, vals, &to_wasm/2)
  end

  # ── memory buffers ─────────────────────────────────────────

  defp live, do: Process.get(:wasm_live, [])

  defp pull_all, do: Enum.each(live(), &pull/1)
  defp push_all, do: Enum.each(live(), &push/1)

  defp pull(mem) do
    case Process.get({:wasm_buf, mem.id}) do
      {buf, _pages, synced} ->
        js = TypedArrays.buffer_bytes(buf)

        if not :erts_debug.same(js, synced) and js != synced do
          Memory.load_binary(mem, js)
        end

        Process.put({:wasm_buf, mem.id}, {buf, Memory.pages(mem), js})

      nil ->
        :ok
    end
  end

  defp push(mem) do
    case Process.get({:wasm_buf, mem.id}) do
      {buf, pages, synced} ->
        now = Memory.pages(mem)

        unless :erts_debug.same(now, pages) do
          bytes = Memory.to_binary(mem)

          if byte_size(bytes) != byte_size(synced) do
            drop_buffer(mem, buf)
          else
            TypedArrays.set_buffer_bytes(buf, bytes)
            Process.put({:wasm_buf, mem.id}, {buf, now, bytes})
          end
        end

      nil ->
        :ok
    end
  end

  defp drop_buffer(mem, buf) do
    TypedArrays.detach(buf)
    Process.delete({:wasm_buf, mem.id})
    Process.put(:wasm_live, Enum.reject(live(), &(&1.id == mem.id)))
  end

  defp buffer_of(mem) do
    push(mem)

    case Process.get({:wasm_buf, mem.id}) do
      {buf, _, _} ->
        buf

      nil ->
        bytes = Memory.to_binary(mem)
        buf = TypedArrays.make_buffer(bytes)
        Process.put({:wasm_buf, mem.id}, {buf, Memory.pages(mem), bytes})
        Process.put(:wasm_live, [mem | live()])
        buf
    end
  end

  # ── handles: objects the JavaScript classes keep ───────────

  defp handle(struct) do
    case Process.get({:wasm_handle, struct.id}) do
      nil ->
        {:obj, id} = h = new_object()
        store(id, Map.put(heap(id), :wasm, struct))
        Process.put({:wasm_handle, struct.id}, h)
        h

      h ->
        h
    end
  end

  defp struct_of({:obj, id}) do
    case heap(id) do
      %{wasm: s} -> s
      _ -> throw_error("TypeError", "not a WebAssembly object")
    end
  end

  defp struct_of(_), do: throw_error("TypeError", "not a WebAssembly object")

  defp kind_name(:func), do: "function"
  defp kind_name(:mem), do: "memory"
  defp kind_name(k), do: Atom.to_string(k)

  defp limits(v) do
    case v do
      :undefined ->
        nil

      n ->
        case to_num(n) do
          x when is_number(x) -> trunc(x)
          _ -> 0
        end
    end
  end

  # ── imports ────────────────────────────────────────────────

  defp import_value({:func, type}, v) do
    cond do
      match?({:obj, _}, v) and Process.get({:wasm_fn_of, elem(v, 1)}) ->
        Process.get({:wasm_fn_of, elem(v, 1)})

      function?(v) ->
        host_func(type, v)

      true ->
        Error.fail(:link, "function import requires a callable")
    end
  end

  defp import_value({:table, _}, {:obj, id} = v), do: wasm_handle(id, Table, v)
  defp import_value({:mem, _}, {:obj, id} = v), do: wasm_handle(id, Memory, v)

  defp import_value({:global, {type, mut}}, v) do
    case v do
      {:obj, id} ->
        case heap(id) do
          %{wasm: %Global{} = g} -> g
          _ -> global_from_value(type, mut, v)
        end

      _ ->
        global_from_value(type, mut, v)
    end
  end

  defp import_value({kind, _}, _),
    do: Error.fail(:link, "#{kind_name(kind)} import has the wrong type")

  defp wasm_handle(id, mod, _v) do
    case heap(id) do
      %{wasm: %{__struct__: ^mod} = s} -> s
      _ -> Error.fail(:link, "import has the wrong type")
    end
  end

  defp global_from_value(type, :const, v) do
    cond do
      type == :i64 and match?({:bigint, _}, v) ->
        Global.new(type, false, to_wasm(type, v))

      type in [:i32, :f32, :f64] and is_number_value(v) ->
        Global.new(type, false, to_wasm(type, v))

      type in [:funcref, :externref] ->
        Global.new(type, false, to_wasm(type, v))

      true ->
        Error.fail(
          :link,
          "global import must be a number, valid Wasm reference, or WebAssembly.Global object"
        )
    end
  end

  defp global_from_value(_, :var, _),
    do: Error.fail(:link, "imported mutable global must be a WebAssembly.Global object")

  defp is_number_value(v), do: is_number(v) or v in [:nan, :infinity, :neg_infinity]

  # ── natives ────────────────────────────────────────────────

  defp natives do
    [
      {"init", 3,
       fn _, args ->
         for {name, i} <- [{"CompileError", 0}, {"LinkError", 1}, {"RuntimeError", 2}] do
           Process.put({:wasm_error, name}, arg(args, i))
         end

         :undefined
       end},
      {"compile", 1,
       fn _, args ->
         case TypedArrays.source_bytes(arg(args, 0)) do
           {:ok, bytes} ->
             mod = guard(fn -> Wasm.compile(bytes) end)
             {:obj, id} = h = new_object()
             store(id, Map.put(heap(id), :wasm, {:module, mod}))
             h

           :error ->
             throw_error("TypeError", "WebAssembly.Module(): Argument 0 must be a buffer source")
         end
       end},
      {"validate", 1,
       fn _, args ->
         case TypedArrays.source_bytes(arg(args, 0)) do
           {:ok, bytes} ->
             Wasm.valid?(bytes)

           :error ->
             throw_error(
               "TypeError",
               "WebAssembly.validate(): Argument 0 must be a buffer source"
             )
         end
       end},
      {"imports", 1,
       fn _, args ->
         {:module, mod} = struct_of(arg(args, 0))

         new_array(
           for i <- Wasm.imports(mod) do
             new_object([
               {"module", i.module},
               {"name", i.name},
               {"kind", kind_name(i.kind)}
             ])
           end
         )
       end},
      {"exports", 1,
       fn _, args ->
         {:module, mod} = struct_of(arg(args, 0))

         new_array(
           for e <- Wasm.exports(mod) do
             new_object([{"name", e.name}, {"kind", kind_name(e.kind)}])
           end
         )
       end},
      {"customSections", 2,
       fn _, args ->
         {:module, mod} = struct_of(arg(args, 0))
         name = to_str(arg(args, 1))
         new_array(for d <- Wasm.custom_sections(mod, name), do: TypedArrays.make_buffer(d))
       end},
      {"instantiate", 2,
       fn _, args ->
         {:module, mod} = struct_of(arg(args, 0))
         resolver = arg(args, 1)

         resolve = fn module, name, desc ->
           v = call(resolver, :undefined, [module, name, kind_name(elem(desc, 0))])
           import_value(desc, v)
         end

         pull_all()

         try do
           inst = guard(fn -> Wasm.instantiate(mod, resolve) end)
           push_all()

           new_array(
             for {name, kind, v} <- inst.exports do
               x = if kind == :func, do: wrap_func(v), else: handle(v)
               new_array([name, kind_name(kind), x])
             end
           )
         catch
           kind, val ->
             push_all()
             :erlang.raise(kind, val, __STACKTRACE__)
         end
       end},
      {"memNew", 2,
       fn _, args ->
         initial = limits(arg(args, 0))
         max = limits(arg(args, 1))

         if initial > 65536 or (is_integer(max) and (max > 65536 or max < initial)),
           do: throw_error("RangeError", "WebAssembly.Memory(): could not allocate memory")

         handle(Memory.new(initial, max))
       end},
      {"memBuffer", 1, fn _, args -> buffer_of(struct_of(arg(args, 0))) end},
      {"memGrow", 2,
       fn _, args ->
         mem = struct_of(arg(args, 0))
         pull_all()
         old = Memory.grow(mem, limits(arg(args, 1)))

         if old < 0,
           do:
             throw_error("RangeError", "WebAssembly.Memory.grow(): Maximum memory size exceeded")

         case Process.get({:wasm_buf, mem.id}) do
           {buf, _, _} -> drop_buffer(mem, buf)
           nil -> :ok
         end

         old * 1.0
       end},
      {"tblNew", 4,
       fn _, args ->
         type = if to_str(arg(args, 0)) == "externref", do: :externref, else: :funcref
         initial = limits(arg(args, 1))
         max = limits(arg(args, 2))

         if initial > 10_000_000 or (is_integer(max) and max < initial),
           do: throw_error("RangeError", "WebAssembly.Table(): could not allocate table")

         handle(Table.new(type, initial, max, to_wasm(type, arg(args, 3))))
       end},
      {"tblGet", 2,
       fn _, args ->
         t = struct_of(arg(args, 0))
         i = limits(arg(args, 1))
         if i >= Table.size(t), do: throw_error("RangeError", "invalid index #{i} into table")
         to_js(t.type, Table.get(t, i))
       end},
      {"tblSet", 3,
       fn _, args ->
         t = struct_of(arg(args, 0))
         i = limits(arg(args, 1))
         if i >= Table.size(t), do: throw_error("RangeError", "invalid index #{i} into table")
         Table.set(t, i, table_value(t, args, 2))
         :undefined
       end},
      {"tblGrow", 3,
       fn _, args ->
         t = struct_of(arg(args, 0))
         old = Table.grow(t, limits(arg(args, 1)), table_value(t, args, 2))

         if old < 0,
           do: throw_error("RangeError", "WebAssembly.Table.grow(): failed to grow table")

         old * 1.0
       end},
      {"tblSize", 1, fn _, args -> Table.size(struct_of(arg(args, 0))) * 1.0 end},
      {"globNew", 3,
       fn _, args ->
         type = String.to_atom(to_str(arg(args, 0)))
         type = if type == :anyfunc, do: :funcref, else: type
         v = if arg(args, 2) == :undefined, do: zero(type), else: to_wasm(type, arg(args, 2))
         v = if arg(args, 2) == :undefined and type == :externref, do: :undefined, else: v
         handle(Global.new(type, arg(args, 1) == true, v))
       end},
      {"globGet", 1,
       fn _, args ->
         g = struct_of(arg(args, 0))
         to_js(g.type, Global.get(g))
       end},
      {"globSet", 2,
       fn _, args ->
         g = struct_of(arg(args, 0))
         unless g.mut, do: throw_error("TypeError", "Can't set the value of an immutable global.")
         Global.set(g, to_wasm(g.type, arg(args, 1)))
         :undefined
       end},
      {"globType", 1,
       fn _, args ->
         g = struct_of(arg(args, 0))
         if g.type == :funcref, do: "anyfunc", else: Atom.to_string(g.type)
       end}
    ]
  end

  defp source, do: Browser.JS.WebAssemblySource.source()
end
