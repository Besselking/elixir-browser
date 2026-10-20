# A faster JavaScript engine in Elixir: design and plan

Date: 2026-10-09. Thread: "Is Elixir the bottleneck?". Companion notes: `notes/language-cost.md`
(measurements against QuickJS and V8), `notes/language-cost/` (scripts, profiles, raw numbers).
All line numbers refer to `lib/browser/js/interp.ex` at `main` on 2026-10-09.

## 1. Summary

- Keep the tree-walking evaluator, the process dictionary heap and the CPS evaluator for
  `async` and generators. Change what a function call, a variable access and a statement cost.
- The interpreter, not the DOM, is the bottleneck in Speedometer. In a full run with the stack
  sampler, about 75% of the samples of the script process are in the interpreter and its helpers
  (`Interp`, `Enum`, `Process`, maps, the JS GC). Forced layout is 4%, other DOM work about 6%.
- Six steps, in this order. Each step is a PR, is tested against test262, and is measured.
  1. Trim the call path (measured on the real interpreter: 12 to 22% on call-heavy code).
  2. A resolver pass and slot frames: variables become `(depth, slot)`, frames become tuples.
  3. Completion values instead of throws, static tail calls, cheaper argument lists.
  4. Precomputed `await` facts for the CPS evaluator.
  5. Closure compilation on top of the resolved tree (the step measured at 10 to 15% before,
     larger after steps 1 to 4).
  6. Later and optional: integers for whole numbers, dense arrays, global call-site caches.
- Expected gain (estimate, see section 5): call-heavy code 3 to 5x, property and DOM-heavy code
  2 to 3x, a Speedometer run about 2x. The floor of a tree walker in Elixir is about 5x slower
  than QuickJS. No design in this document reaches a JIT engine.

## 2. What the interpreter does today

Values: numbers are floats, objects are `{:obj, id}`, the heap is the process dictionary
(`alloc`, `deref`, `store`, `free`: lines 55 to 83).

Scopes are heap entries too. A scope is a map:
`%{scope: true, vars: %{name => value}, consts: MapSet, parent: id}` plus optional keys
(`fnscope`, `fid`, `with`, `lex`, `evalvars`; lines 235 to 247 and 2316 to 2324). Hidden
bindings are atom keys in the same map: `:this`, `:args`, `:new_target`, `:home`, `:strict`,
`:argmap`, `:in_params`, `:module_url`, `:ctor_fn`, `:catch_param`, `{:priv, name}`.

A variable read (`lookup_var`, lines 266 to 310) walks the chain. Each hop is one `deref`
(process dictionary read) and one map match. The global scope is the last hop and also looks at
the global object. A variable write (`assign_var`, lines 320 to 364) walks the chain again,
checks `consts` (a MapSet), checks the TDZ marker, copies the `vars` map and the scope map, and
stores the scope. A declaration (`declare`, lines 255 to 263) copies both maps too.

A call (`ev({:call ...})` line 4413, `call` line 1909, `run_closure` line 2247,
`run_closure_scope` lines 2297 to 2360) does this:

1. `call_target` reads `:js_with_used`, evaluates the callee name (`ev_id`, `lookup_var`).
2. `function?` and `call` each `deref` the function object.
3. `with_hoist` reads the closure record, `pget(:js_fns)` reads the closure counter.
4. `run_closure_scope` writes `:js_depth`, `:js_stack`, `:js_pos`, `:js_tail` (and restores
   all four in an `after` block), builds the `vars` map (`sloppy_this` matches the body for
   `"use strict"` and reads the global `this` through `lookup_var`; `strict_marks` matches the
   body again), allocates the scope (three process dictionary writes).
5. `bind_params` runs `Enum.any?` over the parameters, then one `declare` per parameter.
6. `hoist_into_body` runs `apply_hoist`: one `Map.put_new` per hoisted name, one `make_fn` per
   function declaration, on every call.
7. `exec_fn` runs the body. A `return` that is not reached through `if` or a block is a throw
   (`{:js_return, v}`, line 3436). Before that throw, `exec({:return ...})` reads `:js_tail` and
   walks the whole scope chain for `:strict` (line 3434).
8. `free_scope` reads `:js_fns` again and erases the scope.

Every expression statement writes `:js_last` (line 3342); `if`, loops, `switch` and `try` write it
too. In the CPS evaluator, `cexec` walks the subtree of a statement with `has_await?` each time the
statement runs (`async.ex` lines 1057 to 1061).

## 3. Measurements

### 3.1 Primitive costs (`language-cost/pd.exs`, 4 core cloud machine)

| Operation | ns |
| --- | --- |
| process dictionary read of a 10-tuple | 15 |
| read, `setelement`, write of a 10-tuple | 59 |
| read a scope map and match a string key | 43 |
| today's variable write (read, `Map.put` into `vars`, write) | 108 |
| allocate a 10-tuple from a list | 34 |
| float add (boxed) | 12, int add 11 |
| `try/catch` frame, `try/after` frame | 11 each |
| closure call | 13 |

### 3.2 Where the time goes (`:eprof`, `language-cost/eprof-2026-10-09.txt`)

`fib(25)`: 243k calls. Per call: 13 process dictionary writes, 12.5 `deref`, 10.5 `lookup_var`,
10 `ev`, 4 `Process.get`, 1 throw, 1 alloc and free, 2 `Enum.flat_map` and 2 `Enum.any?`.
Shares: `lookup_var` 12%, `ev` 10%, `erlang:put` 9%, `deref` 7%, `run_closure_scope` 7%,
`ev_id` 3.5%, `throw` 3.4%. About 45 to 50% of the time is scope and call plumbing.

