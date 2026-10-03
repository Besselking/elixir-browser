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
      assert {:syntax, _} = error("var a = 1n")
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

    test "syntax the runtime lacks is a syntax error" do
      assert {:error, {:syntax, _}, _} = Browser.JS.eval("var a = 1n")
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

    test "an async function stops at its first await, and carries on in microtask order" do
      assert logs_of("""
             var out = [];
             async function f() { out.push('a'); await null; out.push('c'); await null; out.push('e'); return 'r' }
             f().then(v => out.push('then ' + v));
             out.push('b');
             Promise.resolve().then(() => out.push('d'));
             console.log(out.join());
             setTimeout(() => console.log(out.join()), 0);
             """) == ["a,b", "a,b,c,d,e,then r"]
    end

    test "await inside loops, try, switch, labels and expressions" do
      assert logs_of("""
             async function g(n) { let s = 0; for (let i = 0; i < n; i++) { s += await i } return s }
             g(5).then(v => console.log('sum', v));
             async function h() {
               try { await Promise.reject('x'); console.log('no') }
               catch (e) { console.log('caught', e) }
               finally { console.log('fin') }
               return 'ok'
             }
             h().then(v => console.log(v));
             async function k() {
               outer: for (let i = 0; i < 3; i++) { for (let j = 0; j < 3; j++) { if (j == 1) continue outer; if (i == 2) break outer; await null; console.log(i, j) } }
               switch (await 2) { case 1: console.log('one'); break; case 2: console.log('two'); case 3: console.log('three'); break; default: console.log('d') }
               const o = { a: await 1, b: [await 2, await 3] };
               console.log(o.a + o.b.join());
               return (await 5) > 3 ? await 'big' : 'small';
             }
             k().then(v => console.log(v));
             """)
             |> Enum.sort() ==
               Enum.sort([
                 "sum 10",
                 "caught x",
                 "fin",
                 "ok",
                 "0 0",
                 "1 0",
                 "two",
                 "three",
                 "12,3",
                 "big"
               ])
    end

    test "return and throw cross a finally, and short-circuits do not await" do
      assert logs_of("""
             async function a() { try { await null; return 'from try' } finally { console.log('cleanup') } }
             a().then(v => console.log(v));
             async function b() { try { await null; throw 'e' } catch (x) { return await ('caught ' + x) } finally { console.log('done b') } }
             b().then(v => console.log(v));
             async function c() { let ran = false; const f = async () => { ran = true; return 1 };
               const x = false && await f(); const y = true || await f(); const z = null ?? await f();
               return [x, y, z, ran].join() }
             c().then(v => console.log(v));
             """)
             |> Enum.sort() ==
               Enum.sort(["cleanup", "from try", "done b", "caught e", "false,true,1,true"])
    end

    test "separate calls interleave at their awaits" do
      assert logs_of("""
             const sleep = (ms) => new Promise(r => setTimeout(r, ms));
             async function a() { await sleep(30); console.log('slow') }
             async function b() { await sleep(10); console.log('fast') }
             a(); b(); console.log('started');
             """) == ["started", "fast", "slow"]
    end

    test "a rejection after an await reaches catch" do
      assert logs_of("""
             async function th() { await null; throw new Error('late') }
             th().catch(e => console.log('c', e.message));
             """) == ["c late"]
    end

    test "destructuring assignment" do
      assert js("var a = 1, b = 2; [a, b] = [b, a]; a + ',' + b") == "2,1"
      assert js("var o; ({ x: o } = { x: 5 }); o") == 5.0
    end
  end

  describe "property attributes" do
    test "defineProperty: a read-only, hidden property" do
      assert js(
               "var o = {}; Object.defineProperty(o, 'x', {value: 1}); o.x = 2; o.x + ',' + Object.keys(o).length"
             ) == "1,0"

      assert js(
               "var o = {}; Object.defineProperty(o, 'x', {value: 1}); JSON.stringify(Object.getOwnPropertyDescriptor(o, 'x'))"
             ) ==
               ~s({"value":1,"writable":false,"enumerable":false,"configurable":false})

      assert js(
               "var o = {}; Object.defineProperty(o, 'x', {value: 1, writable: true, enumerable: true, configurable: true}); o.x = 5; delete o.y; o.x + ',' + Object.keys(o).join()"
             ) == "5,x"
    end

    test "a non-configurable property cannot be redefined or deleted" do
      assert js(
               "var o = {}; Object.defineProperty(o, 'x', {value: 1}); try { Object.defineProperty(o, 'x', {value: 2}) } catch (e) { e.name }"
             ) == "TypeError"

      assert js(
               "var o = {}; Object.defineProperty(o, 'x', {value: 1}); Object.defineProperty(o, 'x', {value: 1}); delete o.x"
             ) == false

      assert js(
               "var o = {}; Object.defineProperty(o, 'x', {value: 1, configurable: true}); Object.defineProperty(o, 'x', {get: function () { return 3 }}); o.x"
             ) == 3.0
    end

    test "accessors, in object literals and defineProperty" do
      assert js(
               "var o = { get a() { return this.b * 2 }, set a(v) { this.b = v }, b: 1 }; o.a = 5; o.a"
             ) == 10.0

      assert js(
               "var o = {}; Object.defineProperty(o, 'g', {get: function () { return 7 }, enumerable: true}); o.g + ',' + Object.keys(o).join()"
             ) == "7,g"

      assert js("var p = { get v() { return this.n } }; var o = Object.create(p); o.n = 4; o.v") ==
               4.0

      assert js("var o = { set only(v) {} }; o.only = 1; typeof o.only") == "undefined"
    end

    test "getOwnPropertyDescriptor, getOwnPropertyNames and propertyIsEnumerable" do
      assert js("Object.getOwnPropertyNames([1, 2]).join()") == "0,1,length"

      assert js(
               "var o = {a: 1}; Object.defineProperty(o, 'h', {value: 1}); Object.getOwnPropertyNames(o).join() + '|' + o.propertyIsEnumerable('a') + o.propertyIsEnumerable('h')"
             ) == "a,h|truefalse"

      assert js("Object.getOwnPropertyDescriptor({}, 'nope')") == :undefined

      assert js(
               "var d = Object.getOwnPropertyDescriptor({get x() { return 1 }}, 'x'); typeof d.get + typeof d.set + d.enumerable"
             ) == "functionundefinedtrue"
    end

    test "freeze, seal and preventExtensions" do
      assert js(
               "var o = Object.freeze({a: 1}); o.a = 9; o.b = 1; delete o.a; o.a + ',' + o.b + ',' + Object.isFrozen(o)"
             ) == "1,undefined,true"

      assert js(
               "var o = Object.seal({a: 1}); o.a = 2; o.z = 1; delete o.a; o.a + ',' + o.z + ',' + Object.isSealed(o) + Object.isFrozen(o)"
             ) == "2,undefined,truefalse"

      assert js(
               "var o = Object.preventExtensions({a: 1}); o.b = 1; Object.isExtensible(o) + ',' + o.b"
             ) == "false,undefined"

      assert js("var a = Object.freeze([1, 2]); a[0] = 9; a[5] = 1; a.length + ',' + a[0]") ==
               "2,1"
    end

    test "Object.create with a descriptor map, prototypes and Object.is" do
      assert js(
               "var p = {i: 1}; var o = Object.create(p, {own: {value: 2, enumerable: true}}); o.i + ',' + o.own + ',' + (Object.getPrototypeOf(o) === p)"
             ) == "1,2,true"

      assert js("var o = Object.create(null); Object.getPrototypeOf(o)") == nil
      assert js("var o = {}; Object.setPrototypeOf(o, {z: 3}); o.z") == 3.0

      assert js("[Object.is(NaN, NaN), Object.is(0, -0), Object.is(1, 1)].join()") ==
               "true,false,true"
    end
  end

  describe "array methods on array-likes" do
    test "work on any object with a length" do
      assert js(
               "var o = {length: 3, 0: 'a', 1: 'b', 2: 'c'}; Array.prototype.map.call(o, x => x + x).join()"
             ) == "aa,bb,cc"

      assert js(
               "var o = {length: 2, 0: 1, 1: 2}; Array.prototype.push.call(o, 3, 4); [o.length, o[2], o[3]].join()"
             ) == "4,3,4"

      assert js(
               "var o = {length: 3, 0: 1, 1: 2, 2: 3}; Array.prototype.reverse.call(o); [o[0], o[1], o[2]].join()"
             ) == "3,2,1"

      assert js(
               "var o = {length: 2, 0: 5, 1: 6}; [Array.prototype.indexOf.call(o, 6), Array.prototype.slice.call(o).join(), Array.prototype.pop.call(o), o.length].join()"
             ) == "1,5,6,6,1"

      assert js("Array.prototype.join.call('abc', '-')") == "a-b-c"

      assert js("var o = {length: 0}; Array.prototype.shift.call(o) + ',' + o.length") ==
               "undefined,0"
    end

    test "null and undefined are rejected, and so is a callback that is not a function" do
      assert js("try { Array.prototype.map.call(null, x => x) } catch (e) { e.name }") ==
               "TypeError"

      assert js("try { [].forEach(1) } catch (e) { e.name }") == "TypeError"
      assert js("try { [1].reduce(2) } catch (e) { e.name }") == "TypeError"
      assert js("try { new Array(-1) } catch (e) { e.name }") == "RangeError"
    end

    test "holes are skipped, count in the length, and read through the prototype" do
      assert js(
               "var a = [1, , 3]; var n = 0; a.forEach(function () { n++ }); [n, a.length, 1 in a].join()"
             ) == "2,3,false"

      assert js("var a = new Array(3); [a.length, 0 in a].join()") == "3,false"

      assert js(
               "Array.prototype[1] = 'p'; var a = [0, , 2]; var seen = []; a.forEach(function (v) { seen.push(v) }); delete Array.prototype[1]; seen.join()"
             ) == "0,p,2"

      assert js("[1, , 3].map(x => x * 2).length + ',' + (1 in [1, , 3].map(x => x))") ==
               "3,false"

      assert js("var r = [, , 5].reduce(function (a, b) { return a + b }); r") == 5.0
    end

    test "a callback that changes the array is seen by the rest of the iteration" do
      assert js(
               "var arr = [1, 2, , 4]; var n = 0; arr.forEach(function () { n++; arr[2] = 3 }); n"
             ) == 4.0
    end
  end

  describe "classes" do
    test "constructors, methods, accessors and statics" do
      assert js(
               "class A { constructor(x) { this.x = x } get double() { return this.x * 2 } static make(n) { return new A(n) } add(n) { return this.x + n } } var a = A.make(4); [a.x, a.double, a.add(1), a instanceof A, typeof A].join()"
             ) == "4,8,5,true,function"

      assert js(
               "class A { m() {} static get z() { return 'sz' } set v(x) { this._v = x * 2 } } var a = new A; a.v = 4; [A.z, a._v, Object.keys(a).join(), Object.getOwnPropertyNames(A.prototype).join()].join()"
             ) == "sz,8,_v,constructor,m,v"

      assert js("var C = class Named { who() { return Named.name } }; new C().who()") == "Named"
    end

    test "extends, super calls and super.method" do
      assert js(
               "class A { constructor(x) { this.x = x } hi() { return 'A' + this.x } } class B extends A { constructor() { super(7); this.y = 1 } hi() { return 'B' + super.hi() } } var b = new B; [b.x, b.y, b.hi(), b instanceof A, Object.getPrototypeOf(B) === A].join()"
             ) == "7,1,BA7,true,true"

      assert js("class A { constructor() { this.n = 1 } } class B extends A {} new B().n") == 1.0

      assert js(
               "class A { static s() { return 'static' } } class B extends A { static s() { return super.s() + '!' } } B.s()"
             ) == "static!"
    end

    test "extending built-ins" do
      assert js(
               "class E extends Error { constructor(m) { super(m); this.name = 'E' } } var e = new E('boom'); [e.message, e.name, e instanceof Error, e instanceof E].join()"
             ) == "boom,E,true,true"

      assert js(
               "class L extends Array { sum() { return this.reduce((a, b) => a + b, 0) } } var l = new L(); l.push(1, 2, 3); [l.length, l.sum(), Array.isArray(l)].join()"
             ) == "3,6,true"
    end

    test "fields, static fields and static blocks" do
      assert js(
               "class P { a = 1; b = this.a + 1; static s = 5; static { P.t = P.s * 2 } } var p = new P; [p.a, p.b, P.s, P.t].join()"
             ) == "1,2,5,10"
    end

    test "misuse is an error" do
      assert js("class A {} try { A() } catch (e) { e.name + ': ' + e.message }") ==
               "TypeError: Class constructor A cannot be invoked without 'new'"

      assert js(
               "class A {} class B extends A { constructor() { this.x = 1; super() } } try { new B } catch (e) { e.name }"
             ) == "ReferenceError"

      assert js("try { class X extends 5 {} } catch (e) { e.name }") == "TypeError"
    end

    test "async methods" do
      assert logs_of(
               "class A { async f() { return await 1 } } new A().f().then(v => console.log('v', v))"
             ) == ["v 1"]
    end
  end

  describe "web-page staples" do
    test "numeric separators" do
      assert js("[1_000, 0x1_F, 1_0.5_0, 1e1_0]") == [1000.0, 31.0, 10.5, 1.0e10]
      assert js("try { eval('1__0') } catch (e) { e.name }") == "SyntaxError"
      assert js("try { eval('1_') } catch (e) { e.name }") == "SyntaxError"
    end

    test "new.target" do
      assert js("function F() { return new.target } F() === undefined") == true
      assert js("function G() { this.t = new.target === G } new G().t") == true

      assert js(
               "class A { constructor() { this.n = new.target.name } } class B extends A {} new B().n"
             ) == "B"
    end

    test "URI encoding" do
      assert js("encodeURIComponent('a b&é/€')") == "a%20b%26%C3%A9%2F%E2%82%AC"
      assert js("decodeURIComponent('a%20b%26%C3%A9%2F%E2%82%AC')") == "a b&é/€"
      assert js("encodeURI('http://x/a b?q=é#h')") == "http://x/a%20b?q=%C3%A9#h"
      assert js("decodeURI('%41%2F')") == "A%2F"
      assert js("try { decodeURIComponent('%E0%A4%A') } catch (e) { e.name }") == "URIError"
    end

    test "newer array and object methods" do
      assert js("[1, 2, 3].findLast(x => x < 3)") == 2.0
      assert js("[1, 2, 3].findLastIndex(x => x > 5)") == -1.0
      assert js("[3, 1, 2].toSorted().join()") == "1,2,3"
      assert js("var a = [3, 1]; a.toSorted(); a.join()") == "3,1"
      assert js("[1, 2].toReversed().join()") == "2,1"
      assert js("[1, 2, 3].with(1, 9).join()") == "1,9,3"
      assert js("[1, 2, 3].toSpliced(1, 1).join()") == "1,3"

      assert js(
               "var g = Object.groupBy([1, 2, 3, 4], x => x % 2 ? 'odd' : 'even'); g.odd.join() + '/' + g.even.join()"
             ) == "1,3/2,4"
    end
  end

  describe "generators" do
    test "next, return and the value sent in" do
      assert logs_of("""
             function* g(a) { var x = yield a; console.log('x=' + x); try { yield 2 } finally { console.log('fin') } return 9 }
             var it = g(1);
             console.log(JSON.stringify([it.next(), it.next('A'), it.return(5), it.next()]))
             """) == [
               "x=A",
               "fin",
               ~s([{"value":1,"done":false},{"value":2,"done":false},{"value":5,"done":true},{"done":true}])
             ]
    end

    test "throw goes in at the yield" do
      assert js("""
             function* t() { try { yield 1 } catch (e) { yield 'caught ' + e } }
             var i = t(); i.next(); i.throw('boom').value
             """) == "caught boom"
    end

    test "for of pulls one value at a time and closes the iterator on break" do
      assert logs_of("""
             function* nat() { try { var i = 0; while (true) yield i++ } finally { console.log('closed') } }
             var r = []; for (var n of nat()) { if (n > 2) break; r.push(n) }
             console.log(r.join())
             """) == ["closed", "0,1,2"]
    end

    test "yield*, spread and destructuring" do
      assert js("""
             function* a() { yield 1; yield* [2, 3]; yield* b() }
             function* b() { yield 4; return 'r' }
             [[...a()].join(), Array.from(a()).length]
             """) == ["1,2,3,4", 4.0]

      assert js(
               "function* a() { yield 1; yield 2; yield 3 } var [p, ...r] = a(); p + ':' + r.join()"
             ) ==
               "1:2,3"
    end

    test "methods and the generator prototype" do
      assert js("""
             class C { *items() { yield 1; yield 2 } static *s() { yield 's' } }
             var o = { *[Symbol.iterator]() { yield 'it' } };
             [[...new C().items()].join(), C.s().next().value, [...o].join()]
             """) == ["1,2", "s", "it"]

      assert js(
               "function* g() {} var i = g(); [Object.getPrototypeOf(i) === g.prototype, i[Symbol.iterator]() === i]"
             ) ==
               [true, true]

      assert js("function* g() {} try { new g() } catch (e) { e.name }") == "TypeError"
    end

    test "yield is an ordinary name outside generators" do
      assert js("var yield = 3; yield + 1") == 4.0
    end
  end

  describe "private class members" do
    test "fields, methods, accessors and statics" do
      assert js("""
             class A {
               #x = 1; #y; static #n = 0;
               constructor(y) { this.#y = y }
               static inc() { return ++A.#n }
               #sum() { return this.#x + this.#y }
               #acc = 5;
               get #dbl() { return this.#acc * 2 }
               set #dbl(v) { this.#acc = v }
               run() { this.#dbl = 7; return [this.#sum(), this.#dbl] }
               bump() { this.#x++; this.#x += 10; return this.#x }
             }
             var a = new A(2);
             [a.run().join(), a.bump(), A.inc(), A.inc(), Object.keys(a).length, JSON.stringify(a)]
             """) == ["3,14", 12.0, 1.0, 2.0, 0.0, "{}"]
    end

    test "#x in obj, optional chains and subclasses" do
      assert js("""
             class A { #x = 1; static has(o) { return #x in o } opt(o) { return o?.#x } }
             class B extends A { #z = 3; z() { return this.#z } }
             [A.has(new A), A.has({}), new A().opt(null), new B().z()]
             """) == [true, false, :undefined, 3.0]
    end

    test "a foreign object has no such member" do
      assert js(
               "class A { #x; static read(o) { return o.#x } } try { A.read({}) } catch (e) { e.name }"
             ) ==
               "TypeError"
    end

    test "early errors" do
      for src <- [
            "class A { m() { this.#nope } }",
            "this.#x",
            "class A { #x; #x }",
            "class A { #constructor }",
            "class A { #x; m() { delete this.#x } }"
          ] do
        assert {:syntax, _} = error(src)
      end
    end
  end

  describe "async generators and for await" do
    test "next, return, yield*, and queued requests" do
      assert logs_of("""
             async function* ag() { var x = yield 1; console.log('got ' + x); try { yield Promise.resolve(2) } finally { console.log('fin') } return 3 }
             var it = ag();
             var rs = [it.next(), it.next('X'), it.return(9), it.next()];
             Promise.all(rs).then(v => console.log(JSON.stringify(v)))
             """) == [
               "got X",
               "fin",
               ~s([{"value":1,"done":false},{"value":2,"done":false},{"value":9,"done":true},{"done":true}])
             ]
    end

    test "for await over async and sync iterables, closing on break" do
      assert logs_of("""
             async function* inner() { yield 'a'; yield 'b' }
             async function* outer() { yield* inner(); yield* [1, Promise.resolve(2)] }
             async function* endless() { try { var i = 0; while (true) yield i++ } finally { console.log('closed') } }
             (async () => {
               var acc = [];
               for await (var v of outer()) acc.push(v);
               for await (var v of [Promise.resolve('p'), 'q']) acc.push(v);
               console.log(acc.join());
               for await (const n of endless()) { if (n > 1) break }
             })()
             """) == ["a,b,1,2,p,q", "closed"]
    end

    test "methods and errors" do
      assert logs_of("""
             var o = { async *m() { yield 'm' } };
             class C { static async *s() { yield 's' } async *[Symbol.asyncIterator]() { yield 'ci' } }
             (async () => {
               for await (var v of o.m()) console.log(v);
               for await (var v of C.s()) console.log(v);
               for await (var v of new C()) console.log(v);
               try { for await (var z of (async function*() { throw new Error('bad') })()); } catch (e) { console.log(e.message) }
             })()
             """) == ["m", "s", "ci", "bad"]
    end
  end

  describe "typed arrays" do
    test "element types wrap, clamp and keep floats" do
      assert js("new Uint8Array([1, 2, 300, -1]).join()") == "1,2,44,255"
      assert js("new Uint8ClampedArray([300, -5, 1.5, 2.5]).join()") == "255,0,2,2"
      assert js("var a = new Int16Array(2); a[0] = 40000; a[0]") == -25536.0

      assert js("var f = new Float32Array(3); f[0] = 1.5; f[1] = NaN; f[2] = 1e40; f.join()") ==
               "1.5,NaN,Infinity"

      assert js("var a = new Uint8Array(2); a[5] = 1; [a.length, a[5]]") == [2.0, :undefined]
    end

    test "views share a buffer, DataView reads both byte orders" do
      assert js("""
             var buf = new ArrayBuffer(8), dv = new DataView(buf);
             dv.setUint16(0, 0x1234); dv.setFloat32(4, 2.5, true);
             var b = new Uint8Array(buf), i32 = new Int32Array(buf, 4, 1);
             [b.join(), dv.getUint16(0), dv.getUint16(0, true), dv.getFloat32(4, true), buf.byteLength, i32.length, i32.byteOffset]
             """) == ["18,52,0,0,0,0,32,64", 4660.0, 13330.0, 2.5, 8.0, 1.0, 4.0]
    end

    test "array methods, iteration and construction" do
      assert js("""
             var s = new Uint8Array([5, 3, 9, 1]);
             [s.sort().join(), s.map(x => x * 2).join(), [...s].join(), s.subarray(1, 3).join(),
              s.slice(2).join(), s.reduce((a, b) => a + b), s.indexOf(9), s.includes(3),
              Uint8Array.from([1, 2, 3], x => x * 3).join(), Uint8Array.of(7, 8).join(),
              Uint8Array.BYTES_PER_ELEMENT]
             """) == [
               "1,3,5,9",
               "2,6,10,18",
               "1,3,5,9",
               "3,5",
               "5,9",
               18.0,
               3.0,
               true,
               "3,6,9",
               "7,8",
               1.0
             ]
    end

    test "TextEncoder and TextDecoder" do
      assert js(
               "var t = new TextEncoder().encode('h\u00e9llo \u20ac'); [t.length, new TextDecoder().decode(t)]"
             ) ==
               [10.0, "héllo €"]
    end
  end

  describe "scope lifetime" do
    test "closures keep the scopes of calls, blocks and loop iterations alive" do
      assert js(
               "var fs = []; function mk(n) { { let k = n * 2; fs.push(() => k + n) } } " <>
                 "for (let i = 0; i < 3; i++) mk(i); " <>
                 "for (let j = 0; j < 3; j++) fs.push(() => j); " <>
                 "for (const x of [7, 8]) fs.push(() => x); " <>
                 "fs.map(f => f()).join()"
             ) == "0,3,6,0,1,2,7,8"
    end

    test "a closure made in a for loop's update expression sees that iteration's variable" do
      assert js(
               "var fs = []; for (let i = 0; i < 3; fs.push(() => i), i++) {} fs.map(f => f()).join()"
             ) == "1,2,3"
    end
  end
end
