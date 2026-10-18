defmodule Browser.JS.GC do
  @moduledoc """
  A mark-and-sweep collector for the heap in `Browser.JS.Interp`.

  It only runs between timers (`Browser.JS.Builtins.run_next_timer/2`), when no script is on
  the stack, so everything alive is reachable from the process dictionary: the global scope,
  prototypes, timers, microtasks, modules, the DOM's bookkeeping and so on.

  The walk is conservative where it does not know the form of a term: it follows every
  `{:obj, id}` and every integer that is a heap id, in any tuple, list, map and in the
  environment of Elixir funs (the built-ins capture ids, and a frame slot can hold a bare
  id). A stray integer there can keep a dead object alive, but nothing reachable is ever
  freed. A JS value is never a bare heap id (an object is `{:obj, id}`). So in the values of
  the own properties and in the elements of an array, an integer is a number, and the walk
  does not read it as an id. The same is true for the length of a sparse array, and for
  the entries and the counters (`seq`, `order`) of a Map or a Set of the common form. The
  walk matches the common forms of a heap record whole, with the patterns of
  `Browser.JS.Obj` and `Browser.JS.Elems` (see `push_record/3`). Function bodies are syntax
  trees and not walked; only the scope and `home` of a closure are. The compiled code of
  step 5 (the `{:jsc, _}` keys and the funs of `Browser.JS.Compile`) is not walked either:
  it holds no heap id.
  The continuation of a compiled plan of an async body or a generator (step 5c) is a fun
  of `Browser.JS.Async`, so the walk visits it and finds the frame that it keeps. The walk
  stops at the compiled closures in it. The process key `:js_cps_vals` holds the values of
  a lift template only while the template runs, so it is a root like any other key. The
  walk reads the document's state through `Browser.JS.DOM.gc_begin/2`, which leaves out the
  node table and the other fields that hold no JS value. The wrappers and the listeners of
  the nodes are not roots either: the walk goes into them when it finds their node live, and
  the nodes that are not live leave the node table (see "the JS collector and the node
  table" in `Browser.JS.DOM`). A plain integer in the data of a wrapper of the DOM or in the
  environment of an Elixir fun can be the id of a node, and the walk then reads it as a
  reference to the node too (`push_nids/3`). The lexer's tables and the boxes
  of the layout are not roots: they hold offsets and numbers only. The fields of a heap
  record that `Browser.JS.Obj.no_refs?/1` names are not walked: they hold counts and keys,
  and a count must not keep a dead object alive. The cells of the inline
  caches (step A2) are process keys that are negative integers. They are not heap entries
  and not roots: a cell can hold the id of a prototype, and a freed prototype makes the
  cell miss (`Browser.JS.Shape`). The leaf frames of a normal build (the keys from
  `Browser.JS.Interp.leaf_base/0` up) are not heap entries and not roots: no call is live
  during a collect, so the collector erases them.

  It is off unless `:js_gc_at` is set (the page runtime does, `Browser.JS.eval/2` does not,
  since it holds a result across the timers). A threshold of 0 stays 0, so the collector
  runs after each timer: `JS_GC=every` sets this for each process that `enable/0` switches
  on, so that the tests can find a value that only an unwalked field holds.
  """

  import Bitwise
  require Browser.JS.Obj, as: Obj
  require Browser.JS.Elems, as: Elems
  require Browser.JS.Interp, as: Interp
  require Browser.JS.DOM, as: DOM

  @min_collect 100_000

  # (the tags of a node id and of Elixir data on the stack of the walk, see `push_nids/3`)
  @node_tag :"$js_gc_node"
  @nids_tag :"$js_gc_nids"

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
    {ids, roots, node_keys} = classify(Process.get(), {[], [], []})

    # The document's state without the fields that hold no JS value (the node table is
    # large and holds none), the terms that the live root trees of nodes hold, and the bound
    # of the node ids.
    {roots, terms, limit, nodes} =
      case Process.get(:dom) do
        %{nodes: nodes} = s ->
          {root, terms, limit} = dom_begin(s, node_keys)
          {[root | roots], terms, limit, nodes}

        _ ->
          {roots, [], 0, %{}}
      end

    # The marks are a bitmap with one bit for each heap id up to the largest key. A bit costs
    # less than an entry of a table, and it makes no garbage for the process's collector.
    # The bitmap also has a bit for each id below `:js_next`, so that `push_ref/3` can test
    # the bit of a reference before it reads the entry. A second bitmap has the plain
    # integers below `limit` that the walk has looked at as node ids.
    top = max(:lists.max([0 | ids]), :erlang.get(:js_next))

    marks =
      {:atomics.new(div(top, 64) + 1, signed: false),
       :atomics.new(div(limit, 64) + 1, signed: false), limit, nodes}

    # (the nodes that the walk did not find live leave the node table, see
    # `Browser.JS.DOM.gc_sweep/0`)
    try do
      mark(Enum.reduce(roots, push_list(terms, [], marks), &push(&1, &2, marks)), marks)
      if limit > 0, do: DOM.gc_sweep()
    after
      Process.delete(:js_gc_dom)
    end

    {freed, live} = sweep(ids, elem(marks, 0), 0, 0)

    Process.put(:js_freed, :erlang.get(:js_next) - live)
    # (a threshold of 0 is the test setting `JS_GC=every`: it stays)
    if Process.get(:js_gc_at) != 0, do: Process.put(:js_gc_at, max(@min_collect, 2 * live))
    freed
  end

  # The entries of the process dictionary, in three lists: the heap ids, the roots and the
  # process keys of the nodes. It is a plain recursion, with no fun call for each entry. A
  # heap id is the most common entry, so its clause comes first.
  defp classify([], acc), do: acc

  defp classify([{k, _} | rest], {ids, roots, nk})
       when is_integer(k) and k >= 0 and k < Interp.leaf_base(),
       do: classify(rest, {[k | ids], roots, nk})

  defp classify([{k, v} | rest], acc), do: classify(rest, classify_key(k, v, acc))

  # (a leaf frame of a normal build, see `Browser.JS.Interp`: no script runs during a
  # collect, so no call holds it. The key is not a heap id, and a bitmap up to it would be
  # too large. The key goes, so that the walk cannot read a number of that size as the id
  # of the old frame.)
  defp classify_key(k, _, acc) when is_integer(k) and k >= Interp.leaf_base(),
    do: erase_key(k, acc)

  # (a negative key is the cell of an inline cache, see `Browser.JS.Shape`: it is not a
  # heap entry, so the sweep must not erase it, and it is not a root, so the id of a
  # prototype in it does not keep the prototype alive)
  defp classify_key(k, _, acc) when is_integer(k), do: acc
  defp classify_key({:js_hoist, _}, _, acc), do: acc
  # (the cache of compiled code holds no heap id, see `Browser.JS.Compile`; its syntax
  # nodes hold slot numbers, which must not keep an object alive)
  defp classify_key({:jsc, _}, _, acc), do: acc
  # (the uids of the entries of each realm, see `Browser.JS.Compile`)
  defp classify_key({:jsc_root, _}, _, acc), do: acc
  # (the count of the code cache holds two integers, which are not heap ids)
  defp classify_key(:jsc_budget, _, acc), do: acc
  defp classify_key(:js_memo, _, acc), do: acc
  # (the memo of the regular expressions holds patterns, texts and byte positions, see
  # `Browser.JS.RegExp`)
  defp classify_key(:js_re_memo, _, acc), do: acc
  defp classify_key(:js_freed, _, acc), do: acc
  # (the call chain holds names, positions and depths, never an id; a depth or a line that
  # equals the id of a dead object must not keep it alive)
  defp classify_key(:js_stack, _, acc), do: acc
  defp classify_key(:js_check_stack, _, acc), do: acc
  # (the transition table of the shapes and its counters hold keys, shapes and integers,
  # never a heap id, see `Browser.JS.Shape`; a count that equals the id of a dead object
  # must not keep it alive)
  defp classify_key({:jst, _}, _, acc), do: acc
  defp classify_key(:js_shape_next, _, acc), do: acc
  defp classify_key(:js_ic_next, _, acc), do: acc
  defp classify_key(:js_shape_n, _, acc), do: acc
  defp classify_key(:js_shape_since, _, acc), do: acc
  # (the positions of the keys of the array iterators hold two prototypes and two built-in
  # functions, which are roots anyway, and shape ids and positions, which are not heap
  # ids, see `Browser.JS.Interp`)
  defp classify_key(:js_arr_iter_pos, _, acc), do: acc
  # (the parser's source table and the lexer's table hold the source, token offsets and
  # tokens: an offset that equals the id of a dead object must not keep it alive)
  defp classify_key(:js_srctab, _, acc), do: acc
  defp classify_key(:lex_table, _, acc), do: acc
  # (a position and the number of the parser's file are integers, see `Browser.JS.Pos`,
  # never a heap id)
  defp classify_key(:js_pos, _, acc), do: acc
  defp classify_key(:js_throw_pos, _, acc), do: acc
  defp classify_key(:js_file_id, _, acc), do: acc
  # (the boxes of the layout and the counts of the forced layouts hold numbers only, see
  # `Browser.JS.DOM`)
  defp classify_key(:dom_page_rects, _, acc), do: acc
  defp classify_key(:dom_forced_rects, _, acc), do: acc
  defp classify_key(:dom_forced, _, acc), do: acc
  defp classify_key(:dom_forced_spent, _, acc), do: acc
  # (the document's state is read in `collect/0`, see `Browser.JS.DOM.gc_begin/2`)
  defp classify_key(:dom, v, acc) when is_map(v), do: acc
  # (the process keys of a node are walked when the node is live)
  defp classify_key(k, v, {ids, roots, nk}) when DOM.gc_node_key?(k),
    do: {ids, roots, [{k, v} | nk]}

  defp classify_key(_, v, {ids, roots, nk}), do: {ids, [v | roots], nk}

  # The sweep: each heap id whose bit is not set goes. It is a plain recursion, with no fun
  # call for each entry.
  defp sweep([], _bits, freed, live), do: {freed, live}

  defp sweep([id | ids], bits, freed, live) do
    if marked?(bits, id) do
      sweep(ids, bits, freed, live + 1)
    else
      :erlang.erase(id)
      sweep(ids, bits, freed + 1, live)
    end
  end

  # (the erase of a leaf frame in `classify_key/3`)
  defp erase_key(k, acc) do
    :erlang.erase(k)
    acc
  end

  @compile {:inline, marked?: 2}
  defp marked?(bits, id), do: (:atomics.get(bits, (id >>> 6) + 1) &&& 1 <<< (id &&& 63)) != 0

  # Sets the bit of `id` in the bitmap `bits`; false when it was set before. For the heap
  # bitmap, only a key of the process dictionary gets here, so the bitmap has a bit for it.
  @compile {:inline, mark_new: 2}
  defp mark_new(bits, id) do
    i = (id >>> 6) + 1
    bit = 1 <<< (id &&& 63)
    word = :atomics.get(bits, i)

    if (word &&& bit) == 0 do
      :atomics.put(bits, i, word ||| bit)
      true
    else
      false
    end
  end

  defp dom_begin(s, node_keys) do
    if @check, do: check_no_values(DOM.gc_left_out(s))
    DOM.gc_begin(s, node_keys)
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
          {{:jsc_root, _}, _}, roots -> roots
          {:jsc_budget, _}, roots -> roots
          {:js_memo, _}, roots -> roots
          {:js_re_memo, _}, roots -> roots
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
          # (a position and the number of a file are integers, never a heap id)
          {:js_pos, _}, roots -> roots
          {:js_throw_pos, _}, roots -> roots
          {:js_file_id, _}, roots -> roots
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

  # The id of a node that the walk found (`push_nids/3`): when the node was not live, its
  # tree is live now, and the walk goes on into what the tree holds
  # (`Browser.JS.DOM.gc_reach/1`).
  defp mark([{@node_tag, nid} | rest], marks),
    do: mark(push_list(DOM.gc_reach(nid), rest, marks), marks)

  # Elixir data (see `push_nids/3`): the terms in it are Elixir data too, until the walk
  # comes to a heap entry or to a term that `mark/2` knows.
  defp mark([{@nids_tag, t} | rest], marks), do: mark(expand_nids(t, rest, marks), marks)

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
  # The record clauses below skip the `shape` field, so the walk gets here only for a shape
  # in another place.
  defp mark([{:js_shape, _, _, _, _, _, _} | rest], marks), do: mark(rest, marks)

  defp mark([t | rest], marks) when is_tuple(t),
    do: mark(push_tuple(t, tuple_size(t), rest, marks), marks)

  defp mark([[] | rest], marks), do: mark(rest, marks)
  defp mark([[_ | _] = l | rest], marks), do: mark(push_list(l, rest, marks), marks)

  # The record of a heap object (`push_record/3`): the most common term on the stack, so
  # its clause comes before the other maps (a closure and the facts of the resolver have
  # no class).
  defp mark([t | rest], marks) when Obj.heap_record?(t),
    do: mark(push_record(t, rest, marks), marks)

  # the resolver's facts hold names, numbers, atoms and syntax, never a heap id:
  # a frame carries one in its header, so the walk must not read it as ids
  defp mark([%Browser.JS.Resolve.Info{} | rest], marks), do: mark(rest, marks)
  defp mark([%Browser.JS.Resolve.Scope{} | rest], marks), do: mark(rest, marks)

  defp mark([%{params: _, body: _} = closure | rest], marks) do
    stack = push(Map.get(closure, :scope), rest, marks)
    mark(push(Map.get(closure, :home), stack, marks), marks)
  end

  # (integer keys are array indices: skip them, not references)
  defp mark([t | rest], marks) when is_map(t),
    do: mark(push_pairs(:maps.to_list(t), rest, marks), marks)

  defp mark([t | rest], marks) when is_function(t), do: mark(mark_fun(t, rest, marks), marks)

  defp mark([_ | rest], marks), do: mark(rest, marks)

  # (the elements of a frame from the 1-based position `i` to `n`)
  defp push_frame_slots(_t, i, n, stack, _marks) when i > n, do: stack

  defp push_frame_slots(t, i, n, stack, marks),
    do: push_frame_slots(t, i + 1, n, push(elem(t, i - 1), stack, marks), marks)

  # The record of a heap object. The common forms are matched whole: the patterns of
  # `Browser.JS.Obj.fast_whole/3` and `Browser.JS.Elems.dense/1`, with the guard on the
  # size that says that the record has no other field. So the walk makes no list of the
  # fields for them. The values of the own properties and the elements are JS values, and a
  # JS value is never a bare heap id (an object is `{:obj, id}`): an integer there is a
  # number, which the walk does not look up (`push_val/3`). A record of another form goes
  # through `push_fields/3`, with the same rules for the fields that it knows.
  defp push_record(Obj.fast_whole(p, v) = t, stack, marks) when Obj.fast_whole?(t, 0),
    do: push_vals(v, tuple_size(v), push(p, stack, marks), marks)

  defp push_record(Obj.fast_whole(p, v, fun: f) = t, stack, marks) when Obj.fast_whole?(t, 1),
    do: push_vals(v, tuple_size(v), push_fun(f, push(p, stack, marks), marks), marks)

  # A Map, a Set, a WeakMap or a WeakSet (`Browser.JS.Collections`): the entries are under
  # `data`, each `{seq, key, value}` with the key and the value JS values. The key of the
  # map is the SameValueZero form of the key, which the entry holds too. `seq` and the
  # positions in `order` are counters, not ids, and `order` holds the keys of `data` again.
  defp push_record(
         %{class: c} = Obj.fast_whole(p, v, data: d, seq: _, order: _) = t,
         stack,
         marks
       )
       when Obj.fast_whole?(t, 3) and c in [:map, :set, :weakmap, :weakset] and is_map(d),
       do: push_vals(v, tuple_size(v), push_entries(d, push(p, stack, marks), marks), marks)

  defp push_record(Obj.fast_whole(p, v) = Elems.dense(vec) = t, stack, marks)
       when Obj.fast_whole?(t, 1) do
    stack = push_vals(v, tuple_size(v), push(p, stack, marks), marks)
    push_vals(vec, tuple_size(vec), stack, marks)
  end

  # (the data of a wrapper of the DOM: a node id, or a tuple that holds one)
  defp push_record(Obj.fast_whole(p, v, host: {DOM, data}) = t, stack, marks)
       when Obj.fast_whole?(t, 1),
       do: push_vals(v, tuple_size(v), push_nids(data, push(p, stack, marks), marks), marks)

  defp push_record(t, stack, marks), do: push_fields(:maps.to_list(t), stack, marks)

  # (the entries of a Map or a Set, see above; an entry of another form is walked whole)
  defp push_entries(d, stack, marks) do
    :maps.fold(
      fn
        _nk, {_seq, k, v}, acc -> push_val(k, push_val(v, acc, marks), marks)
        nk, other, acc -> push(other, push(nk, acc, marks), marks)
      end,
      stack,
      d
    )
  end

  # The function of a function record: a closure keeps its scope and its home object, a
  # native its Elixir fun (whose environment can hold ids). The walk does this at once,
  # without the tuple on the stack. Any other form is walked whole.
  defp push_fun({:closure, %{scope: sc} = c}, stack, marks),
    do: push(Map.get(c, :home), push(sc, stack, marks), marks)

  defp push_fun({:native, _name, f}, stack, marks) when is_function(f),
    do: mark_fun(f, stack, marks)

  defp push_fun(f, stack, marks), do: push(f, stack, marks)

  # (the elements of a tuple of JS values, from the position `n` down to 1)
  defp push_vals(_t, 0, stack, _marks), do: stack

  defp push_vals(t, n, stack, marks),
    do: push_vals(t, n - 1, push_val(:erlang.element(n, t), stack, marks), marks)

  # (the values of a map of JS values: the keys are strings, symbols or indices)
  defp push_items(m, stack, marks),
    do: :maps.fold(fn _k, v, acc -> push_val(v, acc, marks) end, stack, m)

  # A JS value: an object is `{:obj, id}`, an accessor `{:accessor, getter, setter}`. A
  # number (also an integer), a string, a boolean, null and undefined lead to no heap
  # entry. A tuple (an accessor, a symbol) goes on the stack, where the walk reads it as
  # any tuple.
  @compile {:inline, push_val: 3}
  defp push_val({:obj, id}, stack, marks) when is_integer(id) and id >= 0,
    do: push_ref(id, stack, marks)

  defp push_val(t, stack, _marks)
       when is_tuple(t) or is_map(t) or is_list(t) or is_function(t),
       do: [t | stack]

  defp push_val(_, stack, _marks), do: stack

  # The fields of a heap record of another form, as `:maps.to_list/1` gives them: one call
  # of a built-in function, which is faster than a fold with a fun. The walk skips the
  # fields that hold no id (`Browser.JS.Obj.no_refs?/1`, `Browser.JS.Elems.no_refs?/1`):
  # they hold counts, which the walk would read as ids, keys that `props` or the shape also
  # holds, the shape, and the length of a sparse array. The values of the own properties and
  # the elements (a tuple or a map) are JS values (see `push_record/3`).
  defp push_fields([], stack, _marks), do: stack

  defp push_fields([{k, v} | fs], stack, marks)
       when (Obj.values_field?(k) or Elems.elements_field?(k)) and is_tuple(v),
       do: push_fields(fs, push_vals(v, tuple_size(v), stack, marks), marks)

  defp push_fields([{k, m} | fs], stack, marks)
       when (Obj.values_field?(k) or Elems.elements_field?(k)) and is_map(m),
       do: push_fields(fs, push_items(m, stack, marks), marks)

  defp push_fields([{k, _} | fs], stack, marks) when Obj.no_refs?(k) or Elems.no_refs?(k),
    do: push_fields(fs, stack, marks)

  # (the data of a wrapper of the DOM: a node id, or a tuple that holds one)
  defp push_fields([{:host, {DOM, data}} | fs], stack, marks),
    do: push_fields(fs, push_nids(data, stack, marks), marks)

  defp push_fields([{_, v} | fs], stack, marks), do: push_fields(fs, push(v, stack, marks), marks)

  # The keys and the values of any other map, without the integer keys.
  defp push_pairs([], stack, _marks), do: stack

  defp push_pairs([{k, v} | ps], stack, marks) when is_integer(k),
    do: push_pairs(ps, push(v, stack, marks), marks)

  defp push_pairs([{k, v} | ps], stack, marks),
    do: push_pairs(ps, push(v, push(k, stack, marks), marks), marks)

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
  defp push(t, stack, marks) when is_integer(t) and t >= 0, do: push_id(t, stack, marks)

  # A reference `{:obj, id}` is the term that the walk meets most: its id is marked at
  # once, so the tuple does not go on the stack. Its id is a heap id only, not a node id.
  defp push({:obj, id}, stack, marks) when is_integer(id) and id >= 0,
    do: push_ref(id, stack, marks)

  defp push([], stack, _marks), do: stack

  defp push(t, stack, _marks) when is_tuple(t) or is_map(t) or is_list(t) or is_function(t),
    do: [t | stack]

  defp push(_, stack, _marks), do: stack

  # A heap id is marked when it is first reached, and its entry is looked at then. Only an
  # integer of 0 or more can be a heap id: a negative integer (a JS value, a count) is the
  # key of the cell of an inline cache, which must not be walked as an object.
  defp push_id(t, stack, marks) when t >= 0 do
    case :erlang.get(t) do
      :undefined ->
        stack

      # A tombstone of check mode is a freed frame, not a live entry. The walk reads any
      # integer as an id, so a stray number must not keep a tombstone or count it as live.
      # The dangling scan reports a real reference to it.
      {:js_freed, _} ->
        stack

      obj ->
        if mark_new(elem(marks, 0), t), do: [obj | stack], else: stack
    end
  end

  defp push_id(_t, stack, _marks), do: stack

  # The id of a reference `{:obj, id}`. Most references (a prototype, a scope) are met many
  # times, so the walk tests the bit first and reads the entry only the first time. The
  # bitmap has a bit for each id below `:js_next` (see `collect/0`), and a reference holds
  # only such an id.
  defp push_ref(id, stack, marks) do
    bits = elem(marks, 0)
    i = (id >>> 6) + 1
    bit = 1 <<< (id &&& 63)
    word = :atomics.get(bits, i)

    if (word &&& bit) == 0 do
      case :erlang.get(id) do
        :undefined ->
          stack

        # (a tombstone of check mode, see `push_id/3`)
        {:js_freed, _} ->
          stack

        obj ->
          :atomics.put(bits, i, word ||| bit)
          [obj | stack]
      end
    else
      stack
    end
  end

  # Elixir data that can hold node ids: the data of a wrapper of the DOM and the environment
  # of an Elixir fun (a native can hold a node id). In it, a plain integer can also be the id
  # of a node (see "the JS collector and the node table" in `Browser.JS.DOM`). The walk looks
  # an integer below the bound of the node ids up in the node table the first time it finds
  # it, and a node goes on the stack. A JS value never holds a node id (a script reaches a
  # node only through its wrapper), so a number in a slot, a property or an element does not
  # keep a node alive. The process keys hold counters, heap ids and sets of node ids that
  # must not keep a node alive (the scripts that ran), so they are not Elixir data here: the
  # node ids that the state of the document holds are roots of their own
  # (`Browser.JS.DOM.gc_begin/2`), and the funs in the process keys are walked as funs.
  defp push_nids(t, stack, marks) when is_integer(t) and t >= 0 do
    push_id(t, push_node(t, stack, marks), marks)
  end

  defp push_nids({:obj, id}, stack, marks) when is_integer(id), do: push_id(id, stack, marks)
  defp push_nids([], stack, _marks), do: stack

  defp push_nids(t, stack, _marks) when is_tuple(t) or is_map(t) or is_list(t) or is_function(t),
    do: [{@nids_tag, t} | stack]

  defp push_nids(_, stack, _marks), do: stack

  @compile {:inline, push_node: 3}
  defp push_node(t, stack, marks) do
    if t < elem(marks, 2) and mark_new(elem(marks, 1), t) and is_map_key(elem(marks, 3), t),
      do: [{@node_tag, t} | stack],
      else: stack
  end

  # One level of Elixir data. A frame, a heap record, a closure and a struct (the facts of
  # the resolver) go to `mark/2`, which knows them; a shape holds no id. An integer key of a
  # map can be a node id, but it is not a heap id (see `push_pairs/3`).
  defp expand_nids(t, stack, _marks)
       when (is_tuple(t) and tuple_size(t) >= 5 and
               (is_struct(elem(t, 1), Browser.JS.Resolve.Info) or
                  is_struct(elem(t, 1), Browser.JS.Resolve.Scope))) or
              Obj.heap_record?(t) or is_struct(t) or
              (is_map(t) and is_map_key(t, :params) and is_map_key(t, :body)),
       do: [t | stack]

  defp expand_nids({:js_shape, _, _, _, _, _, _}, stack, _marks), do: stack

  defp expand_nids(t, stack, marks) when is_tuple(t),
    do: :lists.foldl(&push_nids(&1, &2, marks), stack, Tuple.to_list(t))

  defp expand_nids([h | t], stack, marks) when is_list(t),
    do: expand_nids(t, push_nids(h, stack, marks), marks)

  defp expand_nids([h | t], stack, marks), do: push_nids(t, push_nids(h, stack, marks), marks)
  defp expand_nids([], stack, _marks), do: stack

  defp expand_nids(t, stack, marks) when is_map(t) do
    :maps.fold(
      fn
        k, v, acc when is_integer(k) and k >= 0 -> push_nids(v, push_node(k, acc, marks), marks)
        k, v, acc when is_integer(k) -> push_nids(v, acc, marks)
        k, v, acc -> push_nids(v, push_nids(k, acc, marks), marks)
      end,
      stack,
      t
    )
  end

  defp expand_nids(t, stack, marks) when is_function(t), do: mark_fun(t, stack, marks)

  # The environment of a fun, as Elixir data (a native can hold a node id), but not the
  # environment of a fun of the compiled code.
  defp mark_fun(t, stack, marks) do
    if compiled?(t) do
      stack
    else
      case :erlang.fun_info(t, :env) do
        {:env, env} -> :lists.foldl(&push_nids(&1, &2, marks), stack, env)
        _ -> stack
      end
    end
  end

  # A fun of the compiled code (step 5). It holds only values known at compile time: no
  # heap id and no frame id (the capture rule of `Browser.JS.Compile`). So the walk does
  # not go into it, also when a continuation of an async function holds it. Its syntax
  # nodes and slot numbers are integers that the walk would read as ids, and a large body
  # would cost a long walk at each collection.
  @compile {:inline, compiled?: 1}
  defp compiled?(f), do: :erlang.fun_info(f, :module) == {:module, Browser.JS.Compile}
end
