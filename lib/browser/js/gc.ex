defmodule Browser.JS.GC do
  @moduledoc """
  A mark-and-sweep collector for the heap in `Browser.JS.Interp`.

  It only runs between timers (`Browser.JS.Builtins.run_next_timer/2`), when no script is on
  the stack, so everything alive is reachable from the process dictionary: the global scope,
  prototypes, timers, microtasks, modules, the DOM's bookkeeping and so on.

  The walk is deliberately conservative instead of knowing every field: it follows every
  `{:obj, id}` and every integer that is a heap id, in any tuple, list, map and in the
  environment of Elixir funs (the built-ins capture ids). A stray integer can keep a dead object
  alive, but nothing reachable is ever freed. Function bodies are syntax trees and not walked;
  only the scope and `home` of a closure are.

  It is off unless `:js_gc_at` is set (the page runtime does, `Browser.JS.eval/2` does not,
  since it holds a result across the timers).
  """

  @min_collect 100_000

  @doc "Switches the collector on for this process."
  def enable, do: Process.put(:js_gc_at, @min_collect)

  # The Erlang collector copies everything alive twice: out of a full young heap, then into the old
  # heap. A young heap that is small next to what is alive makes that happen often, and what dies a
  # little after it was made gets copied as well. So the young heap grows with the process, to at
  # most a part of its size (never down, and never past @max_young words).
  @min_young 2_000_000
  @max_young 16_000_000

  defp tune_young_heap do
    {:total_heap_size, words} = Process.info(self(), :total_heap_size)
    target = words |> div(2) |> max(@min_young) |> min(@max_young)

    if target > Process.get(:js_young, @min_young) * 5 / 4 do
      Process.put(:js_young, target)
      :erlang.process_flag(:min_heap_size, target)
    end
  end

  @doc "Collects when the heap has grown past the threshold; cheap otherwise."
  def maybe_collect do
    case Process.get(:js_gc_at) do
      nil ->
        :ok

      at ->
        tune_young_heap()
        if Browser.JS.Interp.heap_size() > at, do: collect(), else: :ok
    end
  end

  @doc "Frees every heap entry not reachable from the process dictionary; returns how many."
  def collect do
    # (the heap's objects are the process dictionary entries under integer keys)
    {ids, roots} =
      :lists.foldl(
        fn
          {k, _}, {ids, roots} when is_integer(k) -> {[k | ids], roots}
          {{:js_hoist, _}, _}, acc -> acc
          {:js_memo, _}, acc -> acc
          {:js_heap_n, _}, acc -> acc
          {_, v}, {ids, roots} -> {ids, [v | roots]}
        end,
        {[], []},
        Process.get()
      )

    # (the marks live in a table of their own: no garbage for the process's collector to sweep)
    marks = :ets.new(:js_marks, [:set, :private])

    try do
      mark(Enum.reduce(roots, [], &push(&1, &2, marks)), marks)
      live = :ets.info(marks, :size)

      freed =
        :lists.foldl(
          fn id, n ->
            if :ets.member(marks, id) do
              n
            else
              :erlang.erase(id)
              n + 1
            end
          end,
          0,
          ids
        )

      Process.put(:js_heap_n, live)
      Process.put(:js_gc_at, max(@min_collect, 2 * live))
      freed
    after
      :ets.delete(marks)
    end
  end

  # `stack` holds what is still to be looked at: only terms that can lead to heap entries
  defp mark([], _marks), do: :ok

  defp mark([t | rest], marks) when is_tuple(t),
    do: mark(push_tuple(t, tuple_size(t), rest, marks), marks)

  defp mark([[] | rest], marks), do: mark(rest, marks)
  defp mark([[_ | _] = l | rest], marks), do: mark(push_list(l, rest, marks), marks)

  # the resolver's facts hold names, numbers, atoms and syntax, never a heap id:
  # a frame carries one in its header, so the walk must not read it as ids
  defp mark([%Browser.JS.Resolve.Info{} | rest], marks), do: mark(rest, marks)
  defp mark([%Browser.JS.Resolve.Scope{} | rest], marks), do: mark(rest, marks)

  defp mark([%{params: _, body: _} = closure | rest], marks) do
    stack = push(Map.get(closure, :scope), rest, marks)
    mark(push(Map.get(closure, :home), stack, marks), marks)
  end

  defp mark([t | rest], marks) when is_map(t) do
    # integer keys are array indices: skip them, not references
    stack =
      :maps.fold(
        fn
          k, v, acc when is_integer(k) -> push(v, acc, marks)
          k, v, acc -> push(v, push(k, acc, marks), marks)
        end,
        rest,
        t
      )

    mark(stack, marks)
  end

  defp mark([t | rest], marks) when is_function(t) do
    case :erlang.fun_info(t, :env) do
      {:env, env} -> mark(push_list(env, rest, marks), marks)
      _ -> mark(rest, marks)
    end
  end

  defp mark([_ | rest], marks), do: mark(rest, marks)

  defp push_tuple(_t, 0, stack, _marks), do: stack

  defp push_tuple(t, n, stack, marks),
    do: push_tuple(t, n - 1, push(elem(t, n - 1), stack, marks), marks)

  defp push_list([h | t], stack, marks) when is_list(t),
    do: push_list(t, push(h, stack, marks), marks)

  defp push_list([h | t], stack, marks), do: push(t, push(h, stack, marks), marks)
  defp push_list(_, stack, _marks), do: stack

  # a heap id is marked when it is first reached, and its entry is looked at then
  defp push(t, stack, marks) when is_integer(t) do
    case :erlang.get(t) do
      :undefined -> stack
      obj -> if :ets.insert_new(marks, {t}), do: [obj | stack], else: stack
    end
  end

  defp push([], stack, _marks), do: stack

  defp push(t, stack, _marks) when is_tuple(t) or is_map(t) or is_list(t) or is_function(t),
    do: [t | stack]

  defp push(_, stack, _marks), do: stack
end
