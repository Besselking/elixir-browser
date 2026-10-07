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
    install_weakref(scope)
    install_reflect(scope)
    install_host(scope)
    Browser.JS.TypedArrays.install(scope)
    Browser.JS.Disposables.install(scope)
    Browser.JS.Iterators.install(scope)
    Browser.JS.FunctionKinds.install(scope)
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
          Process.put({:js_registered_symbol, sym}, true)
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

  # an Array or String iterator: `step` produces the next result object, `next` is on the shared
  # prototype
  defp make_kind_iterator(list, kind) do
    pos = make_ref()
    Process.put(pos, list)

    step = fn ->
      case Process.get(pos) do
        [h | t] ->
          Process.put(pos, t)
          new_object([{"value", h}, {"done", false}])

        _ ->
          new_object([{"value", :undefined}, {"done", true}])
      end
    end

    array_iterator(step, kind)
  end

  # Array.prototype.values/keys/entries: the object is read as the iterator goes (an element
  # added, changed or removed in between shows), whatever it is, as long as it has a length
  defp live_array_iterator(this, mode) do
    o =
      if nullish?(this),
        do: throw_error("TypeError", "Array.prototype.values called on null or undefined"),
        else: if(match?({:obj, _}, this), do: this, else: Browser.JS.Builtins.box(this))

    pos = make_ref()
    Process.put(pos, 0)

    step = fn ->
      case Process.get(pos) do
        :done ->
          new_object([{"value", :undefined}, {"done", true}])

        i ->
          if i >= Browser.JS.ArrayGeneric.len(o) do
            Process.put(pos, :done)
            new_object([{"value", :undefined}, {"done", true}])
          else
            Process.put(pos, i + 1)

            value =
              case mode do
                :keys -> i * 1.0
                :values -> Interp.get(o, Integer.to_string(i))
                :entries -> new_array([i * 1.0, Interp.get(o, Integer.to_string(i))])
              end

            new_object([{"value", value}, {"done", false}])
          end
      end
    end

    array_iterator(step, :array_iterator)
  end

  @doc "An Array Iterator object (also used for typed arrays) whose `next` runs `step`."
  def array_iterator(step, kind \\ :array_iterator) do
    {:obj, id} = it = new_object([], proto(kind))
    store(id, deref(id) |> Map.put(:iter_kind, kind) |> Map.put(:iter_step, step))
    it
  end

  defp install_kind_iterator(kind, tag) do
    p = new_object([], proto(:iterator))
    put_proto(kind, p)
    put_tag(p, tag)

    def_fn(p, "next", fn this, _ ->
      step =
        case this do
          {:obj, id} ->
            case deref(id) do
              %{iter_kind: ^kind, iter_step: step} -> step
              _ -> nil
            end

          _ ->
            nil
        end

      if step == nil,
        do: throw_error("TypeError", "next method called on an incompatible receiver")

      step.()
    end)
  end

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

    install_kind_iterator(:array_iterator, "Array Iterator")
    install_kind_iterator(:string_iterator, "String Iterator")

    # arrays, strings
    array = proto(:array)

    values = native("values", fn this, _ -> live_array_iterator(this, :values) end)

    put_hidden(array, "values", values)
    put_hidden(array, @iterator, values)

    # what a pristine array iteration looks like (see `Interp.array_iteration_pristine?/1`)
    Process.put(:js_arr_values, values)
    Process.put(:js_arr_next, Interp.get(proto(:array_iterator), "next"))

    unscopables = new_object([], :null)

    for name <-
          ~w(at copyWithin entries fill find findIndex findLast findLastIndex flat flatMap includes keys toReversed toSorted toSpliced values),
        do: Interp.put(unscopables, name, true)

    key = {:symbol, :unscopables, "Symbol.unscopables"}
    put_hidden(array, key, unscopables)
    {:obj, aid} = array
    ao = deref(aid)
    store(aid, Map.put(ao, :attrs, Map.put(Map.get(ao, :attrs, %{}), key, %{w: false, c: true})))

    def_fn(array, "keys", fn this, _ -> live_array_iterator(this, :keys) end)
    def_fn(array, "entries", fn this, _ -> live_array_iterator(this, :entries) end)

    put_hidden(
      proto(:string),
      @iterator,
      native("[Symbol.iterator]", fn this, _ ->
        if nullish?(this),
          do:
            throw_error(
              "TypeError",
              "String.prototype[Symbol.iterator] called on null or undefined"
            )

        make_kind_iterator(String.codepoints(to_str(this)), :string_iterator)
      end)
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

    install_upsert(p, :map, &norm/1, fn _ -> true end)

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

    install_set_methods(p)
  end

  # ── Set methods (union, intersection, ...) ─────────────────

  # GetSetRecord: the argument must look like a set (`size`, `has`, `keys`)
  defp set_record(other) do
    unless match?({:obj, _}, other),
      do: throw_error("TypeError", "the argument must be an object")

    int =
      case to_num(Interp.get(other, "size")) do
        :nan -> throw_error("TypeError", "size is not a number")
        :infinity -> :infinity
        :neg_infinity -> -1
        n -> trunc(n)
      end

    if int != :infinity and int < 0, do: throw_error("RangeError", "size must not be negative")
    has = Interp.get(other, "has")
    unless function?(has), do: throw_error("TypeError", "has is not a function")
    keys = Interp.get(other, "keys")
    unless function?(keys), do: throw_error("TypeError", "keys is not a function")
    %{obj: other, size: int, has: has, keys: keys}
  end

  # calls `fun` with each value of `rec.keys()` until it says :stop (then the iterator is closed)
  defp each_key(rec, fun) do
    it = call(rec.keys, rec.obj, [])
    unless match?({:obj, _}, it), do: throw_error("TypeError", "keys() did not return an object")
    next = Interp.get(it, "next")
    key_loop(it, next, fun)
  end

  defp key_loop(it, next, fun) do
    case Interp.iter_step(it, next) do
      :done ->
        :done

      {:ok, v} ->
        case fun.(norm(v)) do
          :cont ->
            key_loop(it, next, fun)

          :stop ->
            Interp.iter_close(it, false)
            :stopped
        end
    end
  end

  # the values of the receiver, live: what `has` calls add or remove is seen
  defp each_own(this, fun, cursor \\ 0) do
    {:obj, id} = this

    case next_from(deref(id), cursor) do
      :none ->
        :done

      {seq, k, _} ->
        case fun.(k) do
          :cont -> each_own(this, fun, seq + 1)
          :stop -> :stopped
        end
    end
  end

  defp has?(rec, v), do: truthy(call(rec.has, rec.obj, [v]))
  defp in_set?(this, v), do: Map.has_key?(deref(elem(this, 1)).data, v)
  defp set_size(this), do: map_size(deref(elem(this, 1)).data)

  defp copy_set(this) do
    r = new_collection(:set, :set)
    for {_, k, _} <- ordered(deref(elem(this, 1))), do: put_entry(r, k, k)
    r
  end

  defp remove_value(r, v) do
    {:obj, rid} = r
    delete_entry(rid, deref(rid), v)
  end

  defp install_set_methods(p) do
    def_set = fn name, fun ->
      f =
        native(name, fn this, args ->
          data!(this, :set)
          fun.(this, set_record(arg(args, 0)))
        end)

      {:obj, fid} = f
      store(fid, Map.put(deref(fid), :arity, 1.0))
      put_hidden(p, name, f)
    end

    def_set.("union", fn this, rec ->
      r = copy_set(this)

      each_key(rec, fn v ->
        put_entry(r, v, v)
        :cont
      end)

      r
    end)

    def_set.("intersection", fn this, rec ->
      r = new_collection(:set, :set)

      if set_size(this) <= rec.size do
        each_own(this, fn e ->
          if has?(rec, e) and not Map.has_key?(deref(elem(r, 1)).data, e), do: put_entry(r, e, e)
          :cont
        end)
      else
        each_key(rec, fn v ->
          if in_set?(this, v), do: put_entry(r, v, v)
          :cont
        end)
      end

      r
    end)

    def_set.("difference", fn this, rec ->
      r = copy_set(this)

      if set_size(this) <= rec.size do
        each_own(this, fn e ->
          if has?(rec, e), do: remove_value(r, e)
          :cont
        end)
      else
        each_key(rec, fn v ->
          remove_value(r, v)
          :cont
        end)
      end

      r
    end)

    def_set.("symmetricDifference", fn this, rec ->
      r = copy_set(this)

      each_key(rec, fn v ->
        if in_set?(this, v), do: remove_value(r, v), else: put_entry(r, v, v)
        :cont
      end)

      r
    end)

    def_set.("isSubsetOf", fn this, rec ->
      if set_size(this) > rec.size do
        false
      else
        each_own(this, fn e -> if has?(rec, e), do: :cont, else: :stop end) == :done
      end
    end)

    def_set.("isSupersetOf", fn this, rec ->
      if set_size(this) < rec.size do
        false
      else
        each_key(rec, fn v -> if in_set?(this, v), do: :cont, else: :stop end) == :done
      end
    end)

    def_set.("isDisjointFrom", fn this, rec ->
      if set_size(this) <= rec.size do
        each_own(this, fn e -> if has?(rec, e), do: :stop, else: :cont end) == :done
      else
        each_key(rec, fn v -> if in_set?(this, v), do: :stop, else: :cont end) == :done
      end
    end)
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

    install_upsert(wm, :weakmap, & &1, &weak_key?/1)

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
    unless weak_key?(key),
      do: throw_error("TypeError", "Invalid value used as weak map key")

    put_entry(this, key, value)
  end

  # Map.prototype.getOrInsert / getOrInsertComputed (and the WeakMap versions)
  defp install_upsert(proto, class, normf, valid?) do
    def_fn(proto, "getOrInsert", fn this, args ->
      o = data!(this, class)
      key = arg(args, 0)
      unless valid?.(key), do: throw_error("TypeError", "Invalid value used as weak map key")
      nk = normf.(key)

      case o.data do
        %{^nk => {_, _, v}} ->
          v

        _ ->
          put_entry(this, nk, arg(args, 1))
          arg(args, 1)
      end
    end)

    def_fn(proto, "getOrInsertComputed", fn this, args ->
      o = data!(this, class)
      key = arg(args, 0)
      f = arg(args, 1)
      unless valid?.(key), do: throw_error("TypeError", "Invalid value used as weak map key")
      unless function?(f), do: throw_error("TypeError", "callback is not a function")
      nk = normf.(key)

      case o.data do
        %{^nk => {_, _, v}} ->
          v

        _ ->
          v = call(f, :undefined, [nk])
          put_entry(this, nk, v)
          v
      end
    end)

    set_arity(Interp.get(proto, "getOrInsert"), 2)
    set_arity(Interp.get(proto, "getOrInsertComputed"), 2)
  end

  defp install_weakref(scope) do
    p = new_object()
    put_proto(:weakref, p)

    ctor =
      native("WeakRef", fn this, args ->
        unless match?({:obj, _}, this) and deref(elem(this, 1)).class == :object,
          do: throw_error("TypeError", "Constructor WeakRef requires 'new'")

        t = arg(args, 0)

        unless weak_key?(t),
          do: throw_error("TypeError", "WeakRef: invalid target")

        {:obj, id} = this
        store(id, Map.merge(deref(id), %{class: :weakref, target: t}))
        this
      end)

    set_arity(ctor, 1)
    put_const(ctor, "prototype", p)
    put_hidden(p, "constructor", ctor)
    declare(scope, "WeakRef", ctor)
    put_tag(p, "WeakRef")

    def_fn(p, "deref", fn this, _ -> data!(this, :weakref).target end)

    fp = new_object()
    put_proto(:finreg, fp)

    fctor =
      native("FinalizationRegistry", fn this, args ->
        unless match?({:obj, _}, this) and deref(elem(this, 1)).class == :object,
          do: throw_error("TypeError", "Constructor FinalizationRegistry requires 'new'")

        unless function?(arg(args, 0)),
          do: throw_error("TypeError", "cleanup callback must be callable")

        {:obj, id} = this
        store(id, Map.merge(deref(id), %{class: :finreg, tokens: []}))
        this
      end)

    set_arity(fctor, 1)
    put_const(fctor, "prototype", fp)
    put_hidden(fp, "constructor", fctor)
    declare(scope, "FinalizationRegistry", fctor)
    put_tag(fp, "FinalizationRegistry")

    def_fn(fp, "register", fn this, args ->
      data!(this, :finreg)
      t = arg(args, 0)
      held = arg(args, 1)
      token = arg(args, 2)
      unless weak_key?(t), do: throw_error("TypeError", "register: invalid target")
      if t == held, do: throw_error("TypeError", "target and holdings must not be same")

      unless token == :undefined or weak_key?(token),
        do: throw_error("TypeError", "register: invalid unregister token")

      if token != :undefined do
        {:obj, id} = this
        o = deref(id)
        store(id, %{o | tokens: [token | o.tokens]})
      end

      :undefined
    end)

    def_fn(fp, "unregister", fn this, args ->
      o = data!(this, :finreg)
      token = arg(args, 0)
      unless weak_key?(token), do: throw_error("TypeError", "unregister: invalid token")
      {:obj, id} = this
      store(id, %{o | tokens: Enum.reject(o.tokens, &(&1 == token))})
      token in o.tokens
    end)

    set_arity(Interp.get(fp, "register"), 2)
    set_arity(Interp.get(fp, "unregister"), 1)
  end

  defp weak_key?({:obj, _}), do: true
  defp weak_key?({:symbol, _, _} = sym), do: Process.get({:js_registered_symbol, sym}) != true
  defp weak_key?(_), do: false

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
