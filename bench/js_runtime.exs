# Usage: RUNS=5 RESOLVE=off mix run --no-start bench/js_runtime.exs [name ...]
#
# RESOLVE is the resolver level the programs are parsed with (`off`, the default, `info`,
# 1, 2, 3 or 4; see `Browser.JS.Resolve`).
#
# This script measures nine JS programs. The programs stress the interpreter core: calls,
# closures, property access, arrays, strings, a large function body, class methods, a tree
# walk and DOM-like objects. After their total it measures four programs of step 2d and six
# programs of step 2e, which are not in the total. The script wraps each program in a function. Page scripts
# usually run in a function too. The script runs each program RUNS times (default 5). The
# table shows the minimum time and the minimum number of reductions in millions. A reduction
# is a BEAM work unit. The number of reductions does not change with the speed of the
# machine. Use it to compare two builds on a noisy machine. The script compares the result of
# every run with the expected value. It exits with status 1 when a result is wrong.
#
# The QuickJS column shows the time of QuickJS 2021-03-27 (a bytecode interpreter, gcc -O2)
# on the same machine. It is the mean of 5 runs. We measured it on 2026-10-09 for the language
# cost study in the project notes.
#
# To run only some programs, give their names or a part of a name:
# mix run --no-start bench/js_runtime.exs fib tree
alias Browser.JS

wrap = fn body -> "(function(){ function f(){ #{body} } return f() })()" end

big_body =
  "function big(x) { var t = 0;" <>
    String.duplicate(" if (x < 0) { t += 1 }", 300) <>
    " return t + x } var r = 0; for (var i = 0; i < 20000; i++) r += big(i); return r"

programs = [
  {"fib25", "fib(25) recursive calls", 12.5, 75025.0,
   "function fib(n){ return n < 2 ? n : fib(n-1) + fib(n-2) } return fib(25)"},
  {"closures60k", "60k closure calls", 22.2, 964_603.0,
   "var s = 0; var add = function(a){ return function(b){ return a + b } }; for (var i = 0; i < 60000; i++) { s = add(i)(s) % 1000003 } return s"},
  {"propaccess60k", "60k property reads/writes", 4.0, 1_800_270_000.0,
   "var o = {a:1,b:2,c:3}; var t = 0; for (let i = 0; i < 60000; i++) { o.a = i; t += o.a + o.b + o.c } return t"},
  {"array20k", "array push/map/filter/reduce 20k", 3.4, 133_326_666.0,
   "var a = []; for (var i = 0; i < 20000; i++) a.push(i); return a.map(x => x * 2).filter(x => x % 3 == 0).reduce((p, c) => p + c, 0)"},
  {"strbuild20k", "string building 20k", 5.5, 20000.0,
   "var s = ''; for (var i = 0; i < 20000; i++) { s += String(i % 10) } return s.length"},
  {"bigfn20k", "big function body, 20k calls", 31.3, 199_990_000.0, big_body},
  {"classcalls30k", "class method calls 30k", 1.9, 30000.0,
   "class P { constructor(x){ this.x = x } inc(){ this.x++; return this } } var p = new P(0); for (var i = 0; i < 30000; i++) p.inc(); return p.x"},
  {"treewalk", "tree walk (layout like)", 12.9, 61440.0,
   """
   function mk(d){ if(d==0) return {w:10,h:5,kids:[]}; var k=[]; for(var i=0;i<4;i++) k.push(mk(d-1)); return {w:0,h:0,kids:k}; }
   function lay(n,x,y){ if(n.kids.length==0){ n.x=x;n.y=y; return n.h; } var cy=y; for(var i=0;i<n.kids.length;i++){ cy+=lay(n.kids[i],x+2,cy) } n.x=x;n.y=y;n.h=cy-y; return n.h }
   var t=mk(6); var s=0; for(var r=0;r<3;r++) s+=lay(t,0,0); return s
   """},
  {"domlike", "DOM-like objects and queries", 8.3, 3000.0,
   """
   var els=[]; for(var i=0;i<3000;i++){ els.push({tag:'div',attrs:{id:'e'+i,class:'c'+(i%7)},children:[],parent:null}) }
   for(var i=1;i<els.length;i++){ var p=els[(i-1)>>1]; p.children.push(els[i]); els[i].parent=p }
   var cnt=0; function q(n,c){ if(n.attrs['class']===c) cnt++; for(var i=0;i<n.children.length;i++) q(n.children[i],c) }
   for(var k=0;k<7;k++) q(els[0],'c'+k); return cnt
   """}
]

# Four programs of step 2d (level 3 functions on frames: class constructors, default derived
# constructors, `super` and private names in methods, and `arguments`). They show the gain
# of that step and are not in the total of the nine programs above. QuickJS has no time
# for them. The expected values are the results at `:off`.
extra_programs = [
  {"classnew30k", "new of a class 30k", nil, 449_985_000.0,
   "class P { y = 1; constructor(x){ this.x = x } } var s = 0; for (var i = 0; i < 30000; i++) s += new P(i).x; return s"},
  {"subclass30k", "new of a default subclass 30k", nil, 449_985_000.0,
   "class B { constructor(x){ this.x = x } } class D extends B {} var s = 0; for (var i = 0; i < 30000; i++) s += new D(i).x; return s"},
  {"supercalls30k", "super.m() and this.#x 30k", nil, 73650.0,
   "class A { m(x){ return x + 1 } } class B extends A { #x = 2; m(x){ return super.m(x) + this.#x } } var b = new B(); var s = 0; for (var i = 0; i < 30000; i++) s = (s + b.m(i)) % 1000003; return s"},
  {"args30k", "arguments reads 30k", nil, 149_995.0,
   "function g(a, b){ return arguments.length + arguments[1] } var s = 0; for (var i = 0; i < 30000; i++) s += g(i, i % 7); return s"}
]

