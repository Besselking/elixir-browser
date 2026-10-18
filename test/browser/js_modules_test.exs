defmodule Browser.JS.ModulesTest do
  use ExUnit.Case, async: true
  alias Browser.JS.{Builtins, Interp, Modules, Parser, Runtime}

  # The syntax tree of a module stays under a `:js_hoist` key of the process until its body
  # has run (`Browser.JS.Modules`). The tree of a script or of eval code is not kept.

  # runs `fun` in a heap of its own; gives its result and the count of the module trees
  defp in_heap(fun) do
    Task.async(fn ->
      Interp.init(100_000)
      Builtins.install()
      Modules.reset()
      result = fun.()
      {result, length(for {{:js_hoist, m}, _} <- Process.get(), elem(m, 0) == :module, do: 1)}
    end)
    |> Task.await()
  end

  # the files of the modules, by name; an unknown name is not found
  defp loader(files) do
    {fn spec, _base -> {:ok, Path.basename(spec)} end,
     fn name ->
       case files do
         %{^name => src} -> {:ok, src, name}
         _ -> {:error, "404"}
       end
     end}
  end

  defp run(key, src, files) do
    {:ok, program} = Parser.parse(src, module: true)
    Modules.run(key, "main.js", program, loader(files))
    :ok
  catch
    {:js_error, _} -> :error
  end

  test "the tree of a module goes when its body has run" do
    files = %{"a.js" => "export var a = 1;", "b.js" => "import { a } from './a.js'; var b = a;"}
    assert {:ok, 0} = in_heap(fn -> run(:main, "import './b.js'; var m = 1;", files) end)
  end

  test "the tree of a module goes when its body throws" do
    files = %{"a.js" => "throw new Error('a');"}
    assert {:error, 0} = in_heap(fn -> run(:main, "import './a.js';", files) end)
  end

  test "the tree of a module with top-level await goes when its body has run" do
    files = %{"a.js" => "var a = await 1; export { a };"}

    assert {:ok, 0} =
             in_heap(fn -> run(:main, "import { a } from './a.js'; var m = a;", files) end)
  end

  test "the tree of a module whose import rejects its top-level await goes" do
    files = %{"a.js" => "await Promise.reject(new Error('a'));"}
    assert {:error, 0} = in_heap(fn -> run(:main, "import './a.js'; var m = 1;", files) end)
  end

  test "a load that fails keeps no tree" do
    files = %{"a.js" => "import './missing.js'; export var a = 1;"}

    assert {[:error, :error, :error], 0} =
             in_heap(fn -> for i <- 1..3, do: run({:main, i}, "import './a.js';", files) end)
  end

  test "a script and eval code keep no tree" do
    {before, later} =
      Task.async(fn ->
        Interp.init(100_000)
        Builtins.install()
        count = fn -> length(for {{:js_hoist, l}, _} <- Process.get(), is_list(l), do: 1) end
        before = count.()
        {:ok, program} = Parser.parse("var x = 1; eval('var y = 2; x + y');")
        Interp.run_program(program, true)
        {before, count.()}
      end)
      |> Task.await()

    assert later == before
  end

  # Each frame has a record of its own for a module. The page links `a.js`, but its graph
  # does not link, so the body of `a.js` does not run there. The frame runs `a.js` and its
  # tree goes. Then the page imports `a.js` again and runs its own tree.
  test "a module in the page and in a frame: each record runs its own tree" do
    files = %{"http://t.test/a.js" => ~S|var a = 1; console.log("a " + a); export { a }|}

    fetch = fn url ->
      case files do
        %{^url => src} -> {:ok, src, url}
        _ -> {:error, "404"}
      end
    end

    body =
      ~S|<script type="module">import { nope } from "http://t.test/a.js"</script>| <>
        ~S|<iframe srcdoc="<script type=module>import 'http://t.test/a.js'</script>"></iframe>| <>
        ~S|<script>setTimeout(() => import("http://t.test/a.js").then(| <>
        ~S|m => console.log("page " + m.a), e => console.log("page " + e)), 100)</script>|

    {raw, _} = ("<body>" <> body <> "</body>") |> Browser.HTML.parse() |> Browser.Forms.index()
    pid = Runtime.start(raw, %{url: "http://t.test/", width: 800, height: 600, fetch: fetch})
    r = Runtime.run_scripts(pid)
    console = r.console ++ collect(pid)
    Runtime.stop(pid)
    assert for({:log, t} <- console, do: t) == ["a 1", "a 1", "page 1"]
  end

  defp collect(pid) do
    receive do
      {:js_async, ^pid, reply} -> reply.console ++ collect(pid)
    after
      300 -> Runtime.flush(pid).console
    end
  end
end
