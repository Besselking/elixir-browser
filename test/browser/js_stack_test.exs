defmodule Browser.JS.StackTest do
  # Step 2f: the call stack is one chain of cells in `:js_stack`, and each cell carries
  # its depth. The first part is the semantic table of the design (section 6.2). Each row
  # runs at `:off`, `:info` and at levels 1 to 4 and must give one result. The table also
  # passes on the code before step 2f, so it pins the stack text, the console lines and
  # the depth limit. The second part has the unit tests of section 6.1. They build chains
  # by hand and look at the chain and the frames while a call runs. The design is
  # notes/js-frames-2f-design.md.
  use ExUnit.Case, async: true

  alias Browser.JS
  alias Browser.JS.{Builtins, GC, Interp, Parser, Runtime}
  alias Browser.JS.Resolve.{Info, Scope}
  require Interp

  # True in the check build (`JS_RESOLVE_CHECK=1`), which compares the chain with an
  # oracle at each call (design section 5).
  @check Application.compile_env(:browser, :js_resolve_check, false)

  @levels [:off, :info, 1, 2, 3, 4]

  # The text between two lines of a stack (`S` in the table of the design).
  @s "\n    at "
  @range "Maximum call stack size exceeded"

  # ── the semantic table (design 6.2) ────────────────────────

  # The `F` rows parse with the file name "t.js", so the stack lines have positions. They
  # run through `Browser.JS.eval/2` with the `:file` option. Each row gives the full result
  # of `eval`: the value and the console lines.
  @file_rows_2f [
    {"F1", "function a(){ return b() }\nfunction b(){\n return new Error(\"x\").stack }\na()",
     {:ok, "Error: x" <> @s <> "b (t.js:3)" <> @s <> "a (t.js:1)" <> @s <> "t.js:4", []}},
    # F1c and F1d (from the review): a throw out of a derived class constructor, before
    # and after `super()`, leaves the caller's stack as it was.
    {"F1c",
     "class A { constructor(){ throw 1 } }\nclass B extends A { constructor(){ super() } }\nfunction f(){ try { new B() } catch(e) {}\n return new Error(\"z\").stack }\nf()",
     {:ok, "Error: z" <> @s <> "f (t.js:4)" <> @s <> "t.js:5", []}},
    {"F1d",
     "class A {}\nclass B extends A { constructor(){ super(); throw 2 } }\nfunction f(){ try { new B() } catch(e) {}\n return new Error(\"z\").stack }\nf()",
     {:ok, "Error: z" <> @s <> "f (t.js:4)" <> @s <> "t.js:5", []}},
    {"F2",
     "function cb(){ return new Error(\"x\").stack }\nfunction o(){\n return [1].map(cb)[0] }\no()",
     {:ok, "Error: x" <> @s <> "cb (t.js:1)" <> @s <> "o (t.js:3)" <> @s <> "t.js:4", []}},
    {"F3",
     "function* g(){\n yield new Error(\"x\").stack }\nfunction o(){ return g().next().value }\no()",
     {:ok, "Error: x" <> @s <> "o (t.js:2)" <> @s <> "t.js:4", []}},
    {"F4",
     "function f(){ try { g() } catch(e) {}\n return new Error(\"y\").stack }\nfunction g(){\n throw 1 }\nf()",
     {:ok, "Error: y" <> @s <> "f (t.js:2)" <> @s <> "t.js:5", []}},
    {"F5", "function f(){ return eval(\"new Error('e').stack\") }\nf()",
     {:ok, "Error: e" <> @s <> "f (t.js:1)" <> @s <> "t.js:2", []}},
    {"F6",
     "var o = { get p(){ return new Error(\"g\").stack } };\nfunction h(){ return o.p }\nh()",
     {:ok, "Error: g" <> @s <> "get p (t.js:1)" <> @s <> "h (t.js:2)" <> @s <> "t.js:3", []}},
    {"F7", "function f(){ return new Function(\"return new Error('nf').stack\")() }\nf()",
     {:ok, "Error: nf" <> @s <> "anonymous (t.js:1)" <> @s <> "f (t.js:1)" <> @s <> "t.js:2", []}},
    {"F8",
     "\"use strict\"; function a(){ return b() }\nfunction b(){ return new Error(\"t\").stack }\nfunction c(){ var x = a(); return x }\nc()",
     {:ok, "Error: t" <> @s <> "b (t.js:2)" <> @s <> "c (t.js:3)" <> @s <> "t.js:4", []}},
    {"F9", "function f(n){ return n == 0 ? new Error(\"d\").stack : f(n-1) }\nf(10)",
     {:ok, "Error: d" <> String.duplicate(@s <> "f (t.js:1)", 11) <> @s <> "t.js:2", []}},
    {"F10", "function f(n){ return n == 0 ? new Error(\"d\").stack : f(n-1) }\nf(11)",
     {:ok, "Error: d" <> String.duplicate(@s <> "f (t.js:1)", 12), []}},
    {"F11", "function t(){ try { undefined.x } catch(e) { return e.stack } }\nt()",
     {:ok,
      "TypeError: Cannot read properties of undefined (reading 'x')" <>
        @s <> "t (t.js:1)" <> @s <> "t.js:2", []}},
    {"F12",
     "class A { constructor(){ this.s = new Error(\"c\").stack } }\nfunction mk(){\n return new A().s }\nmk()",
     {:ok, "Error: c" <> @s <> "A (t.js:1)" <> @s <> "mk (t.js:3)" <> @s <> "t.js:4", []}},
    {"F13",
     "function f(){ try { leaf() } catch(e) {}\n return g() }\nfunction leaf(){\n null.x }\nfunction g(){ return new Error(\"z\").stack }\nf()",
     {:ok, "Error: z" <> @s <> "g (t.js:5)" <> @s <> "f (t.js:2)" <> @s <> "t.js:6", []}},
    {"F14",
     "function f(){\n  return [g(), new Error(\"q\").stack][1] }\nfunction g(){\n  return 1 }\nf()",
     {:ok, "Error: q" <> @s <> "f (t.js:2)" <> @s <> "t.js:5", []}},
    # The async call `a()` gives back the position of `c` after its sync part, as a sync
    # call does, so `c` reports line 4, as in node 22. (Before the async call had a cell,
    # the position stayed at line 3, a quirk of design 1.3.)
    {"F15",
     "var x;\nasync function a(){\n  x = 1 }\nfunction c(){ a(); return new Error(\"z\").stack }\nc()",
     {:ok, "Error: z" <> @s <> "c (t.js:4)" <> @s <> "t.js:5", []}},
    {"F16",
     "function th(){\n  throw new Error(\"in\") }\nfunction c(){ try { th() } catch (e) { return e.stack + \" # \" + new Error(\"after\").stack } }\nc()",
     {:ok,
      "Error: in" <>
        @s <>
        "th (t.js:2)" <>
        @s <>
        "c (t.js:3)" <>
        @s <> "t.js:4 # Error: after" <> @s <> "c (t.js:3)" <> @s <> "t.js:4", []}},
    {"F17",
     "with ({}) { var dyn = function(){ return leaf() } }\nfunction leaf(){ return new Error('w').stack }\nfunction top(){\n  return dyn()\n}\ntop()",
     {:ok,
      "Error: w" <>
        @s <> "leaf (t.js:2)" <> @s <> "dyn (t.js:1)" <> @s <> "top (t.js:4)" <> @s <> "t.js:6",
      []}},
    {"F18", "function f(){\n  console.trace('here')\n}\nfunction g(){ f() }\ng()",
     {:ok, :undefined,
      [log: "Trace: here" <> @s <> "f (t.js:2)" <> @s <> "g (t.js:4)" <> @s <> "t.js:5"]}},
    {"F19", "function f(){\n  console.assert(false, 'nope')\n}\nf()",
     {:ok, :undefined, [error: "Assertion failed: nope" <> @s <> "f (t.js:2)" <> @s <> "t.js:4"]}},
    {"F22", "setTimeout(function tick(){\n  console.log(new Error('t').stack)\n}, 0)",
     {:ok, 1.0, [log: "Error: t" <> @s <> "tick (t.js:2)" <> @s <> "t.js:1"]}},
    {"F23", "Promise.resolve().then(function job(){\n  console.log(new Error('j').stack)\n})",
     {:ok, %{}, [log: "Error: j" <> @s <> "job (t.js:2)" <> @s <> "t.js:1"]}},
    {"F24",
     "function f(){\n  return [3,1,2].sort(function cmp(a, b){\n    if (a == 1) console.log(new Error('s').stack)\n    return a - b })\n}\nf()",
     {:ok, [1.0, 2.0, 3.0],
      [log: "Error: s" <> @s <> "cmp (t.js:3)" <> @s <> "f (t.js:2)" <> @s <> "t.js:6"]}},
    # The sync part of `a` has a line of its own, as in node 22.
    {"F25",
     "function inner(){ return new Error('i').stack }\nasync function a(){\n  return inner()\n}\nfunction outer(){\n  a().then(v => console.log(v))\n}\nouter()",
     {:ok, :undefined,
      [
        log:
          "Error: i" <>
            @s <>
            "inner (t.js:1)" <> @s <> "a (t.js:3)" <> @s <> "outer (t.js:6)" <> @s <> "t.js:8"
      ]}},
    # After `await` the body runs from a job, so it has a line, but no caller is on the
    # stack, as in node 22.
    {"F26",
     "function inner(){ return new Error('i').stack }\nasync function a(){\n  await 0\n  return inner()\n}\nfunction outer(){\n  a().then(v => console.log(v))\n}\nouter()",
     {:ok, :undefined, [log: "Error: i" <> @s <> "inner (t.js:1)" <> @s <> "a (t.js:4)"]}},
    {"F29", "function f(){ return (() => new Error('arrow').stack)() }\nf()",
     {:ok, "Error: arrow" <> @s <> "t.js:1" <> @s <> "f (t.js:1)" <> @s <> "t.js:2", []}}
  ]

  # The `F` rows with an uncaught throw. `Browser.JS.eval/2` reports only the first line of
  # an uncaught error, so these rows run as the page runtime runs a script (`run_page/2`).
  # The result is the description of the uncaught value with the position of its `throw`,
  # or `:ok`, and the console lines.
  @uncaught_rows_2f [
    {"F20", "function f(){\n  throw new TypeError('boom')\n}\nfunction g(){\n  f()\n}\ng()",
     {{:uncaught, "TypeError: boom" <> @s <> "f (t.js:2)" <> @s <> "g (t.js:5)" <> @s <> "t.js:7",
       {"t.js", 2}}, []}},
    {"F21", "function f(){\n  throw 'str'\n}\nf()", {{:uncaught, "str", {"t.js", 2}}, []}},
    {"F27",
     "function f(){\n  throw new RangeError('deep')\n}\nfunction g(){ return [1].map(f) }\ng()",
     {{:uncaught,
       "RangeError: deep" <> @s <> "f (t.js:2)" <> @s <> "g (t.js:4)" <> @s <> "t.js:5",
       {"t.js", 2}}, []}},
    {"F28", "setTimeout(function t(){\n  (function u(){ throw new Error('x') })() }, 0)",
     {:ok,
      [error: "Uncaught Error: x" <> @s <> "u (t.js:2)" <> @s <> "t (t.js:2)" <> @s <> "t.js:1"]}}
  ]

  # The `E` rows run through `Browser.JS.eval/2` with no file name, so the stack lines
  # have names only. Most rows count calls up to the depth limit of 1000.
  @rows_2f [
    {"E1", "var n = 0; function f(){ n++; f() } try { f() } catch(e) {} n", {:ok, 1000.0, []}},
    {"E2", "var n = 0; function f(){ n++; try { f() } catch(e) { } } f(); n", {:ok, 1000.0, []}},
    {"E3", "function f(n){ try { return f(n+1) } catch (e) { return n } } f(0)",
     {:ok, 999.0, []}},
    {"E4",
     "var n = 0; function a(k){ eval(\"\"); n++; return b(k) } function b(k){ return a(k+1) } try { a(0) } catch (e) { n + \" \" + e.message }",
     {:ok, "500 " <> @range, []}},
    {"E5", "var n=0; async function f(){ n++; await f() } f(); n", {:ok, 1000.0, []}},
    {"E6", "var n = 0; function f(){ n++; [0].map(f) } try { f() } catch (e) {} n",
     {:ok, 1000.0, []}},
    {"E7",
     "var d = 0; async function r(){ d++; await null } function s(n){ if (n == 0) return; r(); s(n - 1) } try { s(2000) } catch (e) { e.constructor.name + ' ' + d }",
     {:ok, "RangeError 999", []}},
    {"E8",
     "var n = 0; async function a(k){ n = k; if (k < 5000) await a(k + 1) } a(0).catch(e => 0); n",
     {:ok, 999.0, []}},
    {"E9",
     "var d = 0; function a(n){ d++; return b(n) } var b = function(n){ eval(''); d++; return a(n + 1) }; try { a(0) } catch (e) { e.constructor.name + ' ' + d }",
     {:ok, "RangeError 1000", []}},
    {"E10",
     "var d = 0; var o = { get p(){ d++; return this.p } }; try { o.p } catch (e) { e.constructor.name + ' ' + d }",
     {:ok, "RangeError 1000", []}},
    {"E11",
     "var d = 0; function f(){ d++; f.call(null) } try { f() } catch (e) { e.constructor.name + ' ' + d }",
     {:ok, "RangeError 1000", []}},
    {"E12",
     "function r(){ r() } var k = 0; for (var i = 0; i < 3; i++) { try { r() } catch (e) { k++ } } function d(n){ return n == 0 ? 0 : 1 + d(n-1) } k + ':' + d(990)",
     {:ok, "3:990", []}},
    {"E13",
     "function bad(n){ if (n == 0) throw 1; return bad(n-1) } function r(n){ try { return r(n+1) } catch(e){ return n } } for (var i = 0; i < 50; i++) { try { [0].forEach(function(){ bad(20) }) } catch (e) {} } r(0)",
     {:ok, 999.0, []}},
    {"E14",
     "function bad(n){ if (n == 0) throw 1; return bad(n-1) } function r(n){ try { return r(n+1) } catch(e){ return n } } var it = { [Symbol.iterator](){ return this }, next(){ return {done: false} }, return(){ return {} } }; for (var i = 0; i < 50; i++) { try { for (var x of it) bad(20) } catch (e) {} } r(0)",
     {:ok, 999.0, []}},
    {"E15",
     "function r(n){ try { return r(n+1) } catch(e){ return e.stack.split('\\n').length } } r(0)",
     {:ok, 13.0, []}},
    {"E16",
     "function f(){ [1,2].forEach(function cb(){ try { (function th(){ throw 1 })() } catch(e){} }); return new Error(\"w\").stack } f()",
     {:ok, "Error: w" <> @s <> "f", []}},
    {"E17",
     "var p = new Promise(function ex(){ (function th(){ throw 1 })() }); (function after(){ return new Error(\"q\").stack })()",
     {:ok, "Error: q" <> @s <> "after", []}},
    {"E18",
     "var b = function(){ return new Error('b').stack }.bind(null); function f(){ return b() } f()",
     {:ok, "Error: b" <> @s <> "<anonymous>" <> @s <> "f", []}},
    {"E19",
     "var s; var it = { [Symbol.iterator](){ return this }, next(){ return {done: false} }, return: function ret(){ s = new Error(\"r\").stack; return {} } }; function th(){ throw 1 } function f(){ try { for (var x of it) { th() } } catch (e) {} return s } f()",
     {:ok, "Error: r" <> @s <> "ret" <> @s <> "f", []}},
    {"E20",
     "var s; var o = { [Symbol.dispose]: function disp(){ s = new Error(\"d\").stack } }; function th(){ throw 1 } function f(){ try { using r = o; th() } catch (e) {} return s } f()",
     {:ok, "Error: d" <> @s <> "disp" <> @s <> "f", []}},
    {"E21", "new Proxy({}, { get: function trap(){ return new Error(\"p\").stack } }).x",
     {:ok, "Error: p" <> @s <> "trap", []}},
    {"E22", "JSON.stringify({toJSON: function toJSON(){ return new Error(\"tj\").stack }})",
     {:ok, "\"Error: tj\\n    at toJSON\"", []}},
    {"E23",
     "JSON.parse(\"[1]\", function rv(k, v){ return k === \"0\" ? new Error(\"j\").stack : v })[0]",
     {:ok, "Error: j" <> @s <> "rv", []}},
    {"E24",
     "function P(){ return mk() } function mk(){ return {s: new Error(\"n\").stack} } new P().s",
     {:ok, "Error: n" <> @s <> "mk" <> @s <> "P", []}},
    {"E25",
     "class A { m(){ return new Error(\"s\").stack } } class B extends A { m(){ return super.m() } } new B().m()",
     {:ok, "Error: s" <> @s <> "m", []}},
    {"E26",
     "class A { constructor(){ this.s = new Error('c').stack } } class B extends A { constructor(){ super() } } new B().s",
     {:ok, "Error: c" <> @s <> "A" <> @s <> "B", []}},
    {"E27",
     "class K { static m(){ return new Error('st').stack } #p(){ return new Error('pr').stack } q(){ return this.#p() } } K.m() + ' / ' + new K().q()",
     {:ok, "Error: st" <> @s <> "m / Error: pr" <> @s <> "#p", []}},
    {"E28",
     Enum.map_join(?a..?l, " ", fn c -> "function #{<<c>>}(){ return #{<<c + 1>>}() }" end) <>
       " function m(){ return new Error('m').stack } a()",
     {:ok, "Error: m" <> Enum.map_join(?m..?b//-1, fn c -> @s <> <<c>> end), []}},
    {"E29",
     "var s; async function a(){ await 0; s = (function inner(){ return new Error(\"aw\").stack })() } function c(){ a() } c(); setTimeout(() => console.log(s), 0); 1",
     {:ok, 1.0, [log: "Error: aw" <> @s <> "inner" <> @s <> "a"]}},
    {"E30",
     "function* g(){ try { yield 1 } catch (e) { yield (function c(){ return new Error(\"gc\").stack })() } } function o(){ var it = g(); it.next(); return it.throw(1).value } o()",
     {:ok, "Error: gc" <> @s <> "c" <> @s <> "o", []}},
    {"E31", "async function a(){ throw new Error('rej') } a().catch(e => console.log(e.stack))",
     {:ok, %{}, [log: "Error: rej" <> @s <> "a"]}},
    # A generator call and its resume do not count, so the recursion ends at the step
    # limit and not at the depth limit. The row runs with a lower step limit (see
    # `@row_opts`), because each `yield*` level makes the next step slower.
    {"E32", "var d = 0; function* g(){ d++; yield* g() } g().next()", {:error, :step_limit, []}},
    {"E33",
     "\"use strict\"; function g(){ return new Error(\"tc\").stack } function f(){ return g() } function h(){ return [f()][0] } h()",
     {:ok, "Error: tc" <> @s <> "g" <> @s <> "h", []}}
  ]

  # Extra options of `Browser.JS.eval/2` for some rows. Row E32 takes about 3 seconds at
  # the default step limit, which is too near the default timeout of 5 seconds when the
  # whole suite runs. A lower step limit gives the same result in less time.
  @row_opts %{"E32" => [max_steps: 100_000]}

  # Runs `src` with the file name "t.js" as the page runtime runs a script: an uncaught
  # error is described with its stack (`Browser.JS.Runtime.describe/1`), and a timer's
  # uncaught error becomes an error line of the console.
  defp run_page(src, level) do
    Task.async(fn ->
      Interp.init(1_000_000)
      Builtins.install()
      assert {:ok, program} = Parser.parse(src, resolve: level, file: "t.js"), src

      on_error = fn v ->
        line = {:error, "Uncaught " <> Runtime.describe(v)}
        Process.put(:js_console, [line | Process.get(:js_console, [])])
      end

      outcome =
        try do
          Interp.run_program(program, true)
          Builtins.run_timers(on_error)
          :ok
        catch
          {:js_error, v} -> {:uncaught, Runtime.describe(v), Process.get(:js_throw_pos)}
        end

      {outcome, Enum.reverse(Process.get(:js_console, []))}
    end)
    |> Task.await(30_000)
  end

  describe "step 2f: the semantic table at :off, :info and levels 1 to 4" do
    for {n, src, expected} <- @file_rows_2f do
      test "row #{n}" do
        for level <- @levels do
          assert {unquote(n), level, JS.eval(unquote(src), resolve: level, file: "t.js")} ==
                   {unquote(n), level, unquote(Macro.escape(expected))}
        end
      end
    end

    for {n, src, expected} <- @uncaught_rows_2f do
      test "row #{n}" do
        for level <- @levels do
          assert {unquote(n), level, run_page(unquote(src), level)} ==
                   {unquote(n), level, unquote(Macro.escape(expected))}
        end
      end
    end

    for {n, src, expected} <- @rows_2f do
      test "row #{n}" do
        for level <- @levels do
          opts = [resolve: level] ++ Map.get(@row_opts, unquote(n), [])

          assert {unquote(n), level, JS.eval(unquote(src), opts)} ==
                   {unquote(n), level, unquote(Macro.escape(expected))}
        end
      end
    end
  end

  # ── helpers for the unit tests ─────────────────────────────

  # Starts a heap in the test process. The built-ins must exist because an error thrown
  # by the evaluator is an object with a prototype. `Interp.init/1` gives out the ids from
  # 0 again, but the prelude keeps the functions that it made under `{:js_prelude, name}`.
  # A test that makes a second heap must remove them, or a stub calls an id of the old
  # heap.
  defp heap do
    for {{:js_prelude, _} = key, _} <- Process.get(), do: Process.delete(key)
    Interp.init(1_000_000)
    Builtins.install()
    Interp.global()
  end

  # Parses `src` at `level` with the file name "t.js" and runs it in the test process.
  # The file name gives `{:pos}` nodes, so the body of each function moves `:js_pos`.
  defp run_script(src, level) do
    assert {:ok, program} = Parser.parse(src, resolve: level, file: "t.js"), src
    Interp.run_program(program, true)
  end

  defp global!(gid, name) do
    assert {:ok, v} = Interp.lookup_scoped(gid, name), name
    v
  end

  # The closure record of a function object.
  defp closure({:obj, id}) do
    %{fun: {:closure, c}} = Interp.deref(id)
    c
  end

  # True when the frame `id` holds no heap entry after its call. A leaf frame of a normal
  # build is not a heap entry: it stays under the key of its depth (`Interp.leaf_base/0`).
  defp freed?(id) do
    case :erlang.get(id) do
      :undefined -> true
      {:js_freed, _} -> true
      _ -> id >= Interp.leaf_base()
    end
  end

  # Sets the chain and the position as a caller would leave them. The value `:undefined`
  # removes the chain, as in a process that did not call `Interp.init/1`. The leaf frames
  # of earlier calls go, so that a leaf frame that `frame_of_call/0` finds is from the
  # next call.
  defp put_caller(chain, pos) do
    put_chain(chain)
    :erlang.put(:js_pos, pos)
    for d <- 0..1001, do: :erlang.erase(Interp.leaf_base() + d)
  end

  # Element 3 of a frame: its chain in the check build, `nil` in a normal build.
  defp link(chain), do: if(@check, do: chain)

  # Writes a hand-built chain to `:js_stack`. In the check build, the oracle compares each
  # call with its own keys (design section 5, C3), so the test must also give the oracle
  # the same calls: the cells as `{name, call_pos}` and the depth of the head.
  # Without this, the oracle stays empty and the first call fails the check.
  defp put_chain(:undefined) do
    :erlang.erase(:js_stack)

    if @check do
      :erlang.erase(:js_check_stack)
      :erlang.erase(:js_check_depth)
    end
  end

  defp put_chain(chain) do
    :erlang.put(:js_stack, chain)

    if @check do
      :erlang.put(:js_check_stack, for({name, pos, _} <- chain, do: {name, pos}))

      depth =
        case chain do
          [{_, _, d} | _] -> d
          _ -> 0
        end

      :erlang.put(:js_check_depth, depth)
    end
  end

  # A native `snap()` that records the chain and the position at the time of its call.
  # A native adds no cell, so the head of the chain is the cell of the JS function that
  # called `snap`.
  defp install_snap(gid) do
    snap =
      Interp.native("snap", fn _this, _args ->
        seen = {:erlang.get(:js_stack), :erlang.get(:js_pos)}
        Process.put(:snaps, [seen | Process.get(:snaps, [])])
        :undefined
      end)

    Interp.declare(gid, "snap", snap)
  end

  defp snaps, do: Enum.reverse(Process.get(:snaps, []))

  # A native `peek()` that records the id of the newest function frame. The body of the
  # call that built the frame is still running at that time, so the test can look at
  # the frame before the call frees it.
  defp install_peek(gid) do
    peek =
      Interp.native("peek", fn _this, _args ->
        Process.put(:peeked, frame_of_call())
        :undefined
      end)

    Interp.declare(gid, "peek", peek)
  end

  defp peeked, do: Process.get(:peeked)

  # A native `probe()` that records the chain, the newest function frame and the newest
  # block frame.
  defp install_probe(gid) do
    probe =
      Interp.native("probe", fn _this, _args ->
        Process.put(:probed, {:erlang.get(:js_stack), frame_of_call(), newest(Scope)})
        :undefined
      end)

    Interp.declare(gid, "probe", probe)
  end

  # The frame of the JS call that called a native, as `{key, tuple}`. A native adds no
  # cell, so the head of the chain is the cell of that call. In a normal build the frame
  # of a leaf is under the key of the depth of its caller (`Interp.leaf_base/0`). Each
  # other frame is the newest heap frame.
  defp frame_of_call do
    key = Interp.leaf_base() + Interp.depth_of(:erlang.get(:js_stack)) - 1

    case :erlang.get(key) do
      t when is_tuple(t) and tuple_size(t) >= 5 and is_struct(elem(t, 1), Info) -> {key, t}
      _ -> newest(Info)
    end
  end

  # The newest heap entry that is a frame whose record (element 2) is a `struct`, as
  # `{id, tuple}`. The ids only go up, so the newest frame has the highest id.
  defp newest(struct) do
    last = :erlang.get(:js_next) - 1

    Enum.find_value(last..0//-1, fn id ->
      case :erlang.get(id) do
        t when is_tuple(t) and tuple_size(t) >= 5 ->
          if is_struct(elem(t, 1), struct), do: {id, t}

        _ ->
          nil
      end
    end)
  end

  # A chain of `n` cells, innermost first, as the calls would push them. The cell at the
  # bottom has the depth 1. A cell has the name "c<depth>" and the call position
  # `{"t.js", depth}`.
  defp chain(n), do: for(d <- n..1//-1, do: {"c#{d}", {"t.js", d}, d})

  # The stack text of `chain` under the innermost position `pos`, as the design says it
  # (2.5): one line per cell, at most 12 lines, and the script line only when
  # the walk reaches the bottom before 12 lines. This is a second, plain statement of
  # the rule, so the tests do not compare the evaluator with itself.
  defp text_of(header, chain, pos) do
    {lines, top} =
      Enum.reduce(chain, {[], pos}, fn {name, call_pos, _}, {lines, loc} ->
        {[line(name, loc) | lines], call_pos}
      end)

    lines = Enum.reverse(lines)

    script =
      if top != nil and length(lines) < 12,
        do: [@s <> elem(top, 0) <> ":#{elem(top, 1)}"],
        else: []

    header <> Enum.join(Enum.take(lines, 12) ++ script)
  end

  defp line(name, {file, l}), do: @s <> "#{name} (#{file}:#{l})"
  defp line(name, nil), do: @s <> name

  # The stack text of an error made under `chain` at the position `pos`.
  defp text(chain, pos) do
    put_chain(chain)
    :erlang.put(:js_pos, pos)
    Interp.stack_string("H")
  end

  # The three entries that count a call: a frame call (level 1), an old-path call (`:off`)
  # and the sync part of an async call.
  defp callees do
    gid = heap()
    run_script("function f(){ return 1 }", 1)
    frame_f = global!(gid, "f")
    assert %{info: %Info{rewritten: true}} = closure(frame_f)
    run_script("function g(){ return 1 }\nasync function a(){ return 1 }", :off)
    [{"frame", frame_f}, {"old path", global!(gid, "g")}, {"async", global!(gid, "a")}]
  end

  # Runs `fun` and gives the error that it threw as `{name, message, stack}`.
  # The properties are read on an empty chain, because a read can run a JS getter of the
  # prelude, and a deep chain would refuse that call. The chain comes back after the reads.
  defp js_error(fun) do
    assert {:js_error, e} = catch_throw(fun.())
    chain = :erlang.get(:js_stack)
    put_chain([])
    found = {Interp.get(e, "name"), Interp.get(e, "message"), Interp.get(e, "stack")}
    put_chain(chain)
    found
  end

  # ── the unit tests (design 6.1) ─────────────────────────────

  describe "the depth of a chain (depth_of)" do
    # `depth_of/1` is a macro for the engine only, so the test reads the depth that a call
    # puts in its own cell: the depth of the chain below it plus 1.
    test "an empty chain, no chain and a cell" do
      for level <- [:off, 1] do
        gid = heap()
        install_snap(gid)
        run_script("function f(){ snap() }", level)
        f = global!(gid, "f")
        if level == 1, do: assert(%{info: %Info{rewritten: true}} = closure(f))
        pos = {"u.js", 9}

        for {below, d} <- [
              {[], 0},
              {:undefined, 0},
              {[{"g", {"u.js", 1}, 7}], 7}
            ] do
          Process.delete(:snaps)
          put_caller(below, pos)
          assert Interp.call(f, :undefined, []) == :undefined
          assert [{[{"f", ^pos, depth} | rest], {"t.js", 1}}] = snaps()
          assert {level, below, depth} == {level, below, d + 1}
          assert rest == below
          assert :erlang.get(:js_stack) == below
          assert :erlang.get(:js_pos) == pos
        end
      end
    end
  end

  describe "the stack text (walk)" do
    test "0, 11, 12 and 13 cells, with positions" do
      heap()
      assert text([], {"t.js", 100}) == "H" <> @s <> "t.js:100"
      assert text([], nil) == "H"

      # The innermost function is at `:js_pos`, and each other function is at the call
      # position of the cell above it. The script line is at the call position of the
      # bottom cell.
      lines = fn n ->
        for k <- n..1//-1, do: @s <> "c#{k} (t.js:#{if k == n, do: 100, else: k + 1})"
      end

      assert text(chain(11), {"t.js", 100}) ==
               "H" <> Enum.join(lines.(11)) <> @s <> "t.js:1"

      assert text(chain(12), {"t.js", 100}) == "H" <> Enum.join(lines.(12))
      assert text(chain(13), {"t.js", 100}) == "H" <> Enum.join(Enum.take(lines.(13), 12))
    end

    test "0, 11, 12 and 13 cells, without positions" do
      heap()
      bare = fn n -> for d <- n..1//-1, do: {"c#{d}", nil, d} end
      names = fn n, k -> Enum.map_join(n..(n - k + 1)//-1, fn d -> @s <> "c#{d}" end) end

      assert text(bare.(0), nil) == "H"
      assert text(bare.(11), nil) == "H" <> names.(11, 11)
      assert text(bare.(12), nil) == "H" <> names.(12, 12)
      assert text(bare.(13), nil) == "H" <> names.(13, 12)
    end

    test "a method name, an empty name and no name" do
      heap()
      cells = [{{:method, "m"}, {"t.js", 3}, 3}, {"", {"t.js", 2}, 2}, {nil, {"t.js", 1}, 1}]

      assert text(cells, {"t.js", 9}) ==
               "H" <> @s <> "m (t.js:9)" <> @s <> "t.js:3" <> @s <> "t.js:2" <> @s <> "t.js:1"

      bare = [{{:method, "m"}, nil, 3}, {"", nil, 2}, {nil, nil, 1}]
      assert text(bare, nil) == "H" <> @s <> "m" <> @s <> "<anonymous>" <> @s <> "<anonymous>"
    end
  end

  describe "run_frame restores the caller" do
    test "after a return, a throw, an Elixir raise in a parameter default and the step limit" do
      gid = heap()
      install_peek(gid)
      Interp.declare(gid, "boom", Interp.native("boom", fn _, _ -> raise "boom" end))

      run_script(
        "function ok(){ peek()\n return 1 }\nfunction bad(){ peek()\n throw 1 }\n" <>
          "function dflt(a = peek(), b = boom()){ return 0 }\nfunction spin(){ peek()\n while (true) {} }",
        1
      )

      [ok, bad, dflt, spin] = for n <- ~w(ok bad dflt spin), do: global!(gid, n)
      for f <- [ok, bad, dflt, spin], do: assert(%{info: %Info{rewritten: true}} = closure(f))

      below = [{"outer", {"u.js", 1}, 1}]
      pos = {"u.js", 2}
      size = Interp.heap_size()

      runs = [
        {"return", fn -> assert Interp.call(ok, :undefined, []) == 1.0 end},
        {"throw",
         fn -> assert catch_throw(Interp.call(bad, :undefined, [])) == {:js_error, 1.0} end},
        {"raise",
         fn -> assert_raise RuntimeError, "boom", fn -> Interp.call(dflt, :undefined, []) end end},
        {"step limit",
         fn ->
           :erlang.put(:js_steps, 100)
           assert catch_throw(Interp.call(spin, :undefined, [])) == :js_limit
           :erlang.put(:js_steps, 1_000_000)
         end}
      ]

      for {what, run} <- runs do
        Process.delete(:peeked)
        put_caller(below, pos)
        run.()
        assert {fid, _} = peeked()
        assert {what, freed?(fid)} == {what, true}
        assert {what, :erlang.get(:js_stack)} == {what, below}
        assert {what, :erlang.get(:js_pos)} == {what, pos}
      end

      assert Interp.heap_size() == size
    end
  end

  describe "the frame header (element 3)" do
    test "a frame holds its own chain, and a block frame copies it" do
      gid = heap()
      install_probe(gid)

      run_script(
        "function f(){ probe() }\nfunction g(){ try { throw 7 } catch (e) { probe(); return () => e } }",
        2
      )

      f = global!(gid, "f")
      g = global!(gid, "g")
      assert %{info: %Info{rewritten: true}} = closure(f)
      assert %{info: %Info{rewritten: true}} = closure(g)

      below = [{"outer", {"u.js", 1}, 4}]
      pos = {"u.js", 2}

      # A leaf: in check mode element 3 is its own cell on the caller's chain, and it
      # equals the chain while the body runs. A normal build keeps `nil` there.
      put_caller(below, pos)
      Interp.call(f, :undefined, [])
      assert {chain, {_, frame}, _} = Process.get(:probed)
      assert chain == [{"f", pos, 5} | below]
      assert elem(frame, 2) == link(chain)
      assert elem(frame, 3) == pos

      # A catch frame: the header elements 3 to 5 are copies of the function frame's.
      put_caller(below, pos)
      Interp.call(g, :undefined, [])
      assert {chain, {_, frame}, {_, catch_frame}} = Process.get(:probed)
      assert %Scope{kind: :catch, frame: true} = elem(catch_frame, 1)
      assert chain == [{"g", pos, 5} | below]
      assert elem(frame, 2) == link(chain)
      assert elem(catch_frame, 2) == link(chain)
      assert elem(catch_frame, 3) == pos
      assert :erlang.get(:js_stack) == below
    end
  end

  describe "the depth limit with hand-built chains" do
    test "999 cells: the call works; 1000 cells: it throws with the caller's stack" do
      for {what, f} <- callees() do
        pos = {"t.js", 1000}
        put_caller(chain(999), pos)
        Interp.call(f, :undefined, [])
        assert {what, :erlang.get(:js_stack)} == {what, chain(999)}

        deep = chain(1000)
        put_caller(deep, pos)
        header = "RangeError: " <> @range

        # The call is refused before it pushes, so the stack of the error is the chain of
        # the caller: 1000 cells, of which the first 12 cells print.
        assert {"RangeError", @range, stack} = js_error(fn -> Interp.call(f, :undefined, []) end)
        assert {what, stack} == {what, text_of(header, deep, pos)}
        assert :erlang.get(:js_stack) == deep
        assert :erlang.get(:js_pos) == pos
      end
    end
  end

  describe "tail calls (tail_loop)" do
    test "a strict tail chain of 5000 calls keeps the depth of the first callee" do
      for level <- [:off, 1] do
        gid = heap()
        install_snap(gid)

        run_script(
          "\"use strict\"; function f(n){ if (n == 0) { snap(); return 0 }\n return f(n - 1) }",
          level
        )

        f = global!(gid, "f")
        pos = {"u.js", 4}
        Process.delete(:snaps)
        put_caller([], pos)
        assert Interp.call(f, :undefined, [5000.0]) == 0.0

        # The tail caller leaves before its callee runs, so each callee pushes on the
        # first caller's chain with the first caller's position.
        assert {^level, [{[{"f", ^pos, 1}], {"t.js", 1}}]} = {level, snaps()}
        assert :erlang.get(:js_stack) == []
      end
    end
  end

  describe "a tail site in a constructor (the tail call under `new` in frame_call/6)" do
    test "a throw restores the chain and frees the frame; a return gives the right value" do
      gid = heap()
      install_peek(gid)
      install_snap(gid)

      run_script(
        "\"use strict\"; function P(){ peek(); return th() }\nfunction th(){ throw 1 }\n" <>
          "function Q(){ peek(); return mk() }\nfunction mk(){ snap(); return {v: 7} }\n" <>
          "function R(){ this.w = 2; return prim() }\nfunction prim(){ return 5 }",
        1
      )

      [p, q, r] = for n <- ~w(P Q R), do: global!(gid, n)
      for f <- [p, q, r], do: assert(%{info: %Info{rewritten: true}} = closure(f))

      below = [{"outer", {"u.js", 1}, 1}]
      pos = {"u.js", 2}

      put_caller(below, pos)
      assert catch_throw(Interp.construct(p, [])) == {:js_error, 1.0}
      assert {fid, _} = peeked()
      assert freed?(fid)
      assert :erlang.get(:js_stack) == below
      assert :erlang.get(:js_pos) == pos

      # The callee of the tail site runs on top of the constructor's cell (row E24).
      put_caller(below, pos)
      obj = Interp.construct(q, [])
      assert Interp.get(obj, "v") == 7.0
      assert [{[{"mk", {"t.js", 3}, 3}, {"Q", ^pos, 2} | ^below], _}] = snaps()
      assert {fid, _} = peeked()
      assert freed?(fid)
      assert :erlang.get(:js_stack) == below

      # A primitive from the tail site gives the new object.
      put_caller(below, pos)
      obj = Interp.construct(r, [])
      assert Interp.get(obj, "w") == 2.0
      assert :erlang.get(:js_stack) == below
    end
  end

  describe "async calls (call_closure)" do
    test "the cell of the function is on the chain during the sync part and goes after it" do
      for level <- [:off, 4] do
        gid = heap()
        install_snap(gid)

        run_script(
          "async function ok(){ snap()\n return 1 }\nasync function bad(){ snap()\n throw 1 }",
          level
        )

        below = [{"outer", {"u.js", 1}, 3}]
        pos = {"u.js", 2}

        for name <- ["ok", "bad"] do
          Process.delete(:snaps)
          put_caller(below, pos)
          assert {:obj, _} = Interp.call(global!(gid, name), :undefined, [])
          assert {^level, ^name, [{[{^name, ^pos, 4} | ^below], _}]} = {level, name, snaps()}
          assert {level, name, :erlang.get(:js_stack)} == {level, name, below}
          assert {level, name, :erlang.get(:js_pos)} == {level, name, pos}
        end

        # At the depth limit the call is refused before the body runs.
        Process.delete(:snaps)
        deep = chain(1000)
        put_caller(deep, pos)
        ok = global!(gid, "ok")
        assert {"RangeError", @range, _} = js_error(fn -> Interp.call(ok, :undefined, []) end)
        assert snaps() == []
        assert :erlang.get(:js_stack) == deep
      end
    end
  end

  describe "async bodies that run again" do
    # A job runs the rest of the body after an await, so the cell has no call position,
    # and the chain under it is the chain of the job. A request of an async generator runs
    # the body at the position of the request, as a call does.
    test "after an await, and at a request of an async generator" do
      for level <- [:off, 4] do
        gid = heap()
        install_snap(gid)
        Process.delete(:snaps)

        run_script(
          "async function r(){ await 0\n snap() }\nasync function* g(){ snap()\n await 0\n snap() }\nr(); g().next()",
          level
        )

        assert {^level,
                [
                  {[{"g", {"t.js", 6}, 1}], {"t.js", 3}},
                  {[{"r", nil, 1}], {"t.js", 2}},
                  {[{"g", nil, 1}], {"t.js", 5}}
                ]} = {level, snaps()}

        # Each resumed body gives back the position, so after the jobs the position is
        # that of the last line of the script.
        assert :erlang.get(:js_stack) == []
        assert {^level, {"t.js", 6}} = {level, :erlang.get(:js_pos)}
      end
    end
  end

  describe "nested calls" do
    test "the cells carry the depths 1, 2 and 3 at every level" do
      for level <- @levels do
        gid = heap()
        install_snap(gid)

        run_script(
          "function a(){ return b() }\nfunction b(){\n return c() }\nfunction c(){ snap() }",
          level
        )

        Process.delete(:snaps)
        put_caller([], {"u.js", 7})
        Interp.call(global!(gid, "a"), :undefined, [])

        assert {^level,
                [{[{"c", {"t.js", 3}, 3}, {"b", {"t.js", 1}, 2}, {"a", {"u.js", 7}, 1}], _}]} =
                 {level, snaps()}

        assert :erlang.get(:js_stack) == []
      end
    end
  end

  describe "the GC and the frame header" do
    # Element 3 holds a depth and element 4 a line. Both can equal the id of an object, but
    # they are not references: the collector and the dangling scan must skip them.
    test "a depth and a line equal to an id keep nothing alive and give no dangling hit" do
      Task.async(fn ->
        heap()
        run_script("function f(){ return 1 }", 1)
        info = closure(global!(Interp.global(), "f")).info

        # `x` holds a scope edge to a freed frame, so the scan reports a hit when it
        # reaches `x`.
        tomb = Interp.alloc({:js_freed, "gone"})
        {:obj, x} = Interp.new_object([{"n", 1.0}])
        Interp.store(x, Map.put(Interp.deref(x), :parent, tomb))

        # The control: a slot that holds `x` is a reference, so the scan finds the hit.
        held = Interp.alloc({nil, info, nil, nil, Interp.global(), x})
        Process.put(:gc_test_frame, held)
        assert "gone" in GC.dangling(nil)

        # A frame that names `x` only as a depth and as a line.
        chain = [{"f", {"t.js", x}, x}]
        frame = Interp.alloc({nil, info, chain, {"t.js", x}, Interp.global()})
        Process.put(:gc_test_frame, frame)
        assert GC.dangling(nil) == []

        GC.collect()
        assert is_tuple(:erlang.get(frame))
        assert :erlang.get(x) == :undefined
      end)
      |> Task.await()
    end
  end

  if @check do
    describe "check mode" do
      # A native that pushes a cell and does not take it off. The next call of the
      # function that called it finds a chain that is not its own (C5).
      @tag :check
      test "a cell that is not restored fails the check" do
        gid = heap()

        leak =
          Interp.native("leak", fn _, _ ->
            [{_, _, d} | _] = s = :erlang.get(:js_stack)
            :erlang.put(:js_stack, [{"leak", nil, d + 1} | s])
            :undefined
          end)

        Interp.declare(gid, "leak", leak)
        run_script("function g(){ return 1 }\nfunction f(){ leak(); return g() }", 1)
        f = global!(gid, "f")
        put_caller([], nil)
        e = assert_raise(ArgumentError, fn -> Interp.call(f, :undefined, []) end)
        assert Exception.message(e) =~ "resolve check"
      end
    end
  end
end