`o.a = i; t += o.a + o.b + o.c` (60k iterations): 12 `lookup_var` per iteration. Variable
handling (`lookup_var`, `ev_id`, `assign_var`, `with_binding`, `id_ref`, `MapSet.member?`,
`sync_argument`) is about 35%. The property path itself (`get`, `lookup`, `put`, `put_prop`,
`to_key`, `ev_key`, `index`) is about 12%.

Closures (60k calls of a fresh closure): 17 process dictionary writes per iteration;
`with_hoist` recomputes the hoisting facts for each new function object (2%).

DOM-like objects: `apply_hoist` 1.3% and `Integer.parse` from `index/1` 1.5% show up as well.

### 3.3 Experiment: the call bookkeeping removed (`language-cost/patch_bookkeeping.py`)

The patch removes `:js_depth`, `:js_stack`, `:js_pos`, `:js_tail`, the `try/after`, the `:strict`
walk on `return` and the `:js_last` write per expression statement. It is not correct code (no
stack traces, no tail calls). Best of 3, ms, same machine load:

| Program | before | after | gain |
| --- | --- | --- | --- |
| fib(25) | 395 | 322 | 18% |
| 60k closure calls | 358 | 306 | 15% |
| property access 60k | 139 | 122 | 12% |
| class method calls 30k | 67 | 52 | 22% |
| tree walk | 165 | 144 | 13% |
| DOM-like | 145 | 126 | 13% |
| big function body (300 `if`) | 758 | 780 | 0 |

The big body does not gain: its cost is 6 million `if` statements at about 130 ns each.

### 3.4 Floors (`language-cost/ladder.exs`, `tw.c`, `language-cost.md`)

| Design | fib(25) |
| --- | --- |
| QuickJS (bytecode, C) | 12 ms |
| minimal tree walker in C | 7.5 ms |
| minimal tree walker in Elixir, integers | 15 ms |
| same, floats | 23 ms |
| same, one frame in the process dictionary per call, `try/after` | 39 ms |
| same, plus today's per-call bookkeeping | 81 ms |
| same, plus name lookup through 3 scopes | 172 ms |
| Browser.JS today | 400 ms |

### 3.5 Speedometer 3.1, full run with the stack sampler (`language-cost/speedometer-prof-2026-10-09.txt`)

`PROF=1 LAYOUT=1`, 222 s under the sampler and a parallel benchmark load (147 s is the normal
time). 46k samples of the script process. Of the samples in the top 45 functions:

| Module | share |
| --- | --- |
| `Browser.JS.Interp` | 55% |
| `Enum` (`reduce`, `flat_map`, `predicate_list`, `map`) | 11.5% |
| `Browser.JS.DOM` (11.9% is `layout_now`, the forced layouts: 37 layouts, 9.3 s) | 12.8% |
| `Process`, maps, `MapSet`, `lists` | 11% |
| `Browser.JS.GC` | 3.5% (6.7% inclusive) |
| JSON, lexer, `String.downcase` | 3% |

Top self functions: `ev` 11%, `deref` 8.4%, `lookup_var` 4.6%, `ev_id` 4.5%, `Enum.reduce` 4.3%,
`Enum.flat_map_list` 2.5%, `get` 2.4%, `Process.get` 2.2% twice, `predicate_list` 2.1%, `ev_key`
2.1%, `exec_fn` 2.1%, `declare` 1.8%, `lookup` 1.8%, `truthy` 1.8%, `to_key` 1.7%.

Conclusion: the interpreter core is about 75% of a Speedometer run. The DOM bindings are not the
first problem. Property access (`get`, `lookup`, `to_key`, `ev_key`, `index`) is about 8%.

## 4. Target design

### 4.1 Decisions

1. **Frames stay in the process dictionary, addressed by id.** The alternative (a frame passed
   down the evaluator and returned with each value) breaks on two things: a closure must see later
   writes to a captured variable, and a `catch` must see writes made in the `try` block before a
   throw unwound the Elixir stack. The CPS evaluator also keeps frame ids in its continuations.
   One process dictionary read per variable access (15 ns) is an acceptable floor.
2. **No bytecode VM.** A loop over a bytecode tuple in Elixir dispatches with `case` per
   instruction. It is not faster than calling a closure per node, and it duplicates every
   semantic. The endpoint is a resolved tree, then closures (step 5).
3. **The resolver is the foundation.** Nearly every cost in section 3 comes from facts that are
   recomputed at run time and could be known once: where a name lives, whether a function is
   strict, whether it makes closures, whether a `return` is a tail call, whether a statement awaits.
4. **Two frame kinds, one lookup.** Function bodies get tuple frames with slots. The global
   scope, module scopes, class scopes and the scopes of dynamic code keep the map form. A
   name-based lookup works on both kinds, so dynamic code and the DOM setup code do not change.
5. **The CPS evaluator keeps its structure.** It calls the ordinary evaluator for every part
   without `await`, so it gets the gains of steps 1 to 3 for free.
6. **Numbers stay floats for now.** Boxed floats cost about 50% on an arithmetic micro-benchmark
   and an estimated 5% on real pages. Integers touch every producer of a number (189 `* 1.0` sites,
   map keys, `===`, collections). Measure before deciding.

### 4.2 The resolver (new module `Browser.JS.Resolve`)

Runs once per parsed function body, after `Parser.parse`, before the first run. For each
function it produces a `FunctionInfo`:

- `slots`: `%{name => index}` for parameters, `var` names, function declarations and the
  lexical names of the body and of blocks that need no frame of their own.
- `hidden`: fixed slots for `this`, `arguments` source, `new.target`, `home`, when the function
  or an arrow inside it uses them.
