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

  ## Frame mode (step 2e)

  A function that the resolver rewrote (level 4) runs its body on a frame. The frame is built
  by `Browser.JS.Interp.enter_frame/4`, and the context `ctx` then has the key `frame`. Every
  context that is made from it keeps the key. In frame mode these rules apply:

  - The resolver marks each statement that awaits with `{:aw, stmt}`. `cexec` sends a marked
    statement to the CPS clauses and every other statement to the sync evaluator, with no
    walk of the statement.
  - An expression that awaits is lifted into a template with holes `{:cps_leaf, i}`. The
    awaited values fill the holes as `{:val, v}`, and the template runs in the scope where
    the resolver resolved it. So no scope comes between the frame and the code, and every
    hop count stays exact. The optional chain puts its value into the tree in the same way.
  - Blocks, loops, for-each items, switches and catch clauses enter the scope of the
    resolver (`Browser.JS.Interp.cps_enter/2`). A framed scope gets a block frame, which the
    collector takes later, as it takes the map scopes of the old path.
  - The frame lives while a continuation of the body can run: a reaction of an awaited
    promise, a microtask or the `resume` of a generator holds the frame id in its
    environment. When the body has ended, `Browser.JS.Interp.frame_done/2` runs once. It
    erases the frame when no closure can hold it.
  """

  alias Browser.JS.{Interp, Promise}
  alias Browser.JS.Resolve.Info

  @max_depth 1000

  # Check mode (`JS_RESOLVE_CHECK=1`, see `config/config.exs`): the CPS evaluator asserts
  # the invariants of frame mode (step 2e). The flag is read at compile time, so without it
  # no check costs anything.
  @check Application.compile_env(:browser, :js_resolve_check, false)

  # The forms that read a name. A call whose callee is one of these lifts only its
  # arguments, so the callee is read after the awaits, as `{:id}` is at `:off`.
  @name [:id, :slot, :gref, :mref, :aslot]

  # The forms that a compound assignment can write. Their value is read before the awaits
  # of the right side, and the write keeps its own form (see `read_form/1`).
  @target @name ++ [:cslot, :fname, :mslot]

  @compound ~w(+= -= *= /= %= **= <<= >>= >>>= &= |= ^=)

  # A generator or async body makes no tail calls: a `return f()` in it must still see the
  # body's `try` and `finally`. The body starts and resumes inside some caller's frame, which
  # may be a strict function's with the tail flag on, so every entry into a body runs with the
  # flag off (an ordinary call inside the body sets and restores the flag for itself).
  defp no_tail(fun) do
    tail = Process.put(:js_tail, false)

    try do
      fun.()
    after
      Process.put(:js_tail, tail)
    end
  end

  @doc """
  Calls an async closure: starts its body and returns its promise. `id` is the id of the
  function object, which the frame of a rewritten closure needs for its hidden slots.
  """
  def call_closure(id, c, this, args) do
    p = Promise.new()
    depth = Process.get(:js_depth)

    if depth >= @max_depth,
      do: Interp.throw_error("RangeError", "Maximum call stack size exceeded")

    Process.put(:js_depth, depth + 1)

    try do
      {env, frame, fns} = body_env(id, c, this, args)

      ctx =
        if frame == nil do
          %{
            ret: fn v -> Promise.resolve(p, v) end,
            throw: fn e -> Promise.reject(p, e) end,
            brk: %{},
            cont: %{}
          }
        else
          # A rewritten body runs on a frame. The promise settles first, and then the frame
          # is done, because a settle runs no code of the body.
          %{
            ret: fn v -> settled(Promise.resolve(p, v), frame, fns) end,
            throw: fn e -> settled(Promise.reject(p, e), frame, fns) end,
            brk: %{},
            cont: %{},
            frame: frame
          }
        end

      no_tail(fn -> run_body(c, env, ctx, :undefined) end)
    catch
      {:js_error, e} -> Promise.reject(p, e)
    after
      Process.put(:js_depth, depth)
    end

    p
  end

  # Gives back the value of the settle after the frame of the body is done, so that the
  # caller of `ret` or `throw` gets the same value as on the old path.
  defp settled(result, frame, fns) do
    Interp.frame_done(frame, fns)
    result
  end

  # Starts a body: an arrow with an expression body returns its value, any other body falls
  # off its end with `ending`.
  defp run_body(%{mode: :arrow_expr} = c, env, ctx, _ending), do: cev(c.body, env, ctx, ctx.ret)
  defp run_body(c, env, ctx, ending), do: clist(c.body, env, ctx, fn _ -> ctx.ret.(ending) end)

  # The frame of a rewritten closure, or the call scope of the old path, and the frame
  # fields of a generator record (`nil` on the old path).
  defp body_env(id, %{info: %Info{rewritten: true}} = c, this, args) do
    {frame, fns} = Interp.enter_frame(id, c, this, args)
    if @check, do: check_marks(c)
    {frame, frame, fns}
  end

  defp body_env(_id, c, this, args), do: {Interp.call_scope(c, this, args), nil, nil}

  # Adds the frame to a context in frame mode. An old-path context never has the key.
  defp with_frame(ctx, nil), do: ctx
  defp with_frame(ctx, frame), do: Map.put(ctx, :frame, frame)

  # Check mode: `info.has_await` is true when the body has a statement marked `{:aw}`.
  defp check_marks(%{info: info, body: body}) do
    if not info.has_await and is_list(body) and Enum.any?(body, &aw_mark?/1),
      do: Interp.check_cps("#{inspect(info.name)} has {:aw} but no has_await")
  end

  defp aw_mark?({:aw, _}), do: true
  defp aw_mark?({:fn, _, _, _, _, _}), do: false
  defp aw_mark?(t) when is_tuple(t), do: t |> Tuple.to_list() |> Enum.any?(&aw_mark?/1)
  defp aw_mark?(l) when is_list(l), do: Enum.any?(l, &aw_mark?/1)
  defp aw_mark?(_), do: false

  @doc "Whether a module body awaits at its top level (not inside a function)."
  def has_tla?(stmts), do: Enum.any?(stmts, &has_await?/1)

  @doc "Runs a module body whose top level awaits: starts it and returns its promise."
  def run_module(stmts, scope) do
    p = Promise.new()

    ctx = %{
      ret: fn _ -> Promise.resolve(p, :undefined) end,
      throw: fn e -> Promise.reject(p, e) end,
      brk: %{},
      cont: %{}
    }

    try do
      no_tail(fn -> clist(stmts, scope, ctx, fn _ -> Promise.resolve(p, :undefined) end) end)
    catch
      {:js_error, e} -> Promise.reject(p, e)
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
  def call_generator({:obj, fid} = f, c, this, args) do
    {scope, frame, fns} = body_env(fid, c, this, args)

    proto =
      case Interp.get(f, "prototype") do
        {:obj, _} = p -> p
        _ -> Interp.proto(:generator)
      end

    {:obj, gid} = gen = Interp.new_object([], proto)

    ctx =
      with_frame(
        %{
          ret: fn v -> finish(gid, {:return, v}) end,
          throw: fn e -> finish(gid, {:throw, e}) end,
          yield: fn v, resume -> suspend(gid, v, resume) end,
          brk: %{},
          cont: %{}
        },
        frame
      )

    start = fn
      {:next, _} -> run_body(c, scope, ctx, :undefined)
      {:throw, e} -> ctx.throw.(e)
      {:return, v} -> ctx.ret.(v)
    end

    set_gen(gid, %{state: :start, resume: start, frame: frame, fns: fns})
    gen
  end

  defp set_gen(gid, gen), do: Interp.store(gid, Map.put(Interp.deref(gid), :gen, gen))
  defp get_gen(gid), do: Map.get(Interp.deref(gid), :gen)

  # The record keeps `frame` and `fns` across each change of state, so that the frame is
  # released exactly once, when the generator is done.
  defp update_gen(gid, changes), do: set_gen(gid, Map.merge(get_gen(gid), changes))

  defp finish(gid, out) do
    set_gen(gid, %{release(get_gen(gid)) | state: :done, resume: nil})
    Process.put(:js_gen_out, out)
    :done
  end

  defp suspend(gid, v, resume) do
    update_gen(gid, %{state: :suspended, resume: resume})
    Process.put(:js_gen_out, {:yield, v})
    :suspended
  end

  # The body of a generator or an async generator has ended, so no continuation of it can
  # run again: its frame is handed to `Interp.frame_done/2`. The record then has no frame,
  # so a second call does nothing. A record of the old path has no frame at all.
  defp release(%{frame: nil} = rec), do: rec

  defp release(%{frame: frame, fns: fns} = rec) do
    Interp.frame_done(frame, fns)
    %{rec | frame: nil}
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
        if @check, do: Interp.check_resume(gen.frame)

        try do
          no_tail(fn -> gen.resume.(msg) end)
        catch
          {:js_error, e} -> finish(gid, {:throw, e})
        end

        case Process.delete(:js_gen_out) do
          {:yield, {:raw, r}} -> r
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
  def call_async_generator({:obj, fid} = f, c, this, args) do
    {scope, frame, fns} = body_env(fid, c, this, args)

    proto =
      case Interp.get(f, "prototype") do
        {:obj, _} = p -> p
        _ -> Interp.proto(:async_generator)
      end

    {:obj, gid} = gen = Interp.new_object([], proto)

    # The `base` context carries the frame too, because `ret` awaits its value with `base`
    # as the context.
    base =
      with_frame(
        %{
          throw: fn e -> ag_finish(gid, {:throw, e}) end,
          yield: fn v, resume -> ag_yield(gid, v, resume, frame) end,
          async_gen: true,
          brk: %{},
          cont: %{}
        },
        frame
      )

    ctx =
      Map.put(base, :ret, fn
        :ag_bare -> ag_finish(gid, {:return, :undefined})
        {:ag_done, v} -> ag_finish(gid, {:return, v})
        v -> await_value(v, base, fn v2 -> ag_finish(gid, {:return, v2}) end)
      end)

    start = fn
      {:next, _} -> run_body(c, scope, ctx, :ag_bare)
      {:throw, e} -> ctx.throw.(e)
      {:return, v} -> ctx.ret.(v)
    end

    set_agen(gid, %{
      state: :start,
      resume: start,
      queue: [],
      running: false,
      cur: nil,
      frame: frame,
      fns: fns
    })

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

        # A request at the start runs no body code, so the frame is released at once.
        {state, {:throw, e}} when state == :start ->
          set_agen(gid, %{release(g) | queue: rest, state: :done})
          Promise.reject(p, e)
          ag_drain(gid)

        {state, {:return, v}} when state in [:done, :start] ->
          set_agen(gid, %{release(g) | queue: rest, state: :done, running: true})

          await_value(v, %{throw: fn e -> ag_settle(gid, p, {:throw, e}) end}, fn v2 ->
            ag_settle(gid, p, {:return, v2})
          end)

        _ ->
          update_agen(gid, %{running: true, cur: p})
          if @check, do: Interp.check_resume(g.frame)

          try do
            no_tail(fn -> g.resume.(msg) end)
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
    set_agen(gid, %{release(g) | state: :done, resume: nil, cur: nil})
    ag_settle(gid, g.cur, out)
    :done
  end

  defp ag_yield(gid, {:ag_raw, v}, resume, _frame) do
    ag_suspend(gid, v, resume)
    :suspended
  end

  # The small context carries the frame, so that check mode tests the frame when the await
  # resumes.
  defp ag_yield(gid, v, resume, frame) do
    await_value(v, with_frame(%{throw: fn e -> resume.({:throw, e}) end}, frame), fn v2 ->
      ag_suspend(gid, v2, resume)
    end)

    :suspended
  end

  defp ag_suspend(gid, v, resume) do
    g = agen(gid)
    update_agen(gid, %{state: :suspended, resume: resume, running: false, cur: nil})
    Promise.resolve(g.cur, iter_result(v, false))
    ag_drain(gid)
  end

  @doc "`AsyncGenerator.prototype`."
  def install_async_generators do
    ai = Interp.new_object()

    Interp.put_hidden(
      ai,
      {:symbol, :asyncIterator, "Symbol.asyncIterator"},
      Interp.native("[Symbol.asyncIterator]", fn this, _ -> this end)
    )

    async_dispose =
      Interp.native("[Symbol.asyncDispose]", fn this, _ ->
        result = Promise.new()

        try do
          case Interp.get(this, "return") do
            f when f in [:undefined, :null] ->
              Promise.resolve(result, :undefined)

            f ->
              unless Interp.function?(f),
                do: Interp.throw_error("TypeError", "return is not a function")

              wrapper = Promise.new()
              Promise.resolve(wrapper, Interp.call(f, this, []))

              Promise.then(
                wrapper,
                Interp.native("", fn _, _ ->
                  Promise.resolve(result, :undefined)
                  :undefined
                end),
                Interp.native("", fn _, args ->
                  Promise.reject(result, Enum.at(args, 0, :undefined))
                  :undefined
                end)
              )
          end
        catch
          {:js_error, e} -> Promise.reject(result, e)
        end

        result
      end)

    Interp.set_arity(async_dispose, 0)
    Interp.put_hidden(ai, {:symbol, :asyncDispose, "Symbol.asyncDispose"}, async_dispose)

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

      method not in [:undefined, :null] ->
        Interp.throw_error("TypeError", "Symbol.asyncIterator is not a function")

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
  defp adelegate(it, next, msg, ctx, k, sync?) do
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

              {false, v} when sync? ->
                # a sync iterator's values are awaited first; a rejection ends the `yield*`
                closing = %{
                  ctx
                  | throw: fn e ->
                      close_sync(it)
                      ctx.throw.(e)
                    end
                }

                await_value(v, closing, fn v2 ->
                  ctx.yield.({:ag_raw, v2}, resume_delegate(it, next, ctx, k, sync?))
                end)

              {false, v} ->
                # the values of an async iterator are passed on as they are
                ctx.yield.({:ag_raw, v}, resume_delegate(it, next, ctx, k, sync?))
            end
          )
        end)
    end
  end

  # the value of a `return()` that resumes a `yield*` is awaited before it reaches the inner
  # iterator; a rejection goes in as a throw
  defp resume_delegate(it, next, ctx, k, sync?) do
    fn
      {:return, v} ->
        await_value(
          v,
          %{ctx | throw: fn e -> adelegate(it, next, {:throw, e}, ctx, k, sync?) end},
          fn v2 ->
            adelegate(it, next, {:return, v2}, ctx, k, sync?)
          end
        )

      m ->
        adelegate(it, next, m, ctx, k, sync?)
    end
  end

  # closes a sync iterator whose value promise was rejected
  defp close_sync(it) do
    case Interp.get(it, "return") do
      r when is_tuple(r) -> if Interp.function?(r), do: Interp.call(r, it, [])
      _ -> :ok
    end
  catch
    {:js_error, _} -> :ok
  end

  defp adelegate_call(it, next, {:next, x}), do: {:result, Interp.call(next, it, [x])}

  defp adelegate_call(it, _next, {:throw, e}) do
    case Interp.get(it, "throw") do
      f when is_tuple(f) ->
        if Interp.function?(f),
          do: {:result, Interp.call(f, it, [e])},
          else: Interp.throw_error("TypeError", "The iterator does not provide a 'throw' method")

      _ ->
        # no `throw` method: the iterator is closed before the TypeError
        case Interp.get(it, "return") do
          r when is_tuple(r) -> if Interp.function?(r), do: Interp.call(r, it, [])
          _ -> :ok
        end

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
      # the inner result object is handed on as it is
      {:yield, r} ->
        ctx.yield.({:raw, r}, fn m -> delegate(it, next, m, ctx, k) end)

      {:done, v} ->
        k.(v)

      {:return, v} ->
        ctx.ret.(v)
    end)
  end

  defp delegate_step(it, next, {:next, x}) do
    check_sync_result(Interp.call(next, it, [x]), :done)
  end

  defp delegate_step(it, _next, {:throw, e}) do
    case Interp.get(it, "throw") do
      f when is_tuple(f) ->
        if Interp.function?(f) do
          check_sync_result(Interp.call(f, it, [e]), :done)
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
          do: check_sync_result(Interp.call(f, it, [v]), :return),
          else: {:return, v}

      _ ->
        {:return, v}
    end
  end

  # a result of an inner iterator of a `yield*` in a generator: yielded whole (its `value` is
  # only read once it says it is done)
  defp check_sync_result(r, on_done) do
    unless match?({:obj, _}, r),
      do: Interp.throw_error("TypeError", "Iterator result is not an object")

    if Interp.truthy(Interp.get(r, "done")),
      do: {on_done, Interp.get(r, "value")},
      else: {:yield, r}
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
  # A `for await` in a rewritten body carries its scope as a sixth element. Its loop awaits
  # even when nothing inside it does, so the shape alone gives the answer.
  defp has_await?({:forawait, _, _, _, _, _}), do: true
  defp has_await?({:using, :await_using, _, _, _}), do: true
  defp has_await?({:gen, _}), do: false
  defp has_await?({:fn, _, _, _, _, _}), do: false
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
        {:next, x} ->
          k.(x)

        {:throw, err} ->
          ctx.throw.(err)

        # in an async generator the value of a `return()` is awaited first, and a rejection
        # is thrown at the `yield`
        {:return, r} when is_map_key(ctx, :async_gen) ->
          await_value(r, ctx, fn v -> ctx.ret.({:ag_done, v}) end)

        {:return, r} ->
          ctx.ret.(r)
      end)
    end)
  end

  defp cev_await({:yield, e, true}, env, %{async_gen: true} = ctx, k) do
    cev(e, env, ctx, fn iterable ->
      attempt(fn -> async_iterator(iterable) end, ctx, fn {it, next, sync?} ->
        adelegate(it, next, {:next, :undefined}, ctx, k, sync?)
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

  # an optional chain with an await in it: the first `?.` is settled before anything after it runs
  defp cev_await({:chain, e}, env, ctx, k) do
    case opt_node(e) do
      nil ->
        cev(e, env, ctx, k)

      {:member, base, key, true} = node ->
        cev(base, env, ctx, fn v ->
          cond do
            Interp.nullish?(v) ->
              k.(:undefined)

            # In frame mode the value goes into the tree, so the rest of the chain runs in
            # `env` and its hop counts stay exact.
            is_map_key(ctx, :frame) ->
              plain = {:member, {:val, v}, key, false}
              cev_await({:chain, replace_node(e, node, plain)}, env, ctx, k)

            true ->
              if @check, do: Interp.check_old_path(env, "a CPS optional chain")
              scope = Interp.new_scope(env)
              name = "\0o#{System.unique_integer([:positive])}"
              Interp.declare(scope, name, v)
              plain = {:member, {:id, name}, key, false}
              cev_await({:chain, replace_node(e, node, plain)}, scope, ctx, k)
          end
        end)

      # `f?.(...)` with an await after it is left to the plain evaluator
      _ ->
        sync_await_expr({:chain, e}, env, ctx, k)
    end
  end

  defp cev_await({:destructure, pat, right}, env, ctx, k) do
    cev(right, env, ctx, fn v -> cbind(pat, v, :assign, env, ctx, fn -> k.(v) end) end)
  end

  defp cev_await({:cond, c, a, b}, env, ctx, k) do
    cev(c, env, ctx, fn cv ->
      if Interp.truthy(cv), do: cev(a, env, ctx, k), else: cev(b, env, ctx, k)
    end)
  end

  # In a rewritten body the values of the holes are collected in order and filled into the
  # template, which then runs in `env`, the scope where the resolver resolved it.
  defp cev_await(node, env, %{frame: _} = ctx, k) do
    {template, leaves} = lift(node, [], :frame)

    eval_vals(Enum.reverse(leaves), [], env, ctx, fn vals ->
      filled = fill(template, vals)
      if @check and has_hole?(filled), do: Interp.check_cps("a hole is left after fill")
      sync_expr(filled, env, ctx, k)
    end)
  end

  defp cev_await(node, env, ctx, k) do
    {template, leaves} = lift(node, [], :map)
    if @check, do: Interp.check_old_path(env, "a CPS leaf scope")
    scope = Interp.new_scope(env)

    eval_leaves(Enum.reverse(leaves), 0, scope, env, ctx, fn ->
      sync_expr(template, scope, ctx, k)
    end)
  end

  # The sync fallback of `f?.(await x)`: `Interp.ev/2` waits for the promise with
  # `Promise.await/1`, as at `:off`. In check mode a process key allows this one sync await
  # in a frame (check item C3).
  if @check do
    defp sync_await_expr(node, env, ctx, k) do
      old = Process.put(:js_cps_sync_await, true)

      result =
        try do
          {:ok, Interp.ev(node, env)}
        catch
          {:js_error, e} -> {:throw, e}
        after
          Process.put(:js_cps_sync_await, old)
        end

      case result do
        {:ok, v} -> k.(v)
        {:throw, e} -> ctx.throw.(e)
      end
    end
  else
    defp sync_await_expr(node, env, ctx, k), do: sync_expr(node, env, ctx, k)
  end

  # the innermost `?.` along the spine (object or callee) of a chain
  defp opt_node({:member, o, _, opt} = n), do: opt_node(o) || if(opt, do: n)
  defp opt_node({:call, c, _, opt} = n), do: opt_node(c) || if(opt, do: n)
  defp opt_node(_), do: nil

  defp replace_node(n, n, with), do: with

  defp replace_node({:member, o, k, opt}, n, with),
    do: {:member, replace_node(o, n, with), k, opt}

  defp replace_node({:call, c, a, opt}, n, with), do: {:call, replace_node(c, n, with), a, opt}
  defp replace_node(other, _n, _with), do: other

  # The awaits (and short-circuit expressions holding one) of an expression, in order. Each
  # one is replaced by a hole that the expression is later evaluated with. In `:map` mode
  # (the old path) the hole is a variable `"\0s<i>"`, which `eval_leaves/6` declares in a
  # leaf scope. In `:frame` mode (a rewritten body) the hole is `{:cps_leaf, i}`, which
  # `fill/2` replaces with the value, so that no scope comes between the frame and the code
  # and every hop count stays exact.
  defp lift(node, leaves, mode) do
    cond do
      leaf?(node) ->
        {hole(mode, length(leaves)), [node | leaves]}

      is_tuple(node) and elem(node, 0) in [:fn, :async] ->
        {node, leaves}

      is_tuple(node) and match?({:ok, _, _}, ordered(node)) ->
        {:ok, kids, rebuild} = ordered(node)

        last =
          kids
          |> Enum.map(&has_await?/1)
          |> Enum.reduce({0, -1}, fn
            true, {i, _} -> {i + 1, i}
            false, {i, l} -> {i + 1, l}
          end)
          |> elem(1)

        {kids, leaves} =
          kids
          |> Enum.with_index()
          |> Enum.map_reduce(leaves, fn {kid, i}, acc ->
            if i < last and not has_await?(kid) and not pure?(kid) do
              {hole(mode, length(acc)), [kid | acc]}
            else
              lift(kid, acc, mode)
            end
          end)

        {rebuild.(kids), leaves}

      is_tuple(node) ->
        {items, leaves} = lift_list(Tuple.to_list(node), leaves, mode)
        {List.to_tuple(items), leaves}

      is_list(node) ->
        lift_list(node, leaves, mode)

      true ->
        {node, leaves}
    end
  end

  defp hole(:map, i), do: {:id, "\0s#{i}"}
  defp hole(:frame, i), do: {:cps_leaf, i}

  # Replaces each hole `{:cps_leaf, i}` of a lifted template with `{:val, v}`, where `v` is
  # element `i` of `vals`. It stops at function nodes, as `lift/3` does, so no hole can be
  # inside one. It does not go into maps either, because the resolver's structs hold no
  # syntax that `lift/3` changed.
  defp fill({:cps_leaf, i}, vals), do: {:val, :erlang.element(i + 1, vals)}
  defp fill({:val, _} = n, _vals), do: n
  defp fill({tag, _} = n, _vals) when tag in [:gen, :async], do: n
  defp fill({:fn, _, _, _, _, _} = n, _vals), do: n

  defp fill(t, vals) when is_tuple(t),
    do: t |> Tuple.to_list() |> Enum.map(&fill(&1, vals)) |> List.to_tuple()

  defp fill(l, vals) when is_list(l), do: fill_list(l, vals)
  defp fill(x, _vals), do: x

  # A list of the syntax tree can be improper, so the tail of the last cell is filled like
  # any other term.
  defp fill_list([h | t], vals), do: [fill(h, vals) | fill_list(t, vals)]
  defp fill_list([], _vals), do: []
  defp fill_list(t, vals), do: fill(t, vals)

  # the operands of an expression in the order they are evaluated, and how to put them back: an
  # operand before one that awaits has to be evaluated first, so it is lifted like an await
  defp ordered({:binary, op, l, r}) when op != "in" or elem(l, 0) != :priv_ref,
    do: {:ok, [l, r], fn [l, r] -> {:binary, op, l, r} end}

  defp ordered({:seq, es}), do: {:ok, es, fn es -> {:seq, es} end}

  defp ordered({:array, elems}) do
    {:ok, for(e <- elems, e != :hole, do: unspread(e)),
     fn kids ->
       {rebuilt, []} =
         Enum.map_reduce(elems, kids, fn
           :hole, rest -> {:hole, rest}
           e, [k | rest] -> {respread(e, k), rest}
         end)

       {:array, rebuilt}
     end}
  end

  defp ordered({:new, callee, args}) do
    {:ok, [callee | Enum.map(args, &unspread/1)],
     fn [callee | kids] -> {:new, callee, respread_all(args, kids)} end}
  end

  defp ordered({:call, {:member, o, k, false}, args, false}) do
    {:ok, [o, k | Enum.map(args, &unspread/1)],
     fn [o, k | kids] -> {:call, {:member, o, k, false}, respread_all(args, kids), false} end}
  end

  defp ordered({:call, callee, args, false})
       when elem(callee, 0) not in [:super, :member, :super_member | @name] do
    {:ok, [callee | Enum.map(args, &unspread/1)],
     fn [callee | kids] -> {:call, callee, respread_all(args, kids), false} end}
  end

  # A callee that is a name is read after the awaits of the arguments. The spec reads it
  # first, but `:off` reads it later, and every level must give the same result.
  defp ordered({:call, callee, args, false}) when elem(callee, 0) in @name and args != [] do
    {:ok, Enum.map(args, &unspread/1),
     fn kids -> {:call, callee, respread_all(args, kids), false} end}
  end

  defp ordered({:member, o, k, false}),
    do: {:ok, [o, k], fn [o, k] -> {:member, o, k, false} end}

  defp ordered({kind, "=", {:member, o, k, mo}, value}) when kind in [:assign, :sassign],
    do: {:ok, [o, k, value], fn [o, k, v] -> {kind, "=", {:member, o, k, mo}, v} end}

  # A compound assignment to a name reads the name before the awaits of the right side. The
  # read uses `read_form/1`, and the write keeps the form of the target, so a `const` still
  # throws, a function name still ignores the write, and a mapped parameter still syncs.
  defp ordered({kind, op, t, value})
       when kind in [:assign, :sassign] and op in @compound and elem(t, 0) in @target do
    bin = binary_part(op, 0, byte_size(op) - 1)

    {:ok, [read_form(t), value], fn [t2, v] -> {kind, "=", t, {:binary, bin, t2, v}} end}
  end

  defp ordered({:tmpl, parts}) do
    {:ok, Enum.reject(parts, &is_binary/1),
     fn kids ->
       {rebuilt, []} =
         Enum.map_reduce(parts, kids, fn
           bin, rest when is_binary(bin) -> {bin, rest}
           _, [k | rest] -> {k, rest}
         end)

       {:tmpl, rebuilt}
     end}
  end

  defp ordered({:object, props}) do
    if Enum.all?(props, &object_prop_ordered?/1) do
      {:ok, Enum.flat_map(props, &prop_kids/1),
       fn kids ->
         {rebuilt, []} = Enum.map_reduce(props, kids, &prop_rebuild/2)
         {:object, rebuilt}
       end}
    else
      :none
    end
  end

  defp ordered(_), do: :none

  # The form that reads the value of a write target. A `const`, a function name and a
  # mapped parameter are read like a plain slot, because only their writes differ.
  defp read_form({k, d, i, name}) when k in [:cslot, :fname], do: {:slot, d, i, name}
  defp read_form({:mslot, d, i, name, _k}), do: {:slot, d, i, name}
  defp read_form(t), do: t

  defp object_prop_ordered?({:init, _, _}), do: true
  defp object_prop_ordered?({:spread, _}), do: true
  defp object_prop_ordered?({:proto, _}), do: true
  defp object_prop_ordered?(_), do: false

  defp prop_kids({:init, {:computed, ke}, v}), do: [ke, v]
  defp prop_kids({:init, _, v}), do: [v]
  defp prop_kids({:spread, e}), do: [e]
  defp prop_kids({:proto, v}), do: [v]

  defp prop_rebuild({:init, {:computed, _}, _}, [ke, v | rest]),
    do: {{:init, {:computed, ke}, v}, rest}

  defp prop_rebuild({:init, key, _}, [v | rest]), do: {{:init, key, v}, rest}
  defp prop_rebuild({:spread, _}, [e | rest]), do: {{:spread, e}, rest}
  defp prop_rebuild({:proto, _}, [v | rest]), do: {{:proto, v}, rest}

  defp unspread({:spread, e}), do: e
  defp unspread(e), do: e

  defp respread({:spread, _}, k), do: {:spread, k}
  defp respread(_, k), do: k

  defp respread_all(orig, kids), do: Enum.zip_with(orig, kids, &respread/2)

  defp pure?({tag, _}) when tag in [:lit, :num, :str, :bigint, :val, :gen, :async], do: true
  defp pure?({:fn, _, _, _, _, _}), do: true
  # a class expression keeps the name its property gives it
  defp pure?({:class, _, _, _, _}), do: true
  defp pure?(_), do: false

  defp lift_list(items, leaves, mode) do
    Enum.map_reduce(items, leaves, fn item, acc -> lift(item, acc, mode) end)
  end

  defp leaf?({:await, _}), do: true
  defp leaf?({:yield, _, _}), do: true
  defp leaf?({:logical, _, _, _} = n), do: has_await?(n)
  defp leaf?({:cond, _, _, _} = n), do: has_await?(n)
  defp leaf?({:chain, _} = n), do: has_await?(n)
  defp leaf?({:destructure, _, _} = n), do: has_await?(n)
  defp leaf?(_), do: false

  defp eval_leaves([], _i, _scope, _env, _ctx, done), do: done.()

  defp eval_leaves([leaf | rest], i, scope, env, ctx, done) do
    cev(leaf, env, ctx, fn v ->
      Interp.declare(scope, "\0s#{i}", v)
      eval_leaves(rest, i + 1, scope, env, ctx, done)
    end)
  end

  # The values of the holes of a template in frame mode, in source order, as a tuple.
  defp eval_vals([], acc, _env, _ctx, done), do: done.(List.to_tuple(:lists.reverse(acc)))

  defp eval_vals([leaf | rest], acc, env, ctx, done),
    do: cev(leaf, env, ctx, fn v -> eval_vals(rest, [v | acc], env, ctx, done) end)

  # Check mode looks for a hole that `fill/2` did not replace, because such a hole would run
  # as an unknown form.
  defp has_hole?({:cps_leaf, _}), do: true
  defp has_hole?({:fn, _, _, _, _, _}), do: false
  defp has_hole?(t) when is_tuple(t), do: t |> Tuple.to_list() |> Enum.any?(&has_hole?/1)
  defp has_hole?([h | t]), do: has_hole?(h) or has_hole?(t)
  defp has_hole?(_), do: false

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
    # PromiseResolve: a promise is reused only when its `constructor` is Promise itself; reading
    # that property may throw
    case (try do
            if Promise.promise?(v) and
                 Interp.get(v, "constructor") == Interp.proto(:promise_ctor),
               do: {:ok, v},
               else: {:wrap, v}
          catch
            {:js_error, e} -> {:error, e}
          end) do
      {:error, e} ->
        ctx.throw.(e)
        :suspended

      {:ok, p} ->
        await_promise(p, ctx, k)

      {:wrap, v} ->
        np = Promise.new()
        Promise.resolve(np, v)
        await_promise(np, ctx, k)
    end
  end

  defp await_promise(p, ctx, k) do
    Promise.then(
      p,
      Interp.native("", fn _, args ->
        if @check, do: Interp.check_resume(Map.get(ctx, :frame))
        no_tail(fn -> k.(Enum.at(args, 0, :undefined)) end)
        :undefined
      end),
      Interp.native("", fn _, args ->
        if @check, do: Interp.check_resume(Map.get(ctx, :frame))
        no_tail(fn -> ctx.throw.(Enum.at(args, 0, :undefined)) end)
        :undefined
      end)
    )

    :suspended
  end

  # ── statements ─────────────────────────────────────────────

  defp clist([], _env, _ctx, k), do: k.(:ok)

  defp clist([s | rest], env, ctx, k),
    do: cexec(s, env, ctx, fn _ -> clist(rest, env, ctx, k) end)

  defp cexec(stmt, env, ctx, k, labels \\ [])

  defp cexec({:return, nil}, _env, %{async_gen: true} = ctx, _k, _labels),
    do: ctx.ret.(:ag_bare)

  # In a rewritten body the resolver marks each statement that awaits with `{:aw}`, so no
  # walk is needed: a marked statement goes to `cs/5`, every other one to `sync_stmt/5`.
  defp cexec({:aw, stmt}, env, ctx, k, labels) do
    if @check and not has_await?(stmt),
      do: Interp.check_cps("{:aw} on #{elem(stmt, 0)}, which does not await")

    cs(stmt, env, ctx, k, labels)
  end

  defp cexec(stmt, env, %{frame: _} = ctx, k, labels) do
    if @check and has_await?(stmt),
      do: Interp.check_cps("no {:aw} on #{elem(stmt, 0)}, which awaits")

    sync_stmt(stmt, env, ctx, k, labels)
  end

  defp cexec(stmt, env, ctx, k, labels) do
    if has_await?(stmt),
      do: cs(stmt, env, ctx, k, labels),
      else: sync_stmt(stmt, env, ctx, k, labels)
  end

  # a statement without awaits, by the ordinary evaluator; its abrupt completions are routed
  # (the tail flag is off, see `no_tail/1`, so a `return f()` here is a plain return)
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

  # in an async generator `return;` and falling off the end finish without awaiting a value
  defp cs({:return, nil}, _env, %{async_gen: true} = ctx, _k, _labels), do: ctx.ret.(:ag_bare)
  defp cs({:return, e}, env, ctx, _k, _labels), do: cev(e, env, ctx, ctx.ret)
  defp cs({:return, e, :plain}, env, ctx, _k, _labels), do: cev(e, env, ctx, ctx.ret)
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
    if @check, do: Interp.check_old_path(env, "a CPS block")
    scope = Interp.new_scope(env)

    guarded(fn -> Interp.hoist_functions(stmts, scope) end, ctx, fn ->
      clist(stmts, scope, ctx, k)
    end)
  end

  # In frame mode `sc.hoist` makes the functions of the block, so this clause does not call
  # `hoist_functions`.
  defp cs({:block, stmts, sc}, env, ctx, k, _labels) do
    attempt(fn -> Interp.cps_enter(env, sc) end, ctx, fn b -> clist(stmts, b, ctx, k) end)
  end

  defp cs({:with, obj, body}, env, ctx, k, _labels) do
    cev(obj, env, ctx, fn o ->
      if o in [:undefined, :null] do
        guarded(
          fn -> Interp.throw_error("TypeError", "Cannot convert undefined or null to object") end,
          ctx,
          fn -> k.(:ok) end
        )
      else
        Process.put(:js_with_used, true)
        if @check, do: Interp.check_old_path(env, "a CPS with")
        scope = Interp.new_scope(env)
        sc = Interp.deref(scope)
        object = if match?({:obj, _}, o), do: o, else: Interp.new_object()
        Interp.store(scope, Map.put(sc, :with, object))
        cexec(body, scope, ctx, k)
      end
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
    # The CPS loop copies map scopes only (`Interp.copy_scope/2`). An async body is never
    # rewritten, so its `env` is no frame; check mode proves it.
    Interp.check_old_path(env, "a CPS for loop")
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

  # A `for` in frame mode. The head scope `l` comes from `Interp.cps_enter/2`. With
  # `per_iter` each round runs in its own copy of the head frame, which is made every round
  # with no counter test, as the CPS loop of `:off` copies its map scope every round. The
  # init is never marked `{:aw}` by the resolver, so it is walked here as `:off` walks it.
  defp cs({:for, init, test, update, body, sc}, env, ctx, k, labels) do
    attempt(fn -> Interp.cps_enter(env, sc) end, ctx, fn l ->
      per_iter? = match?(%{per_iter: true}, sc)

      start = fn _ ->
        first = if per_iter?, do: Interp.copy_scope(l, env), else: l
        for_iter({test, update, body, env, per_iter?}, first, ctx, k, labels)
      end

      case init do
        {:var, _, _} = d ->
          if has_await?(d), do: cs(d, l, ctx, start, []), else: sync_stmt(d, l, ctx, start, [])

        {:expr, e} ->
          cev(e, l, ctx, start)

        nil ->
          start.(:ok)
      end
    end)
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
          foreach(list, {pat, mode, body, env, :map}, ctx, k, labels)

        {:ok, {:proto, it, next}} ->
          proto_foreach(it, next, {pat, mode, body, env, :map}, ctx, k, labels)

        {:throw, e} ->
          ctx.throw.(e)
      end
    end)
  end

  # A for-in or for-of in frame mode. The object runs in the head scope `h`, where the head
  # names are in their TDZ. Each item enters the scope again (`item_env/2`).
  defp cs({kind, decl, pat, obj, body, sc}, env, ctx, k, labels) when kind in [:forin, :forof] do
    attempt(fn -> Interp.cps_enter(env, sc) end, ctx, fn h ->
      cev(obj, h, ctx, fn target ->
        items =
          try do
            {:ok,
             case kind do
               :forin ->
                 {:list, if(Interp.nullish?(target), do: [], else: Interp.own_keys(target))}

               :forof ->
                 Interp.iter_source(target)
             end}
          catch
            {:js_error, e} -> {:throw, e}
          end

        mode = if decl == nil, do: :assign, else: decl

        case items do
          {:ok, {:list, list}} ->
            foreach(list, {pat, mode, body, env, sc}, ctx, k, labels)

          {:ok, {:proto, it, next}} ->
            proto_foreach(it, next, {pat, mode, body, env, sc}, ctx, k, labels)

          {:throw, e} ->
            ctx.throw.(e)
        end
      end)
    end)
  end

  defp cs({:forawait, decl, pat, obj, body}, env, ctx, k, labels) do
    cev(obj, env, ctx, fn target ->
      attempt(fn -> async_iterator(target) end, ctx, fn {it, next, sync?} ->
        mode = if decl == nil, do: :assign, else: decl
        afor(it, next, sync?, {pat, mode, body, env, :map}, ctx, k, labels)
      end)
    end)
  end

  # A for-await in frame mode enters its scopes as the for-in and the for-of above do.
  defp cs({:forawait, decl, pat, obj, body, sc}, env, ctx, k, labels) do
    attempt(fn -> Interp.cps_enter(env, sc) end, ctx, fn h ->
      cev(obj, h, ctx, fn target ->
        attempt(fn -> async_iterator(target) end, ctx, fn {it, next, sync?} ->
          mode = if decl == nil, do: :assign, else: decl
          afor(it, next, sync?, {pat, mode, body, env, sc}, ctx, k, labels)
        end)
      end)
    end)
  end

  defp cs({:switch, disc, cases}, env, ctx, k, _labels) do
    cev(disc, env, ctx, fn v ->
      if @check, do: Interp.check_old_path(env, "a CPS switch")
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

  # In frame mode the discriminant runs in `env`. The tests and the bodies run in the switch
  # scope, where `sc.hoist` has made the functions of every case.
  defp cs({:switch, disc, cases, sc}, env, ctx, k, _labels) do
    cev(disc, env, ctx, fn v ->
      attempt(fn -> Interp.cps_enter(env, sc) end, ctx, fn scope ->
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

  defp cs({:try, block, param, handler, finalizer}, env, ctx, k, labels),
    do: cs_try(block, param, handler, finalizer, :map, env, ctx, k, labels)

  # In frame mode the block and the finalizer run in `env`. The parameter and the handler
  # run in the catch scope.
  defp cs({:try, block, param, handler, finalizer, sc}, env, ctx, k, labels),
    do: cs_try(block, param, handler, finalizer, sc, env, ctx, k, labels)

  defp cs({:using, kind, {:slot, 0, _, n} = form, init, rest}, env, ctx, k, _labels),
    do: cs_using(kind, n, &Interp.using_bind(env, form, &1), init, rest, env, ctx, k)

  defp cs({:using, kind, name, init, rest}, env, ctx, k, _labels),
    do: cs_using(kind, name, &Interp.declare(env, name, &1, true), init, rest, env, ctx, k)

  defp cs({:export, stmt}, env, ctx, k, labels), do: cexec(stmt, env, ctx, k, labels)

  defp cs({:export_default, {:expr, e}}, env, ctx, k, _labels) do
    cev(e, env, ctx, fn v ->
      Interp.declare(env, :default_export, v)
      k.(:ok)
    end)
  end

  if @check do
    # A tail return cannot occur, because the resolver sets `tail_ok` to false in these
    # bodies.
    defp cs({:return, _, :tail}, _env, _ctx, _k, _labels),
      do: Interp.check_cps("a tail return in a CPS body")
  end

  defp cs(stmt, env, ctx, k, labels) do
    if @check and is_map_key(ctx, :frame) and has_await?(stmt),
      do: Interp.check_cps("the sync fallback of cs meets #{elem(stmt, 0)}, which awaits")

    sync_stmt(stmt, env, ctx, k, labels)
  end

  defp cs_try(block, param, handler, finalizer, sc, env, ctx, k, _labels) do
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
              attempt(
                fn ->
                  scope = item_env(env, sc)
                  if param, do: Interp.bind_pattern(param, e, scope, :let)
                  scope
                end,
                wrapped,
                fn scope -> cexec(handler, scope, wrapped, done) end
              )
            end
        }
      else
        wrapped
      end

    cexec(block, env, in_try, done)
  end

  # The scope of one item of a for-in, for-of or for-await, and of a catch clause: a new map
  # scope on the old path (`:map`), the scope of the resolver in frame mode.
  defp item_env(env, :map) do
    if @check, do: Interp.check_old_path(env, "a CPS item scope")
    Interp.new_scope(env)
  end

  defp item_env(env, sc), do: Interp.cps_enter(env, sc)

  # `using` / `await using`: the rest of the list runs under a context that disposes the
  # resource before any way out. `bind` writes the binding: a `declare` on the old path, a
  # slot write in frame mode.
  defp cs_using(kind, name, bind, init, rest, env, ctx, k) do
    cev_named(init, name, env, ctx, fn v ->
      attempt(
        fn ->
          res = Interp.using_resource(kind, v)
          bind.(v)
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

  # binds a pattern (`k` runs afterwards). When a `yield` or `await` sits inside it, in a default,
  # a computed key or a target, the pattern is walked step by step so that the iterator stays
  # open (and is closed on a throw or `return()`) while the generator is suspended.
  defp cbind(pat, v, mode, env, ctx, k) do
    if has_await?(pat),
      do: cbind_cps(pat, v, mode, env, ctx, k),
      else: guarded(fn -> Interp.bind_pattern(pat, v, env, mode) end, ctx, k)
  end

  defp cbind_cps({:default, _, _} = pat, v, mode, env, ctx, k) do
    ctarget(pat, mode, env, ctx, fn binder -> binder.(v, k) end)
  end

  defp cbind_cps({:member, _, _, _} = pat, v, mode, env, ctx, k) do
    ctarget(pat, mode, env, ctx, fn binder -> binder.(v, k) end)
  end

  defp cbind_cps({:arrpat, elems}, v, mode, env, ctx, k) do
    attempt(fn -> Interp.iter_source(v) end, ctx, fn
      {:list, list} -> celems_list(elems, list, mode, env, ctx, k)
      {:proto, it, next} -> celems_proto(elems, it, next, false, mode, env, ctx, k)
    end)
  end

  defp cbind_cps({:objpat, props, rest}, v, mode, env, ctx, k) do
    guarded(
      fn ->
        if Interp.nullish?(v),
          do:
            Interp.throw_error(
              "TypeError",
              "Cannot destructure '#{Interp.to_str(v)}' as it is #{Interp.to_str(v)}."
            )
      end,
      ctx,
      fn -> cobj_props(props, rest, v, [], mode, env, ctx, k) end
    )
  end

  defp cbind_cps(pat, v, mode, env, ctx, k),
    do: guarded(fn -> Interp.bind_pattern(pat, v, env, mode) end, ctx, k)

  # a target: its reference is evaluated first (it may suspend); the binder then takes the value
  defp ctarget({:member, o, key, _}, :assign, env, ctx, kb) do
    cev(o, env, ctx, fn ov ->
      ckey(key, env, ctx, fn kv ->
        kb.(fn val, kk -> guarded(fn -> Interp.put(ov, kv, val) end, ctx, kk) end)
      end)
    end)
  end

  defp ctarget({:default, inner, e}, mode, env, ctx, kb) do
    ctarget(inner, mode, env, ctx, fn binder ->
      kb.(fn
        :undefined, kk -> cev(e, env, ctx, fn dv -> binder.(dv, kk) end)
        val, kk -> binder.(val, kk)
      end)
    end)
  end

  defp ctarget(pat, mode, env, ctx, kb),
    do: kb.(fn val, kk -> cbind(pat, val, mode, env, ctx, kk) end)

  defp ckey({:str, s}, _env, _ctx, k), do: k.(s)

  defp ckey({:priv, name}, env, ctx, k),
    do: attempt(fn -> Interp.private_key(name, env) end, ctx, k)

  defp ckey(e, env, ctx, k),
    do: cev(e, env, ctx, fn kv -> attempt(fn -> Interp.to_key(kv) end, ctx, k) end)

  defp celems_list([], _list, _mode, _env, _ctx, k), do: k.()

  defp celems_list([{:rest, p}], list, mode, env, ctx, k) do
    ctarget(p, mode, env, ctx, fn binder -> binder.(Interp.new_array(list), k) end)
  end

  defp celems_list([p | ps], list, mode, env, ctx, k) do
    {val, tail} =
      case list do
        [h | t] -> {h, t}
        [] -> {:undefined, []}
      end

    next = fn -> celems_list(ps, tail, mode, env, ctx, k) end

    if p == nil,
      do: next.(),
      else: ctarget(p, mode, env, ctx, fn binder -> binder.(val, next) end)
  end

  defp celems_proto([], it, _next, done?, _mode, _env, ctx, k) do
    if done?, do: k.(), else: guarded(fn -> Interp.iter_close(it, false) end, ctx, k)
  end

  defp celems_proto([{:rest, p}], it, next, done?, mode, env, ctx, k) do
    inner = closing_ctx(it, done?, ctx)

    ctarget(p, mode, env, inner, fn binder ->
      attempt(fn -> if done?, do: [], else: pull_all(it, next, []) end, ctx, fn list ->
        binder.(Interp.new_array(list), k)
      end)
    end)
  end

  defp celems_proto([p | ps], it, next, done?, mode, env, ctx, k) do
    inner = closing_ctx(it, done?, ctx)

    cont = fn binder ->
      attempt(
        fn ->
          if done?,
            do: {:undefined, true},
            else:
              (case Interp.iter_step(it, next) do
                 :done -> {:undefined, true}
                 {:ok, item} -> {item, false}
               end)
        end,
        ctx,
        fn {val, done2?} ->
          after_bind = fn -> celems_proto(ps, it, next, done2?, mode, env, ctx, k) end

          if binder == :skip, do: after_bind.(), else: binder.(val, after_bind)
        end
      )
    end

    if p == nil,
      do: cont.(:skip),
      else: ctarget(p, mode, env, inner, cont)
  end

  defp pull_all(it, next, acc) do
    case Interp.iter_step(it, next) do
      :done -> Enum.reverse(acc)
      {:ok, v} -> pull_all(it, next, [v | acc])
    end
  end

  # while a pattern's iterator is open, a throw or a `return()` at a suspension point closes it
  defp closing_ctx(_it, true, ctx), do: ctx

  defp closing_ctx(it, false, ctx) do
    %{
      ctx
      | throw: fn e ->
          try do
            Interp.iter_close(it, true)
          catch
            {:js_error, _} -> :ok
          end

          ctx.throw.(e)
        end,
        ret: fn r ->
          guarded(fn -> Interp.iter_close(it, false) end, ctx, fn -> ctx.ret.(r) end)
        end
    }
  end

  defp cobj_props([], nil, _v, _used, _mode, _env, _ctx, k), do: k.()

  defp cobj_props([], rest, v, used, mode, env, ctx, k) do
    ctarget(rest, mode, env, ctx, fn binder ->
      attempt(
        fn ->
          pairs =
            for key <- Browser.JS.Props.rest_keys(v, used), do: {key, Interp.get(v, key)}

          Interp.new_object(pairs)
        end,
        ctx,
        fn obj -> binder.(obj, k) end
      )
    end)
  end

  defp cobj_props([{key, p} | ps], rest, v, used, mode, env, ctx, k) do
    ckey_of(key, env, ctx, fn kv ->
      ctarget(p, mode, env, ctx, fn binder ->
        attempt(fn -> Interp.get(v, kv) end, ctx, fn val ->
          binder.(val, fn -> cobj_props(ps, rest, v, used ++ [kv], mode, env, ctx, k) end)
        end)
      end)
    end)
  end

  defp ckey_of({:str, s}, _env, _ctx, k), do: k.(s)
  defp ckey_of({:computed, e}, env, ctx, k), do: ckey(e, env, ctx, k)

  # declarations, one at a time
  defp cdecls([], _kind, _env, _ctx, k), do: k.(:ok)

  defp cdecls([{pat, init} | rest], kind, env, ctx, k) do
    next = fn -> cdecls(rest, kind, env, ctx, k) end

    cond do
      init != nil ->
        cev(init, env, ctx, fn v ->
          cbind(pat, v, kind, env, ctx, next)
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

  defp foreach([item | rest], {pat, mode, body, env, sc} = spec, ctx, k, labels) do
    Interp.tick()
    iter_env = item_env(env, sc)

    cbind(pat, item, mode, iter_env, ctx, fn ->
      run_body(body, iter_env, ctx, k, labels, fn _ -> foreach(rest, spec, ctx, k, labels) end)
    end)
  end

  # `for await`: each step's result is awaited, and so is each value of a sync iterator
  defp afor(it, next, sync?, spec, ctx, k, labels) do
    attempt(fn -> Interp.call(next, it, []) end, ctx, fn r ->
      if sync? do
        # AsyncFromSyncIteratorContinuation: the value is resolved, and the loop awaits the
        # promise that `then` on it settles
        attempt(fn -> afor_result(r) end, ctx, fn {done?, v} ->
          p = Promise.new()
          # a rejected value closes the sync iterator and rejects the promise the loop awaits
          reject = fn e ->
            unless done? do
              try do
                case Interp.get(it, "return") do
                  m when m in [:undefined, :null] -> :ok
                  f -> Interp.call(f, it, [])
                end
              catch
                {:js_error, _} -> :ok
              end
            end

            Promise.reject(p, e)
          end

          wrapper_ctx = %{ctx | throw: reject}

          await_value(v, wrapper_ctx, fn val -> Promise.resolve(p, val) end)

          await_value(p, ctx, fn val ->
            if done?,
              do: k.(:ok),
              else: afor_body(val, it, next, sync?, spec, ctx, k, labels)
          end)
        end)
      else
        await_value(r, ctx, fn r2 ->
          attempt(fn -> afor_result(r2) end, ctx, fn
            {true, _} -> k.(:ok)
            {false, v} -> afor_body(v, it, next, sync?, spec, ctx, k, labels)
          end)
        end)
      end
    end)
  end

  defp afor_result(r) do
    unless match?({:obj, _}, r),
      do: Interp.throw_error("TypeError", "Iterator result is not an object")

    {Interp.truthy(Interp.get(r, "done")), Interp.get(r, "value")}
  end

  defp afor_body(item, it, next, sync?, {pat, mode, body, env, sc} = spec, ctx, k, labels) do
    Interp.tick()
    iter_env = item_env(env, sc)

    # leaving the loop early calls the iterator's `return` and waits for it
    closing = fn after_ ->
      attempt(
        fn ->
          case Interp.get(it, "return") do
            m when m in [:undefined, :null] ->
              :undefined

            f ->
              unless Interp.function?(f),
                do: Interp.throw_error("TypeError", "Iterator return is not a function")

              Interp.call(f, it, [])
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

    cbind(pat, item, mode, iter_env, inner, fn ->
      run_body(body, iter_env, inner, on_break, labels, fn _ ->
        afor(it, next, sync?, spec, ctx, k, labels)
      end)
    end)
  end

  # `for of` over an iterator object, one value at a time; leaving the loop early (break,
  # return, an outer label, a throw) calls the iterator's `return`
  defp proto_foreach(it, next, {pat, mode, body, env, sc} = spec, ctx, k, labels) do
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
        iter_env = item_env(env, sc)

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

        cbind(pat, item, mode, iter_env, inner, fn ->
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
