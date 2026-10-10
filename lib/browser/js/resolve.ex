defmodule Browser.JS.Resolve do
  @moduledoc """
  The resolver: a pass over a parsed program that finds the scope of every
  name and attaches the facts the interpreter needs to run a function with
  slot frames.

  The pass is pure. It runs once per parsed program, after the parser, and
  only when the resolve level is not `:off`. With the level `:off` the program
  term does not change. With the level `:info` the pass attaches an `Info` to
  every function node and rewrites nothing. With a level from 1 to 4 the pass
  also rewrites the names of every function whose own level is that number or
  lower.

  The pass has two walks over the same tree. Pass 1 (`analyse`) gives every
  scope-making node a number, records the declarations of each scope and
  marks the names that inner functions capture. `layout` then decides which
  scopes get a frame and gives every name a slot. Pass 2 (`rewrite`) walks the
  tree again in the same order and replaces names by slot forms. Both passes
  must visit the scopes in the same order; `program/2` checks that they end
  with the same scope counter.

  This module also holds the helpers the interpreter uses to read the sixth
  element of a `{:fn, name, params, body, mode, src}` node, which is a source
  text, `nil` or an `Info` that carries the source text.

  Decisions that the design left open, and how this module decides them:

  - `delete x` of a slot keeps the delete node with the slot form inside it.
    The evaluator answers `false` without a lookup. A literal would lose the
    name, and `strip/1` could not restore the program.
  - `template` lists the initial values of the slots after the parameters and
    the hidden slots only. For `params: :exprs` the frame builder sets the
    parameter slots to `:tdz` before it binds them.
  - The name of a `{:using}` declaration inside a rewritten function becomes a
    slot form, because it is a binding target like a pattern.
  - `{:tdz_names, names, e}` gets slots of its own that nothing ever writes,
    so a read inside `e` always finds `:tdz`.
  - A reference to `arguments` that no function owns keeps `{:id}`.
  - Every `return` with a value inside a rewritten function carries a marker:
    `{:return, e, :tail}` at a tail site, `{:return, e, :plain}` elsewhere. The
    evaluator then never reads the run-time tail flag inside such a function.
  - A constructor gets the hidden slots it uses: `:this` always, `:new_target`
    and `:ctor_fn` for a `super()` call, `:home` for a `super.x` access.
  - `nparams` does not count a rest parameter.
  - A class declaration inside a function is a `:let` slot like any other
    lexical name: the parser gives it the `{:var, :let, ...}` form. Only
    `export default class` keeps the `{:classdecl}` form, which declares the
    kind `:class` in the module map scope, never in a frame.
  - An instance or accessor field initializer is a closure boundary like a
    function: it runs at each construction, after the block, the loop
    iteration or the parameter phase around the class has ended. A name it
    reads from outside the class is a capture. Static initializers and static
    blocks run inline and are not boundaries.
  - A direct `eval` inside a field initializer makes the field scope dynamic,
    not the function around the class. The initializers of that scope then
    keep every name as `{:id}`, as the statements of a static block do.
  - A direct `eval` inside a `for (using x of e)` head also makes the
    function around the head dynamic, so the TDZ pseudo-slots of the head
    stay out of the by-name walk of the eval code.
  - `var arguments` in a function with parameter initializers keeps the
    arguments object in a hidden slot under the atom `:arguments` for the
    parameter phase, and gives the `var` a slot of its own that `copies`
    fills from the object at body entry: a closure made in an initializer
    must keep the object when the body assigns the `var`.
  - A direct `eval` inside an arrow sets `uses_this`, `uses_arguments`,
    `uses_new_target` and `uses_home` on the nearest function that is not an
    arrow. The eval code reads these bindings by name from that function, so
    it becomes level 3 and does not run on a frame without them.
  - A direct `eval` or a `with` inside a parameter list, also inside a
    function in a default value, makes the function of that list dynamic. A
    by-name walk cannot tell a parameter from a body `var` of the same name.
  """

  alias Browser.JS.Interp
  alias Browser.JS.Resolve.{Info, Scope}

  @type level :: :off | :info | 1 | 2 | 3 | 4
  @type top :: :script | :module | :eval | :global_eval

  @header 5
  @hidden_order [:this, :args, :arguments, :new_target, :home, :ctor_fn, :self]
  @map_kinds [:module, :class, :field, :static, :static_block, :eval]
  @block_kinds [:block, :loop, :each, :switch, :catch, :tdz]
  @owner_kinds [:fn, :field, :static, :static_block]
  # The scopes whose code runs later than the scope around them: a function
  # and an instance field scope, whose initializers run at each construction.
  @closure_kinds [:fn, :field]

  # ── the hook ───────────────────────────────────────────────

  @doc """
  The hook at the end of `Parser.parse/2`. Returns the program unchanged when
  the resolve level is `:off`. The level comes from the parse option
  `resolve:` or from the application setting `:js_resolve`.
  """
  @spec maybe({:program, [term]}, keyword, boolean) :: {:program, [term]}
  def maybe({:program, _} = program, opts, strict?) do
    case Keyword.get(opts, :resolve) || Application.get_env(:browser, :js_resolve, :off) do
      :off -> program
      level -> program(program, level: level, top: top_kind(opts), strict: strict?)
    end
  end

  defp top_kind(opts) do
    cond do
      Keyword.get(opts, :module, false) -> :module
      Keyword.get(opts, :eval, false) and Keyword.get(opts, :indirect, false) -> :global_eval
      Keyword.get(opts, :eval, false) -> :eval
      true -> :script
    end
  end

  @doc """
  Resolves a parsed program. Options: `level:` (`:info` or 1 to 4), `top:`
  (`:script`, `:module`, `:eval` or `:global_eval`) and `strict:` (the
  strictness of the top-level code).
  """
  @spec program({:program, [term]}, keyword) :: {:program, [term]}
  def program({:program, stmts}, opts) do
    level = Keyword.fetch!(opts, :level)
    top = Keyword.get(opts, :top, :script)
    strict = Keyword.get(opts, :strict, false)

    unless level == :info or level in [1, 2, 3, 4],
      do: raise(ArgumentError, "unknown resolve level #{inspect(level)}")

    st1 = analyse(stmts, top, strict)
    scopes = layout(st1.scopes, level)
    {stmts2, st2} = rewrite(stmts, scopes, top, strict, level)

    # Both passes number the scopes as they meet them. A different count means
    # the walks disagree, and every slot form after the disagreement is wrong.
    if st1.next != st2.next,
      do: raise("resolver passes disagree: #{st1.next} scopes, then #{st2.next}")

    {:program, stmts2}
  end

  # ── readers of the sixth element ───────────────────────────

  @doc """
  Splits the sixth element of a function node into the source text and the
  `Info`. Returns `{src, nil}` when the resolver did not run.
  """
  @spec unpack(binary | nil | Info.t()) :: {binary | nil, Info.t() | nil}
  def unpack(%Info{src: src} = info), do: {src, info}
  def unpack(src), do: {src, nil}

  @doc """
  Gives a function node's sixth element a new source text and keeps its `Info`.
  A plain source text gives the new text back.
  """
  @spec with_src(binary | nil | Info.t(), binary | nil) :: binary | nil | Info.t()
  def with_src(%Info{} = info, src), do: %{info | src: src}
  def with_src(_, src), do: src

  @doc """
  The `Info` of a function node, or `nil` when the resolver did not run.
  """
  @spec info(tuple) :: Info.t() | nil
  def info({:fn, _, _, _, _, %Info{} = info}), do: info
  def info(_), do: nil

  @doc """
  The `Info` of a default class constructor. A base class gets an empty
  constructor. A derived class gets `constructor(...args) { super(...args) }`.
  The struct is constant: `rewritten` is false, and step 2d sets it when it
  gives the default constructors a frame.
  """
  @spec default_ctor_info(boolean, binary | nil) :: Info.t()
  def default_ctor_info(false, src) do
    %Info{
      src: src,
      kind: :ctor,
      name: "constructor",
      level: 3,
      strict: true,
      params: :plain,
      nparams: 0,
      size: @header + 1,
      slots: %{this: 6},
      hidden: [:this],
      kinds: {:parent, :rec, :caller, :call_pos, :root, :hidden},
      template: [],
      uses_this: true,
      free: :counter
    }
  end

  def default_ctor_info(true, src) do
    %Info{
      src: src,
      kind: :derived_ctor,
      name: "constructor",
      level: 3,
      strict: true,
      params: :patterns,
      nparams: 0,
      rest?: true,
      size: @header + 4,
      slots: %{"args" => 6, this: 7, new_target: 8, ctor_fn: 9},
      hidden: [:this, :new_target, :ctor_fn],
      kinds: {:parent, :rec, :caller, :call_pos, :root, :param, :hidden, :hidden, :hidden},
      template: [],
      uses_this: true,
      # (`super()` reads `new.target`, as `layout_fn` records for every
      # constructor that calls it)
      uses_new_target: true,
      uses_super: true,
      free: :counter
    }
  end

  # ── shared helpers ─────────────────────────────────────────

  # The names a pattern binds, in source order. `Interp.pattern_names/2`
  # prepends, so its result is in reverse order.
  defp names_of(pat), do: pat |> Interp.pattern_names([]) |> Enum.reverse()

  defp plain?(params), do: Enum.all?(params, &match?({:id, _}, &1))

  defp has_default?({:default, _, _}), do: true
  defp has_default?(t) when is_tuple(t), do: t |> Tuple.to_list() |> has_default?()
  defp has_default?(l) when is_list(l), do: Enum.any?(l, &has_default?/1)
  defp has_default?(_), do: false

  defp params_kind(params) do
    cond do
      plain?(params) -> :plain
      has_default?(params) -> :exprs
      true -> :patterns
    end
  end

  # The same walk as `Async.has_await?/1`: it stops at function nodes and not
  # at class nodes, because a class body is evaluated inline.
  defp awaits?({:await, _}), do: true
  defp awaits?({:yield, _, _}), do: true
  defp awaits?({:forawait, _, _, _, _}), do: true
  defp awaits?({:using, :await_using, _, _, _}), do: true
  defp awaits?({:gen, _}), do: false
  defp awaits?({:fn, _, _, _, _, _}), do: false
  defp awaits?({:async, _}), do: false
  defp awaits?(t) when is_tuple(t), do: t |> Tuple.to_list() |> Enum.any?(&awaits?/1)
  defp awaits?(l) when is_list(l), do: Enum.any?(l, &awaits?/1)
  defp awaits?(_), do: false

  # Whether a `return` of this expression is a tail call today: `tail_value`
  # (interp.ex) makes the call itself only for a plain call, and looks through
  # the branches of `?:`, the last element of a sequence and the right side of
  # a logical operator.
  defp tail_expr?({:call, callee, _, false}),
    do: callee != {:id, "eval"} and not match?({:chain, _}, callee) and callee != {:super}

  defp tail_expr?({:cond, _, a, b}), do: tail_expr?(a) or tail_expr?(b)
  defp tail_expr?({:seq, es}), do: tail_expr?(List.last(es))
  defp tail_expr?({:logical, _, _, r}), do: tail_expr?(r)
  defp tail_expr?(_), do: false

  defp unwrap({:async, f}, acc), do: unwrap(f, Map.put(acc, :async?, true))
  defp unwrap({:gen, f}, acc), do: unwrap(f, Map.put(acc, :generator?, true))
  defp unwrap({:fn, _, _, _, _, _} = f, acc), do: {f, acc}

  defp rewrap({:async, f}, inner), do: {:async, rewrap(f, inner)}
  defp rewrap({:gen, f}, inner), do: {:gen, rewrap(f, inner)}
  defp rewrap({:fn, _, _, _, _, _}, inner), do: inner

  defp body_strict?([{:expr, {:str, "use strict"}} | _]), do: true
  defp body_strict?(_), do: false

  defp fn_name({:method, n}), do: n
  defp fn_name(n) when is_binary(n), do: n
  defp fn_name(_), do: nil

  # ── prescan: the declarations of one statement list ────────

  # The `var` names of a body, in order of first appearance, with the walk of
  # `Interp.var_names/2` plus `for await (var ...)` heads, which the
  # interpreter forgets today.
  defp var_names(stmts), do: stmts |> vars([]) |> Enum.reverse() |> Enum.uniq()

  defp vars(stmts, acc) when is_list(stmts), do: Enum.reduce(stmts, acc, &vars/2)

  defp vars({:var, :var, decls}, acc),
    do: Enum.reduce(decls, acc, fn {pat, _}, a -> Interp.pattern_names(pat, a) end)

  defp vars({:export, stmt}, acc), do: vars(stmt, acc)
  defp vars({:using, _, _, _, rest}, acc), do: vars(rest, acc)
  defp vars({:if, _, a, b}, acc), do: vars(b, vars(a, acc))
  defp vars({:for, init, _, _, body}, acc), do: vars(body, vars(init, acc))

  defp vars({k, :var, pat, _, body}, acc) when k in [:forin, :forof, :forawait],
    do: vars(body, Interp.pattern_names(pat, acc))

  defp vars({k, _, _, _, body}, acc) when k in [:forin, :forof, :forawait], do: vars(body, acc)
  defp vars({:while, _, body}, acc), do: vars(body, acc)
  defp vars({:dowhile, body, _}, acc), do: vars(body, acc)
  defp vars({:block, stmts}, acc), do: vars(stmts, acc)
  defp vars({:with, _, body}, acc), do: vars(body, acc)
  defp vars({:labeled, _, s}, acc), do: vars(s, acc)
  defp vars({:try, b, _, h, f}, acc), do: vars(f, vars(h, vars(b, acc)))

  defp vars({:switch, _, cases}, acc),
    do: Enum.reduce(cases, acc, fn {_, body}, a -> vars(body, a) end)

  defp vars(_, acc), do: acc

  # The function declarations at the top of a list, through `using` rests and
  # exports, as `Interp.fundecls/1` finds them: `[{name, node}]` in order.
  defp fundecls(stmts) do
    Enum.flat_map(stmts, fn
      {:using, _, _, _, rest} -> fundecls(rest)
      {:fundecl, n, f} -> [{n, f}]
      {:export, {:fundecl, n, f}} -> [{n, f}]
      {:export_default, {:fundecl, n, f}} -> [{n, f}]
      _ -> []
    end)
  end

  # The lexical names at the top of a list as `[{name, kind}]`: `let`, `const`
  # and `using` declarations, through `using` rests (which the interpreter
  # forgets today) and exports. A class declaration parses as a `let`; only
  # `export default class` keeps its own form, at the top of a module.
  defp lexicals(stmts) do
    Enum.flat_map(stmts, fn
      {:var, kind, decls} when kind in [:let, :const] ->
        Enum.flat_map(decls, fn {pat, _} -> for n <- names_of(pat), do: {n, kind} end)

      {:using, _, name, _, rest} ->
        [{name, :using} | lexicals(rest)]

      {:export, stmt} ->
        lexicals([stmt])

      {:export_default, {:classdecl, n, _}} ->
        [{n, :class}]

      _ ->
        []
    end)
  end

  # The local names of the imports of a module, through `using` rests: a
  # top-level `using` owns every statement after it (parser.ex), the imports
  # included.
  defp imports(stmts) do
    Enum.flat_map(stmts, fn
      {:import, _, bindings} ->
        Enum.map(bindings, fn
          {:named, _, local} -> local
          {_, local} -> local
        end)

      {:using, _, _, _, rest} ->
        imports(rest)

      _ ->
        []
    end)
  end

  # ── pass 1: analyse ────────────────────────────────────────

  # The state of pass 1: the scope records by number, the chain of open scope
  # numbers (innermost first), the next number, the nearest function scope
  # and the strictness of the code being walked.
  defp analyse(stmts, top, strict) do
    st = %{scopes: %{}, chain: [], next: 1, fn: nil, strict: strict, top: top}
    {sid, st} = a_open(st, top_scope_kind(top), stmts)
    st = a_declare_top(st, sid, top, stmts, strict)

    st =
      case tla_flags(stmts, top) do
        nil -> a_stmts(stmts, st)
        flags -> a_tla_stmts(Enum.zip(stmts, flags), st)
      end

    a_close(st)
  end

  # Whether each top-level statement of a module awaits, or `nil` when none
  # does (or the code is not a module), so that the walk runs once per
  # statement and both passes read the same answer.
  defp tla_flags(stmts, :module) do
    flags = Enum.map(stmts, &awaits?/1)
    if Enum.any?(flags), do: flags, else: nil
  end

  defp tla_flags(_stmts, _top), do: nil

  defp top_scope_kind(:script), do: :global
  defp top_scope_kind(:module), do: :module
  defp top_scope_kind(_), do: :eval

  # A module scope knows its imports, `var`s, functions and lexical names. An
  # eval `lex` scope knows the lexical names, and the `var`s and functions too
  # when the code is strict (interp.ex `run_eval`). The global scope of a
  # script knows nothing: every name there is read by name at run time.
  defp a_declare_top(st, sid, :module, stmts, _strict) do
    st = a_declare_names(st, sid, imports(stmts), :import)
    st = a_declare_names(st, sid, var_names(stmts), :var)
    st = a_declare_names(st, sid, for({n, _} <- fundecls(stmts), do: n), :fun)
    a_declare_lex(st, sid, lexicals(stmts))
  end

  defp a_declare_top(st, sid, top, stmts, strict) when top in [:eval, :global_eval] do
    st =
      if strict do
        st = a_declare_names(st, sid, var_names(stmts), :var)
        a_declare_names(st, sid, for({n, _} <- fundecls(stmts), do: n), :fun)
      else
        st
      end

    a_declare_lex(st, sid, lexicals(stmts))
  end

  defp a_declare_top(st, _sid, :script, _stmts, _strict), do: st

  # A fresh scope record. `node` is the syntax it belongs to, so that pass 2
  # can check it meets the same scope.
  defp a_open(st, kind, node, extra \\ %{}) do
    sid = st.next

    scope =
      Map.merge(
        %{
          sid: sid,
          kind: kind,
          parent: List.first(st.chain),
          node: node,
          decls: %{},
          order: [],
          captured: MapSet.new(),
          default_captured: MapSet.new(),
          own_dynamic: false,
          dynamic: false,
          dynamic_inside: false
        },
        extra
      )

    st = %{st | scopes: Map.put(st.scopes, sid, scope), chain: [sid | st.chain], next: sid + 1}
    {sid, st}
  end

  defp a_close(%{chain: [_ | rest]} = st), do: %{st | chain: rest}

  defp a_scope(st, sid), do: Map.fetch!(st.scopes, sid)

  defp a_update(st, sid, fun), do: %{st | scopes: Map.update!(st.scopes, sid, fun)}

  # Declares a name in a scope unless it is already there with a kind that
  # wins: a parameter keeps its slot over a `var` or a function declaration,
  # and a function declaration takes over a `var` slot.
  defp a_declare(st, sid, name, kind) do
    a_update(st, sid, fn s ->
      case s.decls do
        %{^name => :param} -> s
        %{^name => :var} when kind == :fun -> %{s | decls: Map.put(s.decls, name, :fun)}
        %{^name => _} -> s
        _ -> %{s | decls: Map.put(s.decls, name, kind), order: [name | s.order]}
      end
    end)
  end

  defp a_declare_names(st, sid, names, kind),
    do: Enum.reduce(names, st, &a_declare(&2, sid, &1, kind))

  defp a_declare_lex(st, sid, lex),
    do: Enum.reduce(lex, st, fn {n, k}, st -> a_declare(st, sid, n, k) end)

  # Resolves a name along the chain and records a capture when the walk passes
  # a closure boundary before it finds the declaring scope. A function is a
  # boundary, and so is an instance field scope: its initializers run at each
  # construction, after the scope that made the class has moved on. A capture
  # during the parameter phase of the declaring function comes from a closure
  # in a default value; `layout` gives such a parameter a slot of its own when
  # a body `var` shares its name.
  defp a_ref(st, name), do: a_ref(st, st.chain, name, false)

  defp a_ref(st, [], _name, _passed), do: st

  defp a_ref(st, [sid | rest], name, passed) do
    s = a_scope(st, sid)

    if visible?(s, name),
      do: if(passed, do: a_capture(st, sid, name), else: st),
      else: a_ref(st, rest, name, passed or s.kind in @closure_kinds)
  end

  # Parameter defaults see the parameters and the self name of their function,
  # never the names its body declares: with a default present the body gets a
  # scope of its own after the parameters are bound (`hoist_into_body`).
  defp visible?(%{decls: decls} = s, name) do
    case decls do
      %{^name => kind} -> s.kind != :fn or s.phase == :body or kind in [:param, :self]
      _ -> false
    end
  end

  # A capture in the parameter phase of a function goes into
  # `default_captured` only: it reads the parameter's slot, which a body
  # `var` of the same name may hide in `slots` later (see `finish_scope`).
  defp a_capture(st, sid, name) do
    a_update(st, sid, fn s ->
      if s.kind == :fn and s.phase == :params,
        do: %{s | default_captured: MapSet.put(s.default_captured, name)},
        else: %{s | captured: MapSet.put(s.captured, name)}
    end)
  end

  # `arguments` belongs to the nearest function that is not an arrow and does
  # not declare the name itself. A field initializer or a static block stops
  # the walk: the name is a parse error there, and nothing above it owns it.
  defp a_arguments(st, [], _passed), do: st

  defp a_arguments(st, [sid | rest], passed) do
    s = a_scope(st, sid)

    cond do
      # `var arguments` without a function of that name keeps the object in
      # the `var` slot (interp.ex `args_var?`); any other declaration hides
      # it, but not from the parameter defaults, which run before the body's
      # names are bound. The capture is of the object, under the atom, so
      # that `finish_scope` finds the object's slot and not a declaration's.
      s.kind == :fn and not s.arrow? and
          (not visible?(s, "arguments") or s.decls["arguments"] == :var) ->
        st = a_update(st, sid, &%{&1 | uses_arguments: true})
        if passed, do: a_capture(st, sid, :arguments), else: st

      visible?(s, "arguments") ->
        if passed, do: a_capture(st, sid, "arguments"), else: st

      s.kind in [:field, :static, :static_block] ->
        st

      true ->
        a_arguments(st, rest, passed or s.kind == :fn)
    end
  end

  # `this`, `new.target` and `super` belong to the nearest function that is
  # not an arrow, or to a field or static scope, which the class code gives
  # them at run time.
  defp a_owner(st, [], _flag, _passed), do: st

  defp a_owner(st, [sid | rest], flag, passed) do
    s = a_scope(st, sid)

    cond do
      s.kind == :fn and not s.arrow? ->
        st = a_update(st, sid, &Map.put(&1, flag, true))
        if passed, do: a_capture(st, sid, flag), else: st

      s.kind in [:field, :static, :static_block] ->
        st

      true ->
        a_owner(st, rest, flag, passed or s.kind == :fn)
    end
  end

  # A direct `eval` or a `with` makes the nearest function-like scope dynamic:
  # eval code adds names to the nearest `fnscope` at run time (interp.ex
  # `variable_scope`), which a field or static scope is too. When the walk
  # then passes a `:tdz` scope (the head of a `for (using x of e)`), the next
  # function-like scope above it is dynamic too: the TDZ names have no frame
  # and no slot, so only a by-name walk through today's `{:tdz_names}` scope
  # can give the eval code the TDZ error.
  #
  # A function whose parameter list holds the eval or the `with` (also inside
  # a function in a default value) is dynamic too. The eval code reads a
  # parameter by name, and a body `var` of the same name has its own slot
  # with the same name in `slots`, so a by-name walk through a frame would
  # find the body slot and not the parameter.
  defp a_dynamic(st) do
    st = a_dynamic(st, st.chain, true)
    Enum.reduce(st.chain, st, &a_param_dynamic(&2, &1))
  end

  defp a_param_dynamic(st, sid) do
    case a_scope(st, sid) do
      %{kind: :fn, phase: :params} -> a_update(st, sid, &%{&1 | own_dynamic: true})
      _ -> st
    end
  end

  defp a_dynamic(st, [], _mark), do: st

  defp a_dynamic(st, [sid | rest], mark) do
    case a_scope(st, sid).kind do
      k when k in @owner_kinds and mark ->
        a_dynamic(a_update(st, sid, &%{&1 | own_dynamic: true}), rest, false)

      :tdz ->
        a_dynamic(st, rest, true)

      _ ->
        a_dynamic(st, rest, mark)
    end
  end

  # A private name is read by name through the frames up to the class scope,
  # which needs the by-name path of level 3 in the function that holds it.
  defp a_priv(st) do
    case Enum.find(st.chain, &(a_scope(st, &1).kind in @owner_kinds)) do
      nil -> st
      sid -> a_update(st, sid, fn s -> if s.kind == :fn, do: %{s | priv: true}, else: s end)
    end
  end

  defp a_makes_closures(%{fn: nil} = st), do: st
  defp a_makes_closures(st), do: a_update(st, st.fn, &%{&1 | makes_closures: true})

  # Top-level statements of a module that awaits run through the CPS
  # evaluator, which creates functions inside scopes of its own (async.ex
  # `eval_leaves`). Such a statement is a leaf region: hop counts stop at it.
  defp a_tla_stmts(stmts_with_flags, st) do
    Enum.reduce(stmts_with_flags, st, fn
      {stmt, true}, st ->
        {_, st} = a_open(st, :cps_leaf, stmt)
        a_stmt(stmt, st) |> a_close()

      {stmt, false}, st ->
        a_stmt(stmt, st)
    end)
  end

  defp a_stmts(stmts, st), do: Enum.reduce(stmts, st, &a_stmt/2)

  # A statement list declares its function declarations; a function that is
  # the sole branch of an `if` or a labeled body is never instantiated
  # (parser.ex `body_statement`), so `a_substmt` resolves it as a function
  # and declares nothing.
  defp a_substmt({:fundecl, _, f}, st), do: a_function(f, :fn, false, st)
  defp a_substmt(stmt, st), do: a_stmt(stmt, st)

  defp a_stmt({:pos, _}, st), do: st
  defp a_stmt({:empty}, st), do: st
  defp a_stmt({:expr, e}, st), do: a_expr(e, st)

  # A `using` inside a static block (the only place the `{:var, :using}` form
  # survives) leaks its names at run time; nothing declares them.
  defp a_stmt({:var, kind, decls}, st) when kind in [:var, :let, :const, :using, :await_using] do
    Enum.reduce(decls, st, fn {pat, init}, st ->
      st = if init, do: a_expr(init, st), else: st
      a_pat(pat, st)
    end)
  end

  defp a_stmt({:using, _, name, init, rest}, st) do
    st = a_expr(init, st)
    st = a_ref(st, name)
    a_stmts(rest, st)
  end

  defp a_stmt({:fundecl, _, f}, st), do: a_function(f, :fn, false, st)
  defp a_stmt({:return, nil}, st), do: st
  defp a_stmt({:return, e}, st), do: a_expr(e, st)
  defp a_stmt({:throw, e}, st), do: a_expr(e, st)

  defp a_stmt({:if, c, a, b}, st) do
    st = a_expr(c, st)
    st = a_substmt(a, st)
    if b, do: a_substmt(b, st), else: st
  end

  defp a_stmt({:labeled, _, s}, st), do: a_substmt(s, st)
  defp a_stmt({:while, c, body}, st), do: a_substmt(body, a_expr(c, st))
  defp a_stmt({:dowhile, body, c}, st), do: a_expr(c, a_substmt(body, st))
  defp a_stmt({:break, _}, st), do: st
  defp a_stmt({:continue, _}, st), do: st

  defp a_stmt({:block, stmts}, st) do
    {sid, st} = a_open(st, :block, stmts)
    st = a_declare_block(st, sid, stmts)
    a_stmts(stmts, st) |> a_close()
  end

  defp a_stmt({:for, init, test, update, body}, st) do
    {sid, st} = a_open(st, :loop, {init, test, update, body}, %{head: head_kind(init)})

    st =
      case init do
        {:var, kind, decls} when kind in [:let, :const] ->
          st = a_declare_lex(st, sid, for({p, _} <- decls, n <- names_of(p), do: {n, kind}))
          a_stmt(init, st)

        {:var, :var, _} ->
          a_stmt(init, st)

        {:expr, e} ->
          a_expr(e, st)

        nil ->
          st
      end

    st = if test, do: a_expr(test, st), else: st
    st = if update, do: a_expr(update, st), else: st
    a_substmt(body, st) |> a_close()
  end

  defp a_stmt({k, decl, pat, obj, body}, st) when k in [:forin, :forof, :forawait] do
    {sid, st} = a_open(st, :each, {decl, pat, obj, body}, %{head: decl})

    st =
      if decl in [:let, :const],
        do: a_declare_lex(st, sid, for(n <- names_of(pat), do: {n, decl})),
        else: st

    st = a_expr(obj, st)
    st = a_pat(pat, st)
    a_substmt(body, st) |> a_close()
  end

  defp a_stmt({:switch, disc, cases}, st) do
    st = a_expr(disc, st)
    all = Enum.flat_map(cases, fn {_, body} -> body end)
    {sid, st} = a_open(st, :switch, cases)
    st = a_declare_block(st, sid, all)

    st =
      Enum.reduce(cases, st, fn {test, body}, st ->
        st = if test == :default, do: st, else: a_expr(test, st)
        a_stmts(body, st)
      end)

    a_close(st)
  end

  defp a_stmt({:try, block, param, handler, finalizer}, st) do
    st = a_substmt(block, st)
    {sid, st} = a_open(st, :catch, {param, handler})
    st = if param, do: a_declare_lex(st, sid, for(n <- names_of(param), do: {n, :let})), else: st
    st = if param, do: a_pat(param, st), else: st
    st = if handler, do: a_substmt(handler, st), else: st
    st = a_close(st)
    if finalizer, do: a_substmt(finalizer, st), else: st
  end

  defp a_stmt({:with, obj, body}, st) do
    st = a_expr(obj, st)
    st = a_dynamic(st)
    {_, st} = a_open(st, :with, body, %{own_dynamic: true})
    a_substmt(body, st) |> a_close()
  end

  defp a_stmt({:import, _, _}, st), do: st
  defp a_stmt({:export, stmt}, st), do: a_stmt(stmt, st)
  defp a_stmt({:export_default, {:fundecl, _, f}}, st), do: a_function(f, :fn, false, st)
  defp a_stmt({:export_default, {:classdecl, _, c}}, st), do: a_class(c, st)
  defp a_stmt({:export_default, {:expr, e}}, st), do: a_expr(e, st)
  defp a_stmt({:export_names, _}, st), do: st
  defp a_stmt({:export_from, _, _}, st), do: st
  defp a_stmt(other, _st), do: raise("resolver: unknown statement #{inspect(other, limit: 5)}")

  defp head_kind({:var, kind, _}), do: kind
  defp head_kind(_), do: nil

  # A block, switch or static block declares the lexical names and the
  # function declarations at the top of its list. Duplicate sloppy functions
  # share a slot: the last declaration wins at entry.
  defp a_declare_block(st, sid, stmts) do
    st = a_declare_lex(st, sid, lexicals(stmts))
    a_declare_names(st, sid, for({n, _} <- fundecls(stmts), do: n), :fun)
  end

  # ── pass 1: patterns and expressions ───────────────────────

  defp a_pat({:id, "arguments"}, st), do: a_arguments(st, st.chain, false)
  defp a_pat({:id, n}, st), do: a_ref(st, n)
  defp a_pat({:default, p, e}, st), do: a_pat(p, a_expr(e, st))
  defp a_pat({:rest, p}, st), do: a_pat(p, st)

  defp a_pat({:arrpat, elems}, st) do
    Enum.reduce(elems, st, fn
      nil, st -> st
      p, st -> a_pat(p, st)
    end)
  end

  defp a_pat({:objpat, props, rest}, st) do
    st =
      Enum.reduce(props, st, fn {key, p}, st ->
        st = a_key(key, st)
        a_pat(p, st)
      end)

    if rest, do: a_pat(rest, st), else: st
  end

  defp a_pat({:member, _, _, _} = m, st), do: a_expr(m, st)
  # (`for (f() in o)` parses in sloppy code and fails at run time)
  defp a_pat({:call, _, _, _} = c, st), do: a_expr(c, st)
  defp a_pat(other, _st), do: raise("resolver: unknown pattern #{inspect(other, limit: 5)}")

  # The keys of members, properties and patterns. A static block carries a
  # `nil` key, which `a_member` handles without this function.
  defp a_key({:computed, e}, st), do: a_expr(e, st)
  defp a_key({:str, _}, st), do: st
  defp a_key({:priv, _}, st), do: st

  defp a_exprs(es, st), do: Enum.reduce(es, st, &a_expr/2)

  defp a_expr({:id, "arguments"}, st), do: a_arguments(st, st.chain, false)
  defp a_expr({:id, n}, st), do: a_ref(st, n)
  defp a_expr({:this}, st), do: a_owner(st, st.chain, :uses_this, false)
  defp a_expr({:new_target}, st), do: a_owner(st, st.chain, :uses_new_target, false)
  defp a_expr({:super}, st), do: a_owner(st, st.chain, :uses_super_call, false)

  defp a_expr({:super_member, k}, st) do
    st = a_owner(st, st.chain, :uses_home, false)
    a_key_or_expr(k, st)
  end

  defp a_expr({:fn, _, _, _, _, _} = f, st), do: a_function(f, :fn, true, st)
  defp a_expr({:gen, _} = f, st), do: a_function(f, :fn, true, st)
  defp a_expr({:async, _} = f, st), do: a_function(f, :fn, true, st)
  defp a_expr({:unnamed, e}, st), do: a_expr(e, st)
  defp a_expr({:class, _, _, _, _} = c, st), do: a_class(c, st)

  # (a private key goes through `a_key_or_expr`, which marks the function)
  defp a_expr({:member, o, k, _}, st), do: a_key_or_expr(k, a_expr(o, st))
  defp a_expr({:chain, e}, st), do: a_expr(e, st)

  # A direct eval is the syntactic form; whether the callee is the real
  # `eval` is decided at run time, so the function must stay name-based.
  #
  # Eval code reads `this`, `arguments`, `new.target` and `super` by name
  # from the nearest function that is not an arrow (interp.ex `direct_eval`,
  # `lazy_arguments`). When the eval sits in an arrow, that function is not
  # dynamic itself, so it must at least own these bindings: the flags make
  # it level 3, which keeps it off the frame path until step 2d gives it
  # the hidden slots that the eval code reads by name.
  defp a_expr({:call, {:id, "eval"} = callee, args, false}, st) do
    st = a_dynamic(st)

    st =
      Enum.reduce(
        [:uses_this, :uses_arguments, :uses_new_target, :uses_home],
        st,
        &a_owner(&2, &2.chain, &1, false)
      )

    a_args(args, a_expr(callee, st))
  end

  defp a_expr({:call, callee, args, _}, st), do: a_args(args, a_expr(callee, st))
  defp a_expr({:new, callee, args}, st), do: a_args(args, a_expr(callee, st))

  defp a_expr({:tmpl, parts}, st),
    do: Enum.reduce(parts, st, fn p, st -> if is_binary(p), do: st, else: a_expr(p, st) end)

  defp a_expr({:array, elems}, st) do
    Enum.reduce(elems, st, fn
      :hole, st -> st
      {:spread, e}, st -> a_expr(e, st)
      e, st -> a_expr(e, st)
    end)
  end

  defp a_expr({:object, props}, st) do
    Enum.reduce(props, st, fn
      {:init, key, {:fn, {:method, _}, _, _, _, _} = f}, st ->
        a_function(f, :method, false, a_key(key, st))

      {:init, key, {w, _} = f}, st when w in [:gen, :async] ->
        {inner, _} = unwrap(f, %{})

        if match?({:fn, {:method, _}, _, _, _, _}, inner),
          do: a_function(f, :method, false, a_key(key, st)),
          else: a_expr(f, a_key(key, st))

      {:init, key, v}, st ->
        a_expr(v, a_key(key, st))

      {:getter, key, f}, st ->
        a_function(f, :get, false, a_key(key, st))

      {:setter, key, f}, st ->
        a_function(f, :set, false, a_key(key, st))

      {:spread, e}, st ->
        a_expr(e, st)

      {:proto, e}, st ->
        a_expr(e, st)
    end)
  end

  defp a_expr({:unary, _, e}, st), do: a_expr(e, st)
  # (`#p in o` has a `{:priv_ref}` left side, which marks the function below)
  defp a_expr({:binary, _, l, r}, st), do: a_expr(r, a_expr(l, st))
  defp a_expr({:logical, _, l, r}, st), do: a_expr(r, a_expr(l, st))
  defp a_expr({:cond, c, a, b}, st), do: a_expr(b, a_expr(a, a_expr(c, st)))
  defp a_expr({:seq, es}, st), do: a_exprs(es, st)
  defp a_expr({k, _, _, target}, st) when k in [:update, :supdate], do: a_expr(target, st)

  defp a_expr({k, _, target, value}, st) when k in [:assign, :sassign],
    do: a_expr(value, a_expr(target, st))

  defp a_expr({:destructure, pat, right}, st), do: a_pat(pat, a_expr(right, st))
  defp a_expr({:await, e}, st), do: a_expr(e, st)
  defp a_expr({:yield, e, _}, st), do: a_expr(e, st)
  defp a_expr({:spread, e}, st), do: a_expr(e, st)
  defp a_expr({:import_call, e}, st), do: a_expr(e, st)
  defp a_expr({:import_call, e, o}, st), do: a_expr(o, a_expr(e, st))
  defp a_expr({:import_phase, _, args}, st), do: a_exprs(args, st)

  # The names of a `for (using x of e)` head are in their TDZ while `e` runs.
  # They get slots that nothing writes, so a read always finds `:tdz`.
  defp a_expr({:tdz_names, names, e}, st) do
    {sid, st} = a_open(st, :tdz, names)
    st = a_declare_lex(st, sid, for(n <- names, do: {n, :const}))
    a_expr(e, st) |> a_close()
  end

  defp a_expr({:num, _}, st), do: st
  defp a_expr({:bigint, _}, st), do: st
  defp a_expr({:str, _}, st), do: st
  defp a_expr({:lit, _}, st), do: st
  defp a_expr({:regex, _, _}, st), do: st
  defp a_expr({:val, _}, st), do: st
  defp a_expr({:tagged_strings, _, _, _}, st), do: st
  defp a_expr({:import_meta}, st), do: st
  defp a_expr({:priv_ref, _}, st), do: a_priv(st)
  defp a_expr(other, _st), do: raise("resolver: unknown expression #{inspect(other, limit: 5)}")

  defp a_args(args, st) do
    Enum.reduce(args, st, fn
      {:spread, e}, st -> a_expr(e, st)
      e, st -> a_expr(e, st)
    end)
  end

  defp a_key_or_expr({:str, _}, st), do: st
  defp a_key_or_expr({:priv, _}, st), do: a_priv(st)
  defp a_key_or_expr(e, st), do: a_expr(e, st)

  # ── pass 1: functions and classes ──────────────────────────

  # `kind` is the position of the function: `:fn`, `:method`, `:get`, `:set`,
  # `:ctor` or `:derived_ctor`. `expr?` says whether a binary name is a
  # binding inside the function (a function expression) or not (a
  # declaration).
  defp a_function(node, kind, expr?, st) do
    st = a_makes_closures(st)

    {{:fn, name, params, body, mode, _}, flags} =
      unwrap(node, %{async?: false, generator?: false})

    arrow? = mode in [:arrow, :arrow_expr]
    strict = if mode == :arrow_expr, do: st.strict, else: body_strict?(body)
    param_names = Enum.flat_map(params, &names_of/1)

    {vars, funs, lex} =
      if mode == :arrow_expr,
        do: {[], [], []},
        else: {var_names(body), fundecls(body), lexicals(body)}

    fun_names = for {n, _} <- funs, do: n
    declared = param_names ++ vars ++ fun_names ++ for({n, _} <- lex, do: n)

    self =
      if expr? and kind == :fn and is_binary(name) and mode == false and name not in declared,
        do: name,
        else: nil

    # A body declaration of the self name hides the self name only in the body. The
    # parameter expressions still see the self binding, and a slot frame has no place for
    # a name that only the parameters see, so such a function keeps its names.
    hidden_self? =
      expr? and kind == :fn and is_binary(name) and mode == false and
        name not in param_names and name in declared and params_kind(params) != :plain

    {sid, st} =
      a_open(st, :fn, node, %{
        fn_kind: kind,
        name: fn_name(name),
        mode: mode,
        arrow?: arrow?,
        strict: strict,
        async?: flags.async?,
        generator?: flags.generator?,
        params_list: params,
        param_names: param_names,
        vars: vars,
        fun_names: Enum.uniq(fun_names),
        lex: lex,
        self: self,
        own_dynamic: hidden_self?,
        phase: :params,
        makes_closures: false,
        uses_this: false,
        uses_arguments: false,
        uses_new_target: false,
        uses_super_call: false,
        uses_home: false,
        priv: false,
        # Only an async or generator body can hold an await, a yield, a `for
        # await` or an `await using`; the walk would find nothing elsewhere.
        has_await: (flags.async? or flags.generator?) and awaits?(body)
      })

    st = a_declare_names(st, sid, param_names, :param)
    st = a_declare_names(st, sid, vars, :var)
    st = a_declare_names(st, sid, fun_names, :fun)
    st = a_declare_lex(st, sid, lex)
    st = if self, do: a_declare(st, sid, self, :self), else: st

    outer = {st.fn, st.strict}
    st = %{st | fn: sid, strict: strict}
    st = Enum.reduce(params, st, &a_pat/2)
    st = a_update(st, sid, &%{&1 | phase: :body})
    st = if mode == :arrow_expr, do: a_expr(body, st), else: a_stmts(body, st)
    {fn0, strict0} = outer
    st = %{st | fn: fn0, strict: strict0}
    a_close(st)
  end

  # A class makes a scope for its name and its private names. Heritage,
  # computed keys and member decorators run in it; class decorators run
  # outside it. Instance field initializers share one scope per construction
  # under the class scope; static members share one static scope, and each
  # static block gets a scope of its own under that (classes.ex `run_statics`).
  defp a_class({:class, name, heritage, members, _} = node, st) do
    st = a_makes_closures(st)
    {decs, members} = split_decorations(members)
    st = a_exprs(elem(decs, 0), st)

    {sid, st} = a_open(st, :class, node)
    st = if name, do: a_declare(st, sid, name, :const), else: st
    outer_strict = st.strict
    st = %{st | strict: true}
    st = if heritage, do: a_expr(heritage, st), else: st
    {field_sid, st} = a_open(st, :field, {:field, node})
    st = a_close(st)
    {static_sid, st} = a_open(st, :static, {:static, node})
    st = a_close(st)
    derived? = heritage != nil

    st =
      members
      |> Enum.with_index()
      |> Enum.reduce(st, fn {member, i}, st ->
        st = a_exprs(Map.get(elem(decs, 1), i, []), st)
        a_member(member, derived?, field_sid, static_sid, st)
      end)

    st = %{st | strict: outer_strict}
    a_close(st)
  end

  defp split_decorations(members) do
    case List.last(members) do
      {:decorations, class_decs, member_decs} ->
        {{class_decs, member_decs}, Enum.drop(members, -1)}

      _ ->
        {{[], %{}}, members}
    end
  end

  defp a_member({:cmember, :method, {:str, "constructor"} = key, f, false}, derived?, _, _, st) do
    st = a_key(key, st)
    a_function(f, if(derived?, do: :derived_ctor, else: :ctor), false, st)
  end

  defp a_member({:cmember, kind, key, f, _}, _, _, _, st) when kind in [:method, :get, :set] do
    st = a_key(key, st)
    a_function(f, kind, false, st)
  end

  defp a_member({:cmember, kind, key, init, static?}, _, field_sid, static_sid, st)
       when kind in [:field, :accessor] do
    st = a_key(key, st)

    if init do
      st = %{st | chain: [if(static?, do: static_sid, else: field_sid) | st.chain]}
      a_expr(init, st) |> a_close()
    else
      st
    end
  end

  defp a_member({:cmember, :block, nil, stmts, true}, _, _, static_sid, st) do
    st = %{st | chain: [static_sid | st.chain]}
    {sid, st} = a_open(st, :static_block, stmts)
    st = a_declare_names(st, sid, var_names(stmts), :var)
    st = a_declare_block(st, sid, stmts)
    a_stmts(stmts, st) |> a_close() |> a_close()
  end

  # ── layout ─────────────────────────────────────────────────

  # Decides frames and slots for every scope. Returns the scope map with, per
  # function scope, the proto `Info` (`:info`), and per block-like scope the
  # proto `Scope` (`:scope`, `nil` when it declares nothing), plus `:index`
  # (name to slot) and `:home` for every scope.
  defp layout(scopes, level) do
    sids = scopes |> Map.keys() |> Enum.sort()

    # A function is dynamic when it, or any scope around it, holds a direct
    # eval or a `with`. Parents have smaller numbers, so one pass in order
    # settles every scope.
    scopes =
      Enum.reduce(sids, scopes, fn sid, scopes ->
        s = scopes[sid]
        inherited = s.parent != nil and scopes[s.parent].dynamic
        Map.put(scopes, sid, %{s | dynamic: s.own_dynamic or inherited})
      end)

    # A block gets a frame when a dynamic function sits anywhere inside it:
    # the eval string can name the block's bindings, and the by-name walk
    # must find the block's own table. Children have larger numbers, so one
    # pass in reverse order settles every scope.
    scopes =
      Enum.reduce(Enum.reverse(sids), scopes, fn sid, scopes ->
        s = scopes[sid]

        if s.parent != nil and (s.dynamic_inside or s.dynamic),
          do: Map.update!(scopes, s.parent, &%{&1 | dynamic_inside: true}),
          else: scopes
      end)

    scopes =
      Enum.reduce(sids, scopes, fn sid, scopes ->
        s = scopes[sid]

        frame =
          case s.kind do
            :fn ->
              true

            # A scope that declares nothing needs no frame, whatever sits
            # inside it.
            k when k in [:block, :loop, :each, :switch, :catch] ->
              s.order != [] and (MapSet.size(s.captured) > 0 or s.dynamic_inside)

            _ ->
              false
          end

        Map.put(scopes, sid, Map.put(s, :frame, frame))
      end)

    # Every frame takes the names of the frameless scopes under it, in
    # pre-order, which is the order of the numbers.
    scopes = Enum.reduce(sids, scopes, &layout_scope(&2, &1, level))

    frameless =
      scopes
      |> Map.values()
      |> Enum.filter(&(&1.kind in @block_kinds and not &1.frame and &1.home != nil))
      |> Enum.group_by(& &1.home)

    Enum.reduce(sids, scopes, &finish_scope(&2, &1, Map.get(frameless, &1, [])))
  end

  # The nearest scope with a frame above `sid`, or `nil` when a map scope or
  # top-level code comes first: the names of such a scope live in a map at
  # run time and need no slot.
  defp home_of(scopes, sid) do
    case scopes[sid] do
      %{parent: nil} ->
        nil

      %{parent: p} ->
        parent = scopes[p]

        cond do
          frame_scope?(parent) -> p
          parent.kind in @block_kinds -> home_of(scopes, p)
          true -> nil
        end
    end
  end

  defp frame_scope?(%{kind: :fn}), do: true
  defp frame_scope?(%{kind: k, frame: true}) when k in @block_kinds, do: true
  defp frame_scope?(_), do: false

  defp layout_scope(scopes, sid, level) do
    s = scopes[sid]

    case s.kind do
      :fn -> Map.put(scopes, sid, layout_fn(s, level))
      k when k in @block_kinds -> layout_block(scopes, sid, s)
      _ -> Map.put(scopes, sid, Map.merge(s, %{index: %{}, home: nil}))
    end
  end

  # The slot groups of a function frame, in the order of design 3.1:
  # parameters, hidden slots, `var` names, function declarations, the body's
  # lexical names. The names of frameless scopes inside come later, when
  # `layout_block` meets them. Each group takes and returns a layout
  # accumulator: `index` (name to slot), `kinds` (slot to kind), `next` (the
  # first free slot), `template` (the initial values after the parameters and
  # the hidden slots, reversed while the layout grows) and `copies`.
  defp layout_fn(s, level) do
    pkind = params_kind(s.params_list)
    uses = fn_uses(s, pkind)

    acc = %{index: %{}, kinds: %{}, next: @header + 1, template: [], copies: []}
    acc = layout_params(acc, s, pkind)
    # The parameter slots by name, before a body `var` of the same name can
    # take another slot: the parameter defaults resolve through this map.
    param_index = acc.index
    {acc, hidden, self} = layout_hidden(acc, s, uses)
    acc = layout_vars(acc, s, pkind, uses)
    acc = layout_funs(acc, s, pkind)
    acc = layout_lex(acc, s)

    level_of = fn_level(s, uses)
    rewritten = is_integer(level) and level_of != nil and level_of <= level
    info = build_info(s, acc, uses, pkind, hidden, self, level_of, rewritten)

    Map.merge(s, %{
      info: info,
      index: acc.index,
      param_index: param_index,
      home: nil,
      rewritten: rewritten,
      next_slot: acc.next
    })
  end

  # Gives the next slot to `key`. A `var`, function or lexical slot has an
  # initial value in the template; a parameter or hidden slot has none.
  defp take(acc, key, kind, init \\ nil) do
    template = if init, do: [init | acc.template], else: acc.template

    %{
      acc
      | index: Map.put(acc.index, key, acc.next),
        kinds: Map.put(acc.kinds, acc.next, kind),
        next: acc.next + 1,
        template: template
    }
  end

  # Gives `name` a `var` slot of its own that the frame builder fills from
  # slot `from` at body entry.
  defp take_copy(acc, name, from) do
    to = acc.next
    acc = take(acc, name, :var, :undefined)
    %{acc | copies: [{from, to} | acc.copies]}
  end

  # The facts about the hidden bindings a function uses. An arrow owns none
  # of them; a constructor always has `this`.
  defp fn_uses(s, pkind) do
    ctor? = s.fn_kind in [:ctor, :derived_ctor]
    uses_arguments = s.uses_arguments and not s.arrow?

    # (syntactic, as `with_flags` in interp.ex: the body names the binding,
    # whether or not anything reads it; an arrow has no `:args` to build from)
    args_var =
      "arguments" in s.vars and "arguments" not in s.fun_names and
        "arguments" not in s.param_names

    %{
      ctor?: ctor?,
      # `super.x` reads `:home` and `:this` (classes.ex `super_base`).
      this: ((s.uses_this or s.uses_home) and not s.arrow?) or ctor?,
      arguments: uses_arguments,
      args_var: args_var,
      # `var arguments` keeps the object in the `var` slot (interp.ex
      # `call_frame`), unless a parameter initializer can close over the
      # object before the body binds the `var`: the object then needs a
      # hidden slot for the parameter phase (see `layout_vars`).
      arguments_slot: uses_arguments and (not args_var or pkind == :exprs),
      new_target: (s.uses_new_target and not s.arrow?) or s.uses_super_call,
      super: s.uses_super_call or s.uses_home
    }
  end

  # Group 1. Duplicate plain parameters: every position gets a slot, the last
  # position owns the name (`bind_plain`, `map_arguments`). A pattern binds
  # each name once.
  defp layout_params(acc, s, :plain),
    do: Enum.reduce(s.params_list, acc, fn {:id, n}, acc -> take(acc, n, :param) end)

  defp layout_params(acc, s, _pkind),
    do: Enum.reduce(s.param_names, acc, &take(&2, &1, :param))

  # Group 2. The hidden slots the function uses, in `@hidden_order`. Returns
  # the accumulator, the list of hidden slots and the self slot.
  defp layout_hidden(acc, s, uses) do
    wanted = [
      this: uses.this,
      args: uses.arguments,
      arguments: uses.arguments_slot,
      new_target: uses.new_target,
      home: s.uses_home,
      ctor_fn: s.uses_super_call,
      self: s.self != nil
    ]

    hidden = for h <- @hidden_order, wanted[h], do: h
    body_names = s.fun_names ++ for({n, _} <- s.lex, do: n)

    Enum.reduce(hidden, {acc, hidden, nil}, fn
      # The object sits under the name, unless the body takes the name once
      # it runs (a function, a lexical or a `var` of that name): then the
      # object is reachable from the parameter defaults only, under the atom.
      :arguments, {acc, hidden, self} ->
        key = if "arguments" in body_names or uses.args_var, do: :arguments, else: "arguments"
        {take(acc, key, :hidden), hidden, self}

      :self, {acc, hidden, _} ->
        {take(acc, s.self, :self), hidden, acc.next}

      h, {acc, hidden, self} ->
        {take(acc, h, :hidden), hidden, self}
    end)
  end

  # A parameter that a closure in a default value captured, when a body
  # `var` or function shares its name: the parameter keeps its slot and the
  # body name gets one of its own.
  defp own_slot?(s, pkind, n),
    do: n in s.param_names and pkind == :exprs and MapSet.member?(s.default_captured, n)

  # Group 3. A `var` with a parameter's name shares the slot, unless a closure
  # in a default value captured the parameter: the body must then get a slot
  # of its own with the parameter's value copied in (`hoist_into_body`).
  # `var arguments` under parameter initializers is the same case for the
  # arguments object: the `var` gets its own slot, filled from the object's
  # hidden slot, so that a closure made in an initializer keeps the object.
  defp layout_vars(acc, s, pkind, uses) do
    Enum.reduce(s.vars, acc, fn n, acc ->
      cond do
        own_slot?(s, pkind, n) ->
          take_copy(acc, n, acc.index[n])

        n == "arguments" and uses.args_var and uses.arguments_slot ->
          take_copy(acc, n, acc.index[:arguments])

        n in s.param_names ->
          acc

        true ->
          take(acc, n, :var, :undefined)
      end
    end)
  end

  # Group 4. A function declaration with a `var`'s name takes over the slot;
  # the hoist at entry writes the function into it. With a parameter's name
  # it shares the parameter's slot, unless a default's closure captured the
  # parameter: then it takes the body's own slot, the one `layout_vars` made
  # when a `var` shares the name too, or a new one.
  defp layout_funs(acc, s, pkind) do
    Enum.reduce(s.fun_names, acc, fn n, acc ->
      cond do
        n in s.param_names and not own_slot?(s, pkind, n) -> acc
        n in s.vars -> %{acc | kinds: Map.put(acc.kinds, acc.index[n], :fun)}
        true -> take(acc, n, :fun, :undefined)
      end
    end)
  end

  # Group 5. The body's lexical names, each in its TDZ at entry.
  defp layout_lex(acc, s),
    do: Enum.reduce(s.lex, acc, fn {n, k}, acc -> take(acc, n, k, :tdz) end)

  # The smallest level that can run the function with slots (design 3.2), or
  # `nil` for a dynamic function.
  defp fn_level(s, uses) do
    cond do
      s.dynamic ->
        nil

      s.async? or s.generator? ->
        4

      uses.arguments or uses.super or uses.ctor? or s.priv or
          (s.uses_new_target and not s.arrow?) ->
        3

      s.makes_closures ->
        2

      true ->
        1
    end
  end

  defp build_info(s, acc, uses, pkind, hidden, self, level_of, rewritten) do
    params = s.params_list
    rest? = match?({:rest, _}, List.last(params))
    nparams = if rest?, do: length(params) - 1, else: length(params)

    argmap =
      if uses.arguments and not s.strict and pkind == :plain and nparams > 0,
        do: Map.new(Enum.with_index(params), fn {{:id, n}, i} -> {n, i} end),
        else: nil

    %Info{
      src: nil,
      # (an arrow's position is `:fn`; the kind names the arrow, as the `Info` doc says,
      # so that a walk over frames can tell an arrow from a function with its own `this`)
      kind: if(s.arrow?, do: s.mode, else: s.fn_kind),
      name: s.name,
      level: level_of,
      rewritten: rewritten,
      strict: s.strict,
      async?: s.async?,
      generator?: s.generator?,
      dynamic: s.dynamic,
      params: pkind,
      nparams: nparams,
      rest?: rest?,
      size: acc.next - 1,
      slots: acc.index,
      hidden: hidden,
      kinds: acc.kinds,
      template: acc.template,
      hoist: [],
      copies: Enum.reverse(acc.copies),
      self: self,
      argmap: argmap,
      uses_this: uses.this,
      uses_arguments: uses.arguments,
      uses_new_target: uses.new_target,
      uses_super: uses.super,
      args_var: uses.args_var,
      makes_closures: s.makes_closures,
      has_await: s.has_await,
      captured: MapSet.new(),
      free: if(level_of == 1, do: :always, else: :counter),
      tail_sites: 0
    }
  end

  # A block-like scope: with a frame, its names get slots from 6 in a frame of
  # its own; without one, they get fresh slots in the home frame, so that a
  # shadowing `let` never shares a slot with the name it shadows. The template
  # is reversed while the layout grows, as a function's is; `finish_scope`
  # puts it in order.
  defp layout_block(scopes, sid, s) do
    names = Enum.reverse(s.order)
    home = home_of(scopes, sid)

    cond do
      names == [] ->
        Map.put(scopes, sid, Map.merge(s, %{index: %{}, home: home, scope: nil}))

      s.frame ->
        {index, kinds, next, template} = block_slots(names, s.decls, @header + 1)

        scope = %Scope{
          kind: s.kind,
          frame: true,
          slots: index,
          kinds: kinds,
          size: next - 1,
          template: template,
          per_iter: s.kind == :loop and s.head == :let
        }

        Map.put(
          scopes,
          sid,
          Map.merge(s, %{index: index, home: home, scope: scope, next_slot: next})
        )

      home == nil ->
        # Top-level code keeps today's map scopes; the names need no slots.
        Map.put(scopes, sid, Map.merge(s, %{index: %{}, home: nil, scope: nil}))

      true ->
        {index, kinds, next, template} = block_slots(names, s.decls, scopes[home].next_slot)
        tdz = for {n, i} <- index, s.decls[n] != :fun, do: i

        scope =
          if s.kind == :tdz,
            do: nil,
            else: %Scope{
              kind: s.kind,
              frame: false,
              slots: index,
              kinds: kinds,
              tdz: Enum.sort(tdz)
            }

        scopes = Map.put(scopes, sid, Map.merge(s, %{index: index, home: home, scope: scope}))
        home_add(scopes, home, next, kinds, template)
    end
  end

  # The slots of a block's names from `first`, with the reversed template: a
  # function declaration starts as `undefined`, every other name in its TDZ.
  defp block_slots(names, decls, first) do
    Enum.reduce(names, {%{}, %{}, first, []}, fn n, {index, kinds, next, template} ->
      k = decls[n]
      init = if k == :fun, do: :undefined, else: :tdz
      {Map.put(index, n, next), Map.put(kinds, next, k), next + 1, [init | template]}
    end)
  end

  # Adds the slots of a frameless scope to its home frame, a function or a
  # framed scope. Both keep their template reversed until `finish_scope`.
  defp home_add(scopes, home, next, kinds, template) do
    Map.update!(scopes, home, fn
      %{info: info} = h ->
        %{h | info: grow(info, next, kinds, template), next_slot: next}

      %{scope: scope} = h ->
        %{h | scope: grow(scope, next, kinds, template), next_slot: next}
    end)
  end

  defp grow(struct, next, kinds, template) do
    %{
      struct
      | size: next - 1,
        kinds: Map.merge(struct.kinds, kinds),
        template: template ++ struct.template
    }
  end

  # Turns the kinds map and the reversed template of a function layout into
  # their final shape and fills `captured` with slot indexes; puts the
  # template of a framed scope in order.
  defp finish_scope(scopes, sid, frameless) do
    case scopes[sid] do
      %{kind: :fn, info: info} = s ->
        slot_kinds = for i <- (@header + 1)..info.size//1, do: Map.fetch!(info.kinds, i)
        kinds = List.to_tuple([:parent, :rec, :caller, :call_pos, :root | slot_kinds])

        captured =
          s.captured
          |> Enum.flat_map(&captured_slots(info, &1))
          |> MapSet.new()

        captured =
          Enum.reduce(frameless, captured, fn c, acc ->
            Enum.reduce(c.captured, acc, &MapSet.put(&2, c.index[&1]))
          end)

        # A closure in a default value reads the parameter's own slot, which a
        # body `var` of the same name hides in `slots` (see `copies`). Any
        # other name it reads has the slot a body closure would read.
        captured =
          Enum.reduce(s.default_captured, captured, fn n, acc ->
            case s.param_index do
              %{^n => i} -> MapSet.put(acc, i)
              _ -> Enum.reduce(captured_slots(info, n), acc, &MapSet.put(&2, &1))
            end
          end)

        captured = captured |> Enum.reject(&is_nil/1) |> MapSet.new()
        info = %{info | kinds: kinds, template: Enum.reverse(info.template), captured: captured}
        Map.put(scopes, sid, %{s | info: info})

      %{kind: k, frame: true, scope: %Scope{} = sc} = s when k in @block_kinds ->
        Map.put(scopes, sid, %{s | scope: %{sc | template: Enum.reverse(sc.template)}})

      _ ->
        scopes
    end
  end

  # The slots that a captured name or flag stands for. `super()` reads
  # `:ctor_fn` and `:new_target` and writes `:this` (classes.ex `super_call`);
  # `super.x` reads `:home` and `:this` (`super_base`); the arguments object
  # sits under the atom or under the name (`layout_hidden`). A slot that the
  # layout did not make (an arrow's `this`, for example) comes back as `nil`.
  defp captured_slots(info, :uses_this), do: [info.slots[:this]]
  defp captured_slots(info, :uses_new_target), do: [info.slots[:new_target]]

  defp captured_slots(info, :uses_super_call),
    do: [info.slots[:ctor_fn], info.slots[:new_target], info.slots[:this]]

  defp captured_slots(info, :uses_home), do: [info.slots[:home], info.slots[:this]]
  defp captured_slots(info, :arguments), do: [info.slots[:arguments] || info.slots["arguments"]]
  defp captured_slots(info, n), do: [info.slots[n]]

  # ── pass 2: rewrite ────────────────────────────────────────

  # The state of pass 2: the finished scopes, the chain, the next number, the
  # resolve level, and the context of the function being walked: whether its
  # names are rewritten, its strictness, whether a `return` here can be a
  # tail call, whether statements with awaits are wrapped (`aw`) and whether
  # the statement being walked has met one (`awaited`), and the hoist lists
  # and tail counts collected per scope.
  defp rewrite(stmts, scopes, top, strict, level) do
    st = %{
      scopes: scopes,
      chain: [],
      next: 1,
      level: level,
      top: top,
      strict: strict,
      rewriting: false,
      tail_ok: false,
      aw: false,
      awaited: false,
      hoists: %{},
      tails: %{}
    }

    {_, st} = r_open(st, top_scope_kind(top), stmts)

    {stmts, st} =
      case tla_flags(stmts, top) do
        nil -> r_stmts(stmts, st)
        flags -> r_tla_stmts(Enum.zip(stmts, flags), st)
      end

    {stmts, r_close(st)}
  end

  defp r_open(st, kind, node) do
    sid = st.next

    s =
      case st.scopes do
        %{^sid => s} -> s
        _ -> raise("resolver: pass 2 found scope #{sid} that pass 1 did not number")
      end

    if s.kind != kind or s.node != node,
      do: raise("resolver: pass 2 meets scope #{sid} out of order (#{s.kind} vs #{kind})")

    # A block inside top-level code or inside an unrewritten function keeps
    # today's map scopes, which the hop count cannot see through.
    s = if kind in @block_kinds, do: Map.put(s, :modelled, st.rewriting), else: s
    st = %{st | scopes: Map.put(st.scopes, sid, s), chain: [sid | st.chain], next: sid + 1}
    {sid, st}
  end

  defp r_close(%{chain: [_ | rest]} = st), do: %{st | chain: rest}

  defp r_scope(st, sid), do: Map.fetch!(st.scopes, sid)

  defp r_tla_stmts(stmts_with_flags, st) do
    map_st(stmts_with_flags, st, fn
      {stmt, true}, st ->
        {_, st} = r_open(st, :cps_leaf, stmt)
        {stmt, st} = r_stmt(stmt, st)
        {stmt, r_close(st)}

      {stmt, false}, st ->
        r_stmt(stmt, st)
    end)
  end

  defp map_st(list, st, fun) do
    {out, st} =
      Enum.reduce(list, {[], st}, fn x, {acc, st} ->
        {y, st} = fun.(x, st)
        {[y | acc], st}
      end)

    {Enum.reverse(out), st}
  end

  # ── pass 2: name resolution ────────────────────────────────

  # Resolves a name along the chain. `role` is `:read`, `:write` (an
  # assignment, update or `for` head without a declaration) or `:bind` (a
  # declaration pattern). A hop-counted form needs every scope on the way to
  # be a frame or a modelled map scope; an unmodelled scope blocks it and the
  # name stays `{:id}`. A `{:gref}` passes through any scope that does not
  # declare the name.
  defp resolve(st, name, role), do: resolve(st, st.chain, name, role, 0, false)

  defp resolve(st, [], name, _role, _d, _blocked), do: top_form(st, name)

  defp resolve(st, [sid | rest], name, role, d, blocked) do
    s = r_scope(st, sid)

    if visible?(s, name) do
      kind = s.decls[name]

      cond do
        blocked -> {:id, name}
        s.kind == :fn and s.rewritten -> slot_form(s, name, kind, role, d, st)
        s.kind == :fn -> {:id, name}
        s.kind in @block_kinds and s.modelled -> slot_form(s, name, kind, role, d, st)
        s.kind in @block_kinds -> {:id, name}
        s.kind in @map_kinds -> {:mref, d, name}
        true -> {:id, name}
      end
    else
      resolve(st, rest, name, role, d + hops(s), blocked or blocks?(s))
    end
  end

  # A frame or a modelled map scope is one run-time scope on the way up; a
  # frameless block is none.
  defp hops(%{kind: :fn, rewritten: true}), do: 1
  defp hops(%{kind: k} = s) when k in @block_kinds, do: if(s.modelled and s.frame, do: 1, else: 0)
  defp hops(%{kind: k}) when k in @map_kinds, do: 1
  defp hops(_), do: 0

  defp blocks?(%{kind: :fn, rewritten: false}), do: true
  defp blocks?(%{kind: k, modelled: false}) when k in @block_kinds, do: true
  defp blocks?(%{kind: :cps_leaf}), do: true
  defp blocks?(%{kind: :with}), do: true
  defp blocks?(_), do: false

  # The chain ran out: the name is global, or unknown. Direct eval code has no
  # `{:gref}`: its free names and sloppy `var`s live in scopes the resolver
  # does not see.
  defp top_form(%{top: :eval}, name), do: {:id, name}
  defp top_form(_, name), do: {:gref, name}

  defp slot_form(s, name, kind, role, d, st) do
    i = slot_index(s, name)

    case {role, kind} do
      {:write, k} when k in [:const, :using, :import] -> {:cslot, d, i, name}
      {:write, :self} -> if st.strict, do: {:cslot, d, i, name}, else: {:fname, d, i, name}
      {:write, :param} -> mapped_or_slot(s, name, d, i)
      _ -> {:slot, d, i, name}
    end
  end

  # In the parameter phase a name is the parameter's slot, even when the body's
  # `var` of that name has a slot of its own: the defaults run before the body
  # is bound (interp.ex `hoist_into_body`), so a closure made there must read
  # the parameter.
  defp slot_index(%{kind: :fn, phase: :params, param_index: %{} = pi}, name)
       when is_map_key(pi, name),
       do: Map.fetch!(pi, name)

  defp slot_index(s, name), do: Map.fetch!(s.index, name)

  # A write to a parameter of a function with a mapped `arguments` object
  # must update the object too.
  defp mapped_or_slot(%{kind: :fn, info: %{argmap: %{} = argmap}}, name, d, i) do
    case argmap do
      %{^name => k} -> {:mslot, d, i, name, k}
      _ -> {:slot, d, i, name}
    end
  end

  defp mapped_or_slot(_, name, d, i), do: {:slot, d, i, name}

  # `arguments` without a declaration of that name belongs to the nearest
  # function that is not an arrow; with one it is an ordinary name.
  defp resolve_arguments(st, role), do: resolve_arguments(st, st.chain, role, 0, false)

  defp resolve_arguments(_st, [], _role, _d, _blocked), do: {:id, "arguments"}

  defp resolve_arguments(st, [sid | rest], role, d, blocked) do
    s = r_scope(st, sid)

    cond do
      # In the parameter phase the object is under the atom when the body
      # takes the name later (a lexical, a function or a `var` of that name);
      # in the body phase `var arguments` holds it under the name.
      s.kind == :fn and not s.arrow? and
          (not visible?(s, "arguments") or s.decls["arguments"] == :var) ->
        cond do
          blocked or not s.rewritten ->
            {:id, "arguments"}

          s.phase == :params ->
            {:slot, d, Map.get(s.index, :arguments) || Map.fetch!(s.index, "arguments"),
             "arguments"}

          true ->
            {:slot, d, Map.get(s.index, "arguments") || Map.fetch!(s.index, :arguments),
             "arguments"}
        end

      visible?(s, "arguments") ->
        resolve(st, [sid | rest], "arguments", role, d, blocked)

      s.kind in [:field, :static, :static_block] ->
        {:id, "arguments"}

      true ->
        resolve_arguments(st, rest, role, d + hops(s), blocked or blocks?(s))
    end
  end

  # `this` and `new.target` of the nearest function that is not an arrow. A
  # field or static scope owns them too, but by name.
  defp resolve_owner(st, key, node), do: resolve_owner(st, st.chain, key, node, 0, false)

  defp resolve_owner(_st, [], _key, node, _d, _blocked), do: node

  defp resolve_owner(st, [sid | rest], key, node, d, blocked) do
    s = r_scope(st, sid)

    cond do
      s.kind == :fn and not s.arrow? ->
        cond do
          blocked or not s.rewritten -> node
          key == :this -> {:this, d, Map.fetch!(s.index, :this)}
          true -> {:slot, d, Map.fetch!(s.index, key), key}
        end

      s.kind in [:field, :static, :static_block] ->
        node

      true ->
        resolve_owner(st, rest, key, node, d + hops(s), blocked or blocks?(s))
    end
  end

  # ── pass 2: statements ─────────────────────────────────────

  defp r_stmts(stmts, st), do: map_st(stmts, st, &r_stmt/2)

  # A function declaration met in a statement list is hoisted into the
  # current scope's frame. The same node as the sole branch of an `if` or a
  # labeled body is never instantiated, so `r_substmt` only resolves it.
  defp r_substmt({:fundecl, n, f}, st) do
    {f, st} = r_function(f, st)
    {{:fundecl, n, f}, st}
  end

  defp r_substmt(stmt, st), do: r_stmt(stmt, st)

  # Inside the body of a rewritten async or generator function, a statement
  # that awaits is wrapped so that the CPS evaluator knows without a walk.
  # The walk of the statement itself sets `awaited` when it meets an await,
  # a yield, a `for await` or an `await using` (the test of `awaits?/1`), and
  # a nested function keeps its awaits to itself (`r_function`). The flag of
  # the statement around this one stays set when this one awaited.
  defp r_stmt(stmt, %{aw: true} = st) do
    outer = st.awaited
    {out, st} = r_stmt1(stmt, %{st | awaited: false})
    awaited = st.awaited
    st = %{st | awaited: outer or awaited}
    if awaited, do: {{:aw, out}, st}, else: {out, st}
  end

  defp r_stmt(stmt, st), do: r_stmt1(stmt, st)

  defp r_awaited(st), do: %{st | awaited: true}

  defp r_stmt1({:pos, _} = p, st), do: {p, st}
  defp r_stmt1({:empty} = e, st), do: {e, st}

  defp r_stmt1({:expr, e}, st) do
    {e, st} = r_expr(e, st)
    {{:expr, e}, st}
  end

  defp r_stmt1({:var, kind, decls}, st) do
    mode = if kind == :var, do: :write, else: :bind

    {decls, st} =
      map_st(decls, st, fn {pat, init}, st ->
        {init, st} = if init, do: r_expr(init, st), else: {nil, st}
        {pat, st} = r_pat(pat, mode, st)
        {{pat, init}, st}
      end)

    {{:var, kind, decls}, st}
  end

  defp r_stmt1({:using, kind, name, init, rest}, st) do
    st = if kind == :await_using, do: r_awaited(st), else: st
    {init, st} = r_expr(init, st)
    target = if st.rewriting, do: resolve(st, name, :bind), else: name
    # The rest of the list runs under the `using` cleanup, where a `return`
    # cannot be a tail call (interp.ex `no_tail`).
    {rest, st} = with_tail(st, false, &r_stmts(rest, &1))
    {{:using, kind, target, init, rest}, st}
  end

  defp r_stmt1({:fundecl, n, f}, st) do
    {f, st} = r_function(f, st)
    {{:fundecl, n, f}, r_hoist(st, n, f)}
  end

  defp r_stmt1({:return, nil} = r, st), do: {r, st}

  # Inside a rewritten function every `return` with a value carries a marker: `:tail` for
  # a tail site, `:plain` for the others. The evaluator then never reads the run-time tail
  # flag inside such a function, so a stale flag from a caller cannot turn a plain return
  # into a tail call.
  defp r_stmt1({:return, e}, st) do
    {e2, st} = r_expr(e, st)

    cond do
      st.tail_ok and tail_expr?(e) -> {{:return, e2, :tail}, r_tail(st)}
      st.rewriting -> {{:return, e2, :plain}, st}
      true -> {{:return, e2}, st}
    end
  end

  defp r_stmt1({:throw, e}, st) do
    {e, st} = r_expr(e, st)
    {{:throw, e}, st}
  end

  defp r_stmt1({:if, c, a, b}, st) do
    {c, st} = r_expr(c, st)
    {a, st} = r_substmt(a, st)
    {b, st} = if b, do: r_substmt(b, st), else: {nil, st}
    {{:if, c, a, b}, st}
  end

  defp r_stmt1({:labeled, l, s}, st) do
    {s, st} = r_substmt(s, st)
    {{:labeled, l, s}, st}
  end

  defp r_stmt1({:while, c, body}, st) do
    {c, st} = r_expr(c, st)
    {body, st} = r_substmt(body, st)
    {{:while, c, body}, st}
  end

  defp r_stmt1({:dowhile, body, c}, st) do
    {body, st} = r_substmt(body, st)
    {c, st} = r_expr(c, st)
    {{:dowhile, body, c}, st}
  end

  defp r_stmt1({:break, _} = b, st), do: {b, st}
  defp r_stmt1({:continue, _} = c, st), do: {c, st}

  defp r_stmt1({:block, stmts}, st) do
    {sid, st} = r_open(st, :block, stmts)
    {stmts, st} = r_stmts(stmts, st)
    {sc, st} = r_leave(st, sid)
    {with_scope({:block, stmts}, sc), st}
  end

  defp r_stmt1({:for, init, test, update, body}, st) do
    {sid, st} = r_open(st, :loop, {init, test, update, body})

    {init, st} =
      case init do
        {:var, _, _} -> r_stmt1(init, st)
        {:expr, e} -> with_st(r_expr(e, st), &{:expr, &1})
        nil -> {nil, st}
      end

    {test, st} = if test, do: r_expr(test, st), else: {nil, st}
    {update, st} = if update, do: r_expr(update, st), else: {nil, st}
    {body, st} = r_substmt(body, st)
    {sc, st} = r_leave(st, sid)
    {with_scope({:for, init, test, update, body}, sc), st}
  end

  defp r_stmt1({k, decl, pat, obj, body}, st) when k in [:forin, :forof, :forawait] do
    st = if k == :forawait, do: r_awaited(st), else: st
    {sid, st} = r_open(st, :each, {decl, pat, obj, body})
    {obj, st} = r_expr(obj, st)
    {pat, st} = r_pat(pat, if(decl in [:let, :const], do: :bind, else: :write), st)
    # The body of a for-in/of loop runs under the iterator's cleanup, where a
    # `return` cannot be a tail call (interp.ex `no_tail`).
    {body, st} = with_tail(st, false, &r_substmt(body, &1))
    {sc, st} = r_leave(st, sid)
    {with_scope({k, decl, pat, obj, body}, sc), st}
  end

  defp r_stmt1({:switch, disc, cases}, st) do
    {disc, st} = r_expr(disc, st)
    {sid, st} = r_open(st, :switch, cases)

    {cases, st} =
      map_st(cases, st, fn {test, body}, st ->
        {test, st} = if test == :default, do: {test, st}, else: r_expr(test, st)
        {body, st} = r_stmts(body, st)
        {{test, body}, st}
      end)

    {sc, st} = r_leave(st, sid)
    {with_scope({:switch, disc, cases}, sc), st}
  end

  defp r_stmt1({:try, block, param, handler, finalizer}, st) do
    {block, st} = with_tail(st, false, &r_substmt(block, &1))
    {sid, st} = r_open(st, :catch, {param, handler})
    {param, st} = if param, do: r_pat(param, :bind, st), else: {nil, st}

    {handler, st} =
      if handler,
        do: with_tail(st, st.tail_ok and finalizer == nil, &r_substmt(handler, &1)),
        else: {nil, st}

    {sc, st} = r_leave(st, sid)
    {finalizer, st} = if finalizer, do: r_substmt(finalizer, st), else: {nil, st}
    {with_scope({:try, block, param, handler, finalizer}, sc), st}
  end

  defp r_stmt1({:with, obj, body}, st) do
    {obj, st} = r_expr(obj, st)
    {_, st} = r_open(st, :with, body)
    {body, st} = r_substmt(body, st)
    {{:with, obj, body}, r_close(st)}
  end

  defp r_stmt1({:import, _, _} = i, st), do: {i, st}

  defp r_stmt1({:export, stmt}, st) do
    {stmt, st} = r_stmt1(stmt, st)
    {{:export, stmt}, st}
  end

  defp r_stmt1({:export_default, {:fundecl, n, f}}, st) do
    {f, st} = r_function(f, st)
    {{:export_default, {:fundecl, n, f}}, st}
  end

  defp r_stmt1({:export_default, {:classdecl, n, c}}, st) do
    {c, st} = r_class(c, st)
    {{:export_default, {:classdecl, n, c}}, st}
  end

  defp r_stmt1({:export_default, {:expr, e}}, st) do
    {e, st} = r_expr(e, st)
    {{:export_default, {:expr, e}}, st}
  end

  defp r_stmt1({:export_names, _} = e, st), do: {e, st}
  defp r_stmt1({:export_from, _, _} = e, st), do: {e, st}
  defp r_stmt1(other, _st), do: raise("resolver: unknown statement #{inspect(other, limit: 5)}")

  defp with_st({x, st}, fun), do: {fun.(x), st}

  defp with_tail(st, tail_ok, fun) do
    old = st.tail_ok
    {out, st} = fun.(%{st | tail_ok: tail_ok})
    {out, %{st | tail_ok: old}}
  end

  # Leaves a block-like scope and gives its `Scope` (with the hoist list) when
  # the current function is rewritten, or `nil` otherwise.
  defp r_leave(st, sid) do
    s = r_scope(st, sid)
    hoist = Enum.reverse(Map.get(st.hoists, sid, []))
    st = %{st | hoists: Map.delete(st.hoists, sid)}
    st = r_close(st)

    cond do
      not st.rewriting -> {:unmodelled, st}
      s.scope == nil -> {nil, st}
      true -> {%{s.scope | hoist: hoist}, st}
    end
  end

  defp with_scope(node, :unmodelled), do: node
  defp with_scope(node, sc), do: Tuple.insert_at(node, tuple_size(node), sc)

  # Records a hoisted function for the scope that declares it.
  defp r_hoist(st, name, node) do
    [sid | _] = st.chain
    s = r_scope(st, sid)

    case s[:index] do
      %{^name => slot} ->
        %{st | hoists: Map.update(st.hoists, sid, [{slot, node}], &[{slot, node} | &1])}

      _ ->
        st
    end
  end

  defp r_tail(st) do
    case Enum.find(st.chain, &(r_scope(st, &1).kind == :fn)) do
      nil -> st
      sid -> %{st | tails: Map.update(st.tails, sid, 1, &(&1 + 1))}
    end
  end

  # ── pass 2: patterns and expressions ───────────────────────

  defp r_pat({:id, "arguments"}, mode, %{rewriting: true} = st),
    do: {resolve_arguments(st, mode), st}

  defp r_pat({:id, n}, mode, %{rewriting: true} = st), do: {resolve(st, n, mode), st}
  defp r_pat({:id, _} = p, _mode, st), do: {p, st}

  defp r_pat({:default, p, e}, mode, st) do
    {e, st} = r_expr(e, st)
    {p, st} = r_pat(p, mode, st)
    {{:default, p, e}, st}
  end

  defp r_pat({:rest, p}, mode, st) do
    {p, st} = r_pat(p, mode, st)
    {{:rest, p}, st}
  end

  defp r_pat({:arrpat, elems}, mode, st) do
    {elems, st} =
      map_st(elems, st, fn
        nil, st -> {nil, st}
        p, st -> r_pat(p, mode, st)
      end)

    {{:arrpat, elems}, st}
  end

  defp r_pat({:objpat, props, rest}, mode, st) do
    {props, st} =
      map_st(props, st, fn {key, p}, st ->
        {key, st} = r_key(key, st)
        {p, st} = r_pat(p, mode, st)
        {{key, p}, st}
      end)

    {rest, st} = if rest, do: r_pat(rest, mode, st), else: {nil, st}
    {{:objpat, props, rest}, st}
  end

  defp r_pat({:member, _, _, _} = m, _mode, st), do: r_expr(m, st)
  defp r_pat({:call, _, _, _} = c, _mode, st), do: r_expr(c, st)

  defp r_pat(other, _mode, _st),
    do: raise("resolver: unknown pattern #{inspect(other, limit: 5)}")

  # The keys `a_key` accepts; an unknown key raises here as it does in pass 1.
  defp r_key({:computed, e}, st), do: with_st(r_expr(e, st), &{:computed, &1})
  defp r_key({:str, _} = key, st), do: {key, st}
  defp r_key({:priv, _} = key, st), do: {key, st}

  defp r_exprs(es, st), do: map_st(es, st, &r_expr/2)

  defp r_expr({:id, "arguments"} = e, st),
    do: {if(st.rewriting, do: resolve_arguments(st, :read), else: e), st}

  defp r_expr({:id, n} = e, st), do: {if(st.rewriting, do: resolve(st, n, :read), else: e), st}

  defp r_expr({:this} = e, st),
    do: {if(st.rewriting, do: resolve_owner(st, :this, e), else: e), st}

  defp r_expr({:new_target} = e, st),
    do: {if(st.rewriting, do: resolve_owner(st, :new_target, e), else: e), st}

  defp r_expr({:super} = e, st), do: {e, st}

  defp r_expr({:super_member, k}, st) do
    {k, st} = r_key_or_expr(k, st)
    {{:super_member, k}, st}
  end

  defp r_expr({:fn, _, _, _, _, _} = f, st), do: r_function(f, st)
  defp r_expr({:gen, _} = f, st), do: r_function(f, st)
  defp r_expr({:async, _} = f, st), do: r_function(f, st)
  defp r_expr({:unnamed, e}, st), do: with_st(r_expr(e, st), &{:unnamed, &1})
  defp r_expr({:class, _, _, _, _} = c, st), do: r_class(c, st)

  defp r_expr({:member, o, k, opt}, st) do
    {o, st} = r_expr(o, st)
    {k, st} = r_key_or_expr(k, st)
    {{:member, o, k, opt}, st}
  end

  defp r_expr({:chain, e}, st), do: with_st(r_expr(e, st), &{:chain, &1})

  defp r_expr({:call, callee, args, opt}, st) do
    {callee, st} = r_expr(callee, st)
    {args, st} = r_args(args, st)
    {{:call, callee, args, opt}, st}
  end

  defp r_expr({:new, callee, args}, st) do
    {callee, st} = r_expr(callee, st)
    {args, st} = r_args(args, st)
    {{:new, callee, args}, st}
  end

  defp r_expr({:tmpl, parts}, st) do
    {parts, st} =
      map_st(parts, st, fn p, st -> if is_binary(p), do: {p, st}, else: r_expr(p, st) end)

    {{:tmpl, parts}, st}
  end

  defp r_expr({:array, elems}, st) do
    {elems, st} =
      map_st(elems, st, fn
        :hole, st -> {:hole, st}
        {:spread, e}, st -> with_st(r_expr(e, st), &{:spread, &1})
        e, st -> r_expr(e, st)
      end)

    {{:array, elems}, st}
  end

  defp r_expr({:object, props}, st) do
    {props, st} =
      map_st(props, st, fn
        # (a method, a getter or a setter is a function node; pass 1 fixed
        # its kind, so pass 2 walks every property value the same way)
        {:init, key, v}, st ->
          {key, st} = r_key(key, st)
          {v, st} = r_expr(v, st)
          {{:init, key, v}, st}

        {:getter, key, f}, st ->
          {key, st} = r_key(key, st)
          {f, st} = r_function(f, st)
          {{:getter, key, f}, st}

        {:setter, key, f}, st ->
          {key, st} = r_key(key, st)
          {f, st} = r_function(f, st)
          {{:setter, key, f}, st}

        {:spread, e}, st ->
          with_st(r_expr(e, st), &{:spread, &1})

        {:proto, e}, st ->
          with_st(r_expr(e, st), &{:proto, &1})
      end)

    {{:object, props}, st}
  end

  # `delete x` and `typeof x` keep their operand in slot form: the evaluator
  # answers `false` for a slot without a lookup and `"undefined"` for an
  # unresolved global.
  defp r_expr({:unary, op, e}, st) do
    {e, st} = r_expr(e, st)
    {{:unary, op, e}, st}
  end

  defp r_expr({:binary, op, l, r}, st) do
    {l, st} = r_expr(l, st)
    {r, st} = r_expr(r, st)
    {{:binary, op, l, r}, st}
  end

  defp r_expr({:logical, op, l, r}, st) do
    {l, st} = r_expr(l, st)
    {r, st} = r_expr(r, st)
    {{:logical, op, l, r}, st}
  end

  defp r_expr({:cond, c, a, b}, st) do
    {c, st} = r_expr(c, st)
    {a, st} = r_expr(a, st)
    {b, st} = r_expr(b, st)
    {{:cond, c, a, b}, st}
  end

  defp r_expr({:seq, es}, st), do: with_st(r_exprs(es, st), &{:seq, &1})

  defp r_expr({k, op, prefix, target}, st) when k in [:update, :supdate] do
    {target, st} = r_target(target, st)
    {{k, op, prefix, target}, st}
  end

  defp r_expr({k, op, target, value}, st) when k in [:assign, :sassign] do
    {target, st} = r_target(target, st)
    {value, st} = r_expr(value, st)
    {{k, op, target, value}, st}
  end

  defp r_expr({:destructure, pat, right}, st) do
    {right, st} = r_expr(right, st)
    {pat, st} = r_pat(pat, :write, st)
    {{:destructure, pat, right}, st}
  end

  defp r_expr({:await, e}, st), do: with_st(r_expr(e, r_awaited(st)), &{:await, &1})

  defp r_expr({:yield, e, d}, st) do
    {e, st} = r_expr(e, r_awaited(st))
    {{:yield, e, d}, st}
  end

  defp r_expr({:spread, e}, st), do: with_st(r_expr(e, st), &{:spread, &1})
  defp r_expr({:import_call, e}, st), do: with_st(r_expr(e, st), &{:import_call, &1})

  defp r_expr({:import_call, e, o}, st) do
    {e, st} = r_expr(e, st)
    {o, st} = r_expr(o, st)
    {{:import_call, e, o}, st}
  end

  defp r_expr({:import_phase, p, args}, st) do
    {args, st} = r_exprs(args, st)
    {{:import_phase, p, args}, st}
  end

  defp r_expr({:tdz_names, names, e}, st) do
    {_, st} = r_open(st, :tdz, names)
    {e, st} = r_expr(e, st)
    st = r_close(st)
    {if(st.rewriting, do: {:in_tdz, names, e}, else: {:tdz_names, names, e}), st}
  end

  defp r_expr({:num, _} = e, st), do: {e, st}
  defp r_expr({:bigint, _} = e, st), do: {e, st}
  defp r_expr({:str, _} = e, st), do: {e, st}
  defp r_expr({:lit, _} = e, st), do: {e, st}
  defp r_expr({:regex, _, _} = e, st), do: {e, st}
  defp r_expr({:val, _} = e, st), do: {e, st}
  defp r_expr({:tagged_strings, _, _, _} = e, st), do: {e, st}
  defp r_expr({:import_meta} = e, st), do: {e, st}
  defp r_expr({:priv_ref, _} = e, st), do: {e, st}
  defp r_expr(other, _st), do: raise("resolver: unknown expression #{inspect(other, limit: 5)}")

  defp r_target({:id, "arguments"} = t, st),
    do: {if(st.rewriting, do: resolve_arguments(st, :write), else: t), st}

  defp r_target({:id, n} = t, st), do: {if(st.rewriting, do: resolve(st, n, :write), else: t), st}
  defp r_target(other, st), do: r_expr(other, st)

  defp r_args(args, st) do
    map_st(args, st, fn
      {:spread, e}, st -> with_st(r_expr(e, st), &{:spread, &1})
      e, st -> r_expr(e, st)
    end)
  end

  defp r_key_or_expr({:str, _} = k, st), do: {k, st}
  defp r_key_or_expr({:priv, _} = k, st), do: {k, st}
  defp r_key_or_expr(e, st), do: r_expr(e, st)

  # ── pass 2: functions and classes ──────────────────────────

  # The kind of the function and its self name were fixed in pass 1; pass 2
  # reads them from the scope record. An await inside the function belongs to
  # the function, not to the statement around it, so `awaited` is restored.
  defp r_function(node, st) do
    {{:fn, name, params, body, mode, src}, _} = unwrap(node, %{})
    {sid, st} = r_open(st, :fn, node)
    s = r_scope(st, sid)
    info = s.info

    outer = Map.take(st, [:rewriting, :strict, :tail_ok, :aw, :awaited])

    tail_ok =
      s.rewritten and s.strict and not s.async? and not s.generator? and
        s.fn_kind not in [:ctor, :derived_ctor] and mode != :arrow_expr

    st = %{
      st
      | rewriting: s.rewritten,
        strict: s.strict,
        tail_ok: tail_ok,
        aw: s.rewritten and (s.async? or s.generator?)
    }

    st = r_phase(st, sid, :params)
    {params, st} = with_aw(st, false, fn st -> map_st(params, st, &r_pat(&1, :bind, &2)) end)
    st = r_phase(st, sid, :body)

    {body, st} =
      if mode == :arrow_expr, do: with_aw(st, false, &r_expr(body, &1)), else: r_stmts(body, st)

    hoist = Enum.reverse(Map.get(st.hoists, sid, []))
    tails = Map.get(st.tails, sid, 0)
    st = %{st | hoists: Map.delete(st.hoists, sid), tails: Map.delete(st.tails, sid)}
    st = Map.merge(r_close(st), outer)

    info = %{info | src: src, hoist: hoist, tail_sites: tails}
    {rewrap(node, {:fn, name, params, body, mode, info}), st}
  end

  defp r_phase(st, sid, phase),
    do: %{st | scopes: Map.update!(st.scopes, sid, &%{&1 | phase: phase})}

  defp with_aw(st, aw, fun) do
    old = st.aw
    {out, st} = fun.(%{st | aw: aw})
    {out, %{st | aw: old}}
  end

  defp r_class({:class, name, heritage, members, src} = node, st) do
    decorated? = match?({:decorations, _, _}, List.last(members))
    {{class_decs, member_decs}, plain_members} = split_decorations(members)
    {class_decs, st} = r_exprs(class_decs, st)

    {_, st} = r_open(st, :class, node)
    outer_strict = st.strict
    st = %{st | strict: true}
    {heritage, st} = if heritage, do: r_expr(heritage, st), else: {nil, st}
    {field_sid, st} = r_open(st, :field, {:field, node})
    st = r_close(st)
    {static_sid, st} = r_open(st, :static, {:static, node})
    st = r_close(st)

    {members, {member_decs, st}} =
      plain_members
      |> Enum.with_index()
      |> Enum.map_reduce({member_decs, st}, fn {member, i}, {member_decs, st} ->
        {member_decs, st} =
          case member_decs do
            %{^i => decs} ->
              {decs, st} = r_exprs(decs, st)
              {Map.put(member_decs, i, decs), st}

            _ ->
              {member_decs, st}
          end

        {member, st} = r_member(member, field_sid, static_sid, st)
        {member, {member_decs, st}}
      end)

    st = %{st | strict: outer_strict}
    st = r_close(st)

    members =
      if decorated?,
        do: members ++ [{:decorations, class_decs, member_decs}],
        else: members

    {{:class, name, heritage, members, src}, st}
  end

  defp r_member({:cmember, kind, key, f, static?}, _, _, st)
       when kind in [:method, :get, :set] do
    {key, st} = r_key(key, st)
    {f, st} = r_function(f, st)
    {{:cmember, kind, key, f, static?}, st}
  end

  # A field initializer runs in the field or static scope. When a direct
  # `eval` made that scope dynamic, its initializers keep their names, as the
  # statements of a static block do: the eval code can add names to the
  # scope, and the direct eval itself must keep its `{:id, "eval"}` callee
  # for the interpreter to recognise it.
  defp r_member({:cmember, kind, key, init, static?}, field_sid, static_sid, st)
       when kind in [:field, :accessor] do
    {key, st} = r_key(key, st)

    {init, st} =
      if init do
        sid = if static?, do: static_sid, else: field_sid
        outer = Map.take(st, [:rewriting, :chain])
        rewriting = st.rewriting and not r_scope(st, sid).dynamic
        st = %{st | chain: [sid | st.chain], rewriting: rewriting}
        {init, st} = r_expr(init, st)
        {init, Map.merge(st, outer)}
      else
        {nil, st}
      end

    {{:cmember, kind, key, init, static?}, st}
  end

  # A static block is top-level code of its own scope: its statements keep
  # their shapes and names, and only the functions inside it are rewritten.
  defp r_member({:cmember, :block, nil, stmts, true}, _, static_sid, st) do
    st = %{st | chain: [static_sid | st.chain]}
    {_, st} = r_open(st, :static_block, stmts)
    outer = Map.take(st, [:rewriting, :tail_ok, :aw])
    st = %{st | rewriting: false, tail_ok: false, aw: false}
    {stmts, st} = r_stmts(stmts, st)
    st = Map.merge(st, outer)
    st = st |> r_close() |> r_close()
    {{:cmember, :block, nil, stmts, true}, st}
  end

  # ── strip ──────────────────────────────────────────────────

  @doc """
  Removes everything the resolver added: the `Info` of every function node,
  the trailing `Scope` of statements, and every slot form. The result of
  `strip(program(ast, level: n))` equals `ast`.
  """
  @spec strip(term) :: term
  def strip({:fn, name, params, body, mode, %Info{src: src}}),
    do: {:fn, name, strip(params), strip(body), mode, src}

  def strip({:slot, _, _, :new_target}), do: {:new_target}
  def strip({:slot, _, _, name}), do: {:id, name}
  def strip({:cslot, _, _, name}), do: {:id, name}
  def strip({:fname, _, _, name}), do: {:id, name}
  def strip({:mslot, _, _, name, _}), do: {:id, name}
  def strip({:mref, _, name}), do: {:id, name}
  def strip({:gref, name}), do: {:id, name}
  def strip({:this, _, _}), do: {:this}
  def strip({:in_tdz, names, e}), do: {:tdz_names, names, strip(e)}
  def strip({:return, e, :tail}), do: {:return, strip(e)}
  def strip({:return, e, :plain}), do: {:return, strip(e)}
  def strip({:aw, s}), do: strip(s)

  def strip({:block, stmts, sc}) when is_nil(sc) or is_struct(sc, Scope),
    do: {:block, strip(stmts)}

  def strip({:for, i, t, u, b, sc}) when is_nil(sc) or is_struct(sc, Scope),
    do: {:for, strip(i), strip(t), strip(u), strip(b)}

  def strip({k, d, p, o, b, sc})
      when k in [:forin, :forof, :forawait] and (is_nil(sc) or is_struct(sc, Scope)),
      do: {k, d, strip(p), strip(o), strip(b)}

  def strip({:switch, d, cases, sc}) when is_nil(sc) or is_struct(sc, Scope),
    do: {:switch, strip(d), strip(cases)}

  def strip({:try, b, p, h, f, sc}) when is_nil(sc) or is_struct(sc, Scope),
    do: {:try, strip(b), strip(p), strip(h), strip(f)}

  def strip({:using, k, {:slot, _, _, name}, init, rest}),
    do: {:using, k, name, strip(init), strip(rest)}

  def strip(t) when is_tuple(t), do: t |> Tuple.to_list() |> Enum.map(&strip/1) |> List.to_tuple()
  def strip(l) when is_list(l), do: Enum.map(l, &strip/1)
  def strip(%MapSet{} = s), do: s
  def strip(%{__struct__: _} = s), do: s
  def strip(m) when is_map(m), do: Map.new(m, fn {k, v} -> {k, strip(v)} end)
  def strip(x), do: x

  # ── check ──────────────────────────────────────────────────

  @doc """
  Checks a resolved program: every slot index is below the size of the frame
  it lands on, every depth reaches a scope that declares the name, no form
  appears in an unrewritten function or in top-level code, and no struct
  holds a run-time reference. Returns `:ok` or `{:error, message}`.

  The option `top:` names the kind of the top-level code (`:script`,
  `:module`, `:eval` or `:global_eval`); without it a program with an import
  or export is a module and any other program is a script.
  """
  @spec check({:program, [term]}, keyword) :: :ok | {:error, String.t()}
  def check({:program, stmts}, opts \\ []) do
    top =
      Keyword.get(opts, :top) || if(Enum.any?(stmts, &module_stmt?/1), do: :module, else: :script)

    names =
      case top do
        :script ->
          MapSet.new()

        _ ->
          MapSet.new(
            imports(stmts) ++
              var_names(stmts) ++
              for({n, _} <- fundecls(stmts), do: n) ++ for({n, _} <- lexicals(stmts), do: n)
          )
      end

    ctx = %{chain: [{:top, top, names}], rewriting: false}

    try do
      c_stmts(stmts, ctx)
      :ok
    catch
      {:check, msg} -> {:error, msg}
    end
  end

  # (a top-level `using` owns the statements after it, imports and exports
  # included)
  defp module_stmt?({k, _, _}) when k in [:import, :export_from], do: true
  defp module_stmt?({k, _}) when k in [:export, :export_default, :export_names], do: true
  defp module_stmt?({:using, _, _, _, rest}), do: Enum.any?(rest, &module_stmt?/1)
  defp module_stmt?(_), do: false

  defp fail(msg), do: throw({:check, msg})

  # The chain of `check`: `{:frame, slots, size}` for a function frame or a
  # framed scope, `{:frameless, slots}` for a frameless scope, `{:map, names}`
  # for a map scope, `{:blocked}` for a scope the hop count cannot cross, and
  # `{:top, kind, names}` at the end.
  defp c_push(ctx, entry), do: %{ctx | chain: [entry | ctx.chain]}

  defp c_stmts(stmts, ctx), do: Enum.each(stmts, &c_stmt(&1, ctx))

  defp c_stmt({:aw, s}, ctx) do
    unless ctx.rewriting, do: fail("{:aw} outside a rewritten function")
    c_stmt(s, ctx)
  end

  defp c_stmt({:pos, _}, _ctx), do: :ok
  defp c_stmt({:empty}, _ctx), do: :ok
  defp c_stmt({:expr, e}, ctx), do: c_expr(e, ctx)

  defp c_stmt({:var, _, decls}, ctx) do
    Enum.each(decls, fn {pat, init} ->
      if init, do: c_expr(init, ctx)
      c_pat(pat, ctx)
    end)
  end

  defp c_stmt({:using, _, name, init, rest}, ctx) do
    c_expr(init, ctx)
    if is_tuple(name), do: c_form(name, ctx)
    c_stmts(rest, ctx)
  end

  defp c_stmt({:fundecl, _, f}, ctx), do: c_expr(f, ctx)
  defp c_stmt({:return, nil}, _ctx), do: :ok

  defp c_stmt({:return, e}, ctx) do
    if ctx.rewriting, do: fail("a return without a marker inside a rewritten function")
    c_expr(e, ctx)
  end

  defp c_stmt({:return, e, mark}, ctx) when mark in [:tail, :plain] do
    unless ctx.rewriting, do: fail("#{mark} return outside a rewritten function")
    c_expr(e, ctx)
  end

  defp c_stmt({:throw, e}, ctx), do: c_expr(e, ctx)

  defp c_stmt({:if, c, a, b}, ctx) do
    c_expr(c, ctx)
    c_stmt(a, ctx)
    if b, do: c_stmt(b, ctx)
  end

  defp c_stmt({:labeled, _, s}, ctx), do: c_stmt(s, ctx)

  defp c_stmt({:while, c, b}, ctx) do
    c_expr(c, ctx)
    c_stmt(b, ctx)
  end

  defp c_stmt({:dowhile, b, c}, ctx) do
    c_stmt(b, ctx)
    c_expr(c, ctx)
  end

  defp c_stmt({:break, _}, _ctx), do: :ok
  defp c_stmt({:continue, _}, _ctx), do: :ok

  defp c_stmt({:block, stmts}, ctx) do
    if ctx.rewriting, do: fail("a block without a scope element in a rewritten function")
    c_stmts(stmts, c_push(ctx, {:blocked}))
  end

  defp c_stmt({:block, stmts, sc}, ctx), do: c_stmts(stmts, c_enter(ctx, sc))

  defp c_stmt({:for, init, test, update, body}, ctx) do
    if ctx.rewriting, do: fail("a for without a scope element in a rewritten function")
    ctx = c_push(ctx, {:blocked})
    if init, do: c_stmt(init, ctx)
    if test, do: c_expr(test, ctx)
    if update, do: c_expr(update, ctx)
    c_stmt(body, ctx)
  end

  defp c_stmt({:for, init, test, update, body, sc}, ctx) do
    ctx = c_enter(ctx, sc)
    if init, do: c_stmt(init, ctx)
    if test, do: c_expr(test, ctx)
    if update, do: c_expr(update, ctx)
    c_stmt(body, ctx)
  end

  defp c_stmt({k, _, pat, obj, body}, ctx) when k in [:forin, :forof, :forawait] do
    if ctx.rewriting, do: fail("a #{k} without a scope element in a rewritten function")
    ctx = c_push(ctx, {:blocked})
    c_expr(obj, ctx)
    c_pat(pat, ctx)
    c_stmt(body, ctx)
  end

  defp c_stmt({k, _, pat, obj, body, sc}, ctx) when k in [:forin, :forof, :forawait] do
    ctx = c_enter(ctx, sc)
    c_expr(obj, ctx)
    c_pat(pat, ctx)
    c_stmt(body, ctx)
  end

  defp c_stmt({:switch, disc, cases}, ctx) do
    if ctx.rewriting, do: fail("a switch without a scope element in a rewritten function")
    c_expr(disc, ctx)
    ctx = c_push(ctx, {:blocked})
    c_cases(cases, ctx)
  end

  defp c_stmt({:switch, disc, cases, sc}, ctx) do
    c_expr(disc, ctx)
    c_cases(cases, c_enter(ctx, sc))
  end

  defp c_stmt({:try, b, p, h, f}, ctx) do
    if ctx.rewriting, do: fail("a try without a scope element in a rewritten function")
    c_stmt(b, ctx)
    inner = c_push(ctx, {:blocked})
    if p, do: c_pat(p, inner)
    if h, do: c_stmt(h, inner)
    if f, do: c_stmt(f, ctx)
  end

  defp c_stmt({:try, b, p, h, f, sc}, ctx) do
    c_stmt(b, ctx)
    inner = c_enter(ctx, sc)
    if p, do: c_pat(p, inner)
    if h, do: c_stmt(h, inner)
    if f, do: c_stmt(f, ctx)
  end

  defp c_stmt({:with, o, body}, ctx) do
    if ctx.rewriting, do: fail("a with inside a rewritten function")
    c_expr(o, ctx)
    c_stmt(body, c_push(ctx, {:blocked}))
  end

  defp c_stmt({:import, _, _}, _ctx), do: :ok
  defp c_stmt({:export, s}, ctx), do: c_stmt(s, ctx)
  defp c_stmt({:export_default, {:fundecl, _, f}}, ctx), do: c_expr(f, ctx)
  defp c_stmt({:export_default, {:classdecl, _, c}}, ctx), do: c_expr(c, ctx)
  defp c_stmt({:export_default, {:expr, e}}, ctx), do: c_expr(e, ctx)
  defp c_stmt({:export_names, _}, _ctx), do: :ok
  defp c_stmt({:export_from, _, _}, _ctx), do: :ok
  defp c_stmt(other, _ctx), do: fail("unknown statement #{inspect(other, limit: 5)}")

  defp c_cases(cases, ctx) do
    Enum.each(cases, fn {test, body} ->
      if test != :default, do: c_expr(test, ctx)
      c_stmts(body, ctx)
    end)
  end

  defp c_enter(ctx, nil), do: ctx

  defp c_enter(ctx, %Scope{frame: true} = sc) do
    unless ctx.rewriting, do: fail("a Scope outside a rewritten function")

    Enum.each(sc.hoist, fn {i, _} ->
      if i < @header + 1 or i > sc.size,
        do: fail("hoist slot #{i} outside a frame of size #{sc.size}")
    end)

    c_push(ctx, {:frame, sc.slots, sc.size})
  end

  defp c_enter(ctx, %Scope{frame: false} = sc) do
    unless ctx.rewriting, do: fail("a Scope outside a rewritten function")
    size = c_home_size(ctx.chain)

    for {_, i} <- sc.slots,
        i < @header + 1 or i > size,
        do: fail("slot #{i} of a frameless scope outside its home frame of size #{size}")

    c_push(ctx, {:frameless, sc.slots})
  end

  defp c_home_size([{:frame, _, size} | _]), do: size
  defp c_home_size([_ | rest]), do: c_home_size(rest)
  defp c_home_size([]), do: 0

  defp c_pat({:id, _}, _ctx), do: :ok

  defp c_pat({:default, p, e}, ctx) do
    c_expr(e, ctx)
    c_pat(p, ctx)
  end

  defp c_pat({:rest, p}, ctx), do: c_pat(p, ctx)
  defp c_pat({:arrpat, elems}, ctx), do: Enum.each(elems, fn p -> if p, do: c_pat(p, ctx) end)

  defp c_pat({:objpat, props, rest}, ctx) do
    Enum.each(props, fn {key, p} ->
      c_key(key, ctx)
      c_pat(p, ctx)
    end)

    if rest, do: c_pat(rest, ctx)
  end

  defp c_pat({:member, _, _, _} = m, ctx), do: c_expr(m, ctx)
  defp c_pat({:call, _, _, _} = c, ctx), do: c_expr(c, ctx)
  defp c_pat(form, ctx), do: c_form(form, ctx)

  defp c_key({:computed, e}, ctx), do: c_expr(e, ctx)
  defp c_key(_, _ctx), do: :ok

  defp c_expr({:id, _}, _ctx), do: :ok
  defp c_expr({:this}, _ctx), do: :ok
  defp c_expr({:new_target}, _ctx), do: :ok
  defp c_expr({:super}, _ctx), do: :ok
  defp c_expr({:super_member, k}, ctx), do: c_key_or_expr(k, ctx)
  defp c_expr({:fn, _, _, _, _, _} = f, ctx), do: c_function(f, ctx)
  defp c_expr({:gen, f}, ctx), do: c_expr(f, ctx)
  defp c_expr({:async, f}, ctx), do: c_expr(f, ctx)
  defp c_expr({:unnamed, e}, ctx), do: c_expr(e, ctx)
  defp c_expr({:class, _, _, _, _} = c, ctx), do: c_class(c, ctx)

  defp c_expr({:member, o, k, _}, ctx) do
    c_expr(o, ctx)
    c_key_or_expr(k, ctx)
  end

  defp c_expr({:chain, e}, ctx), do: c_expr(e, ctx)

  # A direct eval is decided by its `{:id, "eval"}` callee (interp.ex `ev`);
  # a callee in slot form would run as an indirect eval, in the global scope.
  defp c_expr({:call, callee, args, false}, ctx) do
    if direct_eval_callee?(callee), do: fail("a direct eval with a rewritten callee")
    c_expr(callee, ctx)
    c_args(args, ctx)
  end

  defp c_expr({:call, callee, args, _}, ctx) do
    c_expr(callee, ctx)
    c_args(args, ctx)
  end

  defp c_expr({:new, callee, args}, ctx) do
    c_expr(callee, ctx)
    c_args(args, ctx)
  end

  defp c_expr({:tmpl, parts}, ctx),
    do: Enum.each(parts, fn p -> unless is_binary(p), do: c_expr(p, ctx) end)

  defp c_expr({:array, elems}, ctx),
    do: Enum.each(elems, fn e -> unless e == :hole, do: c_expr(e, ctx) end)

  defp c_expr({:object, props}, ctx) do
    Enum.each(props, fn
      {:init, key, v} ->
        c_key(key, ctx)
        c_expr(v, ctx)

      {k, key, f} when k in [:getter, :setter] ->
        c_key(key, ctx)
        c_expr(f, ctx)

      {_, e} ->
        c_expr(e, ctx)
    end)
  end

  defp c_expr({:unary, _, e}, ctx), do: c_expr(e, ctx)

  defp c_expr({:binary, _, l, r}, ctx) do
    c_expr(l, ctx)
    c_expr(r, ctx)
  end

  defp c_expr({:logical, _, l, r}, ctx) do
    c_expr(l, ctx)
    c_expr(r, ctx)
  end

  defp c_expr({:cond, c, a, b}, ctx) do
    c_expr(c, ctx)
    c_expr(a, ctx)
    c_expr(b, ctx)
  end

  defp c_expr({:seq, es}, ctx), do: Enum.each(es, &c_expr(&1, ctx))
  defp c_expr({k, _, _, t}, ctx) when k in [:update, :supdate], do: c_expr(t, ctx)

  defp c_expr({k, _, t, v}, ctx) when k in [:assign, :sassign] do
    c_expr(t, ctx)
    c_expr(v, ctx)
  end

  defp c_expr({:destructure, pat, right}, ctx) do
    c_expr(right, ctx)
    c_pat(pat, ctx)
  end

  defp c_expr({:await, e}, ctx), do: c_expr(e, ctx)
  defp c_expr({:yield, e, _}, ctx), do: c_expr(e, ctx)
  defp c_expr({:spread, e}, ctx), do: c_expr(e, ctx)
  defp c_expr({:import_call, e}, ctx), do: c_expr(e, ctx)

  defp c_expr({:import_call, e, o}, ctx) do
    c_expr(e, ctx)
    c_expr(o, ctx)
  end

  defp c_expr({:import_phase, _, args}, ctx), do: Enum.each(args, &c_expr(&1, ctx))

  defp c_expr({:tdz_names, _, e}, ctx) do
    if ctx.rewriting, do: fail("{:tdz_names} inside a rewritten function")
    c_expr(e, c_push(ctx, {:blocked}))
  end

  defp c_expr({:in_tdz, names, e}, ctx) do
    unless ctx.rewriting, do: fail("{:in_tdz} outside a rewritten function")
    # The names are frameless slots of the home frame; the reads inside `e`
    # carry their own indexes, which `c_form` checks against the frame size.
    c_expr(e, c_push(ctx, {:frameless, Map.new(names, &{&1, nil})}))
  end

  defp c_expr({:num, _}, _ctx), do: :ok
  defp c_expr({:bigint, _}, _ctx), do: :ok
  defp c_expr({:str, _}, _ctx), do: :ok
  defp c_expr({:lit, _}, _ctx), do: :ok
  defp c_expr({:regex, _, _}, _ctx), do: :ok
  defp c_expr({:val, _}, _ctx), do: :ok
  defp c_expr({:tagged_strings, _, _, _}, _ctx), do: :ok
  defp c_expr({:import_meta}, _ctx), do: :ok
  defp c_expr({:priv_ref, _}, _ctx), do: :ok
  defp c_expr(form, ctx), do: c_form(form, ctx)

  defp c_args(args, ctx), do: Enum.each(args, &c_expr(&1, ctx))

  defp direct_eval_callee?({:gref, "eval"}), do: true
  defp direct_eval_callee?({k, _, _, "eval"}) when k in [:slot, :cslot, :fname], do: true
  defp direct_eval_callee?({:mslot, _, _, "eval", _}), do: true
  defp direct_eval_callee?({:mref, _, "eval"}), do: true
  defp direct_eval_callee?(_), do: false
  defp c_key_or_expr({:str, _}, _ctx), do: :ok
  defp c_key_or_expr({:priv, _}, _ctx), do: :ok
  defp c_key_or_expr(e, ctx), do: c_expr(e, ctx)

  # The slot forms. Each must sit in a rewritten function and land, after
  # `d` run-time scopes, on a scope that declares the name at that index.
  defp c_form({:slot, d, i, name}, ctx), do: c_land(ctx, d, i, name, :slot)
  defp c_form({:cslot, d, i, name}, ctx), do: c_land(ctx, d, i, name, :slot)
  defp c_form({:fname, d, i, name}, ctx), do: c_land(ctx, d, i, name, :slot)
  defp c_form({:mslot, d, i, name, _}, ctx), do: c_land(ctx, d, i, name, :slot)
  defp c_form({:mref, d, name}, ctx), do: c_land(ctx, d, nil, name, :map)
  defp c_form({:this, d, i}, ctx), do: c_land(ctx, d, i, :this, :slot)

  defp c_form({:gref, name}, ctx) do
    unless ctx.rewriting, do: fail("{:gref, #{inspect(name)}} outside a rewritten function")

    Enum.each(ctx.chain, fn
      {:frame, slots, _} ->
        if Map.has_key?(slots, name), do: fail("{:gref, #{inspect(name)}} shadowed by a frame")

      {:frameless, slots} ->
        if Map.has_key?(slots, name), do: fail("{:gref, #{inspect(name)}} shadowed by a scope")

      {:map, names} ->
        if MapSet.member?(names, name),
          do: fail("{:gref, #{inspect(name)}} shadowed by a map scope")

      _ ->
        :ok
    end)
  end

  defp c_form(other, _ctx), do: fail("unknown node #{inspect(other, limit: 5)}")

  defp c_land(ctx, d, i, name, want) do
    unless ctx.rewriting, do: fail("#{inspect(name)} form outside a rewritten function")
    c_walk(ctx.chain, d, i, name, want, 0)
  end

  defp c_walk([], d, _i, name, _want, _hops),
    do: fail("#{inspect(name)} at depth #{d} reaches no scope")

  defp c_walk([{:frameless, slots} | rest], d, i, name, want, hops) do
    case slots do
      %{^name => j} ->
        if want != :slot or hops != d or (j != nil and j != i),
          do:
            fail(
              "#{inspect(name)} at depth #{d} slot #{i}: frameless scope has it at hop #{hops} slot #{inspect(j)}"
            )

        size = c_home_size(rest)
        if i > size, do: fail("#{inspect(name)} slot #{i} outside its home frame of size #{size}")

      _ ->
        c_walk(rest, d, i, name, want, hops)
    end
  end

  defp c_walk([{:frame, slots, size} | rest], d, i, name, want, hops) do
    cond do
      hops == d ->
        if want != :slot, do: fail("#{inspect(name)}: an mref lands on a frame")

        # (the arguments object sits under the atom when the body declares
        # the name, see `layout_fn`)
        hit =
          Map.get(slots, name) == i or (name == "arguments" and Map.get(slots, :arguments) == i)

        unless hit, do: fail("#{inspect(name)} slot #{i} not in the frame at depth #{d}")
        if i > size, do: fail("#{inspect(name)} slot #{i} outside a frame of size #{size}")

      Map.has_key?(slots, name) ->
        fail("#{inspect(name)} at depth #{d} is shadowed at hop #{hops}")

      true ->
        c_walk(rest, d, i, name, want, hops + 1)
    end
  end

  defp c_walk([{:map, names} | rest], d, i, name, want, hops) do
    cond do
      hops == d ->
        if want != :map, do: fail("#{inspect(name)}: a slot form lands on a map scope")

        unless MapSet.member?(names, name),
          do: fail("#{inspect(name)} not in the map scope at depth #{d}")

      MapSet.member?(names, name) ->
        fail("#{inspect(name)} at depth #{d} is shadowed at hop #{hops}")

      true ->
        c_walk(rest, d, i, name, want, hops + 1)
    end
  end

  defp c_walk([{:blocked} | _], d, _i, name, _want, _hops),
    do: fail("#{inspect(name)} at depth #{d} crosses an unmodelled scope")

  defp c_walk([{:top, kind, names} | _], d, _i, name, want, hops) do
    if hops != d or want != :map or kind == :script or not MapSet.member?(names, name),
      do: fail("#{inspect(name)} at depth #{d} lands on the top-level scope")
  end

  defp c_function({:fn, _, params, body, mode, src}, ctx) do
    case src do
      %Info{} = info ->
        c_struct(info)
        ctx = %{ctx | rewriting: info.rewritten}

        Enum.each(info.hoist, fn {i, _} ->
          if i < @header + 1 or i > info.size,
            do: fail("hoist slot #{i} outside a frame of size #{info.size}")
        end)

        # Parameter defaults see the parameters and the self name only; the
        # body's names are not bound yet. The parameter list carries each
        # parameter's slot in its binding form, because `slots` keeps the
        # body's entry when a `var` of the same name has a slot of its own.
        param_slots =
          for {n, i} <- info.slots,
              elem(info.kinds, i - 1) in [:self, :hidden],
              into: %{} do
            {n, i}
          end

        param_slots = Enum.reduce(params, param_slots, &c_param_binds/2)

        param_ctx =
          c_push(ctx, if(info.rewritten, do: {:frame, param_slots, info.size}, else: {:blocked}))

        Enum.each(params, &c_pat(&1, param_ctx))

        ctx =
          c_push(ctx, if(info.rewritten, do: {:frame, info.slots, info.size}, else: {:blocked}))

        if mode == :arrow_expr, do: c_expr(body, ctx), else: c_stmts(body, ctx)

      _ ->
        ctx = c_push(%{ctx | rewriting: false}, {:blocked})
        Enum.each(params, &c_pat(&1, ctx))
        if mode == :arrow_expr, do: c_expr(body, ctx), else: c_stmts(body, ctx)
    end
  end

  # The names a rewritten parameter pattern binds, with their slots. Default
  # values are read sites and are left out; a later position wins, as it does
  # for duplicate plain parameters.
  defp c_param_binds({:slot, 0, i, name}, acc), do: Map.put(acc, name, i)
  defp c_param_binds({:default, p, _}, acc), do: c_param_binds(p, acc)
  defp c_param_binds({:rest, p}, acc), do: c_param_binds(p, acc)

  defp c_param_binds({:arrpat, elems}, acc),
    do: Enum.reduce(elems, acc, fn p, acc -> if p, do: c_param_binds(p, acc), else: acc end)

  defp c_param_binds({:objpat, props, rest}, acc) do
    acc = Enum.reduce(props, acc, fn {_, p}, acc -> c_param_binds(p, acc) end)
    if rest, do: c_param_binds(rest, acc), else: acc
  end

  defp c_param_binds(_, acc), do: acc

  defp c_class({:class, name, heritage, members, _}, ctx) do
    {{class_decs, member_decs}, members} = split_decorations(members)
    Enum.each(class_decs, &c_expr(&1, ctx))
    inner = c_push(ctx, {:map, MapSet.new(if(name, do: [name], else: []))})
    if heritage, do: c_expr(heritage, inner)
    Enum.each(Map.values(member_decs), fn decs -> Enum.each(decs, &c_expr(&1, inner)) end)

    Enum.each(members, fn
      {:cmember, k, key, f, _} when k in [:method, :get, :set] ->
        c_key(key, inner)
        c_expr(f, inner)

      {:cmember, _, key, init, _static?} when not is_list(init) ->
        c_key(key, inner)
        if init, do: c_expr(init, c_push(inner, {:map, MapSet.new()}))

      {:cmember, :block, nil, stmts, true} ->
        ctx2 =
          inner
          |> c_push({:map, MapSet.new()})
          |> c_push(
            {:map,
             MapSet.new(
               var_names(stmts) ++
                 for({n, _} <- fundecls(stmts), do: n) ++ for({n, _} <- lexicals(stmts), do: n)
             )}
          )

        c_stmts(stmts, %{ctx2 | rewriting: false})
    end)
  end

  # A struct holds names, numbers, atoms and syntax only. A run-time
  # reference would be a function or a process term.
  defp c_struct(s) do
    s
    |> Map.from_struct()
    |> Map.values()
    |> Enum.each(&c_plain/1)
  end

  defp c_plain(x) when is_function(x) or is_pid(x) or is_reference(x) or is_port(x),
    do: fail("a struct holds a run-time term #{inspect(x)}")

  defp c_plain(t) when is_tuple(t), do: t |> Tuple.to_list() |> Enum.each(&c_plain/1)
  defp c_plain(l) when is_list(l), do: Enum.each(l, &c_plain/1)
  defp c_plain(%MapSet{}), do: :ok
  defp c_plain(%Info{} = i), do: c_struct(i)
  defp c_plain(%Scope{} = s), do: c_struct(s)
  defp c_plain(m) when is_map(m), do: m |> Map.values() |> Enum.each(&c_plain/1)
  defp c_plain(_), do: :ok
end
