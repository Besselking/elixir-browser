defmodule Browser.JS.Builtins do
  @moduledoc """
  The global environment: `console`, `Math`, `JSON`, `Object`, `Array`, `String`, `Number`,
  the error types, timers, and the methods on strings, numbers and arrays.

  Natives are `fn this, args -> value end`. Strings count code points, not UTF-16 units.
  """

  import Browser.JS.Interp, except: [get: 2, put: 3]
  alias Browser.JS.ArrayGeneric
  alias Browser.JS.Interp
  alias Browser.JS.Str
  alias Browser.JS.Num

  @timer_horizon 60_000.0
  @error_types ~w(Error TypeError ReferenceError RangeError SyntaxError EvalError URIError AggregateError SuppressedError)

  @doc "Creates the prototypes and the global scope. Call after `Interp.init/1`."
  def install do
    object_proto = {:obj, alloc(%{class: :object, props: %{}, keys: [], proto: nil})}
    put_proto(:object, object_proto)

    function_proto =
      {:obj,
       alloc(%{
         class: :function,
         fun: {:native, "", fn _, _ -> :undefined end},
         props: %{},
         keys: [],
         proto: object_proto
       })}

    put_proto(:function, function_proto)

    for name <- [:array, :string, :number, :boolean, :symbol], do: put_proto(name, new_object())
    error_proto = new_object()
    put_proto({:error, "Error"}, error_proto)

    for t <- @error_types, t != "Error" do
      put_proto({:error, t}, new_object([], error_proto))
    end

    scope = new_global_scope()
    declare(scope, "undefined", :undefined)
    declare(scope, "NaN", :nan)
    declare(scope, "Infinity", :infinity)

    object_methods(object_proto)
    function_methods(function_proto)
    array_methods(proto(:array))
    string_methods(proto(:string))
    Browser.JS.StringProto.install(proto(:string))
    number_methods(proto(:number))
    install_errors(scope, error_proto)
    install_object(scope, object_proto)
    install_array(scope, proto(:array))
    install_primitives(scope)
    Browser.JS.BigInt.install(scope)
    install_math(scope)
    Browser.JS.Json.install(scope)
    install_console(scope)
    install_timers(scope)
    install_misc(scope)
    Browser.JS.RegExp.install(scope)
    Browser.JS.Promise.install(scope)
    global = Browser.JS.Global.new()
    declare(scope, "globalThis", global)
    declare(scope, :this, global)
    Browser.JS.Collections.install(scope)
    Browser.JS.Proxy.install(scope)

    :erlang.put(:js_builtin_names, MapSet.new(Map.keys(deref(scope).vars)))
    scope
  end

  # Runs source text in the global scope (indirect eval, and the Function constructor).
  # indirect eval and the Function constructor: global code, so no `super` or `new.target`
  defp eval_source(src) do
    case Browser.JS.Parser.parse(src, eval: true) do
      {:ok, program} -> Interp.indirect_eval(program)
      {:error, msg} -> throw_error("SyntaxError", msg)
    end
  end

  def object_to_string(:undefined), do: "[object Undefined]"
  def object_to_string(:null), do: "[object Null]"

  def object_to_string(this) do
    o = if match?({:obj, _}, this), do: this, else: box(this)

    # the built-in tag is worked out before @@toStringTag is read (which may revoke a proxy)
    builtin = class_tag(o)

    case Interp.get(o, {:symbol, :toStringTag, "Symbol.toStringTag"}) do
      tag when is_binary(tag) -> "[object #{tag}]"
      _ -> "[object #{builtin}]"
    end
  end

  defp class_tag({:obj, id} = o) do
    case deref(id) do
      %{proxy: _} ->
        cond do
          Browser.JS.Proxy.is_array(o) -> "Array"
          function?(o) -> "Function"
          true -> "Object"
        end

      %{arguments: true} ->
        "Arguments"

      %{class: :array} ->
        "Array"

      %{class: :function} ->
        "Function"

      %{class: :regexp} ->
        "RegExp"

      %{date: _} ->
        "Date"

      %{prim: p} when is_binary(p) ->
        "String"

      %{prim: p} when is_boolean(p) ->
        "Boolean"

      %{prim: {:bigint, _}} ->
        "Object"

      %{prim: {:symbol, _, _}} ->
        "Object"

      %{prim: _} ->
        "Number"

      _ ->
        if error_object?(o), do: "Error", else: "Object"
    end
  end

  # an error prototype itself has no error data
  defp error_object?({:obj, id} = o),
    do: inherits_error?(deref(id).proto) and o not in Enum.map(@error_types, &proto({:error, &1}))

  defp inherits_error?({:obj, id} = p),
    do: p == proto({:error, "Error"}) or inherits_error?(deref(id).proto)

  defp inherits_error?(_), do: false

  defp has_own?(o, key) do
    if nullish?(o), do: throw_error("TypeError", "Cannot convert undefined or null to object")

    case o do
      {:obj, id} ->
        # (a module namespace answers per name: reading an uninitialized export throws)
        if match?(%{host: {Browser.JS.Modules, _}}, Interp.deref(id)),
          do: Browser.JS.Props.descriptor(o, key) != :undefined,
          else:
            key in own_keys(o) or (array?(o) and key == "length") or
              Browser.JS.Props.descriptor(o, key) != :undefined

      s when is_binary(s) ->
        key == "length" or key in own_keys(s)

      _ ->
        false
    end
  end

  defp def_fn(obj, name, fun), do: put_hidden(obj, name, native(name, fun))
  defp arg(args, i), do: Enum.at(args, i, :undefined)
  defp float(n), do: n * 1.0

  defp constructor(scope, name, proto, fun) do
    f = native(name, fun)
    put_const(f, "prototype", proto)
    put_hidden(proto, "constructor", f)
    declare(scope, name, f)
    f
  end

  # ── Object.prototype / Function.prototype ──────────────────

  defp object_methods(p) do
    def_fn(p, "hasOwnProperty", fn this, args ->
      has_own?(this, to_key(arg(args, 0)))
    end)

    def_fn(p, "toString", fn this, _ -> object_to_string(this) end)
    def_fn(p, "valueOf", fn this, _ -> this end)
  end

  defp function_methods(p), do: Browser.JS.FunctionProto.install(p)

  # ── errors ─────────────────────────────────────────────────

  defp install_errors(scope, error_proto) do
    ctors =
      for t <- @error_types do
        proto = proto({:error, t})
        put_hidden(proto, "name", t)
        put_hidden(proto, "message", "")

        {t,
         constructor(scope, t, proto, fn this, args ->
           err = if match?({:obj, _}, this), do: this, else: new_object([], proto)
           mark_error(err)
           # AggregateError(errors, message): the iterable of errors comes first
           {errors, suppressed, args} =
             case t do
               "AggregateError" -> {arg(args, 0), nil, Enum.drop(args, 1)}
               "SuppressedError" -> {nil, {arg(args, 0), arg(args, 1)}, Enum.drop(args, 2)}
               _ -> {nil, nil, args}
             end

           msg = if arg(args, 0) == :undefined, do: :undefined, else: to_str(arg(args, 0))

           if msg != :undefined, do: put_hidden(err, "message", msg)

           with {:obj, _} = opts <- arg(args, 1),
                true <- Interp.has_property?(opts, "cause") do
             put_hidden(err, "cause", Interp.get(opts, "cause"))
           end

           with {error, sup} <- suppressed do
             put_hidden(err, "error", error)
             put_hidden(err, "suppressed", sup)
           end

           Interp.set_stack(
             err,
             Interp.stack_string(t <> if(msg == :undefined, do: "", else: ": " <> msg))
           )

           if errors, do: put_hidden(err, "errors", new_array(Interp.iterate(errors)))

           err
         end)}
      end

    error_ctor = ctors |> List.keyfind("Error", 0) |> elem(1)

    stack_of =
      native("stackOf", fn _, [{:obj, id}] -> Map.get(deref(id), :stack_str, :undefined) end)

    put_hidden(
      error_proto,
      "stack",
      {:accessor, Browser.JS.Prelude.stack_accessor(:get, stack_of),
       Browser.JS.Prelude.stack_accessor(:set, error_proto)}
    )

    # the other error constructors inherit from Error
    for {t, {:obj, id}} <- ctors, t != "Error", do: store(id, %{deref(id) | proto: error_ctor})

    put_hidden(
      error_ctor,
      "isError",
      native("isError", fn _, args ->
        case arg(args, 0) do
          {:obj, id} -> Map.get(deref(id), :errdata, false)
          _ -> false
        end
      end)
      |> then(fn {:obj, id} = f ->
        store(id, Map.put(deref(id), :arity, 1.0))
        f
      end)
    )

    def_fn(error_proto, "toString", fn this, _ ->
      unless match?({:obj, _}, this),
        do: throw_error("TypeError", "Error.prototype.toString called on a non-object")

      name = with :undefined <- Interp.get(this, "name"), do: "Error", else: (n -> to_str(n))
      msg = with :undefined <- Interp.get(this, "message"), do: "", else: (m -> to_str(m))

      cond do
        name == "" -> msg
        msg == "" -> name
        true -> name <> ": " <> msg
      end
    end)
  end

  # [key, value] of the own enumerable string properties; a proxy is asked for each key's
  # descriptor and then its value, one key at a time
  defp enum_pairs(o) do
    if Browser.JS.Proxy.proxy?(o) do
      for k <- Browser.JS.Proxy.own_keys(o),
          is_binary(k),
          d = Browser.JS.Props.descriptor(o, k),
          d != :undefined,
          Interp.truthy(Interp.get(d, "enumerable")),
          do: {k, Interp.get(o, k)}
    else
      for k <- own_keys(o), do: {k, Interp.get(o, k)}
    end
  end

  # ── Object ─────────────────────────────────────────────────

  defp install_object(scope, object_proto) do
    obj =
      constructor(scope, "Object", object_proto, fn this, args ->
        # `new` on a subclass (new.target is not Object) makes an object of that class
        constructing = Process.delete(:js_native_new)

        subclass? =
          constructing == this and match?({:obj, _}, this) and
            deref(elem(this, 1)).proto not in [nil, object_proto]

        case arg(args, 0) do
          _ when subclass? ->
            this

          {:obj, _} = o ->
            o

          v when v in [:undefined, :null] ->
            new_object()

          v ->
            box(v)
        end
      end)

    def_fn(obj, "keys", fn _, [o | _] -> new_array(own_keys(o)) end)

    def_fn(obj, "hasOwn", fn _, args ->
      o = arg(args, 0)

      if nullish?(o),
        do: throw_error("TypeError", "Cannot convert undefined or null to object"),
        else: has_own?(o, to_key(arg(args, 1)))
    end)

    def_fn(obj, "values", fn _, [o | _] ->
      new_array(Enum.map(enum_pairs(o), &elem(&1, 1)))
    end)

    def_fn(obj, "entries", fn _, [o | _] ->
      new_array(Enum.map(enum_pairs(o), fn {k, v} -> new_array([k, v]) end))
    end)

    def_fn(obj, "assign", fn _, [target | sources] ->
      for s <- sources,
          not nullish?(s),
          k <- Browser.JS.Props.enumerable_own_keys(s),
          do: Interp.put(target, k, Interp.get(s, k))

      target
    end)

    def_fn(obj, "groupBy", fn _, [list, f | _] ->
      callable!(f)
      groups = new_object([], :null)

      for {e, i} <- Enum.with_index(iterate(list)) do
        k = to_key(call(f, :undefined, [e, float(i)]))

        case Interp.get(groups, k) do
          {:obj, _} = arr -> call(Interp.get(arr, "push"), arr, [e])
          _ -> Interp.put(groups, k, new_array([e]))
        end
      end

      groups
    end)

    def_fn(obj, "fromEntries", fn _, [list | _] ->
      o = new_object()
      for e <- iterate(list), do: Interp.put(o, to_key(Interp.get(e, 0.0)), Interp.get(e, 1.0))
      o
    end)

    Browser.JS.Props.install(obj, object_proto)
    Browser.JS.ObjectStatics.install(obj, object_proto)
  end

  # ── Array ──────────────────────────────────────────────────

  defp install_array(scope, array_proto) do
    arr =
      constructor(scope, "Array", array_proto, fn _, args ->
        case args do
          [n] when is_number(n) or n in [:nan, :infinity, :neg_infinity] ->
            unless is_number(n) and n >= 0 and n == trunc(n) and n < 4_294_967_296,
              do: throw_error("RangeError", "Invalid array length")

            array_of(trunc(n), %{})

          list ->
            new_array(list)
        end
      end)

    put_hidden(
      arr,
      {:symbol, :species, "Symbol.species"},
      {:accessor, native("get [Symbol.species]", fn this, _ -> this end), :undefined}
    )

    def_fn(arr, "isArray", fn _, args -> Browser.JS.Proxy.is_array(arg(args, 0)) end)
    put_hidden(arr, "fromAsync", Browser.JS.Prelude.from_async())
    def_fn(arr, "of", fn this, args -> ArrayGeneric.of(this, args) end)
    def_fn(arr, "from", fn this, args -> ArrayGeneric.from(this, args) end)
  end

  # start / end arguments of slice-like methods
  defp rel(v, len, default) do
    if v == :undefined do
      default
    else
      n = to_int(v)
      if n < 0, do: max(len + n, 0), else: min(n, len)
    end
  end

  # an array that push/pop may edit in place: not frozen, sealed, non-extensible or length-locked
  defp plain_array?({:obj, id}) do
    o = deref(id)

    o.class == :array and
      not (Map.get(o, :frozen, false) or Map.get(o, :sealed, false) or
             Map.get(o, :len_ro, false) or Map.get(o, :ext, true) == false)
  end

  defp plain_array?(_), do: false

  # an ordinary array whose list-based fast path is safe: `extra` more elements still fit
  defp fast_array?(this, extra \\ 0) do
    # an element on Array.prototype shows through holes and can run setters: take the generic path
    plain_array?(this) and Map.get(deref(elem(proto(:array), 1)), :items, %{}) == %{} and
      elem(this, 1) |> deref() |> Map.fetch!(:len) |> Kernel.+(extra) <= 50_000_000
  end

  @callback_methods ~w(every some filter forEach map reduce reduceRight find findIndex findLast
                       findLastIndex)

  # ArraySpeciesCreate: nil when the result is a plain array, else the object built by the
  # species constructor
  defp species_target(this, n) do
    if Browser.JS.Proxy.is_array(this) do
      c = Interp.get(this, "constructor")

      c =
        case c do
          {:obj, _} ->
            case Interp.get(c, {:symbol, :species, "Symbol.species"}) do
              :null -> :undefined
              sp -> sp
            end

          other ->
            other
        end

      cond do
        c == :undefined or c == Interp.get(proto(:array), "constructor") ->
          nil

        not function?(c) ->
          throw_error("TypeError", "object.constructor[Symbol.species] is not a constructor")

        true ->
          construct(c, [float(n)])
      end
    end
  end

  # the elements of a plain result array, defined one by one on a species target
  defp species_fill_from(res, target, set_len?), do: species_fill(target, res, set_len?)

  defp species_fill(nil, res, _set_len?), do: res

  defp species_fill(target, res, set_len?) do
    items = array_list(res)

    for {v, i} <- Enum.with_index(items) do
      Browser.JS.Props.define(
        target,
        float(i),
        new_object([
          {"value", v},
          {"writable", true},
          {"enumerable", true},
          {"configurable", true}
        ])
      )
    end

    if set_len?, do: Interp.put(target, "length", float(length(items)))
    target
  end

  # Array.prototype methods run on ToObject(this): numbers and booleans become wrappers
  defp array_fn(obj, name, fun) do
    def_fn(obj, name, fn this, args ->
      this =
        cond do
          nullish?(this) ->
            throw_error("TypeError", "Array.prototype.#{name} called on null or undefined")

          is_binary(this) ->
            box(this)

          is_boolean(this) or match?({:symbol, _, _}, this) or match?({:bigint, _}, this) ->
            box(this)

          is_number(this) or this in [:nan, :infinity, :neg_infinity] ->
            wrap(new_object([], proto(:number)), this)

          true ->
            this
        end

      # the length is read before the callback is checked
      if name in @callback_methods and not array?(this) and not is_binary(this),
        do: length_of(this, false)

      fun.(this, args)
    end)
  end

  defp array_methods(p) do
    # Array.prototype has a `length` of 0 (it is an array exotic object in the spec)
    {:obj, pid} = p
    po = deref(pid)
    store(pid, po |> Map.put(:class, :array) |> Map.put(:items, %{}) |> Map.put(:len, 0))

    array_fn(p, "push", fn this, args ->
      if fast_array?(this, length(args)) do
        {:obj, id} = this
        o = deref(id)

        {items, len} =
          Enum.reduce(args, {o.items, o.len}, fn v, {items, i} ->
            {Map.put(items, i, v), i + 1}
          end)

        Interp.store(id, %{o | items: items, len: len})
        float(len)
      else
        ArrayGeneric.push(this, args)
      end
    end)

    array_fn(p, "pop", fn this, _ ->
      if fast_array?(this) do
        {:obj, id} = this
        o = deref(id)

        if o.len == 0 do
          :undefined
        else
          last =
            case Map.get(o.items, o.len - 1, :undefined) do
              {:accessor, g, _} -> if function?(g), do: call(g, this, []), else: :undefined
              v -> v
            end

          Interp.store(id, %{o | items: Map.delete(o.items, o.len - 1), len: o.len - 1})
          last
        end
      else
        ArrayGeneric.pop(this)
      end
    end)

    array_fn(p, "shift", fn this, _ ->
      if fast_array?(this) do
        case elems(this) do
          [] ->
            put_elems(this, [])
            :undefined

          [first | rest] ->
            put_elems(this, rest)
            first
        end
      else
        ArrayGeneric.shift(this)
      end
    end)

    array_fn(p, "unshift", fn this, args ->
      if fast_array?(this, length(args)) do
        list = args ++ elems(this)
        put_elems(this, list)
        float(length(list))
      else
        ArrayGeneric.unshift(this, args)
      end
    end)

    array_fn(p, "slice", fn this, args ->
      if fast_array?(this) do
        list = elems(this)
        len = length(list)
        from = rel(arg(args, 0), len, 0)
        to = rel(arg(args, 1), len, len)
        target = species_target(this, max(to - from, 0))

        new_array(Enum.slice(list, from, max(to - from, 0)))
        |> species_fill_from(target, true)
      else
        ArrayGeneric.slice(this, args)
      end
    end)

    array_fn(p, "splice", fn this, args ->
      if fast_array?(this, length(args)) do
        list = elems(this)
        len = length(list)
        from = rel(arg(args, 0), len, 0)

        count =
          case args do
            [_] -> len - from
            [] -> 0
            [_, c | _] -> c |> to_int() |> max(0) |> min(len - from)
          end

        target = species_target(this, count)
        {head, rest} = Enum.split(list, from)
        {removed, tail} = Enum.split(rest, count)
        put_elems(this, head ++ Enum.drop(args, 2) ++ tail)
        new_array(removed) |> species_fill_from(target, true)
      else
        ArrayGeneric.splice(this, args)
      end
    end)

    array_fn(p, "concat", fn this, args -> ArrayGeneric.concat(this, args) end)

    array_fn(p, "toLocaleString", fn this, _ ->
      len = length_of(this)

      Enum.map_join(0..(len - 1)//1, ",", fn i ->
        case Interp.get(this, float(i)) do
          v when v in [:undefined, :null] ->
            ""

          v ->
            f = Interp.get(v, "toLocaleString")
            callable!(f)
            to_str(call(f, v, []))
        end
      end)
    end)

    array_fn(p, "join", fn this, args -> ArrayGeneric.join(this, arg(args, 0)) end)

    array_fn(p, "toString", fn this, _ ->
      case Interp.get(this, "join") do
        f when is_tuple(f) ->
          if function?(f), do: call(f, this, []), else: object_to_string(this)

        _ ->
          object_to_string(this)
      end
    end)

    array_fn(p, "reverse", fn this, _ ->
      if fast_array?(this) and not has_holes?(this) and not has_accessors?(this) do
        put_elems(this, Enum.reverse(elems(this)))
        this
      else
        ArrayGeneric.reverse(this)
      end
    end)

    array_fn(p, "indexOf", fn this, args -> ArrayGeneric.index_of(this, args) end)

    array_fn(p, "lastIndexOf", fn this, args -> ArrayGeneric.last_index_of(this, args) end)

    array_fn(p, "includes", fn this, args -> ArrayGeneric.includes(this, args) end)

    array_fn(p, "at", fn this, args -> ArrayGeneric.at(this, args) end)

    array_fn(p, "fill", fn this, args ->
      if fast_array?(this) do
        list = elems(this)
        len = length(list)
        from = rel(arg(args, 1), len, 0)
        to = rel(arg(args, 2), len, len)
        v = arg(args, 0)

        put_elems(
          this,
          list
          |> Enum.with_index()
          |> Enum.map(fn {x, i} -> if i >= from and i < to, do: v, else: x end)
        )

        this
      else
        ArrayGeneric.fill(this, args)
      end
    end)

    array_fn(p, "copyWithin", fn this, args -> ArrayGeneric.copy_within(this, args) end)

    array_fn(p, "flat", fn this, args ->
      depth = if arg(args, 0) == :undefined, do: 1, else: to_int(arg(args, 0))
      source = pairs(this)
      target = species_target(this, 0)
      new_array(flatten(source, depth, nil)) |> species_fill_from(target, false)
    end)

    array_fn(p, "flatMap", fn this, args ->
      source = pairs(this)
      f = callable!(arg(args, 0))
      target = species_target(this, 0)
      mapper = fn i, v -> call(f, arg(args, 1), [v, float(i), this]) end
      new_array(flatten(source, 1, mapper)) |> species_fill_from(target, false)
    end)

    array_fn(p, "forEach", fn this, args ->
      f = callable!(arg(args, 0))

      for {i, v} <- pairs(this), do: call(f, arg(args, 1), [v, float(i), this])
      :undefined
    end)

    array_fn(p, "map", fn this, args ->
      f = callable!(arg(args, 0))
      len = length_of(this)
      target = species_target(this, len)

      mapped =
        for {i, v} <- pairs(this), into: %{}, do: {i, call(f, arg(args, 1), [v, float(i), this])}

      species_fill(target, array_of(len, mapped), false)
    end)

    array_fn(p, "filter", fn this, args ->
      f = callable!(arg(args, 0))
      target = species_target(this, 0)

      new_array(
        for {i, v} <- pairs(this),
            truthy(call(f, arg(args, 1), [v, float(i), this])),
            do: v
      )
      |> species_fill_from(target, false)
    end)

    array_fn(p, "find", fn this, args ->
      f = callable!(arg(args, 0))

      Enum.find_value(each_pair(this, :asc), :undefined, fn {v, i} ->
        if truthy(call(f, arg(args, 1), [v, float(i), this])), do: v
      end)
    end)

    array_fn(p, "findIndex", fn this, args ->
      f = callable!(arg(args, 0))

      idx =
        Enum.find_value(each_pair(this, :asc), -1, fn {v, i} ->
          if truthy(call(f, arg(args, 1), [v, float(i), this])), do: i
        end)

      float(idx)
    end)

    array_fn(p, "findLast", fn this, args -> ArrayGeneric.find_last(this, args, false) end)

    array_fn(p, "findLastIndex", fn this, args -> ArrayGeneric.find_last(this, args, true) end)

    array_fn(p, "toReversed", fn this, _ -> ArrayGeneric.to_reversed(this) end)

    array_fn(p, "toSorted", fn this, args -> ArrayGeneric.to_sorted(this, args) end)
    set_arity(Interp.get(p, "toSorted"), 1)

    array_fn(p, "toSpliced", fn this, args -> ArrayGeneric.to_spliced(this, args) end)

    array_fn(p, "with", fn this, args -> ArrayGeneric.with_index(this, args) end)

    array_fn(p, "some", fn this, args ->
      f = callable!(arg(args, 0))

      Enum.any?(pairs(this), fn {i, v} -> truthy(call(f, arg(args, 1), [v, float(i), this])) end)
    end)

    array_fn(p, "every", fn this, args ->
      f = callable!(arg(args, 0))

      Enum.all?(pairs(this), fn {i, v} -> truthy(call(f, arg(args, 1), [v, float(i), this])) end)
    end)

    array_fn(p, "reduce", fn this, args ->
      reduce(this, callable!(arg(args, 0)), Enum.drop(args, 1), false)
    end)

    array_fn(p, "reduceRight", fn this, args ->
      reduce(this, callable!(arg(args, 0)), Enum.drop(args, 1), true)
    end)

    array_fn(p, "sort", fn this, args ->
      f = arg(args, 0)

      unless f == :undefined or function?(f),
        do:
          throw_error(
            "TypeError",
            "The comparison function must be either a function or undefined"
          )

      o = this_obj(this)
      len = if plain_elements?(o), do: nil, else: length_of(o, false)

      # the values are read first (holes skipped), sorted, then written back and the
      # slots left over deleted, so getters and setters see the spec's order of access
      items =
        if plain_elements?(o),
          do: array_list(o),
          else: for({_, v} <- pairs(o), do: v)

      {undefs, list} = Enum.split_with(items, &(&1 == :undefined))

      cmp =
        if function?(f),
          do: fn a, b ->
            case to_num(call(f, :undefined, [a, b])) do
              :nan -> true
              n -> Num.compare(n, 0.0) != :gt
            end
          end,
          else: fn a, b -> to_str(a) <= to_str(b) end

      sorted = Enum.sort(list, cmp) ++ undefs

      if plain_elements?(o) do
        put_elems(o, sorted)
      else
        sorted |> Enum.with_index() |> Enum.each(fn {v, i} -> Interp.put(o, float(i), v) end)

        for i <- length(sorted)..(len - 1)//1 do
          unless Interp.delete(o, float(i)),
            do: throw_error("TypeError", "Cannot delete property '#{i}'")
        end
      end

      o
    end)
  end

  # an array without holes or accessor elements, which can be sorted as a plain list
  defp plain_elements?(o) do
    array?(o) and not has_holes?(o) and
      not Enum.any?(array_list(o), &match?({:accessor, _, _}, &1))
  end

  # ── array methods on anything with a `length` ──────────────

  @max_length 50_000_000

  defp this_obj(this) do
    if this in [:undefined, :null],
      do: throw_error("TypeError", "Array.prototype method called on null or undefined"),
      else: this
  end

  defp callable!(f) do
    unless function?(f), do: throw_error("TypeError", "#{inspect_js(f, 0, [])} is not a function")
    f
  end

  # the elements `concat` adds for one argument: its elements when it is spreadable
  defp to_length(v) do
    case to_num(v) do
      n when is_number(n) -> n |> trunc() |> max(0) |> min(9_007_199_254_740_991)
      :infinity -> 9_007_199_254_740_991
      _ -> 0
    end
  end

  defp length_of(this, cap? \\ true) do
    cond do
      array?(this) ->
        to_int(Interp.get(this, "length"))

      is_binary(this) ->
        Str.length(this)

      true ->
        len = to_length(Interp.get(this_obj(this), "length"))
        if cap? and len > @max_length, do: throw_error("RangeError", "Invalid array length")
        len
    end
  end

  # the elements as a list, holes and missing indices reading as undefined
  defp elems(this) do
    cond do
      array?(this) and not has_holes?(this) -> array_list(this)
      true -> for i <- 0..(length_of(this) - 1)//1, do: Interp.get(this, float(i))
    end
  end

  # `{value, index}` of every index below the length (holes read as undefined), each read as it
  # is consumed so that a callback that changes the object is seen
  defp each_pair(this, dir) do
    len = length_of(this)
    range = if dir == :asc, do: 0..(len - 1)//1, else: (len - 1)..0//-1
    Stream.map(range, fn i -> {Interp.get(this, float(i)), i} end)
  end

  defp has_holes?({:obj, id}) do
    o = deref(id)
    map_size(o.items) != o.len
  end

  defp has_accessors?({:obj, id}),
    do: Enum.any?(deref(id).items, fn {_, v} -> match?({:accessor, _, _}, v) end)

  # `{index, value}` of the elements that exist, looked at one by one as they are consumed (a
  # callback that changes the array is seen by the iteration); the length is read once
  defp pairs(this, dir \\ :asc, from \\ nil) do
    len = length_of(this, false)

    {first, last} =
      if dir == :asc, do: {from || 0, len - 1}, else: {from || len - 1, 0}

    range = if dir == :asc, do: first..last//1, else: first..last//-1

    if very_sparse?(this, len) do
      # an array with a huge length and few elements: only the slots that exist are visited
      {:obj, id} = this
      keys = for k <- Map.keys(deref(id).items), k in range, do: k
      keys = if dir == :asc, do: Enum.sort(keys), else: Enum.sort(keys, :desc)

      Stream.flat_map(keys, fn i ->
        if has_property?(this, float(i)), do: [{i, Interp.get(this, float(i))}], else: []
      end)
    else
      Stream.flat_map(range, fn i ->
        present =
          if is_binary(this), do: i < len, else: has_property?(this, float(i))

        if present, do: [{i, Interp.get(this, float(i))}], else: []
      end)
    end
  end

  defp very_sparse?({:obj, id} = this, len) do
    len > 100_000 and array?(this) and len - map_size(deref(id).items) > 100_000
  end

  defp very_sparse?(_, _), do: false

  # an array of `len` slots with values at some of them
  def array_of(len, items) do
    arr = new_array([])
    {:obj, id} = arr
    store(id, %{deref(id) | items: items, len: len})
    arr
  end

  # the elements written back: to the array, or to an object index by index
  defp put_elems(this, list) do
    if array?(this) do
      set_array_list(this, list)
    else
      o = this_obj(this)
      old = length_of(o)
      list |> Enum.with_index() |> Enum.each(fn {v, i} -> Interp.put(o, float(i), v) end)
      for i <- length(list)..(old - 1)//1, do: Interp.delete(o, float(i))
      Interp.put(o, "length", float(length(list)))
    end
  end

  defp reduce(this, f, rest, right?) do
    stream = pairs(this, if(right?, do: :desc, else: :asc))
    init = if rest == [], do: :none, else: {:ok, hd(rest)}

    # one pass: the first element read is the accumulator when no initial value was given
    result =
      Enum.reduce(stream, init, fn
        {_i, v}, :none -> {:ok, v}
        {i, v}, {:ok, acc} -> {:ok, call(f, :undefined, [acc, v, float(i), this])}
      end)

    case result do
      {:ok, acc} -> acc
      :none -> throw_error("TypeError", "Reduce of empty array with no initial value")
    end
  end

  # FlattenIntoArray over the present elements of `source` ({index, value} pairs); a nested
  # array-like is read through its own `length` and element accessors
  defp flatten(source, depth, mapper) do
    Enum.flat_map(source, fn {i, v} ->
      v = if mapper, do: mapper.(i, v), else: v

      if depth > 0 and Browser.JS.Proxy.is_array(v),
        do: flatten(pairs(v), depth - 1, nil),
        else: [v]
    end)
  end

  # ── String / Number / Boolean ──────────────────────────────

  defp install_primitives(scope) do
    # the prototypes are themselves a String, a Number and a Boolean
    wrap(proto(:string), "")
    put_const(proto(:string), "length", 0.0)
    wrap(proto(:number), 0.0)
    wrap(proto(:boolean), false)

    str =
      constructor(scope, "String", proto(:string), fn this, args ->
        s =
          case args do
            [] ->
              ""

            [{:symbol, _, _} = sym | _] ->
              if wrapper_target?(this, :string),
                do: to_str(sym),
                else: call(Interp.get(sym, "toString"), sym, [])

            [v | _] ->
              to_str(v)
          end

        if wrapper_target?(this, :string) do
          put_const(this, "length", float(Str.length(s)))
          wrap(this, s)
        else
          s
        end
      end)

    # `String.raw`a\n${b}c``: the raw strings with the substitutions between them
    def_fn(str, "raw", fn _, args ->
      cooked = arg(args, 0)

      if nullish?(cooked),
        do: throw_error("TypeError", "Cannot convert undefined or null to object")

      raw = Interp.get(cooked, "raw")

      if nullish?(raw),
        do: throw_error("TypeError", "Cannot convert undefined or null to object")

      count =
        raw
        |> Interp.get("length")
        |> to_num()
        |> then(&if(is_number(&1), do: trunc(&1), else: 0))

      subs = Enum.drop(args, 1)

      Str.join(
        Enum.map(0..(count - 1)//1, fn i ->
          piece = to_str(Interp.get(raw, Integer.to_string(i)))

          if i < count - 1 and i < length(subs),
            do: Str.cat(piece, to_str(Enum.at(subs, i))),
            else: piece
        end)
      )
    end)

    def_fn(str, "fromCodePoint", fn _, args ->
      Enum.map(args, fn v ->
        n = to_num(v)

        unless is_number(n) and n == trunc(n) and n >= 0 and n <= 0x10FFFF,
          do: throw_error("RangeError", "Invalid code point #{to_str(v)}")

        n = trunc(n)
        Str.from_units(if n >= 0x10000, do: pair(n), else: [n])
      end)
      |> Str.join()
    end)

    # UTF-16 code units: a surrogate pair is one character, a lone surrogate cannot be kept
    def_fn(str, "fromCharCode", fn _, args ->
      args |> Enum.map(&(&1 |> to_num() |> code_unit())) |> units_to_string()
    end)

    num =
      constructor(scope, "Number", proto(:number), fn this, args ->
        n =
          if args == [] do
            0.0
          else
            case to_primitive(hd(args), "number") do
              {:bigint, b} -> Browser.JS.BigInt.to_float(b)
              p -> to_num(p)
            end
          end

        if wrapper_target?(this, :number), do: wrap(this, n), else: n
      end)

    constructor(scope, "Boolean", proto(:boolean), fn this, args ->
      b = truthy(arg(args, 0))
      if wrapper_target?(this, :boolean), do: wrap(this, b), else: b
    end)

    def_fn(num, "isInteger", fn _, args ->
      v = arg(args, 0)
      is_number(v) and v == trunc(v)
    end)

    def_fn(num, "isSafeInteger", fn _, args ->
      v = arg(args, 0)
      is_number(v) and v == trunc(v) and abs(v) <= 9_007_199_254_740_991
    end)

    def_fn(num, "isFinite", fn _, args -> is_number(arg(args, 0)) end)
    def_fn(num, "isNaN", fn _, args -> arg(args, 0) == :nan end)

    for {k, v} <- [
          {"MAX_SAFE_INTEGER", 9_007_199_254_740_991.0},
          {"MIN_SAFE_INTEGER", -9_007_199_254_740_991.0},
          {"EPSILON", 2.220446049250313e-16},
          {"MAX_VALUE", 1.7976931348623157e308},
          {"MIN_VALUE", 5.0e-324},
          {"POSITIVE_INFINITY", :infinity},
          {"NEGATIVE_INFINITY", :neg_infinity},
          {"NaN", :nan}
        ],
        do: put_const(num, k, v)

    parse_float = native("parseFloat", fn _, args -> Num.parse_prefix(to_str(arg(args, 0))) end)

    parse_int =
      native("parseInt", fn _, args -> parse_int(to_str(arg(args, 0)), arg(args, 1)) end)

    put_hidden(num, "parseFloat", parse_float)
    put_hidden(num, "parseInt", parse_int)
    declare(scope, "parseFloat", parse_float)
    declare(scope, "parseInt", parse_int)
    declare(scope, "isNaN", native("isNaN", fn _, args -> to_num(arg(args, 0)) == :nan end))
    install_uri(scope)

    declare(
      scope,
      "isFinite",
      native("isFinite", fn _, args -> is_number(to_num(arg(args, 0))) end)
    )
  end

  # encodeURIComponent and friends. Characters not in `keep` become %XX per UTF-8 byte.
  @uri_unreserved ~c"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()"
  @uri_reserved ~c";/?:@&=+$,#"

  defp install_uri(scope) do
    for {name, keep} <- [
          {"encodeURIComponent", @uri_unreserved},
          {"encodeURI", @uri_unreserved ++ @uri_reserved}
        ] do
      declare(scope, name, native(name, fn _, args -> uri_encode(to_str(arg(args, 0)), keep) end))
    end

    for {name, keep} <- [{"decodeURIComponent", []}, {"decodeURI", @uri_reserved}] do
      declare(scope, name, native(name, fn _, args -> uri_decode(to_str(arg(args, 0)), keep) end))
    end
  end

  defp uri_encode(str, keep) do
    unless String.valid?(str), do: throw_error("URIError", "URI malformed")

    for <<b <- str>>, into: "" do
      if b in keep,
        do: <<b>>,
        else: "%" <> String.upcase(Base.encode16(<<b>>))
    end
  end

  defp uri_decode(str, keep), do: uri_decode(str, keep, [])

  defp uri_decode("", _, acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  defp uri_decode(<<"%", h::binary-size(2), rest::binary>>, keep, acc) do
    with {:ok, b} <- hex_byte(h) do
      if b < 0x80 do
        if b in keep,
          do: uri_decode(rest, keep, [<<"%", h::binary>> | acc]),
          else: uri_decode(rest, keep, [<<b>> | acc])
      else
        n = if b >= 0xF0, do: 3, else: if(b >= 0xE0, do: 2, else: 1)
        {bytes, rest} = uri_continuation(rest, n, [<<b>>])
        bin = IO.iodata_to_binary(bytes)

        if b >= 0xC0 and String.valid?(bin),
          do: uri_decode(rest, keep, [bin | acc]),
          else: throw_error("URIError", "URI malformed")
      end
    else
      _ -> throw_error("URIError", "URI malformed")
    end
  end

  defp uri_decode(<<"%", _::binary>>, _, _), do: throw_error("URIError", "URI malformed")

  defp uri_decode(<<c::utf8, rest::binary>>, keep, acc),
    do: uri_decode(rest, keep, [<<c::utf8>> | acc])

  defp uri_decode(<<b, rest::binary>>, keep, acc), do: uri_decode(rest, keep, [<<b>> | acc])

  # two hex digits to a byte (`Base.decode16` raises and rescues on bad input: slow)
  defp hex_byte(<<a, b>>) do
    with x when x != nil <- hex_digit(a), y when y != nil <- hex_digit(b), do: {:ok, x * 16 + y}
  end

  defp hex_digit(c) when c in ?0..?9, do: c - ?0
  defp hex_digit(c) when c in ?a..?f, do: c - ?a + 10
  defp hex_digit(c) when c in ?A..?F, do: c - ?A + 10
  defp hex_digit(_), do: nil

  defp uri_continuation(rest, 0, acc), do: {Enum.reverse(acc), rest}

  defp uri_continuation(<<"%", h::binary-size(2), rest::binary>>, n, acc) do
    case hex_byte(h) do
      {:ok, b} when b in 0x80..0xBF -> uri_continuation(rest, n - 1, [<<b>> | acc])
      _ -> throw_error("URIError", "URI malformed")
    end
  end

  defp uri_continuation(_, _, _), do: throw_error("URIError", "URI malformed")

  defp parse_int(s, radix_arg) do
    s = Interp.js_trim_start(s)

    {sign, s} =
      case s do
        "-" <> r -> {-1, r}
        "+" <> r -> {1, r}
        _ -> {1, s}
      end

    radix = Num.int32(to_num(radix_arg))

    {radix, s} =
      case {radix, s} do
        {r, "0x" <> rest} when r in [0, 16] -> {16, rest}
        {r, "0X" <> rest} when r in [0, 16] -> {16, rest}
        {0, s} -> {10, s}
        {r, s} -> {r, s}
      end

    if radix < 2 or radix > 36 do
      :nan
    else
      digits = s |> :binary.bin_to_list() |> Enum.take_while(&digit?(&1, radix))

      case digits do
        [] -> :nan
        _ -> sign * String.to_integer(List.to_string(digits), radix) * 1.0
      end
    end
  end

  defp digit?(c, radix) do
    v =
      cond do
        c in ?0..?9 -> c - ?0
        c in ?A..?Z -> c - ?A + 10
        c in ?a..?z -> c - ?a + 10
        true -> 99
      end

    v < radix
  end

  # ToIntegerOrInfinity, with the infinities as numbers far outside any range
  defp int_or_inf(v) do
    case to_num(v) do
      :nan -> 0
      :infinity -> 1_000_000
      :neg_infinity -> -1_000_000
      n -> n |> trunc() |> max(-1_000_000) |> min(1_000_000)
    end
  end

  defp def_fn1(obj, name, fun) do
    f = native(name, fun)
    set_arity(f, 1)
    put_hidden(obj, name, f)
  end

  defp number_methods(p) do
    def_fn(p, "toLocaleString", fn this, _ ->
      Num.to_string(this_prim(this, :number, "Number.prototype.toLocaleString"))
    end)

    def_fn1(p, "toString", fn this, args ->
      this = this_prim(this, :number, "Number.prototype.toString")

      radix =
        case arg(args, 0) do
          :undefined -> 10
          r -> int_or_inf(r)
        end

      if radix < 2 or radix > 36,
        do: throw_error("RangeError", "toString() radix must be between 2 and 36")

      if radix == 10, do: Num.to_string(this), else: Browser.JS.NumberFormat.to_radix(this, radix)
    end)

    def_fn1(p, "toFixed", fn this, args ->
      this = this_prim(this, :number, "Number.prototype.toFixed")
      Browser.JS.NumberFormat.to_fixed(this, int_or_inf(arg(args, 0)))
    end)

    def_fn1(p, "toExponential", fn this, args ->
      this = this_prim(this, :number, "Number.prototype.toExponential")

      f =
        case arg(args, 0) do
          :undefined -> :undefined
          v -> int_or_inf(v)
        end

      Browser.JS.NumberFormat.to_exponential(this, f)
    end)

    def_fn1(p, "toPrecision", fn this, args ->
      this = this_prim(this, :number, "Number.prototype.toPrecision")

      case arg(args, 0) do
        :undefined -> Num.to_string(this)
        v -> Browser.JS.NumberFormat.to_precision(this, int_or_inf(v))
      end
    end)

    def_fn(p, "valueOf", fn this, _ -> this_prim(this, :number, "Number.prototype.valueOf") end)

    def_fn(proto(:boolean), "toString", fn this, _ ->
      this |> this_prim(:boolean, "Boolean.prototype.toString") |> to_str()
    end)

    def_fn(proto(:boolean), "valueOf", fn this, _ ->
      this_prim(this, :boolean, "Boolean.prototype.valueOf")
    end)
  end

  # ToObject of a primitive: a String, Number, Boolean or BigInt wrapper
  @doc false
  def box(v) when is_binary(v) do
    o = new_object([], proto(:string))
    put_const(o, "length", float(Str.length(v)))
    wrap(o, v)
  end

  def box(v) when is_boolean(v), do: wrap(new_object([], proto(:boolean)), v)
  def box({:bigint, _} = v), do: wrap(new_object([], proto(:bigint)), v)
  def box({:symbol, _, _} = v), do: wrap(new_object([], proto(:symbol)), v)
  def box(v), do: wrap(new_object([], proto(:number)), v)

  # `new String(x)`, `new Number(x)`, `new Boolean(x)`: the constructor was handed a fresh object
  # of the right prototype, which becomes the wrapper
  defp wrapper_target?({:obj, id}, kind) do
    o = deref(id)
    not Map.has_key?(o, :prim) and inherits_from?(o.proto, proto(kind))
  end

  defp wrapper_target?(_, _), do: false

  # a subclass instance has the subclass prototype, which inherits from the wrapper's
  defp inherits_from?(p, target) when p == target, do: true
  defp inherits_from?({:obj, id}, target), do: inherits_from?(deref(id).proto, target)
  defp inherits_from?(_, _), do: false

  defp wrap({:obj, id} = o, prim) do
    store(id, Map.put(deref(id), :prim, prim))
    o
  end

  defp unwrap({:obj, id} = o) do
    case Map.fetch(deref(id), :prim) do
      {:ok, prim} -> prim
      :error -> o
    end
  end

  defp unwrap(v), do: v

  # the primitive of a String/Number/Boolean `this`, or a TypeError
  defp this_prim(this, kind, method) do
    v = unwrap(this)

    ok? =
      case kind do
        :string -> is_binary(v)
        :boolean -> is_boolean(v)
        :number -> is_number(v) or v in [:nan, :infinity, :neg_infinity]
      end

    if ok?,
      do: v,
      else: throw_error("TypeError", "#{method} requires that 'this' be a #{kind}")
  end

  # String.prototype methods take any `this` that is not null or undefined, as a string
  defp str_fn(obj, name, fun) do
    def_fn(obj, name, fn this, args ->
      if nullish?(this),
        do: throw_error("TypeError", "String.prototype.#{name} called on null or undefined"),
        else: fun.(to_str(this), args)
    end)
  end

  defp string_methods(p) do
    def_fn(p, "toString", fn this, _ -> this_prim(this, :string, "String.prototype.toString") end)
    def_fn(p, "valueOf", fn this, _ -> this_prim(this, :string, "String.prototype.valueOf") end)
    str_fn(p, "toUpperCase", fn this, _ -> String.upcase(this) end)
    str_fn(p, "toLowerCase", fn this, _ -> String.downcase(this) end)
    str_fn(p, "trim", fn this, _ -> Interp.js_trim(this) end)
    str_fn(p, "trimStart", fn this, _ -> Interp.js_trim_start(this) end)
    str_fn(p, "trimEnd", fn this, _ -> Interp.js_trim_end(this) end)
    str_fn(p, "charAt", fn this, args -> Str.at(this, to_int(arg(args, 0))) || "" end)

    str_fn(p, "at", fn this, args ->
      n = to_int(arg(args, 0))
      Str.at(this, n) || :undefined
    end)

    str_fn(p, "charCodeAt", fn this, args ->
      case Str.at(this, to_int(arg(args, 0))) do
        nil -> :nan
        u -> float(Str.code_unit_at(u, 0))
      end
    end)

    str_fn(p, "codePointAt", fn this, args ->
      case Str.code_point_at(this, to_int(arg(args, 0))) do
        nil -> :undefined
        c -> float(c)
      end
    end)

    str_fn(p, "indexOf", fn this, args ->
      from = max(to_int(arg(args, 1)), 0)
      float(index_of(this, to_str(arg(args, 0)), from))
    end)

    str_fn(p, "lastIndexOf", fn this, args ->
      needle = to_str(arg(args, 0))

      positions =
        for i <- 0..max(Str.length(this) - Str.length(needle), 0)//1,
            cp_slice(this, i, Str.length(needle)) == needle,
            do: i

      float(List.last(positions) || -1)
    end)

    str_fn(p, "includes", fn this, args -> index_of(this, to_str(arg(args, 0)), 0) >= 0 end)

    str_fn(p, "startsWith", fn this, args ->
      String.starts_with?(cp_slice(this, max(to_int(arg(args, 1)), 0), nil), to_str(arg(args, 0)))
    end)

    str_fn(p, "endsWith", fn this, args -> String.ends_with?(this, to_str(arg(args, 0))) end)
    str_fn(p, "concat", fn this, args -> Str.join([this | Enum.map(args, &to_str/1)]) end)
    str_fn(p, "repeat", fn this, args -> String.duplicate(this, max(to_int(arg(args, 0)), 0)) end)

    str_fn(p, "slice", fn this, args ->
      len = Str.length(this)
      from = rel(arg(args, 0), len, 0)
      to = rel(arg(args, 1), len, len)
      cp_slice(this, from, max(to - from, 0))
    end)

    str_fn(p, "substring", fn this, args ->
      len = Str.length(this)

      clamp = fn v, default ->
        if v == :undefined, do: default, else: v |> to_int() |> max(0) |> min(len)
      end

      a = clamp.(arg(args, 0), 0)
      b = clamp.(arg(args, 1), len)
      cp_slice(this, min(a, b), abs(b - a))
    end)

    # `substr(start, length)`: a negative start counts from the end
    str_fn(p, "substr", fn this, args ->
      len = Str.length(this)
      start = arg(args, 0) |> to_int()
      start = if start < 0, do: max(len + start, 0), else: min(start, len)

      count =
        case arg(args, 1) do
          :undefined -> len - start
          v -> v |> to_int() |> max(0) |> min(len - start)
        end

      cp_slice(this, start, count)
    end)

    def_fn(p, "match", fn this, args -> Browser.JS.RegExp.str_match(this, arg(args, 0)) end)

    def_fn(p, "matchAll", fn this, args ->
      Browser.JS.RegExp.str_match_all(this, arg(args, 0))
    end)

    def_fn(p, "search", fn this, args -> Browser.JS.RegExp.str_search(this, arg(args, 0)) end)

    def_fn(p, "split", fn this, args ->
      Browser.JS.RegExp.str_split(this, arg(args, 0), arg(args, 1))
    end)

    def_fn(p, "replace", fn this, args ->
      Browser.JS.RegExp.str_replace(this, arg(args, 0), arg(args, 1), false)
    end)

    def_fn(p, "replaceAll", fn this, args ->
      Browser.JS.RegExp.str_replace(this, arg(args, 0), arg(args, 1), true)
    end)

    str_fn(p, "padStart", fn this, args -> pad(this, args, :leading) end)
    str_fn(p, "padEnd", fn this, args -> pad(this, args, :trailing) end)

    str_fn(p, "localeCompare", fn this, args ->
      other = to_str(arg(args, 0))

      cond do
        this < other -> -1.0
        this > other -> 1.0
        true -> 0.0
      end
    end)
  end

  defp code_unit(n) when is_number(n), do: trunc(n) |> Bitwise.band(0xFFFF)
  defp code_unit(_), do: 0

  defp pair(n),
    do: [0xD800 + Bitwise.bsr(n - 0x10000, 10), 0xDC00 + Bitwise.band(n - 0x10000, 0x3FF)]

  defp units_to_string(units), do: Str.from_units(units)

  defp cp_slice(s, from, count), do: Str.slice(s, from, count)

  defp index_of(s, needle, from), do: Str.index_of(s, needle, from)

  defp pad(s, args, side) do
    target = to_int(arg(args, 0))
    filler = if arg(args, 1) == :undefined, do: " ", else: to_str(arg(args, 1))
    need = target - Str.length(s)

    if need <= 0 or filler == "" do
      s
    else
      padding =
        filler |> String.duplicate(div(need, Str.length(filler)) + 1) |> cp_slice(0, need)

      if side == :leading, do: Str.cat(padding, s), else: Str.cat(s, padding)
    end
  end

  # ── Math ───────────────────────────────────────────────────

  defp install_math(scope) do
    math = new_object()
    declare(scope, "Math", math)
    put_tag(math, "Math")

    for {k, v} <- [
          {"PI", :math.pi()},
          {"E", :math.exp(1)},
          {"LN2", :math.log(2)},
          {"LN10", :math.log(10)},
          {"LOG2E", 1 / :math.log(2)},
          {"LOG10E", 1 / :math.log(10)},
          {"SQRT2", :math.sqrt(2)},
          {"SQRT1_2", :math.sqrt(0.5)}
        ],
        do: put_const(math, k, v)

    # `fun` gets a number (a float or :nan / :infinity / :neg_infinity)
    unary = fn name, fun ->
      def_fn(math, name, fn _, args ->
        case to_num(arg(args, 0)) do
          n when is_atom(n) -> fun.(n)
          n -> fun.(n * 1.0)
        end
      end)
    end

    # zeros and non-finite values map to themselves
    keep_special = fn f -> fn n -> if is_atom(n) or n == 0, do: n, else: f.(n) end end
    nan_for_atoms = fn f -> fn n -> if is_atom(n), do: :nan, else: f.(n) end end
    sign_of = fn n -> if n < 0, do: -1.0, else: 1.0 end

    guarded = fn f, over ->
      fn n ->
        try do
          f.(n)
        rescue
          ArithmeticError -> over.(n)
        end
      end
    end

    neg_zero = -1.0 * 0.0

    unary.("floor", keep_special.(&:math.floor/1))
    unary.("ceil", keep_special.(&:math.ceil/1))

    unary.(
      "trunc",
      keep_special.(fn n ->
        t = trunc(n) * 1.0
        if t == 0.0 and n < 0, do: neg_zero, else: t
      end)
    )

    unary.(
      "round",
      keep_special.(fn n ->
        f = :math.floor(n)
        r = if n - f >= 0.5, do: f + 1.0, else: f
        if r == 0.0 and n < 0, do: neg_zero, else: r
      end)
    )

    unary.("abs", fn n ->
      if n == :neg_infinity, do: :infinity, else: if(is_atom(n), do: n, else: abs(n))
    end)

    unary.("sign", fn n ->
      cond do
        is_atom(n) and n != :nan -> if(n == :infinity, do: 1.0, else: -1.0)
        n == :nan -> :nan
        n > 0 -> 1.0
        n < 0 -> -1.0
        true -> n
      end
    end)

    unary.("sqrt", fn n ->
      cond do
        n == :infinity -> n
        is_atom(n) -> :nan
        n < 0 -> :nan
        true -> :math.sqrt(n)
      end
    end)

    unary.(
      "cbrt",
      keep_special.(fn n ->
        x = abs(n)
        r = :math.pow(x, 1 / 3)
        r = r - (r * r * r - x) / (3 * r * r)
        sign_of.(n) * r
      end)
    )

    unary.("sin", nan_for_atoms.(&:math.sin/1))
    unary.("cos", nan_for_atoms.(&:math.cos/1))
    unary.("tan", nan_for_atoms.(&:math.tan/1))

    unary.("asin", fn n ->
      if is_atom(n) or abs(n) > 1, do: :nan, else: :math.asin(n)
    end)

    unary.("acos", fn n ->
      if is_atom(n) or abs(n) > 1, do: :nan, else: :math.acos(n)
    end)

    unary.("atan", fn
      :infinity -> :math.pi() / 2
      :neg_infinity -> -:math.pi() / 2
      :nan -> :nan
      n -> :math.atan(n)
    end)

    unary.("sinh", fn
      n when is_atom(n) ->
        n

      n ->
        guarded.(&:math.sinh/1, fn n -> if n < 0, do: :neg_infinity, else: :infinity end).(n)
    end)

    unary.("cosh", fn
      :nan -> :nan
      n when is_atom(n) -> :infinity
      n -> guarded.(&:math.cosh/1, fn _ -> :infinity end).(n)
    end)

    unary.("tanh", fn
      :infinity -> 1.0
      :neg_infinity -> -1.0
      :nan -> :nan
      n -> if abs(n) > 20, do: sign_of.(n), else: :math.tanh(n)
    end)

    unary.(
      "asinh",
      keep_special.(fn n ->
        x = abs(n)

        sign_of.(n) *
          if(x > 1.0e150,
            do: :math.log(x) + :math.log(2),
            else: :math.log(x + :math.sqrt(x * x + 1))
          )
      end)
    )

    unary.("acosh", fn
      :infinity -> :infinity
      n when is_atom(n) -> :nan
      n when n < 1 -> :nan
      n -> if n > 1.0e150, do: :math.log(n) + :math.log(2), else: :math.acosh(n)
    end)

    unary.("atanh", fn
      n when is_atom(n) -> :nan
      n when abs(n) > 1 -> :nan
      n when n == 1 -> :infinity
      n when n == -1 -> :neg_infinity
      n when n == 0 -> n
      n -> 0.5 * :math.log((1 + n) / (1 - n))
    end)

    unary.("exp", fn n ->
      cond do
        is_atom(n) -> if n == :neg_infinity, do: 0.0, else: n
        n > 709.79 -> :infinity
        true -> :math.exp(n)
      end
    end)

    unary.("expm1", fn n ->
      cond do
        n == :neg_infinity -> -1.0
        is_atom(n) -> n
        n == 0 -> n
        n > 709.79 -> :infinity
        abs(n) < 1.0e-5 -> n + n * n / 2 + n * n * n / 6
        true -> :math.exp(n) - 1
      end
    end)

    unary.("log", fn n ->
      cond do
        n == :infinity -> n
        is_atom(n) -> :nan
        n < 0 -> :nan
        n == 0 -> :neg_infinity
        true -> :math.log(n)
      end
    end)

    unary.("log1p", fn n ->
      cond do
        n == :infinity -> n
        is_atom(n) -> :nan
        n < -1 -> :nan
        n == -1 -> :neg_infinity
        n == 0 -> n
        abs(n) < 1.0e-4 -> n - n * n / 2 + n * n * n / 3
        true -> :math.log(1 + n)
      end
    end)

    unary.("log2", fn n ->
      cond do
        n == :infinity -> n
        is_atom(n) -> :nan
        n < 0 -> :nan
        n == 0 -> :neg_infinity
        true -> :math.log2(n)
      end
    end)

    unary.("log10", fn n ->
      cond do
        n == :infinity -> n
        is_atom(n) -> :nan
        n < 0 -> :nan
        n == 0 -> :neg_infinity
        true -> :math.log10(n)
      end
    end)

    def_fn(math, "atan2", fn _, args ->
      y = to_num(arg(args, 0))
      x = to_num(arg(args, 1))
      pi = :math.pi()

      cond do
        y == :nan or x == :nan ->
          :nan

        y in [:infinity, :neg_infinity] ->
          ys = if y == :infinity, do: 1.0, else: -1.0

          case x do
            :infinity -> ys * pi / 4
            :neg_infinity -> ys * 3 * pi / 4
            _ -> ys * pi / 2
          end

        x == :infinity ->
          if y < 0 or (y == 0 and match?(<<1::1, _::63>>, <<y * 1.0::float-64>>)),
            do: neg_zero,
            else: 0.0

        x == :neg_infinity ->
          if y < 0 or (y == 0 and match?(<<1::1, _::63>>, <<y * 1.0::float-64>>)),
            do: -pi,
            else: pi

        true ->
          :math.atan2(y * 1.0, x * 1.0)
      end
    end)

    def_fn(math, "pow", fn _, args -> Num.pow(to_num(arg(args, 0)), to_num(arg(args, 1))) end)
    def_fn(math, "random", fn _, _ -> :rand.uniform() end)
    def_fn(math, "max", fn _, args -> extreme(args, :neg_infinity, :gt) end)
    def_fn(math, "min", fn _, args -> extreme(args, :infinity, :lt) end)

    def_fn(math, "clz32", fn _, args ->
      n = args |> arg(0) |> to_num() |> Num.uint32()
      float(32 - if(n == 0, do: 0, else: length(Integer.digits(n, 2))))
    end)

    def_fn(math, "imul", fn _, args ->
      float(Num.int32(Num.int32(to_num(arg(args, 0))) * Num.int32(to_num(arg(args, 1)))))
    end)

    def_fn(math, "sumPrecise", fn _, args ->
      sum_precise(sum_items(arg(args, 0)))
    end)

    def_fn(math, "fround", fn _, args ->
      case to_num(arg(args, 0)) do
        n when is_atom(n) -> n
        n when abs(n) >= 3.4028235677973366e38 -> if n < 0, do: :neg_infinity, else: :infinity
        n -> n |> then(&<<&1 * 1.0::float-32>>) |> then(fn <<f::float-32>> -> f end)
      end
    end)

    def_fn(math, "f16round", fn _, args -> Browser.JS.TypedArrays.f16round(arg(args, 0)) end)

    def_fn(math, "hypot", fn _, args ->
      nums = Enum.map(args, &to_num/1)

      cond do
        Enum.any?(nums, &(&1 in [:infinity, :neg_infinity])) ->
          :infinity

        :nan in nums ->
          :nan

        true ->
          m = nums |> Enum.map(&abs/1) |> Enum.max(fn -> 0.0 end)

          if m == 0,
            do: 0.0,
            else: m * :math.sqrt(Enum.reduce(nums, 0.0, fn n, acc -> acc + n / m * (n / m) end))
      end
    end)
  end

  # pulls the values for Math.sumPrecise through the iterator protocol, closing it on a non-number
  defp sum_items(v) do
    unless match?({:obj, _}, v), do: throw_error("TypeError", "Math.sumPrecise: not iterable")
    f = Interp.get(v, {:symbol, :iterator, "Symbol.iterator"})
    unless Interp.function?(f), do: throw_error("TypeError", "Math.sumPrecise: not iterable")
    it = call(f, v, [])
    next = Interp.get(it, "next")
    sum_pull(it, next, [])
  end

  defp sum_pull(it, next, acc) do
    case Interp.iter_step(it, next) do
      :done ->
        Enum.reverse(acc)

      {:ok, x} ->
        unless num?(x) do
          Interp.iter_close(it, true)
          throw_error("TypeError", "Math.sumPrecise: not a number")
        end

        sum_pull(it, next, [x | acc])
    end
  end

  # Math.sumPrecise: the exact sum of the numbers (as integers of 2^-1074), rounded once
  defp sum_precise(items) do
    {state, total} =
      Enum.reduce(items, {%{nan: false, pos: false, neg: false, nonneg0: false}, 0}, fn v,
                                                                                        {st, sum} ->
        unless num?(v), do: throw_error("TypeError", "Math.sumPrecise: not a number")

        case v do
          :nan ->
            {%{st | nan: true}, sum}

          :infinity ->
            {%{st | pos: true}, sum}

          :neg_infinity ->
            {%{st | neg: true}, sum}

          f ->
            f = f * 1.0
            negzero? = f == 0.0 and match?(<<1::1, _::63>>, <<f::float-64>>)
            st = if negzero?, do: st, else: %{st | nonneg0: true}
            {n, d} = Float.ratio(f)
            {st, sum + n * div(Bitwise.bsl(1, 1074), d)}
        end
      end)

    cond do
      state.nan or (state.pos and state.neg) -> :nan
      state.pos -> :infinity
      state.neg -> :neg_infinity
      total == 0 -> if state.nonneg0, do: 0.0, else: -0.0
      true -> scaled_to_float(total)
    end
  end

  defp scaled_to_float(total) do
    negative? = total < 0
    m = abs(total)
    bits = bit_length(m)

    value =
      if bits <= 53 do
        m * :math.pow(2, -1074)
      else
        shift = bits - 53
        q = Bitwise.bsr(m, shift)
        rem = Bitwise.band(m, Bitwise.bsl(1, shift) - 1)
        half = Bitwise.bsl(1, shift - 1)
        q = if rem > half or (rem == half and Bitwise.band(q, 1) == 1), do: q + 1, else: q

        {q, shift} =
          if q == Bitwise.bsl(1, 53), do: {Bitwise.bsl(1, 52), shift + 1}, else: {q, shift}

        if shift - 1074 + 53 > 1024, do: :infinity, else: q * :math.pow(2, shift - 1074)
      end

    cond do
      value == :infinity -> if negative?, do: :neg_infinity, else: :infinity
      negative? -> -value
      true -> value
    end
  end

  defp bit_length(0), do: 0
  defp bit_length(n), do: length(Integer.digits(n, 2))

  # max prefers +0 and min prefers -0
  defp zero_pick(n, acc, want) do
    neg? = fn z -> match?(<<1::1, _::63>>, <<z * 1.0::float-64>>) end
    if want == :gt, do: if(neg?.(n), do: acc, else: n), else: if(neg?.(n), do: n, else: acc)
  end

  defp extreme(args, start, want) do
    Enum.reduce(args, start, fn v, acc ->
      n = to_num(v)

      cond do
        acc == :nan or n == :nan -> :nan
        Num.compare(n, acc) == want -> n
        n == 0 and acc == 0 -> zero_pick(n, acc, want)
        true -> acc
      end
    end)
  end

  # ── console ────────────────────────────────────────────────

  defp install_console(scope), do: Browser.JS.ConsoleApi.install(scope)

  @doc "Node-style one-line rendering of a value, as `console.log` prints it."
  def inspect_js(v, depth, seen) do
    cond do
      is_binary(v) ->
        "'" <> String.replace(v, "'", "\\'") <> "'"

      v == :undefined ->
        "undefined"

      v == :null ->
        "null"

      is_boolean(v) ->
        to_str(v)

      num?(v) ->
        Num.to_string(v)

      big?(v) ->
        to_str(v) <> "n"

      function?(v) ->
        function_label(v)

      v in seen ->
        "[Circular]"

      error?(v) ->
        to_str(call(Interp.get(v, "toString"), v, []))

      array?(v) and depth > 2 ->
        "[Array]"

      array?(v) ->
        list_label("[", "]", Enum.map(array_list(v), &inspect_js(&1, depth + 1, [v | seen])))

      depth > 2 ->
        "[Object]"

      true ->
        pairs =
          for k <- own_keys(v),
              do: key_label(k) <> ": " <> inspect_js(Interp.get(v, k), depth + 1, [v | seen])

        list_label("{", "}", pairs)
    end
  end

  defp list_label(open, close, []), do: open <> close
  defp list_label(open, close, items), do: open <> " " <> Enum.join(items, ", ") <> " " <> close

  defp key_label(k),
    do: if(Regex.match?(~r/\A[A-Za-z_$][\w$]*\z/, k), do: k, else: "'" <> k <> "'")

  defp function_label(f) do
    case to_str(Interp.get(f, "name")) do
      "" -> "[Function (anonymous)]"
      name -> "[Function: #{name}]"
    end
  end

  defp error?({:obj, _} = v),
    do: Interp.instance_of?(v, Interp.ev({:id, "Error"}, Interp.global()))

  defp error?(_), do: false

  # ── timers ─────────────────────────────────────────────────

  defp install_timers(scope) do
    Process.put(:js_timers, [])
    Process.put(:js_timer_seq, 0)
    Process.put(:js_now, 0.0)

    add = fn interval? ->
      fn _, args ->
        f = arg(args, 0)

        delay =
          case to_num(arg(args, 1)) do
            n when is_number(n) -> max(n, 0.0)
            _ -> 0.0
          end

        seq = Process.get(:js_timer_seq) + 1
        Process.put(:js_timer_seq, seq)

        timer = %{
          id: seq,
          at: Process.get(:js_now) + delay,
          seq: seq,
          fun: f,
          args: Enum.drop(args, 2),
          interval: if(interval?, do: max(delay, 1.0)),
          realm: Browser.JS.DOM.timer_realm()
        }

        Process.put(:js_timers, [timer | Process.get(:js_timers)])
        float(seq)
      end
    end

    clear = fn _, args ->
      id = to_num(arg(args, 0))
      Process.put(:js_timers, Enum.reject(Process.get(:js_timers), &(float(&1.id) == id)))
      :undefined
    end

    declare(scope, "setTimeout", native("setTimeout", add.(false)))
    declare(scope, "setInterval", native("setInterval", add.(true)))
    declare(scope, "clearTimeout", native("clearTimeout", clear))
    declare(scope, "clearInterval", native("clearInterval", clear))
  end

  @doc "Schedules the JS function `fun` after `delay` virtual milliseconds; returns the timer id."
  def add_timer(fun, delay) do
    seq = Process.get(:js_timer_seq) + 1
    Process.put(:js_timer_seq, seq)

    timer = %{
      id: seq,
      at: Process.get(:js_now) + delay,
      seq: seq,
      fun: fun,
      args: [],
      interval: nil,
      realm: Browser.JS.DOM.timer_realm()
    }

    Process.put(:js_timers, [timer | Process.get(:js_timers)])
    seq
  end

  @doc "Cancels a timer made by `add_timer/2`."
  def clear_timer(id),
    do: Process.put(:js_timers, Enum.reject(Process.get(:js_timers), &(&1.id == id)))

  @doc """
  Runs pending timers in virtual time (no real waiting), earliest first, until none are left
  or the next one is more than a virtual minute away (so a `setInterval` can't run forever).
  `on_error` receives the thrown value of a callback that raised; the others still run.
  """
  def run_timers(on_error) do
    if run_next_timer(on_error), do: run_timers(on_error), else: :ok
  end

  @doc """
  Runs the earliest pending timer; false when there is none (or the next one lies beyond the
  virtual minute).
  """
  def run_next_timer(on_error, horizon \\ @timer_horizon) do
    case Enum.min_by(Process.get(:js_timers), &{&1.at, &1.seq}, fn -> nil end) do
      nil ->
        false

      %{at: at} when at > horizon ->
        false

      t ->
        Process.put(:js_timers, List.delete(Process.get(:js_timers), t))
        # time never runs backwards: a timer that is late sees the time it actually ran
        Process.put(:js_now, max(t.at, Process.get(:js_now, 0.0)))

        if t.interval do
          seq = Process.get(:js_timer_seq)
          Process.put(:js_timer_seq, seq + 1)

          Process.put(:js_timers, [
            %{t | at: t.at + t.interval, seq: seq + 1} | Process.get(:js_timers)
          ])
        end

        try do
          # (a timer of a frame runs in the frame; one of a frame that has gone does not run)
          if Browser.JS.DOM.realm_alive?(t[:realm]) do
            Browser.JS.DOM.in_realm(t[:realm], fn -> call(t.fun, :undefined, t.args) end)
          end

          Browser.JS.Promise.run_microtasks()
        catch
          {:js_error, v} -> on_error.(v)
        end

        # no script is on the stack now: the one safe moment to free unreachable objects
        Browser.JS.GC.maybe_collect()
        true
    end
  end

  @doc "When the earliest pending timer is due (in the runtime's milliseconds), or nil."
  def next_timer_at do
    Process.get(:js_timers) |> Enum.map(& &1.at) |> Enum.min(fn -> nil end)
  end

  defp install_misc(scope) do
    constructor(scope, "Function", proto(:function), fn _, args ->
      {params, body} = Enum.split(args, -1)
      params = params |> Enum.map(&to_str/1) |> Enum.join(",")
      body = body |> Enum.map(&to_str/1) |> Enum.join()
      eval_source("(function anonymous(#{params}\n) {\n#{body}\n})")
    end)

    eval_fn =
      native("eval", fn _, args ->
        case arg(args, 0) do
          src when is_binary(src) -> eval_source(src)
          other -> other
        end
      end)

    # a call `eval(...)` through this very function is a direct eval (see `Interp.direct_eval/2`)
    :erlang.put(:js_eval_fn, eval_fn)
    declare(scope, "eval", eval_fn)

    Browser.JS.Date.install(scope)

    perf = new_object()
    declare(scope, "performance", perf)
    def_fn(perf, "now", fn _, _ -> perf_now() end)
  end

  @doc "Milliseconds since the page's time origin (the first time anything asked)."
  def perf_now do
    origin =
      case Process.get(:js_time_origin) do
        nil ->
          t = System.monotonic_time(:microsecond)
          Process.put(:js_time_origin, t)
          t

        t ->
          t
      end

    float(System.monotonic_time(:microsecond) - origin) / 1000
  end
end
