defmodule Browser.JS.Compile.Operand do
  @moduledoc """
  Gives the code that reads an operand form of `Browser.JS.Compile`.

  The macros `pair/6` and `one/4` of `Browser.JS.Compile` use this module when they expand.
  At that time, the functions of `Browser.JS.Compile` do not exist. Thus, this function is
  in a different module, which compiles first.
  """

  @doc """
  Gives the pattern of an operand form with the tag `tag` and the code that reads the value
  of the form in `env`. `side` gives a different name to the variables of each operand of a
  pair.
  """
  def form(tag, side, env) do
    var = fn name -> Macro.var(:"#{side}_#{name}", Browser.JS.Compile) end

    case tag do
      :k ->
        {quote(do: {:k, unquote(var.(:v))}), var.(:v)}

      :s ->
        {i, n} = {var.(:i), var.(:n)}

        {quote(do: {:s, unquote(i), unquote(n)}),
         quote(
           do: slot0(unquote(env), unquote(i), unquote(n), {:slot, 0, unquote(i), unquote(n)})
         )}

      :f ->
        f = var.(:f)
        {quote(do: {:f, unquote(f)}), quote(do: unquote(f).(unquote(env)))}
    end
  end
end

defmodule Browser.JS.Compile do
  @moduledoc """
  Closure compilation of JS function bodies (step 5).

  The resolver rewrites a function so that the function runs on a slot frame. At the first
  call of such a function, this module changes the body into Elixir closures. A closure
  takes the frame id. It gives the value or the completion of the code that it replaces.
  The interpreter (`Browser.JS.Interp`) then calls the closures. It does not walk the
  syntax tree of the body again.

  ## Which nodes compile

  These node kinds have closures of their own:

    * constants, slot reads and `this`;
    * the reads of a name in the global scope or in a map scope (`{:gref}`, `{:mref}`);
    * `?:`, `&&`, `||`, `??`, the comma operator, templates and optional chains;
    * the unary operators and the binary operators;
    * property reads, calls, `new`, array literals and object literals;
    * assignments, compound assignments, `++` and `--` to a slot or to a property;
    * the statements `expr`, `return`, `if`, `block`, `var`, `let`, `const`, `for`,
      `while`, `break`, `continue`, `throw` and labels.

  A parent reads a constant operand inline. It also reads a slot of its own frame inline.
  Thus these operands need no closure call. A binary operator and a test have one closure
  for each kind of operand. Thus the closure does not test the kind when it runs.

  The tests of `if`, `?:`, `for` and `while` give an Elixir boolean. A comparison gives its
  value. `!`, `&&` and `||` join the booleans of their operands. A comparison of operands
  goes into the closure of its branch.

  A slot read reads up to three scope headers inline. For more hops, it calls
  `Interp.hop/2`.

  A property read or write with a constant key uses `Interp.get_ic/3`, `Interp.put_ic/4`
  or `Interp.strict_put_ic/4` when the key is not an array index. Each such site gets a
  site number when it compiles, and the cell of its inline cache is the process key with
  that number (step A2, see "The inline caches" in `Browser.JS.Shape`). A miss and every
  record that is not fast go to the class dispatch of `Interp.get_named/2` and
  `Interp.put_named/3`, which is the one of `Interp.get/2` and `Interp.put/3` without the
  conversion of the key. The key `"length"` also goes to these functions (the design kept
  it on `get/2`): their class dispatch has the `length` clauses of arrays, strings and
  functions. A write site that adds a new key, as `this.x = v` in a constructor does, can
  get an add cell (step A3), which gives the record its new shape with no walk of the
  prototype chain.

  An object literal with constant keys and plain values gets the shape of its keys when it
  compiles (step A3). When it runs, it gets the id of the object first, then it evaluates
  the values, and then it writes the record in one write (`Interp.put_literal/4`). `new`
  of a plain function of the compiled code takes the short way of
  `Interp.construct_new/3`, which reads the record of the function once.

  ## Shells

  Some nodes stay on the tree walker, but their children compile. Such a node is a shell.
  The compiler makes a copy of the node. In the copy, each expression or statement child is
  `{:cc, closure}`. `Interp.ev/2`, `exec/3` and `fstmt/3` run such a child with one call.

  These nodes are shells:

    * `switch`, `try`, `for-in`, `for-of` and `do-while`;
    * a block or a `for` that makes a block frame;
    * a declaration with a pattern;
    * a literal with a spread or a method;
    * a call with a callee that the tree reads by name;
    * some rare forms of assignment and of `delete`.

  Thus the order of `try` and `finally`, the close of iterators, the copies of a loop scope
  and the block frames have one implementation, in `Interp`. A shell keeps the functions
  and the classes as they are, because the heap keeps these nodes. A shell also keeps the
  callee of a call as it is, because the text of an error names the callee.

  ## Nodes on the tree

  Every other node stays on the tree walker with all the nodes in it. Its closure gives the
  node to `Interp.ev/2`, `Interp.fstmt/3` or `Interp.tail_value/2`. These nodes are:

    * functions and classes;
    * the reads and writes of a name that the resolver did not put in a slot;
    * the special forms of `typeof` and `delete`;
    * `super`, `import` and regular expressions;
    * the strings of a tagged template.

  ## Same results

  A compiled node does the same steps in the same order as its clause in `Interp`. It
  calls the same helpers of `Interp` for the work that the two share. This work is the
  frame of a call, the operators, the property reads and writes, and the slot writes.
  Thus a compiled body and the tree walker give the same values, errors, steps and heap
  ids.

  ## Which functions compile

  A function compiles when all of these conditions are true:

    * the resolver rewrote the function (`Info.rewritten`);
    * the `Info` has a `uid`;
    * the switch `:js_compile` of the process is on.

  The body of a sync function becomes a closure (`code/1`). The body of an async function
  or a generator becomes a plan (`cps_body/1`, see "CPS plans").

  The level of a function is the level of the parse that made it. The JS built-ins
  (`Browser.JS.Prelude` and the prelude of the web API) parse at the level of the
  application. Thus, with the application at level 4, they compile also in a script that
  parses at `:off`. For a run with no compiled code, set the application level to `:off`
  (`JS_RESOLVE=off`) or the switch to `false` (`JS_COMPILE=0`).

  ## CPS plans (step 5c)

  `Browser.JS.Async` runs the body of an async function or a generator in
  continuation-passing style, so that an `await` or a `yield` can suspend it. At the first
  call of such a function, this module changes the body into a plan. The plan is a closure
  `fn env, ctx, k -> ... end`. `env` is the frame, `ctx` is the context of `Async` (the
  continuations of `return`, `throw`, `yield`, `break` and `continue`), and `k` is the
  continuation of the body. `Async.run_body/4` runs the plan in frame mode.

  The tree path of `Async` finds some facts each time that it runs. The plan finds them
  once, when it compiles:

    * Statement facts. A statement list splits at each statement with the mark `{:aw}`.
      A run of statements between these compiles with the sync compiler into one
      closure, which runs under one `try`. (A `return;` of an async generator is
      `{:return, {:lit, :ag_bare}}` from the parser, so a sync run gives the marker and
      the generator finishes without an await.)
    * Expression facts. `Browser.JS.Awaits.any?/1` runs once for each node that the plan
      compiles. An expression that does not await is a closure of the sync compiler.
    * Lift plans. `Async.lift_plan/1` gives the template and the leaves of an expression
      that awaits. The template compiles with the sync compiler. A hole `{:cps_leaf, i}`
      reads the value of the leaf `i` from the process key `:js_cps_vals`, which
      `Async.lifted/5` sets while the template runs. The leaves run first, in source order,
      and then the template. This is the order of the tree path, and `:off` has the same
      order, so all levels agree.
    * Loop facts. The test and the update of a `for` or a `while` compile once.

  These kinds compile into the plan: `await`, a plain `yield`, `&&`, `||`, `??`, `?:` and a
  destructuring assignment that awaits, the lift plan of each other expression, and the
  statements `expr`, `var`, `let`, `const`, `return`, `throw`, `if`, `block`, labels,
  `while`, `do`/`while`, `for` and `switch`.

  These kinds stay on the tree path of `Async`:

    * `yield*`, because it runs through the delegate functions of `Async`;
    * an optional chain that awaits, because it puts its value into the tree;
    * a logical assignment (`&&=`, `||=`, `??=`) that awaits, because its right side runs
      only when the operator does not short-circuit;
    * a lift plan with a leaf from a class, because the leaf runs in a class scope;
    * for-in, for-of and for-await;
    * `try` with an await, and `using`;
    * the bind of a pattern that awaits, which runs through `Async.cbind_cps/6` (the
      declaration itself is part of the plan).

  A plan makes no fun when it runs. A continuation keeps the frame id, so the collector
  must walk it. Thus only the named functions of `Async` (for example `Async.then/5`,
  `Async.await_cps/4`, `Async.lifted/5` and `Async.for_k/5`) make the continuations of a
  plan. Their funs belong to `Async`, and the collector walks them. The walk stops at the
  compiled closures that they keep.

  The plan uses the cache, the uid and the budget of a sync body (see "The cache" and
  "Memory bound").

  ## The switch

  The application setting `:js_compile` is the switch. Its default is `true`.
  `JS_COMPILE=0` sets it to `false`. `Browser.JS.Interp.init/1` copies the setting into
  the process dictionary. Thus each heap has its own value, and one VM can run the two
  modes. With the switch off, a closure record gets no `code` key, so the run does the
  work of the tree walker only.

  ## The cache

  The process dictionary keeps the compiled code of each function under the key
  `{:jsc, uid}`. The value is `{body, maker}`:

    * `body` is the closure of the body, or `nil` when the body stays on the tree. For an
      async function or a generator, `body` is the plan.
    * `maker` is the frame maker of the function, or `nil`. An async function and a
      generator have no maker, because `Interp.enter_frame/4` makes their frames.

  A sync function object keeps its code in its closure record, in the keys `code` and
  `mk`. Its first call writes them (`Interp.first_call/2`), so the next calls do not read
  the cache. An async function or a generator gets its plan in its record only when
  `make_fn` makes the object after the plan compiled. Else each call reads the cache, and
  after an erase the next call compiles the plan again.

  ## Frame makers

  A frame maker makes the frame tuple of a call. It knows the shape of the frame when it
  compiles. Thus it does not walk the lists of the parameters and of the hidden slots for
  each call. Only a function with plain parameters gets a maker. The function must have no
  hidden slot, or only the `this` slot.

  ## Memory bound

    * A function with more than 65,536 compiled nodes stays on the tree. Its cache entry is
      `{nil, nil}`. A node of a plan counts as one node, as a node of a sync body does.
    * The process key `:jsc_budget` holds `{nodes, erases}`. `nodes` is the number of
      compiled nodes in the cache, plus 16 for each entry (its fixed part).
    * When the count goes above 400,000 (about 25 to 60 MB on a 64-bit VM), all the
      entries of the cache go. Then the count starts again. `erases` counts these events.
    * Each site of an inline cache counts as one more node, because its cell (a tuple of
      up to 8 small elements under its own process key) is memory of the cache. An erase
      of the cache erases all the cells too (`erase_entries/0`).
    * An add cell (step A3) also keeps a whole shape, the shape after the add. A shape of
      `n` keys is about `16 + 10 * n` words, and an erase of the transition table does not
      free it while the cell lives. So each write of an add cell counts `(16 + 10 * n) / 8`
      more nodes (`charge/1`, from `Interp.ic_learn_add/5`). The count is high when many
      cells share one shape, but it is never low, so the budget of the cache is also a
      bound of the shapes that the cells keep.
    * The count does not include the syntax that a closure of the tree keeps (for example
      a nested function). The heap keeps that syntax also while a function of the parse
      is alive.

  A function object keeps its code. Thus the live code stays bounded by the live
  functions. Each parse of `new Function` code or of `eval` code makes new uids. Thus a
  loop that makes functions without end can not fill the memory.

  ## Rules for the code

    * A compiled closure keeps only values that are known at compile time: slot numbers,
      names, constants, syntax nodes, other compiled closures, the site numbers of the
      inline caches (negative integers, see `Browser.JS.Shape`) and the shapes of object
      literals (a shape holds no heap id). It never keeps a frame id or a heap id. Thus
      the collector (`Browser.JS.GC`) does not walk the cache or the funs of this module.
    * Each closure has one parent closure. Thus the size of the code is linear in the size
      of the body.
    * Compiled code makes no fun when it runs. A loop is a named function of this module.
      The loop gets its closures as arguments. A plan gives each continuation to a named
      function of `Browser.JS.Async`, which makes it.
    * The code stays in its process. Do not send it in a message. Do not put it in ETS, in
      `persistent_term` or in `term_to_binary`.

  ## Check mode

  When the application has `:js_resolve_check`, compiled code does these checks:

    * A body runs only on a frame (S1).
    * Each statement of a list completes with one of the shapes of step 3. A loop gives
      back no break or continue of its own (S2).
    * A slot read or write calls the same checks as its twin on the tree. A call checks
      the call chain (S3).
    * A shell has no compiled child in a function, in a class or in the callee of a call
      (S4).
    * The compiled code of a body or a plan keeps no object, no `{:val}` node and no frame
      (S5).
    * A plan runs only on a frame (S1). A statement of a plan has the mark `{:aw}` only
      when it awaits, and the lift plan is the lift plan of the old walk (item A2 of
      step 4).
    * The tuple of a frame maker is equal to the tuple of the frame builder of `Interp`
      (S6, in `Interp.frame_call/6`).

  When the process key `:jsc_trace` holds a list, the compiler adds to the list each node
  that stays on the tree. The coverage test uses this list.
  """

  alias Browser.JS.{Async, Awaits, Interp, Num}
  alias Browser.JS.Resolve.Info
  require Browser.JS.Fast, as: Fast

  # In check mode compiled code makes the checks of its twins on the tree. The attribute is
  # a constant, so a normal build has no test.
  @check Application.compile_env(:browser, :js_resolve_check, false)

  @doc """
  Gives the compiled code of the closure record `c`: `{body, maker}`, or `nil` when the
  function does not compile. `maker` is the frame maker of the function, or `nil`. The
  first call for a function compiles the body and puts it in the cache.
  """
  @spec code(map) :: {(integer -> term), function | nil} | nil
  def code(%{info: %Info{rewritten: true, async?: false, generator?: false, uid: uid}} = c)
      when uid != nil do
    # (the switch is off when it was never set: a process that did not start its heap with
    # `Interp.init/1` runs on the tree walker)
    if :erlang.get(:js_compile) == true do
      case :erlang.get({:jsc, uid}) do
        {_body, _maker} = code -> code
        :undefined -> compile_and_store(c, uid)
      end
    end
  end

  def code(_c), do: nil

  @doc """
  Gives the compiled plan of the closure record `c` of an async function or a generator
  (step 5c), or `nil` when the body stays on the tree path. The plan is
  `fn env, ctx, k -> ... end` (see "CPS plans"). The first call for a function compiles
  the body and puts the plan in the cache, as `{plan, nil}`.
  """
  @spec cps_body(map) :: function | nil
  # (a function object that was made after its body compiled has the plan in its record;
  # `make_fn` copies it from the cache)
  def cps_body(%{code: plan, info: %Info{async?: a, generator?: g}}) when a or g, do: plan

  def cps_body(%{info: %Info{rewritten: true, uid: uid, async?: a, generator?: g}} = c)
      when uid != nil and (a or g) do
    if :erlang.get(:js_compile) == true do
      case :erlang.get({:jsc, uid}) do
        {plan, _} -> plan
        :undefined -> elem(compile_and_store(c, uid, &cps_code/1), 0)
      end
    end
  end

  def cps_body(_c), do: nil

  # The fixed part of an entry, in nodes (about 230 words for a small function).
  @entry_nodes 16

  defp compile_and_store(c, uid, build \\ &sync_code/1) do
    :erlang.put(:jsc_count, 0)

    {code, n} =
      try do
        {build.(c), :erlang.get(:jsc_count)}
      catch
        # (a function over the cap stays on the tree; its entry in the cache tells the
        # next function objects so)
        :jsc_too_big -> {{nil, nil}, 0}
      after
        :erlang.erase(:jsc_count)
      end

    check_capture(code)
    # Each entry also costs its fixed part: the tuple, the maker and the `Info` that the
    # maker keeps. `@entry_nodes` counts that part, so that an entry with no compiled node
    # also uses the budget. (an exact size with `:erts_debug.size/1` doubled the
    # reductions of a React suite, because it walks the syntax that the closures keep)
    budget(n + @entry_nodes)
    :erlang.put({:jsc, uid}, code)
    code
  end

  defp sync_code(c), do: {body(c), maker(c.info)}

  # ── memory bound ───────────────────────────────────────────

  # A function with more nodes than this stays on the tree. The largest function of the
  # Speedometer suites has about 10.7k words of compiled code, so the cap is far above
  # real code. It stops a generated function of megabytes from making code of megabytes.
  @max_nodes 65_536

  # The budget of the cache of a process, in compiled nodes. A node of a cache entry costs
  # 8 to 18 words (measured with `:erts_debug.size/1` on `new Function` bodies), so the
  # budget is about 25 to 60 MB on a 64-bit VM. A page that makes new functions without
  # end (`new Function` or `eval` in a loop) makes new uids, and each uid gets its own
  # entry. A Speedometer suite keeps about 20,000 nodes.
  @budget 400_000

  # Counts one compiled node of the body that compiles now. The count is in the process
  # key `:jsc_count`, which `compile_and_store/2` sets and erases.
  defp count do
    n = :erlang.get(:jsc_count) + 1
    if n > @max_nodes, do: throw(:jsc_too_big)
    :erlang.put(:jsc_count, n)
  end

  @doc """
  Adds `n` nodes to the count of the cache, for memory that the cache keeps outside its
  entries: the shape that an add cell of an inline cache keeps (see "Memory bound"). Over
  the budget, all the entries and the cells go, as for a new entry.
  """
  def charge(n), do: budget(n)

  # Adds the `n` nodes of a new entry to the count of the cache. Over the budget, all the
  # entries go, and the count starts again with the new entry. A function object keeps
  # its code in its closure record, so the live code stays bounded by the live functions.
  # The process key `:jsc_budget` holds `{nodes, erases}`. The collector does not read it
  # as a root (`Browser.JS.GC`).
  defp budget(n) do
    {total, erases} =
      case :erlang.get(:jsc_budget) do
        :undefined -> {0, 0}
        b -> b
      end

    # (a test can set a smaller budget in the process key `:jsc_budget_max`)
    max =
      case :erlang.get(:jsc_budget_max) do
        :undefined -> @budget
        m -> m
      end

    if total + n > max do
      erase_entries()
      :erlang.put(:jsc_budget, {n, erases + 1})
    else
      :erlang.put(:jsc_budget, {total + n, erases})
    end
  end

  @doc """
  Erases the entries of the code cache and the cells of the inline caches (the process keys
  that are negative integers, see `Browser.JS.Shape`), in one walk of the process
  dictionary. The cells go with the cache, so that the memory bound of the cache is also a
  bound of the cells. A function object keeps its code after an erase, and its sites then
  write their cells again. The count of the cache (`:jsc_budget`) is for the caller.
  """
  def erase_entries do
    for {k, _} <- :erlang.get(),
        match?({:jsc, _}, k) or (is_integer(k) and k < 0),
        do: :erlang.erase(k)

    :ok
  end

  # ── frame makers ───────────────────────────────────────────

  # The value of the `this` slot at entry, as `hidden_slots/8` in `Interp` gives it: a
  # sloppy function gets the global object for `undefined` and a boxed primitive.
  defmacrop entry_this(strict, this) do
    quote do
      if unquote(strict), do: unquote(this), else: Interp.sloppy_this(false, unquote(this))
    end
  end

  # The frame maker of a function: `fn scope, link, pos, root, this, args -> frame tuple
  # end`. It gives the tuple that `frame_slots/5` in `Interp` gives with the header, but it
  # knows the shape of the frame when it compiles. Thus it does not walk the lists of
  # hidden slots and parameters for each call. Only a function with plain parameters and
  # no hidden slot other than `this` gets a maker. The other hidden slots need the function
  # object or the new target, which only the frame builder of `Interp` fills.
  #
  # For up to two parameters and no template, the maker is a tuple literal. Otherwise it
  # puts the arguments in front of the prebuilt list of the hidden slot and the template,
  # and makes the tuple of the list. A missing argument is `undefined`, and an extra
  # argument is dropped, as in `plain_slots/3`.
  defp maker(
         %Info{params: :plain, hidden: hidden, nparams: n, template: t, strict: strict} = info
       )
       when hidden in [[], [:this]] do
    case {n, hidden, t} do
      {0, [], []} ->
        fn s, l, p, r, _this, _args -> {s, info, l, p, r} end

      {1, [], []} ->
        fn s, l, p, r, _this, args ->
          case args do
            [a | _] -> {s, info, l, p, r, a}
            [] -> {s, info, l, p, r, :undefined}
          end
        end

      {2, [], []} ->
        fn s, l, p, r, _this, args ->
          case args do
            [a, b | _] -> {s, info, l, p, r, a, b}
            [a] -> {s, info, l, p, r, a, :undefined}
            [] -> {s, info, l, p, r, :undefined, :undefined}
          end
        end

      {0, [:this], []} ->
        fn s, l, p, r, this, _args -> {s, info, l, p, r, entry_this(strict, this)} end

      {1, [:this], []} ->
        fn s, l, p, r, this, args ->
          case args do
            [a | _] -> {s, info, l, p, r, a, entry_this(strict, this)}
            [] -> {s, info, l, p, r, :undefined, entry_this(strict, this)}
          end
        end

      {2, [:this], []} ->
        fn s, l, p, r, this, args ->
          case args do
            [a, b | _] -> {s, info, l, p, r, a, b, entry_this(strict, this)}
            [a] -> {s, info, l, p, r, a, :undefined, entry_this(strict, this)}
            [] -> {s, info, l, p, r, :undefined, :undefined, entry_this(strict, this)}
          end
        end

      {n, [], t} ->
        fn s, l, p, r, _this, args ->
          :erlang.list_to_tuple([s, info, l, p, r | Interp.plain_slots(args, n, t)])
        end

      {n, [:this], t} ->
        fn s, l, p, r, this, args ->
          rest = [entry_this(strict, this) | t]
          :erlang.list_to_tuple([s, info, l, p, r | Interp.plain_slots(args, n, rest)])
        end
    end
  end

  defp maker(_info), do: nil

  # The closure of a body. An arrow with an expression body gives the value of the
  # expression, and every other body gives the completion of its statement list.
  # `body_value/2` in `Interp` reads the two kinds by the mode of the closure record.
  defp body(%{mode: :arrow_expr, body: e}), do: entry(expr(e))
  defp body(%{body: stmts}), do: entry(list(stmts))

  # S1: in check mode a body must run on a frame, because its slot reads read a tuple.
  if @check do
    defp entry(f) do
      fn env ->
        unless is_tuple(:erlang.get(env)),
          do: raise(ArgumentError, "resolve check: a compiled body runs on #{inspect(env)}")

        f.(env)
      end
    end
  else
    defp entry(f), do: f
  end

  # The node shapes that take the name of the binding that they are assigned to (as the
  # guard of the same name in `Interp`). An assignment of such a value names it through
  # `Interp.ev_named/3`, so it stays on the tree.
  defguardp nameable(e)
            when (elem(e, 0) in [:fn, :class] and elem(e, 1) == nil) or
                   elem(e, 0) in [:gen, :async]

  # A statement scope whose names are slots of the frame (as the guard of the same name in
  # `Interp`). A framed scope makes a block frame, which stays on the tree.
  defguardp frameless(sc) when sc == nil or (is_map(sc) and :erlang.map_get(:frame, sc) == false)

  # ── slot reads ─────────────────────────────────────────────

  # The read of slot `i` of the frame `frame`, as `ev/2` reads `{:slot, 0, i, name}`: a
  # binding in its temporal dead zone throws. `form` is the slot form at depth 0, for the
  # checks of check mode. The read is a macro, so that a parent reads a slot inline.
  defmacrop slot0(frame, i, name, form) do
    quote do
      f = unquote(frame)
      if @check, do: Interp.check_landing(unquote(form), f)

      case :erlang.element(unquote(i), :erlang.get(f)) do
        :tdz ->
          Interp.tdz_error(unquote(name))

        v ->
          # (only `{:aslot}` may meet the marker of an arguments object that is not built)
          if @check and match?({:unbuilt, _}, v),
            do: raise(ArgumentError, "resolve check: {:slot} reads an unbuilt arguments object")

          v
      end
    end
  end

  # The parent of the scope `env`: the first element of a frame, or the `parent` of a map
  # scope, as `parent_of/1` in `Interp` reads it. (check mode reads parents with `hop/2`,
  # so only the normal build has the macro)
  unless @check do
    defmacrop parent(env) do
      quote do
        case :erlang.get(unquote(env)) do
          parent_f when is_tuple(parent_f) -> :erlang.element(1, parent_f)
          %{parent: parent_p} -> parent_p
        end
      end
    end
  end

  # The scope `d` hops above `env`, as `Interp.hop/2` finds it. Up to three hops read the
  # headers inline, because the code of a bundle runs in functions that are nested in the
  # function of its module, and a read of a name of the module is two or three hops away.
  # Check mode always calls `hop/2`, which checks that each frame is live.
  defmacrop up(env, d) do
    if @check do
      quote do: Interp.hop(unquote(env), unquote(d))
    else
      quote do
        env = unquote(env)

        case unquote(d) do
          0 -> env
          1 -> parent(env)
          2 -> parent(parent(env))
          3 -> parent(parent(parent(env)))
          d -> Interp.hop(env, d)
        end
      end
    end
  end

  # ── operands ───────────────────────────────────────────────

  # Most operands of hot code are constants and slots of the frame itself. A parent reads
  # such an operand inline, because a closure call costs one reduction and one jump. An
  # operand form (`opnd/1`) is one of these:
  #
  #   * `{:k, value}`: a constant;
  #   * `{:s, i, name}`: slot `i` of the frame itself (depth 0);
  #   * `{:f, closure}`: the closure of any other expression.
  #
  # A parent that reads the form at run time uses `av/2`, which is one `case` and no call.
  # A hot parent (a binary operator, a test) has one closure for each form of its
  # operands (`pair/6`, `one/4`), so that its closure tests nothing at run time.

  # The value of the operand form `o`.
  defmacrop av(o, env) do
    # The code is marked as generated because a parent that knows the tag of a form when
    # it compiles also uses this macro, and the type checker would warn about the clauses
    # that do not match.
    quote generated: true do
      case unquote(o) do
        {:k, av_v} -> av_v
        {:s, av_i, av_n} -> slot0(unquote(env), av_i, av_n, {:slot, 0, av_i, av_n})
        {:f, av_f} -> av_f.(unquote(env))
      end
    end
  end

  # The closure of a node with two operand forms, `lo` and `ro`: one closure for each pair
  # of tags. The closure reads the left operand into `a`, then the right operand into `b`
  # (the order of the tree walker), then gives the value of `body`.
  defmacrop pair(env, lo, ro, a, b, body) do
    clauses =
      for l <- [:k, :s, :f], r <- [:k, :s, :f] do
        {lp, lr} = Browser.JS.Compile.Operand.form(l, :l, env)
        {rp, rr} = Browser.JS.Compile.Operand.form(r, :r, env)

        hd(
          quote generated: true do
            {unquote(lp), unquote(rp)} ->
              fn unquote(env) ->
                _ = unquote(env)
                unquote(a) = unquote(lr)
                unquote(b) = unquote(rr)
                unquote(body)
              end
          end
        )
      end

    quote generated: true do
      case {unquote(lo), unquote(ro)} do
        unquote(clauses)
      end
    end
  end

  # The closure of a node with one operand form `o`: one closure for each tag. The closure
  # reads the operand into `a`, then gives the value of `body`.
  defmacrop one(env, o, a, body) do
    clauses =
      for t <- [:k, :s, :f] do
        {p, read} = Browser.JS.Compile.Operand.form(t, :o, env)

        hd(
          quote generated: true do
            unquote(p) ->
              fn unquote(env) ->
                _ = unquote(env)
                unquote(a) = unquote(read)
                unquote(body)
              end
          end
        )
      end

    quote generated: true do
      case unquote(o) do
        unquote(clauses)
      end
    end
  end

  # The truthiness of `v`, as `Interp.truthy/1` gives it. The common values are tested
  # inline, so that a test needs no call. The last clause calls `truthy/1` for the rest.
  defmacrop tru(v) do
    quote do
      case unquote(v) do
        true -> true
        false -> false
        :undefined -> false
        :null -> false
        {:obj, _} -> true
        tru_x when is_number(tru_x) -> tru_x != 0
        "" -> false
        tru_x when is_binary(tru_x) -> true
        tru_x -> Interp.truthy(tru_x)
      end
    end
  end

  # The operators that a parent computes inline. `+`, `-`, `*` and the comparisons do the
  # first clauses of `Interp.binop/3` for two floats inline and call `binop/3` for every
  # other pair. The equality operators call `strict_eq/2` and `loose_eq/2`, which are the
  # clauses of `binop/3` for them. Because of this, the semantics are those of `binop/3`.
  @inline_ops ["+", "-", "*", "<", ">", "<=", ">=", "===", "!==", "==", "!="]

  # The operators whose value is always a boolean. A test (`ctest/1`) uses their value as
  # it is, without `truthy/1`.
  @tests ["<", ">", "<=", ">=", "===", "!==", "==", "!="]

  # The value of `a op b` for an operator `op` that is known when the macro expands.
  defmacrop op_body(op, a, b) do
    floats = quote do: is_float(unquote(a)) and is_float(unquote(b))
    slow = quote do: Interp.binop(unquote(op), unquote(a), unquote(b))

    # Two floats are equal for `Num.equal?/2` when `==` says so, because a float is never
    # NaN, and `==` gives true for 0.0 and -0.0.
    fast =
      case op do
        "+" -> quote do: Num.add(unquote(a), unquote(b))
        "-" -> quote do: Num.add(unquote(a), -unquote(b))
        "*" -> quote do: Num.mul(unquote(a), unquote(b))
        "<" -> quote do: unquote(a) < unquote(b)
        ">" -> quote do: unquote(a) > unquote(b)
        "<=" -> quote do: unquote(a) <= unquote(b)
        ">=" -> quote do: unquote(a) >= unquote(b)
        "===" -> quote do: unquote(a) == unquote(b)
        "!==" -> quote do: unquote(a) != unquote(b)
        "==" -> quote do: unquote(a) == unquote(b)
        "!=" -> quote do: unquote(a) != unquote(b)
      end

    slow =
      case op do
        "===" -> quote do: Interp.strict_eq(unquote(a), unquote(b))
        "!==" -> quote do: not Interp.strict_eq(unquote(a), unquote(b))
        "==" -> quote do: Interp.loose_eq(unquote(a), unquote(b))
        "!=" -> quote do: not Interp.loose_eq(unquote(a), unquote(b))
        _ -> slow
      end

    quote do
      if unquote(floats), do: unquote(fast), else: unquote(slow)
    end
  end

  # A branch closure, or `:ok` for a missing branch of an `if`.
  defmacrop run(c, env) do
    quote do
      case unquote(c) do
        nil -> :ok
        run_c -> run_c.(unquote(env))
      end
    end
  end

  # `x = v` to a slot: the write with `slot_assign/4`, which tests the temporal dead zone
  # and a constant, then the value.
  defmacrop assign_slot(env, d, i, name, v) do
    quote do
      Interp.slot_assign(up(unquote(env), unquote(d)), unquote(i), unquote(name), unquote(v))
      unquote(v)
    end
  end

  # The values of an argument list form, from left to right. Each value is bound before the
  # next one is read, because Erlang does not define the order of the parts of a list.
  defmacrop argv(al, env) do
    quote do
      env = unquote(env)

      case unquote(al) do
        {:a} ->
          []

        {:a, argv_x} ->
          [av(argv_x, env)]

        {:a, argv_x, argv_y} ->
          argv_a = av(argv_x, env)
          [argv_a, av(argv_y, env)]

        {:a, argv_x, argv_y, argv_z} ->
          argv_a = av(argv_x, env)
          argv_b = av(argv_y, env)
          [argv_a, argv_b, av(argv_z, env)]

        {:n, argv_os} ->
          values(argv_os, env)

        {:list, argv_cs} ->
          Interp.eval_list(argv_cs, env)
      end
    end
  end

  # ── expressions ────────────────────────────────────────────

  # The closure of the expression `e`: `fn env -> value end`. Each node counts for the
  # memory bound (see `count/0`).
  defp expr(e) do
    count()
    expr_node(e)
  end

  defp expr_node({:num, n}), do: fn _env -> n end
  defp expr_node({:str, s}), do: fn _env -> s end
  defp expr_node({:lit, v}), do: fn _env -> v end

  defp expr_node({:slot, 0, i, name} = form), do: fn env -> slot0(env, i, name, form) end

  defp expr_node({:slot, d, i, name}) do
    form = {:slot, 0, i, name}
    fn env -> slot0(up(env, d), i, name, form) end
  end

  defp expr_node({:this, d, i} = form) do
    fn env ->
      if @check, do: Interp.check_landing(form, env)

      case :erlang.element(i, :erlang.get(up(env, d))) do
        :uninit_this -> Interp.uninit_this_error()
        v -> v
      end
    end
  end

  defp expr_node({:gref, name} = form) do
    # (the by-name read of `ev_id/2` takes this node, so it is built once)
    id = {:id, name}

    fn env ->
      if @check, do: Interp.check_landing(form, env)
      Interp.ev_id(id, Interp.root(env))
    end
  end

  defp expr_node({:in_tdz, _names, e}), do: expr(e)

  defp expr_node({:cond, c, a, b}), do: cbranch(c, expr(a), expr(b))

  # (the right operand is read only when the left one does not give the value)
  defp expr_node({:logical, op, l, r}) do
    {lo, ro} = {opnd(l), opnd(r)}

    case op do
      "&&" -> one(env, lo, lv, if(tru(lv), do: av(ro, env), else: lv))
      "||" -> one(env, lo, lv, if(tru(lv), do: lv, else: av(ro, env)))
      "??" -> one(env, lo, lv, if(lv == :undefined or lv == :null, do: av(ro, env), else: lv))
    end
  end

  # (`!` has no special form in `ev/2`: its operand is a plain expression)
  defp expr_node({:unary, "!", _} = e), do: ctest(e)

  # (`#x in o` reads the private name in its own clause of `ev/2`)
  defp expr_node({:binary, "in", {:priv_ref, _} = l, r}), do: shell({:binary, "in", l, cc(r)})
  defp expr_node({:binary, op, l, r}), do: binary(op, opnd(l), opnd(r))

  defp expr_node({:member, o, k, opt}) do
    case k do
      {:priv, _} -> shell({:member, cc(o), k, opt})
      _ -> member(opnd(o), key_code(k), opt)
    end
  end

  defp expr_node({:call, callee, args, opt}) do
    case target(callee) do
      {:ok, target} -> call(target, list_code(args), opt, callee)
      # (the callee keeps its node: `call_target/2` reads its shape, and the text of an
      # error names it)
      :error -> shell({:call, callee, Enum.map(args, &carg/1), opt})
    end
  end

  defp expr_node({:new, callee, args}) do
    {cc, al} = {expr(callee), list_code(args)}

    fn env ->
      f = cc.(env)
      # (the arguments are evaluated before the callee is checked)
      argv = argv(al, env)
      if @check, do: Interp.check_link(env)

      # (a plain function takes the short way of `Interp.construct_new/3`, as in `ev/2`)
      Interp.construct_new(f, argv, callee)
    end
  end

  defp expr_node({kind, "=", {:slot, d, i, name}, value} = node)
       when kind in [:assign, :sassign] do
    if nameable(value) do
      fallback(node)
    else
      one(env, opnd(value), v, assign_slot(env, d, i, name, v))
    end
  end

  defp expr_node({kind, "=", {:member, o, k, _} = target, value})
       when kind in [:assign, :sassign] do
    case k do
      {:priv, _} -> shell({kind, "=", cmember(target), cc(value)})
      _ -> put(kind, opnd(o), key_code(k), opnd(value))
    end
  end

  # (a slot form that is not `{:slot}` writes through its own helper in `ev/2`, which
  # reads the value with `ev_named/3`)
  defp expr_node({kind, "=", {t, _, _, _} = target, value} = node)
       when kind in [:assign, :sassign] and t in [:cslot, :fname] do
    if nameable(value), do: fallback(node), else: shell({kind, "=", target, cc(value)})
  end

  defp expr_node({kind, "=", {t, _, _, _, _} = target, value} = node)
       when kind in [:assign, :sassign] and t == :mslot do
    if nameable(value), do: fallback(node), else: shell({kind, "=", target, cc(value)})
  end

  # A logical assignment (`&&=`, `||=`, `??=`) stays on the tree, which names a function
  # value through `ev_named/3`.
  defp expr_node({kind, op, target, value} = node)
       when kind in [:assign, :sassign] and op in ["&&=", "||=", "??="] do
    if nameable(value),
      do: fallback(node),
      else: shell({kind, op, ctarget(target), cc(value)})
  end

  defp expr_node({kind, op, target, value} = node)
       when kind in [:assign, :sassign] and op not in ["=", "&&=", "||=", "??="] do
    # (the operator of `x op= v` is `op` without the `=`, as in `compound_assign/5`)
    base = binary_part(op, 0, byte_size(op) - 1)

    case target do
      {:slot, d, i, name} ->
        compound_slot(base, d, i, name, opnd(value))

      {:member, o, k, _} when elem(k, 0) != :priv ->
        compound_member(base, kind == :sassign, opnd(o), key_code(k), opnd(value))

      # (`compound_assign/5` evaluates the value with `ev/2`, so the value is a child)
      _ ->
        if nameable(value),
          do: fallback(node),
          else: shell({kind, op, ctarget(target), cc(value)})
    end
  end

  defp expr_node({kind, op, prefix?, target} = node) when kind in [:update, :supdate] do
    case target do
      {:slot, d, i, name} ->
        update_slot(op, prefix?, d, i, name)

      {:member, o, k, _} when elem(k, 0) != :priv ->
        update_member(op, prefix?, kind == :supdate, opnd(o), key_code(k))

      {:member, _, _, _} ->
        shell({kind, op, prefix?, cmember(target)})

      _ ->
        fallback(node)
    end
  end

  defp expr_node({:array, elems}) do
    if plain_list?(elems) do
      # (`ev/2` evaluates the elements before it makes the array, as here. A literal of
      # at most three elements makes the tuple of a dense array with no list, step B2)
      case list_code(elems) do
        {:a} ->
          fn _env -> Interp.new_array_vec({}) end

        {:a, x} ->
          fn env -> Interp.new_array_vec({av(x, env)}) end

        {:a, x, y} ->
          fn env ->
            a = av(x, env)
            Interp.new_array_vec({a, av(y, env)})
          end

        {:a, x, y, z} ->
          fn env ->
            a = av(x, env)
            b = av(y, env)
            Interp.new_array_vec({a, b, av(z, env)})
          end

        {:n, os} ->
          fn env -> Interp.new_array(values(os, env)) end
      end
    else
      shell({:array, Enum.map(elems, &carg/1)})
    end
  end

  defp expr_node({:object, props}) do
    if Enum.all?(props, &plain_prop?/1) do
      pcs = for {:init, {:str, k}, v} <- props, do: {k, opnd(v)}

      if Fast.on?(:literal) do
        # The object gets its id first, as `ev/2` makes the object before it evaluates the
        # values, and its record in one write at the end (fast path `:literal`, see "object
        # literals" in `Browser.JS.Interp`). Nothing can see the object before the literal
        # is done: no name refers to it, and the literal defines no method that needs the
        # object as its home (`plain_prop?/1`). The key layout comes from the record API when the
        # literal compiles, as `Interp.define_data/3` would make it: a key that comes two
        # times keeps its first place and its last value. The layout holds only the
        # constant keys and a shape. A shape holds no heap id and stays correct when the
        # transition table is erased (`Browser.JS.Shape`), so the closure keeps it, also
        # in a new heap.
        layout = pcs |> Enum.map(&elem(&1, 0)) |> Browser.JS.Obj.literal_keys()
        literal(layout, Enum.map(pcs, &elem(&1, 1)))
      else
        fn env ->
          obj = Interp.new_object()
          props(pcs, obj, env)
          obj
        end
      end
    else
      shell({:object, Enum.map(props, &cprop/1)})
    end
  end

  defp expr_node({:seq, es}) do
    cs = Enum.map(es, &expr/1)
    fn env -> seq(cs, env) end
  end

  # (as `ev/2`: the special forms of `typeof` read a name that can be missing)
  defp expr_node({:unary, "typeof", {:slot, d, i, name} = form}) do
    fn env ->
      if @check, do: Interp.check_landing(form, env)

      case :erlang.element(i, :erlang.get(up(env, d))) do
        :tdz -> Interp.tdz_error(name)
        v -> Interp.typeof(v)
      end
    end
  end

  defp expr_node({:unary, "typeof", {k, _, _}} = node) when k in [:aslot, :mref],
    do: fallback(node)

  defp expr_node({:unary, "typeof", {k, _}} = node) when k in [:gref, :id], do: fallback(node)

  # (a constant operand gives the same value at each run, so the value is computed once)
  defp expr_node({:unary, "-", {:num, n}}) do
    v = Num.neg(n)
    fn _env -> v end
  end

  defp expr_node({:unary, "void", {:num, _}}), do: fn _env -> :undefined end

  defp expr_node({:unary, op, e}) when op in ["-", "+", "~", "typeof", "void"],
    do: unary(op, opnd(e))

  defp expr_node({:unary, d, {:member, _, _, _} = target}) when d in ["delete", "sdelete"],
    do: shell({:unary, d, cmember(target)})

  defp expr_node({:tmpl, parts}) do
    pcs = Enum.map(parts, fn p -> if is_binary(p), do: p, else: opnd(p) end)
    fn env -> parts(pcs, env, []) |> Browser.JS.Str.join() end
  end

  # (an optional member or call in the chain throws `:js_short`, as in `ev/2`)
  defp expr_node({:chain, e}) do
    ec = expr(e)

    fn env ->
      try do
        ec.(env)
      catch
        :js_short -> :undefined
      end
    end
  end

  defp expr_node({:mref, d, name} = form) do
    # (the by-name read of `ev_id/2` takes this node, so it is built once)
    id = {:id, name}

    fn env ->
      if @check, do: Interp.check_landing(form, env)
      Interp.ev_id(id, up(env, d))
    end
  end

  # (the marker only keeps a name from the value, see `ev_named/3`)
  defp expr_node({:unnamed, e}), do: expr(e)

  defp expr_node({:destructure, pat, right}), do: shell({:destructure, pat, cc(right)})

  # A hole of a compiled lift template (step 5c): the value of the leaf `i`, which
  # `Async.lifted/5` keeps in the process key `:js_cps_vals` while the template runs.
  defp expr_node({:cps_leaf, i}),
    do: fn _env -> :erlang.element(i + 1, :erlang.get(:js_cps_vals)) end

  defp expr_node(node), do: fallback(node)

  # The operand form of `e` (see the section on operands). A negative number and `void` of
  # a number are constants, as in `expr/1`. The markers `{:in_tdz}` and `{:unnamed}` do
  # nothing when they run, so their operand is the form of the expression in them.
  defp opnd({k, v}) when k in [:num, :str, :lit], do: {:k, v}
  defp opnd({:slot, 0, i, name}), do: {:s, i, name}
  defp opnd({:unary, "-", {:num, n}}), do: {:k, Num.neg(n)}
  defp opnd({:unary, "void", {:num, _}}), do: {:k, :undefined}
  defp opnd({:in_tdz, _names, e}), do: opnd(e)
  defp opnd({:unnamed, e}), do: opnd(e)
  defp opnd(e), do: {:f, expr(e)}

  # An item of an argument list or an array literal that `eval_list/2` evaluates as a plain
  # expression: no spread and no hole.
  defp plain_list?(items),
    do: Enum.all?(items, fn a -> a != :hole and not match?({:spread, _}, a) end)

  # A property of an object literal with a constant key and a value that takes no name.
  # `ev/2` names a function value after its key, which stays on the tree.
  defp plain_prop?({:init, {:str, _}, v}), do: not nameable(v) and not method_node?(v)
  defp plain_prop?(_), do: false

  # (as `method_node?/1` in `Interp`)
  defp method_node?({:fn, {:method, _}, _, _, _, _}), do: true
  defp method_node?({k, inner}) when k in [:gen, :async], do: method_node?(inner)
  defp method_node?(_), do: false

  # The properties of an object literal, from the first to the last, as `ev/2` defines
  # them: the value, then the property. This is the old path of
  # the fast path `:literal`, which only the check build can take.
  defp props([], _obj, _env), do: :ok

  defp props([{k, vo} | rest], obj, env) do
    Interp.define_data(obj, k, av(vo, env))
    props(rest, obj, env)
  end

  # The values of an object literal from the first to the last, in source order, for
  # `Interp.fill_new/4`. It is a named function, so the compiled code makes no fun when it
  # runs.
  defp lit_vals([], _env, acc), do: :lists.reverse(acc)

  defp lit_vals([vo | rest], env, acc) do
    v = av(vo, env)
    lit_vals(rest, env, [v | acc])
  end

  # The closure of an object literal with constant keys for the fast path `:literal`: the
  # layout `layout` (`Obj.literal_keys/1`) and the operand forms `os` of the values in
  # source order. A literal of up to 8 keys with a shape and no key that comes two times
  # (the usual literal, also `{}`) puts its values in a tuple, with no list, and the record
  # is one map literal (`Interp.put_literal/4`). The other literals give the list of their
  # values to `Interp.fill_new/4`.
  for n <- 0..8 do
    vars = for i <- 1..n//1, do: Macro.var(:"o#{i}", nil)
    vals = for i <- 1..n//1, do: Macro.var(:"v#{i}", nil)

    defp literal({_, _, {:js_shape, _, _, _, _, _, _}, nil} = layout, unquote(vars)) do
      fn env ->
        _ = env
        id = Interp.reserve()
        proto = Interp.proto(:object)

        unquote_splicing(
          for {v, o} <- Enum.zip(vals, vars) do
            quote do: unquote(v) = av(unquote(o), var!(env))
          end
        )

        Interp.put_literal(id, proto, layout, {unquote_splicing(vals)})
        {:obj, id}
      end
    end
  end

  defp literal(layout, os) do
    fn env ->
      id = Interp.reserve()
      proto = Interp.proto(:object)
      Interp.fill_new(id, proto, layout, lit_vals(os, env, []))
      {:obj, id}
    end
  end

  # The values of a comma expression, from left to right. The value is the last one.
  defp seq([c], env), do: c.(env)

  defp seq([c | cs], env) do
    c.(env)
    seq(cs, env)
  end

  # The strings of a template, from left to right. Each value becomes a string before the
  # next part runs, as in `ev/2`, because `toString` can run user code.
  defp parts([], _env, acc), do: Enum.reverse(acc)
  defp parts([p | ps], env, acc) when is_binary(p), do: parts(ps, env, [p | acc])

  defp parts([po | ps], env, acc) do
    s = Interp.to_str(av(po, env))
    parts(ps, env, [s | acc])
  end

  # The unary operators of the last clause of `ev/2` for `{:unary}`: the value, then the
  # operator.
  defp unary("-", o) do
    one(
      env,
      o,
      x,
      case Interp.numeric(x) do
        {:bigint, n} -> {:bigint, -n}
        n -> Num.neg(n)
      end
    )
  end

  defp unary("+", o), do: one(env, o, x, Interp.to_num(x))

  defp unary("~", o) do
    one(
      env,
      o,
      x,
      case Interp.numeric(x) do
        {:bigint, n} -> {:bigint, Bitwise.bnot(n)}
        n -> (Num.int32(n) |> Bitwise.bnot()) * 1.0
      end
    )
  end

  defp unary("typeof", o), do: one(env, o, x, Interp.typeof(x))
  defp unary("void", o), do: one(env, o, _x, :undefined)

  # ── operators and tests ────────────────────────────────────

  # A binary operator, chosen at compile time, on two operand forms. The left operand is
  # read first. The operators of `@inline_ops` compute two floats inline (`op_body/3`), and
  # every other case calls `Interp.binop/3`, so the semantics are those of `binop/3`.
  for op <- @inline_ops do
    defp binary(unquote(op), lo, ro), do: pair(env, lo, ro, a, b, op_body(unquote(op), a, b))
  end

  defp binary(op, lo, ro), do: pair(env, lo, ro, a, b, Interp.binop(op, a, b))

  # The closure of a test: `fn env -> boolean end`, with the truthiness of `e`. A
  # comparison gives its boolean as it is. `!`, `&&` and `||` join the booleans of their
  # operands, which keeps the order and the short circuit of the operators, because only
  # the truthiness of their value is used. Every other value goes through `tru/1`.
  defp ctest({:binary, op, l, r}) when op in @tests, do: binary(op, opnd(l), opnd(r))

  defp ctest({:unary, "!", e}) do
    if test?(e) do
      tc = ctest(e)
      fn env -> not tc.(env) end
    else
      one(env, opnd(e), x, not tru(x))
    end
  end

  defp ctest({:logical, "&&", l, r}) do
    {lc, rc} = {ctest(l), ctest(r)}
    fn env -> lc.(env) and rc.(env) end
  end

  defp ctest({:logical, "||", l, r}) do
    {lc, rc} = {ctest(l), ctest(r)}
    fn env -> lc.(env) or rc.(env) end
  end

  defp ctest(e), do: one(env, opnd(e), x, tru(x))

  # The nodes that `ctest/1` gives a test of their own.
  defp test?({:binary, op, _, _}), do: op in @tests
  defp test?({:unary, "!", _}), do: true
  defp test?({:logical, op, _, _}), do: op in ["&&", "||"]
  defp test?(_), do: false

  # A branch on the truthiness of `c`, for `if`, `?:` and `?:` at a tail site: the closure
  # runs `yc` when `c` is truthy and `nc` when it is not. A missing branch (`nil`) gives
  # `:ok`. A comparison and a plain operand go into the closure of the branch, so a branch
  # costs one closure call and its test. Each branch closure has this closure as its only
  # parent.
  for op <- @tests do
    defp cbranch({:binary, unquote(op), l, r}, yc, nc) do
      pair(
        env,
        opnd(l),
        opnd(r),
        a,
        b,
        if(op_body(unquote(op), a, b), do: run(yc, env), else: run(nc, env))
      )
    end
  end

  # (`!c` swaps the two branches)
  defp cbranch({:unary, "!", c}, yc, nc), do: cbranch(c, nc, yc)

  defp cbranch({:logical, op, _, _} = c, yc, nc) when op in ["&&", "||"] do
    tc = ctest(c)
    fn env -> if tc.(env), do: run(yc, env), else: run(nc, env) end
  end

  defp cbranch(c, yc, nc),
    do: one(env, opnd(c), x, if(tru(x), do: run(yc, env), else: run(nc, env)))

  # ── properties ─────────────────────────────────────────────

  # The key of a property node, as an operand form. A constant name is `{:k, name}`.
  defp key_code({:str, s}), do: {:k, s}
  defp key_code(k), do: opnd(k)

  # A constant key that `Interp.get_named/2` and `Interp.put_named/3` can take: a string
  # that is not an array index. Such a key needs no `index/1` and no `to_key/1` when the
  # code runs.
  defp named?(k), do: is_binary(k) and Interp.index(k) == nil

  # A new site of an inline cache (step A2, see `Browser.JS.Shape`): a negative integer that
  # the closure of the site keeps. The site counts as one node of the memory bound, because
  # its cell is memory of the cache.
  defp site do
    count()
    Browser.JS.Shape.new_site()
  end

  # A property read, as `ev/2` reads `{:member, o, k, opt}`: the object, the test of an
  # optional member, then the key. A named key reads through the inline cache of its site
  # (`Interp.get_ic/3`), whose generic path is the class dispatch of `get/2`.
  defp member(oo, {:k, s}, false) do
    if named?(s) do
      site = site()
      one(env, oo, ov, Interp.get_ic(ov, s, site))
    else
      one(env, oo, ov, Interp.get(ov, s))
    end
  end

  defp member(oo, ko, false), do: pair(env, oo, ko, ov, key, Interp.get(ov, key))

  defp member(oo, ko, true) do
    one(
      env,
      oo,
      ov,
      (
        if ov == :undefined or ov == :null, do: throw(:js_short)
        Interp.get(ov, av(ko, env))
      )
    )
  end

  # A property write `o[k] = v`: the object, the key, then the value, as `ev/2` writes it.
  # Sloppy code gives the value, and strict code gives what `strict_put/3` gives. A
  # constant key has nothing to evaluate, so the object and the value are a pair. A named
  # key writes through the inline cache of its site (`Interp.put_ic/4`), whose generic path
  # is the class dispatch of `put/3`.
  defp put(:assign, oo, {:k, s}, vo) do
    if named?(s) do
      site = site()
      pair(env, oo, vo, ov, v, Interp.put_ic(ov, s, v, site))
    else
      pair(
        env,
        oo,
        vo,
        ov,
        v,
        (
          Interp.put(ov, s, v)
          v
        )
      )
    end
  end

  defp put(:sassign, oo, {:k, s}, vo) do
    if named?(s) do
      site = site()
      pair(env, oo, vo, ov, v, Interp.strict_put_ic(ov, s, v, site))
    else
      pair(env, oo, vo, ov, v, Interp.strict_put(ov, s, v))
    end
  end

  defp put(:assign, oo, ko, vo) do
    fn env ->
      ov = av(oo, env)
      key = av(ko, env)
      v = av(vo, env)
      Interp.put(ov, key, v)
      v
    end
  end

  defp put(:sassign, oo, ko, vo) do
    fn env ->
      ov = av(oo, env)
      key = av(ko, env)
      v = av(vo, env)
      Interp.strict_put(ov, key, v)
    end
  end

  # `x op= v` to a slot, as `compound_assign/5` does it: one hop, the read with its test
  # of the temporal dead zone, the value, the operator, then the write. The result is the
  # write joined with the value by `&&`, as in `compound_assign/5`. `+`, `-` and `*`
  # compute two floats inline.
  for op <- ["+", "-", "*"] do
    defp compound_slot(unquote(op), d, i, name, vo) do
      form = {:slot, 0, i, name}

      fn env ->
        frame = up(env, d)
        old = slot0(frame, i, name, form)
        b = av(vo, env)
        v = op_body(unquote(op), old, b)
        Interp.slot_assign(frame, i, name, v) && v
      end
    end
  end

  defp compound_slot(base, d, i, name, vo) do
    form = {:slot, 0, i, name}

    fn env ->
      frame = up(env, d)
      old = slot0(frame, i, name, form)
      v = Interp.binop(base, old, av(vo, env))
      Interp.slot_assign(frame, i, name, v) && v
    end
  end

  # `o.name op= v` with a constant key that is not an array index (fast path `:compound`):
  # the read and the write go through the inline caches of two sites (`Interp.get_ic/3` and
  # `Interp.put_ic/4`), as `o.name` and `o.name = v` do. For such a key `to_key/1` gives the
  # key and `index/1` gives nil, so `get/2` and `put/3` take the same branch as the named
  # functions, and the message of a nullish object is the same (`safe_key/1` gives the key).
  defp compound_member(base, strict?, oo, {:k, s} = ko, vo) when is_binary(s) do
    if Fast.on?(:compound) and named?(s) do
      {rsite, wsite} = {site(), site()}

      fn env ->
        ov = av(oo, env)

        if Interp.nullish?(ov),
          do:
            Interp.throw_error(
              "TypeError",
              "Cannot read properties of #{Interp.to_str(ov)} (reading '#{s}')"
            )

        old = Interp.get_ic(ov, s, rsite)
        v = Interp.binop(base, old, av(vo, env))

        if(strict?,
          do: Interp.strict_put_ic(ov, s, v, wsite),
          else: Interp.put_ic(ov, s, v, wsite)
        ) && v
      end
    else
      compound_computed(base, strict?, oo, ko, vo)
    end
  end

  defp compound_member(base, strict?, oo, ko, vo),
    do: compound_computed(base, strict?, oo, ko, vo)

  # `o[k] op= v`, as `compound_assign/5` does it: the object, the key, the test of a
  # nullish object, the key conversion (once, for the read and the write, as
  # `Interp.prop_key/1` does it), the read, the value, the operator, then the write.
  defp compound_computed(base, strict?, oo, ko, vo) do
    fn env ->
      ov = av(oo, env)
      key = av(ko, env)

      if Interp.nullish?(ov),
        do:
          Interp.throw_error(
            "TypeError",
            "Cannot read properties of #{Interp.to_str(ov)} (reading '#{Interp.safe_key(key)}')"
          )

      # (`Interp.prop_key/1` inline: a string key does not pay one more call)
      key = if is_number(key), do: key, else: Interp.to_key(key)
      old = Interp.get(ov, key)
      v = Interp.binop(base, old, av(vo, env))

      if(strict?, do: Interp.strict_put(ov, key, v), else: Interp.put(ov, key, v)) && v
    end
  end

  # `++x` and `x--` to a slot, as `ev/2` does them: the read with its test of the temporal
  # dead zone, the number, then the write with `slot_put/3`. A float needs no conversion,
  # and its step is the float clause of `Interp.bump/2` (`Num.sub(x, 1.0)` is
  # `Num.add(x, -1.0)`).
  defp update_slot(op, prefix?, d, i, name) do
    form = {:slot, 0, i, name}
    delta = if op == "++", do: 1.0, else: -1.0

    fn env ->
      frame = up(env, d)

      {old, new} =
        case slot0(frame, i, name, form) do
          x when is_float(x) ->
            {x, Num.add(x, delta)}

          x ->
            old = Interp.numeric(x)
            {old, Interp.bump(op, old)}
        end

      Interp.slot_put(frame, i, new)
      if prefix?, do: new, else: old
    end
  end

  # `++o.name` and `o.name--` with a constant key that is not an array index (fast path
  # `:compound`), through the inline caches of two sites, as `compound_member/5` does it.
  defp update_member(op, prefix?, strict?, oo, {:k, s} = ko) when is_binary(s) do
    if Fast.on?(:compound) and named?(s) do
      {rsite, wsite} = {site(), site()}

      fn env ->
        ov = av(oo, env)

        if Interp.nullish?(ov),
          do: Interp.throw_error("TypeError", "Cannot read properties of #{Interp.to_str(ov)}")

        old = Interp.numeric(Interp.get_ic(ov, s, rsite))
        new = Interp.bump(op, old)

        if strict?,
          do: Interp.strict_put_ic(ov, s, new, wsite),
          else: Interp.put_ic(ov, s, new, wsite)

        if prefix?, do: new, else: old
      end
    else
      update_computed(op, prefix?, strict?, oo, ko)
    end
  end

  defp update_member(op, prefix?, strict?, oo, ko),
    do: update_computed(op, prefix?, strict?, oo, ko)

  # `++o[k]` and `o[k]--`, as `ev/2` does them: the object, the key, the test of a nullish
  # object, the key conversion (as `Interp.prop_key/1` does it), the read, the number, then
  # the write.
  defp update_computed(op, prefix?, strict?, oo, ko) do
    fn env ->
      ov = av(oo, env)
      raw = av(ko, env)

      if Interp.nullish?(ov),
        do: Interp.throw_error("TypeError", "Cannot read properties of #{Interp.to_str(ov)}")

      key = if is_number(raw), do: raw, else: Interp.to_key(raw)
      old = Interp.numeric(Interp.get(ov, key))
      new = Interp.bump(op, old)
      if strict?, do: Interp.strict_put(ov, key, new), else: Interp.put(ov, key, new)
      if prefix?, do: new, else: old
    end
  end

  # ── calls ──────────────────────────────────────────────────

  # The callee of a call, as `call_target/2` finds it: `{:member, object, key, optional?}`
  # for a method call, whose `this` is the object, or `{:plain, callee}`, as operand forms.
  # A callee that `call_target/2` reads by name, a `super` callee and an optional chain
  # stay on the tree.
  defp target({:member, o, k, mopt}) when elem(k, 0) != :priv,
    do: {:ok, {:member, opnd(o), method_key(k), mopt}}

  defp target({k, _}) when k in [:id, :super_member, :chain], do: :error
  defp target({:member, _, _, _}), do: :error
  defp target({:super}), do: :error
  defp target(callee), do: {:ok, {:plain, opnd(callee)}}

  # The key of a method call: `{:named, key, site}` for a named key (see `named?/1`), whose
  # read goes through the inline cache of the site, or an operand form.
  defp method_key({:str, s} = k),
    do: if(named?(s), do: {:named, s, site()}, else: key_code(k))

  defp method_key(k), do: key_code(k)

  # The read of the method of a call from the object `ov`, with the key form of
  # `method_key/1`. The test of the form is one `case` on a term of the closure, so it
  # costs no call.
  defmacrop method(ov, ko, env) do
    quote do
      case unquote(ko) do
        {:named, method_s, method_site} -> Interp.get_ic(unquote(ov), method_s, method_site)
        method_k -> Interp.get(unquote(ov), av(method_k, unquote(env)))
      end
    end
  end

  # A call, in the order of `ev/2`: the callee and `this`, the test of an optional call,
  # the arguments, then `Interp.ccall/5`, which the tree walker also uses.
  defp call({:member, oo, ko, mopt}, al, opt, callee) do
    fn env ->
      ov = av(oo, env)
      if mopt and Interp.nullish?(ov), do: throw(:js_short)
      f = method(ov, ko, env)
      if opt and Interp.nullish?(f), do: throw(:js_short)
      argv = argv(al, env)
      Interp.ccall(f, ov, argv, callee, env)
    end
  end

  defp call({:plain, fo}, al, opt, callee) do
    fn env ->
      f = av(fo, env)
      if opt and Interp.nullish?(f), do: throw(:js_short)
      argv = argv(al, env)
      Interp.ccall(f, :undefined, argv, callee, env)
    end
  end

  # An argument list, as a form that its parent reads inline with `argv/2`: up to three
  # operand forms, `{:n, forms}` for a longer list, or `{:list, children}` for a list with
  # a spread or a hole, which `Interp.eval_list/2` evaluates with compiled children, so
  # that the spread iterates as on the tree.
  defp list_code(args) do
    if plain_list?(args) do
      case Enum.map(args, &opnd/1) do
        os when length(os) <= 3 -> List.to_tuple([:a | os])
        os -> {:n, os}
      end
    else
      {:list, Enum.map(args, &carg/1)}
    end
  end

  defp values([], _env), do: []

  defp values([o | os], env) do
    v = av(o, env)
    [v | values(os, env)]
  end

  # ── statements ─────────────────────────────────────────────

  # A statement list, as a chain of closures that is built from the end. Each link runs
  # one statement. A statement that completes normally (`:ok`) goes on to the rest of the
  # list, with a tail call, so a long body uses no stack. Any other completion ends the
  # list, as in `fbody/2`. A position goes into the link of the statement that follows it,
  # as a write of `:js_pos` before the statement. A function declaration and an empty
  # statement do nothing when they run (the scope hoists the functions at its entry), so
  # they get no link. Each statement of a list runs without labels, as in `fbody/2`.
  defp list(stmts) do
    stmts
    |> Enum.reject(&(match?({:fundecl, _, _}, &1) or &1 == {:empty}))
    |> Enum.reverse()
    |> chain(nil)
  end

  # The list is reversed: the head is the last statement. `rest` is the link of the
  # statements after the head, or `nil` at the end of the list.
  defp chain([], nil), do: fn _env -> :ok end
  defp chain([], rest), do: rest

  defp chain([{:pos, loc} | before], rest), do: chain(before, at(loc, rest))

  defp chain([s, {:pos, loc} | before], rest), do: chain(before, link(loc, s, rest))
  defp chain([s | before], rest), do: chain(before, link(nil, s, rest))

  # A position with no statement after it (the end of a body).
  defp at(loc, nil) do
    fn _env ->
      :erlang.put(:js_pos, loc)
      :ok
    end
  end

  defp at(loc, rest) do
    fn env ->
      :erlang.put(:js_pos, loc)
      rest.(env)
    end
  end

  # S2: in check mode a statement must complete with one of the five shapes of step 3, as
  # in `fbody/2`.
  defmacrop done(c, s) do
    quote do
      c = unquote(c)
      if @check and c != :ok, do: Interp.check_completion(c, unquote(s))
      c
    end
  end

  defp link(loc, s, rest), do: link(loc, s, stmt(s, []), rest)

  # The last statement of a list without a position is its own link, but not in check
  # mode, where each statement passes the completion check.
  if @check do
    defp link(nil, s, sc, nil), do: fn env -> done(sc.(env), s) end
  else
    defp link(nil, _s, sc, nil), do: sc
  end

  defp link(loc, s, sc, nil) do
    fn env ->
      :erlang.put(:js_pos, loc)
      done(sc.(env), s)
    end
  end

  defp link(nil, s, sc, rest) do
    fn env ->
      case done(sc.(env), s) do
        :ok -> rest.(env)
        c -> c
      end
    end
  end

  defp link(loc, s, sc, rest) do
    fn env ->
      :erlang.put(:js_pos, loc)

      case done(sc.(env), s) do
        :ok -> rest.(env)
        c -> c
      end
    end
  end

  # The closure of the statement `s`: `fn env -> completion end`. `labels` are the labels
  # of the statement, as `fstmt/3` gets them. Each node counts for the memory bound (see
  # `count/0`).
  defp stmt(s, labels) do
    count()
    stmt_node(s, labels)
  end

  defp stmt_node({:expr, e}, _labels) do
    ec = expr(e)

    fn env ->
      ec.(env)
      :ok
    end
  end

  defp stmt_node({:return, nil}, _labels), do: fn _env -> {:ret, :undefined} end

  defp stmt_node({:return, e, :plain}, _labels), do: ret(opnd(e))

  defp stmt_node({:return, e, :tail}, _labels), do: tail(e)

  # (the branches of an `if` run without labels, as in `fstmt/3`)
  defp stmt_node({:if, c, a, b}, _labels), do: cbranch(c, stmt(a, []), b && stmt(b, []))

  defp stmt_node({:block, stmts, sc}, _labels) when frameless(sc) do
    bc = list(stmts)
    enter(sc, bc)
  end

  defp stmt_node({:var, kind, decls}, labels) do
    if Enum.all?(decls, &slot_decl?/1) do
      # (a `var` without a value does nothing, as in `exec/3`)
      ds =
        for {{:slot, d, i, name}, init} <- decls,
            not (init == nil and kind == :var),
            do: {d, i, name, if(init, do: opnd(init), else: {:k, :undefined})}

      fn env ->
        decls(ds, env)
        :ok
      end
    else
      # (an initializer that takes a name keeps its node: `ev_named/3` names it after the
      # pattern)
      decls =
        for {pat, init} <- decls,
            do: {pat, if(init == nil or nameable(init), do: init, else: cc(init))}

      shell_stmt({:var, kind, decls}, labels)
    end
  end

  defp stmt_node({:for, init, test, update, body, sc}, labels)
       when frameless(sc) and (init == nil or elem(init, 0) in [:var, :expr]) do
    # (the head runs as `exec/3` runs it: a declaration as a statement, an expression for
    # its value)
    ic =
      case init do
        {:var, _, _} = d -> stmt(d, [])
        {:expr, e} -> expr(e)
        nil -> nil
      end

    {tc, uc, bc} = {test && ctest(test), update && expr(update), stmt(body, [])}

    lc =
      fn env ->
        if ic, do: ic.(env)
        for_loop(tc, uc, bc, env, labels)
      end

    enter(sc, lc)
  end

  defp stmt_node({:while, c, body}, labels) do
    {tc, bc} = {ctest(c), stmt(body, [])}
    fn env -> while_loop(tc, bc, env, labels) end
  end

  # A break to this label ends the labeled statement normally, as in `fstmt/3`.
  defp stmt_node({:labeled, l, s}, labels) do
    sc = stmt(s, [l | labels])

    fn env ->
      case sc.(env) do
        {:brk, ^l} -> :ok
        c -> c
      end
    end
  end

  defp stmt_node({:break, l}, _labels) do
    c = {:brk, l}
    fn _env -> c end
  end

  defp stmt_node({:continue, l}, _labels) do
    c = {:cont, l}
    fn _env -> c end
  end

  defp stmt_node({:throw, e}, _labels) do
    ec = expr(e)

    fn env ->
      v = ec.(env)
      # (as `exec/3`: a thrown value that is no error object has no stack to say where it
      # was thrown)
      :erlang.put(:js_throw_pos, :erlang.get(:js_pos))
      throw({:js_error, v})
    end
  end

  # The statements below stay on the tree with compiled children, so that the order of
  # `try`/`finally`, the closing of iterators, the copies of a loop scope for each round
  # and the block frames keep one implementation, in `Interp`.
  defp stmt_node({:switch, disc, cases, sc}, labels) do
    cases =
      for {t, body} <- cases,
          do: {if(t == :default, do: :default, else: cc(t)), [{:cc, list(body)}]}

    shell_stmt({:switch, cc(disc), cases, sc}, labels)
  end

  defp stmt_node({:try, block, param, handler, finalizer, sc}, labels) do
    node = {:try, cs(block), param, handler && cs(handler), finalizer && cs(finalizer), sc}
    shell_stmt(node, labels)
  end

  defp stmt_node({kind, decl, pat, obj, body, sc}, labels) when kind in [:forin, :forof],
    do: shell_stmt({kind, decl, pat, cc(obj), cs(body), sc}, labels)

  defp stmt_node({:dowhile, body, c}, labels), do: shell_stmt({:dowhile, cs(body), cc(c)}, labels)

  defp stmt_node({:block, stmts, sc}, labels),
    do: shell_stmt({:block, [{:cc, list(stmts)}], sc}, labels)

  # (a framed `for` matches the shape of its head: a declaration runs as an expression
  # child that gives `:ok`, which the loop drops)
  defp stmt_node({:for, init, test, update, body, sc}, labels)
       when init == nil or elem(init, 0) in [:var, :expr] do
    init =
      case init do
        {:var, _, _} = d -> {:expr, cs(d)}
        {:expr, e} -> {:expr, cc(e)}
        nil -> nil
      end

    shell_stmt({:for, init, test && cc(test), update && cc(update), cs(body), sc}, labels)
  end

  defp stmt_node(node, labels), do: fallback_stmt(node, labels)

  # The entry of a frameless scope: `enter_frameless/2` resets the temporal dead zone of
  # its names and makes its functions. A scope with neither needs no call.
  defp enter(nil, c), do: c
  defp enter(%{tdz: [], hoist: []}, c), do: c

  defp enter(sc, c) do
    fn env ->
      Interp.enter_frameless(env, sc)
      c.(env)
    end
  end

  # A declaration whose pattern is a slot and whose value takes no name.
  defp slot_decl?({{:slot, _, _, _}, init}), do: init == nil or not nameable(init)
  defp slot_decl?(_), do: false

  # The declarations of a `var`, `let` or `const`, from left to right, as `bind/4` writes
  # them: the value, then the write with the checks of check mode.
  defp decls([], _env), do: :ok

  defp decls([{d, i, name, io} | rest], env) do
    v = av(io, env)
    frame = up(env, d)
    if @check, do: Interp.check_slot(frame, i, name)
    if @check, do: Interp.check_unsynced(frame, i)
    Interp.slot_put(frame, i, v)
    decls(rest, env)
  end

  # S2: a completion that leaves a loop, with the K7 test of check mode.
  defmacrop leave(c) do
    quote do
      c = unquote(c)
      if @check, do: Interp.loop_exit(c), else: c
    end
  end

  # The rounds of a frameless `for`, as `frame_for_loop/5` and `run_body/4` run them: a
  # step, the test, the body, then the update. A continue to this loop runs the update,
  # and a break to it ends the loop. A missing test is true.
  defp for_loop(tc, uc, bc, env, labels) do
    Interp.tick()

    if tc == nil or tc.(env) do
      case bc.(env) do
        :ok ->
          if uc, do: uc.(env)
          for_loop(tc, uc, bc, env, labels)

        {:cont, l} = c ->
          if l == nil or l in labels do
            if uc, do: uc.(env)
            for_loop(tc, uc, bc, env, labels)
          else
            leave(c)
          end

        {:brk, l} = c ->
          if l == nil or l in labels, do: :ok, else: leave(c)

        c ->
          leave(c)
      end
    else
      :ok
    end
  end

  # The rounds of a `while`, as `while_loop/5` and `run_body/4` run them: the test, a step,
  # then the body.
  defp while_loop(tc, bc, env, labels) do
    if tc.(env) do
      Interp.tick()

      case bc.(env) do
        :ok ->
          while_loop(tc, bc, env, labels)

        {:cont, l} = c ->
          if l == nil or l in labels, do: while_loop(tc, bc, env, labels), else: leave(c)

        {:brk, l} = c ->
          if l == nil or l in labels, do: :ok, else: leave(c)

        c ->
          leave(c)
      end
    else
      :ok
    end
  end

  # ── tail sites ─────────────────────────────────────────────

  # The completion of `return e` at a tail site, as `tail_value/2` gives it. A call gives
  # the pending call `{:tail, f, this, args}`, which the frame of the caller makes. A call
  # of a name (which can be `eval`), a `super` call and an optional chain stay on the tree,
  # and so do a comma expression and a logical operator.
  defp tail({:call, callee, args, false} = e) do
    case target(callee) do
      {:ok, target} -> tail_call(target, list_code(args), callee)
      :error -> fallback_tail(e)
    end
  end

  defp tail({:cond, c, a, b}), do: cbranch(c, tail(a), tail(b))

  defp tail({:seq, _} = e), do: fallback_tail(e)
  defp tail({:logical, _, _, _} = e), do: fallback_tail(e)

  defp tail(e), do: ret(opnd(e))

  # The completion `{:ret, value}`. A constant gives the same completion at each run, so
  # the completion is made once.
  defp ret({:k, v}) do
    c = {:ret, v}
    fn _env -> c end
  end

  defp ret(o), do: one(env, o, v, {:ret, v})

  # (the test of the callee comes here, inside the frame of the caller, as in
  # `tail_value/2`)
  defp tail_call({:member, oo, ko, mopt}, al, callee) do
    fn env ->
      ov = av(oo, env)
      if mopt and Interp.nullish?(ov), do: throw(:js_short)
      f = method(ov, ko, env)
      argv = argv(al, env)

      unless Interp.callable?(f),
        do: Interp.throw_error("TypeError", "#{Interp.describe_node(callee)} is not a function")

      {:tail, f, ov, argv}
    end
  end

  defp tail_call({:plain, fo}, al, callee) do
    fn env ->
      f = av(fo, env)
      argv = argv(al, env)

      unless Interp.callable?(f),
        do: Interp.throw_error("TypeError", "#{Interp.describe_node(callee)} is not a function")

      {:tail, f, :undefined, argv}
    end
  end

  # ── CPS plans (step 5c) ────────────────────────────────────

  # The value of the sync closure `f` in `env`, or the value that it throws. The continuation
  # runs after the `try`, as in `Async.sync_expr/4`, so that the rest of the body does not
  # run inside it.
  defmacrop sync_value(f, env) do
    quote do
      try do
        {:ok, unquote(f).(unquote(env))}
      catch
        {:js_error, sync_e} -> {:throw, sync_e}
      end
    end
  end

  # The plan of an async or generator body: `{plan, nil}`. An arrow with an expression body
  # gives the value of the expression to `k`. Any other body runs its statement list and
  # then calls `k`.
  defp cps_code(%{mode: :arrow_expr, body: e}), do: {kentry(kfun(kexpr(e))), nil}
  defp cps_code(%{body: stmts}), do: {kentry(klist(stmts)), nil}

  # S1 of check mode, for a plan.
  if @check do
    defp kentry(f) do
      fn env, ctx, k ->
        unless is_tuple(:erlang.get(env)),
          do: raise(ArgumentError, "resolve check: a compiled plan runs on #{inspect(env)}")

        f.(env, ctx, k)
      end
    end
  else
    defp kentry(f), do: f
  end

  # The closure `fn env, ctx, k -> ... end` of a compiled expression, which gives the value
  # to `k`.
  defp kfun({:c, f}), do: f

  defp kfun({:s, f}) do
    fn env, ctx, k ->
      case sync_value(f, env) do
        {:ok, v} -> k.(v)
        {:throw, e} -> ctx.throw.(e)
      end
    end
  end

  # A statement list of a plan (the twin of `Async.clist/4`). The list splits at each
  # statement that can suspend, which is a statement with the mark `{:aw}`. Each run of statements
  # between these runs as one compiled list of the sync compiler, under one `try`. The plan
  # is a chain that is built from the end, as in `list/1`.
  defp klist(stmts) do
    stmts
    |> Enum.reject(&(match?({:fundecl, _, _}, &1) or &1 == {:empty}))
    |> segments([], [])
    |> kchain(nil)
  end

  # The segments of a list, in reverse order: `{:run, stmts}` for a run of sync statements
  # and `{:one, stmt}` for a statement that can suspend.
  defp segments([], [], acc), do: acc
  defp segments([], run, acc), do: [{:run, Enum.reverse(run)} | acc]

  defp segments([s | rest], run, acc) do
    if suspends?(s) do
      acc = if run == [], do: acc, else: [{:run, Enum.reverse(run)} | acc]
      segments(rest, [], [{:one, s} | acc])
    else
      segments(rest, [s | run], acc)
    end
  end

  defp suspends?({:aw, _}), do: true
  defp suspends?(_), do: false

  # The segments are reversed: the head is the last segment. `rest` is the plan of the
  # segments after the head, or `nil` at the end of the list.
  defp kchain([], nil), do: fn _env, _ctx, k -> k.(:ok) end
  defp kchain([], rest), do: rest
  defp kchain([seg | before], rest), do: kchain(before, kseg(seg, rest))

  # A run of positions only (the position of a statement that suspends) writes `:js_pos`,
  # which can not throw.
  defp kseg({:run, ss}, rest) do
    case positions(ss) do
      {:ok, loc} -> kpos(loc, rest)
      :error -> krun(list(ss), rest)
    end
  end

  defp kseg({:one, s}, nil), do: kstmt(s, [])

  defp kseg({:one, s}, rest) do
    a = kstmt(s, [])
    fn env, ctx, k -> Async.then(a, rest, env, ctx, k) end
  end

  # The last position of a run that has only positions.
  defp positions([{:pos, loc}]), do: {:ok, loc}
  defp positions([{:pos, _} | rest]), do: positions(rest)
  defp positions(_), do: :error

  defp kpos(loc, nil) do
    fn _env, _ctx, k ->
      :erlang.put(:js_pos, loc)
      k.(:ok)
    end
  end

  defp kpos(loc, rest) do
    fn env, ctx, k ->
      :erlang.put(:js_pos, loc)
      rest.(env, ctx, k)
    end
  end

  # A run of sync statements, as `Async.sync_stmt/5` runs each of them: a completion that
  # is not `:ok` goes to the context, and `:ok` goes on to the rest.
  defp krun(sc, nil), do: fn env, ctx, k -> Async.abrupt(Async.run_stmt(sc, env), ctx, k) end

  defp krun(sc, rest) do
    fn env, ctx, k ->
      case Async.run_stmt(sc, env) do
        :ok -> rest.(env, ctx, k)
        c -> Async.abrupt(c, ctx, k)
      end
    end
  end

  # A statement of a plan (the twin of `Async.cexec/5` in frame mode). `labels` are the
  # labels of the statement. Each node counts for the memory bound.
  defp kstmt(s, labels) do
    count()
    kstmt_node(s, labels)
  end

  defp kstmt_node({:aw, s}, labels) do
    if @check and not Awaits.any?(s),
      do: raise(ArgumentError, "resolve check: {:aw} on #{elem(s, 0)}, which does not await")

    kaw(s, labels)
  end

  defp kstmt_node(s, labels) do
    if @check and Awaits.any?(s),
      do: raise(ArgumentError, "resolve check: no {:aw} on #{elem(s, 0)}, which awaits")

    krun(stmt(s, labels), nil)
  end

  # A statement that awaits (the twin of `Async.cs/5` in frame mode).
  defp kaw({:expr, e}, _labels), do: kfun(kexpr(e))

  defp kaw({:var, kind, decls}, _labels) when kind in [:var, :let, :const] do
    parts = for {pat, init} <- decls, do: {pat, kinit(pat, init), Awaits.any?(pat)}
    fn env, ctx, k -> Async.decls(parts, kind, env, ctx, k) end
  end

  defp kaw({:return, e, :plain}, _labels), do: kto(kexpr(e), :ret)
  defp kaw({:return, e}, _labels) when e != nil, do: kto(kexpr(e), :ret)
  defp kaw({:throw, e}, _labels), do: kto(kexpr(e), :throw)

  defp kaw({:if, c, a, b}, _labels) do
    ka = kstmt(a, [])
    kb = b && kstmt(b, [])

    case ktest(c) do
      {:t, t} ->
        fn env, ctx, k ->
          case sync_value(t, env) do
            {:ok, true} -> ka.(env, ctx, k)
            {:ok, false} -> if kb, do: kb.(env, ctx, k), else: k.(:ok)
            {:throw, e} -> ctx.throw.(e)
          end
        end

      {:c, f} ->
        fn env, ctx, k -> Async.if_cps(f, ka, kb, env, ctx, k) end
    end
  end

  defp kaw({:block, stmts, sc}, _labels) do
    kl = klist(stmts)

    case kscope(sc) do
      nil ->
        kl

      sc ->
        fn env, ctx, k ->
          entered =
            try do
              {:ok, Interp.cps_enter(env, sc)}
            catch
              {:js_error, e} -> {:throw, e}
            end

          case entered do
            {:ok, b} -> kl.(b, ctx, k)
            {:throw, e} -> ctx.throw.(e)
          end
        end
    end
  end

  defp kaw({:labeled, l, s}, labels) do
    ks = kstmt(s, [l | labels])
    fn env, ctx, k -> ks.(env, %{ctx | brk: Map.put(ctx.brk, l, k)}, k) end
  end

  defp kaw({:while, c, body}, labels) do
    t = ktest(c)
    b = kstmt(body, [])
    fn env, ctx, k -> Async.while_k(t, b, env, ctx, k, labels) end
  end

  defp kaw({:dowhile, body, c}, labels) do
    b = kstmt(body, [])
    t = ktest(c)
    fn env, ctx, k -> Async.dowhile_k(t, b, env, ctx, k, labels) end
  end

  # The init is never marked `{:aw}`, so the compiler tests it, as `Async.cs/5` does when
  # it runs.
  defp kaw({:for, init, test, update, body, sc}, labels) do
    init =
      case init do
        nil -> nil
        {:var, _, _} = d -> if Awaits.any?(d), do: {:c, kaw(d, [])}, else: {:stmt, stmt(d, [])}
        {:expr, e} -> kexpr(e)
      end

    t = test && ktest(test)
    u = update && kexpr(update)
    b = kstmt(body, [])
    spec = {init, t, u, b, kscope(sc), match?(%{per_iter: true}, sc)}
    fn env, ctx, k -> Async.for_k(spec, env, ctx, k, labels) end
  end

  # A `switch` that awaits (the twin of the frame clause of `Async.cs/5`). The tests run in
  # order until one is equal to the value. Then the bodies run from that case to the end.
  # Each case body is a plan of its own, so that the code stays linear in the size of the
  # switch, and `Async.switch_k/4` runs the bodies one after the other.
  defp kaw({:switch, disc, cases, sc}, _labels) do
    x = kexpr(disc)
    tests = for {t, _} <- cases, do: if(t == :default, do: :default, else: kexpr(t))
    bodies = for {_, b} <- cases, do: klist(b)
    default = Enum.find_index(cases, fn {t, _} -> t == :default end)
    spec = {x, tests, bodies, default, kscope(sc)}
    fn env, ctx, k -> Async.switch_k(spec, env, ctx, k) end
  end

  # Every other statement that awaits stays on the tree path.
  defp kaw(s, labels),
    do: trace(:cps_stmt, s, fn env, ctx, k -> Async.tree_stmt(s, env, ctx, k, labels) end)

  # An anonymous function or class takes the name of its binding through
  # `Async.named_value/5`, on the tree.
  defp kinit(_pat, nil), do: nil

  defp kinit(pat, init) when nameable(init),
    do: {:c, trace(:cps, init, fn env, ctx, k -> Async.named_value(init, pat, env, ctx, k) end)}

  defp kinit(_pat, init), do: kexpr(init)

  # The scope that a statement enters with `Interp.cps_enter/2`, or `nil` when the entry
  # has no work: a frameless scope with no name in its temporal dead zone and no function.
  defp kscope(nil), do: nil
  defp kscope(%{frame: false, tdz: [], hoist: []}), do: nil
  defp kscope(sc), do: sc

  # A `return` or a `throw` that awaits: the value goes to `ctx.ret` or `ctx.throw`.
  defp kto({:c, f}, :ret), do: fn env, ctx, _k -> f.(env, ctx, ctx.ret) end
  defp kto({:c, f}, :throw), do: fn env, ctx, _k -> f.(env, ctx, ctx.throw) end
  defp kto(x, :ret), do: fn env, ctx, _k -> Async.value(x, env, ctx, ctx.ret) end
  defp kto(x, :throw), do: fn env, ctx, _k -> Async.value(x, env, ctx, ctx.throw) end

  # A test: `{:t, closure}` with an Elixir boolean when it does not await, else
  # `{:c, closure}`.
  defp ktest(c) do
    if Awaits.any?(c), do: kexpr(c), else: {:t, ctest(c)}
  end

  # An expression of a plan (the twin of `Async.cev/4`): `{:s, closure}` when it does not
  # await, else `{:c, closure}`.
  defp kexpr(e) do
    if Awaits.any?(e) do
      count()
      kexpr_aw(e)
    else
      {:s, expr(e)}
    end
  end

  # An expression that awaits (the twin of `Async.cev_await/4` in frame mode).
  defp kexpr_aw({:await, x}) do
    case kexpr(x) do
      {:s, f} ->
        {:c,
         fn env, ctx, k ->
           case sync_value(f, env) do
             {:ok, v} -> Async.await_value(v, ctx, k)
             {:throw, e} -> ctx.throw.(e)
           end
         end}

      {:c, f} ->
        {:c, fn env, ctx, k -> Async.await_cps(f, env, ctx, k) end}
    end
  end

  defp kexpr_aw({:yield, x, false}) do
    case kexpr(x) do
      {:s, f} ->
        {:c,
         fn env, ctx, k ->
           case sync_value(f, env) do
             {:ok, v} -> Async.yield_value(v, ctx, k)
             {:throw, e} -> ctx.throw.(e)
           end
         end}

      {:c, f} ->
        {:c, fn env, ctx, k -> Async.yield_cps(f, env, ctx, k) end}
    end
  end

  defp kexpr_aw({:logical, op, l, r}) do
    kr = kexpr(r)

    case kexpr(l) do
      {:s, f} ->
        {:c,
         fn env, ctx, k ->
           case sync_value(f, env) do
             {:ok, lv} -> Async.logical_rest(op, lv, kr, env, ctx, k)
             {:throw, e} -> ctx.throw.(e)
           end
         end}

      {:c, f} ->
        {:c, fn env, ctx, k -> Async.logical_cps(op, f, kr, env, ctx, k) end}
    end
  end

  defp kexpr_aw({:cond, c, a, b}) do
    ka = kexpr(a)
    kb = kexpr(b)

    case ktest(c) do
      {:t, t} ->
        {:c,
         fn env, ctx, k ->
           case sync_value(t, env) do
             {:ok, true} -> Async.value(ka, env, ctx, k)
             {:ok, false} -> Async.value(kb, env, ctx, k)
             {:throw, e} -> ctx.throw.(e)
           end
         end}

      {:c, f} ->
        {:c, fn env, ctx, k -> Async.cond_cps(f, ka, kb, env, ctx, k) end}
    end
  end

  defp kexpr_aw({:destructure, pat, right}) do
    x = kexpr(right)
    {:c, fn env, ctx, k -> Async.destructure(x, pat, env, ctx, k) end}
  end

  # `yield*`, an optional chain and a logical assignment stay on the tree path: `yield*`
  # runs through `delegate` and `adelegate`, the chain puts its value into the tree, and
  # the logical assignment runs its right side only when it does not short-circuit.
  defp kexpr_aw({:yield, _, true} = e), do: ktree(e)
  defp kexpr_aw({:chain, _} = e), do: ktree(e)

  defp kexpr_aw({kind, op, _, _} = e)
       when kind in [:assign, :sassign] and op in ["&&=", "||=", "??="],
       do: ktree(e)

  # Any other expression gets its lift plan. A leaf from a class must run in a class scope,
  # which the tree path makes, so such a plan stays on the tree path.
  defp kexpr_aw(e) do
    {template, leaves} = Async.lift_plan(e)

    if Enum.any?(leaves, &match?({:cps_class, _, _}, &1)) do
      ktree(e)
    else
      kleaves = Enum.map(leaves, &kexpr/1)
      t = expr(template)
      {:c, fn env, ctx, k -> Async.lifted(kleaves, t, env, ctx, k) end}
    end
  end

  defp ktree(e), do: {:c, trace(:cps, e, fn env, ctx, k -> Async.tree_expr(e, env, ctx, k) end)}

  # ── nodes on the tree ──────────────────────────────────────

  # A node that does not compile. Its closure keeps the node and gives it to the tree
  # walker, which runs it and every node in it.
  defp fallback(node), do: trace(:ev, node, fn env -> Interp.ev(node, env) end)

  defp fallback_stmt(node, labels),
    do: trace(:fstmt, node, fn env -> Interp.fstmt(node, env, labels) end)

  defp fallback_tail(node), do: trace(:tail, node, fn env -> Interp.tail_value(node, env) end)

  # A node that stays on the tree with compiled children (a shell). Its closure gives the
  # shell to the tree walker, which runs the children through the `{:cc, fun}` clauses of
  # `ev/2`, `exec/3` and `fstmt/3`.
  defp shell(node) do
    check_shell(node)
    trace(:shell, node, fn env -> Interp.ev(node, env) end)
  end

  defp shell_stmt(node, labels) do
    check_shell(node)
    trace(:shell, node, fn env -> Interp.fstmt(node, env, labels) end)
  end

  # The compiled children of a shell. A child is `{:cc, closure}`. `ev/2`, `exec/3` and
  # `fstmt/3` run it, as they run the node that it replaces.
  #
  # A constant and a slot read keep their nodes: the tree walker reads them with one call
  # of `ev/2`, and a compiled child would cost one more call.
  defp cc({k, _} = e) when k in [:num, :str, :lit], do: e
  defp cc({:slot, _, _, _} = e), do: e
  defp cc(e), do: {:cc, expr(e)}
  defp cs(s), do: {:cc, stmt(s, [])}

  # An item of an argument list or an array literal.
  defp carg(:hole), do: :hole
  defp carg({:spread, e}), do: {:spread, cc(e)}
  defp carg(e), do: cc(e)

  # A property of an object literal. A value that takes a name (a function or a class
  # without a name, or a method) keeps its node, because `ev/2` reads its shape. Getters
  # and setters are functions, which the heap keeps, so they keep their nodes too.
  defp cprop({:init, key, v}) do
    v = if nameable(v) or method_node?(v), do: v, else: cc(v)
    {:init, ckey(key), v}
  end

  defp cprop({:proto, e}), do: {:proto, cc(e)}
  defp cprop({:spread, e}), do: {:spread, cc(e)}
  defp cprop({kind, key, fun}) when kind in [:getter, :setter], do: {kind, ckey(key), fun}

  defp ckey({:computed, e}), do: {:computed, cc(e)}
  defp ckey(k), do: k

  # A member node as the target of a write or of `delete`: the object and a computed key
  # are children. A constant key and a private name keep their shape.
  defp cmember({:member, o, k, opt}) do
    k = if elem(k, 0) in [:str, :priv], do: k, else: cc(k)
    {:member, cc(o), k, opt}
  end

  # The target of a compound or logical assignment on the tree: a member has compiled
  # children, and every other target keeps its node.
  defp ctarget({:member, _, _, _} = m), do: cmember(m)
  defp ctarget(t), do: t

  # S4: in check mode a compiled child may not be in a node that the heap keeps
  # (`make_fn/3`, `Classes.define/2`) or in the callee of a call, whose node names the
  # callee in an error (`describe/1`). The test runs once, when the shell is made.
  if @check do
    defp check_shell(node), do: shell_walk(node)

    defp shell_walk({k, _} = node) when k in [:gen, :async], do: no_cc(node)
    defp shell_walk({k, _, _, _, _} = node) when k == :class, do: no_cc(node)
    defp shell_walk({:fn, _, _, _, _, _} = node), do: no_cc(node)

    defp shell_walk({:call, callee, args, _}) do
      no_cc(callee)
      shell_walk(args)
    end

    defp shell_walk({:cc, f}) when is_function(f), do: :ok
    defp shell_walk(t) when is_tuple(t), do: shell_walk(Tuple.to_list(t))
    defp shell_walk(l) when is_list(l), do: Enum.each(l, &shell_walk/1)
    defp shell_walk(_), do: :ok

    defp no_cc(t) do
      if has_cc?(t),
        do: raise(ArgumentError, "resolve check: a compiled child in #{inspect(elem(t, 0))}")
    end

    defp has_cc?({:cc, f}) when is_function(f), do: true
    defp has_cc?(t) when is_tuple(t), do: has_cc?(Tuple.to_list(t))
    defp has_cc?(l) when is_list(l), do: Enum.any?(l, &has_cc?/1)
    defp has_cc?(_), do: false
  else
    defp check_shell(_node), do: :ok
  end

  # S5: in check mode the compiled code of a body may not keep a value of the run time (the
  # capture rule). The walk visits the values that each fun keeps, and the values in them.
  # An object, a `{:val}` node (a value that the tree walker put into a syntax node) and a
  # frame (a tuple with an `Info` as its second element) fail. A heap id is an integer, as
  # a slot number is, so the walk cannot see it; the differential oracle moves the heap ids
  # to find it. The walk runs once, when a body compiles.
  if @check do
    defp check_capture(t) do
      case t do
        f when is_function(f) ->
          {:env, env} = :erlang.fun_info(f, :env)
          Enum.each(env, &check_capture/1)

        {:obj, id} when is_integer(id) ->
          capture_fail(t)

        {:val, _} ->
          capture_fail(t)

        t when is_tuple(t) and tuple_size(t) >= 5 and is_struct(elem(t, 1), Info) ->
          capture_fail(t)

        t when is_tuple(t) ->
          check_capture(Tuple.to_list(t))

        [h | rest] ->
          check_capture(h)
          check_capture(rest)

        %Info{} ->
          :ok

        # (a struct is a map too, and `:maps.to_list/1` takes it)
        m when is_map(m) ->
          check_capture(:maps.to_list(m))

        _ ->
          :ok
      end
    end

    defp capture_fail(t),
      do: raise(ArgumentError, "resolve check: compiled code keeps #{inspect(t, limit: 5)}")
  else
    defp check_capture(_code), do: :ok
  end

  # The coverage test of the design (5.4) asks which nodes stay on the tree. When the
  # process key `:jsc_trace` holds a list, the compiler adds each such node to it. The test
  # costs one read of the process dictionary for each node that stays on the tree, and
  # only when a body compiles.
  defp trace(how, node, f) do
    case :erlang.get(:jsc_trace) do
      l when is_list(l) -> :erlang.put(:jsc_trace, [{how, node} | l])
      _ -> :ok
    end

    f
  end
end
