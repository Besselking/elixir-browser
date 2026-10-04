defmodule Browser.JS.Lexer do
  @moduledoc """
  Turns JavaScript source into tokens: `{type, value, newline_before?}`.

  Types are `:num` (a float), `:str`, `:tmpl` (a list of strings and `{:expr, tokens}`), `:id`
  (names and keywords alike), `:p` (punctuation) and `:eof`. The newline flag is what lets the
  parser do automatic semicolon insertion. A `/` where a value may start (after an operator, an
  opening bracket or a keyword such as `return`) begins a regular expression literal, `:regex`
  with `{source, flags}`; anywhere else it is a division.
  """

  @puncts ~w">>>= ... === !== **= <<= >>= >>> &&= ||= ??= => == != <= >= && || ?? ?. ++ -- += -= *= /= %= &= |= ^= ** << >>
             { } ( ) [ ] ; , < > + - * / % & | ^ ! ~ ? : = ."
          |> Enum.sort_by(&(-byte_size(&1)))

  @keywords ~w(break case catch class const continue debugger default delete do else enum export
    extends false finally for function if import in instanceof new null return super switch this
    throw true try typeof var void while with implements interface let package private protected
    public static yield await async)

  @doc "`{:ok, tokens}` or `{:error, message}`."
  def tokenize(src) do
    {:ok, lex(src, false, [])}
  catch
    {:syntax, msg} -> {:error, msg}
  end

  defp lex("", _nl, acc), do: Enum.reverse([{:eof, nil, true} | acc])

  defp lex(<<c, rest::binary>>, _nl, acc) when c in [?\n, ?\r], do: lex(rest, true, acc)
  defp lex(<<c, rest::binary>>, nl, acc) when c in [?\s, ?\t, 0x0B, 0x0C], do: lex(rest, nl, acc)
  defp lex(<<0xC2, 0xA0, rest::binary>>, nl, acc), do: lex(rest, nl, acc)
  defp lex(<<0xEF, 0xBB, 0xBF, rest::binary>>, nl, acc), do: lex(rest, nl, acc)
  defp lex("//" <> rest, nl, acc), do: lex(skip_line(rest), nl, acc)

  defp lex("/*" <> rest, nl, acc) do
    case String.split(rest, "*/", parts: 2) do
      [comment, after_comment] -> lex(after_comment, nl or String.contains?(comment, "\n"), acc)
      _ -> throw({:syntax, "unterminated comment"})
    end
  end

  defp lex(<<c, _::binary>> = s, nl, acc) when c in ?0..?9, do: number(s, nl, acc)
  defp lex(<<?., c, _::binary>> = s, nl, acc) when c in ?0..?9, do: number(s, nl, acc)

  defp lex(<<q, rest::binary>>, nl, acc) when q in [?", ?'] do
    Process.put(:js_octal, false)
    {str, rest} = string(rest, q, [])
    # a string with a legacy octal escape carries `:octal` (`:octal_nl` after a line break)
    # where the newline flag goes, so the parser can refuse it in strict code
    mark =
      cond do
        not Process.get(:js_octal) -> nl
        nl -> :octal_nl
        true -> :octal
      end

    lex(rest, false, [{:str, str, mark} | acc])
  end

  defp lex("`" <> rest, nl, acc) do
    {parts, after_tmpl} = template(rest, [], [])
    # the raw text of the chunks, which `String.raw` and other tags read
    raw = binary_part(rest, 0, byte_size(rest) - byte_size(after_tmpl) - 1)
    raw = String.replace(raw, ["\r\n", "\r"], "\n")
    lex(after_tmpl, false, [{:tmpl, parts ++ [{:raw, raw_chunks(raw, [], [])}], nl} | acc])
  end

  defp lex(<<?\\, ?u, _::binary>> = s, nl, acc), do: lex_ident(s, nl, acc)

  defp lex(<<c, _::binary>> = s, nl, acc)
       when c in ?a..?z or c in ?A..?Z or c in [?_, ?$] or c > 127,
       do: lex_ident(s, nl, acc)

  defp lex("/" <> rest, nl, acc) do
    if regex_allowed?(acc) do
      {source, flags, rest} = regex(rest, [], false)
      lex(rest, false, [{:regex, {source, flags}, nl} | acc])
    else
      punct("/" <> rest, nl, acc)
    end
  end

  # `#name`: a private name
  defp lex(<<?#, c, _::binary>> = s, nl, acc)
       when c in ?a..?z or c in ?A..?Z or c in [?_, ?$, ?\\] or c > 127 do
    {name, rest} = ident(binary_part(s, 1, byte_size(s) - 1), [])
    lex(rest, false, [{:priv, name, nl} | acc])
  end

  defp lex(s, nl, acc), do: punct(s, nl, acc)

  defp lex_ident(s, nl, acc) do
    {name, rest} = ident(s, [])

    # a reserved word spelled with an escape is no keyword and no identifier either: the
    # parser has no use for this token, so it is a syntax error wherever it appears
    kind = if (name in @keywords or name == "target") and escaped?(s, rest), do: :eid, else: :id
    lex(rest, false, [{kind, name, nl} | acc])
  end

  defp punct(s, nl, acc) do
    case Enum.find(@puncts, &String.starts_with?(s, &1)) do
      # `a?.5:b` is a conditional, not an optional chain
      "?." when binary_part(s, 2, min(1, byte_size(s) - 2)) in ~w(0 1 2 3 4 5 6 7 8 9) ->
        lex(binary_part(s, 1, byte_size(s) - 1), false, [{:p, "?", nl} | acc])

      nil ->
        throw({:syntax, "unexpected character #{inspect(String.first(s))}"})

      p ->
        lex(binary_part(s, byte_size(p), byte_size(s) - byte_size(p)), false, [{:p, p, nl} | acc])
    end
  end

  @regex_keywords ~w(return typeof instanceof in of new delete void throw case do else yield await)

  # a `/` starts a regular expression where an operand is expected
  defp regex_allowed?([]), do: true
  defp regex_allowed?([{:p, p, _} | _]), do: p not in [")", "]", "}"]
  defp regex_allowed?([{:id, name, _} | _]), do: name in @regex_keywords
  defp regex_allowed?(_), do: false

  defp regex(<<?\\, c::utf8, rest::binary>>, acc, cls),
    do: regex(rest, [<<?\\, c::utf8>> | acc], cls)

  defp regex(<<?[, rest::binary>>, acc, false), do: regex(rest, ["[" | acc], true)
  defp regex(<<?], rest::binary>>, acc, true), do: regex(rest, ["]" | acc], false)

  defp regex(<<?/, rest::binary>>, acc, false) do
    {flags, rest} = regex_flags(rest, [])
    {acc |> Enum.reverse() |> IO.iodata_to_binary(), flags, rest}
  end

  defp regex(<<c, _::binary>>, _acc, _cls) when c in [?\n, ?\r],
    do: throw({:syntax, "unterminated regular expression"})

  defp regex(<<c::utf8, rest::binary>>, acc, cls), do: regex(rest, [<<c::utf8>> | acc], cls)
  defp regex("", _acc, _cls), do: throw({:syntax, "unterminated regular expression"})

  defp regex_flags(<<c, rest::binary>>, acc) when c in ?a..?z, do: regex_flags(rest, [c | acc])
  defp regex_flags(rest, acc), do: {acc |> Enum.reverse() |> :binary.list_to_bin(), rest}

  defp skip_line(<<c, _::binary>> = s) when c in [?\n, ?\r], do: s
  defp skip_line(<<_, rest::binary>>), do: skip_line(rest)
  defp skip_line(""), do: ""

  defp escaped?(s, rest),
    do: String.contains?(binary_part(s, 0, byte_size(s) - byte_size(rest)), "\\")

  defp ident(<<c, rest::binary>>, acc)
       when c in ?a..?z or c in ?A..?Z or c in ?0..?9 or c in [?_, ?$] or c > 127,
       do: ident(rest, [c | acc])

  # \uXXXX and \u{X...} escapes are part of an identifier
  defp ident(<<"\\u{", rest::binary>>, acc) do
    with [hex, rest] <- String.split(rest, "}", parts: 2),
         {cp, ""} <- Integer.parse(hex, 16),
         true <- cp in 0..0x10FFFF do
      ident(rest, [<<cp::utf8>> | acc])
    else
      _ -> throw({:syntax, "bad unicode escape in identifier"})
    end
  end

  defp ident(<<"\\u", hex::binary-size(4), rest::binary>>, acc) do
    case Integer.parse(hex, 16) do
      {cp, ""} when cp not in 0xD800..0xDFFF -> ident(rest, [<<cp::utf8>> | acc])
      _ -> throw({:syntax, "bad unicode escape in identifier"})
    end
  end

  defp ident(rest, acc), do: {acc |> Enum.reverse() |> :binary.list_to_bin(), rest}

  defp number(s, nl, acc) do
    s = strip_separators(s)

    {value, rest} =
      case s do
        <<?0, x, digits::binary>> when x in [?x, ?X, ?b, ?B, ?o, ?O] ->
          base = %{?x => 16, ?X => 16, ?b => 2, ?B => 2, ?o => 8, ?O => 8}[x]

          case Integer.parse(digits, base) do
            {n, <<?n, rest::binary>>} -> {{:bigint, n}, rest}
            {n, rest} -> {n * 1.0, rest}
            :error -> throw({:syntax, "bad number"})
          end

        _ ->
          [lit] = Regex.run(~r/\A(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?/, s)
          lit_f = if String.starts_with?(lit, "."), do: "0" <> lit, else: lit
          rest = binary_part(s, byte_size(lit), byte_size(s) - byte_size(lit))

          case {rest, Regex.match?(~r/\A(?:0|[1-9]\d*)\z/, lit)} do
            {<<?n, rest::binary>>, true} ->
              {{:bigint, String.to_integer(lit)}, rest}

            {<<?n, _::binary>>, false} ->
              throw({:syntax, "invalid BigInt literal"})

            _ ->
              {f, _} =
                Float.parse(if Regex.match?(~r/\A\d+\z/, lit_f), do: lit_f <> ".0", else: lit_f)

              {f, rest}
          end
      end

    case rest do
      <<c, _::binary>> when c in ?a..?z or c in ?A..?Z or c in [?_, ?$] ->
        throw({:syntax, "identifier directly after number"})

      _ ->
        case value do
          {:bigint, n} -> lex(rest, false, [{:bigint, n, nl} | acc])
          _ -> lex(rest, false, [{:num, value, nl} | acc])
        end
    end
  end

  # numeric separators: an underscore between two digits is dropped; any other underscore is left
  # for `number/3` to reject
  @separated_number ~r/\A(?:0[xX][0-9a-fA-F](?:_?[0-9a-fA-F])*|0[bB][01](?:_?[01])*|0[oO][0-7](?:_?[0-7])*|(?:[1-9](?:_?[0-9])*|0)?(?:\.[0-9](?:_?[0-9])*)?(?:[eE][+-]?[0-9](?:_?[0-9])*)?)/

  defp strip_separators(s) do
    [lit] = Regex.run(@separated_number, s)

    if String.contains?(lit, "_"),
      do:
        String.replace(lit, "_", "") <>
          binary_part(s, byte_size(lit), byte_size(s) - byte_size(lit)),
      else: s
  end

  defp string(<<q, rest::binary>>, q, acc),
    do: {acc |> Enum.reverse() |> IO.iodata_to_binary(), rest}

  defp string(<<c, _::binary>>, _q, _acc) when c in [?\n, ?\r],
    do: throw({:syntax, "unterminated string"})

  # legacy octal escapes (`\1`, `\012`, `\0` followed by a digit) and `\8`, `\9`
  defp string(<<?\\, d, rest::binary>>, q, acc) when d in ?0..?9 do
    case {d, rest} do
      {?0, <<n, _::binary>>} when n not in ?0..?9 ->
        string(rest, q, [<<0>> | acc])

      {?0, ""} ->
        string(rest, q, [<<0>> | acc])

      {d, _} when d in [?8, ?9] ->
        Process.put(:js_octal, true)
        string(rest, q, [<<d>> | acc])

      _ ->
        Process.put(:js_octal, true)
        max_more = if d <= ?3, do: 2, else: 1
        {digits, rest} = octal_digits(rest, max_more, [d])
        string(rest, q, [<<String.to_integer(List.to_string(digits), 8)::utf8>> | acc])
    end
  end

  defp string(<<?\\, rest::binary>>, q, acc) do
    {chunk, rest} = escape(rest)
    string(rest, q, [chunk | acc])
  end

  defp string(<<c::utf8, rest::binary>>, q, acc), do: string(rest, q, [<<c::utf8>> | acc])
  defp string(_, _q, _acc), do: throw({:syntax, "unterminated string"})

  defp octal_digits(<<n, rest::binary>>, left, acc) when left > 0 and n in ?0..?7,
    do: octal_digits(rest, left - 1, acc ++ [n])

  defp octal_digits(rest, _left, acc), do: {acc, rest}

  defp escape("n" <> r), do: {"\n", r}
  defp escape("t" <> r), do: {"\t", r}
  defp escape("r" <> r), do: {"\r", r}
  defp escape("b" <> r), do: {"\b", r}
  defp escape("f" <> r), do: {"\f", r}
  defp escape("v" <> r), do: {"\v", r}
  defp escape("0" <> r), do: {<<0>>, r}
  defp escape("\r\n" <> r), do: {"", r}
  defp escape("\r" <> r), do: {"", r}
  defp escape("\n" <> r), do: {"", r}

  defp escape(<<"x", h::binary-size(2), r::binary>>) do
    {<<String.to_integer(h, 16)::utf8>>, r}
  rescue
    ArgumentError -> throw({:syntax, "bad \\x escape"})
  end

  defp escape("u{" <> r) do
    [hex, r] = String.split(r, "}", parts: 2)
    {<<String.to_integer(hex, 16)::utf8>>, r}
  rescue
    _ -> throw({:syntax, "bad \\u escape"})
  end

  defp escape(<<"u", h::binary-size(4), r::binary>>) do
    case String.to_integer(h, 16) do
      hi when hi in 0xD800..0xDBFF ->
        with <<"\\u", l::binary-size(4), r2::binary>> <- r,
             lo when lo in 0xDC00..0xDFFF <- String.to_integer(l, 16) do
          {<<0x10000 + (hi - 0xD800) * 0x400 + (lo - 0xDC00)::utf8>>, r2}
        else
          _ -> {"�", r}
        end

      lo when lo in 0xDC00..0xDFFF ->
        {"�", r}

      cp ->
        {<<cp::utf8>>, r}
    end
  rescue
    ArgumentError -> throw({:syntax, "bad \\u escape"})
  end

  defp escape(<<c::utf8, r::binary>>), do: {<<c::utf8>>, r}
  defp escape(""), do: throw({:syntax, "unterminated string"})

  # template literal: cooked text chunks interleaved with `{:expr, tokens}`
  defp template("`" <> rest, text, parts), do: {Enum.reverse([flush(text) | parts]), rest}

  defp template("${" <> rest, text, parts) do
    {src, rest} = expr_source(rest, 0, [])

    case tokenize(src) do
      {:ok, toks} -> template(rest, [], [{:expr, toks}, flush(text) | parts])
      {:error, msg} -> throw({:syntax, msg})
    end
  end

  defp template(<<?\\, rest::binary>>, text, parts) do
    if bad_template_escape?(rest) do
      # no cooked value: a tagged template reads `undefined` there, an untagged one is an error
      <<_::utf8, rest::binary>> = rest
      template(rest, [:bad | text], parts)
    else
      {chunk, rest} = escape(rest)
      template(rest, [chunk | text], parts)
    end
  end

  defp template(<<"\r\n", rest::binary>>, text, parts), do: template(rest, ["\n" | text], parts)
  defp template(<<"\r", rest::binary>>, text, parts), do: template(rest, ["\n" | text], parts)

  defp template(<<c::utf8, rest::binary>>, text, parts),
    do: template(rest, [<<c::utf8>> | text], parts)

  defp template(_, _text, _parts), do: throw({:syntax, "unterminated template"})

  # the text between the `${ }` of a template as written (escapes not interpreted)
  defp raw_chunks("", text, chunks), do: Enum.reverse([flush(text) | chunks])

  defp raw_chunks("${" <> rest, text, chunks) do
    {_src, rest} = expr_source(rest, 0, [])
    raw_chunks(rest, [], [flush(text) | chunks])
  end

  defp raw_chunks(<<?\\, c::utf8, rest::binary>>, text, chunks),
    do: raw_chunks(rest, [<<c::utf8>>, "\\" | text], chunks)

  defp raw_chunks(<<"\r\n", rest::binary>>, text, chunks),
    do: raw_chunks(rest, ["\n" | text], chunks)

  defp raw_chunks(<<c::utf8, rest::binary>>, text, chunks),
    do: raw_chunks(rest, [<<c::utf8>> | text], chunks)

  defp flush(text) do
    if :bad in text, do: :bad, else: text |> Enum.reverse() |> IO.iodata_to_binary()
  end

  # an escape a template literal cannot cook: `\1`..`\9`, `\0` before a digit, a malformed
  # `\x`, `\u` or `\u{...}`
  defp bad_template_escape?(<<?0, n, _::binary>>) when n in ?0..?9, do: true
  defp bad_template_escape?(<<d, _::binary>>) when d in ?1..?9, do: true
  defp bad_template_escape?(<<?x, h::binary-size(2), _::binary>>), do: not hex?(h)
  defp bad_template_escape?(<<?x, _::binary>>), do: true

  defp bad_template_escape?("u{" <> r) do
    case String.split(r, "}", parts: 2) do
      [hex, _] -> not (hex != "" and hex?(hex) and String.to_integer(hex, 16) <= 0x10FFFF)
      _ -> true
    end
  end

  defp bad_template_escape?(<<?u, h::binary-size(4), _::binary>>), do: not hex?(h)
  defp bad_template_escape?(<<?u, _::binary>>), do: true
  defp bad_template_escape?(_), do: false

  defp hex?(s), do: s =~ ~r/\A[0-9a-fA-F]+\z/

  # the source of a `${ ... }` expression, up to its matching brace
  defp expr_source("}" <> rest, 0, acc),
    do: {acc |> Enum.reverse() |> IO.iodata_to_binary(), rest}

  defp expr_source("}" <> rest, d, acc), do: expr_source(rest, d - 1, ["}" | acc])
  defp expr_source("{" <> rest, d, acc), do: expr_source(rest, d + 1, ["{" | acc])

  defp expr_source(<<q, rest::binary>>, d, acc) when q in [?", ?'] do
    {_, after_str} = string(rest, q, [])
    consumed = binary_part(rest, 0, byte_size(rest) - byte_size(after_str))
    expr_source(after_str, d, [consumed, <<q>> | acc])
  end

  defp expr_source("`" <> rest, d, acc) do
    {_, after_tmpl} = template(rest, [], [])
    consumed = binary_part(rest, 0, byte_size(rest) - byte_size(after_tmpl))
    expr_source(after_tmpl, d, [consumed, "`" | acc])
  end

  defp expr_source(<<c::utf8, rest::binary>>, d, acc),
    do: expr_source(rest, d, [<<c::utf8>> | acc])

  defp expr_source("", _d, _acc), do: throw({:syntax, "unterminated template expression"})
end
