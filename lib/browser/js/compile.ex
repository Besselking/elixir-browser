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

  The resolver rewrites a function so that it runs on a slot frame. At the first call of
  such a function, this module changes the body of the function into Elixir closures. A
  closure takes the frame id and gives the value or the completion of the code that it
  replaces. The interpreter (`Browser.JS.Interp`) then calls the closures, and does not
  walk the syntax tree of the body again.

  ## Which nodes compile

  The node kinds that most programs use have closures of their own:

    * constants, slot reads, `this`, the reads of a name in the global scope or in a map
      scope (`{:gref}`, `{:mref}`);
    * `?:`, `&&`, `||`, `??`, the comma operator, templates, optional chains, the unary
      operators and the binary operators;
    * property reads, calls, `new`, array and object literals;
    * assignments, compound assignments, `++` and `--` to a slot or to a property;
    * the statements `expr`, `return`, `if`, `block`, `var`, `let`, `const`, `for`,
      `while`, labels, `break`, `continue` and `throw`.

  A parent reads an operand that is a constant or a slot of its own frame inline, without
  the call of a closure. A binary operator and a test have one closure for each kind of
  operand, so that the closure does no test of the kind when it runs. The tests of `if`,
  `?:`, `for` and `while` give an Elixir boolean: a comparison gives its value, and `!`,
  `&&` and `||` join the booleans of their operands. A comparison of operands goes into the
  closure of its branch.

  Some nodes stay on the tree walker, but their children compile (a shell). The compiler
  makes a copy of the node in which each expression or statement child is
  `{:cc, closure}`. `Interp.ev/2`, `exec/3` and `fstmt/3` run such a child with one call.
  These nodes are `switch`, `try`, `for-in`, `for-of`, `do-while`, a block or a `for`
  that makes a block frame, a declaration with a pattern, a literal with a spread or a
  method, a call with a callee that the tree reads by name, and some rare forms of
  assignment and `delete`. Because of this, the order of `try` and `finally`, the closing
  of iterators, the copies of a loop scope and the block frames have one implementation,
  in `Interp`. A shell keeps the nodes that the heap keeps (functions and classes) and the
  callee of a call (its node names the callee in an error) as they are.

  Every other node stays on the tree walker with all the nodes in it. Its closure gives
  the node to `Interp.ev/2`, `Interp.fstmt/3` or `Interp.tail_value/2`. These nodes are
  the functions and classes, the reads and writes of a name that the resolver did not put
  in a slot, the special forms of `typeof` and `delete`, `super`, `import`, regular
  expressions and the strings of a tagged template.

  A compiled node does the same steps in the same order as its clause in `Interp`. It
  calls the same helpers of `Interp` for the work that the two share: the frame of a call,
  the operators, the property reads and writes and the slot writes. Because of this, a
  compiled body and the tree walker give the same values, errors, steps and heap ids.

  ## Which functions compile

  A function compiles when all of these conditions are true:

    * the resolver rewrote the function (`Info.rewritten`);
    * the function is not async and not a generator;
    * the `Info` has a `uid`;
    * the switch `:js_compile` of the process is on.

  ## The switch

  The application setting `:js_compile` (default `true`, `JS_COMPILE=0` sets it to `false`)
  is the switch. `Browser.JS.Interp.init/1` copies it into the process dictionary. Because
  of this, each heap has its own value, and one VM can run the two modes.

  ## The cache

  The process dictionary keeps the compiled code of each function under the key
  `{:jsc, uid}`. The value is `{body, maker}`. `body` is the closure of the body. `maker`
  is the frame maker, which is `nil` in this version. Each function object keeps its code
  in its closure record (the `code` key), so that a call does not read the cache.

  ## Rules for the code

    * A compiled closure keeps only values that are known at compile time: slot numbers,
      names, constants, syntax nodes and other compiled closures. It never keeps a frame id
      or a heap id. Because of this, the collector (`Browser.JS.GC`) does not walk the
      cache or the funs of this module.
    * Each closure has one parent closure. Because of this, the size of the code is linear
      in the size of the body.
    * Compiled code makes no fun when it runs. A loop is a named function of this module,
      which gets the closures of the loop as arguments.
    * The code stays in its process. Do not send it in a message, and do not put it in ETS,
      in `persistent_term` or in `term_to_binary`.

  ## Check mode

  When the application has `:js_resolve_check`, compiled code does these checks:

    * a body runs only on a frame (S1);
    * each statement of a list completes with one of the shapes of step 3, and a loop
      gives back no break or continue of its own (S2);
    * a slot read or write calls the same checks as its twin on the tree, and a call
      checks the call chain (S3);
    * a shell has no compiled child in a function, in a class or in the callee of a call
      (S4);
    * the compiled code of a body keeps no object, no `{:val}` node and no frame (S5).

  When the process key `:jsc_trace` holds a list, the compiler adds to it each node that
  stays on the tree. The coverage test uses this list.
  """

  alias Browser.JS.Interp
  alias Browser.JS.Num
  alias Browser.JS.Resolve.Info

  # In check mode compiled code makes the checks of its twins on the tree. The attribute is
  # a constant, so a normal build has no test.
  @check Application.compile_env(:browser, :js_resolve_check, false)

  @doc """
  Gives the compiled body of the closure record `c`, or `nil` when the function does not
  compile. The first call for a function compiles the body and puts it in the cache.
  """
  @spec code(map) :: (integer -> term) | nil
  def code(%{info: %Info{rewritten: true, async?: false, generator?: false, uid: uid}} = c)
      when uid != nil do
    # (the switch is off when it was never set: a process that did not start its heap with
    # `Interp.init/1` runs on the tree walker)
    if :erlang.get(:js_compile) == true do
      case :erlang.get({:jsc, uid}) do
        {body, _maker} -> body
        :undefined -> compile_and_store(c, uid)
      end
    end
  end

  def code(_c), do: nil

  defp compile_and_store(c, uid) do
    body = body(c)
    check_capture(body)
    :erlang.put({:jsc, uid}, {body, nil})
    body
  end

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

  # The closure of the expression `e`: `fn env -> value end`.
  defp expr({:num, n}), do: fn _env -> n end
  defp expr({:str, s}), do: fn _env -> s end
  defp expr({:lit, v}), do: fn _env -> v end

  defp expr({:slot, 0, i, name} = form), do: fn env -> slot0(env, i, name, form) end

  defp expr({:slot, d, i, name}) do
    form = {:slot, 0, i, name}
    fn env -> slot0(up(env, d), i, name, form) end
  end

  defp expr({:this, d, i} = form) do
    fn env ->
      if @check, do: Interp.check_landing(form, env)

      case :erlang.element(i, :erlang.get(up(env, d))) do
        :uninit_this -> Interp.uninit_this_error()
        v -> v
      end
    end
  end

  defp expr({:gref, name} = form) do
    # (the by-name read of `ev_id/2` takes this node, so it is built once)
    id = {:id, name}

    fn env ->
      if @check, do: Interp.check_landing(form, env)
      Interp.ev_id(id, Interp.root(env))
    end
  end

  defp expr({:in_tdz, _names, e}), do: expr(e)

  defp expr({:cond, c, a, b}), do: cbranch(c, expr(a), expr(b))

  # (the right operand is read only when the left one does not give the value)
  defp expr({:logical, op, l, r}) do
    {lo, ro} = {opnd(l), opnd(r)}

    case op do
      "&&" -> one(env, lo, lv, if(tru(lv), do: av(ro, env), else: lv))
      "||" -> one(env, lo, lv, if(tru(lv), do: lv, else: av(ro, env)))
      "??" -> one(env, lo, lv, if(lv == :undefined or lv == :null, do: av(ro, env), else: lv))
    end
  end

  # (`!` has no special form in `ev/2`: its operand is a plain expression)
  defp expr({:unary, "!", _} = e), do: ctest(e)

  # (`#x in o` reads the private name in its own clause of `ev/2`)
  defp expr({:binary, "in", {:priv_ref, _} = l, r}), do: shell({:binary, "in", l, cc(r)})
  defp expr({:binary, op, l, r}), do: binary(op, opnd(l), opnd(r))

  defp expr({:member, o, k, opt}) do
    case k do
      {:priv, _} -> shell({:member, cc(o), k, opt})
      _ -> member(opnd(o), key_code(k), opt)
    end
  end

  defp expr({:call, callee, args, opt}) do
    case target(callee) do
      {:ok, target} -> call(target, list_code(args), opt, callee)
      # (the callee keeps its node: `call_target/2` reads its shape, and the text of an
      # error names it)
      :error -> shell({:call, callee, Enum.map(args, &carg/1), opt})
    end
  end

  defp expr({:new, callee, args}) do
    {cc, al} = {expr(callee), list_code(args)}

    fn env ->
      f = cc.(env)
      # (the arguments are evaluated before the callee is checked)
      argv = argv(al, env)

      unless Interp.function?(f) and Interp.constructor?(f),
        do:
          Interp.throw_error(
            "TypeError",
            "#{Interp.describe_node(callee)} is not a constructor"
          )

      if @check, do: Interp.check_link(env)
      Interp.construct(f, argv)
    end
  end

  defp expr({kind, "=", {:slot, d, i, name}, value} = node) when kind in [:assign, :sassign] do
    if nameable(value) do
      fallback(node)
    else
      one(env, opnd(value), v, assign_slot(env, d, i, name, v))
    end
  end

  defp expr({kind, "=", {:member, o, k, _} = target, value}) when kind in [:assign, :sassign] do
    case k do
      {:priv, _} -> shell({kind, "=", cmember(target), cc(value)})
      _ -> put(kind, opnd(o), key_code(k), opnd(value))
    end
  end

  # (a slot form that is not `{:slot}` writes through its own helper in `ev/2`, which
  # reads the value with `ev_named/3`)
  defp expr({kind, "=", {t, _, _, _} = target, value} = node)
       when kind in [:assign, :sassign] and t in [:cslot, :fname] do
    if nameable(value), do: fallback(node), else: shell({kind, "=", target, cc(value)})
  end

  defp expr({kind, "=", {t, _, _, _, _} = target, value} = node)
       when kind in [:assign, :sassign] and t == :mslot do
    if nameable(value), do: fallback(node), else: shell({kind, "=", target, cc(value)})
  end

  # A logical assignment (`&&=`, `||=`, `??=`) stays on the tree, which names a function
  # value through `ev_named/3`.
  defp expr({kind, op, target, value} = node)
       when kind in [:assign, :sassign] and op in ["&&=", "||=", "??="] do
    if nameable(value),
      do: fallback(node),
      else: shell({kind, op, ctarget(target), cc(value)})
  end

  defp expr({kind, op, target, value} = node)
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

  defp expr({kind, op, prefix?, target} = node) when kind in [:update, :supdate] do
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

  defp expr({:array, elems}) do
    if plain_list?(elems) do
      al = list_code(elems)
      # (`ev/2` evaluates the elements before it makes the array, as here)
      fn env -> Interp.new_array(argv(al, env)) end
    else
      shell({:array, Enum.map(elems, &carg/1)})
    end
  end

  defp expr({:object, props}) do
    if Enum.all?(props, &plain_prop?/1) do
      pcs = for {:init, {:str, k}, v} <- props, do: {k, opnd(v)}

      # (`ev/2` makes the object before it evaluates the values, as here)
      fn env ->
        obj = Interp.new_object()
        props(pcs, obj, env)
        obj
      end
    else
      shell({:object, Enum.map(props, &cprop/1)})
    end
  end

  defp expr({:seq, es}) do
    cs = Enum.map(es, &expr/1)
    fn env -> seq(cs, env) end
  end

  # (as `ev/2`: the special forms of `typeof` read a name that can be missing)
  defp expr({:unary, "typeof", {:slot, d, i, name} = form}) do
    fn env ->
      if @check, do: Interp.check_landing(form, env)

      case :erlang.element(i, :erlang.get(up(env, d))) do
        :tdz -> Interp.tdz_error(name)
        v -> Interp.typeof(v)
      end
    end
  end

  defp expr({:unary, "typeof", {k, _, _}} = node) when k in [:aslot, :mref], do: fallback(node)
  defp expr({:unary, "typeof", {k, _}} = node) when k in [:gref, :id], do: fallback(node)

  # (a constant operand gives the same value at each run, so the value is computed once)
  defp expr({:unary, "-", {:num, n}}) do
    v = Num.neg(n)
    fn _env -> v end
  end

  defp expr({:unary, "void", {:num, _}}), do: fn _env -> :undefined end

  defp expr({:unary, op, e}) when op in ["-", "+", "~", "typeof", "void"],
    do: unary(op, opnd(e))

  defp expr({:unary, d, {:member, _, _, _} = target}) when d in ["delete", "sdelete"],
    do: shell({:unary, d, cmember(target)})

  defp expr({:tmpl, parts}) do
    pcs = Enum.map(parts, fn p -> if is_binary(p), do: p, else: opnd(p) end)
    fn env -> parts(pcs, env, []) |> Browser.JS.Str.join() end
  end

  # (an optional member or call in the chain throws `:js_short`, as in `ev/2`)
  defp expr({:chain, e}) do
    ec = expr(e)

    fn env ->
      try do
        ec.(env)
      catch
        :js_short -> :undefined
      end
    end
  end

  defp expr({:mref, d, name} = form) do
    # (the by-name read of `ev_id/2` takes this node, so it is built once)
    id = {:id, name}

    fn env ->
      if @check, do: Interp.check_landing(form, env)
      Interp.ev_id(id, up(env, d))
    end
  end

  # (the marker only keeps a name from the value, see `ev_named/3`)
  defp expr({:unnamed, e}), do: expr(e)

  defp expr({:destructure, pat, right}), do: shell({:destructure, pat, cc(right)})

  defp expr(node), do: fallback(node)

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
  # them: the value, then the home of a method, then the property.
  defp props([], _obj, _env), do: :ok

  defp props([{k, vo} | rest], obj, env) do
    v = av(vo, env)
    Interp.method_home(v, obj)
    Interp.define_data(obj, k, v)
    props(rest, obj, env)
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

  # A property read, as `ev/2` reads `{:member, o, k, opt}`: the object, the test of an
  # optional member, then the key. A named key reads through `get_named/2`, which has the
  # class dispatch of `get/2`.
  defp member(oo, {:k, s}, false) do
    if named?(s),
      do: one(env, oo, ov, Interp.get_named(ov, s)),
      else: one(env, oo, ov, Interp.get(ov, s))
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
  # key writes through `put_named/3`, which has the class dispatch of `put/3`.
  defp put(:assign, oo, {:k, s}, vo) do
    if named?(s) do
      pair(env, oo, vo, ov, v, Interp.put_named(ov, s, v))
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
    if named?(s),
      do: pair(env, oo, vo, ov, v, Interp.strict_put_named(ov, s, v)),
      else: pair(env, oo, vo, ov, v, Interp.strict_put(ov, s, v))
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

  # `o[k] op= v`, as `compound_assign/5` does it: the object, the key, the test of a
  # nullish object, the key conversion (once, for the read and the write), the read, the
  # value, the operator, then the write.
  defp compound_member(base, strict?, oo, ko, vo) do
    fn env ->
      ov = av(oo, env)
      key = av(ko, env)

      if Interp.nullish?(ov),
        do:
          Interp.throw_error(
            "TypeError",
            "Cannot read properties of #{Interp.to_str(ov)} (reading '#{Interp.safe_key(key)}')"
          )

      key = Interp.to_key(key)
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

  # `++o[k]` and `o[k]--`, as `ev/2` does them: the object, the key, the test of a nullish
  # object, the key conversion, the read, the number, then the write.
  defp update_member(op, prefix?, strict?, oo, ko) do
    fn env ->
      ov = av(oo, env)
      raw = av(ko, env)

      if Interp.nullish?(ov),
        do: Interp.throw_error("TypeError", "Cannot read properties of #{Interp.to_str(ov)}")

      key = Interp.to_key(raw)
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

  # The key of a method call: `{:named, key}` for a named key (see `named?/1`), or an
  # operand form.
  defp method_key({:str, s} = k), do: if(named?(s), do: {:named, s}, else: key_code(k))
  defp method_key(k), do: key_code(k)

  # The read of the method of a call from the object `ov`, with the key form of
  # `method_key/1`. The test of the form is one `case` on a term of the closure, so it
  # costs no call.
  defmacrop method(ov, ko, env) do
    quote do
      case unquote(ko) do
        {:named, method_s} -> Interp.get_named(unquote(ov), method_s)
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
  # of the statement, as `fstmt/3` gets them.
  defp stmt({:expr, e}, _labels) do
    ec = expr(e)

    fn env ->
      ec.(env)
      :ok
    end
  end

  defp stmt({:return, nil}, _labels), do: fn _env -> {:ret, :undefined} end

  defp stmt({:return, e, :plain}, _labels), do: ret(opnd(e))

  defp stmt({:return, e, :tail}, _labels), do: tail(e)

  # (the branches of an `if` run without labels, as in `fstmt/3`)
  defp stmt({:if, c, a, b}, _labels), do: cbranch(c, stmt(a, []), b && stmt(b, []))

  defp stmt({:block, stmts, sc}, _labels) when frameless(sc) do
    bc = list(stmts)
    enter(sc, bc)
  end

  defp stmt({:var, kind, decls}, labels) do
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

  defp stmt({:for, init, test, update, body, sc}, labels)
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

  defp stmt({:while, c, body}, labels) do
    {tc, bc} = {ctest(c), stmt(body, [])}
    fn env -> while_loop(tc, bc, env, labels) end
  end

  # A break to this label ends the labeled statement normally, as in `fstmt/3`.
  defp stmt({:labeled, l, s}, labels) do
    sc = stmt(s, [l | labels])

    fn env ->
      case sc.(env) do
        {:brk, ^l} -> :ok
        c -> c
      end
    end
  end

  defp stmt({:break, l}, _labels) do
    c = {:brk, l}
    fn _env -> c end
  end

  defp stmt({:continue, l}, _labels) do
    c = {:cont, l}
    fn _env -> c end
  end

  defp stmt({:throw, e}, _labels) do
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
  defp stmt({:switch, disc, cases, sc}, labels) do
    cases =
      for {t, body} <- cases,
          do: {if(t == :default, do: :default, else: cc(t)), [{:cc, list(body)}]}

    shell_stmt({:switch, cc(disc), cases, sc}, labels)
  end

  defp stmt({:try, block, param, handler, finalizer, sc}, labels) do
    node = {:try, cs(block), param, handler && cs(handler), finalizer && cs(finalizer), sc}
    shell_stmt(node, labels)
  end

  defp stmt({kind, decl, pat, obj, body, sc}, labels) when kind in [:forin, :forof],
    do: shell_stmt({kind, decl, pat, cc(obj), cs(body), sc}, labels)

  defp stmt({:dowhile, body, c}, labels), do: shell_stmt({:dowhile, cs(body), cc(c)}, labels)

  defp stmt({:block, stmts, sc}, labels),
    do: shell_stmt({:block, [{:cc, list(stmts)}], sc}, labels)

  # (a framed `for` matches the shape of its head: a declaration runs as an expression
  # child that gives `:ok`, which the loop drops)
  defp stmt({:for, init, test, update, body, sc}, labels)
       when init == nil or elem(init, 0) in [:var, :expr] do
    init =
      case init do
        {:var, _, _} = d -> {:expr, cs(d)}
        {:expr, e} -> {:expr, cc(e)}
        nil -> nil
      end

    shell_stmt({:for, init, test && cc(test), update && cc(update), cs(body), sc}, labels)
  end

  defp stmt(node, labels), do: fallback_stmt(node, labels)

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
