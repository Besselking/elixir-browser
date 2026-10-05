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
       order: :gb_trees.empty(),
       props: %{},
       keys: [],
       proto: proto(proto_name)
     })}
  end

  # a constructor was called with `new`: `this` is the object to turn into the collection
  defp init_collection({:obj, id} = this, class, name) do
    if deref(id).class != :object,
      do: throw_error("TypeError", "Constructor #{name} requires 'new'")

    store(
      id,
      Map.merge(deref(id), %{class: class, data: %{}, seq: 0, order: :gb_trees.empty()})
    )

    this
  end

  defp init_collection(_, _, name),
    do: throw_error("TypeError", "Constructor #{name} requires 'new'")

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
        store(id, %{
          o
          | data: Map.put(o.data, nk, {o.seq, nk, value}),
            order: :gb_trees.insert(o.seq, nk, o.order),
            seq: o.seq + 1
        })
    end
  end

  defp delete_entry(id, o, nk) do
    case o.data do
      %{^nk => {seq, _, _}} ->
        store(id, %{o | data: Map.delete(o.data, nk), order: :gb_trees.delete(seq, o.order)})
        true

      _ ->
        false
    end
  end

  defp clear_entries(id, o), do: store(id, %{o | data: %{}, order: :gb_trees.empty()})

  defp ordered(o), do: for(nk <- :gb_trees.values(o.order), do: Map.fetch!(o.data, nk))

  # the first live entry at or after the numbered position `cursor`
  defp next_from(o, cursor) do
    case :gb_trees.next(:gb_trees.iterator_from(cursor, o.order)) do
      {_, nk, _} -> Map.fetch!(o.data, nk)
      :none -> :none
    end
  end

  # `forEach`: sees the entries added while it runs and skips the ones deleted
  defp each_live({:obj, id}, fun, cursor \\ 0) do
    case next_from(deref(id), cursor) do
      :none ->
        :ok

      {seq, k, v} ->
        fun.(k, v)
        each_live({:obj, id}, fun, seq + 1)
    end
  end

  @doc "The entries of a Map (`[key, value]` arrays) or Set (values), for iteration."
  def entries(%{class: :map} = o), do: for({_, k, v} <- ordered(o), do: new_array([k, v]))
  def entries(%{class: :set} = o), do: for({_, k, _} <- ordered(o), do: k)

  # an iterator over a Map or Set that sees later additions; `kind` is :keys, :values or :entries
  defp coll_iterator(this, class, kind) do
    it = new_object([], proto(if class == :map, do: :map_iterator, else: :set_iterator))
    {:obj, iid} = it
    store(iid, Map.put(deref(iid), :coll_iter, {class, this, kind, 0}))
    it
  end

  defp install_coll_iterator(name, class) do
    p = new_object([], proto(:iterator))
    put_proto(if(class == :map, do: :map_iterator, else: :set_iterator), p)
    put_tag(p, name)

    def_fn(p, "next", fn this, _ ->
      state =
        case this do
          {:obj, iid} -> Map.get(deref(iid), :coll_iter)
          _ -> nil
        end

      case state do
        {^class, coll, kind, cursor} ->
          {:obj, iid} = this

          with true <- cursor != :done,
               {seq, k, v} <- next_from(deref(elem(coll, 1)), cursor) do
            store(iid, Map.put(deref(iid), :coll_iter, {class, coll, kind, seq + 1}))

            value =
              case kind do
                :keys -> k
                :values -> v
                :entries -> new_array([k, v])
              end

            new_object([{"value", value}, {"done", false}])
          else
            _ ->
              store(iid, Map.put(deref(iid), :coll_iter, {class, coll, kind, :done}))
              new_object([{"value", :undefined}, {"done", true}])
          end

        _ ->
          throw_error("TypeError", "next method called on incompatible receiver")
      end
    end)
  end

  # runs `fun.(item, index)` for every value of an iterable, closing the iterator when it throws
  defp each_item(src, fun) do
    case Interp.iter_source(src) do
      {:list, list} ->
        list |> Enum.with_index() |> Enum.each(fn {v, i} -> fun.(v, i) end)

      {:proto, it, next} ->
        each_proto(it, next, fun, 0)
    end
  end

  defp each_proto(it, next, fun, i) do
    case Interp.iter_step(it, next) do
      :done ->
        :ok

      {:ok, item} ->
        try do
          fun.(item, i)
        catch
          kind, e ->
            Interp.iter_close(it, true)
            :erlang.raise(kind, e, __STACKTRACE__)
        end

        each_proto(it, next, fun, i + 1)
    end
  end

  # what the constructors do with their iterable: call `this.set` / `this.add` for each item
  defp add_all(_this, src, _adder, _entry?) when src in [:undefined, :null], do: :ok

  defp add_all(this, src, adder_name, entry?) do
    adder = Interp.get(this, adder_name)

    unless function?(adder),
      do: throw_error("TypeError", "'#{adder_name}' returned for property is not a function")

    each_item(src, fn item, _ ->
      if entry? do
        unless match?({:obj, _}, item),
          do: throw_error("TypeError", "Iterator value #{to_str(item)} is not an entry object")

        call(adder, this, [Interp.get(item, 0.0), Interp.get(item, 1.0)])
      else
        call(adder, this, [item])
      end
    end)
  end

  defp install_map(scope) do
    p = new_object()
    put_proto(:map, p)
    install_coll_iterator("Map Iterator", :map)

    ctor =
      native("Map", fn this, args ->
        init_collection(this, :map, "Map")
        add_all(this, arg(args, 0), "set", true)
        this
      end)

    put_const(ctor, "prototype", p)
    put_hidden(p, "constructor", ctor)
    declare(scope, "Map", ctor)
    def_species(ctor)
    put_tag(p, "Map")

    def_fn(ctor, "groupBy", fn _, args ->
      items = arg(args, 0)
      f = arg(args, 1)

      if items in [:undefined, :null],
        do: throw_error("TypeError", "#{to_str(items)} is not iterable")

      unless function?(f), do: throw_error("TypeError", "callback is not a function")
      m = new_collection(:map, :map)
      {:obj, mid} = m

      each_item(items, fn item, i ->
        key = norm(call(f, :undefined, [item, i * 1.0]))

        case deref(mid).data do
          %{^key => {_, _, {:obj, _} = arr}} -> call(Interp.get(arr, "push"), arr, [item])
          _ -> put_entry(m, key, new_array([item]))
        end
      end)

      m
    end)

    def_fn(p, "get", fn this, args ->
      o = data!(this, :map)
      with {_, _, v} <- Map.get(o.data, norm(arg(args, 0))), do: v, else: (_ -> :undefined)
    end)

    def_fn(p, "set", fn this, args ->
      data!(this, :map)
      put_entry(this, arg(args, 0), arg(args, 1))
      this
    end)

    def_fn(p, "has", fn this, args -> Map.has_key?(data!(this, :map).data, norm(arg(args, 0))) end)

    def_fn(p, "delete", fn this, args ->
      o = data!(this, :map)
      {:obj, id} = this
      delete_entry(id, o, norm(arg(args, 0)))
    end)

    def_fn(p, "clear", fn this, _ ->
      o = data!(this, :map)
      {:obj, id} = this
      clear_entries(id, o)
      :undefined
    end)

    def_fn(p, "forEach", fn this, args ->
      data!(this, :map)
      f = arg(args, 0)

      unless function?(f), do: throw_error("TypeError", "callback is not a function")
      each_live(this, fn k, v -> call(f, arg(args, 1), [v, k, this]) end)
      :undefined
    end)

    def_fn(p, "keys", fn this, _ ->
      data!(this, :map)
      coll_iterator(this, :map, :keys)
    end)

    def_fn(p, "values", fn this, _ ->
      data!(this, :map)
      coll_iterator(this, :map, :values)
    end)

    entries_fn =
      native("entries", fn this, _ ->
        data!(this, :map)
        coll_iterator(this, :map, :entries)
      end)

    put_hidden(p, "entries", entries_fn)
    put_hidden(p, @iterator, entries_fn)

    Props.define_accessor(p, "size",
      get: native("get size", fn this, _ -> map_size(data!(this, :map).data) * 1.0 end),
      enumerable: false
    )
  end

  defp install_set(scope) do
    p = new_object()
    put_proto(:set, p)
    install_coll_iterator("Set Iterator", :set)

    ctor =
      native("Set", fn this, args ->
        init_collection(this, :set, "Set")
        add_all(this, arg(args, 0), "add", false)
        this
      end)

    put_const(ctor, "prototype", p)
    put_hidden(p, "constructor", ctor)
    declare(scope, "Set", ctor)
    def_species(ctor)
    put_tag(p, "Set")

    def_fn(p, "add", fn this, args ->
      data!(this, :set)
      v = arg(args, 0)
      put_entry(this, v, v)
      this
    end)

    def_fn(p, "has", fn this, args -> Map.has_key?(data!(this, :set).data, norm(arg(args, 0))) end)

    def_fn(p, "delete", fn this, args ->
      o = data!(this, :set)
      {:obj, id} = this
      delete_entry(id, o, norm(arg(args, 0)))
    end)

    def_fn(p, "clear", fn this, _ ->
      o = data!(this, :set)
      {:obj, id} = this
      clear_entries(id, o)
      :undefined
    end)

    def_fn(p, "forEach", fn this, args ->
      data!(this, :set)
      f = arg(args, 0)

      unless function?(f), do: throw_error("TypeError", "callback is not a function")
      each_live(this, fn k, _ -> call(f, arg(args, 1), [k, k, this]) end)
      :undefined
    end)

    values_fn =
      native("values", fn this, _ ->
        data!(this, :set)
        coll_iterator(this, :set, :keys)
      end)

    put_hidden(p, "values", values_fn)
    put_hidden(p, "keys", values_fn)
    put_hidden(p, @iterator, values_fn)

    def_fn(p, "entries", fn this, _ ->
      data!(this, :set)
      coll_iterator(this, :set, :entries)
    end)

    Props.define_accessor(p, "size",
      get: native("get size", fn this, _ -> map_size(data!(this, :set).data) * 1.0 end),
      enumerable: false
    )
  end

  # WeakMap and WeakSet: keyed by objects, and nothing is ever collected
  defp install_weak(scope) do
    wm = new_object()
    put_proto(:weakmap, wm)

    wm_ctor =
      native("WeakMap", fn this, args ->
        init_collection(this, :weakmap, "WeakMap")
        add_all(this, arg(args, 0), "set", true)
        this
      end)

    put_const(wm_ctor, "prototype", wm)
    put_hidden(wm, "constructor", wm_ctor)
    declare(scope, "WeakMap", wm_ctor)
    put_tag(wm, "WeakMap")

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
      o = data!(this, :weakmap)
      {:obj, id} = this
      delete_entry(id, o, arg(args, 0))
    end)

    ws = new_object()
    put_proto(:weakset, ws)

    ws_ctor =
      native("WeakSet", fn this, args ->
        init_collection(this, :weakset, "WeakSet")
        add_all(this, arg(args, 0), "add", false)
        this
      end)

    put_const(ws_ctor, "prototype", ws)
    put_hidden(ws, "constructor", ws_ctor)
    declare(scope, "WeakSet", ws_ctor)
    put_tag(ws, "WeakSet")

    def_fn(ws, "add", fn this, args ->
      data!(this, :weakset)
      put_weak(this, arg(args, 0), arg(args, 0))
      this
    end)

    def_fn(ws, "has", fn this, args -> Map.has_key?(data!(this, :weakset).data, arg(args, 0)) end)

    def_fn(ws, "delete", fn this, args ->
      o = data!(this, :weakset)
      {:obj, id} = this
      delete_entry(id, o, arg(args, 0))
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
    put_tag(r, "Reflect")

    # the target of most methods must be an object
    target! = fn v, name ->
      unless match?({:obj, _}, v),
        do: throw_error("TypeError", "Reflect.#{name} called on non-object")

      v
    end

    def = fn name, arity, fun ->
      f = native(name, fun)
      {:obj, fid} = f
      store(fid, Map.put(deref(fid), :arity, arity * 1.0))
      put_hidden(r, name, f)
    end

    def.("apply", 3, fn _, args ->
      f = arg(args, 0)

      unless function?(f),
        do: throw_error("TypeError", "Function.prototype.apply was called on a non-function")

      call(f, arg(args, 1), iterate_args(arg(args, 2)))
    end)

    def.("construct", 2, fn _, args ->
      f = arg(args, 0)

      unless constructor?(f), do: throw_error("TypeError", "target is not a constructor")
      nt = if length(args) < 3, do: f, else: arg(args, 2)

      unless constructor?(nt), do: throw_error("TypeError", "newTarget is not a constructor")
      construct(f, iterate_args(arg(args, 1)), nt)
    end)

    def.("get", 2, fn _, args ->
      o = target!.(arg(args, 0), "get")

      if length(args) < 3,
        do: Interp.get(o, arg(args, 1)),
        else: Interp.get_with_receiver(o, arg(args, 1), arg(args, 2))
    end)

    def.("set", 3, fn _, args ->
      o = target!.(arg(args, 0), "set")
      key = to_key(arg(args, 1))
      Props.ordinary_set(o, key, arg(args, 2), if(length(args) > 3, do: arg(args, 3), else: o))
    end)

    def.("has", 2, fn _, args ->
      has_property?(target!.(arg(args, 0), "has"), arg(args, 1))
    end)

    def.("deleteProperty", 2, fn _, args ->
      o = target!.(arg(args, 0), "deleteProperty")
      Interp.delete(o, to_key(arg(args, 1)))
    end)

    def.("defineProperty", 3, fn _, args ->
      o = target!.(arg(args, 0), "defineProperty")
      Props.try_define(o, arg(args, 1), arg(args, 2))
    end)

    def.("getOwnPropertyDescriptor", 2, fn _, args ->
      o = target!.(arg(args, 0), "getOwnPropertyDescriptor")
      Props.descriptor(o, to_key(arg(args, 1)))
    end)

    def.("ownKeys", 1, fn _, args ->
      new_array(Props.all_own_keys(target!.(arg(args, 0), "ownKeys")))
    end)

    def.("getPrototypeOf", 1, fn _, args ->
      Props.get_prototype_of(target!.(arg(args, 0), "getPrototypeOf"))
    end)

    def.("setPrototypeOf", 2, fn _, args ->
      o = target!.(arg(args, 0), "setPrototypeOf")
      p = arg(args, 1)

      unless p == :null or match?({:obj, _}, p),
        do: throw_error("TypeError", "Object prototype may only be an Object or null")

      Props.set_prototype_of(o, p) == true
    end)

    def.("isExtensible", 1, fn _, args ->
      Props.extensible?(target!.(arg(args, 0), "isExtensible"))
    end)

    def.("preventExtensions", 1, fn _, args ->
      {:obj, id} = o = target!.(arg(args, 0), "preventExtensions")

      if Map.has_key?(deref(id), :proxy) do
        Browser.JS.Proxy.prevent_extensions(o)
      else
        Props.prevent_extensions(o)
        true
      end
    end)
  end

  # CreateListFromArrayLike
  defp iterate_args(:undefined),
    do: throw_error("TypeError", "CreateListFromArrayLike called on non-object")

  defp iterate_args(list) do
    unless match?({:obj, _}, list),
      do: throw_error("TypeError", "CreateListFromArrayLike called on non-object")

    if array?(list) do
      array_list(list)
    else
      len =
        case to_int(Interp.get(list, "length")) do
          n when is_integer(n) and n > 0 -> n
          _ -> 0
        end

      for i <- 0..(len - 1)//1, do: Interp.get(list, Integer.to_string(i))
    end
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
