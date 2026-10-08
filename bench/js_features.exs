# Usage: mix run --no-start bench/js_features.exs
# Parse time of a large generated source, then run time of programs that lean on one language
# feature each (promises, async/await, generators, destructuring, regexps, JSON, Map/Set, classes,
# template strings, typed arrays, BigInt). A program that the commit doesn't support prints "unsupported".
alias Browser.JS

opts = [max_steps: 100_000_000, timeout: 120_000]

ms = fn fun ->
  {us, res} = :timer.tc(fun)
  {div(us, 1000), res}
end

row = fn name, t, extra ->
  IO.puts(String.pad_trailing(name, 30) <> String.pad_leading("#{t} ms", 9) <> "   " <> extra)
end

big =
  String.duplicate(
    "{ function f(a, b) { var o = {x: a, y: [b, 1, 2], z: `t${a}`}; if (a > b) { return o.x + o.y[0] } else { for (let i = 0; i < 3; i++) o.x += i } return (a, b) => a * b + o.x }\n" <>
      "class K extends Object { constructor(v) { super(); this.v = v } get w() { return this.v } static s(x) { return x?.y ?? 0 } } }\n",
    1500
  )

{t, res} = ms.(fn -> JS.parse(big) end)
row.("parse #{div(byte_size(big), 1000)} KB source", t, inspect(elem(res, 0)))

programs = [
  {"promise chain 5k",
   "var r = 0; var p = Promise.resolve(0); for (var i = 0; i < 5000; i++) p = p.then(v => v + 1); p.then(v => { r = v }); r"},
  {"async/await loop 3k",
   "var r = 0; (async () => { for (var i = 0; i < 3000; i++) { r += await i } })(); r"},
  {"generator 20k yields",
   "function* g(){ for (var i = 0; i < 20000; i++) yield i } var s = 0; for (var v of g()) s += v; s"},
  {"destructuring + spread 10k",
   "var s = 0; for (var i = 0; i < 10000; i++) { var [a, b, ...c] = [i, 2, 3, 4]; var {x, y = 5, ...rest} = {x: a, z: b}; s += x + y + c.length + [...c, a].length + Object.keys({...rest, q: 1}).length } s"},
  {"regexp exec/replace 3k",
   "var s = 0; for (var i = 0; i < 3000; i++) { var m = /(\\d+)-(\\w+)/.exec('item 42-abc ' + i); s += m[1].length; s += 'a,b,c,d'.replace(/,/g, ';').length } s"},
  {"JSON round trip 300",
   "var o = {a: [1,2,3,{b: 'x'}], c: 'hello', d: {e: null, f: true}}; var s = 0; for (var i = 0; i < 300; i++) { s += JSON.parse(JSON.stringify(o)).a.length } s"},
  {"Map/Set 10k",
   "var m = new Map, st = new Set; for (var i = 0; i < 10000; i++) { m.set('k' + i, i); st.add(i % 100) } var t = 0; for (var [k, v] of m) t += v; t + st.size"},
  {"class + getters 20k",
   "class A { #p = 1; get p() { return this.#p } set p(v) { this.#p = v } static make(n) { return new B(n) } } class B extends A { constructor(n) { super(); this.n = n } sum() { return this.p + this.n } } var t = 0; for (var i = 0; i < 20000; i++) { var b = A.make(i); b.p = 2; t += b.sum() } t"},
  {"template strings 20k",
   "var s = 0; for (var i = 0; i < 20000; i++) { s += `item ${i}: ${i * 2}`.length } s"},
  {"typed array fill/sum 20k",
   "var a = new Float64Array(20000); for (var i = 0; i < a.length; i++) a[i] = i * 0.5; var s = 0; for (var i = 0; i < a.length; i++) s += a[i]; s"},
  {"BigInt factorial 200",
   "var r = 1n; for (var i = 1n; i <= 200n; i++) r *= i; r.toString().length"},
  {"try/catch + throw 5k",
   "var c = 0; for (var i = 0; i < 5000; i++) { try { if (i % 2) throw new Error('x' + i); c++ } catch (e) { c += e.message.length } } c"},
  {"Array sort 5k objects",
   "var a = []; for (var i = 0; i < 5000; i++) a.push({k: (i * 7919) % 5003}); a.sort((x, y) => x.k - y.k); a[0].k + a[4999].k"}
]

for {name, src} <- programs do
  {t, res} = ms.(fn -> JS.eval(src, opts) end)

  extra =
    case res do
      {:ok, val, _} -> "=> #{inspect(val)}"
      other -> "unsupported/failed: #{inspect(other, limit: 3, printable_limit: 80)}"
    end

  row.(name, t, extra)
end