- `captured`: the names that an inner closure, a nested `eval` or a `with` can see. (Used by
  the frame free rule in 4.3.)
- `flags`: `strict`, `dynamic` (contains direct `eval` or `with`; also set on every function that
  encloses one), `uses_arguments`, `simple_params`, `makes_closures`, `has_await` per statement
  (section 4.6), `tail_sites` (section 4.5).
- `hoist`: the list of `(slot, function node)` to instantiate at entry, the lexical names to
  mark `:tdz` at entry of each block, and the names to copy per loop iteration.

Identifier nodes are rewritten in place:

- `{:id, name}` becomes `{:slot, depth, index}` when the name resolves to a tuple frame
  `depth` hops up. `depth` counts frames, not syntactic blocks.
- `{:gref, name}` when it resolves to the global scope or is unresolved (the global object,
  then `named_element`, then `ReferenceError`). Global names stay name-based: scripts add them
  at run time.
- `{:id, name}` stays as it is inside `dynamic` functions, in module and class top-level code,
  and in eval code. The old path handles it.

Per-iteration `let` copies: a loop gets a frame of its own for its lexical names only when the
body or the update expression contains a function, arrow or class node (today this is detected
at run time with the `:js_fns` counter at line 3496). Otherwise the lexical names live in the
function frame.

Block scopes: a block gets a frame of its own only when it declares names that a closure
inside the block captures. Otherwise its lexical names get slots in the function frame, and the
block entry writes `:tdz` into them (one `setelement` per name).

### 4.3 Frames

A tuple in the process dictionary: `{parent_id, info, chain, call_pos, root_id, slot_6, ...}`.

- `parent_id`: the frame or map scope the function closed over.
- `info`: the `FunctionInfo` (a shared term, no copy). The name-based lookup for dynamic code
  reads `info.slots` to find a slot by name.
- `chain` and `call_pos`: for `Error.stack` and the depth limit (step 2f). Only the check build
  (`JS_RESOLVE_CHECK=1`) stores `chain` in the frame; a normal build stores `nil`, because no
  code reads it there and a frame kept by a closure would keep the cells of all its callers.
  `chain` is the value of `:js_stack` while the body runs: a list of cells `{name, call_pos, depth}`, innermost
  first, with the cell of this call at the head. The sync part of an async call has a hidden
  cell `{:hidden, nil, depth}`, which counts but prints no line. The old path pushes the same
  cells, so all levels share one chain. The name comes from the closure at call time, not from
  `info`, because the stack shows inferred names. A frame of an async function or a generator
  has `nil` there, because its body can run under more than one chain. The current position
  stays in `:js_pos` (one write per statement, only when the script has a file name, as
  today). `stack_string/1` walks at most 12 visible cells of the chain when an error needs
  the text.
- The call depth is the depth in the head cell of `:js_stack`. A call is refused when it is
  1000, before the call pushes. This replaces `:js_depth`, which step 2f removed at every
  level. A frame id chain was rejected: it cannot name an old-path or an async call, it needs
  a heap read for each line, and it cannot hold the inferred name.

Read: `element(i, :erlang.get(id))` after `depth` hops. Write: `:erlang.put(id,
setelement(i, :erlang.get(id), v))`. A `const` write and a TDZ read are checked by the resolver
where it can (an assignment to a known `const` is a static error path) and by the value `:tdz`
where it cannot.

Free rule: a frame of a function with `makes_closures: false` and `dynamic: false` is erased on
return, always. Other frames keep today's rule (the `:js_fns` counter, line 2238).

Mapped `arguments`: the arguments object records `{frame_id, slot}` per parameter. Only
functions with `uses_arguments` pay the sync on parameter writes.

The JS GC (`gc.ex`) follows integers in tuples, but for a frame it starts at `root_id`
(element 5). So `parent_id`, `root_id` and the slots keep objects alive. The chain and
`call_pos` hold depths and line numbers, not ids, so they keep nothing alive. The dangling scan
of check mode skips them in the same way (step 2f). `info` holds no ids.

### 4.4 The call path

The closure record gets `info` plus the facts that are matched on every call today:
`strict?`, `sloppy_this?`, `simple_params?`, `arity`. `with_hoist`, `strict_marks` and
`sloppy_this` disappear from the call path.

A call with simple parameters builds the frame in one `List.to_tuple` from the argument list
padded with `:undefined` for missing parameters and for every other slot. Function declarations
in the body are instantiated into their slots (one `make_fn` each, unavoidable). No `try/after`:
nothing has to be restored, because nothing per call is written to the process dictionary
except the frame itself.

The global `this` for sloppy calls is one process dictionary read (`:js_global_this`), not a
scope walk.

### 4.5 Statements and completions

`exec` returns `:normal`, `{:return, v}`, `{:break, label}` or `{:continue, label}`. Loops,
blocks, `switch`, `try` and labels pass the completion up. A JS exception stays an Elixir throw
(`{:js_error, v}`). `:js_last` is written only in script and eval top-level code (a resolver
flag on the statement list), not inside function bodies.

Tail calls: the resolver marks `return <call>` in a strict function as a tail site when no
`try`, `with`, `for ... of`, `using` or labelled block is between the `return` and the function
body (today `no_tail` and `:js_tail` compute this at run time). The evaluator returns
`{:tailcall, f, this, args}` as the completion, and `call` trampolines as `tail_loop` does today.
The 34 `tco-*` tests in the test262 baseline stay green.

Argument lists: `eval_list` uses `Enum.flat_map` for spreads. The resolver marks argument lists
without spread, and those use a plain recursive map.

### 4.6 The CPS evaluator (`async.ex`)

