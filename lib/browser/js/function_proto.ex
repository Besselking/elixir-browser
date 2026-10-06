defmodule Browser.JS.FunctionProto do
  @moduledoc """
  `Function.prototype`: `call`, `apply`, `bind`, `toString`, `[Symbol.hasInstance]`, and the
  `caller`/`arguments` accessors that throw (`%ThrowTypeError%`).
  """

  import Browser.JS.Interp, except: [get: 2, put: 3]
  alias Browser.JS.Interp

  @has_instance {:symbol, :hasInstance, "Symbol.hasInstance"}

  defp get(o, k), do: Interp.get(o, k)
  defp arg(args, i), do: Enum.at(args, i, :undefined)

  def install(p) do
    def_fn(p, "call", 1, fn this, args ->
      callable!(this, "Function.prototype.call")
      call(this, arg(args, 0), Enum.drop(args, 1))
    end)

    def_fn(p, "apply", 2, fn this, args ->
      callable!(this, "Function.prototype.apply")

      list =
        case arg(args, 1) do
          v when v in [:undefined, :null] -> []
          v -> list_from_array_like(v)
        end

      call(this, arg(args, 0), list)
    end)

    def_fn(p, "bind", 1, &bind/2)

    def_fn(p, "toString", 0, fn this, _ ->
      callable!(this, "Function.prototype.toString")
      "function #{String.trim_leading(to_str(get(this, "name")), "#")}() { [native code] }"
    end)

    has_instance =
      native("[Symbol.hasInstance]", fn this, args ->
        ordinary_has_instance(this, arg(args, 0))
      end)

    set_arity(has_instance, 1)
    put_attr(p, @has_instance, has_instance, %{w: false, c: false, e: false})

    # accessors with one shared function as getter and setter
    accessor = restricted_accessor()
    :erlang.put(:js_throw_type_error, accessor)

    for key <- ["caller", "arguments"],
        do: Browser.JS.Props.define(p, key, accessor_desc(accessor, accessor))

    :ok
  end

  defp accessor_desc(get, set),
    do: new_object([{"get", get}, {"set", set}, {"enumerable", false}, {"configurable", true}])

  # `fn.caller` and `fn.arguments` on a sloppy function are null, as everywhere on the web; on
  # anything else they throw (%ThrowTypeError%)
  defp restricted_accessor do
    f =
      native("", fn this, _ ->
        if sloppy_function?(this) do
          :null
        else
          throw_error(
            "TypeError",
            "'caller', 'callee', and 'arguments' properties may not be accessed on strict mode functions or the arguments objects for calls to them"
          )
        end
      end)

    # `length` and `name` are own, non-configurable properties of %ThrowTypeError%
    for {key, value} <- [{"length", 0.0}, {"name", ""}] do
      Browser.JS.Props.define(
        f,
        key,
        new_object([
          {"value", value},
          {"writable", false},
          {"enumerable", false},
          {"configurable", false}
        ])
      )
    end

    Browser.JS.Props.lock(f, true)
    f
  end

  defp sloppy_function?({:obj, id}) do
    case deref(id) do
      %{fun: {:closure, %{mode: mode, name: name, body: body}}} = o when mode in [false, nil] ->
        not (Map.get(o, :generator, false) or Map.get(o, :async, false) or
               Map.get(o, :class_ctor, false) or
               match?({:method, _}, name) or match?([{:expr, {:str, "use strict"}} | _], body))

      _ ->
        false
    end
  end

  defp sloppy_function?(_), do: false

  defp def_fn(obj, name, arity, fun) do
    f = native(name, fun)
    set_arity(f, arity)
    put_hidden(obj, name, f)
  end

  defp callable!(f, what) do
    unless function?(f), do: throw_error("TypeError", "#{what} called on a non-function")
  end

  defp put_attr({:obj, id}, key, v, attrs) do
    o = deref(id)

    store(
      id,
      o
      |> Map.put(:props, Map.put(o.props, key, v))
      |> Map.put(:attrs, Map.put(Map.get(o, :attrs, %{}), key, attrs))
    )
  end

  defp to_length(v) do
    case to_num(v) do
      n when is_number(n) -> n |> trunc() |> max(0) |> min(9_007_199_254_740_991)
      :infinity -> 9_007_199_254_740_991
      _ -> 0
    end
  end

  # CreateListFromArrayLike
  defp list_from_array_like({:obj, _} = v) do
    for i <- 0..(to_length(get(v, "length")) - 1)//1, do: get(v, Integer.to_string(i))
  end

  defp list_from_array_like(_),
    do: throw_error("TypeError", "CreateListFromArrayLike called on non-object")

  # HasOwnProperty(target, "length"): a deleted one is gone even though functions have it virtually
  defp own_length?({:obj, id} = f) do
    "length" in Browser.JS.Props.own_names(f) and "length" not in Map.get(deref(id), :gone, [])
  end

  defp bind(this, args) do
    callable!(this, "Function.prototype.bind")
    bound_this = arg(args, 0)
    bound_args = Enum.drop(args, 1)

    {:obj, id} =
      bound = native("bound", fn _, more -> call(this, bound_this, bound_args ++ more) end)

    # `new bound(...)` constructs the target (see `Interp.construct/3`)
    store(id, Map.put(deref(id), :bound, {this, bound_args}))

    len =
      if own_length?(this) do
        case get(this, "length") do
          :infinity -> :infinity
          :neg_infinity -> 0.0
          n when is_number(n) -> max(0.0, trunc(n) * 1.0 - length(bound_args))
          _ -> 0.0
        end
      else
        0.0
      end

    name =
      case get(this, "name") do
        n when is_binary(n) -> n
        _ -> ""
      end

    put_attr(bound, "length", len, %{w: false, c: true, e: false})
    put_attr(bound, "name", "bound " <> name, %{w: false, c: true, e: false})
    bound
  end
end
