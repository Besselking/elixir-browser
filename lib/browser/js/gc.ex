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

  @doc "Collects when the heap has grown past the threshold; cheap otherwise."
  def maybe_collect do
    case Process.get(:js_gc_at) do
      nil ->
        :ok

      at ->
        if Browser.JS.Interp.heap_size() > at, do: collect(), else: :ok
    end
  end

  @doc "Frees every heap entry not reachable from the process dictionary; returns how many."
  def collect do
    # (the heap's objects are the process dictionary entries under integer keys)
    {heap, roots} =
      Enum.reduce(Process.get(), {%{}, []}, fn
        {k, v}, {heap, roots} when is_integer(k) -> {Map.put(heap, k, v), roots}
        {{:js_hoist, _}, _}, acc -> acc
        {:js_heap_n, _}, acc -> acc
        {_, v}, {heap, roots} -> {heap, [v | roots]}
      end)

    live = mark(roots, heap, %{})
    freed = map_size(heap) - map_size(live)
    for {id, _} <- heap, not is_map_key(live, id), do: Process.delete(id)
    Process.put(:js_heap_n, map_size(live))
    Process.put(:js_gc_at, max(@min_collect, 2 * map_size(live)))
    freed
  end

  defp mark([], _heap, live), do: live

  defp mark([t | rest], heap, live) when is_integer(t) do
    case heap do
      %{^t => obj} when not is_map_key(live, t) ->
        mark([obj | rest], heap, Map.put(live, t, true))

      _ ->
        mark(rest, heap, live)
    end
  end

  defp mark([%{params: _, body: _} = closure | rest], heap, live),
    do: mark([Map.get(closure, :scope), Map.get(closure, :home) | rest], heap, live)

  defp mark([t | rest], heap, live) when is_tuple(t),
    do: mark(Tuple.to_list(t) ++ rest, heap, live)

  defp mark([[h | t] | rest], heap, live), do: mark([h, t | rest], heap, live)

  defp mark([t | rest], heap, live) when is_map(t) do
    # integer keys are array indices: skip them, not references
    items =
      Enum.flat_map(:maps.to_list(t), fn
        {k, v} when is_integer(k) -> [v]
        {k, v} -> [k, v]
      end)

    mark(items ++ rest, heap, live)
  end

  defp mark([t | rest], heap, live) when is_function(t) do
    case :erlang.fun_info(t, :env) do
      {:env, env} -> mark(env ++ rest, heap, live)
      _ -> mark(rest, heap, live)
    end
  end

  defp mark([_ | rest], heap, live), do: mark(rest, heap, live)
end
