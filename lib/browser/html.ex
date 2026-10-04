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
  @closes_p @block

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
  def parse(html) when is_binary(html) do
    html |> tokenize([]) |> build([{:root, []}])
  end

  # -- tokenizer ---------------------------------------------------------

  defp tokenize("", acc), do: Enum.reverse(acc)

  defp tokenize("<!--" <> rest, acc) do
    case :binary.split(rest, "-->") do
      [_, after_c] -> tokenize(after_c, acc)
      [_] -> Enum.reverse(acc)
    end
  end

  defp tokenize("<!" <> rest, acc), do: tokenize(skip_past(rest, ">"), acc)
  defp tokenize("<?" <> rest, acc), do: tokenize(skip_past(rest, ">"), acc)

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

  # style text is kept (undecoded) for the CSS engine, script text for the page's scripts
  defp add_raw(name, raw, acc) when name in ["style", "script"] and raw != "",
    do: [{:text, raw} | acc]

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
    case Regex.run(~r/\A([^\s\/>]*)/, bin, capture: :all_but_first) do
      [name] ->
        {String.downcase(name),
         binary_part(bin, byte_size(name), byte_size(bin) - byte_size(name))}
    end
  end

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
        [name] = Regex.run(~r/\A[^\s=\/>]+/, bin)
        rest = binary_part(bin, byte_size(name), byte_size(bin) - byte_size(name))
        {value, rest} = take_value(String.trim_leading(rest))
        take_attrs(rest, [{String.downcase(name), value} | acc])
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
