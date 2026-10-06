defmodule Browser.JS.Parser do
  @moduledoc """
  A recursive-descent / precedence-climbing parser for a practical subset of JavaScript.

  Supported: `var`/`let`/`const` (with destructuring), functions and arrow functions (defaults,
  rest parameters), object and array literals (shorthand, computed keys, methods, spread),
  template literals, the usual operators including `?.` and `??`, `if`/`for`/`for-in`/`for-of`/
  `while`/`do`, `switch`, `try`/`catch`/`finally`, labels, `new`, and automatic semicolon
  insertion. Not yet: classes, generators, `async`/`await`, regular expression literals,
  getters/setters, tagged templates.

  `parse/1` returns `{:ok, {:program, statements}}` or `{:error, message}`. The tree is plain
  tuples; see `Browser.JS.Interp` for what each node means.
  """

  alias Browser.JS.Interp
  alias Browser.JS.Lexer

  @reserved ~w(break case catch const continue debugger default delete do else export extends finally for
               function if import in instanceof new return switch throw try typeof var void while with
               class enum super null true false this)

  @assign_ops ~w(= += -= *= /= %= **= <<= >>= >>>= &= |= ^= &&= ||= ??=)

  @binary %{
    "??" => 1,
    "||" => 2,
    "&&" => 3,
    "|" => 4,
    "^" => 5,
    "&" => 6,
    "==" => 7,
    "!=" => 7,
    "===" => 7,
    "!==" => 7,
    "<" => 8,
    ">" => 8,
    "<=" => 8,
    ">=" => 8,
    "instanceof" => 8,
    "in" => 8,
    "<<" => 9,
    ">>" => 9,
    ">>>" => 9,
    "+" => 10,
    "-" => 10,
    "*" => 11,
    "/" => 11,
    "%" => 11,
    "**" => 12
  }

  @doc """
  Parses a script, or with `module: true` a module (strict, and its top-level function
  declarations are lexical, so they clash with `var` and with each other).
  """
  def parse(src, opts \\ []) do
    with {:ok, tokens} <- Lexer.tokenize(src) do
      try do
        eval? = Keyword.get(opts, :eval, false)

        Process.put(
          :js_strict,
          use_strict?(tokens) or Keyword.get(opts, :module, false) or
            Keyword.get(opts, :strict, false)
        )

        Process.put(:js_priv_refs, [])
        Process.put(:js_module, Keyword.get(opts, :module, false))
        Process.put(:js_labels, [])
        Process.put(:js_loop, 0)
        Process.put(:js_switch, 0)
        # no `return` at the top level; a module has no `new.target` there either (a script
        # may be eval code run inside a function)
        Process.put(:js_fn, false)

        Process.put(
          :js_nt,
          if(eval?,
            do: Keyword.get(opts, :new_target, false),
            else: not Keyword.get(opts, :module, false)
          )
        )

        program = tokens |> statements()

        if Enum.any?(program, &using_decl?/1),
          do: throw({:syntax, "using declaration at the top level of a script"})

        program = check_scope(program, true)
        if Keyword.get(opts, :module, false), do: check_module_names(program)

        # eval code sees the private names of the classes around the call
        case Process.get(:js_priv_refs) -- Keyword.get(opts, :private, []) do
          [] -> :ok
          [n | _] -> throw({:syntax, "private name #" <> n <> " is not defined"})
        end

        if eval?, do: check_eval_context(program, opts)

        {:ok, {:program, program}}
      catch
        {:syntax, msg} -> {:error, msg}
      end
    end
  end

  # `super` and `arguments` in eval code are only valid where the surrounding code allows them
  defp check_eval_context(program, opts) do
    if not Keyword.get(opts, :super_prop, false) and
         contains_node?(program, &match?({:super_member, _}, &1)),
       do: throw({:syntax, "'super' keyword unexpected here"})

    if not Keyword.get(opts, :super_call, false) and contains_node?(program, &(&1 == {:super})),
      do: throw({:syntax, "'super' keyword unexpected here"})

    if Keyword.get(opts, :no_arguments, false) and
         contains_node?(program, &(&1 == {:id, "arguments"})),
       do: throw({:syntax, "'arguments' is not allowed in a class field initializer"})
  end

  # ── redeclarations ─────────────────────────────────────────

  # Early errors of a statement list that is a scope: a lexical name (let, const, class, and
  # in blocks function declarations) declared twice, or also declared with var, or also a
  # parameter. At the top of a function or script, function declarations are var-scoped.
  defp check_scope(stmts, top?, params \\ []) do
    lexical =
      Enum.flat_map(stmts, fn
        {:var, k, decls} when k in [:let, :const, :using, :await_using] ->
          for {pat, _} <- decls, n <- Interp.pattern_names(pat, []), do: {n, :lexical}

        {:fundecl, n, {:async, _}} when not top? ->
          [{n, :lexical}]

        {:fundecl, n, _} when not top? ->
          [{n, if(strict?(), do: :lexical, else: :function)}]

        _ ->
          []
      end)

    names = Enum.map(lexical, &elem(&1, 0))

    dup? =
      lexical
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
      |> Enum.any?(fn {_, kinds} -> length(kinds) > 1 and Enum.any?(kinds, &(&1 == :lexical)) end)

    vars =
      Interp.var_names(stmts, []) ++
        if(top?, do: for({:fundecl, n, _} <- stmts, do: n), else: [])

    if dup? or Enum.any?(names, &(&1 in vars or &1 in params)),
      do: throw({:syntax, "redeclaration of a lexical name"})

    if Enum.any?(stmts, &using_decl?/1), do: wrap_using(stmts), else: stmts
  end

  # Early errors of a module: a function declaration at its top is a lexical name, imported
  # names are lexical too (and not `eval` or `arguments`), an exported name appears once, and
  # a name exported from this module has to be declared in it.
  defp check_module_names(stmts) do
    declared_exports =
      Enum.flat_map(stmts, fn
        {:export, {:var, _, decls}} ->
          for {pat, _} <- decls, n <- Interp.pattern_names(pat, []), do: n

        {:export, {:fundecl, n, _}} ->
          [n]

        _ ->
          []
      end)

    stmts =
      Enum.map(stmts, fn
        {:export, s} -> s
        s -> s
      end)

    imported =
      for {:import, _, bindings} <- stmts,
          b <- bindings,
          do:
            (case b do
               {:default, l} -> l
               {:ns, l} -> l
               {:named, _, l} -> l
             end)

    if Enum.any?(imported, &(&1 in ["eval", "arguments"])),
      do: throw({:syntax, "cannot bind eval or arguments"})

    lexical =
      imported ++
        Enum.flat_map(stmts, fn
          {:var, k, decls} when k in [:let, :const] ->
            for {pat, _} <- decls, n <- Interp.pattern_names(pat, []), do: n

          {:fundecl, n, _} ->
            [n]

          {:export_default, {:classdecl, n, _}} ->
            [n]

          {:export_default, {:fundecl, n, _}} ->
            [n]

          _ ->
            []
        end)

    vars = Interp.var_names(stmts, [])

    if length(lexical) != length(Enum.uniq(lexical)) or Enum.any?(lexical, &(&1 in vars)),
      do: throw({:syntax, "redeclaration of a lexical name"})

    declared = lexical ++ vars
    exported = declared_exports ++ exported_names(stmts)

    if length(exported) != length(Enum.uniq(exported)),
      do: throw({:syntax, "duplicate export"})

    for {:export_names, names} <- stmts, {local, _} <- names, local not in declared do
      throw({:syntax, "export of an undeclared name #{local}"})
    end
  end

  defp exported_names(stmts) do
    Enum.flat_map(stmts, fn
      {:export_names, names} -> for {_, exported} <- names, do: exported
      {:export_default, _} -> ["default"]
      {:export_from, _, :all} -> []
      {:export_from, _, names} -> for n <- names, do: elem(n, 1)
      _ -> []
    end)
  end

  defp using_decl?({:var, k, _}), do: k in [:using, :await_using]
  defp using_decl?(_), do: false

  # `using a = x; rest` becomes one node that owns the rest of the list, so that leaving the
  # list (however it ends) disposes the resource
  defp wrap_using([]), do: []

  defp wrap_using([{:var, k, decls} | rest]) when k in [:using, :await_using],
    do: [nest_using(k, decls, wrap_using(rest))]

  defp wrap_using([s | rest]), do: [s | wrap_using(rest)]

  defp nest_using(kind, decls, rest) do
    List.foldr(decls, rest, fn {{:id, name}, init}, acc -> [{:using, kind, name, init, acc}] end)
    |> hd()
  end

  # ── strict mode ────────────────────────────────────────────

  @strict_reserved ~w(implements interface let package private protected public static yield)

  defp strict?, do: Process.get(:js_strict, false)

  # does the token list begin with a "use strict" directive?
  # a token that has a line break before it (`:octal_nl`: a string with a legacy octal escape)
  defguardp nl?(mark) when mark in [true, :octal_nl]

  defp use_strict?([{:str, "use strict", _}, {:p, p, _} | _]) when p in [";", "}"], do: true
  defp use_strict?([{:str, "use strict", _}, {_, _, nl} | _]) when nl?(nl), do: true
  defp use_strict?([{:str, "use strict", _}, {:eof, _, _} | _]), do: true
  defp use_strict?([{:str, _, _}, {:p, ";", _} | ts]), do: use_strict?(ts)
  defp use_strict?(_), do: false

  # a function body: strict when it opens with the directive (or is inside strict code)
  defp function_body(ts, params, unique?) do
    outer = strict?()

    if use_strict?(ts) do
      unless Enum.all?(params, &match?({:id, _}, &1)),
        do: throw({:syntax, "\"use strict\" in a function with non-simple parameters"})

      Process.put(:js_strict, true)
    end

    if strict?(), do: check_strict_params(params)
    if unique? or not Enum.all?(params, &match?({:id, _}, &1)), do: check_unique_params(params)
    {body, rest} = fresh_jumps(fn -> block_body(ts, []) end, true)

    names =
      if params == [], do: [], else: Enum.reduce(params, [], &Interp.pattern_names/2)

    # a function inside strict code carries the directive itself, which is how a call knows
    # not to give it the window for `this`
    body = if strict?(), do: [{:expr, {:str, "use strict"}} | body], else: body

    Process.put(:js_strict, outer)
    {check_scope(body, true, names), rest}
  end

  # `super` needs a method: none in a plain function, no `super()` in an object method
  defp check_super_use(name, code, class_method?) do
    cond do
      match?({:method, _}, name) and class_method? ->
        :ok

      match?({:method, _}, name) ->
        if contains_node?(code, &(&1 == {:super})),
          do: throw({:syntax, "'super' keyword unexpected here"})

      true ->
        if contains_node?(code, &(&1 == {:super} or match?({:super_member, _}, &1))),
          do: throw({:syntax, "'super' keyword unexpected here"})
    end
  end

  # arrow functions, methods and functions with non-simple parameters take no duplicates
  defp check_unique_params(params) do
    names = Enum.reduce(params, [], &Interp.pattern_names/2)
    if names != Enum.uniq(names), do: throw({:syntax, "duplicate parameter name"})
  end

  defp check_strict_params(params) do
    names = for {:id, n} <- Enum.map(params, &strip_default/1), do: n

    if names != Enum.uniq(names), do: throw({:syntax, "duplicate parameter name in strict mode"})
    Enum.each(names, &check_strict_name/1)
  end

  defp check_octal_string(mark) when mark in [:octal, :octal_nl] do
    if strict?(), do: throw({:syntax, "octal escape sequences are not allowed in strict mode"})
  end

  defp check_octal_string(_), do: :ok

  # `yield` and `await` cannot be labels where they are keywords
  defp check_strict_name_context(name) do
    if (name == "yield" and Process.get(:js_generator, false)) or
         (name == "await" and Process.get(:js_async, false)),
       do: throw({:syntax, "#{name} is not a valid label here"})
  end

  defp strip_default({:default, p, _}), do: p
  defp strip_default(p), do: p

  defp check_strict_name(name) do
    if strict?() and (name in ["eval", "arguments"] or name in @strict_reserved),
      do: throw({:syntax, "unexpected #{name} in strict mode"})

    if name == "yield" and Process.get(:js_generator, false),
      do: throw({:syntax, "yield is reserved in generators"})

    if name == "await" and (Process.get(:js_async, false) or Process.get(:js_static_block, false)),
      do: throw({:syntax, "await is reserved here"})
  end

  # the body of if, a loop, `with` or a label: a statement, never a declaration (a plain
  # function declaration is allowed after `if` and a label)
  defp body_statement(ts, allow_function \\ false) do
    case ts do
      [{:id, "let", _}, {:p, "[", _} | _] ->
        throw({:syntax, "lexical declaration in statement position"})

      [{:id, "let", _}, {:p, "{", false} | _] ->
        throw({:syntax, "lexical declaration in statement position"})

      [{:id, "let", _}, {:id, n, false} | _] when n not in ["in", "of", "instanceof"] ->
        throw({:syntax, "lexical declaration in statement position"})

      [{:id, kw, _} | _] when kw in ["const", "class"] ->
        throw({:syntax, "#{kw} declaration in statement position"})

      [{:id, "using", _} | _] ->
        if using_start?(ts),
          do: throw({:syntax, "using declaration in statement position"}),
          else: statement(ts)

      [{:id, "await", _} | rest = [{:id, "using", _} | _]] ->
        if Process.get(:js_async, false) and using_start?(rest),
          do: throw({:syntax, "using declaration in statement position"}),
          else: statement(ts)

      [{:id, l, _}, {:p, ":", _} | rest] when not allow_function and l not in @reserved ->
        body_statement(rest, false)
        statement(ts)

      [{:id, "async", _}, {:id, "function", f} | _] when f != true ->
        throw({:syntax, "async function declaration in statement position"})

      [{:id, "function", _} | _] when not allow_function ->
        throw({:syntax, "function declaration in statement position"})

      _ ->
        statement(ts)
    end
  end

  defp statements(ts) do
    case ts do
      [{:eof, _, _}] ->
        []

      [{:id, "export", _} | _] ->
        if Process.get(:js_module, false), do: module_statements(ts), else: script_statements(ts)

      [{:id, "import", _}, {:p, p, _} | _] when p in ["(", "."] ->
        {stmt, ts} = statement(ts)
        [stmt | statements(ts)]

      [{:id, "import", _} | _] ->
        if Process.get(:js_module, false), do: module_statements(ts), else: script_statements(ts)

      _ ->
        script_statements(ts)
    end
  end

  defp module_statements(ts) do
    {stmt, ts} = module_item(ts)
    [stmt | statements(ts)]
  end

  defp script_statements(ts) do
    {stmt, ts} = statement(ts)
    [stmt | statements(ts)]
  end

  # ── statements ─────────────────────────────────────────────

  defp statement([{:p, "{", _} | ts]) do
    {body, ts} = block_body(ts, [])
    {{:block, check_scope(body, false)}, ts}
  end

  defp statement([{:p, ";", _} | ts]), do: {{:empty}, ts}

  defp statement([{:id, kw, _} | ts]) when kw in ["var", "const"] do
    {decl, ts} = declaration(kw, ts)
    {decl, semi(ts)}
  end

  defp statement([{:id, "using", _}, {:id, name, false} | ts])
       when name not in @reserved and name not in ["in", "instanceof", "of", "let"] do
    {decls, ts} = using_declarators([{:id, name, false} | ts])
    {{:var, :using, decls}, semi(ts)}
  end

  defp statement([{:id, "await", _}, {:id, "using", _}, {:id, name, false} | ts] = all)
       when name not in @reserved and name not in ["in", "instanceof", "of", "let"] do
    if Process.get(:js_async, false) do
      {decls, ts} = using_declarators([{:id, name, false} | ts])
      {{:var, :await_using, decls}, semi(ts)}
    else
      expression_statement(all)
    end
  end

  defp statement([{:id, "let", _} | ts] = all) do
    case ts do
      [{:id, name, _} | _] when name not in ["in", "of", "instanceof"] -> let_decl(ts)
      [{:p, p, _} | _] when p in ["[", "{"] -> let_decl(ts)
      _ -> expression_statement(all)
    end
  end

  defp statement([{:id, "function", _}, {:id, name, _} | ts]) when name not in @reserved do
    {fun, ts} = function_rest(name, ts)
    {{:fundecl, name, fun}, ts}
  end

  defp statement([{:id, "function", _}, {:p, "*", _}, {:id, name, _} | ts])
       when name not in @reserved do
    {fun, ts} = generator_rest(name, ts)
    {{:fundecl, name, fun}, ts}
  end

  defp statement([{:id, "async", _}, {:id, "function", _}, {:p, "*", _}, {:id, name, _} | ts])
       when name not in @reserved do
    Process.put(:js_async_next, true)
    {fun, ts} = generator_rest(name, ts)
    {{:fundecl, name, {:async, fun}}, ts}
  end

  defp statement([{:id, "async", _}, {:id, "function", _}, {:id, name, _} | ts])
       when name not in @reserved do
    Process.put(:js_async_next, true)
    {fun, ts} = function_rest(name, ts)
    {{:fundecl, name, {:async, fun}}, ts}
  end

  defp statement([{:id, "return", _} | ts]) do
    unless Process.get(:js_fn, true), do: throw({:syntax, "return outside a function"})

    case ts do
      [{:p, ";", _} | ts] ->
        {{:return, nil}, ts}

      [{_, _, nl} | _] when nl?(nl) ->
        {{:return, nil}, ts}

      [{:p, "}", _} | _] ->
        {{:return, nil}, ts}

      [{:eof, _, _} | _] ->
        {{:return, nil}, ts}

      _ ->
        {e, ts} = expression(ts)
        {{:return, e}, semi(ts)}
    end
  end

  defp statement([{:id, "if", _} | ts]) do
    ts = expect(ts, "(")
    {c, ts} = expression(ts)
    ts = expect(ts, ")")
    {a, ts} = body_statement(ts, true)

    case ts do
      [{:id, "else", _} | ts] ->
        {b, ts} = body_statement(ts, true)
        {{:if, c, a, b}, ts}

      _ ->
        {{:if, c, a, nil}, ts}
    end
  end

  defp statement([{:id, "while", _} | ts]) do
    ts = expect(ts, "(")
    {c, ts} = expression(ts)
    ts = expect(ts, ")")
    {body, ts} = loop_body(ts)
    {{:while, c, body}, ts}
  end

  defp statement([{:id, "do", _} | ts]) do
    {body, ts} = loop_body(ts)
    ts = expect_id(ts, "while")
    ts = expect(ts, "(")
    {c, ts} = expression(ts)
    ts = expect(ts, ")")

    ts =
      case ts do
        [{:p, ";", _} | t] -> t
        t -> t
      end

    {{:dowhile, body, c}, ts}
  end

  defp statement([{:id, "for", _}, {:id, "await", _} | ts]) do
    case for_statement(expect(ts, "(")) do
      {{:forof, decl, pat, obj, body}, ts} -> {{:forawait, decl, pat, obj, body}, ts}
      _ -> throw({:syntax, "for await needs an of loop"})
    end
  end

  defp statement([{:id, "for", _} | ts]), do: for_statement(expect(ts, "("))

  defp statement([{:id, kw, _} | ts]) when kw in ["break", "continue"] do
    {label, ts} =
      case ts do
        [{:id, l, false} | t] when l not in @reserved -> {l, t}
        t -> {nil, t}
      end

    check_jump(kw, label)
    {{String.to_atom(kw), label}, semi(ts)}
  end

  defp statement([{:id, "throw", _} | ts]) do
    {e, ts} = expression(ts)
    {{:throw, e}, semi(ts)}
  end

  defp statement([{:id, "try", _} | ts]) do
    {block, ts} = statement(ts)

    {param, handler, ts} =
      case ts do
        [{:id, "catch", _} | ts] ->
          {param, ts} =
            case ts do
              [{:p, "(", _} | ts] ->
                {pat, ts} = pattern(ts)
                {pat, expect(ts, ")")}

              ts ->
                {nil, ts}
            end

          {handler, ts} = statement(ts)
          {param, handler, ts}

        ts ->
          {nil, nil, ts}
      end

    {finalizer, ts} =
      case ts do
        [{:id, "finally", _} | ts] -> statement(ts)
        ts -> {nil, ts}
      end

    if handler == nil and finalizer == nil, do: throw({:syntax, "try without catch or finally"})
    {{:try, block, param, handler, finalizer}, ts}
  end

  defp statement([{:id, "switch", _} | ts]) do
    ts = expect(ts, "(")
    {disc, ts} = expression(ts)
    ts = expect(ts, ")")
    ts = expect(ts, "{")
    switches = Process.get(:js_switch, 0)
    Process.put(:js_switch, switches + 1)

    {cases, ts} =
      try do
        switch_cases(ts, [])
      after
        Process.put(:js_switch, switches)
      end

    check_scope(Enum.flat_map(cases, &elem(&1, 1)), false)
    {{:switch, disc, cases}, ts}
  end

  defp statement([{:id, name, _}, {:p, ":", _} | ts]) when name not in @reserved do
    check_strict_name_context(name)
    labels = Process.get(:js_labels, [])

    if List.keymember?(labels, name, 0), do: throw({:syntax, "duplicate label #{name}"})
    Process.put(:js_labels, [{name, loop_ahead?(ts)} | labels])

    try do
      {stmt, ts} = body_statement(ts, true)
      {{:labeled, name, stmt}, ts}
    after
      Process.put(:js_labels, labels)
    end
  end

  defp statement([{:id, "debugger", _} | ts]), do: {{:empty}, semi(ts)}

  # ── modules ────────────────────────────────────────────────

  defp statement([{:id, "class", _}, {:id, name, _} | _] = [_ | ts]) when name not in @reserved do
    {node, ts} = class_rest(ts)
    {{:var, :let, [{{:id, name}, node}]}, ts}
  end

  defp statement([{:id, "import", _}, {:p, p, _} | _] = ts) when p in ["(", "."],
    do: expression_statement(ts)

  defp statement([{:id, kw, _} | _]) when kw in ["import", "export"],
    do: throw({:syntax, "`#{kw}` is only allowed at the top level of a module"})

  defp statement([{:id, "with", _} | ts]) do
    if strict?(), do: throw({:syntax, "`with` in strict mode"})
    ts = expect(ts, "(")
    {obj, ts} = expression(ts)
    ts = expect(ts, ")")
    {body, ts} = loop_body(ts)
    {{:with, obj, body}, ts}
  end

  defp statement([{:id, kw, _} | _]) when kw in ~w(import enum),
    do: throw({:syntax, "`#{kw}` is not supported yet"})

  defp statement(ts), do: expression_statement(ts)

  defp module_item([{:id, "import", _}, {:str, spec, _} | ts]),
    do: {{:import, spec, []}, semi(ts)}

  defp module_item([{:id, "import", _} | [{k, _, _} | _] = ts]) when k in [:id] do
    {bindings, ts} = import_bindings(ts, [])
    ts = expect_id(ts, "from")

    case ts do
      [{:str, spec, _} | ts] -> {{:import, spec, bindings}, semi(ts)}
      _ -> throw({:syntax, "expected a module name"})
    end
  end

  defp module_item([{:id, "import", _}, {:p, "{", _} | _] = [_ | ts]) do
    {bindings, ts} = import_bindings(ts, [])
    ts = expect_id(ts, "from")

    case ts do
      [{:str, spec, _} | ts] -> {{:import, spec, bindings}, semi(ts)}
      _ -> throw({:syntax, "expected a module name"})
    end
  end

  defp module_item([{:id, "import", _}, {:p, "*", _} | _] = [_ | ts]) do
    {bindings, ts} = import_bindings(ts, [])
    ts = expect_id(ts, "from")

    case ts do
      [{:str, spec, _} | ts] -> {{:import, spec, bindings}, semi(ts)}
      _ -> throw({:syntax, "expected a module name"})
    end
  end

  defp module_item([{:id, "export", _}, {:id, "default", _} | ts]) do
    case ts do
      [{:id, "function", _}, {:p, "*", _}, {:id, name, _} | rest] when name not in @reserved ->
        {fun, rest} = generator_rest(name, rest)
        {{:export_default, {:fundecl, name, fun}}, rest}

      [{:id, "function", _}, {:p, "*", _} | rest] ->
        {fun, rest} = generator_rest("default", rest)
        {{:export_default, {:fundecl, "*default*", fun}}, rest}

      [{:id, "function", _}, {:id, name, _} | rest] when name not in @reserved ->
        {fun, rest} = function_rest(name, rest)
        {{:export_default, {:fundecl, name, fun}}, rest}

      [{:id, "function", _} | rest] ->
        {fun, rest} = function_rest("default", rest)
        {{:export_default, {:fundecl, "*default*", fun}}, rest}

      [{:id, "async", _}, {:id, "function", f}, {:p, "*", _}, {:id, name, _} | rest]
      when f != true and name not in @reserved ->
        {fun, rest} = generator_rest(name, rest)
        {{:export_default, {:fundecl, name, {:async, fun}}}, rest}

      [{:id, "async", _}, {:id, "function", f}, {:p, "*", _} | rest] when f != true ->
        {fun, rest} = generator_rest("default", rest)
        {{:export_default, {:fundecl, "*default*", {:async, fun}}}, rest}

      [{:id, "async", _}, {:id, "function", f}, {:id, name, _} | rest]
      when f != true and name not in @reserved ->
        Process.put(:js_async_next, true)
        {fun, rest} = function_rest(name, rest)
        {{:export_default, {:fundecl, name, {:async, fun}}}, rest}

      [{:id, "async", _}, {:id, "function", f} | rest] when f != true ->
        Process.put(:js_async_next, true)
        {fun, rest} = function_rest("default", rest)
        {{:export_default, {:fundecl, "*default*", {:async, fun}}}, rest}

      [{:id, "class", _}, {:id, name, _} | _] = [_ | rest] when name not in @reserved ->
        {node, rest} = class_rest(rest)
        {{:export_default, {:classdecl, name, node}}, rest}

      [{:id, "class", _} | rest] ->
        {node, rest} = class_rest(rest)
        {{:export_default, {:classdecl, "*default*", node}}, rest}

      _ ->
        {e, ts} = assignment(ts)
        {{:export_default, {:expr, e}}, semi(ts)}
    end
  end

  defp module_item([{:id, "export", _}, {:p, "{", _} | ts]) do
    {names, ts} = export_names(ts, [])

    case ts do
      [{:id, "from", _}, {:str, spec, _} | ts] -> {{:export_from, spec, names}, semi(ts)}
      ts -> {{:export_names, names}, semi(ts)}
    end
  end

  defp module_item([{:id, "export", _}, {:p, "*", _}, {:id, "from", _}, {:str, spec, _} | ts]),
    do: {{:export_from, spec, :all}, semi(ts)}

  defp module_item([
         {:id, "export", _},
         {:p, "*", _},
         {:id, "as", _},
         {:id, name, _},
         {:id, "from", _},
         {:str, spec, _} | ts
       ]),
       do: {{:export_from, spec, [{:star, name}]}, semi(ts)}

  defp module_item([{:id, "export", _} | ts]) do
    case ts do
      [{:id, kw, _} | _] when kw in ["var", "let", "const", "function", "async", "class"] ->
        {stmt, ts} = statement(ts)
        {{:export, stmt}, ts}

      _ ->
        throw({:syntax, "unsupported export"})
    end
  end

  defp import_bindings([{:p, "*", _}, {:id, "as", _}, {:id, local, _} | ts], acc),
    do: import_more(ts, [{:ns, local} | acc])

  defp import_bindings([{:p, "{", _} | ts], acc) do
    {named, ts} = import_named(ts, [])
    import_more(ts, named ++ acc)
  end

  defp import_bindings([{:id, local, _} | ts], acc) when local not in @reserved,
    do: import_more(ts, [{:default, local} | acc])

  defp import_bindings(_ts, _acc), do: throw({:syntax, "bad import"})

  # after a default import: `, {…}` or `, * as ns`
  defp import_more([{:p, ",", _} | ts], acc), do: import_bindings(ts, acc)
  defp import_more(ts, acc), do: {Enum.reverse(acc), ts}

  defp import_named([{:p, "}", _} | ts], acc), do: {acc, ts}

  defp import_named([{k, imported, _}, {:id, "as", _}, {:id, local, _} | ts], acc)
       when k in [:id, :str],
       do: import_named_next(ts, [{:named, imported, local} | acc])

  defp import_named([{k, name, _} | ts], acc) when k in [:id, :str],
    do: import_named_next(ts, [{:named, name, name} | acc])

  defp import_named(_ts, _acc), do: throw({:syntax, "bad import list"})

  defp import_named_next([{:p, ",", _} | ts], acc), do: import_named(ts, acc)
  defp import_named_next([{:p, "}", _} | ts], acc), do: {acc, ts}
  defp import_named_next(_ts, _acc), do: throw({:syntax, "bad import list"})

  defp export_names([{:p, "}", _} | ts], acc), do: {Enum.reverse(acc), ts}
  defp export_names([{:p, ",", _} | ts], acc), do: export_names(ts, acc)

  defp export_names([{:id, local, _}, {:id, "as", _}, {k, exported, _} | ts], acc)
       when k in [:id, :str],
       do: export_names(ts, [{local, exported} | acc])

  defp export_names([{:id, name, _} | ts], acc), do: export_names(ts, [{name, name} | acc])
  defp export_names(_ts, _acc), do: throw({:syntax, "bad export list"})

  defp expression_statement(ts) do
    {e, ts} = expression(ts)
    {{:expr, e}, semi(ts)}
  end

  # `using` followed, on the same line, by a binding name starts a using declaration
  defp using_start?([{:id, "using", _}, {:id, name, false} | _]),
    do: name not in ["in", "instanceof", "of", "let"] and name not in @reserved

  defp using_start?(_), do: false

  # the bindings of a using declaration are plain names and always have an initializer
  defp using_declarators(ts) do
    {decls, ts} = declarators(ts, [])

    for {pat, init} <- decls do
      unless match?({:id, _}, pat) and init != nil,
        do: throw({:syntax, "invalid using declaration"})

      {:id, name} = pat
      check_strict_name(name)
    end

    {decls, ts}
  end

  defp let_decl(ts) do
    {decl, ts} = declaration("let", ts)
    {decl, semi(ts)}
  end

  defp declaration(kind, ts) do
    {decls, ts} = declarators(ts, [])
    {{:var, String.to_atom(kind), decls}, ts}
  end

  defp declarators(ts, acc) do
    {pat, ts} = pattern(ts, false)

    {init, ts} =
      case ts do
        [{:p, "=", _} | ts] -> assignment(ts)
        ts -> {nil, ts}
      end

    acc = [{pat, init} | acc]

    case ts do
      [{:p, ",", _} | ts] -> declarators(ts, acc)
      ts -> {Enum.reverse(acc), ts}
    end
  end

  # the body of a loop: `break` and `continue` are allowed in it
  defp loop_body(ts) do
    depth = Process.get(:js_loop, 0)
    Process.put(:js_loop, depth + 1)

    try do
      body_statement(ts)
    after
      Process.put(:js_loop, depth)
    end
  end

  # does the statement after a label (or a run of labels) iterate?
  defp loop_ahead?([{:id, _, _}, {:p, ":", _} | ts]), do: loop_ahead?(ts)
  defp loop_ahead?([{:id, kw, _} | _]), do: kw in ["for", "while", "do"]
  defp loop_ahead?(_), do: false

  # early errors of `break` and `continue`
  defp check_jump("break", nil) do
    if Process.get(:js_loop, 0) == 0 and Process.get(:js_switch, 0) == 0,
      do: throw({:syntax, "break outside a loop or switch"})
  end

  defp check_jump("continue", nil) do
    if Process.get(:js_loop, 0) == 0, do: throw({:syntax, "continue outside a loop"})
  end

  defp check_jump(kw, label) do
    case List.keyfind(Process.get(:js_labels, []), label, 0) do
      nil ->
        throw({:syntax, "undefined label #{label}"})

      {_, false} when kw == "continue" ->
        throw({:syntax, "continue to a label that is not a loop"})

      _ ->
        :ok
    end
  end

  # a function body starts a new world for labels, loops and switches
  defp fresh_jumps(fun, in_fn?) do
    saved =
      {Process.get(:js_labels, []), Process.get(:js_loop, 0), Process.get(:js_switch, 0),
       Process.get(:js_fn, true)}

    Process.put(:js_labels, [])
    Process.put(:js_loop, 0)
    Process.put(:js_switch, 0)
    Process.put(:js_fn, in_fn?)

    try do
      fun.()
    after
      {l, lp, sw, f} = saved
      Process.put(:js_labels, l)
      Process.put(:js_loop, lp)
      Process.put(:js_switch, sw)
      Process.put(:js_fn, f)
    end
  end

  defp for_statement(ts) do
    case ts do
      [{:id, kw, _} | rest] when kw in ["var", "let", "const"] ->
        {pat, after_pat} = pattern(rest, false)

        case after_pat do
          [{:id, of_in, _} | t] when of_in in ["of", "in"] ->
            {obj, t} = if of_in == "of", do: assignment(t), else: expression(t)
            t = expect(t, ")")
            {body, t} = loop_body(t)
            {{if(of_in == "of", do: :forof, else: :forin), String.to_atom(kw), pat, obj, body}, t}

          _ ->
            {decl, t} = declaration(kw, rest)
            for_rest(decl, t)
        end

      [{:id, "using", _}, {:id, n, false} | rest]
      when n not in @reserved and n not in ["in", "instanceof", "of", "let"] ->
        using_for(:using, [{:id, n, false} | rest])

      [{:id, "using", _}, {:id, "of", false}, {:p, "=", _} | _] ->
        using_for(:using, tl(ts))

      [{:id, "await", _}, {:id, "using", _}, {:id, n, false} | rest]
      when n not in @reserved and n not in ["in", "instanceof", "let"] ->
        unless Process.get(:js_async, false), do: throw({:syntax, "await using outside async"})
        using_for(:await_using, [{:id, n, false} | rest])

      [{:p, ";", _} | _] ->
        for_rest(nil, ts)

      _ ->
        {lhs, after_lhs} =
          case destructuring_head(ts) do
            nil ->
              try do
                unary_or_lhs(ts)
              catch
                # an init such as `typeof a == "x" && b()` is no left-hand side
                {:syntax, _} -> {nil, []}
              end

            head ->
              head
          end

        case after_lhs do
          [{:id, of_in, _} | t] when of_in in ["of", "in"] ->
            {obj, t} = if of_in == "of", do: assignment(t), else: expression(t)
            t = expect(t, ")")
            {body, t} = loop_body(t)
            {{if(of_in == "of", do: :forof, else: :forin), nil, lhs, obj, body}, t}

          _ ->
            {e, t} = expression(ts)
            for_rest({:expr, e}, t)
        end
    end
  end

  # `for (using x of y) body` takes each value into a fresh name and declares `x` from it in
  # the iteration's block; `for (using x = a; ...)` disposes when the whole loop is done
  defp using_for(kind, ts) do
    {pat, after_pat} = pattern(ts, false)

    case after_pat do
      [{:id, "of", _} | t] ->
        {:id, name} = pat
        check_strict_name(name)
        {obj, t} = assignment(t)
        t = expect(t, ")")
        {body, t} = loop_body(t)
        tmp = " using"
        node = {:using, kind, name, {:id, tmp}, [body]}
        {{:forof, :const, {:id, tmp}, obj, {:block, [node]}}, t}

      [{:id, "in", _} | _] ->
        throw({:syntax, "using in a for-in head"})

      _ ->
        {decls, t} = using_declarators(ts)
        {loop, t} = for_rest(nil, t)
        {{:block, [nest_using(kind, decls, [loop])]}, t}
    end
  end

  defp unary_or_lhs(ts), do: postfix(ts)

  # `for ([a, b] of x)` / `for ({a} of x)`: a pattern in the head
  defp destructuring_head([{:p, open, _} | _] = ts) when open in ["[", "{"] do
    outer = Process.get(:js_assign_pattern, false)
    Process.put(:js_assign_pattern, true)

    try do
      {pat, rest} = pattern(ts, false)

      case rest do
        [{:id, w, _} | _] when w in ["of", "in"] -> {pat, rest}
        _ -> nil
      end
    catch
      {:syntax, _} -> nil
    after
      Process.put(:js_assign_pattern, outer)
    end
  end

  defp destructuring_head(_), do: nil

  defp for_rest(init, ts) do
    ts = expect(ts, ";")

    {test, ts} =
      case ts do
        [{:p, ";", _} | _] -> {nil, ts}
        _ -> expression(ts)
      end

    ts = expect(ts, ";")

    {update, ts} =
      case ts do
        [{:p, ")", _} | _] -> {nil, ts}
        _ -> expression(ts)
      end

    ts = expect(ts, ")")
    {body, ts} = loop_body(ts)
    {{:for, init, test, update, body}, ts}
  end

  defp switch_cases([{:p, "}", _} | ts], acc), do: {Enum.reverse(acc), ts}

  defp switch_cases([{:id, kw, _} | ts], acc) when kw in ["case", "default"] do
    {test, ts} =
      if kw == "case" do
        expression(ts)
      else
        {:default, ts}
      end

    ts = expect(ts, ":")
    {body, ts} = case_body(ts, [])
    switch_cases(ts, [{test, body} | acc])
  end

  defp switch_cases(_, _), do: throw({:syntax, "bad switch body"})

  defp case_body([{:id, kw, _} | _] = ts, acc) when kw in ["case", "default"],
    do: {Enum.reverse(acc), ts}

  defp case_body([{:p, "}", _} | _] = ts, acc), do: {Enum.reverse(acc), ts}

  defp case_body(ts, acc) do
    {stmt, ts} = statement(ts)

    if using_decl?(stmt), do: throw({:syntax, "using declaration in a case clause"})

    case_body(ts, [stmt | acc])
  end

  defp block_body([{:p, "}", _} | ts], acc), do: {Enum.reverse(acc), ts}
  defp block_body([{:eof, _, _} | _], _), do: throw({:syntax, "missing }"})

  defp block_body(ts, acc) do
    {stmt, ts} = statement(ts)
    block_body(ts, [stmt | acc])
  end

  # automatic semicolon insertion
  defp semi([{:p, ";", _} | ts]), do: ts
  defp semi([{:p, "}", _} | _] = ts), do: ts
  defp semi([{:eof, _, _} | _] = ts), do: ts
  defp semi([{_, _, nl} | _] = ts) when nl?(nl), do: ts
  defp semi([{_, v, _} | _]), do: throw({:syntax, "unexpected token #{inspect(v)}"})

  # ── patterns (binding targets) ─────────────────────────────

  defp pattern(ts, allow_default \\ true)

  # in a destructuring *assignment* a target can be a property: `({a: o.x, b: o.y[0]} = v)`
  defp pattern([{:id, name, _}, {:p, p, _} | _] = ts, allow_default)
       when p in [".", "["] and (name not in @reserved or name == "this") do
    if Process.get(:js_assign_pattern, false) do
      {target, ts} = call_chain(ts)
      with_default(target, ts, allow_default)
    else
      pattern_id(ts, allow_default)
    end
  end

  defp pattern([{:id, _, _} | _] = ts, allow_default), do: pattern_id(ts, allow_default)

  defp pattern([{:p, "[", _} | ts], allow_default) do
    {elems, ts} = array_pattern(ts, [])
    with_default({:arrpat, elems}, ts, allow_default)
  end

  defp pattern([{:p, "{", _} | ts], allow_default) do
    {props, rest, ts} = object_pattern(ts, [], nil)
    with_default({:objpat, props, rest}, ts, allow_default)
  end

  defp pattern([{_, v, _} | _], _),
    do: throw({:syntax, "unexpected token #{inspect(v)} in binding"})

  defp pattern_id([{:id, name, _} | ts], allow_default) when name not in @reserved do
    check_strict_name(name)
    with_default({:id, name}, ts, allow_default)
  end

  defp pattern_id([{_, v, _} | _], _),
    do: throw({:syntax, "unexpected token #{inspect(v)} in binding"})

  defp with_default(pat, [{:p, "=", _} | ts], true) do
    {e, ts} = assignment(ts)
    {{:default, pat, e}, ts}
  end

  defp with_default(pat, ts, _), do: {pat, ts}

  defp array_pattern([{:p, "]", _} | ts], acc), do: {Enum.reverse(acc), ts}
  defp array_pattern([{:p, ",", _} | ts], acc), do: array_pattern(ts, [nil | acc])

  defp array_pattern([{:p, "...", _} | ts], acc) do
    {pat, ts} = pattern(ts, false)
    ts = expect(ts, "]")
    {Enum.reverse([{:rest, pat} | acc]), ts}
  end

  defp array_pattern(ts, acc) do
    {pat, ts} = pattern(ts)

    case ts do
      [{:p, ",", _} | ts] -> array_pattern(ts, [pat | acc])
      [{:p, "]", _} | ts] -> {Enum.reverse([pat | acc]), ts}
      _ -> throw({:syntax, "bad array pattern"})
    end
  end

  defp object_pattern([{:p, "}", _} | ts], acc, rest), do: {Enum.reverse(acc), rest, ts}

  defp object_pattern([{:p, "...", _} | ts], acc, _rest) do
    {pat, ts} = pattern(ts, false)
    ts = expect(ts, "}")
    {Enum.reverse(acc), pat, ts}
  end

  defp object_pattern(ts, acc, rest) do
    {key, shorthand, ts} = property_key(ts)

    {prop, ts} =
      case ts do
        [{:p, ":", _} | ts] ->
          {pat, ts} = pattern(ts)
          {{key, pat}, ts}

        _ ->
          name = shorthand || throw({:syntax, "bad object pattern"})
          check_strict_name(name)
          {pat, ts} = with_default({:id, name}, ts, true)
          {{key, pat}, ts}
      end

    case ts do
      [{:p, ",", _} | ts] -> object_pattern(ts, [prop | acc], rest)
      [{:p, "}", _} | ts] -> {Enum.reverse([prop | acc]), rest, ts}
      _ -> throw({:syntax, "bad object pattern"})
    end
  end

  # → {key_node, shorthand_name_or_nil, rest}
  defp property_key([{:priv, name, _} | ts]), do: {{:priv, name}, "#" <> name, ts}
  defp property_key([{:id, name, _} | ts]), do: {{:str, name}, name, ts}
  defp property_key([{:eid, name, _} | ts]), do: {{:str, name}, nil, ts}

  defp property_key([{:str, s, mark} | ts]) do
    check_octal_string(mark)
    {{:str, s}, nil, ts}
  end

  defp property_key([{:num, n, _} | ts]), do: {{:str, Browser.JS.Num.to_string(n)}, nil, ts}
  defp property_key([{:bigint, n, _} | ts]), do: {{:str, Integer.to_string(n)}, nil, ts}

  defp property_key([{:p, "[", _} | ts]) do
    {e, ts} = assignment(ts)
    {{:computed, e}, nil, expect(ts, "]")}
  end

  defp property_key([{_, v, _} | _]),
    do: throw({:syntax, "unexpected token #{inspect(v)} as property name"})

  # ── classes ────────────────────────────────────────────────

  # after `class`: `Name? (extends expr)? { members }` -> {:class, name, super, members}
  # a private name used in the code being parsed; `class_rest` settles them against the
  # names the class declares, the rest belongs to an enclosing class or is an error
  defp private_ref(name), do: Process.put(:js_priv_refs, [name | Process.get(:js_priv_refs, [])])

  defp check_private_names(members) do
    declared =
      for {:cmember, kind, {:priv, n}, _, static?} <- members do
        if n == "constructor", do: throw({:syntax, "#constructor is not a valid private name"})
        {n, kind, static?}
      end

    declared
    |> Enum.group_by(&elem(&1, 0))
    |> Enum.each(fn {n, entries} ->
      kinds = entries |> Enum.map(&elem(&1, 1)) |> Enum.sort()
      statics = entries |> Enum.map(&elem(&1, 2)) |> Enum.uniq()

      unless length(entries) == 1 or (kinds == [:get, :set] and length(statics) == 1),
        do: throw({:syntax, "private name #" <> n <> " is declared twice"})
    end)

    Enum.map(declared, &elem(&1, 0))
  end

  # early errors of a class body: special member names, `super()` and `arguments` where they
  # are not allowed
  defp check_class_members(members, derived?) do
    ctor = fn
      {:cmember, kind, {:str, "constructor"}, _, false} -> {true, kind}
      {:cmember, kind, "constructor", _, false} -> {true, kind}
      _ -> false
    end

    ctors = for m <- members, {true, kind} <- [ctor.(m)], do: {m, kind}

    if length(ctors) > 1, do: throw({:syntax, "a class may only have one constructor"})

    for {:cmember, kind, key, value, static?} = m <- members do
      name =
        case key do
          {:str, n} -> n
          n when is_binary(n) -> n
          _ -> nil
        end

      cond do
        ctor.(m) != false and (kind in [:get, :set] or not plain_method?(value)) and
            kind != :field ->
          throw({:syntax, "class constructor may not be an accessor, generator or async"})

        kind == :field and name == "constructor" ->
          throw({:syntax, "classes may not have a field named 'constructor'"})

        static? and name == "prototype" and kind != :block ->
          throw({:syntax, "classes may not have a static member named 'prototype'"})

        true ->
          :ok
      end

      accessor_params!(kind, value)

      case value do
        {:gen, fun} -> check_no_yield(method_code(fun))
        {:async, {:gen, fun}} -> check_no_yield(method_code(fun))
        _ -> :ok
      end

      case kind do
        :block ->
          if contains_node?(value, &(&1 == {:id, "arguments"})),
            do: throw({:syntax, "'arguments' is not allowed in a class static block"})

          if contains_node?(value, &match?({:call, {:super}, _, _}, &1)),
            do: throw({:syntax, "'super' call is not allowed in a class static block"})

        :field ->
          if value != nil and contains_node?(value, &(&1 == {:id, "arguments"})),
            do: throw({:syntax, "'arguments' is not allowed in a class field initializer"})

          if value != nil and contains_node?(value, &(&1 == {:super})),
            do: throw({:syntax, "'super' keyword unexpected here"})

        _ ->
          allowed? = derived? and ctor.(m) != false

          if not allowed? and contains_node?(method_code(value), &(&1 == {:super})),
            do: throw({:syntax, "'super' keyword unexpected here"})
      end
    end

    :ok
  end

  defp accessor_params!(:get, value) do
    if match?([[_ | _], _], method_code(value)),
      do: throw({:syntax, "a getter takes no parameters"})
  end

  defp accessor_params!(:set, value) do
    case method_code(value) do
      [[{:rest, _}], _] -> throw({:syntax, "a setter takes exactly one parameter"})
      [[_], _] -> :ok
      _ -> throw({:syntax, "a setter takes exactly one parameter"})
    end
  end

  defp accessor_params!(_, _), do: :ok

  defp check_no_yield([params, _body]) do
    if contains_node?(params, &match?({:yield, _, _}, &1)),
      do: throw({:syntax, "yield expression in generator parameters"})
  end

  # the parameters and body of a method value, whatever generator/async wrapping it has
  defp method_code({tag, fun}) when tag in [:async, :gen], do: method_code(fun)
  defp method_code({:fn, _, params, body, _}), do: [params, body]
  defp method_code(other), do: other

  defp plain_method?({:fn, _, _, _, _}), do: true
  defp plain_method?(_), do: false

  # does `ast` hold a node satisfying `pred`, outside nested non-arrow functions and classes?
  defp contains_node?(ast, pred) do
    cond do
      pred.(ast) -> true
      match?({:fn, _, _, _, m} when m not in [:arrow, :arrow_expr], ast) -> false
      match?({:class, _, _, _}, ast) -> false
      is_tuple(ast) -> ast |> Tuple.to_list() |> Enum.any?(&contains_node?(&1, pred))
      is_list(ast) -> Enum.any?(ast, &contains_node?(&1, pred))
      true -> false
    end
  end

  defp class_rest(ts) do
    outer_refs = Process.get(:js_priv_refs, [])
    Process.put(:js_priv_refs, [])

    {name, ts} =
      case ts do
        [{:id, n, _} | t] when n not in @reserved and n != "extends" -> {n, t}
        t -> {nil, t}
      end

    if name in @strict_reserved or name in ["eval", "arguments"] or
         (name == "await" and Process.get(:js_static_block, false)),
       do: throw({:syntax, "#{name} is not a valid class name"})

    outer = strict?()
    Process.put(:js_strict, true)

    {super, ts} =
      case ts do
        [{:id, "extends", _} | t] -> call_chain(t)
        t -> {nil, t}
      end

    # private names in the heritage belong to the enclosing class
    outer_refs = Process.get(:js_priv_refs, []) ++ outer_refs
    Process.put(:js_priv_refs, [])

    ts = expect(ts, "{")
    nt = Process.put(:js_nt, true)
    {members, ts} = class_members(ts, [])
    Process.put(:js_nt, nt)
    Process.put(:js_strict, outer)

    check_class_members(members, super != nil)
    names = check_private_names(members)
    unresolved = Enum.reject(Process.get(:js_priv_refs, []), &(&1 in names))
    Process.put(:js_priv_refs, unresolved ++ outer_refs)
    {{:class, name, super, members}, ts}
  end

  defp class_members([{:p, "}", _} | ts], acc), do: {Enum.reverse(acc), ts}
  defp class_members([{:p, ";", _} | ts], acc), do: class_members(ts, acc)

  defp class_members([{:id, "static", _}, {:p, "{", _} | ts], acc) do
    outer = Process.get(:js_generator, false)
    outer_sb = Process.put(:js_static_block, true)
    Process.put(:js_generator, false)

    try do
      {body, ts} = fresh_jumps(fn -> block_body(ts, []) end, false)
      check_scope(body, true, [])
      class_members(ts, [{:cmember, :block, nil, body, true} | acc])
    after
      Process.put(:js_generator, outer)
      Process.put(:js_static_block, outer_sb || false)
    end
  end

  defp class_members(ts, acc) do
    {static?, ts} = class_modifier(ts, "static")
    {async?, ts} = class_modifier(ts, "async")

    {generator?, ts} =
      case ts do
        [{:p, "*", _} | t] -> {true, t}
        _ -> {false, ts}
      end

    {kind, ts} =
      case ts do
        [{:id, k, _}, {t, _, _} | _]
        when k in ["get", "set"] and t in [:id, :str, :num, :bigint, :priv] ->
          {String.to_atom(k), tl(ts)}

        [{:id, k, _}, {:p, "[", _} | _] when k in ["get", "set"] ->
          {String.to_atom(k), tl(ts)}

        _ ->
          {:method, ts}
      end

    {key, shorthand, after_key} = property_key(ts)

    case after_key do
      [{:p, "(", _} | _] ->
        if async?, do: Process.put(:js_async_next, true)
        Process.put(:js_class_method, true)

        {{:fn, _, _, _, _} = fun, ts} =
          function_rest({:method, shorthand}, after_key, generator?)

        value =
          cond do
            async? and generator? -> {:async, {:gen, fun}}
            async? -> {:async, fun}
            generator? -> {:gen, fun}
            true -> fun
          end

        class_members(ts, [{:cmember, kind, key, value, static?} | acc])

      [{:p, "=", _} | t] ->
        {init, ts} = assignment(t)
        class_members(semi_field(ts), [{:cmember, :field, key, init, static?} | acc])

      t ->
        class_members(semi_field(t), [{:cmember, :field, key, nil, static?} | acc])
    end
  end

  # `static` / `async` as a modifier: followed by a member name, not by `(`, `=`, `;` or `}`
  defp class_modifier([{:id, word, _}, {t, v, _} | _] = ts, word) do
    if t == :p and v in ["(", "=", ";", "}"], do: {false, ts}, else: {true, tl(ts)}
  end

  defp class_modifier(ts, _), do: {false, ts}

  defp semi_field([{:p, ";", _} | ts]), do: ts
  defp semi_field([{:p, "}", _} | _] = ts), do: ts
  defp semi_field([{_, _, nl} | _] = ts) when nl?(nl), do: ts
  defp semi_field(_), do: throw({:syntax, "expected ';' after a class field"})

  # ── functions ──────────────────────────────────────────────

  # after `function name?` — at the parameter list
  defp function_rest(name, ts, generator? \\ false) do
    outer = Process.get(:js_generator, false)
    outer_async = Process.get(:js_async, false)
    Process.put(:js_generator, generator?)
    Process.put(:js_async, Process.delete(:js_async_next) == true)
    outer_sb = Process.put(:js_static_block, false)
    class_method? = Process.delete(:js_class_method) == true
    nt = Process.put(:js_nt, true)

    try do
      {params, ts} = params(expect(ts, "("), [])
      ts = expect(ts, "{")
      {body, ts} = function_body(ts, params, match?({:method, _}, name))
      check_super_use(name, [params, body], class_method?)

      # a "use strict" in the body makes the function's own name strict code too
      if is_binary(name) and match?([{:expr, {:str, "use strict"}} | _], body) and
           (name in ["eval", "arguments"] or name in @strict_reserved),
         do: throw({:syntax, "unexpected #{name} as the name of a strict function"})

      {{:fn, name, params, body, false}, ts}
    after
      Process.put(:js_generator, outer)
      Process.put(:js_async, outer_async)
      Process.put(:js_static_block, outer_sb || false)
      Process.put(:js_nt, nt)
    end
  end

  # `function*`: the function node wrapped as a generator
  defp generator_rest(name, ts) do
    {fun, ts} = function_rest(name, ts, true)
    {{:gen, fun}, ts}
  end

  defp params([{:p, ")", _} | ts], acc), do: {Enum.reverse(acc), ts}

  defp params([{:p, "...", _} | ts], acc) do
    {pat, ts} = pattern(ts, false)
    {Enum.reverse([{:rest, pat} | acc]), expect(ts, ")")}
  end

  defp params(ts, acc) do
    {pat, ts} = pattern(ts)

    case ts do
      [{:p, ",", _} | ts] -> params(ts, [pat | acc])
      [{:p, ")", _} | ts] -> {Enum.reverse([pat | acc]), ts}
      _ -> throw({:syntax, "bad parameter list"})
    end
  end

  # is the `(` at the head of `ts` the start of an arrow function's parameters?
  defp arrow_ahead?([{:p, "(", _} | ts]), do: arrow_after_parens(ts, 1)
  defp arrow_ahead?([{:id, name, _}, {:p, "=>", false} | _]) when name not in @reserved, do: true
  defp arrow_ahead?(_), do: false

  defp arrow_after_parens([{:eof, _, _} | _], _), do: false

  defp arrow_after_parens([{:p, p, _} | ts], d) when p in ["(", "[", "{"],
    do: arrow_after_parens(ts, d + 1)

  defp arrow_after_parens([{:p, p, _} | ts], d) when p in ["]", "}"],
    do: arrow_after_parens(ts, d - 1)

  defp arrow_after_parens([{:p, ")", _} | ts], 1), do: match?([{:p, "=>", false} | _], ts)
  defp arrow_after_parens([{:p, ")", _} | ts], d), do: arrow_after_parens(ts, d - 1)
  defp arrow_after_parens([_ | ts], d), do: arrow_after_parens(ts, d)

  defp arrow([{:id, name, _}, {:p, "=>", _} | ts]), do: arrow_body([{:id, name}], ts)

  defp arrow([{:p, "(", _} | ts]) do
    {params, ts} = params(ts, [])
    arrow_body(params, expect(ts, "=>"))
  end

  defp arrow_body(params, [{:p, "{", _} | ts]) do
    outer_sb = Process.put(:js_static_block, false)
    {body, ts} = function_body(ts, params, true)
    Process.put(:js_static_block, outer_sb || false)
    {{:fn, nil, params, body, :arrow}, ts}
  end

  defp arrow_body(params, ts) do
    check_unique_params(params)
    if strict?(), do: check_strict_params(params)
    {e, ts} = assignment(ts)
    {{:fn, nil, params, e, :arrow_expr}, ts}
  end

  # ── expressions ────────────────────────────────────────────

  defp expression(ts) do
    {e, ts} = assignment(ts)

    case ts do
      [{:p, ",", _} | _] -> comma(ts, [e])
      _ -> {e, ts}
    end
  end

  defp comma([{:p, ",", _} | ts], acc) do
    {e, ts} = assignment(ts)
    comma(ts, [e | acc])
  end

  defp comma(ts, acc), do: {{:seq, Enum.reverse(acc)}, ts}

  defp assignment([{:id, "async", _} | [_ | _] = rest] = ts) do
    cond do
      arrow_ahead?(rest) and not match?([{_, _, nl} | _] when nl?(nl), rest) ->
        {fun, ts} = arrow(rest)
        {{:async, fun}, ts}

      true ->
        assignment_plain(ts)
    end
  end

  defp assignment([{:id, "yield", _} | rest] = ts) do
    if Process.get(:js_generator, false) do
      yield_expression(rest)
    else
      if strict?(), do: throw({:syntax, "yield is reserved in strict mode"})
      assignment_plain(ts)
    end
  end

  defp assignment(ts), do: assignment_plain(ts)

  defp yield_expression(ts) do
    case ts do
      [{_, _, nl} | _] when nl?(nl) ->
        {{:yield, {:lit, :undefined}, false}, ts}

      [{:p, p, _} | _] when p in [")", "]", "}", ",", ";", ":"] ->
        {{:yield, {:lit, :undefined}, false}, ts}

      [] ->
        {{:yield, {:lit, :undefined}, false}, ts}

      [{:p, "*", _} | t] ->
        {e, ts} = assignment(t)
        {{:yield, e, true}, ts}

      _ ->
        {e, ts} = assignment(ts)
        {{:yield, e, false}, ts}
    end
  end

  defp assignment_plain([{:p, open, _} | _] = ts) when open in ["[", "{"] do
    if destructuring_ahead?(tl(ts), 1) do
      Process.put(:js_assign_pattern, true)

      {pat, ts} =
        try do
          pattern(ts, false)
        after
          Process.put(:js_assign_pattern, false)
        end

      [{:p, "=", _} | ts] = ts
      {right, ts} = assignment(ts)
      {{:destructure, pat, right}, ts}
    else
      assignment_value(ts)
    end
  end

  defp assignment_plain(ts), do: assignment_value(ts)

  # `[a, b] = …` or `{a, b} = …`: the bracket at the head closes and `=` follows
  defp destructuring_ahead?([{:eof, _, _} | _], _), do: false

  defp destructuring_ahead?([{:p, p, _} | ts], d) when p in ["(", "[", "{"],
    do: destructuring_ahead?(ts, d + 1)

  defp destructuring_ahead?([{:p, p, _} | ts], d) when p in [")", "]", "}"] do
    if d == 1, do: match?([{:p, "=", _} | _], ts), else: destructuring_ahead?(ts, d - 1)
  end

  defp destructuring_ahead?([_ | ts], d), do: destructuring_ahead?(ts, d)

  defp assignment_value(ts) do
    if arrow_ahead?(ts) do
      arrow(ts)
    else
      {left, ts} = conditional(ts)

      case ts do
        [{:p, op, _} | rest] when op in @assign_ops ->
          unless assignable?(left), do: throw({:syntax, "invalid assignment target"})
          {right, rest} = assignment(rest)
          {{if(strict?(), do: :sassign, else: :assign), op, left, right}, rest}

        _ ->
          {left, ts}
      end
    end
  end

  defp assignable?({:id, n}), do: not (strict?() and n in ["eval", "arguments"])
  defp assignable?({:member, _, _, false}), do: true
  defp assignable?(_), do: false

  defp conditional(ts) do
    {c, ts} = binary(ts, 1)

    case ts do
      [{:p, "?", _} | ts] ->
        {a, ts} = assignment(ts)
        ts = expect(ts, ":")
        {b, ts} = assignment(ts)
        {{:cond, c, a, b}, ts}

      _ ->
        {c, ts}
    end
  end

  defp binary(ts, min) do
    {left, ts} = unary(ts)
    binary_loop(left, ts, min)
  end

  defp binary_loop(left, [{kind, op, _} | rest] = ts, min) when kind in [:p, :id] do
    case @binary[op] do
      prec when is_integer(prec) and prec >= min and (kind == :p or op in ["in", "instanceof"]) ->
        # `**` is right-associative, everything else left
        {right, rest} = binary(rest, if(op == "**", do: prec, else: prec + 1))

        node =
          if op in ["&&", "||", "??"],
            do: {:logical, op, left, right},
            else: {:binary, op, left, right}

        binary_loop(node, rest, min)

      _ ->
        {left, ts}
    end
  end

  defp binary_loop(left, ts, _), do: {left, ts}

  defp private_member?({:member, _, {:priv, _}, _}), do: true
  defp private_member?({:chain, e}), do: private_member?(e)
  defp private_member?(_), do: false

  defp unary([{:p, op, _} | ts]) when op in ["!", "-", "+", "~"] do
    {e, ts} = unary(ts)

    if op == "delete" and strict?() and match?({:id, _}, e),
      do: throw({:syntax, "delete of an identifier in strict mode"})

    {{:unary, op, e}, ts}
  end

  defp unary([{:p, op, _} | ts]) when op in ["++", "--"] do
    {e, ts} = unary(ts)
    unless assignable?(e), do: throw({:syntax, "invalid #{op} operand"})
    {{if(strict?(), do: :supdate, else: :update), op, true, e}, ts}
  end

  defp unary([{:id, "await", _}, {k, v, _} | _] = [_ | ts])
       when k in [:id, :num, :bigint, :str, :tmpl, :regex] and
              (k != :id or v not in ["in", "of", "instanceof"]) do
    {e, ts} = unary(ts)
    {{:await, e}, ts}
  end

  defp unary([{:id, "await", _}, {:p, p, _} | _] = [_ | ts])
       when p in ["(", "[", "{", "!", "~"] do
    {e, ts} = unary(ts)
    {{:await, e}, ts}
  end

  defp unary([{:id, op, _} | ts]) when op in ["typeof", "void", "delete"] do
    {e, ts} = unary(ts)

    if op == "delete" and private_member?(e),
      do: throw({:syntax, "private fields can not be deleted"})

    op = if op == "delete" and strict?(), do: "sdelete", else: op
    {{:unary, op, e}, ts}
  end

  defp unary(ts), do: postfix(ts)

  defp postfix(ts) do
    {e, ts} = call_chain(ts)

    case ts do
      [{:p, op, false} | ts] when op in ["++", "--"] ->
        unless assignable?(e), do: throw({:syntax, "invalid #{op} operand"})
        {{if(strict?(), do: :supdate, else: :update), op, false, e}, ts}

      _ ->
        {e, ts}
    end
  end

  # member access, calls and optional chains; any `?.` wraps the whole chain
  defp call_chain(ts) do
    {base, ts} =
      case ts do
        [{:id, "new", _}, {:p, ".", _}, {:eid, "target", _} | _] ->
          throw({:syntax, "new.target must not contain escapes"})

        [{:id, "new", _}, {:p, ".", _}, {:id, "target", _} | t] ->
          unless Process.get(:js_nt, true), do: throw({:syntax, "new.target outside a function"})
          {{:new_target}, t}

        [{:id, "new", _}, {:id, "import", _}, {:p, "(", _} | _] ->
          throw({:syntax, "new import() is not allowed"})

        [{:id, "new", _} | ts] ->
          new_expression(ts)

        _ ->
          primary(ts)
      end

    {e, ts, chained?} = chain(base, ts, false)
    {if(chained?, do: {:chain, e}, else: e), ts}
  end

  defp chain(e, [{:p, ".", _}, {:priv, name, _} | ts], c) do
    private_ref(name)
    chain({:member, e, {:priv, name}, false}, ts, c)
  end

  defp chain(e, [{:p, "?.", _}, {:priv, name, _} | ts], _) do
    private_ref(name)
    chain({:member, e, {:priv, name}, true}, ts, true)
  end

  defp chain(e, [{:p, ".", _}, {k, name, _} | ts], c) when k in [:id, :eid],
    do: chain({:member, e, {:str, name}, false}, ts, c)

  defp chain(e, [{:p, "?.", _}, {k, name, _} | ts], _) when k in [:id, :eid],
    do: chain({:member, e, {:str, name}, true}, ts, true)

  defp chain(e, [{:p, "?.", _}, {:p, "[", _} | ts], _) do
    {k, ts} = expression(ts)
    chain({:member, e, k, true}, expect(ts, "]"), true)
  end

  defp chain(e, [{:p, "?.", _}, {:p, "(", _} | ts], _) do
    {args, ts} = arguments(ts, [])
    chain({:call, e, args, true}, ts, true)
  end

  # a tagged template: `tag`a${b}c`` calls tag(["a", "c"], b), the strings with a `raw` list
  defp chain(_e, [{:tmpl, _, _} | _], true),
    do: throw({:syntax, "a template literal cannot follow an optional chain"})

  defp chain(e, [{:tmpl, parts, _} | ts], c) do
    {parts, raw} = template_parts(parts)
    is_text = &(is_binary(&1) or &1 == :bad)
    cooked = parts |> Enum.filter(is_text) |> Enum.map(&if(&1 == :bad, do: :undefined, else: &1))
    exprs = Enum.reject(parts, is_text)
    chain({:call, e, [{:tagged_strings, cooked, raw} | exprs], false}, ts, c)
  end

  defp chain(e, [{:p, "[", _} | ts], c) do
    {k, ts} = expression(ts)
    chain({:member, e, k, false}, expect(ts, "]"), c)
  end

  defp chain(e, [{:p, "(", _} | ts], c) do
    {args, ts} = arguments(ts, [])
    chain({:call, e, args, false}, ts, c)
  end

  defp chain(e, ts, c), do: {e, ts, c}

  defp new_expression(ts) do
    {callee, ts} =
      case ts do
        [{:id, "new", _}, {:p, ".", _}, {:eid, "target", _} | _] ->
          throw({:syntax, "new.target must not contain escapes"})

        [{:id, "new", _}, {:p, ".", _}, {:id, "target", _} | t] ->
          unless Process.get(:js_nt, true), do: throw({:syntax, "new.target outside a function"})
          {{:new_target}, t}

        [{:id, "new", _}, {:id, "import", _}, {:p, "(", _} | _] ->
          throw({:syntax, "new import() is not allowed"})

        [{:id, "new", _} | t] ->
          new_expression(t)

        [{:id, "import", _}, {:p, "(", _} | _] ->
          throw({:syntax, "new import() is not allowed"})

        _ ->
          primary(ts)
      end

    {callee, ts} = member_only(callee, ts)

    {args, ts} =
      case ts do
        [{:p, "(", _} | t] -> arguments(t, [])
        t -> {[], t}
      end

    {{:new, callee, args}, ts}
  end

  defp member_only(e, [{:p, ".", _}, {k, name, _} | ts]) when k in [:id, :eid],
    do: member_only({:member, e, {:str, name}, false}, ts)

  defp member_only(e, [{:p, "[", _} | ts]) do
    {k, ts} = expression(ts)
    member_only({:member, e, k, false}, expect(ts, "]"))
  end

  defp member_only(e, ts), do: {e, ts}

  defp arguments([{:p, ")", _} | ts], acc), do: {Enum.reverse(acc), ts}

  defp arguments(ts, acc) do
    {arg, ts} =
      case ts do
        [{:p, "...", _} | t] ->
          {e, t} = assignment(t)
          {{:spread, e}, t}

        _ ->
          assignment(ts)
      end

    case ts do
      [{:p, ",", _} | ts] -> arguments(ts, [arg | acc])
      [{:p, ")", _} | ts] -> {Enum.reverse([arg | acc]), ts}
      _ -> throw({:syntax, "bad argument list"})
    end
  end

  # -> {parts with the expressions parsed (text chunks that are empty are left out), raw chunks}
  defp template_parts(parts) do
    {raw, parts} =
      case List.last(parts) do
        {:raw, raw} -> {raw, Enum.drop(parts, -1)}
        _ -> {[], parts}
      end

    parts =
      Enum.map(parts, fn
        {:expr, toks} ->
          {e, rest} = expression(toks)
          match?([{:eof, _, _}], rest) || throw({:syntax, "bad template expression"})
          e

        s ->
          s
      end)

    {parts, raw}
  end

  defp primary([{:num, n, _} | ts]), do: {{:num, n}, ts}
  defp primary([{:bigint, n, _} | ts]), do: {{:bigint, n}, ts}

  defp primary([{:str, s, mark} | ts]) do
    check_octal_string(mark)
    {{:str, s}, ts}
  end

  defp primary([{:regex, {source, flags}, _} | ts]) do
    case Browser.JS.RegExp.validate(source, flags) do
      :ok -> {{:regex, source, flags}, ts}
      {:error, msg} -> throw({:syntax, msg})
    end
  end

  defp primary([{:tmpl, parts, _} | ts]) do
    {parts, _raw} = template_parts(parts)
    if :bad in parts, do: throw({:syntax, "invalid escape sequence in template literal"})
    {{:tmpl, parts}, ts}
  end

  defp primary([{:id, "true", _} | ts]), do: {{:lit, true}, ts}
  defp primary([{:id, "false", _} | ts]), do: {{:lit, false}, ts}
  defp primary([{:id, "null", _} | ts]), do: {{:lit, :null}, ts}
  defp primary([{:id, "this", _} | ts]), do: {{:this}, ts}

  defp primary([{:id, "class", _} | ts]), do: class_rest(ts)

  # `import(specifier)` and `import.meta`
  defp primary([{:id, "import", _}, {:p, "(", _} | ts]) do
    {e, ts} = assignment(ts)
    {{:import_call, e}, expect(ts, ")")}
  end

  defp primary([{:id, "import", _}, {:p, ".", _}, {:id, "meta", _} | ts]),
    do: {{:import_meta}, ts}

  defp primary([{:id, "super", _}, {:p, "(", _} | _] = [_ | ts]), do: {{:super}, ts}

  # `#x in obj`
  defp primary([{:priv, name, _}, {:id, "in", _} | _] = [{:priv, _, _} | ts]) do
    private_ref(name)
    {{:priv_ref, name}, ts}
  end

  defp primary([{:id, "super", _}, {:p, ".", _}, {:id, name, _} | ts]),
    do: {{:super_member, {:str, name}}, ts}

  defp primary([{:id, "super", _}, {:p, "[", _} | ts]) do
    {k, ts} = expression(ts)
    {{:super_member, k}, expect(ts, "]")}
  end

  defp primary([{:id, "async", _}, {:id, "function", _} | _] = [_ | rest]) do
    Process.put(:js_async_next, true)
    {fun, ts} = primary(rest)
    {{:async, fun}, ts}
  end

  defp primary([{:id, "function", _} | ts]) do
    {generator?, ts} =
      case ts do
        [{:p, "*", _} | t] -> {true, t}
        t -> {false, t}
      end

    {name, ts} =
      case ts do
        [{:id, n, _} | t] when n not in @reserved -> {n, t}
        t -> {nil, t}
      end

    if generator?, do: generator_rest(name, ts), else: function_rest(name, ts)
  end

  defp primary([{:id, name, _} | ts]) when name not in @reserved do
    if (name == "await" and
          (Process.get(:js_async, false) or Process.get(:js_static_block, false))) or
         (name == "yield" and Process.get(:js_generator, false)),
       do: throw({:syntax, "#{name} is not an identifier here"})

    if strict?() and name in @strict_reserved,
      do: throw({:syntax, "#{name} is a reserved word in strict mode"})

    {{:id, name}, ts}
  end

  defp primary([{:p, "(", _} | ts]) do
    {e, ts} = expression(ts)
    {e, expect(ts, ")")}
  end

  defp primary([{:p, "[", _} | ts]), do: array_literal(ts, [])
  defp primary([{:p, "{", _} | ts]), do: object_literal(ts, [])
  defp primary([{:eof, _, _} | _]), do: throw({:syntax, "unexpected end of input"})
  defp primary([{_, v, _} | _]), do: throw({:syntax, "unexpected token #{inspect(v)}"})

  defp array_literal([{:p, "]", _} | ts], acc), do: {{:array, Enum.reverse(acc)}, ts}
  defp array_literal([{:p, ",", _} | ts], acc), do: array_literal(ts, [:hole | acc])

  defp array_literal(ts, acc) do
    {el, ts} =
      case ts do
        [{:p, "...", _} | t] ->
          {e, t} = assignment(t)
          {{:spread, e}, t}

        _ ->
          assignment(ts)
      end

    case ts do
      [{:p, ",", _} | ts] -> array_literal(ts, [el | acc])
      [{:p, "]", _} | ts] -> {{:array, Enum.reverse([el | acc])}, ts}
      _ -> throw({:syntax, "bad array literal"})
    end
  end

  defp object_literal([{:p, "}", _} | ts], acc), do: {{:object, Enum.reverse(acc)}, ts}

  defp object_literal([{:p, "...", _} | ts], acc) do
    {e, ts} = assignment(ts)
    object_next(ts, [{:spread, e} | acc])
  end

  defp object_literal([{:p, "*", _} | rest], acc) do
    {key, shorthand, after_key} = property_key(rest)
    {fun, ts} = function_rest({:method, shorthand}, after_key, true)
    object_next(ts, [{:init, key, {:gen, fun}} | acc])
  end

  defp object_literal([{:id, "async", _}, {:p, "*", false} | _] = [_, _ | rest], acc) do
    {key, shorthand, after_key} = property_key(rest)
    Process.put(:js_async_next, true)
    {fun, ts} = function_rest({:method, shorthand}, after_key, true)
    object_next(ts, [{:init, key, {:async, {:gen, fun}}} | acc])
  end

  defp object_literal([{:id, "async", _}, {k, v, false} | _] = [_ | rest], acc)
       when k in [:id, :str, :num, :bigint] or (k == :p and v == "[") do
    {key, shorthand, after_key} = property_key(rest)
    Process.put(:js_async_next, true)
    {fun, ts} = function_rest({:method, shorthand}, after_key)
    object_next(ts, [{:init, key, {:async, fun}} | acc])
  end

  # `get x() {}` and `set x(v) {}`
  defp object_literal([{:id, kind, _}, {k, v, _} | _] = [_ | rest], acc)
       when kind in ["get", "set"] and (k in [:id, :str, :num, :bigint] or (k == :p and v == "[")) do
    {key, shorthand, after_key} = property_key(rest)

    case after_key do
      [{:p, "(", _} | _] ->
        {{:fn, _, params, _, _} = fun, ts} = function_rest({:method, shorthand}, after_key)

        case {kind, params} do
          {"get", []} -> :ok
          {"get", _} -> throw({:syntax, "a getter must not have parameters"})
          {"set", [{:rest, _}]} -> throw({:syntax, "a setter cannot take a rest parameter"})
          {"set", [_]} -> :ok
          {"set", _} -> throw({:syntax, "a setter must have exactly one parameter"})
        end

        object_next(ts, [{String.to_atom(kind <> "ter"), key, fun} | acc])

      _ ->
        object_literal_plain([{:id, kind, false} | rest], acc)
    end
  end

  defp object_literal(ts, acc), do: object_literal_plain(ts, acc)

  defp object_literal_plain(ts, acc) do
    {key, shorthand, after_key} = property_key(ts)

    {prop, ts} =
      case after_key do
        [{:p, ":", _} | t] ->
          {v, t} = assignment(t)
          # `__proto__: value` sets the prototype (a computed key or a shorthand does not)
          if key == {:str, "__proto__"}, do: {{:proto, v}, t}, else: {{:init, key, v}, t}

        [{:p, "(", _} | _] = t ->
          {fun, t} = function_rest({:method, shorthand}, t)
          {{:init, key, fun}, t}

        t ->
          name = shorthand || throw({:syntax, "bad object literal"})
          name in @reserved && throw({:syntax, "unexpected token #{inspect(name)}"})

          if strict?() and name in @strict_reserved,
            do: throw({:syntax, "#{name} is a reserved word here"})

          {{:init, key, {:id, name}}, t}
      end

    object_next(ts, [prop | acc])
  end

  defp object_next([{:p, ",", _} | ts], acc), do: object_literal(ts, acc)

  defp object_next([{:p, "}", _} | ts], acc) do
    # two `__proto__: v` entries are an error unless the literal turns out to be a pattern
    if Enum.count(acc, &match?({:proto, _}, &1)) > 1 and
         not match?([{:p, p, _} | _] when p in ["=", ",", "]", "}"], ts),
       do: throw({:syntax, "duplicate __proto__ in an object literal"})

    {{:object, Enum.reverse(acc)}, ts}
  end

  defp object_next(_, _), do: throw({:syntax, "bad object literal"})

  # ── token helpers ──────────────────────────────────────────

  defp expect([{:p, p, _} | ts], p), do: ts

  defp expect([{:eof, _, _} | _], p),
    do: throw({:syntax, "expected #{inspect(p)} but reached the end"})

  defp expect([{_, v, _} | _], p),
    do: throw({:syntax, "expected #{inspect(p)} but found #{inspect(v)}"})

  defp expect_id([{:id, id, _} | ts], id), do: ts
  defp expect_id(_, id), do: throw({:syntax, "expected #{inspect(id)}"})
end
