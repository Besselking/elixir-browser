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

  @doc false
  # The dangling scan of check mode (`Browser.JS.Interp.check_dangling/1`): the names of the
  # freed frames that a reachable value still holds. A freed frame is a tombstone
  # `{:js_freed, name}` in check mode. The walk is the walk of `collect/0`, but a tombstone
  # counts only when it is reached through an edge that holds a scope: the `scope` and
  # `home` of a closure, the `parent` and `env` of a map, and the parent of a frame. The
  # conservative walk reads every integer as an id, so an array length or a line number
  # that equals the id of a tombstone must not count.
  def dangling(extra) do
    roots =
      :lists.foldl(
        fn
          {k, _}, roots when is_integer(k) -> roots
          {{:js_hoist, _}, _}, roots -> roots
          {:js_memo, _}, roots -> roots
          {:js_heap_n, _}, roots -> roots
          {_, v}, roots -> [v | roots]
        end,
        [extra],
        Process.get()
      )

    marks = :ets.new(:js_marks, [:set, :private])

    try do
      scan(Enum.reduce(roots, [], &spush(&1, &2, marks, false)), marks)
      for {{:hit, _}, name} <- :ets.tab2list(marks), uniq: true, do: name
    after
      :ets.delete(marks)
    end
  end

  defp scan([], _marks), do: :ok
  defp scan([%Browser.JS.Resolve.Info{} | rest], marks), do: scan(rest, marks)
  defp scan([%Browser.JS.Resolve.Scope{} | rest], marks), do: scan(rest, marks)

  defp scan([t | rest], marks)
       when is_tuple(t) and tuple_size(t) >= 5 and
              (is_struct(elem(t, 1), Browser.JS.Resolve.Info) or
                 is_struct(elem(t, 1), Browser.JS.Resolve.Scope)) do
    stack = spush_from(t, 3, tuple_size(t), rest, marks)
    scan(spush(elem(t, 0), stack, marks, true), marks)
  end

  defp scan([t | rest], marks) when is_tuple(t),
    do: scan(spush_from(t, 1, tuple_size(t), rest, marks), marks)

  defp scan([l | rest], marks) when is_list(l) do
    stack = Enum.reduce(improper_to_list(l), rest, &spush(&1, &2, marks, false))
    scan(stack, marks)
  end

  defp scan([%{params: _, body: _} = closure | rest], marks) do
    stack = spush(Map.get(closure, :scope), rest, marks, true)
    scan(spush(Map.get(closure, :home), stack, marks, true), marks)
  end

  defp scan([t | rest], marks) when is_map(t) do
    stack =
      :maps.fold(
        fn
          k, v, acc when is_integer(k) -> spush(v, acc, marks, false)
          k, v, acc -> spush(v, spush(k, acc, marks, false), marks, k in [:parent, :env])
        end,
        rest,
        t
      )

    scan(stack, marks)
  end

  defp scan([t | rest], marks) when is_function(t) do
    case :erlang.fun_info(t, :env) do
      {:env, env} -> scan(Enum.reduce(env, rest, &spush(&1, &2, marks, false)), marks)
      _ -> scan(rest, marks)
    end
  end

  defp scan([_ | rest], marks), do: scan(rest, marks)

  # (the elements of a tuple from the 1-based position `i` to `n`)
  defp spush_from(_t, i, n, stack, _marks) when i > n, do: stack

  defp spush_from(t, i, n, stack, marks),
    do: spush_from(t, i + 1, n, spush(elem(t, i - 1), stack, marks, false), marks)

  defp improper_to_list([h | t]) when is_list(t), do: [h | improper_to_list(t)]
  defp improper_to_list([h | t]), do: [h, t]
  defp improper_to_list([]), do: []

  # `scope?` says whether the edge to `t` holds a scope: a tombstone found there is a hit
  defp spush(t, stack, marks, scope?) when is_integer(t) do
    case :erlang.get(t) do
      :undefined ->
        stack

      {:js_freed, name} = obj ->
        if scope?, do: :ets.insert(marks, {{:hit, t}, name})
        if :ets.insert_new(marks, {t}), do: [obj | stack], else: stack

      obj ->
        if :ets.insert_new(marks, {t}), do: [obj | stack], else: stack
    end
  end

  defp spush(t, stack, _marks, _scope?)
       when is_tuple(t) or is_map(t) or is_list(t) or is_function(t),
       do: [t | stack]

  defp spush(_, stack, _marks, _scope?), do: stack

  # `stack` holds what is still to be looked at: only terms that can lead to heap entries
  defp mark([], _marks), do: :ok

  # A frame: element 2 is the resolver's record. Only the parent, the root and the slots can
  # hold ids. The caller id and the line number in `call_pos` must not keep a random object
  # alive. The guard names the two record structs: other tuples, such as the function
  # tuple of a WebAssembly instance, can also have a struct in position 2.
  defp mark([t | rest], marks)
       when is_tuple(t) and tuple_size(t) >= 5 and
              (is_struct(elem(t, 1), Browser.JS.Resolve.Info) or
                 is_struct(elem(t, 1), Browser.JS.Resolve.Scope)) do
    stack = push_frame_slots(t, 5, tuple_size(t), rest, marks)
    mark(push(elem(t, 0), stack, marks), marks)
  end

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

  # (the elements of a frame from the 1-based position `i` to `n`)
  defp push_frame_slots(_t, i, n, stack, _marks) when i > n, do: stack

  defp push_frame_slots(t, i, n, stack, marks),
    do: push_frame_slots(t, i + 1, n, push(elem(t, i - 1), stack, marks), marks)

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
      :undefined ->
        stack

      # A tombstone of check mode is a freed frame, not a live entry. The walk reads any
      # integer as an id, so a stray number must not keep a tombstone or count it as live.
      # The dangling scan reports a real reference to it.
      {:js_freed, _} ->
        stack

      obj ->
        if :ets.insert_new(marks, {t}), do: [obj | stack], else: stack
    end
  end

  defp push([], stack, _marks), do: stack

  defp push(t, stack, _marks) when is_tuple(t) or is_map(t) or is_list(t) or is_function(t),
    do: [t | stack]

  defp push(_, stack, _marks), do: stack
end
