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
    alias Browser.JS.{Builtins, Fast, GC, Interp, Modules, Parser, Props}
    require Browser.JS.Obj, as: Obj
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
    # (`Interp.own_keys/1`) and then the other keys of its `props`, each with its state
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
        {Map.get(o, :class), Map.get(o, :proto), Obj.extensible?(o), Obj.frozen?(o),
         Obj.sealed?(o), Map.get(o, :len)}

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

    describe "the ordered export" do
      # The code under test runs in functions, so an object that only a closure holds must
      # be in the export: a slip in its order or its attributes changes the hash.
      test "an object that only a closure holds is in the export" do
        progs = [
          "function f(){ var o = {a: 1, b: 2}; return () => o } var g = f()",
          "function f(){ var o = {b: 2, a: 1}; return () => o } var g = f()",
          "function f(){ var o = {a: 1}; Object.defineProperty(o, 'a', {configurable: false}); return () => o } var g = f()",
          "function f(){ let o = {a: 1, b: 2}; { let p = [o]; return function(){ return p } } } var g = f()",
          "function f(){ let o = {b: 2, a: 1}; { let p = [o]; return function(){ return p } } } var g = f()"
        ]

        for ids? <- [false, true] do
          heaps = for p <- progs, do: run(p, [], ids: ids?).heap
          assert Enum.all?(heaps, &is_integer/1)
          assert length(Enum.uniq(heaps)) == length(progs)
        end
      end
    end

    describe "the names of the fast paths" do
      # A name that has no place in the code, or a place that the corpus does not get to,
      # turns nothing off, and the oracle then compares the fast path with itself.
      test "the data-model corpus gets to each fast path" do
        rows = Browser.JS.DatamodelCorpus.rows()
        hits = for a <- run_all(rows, [], hits: true), do: a.hits
        total = Enum.reduce(hits, %{}, &Map.merge(&1, &2, fn _, x, y -> x + y end))
        assert Enum.sort(Map.keys(total)) == Enum.sort(Fast.names())

        # (with all fast paths off, no fast path is on anywhere)
        off = for a <- run_all(rows, Fast.names(), hits: true), do: a.hits
        assert Enum.all?(off, &(&1 == %{}))
      end

      test "a wrong name does not compile" do
        assert_raise ArgumentError, "unknown fast path :literall", fn ->
          Code.eval_string("require Browser.JS.Fast; Browser.JS.Fast.on?(:literall)")
        end
      end
    end

    describe "the shadow run" do
      # A JavaScript error that the operation itself throws is a result: the old path and
      # the fast path must throw the same error, and the error of the fast path goes on.
      test "both paths throw the same JavaScript error" do
        result =
          in_process(fn ->
            Interp.init(1_000)
            Builtins.install()
            err = fn msg -> fn -> Interp.throw_error("ReferenceError", msg) end end

            same =
              try do
                Fast.shadow_run(nil, err.("x is not initialized"), err.("x is not initialized"))
              catch
                :throw, {:js_error, e} -> Interp.get(e, "message")
              end

            other =
              try do
                Fast.shadow_run(nil, err.("y"), err.("x"))
              rescue
                e in ArgumentError -> e.message
              end

            fast_gives =
              try do
                Fast.shadow_run(nil, fn -> true end, err.("x"))
              rescue
                e in ArgumentError -> e.message
              end

            {same, other, fast_gives}
          end)

        assert {"x is not initialized", "fast path check: a fast path throws" <> _,
                "fast path check: a fast path gives true, the old path throws" <> _} = result
      end

      # `hasOwnProperty` on a namespace reads the binding, and a binding in its TDZ throws a
      # ReferenceError. A namespace takes the old path of `Object.hasOwn`, so the shadow run
      # does not see it.
      test "hasOwnProperty on a module namespace with a binding in its TDZ" do
        dir = Path.join(System.tmp_dir!(), "js-fast-ns-#{System.unique_integer([:positive])}")
        File.mkdir_p!(dir)
        path = Path.join(dir, "self.js")

        src = ~S"""
        import * as self from './self.js';
        var r = [];
        try { Object.prototype.hasOwnProperty.call(self, 'x') } catch (e) { r.push(e.constructor.name) }
        try { Object.hasOwn(self, 'x') } catch (e) { r.push(e.constructor.name) }
        r.push(Object.hasOwn(self, 'nope'), self.hasOwnProperty === undefined);
        console.log(r.join());
        export let x = 1;
        """

        File.write!(path, src)

        loader =
          {fn spec, base -> {:ok, Path.expand(spec, Path.dirname(base))} end,
           fn p -> {:ok, File.read!(p), p} end}

        console =
          in_process(fn ->
            Interp.init(100_000)
            Builtins.install()
            Modules.reset()
            {:ok, program} = Parser.parse(src, module: true)
            Modules.run(path, path, program, loader)
            Enum.reverse(Process.get(:js_console, []))
          end)

        File.rm_rf!(dir)
        assert [{_, "ReferenceError,ReferenceError,false,true"}] = console
      end
    end
  end
end
