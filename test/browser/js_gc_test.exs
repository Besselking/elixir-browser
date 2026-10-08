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

  test "does nothing unless enabled" do
    Task.async(fn ->
      Interp.init(1000)
      assert GC.maybe_collect() == :ok
    end)
    |> Task.await()
  end
end
