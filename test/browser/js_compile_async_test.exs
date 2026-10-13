defmodule Browser.JS.CompileAsyncTest do
  # Step 5c: compiled CPS plans for the bodies of async functions and generators. The design
  # is section 4 of notes/js-step5-design.md, with sections 3.4, 6.2 and 7 of
  # notes/js-step4-design.md. This file is the differential oracle of 5c. Each program runs
  # with compilation off and on, in fresh processes, and the two runs must agree on every
  # observable item: the result, the console, the steps, the heap ids, the heap count, the
  # position and the unhandled rejections.
  #
  # Before 5c, the bodies of async functions and generators stayed on the tree, and only
  # their sync callees compiled. The tests of the code cache show that the oracle now
  # compares the tree walker with compiled CPS plans: with the switch on, each async
  # function and generator that runs has a plan in the cache.
  #
  # The runner is that of test/browser/js_compile_test.exs. The switch `:js_compile` and
  # the resolver level are application settings, which are global to the VM. Thus this
  # module is not async.
  use ExUnit.Case, async: false

  alias Browser.JS.{Builtins, GC, Interp, Parser}
  alias Browser.JS.Resolve.Info

  @moduletag timeout: 900_000

  @levels [:off, :info, 1, 2, 3, 4]

  # A file name gives each statement a position, so `:js_pos` and the lines of
  # `Error.stack` are part of what the two runs must agree on.
  @file_name "t.js"

  # ── the programs ───────────────────────────────────────────

  # Each program is a script. The code under test is in an async function or in a
  # generator, because only those bodies are the subject of 5c. A row is `{name, source}`
  # or `{name, source, options}`; the option `max_steps` sets the step limit. A program
  # writes its results to the console or to the array `r`, which is the value of the
  # script. The export of the value runs after the microtasks, so `r` holds the values of
  # the async work.

  # Async functions, async arrows and async methods.
  @functions [
    {"async basic",
     ~S|var r = []; async function f(x){ var a = await x; var b = await Promise.resolve(a + 1); return a + b } f(1).then(v => r.push(v)); r.push('sync'); r|},
    {"async no await",
     ~S|var r = []; async function f(){ return 5 } async function g(){} f().then(v => r.push(v)); g().then(v => r.push(typeof v)); r.push(f() instanceof Promise); r|},
    {"async throw",
     ~S|var r = []; async function f(){ throw new TypeError('t') } async function g(){ await 0; throw 'late' } f().catch(e => r.push(e.constructor.name, e.message)); g().then(null, e => r.push(e)); r|},
    {"async thenable",
     ~S|var r = []; var th = { then(ok, no){ r.push('then'); ok(7) } }; var bad = { then(ok, no){ no('bad') } }; async function f(){ var a = await th; try { await bad } catch (e) { r.push(e) } return a } f().then(v => r.push(v)); r|},
    {"async getter thenable",
     ~S|var r = []; var o = {}; Object.defineProperty(o, 'then', { get(){ r.push('get'); return undefined } }); async function f(){ var v = await o; return v === o } f().then(v => r.push(v)); r|},
    {"async arrow expr",
     ~S|var r = []; var f = async x => (await x) + 1; var g = async (a, b) => a + await b; var h = async () => await f(await g(1, 2)); h().then(v => r.push(v)); f(1).then(v => r.push(v)); r|},
    {"async arrow block this",
     ~S|var r = []; var o = { k: 'o', m(){ var f = async () => { await 0; return this.k + arguments.length }; return f() } }; o.m(1, 2).then(v => r.push(v)); r|},
    {"async methods",
     ~S|var r = []; class A { constructor(){ this.v = 1 } async m(x){ return this.v + await x } static async s(){ return 's' + await 2 } } var o = { async m(){ return await 'om' }, async ['c' + 1](){ return 'c' } }; new A().m(4).then(v => r.push(v)); A.s().then(v => r.push(v)); o.m().then(v => r.push(v)); o.c1().then(v => r.push(v)); r|},
    {"async super",
     ~S|var r = []; class A { m(x){ return 'A' + x } } class B extends A { async m(x){ var a = await x; return super.m(a) + super.m(await 2) } } new B().m(1).then(v => r.push(v)); r|},
    {"async nested",
     ~S|var r = []; async function a(n){ r.push('a' + n); if (n == 0) return 0; var v = await b(n - 1); r.push('a.' + n); return v + n } async function b(n){ r.push('b' + n); return a(n) } a(3).then(v => r.push('=' + v)); r.push('top'); r|},
    {"async all",
     ~S|var r = []; async function d(v, n){ for (var i = 0; i < n; i++) await 0; r.push(v); return v } Promise.all([d('x', 3), d('y', 1), d('z', 2)]).then(v => r.push(v.join())); r|},
    {"async arguments",
     ~S|var r = []; async function f(a, b){ await 0; arguments[0] = 9; return [a, b, arguments.length, arguments[1]].join() } async function g(a){ 'use strict'; await 0; a = 2; return arguments[0] } f(1, 2, 3).then(v => r.push(v)); g(1).then(v => r.push(v)); r|},
    {"async defaults",
     ~S|var r = []; async function f(a, b = a + 1, ...rest){ await 0; return [a, b, rest.length].join() } async function g({x, y = 2} = {x: 1}){ return x + await y } f(1).then(v => r.push(v)); f(1, 5, 6, 7).then(v => r.push(v)); g().then(v => r.push(v)); r|},
    {"async return await",
     ~S|var r = []; async function f(){ try { return await Promise.reject(new Error('caught')) } catch (e) { return e.message } } async function g(){ try { return Promise.reject('passes') } catch (e) { return 'no' } } f().then(v => r.push(v)); g().catch(e => r.push(e)); r|},
    {"async constructor kinds",
     ~S|var r = []; async function f(){} try { new f() } catch (e) { r.push(e.constructor.name) } r.push(typeof f.prototype, Object.getPrototypeOf(f).constructor.name, f.length); r|},
    {"async function constructor",
     ~S|var r = []; var AF = Object.getPrototypeOf(async function(){}).constructor; var f = new AF('a', 'var b = await a; return b * 2'); f(21).then(v => r.push(v)); r|},
    {"async eval inside",
     ~S|var r = []; async function f(){ var x = await 3; return eval('x + 1') } f().then(v => r.push(v)); r|},
    {"async unhandled",
     ~S|async function f(){ await 0; throw new Error('nobody') } f(); console.log('end')|},
    {"async stack",
     ~S|async function f(){ await 0; return g() } function g(){ return new Error('s').stack } f().then(s => console.log(s))|},
    {"async uncaught sync",
     ~S|async function f(){ return null.x } f().catch(e => console.log(e.message)); async function g(){ await 0; undefinedName } g().catch(e => console.log(e.message))|}
  ]

  # Generators, their methods and their control.
  @generators [
    {"gen basic",
     ~S|var r = []; function* g(a){ var x = yield a; r.push('x' + x); var y = yield x + 1; r.push('y' + y); return x + y } var it = g(1); r.push(JSON.stringify(it.next('lost')), JSON.stringify(it.next(10)), JSON.stringify(it.next(20)), JSON.stringify(it.next())); r|},
    {"gen spread",
     ~S|function* g(n){ for (var i = 0; i < n; i++) { if (i % 2) continue; yield i } return 'r' } console.log([...g(7)].join(), Array.from(g(3)).length)|},
    {"gen infinite take",
     ~S|function* nat(){ var n = 0; while (true) yield n++ } var s = 0; for (var v of nat()) { if (v > 9) break; s += v } console.log(s)|},
    {"gen methods",
     ~S|var r = []; class C { constructor(){ this.a = [1, 2] } *[Symbol.iterator](){ for (var x of this.a) yield x * 10 } static *s(){ yield 's' } } var o = { *g(){ yield this === o } }; r.push([...new C()].join(), [...C.s()].join(), o.g().next().value); r|},
    {"gen this arguments",
     ~S|var r = []; function* g(){ yield arguments.length; yield typeof this; yield arguments[0] } var it = g.call({}, 'a', 'b'); r.push(it.next().value, it.next().value, it.next().value); r|},
    {"gen new throws",
     ~S|var r = []; function* g(){} try { new g() } catch (e) { r.push(e.constructor.name) } r.push(typeof g.prototype, Object.getPrototypeOf(g()) === g.prototype); r|},
    {"gen running",
     ~S|var r = []; var it; function* g(){ try { it.next() } catch (e) { r.push(e.constructor.name) } yield 1 } it = g(); r.push(it.next().value); r|},
    {"gen return",
     ~S|var r = []; function* g(){ try { yield 1; yield 2 } finally { r.push('fin') } } var it = g(); it.next(); r.push(JSON.stringify(it.return(9)), JSON.stringify(it.next())); var u = g(); r.push(JSON.stringify(u.return(3))); r|},
    {"gen return yield in finally",
     ~S|var r = []; function* g(){ try { yield 1 } finally { yield 'f1'; r.push('after') } } var it = g(); it.next(); r.push(JSON.stringify(it.return(5)), JSON.stringify(it.next()), JSON.stringify(it.next())); r|},
    {"gen return override",
     ~S|var r = []; function* g(){ try { yield 1 } finally { return 'mine' } } var it = g(); it.next(); r.push(JSON.stringify(it.return('theirs'))); r|},
    {"gen throw",
     ~S|var r = []; function* g(){ while (true) { try { yield 1 } catch (e) { r.push('c' + e) } } } var it = g(); it.next(); r.push(it.throw('A').value, it.throw('B').value); function* h(){ yield 1 } var j = h(); try { j.throw(new Error('first')) } catch (e) { r.push(e.message) } r.push(JSON.stringify(j.next())); r|},
    {"gen throw finally",
     ~S|var r = []; function* g(){ try { yield 1 } finally { r.push('fin'); yield 2 } } var it = g(); it.next(); r.push(it.throw('x').value); try { it.next() } catch (e) { r.push('got ' + e) } r|},
    {"gen return in finally",
     ~S|var r = []; function* g(){ for (var i = 0; i < 3; i++) { try { if (i == 1) return 'ret' + i; yield i } finally { r.push('f' + i) } } } r.push([...g()].join()); var it = g(); r.push(JSON.stringify([it.next(), it.next(), it.next()])); r|},
    {"gen closures",
     ~S"function* g(){ var fs = []; for (let i = 0; i < 3; i++) { yield i; fs.push(() => i) } yield fs.map(f => f()).join() } console.log([...g()].join('|'))"},
    {"gen labels",
     ~S|function* g(){ outer: for (var i = 0; i < 3; i++) { for (var j = 0; j < 3; j++) { if (j == 1) continue outer; if (i == 2) break outer; yield i + ':' + j } } yield 'end' } console.log([...g()].join())|},
    {"gen switch",
     ~S|function* g(x){ switch (yield 'd') { case 1: yield 'one'; case 2: yield 'two'; break; default: yield 'def' } } var it = g(); it.next(); console.log(it.next(1).value, it.next().value, it.next().done)|},
    {"gen function constructor",
     ~S|var GF = Object.getPrototypeOf(function*(){}).constructor; var g = new GF('a', 'yield a; yield a * 2'); console.log([...g(4)].join())|},
    {"gen try catch values",
     ~S|function* g(){ var log = []; try { log.push(yield 'a'); throw new Error('e') } catch (e) { log.push(e.message, yield 'b') } finally { log.push(yield 'c') } return log.join() } var it = g(); it.next(); it.next(1); it.next(2); console.log(it.next(3).value)|}
  ]

  # Async generators.
  @async_generators [
    {"agen basic",
     ~S|var r = []; async function* g(){ var x = yield 1; r.push('x' + x); yield await Promise.resolve(2); return 3 } var it = g(); it.next().then(v => { r.push(JSON.stringify(v)); return it.next('in') }).then(v => { r.push(JSON.stringify(v)); return it.next() }).then(v => r.push(JSON.stringify(v))); r|},
    {"agen queue",
     ~S|var r = []; async function* g(){ for (var i = 0; i < 3; i++) { await 0; yield i } } var it = g(); it.next().then(v => r.push('a' + v.value)); it.next().then(v => r.push('b' + v.value)); it.next().then(v => r.push('c' + v.value)); it.next().then(v => r.push('d' + v.done)); r|},
    {"agen yield promise",
     ~S|var r = []; async function* g(){ yield Promise.resolve('p'); yield 'q'; try { yield Promise.reject('no') } catch (e) { r.push('caught ' + e) } } (async () => { for await (var v of g()) r.push(v) })(); r|},
    {"agen return throw",
     ~S|var r = []; async function* g(){ try { yield 1; yield 2 } catch (e) { r.push('c' + e); yield 'after' } finally { r.push('fin'); await 0 } } (async () => { var it = g(); await it.next(); r.push(JSON.stringify(await it.throw('T'))); r.push(JSON.stringify(await it.return('R'))); r.push(JSON.stringify(await it.next())); var u = g(); r.push(JSON.stringify(await u.return('early'))) })(); r|},
    {"agen return in finally",
     ~S|var r = []; async function* g(){ try { yield 1 } finally { return await 'fin' } } (async () => { var it = g(); await it.next(); r.push(JSON.stringify(await it.return('x'))) })(); r|},
    {"agen yield star sync",
     ~S|var r = []; async function* g(){ var v = yield* [1, Promise.resolve(2)]; r.push('v' + v); yield* (async function*(){ yield 3; return 'inner' })() } (async () => { for await (var x of g()) r.push(x) })(); r|},
    {"agen break closes",
     ~S|var r = []; async function* g(){ try { yield 1; yield 2 } finally { r.push('closed'); await 0; r.push('closed2') } } (async () => { for await (var v of g()) { r.push(v); break } r.push('after') })(); r|},
    # A bare `return;` finishes without an await, at any depth; `return undefined;` awaits.
    {"agen bare return race",
     ~S|var r = []; async function* a(){ return } async function* b(){ if (r) return } async function* c(){ await 0; { return } } async function* d(){ await 0; return undefined } async function* e(){ for (;;) { await 0; return } } async function* f(){ var g = () => { return }; yield g() } [a, b, c, d, e, f].forEach((g, i) => g().next().then(v => r.push('g' + i + v.value))); Promise.resolve().then(() => r.push(1)).then(() => r.push(2)).then(() => r.push(3)).then(() => r.push(4)); r|}
  ]

  # `for await` loops.
  @for_await [
    {"for await promises",
     ~S|var r = []; async function f(){ for await (var v of [1, Promise.resolve(2), 3]) r.push(v); for await (const c of 'ab') r.push(c); return 'end' } f().then(v => r.push(v)); r|},
    {"for await rejected",
     ~S|var r = []; async function f(){ try { for await (var v of [1, Promise.reject('rej'), 3]) r.push(v) } catch (e) { r.push('c ' + e) } } f(); r|},
    {"for await custom iterator",
     ~S|var r = []; function src(n){ var i = 0; return { [Symbol.asyncIterator](){ return this }, next(){ r.push('next'); return Promise.resolve({value: i, done: i++ >= n}) }, return(){ r.push('return'); return Promise.resolve({done: true}) } } } async function f(){ for await (var v of src(5)) { if (v == 2) break; r.push(v) } L: for await (var w of src(3)) { for (;;) { if (w == 1) continue L; break } r.push('w' + w) } } f().then(() => r.push('end')); r|},
    {"for await throw closes",
     ~S|var r = []; function src(){ return { [Symbol.asyncIterator](){ return { next(){ return Promise.resolve({value: 1, done: false}) }, return(){ r.push('ret'); return {} } } } } } async function f(){ try { for await (var v of src()) { await 0; throw new Error('body') } } catch (e) { r.push(e.message) } } f(); r|},
    {"for await labelled",
     ~S|var r = []; async function f(){ outer: for (var i = 0; i < 3; i++) { for await (var v of [10, 20, 30]) { if (v == 20) continue outer; if (i == 2) break outer; r.push(i + v) } } r.push('end') } f(); r|},
    {"for await pattern",
     ~S|var r = []; async function f(){ for await (const [a, {b = await 'd'}] of [[1, {}], Promise.resolve([2, {b: 'x'}])]) r.push(a + b) } f(); r|}
  ]

  # `yield*`.
  @yield_star [
    {"yield star return value",
     ~S|var r = []; function* inner(){ var x = yield 1; r.push('in' + x); return 'ret' } function* outer(){ var v = yield* inner(); r.push(v); yield 2 } var it = outer(); r.push(it.next().value, it.next('A').value, it.next().done); r|},
    {"yield star throw",
     ~S|var r = []; function* inner(){ try { yield 1 } catch (e) { r.push('inner ' + e); yield 'recovered' } } function* outer(){ yield* inner(); yield 'o' } var it = outer(); it.next(); r.push(it.throw('E').value, it.next().value); r|},
    {"yield star return",
     ~S|var r = []; function* inner(){ try { yield 1 } finally { r.push('inner fin') } } function* outer(){ try { yield* inner() } finally { r.push('outer fin') } } var it = outer(); it.next(); r.push(JSON.stringify(it.return(4))); r|},
    {"yield star no throw method",
     ~S|var r = []; var iter = { [Symbol.iterator](){ return { next(){ return {value: 1, done: false} }, return(){ r.push('closed'); return {} } } } }; function* g(){ yield* iter } var it = g(); it.next(); try { it.throw('x') } catch (e) { r.push(e.constructor.name) } r|},
    {"yield star expression",
     ~S"function* g(){ var a = [yield* [1, 2], yield* (function*(){ return 'r' })()]; yield a.join() } console.log([...g()].join('|'))"},
    {"yield star async",
     ~S|var r = []; async function* inner(){ yield await 'a'; return 'done' } async function* outer(){ var v = yield* inner(); yield v } (async () => { for await (var x of outer()) r.push(x) })(); r|}
  ]

  # `try`, `catch` and `finally` with awaits.
  @try_finally [
    {"await in try catch finally",
     ~S|var r = []; async function f(x){ try { r.push('t' + await x); if (x) throw new Error('e' + x) } catch (e) { r.push('c' + await e.message) } finally { r.push('f' + await 'F') } return 'end' + x } f(0).then(v => r.push(v)); f(1).then(v => r.push(v)); r|},
    {"return in finally",
     ~S|var r = []; async function f(){ try { return await 'try' } finally { return 'fin' } } async function g(){ try { throw await 'thrown' } finally { return await 'fin2' } } async function h(){ try { return 'try' } finally { await 0; r.push('after await') } } f().then(v => r.push(v)); g().then(v => r.push(v)); h().then(v => r.push(v)); r|},
    {"throw in finally",
     ~S|var r = []; async function f(){ try { return 1 } finally { await 0; throw new Error('fin') } } f().catch(e => r.push(e.message)); r|},
    {"break through finally",
     ~S|var r = []; async function f(){ for (var i = 0; i < 4; i++) { try { if (i == 1) continue; if (i == 3) break; r.push('b' + i) } finally { await 0; r.push('f' + i) } } return i } f().then(v => r.push(v)); r|},
    {"finally continue override",
     ~S|var r = []; async function f(){ for (var i = 0; i < 3; i++) { try { await 0; return i } finally { if (i < 2) continue } } return 'end' } f().then(v => r.push(v)); r|},
    {"nested try",
     ~S|var r = []; async function f(){ try { try { await Promise.reject(new TypeError('t')) } catch (e) { r.push(e.constructor.name); throw new RangeError(await 'r') } finally { r.push('inner') } } catch (e) { return e.constructor.name + e.message } } f().then(v => r.push(v)); r|},
    {"catch pattern await",
     ~S|var r = []; async function f(){ try { throw {m: 'x'} } catch ({m, n = await 'dflt'}) { return m + n } } f().then(v => r.push(v)); r|},
    {"try without await",
     ~S|var r = []; async function f(){ var x = await 1; try { x = x + 1; throw x } catch (e) { x = e * 10 } finally { x++ } return x } f().then(v => r.push(v)); r|},
    {"using",
     ~S|var r = []; async function f(){ { await using a = { async [Symbol.asyncDispose](){ await 0; r.push('da') } }; using b = { [Symbol.dispose](){ r.push('db') } }; r.push('body') } r.push('after') } f().catch(e => r.push('err ' + e)); r|}
  ]

  # Labelled `break` and `continue` across awaits, and `switch`.
  @labels [
    {"labelled loops",
     ~S|var r = []; async function f(){ outer: for (var i = 0; i < 3; i++) { await 0; inner: for (var j = 0; j < 3; j++) { if (await (j == 1)) continue outer; if (i == 2) break outer; r.push(i + ':' + j) } } return i } f().then(v => r.push('i' + v)); r|},
    {"labelled block",
     ~S|var r = []; async function f(){ var s = ''; a: { b: for (var i = 0; i < 3; i++) { c: { if (await (i == 1)) break c; if (i == 2) break a; s += i } s += 'x' } s += 'no' } return s } f().then(v => r.push(v)); r|},
    {"labelled while do",
     ~S|var r = []; async function f(){ var i = 0, s = ''; w: while (i < 5) { i++; d: do { if (await (i % 2)) continue w; s += i; break d } while (true) } return s } f().then(v => r.push(v)); r|},
    {"switch await",
     ~S"var r = []; async function f(x){ var log = []; switch (await x) { case await 1: log.push('one'); case 2: log.push('two'); await 0; break; case 3: { log.push('three'); let y = await 'y'; log.push(y) } default: log.push('def') } return log.join() } Promise.all([f(1), f(2), f(3), f(9)]).then(v => r.push(v.join('|'))); r"},
    {"switch case order",
     ~S"var r = []; async function f(x){ var log = []; function c(v){ log.push('c' + v); return v } switch (x) { case c(1): log.push('one'); case await c(2): log.push('two'); break; case c(3): log.push('three') } return log.join() } Promise.all([f(2), f(3), f(9)]).then(v => r.push(v.join('|'))); r"},
    {"switch let tdz",
     ~S|var r = []; async function f(x){ switch (x) { case 1: let y = await 'one'; return y; case 2: try { return y } catch (e) { return e.constructor.name } } } Promise.all([f(1), f(2), f(3)]).then(v => r.push(v.join())); r|},
    # A `default` in the middle: the search goes on to the later cases first, and comes
    # back to the `default` when no case matches.
    {"switch default in middle",
     ~S|var r = []; async function g(v){ var o = []; switch (await v) { case 1: o.push('one'); default: o.push('def'); break; case await 2: o.push('two') } return o.join() } (async () => { r.push(await g(2), await g(1), await g(3)) })(); r|}
  ]

  # Awaits in the test and the update of loops, and the loops of the step 4 design.
  @loops [
    {"for await parts",
     ~S|var r = []; async function g(i){ return i + 1 } async function f(){ for (var i = await 0; i < await 3; i = await g(i)) { r.push(i) } return i } f().then(v => r.push('end' + v)); r|},
    {"for let copies",
     ~S|var r = []; async function f(){ var fs = []; for (let i = await 0; await (i < 3); i = await (i + 1)) { fs.push(() => i); await 0 } return fs.map(g => g()).join() } f().then(v => r.push(v)); r|},
    {"while await test",
     ~S|var r = []; var n = 0; async function more(){ return n++ < 3 } async function f(){ while (await more()) { if (n == 2) continue; r.push(n) } return n } f().then(v => r.push('n' + v)); r|},
    {"do while await",
     ~S|var r = []; async function f(){ var i = 0; do { await 0; r.push(i) } while (await (++i < 3)); do { r.push('once') } while (await false); return i } f().then(v => r.push(v)); r|},
    {"for in body await",
     ~S|var r = []; async function f(){ var o = {a: 1, b: 2, c: 3}; var s = ''; for (var k in o) { if (k == 'b') { delete o.c; continue } s += k + await o[k] } return s } f().then(v => r.push(v)); r|},
    {"for of body await",
     ~S|var r = []; function mk(){ var i = 0; return { [Symbol.iterator](){ return this }, next(){ return {value: i++, done: i > 4} }, return(){ r.push('close'); return {} } } } async function f(){ var s = 0; for (var v of mk()) { s += await v; if (v == 2) break } for (const [a, b] of [[1, 2]]) s += a + await b; return s } f().then(v => r.push(v)); r|},
    {"loop getter counts",
     ~S|var r = []; var calls = 0, ups = 0; var o = { get t(){ calls++; return calls <= 3 }, get u(){ return ++ups } }; async function f(){ for (let i = 0; o.t; o.u) { await i } while (o.t) { await 0 } return calls + ':' + ups } f().then(v => r.push(v)); r|},
    {"loop no test",
     ~S|var r = []; async function f(){ var x = 0; for (;;) { if (await (x > 2)) break; x++ } for (;;x++) { if (x > 5) return x; await 0 } } f().then(v => r.push(v)); r|},
    {"loop throw test",
     ~S|var r = []; async function f(){ try { while (await Promise.reject(new Error('t'))) { r.push('no') } } catch (e) { r.push(e.message) } try { for (var i = 0; i < 3; await (i++ == 1 ? Promise.reject('u') : 0)) r.push(i) } catch (e) { r.push(e) } } f(); r|},
    {"gen loop parts",
     ~S|function* g(){ var n = 0; for (var i = yield 'init'; yield 'test' + i; i = yield 'upd' + i) { n++ } return n } var it = g(); var out = [it.next().value]; out.push(it.next(1).value, it.next(true).value, it.next(2).value, it.next(false).value); console.log(out.join(), JSON.stringify(it.next()))|},
    {"agen loop",
     ~S|var r = []; async function* g(){ var i = 0; while (await (i < 3)) yield await i++ } (async () => { for await (const v of g()) r.push(v); r.push('end') })(); r|},
    # A `var` without an init in a declaration that awaits keeps its value, and a `let`
    # without an init is `undefined`.
    {"var without init after await",
     ~S|var r = []; async function f(){ var x = 1; var x, y = await 0; let z, w = await 2; r.push(x, y, z, w) } f(); r|}
  ]

  # Closures made after an await or a yield.
  @closures [
    {"closure after await",
     ~S|var r = []; async function f(){ var a = 1; await 0; var g = () => a; a = 2; await 0; let b = 3; var h = function(){ return a + b }; b = 4; return [g(), h()].join() } f().then(v => r.push(v)); r|},
    {"closure this arguments",
     ~S|var r = []; var o = { k: 'K', async m(){ await 0; var g = () => this.k + arguments[0]; await 0; return g() } }; o.m('x').then(v => r.push(v)); r|},
    {"closure async inner",
     ~S|var r = []; async function f(){ var n = await 1; var inner = async (k) => { await 0; n += k; return n }; var a = await inner(10); var b = await inner(100); return [a, b, n].join() } f().then(v => r.push(v)); r|},
    {"closure block fn",
     ~S|var r = []; async function f(){ await 0; { function inner(){ return 'blk' } r.push(inner()) } { let x = await 'x'; var g = () => x } return g() } f().then(v => r.push(v)); r|},
    {"closure counter",
     ~S|var r = []; async function mk(){ var c = await 0; return { inc(){ return ++c }, get v(){ return c } } } (async () => { var a = await mk(); a.inc(); var b = await mk(); b.inc(); b.inc(); r.push(a.v, b.v, a.inc()) })(); r|},
    {"closure gen",
     ~S|function* g(){ var x = yield 1; var f = () => x * 2; x = yield f(); yield f() } var it = g(); console.log(it.next().value, it.next(5).value, it.next(7).value)|},
    {"closure tdz after await",
     ~S|var r = []; async function f(){ var g = () => x; var m; try { g() } catch (e) { m = e.constructor.name } await 0; let x = await 2; return m + ':' + g() } f().then(v => r.push(v)); r|}
  ]

  # `throw` and `catch` across awaits and frames.
  @throws [
    {"throw across frames",
     ~S|var r = []; async function a(){ await 0; throw new RangeError('deep') } async function b(){ return await a() } async function c(){ try { await b() } catch (e) { return e.constructor.name + ':' + e.message } } c().then(v => r.push(v)); r|},
    {"throw value kinds",
     ~S|var r = []; async function f(v){ await 0; throw v } Promise.allSettled([f(1), f('s'), f(null), f(undefined), f({a: 1})]).then(v => r.push(v.map(x => x.status + ':' + JSON.stringify(x.reason)).join())); r|},
    {"throw in callee after await",
     ~S|var r = []; function g(x){ if (x > 1) throw new Error('g' + x); return x } async function f(){ var s = 0; for (var i = 0; i < 4; i++) { try { s += g(await i) } catch (e) { r.push(e.message); break } } return s } f().then(v => r.push(v)); r|},
    {"throw type errors",
     ~S|var r = []; async function f(){ var o = await null; try { o.x } catch (e) { r.push(e.message) } var u; try { u() } catch (e) { r.push(e.message) } try { (await 1)() } catch (e) { r.push(e.message) } try { await undefinedVar } catch (e) { r.push(e.message) } } f(); r|},
    {"throw stack after await",
     ~S|async function f(){ await 0; try { null.x } catch (e) { console.log(e.stack) } await 0; throw new Error('top') } f().catch(e => console.log(e.stack))|},
    {"gen throw across",
     ~S|var r = []; function* g(){ try { yield 1; r.push('no') } catch (e) { r.push('g ' + e); throw 're' + e } } var it = g(); it.next(); try { it.throw('X') } catch (e) { r.push('top ' + e) } r.push(JSON.stringify(it.next())); r|}
  ]

  # The step limit, in a loop that awaits and in a generator. The limit stops the
  # microtasks of the script.
  @steps [
    {"steps async loop", ~S|async function f(){ var i = 0; for (;;) { i += await 1 } } f()|,
     max_steps: 5000},
    {"steps async while", ~S|async function f(){ while (true) { await null } } f(); f()|,
     max_steps: 4000},
    {"steps gen", ~S|function* g(){ for (;;) yield 1 } for (var v of g()) {}|, max_steps: 3000},
    {"steps finally",
     ~S|async function f(){ try { for (;;) { await 0 } } finally { console.log('fin') } } f()|,
     max_steps: 3000}
  ]

  # Frames of async functions and generators that stay suspended across top-level
  # statements. With the forced collections, a collection runs while they are suspended.
  @suspended [
    {"suspended async",
     ~S|var resume, box = []; async function f(a){ var o = {a}; var v = await new Promise(ok => { resume = ok }); box.push(o.a + v) } f(1); var junk = [{}, {}, []]; junk = null; resume(10); box|},
    {"suspended gen",
     ~S|function* g(){ var o = {n: 1}; var x = yield o.n; let fs = [() => o.n + x]; yield fs[0]() } var it = g(); it.next(); var tmp = {t: 1}; tmp = null; console.log(it.next(5).value)|},
    {"suspended agen",
     ~S|var box = []; async function* g(){ var o = {n: 2}; var x = yield o.n; yield o.n * x } var it = g(); it.next().then(v => box.push(v.value)); var tmp = []; tmp = null; it.next(3).then(v => box.push(v.value)); box|},
    {"suspended many",
     ~S|var rs = [], box = []; async function f(i){ let k = {i}; await new Promise(ok => rs.push(ok)); box.push(k.i * 10) } for (var i = 0; i < 5; i++) f(i); var x = {}; x = null; rs.forEach((ok, i) => ok(i)); box|}
  ]

  # The binary operators, with an await on the left, on the right, and on both sides. Each
  # program logs the order of the operand reads and the conversions, and a second task
  # writes to the same log. A missed await changes the order of the log.
  @witness "async function w(){ for (var i = 1; i <= 6; i++) { log.push('w' + i); await 0 } } "
  @log_helpers "var log = []; function t(n, v){ log.push(n); return v } function vo(n, v){ return {valueOf(){ log.push('v' + n); return v }, toString(){ log.push('s' + n); return String(v) }} } "

  @binary_ops (for op <-
                     ~w(+ - * / % ** == != === !== < > <= >= & | ^ << >> >>> && || ?? ,) ++
                       ["in", "instanceof"] do
                 {a, b} =
                   case op do
                     "in" -> {"'k'", "({k: 1})"}
                     "instanceof" -> {"[]", "Array"}
                     _ -> {"7", "3"}
                   end

                 conv =
                   if op in ~w(&& || ?? , in instanceof),
                     do: "",
                     else: "out.push(vo('L', #{a}) #{op} await vo('R', #{b})); "

                 src =
                   @log_helpers <>
                     @witness <>
                     "async function f(){ var out = []; " <>
                     "out.push((t('L', #{a}) #{op} await t('R', #{b}))); " <>
                     "out.push((await t('L', #{a}) #{op} t('R', #{b}))); " <>
                     "out.push(((await t('L', #{a})) #{op} (await t('R', #{b})))); " <>
                     conv <>
                     "log.push('|'); return out.join() } " <>
                     "f().then(v => log.push(v), e => log.push('rej ' + e)); w(); log"

                 {"binary #{op}", src}
               end)

  # Awaits in the other expression positions, each with the log and the second task.
  @positions (for {name, pre, body} <- [
                    {"call args", "function h(a, b, c){ return [a, b, c].join('') } ",
                     "return h(t('a', 1), await t('b', 2), t('c', 3))"},
                    {"call member callee",
                     "var o = { m(x){ return 'm' + x }, n(){ return this === o } }; ",
                     "return o[t('k', 'm')](await t('x', 1)) + o.n(await 0) + (await t('o', o)).n()"},
                    {"call spread", "function h(...a){ return a.join('') } ",
                     "return h(t('a', 0), ...await t('s', [1, 2]), ...[await t('b', 3)])"},
                    {"call callee await", "function h(a){ return 'h' + a } ",
                     "return (await t('f', h))(t('a', 1))"},
                    {"new args", "function C(a, b){ this.v = a + b } ",
                     "return new C(t('a', 1), await t('b', 2)).v + new (await t('C', C))(t('a', 3), 4).v"},
                    {"member keys", "var o = {a: {b: 'ab'}, k: 'kk'}; ",
                     "return o[await t('k', 'a')][t('k2', 'b')] + (await t('o', o))[t('k', 'k')] + o[t('k', 'a')][await t('k2', 'b')]"},
                    {"object literal", "",
                     "return JSON.stringify({a: t('a', 1), [await t('k', 'b')]: t('v', 2), ...(await t('s', {c: 3})), d: await t('d', 4), [t('k2', 'e')]: await t('v2', 5)})"},
                    {"array literal", "",
                     "return JSON.stringify([t('a', 1), await t('b', 2), ...(await t('s', [3, 4])), , t('e', 5), await t('f', 6)])"},
                    {"template", "var x = 'x'; ",
                     "return `${t('a', 1)}-${await t('b', 2)}-${t('c', x)}-${`${await t('d', 'in')}`}`"},
                    {"tagged template",
                     "function tag(s, ...v){ log.push('tag'); return s.raw.join('|') + v.join() } ",
                     "return tag`a${t('a', 1)}b${await t('b', 2)}c`"},
                    {"optional chains",
                     "var o = {a: {m(x){ return 'm' + x }}, f: null}; var n = null; ",
                     "return [o?.[await t('k', 'a')]?.m(t('x', 1)), n?.[await t('k', 'z')], o.a?.m(await t('y', 2)), n?.m(await t('no', 3)), o.f?.(await t('no2', 4)), o?.a.b ?? await t('d', 'dflt')].join()"},
                    {"conditional", "",
                     "return [await t('c', 1) ? await t('a', 2) : t('b', 3), t('c', 0) ? await t('a', 4) : await t('b', 5), (await t('c', '')) ? 1 : (await t('d', 0)) ? 2 : 3].join()"},
                    {"logical", "",
                     "return [t('x', 0) && await t('no', 1), t('x', 1) && await t('y', 2), t('x', 0) || await t('y', 3), t('x', 4) || await t('no', 5), t('x', null) ?? await t('y', 6), t('x', 7) ?? await t('no', 8), (await t('a', 0)) || (await t('b', 0)) || t('c', 9)].join()"},
                    {"assign targets", "var o = { set p(v){ log.push('set' + v) } }; var x; ",
                     "o[t('k', 'p')] = await t('v', 1); o.p = await t('v', 2); x = await t('v', 3); o[await t('k', 'q')] = t('v', 4); return x + o.q"},
                    {"assign patterns", "var o = {}; var a, b; ",
                     "[a, o.q] = [await t('a', 1), await t('b', 2)]; ({p: o[await t('k', 'r')], s: b = await t('d', 5)} = {p: t('p', 3)}); return [a, o.q, o.r, b].join()"},
                    {"compound",
                     "var o = { _p: 1, get p(){ log.push('get'); return this._p }, set p(v){ log.push('set' + v); this._p = v } }; var x = 1; ",
                     "o[t('k', 'p')] += await t('v', 1); o.p **= await t('v', 3); x += await (x = 10, t('v', 1)); x -= await 2; return [o._p, x].join()"},
                    {"logical assign",
                     "var o = { _p: 0, get p(){ log.push('get'); return this._p }, set p(v){ log.push('set' + v); this._p = v } }; var x = null, y = 1; ",
                     "o[t('k', 'p')] ||= await t('v', 5); o.p &&= await t('v', 0); x ??= await t('v', 7); y ??= await t('no', 8); return [o._p, x, y].join()"},
                    {"compound const", "",
                     "const c = 1; try { c += await t('rhs', 1) } catch (e) { log.push(e.constructor.name) } return c"},
                    {"unary", "var o = {a: 1}; ",
                     "return [typeof await t('a', 1), -await t('b', 2), !await t('c', 0), ~await t('d', 1), void await t('e', 1), delete o[await t('k', 'a')], +await t('f', '3')].join()"},
                    {"unary bigint", "",
                     "try { return +await t('a', 1n) } catch (e) { return e.constructor.name }"},
                    {"sequence", "", "return (await t('a', 1), t('b', 2), await t('c', 3))"},
                    {"var decls", "",
                     "var a = t('a', 1), b = await t('b', 2), c = a + b; let d = await t('d', 4), e = d; const f = await t('f', 6); return [a, b, c, d, e, f].join()"},
                    {"pattern default", "",
                     "var {p = await t('p', 1), q = t('q', 2)} = {}; let [x = await t('x', 3), y] = [undefined, t('y', 4)]; return [p, q, x, y].join()"},
                    {"if test", "",
                     "var s = ''; if (await t('c', 1)) s += 'a'; else s += 'b'; if (t('c2', 0)) s += 'no'; else if (await t('c3', 1)) s += 'c'; return s"},
                    {"return throw", "",
                     "try { throw await t('e', 'thrown') } catch (e) { log.push(e) } return await t('r', 'ret')"},
                    {"class key", "",
                     "var C = class { [await t('k', 'm')](){ return 1 } }; return new C().m()"},
                    {"super call args", "class A { constructor(v){ this.v = v } } ",
                     "var B = class extends A { constructor(){ super(1) } async m(){ return this.v + await t('x', 2) } }; return await new B().m()"},
                    {"await await", "", "return await await await t('a', Promise.resolve(1))"},
                    {"nested calls",
                     "async function g(x){ log.push('g' + x); await 0; log.push('g.' + x); return x * 2 } ",
                     "return (await g(1)) + (await g(await g(2)))"}
                  ] do
                {"pos #{name}",
                 @log_helpers <>
                   pre <>
                   @witness <>
                   "async function f(){ #{body} } " <>
                   "f().then(v => log.push('=' + v), e => log.push('rej ' + e)); w(); log"}
              end)

  # Yields in the expression positions of a generator. The driver sends a new value for
  # each yield, so a missed yield changes the values.
  @gen_positions (for {name, body} <- [
                        {"binary", "return t('L', 1) + (yield 'a') * (yield 'b')"},
                        {"call args",
                         "return [t('a', 1), yield 'x', t('c', 3)].join() + h(yield 'y', t('z', 1))"},
                        {"object",
                         "return JSON.stringify({a: yield 'a', [yield 'k']: t('v', 1), ...(yield 'sp')})"},
                        {"template", "return `${t('a', 1)}-${yield 'b'}-${yield 'c'}`"},
                        {"conditional logical",
                         "return [(yield 'c') ? yield 'a' : t('b', 0), t('x', 0) || (yield 'y'), t('x', 1) && (yield 'z')].join()"},
                        {"assign",
                         "var o = {}; o[yield 'k'] = yield 'v'; var x = 1; x += yield 'inc'; return JSON.stringify(o) + x"},
                        {"loop",
                         "var s = 0; for (var i = 0; i < (yield 'n'); i++) s += yield 'i' + i; return s"},
                        {"try",
                         "try { throw yield 'e' } catch (e) { return 'c' + e + (yield 'in catch') } finally { log.push(yield 'fin') }"},
                        {"switch",
                         "switch (yield 'd') { case yield 'c1': return 'one'; default: return 'def' }"}
                      ] do
                    {"gen pos #{name}",
                     @log_helpers <>
                       "function h(a, b){ return a + ':' + b } function* g(){ #{body} } " <>
                       "var it = g(), out = [], n = 0, s; while (!(s = it.next(n == 0 ? undefined : (n % 3 == 0 ? {} : n))).done && n < 20) { out.push(s.value); n++ } out.push('=' + JSON.stringify(s.value)); out.concat(log)"}
                  end)

  # A task `f` that runs one statement with one await, and a witness task `w`. If the
  # statement did not suspend, `f2` would come before `w1`. These rows are those of
  # test/browser/js_awaits_test.exs, with more positions.
  @race_witness "async function w(){ r.push('w1'); await 0; r.push('w2'); await 0; r.push('w3') } "

  @race_exprs [
    {"chain", "var o = {a: 1}; ", "var x = o?.[await 'a']"},
    {"spread", "", "var x = [...[await 1]]"},
    {"object spread", "", "var x = ({...(await {q: 1})})"},
    {"computed key", "", "var x = ({[await 'k']: 1})"},
    {"template", "", "var x = `${await 1}`"},
    {"tagged template", "function tag(s, v){ return v } ", "var x = tag`a${await 1}`"},
    {"object", "", "var x = ({a: await 1})"},
    {"array", "", "var x = [0, await 1]"},
    {"new", "function C(v){ this.v = v } ", "var x = new C(await 1)"},
    {"call arguments", "function h(a, b){ return b } ", "var x = h(0, await 1)"},
    {"member call", "var o = {m(v){ return v }}; ", "var x = o.m(await 1)"},
    {"member key", "var o = {a: 1}; ", "var x = o[await 'a']"},
    {"conditional", "", "var x = (await 1) ? 1 : 2"},
    {"conditional arm", "", "var x = 1 ? await 1 : 2"},
    {"logical", "", "var x = 0 || await 1"},
    {"nullish", "", "var x = null ?? await 1"},
    {"unary", "", "var x = -(await 1)"},
    {"binary left", "", "var x = (await 1) + 2"},
    {"binary right", "", "var x = 2 * await 1"},
    {"comparison", "", "var x = 2 < await 1"},
    {"assign slot", "var z; ", "z = await 1"},
    {"assign member", "var o = {}; ", "o.p = await 1"},
    {"assign key", "var o = {}; ", "o[await 'p'] = 1"},
    {"compound assignment", "var z = 0; ", "z += await 1"},
    {"compound member", "var o = {p: 1}; ", "o.p *= await 2"},
    {"logical assignment", "var z = null; ", "z ??= await 1"},
    {"sequence", "", "var x = (1, await 2)"},
    {"typeof", "", "var x = typeof await 1"},
    {"let", "", "let x = await 1"},
    {"const", "", "const x = await 1"},
    {"if test", "", "if (await 1) {}"},
    {"return", "", "return void r.push(await 'f2')"},
    {"throw", "", "try { throw await 1 } catch (e) {}"},
    {"switch test", "", "switch (await 1) { case 1: }"},
    {"while test", "var n = 0; ", "while (await (n++ < 0)) {}"},
    {"for update", "", "for (var i = 0; i < 1; i += await 1) {}"},
    {"for body", "", "for (var i = 0; i < 1; i++) { await 0 }"},
    {"for of body", "", "for (var v of [1]) { await v }"},
    {"for in body", "", "for (var k in {a: 1}) { await k }"},
    {"block", "", "{ let y = 1; await y }"},
    {"labelled", "", "L: { await 1; break L }"},
    {"class key", "", "var x = class { [await 'm']() {} }"},
    {"pattern default", "", "var {p = await 1} = {}"},
    {"await arrow", "var g = async () => 1; ", "var x = await g()"},
    {"optional call", "var o = {m(v){ return v }}; ", "var x = o.m?.(await 1)"}
  ]

  @races (for {n, pre, stmt} <- @race_exprs do
            # (the `return` row pushes `f2` itself, after the await of its argument)
            tail = if n == "return", do: "", else: "; r.push('f2')"

            {"race #{n}",
             "var r = []; " <>
               pre <>
               @race_witness <>
               "async function f(){ r.push('f1'); #{stmt}#{tail} } f(); w(); r"}
          end)

  @race_order ["f1", "w1", "f2", "w2", "w3"]

  # Programs whose result must be the result of node 22, at every level and with
  # compilation off and on. Each row is `{name, source, result}`, and the result is what
  # node 22 gives for the source. In the async rows a witness task `w` writes to the same
  # log as the code under test, so that the log shows each suspension in its order.
  @node_witness "async function w(){ for (var i = 1; i <= 4; i++) { log.push('w' + i); await 0 } } "

  @node_rows [
    # An await in a default of a catch parameter is an await of the async function: the
    # body suspends, and the witness runs before the handler.
    {"catch param default await",
     "var log = []; var p = Promise.resolve('d'); " <>
       @node_witness <>
       "async function f(){ log.push('f1'); try { throw {} } catch ({a = await p}) { log.push('a' + a) } try { throw [] } catch ([x = await p]) { log.push('x' + x) } log.push('f2') } " <>
       "f().then(() => log.push('end'), e => log.push('rej ' + e)); w(); log",
     ~w(f1 w1 ad w2 xd f2 w3 end w4)},
    # A yield in a default of a catch parameter suspends the generator.
    {"catch param default yield",
     "var r = []; function* g(){ try { throw {} } catch ({a = yield 'y'}) { yield 'a' + a } try { throw [] } catch ([b = yield 'z']) { return 'b' + b } } " <>
       "var it = g(); r.push(it.next().value, it.next(1).value, it.next().value, it.next(2).value); r",
     ~w(y a1 z b2)},
    # A compound assignment to a member reads the object, the key and the old value before
    # the await of its right side, and writes after it. The same is true for a name, for
    # `super[k]`, for a private name, for a key that awaits and for a base that is `null`.
    # (Node converts a key object to a property key a second time before the write. The
    # spec converts it one time, in GetValue, and this engine does the same, so the row has
    # string keys only.)
    {"compound member await",
     "var log = []; function t(n, v){ log.push(n); return v } " <>
       "async function w(){ for (var i = 1; i <= 6; i++) { log.push('w' + i); await 0 } } " <>
       "var o = { _p: 1, get p(){ log.push('get' + this._p); return this._p }, set p(v){ log.push('set' + v); this._p = v } }; var x = 1; " <>
       "class A { get q(){ log.push('getq'); return 10 } set q(v){ log.push('setq' + v) } } " <>
       "class B extends A { #z = 4; async m(){ super[t('k', 'q')] -= await t('v', 3); this.#z <<= await t('v', 2); return this.#z } } " <>
       "async function f(){ t('o', o)[t('k', 'p')] += await t('v', 1); t('o', o).p *= await t('v', 3); x += await (x = 10, t('v', 1)); " <>
       "var y = (t('o', o)[t('k', 'p')] -= t('a', 1) + await t('v', 1)) + t('b', 1); t('o', o)[await t('k', 'p')] += t('v', 0); " <>
       "try { t('o', null)[t('k', 'p')] += await t('no', 1) } catch (e) { log.push(e.constructor.name) } " <>
       "return [o._p, x, y, await new B().m()].join() } " <>
       "f().then(v => log.push('=' + v), e => log.push('rej ' + e)); w(); log",
     ~w(o k get1 v w1 set2 o get2 v w2 set6 v w3 o k get6 a v w4 set4 b o k w5 get4 v set4) ++
       ~w(o k TypeError k getq v w6 setq7 v =4,2,5,16)},
    {"compound member yield",
     "var log = []; function t(n, v){ log.push(n); return v } " <>
       "var o = { _p: 1, get p(){ log.push('get' + this._p); return this._p }, set p(v){ log.push('set' + v); this._p = v } }; " <>
       "function* g(){ t('o', o)[t('k', 'p')] += yield 'y'; t('o', o).p **= yield 'z'; return 'r' + o._p } " <>
       "var it = g(); for (var a of [undefined, 2, 2]) log.push('|' + it.next(a).value); log",
     ~w(o k get1 |y set3 o get3 |z set9 |r9)}
  ]

  # The eleven async programs of bench/js_runtime.exs (`programs_2e`), the programs of the
  # gate of 5c, with small loop counts.
  @bench_file Path.expand("../../bench/js_runtime.exs", __DIR__)
  @external_resource @bench_file

  @bench (fn ->
            {:ok, {:__block__, _, exprs}} = @bench_file |> File.read!() |> Code.string_to_quoted()

            [list] =
              for {:=, _, [{:programs_2e, _, ctx}, value]} <- exprs, is_atom(ctx) do
                {list, _} = Code.eval_quoted(value)
                list
              end

            for {id, _, _, _, body} <- list do
              body =
                Regex.replace(~r/\b\d{4,}\b/, body, fn n ->
                  "#{div(String.to_integer(n), 100)}"
                end)

              {"bench #{id}", "(function(){ function f(){ #{body} } return f() })()"}
            end
          end).()

  @groups [
    functions: @functions,
    generators: @generators,
    async_generators: @async_generators,
    for_await: @for_await,
    yield_star: @yield_star,
    try_finally: @try_finally,
    labels: @labels,
    loops: @loops,
    closures: @closures,
    throws: @throws,
    steps: @steps,
    suspended: @suspended,
    binary_ops: @binary_ops,
    positions: @positions,
    gen_positions: @gen_positions,
    races: @races,
    node_order: for({n, s, _} <- @node_rows, do: {n, s}),
    bench: @bench
  ]

  # Every program, as `{name, source, options}`.
  @corpus for {_, rows} <- @groups,
              row <- rows,
              do:
                (case row do
                   {n, s} -> {n, s, []}
                   {_, _, _} -> row
                 end)

  # ── the runner ─────────────────────────────────────────────

  # Runs each program with compilation off and then on, and gives the pairs of outcomes.
  # All runs of one mode run together, because the switch is one setting of the VM.
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

  # Runs one program in a fresh process and gives its outcome. The options are those of
  # the runner of test/browser/js_compile_test.exs: `:level`, `:max_steps`, `:gc` and
  # `:inspect`.
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

    if opts[:gc] do
      gc = Interp.native("__gc", fn _this, _args -> collect_last() end)
      Interp.declare(Interp.global(), "__gc", gc)
    end

    result =
      try do
        v = Interp.run_program(program, true)
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
    # which counts steps. The unhandled rejections are part of the outcome, because a
    # compiled body must reject the same promises.
    items = %{
      steps: :erlang.get(:js_steps),
      next: :erlang.get(:js_next),
      heap_n: :erlang.get(:js_heap_n),
      pos: Process.get(:js_pos),
      throw_pos: Process.get(:js_throw_pos),
      unhandled: Process.get(:js_unhandled, []),
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
  # Then a collection runs while the async functions and generators of the program are
  # suspended.
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

  # The entries of the code cache of this process.
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

        "#{name}: #{String.slice(src, 0, 200)}\n#{Enum.join(diff, "\n")}"
      end

    assert bad == [],
           "#{length(bad)} of #{length(pairs)} programs differ #{what}:\n\n" <>
             Enum.join(Enum.take(bad, 15), "\n\n")
  end

  # The `Info` of each async function and generator in `tree`. The uid of an `Info` is the
  # key of its code in the cache.
  defp cps_infos(tree, acc \\ [])

  defp cps_infos(%Info{} = info, acc),
    do: if(info.async? or info.generator?, do: [info | acc], else: acc)

  defp cps_infos(t, acc) when is_tuple(t), do: t |> Tuple.to_list() |> cps_infos(acc)
  defp cps_infos(l, acc) when is_list(l), do: Enum.reduce(l, acc, &cps_infos/2)
  defp cps_infos(_, acc), do: acc

  # ── the oracle ─────────────────────────────────────────────

  describe "the differential oracle of 5c" do
    for {group, _rows} <- @groups do
      @tag group: group
      test "#{group}: same outcome with compilation on and off, at level 4", %{group: group} do
        rows = for {n, s, o} <- @corpus, row_in?(n, group), do: {n, s, o}
        assert_same(both(rows, []), "in #{group} at level 4")
      end
    end

    test "the whole corpus with a forced collection before each top-level statement" do
      # A collection then runs while some async functions and generators are suspended. A
      # continuation that hid a live frame from the collector would free it.
      assert_same(both(@corpus, gc: true), "with the forced collections")
    end

    test "the whole corpus at :off with the application at :off" do
      # At `:off` no function is rewritten, so no body compiles. The run proves that the
      # old path of `Browser.JS.Async` does not use compiled code.
      pairs = with_env(:js_resolve, :off, fn -> both(@corpus, level: :off) end)
      assert_same(pairs, "at :off")
      for {{n, _, _}, _, on} <- pairs, do: assert(on.compiled == 0, "#{n} compiled at :off")
    end

    test "the whole corpus at every level" do
      # Levels 1 to 3 mix rewritten functions and old-path functions in one program.
      for level <- @levels -- [4],
          do: assert_same(both(@corpus, level: level), "at #{inspect(level)}")
    end

    test "the whole corpus at :off and 1 with the forced collections" do
      for level <- [:off, 1],
          do: assert_same(both(@corpus, level: level, gc: true), "at #{level}")
    end
  end

  # The groups of the corpus are the attributes above. A test of one group reads its rows
  # by name, because the rows are in one list.
  @group_names (for {group, rows} <- @groups, into: %{} do
                  {group, MapSet.new(rows, &elem(&1, 0))}
                end)

  defp row_in?(name, group), do: MapSet.member?(Map.fetch!(@group_names, group), name)

  describe "the corpus itself" do
    test "the program names are unique, and the corpus is large" do
      names = for {n, _, _} <- @corpus, do: n
      assert length(names) == length(Enum.uniq(names))
      assert length(@corpus) > 200
      assert length(@bench) == 11
    end

    test "the programs give different outcomes, and few of them fail to parse" do
      # A broken runner gives one outcome for every program and so passes the oracle.
      outcomes = for {_, off, _} <- both(@corpus, []), do: off.items

      syntax = for {{n, _, _}, %{syntax: msg}} <- Enum.zip(@corpus, outcomes), do: {n, msg}
      assert syntax == []

      crash = for {{n, _, _}, %{crash: c}} <- Enum.zip(@corpus, outcomes), do: {n, c}
      assert crash == []

      assert Enum.any?(outcomes, &match?(%{result: {:ok, [_ | _]}}, &1))
      assert Enum.any?(outcomes, &match?(%{console: [_ | _]}, &1))
      assert Enum.any?(outcomes, &match?(%{result: :step_limit}, &1))
      assert Enum.any?(outcomes, &match?(%{unhandled: [_ | _]}, &1))
      assert Enum.any?(outcomes, &match?(%{pos: {@file_name, _}}, &1))
      # (many rows give the same value, such as the race rows, but their steps differ)
      distinct = outcomes |> Enum.map(&{&1.result, &1.console, &1.steps}) |> Enum.uniq()
      assert length(distinct) > div(length(outcomes) * 2, 3)
    end

    test "the race rows give the order of one suspension, at every level" do
      # With one await in the statement, `f` gives way once to `w`. If a compiled plan
      # missed the await, `f2` would come before `w1`.
      rows = for {n, s} <- @races, do: {n, s, []}

      for level <- @levels do
        for {{n, _, _}, off, on} <-
              both(rows, level: level) do
          assert off.items.result == {:ok, @race_order}, "#{n} at #{level} (off)"
          assert on.items.result == off.items.result, "#{n} at #{level} (on)"
        end
      end
    end

    test "the node rows give the result of node 22, at every level" do
      rows = for {n, s, _} <- @node_rows, do: {n, s, []}

      for level <- @levels do
        for {{{n, _, _}, off, on}, {_, _, want}} <- Enum.zip(both(rows, level: level), @node_rows) do
          assert off.items.result == {:ok, want}, "#{n} at #{level} (off)"
          assert on.items.result == {:ok, want}, "#{n} at #{level} (on)"
        end
      end
    end

    test "the witness interleaves with the code under test in each position row" do
      # The log of a position row has the entries of the witness among the entries of `f`.
      # If every await of `f` came after the witness, the row would not test the order.
      outcomes = both(Enum.map(@binary_ops ++ @positions, fn {n, s} -> {n, s, []} end), [])

      for {{n, _, _}, off, _} <- outcomes do
        assert {:ok, log} = off.items.result, n
        i = Enum.find_index(log, &(&1 == "w1"))
        j = Enum.find_index(log, &(&1 == "w6"))
        assert i != nil and j != nil, "#{n}: #{inspect(log)}"

        assert Enum.any?(Enum.slice(log, (i + 1)..(j - 1)//1), &(&1 not in ~w(w2 w3 w4 w5))),
               "#{n}: #{inspect(log)}"
      end
    end

    test "the async functions and generators of the corpus are rewritten at level 4" do
      # A body that takes the old path never compiles, so a row of it would prove nothing
      # about compiled code. A function with a direct eval is dynamic and stays on the old
      # path; the rows with eval are the only ones allowed to have such a body.
      not_rewritten =
        for {n, src, _} <- @corpus,
            {:ok, tree} = Parser.parse(src, resolve: 4),
            infos = cps_infos(tree),
            infos == [] or Enum.any?(infos, &(not &1.rewritten)),
            not String.contains?(src, "eval("),
            do: {n, length(infos), Enum.count(infos, & &1.rewritten)}

      assert not_rewritten == []
    end
  end

  # ── the code cache with 5c ─────────────────────────────────

  # Programs whose async functions and generators all run. With 5c, the body of each one
  # has compiled code in the cache under the uid of its `Info`.
  @cache_rows [
    {"await loop", "bench await20k"},
    {"async calls", "bench asynccalls10k"},
    {"generator", "bench gen30k"},
    {"async generator", "bench asyncgen5k"},
    {"expression awaits", "bench exprawait5k"},
    {"labels", "labelled loops"},
    {"try finally", "await in try catch finally"},
    {"gen methods", "gen methods"},
    {"positions", "pos call args"}
  ]

  describe "the code cache with 5c" do
    test "the bodies of async functions and generators get compiled code" do
      rows = for {_, name} <- @cache_rows, do: List.keyfind!(@corpus, name, 0)

      for {name, src, opts} <- rows do
        {:ok, program} = Parser.parse(src, resolve: 4, file: @file_name)
        uids = for %Info{rewritten: true, uid: uid} <- cps_infos(program), uid != nil, do: uid
        assert uids != [], "#{name}: no rewritten async function or generator"

        entries = fn -> for uid <- uids, do: {uid, :erlang.get({:jsc, uid})} end

        on =
          with_compile(true, fn ->
            in_process(fn -> execute(program, Keyword.put(opts, :inspect, entries)) end)
          end)

        missing =
          for {uid, entry} <- on.inspect,
              entry == :undefined or (is_tuple(entry) and elem(entry, 0) == nil),
              do: {uid, entry}

        assert missing == [], "#{name}: bodies with no compiled code: #{inspect(missing)}"

        off =
          with_compile(false, fn ->
            in_process(fn -> execute(program, Keyword.put(opts, :inspect, entries)) end)
          end)

        assert Enum.all?(off.inspect, &match?({_, :undefined}, &1)),
               "#{name}: compiled code with the switch off"
      end
    end

    # A body that the compiler refuses has the entry `{nil, nil}`. The programs of the
    # corpus are small, so the compiler must accept each body that runs. A body that never
    # runs (for example a generator that is made but not resumed) has no entry.
    test "the compiler accepts each async function and generator of the corpus that runs" do
      counts =
        for {name, src, opts} <- @corpus, reduce: %{compiled: 0, not_run: 0, refused: []} do
          acc ->
            {:ok, program} = Parser.parse(src, resolve: 4, file: @file_name)

            uids =
              for %Info{rewritten: true, uid: uid} <- cps_infos(program), uid != nil, do: uid

            entries = fn -> for uid <- uids, do: :erlang.get({:jsc, uid}) end

            on =
              with_compile(true, fn ->
                in_process(fn -> execute(program, Keyword.put(opts, :inspect, entries)) end)
              end)

            Enum.reduce(on.inspect, acc, fn
              :undefined, acc -> %{acc | not_run: acc.not_run + 1}
              {nil, _}, acc -> %{acc | refused: [name | acc.refused]}
              {plan, nil}, acc when is_function(plan, 3) -> %{acc | compiled: acc.compiled + 1}
            end)
        end

      assert counts.refused == [], "bodies that did not compile: #{inspect(counts.refused)}"
      # (a few functions of the corpus are made only to be inspected, and never run)
      assert counts.compiled > 300 and counts.not_run < 10, inspect(counts)
    end
  end

  # ── the GC rules for suspended bodies ──────────────────────

  # The number of calls of `GC.mark/2` and `GC.push/3` in one collection. The count is for
  # all processes, which is safe because this module is not async.
  defp gc_calls(fun) do
    mfas = [{GC, :mark, 2}, {GC, :push, 3}]
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
  # result of `fun`.
  defp in_heap(src, compile?, fun) do
    {:ok, program} = Parser.parse(src, resolve: 4, file: @file_name)

    outcome =
      with_compile(compile?, fn ->
        in_process(fn -> execute(program, max_steps: 100_000_000, inspect: fun) end)
      end)

    outcome.inspect
  end

  @ifs for k <- 1..20, into: "", do: " if (v < #{k}) { t += #{k} } else { t -= 1 }"

  # Bodies with 20 ifs after the point where they stay suspended. With 5c, the
  # continuation of each body holds compiled code, which the collector must not walk.
  @suspended_gc [
    {"async",
     "var resume, box = {}; async function run(){ var t = 0; var v = await new Promise(r => { resume = r });#{@ifs} return t + v } run().then(x => { box.v = x })",
     ["resume(4)"]},
    {"generator",
     "var it, box = {}; function* g(){ var t = 0; var v = yield 1;#{@ifs} box.v = t + v } it = g(); it.next()",
     ["it.next(4)"]},
    {"async generator",
     "var it, box = {}; async function* g(){ var t = 0; var v = yield 1;#{@ifs} box.v = t + v } it = g(); it.next()",
     ["it.next(4)"]},
    {"async loop",
     "var resume, box = {}; async function run(){ var t = 0, v = 0; for (let i = 0; i < 2; i++) { v += await new Promise(r => { resume = r });#{@ifs} } return t + v } run().then(x => { box.v = x })",
     ["resume(2)", "resume(2)"]}
  ]

  describe "the GC rules for suspended async bodies" do
    for {name, src, resume} <- @suspended_gc do
      @tag src: src, resume: resume
      test "a suspended #{name} body collects fast and resumes with the same value",
           %{src: src, resume: resume} do
        # The minimum of five collections removes most of the noise of a busy machine.
        # The bound of the design is 5 ms. A collection with compiled code walks no more
        # items than one with the tree, because the collector skips the funs of
        # `Browser.JS.Compile`.
        check = fn ->
          calls = gc_calls(&GC.collect/0)
          ms = Enum.min(for _ <- 1..5, do: elem(:timer.tc(&GC.collect/0), 0) / 1000)

          # (a collection runs after each resume, while the body is suspended again)
          for s <- resume do
            {:ok, p} = Parser.parse(s, resolve: 4)
            Interp.run_program(p, true)
            GC.collect()
          end

          {:ok, p} = Parser.parse("box.v", resolve: 4)
          {calls, ms, Interp.run_program(p, true)}
        end

        {off_calls, off_ms, off_v} = in_heap(src, false, check)
        {on_calls, on_ms, on_v} = in_heap(src, true, check)

        assert on_v == off_v
        assert is_float(on_v)

        for {a, b} <- Enum.zip(off_calls, on_calls),
            do:
              assert(
                b <= a + div(a, 10) + 8,
                "calls off #{inspect(off_calls)}, on #{inspect(on_calls)}"
              )

        assert on_ms < 5, "one collection took #{on_ms} ms (#{off_ms} ms without compilation)"
      end
    end
  end

  # ── the switch ─────────────────────────────────────────────

  describe "the switch" do
    test "JS_COMPILE=0 turns compilation off, and compilation is on without it" do
      expected = System.get_env("JS_COMPILE") != "0"
      assert Application.get_env(:browser, :js_compile, true) == expected
    end
  end
end
