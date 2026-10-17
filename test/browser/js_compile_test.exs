Code.require_file("js_compile_corpus.ex", __DIR__)

defmodule Browser.JS.CompileTest do
  # Step 5: closure compilation. A rewritten sync function compiles at its first call into
  # a tree of Elixir closures. The tree walker stays as the reference path. The design is
  # notes/js-step5-design.md, and this file has the tests of its section 5 that need no
  # check build:
  #
  #   * 5.1, the differential oracle: each program runs with compilation off and on, in
  #     fresh processes, and the two runs must agree on every observable item;
  #   * 5.4, the structural tests: the tree rule, the capture rule and the GC rules;
  #   * 5.5, the matrix: the oracle at every resolver level, and the `JS_COMPILE` switch.
  #
  # The oracle alone cannot tell that compilation took place, because two runs of the tree
  # walker also agree. So the tests of the code cache assert that compiled code exists, and
  # that the oracle thus compares the tree walker with real compiled code.
  #
  # The switch is the application setting `:js_compile`, which `Interp.init/1` reads (design
  # 3, "Switch"). The setting is global to the VM, so this module is not async: an async
  # module could start a heap while the oracle has the setting changed.
  use ExUnit.Case, async: false

  alias Browser.JS.{Builtins, GC, Interp, Parser}
  alias Browser.JS.CompileTest.Corpus
  alias Browser.JS.DatamodelCorpus
  alias Browser.JS.Resolve.{Info, Scope}

  # The oracle runs some thousands of programs, and the GC tests trace the collector.
  @moduletag timeout: 900_000

  @levels [:off, :info, 1, 2, 3, 4]

  # A file name gives each statement a position, so `:js_pos` and the lines of
  # `Error.stack` are part of what the two runs must agree on.
  @file_name "t.js"

  # ── the corpus ─────────────────────────────────────────────

  @here __DIR__

  for f <- Corpus.sources(@here), do: @external_resource(f)

  # The snippets of steps 2 to 4, read from their test files, and the programs of
  # bench/js_runtime.exs.
  @tables Corpus.tables(@here)

  # The 20 snippets of the judges' differential runs (design 1.8), as function bodies.
  @judges [
    "var log=[]; var o={get a(){log.push('g'); return 1}, set a(v){log.push('s'+v)}}; o.a += 2; o.a++; return log.join()",
    "function g(){ return h() } function h(){ return new Error('x').stack } return g()",
    "var s=0; outer: for (var i=0;i<5;i++){ for (var j=0;j<5;j++){ if (j==2) continue outer; if (i==3) break outer; s+=j } } return s",
    "try { x; let x = 1 } catch(e) { return e.message }",
    "function r(n){ return r(n+1) } try { r(0) } catch(e) { return e.message }",
    "var o = Object.freeze({a:1}); 'use strict'; function f2(){ 'use strict'; o.a = 2 } try { f2() } catch(e){ return e.message } return 'none'",
    "var o=null; try { o.x } catch(e) { return e.message }",
    "var f3 = undefined; try { f3(1) } catch(e) { return e.message }",
    "var o={}; try { o.m() } catch(e) { return e.message }",
    "var a=[1,2,3]; var k='length'; return a[k] + a.length + ('ab').length + (-0 === 0) + (1/(-0))",
    "var x = 1; switch (x) { case 1: x+=1; case 2: x*=3; break; default: x = 0 } return x",
    "function* g(){ var i=0; while(i<3) yield i++ } var t=0; for (var v of g()) t+=v; return t",
    "function f4(){ return arguments.length + typeof q + typeof f4 } return f4(1,2)",
    "var c=0; var fs=[]; for (let i=0;i<3;i++) fs.push(()=>i); return fs.map(f=>f()).join()",
    "var i=0; while(true){ i++ } return i",
    "var o={a:{b:null}}; return String(o?.a?.b?.c) + (o.z ?? 'd')",
    "function A(){ this.v=1 } A.prototype.get=function(){ return this.v }; var a = new A(); return a.get() + (a instanceof A)",
    "var s=''; for (var k in {x:1,y:2}) s+=k; return s",
    "return [1,2,3].map(function(x){ return x * this.m }, {m:2}).join()",
    "var n = 0; function inc(){ n++ } inc(), inc(); return n + (void 0 === undefined)"
  ]

  # The 14 edge programs of the hot-kinds prototype (design 1.8), as whole scripts.
  @hot_kinds [
    ~S|function f(a){ try { return g(a) } finally { a.x = 1 } } function g(o){ throw new Error("boom " + o.y) } try { f({y: 2}) } catch (e) { console.log(e.stack) }|,
    ~S|function h(n){ if (n == 0) { null.x } return h(n - 1) + 1 } try { h(5) } catch (e) { console.log(String(e), e.stack) }|,
    ~S|function t(){ let x = x + 1 } try { t() } catch (e) { console.log(e.message) }|,
    ~S|function s(v){ outer: for (var i = 0; i < 3; i++) { switch (v + i) { case 1: continue outer; case 2: break outer; default: v++ } } return [v, i] } console.log(JSON.stringify([s(0), s(1), s(5)]))|,
    ~S|function o(a){ return a?.b?.c ?? (a && a.d) } console.log(o(null), o({b:{c:3}}), o({d:4}))|,
    ~S|function c(){ var o = {get x(){ console.log("get"); return 1 }, set x(v){ console.log("set", v) }}; o.x += 2; o.x++; return typeof o.y + typeof zz }; console.log(c())|,
    ~S|function k(){ var a = [1,2,3], s = 0; for (var i in a) { s += a[i] } for (var v of a) s += v; do { s-- } while (s > 10); return s } console.log(k())|,
    ~S|function m(){ var r = []; for (let i = 0; i < 3; i++) r.push(() => i); return r.map(f => f()) } console.log(m().join())|,
    ~S|"use strict"; function st(){ var o = Object.freeze({a: 1}); try { o.a = 2 } catch (e) { return e.constructor.name } } console.log(st())|,
    ~S|function u(x){ return x === 1 ? "one" : x !== 2 ? -x : void 0 } console.log(u(1), u(2), u(3), -0 === 0, 1/u(-0))|,
    ~S|function w(){ var i = 0; while (true) { if (++i > 5) break } return i } console.log(w())|,
    ~S|function nf(){ var x = 1; x() } try { nf() } catch (e) { console.log(e.message) } function nm(){ var o = {}; o.f.g() } try { nm() } catch (e) { console.log(e.message) }|,
    ~S|function sq(){ var a = 1, b = (a++, a++, a); return `${a}-${b}-${typeof a}` } console.log(sq())|,
    ~S|function lp(){ var n = 0; for(;;) { n++ } } lp()|
  ]

  # New edge snippets for step 5. Each one is a script, and the code under test is in a
  # function, because only function bodies compile (design 2.5). A row is `{name, source}`
  # or `{name, source, options}`; the option `max_steps` sets the step limit. The groups
  # follow the list of design 5.1.
  @edges [
    # Mapped `arguments`: a sloppy function maps its parameters to the arguments object,
    # a strict one and one with a default do not.
    {"args map",
     ~S|function f(a, b){ arguments[0] = 9; b = 7; return a + ':' + arguments[1] + ':' + arguments.length } console.log(f(1, 2), f(1))|},
    {"args strict",
     ~S|function f(a){ a = 3; return arguments[0] } function g(a){ "use strict"; a = 3; return arguments[0] } function h(a = 0){ a = 3; return arguments[0] } console.log(f(1), g(1), h(1))|},
    {"args closure",
     ~S|function f(a){ var g = () => arguments[0] + a; a = 5; return g() } function h(){ return Array.prototype.slice.call(arguments, 1).join() } console.log(f(1), h(1, 2, 3))|},
    # TDZ through closures and parameter defaults.
    {"tdz closure",
     ~S|function f(){ var g = () => x; var m; try { g() } catch (e) { m = e.message } let x = 2; return m + ':' + g() } console.log(f())|},
    {"tdz default",
     ~S|function f(a = b, b = 1){ return a } try { f() } catch (e) { console.log(e.constructor.name, e.message) } function g(a, b = a){ return b } console.log(g(4))|},
    {"tdz const fn",
     ~S|function f(){ function g(){ return c } try { g() } catch (e) { console.log(e.message) } const c = 3; return g() } console.log(f())|},
    {"tdz loop",
     ~S|function f(){ let fs = []; for (let i = 0; i < 2; i++) { fs.push(() => j); let j = i * 10 } return fs.map(g => g()).join() } console.log(f())|},
    {"tdz typeof",
     ~S|function f(){ try { typeof q; let q = 1 } catch (e) { return e.constructor.name + ' ' + e.message } } console.log(f())|},
    {"tdz deep",
     ~S|function f(){ let a = 1; return function(){ return function(){ try { return a + b } catch (e) { return e.message } finally { } let b }() }() } console.log(f())|},
    # A getter that throws in `op=` and `++`, and the order of object, key, read and write.
    {"op= getter throws",
     ~S|function f(){ var o = { get a(){ throw new Error('g') }, set a(v){ console.log('set') } }; try { o.a += 1 } catch (e) { console.log(e.message) } try { o.a++ } catch (e) { console.log(e.message) } try { --o.a } catch (e) { console.log(e.message) } } f()|},
    {"op= order",
     ~S|function f(){ var log = []; var o = { get p(){ log.push('get'); return 1 }, set p(v){ log.push('set' + v) } }; function k(){ log.push('key'); return 'p' } function r(){ log.push('rhs'); return 2 } o[k()] += r(); o[k()]++; --o[k()]; o.p *= r(); return log.join() } console.log(f())|},
    {"op= null base",
     ~S|function f(){ var o = null; var log = []; try { o[(log.push('k'), 'x')] += (log.push('r'), 1) } catch (e) { log.push(e.constructor.name, e.message) } try { o.y++ } catch (e) { log.push(e.message) } return log.join() } console.log(f())|},
    {"op= setter throws",
     ~S|function f(){ var o = { get p(){ return 1 }, set p(v){ throw 'nope ' + v } }; try { o.p++ } catch (e) { console.log(e) } try { o.p -= 3 } catch (e) { console.log(e) } } f()|},
    {"op= const",
     ~S|function f(){ const c = 1; try { c += (console.log('rhs'), 1) } catch (e) { console.log(e.constructor.name) } try { c++ } catch (e) { console.log(e.message) } return c } console.log(f())|},
    {"frozen write",
     ~S|function s(){ "use strict"; var o = Object.freeze({a: 1}); try { o.a = 2 } catch (e) { return e.message } } function l(){ var o = Object.freeze({a: 1}); o.a = 2; o.b++; return o.a + ':' + o.b } console.log(s(), l())|},
    {"key conversion",
     ~S|function f(){ var log = []; var k = { toString(){ log.push('ts'); return 'x' } }; var o = {x: 1}; o[k]++; o[k] += 1; var v = o[k]; return log.join() + ':' + o.x + ':' + v } console.log(f())|},
    # NaN and -0 keys.
    {"nan -0 keys",
     ~S|function f(){ var o = {}; o[NaN] = 1; o[NaN]++; o[-0] = 2; o[0] += 3; o[-0]--; o[0/0] *= 2; return JSON.stringify(o) + Object.keys(o).join() } console.log(f())|},
    {"nan -0 arrays",
     ~S|function f(){ var a = []; a[-0] = 1; a['-0'] = 2; a[NaN] = 3; a[1.5] = 4; a[2] = 5; return a.length + ':' + Object.keys(a).join() + ':' + a[0] } console.log(f())|},
    {"nan -0 map",
     ~S|function f(){ var m = new Map(); m.set(NaN, 1); m.set(-0, 2); var s = new Set([NaN, NaN, 0, -0]); return [m.get(NaN), m.get(0), 1 / [...m.keys()][1], s.size].join() } console.log(f())|},
    # `(0, o.f)()`, optional calls and `this`.
    {"comma callee",
     ~S"var o = { f(){ return this === o ? 'o' : typeof this } }; function f(){ return [o.f(), (o.f)(), (0, o.f)(), (o.f || 0)(), o['f']()].join() } console.log(f())"},
    {"comma callee strict",
     ~S|"use strict"; var o = { f(){ return this === o ? 'o' : typeof this } }; function f(){ return [o.f(), (0, o.f)(), (o.f)(), o?.f(), o.f?.(), (o?.f)()].join() } console.log(f())|},
    {"optional call",
     ~S|function f(){ var o = { g: null, h(){ return 1 } }; return [o.g?.(), o.h?.(), o.x?.y.z, o?.["h"](), String(o.g?.().x)].join() } console.log(f())|},
    # A tail sequence and `return a(), b()`.
    {"tail seq",
     ~S|"use strict"; var log = []; function a(){ log.push('a') } function b(){ log.push('b'); return 'b' } function f(){ return a(), b() } function g(n){ return n == 0 ? 'done' : (log.length, g(n - 1)) } console.log(f() + log.join(), g(3000))|},
    {"seq sloppy",
     ~S|function f(){ var x = 1; return x++, x } function g(){ var a = [], i = 0; for (i = 0, a.push(i); i < 3; i++, a.push(i)); return a.join() } console.log(f(), g())|},
    # Logical assignment, which falls back (design 2.2).
    {"logical assign",
     ~S"function f(){ var o = {a: 0, b: 1, c: null}; var log = []; o.a ||= (log.push('a'), 5); o.b ||= (log.push('b'), 6); o.c ??= 7; o.b &&= 8; var x; x ??= 9; let y = 0; y ||= 10; return JSON.stringify(o) + x + y + log.join() } console.log(f())"},
    {"logical assign getters",
     ~S"function f(){ var log = []; var o = { get p(){ log.push('get'); return 1 }, set p(v){ log.push('set' + v) } }; o.p ||= 2; o.p &&= 3; o.p ??= 4; return log.join() } console.log(f())"},
    {"logical assign names",
     ~S"function f(){ var g; g ||= function(){}; var o = {}; o.h ??= () => 1; let k = null; k ??= class {}; return [g.name, o.h.name, k.name].join() } console.log(f())"},
    {"logical assign const",
     ~S"function f(){ const c = 0; try { c ||= 1 } catch (e) { return e.constructor.name } } function g(){ const c = 1; c ||= 2; return c } console.log(f(), g())"},
    # Labels, a labeled continue across a for-of, and the close of its iterators.
    {"labeled continue for-of",
     ~S|function f(){ var log = []; function mk(n){ var i = 0; return {[Symbol.iterator](){ return this }, next(){ return {value: i++, done: i > 3} }, return(){ log.push('close' + n); return {} }} } outer: for (var a of mk('A')) { for (var b of mk('B')) { if (b == 1) continue outer; log.push(a + '' + b) } } return log.join() } console.log(f())|},
    {"labeled blocks",
     ~S|function f(){ var s = ''; a: { b: for (var i = 0; i < 3; i++) { c: { if (i == 1) break c; if (i == 2) break a; s += i } s += 'x' } s += 'no' } return s } console.log(f())|},
    {"labeled while",
     ~S|function f(){ var i = 0, s = ''; w: while (i < 5) { i++; d: do { if (i % 2) continue w; s += i; break d } while (true) } return s } console.log(f())|},
    # A `finally` that overrides a return, a break and a throw.
    {"finally override",
     ~S|function f(){ try { return 'try' } finally { console.log('fin') } } function g(){ try { return 'try' } finally { return 'fin' } } function h(){ try { throw 1 } finally { return 'h' } } console.log(f(), g(), h())|},
    {"finally continue",
     ~S|function f(){ for (var i = 0; i < 3; i++) { try { return i } finally { if (i < 2) continue } } return 'end' } function g(){ var n = 0; while (true) { try { n++; break } finally { if (n < 3) continue } } return n } console.log(f(), g())|},
    {"catch rethrow",
     ~S|function f(){ try { try { throw new TypeError('t') } catch (e) { throw new RangeError(e.message + 'r') } finally { console.log('inner') } } catch (e) { return e.constructor.name + e.message } } console.log(f())|},
    # The depth limit, through calls of every shape, and `Error.stack`.
    {"depth plain",
     ~S|function r(n){ return r(n + 1) + 1 } try { r(0) } catch (e) { console.log(e.constructor.name, e.message, e.stack.split('\n').length) }|},
    {"depth method",
     ~S"var o = { m(n){ return this.m(n + 1) + 1 } }; try { o.m(0) } catch (e) { console.log(e.message, e.stack.split('\n').slice(0, 3).join('|')) }"},
    {"depth arrow",
     ~S|var r = n => 1 + r(n + 1); var d = 0; function g(){ d++; return 1 + g() } try { r(0) } catch (e) { console.log(e.message) } try { g() } catch (e) { console.log(d) }|},
    {"depth catch",
     ~S|var n = 0; function f(){ n++; try { return f() + 1 } catch (e) { return n } } console.log(f(), n)|},
    {"stack lines",
     ~S|function a(n){ if (n == 0) throw new Error('deep'); return b(n - 1) } function b(n){ return a(n) + 0 } try { a(40) } catch (e) { console.log(e.stack) }|},
    {"stack ctor",
     ~S|function P(){ this.s = new Error('p').stack } class Q { constructor(){ this.s = new Error('q').stack } m(){ return new P().s } } function f(){ return new Q().m() + '\n' + new Q().s } console.log(f())|},
    {"uncaught", ~S|function f(){ g() } function g(){ throw new TypeError('top') } f()|},
    {"uncaught string", ~S|function f(){ throw 'str' } f()|},
    # Switch fallthrough, a default in the middle, and `let` in a case.
    {"switch fallthrough",
     ~S|function f(x){ var s = ''; switch (x) { case 0: s += 'a'; case 1: s += 'b'; break; case '1': s += 'str'; default: s += 'd'; case 2: s += 'c' } return s } console.log([0, 1, '1', 2, 3].map(f).join())|},
    {"switch let",
     ~S|function f(x){ switch (x) { case 1: let y = 'one'; return y; case 2: try { return y } catch (e) { return e.constructor.name } } } console.log(f(1), f(2), f(3))|},
    {"switch order",
     ~S|function f(x){ var log = []; function c(v){ log.push('c' + v); return v } switch (x) { case c(1): log.push('one'); case c(2): log.push('two'); break; case c(3): log.push('three') } return log.join() } console.log(f(2), f(3), f(9))|},
    # The step limit, in loops, in recursion and in a finalizer.
    {"steps for", ~S|function f(){ var i = 0; for (;;) { i++ } } f()|, max_steps: 5000},
    {"steps while",
     ~S|function f(){ var i = 0; while (true) { i += g(i) } } function g(x){ return x % 3 } f()|,
     max_steps: 5000},
    {"steps finally", ~S|function f(){ try { for (;;) {} } finally { console.log('fin') } } f()|,
     max_steps: 3000},
    {"steps recursion", ~S|function f(n){ return f(n + 1) + 1 } f(0)|, max_steps: 500},
    {"steps do", ~S|function f(){ var i = 0; do { i++ } while (i > 0) } f()|, max_steps: 4000},
    {"steps for-of", ~S|function f(){ var a = [1]; for (var x of a) { a.push(x) } } f()|,
     max_steps: 4000},
    # Frames that live on after a top-level statement: a forced collection between the
    # statements frees a frame that only compiled code would reach.
    {"live frames",
     ~S|var g = (function(){ var x = {n: 1}; return () => x.n++ })(); g(); var h = (function(a){ let y = [a]; return { get: () => y[0] + g(), set(v){ y[0] = v } } })(5); h.set(7); console.log(h.get(), g())|},
    {"live frames loop",
     ~S|var fs = []; function mk(){ for (let i = 0; i < 3; i++) { let o = {i}; fs.push(() => o.i) } } mk(); var t = fs.map(f => f()).join(); mk(); console.log(t, fs.map(f => f()).join())|},
    {"live counter",
     ~S|function counter(){ var c = 0; return { inc(){ return ++c }, get v(){ return c } } } var a = counter(); a.inc(); var b = counter(); b.inc(); b.inc(); console.log(a.v, b.v, a.inc())|},
    # The writes of a slot that the compiled code makes inline. `x op= v` gives the new
    # value for every operator, and an assignment in the dead zone names its binding.
    {"op= slot value",
     ~S"function f(){ var x = 8, s = []; s.push(x /= 2, x %= 3, x **= 3, x <<= 2, x >>= 1, x >>>= 1, x |= 5, x &= 6, x ^= 3, x -= 1, x *= 3, x += 'a'); var y = 2; var z = (y **= 2) + (y /= 2); return s.join() + ':' + x + ':' + z } console.log(f())"},
    {"tdz assign names",
     ~S|function f(){ var m = []; try { q = 1; let q } catch (e) { m.push(e.message) } try { (() => { s = 2 })(); let s } catch (e) { m.push(e.message) } return m.join('/') } console.log(f())|},
    # A declaration reads its frame after its value, which can write the same frame: at
    # depth 0, and at depth 1 from the frame of a loop or of a block.
    {"decl after value",
     ~S|function f(){ var y = 1; var x = (y = 2, 3); let z = (x += 1, y += 10, x * y); const w = (() => { z = 0; return y })(); var out = [x, y, z, w]; for (const k of [5]) { var a = 1; var b = (a = k, a + 1); let g = () => k; out.push(a, b, g()) } { let c = 0; var h = () => c; var d = (c = 7, y = 1, c + y); out.push(d, h(), y) } return out.join() } console.log(f())|}
  ]

  # One snippet for each kind that the compiler handles, and one for each kind that falls
  # back (design 2.2, 2.3 and 2.5). Each kind is in a function, so that it compiles.
  @kinds [
    {"constants",
     ~S|function f(){ return [1, 1.5, -0, 'a', true, false, null, undefined, 1e21, 0x10, 2n].map(String).join() } console.log(f())|},
    {"slots by depth",
     ~S|function f(a){ var b = a + 1; return function(){ var c = b + 1; return function(){ return function(){ return a + b + c }() }() }() } console.log(f(1))|},
    {"globals",
     ~S|var G = 5; function f(){ G = G + 1; H = 2; return G + H + typeof Nope + typeof Math } console.log(f(), G, H)|},
    {"binary",
     ~S"function f(a, b){ return [a + b, a - b, a * b, a / b, a % b, a ** b, a < b, a > b, a <= b, a >= b, a == b, a === b, a != b, a !== b, a & b, a | b, a ^ b, a << b, a >> b, a >>> b].join() } function g(a, b){ return [a + b, a - b, a * b, a ** b, a < b, a == b, a & b, a << b, a >> b].join() } console.log(f(7, 3), f(-7.5, 2), f('7', 3), f(NaN, 0), g(1n, 2n), g(5n, 1n))"},
    {"binary operand order",
     ~S"function f(){ var log = []; function a(){ log.push('a'); return 6 } function b(){ log.push('b'); return 4 } var o = {valueOf(){ log.push('L'); return 7 }}, p = {valueOf(){ log.push('R'); return 2 }}; var r = [a() + b(), a() - b(), a() * b(), a() / b(), a() % b(), a() ** b(), a() < b(), a() == b(), a() === b(), a() & b(), a() | b(), a() ^ b(), a() << b(), a() >> b(), a() >>> b(), o % p, o / p, o ** p, o | p, o < p, o >= p]; var k = {x: 1}; r.push((log.push('k'), 'x') in (log.push('o'), k), (log.push('v'), k) instanceof (log.push('C'), Object)); return r.join() + ';' + log.join('') } console.log(f())"},
    {"parameters and arguments",
     ~S"function z(){ return arguments.length } function p1(a){ return [a] } function p2(a, b){ return [a, b] } function p3(a, b, c){ return [a, b, c] } function l2(a, b){ var t = a; return [t, b] } function s2(a, b){ 'use strict'; return [typeof this, a, b] } function w2(a, b){ return [this === globalThis, a, b] } function f(){ return [z(), z(1, 2), p1(), p1(1, 2), p2(), p2(1), p2(1, 2, 3), p3(1), p3(1, 2), p3(1, 2, 3, 4), l2(1), l2(), s2(1), w2(), w2.call(5, 1)].map(String).join(';') } console.log(f())"},
    {"binary in instanceof",
     ~S|function f(o){ return ['a' in o, 0 in [1], o instanceof Object, [] instanceof Array, f instanceof Function].join() } console.log(f({a: 1}))|},
    {"binary errors",
     ~S|function f(){ var r = []; try { 1n + 1 } catch (e) { r.push(e.constructor.name) } try { 'a' in 'b' } catch (e) { r.push(e.constructor.name) } try { ({}) instanceof 1 } catch (e) { r.push(e.message) } return r.join() } console.log(f())|},
    {"unary",
     ~S|function f(x){ return [-x, +x, !x, ~x, typeof x, void x, - -x].join() } console.log(f(3), f('4'), f(''), f(null), f({}))|},
    {"logical",
     ~S"function f(a, b){ return [a && b, a || b, a ?? b, !a && !b, a || b && 'c'].join('|') } console.log(f(0, 1), f(null, 'x'), f('a', 0), f(undefined, undefined))"},
    {"conditional",
     ~S|function f(x){ return x > 1 ? 'big' : x < -1 ? 'neg' : x === 0 ? 'zero' : 'small' } console.log([2, -2, 0, 1, NaN].map(f).join())|},
    {"member",
     ~S|function f(o, k){ return [o.a, o['a'], o[k], o.length, o[0], o.b.c, o['b']['c'], o.missing].join() } function g(a, i){ return [a.length, a[0], a[i], a['length'], a.x, a[-1]].join() } console.log(f({a: 1, b: {c: 2}, 0: 'z', length: 9}, 'a'), f({a: 'x', b: {}}, 'length'), g([5, 6], 1), g('st', 1))|},
    {"member errors",
     ~S|function f(o){ try { return o.x } catch (e) { return e.message } } function g(o){ try { o.x = 1 } catch (e) { return e.message } } console.log(f(null), f(undefined), g(null), g(undefined))|},
    {"optional member",
     ~S"function f(o){ return [o?.a, o?.a?.b, o?.['a'], o?.a.b?.c].join('|') } console.log(f(null), f({a: {b: {c: 1}}}), f({a: {}}))"},
    {"call shapes",
     ~S|function f0(){ return arguments.length } function f(){ var o = { m(a, b, c){ return [this === o, a, b, c].join() } }; return [f0(), f0(1), f0(1, 2), f0(1, 2, 3), f0(...[1, 2], 3), o.m(1, 2, 3), o.m(...'ab')].join(';') } console.log(f())|},
    {"call errors",
     ~S"function f(){ var r = []; var o = {}; var n = null; try { o.m() } catch (e) { r.push(e.message) } try { n() } catch (e) { r.push(e.message) } try { (1)() } catch (e) { r.push(e.message) } try { o.a.b() } catch (e) { r.push(e.message) } return r.join('|') } console.log(f())"},
    {"call order",
     ~S|function f(){ var log = []; function a(){ log.push('a'); return 1 } var o = { get m(){ log.push('m'); return function(x, y){ log.push('call'); return x + y } } }; var r = o.m(a(), (log.push('b'), 2)); return r + log.join() } console.log(f())|},
    {"new",
     ~S|function P(x){ this.x = x } function Q(){ return {q: 1} } function R(){ return 5 } function f(){ return [new P(1).x, new Q().q, new R() instanceof R, new P(2) instanceof P, new.target === undefined].join() } console.log(f())|},
    {"assign",
     ~S|function f(){ var a, o = {}, arr = []; a = 1; o.x = a; o['y'] = 2; arr[0] = 3; arr.length = 5; G2 = 4; var c = (a = 6); return [a, o.x, o.y, arr.length, G2, c].join() } console.log(f())|},
    {"compound",
     ~S"function f(){ var a = 1, o = {x: 1}, arr = [1]; a += 2; a -= 1; a *= 3; a /= 2; a %= 2; a **= 3; a <<= 2; a >>= 1; a >>>= 0; a |= 8; a &= 12; a ^= 5; o.x += 'q'; arr[0] -= 5; return [a, o.x, arr[0]].join() } console.log(f())"},
    {"update",
     ~S|var g = 1; function f(){ var a = 1, o = {x: 1}, arr = [1], s = '5'; return [a++, ++a, a--, --a, o.x++, ++o.x, arr[0]--, --arr[0], s++, s, g++, ++g, typeof (o.y++), o.y].join() } console.log(f())|},
    {"array object template",
     ~S"function f(a){ var x = [a, , a + 1, ...[a + 2]]; var o = {a, b: x.length, 'c': 1, 1: 2}; return `${x}|${JSON.stringify(o)}|${a}${'s'}` } console.log(f(1))"},
    {"this",
     ~S|function f(){ return typeof this } function g(){ "use strict"; return typeof this } var o = { h(){ return this === o } }; console.log(f(), g(), o.h(), f.call(5), g.call(5))|},
    {"var let const",
     ~S|function f(){ var a = 1; let b = 2; const c = 3; var d; let e; { let b = 20; var a2 = b } return [a, b, c, d, e, a2].join() } console.log(f())|},
    {"if",
     ~S|function f(x){ if (x) { return 'a' } else if (x === 0) return 'b'; else { if (x === null) return 'c' } return 'd' } console.log([1, 0, null, undefined].map(f).join())|},
    {"return tail",
     ~S|"use strict"; function g(x){ return x * 2 } function f(x){ if (x > 0) return g(x); return x ? g(1) : g(-1) } console.log(f(3), f(0))|},
    {"blocks",
     ~S|function f(){ var s = ''; { s += 'a'; { s += 'b' } } { let x = 'c'; s += x; { const y = x + 'd'; s += y } } { function inner(){ return 'e' } s += inner() } return s } console.log(f())|},
    {"framed block",
     ~S|function f(){ var fs = []; { let x = 1; fs.push(() => x); x = 2 } { let y = 3; fs.push(() => y) } return fs.map(g => g()).join() } console.log(f())|},
    {"for",
     ~S|function f(){ var s = 0; for (var i = 0; i < 5; i++) { if (i == 3) continue; s += i } for (let j = 0, k = 10; j < k; j += 4) s += j; for (;;) { break } return s } console.log(f())|},
    {"for framed",
     ~S|function f(){ var fs = []; for (let i = 0; i < 3; i++) { fs.push(() => i); i += 0 } for (let i = 0, g = () => i; i < 2; i++) fs.push(g); return fs.map(g => g()).join() } console.log(f())|},
    {"while do-while",
     ~S|function f(){ var i = 0, s = ''; while (i < 3) { s += i++ } do { s += 'd'; i-- } while (i > 1); while (false) {} return s } console.log(f())|},
    {"for-in",
     ~S|function f(){ var o = {a: 1, b: 2}; Object.defineProperty(o, 'h', {value: 3, enumerable: false}); var p = Object.create(o); p.c = 4; var s = ''; for (var k in p) s += k; for (let k in [7, 8]) s += k; try { for (k in 'xy') s += k } catch (e) { s += e.constructor.name } for (k in new String('xy')) s += k; return s } console.log(f())|},
    {"for-of",
     ~S|function f(){ var s = ''; for (var x of [1, 2]) s += x; for (const c of 'ab') s += c; for (let [k, v] of new Map([[1, 2]])) s += k + v; for (x of new Set([9])) s += x; return s } console.log(f())|},
    {"throw try",
     ~S|function f(x){ try { if (x) throw new Error('e' + x); return 'ok' } catch ({message}) { return message } finally { console.log('f' + x) } } function g(){ try { throw 1 } catch { return 'nobind' } } console.log(f(0), f(1), g())|},
    {"typeof undeclared",
     ~S|function f(){ return [typeof undeclaredName, typeof f, typeof null, typeof [], typeof 1n, typeof Symbol()].join() } console.log(f())|},
    {"empty and fundecl",
     ~S|function f(){ ;;; function g(){ return h() } function h(){ return 'h' } ; return g() } console.log(f())|},
    {"strict sloppy writes",
     ~S|function f(){ "use strict"; try { undeclared1 = 1 } catch (e) { return e.constructor.name } } function g(){ undeclared2 = 2; return undeclared2 } console.log(f(), g())|},
    # The kinds that fall back to the tree walker.
    {"fallback fn class",
     ~S|function f(){ var g = function(x){ return x + 1 }; var h = x => x * 2; class K { constructor(v){ this.v = v } get d(){ return this.v * 2 } static s(){ return 's' } } return [g(1), h(2), new K(3).d, K.s(), g.name, h.name, K.name].join() } console.log(f())|},
    {"fallback regex delete",
     ~S|function f(){ var o = {a: 1, b: 2}; delete o.a; var r = /a(b)?/g; var m = 'xab'.match(r); return [Object.keys(o).join(), m.join(), r.lastIndex, delete o.zz].join(';') } console.log(f())|},
    {"fallback super private",
     ~S|class A { m(){ return 'A' } } class B extends A { #p = 1; static #s = 2; m(){ return super.m() + this.#p + B.#s } has(o){ return #p in o } } function f(){ var b = new B(); return b.m() + b.has(b) + b.has({}) } console.log(f())|},
    {"fallback tagged",
     ~S"function tag(s, ...v){ return s.raw.join('|') + v.join() } function f(x){ return tag`a${x}b\n${x + 1}` + String.raw`\t` } console.log(f(1))"},
    {"fallback object forms",
     ~S|function f(k){ var o = { m(){ return 1 }, get g(){ return 2 }, set g(v){ this._g = v }, [k]: 3, [k + 2]: 4, ...{s: 5} }; o.g = 6; return JSON.stringify(o) + o.m() + o.g } console.log(f('c'))|},
    {"fallback patterns",
     ~S|function f({a, b: [c, d = 4] = []}, ...rest){ var {x = 1, ...y} = {z: 2}; let [p, , q = 5] = [1]; [p, q] = [q, p]; ({a: x} = {a: 7}); return [a, c, d, rest.length, x, JSON.stringify(y), p, q].join() } console.log(f({a: 1, b: [3]}, 8, 9))|},
    {"fallback eval with",
     ~S|function f(){ var x = 1; return eval('x + 1') } function g(o){ with (o) { return a + b } } function h(){ return (0, eval)('typeof x') } console.log(f(), g({a: 1, b: 2}), h())|},
    {"fallback new Function",
     ~S|function f(){ var g = new Function('a', 'b', 'return a * b'); var s = 0; for (var i = 0; i < 5; i++) s += new Function('return ' + i)(); return g(3, 4) + s } console.log(f())|},
    {"eval inner fn",
     ~S|function f(){ var k = eval('(function(n){ var t = 0; for (var i = 0; i < n; i++) t += i; return t })'); return k(5) + k(6) } console.log(f())|},
    {"generator async callees",
     ~S|function sq(x){ return x * x } function* g(){ for (var i = 0; i < 3; i++) yield sq(i) } async function a(){ var t = 0; for (var v of g()) t += sq(await v); return t } a().then(v => console.log(v)); console.log([...g()].join())|},
    {"getter setter calls",
     ~S|class C { constructor(){ this._v = 1 } get v(){ return this._v } set v(x){ this._v = x * 2 } } function f(){ var c = new C(); c.v = 3; c.v += 1; c.v++; return c.v } console.log(f())|},
    {"bind call apply",
     ~S|function f(a, b){ return [this && this.k, a, b].join() } function g(){ var o = {k: 'o'}; return [f.call(o, 1, 2), f.apply(o, [3, 4]), f.bind(o, 5)(6)].join(';') } console.log(g())|}
  ]

  # One object of each class, read and written with constant keys (design 5.4, "Classes").
  # The compiler sends a constant key that is not an array index (also "length") to
  # `get_named/2` and `put_named/3`, and every other key to `get/2` and `put/3`. The two
  # runs must agree for every class.
  @classes [
    {"class primitive receivers",
     ~S|function f(){ var log = []; [Number, String, Boolean].forEach(function (C) { Object.defineProperty(C.prototype, 'x', {set(v){ log.push(typeof this + ':' + v) }, configurable: true}) }); (1.5).x = 1; 'abc'.x = 2; true.x = 3; (1.5).y = 4; 'abc'.length = 5; var s = (function(){ 'use strict'; try { 'abc'.y = 6; return 'no' } catch (e) { return e.name } })(); [Number, String, Boolean].forEach(function (C) { delete C.prototype.x }); return [log.join(), (1.5).y, s].join(';') } console.log(f())|},
    {"class plain",
     ~S|function f(){ var o = {a: 1}; var p = Object.create(o); p.b = 2; o.a = 3; return [p.a, p.b, p.c, o.constructor === Object, p.hasOwnProperty('a')].join() } console.log(f())|},
    {"class array",
     ~S|function f(){ var a = [1, 2]; a.x = 'x'; a.length = 4; a[5] = 6; var k = 'length'; return [a.length, a.x, a[0], a[k], a['1'], a.push(7), a.length, Array.isArray(a)].join() } console.log(f())|},
    {"class function",
     ~S|function g(a, b){} function f(){ g.extra = 1; var b = g.bind(null); return [g.name, g.length, g.extra, typeof g.prototype, b.name, b.length, (() => 1).prototype].join() } console.log(f())|},
    {"class proxy",
     ~S|function f(){ var log = []; var p = new Proxy({a: 1}, { get(t, k, r){ log.push('get ' + String(k)); return Reflect.get(t, k, r) }, set(t, k, v){ log.push('set ' + k); t[k] = v * 2; return true } }); p.a = 5; p.b += 1; return [p.a, p.length, log.join()].join(';') } console.log(f())|},
    {"class host",
     ~S|function f(){ var m = new Map([[1, 2]]); var d = new Date(0); var e = new Error('m'); e.code = 7; return [m.size, typeof d.getTime, e.message, e.code, Math.PI > 3, JSON.stringify.length, globalThis.Infinity].join() } console.log(f())|},
    {"class typed array",
     ~S|function f(){ var t = new Uint8Array(4); t[0] = 300; t.x = 1; t[9] = 5; t.length = 9; var k = 'length'; return [t[0], t.x, t[9], t.length, t[k], t.byteLength, t.buffer.byteLength].join() } console.log(f())|},
    {"class string wrapper",
     ~S|function f(){ var s = new String('ab'); s.x = 1; s.length = 5; s[0] = 'z'; return [s.length, s.x, s[0], s[1], typeof s, 'cd'.length, 'cd'[1], 'cd'.x, (5).x, true.y].join() } console.log(f())|},
    {"class strict writes",
     ~S|"use strict"; function f(){ var r = []; var s = new String('ab'); try { s.length = 5 } catch (e) { r.push(e.constructor.name) } try { 'ab'.x = 1 } catch (e) { r.push(e.constructor.name) } var a = Object.freeze([1]); try { a.length = 0 } catch (e) { r.push(e.constructor.name) } try { a.q = 0 } catch (e) { r.push(e.constructor.name) } return r.join() } console.log(f())|}
  ]

  # The new programs. The step limits are those of the scripts that ran the judges' and
  # the hot-kinds programs first, so that a program that loops for ever stops.
  @judge_rows for {src, i} <- Enum.with_index(@judges),
                  do: {"judge #{i}", Corpus.bench_wrap(src), [max_steps: 200_000]}

  @hot_kinds_rows for {src, i} <- Enum.with_index(@hot_kinds),
                      do: {"hot-kinds #{i}", src, [max_steps: 50_000]}

  # The matrix runs these programs at every level, and the structural tests read the code
  # that they compile.
  @small @judge_rows ++ @hot_kinds_rows ++ Enum.map(@edges ++ @kinds ++ @classes, &Corpus.row/1)

  # Every program of the oracle, as `{name, source, options}`: the new programs, the
  # programs of the data-model step (`Browser.JS.DatamodelCorpus`) and the tables. A source
  # that two tables share runs once, and the new programs come first, so that their step
  # limits apply. `Corpus.programs/1` gives the same list to the fast-path oracle.
  @corpus Enum.uniq_by(
            @small ++ DatamodelCorpus.rows() ++ for({n, s} <- @tables, do: {n, s, []}),
            &elem(&1, 1)
          )

  # ── the runner ─────────────────────────────────────────────

  # Runs each program of `programs` with compilation off and then on, and gives the pairs
  # of outcomes. All runs of one mode run together, because the switch is one setting of
  # the VM. The runs of a mode go in parallel: each run has a process and a heap of its own.
  defp both(programs, opts) do
    off = run_all(programs, false, opts)
    on = run_all(programs, true, opts)
    Enum.zip([programs, off, on])
  end

  defp run_all(programs, compile?, opts) do
    with_compile(compile?, fn ->
      programs
      |> Task.async_stream(fn {_, src, o} -> run(src, Keyword.merge(opts, o)) end,
        timeout: :infinity,
        ordered: true,
        max_concurrency: System.schedulers_online()
      )
      |> Enum.map(fn {:ok, outcome} -> outcome end)
    end)
  end

  # Runs `fun` with the switch set to `compile?`. `Interp.init/1` reads the setting, so it
  # applies to each heap that starts in `fun`.
  defp with_compile(compile?, fun), do: with_env(:js_compile, compile?, fun)

  # Runs `fun` with the application setting `key` set to `value`, and puts the old
  # setting back after it.
  defp with_env(key, value, fun) do
    old = Application.fetch_env(:browser, key)
    Application.put_env(:browser, key, value)

    try do
      fun.()
    after
      case old do
        {:ok, v} -> Application.put_env(:browser, key, v)
        :error -> Application.delete_env(:browser, key)
      end
    end
  end

  # Runs one program in a fresh process, as `Browser.JS.eval/2` does, and gives its
  # outcome: the items that the two runs must agree on (design 5.1) and the count of
  # compiled bodies in the cache, which is not compared. The options are:
  #
  #   * `:level` - the resolver level (default 4);
  #   * `:max_steps` - the step limit (default 1_000_000, as `Browser.JS.eval/2`);
  #   * `:gc` - when true, a forced collection runs before each top-level statement after
  #     the first, and once after the script;
  #   * `:before` - a function that runs in the new process after the built-ins exist;
  #   * `:inspect` - a function that runs in the process at the end, with the heap still
  #     there. Its result is the `:inspect` item of the outcome, which is not compared.
  defp run(src, opts) do
    level = Keyword.get(opts, :level, 4)

    case Parser.parse(src, resolve: level, file: @file_name) do
      {:error, msg} ->
        %{items: %{syntax: msg}, compiled: 0, inspect: nil}

      {:ok, program} ->
        program = if opts[:gc], do: with_gc(program, level), else: program
        in_process(fn -> execute(program, opts) end)
    end
  end

  defp in_process(fun) do
    parent = self()
    ref = make_ref()

    {pid, mon} =
      :erlang.spawn_opt(fn -> send(parent, {ref, fun.()}) end, [
        :monitor | Browser.JS.process_opts()
      ])

    receive do
      {^ref, outcome} ->
        Process.demonitor(mon, [:flush])
        outcome

      {:DOWN, ^mon, _, _, reason} ->
        %{items: %{crash: inspect(reason, limit: 30)}, compiled: 0, inspect: nil}
    after
      120_000 ->
        Process.exit(pid, :kill)
        %{items: %{timeout: true}, compiled: 0, inspect: nil}
    end
  end

  defp execute(program, opts) do
    Interp.init(Keyword.get(opts, :max_steps, 1_000_000))
    Builtins.install()

    # The collection runs from a native function, which gives the completion value back,
    # so the forced collections do not change the value of the script.
    if opts[:gc] do
      gc = Interp.native("__gc", fn _this, _args -> collect_last() end)
      Interp.declare(Interp.global(), "__gc", gc)
    end

    if before = opts[:before], do: before.()

    result =
      try do
        v = Interp.run_program(program, true)
        # The result is a root while the last collection runs, because only this
        # function holds it.
        Process.put(:compile_test_result, v)
        if opts[:gc], do: GC.collect()

        try do
          Builtins.run_timers(&uncaught/1)
        catch
          :js_limit -> console_line(:warn, "step limit reached while running timers")
        end

        Interp.check_dangling(v)
        {:ok, v}
      catch
        {:js_error, v} -> {:throw, v}
        :js_limit -> :step_limit
        {:js_illegal, kind} -> {:illegal, kind}
        :js_short -> :short
      end

    # The counters are read first, because the export of the result can call a getter,
    # which counts steps.
    items = %{
      steps: :erlang.get(:js_steps),
      next: :erlang.get(:js_next),
      heap_n: Browser.JS.Interp.heap_size(),
      pos: Process.get(:js_pos),
      throw_pos: Process.get(:js_throw_pos),
      console: Enum.reverse(Process.get(:js_console, []))
    }

    items = Map.put(items, :result, safely(fn -> outcome(result) end))
    inspect_result = if f = opts[:inspect], do: f.()

    %{items: items, compiled: length(cache()), inspect: inspect_result}
  end

  defp collect_last do
    GC.collect()
    Process.get(:js_last, :undefined)
  end

  defp uncaught(v), do: console_line(:error, "Uncaught " <> describe(v))

  defp console_line(level, text),
    do: Process.put(:js_console, [{level, text} | Process.get(:js_console, [])])

  defp outcome({:ok, v}), do: {:ok, export(v, 0)}
  defp outcome({:throw, v}), do: {:throw, describe(v), export(v, 0)}
  defp outcome(other), do: other

  defp safely(fun) do
    fun.()
  catch
    kind, reason -> {:export_failed, kind, inspect(reason, limit: 10)}
  end

  defp describe(v) when is_binary(v), do: v
  defp describe(v), do: Builtins.inspect_js(v, 0, [])

  # The export of `Browser.JS.eval/2`: JavaScript values as plain data.
  defp export({:obj, _} = v, depth) do
    cond do
      depth > 20 -> :truncated
      Interp.function?(v) -> :function
      Interp.array?(v) -> v |> Interp.array_list() |> Enum.map(&export(&1, depth + 1))
      true -> Map.new(Interp.own_keys(v), &{&1, export(Interp.get(v, &1), depth + 1)})
    end
  end

  defp export(v, _), do: v

  # The program with a call of `__gc()` before each top-level statement after the first.
  # A `{:pos}` node stays with the statement after it. The call is parsed at the level of
  # the program, so that it has the shape of any other call at that level.
  defp with_gc({:program, stmts}, level) do
    {:ok, {:program, gc}} = Parser.parse("__gc();", resolve: level)
    gc = Enum.reject(gc, &match?({:pos, _}, &1))

    {out, pending, _} =
      Enum.reduce(stmts, {[], [], false}, fn
        {:pos, _} = p, {out, pending, seen?} ->
          {out, [p | pending], seen?}

        s, {out, pending, seen?} ->
          out = if seen?, do: Enum.reverse(gc) ++ out, else: out
          {[s | pending] ++ out, [], true}
      end)

    {:program, Enum.reverse(pending ++ out)}
  end

  # The entries of the code cache of this process (design 3, "Cache").
  defp cache, do: for({{:jsc, _}, v} <- Process.get(), do: v)

  # Fails with each program whose two runs do not agree.
  defp assert_same(pairs, what) do
    bad =
      for {{name, src, _}, off, on} <- pairs, off.items != on.items do
        diff =
          for k <- Enum.sort(Enum.uniq(Map.keys(off.items) ++ Map.keys(on.items))),
              Map.get(off.items, k) != Map.get(on.items, k),
              do:
                "    #{k}: off #{inspect(Map.get(off.items, k), limit: 12, printable_limit: 300)}\n" <>
                  "    #{String.duplicate(" ", String.length(to_string(k)))}  on  #{inspect(Map.get(on.items, k), limit: 12, printable_limit: 300)}"

        diff = Enum.join(diff, "\n")

        "#{name}: #{String.slice(src, 0, 160)}\n#{diff}"
      end

    assert bad == [],
           "#{length(bad)} of #{length(pairs)} programs differ #{what}:\n\n" <>
             Enum.join(Enum.take(bad, 15), "\n\n")
  end

  # ── 5.1: the differential oracle ───────────────────────────

  describe "5.1: the differential oracle at level 4" do
    test "the corpus gives the same result, console, steps, heap ids, heap count and position" do
      assert length(@corpus) > 600
      assert_same(both(@corpus, []), "with compilation on")
    end

    test "the same with a forced collection before each top-level statement" do
      # A compiled fun that held a frame id would keep that frame from the collector's
      # walk. The collection then frees a live frame, and the oracle sees the difference.
      assert_same(both(@corpus, gc: true), "with the forced collections")
    end

    test "the snippets of the corpus are not all the same program" do
      # A broken runner gives one outcome for every program and so passes the oracle. This
      # test proves that the runner reports results, errors, the step limit and the console.
      outcomes = for {_, off, _} <- both(@small, []), do: off.items

      assert Enum.any?(outcomes, &match?(%{result: {:ok, _}, console: [_ | _]}, &1))
      assert Enum.any?(outcomes, &match?(%{result: {:throw, "TypeError: top" <> _, _}}, &1))
      assert Enum.any?(outcomes, &match?(%{result: :step_limit}, &1))
      assert Enum.any?(outcomes, &match?({@file_name, _}, Browser.JS.Pos.decode(&1.pos)))
      assert outcomes |> Enum.map(& &1.steps) |> Enum.uniq() |> length() > 50
    end

    test "with compilation on, the corpus fills the code cache, and with it off, it does not" do
      pairs = both(@small, [])
      assert Enum.all?(pairs, fn {_, off, _} -> off.compiled == 0 end)
      compiled = for {{n, _, _}, _, on} <- pairs, on.compiled > 0, do: n
      # Every new snippet calls a function, except the ones whose code is all top level.
      assert length(compiled) > div(length(pairs) * 3, 4), "compiled only: #{inspect(compiled)}"
    end
  end

  # ── 5.4: structural tests ──────────────────────────────────

  # A function `f` with `n` statements `if (x < k) { t += k } else { t -= 1 }` and a
  # final return. The design that the judges rejected shared the rest of the list between
  # the two arms of each `if`, which doubles the flat size for each `if`.
  defp ifs(n) do
    body = for k <- 1..n, into: "", do: " if (x < #{k}) { t += #{k} } else { t -= 1 }"
    "function f(x){ var t = 0;" <> body <> " return t } f(0); f(#{n})"
  end

  # The flat size and the shared size of each entry of the code cache, after `src` ran
  # with compilation on, and the flat size of the program.
  defp code_sizes(src, opts \\ []) do
    {:ok, program} = Parser.parse(src, resolve: 4, file: @file_name)

    sizes = fn -> for c <- cache(), do: {:erts_debug.flat_size(c), :erts_debug.size(c)} end

    outcome =
      with_compile(true, fn ->
        in_process(fn -> execute(program, Keyword.put(opts, :inspect, sizes)) end)
      end)

    {outcome.inspect, :erts_debug.flat_size(program)}
  end

  describe "5.4: the tree rule" do
    test "each compiled body has a flat size of at most 3 times its shared size plus its syntax" do
      # The syntax of the whole program is a bound for the syntax of each function body.
      for {name, src, opts} <- @small do
        {sizes, ast} = code_sizes(src, opts)

        for {flat, size} <- sizes || [] do
          assert flat <= 3 * size + ast, "#{name}: flat #{flat}, shared #{size}, syntax #{ast}"
        end
      end

      {sizes, _} = code_sizes(ifs(20))
      assert sizes != [], "the function with 20 ifs did not compile"
    end

    test "the compiled size of a chain of ifs is linear in the number of ifs" do
      # The small chains run first. If the code were a DAG with shared arms, the flat size
      # of 300 ifs would be about 2^300 words, and the flat walk would not end.
      flat = fn n ->
        {[{flat, size}], ast} = code_sizes(ifs(n))
        assert flat <= 3 * size + ast, "#{n} ifs: flat #{flat}, shared #{size}, syntax #{ast}"
        flat
      end

      f10 = flat.(10)
      f20 = flat.(20)
      assert f20 <= 3 * f10, "10 ifs: #{f10} words, 20 ifs: #{f20} words"
      f300 = flat.(300)
      # Linear growth gives 15 times the size of 20 ifs, plus the cost of one function.
      assert f300 <= 20 * f20, "20 ifs: #{f20} words, 300 ifs: #{f300} words"
    end
  end

  # Every captured value in `term` that compiled code must not hold (design 2.1, the
  # capture rule): an object reference, a `{:val}` node, a frame, and an integer in the
  # range of the heap ids of the program. The walk goes into the environment of every fun.
  defp bad_captures(term, ids) do
    walk([term], ids, [], 0)
  end

  defp walk([], _ids, acc, _n), do: acc
  # A huge term would be a failure of the tree rule, which its own test reports.
  defp walk(_, _ids, acc, n) when n > 5_000_000, do: [:walk_too_long | acc]

  defp walk([t | rest], ids, acc, n) do
    case t do
      {:obj, id} when is_integer(id) ->
        walk(rest, ids, [t | acc], n + 1)

      {:val, _} ->
        walk(rest, ids, [t | acc], n + 1)

      t when is_tuple(t) and tuple_size(t) >= 5 ->
        if (is_integer(elem(t, 0)) or elem(t, 0) == nil) and
             (is_struct(elem(t, 1), Info) or is_struct(elem(t, 1), Scope)),
           do: walk(rest, ids, [{:frame, elem(t, 1).__struct__} | acc], n + 1),
           else: walk(Tuple.to_list(t) ++ rest, ids, acc, n + 1)

      t when is_tuple(t) ->
        walk(Tuple.to_list(t) ++ rest, ids, acc, n + 1)

      [h | tl] ->
        walk([h, tl | rest], ids, acc, n + 1)

      t when is_map(t) ->
        walk(Map.keys(t) ++ Map.values(t) ++ rest, ids, acc, n + 1)

      t when is_function(t) ->
        {:env, env} = :erlang.fun_info(t, :env)
        walk(env ++ rest, ids, acc, n + 1)

      t when is_integer(t) ->
        if t in ids,
          do: walk(rest, ids, [{:heap_id, t} | acc], n + 1),
          else: walk(rest, ids, acc, n + 1)

      _ ->
        walk(rest, ids, acc, n + 1)
    end
  end

  # The heap ids of a program start here, far above every small integer that compiled
  # code may hold: slot indices, depths, line numbers and counts.
  @id_base 1_000_000_000_000

  # Moves the next heap id to `@id_base`. The heap count is the ids given out minus the
  # entries taken away (`Interp.heap_size/0`), so the moved ids count as taken away and the
  # count stays the same.
  defp move_heap_ids do
    next = :erlang.get(:js_next)
    :erlang.put(:js_next, @id_base)
    :erlang.put(:js_freed, :erlang.get(:js_freed) + @id_base - next)
  end

  describe "5.4: the capture rule" do
    test "compiled code holds no object, no frame, no {:val} node and no heap id" do
      results =
        with_compile(true, fn ->
          for {name, src, opts} <- @small ++ [{"ifs", ifs(20), []}] do
            {:ok, program} = Parser.parse(src, resolve: 4, file: @file_name)

            o =
              in_process(fn ->
                execute(
                  program,
                  Keyword.merge(opts,
                    before: &move_heap_ids/0,
                    inspect: fn ->
                      ids = @id_base..(:erlang.get(:js_next) - 1)//1
                      bad = cache() |> bad_captures(ids) |> Enum.uniq() |> Enum.take(5)
                      {length(cache()), bad}
                    end
                  )
                )
              end)

            {name, o.inspect}
          end
        end)

      # The test proves nothing unless the walk saw compiled code.
      assert Enum.sum(for {_, {n, _}} <- results, do: n) > 100
      assert for({name, {_, bad}} <- results, bad != [], do: {name, bad}) == []
    end

    test "the moved heap ids leave the outcome of a program as it was" do
      # The capture test moves the first heap id of the program. This proves that the move
      # changes nothing that the program can see, so that its runs are valid runs.
      for {name, src, opts} <- Enum.take(@small, 40) do
        {:ok, program} = Parser.parse(src, resolve: 4, file: @file_name)
        plain = in_process(fn -> execute(program, opts) end)

        moved =
          in_process(fn ->
            execute(
              program,
              Keyword.put(opts, :before, &move_heap_ids/0)
            )
          end)

        assert Map.drop(plain.items, [:next]) == Map.drop(moved.items, [:next]), name
      end
    end
  end

  # The number of calls of `GC.mark/2` and `GC.push/3` in one collection. Each item that
  # the walk looks at is one call of `mark/2`, and each edge is one call of `push/3`. The
  # count is for all processes, which is safe because this module is not async.
  defp gc_calls(fun) do
    mfas = [{GC, :mark, 2}, {GC, :push, 3}]
    # A pattern on a module that is not loaded yet matches nothing.
    Code.ensure_loaded!(GC)
    for mfa <- mfas, do: 1 = :erlang.trace_pattern(mfa, true, [:call_count])

    try do
      fun.()

      for mfa <- mfas do
        {:call_count, n} = :erlang.trace_info(mfa, :call_count)
        n
      end
    after
      for mfa <- mfas, do: :erlang.trace_pattern(mfa, false, [:call_count])
    end
  end

  # Runs `src` and then `fun` in its process, with compilation on or off, and gives the
  # result of `fun` and the size of the cache.
  defp in_heap(src, compile?, fun) do
    {:ok, program} = Parser.parse(src, resolve: 4, file: @file_name)

    outcome =
      with_compile(compile?, fn ->
        in_process(fn -> execute(program, max_steps: 100_000_000, inspect: fun) end)
      end)

    {outcome.inspect, outcome.compiled}
  end

  # A program whose code is large: ten functions of 300 ifs each, called once each. A
  # closure keeps each function alive.
  @big_code (for i <- 1..10, into: "var keep = []; " do
               body = for k <- 1..300, into: "", do: " if (x < #{k}) { t += #{k} }"

               "function g#{i}(x){ var t = 0;#{body} return t } keep.push(g#{i}(#{i}), () => g#{i}); "
             end)

  # An async function that waits for a promise that nothing resolves until the second
  # script. Its body has 20 ifs after the await, and it calls a sync function with 20
  # ifs before the await, so that the cache has code while the function is suspended.
  @suspended (fn ->
                ifs = for k <- 1..20, into: "", do: " if (v < #{k}) { t += #{k} } else { t -= 1 }"

                "var resume, box = {}; function pick(v){ var t = 0;#{ifs} return t } " <>
                  "async function run(){ var t = pick(3); var v = await new Promise(r => { resume = r });#{ifs} return t + pick(v) } " <>
                  "run().then(x => { box.v = x })"
              end).()

  describe "5.4: the GC rules" do
    test "one collection walks the same items with compilation on and off" do
      # The collector skips the `{:jsc, _}` keys and the funs of `Browser.JS.Compile`
      # (design 3, "GC"). Then the code of 3000 ifs adds nothing to the walk. A few
      # calls of slack allow a new counter in the process dictionary, which is a root.
      {off, _} = in_heap(@big_code, false, fn -> gc_calls(&GC.collect/0) end)
      {on, compiled} = in_heap(@big_code, true, fn -> gc_calls(&GC.collect/0) end)

      for {a, b} <- Enum.zip(off, on) do
        assert abs(a - b) <= 8,
               "calls of mark/2 and push/3: off #{inspect(off)}, on #{inspect(on)}, " <>
                 "#{compiled} bodies in the cache"
      end
    end

    test "a suspended async function with compiled callees collects fast and resumes" do
      # Judge 2 found that a suspended async function can hold compiled code in its
      # continuation, and that a walk of that code took 1.49 s. Since step 5c the body of
      # the async function compiles too. Its continuation is a fun of `Browser.JS.Async`,
      # which keeps the frame and the compiled closures of the 20 ifs after the await.
      # Rule 2 of `Browser.JS.GC` skips the funs of `Browser.JS.Compile`, so the walk stops
      # at these closures. Without compilation the continuation keeps the tree nodes of
      # the rest of the body, which the walk visits. Thus the collection with compilation
      # makes at most the calls of the collection without it. The time bound of the design
      # is 5 ms. The minimum of five collections removes most of the noise of a busy
      # machine.
      check = fn ->
        calls = gc_calls(&GC.collect/0)

        ms =
          for _ <- 1..5 do
            {us, _} = :timer.tc(&GC.collect/0)
            us / 1000
          end
          |> Enum.min()

        {:ok, p} = Parser.parse("resume(4)", resolve: 4)
        Interp.run_program(p, true)
        {:ok, p} = Parser.parse("box.v", resolve: 4)
        {calls, ms, Interp.run_program(p, true)}
      end

      {{off_calls, off_ms, off_v}, _} = in_heap(@suspended, false, check)
      {{on_calls, on_ms, on_v}, _} = in_heap(@suspended, true, check)

      assert on_v == off_v
      assert is_float(on_v)
      for {a, b} <- Enum.zip(off_calls, on_calls), do: assert(b <= a + 8)
      assert on_ms < 5, "one collection took #{on_ms} ms (#{off_ms} ms without compilation)"
    end

    test "the programs of the GC tests fill the code cache" do
      # Without code in the cache, the two tests above compare two equal runs.
      {_, compiled} = in_heap(@big_code, true, fn -> nil end)
      assert compiled >= 10
      {_, compiled} = in_heap(@suspended, true, fn -> nil end)
      assert compiled >= 1
    end
  end

  # ── 5.5: the matrix ────────────────────────────────────────

  describe "5.5: the matrix" do
    test "the new snippets give the same outcome with compilation on and off at every level" do
      # Levels 1 to 3 mix rewritten functions with old-path functions in one program.
      for level <- @levels, do: assert_same(both(@small, level: level), "at #{inspect(level)}")
    end

    test ":off and :info compile nothing when the application runs at that level" do
      # `:off` and `:info` have no rewritten function, so they never compile (design 2.5).
      # The built-ins that are written in JavaScript (`Browser.JS.Prelude`) parse at the
      # level of the application, not at the level of the script. So the application level
      # is set too, as `JS_RESOLVE=off mix test` sets it. With the application at level 4,
      # the `stack` getter of the prelude compiles in an `:off` script.
      for level <- [:off, :info] do
        pairs = with_env(:js_resolve, level, fn -> both(@small, level: level) end)
        assert_same(pairs, "at #{inspect(level)}")

        for {{n, _, _}, _, on} <- pairs,
            do: assert(on.compiled == 0, "#{n} compiled at #{inspect(level)}")
      end
    end

    test "the new snippets give the same outcome at :off, 1 and 4 with the forced collections" do
      # Three levels are enough here: one with no frames, one that mixes the two paths, and
      # the default. The corpus runs with the forced collections at level 4 in 5.1.
      for level <- [:off, 1, 4],
          do: assert_same(both(@small, level: level, gc: true), "at #{level}")
    end

    test "JS_COMPILE=0 turns compilation off, and compilation is on without it" do
      # `mix test` runs at `JS_COMPILE=0` as one cell of the matrix. The setting must
      # follow the variable, or that cell runs with the compiler on.
      expected = System.get_env("JS_COMPILE") != "0"
      assert Application.get_env(:browser, :js_compile, true) == expected

      {_, compiled} =
        in_heap(ifs(5), Application.get_env(:browser, :js_compile, true), fn -> nil end)

      assert compiled > 0 == expected
    end
  end
end
