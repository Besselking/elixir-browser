Code.require_file("js_heap_oracle.ex", __DIR__)

defmodule Browser.JS.ElemsTest do
  # The element store of the arrays (`Browser.JS.Elems`, data-model step B2). The first
  # tests are the grep gate of the moduledoc of `Browser.JS.Elems`: only that module names
  # the fields of the elements of a record. The store oracle then runs random sequences of
  # the operations of `Browser.JS.Elems` on a record and on a plain map with a length, and
  # compares the two after each operation, with indices around the size limit of the
  # dense form. The last tests look at the form of the records that a program makes. (The
  # module is not async: one test changes an application setting.)
  use ExUnit.Case, async: false

  require Browser.JS.Elems, as: Elems
  require Browser.JS.Obj, as: Obj
  alias Browser.JS.{Builtins, HeapOracle, Interp, Parser}

  @fields "items|len|vec"

  # The size limit of the dense form: the oracle uses indices and lengths around it.
  @max Elems.max()

  # The patterns of the grep command in the moduledoc of `Browser.JS.Elems`: `@gate` finds
  # a direct use, and `@allow` is the allow-list. Each is matched against
  # "path:line number:line", as grep prints it.
  @gate "\\.(#{@fields})\\b(?![?!(])|\\b(#{@fields}):|(?<![{\\w:]):(#{@fields})\\b"

  @allow String.trim(~S"""
         ^lib/browser/js/binary_encoding\.ex:\d+:.*(\bst\.len\b|\blen: (byte_size\(str\)|len\b))
         """)

  defp gate?(line), do: Regex.match?(Regex.compile!(@gate), line)
  defp allowed?(path, n, line), do: Regex.match?(Regex.compile!(@allow), "#{path}:#{n}:#{line}")

  describe "the grep gate" do
    test "the moduledoc gives the patterns of this test" do
      {:docs_v1, _, _, _, %{"en" => doc}, _, _} = Code.fetch_docs(Elems)
      assert doc =~ "grep -rnP '#{@gate}' lib/browser/js"
      assert doc =~ "grep -vP '#{@allow}'"
    end

    test "only elems.ex names the fields of the elements of a record" do
      hits =
        for path <- Path.wildcard("lib/browser/js/**/*.ex"),
            path != "lib/browser/js/elems.ex",
            {line, n} <- path |> File.read!() |> String.split("\n") |> Enum.with_index(1),
            not (line =~ ~r/^\s*#/),
            gate?(line),
            not allowed?(path, n, line),
            do: "#{path}:#{n}: #{String.trim(line)}"

      assert hits == []
    end

    test "the gate finds the forms of a direct field use" do
      for line <- [
            "o.items",
            "%{o | items: Map.put(o.items, i, v), len: len}",
            "Map.get(o, :len)",
            "o.len * 1.0",
            "%{class: :array, vec: v}",
            ":erlang.map_get(:vec, o)",
            "is_map_key(o, :items)",
            "Map.put(o, :len, 0)",
            "Map.take(o, [:class, :items])"
          ],
          do: assert(gate?(line), line)

      for line <- [
            "Elems.len(o)",
            "ArrayGeneric.len(v)",
            "len = Elems.len(o)",
            "Map.get(o, :len_ro, false)",
            "items = Map.new(list)",
            "for {v, i} <- items, do: v"
          ],
          do: refute(gate?(line), line)

      assert allowed?("lib/browser/js/binary_encoding.ex", 1, "      i >= st.len -> finish(st)")
      refute allowed?("lib/browser/js/interp.ex", 1, "      i >= st.len -> finish(st)")
    end
  end

  # ── the store oracle ──────────────────────────────────────────

  # The model of a store: the map of each index to its item, and the length.
  defp model(list),
    do: {list |> Enum.with_index() |> Map.new(fn {v, i} -> {i, v} end), length(list)}

  defp accessor?({:accessor, _, _}), do: true
  defp accessor?(_), do: false

  defp packed?({map, len}),
    do: map_size(map) == len and not Enum.any?(map, fn {_, v} -> accessor?(v) end)

  # An index near 0, near the size limit, near the length, or at random.
  defp index(len) do
    Enum.random([
      0,
      1,
      2,
      @max - 2,
      @max - 1,
      @max,
      @max + 1,
      @max + 2,
      max(len - 1, 0),
      len,
      len + 1,
      :rand.uniform(@max + 6) - 1
    ])
  end

  defp value do
    Enum.random([1.0, :rand.uniform() * 1.0e3, "s", :undefined, :null, true, {:obj, 7}])
  end

  defp item do
    if :rand.uniform(4) == 1, do: {:accessor, :undefined, {:obj, 3}}, else: value()
  end

  defp values(n), do: for(_ <- 1..n//1, do: value())

  # A random operation and its effect on the record and on the model.
  defp step(o, {map, len}) do
    case :rand.uniform(10) do
      1 ->
        i = index(len)
        v = value()
        {{:put, i}, Elems.put(o, i, v), {Map.put(map, i, v), max(len, i + 1)}}

      2 ->
        i = index(len)
        x = item()
        {{:define, i}, Elems.define(o, i, x), {Map.put(map, i, x), max(len, i + 1)}}

      3 ->
        i = index(len)
        {{:delete, i}, Elems.delete(o, i), {Map.delete(map, i), len}}

      4 ->
        n = Enum.random([0, 1, max(len - 1, 0), len, len + 1, @max - 1, @max, @max + 1, @max + 2])
        {{:set_len, n}, Elems.set_len(o, n), {Map.filter(map, fn {i, _} -> i < n end), n}}

      5 ->
        list = values(Enum.random([0, 3, @max - 1, @max, @max + 1]))
        {{:replace, length(list)}, Elems.replace(o, list), model(list)}

      6 ->
        n = Enum.random([0, 2, @max, @max + 1, @max + 6])
        items = for i <- 0..(n - 1)//1, :rand.uniform(8) > 1, into: %{}, do: {i, item()}
        {{:replace_map, n}, Elems.replace_map(o, items, n), {items, n}}

      7 ->
        vs = values(Enum.random([1, 1, 1, 2, 3]))

        map =
          vs |> Enum.with_index(len) |> Enum.reduce(map, fn {v, i}, m -> Map.put(m, i, v) end)

        {{:push, length(vs)}, Elems.push(o, vs), {map, len + length(vs)}}

      8 when len > 0 ->
        {last, o2} = Elems.pop(o)
        assert last == Map.get(map, len - 1, :undefined)
        {:pop, o2, {Map.delete(map, len - 1), len - 1}}

      9 ->
        {:sparse, Elems.sparse(o), {map, len}}

      _ ->
        i = index(len)
        v = value()
        {{:put_again, i}, Elems.put(o, i, v), {Map.put(map, i, v), max(len, i + 1)}}
    end
  end

  # An assert with a message that is made only when it fails (the oracle makes many
  # checks).
  defp check!(true, _trace), do: :ok
  defp check!(false, trace), do: flunk("the store differs after #{inspect(trace)}")

  # The record and the model hold the same store, and the record has a correct form.
  defp agree!(o, {map, len} = m, was_dense?, trace) do
    check!(Elems.to_map(o) == map, trace)
    check!(Elems.keys(o) == Enum.sort(Map.keys(map)), trace)
    check!(Elems.count(o) == map_size(map), trace)
    check!(Elems.len(o) == len, trace)
    check!(Elems.to_list(o) == for(i <- 0..(len - 1)//1, do: Map.get(map, i, :undefined)), trace)
    check!(Elems.any_accessor?(o) == Enum.any?(map, fn {_, v} -> accessor?(v) end), trace)
    check!(Elems.packed?(o, len) == packed?(m), trace)
    check!(Elems.empty?(o) == (map == %{}), trace)

    for i <- 0..(len + 3) do
      check!(Elems.fetch(o, i) == Map.fetch(map, i), {trace, i})
      check!(Elems.has?(o, i) == Map.has_key?(map, i), {trace, i})
      check!(Elems.get(o, i, :none) == Map.get(map, i, :none), {trace, i})
    end

    if Elems.dense?(o) do
      # (a dense record holds only data values, with no hole, and at most the limit)
      check!(packed?(m) and len <= Elems.max(), trace)
      check!(was_dense?, trace)
    end

    # (a dense record stays dense while its store fits, and a sparse one stays sparse)
    if was_dense? and packed?(m) and len <= Elems.max() and elem(hd(trace), 0) != :sparse,
      do: check!(Elems.dense?(o), trace)
  end

  describe "the store oracle" do
    test "random sequences of operations give the same store as a map" do
      :rand.seed(:exsss, {2, 7, 64})

      for _run <- 1..400 do
        list = values(Enum.random([0, 1, 3, @max - 2, @max - 1, @max, @max + 1]))
        o = Elems.new(list, nil)
        assert Elems.dense?(o) == length(list) <= Elems.max()
        agree!(o, model(list), Elems.dense?(o), [{:new, length(list)}])

        Enum.reduce(1..40, {o, model(list), [{:new, length(list)}]}, fn _, {o, m, trace} ->
          {op, o2, m2} = step(o, m)
          op = if is_tuple(op), do: op, else: {op}
          trace = [op | trace]
          agree!(o2, m2, Elems.dense?(o), trace)
          {o2, m2, trace}
        end)
      end
    end

    test "from_map/3 gives the dense form only with no hole, no accessor and room" do
      dense = fn items, len -> Elems.dense?(Elems.from_map(items, len, nil)) end
      assert dense.(%{}, 0)
      assert dense.(%{0 => 1.0, 1 => 2.0}, 2)
      refute dense.(%{0 => 1.0}, 2)
      refute dense.(%{0 => {:accessor, :undefined, :undefined}}, 1)
      assert dense.(Map.new(0..(@max - 1), &{&1, 1.0}), @max)
      refute dense.(Map.new(0..@max, &{&1, 1.0}), @max + 1)
    end

    test "the form switch makes the new records sparse" do
      Task.async(fn ->
        Process.put(:js_elems_sparse, true)
        refute Elems.dense?(Elems.new([1.0], nil))
        refute Elems.dense?(Elems.new_vec({1.0}, nil))
        refute Elems.dense?(Elems.from_map(%{0 => 1.0}, 1, nil))
        refute Elems.dense?(Elems.put_empty(%{class: :array}))
        # (a record that is dense stays dense: only the functions that make one read it)
        Process.delete(:js_elems_sparse)
        o = Elems.new([1.0], nil)
        Process.put(:js_elems_sparse, true)
        assert Elems.dense?(Elems.put(o, 1, 2.0))
      end)
      |> Task.await()
    end
  end

  # ── the records of a program ──────────────────────────────────

  defp run(src, fun) do
    {:ok, program} = Parser.parse(src, resolve: 4, file: "t.js")

    HeapOracle.in_process(fn ->
      Interp.init(1_000_000)
      Builtins.install()
      Interp.run_program(program, true)
      fun.()
    end)
  end

  defp form(name) do
    {:obj, id} = Map.fetch!(Interp.deref(Interp.global()).vars, name)
    o = Interp.deref(id)
    if Elems.dense?(o), do: :dense, else: :sparse
  end

  describe "the forms of the arrays of a program" do
    test "each change rule makes the sparse form, and the other changes keep the dense form" do
      src = """
      var lit = [1, 2, 3], empty = [], spread = [...lit, 4], holes = [1, , 3];
      var big = []; for (var i = 0; i < #{@max}; i++) big.push(i);
      var over = big.slice(); over.push(#{@max});
      var hole = [1, 2, 3]; hole[4] = 5;
      var append = [1, 2, 3]; append[3] = 4;
      var del = [1, 2, 3]; delete del[1];
      var delend = [1, 2, 3]; delete delend[7];
      var longer = [1, 2]; longer.length = 3;
      var shorter = [1, 2, 3]; shorter.length = 1;
      var acc = [1, 2]; Object.defineProperty(acc, 0, {get(){ return 1 }});
      var ro = [1, 2]; Object.defineProperty(ro, 0, {value: 1, writable: false});
      var dflt = [1, 2]; Object.defineProperty(dflt, 0, {value: 5, writable: true, enumerable: true, configurable: true});
      var frozen = Object.freeze([1]), sealed = Object.seal([1]), closed = Object.preventExtensions([1]);
      var rolen = [1, 2]; Object.defineProperty(rolen, 'length', {writable: false});
      var args = (function(){ return arguments })(1, 2);
      var sorted = [3, 1, 2].sort(), mapped = [1, 2].map(x => x), cat = [1].concat([2], 3);
      var popped = [1, 2, 3]; popped.pop(); var shifted = [1, 2, 3]; shifted.shift();
      var newarr = new Array(3), newempty = new Array(0), from = Array.from([1, 2]), json = JSON.parse('[1, [2]]');
      """

      forms =
        run(src, fn ->
          ~w(lit empty spread holes big over hole append del delend longer shorter acc ro dflt frozen
             sealed closed rolen args sorted mapped cat popped shifted newarr newempty from json)
          |> Map.new(&{&1, form(&1)})
        end)

      sparse = ~w(holes over hole del longer acc ro frozen sealed closed rolen args newarr)

      for {name, f} <- forms,
          do: assert({name, f} == {name, if(name in sparse, do: :sparse, else: :dense)})
    end

    test "a dense record is never frozen, sealed, closed or an arguments object" do
      src = """
      var all = [];
      for (var i = 0; i < #{@max + 6}; i++) { var a = [i]; if (i % 3 == 0) Object.freeze(a); all.push(a, [i, i]) }
      """

      bad =
        run(src, fn ->
          for {id, o} <- :erlang.get(),
              is_integer(id),
              Obj.heap_record?(o),
              Elems.dense?(o),
              Obj.frozen?(o) or Obj.sealed?(o) or not Obj.extensible?(o) or
                is_map_key(o, :arguments) or is_map_key(o, :len_ro) or
                Elems.count(o) > Elems.max() or Elems.any_accessor?(o) or
                Obj.attr_map(o) != %{},
              do: id
        end)

      assert bad == []
    end

    test "the application setting :js_elems_sparse makes the arrays of each heap sparse" do
      # (JS_ELEMS=sparse and `mix js.test262 --elems sparse` set it; `Interp.init/1` reads it)
      old = Application.get_env(:browser, :js_elems_sparse)

      try do
        Application.put_env(:browser, :js_elems_sparse, true)
        assert run("var a = [1], b = [];", fn -> {form("a"), form("b")} end) == {:sparse, :sparse}
        Application.put_env(:browser, :js_elems_sparse, false)
        assert run("var a = [1], b = [];", fn -> {form("a"), form("b")} end) == {:dense, :dense}
      after
        Application.put_env(:browser, :js_elems_sparse, old)
      end
    end
  end
end
