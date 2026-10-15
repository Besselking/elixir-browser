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
  only the scope and `home` of a closure are. The compiled code of step 5 (the `{:jsc, _}`
  keys and the funs of `Browser.JS.Compile`) is not walked either: it holds no heap id.
  The continuation of a compiled plan of an async body or a generator (step 5c) is a fun
  of `Browser.JS.Async`, so the walk visits it and finds the frame that it keeps. The walk
  stops at the compiled closures in it. The process key `:js_cps_vals` holds the values of
  a lift template only while the template runs, so it is a root like any other key. The
  walk reads the document's state through `Browser.JS.DOM.gc_root/1`, which leaves out the
  node table and the other fields that hold no JS value. The lexer's tables and the boxes
  of the layout are not roots: they hold offsets and numbers only. The fields of a heap
  record that `Browser.JS.Obj.no_refs?/1` names are not walked: they hold counts and keys,
  and a count must not keep a dead object alive. The cells of the inline
  caches (step A2) are process keys that are negative integers. They are not heap entries
  and not roots: a cell can hold the id of a prototype, and a freed prototype makes the
  cell miss (`Browser.JS.Shape`).

  It is off unless `:js_gc_at` is set (the page runtime does, `Browser.JS.eval/2` does not,
  since it holds a result across the timers). A threshold of 0 stays 0, so the collector
  runs after each timer: `JS_GC=every` sets this for each process that `enable/0` switches
  on, so that the tests can find a value that only an unwalked field holds.
  """

  import Bitwise
  require Browser.JS.Obj, as: Obj

  @min_collect 100_000

  # Check mode (`JS_RESOLVE_CHECK=1`): the fields of the document that the walk leaves out
  # must hold no JS value (`check_no_values/1`).
  @check Application.compile_env(:browser, :js_resolve_check, false)

  @doc "Switches the collector on for this process."
  def enable do
    at = if Application.get_env(:browser, :js_gc_every, false), do: 0, else: @min_collect
    Process.put(:js_gc_at, at)
  end

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
          {k, _}, {ids, roots} when is_integer(k) and k >= 0 -> {[k | ids], roots}
          # (a negative key is the cell of an inline cache, see `Browser.JS.Shape`: it is not
          # a heap entry, so the sweep must not erase it, and it is not a root, so the id of
          # a prototype in it does not keep the prototype alive)
          {k, _}, acc when is_integer(k) -> acc
          {{:js_hoist, _}, _}, acc -> acc
          # (the cache of compiled code holds no heap id, see `Browser.JS.Compile`; its
          # syntax nodes hold slot numbers, which must not keep an object alive)
          {{:jsc, _}, _}, acc -> acc
          # (the count of the code cache holds two integers, which are not heap ids)
          {:jsc_budget, _}, acc -> acc
          {:js_memo, _}, acc -> acc
          {:js_freed, _}, acc -> acc
          # (the call chain holds names, positions and depths, never an id; a depth or a
          # line that equals the id of a dead object must not keep it alive)
          {:js_stack, _}, acc -> acc
          {:js_check_stack, _}, acc -> acc
          # (the transition table of the shapes and its counters hold keys, shapes and
          # integers, never a heap id, see `Browser.JS.Shape`; a count that equals the id
          # of a dead object must not keep it alive)
          {{:jst, _}, _}, acc -> acc
          {:js_shape_next, _}, acc -> acc
          {:js_ic_next, _}, acc -> acc
          {:js_shape_n, _}, acc -> acc
          {:js_shape_since, _}, acc -> acc
          # (the positions of the keys of the array iterators hold two prototypes and two
          # built-in functions, which are roots anyway, and shape ids and positions, which
          # are not heap ids, see `Browser.JS.Interp`)
          {:js_arr_iter_pos, _}, acc -> acc
          # (the parser's source table and the lexer's table hold the source, token
          # offsets and tokens: an offset that equals the id of a dead object must not keep
          # it alive)
          {:js_srctab, _}, acc -> acc
          {:lex_table, _}, acc -> acc
          # (the boxes of the layout and the counts of the forced layouts hold numbers
          # only, see `Browser.JS.DOM`)
          {:dom_page_rects, _}, acc -> acc
          {:dom_forced_rects, _}, acc -> acc
          {:dom_forced, _}, acc -> acc
          {:dom_forced_spent, _}, acc -> acc
          # (the document's state: only the fields that can hold a JS value, see
          # `Browser.JS.DOM.gc_root/1`; the node table is large and holds no JS value)
          {:dom, v}, {ids, roots} when is_map(v) -> {ids, [dom_root(v) | roots]}
          {_, v}, {ids, roots} -> {ids, [v | roots]}
        end,
        {[], []},
        Process.get()
      )

    # The marks are a bitmap with one bit for each heap id up to the largest key. A bit costs
    # less than an entry of a table, and it makes no garbage for the process's collector.
    marks = :atomics.new(div(:lists.max([0 | ids]), 64) + 1, signed: false)
    mark(Enum.reduce(roots, [], &push(&1, &2, marks)), marks)

    {freed, live} =
      :lists.foldl(
        fn id, {n, live} ->
          if marked?(marks, id) do
            {n, live + 1}
          else
            :erlang.erase(id)
            {n + 1, live}
          end
        end,
        {0, 0},
        ids
      )

    Process.put(:js_freed, :erlang.get(:js_next) - live)
    # (a threshold of 0 is the test setting `JS_GC=every`: it stays)
    if Process.get(:js_gc_at) != 0, do: Process.put(:js_gc_at, max(@min_collect, 2 * live))
    freed
  end

  @compile {:inline, marked?: 2}
  defp marked?(marks, id),
    do: (:atomics.get(marks, (id >>> 6) + 1) &&& 1 <<< (id &&& 63)) != 0

  # Marks `id`; false when it was marked before. Only a key of the process dictionary gets
  # here, so the bitmap has a bit for it.
  @compile {:inline, mark_new: 2}
  defp mark_new(marks, id) do
    i = (id >>> 6) + 1
    bit = 1 <<< (id &&& 63)
    word = :atomics.get(marks, i)

    if (word &&& bit) == 0 do
      :atomics.put(marks, i, word ||| bit)
      true
    else
      false
    end
  end

  defp dom_root(s) do
    if @check, do: check_no_values(Browser.JS.DOM.gc_left_out(s))
    Browser.JS.DOM.gc_root(s)
  end

  # Check mode: `t` holds no object and no fun. The walk of `collect/0` leaves `t` out, so
  # a JS value in it would not keep its object alive.
  defp check_no_values(t) do
    if value?(t), do: raise(ArgumentError, "resolve check: a JS value in an unwalked field")
  end

  defp value?({:obj, _}), do: true
  defp value?(t) when is_function(t), do: true
  defp value?(t) when is_tuple(t), do: value?(Tuple.to_list(t))
  defp value?([h | t]), do: value?(h) or value?(t)
  defp value?(t) when is_map(t), do: value?(:maps.to_list(t))
  defp value?(_), do: false

  @doc false
  # The dangling scan of check mode (`Browser.JS.Interp.check_dangling/1`): the names of the
  # freed frames that a reachable value still holds. A freed frame is a tombstone
  # `{:js_freed, name}` in check mode. The walk is the walk of `collect/0`, but a tombstone
  # counts only when it is reached through an edge that holds a scope: the `scope` and
  # `home` of a closure, the `parent` and `env` of a map, the `map_scope` of a mapped
  # arguments object (a frame from step 2d, which must be detached before its frame is
  # freed), the `frame` of a CPS context or a generator record (step 2e, which must not
  # outlive `Browser.JS.Interp.frame_done/2`), and the parent of a frame. The
  # conservative walk reads every integer as an id, so an array length or a line number
  # that equals the id of a tombstone must not count.
  def dangling(extra) do
    roots =
      :lists.foldl(
        fn
          {k, _}, roots when is_integer(k) -> roots
          {{:js_hoist, _}, _}, roots -> roots
          # (the cache of compiled code holds no heap id)
          {{:jsc, _}, _}, roots -> roots
          {:jsc_budget, _}, roots -> roots
          {:js_memo, _}, roots -> roots
          {:js_freed, _}, roots -> roots
          # (the call chain holds names, positions and depths, never an id)
          {:js_stack, _}, roots -> roots
          {:js_check_stack, _}, roots -> roots
          # (the transition table of the shapes and its counters hold no heap id)
          {{:jst, _}, _}, roots -> roots
          {:js_shape_next, _}, roots -> roots
          # (the counter of the site numbers of the inline caches holds no heap id; the
          # cells have integer keys, so the first clause skips them)
          {:js_ic_next, _}, roots -> roots
          {:js_shape_n, _}, roots -> roots
          {:js_shape_since, _}, roots -> roots
          {:js_arr_iter_pos, _}, roots -> roots
          # (the parser's source table holds token offsets; an offset that equals the id of
          # an unreachable closure would make that garbage look live)
          {:js_srctab, _}, roots -> roots
          {:lex_table, _}, roots -> roots
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
    # The scan starts at the root id (element 5), as `mark/2` does. Elements 3 and 4 hold
    # the call chain and the call position. Their integers (depths and line numbers) are
    # not ids, and an object found through them by accident could report a false hit.
    stack = spush_from(t, 5, tuple_size(t), rest, marks)
    scan(spush(elem(t, 0), stack, marks, true), marks)
  end

  # (a shape holds keys, positions and attributes, never a heap id, see `Browser.JS.Shape`)
  defp scan([{:js_shape, _, _, _, _, _, _} | rest], marks), do: scan(rest, marks)

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
          k, v, acc when is_integer(k) ->
            spush(v, acc, marks, false)

          k, v, acc ->
            spush(v, spush(k, acc, marks, false), marks, k in [:parent, :env, :map_scope, :frame])
        end,
        rest,
        t
      )

    scan(stack, marks)
  end

  defp scan([t | rest], marks) when is_function(t) do
    if compiled?(t) do
      scan(rest, marks)
    else
      case :erlang.fun_info(t, :env) do
        {:env, env} -> scan(Enum.reduce(env, rest, &spush(&1, &2, marks, false)), marks)
        _ -> scan(rest, marks)
      end
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

  # `scope?` says whether the edge to `t` holds a scope: a tombstone found there is a hit.
  # Only an integer of 0 or more can be a heap id: a negative integer is the key of the cell
  # of an inline cache.
  defp spush(t, stack, marks, scope?) when is_integer(t) and t >= 0 do
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
  # hold ids. The depths and the lines in the call chain and the line in `call_pos` must not
  # keep a random object alive. The guard names the two record structs: other tuples, such
  # as the function tuple of a WebAssembly instance, can also have a struct in position 2.
  defp mark([t | rest], marks)
       when is_tuple(t) and tuple_size(t) >= 5 and
              (is_struct(elem(t, 1), Browser.JS.Resolve.Info) or
                 is_struct(elem(t, 1), Browser.JS.Resolve.Scope)) do
    stack = push_frame_slots(t, 5, tuple_size(t), rest, marks)
    mark(push(elem(t, 0), stack, marks), marks)
  end

  # A shape holds keys, positions and attributes, never a heap id (`Browser.JS.Shape`).
  # The record clause below skips the `shape` field, so the walk gets here only for a shape
  # in another place.
  defp mark([{:js_shape, _, _, _, _, _, _} | rest], marks), do: mark(rest, marks)

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

  # The record of a heap object: the walk skips the fields that hold no id
  # (`Browser.JS.Obj.no_refs?/1`). They hold counts, which the walk would read as ids, keys
  # that `props` or the shape also holds, and the shape. The values of a fast record are
  # in the tuple `vals`, which the walk visits as any tuple.
  defp mark([t | rest], marks) when Obj.heap_record?(t) do
    stack =
      :maps.fold(
        fn
          k, _v, acc when Obj.no_refs?(k) -> acc
          _k, v, acc -> push(v, acc, marks)
        end,
        rest,
        t
      )

    mark(stack, marks)
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
    if compiled?(t) do
      mark(rest, marks)
    else
      case :erlang.fun_info(t, :env) do
        {:env, env} -> mark(push_list(env, rest, marks), marks)
        _ -> mark(rest, marks)
      end
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

  # A heap id is marked when it is first reached, and its entry is looked at then. Only an
  # integer of 0 or more can be a heap id: a negative integer (a JS value, a count) is the
  # key of the cell of an inline cache, which must not be walked as an object.
  defp push(t, stack, marks) when is_integer(t) and t >= 0 do
    case :erlang.get(t) do
      :undefined ->
        stack

      # A tombstone of check mode is a freed frame, not a live entry. The walk reads any
      # integer as an id, so a stray number must not keep a tombstone or count it as live.
      # The dangling scan reports a real reference to it.
      {:js_freed, _} ->
        stack

      obj ->
        if mark_new(marks, t), do: [obj | stack], else: stack
    end
  end

  defp push([], stack, _marks), do: stack

  defp push(t, stack, _marks) when is_tuple(t) or is_map(t) or is_list(t) or is_function(t),
    do: [t | stack]

  defp push(_, stack, _marks), do: stack

  # A fun of the compiled code (step 5). It holds only values known at compile time: no
  # heap id and no frame id (the capture rule of `Browser.JS.Compile`). So the walk does
  # not go into it, also when a continuation of an async function holds it. Its syntax
  # nodes and slot numbers are integers that the walk would read as ids, and a large body
  # would cost a long walk at each collection.
  @compile {:inline, compiled?: 1}
  defp compiled?(f), do: :erlang.fun_info(f, :module) == {:module, Browser.JS.Compile}
end
