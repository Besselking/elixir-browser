defmodule Browser.CSS do
  @moduledoc """
  A small CSS parser and selector matcher.

  Supported: type/universal, `#id`, `.class`, attribute selectors (`=`, `~=`,
  `|=`, `^=`, `$=`, `*=`, `i` flag), the descendant/child/next-sibling/
  subsequent-sibling combinators, and the pseudo-classes `:root`,
  `:first-child`, `:last-child`, `:only-child` and `:not(<compound>)`.

  Selectors using anything else (`:hover`, `::before`, `:nth-child(…)`, …) are
  dropped, since they can't be evaluated statically. At-rules (`@media`,
  `@import`, `@font-face`, …) are skipped entirely.

  A rule is `%{selector: parts, specificity: {ids, classes, types}, decls: decls}`
  where `decls` is `[{property, value, important?}]` and `parts` is the
  selector in right-to-left form: `[{compound, combinator_to_the_left}, …]`.
  """

  # -- stylesheet parsing --------------------------------------------------------

  def parse(css) when is_binary(css) do
    css
    |> String.replace_invalid()
    |> strip_comments()
    |> blocks([])
    |> Enum.flat_map(fn {prelude, body} ->
      decls = parse_declarations(body)

      for sel <- split_top(prelude, ?,),
          {:ok, %{parts: parts, spec: spec}} <- [parse_selector(sel)] do
        %{selector: parts, specificity: spec, decls: decls}
      end
    end)
  end

  @doc "Parses the contents of a declaration block / `style` attribute."
  def parse_declarations(body) when is_binary(body) do
    body
    |> String.replace_invalid()
    |> strip_comments()
    |> split_top(?;)
    |> Enum.flat_map(fn piece ->
      with false <- String.contains?(piece, "{"),
           [prop, value] <- :binary.split(piece, ":"),
           prop = prop |> String.trim() |> String.downcase(),
           true <- prop != "" do
        {value, important?} = split_important(String.trim(value))
        [{prop, value, important?}]
      else
        _ -> []
      end
    end)
  end

  defp split_important(value) do
    case Regex.run(~r/\A(.*?)\s*!\s*important\s*\z/is, value, capture: :all_but_first) do
      [v] -> {String.trim(v), true}
      nil -> {value, false}
    end
  end

  defp strip_comments(css), do: Regex.replace(~r{/\*.*?\*/}s, css, " ")

  # -> [{prelude, body}] for each qualified rule, skipping at-rules
  defp blocks(bin, acc) do
    case String.trim_leading(bin) do
      "" ->
        Enum.reverse(acc)

      "@" <> _ = b ->
        b |> skip_at_rule() |> blocks(acc)

      "}" <> rest ->
        blocks(rest, acc)

      b ->
        case :binary.match(b, ["{", ";"]) do
          :nomatch ->
            Enum.reverse(acc)

          {pos, 1} ->
            <<prelude::binary-size(^pos), delim, rest::binary>> = b

            if delim == ?{ do
              {body, rest} = take_block(rest)
              blocks(rest, [{prelude, body} | acc])
            else
              blocks(rest, acc)
            end
        end
    end
  end

  defp skip_at_rule(bin) do
    case :binary.match(bin, ["{", ";"]) do
      :nomatch ->
        ""

      {pos, 1} ->
        <<_::binary-size(^pos), delim, rest::binary>> = bin

        if delim == ?{ do
          {_, rest} = take_block(rest)
          rest
        else
          rest
        end
    end
  end

  # `bin` starts just after an opening "{": returns {body, rest_after_closing_brace}
  defp take_block(bin), do: scan(bin, bin, 1, nil, 0)

  defp scan(<<>>, whole, _d, _q, _n), do: {whole, ""}
  defp scan(<<?\\, _, r::binary>>, w, d, q, n), do: scan(r, w, d, q, n + 2)

  defp scan(<<c, r::binary>>, w, d, q, n) when q != nil,
    do: scan(r, w, d, if(c == q, do: nil, else: q), n + 1)

  defp scan(<<c, r::binary>>, w, d, nil, n) when c in [?", ?'], do: scan(r, w, d, c, n + 1)
  defp scan(<<?{, r::binary>>, w, d, nil, n), do: scan(r, w, d + 1, nil, n + 1)

  defp scan(<<?}, r::binary>>, w, d, nil, n) do
    if d == 1,
      do: {binary_part(w, 0, n), r},
      else: scan(r, w, d - 1, nil, n + 1)
  end

  defp scan(<<_, r::binary>>, w, d, q, n), do: scan(r, w, d, q, n + 1)

  # split on `sep` outside of quotes and (), [], {}
  defp split_top(str, sep), do: split_top(str, sep, 0, nil, [], [])

  defp split_top(<<>>, _sep, _d, _q, cur, acc), do: Enum.reverse([flat(cur) | acc])

  defp split_top(<<c, r::binary>>, sep, d, q, cur, acc) do
    cond do
      q != nil -> split_top(r, sep, d, if(c == q, do: nil, else: q), [c | cur], acc)
      c in [?", ?'] -> split_top(r, sep, d, c, [c | cur], acc)
      c in [?(, ?[, ?{] -> split_top(r, sep, d + 1, nil, [c | cur], acc)
      c in [?), ?], ?}] -> split_top(r, sep, max(d - 1, 0), nil, [c | cur], acc)
      c == sep and d == 0 -> split_top(r, sep, 0, nil, [], [flat(cur) | acc])
      true -> split_top(r, sep, d, nil, [c | cur], acc)
    end
  end

  defp flat(cur), do: cur |> Enum.reverse() |> :erlang.list_to_binary()

  # -- selector parsing ----------------------------------------------------------

  @doc "Parses one complex selector. Returns `{:ok, %{parts: …, spec: …}}` or `:error`."
  def parse_selector(str) do
    with {:ok, toks} <- tokenize(String.trim(str), []),
         {:ok, parts} <- group(toks) do
      {:ok, %{parts: parts, spec: specificity(parts)}}
    end
  end

  defp tokenize("", acc), do: {:ok, Enum.reverse(acc)}

  defp tokenize(s, acc) do
    cond do
      m = Regex.run(~r/\A\s*([>+~])\s*/u, s) ->
        [whole, c] = m
        tokenize(drop(s, whole), [{:comb, comb(c)} | acc])

      m = Regex.run(~r/\A\s+/u, s) ->
        tokenize(drop(s, hd(m)), [{:comb, :descendant} | acc])

      String.starts_with?(s, "*") ->
        tokenize(binary_part(s, 1, byte_size(s) - 1), [:any | acc])

      m = Regex.run(~r/\A#([\w\-\x{80}-\x{10FFFF}]+)/u, s) ->
        [whole, id] = m
        tokenize(drop(s, whole), [{:id, id} | acc])

      m = Regex.run(~r/\A\.([\w\-\x{80}-\x{10FFFF}]+)/u, s) ->
        [whole, cls] = m
        tokenize(drop(s, whole), [{:class, cls} | acc])

      m = Regex.run(~r/\A\[\s*([\w\-:]+)\s*(?:([~|^$*]?=)\s*(?:"([^"]*)"|'([^']*)'|([^\s\]]+))\s*([iIsS])?)?\s*\]/u, s) ->
        [whole, name | rest] = m
        tokenize(drop(s, whole), [attr_token(name, rest) | acc])

      String.starts_with?(s, "::") ->
        :error

      m = Regex.run(~r/\A:not\(([^()]*)\)/u, s) ->
        [whole, inner] = m

        with {:ok, toks} <- tokenize(String.trim(inner), []),
             true <- Enum.all?(toks, &(not match?({:comb, _}, &1))),
             {:ok, cmp} <- compound(toks) do
          tokenize(drop(s, whole), [{:not, cmp} | acc])
        else
          _ -> :error
        end

      m = Regex.run(~r/\A:(root|first-child|last-child|only-child)(?![\w\-(])/u, s) ->
        [whole, name] = m
        pseudo = name |> String.replace("-", "_") |> String.to_atom()
        tokenize(drop(s, whole), [{:pseudo, pseudo} | acc])

      m = Regex.run(~r/\A([\w\-\x{80}-\x{10FFFF}]+)/u, s) ->
        [whole, tag] = m
        tokenize(drop(s, whole), [{:tag, String.downcase(tag)} | acc])

      true ->
        :error
    end
  end

  defp drop(s, prefix), do: binary_part(s, byte_size(prefix), byte_size(s) - byte_size(prefix))

  defp comb(">"), do: :child
  defp comb("+"), do: :next
  defp comb("~"), do: :subsequent

  # regex captures trail off when optional groups don't participate
  defp attr_token(name, []), do: {:attr, String.downcase(name), nil, nil, false}

  defp attr_token(name, [op | vals]) do
    [dq, sq, bare | flag] = vals ++ List.duplicate("", max(0, 4 - length(vals)))
    val = Enum.find([dq, sq, bare], "", &(&1 != ""))
    ci = flag |> List.first("") |> String.downcase() == "i"
    {:attr, String.downcase(name), op, val, ci}
  end

  # tokens -> right-to-left [{compound, combinator_to_left_neighbour}]
  defp group(toks) do
    case split_combs(toks, [], [], []) do
      {:ok, compounds, combs} ->
        built = Enum.map(compounds, &compound/1)

        if Enum.all?(built, &match?({:ok, _}, &1)) do
          cmps = built |> Enum.map(&elem(&1, 1)) |> Enum.reverse()
          {:ok, Enum.zip(cmps, Enum.reverse(combs) ++ [nil])}
        else
          :error
        end

      :error ->
        :error
    end
  end

  # -> {:ok, [compound_tokens] (left to right), [combinators] (left to right)}
  defp split_combs([], cur, cmps, combs) when cur != [],
    do: {:ok, Enum.reverse([Enum.reverse(cur) | cmps]), Enum.reverse(combs)}

  defp split_combs([], [], _, _), do: :error
  defp split_combs([{:comb, _} | _], [], _, _), do: :error

  defp split_combs([{:comb, c} | rest], cur, cmps, combs),
    do: split_combs(rest, [], [Enum.reverse(cur) | cmps], [c | combs])

  defp split_combs([t | rest], cur, cmps, combs), do: split_combs(rest, [t | cur], cmps, combs)

  defp compound(toks) do
    {head, rest} =
      case toks do
        [{:tag, t} | r] -> {t, r}
        [:any | r] -> {:any, r}
        r -> {nil, r}
      end

    Enum.reduce_while(rest, {:ok, %{tag: head, id: nil, classes: [], attrs: [], pseudos: []}}, fn
      {:id, id}, {:ok, c} -> {:cont, {:ok, %{c | id: id}}}
      {:class, cl}, {:ok, c} -> {:cont, {:ok, %{c | classes: [cl | c.classes]}}}
      {:attr, n, o, v, i}, {:ok, c} -> {:cont, {:ok, %{c | attrs: [{n, o, v, i} | c.attrs]}}}
      {:pseudo, p}, {:ok, c} -> {:cont, {:ok, %{c | pseudos: [p | c.pseudos]}}}
      {:not, n}, {:ok, c} -> {:cont, {:ok, %{c | pseudos: [{:not, n} | c.pseudos]}}}
      _tag_or_any_mid_compound, _ -> {:halt, :error}
    end)
    |> case do
      {:ok, %{tag: nil, id: nil, classes: [], attrs: [], pseudos: []}} -> :error
      other -> other
    end
  end

  defp specificity(parts) do
    Enum.reduce(parts, {0, 0, 0}, fn {c, _}, acc -> add_spec(acc, compound_spec(c)) end)
  end

  defp compound_spec(c) do
    tags = if is_binary(c.tag), do: 1, else: 0
    ids = if c.id, do: 1, else: 0
    base = {ids, length(c.classes) + length(c.attrs), tags}

    Enum.reduce(c.pseudos, base, fn
      {:not, inner}, acc -> add_spec(acc, compound_spec(inner))
      _, {a, b, t} -> {a, b + 1, t}
    end)
  end

  defp add_spec({a, b, c}, {x, y, z}), do: {a + x, b + y, c + z}

  # -- matching ------------------------------------------------------------------
  #
  # An element context is
  #   %{tag, attrs, id, classes, parent: ctx | nil, prev: [ctx], first?, last?}
  # where `prev` holds the preceding element siblings, nearest first.

  def matches?(parts, ctx), do: match_parts(parts, ctx)

  defp match_parts([{cmp, comb} | rest], ctx),
    do: match_compound(cmp, ctx) and match_rel(comb, rest, ctx)

  defp match_rel(nil, _rest, _ctx), do: true

  defp match_rel(:descendant, rest, ctx) do
    ctx.parent
    |> Stream.unfold(fn
      nil -> nil
      p -> {p, p.parent}
    end)
    |> Enum.any?(&match_parts(rest, &1))
  end

  defp match_rel(:child, rest, %{parent: p}), do: p != nil and match_parts(rest, p)
  defp match_rel(:next, rest, %{prev: [p | _]}), do: match_parts(rest, p)
  defp match_rel(:next, _rest, _ctx), do: false
  defp match_rel(:subsequent, rest, %{prev: prev}), do: Enum.any?(prev, &match_parts(rest, &1))

  defp match_compound(c, ctx) do
    (c.tag in [nil, :any] or c.tag == ctx.tag) and
      (c.id == nil or c.id == ctx.id) and
      Enum.all?(c.classes, &(&1 in ctx.classes)) and
      Enum.all?(c.attrs, &attr_match?(&1, ctx.attrs)) and
      Enum.all?(c.pseudos, &pseudo?(&1, ctx))
  end

  defp attr_match?({name, op, val, ci}, attrs) do
    case List.keyfind(attrs, name, 0) do
      nil -> false
      {_, v} when op == nil -> is_binary(v)
      {_, v} -> attr_op(op, fold(v, ci), fold(val, ci))
    end
  end

  defp fold(s, true), do: String.downcase(s)
  defp fold(s, false), do: s

  defp attr_op("=", v, val), do: v == val
  defp attr_op("~=", v, val), do: val != "" and val in String.split(v)
  defp attr_op("|=", v, val), do: v == val or String.starts_with?(v, val <> "-")
  defp attr_op("^=", v, val), do: val != "" and String.starts_with?(v, val)
  defp attr_op("$=", v, val), do: val != "" and String.ends_with?(v, val)
  defp attr_op("*=", v, val), do: val != "" and String.contains?(v, val)

  defp pseudo?(:root, ctx), do: ctx.parent == nil and ctx.tag == "html"
  defp pseudo?(:first_child, ctx), do: ctx.first?
  defp pseudo?(:last_child, ctx), do: ctx.last?
  defp pseudo?(:only_child, ctx), do: ctx.first? and ctx.last?
  defp pseudo?({:not, cmp}, ctx), do: not match_compound(cmp, ctx)
end
