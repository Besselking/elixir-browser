defmodule Browser.JS.RegExpSyntax do
  @moduledoc """
  The early errors of the regular expression grammar, for patterns without the `v` flag.

  Erlang's `:re` accepts things JavaScript rejects (`a++`, `(?i-i:a)`, a lone `]` with the `u`
  flag, ...). This is a recursive-descent pass over the pattern that only validates: it follows
  the ECMAScript grammar including the Annex B leniency of patterns without `u`, and throws
  `{:re_error, message}` where a pattern is not allowed.
  """

  @syntax_chars ~c"^$\\.*+?()[]{}|/"

  @doc "Validates `source`; `u?` is true for the `u` flag (and `v`)."
  def check(source, u?) do
    names = scan_names(source)
    total = count_groups(source)
    ctx = %{u: u?, total: total, names: names, named?: names != []}

    rest = disjunction(source, ctx)

    case rest do
      "" -> :ok
      ")" <> _ -> fail("Unmatched ')'")
    end
  end

  defp fail(msg), do: throw({:re_error, msg})

  @doc """
  Rewrites what PCRE would read differently, on a pattern whose named groups were renamed
  `g<n>`: a reference to a group that is not closed yet (forward or from inside the group)
  matches the empty string, and `\\N` for a group that does not exist is a legacy octal escape.
  """
  def fix_references(source) do
    total = count_groups(source)
    fix(source, total, false, 0, [], MapSet.new(), [])
  end

  defp fix("", _total, _cls, _n, _stack, _closed, acc),
    do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  defp fix("\\k<g" <> rest, total, false, n, stack, closed, acc) do
    case Integer.parse(rest) do
      {i, ">" <> after_ref} ->
        out = if MapSet.member?(closed, i), do: "\\k<g#{i}>", else: "(?:)"
        fix(after_ref, total, false, n, stack, closed, [out | acc])

      _ ->
        fix(rest, total, false, n, stack, closed, ["\\k<g" | acc])
    end
  end

  defp fix(<<?\\, d, _::binary>> = s, total, cls, n, stack, closed, acc) when d in ?1..?9 do
    <<?\\, digits::binary>> = s
    {i, after_digits} = digits(digits)
    ndigits = byte_size(digits) - byte_size(after_digits)

    cond do
      not cls and i <= total ->
        out =
          if MapSet.member?(closed, i), do: "\\" <> binary_part(digits, 0, ndigits), else: "(?:)"

        fix(after_digits, total, cls, n, stack, closed, [out | acc])

      d >= ?8 ->
        <<_, rest::binary>> = digits
        fix(rest, total, cls, n, stack, closed, [<<d>> | acc])

      true ->
        {octal, rest} = take_octal(digits)
        out = "\\x{" <> Integer.to_string(octal, 16) <> "}"
        fix(rest, total, cls, n, stack, closed, [out | acc])
    end
  end

  defp fix(<<?\\, c::utf8, rest::binary>>, total, cls, n, stack, closed, acc),
    do: fix(rest, total, cls, n, stack, closed, [<<?\\, c::utf8>> | acc])

  defp fix("[" <> rest, total, false, n, stack, closed, acc),
    do: fix(rest, total, true, n, stack, closed, ["[" | acc])

  defp fix("]" <> rest, total, true, n, stack, closed, acc),
    do: fix(rest, total, false, n, stack, closed, ["]" | acc])

  # PCRE stops at 65535 repetitions; larger counts could never be matched anyway
  defp fix("{" <> rest, total, false, n, stack, closed, acc) do
    case braced_quantifier("{" <> rest) do
      {min, max, after_q} ->
        clamp = fn v -> Integer.to_string(min(v, 65_535)) end

        out =
          cond do
            max == :infinity -> "{#{clamp.(min)},}"
            min == max -> "{#{clamp.(min)}}"
            true -> "{#{clamp.(min)},#{clamp.(max)}}"
          end

        fix(after_q, total, false, n, stack, closed, [out | acc])

      nil ->
        fix(rest, total, false, n, stack, closed, ["{" | acc])
    end
  end

  defp fix("(?<g" <> rest, total, false, n, stack, closed, acc) do
    {i, _} = Integer.parse(rest)
    fix(rest, total, false, n, [i | stack], closed, ["(?<g" | acc])
  end

  defp fix("(?" <> rest, total, false, n, stack, closed, acc),
    do: fix(rest, total, false, n, [:nc | stack], closed, ["(?" | acc])

  defp fix("(" <> rest, total, false, n, stack, closed, acc),
    do: fix(rest, total, false, n + 1, [n + 1 | stack], closed, ["(" | acc])

  defp fix(")" <> rest, total, false, n, [top | stack], closed, acc) do
    closed = if is_integer(top), do: MapSet.put(closed, top), else: closed
    fix(rest, total, false, n, stack, closed, [")" | acc])
  end

  defp fix(<<c::utf8, rest::binary>>, total, cls, n, stack, closed, acc),
    do: fix(rest, total, cls, n, stack, closed, [<<c::utf8>> | acc])

  defp fix(<<c, rest::binary>>, total, cls, n, stack, closed, acc),
    do: fix(rest, total, cls, n, stack, closed, [<<c>> | acc])

  # up to three octal digits, the value at most 0o377
  defp take_octal(<<a, b, c, rest::binary>>) when a in ?0..?3 and b in ?0..?7 and c in ?0..?7,
    do: {String.to_integer(<<a, b, c>>, 8), rest}

  defp take_octal(<<a, b, rest::binary>>) when a in ?0..?7 and b in ?0..?7,
    do: {String.to_integer(<<a, b>>, 8), rest}

  defp take_octal(<<a, rest::binary>>), do: {a - ?0, rest}

  # ── prepass: group count and names ─────────────────────────

  defp count_groups(src), do: count_groups(src, false, 0)

  defp count_groups("", _cls, n), do: n
  defp count_groups(<<?\\, _::utf8, rest::binary>>, cls, n), do: count_groups(rest, cls, n)
  defp count_groups("[" <> rest, false, n), do: count_groups(rest, true, n)
  defp count_groups("]" <> rest, true, n), do: count_groups(rest, false, n)

  defp count_groups("(?<" <> rest, false, n) do
    case rest do
      "=" <> _ -> count_groups(rest, false, n)
      "!" <> _ -> count_groups(rest, false, n)
      _ -> count_groups(rest, false, n + 1)
    end
  end

  defp count_groups("(?" <> rest, false, n), do: count_groups(rest, false, n)
  defp count_groups("(" <> rest, false, n), do: count_groups(rest, false, n + 1)
  defp count_groups(<<_::utf8, rest::binary>>, cls, n), do: count_groups(rest, cls, n)
  defp count_groups(<<_, rest::binary>>, cls, n), do: count_groups(rest, cls, n)

  defp scan_names(src), do: scan_names(src, false, [])

  defp scan_names("", _cls, acc), do: acc
  defp scan_names(<<?\\, _::utf8, rest::binary>>, cls, acc), do: scan_names(rest, cls, acc)
  defp scan_names("[" <> rest, false, acc), do: scan_names(rest, true, acc)
  defp scan_names("]" <> rest, true, acc), do: scan_names(rest, false, acc)

  defp scan_names("(?<" <> rest, false, acc) do
    case rest do
      "=" <> _ ->
        scan_names(rest, false, acc)

      "!" <> _ ->
        scan_names(rest, false, acc)

      _ ->
        case String.split(rest, ">", parts: 2) do
          [name, after_name] -> scan_names(after_name, false, [name | acc])
          _ -> acc
        end
    end
  end

  defp scan_names(<<_::utf8, rest::binary>>, cls, acc), do: scan_names(rest, cls, acc)
  defp scan_names(<<_, rest::binary>>, cls, acc), do: scan_names(rest, cls, acc)

  # ── disjunction, alternative, term ─────────────────────────

  # parses up to an unmatched `)` or the end and returns what is left
  defp disjunction(s, ctx) do
    case alternative(s, ctx) do
      "|" <> rest -> disjunction(rest, ctx)
      rest -> rest
    end
  end

  defp alternative("", _ctx), do: ""
  defp alternative("|" <> _ = s, _ctx), do: s
  defp alternative(")" <> _ = s, _ctx), do: s
  defp alternative(s, ctx), do: s |> term(ctx) |> alternative(ctx)

  defp term("^" <> rest, ctx), do: no_quantifier(rest, ctx)
  defp term("$" <> rest, ctx), do: no_quantifier(rest, ctx)
  defp term("\\b" <> rest, ctx), do: no_quantifier(rest, ctx)
  defp term("\\B" <> rest, ctx), do: no_quantifier(rest, ctx)

  defp term("(?=" <> rest, ctx), do: lookahead(rest, ctx)
  defp term("(?!" <> rest, ctx), do: lookahead(rest, ctx)
  defp term("(?<=" <> rest, ctx), do: rest |> group_body(ctx) |> no_quantifier(ctx)
  defp term("(?<!" <> rest, ctx), do: rest |> group_body(ctx) |> no_quantifier(ctx)

  defp term("(?<" <> rest, ctx) do
    case String.split(rest, ">", parts: 2) do
      [name, after_name] when name != "" -> after_name |> group_body(ctx) |> quantifier(ctx)
      _ -> fail("Invalid capture group name")
    end
  end

  defp term("(?:" <> rest, ctx), do: rest |> group_body(ctx) |> quantifier(ctx)

  defp term("(?" <> rest, ctx) do
    rest |> modifiers() |> group_body(ctx) |> quantifier(ctx)
  end

  defp term("(" <> rest, ctx), do: rest |> group_body(ctx) |> quantifier(ctx)

  defp term(<<c, _::binary>>, _ctx) when c in [?*, ?+, ??], do: fail("Nothing to repeat")

  defp term("{" <> rest = s, ctx) do
    cond do
      braced_quantifier(s) != nil -> fail("Nothing to repeat")
      ctx.u -> fail("Incomplete quantifier")
      true -> quantifier(rest, ctx)
    end
  end

  defp term("}" <> rest, ctx) do
    if ctx.u, do: fail("Lone quantifier brackets"), else: quantifier(rest, ctx)
  end

  defp term("]" <> rest, ctx) do
    if ctx.u, do: fail("Lone quantifier brackets"), else: quantifier(rest, ctx)
  end

  defp term("[" <> rest, ctx), do: rest |> class(ctx) |> quantifier(ctx)
  defp term("." <> rest, ctx), do: quantifier(rest, ctx)
  defp term("\\" <> rest, ctx), do: rest |> atom_escape(ctx) |> quantifier(ctx)
  defp term(<<_::utf8, rest::binary>>, ctx), do: quantifier(rest, ctx)
  defp term(<<_, rest::binary>>, ctx), do: quantifier(rest, ctx)

  # an assertion that cannot be repeated
  defp no_quantifier(rest, _ctx) do
    case rest do
      <<c, _::binary>> when c in [?*, ?+, ?\?] -> fail("Nothing to repeat")
      "{" <> _ -> if braced_quantifier(rest), do: fail("Nothing to repeat"), else: rest
      _ -> rest
    end
  end

  # lookaheads are quantifiable only without the u flag (Annex B)
  defp lookahead(rest, ctx) do
    rest = group_body(rest, ctx)
    if ctx.u, do: no_quantifier(rest, ctx), else: quantifier(rest, ctx)
  end

  defp group_body(rest, ctx) do
    case disjunction(rest, ctx) do
      ")" <> after_group -> after_group
      _ -> fail("Unterminated group")
    end
  end

  # `(?ims-ims:` flags: letters from `ims`, none twice, not both empty around a `-`
  defp modifiers(rest) do
    {add, rest} = take_flags(rest, "")

    {remove, rest, dash?} =
      case rest do
        "-" <> r ->
          {rem, r} = take_flags(r, "")
          {rem, r, true}

        _ ->
          {"", rest, false}
      end

    rest =
      case rest do
        ":" <> r -> r
        _ -> fail("Invalid group")
      end

    all = String.graphemes(add <> remove)

    cond do
      length(all) != length(Enum.uniq(all)) -> fail("Repeated flag in modifiers")
      dash? and add == "" and remove == "" -> fail("Invalid regular expression modifiers")
      true -> rest
    end
  end

  defp take_flags(<<c, rest::binary>>, acc) when c in ~c"ims", do: take_flags(rest, acc <> <<c>>)
  defp take_flags(<<c, _::binary>>, _acc) when c not in [?-, ?:], do: fail("Invalid group")
  defp take_flags(rest, acc), do: {acc, rest}

  # ── quantifiers ────────────────────────────────────────────

  defp quantifier(<<c, rest::binary>>, _ctx) when c in [?*, ?+, ?\?], do: lazy(rest)

  defp quantifier("{" <> _ = s, ctx) do
    case braced_quantifier(s) do
      nil ->
        if ctx.u, do: fail("Incomplete quantifier"), else: s

      {min, max, rest} when max != :infinity and min > max ->
        fail("numbers out of order in {} quantifier") |> then(fn _ -> rest end)

      {_, _, rest} ->
        lazy(rest)
    end
  end

  defp quantifier(rest, _ctx), do: rest

  defp lazy("?" <> rest), do: rest
  defp lazy(rest), do: rest

  # `{n}`, `{n,}` or `{n,m}` at the start of `s`: `{min, max, rest}` or nil
  defp braced_quantifier("{" <> rest) do
    with {min, after_min} when min != nil <- digits(rest) do
      case after_min do
        "}" <> r ->
          {min, min, r}

        "," <> r ->
          case digits(r) do
            {nil, "}" <> r2} -> {min, :infinity, r2}
            {max, "}" <> r2} when max != nil -> {min, max, r2}
            _ -> nil
          end

        _ ->
          nil
      end
    else
      _ -> nil
    end
  end

  defp digits(s), do: digits(s, nil)

  defp digits(<<c, rest::binary>>, acc) when c in ?0..?9,
    do: digits(rest, (acc || 0) * 10 + c - ?0)

  defp digits(rest, acc), do: {acc, rest}

  # ── escapes outside a class ────────────────────────────────

  defp atom_escape("", _ctx), do: fail("\\ at end of pattern")

  defp atom_escape(<<d, _::binary>> = s, ctx) when d in ?1..?9 do
    {n, rest} = digits(s)

    cond do
      n <= ctx.total -> rest
      ctx.u -> fail("Invalid escape")
      d >= ?8 -> binary_part(s, 1, byte_size(s) - 1)
      true -> legacy_octal(s)
    end
  end

  defp atom_escape("0" <> rest, ctx) do
    case rest do
      <<d, _::binary>> when d in ?0..?9 ->
        if ctx.u, do: fail("Invalid decimal escape"), else: legacy_octal("0" <> rest)

      _ ->
        rest
    end
  end

  defp atom_escape(<<c, rest::binary>>, _ctx) when c in ~c"dDsSwWfnrtv", do: rest

  defp atom_escape("c" <> rest, ctx) do
    case rest do
      <<l, r::binary>> when l in ?a..?z or l in ?A..?Z -> r
      _ -> if ctx.u, do: fail("Invalid unicode escape"), else: "c" <> rest
    end
  end

  defp atom_escape("x" <> rest, ctx) do
    case rest do
      <<a, b, r::binary>>
      when a in ~c"0123456789abcdefABCDEF" and b in ~c"0123456789abcdefABCDEF" ->
        r

      _ ->
        if ctx.u, do: fail("Invalid escape"), else: rest
    end
  end

  defp atom_escape("u" <> rest, ctx), do: unicode_escape(rest, ctx)

  defp atom_escape("k" <> rest, ctx) do
    if ctx.u or ctx.named? do
      case rest do
        "<" <> r ->
          case String.split(r, ">", parts: 2) do
            [name, after_name] when name != "" ->
              if name in ctx.names, do: after_name, else: fail("Invalid named capture referenced")

            _ ->
              fail("Invalid named reference")
          end

        _ ->
          fail("Invalid named reference")
      end
    else
      rest
    end
  end

  defp atom_escape(<<p, rest::binary>>, ctx) when p in ~c"pP" do
    if ctx.u, do: property(rest), else: rest
  end

  defp atom_escape(<<c::utf8, rest::binary>>, ctx) do
    if ctx.u and c not in @syntax_chars, do: fail("Invalid escape"), else: rest
  end

  defp atom_escape(<<_, rest::binary>>, _ctx), do: rest

  # `\u` followed by four hex digits (or braces with the u flag); returns what is after it
  defp unicode_escape("{" <> rest, %{u: true}) do
    case String.split(rest, "}", parts: 2) do
      [hex, after_brace] when hex != "" ->
        case Integer.parse(hex, 16) do
          {n, ""} when n <= 0x10FFFF -> after_brace
          _ -> fail("Invalid Unicode escape")
        end

      _ ->
        fail("Invalid Unicode escape")
    end
  end

  defp unicode_escape(<<h::binary-size(4), rest::binary>>, ctx) do
    if Regex.match?(~r/^[0-9a-fA-F]{4}$/, h),
      do: rest,
      else: if(ctx.u, do: fail("Invalid Unicode escape"), else: h <> rest)
  end

  defp unicode_escape(rest, ctx), do: if(ctx.u, do: fail("Invalid Unicode escape"), else: rest)

  # `\p{Name}` / `\p{Name=Value}`: the braces must be there and the text plain
  defp property("{" <> rest) do
    case String.split(rest, "}", parts: 2) do
      [body, after_brace] ->
        if Regex.match?(~r/^[A-Za-z0-9_]+(=[A-Za-z0-9_]+)?$/, body),
          do: after_brace,
          else: fail("Invalid property name")

      _ ->
        fail("Invalid property name")
    end
  end

  defp property(_), do: fail("Invalid property name")

  # Annex B: up to three octal digits with a value of at most 0o377
  defp legacy_octal(<<a, b, c, rest::binary>>) when a in ?0..?3 and b in ?0..?7 and c in ?0..?7,
    do: rest

  defp legacy_octal(<<a, b, rest::binary>>) when a in ?0..?7 and b in ?0..?7, do: rest
  defp legacy_octal(<<_, rest::binary>>), do: rest

  # ── character classes ──────────────────────────────────────

  defp class("^" <> rest, ctx), do: class_items(rest, ctx)
  defp class(rest, ctx), do: class_items(rest, ctx)

  defp class_items("", _ctx), do: fail("Unterminated character class")
  defp class_items("]" <> rest, _ctx), do: rest

  defp class_items(s, ctx) do
    {lo, rest} = class_atom(s, ctx)

    case rest do
      "-" <> after_dash when after_dash != "" and binary_part(after_dash, 0, 1) != "]" ->
        {hi, rest2} = class_atom(after_dash, ctx)

        case {lo, hi} do
          {{:char, a}, {:char, b}} ->
            if a > b, do: fail("Range out of order in character class")
            class_items(rest2, ctx)

          _ ->
            if ctx.u, do: fail("Invalid character class")
            class_items(rest2, ctx)
        end

      _ ->
        class_items(rest, ctx)
    end
  end

  # {:char, code point} | :set
  defp class_atom("\\" <> rest, ctx), do: class_escape(rest, ctx)
  defp class_atom(<<c::utf8, rest::binary>>, _ctx), do: {{:char, c}, rest}
  defp class_atom(<<c, rest::binary>>, _ctx), do: {{:char, c}, rest}

  defp class_escape("", _ctx), do: fail("\\ at end of pattern")
  defp class_escape("b" <> rest, _ctx), do: {{:char, 8}, rest}
  defp class_escape("-" <> rest, _ctx), do: {{:char, ?-}, rest}
  defp class_escape(<<c, rest::binary>>, _ctx) when c in ~c"dDsSwW", do: {:set, rest}

  defp class_escape(<<p, rest::binary>>, ctx) when p in ~c"pP" do
    if ctx.u, do: {:set, property(rest)}, else: {{:char, p}, rest}
  end

  defp class_escape(<<c, rest::binary>>, _ctx) when c in ~c"fnrtv",
    do: {{:char, escape_value(c)}, rest}

  defp class_escape("c" <> rest, ctx) do
    case rest do
      <<l, r::binary>> when l in ?a..?z or l in ?A..?Z -> {{:char, rem(l, 32)}, r}
      <<l, r::binary>> when (l in ?0..?9 or l == ?_) and not ctx.u -> {{:char, rem(l, 32)}, r}
      _ -> if ctx.u, do: fail("Invalid class escape"), else: {{:char, ?\\}, "c" <> rest}
    end
  end

  defp class_escape("0" <> rest, ctx) do
    case rest do
      <<d, _::binary>> when d in ?0..?9 ->
        if ctx.u, do: fail("Invalid class escape"), else: {{:char, 0}, legacy_octal("0" <> rest)}

      _ ->
        {{:char, 0}, rest}
    end
  end

  defp class_escape(<<d, _::binary>> = s, ctx) when d in ?1..?9 do
    if ctx.u, do: fail("Invalid class escape")

    if d >= ?8,
      do: {{:char, d}, binary_part(s, 1, byte_size(s) - 1)},
      else: {{:char, d}, legacy_octal(s)}
  end

  defp class_escape("x" <> rest, ctx) do
    case rest do
      <<a, b, r::binary>>
      when a in ~c"0123456789abcdefABCDEF" and b in ~c"0123456789abcdefABCDEF" ->
        {{:char, String.to_integer(<<a, b>>, 16)}, r}

      _ ->
        if ctx.u, do: fail("Invalid escape"), else: {{:char, ?x}, rest}
    end
  end

  defp class_escape("u" <> rest, ctx) do
    after_escape = unicode_escape(rest, ctx)
    consumed = binary_part(rest, 0, byte_size(rest) - byte_size(after_escape))

    value =
      case consumed do
        "{" <> body -> body |> String.trim_trailing("}") |> String.to_integer(16)
        <<_::binary-size(4)>> -> String.to_integer(consumed, 16)
        _ -> ?u
      end

    # a surrogate pair written as two escapes is one character under the u flag
    {{:char, value}, after_escape}
  end

  defp class_escape(<<c::utf8, rest::binary>>, ctx) do
    if ctx.u and c not in @syntax_chars,
      do: fail("Invalid escape"),
      else: {{:char, c}, rest}
  end

  defp class_escape(<<c, rest::binary>>, _ctx), do: {{:char, c}, rest}

  defp escape_value(?f), do: 12
  defp escape_value(?n), do: 10
  defp escape_value(?r), do: 13
  defp escape_value(?t), do: 9
  defp escape_value(?v), do: 11
end
