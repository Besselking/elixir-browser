Code.require_file("js_compile_corpus.ex", __DIR__)
Code.require_file("js_heap_oracle.ex", __DIR__)

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
    alias Browser.JS.{Builtins, Fast, HeapOracle, Interp, Modules, Parser}
    alias Browser.JS.CompileTest.Corpus
    @programs Corpus.programs(__DIR__)

    # ── the runner ───────────────────────────────────────────
    # (`Browser.JS.HeapOracle` runs the programs and makes the ordered export; the setting
    # of this oracle is the list of the fast paths that are off)

    defp off(names), do: fn -> Process.put(:js_fast_off, names) end

    # Runs each program with the fast paths in `off_a` off, then with those in `off_b` off,
    # and gives the triples of program and outcomes.
    defp both(programs, off_a, off_b, opts),
      do: HeapOracle.both(programs, off(off_a), off(off_b), opts)

    defp run_all(programs, names, opts), do: HeapOracle.run_all(programs, off(names), opts)
    defp run(src, names, opts), do: HeapOracle.run(src, off(names), opts)
    defp in_process(fun), do: HeapOracle.in_process(fun)
    defp assert_same(triples, what), do: HeapOracle.assert_same(triples, what)

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

      test "with :ic off no site writes a cell" do
        rows = for {"dm ic" <> _, _, _} = row <- Browser.JS.DatamodelCorpus.rows(), do: row
        cells = fn -> for({k, c} <- :erlang.get(), is_integer(k) and k < 0, do: c) end
        on = for a <- HeapOracle.run_all(rows, off([]), after: cells), do: a.after
        off = for a <- HeapOracle.run_all(rows, off([:ic]), after: cells), do: a.after
        assert Enum.any?(on, &(&1 != []))
        assert Enum.all?(off, &(&1 == []))
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
