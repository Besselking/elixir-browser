Code.require_file("js_compile_corpus.ex", __DIR__)

defmodule Browser.JS.FastTest do
  # The fast-path oracle of the data-model step. A fast path of the data model is a short way
  # to the result of a generic operation (see `Browser.JS.Fast`). The compile oracle cannot
  # see a wrong fast path, because the tree walker and the compiled code call the same fast
  # paths. This oracle turns the fast paths off with the process key `:js_fast_off`, which
  # only the check build reads, so the tests run only in the check build
  # (`JS_RESOLVE_CHECK=1`, tag `:check`). In the check build each hit of a fast path also
  # runs the old path and compares (the shadow run of `Browser.JS.Fast.shadow/3`), so a
  # fast path that drifts from the generic code fails here too.
  #
  # Each program of the compile corpus and of the data-model corpus
  # (`Browser.JS.DatamodelCorpus`) runs two times in one VM:
  #
  #   1. all fast paths off, then all on: the result, the console, the steps left, the
  #      positions and the ordered export of the heap must agree. An object of the export
  #      has the name of the order of its first visit, because a fast path can make fewer
  #      objects (`hasOwnProperty` makes no descriptor);
  #   2. all off, then all on except `:has_own`: the heap ids and the heap count must agree
  #      too, and the export names an object by its id.
  #
  # Each comparison runs one more time with a forced collection before each top-level
  # statement, as the step 5 oracle does.
  use ExUnit.Case, async: false

  @check Application.compile_env(:browser, :js_resolve_check, false)

  @moduletag :check
  @moduletag timeout: 1_800_000

  if @check do
    alias Browser.JS.{Builtins, Fast, GC, Interp, Parser, Props}
    alias Browser.JS.CompileTest.Corpus

    @file_name "t.js"
    @programs Corpus.programs(__DIR__)

    # ── the runner ───────────────────────────────────────────

    # Runs each program with the fast paths in `off_a` off, then with those in `off_b` off,
    # and gives the triples of program and outcomes.
    defp both(programs, off_a, off_b, opts) do
      a = run_all(programs, off_a, opts)
      b = run_all(programs, off_b, opts)
      Enum.zip([programs, a, b])
    end

    defp run_all(programs, off, opts) do
      programs
      |> Task.async_stream(fn {_, src, o} -> run(src, off, Keyword.merge(opts, o)) end,
        timeout: :infinity,
        ordered: true,
        max_concurrency: System.schedulers_online()
      )
      |> Enum.map(fn {:ok, outcome} -> outcome end)
    end

    # Runs one program in a fresh process with the fast paths in `off` off. The options are
    # `:max_steps` (default 1_000_000), `:gc` (a forced collection before each top-level
    # statement after the first) and `:ids` (the export names an object by its id, and the
    # outcome has the heap counters).
    defp run(src, off, opts) do
      case Parser.parse(src, resolve: 4, file: @file_name) do
        {:error, msg} ->
          %{syntax: msg}

        {:ok, program} ->
          program = if opts[:gc], do: with_gc(program), else: program
          in_process(fn -> execute(program, off, opts) end)
      end
    end

    defp in_process(fun) do
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

    defp execute(program, off, opts) do
      Process.put(:js_fast_off, off)
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

      items =
        if opts[:ids],
          do: Map.merge(items, %{next: :erlang.get(:js_next), heap_n: :erlang.get(:js_heap_n)}),
          else: items

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

    # The heap as the program left it, from the variables of the global scope (the global
    # object is one of them, `globalThis`): for each object that the walk reaches, its class,
    # its prototype, its own enumerable string keys in their order (`Interp.own_keys/1`) and
    # then the other keys of its `props`, each with its state (`Props.own_state/2`: the value
    # and the attributes). The walk reads no getter and calls no trap, so it runs no
    # JavaScript code, and it makes no object. A proxy is not walked. An object has the name
    # of the order of its first visit, or its id when `ids?` is true. The export is a hash,
    # so that the runs of all programs fit in memory.
    defp heap_export(ids?) do
      roots = Interp.deref(Interp.global()).vars |> Enum.sort()
      ids = refs(roots, [])

      {names, n} =
        Enum.reduce(ids, {%{}, 0}, fn r, {nm, k} ->
          if is_map_key(nm, r), do: {nm, k}, else: {Map.put(nm, r, k), k + 1}
        end)

      queue = ids |> Enum.uniq() |> :queue.from_list()
      {entries, names} = walk(queue, names, n, [], ids?)
      name = fn r -> if ids?, do: {:id, r}, else: {:ref, Map.fetch!(names, r)} end
      :erlang.phash2({rename(roots, name), entries}, 4_294_967_296)
    end

    defp walk(queue, names, n, acc, ids?) do
      case :queue.out(queue) do
        {:empty, _} ->
          {Enum.reverse(acc), names}

        {{:value, id}, queue} ->
          {entry, refs} = entry(id)

          {queue, names, n} =
            Enum.reduce(refs, {queue, names, n}, fn r, {q, nm, k} ->
              if is_map_key(nm, r),
                do: {q, nm, k},
                else: {:queue.in(r, q), Map.put(nm, r, k), k + 1}
            end)

          name = fn r -> if ids?, do: {:id, r}, else: {:ref, Map.fetch!(names, r)} end

          entry =
            case rename(entry, name) do
              {head, enumerable, other} -> {head, enumerable, Enum.sort(other)}
              e -> e
            end

          walk(queue, names, n, [{name.(id), entry} | acc], ids?)
      end
    end

    # The entry of one object, with its references as `{:obj, id}`, and the list of the ids
    # that it refers to, in order.
    defp entry(id) do
      o = Interp.deref(id)
      obj = {:obj, id}

      head =
        {Map.get(o, :class), Map.get(o, :proto), Map.get(o, :ext, true), Map.get(o, :frozen),
         Map.get(o, :sealed), Map.get(o, :len)}

      entry =
        if is_map_key(o, :proxy) do
          {head, :proxy}
        else
          enumerable = Interp.own_keys(obj)
          other = Map.keys(o.props) -- enumerable

          # (a private name holds a reference, which differs between two runs, so it goes
          # out of the export; the other keys are sorted after the objects get their names)
          {head, for(k <- enumerable, do: {k, state(obj, k)}),
           for(k <- other, do: {private(k), state(obj, k)})}
        end

      {entry, refs(entry, [])}
    end

    defp private({:private, _}), do: :private
    defp private(k), do: k

    defp state(obj, key) do
      Props.own_state(obj, key)
    catch
      kind, reason -> {:state_failed, kind, inspect(reason, limit: 6)}
    end

    defp refs({:obj, id}, acc), do: [id | acc]

    defp refs(t, acc) when is_tuple(t),
      do: t |> Tuple.to_list() |> Enum.reverse() |> Enum.reduce(acc, &refs/2)

    defp refs([h | t], acc), do: refs(h, refs(t, acc))
    defp refs(_, acc), do: acc

    defp rename({:obj, id}, name), do: name.(id)

    defp rename(t, name) when is_tuple(t),
      do: t |> Tuple.to_list() |> Enum.map(&rename(&1, name)) |> List.to_tuple()

    defp rename(l, name) when is_list(l), do: Enum.map(l, &rename(&1, name))
    defp rename(v, _), do: v

    # ── the comparison ───────────────────────────────────────

    defp assert_same(triples, what) do
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

    describe "the fast-path oracle" do
      test "all fast paths off, then on: result, console, steps and ordered export agree" do
        assert length(@programs) > 600
        assert_same(both(@programs, Fast.names(), [], []), "with the fast paths on")
      end

      test "the same with a forced collection before each top-level statement" do
        assert_same(both(@programs, Fast.names(), [], gc: true), "with the forced collections")
      end

      test "all off, then all on but :has_own: the heap ids and the heap count agree too" do
        assert_same(
          both(@programs, Fast.names(), [:has_own], ids: true),
          "with the fast paths on but :has_own"
        )
      end

      test "the same with a forced collection before each top-level statement, with ids" do
        assert_same(
          both(@programs, Fast.names(), [:has_own], ids: true, gc: true),
          "with the forced collections, with ids"
        )
      end

      test "the switch turns a fast path off: hasOwnProperty makes its descriptors again" do
        src =
          "function f(){ var o = {a: 1}, n = 0; for (var i = 0; i < 10; i++) if (o.hasOwnProperty('a')) n++; return n } f()"

        [{_, off, on}] = both([{"has own", src, []}], Fast.names(), [], ids: true)
        assert off.result == {:ok, 10.0} and on.result == {:ok, 10.0}
        assert off.next == on.next + 10
      end

      test "the runner reports results, errors, the console and the export" do
        # A broken runner gives one outcome for every program and so passes the oracle.
        outcomes = for {_, a, _} <- both(Browser.JS.DatamodelCorpus.rows(), [], [], []), do: a

        assert Enum.all?(outcomes, &match?(%{console: [_ | _], heap: h} when is_integer(h), &1))
        assert outcomes |> Enum.map(& &1.heap) |> Enum.uniq() |> length() > 3
        assert outcomes |> Enum.map(& &1.console) |> Enum.uniq() |> length() == length(outcomes)
      end
    end
  end
end
