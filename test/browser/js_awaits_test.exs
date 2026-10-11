defmodule Browser.JS.AwaitsTest do
  # Step 4: await facts. `Browser.JS.Awaits.any?/1` replaces the two copies of the await
  # walk in `Async.has_await?/1` and `Resolve.awaits?/1`. The loop-entry facts of the design
  # failed their gate and are left to step 5, so unit test 4 pins the walks of a loop as they
  # are now. The design is notes/js-step4-design.md. The unit tests of section 5.2 compare
  # the new walk with a copy of the walk of ca43138, guard the list of leaf forms, and count
  # the walk's visits. The snippets of section 5.3 pin the results of ca43138 at every
  # resolver level.
  #
  # The unit tests call `Browser.JS.Awaits` or count the visits of the step 4 walk, so they
  # pass only after step 4. The snippet tests also pass on ca43138.
  use ExUnit.Case, async: true

  alias Browser.JS
  alias Browser.JS.{Awaits, Interp, Parser}
  alias Browser.JS.Resolve.Info

  # Every level, because levels 1 to 3 mix rewritten and old-path functions in one program.
  @levels [:off, :info, 1, 2, 3, 4]

  # True in the check build (`JS_RESOLVE_CHECK=1`). There the evaluator runs extra walks to
  # compare its results with the old code (design 5.1), so the visit counts do not apply.
  @check Application.compile_env(:browser, :js_resolve_check, false)

  # ── helpers ────────────────────────────────────────────────

  # Starts a heap in the test process. The built-ins must exist because an error thrown by
  # the evaluator is an object with a prototype.
  defp heap do
    Interp.init(1_000_000)
    Browser.JS.Builtins.install()
    Interp.global()
  end

  defp run_script(src, level) do
    assert {:ok, program} = Parser.parse(src, resolve: level), src
    Interp.run_program(program, true)
  end

  # The walk of `Async.has_await?/1` on ca43138, kept here as the reference for
  # `Awaits.any?/1`. It must not change when the evaluator changes, because it defines the
  # answer that the new walk must give.
  defp ref_any?({:await, _}), do: true
  defp ref_any?({:yield, _, _}), do: true
  defp ref_any?({:forawait, _, _, _, _}), do: true
  defp ref_any?({:forawait, _, _, _, _, _}), do: true
  defp ref_any?({:using, :await_using, _, _, _}), do: true
  defp ref_any?({:gen, _}), do: false
  defp ref_any?({:fn, _, _, _, _, _}), do: false
  defp ref_any?({:async, _}), do: false
  defp ref_any?(t) when is_tuple(t), do: t |> Tuple.to_list() |> Enum.any?(&ref_any?/1)
  defp ref_any?(l) when is_list(l), do: Enum.any?(l, &ref_any?/1)
  defp ref_any?(_), do: false

  # Every tuple and every non-empty list in `t`, `t` included. A list gives each of its
  # tails too, because the walk visits each tail. The search goes into function nodes, so
  # that the bodies of nested functions are in the corpus too, and stops at maps.
  defp subterms(t, acc \\ [])

  defp subterms(t, acc) when is_tuple(t),
    do: t |> Tuple.to_list() |> Enum.reduce([t | acc], &subterms/2)

  defp subterms([h | rest] = l, acc), do: subterms(rest, subterms(h, [l | acc]))
  defp subterms(_, acc), do: acc

  defp find(node, pred) do
    cond do
      pred.(node) -> node
      is_tuple(node) -> node |> Tuple.to_list() |> find(pred)
      is_list(node) -> Enum.find_value(node, &find(&1, pred))
      true -> nil
    end
  end

  defp parse!(src, level) do
    assert {:ok, tree} = Parser.parse(src, resolve: level), "#{level}: #{src}"
    tree
  end

  # Runs `fun` while the calls of the functions `mfas` in this process are traced, local
  # calls included. Returns the result of `fun` and the calls in the order in which they
  # began, each as `{mfa, args, depth, outcome}`. This is the helper of
  # js_frames_test.exs. The tracer is a process of its own, because the traced process
  # cannot be its own tracer.
  defp traced(mfas, fun) do
    me = self()
    tracer = spawn_link(fn -> trace_loop([]) end)

    for mfa <- mfas,
        do: :erlang.trace_pattern(mfa, [{:_, [], [{:exception_trace}]}], [:local])

    :erlang.trace(me, true, [:call, {:tracer, tracer}])

    result =
      try do
        fun.()
      after
        :erlang.trace(me, false, [:call])
        for mfa <- mfas, do: :erlang.trace_pattern(mfa, false, [:local])
      end

    # The trace messages are sent before this returns, so the tracer has them all.
    ref = :erlang.trace_delivered(me)

    receive do
      {:trace_delivered, ^me, ^ref} -> :ok
    end

    send(tracer, {:done, me})

    msgs =
      receive do
        {:trace_msgs, m} -> m
      end

    {result, pair(msgs)}
  end

  defp trace_loop(acc) do
    receive do
      {:done, to} -> send(to, {:trace_msgs, Enum.reverse(acc)})
      m -> trace_loop([m | acc])
    end
  end

  # Pairs each call message with its return or exception message. The return messages of
  # one process come in the reverse order of their calls, so a stack is enough.
  defp pair(msgs) do
    {calls, _open, _n} =
      Enum.reduce(msgs, {%{}, [], 0}, fn
        {:trace, _, :call, {m, f, args}}, {calls, open, n} ->
          {Map.put(calls, n, {{m, f, length(args)}, args, length(open), :open}), [n | open],
           n + 1}

        {:trace, _, kind, _mfa, v}, {calls, [i | open], n}
        when kind in [:return_from, :exception_from] ->
          {Map.update!(calls, i, &put_elem(&1, 3, {kind, v})), open, n}
      end)

    calls |> Enum.sort() |> Enum.map(&elem(&1, 1))
  end

  # The arguments of the calls of `fun` (a name) that run inside no other traced call.
  # These are the roots of the walks.
  defp roots(calls, fun), do: for({{_, ^fun, _}, [arg], 0, _} <- calls, do: arg)

  # ── the corpus ─────────────────────────────────────────────

  # The bench programs of the 2e group and the five programs of design 1.2, with loop
  # counts of 3. The count does not change the shape of the tree, and a small count keeps
  # the traced runs short. Each one runs in the wrapper of bench/js_runtime.exs.
  @bench [
    {"await",
     "var box = {}; async function run(){ var s = 0; for (let i = 0; i < 3; i++) { s = (s + await i) % 1000003 } return s } run().then(v => { box.v = v }); return box"},
    {"asynccalls",
     "var box = {}; async function add(a, b){ return a + b } async function run(){ var s = 0; for (let i = 0; i < 3; i++) { s = (await add(s, i)) % 1000003 } return s } run().then(v => { box.v = v }); return box"},
    {"awaitclosures",
     "var box = {}; async function run(){ var fs = []; for (let i = 0; i < 3; i++) { await null; fs.push(() => i) } var s = 0; for (var j = 0; j < fs.length; j++) s += fs[j](); return s } run().then(v => { box.v = v }); return box"},
    {"genrange",
     "function* range(n){ for (let i = 0; i < n; i++) yield i } var s = 0; for (const v of range(3)) s = (s + v) % 1000003; return s"},
    {"yieldstar",
     "function* two(){ yield 1; yield 2 } function* outer(n){ for (let i = 0; i < n; i++) yield* two() } var s = 0; for (const v of outer(3)) s += v; return s"},
    {"asyncgen",
     "var box = {}; async function* ag(n){ for (let i = 0; i < n; i++) yield i } async function run(){ var s = 0; for await (const v of ag(3)) s += v; return s } run().then(v => { box.v = v }); return box"},
    {"bigasync",
     "var box = {}; async function step(x){ return x } async function run(){ var s = 0; for (let i = 0; i < 3; i++) { if (i % 3 == 0) { s += 1 } else { s += 2 } var o = {a: i, b: [i, i + 1], c: {d: i * 2}}; try { s = (s + o.a + o.b[1] + o.c.d) % 1000003; s = (s + await step(i)) % 1000003 } catch (e) { s = -1 } finally { s += 0 } for (var j = 0; j < 3; j++) { s = (s + j) % 1000003 } } return s } run().then(v => { box.v = v }); return box"},
    {"litlike",
     "var box = {}; class El { constructor(){ this.n = 0; this.p = Promise.resolve(true) } async scheduleUpdate(){ this.isPending = true; try { await this.p } catch (e) { Promise.reject(e) } const r = this.performUpdate(); if (r != null) { await r } return !this.isPending } performUpdate(){ this.n++; this.isPending = false; const changed = new Map(); changed.set('x', this.n); if (this.shouldUpdate(changed)) { this.update(changed) } } shouldUpdate(c){ return c.size > 0 } update(c){ this.last = c.get('x') } } async function run(){ var e = new El(); for (let i = 0; i < 3; i++) { await e.scheduleUpdate() } return e.n } run().then(v => { box.v = v }); return box"},
    {"runnerlike",
     "var box = {}; var log = []; async function measure(name, fn){ const start = Date.now(); let result; try { result = await fn(); } finally { const end = Date.now(); log.push({name, t: end - start}); } return result } async function suite(i){ const a = await measure('a', async () => i + 1); const b = await measure('b', async () => { let t = 0; for (let k = 0; k < 5; k++) t += k; return t + a }); return {a, b, total: a + b} } async function run(){ let s = 0; for (let i = 0; i < 3; i++) { const r = await suite(i); s = (s + r.total) % 1000003 } return s } run().then(v => { box.v = v }); return box"},
    {"exprawait",
     "var box = {}; var o = {a: 1, b: [1, 2, 3], k(x, y){ return x + y }}; async function g(x){ return x } async function run(){ var s = 0; for (let i = 0; i < 3; i++) { const {a = await g(i), b} = {b: await g(1)}; s = (s + a * b + o.a * 2 + (await g(i)) * 2 + [await g(1), i][0] + o.k(await g(2), i) + `${await g('t')}`.length) % 1000003 } return s } run().then(v => { box.v = v }); return box"},
    {"appish",
     "var box = {}; var st = {items: [], n: 0}; function upd(x){ st.n += x; return st.n } async function load(i){ return {id: i, title: 't' + i, done: i % 2 === 0} } async function run(){ var s = 0; for (let i = 0; i < 3; i++) { const it = await load(i); st.items.push(it); if (it.done) { s += upd(1) } else { s += upd(2) } const label = it.title + ':' + (it.done ? 'yes' : 'no'); s += label.length; st.items.length > 100 && st.items.shift() } return s } run().then(v => { box.v = v }); return box"}
  ]

  defp bench_src(body), do: "(function(){ function f(){ #{body} } return f() })()"

  # The rows of the step 2e table and its level differences, read from
  # js_frames_test.exs, so that this corpus grows when a row is added there.
  @frames_file Path.join(__DIR__, "js_frames_test.exs")
  @external_resource @frames_file

  @frames_rows (fn ->
                  {:ok, ast} = @frames_file |> File.read!() |> Code.string_to_quoted()

                  {_, found} =
                    Macro.prewalk(ast, %{}, fn
                      {:@, _, [{name, _, [list]}]} = node, acc
                      when name in [:rows_2e, :diffs_2e] ->
                        {value, _} = Code.eval_quoted(list)
                        {node, Map.put(acc, name, value)}

                      node, acc ->
                        {node, acc}
                    end)

                  rows =
                    for {_n, kind, src, _v} <- Map.fetch!(found, :rows_2e),
                        do: if(kind == :r, do: "var r=[]; " <> src <> "; r", else: src)

                  diffs =
                    for {_n, src, _off, _spec} <- Map.fetch!(found, :diffs_2e),
                        do: "var r=[]; " <> src <> "; r"

                  rows ++ diffs
                end).()

  # ── 5.3: the snippets ──────────────────────────────────────

  # Each snippet runs as `var r=[]; <src>; r` through `JS.eval` and must give its value at
  # every level. The values are the results of ca43138, where every snippet gave the same
  # value at all six levels. The names start with E (expressions), G (generators), P
  # (patterns and other forms), L (loops) and U (the programs of unit test 4).
  @snippets [
    # A compound assignment reads its target first. On a `const`, it throws a TypeError
    # after the right side ran.
    {"E1",
     ~S|async function f(){ var o = {a: 1}; var x = 5; o.a += await 2; x -= await 1; r.push(o.a, x) } f()|,
     [3.0, 4.0]},
    {"E1b",
     ~S|async function f(){ const c = 1; try { c += await (r.push('rhs'), 1) } catch (e) { r.push(e.constructor.name) } r.push(c) } f()|,
     ["rhs", "TypeError", 1.0]},
    {"E1c",
     ~S|const c = 1; async function f(){ c += await 1 } f().catch(e => r.push(e.constructor.name, c))|,
     ["TypeError", 1.0]},
    {"E2",
     ~S|async function f(){ var x = 1; r.push([await 1, x += 1, ...[await 2, 3]].join(), x) } f()|,
     ["1,2,2,3", 2.0]},
    {"E3", ~S|async function f(){ var x = 'b'; r.push(`${await 'a'}-${x}`) } f()|, ["a-b"]},
    {"E3b",
     ~S|async function f(){ var x = 'b'; r.push(`${x}-${await (x = 'c', 'a')}-${x}`) } f()|,
     ["b-a-c"]},
    {"E4",
     ~S|async function f(){ var k = 'z'; var o = {k: await 1, [await k]: 2, ...{q: await 3}}; r.push(JSON.stringify(o)) } f()|,
     [~S|{"k":1,"z":2,"q":3}|]},
    {"E5",
     ~S|async function f(){ r.push(await 1 ? await 2 : 3, await 0 ? 2 : await 3, await '' ? 1 : 4) } f()|,
     [2.0, 3.0, 4.0]},
    {"E6",
     ~S|async function f(){ var o = null; var p = {a: 0}; r.push(o?.a ?? await 9, p?.a ?? await 8, o?.a.b ?? await 7) } f()|,
     [9.0, 0.0, 7.0]},
    {"E7",
     ~S|async function f(){ var x = 1; var g = null; var h = v => v + 1; r.push(g?.(await x), h?.(await x)) } f()|,
     [:undefined, 2.0]},
    {"E8",
     ~S|class C { constructor(v){ this.v = v } } async function f(){ var a = 4; r.push(new (await (r.push('C'), C))(await (r.push('a'), a)).v) } f()|,
     ["C", "a", 4.0]},
    # A name callee is read after the arguments at every level, so the new `g` runs. The
    # spec reads the callee first and gives "old1". Row 10 of step 2e pins the same order.
    {"E9",
     ~S|var g = v => 'old' + v; function h(){ g = v => 'new' + v; return 1 } async function f(){ r.push(g(await h())) } f()|,
     ["new1"]},
    {"E9b",
     ~S|async function f(){ let g = v => 'old' + v; const h = () => { g = v => 'new' + v; return 1 }; r.push(g(await h())) } f()|,
     ["new1"]},
    # A member callee lifts its object before the await, as the spec does.
    {"E9c",
     ~S|async function f(){ var o = {m(v){ return 'old' + v }}; const h = () => { o = {m(v){ return 'new' + v }}; return 1 }; r.push(o.m(await h())) } f()|,
     ["old1"]},
    # A BigInt literal is a leaf form, so this snippet puts one in the corpus.
    {"E10",
     ~S|async function f(){ var b = 1n + await 2n; r.push(String(b), typeof (await 3n)) } f()|,
     ["3", "bigint"]},
    {"G1",
     ~S|function* g(){ var x = yield 1; r.push(x); x = yield 2; r.push(x) } var it = g(); it.next(); it.next(5); it.next(6)|,
     [5.0, 6.0]},
    {"G2",
     ~S|function* g(){ var x = 3; return (yield x) + (yield 2) } var it = g(); r.push(it.next().value, it.next(10).value, it.next(20).value)|,
     [3.0, 2.0, 30.0]},
    {"G3",
     ~S|function* g(){ var s = 1; var a = [s, yield* [7, 8]]; r.push(a.length, a[0], a[1] === undefined) } r.push([...g()].join())|,
     [2.0, 1.0, true, "7,8"]},
    {"G4",
     ~S|async function* g(){ var x = yield 1; r.push(x); r.push([1, yield* [7, 8]].length) } (async () => { var it = g(); await it.next(); await it.next('in'); await it.next(); await it.next() })()|,
     ["in", 2.0]},
    {"P1",
     ~S|async function f(){ var p = Promise.resolve(4); var o = {}; var {a = await p} = o; var {b = await p} = {b: 1}; let [c = await p, d = await 5] = [undefined, 6]; r.push(a, b, c, d) } f()|,
     [4.0, 1.0, 4.0, 6.0]},
    {"P2",
     ~S|async function f(){ for await (const y of [1]) {} for await (const y of [1, Promise.resolve(2)]) r.push(y); r.push('ok') } f()|,
     [1.0, 2.0, "ok"]},
    {"P3",
     ~S|async function f(){ try { await using x = { [Symbol.asyncDispose](){ r.push('d'); throw new Error('boom') } }; r.push('body') } catch (e) { r.push(e.message) } r.push('after') } f()|,
     ["body", "d", "boom", "after"]},
    {"P3b",
     ~S|async function f(){ try { await using x = { [Symbol.asyncDispose](){ r.push('d'); return Promise.reject(new Error('rej')) } }; r.push('body'); await 0 } catch (e) { r.push(e.message) } } f()|,
     ["body", "d", "rej"]},
    {"P4",
     ~S|class A { async m(){ var k = 'z'; const C = class { [await k](){ return 1 } }; return new C().z() + Object.getOwnPropertyNames(C.prototype).join() } } new A().m().then(v => r.push(v))|,
     ["1constructor,z"]},
    {"L1",
     ~S|async function g(i){ return i + 1 } async function f(){ for (let i = 0; i < 3; i = await g(i)) { r.push(i) } r.push('end') } f()|,
     [0.0, 1.0, 2.0, "end"]},
    {"L1b",
     ~S|async function f(){ var fs = []; for (let i = 0; i < 3; i = await (i + 1)) { fs.push(() => i) } r.push(fs.map(g => g()).join()) } f()|,
     ["0,1,2"]},
    {"L2",
     ~S|var n = 0; async function more(){ return n++ < 2 } async function f(){ while (await more()) { r.push(n) } r.push('end', n) } f()|,
     [1.0, 2.0, "end", 3.0]},
    {"L3",
     ~S|var n = 0; async function t(){ return ++n < 3 } async function f(){ do { await 0; r.push(n) } while (await t()); r.push('end') } f()|,
     [0.0, 1.0, 2.0, "end"]},
    {"L3b",
     ~S|var n = 0; async function f(){ do { r.push(n) } while (await (++n < 3)); r.push('end') } f()|,
     [0.0, 1.0, 2.0, "end"]},
    {"L4",
     ~S|async function f(){ var x = 0; for (;;) { if (await x) break; x++; r.push(x) } r.push('end') } f()|,
     [1.0, "end"]},
    {"L5",
     ~S|async function f(){ var fs = []; for (let i = 0; i < 3; i++) { fs.push(() => i); await 0 } r.push(fs.map(g => g()).join()) } f()|,
     ["0,1,2"]},
    # A labelled `continue` goes to a loop whose test awaits.
    {"L6",
     ~S|async function f(){ var i = 0; L: while (await (i < 3)) { i++; for (var j = 0; j < 3; j++) { if (j == 1) continue L; r.push(i + ':' + j) } } r.push('end') } f()|,
     ["1:0", "2:0", "3:0", "end"]},
    {"L6b",
     ~S|async function f(){ L: for (let i = 0; await (i < 2); i++) { for (;;) { r.push(i); continue L } } r.push('end') } f()|,
     [0.0, 1.0, "end"]},
    {"L6c",
     ~S|async function f(){ var i = 0; L: do { i++; for (;;) { r.push(i); continue L } } while (await (i < 3)); r.push('end') } f()|,
     [1.0, 2.0, 3.0, "end"]},
    {"L7",
     ~S|function* g(){ var n = 0; for (; yield n;) { n++ } return 'done' } var it = g(); r.push(it.next().value, it.next(true).value, it.next(true).value, JSON.stringify(it.next(false)))|,
     [0.0, 1.0, 2.0, ~S|{"value":"done","done":true}|]},
    {"L7b",
     ~S|function* g(){ for (var i = 0; i < 2; i = yield i) {} } var it = g(); r.push(it.next().value, it.next(1).value, it.next(5).done)|,
     [0.0, 1.0, true]},
    {"L8",
     ~S|async function* g(){ var i = 0; while (i < 2) yield await i++ } (async () => { for await (const v of g()) r.push(v); r.push('end') })()|,
     [0.0, 1.0, "end"]},
    # An await in a loop part throws, and a `catch` outside the loop gets the error.
    {"L9",
     ~S|async function f(){ try { while (await Promise.reject(new Error('t'))) { r.push('no') } } catch (e) { r.push(e.message) } r.push('end') } f()|,
     ["t", "end"]},
    {"L9b",
     ~S|async function f(){ try { for (let i = 0; i < 3; await (i++ == 1 ? Promise.reject('u') : 0)) r.push(i) } catch (e) { r.push(e) } r.push('end') } f()|,
     [0.0, 1.0, "u", "end"]},
    {"L9c",
     ~S|async function f(){ try { do { r.push('body') } while (await Promise.reject('d')) } catch (e) { r.push(e) } } f()|,
     ["body", "d"]},
    # A getter in a loop part counts its calls: each part runs once in each round, and the
    # test runs once more at the end.
    {"L10",
     ~S|var calls = 0; var o = { get t(){ calls++; return calls <= 3 } }; async function f(){ while (o.t) { await 0 } r.push(calls) } f()|,
     [4.0]},
    {"L10b",
     ~S|var calls = 0, ups = 0; var o = { get t(){ calls++; return calls <= 3 }, get u(){ return ++ups } }; async function f(){ for (let i = 0; o.t; o.u) { await i } r.push(calls, ups) } f()|,
     [4.0, 3.0]},
    {"L10c",
     ~S|var calls = 0; var o = { get t(){ calls++; return calls <= 3 } }; async function f(){ do { await 0 } while (o.t); r.push(calls) } f()|,
     [4.0]},
    {"L10d",
     ~S|var calls = 0; var o = { get t(){ calls++; return calls <= 3 } }; function* g(){ for (var i = 0; o.t; i++) yield i } r.push([...g()].join(), calls)|,
     ["0,1,2", 4.0]},
    {"L10e",
     ~S|var calls = 0; var o = { get t(){ calls++; return Promise.resolve(calls <= 3) } }; async function f(){ while (await o.t) { r.push(calls) } r.push(calls) } f()|,
     [1.0, 2.0, 3.0, 4.0]},
    {"U4a",
     ~S|var s = 1; async function f(){ for (let i = 0; i < 3; i++) { s = (s + await i) % 7 } r.push(s) } f()|,
     [4.0]},
    {"U4b", ~S|async function f(){ var i = 0; while (i < 3) { await 0; i++ } r.push(i) } f()|,
     [3.0]},
    {"U4c", ~S|async function f(){ var i = 0; do { await 0; i++ } while (i < 3); r.push(i) } f()|,
     [3.0]},
    {"U4d", ~S|function* g(){ for (let i = 0; i < 3; i++) { yield i } } r.push([...g()].join())|,
     ["0,1,2"]}
  ]

  describe "5.3: the snippets" do
    test "every snippet gives the value of ca43138 at every level" do
      for {n, src, value} <- @snippets, level <- @levels do
        assert JS.eval("var r=[]; " <> src <> "; r", resolve: level) == {:ok, value, []},
               "#{n} at #{level}: #{src}"
      end
    end

    test "the async functions and generators of the snippets are rewritten at level 4" do
      # A snippet proves nothing about the frame path if its async function or generator
      # took the old path. Plain functions are always rewritten, so they prove nothing here.
      for {n, src, _} <- @snippets ++ for({k, src} <- races(), do: {k, src, nil}) do
        fns = cps_fns(parse!("var r=[]; " <> src <> "; r", 4))
        assert fns != [], "#{n}: no async function or generator"
        for info <- fns, do: assert(info.rewritten, "#{n}: #{inspect(info.name)} not rewritten")
      end
    end

    test "an expression that awaits lets other tasks run, at every level" do
      # One async task alone gives the same value on the sync path, because `Interp.ev`
      # waits for the promise. A second task shows the order: if the walk missed the await,
      # `f2` would come before `w1`. There is one row for each node kind that the leaf
      # forms of `Awaits` could hide by mistake.
      for {n, src} <- races(), level <- @levels do
        assert JS.eval(src, resolve: level) == {:ok, ["f1", "w1", "f2", "w2", "w3"], []},
               "#{n} at #{level}: #{src}"
      end
    end
  end

  # The function nodes under `{:async, _}` and `{:gen, _}` wrappers, as their `Info`.
  defp cps_fns(tree) do
    for {tag, inner} <- subterms(tree),
        tag in [:async, :gen],
        {:fn, _, _, _, _, %Info{} = info} <- [unwrap(inner)],
        do: info
  end

  defp unwrap({:gen, inner}), do: unwrap(inner)
  defp unwrap(node), do: node

  # A task `f` that evaluates one expression with an await, and a witness task `w`.
  defp races do
    w = "async function w(){ r.push('w1'); await 0; r.push('w2'); await 0; r.push('w3') } "

    exprs = [
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
      {"conditional", "", "var x = (await 1) ? 1 : 2"},
      {"logical", "", "var x = 0 || await 1"},
      {"unary", "", "var x = -(await 1)"},
      {"compound assignment", "var z = 0; ", "z += await 1"},
      {"class key", "", "var x = class { [await 'm']() {} }"},
      {"pattern default", "", "var {p = await 1} = {}"}
    ]

    for {n, pre, stmt} <- exprs do
      {n,
       "var r = []; " <>
         pre <> w <> "async function f(){ r.push('f1'); #{stmt}; r.push('f2') } f(); w(); r"}
    end
  end

  # The sources of unit tests 1 and 2: the bench programs, the rows of the 2e table and
  # the snippets.
  defp corpus do
    for({_, body} <- @bench, do: bench_src(body)) ++
      @frames_rows ++ for({_, src, _} <- @snippets, do: "var r=[]; " <> src <> "; r")
  end

  # ── 5.2, unit test 1: the new walk gives the old answers ───

  describe "unit test 1: Awaits.any?/1 gives the answer of the old walk" do
    test "on every subterm of the corpus, parsed at :off and at 4" do
      for src <- corpus(), level <- [:off, 4] do
        wrong = for t <- subterms(parse!(src, level)), Awaits.any?(t) != ref_any?(t), do: t
        assert wrong == [], "#{level}: #{src}\n#{inspect(wrong, limit: 5)}"
      end
    end

    # The test traces each call of `Awaits.any?/1` while it runs the corpus two times. Alone
    # it takes about 1 s. In the full suite on a busy machine the trace messages wait for the
    # tracer, and the run took more than the default limit of 60 s.
    @tag timeout: 300_000
    test "on every term that the evaluator walks while it runs the corpus" do
      # The run adds terms that no parse makes, such as the `{:val, v}` nodes that the
      # optional-chain path puts in a tree.
      for src <- corpus(), level <- [:off, 4] do
        heap()

        # A row that throws at its top level still walks its terms before the throw.
        {_, calls} =
          traced([{Awaits, :any?, 1}], fn ->
            try do
              run_script(src, level)
            catch
              {:js_error, _} -> :thrown
            end
          end)

        wrong = for t <- roots(calls, :any?), Awaits.any?(t) != ref_any?(t), do: t
        assert wrong == [], "#{level}: #{src}\n#{inspect(wrong, limit: 5)}"
      end
    end
  end

  # ── 5.2, unit test 2: the leaf forms hold no syntax ────────

  # True when `t` holds a syntax node: a tuple whose tag is one of `tags`. A function node
  # is a syntax node too, but it cannot hold an await of the enclosing function, so
  # `{:gen, f}` and `{:async, f}` may hold one. An async generator is
  # `{:async, {:gen, f}}`, so a wrapper of a function counts as the function.
  defp holds_syntax?({:fn, _, _, _, _, _}, _tags), do: false
  defp holds_syntax?({w, f}, tags) when w in [:gen, :async], do: holds_syntax?(f, tags)

  defp holds_syntax?(t, tags) when is_tuple(t) and tuple_size(t) > 0 do
    MapSet.member?(tags, elem(t, 0)) or
      t |> Tuple.to_list() |> Enum.any?(&holds_syntax?(&1, tags))
  end

  defp holds_syntax?(l, tags) when is_list(l), do: Enum.any?(l, &holds_syntax?(&1, tags))
  defp holds_syntax?(_, _tags), do: false

  describe "unit test 2: a leaf form holds no syntax" do
    test "on the corpus, parsed at :off and at 4" do
      terms =
        for src <- corpus(), level <- [:off, 4], t <- subterms(parse!(src, level)), do: t

      leaves = Enum.filter(terms, &Awaits.leaf_form?/1)

      # The syntax tags are the tags of every tuple in the corpus. The atoms that a leaf
      # form holds as data (`:null`, `:undefined`) are not tags, because no tuple starts
      # with them.
      tags =
        for t <- terms,
            is_tuple(t),
            tuple_size(t) > 0,
            is_atom(elem(t, 0)),
            into: MapSet.new(),
            do: elem(t, 0)

      for leaf <- leaves do
        [_tag | rest] = Tuple.to_list(leaf)
        refute holds_syntax?(rest, tags), "a leaf form holds syntax: #{inspect(leaf)}"
      end

      # Each kind of leaf form occurs in the corpus, so the guard covers it.
      seen = leaves |> Enum.map(&elem(&1, 0)) |> MapSet.new()

      for tag <- [:gen, :async, :id, :num, :str, :lit, :gref, :bigint, :slot, :cslot, :fname],
          do: assert(tag in seen, "no #{tag} leaf in the corpus")
    end
  end

  # ── 5.2, unit test 3: single cases ─────────────────────────

  describe "unit test 3: single cases of Awaits.any?/1" do
    test "the forms that await" do
      one = {:num, 1.0}
      assert Awaits.any?({:await, one})
      assert Awaits.any?({:yield, one, false})
      assert Awaits.any?({:yield, {:lit, :undefined}, true})
      assert Awaits.any?({:forawait, nil, nil, nil, nil})
      assert Awaits.any?({:using, :await_using, nil, nil, nil})
      refute Awaits.any?({:using, :using, :let, [], nil})
    end

    test "a six-element for await gives true when nothing in it awaits" do
      assert Awaits.any?({:forawait, nil, nil, nil, nil, nil})
      tree = parse!("async function f(){ for await (const y of [1]) {} }", 4)
      node = find(tree, &match?({:forawait, _, _, _, _, _}, &1))
      assert node != nil
      assert Awaits.any?(node)
    end

    test "a function node and the gen and async wrappers give false" do
      aw = {:await, {:num, 1.0}}
      refute Awaits.any?({:gen, aw})
      refute Awaits.any?({:async, aw})

      tree = parse!("var a = async () => await 1; function* g(){ yield 1 }", :off)
      fns = for t <- subterms(tree), match?({:fn, _, _, _, _, _}, t), do: t
      assert length(fns) == 2
      for f <- fns, do: refute(Awaits.any?(f))

      wrapped =
        for t <- subterms(tree),
            match?({w, {:fn, _, _, _, _, _}} when w in [:gen, :async], t),
            do: t

      assert length(wrapped) == 2
      for w <- wrapped, do: refute(Awaits.any?(w))
    end

    test "a class with a computed key that awaits gives true" do
      # A class body is evaluated inline, so its keys belong to the enclosing function.
      for level <- [:off, 4] do
        tree = parse!("async function f(){ let k = 'm'; class C { [await k](){} } }", level)
        class = find(tree, &match?({:class, _, _, _, _}, &1))
        assert class != nil, "#{level}"
        assert Awaits.any?(class), "#{level}"
      end
    end

    test "the first element of a pair is walked" do
      # A declaration pair `{pattern, init}` starts with a pattern, which can await.
      assert Awaits.any?({{:await, {:num, 1.0}}, nil})
      assert Awaits.any?({{:id, "a"}, {:await, {:num, 1.0}}})
      refute Awaits.any?({{:id, "a"}, {:num, 1.0}})
    end

    test "a leaf form, a struct, a map and plain data give false" do
      for t <- [
            {:id, "x"},
            {:num, 1.0},
            {:str, "s"},
            {:lit, :null},
            {:gref, "g"},
            {:bigint, 5},
            {:val, 1.0},
            {:slot, 0, 6, "x"},
            {:cslot, 0, 6, "c"},
            {:fname, 0, 6, "h"}
          ],
          do: refute(Awaits.any?(t), inspect(t))

      refute Awaits.any?(%Info{})
      refute Awaits.any?(%{a: {:await, {:num, 1.0}}})
      for t <- [nil, :ok, 1, 1.0, "s", [], {}], do: refute(Awaits.any?(t), inspect(t))
      assert Awaits.any?([{:num, 1.0}, {:await, {:num, 1.0}}])
    end
  end

  # ── 5.2, unit test 4: visit counts ─────────────────────────

  # Each program has one CPS loop of three rounds. `walks` gives, for the test and the
  # update of the loop, the number of times that the walk starts at that node. The loop-entry
  # facts of design 4.3 failed their gate and are left to step 5, so the loop walks its test
  # and its update each time it evaluates them: a test four times (three rounds and the
  # exit), the test of a do/while three times, and an update three times. `visits` is the
  # number of calls of `Awaits.any?/1` (each visited term is one call) while the parsed
  # program runs. The counts come from the step 4 code. The old walk with `Tuple.to_list`
  # made more calls (ca43138: 355, 210, 130, 56, 112, 45, 142 and 102).
  @loops [
    {"for",
     "var s = 0; async function f(){ for (let i = 0; i < 3; i++) { s = (s + await i) % 7 } } f()",
     [4, 3], %{:off => 133, 4 => 82}},
    {"while", "async function f(){ var i = 0; while (i < 3) { await 0; i++ } } f()", [4],
     %{:off => 78, 4 => 26}},
    {"dowhile", "async function f(){ var i = 0; do { await 0; i++ } while (i < 3) } f()", [3],
     %{:off => 78, 4 => 21}},
    {"generator for", "function* g(){ for (let i = 0; i < 3; i++) { yield i } } [...g()]", [4, 3],
     %{:off => 72, 4 => 49}}
  ]

  # The test and the update of the one loop in `tree`.
  defp loop_parts(tree) do
    case find(tree, &(is_tuple(&1) and elem(&1, 0) in [:for, :while, :dowhile])) do
      {:for, _init, test, update, _body} -> [test, update]
      {:for, _init, test, update, _body, _sc} -> [test, update]
      {:while, test, _body} -> [test]
      {:dowhile, _body, test} -> [test]
    end
  end

  describe "unit test 4: the visits of the walk" do
    # The counts are those of the tree path, so the switch `:js_compile` is off. Step 5c
    # compiles the plans of the bodies at level 4: see the next test.
    test "a loop walks its test and its update once in each evaluation, and the count of visits is fixed" do
      for {name, src, walks, visits} <- @loops, level <- [:off, 4] do
        heap()
        Process.put(:js_compile, false)
        # The parse runs before the trace, because at level 4 the resolver walks each
        # function once (`Resolve.awaits?`), and the count is about the evaluator.
        program = parse!(src, level)
        {_, calls} = traced([{Awaits, :any?, 1}], fn -> Interp.run_program(program, true) end)
        parts = loop_parts(program)
        assert length(parts) in [1, 2]
        walked = roots(calls, :any?)

        assert length(parts) == length(walks)

        for {part, n} <- Enum.zip(parts, walks) do
          assert Enum.count(walked, &(&1 == part)) == n,
                 "#{name} at #{level}: #{inspect(part)}"
        end

        # The check build runs extra walks (A1 and A2), so it makes more visits.
        unless @check do
          assert length(calls) == visits[level],
                 "#{name} at #{level}: #{length(calls)} visits"
        end
      end
    end

    test "with compilation on, a compiled loop walks its test and its update at most once" do
      # Step 5c: the compiler of the plan finds the facts of the loop once, when the body
      # compiles at its first call. The rounds of the loop do not walk.
      for {name, src, walks, _visits} <- @loops do
        heap()
        Process.put(:js_compile, true)
        program = parse!(src, 4)
        {_, calls} = traced([{Awaits, :any?, 1}], fn -> Interp.run_program(program, true) end)
        parts = loop_parts(program)
        walked = roots(calls, :any?)
        assert length(parts) == length(walks)

        for part <- parts do
          assert Enum.count(walked, &(&1 == part)) <= 1, "#{name}: #{inspect(part)}"
        end
      end
    end
  end
end
