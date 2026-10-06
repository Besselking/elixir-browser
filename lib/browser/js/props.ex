defmodule Browser.JS.Props do
  @moduledoc """
  Property attributes for the JavaScript runtime: `Object.defineProperty` and friends.

  A property is a value in the object's `props`, or `{:accessor, getter, setter}` for an accessor.
  Whether it is enumerable is whether its key is in the object's `keys`; `writable` and
  `configurable` are kept in the object's `attrs` map only when they are not both true (the
  default of an assignment). `ext: false` marks a non-extensible object, and `frozen: true` an
  array whose elements may not change.
  """

  import Browser.JS.Interp, except: [get: 2, put: 3]
  alias Browser.JS.Interp

  defp arg(args, i), do: Enum.at(args, i, :undefined)

  # ── reading ────────────────────────────────────────────────

  # -> nil | {:data, value, writable, enumerable, configurable} | {:accessor, get, set, e, c}
  defp own(o, key) do
    cond do
      o.class == :array and is_integer(array_index(key)) ->
        case Map.fetch(o.items, array_index(key)) do
          {:ok, {:accessor, g, s}} ->
            a = Map.get(Map.get(o, :attrs, %{}), array_index(key), %{})

            {:accessor, g, s, Map.get(a, :e, true),
             not Map.get(o, :frozen, false) and Map.get(a, :c, true)}

          {:ok, v} ->
            frozen = Map.get(o, :frozen, false)
            a = Map.get(Map.get(o, :attrs, %{}), array_index(key), %{})

            {:data, v, not frozen and Map.get(a, :w, true), Map.get(a, :e, true),
             not frozen and Map.get(a, :c, true)}

          :error ->
            nil
        end

      o.class == :array and key == "length" ->
        {:data, o.len * 1.0, not Map.get(o, :frozen, false) and not Map.get(o, :len_ro, false),
         false, false}

      Map.has_key?(o.props, key) ->
        attrs = Map.get(o.attrs_or_default, key, %{})
        e = key in o.keys or (not is_binary(key) and Map.get(attrs, :e, false))
        c = Map.get(attrs, :c, true)

        case o.props[key] do
          {:accessor, g, s} -> {:accessor, g, s, e, c}
          v -> {:data, v, Map.get(attrs, :w, true), e, c}
        end

      true ->
        nil
    end
  end

  defp state({:obj, id}, key) do
    o = deref(id)
    o = Map.put(o, :attrs_or_default, Map.get(o, :attrs, %{}))
    own(o, key) || virtual(id, o, key)
  end

  # `name`, `length` and `prototype` of a function exist without being stored
  defp virtual(id, %{class: :function}, key) when key in ["name", "length", "prototype"] do
    case Interp.get({:obj, id}, key) do
      :undefined ->
        nil

      v ->
        case key do
          "prototype" -> {:data, v, true, false, false}
          _ -> {:data, v, false, false, true}
        end
    end
  end

  # a variable of the global scope is a property of the global object
  defp virtual(_id, %{class: :host, host: {Browser.JS.Global, :global}}, key)
       when is_binary(key) do
    case Browser.JS.Global.host_get(:global, key, nil) do
      {:ok, v} ->
        builtin? = MapSet.member?(:erlang.get(:js_builtin_names), key)

        {:data, v, key not in ["NaN", "Infinity", "undefined"], not builtin?,
         key not in ["NaN", "Infinity", "undefined"] and not Interp.global_fixed?(key)}

      :miss ->
        nil
    end
  end

  # an export of a module namespace
  defp virtual(_id, %{class: :host, host: {Browser.JS.Modules, data}}, key)
       when is_binary(key),
       do: Browser.JS.Modules.property(data, key)

  # an element of a typed array
  defp virtual(_id, %{class: :host, host: {Browser.JS.TypedArrays, data}}, key)
       when is_binary(key),
       do: Browser.JS.TypedArrays.property(data, key)

  defp virtual(_id, %{prim: s}, key) when is_binary(s) do
    case array_index(key) do
      i when is_integer(i) ->
        case Browser.JS.Str.at(s, i) do
          nil -> nil
          c -> {:data, c, false, true, false}
        end

      _ ->
        nil
    end
  end

  defp virtual(_, _, _), do: nil

  @doc "The property descriptor object of an own property, or undefined."
  def descriptor({:obj, id} = obj, key) do
    case deref(id) do
      %{proxy: _} -> Browser.JS.Proxy.get_own_property(obj, key)
      _ -> state_to_object(state(obj, key))
    end
  end

  def descriptor(s, key) when is_binary(s), do: string_descriptor(s, key)
  def descriptor(_, _), do: :undefined

  @doc "The descriptor object for an own-property state (or `undefined`)."
  def state_to_object(nil), do: :undefined

  def state_to_object({:data, v, w, e, c}),
    do: new_object([{"value", v}, {"writable", w}, {"enumerable", e}, {"configurable", c}])

  def state_to_object({:accessor, g, s, e, c}),
    do: new_object([{"get", g}, {"set", s}, {"enumerable", e}, {"configurable", c}])

  @doc "The own property of a (non-proxy) object as `nil | {:data, ..} | {:accessor, ..}`."
  def own_state(obj, key), do: state(obj, key)

  @doc "Whether `desc` may be applied to a property in state `current` (nil: absent)."
  def compatible?(extensible?, desc, current) do
    if current == nil do
      extensible?
    else
      try do
        validate(current, desc, "x")
        true
      catch
        {:js_error, _} -> false
      end
    end
  end

  @doc "Descriptor object to the field map (`ToPropertyDescriptor`)."
  def to_property_descriptor(v), do: to_desc(v)

  @doc "Every own property name, enumerable or not: array indices, then the rest."
  def own_names({:obj, id}) do
    o = deref(id)

    if Map.has_key?(o, :proxy) do
      for k <- Browser.JS.Proxy.own_keys({:obj, id}), is_binary(k), do: k
    else
      own_names_plain(id, o)
    end
  end

  def own_names(s) when is_binary(s), do: Interp.own_keys(s) ++ ["length"]
  def own_names(_), do: []

  defp own_names_plain(id, o) do
    case o do
      %{class: :host, host: {Browser.JS.TypedArrays, data}} ->
        Browser.JS.TypedArrays.host_keys(data) ++ own_names_plain2(id, o)

      %{class: :host, host: {Browser.JS.Modules, data}} ->
        Browser.JS.Modules.names(data) ++ own_names_plain2(id, o)

      _ ->
        own_names_plain2(id, o)
    end
  end

  # an array index: an integer below 2^32 - 1
  defp index_key?(k), do: is_integer(array_index(k)) and array_index(k) < 4_294_967_295

  defp own_names_plain2(id, o) do
    base = o.keys |> Enum.reverse() |> Enum.filter(&is_binary/1)

    hidden =
      (Map.keys(o.props) -- o.keys) |> Enum.filter(&is_binary/1) |> Enum.sort()

    case o do
      %{class: :array} ->
        for(i <- 0..(o.len - 1)//1, Map.has_key?(o.items, i), do: Integer.to_string(i)) ++
          base ++ hidden ++ ["length"]

      %{class: :function} ->
        virtual =
          for k <- ["length", "name", "prototype"],
              k not in hidden and k not in base,
              state({:obj, id}, k) != nil,
              do: k

        base ++ virtual ++ hidden

      %{prim: s} when is_binary(s) ->
        {ints, rest} = Enum.split_with(base, &index_key?/1)

        for(i <- 0..(String.length(s) - 1)//1, do: Integer.to_string(i)) ++
          Enum.sort_by(ints, &array_index/1) ++ rest ++ hidden

      _ ->
        {ints, rest} = Enum.split_with(base, &index_key?/1)
        Enum.sort_by(ints, &array_index/1) ++ rest ++ hidden
    end
  end

  @doc "Every own key, strings first then symbols (a proxy's `ownKeys` result as it is)."
  def all_own_keys({:obj, id} = o) do
    if Map.has_key?(deref(id), :proxy),
      do: Browser.JS.Proxy.own_keys(o),
      else: own_names(o) ++ own_symbols(o)
  end

  def all_own_keys(v), do: own_names(v) ++ own_symbols(v)

  @doc """
  The own enumerable keys, strings first then symbols (a proxy's in the order of its `ownKeys`
  trap, asking for the descriptor of every key that is not in `exclude`).
  """
  def enumerable_keys(o, exclude \\ [])

  def enumerable_keys({:obj, id} = o, exclude) do
    if Map.has_key?(deref(id), :proxy) do
      for k <- Browser.JS.Proxy.own_keys(o),
          k not in exclude,
          d = descriptor(o, k),
          d != :undefined,
          truthy(Interp.get(d, "enumerable")),
          do: k
    else
      Enum.reject(Interp.own_keys(o), &(&1 in exclude))
    end
  end

  def enumerable_keys(s, exclude) when is_binary(s),
    do: Enum.reject(Interp.own_keys(s), &(&1 in exclude))

  def enumerable_keys(_, _), do: []

  @doc "Every enumerable own key (CopyDataProperties): strings, then symbols; a proxy's in trap order."
  def enumerable_own_keys({:obj, id} = o) do
    if Map.has_key?(deref(id), :proxy),
      do: enumerable_keys(o),
      else: enumerable_keys(o) ++ enumerable_symbols(o)
  end

  def enumerable_own_keys(v), do: enumerable_keys(v)

  @doc "The symbols of an object's enumerable own properties."
  def enumerable_symbols({:obj, _} = o),
    do: for(k <- own_symbols(o), enumerable_own?(o, k), do: k)

  def enumerable_symbols(_), do: []

  @doc "The symbols an object has properties for."
  def own_symbols({:obj, id}) do
    o = deref(id)

    if Map.has_key?(o, :proxy) do
      for k <- Browser.JS.Proxy.own_keys({:obj, id}), match?({:symbol, _, _}, k), do: k
    else
      o.props |> Map.keys() |> Enum.filter(&match?({:symbol, _, _}, &1))
    end
  end

  def own_symbols(_), do: []

  # ── defining ───────────────────────────────────────────────

  # the fields of a descriptor object that are present: %{value:, writable:, get:, set:, ...}
  defp to_desc({:obj, _} = o) do
    field = fn name ->
      if has_property?(o, name), do: [{String.to_atom(name), Interp.get(o, name)}], else: []
    end

    desc =
      ~w(enumerable configurable value writable get set)
      |> Enum.flat_map(field)
      |> Map.new()

    desc =
      desc
      |> maybe_bool(:enumerable)
      |> maybe_bool(:configurable)
      |> maybe_bool(:writable)

    for k <- [:get, :set] do
      case desc do
        %{^k => v} when v != :undefined ->
          unless function?(v),
            do:
              throw_error("TypeError", "#{String.capitalize(to_string(k))}ter must be a function")

        _ ->
          :ok
      end
    end

    if (Map.has_key?(desc, :get) or Map.has_key?(desc, :set)) and
         (Map.has_key?(desc, :value) or Map.has_key?(desc, :writable)),
       do:
         throw_error(
           "TypeError",
           "Invalid property descriptor. Cannot both specify accessors and a value or writable attribute"
         )

    desc
  end

  defp to_desc(v),
    do: throw_error("TypeError", "Property description must be an object: #{to_str(v)}")

  defp maybe_bool(desc, k) do
    case desc do
      %{^k => v} -> Map.put(desc, k, truthy(v))
      _ -> desc
    end
  end

  @doc "`Object.defineProperty(obj, key, descriptor_object)`."
  def define({:obj, id} = obj, key, descriptor) do
    key = to_key(key)
    desc = to_desc(descriptor)

    if Map.has_key?(deref(id), :proxy) do
      unless Browser.JS.Proxy.define_own_property(obj, key, descriptor, desc),
        do: throw_error("TypeError", "'defineProperty' on proxy: trap returned falsish")
    else
      define_own(obj, id, key, desc)
    end

    obj
  end

  def define(_, _, _),
    do: throw_error("TypeError", "Object.defineProperty called on non-object")

  @doc "Adds or completes an accessor, enumerable and configurable (object literals, `get`/`set`)."
  def define_accessor({:obj, id} = obj, key, opts) do
    existing =
      case state(obj, key) do
        {:accessor, g, s, _, _} -> {g, s}
        _ -> {:undefined, :undefined}
      end

    {g, s} = existing
    g = Keyword.get(opts, :get, g)
    s = Keyword.get(opts, :set, s)

    define_own(obj, id, key, %{
      get: g,
      set: s,
      enumerable: Keyword.get(opts, :enumerable, true),
      configurable: Keyword.get(opts, :configurable, true)
    })
  end

  defp reject(key), do: throw_error("TypeError", "Cannot redefine property: #{key_name(key)}")

  defp key_name({:symbol, _, desc}), do: desc
  defp key_name(key), do: key

  @doc """
  `Reflect.defineProperty`: converts the key and the descriptor (which may throw), then reports
  whether the property could be defined.
  """
  def try_define({:obj, id} = obj, key, descriptor) do
    key = to_key(key)
    desc = to_desc(descriptor)

    if Map.has_key?(deref(id), :proxy) do
      Browser.JS.Proxy.define_own_property(obj, key, descriptor, desc)
    else
      try do
        define_own(obj, id, key, desc)
        true
      catch
        {:js_error, _} -> false
      end
    end
  end

  @doc """
  OrdinarySet: `target.[[Set]](key, value, receiver)` as a boolean. Proxies go through their
  `set` trap; the value is stored on the receiver, which is not always the target.
  """
  def ordinary_set({:obj, id} = target, key, value, receiver) do
    key = to_key(key)
    o = deref(id)

    cond do
      Map.has_key?(o, :proxy) ->
        Browser.JS.Proxy.set(target, key, value, receiver)

      o.class == :host ->
        cond do
          match?({Browser.JS.Modules, _}, o.host) ->
            false

          receiver != target and Browser.JS.TypedArrays.invalid_index?(target, key) ->
            true

          true ->
            Interp.put(target, key, value)
            true
        end

      true ->
        case state(target, key) do
          nil ->
            case get_prototype_of(target) do
              {:obj, _} = parent -> ordinary_set(parent, key, value, receiver)
              _ -> set_on_receiver(key, value, receiver)
            end

          {:data, _, false, _, _} ->
            false

          {:data, _, _, _, _} ->
            set_on_receiver(key, value, receiver)

          {:accessor, _, setter, _, _} ->
            if function?(setter) do
              Interp.call(setter, receiver, [value])
              true
            else
              false
            end
        end
    end
  end

  defp set_on_receiver(key, value, {:obj, rid} = receiver) do
    existing =
      if Map.has_key?(deref(rid), :proxy) do
        case Browser.JS.Proxy.get_own_property(receiver, key) do
          {:obj, _} = d ->
            if Interp.has_property?(d, "get") or Interp.has_property?(d, "set"),
              do: {:accessor, nil, nil, true, true},
              else: {:data, nil, truthy(Interp.get(d, "writable")), true, true}

          _ ->
            nil
        end
      else
        state(receiver, key)
      end

    case existing do
      {:accessor, _, _, _, _} ->
        false

      {:data, _, false, _, _} ->
        false

      {:data, _, _, _, _} ->
        try_define(receiver, key, new_object([{"value", value}]))

      nil ->
        try_define(
          receiver,
          key,
          new_object([
            {"value", value},
            {"writable", true},
            {"enumerable", true},
            {"configurable", true}
          ])
        )
    end
  end

  defp set_on_receiver(_, _, _), do: false

  # an element of a mapped `arguments` object follows [[DefineOwnProperty]] of arguments exotic
  # objects: it stays mapped unless it becomes an accessor or read-only
  defp define_own(obj, id, key, desc) do
    o = deref(id)

    with %{mapped: mapped} <- o,
         i when is_integer(i) <- Interp.array_index(key),
         %{^i => _name} <- mapped do
      accessor? = Map.has_key?(desc, :get) or Map.has_key?(desc, :set)

      desc2 =
        if not accessor? and Map.get(desc, :writable) == false and not Map.has_key?(desc, :value),
          do: Map.put(desc, :value, Map.get(o.items, i, :undefined)),
          else: desc

      define_own_plain(obj, id, key, desc2)

      cond do
        accessor? ->
          Interp.unmap_argument(id, i)

        true ->
          if Map.has_key?(desc, :value), do: Interp.sync_param(deref(id), i, desc.value)
          if Map.get(desc, :writable) == false, do: Interp.unmap_argument(id, i)
      end

      :ok
    else
      _ -> define_own_plain(obj, id, key, desc)
    end
  end

  defp define_own_plain(obj, id, key, desc) do
    o = deref(id)

    cond do
      o.class == :host and match?({Browser.JS.Modules, _}, o.host) and
          Browser.JS.Modules.define_own(elem(o.host, 1), key, desc) == :ok ->
        :ok

      o.class == :host and match?({Browser.JS.TypedArrays, _}, o.host) and is_binary(key) and
          Browser.JS.TypedArrays.define_own(elem(o.host, 1), key, desc) == :ok ->
        :ok

      o.class == :array and is_integer(array_index(key)) ->
        define_element(id, o, key, desc)

      o.class == :array and key == "length" ->
        define_length(id, o, desc)

      true ->
        case state(obj, key) do
          nil ->
            unless Map.get(o, :ext, true),
              do:
                throw_error(
                  "TypeError",
                  "Cannot define property #{key_name(key)}, object is not extensible"
                )

            create(id, key, desc)

          current ->
            validate(current, desc, key)
            update(id, key, current, desc)
        end
    end
  end

  defp create(id, key, desc) do
    o = deref(id)
    accessor? = Map.has_key?(desc, :get) or Map.has_key?(desc, :set)

    value =
      if accessor?,
        do: {:accessor, Map.get(desc, :get, :undefined), Map.get(desc, :set, :undefined)},
        else: Map.get(desc, :value, :undefined)

    attrs = Map.get(o, :attrs, %{})
    flags = %{c: Map.get(desc, :configurable, false)}
    flags = if accessor?, do: flags, else: Map.put(flags, :w, Map.get(desc, :writable, false))
    flags = Map.put_new(flags, :w, true)

    attrs =
      if flags == %{c: true, w: true},
        do: Map.delete(attrs, key),
        else: Map.put(attrs, key, flags)

    keys = if Map.get(desc, :enumerable, false), do: [key | o.keys], else: o.keys

    store(
      id,
      o
      |> Map.put(:attrs, attrs)
      |> Map.put(:props, Map.put(o.props, key, value))
      |> Map.put(:keys, keys)
    )
  end

  # the rules for changing a property that is not configurable
  defp validate({_, _, _, _, c} = current, desc, key) when c == true do
    _ = {current, desc, key}
    :ok
  end

  defp validate(current, desc, key) do
    {kind, e} =
      case current do
        {:data, _, _, e, _} -> {:data, e}
        {:accessor, _, _, e, _} -> {:accessor, e}
      end

    data_desc? = Map.has_key?(desc, :value) or Map.has_key?(desc, :writable)
    accessor_desc? = Map.has_key?(desc, :get) or Map.has_key?(desc, :set)

    cond do
      Map.get(desc, :configurable) == true -> reject(key)
      Map.has_key?(desc, :enumerable) and desc.enumerable != e -> reject(key)
      kind == :data and accessor_desc? -> reject(key)
      kind == :accessor and data_desc? -> reject(key)
      true -> :ok
    end

    case current do
      {:data, v, false, _, _} ->
        if Map.get(desc, :writable) == true, do: reject(key)
        if Map.has_key?(desc, :value) and not same_value?(desc.value, v), do: reject(key)

      {:accessor, g, s, _, _} ->
        if Map.has_key?(desc, :get) and desc.get != g, do: reject(key)
        if Map.has_key?(desc, :set) and desc.set != s, do: reject(key)

      _ ->
        :ok
    end
  end

  defp same_value?(a, b) do
    cond do
      a == :nan and b == :nan -> true
      is_number(a) and is_number(b) -> a == b and (a != 0 or sign_bit(a) == sign_bit(b))
      true -> a == b
    end
  rescue
    _ -> a == b
  end

  defp sign_bit(n), do: match?(<<1::1, _::63>>, <<n * 1.0::float>>)

  defp update(id, key, current, desc) do
    o = deref(id)
    accessor_desc? = Map.has_key?(desc, :get) or Map.has_key?(desc, :set)
    data_desc? = Map.has_key?(desc, :value) or Map.has_key?(desc, :writable)

    {kind, e, c} =
      case current do
        {:data, _, _, e, c} -> {:data, e, c}
        {:accessor, _, _, e, c} -> {:accessor, e, c}
      end

    e = Map.get(desc, :enumerable, e)
    c = Map.get(desc, :configurable, c)

    {value, w} =
      cond do
        accessor_desc? and kind == :accessor ->
          {:accessor, g, s, _, _} = current

          {{:accessor, Map.get(desc, :get, g), Map.get(desc, :set, s)}, true}

        accessor_desc? ->
          {{:accessor, Map.get(desc, :get, :undefined), Map.get(desc, :set, :undefined)}, true}

        data_desc? and kind == :accessor ->
          {Map.get(desc, :value, :undefined), Map.get(desc, :writable, false)}

        kind == :data ->
          {:data, v, w, _, _} = current
          {Map.get(desc, :value, v), Map.get(desc, :writable, w)}

        true ->
          {:accessor, g, s, _, _} = current
          {{:accessor, g, s}, true}
      end

    attrs = Map.get(o, :attrs, %{})
    flags = if match?({:accessor, _, _}, value), do: %{c: c, w: true}, else: %{c: c, w: w}

    attrs =
      if flags == %{c: true, w: true},
        do: Map.delete(attrs, key),
        else: Map.put(attrs, key, flags)

    keys = o.keys |> List.delete(key) |> then(&if(e, do: [key | &1], else: &1))

    # a function's own name, length and prototype become real properties
    store(
      id,
      o
      |> Map.put(:attrs, attrs)
      |> Map.put(:props, Map.put(o.props, key, value))
      |> Map.put(:keys, keys)
    )
  end

  # array elements: a value with writable/configurable kept per index (enumerable stays true,
  # and an accessor is not supported)
  defp define_element(id, o, key, desc) do
    i = array_index(key)

    exists? = Map.has_key?(o.items, i)

    # a generic descriptor (no value, writable, get or set) keeps an accessor an accessor
    generic? = not (Map.has_key?(desc, :value) or Map.has_key?(desc, :writable))

    if Map.has_key?(desc, :get) or Map.has_key?(desc, :set) or
         (generic? and match?({:accessor, _, _}, o.items[i])),
       do: define_element_accessor(id, o, key, i, desc, exists?),
       else: define_element_data(id, o, key, i, desc, exists?)
  end

  defp define_element_accessor(id, o, key, i, desc, exists?) do
    cond do
      not exists? and not Map.get(o, :ext, true) ->
        throw_error("TypeError", "Cannot define property #{key}, object is not extensible")

      not exists? and i >= o.len and Map.get(o, :len_ro, false) ->
        throw_error("TypeError", "Cannot define property #{key}, array length is not writable")

      true ->
        current = if exists?, do: state({:obj, id}, key)
        if current, do: validate(current, desc, key)

        {g0, s0} =
          case o.items[i] do
            {:accessor, g, s} -> {g, s}
            _ -> {:undefined, :undefined}
          end

        item = {:accessor, Map.get(desc, :get, g0), Map.get(desc, :set, s0)}
        attrs = Map.get(o, :attrs, %{})
        c = Map.get(desc, :configurable, if(exists?, do: elem(current, 4), else: false))
        cur = Map.get(attrs, i, %{})
        e = Map.get(desc, :enumerable, if(exists?, do: Map.get(cur, :e, true), else: false))
        flags = %{w: true, c: c, e: e}

        attrs =
          if flags == %{w: true, c: true, e: true},
            do: Map.delete(attrs, i),
            else: Map.put(attrs, i, flags)

        store(
          id,
          o
          |> Map.put(:attrs, attrs)
          |> Map.put(:items, Map.put(o.items, i, item))
          |> Map.put(:len, max(o.len, i + 1))
        )
    end
  end

  defp define_element_data(id, o, key, i, desc, exists?) do
    cond do
      not exists? and not Map.get(o, :ext, true) ->
        throw_error("TypeError", "Cannot define property #{key}, object is not extensible")

      not exists? and i >= o.len and Map.get(o, :len_ro, false) ->
        throw_error("TypeError", "Cannot define property #{key}, array length is not writable")

      true ->
        current =
          if exists?,
            do: state({:obj, id}, key),
            else: nil

        if current, do: validate_element(current, desc, key)

        attrs = Map.get(o, :attrs, %{})
        cur = Map.get(attrs, i, %{})
        # turning an accessor into a data property starts from undefined and read-only
        was_accessor? = match?({:accessor, _, _}, o.items[i])

        w =
          Map.get(
            desc,
            :writable,
            if(exists? and not was_accessor?, do: Map.get(cur, :w, true), else: false)
          )

        c = Map.get(desc, :configurable, if(exists?, do: Map.get(cur, :c, true), else: false))
        e = Map.get(desc, :enumerable, if(exists?, do: Map.get(cur, :e, true), else: false))
        flags = %{w: w, c: c, e: e}

        attrs =
          if flags == %{w: true, c: true, e: true},
            do: Map.delete(attrs, i),
            else: Map.put(attrs, i, flags)

        v =
          Map.get(
            desc,
            :value,
            if(was_accessor?, do: :undefined, else: Map.get(o.items, i, :undefined))
          )

        store(
          id,
          o
          |> Map.put(:attrs, attrs)
          |> Map.put(:items, Map.put(o.items, i, v))
          |> Map.put(:len, max(o.len, i + 1))
        )
    end
  end

  defp validate_element({:accessor, _, _, _, c}, _desc, key), do: if(not c, do: reject(key))

  defp validate_element({:data, v, w, e, c}, desc, key) do
    if not c do
      if Map.get(desc, :configurable) == true, do: reject(key)
      if Map.get(desc, :enumerable, e) != e, do: reject(key)
      if not w and Map.get(desc, :writable) == true, do: reject(key)
      if not w and Map.has_key?(desc, :value) and not same_value?(desc.value, v), do: reject(key)
    end
  end

  defp define_length(id, o, desc) do
    # the value is coerced (twice) before anything else is checked, and may change the array
    new_len = if Map.has_key?(desc, :value), do: Interp.array_length!(desc.value)
    o = if new_len, do: deref(id), else: o

    cond do
      Map.get(desc, :configurable) == true or Map.get(desc, :enumerable) == true or
        Map.has_key?(desc, :get) or Map.has_key?(desc, :set) ->
        reject("length")

      true ->
        read_only? = Map.get(o, :len_ro, false) or Map.get(o, :frozen, false)

        if read_only? and Map.get(desc, :writable) == true, do: reject("length")

        o =
          if new_len do
            if read_only? and new_len != o.len, do: reject("length")
            shrink(id, o, new_len)
          else
            o
          end

        if Map.get(desc, :writable) == false,
          do: store(id, Map.put(deref(id) || o, :len_ro, true))

        :ok
    end
  end

  # cut an array to `len`, but not below an element that cannot be deleted; that is an error
  defp shrink(id, o, len) do
    attrs = Map.get(o, :attrs, %{})

    keep =
      o.items
      |> Map.keys()
      |> Enum.filter(&(&1 >= len and Map.get(Map.get(attrs, &1, %{}), :c, true) == false))
      |> Enum.max(fn -> nil end)

    stop = if keep, do: keep + 1, else: len
    o = %{o | items: Map.filter(o.items, fn {i, _} -> i < stop end), len: stop}
    store(id, o)
    if keep, do: reject("length")
    o
  end

  # ── integrity levels ───────────────────────────────────────

  @doc "`Object.preventExtensions`."
  def prevent_extensions({:obj, id} = obj) do
    o = deref(id)

    if Map.has_key?(o, :proxy) do
      unless Browser.JS.Proxy.prevent_extensions(obj),
        do: throw_error("TypeError", "'preventExtensions' on proxy: trap returned falsish")
    else
      store(id, Map.put(o, :ext, false))
    end

    obj
  end

  def prevent_extensions(v), do: v

  def extensible?({:obj, id} = obj) do
    case deref(id) do
      %{proxy: _} -> Browser.JS.Proxy.extensible?(obj)
      o -> Map.get(o, :ext, true)
    end
  end

  def extensible?(_), do: false

  # private fields are outside freezing and sealing
  defp public_keys(o), do: Enum.reject(Map.keys(o.props), &match?({:private, _}, &1))

  @doc "`Object.seal` (`freeze?` false) and `Object.freeze` (true)."
  def lock({:obj, id} = obj, freeze?) do
    o = deref(id)

    if Map.has_key?(o, :proxy),
      do: lock_proxy(obj, freeze?),
      else: lock_plain(obj, id, o, freeze?)
  end

  def lock(v, _), do: v

  defp lock_proxy(obj, freeze?) do
    prevent_extensions(obj)

    for k <- Browser.JS.Proxy.own_keys(obj) do
      case descriptor(obj, k) do
        :undefined ->
          :ok

        d ->
          accessor? = has_property?(d, "get") or has_property?(d, "set")

          fields =
            if freeze? and not accessor?,
              do: [{"configurable", false}, {"writable", false}],
              else: [{"configurable", false}]

          define(obj, k, new_object(fields))
      end
    end

    obj
  end

  defp lock_plain(obj, id, o, freeze?) do
    attrs =
      Enum.reduce(public_keys(o), Map.get(o, :attrs, %{}), fn key, attrs ->
        accessor? = match?({:accessor, _, _}, o.props[key])
        cur = Map.get(attrs, key, %{})
        w = if freeze? and not accessor?, do: false, else: Map.get(cur, :w, true)
        Map.put(attrs, key, %{c: false, w: w})
      end)

    o = o |> Map.put(:attrs, attrs) |> Map.put(:ext, false)
    o = if freeze? and o.class == :array, do: Map.put(o, :frozen, true), else: o
    o = if not freeze? and o.class == :array, do: Map.put(o, :sealed, true), else: o
    store(id, o)
    obj
  end

  @doc "`Object.isFrozen` (`freeze?` true) and `Object.isSealed`."
  def locked?({:obj, id} = obj, freeze?) do
    o = deref(id)

    if Map.has_key?(o, :proxy),
      do: locked_proxy?(obj, freeze?),
      else: locked_plain?(o, freeze?)
  end

  def locked?(_, _), do: true

  defp locked_proxy?(obj, freeze?) do
    not extensible?(obj) and
      Enum.all?(Browser.JS.Proxy.own_keys(obj), fn k ->
        case descriptor(obj, k) do
          :undefined ->
            true

          d ->
            not truthy(Interp.get(d, "configurable")) and
              (not freeze? or has_property?(d, "get") or has_property?(d, "set") or
                 not truthy(Interp.get(d, "writable")))
        end
      end)
  end

  defp locked_plain?(o, freeze?) do
    not Map.get(o, :ext, true) and
      Enum.all?(public_keys(o), fn key ->
        a = Map.get(Map.get(o, :attrs, %{}), key, %{})
        accessor? = match?({:accessor, _, _}, o.props[key])

        Map.get(a, :c, true) == false and
          (not freeze? or accessor? or Map.get(a, :w, true) == false)
      end) and
      (o.class != :array or o.items == %{} or
         Map.get(o, :frozen, false) or (not freeze? and Map.get(o, :sealed, false)))
  end

  # ── install ────────────────────────────────────────────────

  def install(object_ctor, object_proto) do
    def_fn = fn obj, name, fun -> put_hidden(obj, name, native(name, fun)) end

    def_fn.(object_ctor, "defineProperty", fn _, args ->
      define(arg(args, 0), arg(args, 1), arg(args, 2))
    end)

    def_fn.(object_ctor, "defineProperties", fn _, args ->
      define_all(arg(args, 0), arg(args, 1))
    end)

    def_fn.(object_ctor, "getOwnPropertyDescriptor", fn _, args ->
      case arg(args, 0) do
        {:obj, _} = o ->
          descriptor(o, to_key(arg(args, 1)))

        v when v in [:undefined, :null] ->
          throw_error("TypeError", "Cannot convert undefined or null to object")

        s when is_binary(s) ->
          string_descriptor(s, to_key(arg(args, 1)))

        _ ->
          :undefined
      end
    end)

    def_fn.(object_ctor, "getOwnPropertyDescriptors", fn _, args ->
      o = arg(args, 0)

      if o in [:undefined, :null],
        do: throw_error("TypeError", "Cannot convert undefined or null to object")

      new_object(for k <- all_own_keys(o), d = descriptor(o, k), d != :undefined, do: {k, d})
    end)

    def_fn.(object_ctor, "getOwnPropertyNames", fn _, args ->
      case arg(args, 0) do
        v when v in [:undefined, :null] ->
          throw_error("TypeError", "Cannot convert undefined or null to object")

        v ->
          new_array(own_names(v))
      end
    end)

    def_fn.(object_ctor, "getOwnPropertySymbols", fn _, args ->
      new_array(own_symbols(arg(args, 0)))
    end)

    def_fn.(object_ctor, "create", fn _, args ->
      proto =
        case arg(args, 0) do
          :null ->
            :null

          {:obj, _} = p ->
            p

          v ->
            throw_error(
              "TypeError",
              "Object prototype may only be an Object or null: #{to_str(v)}"
            )
        end

      o = new_object([], proto)
      if arg(args, 1) != :undefined, do: define_all(o, arg(args, 1))
      o
    end)

    def_fn.(object_ctor, "getPrototypeOf", fn _, args ->
      case arg(args, 0) do
        {:obj, _} = o ->
          get_prototype_of(o)

        v when v in [:undefined, :null] ->
          throw_error("TypeError", "Cannot convert undefined or null to object")

        s when is_binary(s) ->
          proto(:string)

        b when is_boolean(b) ->
          proto(:boolean)

        {:symbol, _, _} ->
          proto(:symbol)

        {:bigint, _} ->
          proto(:bigint)

        _ ->
          proto(:number)
      end
    end)

    def_fn.(object_ctor, "setPrototypeOf", fn _, args ->
      o = arg(args, 0)
      p = arg(args, 1)

      unless p == :null or match?({:obj, _}, p),
        do:
          throw_error("TypeError", "Object prototype may only be an Object or null: #{to_str(p)}")

      case o do
        {:obj, _} ->
          case set_prototype_of(o, p) do
            true -> :ok
            :extensible -> throw_error("TypeError", "#{to_str(o)} is not extensible")
            :cycle -> throw_error("TypeError", "Cyclic __proto__ value")
            :immutable -> throw_error("TypeError", "Immutable prototype object")
          end

        v when v in [:undefined, :null] ->
          throw_error("TypeError", "Object.setPrototypeOf called on null or undefined")

        _ ->
          :ok
      end

      o
    end)

    def_fn.(object_ctor, "preventExtensions", fn _, args -> prevent_extensions(arg(args, 0)) end)
    def_fn.(object_ctor, "isExtensible", fn _, args -> extensible?(arg(args, 0)) end)
    def_fn.(object_ctor, "freeze", fn _, args -> lock(arg(args, 0), true) end)
    def_fn.(object_ctor, "seal", fn _, args -> lock(arg(args, 0), false) end)
    def_fn.(object_ctor, "isFrozen", fn _, args -> locked?(arg(args, 0), true) end)
    def_fn.(object_ctor, "isSealed", fn _, args -> locked?(arg(args, 0), false) end)

    def_fn.(object_ctor, "is", fn _, args ->
      a = arg(args, 0)
      b = arg(args, 1)
      same_value?(a, b)
    end)

    install_annex_b(object_proto)

    def_fn.(object_proto, "propertyIsEnumerable", fn this, args ->
      enumerable_own?(this, to_key(arg(args, 0)))
    end)

    def_fn.(object_proto, "isPrototypeOf", fn this, args ->
      case arg(args, 0) do
        {:obj, id} ->
          if this in [:undefined, :null],
            do: throw_error("TypeError", "Cannot convert undefined or null to object")

          proto_chain_has?(get_prototype_of({:obj, id}), this)

        _ ->
          false
      end
    end)

    :ok
  end

  # `__proto__`, `__defineGetter__` and friends (Annex B), `toLocaleString`
  defp install_annex_b(object_proto) do
    def_fn = fn name, arity, fun ->
      f = native(name, fun)
      {:obj, fid} = f
      store(fid, Map.put(deref(fid), :arity, arity * 1.0))
      put_hidden(object_proto, name, f)
    end

    # ToObject(this): a primitive stands in as an empty object with its prototype
    to_obj = fn
      v when v in [:undefined, :null] ->
        throw_error("TypeError", "Cannot convert undefined or null to object")

      {:obj, _} = o ->
        o

      v ->
        new_object([], primitive_proto(v))
    end

    getter =
      native("get __proto__", fn this, _ -> this |> to_obj.() |> get_prototype_of() end)

    setter =
      native("set __proto__", fn this, args ->
        if this in [:undefined, :null],
          do: throw_error("TypeError", "Object.prototype.__proto__ called on null or undefined")

        p = arg(args, 0)

        if (p == :null or match?({:obj, _}, p)) and match?({:obj, _}, this) do
          case set_prototype_of(this, p) do
            true -> :ok
            :cycle -> throw_error("TypeError", "Cyclic __proto__ value")
            _ -> throw_error("TypeError", "Cannot set the prototype of this object")
          end
        end

        :undefined
      end)

    {:obj, sid} = setter
    store(sid, Map.put(deref(sid), :arity, 1.0))
    define_accessor(object_proto, "__proto__", get: getter, set: setter, enumerable: false)

    for {name, kind} <- [{"__defineGetter__", "get"}, {"__defineSetter__", "set"}] do
      def_fn.(name, 2, fn this, args ->
        o = to_obj.(this)
        f = arg(args, 1)
        unless function?(f), do: throw_error("TypeError", "#{name}: expecting function")
        key = to_key(arg(args, 0))
        define(o, key, new_object([{kind, f}, {"enumerable", true}, {"configurable", true}]))
        :undefined
      end)
    end

    for {name, kind} <- [{"__lookupGetter__", "get"}, {"__lookupSetter__", "set"}] do
      def_fn.(name, 1, fn this, args ->
        o = to_obj.(this)
        lookup_accessor(o, to_key(arg(args, 0)), kind)
      end)
    end

    def_fn.("toLocaleString", 0, fn this, _ ->
      Interp.call(Interp.get(this, "toString"), this, [])
    end)
  end

  defp lookup_accessor({:obj, _} = o, key, kind) do
    case descriptor(o, key) do
      {:obj, _} = d ->
        if Interp.has_property?(d, "get") or Interp.has_property?(d, "set"),
          do: Interp.get(d, kind),
          else: :undefined

      _ ->
        case get_prototype_of(o) do
          {:obj, _} = parent -> lookup_accessor(parent, key, kind)
          _ -> :undefined
        end
    end
  end

  defp primitive_proto(v) do
    case v do
      s when is_binary(s) -> proto(:string)
      b when is_boolean(b) -> proto(:boolean)
      {:symbol, _, _} -> proto(:symbol)
      {:bigint, _} -> proto(:bigint)
      _ -> proto(:number)
    end
  end

  defp enumerable_own?(this, key) do
    cond do
      this in [:undefined, :null] ->
        throw_error("TypeError", "Cannot convert undefined or null to object")

      match?({:obj, _}, this) and is_map_key(deref(elem(this, 1)), :proxy) ->
        case Browser.JS.Proxy.get_own_property(this, key) do
          {:obj, _} = d -> truthy(Interp.get(d, "enumerable"))
          _ -> false
        end

      match?({:obj, _}, this) ->
        case state(this, key) do
          {:data, _, _, e, _} -> e
          {:accessor, _, _, e, _} -> e
          nil -> false
        end

      is_binary(this) ->
        is_integer(array_index(key)) and array_index(key) < String.length(this)

      true ->
        false
    end
  end

  defp proto_chain_has?({:obj, _} = p, target),
    do: p == target or proto_chain_has?(get_prototype_of(p), target)

  defp proto_chain_has?(_, _), do: false

  @doc "[[GetPrototypeOf]]."
  def get_prototype_of({:obj, id} = o) do
    case deref(id) do
      %{proxy: _} -> Browser.JS.Proxy.get_prototype_of(o)
      rec -> rec.proto || :null
    end
  end

  @doc """
  [[SetPrototypeOf]]: `true` when done, else why not: `:extensible`, `:cycle` or `:immutable`
  (the prototype of `Object.prototype` can not be changed).
  """
  def set_prototype_of({:obj, id} = o, p) do
    rec = deref(id)
    current = rec.proto || :null

    cond do
      Map.has_key?(rec, :proxy) ->
        if Browser.JS.Proxy.set_prototype_of(o, p), do: true, else: :extensible

      current == p ->
        true

      not Map.get(rec, :ext, true) ->
        :extensible

      o == proto(:object) ->
        :immutable

      proto_chain_has?(p, o) ->
        :cycle

      true ->
        store(id, %{rec | proto: if(p == :null, do: nil, else: p)}) && true
    end
  end

  defp define_all(obj, props) do
    unless match?({:obj, _}, obj),
      do: throw_error("TypeError", "Object.defineProperties called on non-object")

    if props in [:undefined, :null],
      do: throw_error("TypeError", "Cannot convert undefined or null to object")

    descs = for k <- enumerable_keys(props), do: {k, Interp.get(props, k)}

    descs = for {k, d} <- descs, do: {k, d, to_desc(d)}
    {:obj, id} = obj

    for {k, raw, d} <- descs do
      if Map.has_key?(deref(id), :proxy), do: define(obj, k, raw), else: define_own(obj, id, k, d)
    end

    obj
  end

  defp string_descriptor(s, key) do
    cond do
      key == "length" ->
        new_object([
          {"value", String.length(s) * 1.0},
          {"writable", false},
          {"enumerable", false},
          {"configurable", false}
        ])

      is_integer(array_index(key)) and array_index(key) < String.length(s) ->
        new_object([
          {"value", String.at(s, array_index(key))},
          {"writable", false},
          {"enumerable", true},
          {"configurable", false}
        ])

      true ->
        :undefined
    end
  end
end
