defmodule Browser.HTML do
  @moduledoc """
  Tolerant HTML tokenizer and tree builder. Not spec-compliant: it handles
  void elements, a few implied end tags, comments, raw-text elements and
  common entities.

  Nodes are `{:text, binary}` or `{:element, tag, attrs, children}`.
  """

  @void ~w(area base br col embed hr img input link meta param source track wbr)
  @raw_text ~w(script style)
  @block ~w(p div ul ol li h1 h2 h3 h4 h5 h6 pre blockquote table tr hr dl dt dd
            section article header footer nav main form)
  @closes_p @block ++
              ~w(address aside center details dialog dir fieldset figcaption figure hgroup menu
                 search)

  # the full WHATWG named character reference table (priv/html_entities.txt); keys keep their
  # trailing ";", and the legacy names that may omit it are present without one too
  @entities_path Path.expand("../../priv/html_entities.txt", __DIR__)
  @external_resource @entities_path
  @entities @entities_path
            |> File.read!()
            |> String.split("\n", trim: true)
            |> Map.new(fn line ->
              [name, cps] = String.split(line, "\t")

              {name,
               cps
               |> String.split(" ")
               |> Enum.map(&String.to_integer(&1, 16))
               |> List.to_string()}
            end)

  @spec parse(binary) :: [term]
  def parse(html, opts \\ []) when is_binary(html) do
    # (`comments: true` keeps comments as `{:comment, text}`: scripts see them in the DOM;
    # layout never does)
    old = Process.put(:html_comments, opts[:comments] == true)

    try do
      html |> tokenize([]) |> build([{:root, []}])
    after
      Process.put(:html_comments, old || false)
    end
  end

  @doc "Parses a whole page: `parse/1` plus the html, head and body elements it leaves implied."
  @spec parse_document(binary, keyword) :: [term]
  def parse_document(html, opts \\ []) when is_binary(html) do
    nodes = html |> parse() |> implied_structure()
    # (XML documents keep the newline after a start tag, HTML ones drop it)
    if opts[:xml], do: nodes, else: drop_first_newlines(nodes)
  end

  # a newline right after the start tag of pre, listing or textarea is not part of its text
  defp drop_first_newlines(nodes) when is_list(nodes), do: Enum.map(nodes, &drop_first_newlines/1)

  defp drop_first_newlines({:element, name, attrs, [{:text, "\n" <> t} | kids]})
       when name in ["pre", "listing", "textarea"] do
    kids = if t == "", do: kids, else: [{:text, t} | kids]
    {:element, name, attrs, drop_first_newlines(kids)}
  end

  defp drop_first_newlines({:element, name, attrs, kids}),
    do: {:element, name, attrs, drop_first_newlines(kids)}

  defp drop_first_newlines(other), do: other

  # What HTML parsing makes of a document without `<html>`, `<head>` or `<body>` tags: the
  # leading title, meta, link, style, script... go in the head and the rest in the body (which
  # is where the body's default margin comes from).
  @head_tags ~w(title meta link style script base noscript template)

  defp implied_structure(nodes) do
    if Enum.any?(nodes, &match?({:element, n, _, _} when n in ["frameset"], &1)) do
      nodes
    else
      case Enum.split_with(nodes, &match?({:element, "html", _, _}, &1)) do
        {[{:element, "html", attrs, kids} | _], others} ->
          [{:element, "html", attrs, with_body(kids)} | others]

        {[], _} ->
          if Enum.any?(nodes, &match?({:element, "body", _, _}, &1)),
            do: [{:element, "html", [], nodes}],
            else: [{:element, "html", [], with_body(nodes)}]
      end
    end
  end

  defp with_body(kids) do
    if Enum.any?(kids, &match?({:element, "body", _, _}, &1)) do
      kids
    else
      {head, rest} = Enum.split_while(kids, &head_node?/1)

      case Enum.find(head, &match?({:element, "head", _, _}, &1)) do
        nil -> [{:element, "head", [], head}, {:element, "body", [], rest}]
        _ -> head ++ [{:element, "body", [], rest}]
      end
    end
  end

  defp head_node?({:element, name, _, _}), do: name in @head_tags or name == "head"
  defp head_node?({:text, t}), do: String.trim(t) == ""

  # -- tokenizer ---------------------------------------------------------

  defp keep_comment(text, acc),
    do: if(Process.get(:html_comments), do: [{:comment, text} | acc], else: acc)

  defp tokenize("", acc), do: Enum.reverse(acc)

  defp tokenize("<!--" <> rest, acc) do
    case :binary.split(rest, "-->") do
      [text, after_c] -> tokenize(after_c, keep_comment(text, acc))
      [_] -> Enum.reverse(acc)
    end
  end

  defp tokenize("<!" <> rest, acc), do: tokenize(skip_past(rest, ">"), acc)

  # (`<?...>` is a comment whose text starts with `?`)
  defp tokenize("<?" <> rest, acc) do
    case :binary.split(rest, ">") do
      [text, after_c] -> tokenize(after_c, keep_comment("?" <> text, acc))
      [_] -> Enum.reverse(acc)
    end
  end

  defp tokenize("</" <> rest, acc) do
    {name, rest} = take_name(rest)
    tokenize(skip_past(rest, ">"), [{:close, name} | acc])
  end

  defp tokenize(<<"<", c, _::binary>> = "<" <> rest, acc) when c in ?a..?z or c in ?A..?Z do
    {name, rest} = take_name(rest)
    {attrs, self_close?, rest} = take_attrs(rest, [])

    if name in @raw_text and not self_close? do
      {raw, rest} = take_raw(rest, name)
      tokenize(rest, [{:close, name} | add_raw(name, raw, [{:open, name, attrs, false} | acc])])
    else
      tokenize(rest, [{:open, name, attrs, self_close?} | acc])
    end
  end

  defp tokenize(bin, acc) do
    # text up to next "<" (a literal "<" not starting a tag is consumed as text)
    {text, rest} =
      case :binary.match(bin, "<",
             scope: {min(1, byte_size(bin)), byte_size(bin) - min(1, byte_size(bin))}
           ) do
        {pos, _} -> {binary_part(bin, 0, pos), binary_part(bin, pos, byte_size(bin) - pos)}
        :nomatch -> {bin, ""}
      end

    tokenize(rest, [{:text, decode(text)} | acc])
  end

  # style text is kept (undecoded) for the CSS engine, script text for the page's scripts; the
  # CDATA markers XHTML pages wrap their styles in are dropped, or the first rule would be lost
  defp add_raw("style", raw, acc) when raw != "",
    do: [{:text, String.replace(raw, ["<![CDATA[", "]]>"], "")} | acc]

  defp add_raw("script", raw, acc) when raw != "", do: [{:text, raw} | acc]

  defp add_raw(_name, _raw, acc), do: acc

  defp take_raw(bin, name) do
    case Regex.run(~r/<\/#{name}\s*>/i, bin, return: :index) do
      [{pos, len}] ->
        {binary_part(bin, 0, pos), binary_part(bin, pos + len, byte_size(bin) - pos - len)}

      nil ->
        {bin, ""}
    end
  end

  defp skip_past(bin, delim) do
    case :binary.split(bin, delim) do
      [_, rest] -> rest
      [_] -> ""
    end
  end

  defp take_name(bin) do
    n = name_len(bin, 0, false)
    {down(binary_part(bin, 0, n)), binary_part(bin, n, byte_size(bin) - n)}
  end

  # how many bytes before white space, `/` or `>` (and `=` for an attribute name)
  defp name_len(<<c, _::binary>>, n, _eq) when c in [?\s, ?\t, ?\n, ?\r, ?\f, 11, ?/, ?>], do: n
  defp name_len(<<?=, _::binary>>, n, true) when n > 0, do: n
  defp name_len(<<_, rest::binary>>, n, eq), do: name_len(rest, n + 1, eq)
  defp name_len(<<>>, n, _eq), do: n

  # tag and attribute names are nearly always plain lower case ASCII already
  defp down(s), do: if(plain_lower?(s), do: s, else: String.downcase(s))

  defp plain_lower?(<<c, rest::binary>>) when c < 128 and c not in ?A..?Z, do: plain_lower?(rest)
  defp plain_lower?(<<>>), do: true
  defp plain_lower?(_), do: false

  defp take_attrs(bin, acc) do
    bin = String.trim_leading(bin)

    case bin do
      "" ->
        {Enum.reverse(acc), false, ""}

      ">" <> rest ->
        {Enum.reverse(acc), false, rest}

      "/>" <> rest ->
        {Enum.reverse(acc), true, rest}

      "/" <> rest ->
        take_attrs(rest, acc)

      _ ->
        n = name_len(bin, 0, true)
        name = binary_part(bin, 0, n)
        rest = binary_part(bin, n, byte_size(bin) - n)
        {value, rest} = take_value(String.trim_leading(rest))
        take_attrs(rest, [{down(name), value} | acc])
    end
  end

  defp take_value("=" <> rest) do
    case String.trim_leading(rest) do
      "\"" <> r ->
        split_quoted(r, "\"")

      "'" <> r ->
        split_quoted(r, "'")

      r ->
        [v] = Regex.run(~r/\A[^\s>]*/, r)
        {decode(v), binary_part(r, byte_size(v), byte_size(r) - byte_size(v))}
    end
  end

  defp take_value(rest), do: {"", rest}

  defp split_quoted(bin, q) do
    case :binary.split(bin, q) do
      [v, rest] -> {decode(v), rest}
      [v] -> {decode(v), ""}
    end
  end

  # -- entities ----------------------------------------------------------

  def decode(text) do
    if String.contains?(text, "&"), do: do_decode(text), else: text
  end

  defp do_decode(text) do
    Regex.replace(~r/&(#[xX][0-9a-fA-F]+;?|#\d+;?|[a-zA-Z][a-zA-Z0-9]*;?)/, text, fn whole, ent ->
      case ent do
        "#" <> _ = num -> numeric(String.trim_trailing(num, ";"), whole)
        name -> Map.get(@entities, name, whole)
      end
    end)
  end

  defp numeric(<<"#", x, hex::binary>>, whole) when x in [?x, ?X], do: codepoint(hex, 16, whole)
  defp numeric("#" <> dec, whole), do: codepoint(dec, 10, whole)

  defp codepoint(str, base, fallback) do
    <<String.to_integer(str, base)::utf8>>
  rescue
    _ -> fallback
  end

  # -- tree builder ------------------------------------------------------
  # stack: list of {tag, reversed_children}; bottom is {:root, _}

  defp build([], stack), do: stack |> close_all() |> Enum.reverse()

  defp build([{:text, t} | rest], [{tag, kids} | stack]),
    do: build(rest, [{tag, [{:text, t} | kids]} | stack])

  defp build([{:comment, t} | rest], [{tag, kids} | stack]),
    do: build(rest, [{tag, [{:comment, t} | kids]} | stack])

  defp build([{:open, name, attrs, self_close?} | rest], stack) do
    stack = implied_close(name, stack)

    if name in @void or self_close? do
      [{tag, kids} | stack] = stack
      build(rest, [{tag, [{:element, name, attrs, []} | kids]} | stack])
    else
      build(rest, [{{name, attrs}, []} | stack])
    end
  end

  defp build([{:close, name} | rest], stack) do
    if Enum.any?(stack, &match?({{^name, _}, _}, &1)) do
      build(rest, pop_until(stack, name))
    else
      build(rest, stack)
    end
  end

  defp pop_until([{{name, attrs}, kids}, {ptag, pkids} | stack], name),
    do: [{ptag, [{:element, name, attrs, Enum.reverse(kids)} | pkids]} | stack]

  defp pop_until([{{name, attrs}, kids}, {ptag, pkids} | stack], other) do
    pop_until([{ptag, [{:element, name, attrs, Enum.reverse(kids)} | pkids]} | stack], other)
  end

  defp close_all([{:root, kids}]), do: kids
  defp close_all([{{name, _}, _} | _] = stack), do: stack |> pop_until(name) |> close_all()

  defp implied_close("li", stack), do: close_nearest(stack, "li", ~w(ul ol))

  # table parts end the ones before them (`<td>a<td>b`, `<tr>..<tr>`), inside the same table
  defp implied_close(name, stack) when name in ["td", "th"],
    do: close_within(stack, ["td", "th"], "table")

  defp implied_close("tr", stack) do
    stack
    |> close_within(["td", "th", "tr"], "table")
    |> close_nearest("p", [])
  end

  defp implied_close(name, stack) when name in ["thead", "tbody", "tfoot"],
    do: close_within(stack, ["td", "th", "tr", "thead", "tbody", "tfoot"], "table")

  defp implied_close(name, stack) when name in ["dt", "dd"],
    do: close_nearest(stack, name, ~w(dl))

  defp implied_close(name, stack) when name in @closes_p, do: close_nearest(stack, "p", [])
  defp implied_close(_, stack), do: stack

  # closes the outermost open element named in `targets`, if there is one before `barrier`
  defp close_within(stack, targets, barrier) do
    names =
      Enum.map(stack, fn
        {{name, _}, _} -> name
        {:root, _} -> :root
      end)

    inside = Enum.take_while(names, &(&1 != barrier and &1 != :root))

    case Enum.filter(inside, &(&1 in targets)) do
      [] -> stack
      found -> pop_until(stack, List.last(found))
    end
  end

  # close an open `target` only if it's the current element or separated by
  # inline elements (i.e. not past a `barrier` list container)
  defp close_nearest([{{target, _}, _} | _] = stack, target, _), do: pop_until(stack, target)

  defp close_nearest([{{name, _}, _} | _] = stack, target, barriers)
       when name not in @block do
    if name in barriers do
      stack
    else
      case Enum.find_index(stack, &match?({{^target, _}, _}, &1)) do
        nil ->
          stack

        idx ->
          between = stack |> Enum.take(idx) |> Enum.map(fn {{n, _}, _} -> n end)
          if Enum.all?(between, &(&1 not in @block)), do: pop_until(stack, target), else: stack
      end
    end
  end

  defp close_nearest(stack, _, _), do: stack
end
