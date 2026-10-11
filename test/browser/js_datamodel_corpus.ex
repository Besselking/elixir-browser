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
     ~S|function f(){ var o = {a: 1, b: 2, c: 3}; var s = ''; for (var k in o) { s += k; if (k == 'a') { delete o.b; o.d = 4 } } return s + ' ' + Object.keys(o).join() } console.log(f())|}
  ]

  @doc "Gives the rows as `{name, source, options}`."
  def rows, do: Enum.map(@rows, fn {name, src} -> {name, src, []} end)
end
