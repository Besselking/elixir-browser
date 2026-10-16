defmodule Browser.JS.FrameBoxesTest do
  # An assignment to a frame of `@box_min` slots or more (the scope of a bundle) puts the
  # value in a box, a heap entry `{:js_cell, v}`, and the slot keeps `{:js_box, id}`
  # (`Interp.slot_write/3`). Each read that an assignment can reach must take the value out
  # of the box. These programs assign the names of a large scope and read them back
  # through every such read: the slot read and `typeof` on the tree and in compiled code,
  # the by-name read of eval code and `with`, the copies at the body entry, and the
  # per-iteration copies of a loop frame. Each program gives the same value with the
  # resolver off (no frames), and at levels 2 and 4 with compilation off and on.
  # The heap tests look at the boxes themselves: which writes make one, that the collector
  # keeps the box of a live frame, and that a box goes when its slot is written over or its
  # frame goes, so that a loop or a call does not leave one heap entry for each round.
  use ExUnit.Case, async: true

  alias Browser.JS.{Builtins, GC, Interp, Parser}

  @check Application.compile_env(:browser, :js_resolve_check, false)

  # 130 names, so that a scope that declares them has a frame of more than 128 slots
  @vars "var " <> Enum.map_join(0..129, ", ", &"p#{&1}") <> ";"
  @lets "let " <> Enum.map_join(0..129, ", ", &"q#{&1}") <> ";"
  @head Enum.map_join(0..129, ", ", &"q#{&1}")

  # (the closure makes the function a level 2 function, whose frame can take boxes)
  big = fn body -> "(function(){ #{@vars} var keep = function(){ return p0 }; #{body} })()" end

  @rows [
    {"a closure assigns, the scope reads",
     big.(
       "var n = 0; function inc(){ n++; n += 1; return n } inc(); inc(); return [n, inc(), n, typeof n].join()"
     ), "4,6,6,number"},
    {"the scope assigns, a closure reads",
     big.(
       "var x = 1; var get = function(){ return x }; x = 'a'; x += 'b'; return [get(), typeof x, x].join()"
     ), "ab,string,ab"},
    {"compound, logical and update assignments",
     big.(
       "var x = 1; x += 2; x *= 3; x -= 1; x **= 2; var y = null; y ??= 4; y ||= 7; y &&= y + 1; var i = 0; var a = i++; var b = ++i; var c = i--; return [x, y, a, b, c, --i].join()"
     ), "64,5,0,2,2,0"},
    {"destructuring assignments and for-in and for-of heads",
     big.(
       "var x = 1, y = 2, k, v, s = ''; [x, y] = [y, x]; ({a: k} = {a: 'k'}); for (k in {a: 1, b: 2}) s += k; for (v of [3, 4]) s += v; return [x, y, s, k, v].join()"
     ), "2,1,ab34,b,4"},
    {"typeof of a box and of a name in its temporal dead zone",
     big.(
       "var f = 1; f = function(){}; var t = typeof f; try { z = 1; let z } catch (e) { t += e.name } return t"
     ), "functionReferenceError"},
    {"a declaration after an assignment writes the slot again",
     big.(
       "var x = 1; x = 2; var x = 3; x = x + 1; function g(){ return 1 } g = 5; return [x, g, delete x].join()"
     ), "4,5,false"},
    {"eval code and with read the names of the scope",
     big.(
       "var x = 1; var bump = function(){ x++ }; bump(); function peek(){ return eval('x') + ',' + eval('typeof x') } function w(){ with ({}) { x = x + 10; return x } } return [peek(), w(), x].join()"
     ), "2,number,12,12"},
    {"a let of a frameless block is in its temporal dead zone again in each round",
     big.(
       "var out = []; for (var r = 0; r < 3; r++) { try { out.push(typeof w) } catch (e) { out.push('tdz') } let w; w = r; w += 10; out.push(w) } return out.join()"
     ), "tdz,10,tdz,11,tdz,12"},
    {"each call has boxes of its own",
     "function r(n){ #{@vars} var keep = function(){ return x }; var x = 0; x = n; var sub = n > 0 ? r(n - 1) : ''; x += 100; return x + '/' + keep() + (n > 0 ? ',' + sub : '') } r(3)",
     "103/103,102/102,101/101,100/100"},
    {"a generator keeps its boxes across a yield",
     "function* g(){ #{@vars} var keep = function(){ return p0 }; var x = 0; x = 1; var y = yield x; x = y + 1; yield x; x++; return x } var it = g(); [it.next().value, it.next(10).value, it.next().value].join()",
     "1,11,12"},
    {"the copy of a parameter into the var of its name at the body entry",
     "function f(a, get = function(){ return a }, b = (function(){ a = 9; return 1 })()){ #{@vars} var a; var t = a; a = 5; return [t, a, get(), b].join() } f(1)",
     "9,5,9,1"},
    {"each round of a loop copies the values, not the boxes",
     "(function(){ var fs = []; for (let i = 0, #{@head}; i < 3; i++) { q0 = i; q1 = i * 2; fs.push(function(){ return i + ':' + q0 + ':' + ++q1 }) } return fs.map(function(f){ return f() }).join() })()",
     "0:0:1,1:1:3,2:2:5"},
    {"a large block frame in each round of a loop",
     "(function(){ var fs = []; for (const v of [1, 2, 3]) { #{@lets} q5 = v; q5 *= 2; fs.push(function(){ return q5 }) } for (var j = 0; j < 2; j++) { #{@lets} q0 = j; fs.push(function(){ return eval('q0') }) } return fs.map(function(f){ return f() }).join() })()",
     "2,4,6,0,1"},
    {"the parameters and the arguments object of a large function",
     "function f(a, b){ #{@vars} var keep = function(){ return a }; a = 5; var s = arguments[0]; arguments[1] = 9; var set = function(v){ a = v }; set(7); return [s, b, a, arguments[0], keep()].join() } f(1, 2)",
     "5,9,7,7,7"},
    {"a constructor and a derived constructor",
     "class A { constructor(x){ this.x = x } } class B extends A { constructor(){ #{@vars} var y = 1; y = 2; super(y); y = 3; this.y = y; this.f = () => y } } var b = new B(); [b.x, b.y, b.f()].join()",
     "2,3,3"}
  ]

  # Runs `src` in a fresh heap at `level`, with compilation on or off; gives the value.
  defp run(src, level, compile?) do
    Task.async(fn ->
      Interp.init(1_000_000)
      Process.put(:js_compile, compile?)
      Builtins.install()
      {:ok, program} = Parser.parse(src, resolve: level)
      Interp.run_program(program, true)
    end)
    |> Task.await(30_000)
  end

  describe "the same values with the resolver off and on" do
    for {name, src, value} <- @rows do
      test name do
        for {level, compile?} <- [{:off, false}, {2, false}, {2, true}, {4, false}, {4, true}] do
          assert {unquote(name), level, compile?, run(unquote(src), level, compile?)} ==
                   {unquote(name), level, compile?, unquote(value)}
        end
      end
    end
  end

  describe "the heap" do
    # Starts a heap in the test process and runs `src` at level 4, compiled or on the tree.
    defp heap(src, compile? \\ true) do
      Interp.init(1_000_000)
      Process.put(:js_compile, compile?)
      Builtins.install()
      gid = Interp.global()
      {:ok, program} = Parser.parse(src, resolve: 4)
      Interp.run_program(program, true)
      gid
    end

    defp global!(gid, name) do
      assert {:ok, v} = Interp.lookup_scoped(gid, name)
      v
    end

    # The slot of `name` in the frame that the closure `f` keeps.
    defp slot_of(f, name) do
      {:obj, id} = f
      {:closure, c} = Interp.deref(id).fun
      t = :erlang.get(c.scope)
      :erlang.element(:erlang.element(2, t).slots[name], t)
    end

    test "an assignment or an update of a name of a large frame makes a box" do
      for compile? <- [true, false] do
        gid =
          heap(
            "var big = (function(){ #{@vars} var x = 1, y = 0; x = 2; x = 3; y++; ++y; return function(){ return x + y } })();\n" <>
              "var small = (function(){ var x = 1; x = 2; return function(){ return x } })();",
            compile?
          )

        big = global!(gid, "big")
        assert {:js_box, b} = slot_of(big, "x")
        assert :erlang.get(b) == {:js_cell, 3.0}
        assert {:js_box, c} = slot_of(big, "y")
        assert :erlang.get(c) == {:js_cell, 2.0}
        assert slot_of(global!(gid, "small"), "x") == 2.0
      end
    end

    test "the collector keeps the box of a live frame and frees the box of a dead one" do
      gid =
        heap(
          "var get = (function(){ #{@vars} var x = {n: 1}; x = {n: 2}; return function(){ return x.n } })();\n" <>
            "var gone = (function(){ #{@vars} var y = {n: 3}; y = {n: 4}; return function(){ return y.n } })();"
        )

      {:js_box, b} = slot_of(global!(gid, "get"), "x")
      {:js_box, c} = slot_of(global!(gid, "gone"), "y")
      {:ok, program} = Parser.parse("gone = undefined", resolve: 4)
      Interp.run_program(program, true)
      GC.collect()

      assert Interp.call(global!(gid, "get"), :undefined, []) == 2.0
      assert match?({:js_cell, {:obj, _}}, :erlang.get(b))
      assert :erlang.get(c) == :undefined
    end

    test "a large leaf frame takes no box" do
      # (a leaf frame of a normal build is under the key of its depth, and the next leaf
      # call at that depth writes over it)
      gid = heap("function leaf(n){ #{@vars} var x = n; x = x + 1; p1 = x; return p1 }")
      leaf = global!(gid, "leaf")
      next = :erlang.get(:js_next)
      assert Interp.call(leaf, :undefined, [1.0]) == 2.0
      # (the check build gives each frame a heap id and boxes like any other frame)
      unless @check, do: assert(:erlang.get(:js_next) == next)
    end

    # {name, source of `f(n)`, f(10), f(110), objects}: the rounds of `f` write over boxes,
    # or free frames that hold boxes. `objects` is what 100 rounds keep: the functions and
    # the arrays that the rounds make.
    @leaks [
      {"a large frame freed at each return",
       "function big(a){ #{@vars} var x = new.target ? 0 : 1; x = x + a; p1 = x; return p1 }\n" <>
         "function f(n){ var s = 0; for (var i = 0; i < n; i++) s += big(i); return s }", 55.0,
       6105.0, 0},
      {"a var declared again in each round",
       "function f(n){ #{@vars} var keep = function(){ return p0 }; var s = 0; for (var i = 0; i < n; i++) { var t = i; t = t * 2; s += t } return s }",
       90.0, 11990.0, 0},
      {"a let in its temporal dead zone again in each round",
       "function f(n){ #{@vars} var keep = function(){ return p0 }; var s = 0; for (var i = 0; i < n; i++) { let w; w = i; s += w } return s }",
       45.0, 5995.0, 0},
      {"a block function made again in each round",
       "function f(n){ 'use strict'; #{@vars} var keep = function(){ return p0 }; var s = 0; for (var i = 0; i < n; i++) { function h(){ return 1 } s += h(); h = 2; s += h } return s }",
       30.0, 330.0, 100},
      {"the frame of the item before, reused for the next item",
       "function f(n){ #{@vars} var keep = function(){ return p0 }; var fs = [], s = 0; for (let [#{@head}] of Array.from({length: n}, (_, k) => [k])) { q0 += 1; s += q0; if (q0 < 0) fs.push(() => q0) } return s }",
       55.0, 6105.0, 100}
    ]

    for {name, src, small, large, objects} <- @leaks do
      test "a box goes when its slot or its frame goes: #{name}" do
        f = global!(heap(unquote(src)), "f")
        assert Interp.call(f, :undefined, [10.0]) == unquote(small)

        # (100 more rounds keep only the objects that they make)
        [g, h] =
          for {n, value} <- [{10.0, unquote(small)}, {110.0, unquote(large)}] do
            size = Interp.heap_size()
            assert Interp.call(f, :undefined, [n]) == value
            Interp.heap_size() - size
          end

        assert h - g == unquote(objects)
      end
    end
  end
end
