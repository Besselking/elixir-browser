defmodule Browser.Layout do
  @moduledoc """
  Turns an HTML tree into positioned display items.

  `measure` is `(text, style) -> width_in_px`, injected so layout stays
  independent of the GUI toolkit.

  Styling comes from each element's `"@computed"` attribute (see
  `Browser.Style`). When it is absent, as for trees that never went through the
  cascade, built-in per-tag defaults apply instead.

  Items are maps with `type: :rect | :hr | :text`; rects (block backgrounds)
  come first so text paints over them.
  """

  @base 16
  @margin 4
  @legacy_gap 10
  @legacy_indent 28
  @skip ~w(head script style title template)

  @block_tags ~w(address article aside blockquote body center details dialog dd div dl dt
                 fieldset figcaption figure footer form h1 h2 h3 h4 h5 h6 header hgroup hr html
                 legend main menu nav ol p pre section summary ul table caption tr thead tbody
                 tfoot)
  @legacy_gap_tags ~w(p ul ol pre h1 h2 h3 h4 h5 h6 blockquote)
  @headings %{"h1" => 32, "h2" => 24, "h3" => 19, "h4" => 16, "h5" => 13, "h6" => 11}
  @mono_fonts ~w(monospace courier menlo monaco consolas ui-monospace sfmono-regular)

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

  defp text_of(nodes),
    do:
      nodes
      |> Enum.map(fn
        {:text, t} -> t
        {:element, _, _, k} -> text_of(k)
      end)
      |> Enum.join()

  @doc """
  Returns `{items, content_height}`. `view_height` is the viewport height, the
  reference for `bottom`/percentage offsets of positioned elements.
  """
  def layout(nodes, width, measure, view_height \\ 768) do
    style = %{
      size: @base,
      bold: false,
      italic: false,
      mono: false,
      href: nil,
      pre: false,
      indent: 0,
      hidden: false,
      color: {0, 0, 0},
      underline: false,
      strike: false,
      align: :left,
      list: nil
    }

    ops = nodes |> walk(style, []) |> Enum.reverse()
    place(ops, width, measure, view_height)
  end

  # -- tree -> ops ---------------------------------------------------------------
  #
  # ops: {:word, text, style[, :pre]} {:space, style} {:marker, text, style}
  #      {:flush} {:gap, px} {:pad, px} {:hr} {:box_start, ref, color, left} {:box_end, ref}

  defp walk(nodes, style, acc) when is_list(nodes),
    do: Enum.reduce(nodes, acc, &walk(&1, style, &2))

  defp walk({:text, t}, %{pre: true} = style, acc), do: pre_text(t, style, acc)

  defp walk({:text, t}, style, acc) do
    leading = if String.match?(t, ~r/\A\s/), do: [{:space, style}], else: []
    trailing = if String.match?(t, ~r/\S\s+\z/), do: [{:space, style}], else: []
    words = t |> String.split() |> Enum.map(&{:word, &1, style})

    case words do
      [] -> if t == "", do: acc, else: [{:space, style} | acc]
      _ -> Enum.reverse(leading ++ Enum.intersperse(words, {:space, style}) ++ trailing) ++ acc
    end
  end

  defp walk({:element, tag, _, _}, _style, acc) when tag in @skip, do: acc
  defp walk({:element, "br", _, _}, _style, acc), do: [{:flush} | acc]

  defp walk({:element, "img", attrs, _}, style, acc) do
    alt = List.keyfind(attrs, "alt", 0, {nil, ""}) |> elem(1)
    if alt == "", do: acc, else: walk({:text, "[#{alt}]"}, restyle_inline(style, attrs), acc)
  end

  defp walk(el, style, acc), do: walk_element(el, style, acc, nil)

  defp walk_element({:element, tag, attrs, kids} = el, parent_style, acc, force) do
    c = computed(attrs)

    if c["position"] in ["absolute", "fixed"] and force != :abs_inner do
      abs_ops(el, parent_style, c, acc)
    else
      style = restyle(tag, attrs, parent_style, c)

      kind =
        case force do
          nil -> kind(tag, c)
          :abs_inner -> blockify(kind(tag, c))
          forced -> forced
        end

      case kind do
        :contents -> walk(kids, style, acc)
        :inline -> inline_ops(tag, kids, style, c, acc)
        kind -> block_ops(tag, kind, kids, style, c, acc)
      end
    end
  end

  # An out-of-flow element is laid out on its own and placed by `place/4`
  # relative to its containing block; it takes no space in the flow.
  defp abs_ops(el, parent_style, c, acc) do
    if hidden?(c) do
      acc
    else
      sub = el |> walk_element(%{parent_style | indent: 0}, [], :abs_inner) |> Enum.reverse()

      spec = %{
        top: c["top"],
        left: c["left"],
        right: c["right"],
        bottom: c["bottom"],
        width: c["width"],
        fixed: c["position"] == "fixed",
        static_indent: parent_style.indent
      }

      [{:abs, sub, spec} | acc]
    end
  end

  defp blockify(kind) when kind in [:inline, :contents], do: :block
  defp blockify(kind), do: kind

  # display -> :block | :list_item | :flex | :inline | :contents
  defp kind(tag, c) do
    case c["display"] do
      nil ->
        legacy_kind(tag)

      d
      when d in [
             "block",
             "flow-root",
             "grid",
             "table",
             "table-row",
             "table-row-group",
             "table-caption"
           ] ->
        :block

      "list-item" ->
        :list_item

      "flex" ->
        if c["flex-direction"] in ["column", "column-reverse"], do: :block, else: :flex

      "contents" ->
        :contents

      _ ->
        :inline
    end
  end

  defp legacy_kind("li"), do: :list_item
  defp legacy_kind(tag) when tag in @block_tags, do: :block
  defp legacy_kind(_), do: :inline

  defp inline_ops(tag, kids, style, c, acc) do
    acc = if tag in ~w(td th), do: [{:space, style} | acc], else: acc
    positioned? = c["position"] in ["relative", "sticky"]
    acc = if positioned?, do: [{:pos_inline, style.indent} | acc], else: acc
    acc = walk_children(tag, kids, style, acc)
    if positioned?, do: [{:pos_end} | acc], else: acc
  end

  defp block_ops(tag, kind, kids, style, c, acc) do
    box = box(tag, c)
    inner = %{style | indent: style.indent + box.ml + box.pl}

    acc = [{:gap, box.mt}, {:flush} | acc]

    if tag == "hr" do
      [{:hr}, {:gap, box.mb} | acc]
    else
      ref = make_ref()
      opts = box_opts(c, box, style.indent + box.ml)
      acc = if opts, do: [{:box_start, ref, opts} | acc], else: acc
      acc = if box.pt > 0, do: [{:pad, box.pt} | acc], else: acc
      acc = block_children(tag, kind, kids, inner, acc)
      acc = [{:flush} | acc]
      acc = if box.pb > 0, do: [{:pad, box.pb} | acc], else: acc
      acc = if opts, do: [{:box_end, ref} | acc], else: acc
      [{:gap, box.mb} | acc]
    end
  end

  # Boxes that need their geometry tracked: backgrounds, explicit sizes (which
  # may clip) and positioned boxes (containing blocks for absolute children).
  defp box_opts(c, box, left) do
    opts = %{
      bg: box.bg,
      left: left,
      h: num(c["height"]),
      min: num(c["min-height"]),
      max: num(c["max-height"]),
      clip: clips?(c),
      pos: c["position"] in ["relative", "sticky"],
      pt: box.pt,
      pb: box.pb
    }

    if opts.bg || opts.h || opts.min || opts.max || opts.pos, do: opts
  end

  defp num(v) when is_number(v), do: v
  defp num(_), do: nil

  defp clips?(c) do
    Map.get(c, "overflow-x", "visible") in ~w(hidden clip scroll auto) or
      Map.get(c, "overflow-y", "visible") in ~w(hidden clip scroll auto)
  end

  defp block_children(_tag, :flex, kids, style, acc) do
    kids
    |> Enum.reduce({acc, false}, fn
      {:text, _} = t, {a, _} ->
        {walk(t, style, a), false}

      {:element, tag, _, _} = el, {a, sep?} when tag not in @skip ->
        a = if sep?, do: [{:space, style} | a], else: a
        {walk_element(el, style, a, :inline), true}

      _, acc2 ->
        acc2
    end)
    |> elem(0)
  end

  defp block_children(tag, _kind, kids, style, acc), do: walk_children(tag, kids, style, acc)

  # ul/ol number their list items and emit markers; everything else just recurses
  defp walk_children(tag, kids, style, acc) when tag in ~w(ul ol) do
    kids
    |> Enum.reduce({acc, 1}, fn
      {:element, "li", attrs, li_kids} = li, {a, n} ->
        c = computed(attrs)

        if kind("li", c) == :list_item do
          {list_item(tag, n, attrs, li_kids, style, c, a), n + 1}
        else
          {walk(li, style, a), n}
        end

      other, {a, n} ->
        {walk(other, style, a), n}
    end)
    |> elem(0)
  end

  defp walk_children(_tag, kids, style, acc), do: walk(kids, style, acc)

  defp list_item(list_tag, n, attrs, kids, style, c, acc) do
    li_style = restyle("li", attrs, style, c)
    box = box("li", c)
    inner = %{li_style | indent: li_style.indent + box.ml + box.pl}
    type = li_style.list || if(list_tag == "ol", do: "decimal", else: "disc")

    acc = [{:gap, box.mt}, {:flush} | acc]
    acc = if type == "none", do: acc, else: [{:marker, marker(type, n), inner} | acc]
    acc = walk(kids, inner, acc)
    [{:gap, box.mb}, {:flush} | acc]
  end

  defp marker("disc", _), do: "•"
  defp marker("circle", _), do: "◦"
  defp marker("square", _), do: "▪"
  defp marker("decimal", n), do: "#{n}."
  defp marker("decimal-leading-zero", n), do: "#{String.pad_leading("#{n}", 2, "0")}."
  defp marker("lower-alpha", n), do: alpha(n, ?a) <> "."
  defp marker("lower-latin", n), do: alpha(n, ?a) <> "."
  defp marker("upper-alpha", n), do: alpha(n, ?A) <> "."
  defp marker("upper-latin", n), do: alpha(n, ?A) <> "."
  defp marker(_other, n), do: "#{n}."

  defp alpha(n, base) when n > 0 do
    div(n - 1, 26)
    |> then(&if(&1 > 0, do: alpha(&1, base), else: ""))
    |> Kernel.<>(<<base + rem(n - 1, 26)>>)
  end

  defp alpha(_, _), do: ""

  # margins/padding/background of a block; computed values win over tag defaults
  defp box(tag, c) do
    gap = if tag in @legacy_gap_tags, do: @legacy_gap, else: 0

    %{
      mt: px(c["margin-top"] || gap),
      mb: px(c["margin-bottom"] || gap),
      ml: px(c["margin-left"] || if(tag == "blockquote", do: @legacy_indent, else: 0)),
      pl: px(c["padding-left"] || if(tag in ~w(ul ol), do: @legacy_indent, else: 0)),
      pt: px(c["padding-top"] || 0),
      pb: px(c["padding-bottom"] || 0),
      bg:
        case(c["background-color"],
          do: (
            {_, _, _} = rgb -> rgb
            _ -> nil
          )
        )
    }
  end

  # wx draws at integer pixels
  defp px(n), do: round(n)

  # -- styles ----------------------------------------------------------------------

  defp restyle_inline(style, attrs), do: apply_computed(style, computed(attrs))

  defp restyle(tag, attrs, style, c) do
    style =
      case tag do
        t when t in ~w(b strong) -> %{style | bold: true}
        t when t in ~w(i em cite) -> %{style | italic: true}
        t when t in ~w(code tt kbd samp) -> %{style | mono: true}
        "pre" -> %{style | mono: true, pre: true}
        "a" -> link_style(style, attrs)
        t when is_map_key(@headings, t) -> %{style | size: @headings[t], bold: true}
        _ -> style
      end

    apply_computed(style, c)
  end

  defp link_style(style, attrs) do
    case List.keyfind(attrs, "href", 0) do
      {_, href} -> %{style | href: href, color: {0, 0, 238}, underline: true}
      nil -> style
    end
  end

  defp computed(attrs) do
    case List.keyfind(attrs, "@computed", 0) do
      {_, map} -> map
      nil -> %{}
    end
  end

  # Style already resolved inheritance, so present keys simply override.
  defp apply_computed(style, c) do
    decoration = c["text-decoration-line"]

    style
    |> put_if(c["font-size"], fn s, fs ->
      if fs < 1, do: %{s | size: 1, hidden: true}, else: %{s | size: round(fs)}
    end)
    |> put_if(c["font-weight"], &%{&1 | bold: &2 == "bold"})
    |> put_if(c["font-style"], &%{&1 | italic: &2 == "italic"})
    |> put_if(c["font-family"], &%{&1 | mono: mono?(&2)})
    |> put_if(match?({_, _, _}, c["color"]) && c["color"], &%{&1 | color: &2})
    |> put_if(
      decoration,
      &%{
        &1
        | underline: String.contains?(&2, "underline"),
          strike: String.contains?(&2, "line-through")
      }
    )
    |> put_if(c["text-align"], &%{&1 | align: align(&2)})
    |> put_if(c["list-style-type"], &%{&1 | list: &2})
    |> Map.put(:hidden, hidden?(c))
  end

  # visibility is inherited by Style; a zero font-size hides text too
  defp hidden?(c),
    do:
      c["visibility"] in ["hidden", "collapse"] or
        (is_number(c["font-size"]) and c["font-size"] < 1)

  defp put_if(style, nil, _fun), do: style
  defp put_if(style, false, _fun), do: style
  defp put_if(style, value, fun), do: fun.(style, value)

  defp mono?(family) do
    first =
      family
      |> String.split(",")
      |> hd()
      |> String.trim()
      |> String.trim("\"")
      |> String.trim("'")

    first in @mono_fonts
  end

  defp align("center"), do: :center
  defp align("-webkit-center"), do: :center
  defp align(v) when v in ["right", "end"], do: :right
  defp align(_), do: :left

  defp pre_text(t, style, acc) do
    t
    |> String.split("\n")
    |> Enum.with_index()
    |> Enum.reduce(acc, fn {line, i}, a ->
      a = if i > 0, do: [{:flush} | a], else: a
      if line == "", do: a, else: [{:word, String.replace(line, "\t", "    "), style, :pre} | a]
    end)
  end

  # -- ops -> positioned items -------------------------------------------------------
  #
  # State of the line placer. `pos` is the stack of containing-block origins
  # (`%{x, y, w, h}`, bottom entry = the page); `open` holds boxes between
  # their start and end ops; `n`/`nr` count items/rects so a box can find the
  # ones created inside it; `overlays` are laid-out absolute elements.

  defp place(ops, width, measure, view_height) do
    st = run(ops, width, measure, view_height, @margin)
    {finalize(st), st.y + st.margin}
  end

  defp run(ops, width, measure, view_height, margin) do
    st = %{
      items: [],
      rects: [],
      n: 0,
      nr: 0,
      overlays: [],
      deferred: [],
      open: %{},
      pos: [%{x: 0, y: 0, w: width, h: view_height}],
      line: [],
      x: 0,
      y: 0,
      gap: 0,
      pending_space: nil,
      lh: 0,
      indent: 0,
      width: width,
      measure: measure,
      view_h: view_height,
      margin: margin
    }

    ops |> Enum.reduce(st, &op/2) |> flush()
  end

  # paint order: backgrounds, flow content, then absolutely positioned elements
  defp finalize(st) do
    Enum.reverse(st.rects) ++
      Enum.reverse(st.items) ++ (st.overlays |> Enum.reverse() |> Enum.concat())
  end

  defp op({:space, style}, st), do: if(st.line == [], do: st, else: %{st | pending_space: style})
  defp op({:word, text, style}, st), do: word(text, style, false, st)
  defp op({:word, text, style, :pre}, st), do: word(text, style, true, st)

  defp op({:marker, m, style}, st) do
    st = word(m, %{style | indent: style.indent - 18}, true, st)
    st = %{st | line: [Map.put(hd(st.line), :marker, true) | tl(st.line)]}
    %{st | pending_space: style}
  end

  # a list marker stays on the line of the content that follows it
  defp op({:flush}, %{line: [%{marker: true}]} = st), do: st
  defp op({:flush}, st), do: flush(st)

  defp op({:gap, _px}, %{line: [%{marker: true}]} = st), do: st
  defp op({:gap, px}, st), do: %{flush(st) | gap: max(st.gap, px)}

  defp op({:pad, px}, st), do: st |> flush() |> apply_gap() |> Map.update!(:y, &(&1 + px))

  defp op({:hr}, st) do
    st = st |> flush() |> apply_gap()

    item = %{
      type: :hr,
      x: st.margin + st.indent,
      y: st.y,
      w: st.width - 2 * st.margin - st.indent
    }

    %{st | items: [item | st.items], n: st.n + 1, y: st.y + 2}
  end

  defp op({:box_start, ref, o}, st) do
    st = st |> flush() |> apply_gap()
    left = st.margin + o.left
    box = %{ref: ref, top: st.y, left: left, o: o, n0: st.n, nr0: st.nr}
    st = %{st | open: Map.put(st.open, ref, box)}

    if o.pos,
      do:
        push_pos(st, %{
          x: left,
          y: st.y,
          w: max(st.width - st.margin - left, 0),
          h: nil,
          ref: ref
        }),
      else: st
  end

  defp op({:box_end, ref}, st) do
    st = flush(st)
    {box, open} = Map.pop(st.open, ref)
    st = %{st | open: open}
    st = if box.o.pos, do: %{st | pos: tl(st.pos)}, else: st
    finish_box(st, box)
  end

  defp op({:pos_inline, indent}, st) do
    {x, y} =
      if st.line == [],
        do: {st.margin + indent, st.y + st.gap},
        else: {st.x, st.y}

    push_pos(st, %{x: x, y: y, w: max(st.width - st.margin - x, 0), h: nil})
  end

  defp op({:pos_end}, st), do: %{st | pos: tl(st.pos)}

  defp op({:abs, sub, spec}, st) do
    origin = if spec.fixed, do: List.last(st.pos), else: hd(st.pos)

    # `bottom` needs the containing box's height, known only once it closes
    if spec.bottom && !spec.top && is_nil(origin.h) && Map.get(origin, :ref) do
      %{st | deferred: [{origin.ref, sub, spec} | st.deferred]}
    else
      place_absolute(st, sub, spec, origin)
    end
  end

  defp push_pos(st, origin), do: %{st | pos: [origin | st.pos]}

  defp apply_gap(st), do: %{st | y: st.y + st.gap, gap: 0}

  # -- boxes with a size, a background or clipping ------------------------------------

  defp finish_box(st, %{o: o} = box) do
    natural = st.y - box.top
    extra = o.pt + o.pb
    content = natural - extra

    used = o.h || content
    used = if o.max, do: min(used, o.max), else: used
    used = if o.min, do: max(used, o.min), else: used
    used = round(used)

    clipped? = o.clip and used < content
    # without clipping a too-small height just lets the content overflow the box
    height = if used < content and not clipped?, do: natural, else: used + extra

    limit = box.top + o.pt + used
    st = if clipped?, do: clip_to(st, box, limit), else: st
    st = %{st | y: box.top + height}
    st = place_deferred(st, box, height)

    if o.bg do
      rect = %{
        type: :rect,
        x: box.left,
        y: box.top,
        w: max(st.width - st.margin - box.left, 0),
        h: height,
        color: o.bg
      }

      # the box's own background goes under the rects of boxes inside it
      inner = st.nr - box.nr0
      {new, old} = Enum.split(st.rects, inner)
      %{st | rects: new ++ [rect | old], nr: st.nr + 1}
    else
      st
    end
  end

  defp place_deferred(st, box, height) do
    {mine, rest} = Enum.split_with(st.deferred, fn {ref, _, _} -> ref == box.ref end)
    origin = %{x: box.left, y: box.top, w: max(st.width - st.margin - box.left, 0), h: height}

    mine
    |> Enum.reverse()
    |> Enum.reduce(%{st | deferred: rest}, fn {_, sub, spec}, acc ->
      place_absolute(acc, sub, spec, origin)
    end)
  end

  # drop whatever was created inside the box below `limit`
  defp clip_to(st, box, limit) do
    {new_items, old_items} = Enum.split(st.items, st.n - box.n0)
    kept_items = Enum.filter(new_items, &fits?(&1, limit))
    {new_rects, old_rects} = Enum.split(st.rects, st.nr - box.nr0)

    kept_rects =
      for r <- new_rects, r.y < limit, do: %{r | h: min(r.h, limit - r.y)}

    %{
      st
      | items: kept_items ++ old_items,
        n: box.n0 + length(kept_items),
        rects: kept_rects ++ old_rects,
        nr: box.nr0 + length(kept_rects)
    }
  end

  defp fits?(%{type: :text} = it, limit), do: it.y + it.h <= limit
  defp fits?(%{type: :hr} = it, limit), do: it.y < limit

  # -- absolute / fixed positioning ------------------------------------------------------

  defp place_absolute(st, sub, spec, origin) do
    cw = origin.w

    {static_x, static_y} =
      if st.line == [],
        do: {st.margin + spec.static_indent, st.y + st.gap},
        else: {st.x, st.y}

    left = resolve(spec.left, cw)
    right = resolve(spec.right, cw)
    top = resolve_v(spec.top, origin.h)
    bottom = origin.h && resolve_v(spec.bottom, origin.h)

    {width, x} = abs_width(st, sub, spec, origin, left, right, static_x)
    {items, height} = layout_sub(st, sub, width)

    y =
      cond do
        top -> origin.y + top
        bottom -> origin.y + origin.h - bottom - height
        true -> static_y
      end

    x = if left, do: origin.x + left, else: x
    moved = for it <- items, do: %{it | x: it.x + x, y: it.y + y}
    %{st | overlays: [moved | st.overlays]}
  end

  # vertical offsets: percentages need a known containing-block height
  defp resolve_v({:pct, _}, nil), do: nil
  defp resolve_v(v, h), do: resolve(v, h)

  defp resolve(nil, _base), do: nil
  defp resolve({:pct, f}, base), do: round(f * base)
  defp resolve(n, _base) when is_number(n), do: round(n)

  # -> {content width, x for the right/static placement}
  defp abs_width(st, sub, spec, origin, left, right, static_x) do
    cw = origin.w

    case resolve(spec.width, cw) do
      nil ->
        avail =
          cond do
            left && right -> cw - left - right
            left -> cw - left
            right -> cw - right
            true -> origin.x + cw - static_x
          end

        avail = max(avail, 40)

        width =
          if left && right do
            avail
          else
            {items, _} = layout_sub(st, sub, avail)
            min(avail, extent(items))
          end

        {width, if(right && !left, do: origin.x + cw - right - width, else: static_x)}

      w ->
        {w, if(right && !left, do: origin.x + cw - right - w, else: static_x)}
    end
  end

  defp layout_sub(st, sub, width) do
    sub_st = run(sub, max(width, 1), st.measure, st.view_h, 0)
    {finalize(sub_st), sub_st.y}
  end

  # right edge of the text, for shrink-to-fit
  defp extent(items) do
    items |> Enum.filter(&(&1.type == :text)) |> Enum.map(&(&1.x + &1.w)) |> Enum.max(fn -> 0 end)
  end

  # -- words and lines ------------------------------------------------------------------

  defp word(text, style, nowrap?, st) do
    w = st.measure.(text, style)
    indent = st.margin + style.indent

    space_w =
      if st.pending_space && st.line != [], do: st.measure.(" ", st.pending_space), else: 0

    st =
      if st.line == [], do: st |> apply_gap() |> Map.merge(%{x: indent, indent: indent}), else: st

    st =
      if st.line != [] and not nowrap? and st.x + space_w + w > st.width - st.margin do
        st |> flush() |> apply_gap() |> Map.merge(%{x: indent, indent: indent})
      else
        st
      end

    space_w = if st.line == [], do: 0, else: space_w
    x = st.x + space_w

    item = %{
      type: :text,
      x: x,
      y: 0,
      w: w,
      h: style.size,
      text: text,
      size: style.size,
      bold: style.bold,
      italic: style.italic,
      mono: style.mono,
      href: if(style.hidden, do: nil, else: style.href),
      hidden: style.hidden,
      color: style.color,
      underline: style.underline,
      strike: style.strike,
      align: style.align
    }

    st = bridge(st, item, space_w)

    %{st | line: [item | st.line], x: x + w, pending_space: nil, lh: max(st.lh, style.size)}
  end

  # Extend the previous word over the gap when both belong to the same link or
  # the same decoration, so underlines and click targets are continuous.
  defp bridge(%{line: [prev | rest]} = st, item, gap) when gap > 0 do
    same_link = is_binary(item.href) and prev.href == item.href

    same_deco =
      (item.underline or item.strike) and prev.underline == item.underline and
        prev.strike == item.strike and prev.color == item.color

    if same_link or same_deco,
      do: %{st | line: [%{prev | w: prev.w + gap} | rest]},
      else: st
  end

  defp bridge(st, _item, _gap), do: st

  defp flush(%{line: []} = st), do: %{st | pending_space: nil}

  defp flush(st) do
    lh = round(st.lh * 1.35)
    items = Enum.reverse(st.line)
    shift = align_shift(items, st)

    placed =
      Enum.map(st.line, fn it ->
        %{it | x: it.x + shift, y: st.y + lh - it.h - div(lh - it.h, 4)}
      end)

    %{
      st
      | items: placed ++ st.items,
        n: st.n + length(placed),
        line: [],
        y: st.y + lh,
        lh: 0,
        x: st.indent,
        pending_space: nil
    }
  end

  defp align_shift([first | _] = items, st) do
    last = List.last(items)
    free = st.width - st.margin - st.indent - (last.x + last.w - first.x)

    case first.align do
      :center -> max(round(free / 2), 0)
      :right -> max(round(free), 0)
      :left -> 0
    end
  end
end
