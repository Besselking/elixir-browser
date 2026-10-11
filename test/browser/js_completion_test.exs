defmodule Browser.JS.CompletionTest do
  # Step 3: control flow as completions. Before step 3, `return`, `break`, `continue` and a
  # strict tail call are Elixir throws. After step 3, `exec/3` gives back `:ok`, `{:ret, v}`,
  # `{:brk, l}`, `{:cont, l}` or `{:tail, f, this, args}` at every level. The design is
  # notes/js-step3-design.md. This file pins the observable results before the change
  # (section 6.2 and the unit tests of 6.1), so every later commit must give the same
  # results at `:off` and at level 4. A few tests pin the result after a named commit of
  # section 8: the internal shapes of `exec_stmt`, the new `exec_frame_stmt/3` and the three
  # behaviour changes B1, D2 and D1.
  use ExUnit.Case, async: true

  alias Browser.JS
  alias Browser.JS.{Interp, Parser}
  alias Browser.JS.Resolve.Info

  @levels [:off, 4]

  # ── helpers ────────────────────────────────────────────────

  defp eval(src, level, opts \\ []), do: JS.eval(src, [resolve: level] ++ opts)

  # Starts a heap in the test process. The built-ins must exist because an error thrown by
  # the evaluator is an object with a prototype.
  defp heap do
    Interp.init(1_000_000)
    Browser.JS.Builtins.install()
    Interp.global()
  end

  defp find(node, pred) do
    cond do
      pred.(node) -> node
      is_tuple(node) -> node |> Tuple.to_list() |> find(pred)
      is_list(node) -> Enum.find_value(node, &find(&1, pred))
      true -> nil
    end
  end

  # The function node `f` of `src` at `level`, and its body.
  defp fn_f(src, level) do
    assert {:ok, tree} = Parser.parse(src, resolve: level), src
    node = find(tree, &match?({:fn, "f", _, _, _, _}, &1))
    assert node != nil, "no function f in #{src}"
    node
  end

  # A frame of the rewritten function `f` of `src`, stored in the heap under the global
  # scope `gid`, with the template values in its slots. The frame has no caller and no call
  # position, as the frames that js_frames_test.exs builds by hand.
  defp frame_of(src, gid) do
    {:fn, "f", _, body, _, %Info{rewritten: true} = info} = fn_f(src, 4)
    fid = Interp.alloc(List.to_tuple([gid, info, nil, nil, gid | info.template]))
    {body, fid}
  end

  # A native function `g` that gives 42, bound in the global scope.
  defp native_g(gid) do
    g = Interp.native("g", fn _this, _args -> 42.0 end)
    Interp.declare(gid, "g", g)
    g
  end

  # Runs a script in the test process at the given level.
  defp run_script(src, level) do
    assert {:ok, program} = Parser.parse(src, resolve: level), src
    Interp.run_program(program, true)
  end

  # ── 6.2: the snippet rows ──────────────────────────────────

  # Each row runs through `JS.eval` at `:off` and at level 4 and must give its value at
  # both. The names are the row numbers of section 6.2. A row with a letter after the
  # number is one of the cases that the row of the design lists together. The rows X1 to
  # X13 come from the source designs in notes/js-step3/ and cover more of the same ground.
  # Row X11 is with D1 below, because commit 10 changes it.
  @rows [
    {"R1",
     ~S|var r = []; a: for (var i = 0; i < 3; i++) { b: for (var j = 0; j < 3; j++) { if (j == 1) continue a; if (i == 2) break a; r.push(i + "" + j) } } r.join()|,
     "00,10"},
    {"R2",
     ~S|(function(){ var r = []; a: for (let i = 0; i < 3; i++) { b: for (let j = 0; j < 3; j++) { if (j == 1) continue a; if (i == 2) break a; r.push(i + "" + j) } } return r.join() })()|,
     "00,10"},
    {"R3", ~S|var r = ""; l: { r += "a"; if (r) break l; r += "b" } r|, "a"},
    {"R4", ~S|(function(){ a: { b: { break a } return "no" } return "yes" })()|, "yes"},
    {"R5",
     ~S|(function(){ var i = 0; a: while (true) { switch (i++) { case 0: continue a; case 1: break; case 2: break a } } return i })()|,
     3.0},
    {"R6",
     ~S|(function(){ var s = ""; switch (2) { case 1: s += "1"; case 2: s += "2"; case 3: s += "3"; break; case 4: s += "4" } return s })()|,
     "23"},
    {"R7",
     ~S|(function(){ var s = ""; switch (9) { case 1: s += "1"; default: s += "d"; case 2: s += "2" } return s })()|,
     "d2"},
    {"R8",
     ~S|(function(){ var r = []; for (var i = 0; i < 3; i++) { switch (i) { case 0: continue; case 1: r.push("one"); break; default: return r.join() + "!" } r.push("after" + i) } })()|,
     "one,after1!"},
    {"R9",
     ~S|function f(x) { switch (x) { case 1: { let y = 1; if (y) break } return "no"; default: return "d" } return "out" } f(1) + f(2)|,
     "outd"},
    {"R10", ~S|(function(){ l: switch (1) { case 1: for (;;) { break l } } return "ok" })()|,
     "ok"},
    {"R11", ~S|var s = 0, i = 0; do { i++; if (i == 2) continue; s += i } while (i < 4); s|, 8.0},
    {"R12",
     ~S|var s = ""; for (var k in {a: 1, b: 2, c: 3}) { if (k == "b") continue; s += k } s|,
     "ac"},
    {"R13",
     ~S|var r = []; l: for (var k in {a: 1, b: 2, c: 3}) for (var x of [1, 2]) { if (k == "b") continue l; r.push(k + x) } r.join()|,
     "a1,a2,c1,c2"},
    {"R14", ~S|(function(){ try { return 1 } finally { return 2 } })()|, 2.0},
    {"R15", ~S|(function(){ try { throw 1 } finally { return "f" } })()|, "f"},
    {"R16", ~S|(function(){ l: try { return "t" } finally { break l } return "after" })()|,
     "after"},
    {"R17", ~S|(function(){ for (;;) { try { return 1 } finally { break } } return 3 })()|, 3.0},
    {"R18",
     ~S|(function(){ var c = 0; for (var i = 0; i < 5; i++) { try { continue } finally { c++ } } return c })()|,
     5.0},
    {"R19",
     ~S|(function(){ var i = 0; l: while (true) { try { if (i++ > 2) break l; continue l } finally { if (i == 2) return "fin" + i } } })()|,
     "fin2"},
    {"R20",
     ~S|var log = []; (function(){ try { try { return "inner" } finally { log.push(1) } } finally { log.push(2) } })() + log.join()|,
     "inner1,2"},
    {"R21",
     ~S|(function(){ try { try { throw 1 } catch (e) { throw 2 } finally { return "fin" } } catch (e) { return "outer" + e } })()|,
     "fin"},
    {"R22",
     ~S|(function(){ try { try { return "in" } finally { throw "x" } } catch (e) { return "caught " + e } })()|,
     "caught x"},
    {"R23",
     ~S|(function(){ var s = ""; for (var i = 0; i < 3; i++) { try { if (i == 1) return s + "r"; s += i } finally { s += "f"; if (i == 1) continue } } return s })()|,
     "0ff2f"},
    {"R25",
     ~S|var log = []; var it = {[Symbol.iterator]() { return this }, i: 0, next() { return {value: this.i++, done: false} }, return() { log.push("close"); return {} }}; (function(){ for (var x of it) { if (x == 2) return x } })() + log.join()|,
     "2close"},
    {"R26",
     ~S|var log = []; function mk(name) { var i = 0; return {[Symbol.iterator]() { return this }, next() { return {value: i++, done: i > 3} }, return() { log.push(name); return {} }} } outer: for (var a of mk("A")) { for (var b of mk("B")) { break outer } } log.join()|,
     "B,A"},
    {"R27",
     ~S|var log = []; var it = {[Symbol.iterator]() { return this }, i: 0, next() { return {value: this.i++, done: false} }, return() { log.push("close"); return {} }}; (function(){ for (var x of it) { try { return "r" } finally { log.push("fin") } } })() + log.join()|,
     "rfin,close"},
    {"R28",
     ~S|var it = {[Symbol.iterator]() { return this }, next() { return {value: 1, done: false} }, return() { throw "fromReturn" }}; try { (function(){ for (var x of it) return "r" })() } catch (e) { e }|,
     "fromReturn"},
    {"R29",
     ~S|var it = {[Symbol.iterator]() { return this }, next() { return {value: 1, done: false} }, return() { return 5 }}; try { for (var x of it) break; "no error" } catch (e) { e.constructor.name }|,
     "TypeError"},
    {"R30",
     ~S|var it = {[Symbol.iterator]() { return this }, next() { return {value: 1, done: false} }, return() { throw "ret" }}; try { for (var x of it) throw "body" } catch (e) { e }|,
     "body"},
    {"R33",
     ~S|var log = []; function* g() { try { yield 1; yield 2 } finally { log.push("gf") } } (function(){ for (var x of g()) { return x } })() + log.join()|,
     "1gf"},
    {"R34",
     ~S|var log = []; var s = {[Symbol.dispose]() { log.push("d") }}; (function(){ { using r = s; return "x" } })() + log.join()|,
     "xd"},
    {"R35",
     ~S|var log = []; var s = {[Symbol.dispose]() { log.push("d") }}; (function(){ for (var i = 0; i < 3; i++) { using r = s; if (i == 1) break; log.push(i) } })(); log.join()|,
     "0,d,d"},
    {"R36",
     ~S|try { (function(){ using r = {[Symbol.dispose]() { throw "disposeErr" }}; return "ret" })() } catch (e) { e }|,
     "disposeErr"},
    {"R37",
     ~S|"use strict"; function f(n) { if (n === 0) return "done"; return f(n - 1) } f(100000)|,
     "done"},
    {"R38w",
     ~S|"use strict"; function f(n) { while (true) { if (n === 0) return "w"; return f(n - 1) } } f(100000)|,
     "w"},
    {"R38l",
     ~S|"use strict"; function f(n) { if (n === 0) return "l"; L: { return f(n - 1) } } f(100000)|,
     "l"},
    {"R38s",
     ~S|"use strict"; function f(n) { switch (n) { case 0: return "s"; default: return f(n - 1) } } f(100000)|,
     "s"},
    {"R38c",
     ~S|"use strict"; function f(n) { if (n === 0) return "c"; try { throw 0 } catch (e) { return f(n - 1) } } f(100000)|,
     "c"},
    {"R38dw",
     ~S|"use strict"; function f(n) { do { if (n === 0) return "dw"; return f(n - 1) } while (false) } f(100000)|,
     "dw"},
    {"R38fl",
     ~S|"use strict"; function f(n) { for (let i = 0; i < 1; i++) { if (n === 0) return "fl"; return f(n - 1) } } f(100000)|,
     "fl"},
    {"R39f",
     ~S|"use strict"; function f(n) { if (n === 0) return "fin"; try { } finally { return f(n - 1) } } f(100000)|,
     "fin"},
    {"R39cf",
     ~S|"use strict"; function f(n) { if (n === 0) return "cf"; try { throw 0 } catch (e) { } finally { return f(n - 1) } } f(100000)|,
     "cf"},
    {"R40b",
     ~S|"use strict"; function f(n) { { let k = n; if (k === 0) return "blk"; return f(k - 1) } } f(100000)|,
     "blk"},
    {"R40f",
     ~S|"use strict"; function f(n) { { let k = n; var g = () => k; if (k === 0) return "fr" + g(); return f(k - 1) } } f(100000)|,
     "fr0"},
    {"R41c", ~S|"use strict"; function f(n) { return n == 0 ? "c" : f(n - 1) } f(100000)|, "c"},
    {"R41o", ~S'"use strict"; function f(n) { return n == 0 || f(n - 1) } f(100000)', true},
    {"R41q", ~S|"use strict"; function f(n) { return (0, n == 0 ? "q" : f(n - 1)) } f(100000)|,
     "q"},
    {"R42o",
     ~S|"use strict"; function f(n) { if (n === 0) return "done"; for (var x of [1]) { return f(n - 1) } } try { f(2000) } catch (e) { e.constructor.name }|,
     "RangeError"},
    {"R42t",
     ~S|"use strict"; function f(n) { if (n === 0) return "done"; try { return f(n - 1) } finally { } } try { f(5000) } catch (e) { e.constructor.name }|,
     "RangeError"},
    {"R42s",
     ~S|function f(n) { if (n === 0) return "done"; return f(n - 1) } try { f(100000) } catch (e) { e.constructor.name }|,
     "RangeError"},
    {"R43m",
     ~S|"use strict"; var o = { m(n) { return n === 0 ? "m" : this.m(n - 1) } }; o.m(100000)|,
     "m"},
    {"R43k",
     ~S|"use strict"; class K { k(n) { return n === 0 ? "k" : this.k(n - 1) } } new K().k(100000)|,
     "k"},
    {"R44b",
     ~S|"use strict"; var b = function f(n) { return n === 0 ? "b" : b(n - 1) }.bind(null); b(100000)|,
     "b"},
    {"R44a",
     ~S|"use strict"; function f(n) { return n === 0 ? "a" : f.apply(null, [n - 1]) } f(100000)|,
     "a"},
    {"R45",
     ~S|"use strict"; var f = function(n) { return n }; function P() { return f(10) } new P() instanceof P|,
     true},
    {"R45b",
     ~S|"use strict"; var f = function(n) { return {n: n} }; function P() { return f(10) } var p = new P(); (p instanceof P) + ":" + p.n|,
     "false:10"},
    {"R46", ~S|function h() { return 7 } function* g() { return h() } g().next().value|, 7.0},
    {"R47",
     ~S|"use strict"; var d = 0; function f(n) { d++; return n == 0 ? new Error("x").stack.split("\n").length : f(n - 1) } f(50) + ":" + d|,
     "2:51"},
    {"R48",
     ~S|"use strict"; function g(n) { return n === 0 ? new Error("e").stack : g(n - 1) } function h() { return g(3) + "" } (function k() { return h() + "" })()|,
     "Error: e\n    at g\n    at h\n    at k"},
    {"R49", ~S|function b() { return new Error("x").stack } function a() { return b() } a()|,
     "Error: x\n    at b\n    at a"},
    {"R51o",
     ~S|"use strict"; var log = []; function mk() { return {[Symbol.iterator]() { return this }, next() { return {value: 1, done: false} }, return() { log.push("close"); return {} }} } function g() { log.push("call"); return "g" } function f() { for (var x of mk()) { return g() } } f() + ":" + log.join()|,
     "g:call,close"},
    {"R51c",
     ~S|"use strict"; var log = []; function g() { log.push("call"); throw "E" } function f() { try { return g() } catch (e) { log.push("caught " + e) } return "after" } f() + ":" + log.join()|,
     "after:call,caught E"},
    {"R52f",
     ~S|"use strict"; var log = []; function g() { log.push("call"); return "g" } function f() { try { return g() } finally { log.push("fin") } } f() + ":" + log.join()|,
     "g:call,fin"},
    {"R52u",
     ~S|"use strict"; var log = []; function g() { log.push("call"); return "g" } function f() { using r = {[Symbol.dispose]() { log.push("dispose") }}; return g() } f() + ":" + log.join()|,
     "g:call,dispose"},
    {"R53",
     ~S|var log = []; function a() { log.push("a"); return 1 } function b() { log.push("b"); return [2, 3] } function c() { log.push("c"); return 4 } function g() { return arguments.length + ":" + Array.prototype.join.call(arguments) } g(a(), ...b(), c()) + " " + log.join()|,
     "4:1,2,3,4 a,b,c"},
    {"R54a", ~S|eval("1; do { 2; break; } while (false)")|, 2.0},
    {"R54b", ~S|eval("var i = 0; 5; while (i < 2) { i++; if (i == 1) continue; i + 10 }")|, 12.0},
    {"R54c", ~S|eval("6; try { 7 } finally { 8 }")|, 7.0},
    {"R54d", ~S|eval("9; l: { 10; break l; }")|, 10.0},
    {"R54e", ~S|eval("1; switch (1) { case 1: 2; break; }")|, 2.0},
    {"R55a", ~S|eval("1; try { throw 0 } catch (e) { 4 } finally { 5 }")|, 4.0},
    {"R55b", ~S|eval("1; L: try { 3 } finally { break L }")|, :undefined},
    {"R55c", ~S|eval("1; for (var i = 0; i < 2; i++) { if (i) continue; 5 }")|, :undefined},
    {"R56a",
     ~S|function* g() { for (var i = 0; i < 4; i++) { if (i == 1) continue; if (i == 3) return "r" + i; yield i } } var it = g(); var r = []; for (var s = it.next(); !s.done; s = it.next()) r.push(s.value); r.push(s.value); r.join()|,
     "0,2,r3"},
    {"R56b",
     ~S|function* g() { a: for (var i = 0; i < 3; i++) { for (var j = 0; j < 3; j++) { if (j == 1) continue a; yield i + "" + j } } } [...g()].join()|,
     "00,10,20"},
    {"R57a",
     ~S|var box = {}; (async function(){ for (var x of [1, 2, 3]) { if (x == 2) return x } })().then(v => { box.v = v }); box|,
     %{"v" => 2.0}},
    {"R57b",
     ~S|var box = {}; (async function(){ try { return "t" } finally { box.f = 1 } })().then(v => { box.v = v }); box|,
     %{"f" => 1.0, "v" => "t"}},
    {"R58",
     ~S|var log = []; var it = {[Symbol.iterator]() { return this }, i: 0, next() { return {value: this.i++, done: false} }, return() { log.push("close"); return {} }}; function* g() { for (var x of it) yield x } var gen = g(); gen.next(); gen.return(5).value + log.join()|,
     "5close"},
    {"X1", ~S|var s = ""; for (var i = 0; i < 2; i++) { L: { s += i; break L; } s += "x"; } s|,
     "0x1x"},
    {"X2",
     ~S|(function(){ var s = ""; for (var i = 0; i < 3; i++) { try { throw i } catch (e) { s += "c" + e; continue } finally { s += "f" } } return s })()|,
     "c0fc1fc2f"},
    {"X3",
     ~S|(function(){ var s = ""; a: for (var i = 0; i < 2; i++) { b: for (var j = 0; j < 2; j++) { c: { if (j == 0) break c; continue a } s += "x" } } return s })()|,
     "xx"},
    {"X4",
     ~S|(function(){ for (var i = 0; i < 3; i++) { try { break } finally { continue } } return i })()|,
     3.0},
    {"X5", ~S|(function(){ var r = ""; x: if (true) { r += "a"; break x } return r + "b" })()|,
     "ab"},
    {"X6",
     ~S|(function(){ var n = 0; l: while (true) { do { n++; if (n > 3) break l; continue l } while (false) } return n })()|,
     4.0},
    {"X7", ~S|(function(){ l: try { throw 1 } finally { break l } return "swallowed" })()|,
     "swallowed"},
    {"X8",
     ~S|var log = []; var s = {[Symbol.dispose]() { log.push("d") }}; for (var x of [1, 2, 3]) { using a = s; log.push(x); if (x == 2) break } log.join()|,
     "1,d,2,d"},
    {"X9", ~S|eval("7; switch (1) { case 1: 8; case 2: 9; break; }")|, 9.0},
    {"X10", ~S|eval("1; L: for (var i = 0; i < 2; i++) { try { 4; continue L } finally { 5 } }")|,
     4.0},
    {"X12", ~S|"use strict"; function a() { return null() } try { a() } catch (e) { e.message }|,
     "expression is not a function"},
    {"X13",
     ~S|"use strict"; function b() { return new Error("x").stack } function a() { return b() } a()|,
     "Error: x\n    at b"}
  ]

  # Row D1 and the row X11 of the source designs: `:js_last` leaks out of a function body
  # (bug B2). Each row is the source, the value at `:off` and the value at level 4 after
  # commit 10. Before commit 10 both levels give the value of `:off`. After commit 10 a
  # frame does not write `:js_last`, so level 4 gives the value of the spec. These rows run
  # the code of the design rows as a script, because the `resolve:` option of `JS.eval`
  # sets the level of the script but not the level of the code of a direct eval. The rows
  # with the direct eval of the design are in `Browser.JS.CompletionEvalLevelTest` below.
  @d1 [
    {"D1", "5; var x = (function(){ for (var i = 0; i < 1; i++) { 42 } })();", 42.0, 5.0},
    {"X11", "1; var x = (function(){ for (;;) { break } })();", :undefined, 1.0}
  ]

  describe "6.2: the snippet rows" do
    test "each row gives its value at :off and at level 4" do
      for {n, src, value} <- @rows, level <- @levels do
        assert eval(src, level) == {:ok, value, []}, "row #{n} at #{level}: #{src}"
      end
    end

    test "R24: a finalizer that returns replaces the step limit abort (kept quirk, Q2)" do
      src = ~S|(function(){ try { for (;;) {} } finally { return 1 } })()|

      for level <- @levels,
          do: assert(eval(src, level, max_steps: 10_000) == {:ok, 1.0, []}, "at #{level}")
    end

    test "R50: a strict function that tail-calls itself runs until the step limit" do
      src = ~S|"use strict"; var d = 0; function f() { d++; return f() } f()|

      for level <- @levels do
        assert eval(src, level, max_steps: 100_000) == {:error, :step_limit, []}, "at #{level}"
      end
    end

    test "D1 at :off: a function body still writes the completion value of the script" do
      # The old path keeps every write of `:js_last` (design 2.8), so these values stay.
      for {n, src, off, _} <- @d1, do: assert(eval(src, :off) == {:ok, off, []}, n)
    end
  end

  # ── the behaviour changes of step 3 ────────────────────────

  # Rows R31 and R32: a `continue` to a label outside a for-of ends the loop as a normal
  # exit, so the iterator closes with the rules of a normal exit. An error from `return()`
  # goes up, and a result that is not an object is a TypeError. Before commit 2 both rows
  # give "done", because the close is done as after a throw (bug B1).
  @b1 [
    {"R31",
     ~S|var it = {[Symbol.iterator]() { return this }, next() { return {value: 1, done: false} }, return() { throw new Error("ret") }}; var r = "done"; try { outer: for (var i = 0; i < 1; i++) { for (var x of it) { continue outer } } } catch (e) { r = e.message } r|,
     "ret"},
    {"R32",
     ~S|var it = {[Symbol.iterator]() { return this }, next() { return {value: 1, done: false} }, return() { return 5 }}; var r = "done"; try { outer: for (var i = 0; i < 1; i++) { for (var x of it) { continue outer } } } catch (e) { r = e.constructor.name } r|,
     "TypeError"}
  ]

  # Rows D2a, D2b and D2c: a call of a user function named `eval` (bug B3). Before commit 3,
  # D2a gives "undef,undef" (`this` is undefined for a function found on a `with` object),
  # D2b gives "TypeError" (the arguments are not evaluated before the check), and D2c
  # gives 2 (a strict tail call reads the callee two times).
  @d2 [
    {"D2a",
     ~S|var o = { eval() { return this === o ? "obj" : "undef" } }; var r1, r2; with (o) { r1 = eval("1"); r2 = (function(){ return eval("1") })() } r1 + "," + r2|,
     "obj,obj"},
    {"D2b",
     ~S|var log = []; var r; with ({eval: 5}) { try { (function(){ return eval(log.push("arg")) })() } catch (e) { r = e.constructor.name + log.join() } } r|,
     "TypeErrorarg"},
    {"D2c",
     ~S|var n = 0; var o = { get eval() { n++; return function() { return 1 } } }; with (o) { (function(){ "use strict"; return eval("x") })() } n|,
     1.0}
  ]

  describe "the behaviour changes of step 3" do
    test "B1: a continue to an outer label closes the iterator as a normal exit" do
      for {n, src, value} <- @b1, level <- @levels do
        assert eval(src, level) == {:ok, value, []}, "row #{n} at #{level}"
      end
    end

    test "D2: a call of a function named eval reads the callee one time" do
      for {n, src, value} <- @d2, level <- @levels do
        assert eval(src, level) == {:ok, value, []}, "row #{n} at #{level}"
      end
    end

    test "D1: a level 4 function body does not write the completion value" do
      for {n, src, _, spec} <- @d1, do: assert(eval(src, 4) == {:ok, spec, []}, n)
    end
  end

  # ── U1: argument lists ─────────────────────────────────────

  # The arguments of a call and the items of an array literal: the order of the side
  # effects, a spread in the middle, holes, 0, 1, 3 and 20 arguments, and a spread of a
  # generator that throws on its second step. Row R53 is the order of `g(a(), ...b(), c())`.
  @rows_u1 [
    {"U1n",
     ~S|function n() { return arguments.length } [n(), n(1), n(1, 2, 3), n(1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20), n(...[]), n(1, ...[2, 3, 4], 5)].join()|,
     "0,1,3,20,0,5"},
    {"U1h",
     ~S|var a = [1, , 3]; var b = [0, ...[1, , 3], , 5]; a.length + ":" + (1 in a) + ":" + a[1] + " " + b.length + ":" + (2 in b) + ":" + (4 in b) + ":" + b.join("-")|,
     "3:false:undefined 6:true:false:0-1--3--5"},
    {"U1g",
     ~S|var log = []; function* t() { log.push("t1"); yield 1; log.push("t2"); throw "second" } function c() { log.push("c"); return 3 } function g() { log.push("g") } try { g(0, ...t(), c()) } catch (e) { log.push("caught " + e) } log.join()|,
     "t1,t2,caught second"},
    {"U1a",
     ~S|var log = []; function* t() { log.push("t1"); yield 1; throw "second" } try { [log.push("a"), ...t(), log.push("c")] } catch (e) { log.push("caught " + e) } log.join()|,
     "a,t1,caught second"},
    {"U1new",
     ~S|var log = []; function P(a, b, c) { this.s = a + b + c } function v(x) { log.push(x); return x } new P(v(1), ...[v(2)], v(3)).s + ":" + log.join()|,
     "6:1,2,3"},
    {"U1m",
     ~S|var log = []; var o = { m() { return Array.prototype.join.call(arguments, "") } }; function v(x) { log.push(x); return x } o.m(v("a"), ...v(["b", "c"]), v("d")) + ":" + log.join()|,
     "abcd:a,b,c,d"}
  ]

  describe "U1: argument lists (eval_list)" do
    test "each row gives its value at :off and at level 4" do
      for {n, src, value} <- @rows_u1, level <- @levels do
        assert eval(src, level) == {:ok, value, []}, "#{n} at #{level}: #{src}"
      end
    end
  end

  # ── U2: the shapes of the completions ──────────────────────

  describe "U2: completion shapes (exec_stmt)" do
    test "break and continue give {:brk, l} and {:cont, l}" do
      gid = heap()
      {body, fid} = frame_of(~S|function f(){ l: for (;;) { if (0) break; continue l } }|, gid)
      assert Interp.exec_stmt(find(body, &match?({:break, nil}, &1)), fid) == {:brk, nil}
      assert Interp.exec_stmt(find(body, &match?({:continue, "l"}, &1)), fid) == {:cont, "l"}

      # The old path gives the same shapes on a map scope.
      scope = Interp.new_scope(gid)
      assert Interp.exec_stmt({:break, "l"}, scope) == {:brk, "l"}
      assert Interp.exec_stmt({:continue, nil}, scope) == {:cont, nil}
    end

    test "a return gives {:ret, v}" do
      gid = heap()
      native_g(gid)
      {body, fid} = frame_of(~S|function f(){ if (0) return; return 1 }|, gid)
      assert Interp.exec_stmt(find(body, &match?({:return, nil}, &1)), fid) == {:ret, :undefined}

      assert {:return, {:num, 1.0}, :plain} = ret = find(body, &match?({:return, _, _}, &1))
      assert Interp.exec_stmt(ret, fid) == {:ret, 1.0}

      # A call under `:plain` is made here.
      call = {:call, {:gref, "g"}, [], false}
      assert Interp.exec_stmt({:return, call, :plain}, fid) == {:ret, 42.0}

      {:fn, "f", _, off_body, _, _} = fn_f(~S|function f(){ return 1 }|, :off)
      scope = Interp.new_scope(gid)
      assert Interp.exec_stmt(find(off_body, &match?({:return, _}, &1)), scope) == {:ret, 1.0}
    end

    test "a strict return g(1) gives {:tail, g, :undefined, [1.0]}" do
      gid = heap()
      g = native_g(gid)
      {body, fid} = frame_of(~S|"use strict"; function f(){ return g(1) }|, gid)
      assert {:return, {:call, _, _, _}, :tail} = ret = find(body, &match?({:return, _, _}, &1))
      assert Interp.exec_stmt(ret, fid) == {:tail, g, :undefined, [1.0]}

      # On the old path a call form always gives the pending call. The function boundary
      # decides later if it runs there or in the trampoline (design 3.4).
      for src <- [~S|function f(){ "use strict"; return g(1) }|, ~S|function f(){ return g(1) }|] do
        {:fn, "f", _, off_body, _, _} = fn_f(src, :off)
        scope = Interp.new_scope(gid)
        ret = find(off_body, &match?({:return, _}, &1))
        assert Interp.exec_stmt(ret, scope) == {:tail, g, :undefined, [1.0]}, src
      end
    end
  end

  # ── U3: what a loop does with the completion of its body ───

  # The loop is `l: m: while (n++ < 2) { body }` in a strict function. The test runs the
  # `while` statement alone and gives it the labels, so `l` can be a label of the loop or
  # a label outside it. `m` is always a label outside. The result is the completion and
  # the native `g` of the heap.
  defp loop_completion(body, labels, mode) do
    gid = heap()
    g = native_g(gid)
    src = ~s|function f(){ "use strict"; var n = 0; l: m: while (n++ < 2) { #{body} } }|

    case mode do
      # The old path: a map scope and `exec_stmt`.
      :top ->
        {:fn, "f", _, stmts, _, _} = fn_f(src, :off)
        scope = Interp.new_scope(gid)
        Interp.declare(scope, "n", 0.0)
        {Interp.exec_stmt(find(stmts, &match?({:while, _, _}, &1)), scope, labels), g}

      # The frame path: a frame and `exec_frame_stmt`, which runs a statement of a
      # rewritten body without writes of `:js_last` (commit 10). The call goes through
      # `apply/3`, because the function does not exist before commit 10.
      :fn ->
        {stmts, fid} = frame_of(src, gid)
        :erlang.put(fid, :erlang.setelement(6, :erlang.get(fid), 0.0))
        loop = find(stmts, &match?({:while, _, _}, &1))
        {apply(Interp, :exec_frame_stmt, [loop, fid, labels]), g}
    end
  end

  @u3_jumps [
    {"break", [], :ok},
    {"break", ["l"], :ok},
    {"continue", [], :ok},
    {"continue", ["l"], :ok},
    {"break l", [], {:brk, "l"}},
    {"break l", ["l"], :ok},
    {"continue l", [], {:cont, "l"}},
    {"continue l", ["l"], :ok},
    {"break m", ["l"], {:brk, "m"}},
    {"continue m", ["l"], {:cont, "m"}}
  ]

  @u3_returns [{"return 1", [], {:ret, 1.0}}, {"return 1", ["l"], {:ret, 1.0}}]

  defp check_loops(cases, mode) do
    for {body, labels, expected} <- cases do
      assert elem(loop_completion(body, labels, mode), 0) == expected,
             "#{body} with labels #{inspect(labels)} at #{mode}"
    end
  end

  defp check_tail(mode) do
    for labels <- [[], ["l"]] do
      {completion, g} = loop_completion("return g(1)", labels, mode)
      assert completion == {:tail, g, :undefined, [1.0]}, "labels #{inspect(labels)} at #{mode}"
    end
  end

  describe "U3: loop bodies (run_body)" do
    test "break and continue at the old path" do
      check_loops(@u3_jumps, :top)
    end

    test "return at the old path" do
      check_loops(@u3_returns, :top)
    end

    test "a tail call at the old path" do
      check_tail(:top)
    end

    test "every completion at the frame path" do
      check_loops(@u3_jumps ++ @u3_returns, :fn)
      check_tail(:fn)
    end
  end

  # ── U4: the try matrix ─────────────────────────────────────

  @u4_blocks [
    normal: "",
    return: ~S|return "B"|,
    break: "break",
    continue: "continue",
    throw: ~S|throw "x"|,
    tail: "return g()"
  ]
  @u4_handlers [none: nil, normal: "", return: ~S|return "H"|, throw: ~S|throw "y"|]
  @u4_finalizers [none: nil, normal: "", return: ~S|return "F"|, break: "break"]

  # The 96 programs: block × handler × finalizer, each in a loop of two rounds inside a
  # strict function. With no handler and no finalizer, the block is a plain block. The
  # result is the value of the function (or the thrown value) and the log of the steps.
  defp u4_programs do
    for {b, bs} <- @u4_blocks, {h, hs} <- @u4_handlers, {f, fs} <- @u4_finalizers do
      handler = if hs, do: ~s| catch (e) { log.push("h" + e); #{hs} }|, else: ""
      finalizer = if fs, do: ~s| finally { log.push("f"); #{fs} }|, else: ""

      stmt =
        if hs == nil and fs == nil,
          do: ~s|{ log.push("b"); #{bs} }|,
          else: ~s|try { log.push("b"); #{bs} }| <> handler <> finalizer

      src =
        ~s|"use strict"; var log = []; function g() { log.push("g"); return "G" } | <>
          ~s|function f() { for (var i = 0; i < 2; i++) { log.push("i" + i); #{stmt} log.push("e" + i) } return "end" } | <>
          ~s|var r; try { r = f() } catch (e) { r = "threw " + e } r + "\|" + log.join()|

      {"#{b}/#{h}/#{f}", src}
    end
  end

  # The results at fc9f0db, the same at `:off` and at level 4.
  @u4_golden %{
    "normal/none/none" => "end|i0,b,e0,i1,b,e1",
    "normal/none/normal" => "end|i0,b,f,e0,i1,b,f,e1",
    "normal/none/return" => "F|i0,b,f",
    "normal/none/break" => "end|i0,b,f",
    "normal/normal/none" => "end|i0,b,e0,i1,b,e1",
    "normal/normal/normal" => "end|i0,b,f,e0,i1,b,f,e1",
    "normal/normal/return" => "F|i0,b,f",
    "normal/normal/break" => "end|i0,b,f",
    "normal/return/none" => "end|i0,b,e0,i1,b,e1",
    "normal/return/normal" => "end|i0,b,f,e0,i1,b,f,e1",
    "normal/return/return" => "F|i0,b,f",
    "normal/return/break" => "end|i0,b,f",
    "normal/throw/none" => "end|i0,b,e0,i1,b,e1",
    "normal/throw/normal" => "end|i0,b,f,e0,i1,b,f,e1",
    "normal/throw/return" => "F|i0,b,f",
    "normal/throw/break" => "end|i0,b,f",
    "return/none/none" => "B|i0,b",
    "return/none/normal" => "B|i0,b,f",
    "return/none/return" => "F|i0,b,f",
    "return/none/break" => "end|i0,b,f",
    "return/normal/none" => "B|i0,b",
    "return/normal/normal" => "B|i0,b,f",
    "return/normal/return" => "F|i0,b,f",
    "return/normal/break" => "end|i0,b,f",
    "return/return/none" => "B|i0,b",
    "return/return/normal" => "B|i0,b,f",
    "return/return/return" => "F|i0,b,f",
    "return/return/break" => "end|i0,b,f",
    "return/throw/none" => "B|i0,b",
    "return/throw/normal" => "B|i0,b,f",
    "return/throw/return" => "F|i0,b,f",
    "return/throw/break" => "end|i0,b,f",
    "break/none/none" => "end|i0,b",
    "break/none/normal" => "end|i0,b,f",
    "break/none/return" => "F|i0,b,f",
    "break/none/break" => "end|i0,b,f",
    "break/normal/none" => "end|i0,b",
    "break/normal/normal" => "end|i0,b,f",
    "break/normal/return" => "F|i0,b,f",
    "break/normal/break" => "end|i0,b,f",
    "break/return/none" => "end|i0,b",
    "break/return/normal" => "end|i0,b,f",
    "break/return/return" => "F|i0,b,f",
    "break/return/break" => "end|i0,b,f",
    "break/throw/none" => "end|i0,b",
    "break/throw/normal" => "end|i0,b,f",
    "break/throw/return" => "F|i0,b,f",
    "break/throw/break" => "end|i0,b,f",
    "continue/none/none" => "end|i0,b,i1,b",
    "continue/none/normal" => "end|i0,b,f,i1,b,f",
    "continue/none/return" => "F|i0,b,f",
    "continue/none/break" => "end|i0,b,f",
    "continue/normal/none" => "end|i0,b,i1,b",
    "continue/normal/normal" => "end|i0,b,f,i1,b,f",
    "continue/normal/return" => "F|i0,b,f",
    "continue/normal/break" => "end|i0,b,f",
    "continue/return/none" => "end|i0,b,i1,b",
    "continue/return/normal" => "end|i0,b,f,i1,b,f",
    "continue/return/return" => "F|i0,b,f",
    "continue/return/break" => "end|i0,b,f",
    "continue/throw/none" => "end|i0,b,i1,b",
    "continue/throw/normal" => "end|i0,b,f,i1,b,f",
    "continue/throw/return" => "F|i0,b,f",
    "continue/throw/break" => "end|i0,b,f",
    "throw/none/none" => "threw x|i0,b",
    "throw/none/normal" => "threw x|i0,b,f",
    "throw/none/return" => "F|i0,b,f",
    "throw/none/break" => "end|i0,b,f",
    "throw/normal/none" => "end|i0,b,hx,e0,i1,b,hx,e1",
    "throw/normal/normal" => "end|i0,b,hx,f,e0,i1,b,hx,f,e1",
    "throw/normal/return" => "F|i0,b,hx,f",
    "throw/normal/break" => "end|i0,b,hx,f",
    "throw/return/none" => "H|i0,b,hx",
    "throw/return/normal" => "H|i0,b,hx,f",
    "throw/return/return" => "F|i0,b,hx,f",
    "throw/return/break" => "end|i0,b,hx,f",
    "throw/throw/none" => "threw y|i0,b,hx",
    "throw/throw/normal" => "threw y|i0,b,hx,f",
    "throw/throw/return" => "F|i0,b,hx,f",
    "throw/throw/break" => "end|i0,b,hx,f",
    "tail/none/none" => "G|i0,b,g",
    "tail/none/normal" => "G|i0,b,g,f",
    "tail/none/return" => "F|i0,b,g,f",
    "tail/none/break" => "end|i0,b,g,f",
    "tail/normal/none" => "G|i0,b,g",
    "tail/normal/normal" => "G|i0,b,g,f",
    "tail/normal/return" => "F|i0,b,g,f",
    "tail/normal/break" => "end|i0,b,g,f",
    "tail/return/none" => "G|i0,b,g",
    "tail/return/normal" => "G|i0,b,g,f",
    "tail/return/return" => "F|i0,b,g,f",
    "tail/return/break" => "end|i0,b,g,f",
    "tail/throw/none" => "G|i0,b,g",
    "tail/throw/normal" => "G|i0,b,g,f",
    "tail/throw/return" => "F|i0,b,g,f",
    "tail/throw/break" => "end|i0,b,g,f"
  }

  describe "U4: the try matrix" do
    test "each program gives its pinned result at :off and at level 4" do
      programs = u4_programs()
      assert length(programs) == 96
      assert Enum.sort(Enum.map(programs, &elem(&1, 0))) == Enum.sort(Map.keys(@u4_golden))

      for {name, src} <- programs, level <- @levels do
        assert eval(src, level) == {:ok, @u4_golden[name], []}, "#{name} at #{level}: #{src}"
      end
    end
  end

  # ── U5: the loop matrix ────────────────────────────────────

  @u5_exits [
    break: "break",
    continue: "continue",
    break_outer: "break outer",
    continue_outer: "continue outer",
    return: ~S|return "ret" + v|
  ]

  # The inner loops. `mk()` makes an iterator over 0, 1 and 2 whose `return()` logs and
  # counts the closes. A loop that pushes a closure into `fs` gets a frame for each round
  # at level 4. The two last kinds use an iterator whose `return()` throws "rt".
  @u5_loops [
    for_var: "for (var v = 0; v < 3; v++) { BODY }",
    for_let: "for (let v = 0; v < 3; v++) { BODY }",
    for_let_captured: "for (let v = 0; v < 3; v++) { fs.push(() => v); BODY }",
    while: "var v = -1; while (++v < 3) { BODY }",
    do_while: "var v = -1; do { v++; BODY } while (v < 2)",
    for_in: "for (var k in [0, 1, 2]) { var v = +k; BODY }",
    for_of_array: "for (var v of [0, 1, 2]) { BODY }",
    for_of_iterator: "for (var v of mk()) { BODY }",
    for_of_framed: "for (const v of mk()) { fs.push(() => v); BODY }",
    switch: "for (var v = 0; v < 3; v++) { switch (v) { default: BODY } }",
    for_of_iterator_throws: "for (var v of mk()) { BODY }",
    for_of_framed_throws: "for (const v of mk()) { fs.push(() => v); BODY }"
  ]

  # The 60 programs: exit × loop. The inner loop is in an outer loop with the label
  # `outer`, inside a sloppy function. The result is the value of the function (or the
  # thrown value), the log and the number of closes.
  defp u5_programs do
    for {l, ls} <- @u5_loops, {x, xs} <- @u5_exits do
      body = ~s|log.push("x" + v); if (v == 1) #{xs}; log.push("y" + v)|

      ret =
        if l in [:for_of_iterator_throws, :for_of_framed_throws],
          do: ~S|throw "rt"|,
          else: "return {}"

      src =
        ~s|var log = [], fs = [], closes = 0; | <>
          ~s|function mk() { var i = 0; return {[Symbol.iterator]() { return this }, next() { return {value: i++, done: i > 3} }, return() { closes++; log.push("close"); #{ret} }} } | <>
          ~s|function f() { outer: for (var o = 0; o < 2; o++) { log.push("o" + o); #{String.replace(ls, "BODY", body)} log.push("after" + o) } return "end" } | <>
          ~s|var r; try { r = f() } catch (e) { r = "threw " + e } r + "\|" + log.join() + "\|" + closes|

      {"#{l}/#{x}", src}
    end
  end

  # The programs that commit 2 changes (B1). A `continue outer` closes the iterator as a
  # normal exit, so the error of `return()` goes up, as it does for `break outer`. Before
  # commit 2 both give "end|o0,x0,y0,x1,close,o1,x0,y0,x1,close|2".
  @u5_b1 ["for_of_iterator_throws/continue_outer", "for_of_framed_throws/continue_outer"]

  # The results at fc9f0db, the same at `:off` and at level 4, except the two programs of
  # `@u5_b1`, which have the value after commit 2.
  @u5_golden %{
    "for_var/break" => "end|o0,x0,y0,x1,after0,o1,x0,y0,x1,after1|0",
    "for_var/continue" => "end|o0,x0,y0,x1,x2,y2,after0,o1,x0,y0,x1,x2,y2,after1|0",
    "for_var/break_outer" => "end|o0,x0,y0,x1|0",
    "for_var/continue_outer" => "end|o0,x0,y0,x1,o1,x0,y0,x1|0",
    "for_var/return" => "ret1|o0,x0,y0,x1|0",
    "for_let/break" => "end|o0,x0,y0,x1,after0,o1,x0,y0,x1,after1|0",
    "for_let/continue" => "end|o0,x0,y0,x1,x2,y2,after0,o1,x0,y0,x1,x2,y2,after1|0",
    "for_let/break_outer" => "end|o0,x0,y0,x1|0",
    "for_let/continue_outer" => "end|o0,x0,y0,x1,o1,x0,y0,x1|0",
    "for_let/return" => "ret1|o0,x0,y0,x1|0",
    "for_let_captured/break" => "end|o0,x0,y0,x1,after0,o1,x0,y0,x1,after1|0",
    "for_let_captured/continue" => "end|o0,x0,y0,x1,x2,y2,after0,o1,x0,y0,x1,x2,y2,after1|0",
    "for_let_captured/break_outer" => "end|o0,x0,y0,x1|0",
    "for_let_captured/continue_outer" => "end|o0,x0,y0,x1,o1,x0,y0,x1|0",
    "for_let_captured/return" => "ret1|o0,x0,y0,x1|0",
    "while/break" => "end|o0,x0,y0,x1,after0,o1,x0,y0,x1,after1|0",
    "while/continue" => "end|o0,x0,y0,x1,x2,y2,after0,o1,x0,y0,x1,x2,y2,after1|0",
    "while/break_outer" => "end|o0,x0,y0,x1|0",
    "while/continue_outer" => "end|o0,x0,y0,x1,o1,x0,y0,x1|0",
    "while/return" => "ret1|o0,x0,y0,x1|0",
    "do_while/break" => "end|o0,x0,y0,x1,after0,o1,x0,y0,x1,after1|0",
    "do_while/continue" => "end|o0,x0,y0,x1,x2,y2,after0,o1,x0,y0,x1,x2,y2,after1|0",
    "do_while/break_outer" => "end|o0,x0,y0,x1|0",
    "do_while/continue_outer" => "end|o0,x0,y0,x1,o1,x0,y0,x1|0",
    "do_while/return" => "ret1|o0,x0,y0,x1|0",
    "for_in/break" => "end|o0,x0,y0,x1,after0,o1,x0,y0,x1,after1|0",
    "for_in/continue" => "end|o0,x0,y0,x1,x2,y2,after0,o1,x0,y0,x1,x2,y2,after1|0",
    "for_in/break_outer" => "end|o0,x0,y0,x1|0",
    "for_in/continue_outer" => "end|o0,x0,y0,x1,o1,x0,y0,x1|0",
    "for_in/return" => "ret1|o0,x0,y0,x1|0",
    "for_of_array/break" => "end|o0,x0,y0,x1,after0,o1,x0,y0,x1,after1|0",
    "for_of_array/continue" => "end|o0,x0,y0,x1,x2,y2,after0,o1,x0,y0,x1,x2,y2,after1|0",
    "for_of_array/break_outer" => "end|o0,x0,y0,x1|0",
    "for_of_array/continue_outer" => "end|o0,x0,y0,x1,o1,x0,y0,x1|0",
    "for_of_array/return" => "ret1|o0,x0,y0,x1|0",
    "for_of_iterator/break" => "end|o0,x0,y0,x1,close,after0,o1,x0,y0,x1,close,after1|2",
    "for_of_iterator/continue" => "end|o0,x0,y0,x1,x2,y2,after0,o1,x0,y0,x1,x2,y2,after1|0",
    "for_of_iterator/break_outer" => "end|o0,x0,y0,x1,close|1",
    "for_of_iterator/continue_outer" => "end|o0,x0,y0,x1,close,o1,x0,y0,x1,close|2",
    "for_of_iterator/return" => "ret1|o0,x0,y0,x1,close|1",
    "for_of_framed/break" => "end|o0,x0,y0,x1,close,after0,o1,x0,y0,x1,close,after1|2",
    "for_of_framed/continue" => "end|o0,x0,y0,x1,x2,y2,after0,o1,x0,y0,x1,x2,y2,after1|0",
    "for_of_framed/break_outer" => "end|o0,x0,y0,x1,close|1",
    "for_of_framed/continue_outer" => "end|o0,x0,y0,x1,close,o1,x0,y0,x1,close|2",
    "for_of_framed/return" => "ret1|o0,x0,y0,x1,close|1",
    "switch/break" => "end|o0,x0,y0,x1,x2,y2,after0,o1,x0,y0,x1,x2,y2,after1|0",
    "switch/continue" => "end|o0,x0,y0,x1,x2,y2,after0,o1,x0,y0,x1,x2,y2,after1|0",
    "switch/break_outer" => "end|o0,x0,y0,x1|0",
    "switch/continue_outer" => "end|o0,x0,y0,x1,o1,x0,y0,x1|0",
    "switch/return" => "ret1|o0,x0,y0,x1|0",
    "for_of_iterator_throws/break" => "threw rt|o0,x0,y0,x1,close|1",
    "for_of_iterator_throws/continue" =>
      "end|o0,x0,y0,x1,x2,y2,after0,o1,x0,y0,x1,x2,y2,after1|0",
    "for_of_iterator_throws/break_outer" => "threw rt|o0,x0,y0,x1,close|1",
    # Commit 2 (B1).
    "for_of_iterator_throws/continue_outer" => "threw rt|o0,x0,y0,x1,close|1",
    "for_of_iterator_throws/return" => "threw rt|o0,x0,y0,x1,close|1",
    "for_of_framed_throws/break" => "threw rt|o0,x0,y0,x1,close|1",
    "for_of_framed_throws/continue" => "end|o0,x0,y0,x1,x2,y2,after0,o1,x0,y0,x1,x2,y2,after1|0",
    "for_of_framed_throws/break_outer" => "threw rt|o0,x0,y0,x1,close|1",
    # Commit 2 (B1).
    "for_of_framed_throws/continue_outer" => "threw rt|o0,x0,y0,x1,close|1",
    "for_of_framed_throws/return" => "threw rt|o0,x0,y0,x1,close|1"
  }

  describe "U5: the loop matrix" do
    test "each program gives its pinned result at :off and at level 4" do
      programs = u5_programs()
      assert length(programs) == 60
      assert Enum.sort(Enum.map(programs, &elem(&1, 0))) == Enum.sort(Map.keys(@u5_golden))

      for {name, src} <- programs, name not in @u5_b1, level <- @levels do
        assert eval(src, level) == {:ok, @u5_golden[name], []}, "#{name} at #{level}: #{src}"
      end
    end

    test "B1: a continue to an outer label closes as a normal exit" do
      for {name, src} <- u5_programs(), name in @u5_b1, level <- @levels do
        assert eval(src, level) == {:ok, @u5_golden[name], []}, "#{name} at #{level}: #{src}"
      end
    end
  end

  # ── U6: tail calls ─────────────────────────────────────────

  # Rows R37 to R44 of 6.2 have every tail position at depth 100000. These rows add the
  # run sites, where a pending call must run in place: with a callee that logs or throws,
  # the call runs before the catch, the finalizer, `return()` or the disposal. They also
  # pin the boundary rule. A strict function does not grow the stack. A sloppy function
  # and a chain through `new` do (the depth limit is 1000). A constructor makes its tail
  # call in place, so its line stays in `Error.stack`. A concise arrow body is not a tail
  # position at any level (Q3).
  @rows_u6 [
    {"U6cf",
     ~S|"use strict"; var log = []; function g() { log.push("call"); return "g" } function f() { try { throw 0 } catch (e) { return g() } finally { log.push("fin") } } f() + ":" + log.join()|,
     "g:call,fin"},
    {"U6cfE",
     ~S|"use strict"; var log = []; function g() { log.push("call"); throw "E" } function f() { try { throw 0 } catch (e) { return g() } finally { log.push("fin") } } var r; try { r = f() } catch (e) { r = "threw " + e } r + ":" + log.join()|,
     "threw E:call,fin"},
    {"U6fE",
     ~S|"use strict"; var log = []; function g() { log.push("call"); throw "E" } function f() { try { return g() } finally { log.push("fin") } } var r; try { r = f() } catch (e) { r = "threw " + e } r + ":" + log.join()|,
     "threw E:call,fin"},
    {"U6in",
     ~S|"use strict"; var log = []; function g() { log.push("call"); throw "E" } function f() { for (var k in {a: 1}) { try { return g() } catch (e) { log.push("caught " + e) } } return "after" } f() + ":" + log.join()|,
     "after:call,caught E"},
    {"U6inE",
     ~S|"use strict"; var log = []; function g() { log.push("call"); throw "E" } function f() { for (var k in {a: 1}) { return g() } } var r; try { r = f() } catch (e) { r = "threw " + e } r + ":" + log.join()|,
     "threw E:call"},
    {"U6ofE",
     ~S|"use strict"; var log = []; function mk() { return {[Symbol.iterator]() { return this }, next() { return {value: 1, done: false} }, return() { log.push("close"); return {} }} } function g() { log.push("call"); throw "E" } function f() { for (var x of mk()) { return g() } } var r; try { r = f() } catch (e) { r = "threw " + e } r + ":" + log.join()|,
     "threw E:call,close"},
    {"U6ofL",
     ~S|"use strict"; var log = []; function mk() { return {[Symbol.iterator]() { return this }, next() { return {value: 1, done: false} }, return() { log.push("close"); return {} }} } function g() { log.push("call"); return "g" } function f() { for (const x of mk()) { var h = () => x; return g() } } f() + ":" + log.join()|,
     "g:call,close"},
    {"U6uE",
     ~S|"use strict"; var log = []; function g() { log.push("call"); throw "E" } function f() { using r = {[Symbol.dispose]() { log.push("dispose") }}; return g() } var r; try { r = f() } catch (e) { r = "threw " + e } r + ":" + log.join()|,
     "threw E:call,dispose"},
    {"U6ub",
     ~S|"use strict"; var log = []; function g() { log.push("call"); return "g" } function f() { { using r = {[Symbol.dispose]() { log.push("dispose") }}; return g() } } f() + ":" + log.join()|,
     "g:call,dispose"},
    {"U6w",
     ~S|var log = []; function g() { log.push("call"); throw "E" } function f() { with ({}) { return g() } } var r; try { r = f() } catch (e) { r = "threw " + e } r + ":" + log.join()|,
     "threw E:call"},
    {"U6async",
     ~S|"use strict"; var box = {}; function g() { box.called = 1; throw "E" } async function f() { return g() } f().then(v => { box.v = v }, e => { box.e = e }); box|,
     %{"called" => 1.0, "e" => "E"}},
    {"U6gen",
     ~S|"use strict"; var log = []; function g() { log.push("call"); throw "E" } function* f() { return g() } var r; try { r = f().next().value } catch (e) { r = "threw " + e } r + ":" + log.join()|,
     "threw E:call"},
    {"U6genok",
     ~S|"use strict"; function g() { return "g" } function* f() { yield 1; return g() } var it = f(); it.next(); JSON.stringify(it.next())|,
     "{\"value\":\"g\",\"done\":true}"},
    {"U6ctor400",
     ~S|"use strict"; function C(n) { if (n === 0) return {v: "done"}; return mk(n - 1) } function mk(n) { return new C(n) } try { new C(400).v } catch (e) { e.constructor.name }|,
     "done"},
    {"U6ctor2000",
     ~S|"use strict"; function C(n) { if (n === 0) return {v: "done"}; return mk(n - 1) } function mk(n) { return new C(n) } try { new C(2000).v } catch (e) { e.constructor.name }|,
     "RangeError"},
    {"U6ctorstack",
     ~S|"use strict"; function g() { return {s: new Error("e").stack} } function P() { return g() } new P().s + " / " + P().s|,
     "Error: e\n    at g\n    at P / Error: e\n    at g"},
    {"U6sloppy999", ~S|function f(n) { if (n === 0) return "done"; return f(n - 1) } f(900)|,
     "done"},
    {"U6strictnew",
     ~S|"use strict"; function f(n) { return n === 0 ? "done" : f(n - 1) } function P() { this.v = f(100000) } new P().v|,
     "done"},
    {"U6arrow",
     ~S|"use strict"; var f = n => n === 0 ? "done" : f(n - 1); try { f(100000) } catch (e) { e.constructor.name }|,
     "RangeError"},
    {"U6arrowb", ~S|"use strict"; var f = n => { return n === 0 ? "done" : f(n - 1) }; f(100000)|,
     "done"}
  ]

  describe "U6: tail calls" do
    test "each row gives its value at :off and at level 4" do
      for {n, src, value} <- @rows_u6, level <- @levels do
        assert eval(src, level) == {:ok, value, []}, "#{n} at #{level}: #{src}"
      end
    end
  end

  # ── U7: using ──────────────────────────────────────────────

  # A clean disposal keeps the value of a return. A disposal error replaces a return and a
  # break. A throw and a disposal error make a SuppressedError. Rows R34 to R36 of 6.2 are
  # the same kind.
  @rows_u7 [
    {"U7ok",
     ~S|var log = []; var r = (function(){ using a = {[Symbol.dispose]() { log.push("a") }}, b = {[Symbol.dispose]() { log.push("b") }}; return "v" })(); r + ":" + log.join()|,
     "v:b,a"},
    {"U7ret",
     ~S|try { (function(){ using r = {[Symbol.dispose]() { throw "disposeErr" }}; return "ret" })() } catch (e) { e }|,
     "disposeErr"},
    {"U7brk",
     ~S|var r; try { for (;;) { using d = {[Symbol.dispose]() { throw "dErr" }}; break } r = "no" } catch (e) { r = e } r|,
     "dErr"},
    {"U7cont",
     ~S|var log = []; for (var i = 0; i < 2; i++) { using d = {[Symbol.dispose]() { log.push("d" + i) }}; if (i == 0) continue; log.push("b" + i) } log.join()|,
     "d0,b1,d1"},
    {"U7sup",
     ~S|try { (function(){ using r = {[Symbol.dispose]() { throw "d" }}; throw "body" })() } catch (e) { e.constructor.name + ":" + e.error + ":" + e.suppressed }|,
     "SuppressedError:d:body"},
    {"U7sup2",
     ~S|try { (function(){ using a = {[Symbol.dispose]() { throw "da" }}, b = {[Symbol.dispose]() { throw "db" }}; return "r" })() } catch (e) { e.constructor.name + ":" + e.error + ":" + e.suppressed }|,
     "SuppressedError:da:db"}
  ]

  describe "U7: using" do
    test "each row gives its value at :off and at level 4" do
      for {n, src, value} <- @rows_u7, level <- @levels do
        assert eval(src, level) == {:ok, value, []}, "#{n} at #{level}: #{src}"
      end
    end
  end

  # ── U8: the completion value ───────────────────────────────

  # The script writes "mark" to `:js_last`, then calls `f`. The native `peek` reads
  # `:js_last` after `f` returns. The body of `f` has loops, a bare loop body, `if`, `try`,
  # `switch`, a labeled block and a `for let`.
  @u8 ~S"""
  function f() {
    var s = 0;
    for (var i = 0; i < 2; i++) { s += i }
    for (var j = 0; j < 2; j++) s += j;
    if (s) { s++ } else { s-- }
    try { s++ } finally { s += 2 }
    switch (s) { case 1: s++; break; default: s-- }
    while (s < 10) s++;
    do { s++ } while (s < 12);
    l: { s++ }
    for (let k = 0; k < 2; k++) { s += k }
    return s
  }
  "mark";
  peek(f());
  """

  defp js_last_after_call(level) do
    gid = heap()

    peek =
      Interp.native("peek", fn _this, _args ->
        Process.put(:peeked, :erlang.get(:js_last))
        :undefined
      end)

    Interp.declare(gid, "peek", peek)
    run_script(@u8, level)
    Process.get(:peeked)
  end

  describe "U8: the completion value (:js_last)" do
    test "at :off a call changes :js_last" do
      assert js_last_after_call(:off) == 14.0
    end

    test "at level 4 a call leaves :js_last unchanged" do
      assert js_last_after_call(4) == "mark"
    end
  end

  # ── the step 3 bench programs ──────────────────────────────

  # The five step 3 programs of bench/js_runtime.exs, wrapped as that script wraps them.
  # The expected values are the results at `:off`.
  @bench_3 [
    {"stricttail40k",
     ~S|"use strict"; function loop(n, acc){ if (n === 0) return acc; return loop(n - 1, (acc + n) % 1000003) } var s = 0; for (var i = 0; i < 40; i++) s = (s + loop(1000, i)) % 1000003; return s|,
     20720.0},
    {"find20k",
     "function find(a, x){ for (var i = 0; i < a.length; i++) { if (a[i] === x) return i } return -1 } var a = [0, 1, 2, 3]; var s = 0; for (var k = 0; k < 20000; k++) s += find(a, k % 4); return s",
     30000.0},
    {"switchret30k",
     "function kind(x){ switch (x % 3) { case 0: return 1; case 1: return 2; default: return 3 } } var s = 0; for (var i = 0; i < 30000; i++) s += kind(i); return s",
     60000.0},
    {"continue60k",
     "var s = 0; for (var i = 0; i < 60000; i++) { if (i % 2) continue; s += i } return s",
     899_970_000.0},
    {"forofret10k",
     "function mk(){ var i = 0; return {[Symbol.iterator](){ return this }, next(){ return {value: i++, done: i > 3} }} } function first(it){ for (var x of it) { if (x > 0) return x } return 0 } var s = 0; for (var i = 0; i < 10000; i++) s += first(mk()); return s",
     10000.0}
  ]

  describe "the step 3 bench programs" do
    test "each program gives its value at :off and at level 4" do
      for {name, body, expected} <- @bench_3, level <- @levels do
        src = "(function(){ function f(){ #{body} } return f() })()"

        assert eval(src, level, max_steps: 1_000_000_000, timeout: 60_000) ==
                 {:ok, expected, []},
               "#{name} at #{level}"
      end
    end
  end
end

defmodule Browser.JS.CompletionEvalLevelTest do
  # Rows D1 and X11 of notes/js-step3-design.md as the design writes them, with a direct
  # eval. The parser reads the code of a direct eval at the application level
  # `:js_resolve`, not at the `resolve:` option of the outer `JS.eval`. Thus the expected
  # value follows the application level, and this module sets that level for each case.
  # The module is not async, because the application level is global to the VM.
  use ExUnit.Case, async: false

  alias Browser.JS

  @d1 [
    {"D1", ~S|eval("5; var x = (function(){ for (var i = 0; i < 1; i++) { 42 } })();")|, 42.0,
     5.0},
    {"X11", ~S|eval("1; var x = (function(){ for (;;) { break } })();")|, :undefined, 1.0}
  ]

  setup do
    old = Application.get_env(:browser, :js_resolve)
    on_exit(fn -> Application.put_env(:browser, :js_resolve, old) end)
  end

  # Runs `src` with the script and the code of its direct eval at `level`.
  defp eval_at(src, level) do
    Application.put_env(:browser, :js_resolve, level)
    JS.eval(src, resolve: level)
  end

  test "D1 at :off: the eval code still gives the completion value of the function body" do
    for {n, src, off, _} <- @d1, do: assert(eval_at(src, :off) == {:ok, off, []}, n)
  end

  test "D1: at level 4 the eval code gives the value of the spec" do
    for {n, src, _, spec} <- @d1, do: assert(eval_at(src, 4) == {:ok, spec, []}, n)
  end
end
