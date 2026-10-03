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

  def parse(src) do
    with {:ok, tokens} <- Lexer.tokenize(src) do
      try do
        Process.put(:js_strict, use_strict?(tokens))
        Process.put(:js_priv_refs, [])
        program = tokens |> statements() |> check_scope(true)

        case Process.get(:js_priv_refs) do
          [] -> :ok
          [n | _] -> throw({:syntax, "private name #" <> n <> " is not defined"})
        end

        {:ok, {:program, program}}
      catch
        {:syntax, msg} -> {:error, msg}
      end
    end
  end

  # ── redeclarations ─────────────────────────────────────────

  # Early errors of a statement list that is a scope: a lexical name (let, const, class, and
  # in blocks function declarations) declared twice, or also declared with var, or also a
  # parameter. At the top of a function or script, function declarations are var-scoped.
  defp check_scope(stmts, top?, params \\ []) do
    lexical =
      Enum.flat_map(stmts, fn
        {:var, k, decls} when k in [:let, :const] ->
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

    stmts
  end

  # ── strict mode ────────────────────────────────────────────

  @strict_reserved ~w(implements interface let package private protected public static yield)

  defp strict?, do: Process.get(:js_strict, false)

  # does the token list begin with a "use strict" directive?
  defp use_strict?([{:str, "use strict", _}, {:p, p, _} | _]) when p in [";", "}"], do: true
  defp use_strict?([{:str, "use strict", _}, {_, _, true} | _]), do: true
  defp use_strict?([{:str, "use strict", _}, {:eof, _, _} | _]), do: true
  defp use_strict?([{:str, _, _}, {:p, ";", _} | ts]), do: use_strict?(ts)
  defp use_strict?(_), do: false

  # a function body: strict when it opens with the directive (or is inside strict code)
  defp function_body(ts, params) do
    outer = strict?()

    if use_strict?(ts) do
      unless Enum.all?(params, &match?({:id, _}, &1)),
        do: throw({:syntax, "\"use strict\" in a function with non-simple parameters"})

      Process.put(:js_strict, true)
    end

    if strict?(), do: check_strict_params(params)
    {body, rest} = block_body(ts, [])

    names =
      if params == [], do: [], else: Enum.reduce(params, [], &Interp.pattern_names/2)

    Process.put(:js_strict, outer)
    {check_scope(body, true, names), rest}
  end

  defp check_strict_params(params) do
    names = for {:id, n} <- Enum.map(params, &strip_default/1), do: n

    if names != Enum.uniq(names), do: throw({:syntax, "duplicate parameter name in strict mode"})
    Enum.each(names, &check_strict_name/1)
  end

  defp strip_default({:default, p, _}), do: p
  defp strip_default(p), do: p

  defp check_strict_name(name) do
    if strict?() and (name in ["eval", "arguments"] or name in @strict_reserved),
      do: throw({:syntax, "unexpected #{name} in strict mode"})

    if name == "yield" and Process.get(:js_generator, false),
      do: throw({:syntax, "yield is reserved in generators"})
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

      _ ->
        {stmt, ts} = statement(ts)
        [stmt | statements(ts)]
    end
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
    {fun, ts} = generator_rest(name, ts)
    {{:fundecl, name, {:async, fun}}, ts}
  end

  defp statement([{:id, "async", _}, {:id, "function", _}, {:id, name, _} | ts])
       when name not in @reserved do
    {fun, ts} = function_rest(name, ts)
    {{:fundecl, name, {:async, fun}}, ts}
  end

  defp statement([{:id, "return", _} | ts]) do
    case ts do
      [{:p, ";", _} | ts] ->
        {{:return, nil}, ts}

      [{_, _, true} | _] ->
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
    {body, ts} = body_statement(ts)
    {{:while, c, body}, ts}
  end

  defp statement([{:id, "do", _} | ts]) do
    {body, ts} = body_statement(ts)
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
    {cases, ts} = switch_cases(ts, [])
    check_scope(Enum.flat_map(cases, &elem(&1, 1)), false)
    {{:switch, disc, cases}, ts}
  end

  defp statement([{:id, name, _}, {:p, ":", _} | ts]) when name not in @reserved do
    {stmt, ts} = body_statement(ts, true)
    {{:labeled, name, stmt}, ts}
  end

  defp statement([{:id, "debugger", _} | ts]), do: {{:empty}, semi(ts)}

  # ── modules ────────────────────────────────────────────────

  defp statement([{:id, "import", _}, {:str, spec, _} | ts]), do: {{:import, spec, []}, semi(ts)}

  defp statement([{:id, "import", _} | [{k, _, _} | _] = ts]) when k in [:id] do
    {bindings, ts} = import_bindings(ts, [])
    ts = expect_id(ts, "from")

    case ts do
      [{:str, spec, _} | ts] -> {{:import, spec, bindings}, semi(ts)}
      _ -> throw({:syntax, "expected a module name"})
    end
  end

  defp statement([{:id, "import", _}, {:p, "{", _} | _] = [_ | ts]) do
    {bindings, ts} = import_bindings(ts, [])
    ts = expect_id(ts, "from")

    case ts do
      [{:str, spec, _} | ts] -> {{:import, spec, bindings}, semi(ts)}
      _ -> throw({:syntax, "expected a module name"})
    end
  end

  defp statement([{:id, "import", _}, {:p, "*", _} | _] = [_ | ts]) do
    {bindings, ts} = import_bindings(ts, [])
    ts = expect_id(ts, "from")

    case ts do
      [{:str, spec, _} | ts] -> {{:import, spec, bindings}, semi(ts)}
      _ -> throw({:syntax, "expected a module name"})
    end
  end

  defp statement([{:id, "export", _}, {:id, "default", _} | ts]) do
    case ts do
      [{:id, "function", _}, {:id, name, _} | rest] when name not in @reserved ->
        {fun, rest} = function_rest(name, rest)
        {{:export_default, {:fundecl, name, fun}}, rest}

      _ ->
        {e, ts} = assignment(ts)
        {{:export_default, {:expr, e}}, semi(ts)}
    end
  end

  defp statement([{:id, "export", _}, {:p, "{", _} | ts]) do
    {names, ts} = export_names(ts, [])

    case ts do
      [{:id, "from", _}, {:str, spec, _} | ts] -> {{:export_from, spec, names}, semi(ts)}
      ts -> {{:export_names, names}, semi(ts)}
    end
  end

  defp statement([{:id, "export", _}, {:p, "*", _}, {:id, "from", _}, {:str, spec, _} | ts]),
    do: {{:export_from, spec, :all}, semi(ts)}

  defp statement([{:id, "export", _} | ts]) do
    case ts do
      [{:id, kw, _} | _] when kw in ["var", "let", "const", "function", "async"] ->
        {stmt, ts} = statement(ts)
        {{:export, stmt}, ts}

      _ ->
        throw({:syntax, "unsupported export"})
    end
  end

  defp statement([{:id, "class", _}, {:id, name, _} | _] = [_ | ts]) when name not in @reserved do
    {node, ts} = class_rest(ts)
    {{:var, :let, [{{:id, name}, node}]}, ts}
  end

  defp statement([{:id, "import", _}, {:p, p, _} | _] = ts) when p in ["(", "."],
    do: expression_statement(ts)

  defp statement([{:id, "with", _} | ts]) do
    if strict?(), do: throw({:syntax, "`with` in strict mode"})
    ts = expect(ts, "(")
    {obj, ts} = expression(ts)
    ts = expect(ts, ")")
    {body, ts} = body_statement(ts)
    {{:with, obj, body}, ts}
  end

  defp statement([{:id, kw, _} | _]) when kw in ~w(import enum),
    do: throw({:syntax, "`#{kw}` is not supported yet"})

  defp statement(ts), do: expression_statement(ts)

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

  defp for_statement(ts) do
    case ts do
      [{:id, kw, _} | rest] when kw in ["var", "let", "const"] ->
        {pat, after_pat} = pattern(rest, false)

        case after_pat do
          [{:id, of_in, _} | t] when of_in in ["of", "in"] ->
            {obj, t} = if of_in == "of", do: assignment(t), else: expression(t)
            t = expect(t, ")")
            {body, t} = body_statement(t)
            {{if(of_in == "of", do: :forof, else: :forin), String.to_atom(kw), pat, obj, body}, t}

          _ ->
            {decl, t} = declaration(kw, rest)
            for_rest(decl, t)
        end

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
            {body, t} = body_statement(t)
            {{if(of_in == "of", do: :forof, else: :forin), nil, lhs, obj, body}, t}

          _ ->
            {e, t} = expression(ts)
            for_rest({:expr, e}, t)
        end
    end
  end

  defp unary_or_lhs(ts), do: postfix(ts)

  # `for ([a, b] of x)` / `for ({a} of x)`: a pattern in the head
  defp destructuring_head([{:p, open, _} | _] = ts) when open in ["[", "{"] do
    try do
      {pat, rest} = pattern(ts, false)

      case rest do
        [{:id, w, _} | _] when w in ["of", "in"] -> {pat, rest}
        _ -> nil
      end
    catch
      {:syntax, _} -> nil
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
    {body, ts} = body_statement(ts)
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
  defp semi([{_, _, true} | _] = ts), do: ts
  defp semi([{_, v, _} | _]), do: throw({:syntax, "unexpected token #{inspect(v)}"})

  # ── patterns (binding targets) ─────────────────────────────

  defp pattern(ts, allow_default \\ true)

  defp pattern([{:id, name, _} | ts], allow_default) when name not in @reserved do
    check_strict_name(name)
    with_default({:id, name}, ts, allow_default)
  end

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
  defp property_key([{:priv, name, _} | ts]), do: {{:priv, name}, nil, ts}
  defp property_key([{:id, name, _} | ts]), do: {{:str, name}, name, ts}
  defp property_key([{:eid, name, _} | ts]), do: {{:str, name}, nil, ts}
  defp property_key([{:str, s, _} | ts]), do: {{:str, s}, nil, ts}
  defp property_key([{:num, n, _} | ts]), do: {{:str, Browser.JS.Num.to_string(n)}, nil, ts}

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

  defp class_rest(ts) do
    outer_refs = Process.get(:js_priv_refs, [])
    Process.put(:js_priv_refs, [])

    {name, ts} =
      case ts do
        [{:id, n, _} | t] when n not in @reserved and n != "extends" -> {n, t}
        t -> {nil, t}
      end

    outer = strict?()
    Process.put(:js_strict, true)

    {super, ts} =
      case ts do
        [{:id, "extends", _} | t] -> call_chain(t)
        t -> {nil, t}
      end

    ts = expect(ts, "{")
    {members, ts} = class_members(ts, [])
    Process.put(:js_strict, outer)

    names = check_private_names(members)
    unresolved = Enum.reject(Process.get(:js_priv_refs, []), &(&1 in names))
    Process.put(:js_priv_refs, unresolved ++ outer_refs)
    {{:class, name, super, members}, ts}
  end

  defp class_members([{:p, "}", _} | ts], acc), do: {Enum.reverse(acc), ts}
  defp class_members([{:p, ";", _} | ts], acc), do: class_members(ts, acc)

  defp class_members([{:id, "static", _}, {:p, "{", _} | ts], acc) do
    outer = Process.get(:js_generator, false)
    Process.put(:js_generator, false)

    try do
      {body, ts} = block_body(ts, [])
      class_members(ts, [{:cmember, :block, nil, body, true} | acc])
    after
      Process.put(:js_generator, outer)
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
        [{:id, k, _}, {t, _, _} | _] when k in ["get", "set"] and t in [:id, :str, :num, :priv] ->
          {String.to_atom(k), tl(ts)}

        [{:id, k, _}, {:p, "[", _} | _] when k in ["get", "set"] ->
          {String.to_atom(k), tl(ts)}

        _ ->
          {:method, ts}
      end

    {key, shorthand, after_key} = property_key(ts)

    case after_key do
      [{:p, "(", _} | _] ->
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
  defp semi_field(ts), do: ts

  # ── functions ──────────────────────────────────────────────

  # after `function name?` — at the parameter list
  defp function_rest(name, ts, generator? \\ false) do
    outer = Process.get(:js_generator, false)
    Process.put(:js_generator, generator?)

    try do
      {params, ts} = params(expect(ts, "("), [])
      ts = expect(ts, "{")
      {body, ts} = function_body(ts, params)
      {{:fn, name, params, body, false}, ts}
    after
      Process.put(:js_generator, outer)
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
    {body, ts} = function_body(ts, params)
    {{:fn, nil, params, body, :arrow}, ts}
  end

  defp arrow_body(params, ts) do
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
      arrow_ahead?(rest) and not match?([{_, _, true} | _], rest) ->
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
      [{_, _, true} | _] ->
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
      {pat, ts} = pattern(ts, false)
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
          {{:assign, op, left, right}, rest}

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
    {{:update, op, true, e}, ts}
  end

  defp unary([{:id, "await", _}, {k, v, _} | _] = [_ | ts])
       when k in [:id, :num, :str, :tmpl, :regex] and
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

    {{:unary, op, e}, ts}
  end

  defp unary(ts), do: postfix(ts)

  defp postfix(ts) do
    {e, ts} = call_chain(ts)

    case ts do
      [{:p, op, false} | ts] when op in ["++", "--"] ->
        unless assignable?(e), do: throw({:syntax, "invalid #{op} operand"})
        {{:update, op, false, e}, ts}

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
          {{:new_target}, t}

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
          {{:new_target}, t}

        [{:id, "new", _} | t] ->
          new_expression(t)

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

  defp primary([{:num, n, _} | ts]), do: {{:num, n}, ts}
  defp primary([{:str, s, _} | ts]), do: {{:str, s}, ts}

  defp primary([{:regex, {source, flags}, _} | ts]) do
    case Browser.JS.RegExp.validate(source, flags) do
      :ok -> {{:regex, source, flags}, ts}
      {:error, msg} -> throw({:syntax, msg})
    end
  end

  defp primary([{:tmpl, parts, _} | ts]) do
    parts =
      Enum.map(parts, fn
        {:expr, toks} ->
          {e, rest} = expression(toks)
          match?([{:eof, _, _}], rest) || throw({:syntax, "bad template expression"})
          e

        s ->
          s
      end)

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

  defp primary([{:id, name, _} | ts]) when name not in @reserved, do: {{:id, name}, ts}

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
    {fun, ts} = function_rest({:method, shorthand}, after_key, true)
    object_next(ts, [{:init, key, {:async, {:gen, fun}}} | acc])
  end

  defp object_literal([{:id, "async", _}, {k, _, false} | _] = [_ | rest], acc)
       when k in [:id, :str, :num] do
    {key, shorthand, after_key} = property_key(rest)
    {fun, ts} = function_rest({:method, shorthand}, after_key)
    object_next(ts, [{:init, key, {:async, fun}} | acc])
  end

  # `get x() {}` and `set x(v) {}`
  defp object_literal([{:id, kind, _}, {k, _, _} | _] = [_ | rest], acc)
       when kind in ["get", "set"] and k in [:id, :str, :num] do
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
          {{:init, key, v}, t}

        [{:p, "(", _} | _] = t ->
          {fun, t} = function_rest({:method, shorthand}, t)
          {{:init, key, fun}, t}

        t ->
          name = shorthand || throw({:syntax, "bad object literal"})
          name in @reserved && throw({:syntax, "unexpected token #{inspect(name)}"})
          {{:init, key, {:id, name}}, t}
      end

    object_next(ts, [prop | acc])
  end

  defp object_next([{:p, ",", _} | ts], acc), do: object_literal(ts, acc)
  defp object_next([{:p, "}", _} | ts], acc), do: {{:object, Enum.reverse(acc)}, ts}
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
