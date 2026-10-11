defmodule Browser.JS.Compile do
  @moduledoc """
  Closure compilation of JS function bodies (step 5).

  The resolver rewrites a function so that it runs on a slot frame. At the first call of
  such a function, this module changes the body of the function into Elixir closures. A
  closure takes the frame id and gives the value or the completion of the code that it
  replaces. The interpreter (`Browser.JS.Interp`) then calls the closures, and does not
  walk the syntax tree of the body again.

  This version has no compiled node kinds. A body becomes a chain of closures, with one
  closure for each statement. Each closure sends its statement to the tree walker. Because
  of this, the results are the same as the results of the tree walker, and a call costs
  almost the same number of reductions. This version gives the cache, the switch and the rules
  for the collector, which the node kinds use later.

  ## Which functions compile

  A function compiles when all of these conditions are true:

    * the resolver rewrote the function (`Info.rewritten`);
    * the function is not async and not a generator;
    * the `Info` has a `uid`;
    * the switch `:js_compile` of the process is on.

  ## The switch

  The application setting `:js_compile` (default `true`, `JS_COMPILE=0` sets it to `false`)
  is the switch. `Browser.JS.Interp.init/1` copies it into the process dictionary. Because
  of this, each heap has its own value, and one VM can run the two modes.

  ## The cache

  The process dictionary keeps the compiled code of each function under the key
  `{:jsc, uid}`. The value is `{body, maker}`. `body` is the closure of the body. `maker`
  is the frame maker, which is `nil` in this version. Each function object keeps its code
  in its closure record (the `code` key), so that a call does not read the cache.

  ## Rules for the code

    * A compiled closure keeps only values that are known at compile time: slot numbers,
      names, constants, syntax nodes and other compiled closures. It never keeps a frame id
      or a heap id. Because of this, the collector (`Browser.JS.GC`) does not walk the
      cache or the funs of this module.
    * Each closure has one parent closure. Because of this, the size of the code is linear
      in the size of the body.
    * The code stays in its process. Do not send it in a message, and do not put it in ETS,
      in `persistent_term` or in `term_to_binary`.
  """

  alias Browser.JS.Interp
  alias Browser.JS.Resolve.Info

  @doc """
  Gives the compiled body of the closure record `c`, or `nil` when the function does not
  compile. The first call for a function compiles the body and puts it in the cache.
  """
  @spec code(map) :: (integer -> term) | nil
  def code(%{info: %Info{rewritten: true, async?: false, generator?: false, uid: uid}} = c)
      when uid != nil do
    # (the switch is off when it was never set: a process that did not start its heap with
    # `Interp.init/1` runs on the tree walker)
    if :erlang.get(:js_compile) == true do
      case :erlang.get({:jsc, uid}) do
        {body, _maker} -> body
        :undefined -> compile_and_store(c, uid)
      end
    end
  end

  def code(_c), do: nil

  defp compile_and_store(c, uid) do
    body = body(c)
    :erlang.put({:jsc, uid}, {body, nil})
    body
  end

  # The closure of a body. An arrow with an expression body gives the value of the
  # expression, and every other body gives the completion of its statement list.
  # `body_value/2` in `Interp` reads the two kinds by the mode of the closure record.
  defp body(%{mode: :arrow_expr, body: e}), do: expr(e)
  defp body(%{body: stmts}), do: list(stmts)

  # An expression. No kind compiles yet, so the tree walker evaluates it.
  defp expr(e), do: fn env -> Interp.ev(e, env) end

  # A statement list, as a chain of closures that is built from the end. Each link runs
  # one statement. A statement that completes normally (`:ok`) goes on to the rest of the
  # list, with a tail call, so a long body uses no stack. Any other completion ends the
  # list, as in `fbody/2`. A position goes into the link of the statement that follows it,
  # as a write of `:js_pos` before the statement. A function declaration and an empty
  # statement do nothing when they run (the frame hoists the functions at its entry), so
  # they get no link. No statement kind compiles yet, so each link runs its statement
  # through `Interp.fstmt/3`, as `fbody/2` does. A link then costs one call, as one step
  # of `fbody/2` does.
  defp list(stmts) do
    stmts
    |> Enum.reject(&(match?({:fundecl, _, _}, &1) or &1 == {:empty}))
    |> Enum.reverse()
    |> chain(nil)
  end

  # The list is reversed: the head is the last statement. `rest` is the link of the
  # statements after the head, or `nil` at the end of the list.
  defp chain([], nil), do: fn _env -> :ok end
  defp chain([], rest), do: rest

  defp chain([{:pos, loc} | before], rest), do: chain(before, at(loc, rest))

  defp chain([s, {:pos, loc} | before], rest), do: chain(before, link(loc, s, rest))
  defp chain([s | before], rest), do: chain(before, link(nil, s, rest))

  # A position with no statement after it (the end of a body).
  defp at(loc, nil) do
    fn _env ->
      :erlang.put(:js_pos, loc)
      :ok
    end
  end

  defp at(loc, rest) do
    fn env ->
      :erlang.put(:js_pos, loc)
      rest.(env)
    end
  end

  # In check mode a statement must complete with one of the five shapes of step 3, as in
  # `fbody/2`. The attribute is a constant, so a normal build has no test.
  @check Application.compile_env(:browser, :js_resolve_check, false)

  defmacrop done(c, s) do
    quote do
      c = unquote(c)
      if @check and c != :ok, do: Interp.check_completion(c, unquote(s))
      c
    end
  end

  defp link(nil, s, nil), do: fn env -> done(Interp.fstmt(s, env, []), s) end

  defp link(loc, s, nil) do
    fn env ->
      :erlang.put(:js_pos, loc)
      done(Interp.fstmt(s, env, []), s)
    end
  end

  defp link(nil, s, rest) do
    fn env ->
      case done(Interp.fstmt(s, env, []), s) do
        :ok -> rest.(env)
        c -> c
      end
    end
  end

  defp link(loc, s, rest) do
    fn env ->
      :erlang.put(:js_pos, loc)

      case done(Interp.fstmt(s, env, []), s) do
        :ok -> rest.(env)
        c -> c
      end
    end
  end
end