- Statement facts were done in 2e: the resolver marks each statement that awaits with
  `{:aw, stmt}`, and `cexec` reads the mark. Step 4 makes the walk that is left faster
  (`Browser.JS.Awaits.any?/1`, a tidier `lift`, loop-entry facts). Expression facts move to
  step 5 as CPS plans (notes/js-step4-design.md, section 3.4).
- Async and generator functions get tuple frames like other functions. `call_scope` builds
  the frame. The CPS code keeps calling `Interp.ev` and `Interp.exec` with the frame id.
- The leaf temporaries (`"\0s0"`, `"\0s1"`: `async.ex` line 983) and the block scopes the CPS
  code makes with `new_scope` keep the map form: they are child scopes of a tuple frame, and
  the one lookup handles both kinds. They can move to slots later if a profile shows them.

### 4.7 What does not change

Objects (`%{class, props, keys, proto}` in the process dictionary), property access, arrays as
index maps, strings, the built-ins, the DOM bindings, Promise and microtasks, the JS GC.

### 4.8 Closure compilation (step 5)

On the first call of a function, compile its resolved body into Elixir closures: a node becomes
`fn frame_id -> ... end` that calls its children's closures. This removes the `ev` and `exec`
dispatch (11% plus 2% self in Speedometer) and the re-dispatch on literals, positions and
identifier kinds. The syntax tree is kept for `Function.prototype.toString`, `eval` and the
CPS evaluator (async bodies stay on the tree, their sync parts call compiled children). The
earlier measurement (10 to 15%) was taken on today's data model; after steps 1 to 4, dispatch is
a larger share. Measure again before building it.

### 4.9 Later, optional

- Integers for whole numbers (section 4.1, decision 6).
- Dense arrays as tuples in chunks of 64 instead of one map per array.
- A per-site cache for global function references with a global write counter for invalidation.
- The DOM binding dispatch (`host_get` with a `case` on the key string, `dom.ex` line 1668) if
  a later profile shows it.

## 5. Expected gains

Estimates built from section 3. Each step is measured before the next starts.

| Step | fib(25), 400 ms today | property access, 139 ms | DOM-like, 145 ms | Speedometer run |
| --- | --- | --- | --- | --- |
| 1 trim the call path | 330 (measured 322 without stack traces) | 125 (measured) | 128 (measured) | about 10% |
| 2 resolver and slot frames | 150 to 200 | 60 to 80 | 70 to 90 | about 1.6x total |
| 3 completions, static tail calls, argument lists | 110 to 150 | 50 to 70 | 60 to 80 | |
| 4 `await` facts precomputed | no change | no change | no change | no Speedometer change (measured); async programs -10% to -36% Mred |
| 5 closure compilation | 80 to 120 | 40 to 55 | 45 to 65 | about 2x total |

The floor is about 40 ms for fib(25) (section 3.4, the tree walker with frames in the process
dictionary), and Browser.JS keeps semantics that the floor does not have (property descriptors,
`this` rules, completion values, the step limit). So 80 to 120 ms is the realistic end point:
3 to 5x faster than today, 7 to 10x slower than QuickJS.

A Speedometer run spends about 75% in the interpreter. A 2.5 to 3x faster interpreter gives a
run about 2x faster (score 0.15 to about 0.3 runs/min). Real browsers score 20 to 40. The
gap to them is a JIT and inline caches, which this design does not provide.

## 6. Plan

Sizes as in the project notes: S under an hour, M a few hours, L a day or more, XL several days.

### Progress

- 2026-10-09, steps 0 and 1 done: PR 244 (branch `claude/project-thread-gx8rln`).
  Step 0: `bench/js_runtime.exs` runs the nine programs, min of 5, with a reductions column
  (BEAM work units; stable when wall time on the cloud VM is not: time noise was up to 30%
  between runs of the same code, reductions did not move). Step 1 measured against a clean
  build of main, best of 3 rounds: fib(25) 424 -> 299 ms (-29% time, -16% reductions), tree walk
  160 -> 148 ms (-12% reductions), DOM-like -10% reductions, closures60k -7% time, big function
  body -6% time; property access, arrays, strings and class calls unchanged (no calls in their
  hot loops). After the review fixes (final PR numbers): fib -27% time / -19% reductions, tree
  walk -14% reductions, DOM-like -11%, arrays -7%, closures -6%, class calls -3%. test262
  `--check` green (42256 pass), `mix test` green. Two adversarial review rounds found: the
  tail flag leaking into generator/async bodies resumed under a strict frame (fixed: the flag
  is off at every CPS entry), `return super()` crashing (pre-existing, fixed), and small
  per-call costs (fixed).
  What step 1 did not do: the per-call bookkeeping (`:js_depth`, `:js_stack`, `:js_pos`,
  `:js_tail`, `try/after`) stays, as planned; `with_hoist` is still paid once per function
  object, which is why closures60k (a new function per iteration) gained little.
- 2026-10-09 night, step 2a done (same PR 244, stacked): `Browser.JS.Resolve` (design in
  notes/js-resolver-design.md, chosen by a judge panel over three designs). The pass runs at
  the end of `Parser.parse/2` behind the parse option `resolve:` or the application setting
  `:js_resolve` (`:off` default, `:info`, 1 to 4). `%Info{}` replaces the sixth element of
  `{:fn}` nodes; frames are `{parent, rec, caller, call_pos, root, slot_6, ...}`; forms are
  `{:slot, d, i, name}`, `{:cslot}`, `{:fname}`, `{:mslot}`, `{:mref, d, name}`, `{:gref, name}`,
  `{:this, d, i}`, trailing `%Scope{}` on blocks, loops, switches and catches, `{:in_tdz}`,
  `{:return, e, :tail}`, `{:aw, stmt}`. 44 unit tests, corpus round trip and oracle over
  test262. test262 unchanged at `:off` and at `:info` (42256). Review found 36 issues (4
  blockers: field initializers are closures; direct eval in field initializers; imports after
  a top-level `using`; `var arguments` under parameter defaults), all fixed. Deviations from
  the design are listed in the moduledoc of `resolve.ex`. Parse cost: about +35% at `:info`
  and +75% at level 4 on a 94 KB file (one parse per script; to revisit before 2b if it shows).
  Next: 2b, level 1 frames in the interpreter.
