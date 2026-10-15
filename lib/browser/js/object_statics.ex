defmodule Browser.JS.ObjectStatics do
  @moduledoc """
  `Object.keys`, `values`, `entries`, `assign`, `fromEntries`, `hasOwn`, and the
  `Object.prototype` methods `hasOwnProperty`, `propertyIsEnumerable`, `valueOf`, following the
  specification's order of observable operations.
  """

  import Browser.JS.Interp, except: [get: 2, put: 3]
  alias Browser.JS.{Builtins, Interp, Props}
  require Browser.JS.Fast, as: Fast
  require Browser.JS.Obj, as: Obj

  defp get(o, k), do: Interp.get(o, k)
  defp arg(args, i), do: Enum.at(args, i, :undefined)

  def install(obj, proto) do
    def_fn(obj, "keys", 1, fn _, args ->
      o = object!(arg(args, 0))

      if proxy?(o),
        do: new_array(for k <- Props.own_names(o), enumerable_own?(o, k), do: k),
        else: new_array(enumerable_keys(o))
    end)

    def_fn(obj, "values", 1, fn _, args ->
      new_array(entries_of(object!(arg(args, 0)), fn _, v -> v end))
    end)

    def_fn(obj, "entries", 1, fn _, args ->
      new_array(entries_of(object!(arg(args, 0)), fn k, v -> new_array([k, v]) end))
    end)

    def_fn(obj, "assign", 2, fn _, args -> assign(arg(args, 0), Enum.drop(args, 1)) end)
    def_fn(obj, "fromEntries", 1, fn _, args -> from_entries(arg(args, 0)) end)

    def_fn(obj, "hasOwn", 2, fn _, args ->
      o = object!(arg(args, 0))
      has_own?(o, to_key(arg(args, 1)))
    end)

    def_fn(obj, "getOwnPropertySymbols", 1, fn _, args ->
      new_array(Props.own_symbols(object!(arg(args, 0))))
    end)

    def_fn(proto, "hasOwnProperty", 1, fn this, args ->
      key = to_key(arg(args, 0))
      has_own?(object!(this), key)
    end)

    def_fn(proto, "propertyIsEnumerable", 1, fn this, args ->
      key = to_key(arg(args, 0))
      o = object!(this)
      enumerable_own?(o, key)
    end)

    def_fn(proto, "valueOf", 0, fn this, _ -> to_object(this) end)
    :ok
  end

  defp def_fn(obj, name, arity, fun) do
    f = native(name, fun)
    set_arity(f, arity)
    put_hidden(obj, name, f)
  end

  # RequireObjectCoercible: keeps strings as they are (their own keys are the characters)
  defp object!(v) when v in [:undefined, :null],
    do: throw_error("TypeError", "Cannot convert undefined or null to object")

  defp object!(v), do: v

  defp to_object({:obj, _} = o), do: o
  defp to_object(v), do: v |> object!() |> Builtins.box()

  defp enumerable_keys(o), do: Props.enumerable_own_keys(o) |> Enum.filter(&is_binary/1)

  # a proxy is asked for its keys once, then for each key's descriptor and value in turn
  defp entries_of(o, build) do
    if proxy?(o) do
      for k <- Props.own_names(o), enumerable_own?(o, k), do: build.(k, get(o, k))
    else
      for k <- enumerable_keys(o), live_enumerable?(o, k), do: build.(k, get(o, k))
    end
  end

  defp proxy?({:obj, id}), do: Map.has_key?(deref(id), :proxy)
  defp proxy?(_), do: false

  # A proxy answers through its getOwnPropertyDescriptor trap, so it needs the descriptor.
  # Any other object does not: `Props.descriptor/2` gives :undefined exactly when the state
  # of the key is nil, which is `Props.has_own?/2`, and that makes no descriptor object
  # (fast path `:has_own`).
  defp has_own?({:obj, id} = o, key) do
    case deref(id) do
      %{proxy: _} ->
        Props.descriptor(o, key) != :undefined

      # A module namespace reads the binding: a binding in its TDZ throws, and a deferred
      # namespace evaluates its module, which runs user code. The shadow run must not run
      # user code, so a namespace takes the old path, as a proxy does.
      %{host: {Browser.JS.Modules, _}} ->
        Props.descriptor(o, key) != :undefined

      _ ->
        if Fast.on?(:has_own),
          do: Fast.shadow(id, Props.has_own?(o, key), Props.descriptor(o, key) != :undefined),
          else: Props.descriptor(o, key) != :undefined
    end
  end

  defp has_own?(o, key), do: Props.descriptor(o, key) != :undefined

  defp enumerable_own?(o, key) do
    case Props.descriptor(o, key) do
      :undefined -> false
      d -> truthy(get(d, "enumerable"))
    end
  end

  # a key that an earlier getter may have removed or made non-enumerable since the keys were read
  defp live_enumerable?({:obj, id} = o, key) do
    case deref(id) do
      %{proxy: _} -> true
      %{class: :host} -> true
      _ -> enumerable_own?(o, key)
    end
  end

  defp live_enumerable?(_, _), do: true

  # A plain object: a record of class `:object` that is not a proxy and not a primitive
  # wrapper. Its own keys are only the keys in the record.
  defguardp plain?(o)
            when :erlang.map_get(:class, o) == :object and not is_map_key(o, :proxy) and
                   not is_map_key(o, :prim)

  # A plain source (`plain_keys/1`) gives its keys from one list, and the loop reads each
  # value from the record (fast path `:assign`). Any other source takes the generic path.
  defp assign(target, sources) do
    {:obj, id} = to = to_object(target)

    for s <- sources, s not in [:undefined, :null] do
      from = if is_binary(s) or match?({:obj, _}, s), do: s, else: Builtins.box(s)

      case if(Fast.on?(:assign), do: plain_keys(from)) do
        nil -> for k <- source_keys(from), do: assign_key(id, to, k, get(from, k))
        keys -> assign_plain(id, to, from, keys)
      end
    end

    to
  end

  # An empty plain target (`Object.assign({}, source)`) takes the shape and the values of
  # the source in one step (`Obj.copy_plain/2`) when no key meets a setter or a read-only
  # key on its prototype chain. Else each key is a [[Set]] of its own.
  defp assign_plain(id, to, {:obj, sid} = from, keys) do
    t = deref(id)

    with true <- plain?(t),
         %{} = o <- Obj.copy_plain(t, deref(sid)),
         true <- Enum.all?(keys, &plain_chain?(t.proto, &1)) do
      Fast.shadow(
        id,
        (
          store(id, o)
          true
        ),
        Enum.all?(keys, &Props.ordinary_set(to, &1, plain_value(from, &1), to))
      )
    else
      _ -> assign_each(id, to, from, keys)
    end
  end

  defp assign_each(id, to, from, [k | rest]) do
    assign_key(id, to, k, plain_value(from, k))
    assign_each(id, to, from, rest)
  end

  defp assign_each(_, _, _, []), do: :ok

  # The [[Set]] of one key. A write that cannot call JavaScript code (`plain_write/3`) stores
  # the record directly. Any other write (a setter, a proxy, a read-only key, a target or a
  # prototype that is not a plain object) takes the generic path.
  defp assign_key(id, to, k, v) do
    case if(Fast.on?(:assign), do: plain_write(deref(id), k, v)) do
      nil ->
        unless Props.ordinary_set(to, k, v, to),
          do: throw_error("TypeError", "Cannot assign to read only property '#{key_name(k)}'")

      o ->
        Fast.shadow(
          id,
          (
            store(id, o)
            true
          ),
          Props.ordinary_set(to, k, v, to)
        )
    end
  end

  # The enumerable keys of a plain source in the order of `source_keys/1`, or `nil`.
  # `Obj.plain_names/1` gives a list only when no enumerable key is an index or a symbol, so
  # the list has no index keys to put first and no symbols to add.
  defp plain_keys({:obj, id}) do
    case deref(id) do
      o when plain?(o) -> Obj.plain_names(o)
      _ -> nil
    end
  end

  defp plain_keys(_), do: nil

  # The value of `k` in a plain source. The record is read again for each key, because a
  # setter of the target can change the source. A getter or a key that is gone takes `get`.
  defp plain_value({:obj, id} = from, k) do
    o = deref(id)

    Obj.own_case o, k do
      {:ok, {:accessor, _, _}} -> get(from, k)
      {:ok, v} -> v
      :error -> get(from, k)
    end
  end

  # The record `t` after the [[Set]] of `k` to `v`, or `nil` when the write can call
  # JavaScript code or can fail. `t` must be a plain object, and `k` a string. An own key
  # must be a writable data property. A new key needs an extensible `t` and a prototype
  # chain of plain objects with no setter and no read-only property for `k`
  # (`plain_chain?/2`). So the key `__proto__` takes the generic path, because
  # `Object.prototype` has an accessor for it. A symbol takes the generic path too, which
  # makes a descriptor object for it, so that the heap ids stay the same.
  defp plain_write(t, k, v) when plain?(t) and is_binary(k) do
    Obj.own_case t, k do
      {:ok, {:accessor, _, _}} ->
        nil

      {:ok, _} ->
        if Obj.writable?(t, k), do: Obj.own_update(t, k, v)

      :error ->
        if Obj.extensible?(t) and plain_chain?(t.proto, k), do: Obj.own_add_assigned(t, k, v)
    end
  end

  defp plain_write(_, _, _), do: nil

  # Whether a [[Set]] of `k` that gets to the prototype `p` adds an own key to the receiver
  # and calls no JavaScript code.
  defp plain_chain?({:obj, pid}, k) do
    case deref(pid) do
      p when plain?(p) ->
        Obj.own_case p, k do
          {:ok, {:accessor, _, _}} -> false
          {:ok, _} -> Obj.writable?(p, k)
          :error -> plain_chain?(p.proto, k)
        end

      _ ->
        false
    end
  end

  defp plain_chain?(nil, _), do: true
  defp plain_chain?(_, _), do: false

  # A proxy is asked for its keys, then each key's descriptor, in order. For any other
  # source, `Interp.own_keys/1` gives the enumerable string keys in the order of
  # `Props.enumerable_own_keys/1`, and the symbols come after them.
  defp source_keys(from) do
    if proxy?(from) do
      all = for k <- Props.all_own_keys(from), enumerable_own?(from, k), do: k
      {strings, symbols} = Enum.split_with(all, &is_binary/1)
      strings ++ symbols
    else
      Interp.own_keys(from) ++ Props.enumerable_symbols(from)
    end
  end

  defp key_name({:symbol, _, d}), do: d
  defp key_name(k), do: k

  defp from_entries(iterable) do
    object!(iterable)
    obj = new_object()

    case Interp.iter_source(iterable) do
      {:list, items} ->
        Enum.each(items, &add_entry(obj, &1))

      {:proto, it, next} ->
        loop = fn loop ->
          case Interp.iter_step(it, next) do
            :done ->
              :ok

            {:ok, item} ->
              try do
                add_entry(obj, item)
              catch
                {:js_error, _} = err ->
                  Interp.iter_close(it, true)
                  throw(err)
              end

              loop.(loop)
          end
        end

        loop.(loop)
    end

    obj
  end

  defp add_entry(obj, {:obj, _} = item) do
    k = get(item, "0")
    v = get(item, "1")
    define_data(obj, to_key(k), v)
  end

  defp add_entry(_, item),
    do: throw_error("TypeError", "Iterator value #{inspect_value(item)} is not an entry object")

  defp inspect_value(v) when is_binary(v), do: v
  defp inspect_value(v), do: to_str(v)
end
