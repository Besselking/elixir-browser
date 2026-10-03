defmodule Browser.JS.Proxy do
  @moduledoc """
  `Proxy` and `Proxy.revocable` for objects: an object backed by Elixir (see `Interp.new_host/3`)
  whose reads, writes, `in`, `delete` and key listing go to the handler's `get`, `set`, `has`,
  `deleteProperty` and `ownKeys` traps, or to the target when the handler has none. A function
  target becomes a function that calls the `apply` trap (or the target) and constructs the target.
  """

  alias Browser.JS.Interp

  def install(scope) do
    maker = fn _this, args -> make(Enum.at(args, 0, :undefined), Enum.at(args, 1, :undefined)) end

    proxy_ctor = Interp.native("Proxy", maker)
    Interp.declare(scope, "Proxy", proxy_ctor)

    Interp.put(
      proxy_ctor,
      "revocable",
      Interp.native("revocable", fn _, args ->
        p = make(Enum.at(args, 0, :undefined), Enum.at(args, 1, :undefined))

        Interp.new_object([
          {"proxy", p},
          {"revoke", Interp.native("revoke", fn _, _ -> :undefined end)}
        ])
      end)
    )

    :ok
  end

  defp make({:obj, _} = target, {:obj, _} = handler) do
    if Interp.function?(target) do
      Interp.native("proxy", fn this, args ->
        case trap(handler, "apply") do
          nil -> Interp.call(target, this, args)
          f -> Interp.call(f, handler, [target, this, Interp.new_array(args)])
        end
      end)
      |> bind_to(target)
    else
      proto =
        case Interp.deref(elem(target, 1)) do
          %{proto: p} -> p
        end

      Interp.new_host(__MODULE__, {target, handler}, proto)
    end
  end

  defp make(_, _),
    do:
      Interp.throw_error(
        "TypeError",
        "Cannot create proxy with a non-object as target or handler"
      )

  # a proxied function constructs its target
  defp bind_to({:obj, id} = f, target) do
    Interp.store(id, Map.put(Interp.deref(id), :bound, {target, []}))
    f
  end

  defp trap(handler, name) do
    case Interp.get(handler, name) do
      f when f not in [:undefined, :null] -> f
      _ -> nil
    end
  end

  # ── the host protocol ──────────────────────────────────────

  def host_get({target, handler}, key, self) do
    case trap(handler, "get") do
      nil -> {:ok, Interp.get(target, key)}
      f -> {:ok, Interp.call(f, handler, [target, key, self])}
    end
  end

  def host_put({target, handler}, key, value, self) do
    case trap(handler, "set") do
      nil ->
        Interp.put(target, key, value)
        :ok

      f ->
        Interp.call(f, handler, [target, key, value, self])
        :ok
    end
  end

  def host_has({target, handler}, key) do
    case trap(handler, "has") do
      nil -> Interp.has_property?(target, key)
      f -> Interp.truthy(Interp.call(f, handler, [target, key]))
    end
  end

  def host_delete({target, handler}, key) do
    case trap(handler, "deleteProperty") do
      nil -> Interp.delete(target, key)
      f -> Interp.truthy(Interp.call(f, handler, [target, key]))
    end
  end

  def host_keys({target, handler}) do
    case trap(handler, "ownKeys") do
      nil ->
        Interp.own_keys(target)

      f ->
        handler
        |> then(&Interp.call(f, &1, [target]))
        |> Interp.array_list()
        |> Enum.map(&Interp.to_str/1)
    end
  end
end
