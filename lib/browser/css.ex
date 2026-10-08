defmodule Browser.CSS do
  @moduledoc """
  A small CSS parser and selector matcher.

  Supported: type/universal, `#id`, `.class`, attribute selectors (`=`, `~=`,
  `|=`, `^=`, `$=`, `*=`, `i` flag), the descendant/child/next-sibling/
  subsequent-sibling combinators, and these pseudo-classes: `:root`, `:empty`,
  `:first-child`, `:last-child`, `:only-child`, `:first-of-type`, `:nth-child()`,
  `:nth-last-child()`, `:nth-of-type()`, `:modal`, `:open`, `::backdrop`, `:link`, `:disabled`, `:enabled`, `:checked` (as the page was written), and
  `:not()`/`:is()`/`:where()` over lists of compound selectors. State-dependent
  pseudo-classes (`:hover`, `:focus`, `:visited`, …) never match, which keeps
  `:not(:focus)` true.

  A selector may end in `::before`, `::after` (or the one-colon forms), `::marker` or
  `::placeholder`: its rule styles the generated box, marker or hint, and carries
  `pseudo: :before | :after | :marker | :placeholder` (nil for other rules).
  Selectors using anything else (`:has()`, …) are dropped. `@media` (see
  `Browser.MediaQuery`), `@supports` (assumed true unless it starts with `not`)
  and `@layer` blocks are entered (a rule carries its `layer`, nil when it is in none, for the
  cascade); other at-rules (`@import`, `@font-face`,
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
        %{
          selector: parts,
          specificity: spec,
          decls: decls,
          media: Enum.reject(conds, &match?({:layer, _}, &1)),
          layer: layer_path(conds),
          pseudo: pseudo
        }
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
      with false <- String.contains?(piece, "{") and not var_reference?(piece),
           [prop, value] <- :binary.split(piece, ":"),
           prop = prop |> String.trim() |> fold_prop(),
           true <- prop not in ["", "--"] do
        {value, important?} = split_important(String.trim(value))

        if valid_value?(prop, value) and not Regex.match?(~r/!\s*important/i, value),
          do: [{prop, value, important?}],
          else: []
      else
        _ -> []
      end
    end)
  end

  defp var_reference?(piece), do: Regex.match?(~r/var\(/i, piece)

  # custom property names are case-sensitive, everything else is not
  defp fold_prop(prop) do
    case if(String.starts_with?(prop, "-"), do: unescape(prop), else: prop) do
      "--" <> _ = custom -> custom
      _ -> String.downcase(prop)
    end
  end

  # a declaration whose value is not allowed is dropped, so the one before it still applies
  defp valid_value?("tab-size", value),
    do: Regex.match?(~r/\A(\d+\.?\d*|\.\d+)(px|em|rem|pt|ch|ex)?\z/, value)

  defp valid_value?(prop, value) do
    (not var_reference?(value) or var_references_valid?(value)) and
      (not String.starts_with?(prop, "--") or balanced?(value))
  end

  defp split_important(value) do
    case Regex.run(~r/\A(.*?)\s*!\s*important\s*\z/is, value, capture: :all_but_first) do
      [v] -> {String.trim(v), true}
      nil -> {value, false}
    end
  end

  # a comment left open at the end of the input runs to the end
  defp strip_comments(css), do: Regex.replace(~r{/\*(?:.*?\*/|.*\z)}s, css, " ")

  # no closing bracket without its opener (strings and escapes aside)
  defp balanced?(value), do: balanced?(value, [])
  defp balanced?(<<>>, stack), do: stack == []
  defp balanced?(<<?\\, _, r::binary>>, stack), do: balanced?(r, stack)

  defp balanced?(<<q, r::binary>>, stack) when q in [?", ?'] do
    case :binary.split(r, <<q>>) do
      [_, rest] -> balanced?(rest, stack)
      _ -> false
    end
  end

  defp balanced?(<<c, r::binary>>, stack) when c in [?(, ?[, ?{],
    do: balanced?(r, [c | stack])

  defp balanced?(<<c, r::binary>>, [o | stack])
       when (c == ?) and o == ?() or (c == ?] and o == ?[) or (c == ?} and o == ?{),
       do: balanced?(r, stack)

  defp balanced?(<<c, _::binary>>, _stack) when c in [?), ?], ?}], do: false
  defp balanced?(<<_, r::binary>>, stack), do: balanced?(r, stack)

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

      # the HTML comment tokens between rules are ignored
      "<!--" <> rest ->
        blocks(rest, conds, acc)

      "-->" <> rest ->
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
    case prelude_end(bin) do
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
              "supports" -> if supports?(prelude), do: blocks(body, conds, []), else: []
              "layer" -> blocks(body, conds ++ [{:layer, layer_name(prelude)}], [])
              _ -> []
            end

          {Enum.reverse(inner) ++ acc, rest}
        end
    end
  end

  # the name of a `@layer` block; an unnamed one is a layer of its own
  defp layer_name(prelude) do
    case String.trim(prelude) do
      "" -> "(anonymous #{:erlang.unique_integer([:positive])})"
      name -> name
    end
  end

  # the layer a rule is in (nested layers are joined with a dot), nil for unlayered rules
  defp layer_path(conds) do
    case for {:layer, name} <- conds, do: name do
      [] -> nil
      names -> Enum.join(names, ".")
    end
  end

  # the `{` or `;` that ends an at-rule prelude: braces inside parentheses (`@supports (a: {b})`)
  # and strings belong to the prelude
  defp prelude_end(bin), do: prelude_end(bin, 0, 0, nil)
  defp prelude_end(<<>>, _n, _d, _q), do: :nomatch
  defp prelude_end(<<?\\, _, r::binary>>, n, d, q), do: prelude_end(r, n + 2, d, q)

  defp prelude_end(<<c, r::binary>>, n, d, q) when q != nil,
    do: prelude_end(r, n + 1, d, if(c == q, do: nil, else: q))

  defp prelude_end(<<c, r::binary>>, n, d, nil) when c in [?", ?'],
    do: prelude_end(r, n + 1, d, c)

  defp prelude_end(<<?(, r::binary>>, n, d, nil), do: prelude_end(r, n + 1, d + 1, nil)
  defp prelude_end(<<?), r::binary>>, n, d, nil), do: prelude_end(r, n + 1, max(d - 1, 0), nil)
  defp prelude_end(<<c, _::binary>>, n, 0, nil) when c in [?{, ?;], do: {n, 1}
  defp prelude_end(<<_, r::binary>>, n, d, nil), do: prelude_end(r, n + 1, d, nil)

  @doc """
  Evaluates an `@supports` condition: `not`, `and`, `or`, parenthesised declarations and
  `selector()`. A declaration is supported when its name is a valid property name and, if it uses
  `var()`, the reference is well formed; values are not checked beyond that.
  """
  def supports?(prelude) do
    prelude = String.trim(prelude)

    case Regex.run(~r/\Anot\s*(.*)\z/is, prelude) do
      [_, rest] ->
        not supports?(rest)

      nil ->
        case split_keyword(prelude, ["and", "or"]) do
          {:ok, op, parts} ->
            results = Enum.map(parts, &supports?/1)
            if op == "and", do: Enum.all?(results), else: Enum.any?(results)

          :none ->
            supports_term(prelude)
        end
    end
  end

  defp supports_term("(" <> _ = term) do
    term = String.trim_trailing(term)
    inner = term |> binary_part(1, byte_size(term) - 2) |> String.trim()

    cond do
      String.starts_with?(inner, "(") or Regex.match?(~r/\Anot[\s(]/i, inner) -> supports?(inner)
      true -> supports_declaration(inner)
    end
  end

  defp supports_term(term) do
    case Regex.run(~r/\Aselector\((.*)\)\z/is, term) do
      [_, sel] -> selector_supported?(sel)
      nil -> false
    end
  end

  @properties ~w(
            align-content align-items align-self all animation animation-delay animation-direction animation-duration
            animation-fill-mode animation-iteration-count animation-name animation-play-state animation-timing-function appearance aspect-ratio backdrop-filter
            backface-visibility background background-attachment background-blend-mode background-clip background-color background-image background-origin
            background-position background-position-x background-position-y background-repeat background-size block-size border border-block
            border-block-color border-block-end border-block-end-color border-block-end-style border-block-end-width border-block-start border-block-start-color border-block-start-style
            border-block-start-width border-block-style border-block-width border-bottom border-bottom-color border-bottom-left-radius border-bottom-right-radius border-bottom-style
            border-bottom-width border-collapse border-color border-end-end-radius border-end-start-radius border-image border-image-outset border-image-repeat
            border-image-slice border-image-source border-image-width border-inline border-inline-color border-inline-end border-inline-end-color border-inline-end-style
            border-inline-end-width border-inline-start border-inline-start-color border-inline-start-style border-inline-start-width border-inline-style border-inline-width border-left
            border-left-color border-left-style border-left-width border-radius border-right border-right-color border-right-style border-right-width
            border-spacing border-start-end-radius border-start-start-radius border-style border-top border-top-color border-top-left-radius border-top-right-radius
            border-top-style border-top-width border-width bottom box-decoration-break box-shadow box-sizing break-after
            break-before break-inside caption-side caret-color clear clip clip-path color
            color-scheme column-count column-fill column-gap column-rule column-rule-color column-rule-style column-rule-width
            column-span column-width columns contain contain-intrinsic-size container container-name container-type
            content content-visibility counter-increment counter-reset counter-set cursor direction display
            empty-cells filter flex flex-basis flex-direction flex-flow flex-grow flex-shrink
            flex-wrap float font font-family font-feature-settings font-kerning font-language-override font-optical-sizing
            font-size font-size-adjust font-stretch font-style font-synthesis font-variant font-variant-alternates font-variant-caps
            font-variant-east-asian font-variant-ligatures font-variant-numeric font-variant-position font-variation-settings font-weight gap grid
            grid-area grid-auto-columns grid-auto-flow grid-auto-rows grid-column grid-column-end grid-column-gap grid-column-start
            grid-gap grid-row grid-row-end grid-row-gap grid-row-start grid-template grid-template-areas grid-template-columns
            grid-template-rows hanging-punctuation height hyphenate-character hyphens image-orientation image-rendering inline-size inset
            inset-block inset-block-end inset-block-start inset-inline inset-inline-end inset-inline-start isolation justify-content
            justify-items justify-self left letter-spacing line-break line-height list-style list-style-image
            list-style-position list-style-type margin margin-block margin-block-end margin-block-start margin-bottom margin-inline
            margin-inline-end margin-inline-start margin-left margin-right margin-top margin-trim mask mask-clip
            mask-composite mask-image mask-mode mask-origin mask-position mask-repeat mask-size mask-type
            max-block-size max-height max-inline-size max-width min-block-size min-height min-inline-size min-width
            mix-blend-mode object-fit object-position offset opacity order orphans outline
            outline-color outline-offset outline-style outline-width overflow overflow-anchor overflow-wrap overflow-x
            overflow-y overscroll-behavior padding padding-block padding-block-end padding-block-start padding-bottom padding-inline
            padding-inline-end padding-inline-start padding-left padding-right padding-top page-break-after page-break-before page-break-inside
            paint-order perspective perspective-origin place-content place-items place-self pointer-events position
            quotes resize right rotate row-gap ruby-align ruby-position scale
            scroll-behavior scroll-margin scroll-padding scroll-snap-align scroll-snap-stop scroll-snap-type scrollbar-color scrollbar-gutter
            scrollbar-width shape-image-threshold shape-margin shape-outside tab-size table-layout text-align text-align-last
            text-combine-upright text-decoration text-decoration-color text-decoration-line text-decoration-skip-ink text-decoration-style text-decoration-thickness text-emphasis
            text-emphasis-color text-emphasis-position text-emphasis-style text-indent text-justify text-orientation text-overflow text-rendering
            text-shadow text-size-adjust text-transform text-underline-offset text-underline-position text-wrap top touch-action
            transform transform-box transform-origin transform-style transition transition-delay transition-duration transition-property
            transition-timing-function translate unicode-bidi user-select vertical-align visibility white-space widows
            width will-change word-break word-spacing word-space-transform word-wrap writing-mode z-index zoom
  )

  defp known_property?("-" <> rest = prop) do
    String.starts_with?(rest, ["webkit-", "moz-", "ms-", "o-"]) and
      Regex.match?(~r/\A-[a-z]+-[a-z][\w-]*\z/, prop)
  end

  defp known_property?(prop), do: String.downcase(prop) in @properties

  # pseudo-elements we don't style are still understood
  defp selector_supported?(sel) do
    sel = Regex.replace(~r/::[a-zA-Z-]+(\([^)]*\))?/, sel, "")
    match?({:ok, _}, parse_selector(if String.trim(sel) == "", do: "*", else: sel))
  end

  defp supports_declaration(decl) do
    case :binary.split(decl, ":") do
      [prop, value] ->
        prop = String.trim(prop)
        value = String.trim(value)

        cond do
          prop == "--" -> false
          String.starts_with?(prop, "--") -> balanced?(value) and supports_value?(value, true)
          not known_property?(prop) -> false
          value == "" -> false
          true -> supports_value?(value)
        end

      _ ->
        false
    end
  end

  # one `!important` is fine, anything else with `!` or a top-level `;` is not
  defp supports_value?(value, custom? \\ false) do
    {value, _} = split_important(value)

    not top_level_bang?(value) and var_references_valid?(value) and
      (custom? or balanced?(value))
  end

  # `var(` needs a name (a valid custom property name) and no top-level `!` or `;` in its fallback
  defp var_references_valid?(value) do
    Regex.scan(~r/var\(/i, value, return: :index)
    |> Enum.all?(fn [{pos, len}] ->
      rest = binary_part(value, pos + len, byte_size(value) - pos - len)
      {inner, _} = take_var(rest)

      case split_top(inner, ?,) do
        [name | fallback] ->
          String.trim(name) != "" and Enum.all?(fallback, &(not top_level_bang?(&1)))

        _ ->
          false
      end
    end)
  end

  defp top_level_bang?(s),
    do: s |> String.replace("<!--", "") |> flat_top() |> String.contains?(["!", ";"])

  # `s` with everything inside brackets and strings removed
  defp flat_top(s),
    do: Regex.replace(~r/\([^()]*\)|\[[^\[\]]*\]|\{[^{}]*\}|"[^"]*"|'[^']*'/, s, "")

  defp take_var(rest), do: take_var(rest, rest, 1, 0)
  defp take_var(<<>>, whole, _d, _n), do: {whole, ""}
  defp take_var(<<?(, r::binary>>, w, d, n), do: take_var(r, w, d + 1, n + 1)

  defp take_var(<<?), r::binary>>, w, d, n),
    do: if(d == 1, do: {binary_part(w, 0, n), r}, else: take_var(r, w, d - 1, n + 1))

  defp take_var(<<_, r::binary>>, w, d, n), do: take_var(r, w, d, n + 1)

  # splits at top-level whitespace-delimited `and` / `or`: {:ok, op, parts} | :none
  defp split_keyword(s, _words) do
    masked = mask_groups(s)

    case Regex.scan(~r/\s(and|or)\s/i, masked, return: :index) do
      [] ->
        :none

      found ->
        op = found |> hd() |> tl() |> hd() |> then(fn {i, l} -> binary_part(s, i, l) end)

        {parts, last} =
          Enum.reduce(found, {[], 0}, fn [{i, l}, _], {acc, from} ->
            {[binary_part(s, from, i - from) | acc], i + l}
          end)

        {:ok, String.downcase(op),
         Enum.reverse([binary_part(s, last, byte_size(s) - last) | parts])}
    end
  end

  # the same length as `s` with whatever sits inside brackets replaced by underscores
  defp mask_groups(s) do
    {out, _} =
      s
      |> :binary.bin_to_list()
      |> Enum.map_reduce(0, fn c, d ->
        cond do
          c == ?( -> {?_, d + 1}
          c == ?) -> {?_, max(d - 1, 0)}
          d > 0 -> {?_, d}
          true -> {c, d}
        end
      end)

    :erlang.list_to_binary(out)
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
    case Regex.run(
           ~r/\A(.*?)(?:::(before|after|marker|placeholder|backdrop)|:(before|after))\z/su,
           str
         ) do
      # a backdrop is a box of its own (see `Browser.Modal`) that only these rules match
      [_, head, "backdrop"] -> {head_or_any(head) <> ":mb-backdrop", nil}
      [_, head, which] -> {head_or_any(head), String.to_atom(which)}
      [_, head, "", which] -> {head_or_any(head), String.to_atom(which)}
      nil -> {str, nil}
    end
  end

  defp head_or_any(""), do: "*"
  defp head_or_any(head), do: head

  # an identifier: name characters and escapes (`\[`, `\:`, `\31 `), as in Tailwind's `.w-\[10px\]`
  @ident ~S"(?:[\w\-\x{80}-\x{10FFFF}]|\\(?:[0-9a-fA-F]{1,6}\s?|[^\n0-9a-fA-F]))+"

  @doc false
  def unescape(ident) do
    Regex.replace(~r/\\(?:([0-9a-fA-F]{1,6})\s?|(.))/su, ident, fn
      _, hex, "" -> code_point(String.to_integer(hex, 16))
      _, _, char -> char
    end)
  end

  # zero, surrogates and anything past U+10FFFF escape to the replacement character
  defp code_point(n) when n == 0 or n > 0x10FFFF or n in 0xD800..0xDFFF, do: "\uFFFD"
  defp code_point(n), do: <<n::utf8>>

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

      m = Regex.run(~r/\A#(?!\d|-\d)(#{@ident})/u, s) ->
        [whole, id] = m
        tokenize(drop(s, whole), [{:id, unescape(id)} | acc])

      m = Regex.run(~r/\A\.(?!\d|-\d)(#{@ident})/u, s) ->
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

      m = Regex.run(~r/\A:has\(/u, s) ->
        [whole] = m

        with {inner, rest} <- balanced(drop(s, whole)),
             {:ok, rels} <- relative_list(inner) do
          tokenize(rest, [{:has, rels} | acc])
        else
          _ -> :error
        end

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

      m = Regex.run(~r/\A:(nth-child|nth-last-child|nth-of-type|nth-last-of-type)\(/u, s) ->
        [whole, name] = m

        kind =
          case name,
            do: (
              "nth-child" -> :child
              "nth-last-child" -> :last_child
              "nth-last-of-type" -> :last_of_type
              _ -> :of_type
            )

        with {inner, rest} <- balanced(drop(s, whole)),
             {arg, of_sels} <- split_of(inner, kind),
             ab when ab != nil <- nth(arg),
             {:ok, sels} <- of_selectors(of_sels) do
          token = if sels == nil, do: {:nth, kind, ab}, else: {:nth_of, kind, ab, sels}
          tokenize(rest, [token | acc])
        else
          _ -> :error
        end

      m = Regex.run(~r/\A:(lang|dir)\(/u, s) ->
        [whole, name] = m

        with {inner, rest} <- balanced(drop(s, whole)),
             {:ok, p} <- lang_dir(name, inner) do
          tokenize(rest, [{:pseudo, p} | acc])
        else
          _ -> :error
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

  # `2n+1 of .a, b > c` -> {"2n+1", ".a, b > c"}; the `of` part is only for the child kinds
  defp split_of(inner, kind) do
    case Regex.run(~r/\A(.*?)\s+of(?=[\s\[.#:*]|[\w\-])\s*(.*)\z/su, inner) do
      [_, arg, sels] when kind not in [:of_type, :last_of_type] and sels != "" ->
        {String.trim(arg), sels}

      [_, _, _] ->
        :error

      nil ->
        {String.trim(inner), nil}
    end
  end

  defp of_selectors(nil), do: {:ok, nil}

  defp of_selectors(str) do
    # no namespaces here: `*|*` is the same as `*`
    str
    |> String.replace("*|", "")
    |> split_top(?,)
    |> Enum.reduce_while({:ok, []}, fn part, {:ok, acc} ->
      case parse_selector(part) do
        {:ok, %{parts: parts, pseudo: nil}} -> {:cont, {:ok, [parts | acc]}}
        _ -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, list} -> {:ok, Enum.reverse(list)}
      :error -> :error
    end
  end

  defp lang_dir("dir", inner) do
    case inner |> String.trim() |> String.downcase() do
      d when d in ["ltr", "rtl"] -> {:ok, {:dir, d}}
      _ -> :error
    end
  end

  defp lang_dir("lang", inner) do
    ranges =
      inner
      |> split_top(?,)
      |> Enum.map(fn r ->
        r
        |> String.trim()
        |> String.trim("\"")
        |> String.trim("'")
        |> String.replace(~r/\\(.)/, "\\1")
        |> String.downcase()
      end)

    # an unquoted range is an identifier, which cannot start with a digit
    valid? = fn r -> r != "" and (quoted?(inner, r) or not String.match?(r, ~r/\A-?\d/)) end

    if ranges != [] and Enum.all?(ranges, valid?),
      do: {:ok, {:lang, ranges}},
      else: :error
  end

  defp quoted?(inner, range), do: String.contains?(inner, ["\"" <> range, "'" <> range])

  defp drop(s, prefix), do: binary_part(s, byte_size(prefix), byte_size(s) - byte_size(prefix))

  @never ~w(hover focus focus-within focus-visible active visited target indeterminate)
  @simple ~w(root scope empty first-child last-child only-child first-of-type last-of-type only-of-type link any-link disabled enabled checked modal open mb-backdrop popover-open)

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

  # the argument of :has(): comma-separated relative selectors (`> a`, `+ b c`, `d`) as
  # `[{combinator_to_the_anchor, parts}]`. One that needs a state we don't track (`a:hover`)
  # can never match and is left out.
  defp relative_list(inner) do
    inner
    |> split_top(?,)
    |> Enum.reduce_while({:ok, []}, fn part, {:ok, acc} ->
      part = String.trim(part)

      {lead, body} =
        case Regex.run(~r/\A([>+~])\s*(.*)\z/su, part) do
          [_, c, rest] -> {comb(c), rest}
          nil -> {:descendant, part}
        end

      with {:ok, toks} <- tokenize(body, []),
           {:ok, parts} <- group(toks) do
        if Enum.any?(parts, fn {c, _} -> :never in c.pseudos end),
          do: {:cont, {:ok, acc}},
          else: {:cont, {:ok, acc ++ [{lead, parts}]}}
      else
        _ -> {:halt, :error}
      end
    end)
  end

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
      {:has, _} = h, {:ok, c} -> {:cont, {:ok, %{c | pseudos: [h | c.pseudos]}}}
      {:nth, _, _} = n, {:ok, c} -> {:cont, {:ok, %{c | pseudos: [n | c.pseudos]}}}
      {:nth_of, _, _, _} = n, {:ok, c} -> {:cont, {:ok, %{c | pseudos: [n | c.pseudos]}}}
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
      {:fn, :where, _}, acc ->
        acc

      {:fn, _, cmps}, acc ->
        add_spec(acc, cmps |> Enum.map(&compound_spec/1) |> Enum.max())

      {:nth_of, _, _, sels}, {a, b, t} ->
        add_spec({a, b + 1, t}, sels |> Enum.map(&specificity/1) |> Enum.max())

      {:has, []}, acc ->
        acc

      {:has, rels}, acc ->
        add_spec(acc, rels |> Enum.map(fn {_, parts} -> specificity(parts) end) |> Enum.max())

      _, {a, b, t} ->
        {a, b + 1, t}
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
    # the backdrop of a dialog is only styled by its own rules, not by those for the dialog
    (:mb_backdrop in c.pseudos or not List.keymember?(ctx.attrs, "@backdrop", 0)) and
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

  defp pseudo?(:scope, ctx), do: pseudo?(:root, ctx)
  defp pseudo?({:dir, d}, ctx), do: direction(ctx) == d

  defp pseudo?({:lang, ranges}, ctx) do
    case language(ctx) do
      nil -> false
      lang -> Enum.any?(ranges, &lang_match?(&1, String.downcase(lang)))
    end
  end

  defp pseudo?(:root, ctx), do: ctx.parent == nil and ctx.tag == "html"
  defp pseudo?(:first_child, ctx), do: ctx.first?
  defp pseudo?(:last_child, ctx), do: ctx.last?
  defp pseudo?(:only_child, ctx), do: ctx.first? and ctx.last?
  defp pseudo?(:never, _ctx), do: false
  defp pseudo?(:empty, ctx), do: ctx.empty?
  defp pseudo?(:first_of_type, ctx), do: not Enum.any?(ctx.prev, &(&1.tag == ctx.tag))
  defp pseudo?(:last_of_type, ctx), do: later_of_type(ctx) == 0
  defp pseudo?(:only_of_type, ctx), do: pseudo?(:first_of_type, ctx) and later_of_type(ctx) == 0

  defp pseudo?(link, ctx) when link in [:link, :any_link],
    do: ctx.tag in ["a", "area"] and List.keymember?(ctx.attrs, "href", 0)

  defp pseudo?(:modal, ctx), do: List.keymember?(ctx.attrs, "@modal", 0)
  defp pseudo?(:popover_open, ctx), do: List.keymember?(ctx.attrs, "@popover", 0)
  defp pseudo?(:mb_backdrop, ctx), do: List.keymember?(ctx.attrs, "@backdrop", 0)

  defp pseudo?(:open, ctx),
    do: ctx.tag in ["dialog", "details"] and List.keymember?(ctx.attrs, "open", 0)

  defp pseudo?(:disabled, ctx), do: List.keymember?(ctx.attrs, "disabled", 0)

  defp pseudo?(:checked, ctx),
    do: List.keymember?(ctx.attrs, "checked", 0) or List.keymember?(ctx.attrs, "selected", 0)

  defp pseudo?(:enabled, ctx), do: not List.keymember?(ctx.attrs, "disabled", 0)
  defp pseudo?({:anchor, key}, ctx), do: ctx.key == key
  defp pseudo?({:has, rels}, ctx), do: Enum.any?(rels, &has?(&1, ctx))
  defp pseudo?({:fn, :not, cmps}, ctx), do: not Enum.any?(cmps, &match_compound(&1, ctx))
  defp pseudo?({:fn, _, cmps}, ctx), do: Enum.any?(cmps, &match_compound(&1, ctx))
  defp pseudo?({:nth, kind, {a, b}}, ctx), do: nth_match?(a, b, position(kind, ctx))

  # `:nth-child(an+b of S)`: the element matches S and counts among the siblings that do
  defp pseudo?({:nth_of, kind, {a, b}, sels}, ctx) do
    in_list? = fn c -> Enum.any?(sels, &matches?(&1, c)) end

    in_list?.(ctx) and
      case kind do
        :child -> nth_match?(a, b, 1 + Enum.count(ctx.prev, in_list?))
        :last_child -> nth_match?(a, b, 1 + Enum.count(next_contexts(ctx), in_list?))
      end
  end

  # `:has(lead parts)`: some element the relative selector reaches from `ctx`. The selector is
  # matched as `parts` with `ctx` itself (an :anchor) at its left end, joined by `lead`.
  defp has?({lead, parts}, ctx) do
    anchor = {%{tag: nil, id: nil, classes: [], attrs: [], pseudos: [{:anchor, ctx.key}]}, nil}
    {rest, [{leftmost, nil}]} = Enum.split(parts, -1)
    parts = rest ++ [{leftmost, lead}, anchor]

    ctx
    |> reachable(lead)
    |> Enum.any?(&match_parts(parts, &1))
  end

  # the elements a `:has()` selector may match: below `ctx`, or after it (and below those)
  defp reachable(ctx, lead) when lead in [:descendant, :child], do: descendants(ctx)

  defp reachable(ctx, _lead) do
    Stream.flat_map(next_contexts(ctx), fn sibling ->
      Stream.concat([sibling], descendants(sibling))
    end)
  end

  defp descendants(ctx) do
    Stream.flat_map(child_contexts(ctx), fn child ->
      Stream.concat([child], descendants(child))
    end)
  end

  defp child_contexts(ctx) do
    count = Enum.count(ctx.kids, &match?({:element, _, _, _}, &1))
    contexts(ctx.kids, ctx, [], 0, count)
  end

  defp next_contexts(%{next: rest} = ctx) do
    count = ctx.count
    contexts(rest, ctx.parent, [ctx | ctx.prev], ctx.index, count)
  end

  # the contexts of the elements in `nodes`, lazily
  defp contexts(nodes, parent, prev, i, count) do
    Stream.unfold({nodes, prev, i}, fn
      {[], _, _} ->
        nil

      {[{:text, _} | rest], prev, i} ->
        {nil, {rest, prev, i}}

      {[{:element, tag, attrs, kids} | rest], prev, i} ->
        ctx = context(tag, attrs, kids, parent, prev, i, count, rest)
        {ctx, {rest, [ctx | prev], i + 1}}
    end)
    |> Stream.reject(&is_nil/1)
  end

  @doc """
  The element context (see above) of an element with `kids`, `rest` being the nodes after it
  among its siblings. `prev` are the contexts of the elements before it, nearest first, `i` its
  0-based position among the elements and `count` how many elements there are in all.
  """
  def context(tag, attrs, kids, parent, prev, i, count, rest) do
    %{
      tag: tag,
      attrs: attrs,
      id: attr_value(attrs, "id"),
      classes: attrs |> attr_value("class") |> Kernel.||("") |> String.split(),
      parent: parent,
      prev: prev,
      first?: i == 0,
      last?: i == count - 1,
      index: i + 1,
      count: count,
      empty?: kids == [],
      kids: kids,
      next: rest,
      key: {parent && parent.key, i}
    }
  end

  defp attr_value(attrs, name) do
    case List.keyfind(attrs, name, 0) do
      {_, v} -> v
      nil -> nil
    end
  end

  # the nearest `lang` (or `xml:lang`) of the element or its ancestors
  defp language(nil), do: nil

  defp language(ctx) do
    attr_value(ctx.attrs, "lang") || attr_value(ctx.attrs, "xml:lang") || language(ctx.parent)
  end

  # extended filtering (RFC 4647): `*` stands for any subtag, and a range may skip subtags of
  # the language tag, but not past a singleton such as `x`
  defp lang_match?(range, lang) do
    case {String.split(range, "-"), String.split(lang, "-")} do
      {["*" | rs], [t | ts]} when t != "" -> lang_subtags(rs, ts)
      {[r | rs], [r | ts]} -> lang_subtags(rs, ts)
      _ -> false
    end
  end

  defp lang_subtags([], _), do: true
  defp lang_subtags(["*" | rs], ts), do: lang_subtags(rs, ts)
  defp lang_subtags(_, []), do: false
  defp lang_subtags([r | rs], [r | ts]), do: lang_subtags(rs, ts)
  defp lang_subtags(_, [t | _]) when byte_size(t) == 1, do: false
  defp lang_subtags(rs, [_ | ts]), do: lang_subtags(rs, ts)

  defp direction(nil), do: "ltr"

  defp direction(ctx) do
    case attr_value(ctx.attrs, "dir") do
      d when is_binary(d) ->
        case String.downcase(d) do
          x when x in ["ltr", "rtl"] -> x
          _ -> direction(ctx.parent)
        end

      _ ->
        direction(ctx.parent)
    end
  end

  defp position(:child, ctx), do: ctx.index
  defp position(:last_child, ctx), do: ctx.count - ctx.index + 1
  defp position(:of_type, ctx), do: 1 + Enum.count(ctx.prev, &(&1.tag == ctx.tag))
  defp position(:last_of_type, ctx), do: 1 + later_of_type(ctx)

  # how many elements of the same type follow this one
  defp later_of_type(ctx),
    do:
      Enum.count(Map.get(ctx, :next, []), &match?({:element, tag, _, _} when tag == ctx.tag, &1))

  # does some n >= 0 satisfy a*n + b == pos?
  defp nth_match?(0, b, pos), do: pos == b
  defp nth_match?(a, b, pos), do: rem(pos - b, a) == 0 and div(pos - b, a) >= 0
end
