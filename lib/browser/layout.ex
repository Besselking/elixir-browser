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
  # a font's content height (ascent plus descent) over its size, for when nothing measures it
  @content_factor 1.35
  @legacy_gap 10
  @legacy_indent 28
  # the width a box is laid out at to find how wide its content wants to be
  @unbounded 100_000

  @skip ~w(head script style title template)

  @block_tags ~w(address article aside blockquote body center details dialog dd div dl dt
                 fieldset figcaption figure footer form h1 h2 h3 h4 h5 h6 header hgroup hr html
                 legend main menu nav ol p pre section summary ul table caption tr thead tbody
                 tfoot)
  @legacy_gap_tags ~w(p ul ol pre h1 h2 h3 h4 h5 h6 blockquote)
  @headings %{"h1" => 32, "h2" => 24, "h3" => 19, "h4" => 16, "h5" => 13, "h6" => 11}
  # Fonts we can tell apart in a font-family list. Names of web fonts (which are not loaded)
  # are skipped: the first font we know decides, as with the fonts a browser has installed.
  @mono_fonts [
    "monospace",
    "ui-monospace",
    "sfmono-regular",
    "sf mono",
    "menlo",
    "monaco",
    "consolas",
    "courier",
    "courier new",
    "liberation mono",
    "dejavu sans mono",
    "lucida console"
  ]
  @proportional_fonts [
    "sans-serif",
    "serif",
    "system-ui",
    "ui-sans-serif",
    "ui-serif",
    "ui-rounded",
    "-apple-system",
    "blinkmacsystemfont",
    "segoe ui",
    "roboto",
    "helvetica",
    "helvetica neue",
    "arial",
    "times",
    "times new roman",
    "georgia",
    "verdana",
    "tahoma",
    "cursive",
    "fantasy"
  ]

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

  Option `metrics: (style -> content_height_px)` gives the height of a font's glyphs (its
  `normal` line-height); without it text is taken to be 1.35 times its size.

  Option `focus: %{cid: id, caret: {line, column}}` adds a `:ring` item around the
  focused form control and a `:caret` item at the given position of its text.
  """
  def layout(nodes, width, measure, view_height \\ 768, opts \\ []) do
    style = %{
      size: @base,
      bold: false,
      italic: false,
      mono: false,
      family: nil,
      href: nil,
      pre: false,
      ws: :normal,
      tab: 8,
      hidden: false,
      color: {0, 0, 0},
      underline: false,
      strike: false,
      align: :left,
      # the direction of the text; of the block it is in (`cb`), which settles where a box
      # that is over-constrained goes, and of the block its parent is in (`prtl`)
      rtl: false,
      cb: false,
      prtl: false,
      list: nil,
      lh: :normal,
      cid: nil,
      nid: nil,
      images: Keyword.get(opts, :images),
      svg_defs: Keyword.get(opts, :svg_defs, %{})
    }

    # what percentage margins and padding refer to, as the walk goes down the tree
    margin = Keyword.get(opts, :margin, @margin)
    Process.put(:layout_cw, max(width - 2 * margin, 0))
    Process.put(:layout_memo, %{})
    Process.put(:layout_metrics, opts[:metrics])
    {nodes, canvas} = propagate_background(nodes)
    t0 = System.monotonic_time(:microsecond)
    ops = nodes |> walk(style, []) |> Enum.reverse()
    t1 = System.monotonic_time(:microsecond)
    {items, height} = place(ops, width, measure, view_height, opts[:images], margin)

    if System.get_env("LAYOUT_TIMES"),
      do:
        IO.puts(
          :stderr,
          "walk #{div(t1 - t0, 1000)}ms place #{div(System.monotonic_time(:microsecond) - t1, 1000)}ms ops=#{length(ops)}"
        )

    # absolutely positioned boxes take no room in the flow but do extend the scrollable page
    height = max(height, content_bottom(items))
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

  defp add_focus(items, measure, %{cid: cid, caret: caret} = focus) do
    texts =
      items
      |> Enum.filter(&(&1.type == :text and Map.get(&1, :cid) == cid))
      |> Enum.sort_by(&{&1.y, &1.x})

    # the box item is clipped by ancestors only: the control's own clip applies to its text
    clip =
      Enum.find_value(
        items,
        &((Map.get(&1, :cid) == cid and &1.type in [:rect, :box]) && Map.get(&1, :clip))
      )

    ring =
      case controls(items)[cid] do
        nil ->
          []

        b ->
          b = within(b, clip)

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

    # a control in a sticky or fixed box has its ring and caret there too
    stick = Enum.find_value(items, &(Map.get(&1, :cid) == cid && Map.get(&1, :stick)))
    extra = selection_items(texts, cid, focus[:sel], measure) ++ ring ++ caret
    extra = if stick, do: Enum.map(extra, &Map.put(&1, :stick, stick)), else: extra
    items ++ extra
  end

  # The highlight of the text selected in the focused field: `sel` is `{from, to}` with
  # positions `{line, column}` relative to what the field shows (lines may fall outside it).
  defp selection_items(_texts, _cid, nil, _measure), do: []

  defp selection_items(texts, cid, {{fl, fc}, {tl, tc}}, measure) do
    for {it, line} <- Enum.with_index(texts),
        line >= fl and line <= tl,
        len = String.length(it.text),
        it.text != "\u200B",
        s = if(line == fl, do: min(fc, len), else: 0),
        e = if(line == tl, do: min(tc, len), else: len),
        e > s do
      x0 = it.x + prefix_width(it, s, measure)
      x1 = it.x + prefix_width(it, e, measure)

      item = %{
        type: :selection,
        x: round(x0),
        y: it.y,
        w: max(round(x1 - x0), 1),
        h: round(it.h * 1.25),
        cid: cid
      }

      if clip = Map.get(it, :clip), do: Map.put(item, :clip, clip), else: item
    end
  end

  defp prefix_width(_it, 0, _measure), do: 0
  defp prefix_width(it, n, measure), do: measure.(String.slice(it.text, 0, n), it)

  # a control wider than the box that clips it (overflow: hidden) is only seen inside that box
  defp within(b, nil), do: b

  defp within(b, clip) do
    x0 = max(b.x, clip.x)
    y0 = max(b.y, clip.y)
    x1 = min(b.x + b.w, clip.x + clip.w)
    y1 = min(b.y + b.h, clip.y + clip.h)
    if x1 > x0 and y1 > y0, do: %{b | x: x0, y: y0, w: x1 - x0, h: y1 - y0}, else: b
  end

  @doc """
  Updates `items` (from `layout/5`) after the text of one single-line field changed from
  `old_text` to `new_text`, without laying the page out again. Returns `{:ok, items}`, or
  `:error` when only a full layout can be trusted: the field's text isn't exactly one
  left-aligned item showing `old_text`, or the new text wouldn't fit the field on one line
  (a field's box doesn't depend on its text, so when it fits, nothing else moves).

  `focus` is as for the `:focus` option of `layout/5`; the ring and caret are redone.
  """
  def patch_field(items, cid, old_text, new_text, focus, measure) do
    mine = fn it -> Map.get(it, :cid) == cid end

    with [%{text: ^old_text, align: :left} = item] when old_text != "" and new_text != "" <-
           Enum.filter(items, &(&1.type == :text and mine.(&1))),
         %{w: box_w} <- controls(items)[cid],
         width = measure.(new_text, item),
         true <- width <= box_w - 8 do
      items =
        for it <- items, not (it.type in [:ring, :caret, :selection] and mine.(it)) do
          if it.type == :text and mine.(it), do: %{it | text: new_text, w: width}, else: it
        end

      {:ok, add_focus(items, measure, focus)}
    else
      _ -> :error
    end
  end

  defp grow(nil, _by), do: nil

  defp grow(radii, by) do
    radii
    |> Tuple.to_list()
    |> Enum.map(fn {rx, ry} -> if rx > 0 and ry > 0, do: {rx + by, ry + by}, else: {0, 0} end)
    |> List.to_tuple()
  end

  @doc """
  How far down the laid out page extends (inside the boxes that clip it): the bottom of
  what is drawn.
  """
  def content_bottom(items) do
    items
    |> Enum.filter(
      &(&1.type in [:text, :rect, :image, :svg, :hr] and not Map.get(&1, :hidden, false))
    )
    |> Enum.reduce(0, fn item, acc ->
      bottom = item.y + Map.get(item, :h, 0)
      bottom = if clip = Map.get(item, :clip), do: min(bottom, clip.y + clip.h), else: bottom
      max(acc, bottom)
    end)
  end

  @doc """
  How far right the laid out page extends: the right edge of what is drawn (inside the boxes
  that clip it), and at least `width`. A wider page scrolls sideways.
  """
  def content_width(items, width) do
    items
    |> Enum.filter(
      &(&1.type in [:text, :rect, :image, :svg, :hr] and not Map.get(&1, :hidden, false))
    )
    |> Enum.reduce(width, fn item, acc ->
      right = item.x + Map.get(item, :w, 0)
      right = if clip = Map.get(item, :clip), do: min(right, clip.x + clip.w), else: right
      max(acc, right)
    end)
  end

  @doc """
  Bounds of every form control that appears in `items`: `%{cid => %{x, y, w, h, radius}}`.
  A control is its border box (its largest rect), or the box around its text if it has none.
  """
  def controls(items) do
    items
    |> Enum.filter(&(Map.get(&1, :cid) != nil and &1.type in [:rect, :box, :text]))
    |> Enum.group_by(& &1.cid)
    |> Map.new(fn {cid, its} -> {cid, bounds(its)} end)
  end

  # the font of the control's text, for measuring it
  defp font_of(items) do
    case Enum.find(items, &(&1.type == :text)) do
      nil -> nil
      it -> Map.take(it, [:size, :bold, :italic, :mono, :family])
    end
  end

  defp bounds(items) do
    case Enum.filter(items, &(&1.type in [:rect, :box])) do
      [] ->
        x0 = items |> Enum.map(& &1.x) |> Enum.min()
        y0 = items |> Enum.map(& &1.y) |> Enum.min()
        x1 = items |> Enum.map(&(&1.x + &1.w)) |> Enum.max()
        y1 = items |> Enum.map(&(&1.y + round(&1.h * 1.25))) |> Enum.max()

        %{
          x: x0,
          y: y0,
          w: x1 - x0,
          h: y1 - y0,
          radius: nil,
          font: font_of(items),
          stick: stick_of(items)
        }

      rects ->
        r = Enum.max_by(rects, &(&1.w * &1.h))

        %{
          x: r.x,
          y: r.y,
          w: r.w,
          h: r.h,
          radius: Map.get(r, :radius),
          font: font_of(items),
          stick: stick_of(items)
        }
    end
  end

  # set when the control sits in a sticky or fixed box (see `Browser.UI.stick_shift/2`)
  defp stick_of(items), do: Enum.find_value(items, &Map.get(&1, :stick))

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

  defp has_background?(c), do: color?(c["background-color"]) or bgimg_spec(c) != nil

  # an opaque `{r, g, b}` or translucent `{r, g, b, a}` colour
  defp color?({_, _, _}), do: true
  defp color?({_, _, _, _}), do: true
  defp color?(_), do: false

  # the canvas is painted first, over white: a translucent colour is blended with it
  defp over_white({r, g, b, a}) do
    f = a / 255
    {round(r * f + 255 * (1 - f)), round(g * f + 255 * (1 - f)), round(b * f + 255 * (1 - f))}
  end

  defp over_white(c), do: c

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
      color: if(color?(c["background-color"]), do: over_white(c["background-color"])),
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
  defp color4(_), do: {0, 0, 0, 255}

  # -- tree -> ops ---------------------------------------------------------------
  #
  # ops: {:word, text, style[, :pre]} {:space, style} {:marker, text, style}
  #      {:flush} {:gap, px} {:pad, px} {:hr} {:box_start, ref, color, left} {:box_end, ref}

  defp walk(nodes, style, acc) when is_list(nodes),
    do: nodes |> wrap_table_parts() |> Enum.reduce(acc, &walk(&1, style, &2))

  # a soft hyphen (U+00AD) is invisible unless a line breaks at it; breaking there is not
  # supported yet, so it is dropped from the laid-out text (the DOM text keeps it)
  defp walk({:text, t}, style, acc) when is_binary(t) do
    if String.contains?(t, "\u00AD"),
      do: walk({:text, String.replace(t, "\u00AD", "")}, style, acc),
      else: walk_text(t, style, acc)
  end

  defp walk({:element, tag, _, _}, _style, acc) when tag in @skip, do: acc
  defp walk({:element, "br", _, _}, style, acc), do: [{:br, style} | acc]

  defp walk({:element, tag, attrs, _} = el, style, acc) when tag in ["img", "svg"] do
    ops = fn acc ->
      if tag == "img", do: image_ops(el, style, acc), else: svg_ops(el, style, acc)
    end

    c = computed(attrs)

    case float_side(c) do
      nil ->
        cond do
          c["position"] in ["absolute", "fixed"] ->
            abs_ops(el, style, c, acc)

          c["position"] == "relative" ->
            rel = %{top: c["top"], bottom: c["bottom"], left: c["left"], right: c["right"]}
            acc = [{:pos_inline, rel} | acc]
            [{:pos_end} | ops.(acc)]

          true ->
            ops.(acc)
        end

      side ->
        # a floated picture is sized by its own content, like any float
        sub = [] |> ops.() |> Enum.reverse()

        spec = %{
          key: make_ref(),
          width: nil,
          minw: nil,
          maxw: nil,
          extra: 0,
          mextra: 0,
          rextra: 0,
          valign: nil,
          table?: false
        }

        [{:float, side, sub, spec, style} | acc]
    end
  end

  defp walk(el, style, acc), do: walk_element(el, style, acc, nil)

  defp walk_element({:element, tag, attrs, kids} = el, parent_style, acc, force) do
    c = computed(attrs)

    if c["position"] in ["absolute", "fixed"] and force not in [:abs_inner, :inline_inner] do
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

      fit? = c["width"] == :fit and kind in [:block, :flex, :grid]
      table? = kind == :table and force != :inline_inner
      float? = force == nil and c["float"] in ["left", "right"]

      case kind do
        _ when float? ->
          float_ops(el, parent_style, c, acc)

        :contents ->
          walk(kids, style, acc)

        :inline ->
          inline_ops(tag, kids, style, c, acc)

        :inline_block ->
          hoist_atom(inline_block_ops(el, parent_style, c, acc))

        # `width: fit-content`: a block as wide as its content, on a line of its own
        _ when fit? ->
          acc = [{:flush} | acc]
          acc = hoist_atom(inline_block_ops(el, parent_style, c, acc, true))
          [{:flush} | acc]

        # a table is as wide as its columns need, on a line of its own
        _ when table? ->
          acc = [{:flush} | acc]
          acc = hoist_atom(inline_block_ops(el, parent_style, c, acc, true, true))
          [{:flush} | acc]

        kind ->
          # an element that can be linked to (`#id`) needs to know where its box starts, which
          # nothing drawn says for a plain block
          c = if List.keymember?(attrs, "id", 0), do: Map.put(c, :anchor, true), else: c
          block_ops(tag, kind, kids, style, c, acc)
      end
    end
  end

  # An out-of-flow element is laid out on its own and placed by `place/4`
  # relative to its containing block; it takes no space in the flow. Its width
  # properties belong to the placement, so they are removed from the element's
  # own box.
  defp image_sub({:element, "img", _, _} = el, style), do: image_ops(el, style, [])
  defp image_sub(el, style), do: svg_ops(el, style, [])

  defp abs_ops({:element, tag, attrs, kids}, parent_style, c, acc) do
    if hidden?(c) do
      acc
    else
      box = box(tag, c)
      # a picture is sized by its own width and height: they stay with it
      replaced? = tag in ["img", "svg"]

      own =
        Map.drop(
          c,
          cond do
            replaced? -> ~w(margin-left margin-right)
            # a table's width is its own, as well as what places it
            kind(tag, c) == :table -> ~w(margin-left margin-right)
            true -> ~w(width min-width max-width margin-left margin-right)
          end
        )

      attrs = List.keyreplace(attrs, "@computed", 0, {"@computed", own})
      el = {:element, tag, attrs, kids}

      sub =
        if replaced? do
          el |> image_sub(parent_style) |> Enum.reverse()
        else
          el |> walk_element(parent_style, [], :abs_inner) |> Enum.reverse()
        end

      {_, br, _, bl} = box.bw
      border_box? = c["box-sizing"] == "border-box"

      spec = %{
        key: make_ref(),
        top: c["top"],
        left: c["left"],
        right: c["right"],
        bottom: c["bottom"],
        width: if(replaced?, do: nil, else: dim(c["width"])),
        replaced: replaced?,
        minw: if(replaced?, do: nil, else: c["min-width"]),
        maxw: if(replaced?, do: nil, else: c["max-width"]),
        ml: box.ml,
        mr: box.mr,
        rtl: parent_style.cb,
        # width properties size the content box unless box-sizing says otherwise
        extra: if(border_box?, do: 0, else: box.pl + box.pr + bl + br),
        rextra: box.pr + br,
        mextra: 0,
        fixed: c["position"] == "fixed",
        autoh: not replaced? and c["height"] in [nil, :auto] and c["max-height"] != :fit,
        mta: c["margin-top"] == :auto,
        mba: c["margin-bottom"] == :auto,
        mb: box.mb,
        hpct:
          case c["height"] do
            {:pct, f} -> f
            _ -> nil
          end,
        z: z_index(c),
        translate: translate_of(c)
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

      match?({:svg, _, _, _}, info) ->
        {:svg, w, h, scene} = info
        extra = %{scene: scene, intrinsic: {w, h}, paint?: true, current: color4(c["color"])}
        image_atom(url, nil, attrs, c, style, acc, extra)

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

  @doc """
  True when none of the `<img>` elements showing `url` change size when the picture
  loads: each has a width and a height of its own (attributes or CSS). Laying the page
  out again after such a picture arrives would give the same boxes, so a repaint is enough.
  """
  @spec image_size_fixed?([term] | term, String.t()) :: boolean
  def image_size_fixed?(nodes, url) when is_list(nodes),
    do: Enum.all?(nodes, &image_size_fixed?(&1, url))

  def image_size_fixed?({:element, "img", attrs, _}, url) do
    attr_value(attrs, "@src") != url or
      Browser.ImageBox.fixed?(
        declared_size(attrs) || %{w: nil, h: nil},
        image_css(computed(attrs))
      )
  end

  def image_size_fixed?({:element, _tag, _attrs, kids}, url), do: image_size_fixed?(kids, url)
  def image_size_fixed?(_text, _url), do: true

  defp image_css(c) do
    %{
      w: c["width"],
      h: c["height"],
      minw: c["min-width"],
      maxw: c["max-width"],
      minh: c["min-height"],
      maxh: c["max-height"]
    }
  end

  defp declared_size(attrs) do
    w = attr_width(attrs)
    h = attr_int(attrs, "height")
    if w || h, do: %{w: w, h: h}
  end

  # a width attribute may be a percentage of the container
  defp attr_width(attrs) do
    case Integer.parse(attr_value(attrs, "width")) do
      {n, "%" <> _} when n >= 0 -> {:pct, n / 100}
      {n, _} when n >= 0 -> n
      _ -> nil
    end
  end

  defp attr_int(attrs, name) do
    case Integer.parse(attr_value(attrs, name)) do
      {n, _} when n >= 0 -> n
      _ -> nil
    end
  end

  defp attr_value(attrs, name), do: List.keyfind(attrs, name, 0, {nil, ""}) |> elem(1)

  # An inline <svg> is a replaced element too. Its width/height attributes size it (a
  # percentage is relative to the container); with only a viewBox it fills the width.
  defp svg_ops({:element, "svg", attrs, _} = el, parent_style, acc) do
    c = computed(attrs)
    style = restyle("svg", attrs, parent_style, c)
    scene = Browser.Svg.from_element(el, parent_style.svg_defs)
    {iw, ih} = Browser.Svg.intrinsic(scene)

    c =
      Enum.reduce([{"width", scene.width}, {"height", scene.height}], c, fn
        {prop, {:pct, _} = pct}, c -> Map.put_new(c, prop, pct)
        _, c -> c
      end)

    num = fn v -> if is_number(v), do: v end

    fill_ratio =
      case scene do
        %{width: nil, height: nil, viewbox: {_, _, vw, vh}} -> vh / vw
        _ -> nil
      end

    extra = %{
      scene: scene,
      intrinsic: {iw, ih},
      fill_ratio: fill_ratio,
      paint?: true,
      attrs: %{w: num.(scene.width), h: num.(scene.height)},
      current: color4(c["color"]),
      tag: "svg"
    }

    image_atom(nil, nil, attrs, c, style, acc, extra)
  end

  defp image_atom(url, info, attrs, c, style, acc, extra \\ %{}) do
    tag = Map.get(extra, :tag, "img")
    kind = kind(tag, c)
    block? = kind in [:block, :list_item, :flex, :grid]
    box = box(tag, c)

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

    declared = declared_size(attrs) || %{w: nil, h: nil}

    spec = %{
      url: url,
      intrinsic: with({:ok, w, h} <- info, do: {w, h}, else: (_ -> nil)),
      # a picture still loading whose box is already known gets its (not yet drawable) item
      # now, so that the page does not need another layout when the picture arrives
      paint?: info != nil or (url != nil and Browser.ImageBox.fixed?(declared, image_css(c))),
      attrs: declared,
      css: image_css(c),
      box: box,
      href: style.href,
      hidden: style.hidden,
      nid: style.nid,
      # a block-level picture sits on a line of its own: vertical-align does not apply
      valign: if(block?, do: nil, else: c["vertical-align"]),
      xform: xform_spec(c)
    }

    spec = Map.merge(spec, extra)

    Enum.reverse(before) ++
      [{:image, spec, %{style | align: align}}] ++ Enum.reverse(after_) ++ acc
  end

  defp blockify(kind) when kind in [:inline, :contents, :inline_block], do: :block
  defp blockify(kind), do: kind

  # the box an inline-block establishes inside itself
  defp inner_kind(c) do
    case c["display"] do
      d when d in ["flex", "inline-flex"] -> :flex
      d when d in ["grid", "inline-grid"] -> :grid
      d when d in ["table", "inline-table"] -> :table
      _ -> :block
    end
  end

  # An inline-block is laid out on its own (a block inside) and then placed in
  # the line as one unit; its width properties size the unit, so they are
  # removed from the element's own box.
  defp inline_block_ops(
         {:element, tag, attrs, kids},
         parent_style,
         c,
         acc,
         block? \\ false,
         table? \\ false
       ) do
    box = box(tag, c)
    ml = if box.ml == :auto, do: 0, else: box.ml
    mr = if box.mr == :auto, do: 0, else: box.mr

    own =
      c
      |> resolve_box_pct(containing_width())
      |> Map.drop(~w(width min-width max-width))
      |> Map.merge(%{"margin-left" => ml * 1.0, "margin-right" => mr * 1.0})

    attrs = List.keyreplace(attrs, "@computed", 0, {"@computed", own})

    # a box with a width of its own is what its children's percentages refer to
    {_, br, _, bl} = box.bw
    outer = containing_width()

    reference =
      case dim(c["width"]) do
        nil ->
          outer

        w ->
          sized_by(w, outer) +
            if(c["box-sizing"] == "border-box", do: 0, else: box.pl + box.pr + bl + br) + ml + mr
      end

    sub =
      with_cw(reference, fn ->
        {:element, tag, attrs, kids}
        |> walk_element(parent_style, [], :inline_inner)
        |> Enum.reverse()
      end)

    spec = %{
      key: make_ref(),
      width: dim(c["width"]),
      minw: c["min-width"],
      maxw: c["max-width"],
      extra: if(c["box-sizing"] == "border-box", do: 0, else: box.pl + box.pr + bl + br),
      mextra: ml + mr,
      rextra: box.pr + br + mr,
      valign: c["vertical-align"],
      table?: table?,
      # a block-level box with auto side margins sits in the middle (or at the right)
      malign:
        cond do
          not block? -> nil
          box.ml == :auto and box.mr == :auto -> :center
          box.ml == :auto -> :right
          true -> nil
        end
    }

    [{:inline_block, sub, spec, parent_style} | acc]
  end

  # out-of-flow boxes with no positioned ancestor inside the atom are placed against what
  # contains the atom, not against it
  defp hoist_atom([{:inline_block, sub, spec, ps} | acc]) do
    {escaped, sub} = hoist_abs(sub)
    [{:inline_block, sub, spec, ps} | Enum.reduce(escaped, acc, &[&1 | &2])]
  end

  # splits the absolute boxes whose containing block is outside of `ops` from the rest
  defp hoist_abs(ops) do
    {kept, escaped, _} =
      Enum.reduce(ops, {[], [], {0, []}}, fn
        {:abs, _, %{fixed: false}} = a, {kept, esc, {0, _} = d} ->
          {kept, [a | esc], d}

        op, {kept, esc, d} ->
          {[op | kept], esc, track_pos(op, d)}
      end)

    {Enum.reverse(escaped), Enum.reverse(kept)}
  end

  defp track_pos({:pos_inline, _}, {n, s}), do: {n + 1, s}
  defp track_pos({:pos_end}, {n, s}), do: {n - 1, s}

  defp track_pos({:box_start, ref, %{pos: p}}, {n, s}) when p not in [nil, false],
    do: {n + 1, [ref | s]}

  defp track_pos({:box_end, ref}, {n, s}) do
    if ref in s, do: {n - 1, List.delete(s, ref)}, else: {n, s}
  end

  defp track_pos(_, d), do: d

  # display -> :block | :list_item | :flex | :inline | :contents
  defp kind(tag, c) do
    case c["display"] do
      nil ->
        legacy_kind(tag)

      d
      when d in [
             "block",
             "flow-root",
             "table-row",
             "table-row-group",
             "table-header-group",
             "table-footer-group",
             "table-caption"
           ] ->
        :block

      "table" ->
        :table

      # a cell outside a table: side by side like inline blocks
      "table-cell" ->
        :inline_block

      "list-item" ->
        :list_item

      "flex" ->
        :flex

      "grid" ->
        :grid

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

    rel =
      if c["position"] == "relative",
        do: %{top: c["top"], bottom: c["bottom"], left: c["left"], right: c["right"]}

    acc = if positioned?, do: [{:pos_inline, rel} | acc], else: acc

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
        # the height of the font's content area, in ems, is the height of the box
        cf: content_factor(style),
        paint: visible? and not style.hidden
      }
    end
  end

  defp block_ops(tag, kind, kids, style, c, acc) do
    box = box(tag, c)

    acc =
      case clear_side(c) do
        nil -> [{:gap, box.mt}, {:flush} | acc]
        side -> [{:gap, box.mt}, {:clear, side}, {:flush} | acc]
      end

    acc = if Map.get(c, :anchor) && style.nid, do: [{:anchor, style.nid} | acc], else: acc

    if tag == "hr" do
      [{:hr}, {:gap, box.mb} | acc]
    else
      ref = make_ref()

      case box_spec(tag, c, box, style) do
        nil ->
          # plain block: just insets
          acc = [{:inset, box.ml + box.pl, box.mr + box.pr} | acc]
          acc = if box.pt > 0, do: [{:pad, box.pt} | acc], else: acc
          acc = indent_op(c, box, acc)

          acc =
            with_cw(child_width(c, box), fn ->
              with_definite(own_definite?(tag, c), fn ->
                block_children(tag, kind, kids, style, c, acc)
              end)
            end)

          acc = [{:flush} | acc]
          acc = indent_end(c, acc)
          acc = if box.pb > 0, do: [{:pad, box.pb} | acc], else: acc
          [{:gap, box.mb}, {:inset_end} | acc]

        spec ->
          {legend, kids} = take_legend(tag, kind, spec, kids, style)
          spec = if legend, do: Map.put(spec, :legend, true), else: spec
          acc = [{:box_start, ref, spec} | acc]
          acc = if legend, do: [legend | acc], else: acc
          acc = indent_op(c, box, acc)

          acc =
            with_cw(child_width(c, box), fn ->
              with_definite(own_definite?(tag, c), fn ->
                block_children(tag, kind, kids, style, c, acc)
              end)
            end)

          acc = [{:flush} | acc]
          acc = indent_end(c, acc)
          acc = [{:box_end, ref} | acc]
          [{:gap, box.mb} | acc]
      end
    end
  end

  # `text-indent`: the first line of a block starts that far in, as if an inline box of that
  # width led it (`lead`); a percentage is of the block's own width. Nothing carries over from
  # one block to the next.
  defp indent_op(c, box, acc) do
    case c["text-indent"] do
      n when is_number(n) and n != 0 -> [{:indent, round(n)} | acc]
      {:pct, f} when f != 0 -> [{:indent, round(f * child_width(c, box))} | acc]
      _ -> acc
    end
  end

  defp indent_end(c, acc) do
    if c["text-indent"] in [nil, 0, 0.0, {:pct, 0.0}], do: acc, else: [{:indent, 0} | acc]
  end

  # A fieldset's first child, when it is a legend, sits on the top border and interrupts it.
  # -> {the `:legend` op or nil, the children left for the fieldset's content}
  defp take_legend("fieldset", :block, %{bw: {bt, _, _, _}}, kids, style) when bt > 0 do
    {skipped, rest} =
      Enum.split_while(kids, &(match?({:text, t} when is_binary(t), &1) and blank?(&1)))

    with [{:element, "legend", attrs, _} = el | rest] <- rest,
         c = computed(attrs),
         false <- hidden?(c),
         false <- c["position"] in ["absolute", "fixed"],
         false <- c["float"] in ["left", "right"] do
      [{:inline_block, sub, spec, ps}] = inline_block_ops(el, style, c, [], true)
      {{:legend, sub, spec, ps}, skipped ++ rest}
    else
      _ -> {nil, kids}
    end
  end

  defp take_legend(_tag, _kind, _spec, kids, _style), do: {nil, kids}

  defp blank?({:text, t}), do: String.trim(t) == ""

  # Boxes whose geometry must be resolved at placement: backgrounds, borders,
  # explicit widths/heights, `auto` margins, clipping and positioned boxes.
  defp box_spec(tag, c, box, style) do
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
      bs: box.bs,
      width: dim(c["width"]),
      minw: c["min-width"],
      maxw: c["max-width"],
      sizing: if(c["box-sizing"] == "border-box", do: :border, else: :content),
      rtl: style.prtl,
      bg: box.bg,
      r: box.r,
      bgimg: box.bgimg,
      shadows: box.shadows,
      color: box.color,
      cid: style.cid,
      nid: style.nid,
      h: num(c["height"]),
      hpct: pct_of(c["height"]),
      root: tag == "html",
      min: num(c["min-height"]),
      max: num(c["max-height"]),
      clip: clips?(c),
      pos: c["position"] in ["relative", "sticky", "absolute", "fixed"],
      # `position: relative`: the box is drawn shifted by `top`/`left` (or `bottom`/`right`)
      rel:
        if(c["position"] == "relative",
          do: %{top: c["top"], bottom: c["bottom"], left: c["left"], right: c["right"]}
        ),
      xform: xform_spec(c),
      # `position: sticky; top: n`: the box stays n px from the top of the window once scrolled to it
      sticky: if(c["position"] == "sticky" and is_number(c["top"]), do: round(c["top"])),
      z: z_index(c)
    }

    needed? =
      spec.xform || spec.bg || spec.bgimg || spec.shadows != [] || bt + br + bb + bl > 0 || spec.h ||
        spec.min ||
        spec.max || spec.pos ||
        spec.clip || spec.width || spec.minw || spec.maxw || spec.ml == :auto ||
        spec.mr == :auto || spec.cid != nil || (spec.hpct && percent_definite?(tag))

    if needed?, do: spec
  end

  # `auto` is the same as no width/height for everything but images
  defp dim(:auto), do: nil
  defp dim(:fit), do: nil
  defp dim(v), do: v

  defp num(v) when is_number(v), do: v
  defp num(_), do: nil

  defp clips?(c) do
    Map.get(c, "overflow-x", "visible") in ~w(hidden clip scroll auto) or
      Map.get(c, "overflow-y", "visible") in ~w(hidden clip scroll auto)
  end

  # the absolutely positioned elements among a table's children, its row groups' and its rows'
  # (which are no row, group or cell), and what is left
  defp split_out_of_flow(kids) do
    Enum.reduce(kids, {[], []}, fn
      {:element, tag, attrs, ekids} = el, {out, keep} when tag not in @skip ->
        c = computed(attrs)

        cond do
          c["position"] in ["absolute", "fixed"] ->
            {out ++ [el], keep}

          kind_of_table_part(tag, c) in [:group, :row] ->
            {inner_out, inner_keep} = split_out_of_flow(ekids)
            {out ++ inner_out, keep ++ [{:element, tag, attrs, inner_keep}]}

          true ->
            {out, keep ++ [el]}
        end

      other, {out, keep} ->
        {out, keep ++ [other]}
    end)
  end

  # A table is laid out as one unit at placement time (`op({:table, ...})`), when the width
  # its columns share is known.
  defp block_children(_tag, :table, kids, style, c, acc) do
    # a positioned child is out of flow: no row, cell or caption of the table, placed on its own
    {positioned, kids} = split_out_of_flow(kids)

    acc = Enum.reduce(positioned, acc, &walk(&1, style, &2))
    model = table_model(kids, style)

    if model.rows == [] and model.caption == nil,
      do: acc,
      else: [{:table, table_spec(c), model, style} | acc]
  end

  # A flex container lays its children out as one unit at placement time (`op({:flex, ...})`),
  # when the width they share is known. Out-of-flow children are placed as usual.
  defp block_children(tag, :flex, kids, style, c, acc) do
    {items, acc} =
      Enum.reduce(kids, {[], acc}, fn
        {:text, t}, {items, acc} ->
          if String.trim(t) == "",
            do: {items, acc},
            else: {[flex_text_item(t, style) | items], acc}

        {:element, tag, _, _}, {items, acc} when tag in @skip ->
          {items, acc}

        {:element, _tag, attrs, _} = el, {items, acc} ->
          ic = computed(attrs)

          cond do
            hidden?(ic) -> {items, acc}
            ic["position"] in ["absolute", "fixed"] -> {items, walk(el, style, acc)}
            true -> {[flex_element_item(el, ic, style) | items], acc}
          end

        _, state ->
          state
      end)

    case Enum.reverse(items) do
      [] -> acc
      items -> [{:flex, flex_spec(tag, c), items, style} | acc]
    end
  end

  # A grid is laid out like a flex container is: as one unit, once the width is known.
  defp block_children(tag, :grid, kids, style, c, acc) do
    {items, acc} =
      Enum.reduce(kids, {[], acc}, fn
        {:text, t}, {items, acc} ->
          if String.trim(t) == "",
            do: {items, acc},
            else: {[grid_item(flex_text_item(t, style), %{}) | items], acc}

        {:element, tag, _, _}, {items, acc} when tag in @skip ->
          {items, acc}

        {:element, _tag, attrs, _} = el, {items, acc} ->
          ic = computed(attrs)

          cond do
            hidden?(ic) -> {items, acc}
            ic["position"] in ["absolute", "fixed"] -> {items, walk(el, style, acc)}
            true -> {[grid_item(flex_element_item(el, ic, style), ic) | items], acc}
          end

        _, state ->
          state
      end)

    case Enum.reverse(items) do
      [] -> acc
      items -> [{:grid, grid_spec(tag, c), items, style} | acc]
    end
  end

  # a block with `columns`, `column-count` or `column-width` flows its content through columns
  defp block_children(tag, :block, kids, style, c, acc) do
    case columns_spec(c) do
      nil ->
        walk_children(tag, kids, style, acc)

      cs ->
        sub = tag |> walk_children(kids, style, []) |> Enum.reverse()
        [{:columns, cs, sub, style} | acc]
    end
  end

  defp block_children(tag, _kind, kids, style, _c, acc), do: walk_children(tag, kids, style, acc)

  defp columns_spec(c) do
    count = c["column-count"]
    width = c["column-width"]

    if count || width do
      fs = if is_number(c["font-size"]), do: c["font-size"], else: 16.0
      gap = if is_number(c["column-gap"]), do: c["column-gap"], else: fs
      %{count: count, width: width, gap: gap}
    end
  end

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

  @row_groups ~w(table-row-group table-header-group table-footer-group table-row)

  # rows and row groups outside a table sit in an anonymous table of their own
  defp wrap_table_parts(nodes) do
    if Enum.any?(nodes, &table_part?/1) do
      nodes
      |> Enum.chunk_by(&table_part?/1)
      |> Enum.flat_map(fn chunk ->
        if table_part?(hd(chunk)),
          do: [{:element, "div", [{"@computed", %{"display" => "table"}}], chunk}],
          else: chunk
      end)
    else
      nodes
    end
  end

  defp table_part?({:element, tag, attrs, _}) when tag not in @skip,
    do: computed(attrs)["display"] in @row_groups

  defp table_part?(_), do: false

  defp list_item(list_tag, n, attrs, kids, style, c, acc) do
    li_style = restyle("li", attrs, style, c)
    box = box("li", c)
    type = li_style.list || if(list_tag == "ol", do: "decimal", else: "disc")
    ml = if box.ml == :auto, do: 0, else: box.ml
    mr = if box.mr == :auto, do: 0, else: box.mr

    acc = [{:inset, ml + box.pl, mr + box.pr}, {:gap, box.mt}, {:flush} | acc]

    acc =
      cond do
        is_binary(c["marker-content"]) -> [{:marker, c["marker-content"], li_style} | acc]
        type == "none" -> acc
        true -> [{:marker, marker(type, n), li_style} | acc]
      end

    acc = walk(kids, li_style, acc)
    acc = [{:flush} | acc]
    [{:gap, box.mb}, {:inset_end} | acc]
  end

  # `list-style-type: "- "`: the string is the marker
  defp marker(<<q, _::binary>> = type, _) when q in [?", ?'] do
    type
    |> String.slice(1..-2//1)
    |> then(
      &Regex.replace(~r/\\([0-9a-fA-F]{1,6}) ?/, &1, fn _, h ->
        <<String.to_integer(h, 16)::utf8>>
      end)
    )
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
      bs: {border_s(c, "top"), border_s(c, "right"), border_s(c, "bottom"), border_s(c, "left")},
      bc: {
        border_c(c, "top", color),
        border_c(c, "right", color),
        border_c(c, "bottom", color),
        border_c(c, "left", color)
      },
      bg: if(color?(c["background-color"]), do: c["background-color"]),
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

  # how a side is drawn: :solid (also for the styles drawn like it), :dashed or :dotted
  defp border_s(c, side) do
    case c["border-#{side}-style"] do
      s when s in ["dashed", "dotted"] -> String.to_atom(s)
      _ -> :solid
    end
  end

  defp border_c(c, side, default) do
    case c["border-#{side}-color"] do
      {_, _, _} = rgb -> rgb
      {_, _, _, _} = rgba -> rgba
      :transparent -> nil
      _ -> default
    end
  end

  # wx draws at integer pixels
  # a percentage margin or padding is of the width of the containing block
  defp px(:auto), do: 0
  defp px({:pct, f}), do: round(f * containing_width())
  defp px(n), do: round(n)

  defp containing_width, do: Process.get(:layout_cw, 0)

  # -- styles ----------------------------------------------------------------------

  defp restyle_inline(style, attrs), do: apply_computed(style, computed(attrs))

  defp restyle(tag, attrs, style, c) do
    style = %{style | prtl: style.cb}

    style =
      case tag do
        t when t in ~w(b strong) -> %{style | bold: true}
        t when t in ~w(i em cite) -> %{style | italic: true}
        t when t in ~w(code tt kbd samp) -> %{style | mono: true, family: "monospace"}
        "pre" -> %{style | mono: true, family: "monospace", pre: true, ws: :pre}
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

    style =
      case List.keyfind(attrs, "@nid", 0) do
        {_, nid} -> %{style | nid: nid}
        nil -> style
      end

    style = apply_computed(style, c)

    # a field draws its text a line to an item (the caret and the selection count on it),
    # whatever `white-space` the page gives it
    if tag in ~w(textarea input), do: %{style | pre: true, ws: :pre}, else: style
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
    |> put_if(c["font-family"], &%{&1 | mono: mono?(&2), family: &2})
    |> put_if(match?({_, _, _}, c["color"]) && c["color"], &%{&1 | color: &2})
    |> put_if(
      decoration,
      &%{
        &1
        | underline: String.contains?(&2, "underline"),
          strike: String.contains?(&2, "line-through")
      }
    )
    |> put_if(
      c["text-align"] || c["direction"],
      fn s, _ -> %{s | align: align(c["text-align"] || "start", c["direction"])} end
    )
    |> put_if(c["list-style-type"], &%{&1 | list: &2})
    |> put_if(c["line-height"], &%{&1 | lh: &2})
    |> put_if(c["white-space"], &white_space(&1, &2))
    |> put_if(c["tab-size"], &tab_size(&1, &2))
    |> Map.put(:rtl, c["direction"] == "rtl")
    |> then(&if(c["display"] in [nil, "inline"], do: &1, else: Map.put(&1, :cb, &1.rtl)))
    |> Map.put(:hidden, hidden?(c))
  end

  # visibility is inherited by Style; a zero font-size hides text too
  defp hidden?(c),
    do:
      c["visibility"] in ["hidden", "collapse"] or
        (is_number(c["font-size"]) and c["font-size"] < 1)

  # `tab-size`: a number of columns (lengths are not supported)
  defp tab_size(style, value) do
    case Integer.parse(to_string(value)) do
      {n, ""} when n >= 0 -> %{style | tab: n}
      _ -> style
    end
  end

  defp white_space(style, value) do
    ws =
      case value do
        "pre" -> :pre
        "pre-wrap" -> :pre_wrap
        "break-spaces" -> :pre_wrap
        "pre-line" -> :pre_line
        "nowrap" -> :nowrap
        _ -> :normal
      end

    %{style | ws: ws, pre: ws == :pre}
  end

  defp put_if(style, nil, _fun), do: style
  defp put_if(style, false, _fun), do: style
  defp put_if(style, value, fun), do: fun.(style, value)

  # every element restyles with its family string, and there are only a few distinct ones
  defp mono?(family) do
    case Process.get({:mono, family}) do
      nil ->
        mono = mono_family?(family)
        Process.put({:mono, family}, if(mono, do: :yes, else: :no))
        mono

      cached ->
        cached == :yes
    end
  end

  @doc false
  def mono_family?(family) do
    family
    |> String.split(",")
    |> Enum.map(
      &(&1
        |> String.trim()
        |> String.trim("\"")
        |> String.trim("'")
        |> String.downcase())
    )
    |> Enum.find_value(false, fn
      name when name in @mono_fonts -> :mono
      name when name in @proportional_fonts -> :proportional
      # a web font we can't load, but whose name says what it is: "DM Mono", "Fira Code"
      name -> if String.contains?(name, ["mono", "code", "courier", "consol"]), do: :mono
    end)
    |> Kernel.==(:mono)
  end

  defp walk_text(t, %{pre: true} = style, acc), do: pre_text(t, style, acc)

  defp walk_text(t, %{ws: ws} = style, acc) when ws in [:pre_wrap, :pre_line],
    do: pre_text(t, style, acc, ws)

  defp walk_text(t, %{ws: :nowrap} = style, acc) do
    # whitespace collapses, but the words never wrap
    leading = if String.match?(t, ~r/\A\s/), do: [{:space, style}], else: []
    trailing = if String.match?(t, ~r/\S\s+\z/), do: [{:space, style}], else: []
    words = t |> String.split() |> Enum.map(&{:word, &1, style, :pre})

    case words do
      [] -> if t == "", do: acc, else: [{:space, style} | acc]
      _ -> Enum.reverse(leading ++ Enum.intersperse(words, {:space, style}) ++ trailing) ++ acc
    end
  end

  defp walk_text(t, style, acc) do
    leading = if String.match?(t, ~r/\A\s/), do: [{:space, style}], else: []
    trailing = if String.match?(t, ~r/\S\s+\z/), do: [{:space, style}], else: []
    words = t |> String.split() |> Enum.map(&{:word, &1, style})
    # without a space before it, the first word is glued to whatever came before
    words =
      case words do
        [{:word, w, st} | more] when leading == [] -> [{:word, w, st, :glue} | more]
        _ -> words
      end

    case words do
      [] -> if t == "", do: acc, else: [{:space, style} | acc]
      _ -> Enum.reverse(leading ++ Enum.intersperse(words, {:space, style}) ++ trailing) ++ acc
    end
  end

  defp align("center", _dir), do: :center
  defp align("-webkit-center", _dir), do: :center
  # `:rstart`: against the right edge, and a line too long for the box overflows to the left
  # (it starts at the right) where `:right` would start it at the left edge
  defp align("right", dir), do: if(dir == "rtl", do: :rstart, else: :right)
  defp align("end", dir), do: if(dir == "rtl", do: :left, else: :right)
  defp align("start", dir), do: if(dir == "rtl", do: :rstart, else: :left)
  defp align(_, _dir), do: :left

  # Preformatted text keeps its line breaks. A blank line holds a zero-width space so
  # it still takes a line; the empty tail after a final newline just ends the line.
  defp pre_text(t, style, acc, ws \\ :pre) do
    lines = String.split(t, "\n")
    last = length(lines) - 1

    lines
    |> Enum.with_index()
    |> Enum.reduce(acc, fn {line, i}, a ->
      a = if i > 0, do: [{:flush} | a], else: a

      cond do
        line != "" -> Enum.reverse(line_ops(line, style, ws)) ++ a
        i == last -> a
        true -> [{:word, "\u200B", style, :pre} | a]
      end
    end)
  end

  # the words of one line: `pre` keeps it whole, `pre-wrap` keeps its spaces but may wrap,
  # `pre-line` collapses spaces
  defp line_ops(line, style, :pre),
    do: [{:word, expand_tabs(line, style.tab), style, :pre}]

  defp line_ops(line, style, :pre_line) do
    line
    |> String.split()
    |> Enum.map(&{:word, &1, style})
    |> Enum.intersperse({:space, style})
  end

  defp line_ops(line, style, :pre_wrap) do
    ~r/ +|[^ ]+/
    |> Regex.scan(expand_tabs(line, style.tab))
    |> Enum.map(fn [run] ->
      cond do
        run == " " ->
          {:space, style}

        String.starts_with?(run, " ") ->
          {:word, String.duplicate("\u00A0", String.length(run)), style, :pre}

        true ->
          {:word, run, style}
      end
    end)
  end

  # a tab advances to the next multiple of `tab-size` columns
  defp expand_tabs(line, tab) do
    if String.contains?(line, "\t") do
      {parts, _} =
        line
        |> String.graphemes()
        |> Enum.reduce({[], 0}, fn
          "\t", {acc, col} ->
            n = if tab == 0, do: 0, else: tab - rem(col, tab)
            {[String.duplicate(" ", n) | acc], col + n}

          g, {acc, col} ->
            {[g | acc], col + 1}
        end)

      parts |> Enum.reverse() |> Enum.join()
    else
      line
    end
  end

  # -- ops -> positioned items -------------------------------------------------------
  #
  # State of the line placer. Lines span `margin + left` .. `width - margin -
  # right`; blocks push insets onto `insets` and restore them when they end.
  # `pos` is the stack of containing-block origins (`%{x, y, w, h}`, bottom
  # entry = the page); `open` holds boxes between their start and end ops;
  # `n`/`nr` count items/rects so a box can find the ones created inside it;
  # `overlays` are laid-out absolute elements.

  defp place(ops, width, measure, view_height, images, margin) do
    st = run(ops, width, measure, view_height, margin, :view, true, images)
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
      free: 0,
      ext: 0,
      insets: [],
      line: [],
      x: 0,
      y: 0,
      gap: 0,
      # boxes whose top edge waits for the margin that collapses into it (see `start_box`)
      ptop: [],
      # a space was taken up by an inline box opening (so what follows is not glued to what
      # came before)
      after_space: false,
      # offsets of the relatively positioned inline elements the layout is inside (or nil)
      rels: [],
      # the most negative margin waiting to be applied, which adds to the largest positive one
      ngap: 0,
      pending_space: nil,
      lh: 0,
      lf: @content_factor,
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
      lmax: 0,
      # floated boxes (newest first) and how much the right-hand ones take of the current line
      floats: [],
      fr: 0,
      # the open blocks (innermost first), and where each one ended: what sticky boxes inside stop at
      blocks: [],
      limits: %{},
      # the content height of the enclosing block when it has one of its own (for percentages)
      cbh: nil,
      cbw: nil,
      root_view: root_height == :view,
      flex_item: Process.get(:layout_flex_item, false)
    }

    # what is laid out here is a block formatting context of its own: it grows to hold its floats
    st = ops |> Enum.reduce(st, &op/2) |> flush()
    contain_floats(st, 0)
  end

  # paint order: backgrounds, flow content, then absolutely positioned elements
  defp finalize(st) do
    # what an absolutely positioned box painted (`:over`) stays above the flow, even when it came
    # through a line or an inline-block that sorts its items into backgrounds and the rest
    {over, flow} =
      (Enum.reverse(st.rects) ++ Enum.reverse(st.items))
      |> Enum.split_with(&Map.get(&1, :over))

    {under, overlays} =
      st.overlays |> Enum.reverse() |> Enum.concat() |> Enum.split_with(&Map.get(&1, :under))

    {under_flow, flow} = Enum.split_with(flow, &Map.get(&1, :under))
    # positioned boxes paint in tree order, whichever of the two lists they came through
    positioned = Enum.sort_by(overlays ++ over, &Map.get(&1, :pz, 0))
    all = under ++ under_flow ++ flow ++ positioned

    if st.limits == %{}, do: all, else: Enum.map(all, &stick_limit(&1, st.limits))
  end

  # A block ends: its content bottom is as far as sticky boxes inside it can go.
  defp end_block(%{blocks: [id | rest]} = st),
    do: %{st | blocks: rest, limits: Map.put(st.limits, id, st.y)}

  defp end_block(st), do: st

  defp stick_limit(%{stick: %{parent: parent} = stick} = item, limits) when parent != nil,
    do: %{item | stick: Map.put(stick, :limit, Map.get(limits, parent))}

  defp stick_limit(item, _limits), do: item

  defp op({:indent, px}, %{line: []} = st), do: %{st | lead: px}
  defp op({:indent, _px}, st), do: st

  defp op({:space, style}, st), do: if(st.line == [], do: st, else: %{st | pending_space: style})
  defp op({:word, text, style}, st), do: word(text, style, false, st)
  defp op({:word, text, style, :pre}, st), do: word(text, style, true, st)
  defp op({:word, text, style, :glue}, st), do: word(text, style, false, st, 0, true)

  defp op({:marker, m, style}, st) do
    # a marker right after another one (the first item of a list nested in an item) hangs in
    # its own list's margin, on the same line
    st =
      case st.line do
        [%{marker: true}] ->
          left = st.margin + st.left
          %{st | x: left - 18, indent: left, pending_space: nil}

        _ ->
          st
      end

    st = word(m, style, true, st, -18)
    st = %{st | line: [Map.put(hd(st.line), :marker, true) | tl(st.line)]}
    %{st | pending_space: style}
  end

  # a list marker stays on the line of the content that follows it
  defp op({:flush}, %{line: [%{marker: true}]} = st), do: st
  defp op({:flush}, st), do: flush(st)

  # a line break ends the line; on an empty line (after another break or a block) it is a
  # blank line of its own
  defp op({:br, _style}, %{line: [%{marker: true}]} = st), do: st

  defp op({:br, style}, %{line: []} = st) do
    st = st |> apply_gap() |> flush()
    %{st | y: st.y + line_px(style)}
  end

  defp op({:br, _style}, st), do: flush(st)

  defp op({:gap, _px}, %{line: [%{marker: true}]} = st), do: st
  defp op({:gap, px}, st) when px < 0, do: %{flush(st) | ngap: min(st.ngap, px)}
  defp op({:gap, px}, st), do: %{flush(st) | gap: max(st.gap, px)}

  defp op({:pad, px}, st), do: st |> flush() |> apply_gap() |> Map.update!(:y, &(&1 + px))

  # a floated box goes to the left or right edge of the line below, and text flows around it
  defp op({:float, side, sub, spec, _style}, st) do
    st = st |> flush() |> apply_gap()
    avail = max(st.width - 2 * st.margin - st.left - st.right, 0)
    w = fit_width(st, sub, spec, avail)
    {items, height, _base} = layout_atom(st, sub, w, Map.get(spec, :key))
    # `clear` puts the float below the earlier floats on that side
    top = clear_top(st, Map.get(spec, :clear))

    {x, y} =
      place_float(st, side, w, height, top, st.margin + st.left, st.width - st.margin - st.right)

    moved = for item <- items, do: item |> limit_extent(w) |> move(x, y) |> adopt_sticky(st)
    float = %{side: side, x0: x, x1: x + w, y0: y, y1: y + height}

    # a float paints above the backgrounds and borders of the blocks it overlaps: all of it,
    # background included, goes with the content
    %{
      st
      | items: Enum.reverse(moved) ++ st.items,
        n: st.n + length(moved),
        floats: [float | st.floats]
    }
  end

  # `clear`: the next line starts below the floats on that side
  defp op({:clear, side}, st) do
    st = st |> flush() |> apply_gap()

    bottom =
      st.floats
      |> Enum.filter(&(side == :both or &1.side == side))
      |> Enum.map(& &1.y1)
      |> Enum.max(fn -> st.y end)

    %{st | y: max(st.y, bottom)}
  end

  defp op({:inset, l, r}, st) do
    %{
      st
      | insets: [{st.left, st.right, st.y, length(st.floats)} | st.insets],
        blocks: [make_ref() | st.blocks],
        left: st.left + l,
        right: st.right + r
    }
  end

  # a block holding nothing but floats still contains them (the usual "clearfix")
  defp op({:inset_end}, %{insets: [{l, r, y0, n0} | rest]} = st) do
    st = if st.y == y0, do: contain_floats(st, n0), else: st
    st = end_block(st)
    %{st | insets: rest, left: l, right: r}
  end

  # where a block that has an id starts, for `#fragment`s and `scrollIntoView`
  defp op({:anchor, nid}, st) do
    item = %{
      type: :box,
      nid: nid,
      x: st.margin + st.left,
      y: st.y + max(st.gap, 0) + min(st.ngap, 0),
      w: max(st.width - 2 * st.margin - st.left - st.right, 0),
      h: 0,
      rr: 0,
      anchor: true
    }

    %{st | items: [item | st.items], n: st.n + 1}
  end

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

  # A fieldset's legend is laid out on its own, shrink-to-fit, at the top of the fieldset with its
  # middle on the border. The content starts below it, and the border has a gap where it is.
  defp op({:legend, sub, spec, _style}, st) do
    {ref, box} = Enum.find(st.open, fn {_, b} -> b.id == hd(st.blocks) end)
    {bt, _br, _bb, _bl} = box.o.bw
    st = flush(st)
    avail = max(st.width - 2 * st.margin - st.left - st.right, 0)
    w = fit_width(st, sub, spec, avail)
    {items, height, _} = layout_atom(st, sub, w, spec.key)
    x = st.margin + st.left
    moved = for it <- items, do: move(it, x, box.top)

    {rects, others} =
      Enum.split_with(moved, &(&1.type in @behind_text and !Map.get(&1, :over)))

    # the border runs through the middle of the legend's text (a little above the baseline), not
    # the middle of its line, which sits above the text: the way a line puts its text lower
    middle =
      case for(%{type: :text, y: ty, h: th} <- others, do: ty + round(th * 0.64)) do
        [] -> box.top + div(height, 2)
        mids -> Enum.min(mids)
      end

    off = (middle - box.top - div(bt, 2)) |> max(0) |> min(max(height - bt, 0))
    box = Map.put(box, :legend, %{x: x, w: w, off: off})

    %{
      st
      | items: Enum.reverse(others) ++ st.items,
        n: st.n + length(others),
        rects: Enum.reverse(rects) ++ st.rects,
        nr: st.nr + length(rects),
        open: Map.put(st.open, ref, box),
        gap: 0,
        ngap: 0,
        y: box.top + max(height, off + bt) + box.o.pt
    }
  end

  defp op({:box_end, ref}, st) do
    st = flush(st)
    # nothing was placed in it: the margin above still decides where it starts
    st = if ref in st.ptop, do: apply_gap(st), else: st
    {box, open} = Map.pop(st.open, ref)
    {bt, _br, bb, _bl} = box.o.bw
    st = %{st | open: open}

    # a box that clips, or that holds nothing but floats, contains them
    flow? = st.y > box.top + bt + box.o.pt
    st = if box.o.clip or not flow?, do: contain_floats(st, box.fl0), else: st
    st = %{st | blocks: List.delete(st.blocks, box.id)}
    st = if box.outer_floats, do: %{st | floats: box.outer_floats}, else: st

    # child margins stay inside the box only when padding or a border separates them
    st = if box.o.pb > 0 or bb > 0, do: apply_gap(st), else: st
    st = %{st | y: st.y + box.o.pb + bb}
    {l, r, f} = box.saved
    st = %{st | left: l, right: r, free: f}
    st = if box.o.pos, do: %{st | pos: tl(st.pos)}, else: st
    finish_box(st, box)
  end

  defp op({:inline_block, sub, spec, style}, st) do
    avail = max(st.width - 2 * st.margin - st.left - st.right, 0)
    w = fit_width(st, sub, spec, avail)
    {items, height, base} = layout_atom(st, sub, w, Map.get(spec, :key))

    place_atom(st, %{
      w: w,
      h: height,
      base: base,
      items: items,
      align: Map.get(spec, :malign) || style.align,
      valign: spec.valign
    })
  end

  defp op({:table, ts, model, _style}, st) do
    avail = max(st.width - 2 * st.margin - st.left - st.right, 0)
    {laid, w, height} = table_layout(st, ts, model, avail)
    laid = [%{type: :box, x: 0, y: 0, w: w, h: 0, rr: 0} | laid]

    place_atom(st, %{
      w: w,
      h: height,
      base: height,
      items: laid,
      align: :left,
      valign: nil
    })
  end

  defp op({:flex, cs, items, style}, st) do
    avail = max(st.width - 2 * st.margin - st.left - st.right, 0)
    # when measuring how wide the content wants to be (an unbounded width), the container
    # is as wide as its items, rather than spreading them over the whole width
    avail = if avail > @unbounded / 2, do: flex_natural_width(st, cs, items, avail), else: avail
    {laid, height} = flex_layout(st, cs, items, avail)
    # lets a measuring layout see how wide the container is (what surrounds it is added when
    # the atom is placed)
    laid = [%{type: :box, x: 0, y: 0, w: avail, h: 0, rr: 0} | laid]

    place_atom(st, %{
      w: avail,
      h: height,
      base: height,
      items: laid,
      align: style.align,
      valign: nil
    })
  end

  # Columns: the content is laid out once at the width of a column, then cut into as many
  # columns as there are, as even as lines allow, and the pieces are set side by side.
  defp op({:columns, cs, sub, style}, st) do
    avail = max(st.width - 2 * st.margin - st.left - st.right, 0)
    {n, colw} = column_geometry(cs, avail)

    if n <= 1 or avail > @unbounded / 2 do
      Enum.reduce(sub, st, &op/2)
    else
      {items, height, _} = layout_atom(st, sub, colw)
      {laid, height} = split_columns(items, height, n, colw, cs.gap)
      laid = [%{type: :box, x: 0, y: 0, w: avail, h: 0, rr: 0} | laid]

      place_atom(st, %{
        w: avail,
        h: height,
        base: height,
        items: laid,
        align: style.align,
        valign: nil
      })
    end
  end

  defp op({:grid, gs, items, style}, st) do
    avail = max(st.width - 2 * st.margin - st.left - st.right, 0)
    natural? = avail > @unbounded / 2
    {laid, width, height} = grid_layout(st, gs, items, avail, natural?)
    laid = [%{type: :box, x: 0, y: 0, w: width, h: 0, rr: 0} | laid]

    place_atom(st, %{
      w: width,
      h: height,
      base: height,
      items: laid,
      align: style.align,
      valign: nil
    })
  end

  # An image is a replaced element: an atom whose content is the picture inside
  # whatever box (border, padding, background, radius) the element has.
  defp op({:image, spec, style}, st) do
    avail = max(st.width - 2 * st.margin - st.left - st.right, 0)

    intrinsic =
      case spec do
        %{fill_ratio: r} when is_number(r) -> {avail, avail * r}
        _ -> spec.intrinsic
      end

    {cw, ch} = Browser.ImageBox.size(intrinsic, spec.attrs, spec.css, avail)
    box = spec.box
    {bt, br, bb, bl} = box.bw
    ml = if box.ml == :auto, do: 0, else: box.ml
    mr = if box.mr == :auto, do: 0, else: box.mr

    box_w = bl + box.pl + cw + box.pr + br
    box_h = bt + box.pt + ch + box.pb + bb

    outer = %{
      o: %{
        bw: box.bw,
        bc: box.bc,
        bs: box.bs,
        bg: box.bg,
        r: box.r,
        cid: nil,
        nid: Map.get(spec, :nid)
      },
      x: ml,
      top: box.mt,
      w: box_w
    }

    picture =
      if spec.paint? and cw > 0 and ch > 0 do
        item = %{
          x: ml + bl + box.pl,
          y: box.mt + bt + box.pt,
          w: cw,
          h: ch,
          href: spec.href,
          hidden: spec.hidden,
          nid: Map.get(spec, :nid),
          rr: box.pr + br + mr
        }

        case spec do
          %{scene: scene} ->
            ops = Browser.Svg.render(scene, cw, ch, current: spec.current)
            [Map.merge(item, %{type: :svg, ops: ops})]

          _ ->
            [Map.merge(item, %{type: :image, url: spec.url})]
        end
      else
        []
      end

    height = box.mt + box_h + box.mb

    place_atom(st, %{
      w: ml + box_w + mr,
      h: height,
      # the baseline of a replaced element is its bottom margin edge
      base: height,
      items:
        transformed_picture(
          spec,
          outer_rects(outer, box_h, st.images) ++ picture,
          {ml, box.mt, box_w, box_h}
        ),
      align: style.align,
      valign: spec.valign
    })
  end

  # Opening an inline box adds its left margin/border/padding to the line and
  # records where its box starts. On an empty line the space is carried in
  # `lead` and applied when the first word of the line is placed.
  defp op({:inline_open, ref, spec}, st) do
    spec = Map.put(spec, :rel, current_rel(st))

    if st.line == [] do
      {fl, _} = float_offsets(st, st.y + st.gap + st.ngap)
      x = st.margin + st.left + fl + st.lead + spec.ml

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
          after_space: st.after_space or space_w > 0,
          marks: [{:start, ref, spec, x + spec.ml} | st.marks]
      }
    end
  end

  defp op({:inline_close, ref, spec}, st) do
    right = spec.pr + spec.br

    if st.line == [] do
      {fl, _} = float_offsets(st, st.y + st.gap + st.ngap)
      x = st.margin + st.left + fl + st.lead + right
      %{st | lead: st.lead + right + spec.mr, marks: [{:end, ref, x} | st.marks]}
    else
      %{st | x: st.x + right + spec.mr, marks: [{:end, ref, st.x + right} | st.marks]}
    end
  end

  defp op({:pos_inline, rel}, st) do
    # text and boxes in a relatively positioned inline are drawn shifted
    st = %{st | rels: [inline_shift(st, rel) | st.rels]}

    {x, y} =
      if st.line == [],
        do: {st.margin + st.left, st.y + st.gap + st.ngap},
        else: {st.x, st.y}

    push_pos(st, %{x: x, y: y, w: max(st.width - st.margin - st.right - x, 0), h: nil})
  end

  defp op({:pos_end}, st), do: %{st | pos: tl(st.pos), rels: tl(st.rels)}

  defp op({:abs, sub, spec}, st) do
    spec = Map.put(spec, :seq, :erlang.unique_integer([:monotonic]))
    # the boxes it is placed against must know where they start
    st = if st.ptop == [], do: st, else: apply_gap(st)
    origin = if spec.fixed, do: List.last(st.pos), else: hd(st.pos)

    # `bottom` and a percentage `top` need the containing box's height, known only once it closes
    needs_height? = (spec.bottom && !spec.top) || match?({:pct, _}, spec.top)

    if needs_height? && is_nil(origin.h) && Map.get(origin, :ref) do
      %{st | deferred: [{origin.ref, sub, spec} | st.deferred]}
    else
      place_absolute(st, sub, spec, origin)
    end
  end

  defp inline_shift(_st, nil), do: nil

  defp inline_shift(st, rel) do
    cw = max(st.width - 2 * st.margin - st.left - st.right, 0)
    left = rel_offset(rel.left, cw)
    right = rel_offset(rel.right, cw)
    dx = left || -(right || 0)
    dy = rel_offset(rel.top, st.cbh) || -(rel_offset(rel.bottom, st.cbh) || 0)
    if dx == 0 and dy == 0, do: nil, else: {dx, dy, :erlang.unique_integer([:monotonic])}
  end

  # the offset the relatively positioned inlines around the current place add up to
  defp current_rel(%{rels: rels}) do
    case Enum.reject(rels, &is_nil/1) do
      [] ->
        nil

      list ->
        {Enum.sum(for({dx, _, _} <- list, do: dx)), Enum.sum(for({_, dy, _} <- list, do: dy)),
         elem(hd(list), 2)}
    end
  end

  defp atom_items(%{rel: rel, items: items}), do: Enum.map(items, &Map.put(&1, :rel, rel))
  defp atom_items(%{items: items}), do: items

  defp apply_rel(items) do
    Enum.map(items, fn
      %{rel: {dx, dy, seq}} = it ->
        it |> Map.delete(:rel) |> move(dx, dy) |> Map.merge(%{over: true, pz: seq})

      it ->
        it
    end)
  end

  defp push_pos(st, origin), do: %{st | pos: [origin | st.pos]}

  defp apply_gap(%{ptop: []} = st), do: %{st | y: st.y + st.gap + st.ngap, gap: 0, ngap: 0}

  # the margin of a first child collapsed into the margin above its parent: the parent's top
  # edge is where the merged margin ends
  defp apply_gap(st) do
    y = st.y + st.gap + st.ngap

    {open, pos} =
      Enum.reduce(st.ptop, {st.open, st.pos}, fn ref, {open, pos} ->
        delta = y - open[ref].top
        open = Map.update!(open, ref, &%{&1 | top: y})
        # the box a positioned descendant is placed against moves with it
        pos = Enum.map(pos, fn e -> if e[:ref] == ref, do: %{e | y: e.y + delta}, else: e end)
        {open, pos}
      end)

    %{st | y: y, gap: 0, ngap: 0, open: open, pos: pos, ptop: []}
  end

  # Puts an atomic inline box (`%{w, h, base, items, align, valign}`) on the line,
  # wrapping to a new line if it doesn't fit.
  # A sticky box that sat at the top of a layout of its own (a flex item, say) is limited by
  # the block the whole thing is placed in.
  defp adopt_sticky(%{stick: %{parent: nil} = stick} = item, st),
    do: %{item | stick: %{stick | parent: List.first(st.blocks)}}

  defp adopt_sticky(item, _st), do: item

  defp add_rr(%{rr: rr} = item, extra), do: %{item | rr: rr + extra}
  defp add_rr(item, _extra), do: item

  # the items a box of its own width holds stop counting for shrink-to-fit at its right edge
  defp limit_new_items(st, box) do
    {new, old} = Enum.split(st.items, st.n - box.n0)
    limit = box.x + box.w
    %{st | items: Enum.map(new, &limit_extent(&1, limit)) ++ old}
  end

  # what overflows an inline-level box does not make the line wider: shrink-to-fit stops
  # counting its content at the box's right edge (`xlim`, which moves with the item)
  defp limit_extent(%{xlim: l} = item, w), do: %{item | xlim: min(l, w)}
  defp limit_extent(item, w), do: Map.put(item, :xlim, w)

  defp place_atom(st, atom) do
    line_left = st.margin + st.left

    space_w =
      if st.pending_space && st.line != [], do: st.measure.(" ", st.pending_space), else: 0

    st = if st.line == [], do: st |> apply_gap() |> start_atom_line(atom, line_left), else: st

    st =
      if st.line != [] and st.x + space_w + atom.w > st.width - st.margin - st.right - st.fr do
        st |> flush() |> apply_gap() |> start_atom_line(atom, line_left)
      else
        st
      end

    space_w = if st.line == [], do: 0, else: space_w
    x = st.x + space_w
    # inside the atom the room kept free on the right (see `rr`) includes what surrounds it
    # (not the room beside a box that has a width of its own: that is not part of what it needs)
    extra = st.right - st.free

    atom =
      if extra > 0,
        do: %{atom | items: Enum.map(atom.items, &add_rr(&1, extra))},
        else: atom

    atom = %{
      atom
      | items:
          atom.items
          |> Enum.map(&(&1 |> adopt_sticky(st) |> limit_extent(atom.w)))
          |> renumber_pz()
    }

    atom = atom |> Map.put(:type, :atom) |> Map.put(:x, x)
    atom = if rel = current_rel(st), do: Map.put(atom, :rel, rel), else: atom
    # an atom with nothing drawn in it still takes the room it asks for (one with content is
    # measured by what it draws)
    ext = if extent(atom.items) == 0, do: max(st.ext, x + atom.w + max(extra, 0)), else: st.ext
    %{st | line: [atom | st.line], x: x + atom.w, pending_space: nil, ext: ext}
  end

  # the tree order of positioned boxes in an atom (laid out earlier, maybe cached) is renewed
  # to come after what the page placed before it
  defp renumber_pz(items) do
    order = items |> Enum.flat_map(&List.wrap(Map.get(&1, :pz))) |> Enum.uniq() |> Enum.sort()

    if order == [] do
      items
    else
      fresh = Map.new(order, &{&1, :erlang.unique_integer([:monotonic])})
      Enum.map(items, fn it -> if pz = Map.get(it, :pz), do: %{it | pz: fresh[pz]}, else: it end)
    end
  end

  # -- boxes: width, margins, borders, height, clipping ------------------------------------

  # A box with no border or padding on top lets its first child's margin collapse into its own,
  # so its top edge is only known once the first content is placed.
  defp start_box(st, ref, o) do
    {bt, _, _, _} = o.bw
    st = flush(st)

    # (the outermost box of a layout of its own, an absolute or inline-block one, say, is a
    # block formatting context: its children's margins stay inside)
    if bt == 0 and o.pt == 0 and not o.clip and not o.root and st.floats == [] and
         not st.flex_item and
         (st.blocks != [] or st.root_view) do
      st = place_box(st, ref, percent_height(st, o))
      if Map.has_key?(st.open, ref), do: %{st | ptop: [ref | st.ptop]}, else: st
    else
      st |> apply_gap() |> place_box(ref, percent_height(st, o))
    end
  end

  # a percentage height is a share of the enclosing block's height when that is known
  defp percent_height(st, %{h: nil, hpct: pct} = o) when is_number(pct) do
    # the root's percentage refers to the window, anything else to the block it sits in
    base = if o.root and st.root_view, do: st.view_h, else: st.cbh
    if is_number(base), do: %{o | h: round(pct * base)}, else: o
  end

  defp percent_height(_st, o), do: o

  defp place_box(st, ref, o) do
    {_bt, br, _bb, bl} = o.bw
    avail = max(st.width - 2 * st.margin - st.left - st.right, 0)
    hpad = o.pl + o.pr + bl + br
    intrinsic? = Process.get(:layout_intrinsic, false)

    # width properties are for the content box unless box-sizing is border-box
    to_content = fn
      nil -> nil
      {:pct, _} when intrinsic? -> nil
      v -> v |> resolve(avail) |> then(&if(o.sizing == :border, do: max(&1 - hpad, 0), else: &1))
    end

    ml0 = if o.ml == :auto, do: 0, else: o.ml
    mr0 = if o.mr == :auto, do: 0, else: o.mr

    # a box that clips (overflow other than visible) starts a block formatting context: it does
    # not overlap the floats beside it, but narrows to the room they leave, or moves below them
    {fl, fr} = if o.clip, do: float_offsets(st, st.y, st.y + max(o.h || 1, 1)), else: {0, 0}
    beside = avail - fl - fr

    cw = to_content.(o.width) || max(beside - ml0 - mr0 - hpad, 0)
    cw = if m = to_content.(o.maxw), do: min(cw, m), else: cw
    cw = if m = to_content.(o.minw), do: max(cw, m), else: cw
    box_w = hpad + cw
    free = beside - ml0 - mr0 - box_w

    below =
      if fl > 0 or fr > 0,
        do:
          st.floats
          |> Enum.filter(&(&1.y1 > st.y))
          |> Enum.map(& &1.y1)
          |> Enum.min(fn -> nil end)

    if below && ml0 + box_w + mr0 > beside,
      do: place_box(%{st | y: below}, ref, o),
      else: open_box(st, ref, o, {fl, fr, beside}, {ml0, mr0, box_w, free})
  end

  defp open_box(st, ref, o, {fl, fr, beside}, {ml0, mr0, box_w, free}) do
    {bt, br, _bb, bl} = o.bw

    {ml, _mr} =
      case {o.ml, o.mr} do
        {:auto, :auto} -> {max(div(free, 2), 0), max(free - div(free, 2), 0)}
        {:auto, _} -> {max(free, 0), mr0}
        {_, :auto} -> {ml0, max(free, 0)}
        # over-constrained: the margin at the end of the line gives way, so a box with a width
        # sits against the right edge when the direction is rtl
        _ when o.rtl -> {ml0 + free, mr0}
        _ -> {ml0, mr0}
      end

    left = st.left + fl + ml
    # a negative margin lets the box reach into the space beside it
    rest = beside - ml - box_w
    rest = if ml0 < 0 or mr0 < 0, do: rest, else: max(rest, 0)
    x = st.margin + left

    id = make_ref()

    box = %{
      id: id,
      ref: ref,
      o: o,
      top: st.y,
      x: x,
      w: box_w,
      n0: st.n,
      nr0: st.nr,
      # a box that clips has a block formatting context: the floats outside it do not reach in
      fl0: if(o.clip, do: 0, else: length(st.floats)),
      outer_floats: if(o.clip, do: st.floats),
      ov0: length(st.overlays),
      seq: :erlang.unique_integer([:monotonic]),
      pcbh: st.cbh,
      pcbw: st.cbw,
      saved: {st.left, st.right, st.free}
    }

    st = %{
      st
      | open: Map.put(st.open, ref, box),
        blocks: [id | st.blocks],
        cbh: if(st.flex_item and st.blocks == [], do: nil, else: content_height(o)),
        cbw: max(box_w - bl - br - o.pl - o.pr, 0),
        floats: if(o.clip, do: [], else: st.floats),
        left: left + bl + o.pl,
        right: st.right + fr + rest + br + o.pr,
        # room beside a box with a width is not part of what it needs
        free: st.free + if(own_width?(o.width) || o.maxw, do: max(rest - mr0, 0), else: 0),
        y: st.y + bt + o.pt
    }

    if o.pos do
      push_pos(st, %{
        x: x + bl,
        y: box.top + bt,
        w: max(box_w - bl - br, 0),
        h: padding_height(st, o),
        ref: ref
      })
    else
      st
    end
  end

  # a box with a width is that wide for shrink-to-fit, whatever it holds (and the margin after it)
  defp box_mr(%{mr: mr}) when is_number(mr), do: max(mr, 0)
  defp box_mr(_), do: 0

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
    # a too-small height is the height of the box all the same: the content overflows it
    height = used + extra

    limit = box.top + bt + o.pt + used
    st = if clipped?, do: drop_below(st, box, limit), else: st
    st = %{st | y: box.top + height}

    st =
      if (own_width?(o.width) or o.maxw != nil) and fixed_width?(box),
        do: limit_new_items(%{st | ext: max(st.ext, box.x + box.w + box_mr(o))}, box),
        else: st

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
    st = %{st | rects: new ++ Enum.reverse(outer) ++ old, nr: st.nr + length(outer)}
    # sticky boxes inside stop at the bottom of this one's content
    st = %{st | limits: Map.put(st.limits, box.id, box.top + height - bb - o.pb)}
    st = %{st | cbh: box.pcbh, cbw: box.pcbw}
    {st, box} = if o.rel, do: relative_shift(st, box), else: {st, box}
    st = if o.xform, do: xform_new(st, box, height), else: st
    if o.sticky, do: stick_new(st, box, height), else: st
  end

  # A relatively positioned box and everything it painted move by its offsets; the space it
  # takes in the flow stays where it was. `top` wins over `bottom` and `left` over `right`.
  defp relative_shift(st, %{o: %{rel: rel}} = box) do
    cw = box.pcbw || max(st.width - 2 * st.margin - st.left - st.right, 0)
    left = rel_offset(rel.left, cw)
    right = rel_offset(rel.right, cw)
    # with both given, `left` wins in a left-to-right block and `right` in a right-to-left one
    dx = if box.o.rtl && right, do: -right, else: left || -(right || 0)
    dy = rel_offset(rel.top, box.pcbh) || -(rel_offset(rel.bottom, box.pcbh) || 0)

    {new_items, old_items} = Enum.split(st.items, st.n - box.n0)
    {new_rects, old_rects} = Enum.split(st.rects, st.nr - box.nr0)
    {new_over, old_over} = Enum.split(st.overlays, length(st.overlays) - box.ov0)

    # a box that moved paints above the non-positioned content of the flow
    shift = fn list ->
      if dx == 0 and dy == 0,
        do: list,
        else:
          Enum.map(list, fn it ->
            it |> move(dx, dy) |> Map.put(:over, true) |> Map.put_new(:pz, box.seq)
          end)
    end

    st = %{
      st
      | items: shift.(new_items) ++ old_items,
        rects: shift.(new_rects) ++ old_rects,
        overlays: Enum.map(new_over, shift) ++ old_over
    }

    {st, %{box | x: box.x + dx, top: box.top + dy}}
  end

  defp rel_offset(n, _cw) when is_number(n), do: round(n)
  defp rel_offset({:pct, f}, base) when is_number(base), do: round(f * base)
  defp rel_offset(_, _), do: nil

  # the height of a box's content when `height` gives one
  defp content_height(%{h: h} = o) when is_number(h) do
    {bt, _, bb, _} = o.bw
    # `min-height` and `max-height` bound the height its children's percentages refer to
    h = if is_number(o.max), do: min(h, o.max), else: h
    h = if is_number(o.min), do: max(h, o.min), else: h
    if o.sizing == :border, do: max(h - bt - bb - o.pt - o.pb, 0), else: h
  end

  defp content_height(_), do: nil

  # everything the box painted sticks with it
  defp stick_new(st, %{o: o} = box, height) do
    # `parent` is the block it sits in, whose bottom becomes its `limit` when layout is done
    stick = %{top: o.sticky, y0: box.top, h: height, parent: List.first(st.blocks)}
    {new_items, old_items} = Enum.split(st.items, st.n - box.n0)
    {new_rects, old_rects} = Enum.split(st.rects, st.nr - box.nr0)
    # absolutely positioned children are placed in `overlays`, outside the flow
    {new_over, old_over} = Enum.split(st.overlays, length(st.overlays) - box.ov0)

    tag = fn list ->
      Enum.map(list, &(&1 |> Map.put_new(:stick, stick) |> Map.put_new(:z, o.z)))
    end

    %{
      st
      | items: tag.(new_items) ++ old_items,
        rects: tag.(new_rects) ++ old_rects,
        overlays: Enum.map(new_over, tag) ++ old_over
    }
  end

  # items in paint order: background, then the four border sides. A box with
  # rounded corners is a single item carrying its radii and border data, for
  # the painter to draw as paths.
  defp outer_rects(%{o: o} = box, height, images) do
    items = plain_outer_rects(box, height, images)
    items = if o.cid, do: Enum.map(items, &Map.put(&1, :cid, o.cid)), else: items
    if Map.get(o, :nid), do: Enum.map(items, &Map.put(&1, :nid, o.nid)), else: items
  end

  # In paint order: outer shadows, background colour, background images, inset shadows,
  # then the borders. Without images or shadows this is just colour and borders.
  defp plain_outer_rects(%{o: o} = box, height, images) do
    {bt, br, bb, bl} = o.bw
    {tc, rc, bc, lc} = o.bc
    # the border of a fieldset starts at the middle of its legend, which has a gap cut out of it
    {off, gap} =
      case box do
        %{legend: %{x: lx, w: lw, off: off}} -> {off, {lx, lx + lw}}
        _ -> {0, nil}
      end

    {x, y, w} = {box.x, box.top + off, box.w}
    height = height - off
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

          {st, sr, sb, sl} = Map.get(o, :bs, {:solid, :solid, :solid, :solid})

          sides = [
            bt > 0 && tc && top_rects(st, x, y, w, bt, tc, gap),
            bb > 0 && bc && side_rects(sb, :h, x, y + height - bb, w, bb, bc),
            bl > 0 && lc && side_rects(sl, :v, x, y, bl, height, lc),
            br > 0 && rc && side_rects(sr, :v, x + w - br, y, br, height, rc)
          ]

          bg ++ images_item ++ insets ++ (sides |> Enum.filter(& &1) |> List.flatten())

        radii when decorated? ->
          # the border must be painted over the images and inset shadows
          rounded(x, y, w, height, o.bg, radii, {0, 0, 0, 0}, o.bc) ++
            images_item ++ insets ++ rounded(x, y, w, height, nil, radii, o.bw, o.bc, o[:bs], gap)

        radii ->
          rounded(x, y, w, height, o.bg, radii, o.bw, o.bc, o[:bs], gap)
      end

    # a control without background or border still has a box: keep it for its bounds
    marker =
      if o.cid && body == [] && w > 0 && height > 0,
        do: [%{type: :box, x: x, y: y, w: w, h: height}],
        else: []

    shadows ++ body ++ marker
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

  # `bs` are the sides' styles (:solid, :dashed, :dotted), which the painter draws
  # `gap` is the stretch {x0, x1} of the top side a fieldset's legend sits in, left undrawn
  defp rounded(x, y, w, h, bg, radii, bw, bc, bs \\ nil, gap \\ nil) do
    border = if bw == {0, 0, 0, 0}, do: nil, else: %{w: bw, c: bc, s: bs, gap: gap}

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

  # One border side. A dashed side is a row of 3t-long dashes with gaps of 3t, a dotted one a
  # row of t-wide dots with gaps of t; the pattern is spread so that it starts and ends with
  # a full dash at the corners (`:h` runs along x, `:v` along y).
  @max_dashes 400

  # the top side, without the stretch `gap` ({x0, x1}) a legend sits in
  defp top_rects(style, x, y, w, h, color, nil), do: side_rects(style, :h, x, y, w, h, color)

  defp top_rects(style, x, y, w, h, color, {g0, g1}) do
    g0 = g0 |> max(x) |> min(x + w)
    g1 = g1 |> max(g0) |> min(x + w)

    for {from, to} <- [{x, g0}, {g1, x + w}], to > from do
      side_rects(style, :h, from, y, to - from, h, color)
    end
    |> List.flatten()
  end

  defp side_rects(:solid, _dir, x, y, w, h, color), do: [rect(x, y, w, h, color)]

  defp side_rects(style, dir, x, y, w, h, color) do
    {len, t} = if dir == :h, do: {w, h}, else: {h, w}
    {dash, gap} = if style == :dashed, do: {3 * t, 3 * t}, else: {t, t}
    n = max(round((len + gap) / (dash + gap)), 1)

    if n == 1 or n > @max_dashes do
      [rect(x, y, w, h, color)]
    else
      # n dashes and n - 1 gaps exactly fill the side
      dash_len = (len - (n - 1) * gap) / n

      for i <- 0..(n - 1) do
        from = round(i * (dash_len + gap))
        to = round(i * (dash_len + gap) + dash_len)

        if dir == :h,
          do: rect(x + from, y, max(to - from, 1), h, color),
          else: rect(x, y + from, w, max(to - from, 1), color)
      end
    end
  end

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
    # a fixed box is placed against the window, whose height is known
    origin = if spec.fixed and origin.h == nil, do: %{origin | h: st.view_h}, else: origin
    cw = origin.w

    {static_x, static_y} =
      if st.line == [],
        do: {st.margin + st.left, st.y + st.gap + st.ngap},
        else: {st.x, st.y}

    static_right = st.width - st.margin - st.right

    left = resolve_h(spec.left, cw)
    right = resolve_h(spec.right, cw)
    top = resolve_v(spec.top, origin.h)
    bottom = origin.h && resolve_v(spec.bottom, origin.h)

    sub = if spec.replaced, do: Enum.map(sub, &pct_to_px(&1, cw)), else: sub
    {width, x} = abs_width(st, sub, spec, origin, left, right, {static_x, static_right})
    # `top` and `bottom` with an auto height stretch the box between them
    sub =
      cond do
        (spec.autoh and top) && bottom -> stretch(sub, origin.h - top - bottom)
        is_number(spec.hpct) and origin.h -> set_height(sub, spec.hpct * origin.h)
        true -> sub
      end

    {items, height} = layout_sub(st, sub, width)

    y =
      cond do
        top && bottom && (spec.mta || spec.mba) ->
          # auto vertical margins share what `top`, `bottom` and the height leave over
          free = origin.h - top - bottom - height - if(spec.mba, do: 0, else: spec.mb)
          origin.y + top + if(spec.mta, do: if(spec.mba, do: div(free, 2), else: free), else: 0)

        top ->
          origin.y + top

        bottom ->
          origin.y + origin.h - bottom - height

        true ->
          static_y
      end

    {tx, ty} = resolve_translate(spec.translate, width, height)
    # a negative `z-index` puts the box behind the flow: above the page's background only
    layer = if spec.z < 0 and !spec.fixed, do: :under, else: :over

    moved =
      for it <- items,
          do: it |> move(x + tx, y + ty) |> Map.put(layer, true) |> Map.put_new(:pz, spec.seq)

    # a fixed box stays where it is in the window while the page scrolls
    moved =
      if spec.fixed,
        do: Enum.map(moved, &(&1 |> Map.put(:stick, :fixed) |> Map.put(:z, spec.z))),
        else: moved

    %{st | overlays: [moved | st.overlays]}
  end

  defp pct_of({:pct, f}), do: f
  defp pct_of(_), do: nil

  # the height of a positioned box's padding edge when its `height` is given: a length, or a
  # percentage of the window's height for the root
  defp padding_height(st, o) do
    {bt, _, bb, _} = o.bw
    # only the root's percentage is known: its containing block is the window
    root? = length(st.blocks) <= 1
    h = o.h || (root? && o.hpct && hd(st.pos).h && o.hpct * hd(st.pos).h)

    if h do
      round(if o.sizing == :border, do: max(h - bt - bb, 0), else: h + o.pt + o.pb)
    end
  end

  # the element's own box, when nothing but margins comes before it (not a flex or table op)
  defp own_box(sub) do
    {before, rest} = Enum.split_while(sub, &(not match?({:box_start, _, _}, &1)))

    with [{:box_start, ref, o} | tail] <- rest,
         true <-
           Enum.all?(
             before,
             &(&1 == {:flush} or match?({tag, _} when tag in [:gap, :anchor], &1))
           ) do
      {before, ref, o, tail}
    else
      _ ->
        nil
    end
  end

  # the first box of an absolute element is `target` tall (max-height and min-height still apply)
  defp stretch(sub, target) do
    case own_box(sub) do
      {before, ref, o, tail} ->
        {bt, _, bb, _} = o.bw
        extra = if o.sizing == :border, do: 0, else: bt + o.pt + o.pb + bb
        target = max(target - extra, 0)
        before ++ [{:box_start, ref, %{o | h: target}} | tail]

      nil ->
        sub
    end
  end

  # an absolute element's percentage height is of its containing block
  defp set_height(sub, h) do
    case own_box(sub) do
      {before, ref, o, tail} -> before ++ [{:box_start, ref, %{o | h: h}} | tail]
      nil -> sub
    end
  end

  # the width of an absolute picture in percent is relative to its containing block
  defp pct_to_px({:image, %{attrs: attrs, css: css} = spec, style}, cw) do
    fix = fn
      {:pct, f} -> f * cw
      v -> v
    end

    attrs = if is_map(attrs), do: Map.update(attrs, :w, nil, fix), else: attrs
    css = if is_map(css), do: Map.update(css, :w, nil, fix), else: css
    {:image, %{spec | attrs: attrs, css: css}, style}
  end

  defp pct_to_px(op, _cw), do: op

  # The translation of a box: `translate: x y` or `transform: translate(x, y)` (also translateX
  # and translateY), each as `{:px, n}` or `{:pct, fraction of the box}`.
  defp translate_of(c) do
    fs = if is_number(c["font-size"]), do: c["font-size"], else: 16.0

    from_property = c["translate"] |> translate_pair(fs)

    from_transform =
      case c["transform"] do
        t when is_binary(t) ->
          Regex.scan(~r/translate(x|y|3d)?\(([^)]*(?:\([^)]*\)[^)]*)*)\)/, t)
          |> Enum.reduce({nil, nil}, fn [_, axis, args], {x, y} ->
            parts = args |> String.split(",") |> Enum.map(&translate_value(&1, fs))

            case {axis, parts} do
              {"x", [v]} -> {v || x, y}
              {"y", [v]} -> {x, v || y}
              {_, [vx, vy | _]} -> {vx || x, vy || y}
              {_, [vx]} -> {vx || x, y}
            end
          end)

        _ ->
          {nil, nil}
      end

    {tx, ty} = if from_transform != {nil, nil}, do: from_transform, else: from_property
    if tx || ty, do: {tx || {:px, 0}, ty || {:px, 0}}
  end

  defp translate_pair(value, fs) when is_binary(value) do
    case Regex.scan(~r/[\w.%-]*\((?:[^()]|\([^()]*\))*\)|\S+/, value) |> List.flatten() do
      [x] -> {translate_value(x, fs), nil}
      [x, y | _] -> {translate_value(x, fs), translate_value(y, fs)}
      _ -> {nil, nil}
    end
  end

  defp translate_pair(_, _fs), do: {nil, nil}

  defp translate_value(text, fs) do
    text = String.trim(text)

    if text == "0" do
      {:px, 0}
    else
      case Browser.Calc.eval("calc(" <> text <> ")", &Browser.Calc.unit_px(&1, fs, 16.0)) do
        {:ok, {:px, n}} -> {:px, n}
        {:ok, {:pct, f}} -> {:pct, f}
        _ -> nil
      end
    end
  end

  defp resolve_translate(nil, _w, _h), do: {0, 0}

  defp resolve_translate({tx, ty}, w, h),
    do: {round(translate_px(tx, w)), round(translate_px(ty, h))}

  defp translate_px({:px, n}, _size), do: n
  defp translate_px({:pct, f}, size), do: f * size

  # Moves an item, including the coordinates held inside it: the clip, the tiles and
  # clip of background layers, the shapes of shadows.
  defp move(it, dx, dy) do
    it = %{it | x: it.x + dx, y: it.y + dy}
    it = if it[:xlim], do: %{it | xlim: it.xlim + dx}, else: it

    it =
      case it do
        %{clip: c} -> %{it | clip: shift_rect(c, dx, dy)}
        _ -> it
      end

    # a sticky box's own place moves with it
    it =
      case it do
        %{stick: %{y0: y0} = stick} ->
          stick = %{stick | y0: y0 + dy}
          stick = if stick[:limit], do: %{stick | limit: stick.limit + dy}, else: stick
          %{it | stick: stick}

        _ ->
          it
      end

    # and a transformed box turns about where it now is
    it =
      case it do
        %{xform: list} -> %{it | xform: Enum.map(list, &Browser.Transform.moved(&1, dx, dy))}
        _ -> it
      end

    # the gap a fieldset's legend leaves in the top border is a place on the page too
    it =
      case it do
        %{border: %{gap: {g0, g1}} = border} ->
          %{it | border: %{border | gap: {g0 + dx, g1 + dx}}}

        _ ->
          it
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

  # a width of its own: a percentage is none while the content's width is being measured
  defp own_width?(nil), do: false
  defp own_width?({:pct, _}), do: !Process.get(:layout_intrinsic)
  defp own_width?(_), do: true

  defp resolve(nil, _base), do: nil

  defp resolve({:pct, f}, base), do: round(f * base)

  defp resolve(n, _base) when is_number(n), do: round(n)

  # CSS 2 10.3.7: the width of an absolutely positioned box and where its border box starts,
  # from `left`, `right`, `width` and the margins. With neither offset set the box sits at its
  # static position, which is its left edge, or its right edge when the direction is rtl.
  # -> {border-box width, x of the border box}
  defp abs_width(st, sub, spec, origin, left, right, {static_x, static_right}) do
    cw = origin.w
    rtl = spec.rtl
    ml = if spec.ml == :auto, do: nil, else: spec.ml
    mr = if spec.mr == :auto, do: nil, else: spec.mr

    {left, right} =
      cond do
        left || right -> {left, right}
        rtl -> {nil, origin.x + cw - static_right}
        true -> {static_x - origin.x, nil}
      end

    width =
      case resolve(spec.width, cw) do
        nil ->
          avail =
            cond do
              left && right -> cw - left - right
              left -> cw - left
              true -> cw - right
            end

          avail = max(avail - (ml || 0) - (mr || 0), 40)

          # a flex or grid container as the content wants its own natural width, not the room
          at =
            if Enum.any?(sub, &match?({tag, _, _, _} when tag in [:flex, :grid], &1)),
              do: @unbounded,
              else: avail

          if left && right && !spec.replaced do
            avail
          else
            min(avail, shrink_extent(st, sub, at, Map.get(spec, :key)) + spec.rextra)
          end

        w ->
          w + spec.extra + spec.mextra
      end

    width = clamp_width(width, spec, cw)

    x =
      cond do
        left && right ->
          free = cw - left - right - width - (ml || 0) - (mr || 0)

          cond do
            ml == nil and mr == nil and free >= 0 -> left + div(free, 2)
            ml == nil and mr == nil -> if rtl, do: left + free, else: left
            ml == nil -> left + free
            mr == nil -> left + ml
            rtl -> cw - right - mr - width
            true -> left + ml
          end

        left ->
          left + (ml || 0)

        true ->
          cw - right - (mr || 0) - width
      end

    {width, origin.x + x}
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
          measure_at = if Map.get(spec, :table?), do: @unbounded, else: max(avail, 1)
          min(avail, shrink_extent(st, sub, measure_at, Map.get(spec, :key)))

        w ->
          w + spec.extra + spec.mextra
      end

    clamp_width(width, spec, avail)
  end

  # natural width of the content when wrapped at `width`: lines are measured
  # left-aligned, since centring inside the available width would inflate it
  defp shrink_extent(st, sub, width, key) do
    memo({:extent, key || :erlang.phash2(sub), width}, fn ->
      # a percentage width depends on the very width being measured: it counts as auto
      outer = Process.put(:layout_intrinsic, true)
      sub_st = run(sub, max(width, 1), st.measure, st.view_h, 0, nil, false, st.images)
      Process.put(:layout_intrinsic, outer)
      max(sub_st |> finalize() |> extent(), sub_st.ext)
    end)
  end

  # The narrowest content can be: what `shrink_extent(st, sub, 1)` gives, which puts one word on
  # every line. Content made of words, blocks and their insets only needs no layout for that:
  # it is as wide as its widest word plus the insets around it. Anything else (boxes, images,
  # floats, inline boxes, preformatted words) is laid out at width 1.
  defp min_extent(st, sub, key) do
    memo({:min_extent, key || :erlang.phash2(sub)}, fn ->
      case min_words(sub, st.measure, 0, 0, [], 0) do
        :layout -> shrink_extent(st, sub, 1, key)
        ext -> ext
      end
    end)
  end

  defp min_words([], _measure, _l, _r, _stack, ext), do: ext

  defp min_words([op | rest], measure, l, r, stack, ext) do
    case op do
      {:word, text, style} ->
        min_words(rest, measure, l, r, stack, max(ext, l + r + measure.(text, style)))

      {:word, text, style, :glue} ->
        min_words(rest, measure, l, r, stack, max(ext, l + r + measure.(text, style)))

      {:inset, dl, dr} ->
        min_words(rest, measure, l + dl, r + dr, [{l, r} | stack], ext)

      {:inset_end} when stack != [] ->
        [{l, r} | stack] = stack
        min_words(rest, measure, l, r, stack, ext)

      {tag, _} when tag in [:space, :gap, :pad] ->
        min_words(rest, measure, l, r, stack, ext)

      {:flush} ->
        min_words(rest, measure, l, r, stack, ext)

      _ ->
        :layout
    end
  end

  # Nested tables measure and lay out the same cell content again and again (and every level
  # multiplies the passes), so results are remembered for the duration of one layout. The key
  # is a hash of the content, so a collision is possible in principle but not worth guarding.
  defp memo(key, fun) do
    case Process.get(:layout_memo) do
      nil ->
        fun.()

      cache ->
        key = {key, containing_width()}

        case cache do
          %{^key => value} ->
            value

          _ ->
            value = fun.()
            Process.put(:layout_memo, Map.put(Process.get(:layout_memo), key, value))
            value
        end
    end
  end

  defp layout_sub(st, sub, width) do
    sub_st = run(sub, max(width, 0), st.measure, st.view_h, 0, nil, true, st.images)
    {finalize(sub_st), sub_st.y}
  end

  # An inline-block's content: laid out at `width`; returns its items (relative
  # to its top-left), its height including trailing margin, and its baseline
  # (bottom of the last text line, or the bottom edge if there is no text).
  defp layout_atom(st, sub, width, key \\ nil) do
    memo({:atom, key || :erlang.phash2(sub), width}, fn ->
      sub_st = run(sub, max(width, 1), st.measure, st.view_h, 0, nil, true, st.images)
      height = sub_st.y + sub_st.gap + sub_st.ngap
      items = finalize(sub_st)
      {items, height, last_baseline(items, height)}
    end)
  end

  # A flex item's height is not definite for what it holds: a percentage inside it is `auto`.
  defp flex_atom(st, sub, width, key) do
    Process.put(:layout_flex_item, true)

    try do
      layout_atom(st, sub, width, {:flex, key || :erlang.phash2(sub)})
    after
      Process.delete(:layout_flex_item)
    end
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

  # A marker box is as wide as its content only when it is not just the measuring width: the
  # box of a block-level control fills whatever width it is laid out at.
  defp fixed_width?(%{w: w}), do: w < @unbounded / 2

  # right edge of the text, for shrink-to-fit; an anchor's box spans the width it was laid out at,
  # which says nothing about what the content needs
  defp extent(items) do
    items
    |> Enum.filter(
      &(&1.type in [:text, :image, :svg] or
          (&1.type == :box and fixed_width?(&1) and not Map.get(&1, :anchor, false)) or
          (&1.type == :bgimage and Map.get(&1, :sized, false)))
    )
    |> Enum.map(&(min(&1.x + &1.w, Map.get(&1, :xlim, @unbounded)) + Map.get(&1, :rr, 0)))
    |> Enum.max(fn -> 0 end)
  end

  # -- words and lines ------------------------------------------------------------------

  # How tall the glyphs of a font are as a factor of its size (ascent plus descent, which is also
  # its `normal` line-height): what the `:metrics` option measures, exactly 1 for Ahem, the test
  # font, or a fixed guess when nothing can measure the font.
  defp content_factor(style) do
    cond do
      String.contains?(to_string(Map.get(style, :family)), "ahem") -> 1.0
      metrics = Process.get(:layout_metrics) -> metrics.(style) / style.size
      true -> @content_factor
    end
  end

  # the line-height of text in px: `normal` is the font's content height, a number is a
  # factor of the font size
  defp line_px(%{lh: :normal, size: size} = style), do: round(size * content_factor(style))
  defp line_px(%{lh: {:num, f}, size: size}), do: round(f * size)
  defp line_px(%{lh: {:px, v}}), do: round(v)

  # A new line starts at `line_left` (a list marker hangs `dx` to the left). Space
  # owed by inline boxes opened on the empty line (`lead`) is applied to content.
  # The line an atom starts: beside the floats along its whole height, or lower down when it
  # does not fit between them.
  defp start_atom_line(st, atom, line_left) do
    right = st.width - st.margin - st.right
    st = move_below_floats(st, atom, right - line_left)
    start_line(st, line_left, 0, atom.h)
  end

  defp move_below_floats(st, atom, room) do
    h = max(atom.h, 1)
    {fl, fr} = float_offsets(st, st.y, st.y + h)

    case Enum.filter(st.floats, &(&1.y0 < st.y + h and &1.y1 > st.y)) do
      [] ->
        st

      _ when atom.w <= room - fl - fr ->
        st

      overlapping ->
        below = overlapping |> Enum.map(& &1.y1) |> Enum.min()
        move_below_floats(%{st | y: below}, atom, room)
    end
  end

  defp start_line(st, line_left, dx, h \\ 1) do
    lead = if dx == 0, do: st.lead, else: 0
    # floats beside this line push its start right and its end left (for as tall as the line is)
    {fl, fr} = float_offsets(st, st.y, st.y + max(h, 1))

    %{
      st
      | x: line_left + fl + dx + lead,
        indent: line_left + fl,
        lead: st.lead - lead,
        line_lead: lead,
        fr: fr
    }
  end

  defp word(text, style, nowrap?, st, dx \\ 0, glued? \\ false) do
    w = st.measure.(text, style)
    line_left = st.margin + st.left

    space_w =
      if st.pending_space && st.line != [], do: st.measure.(" ", st.pending_space), else: 0

    st = if st.line == [], do: st |> apply_gap() |> start_line(line_left, dx), else: st

    st =
      cond do
        st.line == [] or nowrap? or st.x + space_w + w <= st.width - st.margin - st.right - st.fr ->
          st

        # no space between this word and what comes before: they only break before all of it
        glued? and space_w == 0 and not st.after_space ->
          wrap_glued(st, line_left)

        true ->
          st |> flush() |> apply_gap() |> start_line(line_left, 0)
      end

    glue? = glued? and st.line != [] and space_w == 0 and not st.after_space
    space_w = if st.line == [], do: 0, else: space_w
    x = st.x + space_w

    item = %{
      type: :text,
      glue: glue?,
      # what the item adds to the metrics of its line, for when it moves to another one
      lm: {style.size, content_factor(style), line_px(style)},
      x: x,
      y: 0,
      w: w,
      h: style.size,
      text: text,
      size: style.size,
      bold: style.bold,
      italic: style.italic,
      mono: style.mono,
      family: style.family,
      href: if(style.hidden, do: nil, else: style.href),
      hidden: style.hidden,
      color: style.color,
      underline: style.underline,
      strike: style.strike,
      align: style.align,
      cid: style.cid,
      nid: style.nid,
      # the room boxes around it keep free on its right: for measuring how wide content is
      rr: st.right - st.free
    }

    item = if rel = current_rel(st), do: Map.put(item, :rel, rel), else: item
    st = bridge(st, item, space_w)

    %{
      st
      | line: [item | st.line],
        x: x + w,
        pending_space: nil,
        after_space: false,
        lf: if(style.size >= st.lh, do: content_factor(style), else: st.lf),
        lh: max(st.lh, style.size),
        lmax: max(st.lmax, line_px(style))
    }
  end

  # A word that does not fit, glued to the text before it (`bb<b>cc</b>`): everything back to
  # the last place a line may break moves to the next line together.
  defp wrap_glued(st, line_left) do
    {chain, rest} = Enum.split_while(st.line, &Map.get(&1, :glue, false))

    case rest do
      [%{type: :text} = first | [_ | _] = older] ->
        if Enum.all?(chain, &(&1.type == :text)),
          do: carry_chain(st, line_left, [first | chain], older),
          else: st |> flush() |> apply_gap() |> start_line(line_left, 0)

      # nothing earlier to break at: the word goes first on the next line, as it would
      # with a break allowed there
      _ ->
        st |> flush() |> apply_gap() |> start_line(line_left, 0)
    end
  end

  defp carry_chain(st, line_left, chain_newest_first, older) do
    chain = Enum.reverse(chain_newest_first)
    first_x = hd(chain).x
    # the room inline boxes opened since (margins, borders) took after the last word
    pending = st.x - (List.last(chain).x + List.last(chain).w)

    {moved, kept} =
      Enum.split_with(st.marks, fn
        {:start, _ref, spec, x} -> x + spec.bl + spec.pl >= first_x
        {:end, _ref, x} -> x >= first_x
      end)

    st = %{st | line: older, marks: kept, x: List.first(older) |> then(&(&1.x + &1.w))}
    st = st |> flush() |> apply_gap() |> start_line(line_left, 0)
    shift = st.x - first_x

    mark_shift = fn
      {:start, ref, spec, x} -> {:start, ref, spec, x + shift}
      {:end, ref, x} -> {:end, ref, x + shift}
    end

    chain = Enum.map(chain, &%{&1 | x: &1.x + shift})
    last = List.last(chain)

    st =
      Enum.reduce(chain, st, fn it, acc ->
        {size, cf, lpx} = it.lm

        %{
          acc
          | lf: if(size >= acc.lh, do: cf, else: acc.lf),
            lh: max(acc.lh, size),
            lmax: max(acc.lmax, lpx)
        }
      end)

    %{
      st
      | line: Enum.reverse(chain),
        x: last.x + last.w + pending,
        marks: Enum.map(moved, mark_shift) ++ st.marks
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
    # most lines are words only
    {atoms, texts} =
      if Enum.any?(st.line, &(&1.type == :atom)),
        do: Enum.split_with(st.line, &(&1.type == :atom)),
        else: {[], st.line}

    {floating, on_baseline} =
      if atoms == [],
        do: {[], []},
        else: Enum.split_with(atoms, &(&1.valign in ["top", "bottom", "middle"]))

    # `normal` height of the biggest text, and the height line-height gives the
    # line; the glyphs sit centred in the line, i.e. shifted by half the difference
    normal = if st.lh > 0, do: round(st.lh * st.lf), else: 0
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

    placed = placed |> Enum.map(&Map.drop(&1, [:glue, :lm])) |> apply_rel()

    top_of = fn
      %{valign: "top"} -> st.y
      %{valign: "bottom"} = a -> st.y + line_h - a.h
      %{valign: "middle"} = a -> st.y + base - round(st.lh * 0.3) - div(a.h, 2)
      a -> st.y + base - a.base
    end

    moved =
      for atom <- Enum.reverse(atoms),
          sub <- atom_items(atom),
          do: move(sub, atom.x + shift, top_of.(atom))

    moved = apply_rel(moved)

    # everything a box paints behind its text: colours, borders, images, shadows
    {rects, others} =
      Enum.split_with(moved, &(&1.type in @behind_text and !Map.get(&1, :over)))

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
        lf: @content_factor,
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

  defp fragment(%{spec: %{rel: {_, _, _} = rel}} = box, x1, last?, ctx) do
    spec = %{box.spec | rel: nil}

    %{box | spec: spec}
    |> fragment(x1, last?, ctx)
    |> Enum.map(&Map.put(&1, :rel, rel))
    |> apply_rel()
  end

  defp fragment(%{spec: spec} = box, x1, last?, ctx) do
    x0 = (box.x || ctx.first_x) + ctx.shift
    w = x1 + ctx.shift - x0
    y = ctx.y_ref.(spec.size) - spec.pt - spec.bt
    h = round(spec.size * Map.get(spec, :cf, 1.2)) + spec.pt + spec.pb + spec.bt + spec.bb
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
    free = st.width - st.margin - st.right - st.fr - st.indent - (right - left)

    case first.align do
      :center -> max(round(free / 2), 0)
      :right -> max(round(free), 0)
      :rstart -> round(free) - st.line_lead
      :left -> 0
    end
  end

  # -- flexbox ------------------------------------------------------------------------------

  # ── grid ─────────────────────────────────────────────────────────────────────────────────

  defp grid_spec(_tag, c) do
    fs = if is_number(c["font-size"]), do: c["font-size"], else: 16.0

    %{
      tracks: grid_tracks(c["grid-template-columns"], fs),
      col_gap: num(c["column-gap"]) || 0.0,
      row_gap: num(c["row-gap"]) || 0.0,
      align: c["align-items"] || "stretch",
      justify: c["justify-items"] || "stretch",
      fs: fs
    }
  end

  # where the child asks to sit: `{start, stop}` of `{:line, n}`, `{:span, n}` or nil
  defp grid_item(item, c) do
    {start, stop} =
      case c["grid-column"] do
        v when is_binary(v) ->
          case String.split(v, "/") do
            [a, b] -> {grid_line(a), grid_line(b)}
            [a] -> {grid_line(a), nil}
          end

        _ ->
          {grid_line(c["grid-column-start"]), grid_line(c["grid-column-end"])}
      end

    Map.merge(item, %{gstart: start, gstop: stop, gjustify: c["justify-self"] || "auto"})
  end

  defp grid_line(nil), do: nil

  defp grid_line(v) when is_binary(v) do
    v = String.trim(v)

    cond do
      v in ["", "auto"] ->
        nil

      String.starts_with?(v, "span") ->
        {:span, v |> String.replace("span", "") |> String.trim() |> int_or(1)}

      true ->
        {:line, int_or(v, 1)}
    end
  end

  defp grid_line(v) when is_number(v), do: {:line, trunc(v)}
  defp grid_line(_), do: nil

  defp int_or(text, default) do
    case Integer.parse(text) do
      {n, ""} -> n
      _ -> default
    end
  end

  # grid-template-columns: a list of tracks (`{:repeat_auto, min, tracks}` expands to what fits)
  defp grid_tracks(v, fs) when is_binary(v) do
    v
    |> split_tracks()
    |> Enum.flat_map(&parse_track(&1, fs))
  end

  defp grid_tracks(_, _), do: []

  defp split_tracks(text), do: split_tracks(String.graphemes(text), 0, [], [])

  defp split_tracks([], _d, cur, acc), do: Enum.reverse(flush_track(cur, acc))

  defp split_tracks([c | rest], d, cur, acc) do
    cond do
      c == "(" -> split_tracks(rest, d + 1, [c | cur], acc)
      c == ")" -> split_tracks(rest, d - 1, [c | cur], acc)
      d == 0 and c in [" ", "\t", "\n"] -> split_tracks(rest, d, [], flush_track(cur, acc))
      true -> split_tracks(rest, d, [c | cur], acc)
    end
  end

  defp flush_track([], acc), do: acc
  defp flush_track(cur, acc), do: [cur |> Enum.reverse() |> Enum.join() | acc]

  defp parse_track("[" <> _, _fs), do: []

  defp parse_track("repeat(" <> rest, fs) do
    inner = String.trim_trailing(rest, ")")

    case String.split(inner, ",", parts: 2) do
      [count, list] ->
        tracks = list |> split_tracks() |> Enum.flat_map(&parse_track(&1, fs))

        case String.trim(count) do
          n when n in ["auto-fill", "auto-fit"] ->
            [{:repeat_auto, tracks}]

          n ->
            List.flatten(List.duplicate(tracks, max(int_or(n, 1), 1)))
        end

      _ ->
        []
    end
  end

  defp parse_track("minmax(" <> rest, fs) do
    inner = String.trim_trailing(rest, ")")

    case split_args(inner) do
      [a, b] -> [{:minmax, track_size(a, fs), track_size(b, fs)}]
      _ -> [{:auto}]
    end
  end

  defp parse_track("fit-content(" <> _, _fs), do: [{:auto}]
  defp parse_track(t, fs), do: [track_size(t, fs)]

  defp split_args(text), do: split_args(String.graphemes(text), 0, [], [])

  defp split_args([], _d, cur, acc),
    do: Enum.reverse([cur |> Enum.reverse() |> Enum.join() |> String.trim() | acc])

  defp split_args([c | rest], d, cur, acc) do
    cond do
      c == "(" ->
        split_args(rest, d + 1, [c | cur], acc)

      c == ")" ->
        split_args(rest, d - 1, [c | cur], acc)

      c == "," and d == 0 ->
        split_args(rest, d, [], [cur |> Enum.reverse() |> Enum.join() |> String.trim() | acc])

      true ->
        split_args(rest, d, [c | cur], acc)
    end
  end

  # one track size: {:px, n} {:pct, f} {:fr, f} {:auto} {:minc} {:maxc}
  defp track_size(text, fs) do
    text = String.trim(text)

    cond do
      text == "auto" ->
        {:auto}

      text == "min-content" ->
        {:minc}

      text == "max-content" ->
        {:maxc}

      String.ends_with?(text, "fr") ->
        case Float.parse(String.trim_trailing(text, "fr")) do
          {f, ""} -> {:fr, f}
          _ -> {:auto}
        end

      String.starts_with?(text, "minmax(") ->
        {:auto}

      true ->
        case len_value(text, fs) do
          {:px, n} -> {:px, n * 1.0}
          {:pct, f} -> {:pct, f}
          _ -> {:auto}
        end
    end
  end

  # -> {items, width, height}
  defp grid_layout(st, gs, items, avail, natural?) do
    # explicit columns, or one stretching column; `repeat(auto-fill, …)` as many as fit
    explicit = expand_repeats(gs.tracks, avail, gs.col_gap, natural?)
    explicit = if explicit == [], do: [{:auto}], else: explicit

    placed = place_in_grid(items, length(explicit))

    ncols =
      max(length(explicit), placed |> Enum.map(&(&1.col + &1.span)) |> Enum.max(fn -> 0 end))

    tracks = explicit ++ List.duplicate({:auto}, ncols - length(explicit))

    sizes = track_sizes(st, tracks, placed, avail, gs.col_gap, natural?)
    gap = round(gs.col_gap)
    xs = sizes |> Enum.scan(0, fn w, x -> x + w + gap end) |> then(&[0 | Enum.drop(&1, -1)])
    width = Enum.sum(sizes) + gap * (ncols - 1)

    rows = placed |> Enum.group_by(& &1.row) |> Enum.sort()

    {laid, y} =
      Enum.map_reduce(rows, 0, fn {_row, cells}, y ->
        sized =
          Enum.map(cells, fn it ->
            span_w = Enum.sum(Enum.slice(sizes, it.col, it.span)) + gap * (it.span - 1)
            room = max(span_w - auto_zero(it.ml) - auto_zero(it.mr), 1)

            w =
              cond do
                it.width != nil ->
                  resolve(it.width, span_w) + it.extra

                it.fit? or justify_shrink?(it, gs) ->
                  min(room, shrink_extent(st, it.sub, @unbounded, it.key))

                true ->
                  room
              end

            w =
              clamp_width(w, %{maxw: it.maxw, minw: it.minw, extra: it.extra, mextra: 0}, span_w)

            w = max(round(w), 1)
            {items, h, _} = layout_atom(st, it.sub, w, it.key)
            Map.merge(it, %{w: w, items: items, h: h, room: room})
          end)

        cross = sized |> Enum.map(&(&1.h + &1.mt + &1.mb)) |> Enum.max() |> max(0)

        placed_items =
          Enum.flat_map(sized, fn it ->
            it = flex_stretch(st, it, gs.align, cross)
            dy = flex_offset(flex_align(it, gs.align), cross - it.mt - it.mb, it.h)
            dx = grid_justify(it, gs, it.room)
            x = Enum.at(xs, it.col) + auto_zero(it.ml) + dx
            for item <- it.items, do: move(item, round(x), y + it.mt + dy)
          end)

        {placed_items, y + cross + round(gs.row_gap)}
      end)

    {List.flatten(laid), width, max(y - round(gs.row_gap), 0)}
  end

  defp justify_shrink?(it, gs),
    do: grid_self(it, gs) in ["start", "end", "center", "left", "right", "flex-start", "flex-end"]

  defp grid_self(it, gs), do: if(it.gjustify in ["auto", nil], do: gs.justify, else: it.gjustify)

  defp grid_justify(it, gs, room) do
    free = max(room - it.w, 0)

    case grid_self(it, gs) do
      j when j in ["center"] -> round(free / 2)
      j when j in ["end", "right", "flex-end"] -> free
      _ -> 0
    end
  end

  defp expand_repeats(tracks, avail, gap, natural?) do
    Enum.flat_map(tracks, fn
      {:repeat_auto, inner} ->
        min =
          inner
          |> Enum.map(fn
            {:px, n} -> n
            {:minmax, {:px, n}, _} -> n
            _ -> 1.0
          end)
          |> Enum.sum()

        min = max(min, 1.0)
        n = if natural?, do: 1, else: max(trunc((avail + gap) / (min + gap)), 1)
        List.flatten(List.duplicate(inner, n))

      t ->
        [t]
    end)
  end

  # items into (row, column) cells, in order; `span` columns wide
  defp place_in_grid(items, ncols) do
    {placed, _} =
      Enum.map_reduce(items, {0, 0}, fn it, {row, col} ->
        {start, span} = grid_range(it, ncols)

        {row, col} =
          cond do
            start != nil and start < col -> {row + 1, 0}
            start == nil and col + span > ncols and col > 0 -> {row + 1, 0}
            true -> {row, col}
          end

        c = start || col
        {Map.merge(it, %{row: row, col: c, span: span}), {row, c + span}}
      end)

    placed
  end

  # -> {start column (0-based) or nil, span}
  defp grid_range(it, ncols) do
    line = fn
      {:line, n} when n < 0 -> max(ncols + 2 + n, 1)
      {:line, n} -> n
      _ -> nil
    end

    case {it.gstart, it.gstop} do
      {{:span, n}, _} ->
        {nil, min(max(n, 1), ncols)}

      {nil, {:span, n}} ->
        {nil, min(max(n, 1), ncols)}

      {nil, nil} ->
        {nil, 1}

      {a, nil} ->
        {(line.(a) || 1) - 1, 1}

      {nil, b} ->
        {nil, max((line.(b) || 2) - 1, 1)}

      {a, {:span, n}} ->
        {(line.(a) || 1) - 1, min(max(n, 1), ncols)}

      {a, b} ->
        s = line.(a) || 1
        e = line.(b) || s + 1
        {s - 1, max(e - s, 1)}
    end
  end

  # the width of every column
  defp track_sizes(st, tracks, placed, avail, gap, natural?) do
    n = length(tracks)

    contents =
      for i <- 0..(n - 1) do
        singles = Enum.filter(placed, &(&1.col == i and &1.span == 1))

        min =
          singles
          |> Enum.map(
            &(shrink_extent(st, &1.sub, 1, &1.key) + auto_zero(&1.ml) + auto_zero(&1.mr))
          )
          |> Enum.max(fn -> 0 end)

        max =
          singles
          |> Enum.map(
            &(shrink_extent(st, &1.sub, @unbounded, &1.key) + auto_zero(&1.ml) + auto_zero(&1.mr))
          )
          |> Enum.max(fn -> 0 end)

        {min, max(max, min)}
      end

    limits =
      for {t, {min, max}} <- Enum.zip(tracks, contents) do
        resolve_track(t, min, max, avail)
      end

    gaps = gap * (n - 1)

    if natural? do
      # as wide as the content wants, flexible columns included
      for {base, limit} <- limits, do: round(grow_limit(base, limit, nil))
    else
      widths = for {base, _} <- limits, do: base * 1.0
      grow_tracks(limits, widths, avail - gaps)
    end
  end

  defp grow_limit(base, {:num, l}, _), do: max(base, l)
  defp grow_limit(base, {:auto_max, l}, _), do: max(base, l)
  defp grow_limit(base, {:flex, _, max}, _), do: max(base, max)

  # {base, limit}: limit is {:num, n}, {:flex, f} or {:auto_max, n} (grows only when stretched)
  defp resolve_track({:px, v}, _min, _max, _avail), do: {v, {:num, v}}
  defp resolve_track({:pct, f}, _min, _max, avail), do: {f * avail, {:num, f * avail}}
  defp resolve_track({:fr, f}, min, max, _avail), do: {min * 1.0, {:flex, f, max}}
  defp resolve_track({:auto}, min, max, _avail), do: {min * 1.0, {:auto_max, max * 1.0}}
  defp resolve_track({:minc}, min, _max, _avail), do: {min * 1.0, {:num, min * 1.0}}
  defp resolve_track({:maxc}, _min, max, _avail), do: {max * 1.0, {:num, max * 1.0}}

  defp resolve_track({:minmax, a, b}, min, max, avail) do
    {base, _} = resolve_track(a, min, max, avail)
    base = if match?({:fr, _}, a), do: min * 1.0, else: base

    limit =
      case b do
        {:fr, f} -> {:flex, f, max}
        {:px, v} -> {:num, v}
        {:pct, f} -> {:num, f * avail}
        {:minc} -> {:num, min * 1.0}
        _ -> {:auto_max, max * 1.0}
      end

    {base, limit}
  end

  # free space goes to the tracks that can still grow, then to the flexible ones
  defp grow_tracks(limits, widths, space) do
    free = space - Enum.sum(widths)

    if free <= 0 do
      Enum.map(widths, &round/1)
    else
      growable = fn {w, {_b, l}} ->
        case l do
          {:num, v} -> v > w + 0.5
          {:auto_max, v} -> v > w + 0.5
          _ -> false
        end
      end

      widths = maximize(Enum.zip(widths, limits), free, growable)
      free = space - Enum.sum(widths)
      flex = for {_, {_, {:flex, f, _}}} <- Enum.zip(widths, limits), do: f

      cond do
        flex != [] and free > 0 ->
          flex_widths(widths, limits, space)

        free > 0 ->
          # nothing flexible: columns that size to their content share what is left
          autos =
            for {{_, {_, {:auto_max, _}}}, i} <- Enum.with_index(Enum.zip(widths, limits)), do: i

          if autos == [] do
            Enum.map(widths, &round/1)
          else
            share = free / length(autos)

            widths
            |> Enum.with_index()
            |> Enum.map(fn {w, i} -> round(if i in autos, do: w + share, else: w) end)
          end

        true ->
          Enum.map(widths, &round/1)
      end
    end
  end

  # raise every growable track toward its limit, equally, until the space or the limits run out
  defp maximize(pairs, free, growable) do
    open = Enum.filter(pairs, growable)

    if free < 0.5 or open == [] do
      Enum.map(pairs, &elem(&1, 0))
    else
      share = free / length(open)

      {new, used} =
        Enum.map_reduce(pairs, 0.0, fn {w, {_b, l} = lim} = pair, used ->
          if growable.(pair) do
            target =
              case l do
                {:num, v} -> v
                {:auto_max, v} -> v
              end

            add = min(share, target - w)
            {{w + add, lim}, used + add}
          else
            {{w, lim}, used}
          end
        end)

      if used < 0.5, do: Enum.map(new, &elem(&1, 0)), else: maximize(new, free - used, growable)
    end
  end

  # fr tracks split what is left in proportion, none below its own minimum
  defp flex_widths(widths, limits, space) do
    flex_idx =
      for {{_, {_, {:flex, f, _}}}, i} <- Enum.with_index(Enum.zip(widths, limits)), do: {i, f}

    fixed_total =
      widths
      |> Enum.with_index()
      |> Enum.reject(fn {_, i} -> List.keymember?(flex_idx, i, 0) end)
      |> Enum.map(&elem(&1, 0))
      |> Enum.sum()

    result = settle_flex(flex_idx, widths, space - fixed_total, %{})
    widths |> Enum.with_index() |> Enum.map(fn {w, i} -> round(Map.get(result, i, w)) end)
  end

  defp settle_flex(flex, widths, space, fixed) do
    open = Enum.reject(flex, fn {i, _} -> Map.has_key?(fixed, i) end)
    taken = fixed |> Map.values() |> Enum.sum()
    total = open |> Enum.map(&elem(&1, 1)) |> Enum.sum()
    per = if total > 0, do: (space - taken) / total, else: 0

    case Enum.find(open, fn {i, f} -> f * per < Enum.at(widths, i) end) do
      nil ->
        Enum.reduce(open, fixed, fn {i, f}, acc -> Map.put(acc, i, f * per) end)

      {i, _} ->
        settle_flex(flex, widths, space, Map.put(fixed, i, Enum.at(widths, i)))
    end
  end

  defp flex_spec(tag, c) do
    fs = if is_number(c["font-size"]), do: c["font-size"], else: 16.0
    box = box(tag, c)
    {bt, _br, bb, _bl} = box.bw
    vextra = if c["box-sizing"] == "border-box", do: box.pt + box.pb + bt + bb, else: 0
    # the content height a container with a height of its own gives its line
    inner = fn v -> if is_number(v), do: max(v - vextra, 0) end

    %{
      dir: flex_direction(c["flex-direction"]),
      wrap: c["flex-wrap"] in ["wrap", "wrap-reverse"],
      justify: c["justify-content"] || "flex-start",
      align: c["align-items"] || "stretch",
      col_gap: num(c["column-gap"]) || 0.0,
      row_gap: num(c["row-gap"]) || 0.0,
      height: inner.(num(c["height"])) || inner.(num(c["min-height"])),
      fs: fs
    }
  end

  # -> {number of columns, the width of one}
  defp column_geometry(%{count: count, width: width, gap: gap}, avail) do
    fit = if width, do: max(trunc((avail + gap) / (width + gap)), 1)

    n =
      cond do
        count && fit -> min(count, fit)
        count -> count
        fit -> fit
        true -> 1
      end

    {n, max((avail - (n - 1) * gap) / n, 1)}
  end

  # Cuts laid-out content (`items`, `height` tall) into `n` columns of the least height that
  # holds it when columns break between lines. -> {the items placed, the height used}
  defp split_columns(items, height, n, colw, gap) do
    lines =
      items
      |> Enum.filter(&(&1.type not in [:rect, :box]))
      |> Enum.map(&{&1.y, &1.y + Map.get(&1, :h, 0)})
      |> Enum.uniq()
      |> Enum.sort()

    # the top of each line, with the bottom of the lowest thing on it
    starts_for = fn h -> column_starts(lines, h) end
    fits? = fn h -> length(starts_for.(h)) <= n end

    low = max(ceil(height / n), 1)
    best = if fits?.(low), do: low, else: search_height(fits?, low, max(height, low))
    starts = starts_for.(best)

    ends = Enum.drop(starts, 1) ++ [height]
    used = Enum.zip(starts, ends) |> Enum.map(fn {a, b} -> b - a end) |> Enum.max(fn -> 0 end)
    bounds = Enum.with_index(starts)

    placed =
      for it <- items do
        {start, k} =
          bounds |> Enum.filter(fn {s, _} -> s <= it.y end) |> List.last() || {0, 0}

        move(it, round(k * (colw + gap)), -start)
      end

    {placed, used}
  end

  # the least height in low..high at which the lines fit the columns (fits? is monotonic)
  defp search_height(_fits?, low, high) when low >= high, do: high

  defp search_height(fits?, low, high) do
    mid = div(low + high, 2)
    if fits?.(mid), do: search_height(fits?, low, mid), else: search_height(fits?, mid + 1, high)
  end

  # where each column starts when lines are poured into columns of height `h`: the first at the
  # top, the others as far above their first line as the first column's first line is below it
  defp column_starts([], _h), do: [0]

  defp column_starts([{top0, _} | _] = lines, h) do
    {breaks, _} =
      Enum.reduce(lines, {[], top0}, fn {t, b}, {breaks, start} ->
        if b - start > h and t > start, do: {[t | breaks], t}, else: {breaks, start}
      end)

    [0 | breaks |> Enum.reverse() |> Enum.map(&(&1 - top0))]
  end

  defp flex_direction("row-reverse"), do: :row_reverse
  defp flex_direction("column"), do: :column
  defp flex_direction("column-reverse"), do: :column_reverse
  defp flex_direction(_), do: :row

  defp flex_text_item(text, style) do
    %{
      sub: walk({:text, text}, style, []) |> Enum.reverse(),
      key: make_ref(),
      rebuild: nil,
      grow: 0.0,
      shrink: 1.0,
      basis: nil,
      width: nil,
      minw: nil,
      maxw: nil,
      extra: 0,
      rextra: 0,
      ml: 0,
      mr: 0,
      mt: 0,
      mb: 0,
      vextra: 0,
      sizing: :content,
      align: "auto",
      order: 0,
      auto_height?: true,
      fit?: false
    }
  end

  # A child of a flex container: laid out on its own as a block (like an inline-block),
  # with its horizontal margins and its width taken over by the container.
  defp flex_element_item({:element, tag, attrs, kids} = el, c, style) do
    box = box(tag, c)
    {bt, br, bb, bl} = box.bw
    border_box? = c["box-sizing"] == "border-box"
    fs = if is_number(c["font-size"]), do: c["font-size"], else: 16.0

    # built again when the container stretches the item: with the same reference width
    cw = containing_width()

    build = fn extra_props ->
      with_cw(cw, fn -> build_flex_item(tag, el, c, attrs, kids, style, extra_props) end)
    end

    %{
      sub: build.(%{}),
      key: make_ref(),
      rebuild: if(tag in ~w(img svg), do: nil, else: build),
      grow: flex_number(c["flex-grow"], 0.0),
      shrink: flex_number(c["flex-shrink"], 1.0),
      basis: len_value(c["flex-basis"], fs),
      width: dim(c["width"]),
      minw: c["min-width"],
      maxw: c["max-width"],
      extra: if(border_box?, do: 0, else: box.pl + box.pr + bl + br),
      rextra: box.pr + br,
      ml: box.ml,
      mr: box.mr,
      mt: box.mt,
      mb: box.mb,
      vextra: box.pt + box.pb + bt + bb,
      sizing: if(border_box?, do: :border, else: :content),
      align: c["align-self"] || "auto",
      order: flex_number(c["order"], 0.0),
      auto_height?: c["height"] in [nil, :auto],
      fit?: c["width"] == :fit
    }
  end

  defp build_flex_item(tag, el, c, attrs, kids, style, extra_props) do
    if tag in ~w(img svg) do
      el |> walk(style, []) |> Enum.reverse()
    else
      own =
        c
        |> resolve_box_pct(containing_width())
        |> Map.drop(~w(width min-width max-width flex-basis))
        |> Map.merge(%{"margin-left" => 0.0, "margin-right" => 0.0})
        |> Map.merge(extra_props)

      attrs = List.keyreplace(attrs, "@computed", 0, {"@computed", own})

      {:element, tag, attrs, kids}
      |> walk_element(style, [], :inline_inner)
      |> Enum.reverse()
    end
  end

  defp flex_number(v, default) when is_binary(v) do
    case Float.parse(v) do
      {n, ""} -> n
      _ -> default
    end
  end

  defp flex_number(_v, default), do: default

  # a length or percentage written as text: `{:px, n}`, `{:pct, f}`, or nil (auto, content)
  defp len_value(text, fs) when is_binary(text) do
    text = String.trim(text)

    cond do
      text in ["", "auto", "content", "none"] -> nil
      text == "0" -> {:px, 0.0}
      true -> translate_value(text, fs)
    end
  end

  defp len_value(n, _fs) when is_number(n), do: {:px, n * 1.0}
  defp len_value(_, _fs), do: nil

  defp len_px({:px, n}, _base), do: n
  defp len_px({:pct, f}, base), do: f * base

  defp flex_natural_width(st, cs, items, avail) do
    widths =
      for it <- items,
          do: flex_base(st, it, avail) + auto_zero(it.ml) + auto_zero(it.mr)

    if cs.dir in [:row, :row_reverse],
      do: round(Enum.sum(widths) + cs.col_gap * (length(items) - 1)),
      else: round(Enum.max(widths, fn -> 0 end))
  end

  defp flex_layout(_st, _cs, [], _avail), do: {[], 0}

  defp flex_layout(st, cs, items, avail) do
    items = Enum.sort_by(items, & &1.order)
    reverse? = cs.dir in [:row_reverse, :column_reverse]
    items = if reverse?, do: Enum.reverse(items), else: items

    if cs.dir in [:row, :row_reverse],
      do: flex_row(st, cs, items, avail),
      else: flex_column(st, cs, items, avail)
  end

  defp auto_zero(:auto), do: 0
  defp auto_zero(n), do: n

  # the border-box width an item would like
  defp flex_base(st, it, avail) do
    w =
      cond do
        it.basis != nil -> len_px(it.basis, avail) + it.extra
        it.width != nil -> resolve(it.width, avail) + it.extra
        true -> shrink_extent(st, it.sub, @unbounded, it.key)
      end

    clamp_width(w, %{maxw: it.maxw, minw: it.minw, extra: it.extra, mextra: 0}, avail)
  end

  defp flex_row(st, cs, items, avail) do
    items = Enum.map(items, &Map.put(&1, :hw, flex_base(st, &1, avail) * 1.0))

    lines =
      if cs.wrap, do: flex_break(items, cs.col_gap, avail), else: [items]

    {laid, y} =
      Enum.map_reduce(lines, 0, fn line, y ->
        min_cross = if length(lines) == 1, do: cs.height || 0, else: 0
        {line_items, cross} = flex_line(st, cs, line, avail, y, min_cross)
        {line_items, y + cross + round(cs.row_gap)}
      end)

    {List.flatten(laid), max(y - round(cs.row_gap), 0)}
  end

  # wrapping: a new line when the next item no longer fits
  defp flex_break(items, gap, avail) do
    {lines, current, _used} =
      Enum.reduce(items, {[], [], 0.0}, fn it, {lines, cur, used} ->
        outer = it.hw + auto_zero(it.ml) + auto_zero(it.mr)
        needed = if cur == [], do: outer, else: used + gap + outer

        if cur != [] and needed > avail,
          do: {[Enum.reverse(cur) | lines], [it], outer},
          else: {lines, [it | cur], needed}
      end)

    Enum.reverse(if current == [], do: lines, else: [Enum.reverse(current) | lines])
  end

  defp flex_line(st, cs, line, avail, top, min_cross) do
    n = length(line)
    gaps = cs.col_gap * (n - 1)
    outer = fn it -> it.hw + auto_zero(it.ml) + auto_zero(it.mr) end
    free = avail - Enum.sum(Enum.map(line, outer)) - gaps

    line = flex_resize(st, line, free, avail)
    free = avail - Enum.sum(Enum.map(line, outer)) - gaps

    # auto margins take the free space before justify-content does
    autos = Enum.sum(for it <- line, m <- [it.ml, it.mr], m == :auto, do: 1)

    {line, free} =
      if free > 0 and autos > 0 do
        share = free / autos
        fix = fn m -> if m == :auto, do: share, else: m end
        {Enum.map(line, &%{&1 | ml: fix.(&1.ml), mr: fix.(&1.mr)}), 0.0}
      else
        {Enum.map(line, &%{&1 | ml: auto_zero(&1.ml), mr: auto_zero(&1.mr)}), free}
      end

    {start, between} = flex_justify(cs.justify, cs.dir == :row_reverse, max(free, 0.0), n)

    # lay every item out at its final width, find the height of the line
    sized =
      Enum.map(line, fn it ->
        w = max(round(it.hw), 1)
        {items, h, _base} = flex_atom(st, it.sub, w, it.key)
        Map.merge(it, %{w: w, items: items, h: h})
      end)

    cross = sized |> Enum.map(& &1.h) |> Enum.max() |> max(round(min_cross))

    {placed, _x} =
      Enum.map_reduce(sized, start, fn it, x ->
        it = flex_stretch(st, it, cs.align, cross)
        dy = flex_offset(flex_align(it, cs.align), cross, it.h)
        ix = x + it.ml
        moved = for item <- it.items, do: move(item, round(ix), top + dy)
        {moved, ix + it.w + it.mr + cs.col_gap + between}
      end)

    {placed, cross}
  end

  # grow into free space, or shrink in proportion to the base size
  defp flex_resize(_st, line, free, avail) when free > 0 do
    total = line |> Enum.map(& &1.grow) |> Enum.sum()

    if total > 0 do
      Enum.map(line, fn it ->
        w = it.hw + free * it.grow / total

        %{
          it
          | hw:
              clamp_width(w, %{maxw: it.maxw, minw: it.minw, extra: it.extra, mextra: 0}, avail) *
                1.0
        }
      end)
    else
      line
    end
  end

  # shrinking stops at the min-content width (`min-width: auto`); an item that reaches it is
  # frozen there and the others shrink further
  defp flex_resize(st, line, free, avail) when free < 0 do
    line = Enum.map(line, &Map.put(&1, :frozen, false))
    flex_shrink(st, line, free, avail)
  end

  defp flex_resize(_st, line, _free, _avail), do: line

  defp flex_shrink(st, line, free, avail) do
    live = Enum.reject(line, & &1.frozen)
    total = live |> Enum.map(&(&1.shrink * &1.hw)) |> Enum.sum()

    if total > 0 and free < 0 do
      # items whose share would go below their floor are pinned there
      {pinned, _} =
        Enum.split_with(live, fn it ->
          it.width == nil and it.hw + free * it.shrink * it.hw / total < flex_min(st, it)
        end)

      if pinned == [] do
        Enum.map(line, fn it ->
          if it.frozen do
            it
          else
            w = max(it.hw + free * it.shrink * it.hw / total, it.extra + 0.0)
            c = %{maxw: it.maxw, minw: it.minw, extra: it.extra, mextra: 0}
            %{it | hw: clamp_width(w, c, avail) * 1.0}
          end
        end)
      else
        gained = Enum.sum(for it <- pinned, do: max(it.hw - flex_min(st, it), 0.0))

        line =
          Enum.map(line, fn it ->
            if it in pinned, do: %{it | hw: min(flex_min(st, it), it.hw), frozen: true}, else: it
          end)

        flex_shrink(st, line, free + gained, avail)
      end
    else
      line
    end
  end

  defp flex_min(st, it), do: shrink_extent(st, it.sub, 1, it.key) * 1.0

  # -> {offset before the first item, extra space between items}
  defp flex_justify(justify, reversed?, free, n) do
    justify =
      case {justify, reversed?} do
        {j, true} when j in ["flex-start", "start", "normal"] -> "flex-end"
        {j, true} when j in ["flex-end", "end"] -> "flex-start"
        {j, _} -> j
      end

    case justify do
      j when j in ["flex-end", "end", "right"] -> {free, 0.0}
      "center" -> {free / 2, 0.0}
      "space-between" when n > 1 -> {0.0, free / (n - 1)}
      "space-around" -> {free / n / 2, free / n}
      "space-evenly" -> {free / (n + 1), free / (n + 1)}
      _ -> {0.0, 0.0}
    end
  end

  defp flex_align(%{align: "auto"}, container), do: container
  defp flex_align(%{align: own}, _container), do: own

  defp flex_offset(align, cross, h) when align in ["center"], do: round((cross - h) / 2)
  defp flex_offset(align, cross, h) when align in ["flex-end", "end"], do: cross - h
  defp flex_offset(_align, _cross, _h), do: 0

  # a stretched item with an automatic height fills the line: laid out again with a minimum height
  defp flex_stretch(st, it, container_align, cross) do
    stretch? = flex_align(it, container_align) in ["stretch", "normal"]

    if stretch? and it.auto_height? and it.rebuild != nil and it.h < cross do
      box_h = cross - it.mt - it.mb
      min_h = if it.sizing == :border, do: box_h, else: box_h - it.vextra
      sub = it.rebuild.(%{"min-height" => max(min_h, 0) * 1.0})
      {items, h, _} = flex_atom(st, sub, it.w, {it.key, min_h})
      %{it | items: items, h: max(h, cross)}
    else
      it
    end
  end

  defp flex_column(st, cs, items, avail) do
    {laid, y} =
      Enum.reduce(items, {[], 0}, fn it, {laid, y} ->
        ml = it.ml
        mr = it.mr
        room = avail - auto_zero(ml) - auto_zero(mr)
        align = flex_align(it, cs.align)

        w =
          cond do
            it.width != nil -> resolve(it.width, avail) + it.extra
            align in ["stretch", "normal"] and not it.fit? -> room
            true -> min(room, shrink_extent(st, it.sub, @unbounded, it.key))
          end

        w = clamp_width(w, %{maxw: it.maxw, minw: it.minw, extra: it.extra, mextra: 0}, avail)
        w = max(round(w), 1)
        {items, h, _} = flex_atom(st, it.sub, w, it.key)

        x =
          cond do
            ml == :auto and mr == :auto -> round((avail - w) / 2)
            ml == :auto -> avail - w - mr
            align in ["center"] -> round((avail - w) / 2)
            align in ["flex-end", "end"] -> avail - w - mr
            true -> ml
          end

        moved = for item <- items, do: move(item, round(x), y)
        {[moved | laid], y + h + round(cs.row_gap)}
      end)

    {laid |> Enum.reverse() |> List.flatten(), max(y - round(cs.row_gap), 0)}
  end

  # -- tables -------------------------------------------------------------------------------

  defp table_spec(c) do
    collapse? = c["border-collapse"] == "collapse"

    {sx, sy} =
      case c["border-spacing"] do
        {h, v} when not collapse? -> {h, v}
        _ when collapse? -> {0.0, 0.0}
        _ -> {0.0, 0.0}
      end

    # a table is at least as high as its `height`, the rows share what its content leaves over
    %{sx: round(sx), sy: round(sy), collapse?: collapse?, h: num(c["height"])}
  end

  @cell_tags ~w(td th)
  @group_tags ~w(thead tbody tfoot)

  # the caption and the rows of a table, in display order: header rows, body rows, footer rows
  defp table_model(kids, style) do
    parts =
      for {:element, tag, attrs, ekids} = el <- kids, tag not in @skip do
        c = computed(attrs)
        {kind_of_table_part(tag, c), el, tag, c, ekids}
      end

    caption =
      Enum.find_value(parts, fn
        {:caption, el, _tag, _c, _kids} -> table_caption(el, style)
        _ -> nil
      end)

    rows_of = fn wanted ->
      Enum.flat_map(parts, fn
        {:row, el, _tag, c, kids} when wanted == :body ->
          [table_row(el, c, kids, style, nil)]

        {:group, _el, tag, c, kids} ->
          if group_kind(tag) == wanted, do: group_rows(kids, style, row_bg(c)), else: []

        _ ->
          []
      end)
    end

    %{
      caption: caption,
      rows: rows_of.(:head) ++ rows_of.(:body) ++ rows_of.(:foot)
    }
  end

  defp kind_of_table_part(tag, c) do
    cond do
      tag == "caption" or c["display"] == "table-caption" ->
        :caption

      tag == "tr" or c["display"] == "table-row" ->
        :row

      tag in @group_tags or
          c["display"] in ["table-row-group", "table-header-group", "table-footer-group"] ->
        :group

      true ->
        :other
    end
  end

  defp group_kind("thead"), do: :head
  defp group_kind("tfoot"), do: :foot
  defp group_kind(_), do: :body

  defp group_rows(kids, style, bg) do
    for {:element, tag, attrs, ekids} = el <- kids,
        tag not in @skip,
        c = computed(attrs),
        tag == "tr" or c["display"] == "table-row",
        do: table_row(el, c, ekids, style, bg)
  end

  defp row_bg(c), do: if(color?(c["background-color"]), do: c["background-color"])

  # a row's background shows behind its cells; a row group's behind its rows
  defp table_row({:element, _tag, _attrs, _}, c, kids, style, group_bg) do
    cells =
      for {:element, tag, attrs, _} = el <- anonymous_cells(kids),
          tag not in @skip,
          cc = computed(attrs),
          tag in @cell_tags or cc["display"] == "table-cell",
          do: table_cell(el, cc, style)

    %{cells: cells, valign: valign_of(c["vertical-align"]), bg: row_bg(c) || group_bg}
  end

  # whatever else a row holds sits in an anonymous cell
  defp anonymous_cells(kids) do
    cell? = fn
      {:element, tag, attrs, _} -> tag in @cell_tags or computed(attrs)["display"] == "table-cell"
      _ -> false
    end

    skipped? = fn
      {:element, tag, _, _} -> tag in @skip
      {:text, t} -> String.trim(t) == ""
      _ -> true
    end

    kids
    |> Enum.reject(skipped?)
    |> Enum.chunk_by(cell?)
    |> Enum.flat_map(fn chunk ->
      if cell?.(hd(chunk)),
        do: chunk,
        else: [{:element, "div", [{"@computed", %{"display" => "table-cell"}}], chunk}]
    end)
  end

  defp table_caption({:element, tag, attrs, kids}, style) do
    c = computed(attrs)
    own = Map.merge(c, %{"margin-left" => 0.0, "margin-right" => 0.0})
    attrs = List.keyreplace(attrs, "@computed", 0, {"@computed", own})
    {:element, tag, attrs, kids} |> walk_element(style, [], :inline_inner) |> Enum.reverse()
  end

  defp valign_of(v) when v in ["top", "middle", "bottom"], do: v
  defp valign_of(_), do: nil

  defp table_cell({:element, tag, attrs, kids}, c, style) do
    box = box(tag, c)
    {bt, br, bb, bl} = box.bw
    border_box? = c["box-sizing"] == "border-box"

    # cells are built again at their final size: with the same reference width
    cw = containing_width()

    build = fn props -> with_cw(cw, fn -> build_cell(tag, attrs, kids, c, style, props) end) end
    sub = build.(%{})

    %{
      build: build,
      sub: sub,
      key: make_ref(),
      colspan: span_attr(attrs, "colspan"),
      rowspan: span_attr(attrs, "rowspan"),
      width: dim(c["width"]),
      minh: num(c["height"]) || num(c["min-height"]),
      valign: valign_of(c["vertical-align"]),
      extra: if(border_box?, do: 0, else: box.pl + box.pr + bl + br),
      pt: box.pt,
      # nothing is painted for the cell itself, so its height does not show
      plain:
        box.bg == nil and box.bgimg == nil and box.shadows == [] and box.bw == {0, 0, 0, 0} and
          xform_spec(c) == nil and not clips?(c) and
          c["position"] not in ["relative", "sticky"],
      vextra: box.pt + box.pb + bt + bb,
      sizing: if(border_box?, do: :border, else: :content)
    }
  end

  defp build_cell(tag, attrs, kids, c, style, props) do
    own =
      c
      |> resolve_box_pct(containing_width())
      |> Map.drop(~w(width min-width max-width height))
      |> Map.merge(%{
        "margin-left" => 0.0,
        "margin-right" => 0.0,
        "margin-top" => 0.0,
        "margin-bottom" => 0.0
      })
      |> Map.merge(props)

    attrs = List.keyreplace(attrs, "@computed", 0, {"@computed", own})
    {:element, tag, attrs, kids} |> walk_element(style, [], :inline_inner) |> Enum.reverse()
  end

  defp span_attr(attrs, name) do
    case Integer.parse(attr_value(attrs, name)) do
      {n, _} when n >= 1 -> min(n, 200)
      _ -> 1
    end
  end

  # -> {items, table width, height}
  defp table_layout(st, ts, model, avail) do
    placed = table_grid(model.rows)
    ncols = placed |> Enum.map(&(&1.col + &1.cell.colspan)) |> Enum.max(fn -> 0 end)
    nrows = length(model.rows)
    sx = ts.sx
    sy = ts.sy

    if ncols == 0 do
      table_caption_only(st, model, avail)
    else
      natural? = avail > @unbounded / 2
      {mins, maxs, pcts} = table_columns(st, placed, ncols)
      spacing = sx * (ncols + 1)

      widths =
        if natural? do
          maxs
        else
          table_widths(mins, maxs, pcts, max(avail - spacing, 0))
        end

      table_w = if natural?, do: Enum.sum(widths) + spacing, else: avail
      xs = column_positions(widths, sx)
      span_w = fn col, span -> Enum.sum(Enum.slice(widths, col, span)) + sx * (span - 1) end

      # first pass: the height every cell wants at the width of its columns
      sized =
        Enum.map(placed, fn p ->
          w = max(span_w.(p.col, p.cell.colspan), 1)
          {items0, h, _} = layout_atom(st, p.cell.sub, w, p.cell.key)
          Map.merge(p, %{w: w, h0: h, items0: items0})
        end)

      row_heights = table_row_heights(sized, nrows, sy)

      {caption_items, caption_h} = table_caption_items(st, model.caption, table_w)
      top = caption_h
      row_heights = grow_rows(row_heights, ts.h, top + sy + sy * nrows)
      ys = row_positions(row_heights, sy, top)

      cells =
        for p <- sized do
          rs = min(p.cell.rowspan, nrows - p.row)
          full_h = Enum.sum(Enum.slice(row_heights, p.row, rs)) + sy * (rs - 1)
          valign = p.cell.valign || p.row_valign || "middle"

          extra_top =
            case valign do
              "middle" -> max(div(full_h - p.h0, 2), 0)
              "bottom" -> max(full_h - p.h0, 0)
              _ -> 0
            end

          min_h =
            if p.cell.sizing == :border,
              do: full_h,
              else: max(full_h - p.cell.vextra - extra_top, 0)

          props = %{
            "padding-top" => (p.cell.pt + extra_top) * 1.0,
            "min-height" => min_h * 1.0
          }

          props = if ts.collapse?, do: collapse_borders(props, p, ncols, nrows), else: props
          # a plain cell looks the same at its final height, just lower when it is centred or
          # at the bottom
          items =
            if p.cell.plain and not ts.collapse? do
              if extra_top == 0, do: p.items0, else: Enum.map(p.items0, &move(&1, 0, extra_top))
            else
              {items, _h, _} = layout_atom(st, p.cell.build.(props), p.w)
              items
            end

          dx = Enum.at(xs, p.col)
          dy = Enum.at(ys, p.row)
          behind = if p.row_bg, do: [rect(0, 0, p.w, full_h, p.row_bg)], else: []
          for item <- behind ++ items, do: move(item, dx, dy)
        end

      height = top + sy + Enum.sum(row_heights) + sy * nrows
      {List.flatten([caption_items | cells]), table_w, height}
    end
  end

  # a table with only a caption
  defp table_caption_only(st, model, avail) do
    {items, h} = table_caption_items(st, model.caption, avail)
    {items, avail, h}
  end

  defp table_caption_items(_st, nil, _w), do: {[], 0}

  defp table_caption_items(st, sub, w) do
    {items, h, _} = layout_atom(st, sub, max(w, 1))
    {items, h}
  end

  # with collapsed borders neighbouring cells share one line: the right and bottom
  # borders only belong to the cells at the edge
  defp collapse_borders(props, p, ncols, nrows) do
    props =
      if p.col + p.cell.colspan < ncols,
        do: Map.put(props, "border-right-width", 0.0),
        else: props

    if p.row + min(p.cell.rowspan, nrows - p.row) < nrows,
      do: Map.put(props, "border-bottom-width", 0.0),
      else: props
  end

  # cells at their row and column; a cell with a rowspan or colspan takes the places below
  # and beside it
  defp table_grid(rows) do
    {placed, _taken} =
      rows
      |> Enum.with_index()
      |> Enum.reduce({[], MapSet.new()}, fn {row, r}, {placed, taken} ->
        {placed, taken, _col} =
          Enum.reduce(row.cells, {placed, taken, 0}, fn cell, {placed, taken, col} ->
            col = next_free(taken, r, col)

            spots =
              for dr <- 0..(cell.rowspan - 1), dc <- 0..(cell.colspan - 1), do: {r + dr, col + dc}

            entry = %{cell: cell, row: r, col: col, row_valign: row.valign, row_bg: row.bg}
            {[entry | placed], Enum.into(spots, taken), col + cell.colspan}
          end)

        {placed, taken}
      end)

    Enum.reverse(placed)
  end

  defp next_free(taken, r, col),
    do: if(MapSet.member?(taken, {r, col}), do: next_free(taken, r, col + 1), else: col)

  # the narrowest and widest each column can be, from its cells: wide cells that span several
  # columns add what is missing equally; percentage widths are kept per column
  defp table_columns(st, placed, ncols) do
    measured =
      Enum.map(placed, fn p ->
        cell = p.cell
        min = min_extent(st, cell.sub, cell.key)
        max = shrink_extent(st, cell.sub, @unbounded, cell.key)

        {max, pct} =
          case cell.width do
            w when is_number(w) -> {max(min, round(w) + cell.extra), nil}
            {:pct, f} -> {max, f}
            _ -> {max, nil}
          end

        {p, min, max(max, min), pct}
      end)

    zeros = List.duplicate(0, ncols)

    {mins, maxs, pcts} =
      measured
      |> Enum.filter(fn {p, _, _, _} -> p.cell.colspan == 1 end)
      |> Enum.reduce({zeros, zeros, List.duplicate(nil, ncols)}, fn {p, mn, mx, pct},
                                                                    {mins, maxs, pcts} ->
        {
          List.update_at(mins, p.col, &max(&1, mn)),
          List.update_at(maxs, p.col, &max(&1, mx)),
          if(pct, do: List.update_at(pcts, p.col, &max(&1 || 0, pct)), else: pcts)
        }
      end)

    spanning =
      measured
      |> Enum.filter(fn {p, _, _, _} -> p.cell.colspan > 1 end)
      |> Enum.sort_by(fn {p, _, _, _} -> p.cell.colspan end)

    Enum.reduce(spanning, {mins, maxs, pcts}, fn {p, mn, mx, _pct}, {mins, maxs, pcts} ->
      {widen(mins, p.col, p.cell.colspan, mn), widen(maxs, p.col, p.cell.colspan, mx), pcts}
    end)
  end

  # make the columns col..col+span-1 together `need` wide
  defp widen(list, col, span, need) do
    have = list |> Enum.slice(col, span) |> Enum.sum()

    if have >= need do
      list
    else
      lack = need - have
      share = div(lack, span)
      rest = rem(lack, span)

      list
      |> Enum.with_index()
      |> Enum.map(fn {w, i} ->
        if i >= col and i < col + span,
          do: w + share + if(i - col < rest, do: 1, else: 0),
          else: w
      end)
    end
  end

  # column widths for `space` px: percentages first, then the others between their narrowest
  # and widest
  defp table_widths(mins, maxs, pcts, space) do
    fixed =
      Enum.zip([mins, pcts])
      |> Enum.map(fn
        {mn, nil} -> {nil, mn}
        {mn, pct} -> {max(round(pct * space), mn), mn}
      end)

    taken = fixed |> Enum.map(fn {w, _} -> w || 0 end) |> Enum.sum()
    free = max(space - taken, 0)

    open =
      for {{nil, _}, mn, mx} <- Enum.zip([fixed, mins, maxs]), do: {mn, mx}

    shared = distribute_columns(open, free)

    {widths, _} =
      Enum.map_reduce(fixed, shared, fn
        {nil, _}, [w | rest] -> {w, rest}
        {w, _}, rest -> {w, rest}
      end)

    widths
  end

  defp distribute_columns([], _space), do: []

  defp distribute_columns(cols, space) do
    sum_min = cols |> Enum.map(&elem(&1, 0)) |> Enum.sum()
    sum_max = cols |> Enum.map(&elem(&1, 1)) |> Enum.sum()

    cond do
      sum_min >= space ->
        Enum.map(cols, &elem(&1, 0))

      sum_max <= space ->
        # more room than the content wants: grow in proportion to the preferred width
        extra = space - sum_max
        spread(Enum.map(cols, &elem(&1, 1)), extra, sum_max)

      true ->
        t = (space - sum_min) / (sum_max - sum_min)

        widths = Enum.map(cols, fn {mn, mx} -> mn + (mx - mn) * t end)
        round_to(widths, space)
    end
  end

  defp spread(widths, 0, _total), do: widths

  defp spread(widths, extra, total) do
    weights = if total > 0, do: widths, else: List.duplicate(1, length(widths))
    sum = Enum.sum(weights)
    grown = Enum.zip(widths, weights) |> Enum.map(fn {w, wt} -> w + extra * wt / sum end)
    round_to(grown, Enum.sum(widths) + extra)
  end

  # whole pixels that still add up to `total`
  defp round_to(widths, total) do
    floors = Enum.map(widths, &floor/1)
    missing = total - Enum.sum(floors)

    order =
      widths
      |> Enum.with_index()
      |> Enum.sort_by(fn {w, i} -> {-(w - floor(w)), i} end)
      |> Enum.map(&elem(&1, 1))
      |> Enum.take(max(missing, 0))

    floors |> Enum.with_index() |> Enum.map(fn {w, i} -> if i in order, do: w + 1, else: w end)
  end

  defp column_positions(widths, sx) do
    {xs, _} = Enum.map_reduce(widths, sx, fn w, x -> {x, x + w + sx} end)
    xs
  end

  defp row_positions(heights, sy, top) do
    {ys, _} = Enum.map_reduce(heights, top + sy, fn h, y -> {y, y + h + sy} end)
    ys
  end

  # a row is as tall as its tallest cell; cells spanning rows add what is missing to their
  # last row
  # rows grow in proportion to their height (equally when none has any) to fill `target`
  defp grow_rows(heights, target, fixed) when is_number(target) do
    extra = round(target) - fixed - Enum.sum(heights)
    total = Enum.sum(heights)

    cond do
      extra <= 0 or heights == [] ->
        heights

      total == 0 ->
        n = length(heights)

        heights
        |> Enum.with_index()
        |> Enum.map(fn {h, i} -> h + div(extra, n) + if(i < rem(extra, n), do: 1, else: 0) end)

      true ->
        {grown, _} =
          Enum.map_reduce(heights, {0, total}, fn h, {given, rest} ->
            share = if rest == 0, do: 0, else: round((extra - given) * h / rest)
            {h + share, {given + share, rest - h}}
          end)

        grown
    end
  end

  defp grow_rows(heights, _, _), do: heights

  defp table_row_heights(sized, nrows, sy) do
    base = List.duplicate(0, nrows)

    single =
      sized
      |> Enum.filter(&(min(&1.cell.rowspan, nrows - &1.row) == 1))
      |> Enum.reduce(base, fn p, heights ->
        List.update_at(heights, p.row, &max(&1, max(p.h0, round(p.cell.minh || 0))))
      end)

    sized
    |> Enum.filter(&(min(&1.cell.rowspan, nrows - &1.row) > 1))
    |> Enum.sort_by(& &1.cell.rowspan)
    |> Enum.reduce(single, fn p, heights ->
      rs = min(p.cell.rowspan, nrows - p.row)
      have = heights |> Enum.slice(p.row, rs) |> Enum.sum() |> Kernel.+(sy * (rs - 1))
      need = max(p.h0, round(p.cell.minh || 0)) - have
      if need > 0, do: List.update_at(heights, p.row + rs - 1, &(&1 + need)), else: heights
    end)
  end

  # -- percentage margins and padding -------------------------------------------------------

  @box_props ~w(margin-top margin-right margin-bottom margin-left
                padding-top padding-right padding-bottom padding-left)

  # A box laid out on its own (inline-block, float, flex item, cell) is built with a new
  # reference width for its children, but its own percentage margins and padding refer to
  # the width outside it: turn them into px before that changes.
  defp resolve_box_pct(c, outer) do
    Enum.reduce(@box_props, c, fn key, acc ->
      case acc[key] do
        {:pct, f} -> Map.put(acc, key, f * outer * 1.0)
        _ -> acc
      end
    end)
  end

  defp sized_by({:pct, f}, outer), do: round(f * outer)
  defp sized_by(w, _outer) when is_number(w), do: round(w)
  defp sized_by(_, outer), do: outer

  # runs `fun` with `width` as the containing block's width, then puts the old one back
  # whether the block being built has a height its children's percentages can refer to
  defp own_definite?(tag, c) do
    is_number(c["height"]) or (match?({:pct, _}, c["height"]) and percent_definite?(tag))
  end

  # a percentage height has something to refer to: the window (for the root) or a block with a
  # height of its own
  defp percent_definite?(tag), do: tag == "html" or Process.get(:layout_definite, false)

  defp with_definite(value, fun) do
    previous = Process.get(:layout_definite, false)
    Process.put(:layout_definite, value)

    try do
      fun.()
    after
      Process.put(:layout_definite, previous)
    end
  end

  defp with_cw(width, fun) do
    previous = containing_width()
    Process.put(:layout_cw, width)

    try do
      fun.()
    after
      Process.put(:layout_cw, previous)
    end
  end

  # the width of a block's content box, which its children's percentages refer to: its width
  # (or what is left of the container) less padding and borders
  defp child_width(c, box) do
    outer = containing_width()
    {_bt, br, _bb, bl} = box.bw
    extras = box.pl + box.pr + bl + br
    ml = if box.ml == :auto, do: 0, else: box.ml
    mr = if box.mr == :auto, do: 0, else: box.mr
    border_box? = c["box-sizing"] == "border-box"
    sized = fn w -> if border_box?, do: w - extras, else: w end

    width =
      case dim(c["width"]) do
        nil -> outer - ml - mr - extras
        {:pct, f} -> sized.(f * outer)
        w when is_number(w) -> sized.(w)
        _ -> outer - ml - mr - extras
      end

    width =
      case c["max-width"] do
        m when is_number(m) -> min(width, sized.(m))
        {:pct, f} -> min(width, sized.(f * outer))
        _ -> width
      end

    max(round(width), 0)
  end

  # -- transforms --------------------------------------------------------------------------

  # what a box needs to work out its transformation once its size is known
  defp xform_spec(c) do
    if Browser.Transform.transformed?(c) do
      %{
        c: Map.take(c, Browser.Transform.props() ++ ["transform-origin", "font-size"]),
        # boxes placed with `top`/`left` have had their translation applied to their position
        translate?: c["position"] not in ["absolute", "fixed"]
      }
    end
  end

  defp xform_matrix(%{c: c, translate?: translate?}, rect),
    do: Browser.Transform.matrix(c, rect, translate: translate?)

  # everything the box painted is drawn through the box's transformation
  defp xform_new(st, %{o: o} = box, height) do
    case xform_matrix(o.xform, {box.x, box.top, box.w, height}) do
      nil ->
        st

      matrix ->
        {new_items, old_items} = Enum.split(st.items, st.n - box.n0)
        {new_rects, old_rects} = Enum.split(st.rects, st.nr - box.nr0)
        {new_over, old_over} = Enum.split(st.overlays, length(st.overlays) - box.ov0)

        %{
          st
          | items: with_xform(new_items, matrix) ++ old_items,
            rects: with_xform(new_rects, matrix) ++ old_rects,
            overlays: Enum.map(new_over, &with_xform(&1, matrix)) ++ old_over
        }
    end
  end

  # a picture's box and what is drawn in it, through the picture's own transformation
  defp transformed_picture(%{xform: nil}, items, _rect), do: items

  defp transformed_picture(%{xform: xform}, items, rect) do
    case xform_matrix(xform, rect) do
      nil -> items
      matrix -> with_xform(items, matrix)
    end
  end

  # (transformations of boxes inside come first in the list; the outermost last)
  defp with_xform(items, matrix),
    do: Enum.map(items, &Map.update(&1, :xform, [matrix], fn list -> list ++ [matrix] end))

  # -- floats --------------------------------------------------------------------------------

  # `z-index`: the order sticky and fixed boxes are painted in
  defp z_index(c) do
    case Integer.parse(to_string(c["z-index"])) do
      {n, ""} -> n
      _ -> 0
    end
  end

  defp float_side(c) do
    case c["float"] do
      "left" -> :left
      "right" -> :right
      _ -> nil
    end
  end

  # `clear` only applies to block-level boxes: not to the parts of a table
  @table_parts ~w(table-row-group table-header-group table-footer-group table-row table-cell
                  table-column table-column-group)

  defp clear_side(%{"display" => d}) when d in @table_parts, do: nil

  defp clear_side(c) do
    case c["clear"] do
      "left" -> :left
      "right" -> :right
      "both" -> :both
      _ -> nil
    end
  end

  # a floated element: laid out on its own like an inline-block, then placed by `op({:float, ...})`
  defp float_ops({:element, _, _, _} = el, parent_style, c, acc) do
    side = float_side(c)

    [{:inline_block, sub, spec, style}] =
      inline_block_ops(el, parent_style, c, [], true, c["display"] == "table")

    [{:float, side, sub, Map.put(spec, :clear, clear_side(c)), style} | acc]
  end

  defp clear_top(st, nil), do: st.y

  defp clear_top(st, side) do
    st.floats
    |> Enum.filter(&(side == :both or &1.side == side))
    |> Enum.map(& &1.y1)
    |> Enum.max(fn -> st.y end)
    |> max(st.y)
  end

  # how far floats take from the line starting at `y`: {from the left, from the right}
  defp float_offsets(%{floats: []}, _y), do: {0, 0}

  defp float_offsets(st, y), do: float_offsets(st, y, y + 1)

  # ... or across the vertical span y0..y1
  defp float_offsets(st, y0, y1) do
    left = st.margin + st.left
    right = st.width - st.margin - st.right
    active = Enum.filter(st.floats, &(&1.y0 < y1 and &1.y1 > y0))

    fl = for(%{side: :left} = f <- active, do: f.x1 - left) |> Enum.max(fn -> 0 end)
    fr = for(%{side: :right} = f <- active, do: right - f.x0) |> Enum.max(fn -> 0 end)
    {max(fl, 0), max(fr, 0)}
  end

  # the top-left corner of a float `w` x `h` whose top is no higher than `y`: lower down when the
  # floats beside it leave no room
  defp place_float(st, side, w, h, y, left, right) do
    {fl, fr} = float_offsets(st, y, y + max(h, 1))
    overlapping = Enum.filter(st.floats, &(&1.y0 < y + max(h, 1) and &1.y1 > y))

    if overlapping == [] or w <= right - fr - (left + fl) do
      x = if side == :left, do: left + fl, else: right - fr - w
      {x, y}
    else
      # below the lowest edge of the floats in the way, and look again
      next = overlapping |> Enum.map(& &1.y1) |> Enum.min()
      place_float(st, side, w, h, next, left, right)
    end
  end

  # the floats made since `count` stop affecting what follows, and the box grows to hold them
  defp contain_floats(st, count) do
    mine = Enum.take(st.floats, max(length(st.floats) - count, 0))

    case mine do
      [] ->
        st

      _ ->
        bottom = mine |> Enum.map(& &1.y1) |> Enum.max()
        %{st | floats: Enum.drop(st.floats, length(mine)), y: max(st.y, bottom)}
    end
  end
end
