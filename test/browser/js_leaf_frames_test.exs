defmodule Browser.JS.LeafFramesTest do
  # In a normal build the frame of a leaf call (a level 1 function) is not a heap entry. It
  # is under the key of the depth of its caller (`@leaf_base` in `Browser.JS.Interp`), and
  # the next leaf call at that depth writes over it. The check build keeps the heap frames,
  # so the test262 oracle of the check build does not test this path. These programs call
  # leaves in the places where the frame of a wrong call could show: nested and sibling
  # calls, closures, recursion and the depth limit, throws, tail calls, generators, async
  # bodies, `arguments`, `eval` and `with`, and calls back from built-ins and from the DOM.
  use ExUnit.Case, async: true

  alias Browser.JS
  alias Browser.JS.{Builtins, GC, Interp, Parser, Runtime}
  require Interp

  @check Application.compile_env(:browser, :js_resolve_check, false)

  # {name, source, value}: each program gives `value` with the resolver off (no frames) and
  # at levels 1 and 4.
  @rows [
    {"nested leaves keep their own slots",
     ~S"""
     function c(x){ var k = x + 1; return k }
     function b(x){ var z = c(x + 1); return x * z }
     function a(x){ var y = b(x + 1); return [x, y].join() }
     a(1)
     """, "1,8"},
    {"sibling leaves at one depth do not change the slots of their caller",
     ~S"""
     function g(p, q){ return p - q }
     function h(a){ var t = g(a, 1); var u = g(t, a); var v = g(u, t); return [a, t, u, v].join() }
     h(10)
     """, "10,9,-1,-10"},
    {"a closure keeps the frame of its maker while leaves run at that depth",
     ~S"""
     function leaf(x){ var y = x * 2; return y }
     function mk(n){ var v = leaf(n); return function(){ return v + leaf(1) } }
     var fs = [];
     for (var i = 0; i < 4; i++) fs.push(mk(i));
     fs.map(function(f){ return f() }).join()
     """, "2,4,6,8"},
    {"recursion of leaves",
     ~S"""
     function fib(n){ if (n < 2) return n; return fib(n - 1) + fib(n - 2) }
     function down(n){ return n == 0 ? 0 : 1 + down(n - 1) }
     [fib(15), down(900)].join()
     """, "610,900"},
    {"the depth limit throws through 1000 leaves, and the leaves work after it",
     ~S"""
     function down(n){ return n == 0 ? 0 : 1 + down(n - 1) }
     function probe(n){ var before = n; var r; try { r = down(n) } catch (e) { r = e instanceof RangeError } return before + ":" + r }
     [probe(5000), probe(3), down(10)].join()
     """, "5000:true,3:3,10"},
    {"a throw from a leaf, a catch and a finally in a leaf",
     ~S"""
     function t(x){ var m = "x" + x; if (x > 2) throw new Error(m); return x }
     function w(x){ var a = x * 10; try { return t(x) } catch (e) { return a + ":" + e.message } finally { last = a } }
     var last = 0;
     [w(1), w(3), last].join()
     """, "1,30:x3,30"},
    {"tail calls of leaves, and a tail call under new",
     ~S"""
     "use strict";
     function step(n, acc){ if (n == 0) return acc; return step(n - 1, acc + n) }
     function outer(n){ var k = n; var r = step(n, 0); return k + ":" + r }
     function make(x){ return x }
     function P(x){ this.v = x; return make(x) }
     [outer(100), new P(3).v].join()
     """, "100:5050,3"},
    {"a generator calls leaves, and a leaf runs the generator",
     ~S"""
     function sq(x){ return x * x }
     function* gen(n){ for (var i = 0; i < n; i++) yield sq(i) + sq(i + 1) }
     function pull(it){ var k = sq(2); var r = it.next(); var s = sq(3); return r.value + k + s }
     var it = gen(3);
     [pull(it), pull(it), pull(it)].join()
     """, "14,18,26"},
    {"a mapped arguments object in a caller of leaves",
     ~S"""
     function sq(x){ return x * x }
     function m(a, b){ arguments[0] = sq(a); var r = a + sq(b); return [a, r, arguments.length].join() }
     m(2, 3)
     """, "4,13,2"},
    {"eval and with around leaves",
     ~S"""
     function sq(x){ return x * x }
     function e(x){ var y = x + 1; return eval("sq(y) + x") }
     function w(o){ var k = 1; with (o) { return sq(k) + k } }
     [e(2), w({k: 3}), w({}), (0, eval)("sq(5)")].join()
     """, "11,12,2,25"},
    {"built-ins call leaves back from inside a leaf",
     ~S"""
     function cmp(a, b){ var d = a - b; return d }
     function dbl(x){ return x * 2 }
     function sum(acc, x){ return acc + x }
     function up(m){ return m.toUpperCase() }
     function rep(k, v){ return typeof v === "number" ? dbl(v) : v }
     function val(){ return dbl(21) }
     function getv(){ return dbl(4) }
     function trap(t, k){ return k === "z" ? dbl(5) : t[k] }
     function s(arr){
       var n = arr.length;
       arr.sort(cmp);
       var m = arr.map(dbl);
       var r = m.reduce(sum, 0);
       var str = "a-b".replace(/[a-z]/g, up);
       var j = JSON.stringify({p: 1, q: [2]}, rep);
       var o = {valueOf: val};
       var g = {};
       Object.defineProperty(g, "v", {get: getv});
       var p = new Proxy({y: 7}, {get: trap});
       return [n, arr.join("|"), r, str, j, o + 1, g.v, p.z, p.y].join(" ")
     }
     s([3, 1, 2])
     """, ~S'3 1|2|3 12 A-B {"p":2,"q":[4]} 43 8 10 7'},
    {"class constructors and methods call leaves",
     ~S"""
     function sq(x){ return x * x }
     class A { constructor(x){ this.x = sq(x) } m(y){ var t = sq(y); return this.x + t } static s(z){ return sq(z) + 1 } }
     var a = new A(2);
     [a.x, a.m(3), A.s(4)].join()
     """, "4,13,17"}
  ]

  describe "the same results with the resolver off and on" do
    for {name, src, value} <- @rows do
      test name do
        for level <- [:off, 1, 4] do
          assert {unquote(name), level, JS.eval(unquote(src), resolve: level)} ==
                   {unquote(name), level, {:ok, unquote(value), []}}
        end
      end
    end

    test "async bodies call leaves across their awaits" do
      src = ~S"""
      function sq(x){ return x * x }
      function add(a, b){ var s = a + b; return s }
      async function job(x){ var y = sq(x); await null; var z = add(y, sq(2)); await Promise.resolve(1); return add(z, x) }
      function start(x){ var k = sq(x); job(x).then(function(v){ console.log("job", x, v, sq(k)) }); return k }
      console.log("sync", start(2), start(3));
      """

      logs = [{:log, "sync 4 9"}, {:log, "job 2 10 16"}, {:log, "job 3 16 81"}]

      for level <- [:off, 1, 4] do
        assert {level, JS.eval(src, resolve: level)} == {level, {:ok, :undefined, logs}}
      end
    end
  end

  describe "the DOM calls leaves back" do
    test "event listeners run on top of the frame of a leaf that dispatches the event" do
      script = ~S"""
      function sq(x){ return x * x }
      function onclick(e){ var a = sq(2); log.push("in:" + a + ":" + e.type) }
      function onping(e){ var d = e.detail; log.push("ping:" + sq(d)); if (d > 4) document.body.dispatchEvent(new Event("deep")) }
      function ondeep(){ var q = sq(7); log.push("deep:" + q) }
      function onboom(){ sq(1); throw new Error("boom") }
      var log = [];
      var b = document.getElementById("b");
      b.addEventListener("click", onclick);
      b.addEventListener("ping", onping);
      b.addEventListener("boom", onboom);
      document.body.addEventListener("deep", ondeep);
      function outer(x){
        var keep = x + 1;
        b.click();
        var mid = sq(keep);
        b.dispatchEvent(new CustomEvent("ping", {detail: keep}));
        b.dispatchEvent(new Event("boom"));
        return [x, keep, mid].join()
      }
      log.push(outer(3));
      log.push(outer(4));
      console.log(log.join(" "));
      """

      {raw, _} =
        "<body><button id=b>x</button><script>#{script}</script></body>"
        |> Browser.HTML.parse()
        |> Browser.Forms.index()

      pid =
        Runtime.start(raw, %{
          url: "http://t.test/",
          width: 800,
          height: 600,
          fetch: fn _ -> {:error, "404"} end
        })

      reply = Runtime.run_scripts(pid)
      logs = for {:log, t} <- reply.console, do: t

      assert logs == [
               "in:4:click ping:16 3,4,16 in:4:click ping:25 deep:49 4,5,25"
             ]

      # (the listener that throws reports its error, and the leaf that dispatched goes on)
      assert length(for {:error, t} <- reply.console, t =~ "boom", do: t) == 2
    end
  end

  describe "the heap" do
    # Starts a heap in the test process and runs `src` at level 4.
    defp heap(src) do
      Interp.init(1_000_000)
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

    test "a leaf call takes no heap id, and the heap count stays the same" do
      gid =
        heap(
          "function leaf(x){ var y = x + 1; return y }\n" <>
            "function loop(n){ var t = 0; for (var i = 0; i < n; i++) t = leaf(t); return t }"
        )

      loop = global!(gid, "loop")
      next = :erlang.get(:js_next)
      size = Interp.heap_size()
      assert Interp.call(loop, :undefined, [1000.0]) == 1000.0
      assert Interp.heap_size() == size
      # (the check build gives each frame a heap id and frees it after the call)
      if @check, do: assert(:erlang.get(:js_next) == next + 1001)
      unless @check, do: assert(:erlang.get(:js_next) == next)
    end

    @tag skip: @check && "the check build keeps the leaf frames in the heap"
    test "the collector erases the leaf frames and frees what only they held" do
      gid = heap("function keep(o){ var v = o.v; return v }\nvar r = keep({v: 1})")
      base = Interp.leaf_base()

      # The top-level call has the depth 0, so its frame is under the first key. The frame
      # still holds the argument after the call.
      assert {_, _, _, _, _, {:obj, oid}, 1.0} = :erlang.get(base)
      assert is_map(:erlang.get(oid))

      # A number that equals a leaf key is not an id: the walk must not read the old frame.
      Process.put(:leaf_number, base)
      GC.collect()
      Process.delete(:leaf_number)

      assert :erlang.get(base) == :undefined
      assert :erlang.get(oid) == :undefined

      keep = global!(gid, "keep")
      obj = Interp.new_object()
      Interp.put(obj, "v", 5.0)
      assert Interp.call(keep, :undefined, [obj]) == 5.0
    end
  end
end