# Six programs of step 2e (level 4: async functions, generators and async generators on
# frames). They are not in the total either. An async program returns a box, which the
# script reads after the microtasks and timers ran. The expected values are the results at
# `:off`.
programs_2e = [
  {"await20k", "await in a loop 20k", nil, %{"v" => 989_403.0},
   "var box = {}; async function run(){ var s = 0; for (let i = 0; i < 20000; i++) { s = (s + await i) % 1000003 } return s } run().then(v => { box.v = v }); return box"},
  {"asynccalls10k", "async function calls 10k", nil, %{"v" => 994_853.0},
   "var box = {}; async function add(a, b){ return a + b } async function run(){ var s = 0; for (let i = 0; i < 10000; i++) { s = (await add(s, i)) % 1000003 } return s } run().then(v => { box.v = v }); return box"},
  {"awaitclosures10k", "closures over a let after await 10k", nil, %{"v" => 49_995_000.0},
   "var box = {}; async function run(){ var fs = []; for (let i = 0; i < 10000; i++) { await null; fs.push(() => i) } var s = 0; for (var j = 0; j < fs.length; j++) s += fs[j](); return s } run().then(v => { box.v = v }); return box"},
  {"gen30k", "generator range 30k", nil, 983_653.0,
   "function* range(n){ for (let i = 0; i < n; i++) yield i } var s = 0; for (const v of range(30000)) s = (s + v) % 1000003; return s"},
  {"yieldstar10k", "yield* delegation 10k", nil, 30000.0,
   "function* two(){ yield 1; yield 2 } function* outer(n){ for (let i = 0; i < n; i++) yield* two() } var s = 0; for (const v of outer(10000)) s += v; return s"},
  {"asyncgen5k", "async generator with for await 5k", nil, %{"v" => 12_497_500.0},
   "var box = {}; async function* ag(n){ for (let i = 0; i < n; i++) yield i } async function run(){ var s = 0; for await (const v of ag(5000)) s += v; return s } run().then(v => { box.v = v }); return box"}
]

runs = String.to_integer(System.get_env("RUNS", "5"))
filter = System.argv()

pick = fn list ->
  if filter == [],
    do: list,
    else:
      Enum.filter(list, fn {id, _, _, _, _} ->
        Enum.any?(filter, &String.contains?(id, &1))
      end)
end

selected = pick.(programs)
selected_extra = pick.(extra_programs)
selected_2e = pick.(programs_2e)

resolve =
  case System.get_env("RESOLVE", "off") do
    "off" -> :off
    "info" -> :info
    "1" -> 1
    "2" -> 2
    "3" -> 3
    "4" -> 4
    other -> raise "RESOLVE takes off, info, 1, 2, 3 or 4, not #{other}"
  end

opts = [max_steps: 1_000_000_000, timeout: 300_000, resolve: resolve]

IO.puts(
  String.pad_trailing("program", 34) <>
    String.pad_leading("min ms", 8) <>
    String.pad_leading("Mred", 7) <>
    String.pad_leading("QuickJS", 9) <> String.pad_leading("ratio", 7) <> "   result"
)

# Runs the programs of `list` and prints one row for each. Returns the total of the minimum
# times and the number of wrong results.
run_list = fn list ->
  Enum.reduce(list, {0.0, 0}, fn {_id, name, qjs, expected, body}, {total, bad} ->
    src = wrap.(body)

    {ms, reds, val, ok} =
      Enum.reduce(1..runs, {nil, nil, nil, true}, fn _, {best, best_reds, _, ok} ->
        :erlang.statistics(:exact_reductions)
        {us, res} = :timer.tc(fn -> JS.eval(src, opts) end)
        {_, reds} = :erlang.statistics(:exact_reductions)
        ms = us / 1000
        val = elem(res, 1)

        {if(best == nil or ms < best, do: ms, else: best),
         if(best_reds == nil or reds < best_reds, do: reds, else: best_reds), val,
         ok and val == expected}
      end)

    {qjs_col, ratio_col} =
      if qjs,
        do:
          {:erlang.float_to_binary(qjs, decimals: 1),
           :erlang.float_to_binary(ms / qjs, decimals: 0) <> "x"},
        else: {"-", "-"}

    IO.puts(
      String.pad_trailing(name, 34) <>
        String.pad_leading(:erlang.float_to_binary(ms, decimals: 1), 8) <>
        String.pad_leading(:erlang.float_to_binary(reds / 1_000_000, decimals: 1), 7) <>
        String.pad_leading(qjs_col, 9) <>
        String.pad_leading(ratio_col, 7) <>
        "   " <> inspect(val) <> if(ok, do: "", else: "  WRONG, expected #{inspect(expected)}")
    )

    {total + ms, if(ok, do: bad, else: bad + 1)}
  end)
end

{total, bad} = run_list.(selected)

IO.puts(
  String.pad_trailing("total", 34) <>
    String.pad_leading(:erlang.float_to_binary(total, decimals: 1), 8)
)

{_, bad_extra} =
  if selected_extra == [] do
    {0.0, 0}
  else
    IO.puts("step 2d programs (not in the total)")
    run_list.(selected_extra)
  end

{_, bad_2e} =
  if selected_2e == [] do
    {0.0, 0}
  else
    IO.puts("step 2e programs (not in the total)")
    run_list.(selected_2e)
  end

if bad + bad_extra + bad_2e > 0, do: System.halt(1)
