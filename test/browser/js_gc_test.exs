defmodule Browser.JSGCTest do
  use ExUnit.Case, async: true

  alias Browser.JS.{Builtins, GC, Interp, Parser}
  require Browser.JS.Elems, as: Elems
  require Browser.JS.Obj, as: Obj

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
      # (a slot can hold a bare id too: the walk reads the slots of a frame as any term)
      {:obj, bare} = Interp.new_object([{"z", 3.0}])
      frame = Interp.alloc({nil, info, nil, stray, Interp.global(), {:obj, slot_obj}, bare})
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
      assert is_map(:erlang.get(bare))
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
      # the id index. Its wrapper (the only field here that holds a JS value) is `held`:
      # the node is in the document, so its wrapper lives.
      s = Process.get(:dom)
      node = %{s.nodes[doc] | id: gid, kind: :element, tag: "p", kids: [], parent: doc}
      nodes = s.nodes |> Map.put(gid, node) |> Map.update!(doc, &%{&1 | kids: [gid | &1.kids]})
      ids = Map.put(s.ids, "b", [gid])
      wrappers = Map.put(s.wrappers, gid, {:obj, held})
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

  # `:js_pmiss` holds the ids of the prototypes of the chains of the misses of host
  # objects (`Interp.host_lookup/3`). It is not a root.
  test "the chains of the misses of host objects keep no prototype alive" do
    Task.async(fn ->
      Interp.init(10_000_000)
      Builtins.install()

      {:ok, p} =
        Parser.parse("""
        var ta = new Int32Array(1), mid = Object.create(Int32Array.prototype);
        Object.setPrototypeOf(ta, mid); ta.nope;
        Object.setPrototypeOf(ta, Int32Array.prototype); mid = null;
        """)

      Interp.run_program(p)
      assert [mid] = for({{pid, "nope"}, _} <- Process.get(:js_pmiss), do: pid)
      assert is_map(:erlang.get(mid))

      GC.collect()
      assert :erlang.get(mid) == :undefined
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
        | wrappers: Map.put(s.wrappers, {:aux, :window}, w),
          listeners: Map.put(s.listeners, :window, [l]),
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

  # A JS value is never a bare heap id, so the walk reads an integer in a JS value as a
  # number: an integer that equals the id of an object that nothing holds does not keep
  # that object alive. Each case puts such an integer in one place: an element of a dense
  # array, the value of an own property, the key and the value of a Map entry, the `seq` of
  # a Map and the `len` of a sparse array. The dense array, the object and the Map are of
  # the common forms, which the walk matches whole; the sparse array is not.
  test "an integer in a JS value, a Map counter or a length keeps no object alive" do
    Task.async(fn ->
      Interp.init(10_000_000)
      Builtins.install()
      dead = for _ <- 1..6, do: elem(Interp.new_object([{"d", 1.0}]), 1)
      [d_elem, d_prop, d_key, d_val, d_seq, d_len] = dead

      run = fn src ->
        {:ok, p} = Parser.parse(src)
        Interp.run_program(p)
      end

      arr = Interp.new_array([d_elem])
      obj = Interp.new_object([{"x", d_prop}])
      Process.put({:gc_test_keep, 1}, [arr, obj])

      # (with the last entry, the Map has `d_seq` entries, so its next `seq` is `d_seq`)
      run.("var m = new Map(); for (var i = 0; i < #{d_seq - 1}; i++) m.set('k' + i, i)")
      {:ok, {:obj, mid} = m} = Interp.lookup_scoped(Interp.global(), "m")
      Interp.call(Interp.get(m, "set"), m, [d_key, d_val])
      run.("var a = []; a[#{d_len - 1}] = 'x'")
      {:ok, {:obj, sid}} = Interp.lookup_scoped(Interp.global(), "a")

      {:obj, aid} = arr
      assert Elems.dense?(Interp.deref(aid))
      assert map_size(Interp.deref(mid)) == 7 and Interp.deref(mid).seq == d_seq
      refute Elems.dense?(Interp.deref(sid))
      assert Interp.deref(sid).len == d_len

      GC.collect()
      for id <- dead, do: assert(:erlang.get(id) == :undefined, "kept: #{id}")
      assert Interp.get(arr, 0.0) == d_elem
      assert Interp.get(obj, "x") == d_prop
      assert Interp.call(Interp.get(m, "get"), m, [d_key]) == d_val
      assert run.("m.size + ':' + a.length") == "#{d_seq}:#{d_len}"
    end)
    |> Task.await(30_000)
  end

  # The forms of a record that the walk does not match whole keep the walk of each field,
  # and the entries of a Map or a Set hold their keys and values as JS values. So an object
  # that only one of these holds stays alive: the key and the value of a Map entry, a Set
  # entry, the getter of an accessor in `vals`, the target and the `this` of a bound
  # function and the target of a proxy.
  test "keeps an object that only a Map, a Set, an accessor, a bound function or a proxy holds" do
    Task.async(fn ->
      Interp.init(10_000_000)
      Builtins.install()

      run = fn src ->
        {:ok, p} = Parser.parse(src)
        Interp.run_program(p)
      end

      run.("""
      var held = [{ k: 'key' }, { k: 'value' }, { k: 'set' }, function () { return 'get' },
        function () { return this.k }, { k: 'this' }, { k: 'target' }];
      var m = new Map([[held[0], 1], ['v', held[1]]]);
      var s = new Set([held[2]]);
      var acc = {};
      Object.defineProperty(acc, 'x', { get: held[3] });
      var b = held[4].bind(held[5]);
      var p = new Proxy(held[6], {});
      """)

      {:ok, {:obj, hid}} = Interp.lookup_scoped(Interp.global(), "held")
      ids = for i <- 0..6, do: elem(Interp.get({:obj, hid}, i * 1.0), 1)
      {:ok, {:obj, accid}} = Interp.lookup_scoped(Interp.global(), "acc")
      assert Obj.fast?(Interp.deref(accid))
      run.("held = null")

      GC.collect()
      assert :erlang.get(hid) == :undefined
      for id <- ids, do: assert(is_map(:erlang.get(id)), "freed: #{id}")

      assert run.("[[...m.keys()][0].k, m.get('v').k, [...s][0].k, acc.x, b(), p.k].join()") ==
               "key,value,set,get,this,target"
    end)
    |> Task.await(30_000)
  end

  # The walk matches the common forms of a record whole: a plain object, a function, a
  # dense array and a Map. Each clause must still walk each field that can hold a
  # reference: the prototype, the own properties, the home object of a method (for
  # `super`) and the environment of a native. Each object of `held` has only one such
  # field that holds it, and the program reads each one after the collection.
  test "keeps what each field of a record of a common form holds" do
    Task.async(fn ->
      Interp.init(10_000_000)
      Builtins.install()

      run = fn src ->
        {:ok, p} = Parser.parse(src)
        Interp.run_program(p)
      end

      run.("""
      var held = [{ k: 'proto' }, { k: 'fn' }, { k: 'array' }, { k: 'map' }, { k: 'home' }];
      var o = Object.create(held[0]);
      var f = function () {}; f.x = held[1];
      var a = [1, 2]; a.x = held[2];
      var m = new Map(); m.x = held[3];
      var sub = new (class extends Map { get k() { return 'map proto' } })();
      var meth = { __proto__: held[4], m() { return super.k } }.m;
      """)

      {:ok, {:obj, hid}} = Interp.lookup_scoped(Interp.global(), "held")
      ids = for i <- 0..4, do: elem(Interp.get({:obj, hid}, i * 1.0), 1)
      # (a native whose Elixir fun holds the only reference to an object)
      {:obj, nat} = Interp.new_object([{"k", "native"}])
      Interp.declare(Interp.global(), "nat", Interp.native("nat", fn _, _ -> {:obj, nat} end))

      # (each record is of a form that the walk matches whole: the four fields of a fast
      # record and `n` more)
      for {name, n} <- [
            {"o", 0},
            {"f", 1},
            {"a", 1},
            {"m", 3},
            {"sub", 3},
            {"meth", 1},
            {"nat", 1}
          ] do
        {:ok, {:obj, id}} = Interp.lookup_scoped(Interp.global(), name)
        r = Interp.deref(id)
        assert Obj.fast?(r) and map_size(r) == 4 + n, "#{name}: #{inspect(Map.keys(r))}"
      end

      {:ok, {:obj, aid}} = Interp.lookup_scoped(Interp.global(), "a")
      assert Elems.dense?(Interp.deref(aid))
      run.("held = null")

      GC.collect()
      for id <- [nat | ids], do: assert(is_map(:erlang.get(id)), "freed: #{id}")

      assert run.("[o.k, f.x.k, a.x.k, m.x.k, sub.k, meth(), nat().k].join()") ==
               "proto,fn,array,map,map proto,home,native"
    end)
    |> Task.await(30_000)
  end

  # A reference reads its mark bit before it reads the entry, so the bitmap has a bit for
  # each id below `:js_next`, also above the largest key. A reference to an id that has no
  # entry does not stop the collection. Here the 70 newest objects are gone, so the id of
  # the last one is in a word of the bitmap above the word of the largest key.
  test "a reference to an id below the next heap id with no entry does not stop the walk" do
    Task.async(fn ->
      Interp.init(10_000_000)
      Builtins.install()
      ids = for _ <- 1..130, do: elem(Interp.new_object(), 1)
      for id <- Enum.take(ids, -70), do: :erlang.erase(id)
      Process.put(:js_freed, Process.get(:js_freed) + 70)
      last = List.last(ids)
      Process.put({:gc_test_key, 1}, {:held, {:obj, last}})
      keys = for {k, _} <- Process.get(), is_integer(k), k >= 0, do: k
      assert div(last, 64) > div(Enum.max(keys), 64)

      GC.collect()
      assert :erlang.get(last) == :undefined

      assert Interp.heap_size() ==
               length(for {k, _} <- Process.get(), is_integer(k), k >= 0, do: k)
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

  # A top-level `await` waits for its promise inside the script: the timers run in the
  # script (`Browser.JS.Promise.await/1`). What the script holds on the Elixir stack then
  # (here the first element of an array literal that is not built yet) is not a root, so
  # the timers that run there do not collect. The timers after the script do.
  test "a timer that a top-level await runs does not collect" do
    Task.async(fn ->
      Interp.init(10_000_000)
      Builtins.install()
      Process.put(:js_gc_at, 0)
      # (nothing holds this object, and only a collect frees it: `free/1` frees only what
      # the interpreter dropped, so a count of `:js_freed` also changes with no collect)
      {:obj, stray} = Interp.new_object([{"x", 1.0}])

      {:ok, p} =
        Parser.parse(
          """
          globalThis.out = [{ k: 'tmp' }, await new Promise(function (r) { setTimeout(r, 1) })][0].k;
          setTimeout(function () { out += '!' }, 1);
          """,
          module: true
        )

      Interp.run_program(p, true)
      assert Process.get(stray) != nil
      Builtins.run_timers(fn v -> throw({:uncaught, v}) end)
      assert Process.get(stray) == nil
      {:ok, q} = Parser.parse("out")
      assert Interp.run_program(q) == "tmp!"
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
