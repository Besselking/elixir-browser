defmodule Browser.JSNativeArgsTest do
  # The natives read their arguments by position with a walk of the argument list (`arg/2`
  # in each module of natives), and `Function.prototype.call` and `Object.assign` take their
  # arguments with a match. An argument that the call does not give is `undefined`, and an
  # argument after the last one that the native reads changes nothing.
  use ExUnit.Case, async: true

  alias Browser.JS

  defp js(src) do
    {:ok, value, _console} = JS.eval(src)
    value
  end

  test "a missing argument is undefined" do
    assert js("""
           var m = new Map();
           m.set();
           [
             'xundefined'.indexOf(), 'abc'.indexOf(), 'abc'.at(), 'abc'.padStart(),
             'abc'.substring(1), 'a,b'.split().length,
             m.has(), m.size, m.get(), new Set().add().has(undefined),
             JSON.stringify(), JSON.stringify(undefined) === JSON.stringify(),
             /undef/.test(), Object.hasOwn({undefined: 1}),
             String(new Float64Array(2).fill()), new Date(2020, 0).getDate(),
             Symbol().description, typeof Promise.resolve()
           ].join('|')
           """) ==
             "1|-1|a|abc|bc|1|true|1||true||true|true|true|NaN,NaN|1||object"
  end

  test "an argument after the last one that a native reads changes nothing" do
    assert js("""
           var m = new Map([[1, 2]]);
           [
             'abc'.indexOf('b', 0, 'x', 9), 'a-b-c'.replace('-', '+', 1, 2),
             'abc'.slice(1, 2, 3), m.get(1, 3, 4), m.has(1, 2),
             JSON.parse('1', undefined, 'x'), JSON.stringify({a: 1}, null, 0, 'x'),
             new Date(2020, 1, 3, 4, 5, 6, 7, 8, 9).getMilliseconds(),
             new Float64Array([1, 2, 3]).indexOf(2, 0, 9), /b/.exec('abc', 1)[0],
             Object.hasOwn({a: 1}, 'a', 'b')
           ].join('|')
           """) == "1|a+b-c|b|2|true|1|{\"a\":1}|7|1|b|true"
  end

  test "Function.prototype.call with no argument, a this only and many arguments" do
    assert js("""
           function s() { return [this === globalThis, arguments.length].join() }
           function t() { 'use strict'; return [this === undefined, arguments.length].join() }
           var o = {};
           function u() { return [this === o, Array.prototype.join.call(arguments, '+')].join() }
           var r = [s.call(), t.call(), u.call(o), u.call(o, 1, 2, 3), s.call(null, 1),
                    t.call(undefined, 1, 2), Function.prototype.call.call(u, o, 4),
                    s.call.length];
           try { Function.prototype.call.call(1) } catch (e) { r.push(e.constructor.name) }
           r.join('|')
           """) == "true,0|true,0|true,|true,1+2+3|true,1|true,2|true,4|1|TypeError"
  end

  test "Object.assign with no source, one source and many sources" do
    assert js("""
           var o = {a: 1};
           var r = [Object.assign(o) === o, Object.keys(Object.assign({}, {b: 2})).join(),
                    JSON.stringify(Object.assign({}, {a: 1}, null, {b: 2}, undefined, 'xy',
                                                 {a: 3}, 5, true)),
                    typeof Object.assign(1), Object.assign.length];
           try { Object.assign() } catch (e) { r.push(e.constructor.name) }
           try { Object.assign(null, {a: 1}) } catch (e) { r.push(e.constructor.name) }
           r.join('|')
           """) == ~s(true|b|{"0":"x","1":"y","a":3,"b":2}|object|2|TypeError|TypeError)
  end
end
