defmodule Browser.JS.ResolveTest do
  # The unit tests of the resolver design (notes/js-resolver-design.md, section 6). Each test
  # carries its number in the design. The expected values are the design's own; where the
  # design gives a rule and no value, a comment names the rule the value comes from.
  use ExUnit.Case, async: true

  alias Browser.JS.{Interp, Parser, Resolve}
  alias Browser.JS.Resolve.{Info, Scope}

  # ── sources ─────────────────────────────────────────────────

  @s1 "function f(a, b) { var c; let d; const e = 1; function g(){} }"
  @s2a "function f(a, a) { return a }"
  @s2b "function f(a) { var a; function a(){} }"
  @s3 "function f() { g(); function g(){} function g(){ return 2 } }"
  @s4a "function f() { let x = 1; { let x = 2; return x } }"
  @s4b "function f() { { return 1 } }"
  @s5a "function f() { let fs = []; { let x; fs.push(() => x) } }"
  @s5b "function f() { let fs = []; { let x; fs.push(() => [fs, x]) } }"
  @s6a "function f(n, fs) { for (let i = 0; i < n; i++) fs.push(() => i) }"
  @s6b "function f(n, use) { for (let i = 0; i < n; i++) use(i) }"
  @s6c "function f(n, fs) { for (let i = 0; i < n; i++) fs.push(() => 0) }"
  @s7a "function f(o) { for (const k in o) k }"
  @s7b "function f(xs) { for (const [a, b] of xs) a + b }"
  @s7c "async function f(y) { for await (const x of y) x }"
  @s7d "async function f(y) { for await (var x of y) x }"
  @s7e "function f(xs, fs) { for (const x of xs) fs.push(() => x) }"
  @s8a "function f(v) { switch (v) { case 1: let a; function g(){} } }"
  @s8b "function f(v) { switch (v) { case v: let a; function g(){ return a } } }"
  @s8c "function f() { try {} catch ({ a, b }) { a + b } }"
  @s8d "function f(fs) { try {} catch (e) { fs.push(() => e) } }"
  @s9 "function f() { using r = x; let y = 1; r = 2; return y }"
  @s10a "(function g() { g = 1; return g })"
  @s10b "(function g() { \"use strict\"; g = 1; return g })"
  @s10c "(function g(g) {})"
  @s10d "function g() { g = 1 }"
  @s11 "function f() { const c = 1; c = 2; delete c; delete y }"
  @s12a "function f(a) { arguments[0] = 2; a = 3; return a }"
  @s12b "function f(a) { \"use strict\"; arguments[0] = 2; return a }"
  @s12c "function f(a = 1) { arguments[0] = 2; return a }"
  @s12d "function f() { var arguments; return arguments }"
  @s12e "function f() { let arguments; return arguments }"
  @s12f "function f(arguments) { return arguments }"
  @s12g "function f(a) { return () => arguments[0] }"
  @s13a "({ m() { return this.x } })"
  @s13b "({ m() { return () => this } })"
  @s13c "class A { x = () => this }"
  @s14 "class B extends A { constructor() { super(); return new.target } }"
  @s15a "function outer(z) { function f() { eval(\"x\"); return () => y } return z }"
  @s15b "function f() { eval?.(\"x\"); (0, eval)(\"x\") }"
  @s16a "function f() { { let z; function g() { return eval(\"z\") } } }"
  @s16b "function f() { { let z; } function g() { return eval(\"z\") } }"
  @s16c "with (o) { function h() { return x } } function k() { return x }"
  @s17a "function f() { return Math.max(y, 1) }"
  @s17b "let l = 1; function f() { return Math.max(y, l) }"
  @s17c "var v = 1; let l = 2; function g() {} function f() { return v + l + y + g }"
  @s17d "\"use strict\"; var v = 1; function g() {} function f() { return v + g }"
  @s18a "import { a } from \"m\"; const b = 1; export function f() { return a + b + c } { let q = b }"
  @s18b "export default function () {}"
  @s18c "const b = 1; var r = await g(() => b + c);"
  @s19a "function outer() { let v; class A { m() { return A + v } static { var s; s } } }"
  @s19b "class A { #p; m(o) { return #p in o } }"
  @s20a "function f(a = 1, g = () => a) { var a; }"
  @s20b "function f(a = 1) { var a }"
  @s20c "function f(a = b) { var b }"
  @s20d "function f({a, b}, [c]) {}"
  @s21a "\"use strict\"; function f(){ return 1 }"
  @s21b "\"use strict\"; (() => 1)"
  @s21c "(() => 1)"
  @s21d "function f() { \"use strict\"; return () => 1 }"
  @s22_tail [
    "\"use strict\"; function f() { return g() }",
    "\"use strict\"; function f() { return a ? g() : h() }",
    # `labeled` does not clear the tail flag (design 4.9 names the statements that do).
    "\"use strict\"; function f() { l: { return g() } }",
    # A handler without a finalizer keeps the flag (design 4.9: catch-with-finally clears it).
    "\"use strict\"; function f() { try {} catch (e) { return g() } }"
  ]
  @s22_no_tail [
    "\"use strict\"; function f() { try { return g() } catch (e) {} }",
    "\"use strict\"; function f() { try {} catch (e) { return g() } finally {} }",
    "function f() { with (o) { return g() } }",
    "\"use strict\"; function f() { for (x of y) return g() }",
    "\"use strict\"; function f() { for (x in y) return g() }",
    "\"use strict\"; function f() { using r = x; return g() }",
    "class C { constructor() { return g() } }",
    "\"use strict\"; async function f() { return g() }",
    "\"use strict\"; function* f() { return g() }",
    "function f() { return g() }",
    "\"use strict\"; function f() { return eval() }",
    "\"use strict\"; function f() { return g?.() }"
  ]
  @s23a "async function f() { x; await y; if (c) { await z } }"
  @s23b "async function f() { class A { [await k]() {} } }"
  @s23c "function f() { x; y }"
  @s23d "await 1; x"
  @s23e "function* f() { yield 1 }"
  @s24 "function f() { let fs = []; { let x; fs.push((p) => p + x) } }"
  # Field initializers as closure boundaries: a loop, a block and the parameter phase.
  @s30a "function f(cs) { for (let i = 0; i < 2; i++) { cs.push(class { x = i; accessor y = i }) } }"
  @s30b "function f(fs) { for (let k of [1,2]) { let v = k; fs.push(class { x = v }) } }"
  @s30c "function f(a, C = class { x = a }) { var a = 2; return new C().x }"
  @s30d "function f() { let x = 1; return class { static s = x } }"
  @s31 "function f() { let x = 1; return new (class { y = eval(\"x\"); static z = eval(\"x\"); accessor w = eval(\"x\") })().y }"
  @s32a "function f(a = () => arguments) { var arguments = 5; return [typeof a(), arguments] }"
  @s32b "function f(a = arguments) { var arguments; return arguments }"
  @s32c "function f(a = () => arguments) { function arguments() {} return arguments }"
  @s32d "function f(p = () => arguments) { let arguments = 1; return arguments }"
  @s33a "function f(a = 1, g = () => a) { var a; function a() {} }"
  @s33b "function f(a, b = () => a, c) { var a; }"
  @s33c "function f(a = () => a) { var a; function a(){} return a }"
  @s34a "class C { m() { return () => super.y } }"
  @s34b "class B extends A { constructor() { (() => super())() } }"
  @s35 "using x = y; import { a } from \"m\"; export const b = 1; function f() { return a + b + x }"
  @s36 "function f(xs) { for (using x of (() => eval(\"x\"))()) {} }"
  @s37a "async function f() { for (let i = 0; i < 1; i++) { await x } }"
  @s37b "async function f() { const g = async () => { await x }; y }"
  @s37c "async function f() { for await (const x of y) {} await using r = z; w }"
  @s38a "function f(fs) { { let a; let b; fs.push(() => a + b); { function g(){} let c } } }"
  @s38b "(class A { constructor() {} })"
  @s38c "(class B extends A { constructor(...args) { super(...args) } })"

  # Every source of this file with its parse options, for the flag-off and scope-count tests.
  @cases Enum.map(
           [
             @s1,
             @s2a,
             @s2b,
             @s3,
             @s4a,
             @s4b,
             @s5a,
             @s5b,
             @s6a,
             @s6b,
             @s6c,
             @s7a,
             @s7b,
             @s7c,
             @s7d,
             @s7e,
             @s8a,
             @s8b,
             @s8c,
             @s8d,
             @s9,
             @s10a,
             @s10b,
             @s10c,
             @s10d,
             @s11,
             @s12a,
             @s12b,
             @s12c,
             @s12d,
             @s12e,
             @s12f,
             @s12g,
             @s13a,
             @s13b,
             @s13c,
             @s14,
             @s15a,
             @s15b,
             @s16a,
             @s16b,
             @s16c,
             @s17a,
             @s19a,
             @s19b,
             @s20a,
             @s20b,
             @s20c,
             @s20d,
             @s21a,
             @s21b,
             @s21c,
             @s21d,
             @s23a,
             @s23b,
             @s23c,
             @s23e,
             @s24,
             @s30a,
             @s30b,
             @s30c,
             @s30d,
             @s31,
             @s32a,
             @s32b,
             @s32c,
             @s32d,
             @s33a,
             @s33b,
             @s33c,
             @s34a,
             @s34b,
             @s36,
             @s37a,
             @s37b,
             @s37c,
             @s38a,
             @s38b,
             @s38c
           ] ++ @s22_tail ++ @s22_no_tail,
           &{&1, []}
         ) ++
           [
             {@s21a, [file: "t.js"]},
             {@s17b, [eval: true]},
             {@s17c, [eval: true, indirect: true]},
             {@s17d, [eval: true, indirect: true]},
             {@s18a, [module: true]},
             {@s18b, [module: true]},
             {@s18c, [module: true]},
             {@s23d, [module: true]},
             {@s35, [module: true]}
           ]

  # The scripts of the `functions`, `classes`, `scope lifetime` and `explicit resource
  # management` groups of js_test.exs, run with and without `resolve: :info` in test 26.
  @eval_sources [
    "function fib(n) { return n < 2 ? n : fib(n - 1) + fib(n - 2) } fib(15)",
    "function counter() { var n = 0; return () => ++n } var c = counter(); c(); c(); c()",
    "var f = function fact(n) { return n <= 1 ? 1 : n * fact(n - 1) }; f(5)",
    "(x => y => x + y)(1)(2)",
    "function f(a, b = 2, ...c) { return [a, b, c.length] } f(1).concat(f(1, 5, 6, 7))",
    "Math.max(...[1, 5, 3], 4)",
    "[...'ab', ...[1, 2]].length",
    "var o = {a: 1, ...{b: 2, a: 3}}; [o.a, o.b]",
    "function F(x) { this.x = x } F.prototype.get = function () { return this.x }; new F(7).get()",
    "function F() {} new F() instanceof F",
    "var o = {n: 1, get() { return this.n }}; o.get()",
    "function f(a) { return this.k + a } f.call({k: 1}, 2) + f.apply({k: 10}, [5]) + f.bind({k: 100})(1)",
    "var o = {n: 1, f() { return () => this.n }}; o.f()()",
    "function print() { return 'outer' } var o = {print() { return print() }}; o.print()",
    "function r() { return r() } r()",
    "function f() { return typeof arguments } f()",
    "function f() { var arguments; return typeof arguments } f()",
    "function f() { return [delete arguments, typeof arguments].join() } f()",
    "typeof arguments",
    "class A { constructor(x) { this.x = x } get double() { return this.x * 2 } static make(n) { return new A(n) } add(n) { return this.x + n } } var a = A.make(4); [a.x, a.double, a.add(1), a instanceof A, typeof A].join()",
    "class A { m() {} static get z() { return 'sz' } set v(x) { this._v = x * 2 } } var a = new A; a.v = 4; [A.z, a._v, Object.keys(a).join(), Object.getOwnPropertyNames(A.prototype).join()].join()",
    "var C = class Named { who() { return Named.name } }; new C().who()",
    "let X = class { constructor() { X = 5 } }; new X(); X",
    "class Y { constructor() { try { Y = 1 } catch (e) { this.e = e.constructor.name } } }; new Y().e",
    "let Z = class N { constructor() { try { N = 1 } catch (e) { this.e = e.constructor.name } } }; new Z().e",
    "class A { constructor(x) { this.x = x } hi() { return 'A' + this.x } } class B extends A { constructor() { super(7); this.y = 1 } hi() { return 'B' + super.hi() } } var b = new B; [b.x, b.y, b.hi(), b instanceof A, Object.getPrototypeOf(B) === A].join()",
    "class A { constructor() { this.n = 1 } } class B extends A {} new B().n",
    "class A { static s() { return 'static' } } class B extends A { static s() { return super.s() + '!' } } B.s()",
    "class E extends Error { constructor(m) { super(m); this.name = 'E' } } var e = new E('boom'); [e.message, e.name, e instanceof Error, e instanceof E].join()",
    "class L extends Array { sum() { return this.reduce((a, b) => a + b, 0) } } var l = new L(); l.push(1, 2, 3); [l.length, l.sum(), Array.isArray(l)].join()",
    "class P { a = 1; b = this.a + 1; static s = 5; static { P.t = P.s * 2 } } var p = new P; [p.a, p.b, P.s, P.t].join()",
    "class A {} try { A() } catch (e) { e.name + ': ' + e.message }",
    "class A {} class B extends A { constructor() { this.x = 1; super() } } try { new B } catch (e) { e.name }",
    "try { class X extends 5 {} } catch (e) { e.name }",
    "class A { async f() { return await 1 } } new A().f().then(v => console.log('v', v))",
    "var fs = []; function mk(n) { { let k = n * 2; fs.push(() => k + n) } } " <>
      "for (let i = 0; i < 3; i++) mk(i); " <>
      "for (let j = 0; j < 3; j++) fs.push(() => j); " <>
      "for (const x of [7, 8]) fs.push(() => x); " <>
      "fs.map(f => f()).join()",
    "var fs = []; for (let i = 0; i < 3; fs.push(() => i), i++) {} fs.map(f => f()).join()",
    """
    var log = [];
    function res(n) { return { [Symbol.dispose]() { log.push(n) } } }
    function f() { using a = res('a'); using b = res('b'); return 'r' }
    var r = f();
    try { { using c = res('c'); throw new Error('boom') } } catch (e) { log.push(e.message) }
    for (using d of [res('d1'), res('d2')]) log.push('body');
    using_null: { using n = null; }
    r + ':' + log.join()
    """,
    """
    var bad = n => ({ [Symbol.dispose]() { throw n } });
    var r;
    try { { using a = bad(1); using b = bad(2); } } catch (e) {
      r = [e instanceof SuppressedError, e.error, e.suppressed].join();
    }
    r
    """,
    """
    var log = [];
    async function main() {
      {
        await using a = { async [Symbol.asyncDispose]() { await null; log.push('a') } };
        await using b = { [Symbol.dispose]() { log.push('b') } };
        log.push('body');
      }
      var s = new AsyncDisposableStack();
      s.defer(() => log.push('d1'));
      s.adopt(5, v => log.push('adopt' + v));
      await s.disposeAsync();
      var ds = new DisposableStack();
      ds.use({ [Symbol.dispose]() { log.push('u') } });
      ds.dispose();
      log.push(ds.disposed);
    }
    main().then(() => console.log(log.join()));
    """,
    "{ using x; }",
    "{ using x = 1 }",
    "{ using x = {} }",
    # The sources of tests 30 to 36, run so that the facts the resolver attaches never
    # change what the interpreter answers.
    "var cs = []; #{@s30a} f(cs); [new cs[0]().x, new cs[1]().x, new cs[0]().y, new cs[1]().y].join()",
    "var fs = []; #{@s30b} f(fs); [new fs[0]().x, new fs[1]().x].join()",
    "#{@s30c} f(1)",
    "#{@s30d} f().s",
    "#{@s31} f()",
    "#{@s32a} f().join()",
    "#{@s32c} typeof f()",
    "#{@s32d} f()",
    "#{@s33c} typeof f()",
    "#{@s36} try { f([]) } catch (e) { e.name + ': ' + e.message }"
  ]

  # The `early errors` group of js_test.exs: scripts that must or must not parse. Some of the
  # good ones loop forever, so test 26 runs them with a small step budget.
  @early_error_scripts [
    "x: x: ;",
    "break foo;",
    "continue foo;",
    "while (1) { break foo }",
    "a: { continue a }",
    "if (1) break;",
    "function f() { while (1) { function g() { break } } }",
    "return 1",
    "a: b: while (1) { continue a; break b }",
    "a: { break a }",
    "switch (1) { case 1: break }",
    "x: ; x: ;",
    "if (a) b(); else l: switch (1) { case 1: break l }",
    "if (a) l: { break l }",
    "export var a = 1"
  ]
  @early_error_modules [
    "{ export var a = 1 }",
    "export var a = 1",
    "export {x}",
    "var a; export {a}; export {a as a}",
    "export default 1; export {x as default}; var x",
    "function f() {} var f",
    "new.target",
    "export default class {}; export * as ns from 'x'"
  ]

  # The nine programs of bench/js_runtime.exs, wrapped as the bench wraps them.
  @bench_big_body "function big(x) { var t = 0;" <>
                    String.duplicate(" if (x < 0) { t += 1 }", 300) <>
                    " return t + x } var r = 0; for (var i = 0; i < 20000; i++) r += big(i); return r"
  @bench_bodies [
    "function fib(n){ return n < 2 ? n : fib(n-1) + fib(n-2) } return fib(25)",
    "var s = 0; var add = function(a){ return function(b){ return a + b } }; for (var i = 0; i < 60000; i++) { s = add(i)(s) % 1000003 } return s",
    "var o = {a:1,b:2,c:3}; var t = 0; for (let i = 0; i < 60000; i++) { o.a = i; t += o.a + o.b + o.c } return t",
    "var a = []; for (var i = 0; i < 20000; i++) a.push(i); return a.map(x => x * 2).filter(x => x % 3 == 0).reduce((p, c) => p + c, 0)",
    "var s = ''; for (var i = 0; i < 20000; i++) { s += String(i % 10) } return s.length",
    @bench_big_body,
    "class P { constructor(x){ this.x = x } inc(){ this.x++; return this } } var p = new P(0); for (var i = 0; i < 30000; i++) p.inc(); return p.x",
    """
    function mk(d){ if(d==0) return {w:10,h:5,kids:[]}; var k=[]; for(var i=0;i<4;i++) k.push(mk(d-1)); return {w:0,h:0,kids:k}; }
    function lay(n,x,y){ if(n.kids.length==0){ n.x=x;n.y=y; return n.h; } var cy=y; for(var i=0;i<n.kids.length;i++){ cy+=lay(n.kids[i],x+2,cy) } n.x=x;n.y=y;n.h=cy-y; return n.h }
    var t=mk(6); var s=0; for(var r=0;r<3;r++) s+=lay(t,0,0); return s
    """,
    """
    var els=[]; for(var i=0;i<3000;i++){ els.push({tag:'div',attrs:{id:'e'+i,class:'c'+(i%7)},children:[],parent:null}) }
    for(var i=1;i<els.length;i++){ var p=els[(i-1)>>1]; p.children.push(els[i]); els[i].parent=p }
    var cnt=0; function q(n,c){ if(n.attrs['class']===c) cnt++; for(var i=0;i<n.children.length;i++) q(n.children[i],c) }
    for(var k=0;k<7;k++) q(els[0],'c'+k); return cnt
    """
  ]

  @levels [:info, 1, 2, 3, 4]
  # The levels test 26 runs the js_test.exs groups at: `:info` rewrites nothing, 1 runs
  # the leaf functions on frames (step 2b). Both must give the result of `:off`.
  @eval_levels [:info, 1]

  # ── helpers of design section 6 ─────────────────────────────

  # Parses `src` with the resolver at level 4 unless `opts` names a level.
  defp resolve(src, opts \\ []) do
    assert {:ok, tree} = Parser.parse(src, Keyword.put_new(opts, :resolve, 4)), src
    tree
  end

  # Parses `src` the way every caller does today: without the resolver (also when
  # `JS_RESOLVE` sets a level for the whole suite).
  defp off(src, opts \\ []) do
    assert {:ok, tree} = Parser.parse(src, Keyword.put_new(opts, :resolve, :off)), src
    tree
  end

  # The first function node named `name`, in source order. A method's node carries
  # `{:method, name}`; a declaration's node carries the name itself.
  defp fun(tree, name) do
    case find(tree, fn
           {:fn, ^name, _, _, _, _} -> true
           {:fn, {:method, ^name}, _, _, _, _} -> true
           _ -> false
         end) do
      nil -> flunk("no function #{inspect(name)} in #{inspect(tree)}")
      node -> node
    end
  end

  # The `nth` arrow function of `tree` in source order.
  defp arrow(tree, nth \\ 0) do
    tree
    |> collect(&match?({:fn, _, _, _, mode, _} when mode in [:arrow, :arrow_expr], &1))
    |> Enum.at(nth) || flunk("no arrow #{nth} in #{inspect(tree)}")
  end

  # Every function node of `tree` in source order.
  defp fns(tree), do: collect(tree, &match?({:fn, _, _, _, _, _}, &1))

  defp info(node) do
    assert %Info{} = info = Resolve.info(node), "no Info on #{inspect(node)}"
    info
  end

  defp body({:fn, _, _, body, _, _}), do: body
  defp params({:fn, _, params, _, _, _}), do: params

  # The slots of a function as `{index, name, kind}`, by index. Hidden slots have atom names.
  defp slots(%Info{slots: slots, kinds: kinds}) do
    slots
    |> Enum.map(fn {name, i} -> {i, name, :erlang.element(i, kinds)} end)
    |> Enum.sort_by(&elem(&1, 0))
  end

  defp kind(%Info{slots: slots, kinds: kinds}, name),
    do: :erlang.element(Map.fetch!(slots, name), kinds)

  # Every rewritten name node of `term`, in source order, nested functions included.
  defp forms(term), do: collect(term, &form?/1)

  defp form?({k, _, _, _}) when k in [:slot, :cslot, :fname], do: true
  defp form?({:mslot, _, _, _, _}), do: true
  defp form?({:aslot, _, _}), do: true
  defp form?({:mref, _, _}), do: true
  defp form?({:gref, _}), do: true
  defp form?({:this, _, _}), do: true
  defp form?({:in_tdz, _, _}), do: true
  defp form?(_), do: false

  # The statements of a function that carry a scope position, in source order, without the
  # statements of nested functions and classes.
  defp scope_stmts(node), do: collect_local(node, &scoped_stmt?/1)

  defp scoped_stmt?({:block, _, _}), do: true
  defp scoped_stmt?({:for, _, _, _, _, _}), do: true
  defp scoped_stmt?({k, _, _, _, _, _}) when k in [:forin, :forof, :forawait], do: true
  defp scoped_stmt?({:switch, _, _, _}), do: true
  defp scoped_stmt?({:try, _, _, _, _, _}), do: true
  defp scoped_stmt?(_), do: false

  # The `%Scope{}` (or `nil`) of the `nth` scope-making statement of a function.
  defp scope_of(node, nth) do
    case Enum.at(scope_stmts(node), nth) do
      nil -> flunk("no scoped statement #{nth} in #{inspect(node)}")
      stmt -> elem(stmt, tuple_size(stmt) - 1)
    end
  end

  # The tail-marked returns of a function, without those of nested functions.
  defp tails(node), do: collect_local(node, &match?({:return, _, :tail}, &1))

  # The `{:aw, _}` wrappers of a term.
  defp aws(term), do: collect(term, &match?({:aw, _}, &1))

  defp fn_name({:fn, name, _, _, _, _}), do: name
  defp fn_name({:fundecl, name, _}), do: name
  defp fn_name({:gen, f}), do: fn_name(f)
  defp fn_name({:async, f}), do: fn_name(f)

  defp unwrap({:gen, f}), do: unwrap(f)
  defp unwrap({:async, f}), do: unwrap(f)
  defp unwrap({:fundecl, _, f}), do: unwrap(f)
  defp unwrap(f), do: f

  defp find(term, pred), do: term |> collect(pred) |> List.first()

  # Every node of `term` that satisfies `pred`, in source order. The walk does not enter the
  # resolver's structs, so a function node kept in a hoist list is not seen twice.
  defp collect(term, pred), do: term |> walk(pred, [], true) |> Enum.reverse()

  # Like `collect/2`, but the walk starts inside `node` and does not enter nested functions
  # or classes, whose statements belong to another scope chain.
  defp collect_local(node, pred) do
    node
    |> Tuple.to_list()
    |> Enum.reduce([], &walk(&1, pred, &2, false))
    |> Enum.reverse()
  end

  defp walk(term, pred, acc, enter?) do
    acc = if pred.(term), do: [term | acc], else: acc

    cond do
      is_struct(term) -> acc
      not enter? and match?({:fn, _, _, _, _, _}, term) -> acc
      not enter? and match?({:class, _, _, _, _}, term) -> acc
      is_tuple(term) -> Enum.reduce(Tuple.to_list(term), acc, &walk(&1, pred, &2, enter?))
      is_list(term) -> Enum.reduce(term, acc, &walk(&1, pred, &2, enter?))
      is_map(term) -> Enum.reduce(Map.values(term), acc, &walk(&1, pred, &2, enter?))
      true -> acc
    end
  end

  # True when the term carries anything the resolver adds: a struct or one of its node forms.
  defp mark?(%Info{}), do: true
  defp mark?(%Scope{}), do: true

  defp mark?(t) when is_tuple(t) and tuple_size(t) > 0 and is_atom(elem(t, 0)),
    do: elem(t, 0) in [:slot, :cslot, :fname, :mslot, :aslot, :mref, :gref, :in_tdz, :aw]

  defp mark?(_), do: false

  defp marks(term), do: collect(term, &mark?/1)

  # True when `a` and `b` are the same term except for the sixth element of function nodes,
  # where one side may carry an `Info` with the other side's source text.
  defp same_but_src?({:fn, n, p, b, m, x}, {:fn, n, p2, b2, m, y}),
    do: src_equal?(x, y) and same_but_src?(p, p2) and same_but_src?(b, b2)

  defp same_but_src?(a, b) when is_tuple(a) and is_tuple(b) do
    tuple_size(a) == tuple_size(b) and same_but_src?(Tuple.to_list(a), Tuple.to_list(b))
  end

  defp same_but_src?(a, b) when is_list(a) and is_list(b) do
    length(a) == length(b) and Enum.all?(Enum.zip(a, b), fn {x, y} -> same_but_src?(x, y) end)
  end

  defp same_but_src?(a, b)
       when is_map(a) and is_map(b) and not is_struct(a) and not is_struct(b) do
    Map.keys(a) == Map.keys(b) and same_but_src?(Map.values(a), Map.values(b))
  end

  defp same_but_src?(a, b), do: a == b

  defp src_equal?(%Info{src: s}, s2), do: s == s2
  defp src_equal?(s, %Info{src: s2}), do: s == s2
  defp src_equal?(a, b), do: a == b

  # The program's own strictness, which the parser takes from the first statement.
  defp directive?({:program, [{:expr, {:str, "use strict"}} | _]}), do: true
  defp directive?(_), do: false

  defp top_of(opts) do
    cond do
      Keyword.get(opts, :module, false) -> :module
      Keyword.get(opts, :eval, false) and Keyword.get(opts, :indirect, false) -> :global_eval
      Keyword.get(opts, :eval, false) -> :eval
      true -> :script
    end
  end

  # Runs the pass on a flag-off tree the way the parser's hook does.
  defp program(tree, level, opts) do
    Resolve.program(tree,
      level: level,
      top: top_of(opts),
      strict: directive?(tree) or opts[:module] == true
    )
  end

  # ── the corpus ──────────────────────────────────────────────

  # `{label, src, opts}` triples: every test262 test and harness file, the nine bench
  # programs and the JavaScript preludes of the engine. A test262 file with the `module`
  # flag carries `module: true`, so that the module top, its imports and the top-level
  # await rules get corpus coverage too (design 6, test 27: every file under the root).
  defp corpus do
    root = Path.expand(".test262")

    files =
      Path.wildcard(Path.join(root, "test/**/*.js")) ++
        Path.wildcard(Path.join(root, "harness/*.js"))

    tests =
      Enum.map(files, fn path ->
        src = File.read!(path)
        meta = Browser.JS.Test262.parse_meta(src)
        module? = "module" in List.wrap(meta["flags"])
        {Path.relative_to(path, root), src, if(module?, do: [module: true], else: [])}
      end)

    benches =
      Enum.with_index(@bench_bodies, fn body, i ->
        {"bench #{i}", "(function(){ function f(){ #{body} } return f() })()", []}
      end)

    tests ++ benches ++ Enum.map(prelude_sources(), fn {label, src} -> {label, src, []} end)
  end

  # The JavaScript sources the engine parses for its own built-ins: the files under priv/js,
  # the WebAssembly source and every string literal of prelude.ex and webapi.ex that is a
  # program or a function expression.
  defp prelude_sources do
    files =
      for name <- ~w(editing.js indexeddb.js websocket.js worker.js worker_scope.js),
          path = Path.expand("priv/js/" <> name),
          File.exists?(path),
          do: {name, File.read!(path)}

    literals =
      for file <- ~w(lib/browser/js/prelude.ex lib/browser/js/webapi.ex),
          {s, i} <- Enum.with_index(string_literals(file)),
          src = parsable(s),
          do: {"#{file} literal #{i}", src}

    files ++ [{"webassembly", "(" <> Browser.JS.WebAssemblySource.source() <> ")"}] ++ literals
  end

  # The source itself when it parses, else the source wrapped as an expression (a prelude is
  # often a bare function expression), else `nil`.
  defp parsable(s) do
    cond do
      match?({:ok, _}, Parser.parse(s)) -> s
      match?({:ok, _}, Parser.parse("(" <> s <> ")")) -> "(" <> s <> ")"
      true -> nil
    end
  end

  # The string literals of an Elixir file that are long enough to be JavaScript, including
  # the content of `~S` sigils.
  defp string_literals(file) do
    {_, acc} =
      file
      |> File.read!()
      |> Code.string_to_quoted!()
      |> Macro.prewalk([], fn
        {:sigil_S, _, [{:<<>>, _, [s]}, _]} = node, acc when is_binary(s) -> {node, [s | acc]}
        s, acc when is_binary(s) and byte_size(s) >= 40 -> {s, [s | acc]}
        node, acc -> {node, acc}
      end)

    acc |> Enum.reverse() |> Enum.uniq()
  end

  # ── the oracle of test 28 ───────────────────────────────────

  # Compares the Info of one function node with the interpreter's own hoisting helpers and
  # returns the disagreements. Three differences are allowed: `for await (var ...)` names are
  # in the Info only, the lexical names in the rest of a `using` (and the `using` name) are
  # in the Info only, and a class declaration may carry the kind `:class` where the oracle,
  # which sees the parser's `{:var, :let, ...}` form, says `:let`.
  defp oracle_failures({:fn, name, params, body, mode, %Info{} = i} = node) do
    plain? = Interp.plain_params?(params)
    exprs? = Interp.param_exprs?(params)
    expected_params = if plain?, do: :plain, else: if(exprs?, do: :exprs, else: :patterns)
    pnames = Enum.flat_map(params, &Interp.pattern_names(&1, []))
    stmts = if is_list(body), do: body, else: []
    vars = stmts |> Interp.var_names([]) |> Enum.uniq()
    funs = Interp.fundecls(stmts)
    fnames = Enum.map(funs, &elem(&1, 0))
    lex = Enum.flat_map(stmts, &Interp.lexical_names/1)
    extra_lex = using_lexicals(stmts)
    await_vars = forawait_vars(stmts)
    strict? = match?([{:expr, {:str, "use strict"}} | _], stmts)
    # A parameter named `arguments` defeats the object too: the run time's `call_frame` tests
    # the bound names (interp.ex), not only the function declarations.
    args_var? =
      "arguments" in vars and "arguments" not in fnames and "arguments" not in pnames

    named = for {n, _} <- i.slots, is_binary(n), do: n

    checks =
      [
        {i.params == expected_params, "params #{inspect(i.params)}, oracle #{expected_params}"},
        # `nparams` is the positional count without the rest parameter (deviation 6).
        {i.nparams == length(params) - if(i.rest?, do: 1, else: 0),
         "nparams #{i.nparams}, oracle #{length(params) - if(i.rest?, do: 1, else: 0)}"},
        {mode == :arrow_expr or i.strict == strict?, "strict #{i.strict}, oracle #{strict?}"},
        {i.args_var == args_var?, "args_var #{i.args_var}, oracle #{args_var?}"},
        {tuple_size(i.kinds) == i.size,
         "kinds has #{tuple_size(i.kinds)} entries, size #{i.size}"},
        {Enum.all?(vars, &(Map.has_key?(i.slots, &1) and kind(i, &1) in [:param, :var, :fun])),
         "a var name is missing or has the wrong kind: #{inspect(vars)}"},
        {Enum.all?(lex, &(Map.has_key?(i.slots, &1) and kind(i, &1) in [:let, :const, :class])),
         "a lexical name is missing or has the wrong kind: #{inspect(lex)}"},
        {Enum.map(i.hoist, &elem(&1, 0)) == Enum.map(fnames, &Map.get(i.slots, &1)),
         "hoist slots #{inspect(Enum.map(i.hoist, &elem(&1, 0)))}, oracle names #{inspect(fnames)}"},
        {Enum.map(i.hoist, &Resolve.strip(unwrap(elem(&1, 1)))) ==
           Enum.map(funs, &Resolve.strip(unwrap(elem(&1, 1)))),
         "hoist nodes differ from fundecls/1"}
      ] ++
        for n <- named do
          k = kind(i, n)

          ok? =
            case k do
              :param -> n in pnames
              :var -> n in vars or n in await_vars
              :fun -> n in fnames
              :self -> n == name and mode == false
              :using -> n in extra_lex
              k when k in [:let, :const, :class] -> n in lex or n in extra_lex
              # The arguments object is the one hidden slot under a name (design 3.1, group 2).
              :hidden -> n == "arguments"
              _ -> false
            end

          {ok?, "slot #{n} of kind #{k} is not in the oracle's names"}
        end ++
        template_checks(i)

    for {false, msg} <- checks, do: "#{inspect(name)} (#{short(node)}): #{msg}"
  end

  # The template holds `:undefined` for var and function slots and `:tdz` for the lexical
  # ones; it starts after the parameter and hidden slots and never covers a parameter slot,
  # with or without initializers (design 3.1, deviation 2).
  defp template_checks(%Info{} = i) do
    first = 6 + Enum.count(Tuple.to_list(i.kinds), &(&1 == :param)) + length(i.hidden)
    by_index = Map.new(i.slots, fn {n, idx} -> {idx, n} end)

    [
      {length(i.template) == i.size - first + 1,
       "template has #{length(i.template)} values for #{i.size - first + 1} slots"}
    ] ++
      for {v, k} <- Enum.with_index(i.template), Map.has_key?(by_index, first + k) do
        kind = :erlang.element(first + k, i.kinds)
        want = if kind in [:var, :fun], do: :undefined, else: :tdz
        {v == want, "template value #{inspect(v)} for #{by_index[first + k]} (#{kind})"}
      end
  end

  # The `using` names of a body and the lexical names in their rests, which
  # `Interp.lexical_names/1` does not enter.
  defp using_lexicals(stmts) do
    Enum.flat_map(stmts, fn
      {:using, _, name, _, rest} ->
        [name | Enum.flat_map(rest, &Interp.lexical_names/1) ++ using_lexicals(rest)]

      _ ->
        []
    end)
  end

  # The `var` names of `for await` heads, which `Interp.var_names/2` does not collect.
  defp forawait_vars(stmts) do
    stmts
    |> Enum.flat_map(
      &collect_local({:body, &1}, fn t -> match?({:forawait, :var, _, _, _}, t) end)
    )
    |> Enum.flat_map(fn {:forawait, :var, pat, _, _} -> Interp.pattern_names(pat, []) end)
  end

  defp short(node) do
    {:fn, _, _, _, _, %Info{src: src}} = node
    src |> to_string() |> String.slice(0, 60)
  end

  # ── tests ───────────────────────────────────────────────────

  test "1. slots of a plain function" do
    f = fun(resolve(@s1), "f")
    i = info(f)

    assert slots(i) == [
             {6, "a", :param},
             {7, "b", :param},
             {8, "c", :var},
             {9, "g", :fun},
             {10, "d", :let},
             {11, "e", :const}
           ]

    assert i.template == [:undefined, :undefined, :tdz, :tdz]
    assert [{9, g}] = i.hoist
    assert fn_name(g) == "g"
    assert i.nparams == 2
    assert i.params == :plain
    assert i.level == 2
    assert i.rewritten
    assert i.makes_closures
    assert i.hidden == []
    assert i.kind == :fn
    assert i.name == "f"
    assert i.src == @s1
    # Six slots after the five header positions (design 3.1).
    assert i.size == 11

    assert i.kinds ==
             {:parent, :rec, :caller, :call_pos, :root, :param, :param, :var, :fun, :let, :const}

    # Level 2 frames are freed by the closure counter (design 3.2).
    assert i.free == :counter
  end

  test "2. duplicate parameter names and a var that shares a parameter's slot" do
    f = fun(resolve(@s2a), "f")
    i = info(f)
    assert i.slots == %{"a" => 7}
    assert i.nparams == 2
    assert i.kinds == {:parent, :rec, :caller, :call_pos, :root, :param, :param}
    assert i.size == 7
    assert forms(body(f)) == [{:slot, 0, 7, "a"}]

    f = fun(resolve(@s2b), "f")
    i = info(f)
    assert slots(i) == [{6, "a", :param}]
    assert [{6, node}] = i.hoist
    assert fn_name(node) == "a"
    assert i.size == 6
    assert i.template == []
  end

  test "3. two declarations of one function hoist in order into one slot" do
    f = fun(resolve(@s3), "f")
    i = info(f)
    assert [{6, g1}, {6, g2}] = i.hoist
    assert {:fn, "g", [], [], false, _} = Resolve.strip(unwrap(g1))
    assert {:fn, "g", [], [{:return, {:num, 2.0}}], false, _} = Resolve.strip(unwrap(g2))
    assert slots(i) == [{6, "g", :fun}]
    assert forms(body(f)) == [{:slot, 0, 6, "g"}]
  end

  test "4. a shadowing let in a block gets its own frameless slot" do
    f = fun(resolve(@s4a), "f")
    i = info(f)
    assert i.slots == %{"x" => 6}
    assert slots(i) == [{6, "x", :let}]
    # The block's `x` is slot 7 of the function frame, after the body's lexical names
    # (design 3.1, group 5), so the frame has two slots.
    assert i.size == 7
    assert i.template == [:tdz, :tdz]
    assert i.level == 1
    assert i.free == :always
    assert forms(f) == [{:slot, 0, 6, "x"}, {:slot, 0, 7, "x"}, {:slot, 0, 7, "x"}]

    assert {:block, [_, {:return, {:slot, 0, 7, "x"}, :plain}], %Scope{} = sc} =
             f |> scope_stmts() |> List.first()

    assert %Scope{kind: :block, frame: false, tdz: [7], slots: %{"x" => 7}, kinds: %{7 => :let}} =
             sc

    f = fun(resolve(@s4b), "f")
    assert {:block, [{:return, {:num, 1.0}, :plain}], nil} = f |> scope_stmts() |> List.first()
    assert scope_of(f, 0) == nil
  end

  test "5. a block whose name an arrow captures gets a frame" do
    f = fun(resolve(@s5a), "f")
    i = info(f)

    assert %Scope{kind: :block, frame: true, slots: %{"x" => 6}, kinds: %{6 => :let}} =
             scope_of(f, 0)

    # A framed block starts its slots at 6, like a function frame (design 3.3).
    assert %Scope{size: 6, template: [:tdz]} = scope_of(f, 0)
    assert forms(arrow(f)) == [{:slot, 1, 6, "x"}]
    assert i.slots == %{"fs" => 6}
    refute Map.has_key?(i.slots, "x")
    assert i.level == 2
    assert i.makes_closures
    # The block reads `fs` one hop up (block frame to function frame); the design's
    # `{:slot, 2, 6, "fs"}` needs the read inside the arrow, which the next source has.
    assert forms(f) == [
             {:slot, 0, 6, "fs"},
             {:slot, 0, 6, "x"},
             {:slot, 1, 6, "fs"},
             {:slot, 1, 6, "x"}
           ]

    f = fun(resolve(@s5b), "f")
    assert forms(arrow(f)) == [{:slot, 2, 6, "fs"}, {:slot, 1, 6, "x"}]
    # The arrow captures slot 6 of `f` (design 3.2, `captured`).
    assert info(f).captured == MapSet.new([6])
  end

  test "6. a for-let head gets a per-iteration frame only when a closure captures it" do
    f = fun(resolve(@s6a), "f")

    assert %Scope{
             kind: :loop,
             frame: true,
             per_iter: true,
             slots: %{"i" => 6},
             kinds: %{6 => :let}
           } =
             scope_of(f, 0)

    assert forms(arrow(f)) == [{:slot, 1, 6, "i"}]
    # The loop test runs in the loop frame, one hop below the parameters (design 3.4).
    assert {:slot, 1, 6, "n"} in forms(f)
    assert info(f).level == 2

    f = fun(resolve(@s6b), "f")
    # Parameters take 6 and 7, so the frameless head name is slot 8 (design 3.1, group 5).
    assert %Scope{kind: :loop, frame: false, per_iter: false, slots: %{"i" => 8}, tdz: [8]} =
             scope_of(f, 0)

    refute Map.has_key?(info(f).slots, "i")
    assert {:slot, 0, 8, "i"} in forms(f)
    assert info(f).size == 8
    assert info(f).level == 1

    f = fun(resolve(@s6c), "f")
    assert %Scope{kind: :loop, frame: false, per_iter: false} = scope_of(f, 0)
  end

  test "7. for-in, for-of and for-await heads" do
    f = fun(resolve(@s7a), "f")

    assert [
             {:forin, :const, {:slot, 0, 7, "k"}, {:slot, 0, 6, "o"}, {:expr, {:slot, 0, 7, "k"}},
              %Scope{
                kind: :each,
                frame: false,
                slots: %{"k" => 7},
                kinds: %{7 => :const},
                tdz: [7]
              }}
           ] = body(f)

    f = fun(resolve(@s7b), "f")
    assert %Scope{kind: :each, frame: false, slots: %{"a" => 7, "b" => 8}} = scope_of(f, 0)

    # The parameter is a binding target too (design 3.4), so it is the first form.
    assert forms(f) == [
             {:slot, 0, 6, "xs"},
             {:slot, 0, 7, "a"},
             {:slot, 0, 8, "b"},
             {:slot, 0, 6, "xs"},
             {:slot, 0, 7, "a"},
             {:slot, 0, 8, "b"}
           ]

    refute Enum.any?(forms(f), &match?({:in_tdz, _, _}, &1))

    f = fun(resolve(@s7c), "f")
    assert info(f).async?
    assert info(f).level == 4

    assert [
             {:aw,
              {:forawait, :const, {:slot, 0, 7, "x"}, {:slot, 0, 6, "y"},
               {:expr, {:slot, 0, 7, "x"}}, %Scope{kind: :each, slots: %{"x" => 7}}}}
           ] = body(f)

    f = fun(resolve(@s7d), "f")
    assert slots(info(f)) == [{6, "y", :param}, {7, "x", :var}]
    assert info(f).template == [:undefined]
    assert [{:aw, {:forawait, :var, {:slot, 0, 7, "x"}, {:slot, 0, 6, "y"}, _, nil}}] = body(f)

    f = fun(resolve(@s7e), "f")
    assert %Scope{kind: :each, frame: true, slots: %{"x" => 6}} = scope_of(f, 0)
    assert forms(arrow(f)) == [{:slot, 1, 6, "x"}]
  end

  test "8. switch and catch scopes" do
    f = fun(resolve(@s8a), "f")
    assert [sc] = Enum.map(scope_stmts(f), &elem(&1, tuple_size(&1) - 1))
    assert %Scope{kind: :switch, frame: false, slots: %{"a" => 7, "g" => 8}} = sc
    assert %Scope{kinds: %{7 => :let, 8 => :fun}, hoist: [{8, g}]} = sc
    assert fn_name(g) == "g"
    # Only the `let` starts in its TDZ; the function slot 8 is hoisted (design 3.4).
    assert sc.tdz == [7]
    assert [{:switch, {:slot, 0, 6, "v"}, [{{:num, 1.0}, _}], %Scope{}}] = body(f)

    f = fun(resolve(@s8b), "f")
    assert %Scope{kind: :switch, frame: true, slots: %{"a" => 6, "g" => 7}} = scope_of(f, 0)
    # The discriminant resolves outside the switch frame, the case test inside it.
    assert [{:switch, {:slot, 0, 6, "v"}, [{{:slot, 1, 6, "v"}, _}], %Scope{}}] = body(f)
    assert forms(body(fun(f, "g"))) == [{:slot, 1, 6, "a"}]

    f = fun(resolve(@s8c), "f")

    assert [
             {:try, {:block, [], nil},
              {:objpat, [{{:str, "a"}, {:slot, 0, 6, "a"}}, {{:str, "b"}, {:slot, 0, 7, "b"}}],
               nil},
              {:block, [{:expr, {:binary, "+", {:slot, 0, 6, "a"}, {:slot, 0, 7, "b"}}}], nil},
              nil, %Scope{kind: :catch, frame: false, slots: %{"a" => 6, "b" => 7}} = sc}
           ] = body(f)

    assert sc.kinds == %{6 => :let, 7 => :let}
    assert Enum.sort(sc.tdz) == [6, 7]

    f = fun(resolve(@s8d), "f")
    assert %Scope{kind: :catch, frame: true, slots: %{"e" => 6}} = scope_of(f, 0)
    assert forms(arrow(f)) == [{:slot, 1, 6, "e"}]
    assert {:slot, 1, 6, "fs"} in forms(f)

    # Annex B.3.4: a `var` of the catch parameter's name writes the catch binding (slot 7)
    # and the function's own `e` (slot 6) stays undefined.
    f = fun(resolve("function f() { try { throw 1 } catch (e) { var e = 2 } return e }"), "f")
    assert slots(info(f)) == [{6, "e", :var}] and info(f).template == [:undefined, :tdz]

    assert [
             {:try, {:block, [throw: {:num, 1.0}], nil}, {:slot, 0, 7, "e"},
              {:block, [{:var, :var, [{{:slot, 0, 7, "e"}, {:num, 2.0}}]}], nil}, nil,
              %Scope{kind: :catch, frame: false, slots: %{"e" => 7}, tdz: [7]}},
             {:return, {:slot, 0, 6, "e"}, :plain}
           ] = body(f)

    # A catch parameter shadows a parameter of the same name.
    f = fun(resolve("function f(e) { try {} catch (e) { e } }"), "f")

    assert [
             {:try, _, {:slot, 0, 7, "e"}, {:block, [expr: {:slot, 0, 7, "e"}], nil}, nil,
              %Scope{slots: %{"e" => 7}}}
           ] = body(f)
  end

  test "9. a using declaration is a const with a TDZ for what follows it" do
    f = fun(resolve(@s9), "f")
    i = info(f)
    assert slots(i) == [{6, "r", :using}, {7, "y", :let}]
    assert i.template == [:tdz, :tdz]
    assert i.level == 1

    # The `using` name is a binding site like a declaration pattern, so it takes the slot
    # form too (design 3.4; the design does not name the `{:using}` node's own element).
    assert [{:using, :using, {:slot, 0, 6, "r"}, {:gref, "x"}, rest}] = body(f)

    assert [
             {:var, :let, [{{:slot, 0, 7, "y"}, {:num, 1.0}}]},
             {:expr, {:assign, "=", {:cslot, 0, 6, "r"}, {:num, 2.0}}},
             {:return, {:slot, 0, 7, "y"}, :plain}
           ] = rest
  end

  test "10. the self name of a named function expression" do
    g = fun(resolve(@s10a), "g")
    i = info(g)
    assert i.self == 6
    assert i.hidden == [:self]
    assert slots(i) == [{6, "g", :self}]
    assert forms(body(g)) == [{:fname, 0, 6, "g"}, {:slot, 0, 6, "g"}]

    g = fun(resolve(@s10b), "g")
    assert info(g).self == 6
    assert info(g).strict
    assert forms(body(g)) == [{:cslot, 0, 6, "g"}, {:slot, 0, 6, "g"}]

    g = fun(resolve(@s10c), "g")
    assert info(g).self == nil
    assert slots(info(g)) == [{6, "g", :param}]

    g = fun(resolve(@s10d), "g")
    assert info(g).self == nil
    assert info(g).hidden == []
    assert forms(body(g)) == [{:gref, "g"}]

    # An arrow captures the self slot like any other slot of the frame (design 3.2).
    g = fun(resolve("(function g() { return () => g })"), "g")
    assert info(g).self == 6
    assert forms(arrow(g)) == [{:slot, 1, 6, "g"}]
    assert info(g).captured == MapSet.new([6])

    # The self name is omitted when the body declares the name (design 4.5): the `var`
    # takes slot 6.
    g = fun(resolve("(function g() { var g; return g })"), "g")
    assert info(g).self == nil and info(g).hidden == []
    assert slots(info(g)) == [{6, "g", :var}]
    assert forms(body(g)) == [{:slot, 0, 6, "g"}, {:slot, 0, 6, "g"}]

    # A generator expression keeps its self slot.
    assert info(fun(resolve("(function* g() { g })"), "g")).self == 6
  end

  test "11. const writes, deletes of slots and of free names" do
    f = fun(resolve(@s11), "f")

    assert body(f) == [
             {:var, :const, [{{:slot, 0, 6, "c"}, {:num, 1.0}}]},
             {:expr, {:assign, "=", {:cslot, 0, 6, "c"}, {:num, 2.0}}},
             # Design 3.4 asks for `{:lit, false}` here, but a literal loses the name and
             # breaks the round trip of test 27 and decision 0.5; the node keeps the slot
             # form, and the evaluator answers `false` from it without a lookup.
             {:expr, {:unary, "delete", {:slot, 0, 6, "c"}}},
             {:expr, {:unary, "delete", {:gref, "y"}}}
           ]

    # Every write to a const takes `{:cslot}`, whatever its syntax (design 3.4): an update
    # and a compound assignment go through the target path, a pattern through the
    # destructuring path. `typeof` reads, so it keeps the slot form.
    f = fun(resolve("function f() { const c = 1; c++; c += 1; typeof c; [c] = [2] }"), "f")

    assert body(f) == [
             {:var, :const, [{{:slot, 0, 6, "c"}, {:num, 1.0}}]},
             {:expr, {:update, "++", false, {:cslot, 0, 6, "c"}}},
             {:expr, {:assign, "+=", {:cslot, 0, 6, "c"}, {:num, 1.0}}},
             {:expr, {:unary, "typeof", {:slot, 0, 6, "c"}}},
             {:expr, {:destructure, {:arrpat, [{:cslot, 0, 6, "c"}]}, {:array, [num: 2.0]}}}
           ]
  end

  test "12. arguments: mapped parameters, the hidden slots and the owner of an arrow" do
    f = fun(resolve(@s12a), "f")
    i = info(f)
    assert i.level == 3
    assert i.uses_arguments
    assert i.argmap == %{"a" => 0}
    assert i.hidden == [:args, :arguments]
    # The hidden slots follow the parameters in `hidden` order (design 3.1, group 2): the
    # raw argument list at 7, then the object, which `arguments` reads by name at 8.
    assert i.slots == %{"a" => 6, "arguments" => 8, args: 7}
    assert i.size == 8
    assert i.kinds == {:parent, :rec, :caller, :call_pos, :root, :param, :hidden, :hidden}

    # The hidden slot of the object is read through `{:aslot}` (step 2d, rule R3).
    assert forms(body(f)) == [
             {:aslot, 0, 8},
             {:mslot, 0, 6, "a", 0},
             {:slot, 0, 6, "a"}
           ]

    # A `var` of a mapped parameter writes through the mapping, so `arguments[0]` follows.
    f = fun(resolve("function f(a) { var a = 1; return arguments[0] }"), "f")

    assert body(f) == [
             {:var, :var, [{{:mslot, 0, 6, "a", 0}, {:num, 1.0}}]},
             {:return, {:member, {:aslot, 0, 8}, {:num, 0.0}, false}, :plain}
           ]

    f = fun(resolve(@s12b), "f")
    assert info(f).strict
    assert info(f).uses_arguments
    assert info(f).argmap == nil
    assert {:slot, 0, 6, "a"} in forms(body(f))

    f = fun(resolve(@s12c), "f")
    assert info(f).params == :exprs
    assert info(f).argmap == nil
    assert info(f).uses_arguments

    f = fun(resolve(@s12d), "f")
    i = info(f)
    assert i.uses_arguments
    assert i.args_var
    # Without parameter initializers the `var` itself holds the object (deviation 8): the
    # raw list is the only hidden slot and the `var` is an ordinary slot after it.
    assert i.hidden == [:args]
    assert i.slots == %{"arguments" => 7, args: 6}
    assert i.kinds == {:parent, :rec, :caller, :call_pos, :root, :hidden, :var}
    assert i.template == [:undefined]
    assert forms(body(f)) == [{:slot, 0, 7, "arguments"}, {:slot, 0, 7, "arguments"}]

    f = fun(resolve(@s12e), "f")
    refute info(f).uses_arguments
    refute info(f).args_var
    assert info(f).hidden == []

    f = fun(resolve(@s12f), "f")
    refute info(f).uses_arguments
    assert slots(info(f)) == [{6, "arguments", :param}]

    # A parameter of that name defeats `args_var` as well: the `var` shares its slot (the
    # run time's `call_frame` tests the bound names, not only the functions).
    f = fun(resolve("function f(arguments) { var arguments; return arguments }"), "f")
    refute info(f).args_var
    assert slots(info(f)) == [{6, "arguments", :param}]

    f = fun(resolve(@s12g), "f")
    i = info(f)
    assert i.uses_arguments
    assert i.level == 3
    assert i.slots == %{"a" => 6, "arguments" => 8, args: 7}
    assert forms(arrow(f)) == [{:aslot, 1, 8}]
    assert i.captured == MapSet.new([8])
  end

  test "13. this: a method's hidden slot, an arrow inside it, a field initializer" do
    m = fun(resolve(@s13a), "m")
    i = info(m)
    assert i.kind == :method
    assert i.level == 1
    assert i.uses_this
    assert i.hidden == [:this]
    assert i.slots[:this] == 6
    assert forms(body(m)) == [{:this, 0, 6}]

    m = fun(resolve(@s13b), "m")
    assert info(m).uses_this
    assert info(m).level == 2
    assert forms(arrow(m)) == [{:this, 1, 6}]

    tree = resolve(@s13c)
    assert {:fn, nil, [], {:this}, :arrow_expr, %Info{}} = arrow(tree)
  end

  test "14. a derived constructor and the default constructors" do
    tree = resolve(@s14)
    c = fun(tree, "constructor")
    i = info(c)
    assert i.kind == :derived_ctor
    assert i.level == 3
    assert i.uses_new_target
    assert i.uses_super
    # Hidden slots are added as used (design 4.7): `super()` reads `:ctor_fn`, `:new_target`
    # and `:this` (classes.ex `super_call`), never `:home`, which only `super.x` reads.
    assert i.hidden == [:this, :new_target, :ctor_fn]
    # `hidden` lists the slots in slot order, which 2d's frame builder follows.
    assert i.slots == %{this: 6, new_target: 7, ctor_fn: 8}
    assert i.size == 8
    assert i.kinds == {:parent, :rec, :caller, :call_pos, :root, :hidden, :hidden, :hidden}

    assert [
             _,
             {:expr, {:call, {:super}, [], false}},
             {:return, {:slot, 0, 7, :new_target}, :plain}
           ] =
             body(c)

    # `super.m()` adds `:home`, which comes before `:ctor_fn` in the slot order.
    c = fun(resolve("class B extends A { constructor() { super(); super.m() } }"), "constructor")
    assert info(c).hidden == [:this, :new_target, :home, :ctor_fn]
    assert info(c).slots == %{this: 6, new_target: 7, home: 8, ctor_fn: 9}

    # An arrow that calls `super()` captures every hidden slot the call reads or writes:
    # `:this` too, since `super()` binds it (test 34), so the review's `[7, 8]` is `[6, 7, 8]`.
    c =
      fun(
        resolve(
          "class B extends A { constructor() { const f = () => super(); f(); return () => new.target } }"
        ),
        "constructor"
      )

    assert info(c).slots == %{"f" => 9, this: 6, new_target: 7, ctor_fn: 8}
    assert info(c).captured == MapSet.new([6, 7, 8])
    assert forms(arrow(c, 1)) == [{:slot, 1, 7, :new_target}]

    # The derived default constructor takes its rest parameter at 6 and the three hidden
    # slots after it; the base one has only `:this`.
    d = Resolve.default_ctor_info(true, @s14)
    assert %Info{kind: :derived_ctor, src: @s14, rest?: true} = d
    assert d.hidden == [:this, :new_target, :ctor_fn]
    assert d.slots == %{"args" => 6, this: 7, new_target: 8, ctor_fn: 9}
    assert d.size == 9 and d.nparams == 0 and d.params == :patterns

    assert d.kinds ==
             {:parent, :rec, :caller, :call_pos, :root, :param, :hidden, :hidden, :hidden}

    b = Resolve.default_ctor_info(false, "class A {}")
    assert %Info{kind: :ctor, src: "class A {}"} = b
    assert b.hidden == [:this] and b.slots == %{this: 6} and b.size == 6
    assert b.level == 3
  end

  test "15. direct eval makes a function and everything inside it dynamic" do
    tree = resolve(@s15a)
    outer = fun(tree, "outer")
    assert info(outer).level == 2
    assert info(outer).rewritten
    refute info(outer).dynamic
    assert {:return, {:slot, 0, 6, "z"}, :plain} = List.last(body(outer))

    f = fun(tree, "f")
    assert info(f).dynamic
    assert info(f).level == nil
    refute info(f).rewritten
    assert forms(f) == []
    assert [{:expr, {:call, {:id, "eval"}, [{:str, "x"}], false}}, {:return, a}] = body(f)

    assert {:fn, nil, [], {:id, "y"}, :arrow_expr,
            %Info{dynamic: true, level: nil, rewritten: false}} = a

    f = fun(resolve(@s15b), "f")
    refute info(f).dynamic
    assert info(f).level == 1
    assert forms(f) == [{:gref, "eval"}, {:gref, "eval"}]
  end

  test "16. a dynamic function frames the block around it; with makes a region dynamic" do
    f = fun(resolve(@s16a), "f")

    assert %Scope{kind: :block, frame: true, slots: %{"z" => 6, "g" => 7}, hoist: [{7, _}]} =
             scope_of(f, 0)

    assert info(fun(f, "g")).dynamic
    refute info(f).dynamic
    assert info(f).level == 2

    f = fun(resolve(@s16b), "f")
    # `g` is a function declaration of `f` and takes slot 6 (design 3.1, group 3); the
    # block's `z` is a frameless name and comes after it (group 5).
    assert %Scope{kind: :block, frame: false, slots: %{"z" => 7}, tdz: [7]} = scope_of(f, 0)
    assert info(f).slots == %{"g" => 6}
    assert info(fun(f, "g")).dynamic

    tree = resolve(@s16c)
    h = fun(tree, "h")
    assert info(h).dynamic
    assert info(h).level == nil
    assert body(h) == [{:return, {:id, "x"}}]
    k = fun(tree, "k")
    assert info(k).rewritten
    assert forms(k) == [{:gref, "x"}]
  end

  test "17. free names: script, direct eval and indirect eval tops" do
    f = fun(resolve(@s17a), "f")
    assert forms(f) == [{:gref, "Math"}, {:gref, "y"}]

    f = fun(resolve(@s17b, eval: true), "f")
    assert info(f).rewritten
    assert forms(f) == [{:mref, 1, "l"}]

    assert [
             {:return,
              {:call, {:member, {:id, "Math"}, {:str, "max"}, false},
               [{:id, "y"}, {:mref, 1, "l"}], false}, :plain}
           ] = body(f)

    f = fun(resolve(@s17c, eval: true, indirect: true), "f")
    assert forms(f) == [{:gref, "v"}, {:mref, 1, "l"}, {:gref, "y"}, {:gref, "g"}]

    f = fun(resolve(@s17d, eval: true, indirect: true), "f")
    # A strict eval keeps its `var`s and functions in its own lexical scope (design 4.6).
    assert forms(f) == [{:mref, 1, "v"}, {:mref, 1, "g"}]
  end

  test "18. module names are mref, undeclared names gref, top-level statements unchanged" do
    tree = resolve(@s18a, module: true)
    f = fun(tree, "f")
    assert forms(f) == [{:mref, 1, "a"}, {:mref, 1, "b"}, {:gref, "c"}]

    assert {:program,
            [
              {:import, "m", [{:named, "a", "a"}]},
              {:var, :const, [{{:id, "b"}, {:num, 1.0}}]},
              {:export, {:fundecl, "f", {:fn, "f", [], _, false, %Info{}}}},
              {:block, [{:var, :let, [{{:id, "q"}, {:id, "b"}}]}]}
            ]} = tree

    # The declaration of `"*default*"` is a fact of the module scope that no name can read;
    # the test checks that the pass accepts the form and attaches an Info to the function.
    assert {:program,
            [
              {:export_default,
               {:fundecl, "*default*", {:fn, "default", [], _, false, %Info{kind: :fn}}}}
            ]} =
             resolve(@s18b, module: true)

    tree = resolve(@s18c, module: true)
    a = arrow(tree)
    assert info(a).rewritten
    assert {:fn, nil, [], {:binary, "+", {:id, "b"}, {:gref, "c"}}, :arrow_expr, %Info{}} = a
  end

  test "19. class scopes: the class name by mref, outer locals by depth, static blocks by name" do
    tree = resolve(@s19a)
    m = fun(tree, "m")
    assert info(m).level == 1
    assert forms(m) == [{:mref, 1, "A"}, {:slot, 2, 6, "v"}]
    outer = fun(tree, "outer")
    # `v` is slot 6 and the class declaration slot 7 (design 3.1, group 4). The parser folds
    # a class declaration into `{:var, :let, ...}`, so its kind is `:let` (resolve.ex,
    # the decisions of the moduledoc).
    assert info(outer).slots == %{"v" => 6, "A" => 7}
    assert kind(info(outer), "v") == :let
    assert kind(info(outer), "A") == :let

    assert {:cmember, :block, nil, [{:var, :var, [{{:id, "s"}, nil}]}, {:expr, {:id, "s"}}], true} =
             find(tree, &match?({:cmember, :block, _, _, _}, &1))

    m = fun(resolve(@s19b), "m")
    assert [_, {:return, {:binary, "in", {:priv_ref, "p"}, {:slot, 0, 6, "o"}}, :plain}] = body(m)
    # A private name needs the class scope by name, level 3 (design 3.2).
    assert info(m).level == 3

    m = fun(resolve(@s19a, resolve: :info), "m")
    assert info(m).level == 1
    refute info(m).rewritten

    assert [{:expr, {:str, "use strict"}}, {:return, {:binary, "+", {:id, "A"}, {:id, "v"}}}] =
             body(m)
  end

  test "20. parameter defaults and patterns" do
    f = fun(resolve(@s20a), "f")
    i = info(f)
    assert i.params == :exprs
    assert i.copies == [{6, 8}]
    assert i.slots["a"] == 8
    assert i.slots["g"] == 7
    # Three slots after the header: the two parameters and the body's own `a` (design 4.5).
    assert i.size == 8
    assert i.kinds == {:parent, :rec, :caller, :call_pos, :root, :param, :param, :var}
    # The default runs in the function's own frame, one hop from the arrow (design 4.5).
    assert forms(arrow(f)) == [{:slot, 1, 6, "a"}]

    assert params(f) == [
             {:default, {:slot, 0, 6, "a"}, {:num, 1.0}},
             {:default, {:slot, 0, 7, "g"}, arrow(f)}
           ]

    # The body's `var a` is the copied slot 8, never the parameter slot 6.
    assert body(f) == [{:var, :var, [{{:slot, 0, 8, "a"}, nil}]}]
    assert i.template == [:undefined]
    assert 6 in i.captured

    f = fun(resolve(@s20b), "f")
    assert slots(info(f)) == [{6, "a", :param}]
    assert info(f).copies == []
    assert info(f).size == 6

    f = fun(resolve(@s20c), "f")
    # The body's `var b` is not visible from the parameter phase, so the default reads the
    # global (design 4.5).
    assert params(f) == [{:default, {:slot, 0, 6, "a"}, {:gref, "b"}}]
    assert body(f) == [{:var, :var, [{{:slot, 0, 7, "b"}, nil}]}]
    assert slots(info(f)) == [{6, "a", :param}, {7, "b", :var}]

    f = fun(resolve(@s20d), "f")
    assert info(f).params == :patterns
    assert info(f).nparams == 2
    assert slots(info(f)) == [{6, "a", :param}, {7, "b", :param}, {8, "c", :param}]
    assert info(f).size == 8

    assert params(f) == [
             {:objpat, [{{:str, "a"}, {:slot, 0, 6, "a"}}, {{:str, "b"}, {:slot, 0, 7, "b"}}],
              nil},
             {:arrpat, [{:slot, 0, 8, "c"}]}
           ]

    # A rest parameter makes the parameters patterns and is not counted (deviation 6).
    f = fun(resolve("function f(a, ...r) { return r }"), "f")
    i = info(f)
    assert i.params == :patterns and i.rest? and i.nparams == 1
    assert slots(i) == [{6, "a", :param}, {7, "r", :param}] and i.size == 7
    assert params(f) == [{:slot, 0, 6, "a"}, {:rest, {:slot, 0, 7, "r"}}]
    assert body(f) == [{:return, {:slot, 0, 7, "r"}, :plain}]
  end

  test "21. strictness comes from the directive, the file position follows it" do
    f = fun(resolve(@s21a), "f")
    assert info(f).strict
    assert [{:expr, {:str, "use strict"}}, {:return, {:num, 1.0}, :plain}] = body(f)

    f = fun(resolve(@s21a, file: "t.js"), "f")
    assert info(f).strict

    assert [{:expr, {:str, "use strict"}}, {:pos, {"t.js", 1}}, {:return, {:num, 1.0}, :plain}] =
             body(f)

    assert info(arrow(resolve(@s21b))).strict
    refute info(arrow(resolve(@s21c))).strict
    # An expression arrow takes the strictness of the function around it (design 4.5).
    assert info(arrow(resolve(@s21d))).strict
  end

  test "22. tail sites" do
    for src <- @s22_tail do
      f = fun(resolve(src), "f")
      assert [{:return, _, :tail}] = tails(f), src
      assert info(f).tail_sites == 1, src
    end

    assert [{:return, {:call, {:gref, "g"}, [], false}, :tail}] =
             tails(fun(resolve(hd(@s22_tail)), "f"))

    for src <- @s22_no_tail do
      name = if String.contains?(src, "constructor"), do: "constructor", else: "f"
      f = fun(resolve(src), name)
      assert tails(f) == [], src
      assert info(f).tail_sites == 0, src
    end

    # Step 2b: every other `return` with a value inside a rewritten function is `:plain`,
    # so the evaluator never reads the run-time tail flag there. A sloppy function has no
    # tail sites at all. A function the level does not rewrite keeps the bare form, and
    # `check/1` refuses a bare return inside a rewritten function.
    f = fun(resolve("function f(n) { if (n) return g(); return 1 }"), "f")

    assert [
             {:if, {:slot, 0, 6, "n"}, {:return, {:call, {:gref, "g"}, [], false}, :plain}, nil},
             {:return, {:num, 1.0}, :plain}
           ] = body(f)

    f = fun(resolve("'use strict'; function f(n) { while (n) { return g() } return 1 }"), "f")

    assert [_, {:while, _, {:block, [{:return, _, :tail}], nil}}, {:return, {:num, 1.0}, :plain}] =
             body(f)

    f = fun(resolve("function f() { return 1 }", resolve: :info), "f")
    assert body(f) == [{:return, {:num, 1.0}}]

    assert {:error, _} =
             Resolve.check(
               {:program,
                [
                  {:fundecl, "f",
                   {:fn, "f", [], [{:return, {:num, 1.0}}], false,
                    %Info{rewritten: true, level: 1}}}
                ]}
             )
  end

  test "23. await wraps the statements of async and generator bodies" do
    f = fun(resolve(@s23a), "f")
    assert info(f).has_await

    # Every statement that contains an await is wrapped (design 4.9), the block of the `if`
    # included: the CPS evaluator checks each branch statement on its own (async.ex `cexec`).
    assert body(f) == [
             {:expr, {:gref, "x"}},
             {:aw, {:expr, {:await, {:gref, "y"}}}},
             {:aw,
              {:if, {:gref, "c"}, {:aw, {:block, [{:aw, {:expr, {:await, {:gref, "z"}}}}], nil}},
               nil}}
           ]

    f = fun(resolve(@s23b), "f")
    assert [{:aw, {:var, :let, [{{:slot, 0, 6, "A"}, {:class, "A", nil, _, _}}]}}] = body(f)

    f = fun(resolve(@s23c), "f")
    assert aws(f) == []
    refute info(f).has_await

    assert {:program, [{:expr, {:await, {:num, 1.0}}}, {:expr, {:id, "x"}}]} =
             resolve(@s23d, module: true)

    f = fun(resolve(@s23e), "f")
    assert info(f).generator?
    assert [{:aw, {:expr, {:yield, {:num, 1.0}, false}}}] = body(f)
  end

  test "24. a level rewrites only the functions at or below it" do
    tree = resolve(@s24, resolve: 1)
    f = fun(tree, "f")
    refute info(f).rewritten
    assert info(f).level == 2
    assert [{:var, :let, [{{:id, "fs"}, _}]}, {:block, _}] = body(f)
    a = arrow(f)
    assert info(a).rewritten

    assert {:fn, nil, [{:slot, 0, 6, "p"}], {:binary, "+", {:slot, 0, 6, "p"}, {:id, "x"}},
            :arrow_expr, _} = a

    f = fun(resolve(@s12a, resolve: 2), "f")
    refute info(f).rewritten
    assert same_but_src?(f, fun(off(@s12a), "f"))

    f = fun(resolve(@s23a, resolve: 3), "f")
    refute info(f).rewritten
    assert same_but_src?(f, fun(off(@s23a), "f"))
  end

  test "25. with the flag off the parsed term is today's" do
    # (under `JS_RESOLVE` the default parse resolves, so only the explicit `:off` is checked)
    default_off? = Application.get_env(:browser, :js_resolve, :off) == :off

    sources =
      @cases ++
        Enum.map(@eval_sources ++ @early_error_scripts, &{&1, []}) ++
        Enum.map(@early_error_modules, &{&1, [module: true]}) ++
        Enum.map(prelude_sources(), fn {_, src} -> {src, []} end)

    for {src, opts} <- sources do
      plain = Parser.parse(src, [resolve: :off] ++ opts)
      if default_off?, do: assert(plain == Parser.parse(src, opts), src)
      assert marks(plain) == [], src
    end
  end

  test "26. :info attaches facts and changes nothing else" do
    for {src, opts} <- @cases do
      tree = off(src, opts)
      marked = program(tree, :info, opts)
      assert Resolve.strip(marked) == tree, src
      assert same_but_src?(marked, tree), src
      assert Enum.all?(fns(marked), &match?({:fn, _, _, _, _, %Info{rewritten: false}}, &1)), src
    end

    for level <- @eval_levels, src <- @eval_sources do
      assert Browser.JS.eval(src, resolve: level) == Browser.JS.eval(src, resolve: :off),
             "#{src} at #{level}"
    end

    for level <- @eval_levels, src <- @early_error_scripts do
      assert Browser.JS.eval(src, resolve: level, max_steps: 10_000) ==
               Browser.JS.eval(src, resolve: :off, max_steps: 10_000),
             "#{src} at #{level}"
    end

    for level <- @eval_levels, src <- @early_error_modules do
      plain = Parser.parse(src, module: true, resolve: :off)

      assert match?({:ok, _}, plain) ==
               match?({:ok, _}, Parser.parse(src, module: true, resolve: level)),
             "#{src} at #{level}"
    end
  end

  @tag :corpus
  @tag timeout: :infinity
  test "27. round trip and check over the corpus" do
    {failures, parsed, unparsed} =
      Enum.reduce(corpus(), {[], 0, 0}, fn {label, src, opts}, {failures, parsed, unparsed} ->
        case Parser.parse(src, opts) do
          {:error, _} ->
            {failures, parsed, unparsed + 1}

          {:ok, tree} ->
            bad =
              Enum.flat_map(@levels, fn level ->
                resolved = program(tree, level, opts)

                cond do
                  Resolve.strip(resolved) != tree ->
                    ["#{label}: strip at #{level} differs"]

                  # (level 3 too: rules R3 and R4 of step 2d emit only from level 3)
                  level in [3, 4] and Resolve.check(resolved, top: top_of(opts)) != :ok ->
                    ["#{label}: #{inspect(Resolve.check(resolved, top: top_of(opts)))}"]

                  true ->
                    []
                end
              end)

            {bad ++ failures, parsed + 1, unparsed}
        end
      end)

    assert parsed > 0

    assert failures == [],
           "#{length(failures)} failures (#{parsed} parsed, #{unparsed} unparsed):\n" <>
             Enum.join(Enum.take(Enum.reverse(failures), 20), "\n")
  end

  @tag :corpus
  @tag timeout: :infinity
  test "28. the Info of every function agrees with the interpreter's hoisting helpers" do
    {failures, functions} =
      Enum.reduce(corpus(), {[], 0}, fn {label, src, opts}, {failures, functions} ->
        case Parser.parse(src, opts) do
          {:error, _} ->
            {failures, functions}

          {:ok, tree} ->
            nodes = fns(program(tree, :info, opts))
            bad = for node <- nodes, msg <- oracle_failures(node), do: "#{label}: #{msg}"
            {bad ++ failures, functions + length(nodes)}
        end
      end)

    assert functions > 0

    assert failures == [],
           "#{length(failures)} disagreements over #{functions} functions:\n" <>
             Enum.join(Enum.take(Enum.reverse(failures), 20), "\n")
  end

  test "29. both passes agree on the scope count at every level" do
    for {src, opts} <- @cases, level <- @levels do
      assert {:program, _} = program(off(src, opts), level, opts), "#{src} at #{level}"
    end
  end

  # ── tests from the review of the pass ───────────────────────

  test "30. an instance field initializer is a closure boundary" do
    # The loop head gets a per-iteration frame: each class reads its own `i` (the
    # initializer runs at `new` time, after the loop moved on). The read is two hops from
    # the field scope: the class scope, then the loop frame.
    f = fun(resolve(@s30a), "f")
    assert %Scope{kind: :loop, frame: true, per_iter: true, slots: %{"i" => 6}} = scope_of(f, 0)
    refute Map.has_key?(info(f).slots, "i")

    assert [
             {:cmember, :field, _, {:slot, 2, 6, "i"}, false},
             {:cmember, :accessor, _, {:slot, 2, 6, "i"}, false}
           ] =
             find(f, &match?({:class, _, _, _, _}, &1)) |> elem(3)

    # The block around the class gets a frame for `v`.
    f = fun(resolve(@s30b), "f")
    assert %Scope{kind: :block, frame: true, slots: %{"v" => 6}} = scope_of(f, 1)

    assert [{:cmember, :field, _, {:slot, 2, 6, "v"}, false}] =
             find(f, &match?({:class, _, _, _, _}, &1)) |> elem(3)

    # A class in a default value captures the parameter: the body's `var a` gets a slot
    # of its own, copied from the parameter, and the initializer keeps the parameter.
    f = fun(resolve(@s30c), "f")
    i = info(f)
    assert i.copies == [{6, 8}]
    assert i.captured == MapSet.new([6])
    # `slots` keeps the body's entry for `a`; the parameter slot 6 stays in `kinds`.
    assert slots(i) == [{7, "C", :param}, {8, "a", :var}]
    assert i.kinds == {:parent, :rec, :caller, :call_pos, :root, :param, :param, :var}

    assert [{:cmember, :field, _, {:slot, 2, 6, "a"}, false}] =
             find(f, &match?({:class, _, _, _, _}, &1)) |> elem(3)

    assert [{:var, :var, [{{:slot, 0, 8, "a"}, _}]} | _] = body(f)

    # A static initializer runs inline: no capture, no frame.
    f = fun(resolve(@s30d), "f")
    assert info(f).captured == MapSet.new()

    assert [{:cmember, :field, _, {:slot, 2, 6, "x"}, true}] =
             find(f, &match?({:class, _, _, _, _}, &1)) |> elem(3)
  end

  test "31. a direct eval in a field initializer keeps its callee and the names around it" do
    f = fun(resolve(@s31), "f")
    assert info(f).rewritten
    refute info(f).dynamic
    # The three initializers (instance, static, accessor) keep `{:id, "eval"}`, which the
    # interpreter's direct-eval clause matches.
    assert {:class, _, _, members, _} = find(f, &match?({:class, _, _, _, _}, &1))

    assert Enum.map(members, fn {:cmember, _, _, init, _} -> init end) ==
             List.duplicate({:call, {:id, "eval"}, [{:str, "x"}], false}, 3)

    assert Resolve.check(resolve(@s31)) == :ok

    # `check/1` rejects a direct eval whose callee was rewritten.
    assert {:error, _} =
             Resolve.check(
               {:program,
                [
                  {:fundecl, "f",
                   {:fn, "f", [], [{:expr, {:call, {:gref, "eval"}, [], false}}], false,
                    %Info{rewritten: true, level: 1}}}
                ]}
             )
  end

  test "32. var arguments under parameter initializers keeps the object in a hidden slot" do
    f = fun(resolve(@s32a), "f")
    i = info(f)
    assert i.args_var
    assert i.hidden == [:args, :arguments]

    assert slots(i) == [
             {6, "a", :param},
             {7, :args, :hidden},
             {8, :arguments, :hidden},
             {9, "arguments", :var}
           ]

    # The body's `var` is filled from the object at body entry.
    assert i.copies == [{8, 9}]
    assert i.captured == MapSet.new([8])
    # The closure in the default reads the object; the body reads and writes the `var`.
    assert forms(arrow(f)) == [{:aslot, 1, 8}]

    assert [
             {:var, :var, [{{:slot, 0, 9, "arguments"}, _}]},
             {:return, {:array, [_, {:slot, 0, 9, "arguments"}]}, :plain}
           ] = body(f)

    assert Resolve.check(resolve(@s32a)) == :ok

    f = fun(resolve(@s32b), "f")
    assert forms(params(f)) == [{:slot, 0, 6, "a"}, {:aslot, 0, 8}]
    assert forms(body(f)) == [{:slot, 0, 9, "arguments"}, {:slot, 0, 9, "arguments"}]
    assert Resolve.check(resolve(@s32b)) == :ok

    # Without parameter initializers the `var` slot keeps the object, as before.
    f = fun(resolve(@s12d), "f")
    assert info(f).hidden == [:args]
    assert info(f).copies == []

    # `captured` names the object's slot, not the slot of the function or lexical that
    # takes the name in the body.
    f = fun(resolve(@s32c), "f")
    assert info(f).slots[:arguments] == 8
    assert forms(arrow(f)) == [{:aslot, 1, 8}]
    assert info(f).captured == MapSet.new([8])
    f = fun(resolve(@s32d), "f")
    assert forms(arrow(f)) == [{:aslot, 1, 8}]
    assert info(f).captured == MapSet.new([8])
  end

  test "33. a function declaration takes over the own slot of a default-captured var" do
    f = fun(resolve(@s33a), "f")
    i = info(f)
    assert slots(i) == [{7, "g", :param}, {8, "a", :fun}]
    assert i.kinds == {:parent, :rec, :caller, :call_pos, :root, :param, :param, :fun}
    assert i.copies == [{6, 8}]
    assert [{8, _}] = i.hoist
    assert i.size == 8

    # Only the parameter slot is captured: the body's `var` is read by no closure.
    f = fun(resolve(@s33b), "f")
    assert info(f).captured == MapSet.new([6])
    assert info(f).copies == [{6, 9}]

    f = fun(resolve(@s33c), "f")
    i = info(f)
    assert slots(i) == [{7, "a", :fun}]
    assert i.kinds == {:parent, :rec, :caller, :call_pos, :root, :param, :fun}
    assert i.copies == [{6, 7}]
    assert [{7, _}] = i.hoist
    assert i.size == 7
    # Every read of `a` in the body is slot 7: the `var` target and the return.
    assert forms(body(f)) == [{:slot, 0, 7, "a"}, {:slot, 0, 7, "a"}]
    assert Resolve.check(resolve(@s33c)) == :ok
  end

  test "34. captured lists every hidden slot that super() and super.x read or write" do
    m = fun(resolve(@s34a), "m")
    assert info(m).slots == %{this: 6, home: 7}
    assert info(m).captured == MapSet.new([6, 7])

    c = fun(resolve(@s34b), "constructor")
    assert info(c).slots == %{this: 6, new_target: 7, ctor_fn: 8}
    assert info(c).captured == MapSet.new([6, 7, 8])
  end

  test "35. imports after a top-level using are module names" do
    tree = resolve(@s35, module: true)
    f = fun(tree, "f")
    assert forms(f) == [{:mref, 1, "a"}, {:mref, 1, "b"}, {:mref, 1, "x"}]
    # `check/1` infers the module from the statements inside the `using` rest.
    assert Resolve.check(tree) == :ok
  end

  test "36. a direct eval in a for-using head keeps the function name-based" do
    f = fun(resolve(@s36), "f")
    assert info(f).dynamic
    refute info(f).rewritten
    assert [{:forof, :const, _, {:tdz_names, ["x"], _}, _}] = body(f)
    assert forms(f) == []
  end

  test "37. the await wrap follows the statement's own awaits, not a nested function's" do
    f = fun(resolve(@s37a), "f")

    assert [{:aw, {:for, _, _, _, {:aw, {:block, [{:aw, {:expr, {:await, _}}}], nil}}, %Scope{}}}] =
             body(f)

    f = fun(resolve(@s37b), "f")
    assert [{:var, :const, _}, {:expr, {:gref, "y"}}] = body(f)
    assert [{:aw, {:expr, {:await, _}}}] = body(arrow(f))
    # The await belongs to the arrow (design 4.9: the walk stops at function nodes).
    refute info(f).has_await
    assert info(arrow(f)).has_await
    assert info(fun(resolve(@s37a), "f")).has_await
    refute info(fun(resolve(@s23c), "f")).has_await

    f = fun(resolve(@s37c), "f")

    assert [
             {:aw, {:forawait, _, _, _, _, _}},
             {:aw, {:using, :await_using, _, _, [{:expr, {:gref, "w"}}]}}
           ] = body(f)
  end

  test "38. templates of framed scopes and the default constructor constants" do
    # The block frame holds `a`, `b` and then the names of the frameless block under it,
    # its lexical names first: `c` in its TDZ, then the function `g` as undefined.
    f = fun(resolve(@s38a), "f")
    assert %Scope{frame: true, slots: %{"a" => 6, "b" => 7}, size: 9} = sc = scope_of(f, 0)
    assert sc.template == [:tdz, :tdz, :tdz, :undefined]
    assert %Scope{frame: false, slots: %{"c" => 8, "g" => 9}, hoist: [{9, _}]} = scope_of(f, 1)

    # The constants agree with the resolver's own Info for the same text, except for the
    # source and `rewritten` (which step 2d sets).
    for {src, derived?} <- [{@s38b, false}, {@s38c, true}] do
      i = info(fun(resolve(src), "constructor"))
      d = Resolve.default_ctor_info(derived?, i.src)
      assert %{i | rewritten: false} == d, src
    end
  end

  # ── tests from the review of the tests ──────────────────────

  test "39. for (using x of e): three distinct slots" do
    # The parser's synthetic head const takes slot 7, the pseudo-slot that the iterable
    # reads as `x` in its TDZ is 8 (written by nothing), and the body's `using x` is 9
    # (design 3.4 and deviation 4).
    src = "function f(xs) { for (using x of (() => x)()) { x } }"
    f = fun(resolve(src), "f")
    i = info(f)
    assert i.size == 9
    assert i.kinds == {:parent, :rec, :caller, :call_pos, :root, :param, :const, :const, :using}
    assert i.template == [:tdz, :tdz, :tdz]
    refute Map.has_key?(i.slots, "x")

    assert [
             {:forof, :const, {:slot, 0, 7, _}, {:in_tdz, ["x"], {:call, arrow, [], false}},
              {:block,
               [
                 {:using, :using, {:slot, 0, 9, "x"}, {:slot, 0, 7, _},
                  [{:block, [expr: {:slot, 0, 9, "x"}], nil}]}
               ],
               %Scope{
                 kind: :block,
                 frame: false,
                 slots: %{"x" => 9},
                 kinds: %{9 => :using},
                 tdz: [9]
               }}, %Scope{kind: :each, frame: false, slots: head_slots, tdz: [7]}}
           ] = body(f)

    assert Map.values(head_slots) == [7]
    assert {:fn, nil, [], {:slot, 1, 8, "x"}, :arrow_expr, %Info{}} = arrow
    assert i.captured == MapSet.new([8])
    assert Resolve.strip(f) == fun(off(src), "f")
  end

  test "40. a for-of head is in its TDZ over its own iterable; a framed block under a framed head" do
    # Design 4.2: the iterable sees the head names as `:tdz` in the same slots, so `g(x)`
    # reads the head slot 8, not the parameter 6.
    f = fun(resolve("function f(x, g) { for (const x of g(x)) {} }"), "f")

    assert [
             {:forof, :const, {:slot, 0, 8, "x"},
              {:call, {:slot, 0, 7, "g"}, [{:slot, 0, 8, "x"}], false}, {:block, [], nil},
              %Scope{kind: :each, frame: false, slots: %{"x" => 8}, tdz: [8]}}
           ] = body(f)

    assert info(f).template == [:tdz]

    # The arrow counts two hops to the head name through the framed block (design 3.3).
    f =
      fun(
        resolve("function f(xs, fs) { for (const x of xs) { let y; fs.push(() => x + y) } }"),
        "f"
      )

    assert %Scope{kind: :each, frame: true, slots: %{"x" => 6}} = scope_of(f, 0)
    assert %Scope{kind: :block, frame: true, slots: %{"y" => 6}} = scope_of(f, 1)
    assert forms(arrow(f)) == [{:slot, 2, 6, "x"}, {:slot, 1, 6, "y"}]
    assert {:slot, 2, 7, "fs"} in forms(f)
  end

  test "41. depths through the class, field, static and static-block scopes" do
    # A function in a static block: its frame, the static block, the static scope, the
    # class scope, then `outer` (design 4.7).
    tree =
      resolve(
        "function outer() { let v; class A { static { var s; function g() { return s + v } } } }"
      )

    assert forms(fun(tree, "g")) == [{:mref, 1, "s"}, {:slot, 4, 6, "v"}]

    # An arrow in a field initializer: its frame, the field scope, the class scope, then
    # `outer`; the plain initializer is one hop less.
    tree =
      resolve("function outer() { let v; class A { x = () => v; static y = () => v; z = v } }")

    assert forms(arrow(tree, 0)) == [{:slot, 3, 6, "v"}]
    assert forms(arrow(tree, 1)) == [{:slot, 3, 6, "v"}]

    assert {:cmember, :field, {:str, "z"}, {:slot, 2, 6, "v"}, false} =
             find(tree, &match?({:cmember, :field, {:str, "z"}, _, _}, &1))

    # The heritage and a computed key run in the class scope, one hop from `f`.
    f = fun(resolve("function f(B, k) { class A extends B { [k]() {} } }"), "f")

    assert {:class, "A", {:slot, 1, 6, "B"},
            [{:cmember, :method, {:computed, {:slot, 1, 7, "k"}}, _, false}], _} =
             find(f, &match?({:class, _, _, _, _}, &1))

    # A class expression's own name is a name of the class scope.
    assert forms(fun(resolve("function f() { return class A { m() { return A } } }"), "m")) ==
             [{:mref, 1, "A"}]
  end

  test "42. a top-level block blocks the hop-counted forms and passes {:gref} through" do
    # Design 4.1: the block is not a frame, so its names and every name beyond it stay
    # `{:id}`; only a name that no scope declares becomes `{:gref}`.
    g = fun(resolve("{ let z = 1; function g() { return z + w } }"), "g")
    assert info(g).rewritten
    assert body(g) == [{:return, {:binary, "+", {:id, "z"}, {:gref, "w"}}, :plain}]

    g =
      fun(resolve("const b = 1; { let z; function g() { return b + z + c } }", module: true), "g")

    assert [
             _,
             {:return, {:binary, "+", {:binary, "+", {:id, "b"}, {:id, "z"}}, {:gref, "c"}},
              :plain}
           ] = body(g)
  end

  test "43. a function as the sole if-branch or labeled body, new.target in an arrow, strict eval" do
    # Design 4.2: such a declaration is never instantiated, so the resolver declares
    # nothing and the read of `g` is free.
    f = fun(resolve("function f(c) { if (c) function g() {} return g }"), "f")
    assert info(f).slots == %{"c" => 6} and info(f).hoist == []

    assert [
             {:if, {:slot, 0, 6, "c"},
              {:fundecl, "g", {:fn, "g", [], [], false, %Info{rewritten: true}}}, nil},
             {:return, {:gref, "g"}, :plain}
           ] = body(f)

    f = fun(resolve("function f() { l: function g() {} return g }"), "f")
    assert info(f).slots == %{}
    assert [{:labeled, "l", {:fundecl, "g", _}}, {:return, {:gref, "g"}, :plain}] = body(f)

    # Design 4.4: `new.target` in an arrow is a hidden slot of the nearest function.
    f = fun(resolve("function f() { return () => new.target }"), "f")
    assert info(f).level == 3 and info(f).hidden == [:new_target]
    assert info(f).slots == %{new_target: 6}
    assert forms(arrow(f)) == [{:slot, 1, 6, :new_target}] and info(f).captured == MapSet.new([6])

    # Design 4.6: a strict direct eval keeps its vars and functions in its own scope, from
    # the directive or from the caller's `strict: true`; a sloppy one leaves them by name.
    f =
      fun(
        resolve(
          "\"use strict\"; var v = 1; function g() {} function f() { return v + g + l } let l",
          eval: true
        ),
        "f"
      )

    assert forms(f) == [{:mref, 1, "v"}, {:mref, 1, "g"}, {:mref, 1, "l"}]

    assert forms(
             fun(resolve("var v = 1; function f() { return v }", eval: true, strict: true), "f")
           ) ==
             [{:mref, 1, "v"}]

    assert [{:return, {:id, "v"}, :plain}] =
             body(fun(resolve("var v = 1; function f() { return v }", eval: true), "f"))
  end

  # Step 2c design 4.3, hole 1: the eval code reads `this`, `arguments` and `new.target`
  # by name from the function around the arrow, so that function owns them and is level 3.
  test "2c. a direct eval in an arrow makes the function around it level 3" do
    tree = resolve("function f(){ return (() => eval('this.k'))() }", resolve: 2)
    f = info(fun(tree, "f"))
    assert %Info{level: 3, rewritten: false, dynamic: false} = f
    assert f.uses_this and f.uses_arguments and f.uses_new_target
    # (the kind names the arrow: the interpreter's frame walks tell arrows apart by it)
    assert %Info{level: nil, dynamic: true, kind: :arrow_expr} = info(arrow(tree))

    assert %Info{kind: :arrow} =
             info(arrow(resolve("function g(){ return () => { return 1 } }", resolve: 2)))

    # A function without such an arrow keeps its level.
    assert %Info{level: 2, rewritten: true} =
             info(fun(resolve("function g(){ return () => this.k }", resolve: 2), "g"))
  end

  # Step 2c design 4.3, hole 2: a dynamic function in a parameter initializer makes the
  # function of that list dynamic; the functions beside it keep their levels.
  test "2c. a direct eval in a default value makes the function of the list dynamic" do
    tree =
      resolve(
        "function f(a = 1, b = function(){ return eval('a') }){ var a = 2; return b() } " <>
          "function s(){ return () => 1 }",
        resolve: 2
      )

    assert %Info{level: nil, dynamic: true} = info(fun(tree, "f"))
    assert %Info{level: 2, rewritten: true} = info(fun(tree, "s"))
    assert %Info{level: 1, rewritten: true} = info(arrow(tree))

    tree = resolve("function f(o, b = function(){ with (o) { return a } }){ var a }", resolve: 2)
    assert %Info{level: nil, dynamic: true} = info(fun(tree, "f"))
  end

  # ── step 2d: rules R1 to R4 (notes/js-frames-2d-design.md, 1.5, 1.6, 2.4 and 2.6) ──

  test "2d. R1: eval in an arrow gives the super bindings of the old path from level 3" do
    src = "class B extends A { constructor(){ (() => eval('super()'))() } }"
    c = info(fun(resolve(src, resolve: 3), "constructor"))
    assert c.hidden == [:this, :args, :arguments, :new_target, :home, :ctor_fn]
    assert c.rewritten

    # Below level 3 the facts stay as they were: the owner is not rewritten there.
    c = info(fun(resolve(src, resolve: 2), "constructor"))
    assert c.hidden == [:this, :args, :arguments, :new_target, :home]

    # A plain function gets no `:home`, so the by-name walk of `super.m()` goes on to the
    # method, as on the old path.
    src =
      "class B extends A { m(){ function g(){ return (() => eval('super.m()'))() } " <>
        "return g.call(this) } }"

    assert info(fun(resolve(src, resolve: 3), "g")).hidden == [
             :this,
             :args,
             :arguments,
             :new_target
           ]

    assert :home in info(fun(resolve(src, resolve: 2), "g")).hidden

    # A method gets `:home` and no `:ctor_fn`.
    m = info(fun(resolve("({ m(){ return (() => eval('1'))() } })", resolve: 3), "m"))
    assert :home in m.hidden
    refute :ctor_fn in m.hidden
  end

  test "2d. R2: an async arrow in the parameters makes the owner dynamic" do
    for decl <- ["let arguments = 1", "var arguments = 1", "function arguments(){}"] do
      src = "function f(a = async () => { r = arguments.length }){ #{decl}; return a }"
      assert %Info{dynamic: true, level: nil} = info(fun(resolve(src, resolve: 3), "f"))
      assert %Info{dynamic: false, level: 3} = info(fun(resolve(src, resolve: 2), "f"))
    end

    # Without a body declaration of the name the by-name walk finds the object.
    src = "function f(a = async () => arguments.length){ return a }"
    assert %Info{dynamic: false, level: 3, rewritten: true} = info(fun(resolve(src), "f"))

    # A rewritten arrow reads the hidden slot, so the owner keeps its level.
    src = "function f(a = () => arguments.length){ let arguments = 1; return a }"
    tree = resolve(src, resolve: 3)
    assert %Info{dynamic: false, level: 3, rewritten: true} = info(fun(tree, "f"))
    assert forms(arrow(tree)) == [{:aslot, 1, 8}]
  end

  test "2d. R3: a hidden arguments slot is an aslot, a var arguments slot is a slot" do
    for level <- [3, 4] do
      tree = resolve(@s12a, resolve: level)
      assert {:aslot, 0, 8} in forms(tree)
      assert Resolve.check(tree) == :ok
      assert Resolve.strip(tree) == off(@s12a)
    end

    tree = resolve(@s12d, resolve: 3)
    assert forms(tree) == [{:slot, 0, 7, "arguments"}, {:slot, 0, 7, "arguments"}]

    # An assignment to `arguments` keeps the form in its write role.
    src = "function f(){ arguments = 5; return arguments }"
    assert [{:aslot, 0, 7}, {:aslot, 0, 7}] = forms(resolve(src, resolve: 3))
    assert Resolve.check(resolve(src, resolve: 3)) == :ok

    # The check refuses an aslot that lands on a slot that is not the object's.
    bad =
      {:program,
       [
         {:fundecl, "f",
          put_elem(fun(resolve(@s12d, resolve: 3), "f"), 3, [{:return, {:aslot, 0, 7}, :plain}])}
       ]}

    assert {:error, _} = Resolve.check(bad)
  end

  test "2d. R4: a class without a constructor carries a default constructor Info from level 3" do
    src = "class A {} class B extends A {} class C { constructor(){} }"

    for level <- [3, 4] do
      tree = resolve(src, resolve: level)
      [a, b, c] = collect(tree, &match?({:class, _, _, _, _}, &1))
      assert {:class, "A", nil, [], %Info{kind: :ctor, rewritten: true, src: "class A {}"}} = a
      assert {:class, "B", _, [], %Info{kind: :derived_ctor, rewritten: true}} = b
      assert {:class, "C", nil, _, "class C { constructor(){} }"} = c
      assert Resolve.check(tree) == :ok
      assert Resolve.strip(tree) == off(src)
    end

    # At `:info`, 1 and 2 the class node keeps its source text.
    for level <- [:info, 1, 2] do
      for {:class, _, _, _, x} <-
            collect(resolve(src, resolve: level), &match?({:class, _, _, _, _}, &1)),
          do: assert(is_binary(x))
    end

    # A class in a dynamic region keeps its source text.
    tree = resolve("function f(){ eval(''); class A {} }", resolve: 3)
    assert [{:class, _, _, _, x}] = collect(tree, &match?({:class, _, _, _, _}, &1))
    assert is_binary(x)

    # The check refuses an Info on a class with a constructor member.
    {:program, [{:var, :let, [{id, {:class, n, h, m, s}}]}]} =
      resolve("class C { constructor(){} }", resolve: 3)

    bad =
      {:program,
       [
         {:var, :let,
          [{id, {:class, n, h, m, %{Resolve.default_ctor_info(false, s) | rewritten: true}}}]}
       ]}

    assert {:error, _} = Resolve.check(bad)
  end

  # ── step 2d: more cases of R1 to R4 ─────────────────────────

  # The cases of design 6.1, item 11, that the tests above do not cover.

  # The class nodes of a term, in source order.
  defp classes(term), do: collect(term, &match?({:class, _, _, _, _}, &1))

  # Replaces every subterm `from` of `term` with `to`, and fails when `term` has none: a
  # negative test of `check` proves nothing when it checks the unchanged term.
  defp swap(term, from, to) do
    swapped = replace(term, from, to)
    assert swapped != term, "no #{inspect(from)} in the term"
    swapped
  end

  # Replaces every subterm `from` of `term` with `to`, also inside the hoist list of an
  # `Info`, where a function node of the body is kept a second time.
  defp replace(term, from, to) when term == from, do: to

  defp replace(%Info{hoist: h} = i, from, to),
    do: %{i | hoist: Enum.map(h, fn {s, n} -> {s, replace(n, from, to)} end)}

  defp replace(%{__struct__: _} = s, _from, _to), do: s

  defp replace(t, from, to) when is_tuple(t),
    do: t |> Tuple.to_list() |> Enum.map(&replace(&1, from, to)) |> List.to_tuple()

  defp replace(l, from, to) when is_list(l), do: Enum.map(l, &replace(&1, from, to))
  defp replace(x, _from, _to), do: x

  test "2d. R1: a base constructor gets :ctor_fn, as `:off` gives it to every constructor" do
    src = "class C { constructor(){ (() => eval('1'))() } }"
    base = info(fun(resolve(src, resolve: 3), "constructor"))
    assert base.kind == :ctor
    assert :ctor_fn in base.hidden and :new_target in base.hidden and :home in base.hidden
  end

  test "2d. R2: an async arrow in the body keeps the owner at level 3" do
    # The body phase sees the body binding of `arguments`, as the spec says, so the rule of
    # design 2.6 does not apply.
    src = "function f(){ var arguments; return async () => arguments.length }"

    assert %Info{dynamic: false, level: 3, rewritten: true} =
             info(fun(resolve(src, resolve: 3), "f"))
  end

  test "2d. R3: every role of a hidden arguments slot, the hop of an arrow, the round trip" do
    src =
      "function f(a){ arguments = 5; return typeof arguments + delete arguments + arguments[0] }"

    tree = resolve(src, resolve: 3)
    f = fun(tree, "f")
    assert %Info{slots: %{"a" => 6, :args => 7, "arguments" => 8}} = info(f)
    assert collect(f, &match?({:aslot, _, _}, &1)) == List.duplicate({:aslot, 0, 8}, 4)
    refute find(f, &match?({:slot, _, _, "arguments"}, &1))
    assert Resolve.strip(tree) == off(src)
    assert Resolve.check(tree) == :ok

    # Under parameter expressions the default reads the hidden slot, the body the `var`.
    src = "function f(a = arguments){ var arguments; return arguments }"
    tree = resolve(src, resolve: 3)
    assert %Info{slots: %{:arguments => 8, "arguments" => 9}} = info(fun(tree, "f"))
    assert collect(tree, &match?({:aslot, _, _}, &1)) == [{:aslot, 0, 8}]
    assert Resolve.strip(tree) == off(src)
    assert Resolve.check(tree) == :ok

    # Below level 3 the function is not rewritten, so no form is emitted.
    assert collect(
             resolve("function f(){ return arguments }", resolve: 2),
             &match?({:aslot, _, _}, &1)
           ) == []
  end

  # Design 5.2, item 3: `check` asserts statically that an `{:mslot}` lands only where
  # `argmap` has the name, and that no `{:slot}` writes a mapped parameter.
  test "2d. R3: check refuses an {:mslot} without a mapping and a {:slot} write to a mapped parameter" do
    # A strict function maps nothing, so an `{:mslot}` there is wrong.
    tree = resolve("function f(a){ 'use strict'; a = 1; return arguments }", resolve: 3)
    assert Resolve.check(tree) == :ok

    bad =
      swap(
        tree,
        {:sassign, "=", {:slot, 0, 6, "a"}, {:num, 1.0}},
        {:sassign, "=", {:mslot, 0, 6, "a", 0}, {:num, 1.0}}
      )

    assert {:error, _} = Resolve.check(bad)

    # A write to a mapped parameter must sync, so a `{:slot}` write there is wrong.
    tree = resolve("function f(a){ a = 1; return arguments }", resolve: 3)
    assert Resolve.check(tree) == :ok
    assert {:error, _} = Resolve.check(swap(tree, {:mslot, 0, 6, "a", 0}, {:slot, 0, 6, "a"}))
  end

  test "2d. R4: the record on the class node is the default constructor record of design 1.5" do
    for {src, derived?} <- [{"(class A {})", false}, {"(class B extends A {})", true}] do
      [{:class, _, _, [], text}] = classes(off(src))
      expected = %{Resolve.default_ctor_info(derived?, text) | rewritten: true}

      for level <- [3, 4] do
        assert [{:class, _, _, [], ^expected}] = classes(resolve(src, resolve: level)),
               "#{src} at #{level}"
      end

      # At `:info`, 1 and 2 the class node is the node of `:off`.
      for level <- [:info, 1, 2] do
        assert classes(resolve(src, resolve: level)) == classes(off(src)), "#{src} at #{level}"
      end
    end

    # A derived class with an explicit constructor keeps its text.
    src = "(class B extends A { constructor(){ super() } })"
    assert [{:class, _, _, [_], text}] = classes(resolve(src, resolve: 3))
    assert is_binary(text)
  end
end

defmodule Browser.JS.ResolveEnvTest do
  # The application env is the second source of the flag (design 1), and it is global, so
  # this module runs on its own after the async one.
  use ExUnit.Case, async: false

  alias Browser.JS.Parser
  alias Browser.JS.Resolve.Info

  test "the application env is the second source of the flag" do
    Application.put_env(:browser, :js_resolve, :info)
    on_exit(fn -> Application.delete_env(:browser, :js_resolve) end)

    assert {:ok,
            {:program, [{:fundecl, "f", {:fn, "f", [], [], false, %Info{rewritten: false}}}]}} =
             Parser.parse("function f() {}")

    # The parse option comes first.
    assert {:ok, {:program, [{:fundecl, "f", {:fn, "f", [], [], false, "function f() {}"}}]}} =
             Parser.parse("function f() {}", resolve: :off)
  end
end
