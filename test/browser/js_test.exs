defmodule Browser.JSTest do
  use ExUnit.Case, async: true

  alias Browser.JS

  defp js(src, opts \\ []) do
    {:ok, value, _console} = JS.eval(src, opts)
    value
  end

  defp console(src) do
    {:ok, _, lines} = JS.eval(src)
    lines
  end

  defp error(src, opts \\ []) do
    {:error, reason, _} = JS.eval(src, opts)
    reason
  end

  describe "values and operators" do
    test "arithmetic follows JavaScript semantics" do
      assert js("1 + 2 * 3") == 7.0
      assert js("2 ** 10") == 1024.0
      assert js("7 % 3") == 1.0
      assert js("-7 % 3") == -1.0
      assert js("1 / 0") == :infinity
      assert js("-1 / 0") == :neg_infinity
      assert js("0 / 0") == :nan
      assert js("1e308 * 10") == :infinity
      assert js("1 << 31") == -2_147_483_648.0
      assert js("-1 >>> 0") == 4_294_967_295.0
      assert js("~5") == -6.0
      assert js("5 & 3 | 8 ^ 1") == 9.0
    end

    test "numbers print the way JavaScript prints them" do
      assert js("String(0.1 + 0.2)") == "0.30000000000000004"
      assert js("String(1e21)") == "1e+21"
      assert js("String(1e-7)") == "1e-7"
      assert js("String(0.000001)") == "0.000001"
      assert js("String(123456789.123)") == "123456789.123"
      assert js("String(100)") == "100"
      assert js("String(-0)") == "0"
      assert js("String(1 / 0) + String(0 / 0)") == "InfinityNaN"
      assert js("(255).toString(16)") == "ff"
      assert js("(0.1).toFixed(2)") == "0.10"
    end

    test "string and number coercion" do
      assert js("'5' * '2'") == 10.0
      assert js("'5' + 2") == "52"
      assert js("null + 1") == 1.0
      assert js("undefined + 1") == :nan
      assert js("'a' < 'b'") == true
      assert js("'2' < '10'") == false
      assert js("2 < 10") == true
      assert js("1 == '1'") == true
      assert js("null == undefined") == true
      assert js("null === undefined") == false
      assert js("NaN === NaN") == false
      assert js("[1, [2, 3]] + ''") == "1,2,3"
      assert js("Number('  12 ')") == 12.0
      assert js("Number('0x1f')") == 31.0
      assert js("Number('abc')") == :nan
    end

    test "typeof" do
      assert js(
               "[typeof 1, typeof 'a', typeof null, typeof undefined, typeof {}, typeof (() => 1), typeof nope]"
             ) ==
               ["number", "string", "object", "undefined", "object", "function", "undefined"]
    end

    test "logical operators, ternary, nullish and optional chaining" do
      assert js("0 || 'x'") == "x"
      assert js("1 && 'y'") == "y"
      assert js("null ?? 'd'") == "d"
      assert js("0 ?? 'd'") == 0.0
      assert js("true ? 1 : 2") == 1.0
      assert js("var o = null; o?.a.b.c") == :undefined
      assert js("var o = {a: {b: 4}}; o?.a?.b") == 4.0
      assert js("var f = null; f?.()") == :undefined
      assert js("var o = {}; o.missing?.[0]") == :undefined
    end

    test "assignment operators" do
      assert js("let x = 5; x **= 2; x -= 1; x") == 24.0
      assert js("let x = 0; x ||= 3; x &&= 4; x") == 4.0
      assert js("let x = null; x ??= 9; x") == 9.0
      assert js("var i = 1; [i++, i, ++i, i--, i]") == [1.0, 2.0, 3.0, 3.0, 2.0]
    end
  end

  describe "statements" do
    test "var, let and const scoping" do
      assert js("var a = 1; { let a = 2; } a") == 1.0
      assert js("if (true) { var v = 3 } v") == 3.0
      assert js("hoisted(); function hoisted() { return 5 }") == 5.0

      assert error("const c = 1; c = 2") ==
               {:uncaught, "TypeError: Assignment to constant variable."}

      assert error("nope") == {:uncaught, "ReferenceError: nope is not defined"}
    end

    test "loops with break and continue" do
      assert js(
               "var s = 0; for (let i = 0; i < 10; i++) { if (i % 2) continue; if (i > 6) break; s += i } s"
             ) == 12.0

      assert js("var n = 0; while (n < 5) n++; n") == 5.0
      assert js("var n = 0; do { n++ } while (n < 3); n") == 3.0
      assert js("outer: for (var i = 0; i < 3; i++) { for (;;) { continue outer } } i") == 3.0
      assert js("a: { break a; }") == :undefined
    end

    test "let in a for loop is bound per iteration" do
      assert js("var fs = []; for (let i = 0; i < 3; i++) fs.push(() => i); fs.map(f => f())") ==
               [0.0, 1.0, 2.0]

      assert js("var fs = []; for (var i = 0; i < 3; i++) fs.push(() => i); fs.map(f => f())") ==
               [3.0, 3.0, 3.0]
    end

    test "for-in and for-of" do
      assert js("var r = []; for (var k in {a: 1, b: 2}) r.push(k); r.join()") == "a,b"

      assert js("var r = []; for (const [i, v] of [[1, 2], [3, 4]]) r.push(i + v); r") == [
               3.0,
               7.0
             ]

      assert js("var r = []; for (const c of 'abc') r.push(c); r.join('')") == "abc"
      assert js("var r = []; for (var i in [7, 8]) r.push(i); r.join()") == "0,1"
    end

    test "switch falls through until break" do
      assert js("switch (2) { case 1: 'a'; case 2: 'b'; case 3: 'c'; break; default: 'd' }") ==
               "c"

      assert js("switch (9) { case 1: 'a'; break; default: 'd' }") == "d"
    end

    test "try, catch and finally" do
      assert js("try { null.x } catch (e) { e.message }") ==
               "Cannot read properties of null (reading 'x')"

      assert js("try { throw 5 } catch (e) { e + 1 }") == 6.0

      assert js("try { throw new TypeError('t') } catch ({name, message}) { name + message }") ==
               "TypeErrort"

      assert console("(function () { try { return 1 } finally { console.log('fin') } })()") == [
               log: "fin"
             ]

      assert console(
               "try { try { throw 1 } finally { console.log('inner') } } catch (e) { console.log('outer') }"
             ) ==
               [log: "inner", log: "outer"]
    end

    test "automatic semicolon insertion" do
      assert js("var a = 1\nvar b = 2\na + b") == 3.0
      assert js("function f() {\n return\n 5\n}\nf()") == :undefined
      assert js("var i = 1\ni\n++\ni\ni") == 2.0
    end
  end

  describe "functions" do
    test "closures, recursion and arrows" do
      assert js("function fib(n) { return n < 2 ? n : fib(n - 1) + fib(n - 2) } fib(15)") == 610.0

      assert js(
               "function counter() { var n = 0; return () => ++n } var c = counter(); c(); c(); c()"
             ) == 3.0

      assert js("var f = function fact(n) { return n <= 1 ? 1 : n * fact(n - 1) }; f(5)") == 120.0
      assert js("(x => y => x + y)(1)(2)") == 3.0
    end

    test "default, rest and spread" do
      assert js(
               "function f(a, b = 2, ...c) { return [a, b, c.length] } f(1).concat(f(1, 5, 6, 7))"
             ) ==
               [1.0, 2.0, 0.0, 1.0, 5.0, 2.0]

      assert js("Math.max(...[1, 5, 3], 4)") == 5.0
      assert js("[...'ab', ...[1, 2]].length") == 4.0
      assert js("var o = {a: 1, ...{b: 2, a: 3}}; [o.a, o.b]") == [3.0, 2.0]
    end

    test "this, new, prototypes and call/apply/bind" do
      assert js(
               "function F(x) { this.x = x } F.prototype.get = function () { return this.x }; new F(7).get()"
             ) == 7.0

      assert js("function F() {} new F() instanceof F") == true
      assert js("var o = {n: 1, get() { return this.n }}; o.get()") == 1.0

      assert js(
               "function f(a) { return this.k + a } f.call({k: 1}, 2) + f.apply({k: 10}, [5]) + f.bind({k: 100})(1)"
             ) == 119.0

      assert js("var o = {n: 1, f() { return () => this.n }}; o.f()()") == 1.0
    end

    test "a method's name isn't a binding inside it" do
      assert js(
               "function print() { return 'outer' } var o = {print() { return print() }}; o.print()"
             ) == "outer"
    end

    test "deep recursion is a RangeError, not a crash" do
      assert error("function r() { return r() } r()") ==
               {:uncaught, "RangeError: Maximum call stack size exceeded"}
    end
  end

  describe "objects and destructuring" do
    test "literals, computed keys and shorthand" do
      assert js("var k = 'x'; var a = 1; var o = {a, [k + 'y']: 2, 'q-r': 3}; JSON.stringify(o)") ==
               ~s({"a":1,"xy":2,"q-r":3})

      assert js("var o = {a: 1}; o.b = 2; delete o.a; Object.keys(o).join()") == "b"
      assert js("'a' in {a: 1}") == true
      assert js("var o = {2: 'b', 1: 'a', z: 0}; Object.keys(o).join()") == "1,2,z"
    end

    test "destructuring" do
      assert js(
               "const {a, b: {c = 5}, ...r} = {a: 1, b: {}, x: 2, y: 3}; [a, c, JSON.stringify(r)]"
             ) ==
               [1.0, 5.0, ~s({"x":2,"y":3})]

      assert js("const [a, , b = 9, ...rest] = [1, 2, undefined, 4, 5]; [a, b, rest.join()]") == [
               1.0,
               9.0,
               "4,5"
             ]

      assert js("function f({x, y = 2}, [z]) { return x + y + z } f({x: 1}, [3])") == 6.0
    end
  end

  describe "built-ins" do
    test "array methods" do
      assert js("[1, 2, 3].map(x => x * 2).join('-')") == "2-4-6"
      assert js("[1, 2, 3, 4].filter(x => x % 2 == 0)") == [2.0, 4.0]
      assert js("[1, 2, 3].reduce((a, b) => a + b)") == 6.0
      assert js("[1, 2, 3].reduce((a, b) => a + b, 10)") == 16.0
      assert js("[3, 1, 2].sort()") == [1.0, 2.0, 3.0]
      assert js("[10, 9, 1].sort()") == [1.0, 10.0, 9.0]
      assert js("[10, 9, 1].sort((a, b) => a - b)") == [1.0, 9.0, 10.0]

      assert js("var a = [1, 2, 3]; a.push(4, 5); a.pop(); a.shift(); a.unshift(0); a") == [
               0.0,
               2.0,
               3.0,
               4.0
             ]

      assert js("var a = [1, 2, 3, 4, 5]; var r = a.splice(1, 2, 'x'); [a.join(), r.join()]") == [
               "1,x,4,5",
               "2,3"
             ]

      assert js("[1, 2, 3, 4].slice(-2)") == [3.0, 4.0]
      assert js("[1, [2, [3]]].flat(Infinity)") == [1.0, 2.0, 3.0]
      assert js("[1, 2, 3].indexOf(2) + [1, NaN].includes(NaN)") == 2.0
      assert js("[1, 2, 3].find(x => x > 1) + [1, 2, 3].findIndex(x => x > 1)") == 3.0
      assert js("[1, 2].some(x => x > 1) && [1, 2].every(x => x > 0)") == true
      assert js("var a = []; a[3] = 1; a.length") == 4.0
      assert js("var a = [1, 2, 3]; a.length = 1; a") == [1.0]
      assert js("Array.isArray([]) && !Array.isArray({})") == true

      assert js("Array.from('abc').length + Array.from({length: 3}, (_, i) => i * 2).join()") ==
               "30,2,4"
    end

    test "string methods" do
      assert js("'abc'.toUpperCase().padStart(6, '*')") == "***ABC"
      assert js("'a-b-c'.split('-').length") == 3.0
      assert js("'hello'.slice(-3) + 'hello'.substring(1, 3) + 'x'.repeat(3)") == "lloelxxx"
      assert js("' hi '.trim() + 'abc'.charAt(1) + 'abc'[2]") == "hib" <> "c"

      assert js("'banana'.indexOf('an') + 'banana'.lastIndexOf('an') + 'banana'.indexOf('z')") ==
               3.0

      assert js("'a.b.c'.replace('.', '-') + 'a.b.c'.replaceAll('.', '-')") == "a-b.ca-b-c"
      assert js("'abc'.replace('b', m => m.toUpperCase())") == "aBc"
      assert js("'abc'.startsWith('ab') && 'abc'.endsWith('bc') && 'abc'.includes('b')") == true
      assert js("'abc'.length") == 3.0
      assert js("'é'.length") == 1.0
      assert js("'A'.charCodeAt(0) + String.fromCharCode(66)") == "65B"
    end

    test "Math, Number and parsing" do
      assert js(
               "Math.floor(-1.5) + Math.ceil(1.2) + Math.round(2.5) + Math.abs(-3) + Math.trunc(-2.7)"
             ) == -2.0 + 2.0 + 3.0 + 3.0 - 2.0

      assert js(
               "Math.max() === -Infinity && Math.min() === Infinity && Math.max(1, NaN) !== Math.max(1, NaN)"
             ) == true

      assert js("Math.sqrt(16) + Math.pow(2, 3) + Math.hypot(3, 4)") == 17.0
      assert js("Math.PI > 3.14 && Math.PI < 3.15") == true
      assert js("var r = Math.random(); r >= 0 && r < 1") == true

      assert js("parseInt('0x1f') + parseInt('12px') + parseInt('101', 2) + parseFloat('3.5abc')") ==
               31.0 + 12.0 + 5.0 + 3.5

      assert js("isNaN(parseInt('x')) && Number.isInteger(5) && !Number.isInteger(5.5)") == true
    end

    test "JSON" do
      assert js("JSON.stringify({a: [1, {b: 2}], c: 'x\"', d: undefined, e: () => 1})") ==
               ~s({"a":[1,{"b":2}],"c":"x\\""})

      assert js("JSON.stringify([undefined, NaN])") == "[null,null]"
      assert js("JSON.stringify({a: [1, 2]}, null, 2)") == "{\n  \"a\": [\n    1,\n    2\n  ]\n}"

      assert js(
               "var o = JSON.parse('{\"z\":1,\"a\":[1,2,{\"b\":null}],\"f\":1.5}'); Object.keys(o).join() + o.a[2].b + o.f"
             ) == "z,a,fnull1.5"

      assert js("try { JSON.parse('{oops') } catch (e) { e.name }") == "SyntaxError"

      assert js("var o = {}; o.self = o; try { JSON.stringify(o) } catch (e) { e.name }") ==
               "TypeError"
    end

    test "Object statics" do
      assert js("Object.entries({a: 1, b: 2}).map(([k, v]) => k + v).join()") == "a1,b2"
      assert js("Object.values({a: 1, b: 2}).join()") == "1,2"
      assert js("JSON.stringify(Object.assign({}, {a: 1}, {b: 2}))") == ~s({"a":1,"b":2})
      assert js("JSON.stringify(Object.fromEntries([['a', 1]]))") == ~s({"a":1})
      assert js("var p = {hi() { return 'hi' }}; Object.create(p).hi()") == "hi"
      assert js("({a: 1}).hasOwnProperty('a')") == true
    end

    test "errors" do
      assert js("new Error('m') instanceof Error") == true
      assert js("new TypeError('m') instanceof Error") == true
      assert js("var e = new RangeError('r'); e.name + ': ' + e.message") == "RangeError: r"
      assert js("String(new TypeError('boom'))") == "TypeError: boom"
      assert js("try { undefinedFn() } catch (e) { e instanceof ReferenceError }") == true
      assert js("try { (void 0)() } catch (e) { e instanceof TypeError }") == true
      assert error("throw new TypeError('boom')") == {:uncaught, "TypeError: boom"}
    end
  end

  describe "console" do
    test "log formats values like Node" do
      assert console("console.log('hi', 1, true, null, undefined)") == [
               log: "hi 1 true null undefined"
             ]

      assert console("console.log({x: 1, y: 'z', 'a-b': [1, 2]}, [])") == [
               log: "{ x: 1, y: 'z', 'a-b': [ 1, 2 ] } []"
             ]

      assert console("console.log(function foo() {}, () => 1, new Error('e'))") ==
               [log: "[Function: foo] [Function (anonymous)] Error: e"]

      assert console("var o = {}; o.o = o; console.log(o)") == [log: "{ o: [Circular] }"]
      assert console("console.warn('w'); console.error('e')") == [warn: "w", error: "e"]
    end
  end

  describe "timers" do
    test "run after the script, in order of time" do
      assert console("""
             setTimeout(() => console.log('b'), 20);
             setTimeout(() => console.log('a'), 10);
             setTimeout((x) => console.log('c' + x), 20, '!');
             console.log('first');
             """) == [log: "first", log: "a", log: "b", log: "c!"]
    end

    test "clearTimeout, setInterval and nested timers" do
      assert console("var t = setTimeout(() => console.log('no'), 1); clearTimeout(t)") == []

      assert console("""
             var n = 0;
             var id = setInterval(() => { console.log(++n); if (n == 3) clearInterval(id) }, 5);
             """) == [log: "1", log: "2", log: "3"]

      assert console(
               "setTimeout(() => { console.log(1); setTimeout(() => console.log(2), 0) }, 0)"
             ) == [log: "1", log: "2"]
    end

    test "an endless interval stops instead of hanging" do
      assert {:ok, _, lines} = JS.eval("setInterval(() => console.log('t'), 1000)")
      assert length(lines) == 60
    end

    test "an error in a timer is reported and the rest still run" do
      assert console(
               "setTimeout(() => { throw new Error('x') }, 1); setTimeout(() => console.log('ok'), 2)"
             ) ==
               [error: "Uncaught Error: x", log: "ok"]
    end
  end

  describe "the result and failures" do
    test "the value is the last expression statement, as plain data" do
      assert js("1; 2") == 2.0
      assert js("var x") == :undefined
      assert js("null") == nil
      assert js("[1, 'a', true, null, {k: [2]}]") == [1.0, "a", true, nil, %{"k" => [2.0]}]
      assert js("(function () {})") == :function
    end

    test "syntax errors" do
      assert {:syntax, _} = error("var = 1")
      assert {:syntax, _} = error("1 +")
      assert {:syntax, _} = error("'unterminated")
      assert {:syntax, _} = error("class A {}")
      assert {:syntax, _} = error("a ? b")
      assert {:syntax, _} = error("1 = 2")
    end

    test "an infinite loop runs out of steps instead of hanging" do
      assert error("while (true) {}", max_steps: 1000) == :step_limit
      assert error("for (;;) {}", max_steps: 1000) == :step_limit
    end

    test "console output survives an uncaught error" do
      assert {:error, {:uncaught, "boom"}, [log: "before"]} =
               JS.eval("console.log('before'); throw 'boom'")
    end

    test "runs are isolated from each other" do
      assert js("var leak = 1; leak") == 1.0
      assert error("leak") == {:uncaught, "ReferenceError: leak is not defined"}
    end
  end

  describe "lexer" do
    test "string escapes, template literals and numbers" do
      assert js(~S|'a\tb\n\x41B\u{1F600}'|) == "a\tb\nAB😀"
      assert js(~S|"it's"|) == "it's"
      assert js("`a${1 + 1}b${`n${'x'}`}c`") == "a2bnxc"
      assert js("`${ {a: 1}.a }`") == "1"
      assert js("0xff + 0b11 + 0o7 + 1e3 + .5 + 5.") == 255.0 + 3 + 7 + 1000 + 0.5 + 5
      assert js("// line\n1 /* block\n */ + 1") == 2.0
      assert js("true ?.5:1") == 0.5
    end
  end

  describe "regular expressions" do
    test "literals are told from division" do
      assert js("var a = 8, b = 2, g = 2; a / b / g") == 2.0
      assert js("(8) / 2") == 4.0
      assert js("[1, 2].map(x => x / 2).join()") == "0.5,1"
      assert js("function f() { return /a/.test('cat') } f()") == true
      assert js("typeof /x/") == "object"
    end

    test "test, exec and lastIndex" do
      assert js(~S'/^on[A-Z]/.test("onClick")') == true
      assert js(~S'/^on[A-Z]/.test("online")') == false

      assert js(
               ~S'var m = /(\d+)-(\d+)/.exec("a 10-20 b"); m[0] + "|" + m[1] + "|" + m[2] + "|" + m.index'
             ) == "10-20|10|20|2"

      assert js(
               ~S'var re = /a/g; re.test("aa"); re.test("aa"); var r = re.test("aa"); r + ":" + re.lastIndex'
             ) == "false:0"

      assert js(~S'new RegExp("a+", "i").test("xAAy")') == true
      assert js(~S'/a\/b/.source') == "a\\/b"
    end

    test "string methods with a regular expression" do
      assert js(~S'"a1b22c".replace(/\d+/g, m => "<" + m + ">")') == "a<1>b<22>c"
      assert js(~S'"John Smith".replace(/(\w+) (\w+)/, "$2, $1")') == "Smith, John"
      assert js(~S'"a-b_c".split(/[-_]/).join("+")') == "a+b+c"
      assert js(~S'"2024-01-02".match(/\d+/g).join()') == "2024,01,02"
      assert js(~S'"abc".match(/z/)') == nil
      assert js(~S'"x1y2".search(/\d/)') == 1.0

      assert js(~S'[..."a1b2".matchAll(/[a-z](\d)/g)].map(m => m[1] + m.index).join()') ==
               "10,22"

      assert js(~S'"aaa".replaceAll(/a/g, "b")') == "bbb"
      assert js(~S'"a  b".replace(/\s+/, " ")') == "a b"
    end

    test "named groups" do
      assert js(~S'"John Smith".replace(/(?<f>\w+) (?<l>\w+)/, "$<l> $<f>")') == "Smith John"
      assert js(~S'"ab".match(/(?<x>a)(?<y>b)/).groups.y') == "b"
    end
  end

  describe "modules" do
    test "import and export declarations parse" do
      assert {:ok, {:program, [{:import, "a", [{:named, "x", "x"}, {:named, "y", "y"}]}]}} =
               Browser.JS.parse(~S'import { x, y } from "a"')

      assert {:ok, {:program, [{:import, "a", [{:default, "d"}, {:ns, "n"}]}]}} =
               Browser.JS.parse(~S'import d, * as n from "a"')

      assert {:ok, {:program, [{:import, "a", [{:named, "x", "z"}]}]}} =
               Browser.JS.parse(~S'import { x as z } from "a"')

      assert {:ok, {:program, [{:import, "side", []}]}} = Browser.JS.parse(~S'import "side"')

      assert {:ok, {:program, [{:export, {:fundecl, "f", _}}]}} =
               Browser.JS.parse("export function f() {}")

      assert {:ok, {:program, [{:export_names, [{"a", "b"}, {"c", "c"}]}]}} =
               Browser.JS.parse("export { a as b, c }")

      assert {:ok, {:program, [{:export_default, {:expr, _}}]}} =
               Browser.JS.parse("export default 1 + 2")
    end

    test "plain scripts still reject them at run time" do
      assert {:error, {:syntax, _}, _} = Browser.JS.eval("class A {}")
    end
  end

  describe "promises and async functions" do
    # the script ends by returning a promise: what it resolves to, after everything has run
    defp logs_of(src) do
      case Browser.JS.eval(src) do
        {:ok, _, console} -> for {:log, t} <- console, do: t
        {:error, reason, _} -> {:error, reason}
      end
    end

    test "then, catch and finally run as microtasks, after the script" do
      assert logs_of("""
             Promise.resolve(1).then(v => { console.log('then', v); return v + 1 })
               .then(v => console.log('next', v))
               .finally(() => console.log('finally'));
             Promise.reject('no').catch(e => console.log('caught', e));
             console.log('sync');
             """) == ["sync", "then 1", "caught no", "next 2", "finally"]
    end

    test "the executor, resolving with a promise, and the combinators" do
      assert logs_of("""
             new Promise((res, rej) => res(Promise.resolve('inner'))).then(v => console.log(v));
             new Promise((res, rej) => { throw 'boom' }).catch(e => console.log('rejected', e));
             Promise.all([1, Promise.resolve(2), new Promise(r => setTimeout(() => r(3), 10))]).then(v => console.log(v.join()));
             Promise.race([new Promise(r => setTimeout(() => r('slow'), 20)), new Promise(r => setTimeout(() => r('fast'), 5))]).then(v => console.log(v));
             Promise.allSettled([Promise.reject('x'), 1]).then(r => console.log(r.map(o => o.status).join()));
             """)
             |> Enum.sort() ==
               ["1,2,3", "fast", "inner", "rejected boom", "rejected,fulfilled"]
    end

    test "await waits for timers and other promises, and rethrows" do
      assert logs_of("""
             async function wait(ms, v) { await new Promise(r => setTimeout(r, ms)); return v }
             (async () => {
               console.log(await wait(50, 'a'), await wait(10, 'b'));
               try { await Promise.reject(new Error('bad')) } catch (e) { console.log('caught', e.message) }
               const [x, y] = await Promise.all([wait(5, 1), wait(1, 2)]);
               console.log(x + y);
             })();
             """) == ["a b", "caught bad", "3"]
    end

    test "async arrows, methods, function expressions and exceptions" do
      assert logs_of("""
             const o = { async m(x) { return x * 2 }, n: async function () { throw 'oops' } };
             o.m(4).then(v => console.log('m', v));
             o.n().catch(e => console.log('n', e));
             (async x => x + 1)(1).then(v => console.log('arrow', v));
             """) == ["m 8", "n oops", "arrow 2"]
    end

    test "destructuring assignment" do
      assert js("var a = 1, b = 2; [a, b] = [b, a]; a + ',' + b") == "2,1"
      assert js("var o; ({ x: o } = { x: 5 }); o") == 5.0
    end
  end
end
