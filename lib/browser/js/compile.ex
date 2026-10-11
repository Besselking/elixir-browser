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

    * constants, slot reads, `this`, global reads (`{:gref}`);
    * `?:`, `&&`, `||`, `??`, `!` and the binary operators;
    * property reads, calls, `new`, array and object literals;
    * assignments, compound assignments, `++` and `--` to a slot or to a property;
    * the statements `expr`, `return`, `if`, `block`, `var`, `for`, `while`, labels,
      `break` and `continue`.

  Every other node runs on the tree walker. Its closure gives the node to
  `Interp.ev/2`, `Interp.fstmt/3` or `Interp.tail_value/2`. The tree walker then runs the
  node and all the nodes in it.

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
      checks the call chain (S3).
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

  # The scope `d` hops above `env`, as `Interp.hop/2` finds it. One hop reads the header
  # of the frame inline. Check mode always calls `hop/2`, which checks that each frame is
  # live.
  defmacrop up(env, d) do
    if @check do
      quote do: Interp.hop(unquote(env), unquote(d))
    else
      quote do
        env = unquote(env)

        case unquote(d) do
          0 ->
            env

          1 ->
            case :erlang.get(env) do
              f when is_tuple(f) -> :erlang.element(1, f)
              %{parent: p} -> p
            end

          d ->
            Interp.hop(env, d)
        end
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

  defp expr({:cond, c, a, b}) do
    {cc, ac, bc} = {expr(c), expr(a), expr(b)}
    fn env -> if Interp.truthy(cc.(env)), do: ac.(env), else: bc.(env) end
  end

  defp expr({:logical, op, l, r}) do
    {lc, rc} = {expr(l), expr(r)}

    case op do
      "&&" ->
        fn env ->
          lv = lc.(env)
          if Interp.truthy(lv), do: rc.(env), else: lv
        end

      "||" ->
        fn env ->
          lv = lc.(env)
          if Interp.truthy(lv), do: lv, else: rc.(env)
        end

      "??" ->
        fn env ->
          lv = lc.(env)
          if Interp.nullish?(lv), do: rc.(env), else: lv
        end
    end
  end

  # (`!` has no special form in `ev/2`: its operand is a plain expression)
  defp expr({:unary, "!", e}) do
    ec = expr(e)
    fn env -> not Interp.truthy(ec.(env)) end
  end

  defp expr({:binary, op, l, r} = node) do
    case l do
      {:priv_ref, _} -> fallback(node)
      _ -> binary(op, expr(l), expr(r))
    end
  end

  defp expr({:member, o, k, opt} = node) do
    case k do
      {:priv, _} -> fallback(node)
      {:str, s} -> member(expr(o), s, opt)
      _ -> member(expr(o), expr(k), opt)
    end
  end

  defp expr({:call, callee, args, opt} = node) do
    with true <- plain_list?(args),
         {:ok, target} <- target(callee) do
      call(target, args_code(args), opt, callee)
    else
      _ -> fallback(node)
    end
  end

  defp expr({:new, callee, args} = node) do
    if plain_list?(args) do
      {cc, ac} = {expr(callee), args_code(args)}

      fn env ->
        f = cc.(env)
        # (the arguments are evaluated before the callee is checked)
        argv = ac.(env)

        unless Interp.function?(f) and Interp.constructor?(f),
          do:
            Interp.throw_error(
              "TypeError",
              "#{Interp.describe_node(callee)} is not a constructor"
            )

        if @check, do: Interp.check_link(env)
        Interp.construct(f, argv)
      end
    else
      fallback(node)
    end
  end

  defp expr({kind, "=", {:slot, d, i, name}, value} = node) when kind in [:assign, :sassign] do
    if nameable(value) do
      fallback(node)
    else
      vc = expr(value)

      fn env ->
        v = vc.(env)
        Interp.slot_assign(up(env, d), i, name, v)
        v
      end
    end
  end

  defp expr({kind, "=", {:member, o, k, _}, value} = node) when kind in [:assign, :sassign] do
    case k do
      {:priv, _} -> fallback(node)
      _ -> put(kind, expr(o), key_code(k), expr(value))
    end
  end

  defp expr({kind, op, target, value} = node)
       when kind in [:assign, :sassign] and op not in ["=", "&&=", "||=", "??="] do
    # (the operator of `x op= v` is `op` without the `=`, as in `compound_assign/5`)
    base = binary_part(op, 0, byte_size(op) - 1)

    case target do
      {:slot, d, i, name} ->
        compound_slot(base, d, i, name, expr(value))

      {:member, o, k, _} when elem(k, 0) != :priv ->
        compound_member(base, kind == :sassign, expr(o), key_code(k), expr(value))

      _ ->
        fallback(node)
    end
  end

  defp expr({kind, op, prefix?, target} = node) when kind in [:update, :supdate] do
    case target do
      {:slot, d, i, name} ->
        update_slot(op, prefix?, d, i, name)

      {:member, o, k, _} when elem(k, 0) != :priv ->
        update_member(op, prefix?, kind == :supdate, expr(o), key_code(k))

      _ ->
        fallback(node)
    end
  end

  defp expr({:array, elems} = node) do
    if plain_list?(elems) do
      ac = args_code(elems)
      # (`ev/2` evaluates the elements before it makes the array, as here)
      fn env -> Interp.new_array(ac.(env)) end
    else
      fallback(node)
    end
  end

  defp expr({:object, props} = node) do
    if Enum.all?(props, &plain_prop?/1) do
      pcs = for {:init, {:str, k}, v} <- props, do: {k, expr(v)}

      # (`ev/2` makes the object before it evaluates the values, as here)
      fn env ->
        obj = Interp.new_object()
        props(pcs, obj, env)
        obj
      end
    else
      fallback(node)
    end
  end

  defp expr(node), do: fallback(node)

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

  defp props([{k, vc} | rest], obj, env) do
    v = vc.(env)
    Interp.method_home(v, obj)
    Interp.define_data(obj, k, v)
    props(rest, obj, env)
  end

  # ── operators ──────────────────────────────────────────────

  # A binary operator, chosen at compile time. The left operand is evaluated first. For
  # `+`, `-` and the comparisons, two floats take the first clauses of `Interp.binop/3`
  # inline. Every other case calls `binop/3`, so the semantics are those of `binop/3`.
  defp binary("+", lc, rc) do
    fn env ->
      a = lc.(env)
      b = rc.(env)
      if is_float(a) and is_float(b), do: Num.add(a, b), else: Interp.binop("+", a, b)
    end
  end

  defp binary("-", lc, rc) do
    fn env ->
      a = lc.(env)
      b = rc.(env)
      if is_float(a) and is_float(b), do: Num.add(a, -b), else: Interp.binop("-", a, b)
    end
  end

  defp binary("<", lc, rc) do
    fn env ->
      a = lc.(env)
      b = rc.(env)
      if is_float(a) and is_float(b), do: a < b, else: Interp.binop("<", a, b)
    end
  end

  defp binary(">", lc, rc) do
    fn env ->
      a = lc.(env)
      b = rc.(env)
      if is_float(a) and is_float(b), do: a > b, else: Interp.binop(">", a, b)
    end
  end

  defp binary("<=", lc, rc) do
    fn env ->
      a = lc.(env)
      b = rc.(env)
      if is_float(a) and is_float(b), do: a <= b, else: Interp.binop("<=", a, b)
    end
  end

  defp binary(">=", lc, rc) do
    fn env ->
      a = lc.(env)
      b = rc.(env)
      if is_float(a) and is_float(b), do: a >= b, else: Interp.binop(">=", a, b)
    end
  end

  defp binary(op, lc, rc) do
    fn env ->
      a = lc.(env)
      Interp.binop(op, a, rc.(env))
    end
  end

  # ── properties ─────────────────────────────────────────────

  # The key of a property node: a constant string, or the closure of a computed key.
  defp key_code({:str, s}), do: s
  defp key_code(k), do: expr(k)

  # A property read, as `ev/2` reads `{:member, o, k, opt}`: the object, the test of an
  # optional member, then the key.
  defp member(oc, s, opt) when is_binary(s) do
    if opt do
      fn env ->
        ov = oc.(env)
        if Interp.nullish?(ov), do: throw(:js_short)
        Interp.get(ov, s)
      end
    else
      fn env -> Interp.get(oc.(env), s) end
    end
  end

  defp member(oc, kc, opt) do
    fn env ->
      ov = oc.(env)
      if opt and Interp.nullish?(ov), do: throw(:js_short)
      Interp.get(ov, kc.(env))
    end
  end

  # A property write `o[k] = v`: the object, the key, then the value, as `ev/2` writes it.
  # Sloppy code gives the value, and strict code gives what `strict_put/3` gives.
  defp put(:assign, oc, s, vc) when is_binary(s) do
    fn env ->
      ov = oc.(env)
      v = vc.(env)
      Interp.put(ov, s, v)
      v
    end
  end

  defp put(:assign, oc, kc, vc) do
    fn env ->
      ov = oc.(env)
      key = kc.(env)
      v = vc.(env)
      Interp.put(ov, key, v)
      v
    end
  end

  defp put(:sassign, oc, s, vc) when is_binary(s) do
    fn env ->
      ov = oc.(env)
      v = vc.(env)
      Interp.strict_put(ov, s, v)
    end
  end

  defp put(:sassign, oc, kc, vc) do
    fn env ->
      ov = oc.(env)
      key = kc.(env)
      v = vc.(env)
      Interp.strict_put(ov, key, v)
    end
  end

  # The value of a key closure, or the constant key.
  defmacrop key(kc, env) do
    quote do
      case unquote(kc) do
        s when is_binary(s) -> s
        kc -> kc.(unquote(env))
      end
    end
  end

  # `x op= v` to a slot, as `compound_assign/5` does it: one hop, the read with its test
  # of the temporal dead zone, the value, the operator, then the write. The result is the
  # write joined with the value by `&&`, as in `compound_assign/5`.
  defp compound_slot(base, d, i, name, vc) do
    form = {:slot, 0, i, name}

    fn env ->
      frame = up(env, d)
      old = slot0(frame, i, name, form)
      v = Interp.binop(base, old, vc.(env))
      Interp.slot_assign(frame, i, name, v) && v
    end
  end

  # `o[k] op= v`, as `compound_assign/5` does it: the object, the key, the test of a
  # nullish object, the key conversion (once, for the read and the write), the read, the
  # value, the operator, then the write.
  defp compound_member(base, strict?, oc, kc, vc) do
    fn env ->
      ov = oc.(env)
      key = key(kc, env)

      if Interp.nullish?(ov),
        do:
          Interp.throw_error(
            "TypeError",
            "Cannot read properties of #{Interp.to_str(ov)} (reading '#{Interp.safe_key(key)}')"
          )

      key = Interp.to_key(key)
      old = Interp.get(ov, key)
      v = Interp.binop(base, old, vc.(env))

      if(strict?, do: Interp.strict_put(ov, key, v), else: Interp.put(ov, key, v)) && v
    end
  end

  # `++x` and `x--` to a slot, as `ev/2` does them: the read with its test of the temporal
  # dead zone, the number, then the write with `slot_put/3`.
  defp update_slot(op, prefix?, d, i, name) do
    form = {:slot, 0, i, name}

    fn env ->
      frame = up(env, d)
      old = Interp.numeric(slot0(frame, i, name, form))
      new = Interp.bump(op, old)
      Interp.slot_put(frame, i, new)
      if prefix?, do: new, else: old
    end
  end

  # `++o[k]` and `o[k]--`, as `ev/2` does them: the object, the key, the test of a nullish
  # object, the key conversion, the read, the number, then the write.
  defp update_member(op, prefix?, strict?, oc, kc) do
    fn env ->
      ov = oc.(env)
      raw = key(kc, env)

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
  # for a method call, whose `this` is the object, or `{:plain, closure}`. A callee that
  # `call_target/2` reads by name, a `super` callee and an optional chain stay on the tree.
  defp target({:member, o, k, mopt}) when elem(k, 0) != :priv,
    do: {:ok, {:member, expr(o), key_code(k), mopt}}

  defp target({k, _}) when k in [:id, :super_member, :chain], do: :error
  defp target({:member, _, _, _}), do: :error
  defp target({:super}), do: :error
  defp target(callee), do: {:ok, {:plain, expr(callee)}}

  # A call, in the order of `ev/2`: the callee and `this`, the test of an optional call,
  # the arguments, then `Interp.ccall/5`, which the tree walker also uses.
  defp call({:member, oc, kc, mopt}, ac, opt, callee) do
    fn env ->
      ov = oc.(env)
      if mopt and Interp.nullish?(ov), do: throw(:js_short)
      f = Interp.get(ov, key(kc, env))
      if opt and Interp.nullish?(f), do: throw(:js_short)
      argv = ac.(env)
      Interp.ccall(f, ov, argv, callee, env)
    end
  end

  defp call({:plain, fc}, ac, opt, callee) do
    fn env ->
      f = fc.(env)
      if opt and Interp.nullish?(f), do: throw(:js_short)
      argv = ac.(env)
      Interp.ccall(f, :undefined, argv, callee, env)
    end
  end

  # The closure of an argument list without spread and holes: `fn env -> values end`. The
  # values are evaluated from left to right. Each value is bound before the next one is
  # evaluated, because Erlang does not define the order of the parts of a list.
  defp args_code([]), do: fn _env -> [] end

  defp args_code([a]) do
    ac = expr(a)
    fn env -> [ac.(env)] end
  end

  defp args_code([a, b]) do
    {ac, bc} = {expr(a), expr(b)}

    fn env ->
      x = ac.(env)
      [x, bc.(env)]
    end
  end

  defp args_code([a, b, c]) do
    {ac, bc, cc} = {expr(a), expr(b), expr(c)}

    fn env ->
      x = ac.(env)
      y = bc.(env)
      [x, y, cc.(env)]
    end
  end

  defp args_code(args) do
    cs = Enum.map(args, &expr/1)
    fn env -> values(cs, env) end
  end

  defp values([], _env), do: []

  defp values([c | cs], env) do
    v = c.(env)
    [v | values(cs, env)]
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

  defp stmt({:return, e, :plain}, _labels) do
    ec = expr(e)
    fn env -> {:ret, ec.(env)} end
  end

  defp stmt({:return, e, :tail}, _labels), do: tail(e)

  # (the branches of an `if` run without labels, as in `fstmt/3`)
  defp stmt({:if, c, a, nil}, _labels) do
    {cc, ac} = {expr(c), stmt(a, [])}
    fn env -> if Interp.truthy(cc.(env)), do: ac.(env), else: :ok end
  end

  defp stmt({:if, c, a, b}, _labels) do
    {cc, ac, bc} = {expr(c), stmt(a, []), stmt(b, [])}
    fn env -> if Interp.truthy(cc.(env)), do: ac.(env), else: bc.(env) end
  end

  defp stmt({:block, stmts, sc}, _labels) when frameless(sc) do
    bc = list(stmts)
    enter(sc, bc)
  end

  defp stmt({:var, kind, decls} = node, labels) do
    if Enum.all?(decls, &slot_decl?/1) do
      # (a `var` without a value does nothing, as in `exec/3`)
      ds =
        for {{:slot, d, i, name}, init} <- decls,
            not (init == nil and kind == :var),
            do: {d, i, name, if(init, do: expr(init))}

      fn env ->
        decls(ds, env)
        :ok
      end
    else
      fallback_stmt(node, labels)
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

    {tc, uc, bc} = {test && expr(test), update && expr(update), stmt(body, [])}

    lc =
      fn env ->
        if ic, do: ic.(env)
        for_loop(tc, uc, bc, env, labels)
      end

    enter(sc, lc)
  end

  defp stmt({:while, c, body}, labels) do
    {cc, bc} = {expr(c), stmt(body, [])}
    fn env -> while_loop(cc, bc, env, labels) end
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

  defp decls([{d, i, name, ic} | rest], env) do
    v = if ic, do: ic.(env), else: :undefined
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

    if tc == nil or Interp.truthy(tc.(env)) do
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
  defp while_loop(cc, bc, env, labels) do
    if Interp.truthy(cc.(env)) do
      Interp.tick()

      case bc.(env) do
        :ok ->
          while_loop(cc, bc, env, labels)

        {:cont, l} = c ->
          if l == nil or l in labels, do: while_loop(cc, bc, env, labels), else: leave(c)

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
    with true <- plain_list?(args),
         {:ok, target} <- target(callee) do
      tail_call(target, args_code(args), callee)
    else
      _ -> fallback_tail(e)
    end
  end

  defp tail({:cond, c, a, b}) do
    {cc, ac, bc} = {expr(c), tail(a), tail(b)}
    fn env -> if Interp.truthy(cc.(env)), do: ac.(env), else: bc.(env) end
  end

  defp tail({:seq, _} = e), do: fallback_tail(e)
  defp tail({:logical, _, _, _} = e), do: fallback_tail(e)

  defp tail(e) do
    ec = expr(e)
    fn env -> {:ret, ec.(env)} end
  end

  # (the test of the callee comes here, inside the frame of the caller, as in
  # `tail_value/2`)
  defp tail_call({:member, oc, kc, mopt}, ac, callee) do
    fn env ->
      ov = oc.(env)
      if mopt and Interp.nullish?(ov), do: throw(:js_short)
      f = Interp.get(ov, key(kc, env))
      argv = ac.(env)

      unless Interp.callable?(f),
        do: Interp.throw_error("TypeError", "#{Interp.describe_node(callee)} is not a function")

      {:tail, f, ov, argv}
    end
  end

  defp tail_call({:plain, fc}, ac, callee) do
    fn env ->
      f = fc.(env)
      argv = ac.(env)

      unless Interp.callable?(f),
        do: Interp.throw_error("TypeError", "#{Interp.describe_node(callee)} is not a function")

      {:tail, f, :undefined, argv}
    end
  end

  # ── nodes on the tree ──────────────────────────────────────

  # A node that does not compile. Its closure keeps the node and gives it to the tree
  # walker, which runs it and every node in it.
  defp fallback(node), do: fn env -> Interp.ev(node, env) end
  defp fallback_stmt(node, labels), do: fn env -> Interp.fstmt(node, env, labels) end
  defp fallback_tail(node), do: fn env -> Interp.tail_value(node, env) end
end
