defmodule Browser.JS.Interp do
  @moduledoc """
  A tree-walking evaluator for the syntax tree from `Browser.JS.Parser`.

  Everything runs inside one process, which owns the "heap" (objects and scopes, kept in the
  process dictionary under integer ids). Use `Browser.JS.eval/2` rather than calling this
  directly; it sets that process up, installs the built-ins and tears it down.

  ## Values

  | JavaScript   | Elixir                                              |
  |--------------|-----------------------------------------------------|
  | number       | float, or `:nan` / `:infinity` / `:neg_infinity`    |
  | string       | binary (UTF-8; indices and lengths count code points, not UTF-16 units) |
  | boolean      | `true` / `false`                                    |
  | `undefined`  | `:undefined`                                        |
  | `null`       | `:null`                                             |
  | object, array, function | `{:obj, id}` into the heap               |

  ## Control flow

  `return`, `break`, `continue` and `throw` are Elixir throws (`{:js_return, v}`,
  `{:js_break, label}`, `{:js_continue, label}`, `{:js_error, value}`); `:js_limit` aborts a
  script that ran out of steps and can't be caught from JavaScript.
  """

  alias Browser.JS.Num

  @max_depth 1000

  # ── heap ───────────────────────────────────────────────────

  @doc "Starts a fresh heap in this process. `max_steps` bounds how much work a script may do."
  def init(max_steps) do
    Process.put(:js_heap, %{})
    Process.put(:js_next, 0)
    Process.put(:js_steps, max_steps)
    Process.put(:js_depth, 0)
    Process.put(:js_last, :undefined)
    Process.put(:js_fns, 0)
  end

  def alloc(obj) do
    id = Process.get(:js_next)
    Process.put(:js_next, id + 1)
    Process.put(:js_heap, Map.put(Process.get(:js_heap), id, obj))
    id
  end

  def deref(id), do: Map.fetch!(Process.get(:js_heap), id)
  def store(id, obj), do: Process.put(:js_heap, Map.put(Process.get(:js_heap), id, obj))

  @doc "The built-in prototype object registered under `name` (`:object`, `:array`, ...)."
  def proto(name), do: Process.get({:proto, name})
  def put_proto(name, val), do: Process.put({:proto, name}, val)

  def global, do: Process.get(:js_global)

  @doc "A plain object with the given `{key, value}` pairs."
  def new_object(pairs \\ [], proto \\ nil) do
    props = Map.new(pairs)
    keys = pairs |> Enum.map(&elem(&1, 0)) |> Enum.reverse()

    {:obj,
     alloc(%{
       class: :object,
       props: props,
       keys: keys,
       proto: if(proto == :null, do: nil, else: proto || proto(:object))
     })}
  end

  def new_array(list) do
    {:obj,
     alloc(%{
       class: :array,
       items: items_map(list),
       len: length(list),
       props: %{},
       keys: [],
       proto: proto(:array)
     })}
  end

  defp items_map(list), do: list |> Enum.with_index() |> Map.new(fn {v, i} -> {i, v} end)

  @doc """
  An object backed by Elixir: reads and writes of its properties go to `mod.host_get/3` and
  `mod.host_put/4` first (`{:ok, value}` / `:ok`, or `:miss` to fall back to ordinary
  properties and the prototype chain, where its methods live).
  """
  def new_host(mod, data, proto) do
    {:obj, alloc(%{class: :host, host: {mod, data}, props: %{}, keys: [], proto: proto})}
  end

  def native(name, fun) do
    {:obj,
     alloc(%{
       class: :function,
       fun: {:native, name, fun},
       props: %{},
       keys: [],
       proto: proto(:function)
     })}
  end

  def make_error(type, message) do
    err = new_object([{"message", message}], proto({:error, type}))
    put_hidden(err, "stack", stack_string("#{type}: #{message}"))
    err
  end

  @doc "`Error.stack`: the header and the names of the functions being run, innermost first."
  def stack_string(header) do
    frames =
      Process.get(:js_stack, [])
      |> Enum.take(12)
      |> Enum.map(fn name ->
        "\n    at " <> if(is_binary(name) and name != "", do: name, else: "<anonymous>")
      end)

    header <> Enum.join(frames)
  end

  def throw_error(type, message), do: throw({:js_error, make_error(type, message)})

  @doc false
  def new_scope(parent) do
    alloc(%{scope: true, vars: %{}, consts: MapSet.new(), parent: parent})
  end

  def new_global_scope do
    id = new_scope(nil)
    Process.put(:js_global, id)
    id
  end

  def declare(scope, name, val, const? \\ false) do
    s = deref(scope)

    store(scope, %{
      s
      | vars: Map.put(s.vars, name, val),
        consts: if(const?, do: MapSet.put(s.consts, name), else: s.consts)
    })
  end

  defp lookup_var(nil, _), do: :error

  defp lookup_var(scope, name) do
    s = deref(scope)

    case s.vars do
      %{^name => v} ->
        {:ok, v}

      _ ->
        case s do
          %{with: obj} when is_binary(name) ->
            if has_property?(obj, name),
              do: {:ok, get(obj, name)},
              else: lookup_var(s.parent, name)

          _ ->
            lookup_var(s.parent, name)
        end
    end
  end

  defp assign_var(scope, name, val) do
    s = deref(scope)

    cond do
      Map.has_key?(s.vars, name) ->
        if MapSet.member?(s.consts, name),
          do: throw_error("TypeError", "Assignment to constant variable.")

        store(scope, %{s | vars: Map.put(s.vars, name, val)})

      is_binary(name) and is_map_key(s, :with) and has_property?(s.with, name) ->
        put(s.with, name, val)

      s.parent != nil ->
        assign_var(s.parent, name, val)

      true ->
        # an undeclared variable becomes a global
        store(scope, %{s | vars: Map.put(s.vars, name, val)})
    end
  end

  @doc false
  def copy_scope(src, parent) do
    s = deref(src)
    alloc(%{s | parent: parent})
  end

  # ── conversions ────────────────────────────────────────────

  def num?(x), do: is_number(x) or x in [:nan, :infinity, :neg_infinity]
  def nullish?(x), do: x == :undefined or x == :null

  def function?({:obj, id}), do: deref(id).class == :function
  def function?(_), do: false

  def truthy(v) when v in [false, :undefined, :null, :nan, ""], do: false
  def truthy(v) when is_number(v), do: v != 0
  def truthy(_), do: true

  def typeof(:undefined), do: "undefined"
  def typeof(:null), do: "object"
  def typeof(v) when is_boolean(v), do: "boolean"
  def typeof(v) when is_binary(v), do: "string"
  def typeof({:obj, _} = v), do: if(function?(v), do: "function", else: "object")
  def typeof({:symbol, _, _}), do: "symbol"
  def typeof(v), do: if(num?(v), do: "number", else: "object")

  def to_num(v) when is_number(v), do: v
  def to_num(v) when v in [:nan, :infinity, :neg_infinity], do: v

  def to_num({:symbol, _, _}),
    do: throw_error("TypeError", "Cannot convert a Symbol value to a number")

  def to_num(:undefined), do: :nan
  def to_num(:null), do: 0.0
  def to_num(true), do: 1.0
  def to_num(false), do: 0.0
  def to_num(v) when is_binary(v), do: Num.parse(v)
  def to_num({:obj, _} = v), do: v |> to_primitive("number") |> to_num()

  @doc "ToIntegerOrInfinity, clamped to a large integer so callers can compare freely."
  def to_int(v) do
    case to_num(v) do
      :nan -> 0
      :infinity -> 1_000_000_000_000
      :neg_infinity -> -1_000_000_000_000
      n -> trunc(n)
    end
  end

  def to_str(v) when is_binary(v), do: v

  def to_str({:symbol, _, _}),
    do: throw_error("TypeError", "Cannot convert a Symbol value to a string")

  def to_str(:undefined), do: "undefined"
  def to_str(:null), do: "null"
  def to_str(true), do: "true"
  def to_str(false), do: "false"
  def to_str(v) when is_number(v) or v in [:nan, :infinity, :neg_infinity], do: Num.to_string(v)
  def to_str({:obj, _} = v), do: v |> to_primitive("string") |> to_str()

  def to_key(k) when is_binary(k), do: k
  def to_key({:symbol, _, _} = k), do: k
  def to_key(k), do: to_str(k)

  def to_primitive({:obj, _} = o, hint) do
    order = if hint == "string", do: ["toString", "valueOf"], else: ["valueOf", "toString"]

    Enum.find_value(order, fn name ->
      f = get(o, name)

      if function?(f) do
        case call(f, o, []) do
          {:obj, _} -> nil
          prim -> {:ok, prim}
        end
      end
    end)
    |> case do
      {:ok, prim} -> prim
      nil -> throw_error("TypeError", "Cannot convert object to primitive value")
    end
  end

  def to_primitive(v, _), do: v

  # ── equality and comparison ────────────────────────────────

  def strict_eq(a, b) do
    if num?(a) and num?(b), do: Num.equal?(a, b), else: a === b
  end

  def loose_eq(a, b) do
    cond do
      nullish?(a) and nullish?(b) -> true
      nullish?(a) or nullish?(b) -> false
      num?(a) and num?(b) -> Num.equal?(a, b)
      is_binary(a) and is_binary(b) -> a == b
      is_boolean(a) -> loose_eq(to_num(a), b)
      is_boolean(b) -> loose_eq(a, to_num(b))
      num?(a) and is_binary(b) -> Num.equal?(a, to_num(b))
      is_binary(a) and num?(b) -> Num.equal?(to_num(a), b)
      match?({:obj, _}, a) and match?({:obj, _}, b) -> a == b
      match?({:obj, _}, a) -> loose_eq(to_primitive(a, "default"), b)
      match?({:obj, _}, b) -> loose_eq(a, to_primitive(b, "default"))
      true -> false
    end
  end

  # SameValueZero, for includes()
  def same_value_zero(a, b) do
    (a == :nan and b == :nan) or strict_eq(a, b)
  end

  defp compare(a, b) do
    a = to_primitive(a, "number")
    b = to_primitive(b, "number")

    if is_binary(a) and is_binary(b) do
      cond do
        a < b -> :lt
        a > b -> :gt
        true -> :eq
      end
    else
      Num.compare(to_num(a), to_num(b))
    end
  end

  # ── properties ─────────────────────────────────────────────

  defp index(k) when is_number(k) and k >= 0 and k == trunc(k), do: trunc(k)

  defp index(k) when is_binary(k) do
    case Integer.parse(k) do
      {i, ""} when i >= 0 -> if Integer.to_string(i) == k, do: i
      _ -> nil
    end
  end

  defp index(_), do: nil

  def get({:obj, id} = obj, {:private, _} = key) do
    case Map.fetch(deref(id).props, key) do
      {:ok, {:accessor, g, _}} ->
        if function?(g),
          do: call(g, obj, []),
          else: throw_error("TypeError", "'#x' was defined without a getter")

      {:ok, v} ->
        v

      :error ->
        throw_error(
          "TypeError",
          "Cannot read private member from an object whose class did not declare it"
        )
    end
  end

  def get({:obj, id}, key) do
    o = deref(id)

    case o.class do
      :array ->
        case index(key) do
          i when is_integer(i) ->
            case o.items do
              %{^i => {:accessor, g, _}} ->
                if function?(g), do: call(g, {:obj, id}, []), else: :undefined

              %{^i => v} ->
                v

              _ ->
                lookup(o, to_key(key), {:obj, id})
            end

          nil ->
            if key == "length", do: o.len * 1.0, else: lookup(o, to_key(key), {:obj, id})
        end

      :function ->
        key = to_key(key)

        case lookup(o, key, {:obj, id}) do
          :undefined -> function_prop(id, o, key)
          v -> v
        end

      :host ->
        key = to_key(key)
        {mod, data} = o.host

        case mod.host_get(data, key, {:obj, id}) do
          {:ok, v} -> v
          :miss -> lookup(o, key, {:obj, id})
        end

      _ ->
        lookup(o, to_key(key), {:obj, id})
    end
  end

  def get(s, key) when is_binary(s) do
    case {index(key), key} do
      {i, _} when is_integer(i) -> Browser.JS.Str.at(s, i) || :undefined
      {_, "length"} -> Browser.JS.Str.length(s) * 1.0
      _ -> lookup(deref(elem(proto(:string), 1)), to_key(key), s)
    end
  end

  def get(n, key) when is_number(n) or n in [:nan, :infinity, :neg_infinity],
    do: lookup(deref(elem(proto(:number), 1)), to_key(key), n)

  def get({:symbol, _, _} = s, key), do: lookup(deref(elem(proto(:symbol), 1)), to_key(key), s)

  def get(b, key) when is_boolean(b),
    do: lookup(deref(elem(proto(:boolean), 1)), to_key(key), b)

  def get(v, key),
    do:
      throw_error(
        "TypeError",
        "Cannot read properties of #{to_str(v)} (reading '#{to_str(key)}')"
      )

  # a property found along the prototype chain; a getter is called with the object it was
  # asked of as `this`
  defp lookup(o, key, receiver) do
    case o.props do
      %{^key => {:accessor, getter, _}} ->
        if function?(getter), do: call(getter, receiver, []), else: :undefined

      %{^key => v} ->
        v

      _ ->
        case o.proto do
          {:obj, pid} -> lookup(deref(pid), key, receiver)
          _ -> :undefined
        end
    end
  end

  defp function_prop(id, %{generator: true} = o, "prototype") do
    p = new_object([], proto(if Map.get(o, :async), do: :async_generator, else: :generator))
    put_hidden({:obj, id}, "prototype", p)
    p
  end

  defp function_prop(id, o, "prototype") do
    case o.fun do
      {:closure, %{name: {:method, _}}} ->
        :undefined

      {:closure, %{mode: mode}} when mode in [false, nil] ->
        p = new_object()
        put_hidden(p, "constructor", {:obj, id})
        put_hidden({:obj, id}, "prototype", p)
        p

      {:native, _, _} ->
        :undefined

      _ ->
        :undefined
    end
  end

  defp function_prop(_id, %{fun: {:closure, c}}, "name"),
    do:
      if(is_binary(c.name),
        do: c.name,
        else:
          case c.name do
            {:method, n} when is_binary(n) -> n
            _ -> ""
          end
      )

  defp function_prop(_id, %{fun: {:native, name, _}}, "name"), do: name

  defp function_prop(_id, %{fun: {:closure, c}}, "length"),
    do:
      Enum.count(c.params, &(not match?({:rest, _}, &1) and not match?({:default, _, _}, &1))) *
        1.0

  defp function_prop(_id, _o, _key), do: :undefined

  @doc "Sets an own property without making it show up in `Object.keys`."
  def put_hidden({:obj, id}, key, v) do
    o = deref(id)
    store(id, %{o | props: Map.put(o.props, key, v)})
  end

  def put({:obj, id} = obj, {:private, _} = key, v) do
    o = deref(id)

    case Map.fetch(o.props, key) do
      {:ok, {:accessor, _, setter}} ->
        if function?(setter),
          do: call(setter, obj, [v]),
          else: throw_error("TypeError", "'#x' was defined without a setter")

        :ok

      {:ok, _} ->
        store(id, %{o | props: Map.put(o.props, key, v)})

      :error ->
        throw_error(
          "TypeError",
          "Cannot write private member to an object whose class did not declare it"
        )
    end
  end

  def put({:obj, id}, key, v) do
    o = deref(id)

    case o do
      %{class: :array} ->
        case index(key) do
          i when is_integer(i) ->
            cond do
              match?(%{^i => {:accessor, _, _}}, o.items) ->
                {:accessor, _, setter} = o.items[i]
                if function?(setter), do: call(setter, {:obj, id}, [v])
                :ok

              Map.get(o, :frozen, false) ->
                :ok

              not Map.get(o, :ext, true) and not Map.has_key?(o.items, i) ->
                :ok

              i >= o.len and Map.get(o, :len_ro, false) ->
                :ok

              not writable?(o, i) ->
                :ok

              true ->
                store(id, %{o | items: Map.put(o.items, i, v), len: max(o.len, i + 1)})
            end

          nil ->
            if key == "length" do
              new_len = to_int(v)

              cond do
                Map.get(o, :frozen, false) or Map.get(o, :len_ro, false) ->
                  :ok

                true ->
                  # an element that cannot be deleted stops the array from shrinking past it
                  attrs = Map.get(o, :attrs, %{})

                  stop =
                    o.items
                    |> Map.keys()
                    |> Enum.filter(
                      &(&1 >= new_len and Map.get(Map.get(attrs, &1, %{}), :c, true) == false)
                    )
                    |> Enum.max(fn -> nil end)
                    |> then(&if(&1, do: &1 + 1, else: new_len))

                  store(id, %{
                    o
                    | items: Map.filter(o.items, fn {i, _} -> i < stop end),
                      len: stop
                  })
              end
            else
              put_prop(id, o, to_key(key), v)
            end
        end

      %{class: :host, host: {mod, data}} ->
        key = to_key(key)

        case mod.host_put(data, key, v, {:obj, id}) do
          :ok -> :ok
          :miss -> put_prop(id, o, key, v)
        end

      _ ->
        put_prop(id, o, to_key(key), v)
    end

    v
  end

  def put(v, key, _) when v in [:undefined, :null],
    do:
      throw_error("TypeError", "Cannot set properties of #{to_str(v)} (setting '#{to_str(key)}')")

  def put(_primitive, _key, v), do: v

  # an assignment: own accessor or non-writable property, inherited ones, then a new property
  defp put_prop(id, o, key, v) do
    case Map.fetch(o.props, key) do
      {:ok, {:accessor, _, setter}} ->
        if function?(setter), do: call(setter, {:obj, id}, [v])
        :ok

      {:ok, _} ->
        if writable?(o, key), do: store(id, %{o | props: Map.put(o.props, key, v)}), else: :ok

      :error ->
        case inherited_set(o.proto, key) do
          {:setter, setter} ->
            call(setter, {:obj, id}, [v])
            :ok

          :readonly ->
            :ok

          :none ->
            if Map.get(o, :ext, true),
              do:
                store(id, %{
                  o
                  | props: Map.put(o.props, key, v),
                    # a symbol-keyed property is not listed by Object.keys or for-in
                    keys: if(is_binary(key), do: [key | o.keys], else: o.keys)
                }),
              else: :ok
        end
    end
  end

  defp inherited_set({:obj, pid}, key) do
    p = deref(pid)

    case p.props do
      %{^key => {:accessor, _, setter}} ->
        if function?(setter), do: {:setter, setter}, else: :readonly

      %{^key => _} ->
        if writable?(p, key), do: :none, else: :readonly

      _ ->
        inherited_set(p.proto, key)
    end
  end

  defp inherited_set(_, _), do: :none

  @doc false
  def writable?(o, key), do: match?(%{w: true}, Map.get(Map.get(o, :attrs, %{}), key, %{w: true}))

  @doc false
  def configurable?(o, key),
    do: match?(%{c: true}, Map.get(Map.get(o, :attrs, %{}), key, %{c: true}))

  @doc false
  def array_index(key), do: index(key)

  def delete({:obj, id}, key) do
    o = deref(id)

    case o do
      %{class: :host, host: {mod, data}} ->
        if function_exported?(mod, :host_delete, 2),
          do: mod.host_delete(data, to_key(key)),
          else: delete_plain(id, o, key)

      _ ->
        delete_plain(id, o, key)
    end
  end

  def delete(_, _), do: true

  defp delete_plain(id, o, key) do
    i = if o.class == :array, do: index(key)

    cond do
      i && not configurable?(o, i) && Map.has_key?(o.items, i) ->
        false

      i ->
        store(id, %{o | items: Map.delete(o.items, i)})
        true

      true ->
        key = to_key(key)

        if Map.has_key?(o.props, key) and not configurable?(o, key) do
          false
        else
          attrs = Map.delete(Map.get(o, :attrs, %{}), key)

          store(
            id,
            %{
              o
              | props: Map.delete(o.props, key),
                keys: List.delete(o.keys, key)
            }
            |> Map.put(:attrs, attrs)
          )

          true
        end
    end
  end

  def has_property?({:obj, id}, key) do
    o = deref(id)
    key_s = to_key(key)

    cond do
      # what a host object answers for is there (`"foo" in window`)
      o.class == :host and host_has?(o, id, key_s) ->
        true

      o.class == :array and key_s == "length" ->
        true

      o.class == :array and is_integer(index(key)) ->
        Map.has_key?(o.items, index(key)) or
          (match?({:obj, _}, o.proto) and has_property?(o.proto, key_s))

      Map.has_key?(o.props, key_s) ->
        true

      match?({:obj, _}, o.proto) ->
        has_property?(o.proto, key_s)

      true ->
        false
    end
  end

  def has_property?(_, _),
    do: throw_error("TypeError", "Cannot use 'in' operator to search for a key in a non-object")

  defp host_has?(%{host: {mod, data}}, id, key) do
    if function_exported?(mod, :host_has, 2),
      do: mod.host_has(data, key),
      else: match?({:ok, v} when v != :undefined, mod.host_get(data, key, {:obj, id}))
  end

  @doc "Own enumerable string keys, in insertion order (array indices first)."
  def own_keys({:obj, id}) do
    o = deref(id)

    case o do
      %{class: :host, host: {mod, data}} ->
        if function_exported?(mod, :host_keys, 1),
          do: mod.host_keys(data),
          else: own_keys_plain(o)

      _ ->
        own_keys_plain(o)
    end
  end

  def own_keys(s) when is_binary(s),
    do: for(i <- 0..(String.length(s) - 1)//1, do: Integer.to_string(i))

  def own_keys(_), do: []

  defp own_keys_plain(o) do
    base = Enum.reverse(o.keys)

    case o do
      %{class: :array} ->
        for(i <- 0..(o.len - 1)//1, Map.has_key?(o.items, i), do: Integer.to_string(i)) ++ base

      _ ->
        {ints, rest} = Enum.split_with(base, &is_integer(index(&1)))
        Enum.sort_by(ints, &index/1) ++ rest
    end
  end

  def array_list({:obj, id}) do
    o = deref(id)

    for i <- 0..(o.len - 1)//1 do
      case Map.get(o.items, i, :undefined) do
        {:accessor, g, _} -> if function?(g), do: call(g, {:obj, id}, []), else: :undefined
        v -> v
      end
    end
  end

  def set_array_list({:obj, id}, list) do
    o = deref(id)
    store(id, %{o | items: items_map(list), len: length(list)})
  end

  def array?({:obj, id}), do: deref(id).class == :array
  def array?(_), do: false

  def iterate({:obj, id} = v) do
    o = deref(id)

    cond do
      o.class == :array -> array_list(v)
      o.class in [:map, :set] -> Browser.JS.Collections.entries(o)
      true -> iterate_protocol(v)
    end
  end

  def iterate(s) when is_binary(s), do: String.codepoints(s)
  def iterate(v), do: throw_error("TypeError", "#{to_str(v)} is not iterable")

  @doc false
  # what `for of` loops over: a list that is known up front (arrays, strings, Map, Set), or an
  # iterator object to pull from one value at a time, so that an endless generator can be left
  # with `break`
  def iter_source({:obj, id} = v) do
    o = deref(id)

    if o.class in [:array, :map, :set] do
      {:list, iterate(v)}
    else
      case get(v, {:symbol, :iterator, "Symbol.iterator"}) do
        f when is_tuple(f) ->
          unless function?(f), do: throw_error("TypeError", "object is not iterable")
          it = call(f, v, [])
          {:proto, it, get(it, "next")}

        _ ->
          throw_error("TypeError", "object is not iterable")
      end
    end
  end

  def iter_source(v), do: {:list, iterate(v)}

  @doc false
  # one step of an iterator: `{:ok, value}` or `:done`
  def iter_step(it, next) do
    r = call(next, it, [])

    unless match?({:obj, _}, r),
      do: throw_error("TypeError", "Iterator result is not an object")

    if truthy(get(r, "done")), do: :done, else: {:ok, get(r, "value")}
  end

  @doc false
  # leaves an iterator early: calls its `return` method. After a throw the error from `return`
  # is dropped in favour of the original one.
  def iter_close(it, after_throw?) do
    try do
      case get(it, "return") do
        f when is_tuple(f) -> if function?(f), do: call(f, it, [])
        _ -> :ok
      end
    catch
      {:js_error, _} when after_throw? -> :ok
    end
  end

  defp proto_loop(it, next, {pat, mode, body, env} = spec, labels) do
    case iter_step(it, next) do
      :done ->
        :ok

      {:ok, item} ->
        tick()
        iter_env = new_scope(env)

        result =
          try do
            bind(pat, item, iter_env, mode)
            run_body(body, iter_env, labels)
          catch
            kind, e ->
              iter_close(it, true)
              :erlang.raise(kind, e, __STACKTRACE__)
          end

        case result do
          :break ->
            iter_close(it, false)
            :ok

          :next ->
            proto_loop(it, next, spec, labels)
        end
    end
  end

  # anything with a `[Symbol.iterator]` method: call it and pull values until it is done
  defp iterate_protocol(v) do
    case get(v, {:symbol, :iterator, "Symbol.iterator"}) do
      f when is_tuple(f) ->
        if function?(f) do
          it = call(f, v, [])
          pull(it, get(it, "next"), [])
        else
          throw_error("TypeError", "object is not iterable")
        end

      _ ->
        throw_error("TypeError", "object is not iterable")
    end
  end

  defp pull(it, next, acc) do
    r = call(next, it, [])

    unless match?({:obj, _}, r),
      do: throw_error("TypeError", "Iterator result is not an object")

    if truthy(get(r, "done")) do
      Enum.reverse(acc)
    else
      tick()
      pull(it, next, [get(r, "value") | acc])
    end
  end

  # ── calling ────────────────────────────────────────────────

  def call({:obj, id}, this, args) do
    case deref(id) do
      %{class_info: info} ->
        throw_error(
          "TypeError",
          "Class constructor #{info.name || ""} cannot be invoked without 'new'"
        )

      %{class: :function, fun: {:native, _, fun}} ->
        tick()
        fun.(this, args)

      %{class: :function, fun: {:closure, c}, generator: true, async: true} ->
        tick()
        Browser.JS.Async.call_async_generator({:obj, id}, c, this, args)

      %{class: :function, fun: {:closure, c}, generator: true} ->
        tick()
        Browser.JS.Async.call_generator({:obj, id}, c, this, args)

      %{class: :function, fun: {:closure, c}, async: true} ->
        tick()
        Browser.JS.Async.call_closure(c, this, args)

      %{class: :function, fun: {:closure, c}} ->
        tick()
        run_closure(c, this, args)

      _ ->
        throw_error("TypeError", "value is not a function")
    end
  end

  def call(_, _, _), do: throw_error("TypeError", "value is not a function")

  def construct(f, args, new_target \\ nil)

  def construct({:obj, id} = f, args, new_target) do
    unless function?(f), do: throw_error("TypeError", "value is not a constructor")

    if match?(%{fun: {:closure, %{mode: m}}} when m in [:arrow, :arrow_expr], deref(id)),
      do: throw_error("TypeError", "arrow function is not a constructor")

    if Map.get(deref(id), :generator),
      do: throw_error("TypeError", "generator is not a constructor")

    nt = new_target || f

    case Map.get(deref(id), :bound) do
      {target, bound_args} ->
        # a bound function constructs what it is bound to
        construct(
          target,
          bound_args ++ args,
          if(new_target in [nil, f], do: nil, else: new_target)
        )

      nil ->
        construct_plain(f, id, nt, new_target, args)
    end
  end

  def construct(_, _, _), do: throw_error("TypeError", "value is not a constructor")

  defp construct_plain({:obj, _} = f, id, nt, new_target, args) do
    case Map.get(deref(id), :class_info) do
      nil ->
        proto =
          case get(nt, "prototype") do
            {:obj, _} = p -> p
            _ -> proto(:object)
          end

        this = new_object([], proto)

        result =
          case deref(id) do
            %{fun: {:closure, _}, async: true} ->
              call(f, this, args)

            %{fun: {:closure, c}} ->
              tick()
              elem(run_closure_scope(c, this, args, [{:new_target, nt}]), 0)

            _ ->
              call(f, this, args)
          end

        case result do
          {:obj, rid} = result ->
            # a built-in that makes its own object (Error, Array, an element) gets the
            # prototype of the class that extended it
            if new_target != nil and result != this, do: store(rid, %{deref(rid) | proto: proto})
            result

          _ ->
            this
        end

      info ->
        Browser.JS.Classes.construct(f, info, args, nt)
    end
  end

  def instance_of?({:obj, _} = o, {:obj, _} = f) do
    unless function?(f),
      do: throw_error("TypeError", "Right-hand side of 'instanceof' is not callable")

    walk_protos(o, get(f, "prototype"))
  end

  def instance_of?(_, f) do
    unless function?(f),
      do: throw_error("TypeError", "Right-hand side of 'instanceof' is not callable")

    false
  end

  defp walk_protos({:obj, id}, target) do
    case deref(id).proto do
      {:obj, _} = p -> p == target or walk_protos(p, target)
      _ -> false
    end
  end

  @doc false
  def tick do
    n = Process.get(:js_steps) - 1
    if n < 0, do: throw(:js_limit)
    Process.put(:js_steps, n)
  end

  @doc false
  # the scope a function body runs in: `this`, the parameters, hoisted declarations
  def call_scope(c, this, args) do
    scope = new_scope(c.scope)

    if c.mode in [false, nil] do
      declare(scope, :this, sloppy_this(c, this))
      declare(scope, :args, args)
    end

    if h = Map.get(c, :home), do: declare(scope, :home, h)
    bind_params(c.params, args, scope)

    if c.mode != :arrow_expr do
      hoist_vars(c.body, scope)
      hoist_functions(c.body, scope)
    end

    scope
  end

  # Drops a scope from the heap once its code has run, unless a closure was created since
  # `fns` was read (`make_fn` counts them): only a closure can keep a scope alive past its code.
  defp free_scope(scope, fns) do
    if Process.get(:js_fns) == fns,
      do: Process.put(:js_heap, Map.delete(Process.get(:js_heap), scope))

    :ok
  end

  # A call's scope can only outlive the call through a closure created inside it (a function,
  # method, class or arrow all go through `make_fn`, which counts them). When none was, the
  # scope is garbage on return: dropping it keeps the heap from growing with every call.
  defp run_closure(c, this, args) do
    before = Process.get(:js_fns)
    {result, scope} = run_closure_scope(c, this, args, [])
    free_scope(scope, before)
    result
  end

  @doc false
  # runs a function body, also handing back its scope (a constructor reads `this` from it);
  # `extra` are more variables for the scope
  def run_closure_scope(c, this, args, extra) do
    depth = Process.get(:js_depth)
    if depth >= @max_depth, do: throw_error("RangeError", "Maximum call stack size exceeded")
    Process.put(:js_depth, depth + 1)
    stack = Process.get(:js_stack, [])
    Process.put(:js_stack, [c.name | stack])

    try do
      vars =
        if c.mode in [false, nil],
          do: %{this: sloppy_this(c, this), args: args, new_target: :undefined},
          else: %{}

      vars = if h = Map.get(c, :home), do: Map.put(vars, :home, h), else: vars
      vars = Enum.reduce(extra, vars, fn {k, v}, m -> Map.put(m, k, v) end)
      scope = alloc(%{scope: true, vars: vars, consts: MapSet.new(), parent: c.scope})
      bind_params(c.params, args, scope)

      result =
        case c.mode do
          :arrow_expr ->
            ev(c.body, scope)

          _ ->
            hoist_vars(c.body, scope)
            hoist_functions(c.body, scope)

            try do
              exec_list(c.body, scope)
              :undefined
            catch
              {:js_return, v} -> v
            end
        end

      {result, scope}
    after
      Process.put(:js_depth, depth)
      Process.put(:js_stack, stack)
    end
  end

  @doc false
  def make_function(node, env), do: make_fn(node, env)

  @doc false
  # sets a field of a function's closure (the `home` object of a method)
  def set_home({:obj, id}, home) do
    o = deref(id)

    case o.fun do
      {:closure, c} -> store(id, %{o | fun: {:closure, Map.put(c, :home, home)}})
      _ -> :ok
    end
  end

  @doc false
  def lookup_scoped(env, name), do: lookup_var(env, name)

  @doc false
  # the key a private name stands for in the class it is declared in
  def private_key(name, env) do
    case lookup_var(env, {:priv, name}) do
      {:ok, ref} ->
        {:private, ref}

      :error ->
        throw_error(
          "SyntaxError",
          "Private field '#' + #{name} must be declared in an enclosing class"
        )
    end
  end

  @doc false
  # the scope, along the chain from `env`, that holds the variable `name`
  def scope_of(nil, _), do: nil

  def scope_of(env, name) do
    s = deref(env)
    if Map.has_key?(s.vars, name), do: env, else: scope_of(s.parent, name)
  end

  @doc "A property read with a given `this` for getters (`super.x`)."
  def get_with_receiver({:obj, id}, key, receiver), do: lookup(deref(id), to_key(key), receiver)
  def get_with_receiver(_, _, _), do: :undefined

  defp bind_params([], _, _), do: :ok

  defp bind_params([{:rest, pat}], args, scope), do: bind(pat, new_array(args), scope, :let)

  defp bind_params([p | ps], args, scope) do
    {arg, rest} =
      case args do
        [a | r] -> {a, r}
        [] -> {:undefined, []}
      end

    bind(p, arg, scope, :let)
    bind_params(ps, rest, scope)
  end

  defp make_fn({:gen, fun}, env) do
    {:obj, id} = f = make_fn(fun, env)
    store(id, Map.put(deref(id), :generator, true))
    f
  end

  defp make_fn({:async, fun}, env) do
    {:obj, id} = f = make_fn(fun, env)
    store(id, Map.put(deref(id), :async, true))
    f
  end

  defp make_fn({:fn, name, params, body, mode}, env) do
    env =
      if is_binary(name) and mode == false do
        # a function expression can call itself by name
        s = new_scope(env)
        s
      else
        env
      end

    Process.put(:js_fns, Process.get(:js_fns) + 1)

    fun =
      {:obj,
       alloc(%{
         class: :function,
         fun: {:closure, %{name: name, params: params, body: body, mode: mode, scope: env}},
         props: %{},
         keys: [],
         proto: proto(:function)
       })}

    if is_binary(name) and mode == false and env != nil, do: declare(env, name, fun)
    fun
  end

  # A function that is not strict gets the global object for a `this` that is undefined or null
  # (a plain call): `(function () { this.x = 1 })()` sets a global. Without a global `this`
  # (no page) nothing changes.
  defp sloppy_this(c, this) when this in [:undefined, :null] do
    case c.body do
      [{:expr, {:str, "use strict"}} | _] ->
        this

      _ ->
        case lookup_var(global(), :this) do
          {:ok, w} -> w
          :error -> this
        end
    end
  end

  defp sloppy_this(_c, this), do: this

  # `arguments` is only built when a function body asks for it
  defp lazy_arguments(env) do
    case lookup_var(env, :args) do
      {:ok, args} ->
        a = new_array(args)
        owner = scope_with(env, :args)
        declare(owner, "arguments", a)
        a

      :error ->
        throw_error("ReferenceError", "arguments is not defined")
    end
  end

  defp scope_with(scope, name) do
    if Map.has_key?(deref(scope).vars, name),
      do: scope,
      else: scope_with(deref(scope).parent, name)
  end

  # ── hoisting ───────────────────────────────────────────────

  defp hoist_vars(stmts, scope) do
    case hoisted_names(stmts) do
      [] ->
        :ok

      names ->
        s = deref(scope)
        vars = Enum.reduce(names, s.vars, fn n, m -> Map.put_new(m, n, :undefined) end)
        store(scope, %{s | vars: vars})
    end
  end

  # the `var` names of a body, remembered: walking the syntax tree on every call is costly
  defp hoisted_names(stmts) do
    key = {:js_hoist, stmts}

    case Process.get(key) do
      nil ->
        names = stmts |> var_names([]) |> Enum.uniq()
        Process.put(key, names)
        names

      names ->
        names
    end
  end

  @doc false
  def var_names(stmts, acc) when is_list(stmts), do: Enum.reduce(stmts, acc, &var_names/2)

  def var_names({:var, :var, decls}, acc),
    do: Enum.reduce(decls, acc, fn {pat, _}, a -> pattern_names(pat, a) end)

  def var_names({:export, stmt}, acc), do: var_names(stmt, acc)
  def var_names({:if, _, a, b}, acc), do: var_names(b, var_names(a, acc))
  def var_names({:for, init, _, _, body}, acc), do: var_names(body, var_names(init, acc))

  def var_names({k, :var, pat, _, body}, acc) when k in [:forin, :forof],
    do: var_names(body, pattern_names(pat, acc))

  def var_names({k, _, _, _, body}, acc) when k in [:forin, :forof], do: var_names(body, acc)
  def var_names({:while, _, body}, acc), do: var_names(body, acc)
  def var_names({:dowhile, body, _}, acc), do: var_names(body, acc)
  def var_names({:block, stmts}, acc), do: var_names(stmts, acc)
  def var_names({:with, _, body}, acc), do: var_names(body, acc)
  def var_names({:labeled, _, s}, acc), do: var_names(s, acc)
  def var_names({:try, b, _, h, f}, acc), do: var_names(f, var_names(h, var_names(b, acc)))

  def var_names({:switch, _, cases}, acc),
    do: Enum.reduce(cases, acc, fn {_, body}, a -> var_names(body, a) end)

  def var_names(_, acc), do: acc

  @doc false
  def pattern_names({:id, n}, acc), do: [n | acc]
  def pattern_names({:default, p, _}, acc), do: pattern_names(p, acc)
  def pattern_names({:rest, p}, acc), do: pattern_names(p, acc)
  def pattern_names({:arrpat, elems}, acc), do: Enum.reduce(elems, acc, &pattern_names/2)

  def pattern_names({:objpat, props, rest}, acc) do
    acc = Enum.reduce(props, acc, fn {_, p}, a -> pattern_names(p, a) end)
    if rest, do: pattern_names(rest, acc), else: acc
  end

  def pattern_names(_, acc), do: acc

  @doc false
  def hoist_functions(stmts, scope) do
    for stmt <- stmts, {:fundecl, name, fun} <- [unexport(stmt)] do
      declare(scope, name, make_fn(fun, scope))
    end

    :ok
  end

  defp unexport({:export, stmt}), do: stmt
  defp unexport({:export_default, {:fundecl, _, _} = stmt}), do: stmt
  defp unexport(stmt), do: stmt

  # ── statements ─────────────────────────────────────────────

  @doc "Runs a whole program in the global scope; returns the completion value."
  def run_program({:program, stmts}) do
    scope = global()
    hoist_vars(stmts, scope)
    hoist_functions(stmts, scope)
    exec_list(stmts, scope)
    Browser.JS.Promise.run_microtasks()
    # (the process dictionary reports a stored :undefined as missing, hence the default)
    Process.get(:js_last, :undefined)
  end

  @doc """
  Runs a module in a scope of its own and returns its namespace object (the exports).
  `resolve` maps an import specifier to the namespace object of that module.
  """
  def run_module({:program, stmts}, resolve, base \\ nil) do
    scope = new_scope(global())
    if base, do: declare(scope, :module_url, base)

    for {:import, spec, bindings} <- stmts do
      ns = resolve.(spec)

      for b <- bindings do
        case b do
          {:default, local} -> declare(scope, local, get(ns, "default"))
          {:ns, local} -> declare(scope, local, ns)
          {:named, imported, local} -> declare(scope, local, get(ns, imported))
        end
      end
    end

    hoist_vars(stmts, scope)
    hoist_functions(stmts, scope)
    exec_list(stmts, scope)
    Browser.JS.Promise.run_microtasks()

    pairs =
      Enum.flat_map(stmts, fn
        {:export, {:var, _, decls}} ->
          decls
          |> Enum.reduce([], fn {pat, _}, a -> pattern_names(pat, a) end)
          |> Enum.reverse()
          |> Enum.map(&{&1, scope_value(scope, &1)})

        {:export, {:fundecl, name, _}} ->
          [{name, scope_value(scope, name)}]

        {:export_default, {:fundecl, name, _}} ->
          [{"default", scope_value(scope, name)}]

        {:export_default, {:expr, _}} ->
          [{"default", scope_value(scope, :default_export)}]

        {:export_names, names} ->
          for {local, exported} <- names, do: {exported, scope_value(scope, local)}

        {:export_from, spec, :all} ->
          ns = resolve.(spec)
          for k <- own_keys(ns), k != "default", do: {k, get(ns, k)}

        {:export_from, spec, names} ->
          ns = resolve.(spec)
          for {imported, exported} <- names, do: {exported, get(ns, imported)}

        _ ->
          []
      end)

    # a module namespace lists its names in code unit order
    pairs |> Enum.uniq_by(&elem(&1, 0)) |> Enum.sort_by(&elem(&1, 0)) |> new_object()
  end

  defp scope_value(scope, name) do
    case lookup_var(scope, name) do
      {:ok, v} -> v
      :error -> :undefined
    end
  end

  defp exec_list(stmts, env), do: Enum.each(stmts, &exec(&1, env, []))

  @doc false
  def exec_stmt(stmt, env, labels \\ []), do: exec(stmt, env, labels)

  defp exec(stmt, env), do: exec(stmt, env, [])

  defp exec({:expr, e}, env, _) do
    Process.put(:js_last, ev(e, env))
    :ok
  end

  defp exec({:var, kind, decls}, env, _) do
    for {pat, init} <- decls do
      cond do
        init != nil -> bind(pat, ev_named(init, env, pat), env, kind)
        kind == :var -> :ok
        true -> bind(pat, :undefined, env, kind)
      end
    end

    :ok
  end

  defp exec({:with, obj, body}, env, _) do
    o = ev(obj, env)

    if o in [:undefined, :null],
      do: throw_error("TypeError", "Cannot convert undefined or null to object")

    scope = new_scope(env)
    s = deref(scope)
    store(scope, Map.put(s, :with, if(match?({:obj, _}, o), do: o, else: new_object())))
    exec(body, scope, [])
  end

  defp exec({:fundecl, _, _}, _, _), do: :ok
  defp exec({:empty}, _, _), do: :ok
  defp exec({:import, _, _}, _, _), do: :ok
  defp exec({:export, stmt}, env, _), do: exec(stmt, env, [])
  defp exec({:export_default, {:fundecl, _, _}}, _, _), do: :ok
  defp exec({:export_default, {:expr, e}}, env, _), do: declare(env, :default_export, ev(e, env))
  defp exec({:export_names, _}, _, _), do: :ok
  defp exec({:export_from, _, _}, _, _), do: :ok

  defp exec({:block, stmts}, env, _) do
    fns = Process.get(:js_fns)
    scope = new_scope(env)
    hoist_functions(stmts, scope)
    result = exec_list(stmts, scope)
    free_scope(scope, fns)
    result
  end

  defp exec({:return, nil}, _, _), do: throw({:js_return, :undefined})
  defp exec({:return, e}, env, _), do: throw({:js_return, ev(e, env)})
  defp exec({:throw, e}, env, _), do: throw({:js_error, ev(e, env)})
  defp exec({:break, label}, _, _), do: throw({:js_break, label})
  defp exec({:continue, label}, _, _), do: throw({:js_continue, label})

  defp exec({:if, c, a, b}, env, _) do
    cond do
      truthy(ev(c, env)) -> exec(a, env)
      b != nil -> exec(b, env)
      true -> :ok
    end
  end

  defp exec({:labeled, l, s}, env, labels) do
    exec(s, env, [l | labels])
  catch
    {:js_break, ^l} -> :ok
  end

  defp exec({:while, c, body}, env, labels), do: while_loop(c, body, env, labels)

  defp exec({:dowhile, body, c}, env, labels) do
    case run_body(body, env, labels) do
      :break -> :ok
      :next -> while_loop(c, body, env, labels)
    end
  end

  defp exec({:for, init, test, update, body}, env, labels) do
    loop_env = new_scope(env)
    per_iteration? = match?({:var, :let, _}, init)

    case init do
      {:var, _, _} = d -> exec(d, loop_env)
      {:expr, e} -> ev(e, loop_env)
      nil -> :ok
    end

    first = if per_iteration?, do: copy_scope(loop_env, env), else: loop_env
    for_loop(test, update, body, env, first, per_iteration?, labels, Process.get(:js_fns))
  end

  defp exec({kind, decl, pat, obj, body}, env, labels) when kind in [:forin, :forof] do
    target = ev(obj, env)

    mode = if decl == nil, do: :assign, else: decl

    source =
      case kind do
        :forin -> {:list, if(nullish?(target), do: [], else: own_keys(target))}
        :forof -> iter_source(target)
      end

    case source do
      {:proto, it, next} ->
        proto_loop(it, next, {pat, mode, body, env}, labels)

      {:list, items} ->
        Enum.reduce_while(items, :ok, fn item, _ ->
          tick()
          fns = Process.get(:js_fns)
          iter_env = new_scope(env)
          bind(pat, item, iter_env, mode)
          outcome = run_body(body, iter_env, labels)
          free_scope(iter_env, fns)

          case outcome do
            :break -> {:halt, :ok}
            :next -> {:cont, :ok}
          end
        end)
    end
  end

  defp exec({:switch, disc, cases}, env, _) do
    v = ev(disc, env)
    scope = new_scope(env)
    all = Enum.flat_map(cases, fn {_, body} -> body end)
    hoist_functions(all, scope)

    start =
      Enum.find_index(cases, fn {test, _} ->
        test != :default and strict_eq(v, ev(test, scope))
      end) ||
        Enum.find_index(cases, fn {test, _} -> test == :default end)

    try do
      if start,
        do: cases |> Enum.drop(start) |> Enum.each(fn {_, body} -> exec_list(body, scope) end)

      :ok
    catch
      {:js_break, nil} -> :ok
    end
  end

  defp exec({:try, block, param, handler, finalizer}, env, _) do
    try do
      try do
        exec(block, env)
      catch
        {:js_error, v} when handler != nil ->
          scope = new_scope(env)
          if param, do: bind(param, v, scope, :let)
          exec(handler, scope)
      end
    after
      if finalizer, do: exec(finalizer, env)
    end
  end

  defp while_loop(c, body, env, labels) do
    if truthy(ev(c, env)) do
      tick()

      case run_body(body, env, labels) do
        :break -> :ok
        :next -> while_loop(c, body, env, labels)
      end
    else
      :ok
    end
  end

  # `fns` is the closure count from before this iteration's update expression ran (which
  # evaluates in the iteration's scope), so a closure made there keeps the scope alive too
  defp for_loop(test, update, body, env, iter_env, copy?, labels, fns) do
    tick()

    if test == nil or truthy(ev(test, iter_env)) do
      case run_body(body, iter_env, labels) do
        :break ->
          :ok

        :next ->
          next_env = if copy?, do: copy_scope(iter_env, env), else: iter_env
          if copy?, do: free_scope(iter_env, fns)
          next_fns = Process.get(:js_fns)
          if update, do: ev(update, next_env)
          for_loop(test, update, body, env, next_env, copy?, labels, next_fns)
      end
    else
      :ok
    end
  end

  # runs a loop body, translating break / continue aimed at this loop
  defp run_body(body, env, labels) do
    exec(body, env)
    :next
  catch
    {:js_break, l} = signal -> if l == nil or l in labels, do: :break, else: throw(signal)
    {:js_continue, l} = signal -> if l == nil or l in labels, do: :next, else: throw(signal)
  end

  # ── binding ────────────────────────────────────────────────

  @doc false
  def bind_pattern(pat, v, env, mode), do: bind(pat, v, env, mode)

  defp bind({:id, name}, v, env, mode), do: bind_name(mode, env, name, v)

  defp bind({:default, pat, e}, v, env, mode),
    do: bind(pat, if(v == :undefined, do: ev_named(e, env, pat), else: v), env, mode)

  defp bind({:arrpat, elems}, v, env, mode), do: bind_elems(elems, iterate(v), env, mode)

  defp bind({:objpat, props, rest}, v, env, mode) do
    if nullish?(v),
      do: throw_error("TypeError", "Cannot destructure '#{to_str(v)}' as it is #{to_str(v)}.")

    used =
      for {key, pat} <- props do
        k = key_of(key, env)
        bind(pat, get(v, k), env, mode)
        k
      end

    if rest do
      pairs = for k <- own_keys(v), k not in used, do: {k, get(v, k)}
      bind(rest, new_object(pairs), env, mode)
    end

    :ok
  end

  defp bind({:member, _, _, _} = target, v, env, :assign), do: assign_to(target, v, env)

  defp bind_elems([], _, _, _), do: :ok
  defp bind_elems([{:rest, pat}], list, env, mode), do: bind(pat, new_array(list), env, mode)

  defp bind_elems([p | ps], list, env, mode) do
    {v, rest} =
      case list do
        [h | t] -> {h, t}
        [] -> {:undefined, []}
      end

    if p != nil, do: bind(p, v, env, mode)
    bind_elems(ps, rest, env, mode)
  end

  defp bind_name(:let, env, name, v), do: declare(env, name, v)
  defp bind_name(:const, env, name, v), do: declare(env, name, v, true)
  defp bind_name(_, env, name, v), do: assign_var(env, name, v)

  defp key_of({:str, s}, _), do: s
  defp key_of({:computed, e}, env), do: to_key(ev(e, env))

  defp assign_to({:id, name}, v, env), do: assign_var(env, name, v)

  defp assign_to({:member, o, k, _}, v, env) do
    ov = ev(o, env)
    put(ov, ev_key(k, env), v)
  end

  defp ev_key({:str, s}, _), do: s
  defp ev_key({:priv, name}, env), do: private_key(name, env)
  defp ev_key(k, env), do: ev(k, env)

  # ── expressions ────────────────────────────────────────────

  def ev({:num, n}, _), do: n

  def ev({:val, v}, _env), do: v

  def ev({:destructure, pat, right}, env) do
    v = ev(right, env)
    bind(pat, v, env, :assign)
    v
  end

  def ev({:async, fun}, env), do: make_fn({:async, fun}, env)
  def ev({:gen, fun}, env), do: make_fn({:gen, fun}, env)
  def ev({:await, e}, env), do: Browser.JS.Promise.await(ev(e, env))
  def ev({:regex, source, flags}, _env), do: Browser.JS.RegExp.new(source, flags)
  def ev({:str, s}, _), do: s
  def ev({:lit, v}, _), do: v

  def ev({:new_target}, env) do
    case lookup_var(env, :new_target) do
      {:ok, nt} -> nt
      _ -> :undefined
    end
  end

  def ev({:this}, env) do
    case lookup_var(env, :this) do
      {:ok, :uninit_this} ->
        throw_error(
          "ReferenceError",
          "Must call super constructor in derived class before accessing 'this' or returning from derived constructor"
        )

      {:ok, v} ->
        v

      :error ->
        :undefined
    end
  end

  # `import(specifier)`: a promise for the module's namespace (the host loads it)
  def ev({:import_call, e}, env) do
    spec = to_str(ev(e, env))
    p = Browser.JS.Promise.new()

    case Process.get(:js_import) do
      nil ->
        Browser.JS.Promise.reject(p, make_error("TypeError", "Dynamic import is not available"))

      hook ->
        base =
          case lookup_var(env, :module_url) do
            {:ok, b} -> b
            :error -> nil
          end

        try do
          Browser.JS.Promise.resolve(p, hook.(spec, base))
        catch
          {:js_error, err} -> Browser.JS.Promise.reject(p, err)
        end
    end

    p
  end

  def ev({:import_meta}, env) do
    url =
      case lookup_var(env, :module_url) do
        {:ok, b} -> b
        :error -> :undefined
      end

    new_object([{"url", url}])
  end

  def ev({:class, _, _, _} = c, env), do: Browser.JS.Classes.define(c, env)

  def ev({:call, {:super}, args, _}, env),
    do: Browser.JS.Classes.super_call(eval_list(args, env), env)

  def ev({:super_member, key}, env) do
    {home, this} = Browser.JS.Classes.super_base(env)
    get_with_receiver(home, ev_key(key, env), this)
  end

  def ev({:id, name}, env) do
    case lookup_var(env, name) do
      {:ok, v} -> v
      :error when name == "arguments" -> lazy_arguments(env)
      :error -> throw_error("ReferenceError", "#{name} is not defined")
    end
  end

  # the strings argument of a tagged template: an array with a `raw` twin
  def ev({:tagged_strings, cooked, raw}, _env) do
    strings = new_array(cooked)
    put_hidden(strings, "raw", new_array(raw))
    strings
  end

  def ev({:tmpl, parts}, env) do
    parts
    |> Enum.map(fn p -> if is_binary(p), do: p, else: to_str(ev(p, env)) end)
    |> IO.iodata_to_binary()
  end

  # an elision (`[1, , 3]`) leaves a hole: no element, but it counts in the length
  def ev({:array, elems}, env) do
    {items, len} =
      Enum.reduce(elems, {%{}, 0}, fn
        {:spread, e}, {m, i} ->
          vals = iterate(ev(e, env))

          m =
            vals |> Enum.with_index(i) |> Enum.reduce(m, fn {v, j}, acc -> Map.put(acc, j, v) end)

          {m, i + length(vals)}

        :hole, {m, i} ->
          {m, i + 1}

        n, {m, i} ->
          {Map.put(m, i, ev(n, env)), i + 1}
      end)

    {:obj, id} = arr = new_array([])
    store(id, %{deref(id) | items: items, len: len})
    arr
  end

  def ev({:object, props}, env) do
    obj = new_object()

    Enum.each(props, fn
      {:init, key, val} ->
        k = key_of(key, env)
        put(obj, k, ev_named(val, env, if(is_binary(k), do: {:id, k})))

      {:spread, e} ->
        spread_into(obj, ev(e, env))

      {:getter, key, fun} ->
        Browser.JS.Props.define_accessor(obj, key_of(key, env), get: ev(fun, env))

      {:setter, key, fun} ->
        Browser.JS.Props.define_accessor(obj, key_of(key, env), set: ev(fun, env))
    end)

    obj
  end

  def ev({:fn, _, _, _, _} = f, env), do: make_fn(f, env)

  def ev({:seq, es}, env), do: Enum.reduce(es, :undefined, fn e, _ -> ev(e, env) end)

  def ev({:chain, e}, env) do
    ev(e, env)
  catch
    :js_short -> :undefined
  end

  def ev({:cond, c, a, b}, env), do: if(truthy(ev(c, env)), do: ev(a, env), else: ev(b, env))

  def ev({:logical, op, l, r}, env) do
    lv = ev(l, env)

    case op do
      "&&" -> if truthy(lv), do: ev(r, env), else: lv
      "||" -> if truthy(lv), do: lv, else: ev(r, env)
      "??" -> if nullish?(lv), do: ev(r, env), else: lv
    end
  end

  def ev({:unary, "typeof", {:id, name}}, env) do
    case lookup_var(env, name) do
      {:ok, v} -> typeof(v)
      :error -> "undefined"
    end
  end

  def ev({:unary, "delete", {:member, o, k, _}}, env), do: delete(ev(o, env), ev_key(k, env))
  def ev({:unary, "delete", _}, _), do: true

  def ev({:unary, op, e}, env) do
    v = ev(e, env)

    case op do
      "!" -> not truthy(v)
      "-" -> Num.neg(to_num(v))
      "+" -> to_num(v)
      "~" -> (Num.int32(to_num(v)) |> Bitwise.bnot()) * 1.0
      "typeof" -> typeof(v)
      "void" -> :undefined
    end
  end

  def ev({:binary, "in", {:priv_ref, name}, r}, env) do
    key = private_key(name, env)

    case ev(r, env) do
      {:obj, id} ->
        Map.has_key?(deref(id).props, key)

      _ ->
        throw_error(
          "TypeError",
          "Cannot use 'in' operator to search for a private field in a non-object"
        )
    end
  end

  def ev({:binary, op, l, r}, env), do: binop(op, ev(l, env), ev(r, env))

  def ev({:update, op, prefix?, target}, env) do
    old = to_num(ev(target, env))
    new = if op == "++", do: Num.add(old, 1.0), else: Num.sub(old, 1.0)
    assign_to(target, new, env)
    if prefix?, do: new, else: old
  end

  def ev({:assign, "=", {:id, name}, value}, env) do
    v = ev_named(value, env, {:id, name})
    assign_var(env, name, v)
    v
  end

  def ev({:assign, "=", {:member, o, k, _}, value}, env) do
    ov = ev(o, env)
    key = ev_key(k, env)
    v = ev(value, env)
    put(ov, key, v)
    v
  end

  def ev({:assign, op, target, value}, env) do
    # evaluate the target's object and key once
    {read, write} =
      case target do
        {:id, name} ->
          {fn -> ev(target, env) end, fn v -> assign_var(env, name, v) end}

        {:member, o, k, _} ->
          ov = ev(o, env)
          key = ev_key(k, env)
          {fn -> get(ov, key) end, fn v -> put(ov, key, v) end}
      end

    old = read.()
    base = binary_part(op, 0, byte_size(op) - 1)

    result =
      case base do
        "&&" -> if truthy(old), do: {:set, ev(value, env)}, else: :keep
        "||" -> if truthy(old), do: :keep, else: {:set, ev(value, env)}
        "??" -> if nullish?(old), do: {:set, ev(value, env)}, else: :keep
        _ -> {:set, binop(base, old, ev(value, env))}
      end

    case result do
      :keep -> old
      {:set, v} -> write.(v) && v
    end
  end

  def ev({:member, o, k, opt}, env) do
    ov = ev(o, env)
    if opt and nullish?(ov), do: throw(:js_short)
    get(ov, ev_key(k, env))
  end

  def ev({:call, callee, args, opt}, env) do
    {f, this} =
      case callee do
        {:super_member, key} ->
          {home, this} = Browser.JS.Classes.super_base(env)
          {get_with_receiver(home, ev_key(key, env), this), this}

        {:member, o, k, mopt} ->
          ov = ev(o, env)
          if mopt and nullish?(ov), do: throw(:js_short)
          {get(ov, ev_key(k, env)), ov}

        _ ->
          {ev(callee, env), :undefined}
      end

    if opt and nullish?(f), do: throw(:js_short)
    unless function?(f), do: throw_error("TypeError", "#{describe(callee)} is not a function")
    call(f, this, eval_list(args, env))
  end

  def ev({:new, callee, args}, env) do
    f = ev(callee, env)
    unless function?(f), do: throw_error("TypeError", "#{describe(callee)} is not a constructor")
    construct(f, eval_list(args, env))
  end

  defp describe({:id, n}), do: n
  defp describe({:member, o, {:str, k}, _}), do: describe(o) <> "." <> k
  defp describe({:member, o, _, _}), do: describe(o) <> "[...]"
  defp describe({:this}), do: "this"
  defp describe(_), do: "expression"

  defp eval_list(nodes, env) do
    Enum.flat_map(nodes, fn
      {:spread, e} -> iterate(ev(e, env))
      :hole -> [:undefined]
      n -> [ev(n, env)]
    end)
  end

  defp spread_into(obj, src) do
    for k <- own_keys(src), do: put(obj, k, get(src, k))
    :ok
  end

  # ── operators ──────────────────────────────────────────────

  def binop("+", a, b) do
    a = to_primitive(a, "default")
    b = to_primitive(b, "default")

    if is_binary(a) or is_binary(b),
      do: to_str(a) <> to_str(b),
      else: Num.add(to_num(a), to_num(b))
  end

  def binop("-", a, b), do: Num.sub(to_num(a), to_num(b))
  def binop("*", a, b), do: Num.mul(to_num(a), to_num(b))
  def binop("/", a, b), do: Num.div(to_num(a), to_num(b))
  def binop("%", a, b), do: Num.mod(to_num(a), to_num(b))
  def binop("**", a, b), do: Num.pow(to_num(a), to_num(b))
  def binop("===", a, b), do: strict_eq(a, b)
  def binop("!==", a, b), do: not strict_eq(a, b)
  def binop("==", a, b), do: loose_eq(a, b)
  def binop("!=", a, b), do: not loose_eq(a, b)
  def binop("<", a, b), do: compare(a, b) == :lt
  def binop(">", a, b), do: compare(a, b) == :gt
  def binop("<=", a, b), do: compare(a, b) in [:lt, :eq]
  def binop(">=", a, b), do: compare(a, b) in [:gt, :eq]
  def binop(op, a, b) when op in ["&", "|", "^"], do: Num.bitop(op, to_num(a), to_num(b))
  def binop(op, a, b) when op in ["<<", ">>", ">>>"], do: Num.shift(op, to_num(a), to_num(b))
  def binop("in", a, b), do: has_property?(b, a)
  def binop("instanceof", a, b), do: instance_of?(a, b)
  # an anonymous function or class takes the name of the binding or property it is assigned to
  defp ev_named({:fn, nil, _, _, _} = e, env, {:id, name}), do: name_fn(ev(e, env), name)
  defp ev_named({:class, nil, _, _} = e, env, {:id, name}), do: name_fn(ev(e, env), name)
  defp ev_named(e, env, _), do: ev(e, env)

  defp name_fn({:obj, id} = f, name) do
    case deref(id) do
      %{fun: {:closure, %{name: n} = c}} = o when not is_binary(n) ->
        store(id, %{o | fun: {:closure, %{c | name: name}}})

      _ ->
        :ok
    end

    f
  end
end
