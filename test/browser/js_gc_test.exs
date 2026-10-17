defmodule Browser.JSGCTest do
  use ExUnit.Case, async: true

  alias Browser.JS.{Builtins, GC, Interp, Parser}
  require Browser.JS.Elems, as: Elems

  # True in the check build (`JS_RESOLVE_CHECK=1`).
  @check Application.compile_env(:browser, :js_resolve_check, false)

  # runs `src` in a fresh heap, collects, then runs the timers; returns {freed, heap size
  # before, heap size after, console}
  defp run(src, after_src) do
    Task.async(fn ->
      Interp.init(10_000_000)
      Builtins.install()
      {:ok, p} = Parser.parse(src)
      Interp.run_program(p)
      before = Browser.JS.Interp.heap_size()
      freed = GC.collect()
      {:ok, p2} = Parser.parse(after_src)
      Interp.run_program(p2)
      Builtins.run_timers(fn v -> throw({:uncaught, v}) end)
      {freed, before, Browser.JS.Interp.heap_size(), Enum.reverse(Process.get(:js_console, []))}
    end)
    |> Task.await(30_000)
  end

  test "frees unreachable objects and keeps what timers, globals and closures still use" do
    {freed, before, _, console} =
      run(
        """
        var keep = { n: 1, list: [1, 2, 3] };
        function counter() { var c = 0; return function() { return ++c } }
        var next = counter();
        next();
        for (var i = 0; i < 2000; i++) { var junk = { a: [i], b: { c: i } } }
        junk = null;
        (function () {
          var held = { msg: 'from a timer' };
          setTimeout(function () { console.log(held.msg, keep.list.length, next()) }, 10);
        })();
        """,
        "console.log('after', keep.n)"
      )

    assert freed > 4000
    assert freed < before
    assert console == [{:log, "after 1"}, {:log, "from a timer 3 2"}]
  end

  # Step 2c: a level 2 frame that a closure holds lives on, a frame that nothing holds is
  # swept, and the line number in a frame's header keeps nothing alive.
  test "follows the parent, the root and the slots of a frame, not its call position" do
    Task.async(fn ->
      Interp.init(10_000_000)
      Builtins.install()

      {:ok, p} =
        Parser.parse(
          "function mk(){ var c = { n: 41 }; return () => ++c.n } var inc = mk(); " <>
            "function dead(){ var d = { n: 1 }; var g = () => d; return 0 } dead()",
          resolve: 2
        )

      Interp.run_program(p)
      {:ok, {:obj, inc_id}} = Interp.lookup_scoped(Interp.global(), "inc")
      {:closure, %{scope: kept}} = Interp.deref(inc_id).fun
      assert is_tuple(Interp.deref(kept))

      # A frame whose call position is the id of an object that nothing else holds.
      {:obj, stray} = Interp.new_object([{"x", 1.0}])
      {:obj, slot_obj} = Interp.new_object([{"y", 2.0}])
      info = elem(Interp.deref(kept), 1)
      frame = Interp.alloc({nil, info, nil, stray, Interp.global(), {:obj, slot_obj}})
      Process.put(:gc_test_frame, frame)

      # The frame of `dead` stays after its call (a closure was made in it), but nothing holds it.
      dead? = fn ->
        Enum.any?(Process.get(), fn {k, v} ->
          is_integer(k) and is_tuple(v) and tuple_size(v) >= 5 and
            match?(%{name: "dead"}, elem(v, 1))
        end)
      end

      assert dead?.()
      GC.collect()
      refute dead?.()
      assert is_tuple(Interp.deref(kept))
      assert Interp.call({:obj, inc_id}, :undefined, []) == 42.0
      assert :erlang.get(stray) == :undefined
      assert is_map(:erlang.get(slot_obj))
    end)
    |> Task.await()
  end

  test "walks every element of a tuple that is not a frame, even with a struct in position 2" do
    Task.async(fn ->
      Interp.init(10_000_000)
      Builtins.install()

      # A WebAssembly instance keeps its functions as a tuple of structs; element 2 can hold
      # the only reference to a JS function.
      {:obj, held} = Interp.new_object([{"x", 1.0}])
      fun = fn -> {:obj, held} end
      tuple = {%URI{}, %URI{path: "a"}, fun, %URI{}, %URI{}}
      Process.put({:gc_test_tuple, 1}, tuple)

      GC.collect()
      assert is_map(:erlang.get(held))
    end)
    |> Task.await()
  end

  # A map that is not an object record: the walk follows its keys and its values, but an
  # integer key is an array index, not an id. So a reference that is only a key keeps its
  # object alive, and an index (of a sparse array, or of any other map) that equals the id
  # of an object that nothing holds does not keep it alive.
  test "walks the keys of a map, but not its integer keys" do
    Task.async(fn ->
      Interp.init(10_000_000)
      Builtins.install()

      {:obj, held} = Interp.new_object([{"x", 1.0}])
      {:obj, dead} = Interp.new_object([{"y", 2.0}])
      {:obj, dead2} = Interp.new_object([{"z", 3.0}])
      Process.put({:gc_test_map, 1}, %{{:obj, held} => 1.0, dead => 2.0})

      {:ok, p} = Parser.parse("var a = []; a[#{dead2}] = 'x'; a.length")
      assert Interp.run_program(p) == dead2 + 1.0
      {:ok, {:obj, aid}} = Interp.lookup_scoped(Interp.global(), "a")
      # (the elements are in a map, with the index as its key)
      refute Elems.dense?(Interp.deref(aid))

      GC.collect()
      assert is_map(:erlang.get(held))
      assert :erlang.get(dead) == :undefined
      assert :erlang.get(dead2) == :undefined

      {:ok, p} = Parser.parse("a[#{dead2}] + a.length")
      assert Interp.run_program(p) == "x#{dead2 + 1}"
    end)
    |> Task.await()
  end

  # The own-property fields of an object record also hold integers that are not heap ids:
  # the place of a key that is not enumerable among the enumerable names is a count. Such a
  # count must not keep the object with that id alive. The loop makes the count equal to the
  # id of an object that nothing holds.
  test "the place of a hidden key keeps no object alive" do
    for enumerable <- [false, true] do
      Task.async(fn ->
        Interp.init(10_000_000)
        Builtins.install()
        {:obj, gid} = Interp.new_object()

        {:ok, p} =
          Parser.parse("""
          var o = {};
          for (var i = 0; i < #{gid}; i++) o['k' + i] = i;
          Object.defineProperty(o, 'h', {value: 1, enumerable: #{enumerable}});
          """)

        Interp.run_program(p)
        GC.collect()
        assert :erlang.get(gid) == :undefined, "enumerable: #{enumerable}"

        {:ok, names} = Parser.parse("Object.getOwnPropertyNames(o).slice(-2).join()")
        assert Interp.run_program(names) == "k#{gid - 1},h"
      end)
      |> Task.await(30_000)
    end
  end

  # Step B2: a dense array keeps its elements in a tuple (`Browser.JS.Elems`). The collector
  # and the dangling scan of check mode walk the tuple as any tuple, so each element stays
  # alive, a frame that a closure in the tuple holds counts as a scope, and an element that
  # a shrink of the length cuts off is freed.
  test "walks the elements of a dense array, also in the dangling scan" do
    Task.async(fn ->
      Interp.init(10_000_000)
      Builtins.install()

      run = fn src ->
        {:ok, p} = Parser.parse(src, resolve: 4)
        Interp.run_program(p)
      end

      run.(
        "function mk(){ var c = { n: 1 }; return () => c } " <>
          "var a = [mk(), { k: 2 }], drop = [1, { k: 3 }];"
      )

      global = fn name ->
        {:ok, {:obj, id}} = Interp.lookup_scoped(Interp.global(), name)
        id
      end

      aid = global.("a")
      did = global.("drop")
      assert Elems.dense?(Interp.deref(aid)) and Elems.dense?(Interp.deref(did))
      {:obj, fid} = Interp.get({:obj, aid}, 0.0)
      {:obj, oid} = Interp.get({:obj, aid}, 1.0)
      {:obj, cut} = Interp.get({:obj, did}, 1.0)

      run.("drop.length = 1")
      assert Elems.dense?(Interp.deref(did))
      GC.collect()
      assert is_map(:erlang.get(fid)) and is_map(:erlang.get(oid))
      assert :erlang.get(cut) == :undefined
      assert Interp.call({:obj, fid}, :undefined, []) |> Interp.get("n") == 1.0

      # A frame freed while the closure in the tuple still holds it: the scan finds it
      # through the scope of the closure.
      {:closure, %{scope: sid}} = Interp.deref(fid).fun
      assert GC.dangling(nil) == []
      :erlang.put(sid, {:js_freed, ~s("mk")})
      assert GC.dangling(nil) == [~s("mk")]
    end)
    |> Task.await(30_000)
  end

  # The walk reads each integer as a heap id. The node table of the document holds node ids,
  # and the lexer's tables hold offsets. The walk does not read them, so such an integer
  # does not keep a dead object alive.
  test "a node id that equals the id of a dead object does not keep it alive" do
    Task.async(fn ->
      Interp.init(10_000_000)
      Builtins.install()
      {raw, _} = "<body><p id=a>x</p></body>" |> Browser.HTML.parse() |> Browser.Forms.index()
      doc = Browser.JS.DOM.init(raw, %{url: "http://t.test/"})
      {:obj, gid} = Interp.new_object()
      {:obj, held} = Interp.new_object()

      # A node with the id `gid`, in the node table, in the kids of the document and in
      # the id index. A wrapper (the only field here that holds a JS value) holds `held`.
      s = Process.get(:dom)
      node = %{s.nodes[doc] | id: gid, kind: :element, tag: "p", kids: [], parent: doc}
      nodes = s.nodes |> Map.put(gid, node) |> Map.update!(doc, &%{&1 | kids: [gid | &1.kids]})
      ids = Map.put(s.ids, "b", [gid])
      wrappers = Map.put(s.wrappers, -1, {:obj, held})
      Process.put(:dom, %{s | nodes: nodes, ids: ids, wrappers: wrappers, next: gid})

      GC.collect()
      assert :erlang.get(gid) == :undefined
      assert is_map(:erlang.get(held))
      assert Process.get(:dom).nodes[gid] == node
    end)
    |> Task.await(30_000)
  end

  # The node table is not a root, so a JS value in a node map does not keep its object
  # alive. The check build (`JS_RESOLVE_CHECK=1`) stops the collection when it finds one.
  test "a JS value in the node table stops the collection in the check build" do
    Task.async(fn ->
      Interp.init(10_000_000)
      Builtins.install()
      {raw, _} = "<body><p id=a>x</p></body>" |> Browser.HTML.parse() |> Browser.Forms.index()
      doc = Browser.JS.DOM.init(raw, %{url: "http://t.test/"})
      {:obj, held} = Interp.new_object()
      s = Process.get(:dom)
      nodes = Map.update!(s.nodes, doc, &%{&1 | props: %{"x" => {:obj, held}}})
      Process.put(:dom, %{s | nodes: nodes})

      if @check do
        assert_raise ArgumentError, ~r/unwalked field/, &GC.collect/0
      else
        GC.collect()
        assert :erlang.get(held) == :undefined
      end
    end)
    |> Task.await(30_000)
  end

  test "the lexer's tables keep no object alive" do
    Task.async(fn ->
      Interp.init(10_000_000)
      Builtins.install()
      {:obj, gid} = Interp.new_object()

      # The source is `gid` bytes long, so the tables hold `gid` as an offset.
      {:ok, _} = Parser.parse(String.duplicate(" ", gid - 1) <> "1")
      {_, starts, _} = Process.get(:lex_table)
      assert gid in Tuple.to_list(starts)
      assert gid in Tuple.to_list(elem(Process.get(:js_srctab), 1))

      GC.collect()
      assert :erlang.get(gid) == :undefined
    end)
    |> Task.await(30_000)
  end

  # `Browser.JS.DOM.gc_root/1` leaves out the fields that hold no JS value. The fields that
  # can hold one stay roots: in the running realm and in the saved fields and keys of a
  # realm that does not run.
  test "the fields of the document that hold JS values keep their objects alive" do
    Task.async(fn ->
      Interp.init(10_000_000)
      Builtins.install()
      {raw, _} = "<body><p id=a>x</p></body>" |> Browser.HTML.parse() |> Browser.Forms.index()
      Browser.JS.DOM.init(raw, %{url: "http://t.test/"})
      objs = for _ <- 1..9, do: Interp.new_object()
      [w, l, ce, h, ses, rh, rce, rk, out] = objs
      s = Process.get(:dom)

      realm = %{
        fields: %{hist: [{"http://f.test/", rh}], ce: %{"x-r" => rce}, hist_idx: 0},
        keys: %{js_global: rk}
      }

      Process.put(:dom, %{
        s
        | wrappers: Map.put(s.wrappers, -1, w),
          listeners: Map.put(s.listeners, -1, [l]),
          ce: %{"x-a" => ce},
          hist: [{"http://t.test/", h}],
          session: %{"k" => ses},
          outbox: [{:x, out}],
          realms: Map.put(s.realms, -2, realm)
      })

      GC.collect()
      for {:obj, id} <- objs, do: assert(is_map(:erlang.get(id)), "freed: #{id}")
    end)
    |> Task.await(30_000)
  end

  # The marks are a bitmap up to the largest heap key, not up to `:js_next`. An entry above
  # `:js_next` that a root holds stays, and so does what it holds.
  test "keeps a held entry with a key above the next heap id" do
    Task.async(fn ->
      Interp.init(10_000_000)
      Builtins.install()
      {:obj, inner} = Interp.new_object()
      top = Process.get(:js_next) + 1000
      :erlang.put(top, {:obj, inner})
      :erlang.put(top + 64, {:obj, inner})
      Process.put({:gc_test_key, 1}, {:held, top})

      GC.collect()
      assert :erlang.get(top) == {:obj, inner}
      assert is_map(:erlang.get(inner))
      assert :erlang.get(top + 64) == :undefined
    end)
    |> Task.await(30_000)
  end

  test "does nothing unless enabled" do
    Task.async(fn ->
      Interp.init(1000)
      assert GC.maybe_collect() == :ok
    end)
    |> Task.await()
  end
end
