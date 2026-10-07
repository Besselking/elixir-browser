defmodule Browser.JS.Proxy do
  @moduledoc """
  `Proxy` and `Proxy.revocable`. A proxy is an object with a `:proxy` field holding `{target,
  handler}` (`:revoked` after `revoke()`). A proxy of a non-function is a host object (see
  `Interp.new_host/3`, whose callbacks are the `host_*` functions here); a proxy of a function is
  a function object whose call runs the `apply` trap and whose `new` runs the `construct` trap
  (`Interp.construct/3`).

  Every internal method (`get`, `set`, `has`, `deleteProperty`, `ownKeys`,
  `getOwnPropertyDescriptor`, `defineProperty`, `getPrototypeOf`, `setPrototypeOf`,
  `isExtensible`, `preventExtensions`, `apply`, `construct`) calls the handler's trap when there
  is one, or the target, and checks the invariants the specification lists for the trap's result.
  """

  alias Browser.JS.{Interp, Props}

  def install(scope) do
    ctor =
      Interp.native("Proxy", fn this, args ->
        unless match?({:obj, _}, this),
          do: Interp.throw_error("TypeError", "Constructor Proxy requires 'new'")

        make(Enum.at(args, 0, :undefined), Enum.at(args, 1, :undefined))
      end)

    Interp.declare(scope, "Proxy", ctor)
    # a constructor that has no `prototype`
    Interp.store(elem(ctor, 1), Map.put(Interp.deref(elem(ctor, 1)), :proxy_ctor, true))

    Interp.put_hidden(
      ctor,
      "revocable",
      Interp.native("revocable", fn _, args ->
        p = make(Enum.at(args, 0, :undefined), Enum.at(args, 1, :undefined))

        revoke =
          Interp.native("", fn _, _ ->
            {:obj, id} = p
            Interp.store(id, Map.put(Interp.deref(id), :proxy, :revoked))
            :undefined
          end)

        Interp.new_object([{"proxy", p}, {"revoke", revoke}])
      end)
    )

    :ok
  end

  def proxy?({:obj, id}), do: Map.has_key?(Interp.deref(id), :proxy)
  def proxy?(_), do: false

  defp make({:obj, _} = target, {:obj, _} = handler) do
    if Interp.function?(target) do
      ref = make_ref()
      f = Interp.native("", fn this, args -> call_proxy(:erlang.get(ref), this, args) end)
      :erlang.put(ref, f)
      {:obj, id} = f

      Interp.store(
        id,
        Interp.deref(id)
        |> Map.put(:proxy, {target, handler})
        |> Map.put(:proxy_constructor, Interp.constructor?(target))
      )

      f
    else
      {:obj, id} = Interp.new_host(__MODULE__, nil, nil)

      Interp.store(
        id,
        Interp.deref(id) |> Map.put(:host, {__MODULE__, id}) |> Map.put(:proxy, {target, handler})
      )

      {:obj, id}
    end
  end

  defp make(_, _),
    do:
      Interp.throw_error(
        "TypeError",
        "Cannot create proxy with a non-object as target or handler"
      )

  defp call_proxy(p, this, args) do
    {target, handler} = state(p)

    case trap(handler, "apply") do
      nil -> Interp.call(target, this, args)
      f -> Interp.call(f, handler, [target, this, Interp.new_array(args)])
    end
  end

  # ── helpers ────────────────────────────────────────────────

  defp state({:obj, id}) do
    case Interp.deref(id) do
      %{proxy: {_, _} = s} -> s
      _ -> Interp.throw_error("TypeError", "Cannot perform operation on a revoked proxy")
    end
  end

  defp trap(handler, name) do
    case Interp.get(handler, name) do
      f when f in [:undefined, :null] ->
        nil

      f ->
        unless Interp.function?(f),
          do: Interp.throw_error("TypeError", "proxy trap '#{name}' is not a function")

        f
    end
  end

  defp err(msg), do: Interp.throw_error("TypeError", msg)

  defp same_value?(a, b) do
    cond do
      a == :nan and b == :nan -> true
      is_number(a) and is_number(b) -> <<a * 1.0::float-64>> == <<b * 1.0::float-64>>
      true -> a === b
    end
  end

  defp key_value(k), do: k

  # ── [[Get]] / [[Set]] / [[Has]] / [[Delete]] ───────────────

  def get(p, key, receiver) do
    {target, handler} = state(p)

    case trap(handler, "get") do
      nil ->
        if proxy?(target),
          do: get(target, key, receiver),
          else: Interp.get_with_receiver(target, key, receiver)

      f ->
        v = Interp.call(f, handler, [target, key_value(key), receiver])

        case target_state(target, key) do
          {:data, tv, false, _, false} ->
            unless same_value?(v, tv),
              do:
                err(
                  "'get' on proxy: property '#{show(key)}' is a read-only and non-configurable data property"
                )

          {:accessor, :undefined, _, _, false} ->
            unless v == :undefined,
              do:
                err(
                  "'get' on proxy: property '#{show(key)}' is a non-configurable accessor without a getter"
                )

          _ ->
            :ok
        end

        v
    end
  end

  # the result of [[Set]]: true when it worked
  def set(p, key, value, receiver) do
    {target, handler} = state(p)

    case trap(handler, "set") do
      nil ->
        if proxy?(target),
          do: set(target, key, value, receiver),
          else: Props.ordinary_set(target, key, value, receiver)

      f ->
        if Interp.truthy(Interp.call(f, handler, [target, key_value(key), value, receiver])) do
          case target_state(target, key) do
            {:data, tv, false, _, false} ->
              unless same_value?(value, tv),
                do:
                  err(
                    "'set' on proxy: trap returned truish for a non-writable, non-configurable property"
                  )

            {:accessor, _, :undefined, _, false} ->
              err("'set' on proxy: trap returned truish for an accessor without a setter")

            _ ->
              :ok
          end

          true
        else
          false
        end
    end
  end

  def has(p, key) do
    {target, handler} = state(p)

    case trap(handler, "has") do
      nil ->
        if proxy?(target), do: has(target, key), else: Interp.has_property?(target, key)

      f ->
        r = Interp.truthy(Interp.call(f, handler, [target, key_value(key)]))

        unless r do
          case target_state(target, key) do
            nil ->
              :ok

            {_, _, _, _, false} ->
              err("'has' on proxy: trap returned falsish for a non-configurable property")

            _ ->
              unless Props.extensible?(target),
                do:
                  err(
                    "'has' on proxy: trap returned falsish for a property of a non-extensible object"
                  )
          end
        end

        r
    end
  end

  def delete(p, key) do
    {target, handler} = state(p)

    case trap(handler, "deleteProperty") do
      nil ->
        if proxy?(target), do: delete(target, key), else: Interp.delete(target, key)

      f ->
        r = Interp.truthy(Interp.call(f, handler, [target, key_value(key)]))

        if r do
          case target_state(target, key) do
            nil ->
              :ok

            {_, _, _, _, false} ->
              err(
                "'deleteProperty' on proxy: trap returned truish for a non-configurable property"
              )

            _ ->
              unless Props.extensible?(target),
                do:
                  err(
                    "'deleteProperty' on proxy: trap returned truish for a property of a non-extensible object"
                  )
          end
        end

        r
    end
  end

  # ── own keys and descriptors ───────────────────────────────

  @doc "[[OwnPropertyKeys]]: every own key (strings, then symbols)."
  def own_keys(p) do
    {target, handler} = state(p)

    case trap(handler, "ownKeys") do
      nil ->
        Props.own_names(target) ++ Props.own_symbols(target)

      f ->
        result = Interp.call(f, handler, [target])

        unless match?({:obj, _}, result),
          do: err("CreateListFromArrayLike called on non-object")

        keys = list_from_array_like(result)

        for k <- keys do
          unless is_binary(k) or match?({:symbol, _, _}, k),
            do: err("#{Interp.to_str(k)} is not a valid property name")
        end

        if length(Enum.uniq(keys)) != length(keys),
          do: err("'ownKeys' on proxy: trap returned duplicate entries")

        extensible? = Props.extensible?(target)
        target_keys = Props.own_names(target) ++ Props.own_symbols(target)

        {nonconfig, config} =
          Enum.split_with(target_keys, fn k ->
            match?({_, _, _, _, false}, target_state(target, k))
          end)

        if extensible? and nonconfig == [] do
          keys
        else
          unchecked = keys

          unchecked =
            Enum.reduce(nonconfig, unchecked, fn k, acc ->
              unless k in acc,
                do: err("'ownKeys' on proxy: trap result did not include '#{show(k)}'")

              List.delete(acc, k)
            end)

          if extensible? do
            keys
          else
            unchecked =
              Enum.reduce(config, unchecked, fn k, acc ->
                unless k in acc,
                  do: err("'ownKeys' on proxy: trap result did not include '#{show(k)}'")

                List.delete(acc, k)
              end)

            if unchecked != [],
              do:
                err(
                  "'ownKeys' on proxy: trap returned extra keys but proxy target is non-extensible"
                )

            keys
          end
        end
    end
  end

  defp list_from_array_like(o) do
    n =
      o
      |> Interp.get("length")
      |> Interp.to_num()
      |> then(&if(is_number(&1), do: trunc(&1), else: 0))

    for i <- 0..(n - 1)//1, do: Interp.get(o, Integer.to_string(i))
  end

  @doc "[[GetOwnProperty]] as a descriptor object, or undefined."
  def get_own_property(p, key) do
    {target, handler} = state(p)

    case trap(handler, "getOwnPropertyDescriptor") do
      nil ->
        Props.descriptor(target, key)

      f ->
        r = Interp.call(f, handler, [target, key_value(key)])
        ts = target_state(target, key)

        cond do
          r == :undefined ->
            case ts do
              nil ->
                :undefined

              {_, _, _, _, false} ->
                err(
                  "'getOwnPropertyDescriptor' on proxy: trap returned undefined for non-configurable property '#{show(key)}'"
                )

              _ ->
                if Props.extensible?(target),
                  do: :undefined,
                  else:
                    err(
                      "'getOwnPropertyDescriptor' on proxy: trap returned undefined for property '#{show(key)}' of a non-extensible object"
                    )
            end

          match?({:obj, _}, r) ->
            desc = r |> Props.to_property_descriptor() |> complete()

            unless Props.compatible?(Props.extensible?(target), desc, ts),
              do:
                err(
                  "'getOwnPropertyDescriptor' on proxy: trap returned a descriptor incompatible with property '#{show(key)}'"
                )

            if Map.get(desc, :configurable) == false do
              case ts do
                nil ->
                  err(
                    "'getOwnPropertyDescriptor' on proxy: trap reported non-configurability for missing property '#{show(key)}'"
                  )

                {_, _, _, _, true} ->
                  err(
                    "'getOwnPropertyDescriptor' on proxy: trap reported non-configurability for configurable property '#{show(key)}'"
                  )

                {:data, _, true, _, false} ->
                  if Map.get(desc, :writable) == false,
                    do:
                      err(
                        "'getOwnPropertyDescriptor' on proxy: trap reported non-writable for writable property '#{show(key)}'"
                      )

                _ ->
                  :ok
              end
            end

            desc_object(desc)

          true ->
            err(
              "'getOwnPropertyDescriptor' on proxy: trap returned neither object nor undefined for property '#{show(key)}'"
            )
        end
    end
  end

  # CompletePropertyDescriptor
  defp complete(desc) do
    accessor? = Map.has_key?(desc, :get) or Map.has_key?(desc, :set)

    desc =
      if accessor? do
        desc |> Map.put_new(:get, :undefined) |> Map.put_new(:set, :undefined)
      else
        desc |> Map.put_new(:value, :undefined) |> Map.put_new(:writable, false)
      end

    desc |> Map.put_new(:enumerable, false) |> Map.put_new(:configurable, false)
  end

  defp desc_object(desc) do
    fields =
      if Map.has_key?(desc, :get),
        do: [{"get", desc.get}, {"set", desc.set}],
        else: [{"value", desc.value}, {"writable", desc.writable}]

    Interp.new_object(
      fields ++ [{"enumerable", desc.enumerable}, {"configurable", desc.configurable}]
    )
  end

  @doc "[[DefineOwnProperty]]: true when the trap (or the target) accepted it."
  def define_own_property(p, key, descriptor, desc) do
    {target, handler} = state(p)

    case trap(handler, "defineProperty") do
      nil ->
        Props.define(target, key, descriptor)
        true

      f ->
        if Interp.truthy(Interp.call(f, handler, [target, key_value(key), desc_for_trap(desc)])) do
          ts = target_state(target, key)
          ext = Props.extensible?(target)
          setting_nonconfig = Map.get(desc, :configurable) == false

          cond do
            ts == nil and not ext ->
              err(
                "'defineProperty' on proxy: trap returned truish for adding property '#{show(key)}' to a non-extensible object"
              )

            ts == nil and setting_nonconfig ->
              err(
                "'defineProperty' on proxy: trap returned truish for defining non-configurable property '#{show(key)}' which is non-existent in the target"
              )

            ts != nil and not Props.compatible?(ext, desc, ts) ->
              err(
                "'defineProperty' on proxy: trap returned truish for adding property '#{show(key)}' that is incompatible with the existing property in the proxy target"
              )

            ts != nil and setting_nonconfig and match?({_, _, _, _, true}, ts) ->
              err(
                "'defineProperty' on proxy: trap returned truish for defining non-configurable property '#{show(key)}' which is configurable in the target"
              )

            match?({:data, _, true, _, false}, ts) and Map.get(desc, :writable) == false ->
              err(
                "'defineProperty' on proxy: trap returned truish for defining non-configurable property '#{show(key)}' which cannot be non-writable"
              )

            true ->
              true
          end
        else
          false
        end
    end
  end

  defp desc_for_trap(desc) do
    fields =
      for k <- ~w(value writable get set enumerable configurable)a, Map.has_key?(desc, k) do
        {Atom.to_string(k), Map.fetch!(desc, k)}
      end

    Interp.new_object(fields)
  end

  # ── prototype and extensibility ────────────────────────────

  def get_prototype_of(p) do
    {target, handler} = state(p)

    case trap(handler, "getPrototypeOf") do
      nil ->
        Props.get_prototype_of(target)

      f ->
        r = Interp.call(f, handler, [target])

        unless r == :null or match?({:obj, _}, r),
          do: err("'getPrototypeOf' on proxy: trap returned neither object nor null")

        if not Props.extensible?(target) and r != Props.get_prototype_of(target),
          do:
            err(
              "'getPrototypeOf' on proxy: proxy target is non-extensible but the trap did not return its actual prototype"
            )

        r
    end
  end

  def set_prototype_of(p, v) do
    {target, handler} = state(p)

    case trap(handler, "setPrototypeOf") do
      nil ->
        Props.set_prototype_of(target, v) == true

      f ->
        if Interp.truthy(Interp.call(f, handler, [target, v])) do
          if not Props.extensible?(target) and v != Props.get_prototype_of(target),
            do:
              err(
                "'setPrototypeOf' on proxy: trap returned truish for setting a new prototype on the non-extensible proxy target"
              )

          true
        else
          false
        end
    end
  end

  def extensible?(p) do
    {target, handler} = state(p)

    case trap(handler, "isExtensible") do
      nil ->
        Props.extensible?(target)

      f ->
        r = Interp.truthy(Interp.call(f, handler, [target]))

        if r != Props.extensible?(target),
          do:
            err(
              "'isExtensible' on proxy: trap result does not reflect extensibility of proxy target"
            )

        r
    end
  end

  def prevent_extensions(p) do
    {target, handler} = state(p)

    case trap(handler, "preventExtensions") do
      nil ->
        Props.prevent_extensions(target)
        true

      f ->
        r = Interp.truthy(Interp.call(f, handler, [target]))

        if r and Props.extensible?(target),
          do:
            err(
              "'preventExtensions' on proxy: trap returned truish but the proxy target is extensible"
            )

        r
    end
  end

  # ── construct ──────────────────────────────────────────────

  def construct(p, args, new_target) do
    {target, handler} = state(p)

    case trap(handler, "construct") do
      nil ->
        Interp.construct(target, args, if(new_target == p, do: target, else: new_target))

      f ->
        r = Interp.call(f, handler, [target, Interp.new_array(args), new_target])

        unless match?({:obj, _}, r),
          do: err("proxy [[Construct]] must return an object")

        r
    end
  end

  @doc "IsArray: follows proxies (a revoked one throws)."
  def is_array({:obj, id} = o) do
    case Interp.deref(id) do
      %{proxy: _} -> is_array(elem(state(o), 0))
      %{class: :array} = o -> not Map.get(o, :arguments, false)
      _ -> false
    end
  end

  def is_array(_), do: false

  def constructor?({:obj, id}), do: Map.get(Interp.deref(id), :proxy_constructor, false)

  # ── the host protocol (non-function proxies) ───────────────

  def host_get(id, key, self), do: {:ok, get({:obj, id}, key, self)}

  def host_put(id, key, value, self) do
    unless set({:obj, id}, key, value, self), do: :erlang.put(:js_put_failed, true)
    :ok
  end

  def host_has(id, key), do: has({:obj, id}, key)
  def host_delete(id, key), do: delete({:obj, id}, key)

  # enumerable own string keys: the `ownKeys` result filtered by each key's descriptor
  def host_keys(id) do
    p = {:obj, id}

    for k <- own_keys(p),
        is_binary(k),
        d = get_own_property(p, k),
        d != :undefined,
        Interp.truthy(Interp.get(d, "enumerable")),
        do: k
  end

  # ── misc ───────────────────────────────────────────────────

  defp target_state({:obj, id} = t, key) do
    if Map.has_key?(Interp.deref(id), :proxy) do
      case get_own_property(t, key) do
        :undefined ->
          nil

        d ->
          desc = d |> Props.to_property_descriptor() |> complete()

          if Map.has_key?(desc, :get),
            do: {:accessor, desc.get, desc.set, desc.enumerable, desc.configurable},
            else: {:data, desc.value, desc.writable, desc.enumerable, desc.configurable}
      end
    else
      Props.own_state(t, key)
    end
  end

  defp show({:symbol, _, d}), do: d
  defp show(k), do: Interp.to_str(k)
end
