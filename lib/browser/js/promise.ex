defmodule Browser.JS.Promise do
  @moduledoc """
  Promises, `async` functions and `await` for the JavaScript runtime.

  A promise is a heap object of class `:promise` holding its state and the reactions waiting on
  it. Reactions run as microtasks, which are drained when a script, a timer callback or an event
  handler returns (see `run_microtasks/0`).

  `async` functions are run by `Browser.JS.Async`, which suspends them at an `await` and resumes
  them from a promise reaction. The `await/1` here is only for an `await` outside any async
  function (a top-level one in a module): it blocks, running microtasks and timers until the
  promise has settled.
  """

  import Browser.JS.Interp, except: [get: 2, put: 3]
  alias Browser.JS.Interp

  defp arg(args, i), do: Enum.at(args, i, :undefined)

  # ── promises ───────────────────────────────────────────────

  def new do
    {:obj,
     alloc(%{
       class: :promise,
       state: :pending,
       value: :undefined,
       reactions: [],
       props: %{},
       keys: [],
       proto: proto(:promise)
     })}
  end

  def promise?({:obj, id}), do: match?(%{class: :promise}, deref(id))
  def promise?(_), do: false

  defp data({:obj, id}), do: deref(id)

  defp update({:obj, id}, fun), do: store(id, fun.(deref(id)))

  def state(p), do: data(p).state

  @doc "The promise's resolve function: settles it with `value`, following thenables."
  def resolve(p, value) do
    cond do
      value == p ->
        reject(p, make_error("TypeError", "Chaining cycle detected for promise"))

      match?({:obj, _}, value) ->
        try do
          case thenable(value) do
            nil -> fulfill(p, value)
            then_fn -> enqueue(fn -> follow(p, value, then_fn) end)
          end
        catch
          {:js_error, e} -> reject(p, e)
        end

      true ->
        fulfill(p, value)
    end
  end

  # the `then` method of a thenable, `nil` for anything else; a throwing getter propagates
  defp thenable(obj) do
    case Interp.get(obj, "then") do
      f when is_tuple(f) -> if function?(f), do: f
      _ -> nil
    end
  end

  defp follow(p, thenable, then_fn) do
    {res, rej} = once_pair(p)

    try do
      call(then_fn, thenable, [res, rej])
    catch
      {:js_error, e} -> call(rej, :undefined, [e])
    end
  end

  # resolve and reject functions of which only the first call counts
  defp once_pair(p) do
    key = {:js_once, make_ref()}

    guard = fn fun ->
      with_length(
        native("", fn _, args ->
          unless Process.get(key) do
            Process.put(key, true)
            fun.(arg(args, 0))
          end

          :undefined
        end),
        1
      )
    end

    {guard.(&resolve(p, &1)), guard.(&reject(p, &1))}
  end

  def fulfill(p, v), do: settle(p, :fulfilled, v)
  def reject(p, e), do: settle(p, :rejected, e)

  defp settle(p, state, v) do
    d = data(p)

    if d.state == :pending do
      update(p, &%{&1 | state: state, value: v, reactions: []})
      for r <- Enum.reverse(d.reactions), do: enqueue(fn -> react(r, state, v) end)
    end

    :ok
  end

  @doc "`p.then(on_fulfilled, on_rejected)`: the derived promise."
  def then(p, on_f, on_r), do: then(p, on_f, on_r, new())

  defp then(p, on_f, on_r, child) do
    reaction = %{on_f: on_f, on_r: on_r, child: child}
    d = data(p)

    case d.state do
      :pending -> update(p, &%{&1 | reactions: [reaction | &1.reactions]})
      state -> enqueue(fn -> react(reaction, state, d.value) end)
    end

    child
  end

  defp react(%{on_f: on_f, on_r: on_r, child: child}, state, value) do
    handler = if state == :fulfilled, do: on_f, else: on_r

    if function?(handler) do
      try do
        child_resolve(child, call(handler, :undefined, [value]))
      catch
        {:js_error, e} -> child_reject(child, e)
      end
    else
      if state == :fulfilled, do: child_resolve(child, value), else: child_reject(child, value)
    end
  end

  defp child_resolve({:cap, res, _}, v), do: call(res, :undefined, [v])
  defp child_resolve(child, v), do: resolve(child, v)
  defp child_reject({:cap, _, rej}, e), do: call(rej, :undefined, [e])
  defp child_reject(child, e), do: reject(child, e)

  # ── microtasks ─────────────────────────────────────────────

  def enqueue(fun), do: Process.put(:js_microtasks, [fun | Process.get(:js_microtasks, [])])

  @doc "Runs the queued microtasks (and those they queue) to the end."
  def run_microtasks do
    case Process.get(:js_microtasks, []) do
      [] ->
        :ok

      jobs ->
        Process.put(:js_microtasks, [])
        Enum.each(Enum.reverse(jobs), & &1.())
        run_microtasks()
    end
  end

  # ── await outside async functions ──────────────────────────

  @doc "`await value`."
  def await(value) do
    p =
      if promise?(value) do
        value
      else
        np = new()
        resolve(np, value)
        np
      end

    settle_loop(p)
  end

  defp settle_loop(p) do
    run_microtasks()

    case data(p) do
      %{state: :fulfilled, value: v} ->
        v

      %{state: :rejected, value: e} ->
        throw({:js_error, e})

      %{state: :pending} ->
        if Browser.JS.Builtins.run_next_timer(fn _ -> :ok end),
          do: settle_loop(p),
          else: throw_error("Error", "await: the promise never settles")
    end
  end

  # ── install ────────────────────────────────────────────────

  def install(scope) do
    p = new_object()
    put_proto(:promise, p)

    ctor =
      native("Promise", fn _this, args ->
        executor = arg(args, 0)

        unless function?(executor),
          do: throw_error("TypeError", "Promise resolver #{to_str(executor)} is not a function")

        promise = new()
        {res, rej} = once_pair(promise)

        try do
          call(executor, :undefined, [res, rej])
        catch
          {:js_error, e} -> call(rej, :undefined, [e])
        end

        promise
      end)

    put_const(ctor, "prototype", p)
    put_hidden(p, "constructor", ctor)
    put_proto(:promise_ctor, ctor)
    declare(scope, "Promise", ctor)
    def_species(ctor)

    def_fn(p, "then", fn this, args ->
      unless promise?(this),
        do: throw_error("TypeError", "Promise.prototype.then called on a non-promise")

      c = species_constructor(this)

      if c == proto(:promise_ctor) do
        then(this, arg(args, 0), arg(args, 1))
      else
        {child, res, rej} = capability(c)
        then(this, arg(args, 0), arg(args, 1), {:cap, res, rej})
        child
      end
    end)

    def_fn(p, "catch", fn this, args -> invoke_then(this, :undefined, arg(args, 0)) end)

    def_fn(p, "finally", fn this, args ->
      unless match?({:obj, _}, this),
        do: throw_error("TypeError", "Promise.prototype.finally called on a non-object")

      c = species_constructor(this)
      f = arg(args, 0)

      if function?(f) do
        # `C.resolve(f())` is awaited, then the original value or reason passes through
        settle_then = fn result, k ->
          promise =
            call(Interp.get(c, "resolve"), c, [result])

          call(Interp.get(promise, "then"), promise, [native("", fn _, _ -> k.() end)])
        end

        invoke_then(
          this,
          with_length(
            native("", fn _, a ->
              settle_then.(call(f, :undefined, []), fn -> arg(a, 0) end)
            end),
            1
          ),
          with_length(
            native("", fn _, a ->
              settle_then.(call(f, :undefined, []), fn -> throw({:js_error, arg(a, 0)}) end)
            end),
            1
          )
        )
      else
        invoke_then(this, f, f)
      end
    end)

    put_tag(p, "Promise")

    def_fn(ctor, "resolve", fn this, args ->
      unless match?({:obj, _}, this),
        do: throw_error("TypeError", "Promise.resolve called on a non-object")

      v = arg(args, 0)

      if promise?(v) and Interp.get(v, "constructor") == this do
        v
      else
        {pr, res, _} = capability(this)
        call(res, :undefined, [v])
        pr
      end
    end)

    def_fn(ctor, "reject", fn this, args ->
      {pr, _, rej} = capability(this)
      call(rej, :undefined, [arg(args, 0)])
      pr
    end)

    def_fn(ctor, "withResolvers", fn this, _ ->
      {pr, res, rej} = capability(this)
      new_object([{"promise", pr}, {"resolve", res}, {"reject", rej}])
    end)

    put_hidden(ctor, "allKeyed", Browser.JS.Prelude.all_keyed())
    put_hidden(ctor, "allSettledKeyed", Browser.JS.Prelude.all_settled_keyed())

    put_hidden(
      ctor,
      "try",
      with_length(
        native("try", fn this, args ->
          unless match?({:obj, _}, this),
            do: throw_error("TypeError", "Promise.try called on a non-object")

          {pr, res, rej} = capability(this)

          try do
            call(res, :undefined, [call(arg(args, 0), :undefined, Enum.drop(args, 1))])
          catch
            {:js_error, e} -> call(rej, :undefined, [e])
          end

          pr
        end),
        1
      )
    )

    def_fn(ctor, "all", fn this, args -> combine(this, arg(args, 0), :all) end)
    def_fn(ctor, "allSettled", fn this, args -> combine(this, arg(args, 0), :all_settled) end)
    def_fn(ctor, "race", fn this, args -> combine(this, arg(args, 0), :race) end)
    def_fn(ctor, "any", fn this, args -> combine(this, arg(args, 0), :any) end)

    declare(
      scope,
      "queueMicrotask",
      native("queueMicrotask", fn _, args ->
        f = arg(args, 0)
        enqueue(fn -> call(f, :undefined, []) end)
        :undefined
      end)
    )

    :ok
  end

  defp invoke_then(this, on_f, on_r) do
    then_fn = Interp.get(this, "then")
    call(then_fn, this, [on_f, on_r])
  end

  # SpeciesConstructor(promise, %Promise%)
  defp species_constructor(promise) do
    default = proto(:promise_ctor)

    case Interp.get(promise, "constructor") do
      :undefined ->
        default

      {:obj, _} = c ->
        case Interp.get(c, {:symbol, :species, "Symbol.species"}) do
          s when s in [:undefined, :null, nil] ->
            default

          s ->
            if constructor?(s),
              do: s,
              else:
                throw_error(
                  "TypeError",
                  "object.constructor[Symbol.species] is not a constructor"
                )
        end

      _ ->
        throw_error("TypeError", "The .constructor property is not an object")
    end
  end

  # NewPromiseCapability(C): {promise, resolve function, reject function}
  defp capability(c) do
    if c == proto(:promise_ctor) do
      p = new()
      {res, rej} = once_pair(p)
      {p, res, rej}
    else
      unless constructor?(c),
        do: throw_error("TypeError", "Promise capability constructor is not a constructor")

      key = {:js_capability, make_ref()}
      :erlang.put(key, {:undefined, :undefined})

      executor =
        native("", fn _, args ->
          {r, j} = :erlang.get(key)

          if r != :undefined or j != :undefined,
            do: throw_error("TypeError", "Promise executor has already been invoked")

          :erlang.put(key, {arg(args, 0), arg(args, 1)})
          :undefined
        end)
        |> with_length(2)

      p = Interp.construct(c, [executor])
      {res, rej} = :erlang.erase(key)

      unless function?(res) and function?(rej),
        do: throw_error("TypeError", "Promise resolve or reject function is not callable")

      {p, res, rej}
    end
  end

  # a built-in function's `length` (the virtual property reads `:arity`)
  defp with_length({:obj, id} = f, n) do
    store(id, Map.put(deref(id), :arity, n * 1.0))
    f
  end

  defp def_fn(obj, name, fun), do: put_hidden(obj, name, native(name, fun))

  # Promise.all / allSettled / race / any: the iterable is pulled one value at a time, each one
  # goes through `C.resolve` and its `then` (so a throwing one closes the iterator and rejects
  # the result), and the combined value is made once the iterator is done and every element
  # has settled
  defp combine(ctor, iterable, mode) do
    unless match?({:obj, _}, ctor),
      do: throw_error("TypeError", "Promise combinator called on a non-object")

    {promise, res_fn, rej_fn} = capability(ctor)
    result = {res_fn, rej_fn}
    key = {:js_combine, make_ref()}
    Process.put(key, %{remaining: 1, values: %{}})

    try do
      resolve_fn = Interp.get(ctor, "resolve")

      unless function?(resolve_fn),
        do: throw_error("TypeError", "Promise resolve is not a function")

      case iter_source(iterable) do
        {:list, items} -> combine_each(items, nil, nil, 0, ctor, resolve_fn, mode, result, key)
        {:proto, it, next} -> combine_each(nil, it, next, 0, ctor, resolve_fn, mode, result, key)
      end

      if mode != :race, do: combine_finish(key, mode, result, -1, nil)
    catch
      {:js_error, e} -> call(rej_fn, :undefined, [e])
    end

    promise
  end

  defp combine_each(items, it, next, i, ctor, resolve_fn, mode, result, key) do
    step =
      case items do
        [h | t] ->
          {:ok, h, t}

        [] ->
          :done

        nil ->
          case iter_step(it, next) do
            :done -> :done
            {:ok, v} -> {:ok, v, nil}
          end
      end

    case step do
      :done ->
        :ok

      {:ok, item, rest} ->
        try do
          combine_item(item, i, ctor, resolve_fn, mode, result, key)
        catch
          kind, e ->
            if it, do: iter_close(it, true)
            :erlang.raise(kind, e, __STACKTRACE__)
        end

        combine_each(rest, it, next, i + 1, ctor, resolve_fn, mode, result, key)
    end
  end

  defp combine_item(item, i, ctor, resolve_fn, mode, result, key) do
    pr = call(resolve_fn, ctor, [item])
    then_fn = Interp.get(pr, "then")

    unless function?(then_fn), do: throw_error("TypeError", "then is not a function")

    if mode != :race do
      s = Process.get(key)
      Process.put(key, %{s | remaining: s.remaining + 1})
    end

    called = {:js_called, make_ref()}

    done = fn v ->
      if :erlang.get(called) != true do
        :erlang.put(called, true)
        combine_finish(key, mode, result, i, v)
      end

      :undefined
    end

    {res_fn, rej_fn} = result

    {on_f, on_r} =
      case mode do
        :all ->
          {with_length(native("", fn _, a -> done.(arg(a, 0)) end), 1), rej_fn}

        :all_settled ->
          {with_length(
             native("", fn _, a ->
               done.(new_object([{"status", "fulfilled"}, {"value", arg(a, 0)}]))
             end),
             1
           ),
           with_length(
             native("", fn _, a ->
               done.(new_object([{"status", "rejected"}, {"reason", arg(a, 0)}]))
             end),
             1
           )}

        :race ->
          {res_fn, rej_fn}

        :any ->
          {res_fn, with_length(native("", fn _, a -> done.(arg(a, 0)) end), 1)}
      end

    call(then_fn, pr, [on_f, on_r])
  end

  # one element has settled (index i), or `-1` when the iterator is done: when nothing is left
  # the result is settled
  defp combine_finish(key, mode, {res_fn, rej_fn}, i, v) do
    s = Process.get(key)
    s = if i >= 0, do: %{s | values: Map.put(s.values, i, v)}, else: s
    s = %{s | remaining: s.remaining - 1}
    Process.put(key, s)

    if s.remaining == 0 do
      list = for j <- 0..(map_size(s.values) - 1)//1, do: Map.fetch!(s.values, j)

      case mode do
        :any ->
          err = make_error("AggregateError", "All promises were rejected")
          put_hidden(err, "errors", new_array(list))
          call(rej_fn, :undefined, [err])

        _ ->
          call(res_fn, :undefined, [new_array(list)])
      end
    end
  end
end
