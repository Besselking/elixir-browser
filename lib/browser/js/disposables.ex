defmodule Browser.JS.Disposables do
  @moduledoc """
  `DisposableStack` and `AsyncDisposableStack` (explicit resource management): a stack of
  disposers that run, last added first, when the stack is disposed.

  A stack is an ordinary object with its state in a `:dstate` field: `{state, items}` where
  `state` is `:pending` or `:disposed` and `items` is the resources, newest first, in the form
  `Interp.using_resource/2` gives (the same as for a `using` declaration).
  """

  import Browser.JS.Interp, except: [get: 2, put: 3]
  alias Browser.JS.{Interp, Promise, Props}

  @dispose {:symbol, :dispose, "Symbol.dispose"}
  @async_dispose {:symbol, :asyncDispose, "Symbol.asyncDispose"}

  defp arg(args, i), do: Enum.at(args, i, :undefined)

  def install(scope) do
    install_stack(scope, :sync)
    install_stack(scope, :async)
  end

  defp install_stack(scope, mode) do
    {name, dispose_name, dispose_sym, kind} =
      case mode do
        :sync -> {"DisposableStack", "dispose", @dispose, :using}
        :async -> {"AsyncDisposableStack", "disposeAsync", @async_dispose, :await_using}
      end

    p = new_object()

    ctor =
      native(name, fn this, _ ->
        unless match?({:obj, _}, this),
          do: throw_error("TypeError", "Constructor #{name} requires 'new'")

        set_state(this, mode, {:pending, []})
        this
      end)

    put_const(ctor, "prototype", p)
    put_hidden(p, "constructor", ctor)
    declare(scope, name, ctor)
    put_tag(p, name)

    # `this` must be a stack of this kind (a TypeError, or for disposeAsync a rejection)
    stack! = fn this ->
      case state_of(this, mode) do
        nil -> throw_error("TypeError", "not a #{name}")
        st -> st
      end
    end

    live! = fn this ->
      case stack!.(this) do
        {:disposed, _} -> throw_error("ReferenceError", "#{name} is already disposed")
        {:pending, items} -> items
      end
    end

    method(p, "adopt", 2.0, fn this, args ->
      items = live!.(this)
      value = arg(args, 0)
      on_dispose = arg(args, 1)

      unless function?(on_dispose),
        do: throw_error("TypeError", "onDispose is not a function")

      closure = native("", fn _, _ -> call(on_dispose, :undefined, [value]) end)
      set_state(this, mode, {:pending, [{:res, :undefined, closure, mode} | items]})
      value
    end)

    method(p, "defer", 1.0, fn this, args ->
      items = live!.(this)
      on_dispose = arg(args, 0)

      unless function?(on_dispose),
        do: throw_error("TypeError", "onDispose is not a function")

      set_state(this, mode, {:pending, [{:res, :undefined, on_dispose, mode} | items]})
      :undefined
    end)

    method(p, "use", 1.0, fn this, args ->
      items = live!.(this)
      value = arg(args, 0)

      case {mode, Interp.using_resource(kind, value)} do
        # nothing to dispose in a sync stack
        {:sync, {:none, _}} -> :ok
        {_, res} -> set_state(this, mode, {:pending, [res | items]})
      end

      value
    end)

    method(p, "move", 0.0, fn this, _ ->
      items = live!.(this)
      moved = new_object([], p)
      set_state(moved, mode, {:pending, items})
      set_state(this, mode, {:disposed, []})
      moved
    end)

    Props.define_accessor(p, "disposed",
      get:
        native("get disposed", fn this, _ ->
          match?({:disposed, _}, stack!.(this))
        end),
      enumerable: false
    )

    dispose =
      case mode do
        :sync ->
          method(p, dispose_name, 0.0, fn this, _ ->
            case stack!.(this) do
              {:disposed, _} ->
                :undefined

              {:pending, items} ->
                set_state(this, mode, {:disposed, []})

                case dispose_items(items) do
                  :ok -> :undefined
                  {:error, e} -> throw({:js_error, e})
                end
            end
          end)

        :async ->
          method(p, dispose_name, 0.0, fn this, _ ->
            promise = Promise.new()

            case state_of(this, :async) do
              nil ->
                Promise.reject(promise, make_error("TypeError", "not an AsyncDisposableStack"))

              {:disposed, _} ->
                Promise.resolve(promise, :undefined)

              {:pending, items} ->
                set_state(this, mode, {:disposed, []})

                dispose_async(items, fn
                  :ok -> Promise.resolve(promise, :undefined)
                  {:error, e} -> Promise.reject(promise, e)
                end)
            end

            promise
          end)
      end

    put_hidden(p, dispose_sym, dispose)
    :ok
  end

  defp method(obj, name, arity, fun) do
    {:obj, id} = f = native(name, fun)
    store(id, Map.put(deref(id), :arity, arity))
    put_hidden(obj, name, f)
    f
  end

  defp set_state({:obj, id}, mode, {status, items}),
    do: store(id, Map.put(deref(id), :dstate, {mode, status, items}))

  # the state of a stack of this kind, or nil
  defp state_of({:obj, id}, mode) do
    case deref(id) do
      %{dstate: {^mode, status, items}} -> {status, items}
      _ -> nil
    end
  end

  defp state_of(_, _), do: nil

  # ── disposing ──────────────────────────────────────────────

  # runs the resources in order (newest first); the first error stands, each later one wraps it
  defp dispose_items(items) do
    Enum.reduce(items, :ok, fn item, acc ->
      case Interp.dispose_sync(item) do
        :ok -> acc
        {:error, e} -> merge(acc, e)
      end
    end)
  end

  defp merge(:ok, e), do: {:error, e}
  defp merge({:error, old}, e), do: {:error, Interp.suppressed_error(e, old)}

  # the same, awaiting each disposer; `finish` gets :ok or {:error, e}
  defp dispose_async(items, finish), do: dispose_loop(items, :ok, false, false, finish)

  defp dispose_loop([], acc, awaited?, needs_await?, finish) do
    if needs_await? and not awaited?,
      do: await_then(:undefined, fn _ -> finish.(acc) end, fn _ -> finish.(acc) end),
      else: finish.(acc)
  end

  defp dispose_loop([{:none, _} | rest], acc, awaited?, _needs, finish),
    do: dispose_loop(rest, acc, awaited?, true, finish)

  defp dispose_loop([{:res, v, m, mode} | rest], acc, awaited?, needs, finish) do
    next = fn acc, awaited? -> dispose_loop(rest, acc, awaited?, needs, finish) end

    try do
      {:ok, call(m, v, [])}
    catch
      {:js_error, e} ->
        # the wrapper around a sync `dispose` hands back a rejected promise: that is awaited
        if mode == :async_from_sync,
          do: await_then(:undefined, fn _ -> next.(merge(acc, e), true) end, fn _ -> :ok end),
          else: next.(merge(acc, e), awaited?)
    else
      {:ok, result} ->
        awaited = if mode == :async_from_sync, do: :undefined, else: result

        await_then(
          awaited,
          fn _ -> next.(acc, true) end,
          fn e -> next.(merge(acc, e), true) end
        )
    end
  end

  defp await_then(value, on_ok, on_err) do
    p =
      if Promise.promise?(value) do
        value
      else
        np = Promise.new()
        Promise.resolve(np, value)
        np
      end

    Promise.then(
      p,
      native("", fn _, args ->
        on_ok.(arg(args, 0))
        :undefined
      end),
      native("", fn _, args ->
        on_err.(arg(args, 0))
        :undefined
      end)
    )

    :ok
  end
end
