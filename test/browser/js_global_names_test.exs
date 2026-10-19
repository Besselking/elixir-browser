defmodule Browser.JS.GlobalNamesTest do
  use ExUnit.Case, async: true
  alias Browser.JS.{Builtins, Interp, Modules, Parser}

  # `Interp.run_program/2` gives the `var` names of a script (without the memo) to
  # GlobalDeclarationInstantiation and to the hoist.

  # runs the scripts one after the other in one heap; gives the name of the error of each
  defp scripts(srcs) do
    Task.async(fn ->
      Interp.init(100_000)
      Builtins.install()

      for src <- srcs do
        {:ok, program} = Parser.parse(src)

        try do
          Interp.run_program(program, true)
          :ok
        catch
          {:js_error, e} -> Interp.get(e, "name")
        end
      end
    end)
    |> Task.await()
  end

  test "a var may not take the name of a let of an earlier script" do
    assert scripts(["let q = 1;", "var q;", "var r; q"]) == [:ok, "SyntaxError", :ok]
  end

  test "a new var needs a global object that can take new properties" do
    assert scripts(["var old;", "Object.preventExtensions(globalThis);", "var old;", "var nu;"]) ==
             [:ok, :ok, :ok, "TypeError"]
  end

  test "a var is hoisted, and a var of a script is not configurable" do
    assert scripts(["typeof v === 'undefined' && v === undefined; var v = 1;"]) == [:ok]

    assert scripts([
             "var w = 1;",
             "if (delete globalThis.w || w !== 1) throw new TypeError()"
           ]) == [:ok, :ok]
  end

  test "a var of a module body is hoisted" do
    src = "var seen = v === undefined; var v = 1; export { seen, v };"

    ns =
      Task.async(fn ->
        Interp.init(100_000)
        Builtins.install()
        Modules.reset()
        {:ok, program} = Parser.parse(src, module: true)
        loader = {fn _, _ -> {:error, "none"} end, fn _ -> {:error, "none"} end}
        ns = Modules.run(:main, "main.js", program, loader)
        {Interp.get(ns, "seen"), Interp.get(ns, "v")}
      end)
      |> Task.await()

    assert ns == {true, 1.0}
  end
end
