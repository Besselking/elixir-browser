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
       ~S|function f(){ body(() => [1, 2, 3], 'array'); body(() => Object.freeze([1, 2, 3]), 'frozen array'); body(() => ({1: 5}), 'object'); body(() => new Int8Array(3), 'typed array'); body(() => new String('abc'), 'String wrapper'); body(() => 'abc', 'string'); body(() => 5, 'number') } f()|}
  ]

  @doc "Gives the rows as `{name, source, options}`."
  def rows, do: Enum.map(@rows, fn {name, src} -> {name, src, []} end)
end
