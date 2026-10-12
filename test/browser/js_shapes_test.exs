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
  # as a heap id shows up as a different heap count.
  #
  # The other tests look at the records: which ones are fast, the change to dictionary
  # mode at the limits, and the form of each fast record.
  use ExUnit.Case, async: false

  @moduletag timeout: 1_800_000

  alias Browser.JS.{Builtins, HeapOracle, Interp, Parser, Shape}
  alias Browser.JS.CompileTest.Corpus
  require Browser.JS.Obj, as: Obj

  @programs Corpus.programs(__DIR__)

  defp shapes(on?), do: fn -> Process.put(:js_shapes, on?) end

  # The keys of the transition table, and the process keys of `Browser.JS.Shape`.
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
      HeapOracle.assert_same(
        HeapOracle.both(@programs, shapes(false), shapes(true), ids: true, gc: true),
        "with the fast records on and forced collections"
      )
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
    test "plain objects, literals, instances and parsed objects are fast; the others are not" do
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

      assert Enum.sort(fast) == Enum.sort(~w(lit empty inst fobj parsed err made))
      assert Enum.sort(dict) == ["arr", "fn"]

      # (the prototypes that the interpreter makes stay dictionaries in step A1)
      protos =
        inspect_run("function F(){}; class K {}; var p = F.prototype, q = K.prototype", fn ->
          {Obj.fast?(global_record("p")), Obj.fast?(global_record("q"))}
        end)

      assert protos == {false, false}

      # (the built-in objects stay dictionaries, and the switch goes back on after them)
      builtins =
        inspect_run("var m = Math, o = {};", fn ->
          {Obj.fast?(global_record("m")), Obj.fast?(global_record("o")),
           Obj.fast?(Interp.deref(elem(Interp.proto(:object), 1)))}
        end)

      assert builtins == {false, true, false}

      # (with the switch off, no record is fast)
      assert inspect_run(src, fn -> Enum.count(records(), &Obj.fast?(elem(&1, 1))) end, false) ==
               0
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
      src = ~S"""
      var last = {a: 1, b: 2}; delete last.b;
      var mid = {a: 1, b: 2, c: 3}; delete mid.b;
      var many = {}; for (var i = 0; i < 129; i++) many['k' + i] = i;
      var limit = {}; for (var i = 0; i < 128; i++) limit['k' + i] = i;
      var index = {a: 1}; index[0] = 2;
      var reconf = {a: 1};
      for (var i = 0; i < 9; i++) Object.defineProperty(reconf, 'a', {enumerable: i % 2 == 1});
      var few = {a: 1};
      for (var i = 0; i < 8; i++) Object.defineProperty(few, 'a', {enumerable: i % 2 == 1});
      var one = {a: 1};
      """

      modes =
        inspect_run(src, fn ->
          for n <- ~w(last mid many limit index reconf few one),
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
               "one" => true
             }

      # (a delete of the last key goes back to the shape of the record before the add)
      same =
        inspect_run(src, fn ->
          global_record("last").shape == global_record("one").shape
        end)

      assert same
    end

    test "the table is erased past its budget, and an erase does not walk the heap" do
      # (each object gets a new first key, so each one makes a new child of the root)
      src = ~S"""
      var keep = [];
      for (var i = 0; i < 40000; i++) { var o = {}; o['k' + i] = i; if (i % 1000 == 0) keep.push(o) }
      """

      {sids, used, {first, old}, last_ok} =
        inspect_run(src, fn ->
          {:obj, id} = Map.fetch!(Interp.deref(Interp.global()).vars, "keep")
          last = Interp.deref(elem(Interp.deref(id).items[39], 1))

          {table_sids(), :erlang.get(:js_shape_n), :erlang.get(:js_shape_since),
           Obj.own_value(last, "k39000") == 39_000.0}
        end)

      # (a shape of one key costs 58 words of the budget of 2,000,000 words)
      assert length(sids) < 40_000 - div(2_000_000, 58) + 100
      assert used <= 2_000_000
      assert first > div(2_000_000, 58) and old == []
      assert Enum.all?(sids, &(&1 == 0 or &1 >= first))
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
      var before = mk();
      """

      result =
        inspect_run(src, fn ->
          Shape.erase()

          {:ok, program} =
            Parser.parse("var after = mk(); after.c = 3; before.c = 4;", resolve: 4)

          Interp.run_program(program, true)
          b = global_record("before")
          a = global_record("after")

          {Obj.enum_names(b), Obj.enum_names(a), Obj.own_value(b, "c"), Obj.own_value(a, "c"),
           elem(b.shape, 1) != elem(a.shape, 1), well_formed?(a) and well_formed?(b)}
        end)

      assert result == {["a", "b", "c"], ["a", "b", "c"], 4, 3, true, true}
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
    end
  end
end