- 2026-10-10, step 2b done (design in notes/js-frames-2b-design.md): level 1 functions run on
  tuple frames. The closure's `info.rewritten` selects the path (`run_closure`, `tail_loop`,
  `construct_plain`); `run_frame/5` builds the frame with one `List.to_tuple`, runs the body
  and frees the frame in `after`. The resolver marks every other `return` of a rewritten
  function `{:return, e, :plain}`, so no leaf reads `:js_tail`. The by-name walkers
  (`lookup_var`, `assign_var`, `declare`, `resolvable?`, `with_binding`, `scope_of`,
  `scope_with`, `args_shadowed?`, `in_field_initializer?`, `private_names_in`,
  `variable_scope`, the `delete` branch) read a frame through `info.slots`. Check mode
  (`JS_RESOLVE_CHECK=1`, compile time) asserts every landing; `JS_RESOLVE=1 mix test` runs
  the suite at level 1; `RESOLVE=1 mix run --no-start bench/js_runtime.exs` benches it.
  Level 1 after the resolver: fib25 `fib`; closures60k the inner `function(b)`; propaccess60k
  `f`; array20k the three arrows; strbuild20k `f`; bigfn20k `big`; classcalls30k `inc`;
  treewalk `mk` and `lay`; domlike `q`. In every program the wrapper `f` is level 2, so the
  recursion names stay `{:id}` and walk by name through the frame (2c removes that).
  `caller_id` stays `nil` until 2f (`Error.stack` keeps `:js_stack`). Two legitimate level 1
  differences: `let`/`const` after a function-level `using` are in their TDZ, and a for-of
  head default that reads its own name on a later round throws the TDZ message instead of
  `a is not defined`. A third one (found in review): a default inside a nested parameter
  pattern, as in `function f({a = b}, b)`, puts every parameter in its TDZ at level 1, as the
  spec says; `:off` only does that for a default at the top of the list. test262 (local, 2026-10-10): 42256 pass at :off, :info and level 1, no
  regressions. `mix test` 2145 pass at :off and at `JS_RESOLVE=1`. Bench, RUNS=3, same tree,
  min ms / Mred, :off vs level 1: fib 326/30.9 vs 220/19.2; closures 376/20.8 vs 288/16.5;
  propaccess 120/12.6 vs 61/7.7; array 116/9.4 vs 119/8.3; strbuild 38/3.4 vs 20/2.5; bigfn
  694/112.7 vs 346/75.8; classcalls 61/6.1 vs 55/5.2; treewalk 128/10.3 vs 91/7.5; domlike
  114/9.6 vs 85/7.5; total 1974 vs 1284 ms (-35%).
- 2026-10-10, step 2c done (design in notes/js-frames-2c-design.md, judge panel winner
  'correctness'): level 2 functions, which make closures, run on frames. Call entry adds copies
  and hoisted declarations; closures keep the frame id as scope; a level 2 frame is freed on
  return only when `:js_fns` did not move, else the collector takes it (gc.ex marks frames by
  their Info/Scope record). Blocks, switch, catch and loops with captured lexical names get
  block frames; `for (let)` copies the frame per round only after a closure was made; for-in/of
  renew the item frame in place until a closure takes it. Resolver: an arrow with a direct eval
  makes its owner level 3; a dynamic function in a parameter list makes the owner dynamic; a
  named function expression whose body redeclares its name with expression parameters keeps
  names. Check mode: tombstones for freed frames and a dangling scan after each eval and test262
  test. test262 42256 at :off, :info, 1 and 2, and in the check build at 1 and 2. `mix test`
  2183 at :off, 1 and 2. Bench, RUNS=3, min ms / Mred, :off vs 1 vs 2: fib 302/30.9, 228/19.7,
  210/18.2; closures 381/20.8, 320/16.7, 218/11.7; propaccess 131/12.6, 62/7.8, 63/7.8; array
  139/9.4, 122/8.4, 115/7.8; strbuild 43/3.4, 19/2.6, 20/2.6; bigfn 712/112.7, 360/75.8,
  337/74.9; classcalls 58/6.1, 57/5.3, 48/4.6; treewalk 129/10.3, 89/7.5, 93/7.4; domlike
  120/9.6, 97/7.6, 93/7.1; total 2015, 1354, 1197 ms (-41% at level 2). Level 1 reductions
  rose about 1-3% against the 2b run (fib 19.2 to 19.7): the free-rule read and block entry
  helpers; to win back in step 3.
