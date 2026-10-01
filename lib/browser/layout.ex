defmodule Browser.Layout do
  @moduledoc """
  Turns an HTML tree into positioned display items.

  `measure` is `(text, style) -> width_in_px`, injected so layout stays
  independent of the GUI toolkit.

  Styling comes from each element's `"@computed"` attribute (see
  `Browser.Style`). When it is absent, as for trees that never went through the
  cascade, built-in per-tag defaults apply instead.

  Items are maps with `type: :canvas | :rect | :hr | :text`. A `:canvas` item
  (the root background colour) comes first, then rects (block backgrounds and
  borders), so text paints over them.
  """

  alias Browser.{Backgrounds, Shadows}

  # item types painted before (underneath) the text of the same page
  @behind_text [:rect, :shadow, :inset_shadow, :bgimage]

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

  Option `images: %{url => {:ok, width, height} | :failed}` says which pictures are
  known; without it images are shown as their alt text. With it (even empty), an
  image not in the map is still loading: its declared size is reserved and it
  takes no room if it has none.

  Option `focus: %{cid: id, caret: {line, column}}` adds a `:ring` item around the
  focused form control and a `:caret` item at the given position of its text.
  """
  def layout(nodes, width, measure, view_height \\ 768, opts \\ []) do
    style = %{
      size: @base,
      bold: false,
      italic: false,
      mono: false,
      href: nil,
      pre: false,
      hidden: false,
      color: {0, 0, 0},
      underline: false,
      strike: false,
      align: :left,
      list: nil,
      lh: :normal,
      cid: nil,
      images: Keyword.get(opts, :images)
    }

    {nodes, canvas} = propagate_background(nodes)
    ops = nodes |> walk(style, []) |> Enum.reverse()
    {items, height} = place(ops, width, measure, view_height, opts[:images])
    items = add_focus(items, measure, opts[:focus])

    case canvas do
      nil ->
        {items, height}

      canvas ->
        {[canvas_item(canvas, width, max(height, view_height), opts[:images]) | items], height}
    end
  end

  # -- focus -----------------------------------------------------------------------

  @ring_color {26, 115, 232}

  defp add_focus(items, _measure, nil), do: items

  defp add_focus(items, measure, %{cid: cid, caret: caret}) do
    texts =
      items
      |> Enum.filter(&(&1.type == :text and Map.get(&1, :cid) == cid))
      |> Enum.sort_by(&{&1.y, &1.x})

    ring =
      case controls(items)[cid] do
        nil ->
          []

        b ->
          [
            %{
              type: :ring,
              x: b.x - 2,
              y: b.y - 2,
              w: b.w + 4,
              h: b.h + 4,
              radius: grow(b.radius, 2),
              color: @ring_color,
              cid: cid
            }
          ]
      end

    caret =
      with {line, col} <- caret, %{} = it <- Enum.at(texts, line) do
        prefix = String.slice(it.text, 0, col)
        x = it.x + if(prefix == "", do: 0, else: measure.(prefix, it))

        c = %{
          type: :caret,
          x: round(x),
          y: it.y,
          w: 1,
          h: round(it.h * 1.25),
          color: it.color,
          cid: cid
        }

        [if(clip = Map.get(it, :clip), do: Map.put(c, :clip, clip), else: c)]
      else
        _ -> []
      end

    items ++ ring ++ caret
  end

  defp grow(nil, _by), do: nil

  defp grow(radii, by) do
    radii
    |> Tuple.to_list()
    |> Enum.map(fn {rx, ry} -> if rx > 0 and ry > 0, do: {rx + by, ry + by}, else: {0, 0} end)
    |> List.to_tuple()
  end

  @doc """
  Bounds of every form control that appears in `items`: `%{cid => %{x, y, w, h, radius}}`.
  A control is its border box (its largest rect), or the box around its text if it has none.
  """
  def controls(items) do
    items
    |> Enum.filter(&(Map.get(&1, :cid) != nil and &1.type in [:rect, :text]))
    |> Enum.group_by(& &1.cid)
    |> Map.new(fn {cid, its} -> {cid, bounds(its)} end)
  end

  # the font of the control's text, for measuring it
  defp font_of(items) do
    case Enum.find(items, &(&1.type == :text)) do
      nil -> nil
      it -> Map.take(it, [:size, :bold, :italic, :mono])
    end
  end

  defp bounds(items) do
    case Enum.filter(items, &(&1.type == :rect)) do
      [] ->
        x0 = items |> Enum.map(& &1.x) |> Enum.min()
        y0 = items |> Enum.map(& &1.y) |> Enum.min()
        x1 = items |> Enum.map(&(&1.x + &1.w)) |> Enum.max()
        y1 = items |> Enum.map(&(&1.y + round(&1.h * 1.25))) |> Enum.max()
        %{x: x0, y: y0, w: x1 - x0, h: y1 - y0, radius: nil, font: font_of(items)}

      rects ->
        r = Enum.max_by(rects, &(&1.w * &1.h))
        %{x: r.x, y: r.y, w: r.w, h: r.h, radius: Map.get(r, :radius), font: font_of(items)}
    end
  end

  # The root element's background (or body's, if the root has none) paints the whole
  # canvas, not just the area the element covers. That element then doesn't paint it
  # again on its own box. Returns `{nodes, canvas_style | nil}`.
  defp propagate_background(nodes) do
    with i when i != nil <- Enum.find_index(nodes, &match?({:element, "html", _, _}, &1)),
         {:element, "html", hattrs, kids} <- Enum.at(nodes, i) do
      body_i = Enum.find_index(kids, &match?({:element, "body", _, _}, &1))
      body = body_i && Enum.at(kids, body_i)

      cond do
        has_background?(computed(hattrs)) ->
          html = {:element, "html", without_background(hattrs), kids}
          {List.replace_at(nodes, i, html), canvas_style(computed(hattrs))}

        body && has_background?(computed(elem(body, 2))) ->
          {:element, "body", battrs, bkids} = body
          body = {:element, "body", without_background(battrs), bkids}
          html = {:element, "html", hattrs, List.replace_at(kids, body_i, body)}
          {List.replace_at(nodes, i, html), canvas_style(computed(battrs))}

        true ->
          {nodes, nil}
      end
    else
      _ -> {nodes, nil}
    end
  end

  @background_keys ~w(background-color background-image background-repeat background-position background-size)

  defp has_background?(c), do: match?({_, _, _}, c["background-color"]) or bgimg_spec(c) != nil

  defp without_background(attrs) do
    List.keyreplace(
      attrs,
      "@computed",
      0,
      {"@computed", Map.drop(computed(attrs), @background_keys)}
    )
  end

  defp canvas_style(c) do
    %{
      color: if(match?({_, _, _}, c["background-color"]), do: c["background-color"]),
      bgimg: bgimg_spec(c),
      current: if(match?({_, _, _}, c["color"]), do: c["color"], else: {0, 0, 0})
    }
  end

  defp canvas_item(canvas, width, height, images) do
    area = {0, 0, width, height}

    layers =
      if canvas.bgimg,
        do: Backgrounds.paint_layers(canvas.bgimg, area, area, images, color4(canvas.current)),
        else: []

    %{type: :canvas, color: canvas.color, layers: layers, x: 0, y: 0, w: width, h: height}
  end

  defp color4({r, g, b}), do: {r, g, b, 255}

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

  defp walk({:element, "img", _attrs, _} = el, style, acc), do: image_ops(el, style, acc)

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
          :inline_inner -> inner_kind(c)
          forced -> forced
        end

      case kind do
        :contents -> walk(kids, style, acc)
        :inline -> inline_ops(tag, kids, style, c, acc)
        :inline_block -> inline_block_ops(el, parent_style, c, acc)
        kind -> block_ops(tag, kind, kids, style, c, acc)
      end
    end
  end

  # An out-of-flow element is laid out on its own and placed by `place/4`
  # relative to its containing block; it takes no space in the flow. Its width
  # properties belong to the placement, so they are removed from the element's
  # own box.
  defp abs_ops({:element, tag, attrs, kids}, parent_style, c, acc) do
    if hidden?(c) do
      acc
    else
      box = box(tag, c)
      own = Map.drop(c, ~w(width min-width max-width margin-left margin-right))
      attrs = List.keyreplace(attrs, "@computed", 0, {"@computed", own})

      sub =
        {:element, tag, attrs, kids}
        |> walk_element(parent_style, [], :abs_inner)
        |> Enum.reverse()

      {_, br, _, bl} = box.bw
      border_box? = c["box-sizing"] == "border-box"

      spec = %{
        top: c["top"],
        left: c["left"],
        right: c["right"],
        bottom: c["bottom"],
        width: dim(c["width"]),
        minw: c["min-width"],
        maxw: c["max-width"],
        # width properties size the content box unless box-sizing says otherwise
        extra: if(border_box?, do: 0, else: box.pl + box.pr + bl + br),
        rextra: box.pr + br,
        mextra: 0,
        fixed: c["position"] == "fixed"
      }

      [{:abs, sub, spec} | acc]
    end
  end

  # <img>: the picture once it has loaded; its declared size while it loads; the alt
  # text if there is no picture (no source, or it failed). Without any image
  # information at all (`images` option not given) it is just the alt text.
  defp image_ops({:element, "img", attrs, _}, parent_style, acc) do
    c = computed(attrs)
    style = restyle("img", attrs, parent_style, c)
    url = with "" <- attr_value(attrs, "@src"), do: nil
    images = parent_style.images
    info = if url && images, do: Map.get(images, url)
    alt = attr_value(attrs, "alt")
    declared = declared_size(attrs)

    cond do
      match?({:ok, _, _}, info) ->
        image_atom(url, info, attrs, c, style, acc)

      url != nil and info == nil and is_map(images) and declared != nil ->
        image_atom(url, nil, attrs, c, style, acc)

      url != nil and info == nil and is_map(images) ->
        acc

      alt == "" ->
        acc

      true ->
        walk({:text, "[#{alt}]"}, restyle_inline(parent_style, attrs), acc)
    end
  end

  defp declared_size(attrs) do
    w = attr_int(attrs, "width")
    h = attr_int(attrs, "height")
    if w || h, do: %{w: w, h: h}
  end

  defp attr_int(attrs, name) do
    case Integer.parse(attr_value(attrs, name)) do
      {n, _} when n >= 0 -> n
      _ -> nil
    end
  end

  defp attr_value(attrs, name), do: List.keyfind(attrs, name, 0, {nil, ""}) |> elem(1)

  defp image_atom(url, info, attrs, c, style, acc) do
    kind = kind("img", c)
    block? = kind in [:block, :list_item, :flex]
    box = box("img", c)

    # a block-level image sits on its own line; auto side margins position it
    {box, align, before, after_} =
      if block? do
        align =
          case {box.ml, box.mr} do
            {:auto, :auto} -> :center
            {:auto, _} -> :right
            _ -> style.align
          end

        {%{box | mt: 0, mb: 0}, align, [{:flush}, {:gap, box.mt}], [{:flush}, {:gap, box.mb}]}
      else
        {box, style.align, [], []}
      end

    spec = %{
      url: url,
      intrinsic: with({:ok, w, h} <- info, do: {w, h}, else: (_ -> nil)),
      paint?: info != nil,
      attrs: declared_size(attrs) || %{w: nil, h: nil},
      css: %{
        w: c["width"],
        h: c["height"],
        minw: c["min-width"],
        maxw: c["max-width"],
        minh: c["min-height"],
        maxh: c["max-height"]
      },
      box: box,
      href: style.href,
      hidden: style.hidden,
      valign: c["vertical-align"]
    }

    Enum.reverse(before) ++
      [{:image, spec, %{style | align: align}}] ++ Enum.reverse(after_) ++ acc
  end

  defp blockify(kind) when kind in [:inline, :contents, :inline_block], do: :block
  defp blockify(kind), do: kind

  # the box an inline-block establishes inside itself
  defp inner_kind(c) do
    if c["display"] == "inline-flex" and c["flex-direction"] not in ["column", "column-reverse"],
      do: :flex,
      else: :block
  end

  # An inline-block is laid out on its own (a block inside) and then placed in
  # the line as one unit; its width properties size the unit, so they are
  # removed from the element's own box.
  defp inline_block_ops({:element, tag, attrs, kids}, parent_style, c, acc) do
    box = box(tag, c)
    ml = if box.ml == :auto, do: 0, else: box.ml
    mr = if box.mr == :auto, do: 0, else: box.mr

    own =
      c
      |> Map.drop(~w(width min-width max-width))
      |> Map.merge(%{"margin-left" => ml * 1.0, "margin-right" => mr * 1.0})

    attrs = List.keyreplace(attrs, "@computed", 0, {"@computed", own})

    sub =
      {:element, tag, attrs, kids}
      |> walk_element(parent_style, [], :inline_inner)
      |> Enum.reverse()

    {_, br, _, bl} = box.bw

    spec = %{
      width: dim(c["width"]),
      minw: c["min-width"],
      maxw: c["max-width"],
      extra: if(c["box-sizing"] == "border-box", do: 0, else: box.pl + box.pr + bl + br),
      mextra: ml + mr,
      rextra: box.pr + br + mr,
      valign: c["vertical-align"]
    }

    [{:inline_block, sub, spec, parent_style} | acc]
  end

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

      d when d in ["inline-block", "inline-flex", "inline-grid", "inline-table"] ->
        :inline_block

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
    acc = if positioned?, do: [{:pos_inline} | acc], else: acc

    spec = inline_spec(tag, c, style)
    ref = make_ref()
    acc = if spec, do: [{:inline_open, ref, spec} | acc], else: acc
    acc = walk_children(tag, kids, style, acc)
    acc = if spec, do: [{:inline_close, ref, spec} | acc], else: acc

    if positioned?, do: [{:pos_end} | acc], else: acc
  end

  # An inline element needs its own box only if it has a background, borders,
  # or horizontal padding/margins (vertical padding alone paints nothing).
  defp inline_spec(_tag, c, _style) when map_size(c) == 0, do: nil

  defp inline_spec(tag, c, style) do
    box = box(tag, c)
    {bt, br, bb, bl} = box.bw
    ml = if box.ml == :auto, do: 0, else: box.ml
    mr = if box.mr == :auto, do: 0, else: box.mr
    visible? = box.bg != nil or bt + br + bb + bl > 0

    if visible? or box.pl + box.pr + ml + mr > 0 do
      %{
        ml: ml,
        mr: mr,
        pl: box.pl,
        pr: box.pr,
        pt: box.pt,
        pb: box.pb,
        bt: bt,
        br: br,
        bb: bb,
        bl: bl,
        bc: box.bc,
        bg: box.bg,
        r: box.r,
        size: style.size,
        paint: visible? and not style.hidden
      }
    end
  end

  defp block_ops(tag, kind, kids, style, c, acc) do
    box = box(tag, c)
    acc = [{:gap, box.mt}, {:flush} | acc]

    if tag == "hr" do
      [{:hr}, {:gap, box.mb} | acc]
    else
      ref = make_ref()

      case box_spec(c, box, style) do
        nil ->
          # plain block: just insets
          acc = [{:inset, box.ml + box.pl, box.mr + box.pr} | acc]
          acc = if box.pt > 0, do: [{:pad, box.pt} | acc], else: acc
          acc = block_children(tag, kind, kids, style, acc)
          acc = [{:flush} | acc]
          acc = if box.pb > 0, do: [{:pad, box.pb} | acc], else: acc
          [{:gap, box.mb}, {:inset_end} | acc]

        spec ->
          acc = [{:box_start, ref, spec} | acc]
          acc = block_children(tag, kind, kids, style, acc)
          acc = [{:box_end, ref}, {:flush} | acc]
          [{:gap, box.mb} | acc]
      end
    end
  end

  # Boxes whose geometry must be resolved at placement: backgrounds, borders,
  # explicit widths/heights, `auto` margins, clipping and positioned boxes.
  defp box_spec(c, box, style) do
    {bt, br, bb, bl} = box.bw

    spec = %{
      ml: box.ml,
      mr: box.mr,
      pl: box.pl,
      pr: box.pr,
      pt: box.pt,
      pb: box.pb,
      bw: box.bw,
      bc: box.bc,
      width: dim(c["width"]),
      minw: c["min-width"],
      maxw: c["max-width"],
      sizing: if(c["box-sizing"] == "border-box", do: :border, else: :content),
      bg: box.bg,
      r: box.r,
      bgimg: box.bgimg,
      shadows: box.shadows,
      color: box.color,
      cid: style.cid,
      h: num(c["height"]),
      min: num(c["min-height"]),
      max: num(c["max-height"]),
      clip: clips?(c),
      pos: c["position"] in ["relative", "sticky"]
    }

    needed? =
      spec.bg || spec.bgimg || spec.shadows != [] || bt + br + bb + bl > 0 || spec.h || spec.min ||
        spec.max || spec.pos ||
        spec.clip || spec.width || spec.minw || spec.maxw || spec.ml == :auto ||
        spec.mr == :auto

    if needed?, do: spec
  end

  # `auto` is the same as no width/height for everything but images
  defp dim(:auto), do: nil
  defp dim(v), do: v

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
    type = li_style.list || if(list_tag == "ol", do: "decimal", else: "disc")
    ml = if box.ml == :auto, do: 0, else: box.ml
    mr = if box.mr == :auto, do: 0, else: box.mr

    acc = [{:inset, ml + box.pl, mr + box.pr}, {:gap, box.mt}, {:flush} | acc]
    acc = if type == "none", do: acc, else: [{:marker, marker(type, n), li_style} | acc]
    acc = walk(kids, li_style, acc)
    acc = [{:flush} | acc]
    [{:gap, box.mb}, {:inset_end} | acc]
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

  # margins, padding, borders and background of a block; computed values win
  # over tag defaults. Left/right margins may be :auto.
  defp box(tag, c) do
    gap = if tag in @legacy_gap_tags, do: @legacy_gap, else: 0
    legacy_ml = if tag == "blockquote", do: @legacy_indent, else: 0
    color = if match?({_, _, _}, c["color"]), do: c["color"], else: {0, 0, 0}

    %{
      mt: px(c["margin-top"] || gap),
      mb: px(c["margin-bottom"] || gap),
      ml: margin_x(c["margin-left"], legacy_ml),
      mr: margin_x(c["margin-right"], 0),
      pl: px(c["padding-left"] || if(tag in ~w(ul ol), do: @legacy_indent, else: 0)),
      pr: px(c["padding-right"] || 0),
      pt: px(c["padding-top"] || 0),
      pb: px(c["padding-bottom"] || 0),
      bw: {border_w(c, "top"), border_w(c, "right"), border_w(c, "bottom"), border_w(c, "left")},
      bc: {
        border_c(c, "top", color),
        border_c(c, "right", color),
        border_c(c, "bottom", color),
        border_c(c, "left", color)
      },
      bg: if(match?({_, _, _}, c["background-color"]), do: c["background-color"]),
      r: radii_spec(c),
      bgimg: bgimg_spec(c),
      shadows: c["box-shadow"] || [],
      color: color
    }
  end

  # the parsed background layers, or nil when there are no images or gradients
  defp bgimg_spec(c) do
    images = c["background-image"]

    if is_list(images) and Enum.any?(images, &(&1 != :none)) do
      %{
        images: images,
        repeat: c["background-repeat"] || [],
        position: c["background-position"] || [],
        size: c["background-size"] || []
      }
    end
  end

  # raw corner radii {tl, tr, br, bl}, each {horizontal, vertical} (px or {:pct, f})
  defp radii_spec(c) do
    corners =
      for k <- ~w(border-top-left-radius border-top-right-radius border-bottom-right-radius
                  border-bottom-left-radius),
          do: c[k]

    if Enum.any?(corners, & &1), do: corners |> Enum.map(&(&1 || {0, 0})) |> List.to_tuple()
  end

  defp margin_x(:auto, _legacy), do: :auto
  defp margin_x(nil, legacy), do: px(legacy)
  defp margin_x(v, _legacy), do: px(v)

  # a border takes space only when it has a style other than none/hidden
  defp border_w(c, side) do
    if c["border-#{side}-style"] in [nil, "none", "hidden"] do
      0
    else
      w = c["border-#{side}-width"] || 3.0
      if w > 0, do: max(round(w), 1), else: 0
    end
  end

  defp border_c(c, side, default) do
    case c["border-#{side}-color"] do
      {_, _, _} = rgb -> rgb
      :transparent -> nil
      _ -> default
    end
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
        t when t in ~w(textarea input) -> %{style | pre: true}
        "a" -> link_style(style, attrs)
        t when is_map_key(@headings, t) -> %{style | size: @headings[t], bold: true}
        _ -> style
      end

    style =
      case List.keyfind(attrs, "@cid", 0) do
        {_, cid} -> %{style | cid: cid}
        nil -> style
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
    |> put_if(c["line-height"], &%{&1 | lh: &2})
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

  # Preformatted text keeps its line breaks. A blank line holds a zero-width space so
  # it still takes a line; the empty tail after a final newline just ends the line.
  defp pre_text(t, style, acc) do
    lines = String.split(t, "\n")
    last = length(lines) - 1

    lines
    |> Enum.with_index()
    |> Enum.reduce(acc, fn {line, i}, a ->
      a = if i > 0, do: [{:flush} | a], else: a

      cond do
        line != "" -> [{:word, String.replace(line, "\t", "    "), style, :pre} | a]
        i == last -> a
        true -> [{:word, "\u200B", style, :pre} | a]
      end
    end)
  end

  # -- ops -> positioned items -------------------------------------------------------
  #
  # State of the line placer. Lines span `margin + left` .. `width - margin -
  # right`; blocks push insets onto `insets` and restore them when they end.
  # `pos` is the stack of containing-block origins (`%{x, y, w, h}`, bottom
  # entry = the page); `open` holds boxes between their start and end ops;
  # `n`/`nr` count items/rects so a box can find the ones created inside it;
  # `overlays` are laid-out absolute elements.

  defp place(ops, width, measure, view_height, images) do
    st = run(ops, width, measure, view_height, @margin, :view, true, images)
    {finalize(st), st.y + st.margin}
  end

  defp run(
         ops,
         width,
         measure,
         view_height,
         margin,
         root_height,
         aligned?,
         images
       ) do
    st = %{
      items: [],
      rects: [],
      n: 0,
      nr: 0,
      overlays: [],
      deferred: [],
      open: %{},
      pos: [
        %{x: 0, y: 0, w: width, h: if(root_height == :view, do: view_height, else: root_height)}
      ],
      left: 0,
      right: 0,
      insets: [],
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
      margin: margin,
      aligned?: aligned?,
      images: images,
      marks: [],
      active: [],
      lead: 0,
      line_lead: 0,
      lmax: 0
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
    st = word(m, style, true, st, -18)
    st = %{st | line: [Map.put(hd(st.line), :marker, true) | tl(st.line)]}
    %{st | pending_space: style}
  end

  # a list marker stays on the line of the content that follows it
  defp op({:flush}, %{line: [%{marker: true}]} = st), do: st
  defp op({:flush}, st), do: flush(st)

  defp op({:gap, _px}, %{line: [%{marker: true}]} = st), do: st
  defp op({:gap, px}, st), do: %{flush(st) | gap: max(st.gap, px)}

  defp op({:pad, px}, st), do: st |> flush() |> apply_gap() |> Map.update!(:y, &(&1 + px))

  defp op({:inset, l, r}, st) do
    %{st | insets: [{st.left, st.right} | st.insets], left: st.left + l, right: st.right + r}
  end

  defp op({:inset_end}, %{insets: [{l, r} | rest]} = st),
    do: %{st | insets: rest, left: l, right: r}

  defp op({:hr}, st) do
    st = st |> flush() |> apply_gap()

    item = %{
      type: :hr,
      x: st.margin + st.left,
      y: st.y,
      w: max(st.width - 2 * st.margin - st.left - st.right, 0)
    }

    %{st | items: [item | st.items], n: st.n + 1, y: st.y + 2}
  end

  defp op({:box_start, ref, o}, st), do: start_box(st, ref, o)

  defp op({:box_end, ref}, st) do
    st = flush(st)
    {box, open} = Map.pop(st.open, ref)
    {_bt, _br, bb, _bl} = box.o.bw
    st = %{st | open: open}

    # child margins stay inside the box only when padding or a border separates them
    st = if box.o.pb > 0 or bb > 0, do: apply_gap(st), else: st
    st = %{st | y: st.y + box.o.pb + bb}
    {l, r} = box.saved
    st = %{st | left: l, right: r}
    st = if box.o.pos, do: %{st | pos: tl(st.pos)}, else: st
    finish_box(st, box)
  end

  defp op({:inline_block, sub, spec, style}, st) do
    avail = max(st.width - 2 * st.margin - st.left - st.right, 0)
    w = fit_width(st, sub, spec, avail)
    {items, height, base} = layout_atom(st, sub, w)

    place_atom(st, %{
      w: w,
      h: height,
      base: base,
      items: items,
      align: style.align,
      valign: spec.valign
    })
  end

  # An image is a replaced element: an atom whose content is the picture inside
  # whatever box (border, padding, background, radius) the element has.
  defp op({:image, spec, style}, st) do
    avail = max(st.width - 2 * st.margin - st.left - st.right, 0)
    {cw, ch} = Browser.ImageBox.size(spec.intrinsic, spec.attrs, spec.css, avail)
    box = spec.box
    {bt, br, bb, bl} = box.bw
    ml = if box.ml == :auto, do: 0, else: box.ml
    mr = if box.mr == :auto, do: 0, else: box.mr

    box_w = bl + box.pl + cw + box.pr + br
    box_h = bt + box.pt + ch + box.pb + bb

    outer = %{
      o: %{bw: box.bw, bc: box.bc, bg: box.bg, r: box.r, cid: nil},
      x: ml,
      top: box.mt,
      w: box_w
    }

    picture =
      if spec.paint? and cw > 0 and ch > 0 do
        [
          %{
            type: :image,
            url: spec.url,
            x: ml + bl + box.pl,
            y: box.mt + bt + box.pt,
            w: cw,
            h: ch,
            href: spec.href,
            hidden: spec.hidden
          }
        ]
      else
        []
      end

    height = box.mt + box_h + box.mb

    place_atom(st, %{
      w: ml + box_w + mr,
      h: height,
      # the baseline of a replaced element is its bottom margin edge
      base: height,
      items: outer_rects(outer, box_h, st.images) ++ picture,
      align: style.align,
      valign: spec.valign
    })
  end

  # Opening an inline box adds its left margin/border/padding to the line and
  # records where its box starts. On an empty line the space is carried in
  # `lead` and applied when the first word of the line is placed.
  defp op({:inline_open, ref, spec}, st) do
    if st.line == [] do
      x = st.margin + st.left + st.lead + spec.ml

      %{
        st
        | lead: st.lead + spec.ml + spec.bl + spec.pl,
          marks: [{:start, ref, spec, x} | st.marks]
      }
    else
      space_w = if st.pending_space, do: st.measure.(" ", st.pending_space), else: 0
      x = st.x + space_w

      %{
        st
        | x: x + spec.ml + spec.bl + spec.pl,
          pending_space: nil,
          marks: [{:start, ref, spec, x + spec.ml} | st.marks]
      }
    end
  end

  defp op({:inline_close, ref, spec}, st) do
    right = spec.pr + spec.br

    if st.line == [] do
      x = st.margin + st.left + st.lead + right
      %{st | lead: st.lead + right + spec.mr, marks: [{:end, ref, x} | st.marks]}
    else
      %{st | x: st.x + right + spec.mr, marks: [{:end, ref, st.x + right} | st.marks]}
    end
  end

  defp op({:pos_inline}, st) do
    {x, y} =
      if st.line == [],
        do: {st.margin + st.left, st.y + st.gap},
        else: {st.x, st.y}

    push_pos(st, %{x: x, y: y, w: max(st.width - st.margin - st.right - x, 0), h: nil})
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

  # Puts an atomic inline box (`%{w, h, base, items, align, valign}`) on the line,
  # wrapping to a new line if it doesn't fit.
  defp place_atom(st, atom) do
    line_left = st.margin + st.left

    space_w =
      if st.pending_space && st.line != [], do: st.measure.(" ", st.pending_space), else: 0

    st = if st.line == [], do: st |> apply_gap() |> start_line(line_left, 0), else: st

    st =
      if st.line != [] and st.x + space_w + atom.w > st.width - st.margin - st.right do
        st |> flush() |> apply_gap() |> start_line(line_left, 0)
      else
        st
      end

    space_w = if st.line == [], do: 0, else: space_w
    x = st.x + space_w
    atom = atom |> Map.put(:type, :atom) |> Map.put(:x, x)
    %{st | line: [atom | st.line], x: x + atom.w, pending_space: nil}
  end

  # -- boxes: width, margins, borders, height, clipping ------------------------------------

  defp start_box(st, ref, o) do
    st = st |> flush() |> apply_gap()
    {bt, br, _bb, bl} = o.bw
    avail = max(st.width - 2 * st.margin - st.left - st.right, 0)
    hpad = o.pl + o.pr + bl + br

    # width properties are for the content box unless box-sizing is border-box
    to_content = fn
      nil -> nil
      v -> v |> resolve(avail) |> then(&if(o.sizing == :border, do: max(&1 - hpad, 0), else: &1))
    end

    ml0 = if o.ml == :auto, do: 0, else: o.ml
    mr0 = if o.mr == :auto, do: 0, else: o.mr

    cw = to_content.(o.width) || max(avail - ml0 - mr0 - hpad, 0)
    cw = if m = to_content.(o.maxw), do: min(cw, m), else: cw
    cw = if m = to_content.(o.minw), do: max(cw, m), else: cw
    box_w = hpad + cw
    free = avail - ml0 - mr0 - box_w

    {ml, _mr} =
      case {o.ml, o.mr} do
        {:auto, :auto} -> {max(div(free, 2), 0), max(free - div(free, 2), 0)}
        {:auto, _} -> {max(free, 0), mr0}
        {_, :auto} -> {ml0, max(free, 0)}
        _ -> {ml0, mr0}
      end

    left = st.left + ml
    rest = max(avail - ml - box_w, 0)
    x = st.margin + left

    box = %{
      ref: ref,
      o: o,
      top: st.y,
      x: x,
      w: box_w,
      n0: st.n,
      nr0: st.nr,
      saved: {st.left, st.right}
    }

    st = %{
      st
      | open: Map.put(st.open, ref, box),
        left: left + bl + o.pl,
        right: st.right + rest + br + o.pr,
        y: st.y + bt + o.pt
    }

    if o.pos do
      push_pos(st, %{x: x + bl, y: box.top + bt, w: max(box_w - bl - br, 0), h: nil, ref: ref})
    else
      st
    end
  end

  defp finish_box(st, %{o: o} = box) do
    {bt, br, bb, bl} = o.bw
    natural = st.y - box.top
    extra = bt + o.pt + o.pb + bb
    content = natural - extra

    # height properties size the content box unless box-sizing is border-box
    inner = fn v -> if o.sizing == :border, do: max(v - extra, 0), else: v end

    used = if o.h, do: inner.(o.h), else: content
    used = if o.max, do: min(used, inner.(o.max)), else: used
    used = if o.min, do: max(used, inner.(o.min)), else: used
    used = round(used)

    clipped? = o.clip and used < content
    # without clipping a too-small height just lets the content overflow the box
    height = if used < content and not clipped?, do: natural, else: used + extra

    limit = box.top + bt + o.pt + used
    st = if clipped?, do: drop_below(st, box, limit), else: st
    st = %{st | y: box.top + height}
    st = place_deferred(st, box, height)

    # overflow clips to the padding box
    clip = %{
      x: box.x + bl,
      y: box.top + bt,
      w: max(box.w - bl - br, 0),
      h: max(height - bt - bb, 0)
    }

    st = if o.clip, do: clip_new(st, box, clip), else: st

    # the box's own background and borders go under whatever is inside it
    outer = outer_rects(box, height, st.images)
    {new, old} = Enum.split(st.rects, st.nr - box.nr0)
    %{st | rects: new ++ Enum.reverse(outer) ++ old, nr: st.nr + length(outer)}
  end

  # items in paint order: background, then the four border sides. A box with
  # rounded corners is a single item carrying its radii and border data, for
  # the painter to draw as paths.
  defp outer_rects(%{o: o} = box, height, images) do
    items = plain_outer_rects(box, height, images)
    if o.cid, do: Enum.map(items, &Map.put(&1, :cid, o.cid)), else: items
  end

  # In paint order: outer shadows, background colour, background images, inset shadows,
  # then the borders. Without images or shadows this is just colour and borders.
  defp plain_outer_rects(%{o: o} = box, height, images) do
    {bt, br, bb, bl} = o.bw
    {tc, rc, bc, lc} = o.bc
    {x, y, w} = {box.x, box.top, box.w}
    border_box = {x, y, w, height}
    radii = resolve_radii(o.r, w, height)

    # images are positioned in the padding box and painted into the border box
    padding_box = {x + bl, y + bt, max(w - bl - br, 0), max(height - bt - bb, 0)}

    layers =
      if Map.get(o, :bgimg) && w > 0 && height > 0,
        do:
          Backgrounds.paint_layers(
            o.bgimg,
            padding_box,
            border_box,
            images,
            color4(Map.get(o, :color) || {0, 0, 0})
          ),
        else: []

    {inset, outer} = o |> Map.get(:shadows, []) |> Enum.split_with(& &1.inset?)

    shadows =
      for s <- Enum.reverse(outer),
          layers = Shadows.outer_layers(s, border_box, radii),
          layers != [] do
        {bx, by, bw, bh} = shadow_bounds(layers)
        %{type: :shadow, layers: layers, x: bx, y: by, w: bw, h: bh, radius: radii}
      end

    insets =
      for s <- Enum.reverse(inset),
          layers = Shadows.inset_layers(s, border_box, radii),
          layers != [] do
        %{type: :inset_shadow, layers: layers, x: x, y: y, w: w, h: height, radius: radii}
      end

    images_item =
      if layers == [],
        do: [],
        else: [%{type: :bgimage, layers: layers, x: x, y: y, w: w, h: height, radius: radii}]

    decorated? = images_item != [] or insets != []

    body =
      case radii do
        nil ->
          bg = if o.bg && w > 0 && height > 0, do: [rect(x, y, w, height, o.bg)], else: []

          sides = [
            bt > 0 && tc && rect(x, y, w, bt, tc),
            bb > 0 && bc && rect(x, y + height - bb, w, bb, bc),
            bl > 0 && lc && rect(x, y, bl, height, lc),
            br > 0 && rc && rect(x + w - br, y, br, height, rc)
          ]

          bg ++ images_item ++ insets ++ Enum.filter(sides, & &1)

        radii when decorated? ->
          # the border must be painted over the images and inset shadows
          rounded(x, y, w, height, o.bg, radii, {0, 0, 0, 0}, o.bc) ++
            images_item ++ insets ++ rounded(x, y, w, height, nil, radii, o.bw, o.bc)

        radii ->
          rounded(x, y, w, height, o.bg, radii, o.bw, o.bc)
      end

    shadows ++ body
  end

  # the box around all of a shadow's layers, so it is drawn whenever any of it is visible
  defp shadow_bounds(layers) do
    rects = Enum.map(layers, & &1.rect)
    x0 = rects |> Enum.map(&elem(&1, 0)) |> Enum.min()
    y0 = rects |> Enum.map(&elem(&1, 1)) |> Enum.min()
    x1 = rects |> Enum.map(fn {x, _, w, _} -> x + w end) |> Enum.max()
    y1 = rects |> Enum.map(fn {_, y, _, h} -> y + h end) |> Enum.max()
    {x0, y0, x1 - x0, y1 - y0}
  end

  defp rounded(x, y, w, h, bg, radii, bw, bc) do
    border = if bw == {0, 0, 0, 0}, do: nil, else: %{w: bw, c: bc}

    if w > 0 and h > 0 and (bg || border) do
      [%{type: :rect, x: x, y: y, w: w, h: h, color: bg, radius: radii, border: border}]
    else
      []
    end
  end

  # Corner radii in px for a box of `w` x `h`: {{rx, ry} for tl, tr, br, bl}, or
  # nil when no corner is rounded. Percentages are relative to the box, and radii
  # are scaled down together if neighbouring corners would overlap (CSS rule).
  defp resolve_radii(nil, _w, _h), do: nil

  defp resolve_radii({tl, tr, br, bl}, w, h) do
    [{tlx, tly}, {trx, try_}, {brx, bry}, {blx, bly}] =
      for {hv, vv} <- [tl, tr, br, bl], do: {radius_len(hv, w), radius_len(vv, h)}

    f =
      Enum.min([
        1.0,
        fit(w, tlx + trx),
        fit(w, blx + brx),
        fit(h, tly + bly),
        fit(h, try_ + bry)
      ])

    scale = fn {a, b} ->
      {a, b} = if f < 1.0, do: {floor(a * f), floor(b * f)}, else: {a, b}
      if a > 0 and b > 0, do: {a, b}, else: {0, 0}
    end

    radii = {scale.({tlx, tly}), scale.({trx, try_}), scale.({brx, bry}), scale.({blx, bly})}
    if radii == {{0, 0}, {0, 0}, {0, 0}, {0, 0}}, do: nil, else: radii
  end

  defp radius_len({:pct, f}, dim), do: round(f * dim)
  defp radius_len(n, _dim) when is_number(n), do: round(n)
  defp radius_len(_, _dim), do: 0

  defp fit(_len, 0), do: 1.0
  defp fit(len, sum), do: len / sum

  defp rect(x, y, w, h, color), do: %{type: :rect, x: x, y: y, w: w, h: h, color: color}

  defp place_deferred(st, box, height) do
    {mine, rest} = Enum.split_with(st.deferred, fn {ref, _, _} -> ref == box.ref end)
    {bt, br, bb, bl} = box.o.bw

    origin = %{
      x: box.x + bl,
      y: box.top + bt,
      w: max(box.w - bl - br, 0),
      h: max(height - bt - bb, 0)
    }

    mine
    |> Enum.reverse()
    |> Enum.reduce(%{st | deferred: rest}, fn {_, sub, spec}, acc ->
      place_absolute(acc, sub, spec, origin)
    end)
  end

  # drop whatever was created inside the box entirely below `limit`
  defp drop_below(st, box, limit) do
    {new_items, old_items} = Enum.split(st.items, st.n - box.n0)
    kept_items = Enum.filter(new_items, &(&1.y < limit))
    {new_rects, old_rects} = Enum.split(st.rects, st.nr - box.nr0)
    kept_rects = Enum.filter(new_rects, &(&1.y < limit))

    %{
      st
      | items: kept_items ++ old_items,
        n: box.n0 + length(kept_items),
        rects: kept_rects ++ old_rects,
        nr: box.nr0 + length(kept_rects)
    }
  end

  # items and rects created inside a clipping box get (intersected) clip rectangles
  defp clip_new(st, box, clip) do
    {new_items, old_items} = Enum.split(st.items, st.n - box.n0)
    {new_rects, old_rects} = Enum.split(st.rects, st.nr - box.nr0)

    %{
      st
      | items: Enum.map(new_items, &put_clip(&1, clip)) ++ old_items,
        rects: Enum.map(new_rects, &put_clip(&1, clip)) ++ old_rects
    }
  end

  defp put_clip(item, clip), do: Map.put(item, :clip, intersect(Map.get(item, :clip), clip))

  defp intersect(nil, b), do: b

  defp intersect(a, b) do
    x = max(a.x, b.x)
    y = max(a.y, b.y)

    %{
      x: x,
      y: y,
      w: max(min(a.x + a.w, b.x + b.w) - x, 0),
      h: max(min(a.y + a.h, b.y + b.h) - y, 0)
    }
  end

  # -- absolute / fixed positioning ------------------------------------------------------

  defp place_absolute(st, sub, spec, origin) do
    cw = origin.w

    {static_x, static_y} =
      if st.line == [],
        do: {st.margin + st.left, st.y + st.gap},
        else: {st.x, st.y}

    left = resolve_h(spec.left, cw)
    right = resolve_h(spec.right, cw)
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
    moved = for it <- items, do: move(it, x, y)
    %{st | overlays: [moved | st.overlays]}
  end

  # Moves an item, including the coordinates held inside it: the clip, the tiles and
  # clip of background layers, the shapes of shadows.
  defp move(it, dx, dy) do
    it = %{it | x: it.x + dx, y: it.y + dy}

    it =
      case it do
        %{clip: c} -> %{it | clip: shift_rect(c, dx, dy)}
        _ -> it
      end

    case it do
      %{type: :bgimage, layers: layers} ->
        %{it | layers: Enum.map(layers, &shift_layer(&1, dx, dy))}

      %{type: :shadow, layers: layers} ->
        %{it | layers: Enum.map(layers, &%{&1 | rect: shift_box(&1.rect, dx, dy)})}

      %{type: :inset_shadow, layers: layers} ->
        %{it | layers: Enum.map(layers, &shift_hole(&1, dx, dy))}

      _ ->
        it
    end
  end

  defp shift_rect(%{x: x, y: y} = c, dx, dy), do: %{c | x: x + dx, y: y + dy}
  defp shift_box({x, y, w, h}, dx, dy), do: {x + dx, y + dy, w, h}

  defp shift_layer(layer, dx, dy),
    do: %{layer | tile: shift_box(layer.tile, dx, dy), clip: shift_box(layer.clip, dx, dy)}

  defp shift_hole(%{hole: nil} = layer, _dx, _dy), do: layer

  defp shift_hole(%{hole: hole} = layer, dx, dy),
    do: %{layer | hole: %{hole | rect: shift_box(hole.rect, dx, dy)}}

  # vertical offsets: percentages need a known containing-block height
  defp resolve_v({:pct, _}, nil), do: nil
  defp resolve_v(v, h), do: resolve(v, h)
  defp resolve_h(v, w), do: resolve(v, w)

  defp resolve(nil, _base), do: nil
  defp resolve({:pct, f}, base), do: round(f * base)
  defp resolve(n, _base) when is_number(n), do: round(n)

  # -> {border-box width, x for the right/static placement}
  defp abs_width(st, sub, spec, origin, left, right, static_x) do
    cw = origin.w

    width =
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

          if left && right do
            avail
          else
            min(avail, shrink_extent(st, sub, avail) + spec.rextra)
          end

        w ->
          w + spec.extra + spec.mextra
      end

    width = clamp_width(width, spec, cw)
    {width, if(right && !left, do: origin.x + cw - right - width, else: static_x)}
  end

  defp clamp_width(width, spec, base) do
    width =
      case resolve(spec.maxw, base) do
        nil -> width
        m -> min(width, m + spec.extra + spec.mextra)
      end

    case resolve(spec.minw, base) do
      nil -> width
      m -> max(width, m + spec.extra + spec.mextra)
    end
  end

  # outer width of an inline-block: its width, or shrink-to-fit within `avail`
  defp fit_width(st, sub, spec, avail) do
    width =
      case resolve(spec.width, avail) do
        nil ->
          min(avail, shrink_extent(st, sub, max(avail, 1)) + spec.rextra)

        w ->
          w + spec.extra + spec.mextra
      end

    clamp_width(width, spec, avail)
  end

  # natural width of the content when wrapped at `width`: lines are measured
  # left-aligned, since centring inside the available width would inflate it
  defp shrink_extent(st, sub, width) do
    sub_st = run(sub, max(width, 1), st.measure, st.view_h, 0, nil, false, st.images)
    sub_st |> finalize() |> extent()
  end

  defp layout_sub(st, sub, width) do
    sub_st = run(sub, max(width, 1), st.measure, st.view_h, 0, nil, true, st.images)
    {finalize(sub_st), sub_st.y}
  end

  # An inline-block's content: laid out at `width`; returns its items (relative
  # to its top-left), its height including trailing margin, and its baseline
  # (bottom of the last text line, or the bottom edge if there is no text).
  defp layout_atom(st, sub, width) do
    sub_st = run(sub, max(width, 1), st.measure, st.view_h, 0, nil, true, st.images)
    height = sub_st.y + sub_st.gap
    items = finalize(sub_st)
    {items, height, last_baseline(items, height)}
  end

  defp last_baseline(items, height) do
    case Enum.filter(items, &(&1.type == :text)) do
      [] ->
        height

      texts ->
        last_y = texts |> Enum.map(& &1.y) |> Enum.max()
        for(%{y: ^last_y} = t <- texts, do: t.y + t.h) |> Enum.max()
    end
  end

  # right edge of the text, for shrink-to-fit
  defp extent(items) do
    items
    |> Enum.filter(&(&1.type == :text))
    |> Enum.map(&(&1.x + &1.w))
    |> Enum.max(fn -> 0 end)
  end

  # -- words and lines ------------------------------------------------------------------

  # the line-height of text in px: `normal` is the built-in 1.35, a number is a
  # factor of the font size
  defp line_px(%{lh: :normal, size: size}), do: round(size * 1.35)
  defp line_px(%{lh: {:num, f}, size: size}), do: round(f * size)
  defp line_px(%{lh: {:px, v}}), do: round(v)

  # A new line starts at `line_left` (a list marker hangs `dx` to the left). Space
  # owed by inline boxes opened on the empty line (`lead`) is applied to content.
  defp start_line(st, line_left, dx) do
    lead = if dx == 0, do: st.lead, else: 0

    %{
      st
      | x: line_left + dx + lead,
        indent: line_left,
        lead: st.lead - lead,
        line_lead: lead
    }
  end

  defp word(text, style, nowrap?, st, dx \\ 0) do
    w = st.measure.(text, style)
    line_left = st.margin + st.left

    space_w =
      if st.pending_space && st.line != [], do: st.measure.(" ", st.pending_space), else: 0

    st = if st.line == [], do: st |> apply_gap() |> start_line(line_left, dx), else: st

    st =
      if st.line != [] and not nowrap? and st.x + space_w + w > st.width - st.margin - st.right do
        st |> flush() |> apply_gap() |> start_line(line_left, 0)
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
      align: style.align,
      cid: style.cid
    }

    st = bridge(st, item, space_w)

    %{
      st
      | line: [item | st.line],
        x: x + w,
        pending_space: nil,
        lh: max(st.lh, style.size),
        lmax: max(st.lmax, line_px(style))
    }
  end

  # Extend the previous word over the gap when both belong to the same link or
  # the same decoration, so underlines and click targets are continuous.
  defp bridge(%{line: [%{type: :text} = prev | rest]} = st, item, gap) when gap > 0 do
    same_link = is_binary(item.href) and prev.href == item.href

    same_deco =
      (item.underline or item.strike) and prev.underline == item.underline and
        prev.strike == item.strike and prev.color == item.color

    if same_link or same_deco,
      do: %{st | line: [%{prev | w: prev.w + gap} | rest]},
      else: st
  end

  defp bridge(st, _item, _gap), do: st

  # Nothing on the line: boxes opened/closed here only change which boxes are
  # open. Newly opened ones are `pending` until a line with content paints them.
  defp flush(%{line: []} = st) do
    active =
      st.marks
      |> Enum.reverse()
      |> Enum.reduce(st.active, fn
        {:start, ref, spec, _x}, active -> active ++ [%{ref: ref, spec: spec, pending: true}]
        {:end, ref, _x}, active -> Enum.reject(active, &(&1.ref == ref))
      end)

    %{st | pending_space: nil, marks: [], active: active}
  end

  # A line holds words and inline-block atoms. Baseline-aligned atoms (the
  # default) put their baseline on the line's, which sits at the taller of the
  # text's and the atoms' ascent; the line grows to hold whatever hangs below.
  # Atoms with `vertical-align: top | bottom | middle` are placed afterwards
  # against the finished line, which they can only make taller.
  defp flush(st) do
    {atoms, texts} = Enum.split_with(st.line, &(&1.type == :atom))
    {floating, on_baseline} = Enum.split_with(atoms, &(&1.valign in ["top", "bottom", "middle"]))

    # `normal` height of the biggest text, and the height line-height gives the
    # line; the glyphs sit centred in the line, i.e. shifted by half the difference
    normal = if st.lh > 0, do: round(st.lh * 1.35), else: 0
    lh = if st.lh > 0, do: st.lmax, else: 0
    half = if st.lh > 0, do: div(lh - normal, 2), else: 0
    text_base = if st.lh > 0, do: half + normal - div(normal - st.lh, 4), else: 0

    base = Enum.reduce(on_baseline, text_base, &max(&2, &1.base))
    below = Enum.reduce(on_baseline, lh - text_base, &max(&2, &1.h - &1.base))
    line_h = Enum.reduce(floating, base + below, &max(&2, &1.h))
    shift = align_shift(Enum.reverse(st.line), st)
    dy = base - text_base

    placed =
      for it <- texts,
          do: %{
            it
            | x: it.x + shift,
              y: st.y + dy + half + normal - it.h - div(normal - it.h, 4)
          }

    top_of = fn
      %{valign: "top"} -> st.y
      %{valign: "bottom"} = a -> st.y + line_h - a.h
      %{valign: "middle"} = a -> st.y + base - round(st.lh * 0.3) - div(a.h, 2)
      a -> st.y + base - a.base
    end

    moved =
      for atom <- Enum.reverse(atoms),
          sub <- atom.items,
          do: move(sub, atom.x + shift, top_of.(atom))

    # everything a box paints behind its text: colours, borders, images, shadows
    {rects, others} = Enum.split_with(moved, &(&1.type in @behind_text))
    new_items = Enum.reverse(others) ++ placed

    ctx = %{
      shift: shift,
      first_x: st.line |> List.last() |> Map.fetch!(:x),
      last_right: (fn l -> l.x + l.w end).(hd(st.line)),
      y_ref: fn size ->
        if normal > 0,
          do: st.y + dy + half + normal - size - div(normal - size, 4),
          else: st.y + base - size
      end
    }

    {boxes, active, carried, lead} = inline_boxes(st, ctx)
    # `boxes` is already newest-first like st.rects
    all_rects = Enum.reverse(rects) ++ boxes

    %{
      st
      | items: new_items ++ st.items,
        n: st.n + length(new_items),
        rects: all_rects ++ st.rects,
        nr: st.nr + length(rects) + length(boxes),
        line: [],
        y: st.y + line_h,
        lh: 0,
        lmax: 0,
        x: st.indent,
        pending_space: nil,
        marks: carried,
        active: active,
        lead: lead
    }
  end

  # -- inline boxes -----------------------------------------------------------------
  #
  # `marks` (newest first) say where inline boxes start and end on this line;
  # `active` are boxes still open from earlier lines. Every box open on the line
  # gets one fragment: background plus top/bottom borders, the left border only
  # on its first fragment and the right border only on its last.
  #
  # -> {rects in reverse paint order, boxes still open, marks carried to the next
  #     line, lead for the next line}
  defp inline_boxes(%{marks: [], active: []} = st, _ctx), do: {[], [], [], st.lead}

  defp inline_boxes(st, ctx) do
    ended = for {:end, ref, _} <- st.marks, into: MapSet.new(), do: ref

    # boxes opened on an empty line sit just before the first word's lead
    {open0, _} =
      Enum.map_reduce(Enum.with_index(st.active), st.indent, fn {e, i}, running ->
        if Map.get(e, :pending) do
          x = running + e.spec.ml
          {%{ref: e.ref, spec: e.spec, x: x, first?: true, seq: i}, x + e.spec.bl + e.spec.pl}
        else
          {%{ref: e.ref, spec: e.spec, x: nil, first?: false, seq: i}, running}
        end
      end)

    {open, done, carried, lead, _} =
      st.marks
      |> Enum.reverse()
      |> Enum.reduce({open0, [], [], st.lead, length(open0)}, fn
        {:start, ref, spec, x}, {open, done, carried, lead, seq} ->
          if x >= ctx.last_right and not MapSet.member?(ended, ref) do
            # no content after the box's start on this line: it starts on the next one
            mark = {:start, ref, spec, st.indent + lead + spec.ml}
            {open, done, [mark | carried], lead + spec.ml + spec.bl + spec.pl, seq}
          else
            box = %{ref: ref, spec: spec, x: x, first?: true, seq: seq}
            {open ++ [box], done, carried, lead, seq + 1}
          end

        {:end, ref, x}, {open, done, carried, lead, seq} ->
          case Enum.split_with(open, &(&1.ref == ref)) do
            {[box], rest} -> {rest, [{box, x, true} | done], carried, lead, seq}
            {[], _} -> {open, done, carried, lead, seq}
          end
      end)

    done = Enum.reduce(open, done, fn box, acc -> [{box, ctx.last_right, false} | acc] end)

    boxes =
      done
      |> Enum.sort_by(fn {box, _, _} -> box.seq end)
      |> Enum.flat_map(fn {box, x1, last?} -> fragment(box, x1, last?, ctx) end)

    still_open = for box <- open, do: %{ref: box.ref, spec: box.spec}
    {Enum.reverse(boxes), still_open, carried, lead}
  end

  defp fragment(%{spec: %{paint: false}}, _x1, _last?, _ctx), do: []

  defp fragment(%{spec: spec} = box, x1, last?, ctx) do
    x0 = (box.x || ctx.first_x) + ctx.shift
    w = x1 + ctx.shift - x0
    y = ctx.y_ref.(spec.size) - spec.pt - spec.bt
    h = round(spec.size * 1.2) + spec.pt + spec.pb + spec.bt + spec.bb
    {tc, rc, bc, lc} = spec.bc
    # a box broken over lines keeps its left edge on the first fragment only and
    # its right edge on the last one
    bl = if box.first?, do: spec.bl, else: 0
    br = if last?, do: spec.br, else: 0

    cond do
      w <= 0 ->
        []

      radii = resolve_radii(spec.r, w, h) |> cut_corners(box.first?, last?) ->
        rounded(x0, y, w, h, spec.bg, radii, {spec.bt, br, spec.bb, bl}, spec.bc)

      true ->
        sides = [
          spec.bt > 0 && tc && rect(x0, y, w, spec.bt, tc),
          spec.bb > 0 && bc && rect(x0, y + h - spec.bb, w, spec.bb, bc),
          bl > 0 && lc && rect(x0, y, bl, h, lc),
          br > 0 && rc && rect(x0 + w - br, y, br, h, rc)
        ]

        bg = if spec.bg, do: [rect(x0, y, w, h, spec.bg)], else: []
        bg ++ Enum.filter(sides, & &1)
    end
  end

  # fragments that continue on another line have square edges on that side
  defp cut_corners(nil, _first?, _last?), do: nil

  defp cut_corners({tl, tr, br, bl}, first?, last?) do
    {tl, bl} = if first?, do: {tl, bl}, else: {{0, 0}, {0, 0}}
    {tr, br} = if last?, do: {tr, br}, else: {{0, 0}, {0, 0}}
    radii = {tl, tr, br, bl}
    if radii == {{0, 0}, {0, 0}, {0, 0}, {0, 0}}, do: nil, else: radii
  end

  defp align_shift(_items, %{aligned?: false}), do: 0

  defp align_shift([first | _] = items, st) do
    last = List.last(items)
    # the line runs from its start (inline-box lead included) to wherever the
    # last box's padding/border ends, which `st.x` tracks
    left = min(first.x, st.indent)
    right = max(last.x + last.w, st.x)
    free = st.width - st.margin - st.right - st.indent - (right - left)

    case first.align do
      :center -> max(round(free / 2), 0)
      :right -> max(round(free), 0)
      :left -> 0
    end
  end
end
