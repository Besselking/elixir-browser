defmodule Browser.JS.BookkeepingTest do
  @moduledoc """
  The bookkeeping of the interpreter in the process dictionary: the step budget
  (`:js_steps`), the heap count (`Interp.heap_size/0`, from `:js_next` and `:js_freed`) and
  the position of the statement that runs (`:js_pos`), which the error positions and the
  stack text read. The rows pin what a program sees of them, at all levels of the
  resolver, so that a cheaper bookkeeping cannot change it.
  """
  use ExUnit.Case, async: true

  alias Browser.JS
  alias Browser.JS.{Builtins, GC, Interp, Parser}

  @levels [:off, :info, 1, 2, 3, 4]
  @s "\n    at "

  # The steps of a call and of a round of a loop: the number of lines that a program logs
  # before its budget of steps is spent.
  @step_rows [
    {"while", "var i = 0; while (true) { console.log(i++) }", 60},
    {"for", "for (var i = 0; ; i++) console.log(i)", 60},
    {"calls", "function f(i){ console.log(i); return i + 1 }\nvar i = 0; while (true) i = f(i)",
     90},
    {"recursion", "function r(n){ console.log(n); r(n + 1) }\nr(0)", 70},
    {"for-of",
     "var a = []; for (var k = 0; k < 500; k++) a.push(k);\nfor (const x of a) console.log(x)",
     1400},
    {"closures",
     "function mk(n){ return function(){ return n } }\nfor (let i = 0; ; i++) console.log(mk(i)())",
     90},
    {"do-while", "var j = 0; do { console.log(j++) } while (true)", 60},
    {"methods",
     "class C { m(i){ return i * 2 } }\nconst c = new C();\nfor (let i = 0; ; i++) console.log(c.m(i))",
     90}
  ]

  # The positions of errors and of the frames of a stack: a throw in the update of a loop,
  # in its test, after a call came back, in a `finally`, in a callback of a built-in and in
  # a getter.
  @pos_rows [
    {"update",
     "function f(){\n  for (var i = 0; i < 3;\n    i = i.x.y) {\n    var z = i }\n}\ntry { f() } catch (e) { e.stack }",
     "TypeError: Cannot read properties of undefined (reading 'y')" <>
       @s <> "f (t.js:4)" <> @s <> "t.js:6"},
    {"test",
     "var o = null;\nfunction f(){\n  var n = 0;\n  while (o.k) {\n  n++ }\n}\ntry { f() } catch (e) { e.stack }",
     "TypeError: Cannot read properties of null (reading 'k')" <>
       @s <> "f (t.js:4)" <> @s <> "t.js:7"},
    {"after a call",
     "function g(){\n  return 1 }\nfunction f(){\n  var a = g(); var b = a.p.q;\n}\ntry { f() } catch (e) { e.stack }",
     "TypeError: Cannot read properties of undefined (reading 'q')" <>
       @s <> "f (t.js:4)" <> @s <> "t.js:6"},
    {"finally",
     "function f(){\n  try {\n    return 1\n  } finally {\n    null.x }\n}\ntry { f() } catch (e) { e.stack }",
     "TypeError: Cannot read properties of null (reading 'x')" <>
       @s <> "f (t.js:5)" <> @s <> "t.js:7"},
    {"callback",
     "function cb(x){\n  return x.y.z }\nfunction f(){\n  return [1].map(cb) }\ntry { f() } catch (e) { e.stack }",
     "TypeError: Cannot read properties of undefined (reading 'z')" <>
       @s <> "cb (t.js:2)" <> @s <> "f (t.js:4)" <> @s <> "t.js:5"},
    {"getter",
     "var o = {\n  get p(){\n    return new Error(\"g\").stack } };\nfunction h(){\n  var a = 1;\n  return o.p }\nh()",
     "Error: g" <> @s <> "get p (t.js:3)" <> @s <> "h (t.js:6)" <> @s <> "t.js:7"},
    {"constructor",
     "class A {\n  constructor(){\n    this.s = new Error(\"c\").stack } }\nfunction mk(){\n  var q = 0;\n  return new A().s }\nmk()",
     "Error: c" <> @s <> "A (t.js:3)" <> @s <> "mk (t.js:6)" <> @s <> "t.js:7"},
    {"next line",
     "function f(){ return 1 }\nfunction g(){\n  f();\n  return new Error(\"n\").stack }\ng()",
     "Error: n" <> @s <> "g (t.js:4)" <> @s <> "t.js:5"}
  ]

  describe "the step budget" do
    for {name, src, budget} <- @step_rows do
      test "#{name}: the same lines at every level" do
        results =
          for level <- @levels do
            {:error, :step_limit, console} =
              JS.eval(unquote(src), resolve: level, file: "t.js", max_steps: unquote(budget))

            {level, length(console)}
          end

        counts = results |> Enum.map(&elem(&1, 1)) |> Enum.uniq()
        assert length(counts) == 1, inspect(results)
        assert {unquote(name), hd(counts)} == {unquote(name), Map.fetch!(steps(), unquote(name))}
      end
    end
  end

  # The number of lines of each row of `@step_rows`. These are the counts of the interpreter
  # before `tick` became a macro and before the heap count came from `:js_freed`.
  defp steps do
    %{
      "while" => 30,
      "for" => 30,
      "calls" => 30,
      "recursion" => 35,
      "for-of" => 199,
      "closures" => 22,
      "do-while" => 30,
      "methods" => 30
    }
  end

  describe "the positions of errors and stacks" do
    for {name, src, stack} <- @pos_rows do
      test name do
        for level <- @levels do
          assert {unquote(name), level, JS.eval(unquote(src), resolve: level, file: "t.js")} ==
                   {unquote(name), level, {:ok, unquote(stack), []}}
        end
      end
    end
  end

  describe "the heap count" do
    test "is the number of heap entries after calls, closures, frees and a collection" do
      src = """
      function leaf(n){ var a = [n], o = { n: n }; return a.length + o.n }
      function keep(n){ return function(){ return n } }
      var kept = [];
      for (var i = 0; i < 50; i++) { leaf(i); if (i % 5 == 0) kept.push(keep(i)) }
      check("calls");
      kept = null;
      collect();
      check("collected");
      class P { constructor(x){ this.x = x } get y(){ return this.x } }
      for (var j = 0; j < 20; j++) new P(j).y;
      check("classes");
      function* gen(){ yield 1; yield 2 }
      for (const v of gen()) leaf(v);
      check("generator");
      """

      task =
        Task.async(fn ->
          Interp.init(1_000_000)
          Builtins.install()
          g = Interp.global()

          Interp.declare(
            g,
            "check",
            Interp.native("check", fn _, [label | _] ->
              send(self(), {:count, label, Interp.heap_size(), entries()})
              :undefined
            end)
          )

          Interp.declare(
            g,
            "collect",
            Interp.native("collect", fn _, _ ->
              GC.collect()
              :undefined
            end)
          )

          {:ok, program} = Parser.parse(src, resolve: 4)
          Interp.run_program(program, true)
          collect_counts([])
        end)

      counts = Task.await(task, 30_000)
      assert length(counts) == 4

      for {label, size, entries} <- counts do
        assert {label, size} == {label, entries}
      end
    end
  end

  defp collect_counts(acc) do
    receive do
      {:count, label, size, entries} -> collect_counts([{label, size, entries} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # The heap entries are the keys of the process dictionary that are integers from 0 up
  # (a negative key is a cell of an inline cache). A freed frame of the check build is a
  # tombstone, which the count does not hold.
  defp entries do
    Enum.count(Process.get(), fn
      {k, {:js_freed, _}} when is_integer(k) -> false
      {k, _} -> is_integer(k) and k >= 0
    end)
  end
end
