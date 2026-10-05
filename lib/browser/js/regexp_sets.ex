defmodule Browser.JS.RegExpSets do
  @moduledoc """
  Character classes of the `v` flag (`unicodeSets`): nested classes, `--` and `&&`, `\\q{...}`
  string literals and properties of strings, turned into PCRE.

  A class becomes a model: `chars` is a PCRE fragment that matches exactly one character of the
  set (nil when there is none) and `strings` the members that are not one character long. Union,
  intersection and difference work on both parts (lookaheads for characters, list operations
  for strings), and the model is written out as an alternation, longest strings first.

  Early errors (a reserved double punctuator, an unescaped syntax character, mixed operators,
  a negated class that may contain strings, ...) are thrown as `{:re_error, message}`.
  """

  @syntax ~c"()[]{}/-\\|"
  @double ~c"&!#$%*+,.:;<=>?@^`~"
  @reserved ~c"&-!#%,:;<=>@`~"

  @keycap for c <- ~c"0123456789#*", do: <<c::utf8, 0xFE0F::utf8, 0x20E3::utf8>>

  defp fail(msg), do: throw({:re_error, msg})

  @doc """
  Translates a pattern for the `v` flag; `plain` translates the parts outside classes (what
  the other flags do for the whole pattern).
  """
  def translate(source, plain), do: top(source, plain, "", [])

  defp top("", plain, seg, acc), do: join(plain, seg, acc)

  defp top("[" <> rest, plain, seg, acc) do
    {model, rest} = class(rest)
    top(rest, plain, "", [emit(model), plain.(seg) | acc])
  end

  defp top("\\p{" <> rest, plain, seg, acc) do
    [name, after_name] = String.split(rest, "}", parts: 2)

    if name == "Emoji_Keycap_Sequence",
      do: top(after_name, plain, "", [emit(strings_model(@keycap, true)), plain.(seg) | acc]),
      else: top(after_name, plain, seg <> "\\p{" <> name <> "}", acc)
  end

  defp top("\\P{" <> rest, plain, seg, acc) do
    [name, after_name] = String.split(rest, "}", parts: 2)

    if name == "Emoji_Keycap_Sequence",
      do: fail("Negated property of strings"),
      else: top(after_name, plain, seg <> "\\P{" <> name <> "}", acc)
  end

  defp top(<<?\\, c::utf8, rest::binary>>, plain, seg, acc),
    do: top(rest, plain, seg <> <<?\\, c::utf8>>, acc)

  defp top(<<c::utf8, rest::binary>>, plain, seg, acc),
    do: top(rest, plain, seg <> <<c::utf8>>, acc)

  defp join(plain, seg, acc), do: [plain.(seg) | acc] |> Enum.reverse() |> IO.iodata_to_binary()

  # ── models ─────────────────────────────────────────────────

  defp char_model(cp), do: %{chars: lit(cp), strings: [], may: false}
  defp frag_model(frag), do: %{chars: frag, strings: [], may: false}
  defp strings_model(list, may), do: %{chars: nil, strings: list, may: may}
  defp empty, do: %{chars: nil, strings: [], may: false}

  defp lit(cp), do: "\\x{#{Integer.to_string(cp, 16)}}"

  defp alt(nil, b), do: b
  defp alt(a, nil), do: a
  defp alt(a, b), do: "(?:#{a}|#{b})"

  defp union(a, b),
    do: %{
      chars: alt(a.chars, b.chars),
      strings: Enum.uniq(a.strings ++ b.strings),
      may: a.may or b.may
    }

  defp intersect(a, b) do
    chars = if a.chars && b.chars, do: "(?:(?=#{a.chars})#{b.chars})"
    %{chars: chars, strings: Enum.filter(a.strings, &(&1 in b.strings)), may: a.may and b.may}
  end

  defp subtract(a, b) do
    chars =
      cond do
        a.chars == nil -> nil
        b.chars == nil -> a.chars
        true -> "(?:(?!#{b.chars})#{a.chars})"
      end

    %{chars: chars, strings: a.strings -- b.strings, may: a.may}
  end

  defp complement(m) do
    chars = if m.chars, do: "(?:(?!#{m.chars})(?s:.))", else: "(?s:.)"
    frag_model(chars)
  end

  defp emit(m) do
    strings =
      m.strings
      |> Enum.sort_by(&(-String.length(&1)))
      |> Enum.map(fn s -> for(<<c::utf8 <- s>>, into: "", do: lit(c)) end)

    case strings ++ List.wrap(m.chars) do
      [] -> "(?!)"
      [one] -> one
      many -> "(?:" <> Enum.join(many, "|") <> ")"
    end
  end

  # ── classes ────────────────────────────────────────────────

  # after `[`: the model, and what follows the closing `]`
  defp class(rest) do
    {neg?, rest} =
      case rest do
        "^" <> r -> {true, r}
        _ -> {false, rest}
      end

    {model, rest} = contents(rest)

    model =
      if neg? do
        if model.may or model.strings != [],
          do: fail("Negated character class may contain strings")

        complement(model)
      else
        model
      end

    {model, rest}
  end

  defp contents("]" <> rest), do: {empty(), rest}

  defp contents(rest) do
    {kind, first, rest} = item(rest)

    case rest do
      "--" <> r when kind == :operand -> chain(r, first, &subtract/2, "--")
      "&&" <> r when kind == :operand -> chain_and(r, first)
      _ -> union_rest(rest, first)
    end
  end

  defp union_rest("]" <> rest, acc), do: {acc, rest}
  defp union_rest("--" <> _, _), do: fail("Invalid set operation in character class")
  defp union_rest("&&" <> _, _), do: fail("Invalid set operation in character class")
  defp union_rest("", _), do: fail("Unterminated character class")

  defp union_rest(rest, acc) do
    {_, m, rest} = item(rest)
    union_rest(rest, union(acc, m))
  end

  defp chain(rest, acc, op, sep) do
    {m, rest} = operand(rest)

    case rest do
      "]" <> r -> {op.(acc, m), r}
      ^sep <> r -> chain(r, op.(acc, m), op, sep)
      _ -> fail("Invalid set operation in character class")
    end
  end

  defp chain_and("&" <> _, _), do: fail("Invalid set operation in character class")
  defp chain_and(rest, acc), do: chain(rest, acc, &intersect/2, "&&")

  # a set operand: no range
  defp operand(rest) do
    case atom(rest) do
      {:char, cp, rest} -> {char_model(cp), rest}
      {:set, m, rest} -> {m, rest}
    end
  end

  # one union member: a range, or an operand
  defp item(rest) do
    case atom(rest) do
      {:char, lo, "-" <> after_dash = rest2} ->
        if String.starts_with?(rest2, "--") do
          {:operand, char_model(lo), rest2}
        else
          case atom(after_dash) do
            {:char, hi, rest3} when hi >= lo ->
              {:range, frag_model("[#{lit(lo)}-#{lit(hi)}]"), rest3}

            {:char, _, _} ->
              fail("Range out of order in character class")

            _ ->
              fail("Invalid character class")
          end
        end

      {:char, cp, rest} ->
        {:operand, char_model(cp), rest}

      {:set, m, rest} ->
        {:operand, m, rest}
    end
  end

  # ── atoms ──────────────────────────────────────────────────

  defp atom("[" <> rest) do
    {m, rest} = class(rest)
    {:set, m, rest}
  end

  defp atom("\\q{" <> rest) do
    [body, rest] =
      case String.split(rest, "}", parts: 2) do
        [_, _] = parts -> parts
        _ -> fail("Invalid escape")
      end

    {:set, string_disjunction(body), rest}
  end

  defp atom(<<?\\, d, rest::binary>>) when d in ~c"dDsSwW",
    do: {:set, frag_model(<<?\\, d>>), rest}

  defp atom("\\p{" <> rest), do: property(rest, false)
  defp atom("\\P{" <> rest), do: property(rest, true)
  defp atom("\\" <> rest), do: escape(rest)
  defp atom(""), do: fail("Unterminated character class")

  defp atom(<<c::utf8, n::utf8, _::binary>>) when c in @double and c == n,
    do: fail("Invalid set operation in character class")

  defp atom(<<c::utf8, _::binary>>) when c in @syntax,
    do: fail("Invalid character in character class")

  defp atom(<<c::utf8, rest::binary>>), do: {:char, c, rest}

  defp property(rest, negated?) do
    [name, rest] =
      case String.split(rest, "}", parts: 2) do
        [_, _] = parts -> parts
        _ -> fail("Invalid property name")
      end

    cond do
      name == "Emoji_Keycap_Sequence" and negated? ->
        fail("Negated property of strings")

      name == "Emoji_Keycap_Sequence" ->
        {:set, strings_model(@keycap, true), rest}

      true ->
        {:set, frag_model("\\#{if negated?, do: "P", else: "p"}{#{name}}"), rest}
    end
  end

  defp escape(<<?u, ?{, rest::binary>>) do
    case String.split(rest, "}", parts: 2) do
      [hex, rest] ->
        case Integer.parse(hex, 16) do
          {cp, ""} when cp <= 0x10FFFF -> {:char, cp, rest}
          _ -> fail("Invalid Unicode escape")
        end

      _ ->
        fail("Invalid Unicode escape")
    end
  end

  defp escape(<<?u, hex::binary-size(4), rest::binary>>) do
    case Integer.parse(hex, 16) do
      {hi, ""} when hi in 0xD800..0xDBFF ->
        with <<"\\u", lo_hex::binary-size(4), after_pair::binary>> <- rest,
             {lo, ""} when lo in 0xDC00..0xDFFF <- Integer.parse(lo_hex, 16) do
          {:char, 0x10000 + (hi - 0xD800) * 0x400 + (lo - 0xDC00), after_pair}
        else
          _ -> {:char, hi, rest}
        end

      {cp, ""} ->
        {:char, cp, rest}

      _ ->
        fail("Invalid Unicode escape")
    end
  end

  defp escape(<<?x, hex::binary-size(2), rest::binary>>) do
    case Integer.parse(hex, 16) do
      {cp, ""} -> {:char, cp, rest}
      _ -> fail("Invalid escape")
    end
  end

  defp escape(<<?c, l, rest::binary>>) when l in ?a..?z or l in ?A..?Z,
    do: {:char, rem(l, 32), rest}

  defp escape(<<?0, rest::binary>>), do: {:char, 0, rest}
  defp escape(<<?b, rest::binary>>), do: {:char, 8, rest}
  defp escape(<<?t, rest::binary>>), do: {:char, 9, rest}
  defp escape(<<?n, rest::binary>>), do: {:char, 10, rest}
  defp escape(<<?v, rest::binary>>), do: {:char, 11, rest}
  defp escape(<<?f, rest::binary>>), do: {:char, 12, rest}
  defp escape(<<?r, rest::binary>>), do: {:char, 13, rest}

  defp escape(<<c::utf8, rest::binary>>) when c in @syntax or c in @reserved,
    do: {:char, c, rest}

  defp escape(_), do: fail("Invalid escape")

  # `\q{ab|c|}`: alternatives of characters
  defp string_disjunction(body) do
    body
    |> split_alternatives("", [])
    |> Enum.reduce(empty(), fn alt, acc ->
      case alt do
        [cp] -> union(acc, char_model(cp))
        cps -> union(acc, strings_model([for(c <- cps, into: "", do: <<c::utf8>>)], false))
      end
    end)
  end

  defp split_alternatives("", cur, acc), do: Enum.reverse([chars_of(cur) | acc])

  defp split_alternatives("|" <> rest, cur, acc),
    do: split_alternatives(rest, "", [chars_of(cur) | acc])

  defp split_alternatives(<<?\\, c::utf8, rest::binary>>, cur, acc),
    do: split_alternatives(rest, cur <> <<?\\, c::utf8>>, acc)

  defp split_alternatives(<<c::utf8, rest::binary>>, cur, acc),
    do: split_alternatives(rest, cur <> <<c::utf8>>, acc)

  # the characters of one alternative (each a ClassSetCharacter)
  defp chars_of(""), do: []

  defp chars_of(src) do
    case atom(src) do
      {:char, cp, rest} -> [cp | chars_of(rest)]
      _ -> fail("Invalid escape in string literal")
    end
  end
end
