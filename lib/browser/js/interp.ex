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

  # `Process.get/1` as a macro: the same result (nil when unset) without a call into Process
  defmacrop pget(key) do
    quote do
      case :erlang.get(unquote(key)) do
        :undefined -> nil
        v -> v
      end
    end
  end

  @max_depth 1000

  # ── heap ───────────────────────────────────────────────────

  @doc "Starts a fresh heap in this process. `max_steps` bounds how much work a script may do."
  def init(max_steps) do
    :erlang.put(:js_heap, %{})
    :erlang.put(:js_next, 0)
    :erlang.put(:js_steps, max_steps)
    :erlang.put(:js_depth, 0)
    :erlang.put(:js_last, :undefined)
    :erlang.put(:js_fns, 0)
  end

  def alloc(obj) do
    id = pget(:js_next)
    :erlang.put(:js_next, id + 1)
    :erlang.put(:js_heap, Map.put(pget(:js_heap), id, obj))
    id
  end

  def deref(id), do: Map.fetch!(pget(:js_heap), id)
  def store(id, obj), do: :erlang.put(:js_heap, Map.put(pget(:js_heap), id, obj))

  @doc "The built-in prototype object registered under `name` (`:object`, `:array`, ...)."
  def proto(name), do: Process.get({:proto, name})
  def put_proto(name, val), do: :erlang.put({:proto, name}, val)

  def global, do: pget(:js_global)

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

  @doc "`get [Symbol.species]` on a built-in constructor: returns `this`."
  def def_species(ctor) do
    put_hidden(
      ctor,
      {:symbol, :species, "Symbol.species"},
      {:accessor, native("get [Symbol.species]", fn this, _ -> this end), :undefined}
    )
  end

  def make_error(type, message) do
    err = new_object([{"message", message}], proto({:error, type}))
    mark_error(err)
    put_hidden(err, "stack", stack_string("#{type}: #{message}"))
    err
  end

  @doc "Sets the [[ErrorData]] marker `Error.isError` looks for."
  def mark_error({:obj, id} = e) do
    store(id, Map.put(deref(id), :errdata, true))
    e
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

  @doc false
  # a scope that `var`s declared by eval code land in (a function body's)
  def new_fn_scope(parent, vars \\ %{}) do
    alloc(%{scope: true, fnscope: true, vars: vars, consts: MapSet.new(), parent: parent})
  end

  def new_global_scope do
    id = new_scope(nil)
    :erlang.put(:js_global, id)
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

  defp lookup_var(scope, name), do: lookup_var(scope, name, pget(:js_heap))

  # walks the scope chain over one read of the heap
  defp lookup_var(nil, _, _), do: :error

  defp lookup_var(scope, name, heap) do
    s = Map.fetch!(heap, scope)

    case s.vars do
      %{^name => {:alias, target, var}} ->
        lookup_var(target, var, heap)

      %{^name => v} ->
        {:ok, v}

      _ ->
        case s do
          %{with: obj} when is_binary(name) ->
            if has_property?(obj, name) and not unscopable?(obj, name),
              do: {:ok, get(obj, name)},
              else: lookup_var(s.parent, name, heap)

          _ ->
            lookup_var(s.parent, name, heap)
        end
    end
  end

  # `with` skips what the object's Symbol.unscopables lists
  defp unscopable?(obj, name) do
    case get(obj, {:symbol, :unscopables, "Symbol.unscopables"}) do
      {:obj, _} = u -> truthy(get(u, name))
      _ -> false
    end
  end

  defp assign_var(scope, name, val), do: assign_var(scope, name, val, pget(:js_heap))

  defp assign_var(scope, name, val, heap) do
    s = Map.fetch!(heap, scope)

    cond do
      Map.has_key?(s.vars, name) ->
        if MapSet.member?(s.consts, name),
          do: throw_error("TypeError", "Assignment to constant variable.")

        cond do
          :erlang.map_get(name, s.vars) == :tdz ->
            throw_error("ReferenceError", "Cannot access '#{name}' before initialization")

          MapSet.member?(s.consts, {:fname, name}) ->
            :fname_ignored

          true ->
            :erlang.put(:js_heap, Map.put(heap, scope, %{s | vars: Map.put(s.vars, name, val)}))
        end

      is_binary(name) and is_map_key(s, :with) and has_property?(s.with, name) and
          not unscopable?(s.with, name) ->
        put(s.with, name, val)

      s.parent != nil ->
        assign_var(s.parent, name, val, heap)

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

  def truthy(v) when v in [false, :undefined, :null, :nan, "", {:bigint, 0}], do: false
  def truthy(v) when is_number(v), do: v != 0
  def truthy(_), do: true

  def typeof(:undefined), do: "undefined"
  def typeof(:null), do: "object"
  def typeof(v) when is_boolean(v), do: "boolean"
  def typeof(v) when is_binary(v), do: "string"
  def typeof({:obj, _} = v), do: if(function?(v), do: "function", else: "object")
  def typeof({:symbol, _, _}), do: "symbol"
  def typeof({:bigint, _}), do: "bigint"
  def typeof(v), do: if(num?(v), do: "number", else: "object")

  def to_num(v) when is_number(v), do: v
  def to_num(v) when v in [:nan, :infinity, :neg_infinity], do: v

  def to_num({:symbol, _, _}),
    do: throw_error("TypeError", "Cannot convert a Symbol value to a number")

  def to_num({:bigint, _}),
    do: throw_error("TypeError", "Cannot convert a BigInt value to a number")

  def to_num(:undefined), do: :nan
  def to_num(:null), do: 0.0
  def to_num(true), do: 1.0
  def to_num(false), do: 0.0
  def to_num(v) when is_binary(v), do: Num.parse(v)
  def to_num({:obj, _} = v), do: v |> to_primitive("number") |> to_num()

  # WhiteSpace and LineTerminator of the language: not Unicode's White_Space (U+180E, U+0085)
  @js_space [9, 10, 11, 12, 13, 32, 0xA0, 0x1680, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF] ++
              Enum.to_list(0x2000..0x200A)

  def js_trim_start(<<c::utf8, rest::binary>> = s),
    do: if(c in @js_space, do: js_trim_start(rest), else: s)

  def js_trim_start(s), do: s

  def js_trim_end(s) do
    s
    |> String.codepoints()
    |> Enum.reverse()
    |> Enum.drop_while(fn <<c::utf8>> -> c in @js_space end)
    |> Enum.reverse()
    |> Enum.join()
  end

  def js_trim(s), do: s |> js_trim_start() |> js_trim_end()

  @doc "ToNumeric: a number, or a `{:bigint, n}`."
  def numeric(v) do
    case to_primitive(v, "number") do
      {:bigint, _} = b -> b
      p -> to_num(p)
    end
  end

  def big?({:bigint, _}), do: true
  def big?(_), do: false

  @doc "ToIntegerOrInfinity, clamped to a large integer so callers can compare freely."
  def to_int(v) do
    case to_num(v) do
      :nan -> 0
      :infinity -> 18_014_398_509_481_984
      :neg_infinity -> -18_014_398_509_481_984
      n -> trunc(n)
    end
  end

  @doc "ArraySetLength's value check: ToUint32 and ToNumber must agree, or a RangeError."
  def array_length!(v) do
    u = uint32(to_num(v))

    case to_num(v) do
      n when is_number(n) and n == u -> u
      _ -> throw_error("RangeError", "Invalid array length")
    end
  end

  defp uint32(n) when is_number(n), do: n |> trunc() |> Bitwise.band(0xFFFFFFFF)
  defp uint32(_), do: 0

  def to_str(v) when is_binary(v), do: v

  def to_str({:symbol, _, _}),
    do: throw_error("TypeError", "Cannot convert a Symbol value to a string")

  def to_str({:bigint, n}), do: Integer.to_string(n)
  def to_str(:undefined), do: "undefined"
  def to_str(:null), do: "null"
  def to_str(true), do: "true"
  def to_str(false), do: "false"
  def to_str(v) when is_number(v) or v in [:nan, :infinity, :neg_infinity], do: Num.to_string(v)
  def to_str({:obj, _} = v), do: v |> to_primitive("string") |> to_str()

  def to_key(k) when is_binary(k), do: k
  def to_key({:symbol, _, _} = k), do: k
  def to_key({:private, _} = k), do: k

  def to_key({:obj, _} = o) do
    case to_primitive(o, "string") do
      {:symbol, _, _} = s -> s
      prim -> to_str(prim)
    end
  end

  def to_key(k), do: to_str(k)

  def to_primitive({:obj, _} = o, hint) do
    case get(o, {:symbol, :toPrimitive, "Symbol.toPrimitive"}) do
      m when m in [:undefined, :null] ->
        ordinary_to_primitive(o, hint)

      m ->
        unless function?(m),
          do: throw_error("TypeError", "Symbol.toPrimitive is not a function")

        case call(m, o, [hint]) do
          {:obj, _} -> throw_error("TypeError", "Cannot convert object to primitive value")
          prim -> prim
        end
    end
  end

  def to_primitive(v, _), do: v

  @doc false
  def ordinary_to_primitive(o, hint) do
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

  # ── equality and comparison ────────────────────────────────

  def strict_eq(a, b) do
    if num?(a) and num?(b), do: Num.equal?(a, b), else: a === b
  end

  def loose_eq(a, b) do
    cond do
      nullish?(a) and nullish?(b) -> true
      nullish?(a) or nullish?(b) -> false
      num?(a) and num?(b) -> Num.equal?(a, b)
      big?(a) or big?(b) -> Browser.JS.BigInt.loose_eq(a, b)
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

    cond do
      is_binary(a) and is_binary(b) ->
        cond do
          a < b -> :lt
          a > b -> :gt
          true -> :eq
        end

      big?(a) or big?(b) ->
        Browser.JS.BigInt.compare(a, b)

      true ->
        Num.compare(to_num(a), to_num(b))
    end
  end

  # ── properties ─────────────────────────────────────────────

  # array indices stop below 2^32 - 1; larger integers are ordinary property names
  defp index(k) when is_number(k) and k >= 0 and k < 4_294_967_295 and k == trunc(k), do: trunc(k)

  defp index(k) when is_binary(k) do
    case Integer.parse(k) do
      {i, ""} when i >= 0 and i < 4_294_967_295 -> if Integer.to_string(i) == k, do: i
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

        if Map.has_key?(o, :proxy) do
          Browser.JS.Proxy.get({:obj, id}, key, {:obj, id})
        else
          function_get(id, o, key)
        end

      :host ->
        key = to_key(key)
        {mod, data} = o.host

        case mod.host_get(data, key, {:obj, id}) do
          {:ok, v} -> v
          :miss -> lookup(o, key, {:obj, id})
        end

      _ ->
        case o do
          # a String wrapper's characters
          %{prim: str} when is_binary(str) ->
            case index(key) do
              i when is_integer(i) ->
                Browser.JS.Str.at(str, i) || lookup(o, to_key(key), {:obj, id})

              _ ->
                lookup(o, to_key(key), {:obj, id})
            end

          _ ->
            lookup(o, to_key(key), {:obj, id})
        end
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

  def get({:bigint, _} = n, key), do: lookup(deref(elem(proto(:bigint), 1)), to_key(key), n)
  def get({:symbol, _, _} = s, key), do: lookup(deref(elem(proto(:symbol), 1)), to_key(key), s)

  def get(b, key) when is_boolean(b),
    do: lookup(deref(elem(proto(:boolean), 1)), to_key(key), b)

  def get(v, key),
    do:
      throw_error(
        "TypeError",
        "Cannot read properties of #{to_str(v)} (reading '#{safe_key(key)}')"
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
        case o do
          # an array further up the prototype chain: its length and elements show through
          %{class: :array} when key == "length" ->
            o.len * 1.0

          %{class: :array, items: items} when is_binary(key) ->
            case index(key) do
              i when is_integer(i) and is_map_key(items, i) ->
                case items[i] do
                  {:accessor, getter, _} ->
                    if function?(getter), do: call(getter, receiver, []), else: :undefined

                  v ->
                    v
                end

              _ ->
                lookup_proto(o, key, receiver)
            end

          _ ->
            lookup_proto(o, key, receiver)
        end
    end
  end

  defp lookup_proto(o, key, receiver) do
    case o.proto do
      {:obj, pid} ->
        case deref(pid) do
          %{proxy: _} -> Browser.JS.Proxy.get({:obj, pid}, key, receiver)
          po -> lookup(po, key, receiver)
        end

      _ ->
        :undefined
    end
  end

  # spec lengths of the built-in functions, by name (a handful of names are shared
  # between objects with different arities; the common one wins)
  @native_lengths %{
    "Array" => 1.0,
    "ArrayBuffer" => 1.0,
    "DataView" => 1.0,
    "SharedArrayBuffer" => 1.0,
    "Boolean" => 1.0,
    "Date" => 7.0,
    "AggregateError" => 2.0,
    "SuppressedError" => 3.0,
    "Error" => 1.0,
    "EvalError" => 1.0,
    "Function" => 1.0,
    "Number" => 1.0,
    "Object" => 1.0,
    "Promise" => 1.0,
    "Proxy" => 2.0,
    "RangeError" => 1.0,
    "ReferenceError" => 1.0,
    "RegExp" => 2.0,
    "String" => 1.0,
    "SyntaxError" => 1.0,
    "TypeError" => 1.0,
    "URIError" => 1.0,
    "UTC" => 7.0,
    "abs" => 1.0,
    "acos" => 1.0,
    "acosh" => 1.0,
    "add" => 1.0,
    "all" => 1.0,
    "allSettled" => 1.0,
    "any" => 1.0,
    "apply" => 2.0,
    "asin" => 1.0,
    "asinh" => 1.0,
    "assign" => 2.0,
    "at" => 1.0,
    "atan" => 1.0,
    "atan2" => 2.0,
    "atanh" => 1.0,
    "bind" => 1.0,
    "catch" => 1.0,
    "cbrt" => 1.0,
    "ceil" => 1.0,
    "charAt" => 1.0,
    "charCodeAt" => 1.0,
    "clz32" => 1.0,
    "codePointAt" => 1.0,
    "concat" => 1.0,
    "construct" => 2.0,
    "copyWithin" => 2.0,
    "cos" => 1.0,
    "cosh" => 1.0,
    "create" => 2.0,
    "decodeURI" => 1.0,
    "decodeURIComponent" => 1.0,
    "defineProperties" => 2.0,
    "defineProperty" => 3.0,
    "delete" => 1.0,
    "deleteProperty" => 2.0,
    "encodeURI" => 1.0,
    "encodeURIComponent" => 1.0,
    "endsWith" => 1.0,
    "eval" => 1.0,
    "every" => 1.0,
    "exp" => 1.0,
    "expm1" => 1.0,
    "fill" => 1.0,
    "filter" => 1.0,
    "finally" => 1.0,
    "find" => 1.0,
    "findIndex" => 1.0,
    "findLast" => 1.0,
    "findLastIndex" => 1.0,
    "flatMap" => 1.0,
    "floor" => 1.0,
    "forEach" => 1.0,
    "freeze" => 1.0,
    "from" => 1.0,
    "groupBy" => 2.0,
    "fromCharCode" => 1.0,
    "fromCodePoint" => 1.0,
    "fromEntries" => 1.0,
    "fround" => 1.0,
    "f16round" => 1.0,
    "get" => 1.0,
    "getOwnPropertyDescriptor" => 2.0,
    "getOwnPropertyDescriptors" => 1.0,
    "getOwnPropertyNames" => 1.0,
    "getOwnPropertySymbols" => 1.0,
    "for" => 1.0,
    "getPrototypeOf" => 1.0,
    "keyFor" => 1.0,
    "has" => 1.0,
    "hasOwn" => 2.0,
    "hasOwnProperty" => 1.0,
    "hypot" => 2.0,
    "sumPrecise" => 1.0,
    "imul" => 2.0,
    "includes" => 1.0,
    "indexOf" => 1.0,
    "is" => 2.0,
    "isArray" => 1.0,
    "isExtensible" => 1.0,
    "isFinite" => 1.0,
    "isFrozen" => 1.0,
    "isInteger" => 1.0,
    "isNaN" => 1.0,
    "isPrototypeOf" => 1.0,
    "isSafeInteger" => 1.0,
    "isSealed" => 1.0,
    "isView" => 1.0,
    "join" => 1.0,
    "lastIndexOf" => 1.0,
    "localeCompare" => 1.0,
    "log" => 1.0,
    "log10" => 1.0,
    "log1p" => 1.0,
    "log2" => 1.0,
    "map" => 1.0,
    "match" => 1.0,
    "matchAll" => 1.0,
    "max" => 2.0,
    "min" => 2.0,
    "padEnd" => 1.0,
    "padStart" => 1.0,
    "parse" => 1.0,
    "parseFloat" => 1.0,
    "parseInt" => 2.0,
    "pow" => 2.0,
    "preventExtensions" => 1.0,
    "propertyIsEnumerable" => 1.0,
    "push" => 1.0,
    "race" => 1.0,
    "raw" => 1.0,
    "reduce" => 1.0,
    "reduceRight" => 1.0,
    "reject" => 1.0,
    "repeat" => 1.0,
    "replace" => 2.0,
    "replaceAll" => 2.0,
    "resolve" => 1.0,
    "round" => 1.0,
    "seal" => 1.0,
    "search" => 1.0,
    "set" => 2.0,
    "setPrototypeOf" => 2.0,
    "sign" => 1.0,
    "sin" => 1.0,
    "sinh" => 1.0,
    "slice" => 2.0,
    "some" => 1.0,
    "sort" => 1.0,
    "splice" => 2.0,
    "split" => 2.0,
    "sqrt" => 1.0,
    "startsWith" => 1.0,
    "stringify" => 3.0,
    "substr" => 2.0,
    "substring" => 2.0,
    "tan" => 1.0,
    "tanh" => 1.0,
    "then" => 2.0,
    "toExponential" => 1.0,
    "toFixed" => 1.0,
    "toPrecision" => 1.0,
    "toSpliced" => 2.0,
    "trunc" => 1.0,
    "unshift" => 1.0,
    "with" => 2.0
  }

  defp function_prop(id, %{generator: true} = o, "prototype") do
    p = new_object([], proto(if Map.get(o, :async), do: :async_generator, else: :generator))
    o = deref(id)
    attrs = Map.put(Map.get(o, :attrs, %{}), "prototype", %{w: true, c: false, e: false})
    store(id, o |> Map.put(:props, Map.put(o.props, "prototype", p)) |> Map.put(:attrs, attrs))
    p
  end

  defp function_prop(_id, %{async: true}, "prototype"), do: :undefined

  defp function_prop(id, o, "prototype") do
    case o.fun do
      {:closure, %{name: {:method, _}}} ->
        :undefined

      {:closure, %{mode: mode}} when mode in [false, nil] ->
        p = new_object()
        put_hidden(p, "constructor", {:obj, id})
        o = deref(id)
        attrs = Map.put(Map.get(o, :attrs, %{}), "prototype", %{w: true, c: false, e: false})

        store(
          id,
          o |> Map.put(:props, Map.put(o.props, "prototype", p)) |> Map.put(:attrs, attrs)
        )

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
      Enum.count(
        Enum.take_while(
          c.params,
          &(not match?({:rest, _}, &1) and not match?({:default, _, _}, &1))
        )
      ) * 1.0

  defp function_prop(_id, %{fun: {:native, name, _}} = o, "length"),
    do: Map.get(o, :arity) || Map.get(@native_lengths, name, 0.0)

  defp function_prop(_id, _o, _key), do: :undefined

  @doc "Sets an own property without making it show up in `Object.keys`."
  def put_hidden({:obj, id}, key, v) do
    o = deref(id)
    store(id, %{o | props: Map.put(o.props, key, v)})
  end

  @doc "CreateDataProperty: an own enumerable property, whatever the prototype chain says."
  def define_data({:obj, id}, key, v) do
    o = deref(id)
    keys = if Map.has_key?(o.props, key), do: o.keys, else: [key | o.keys]
    store(id, %{o | props: Map.put(o.props, key, v), keys: keys})
  end

  @doc "Sets `@@toStringTag`: not writable or enumerable, but configurable."
  def put_tag({:obj, id}, name) do
    key = {:symbol, :toStringTag, "Symbol.toStringTag"}
    o = deref(id)
    attrs = Map.put(Map.get(o, :attrs, %{}), key, %{w: false, c: true, e: false})
    store(id, o |> Map.put(:props, Map.put(o.props, key, name)) |> Map.put(:attrs, attrs))
  end

  @doc "Overrides the `length` of a native function."
  def set_arity({:obj, id}, n), do: store(id, Map.put(deref(id), :arity, n * 1.0))

  @doc "Sets an own property that is not writable, enumerable or configurable (a built-in's `prototype`)."
  def put_const({:obj, id}, key, v) do
    o = deref(id)
    attrs = Map.put(Map.get(o, :attrs, %{}), key, %{w: false, c: false, e: false})
    store(id, o |> Map.put(:props, Map.put(o.props, key, v)) |> Map.put(:attrs, attrs))
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
        if key in Map.get(o, :pmethods, []),
          do: throw_error("TypeError", "Private methods are not writable")

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
                if function?(setter), do: call(setter, {:obj, id}, [v]), else: fail_put()
                :ok

              Map.get(o, :frozen, false) ->
                fail_put()

              not Map.get(o, :ext, true) and not Map.has_key?(o.items, i) ->
                fail_put()

              i >= o.len and Map.get(o, :len_ro, false) ->
                fail_put()

              not writable?(o, i) ->
                fail_put()

              true ->
                store(id, %{o | items: Map.put(o.items, i, v), len: max(o.len, i + 1)})
            end

          nil ->
            if key == "length" do
              new_len = array_length!(v)

              cond do
                Map.get(o, :frozen, false) or Map.get(o, :len_ro, false) ->
                  fail_put()

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

      %{proxy: _} ->
        Browser.JS.Proxy.set({:obj, id}, to_key(key), v, {:obj, id})
        :ok

      # a function's own name and length are not writable
      %{class: :function, props: props} when key in ["name", "length"] ->
        unless Map.has_key?(props, key) or key in Map.get(o, :gone, []),
          do: fail_put(),
          else: put_prop(id, o, key, v)

      _ ->
        put_prop(id, o, to_key(key), v)
    end

    v
  end

  def put(v, key, _) when v in [:undefined, :null],
    do:
      throw_error(
        "TypeError",
        "Cannot set properties of #{to_str(v)} (setting '#{safe_key(key)}')"
      )

  def put(_primitive, _key, v), do: v

  # naming a key in an error must not run user code (a toString that throws)
  defp safe_key(key) when is_binary(key), do: key
  defp safe_key(key) when is_number(key), do: to_str(key)
  defp safe_key(_), do: "?"

  # an assignment: own accessor or non-writable property, inherited ones, then a new property
  defp put_prop(id, o, key, v) do
    case Map.fetch(o.props, key) do
      {:ok, {:accessor, _, setter}} ->
        if function?(setter), do: call(setter, {:obj, id}, [v]), else: fail_put()
        :ok

      {:ok, _} ->
        if writable?(o, key),
          do: store(id, %{o | props: Map.put(o.props, key, v)}),
          else: fail_put()

      :error ->
        case inherited_set(o.proto, key) do
          {:setter, setter} ->
            call(setter, {:obj, id}, [v])
            :ok

          :readonly ->
            fail_put()

          {:proxy, proxy} ->
            Browser.JS.Proxy.set(proxy, key, v, {:obj, id})
            :ok

          :none ->
            if Map.get(o, :ext, true) do
              o2 = %{
                o
                | props: Map.put(o.props, key, v),
                  # a symbol-keyed property is not listed by Object.keys or for-in; it is
                  # marked enumerable in its attributes instead
                  keys: if(is_binary(key), do: [key | o.keys], else: o.keys)
              }

              if is_binary(key),
                do: store(id, o2),
                else:
                  store(
                    id,
                    Map.put(
                      o2,
                      :attrs,
                      Map.put(Map.get(o, :attrs, %{}), key, %{e: true, w: true, c: true})
                    )
                  )
            else
              fail_put()
            end
        end
    end
  end

  # a failed [[Set]]: sloppy code ignores it, strict code (`strict_put`) throws
  defp fail_put, do: :erlang.put(:js_put_failed, true)

  defp strict_put(ov, key, v) do
    :erlang.put(:js_put_failed, false)
    put(ov, key, v)

    if :erlang.get(:js_put_failed) == true do
      :erlang.put(:js_put_failed, false)
      throw_error("TypeError", "Cannot assign to read only property '#{to_str(key)}'")
    end

    v
  end

  # an assignment to a name nothing declares is a ReferenceError in strict code
  defp resolvable?(scope, name) do
    s = deref(scope)

    cond do
      Map.has_key?(s.vars, name) -> true
      is_binary(name) and is_map_key(s, :with) and has_property?(s.with, name) -> true
      s.parent != nil -> resolvable?(s.parent, name)
      true -> false
    end
  end

  # where a name resolves to: the scope declaring it or the `with` object having it
  defp with_binding(scope, name) do
    s = deref(scope)

    cond do
      Map.has_key?(s.vars, name) ->
        {:var, scope}

      is_binary(name) and is_map_key(s, :with) and has_property?(s.with, name) and
          not unscopable?(s.with, name) ->
        {:with, s.with}

      s.parent != nil ->
        with_binding(s.parent, name)

      true ->
        nil
    end
  end

  defp strict_assign_var(env, name, v, resolved?) do
    unless resolved?, do: throw_error("ReferenceError", "#{name} is not defined")

    if assign_var(env, name, v) == :fname_ignored,
      do: throw_error("TypeError", "Assignment to constant variable.")

    :ok
  end

  defp inherited_set({:obj, pid}, key) do
    p = deref(pid)

    case p.props do
      _ when is_map_key(p, :proxy) ->
        {:proxy, {:obj, pid}}

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
      %{proxy: _} ->
        Browser.JS.Proxy.delete({:obj, id}, to_key(key))

      %{class: :host, host: {mod, data}} ->
        if function_exported?(mod, :host_delete, 2),
          # a host that has nothing to say about `key` answers :default
          do: with(:default <- mod.host_delete(data, to_key(key)), do: delete_plain(id, o, key)),
          else: delete_plain(id, o, key)

      _ ->
        delete_plain(id, o, key)
    end
  end

  def delete(_, _), do: true

  defp delete_plain(id, o, key) do
    i = if o.class == :array, do: index(key)

    cond do
      o.class == :function and key in ["name", "length"] and not Map.has_key?(o.props, key) ->
        store(id, Map.update(o, :gone, [key], &[key | &1]))
        true

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
            |> then(fn o2 ->
              # a function's own `name` or `length` that is gone must not reappear as the virtual one
              if o.class == :function and key in ["name", "length"],
                do: Map.update(o2, :gone, [key], &[key | &1]),
                else: o2
            end)
          )

          true
        end
    end
  end

  def has_property?({:obj, id}, key) do
    o = deref(id)
    key_s = to_key(key)

    cond do
      Map.has_key?(o, :proxy) ->
        Browser.JS.Proxy.has({:obj, id}, key_s)

      # what a host object answers for is there (`"foo" in window`)
      o.class == :host and host_has?(o, id, key_s) ->
        true

      # a typed array never looks past itself for a numeric key
      o.class == :host and match?({Browser.JS.TypedArrays, _}, o.host) and
          Browser.JS.TypedArrays.numeric_key?(key_s) ->
        false

      o.class == :array and key_s == "length" ->
        true

      match?(%{prim: str} when is_binary(str), o) and is_integer(index(key)) and
          index(key) < Browser.JS.Str.length(o.prim) ->
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
      %{proxy: _} ->
        Browser.JS.Proxy.host_keys(id)

      %{class: :host, host: {Browser.JS.TypedArrays, data}} ->
        Browser.JS.TypedArrays.host_keys(data) ++ own_keys_plain(o)

      %{class: :host, host: {mod, data}} ->
        if function_exported?(mod, :host_keys, 1),
          do: with(:default <- mod.host_keys(data), do: own_keys_plain(o)),
          else: own_keys_plain(o)

      _ ->
        own_keys_plain(o)
    end
  end

  def own_keys(s) when is_binary(s),
    do: for(i <- 0..(String.length(s) - 1)//1, do: Integer.to_string(i))

  def own_keys(_), do: []

  defp own_keys_plain(o) do
    base = o.keys |> Enum.reverse() |> Enum.filter(&is_binary/1)

    case o do
      %{class: :array} ->
        attrs = Map.get(o, :attrs, %{})

        for(
          i <- o.items |> Map.keys() |> Enum.sort(),
          i < o.len,
          Map.get(Map.get(attrs, i, %{}), :e, true),
          do: Integer.to_string(i)
        ) ++ base

      _ ->
        {ints, rest} =
          Enum.split_with(base, &(is_integer(index(&1)) and index(&1) < 4_294_967_295))

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
        run_closure(id, c, this, args)

      _ ->
        throw_error("TypeError", "value is not a function")
    end
  end

  def call(_, _, _), do: throw_error("TypeError", "value is not a function")

  def construct(f, args, new_target \\ nil)

  def construct({:obj, id} = f, args, new_target) do
    unless constructor?(f), do: throw_error("TypeError", "value is not a constructor")

    nt = new_target || f

    case deref(id) do
      %{proxy: _} -> Browser.JS.Proxy.construct(f, args, nt)
      _ -> construct_bound(f, id, args, new_target, nt)
    end
  end

  def construct(_, _, _), do: throw_error("TypeError", "value is not a constructor")

  defp construct_bound(f, id, args, new_target, nt) do
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

  @doc "IsConstructor: arrows, generators, async functions, methods and built-ins without a `prototype` are not."
  def constructor?({:obj, id} = f) do
    o = deref(id)

    function?(f) and
      case o do
        %{proxy_constructor: c} -> c
        %{proxy_ctor: true} -> true
        %{bound: {target, _}} -> constructor?(target)
        %{generator: true} -> false
        %{fun: {:closure, %{mode: m}}} when m in [:arrow, :arrow_expr] -> false
        %{fun: {:closure, %{name: {:method, _}}}} -> false
        %{fun: {:closure, _}, async: true} -> false
        %{fun: {:native, _, _}, props: props} -> Map.has_key?(props, "prototype")
        _ -> true
      end
  end

  def constructor?(_), do: false

  defp builtin_prototype(%{fun: {:native, _, _}}, f) do
    case get(f, "prototype") do
      {:obj, _} = p -> p
      _ -> proto(:object)
    end
  end

  defp builtin_prototype(_, _), do: proto(:object)

  defp construct_plain({:obj, _} = f, id, nt, new_target, args) do
    case Map.get(deref(id), :class_info) do
      nil ->
        proto =
          case get(nt, "prototype") do
            {:obj, _} = p -> p
            # a built-in falls back to its own prototype, a plain function to Object.prototype
            _ -> builtin_prototype(deref(id), f)
          end

        if Map.get(deref(id), :no_new), do: throw_error("TypeError", "not a constructor")

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

  def instance_of?(o, {:obj, _} = f) do
    case get(f, {:symbol, :hasInstance, "Symbol.hasInstance"}) do
      m when m in [:undefined, :null] ->
        unless function?(f),
          do: throw_error("TypeError", "Right-hand side of 'instanceof' is not callable")

        ordinary_has_instance(f, o)

      m ->
        truthy(call(m, f, [o]))
    end
  end

  def instance_of?(_, _),
    do: throw_error("TypeError", "Right-hand side of 'instanceof' is not an object")

  @doc "OrdinaryHasInstance(c, o)."
  def ordinary_has_instance(c, o) do
    cond do
      not function?(c) ->
        false

      match?(%{bound: {_, _}}, deref(elem(c, 1))) ->
        {target, _} = deref(elem(c, 1)).bound
        instance_of?(o, target)

      not match?({:obj, _}, o) ->
        false

      true ->
        case get(c, "prototype") do
          {:obj, _} = p -> walk_protos(o, p)
          _ -> throw_error("TypeError", "Function has non-object prototype in instanceof check")
        end
    end
  end

  defp walk_protos({:obj, _} = o, target) do
    case Browser.JS.Props.get_prototype_of(o) do
      {:obj, _} = p -> p == target or walk_protos(p, target)
      _ -> false
    end
  end

  @doc false
  def tick do
    n = pget(:js_steps) - 1
    if n < 0, do: throw(:js_limit)
    :erlang.put(:js_steps, n)
  end

  @doc false
  # the scope a function body runs in: `this`, the parameters, hoisted declarations
  def call_scope(c, this, args) do
    scope =
      alloc(%{
        scope: true,
        fnscope: true,
        vars: strict_marks(c, %{}),
        consts: MapSet.new(),
        parent: c.scope
      })

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
    if pget(:js_fns) == fns,
      do: :erlang.put(:js_heap, Map.delete(pget(:js_heap), scope))

    :ok
  end

  # A call's scope can only outlive the call through a closure created inside it (a function,
  # method, class or arrow all go through `make_fn`, which counts them). When none was, the
  # scope is garbage on return: dropping it keeps the heap from growing with every call.
  defp run_closure(id, c, this, args) do
    c = with_hoist(id, c)
    before = pget(:js_fns)
    {result, scope} = run_closure_scope(c, this, args, [])
    free_scope(scope, before)
    result
  end

  @doc false
  # runs a function body, also handing back its scope (a constructor reads `this` from it);
  # `extra` are more variables for the scope
  def run_closure_scope(c, this, args, extra) do
    depth = pget(:js_depth)
    if depth >= @max_depth, do: throw_error("RangeError", "Maximum call stack size exceeded")
    :erlang.put(:js_depth, depth + 1)
    stack = Process.get(:js_stack, [])
    :erlang.put(:js_stack, [c.name | stack])

    try do
      vars =
        if c.mode in [false, nil],
          do: %{this: sloppy_this(c, this), args: args, new_target: :undefined},
          else: %{}

      vars = if h = Map.get(c, :home), do: Map.put(vars, :home, h), else: vars
      vars = Enum.reduce(extra, vars, fn {k, v}, m -> Map.put(m, k, v) end)
      vars = strict_marks(c, vars)

      scope =
        alloc(%{scope: true, fnscope: true, vars: vars, consts: MapSet.new(), parent: c.scope})

      bind_params(c.params, args, scope)

      result =
        case c.mode do
          :arrow_expr ->
            ev(c.body, scope)

          _ ->
            {names, funs} =
              case c do
                %{hoist: h} -> h
                _ -> {hoisted_names(c.body), fundecls(c.body)}
              end

            apply_hoist(scope, names, funs)

            try do
              exec_list(c.body, scope)
              :undefined
            catch
              {:js_return, v} -> v
            end
        end

      {result, scope}
    after
      :erlang.put(:js_depth, depth)
      :erlang.put(:js_stack, stack)
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

  # an unresolved name is an element with that id when the page has one, else a ReferenceError
  defp named_global(name) do
    case Browser.JS.DOM.named_element(name) do
      {:ok, v} -> v
      :error -> throw_error("ReferenceError", "#{name} is not defined")
    end
  end

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

  # a generator or async function's `prototype` is its own (or none), never the one its kind's
  # prototype object carries
  defp function_get(id, %{props: props} = o, "prototype")
       when (is_map_key(o, :generator) or is_map_key(o, :async)) and
              not is_map_key(props, "prototype"),
       do: function_prop(id, o, "prototype")

  defp function_get(id, o, key) do
    case lookup(o, key, {:obj, id}) do
      :undefined ->
        cond do
          key in ["name", "length"] and key in Map.get(o, :gone, []) -> :undefined
          # `f.prototype = undefined` is a value, not a missing property
          key == "prototype" and Map.has_key?(o.props, "prototype") -> :undefined
          true -> function_prop(id, o, key)
        end

      v ->
        v
    end
  end

  @doc "A property read with a given `this` for getters (`super.x`)."
  def get_with_receiver({:obj, id} = obj, key, receiver) do
    case deref(id) do
      %{proxy: _} ->
        Browser.JS.Proxy.get(obj, to_key(key), receiver)

      %{class: class} = o when class in [:array, :function, :host] ->
        if receiver == obj or class == :host or (not is_binary(key) and not is_tuple(key)) do
          get(obj, key)
        else
          key = to_key(key)

          case Browser.JS.Props.own_state(obj, key) do
            nil ->
              case o.proto do
                {:obj, _} = p -> get_with_receiver(p, key, receiver)
                _ -> :undefined
              end

            {:data, v, _, _, _} ->
              v

            {:accessor, g, _, _, _} ->
              if function?(g), do: call(g, receiver, []), else: :undefined
          end
        end

      o ->
        lookup(o, to_key(key), receiver)
    end
  end

  def get_with_receiver(_, _, _), do: :undefined

  # a parameter list with initialisers gets a temporal dead zone: every name
  # reads as uninitialised until its own binding runs
  defp bind_params(params, args, scope) do
    if Enum.any?(params, &match?({:default, _, _}, &1)) do
      for p <- params, name <- pattern_names(p, []), do: declare(scope, name, :tdz)
      # eval code in a default expression cannot declare `arguments` (see `run_eval/3`)
      declare(scope, :in_params, true)
      bind_params_list(params, args, scope)
      s = deref(scope)
      store(scope, %{s | vars: Map.delete(s.vars, :in_params)})
    else
      bind_params_list(params, args, scope)
    end
  end

  defp bind_params_list([], _, _), do: :ok

  defp bind_params_list([{:rest, pat}], args, scope), do: bind(pat, new_array(args), scope, :let)

  defp bind_params_list([p | ps], args, scope) do
    {arg, rest} =
      case args do
        [a | r] -> {a, r}
        [] -> {:undefined, []}
      end

    bind(p, arg, scope, :let)
    bind_params_list(ps, rest, scope)
  end

  # generator, async and async generator functions do not inherit from Function.prototype directly
  defp kind_proto(id) do
    o = deref(id)

    key =
      case o do
        %{generator: true, async: true} -> :async_generator_function
        %{generator: true} -> :generator_function
        %{async: true} -> :async_function
      end

    if p = proto(key), do: store(id, %{o | proto: p})
    :ok
  end

  defp make_fn(node, env), do: make_fn(node, env, true)

  # `named?`: a function expression's own name is a binding inside it (a declaration's is not)
  defp make_fn({:gen, fun}, env, named?) do
    {:obj, id} = f = make_fn(fun, env, named?)
    store(id, Map.put(deref(id), :generator, true))
    kind_proto(id)
    f
  end

  defp make_fn({:async, fun}, env, named?) do
    {:obj, id} = f = make_fn(fun, env, named?)
    store(id, Map.put(deref(id), :async, true))
    kind_proto(id)
    f
  end

  defp make_fn({:fn, name, params, body, mode}, env, named?) do
    named? = named? and is_binary(name) and mode == false

    env =
      if named? do
        # a function expression can call itself by name
        s = new_scope(env)
        s
      else
        env
      end

    :erlang.put(:js_fns, pget(:js_fns) + 1)

    fun =
      {:obj,
       alloc(%{
         class: :function,
         fun: {:closure, %{name: name, params: params, body: body, mode: mode, scope: env}},
         props: %{},
         keys: [],
         proto: proto(:function)
       })}

    if named? and env != nil do
      declare(env, name, fun)
      # the function's own name cannot be assigned to (sloppy code ignores the attempt)
      s = deref(env)
      store(env, %{s | consts: MapSet.put(s.consts, {:fname, name})})
    end

    fun
  end

  # strict functions mark their scope, so that eval code called from them is strict too
  defp strict_marks(%{body: [{:expr, {:str, "use strict"}} | _]}, vars),
    do: Map.put(vars, :strict, true)

  defp strict_marks(_, vars), do: vars

  # A function that is not strict gets the global object for a `this` that is undefined or null
  # (a plain call): `(function () { this.x = 1 })()` sets a global. Without a global `this`
  # (no page) nothing changes.
  defp sloppy_this(c, this) do
    strict? =
      case c.body do
        [{:expr, {:str, "use strict"}} | _] -> true
        _ -> false
      end

    cond do
      strict? ->
        this

      this in [:undefined, :null] ->
        case lookup_var(global(), :this) do
          {:ok, w} -> w
          :error -> this
        end

      is_binary(this) or is_number(this) or is_boolean(this) or
        this in [:nan, :infinity, :neg_infinity] or
          (is_tuple(this) and elem(this, 0) in [:bigint, :symbol]) ->
        Browser.JS.Builtins.box(this)

      true ->
        this
    end
  end

  # `arguments` is only built when a function body asks for it
  defp lazy_arguments(env) do
    case lookup_var(env, :args) do
      {:ok, args} ->
        {:obj, aid} = a = new_array(args)
        store(aid, Map.put(deref(aid), :arguments, true))
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

  defp hoist_vars(stmts, scope), do: apply_hoist(scope, hoisted_names(stmts), [])

  # declares `var` names (undefined unless already a parameter) and function declarations
  defp apply_hoist(scope, names, funs) do
    if names != [] do
      s = deref(scope)
      vars = Enum.reduce(names, s.vars, fn n, m -> Map.put_new(m, n, :undefined) end)
      store(scope, %{s | vars: vars})
    end

    for {name, fun} <- funs, do: declare(scope, name, make_fn(fun, scope, false))
    :ok
  end

  # What a call must hoist is worked out from the body once per function object and kept in
  # its closure: looking the body up by value costs time proportional to its size on every call.
  defp with_hoist(_id, %{hoist: _} = c), do: c
  defp with_hoist(_id, %{mode: :arrow_expr} = c), do: c

  defp with_hoist(id, c) do
    c = Map.put(c, :hoist, {hoisted_names(c.body), fundecls(c.body)})
    o = deref(id)
    store(id, %{o | fun: {:closure, c}})
    c
  end

  defp fundecls(stmts) do
    Enum.flat_map(stmts, fn
      {:using, _, _, _, rest} -> fundecls(rest)
      stmt -> for {:fundecl, n, f} <- [unexport(stmt)], do: {n, f}
    end)
  end

  # the `var` names of a body, remembered: walking the syntax tree on every call is costly
  defp hoisted_names(stmts) do
    key = {:js_hoist, stmts}

    case pget(key) do
      nil ->
        names = stmts |> var_names([]) |> Enum.uniq()
        :erlang.put(key, names)
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
  def var_names({:using, _, _, _, rest}, acc), do: var_names(rest, acc)
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
    for stmt <- stmts do
      case unexport(stmt) do
        {:fundecl, name, fun} -> declare(scope, name, make_fn(fun, scope, false))
        {:using, _, _, _, rest} -> hoist_functions(rest, scope)
        _ -> :ok
      end
    end

    :ok
  end

  defp unexport({:export, stmt}), do: stmt
  defp unexport({:export_default, {:fundecl, _, _} = stmt}), do: stmt
  defp unexport(stmt), do: stmt

  # ── statements ─────────────────────────────────────────────

  @doc "Runs a whole program in the global scope; returns the completion value."
  def run_program({:program, stmts}) do
    :erlang.put(:js_last, :undefined)
    scope = global()
    hoist_vars(stmts, scope)
    hoist_functions(stmts, scope)
    exec_list(stmts, scope)
    Browser.JS.Promise.run_microtasks()
    # (the process dictionary reports a stored :undefined as missing, hence the default)
    Process.get(:js_last, :undefined)
  end

  @doc false
  # declares what a module body brings into its scope: `var` names, `let`/`const`/class names
  # (uninitialized until their declaration runs) and function declarations
  def module_init(stmts, scope) do
    hoist_vars(stmts, scope)

    for stmt <- stmts, name <- lexical_names(unexport(stmt)), do: declare(scope, name, :tdz)
    declare(scope, :default_export, :tdz)
    hoist_functions(stmts, scope)
  end

  defp lexical_names({:var, kind, decls}) when kind in [:let, :const],
    do: Enum.reduce(decls, [], fn {pat, _}, a -> pattern_names(pat, a) end)

  defp lexical_names({:export_default, {:classdecl, name, _}}), do: [name]
  defp lexical_names(_), do: []

  @doc false
  def module_exec(stmts, scope), do: exec_list(stmts, scope)

  @doc false
  # the current value of a module's variable (`:tdz` while uninitialized)
  def module_binding(scope, name) do
    case lookup_var(scope, name) do
      {:ok, v} -> v
      :error -> :undefined
    end
  end

  defp exec_list(stmts, env), do: Enum.each(stmts, &exec(&1, env, []))

  @doc "Runs statements as a function body in `scope`: hoists, then executes."
  def run_body(stmts, scope) do
    hoist_vars(stmts, scope)
    hoist_functions(stmts, scope)
    exec_list(stmts, scope)
  end

  # ── using declarations ─────────────────────────────────────

  @dispose {:symbol, :dispose, "Symbol.dispose"}
  @async_dispose {:symbol, :asyncDispose, "Symbol.asyncDispose"}

  @doc false
  # what a `using` / `await using` initializer gives: `{:none, mode}` for null and undefined,
  # else `{:res, value, method, mode}` where mode is :sync, :async, or :async_from_sync
  def using_resource(kind, v) when v in [:undefined, :null],
    do: {:none, if(kind == :using, do: :sync, else: :async)}

  def using_resource(kind, v) do
    unless match?({:obj, _}, v),
      do: throw_error("TypeError", "using declaration needs an object, null or undefined")

    case kind do
      :using ->
        {:res, v, dispose_method(v, @dispose) || missing_dispose(), :sync}

      :await_using ->
        case dispose_method(v, @async_dispose) do
          nil -> {:res, v, dispose_method(v, @dispose) || missing_dispose(), :async_from_sync}
          m -> {:res, v, m, :async}
        end
    end
  end

  defp missing_dispose, do: throw_error("TypeError", "object is not disposable")

  defp dispose_method(v, sym) do
    case get(v, sym) do
      m when m in [:undefined, :null] ->
        nil

      m ->
        unless function?(m), do: throw_error("TypeError", "dispose method is not callable")
        m
    end
  end

  @doc false
  # runs the disposal of one resource to its end: :ok or {:error, e}
  def dispose_sync({:none, :sync}), do: :ok
  def dispose_sync({:none, :async}), do: await_catching(:undefined)

  def dispose_sync({:res, v, m, :sync}) do
    call(m, v, [])
    :ok
  catch
    {:js_error, e} -> {:error, e}
  end

  def dispose_sync({:res, v, m, :async}) do
    await_catching(call(m, v, []))
  catch
    {:js_error, e} -> {:error, e}
  end

  def dispose_sync({:res, v, m, :async_from_sync}) do
    call(m, v, [])
    await_catching(:undefined)
  catch
    {:js_error, e} -> {:error, e}
  end

  defp await_catching(value) do
    Browser.JS.Promise.await(value)
    :ok
  catch
    {:js_error, e} -> {:error, e}
  end

  @doc false
  # how the rest of a list ended (:ok, or {:thrown, t}) together with its disposal
  def using_finish(:ok, :ok), do: :ok
  def using_finish(:ok, {:error, e}), do: throw({:js_error, e})
  def using_finish({:thrown, t}, :ok), do: throw(t)

  def using_finish({:thrown, {:js_error, e}}, {:error, e2}),
    do: throw({:js_error, suppressed_error(e2, e)})

  def using_finish({:thrown, _}, {:error, e2}), do: throw({:js_error, e2})

  @doc false
  def suppressed_error(error, suppressed) do
    err = make_error("SuppressedError", "An error was suppressed during disposal")
    put_hidden(err, "error", error)
    put_hidden(err, "suppressed", suppressed)
    err
  end

  @doc false
  def exec_stmt(stmt, env, labels \\ []), do: exec(stmt, env, labels)

  defp exec(stmt, env), do: exec(stmt, env, [])

  defp exec({:expr, e}, env, _) do
    :erlang.put(:js_last, ev(e, env))
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

  # `using x = v; rest`: the rest of the list runs, then the resource is disposed, whichever
  # way the rest ended
  defp exec({:using, kind, name, init, rest}, env, _) do
    v = ev_named(init, env, {:id, name})
    res = using_resource(kind, v)
    declare(env, name, v, true)

    outcome =
      try do
        exec_list(rest, env)
        :ok
      catch
        t -> {:thrown, t}
      end

    using_finish(outcome, dispose_sync(res))
  end

  defp exec({:with, obj, body}, env, _) do
    :erlang.put(:js_last, :undefined)
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

  defp exec({:export_default, {:classdecl, name, node}}, env, _),
    do: declare(env, name, ev_named(node, env, {:id, "default"}))

  defp exec({:export_default, {:expr, e}}, env, _),
    do: declare(env, :default_export, ev_named(e, env, {:id, "default"}))

  defp exec({:export_names, _}, _, _), do: :ok
  defp exec({:export_from, _, _}, _, _), do: :ok

  defp exec({:block, stmts}, env, _) do
    fns = pget(:js_fns)
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
    :erlang.put(:js_last, :undefined)

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

  defp exec({:while, c, body}, env, labels) do
    :erlang.put(:js_last, :undefined)
    while_loop(c, body, env, labels)
  end

  defp exec({:dowhile, body, c}, env, labels) do
    :erlang.put(:js_last, :undefined)

    case run_body(body, env, labels) do
      :break -> :ok
      :next -> while_loop(c, body, env, labels)
    end
  end

  defp exec({:for, init, test, update, body}, env, labels) do
    :erlang.put(:js_last, :undefined)
    loop_env = new_scope(env)
    per_iteration? = match?({:var, :let, _}, init)

    case init do
      {:var, _, _} = d -> exec(d, loop_env)
      {:expr, e} -> ev(e, loop_env)
      nil -> :ok
    end

    first = if per_iteration?, do: copy_scope(loop_env, env), else: loop_env
    for_loop(test, update, body, env, first, per_iteration?, labels, pget(:js_fns))
  end

  defp exec({kind, decl, pat, obj, body}, env, labels) when kind in [:forin, :forof] do
    :erlang.put(:js_last, :undefined)
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
          fns = pget(:js_fns)
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
    :erlang.put(:js_last, :undefined)
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
    :erlang.put(:js_last, :undefined)

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
      # a finalizer that completes normally leaves the try statement's own value
      if finalizer do
        saved = :erlang.get(:js_last)
        exec(finalizer, env)
        :erlang.put(:js_last, saved)
      end
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
          next_fns = pget(:js_fns)
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

  defp bind({:arrpat, elems}, v, env, mode) do
    case iter_source(v) do
      {:list, list} -> bind_elems(elems, list, env, mode)
      {:proto, it, next} -> bind_proto(elems, it, next, env, mode, false)
    end
  end

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
      pairs =
        for k <- Browser.JS.Props.enumerable_keys(v, used), do: {k, get(v, k)}

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

  # an iterator object is pulled from one value per element, so that an endless one works
  # and the iterator is closed when the pattern leaves it before it is done
  defp bind_proto([], it, _next, _env, _mode, done?) do
    unless done?, do: iter_close(it, false)
    :ok
  end

  defp bind_proto([{:rest, pat}], it, next, env, mode, done?) do
    list = if done?, do: [], else: pull(it, next, [])
    bind(pat, new_array(list), env, mode)
  end

  defp bind_proto([p | ps], it, next, env, mode, done?) do
    {v, done?} =
      if done? do
        {:undefined, true}
      else
        case iter_step(it, next) do
          :done -> {:undefined, true}
          {:ok, item} -> {item, false}
        end
      end

    if p != nil do
      try do
        bind(p, v, env, mode)
      catch
        kind, e ->
          unless done?, do: iter_close(it, true)
          :erlang.raise(kind, e, __STACKTRACE__)
      end
    end

    bind_proto(ps, it, next, env, mode, done?)
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
  def ev({:bigint, n}, _), do: {:bigint, n}

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
    arg = ev(e, env)
    p = Browser.JS.Promise.new()

    # the specifier is converted now; the module is loaded in a later job
    try do
      spec = to_str(arg)

      base =
        case lookup_var(env, :module_url) do
          {:ok, b} -> b
          :error -> nil
        end

      hook = pget(:js_import)

      Browser.JS.Promise.enqueue(fn ->
        try do
          if hook == nil,
            do: throw_error("TypeError", "Dynamic import is not available"),
            else: Browser.JS.Promise.resolve(p, hook.(spec, base))
        catch
          {:js_error, err} -> Browser.JS.Promise.reject(p, err)
        end
      end)
    catch
      {:js_error, err} -> Browser.JS.Promise.reject(p, err)
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
      {:ok, :tdz} ->
        throw_error("ReferenceError", "Cannot access '#{name}' before initialization")

      {:ok, v} ->
        v

      :error when name == "arguments" ->
        lazy_arguments(env)

      :error ->
        named_global(name)
    end
  end

  # the strings argument of a tagged template: an array with a `raw` twin
  def ev({:tagged_strings, cooked, raw}, _env) do
    strings = new_array(cooked)
    raw = new_array(raw)
    Browser.JS.Props.lock(raw, true)
    put_hidden(strings, "raw", raw)
    Browser.JS.Props.lock(strings, true)
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
        v = ev_named(val, env, if(is_binary(k), do: {:id, k}))
        method_home(v, obj)
        define_data(obj, k, v)

      {:proto, e} ->
        case ev(e, env) do
          {:obj, _} = p -> Browser.JS.Props.set_prototype_of(obj, p)
          :null -> Browser.JS.Props.set_prototype_of(obj, :null)
          _ -> :ok
        end

      {:spread, e} ->
        spread_into(obj, ev(e, env))

      {:getter, key, fun} ->
        f = ev(fun, env)
        method_home(f, obj)
        Browser.JS.Props.define_accessor(obj, key_of(key, env), get: f)

      {:setter, key, fun} ->
        f = ev(fun, env)
        method_home(f, obj)
        Browser.JS.Props.define_accessor(obj, key_of(key, env), set: f)
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
      {:ok, :tdz} ->
        throw_error("ReferenceError", "Cannot access '#{name}' before initialization")

      {:ok, v} ->
        typeof(v)

      :error ->
        with {:ok, v} <- Browser.JS.DOM.named_element(name),
             do: typeof(v),
             else: (_ -> "undefined")
    end
  end

  def ev({:unary, "delete", {:member, o, k, _}}, env), do: delete(ev(o, env), ev_key(k, env))
  # an identifier found on a `with` object is deleted from it
  def ev({:unary, "delete", {:id, name}}, env) do
    case with_binding(env, name) do
      {:with, obj} -> delete(obj, name)
      _ -> true
    end
  end

  def ev({:unary, "delete", _}, _), do: true

  # in strict code a delete that fails throws
  def ev({:unary, "sdelete", {:member, o, k, _}}, env) do
    ov = ev(o, env)
    key = ev_key(k, env)

    if delete(ov, key) == false,
      do: throw_error("TypeError", "Cannot delete property '#{to_str(key)}'"),
      else: true
  end

  def ev({:unary, "sdelete", _}, _), do: true

  def ev({:unary, op, e}, env) do
    v = ev(e, env)

    case op do
      "!" ->
        not truthy(v)

      "-" ->
        case numeric(v) do
          {:bigint, n} -> {:bigint, -n}
          n -> Num.neg(n)
        end

      "+" ->
        to_num(v)

      "~" ->
        case numeric(v) do
          {:bigint, n} -> {:bigint, Bitwise.bnot(n)}
          n -> (Num.int32(n) |> Bitwise.bnot()) * 1.0
        end

      "typeof" ->
        typeof(v)

      "void" ->
        :undefined
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
    old = numeric(ev(target, env))

    new =
      case old do
        {:bigint, n} -> {:bigint, if(op == "++", do: n + 1, else: n - 1)}
        _ -> if op == "++", do: Num.add(old, 1.0), else: Num.sub(old, 1.0)
      end

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

  def ev({:assign, op, target, value}, env), do: compound_assign(op, target, value, env, false)

  # assignments in strict code: a failed [[Set]] or an undeclared name throws
  def ev({:sassign, "=", {:id, name}, value}, env) do
    resolved? = resolvable?(env, name)
    v = ev_named(value, env, {:id, name})
    strict_assign_var(env, name, v, resolved?)
    v
  end

  def ev({:sassign, "=", {:member, o, k, _}, value}, env) do
    ov = ev(o, env)
    key = ev_key(k, env)
    v = ev(value, env)
    strict_put(ov, key, v)
  end

  def ev({:sassign, op, target, value}, env), do: compound_assign(op, target, value, env, true)

  def ev({:supdate, op, prefix?, target}, env) do
    old = numeric(ev(target, env))

    new =
      case old do
        {:bigint, n} -> {:bigint, if(op == "++", do: n + 1, else: n - 1)}
        _ -> if op == "++", do: Num.add(old, 1.0), else: Num.sub(old, 1.0)
      end

    case target do
      {:id, name} -> strict_assign_var(env, name, new, resolvable?(env, name))
      {:member, o, k, _} -> strict_put(ev(o, env), ev_key(k, env), new)
    end

    if prefix?, do: new, else: old
  end

  def ev({:member, o, k, opt}, env) do
    ov = ev(o, env)
    if opt and nullish?(ov), do: throw(:js_short)
    get(ov, ev_key(k, env))
  end

  # `eval(...)` where `eval` is the built-in function runs in the caller's scope
  def ev({:call, {:id, "eval"} = callee, args, false}, env) do
    f = ev(callee, env)
    unless function?(f), do: throw_error("TypeError", "eval is not a function")

    if f == :erlang.get(:js_eval_fn),
      do: direct_eval(eval_list(args, env), env),
      else: call(f, :undefined, eval_list(args, env))
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

  # ── direct eval ────────────────────────────────────────────

  @doc false
  def direct_eval([src | _], env) when is_binary(src) do
    ctx = %{
      strict: lookup_var(env, :strict) == {:ok, true},
      new_target: match?({:ok, _}, lookup_var(env, :new_target)),
      super_prop: match?({:ok, {:obj, _}}, lookup_var(env, :home)),
      super_call: match?({:ok, _}, lookup_var(env, :ctor_fn)),
      private: private_names_in(env, []),
      field_init: in_field_initializer?(env)
    }

    opts = [
      eval: true,
      strict: ctx.strict,
      new_target: ctx.new_target,
      super_prop: ctx.super_prop,
      super_call: ctx.super_call,
      private: ctx.private,
      no_arguments: ctx.field_init
    ]

    case Browser.JS.Parser.parse(src, opts) do
      {:error, msg} -> throw_error("SyntaxError", msg)
      {:ok, {:program, stmts}} -> run_eval(stmts, env, ctx.strict)
    end
  end

  def direct_eval([other | _], _env), do: other
  def direct_eval([], _env), do: :undefined

  # is the code in a class field initializer (arrow functions inside it count, functions do not)?
  defp in_field_initializer?(nil), do: false

  defp in_field_initializer?(env) do
    s = deref(env)

    cond do
      Map.has_key?(s.vars, :field_init) -> true
      Map.has_key?(s.vars, :args) -> false
      true -> in_field_initializer?(s.parent)
    end
  end

  # the private names (`#x`) declared by the classes around `env`
  defp private_names_in(nil, acc), do: acc

  defp private_names_in(env, acc) do
    s = deref(env)
    acc = for({:priv, n} <- Map.keys(s.vars), do: n) ++ acc
    private_names_in(s.parent, acc)
  end

  # Runs eval code: `var`s and functions go to the caller's function scope (sloppy code) while
  # `let`, `const` and classes stay in a scope of the eval's own; strict eval keeps everything.
  defp run_eval(stmts, env, caller_strict?) do
    strict? = caller_strict? or match?([{:expr, {:str, "use strict"}} | _], stmts)
    before = pget(:js_fns)
    lex = new_scope(env)
    var_scope = if strict?, do: lex, else: variable_scope(env)

    if strict?, do: declare(lex, :strict, true)

    s = deref(var_scope)

    if not strict? and Map.has_key?(s.vars, :in_params) and Map.has_key?(s.vars, :args) and
         "arguments" in hoisted_names(stmts),
       do: throw_error("SyntaxError", "Identifier 'arguments' has already been declared")

    vars = Enum.reduce(hoisted_names(stmts), s.vars, fn n, m -> Map.put_new(m, n, :undefined) end)
    store(var_scope, %{s | vars: vars})
    for {name, fun} <- fundecls(stmts), do: declare(var_scope, name, make_fn(fun, lex, false))
    for stmt <- stmts, name <- lexical_names(unexport(stmt)), do: declare(lex, name, :tdz)

    :erlang.put(:js_last, :undefined)
    exec_list(stmts, lex)
    result = Process.get(:js_last, :undefined)
    free_scope(lex, before)
    result
  end

  # the nearest function scope (or the global one) from `env` outwards
  defp variable_scope(env) do
    s = deref(env)
    if Map.get(s, :fnscope, false) or s.parent == nil, do: env, else: variable_scope(s.parent)
  end

  # a method written in an object literal finds `super` through the object
  defp method_home({:obj, id} = f, obj) do
    case deref(id) do
      %{fun: {:closure, %{name: {:method, _}}}} -> set_home(f, obj)
      _ -> :ok
    end
  end

  defp method_home(_, _), do: :ok

  defp compound_assign(op, target, value, env, strict?) do
    # evaluate the target's object and key once
    {read, write} =
      case target do
        {:id, name} ->
          # the reference is resolved once: a `with` object keeps receiving the write even if
          # the property is gone by then
          case with_binding(env, name) do
            {:with, obj} ->
              {fn -> get(obj, name) end,
               fn v ->
                 if strict? do
                   unless has_property?(obj, name),
                     do: throw_error("ReferenceError", "#{name} is not defined")

                   strict_put(obj, name, v)
                 else
                   put(obj, name, v)
                 end
               end}

            {:var, sid} ->
              {fn -> ev(target, sid) end,
               fn v ->
                 if strict?,
                   do: strict_assign_var(sid, name, v, true),
                   else: assign_var(sid, name, v)
               end}

            nil ->
              {fn -> ev(target, env) end,
               fn v ->
                 if strict?,
                   do: strict_assign_var(env, name, v, false),
                   else: assign_var(env, name, v)
               end}
          end

        {:member, o, k, _} ->
          ov = ev(o, env)
          key = ev_key(k, env)

          if nullish?(ov),
            do:
              throw_error(
                "TypeError",
                "Cannot read properties of #{to_str(ov)} (reading '#{safe_key(key)}')"
              )

          # the key is converted once, for the read and for the write
          key = to_key(key)

          {fn -> get(ov, key) end,
           fn v -> if strict?, do: strict_put(ov, key, v), else: put(ov, key, v) end}
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
    unless nullish?(src) or not match?({:obj, _}, src),
      do:
        for(
          k <- Browser.JS.Props.enumerable_own_keys(src),
          do: define_data(obj, k, get(src, k))
        )

    :ok
  end

  # ── operators ──────────────────────────────────────────────

  # plain numbers (never NaN or infinite: those are atoms) skip the conversions
  def binop("+", a, b) when is_float(a) and is_float(b), do: Num.add(a, b)
  def binop("-", a, b) when is_float(a) and is_float(b), do: Num.add(a, -b)
  def binop("*", a, b) when is_float(a) and is_float(b), do: Num.mul(a, b)
  def binop("<", a, b) when is_float(a) and is_float(b), do: a < b
  def binop(">", a, b) when is_float(a) and is_float(b), do: a > b
  def binop("<=", a, b) when is_float(a) and is_float(b), do: a <= b
  def binop(">=", a, b) when is_float(a) and is_float(b), do: a >= b

  def binop("+", a, b) do
    a = to_primitive(a, "default")
    b = to_primitive(b, "default")

    cond do
      is_binary(a) or is_binary(b) -> to_str(a) <> to_str(b)
      big?(a) or big?(b) -> Browser.JS.BigInt.arith("+", a, b)
      true -> Num.add(to_num(a), to_num(b))
    end
  end

  def binop(op, a, b) when op in ["-", "*", "/", "%", "**"] do
    a = numeric(a)
    b = numeric(b)

    if big?(a) or big?(b) do
      Browser.JS.BigInt.arith(op, a, b)
    else
      case op do
        "-" -> Num.sub(a, b)
        "*" -> Num.mul(a, b)
        "/" -> Num.div(a, b)
        "%" -> Num.mod(a, b)
        "**" -> Num.pow(a, b)
      end
    end
  end

  def binop("===", a, b), do: strict_eq(a, b)
  def binop("!==", a, b), do: not strict_eq(a, b)
  def binop("==", a, b), do: loose_eq(a, b)
  def binop("!=", a, b), do: not loose_eq(a, b)
  def binop("<", a, b), do: compare(a, b) == :lt
  def binop(">", a, b), do: compare(a, b) == :gt
  def binop("<=", a, b), do: compare(a, b) in [:lt, :eq]
  def binop(">=", a, b), do: compare(a, b) in [:gt, :eq]

  def binop(op, a, b) when op in ["&", "|", "^", "<<", ">>", ">>>"] do
    a = numeric(a)
    b = numeric(b)

    cond do
      big?(a) or big?(b) -> Browser.JS.BigInt.arith(op, a, b)
      op in ["&", "|", "^"] -> Num.bitop(op, a, b)
      true -> Num.shift(op, a, b)
    end
  end

  def binop("in", a, b), do: has_property?(b, a)
  def binop("instanceof", a, b), do: instance_of?(a, b)
  # an anonymous function or class takes the name of the binding or property it is assigned to
  def ev_named({:fn, nil, _, _, _} = e, env, {:id, name}), do: name_fn(ev(e, env), name)
  def ev_named({:class, nil, _, _} = e, env, {:id, name}), do: name_fn(ev(e, env), name)

  def ev_named({k, {:fn, nil, _, _, _}} = e, env, {:id, name}) when k in [:gen, :async],
    do: name_fn(ev(e, env), name)

  def ev_named({:async, {:gen, {:fn, nil, _, _, _}}} = e, env, {:id, name}),
    do: name_fn(ev(e, env), name)

  def ev_named(e, env, _), do: ev(e, env)

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
