defmodule Browser.Layout do
  @moduledoc """
  Turns an HTML tree into positioned display items.

  `measure` is `(text, style) -> width_in_px`, injected so layout stays
  independent of the GUI toolkit.
  """

  @base 14
  @margin 12
  @indent 28
  @skip ~w(head script style title template)
  @blocks ~w(div section article header footer nav main form table tr blockquote dl dt dd body html)
  @para ~w(p ul ol pre h1 h2 h3 h4 h5 h6 blockquote)
  @headings %{"h1" => 28, "h2" => 22, "h3" => 18, "h4" => 16, "h5" => 14, "h6" => 13}

  def title(nodes) do
    case find(nodes, "title") do
      {:element, _, _, kids} -> kids |> text_of() |> String.split() |> Enum.join(" ")
      nil -> nil
    end
  end

  defp find(nodes, tag) when is_list(nodes), do: Enum.find_value(nodes, &find(&1, tag))
  defp find({:element, tag, _, _} = n, tag), do: n
  defp find({:element, _, _, kids}, tag), do: find(kids, tag)
  defp find(_, _), do: nil

  defp text_of(nodes), do: nodes |> Enum.map(fn {:text, t} -> t; {:element, _, _, k} -> text_of(k) end) |> Enum.join()

  @doc "Returns `{items, content_height}`."
  def layout(nodes, width, measure) do
    style = %{size: @base, bold: false, italic: false, mono: false, href: nil, pre: false, indent: 0}
    ops = nodes |> walk(style, []) |> Enum.reverse()
    place(ops, width, measure)
  end

  # -- tree -> ops -------------------------------------------------------

  defp walk(nodes, style, acc) when is_list(nodes), do: Enum.reduce(nodes, acc, &walk(&1, style, &2))

  defp walk({:text, t}, %{pre: true} = style, acc), do: pre_text(t, style, acc)

  defp walk({:text, t}, style, acc) do
    leading = if String.match?(t, ~r/\A\s/), do: [{:space, style}], else: []
    trailing = if String.match?(t, ~r/\S\s+\z/), do: [{:space, style}], else: []
    words = t |> String.split() |> Enum.map(&{:word, &1, style})

    case words do
      [] -> if t == "", do: acc, else: [{:space, style} | acc]
      _ -> Enum.reverse(leading ++ intersperse(words, style) ++ trailing) ++ acc
    end
  end

  defp walk({:element, tag, _, _}, _style, acc) when tag in @skip, do: acc
  defp walk({:element, "br", _, _}, _style, acc), do: [{:newline} | acc]
  defp walk({:element, "hr", _, _}, _style, acc), do: [{:hr}, {:para} | [{:para} | acc]]
  defp walk({:element, "img", attrs, _}, style, acc) do
    alt = List.keyfind(attrs, "alt", 0, {nil, ""}) |> elem(1)
    if alt == "", do: acc, else: walk({:text, "[#{alt}]"}, style, acc)
  end

  defp walk({:element, tag, attrs, kids}, style, acc) do
    style = restyle(tag, attrs, style)
    container_ops(tag, kids, style, acc)
  end

  defp container_ops(tag, kids, style, acc) when tag in ~w(ul ol) do
    inner = %{style | indent: style.indent + @indent}
    items =
      kids
      |> Enum.filter(&match?({:element, "li", _, _}, &1))
      |> Enum.with_index(1)
      |> Enum.reduce([{:para} | acc], fn {{:element, _, _, li_kids}, i}, a ->
        marker = if tag == "ol", do: "#{i}.", else: "•"
        a = [{:marker, marker, inner} , {:newline} | a]
        walk(li_kids, inner, a)
      end)

    [{:para} | items]
  end

  defp container_ops(tag, kids, style, acc) when tag in @para or tag in @blocks do
    acc = if tag in @para, do: [{:para} | acc], else: [{:newline} | acc]
    acc = walk(kids, style, acc)
    if tag in @para, do: [{:para} | acc], else: [{:newline} | acc]
  end

  defp container_ops("li", kids, style, acc), do: walk(kids, style, [{:newline} | acc])
  defp container_ops(_inline, kids, style, acc), do: walk(kids, style, acc)

  defp restyle(tag, attrs, style) do
    style =
      case tag do
        t when t in ~w(b strong) -> %{style | bold: true}
        t when t in ~w(i em cite) -> %{style | italic: true}
        t when t in ~w(code tt kbd samp) -> %{style | mono: true}
        "pre" -> %{style | mono: true, pre: true}
        "a" -> %{style | href: List.keyfind(attrs, "href", 0, {nil, nil}) |> elem(1)}
        "blockquote" -> %{style | indent: style.indent + @indent}
        t when is_map_key(@headings, t) -> %{style | size: @headings[t], bold: true}
        _ -> style
      end

    style
  end

  defp intersperse(words, style), do: Enum.intersperse(words, {:space, style})

  defp pre_text(t, style, acc) do
    t
    |> String.split("\n")
    |> Enum.with_index()
    |> Enum.reduce(acc, fn {line, i}, a ->
      a = if i > 0, do: [{:newline} | a], else: a
      if line == "", do: a, else: [{:word, String.replace(line, "\t", "    "), style, :pre} | a]
    end)
  end

  # -- ops -> positioned items --------------------------------------------

  defp place(ops, width, measure) do
    st = %{items: [], line: [], x: 0, y: @margin, gap: false, pending_space: nil,
           lh: 0, indent: 0, width: width, measure: measure, last_break: :start}

    st = Enum.reduce(ops, st, &op/2)
    st = flush(st)
    {Enum.reverse(st.items), st.y + @margin}
  end

  defp op({:space, style}, st), do: if(st.line == [], do: st, else: %{st | pending_space: style})

  defp op({:word, text, style}, st), do: word(text, style, false, st)
  defp op({:word, text, style, :pre}, st), do: word(text, style, true, st)
  defp op({:marker, m, style}, st) do
    st = word(m, %{style | indent: style.indent - 18}, true, st)
    %{st | pending_space: style}
  end

  defp op({:newline}, st), do: flush(st)
  defp op({:para}, st), do: st |> flush() |> para_gap()
  defp op({:hr}, st) do
    st = flush(st)
    item = %{type: :hr, x: @margin, y: st.y, w: st.width - 2 * @margin}
    %{st | items: [item | st.items], y: st.y + 2, last_break: :para}
  end

  defp para_gap(%{last_break: :para} = st), do: st
  defp para_gap(%{last_break: :start} = st), do: st
  defp para_gap(st), do: %{st | y: st.y + 10, last_break: :para}

  defp word(text, style, nowrap?, st) do
    w = st.measure.(text, style)
    indent = @margin + style.indent
    space_w = if st.pending_space && st.line != [], do: st.measure.(" ", st.pending_space), else: 0
    st = if st.line == [], do: %{st | x: indent, indent: indent}, else: st

    st =
      if st.line != [] and not nowrap? and st.x + space_w + w > st.width - @margin do
        st |> flush() |> Map.merge(%{x: indent, indent: indent})
      else
        st
      end

    space_w = if st.line == [], do: 0, else: space_w
    x = st.x + space_w
    st = bridge_link(st, style.href, space_w)

    item = %{type: :text, x: x, y: 0, w: w, h: style.size, text: text, size: style.size,
             bold: style.bold, italic: style.italic, mono: style.mono, href: style.href}

    %{st | line: [item | st.line], x: x + w, pending_space: nil,
           lh: max(st.lh, style.size), last_break: :text}
  end

  # Extend the previous word of the same link over the gap so the underline
  # and click target are continuous between words.
  defp bridge_link(%{line: [%{href: href} = prev | rest]} = st, href, gap)
       when is_binary(href) and gap > 0,
       do: %{st | line: [%{prev | w: prev.w + gap} | rest]}

  defp bridge_link(st, _, _), do: st

  defp flush(%{line: []} = st), do: %{st | pending_space: nil}

  defp flush(st) do
    lh = round(st.lh * 1.35)

    placed =
      Enum.map(st.line, fn it -> %{it | y: st.y + lh - it.h - div(lh - it.h, 4)} end)

    %{st | items: placed ++ st.items, line: [], y: st.y + lh, lh: 0,
           x: st.indent, pending_space: nil, last_break: :line}
  end
end
