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
        {:ok, {:program, statements(tokens)}}
      catch
        {:syntax, msg} -> {:error, msg}
      end
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
    {{:block, body}, ts}
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
    {a, ts} = statement(ts)

    case ts do
      [{:id, "else", _} | ts] ->
        {b, ts} = statement(ts)
        {{:if, c, a, b}, ts}

      _ ->
        {{:if, c, a, nil}, ts}
    end
  end

  defp statement([{:id, "while", _} | ts]) do
    ts = expect(ts, "(")
    {c, ts} = expression(ts)
    ts = expect(ts, ")")
    {body, ts} = statement(ts)
    {{:while, c, body}, ts}
  end

  defp statement([{:id, "do", _} | ts]) do
    {body, ts} = statement(ts)
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
    {{:switch, disc, cases}, ts}
  end

  defp statement([{:id, name, _}, {:p, ":", _} | ts]) when name not in @reserved do
    {stmt, ts} = statement(ts)
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

  defp statement([{:id, kw, _} | _]) when kw in ~w(class import with enum),
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
            {body, t} = statement(t)
            {{if(of_in == "of", do: :forof, else: :forin), String.to_atom(kw), pat, obj, body}, t}

          _ ->
            {decl, t} = declaration(kw, rest)
            for_rest(decl, t)
        end

      [{:p, ";", _} | _] ->
        for_rest(nil, ts)

      _ ->
        {lhs, after_lhs} = unary_or_lhs(ts)

        case after_lhs do
          [{:id, of_in, _} | t] when of_in in ["of", "in"] ->
            {obj, t} = if of_in == "of", do: assignment(t), else: expression(t)
            t = expect(t, ")")
            {body, t} = statement(t)
            {{if(of_in == "of", do: :forof, else: :forin), nil, lhs, obj, body}, t}

          _ ->
            {e, t} = expression(ts)
            for_rest({:expr, e}, t)
        end
    end
  end

  defp unary_or_lhs(ts), do: postfix(ts)

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
    {body, ts} = statement(ts)
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
  defp property_key([{:id, name, _} | ts]), do: {{:str, name}, name, ts}
  defp property_key([{:str, s, _} | ts]), do: {{:str, s}, nil, ts}
  defp property_key([{:num, n, _} | ts]), do: {{:str, Browser.JS.Num.to_string(n)}, nil, ts}

  defp property_key([{:p, "[", _} | ts]) do
    {e, ts} = assignment(ts)
    {{:computed, e}, nil, expect(ts, "]")}
  end

  defp property_key([{_, v, _} | _]),
    do: throw({:syntax, "unexpected token #{inspect(v)} as property name"})

  # ── functions ──────────────────────────────────────────────

  # after `function name?` — at the parameter list
  defp function_rest(name, ts) do
    {params, ts} = params(expect(ts, "("), [])
    ts = expect(ts, "{")
    {body, ts} = block_body(ts, [])
    {{:fn, name, params, body, false}, ts}
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
    {body, ts} = block_body(ts, [])
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

  defp assignment(ts), do: assignment_plain(ts)

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

  defp assignable?({:id, _}), do: true
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

  defp unary([{:p, op, _} | ts]) when op in ["!", "-", "+", "~"] do
    {e, ts} = unary(ts)
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
        [{:id, "new", _} | ts] -> new_expression(ts)
        _ -> primary(ts)
      end

    {e, ts, chained?} = chain(base, ts, false)
    {if(chained?, do: {:chain, e}, else: e), ts}
  end

  defp chain(e, [{:p, ".", _}, {:id, name, _} | ts], c),
    do: chain({:member, e, {:str, name}, false}, ts, c)

  defp chain(e, [{:p, "?.", _}, {:id, name, _} | ts], _),
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
        [{:id, "new", _} | t] -> new_expression(t)
        _ -> primary(ts)
      end

    {callee, ts} = member_only(callee, ts)

    {args, ts} =
      case ts do
        [{:p, "(", _} | t] -> arguments(t, [])
        t -> {[], t}
      end

    {{:new, callee, args}, ts}
  end

  defp member_only(e, [{:p, ".", _}, {:id, name, _} | ts]),
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
  defp primary([{:regex, {source, flags}, _} | ts]), do: {{:regex, source, flags}, ts}

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

  defp primary([{:id, "async", _}, {:id, "function", _} | _] = [_ | rest]) do
    {fun, ts} = primary(rest)
    {{:async, fun}, ts}
  end

  defp primary([{:id, "function", _} | ts]) do
    {name, ts} =
      case ts do
        [{:id, n, _} | t] when n not in @reserved -> {n, t}
        t -> {nil, t}
      end

    function_rest(name, ts)
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
