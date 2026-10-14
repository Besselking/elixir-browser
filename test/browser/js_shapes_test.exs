Code.require_file("js_compile_corpus.ex", __DIR__)
Code.require_file("js_heap_oracle.ex", __DIR__)

defmodule Browser.JS.ShapesTest do
  # The oracle of the fast records (data-model step A1, `Browser.JS.Shape`). The process key
  # `:js_shapes` set to `false` turns the fast records off: every record is then a
  # dictionary record, as before step A1. The key is read only where a record is made, so
  # this oracle runs in the normal build and in the check build.
  #
  # Each program of the compile corpus and of the data-model corpus
  # (`Browser.JS.DatamodelCorpus`) runs two times in one VM, with the fast records off and
  # on. The result, the console, the steps left, the positions, the ordered export of the
  # heap (`Browser.JS.HeapOracle`), the heap ids and the heap count must agree: a fast
  # record holds the same properties as a dictionary record, and it makes no object. The
  # comparison runs one more time with a forced collection before each top-level
  # statement, so that a shape, the transition table or a counter that the collector reads
  # as a heap id shows up as a different heap count. For this, the shape ids start past the
  # ids of the built-in objects, which are always live: a shape id is then the id of an
  # object that the program makes, which can be garbage.
  #
  # The other tests look at the records: which ones are fast, the change to dictionary
  # mode at the limits, and the form of each fast record.
  use ExUnit.Case, async: false

  @moduletag timeout: 1_800_000

  alias Browser.JS.{Builtins, GC, HeapOracle, Interp, Parser, Shape}
  alias Browser.JS.CompileTest.Corpus
  require Browser.JS.Obj, as: Obj

  @programs Corpus.programs(__DIR__)

  # The first shape id of the oracle runs: past the ids of the built-in objects.
  @first_sid 700

  defp shapes(on?) do
    fn ->
      Process.put(:js_shapes, on?)
      Process.put(:js_shape_next, @first_sid)
    end
  end

  # The ids of the shapes that have an entry in the transition table.
  defp table_sids, do: for({{:jst, sid}, _} <- :erlang.get(), do: sid)

  # The records of the heap of the process: `{id, record}` for each heap object.
  defp records do
    for {id, o} <- :erlang.get(), is_integer(id), Obj.heap_record?(o), do: {id, o}
  end

  # Runs `src` in a fresh process with the fast records on (or off), and gives the result of
  # `fun`, which runs at the end in that process.
  defp inspect_run(src, fun, on? \\ true) do
    {:ok, program} = Parser.parse(src, resolve: 4, file: "t.js")

    HeapOracle.in_process(fn ->
      Process.put(:js_shapes, on?)
      Interp.init(1_000_000)
      Builtins.install()
      Interp.run_program(program, true)
      fun.()
    end)
  end

  # The record of the global variable `name`.
  defp global_record(name) do
    {:obj, id} = Map.fetch!(Interp.deref(Interp.global()).vars, name)
    Interp.deref(id)
  end

  # Whether the fast record `o` has a form that the record API can read: one value for each
  # key, the index of each key at its position, the bits of each key, and the `enum` list
  # of the enumerable string keys in order, and the flag 8 when a key is a symbol.
  defp well_formed?(%{shape: {:js_shape, sid, index, keys, bits, flags, enum}, vals: vals}) do
    n = tuple_size(vals)
    list = Tuple.to_list(keys)

    is_integer(sid) and is_integer(flags) and map_size(index) == n and tuple_size(keys) == n and
      tuple_size(bits) == n and
      Bitwise.band(flags, 8) != 0 == Enum.any?(list, &match?({:symbol, _, _}, &1)) and
      Enum.all?(Enum.with_index(list, 1), fn {k, i} -> Map.get(index, k) == i end) and
      enum ==
        for(
          {k, i} <- Enum.with_index(list, 1),
          is_binary(k) and Bitwise.band(elem(bits, i - 1), 2) != 0,
          do: k
        )
  end

  describe "the shapes oracle" do
    test "fast records off, then on: the outcomes, the heap ids and the heap count agree" do
      assert length(@programs) > 600

      HeapOracle.assert_same(
        HeapOracle.both(@programs, shapes(false), shapes(true), ids: true),
        "with the fast records on"
      )
    end

    test "the same with a forced collection before each top-level statement" do
      # (the shape ids of the runs must be ids of objects that a program makes)
      assert inspect_run("", fn -> :erlang.get(:js_next) end) < @first_sid

      HeapOracle.assert_same(
        HeapOracle.both(@programs, shapes(false), shapes(true), ids: true, gc: true),
        "with the fast records on and forced collections"
      )
    end

    test "the rows of steps A3 and A4 give the output of node" do
      # (the oracles compare two modes of the engine; this test also finds a fault that
      # gives the same wrong output in the two modes)
      rows = Map.new(Browser.JS.DatamodelCorpus.rows(), fn {name, src, _} -> {name, src} end)
      expected = Browser.JS.DatamodelCorpus.node_output()
      assert length(expected) >= 20

      programs = for {name, _} <- expected, do: {name, Map.fetch!(rows, name), []}

      outputs =
        for out <- HeapOracle.run_all(programs, shapes(true), []),
            do: Enum.map_join(out.console, "\n", fn {_, text} -> text end)

      for {{name, want}, got} <- Enum.zip(expected, outputs),
          do: assert({name, got} == {name, want})
    end

    test "each fast record of the corpus has a correct form, and the switch turns them off" do
      count = fn ->
        rs = records()
        fast = for {_, o} <- rs, Obj.fast?(o), do: o
        {length(fast), Enum.all?(fast, &well_formed?/1)}
      end

      on = HeapOracle.run_all(@programs, shapes(true), after: count)
      off = HeapOracle.run_all(@programs, shapes(false), after: count)

      assert Enum.all?(on, &match?(%{after: {_, true}}, &1))
      assert Enum.sum(for %{after: {n, _}} <- on, do: n) > 10_000
      assert Enum.all?(off, &match?(%{after: {0, true}}, &1))
    end
  end

  describe "the records" do
    test "plain objects, arrays, functions and the built-in objects are fast; the others are not" do
      src = ~S"""
      class K { constructor(){ this.a = 1 } }
      function F(){ this.b = 2 }
      var lit = {x: 1, y: 2}, empty = {}, inst = new K(), fobj = new F();
      var parsed = JSON.parse('{"p":1}'), err = new Error('e'), arr = [1], fn = function(){};
      var made = Object.create(null); made.q = 1;
      """

      {fast, dict} =
        inspect_run(src, fn ->
          names = ~w(lit empty inst fobj parsed err made arr fn)
          Enum.split_with(names, &Obj.fast?(global_record(&1)))
        end)

      assert Enum.sort(fast) == Enum.sort(~w(lit empty inst fobj parsed err made arr fn))
      assert dict == []

      # (the prototypes that the interpreter makes are fast from step A2 on)
      protos =
        inspect_run("function F(){}; class K {}; var p = F.prototype, q = K.prototype", fn ->
          {Obj.fast?(global_record("p")), Obj.fast?(global_record("q"))}
        end)

      assert protos == {true, true}

      # (the built-in objects are fast from step A4 on, and the switch goes back on after
      # them; proxies, host objects and arguments objects stay dictionaries)
      src2 = ~S"""
      var names = ['Math', 'JSON', 'Reflect', 'Array', 'Object', 'op', 'ap', 'fp', 'sp', 'o',
                   'px', 'fpx', 'mp', 'args', 'g'];
      var op = Object.prototype, ap = Array.prototype, fp = Function.prototype;
      var sp = String.prototype, o = {}, px = new Proxy({}, {}), fpx = new Proxy(function(){}, {});
      var mp = new Map(), args = (function(){ return arguments })(1), g = globalThis;
      """

      builtins =
        inspect_run(src2, fn ->
          for n <- ~w(Math JSON Reflect Array Object op ap fp sp o px fpx mp args g),
              do: {n, Obj.fast?(global_record(n))}
        end)

      # (a collection of `new Map()` is the record of `this`, which is fast from step A1 on:
      # its entries are in `data`, not in the shape)
      assert for({n, true} <- builtins, do: n) ==
               ~w(Math JSON Reflect Array Object op ap fp sp o mp)

      # (with the switch off, no record is fast)
      assert inspect_run(src, fn -> Enum.count(records(), &Obj.fast?(elem(&1, 1))) end, false) ==
               0
    end

    test "the application setting :js_shapes false turns the fast records off in each heap" do
      # (JS_SHAPES=0 and `mix js.test262 --shapes off` set it; `Interp.init/1` reads it)
      src = "var o = {a: 1}, a = [1], f = function(){};"
      {:ok, program} = Parser.parse(src, resolve: 4, file: "t.js")

      fast = fn key ->
        HeapOracle.in_process(fn ->
          if key != nil, do: Process.put(:js_shapes, key)
          Interp.init(1_000_000)
          Builtins.install()
          Interp.run_program(program, true)
          {Process.get(:js_shapes), Enum.count(records(), fn {_, o} -> Obj.fast?(o) end)}
        end)
      end

      old = Application.get_env(:browser, :js_shapes)

      try do
        Application.put_env(:browser, :js_shapes, false)
        assert fast.(nil) == {false, 0}
        assert fast.(true) == {false, 0}

        # (with the setting on, a process that set its own switch keeps it)
        Application.put_env(:browser, :js_shapes, true)
        assert fast.(false) == {false, 0}
        assert {nil, n} = fast.(nil)
        assert n > 100

        # (the option of the task sets the setting before it looks for the checkout)
        assert_raise Mix.Error, fn ->
          Mix.Tasks.Js.Test262.run(["--shapes", "off", "--dir", "/nonexistent/test262"])
        end

        assert Application.get_env(:browser, :js_shapes) == false
      after
        if old == nil,
          do: Application.delete_env(:browser, :js_shapes),
          else: Application.put_env(:browser, :js_shapes, old)
      end
    end

    test "a new process gets the shapes of the realm from a copy in the VM" do
      # (a process with its own counter makes the realm itself, as the first process did)
      install = fn setup ->
        HeapOracle.in_process(fn ->
          setup.()
          Interp.init(1_000_000)
          {_, r0} = Process.info(self(), :reductions)
          Builtins.install()
          {_, r1} = Process.info(self(), :reductions)
          table = Map.new(for {{:jst, _}, _} = e <- :erlang.get(), do: e)
          {:ok, program} = Parser.parse("var o = {zz9: 1};", resolve: 4, file: "t.js")
          Interp.run_program(program, true)
          {:js_shape, sid, _, _, _, _, _} = Obj.shape(global_record("o"))
          {table, Process.get(:js_shape_n), r1 - r0, sid}
        end)
      end

      {cold, cold_n, cold_r, _} = install.(fn -> Process.put(:js_shape_next, 1) end)
      _ = install.(fn -> :ok end)
      {entries, counters} = :persistent_term.get({Shape, :realm, :install})
      {warm, warm_n, warm_r, sid} = install.(fn -> :ok end)

      # (the same table as a cold build, a new shape past the copy, and less work)
      assert warm == cold
      assert Map.new(entries) == warm
      assert warm_n == cold_n
      assert sid >= Keyword.fetch!(counters, :js_shape_next)
      assert warm_r < cold_r
    end

    test "a built-in prototype stays exact at the limits of its shape" do
      # (a polyfill that adds many keys passes the limit of 128 keys: `Array.prototype`
      # goes to dictionary mode, and every key stays)
      src = ~S"""
      for (var i = 0; i < 130; i++) if (!Array.prototype['poly' + i]) Array.prototype['poly' + i] = i;
      var r = [[].poly0, [].poly129, typeof [].push, [3, 1, 2].sort().join()].join();
      """

      result =
        inspect_run(src, fn ->
          {Obj.fast?(Interp.deref(elem(Interp.proto(:array), 1))),
           Interp.get(global("r"), "length"), global("r")}
        end)

      assert result == {false, 20.0, "0,129,function,1,2,3"}

      # (each new heap of one process gives `Object.prototype` the same shape; a new key
      # in each heap makes a new child of that shape, and past 64 children the add makes
      # `Object.prototype` a dictionary, which reads the same)
      results =
        HeapOracle.in_process(fn ->
          for i <- 1..70 do
            Interp.init(1_000_000)
            Builtins.install()
            run_here("Object.prototype.k#{i} = #{i}; var r = ({}).k#{i} + [].k#{i};")
            {Obj.fast?(Interp.deref(elem(Interp.proto(:object), 1))), global("r")}
          end
        end)

      assert Enum.all?(results, fn {_, r} -> is_float(r) end)
      assert for({_, r} <- results, do: trunc(r)) == for(i <- 1..70, do: 2 * i)
      {fast, dict} = Enum.split_while(results, &elem(&1, 0))
      assert length(fast) in 60..66 and Enum.all?(dict, &(not elem(&1, 0)))
    end

    test "objects with the same keys in the same order share one shape" do
      src = ~S"""
      function P(){ this.a = 1; this.b = 2 }
      var x = new P(), y = new P(), z = {a: 3, b: 4}, w = {}; w.a = 5; w.b = 6;
      var other = {b: 1, a: 2}, frozen1 = Object.freeze({a: 1, b: 2}), frozen2 = Object.freeze({a: 3, b: 4});
      """

      sids =
        inspect_run(src, fn ->
          for n <- ~w(x y z w other frozen1 frozen2),
              into: %{},
              do: {n, elem(global_record(n).shape, 1)}
        end)

      assert sids["x"] == sids["y"] and sids["y"] == sids["z"] and sids["z"] == sids["w"]
      assert sids["other"] != sids["x"]
      assert sids["frozen1"] == sids["frozen2"] and sids["frozen1"] != sids["x"]
    end

    test "a record goes to dictionary mode at the limits, and stays correct" do
      # (the objects of a constructor of 128 keys are fast once the chain is in the table,
      # and the add of a 129th key is past the limit)
      src = ~S"""
      var last = {a: 1, b: 2}; delete last.b;
      var mid = {a: 1, b: 2, c: 3}; delete mid.b;
      var index = {a: 1}; index[0] = 2;
      var reconf = {a: 1};
      for (var i = 0; i < 9; i++) Object.defineProperty(reconf, 'a', {enumerable: i % 2 == 1});
      var few = {a: 1};
      for (var i = 0; i < 8; i++) Object.defineProperty(few, 'a', {enumerable: i % 2 == 1});
      var one = {a: 1};
      var absent = {a: 1}; delete absent.nope;
      var twice = {a: 1, b: 2, a: 3};
      function L(){ for (var j = 0; j < 128; j++) this['k' + j] = j }
      for (var i = 0; i < 20; i++) var limit = new L();
      var many = new L(); many.k128 = 1;
      """

      modes =
        inspect_run(src, fn ->
          for n <- ~w(last mid many limit index reconf few one absent twice),
              into: %{},
              do: {n, Obj.fast?(global_record(n))}
        end)

      assert modes == %{
               "last" => true,
               "mid" => false,
               "many" => false,
               "limit" => true,
               "index" => false,
               "reconf" => false,
               "few" => true,
               "one" => true,
               "absent" => true,
               "twice" => true
             }

      # (a delete of the last key goes back to the shape of the record before the add)
      same =
        inspect_run(src, fn ->
          global_record("last").shape == global_record("one").shape
        end)

      assert same
    end

    test "a shape other than the root has at most 64 children; the root has no limit" do
      src = ~S"""
      var kids = [], roots = [];
      for (var i = 0; i < 65; i++) { var o = {p: 1}; o['c' + i] = i; kids.push(o) }
      for (var i = 0; i < 100; i++) { var o = {}; o['r' + i] = i; roots.push(o) }
      """

      result =
        inspect_run(src, fn ->
          fast = fn name ->
            {:obj, id} = Map.fetch!(Interp.deref(Interp.global()).vars, name)

            for v <- Browser.JS.Elems.to_list(Interp.deref(id)),
                do: Obj.fast?(Interp.deref(elem(v, 1)))
          end

          {fast.("kids"), fast.("roots")}
        end)

      assert result == {List.duplicate(true, 64) ++ [false], List.duplicate(true, 100)}
    end

    test "a chain that makes too many new shapes in a row goes to dictionary mode once" do
      # (a hash map gets keys that no other object has; the objects of a constructor use the
      # same chain again, so each one gets further, and the later ones are fast)
      src = ~S"""
      var h8 = {}, h9 = {};
      for (var i = 0; i < 8; i++) h8['a' + i] = i;
      for (var i = 0; i < 9; i++) h9['b' + i] = i;
      function C(){ for (var j = 0; j < 20; j++) this['f' + j] = j }
      var c1 = new C(), c2 = new C(), c3 = new C(), c4 = new C();
      """

      result =
        inspect_run(src, fn ->
          modes = for n <- ~w(h8 h9 c1 c2 c3 c4), do: Obj.fast?(global_record(n))
          {modes, global_record("c3").shape == global_record("c4").shape}
        end)

      assert result == {[true, false, false, false, true, true], true}

      # (the keys of an object literal that the compiler sees have no such limit; past 128
      # keys the literal has no shape)
      keys = for i <- 0..127, do: "q#{i}"

      assert {:js_shape, _, _, _, _, _, _} =
               HeapOracle.in_process(fn -> Shape.from_keys(keys) end)

      assert HeapOracle.in_process(fn -> Shape.from_keys(keys ++ ["q128"]) end) == nil
    end

    test "two changes of attributes at two positions give two shapes" do
      src = ~S"""
      var a = {x: 1, y: 2}; Object.defineProperty(a, 'x', {enumerable: false});
      var b = {x: 1, y: 2}; Object.defineProperty(b, 'y', {enumerable: false});
      var c = Object.preventExtensions({x: 1});
      Object.defineProperty(c, 'x', {enumerable: false});
      """

      result =
        inspect_run(src, fn ->
          {a, b, c} = {global_record("a"), global_record("b"), global_record("c")}

          {a.shape != b.shape, Obj.enum_names(a), Obj.enum_names(b), Obj.fast?(c),
           Obj.extensible?(c)}
        end)

      assert result == {true, ["y"], ["x"], true, false}
    end

    test "the table is erased past its budget, and an erase does not walk the heap" do
      # (each object gets a new first key, so each one makes a new child of the root)
      src = ~S"""
      var keep = [];
      for (var i = 0; i < 40000; i++) {
        var o = {}; o['k' + i] = i; if (i % 1000 == 0) keep.push(o)
      }
      """

      {sids, used, {first, old}, last_ok} =
        inspect_run(src, fn ->
          {:obj, id} = Map.fetch!(Interp.deref(Interp.global()).vars, "keep")
          last = Interp.deref(elem(Enum.at(Browser.JS.Elems.to_list(Interp.deref(id)), 39), 1))

          {table_sids(), :erlang.get(:js_shape_n), :erlang.get(:js_shape_since),
           Obj.own_value(last, "k39000") == 39_000.0}
        end)

      # (a shape of one key costs 58 words of the budget of 2,000,000 words. The shapes of
      # the built-in objects use a part of the budget before the program starts)
      realm = inspect_run("", fn -> :erlang.get(:js_shape_n) end)
      assert realm > 0 and realm < 200_000
      assert length(sids) < 40_000 - div(2_000_000 - realm, 58) + 100
      assert used <= 2_000_000
      assert first > div(2_000_000 - realm, 58) and old == []
      assert Enum.all?(sids, &(&1 <= 0 or &1 >= first))
      assert last_ok

      # (an erase removes the entries of the shapes from before the last erase that got an
      # entry after it, and only the entries of the table)
      src = ~S"""
      function mk(){ var o = {a: 1}; o.b = 2; return o }
      var x = mk(), y = mk();
      """

      result =
        inspect_run(src, fn ->
          Shape.erase()
          sid = elem(global_record("x").shape, 1)
          {:ok, program} = Parser.parse("x.c = 3; y.c = 4; var z = {q: 1};", resolve: 4)
          Interp.run_program(program, true)
          shared = global_record("x").shape == global_record("y").shape
          {_, old} = :erlang.get(:js_shape_since)
          before = length(table_sids())
          Shape.erase()
          {shared, old == [sid], before > 0, table_sids(), Obj.own_value(global_record("y"), "c")}
        end)

      assert result == {true, true, true, [], 4.0}
    end

    test "an erase of the transition table keeps the records correct" do
      src = ~S"""
      function mk(){ var o = {a: 1}; o.b = 2; return o }
      mk(); var before = mk();
      """

      # (with compilation on, the closure of `mk` keeps the shape of its literal and the add
      # cell of `o.b`, which the second call makes, keeps its child, so the records that `mk` makes after the erase have
      # the shapes of the records from before it; on the tree walker the adds make new
      # shapes)
      for compile? <- [false, true] do
        result =
          with_compile(compile?, fn ->
            inspect_run(src, fn ->
              Shape.erase()

              {:ok, program} =
                Parser.parse("var after = mk(); after.c = 3; before.c = 4;", resolve: 4)

              Interp.run_program(program, true)
              b = global_record("before")
              a = global_record("after")

              {Obj.enum_names(b), Obj.enum_names(a), Obj.own_value(b, "c"), Obj.own_value(a, "c"),
               elem(b.shape, 1) == elem(a.shape, 1), well_formed?(a) and well_formed?(b)}
            end)
          end)

        assert result == {["a", "b", "c"], ["a", "b", "c"], 4, 3, compile?, true}
      end
    end

    test "the transition table and its counters are not roots of the collector" do
      # (a counter that holds the id of a dead object must not keep it alive)
      result =
        inspect_run("var keep = {a: 1};", fn ->
          {:obj, keep} = Map.fetch!(Interp.deref(Interp.global()).vars, "keep")
          {:obj, dead} = Interp.new_object([{"x", 1}], nil)
          Process.put(:js_shape_next, dead)
          Process.put(:js_shape_n, dead)
          Process.put({:jst, dead}, %{up: dead, x: %{7 => dead}})
          Process.put(:js_shape_since, {dead, [dead]})
          Browser.JS.GC.collect()
          {:erlang.get(dead) == :undefined, :erlang.get(keep) != :undefined}
        end)

      assert result == {true, true}

      # (a live fast record whose shape has the id of a dead object must not keep it alive:
      # the collector does not walk the shape)
      result =
        inspect_run("var keep = {a: 1};", fn ->
          {:obj, dead} = Interp.new_object([{"x", 1}], nil)
          Process.put(:js_shape_next, dead)
          {:ok, program} = Parser.parse("keep.only_here = 2;", resolve: 4)
          Interp.run_program(program, true)
          sid = elem(global_record("keep").shape, 1)
          Browser.JS.GC.collect()
          {sid == dead, :erlang.get(dead) == :undefined}
        end)

      assert result == {true, true}
    end
  end

  describe "the inline caches" do
    # The cells of the inline caches of step A2 (the moduledoc of `Browser.JS.Shape`): the
    # oracles of the corpus compare the results with the cells on and off. These tests look
    # at the cells themselves.

    # The kind of the cell `cell`.
    defp cell_kind(:mega), do: :mega
    defp cell_kind({_, _}), do: :generic
    defp cell_kind({:add, _, _}), do: :add_first
    defp cell_kind({_, _, _}), do: :own
    defp cell_kind({_, :get, _, _}), do: :own_getter
    defp cell_kind({_, {:js_shape, _, _, _, _, _, _}, protos, _}) when is_list(protos), do: :add
    defp cell_kind({_, _, _, _, _}), do: :proto
    defp cell_kind({_, :get, _, _, _, _}), do: :proto_getter
    defp cell_kind({_, _, _, _, _, _, _}), do: :proto2
    defp cell_kind({_, :get, _, _, _, _, _, _}), do: :proto2_getter

    defp cells, do: for({k, cell} <- :erlang.get(), is_integer(k) and k < 0, do: cell)

    # The global variable `name` of the heap of the process.
    defp global(name), do: Map.fetch!(Interp.deref(Interp.global()).vars, name)

    defp run_here(src) do
      {:ok, program} = Parser.parse(src, resolve: 4, file: "t.js")
      Interp.run_program(program, true)
    end

    # Runs `fun` with the application setting `:js_compile` at `on?`, which `Interp.init/1`
    # copies into each new heap. The cells need compiled code, also when the suite runs with
    # JS_COMPILE=0.
    defp with_compile(on?, fun) do
      old = Application.get_env(:browser, :js_compile)
      Application.put_env(:browser, :js_compile, on?)

      try do
        fun.()
      after
        if old == nil,
          do: Application.delete_env(:browser, :js_compile),
          else: Application.put_env(:browser, :js_compile, old)
      end
    end

    test "the rows of the corpus make each kind of cell" do
      rows = for {"dm ic" <> _, _, _} = row <- Browser.JS.DatamodelCorpus.rows(), do: row
      assert length(rows) >= 5

      kinds =
        with_compile(true, fn ->
          HeapOracle.run_all(rows, shapes(true), after: fn -> Enum.map(cells(), &cell_kind/1) end)
        end)
        |> Enum.flat_map(& &1.after)
        |> Enum.uniq()
        |> Enum.sort()

      assert kinds ==
               Enum.sort([
                 :mega,
                 :generic,
                 :add_first,
                 :add,
                 :own,
                 :own_getter,
                 :proto,
                 :proto_getter,
                 :proto2,
                 :proto2_getter
               ])

      # (with the fast records off, no site writes a cell)
      off =
        with_compile(true, fn -> HeapOracle.run_all(rows, shapes(false), after: &cells/0) end)

      assert Enum.all?(off, &(&1.after == []))
    end

    test "the cells hit through the built-in objects and miss after a change of them" do
      src = ~S"""
      function ts(o){ return o.toString } function pu(a){ return a.push }
      function ca(f){ return f.call } function mx(){ return Math.max }
      class C {} var c = new C(), o = {}, a = [], fn = function(){}, out = [];
      function run(){ out[out.length] = [ts(o) === ts(c), typeof pu(a), typeof ca(fn), typeof mx()] }
      for (var i = 0; i < 3; i++) run();
      Object.prototype.toString = 1; Array.prototype.push = 2; Function.prototype.call = 3;
      Math.max = 4; run(); run();
      """

      {kinds, pids, out} =
        with_compile(true, fn ->
          inspect_run(src, fn ->
            protos = for n <- [:object, :array, :function], do: elem(Interp.proto(n), 1)
            cs = cells()

            {Enum.uniq(Enum.map(cs, &cell_kind/1)) |> Enum.sort(),
             for({_, pid, _, _, _} <- cs, do: pid in protos) |> Enum.uniq(),
             Interp.get(global("out"), "length")}
          end)
        end)

      assert Enum.sort([:own, :proto, :proto2]) -- kinds == []
      assert pids == [true]
      assert out == 5.0

      # (the values after the change are those of the generic path)
      {:ok, _, log} =
        Browser.JS.eval(src <> "console.log(out.join())", resolve: 4)

      assert log == [
               log:
                 "true,function,function,function,true,function,function,function," <>
                   "true,function,function,function,true,number,number,number," <>
                   "true,number,number,number"
             ]
    end

    test "a site goes to :mega at its 17th miss, not before" do
      src = fn n ->
        "function rd(o){ return o.v } var objs = []; for (var i = 0; i < #{n}; i++) { var o = {}; o['k' + i] = i; o.v = i; objs.push(o) } for (var i = 0; i < #{n}; i++) rd(objs[i]);"
      end

      at = fn n -> with_compile(true, fn -> inspect_run(src.(n), fn -> cells() end) end) end
      assert [{_, _, 16}] = at.(16)
      assert at.(17) == [:mega]
    end

    test "an add site gets its add cell at the second miss with the same shape" do
      # (a site that runs once keeps the cell {:add, sid}, which matches no record; the
      # second record with the same shape makes the add cell, and a record with another
      # shape between the two starts again)
      kinds = fn calls ->
        src = "function add(o){ o.k = 1; return o } " <> calls

        with_compile(true, fn -> inspect_run(src, fn -> Enum.map(cells(), &cell_kind/1) end) end)
      end

      assert kinds.("add({});") == [:add_first]
      assert kinds.("add({}); add({});") == [:add]
      assert kinds.("add({}); add({a: 1}); add({});") == [:add_first]
      assert kinds.("add({}); add({}); add({});") == [:add]
    end

    test "a cell is not a root, it does not keep its prototype alive, and a sweep keeps it" do
      src = ~S"""
      function mk(tag){ var p = {m: tag}; var o = Object.create(p); o.x = 1; return o }
      var o1 = mk('a');
      """

      result =
        inspect_run(src, fn ->
          site = Shape.new_site()
          o1 = global("o1")
          {:obj, pid} = Interp.deref(elem(o1, 1)).proto
          reads = [Interp.get_ic(o1, "m", site), Interp.get_ic(o1, "m", site)]
          cell = :erlang.get(site)
          run_here("o1 = null; var o2 = mk('b');")
          # (a root that holds the site number: a negative integer is not a heap id, so the
          # walk does not go into the cell)
          Process.put(:ic_test_root, {site})
          GC.collect()
          freed? = :erlang.get(pid) == :undefined
          kept = :erlang.get(site)
          # (the next object has the same shape and a prototype with the same shape, at a
          # new id: the cell misses on the link, and the read is right)
          read = Interp.get_ic(global("o2"), "m", site)
          {reads, cell_kind(cell), elem(cell, 1) == pid, freed?, kept == cell, read}
        end)

      assert result == {["a", "a"], :proto, true, true, true, "b"}
    end

    test "a cell stays exact in a new heap that gives the same ids to other objects" do
      src = fn proto -> "var p = #{proto}; var o = Object.create(p); o.x = 1;" end

      in_heaps = fn fun -> with_compile(true, fn -> HeapOracle.in_process(fun) end) end

      result =
        in_heaps.(fn ->
          site = Shape.new_site()

          heap = fn proto ->
            Interp.init(1_000_000)
            Builtins.install()
            run_here(src.(proto))
            o = global("o")

            {Interp.get_ic(o, "m", site), Interp.get_ic(o, "m", site), Interp.get(o, "m"),
             global("p"), :erlang.get(site)}
          end

          {a1, a2, a, pa, cell} = heap.("{m: 'first'}")
          # (the same ids and the same shapes, other values: the cell hits and reads the
          # object of the new heap)
          {b1, b2, b, pb, cell_b} = heap.("{m: 'second'}")
          # (the same id for the prototype, but another shape: the cell misses)
          {c1, c2, c, pc, cell_c} = heap.("{q: 0, m: 'third'}")

          {[a1, a2, a, b1, b2, b, c1, c2, c], pa == pb and pb == pc, cell_kind(cell),
           cell_b == cell, cell_kind(cell_c), elem(cell_c, tuple_size(cell_c) - 1)}
        end)

      assert result ==
               {[
                  "first",
                  "first",
                  "first",
                  "second",
                  "second",
                  "second",
                  "third",
                  "third",
                  "third"
                ], true, :proto, true, :proto, 2}
    end

    test "an add cell sees a setter that a new heap has at the same prototype id" do
      result =
        with_compile(true, fn ->
          HeapOracle.in_process(fn ->
            site = Shape.new_site()

            heap = fn setup ->
              Interp.init(1_000_000)
              Builtins.install()
              run_here(setup)
              a = Interp.new_object()
              b = Interp.new_object()
              Interp.put_ic(a, "k", 1.0, site)
              Interp.put_ic(b, "k", 2.0, site)

              {Interp.get(a, "k"), Interp.get(b, "k"), cell_kind(:erlang.get(site)),
               global("log"), Interp.proto(:object)}
            end

            {a1, b1, kind1, log1, op1} = heap.("var log = 'none';")

            # (`Object.prototype` has the same id in the new heap, and a setter of the key)
            {a2, b2, kind2, log2, op2} =
              heap.(
                "var log = 'none'; Object.defineProperty(Object.prototype, 'k', {set(v){ log = 'set ' + v }, configurable: true});"
              )

            {[a1, b1, kind1, log1], [a2, b2, kind2, log2], op1 == op2}
          end)
        end)

      assert result ==
               {[1.0, 2.0, :add, "none"], [:undefined, :undefined, :generic, "set 2"], true}
    end

    test "a literal keeps its shape after an erase of the table and in a new heap" do
      {:ok, program} =
        Parser.parse(
          "function mk(){ return {a: 1, b: 2} } function more(o){ o.c = 3; return o } var x = mk(), y = more(mk());",
          resolve: 4,
          file: "t.js"
        )

      result =
        with_compile(true, fn ->
          HeapOracle.in_process(fn ->
            heap = fn ->
              Interp.init(1_000_000)
              Builtins.install()
              Interp.run_program(program, true)
              x = global_record("x")
              y = global_record("y")

              {elem(x.shape, 1), Obj.enum_names(y), Obj.own_value(y, "c"),
               well_formed?(x) and well_formed?(y)}
            end

            {sid1, names1, c1, ok1} = heap.()
            Shape.erase()
            # (the closure of `mk` is in the code cache, which the new heap keeps)
            {sid2, names2, c2, ok2} = heap.()
            {sid1 == sid2, names1 == names2 and names2 == ["a", "b", "c"], c1 == c2, ok1 and ok2}
          end)
        end)

      assert result == {true, true, true, true}
    end

    test "the shapes that add cells keep count in the budget of the code cache" do
      # (each function adds 100 keys that no other object has, so each add cell keeps a
      # shape of its own; after an erase of the transition table and a collection, the
      # cells are the only holders of these shapes, and the budget must bound them)
      budget = 4_000

      fns =
        for f <- 1..10 do
          adds = Enum.map_join(1..100, " ", &"o.f#{f}_#{&1} = #{&1};")
          "function f#{f}(){ var o = {}; #{adds} return 1 } for (var i = 0; i < 20; i++) f#{f}();"
        end

      words =
        with_compile(true, fn ->
          inspect_run("", fn ->
            :erlang.put(:jsc_budget_max, budget)
            run_here(Enum.join(fns, " "))
            Shape.erase()
            GC.collect()
            {:erts_debug.size(cells()), Enum.count(cells(), &(cell_kind(&1) == :add))}
          end)
        end)

      # (a node of the cache is 8 to 18 words)
      assert {w, adds} = words
      assert adds > 0
      assert w < 20 * budget
    end

    test "the cells go with the code cache: at an erase of the budget and with JS_COMPILE=0" do
      erased =
        with_compile(true, fn ->
          inspect_run("", fn ->
            :erlang.put(-1_000_000_000, {1, 1, 1})
            :erlang.put(:jsc_budget_max, 10)
            run_here("function f(){ return {a: 1}.a } f()")
            {:erlang.get(-1_000_000_000), elem(:erlang.get(:jsc_budget), 1) > 0}
          end)
        end)

      assert erased == {:undefined, true}

      result =
        with_compile(false, fn ->
          HeapOracle.in_process(fn ->
            :erlang.put(-1_000_000_000, {1, 1, 1})
            next = Shape.new_site()
            Interp.init(1_000)
            # (the site numbers are never given two times, also after a new heap)
            {:erlang.get(-1_000_000_000), Shape.new_site() < next}
          end)
        end)

      assert result == {:undefined, true}
    end
  end
end
