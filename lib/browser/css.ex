defmodule Browser.CSS do
  @moduledoc """
  A small CSS parser and selector matcher.

  Supported: type/universal, `#id`, `.class`, attribute selectors (`=`, `~=`,
  `|=`, `^=`, `$=`, `*=`, `i` flag), the descendant/child/next-sibling/
  subsequent-sibling combinators, and these pseudo-classes: `:root`, `:empty`,
  `:first-child`, `:last-child`, `:only-child`, `:first-of-type`, `:nth-child()`,
  `:nth-last-child()`, `:nth-of-type()`, `:link`, `:disabled`, `:enabled`, `:checked` (as the page was written), and
  `:not()`/`:is()`/`:where()` over lists of compound selectors. State-dependent
  pseudo-classes (`:hover`, `:focus`, `:visited`, …) never match, which keeps
  `:not(:focus)` true.

  A selector may end in `::before`, `::after` (or the one-colon forms) or `::marker`: its
  rule styles the generated box or marker, and carries `pseudo: :before | :after | :marker`
  (nil for other rules).
  Selectors using anything else (`::marker`, `:has()`, …) are dropped. `@media` (see
  `Browser.MediaQuery`), `@supports` (assumed true unless it starts with `not`)
  and `@layer` blocks are entered; other at-rules (`@import`, `@font-face`,
  `@keyframes`, …) are skipped.

  A rule is `%{selector: parts, specificity: {ids, classes, types}, decls: decls, media: conds,
  pseudo: pseudo}`
  where `decls` is `[{property, value, important?}]`, `media` lists the
  enclosing `@media` query lists (all must match), and `parts` is the
  selector in right-to-left form: `[{compound, combinator_to_the_left}, …]`.
  """

  alias Browser.MediaQuery

  # -- stylesheet parsing --------------------------------------------------------

  def parse(css) when is_binary(css) do
    css
    |> String.replace_invalid()
    |> strip_comments()
    |> blocks([], [])
    |> Enum.flat_map(fn {prelude, body, conds} ->
      decls = parse_declarations(body)

      for sel <- split_top(prelude, ?,),
          {:ok, %{parts: parts, spec: spec, pseudo: pseudo}} <- [parse_selector(sel)] do
        %{selector: parts, specificity: spec, decls: decls, media: conds, pseudo: pseudo}
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

  # -> [{prelude, body, media_conditions}] for each qualified rule, in order
  defp blocks(bin, conds, acc) do
    case String.trim_leading(bin) do
      "" ->
        Enum.reverse(acc)

      "@" <> _ = b ->
        {acc, rest} = at_rule(b, conds, acc)
        blocks(rest, conds, acc)

      "}" <> rest ->
        blocks(rest, conds, acc)

      b ->
        case :binary.match(b, ["{", ";"]) do
          :nomatch ->
            Enum.reverse(acc)

          {pos, 1} ->
            <<prelude::binary-size(^pos), delim, rest::binary>> = b

            if delim == ?{ do
              {body, rest} = take_block(rest)
              blocks(rest, conds, [{prelude, body, conds} | acc])
            else
              blocks(rest, conds, acc)
            end
        end
    end
  end

  defp at_rule(bin, conds, acc) do
    case :binary.match(bin, ["{", ";"]) do
      :nomatch ->
        {acc, ""}

      {pos, 1} ->
        <<head::binary-size(^pos), delim, rest::binary>> = bin

        if delim == ?; do
          {acc, rest}
        else
          {body, rest} = take_block(rest)
          [_, name, prelude] = Regex.run(~r/\A@([\w-]+)\s*(.*)\z/s, head)

          inner =
            case String.downcase(name) do
              "media" -> blocks(body, conds ++ [MediaQuery.parse(prelude)], [])
              "supports" -> if supports_not?(prelude), do: [], else: blocks(body, conds, [])
              "layer" -> blocks(body, conds, [])
              _ -> []
            end

          {Enum.reverse(inner) ++ acc, rest}
        end
    end
  end

  defp supports_not?(prelude),
    do: prelude |> String.trim() |> String.downcase() |> String.starts_with?("not")

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

  defp split_top(<<?\\, x, r::binary>>, sep, d, q, cur, acc),
    do: split_top(r, sep, d, q, [x, ?\\ | cur], acc)

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
    {str, pseudo} = split_pseudo_element(String.trim(str))

    with {:ok, toks} <- tokenize(str, []),
         {:ok, parts} <- group(toks) do
      {:ok, %{parts: parts, spec: specificity(parts), pseudo: pseudo}}
    end
  end

  # `a::before` -> {"a", :before}; a bare `::after` styles the box of every element
  defp split_pseudo_element(str) do
    case Regex.run(~r/\A(.*?)(?:::(before|after|marker)|:(before|after))\z/su, str) do
      [_, head, which] -> {head_or_any(head), String.to_atom(which)}
      [_, head, "", which] -> {head_or_any(head), String.to_atom(which)}
      nil -> {str, nil}
    end
  end

  defp head_or_any(""), do: "*"
  defp head_or_any(head), do: head

  # an identifier: name characters and escapes (`\[`, `\:`, `\31 `), as in Tailwind's `.w-\[10px\]`
  @ident ~S"(?:[\w\-\x{80}-\x{10FFFF}]|\\(?:[0-9a-fA-F]{1,6}\s?|[^\n0-9a-fA-F]))+"

  defp unescape(ident) do
    Regex.replace(~r/\\(?:([0-9a-fA-F]{1,6})\s?|(.))/su, ident, fn
      _, hex, "" -> <<String.to_integer(hex, 16)::utf8>>
      _, _, char -> char
    end)
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

      m = Regex.run(~r/\A#(#{@ident})/u, s) ->
        [whole, id] = m
        tokenize(drop(s, whole), [{:id, unescape(id)} | acc])

      m = Regex.run(~r/\A\.(#{@ident})/u, s) ->
        [whole, cls] = m
        tokenize(drop(s, whole), [{:class, unescape(cls)} | acc])

      m =
          Regex.run(
            ~r/\A\[\s*([\w\-:]+)\s*(?:([~|^$*]?=)\s*(?:"([^"]*)"|'([^']*)'|([^\s\]]+))\s*([iIsS])?)?\s*\]/u,
            s
          ) ->
        [whole, name | rest] = m
        tokenize(drop(s, whole), [attr_token(name, rest) | acc])

      String.starts_with?(s, "::") ->
        :error

      m = Regex.run(~r/\A:(not|is|where|matches|-webkit-any|-moz-any)\(/u, s) ->
        [whole, name] = m

        with {inner, rest} <- balanced(drop(s, whole)),
             {:ok, cmps} <- compound_list(inner) do
          kind =
            case name,
              do: (
                "not" -> :not
                "where" -> :where
                _ -> :is
              )

          tokenize(rest, [{:fn, kind, cmps} | acc])
        else
          _ -> :error
        end

      m = Regex.run(~r/\A:(nth-child|nth-last-child|nth-of-type)\(\s*([^()]*?)\s*\)/u, s) ->
        [whole, name, arg] = m

        kind =
          case name,
            do: (
              "nth-child" -> :child
              "nth-last-child" -> :last_child
              _ -> :of_type
            )

        case nth(arg) do
          nil -> :error
          ab -> tokenize(drop(s, whole), [{:nth, kind, ab} | acc])
        end

      m = Regex.run(~r/\A:([a-z-]+)(?![\w\-(])/u, s) ->
        [whole, name] = m

        case pseudo_class(name) do
          nil -> :error
          p -> tokenize(drop(s, whole), [{:pseudo, p} | acc])
        end

      m = Regex.run(~r/\A(#{@ident})/u, s) ->
        [whole, tag] = m
        tokenize(drop(s, whole), [{:tag, tag |> unescape() |> String.downcase()} | acc])

      true ->
        :error
    end
  end

  defp drop(s, prefix), do: binary_part(s, byte_size(prefix), byte_size(s) - byte_size(prefix))

  @never ~w(hover focus focus-within focus-visible active visited target indeterminate)
  @simple ~w(root empty first-child last-child only-child first-of-type link any-link disabled enabled checked)

  defp pseudo_class(name) when name in @never, do: :never

  defp pseudo_class(name) when name in @simple,
    do: name |> String.replace("-", "_") |> String.to_atom()

  defp pseudo_class(_), do: nil

  # `rest` follows an opening paren: -> {inside, after_closing_paren} | :error
  defp balanced(rest), do: balanced(rest, rest, 1, 0)
  defp balanced(<<>>, _w, _d, _n), do: :error
  defp balanced(<<?(, r::binary>>, w, d, n), do: balanced(r, w, d + 1, n + 1)

  defp balanced(<<?), r::binary>>, w, d, n) do
    if d == 1, do: {binary_part(w, 0, n), r}, else: balanced(r, w, d - 1, n + 1)
  end

  defp balanced(<<_, r::binary>>, w, d, n), do: balanced(r, w, d, n + 1)

  # comma-separated compound selectors (no combinators) as used in :is()/:not()
  defp compound_list(inner) do
    inner
    |> String.split(~r/,(?![^()]*\))/)
    |> Enum.reduce_while({:ok, []}, fn part, {:ok, acc} ->
      with {:ok, toks} <- tokenize(String.trim(part), []),
           true <- Enum.all?(toks, &(not match?({:comb, _}, &1))),
           {:ok, cmp} <- compound(toks) do
        {:cont, {:ok, [cmp | acc]}}
      else
        _ -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, list} -> {:ok, Enum.reverse(list)}
      :error -> :error
    end
  end

  # an+b -> {a, b}
  defp nth(arg) do
    arg = String.downcase(arg)

    cond do
      arg == "odd" ->
        {2, 1}

      arg == "even" ->
        {2, 0}

      m = Regex.run(~r/\A([+-]?\d*)n\s*(?:([+-])\s*(\d+))?\z/, arg) ->
        [_, coef | rest] = m

        a =
          case coef,
            do: (
              "" -> 1
              "+" -> 1
              "-" -> -1
              c -> String.to_integer(c)
            )

        b =
          case rest do
            [sign, n] when n != "" ->
              if sign == "-", do: -String.to_integer(n), else: String.to_integer(n)

            _ ->
              0
          end

        {a, b}

      Regex.match?(~r/\A[+-]?\d+\z/, arg) ->
        {0, String.to_integer(String.trim_leading(arg, "+"))}

      true ->
        nil
    end
  end

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
      {:fn, _, _} = f, {:ok, c} -> {:cont, {:ok, %{c | pseudos: [f | c.pseudos]}}}
      {:nth, _, _} = n, {:ok, c} -> {:cont, {:ok, %{c | pseudos: [n | c.pseudos]}}}
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
      {:fn, :where, _}, acc -> acc
      {:fn, _, cmps}, acc -> add_spec(acc, cmps |> Enum.map(&compound_spec/1) |> Enum.max())
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
  defp pseudo?(:never, _ctx), do: false
  defp pseudo?(:empty, ctx), do: ctx.empty?
  defp pseudo?(:first_of_type, ctx), do: not Enum.any?(ctx.prev, &(&1.tag == ctx.tag))

  defp pseudo?(link, ctx) when link in [:link, :any_link],
    do: ctx.tag in ["a", "area"] and List.keymember?(ctx.attrs, "href", 0)

  defp pseudo?(:disabled, ctx), do: List.keymember?(ctx.attrs, "disabled", 0)

  defp pseudo?(:checked, ctx),
    do: List.keymember?(ctx.attrs, "checked", 0) or List.keymember?(ctx.attrs, "selected", 0)

  defp pseudo?(:enabled, ctx), do: not List.keymember?(ctx.attrs, "disabled", 0)
  defp pseudo?({:fn, :not, cmps}, ctx), do: not Enum.any?(cmps, &match_compound(&1, ctx))
  defp pseudo?({:fn, _, cmps}, ctx), do: Enum.any?(cmps, &match_compound(&1, ctx))
  defp pseudo?({:nth, kind, {a, b}}, ctx), do: nth_match?(a, b, position(kind, ctx))

  defp position(:child, ctx), do: ctx.index
  defp position(:last_child, ctx), do: ctx.count - ctx.index + 1
  defp position(:of_type, ctx), do: 1 + Enum.count(ctx.prev, &(&1.tag == ctx.tag))

  # does some n >= 0 satisfy a*n + b == pos?
  defp nth_match?(0, b, pos), do: pos == b
  defp nth_match?(a, b, pos), do: rem(pos - b, a) == 0 and div(pos - b, a) >= 0
end
