defmodule Browser.JS.Async do
  @moduledoc """
  The body of an `async` function, run so that `await` really suspends it.

  An async function is evaluated in continuation-passing style: `cev/4` and `cexec/4` take what
  to do next as a function, and `await` hands that function to the awaited promise as a
  reaction, then simply returns. The caller gets the function's promise straight away, and the
  rest of the body runs later, as a microtask, when the awaited promise has settled.

  Only the parts of the body that contain an `await` are run this way; everything else goes to
  the ordinary evaluator in `Browser.JS.Interp`, so a function that awaits once at the end pays
  for that once. Abrupt completions (`return`, `break`, `continue`, a throw) are continuations
  too, kept in the `ctx` map, so that `try`/`finally` and labelled loops behave as usual across
  an `await`.

  Within an expression the awaits are evaluated first, left to right, and the expression is then
  evaluated with their values (`f(a(), await b)` calls `a` after waiting for `b`); `&&`, `||`,
  `??` and `?:` keep their short-circuiting.
  """

  alias Browser.JS.{Interp, Promise}

  @max_depth 1000

  @doc "Calls an async closure: starts its body and returns its promise."
  def call_closure(c, this, args) do
    p = Promise.new()

    ctx = %{
      ret: fn v -> Promise.resolve(p, v) end,
      throw: fn e -> Promise.reject(p, e) end,
      brk: %{},
      cont: %{}
    }

    depth = Process.get(:js_depth)

    if depth >= @max_depth,
      do: Interp.throw_error("RangeError", "Maximum call stack size exceeded")

    Process.put(:js_depth, depth + 1)

    try do
      scope = Interp.call_scope(c, this, args)

      case c.mode do
        :arrow_expr -> cev(c.body, scope, ctx, ctx.ret)
        _ -> clist(c.body, scope, ctx, fn _ -> ctx.ret.(:undefined) end)
      end
    catch
      {:js_error, e} -> Promise.reject(p, e)
    after
      Process.put(:js_depth, depth)
    end

    p
  end

  # ── generators ─────────────────────────────────────────────
  #
  # A generator function's body runs in the same continuation-passing style. `yield` hands the
  # rest of the body (as `resume`) to the generator object and returns; `next`, `throw` and
  # `return` call that function with how to go on. A yielded value, the end of the body or a
  # throw is left in the process dictionary for the caller of `resume/2` to pick up as soon as
  # the body has returned control.

  @doc "Calls a generator function: binds the parameters and makes the generator object."
  def call_generator(f, c, this, args) do
    scope = Interp.call_scope(c, this, args)

    proto =
      case Interp.get(f, "prototype") do
        {:obj, _} = p -> p
        _ -> Interp.proto(:generator)
      end

    {:obj, gid} = gen = Interp.new_object([], proto)

    ctx = %{
      ret: fn v -> finish(gid, {:return, v}) end,
      throw: fn e -> finish(gid, {:throw, e}) end,
      yield: fn v, resume -> suspend(gid, v, resume) end,
      brk: %{},
      cont: %{}
    }

    start = fn
      {:next, _} ->
        case c.mode do
          :arrow_expr -> cev(c.body, scope, ctx, ctx.ret)
          _ -> clist(c.body, scope, ctx, fn _ -> ctx.ret.(:undefined) end)
        end

      {:throw, e} ->
        ctx.throw.(e)

      {:return, v} ->
        ctx.ret.(v)
    end

    set_gen(gid, %{state: :start, resume: start})
    gen
  end

  defp set_gen(gid, gen), do: Interp.store(gid, Map.put(Interp.deref(gid), :gen, gen))

  defp finish(gid, out) do
    set_gen(gid, %{state: :done, resume: nil})
    Process.put(:js_gen_out, out)
    :done
  end

  defp suspend(gid, v, resume) do
    set_gen(gid, %{state: :suspended, resume: resume})
    Process.put(:js_gen_out, {:yield, v})
    :suspended
  end

  @doc "`next`, `throw` or `return` on a generator: `msg` is `{:next | :throw | :return, value}`."
  def resume({:obj, gid}, msg) do
    gen =
      case Interp.deref(gid) do
        %{gen: g} -> g
        _ -> Interp.throw_error("TypeError", "next method called on an incompatible receiver")
      end

    case {gen.state, msg} do
      {:running, _} ->
        Interp.throw_error("TypeError", "Generator is already running")

      {:done, {:next, _}} ->
        iter_result(:undefined, true)

      {:done, {:return, v}} ->
        iter_result(v, true)

      {:done, {:throw, e}} ->
        throw({:js_error, e})

      {:start, {:return, v}} ->
        finish(gid, {:return, v})
        iter_result(v, true)

      {:start, {:throw, e}} ->
        finish(gid, {:throw, e})
        throw({:js_error, e})

      _ ->
        set_gen(gid, %{gen | state: :running})
        Process.delete(:js_gen_out)

        try do
          gen.resume.(msg)
        catch
          {:js_error, e} -> finish(gid, {:throw, e})
        end

        case Process.delete(:js_gen_out) do
          {:yield, v} -> iter_result(v, false)
          {:return, v} -> iter_result(v, true)
          {:throw, e} -> throw({:js_error, e})
          nil -> iter_result(:undefined, true)
        end
    end
  end

  def resume(_, _),
    do: Interp.throw_error("TypeError", "next method called on an incompatible receiver")

  defp iter_result(v, done), do: Interp.new_object([{"value", v}, {"done", done}])

  @doc "`Generator.prototype` with `next`, `return` and `throw`."
  def install_generators do
    p = Interp.new_object([], Interp.proto(:iterator))
    Interp.put_proto(:generator, p)

    for {name, tag} <- [{"next", :next}, {"return", :return}, {"throw", :throw}] do
      f =
        Interp.native(name, fn this, args ->
          resume(this, {tag, Enum.at(args, 0, :undefined)})
        end)

      Interp.set_arity(f, 1)
      Interp.put_hidden(p, name, f)
    end

    Interp.put_tag(p, "Generator")
    :ok
  end

  # ── async generators ───────────────────────────────────────
  #
  # `next`, `return` and `throw` return promises and queue up while the body runs. A yielded
  # value is awaited first, and so is a returned one.

  @doc "Calls an async generator function: binds the parameters and makes the generator object."
  def call_async_generator(f, c, this, args) do
    scope = Interp.call_scope(c, this, args)

    proto =
      case Interp.get(f, "prototype") do
        {:obj, _} = p -> p
        _ -> Interp.proto(:async_generator)
      end

    {:obj, gid} = gen = Interp.new_object([], proto)

    base = %{
      throw: fn e -> ag_finish(gid, {:throw, e}) end,
      yield: fn v, resume -> ag_yield(gid, v, resume) end,
      async_gen: true,
      brk: %{},
      cont: %{}
    }

    ctx =
      Map.put(base, :ret, fn v ->
        await_value(v, base, fn v2 -> ag_finish(gid, {:return, v2}) end)
      end)

    start = fn
      {:next, _} ->
        case c.mode do
          :arrow_expr -> cev(c.body, scope, ctx, ctx.ret)
          _ -> clist(c.body, scope, ctx, fn _ -> ctx.ret.(:undefined) end)
        end

      {:throw, e} ->
        ctx.throw.(e)

      {:return, v} ->
        ctx.ret.(v)
    end

    set_agen(gid, %{state: :start, resume: start, queue: [], running: false, cur: nil})
    gen
  end

  defp agen(gid), do: Map.get(Interp.deref(gid), :agen)
  defp set_agen(gid, g), do: Interp.store(gid, Map.put(Interp.deref(gid), :agen, g))
  defp update_agen(gid, changes), do: set_agen(gid, Map.merge(agen(gid), changes))

  defp ag_request({:obj, gid}, msg) do
    case Interp.deref(gid) do
      %{agen: g} ->
        p = Promise.new()
        update_agen(gid, %{queue: g.queue ++ [{msg, p}]})
        ag_drain(gid)
        p

      _ ->
        p = Promise.new()

        Promise.reject(
          p,
          Interp.make_error("TypeError", "next method called on an incompatible receiver")
        )

        p
    end
  end

  defp ag_request(_, _) do
    p = Promise.new()

    Promise.reject(
      p,
      Interp.make_error("TypeError", "next method called on an incompatible receiver")
    )

    p
  end

  # starts the next queued request, unless the body is running
  defp ag_drain(gid) do
    g = agen(gid)

    with false <- g.running, [{msg, p} | rest] <- g.queue do
      update_agen(gid, %{queue: rest})

      case {g.state, msg} do
        {:done, {:next, _}} ->
          Promise.resolve(p, iter_result(:undefined, true))
          ag_drain(gid)

        {:done, {:throw, e}} ->
          Promise.reject(p, e)
          ag_drain(gid)

        {state, {:throw, e}} when state == :start ->
          update_agen(gid, %{state: :done})
          Promise.reject(p, e)
          ag_drain(gid)

        {state, {:return, v}} when state in [:done, :start] ->
          update_agen(gid, %{state: :done, running: true})

          await_value(v, %{throw: fn e -> ag_settle(gid, p, {:throw, e}) end}, fn v2 ->
            ag_settle(gid, p, {:return, v2})
          end)

        _ ->
          update_agen(gid, %{running: true, cur: p})

          try do
            g.resume.(msg)
          catch
            {:js_error, e} -> ag_finish(gid, {:throw, e})
          end
      end
    else
      _ -> :ok
    end
  end

  defp ag_settle(gid, p, {:return, v}) do
    Promise.resolve(p, iter_result(v, true))
    update_agen(gid, %{running: false})
    ag_drain(gid)
  end

  defp ag_settle(gid, p, {:throw, e}) do
    Promise.reject(p, e)
    update_agen(gid, %{running: false})
    ag_drain(gid)
  end

  defp ag_finish(gid, out) do
    g = agen(gid)
    update_agen(gid, %{state: :done, resume: nil, cur: nil})
    ag_settle(gid, g.cur, out)
    :done
  end

  defp ag_yield(gid, v, resume) do
    await_value(v, %{throw: fn e -> resume.({:throw, e}) end}, fn v2 ->
      g = agen(gid)
      update_agen(gid, %{state: :suspended, resume: resume, running: false, cur: nil})
      Promise.resolve(g.cur, iter_result(v2, false))
      ag_drain(gid)
    end)

    :suspended
  end

  @doc "`AsyncGenerator.prototype`."
  def install_async_generators do
    ai = Interp.new_object()

    Interp.put_hidden(
      ai,
      {:symbol, :asyncIterator, "Symbol.asyncIterator"},
      Interp.native("[Symbol.asyncIterator]", fn this, _ -> this end)
    )

    p = Interp.new_object([], ai)
    Interp.put_proto(:async_generator, p)

    for {name, tag} <- [{"next", :next}, {"return", :return}, {"throw", :throw}] do
      f =
        Interp.native(name, fn this, args ->
          ag_request(this, {tag, Enum.at(args, 0, :undefined)})
        end)

      Interp.set_arity(f, 1)
      Interp.put_hidden(p, name, f)
    end

    Interp.put_tag(p, "AsyncGenerator")
    :ok
  end

  # the iterator of a `for await` or `yield*` in an async generator: an async one, or a sync one
  # whose values are awaited
  defp async_iterator(target) do
    key = {:symbol, :asyncIterator, "Symbol.asyncIterator"}

    method =
      if match?({:obj, _}, target), do: Interp.get(target, key), else: :undefined

    cond do
      is_tuple(method) and Interp.function?(method) ->
        it = Interp.call(method, target, [])
        {it, Interp.get(it, "next"), false}

      true ->
        case Interp.iter_source(target) do
          {:proto, it, next} ->
            {it, next, true}

          {:list, items} ->
            it = iterator_of(items)
            {it, Interp.get(it, "next"), true}
        end
    end
  end

  # `yield*` in an async generator
  defp adelegate(it, next, msg, ctx, k) do
    call_result =
      try do
        {:ok, adelegate_call(it, next, msg)}
      catch
        {:js_error, e} -> {:throw, e}
      end

    case call_result do
      {:throw, e} ->
        ctx.throw.(e)

      {:ok, {:return_now, v}} ->
        ctx.ret.(v)

      {:ok, {:result, r}} ->
        await_value(r, ctx, fn r2 ->
          attempt(
            fn ->
              unless match?({:obj, _}, r2),
                do: Interp.throw_error("TypeError", "Iterator result is not an object")

              {Interp.truthy(Interp.get(r2, "done")), Interp.get(r2, "value")}
            end,
            ctx,
            fn
              {true, v} ->
                if match?({:return, _}, msg), do: ctx.ret.(v), else: k.(v)

              {false, v} ->
                ctx.yield.(v, fn m -> adelegate(it, next, m, ctx, k) end)
            end
          )
        end)
    end
  end

  defp adelegate_call(it, next, {:next, x}), do: {:result, Interp.call(next, it, [x])}

  defp adelegate_call(it, _next, {:throw, e}) do
    case Interp.get(it, "throw") do
      f when is_tuple(f) ->
        if Interp.function?(f),
          do: {:result, Interp.call(f, it, [e])},
          else: Interp.throw_error("TypeError", "The iterator does not provide a 'throw' method")

      _ ->
        Interp.throw_error("TypeError", "The iterator does not provide a 'throw' method")
    end
  end

  defp adelegate_call(it, _next, {:return, v}) do
    case Interp.get(it, "return") do
      f when is_tuple(f) ->
        if Interp.function?(f),
          do: {:result, Interp.call(f, it, [v])},
          else: {:return_now, v}

      _ ->
        {:return_now, v}
    end
  end

  # `yield*`: forwards `next`, `throw` and `return` to the inner iterator
  defp delegate(it, next, msg, ctx, k) do
    attempt(fn -> delegate_step(it, next, msg) end, ctx, fn
      {:yield, v} ->
        ctx.yield.(v, fn m -> delegate(it, next, m, ctx, k) end)

      {:done, v} ->
        k.(v)

      {:return, v} ->
        ctx.ret.(v)
    end)
  end

  defp delegate_step(it, next, {:next, x}) do
    check_result(Interp.call(next, it, [x]), :done)
  end

  defp delegate_step(it, _next, {:throw, e}) do
    case Interp.get(it, "throw") do
      f when is_tuple(f) ->
        if Interp.function?(f) do
          check_result(Interp.call(f, it, [e]), :done)
        else
          Interp.iter_close(it, false)
          Interp.throw_error("TypeError", "The iterator does not provide a 'throw' method")
        end

      _ ->
        Interp.iter_close(it, false)
        Interp.throw_error("TypeError", "The iterator does not provide a 'throw' method")
    end
  end

  defp delegate_step(it, _next, {:return, v}) do
    case Interp.get(it, "return") do
      f when is_tuple(f) ->
        if Interp.function?(f),
          do: check_result(Interp.call(f, it, [v]), :return),
          else: {:return, v}

      _ ->
        {:return, v}
    end
  end

  defp check_result(r, on_done) do
    unless match?({:obj, _}, r),
      do: Interp.throw_error("TypeError", "Iterator result is not an object")

    if Interp.truthy(Interp.get(r, "done")),
      do: {on_done, Interp.get(r, "value")},
      else: {:yield, Interp.get(r, "value")}
  end

  defp iterator_of(items) do
    Browser.JS.Collections.make_iterator(items)
  end

  # runs a piece of synchronous work and hands its value on, or takes its throw
  defp attempt(fun, ctx, k) do
    result =
      try do
        {:ok, fun.()}
      catch
        {:js_error, e} -> {:throw, e}
      end

    case result do
      {:ok, v} -> k.(v)
      {:throw, e} -> ctx.throw.(e)
    end
  end

  # ── what contains an await ─────────────────────────────────

  defp has_await?({:await, _}), do: true
  defp has_await?({:yield, _, _}), do: true
  defp has_await?({:forawait, _, _, _, _}), do: true
  defp has_await?({:using, :await_using, _, _, _}), do: true
  defp has_await?({:gen, _}), do: false
  defp has_await?({:fn, _, _, _, _}), do: false
  defp has_await?({:async, _}), do: false
  defp has_await?(t) when is_tuple(t), do: t |> Tuple.to_list() |> Enum.any?(&has_await?/1)
  defp has_await?(l) when is_list(l), do: Enum.any?(l, &has_await?/1)
  defp has_await?(_), do: false

  # ── expressions ────────────────────────────────────────────

  defp cev(node, env, ctx, k) do
    if has_await?(node), do: cev_await(node, env, ctx, k), else: sync_expr(node, env, ctx, k)
  end

  defp cev_await({:await, e}, env, ctx, k) do
    cev(e, env, ctx, fn v -> await_value(v, ctx, k) end)
  end

  defp cev_await({:yield, e, false}, env, ctx, k) do
    cev(e, env, ctx, fn v ->
      ctx.yield.(v, fn
        {:next, x} -> k.(x)
        {:throw, err} -> ctx.throw.(err)
        {:return, r} -> ctx.ret.(r)
      end)
    end)
  end

  defp cev_await({:yield, e, true}, env, %{async_gen: true} = ctx, k) do
    cev(e, env, ctx, fn iterable ->
      attempt(fn -> async_iterator(iterable) end, ctx, fn {it, next, _sync?} ->
        adelegate(it, next, {:next, :undefined}, ctx, k)
      end)
    end)
  end

  defp cev_await({:yield, e, true}, env, ctx, k) do
    cev(e, env, ctx, fn iterable ->
      attempt(
        fn ->
          case Interp.iter_source(iterable) do
            {:proto, it, next} -> {it, next}
            {:list, items} -> {iterator_of(items), nil}
          end
        end,
        ctx,
        fn
          {it, nil} ->
            delegate(it, Interp.get(it, "next"), {:next, :undefined}, ctx, k)

          {it, next} ->
            delegate(it, next, {:next, :undefined}, ctx, k)
        end
      )
    end)
  end

  defp cev_await({:logical, op, l, r}, env, ctx, k) do
    cev(l, env, ctx, fn lv ->
      short =
        case op do
          "&&" -> not Interp.truthy(lv)
          "||" -> Interp.truthy(lv)
          "??" -> not Interp.nullish?(lv)
        end

      if short, do: k.(lv), else: cev(r, env, ctx, k)
    end)
  end

  defp cev_await({:cond, c, a, b}, env, ctx, k) do
    cev(c, env, ctx, fn cv ->
      if Interp.truthy(cv), do: cev(a, env, ctx, k), else: cev(b, env, ctx, k)
    end)
  end

  defp cev_await(node, env, ctx, k) do
    {template, leaves} = lift(node, [])
    scope = Interp.new_scope(env)

    eval_leaves(Enum.reverse(leaves), 0, scope, env, ctx, fn ->
      sync_expr(template, scope, ctx, k)
    end)
  end

  # the awaits (and short-circuit expressions holding one) of an expression, in order, each
  # replaced by a variable the expression is later evaluated with
  defp lift(node, leaves) do
    cond do
      leaf?(node) ->
        name = "\0s#{length(leaves)}"
        {{:id, name}, [node | leaves]}

      is_tuple(node) and elem(node, 0) in [:fn, :async] ->
        {node, leaves}

      is_tuple(node) ->
        {items, leaves} = lift_list(Tuple.to_list(node), leaves)
        {List.to_tuple(items), leaves}

      is_list(node) ->
        lift_list(node, leaves)

      true ->
        {node, leaves}
    end
  end

  defp lift_list(items, leaves) do
    Enum.map_reduce(items, leaves, fn item, acc -> lift(item, acc) end)
  end

  defp leaf?({:await, _}), do: true
  defp leaf?({:yield, _, _}), do: true
  defp leaf?({:logical, _, _, _} = n), do: has_await?(n)
  defp leaf?({:cond, _, _, _} = n), do: has_await?(n)
  defp leaf?(_), do: false

  defp eval_leaves([], _i, _scope, _env, _ctx, done), do: done.()

  defp eval_leaves([leaf | rest], i, scope, env, ctx, done) do
    cev(leaf, env, ctx, fn v ->
      Interp.declare(scope, "\0s#{i}", v)
      eval_leaves(rest, i + 1, scope, env, ctx, done)
    end)
  end

  # evaluates a piece without awaits; a throw goes to the nearest handler, outside the `try`
  # so the rest of the function does not run inside it
  defp sync_expr(node, env, ctx, k) do
    result =
      try do
        {:ok, Interp.ev(node, env)}
      catch
        {:js_error, e} -> {:throw, e}
      end

    case result do
      {:ok, v} -> k.(v)
      {:throw, e} -> ctx.throw.(e)
    end
  end

  defp await_value(v, ctx, k) do
    p =
      if Promise.promise?(v) do
        v
      else
        np = Promise.new()
        Promise.resolve(np, v)
        np
      end

    Promise.then(
      p,
      Interp.native("", fn _, args ->
        k.(Enum.at(args, 0, :undefined))
        :undefined
      end),
      Interp.native("", fn _, args ->
        ctx.throw.(Enum.at(args, 0, :undefined))
        :undefined
      end)
    )

    :suspended
  end

  # ── statements ─────────────────────────────────────────────

  defp clist([], _env, _ctx, k), do: k.(:ok)

  defp clist([s | rest], env, ctx, k),
    do: cexec(s, env, ctx, fn _ -> clist(rest, env, ctx, k) end)

  defp cexec(stmt, env, ctx, k, labels \\ []) do
    if has_await?(stmt),
      do: cs(stmt, env, ctx, k, labels),
      else: sync_stmt(stmt, env, ctx, k, labels)
  end

  # a statement without awaits, by the ordinary evaluator; its abrupt completions are routed
  defp sync_stmt(stmt, env, ctx, k, labels) do
    result =
      try do
        Interp.exec_stmt(stmt, env, labels)
        :ok
      catch
        {:js_error, e} -> {:throw, e}
        {:js_return, v} -> {:ret, v}
        {:js_break, l} -> {:brk, l}
        {:js_continue, l} -> {:cont, l}
      end

    abrupt(result, ctx, k)
  end

  defp abrupt(:ok, _ctx, k), do: k.(:ok)
  defp abrupt({:throw, e}, ctx, _k), do: ctx.throw.(e)
  defp abrupt({:ret, v}, ctx, _k), do: ctx.ret.(v)

  defp abrupt({:brk, l}, ctx, _k) do
    case ctx.brk do
      %{^l => target} -> target.(:ok)
      _ -> :ok
    end
  end

  defp abrupt({:cont, l}, ctx, _k) do
    case ctx.cont do
      %{^l => target} -> target.(:ok)
      _ -> :ok
    end
  end

  # run a piece of synchronous work (a binding, say), then carry on or take its throw
  defp guarded(fun, ctx, next) do
    result =
      try do
        fun.()
        :ok
      catch
        {:js_error, e} -> {:throw, e}
      end

    case result do
      :ok -> next.()
      {:throw, e} -> ctx.throw.(e)
    end
  end

  defp cs({:expr, e}, env, ctx, k, _labels) do
    cev(e, env, ctx, fn v ->
      Process.put(:js_last, v)
      k.(:ok)
    end)
  end

  defp cs({:var, kind, decls}, env, ctx, k, _labels), do: cdecls(decls, kind, env, ctx, k)

  defp cs({:return, e}, env, ctx, _k, _labels), do: cev(e, env, ctx, ctx.ret)
  defp cs({:throw, e}, env, ctx, _k, _labels), do: cev(e, env, ctx, ctx.throw)

  defp cs({:if, c, a, b}, env, ctx, k, _labels) do
    cev(c, env, ctx, fn v ->
      cond do
        Interp.truthy(v) -> cexec(a, env, ctx, k)
        b != nil -> cexec(b, env, ctx, k)
        true -> k.(:ok)
      end
    end)
  end

  defp cs({:block, stmts}, env, ctx, k, _labels) do
    scope = Interp.new_scope(env)

    guarded(fn -> Interp.hoist_functions(stmts, scope) end, ctx, fn ->
      clist(stmts, scope, ctx, k)
    end)
  end

  defp cs({:labeled, l, s}, env, ctx, k, labels) do
    ctx = %{ctx | brk: Map.put(ctx.brk, l, k)}
    cexec(s, env, ctx, k, [l | labels])
  end

  defp cs({:while, c, body}, env, ctx, k, labels), do: while_loop(c, body, env, ctx, k, labels)

  defp cs({:dowhile, body, c}, env, ctx, k, labels) do
    run_body(body, env, ctx, k, labels, fn _ -> while_loop(c, body, env, ctx, k, labels) end)
  end

  defp cs({:for, init, test, update, body}, env, ctx, k, labels) do
    loop_env = Interp.new_scope(env)
    per_iteration? = match?({:var, :let, _}, init)

    start = fn _ ->
      first = if per_iteration?, do: Interp.copy_scope(loop_env, env), else: loop_env
      for_iter({test, update, body, env, per_iteration?}, first, ctx, k, labels)
    end

    case init do
      {:var, _, _} = d -> cexec(d, loop_env, ctx, start)
      {:expr, e} -> cev(e, loop_env, ctx, start)
      nil -> start.(:ok)
    end
  end

  defp cs({kind, decl, pat, obj, body}, env, ctx, k, labels) when kind in [:forin, :forof] do
    cev(obj, env, ctx, fn target ->
      items =
        try do
          {:ok,
           case kind do
             :forin -> {:list, if(Interp.nullish?(target), do: [], else: Interp.own_keys(target))}
             :forof -> Interp.iter_source(target)
           end}
        catch
          {:js_error, e} -> {:throw, e}
        end

      mode = if decl == nil, do: :assign, else: decl

      case items do
        {:ok, {:list, list}} ->
          foreach(list, {pat, mode, body, env}, ctx, k, labels)

        {:ok, {:proto, it, next}} ->
          proto_foreach(it, next, {pat, mode, body, env}, ctx, k, labels)

        {:throw, e} ->
          ctx.throw.(e)
      end
    end)
  end

  defp cs({:forawait, decl, pat, obj, body}, env, ctx, k, labels) do
    cev(obj, env, ctx, fn target ->
      attempt(fn -> async_iterator(target) end, ctx, fn {it, next, sync?} ->
        mode = if decl == nil, do: :assign, else: decl
        afor(it, next, sync?, {pat, mode, body, env}, ctx, k, labels)
      end)
    end)
  end

  defp cs({:switch, disc, cases}, env, ctx, k, _labels) do
    cev(disc, env, ctx, fn v ->
      scope = Interp.new_scope(env)
      all = Enum.flat_map(cases, fn {_, body} -> body end)

      guarded(fn -> Interp.hoist_functions(all, scope) end, ctx, fn ->
        find_case(cases, 0, v, scope, ctx, fn start ->
          ctx = %{ctx | brk: Map.put(ctx.brk, nil, k)}

          if start do
            body = cases |> Enum.drop(start) |> Enum.flat_map(fn {_, b} -> b end)
            clist(body, scope, ctx, k)
          else
            k.(:ok)
          end
        end)
      end)
    end)
  end

  defp cs({:try, block, param, handler, finalizer}, env, ctx, k, _labels) do
    # a `finally` runs before any way out of the statement
    leave = fn after_ ->
      if finalizer, do: cexec(finalizer, env, ctx, fn _ -> after_.() end), else: after_.()
    end

    wrapped = %{
      ctx
      | ret: fn v -> leave.(fn -> ctx.ret.(v) end) end,
        throw: fn e -> leave.(fn -> ctx.throw.(e) end) end,
        brk: Map.new(ctx.brk, fn {l, f} -> {l, fn x -> leave.(fn -> f.(x) end) end} end),
        cont: Map.new(ctx.cont, fn {l, f} -> {l, fn x -> leave.(fn -> f.(x) end) end} end)
    }

    done = fn _ -> leave.(fn -> k.(:ok) end) end

    in_try =
      if handler do
        %{
          wrapped
          | throw: fn e ->
              scope = Interp.new_scope(env)

              guarded(
                fn -> if param, do: Interp.bind_pattern(param, e, scope, :let) end,
                wrapped,
                fn -> cexec(handler, scope, wrapped, done) end
              )
            end
        }
      else
        wrapped
      end

    cexec(block, env, in_try, done)
  end

  # `using` / `await using`: the rest of the list runs under a context that disposes the
  # resource before any way out
  defp cs({:using, kind, name, init, rest}, env, ctx, k, _labels) do
    cev_named(init, name, env, ctx, fn v ->
      attempt(
        fn ->
          res = Interp.using_resource(kind, v)
          Interp.declare(env, name, v, true)
          res
        end,
        ctx,
        fn res ->
          leave = fn after_, thrown ->
            dispose_cps(res, ctx, fn
              :ok ->
                after_.()

              {:error, e2} ->
                case thrown do
                  {:error, e} -> ctx.throw.(Interp.suppressed_error(e2, e))
                  :none -> ctx.throw.(e2)
                end
            end)
          end

          wrapped = %{
            ctx
            | ret: fn v -> leave.(fn -> ctx.ret.(v) end, :none) end,
              throw: fn e -> leave.(fn -> ctx.throw.(e) end, {:error, e}) end,
              brk:
                Map.new(ctx.brk, fn {l, f} -> {l, fn x -> leave.(fn -> f.(x) end, :none) end} end),
              cont:
                Map.new(ctx.cont, fn {l, f} -> {l, fn x -> leave.(fn -> f.(x) end, :none) end} end)
          }

          clist(rest, env, wrapped, fn _ -> leave.(fn -> k.(:ok) end, :none) end)
        end
      )
    end)
  end

  defp cs(stmt, env, ctx, k, labels), do: sync_stmt(stmt, env, ctx, k, labels)

  # the initializer, named after the binding when it is an anonymous function
  defp cev_named(init, name, env, ctx, k) do
    if has_await?(init) do
      cev(init, env, ctx, k)
    else
      attempt(fn -> Interp.ev_named(init, env, {:id, name}) end, ctx, k)
    end
  end

  # disposes one resource; `k` gets :ok or {:error, e}
  defp dispose_cps({:none, :sync}, _ctx, k), do: k.(:ok)
  defp dispose_cps({:none, :async}, ctx, k), do: await_result(:undefined, ctx, k)

  defp dispose_cps({:res, v, m, mode}, ctx, k) do
    result =
      try do
        {:ok, Interp.call(m, v, [])}
      catch
        {:js_error, e} -> {:error, e}
      end

    case {result, mode} do
      {{:error, e}, _} -> k.({:error, e})
      {{:ok, _}, :sync} -> k.(:ok)
      {{:ok, r}, :async} -> await_result(r, ctx, k)
      {{:ok, _}, :async_from_sync} -> await_result(:undefined, ctx, k)
    end
  end

  defp await_result(v, ctx, k),
    do: await_value(v, %{ctx | throw: fn e -> k.({:error, e}) end}, fn _ -> k.(:ok) end)

  # declarations, one at a time
  defp cdecls([], _kind, _env, _ctx, k), do: k.(:ok)

  defp cdecls([{pat, init} | rest], kind, env, ctx, k) do
    next = fn -> cdecls(rest, kind, env, ctx, k) end

    cond do
      init != nil ->
        cev(init, env, ctx, fn v ->
          guarded(fn -> Interp.bind_pattern(pat, v, env, kind) end, ctx, next)
        end)

      kind == :var ->
        next.()

      true ->
        guarded(fn -> Interp.bind_pattern(pat, :undefined, env, kind) end, ctx, next)
    end
  end

  # ── loops ──────────────────────────────────────────────────

  # the context for a loop body: where `break` and `continue` (bare or with this loop's labels) go
  defp loop_ctx(ctx, labels, on_break, on_continue) do
    brk = Enum.reduce([nil | labels], ctx.brk, &Map.put(&2, &1, on_break))
    cont = Enum.reduce([nil | labels], ctx.cont, &Map.put(&2, &1, on_continue))
    %{ctx | brk: brk, cont: cont}
  end

  defp run_body(body, env, ctx, k, labels, next) do
    cexec(body, env, loop_ctx(ctx, labels, k, next), next)
  end

  defp while_loop(c, body, env, ctx, k, labels) do
    cev(c, env, ctx, fn v ->
      if Interp.truthy(v) do
        Interp.tick()

        run_body(body, env, ctx, k, labels, fn _ ->
          while_loop(c, body, env, ctx, k, labels)
        end)
      else
        k.(:ok)
      end
    end)
  end

  defp for_iter({test, update, body, env, copy?} = spec, iter_env, ctx, k, labels) do
    Interp.tick()

    run = fn ->
      advance = fn _ ->
        next_env = if copy?, do: Interp.copy_scope(iter_env, env), else: iter_env

        if update do
          cev(update, next_env, ctx, fn _ -> for_iter(spec, next_env, ctx, k, labels) end)
        else
          for_iter(spec, next_env, ctx, k, labels)
        end
      end

      run_body(body, iter_env, ctx, k, labels, advance)
    end

    if test == nil do
      run.()
    else
      cev(test, iter_env, ctx, fn v -> if Interp.truthy(v), do: run.(), else: k.(:ok) end)
    end
  end

  defp foreach([], _spec, _ctx, k, _labels), do: k.(:ok)

  defp foreach([item | rest], {pat, mode, body, env} = spec, ctx, k, labels) do
    Interp.tick()
    iter_env = Interp.new_scope(env)

    guarded(fn -> Interp.bind_pattern(pat, item, iter_env, mode) end, ctx, fn ->
      run_body(body, iter_env, ctx, k, labels, fn _ -> foreach(rest, spec, ctx, k, labels) end)
    end)
  end

  # `for await`: each step's result is awaited, and so is each value of a sync iterator
  defp afor(it, next, sync?, spec, ctx, k, labels) do
    attempt(fn -> Interp.call(next, it, []) end, ctx, fn r ->
      await_value(r, ctx, fn r2 ->
        attempt(
          fn ->
            unless match?({:obj, _}, r2),
              do: Interp.throw_error("TypeError", "Iterator result is not an object")

            {Interp.truthy(Interp.get(r2, "done")), Interp.get(r2, "value")}
          end,
          ctx,
          fn
            {true, _} ->
              k.(:ok)

            {false, v} ->
              if sync?,
                do: await_value(v, ctx, &afor_body(&1, it, next, sync?, spec, ctx, k, labels)),
                else: afor_body(v, it, next, sync?, spec, ctx, k, labels)
          end
        )
      end)
    end)
  end

  defp afor_body(item, it, next, sync?, {pat, mode, body, env} = spec, ctx, k, labels) do
    Interp.tick()
    iter_env = Interp.new_scope(env)

    # leaving the loop early calls the iterator's `return` and waits for it
    closing = fn after_ ->
      attempt(
        fn ->
          case Interp.get(it, "return") do
            f when is_tuple(f) ->
              if Interp.function?(f), do: Interp.call(f, it, []), else: :undefined

            _ ->
              :undefined
          end
        end,
        ctx,
        fn r -> await_value(r, ctx, fn _ -> after_.() end) end
      )
    end

    inner = %{
      ctx
      | ret: fn v -> closing.(fn -> ctx.ret.(v) end) end,
        throw: fn e ->
          try do
            Interp.call(Interp.get(it, "return"), it, [])
          catch
            {:js_error, _} -> :ok
          end

          ctx.throw.(e)
        end,
        brk: Map.new(ctx.brk, fn {l, f} -> {l, fn x -> closing.(fn -> f.(x) end) end} end),
        cont: Map.new(ctx.cont, fn {l, f} -> {l, fn x -> closing.(fn -> f.(x) end) end} end)
    }

    on_break = fn x -> closing.(fn -> k.(x) end) end

    guarded(fn -> Interp.bind_pattern(pat, item, iter_env, mode) end, inner, fn ->
      run_body(body, iter_env, inner, on_break, labels, fn _ ->
        afor(it, next, sync?, spec, ctx, k, labels)
      end)
    end)
  end

  # `for of` over an iterator object, one value at a time; leaving the loop early (break,
  # return, an outer label, a throw) calls the iterator's `return`
  defp proto_foreach(it, next, {pat, mode, body, env} = spec, ctx, k, labels) do
    step =
      try do
        {:ok, Interp.iter_step(it, next)}
      catch
        {:js_error, e} -> {:throw, e}
      end

    case step do
      {:throw, e} ->
        ctx.throw.(e)

      {:ok, :done} ->
        k.(:ok)

      {:ok, {:ok, item}} ->
        Interp.tick()
        iter_env = Interp.new_scope(env)

        closing = fn after_ ->
          guarded(fn -> Interp.iter_close(it, false) end, ctx, after_)
        end

        inner = %{
          ctx
          | ret: fn v -> closing.(fn -> ctx.ret.(v) end) end,
            throw: fn e ->
              try do
                Interp.iter_close(it, true)
              catch
                {:js_error, _} -> :ok
              end

              ctx.throw.(e)
            end,
            brk: Map.new(ctx.brk, fn {l, f} -> {l, fn x -> closing.(fn -> f.(x) end) end} end),
            cont: Map.new(ctx.cont, fn {l, f} -> {l, fn x -> closing.(fn -> f.(x) end) end} end)
        }

        on_break = fn x -> closing.(fn -> k.(x) end) end

        guarded(fn -> Interp.bind_pattern(pat, item, iter_env, mode) end, inner, fn ->
          run_body(body, iter_env, inner, on_break, labels, fn _ ->
            proto_foreach(it, next, spec, ctx, k, labels)
          end)
        end)
    end
  end

  # the first `case` whose test equals the value, else `default`
  defp find_case(cases, i, v, scope, ctx, found) do
    case Enum.at(cases, i) do
      nil ->
        found.(Enum.find_index(cases, fn {t, _} -> t == :default end))

      {:default, _} ->
        find_case(cases, i + 1, v, scope, ctx, found)

      {test, _} ->
        cev(test, scope, ctx, fn tv ->
          if Interp.strict_eq(v, tv),
            do: found.(i),
            else: find_case(cases, i + 1, v, scope, ctx, found)
        end)
    end
  end
end
