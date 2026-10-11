defmodule Browser.JS.DatamodelCorpus do
  # The corpus of the data-model step: small programs for the fast paths of the data model
  # (`Browser.JS.Fast`). The rows have the form of the rows of the compile oracle
  # (`{name, source}`), so that js_compile_test.exs runs them with compilation off and on,
  # and js_fast_test.exs runs them with the fast paths off and on. Each program writes its
  # results with `console.log`, so that each oracle compares them. The code under test is
  # in functions, because only function bodies compile.
  @moduledoc false

  # A function `run(mk, label)` for the key rows: for each key of the list, it makes a new
  # target with `mk()` and applies `t[k]++`, `t[k] += 1` and `++t[k]` to it. Then it does
  # the same with an object key whose `toString` counts its calls: each operation converts
  # the key once. A strict copy of the function (`srun`) gives the strict writes.
  @run_keys ~S"""
  function body(mk, label){
    var keys = [1, 1.5, -0, -1, "1", "01", 4294967295, 4294967294, "4294967295"];
    var out = [];
    for (var i = 0; i < keys.length; i++) {
      var t = mk(), k = keys[i];
      try {
        var r1 = t[k]++, r2 = (t[k] += 1), r3 = ++t[k];
        out.push(String(r1) + ',' + String(r2) + ',' + String(r3) + ',' + String(t[k]));
      } catch (e) { out.push(e.constructor.name + ':' + e.message) }
    }
    var n = 0, ko = { toString(){ n++; return '1' } };
    var t = mk(), counts = [];
    try { t[ko]++; counts.push(n); t[ko] += 1; counts.push(n); --t[ko]; counts.push(n) }
    catch (e) { counts.push(e.constructor.name + ':' + e.message) }
    out.push('toString ' + counts.join() + ' ' + String(t[1]));
    console.log(label, out.join(' | '));
  }
  """

  @rows [
    # ── D1: cheap keys ─────────────────────────────────────────
    {"dm keys array reads",
     ~S|function f(){ var a = [10, 11, 12]; a[4294967294] = 'last'; a[4294967295] = 'name'; return [a[-0], a["01"], a["+1"], a[" 1"], a["-0"], a["1"], a[1], a[1.5], a["1.5"], a[4294967294], a[4294967295], a["4294967295"], a.length, a[1e21], a["1e+21"]].map(String).join('/') } console.log(f())|},
    {"dm keys object reads",
     ~S|function f(){ var o = {0: 'zero', '01': 'z1', 1.5: 'f', '-0': 'm'}; return [o["0"], o[0], o[-0], o["01"], o[1], o[1.5], o["-0"], o[4294967295], Object.keys(o).join()].map(String).join('/') } console.log(f())|},
    {"dm keys array methods",
     ~S|function f(){ var a = [3, 1, 2]; return [typeof [].push, typeof [].map, typeof a.length, a.push === Array.prototype.push, a.map(x => x * 2).join(), 'push' in a, '0' in a, '01' in a, Object.keys(a).join()].join('/') } console.log(f())|},
    {"dm keys array proto element",
     ~S|function f(){ Array.prototype[1] = 'proto'; var a = [0, , 2]; var r = [a[1], a["1"], a.push === [].push, a[5]].join('/'); delete Array.prototype[1]; return r + '/' + a[1] } console.log(f())|},
    {"dm keys update array",
     @run_keys <>
       ~S|function f(){ body(() => [1, 2, 3], 'array'); body(() => Object.freeze([1, 2, 3]), 'frozen array') } f()|},
    {"dm keys update object",
     @run_keys <>
       ~S|function f(){ body(() => ({1: 5, '01': 6, '-1': 7}), 'object'); body(() => Object.freeze({1: 5}), 'frozen object') } f()|},
    {"dm keys update typed array",
     @run_keys <> ~S|function f(){ body(() => new Int8Array(3), 'typed array') } f()|},
    {"dm keys update string",
     @run_keys <>
       ~S|function f(){ body(() => new String('abc'), 'String wrapper'); body(() => 'abc', 'string') } f()|},
    {"dm keys update strict",
     ~S|"use strict"; | <>
       @run_keys <>
       ~S|function f(){ body(() => [1, 2, 3], 'array'); body(() => Object.freeze([1, 2, 3]), 'frozen array'); body(() => ({1: 5}), 'object'); body(() => new Int8Array(3), 'typed array'); body(() => new String('abc'), 'String wrapper'); body(() => 'abc', 'string'); body(() => 5, 'number') } f()|},
    # ── D2: hasOwnProperty, Object.keys and for-in ──────────────
    {"dm has own plain",
     ~S|function f(){ var o = {a: 1, b: undefined}; Object.defineProperty(o, 'h', {value: 2}); var s = Symbol('s'); o[s] = 3; var c = Object.create(o); return [o.hasOwnProperty('a'), o.hasOwnProperty('b'), o.hasOwnProperty('h'), o.hasOwnProperty('z'), o.hasOwnProperty(s), o.hasOwnProperty('toString'), c.hasOwnProperty('a'), Object.hasOwn(o, 'a'), Object.hasOwn(c, 'a'), Object.prototype.hasOwnProperty.call(o, 'b'), ({}).hasOwnProperty.call(Object.prototype, 'toString')].join() } console.log(f())|},
    {"dm has own array",
     ~S|function f(){ var a = [1, , 3]; a.x = 1; return [a.hasOwnProperty('0'), a.hasOwnProperty(0), a.hasOwnProperty('1'), a.hasOwnProperty('length'), a.hasOwnProperty('x'), a.hasOwnProperty('push'), Object.hasOwn(a, 2), Array.prototype.hasOwnProperty('length'), Array.prototype.hasOwnProperty('push')].join() } function g(){ return arguments.hasOwnProperty('0') + ',' + arguments.hasOwnProperty('length') + ',' + arguments.hasOwnProperty('callee') } console.log(f(), g(1))|},
    {"dm has own function",
     ~S|function f(){ function h(a, b){} var r = [h.hasOwnProperty('name'), h.hasOwnProperty('length'), h.hasOwnProperty('prototype'), h.hasOwnProperty('caller')]; delete h.name; r.push(h.hasOwnProperty('name'), h.name); var arrow = () => 1; r.push(arrow.hasOwnProperty('prototype'), Object.hasOwn(Math.max, 'prototype'), (function*(){}).hasOwnProperty('prototype'), (class {}).hasOwnProperty('prototype'), h.prototype.constructor === h); return r.join() } console.log(f())|},
    {"dm has own lazy prototype",
     ~S|function f(){ function p(){} function q(){} var r = [Object.hasOwn(p, 'prototype'), Object.keys(p).length, Object.getOwnPropertyNames(q).join()]; r.push(typeof p.prototype, p.prototype === p.prototype, Object.getOwnPropertyDescriptor(q, 'prototype').writable); return r.join() } console.log(f())|},
    {"dm has own string",
     ~S|function f(){ var w = new String('ab'); w.x = 1; var s = 'cd'; return [w.hasOwnProperty('0'), w.hasOwnProperty('2'), w.hasOwnProperty('length'), w.hasOwnProperty('x'), s.hasOwnProperty('1'), s.hasOwnProperty('length'), s.hasOwnProperty('x'), Object.hasOwn(s, 0), Object.prototype.hasOwnProperty.call(5, 'x'), Object.prototype.hasOwnProperty.call(true, 'valueOf')].join() } console.log(f())|},
    {"dm has own typed array",
     ~S|function f(){ var t = new Int8Array(2); t.x = 1; return [t.hasOwnProperty('0'), t.hasOwnProperty('2'), t.hasOwnProperty('-0'), t.hasOwnProperty('1.5'), t.hasOwnProperty('length'), t.hasOwnProperty('x'), Object.hasOwn(t, 1)].join() } console.log(f())|},
    {"dm has own proxy",
     ~S|function f(){ var log = []; var p = new Proxy({a: 1}, { getOwnPropertyDescriptor(t, k){ log.push('gopd ' + String(k)); return Reflect.getOwnPropertyDescriptor(t, k) }, has(t, k){ log.push('has ' + String(k)); return k in t } }); var r = [p.hasOwnProperty('a'), Object.hasOwn(p, 'b'), 'a' in p, Object.prototype.hasOwnProperty.call(p, 'a')]; var rv = Proxy.revocable({}, {}); rv.revoke(); try { Object.hasOwn(rv.proxy, 'a') } catch (e) { r.push(e.constructor.name) } return r.join() + ' ' + log.join() } console.log(f())|},
    {"dm has own global",
     ~S|var gv = 1; let gl = 2; function f(){ globalThis.gp = 3; Object.defineProperty(globalThis, 'gd', {value: 4}); return [globalThis.hasOwnProperty('gv'), globalThis.hasOwnProperty('gl'), globalThis.hasOwnProperty('gp'), globalThis.hasOwnProperty('gd'), globalThis.hasOwnProperty('Math'), globalThis.hasOwnProperty('nope'), Object.hasOwn(globalThis, 'f'), Object.keys(globalThis).filter(k => k[0] == 'g').join()].join() } console.log(f())|},
    {"dm keys order",
     ~S|function f(){ var o = {b: 1, 2: 1, a: 1, 1: 1}; var p = {'01': 1, z: 1, '4294967295': 1, '4294967294': 1, '': 1, '-1': 1}; var r = [Object.keys(o).join(), Object.keys(p).join()]; var s = ''; for (var k in o) s += k + ';'; r.push(s); delete o.b; o.b = 2; o[0] = 0; r.push(Object.keys(o).join(), JSON.stringify(o), Object.entries(p).join('/')); return r.join(' ') } console.log(f())|},
    {"dm keys order special",
     ~S|function f(){ function h(){} h.b = 1; h[1] = 2; h.a = 3; var w = new String('xy'); w.q = 1; w[5] = 2; var sym = Symbol('k'); var o = {[sym]: 1, a: 2}; Object.defineProperty(o, 'hid', {value: 3, enumerable: false}); o.c = 4; var r = [Object.keys(h).join(), Object.keys(w).join(), Object.keys(o).join(), Reflect.ownKeys(o).map(String).join()]; var s = ''; for (var k in w) s += k; r.push(s); var proto = {inh: 1}; var c = Object.create(proto); c.own = 1; s = ''; for (var k in c) s += k; r.push(s); return r.join(' ') } console.log(f())|},
    {"dm keys during for-in",
     ~S|function f(){ var o = {a: 1, b: 2, c: 3}; var s = ''; for (var k in o) { s += k; if (k == 'a') { delete o.b; o.d = 4 } } return s + ' ' + Object.keys(o).join() } console.log(f())|},
    # ── D3: the fast update of an own data property ─────────────
    {"dm update attrs",
     ~S|function f(){ var o = {a: 1, b: 2}; Object.defineProperty(o, 'a', {writable: false}); o.a = 5; o.b = 6; var fr = Object.freeze({a: 1}); fr.a = 2; var se = Object.seal({a: 1}); se.a = 2; se.z = 3; var pe = Object.preventExtensions({a: 1}); pe.a = 2; pe.z = 3; var w = {a: 1}; Object.defineProperty(w, 'a', {writable: true, enumerable: false}); w.a = 7; return [o.a, o.b, fr.a, se.a, se.z, pe.a, pe.z, w.a, Object.keys(w).length].join() } function g(){ "use strict"; var r = []; var o = {a: 1}; Object.defineProperty(o, 'a', {writable: false}); try { o.a = 5 } catch (e) { r.push(e.message) } var fr = Object.freeze({a: 1}); try { fr.a = 2 } catch (e) { r.push(e.message) } var se = Object.seal({a: 1}); se.a = 2; try { se.z = 3 } catch (e) { r.push(e.constructor.name) } r.push(o.a, fr.a, se.a); return r.join() } console.log(f(), g())|},
    {"dm update accessors",
     ~S|function f(){ var log = []; var o = { get a(){ log.push('get'); return 1 }, set a(v){ log.push('set ' + v) } }; o.a = 2; var r = { get a(){ return 3 } }; r.a = 4; var p = { set a(v){ log.push('proto set ' + v) } }; var c = Object.create(p); c.a = 5; Object.defineProperty(c, 'a', {value: 6, writable: true, enumerable: true, configurable: true}); c.a = 7; return [r.a, c.a, log.join('/')].join() } function g(){ "use strict"; var r = { get a(){ return 3 } }; try { r.a = 4 } catch (e) { return e.constructor.name + ' ' + e.message } } console.log(f(), g())|},
    {"dm update proxy",
     ~S|function f(){ var log = []; var t = {a: 1}; var p = new Proxy(t, { set(tt, k, v, rcv){ log.push('set ' + String(k) + ' ' + v); tt[k] = v * 10; return true } }); p.a = 2; p.b = 3; var q = new Proxy(function(){}, { set(tt, k, v){ log.push('fset ' + String(k)); return false } }); q.x = 1; return [t.a, t.b, log.join('/')].join() } function g(){ "use strict"; var q = new Proxy({}, { set(){ return false } }); try { q.x = 1 } catch (e) { return e.constructor.name } } console.log(f(), g())|},
    {"dm update exotic",
     ~S|function f(){ var ta = new Int8Array(4); ta.length = 1; ta.x = 1; ta.x = 2; var a = [1, 2, 3]; a.length = 0; a.y = 1; a.y = 2; function h(p, q){} h.name = 'x'; h.length = 5; var r = [ta.length, ta.x, a.length, a.y, h.name, h.length]; delete h.name; h.name = 'y'; r.push(h.name); Object.defineProperty(h, 'length', {value: 9, writable: true}); h.length = 10; r.push(h.length); var w = new String('ab'); w.length = 9; w.q = 1; w.q = 2; r.push(w.length, w.q); return r.join() } function g(){ "use strict"; var r = []; function h(){} try { h.name = 'x' } catch (e) { r.push(e.constructor.name) } var w = new String('ab'); try { w.length = 9 } catch (e) { r.push(e.constructor.name) } var ta = new Int8Array(4); try { ta.length = 1 } catch (e) { r.push(e.constructor.name) } return r.join() } console.log(f(), g())|},
    {"dm update global",
     ~S|var gv = 1; globalThis.gp = 2; function f(){ globalThis.gv = 3; globalThis.gp = 4; globalThis.gn = 5; Object.defineProperty(globalThis, 'gro', {value: 1, writable: false}); globalThis.gro = 2; return [gv, gp, gn, gro].join() } console.log(f())|},
    {"dm update strict in setter",
     ~S|var inner = { b: 1 }; function strictWrite(){ "use strict"; inner.b = 2; inner.b = 3 } var frozen = Object.freeze({x: 1}); var o = { set s(v){ frozen.x = 2; strictWrite() } }; function sloppy(){ o.s = 1; return inner.b } function strictOuter(){ "use strict"; o.s = 1; var q = {a: 1}; q.a = 2; frozen.y; try { frozen.x = 3 } catch (e) { return inner.b + q.a + e.constructor.name } } console.log(sloppy(), strictOuter())|},
    {"dm update class fields",
     ~S|class P { constructor(){ this.x = 1; this.y = 2 } bump(){ this.x = this.x + 1; this.y += 1; this.x++; return this.x + this.y } } function f(){ var p = new P(); var r = [p.bump(), p.bump()]; Object.freeze(p); try { p.bump() } catch (e) { r.push(e.constructor.name, e.message) } return r.join() } console.log(f())|},
    # ── D4: compound and update writes with a constant key ──────
    {"dm compound plain",
     ~S|function f(){ var o = {a: 1, s: 'x'}; var r = [o.a += 1, o.a++, --o.a, ++o.a, o.a--, o.a, o.s += 'y', o.s, o.n += 1, o.m++, o.m, o.length += 2]; var big = {}; for (var i = 0; i < 20; i++) big['p' + i] = i; big.p7 *= 3; big.p19 **= 2; big.p3 <<= 2; big.p0 ??= 5; big.p1 &&= 7; r.push(big.p7, big.p19, big.p3, big.p0); return r.map(String).join() } console.log(f())|},
    {"dm compound frozen",
     ~S|function f(){ var o = Object.freeze({a: 1}); var r = [o.a += 1, o.a++, --o.a, o.a, o.b++, o.b]; return r.map(String).join() } function g(){ "use strict"; var o = Object.freeze({a: 1}); var r = []; try { o.a += 1 } catch (e) { r.push(e.message) } try { o.a++ } catch (e) { r.push(e.message) } try { --o.a } catch (e) { r.push(e.message) } try { o.b++ } catch (e) { r.push(e.message) } r.push(o.a); return r.join() } console.log(f(), g())|},
    {"dm compound getter only",
     ~S|function f(){ var log = []; var o = { get a(){ log.push('get'); return 1 } }; var r = [o.a += 1, o.a++, --o.a, o.a]; return r.join() + ' ' + log.join() } function g(){ "use strict"; var o = { get a(){ return 1 } }; var r = []; try { o.a += 1 } catch (e) { r.push(e.constructor.name, e.message) } try { o.a++ } catch (e) { r.push(e.message) } return r.join() } console.log(f(), g())|},
    {"dm compound proxy",
     ~S|function f(){ var log = []; var p = new Proxy({a: 1}, { get(t, k, r){ log.push('get ' + String(k)); return t[k] }, set(t, k, v, r){ log.push('set ' + String(k) + ' ' + v); t[k] = v; return true } }); p.a += 2; p.a++; --p.a; p.a **= 2; return p.a + ' ' + log.join('/') } console.log(f())|},
    {"dm compound primitives",
     ~S|function f(){ var s = 'abc'; var n = 5; var r = [s.length += 1, s.length++, s.length, s.x += 1, n.y++, true.z += 1]; return r.map(String).join() } function g(){ "use strict"; var s = 'abc'; var r = []; try { s.length += 1 } catch (e) { r.push(e.message) } try { s.length++ } catch (e) { r.push(e.message) } try { s.x += 1 } catch (e) { r.push(e.message) } try { (5).y++ } catch (e) { r.push(e.message) } return r.join() } console.log(f(), g())|},
    {"dm compound nullish",
     ~S|function f(){ var r = []; var n = null, u; try { n.a += 1 } catch (e) { r.push(e.message) } try { u.a++ } catch (e) { r.push(e.message) } try { --n.b } catch (e) { r.push(e.message) } try { n.a += (r.push('rhs'), 1) } catch (e) { r.push(e.constructor.name) } return r.join('/') } console.log(f())|},
    {"dm compound arrays and functions",
     ~S|function f(){ var a = [1, 2]; a.length += 1; a.x = 1; a.x += 1; a.length--; function h(){} h.c = 1; h.c += 1; h.c++; var args = (function(){ arguments.length += 1; return arguments.length })(1, 2); var t = new Int8Array(2); t.length += 1; var w = new String('ab'); w.length += 1; w.q = 1; w.q++; return [a.length, a.x, h.c, args, t.length, w.length, w.q].join() } console.log(f())|},
    # ── D5: a literal in one write ──────────────────────────────
    {"dm literal duplicates",
     ~S|function f(){ var a = {a: 1, a: 2}; var b = {a: 1, b: 2, a: 3}; var c = {0: 1, a: 2, 1: 3, b: 4, 0: 5}; var d = {}; var e = {x: undefined, y: null, z: 0}; return [JSON.stringify(a), JSON.stringify(b), Object.keys(b).join(), JSON.stringify(c), Object.keys(c).join(), Object.keys(d).length, Object.keys(e).join(), 'x' in e, e.hasOwnProperty('x')].join(' ') } console.log(f())|},
    {"dm literal throws",
     ~S|function f(){ var n = 0; function bad(){ n++; throw new Error('v' + n) } var r = []; try { var o = {a: 1, b: bad(), c: 3} } catch (e) { r.push(e.message, typeof o) } try { var p = {a: (r.push('a'), 1), b: (r.push('b'), 2), c: bad()} } catch (e) { r.push(e.message) } return r.join() } console.log(f())|},
    {"dm literal order",
     ~S|function f(){ var log = []; function v(x){ log.push(x); return x } var o = {z: v(1), a: v(2), m: v(3), a: v(4)}; for (var i = 0; i < 3; i++) { var p = {k: i, j: i * 2}; p.k += p.j; log.push(p.k) } return log.join() + ' ' + Object.keys(o).join() + ' ' + JSON.stringify(o) } console.log(f())|},
    {"dm literal method home",
     ~S|var base = { hi(){ return 'base' } }; var obj = { __proto__: base, m(){ return super.hi() + '!' } }; function f(){ var r = [obj.m()]; var o2 = {m: obj.m, n: 1}; try { r.push(o2.m(), obj.m()) } catch (e) { r.push(e.constructor.name) } var o3 = {g: obj.m, h: 1}; try { r.push(o3.g()) } catch (e) { r.push(e.constructor.name) } return r.join() } console.log(f())|},
    {"dm literal wide",
     ~S|function f(){ var o = {k0: 0, k1: 1, k2: 2, k3: 3, k4: 4, k5: 5, k6: 6, k7: 7, k8: 8, k9: 9, k10: 10, k11: 11, k12: 12, k13: 13, k14: 14, k15: 15, k16: 16, k17: 17, k18: 18, k19: 19, k20: 20, k21: 21, k22: 22, k23: 23, k24: 24, k25: 25, k26: 26, k27: 27, k28: 28, k29: 29, k30: 30, k31: 31, k32: 32, k33: 33, k34: 34, k35: 35, k36: 36, k37: 37, k38: 38, k39: 39}; o.k20 = 'x'; o.k40 = 40; delete o.k3; return Object.keys(o).join() + ' ' + o.k39 + o.k20 + o.k40 + Object.values(o).length } console.log(f())|},
    {"dm literal nested and frozen",
     ~S|function f(){ var o = {a: {b: {c: 1}}, d: [1, {e: 2}]}; var fr = Object.freeze({x: 1, y: {z: 2}}); fr.x = 5; fr.y.z = 3; var sym = Symbol('s'); var mixed = {a: 1, [sym]: 2, ['c' + 1]: 3, get g(){ return 4 }, m(){ return 5 }, b: 6}; return [JSON.stringify(o), fr.x, fr.y.z, Object.isFrozen(fr), Object.keys(mixed).join(), mixed.g, mixed.m(), mixed[sym]].join(' ') } console.log(f())|},
    # ── D6: the add path ────────────────────────────────────────
    {"dm add typed array proto",
     ~S|function f(){ var ta = new Int8Array(4); var o = {}; Object.setPrototypeOf(o, ta); o[1] = 5; o["1.5"] = 1; o["-0"] = 2; o[7] = 3; o.x = 1; var r = [ta[1], o[1], o["1.5"], o.x, o[7], Object.keys(o).join()]; var c = Object.create(Object.create(ta)); c[2] = 9; c.y = 2; r.push(ta[2], Object.keys(c).join()); return r.join() } function g(){ "use strict"; var ta = new Int8Array(4); var o = Object.setPrototypeOf({}, ta); var r = []; o[1] = 5; try { o["1.5"] = 1 } catch (e) { r.push(e.constructor.name) } try { o[9] = 1 } catch (e) { r.push(e.constructor.name) } o.x = 1; r.push(ta[1], o.x, Object.keys(o).join()); return r.join() } console.log(f(), g())|},
    {"dm add chain",
     ~S|function f(){ var log = []; var p = { set s(v){ log.push('s' + v) } }; Object.defineProperty(p, 'ro', {value: 1, writable: false}); var o = Object.create(p); o.s = 1; o.ro = 2; o.n = 3; function P(){ this.a = 1; this.b = 2 } P.prototype.c = 3; var q = new P(); q.c = 4; var ne = Object.preventExtensions({}); ne.z = 1; return [log.join(), o.ro, o.n, Object.keys(o).join(), q.c, P.prototype.c, Object.keys(q).join(), ne.z].join() } function g(){ "use strict"; var p = {}; Object.defineProperty(p, 'ro', {value: 1}); var o = Object.create(p); try { o.ro = 2 } catch (e) { return e.message } } console.log(f(), g())|},
    # ── D7: element iteration ───────────────────────────────────
    {"dm iter for-of changes",
     ~S|function f(){ var r = []; var a = [1, 2, 3, 4]; for (var x of a) { r.push(x); if (x == 1) a[2] = 30; if (x == 2) a.push(5); if (x == 30) delete a[3]; if (r.length > 8) break } var b = [1, 2, 3, 4, 5]; for (var y of b) { r.push(y); if (y == 2) b.length = 3 } var c = [1, 2]; for (var z of c) { r.push(z); if (c.length < 4) c.unshift(0) } return r.map(String).join() } console.log(f())|},
    {"dm iter for-of exotic",
     ~S|function f(){ var r = []; var a = [1, , 3]; Object.defineProperty(a, 0, { get(){ r.push('get'); return 'g' } }); Array.prototype[1] = 'proto'; for (var x of a) r.push(x); delete Array.prototype[1]; for (var x of a) r.push(String(x)); function m(p, q){ for (var v of arguments) { r.push(v); p = 'p2' } return r.length } m(1, 2); function u(p){ "use strict"; for (var v of arguments) { r.push(v); p = 9 } } u(7); var e = [1, 2]; for (var w of e) { r.push(w); Object.setPrototypeOf(e, {}) } return r.join() } console.log(f())|},
    {"dm iter callbacks change",
     ~S|function f(){ var r = []; var a = [1, 2, 3, 4]; a.forEach(function(x, i, arr){ r.push(x); if (i == 0) { arr[1] = 20; arr.push(9); delete arr[3] } }); var b = [1, 2, 3, 4]; r.push(b.map(function(x, i){ if (i == 0) b.length = 2; return x * 2 }).join('/')); var c = [5, 6, 7]; r.push(c.filter(function(x, i){ c[i + 1] = 0; return x > 0 }).join('/')); r.push([1, 2, 3].some(x => x > 2), [1, 2, 3].every(x => x > 0), [1, 2, 3].reduce((s, x) => s + x, 0), [1, 2, 3].reduceRight((s, x) => s + x, ''), [4, 5, 6].find(x => x > 4), [4, 5, 6].findIndex(x => x > 4), [4, 5, 6].findLast(x => x < 6), [4, 5, 6].findLastIndex(x => x < 6)); return r.join() } console.log(f())|},
    {"dm iter callbacks exotic",
     ~S|function f(){ var r = []; var a = [1, , 3]; Object.defineProperty(a, 2, { get(){ r.push('get'); return 'g' } }); a.forEach(x => r.push(x)); Array.prototype[1] = 'p'; a.forEach(x => r.push(x)); r.push(a.map(x => x).join('/')); delete Array.prototype[1]; Object.prototype[1] = 'op'; a.forEach(x => r.push(x)); delete Object.prototype[1]; function m(p, q){ Array.prototype.forEach.call(arguments, function(x){ r.push(x); p = 'p2'; q = 'q2' }); return arguments[1] } r.push(m(1, 2)); var al = {length: 3, 0: 'a', 2: 'c'}; Array.prototype.forEach.call(al, x => r.push(x)); var pr = new Proxy([1, 2], { get(t, k){ if (k === '0') r.push('trap'); return t[k] } }); pr.forEach(x => r.push(x)); return r.join() } console.log(f())|},
    {"dm iter put element",
     ~S|function f(){ var r = []; var a = [1, 2, 3]; a[1] = 20; a[5] = 6; var fr = Object.freeze([1, 2]); fr[0] = 9; fr[2] = 3; var ne = Object.preventExtensions([1, , 3]); ne[0] = 7; ne[1] = 8; var d = [1, 2]; Object.defineProperty(d, 0, {writable: false}); d[0] = 5; d[1] = 6; var s = [1]; Object.defineProperty(s, 0, { set(v){ r.push('set ' + v) } }); s[0] = 4; Object.defineProperty(Array.prototype, 7, { set(v){ r.push('proto set ' + v) }, configurable: true }); var h = []; h[7] = 1; delete Array.prototype[7]; var l = [1, 2, 3]; Object.defineProperty(l, 'length', {writable: false}); l[1] = 9; l[3] = 4; r.push(a.join('/'), fr.join('/'), ne.join('/'), d.join('/'), h.length, l.join('/'), l.length); return r.join() } function g(){ "use strict"; var r = []; var fr = Object.freeze([1]); try { fr[0] = 2 } catch (e) { r.push(e.constructor.name) } var l = [1]; Object.defineProperty(l, 'length', {writable: false}); try { l[1] = 2 } catch (e) { r.push(e.constructor.name) } return r.join() } console.log(f(), g())|}
  ]

  @doc "Gives the rows as `{name, source, options}`."
  def rows, do: Enum.map(@rows, fn {name, src} -> {name, src, []} end)
end
