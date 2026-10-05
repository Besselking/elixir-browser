defmodule Browser.JS.Collections do
  @moduledoc """
  `Symbol`, `Map`, `Set`, `WeakMap`, `WeakSet`, `Reflect`, iterator objects, `setImmediate` and
  `MessageChannel` for the JavaScript runtime.

  A symbol is `{:symbol, id, description}`; the well-known ones have atoms for their id
  (`{:symbol, :iterator, "Symbol.iterator"}`). A symbol-keyed property is an ordinary entry in the
  object's `props` that is not listed in `keys`, so it stays out of `Object.keys` and `for in`.

  A `Map` or `Set` is a heap object of class `:map` or `:set` with its entries under `data`,
  keyed by the SameValueZero form of the key and numbered by insertion.
  """

  import Browser.JS.Interp, except: [get: 2, put: 3]
  alias Browser.JS.{Interp, Props}

  @iterator {:symbol, :iterator, "Symbol.iterator"}
  @well_known ~w(iterator asyncIterator hasInstance toPrimitive toStringTag species isConcatSpreadable
                 match matchAll replace search split unscopables dispose asyncDispose)a

  def iterator_symbol, do: @iterator

  defp arg(args, i), do: Enum.at(args, i, :undefined)
  defp def_fn(obj, name, fun), do: put_hidden(obj, name, native(name, fun))

  # ── Symbol ─────────────────────────────────────────────────

  def install(scope) do
    install_symbol(scope)
    install_iterators()
    Browser.JS.Async.install_generators()
    Browser.JS.Async.install_async_generators()
    install_map(scope)
    install_set(scope)
    install_weak(scope)
    install_reflect(scope)
    install_host(scope)
    Browser.JS.TypedArrays.install(scope)
    Browser.JS.Disposables.install(scope)
    :ok
  end

  defp install_symbol(scope) do
    p = new_object()
    put_proto(:symbol, p)
    counter = :counters.new(1, [])
    registry = :ets.new(:js_symbol_registry, [:set, :private])

    ctor =
      native("Symbol", fn _, args ->
        :counters.add(counter, 1, 1)
        desc = if arg(args, 0) == :undefined, do: :undefined, else: to_str(arg(args, 0))
        {:symbol, :counters.get(counter, 1), desc}
      end)

    put_const(ctor, "prototype", p)
    put_hidden(p, "constructor", ctor)
    declare(scope, "Symbol", ctor)
    put_tag(p, "Symbol")
    {:obj, ctor_id} = ctor
    store(ctor_id, Map.put(deref(ctor_id), :no_new, true))

    for name <- @well_known,
        do: put_const(ctor, to_string(name), {:symbol, name, "Symbol." <> to_string(name)})

    def_fn(ctor, "for", fn _, args ->
      key = to_str(arg(args, 0))

      case :ets.lookup(registry, key) do
        [{_, sym}] ->
          sym

        [] ->
          :counters.add(counter, 1, 1)
          sym = {:symbol, :counters.get(counter, 1), key}
          :ets.insert(registry, {key, sym})
          sym
      end
    end)

    def_fn(ctor, "keyFor", fn _, args ->
      case arg(args, 0) do
        {:symbol, _, desc} = sym ->
          case :ets.lookup(registry, desc) do
            [{_, ^sym}] -> desc
            _ -> :undefined
          end

        _ ->
          throw_error("TypeError", "not a symbol")
      end
    end)

    def_fn(p, "toString", fn this, _ -> "Symbol(#{description(this_symbol(this))})" end)
    def_fn(p, "valueOf", fn this, _ -> this_symbol(this) end)

    Props.define_accessor(p, "description",
      get: native("description", fn this, _ -> desc_or_undefined(this_symbol(this)) end),
      enumerable: false
    )

    put_hidden(p, @iterator, native("[Symbol.iterator]", fn this, _ -> this end))

    # Symbol.prototype[@@toPrimitive]: not writable, but configurable
    {:obj, tp_id} = to_prim = native("[Symbol.toPrimitive]", fn this, _ -> this_symbol(this) end)
    store(tp_id, Map.put(deref(tp_id), :arity, 1.0))
    key = {:symbol, :toPrimitive, "Symbol.toPrimitive"}
    {:obj, pid} = p
    po = deref(pid)
    attrs = Map.put(Map.get(po, :attrs, %{}), key, %{w: false, c: true, e: false})
    store(pid, po |> Map.put(:props, Map.put(po.props, key, to_prim)) |> Map.put(:attrs, attrs))
    :ok
  end

  # a Symbol primitive or a `Object(sym)` wrapper
  defp this_symbol({:symbol, _, _} = s), do: s

  defp this_symbol({:obj, id}) do
    case deref(id) do
      %{prim: {:symbol, _, _} = s} -> s
      _ -> throw_error("TypeError", "not a symbol")
    end
  end

  defp this_symbol(_), do: throw_error("TypeError", "not a symbol")

  defp description({:symbol, _, :undefined}), do: ""
  defp description({:symbol, _, d}), do: d
  defp description(_), do: throw_error("TypeError", "not a symbol")

  defp desc_or_undefined({:symbol, _, d}), do: d
  defp desc_or_undefined(_), do: :undefined

  # ── iterator objects ───────────────────────────────────────

  @doc "An iterator object over a list (computed up front)."
  def make_iterator(list) do
    pos = make_ref()
    Process.put(pos, list)
    it = new_object([], proto(:iterator))

    put_hidden(
      it,
      "next",
      native("next", fn _, _ ->
        case Process.get(pos) do
          [h | t] ->
            Process.put(pos, t)
            new_object([{"value", h}, {"done", false}])

          _ ->
            new_object([{"value", :undefined}, {"done", true}])
        end
      end)
    )

    it
  end

  defp install_iterators do
    p = new_object()
    put_proto(:iterator, p)
    put_hidden(p, @iterator, native("[Symbol.iterator]", fn this, _ -> this end))

    # arrays, strings
    array = proto(:array)

    values = native("values", fn this, _ -> make_iterator(iterate(this)) end)
    put_hidden(array, "values", values)
    put_hidden(array, @iterator, values)

    unscopables = new_object([], :null)

    for name <-
          ~w(at copyWithin entries fill find findIndex findLast findLastIndex flat flatMap includes keys toReversed toSorted toSpliced values),
        do: Interp.put(unscopables, name, true)

    key = {:symbol, :unscopables, "Symbol.unscopables"}
    put_hidden(array, key, unscopables)
    {:obj, aid} = array
    ao = deref(aid)
    store(aid, Map.put(ao, :attrs, Map.put(Map.get(ao, :attrs, %{}), key, %{w: false})))

    def_fn(array, "keys", fn this, _ ->
      make_iterator(for i <- 0..(length(iterate(this)) - 1)//1, do: i * 1.0)
    end)

    def_fn(array, "entries", fn this, _ ->
      make_iterator(for {v, i} <- Enum.with_index(iterate(this)), do: new_array([i * 1.0, v]))
    end)

    put_hidden(
      proto(:string),
      @iterator,
      native("[Symbol.iterator]", fn this, _ -> make_iterator(String.codepoints(to_str(this))) end)
    )
  end

  # ── Map and Set ────────────────────────────────────────────

  defp norm(k) when is_float(k) and k == 0, do: 0.0
  defp norm(k), do: k

  defp new_collection(class, proto_name) do
    {:obj,
     alloc(%{
       class: class,
       data: %{},
       seq: 0,
       props: %{},
       keys: [],
       proto: proto(proto_name)
     })}
  end

  defp data!({:obj, id} = this, class) do
    o = deref(id)

    unless o.class == class,
      do:
        throw_error(
          "TypeError",
          "Method called on incompatible receiver #{Browser.JS.Builtins.inspect_js(this, 0, [])}"
        )

    o
  end

  defp data!(this, _),
    do:
      throw_error(
        "TypeError",
        "Method called on incompatible receiver #{Browser.JS.Builtins.inspect_js(this, 0, [])}"
      )

  defp put_entry({:obj, id}, key, value) do
    o = deref(id)
    nk = norm(key)

    case o.data do
      %{^nk => {seq, k, _}} ->
        store(id, %{o | data: Map.put(o.data, nk, {seq, k, value})})

      _ ->
        store(id, %{o | data: Map.put(o.data, nk, {o.seq, nk, value}), seq: o.seq + 1})
    end
  end

  defp ordered(o), do: o.data |> Map.values() |> Enum.sort_by(&elem(&1, 0))

  @doc "The entries of a Map (`[key, value]` arrays) or Set (values), for iteration."
  def entries(%{class: :map} = o), do: for({_, k, v} <- ordered(o), do: new_array([k, v]))
  def entries(%{class: :set} = o), do: for({_, k, _} <- ordered(o), do: k)

  defp install_map(scope) do
    p = new_object()
    put_proto(:map, p)

    ctor =
      native("Map", fn _, args ->
        m = new_collection(:map, :map)

        case arg(args, 0) do
          v when v in [:undefined, :null] ->
            :ok

          src ->
            for e <- iterate(src) do
              unless match?({:obj, _}, e),
                do: throw_error("TypeError", "Iterator value #{to_str(e)} is not an entry object")

              put_entry(m, Interp.get(e, 0.0), Interp.get(e, 1.0))
            end
        end

        m
      end)

    put_const(ctor, "prototype", p)
    put_hidden(p, "constructor", ctor)
    declare(scope, "Map", ctor)
    def_species(ctor)

    def_fn(p, "get", fn this, args ->
      o = data!(this, :map)

      case o.data do
        %{} = d ->
          with {_, _, v} <- Map.get(d, norm(arg(args, 0))), do: v, else: (_ -> :undefined)
      end
    end)

    def_fn(p, "set", fn this, args ->
      data!(this, :map)
      put_entry(this, arg(args, 0), arg(args, 1))
      this
    end)

    def_fn(p, "has", fn this, args -> Map.has_key?(data!(this, :map).data, norm(arg(args, 0))) end)

    def_fn(p, "delete", fn this, args ->
      {:obj, id} = this
      o = data!(this, :map)
      nk = norm(arg(args, 0))
      had = Map.has_key?(o.data, nk)
      store(id, %{o | data: Map.delete(o.data, nk)})
      had
    end)

    def_fn(p, "clear", fn this, _ ->
      {:obj, id} = this
      o = data!(this, :map)
      store(id, %{o | data: %{}})
      :undefined
    end)

    def_fn(p, "forEach", fn this, args ->
      o = data!(this, :map)
      f = arg(args, 0)

      unless function?(f), do: throw_error("TypeError", "callback is not a function")
      for {_, k, v} <- ordered(o), do: call(f, arg(args, 1), [v, k, this])
      :undefined
    end)

    def_fn(p, "keys", fn this, _ ->
      make_iterator(for({_, k, _} <- ordered(data!(this, :map)), do: k))
    end)

    def_fn(p, "values", fn this, _ ->
      make_iterator(for({_, _, v} <- ordered(data!(this, :map)), do: v))
    end)

    entries_fn = native("entries", fn this, _ -> make_iterator(entries(data!(this, :map))) end)
    put_hidden(p, "entries", entries_fn)
    put_hidden(p, @iterator, entries_fn)

    Props.define_accessor(p, "size",
      get: native("size", fn this, _ -> map_size(data!(this, :map).data) * 1.0 end),
      enumerable: false
    )
  end

  defp install_set(scope) do
    p = new_object()
    put_proto(:set, p)

    ctor =
      native("Set", fn _, args ->
        s = new_collection(:set, :set)

        case arg(args, 0) do
          v when v in [:undefined, :null] -> :ok
          src -> for v <- iterate(src), do: put_entry(s, v, v)
        end

        s
      end)

    put_const(ctor, "prototype", p)
    put_hidden(p, "constructor", ctor)
    declare(scope, "Set", ctor)
    def_species(ctor)

    def_fn(p, "add", fn this, args ->
      data!(this, :set)
      v = arg(args, 0)
      put_entry(this, v, v)
      this
    end)

    def_fn(p, "has", fn this, args -> Map.has_key?(data!(this, :set).data, norm(arg(args, 0))) end)

    def_fn(p, "delete", fn this, args ->
      {:obj, id} = this
      o = data!(this, :set)
      nk = norm(arg(args, 0))
      had = Map.has_key?(o.data, nk)
      store(id, %{o | data: Map.delete(o.data, nk)})
      had
    end)

    def_fn(p, "clear", fn this, _ ->
      {:obj, id} = this
      o = data!(this, :set)
      store(id, %{o | data: %{}})
      :undefined
    end)

    def_fn(p, "forEach", fn this, args ->
      o = data!(this, :set)
      f = arg(args, 0)

      unless function?(f), do: throw_error("TypeError", "callback is not a function")
      for {_, k, _} <- ordered(o), do: call(f, arg(args, 1), [k, k, this])
      :undefined
    end)

    values_fn = native("values", fn this, _ -> make_iterator(entries(data!(this, :set))) end)
    put_hidden(p, "values", values_fn)
    put_hidden(p, "keys", values_fn)
    put_hidden(p, @iterator, values_fn)

    def_fn(p, "entries", fn this, _ ->
      make_iterator(for v <- entries(data!(this, :set)), do: new_array([v, v]))
    end)

    Props.define_accessor(p, "size",
      get: native("size", fn this, _ -> map_size(data!(this, :set).data) * 1.0 end),
      enumerable: false
    )
  end

  # WeakMap and WeakSet: keyed by objects, and nothing is ever collected
  defp install_weak(scope) do
    wm = new_object()
    put_proto(:weakmap, wm)

    wm_ctor =
      native("WeakMap", fn _, args ->
        m = new_collection(:weakmap, :weakmap)

        case arg(args, 0) do
          v when v in [:undefined, :null] -> :ok
          src -> for e <- iterate(src), do: put_weak(m, Interp.get(e, 0.0), Interp.get(e, 1.0))
        end

        m
      end)

    put_const(wm_ctor, "prototype", wm)
    put_hidden(wm, "constructor", wm_ctor)
    declare(scope, "WeakMap", wm_ctor)

    def_fn(wm, "get", fn this, args ->
      o = data!(this, :weakmap)
      with {_, _, v} <- Map.get(o.data, arg(args, 0)), do: v, else: (_ -> :undefined)
    end)

    def_fn(wm, "set", fn this, args ->
      data!(this, :weakmap)
      put_weak(this, arg(args, 0), arg(args, 1))
      this
    end)

    def_fn(wm, "has", fn this, args -> Map.has_key?(data!(this, :weakmap).data, arg(args, 0)) end)

    def_fn(wm, "delete", fn this, args ->
      {:obj, id} = this
      o = data!(this, :weakmap)
      had = Map.has_key?(o.data, arg(args, 0))
      store(id, %{o | data: Map.delete(o.data, arg(args, 0))})
      had
    end)

    ws = new_object()
    put_proto(:weakset, ws)

    ws_ctor =
      native("WeakSet", fn _, args ->
        s = new_collection(:weakset, :weakset)

        case arg(args, 0) do
          v when v in [:undefined, :null] -> :ok
          src -> for v <- iterate(src), do: put_weak(s, v, v)
        end

        s
      end)

    put_const(ws_ctor, "prototype", ws)
    put_hidden(ws, "constructor", ws_ctor)
    declare(scope, "WeakSet", ws_ctor)

    def_fn(ws, "add", fn this, args ->
      data!(this, :weakset)
      put_weak(this, arg(args, 0), arg(args, 0))
      this
    end)

    def_fn(ws, "has", fn this, args -> Map.has_key?(data!(this, :weakset).data, arg(args, 0)) end)

    def_fn(ws, "delete", fn this, args ->
      {:obj, id} = this
      o = data!(this, :weakset)
      had = Map.has_key?(o.data, arg(args, 0))
      store(id, %{o | data: Map.delete(o.data, arg(args, 0))})
      had
    end)
  end

  defp put_weak(this, key, value) do
    unless match?({:obj, _}, key),
      do: throw_error("TypeError", "Invalid value used as weak map key")

    put_entry(this, key, value)
  end

  # ── Reflect ────────────────────────────────────────────────

  defp install_reflect(scope) do
    r = new_object()
    declare(scope, "Reflect", r)

    def_fn(r, "apply", fn _, args ->
      f = arg(args, 0)
      list = if arg(args, 2) == :undefined, do: [], else: iterate_args(arg(args, 2))

      unless function?(f),
        do: throw_error("TypeError", "Function.prototype.apply was called on a non-function")

      call(f, arg(args, 1), list)
    end)

    def_fn(r, "construct", fn _, args ->
      f = arg(args, 0)
      nt = if arg(args, 2) == :undefined, do: f, else: arg(args, 2)

      unless constructor?(nt), do: throw_error("TypeError", "newTarget is not a constructor")
      construct(f, iterate_args(arg(args, 1)), nt)
    end)

    def_fn(r, "get", fn _, args ->
      case arg(args, 0) do
        {:obj, _} = o ->
          if arg(args, 2) == :undefined,
            do: Interp.get(o, arg(args, 1)),
            else: Interp.get_with_receiver(o, arg(args, 1), arg(args, 2))

        _ ->
          throw_error("TypeError", "Reflect.get called on non-object")
      end
    end)

    def_fn(r, "set", fn _, args ->
      case arg(args, 0) do
        {:obj, id} = o ->
          if Map.has_key?(deref(id), :proxy) do
            Browser.JS.Proxy.set(
              o,
              to_key(arg(args, 1)),
              arg(args, 2),
              if(length(args) > 3, do: arg(args, 3), else: o)
            )
          else
            Interp.put(o, arg(args, 1), arg(args, 2))
            true
          end

        _ ->
          throw_error("TypeError", "Reflect.set called on non-object")
      end
    end)

    def_fn(r, "has", fn _, args ->
      unless match?({:obj, _}, arg(args, 0)),
        do: throw_error("TypeError", "Reflect.has called on non-object")

      has_property?(arg(args, 0), arg(args, 1))
    end)

    def_fn(r, "deleteProperty", fn _, args -> Interp.delete(arg(args, 0), arg(args, 1)) end)

    def_fn(r, "defineProperty", fn _, args ->
      try do
        Props.define(arg(args, 0), arg(args, 1), arg(args, 2))
        true
      catch
        {:js_error, _} -> false
      end
    end)

    def_fn(r, "getOwnPropertyDescriptor", fn _, args ->
      Props.descriptor(arg(args, 0), to_key(arg(args, 1)))
    end)

    def_fn(r, "ownKeys", fn _, args ->
      o = arg(args, 0)
      new_array(Props.own_names(o) ++ Props.own_symbols(o))
    end)

    def_fn(r, "getPrototypeOf", fn _, args ->
      case arg(args, 0) do
        {:obj, _} = o -> Props.get_prototype_of(o)
        _ -> throw_error("TypeError", "Reflect.getPrototypeOf called on non-object")
      end
    end)

    def_fn(r, "setPrototypeOf", fn _, args ->
      case arg(args, 0) do
        {:obj, _} = o ->
          p = arg(args, 1)

          unless p == :null or match?({:obj, _}, p),
            do: throw_error("TypeError", "Object prototype may only be an Object or null")

          Props.set_prototype_of(o, p) == true

        _ ->
          throw_error("TypeError", "Reflect.setPrototypeOf called on non-object")
      end
    end)

    def_fn(r, "isExtensible", fn _, args -> Props.extensible?(arg(args, 0)) end)

    def_fn(r, "preventExtensions", fn _, args ->
      case arg(args, 0) do
        {:obj, id} = o ->
          if Map.has_key?(deref(id), :proxy) do
            Browser.JS.Proxy.prevent_extensions(o)
          else
            Props.prevent_extensions(o)
            true
          end

        _ ->
          throw_error("TypeError", "Reflect.preventExtensions called on non-object")
      end
    end)
  end

  defp iterate_args(list) do
    unless match?({:obj, _}, list),
      do: throw_error("TypeError", "CreateListFromArrayLike called on non-object")

    if array?(list), do: array_list(list), else: iterate(list)
  end

  # ── setImmediate, MessageChannel ───────────────────────────

  defp install_host(scope) do
    timeout = fn -> Map.fetch!(deref(global()).vars, "setTimeout") end

    declare(
      scope,
      "setImmediate",
      native("setImmediate", fn _, args ->
        call(timeout.(), :undefined, [arg(args, 0), 0.0 | Enum.drop(args, 1)])
      end)
    )

    declare(
      scope,
      "clearImmediate",
      native("clearImmediate", fn _, args ->
        call(Map.fetch!(deref(global()).vars, "clearTimeout"), :undefined, [arg(args, 0)])
      end)
    )

    port_proto = new_object()

    ctor =
      native("MessageChannel", fn _, _ ->
        p1 = new_object([], port_proto)
        p2 = new_object([], port_proto)
        link(p1, p2, timeout)
        link(p2, p1, timeout)
        new_object([{"port1", p1}, {"port2", p2}])
      end)

    declare(scope, "MessageChannel", ctor)
  end

  # `a.postMessage(x)` later calls `b.onmessage({data: x})`
  defp link(from, to, timeout) do
    put_hidden(
      from,
      "postMessage",
      native("postMessage", fn _, args ->
        data = arg(args, 0)

        deliver =
          native("", fn _, _ ->
            case Interp.get(to, "onmessage") do
              f when is_tuple(f) ->
                if function?(f), do: call(f, to, [new_object([{"data", data}])])

              _ ->
                :ok
            end

            :undefined
          end)

        call(timeout.(), :undefined, [deliver, 0.0])
        :undefined
      end)
    )

    put_hidden(from, "close", native("close", fn _, _ -> :undefined end))
    put_hidden(from, "start", native("start", fn _, _ -> :undefined end))
  end
end
