defmodule Browser.JS.CompileBudgetTest do
  # Step 5, the memory bound of design 3 and the budget test of design 5.4. Each parse of
  # `new Function` or `eval` code gives new uids, so a page that makes functions in a loop
  # adds an entry to the code cache for each one. The cache has a budget in compiled nodes
  # (`Browser.JS.Compile`): over the budget, all the entries go, and the count starts again.
  # A function with too many nodes stays on the tree.
  #
  # Each program runs in a fresh process with its own heap, as `Browser.JS.eval/2` runs a
  # script, so that the test can read the cache and its count after the script.
  #
  # Each heap turns its own switch `:js_compile` on. The code of `new Function` and of
  # `eval` is parsed at the level of the application, so the module sets the level to 4
  # for its tests (also when the suite runs with JS_RESOLVE=off). That setting is global
  # to the VM, so the module is not async.
  use ExUnit.Case, async: false

  alias Browser.JS.{Builtins, Interp, Parser}

  # The budget of `Browser.JS.Compile`, in compiled nodes.
  @budget 400_000

  # The test parses about 3.2M nodes of `new Function` code, which takes about 40 s, so it
  # runs only with `mix test --include corpus`.
  @tag :corpus
  @tag timeout: 600_000
  test "new Function 100k times in a loop keeps the code cache under the budget" do
    src = """
    var body = 'var s = a;' + ' s = s + 1;'.repeat(10) + ' return s';
    var t = 0;
    for (var i = 0; i < 100000; i++) { t += new Function('a', body)(i) }
    t
    """

    {value, {nodes, erases}, entries} = run(src)
    # (each call gives i + 10)
    assert value == Enum.sum(0..99_999) + 10 * 100_000 * 1.0
    assert nodes <= @budget
    assert erases >= 1
    assert entries < 100_000
  end

  test "over a small budget the cache is erased, and the count stays under the budget" do
    # (the same loop as the corpus test above, with a budget of 5,000 nodes in place of
    # the 400,000 of the browser, so that the erase happens in a fast test)
    src = """
    var body = 'var s = a;' + ' s = s + 1;'.repeat(10) + ' return s';
    var t = 0;
    for (var i = 0; i < 2000; i++) { t += new Function('a', body)(i) }
    t
    """

    {value, {nodes, erases}, entries} = run(src, 5_000)
    assert value == Enum.sum(0..1999) + 10 * 2000 * 1.0
    assert nodes <= 5_000
    assert erases >= 5
    assert entries < 2000
  end

  test "eval in a loop compiles each new function and counts its nodes" do
    src = """
    var t = 0;
    for (var i = 0; i < 2000; i++) { t += (0, eval)('(function (a) { var s = a; s = s + 1; return s })')(i) }
    t
    """

    {value, {nodes, erases}, entries} = run(src)
    assert value == Enum.sum(0..1999) + 2000 * 1.0
    # (the 2000 functions of the eval code, and the few functions of the prelude; each
    # entry counts its fixed part of 16 and its compiled nodes)
    assert entries >= 2000
    assert erases == 0
    assert nodes >= 2000 * 17 and nodes <= @budget
  end

  test "a function over the cap of nodes runs on the tree and gives the same value" do
    # (three nodes for each statement: the statement, the assignment and the addition)
    stmts = String.duplicate(" s = s + 1;", 22_000)
    src = "function big(a) { var s = a;#{stmts} return s } big(1) + big(2)"

    {value, _budget, _entries} = run(src)
    assert value == 22_001 + 22_002 * 1.0

    # (the function stays on the tree: its cache entry has no code)
    {:ok, program} = Parser.parse(src, resolve: 4)
    codes = run_codes(program)
    assert {nil, nil} in codes
  end

  test "the plans of generators count in the budget, and over a small budget the cache is erased" do
    # Step 5c: the plan of an async body or a generator goes into the same cache, under the
    # same uid, with the same count. Each parse of `GeneratorFunction` code gives a new uid.
    # The body yields in the middle, so the plan has a run of sync statements on each side.
    src = """
    var G = (function* () {}).constructor;
    var body = 'var s = a;' + ' s = s + 1;'.repeat(5) + ' yield s;' + ' s = s + 1;'.repeat(5);
    var t = 0;
    for (var i = 0; i < 2000; i++) { t += G('a', body)(i).next().value }
    t
    """

    {value, {nodes, erases}, entries} = run(src)
    assert value == Enum.sum(0..1999) + 5 * 2000 * 1.0
    assert entries >= 2000
    assert erases == 0
    assert nodes >= 2000 * 17 and nodes <= @budget

    {value, {nodes, erases}, entries} = run(src, 5_000)
    assert value == Enum.sum(0..1999) + 5 * 2000 * 1.0
    assert nodes <= 5_000
    assert erases >= 5
    assert entries < 2000
  end

  test "a generator over the cap of nodes runs on the tree path and gives the same value" do
    stmts = String.duplicate(" s = s + 1;", 22_000)

    src =
      "function* big(a) { var s = a;#{stmts} yield s } big(1).next().value + big(2).next().value"

    {value, _budget, _entries} = run(src)
    assert value == 22_001 + 22_002 * 1.0

    # (the body stays on the tree path: its cache entry has no plan)
    {:ok, program} = Parser.parse(src, resolve: 4)
    codes = run_codes(program)
    assert {nil, nil} in codes
  end

  test "each site of an inline cache counts one node" do
    {_, {named, _}, _} = run("function f(o){ return o.a + o.b + o.c } f({a: 1, b: 2, c: 3})")
    {_, {index, _}, _} = run("function f(o){ return o['0'] + o['1'] + o['2'] } f([1, 2, 3])")
    assert named - index == 3
  end

  # Runs `src` in a fresh heap. Gives the value, the count of the cache and the number of
  # entries of the cache.
  defp run(src, budget \\ nil) do
    in_heap(fn ->
      if budget, do: :erlang.put(:jsc_budget_max, budget)
      {:ok, program} = Parser.parse(src, resolve: 4)
      value = Interp.run_program(program, true)
      entries = Enum.count(:erlang.get(), &match?({{:jsc, _}, _}, &1))
      {value, :erlang.get(:jsc_budget), entries}
    end)
  end

  # Runs `program` in a fresh heap and gives the entries of its code cache.
  defp run_codes(program) do
    in_heap(fn ->
      Interp.run_program(program, true)
      for {{:jsc, _}, code} <- :erlang.get(), do: code
    end)
  end

  defp in_heap(fun) do
    old = Application.get_env(:browser, :js_resolve)
    Application.put_env(:browser, :js_resolve, 4)

    on_exit(fn ->
      if old == nil,
        do: Application.delete_env(:browser, :js_resolve),
        else: Application.put_env(:browser, :js_resolve, old)
    end)

    task =
      Task.async(fn ->
        Interp.init(100_000_000)
        # (the switch of this process only: the test needs the compiler also when the suite
        # runs with JS_COMPILE=0)
        :erlang.put(:js_compile, true)
        Builtins.install()
        fun.()
      end)

    Task.await(task, :infinity)
  end
end
