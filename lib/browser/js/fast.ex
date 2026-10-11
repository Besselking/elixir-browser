defmodule Browser.JS.Fast do
  @moduledoc false
  # The switch and the shadow run of the fast paths of the data model.
  #
  # A fast path is a short way to the result of a generic operation (`put_obj/5`,
  # `Props.descriptor/2`, `has_property?/2` and `get/2`) for the common cases. The
  # differential oracle of `test/browser/js_fast_test.exs` runs each program with the fast
  # paths off and on, and compares the two runs. The compile oracle cannot see a wrong fast
  # path, because the tree walker and the compiled code call the same fast paths.
  #
  # Each fast path has a name. In the check build (`JS_RESOLVE_CHECK=1`, see
  # `config/config.exs`) the process key `:js_fast_off` holds the list of the names that are
  # off, and each hit of a fast path also runs the old path and compares (`shadow/3`). In the
  # normal build, `on?/1` gives `true` when the caller compiles and `shadow/3` gives the fast
  # expression, so the switch and the shadow cost nothing.

  @check Application.compile_env(:browser, :js_resolve_check, false)

  # The names of all fast paths. The oracle turns them all off with this list.
  @names [:has_own, :update, :compound, :literal, :add, :iter]

  @doc false
  def names, do: @names

  @doc false
  # Whether the fast path `name` is on. In the normal build it is the constant `true`.
  defmacro on?(name) do
    if @check do
      quote do
        case :erlang.get(:js_fast_off) do
          :undefined -> true
          off -> not :lists.member(unquote(name), off)
        end
      end
    else
      true
    end
  end

  @doc false
  # The result of a fast path, `fast`, for the object with the id `id` (or `nil` when the
  # fast path reads no object). In the check build the old path, `old`, runs first on the
  # same state, and the two must give the same result and leave the same record at `id`.
  # The old path must not fail a write and must not call JavaScript code: the guard of each
  # fast path excludes setters, getters and proxies, so the old path cannot get to user
  # code. The old path must not change the heap either: the objects that it makes are
  # erased, and the heap counters go back to their values before it. In the normal build
  # the old path is in a branch that the compiler drops, so that a name or a function that
  # only the old path uses is not reported as unused.
  defmacro shadow(id, fast, old) do
    if @check do
      quote do
        Browser.JS.Fast.shadow_run(
          unquote(id),
          fn -> unquote(fast) end,
          fn -> unquote(old) end
        )
      end
    else
      quote do
        _ = unquote(id)
        if false, do: unquote(old), else: unquote(fast)
      end
    end
  end

  if @check do
    @doc false
    def shadow_run(id, fast, old) do
      record = if id, do: :erlang.get(id)
      flag = :erlang.get(:js_put_failed)
      next = :erlang.get(:js_next)
      heap_n = :erlang.get(:js_heap_n)
      steps = :erlang.get(:js_steps)

      # (a write that fails sets the flag; the old path starts with the flag clear, so that
      # the test below sees its own failure)
      :erlang.put(:js_put_failed, false)

      old_result =
        try do
          old.()
        catch
          kind, reason ->
            fail("the old path of a fast path stopped with #{inspect({kind, reason}, limit: 8)}")
        end

      if :erlang.get(:js_steps) != steps,
        do: fail("the old path of a fast path called JavaScript")

      if :erlang.get(:js_put_failed) == true,
        do: fail("the old path of a fast path failed a write")

      old_record = if id, do: :erlang.get(id)

      # The state goes back to what it was before the old path.
      for i <- next..(:erlang.get(:js_next) - 1)//1, do: :erlang.erase(i)
      :erlang.put(:js_next, next)
      :erlang.put(:js_heap_n, heap_n)
      if id, do: :erlang.put(id, record)

      if flag == :undefined,
        do: :erlang.erase(:js_put_failed),
        else: :erlang.put(:js_put_failed, flag)

      fast_result = fast.()
      fast_record = if id, do: :erlang.get(id)

      if fast_result !== old_result,
        do:
          fail(
            "a fast path gives #{inspect(fast_result, limit: 8)}, " <>
              "the old path #{inspect(old_result, limit: 8)}"
          )

      if fast_record !== old_record,
        do:
          fail(
            "a fast path stores #{inspect(fast_record, limit: 12)}, " <>
              "the old path #{inspect(old_record, limit: 12)}"
          )

      fast_result
    end

    defp fail(msg), do: raise(ArgumentError, "fast path check: " <> msg)
  end
end
