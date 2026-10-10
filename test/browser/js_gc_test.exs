defmodule Browser.JSGCTest do
  use ExUnit.Case, async: true

  alias Browser.JS.{Builtins, GC, Interp, Parser}

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

  test "does nothing unless enabled" do
    Task.async(fn ->
      Interp.init(1000)
      assert GC.maybe_collect() == :ok
    end)
    |> Task.await()
  end
end
