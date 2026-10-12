defmodule Browser.JS.HeapOracle do
  # The runner and the ordered export of the heap of the data-model oracles: the fast-path
  # oracle (`js_fast_test.exs`, fast paths off and on), the shapes oracle
  # (`js_shapes_test.exs`, fast records off and on) and the form oracle of the elements
  # (`js_elems_form_test.exs`, all arrays sparse, then the dense form). Each oracle runs the
  # same programs two times in one VM with a different setting, and compares the outcomes.
  #
  # The setting is a function that runs in the process of the program before
  # `Interp.init/1`: it puts the process keys of the setting (`:js_fast_off`, `:js_shapes`,
  # `:js_elems_sparse`).
  @moduledoc false

  import ExUnit.Assertions
  alias Browser.JS.{Builtins, GC, Interp, Parser, Props}
  require Browser.JS.Obj, as: Obj
  require Browser.JS.Elems

  @file_name "t.js"

  # ── the runner ───────────────────────────────────────────

  @doc """
  Runs each program with the setting `a`, then with the setting `b`, and gives the triples
  of program and outcomes.
  """
  def both(programs, a, b, opts) do
    outcomes_a = run_all(programs, a, opts)
    outcomes_b = run_all(programs, b, opts)
    Enum.zip([programs, outcomes_a, outcomes_b])
  end

  @doc "Runs each program with the setting `setup` and gives the outcomes in order."
  def run_all(programs, setup, opts) do
    programs
    |> Task.async_stream(fn {_, src, o} -> run(src, setup, Keyword.merge(opts, o)) end,
      timeout: :infinity,
      ordered: true,
      max_concurrency: System.schedulers_online()
    )
    |> Enum.map(fn {:ok, outcome} -> outcome end)
  end

  @doc """
  Runs one program in a fresh process with the setting `setup`. The options are
  `:max_steps` (default 1_000_000), `:gc` (a forced collection before each top-level
  statement after the first), `:ids` (the export names an object by its id, and the
  outcome has the heap counters), `:hits` (the outcome has the counts of the fast paths)
  and `:after` (a function that runs at the end, in the process of the program; its
  result is the item `after` of the outcome).
  """
  def run(src, setup, opts) do
    case Parser.parse(src, resolve: 4, file: @file_name) do
      {:error, msg} ->
        %{syntax: msg}

      {:ok, program} ->
        program = if opts[:gc], do: with_gc(program), else: program
        in_process(fn -> execute(program, setup, opts) end)
    end
  end

  @doc "Runs `fun` in a fresh process with the options of a JS process, and gives its result."
  def in_process(fun) do
    parent = self()
    ref = make_ref()

    {pid, mon} =
      :erlang.spawn_opt(fn -> send(parent, {ref, fun.()}) end, [
        :monitor | Browser.JS.process_opts()
      ])

    receive do
      {^ref, outcome} ->
        Process.demonitor(mon, [:flush])
        outcome

      {:DOWN, ^mon, _, _, reason} ->
        %{crash: inspect(reason, limit: 30)}
    after
      120_000 ->
        Process.exit(pid, :kill)
        %{timeout: true}
    end
  end

  defp execute(program, setup, opts) do
    setup.()
    if opts[:hits], do: Process.put(:js_fast_hits, %{})
    Interp.init(Keyword.get(opts, :max_steps, 1_000_000))
    Builtins.install()

    if opts[:gc] do
      gc = Interp.native("__gc", fn _this, _args -> collect_last() end)
      Interp.declare(Interp.global(), "__gc", gc)
    end

    result =
      try do
        v = Interp.run_program(program, true)
        Process.put(:fast_test_result, v)
        if opts[:gc], do: GC.collect()

        try do
          Builtins.run_timers(&uncaught/1)
        catch
          :js_limit -> console_line(:warn, "step limit reached while running timers")
        end

        {:ok, v}
      catch
        {:js_error, v} -> {:throw, v}
        :js_limit -> :step_limit
        {:js_illegal, kind} -> {:illegal, kind}
        :js_short -> :short
      end

    # The counters and the export come first: the export of the result can call a getter.
    items = %{
      steps: :erlang.get(:js_steps),
      pos: Process.get(:js_pos),
      throw_pos: Process.get(:js_throw_pos),
      console: Enum.reverse(Process.get(:js_console, [])),
      heap: safely(fn -> heap_export(opts[:ids]) end)
    }

    items = if opts[:hits], do: Map.put(items, :hits, Process.get(:js_fast_hits)), else: items

    items =
      if opts[:ids],
        do: Map.merge(items, %{next: :erlang.get(:js_next), heap_n: :erlang.get(:js_heap_n)}),
        else: items

    items = if f = opts[:after], do: Map.put(items, :after, safely(f)), else: items
    Map.put(items, :result, safely(fn -> outcome(result) end))
  end

  defp collect_last do
    GC.collect()
    Process.get(:js_last, :undefined)
  end

  defp uncaught(v), do: console_line(:error, "Uncaught " <> describe(v))

  defp console_line(level, text),
    do: Process.put(:js_console, [{level, text} | Process.get(:js_console, [])])

  defp outcome({:ok, v}), do: {:ok, export(v, 0)}
  defp outcome({:throw, v}), do: {:throw, describe(v), export(v, 0)}
  defp outcome(other), do: other

  defp safely(fun) do
    fun.()
  catch
    kind, reason -> {:export_failed, kind, inspect(reason, limit: 10)}
  end

  defp describe(v) when is_binary(v), do: v
  defp describe(v), do: Builtins.inspect_js(v, 0, [])

  defp export({:obj, _} = v, depth) do
    cond do
      depth > 20 -> :truncated
      Interp.function?(v) -> :function
      Interp.array?(v) -> v |> Interp.array_list() |> Enum.map(&export(&1, depth + 1))
      true -> Map.new(Interp.own_keys(v), &{&1, export(Interp.get(v, &1), depth + 1)})
    end
  end

  defp export(v, _), do: v

  # The program with a call of `__gc()` before each top-level statement after the first.
  defp with_gc({:program, stmts}) do
    {:ok, {:program, gc}} = Parser.parse("__gc();", resolve: 4)
    gc = Enum.reject(gc, &match?({:pos, _}, &1))

    {out, pending, _} =
      Enum.reduce(stmts, {[], [], false}, fn
        {:pos, _} = p, {out, pending, seen?} ->
          {out, [p | pending], seen?}

        s, {out, pending, seen?} ->
          out = if seen?, do: Enum.reverse(gc) ++ out, else: out
          {[s | pending] ++ out, [], true}
      end)

    {:program, Enum.reverse(pending ++ out)}
  end

  # ── the ordered export ───────────────────────────────────

  # The heap as the program left it, from the global scope: for each object that the walk
  # reaches, its class, its prototype, its own enumerable string keys in their order
  # (`Interp.own_keys/1`) and then its other own keys, each with its state
  # (`Props.own_state/2`: the value and the attributes). The walk also goes into the
  # scope of each closure and up its chain, as the collector does, because the code under
  # test runs in functions, and an object that only a closure holds is otherwise not in
  # the export. A scope gives its variables (a map scope) or its slots (a frame). The
  # walk reads no getter and calls no trap, so it runs no JavaScript code, and it makes
  # no object. A proxy is not walked. A node (an object or a scope) has the name of the
  # order of its first visit, or its id when `ids?` is true. The export is a hash, so that
  # the runs of all programs fit in memory.
  defp heap_export(ids?) do
    root = {:scope, Interp.global()}
    {entries, _} = walk(:queue.from_list([root]), %{root => 0}, 1, [], ids?)
    :erlang.phash2(entries, 4_294_967_296)
  end

  defp walk(queue, names, n, acc, ids?) do
    case :queue.out(queue) do
      {:empty, _} ->
        {Enum.reverse(acc), names}

      {{:value, node}, queue} ->
        {entry, refs} = entry(node)

        {queue, names, n} =
          Enum.reduce(refs, {queue, names, n}, fn r, {q, nm, k} ->
            if is_map_key(nm, r),
              do: {q, nm, k},
              else: {:queue.in(r, q), Map.put(nm, r, k), k + 1}
          end)

        name = fn r -> if ids?, do: r, else: {:ref, Map.fetch!(names, r)} end

        entry =
          case rename(entry, name) do
            {head, enumerable, other} -> {head, enumerable, Enum.sort(other)}
            e -> e
          end

        walk(queue, names, n, [{name.(node), entry} | acc], ids?)
    end
  end

  # The entry of one node, with its references as `{:obj, id}` and `{:scope, id}`, and
  # the list of the nodes that it refers to, in order.
  defp entry({:obj, id} = obj) do
    o = Interp.deref(id)

    head =
      {Map.get(o, :class), Map.get(o, :proto), Obj.extensible?(o), Obj.frozen?(o), Obj.sealed?(o),
       if(Map.get(o, :class) == :array, do: Browser.JS.Elems.len(o))}

    entry =
      if is_map_key(o, :proxy) do
        {head, :proxy}
      else
        enumerable = Interp.own_keys(obj)
        other = Obj.all_keys(o) -- enumerable

        # (a private name holds a reference, which differs between two runs, so it goes
        # out of the export; the other keys are sorted after the objects get their names)
        {head, for(k <- enumerable, do: {k, state(obj, k)}),
         for(k <- other, do: {private(k), state(obj, k)})}
      end

    # (the scope and the home of a closure, after the references of the entry)
    closure =
      case o do
        %{fun: {:closure, c}} -> [scope(Map.get(c, :scope)), Map.get(c, :home)]
        _ -> []
      end

    {entry, refs(entry, refs(closure, []))}
  end

  defp entry({:scope, id}) do
    entry =
      case Interp.deref(id) do
        # A frame: `{parent_id, info, chain, call_pos, root_id, slots...}`. The info, the
        # chain and the position hold no value of the program.
        f when is_tuple(f) ->
          slots = f |> Tuple.to_list() |> Enum.drop(5)
          {:frame, scope(elem(f, 0)), slots}

        %{vars: vars} = s ->
          {:scope, scope(Map.get(s, :parent)), Enum.sort(Map.to_list(vars))}

        other ->
          {:other, other}
      end

    {entry, refs(entry, [])}
  end

  defp scope(id) when is_integer(id), do: {:scope, id}
  defp scope(_), do: nil

  defp private({:private, _}), do: :private
  defp private(k), do: k

  defp state(obj, key) do
    Props.own_state(obj, key)
  catch
    kind, reason -> {:state_failed, kind, inspect(reason, limit: 6)}
  end

  defp refs({:obj, id}, acc), do: [{:obj, id} | acc]
  defp refs({:scope, id}, acc), do: [{:scope, id} | acc]

  defp refs(t, acc) when is_tuple(t),
    do: t |> Tuple.to_list() |> Enum.reverse() |> Enum.reduce(acc, &refs/2)

  defp refs([h | t], acc), do: refs(h, refs(t, acc))
  defp refs(m, acc) when is_map(m), do: m |> Map.to_list() |> Enum.sort() |> refs(acc)
  defp refs(_, acc), do: acc

  defp rename({:obj, _} = node, name), do: name.(node)
  defp rename({:scope, _} = node, name), do: name.(node)

  defp rename(t, name) when is_tuple(t),
    do: t |> Tuple.to_list() |> Enum.map(&rename(&1, name)) |> List.to_tuple()

  defp rename(l, name) when is_list(l), do: Enum.map(l, &rename(&1, name))
  defp rename(m, name) when is_map(m), do: Map.new(m, &rename(&1, name))

  # (a fun can hold ids, and a private name of a class scope holds a reference: both
  # differ between two runs, so the export does not go into them)
  defp rename(f, _) when is_function(f), do: :fun
  defp rename(r, _) when is_reference(r), do: :reference
  defp rename(v, _), do: v

  # ── the comparison ───────────────────────────────────────

  @doc """
  Asserts that the two outcomes of each triple of `both/4` are the same. `what` names the
  second setting in the message.
  """
  def assert_same(triples, what) do
    bad =
      for {{name, src, _}, a, b} <- triples, a != b do
        diff =
          for k <- Enum.sort(Enum.uniq(Map.keys(a) ++ Map.keys(b))),
              Map.get(a, k) != Map.get(b, k),
              do:
                "    #{k}: off #{inspect(Map.get(a, k), limit: 12, printable_limit: 300)}\n" <>
                  "    #{String.duplicate(" ", String.length(to_string(k)))}  on  #{inspect(Map.get(b, k), limit: 12, printable_limit: 300)}"

        "#{name}: #{String.slice(src, 0, 160)}\n#{Enum.join(diff, "\n")}"
      end

    assert bad == [],
           "#{length(bad)} of #{length(triples)} programs differ #{what}:\n\n" <>
             Enum.join(Enum.take(bad, 15), "\n\n")
  end
end
