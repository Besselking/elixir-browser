defmodule Browser.JS.ObjectStatics do
  @moduledoc """
  `Object.keys`, `values`, `entries`, `assign`, `fromEntries`, `hasOwn`, and the
  `Object.prototype` methods `hasOwnProperty`, `propertyIsEnumerable`, `valueOf`, following the
  specification's order of observable operations.
  """

  import Browser.JS.Interp, except: [get: 2, put: 3]
  alias Browser.JS.{Builtins, Interp, Props}

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

  defp assign(target, sources) do
    to = to_object(target)

    for s <- sources, s not in [:undefined, :null] do
      from = if is_binary(s) or match?({:obj, _}, s), do: s, else: Builtins.box(s)

      for k <- source_keys(from) do
        unless Props.ordinary_set(to, k, get(from, k), to),
          do: throw_error("TypeError", "Cannot assign to read only property '#{key_name(k)}'")
      end
    end

    to
  end

  # a proxy is asked for its keys, then each key's descriptor, in order
  defp source_keys(from) do
    if proxy?(from) do
      all = for k <- Props.all_own_keys(from), enumerable_own?(from, k), do: k
      {strings, symbols} = Enum.split_with(all, &is_binary/1)
      strings ++ symbols
    else
      Enum.filter(Props.enumerable_own_keys(from), &is_binary/1) ++ Props.enumerable_symbols(from)
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