- 2026-10-10, step 2d done (design in notes/js-frames-2d-design.md, judge panel winner
  'correctness'): level 3 functions (arguments, new.target, super, home, private names, class
  constructors) run on frames. `run_frame/6` takes new.target and a mode (:call, :new, :ctor)
  and fills the hidden slots; the arguments object is built on first read, a mapped one keeps
  its frame in `map_scope` and is detached before the frame is freed; rewritten class
  constructors run through `construct_frame/5`; a class without a constructor gets a
  default-constructor Info. Resolver R1-R4 (eval in methods, async arrow + `arguments`, the
  `{:aslot}` form, default ctor Info). Review fixes: computed-key parameters with `var
  arguments` keep names; super() before the class record throws the old SyntaxError; frames
  without an argument map pay only free/1; check mode compares only the written index of a
  mapped arguments object. test262 42256 at :off, :info, 1, 2, 3 and in the check build at 2
  and 3; `mix test` 2229 at every level. Bench, RUNS=3, Mred :off vs 3 (min ms): nine-program
  total 1962 vs 1135 ms; new of a class 15.3 vs 13.2; default subclass 15.1 vs 12.2;
  super.m() and this.#x 10.8 vs 7.8; arguments reads 14.0 vs 9.8. Level 3 spec differences
  from :off: D1-D4 (writes to `arguments` before its first read land on the local binding).
  Level 2 gives the spec SyntaxError for eval('super.m()') in a plain function inside a method,
  where :off, 1 and 3 give the old result.
- 2026-10-10, step 2e done (design in notes/js-frames-2e-design.md, judge panel winner
  'correctness'): level 4 functions (async functions, async arrows, generators, async
  generators) run on frames. `enter_frame/4` builds the frame without running the body; the
  CPS context carries `frame`, and generator records carry `frame` and `fns`; `frame_done`
  frees the frame once when the body ends and no closure was made. Awaits are lifted into
  `{:cps_leaf, i}` holes filled with `{:val, v}`, so no scope comes between the frame and the
  code. Review fixes: an await in a class key or heritage runs in a class scope (its hops were
  one short); an async generator closed at the start drops its start continuation; check mode
  allows the sync await in a catch parameter default; a yield reads its object once (the old
  path cost 3-5% more on generators before this). test262 42256 at :off, :info and 1 to 4 and
  in the check build at 3 and 4; `mix test` 2276 at every level. Bench, RUNS=3, Mred :off vs 3
  vs 4 (ms at 3 and 4): await loop 18.6, 18.6, 16.8 (207, 127); async calls 9.5, 9.5, 8.1
  (104, 83); closures after await 7.4, 7.3, 5.5 (82, 69); generator range 11.1, 10.5, 9.8
  (102, 84); yield* 9.7, 9.7, 9.1 (96, 89); async generator 4.2, 4.2, 3.8 (45, 40). The
  nine-program total does not change at 4 (no async code). Level 4 spec differences from
  :off: D1-D6 of the design, plus D7: `delete (await o)?.p` gives true at 4 and false at :off,
  and neither deletes the property.
- 2026-10-10, step 2f done (design in notes/js-frames-2f-design.md; the judges split between
  'minimal' and 'correctness', and the final design starts from 'correctness'): `:js_depth` is
  gone at every level. Each `:js_stack` cell is `{name, call_pos, depth}`; an async call pushes
  a hidden cell. `run_frame/6` has one `try` with `catch` clauses and no `after`; the old path
  and `Async.call_closure` keep their `after` until step 3. `stack_string/1` walks the chain on
  demand and stops after 12 lines. Check mode keeps the old bookkeeping as a shadow and
  compares the text and the depth at each call (C1-C6). New `test/browser/js_stack_test.exs`
  pins the stack text, console output and depth limit at `:off`, `:info` and 1 to 4.
  `Browser.JS.eval` now passes `:file` to the parser. Review fix: only the check build stores
  the chain in frame element 3 (a kept frame held its callers' cells, up to 43 KB per closure
  in deep recursion). test262 42256 at :off, :info and 1 to 4 and in the check build at :off
  and 4; `mix test` 2351 at every level. Bench, RUNS=3, Mred 2e vs 2f at level 4: fib 18.7 vs
  17.0 (-9%); closures 12.0 vs 11.1 (-8%); array 7.9 vs 7.6; class calls 4.6 vs 4.4; tree walk
  7.4 vs 7.3; DOM-like 7.1 vs 7.0. At :off: fib 30.9 vs 29.6 (-4%), closures 20.8 vs 20.2. The
  design recommends moving the default level to 4 in its own PR after 2f, behind the gates of
  its section 7.5 (Speedometer, WPT reftests and page tests at level 4).
