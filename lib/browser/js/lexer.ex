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
    # a hashbang comment is only allowed at the very start
    src = if match?("#!" <> _, src), do: skip_line(src), else: src
    {:ok, lex(src, false, [])}
  catch
    {:syntax, msg} -> {:error, msg}
  end

  defp lex("", _nl, acc), do: Enum.reverse([{:eof, nil, true} | acc])

  defp lex(<<c, rest::binary>>, _nl, acc) when c in [?\n, ?\r], do: lex(rest, true, acc)
  defp lex(<<c, rest::binary>>, nl, acc) when c in [?\s, ?\t, 0x0B, 0x0C], do: lex(rest, nl, acc)

  defp lex(<<0xE2, 0x80, c, rest::binary>>, _nl, acc) when c in [0xA8, 0xA9],
    do: lex(rest, true, acc)

  defp lex(<<c::utf8, rest::binary>> = s, nl, acc) when c > 127 do
    if space_cp?(c), do: lex(rest, nl, acc), else: lex_ident(s, nl, acc)
  end

  defp lex("//" <> rest, nl, acc), do: lex(skip_line(rest), nl, acc)

  defp lex("/*" <> rest, nl, acc) do
    case String.split(rest, "*/", parts: 2) do
      [comment, after_comment] ->
        lex(after_comment, nl or String.contains?(comment, ["\n", "\r", "\u2028", "\u2029"]), acc)

      _ ->
        throw({:syntax, "unterminated comment"})
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

  defp regex(<<0xE2, 0x80, c, _::binary>>, _acc, _cls) when c in [0xA8, 0xA9],
    do: throw({:syntax, "unterminated regular expression"})

  defp regex(<<c::utf8, rest::binary>>, acc, cls), do: regex(rest, [<<c::utf8>> | acc], cls)
  defp regex("", _acc, _cls), do: throw({:syntax, "unterminated regular expression"})

  defp regex_flags(<<c, rest::binary>>, acc) when c in ?a..?z, do: regex_flags(rest, [c | acc])
  defp regex_flags(rest, acc), do: {acc |> Enum.reverse() |> :binary.list_to_bin(), rest}

  defp skip_line(<<c, _::binary>> = s) when c in [?\n, ?\r], do: s
  defp skip_line(<<0xE2, 0x80, c, _::binary>> = s) when c in [0xA8, 0xA9], do: s
  defp skip_line(<<_, rest::binary>>), do: skip_line(rest)
  defp skip_line(""), do: ""

  defp escaped?(s, rest),
    do: String.contains?(binary_part(s, 0, byte_size(s) - byte_size(rest)), "\\")

  # white space and line terminators outside ASCII (Zs, BOM, U+2028, U+2029)
  defp space_cp?(c),
    do: c in [0xA0, 0x1680, 0x202F, 0x205F, 0x3000, 0xFEFF, 0x2028, 0x2029] or c in 0x2000..0x200A

  # an escape in an identifier must spell an identifier character
  defp id_escape?(cp) when cp < 128,
    do: cp in ?a..?z or cp in ?A..?Z or cp in ?0..?9 or cp in [?_, ?$]

  defp id_escape?(cp), do: not space_cp?(cp)

  defp ident(<<c, rest::binary>> = s, acc)
       when c in ?a..?z or c in ?A..?Z or c in ?0..?9 or c in [?_, ?$] or c > 127 do
    case s do
      <<cp::utf8, _::binary>> when cp > 127 ->
        if space_cp?(cp),
          do: {acc |> Enum.reverse() |> :binary.list_to_bin(), s},
          else: ident(rest, [c | acc])

      _ ->
        ident(rest, [c | acc])
    end
  end

  # \uXXXX and \u{X...} escapes are part of an identifier
  defp ident(<<"\\u{", rest::binary>>, acc) do
    with [hex, rest] <- String.split(rest, "}", parts: 2),
         {cp, ""} <- Integer.parse(hex, 16),
         true <- cp in 0..0x10FFFF and id_escape?(cp) do
      ident(rest, [<<cp::utf8>> | acc])
    else
      _ -> throw({:syntax, "bad unicode escape in identifier"})
    end
  end

  defp ident(<<"\\u", hex::binary-size(4), rest::binary>>, acc) do
    case Integer.parse(hex, 16) do
      {cp, ""} when cp not in 0xD800..0xDFFF ->
        if id_escape?(cp),
          do: ident(rest, [<<cp::utf8>> | acc]),
          else: throw({:syntax, "bad unicode escape in identifier"})

      _ ->
        throw({:syntax, "bad unicode escape in identifier"})
    end
  end

  defp ident(rest, acc), do: {acc |> Enum.reverse() |> :binary.list_to_bin(), rest}

  # `010` is octal when every digit is below 8; `08` and `089.5` are plain decimals
  defp legacy_number(<<?0, rest::binary>> = s) do
    digits = rest |> :binary.bin_to_list() |> Enum.take_while(&(&1 in ?0..?9))
    tail = binary_part(rest, length(digits), byte_size(rest) - length(digits))

    if Enum.all?(digits, &(&1 in ?0..?7)),
      do: {String.to_integer(List.to_string(digits), 8) * 1.0, tail},
      else: decimal_number(s)
  end

  defp decimal_number(s) do
    [lit] = Regex.run(~r/\A(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?/, s)
    {Browser.JS.Num.parse(lit), binary_part(s, byte_size(lit), byte_size(s) - byte_size(lit))}
  end

  defp number(s, nl, acc) do
    s = strip_separators(s)
    legacy? = match?(<<?0, d, _::binary>> when d in ?0..?9, s)
    nl = if legacy?, do: if(nl, do: :octal_nl, else: :octal), else: nl

    {value, rest} =
      case s do
        <<?0, d, _::binary>> when d in ?0..?9 ->
          legacy_number(s)

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
              {Browser.JS.Num.parse(lit_f), rest}
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

  # a regular expression literal (it may hold quotes and braces): `/` after an operator or an
  # opening bracket, not a division
  defp expr_source("/" <> rest, d, acc)
       when rest != "" and binary_part(rest, 0, 1) not in ["/", "*"] do
    if subst_regex?(acc) do
      {lit, after_re} = subst_re_body(rest, false, [])
      expr_source(after_re, d, [lit, "/" | acc])
    else
      expr_source(rest, d, ["/" | acc])
    end
  end

  defp expr_source("`" <> rest, d, acc) do
    {_, after_tmpl} = template(rest, [], [])
    consumed = binary_part(rest, 0, byte_size(rest) - byte_size(after_tmpl))
    expr_source(after_tmpl, d, [consumed, "`" | acc])
  end

  defp expr_source(<<c::utf8, rest::binary>>, d, acc),
    do: expr_source(rest, d, [<<c::utf8>> | acc])

  defp expr_source("", _d, _acc), do: throw({:syntax, "unterminated template expression"})

  defp subst_regex?(acc) do
    last =
      Enum.find_value(acc, fn piece ->
        t = String.trim_trailing(piece)
        if t != "", do: binary_part(t, byte_size(t) - 1, 1)
      end)

    last == nil or last in ~w[( , = : [ ! & | ? { } ; + - * % < > ~ ^]
  end

  # the rest of a regex literal after its opening `/`: the body, the closing `/` and the flags
  defp subst_re_body("\\" <> <<c::utf8, rest::binary>>, cls, acc),
    do: subst_re_body(rest, cls, [<<c::utf8>>, "\\" | acc])

  defp subst_re_body("[" <> rest, _cls, acc), do: subst_re_body(rest, true, ["[" | acc])
  defp subst_re_body("]" <> rest, _cls, acc), do: subst_re_body(rest, false, ["]" | acc])

  defp subst_re_body("/" <> rest, false, acc) do
    {flags, rest} = subst_re_flags(rest, [])
    {IO.iodata_to_binary(Enum.reverse(["/" | acc])) <> flags, rest}
  end

  defp subst_re_body(<<c::utf8, rest::binary>>, cls, acc),
    do: subst_re_body(rest, cls, [<<c::utf8>> | acc])

  defp subst_re_body("", _, _), do: throw({:syntax, "unterminated regular expression"})

  defp subst_re_flags(<<c, rest::binary>>, acc) when c in ?a..?z,
    do: subst_re_flags(rest, [c | acc])

  defp subst_re_flags(rest, acc), do: {acc |> Enum.reverse() |> List.to_string(), rest}
end
