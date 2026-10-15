defmodule Browser.JSObjectAssignTest do
  # `Object.assign` (fast path `:assign` of `Browser.JS.ObjectStatics`). A plain source gives
  # its keys from one list, an empty plain target takes the shape and the values of a plain
  # source in one step, and a write to a plain target that cannot call JavaScript code
  # stores the record directly. Each test here sends one case to the generic path, and the
  # result must be the result of the specification.
  use ExUnit.Case, async: true

  alias Browser.JS

  defp js(src) do
    {:ok, value, _console} = JS.eval(src)
    value
  end

  describe "the fast path" do
    test "an empty target gets the keys, the values and the order of a plain source" do
      assert js("""
             var s = {b: 1, a: 2, c: 3};
             var o = Object.assign({}, s);
             o.d = 4; s.e = 5; o.a = 9;
             [Object.keys(o).join(), Object.values(o).join(), Object.keys(s).join(),
              s.a, JSON.stringify(Object.getOwnPropertyDescriptor(o, 'b'))].join(' ')
             """) ==
               "b,a,c,d 1,9,3,4 b,a,c,e 2 " <>
                 ~s({"value":1,"writable":true,"enumerable":true,"configurable":true})
    end

    test "a target with keys keeps its order, and a key that it has gets the new value" do
      assert js("""
             var t = {x: 1, a: 2};
             var r = Object.assign(t, {a: 3, b: 4}, null, undefined, {c: 5});
             [r === t, Object.keys(t).join(), Object.values(t).join()].join(' ')
             """) == "true x,a,b,c 1,3,4,5"
    end

    test "an object made by new, with keys on its prototype, gets own keys" do
      assert js("""
             function P() {} P.prototype.z = 1;
             var o = Object.assign(new P(), {z: 2, y: 3});
             [o.z, P.prototype.z, Object.keys(o).join(), o instanceof P].join(' ')
             """) == "2 1 z,y true"
    end

    test "a source that is the target" do
      assert js("var o = {a: 1, b: 2}; Object.assign(o, o); Object.keys(o).join() + o.b") ==
               "a,b2"
    end

    test "non-enumerable keys of a source are not copied" do
      assert js("""
             var s = {a: 1}; Object.defineProperty(s, 'h', {value: 2, enumerable: true});
             Object.defineProperty(s, 'n', {value: 3});
             var o = Object.assign({}, s);
             [Object.keys(o).join(), Object.getOwnPropertyDescriptor(o, 'h').writable].join(' ')
             """) == "a,h true"
    end

    test "a target and a source of one shape stay apart" do
      assert js("""
             var s = {a: 1, b: 2}, o = Object.assign({}, s);
             delete o.a; o.b = 3; Object.freeze(s);
             [Object.keys(o).join(), o.b, s.a, s.b, Object.isFrozen(o)].join(' ')
             """) == "b 3 1 2 false"
    end
  end

  describe "the generic path" do
    test "a source key __proto__ calls the setter of Object.prototype" do
      assert js("""
             var s = JSON.parse('{"__proto__": {"x": 1}, "a": 2}');
             var o = Object.assign({}, s);
             [o.x, o.a, Object.keys(o).join(), Object.getPrototypeOf(o) === s.__proto__].join(' ')
             """) == "1 2 a true"
    end

    test "a key __proto__ is an own key of a target with no prototype" do
      assert js("""
             var o = Object.assign(Object.create(null), JSON.parse('{"__proto__": 1}'));
             [Object.keys(o).join(), o.__proto__].join(' ')
             """) == "__proto__ 1"
    end

    test "a proxy source answers its traps in order" do
      assert js("""
             var log = [];
             var p = new Proxy({a: 1, b: 2}, {
               ownKeys(t) { log.push('keys'); return Reflect.ownKeys(t) },
               getOwnPropertyDescriptor(t, k) { log.push('desc ' + k); return Reflect.getOwnPropertyDescriptor(t, k) },
               get(t, k) { log.push('get ' + String(k)); return t[k] }
             });
             var o = Object.assign({}, p);
             [JSON.stringify(o), log.join()].join(' ')
             """) == ~s({"a":1,"b":2} keys,desc a,desc b,get a,get b)
    end

    test "a proxy target gets each key through its set trap" do
      assert js("""
             var log = [], t = {};
             var p = new Proxy(t, { set(o, k, v, r) { log.push(k + '=' + v); o[k] = v; return true } });
             Object.assign(p, {a: 1, b: 2});
             [log.join(), JSON.stringify(t)].join(' ')
             """) == ~s(a=1,b=2 {"a":1,"b":2})
    end

    test "a host source and a host target" do
      assert js("""
             var o = Object.assign({}, new Uint8Array([5, 6]));
             var ta = Object.assign(new Uint8Array(2), {0: 7, x: 8});
             [JSON.stringify(o), ta[0], ta.x].join(' ')
             """) == ~s({"0":5,"1":6} 7 8)
    end

    test "a getter of a source runs once, in order, with the source as this" do
      assert js("""
             var log = [];
             var s = {a: 1, get b() { log.push('b'); return this.a + 1 }, c: 3};
             var o = Object.assign({}, s);
             [JSON.stringify(o), log.join(), Object.getOwnPropertyDescriptor(o, 'b').writable].join(' ')
             """) == ~s({"a":1,"b":2,"c":3} b true)
    end

    test "an own setter of the target runs with the target as this" do
      assert js("""
             var t = { set a(v) { this.seen = v * 2 } };
             Object.assign(t, {a: 4, b: 5});
             [t.seen, t.b, Object.keys(t).join()].join(' ')
             """) == "8 5 a,seen,b"
    end

    test "a setter on Object.prototype runs, and adds no own key" do
      assert js("""
             var log = [];
             Object.defineProperty(Object.prototype, 'sx', {set(v) { log.push(v) }, configurable: true});
             try {
               var o = Object.assign({}, {sx: 1, y: 2});
               var r = [log.join(), Object.keys(o).join(), o.hasOwnProperty('sx')].join(' ');
             } finally { delete Object.prototype.sx }
             r
             """) == "1 y false"
    end

    test "a setter of the target sees the source as it is now" do
      assert js("""
             var s = {a: 1, b: 2};
             var t = { set a(v) { s.b = 20 } };
             Object.assign(t, s);
             t.b
             """) == 20.0
    end

    test "a read-only key on the prototype chain throws after the keys before it" do
      assert js("""
             Object.defineProperty(Object.prototype, 'ro', {value: 1, writable: false, configurable: true});
             var t = {};
             try { Object.assign(t, {a: 1, ro: 2, b: 3}); var r = 'no error' }
             catch (e) { r = e.constructor.name + ': ' + e.message }
             finally { delete Object.prototype.ro }
             [r, Object.keys(t).join()].join(' ')
             """) == "TypeError: Cannot assign to read only property 'ro' a"
    end

    test "a getter without a setter on the prototype of a class throws" do
      assert js("""
             class A { get x() { return 1 } }
             try { Object.assign(new A(), {x: 2}); 'no error' } catch (e) { e.constructor.name }
             """) == "TypeError"
    end

    test "a target that is not extensible or is frozen throws" do
      assert js("""
             var r = [];
             var t = Object.preventExtensions({a: 1});
             Object.assign(t, {a: 2}); r.push(t.a);
             try { Object.assign(t, {b: 1}) } catch (e) { r.push(e.constructor.name) }
             var f = Object.freeze({a: 1});
             try { Object.assign(f, {a: 2}) } catch (e) { r.push(e.constructor.name, f.a) }
             r.join(' ')
             """) == "2 TypeError TypeError 1"
    end

    test "a function, a primitive wrapper and a prototype function keep their read-only keys" do
      assert js("""
             var r = [];
             try { Object.assign(function f() {}, {name: 'x'}) } catch (e) { r.push(e.constructor.name) }
             try { Object.assign(new String('ab'), {length: 5}) } catch (e) { r.push(e.constructor.name) }
             try { Object.assign(new String('ab'), {0: 'x'}) } catch (e) { r.push(e.constructor.name) }
             try { Object.assign(Object.create(function g() {}), {name: 'x'}) } catch (e) { r.push(e.constructor.name) }
             var a = Object.assign([1, 2], {length: 1, x: 3});
             r.push(a.length, a.x);
             r.join(' ')
             """) == "TypeError TypeError TypeError TypeError 1 3"
    end

    test "symbols come after the strings, and index keys come first" do
      assert js("""
             var s1 = Symbol('s1'), s = {b: 1}; s[s1] = 2; s[1] = 3; s.a = 4;
             var o = Object.assign({}, s);
             [Reflect.ownKeys(o).map(String).join(), o[s1]].join(' ')
             """) == "1,b,a,Symbol(s1) 2"
    end

    test "primitive sources" do
      assert js("JSON.stringify(Object.assign({}, 'ab', 1, true, null))") == ~s({"0":"a","1":"b"})
    end
  end
end