- 2026-10-11, step 3 done (design in notes/js-step3-design.md): `exec/3` gives a completion
  at every level: `:ok`, `{:ret, v}`, `{:brk, label}`, `{:cont, label}` or `{:tail, f, this,
  args}`. Only a JS exception (`{:js_error, v}`), `:js_limit` and `:js_short` are Elixir
  throws. `:js_tail`, the two `no_tail/1` helpers, `ctor_tail/9` and `{:js_tailcall}` are
  gone. A tail site of a rewritten function gives the pending call to `run_frame/6`, which
  calls `tail_loop/3` after `leave/5`. On the old path every `return` of a call form gives a
  pending call, and the function boundary decides with the old predicate (strict and not a
  constructor). The old `no_tail` sites are now run sites (`run_tail/2`). `eval_list/2` is
  plain recursion. The statements of a rewritten function run through `fbody/2` and
  `fstmt/3` and do not write `:js_last`. The old path keeps every write. Behaviour changes,
  each in its own commit: B1 (a `continue` to an outer label closes an iterator as a normal
  exit, at every level), D2 (a call of a function named `eval` reads the callee one time,
  takes `this` from a `with` object and evaluates the arguments first, at every level) and
  D1 (level 4 only: a call no longer changes the completion value of script or eval code).
  Check mode adds K1 (completion shapes), K2 (function and top-level boundaries), K3 (no
  pending call at a run site of a frame, or from a function with no tail site), K6 (no
  statement of a rewritten function in the script clauses of `exec/3`) and K7. K4 and K5
  were not built: test262 at :off and 4 in the normal and the check build was the oracle.
  The last `try` in `run_frame/6` stays (2f Q1 is closed: it costs no time when nothing is
  thrown). One-VM A/B against fc9f0db (both `interp.ex` builds loaded in turn, RUNS=5, min
  ms and Mred, old -> new), level 4: fib 172 -> 158 ms (-8%), 17.0 -> 16.1 Mred (-5.7%);
  closures 178 -> 160 (-10%), 11.1 -> 10.6; propaccess 57 -> 53 (-7%); array 95 -> 95;
  strbuild 18.6 -> 17.6 (-5%); bigfn 295 -> 299 (noise, -0.2% Mred); classcalls 37.9 ->
  37.1; treewalk 77 -> 72 (-7%); domlike 67 -> 66; nine-program total 997 -> 958 ms (-3.9%).
  Step 3 programs at level 4: stricttail40k 37.7 -> 32.6 (-13.5%), find20k 79 -> 72 (-9%),
  switchret30k 54 -> 41 (-23%), continue60k 38 -> 32 (-16%), forofret10k 28.1 -> 27.6. At
  :off every program has fewer Mred (fib -9.9%, closures -6.2%, stricttail40k -8.2%), and
  the nine-program total goes from 1760 to 1719 ms (-2.3%). Per commit: `eval_list` gave fib
  -5.7% Mred; tail calls as completions gave stricttail40k -16.7% time; frames without
  `:js_last` gave propaccess60k -12.6% time. Review (six lenses, about 60 edge programs at
  all six levels against fc9f0db) found one leak: global code inside a call (an indirect
  eval, the Function constructor) wrote the completion value of the script, which no later
  write of a level 4 function hid any more. `run_eval` and `run_program` now restore the
  caller's value; this is also a spec fix at `:off` (`5; var y = eval('7')` gives 5). The
  completion tests run at every level. Gates: `mix test` 2378 pass at 4 and at `:off`;
  test262 42256 at `:off` and 4 in the normal and the check build.
- 2026-10-11, step 4 done (design in notes/js-step4-design.md; three angle designs and the
  judge scores in notes/js-step4/). Measurement first: on seven Speedometer suites all CPS
  walks together cost at most 0.1% of the reductions at level 4, so step 4 gives no Speedometer
  gain, and the statement facts were already done in 2e (`{:aw}`). Landed:
  `Browser.JS.Awaits.any?/1`, one walk for the CPS evaluator and the resolver (elem recursion,
  leaf forms stop the walk; check item A1 compares it with the old walk), and a tidier `lift`
  (one `ordered/1` call, child flags once; A2 compares the templates). One-VM A/B against
  ca43138, RUNS=9, Mred: the six 2e programs together 50.98 -> 39.66 (-22.2%) at level 4 and
  59.17 -> 47.21 (-20.2%) at `:off`; await20k 16.7 -> 10.9 (112 -> 88 ms); asynccalls10k 7.8 ->
  5.7 (60 -> 48 ms); exprawait5k -48%; the nine core programs unchanged; NewsSite-Nuxt -0.24%.
  The loop-entry facts (a loop walks its test and update once) gave genrange30k -12.9% Mred but
  only 2 to 4% time, under the 5% gate, so they move to step 5 with the expression facts, the
  lift plans and the removal of `fill` (patch kept in
  notes/js-step4/item3_loopfacts.diff). New tests: test/browser/js_awaits_test.exs (the walk against a reference
  copy on a corpus, 50 snippets at every level). `mix test` 2391 pass at 4 and at `:off`.
- 2026-10-11, step 5 done (design in notes/js-step5-design.md; three measured prototypes and
  the judge scores in notes/js-step5/). Bess chose to keep the compiler for its gain on the
  core programs, with Speedometer as information only. `Browser.JS.Compile` turns the body of
  a rewritten sync function into Elixir closures at its first call (`fn frame -> value or
  completion end`). Hot kinds have closures of their own; switch, try, for-in, for-of and
  do-while are shells whose children compile; functions, classes and non-slot names stay on
  the tree. Constants and own-frame slots are read inline, tests give Elixir booleans, a
  property read or write with a constant key uses `get_named`/`put_named`, and a function
  with plain parameters gets a frame maker. The cache is `{:jsc, uid}` plus the `code` and
  `mk` keys of each closure record; the GC skips both. Memory: a body over 65,536 nodes stays
  on the tree, and the cache is erased above 400,000 nodes (16 more per entry). `JS_COMPILE=0`
  turns it off; `mix js.test262 --compile-diff` runs each test with the compiler off and on
  and compares outcome, console, steps, heap ids and position. Ten commits, each with an A/B
  gate (bench/ab.exs). Final gate against 011ad3f on a quiet machine: nine programs 969 ->
  679 ms (-30%), 137.2 -> 51.7 Mred (-62%); fib25 -23% ms, bigfn20k -50% ms, propaccess60k
  -34%; step 3 programs -24% ms; async programs -2% Mred (they stay on the CPS path). Single
  suites (whole-VM Mred, score): chartjs -31.5%, 0.177 -> 0.211; React-Complex-DOM -24.7%,
  0.129 -> 0.137. Full Speedometer run against 29a6d20 (level 4, `LAYOUT=1`): VM reductions
  5666 -> 4374 M (-23%), but CPU time 149.9 -> 149.5 s and total 138 -> 134 s, score 0.235 ->
  0.236, peak memory the same: forced layout (72 s), the GC and idle waits hold the wall time,
  and fewer reductions in compiled code do not give the same cut in CPU time. Review (five
  lenses, 20 findings, most shown with a mutant): oracle rows for operand order and missing
  arguments, a fast budget-erase test, test262 diff mode tags finished runs and skips the
  steps of clock tests, `JS_COMPILE=0` leaves records untouched, and a fix from before step
  5: a strict write no longer throws for a failed sloppy write inside its setter or proxy
  trap. A first fix that sized cache entries with `:erts_debug.size/1` doubled React's
  reductions, so the budget counts nodes. Test fixes: ResolveEnvTest and FramesSerialTest put
  the resolver level back (a deleted level broke later tests under `JS_RESOLVE=off`). The review also
  found that `for (k in 'xy')` threw a TypeError at every level; for-in now boxes a
  primitive. Gates: `mix test` 2424 pass at 4 (2423 at `:off` and with `JS_COMPILE=0`
  before the for-in fix); test262 42256 at `:off` and 4 in the normal and the check build;
  `--compile-diff` 0 diffs. Open: step 5c (CPS plans for async bodies).

