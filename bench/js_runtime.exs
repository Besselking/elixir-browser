# Usage: mix run --no-start bench/js_runtime.exs
# Times a few JS-heavy programs (calls, closures, property access, array/string work, allocation).
alias Browser.JS

programs = [
  {"fib(25) recursive calls", "function fib(n){ return n < 2 ? n : fib(n-1) + fib(n-2) } fib(25)"},
  {"loop with closures",
   "var s = 0; var add = function(a){ return function(b){ return a + b } }; for (var i = 0; i < 60000; i++) { s = add(i)(s) % 1000003 } s"},
  {"object property access",
   "var o = {a:1,b:2,c:3}; var t = 0; for (let i = 0; i < 60000; i++) { o.a = i; t += o.a + o.b + o.c } t"},
  {"array push/map/reduce",
   "var a = []; for (var i = 0; i < 20000; i++) a.push(i); a.map(x => x * 2).filter(x => x % 3 == 0).reduce((p, c) => p + c, 0)"},
  {"string building", "var s = ''; for (var i = 0; i < 20000; i++) { s += String(i % 10) } s.length"},
  {"class method calls",
   "class P { constructor(x){ this.x = x } inc(){ this.x++; return this } } var p = new P(0); for (var i = 0; i < 30000; i++) p.inc(); p.x"}
]

opts = [max_steps: 100_000_000, timeout: 120_000]

for {name, src} <- programs do
  {us, res} = :timer.tc(fn -> JS.eval(src, opts) end)
  val = elem(res, 1)
  IO.puts(String.pad_trailing(name, 28) <> String.pad_leading("#{div(us, 1000)} ms", 9) <> "   => #{inspect(val)}")
end