### Step 0: measurement harness (S)

Add the nine programs of `notes/language-cost/` to `bench/js_runtime.exs` and run each 5 times,
reporting the minimum. Record the QuickJS numbers in the bench header as the reference. Check
noise once on the cloud machine with nothing else running.

### Step 1: trim the call path (M), expected 10 to 15%

Shippable parts of the experiment in 3.3, with stack traces and tail calls kept:

- Precompute `strict?`, `sloppy_this?` and `simple_params?` in the closure record
  (`with_hoist` already caches `hoist`; add the three flags).
- `:js_last` only outside function bodies (`exec_fn` passes a flag, or two `exec` entry points).
- `exec({:return})`: use the closure's `strict?` instead of the `:strict` scope walk.
- `bind_params`: skip `Enum.any?` when `simple_params?`; bind in one `vars` map build.
- `apply_hoist`: merge the hoisted names into the initial `vars` map in one `Map.merge`.
- `sloppy_this`: read the global `this` from one process dictionary key.
- Keep `:js_depth`, `:js_stack`, `:js_pos`, `:js_tail` until step 2 replaces them.

Gate: test262 `--check` green, `mix test`, the bench.

### Step 2: resolver and slot frames (XL), expected 2x on call-heavy code

In sub-steps, each green on test262:

- 2a. The resolver as a pure pass with unit tests. It computes `FunctionInfo` and rewrites
  identifiers only when a flag is on. With the flag off nothing changes. Land it.
- 2b. Tuple frames for functions that are not `dynamic`, make no closures, do not use
  `arguments`, and are not async or generators. This covers most leaf functions. The name-based
  lookup learns to read tuple frames (through `info.slots`), so outer dynamic code and the
  class, module and global scopes work unchanged.
- 2c. Functions that make closures: parent links, the free rule, per-iteration loop frames,
  block frames for captured lexical names.
- 2d. `arguments` (mapped and unmapped), `this` and `new.target` slots, `super` and `home`
  through fixed slots, class fields and private names resolved to the class scope by depth.
- 2e. Async and generator functions through `call_scope`.
- 2f. Remove `:js_depth` at every level. Keep `:js_stack` as one chain of cells that carry
  their depth (the check build also keeps the chain of each sync frame in its element 3). `run_frame/6` has one
  `try` with `catch` clauses and no `after`. The `try/after` of `run_closure_scope` stays until
  step 3, because it also restores the tail flag (design in notes/js-frames-2f-design.md).

Risks and their checks: the TDZ tests, `tco-*`, `with`, direct and indirect `eval`, `delete` of
eval-declared names, `arguments` mapping, class private names, module live bindings, the
`Function` constructor and `setTimeout` with a string, event handler attributes in `dom.ex`, and
`Error.stack` output (console, crash reports). All of these are in test262 or `mix test` today;
add a test for each that is not.

### Step 3: completions, static tail calls, argument lists (L), expected about 3% on the nine programs, 5 to 25% on code that returns early, continues or makes strict tail calls

- `exec` returns completions; `run_body`, `for_loop`, `while_loop`, `exec_for_each`,
  `proto_loop`, `exec({:try ...})`, `exec({:labeled ...})` and `exec({:switch ...})` read them.
- Tail sites marked by the resolver; `no_tail` and `:js_tail` removed.
- `eval_list` without spread as a plain map.

### Step 4: `await` facts (S to M)

Statement facts were done in 2e. The measurements of the step 4 design
(notes/js-step4-design.md) show that all CPS walks together cost at most 0.1% of a Speedometer
suite at level 4, so step 4 gives no Speedometer gain. Step 4 lands a faster shared walk
(`Browser.JS.Awaits.any?/1`), a tidier `lift` and loop-entry facts, each behind a measured gate.
Expression facts, lift plans and the removal of `fill` move to step 5 as CPS plans.

### Step 5: closure compilation (XL), measure first

Prototype on the hot expression and statement kinds with a fallback to the tree. Keep it only
if the bench shows 15% or more on the nine programs and a Speedometer suite. For async and
generator bodies, step 5 also compiles CPS plans: one await fact per expression, lift plans
and compiled templates instead of `fill` (notes/js-step4-design.md, section 6.2).

### After step 5

Re-profile a Speedometer run. Decide between integers, dense arrays, global caches and the DOM
binding dispatch from that profile, not from this document.

## 7. What this design does not fix

- The gap to a JIT engine (20 to 40 runs/min in Speedometer against about 0.3 after this plan).
- Layout and paint. They are a separate workstream.
- Memory: fewer frames mean a smaller heap, but objects keep their shape.
- Parsing (`Lexer.ident` shows at 0.9% in Speedometer); the resolver adds a pass of its own,
  which is cheap next to the lexer.
