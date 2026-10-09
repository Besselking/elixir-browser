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

  Option `boxes: true` gives every element its own box in the result (a `:box` item when it
  draws nothing), for scripts that ask for the size of any element.

  Option `scrollers: true` keeps the `:scroller` items that say where the boxes with
  `overflow: scroll | auto` are (see `Browser.Scrollers`); without it they are left out.

  Option `focus: %{cid: id, caret: {line, column}}` adds a `:ring` item around the
  focused form control and a `:caret` item at the given position of its text.
  """
  def layout(nodes, width, measure, view_height \\ 768, opts \\ []) do
    measure = spaced(measure)
    # (a tab-size given as a length is turned into columns with the width of a space)
    Process.put(:layout_measure, measure)
    Process.put(:layout_boxes, Keyword.get(opts, :boxes, false))

    style = %{
      size: @base,
      bold: false,
      italic: false,
      mono: false,
      family: nil,
      href: nil,
      blank: false,
      pre: false,
      ws: :normal,
      # inside an inline box (a block in it splits the box)
      inl: false,
      tab: 8,
      # the width of a space in the font of the block container: what `tab-size` counts in
      bspace: nil,
      # a tab: `{tab-size in px, half a space}`, its width depends on where it falls on the line
      tabw: nil,
      hyph: "-",
      hidden: false,
      tiny: false,
      vhidden: false,
      color: {0, 0, 0},
      underline: false,
      strike: false,
      alast: nil,
      vs: 0,
      wrap_chars: :none,
      keep_all: false,
      lang: nil,
      wst: :none,
      shy: true,
      nojust: false,
      ls: 0.0,
      wsp: 0.0,
      tt: :none,
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
    Process.put(:layout_viewport, {0, 0, width, view_height})
    Process.put(:layout_metrics, opts[:metrics])
    {nodes, canvas} = propagate_background(nodes)
    t0 = System.monotonic_time(:microsecond)
    ops = nodes |> walk(style, []) |> Enum.reverse() |> trim_line_end_spaces()
    t1 = System.monotonic_time(:microsecond)
    {items, height} = place(ops, width, measure, view_height, opts[:images], margin)
    # column break markers that no column set read
    items = Enum.reject(items, &(&1.type == :colbreak))

    if System.get_env("LAYOUT_TIMES"),
      do:
        IO.puts(
          :stderr,
          "walk #{div(t1 - t0, 1000)}ms place #{div(System.monotonic_time(:microsecond) - t1, 1000)}ms ops=#{length(ops)}"
        )

    # absolutely positioned boxes take no room in the flow but do extend the scrollable page
    height = max(height, content_bottom(items))
    items = add_focus(items, measure, opts[:focus])
    items = if opts[:scrollers], do: items, else: Enum.reject(items, &(&1.type == :scroller))

    case canvas do
      nil ->
        {items, height}

      canvas ->
        {[canvas_item(canvas, width, height, view_height, opts[:images]) | items], height}
    end
  end

  # `letter-spacing` adds its length after every character, `word-spacing` after every space
  defp spaced(measure) do
    fn
      :content_height, style ->
        measure.(:content_height, style)

      # (text of a font size under one pixel takes no room)
      _text, %{tiny: true} ->
        0

      text, style ->
        # (a zero-width space takes no room)
        measured =
          if String.contains?(text, "\u200B"), do: String.replace(text, "\u200B", ""), else: text

        measure.(measured, style) + extra_width(text, style)
    end
  end

  defp extra_width(text, %{ls: ls, wsp: wsp}) when ls != 0 or wsp != 0,
    do: round(ls * spaced_length(text) + wsp * count_spaces(text))

  defp extra_width(_text, _style), do: 0

  # the spacing after the last letter of a line does not count towards fitting it
  defp trailing_ls(%{ls: ls}) when ls > 0, do: round(ls)
  defp trailing_ls(_style), do: 0

  # zero-width format characters receive no letter-spacing
  defp spaced_length(text) do
    if String.match?(text, ~r/[\x{200B}-\x{200D}\x{2060}\x{FEFF}]/u),
      do: String.length(String.replace(text, ~r/[\x{200B}-\x{200D}\x{2060}\x{FEFF}]/u, "")),
      else: String.length(text)
  end

  defp count_spaces(text), do: text |> String.graphemes() |> Enum.count(&(&1 in [" ", "\u00A0"]))

  # A block-level table too wide for the room the floats leave beside it is laid out again in
  # that room, when it can be that narrow, rather than moved below them.
  defp table_beside_floats(
         %{floats: [_ | _]} = st,
         sub,
         %{block_table?: true, width: nil} = spec,
         avail,
         {w, _, h, _} = first
       ) do
    y = st.y + st.gap + st.ngap
    {fl, fr} = float_offsets(st, y, y + max(h, 1))
    beside = avail - fl - fr

    if (fl > 0 or fr > 0) and w > beside and beside > 0 do
      w2 = fit_width(st, sub, spec, beside)

      if w2 <= beside do
        {items, height, base} = layout_atom(st, sub, w2, Map.get(spec, :key))
        {w2, items, height, base}
      else
        first
      end
    else
      first
    end
  end

  defp table_beside_floats(_st, _sub, _spec, _avail, first), do: first

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
    # and in a scrolling box it scrolls with the control
    src = Enum.find(items, &(Map.get(&1, :cid) == cid and Map.has_key?(&1, :sc)))
    extra = if src, do: Enum.map(extra, &Map.merge(&1, Map.take(src, [:sc, :clips]))), else: extra
    extra = if stick, do: Enum.map(extra, &Map.put(&1, :stick, stick)), else: extra
    # and above the box it is in: fixed items are drawn in the order of their `z`
    z = Enum.find_value(items, &(Map.get(&1, :cid) == cid && Map.get(&1, :z)))
    extra = if z, do: Enum.map(extra, &Map.put(&1, :z, z)), else: extra
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
        # (the root's background goes to the canvas even with `display: contents`)
        has_background?(root_computed(hattrs)) ->
          html = {:element, "html", without_background(hattrs), kids}

          {List.replace_at(nodes, i, html),
           canvas_style(root_computed(hattrs), root_computed(hattrs))}

        body && has_background?(computed(elem(body, 2))) ->
          {:element, "body", battrs, bkids} = body
          body = {:element, "body", without_background(battrs), bkids}
          html = {:element, "html", hattrs, List.replace_at(kids, body_i, body)}
          {List.replace_at(nodes, i, html), canvas_style(computed(battrs), computed(hattrs))}

        true ->
          {nodes, nil}
      end
    else
      _ -> {nodes, nil}
    end
  end

  @background_keys ~w(background-color background-image background-attachment background-repeat background-position background-size)

  defp root_computed(attrs) do
    case List.keyfind(attrs, "@computed", 0) do
      {_, map} -> map
      nil -> %{}
    end
  end

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

  defp canvas_style(c, root) do
    %{
      root: if(root["display"] != "contents", do: box("html", root)),
      color: if(color?(c["background-color"]), do: over_white(c["background-color"])),
      bgimg: bgimg_spec(c),
      current: if(match?({_, _, _}, c["color"]), do: c["color"], else: {0, 0, 0})
    }
  end

  defp canvas_item(canvas, width, doc_height, view_height, images) do
    height = max(doc_height, view_height)
    clip = {0, 0, width, height}

    # the images are placed in the root element's padding box
    area =
      case canvas.root do
        %{bw: {bt, br, bb, bl}} = r ->
          ml = auto_zero(r.ml)
          mr = auto_zero(r.mr)
          mt = r.mt
          {ml + bl, mt + bt, max(width - ml - mr - bl - br, 0), max(doc_height - mt - bt - bb, 0)}

        _ ->
          clip
      end

    layers =
      if canvas.bgimg,
        do:
          Backgrounds.paint_layers(
            canvas.bgimg,
            area,
            clip,
            images,
            color4(canvas.current),
            viewport_area()
          ),
        else: []

    %{type: :canvas, color: canvas.color, layers: layers, x: 0, y: 0, w: width, h: height}
  end

  # the window a `fixed` background is placed against
  defp viewport_area, do: Process.get(:layout_viewport)

  defp color4({r, g, b}), do: {r, g, b, 255}
  defp color4(_), do: {0, 0, 0, 255}

  # -- tree -> ops ---------------------------------------------------------------
  #
  # ops: {:word, text, style[, :pre]} {:space, style} {:marker, text, style}
  #      {:flush} {:gap, px} {:pad, px} {:hr} {:box_start, ref, color, left} {:box_end, ref}

  # `display: run-in`: a run-in box becomes the first inline box of the block that follows it
  # (floats, positioned boxes and white space between them do not count); without such a block,
  # or when it holds blocks itself, it is a block of its own
  defp run_ins(nodes, style) do
    if Enum.any?(nodes, &run_in?/1) do
      keep = style.ws not in [:normal, :nowrap]

      # the block each run-in runs into, by position: %{run-in index => block index}
      into =
        for {node, i} <- Enum.with_index(nodes),
            run_in?(node),
            not run_in_blocks?(node),
            {between, _target, _rest} <- [run_in_target(Enum.drop(nodes, i + 1), [], keep)],
            into: %{},
            do: {i, i + length(between) + 1}

      runners = Map.new(into, fn {i, j} -> {j, Enum.at(nodes, i)} end)

      nodes
      |> Enum.with_index()
      |> Enum.flat_map(fn {node, i} ->
        cond do
          Map.has_key?(into, i) ->
            []

          run_in?(node) ->
            [set_display(node, "block")]

          runner = runners[i] ->
            # (`clear` on a run-in applies to the block it runs into)
            node =
              case computed(elem(runner, 2)) do
                %{"clear" => clear} -> set_prop(node, "clear", clear)
                _ -> node
              end

            {:element, tag, attrs, kids} = node
            [{:element, tag, attrs, [set_display(runner, "inline") | kids]}]

          true ->
            [node]
        end
      end)
    else
      nodes
    end
  end

  # the first thing after a run-in that is not skipped: {skipped nodes, it, the rest}
  defp run_in_target(nodes, between, keep)

  defp run_in_target([{:text, t} = node | rest], between, keep) when is_binary(t) do
    if String.trim(t) == "" and not keep,
      do: run_in_target(rest, [node | between], keep),
      else: nil
  end

  defp run_in_target([{:element, tag, attrs, _} = node | rest], between, keep) do
    c = computed(attrs)

    cond do
      tag in @skip or c["display"] == "none" ->
        run_in_target(rest, [node | between], keep)

      c["position"] in ["absolute", "fixed"] or float_side(c) != nil ->
        run_in_target(rest, [node | between], keep)

      c["display"] in ["block", "flow-root", "list-item"] or
          (c["display"] == nil and legacy_kind(tag) == :block) ->
        {Enum.reverse(between), node, rest}

      true ->
        nil
    end
  end

  defp run_in_target(_nodes, _between, _keep), do: nil

  defp run_in?({:element, _tag, attrs, _}) do
    c = computed(attrs)

    c["display"] == "run-in" and c["position"] not in ["absolute", "fixed"] and
      float_side(c) == nil
  end

  defp run_in?(_), do: false

  defp run_in_blocks?({:element, _, _, kids}) do
    Enum.any?(kids, fn
      {:element, tag, attrs, _} ->
        kind(tag, computed(attrs)) in [:block, :list_item, :table, :flex, :grid]

      _ ->
        false
    end)
  end

  defp set_display(node, display), do: set_prop(node, "display", display)

  defp set_prop({:element, tag, attrs, kids}, prop, value) do
    attrs =
      List.update_at(attrs, Enum.find_index(attrs, &match?({"@computed", _}, &1)), fn {k, c} ->
        {k, Map.put(c, prop, value)}
      end)

    {:element, tag, attrs, kids}
  end

  defp walk(nodes, style, acc) when is_list(nodes),
    do: nodes |> run_ins(style) |> wrap_table_parts() |> Enum.reduce(acc, &walk(&1, style, &2))

  # a soft hyphen (U+00AD) is invisible unless a line breaks at it, and `hyphens: none` takes
  # that away: it is dropped from the laid-out text (the DOM text keeps it)
  defp walk({:text, t}, %{tt: tt} = style, acc) when is_binary(t) and tt != :none,
    do:
      walk(
        {:text, transform_text(collapse_for(t, tt, style), tt, {acc, style.lang})},
        %{style | tt: :none},
        acc
      )

  defp walk({:text, t}, style, acc) when is_binary(t) do
    if String.contains?(t, "\u00AD") and not style.shy,
      do: walk({:text, String.replace(t, "\u00AD", "")}, style, acc),
      else: walk_text(t, style, acc)
  end

  defp walk({:element, tag, _, _}, _style, acc) when tag in @skip, do: acc
  # a line break that clears floats ends the line and moves down below them, taking no line of
  # its own
  defp walk({:element, "br", attrs, _}, style, acc) do
    case clear_side(computed(attrs)) do
      nil -> [{:br, style} | acc]
      side -> [{:clear, side}, {:flush} | acc]
    end
  end

  # <wbr> is a place to break, like a zero-width space
  defp walk({:element, "wbr", attrs, _}, style, acc) do
    style = restyle("wbr", attrs, style, computed(attrs))
    walk_zwsp_text("\u200B", style, acc)
  end

  defp walk({:element, tag, attrs, _} = el, style, acc) when tag in ["img", "svg", "canvas"] do
    ops = fn acc ->
      case tag do
        "img" -> image_ops(el, style, acc)
        "canvas" -> canvas_ops(el, style, acc)
        _ -> svg_ops(el, style, acc)
      end
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

  # `margin-trim`: the container drops the margins of the children at its edges, so they do not
  # add to the space around it (a block's first and last child, a flex container's first and
  # last items along either axis)
  defp trim_margins(kids, c) do
    case trim_sides(c["margin-trim"]) do
      [] -> kids
      sides -> trim_children(kids, sides, c)
    end
  end

  defp trim_sides(v) when is_binary(v) do
    v
    |> String.split()
    |> Enum.flat_map(fn
      "block" -> [:bs, :be]
      "block-start" -> [:bs]
      "block-end" -> [:be]
      "inline" -> [:is, :ie]
      "inline-start" -> [:is]
      "inline-end" -> [:ie]
      _ -> []
    end)
    |> Enum.uniq()
  end

  defp trim_sides(_), do: []

  defp trim_children(kids, sides, c) do
    idx =
      kids
      |> Enum.with_index()
      |> Enum.filter(fn
        {{:element, _, attrs, _}, _} ->
          ic = computed(attrs)

          not hidden?(ic) and ic["position"] not in ["absolute", "fixed"] and
            float_side(ic) == nil

        {{:text, t}, _} ->
          String.trim(t) != ""

        _ ->
          false
      end)
      |> Enum.map(&elem(&1, 1))

    case idx do
      [] ->
        kids

      _ ->
        keys =
          case c["display"] do
            d when d in ["flex", "inline-flex"] ->
              flex_trim(
                sides,
                c["flex-direction"],
                wraps?(c["flex-wrap"]),
                idx
              )

            d when d in ["grid", "inline-grid"] ->
              grid_trim(sides, kids, idx, c)

            _ ->
              block_trim(sides, kids, idx)
          end

        kids
        |> Enum.with_index()
        |> Enum.map(fn
          {{:element, tag, attrs, sub} = kid, i} ->
            if props = keys[i], do: trim_element(tag, attrs, sub, props), else: kid

          {kid, _} ->
            kid
        end)
    end
  end

  # a self-collapsing child at the edge lets the margin of its neighbour through, so that is
  # trimmed too
  defp block_trim(sides, kids, idx) do
    %{}
    |> trim_run(:bs in sides, kids, idx, :top)
    |> trim_run(:be in sides, kids, Enum.reverse(idx), :bottom)
  end

  defp trim_run(m, false, _, _, _), do: m

  defp trim_run(m, true, kids, idx, side) do
    {empty, rest} = Enum.split_while(idx, &self_collapsing?(Enum.at(kids, &1)))
    # (a self-collapsing box has no margin of its own: its top and bottom both run through it)
    m =
      Enum.reduce(empty, m, fn i, m ->
        m |> add_trim(true, i, :top) |> add_trim(true, i, :bottom)
      end)

    if rest == [], do: m, else: add_trim(m, true, hd(rest), side)
  end

  defp self_collapsing?({:element, _, attrs, sub}) do
    c = computed(attrs)

    c["display"] in [nil, "block"] and c["height"] in [nil, 0, 0.0] and
      Enum.all?(
        sub,
        &(match?({:text, t} when is_binary(t), &1) and String.trim(elem(&1, 1)) == "")
      ) and
      px(c["padding-top"] || 0) == 0 and px(c["padding-bottom"] || 0) == 0 and
      border_w(c, "top") == 0 and border_w(c, "bottom") == 0
  end

  defp self_collapsing?(_), do: false

  defp flex_trim(sides, dir, wrap?, idx) do
    dir = flex_direction(dir)
    col? = dir in [:column, :column_reverse]
    {first, last} = {hd(idx), List.last(idx)}

    {main_start, main_end} =
      if dir in [:row_reverse, :column_reverse], do: {last, first}, else: {first, last}

    # across the lines every item is at an edge; along them only the first and last are
    {cross, _} = {idx, nil}
    {block_items, inline_items} = if col?, do: {[main_start], cross}, else: {cross, [main_start]}

    %{}
    |> add_trim_all(:bs in sides, block_items, :top)
    |> add_trim_all(:be in sides, if(col?, do: [main_end], else: cross), :bottom)
    # across the lines of a wrapping column it is the first and last line that are trimmed: done
    # when the lines are known
    |> add_trim_all(:is in sides and not (col? and wrap?), inline_items, :left)
    |> add_trim_all(
      :ie in sides and not (col? and wrap?),
      if(col?, do: cross, else: [main_end]),
      :right
    )
  end

  # the items of a grid that are placed automatically, row by row, are at its edges when they
  # are in the first or last row or column
  defp grid_trim(sides, kids, idx, c) do
    cols = c["grid-template-columns"] |> grid_tracks(16) |> length() |> max(1)

    placed? =
      Enum.any?(idx, fn i ->
        case Enum.at(kids, i) do
          {:element, _, attrs, _} ->
            ic = computed(attrs)
            Enum.any?(~w(grid-row grid-column grid-area), &(ic[&1] not in [nil, "auto"]))

          _ ->
            false
        end
      end)

    if placed? or c["grid-auto-flow"] in ["column", "column dense"] do
      %{}
    else
      rows = div(length(idx) + cols - 1, cols)

      idx
      |> Enum.with_index()
      |> Enum.reduce(%{}, fn {i, k}, m ->
        {row, col} = {div(k, cols), rem(k, cols)}

        m
        |> add_trim(:bs in sides and row == 0, i, :top)
        |> add_trim(:be in sides and row == rows - 1, i, :bottom)
        |> add_trim(:is in sides and col == 0, i, :left)
        |> add_trim(:ie in sides and col == cols - 1, i, :right)
      end)
    end
  end

  defp add_trim(m, false, _, _), do: m
  defp add_trim(m, true, i, side), do: Map.update(m, i, [side], &[side | &1])

  defp add_trim_all(m, cond?, items, side),
    do: Enum.reduce(items, m, &add_trim(&2, cond?, &1, side))

  defp trim_element(tag, attrs, sub, props) do
    c = computed(attrs)
    c = Enum.reduce(props, c, &Map.put(&2, "margin-" <> Atom.to_string(&1), 0))
    attrs = List.keyreplace(attrs, "@computed", 0, {"@computed", c})

    # a margin that ran through the child to its own first or last child is trimmed too
    sub =
      Enum.reduce(props, sub, fn
        side, sub when side in [:top, :bottom] -> trim_through(sub, side, c)
        _, sub -> sub
      end)

    {:element, tag, attrs, sub}
  end

  defp trim_through(kids, side, c) do
    open? =
      if side == :top,
        do: px(c["padding-top"] || 0) == 0 and border_w(c, "top") == 0,
        else:
          px(c["padding-bottom"] || 0) == 0 and border_w(c, "bottom") == 0 and c["height"] == nil

    if open? and c["display"] in [nil, "block"] and c["overflow-x"] in [nil, "visible"],
      do: trim_children(kids, [if(side == :top, do: :bs, else: :be)], %{}),
      else: kids
  end

  # a floated part of a table is a block that holds an anonymous table around it
  @float_table_parts ~w(table-row-group table-header-group table-footer-group table-row table-cell table-caption table-column
                         table-column-group)

  defp walk_element({:element, tag, attrs, kids}, parent_style, acc, nil = force)
       when tag != "@float" do
    c = computed(attrs)

    if c["float"] in ["left", "right"] and c["display"] in @float_table_parts do
      anon = fn display, kids ->
        {:element, "@float", [{"@computed", %{"display" => display}}], kids}
      end

      # the rows or cells it held are those of a table of their own
      kids =
        case c["display"] do
          "table-row" -> [anon.("table", [anon.("table-row", kids)])]
          d when d in ["table-cell", "table-caption"] -> kids
          _ -> [anon.("table", kids)]
        end

      el = {:element, tag, put_computed(attrs, Map.put(c, "display", "block")), kids}

      walk_element(el, parent_style, acc, force)
    else
      walk_element_inner({:element, tag, attrs, kids}, parent_style, acc, force)
    end
  end

  defp walk_element(el, parent_style, acc, force),
    do: walk_element_inner(el, parent_style, acc, force)

  defp put_computed(attrs, c), do: List.keyreplace(attrs, "@computed", 0, {"@computed", c})

  defp walk_element_inner({:element, tag, attrs, kids}, parent_style, acc, force) do
    c = computed(attrs)
    kids = trim_margins(kids, c)
    el = {:element, tag, attrs, kids}

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

      fit? =
        (c["width"] in [:fit, :minc, :maxc] or fitc?(c["width"]) or kw?(c["max-width"]) or
           kw?(c["min-width"])) and
          kind in [:block, :flex, :grid]

      # laying a flex or grid container out at width 1 does not give its min-content width (a
      # wrapping row does: every item is on a line of its own)
      c =
        if c["width"] == :minc and kind != :block and
             not (kind in [:flex, :inline_block] and inner_kind(c) == :flex and
                    wraps?(c["flex-wrap"]) and
                    c["flex-direction"] in [nil, "row", "row-reverse"]),
           do: Map.put(c, "width", :fit),
           else: c

      table? = kind == :table and force != :inline_inner
      float? = force == nil and c["float"] in ["left", "right"]

      case kind do
        _ when float? and kind != :contents ->
          float_ops(el, parent_style, c, acc)

        # (what is in it goes on the line as if it were in the parent: text on either side is
        # one run)
        :contents ->
          acc = [{:run_on} | acc]
          acc = walk(kids, style, acc)
          [{:run_on} | acc]

        :inline ->
          inline_ops(tag, kids, style, parent_style, c, acc)

        :inline_block ->
          hoist_atom(inline_block_ops(el, parent_style, c, acc))

        # `width: fit-content`: a block as wide as its content, on a line of its own
        _ when fit? ->
          acc = if side = clear_side(c), do: [{:clear, side}, {:flush} | acc], else: acc
          acc = [{:flush} | acc]
          acc = hoist_atom(inline_block_ops(el, parent_style, c, acc, true))
          [{:flush} | acc]

        # a table is as wide as its columns need, on a line of its own
        _ when table? ->
          {mt, mb} = vertical_margins(c)
          acc = if side = clear_side(c), do: [{:clear, side}, {:flush} | acc], else: acc
          acc = [{:gap, mt}, {:flush} | acc]
          acc = hoist_atom(inline_block_ops(el, parent_style, c, acc, true, true))
          [{:gap, mb}, {:flush} | acc]

        kind ->
          # an element that can be linked to (`#id`) needs to know where its box starts, which
          # nothing drawn says for a plain block
          c = if List.keymember?(attrs, "id", 0), do: Map.put(c, :anchor, true), else: c

          # a block inside an inline box splits the box: what is before and after it
          # are fragments of their own
          if parent_style.inl do
            acc = [{:ib_split} | acc]
            acc = block_ops(tag, kind, kids, %{style | inl: false}, c, acc)
            [{:ib_join} | acc]
          else
            block_ops(tag, kind, kids, %{style | inl: false}, c, acc)
          end
      end
    end
  end

  # An out-of-flow element is laid out on its own and placed by `place/4`
  # relative to its containing block; it takes no space in the flow. Its width
  # properties belong to the placement, so they are removed from the element's
  # own box.
  defp image_sub({:element, "img", _, _} = el, style), do: image_ops(el, style, [])
  defp image_sub({:element, "canvas", _, _} = el, style), do: canvas_ops(el, style, [])
  defp image_sub(el, style), do: svg_ops(el, style, [])

  defp abs_ops({:element, tag, attrs, kids}, parent_style, c, acc) do
    if hidden?(c) do
      acc
    else
      box = box(tag, c)
      # a picture is sized by its own width and height: they stay with it
      replaced? = tag in ["img", "svg", "canvas"]

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

      # a `calc()` with a percentage is of the containing block of this box, not of the box
      # it was written in: it stays unresolved until the box is placed
      raw = attrs |> List.keyfind("@computed", 0) |> elem(1)
      calc = fn key -> match?({:calc, _, _}, raw[key]) && raw[key] end

      attrs = List.keyreplace(attrs, "@computed", 0, {"@computed", own})
      el = {:element, tag, attrs, kids}

      sub =
        if replaced? do
          el |> image_sub(parent_style) |> Enum.reverse()
        else
          # a `calc()` with a percentage in it is of this box's width, when that is given
          walk = fn -> el |> walk_element(parent_style, [], :abs_inner) |> Enum.reverse() end

          case dim(c["width"]) do
            w when is_number(w) or (is_tuple(w) and elem(w, 0) == :pct) ->
              with_cw(child_width(c, box), walk)

            _ ->
              walk.()
          end
        end

      {_, br, _, bl} = box.bw
      border_box? = c["box-sizing"] == "border-box"

      spec = %{
        key: make_ref(),
        top: c["top"],
        left: c["left"],
        right: c["right"],
        bottom: c["bottom"],
        width:
          if(replaced? or raw["width"] == :stretch,
            do: nil,
            else: calc.("width") || dim(c["width"])
          ),
        stretch: raw["width"] == :stretch,
        replaced: replaced?,
        minw: if(replaced?, do: nil, else: calc.("min-width") || c["min-width"]),
        maxw: if(replaced?, do: nil, else: calc.("max-width") || c["max-width"]),
        ml: box.ml,
        mr: box.mr,
        rtl: parent_style.cb,
        # width properties size the content box unless box-sizing says otherwise
        extra: if(border_box?, do: 0, else: box.pl + box.pr + bl + br),
        rextra: box.pr + br,
        mextra: 0,
        fixed: c["position"] == "fixed",
        # `width: fit-content` between two insets shrinks to the content, not stretches
        fit:
          c["width"] in [:fit, :minc, :maxc] or tag == "table" or
            c["display"] in ["table", "inline-table"],
        # an inline-level box is where it would be on a line: beside the floats
        inline: kind(tag, c) in [:inline, :inline_block],
        align: parent_style.align,
        autoh: not replaced? and c["height"] in [nil, :auto] and c["max-height"] != :fit,
        mta: c["margin-top"] == :auto,
        mba: c["margin-bottom"] == :auto,
        mb: box.mb,
        hstretch: c["height"] == :hstretch,
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
        image_atom(url, info, attrs, c, style, acc, %{pstyle: parent_style})

      match?({:svg, _, _, _}, info) ->
        {:svg, w, h, scene} = info
        extra = %{scene: scene, intrinsic: {w, h}, paint?: true, current: color4(c["color"])}
        image_atom(url, nil, attrs, c, style, acc, Map.put(extra, :pstyle, parent_style))

      url != nil and info == nil and is_map(images) and declared != nil ->
        image_atom(url, nil, attrs, c, style, acc, %{pstyle: parent_style})

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
      maxh: c["max-height"],
      ratio: aspect_ratio(c["aspect-ratio"]),
      pad: nil
    }
  end

  # with `box-sizing: border-box` the sizes of a picture include its padding and border
  defp content_sizes(css, %{"box-sizing" => "border-box"}, box) do
    {bt, br, bb, bl} = box.bw
    hx = box.pl + box.pr + bl + br
    vx = box.pt + box.pb + bt + bb
    less = fn v, x -> if is_number(v), do: max(v - x, 0), else: v end

    %{
      css
      | pad: {hx, vx},
        w: less.(css.w, hx),
        minw: less.(css.minw, hx),
        maxw: less.(css.maxw, hx),
        h: less.(css.h, vx),
        minh: less.(css.minh, vx),
        maxh: less.(css.maxh, vx)
    }
  end

  defp content_sizes(css, _c, _box), do: css

  # `object-position` as an {x, y} pair of px or fractions; nil is the centre
  defp object_position(nil), do: nil

  defp object_position(v) when is_binary(v) do
    case Browser.Backgrounds.parse_position(v) do
      [{x, y} | _] -> {x, y}
      _ -> nil
    end
  end

  defp object_position(_), do: nil

  defp declared_size(attrs) do
    w = attr_width(attrs)
    h = attr_height(attrs)
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

  # a height attribute may be a percentage of the containing block's height
  defp attr_height(attrs) do
    case Integer.parse(attr_value(attrs, "height")) do
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

  # A <canvas> is a replaced element with the size of its bitmap (300 x 150 unless set). What
  # the page's scripts drew on it comes as the "@canvas" attribute: `{width, height, display
  # list}`, which is painted like an inline <svg>, scaled to the box.
  defp canvas_ops({:element, "canvas", attrs, _}, parent_style, acc) do
    c = computed(attrs)
    style = restyle("canvas", attrs, parent_style, c)
    dim = fn name, default -> attr_int(attrs, name) || default end

    {bw, bh, ops} =
      case List.keyfind(attrs, "@canvas", 0) do
        {_, {w, h, ops}} -> {w, h, ops}
        _ -> {dim.("width", 300), dim.("height", 150), []}
      end

    extra = %{
      canvas: {max(bw, 1), max(bh, 1), ops},
      intrinsic: {max(bw, 1), max(bh, 1)},
      paint?: true,
      attrs: declared_size(attrs) || %{w: nil, h: nil},
      current: color4(c["color"]),
      tag: "canvas"
    }

    image_atom(nil, nil, attrs, c, style, acc, extra)
  end

  defp image_atom(url, info, attrs, c, style, acc, extra) do
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
    css = content_sizes(image_css(c), c, box)

    spec = %{
      url: url,
      intrinsic: with({:ok, w, h} <- info, do: {w, h}, else: (_ -> nil)),
      # a picture still loading whose box is already known gets its (not yet drawable) item
      # now, so that the page does not need another layout when the picture arrives
      paint?: info != nil or (url != nil and Browser.ImageBox.fixed?(declared, css)),
      attrs: declared,
      css: css,
      box: box,
      href: style.href,
      blank: style.blank,
      hidden: style.hidden,
      nid: style.nid,
      # a block-level picture sits on a line of its own: vertical-align does not apply
      valign: if(block?, do: nil, else: c["vertical-align"]),
      xform: xform_spec(c),
      fit: c["object-fit"],
      fit_pos: object_position(c["object-position"])
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
  # the top and bottom margins of a block-level box that is laid out as an atom: they collapse
  # with their neighbours outside of it
  defp vertical_margins(c) do
    box = box("div", c)
    {box.mt, box.mb}
  end

  # the border of a table with collapsed borders is one more border for its cells' to be
  # resolved with (see `table_edges/4`), it takes no room of its own
  defp collapsed_table_border(%{"border-collapse" => "collapse", "display" => d} = c)
       when d in ["table", "inline-table"] do
    Map.merge(c, %{
      "@tedges" => edges_of(c),
      "border-top-width" => 0.0,
      "border-right-width" => 0.0,
      "border-bottom-width" => 0.0,
      "border-left-width" => 0.0
    })
  end

  defp collapsed_table_border(c), do: c

  defp inline_block_ops(
         {:element, tag, attrs, kids},
         parent_style,
         c,
         acc,
         block? \\ false,
         table? \\ false
       ) do
    c = collapsed_table_border(c)
    box = box(tag, c)
    ml = if box.ml == :auto, do: 0, else: box.ml
    mr = if box.mr == :auto, do: 0, else: box.mr

    own =
      c
      |> resolve_box_pct(containing_width())
      |> Map.drop(~w(width min-width max-width))
      |> Map.merge(%{"margin-left" => ml * 1.0, "margin-right" => mr * 1.0})

    own =
      if table?, do: Map.merge(own, %{"margin-top" => 0.0, "margin-bottom" => 0.0}), else: own

    # (a table is told its width was given: with collapsed borders that is the width of its columns)
    own = if table? and dim(c["width"]) != nil, do: Map.put(own, "@sized", true), else: own

    attrs = List.keyreplace(attrs, "@computed", 0, {"@computed", own})

    # a box with a width of its own is what its children's percentages refer to
    {_, br, _, bl} = box.bw
    outer = containing_width()

    reference =
      case dim(c["width"]) do
        # (percentages of a box that is as wide as its content count as zero)
        nil ->
          if c["width"] in [:minc, :maxc], do: 0, else: outer

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
      # `min-content` / `max-content`: the narrowest / widest the content can be
      sizing: if(c["width"] in [:minc, :maxc] or fitc?(c["width"]), do: c["width"]),
      minw: c["min-width"],
      maxw: c["max-width"],
      extra: if(c["box-sizing"] == "border-box", do: 0, else: box.pl + box.pr + bl + br),
      mextra: ml + mr,
      mr: mr,
      rextra: box.pr + br + mr,
      valign: c["vertical-align"],
      cell?: c["display"] == "table-cell",
      table?: table? or c["display"] == "inline-table",
      block_table?: table? and block?,
      flex?: c["display"] in ["flex", "inline-flex", "grid", "inline-grid"],
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

  defp inline_ops(tag, kids, style, parent_style, c, acc) do
    acc = if tag in ~w(td th), do: [{:space, style} | acc], else: acc
    positioned? = c["position"] in ["relative", "sticky"]

    rel =
      if c["position"] == "relative",
        do: %{top: c["top"], bottom: c["bottom"], left: c["left"], right: c["right"]}

    acc = if positioned?, do: [{:pos_inline, rel} | acc], else: acc

    spec = inline_spec(tag, c, style)
    ref = make_ref()
    acc = if spec, do: [{:inline_open, ref, spec} | acc], else: acc

    acc =
      if kids == [] and !spec and style.lh != parent_style.lh,
        do: [{:empty_inline, style} | acc],
        else: acc

    acc = walk_children(tag, kids, if(spec, do: %{style | inl: true}, else: style), acc)
    acc = edge_spacing(acc, style, parent_style)
    acc = if spec, do: [{:inline_close, ref, spec} | acc], else: acc

    if positioned?, do: [{:pos_end} | acc], else: acc
  end

  # the spacing between the last letter of an inline element and what follows is the one of
  # the element's parent, which is the closest element the two letters have in common
  defp edge_spacing([op | rest], %{ls: ls}, %{ls: pls})
       when ls != pls and ls > 0 and elem(op, 0) == :word do
    {text, style, tag} =
      case op do
        {:word, t, st} -> {t, st, nil}
        {:word, t, st, g} -> {t, st, g}
      end

    chars = String.graphemes(text)
    last = {:word, List.last(chars), %{style | ls: pls}, :glue}

    case Enum.drop(chars, -1) do
      [] ->
        [last | rest]

      init ->
        init = Enum.join(init)
        [last, if(tag, do: {:word, init, style, tag}, else: {:word, init, style}) | rest]
    end
  end

  defp edge_spacing(acc, _style, _parent), do: acc

  # An inline element needs its own box only if it has a background, borders,
  # or horizontal padding/margins (vertical padding alone paints nothing).
  # An inline box with nothing in it still makes a line when it has horizontal margins, padding
  # or borders, unless something else comes on that line: an empty word, taken off the line when
  # it is laid out, holds the line open (see `flush/1`).
  # the absolutely positioned boxes of a multicol container's content that are not inside a
  # positioned box of it (those are placed against that box) -> {them, the rest}
  defp split_outer_abs(sub) do
    {abs, rest, _} =
      Enum.reduce(sub, {[], [], []}, fn
        # (one with an automatic offset in either direction goes where it would be in the flow,
        # which is in a column)
        {:abs, _, spec} = op, {abs, rest, []}
        when (spec.top != nil or spec.bottom != nil) and
               (spec.left != nil or spec.right != nil) ->
          {[op | abs], rest, []}

        {:box_start, ref, %{pos: true}} = op, {abs, rest, stack} ->
          {abs, [op | rest], [ref | stack]}

        {:box_end, ref} = op, {abs, rest, [ref | stack]} ->
          {abs, [op | rest], stack}

        {:pos_inline, _} = op, {abs, rest, stack} ->
          {abs, [op | rest], [:inline | stack]}

        {:pos_end} = op, {abs, rest, [:inline | stack]} ->
          {abs, [op | rest], stack}

        op, {abs, rest, stack} ->
          {abs, [op | rest], stack}
      end)

    {Enum.reverse(abs), Enum.reverse(rest)}
  end

  defp strut_for_empty(%{line: []} = st, ref, %{style: style} = spec) do
    empty? = Enum.any?(st.marks, &match?({:start, ^ref, _, _}, &1))
    # (the rest of a box that a block split has only its right side to show)
    rest? = Enum.any?(st.active, &(&1.ref == ref and Map.get(&1, :joined, false)))

    sides =
      if empty?,
        do: spec.ml + spec.mr + spec.pl + spec.pr + spec.bl + spec.br,
        else: if(rest?, do: spec.mr + spec.pr + spec.br, else: 0)

    if sides > 0, do: %{st | strut: style}, else: st
  end

  defp strut_for_empty(st, _ref, _spec), do: st

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
        style: style,
        # the height of the font's content area, in ems, is the height of the box
        cf: content_factor(style),
        # (transparent text does not hide the box it is in)
        paint: visible? and not Map.get(style, :vhidden, style.hidden)
      }
    end
  end

  # `break-before/after: column` leave a marker the column set around the block reads
  defp block_ops(tag, kind, kids, style, c, acc) do
    acc = if c["break-before"] in ["column", "all"], do: [{:colbreak} | acc], else: acc
    acc = block_ops_inner(tag, kind, kids, style, c, acc)
    if c["break-after"] in ["column", "all"], do: [{:colbreak} | acc], else: acc
  end

  defp block_ops_inner(tag, kind, kids, style, c, acc) do
    box = box(tag, c)

    acc =
      case clear_side(c) do
        nil -> [{:gap, box.mt}, {:flush} | acc]
        side -> [{:clear, side}, {:gap, box.mt}, {:flush} | acc]
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
          # the margins of the root element do not collapse with those of its children
          acc = if box.pt > 0 or tag == "html", do: [{:pad, box.pt} | acc], else: acc
          acc = indent_op(c, box, acc)

          acc =
            with_cw(child_width(c, box), fn ->
              with_definite(own_definite?(tag, c), fn ->
                balanced_children(tag, kind, kids, style, c, acc)
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
                balanced_children(tag, kind, kids, style, c, acc)
              end)
            end)

          acc = [{:flush} | acc]
          acc = indent_end(c, acc)
          acc = [{:box_end, ref} | acc]
          [{:gap, box.mb} | acc]
      end
    end
  end

  # `text-wrap: balance`: the lines of a block of text are as even as the same number of lines
  # can be. Its content is laid out at a width found when the block is reached.
  defp balanced_children(tag, kind, kids, style, c, acc) do
    if balance_text?(c) and kind in [:block, :list_item] do
      inner = tag |> block_children(kind, kids, style, c, []) |> Enum.reverse()
      [{:balance, inner} | acc]
    else
      block_children(tag, kind, kids, style, c, acc)
    end
  end

  defp balance_text?(c),
    do: "balance" in String.split(to_string(c["text-wrap-style"] || c["text-wrap"]))

  # `text-indent`: the first line of a block starts that far in, as if an inline box of that
  # width led it (`lead`); a percentage is of the block's own width. Nothing carries over from
  # one block to the next.
  defp indent_op(c, box, acc) do
    case c["text-indent"] do
      n when is_number(n) and n != 0 -> [{:indent, round(n)} | acc]
      {:pct, f} when f != 0 -> [{:indent, round(f * child_width(c, box))} | acc]
      {:calc, px, f} -> [{:indent, round(px + f * child_width(c, box))} | acc]
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

  # `aspect-ratio: 16 / 9`, `1`, `auto 3 / 2` (a box with no natural ratio uses the given one):
  # width over height, or nil
  defp aspect_ratio(nil), do: nil

  defp aspect_ratio(v) when is_binary(v) do
    v = String.trim(v)
    # with `auto` the ratio is for the content box, whatever box-sizing says
    kind = if String.starts_with?(v, "auto"), do: :content, else: :sizing

    ratio =
      case v |> String.replace_prefix("auto", "") |> String.split("/") do
        [w] -> ratio_of(w, "1")
        [w, h] -> ratio_of(w, h)
        _ -> nil
      end

    if ratio, do: {ratio, kind}
  end

  defp aspect_ratio(_), do: nil

  defp ratio_of(w, h) do
    with {w, ""} <- w |> String.trim() |> Float.parse(),
         {h, ""} <- h |> String.trim() |> Float.parse(),
         true <- w > 0 and h > 0 do
      w / h
    else
      _ -> nil
    end
  end

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
      hpct: pct_of(c["height"]) || calc_pct(c["height"]),
      hoff: calc_px(c["height"]),
      hstretch: :hstretch in [c["height"], c["min-height"], c["max-height"]],
      hstretch_for: for(k <- ~w(height min-height max-height), c[k] == :hstretch, do: k),
      definite: box.definite,
      ratio: aspect_ratio(c["aspect-ratio"]),
      flex_sized: c["@flex_sized"] == true,
      root: tag == "html",
      min: num(c["min-height"]),
      max: num(c["max-height"]),
      # (`min-height: max-content` and its kind: the height of the content)
      minc: c["min-height"] == :fit,
      maxc: c["max-height"] == :fit,
      maxpct: pct_of(c["max-height"]) || calc_pct(c["max-height"]),
      maxoff: calc_px(c["max-height"]),
      minpct: pct_of(c["min-height"]) || calc_pct(c["min-height"]),
      minoff: calc_px(c["min-height"]),
      clip: clips?(c),
      cpath: plain_inset?(c["clip-path"]),
      scroll: scroll_axes(c),
      # (`contain: size`: asked how wide it wants to be, it says its `contain-intrinsic-size`)
      cisw: c["@cis_w"],
      bfc: clips?(c) or c["display"] == "flow-root" or columns_spec(c) != nil,
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
        spec.min || spec.ratio || spec.maxpct ||
        spec.max || spec.pos || spec.cisw ||
        spec.clip || spec.bfc || spec.width || spec.minw || spec.maxw || spec.ml == :auto ||
        spec.mr == :auto || spec.cid != nil || (spec.hpct && percent_definite?(tag)) ||
        spec.hstretch || (spec.nid != nil and Process.get(:layout_boxes, false))

    if needed?, do: spec
  end

  # `auto` is the same as no width/height for everything but images
  defp dim(:auto), do: nil
  defp dim(w) when w in [:fit, :minc, :maxc], do: nil
  defp dim({:fitc, _}), do: nil
  defp dim(v), do: v

  defp fitc?({:fitc, _}), do: true
  defp fitc?(_), do: false

  defp kw?({:kw, _}), do: true
  defp kw?(_), do: false

  defp num(v) when is_number(v), do: v
  defp num(_), do: nil

  # `overflow: scroll | auto` on either axis: the box scrolls its content (see `Browser.Scrollers`)
  defp scroll_axes(c) do
    ox = scroll_kind(Map.get(c, "overflow-x", "visible"))
    oy = scroll_kind(Map.get(c, "overflow-y", "visible"))
    if ox || oy, do: {ox, oy}
  end

  defp scroll_kind("scroll"), do: :scroll
  defp scroll_kind("auto"), do: :auto
  defp scroll_kind(_), do: nil

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

          # a floated part of the table floats beside it
          c["float"] in ["left", "right"] and c["display"] in @float_table_parts ->
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
            hidden?(ic) and ic["visibility"] != "collapse" ->
              {items, acc}

            ic["position"] in ["absolute", "fixed"] ->
              {items, el |> walk(style, acc) |> flex_static(c, ic)}

            true ->
              {[flex_element_item(el, ic, style) | items], acc}
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

    spec = grid_spec(tag, c)

    case Enum.reverse(items) do
      # (the rows of an empty grid still take their room)
      [] when spec.rows == [] -> acc
      items -> [{:grid, spec, items, style} | acc]
    end
  end

  # a block with `columns`, `column-count` or `column-width` flows its content through columns
  defp block_children(tag, :block, kids, style, c, acc) do
    case columns_spec(c) do
      nil ->
        walk_children(tag, kids, style, acc)

      cs ->
        case split_spanners(kids) do
          [{:flow, _}] ->
            sub = tag |> walk_children(kids, style, []) |> Enum.reverse()
            [{:columns, Map.put(cs, :height, columns_height(tag, c)), sub, style} | acc]

          parts ->
            # `column-span: all` children run across all the columns: the content before and
            # after them is poured into columns of its own
            Enum.reduce(parts, acc, fn
              {:flow, flow}, acc ->
                sub = tag |> walk_children(flow, style, []) |> Enum.reverse()
                [{:columns, Map.put(cs, :height, nil), sub, style} | acc]

              {:span, node}, acc ->
                walk_children(tag, [node], style, acc)
            end)
        end
    end
  end

  defp block_children(tag, _kind, kids, style, _c, acc), do: walk_children(tag, kids, style, acc)

  # the children of a multicol container as runs of flow and the `column-span: all` ones
  defp split_spanners(kids) do
    kids
    |> Enum.chunk_by(&spanner?/1)
    |> Enum.map(fn [first | _] = run ->
      if spanner?(first), do: {:span_run, run}, else: {:flow, run}
    end)
    |> Enum.flat_map(fn
      {:span_run, run} -> Enum.map(run, &{:span, &1})
      flow -> [flow]
    end)
  end

  defp spanner?({:element, tag, attrs, _kids}) do
    c = computed(attrs)
    c["column-span"] == "all" and kind(tag, c) == :block and c["float"] in [nil, "none"]
  end

  defp spanner?(_), do: false

  defp columns_spec(c) do
    count = c["column-count"]
    width = c["column-width"]

    if count || width do
      fs = if is_number(c["font-size"]), do: c["font-size"], else: 16.0

      gap =
        if is_number(c["column-gap"]) or match?({:pct, _}, c["column-gap"]),
          do: c["column-gap"],
          else: fs

      %{
        count: count,
        width: width,
        gap: gap,
        fill: c["column-fill"],
        rule: column_rule(c, fs),
        # `column-height` makes the columns that tall, and the ones that do not fit the row
        # wrap into rows of their own (unless `column-wrap: nowrap`)
        colh: if(is_number(c["column-height"]), do: c["column-height"]),
        wrap: c["column-wrap"],
        rowgap: if(is_number(c["row-gap"]), do: c["row-gap"], else: 0)
      }
    end
  end

  # the line between columns: {width, color} (`medium` and the text colour when not given)
  defp column_rule(c, _fs) do
    w = if is_number(c["column-rule-width"]), do: c["column-rule-width"], else: 3.0
    # widths are whole pixels: a thin one is rounded up to one, the others down
    w = if w > 0 and w < 1, do: 1, else: trunc(w)

    if c["column-rule-style"] in [nil, "none", "hidden"] or w <= 0,
      do: nil,
      else: {w, c["column-rule-color"] || c["color"] || {0, 0, 0}}
  end

  # the height a multicol box's columns have (its content height), when it is set
  defp columns_height(tag, c) do
    case num(c["height"]) do
      nil ->
        # a height limit sets the column height too when the columns fill one after another
        if c["column-fill"] == "auto", do: num(c["max-height"])

      h ->
        if c["box-sizing"] == "border-box" do
          box = box(tag, c)
          {bt, _br, bb, _bl} = box.bw
          max(h - bt - bb - box.pt - box.pb, 0)
        else
          h
        end
    end
  end

  # ul/ol number their list items and emit markers; everything else just recurses
  defp walk_children(tag, kids, style, acc) when tag in ~w(ul ol) do
    kids
    |> Enum.reduce({acc, 1}, fn
      {:element, "li", attrs, li_kids} = li, {a, n} ->
        c = computed(attrs)

        cond do
          # a floated or positioned item is a box of its own, without a marker
          kind("li", c) == :list_item and
              (float_side(c) != nil or c["position"] in ["absolute", "fixed"]) ->
            {walk(li, style, a), n + 1}

          kind("li", c) == :list_item ->
            {list_item(tag, n, attrs, li_kids, style, c, a), n + 1}

          true ->
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
      # the height was settled by flexing, which makes percentages of it definite
      definite: c["@definite"] == true,
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
        attachment: c["background-attachment"] || [],
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
  defp px({:calc, px, f}), do: round(px + f * containing_width())
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
      case List.keyfind(attrs, "lang", 0) do
        {_, lang} when is_binary(lang) and lang != "" ->
          %{style | lang: lang |> String.downcase() |> String.split("-") |> hd()}

        _ ->
          style
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
      {_, href} ->
        blank = List.keyfind(attrs, "target", 0) == {"target", "_blank"}
        %{style | href: href, blank: blank, color: {0, 0, 238}, underline: true}

      nil ->
        style
    end
  end

  defp computed(attrs) do
    case List.keyfind(attrs, "@computed", 0) do
      # `display: contents` makes no box: only what its children inherit is left
      {_, %{"display" => "contents"} = map} ->
        Map.take(map, ["display" | Browser.Style.inherited_props()])

      {_, map} ->
        resolve_calc(map)

      nil ->
        %{}
    end
  end

  # a width of `calc(50% - 10px)`: the percentage of the width of the containing block
  defp resolve_calc(map) do
    Enum.reduce(["width", "min-width", "max-width"], map, fn key, acc ->
      case acc[key] do
        {:calc, px, f} -> Map.put(acc, key, max(px + f * containing_width(), 0.0))
        :stretch -> Map.put(acc, key, stretched(acc))
        _ -> acc
      end
    end)
  end

  # `width: stretch`: a float or an out-of-flow box fills the containing block less its margins
  # (and its borders and padding, when the width is the content width); other boxes are as wide as
  # `auto` makes them
  defp stretched(c) do
    if c["float"] in ["left", "right"] do
      margins = Enum.sum(for k <- ["margin-left", "margin-right"], do: num(c[k]) || 0)
      edges = if c["box-sizing"] == "border-box", do: 0, else: stretch_edges(c)
      max(containing_width() - margins - edges, 0.0)
    else
      :auto
    end
  end

  defp stretch_edges(c) do
    Enum.sum(
      for k <-
            ~w(padding-left padding-right border-left-width border-right-width),
          do: num(c[k]) || 0
    )
  end

  # Style already resolved inheritance, so present keys simply override.
  defp apply_computed(style, c) do
    decoration = c["text-decoration-line"]

    style
    |> put_if(c["font-size"], fn s, fs ->
      if fs < 1,
        do: %{s | size: 1, hidden: true, tiny: true},
        else: %{s | size: round(fs), tiny: false}
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
      fn s, _ ->
        # (`match-parent` keeps what the parent resolved, in the parent's direction)
        s =
          if c["text-align"] == "match-parent",
            do: s,
            else: %{s | align: align(c["text-align"] || "start", c["direction"])}

        if c["text-align"] == "justify-all", do: %{s | alast: s.align}, else: s
      end
    )
    |> put_if(c["word-break"] || c["line-break"] || c["overflow-wrap"] || c["word-wrap"], fn s,
                                                                                             _ ->
      %{s | wrap_chars: wrap_chars(c)}
    end)
    |> put_if(c["word-space-transform"], &%{&1 | wst: word_space_transform(&2)})
    |> put_if(c["word-break"], &%{&1 | keep_all: &2 in ["keep-all", "auto-phrase"]})
    |> put_if(c["hyphens"], &%{&1 | shy: &2 != "none"})
    |> put_if(c["hyphenate-character"], &%{&1 | hyph: hyphen_char(&2)})
    |> put_if(c["vertical-align"], &raise_text/2)
    |> put_if(c["text-justify"], &%{&1 | nojust: &2 == "none"})
    |> put_if(c["text-align-last"], fn s, v ->
      if c["text-align"] == "justify-all",
        do: s,
        else: %{s | alast: if(v == "auto", do: nil, else: align(v, c["direction"]))}
    end)
    |> put_if(c["list-style-type"], &%{&1 | list: &2})
    |> put_if(c["line-height"], &%{&1 | lh: &2})
    |> put_if(c["white-space"], &white_space(&1, &2))
    |> put_if(text_wrap_mode(c), &wrap_mode/2)
    |> put_if(c["letter-spacing"], &letter_spacing/2)
    |> put_if(is_number(c["word-spacing"]) && c["word-spacing"], &%{&1 | wsp: &2 / 1})
    |> put_if(c["text-transform"], &%{&1 | tt: text_transform(&2)})
    |> put_if(c["tab-size"], &tab_size(&1, &2))
    |> Map.put(:rtl, c["direction"] == "rtl")
    |> then(
      &if(c["display"] in [nil, "inline"],
        do: &1,
        else: &1 |> Map.put(:cb, &1.rtl) |> Map.put(:vs, 0) |> block_space()
      )
    )
    |> then(&if(blockified?(c), do: Map.put(&1, :vs, 0), else: &1))
    # transparent text takes its room and shows nothing
    |> Map.put(:vhidden, hidden?(c))
    |> Map.put(:hidden, hidden?(c) or c["color"] == :transparent)
  end

  # visibility is inherited by Style; a zero font-size hides text too
  defp hidden?(c),
    do:
      c["visibility"] in ["hidden", "collapse"] or
        (is_number(c["font-size"]) and c["font-size"] < 1)

  # `hyphenate-character`: `auto` is a hyphen; a string may use CSS escapes (`"\\2022"`)
  defp hyphen_char(value) do
    case String.trim(to_string(value)) do
      <<q, rest::binary>> when q in [?", ?'] ->
        rest
        |> String.trim_trailing(<<q>>)
        |> then(
          &Regex.replace(~r/\\([0-9a-fA-F]{1,6})\s?|\\(.)/su, &1, fn
            _, hex, "" -> <<String.to_integer(hex, 16)::utf8>>
            _, _, ch -> ch
          end)
        )

      _ ->
        "-"
    end
  end

  # `tab-size`: a number of columns, or a length
  defp tab_size(style, value) do
    text = value |> to_string() |> String.trim()

    case Float.parse(text) do
      {n, ""} when n >= 0 ->
        %{style | tab: if(n == trunc(n), do: trunc(n), else: n)}

      _ ->
        case Regex.run(~r/\A(\d+\.?\d*|\.\d+)(px|em|rem|pt|ch|ex)\z/, text) do
          [_, num, unit] ->
            n = if String.starts_with?(num, "."), do: "0" <> num, else: num
            n = n |> Float.parse() |> elem(0)

            px =
              case unit do
                "px" -> n
                "pt" -> n * 4 / 3
                u when u in ["em", "ch", "ex"] -> n * style.size
                "rem" -> n * 16
              end

            %{style | tab: {:px, px}}

          _ ->
            style
        end
    end
  end

  # the width of the space in the font of a block container
  defp block_space(style) do
    case Process.get(:layout_measure) do
      nil -> style
      measure -> %{style | bspace: measure.(" ", style)}
    end
  end

  # the tab stops in columns of spaces
  defp tab_cols(style) do
    with measure when measure != nil <- Process.get(:layout_measure),
         space when space > 0 <- measure.(" ", %{style | ls: 0, wsp: 0}) do
      max(round(tab_px(style, space) / space), 0)
    else
      _ -> 0
    end
  end

  # the distance between tab stops in px: a number of the spaces of the block container's font,
  # or a length
  defp tab_px(%{tab: {:px, px}}, _space), do: px
  defp tab_px(%{tab: n} = style, space), do: n * (style.bspace || space)

  # Georgian Mkhedruli letters stay as they are in upper case (their capitals are a style of
  # their own, not a case)
  @full_kana Map.new(
               Enum.zip(
                 String.to_charlist("ぁぃぅぇぉっゃゅょゎゕゖァィゥェォッャュョヮヵヶㇰㇱㇲㇳㇴㇵㇶㇷㇸㇹㇺㇻㇼㇽㇾㇿｧｨｩｪｫｯｬｭｮ"),
                 String.to_charlist("あいうえおつやゆよわかけアイウエオツヤユヨワカケクシストヌハヒフヘホムラリルレロｱｲｳｴｵﾂﾔﾕﾖ")
               )
             )

  # (white space is collapsed before `full-width` turns the spaces that are left into wide ones)
  defp collapse_for(t, tt, %{ws: :normal}) when is_list(tt) do
    if :full_width in tt, do: Regex.replace(~r/[ \t\n\r\f]+/, t, " "), else: t
  end

  defp collapse_for(t, _tt, _style), do: t

  defp transform_text(t, kinds, acc) when is_list(kinds),
    do: Enum.reduce(kinds, t, &transform_text(&2, &1, acc))

  defp transform_text(t, :upper, {_acc, lang}) do
    upper =
      if String.match?(t, ~r/[\x{10D0}-\x{10FF}]/u),
        do: Regex.replace(~r/[^\x{10D0}-\x{10FF}]+/u, t, &String.upcase/1),
        else: String.upcase(t)

    # (Greek capitals lose their accents but keep the diaeresis)
    if lang == "el", do: greek_unaccent(upper), else: upper
  end

  defp transform_text(t, :lower, _acc), do: String.downcase(t)

  # ASCII letters, digits and punctuation become their full-width forms, a space the ideographic one
  defp transform_text(t, :full_width, _acc) do
    for <<c::utf8 <- t>>, into: "" do
      cond do
        c == 0x20 -> <<0x3000::utf8>>
        c in 0x21..0x7E -> <<c + 0xFEE0::utf8>>
        true -> <<c::utf8>>
      end
    end
  end

  # small kana become the full-size ones
  defp transform_text(t, :full_kana, _acc) do
    for <<c::utf8 <- t>>, into: "", do: <<Map.get(@full_kana, c, c)::utf8>>
  end

  # the first letter of a word, after any punctuation that opens it; text that carries on a
  # word begun in the text before it (`T<b>his`) keeps what it has until its first space
  defp transform_text(t, :cap, {acc, lang}) do
    {head, tail} =
      if word_begun?(acc),
        do:
          case(Regex.run(~r/\A\S*/u, t),
            do: ([h] -> {h, binary_part(t, byte_size(h), byte_size(t) - byte_size(h))})
          ),
        else: {"", t}

    (head <>
       Regex.replace(~r/(^|\s)([\p{P}\p{S}]*)(\p{L})/u, tail, fn _, sp, p, ch ->
         sp <> p <> String.upcase(ch)
       end))
    |> then(
      &if(lang == "nl", do: Regex.replace(~r/(^|\s)([\p{P}\p{S}]*)Ij/u, &1, "\\1\\2IJ"), else: &1)
    )
  end

  defp greek_unaccent(t) do
    t
    |> String.normalize(:nfd)
    |> String.replace(~r/[\x{0300}\x{0301}\x{0304}\x{0306}\x{0313}\x{0314}\x{0342}\x{0345}]/u, "")
    |> String.normalize(:nfc)
  end

  # true when the words just before (no space between them) hold a letter
  defp word_begun?([{:word, text, _} | rest]), do: letters?(text) or word_begun?(rest)
  defp word_begun?([{:word, text, _, _} | rest]), do: letters?(text) or word_begun?(rest)
  defp word_begun?([{:inline_open, _, _} | rest]), do: word_begun?(rest)
  defp word_begun?([{:inline_close, _, _} | rest]), do: word_begun?(rest)
  defp word_begun?(_), do: false

  defp letters?(text), do: String.match?(text, ~r/[\p{L}\p{N}]/u)

  defp letter_spacing(style, {:pct, f}), do: %{style | ls: f * style.size}
  defp letter_spacing(style, {:calc, px, f}), do: %{style | ls: px + f * style.size}
  defp letter_spacing(style, n) when is_number(n), do: %{style | ls: n / 1}
  defp letter_spacing(style, _), do: style

  # absolutely positioned and floated boxes are block-level: vertical-align does not apply
  defp blockified?(c),
    do: c["position"] in ["absolute", "fixed"] or c["float"] in ["left", "right"]

  # `vertical-align` on an inline box moves its text (and what is inside it) up or down from the
  # parent's baseline; boxes of their own start from the baseline again
  defp raise_text(style, value) do
    own =
      case value do
        "sub" -> -round(style.size / 5)
        "super" -> round(style.size / 3)
        n when is_number(n) -> round(n)
        {:pct, f} -> round(f * line_px(style))
        _ -> 0
      end

    %{style | vs: style.vs + own}
  end

  # `word-space-transform` turns the zero-width spaces and <wbr> into spaces
  defp word_space_transform(v) do
    words = v |> to_string() |> String.split()

    cond do
      "ideographic-space" in words -> :ideo
      "space" in words -> :space
      true -> :none
    end
  end

  defp wrap_chars(c) do
    cond do
      c["line-break"] == "anywhere" -> :every
      c["word-break"] == "break-all" -> :all
      c["word-break"] == "break-word" -> :anywhere
      c["overflow-wrap"] == "anywhere" -> :anywhere
      c["overflow-wrap"] == "break-word" -> :word
      c["word-wrap"] == "anywhere" -> :anywhere
      c["word-wrap"] == "break-word" -> :word
      true -> :none
    end
  end

  # `text-transform` takes a case keyword and any of `full-width` and `full-size-kana`
  defp text_transform(value) do
    kinds =
      for word <- value |> to_string() |> String.split(),
          kind = text_transform_kind(word),
          do: kind

    if kinds == [], do: :none, else: kinds
  end

  defp text_transform_kind("uppercase"), do: :upper
  defp text_transform_kind("lowercase"), do: :lower
  defp text_transform_kind("capitalize"), do: :cap
  defp text_transform_kind("full-width"), do: :full_width
  defp text_transform_kind("full-size-kana"), do: :full_kana
  defp text_transform_kind(_), do: nil

  defp white_space(style, value) do
    ws =
      case value do
        "pre" -> :pre
        "pre-wrap" -> :pre_wrap
        "break-spaces" -> :break_spaces
        "pre-line" -> :pre_line
        "nowrap" -> :nowrap
        _ -> :normal
      end

    %{style | ws: ws, pre: ws == :pre}
  end

  # `text-wrap` (or its `text-wrap-mode` longhand) switches line wrapping on or off
  # without touching how white space collapses
  defp text_wrap_mode(c) do
    case to_string(c["text-wrap-mode"] || c["text-wrap"]) |> String.split() |> List.first() do
      mode when mode in ["wrap", "nowrap"] -> mode
      _ -> nil
    end
  end

  defp wrap_mode(%{ws: ws} = style, "nowrap") when ws in [:normal, :pre_wrap, :pre_line],
    do: %{style | ws: :nowrap}

  defp wrap_mode(%{ws: :nowrap} = style, "wrap"), do: %{style | ws: :normal}
  defp wrap_mode(%{ws: :pre} = style, "wrap"), do: %{style | ws: :pre_wrap, pre: false}
  defp wrap_mode(style, _mode), do: style

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

  defp walk_text(t, %{ws: ws} = style, acc) when ws in [:pre_wrap, :pre_line, :break_spaces],
    do: pre_text(t, style, acc, ws)

  defp walk_text(t, %{ws: :nowrap} = style, acc) do
    t = drop_wide_breaks(t)
    # whitespace collapses, but the words never wrap
    leading = if String.match?(t, space_start()), do: [{:space, style}], else: []
    trailing = if String.match?(t, space_end()), do: [{:space, style}], else: []
    words = t |> css_words() |> Enum.map(&{:word, &1, style, :pre})

    case words do
      [] -> if t == "", do: acc, else: [{:space, style} | acc]
      _ -> Enum.reverse(leading ++ Enum.intersperse(words, {:space, style}) ++ trailing) ++ acc
    end
  end

  # a zero-width space is a place where a line may break, with nothing shown; it also keeps the
  # spaces on either side of it from collapsing into one
  defp walk_text(t, style, acc) do
    if String.contains?(t, "\u200B"),
      do: walk_zwsp_text(t, style, acc),
      else: walk_plain_text(t, style, acc)
  end

  defp walk_zwsp_text(t, %{wst: wst} = style, acc) do
    ops =
      ~r/[ \t\n\r\f\v\x{85}\x{1680}\x{2000}-\x{2006}\x{2008}-\x{200A}\x{2028}\x{2029}\x{205F}]+|\x{200B}|[^ \t\n\r\f\v\x{85}\x{1680}\x{2000}-\x{2006}\x{2008}-\x{200A}\x{2028}\x{2029}\x{205F}\x{200B}]+/u
      |> Regex.scan(drop_wide_breaks(t))
      |> Enum.map(fn
        ["\u200B"] when wst != :none ->
          if wst == :space, do: {:space, style}, else: {:word, "\u3000", style}

        [tok] ->
          if String.match?(
               tok,
               ~r/\A[ \t\n\r\f\v\x{85}\x{1680}\x{2000}-\x{2006}\x{2008}-\x{200A}\x{2028}\x{2029}\x{205F}]/u
             ),
             do: {:space, style},
             else: {:word, tok, style}
      end)

    ops =
      case ops do
        [{:word, w, st} | more] when w != "\u200B" -> [{:word, w, st, :glue} | more]
        _ -> ops
      end

    Enum.reverse(ops) ++ acc
  end

  defp walk_plain_text(t, style, acc) do
    t = drop_wide_breaks(t)
    leading = if String.match?(t, space_start()), do: [{:space, style}], else: []
    trailing = if String.match?(t, space_end()), do: [{:space, style}], else: []
    words = t |> css_words() |> Enum.map(&{:word, &1, style})
    # without a space before it, the first word is glued to whatever came before
    words =
      case words do
        [{:word, w, st} | more] when leading == [] ->
          if ideograph_edge?(prev_char(acc), w, st.keep_all),
            do: [{:word, w, st} | more],
            else: [{:word, w, st, :glue} | more]

        _ ->
          words
      end

    case words do
      [] ->
        if t == "", do: acc, else: [{:space, style} | acc]

      _ ->
        Enum.reverse(
          List.flatten(
            leading ++
              Enum.intersperse(Enum.map(words, &ideograph_breaks(&1, style)), {:space, style}) ++
              trailing
          )
        ) ++ acc
    end
  end

  # a line break between two wide East Asian characters (not Hangul) is removed, not turned into a space
  @wide "\\x{2E80}-\\x{303E}\\x{3041}-\\x{33FF}\\x{3400}-\\x{4DBF}\\x{4E00}-\\x{9FFF}\\x{F900}-\\x{FAFF}\\x{FE30}-\\x{FE4F}\\x{FF01}-\\x{FF9F}\\x{FFE0}-\\x{FFE6}\\x{20000}-\\x{3FFFD}"
  # (variation selectors, soft hyphens and direction marks are invisible between the two)
  @ignorable "\\x{FE00}-\\x{FE0F}\\x{E0100}-\\x{E01EF}\\x{AD}\\x{200E}\\x{200F}"
  @wide_break Regex.compile!(
                "([#{@wide}][#{@ignorable}]*)[ \\t\\n]*\\n[ \\t\\n]*(?=[#{@ignorable}]*[#{@wide}])",
                "u"
              )
  # (CJK punctuation, also the half- and fullwidth forms of it)
  @cjk_punct "\\x{3001}-\\x{303F}\\x{30FB}\\x{FF01}-\\x{FF0F}\\x{FF1A}-\\x{FF20}\\x{FF3B}-\\x{FF40}\\x{FF5B}-\\x{FF65}"
  @punct_break Regex.compile!(
                 "([#{@cjk_punct}])[ \\t\\n]*\\n[ \\t\\n]*|[ \\t\\n]*\\n[ \\t\\n]*(?=[#{@cjk_punct}])",
                 "u"
               )
  # (a segment break next to a zero-width space goes as well)
  @zwsp_break Regex.compile!(
                "\\x{200B}[ \\t\\n]*\\n[ \\t\\n]*|[ \\t\\n]*\\n[ \\t\\n]*(?=\\x{200B})",
                "u"
              )

  defp drop_wide_breaks(t) do
    if String.contains?(t, "\n") do
      t
      |> then(&Regex.replace(@wide_break, &1, "\\1"))
      |> then(&Regex.replace(@punct_break, &1, "\\1"))
      |> then(
        &Regex.replace(@zwsp_break, &1, fn m ->
          if String.starts_with?(m, "\u200B"), do: "\u200B", else: ""
        end)
      )
    else
      t
    end
  end

  # a line may break between an ideograph (or kana) and the character next to it, except before
  # punctuation that cannot start a line and after an opening bracket; the pieces of a word
  # follow each other without a space
  @wide_re Regex.compile!("[#{@wide}]", "u")
  @no_start "-.,;:!?)]}%\u00B7\u2019\u201D\u2026\u2010\u2013\u3001\u3002\u3005\u3009\u300B\u300D\u300F\u3011\u3015\u3017\u3019\u301C\u30FB\u30FC\u3041\u3043\u3045\u3047\u3049\u3063\u3083\u3085\u3087\u308E\u3095\u3096\u309D\u309E\u30A1\u30A3\u30A5\u30A7\u30A9\u30C3\u30E3\u30E5\u30E7\u30EE\u30F5\u30F6\u30FD\u30FE\uFF01\uFF09\uFF0C\uFF0E\uFF1A\uFF1B\uFF1F\uFF3D\uFF5D\uFF5E\uFF60\u200D\u3000"
  @no_end "([{\u2018\u201C\u3008\u300A\u300C\u300E\u3010\u3014\u3016\u3018\uFF08\uFF3B\uFF5B\uFF5F\u200D"

  defp ideograph_breaks(op, _style) do
    {text, style, glue} =
      case op do
        {:word, t, st} -> {t, st, nil}
        {:word, t, st, g} -> {t, st, g}
      end

    if String.length(text) > 1 and Regex.match?(@wide_re, text) do
      text
      |> String.graphemes()
      |> Enum.reduce([], fn
        g, [] ->
          [g]

        g, [cur | done] = acc ->
          if break_between?(cur, g, style.keep_all), do: [g | acc], else: [cur <> g | done]
      end)
      |> Enum.reverse()
      |> Enum.with_index()
      |> Enum.map(fn
        {w, 0} when glue != nil -> {:word, w, style, glue}
        {w, _} -> {:word, w, style}
      end)
    else
      op
    end
  end

  # the last character laid out before, looking through the edges of inline boxes
  defp prev_char([{:word, text, _} | _]), do: String.last(text)
  defp prev_char([{:word, text, _, _} | _]), do: String.last(text)

  defp prev_char([{tag, _, _} | rest]) when tag in [:inline_open, :inline_close],
    do: prev_char(rest)

  defp prev_char(_), do: nil

  # whether a line may break between the character before and the start of the next word
  defp ideograph_edge?(nil, _word, _keep_all), do: false
  defp ideograph_edge?(_prev, "", _keep_all), do: false

  defp ideograph_edge?(prev, word, keep_all),
    do: break_between?(prev, String.first(word), keep_all)

  defp break_between?(cur, g, keep_all?) do
    a = String.last(cur)
    a = if String.ends_with?(cur, "\u200D"), do: "\u200D", else: a

    # (`keep-all` leaves only the break after an ideographic space and a CJK comma or full stop)
    (Regex.match?(@wide_re, a) or Regex.match?(@wide_re, g)) and
      (not keep_all? or a in ["\u3000", "\u3001", "\u3002", "\uFF0C", "\uFF0E"]) and
      not String.contains?(@no_start, g) and not String.contains?(@no_end, a)
  end

  defp space_start,
    do:
      ~r/\A[ \t\n\r\f\v\x{85}\x{1680}\x{2000}-\x{2006}\x{2008}-\x{200A}\x{2028}\x{2029}\x{205F}]/u

  defp space_end,
    do:
      ~r/[^ \t\n\r\f\v\x{85}\x{1680}\x{2000}-\x{2006}\x{2008}-\x{200A}\x{2028}\x{2029}\x{205F}][ \t\n\r\f\v\x{85}\x{1680}\x{2000}-\x{2006}\x{2008}-\x{200A}\x{2028}\x{2029}\x{205F}]+\z/u

  defp space_run,
    do:
      ~r/[ \t\n\r\f\v\x{85}\x{1680}\x{2000}-\x{2006}\x{2008}-\x{200A}\x{2028}\x{2029}\x{205F}]+/u

  # words split on white space except the ideographic space and the no-break ones
  # (an ideographic space is a word character that may hang at the end of a line)
  defp css_words(t), do: String.split(t, space_run(), trim: true)

  defp align(v, dir) when v in ["justify", "justify-all"],
    do: if(dir == "rtl", do: :rjustify, else: :justify)

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
        line != "" -> Enum.reverse(line_ops(line, style, ws, if(i == 0, do: prev_kind(acc)))) ++ a
        i == last -> a
        true -> [{:word, "\u200B", style, :pre} | a]
      end
    end)
  end

  # the words of one line: `pre` keeps it whole, `pre-wrap` keeps its spaces but may wrap,
  # `pre-line` collapses spaces
  defp line_ops(line, style, :pre, _prev) do
    if String.contains?(line, "\t"),
      do: pre_words(line, style),
      else: [{:word, line, style, :pre}]
  end

  defp line_ops(line, style, :pre_line, _prev) do
    line
    |> String.split()
    |> Enum.map(&{:word, &1, style})
    |> Enum.intersperse({:space, style})
  end

  @break_spaces [
    " ",
    "\u1680",
    "\u2000",
    "\u2001",
    "\u2002",
    "\u2003",
    "\u2004",
    "\u2005",
    "\u2006",
    "\u2008",
    "\u2009",
    "\u200A",
    "\u205F",
    "\u3000"
  ]

  # `break-spaces`: every preserved space is a word of its own and a line may break after
  # each of them, so none hangs; the first one after text does not wrap away from it
  defp line_ops(line, style, :break_spaces, prev) do
    style = if String.contains?(line, "\t"), do: %{style | nojust: true}, else: style

    ~r/\t|[ \x{1680}\x{2000}-\x{2006}\x{2008}-\x{200A}\x{205F}\x{3000}]|[^ \x{1680}\x{2000}-\x{2006}\x{2008}-\x{200A}\x{205F}\x{3000}\t]+/u
    |> Regex.scan(String.replace(line, "\r", " "))
    |> Enum.map_reduce({prev, 0}, fn
      # a tab is one unbreakable word as wide as the spaces it stands for
      ["\t"], {prev, col} ->
        tab = tab_cols(style)
        n = if tab == 0, do: 0, else: tab - rem(col, tab)
        word = String.duplicate("\u00A0", n)

        if prev == :text and style.wrap_chars != :every,
          do: {{:word, word, style, :hold}, {:space, col + n}},
          else: {{:word, word, style}, {:space, col + n}}

      # (`line-break: anywhere` allows a break between a word and the space after it)
      [sp], {:text, col} when sp in @break_spaces and style.wrap_chars != :every ->
        {{:word, nbsp_of(sp), style, :hold}, {:space, col + 1}}

      [sp], {_, col} when sp in @break_spaces ->
        {{:word, nbsp_of(sp), style}, {:space, col + 1}}

      [run], {_, col} ->
        {ideograph_breaks({:word, run, style}, style), {:text, col + String.length(run)}}
    end)
    |> elem(0)
    |> List.flatten()
  end

  # a tab keeps a line from being justified
  defp line_ops(line, style, :pre_wrap, prev) do
    style = if String.contains?(line, "\t"), do: %{style | nojust: true}, else: style

    ~r/ +|[^ ]+/
    |> Regex.scan(expand_tabs(line, style))
    |> then(&Enum.with_index(&1, fn token, i -> {token, i, i == length(&1) - 1} end))
    |> Enum.map(fn {[run], i, last?} ->
      cond do
        # a space that starts or ends a line stays (a lone one would be dropped there)
        run == " " and ((i == 0 and prev == nil) or (last? and not style.rtl)) ->
          {:word, "\u00A0", style, :pre}

        run == " " ->
          {:space, style}

        String.starts_with?(run, " ") ->
          {:word, String.duplicate("\u00A0", String.length(run)), style, :pre}

        true ->
          ideograph_breaks({:word, run, style}, style)
      end
    end)
    |> List.flatten()
  end

  # what the text laid out so far ends in: `:text`, or `:space` for a preserved space
  defp prev_kind([{:word, text, _} | _]), do: word_kind(text)
  defp prev_kind([{:word, text, _, _} | _]), do: word_kind(text)
  defp prev_kind([{:inline_open, _, _} | rest]), do: prev_kind(rest)
  defp prev_kind([{:inline_close, _, _} | rest]), do: prev_kind(rest)
  defp prev_kind(_), do: nil

  defp word_kind(text),
    do: if(String.last(text) in ["\u00A0" | @break_spaces], do: :space, else: :text)

  defp nbsp_of(" "), do: "\u00A0"
  defp nbsp_of(other), do: other

  # a tab advances to the next multiple of `tab-size`, as many spaces of the text's font
  defp expand_tabs(line, style) do
    with true <- String.contains?(line, "\t"),
         measure when measure != nil <- Process.get(:layout_measure),
         plain = %{style | ls: 0, wsp: 0},
         space when space > 0 <- measure.(" ", plain) do
      tabw = tab_px(style, space)

      {parts, _} =
        line
        |> String.graphemes()
        |> Enum.reduce({[], 0}, fn
          "\t", {acc, off} ->
            n = if tabw <= 0, do: 0, else: round(((trunc(off / tabw) + 1) * tabw - off) / space)
            {[String.duplicate(" ", n) | acc], off + n * space}

          g, {acc, off} ->
            {[g | acc], off + measure.(g, plain)}
        end)

      parts |> Enum.reverse() |> Enum.join()
    else
      _ -> line
    end
  end

  # the pieces of a preserved line with tabs: each tab is a space as wide as the way to the next
  # tab stop, counted from the start of the line when it is placed (`tab_width/3`)
  defp pre_words(line, style) do
    measure = Process.get(:layout_measure)
    space = measure.(" ", %{style | tabw: nil})
    tab = %{style | tabw: {tab_px(style, space), space / 2}}

    ~r/\t|[^\t]+/
    |> Regex.scan(line)
    |> Enum.map(fn
      ["\t"] -> {:word, " ", tab, :pre}
      [text] -> {:word, text, style, :pre}
    end)
  end

  # a tab runs to the next tab stop, or to the one after it when that is less than half a space
  defp tab_width({tabw, _}, _off) when tabw <= 0, do: 0

  defp tab_width({tabw, threshold}, off) do
    left = tabw - :math.fmod(off, tabw)
    round(if left < threshold, do: left + tabw, else: left)
  end

  # collapsible spaces at the end of a line vanish even when only empty inline boxes stand
  # between them and the line break, which is why they are dropped before those boxes open
  defp trim_line_end_spaces(ops) do
    ops
    |> Enum.reverse()
    |> Enum.reduce({[], true}, fn
      {:space, _}, {acc, true} ->
        {acc, true}

      {tag, _, _} = op, {acc, edge?} when tag in [:inline_open, :inline_close] ->
        {[op | acc], edge?}

      {tag, _} = op, {acc, _} when tag in [:br] ->
        {[op | acc], true}

      {:flush} = op, {acc, _} ->
        {[op | acc], true}

      op, {acc, _} ->
        {[op | acc], false}
    end)
    |> elem(0)
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
         images,
         cbh \\ nil
       ) do
    st = %{
      items: [],
      rects: [],
      n: 0,
      nr: 0,
      overlays: [],
      deferred: [],
      open: %{},
      clr: nil,
      # a margin that follows a cleared box and stays inside the box around it
      hold: 0,
      adj: nil,
      strut: nil,
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
      pstart: %{},
      # a space was taken up by an inline box opening (so what follows is not glued to what
      # came before)
      after_space: false,
      soft: false,
      # offsets of the relatively positioned inline elements the layout is inside (or nil)
      rels: [],
      bal: 0,
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
      split: [],
      splitting: false,
      runon: false,
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
      cbh: cbh,
      scbh: cbh,
      bstart: {0, 0},
      cbw: nil,
      root_view: root_height == :view,
      flex_item: Process.get(:layout_flex_item, false)
    }

    # what is laid out here is a block formatting context of its own: it grows to hold its floats
    st = ops |> tail_extents() |> Enum.reduce(st, &op/2) |> flush()
    contain_floats(st, 0)
  end

  # the right margin, border and padding of an inline box stick to its last word: they have to
  # fit on the line with it (the word wraps when they do not)
  defp tail_extents([{:word, text, style} = w | rest]) do
    case closing_extent(rest, 0) do
      0 -> [w | tail_extents(rest)]
      extra -> [{:word, text, Map.put(style, :tail, extra)} | tail_extents(rest)]
    end
  end

  defp tail_extents([op | rest]), do: [op | tail_extents(rest)]
  defp tail_extents([]), do: []

  defp closing_extent([{:inline_close, _, spec} | rest], acc),
    do: closing_extent(rest, acc + spec.pr + spec.br + spec.mr)

  defp closing_extent(_, acc), do: acc

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
    positioned = Enum.sort_by(overlays ++ over, &pz_key(Map.get(&1, :pz, 0)))
    all = under ++ under_flow ++ flow ++ positioned

    if st.limits == %{}, do: all, else: Enum.map(all, &stick_limit(&1, st.limits))
  end

  # A block ends: its content bottom is as far as sticky boxes inside it can go.
  # an empty block that held floats: they come up against the margin of what follows
  defp adjoin_floats(st, _y0, n0) do
    added = length(st.floats) - n0

    if added > 0 and st.y == hd(st.floats).y0,
      do: %{st | adj: {st.y, Enum.take(st.floats, added)}},
      else: st
  end

  # the bottom of the floats on `side` that such a block held, while nothing has come after it
  defp adjoining_bottom(%{adj: {y, floats}} = st, side) when y == st.y do
    floats
    |> Enum.filter(&(side == :both or &1.side == side))
    |> Enum.map(& &1.y1)
    |> Enum.max(fn -> nil end)
  end

  defp adjoining_bottom(_st, _side), do: nil

  defp end_block(%{blocks: [id | rest]} = st),
    do: %{st | blocks: rest, limits: Map.put(st.limits, id, st.y)}

  defp end_block(st), do: st

  defp stick_limit(%{stick: %{parent: parent} = stick} = item, limits) when parent != nil,
    do: %{item | stick: Map.put(stick, :limit, Map.get(limits, parent))}

  defp stick_limit(item, _limits), do: item

  defp op({:indent, px}, %{line: []} = st), do: %{st | lead: px}
  defp op({:indent, _px}, st), do: st

  # (a space an inline box opened over already took the room of the one that follows it)
  defp op({:space, style}, st),
    do: if(st.line == [] or st.after_space, do: st, else: %{st | pending_space: style})

  defp op({:word, text, style}, st), do: word(text, style, false, st)
  # (a zero-width space before it is a place where the line may break)
  defp op({:word, text, %{ws: :pre} = style, :pre}, %{line: [%{text: "\u200B"} | _]} = st),
    do: word(text, style, false, st)

  defp op({:word, text, style, :pre}, st), do: word(text, style, true, st)
  defp op({:word, text, style, :glue}, st), do: word(text, style, false, st, 0, true)
  defp op({:word, text, style, :hold}, st), do: word(text, style, false, st, 0, :hold)

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

  # (the margin of what follows a cleared box with no margin of its own counts from its border
  # edge: it is not subtracted from the clearance)
  defp op({:gap, px}, %{clr: {_, 0, bottom, :cleared}} = st) when st.y == bottom do
    st = flush(st)
    gap = max(st.gap, px)
    %{st | gap: gap, hold: gap}
  end

  defp op({:gap, px}, %{clr: clr} = st) when is_tuple(clr) and st.y == elem(clr, 2) do
    {y0, gap, bottom} = {elem(clr, 0), elem(clr, 1), elem(clr, 2)}
    st = flush(st)
    %{st | gap: max(st.gap, max(y0 + max(gap, px) - bottom, 0))}
  end

  defp op({:gap, px}, st), do: %{flush(st) | gap: max(st.gap, px)}

  defp op({:pad, px}, st), do: st |> flush() |> apply_gap() |> Map.update!(:y, &(&1 + px))

  # a floated box goes to the left or right edge of the line below, and text flows around it
  # a float goes beside the line it comes in when it fits there, at the top of that
  # line; otherwise the line ends and the float goes below it
  defp op({:float, side, sub, spec, style}, st),
    do:
      mid_line_float(st, side, sub, spec, style) || op({:float_below, side, sub, spec, style}, st)

  defp op({:float_below, side, sub, spec, style}, st) do
    # a float in the middle of a line that does not wrap goes below that line, which goes on
    {st, line_bottom} =
      if style.ws == :nowrap and st.line != [] and
           st.x + fit_width(st, sub, spec, max(st.width - 2 * st.margin - st.left - st.right, 0)) >
             st.width - st.margin - st.right,
         do: {st, st.y + st.lmax},
         else: {if(st.line == [], do: st, else: flush(st)), nil}

    {y0, gap, old} = {st.y, max(st.gap, 0), st.clr}
    st = if line_bottom, do: st, else: apply_gap(st)
    # the margin above a float is not used up by it: it goes on collapsing with the margins of
    # the block that follows (see the `gap` op)
    st = %{st | clr: if(gap > 0, do: {y0, gap, st.y}, else: old)}
    avail = max(st.width - 2 * st.margin - st.left - st.right, 0)
    w = fit_width(st, sub, spec, avail)
    {items, height, _base} = layout_atom(st, sub, w, Map.get(spec, :key), atom_cbh(st, spec))
    # `clear` puts the float below the earlier floats on that side
    top = clear_top(st, Map.get(spec, :clear))
    top = if line_bottom, do: max(top, line_bottom), else: top

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
        # a float is part of what its container needs when sizing to the content
        ext: max(st.ext, x + w + st.right - st.free),
        floats: [float | st.floats]
    }
  end

  # `clear`: the next line starts below the floats on that side
  defp op({:clear, side}, st) do
    adjoining = adjoining_bottom(st, side)
    st = flush(st)

    bottom =
      st.floats
      |> Enum.filter(&(side == :both or &1.side == side))
      |> Enum.map(& &1.y1)
      |> Enum.max(fn -> nil end)

    {y0, gap} = {st.y, max(st.gap, 0)}

    # a box that is not pushed down keeps its margin to collapse with others; when it is, the
    # margin of a first child collapses with the one above it (see the `gap` op)
    # (floats in an empty block just above would be pulled down by the margin: they need clearance
    # however large it is)
    # the margin of a cleared box that starts its parent would move the floats the parent holds
    # along with the parent: they reach past the box, so it is cleared (by a negative amount
    # when the margin was larger)
    {n0, start_y} = st.bstart

    moved? =
      gap > 0 and y0 == start_y and
        st.floats
        |> Enum.take(length(st.floats) - n0)
        |> Enum.any?(&((side == :both or &1.side == side) and &1.y0 == y0 and &1.y1 > y0))

    if bottom && (bottom > y0 + gap + min(st.ngap, 0) or (adjoining || 0) > y0 or moved?) do
      # (the margin of the cleared box is not part of its parents': they stay where their own
      # margins put them)
      st = apply_gap(st, true)
      %{st | y: bottom, clr: {y0, if(moved?, do: 0, else: gap), bottom, :clearance}}
    else
      st
    end
  end

  defp op({:inset, l, r}, st) do
    # (the indent of the block around it is for its own first line)
    st = if st.line == [], do: %{st | lead: 0}, else: st

    %{
      st
      | insets: [{st.left, st.right, st.y, length(st.floats), st.scbh, st.bstart} | st.insets],
        bstart: {length(st.floats), st.y},
        # (a pictures's percentage height in a block with no height of its own is auto, where
        # the percentages of boxes go on to refer to the block around, as in quirks mode)
        scbh: nil,
        blocks: [make_ref() | st.blocks],
        left: st.left + l,
        right: st.right + r,
        # (a block with nothing in it is still as wide as the insets around it, for shrink-to-fit)
        ext: max(st.ext, st.margin + st.left + l + st.right + r - st.free)
    }
  end

  defp op({:inset_end}, %{insets: [{l, r, y0, n0, cbh, bstart} | rest]} = st) do
    st = adjoin_floats(st, y0, n0)
    # the margin below a box is not one of a first child, unless the box held nothing but the
    # floats that left that margin pending: then it is empty and its margins go on collapsing
    st =
      case st.clr do
        {c0, _, bottom} when bottom == st.y and c0 >= y0 ->
          st

        {c0, g, bottom, :clearance} when bottom == st.y ->
          %{st | clr: {c0, g, bottom, :cleared}}

        _ ->
          %{st | clr: nil}
      end

    st = end_block(st)
    %{st | insets: rest, left: l, right: r, scbh: cbh, bstart: bstart}
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

  # where a column must end (`break-before/after: column`): a marker the columns read
  defp op({:colbreak}, st) do
    st = st |> flush() |> apply_gap()
    %{st | items: [%{type: :colbreak, x: 0, y: st.y, h: 0} | st.items], n: st.n + 1}
  end

  defp op({:box_start, ref, o}, st),
    do: start_box(if(st.line == [], do: %{st | lead: 0}, else: st), ref, o)

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
    # nothing was placed in it: the margin above still decides where it starts, unless the box
    # is empty and has no height: then its margins collapse together and with its neighbours'
    o = st.open[ref].o
    {_, _, obb, _} = o.bw

    held? = st.hold > 0 and st.hold == st.gap

    empty? =
      o.h in [nil, 0, 0.0] and o.min in [nil, 0, 0.0] and o[:ratio] == nil and o.pb == 0 and
        obb == 0

    st = if ref in st.ptop and not empty?, do: apply_gap(st), else: st

    # an empty box that held floats leaves the margin above them pending, to collapse on
    clr =
      case st.clr do
        {c0, g, bottom, :clearance} when empty? and bottom == st.y ->
          if c0 >= st.open[ref].top, do: {c0, g, bottom, :cleared}

        {c0, _, bottom} = clr when empty? and bottom == st.y ->
          if c0 >= st.open[ref].top or st.y == st.open[ref].top, do: clr

        _ ->
          nil
      end

    st = %{st | ptop: List.delete(st.ptop, ref), clr: clr}
    {box, open} = Map.pop(st.open, ref)
    {bt, _br, bb, _bl} = box.o.bw
    st = %{st | open: open}

    # a box that starts a formatting context contains its floats
    flow? = st.y > box.top + bt + box.o.pt
    bfc? = box.o.bfc or Map.get(box, :bfc, false)
    st = if bfc?, do: contain_floats(st, box.fl0), else: st
    st = if bfc? or flow?, do: st, else: adjoin_floats(st, box.top, box.fl0)
    st = %{st | blocks: List.delete(st.blocks, box.id)}
    st = if box.outer_floats, do: %{st | floats: box.outer_floats}, else: st

    # child margins stay inside the box only when padding or a border separates them

    ch = st.y - (box.top + bt + box.o.pt)

    # (`max-height` has no say in it: CSS2 test margin-collapse-038)
    sized? = (is_number(box.o.min) and box.o.min > ch) or (is_number(box.o.h) and box.o.h > 0)

    st =
      cond do
        box.o.pb > 0 or bb > 0 or Map.get(box, :bfc, false) -> apply_gap(st)
        # (a margin that follows a cleared box stays in the box: clearance separates it from the
        # box's own bottom margin)
        held? -> apply_gap(st)
        # (the margin below the last child is lost: the height is the one that was set)
        sized? -> %{st | gap: 0, ngap: 0, clr: nil}
        true -> st
      end

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

    {w, items, height, base} =
      table_beside_floats(st, sub, spec, avail, {w, items, height, base})

    place_atom(st, %{
      w: w,
      h: height,
      base: base,
      items: items,
      align: Map.get(spec, :malign) || style.align,
      valign: spec.valign,
      block: Map.get(spec, :cell?, false)
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
    # a balanced column without a height is as tall as holds its items in that many columns
    cs =
      if cs.height == nil and cs.maxh == nil and cs.wrap and Map.get(cs, :balance) == true and
           (cs.line_count || 0) > 1 and cs.dir in [:column, :column_reverse] do
        widest = flex_widest(st, %{cs | dir: :row}, items, avail)

        sized =
          items
          |> Enum.sort_by(& &1.order)
          |> Enum.map(fn it ->
            st
            |> flex_column_item(cs, %{it | fit?: true}, widest)
            |> then(&flex_column_basis(st, &1))
          end)

        %{
          cs
          | height: balanced_width(Enum.map(sized, & &1.h), cs.row_gap, cs.line_count) * 1.0,
            hdef: true
        }
      else
        cs
      end

    # when measuring how wide the content wants to be (an unbounded width), the container
    # is as wide as its items, rather than spreading them over the whole width
    avail = if avail > @unbounded / 2, do: flex_natural_width(st, cs, items, avail), else: avail

    # measured for its min-content (at width 1), a wrapping row is as wide as its widest item
    avail =
      if avail <= 1 and cs.wrap and cs.dir in [:row, :row_reverse] and
           Process.get(:layout_intrinsic, false),
         do: max(avail, flex_widest(st, cs, items, avail)),
         else: avail

    cs =
      if cs.col_pct > 0 and avail < @unbounded / 2,
        do: %{cs | col_gap: max(round(cs.col_gap + cs.col_pct * avail) * 1.0, 0.0)},
        else: cs

    # a percentage height is of the enclosing block's height when that is known
    cs =
      if cs.height == nil and cs.hpct != nil and is_number(st.cbh),
        do: %{cs | height: max(cs.hpct * st.cbh - cs.hx, 0), hdef: true},
        else: cs

    # a wrapping column takes its height from its width and ratio, to know where to wrap
    cs =
      with %{height: nil, maxh: nil, wrap: true, dir: dir, ratio: {r, _}} <- cs,
           true <- dir in [:column, :column_reverse] and avail < @unbounded / 2 do
        %{cs | height: avail / r, hdef: true}
      else
        _ -> cs
      end

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
      valign: nil,
      # items that overflow it still count towards how wide the content wants to be: a flex
      # container measured for its min-content (at width 1) is as wide as its items need
      overflow_counts: true
    })
  end

  # Columns: the content is laid out once at the width of a column, then cut into as many
  # columns as there are, as even as lines allow, and the pieces are set side by side.
  defp op({:columns, cs, sub, style}, st) do
    avail = max(st.width - 2 * st.margin - st.left - st.right, 0)
    # a percentage gap is of the width of the box
    cs = with %{gap: {:pct, f}} <- cs, do: %{cs | gap: f * avail}
    {n, colw} = column_geometry(cs, avail)

    # (one column of a set height still has the rest of the content spill into more of them)
    if (n <= 1 and not ((cs.height != nil and cs.fill == "auto") or cs[:colh] != nil)) or
         avail > @unbounded / 2 do
      Enum.reduce(sub, st, &op/2)
    else
      # absolutely positioned boxes are placed against their containing block, not a column
      {abs, sub} = split_outer_abs(sub)
      {items, height, _} = layout_atom(st, sub, colw)
      {laid, height} = split_columns(items, height, n, colw, cs)
      laid = [%{type: :box, x: 0, y: 0, w: avail, h: 0, rr: 0} | laid]

      st =
        place_atom(st, %{
          w: avail,
          h: height,
          base: height,
          items: laid,
          align: style.align,
          valign: nil
        })

      Enum.reduce(abs, st, &op/2)
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

    # a percentage height is of the containing block's height, when that is known
    pct_h = fn
      {:pct, f} -> if is_number(st.scbh), do: f * st.scbh
      h -> h
    end

    attrs = Map.update(spec.attrs, :h, nil, pct_h)
    css = Map.update(spec.css, :h, nil, pct_h)
    {cw, ch} = Browser.ImageBox.size(intrinsic, attrs, css, avail)
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
          blank: Map.get(spec, :blank, false),
          hidden: spec.hidden,
          nid: Map.get(spec, :nid),
          rr: box.pr + br + mr
        }

        case spec do
          %{scene: scene} ->
            ops = Browser.Svg.render(scene, cw, ch, current: spec.current)
            [Map.merge(item, %{type: :svg, ops: ops})]

          %{canvas: {bw, bh, ops}} ->
            ops = Browser.Canvas.scaled_ops(ops, cw / bw, ch / bh)
            [Map.merge(item, %{type: :svg, ops: ops})]

          _ ->
            item = Map.merge(item, %{type: :image, url: spec.url})

            case Browser.ImageBox.fit(spec.intrinsic, {cw, ch}, spec[:fit], spec[:fit_pos]) do
              nil ->
                [item]

              rect ->
                # drawn at its own size inside the item's box, which clips it
                [Map.put(item, :fit, rect)]
            end
        end
      else
        []
      end

    height = box.mt + box_h + box.mb

    place_atom(strut(st, Map.get(spec, :pstyle, style)), %{
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

  # an empty inline box with its own line height still makes the line at least that tall
  defp op({:empty_inline, style}, %{line: []} = st), do: strut(st, style)

  defp op({:empty_inline, style}, st) do
    %{st | lmax: max(st.lmax, line_px(style))}
  end

  # the narrowest room that keeps the number of lines: the lines of each run of text between
  # blocks and forced breaks are then the evenest the text allows. Only where lines may wrap
  # does the room shrink: the box and the alignment keep their width.
  defp op({:balance, inner}, st) do
    inner
    |> tail_extents()
    |> balance_runs()
    |> Enum.reduce(st, fn
      {:run, run}, st -> balance_run(st, run)
      {:ops, ops}, st -> Enum.reduce(ops, st, &op/2)
    end)
  end

  defp op({:inline_close, ref, spec}, st) do
    st = strut_for_empty(st, ref, spec)
    right = spec.pr + spec.br

    if st.line == [] do
      {fl, _} = float_offsets(st, st.y + st.gap + st.ngap)
      x = st.margin + st.left + fl + st.lead + right
      %{st | lead: st.lead + right + spec.mr, marks: [{:end, ref, x} | st.marks]}
    else
      %{st | x: st.x + right + spec.mr, marks: [{:end, ref, st.x + right} | st.marks]}
    end
  end

  # a block inside inline boxes: the boxes have no part in it; they go on after it, as fragments
  # that continue the ones before
  defp op({:run_on}, st), do: %{st | runon: true}

  defp op({:ib_split}, st) do
    # (the part of a box before the block shows its left side, on a line of its own)
    opened =
      if st.line == [],
        do:
          Enum.find(
            st.marks,
            &match?({:start, _, %{ml: ml, bl: bl, pl: pl}, _} when ml + bl + pl > 0, &1)
          )

    st = if opened, do: %{st | strut: elem(opened, 2).style}, else: st
    st = flush(%{st | splitting: true})
    %{st | split: [st.active | st.split], active: [], lead: 0, splitting: false}
  end

  defp op({:ib_join}, st) do
    st = flush(st)
    [saved | rest] = st.split

    active =
      for e <- saved, do: e |> Map.delete(:pending) |> Map.put(:joined, true)

    %{st | split: rest, active: active, lead: 0}
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
    st =
      if st.ptop == [] do
        st
      else
        # the margin above is not used up by it: it goes on collapsing with the ones below
        # (see the `gap` op)
        {y0, gap, old, neg} = {st.y, max(st.gap, 0), st.clr, st.ngap}
        st = apply_gap(st)
        %{st | clr: if(gap > 0 and neg == 0, do: {y0, gap, st.y}, else: old)}
      end

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

  defp apply_gap(st, own? \\ false)

  defp apply_gap(%{ptop: []} = st, _own?),
    do: moved_start(%{st | y: st.y + st.gap + st.ngap, gap: 0, ngap: 0, clr: nil}, st.y)

  # the margin of a first child collapsed into the margin above its parent: the parent's top
  # edge is where the merged margin ends
  defp apply_gap(st, own?) do
    y = st.y + st.gap + st.ngap

    {open, pos} =
      Enum.reduce(st.ptop, {st.open, st.pos}, fn ref, {open, pos} ->
        top = if own?, do: min(y, st.y + Map.get(st.pstart, ref, st.gap + st.ngap)), else: y
        delta = top - open[ref].top
        open = Map.update!(open, ref, &%{&1 | top: top})
        # the box a positioned descendant is placed against moves with it
        pos = Enum.map(pos, fn e -> if e[:ref] == ref, do: %{e | y: e.y + delta}, else: e end)
        {open, pos}
      end)

    moved_start(%{st | y: y, gap: 0, ngap: 0, open: open, pos: pos, ptop: [], clr: nil}, st.y)
  end

  # the start of the block around moves with the margin that was pending at it
  defp moved_start(%{bstart: {n, y0}} = st, y) when y0 == y, do: %{st | bstart: {n, st.y}}
  defp moved_start(st, _y), do: st

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

  # A line made of nothing but boxes still has the height of the font and line height around
  # them (the strut)
  # (only a line height taller than the font's own counts: the font metrics are approximate, so
  # a strut of the normal height would move pictures)
  # the runs of text that belong to the block itself, between its forced breaks and the blocks
  # inside it (the text of those is theirs); the rest as it is
  defp balance_runs(ops) do
    {parts, cur, _depth} =
      Enum.reduce(ops, {[], [], 0}, fn op, {parts, cur, depth} ->
        kind = elem(op, 0)

        depth =
          cond do
            kind in [:inset, :box_start] -> depth + 1
            kind in [:inset_end, :box_end] -> depth - 1
            true -> depth
          end

        inline? = balance_inline?(op) and depth == 0

        case cur do
          [{inl, _} | _] when inl == inline? -> {parts, [{inline?, op} | cur], depth}
          _ -> {flush_balance_part(parts, cur), [{inline?, op}], depth}
        end
      end)

    Enum.reverse(flush_balance_part(parts, cur))
  end

  defp flush_balance_part(parts, []), do: parts

  defp flush_balance_part(parts, cur) do
    ops = cur |> Enum.map(&elem(&1, 1)) |> Enum.reverse()
    [{inline_part(cur), ops} | parts]
  end

  defp inline_part([{inl, _} | _] = cur),
    do: if(inl and Enum.any?(cur, &(elem(elem(&1, 1), 0) == :word)), do: :run, else: :ops)

  defp balance_inline?(op),
    do: elem(op, 0) in [:word, :space, :inline_open, :inline_close, :pos_inline, :pos_end]

  defp balance_run(st, run) do
    avail = max(st.width - 2 * st.margin - st.left - st.right - st.fr, 1)
    n = balance_line_count(st, run, avail)

    # (floats beside the lines change how wide each is: left as they are)
    if n < 2 or Enum.any?(st.floats, &(&1.y1 > st.y)) do
      Enum.reduce(run, st, &op/2)
    else
      # (no narrower than the longest word: a word that may break anywhere does not count)
      longest =
        run
        |> Enum.map(fn
          {:word, text, style} -> st.measure.(text, style)
          {:word, text, style, _} -> st.measure.(text, style)
          _ -> 0
        end)
        |> Enum.max()

      narrow =
        balance_width(min(max(longest, 1), avail), avail, fn w ->
          balance_line_count(st, run, w) <= n
        end)

      st = Enum.reduce(run, %{st | bal: avail - narrow}, &op/2)
      %{st | bal: 0}
    end
  end

  defp balance_line_count(st, ops, width) do
    sub = run(ops, max(width, 1), st.measure, st.view_h, 0, nil, false, st.images)

    sub
    |> finalize()
    |> Enum.filter(&(&1.type == :text))
    |> Enum.map(& &1.y)
    |> Enum.uniq()
    |> length()
  end

  defp balance_width(lo, hi, _fits?) when lo >= hi, do: hi

  defp balance_width(lo, hi, fits?) do
    mid = div(lo + hi, 2)
    if fits?.(mid), do: balance_width(lo, mid, fits?), else: balance_width(mid + 1, hi, fits?)
  end

  defp strut(%{line: [], lh: 0} = st, style) do
    lf = content_factor(style)
    px = line_px(style)

    if px > round(style.size * lf),
      do: %{st | lh: style.size, lf: lf, lmax: px},
      else: st
  end

  defp strut(st, _style), do: st

  defp place_atom(st, atom) do
    line_left = st.margin + st.left

    space_w =
      if st.pending_space && st.line != [], do: st.measure.(" ", st.pending_space), else: 0

    st = if st.line == [], do: st |> apply_gap() |> start_atom_line(atom, line_left), else: st

    st =
      if st.line != [] and
           st.x + space_w + atom.w > st.width - st.margin - st.right - st.fr - st.bal and
           not glued_before?(st, space_w) do
        st |> wrap_flush() |> apply_gap() |> start_atom_line(atom, line_left)
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
          |> Enum.map(fn item ->
            item = adopt_sticky(item, st)
            if atom[:overflow_counts], do: item, else: limit_extent(item, atom.w)
          end)
          |> renumber_pz()
    }

    atom = atom |> Map.put(:type, :atom) |> Map.put(:x, x)
    atom = if rel = current_rel(st), do: Map.put(atom, :rel, rel), else: atom
    # an atom with nothing drawn in it still takes the room it asks for (one with content is
    # measured by what it draws)
    # (a width that is no more than the room there is: the width of a flex container measured
    # without a bound is not what its surroundings need)
    ext =
      if extent(atom.items) == 0 or atom.w < @unbounded / 2,
        do: max(st.ext, x + atom.w + max(extra, 0)),
        else: st.ext

    %{st | line: [atom | st.line], x: x + atom.w, pending_space: nil, ext: ext}
  end

  # characters that forbid a line break on either side of them, also next to an atomic inline
  @no_break [
    "\u202F",
    "\u2060",
    "\u200D",
    "\uFEFF",
    "\u180E",
    "\u034F",
    "\u2007",
    "\u2011",
    "\u0F08",
    "\u0F0C",
    "\u0F12"
  ]

  # text that ends in one of them, with no space between, stays with the atom that follows
  defp glued_before?(%{line: [%{type: :text, text: text} | _]}, 0),
    do: String.ends_with?(text, @no_break)

  defp glued_before?(_, _), do: false

  # ... and the other way round: a word that starts with one stays with the atom before it
  defp glued_after?(%{line: [%{type: :atom} | _]}, text, 0),
    do: String.starts_with?(text, @no_break)

  defp glued_after?(_, _, _), do: false

  # the tree order of positioned boxes in an atom (laid out earlier, maybe cached) is renewed
  # to come after what the page placed before it
  defp pz_key({z, seq}), do: {z, seq}
  defp pz_key(seq), do: {0, seq}

  defp renumber_pz(items) do
    order =
      items
      |> Enum.flat_map(&List.wrap(Map.get(&1, :pz)))
      |> Enum.uniq()
      |> Enum.sort_by(&pz_key/1)

    if order == [] do
      items
    else
      fresh =
        Map.new(order, fn
          {z, _} = pz -> {pz, {z, :erlang.unique_integer([:monotonic])}}
          pz -> {pz, :erlang.unique_integer([:monotonic])}
        end)

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
    if bt == 0 and o.pt == 0 and not o.bfc and not o.root and
         not st.flex_item and
         (st.blocks != [] or st.root_view) do
      own = st.gap + st.ngap
      st = place_box(st, ref, percent_height(st, o))

      if Map.has_key?(st.open, ref),
        do: %{st | ptop: [ref | st.ptop], pstart: Map.put(st.pstart, ref, own)},
        else: st
    else
      bfc? = o.bfc or o.root or st.flex_item or (st.blocks == [] and not st.root_view)
      # the margin of a first child still collapses with the clearance of the box above it
      clr =
        if bt == 0 and o.pt == 0 and not bfc? and st.y == elem(st.clr || {0, 0, nil}, 2),
          do: st.clr

      st = st |> apply_gap() |> place_box(ref, percent_height(st, o))
      st = if clr, do: %{st | clr: clr}, else: st

      if bfc? and Map.has_key?(st.open, ref),
        do: %{st | open: Map.update!(st.open, ref, &Map.put(&1, :bfc, true))},
        else: st
    end
  end

  # a percentage height, max-height or min-height is a share of the enclosing block's height
  # when that is known
  defp percent_height(st, o) do
    # the root's percentage refers to the window, anything else to the block it sits in
    base = if o.root and st.root_view, do: st.view_h, else: st.cbh
    o = stretch_height(o, base)

    if is_number(base) do
      o
      |> pct_set(:h, o.hpct, base, Map.get(o, :hoff, 0))
      |> pct_set(:max, o.maxpct, st.cbh, Map.get(o, :maxoff, 0))
      |> pct_set(:min, o.minpct, st.cbh, Map.get(o, :minoff, 0))
    else
      o
    end
  end

  # `height: stretch`: the containing block's (definite) height, less the padding and borders
  # when it is for the content box. The margins in the block direction are left out: they
  # collapse with the container's or fall outside it.
  defp stretch_height(%{hstretch: true} = o, base) when is_number(base) do
    {bt, _, bb, _} = o.bw
    inner = if o.sizing == :border, do: 0, else: o.pt + o.pb + bt + bb
    h = round(max(base - inner, 0))

    Enum.reduce(o.hstretch_for, o, fn
      "height", o -> if o.h == nil, do: %{o | h: h}, else: o
      "min-height", o -> if o.min == nil, do: %{o | min: h}, else: o
      "max-height", o -> if o.max == nil, do: %{o | max: h}, else: o
    end)
  end

  defp stretch_height(o, _base), do: o

  defp pct_set(o, key, pct, base, off) when is_number(pct) and is_number(base) do
    if Map.get(o, key) == nil,
      do: Map.put(o, key, max(round(pct * base + off), 0)),
      else: o
  end

  defp pct_set(o, _key, _pct, _base, _off), do: o

  defp place_box(st, ref, o) do
    {_bt, br, _bb, bl} = o.bw
    avail = max(st.width - 2 * st.margin - st.left - st.right, 0)
    hpad = o.pl + o.pr + bl + br
    intrinsic? = Process.get(:layout_intrinsic, false)

    # width properties are for the content box unless box-sizing is border-box
    to_content = fn
      nil -> nil
      {:pct, _} when intrinsic? -> nil
      {:kw, _} -> nil
      v -> v |> resolve(avail) |> then(&if(o.sizing == :border, do: max(&1 - hpad, 0), else: &1))
    end

    ml0 = if o.ml == :auto, do: 0, else: o.ml
    mr0 = if o.mr == :auto, do: 0, else: o.mr

    # a box that clips (overflow other than visible) starts a block formatting context: it does
    # not overlap the floats beside it, but narrows to the room they leave, or moves below them
    {fl, fr} = if o.bfc, do: float_offsets(st, st.y, st.y + max(o.h || 1, 1)), else: {0, 0}
    beside = avail - fl - fr

    flex_item? = st.flex_item and st.blocks == []

    # (a flex item is as wide as the flex algorithm made it, which has taken its ratio into account)
    cw =
      to_content.(o.width) || (intrinsic? && o.cisw && round(o.cisw)) ||
        (not (flex_item? and o.flex_sized) && ratio_width(o, hpad)) ||
        max(beside - ml0 - mr0 - hpad, 0)

    cw =
      if o.width == nil and o.h == nil and not flex_item?, do: ratio_limits(o, hpad, cw), else: cw

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

    # (a positive right margin of a box with a width of its own does not push it below a float)
    mr_fit = if o.width, do: min(mr0, 0), else: mr0

    # (the margin above it counts from where it was: it can take up the way down)
    if below && ml0 + box_w + mr_fit > beside,
      do: place_box(%{st | y: below, gap: max(st.gap - (below - st.y), 0)}, ref, o),
      else: open_box(st, ref, o, {fl, fr, beside}, {ml0, mr0, box_w, free})
  end

  # a box with a height and an aspect ratio takes its width from them when it has none
  defp ratio_width(%{ratio: {r, kind}, h: h} = o, hpad) when is_number(h) do
    {bt, _, bb, _} = o.bw
    vpad = o.pt + o.pb + bt + bb
    # the height of the content box, whatever box-sizing says it was given for
    content_h = if o.sizing == :border, do: max(h - vpad, 0), else: h

    round(
      if ratio_sizing(o, kind) == :border,
        do: max((content_h + vpad) * r - hpad, 0),
        else: content_h * r
    )
  end

  defp ratio_width(_, _), do: nil

  # a box whose width comes from its height and aspect ratio is that wide whatever it holds
  defp ratio_sized?(%{width: nil, ratio: {_, _}, h: h}) when is_number(h), do: true
  defp ratio_sized?(_), do: false

  # `min-height` and `max-height` of a box with an aspect ratio and no width carry over to it
  defp ratio_limits(%{ratio: {_, _}} = o, hpad, cw) do
    cw = if o.max, do: min(cw, ratio_width(%{o | h: o.max}, hpad)), else: cw
    if o.min, do: max(cw, ratio_width(%{o | h: o.min}, hpad)), else: cw
  end

  defp ratio_limits(_, _, cw), do: cw

  defp open_box(st, ref, o, {fl, fr, beside}, {ml0, mr0, box_w, free}) do
    {bt, br, _bb, bl} = o.bw
    intrinsic? = Process.get(:layout_intrinsic, false)

    {ml, _mr} =
      case {o.ml, o.mr} do
        # (while measuring how wide content wants to be, auto margins are none)
        {:auto, _} when intrinsic? -> {ml0, mr0}
        {_, :auto} when intrinsic? -> {ml0, mr0}
        {:auto, :auto} -> {max(floor(free / 2), 0), max(free - floor(free / 2), 0)}
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
    rest = if ml0 < 0 or mr0 < 0 or own_width?(o.width), do: rest, else: max(rest, 0)
    x = st.margin + left

    id = make_ref()

    own_free =
      if own_width?(o.width) || o.maxw || (intrinsic? && o.cisw),
        do: max(rest - mr0, 0),
        else: 0

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
      fl0: if(o.bfc, do: 0, else: length(st.floats)),
      outer_floats: if(o.bfc, do: st.floats),
      ov0: length(st.overlays),
      seq: :erlang.unique_integer([:monotonic]),
      pcbh: st.cbh,
      pscbh: st.scbh,
      pbstart: st.bstart,
      pcbw: st.cbw,
      saved: {st.left, st.right, st.free},
      need: x + bl + o.pl + st.right + fr + rest + br + o.pr - st.free - own_free
    }

    new_cbh =
      if(
        st.flex_item and st.blocks == [] and not Map.get(o, :definite, false) and
          not (o.ratio != nil and o.h == nil),
        do: nil,
        else: content_height(o) || ratio_content_height(o, box_w)
      )

    st = %{
      st
      | open: Map.put(st.open, ref, box),
        blocks: [id | st.blocks],
        scbh: new_cbh,
        cbh: new_cbh,
        # (a border or padding keeps the margin of a first child from reaching the box's start)
        bstart: {length(st.floats), if(bt + o.pt == 0, do: st.y)},
        cbw: max(box_w - bl - br - o.pl - o.pr, 0),
        floats: if(o.bfc, do: [], else: st.floats),
        left: left + bl + o.pl,
        right: st.right + fr + rest + br + o.pr,
        # room beside a box with a width is not part of what it needs
        free: st.free + own_free,
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

  # without a height, an aspect ratio gives one from the width; content that is taller keeps
  # its room unless the box clips it
  defp ratio_height(%{ratio: {r, kind}} = o, box, content, extra) do
    {_, br, _, bl} = o.bw
    border_h = box.w / r

    h =
      if ratio_sizing(o, kind) == :border,
        do: max(border_h - extra, 0),
        else: max(box.w - bl - br - o.pl - o.pr, 0) / r

    if o.clip, do: h, else: max(h, content)
  end

  defp ratio_height(_, _, content, _), do: content

  defp ratio_sizing(_o, :content), do: :content
  defp ratio_sizing(o, :sizing), do: o.sizing

  defp finish_box(st, %{o: o} = box) do
    {bt, br, bb, bl} = o.bw
    natural = st.y - box.top
    extra = bt + o.pt + o.pb + bb
    content = natural - extra

    # height properties size the content box unless box-sizing is border-box
    inner = fn v -> if o.sizing == :border, do: max(v - extra, 0), else: v end

    used = if o.h, do: inner.(o.h), else: ratio_height(o, box, content, extra)
    used = if o.max, do: min(used, inner.(o.max)), else: used
    used = if o.min, do: max(used, inner.(o.min)), else: used
    used = if Map.get(o, :maxc), do: min(used, max(content, 0)), else: used
    used = if Map.get(o, :minc), do: max(used, max(content, 0)), else: used
    used = round(used)

    # (what a scrolling box clips is still there: it scrolls into view)
    clipped? = o.clip and used < content and Map.get(o, :scroll) == nil
    # a too-small height is the height of the box all the same: the content overflows it
    height = used + extra

    limit = box.top + bt + o.pt + used
    st = if clipped?, do: drop_below(st, box, limit), else: st
    st = %{st | y: box.top + height}

    st =
      if (own_width?(o.width) or o.maxw != nil or ratio_sized?(o)) and fixed_width?(box),
        do:
          limit_new_items(
            %{st | ext: max(st.ext, box.x + box.w + box_mr(o) + max(st.right - st.free, 0))},
            box
          ),
        else: st

    # an empty box is as wide as the insets around its content, for shrink-to-fit
    st =
      if own_width?(o.width) or o.maxw != nil or ratio_sized?(o),
        do: st,
        else: %{st | ext: max(st.ext, box.need)}

    # (a size-contained box is as wide as its `contain-intrinsic-size` says, whatever it holds)
    st =
      if o.cisw != nil and Process.get(:layout_intrinsic, false),
        do: %{st | ext: max(st.ext, box.x + box.w + box_mr(o) + max(st.right - st.free, 0))},
        else: st

    st = place_deferred(st, box, height)

    # overflow clips to the padding box
    clip = %{
      x: box.x + bl,
      y: box.top + bt,
      w: max(box.w - bl - br, 0),
      h: max(height - bt - bb, 0)
    }

    sid = if Map.get(o, :scroll), do: o.nid || box.id
    st = if o.clip, do: clip_new(st, box, clip, sid), else: st

    st =
      if o.cpath,
        do: cpath_new(st, box, %{x: box.x, y: box.top, w: box.w, h: height}),
        else: st

    st = if sid, do: add_scroller(st, sid, clip, o), else: st

    # the box's own background and borders go under whatever is inside it
    outer = outer_rects(box, height, st.images)
    {new, old} = Enum.split(st.rects, st.nr - box.nr0)
    st = %{st | rects: new ++ Enum.reverse(outer) ++ old, nr: st.nr + length(outer)}
    # sticky boxes inside stop at the bottom of this one's content
    st = %{st | limits: Map.put(st.limits, box.id, box.top + height - bb - o.pb)}
    st = %{st | cbh: box.pcbh, scbh: box.pscbh, bstart: box.pbstart, cbw: box.pcbw}
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
    # (a block inside a relatively positioned inline goes along with it)
    {dx, dy} =
      case current_rel(st) do
        {rx, ry, _} -> {dx + rx, dy + ry}
        nil -> {dx, dy}
      end

    {new_items, old_items} = Enum.split(st.items, st.n - box.n0)
    {new_rects, old_rects} = Enum.split(st.rects, st.nr - box.nr0)
    {new_over, old_over} = Enum.split(st.overlays, length(st.overlays) - box.ov0)

    # a positioned box paints above the non-positioned content of the flow
    shift = fn list ->
      Enum.map(list, fn it ->
        layer = if box.o.z < 0, do: :under, else: :over
        it |> move(dx, dy) |> Map.put(layer, true) |> Map.put_new(:pz, z_order(box.seq, box.o.z))
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

  # a box with an aspect ratio and no height has the height its width gives it (when its
  # content is not taller), which is what the percentages of its children refer to
  defp ratio_content_height(%{h: nil, ratio: {_, _}, clip: false} = o, box_w) do
    {bt, _, bb, _} = o.bw
    h = ratio_height(o, %{w: box_w}, 0, bt + o.pt + o.pb + bb)
    if o.max == nil and o.min == nil, do: h
  end

  defp ratio_content_height(_, _), do: nil

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
            color4(Map.get(o, :color) || {0, 0, 0}),
            viewport_area()
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

    # (with the `boxes` option every element keeps its box, for the scripts that ask for its size
    # or position: a container that draws nothing itself, or one scrolled or clipped out of sight)
    bounds =
      if Map.get(o, :nid) && Process.get(:layout_boxes, false) && w > 0 && height > 0,
        do: [%{type: :bounds, x: x, y: y, w: w, h: height}],
        else: []

    # a box that clips its content (overflow) is not split across columns
    body = if o[:clip], do: Enum.map(body, &Map.put(&1, :mono, true)), else: body
    shadows ++ body ++ marker ++ bounds
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

  # drop whatever was created inside the box entirely below `limit` (an element still has its
  # box for the scripts, drawn or not: `:bounds` stay)
  defp drop_below(st, box, limit) do
    keep? = &(&1.y < limit or &1.type == :bounds)
    {new_items, old_items} = Enum.split(st.items, st.n - box.n0)
    kept_items = Enum.filter(new_items, keep?)
    {new_rects, old_rects} = Enum.split(st.rects, st.nr - box.nr0)
    kept_rects = Enum.filter(new_rects, keep?)

    %{
      st
      | items: kept_items ++ old_items,
        n: box.n0 + length(kept_items),
        rects: kept_rects ++ old_rects,
        nr: box.nr0 + length(kept_rects)
    }
  end

  # items and rects created inside a clipping box get (intersected) clip rectangles
  defp clip_new(st, box, clip, sid) do
    {new_items, old_items} = Enum.split(st.items, st.n - box.n0)
    {new_rects, old_rects} = Enum.split(st.rects, st.nr - box.nr0)

    %{
      st
      | items: Enum.map(new_items, &put_clip(&1, clip, sid)) ++ old_items,
        rects: Enum.map(new_rects, &put_clip(&1, clip, sid)) ++ old_rects
    }
  end

  # `clip-path: inset(0)` clips the box and everything it paints, a fixed box inside it too (it
  # is where the window shows the box, so a fixed item has its own clip in page coordinates:
  # `fclip`)
  defp cpath_new(st, box, rect) do
    st = clip_new(st, box, rect, nil)
    {new_over, old_over} = Enum.split(st.overlays, length(st.overlays) - box.ov0)

    clip_item = fn
      %{stick: _} = it -> Map.update(it, :fclip, rect, &intersect(&1, rect))
      it -> put_clip(it, rect, nil)
    end

    %{st | overlays: Enum.map(new_over, &Enum.map(&1, clip_item)) ++ old_over}
  end

  # `inset(0)` with no rounded corners
  defp plain_inset?(v) when is_binary(v),
    do: Regex.match?(~r/\Ainset\(\s*0(?:px)?(?:\s+0(?:px)?){0,3}\s*\)\z/, String.trim(v))

  defp plain_inset?(_), do: false

  # Besides the merged `clip`, an item keeps each clip it got as `{rect, k, scroller}` (`k` is
  # how many scrollers it was already inside) and the scrollers it is in, innermost first
  # (`sc`): scrolling one of them moves the item and the clips inside it, not those outside.
  defp put_clip(item, clip, sid) do
    sc = Map.get(item, :sc, [])
    entry = {clip, length(sc), sid}
    item = Map.put(item, :clip, intersect(Map.get(item, :clip), clip))
    item = Map.update(item, :clips, [entry], &[entry | &1])
    if sid, do: Map.put(item, :sc, sc ++ [sid]), else: item
  end

  # the box that scrolls its content: where it is, and how far its content reaches past it
  defp add_scroller(st, sid, clip, o) do
    item = %{
      type: :scroller,
      sid: sid,
      x: clip.x,
      y: clip.y,
      w: clip.w,
      h: clip.h,
      ov: o.scroll,
      pb: o.pb,
      pr: o.pr
    }

    %{st | items: [item | st.items], n: st.n + 1}
  end

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
      cond do
        # (a block-level box is where a block would be: under the line, at its start)
        st.line != [] and not Map.get(spec, :inline, true) ->
          {fl, _} = float_offsets(st, st.y)
          {st.margin + st.left + fl, st.y + st.lmax}

        st.line != [] ->
          {st.x, st.y}

        Map.get(spec, :inline) ->
          y = st.y + st.gap + st.ngap
          {fl, fr} = float_offsets(st, y)
          left = st.margin + st.left + fl
          room = st.width - st.margin - st.right - fr - left

          # the static position of the box is that of an empty one on the line
          shift =
            case Map.get(spec, :align) do
              :center -> max(round(room / 2), 0)
              align when align in [:right, :rstart] -> max(room, 0)
              _ -> 0
            end

          {left + shift, y}

        true ->
          {st.margin + st.left, st.y + st.gap + st.ngap}
      end

    static_x = round(static_x)

    # a right-to-left box ends where the empty line would put it (a box on a line is at the
    # line's start edge)
    static_right =
      if spec.rtl and st.line == [] and Map.get(spec, :inline),
        do: round(static_x),
        else: st.width - st.margin - st.right

    left = resolve_h(spec.left, cw)
    right = resolve_h(spec.right, cw)
    top = resolve_v(spec.top, origin.h)
    bottom = origin.h && resolve_v(spec.bottom, origin.h)

    sub = if spec.replaced, do: Enum.map(sub, &pct_to_px(&1, cw)), else: sub
    {width, x} = abs_width(st, sub, spec, origin, left, right, {static_x, static_right})
    # `top` and `bottom` with an auto height stretch the box between them
    sub =
      cond do
        (spec.autoh and top) && bottom ->
          stretch(sub, origin.h - top - bottom, left != nil and right != nil)

        is_number(spec.hpct) and origin.h ->
          set_height(sub, spec.hpct * origin.h)

        # `height: stretch`: what the insets leave of the containing block
        spec.hstretch and origin.h ->
          set_height(sub, max(origin.h - (top || 0) - (bottom || 0) - auto_zero(spec.mb), 0))

        true ->
          sub
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

    {x, y} = flex_aligned(spec, st, origin, {x, y}, {width, height}, {left, right, top, bottom})
    {tx, ty} = resolve_translate(spec.translate, width, height)
    # a negative `z-index` puts the box behind the flow: above the page's background only
    layer = if spec.z < 0 and !spec.fixed, do: :under, else: :over

    moved =
      for it <- items,
          do:
            it
            |> move(x + tx, y + ty)
            |> Map.put(layer, true)
            |> Map.put_new(:pz, z_order(spec.seq, spec.z))

    # a fixed box stays where it is in the window while the page scrolls
    moved =
      if spec.fixed,
        do: Enum.map(moved, &(&1 |> Map.put(:stick, :fixed) |> Map.put(:z, spec.z))),
        else: moved

    %{st | overlays: [moved | st.overlays]}
  end

  # an absolute child of a flex container sits where it would be as the only flex item: its
  # static position is aligned by `justify-content` and `align-items` within the container
  defp flex_static([{:abs, sub, spec} | rest], c, ic) do
    if c["writing-mode"] in [nil, "horizontal-tb"] and c["direction"] in [nil, "ltr"],
      do: [{:abs, sub, Map.put(spec, :fpos, flex_fpos(c, ic))} | rest],
      else: [{:abs, sub, spec} | rest]
  end

  defp flex_static(acc, _c, _ic), do: acc

  defp flex_fpos(c, ic) do
    align = ic["align-self"]
    align = if align in [nil, "auto"], do: c["align-items"], else: align

    %{
      column?: c["flex-direction"] in ["column", "column-reverse"],
      justify: c["justify-content"],
      align: align,
      w: num(c["width"]),
      h: num(c["height"])
    }
  end

  defp pct_of({:pct, f}), do: f
  defp pct_of(_), do: nil

  # a height of `calc(100% - 2rem)`: a share of the enclosing height, and a length
  defp calc_pct({:calc, _px, f}), do: f
  defp calc_pct(_), do: nil
  defp calc_px({:calc, px, _f}), do: px
  defp calc_px(_), do: 0

  # the static position of an absolute child of a flex container, moved by the container's
  # alignment (when the container's size on that axis is known)
  defp flex_aligned(%{fpos: f} = spec, st, origin, {x, y}, {w, h}, {left, right, top, bottom}) do
    room_w = f.w || max(st.width - 2 * st.margin - st.left - st.right, 0)
    mx = auto_zero(spec.ml) + auto_zero(spec.mr)
    my = auto_zero(spec.mb)

    {jx, jy} = if f.column?, do: {f.align, f.justify}, else: {f.justify, f.align}

    nx = if left || right, do: x, else: x + abs_main_shift(jx, room_w - w - mx)
    ny = if top || bottom || f.h == nil, do: y, else: y + abs_main_shift(jy, f.h - h - my)

    # (`safe` alignment keeps the box inside its containing block)
    nx = if safe?(jx), do: keep_inside(nx, x, w, origin.x, origin.w), else: nx
    ny = if safe?(jy) and origin.h, do: keep_inside(ny, y, h, origin.y, origin.h), else: ny
    {nx, ny}
  end

  defp flex_aligned(_spec, _st, _origin, pos, _size, _offsets), do: pos

  defp safe?(mode), do: is_binary(mode) and String.starts_with?(mode, "safe ")

  defp keep_inside(new, old, size, start, extent),
    do: if(new < start or new + size > start + extent, do: old, else: new)

  defp abs_main_shift("safe " <> mode, free), do: abs_main_shift(mode, free)
  defp abs_main_shift("unsafe " <> mode, free), do: abs_main_shift(mode, free)
  defp abs_main_shift("center", free), do: round(free / 2)
  defp abs_main_shift(mode, free) when mode in ["flex-end", "end", "self-end"], do: free
  defp abs_main_shift(_mode, _free), do: 0

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
  defp stretch(sub, target, both_sides?) do
    case own_box(sub) do
      # a box with an aspect ratio whose width is set by `left` and `right` takes its height from it
      {_before, _ref, %{ratio: {_, _}}, _tail} when both_sides? ->
        sub

      {before, ref, o, tail} ->
        {bt, _, bb, _} = o.bw
        extra = if o.sizing == :border, do: 0, else: bt + o.pt + o.pb + bb
        target = max(target - extra, 0)
        before ++ [{:box_start, ref, %{o | h: target}} | flex_height(tail, target)]

      nil ->
        flex_height(sub, target)
    end
  end

  # a flex container takes the height it is given (a definite one for its items' percentages)
  defp flex_height(sub, target) do
    Enum.map(sub, fn
      {:flex, %{height: nil} = cs, items, style} ->
        {:flex, %{cs | height: max(target - cs.hx, 0), hdef: true}, items, style}

      op ->
        op
    end)
  end

  # an absolute element's percentage height is of its containing block
  defp set_height(sub, h) do
    case own_box(sub) do
      {before, ref, o, tail} -> before ++ [{:box_start, ref, %{o | h: h}} | flex_height(tail, h)]
      nil -> flex_height(sub, h)
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

    it =
      case it do
        %{clips: clips} ->
          %{it | clips: Enum.map(clips, fn {r, k, sid} -> {shift_rect(r, dx, dy), k, sid} end)}

        _ ->
          it
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

  @doc false
  def shift(it, dx, dy), do: move(it, dx, dy)

  defp shift_rect(%{x: x, y: y} = c, dx, dy), do: %{c | x: x + dx, y: y + dy}
  defp shift_box({x, y, w, h}, dx, dy), do: {x + dx, y + dy, w, h}

  # (a `fixed` layer is placed against the window: only the part it shows moves)
  defp shift_layer(%{fixed: true} = layer, dx, dy),
    do: %{layer | clip: shift_box(layer.clip, dx, dy)}

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

  defp resolve({:kw, _}, _base), do: nil
  defp resolve({:pct, f}, base), do: round(f * base)
  defp resolve({:calc, px, f}, base), do: round(max(px + f * base, 0))

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
        # `width: stretch`: what the insets and margins leave of the containing block
        nil when spec.stretch ->
          max(
            cw - (left || 0) - (right || 0) - (ml || 0) - (mr || 0) - spec.extra + spec.extra,
            0
          )

        nil ->
          avail =
            cond do
              left && right -> cw - left - right
              # (a child of a flex container is aligned within the container, not stretched)
              Map.has_key?(spec, :fpos) and left == static_x - origin.x -> cw
              left -> cw - left
              true -> cw - right
            end

          avail = max(avail - (ml || 0) - (mr || 0), 40)

          # a flex or grid container as the content wants its own natural width, not the room
          at =
            if Enum.any?(sub, &match?({tag, _, _, _} when tag in [:flex, :grid], &1)),
              do: @unbounded,
              else: avail

          if left && right && !spec.replaced && !Map.get(spec, :fit, false) do
            avail
          else
            min(avail, shrink_extent(st, sub, at, Map.get(spec, :key)))
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
    # while content is measured, a percentage depends on the width being measured: it counts as none
    intrinsic? = Process.get(:layout_intrinsic) == true
    maxw = if intrinsic? and match?({:pct, _}, spec.maxw), do: nil, else: spec.maxw
    minw = if intrinsic? and match?({:pct, _}, spec.minw), do: nil, else: spec.minw

    width =
      case resolve(maxw, base) do
        nil -> width
        m -> min(width, m + spec.extra + spec.mextra)
      end

    case resolve(minw, base) do
      nil -> width
      m -> max(width, m + spec.extra + spec.mextra)
    end
  end

  # outer width of an inline-block: its width, or shrink-to-fit within `avail`
  defp fit_width(st, sub, spec, avail) do
    width =
      case resolve(spec.width, avail) do
        nil ->
          case ratio_fit(sub, spec) do
            nil -> content_width(st, sub, spec, avail)
            w -> w + spec.extra + spec.mextra
          end

        w ->
          w + spec.extra + spec.mextra
      end

    width
    |> clamp_width(spec, avail)
    |> clamp_keyword(st, sub, spec, avail)
  end

  # `max-width: min-content` (and the other keywords) clamp by what the content makes of them
  defp clamp_keyword(width, st, sub, spec, avail) do
    width =
      case spec.maxw do
        {:kw, kw} -> min(width, keyword_width(kw, st, sub, spec, avail))
        _ -> width
      end

    case spec.minw do
      {:kw, kw} -> max(width, keyword_width(kw, st, sub, spec, avail))
      _ -> width
    end
  end

  defp keyword_width({:fitc, limit}, st, sub, spec, avail),
    do: content_width(st, sub, %{spec | sizing: {:fitc, limit}}, avail)

  defp keyword_width(:fit, st, sub, spec, avail),
    do: content_width(st, sub, %{spec | sizing: {:fitc, avail}}, avail)

  defp keyword_width(kw, st, sub, spec, avail),
    do: content_width(st, sub, %{spec | sizing: kw}, avail)

  # an inline-block that has a height and an aspect ratio is as wide as they make it
  defp ratio_fit(sub, spec) do
    with {_before, _ref, %{ratio: {_, _}, h: h} = o, _tail} when is_number(h) <- own_box(sub),
         true <- spec.sizing not in [:minc, :maxc] and not fitc?(spec.sizing) do
      ratio_width(o, spec.extra)
    else
      _ -> nil
    end
  end

  defp content_width(st, sub, %{sizing: :minc} = spec, _avail),
    do: min_extent(st, sub, Map.get(spec, :key), Map.get(spec, :mr, 0))

  defp content_width(st, sub, %{sizing: {:fitc, limit}} = spec, avail) do
    limit = if match?({:pct, _}, limit), do: resolve(limit, avail), else: limit
    narrowest = min_extent(st, sub, Map.get(spec, :key), Map.get(spec, :mr, 0))
    widest = shrink_extent(st, sub, @unbounded, Map.get(spec, :key))
    min(widest, max(narrowest, limit))
  end

  defp content_width(st, sub, %{sizing: :maxc} = spec, _avail),
    do: shrink_extent(st, sub, @unbounded, Map.get(spec, :key))

  defp content_width(st, sub, spec, avail) do
    # a table or a flex container is as wide as its content wants, up to the room there is
    measure_at =
      if Map.get(spec, :table?) or Map.get(spec, :flex?), do: @unbounded, else: max(avail, 1)

    key = Map.get(spec, :key)
    wanted = shrink_extent(st, sub, measure_at, key)

    # (text that wraps fills the room there is: the box is not tightened to its longest line)
    wanted =
      if wanted < avail and measure_at == max(avail, 1) and
           shrink_extent(st, sub, @unbounded, key) > avail,
         do: avail,
         else: wanted

    # While a table cell is measured at a width of 1, shrink-to-fit is never narrower than the
    # narrowest the content can be: the inline-block still holds its unbreakable text
    if wanted <= avail,
      do: wanted,
      else: min(wanted, max(avail, min_extent(st, sub, key)))
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
  defp min_extent(st, sub, key, right_margin \\ 0) do
    memo({:min_extent, key || :erlang.phash2(sub)}, fn ->
      case min_words(sub, st.measure, 0, 0, [], 0) do
        :layout -> shrink_extent(st, sub, 1, key) + right_margin
        ext -> ext
      end
    end)
  end

  # `cur` is the width of the unbreakable run the words so far end in: a word glued to the
  # one before it (`a<b>b</b>`) extends it
  defp min_words(ops, measure, l, r, stack, ext, cur \\ 0)

  defp min_words([], _measure, _l, _r, _stack, ext, _cur), do: ext

  defp min_words([op | rest], measure, l, r, stack, ext, cur) do
    case op do
      {:word, _, %{wrap_chars: mode}} when mode in [:all, :every, :anywhere] ->
        :layout

      {:word, _, %{wrap_chars: mode}, _} when mode in [:all, :every, :anywhere] ->
        :layout

      {:word, text, style} ->
        min_run(rest, measure, l, r, stack, ext, measure.(trim_hang(text), style))

      {:word, text, style, :glue} ->
        min_run(rest, measure, l, r, stack, ext, cur + measure.(trim_hang(text), style))

      {:inset, dl, dr} ->
        # (a box with nothing in it still takes the room of its margins, borders and padding)
        min_words(rest, measure, l + dl, r + dr, [{l, r} | stack], max(ext, l + dl + r + dr), cur)

      {:inset_end} when stack != [] ->
        [{l, r} | stack] = stack
        min_words(rest, measure, l, r, stack, ext, cur)

      {tag, _} when tag in [:space, :gap, :pad] ->
        min_words(rest, measure, l, r, stack, ext, 0)

      {:flush} ->
        min_words(rest, measure, l, r, stack, ext, 0)

      _ ->
        :layout
    end
  end

  defp min_run(rest, measure, l, r, stack, ext, cur),
    do: min_words(rest, measure, l, r, stack, max(ext, l + r + cur), cur)

  defp trim_hang(text), do: String.trim_trailing(text, "\u3000")

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
  # a float with a percentage height refers to the height of the box it sits in
  defp atom_cbh(st, %{hpct_atom: pct}) when pct != nil, do: st.cbh
  defp atom_cbh(_st, _spec), do: nil

  defp layout_atom(st, sub, width, key \\ nil, cbh \\ nil) do
    memo(
      {:atom, key || :erlang.phash2(sub), width, cbh, Process.get(:layout_intrinsic, false)},
      fn ->
        # (the height of the box a float or inline-block sits in is what its own percentage
        # heights refer to)
        sub_st = run(sub, max(width, 0), st.measure, st.view_h, 0, nil, true, st.images, cbh)
        height = sub_st.y + sub_st.gap + sub_st.ngap
        items = finalize(sub_st)
        {items, height, last_baseline(items, height)}
      end
    )
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
    |> Enum.map(
      &(min(&1.x + &1.w - hanging(&1, items), Map.get(&1, :xlim, @unbounded)) +
          Map.get(&1, :rr, 0))
    )
    |> Enum.max(fn -> 0 end)
  end

  # what hangs past the end of a line does not count: the width of the item's `hang`, unless
  # something follows it on its line
  defp hanging(%{hang: hang, y: y, x: x}, items) do
    if Enum.any?(items, &(&1.type == :text and &1.y == y and &1.x > x)), do: 0, else: hang
  end

  defp hanging(_, _), do: 0

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

  defp mid_line_float(%{line: [_ | _]} = st, side, sub, spec, _style) do
    avail = max(st.width - 2 * st.margin - st.left - st.right, 0)
    w = fit_width(st, sub, spec, avail)
    edge = st.width - st.margin - st.right

    if Map.get(spec, :clear) == nil and st.x + w <= edge - st.fr do
      {items, height, _base} = layout_atom(st, sub, w, Map.get(spec, :key), atom_cbh(st, spec))
      {x, y} = place_float(st, side, w, height, st.y, st.margin + st.left, edge)

      if y == st.y do
        moved = for item <- items, do: item |> limit_extent(w) |> move(x, y) |> adopt_sticky(st)
        float = %{side: side, x0: x, x1: x + w, y0: y, y1: y + height}

        st = %{
          st
          | items: Enum.reverse(moved) ++ st.items,
            n: st.n + length(moved),
            ext: max(st.ext, x + w + st.right - st.free),
            floats: [float | st.floats]
        }

        if side == :left,
          do: shift_line(st, max(x + w - st.indent, 0)),
          else: %{st | fr: max(st.fr, edge - x)}
      end
    end
  end

  defp mid_line_float(_st, _side, _sub, _spec, _style), do: nil

  # the line moves right by `dx`: what is on it, where it started and the inline boxes open on it
  defp shift_line(st, 0), do: st

  defp shift_line(st, dx) do
    marks =
      Enum.map(st.marks, fn
        {:start, ref, spec, x} -> {:start, ref, spec, x + dx}
        {:end, ref, x} -> {:end, ref, x + dx}
      end)

    %{
      st
      | line: Enum.map(st.line, &%{&1 | x: &1.x + dx}),
        x: st.x + dx,
        indent: st.indent + dx,
        marks: marks
    }
  end

  # A line beside floats that a word cannot fit on moves down to where a float ends. (A word that
  # may break between its letters is not moved: some of it fits; nor is a line that cannot wrap.)
  defp begin_line(st, line_left, dx, w, style) do
    first = start_line(st, line_left, dx)

    if st.floats != [] and Map.get(style, :wrap_chars, :none) == :none and
         style.ws not in [:pre, :nowrap] do
      narrowed(st, first, line_left, dx, w)
    else
      first
    end
  end

  defp narrowed(st0, st, line_left, dx, w) do
    right = st.width - st.margin - st.right - st.fr
    beside? = st.fr > 0 or st.indent > line_left

    next =
      if beside? and st.x + w > right do
        st.floats
        |> Enum.filter(&(&1.y0 <= st.y and &1.y1 > st.y))
        |> Enum.map(& &1.y1)
        |> Enum.min(fn -> nil end)
      end

    if next && next > st.y,
      do: narrowed(st0, start_line(%{st0 | y: next}, line_left, dx), line_left, dx, w),
      else: st
  end

  defp word(text, style, nowrap?, st, dx \\ 0, glue \\ false) do
    if String.contains?(text, "\u00AD"),
      do: shy_word(text, style, nowrap?, st, dx, glue),
      else: plain_word(text, style, nowrap?, st, dx, glue)
  end

  # A word with soft hyphens: when it does not fit, the line breaks at the last one that lets
  # the part before it (and the hyphen shown there) fit.
  defp shy_word(text, style, nowrap?, st, dx, glue) do
    clean = String.replace(text, "\u00AD", "")
    line_left = st.margin + st.left
    st = if st.line == [], do: st |> apply_gap() |> start_line(line_left, dx), else: st

    space_w =
      if st.pending_space && st.line != [], do: st.measure.(" ", st.pending_space), else: 0

    room = st.width - st.margin - st.right - st.fr - st.bal - st.x - space_w
    segs = String.split(text, "\u00AD")

    cond do
      # (a soft hyphen's break does not count when sizing to the content)
      nowrap? || Process.get(:layout_intrinsic, false) || st.measure.(clean, style) <= room ->
        plain_word(clean, style, nowrap?, st, 0, glue)

      true ->
        fits =
          for k <- (length(segs) - 1)..1//-1,
              head = segs |> Enum.take(k) |> Enum.join(),
              st.measure.(head <> style.hyph, style) <= room,
              do: k

        case fits do
          [k | _] -> shy_break(segs, k, style, st, glue, line_left)
          [] when st.line != [] -> shy_retry(text, style, st, glue, line_left)
          [] -> shy_break(segs, 1, style, st, glue, line_left)
        end
    end
  end

  defp shy_retry(text, style, st, glue, line_left) do
    st = st |> wrap_flush() |> apply_gap() |> start_line(line_left, 0)
    shy_word(text, style, false, st, 0, glue)
  end

  defp shy_break(segs, k, style, st, glue, line_left) do
    {head, rest} = Enum.split(segs, k)
    st = plain_word(Enum.join(head) <> style.hyph, style, true, st, 0, glue)
    st = st |> wrap_flush() |> apply_gap() |> start_line(line_left, 0)
    word(Enum.join(rest, "\u00AD"), style, false, st, 0, false)
  end

  defp plain_word(text, style, nowrap?, st, dx, glue) do
    w =
      case style.tabw do
        nil ->
          st.measure.(text, style)

        tab ->
          tab_width(tab, if(st.line == [], do: dx + st.lead, else: st.x - st.indent))
      end

    line_left = st.margin + st.left

    space_w =
      if st.pending_space && st.line != [], do: st.measure.(" ", st.pending_space), else: 0

    st = if st.line == [], do: st |> apply_gap() |> begin_line(line_left, dx, w, style), else: st

    case split_point(text, style, nowrap?, st, w, space_w) do
      nil -> word_placed(text, style, nowrap?, st, glue, w, space_w, line_left)
      split -> word_split(split, style, st, glue, line_left)
    end
  end

  # `word-break: break-all` and `overflow-wrap: break-word | anywhere` let a word that does not
  # fit break between its characters. -> nil, or {head, rest}: what fits on the line and the rest
  # ("" for head when the line has to wrap before anything of the word goes on it)
  defp split_point(text, style, nowrap?, st, w, space_w) do
    mode = Map.get(style, :wrap_chars, :none)
    # break-word's opportunities do not count when sizing to the content; anywhere's do
    mode = if mode == :word and Process.get(:layout_intrinsic), do: :none, else: mode
    mode = if mode == :anywhere, do: :word, else: mode
    mode = if mode == :every, do: :all, else: mode
    right = st.width - st.margin - st.right - st.fr - st.bal
    space_w = if st.line == [], do: 0, else: space_w

    cond do
      nowrap? or mode == :none or String.length(text) < 2 ->
        nil

      st.x + space_w + w - trailing_ls(style) <= right ->
        nil

      # break-word: a word that fits a line of its own wraps whole first
      mode == :word and w <= right - st.indent ->
        nil

      mode == :word and st.line != [] ->
        {"", text}

      true ->
        room = right - st.x - space_w
        {head, rest} = longest_prefix(text, style, st, room)

        if head == "" and st.line == [],
          do: String.split_at(text, 1),
          else: {head, rest}
    end
  end

  defp longest_prefix(text, style, st, room) do
    chars = String.graphemes(text)

    fit =
      chars
      |> Enum.with_index(1)
      |> Enum.take_while(fn {_, n} ->
        st.measure.(chars |> Enum.take(n) |> Enum.join(), style) - trailing_ls(style) <= room
      end)
      |> length()

    fit = if Map.get(style, :wrap_chars) == :all, do: keep_punctuation(chars, fit), else: fit
    {chars |> Enum.take(fit) |> Enum.join(), chars |> Enum.drop(fit) |> Enum.join()}
  end

  # `break-all` does not break before punctuation that cannot start a line: the character before
  # it goes to the next line too, or when that leaves nothing, the punctuation stays
  defp keep_punctuation(chars, fit) do
    cond do
      fit >= length(chars) ->
        fit

      not (no_start?(Enum.at(chars, fit)) or prefix?(Enum.at(chars, fit - 1)) or
             glue_char?(Enum.at(chars, fit)) or glue_char?(Enum.at(chars, fit - 1))) ->
        fit

      fit > 1 ->
        keep_punctuation(chars, fit - 1)

      true ->
        keep_punctuation(chars, fit + 1)
    end
  end

  defp no_start?(ch), do: String.contains?("./,;:!?)]}%\u3001\u3002\uFF0C\uFF0E\u2026", ch)

  # a prefix symbol (a currency sign, a backslash) never ends a line: `word-break: break-all`
  # does not change that
  defp glue_char?(ch), do: ch in ["\u00A0" | @no_break]

  defp prefix?(ch), do: String.contains?("$\\+\u00A3\u00A4\u00A5\u20AC\u00B1", ch)

  defp word_split({"", rest}, style, st, glue, line_left) do
    st = st |> wrap_flush() |> apply_gap() |> start_line(line_left, 0)
    word(rest, style, false, st, 0, glue)
  end

  defp word_split({head, rest}, style, st, glue, line_left) do
    w = st.measure.(head, style)

    space_w =
      if st.pending_space && st.line != [], do: st.measure.(" ", st.pending_space), else: 0

    st = word_placed(head, style, true, st, glue, w, space_w, line_left)

    if rest == "" do
      st
    else
      st = st |> wrap_flush() |> apply_gap() |> start_line(line_left, 0)
      word(rest, style, false, st)
    end
  end

  defp word_placed(text, style, nowrap?, st, glue, w, space_w, line_left) do
    glued? = glue != false
    hang = hang_width(text, style, st)

    st =
      cond do
        st.line == [] or nowrap? or hang == w or glued_after?(st, text, space_w) or
            st.x + space_w + w + Map.get(style, :tail, 0) - hang <=
              st.width - st.margin - st.right - st.fr - st.bal ->
          st

        # no space between this word and what comes before: they only break before all of it
        glued? and space_w == 0 and not st.after_space ->
          # (under `break-all` a closing punctuation mark takes the last letter before it along)
          glue =
            if glue == true and style.wrap_chars == :all and no_start?(String.first(text)),
              do: :hold,
              else: glue

          wrap_glued(st, line_left, glue, style)

        true ->
          st |> wrap_flush() |> apply_gap() |> start_line(line_left, 0)
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
      blank: style.blank,
      hidden: style.hidden,
      color: style.color,
      underline: style.underline,
      strike: style.strike,
      ls: style.ls,
      vs: style.vs,
      wsp: style.wsp,
      alast: style.alast,
      nojust: style.nojust or style.ws == :pre,
      align: style.align,
      cid: style.cid,
      nid: style.nid,
      # the room boxes around it keep free on its right: for measuring how wide content is
      rr: st.right - st.free
    }

    item = if hang > 0, do: Map.put(item, :hang, hang), else: item
    item = if style.wrap_chars != :none, do: Map.put(item, :wc, style.wrap_chars), else: item
    item = if rel = current_rel(st), do: Map.put(item, :rel, rel), else: item
    st = bridge(st, item, space_w)

    # text that continues the text before it in the same style (across the tags of elements that
    # paint nothing) is one run: it is measured and drawn as such
    case st.line do
      [%{type: :text, glue: _} = prev | older]
      when glue? and hang == 0 and space_w == 0 ->
        if mergeable?(prev, item) do
          text = prev.text <> item.text
          w = st.measure.(text, style)
          merged = %{prev | text: text, w: w}

          %{
            st
            | line: [merged | older],
              x: prev.x + w,
              runon: false,
              pending_space: nil,
              after_space: false,
              lf: if(style.size >= st.lh, do: content_factor(style), else: st.lf),
              lh: max(st.lh, style.size),
              lmax: max(st.lmax, line_px(style))
          }
        else
          push_word(st, item, x, w, style)
        end

      _ ->
        push_word(st, item, x, w, style)
    end
  end

  defp mergeable?(prev, item) do
    keys = [:x, :w, :text, :glue, :lm, :hang, :nid]

    Map.drop(prev, keys) == Map.drop(item, keys) and prev.x + prev.w == item.x and
      not String.match?(prev.text <> item.text, ~r/\s|[\x{2000}-\x{200A}\x{3000}]/u) and
      not Map.has_key?(prev, :hang) and not Map.has_key?(prev, :wc)
  end

  defp push_word(st, item, x, w, style) do
    %{
      st
      | line: [item | st.line],
        x: x + w,
        runon: false,
        pending_space: nil,
        after_space: false,
        lf: if(style.size >= st.lh, do: content_factor(style), else: st.lf),
        lh: max(st.lh, style.size),
        lmax: max(st.lmax, line_px(style))
    }
  end

  # ideographic spaces at the end of a word hang: they take no room when the line is filled
  # or the content measured
  defp hang_width(_text, %{ws: :break_spaces}, _st), do: 0

  # (the spaces `pre-wrap` preserves hang when they do not fit)
  defp hang_width(text, %{ws: :pre_wrap} = style, st) do
    w = st.measure.(text, style)

    if text != "" and String.trim(text, "\u00A0") == "" and
         st.x + w > st.width - st.margin - st.right - st.fr - st.bal,
       do: w,
       else: ideographic_hang(text, style, st)
  end

  defp hang_width(text, style, st), do: ideographic_hang(text, style, st)

  defp ideographic_hang(text, style, st) do
    hang =
      case String.trim_trailing(text, "\u3000") do
        ^text -> 0
        "" -> st.measure.(text, style)
        body -> st.measure.(text, style) - st.measure.(body, style)
      end

    # (the spacing after the last letter of a line is not shown nor counted)
    min(hang + trailing_ls(style), st.measure.(text, style))
  end

  # A word that does not fit, glued to the text before it (`bb<b>cc</b>`): everything back to
  # the last place a line may break moves to the next line together.
  # (`word-break: break-all` takes the last letter of the word before a space of `break-spaces`
  # along, since a break may not come between a letter and the space after it)
  defp wrap_glued(
         %{line: [%{type: :text, text: text} = it | older]} = st,
         line_left,
         :hold,
         %{wrap_chars: :all} = style
       )
       when older != [] or byte_size(text) > 1 do
    case String.graphemes(text) do
      [_, _ | _] = chars ->
        {head, [last]} = Enum.split(chars, length(chars) - 1)
        head = Enum.join(head)
        head_w = st.measure.(head, style)
        st = %{st | line: [%{it | text: head, w: head_w} | older], x: it.x + head_w}
        st = st |> wrap_flush() |> apply_gap() |> start_line(line_left, 0)
        word_placed(last, style, true, st, false, st.measure.(last, style), 0, line_left)

      _ ->
        wrap_glued(st, line_left, :hold)
    end
  end

  # (`word-break: break-word` lets a space of `break-spaces` wrap away from a word that has no
  # earlier break opportunity on its line)
  defp wrap_glued(%{line: [%{type: :text} | older]} = st, line_left, :hold, %{wrap_chars: mode})
       when older == [] and mode in [:word, :anywhere] do
    wrap_alone(st, line_left, nil)
  end

  # (a line that is all one unbreakable run overflows)
  defp wrap_glued(%{line: line} = st, line_left, true, %{wrap_chars: :none}) do
    {chain, rest} = Enum.split_while(line, &Map.get(&1, :glue, false))

    case rest do
      [%{type: :text}] ->
        if Enum.all?(chain ++ rest, &(&1.type == :text and not is_map_key(&1, :wc))),
          do: st,
          else: wrap_glued(st, line_left, true)

      _ ->
        wrap_glued(st, line_left, true)
    end
  end

  defp wrap_glued(st, line_left, glued, _style), do: wrap_glued(st, line_left, glued)

  defp wrap_glued(st, line_left, glued) do
    {chain, rest} = Enum.split_while(st.line, &Map.get(&1, :glue, false))

    case rest do
      [%{type: :text} = first | [_ | _] = older] ->
        if Enum.all?(chain, &(&1.type == :text)),
          do: carry_chain(st, line_left, [first | chain], older),
          else: wrap_alone(st, line_left, glued)

      # nothing earlier to break at: the word goes first on the next line, as it would
      # with a break allowed there; a space of `break-spaces`, which only ever breaks after
      # itself, stays on the line it overflows
      _ ->
        wrap_alone(st, line_left, glued)
    end
  end

  defp wrap_alone(st, _line_left, :hold), do: st

  defp wrap_alone(st, line_left, _),
    do: st |> wrap_flush() |> apply_gap() |> start_line(line_left, 0)

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
    st = st |> wrap_flush() |> apply_gap() |> start_line(line_left, 0)
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
  defp flush(%{line: [], strut: %{} = style} = st) do
    st = word("", style, false, %{st | strut: nil})
    flush(%{st | line: [Map.put(hd(st.line), :strut, true) | tl(st.line)]})
  end

  defp flush(%{line: []} = st) do
    active =
      st.marks
      |> Enum.reverse()
      |> Enum.reduce(st.active, fn
        {:start, ref, spec, _x}, active -> active ++ [%{ref: ref, spec: spec, pending: true}]
        {:end, ref, _x}, active -> Enum.reject(active, &(&1.ref == ref))
      end)

    %{st | pending_space: nil, marks: [], active: active, soft: false}
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

    # an atom with a length or percentage `vertical-align` sits that far above the baseline
    raise = fn
      %{valign: n} when is_number(n) -> round(n)
      %{valign: {:pct, f}} -> round(f * st.lh)
      _ -> 0
    end

    base = Enum.reduce(on_baseline, text_base, &max(&2, &1.base + raise.(&1)))
    below = Enum.reduce(on_baseline, lh - text_base, &max(&2, &1.h - &1.base - raise.(&1)))
    # text raised or lowered by `vertical-align` makes the line taller where it sticks out
    {base, below} = raised_room(texts, base, below, normal, half, text_base)

    # a middle-aligned box taller than the line reaches above it: the baseline moves down so that
    # it still starts at the top of the line
    mid_up = fn a -> div(a.h, 2) + round(st.lh * 0.3) end

    lift =
      for(%{valign: "middle"} = a <- floating, do: mid_up.(a) - base) |> Enum.max(fn -> 0 end)

    base = base + max(lift, 0)

    line_h =
      Enum.reduce(floating, base + below, fn
        %{valign: "middle"} = a, h -> max(h, base - mid_up.(a) + a.h)
        a, h -> max(h, a.h)
      end)

    shift = static_shift(Enum.reverse(st.line), st)
    dy = base - text_base

    placed =
      for it <- texts,
          do: %{
            it
            | x: it.x + shift,
              y: st.y + dy + half + normal - it.h - div(normal - it.h, 4) - Map.get(it, :vs, 0)
          }

    placed =
      placed
      |> Enum.reject(&Map.get(&1, :strut))
      |> Enum.map(&Map.drop(&1, [:glue, :lm]))
      |> apply_rel()

    placed = justify(placed, st, List.last(st.line), shift)

    top_of = fn
      %{valign: "top"} -> st.y
      %{valign: "bottom"} = a -> st.y + line_h - a.h
      %{valign: "middle"} = a -> st.y + base - round(st.lh * 0.3) - div(a.h, 2)
      a -> st.y + base - a.base - raise.(a)
    end

    moved =
      for atom <- Enum.reverse(atoms),
          sub <- atom_items(atom),
          do: move(sub, atom.x + shift, top_of.(atom)) |> Map.put(:blk, Map.get(atom, :block))

    moved = apply_rel(moved)

    # everything a box paints behind its text: colours, borders, images, shadows
    {behind, others} =
      Enum.split_with(moved, &(&1.type in @behind_text and !Map.get(&1, :over)))

    # (a table cell outside a table is a block of its own; what an inline-block paints is inline
    # content, above the backgrounds of blocks)
    {rects, inline_rects} = Enum.split_with(behind, &Map.get(&1, :blk))
    others = Enum.map(others, &Map.delete(&1, :blk))
    rects = Enum.map(rects, &Map.delete(&1, :blk))
    inline_rects = Enum.map(inline_rects, &Map.delete(&1, :blk))

    new_items = Enum.reverse(others) ++ placed

    ctx = %{
      shift: shift,
      first_x: (st.line |> List.last() |> Map.fetch!(:x)) - st.line_lead,
      last_right: (fn l -> l.x + l.w end).(hd(st.line)),
      split: st.splitting,
      y_ref: fn size ->
        if normal > 0,
          do: st.y + dy + half + normal - size - div(normal - size, 4),
          else: st.y + base - size
      end
    }

    {boxes, active, carried, lead} = inline_boxes(st, ctx)
    # `boxes` is already newest-first like st.rects
    inline_rects = Enum.reverse(inline_rects) ++ boxes

    # (what a line holds paints as inline content: above the backgrounds of the blocks, whatever
    # their order in the page)
    %{
      st
      | items: new_items ++ inline_rects ++ st.items,
        n: st.n + length(new_items) + length(inline_rects),
        rects: Enum.reverse(rects) ++ st.rects,
        nr: st.nr + length(rects),
        line: [],
        y: st.y + line_h,
        strut: nil,
        lh: 0,
        lf: @content_factor,
        lmax: 0,
        x: st.indent,
        pending_space: nil,
        marks: carried,
        active: active,
        lead: lead,
        soft: false
    }
  end

  # a line that ends because the next word does not fit (a justified one stretches)
  defp wrap_flush(st), do: flush(%{st | soft: true})

  defp raised_room(texts, base, below, normal, half, text_base) do
    Enum.reduce(texts, {base, below}, fn
      %{vs: vs} = it, {b, bl} when vs != 0 ->
        y_rel = half + normal - it.h - div(normal - it.h, 4)
        {max(b, text_base + vs - y_rel), max(bl, y_rel + it.h - vs - text_base)}

      _, acc ->
        acc
    end)
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
          if x >= ctx.last_right and not ctx.split and not MapSet.member?(ended, ref) do
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

    done =
      Enum.reduce(open, done, fn box, acc ->
        # (a box that a block splits, with nothing in it before the block, shows its left side)
        # (it follows the text, the space between them being at the end of the line)
        if ctx.split and is_number(box.x) and box.x >= ctx.last_right do
          [{%{box | x: ctx.last_right}, ctx.last_right + box.spec.bl + box.spec.pl, false} | acc]
        else
          [{box, ctx.last_right, false} | acc]
        end
      end)

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
    content = round(spec.size * Map.get(spec, :cf, 1.2))
    # With a guessed content height (no font was measured) the text sits a little low in its line,
    # and the box around it spans the content area from the top of the line. A measured font is
    # drawn from the top of that area.
    above =
      if Process.get(:layout_metrics) || content <= spec.size,
        do: 0,
        else: content - spec.size - div(content - spec.size, 4)

    y = ctx.y_ref.(spec.size) - above - spec.pt - spec.bt
    h = content + spec.pt + spec.pb + spec.bt + spec.bb
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

  defp static_shift(_items, %{aligned?: false}), do: 0

  defp static_shift([first | _] = items, st) do
    free = line_free(items, st)

    case line_mode(first, st) do
      :center -> max(round(free / 2), 0)
      :right -> max(round(free), 0)
      :rstart -> round(free) - st.line_lead
      :rjustify -> round(free) - st.line_lead
      _ -> 0
    end
  end

  # the room left on a line: it runs from its start (inline-box lead included) to wherever the
  # last box's padding/border ends, which `st.x` tracks
  defp line_free([first | _] = items, st) do
    last = List.last(items)
    left = min(first.x, st.indent)
    right = max(last.x + last.w, st.x)
    st.width - st.margin - st.right - st.fr - st.indent - (right - left)
  end

  # how a line is aligned: a line that is not the last one follows `text-align`; the last
  # (or one before a forced break) follows `text-align-last`, or starts at its start edge when
  # the text is justified
  defp line_mode(first, st) do
    cond do
      st.soft ->
        first.align

      Map.get(first, :alast) ->
        first.alast

      first.align == :justify ->
        :left

      first.align == :rjustify ->
        :rstart

      true ->
        first.align
    end
  end

  # Justified lines share their free room out between the spaces. Lines with inline boxes
  # that draw something, and text that keeps its white space, are left as they are.
  defp justify(placed, st, first, shift) do
    if line_mode(first, st) in [:justify, :rjustify] and not Map.get(first, :nojust, false) and
         st.marks == [] and
         st.active == [] and
         Enum.all?(placed, &(&1.type == :text and not Map.get(&1, :nojust, false))) do
      ordered = Enum.reverse(placed)
      free = line_free(Enum.reverse(st.line), st)
      gaps = ordered |> Enum.chunk_every(2, 1, :discard) |> Enum.count(&gap?/1)

      if free > 0 and gaps > 0 do
        {out, _, _} =
          Enum.reduce(ordered, {[], nil, 0}, fn it, {acc, prev, j} ->
            j = if prev && gap?([prev, it]), do: j + 1, else: j
            {[%{it | x: it.x - shift + round(j * free / gaps)} | acc], it, j}
          end)

        out
      else
        placed
      end
    else
      placed
    end
  end

  defp gap?([a, b]), do: b.x - (a.x + a.w) > 0

  # -- flexbox ------------------------------------------------------------------------------

  # ── grid ─────────────────────────────────────────────────────────────────────────────────

  # the content height of a grid container that has a height of its own
  defp grid_height(tag, c) do
    box = box(tag, c)
    {bt, _br, bb, _bl} = box.bw
    vextra = if c["box-sizing"] == "border-box", do: box.pt + box.pb + bt + bb, else: 0

    case num(c["height"]) || num(c["min-height"]) do
      n when is_number(n) -> max(n - vextra, 0)
      _ -> nil
    end
  end

  defp grid_spec(tag, c) do
    fs = if is_number(c["font-size"]), do: c["font-size"], else: 16.0

    %{
      tracks: grid_tracks(c["grid-template-columns"], fs),
      rows: grid_tracks(c["grid-template-rows"], fs),
      auto_row: c["grid-auto-rows"] |> grid_tracks(fs) |> List.first({:auto}),
      content: c["align-content"] || "normal",
      align_set: c["align-items"] == "stretch",
      justify_set: c["justify-items"] == "stretch",
      height: grid_height(tag, c),
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

    groups = Enum.group_by(placed, & &1.row)
    nrows = max(length(gs.rows), (groups |> Map.keys() |> Enum.max(fn -> -1 end)) + 1)

    # every item laid out at the width of its columns: what a row needs is its tallest item
    rows =
      for r <- 0..(nrows - 1)//1 do
        sized =
          for it <- Map.get(groups, r, []) do
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
          end

        # (what an item laid out includes its own margins)
        natural = sized |> Enum.map(& &1.h) |> Enum.max(fn -> 0 end) |> max(0)
        {sized, natural}
      end

    heights = grid_row_heights(gs, rows, round(gs.row_gap))

    {laid, y} =
      rows
      |> Enum.zip(heights)
      |> Enum.map_reduce(0, fn {{sized, _natural}, cross}, y ->
        placed_items =
          Enum.flat_map(sized, fn it ->
            it = grid_stretch(st, it, gs, cross)
            dy = flex_offset(flex_align(it, gs.align), cross, it.h)
            dx = grid_justify(it, gs, it.room)
            x = Enum.at(xs, it.col) + auto_zero(it.ml) + dx
            for item <- z_items(it), do: move(item, round(x), y + dy)
          end)

        {placed_items, y + cross + round(gs.row_gap)}
      end)

    {List.flatten(laid), width, max(y - round(gs.row_gap), 0)}
  end

  # An item that fills its row: stretched taller, or (with a ratio) sized by the axis it stretches
  # in. A ratio is given up when both sizes are fixed, by stretching or by a length: only
  # `align-self`/`justify-self: stretch` set on purpose count as stretching for it.
  defp grid_stretch(st, %{ratio: {r, _}, rebuild: build} = it, gs, cross)
       when build != nil and is_number(r) do
    block? = grid_explicit_stretch?(it.align, gs.align_set)
    inline? = grid_explicit_stretch?(it.gjustify, gs.justify_set)
    box_h = max(cross - it.mt - it.mb - if(it.sizing == :border, do: 0, else: it.vextra), 0) * 1.0

    cond do
      it.hpct != nil and inline? ->
        h =
          max(
            it.hpct * (cross - it.mt - it.mb) - if(it.sizing == :border, do: 0, else: it.vextra),
            0
          )

        grid_resize(st, it, build.(%{"height" => h * 1.0, "aspect-ratio" => nil}), it.w, h)

      inline? and it.ch != nil and it.width == nil ->
        w = max(round(it.room), 1)

        grid_resize(
          st,
          it,
          build.(%{"aspect-ratio" => nil, "width" => w * 1.0 - it.extra}),
          w,
          :w
        )

      it.width != nil and block? and it.auto_height? ->
        grid_resize(st, it, build.(%{"height" => box_h, "aspect-ratio" => nil}), it.w, box_h)

      it.auto_height? and block? and inline? ->
        grid_resize(st, it, build.(%{"height" => box_h, "aspect-ratio" => nil}), it.w, box_h)

      it.auto_height? and block? and it.width == nil ->
        w = max(round(box_h * r) + it.extra, 1)
        grid_resize(st, it, build.(%{"height" => box_h, "width" => w * 1.0 - it.extra}), w, box_h)

      true ->
        it
    end
  end

  defp grid_stretch(st, it, gs, cross) do
    if it.width == nil or it.ratio == nil or it.rebuild == nil do
      flex_stretch(st, it, gs.align, cross)
    else
      it
    end
  end

  defp grid_explicit_stretch?(self, container),
    do: self == "stretch" or (self in ["auto", nil] and container)

  defp grid_resize(st, it, sub, w, box_h) do
    {items, h, _} = flex_atom(st, sub, w, {it.key, :grid, w, box_h})
    %{it | items: items, h: h, w: w}
  end

  # The height of every row. A row with a size of its own (`px`) has it; `fr` rows share what a
  # container with a height leaves; with room to spare, the `auto` rows grow into it.
  defp grid_row_heights(gs, rows, gap) do
    tracks =
      for i <- 0..(length(rows) - 1)//1,
          do: Enum.at(gs.rows, i) || gs.auto_row

    base =
      Enum.zip(tracks, rows)
      |> Enum.map(fn {track, {_, natural}} ->
        case track do
          {:px, n} ->
            n * 1.0

          {:minmax, {:px, lo}, {:px, hi}} ->
            natural |> max(lo) |> min(max(lo, hi)) |> Kernel.*(1.0)

          {:minmax, {:px, lo}, _} ->
            max(natural, lo) * 1.0

          _ ->
            natural * 1.0
        end
      end)

    gaps = gap * max(length(rows) - 1, 0)

    frac = fn
      {:fr, f} -> f
      {:minmax, _, {:fr, f}} -> f
      _ -> 0
    end

    flex_total = tracks |> Enum.map(frac) |> Enum.sum()

    auto? = fn
      {:auto} -> true
      {:minmax, _, {:auto}} -> true
      {:minmax, _, {:maxc}} -> true
      _ -> false
    end

    cond do
      gs.height == nil ->
        base

      flex_total > 0 ->
        fixed =
          Enum.zip(tracks, base)
          |> Enum.filter(&(frac.(elem(&1, 0)) == 0))
          |> Enum.map(&elem(&1, 1))
          |> Enum.sum()

        unit = max(gs.height - gaps - fixed, 0) / max(flex_total, 1.0)

        Enum.zip(tracks, base)
        |> Enum.map(fn {t, b} -> if frac.(t) > 0, do: max(b, frac.(t) * unit), else: b end)

      gs.content in ["stretch", "normal"] and Enum.any?(tracks, auto?) ->
        free = gs.height - gaps - Enum.sum(base)
        n = Enum.count(tracks, auto?)

        if free > 0 do
          Enum.zip(tracks, base)
          |> Enum.map(fn {t, b} -> if auto?.(t), do: b + free / n, else: b end)
        else
          base
        end

      true ->
        base
    end
    |> Enum.map(&round/1)
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
          |> Enum.map(&(grid_extent(st, &1, 1) + auto_zero(&1.ml) + auto_zero(&1.mr)))
          |> Enum.max(fn -> 0 end)

        max =
          singles
          |> Enum.map(&(grid_extent(st, &1, @unbounded) + auto_zero(&1.ml) + auto_zero(&1.mr)))
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

  # what a grid item asks of its column: a width of its own, else what its content makes of it
  defp grid_extent(st, it, width) do
    case it.width do
      w when is_number(w) -> w + it.extra
      _ -> shrink_extent(st, it.sub, width, it.key)
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

  # a percentage gap is of the container's height, which it only has when it is set
  # a gap given as a percentage (or `calc(10% - 1rem)`) is of the container's width
  defp gap_px({:calc, px, _f}), do: px * 1.0
  defp gap_px(_), do: 0.0

  defp gap_pct({:pct, f}), do: f
  defp gap_pct({:calc, _px, f}), do: f
  defp gap_pct(_), do: 0.0

  defp row_gap({:pct, f}, height) when is_number(height), do: f * height
  defp row_gap(gap, _height), do: num(gap) || 0.0

  defp flex_spec(tag, c) do
    fs = if is_number(c["font-size"]), do: c["font-size"], else: 16.0
    box = box(tag, c)
    {bt, _br, bb, _bl} = box.bw
    vextra = if c["box-sizing"] == "border-box", do: box.pt + box.pb + bt + bb, else: 0
    # the content height a container with a height of its own gives its line
    inner = fn v -> if is_number(v), do: max(v - vextra, 0) end

    %{
      dir: flex_direction(c["flex-direction"]),
      wrap: wraps?(c["flex-wrap"]),
      balance: wrap_words(c["flex-wrap"]) |> Enum.member?("balance"),
      line_count: flex_line_count(c["flex-line-count"]),
      wrap_reverse: wrap_words(c["flex-wrap"]) |> Enum.member?("wrap-reverse"),
      trim: trim_sides(c["margin-trim"]),
      justify: c["justify-content"] || "flex-start",
      content: c["align-content"] || "stretch",
      align: c["align-items"] || "stretch",
      col_gap: num(c["column-gap"]) || gap_px(c["column-gap"]),
      col_pct: gap_pct(c["column-gap"]),
      row_gap: row_gap(c["row-gap"], inner.(num(c["height"]))),
      height: inner.(num(c["height"])) || inner.(num(c["min-height"])),
      maxh: inner.(num(c["max-height"])),
      dir_rtl: c["direction"] == "rtl",
      rtl: c["direction"] == "rtl" and not wraps?(c["flex-wrap"]),
      hpct: pct_of(c["height"]),
      ratio: aspect_ratio(c["aspect-ratio"]),
      hdef: inner.(num(c["height"])) != nil,
      hx: vextra,
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

  # Cuts laid-out content (`items`, `height` tall) into columns. With a height of its own (and
  # `column-fill: auto`) every column is that tall and the rest spills into more columns; else
  # the columns are as short as the content allows, `n` of them. Lines move whole into the
  # next column, backgrounds are cut where a column ends. -> {the items placed, the height used}
  defp split_columns(items, height, n, colw, %{gap: gap} = cs) do
    lines =
      items
      |> Enum.filter(&(&1.type not in [:rect, :box]))
      |> Enum.map(&{&1.y, &1.y + Map.get(&1, :h, 0)})
      |> Enum.uniq()
      |> Enum.sort()

    top0 = with [{t, _} | _] <- lines, do: t, else: (_ -> 0)
    # (`column-wrap: wrap` alone wraps columns of the height of the box)
    colh = cs[:colh] || if cs[:wrap] == "wrap", do: cs.height
    fixed = colh || cs.height
    wrap? = colh != nil and cs[:wrap] != "nowrap"
    rowgap = cs[:rowgap] || 0

    forced =
      for(%{type: :colbreak, y: y} <- items, y > 0 and y < height, uniq: true, do: y)
      |> Enum.sort()

    items = Enum.reject(items, &(&1.type == :colbreak))
    sliced? = fixed != nil or forced != []

    h =
      cond do
        colh ->
          colh

        fixed && cs.fill == "auto" ->
          fixed

        true ->
          fits? = fn h -> length(column_starts(lines, height, h, top0, forced, sliced?)) <= n end
          low = max(ceil(height / n), 1)
          high = max(ceil(height), low)
          high = if fixed, do: max(min(high, ceil(fixed)), 1), else: high
          if fits?.(low), do: low, else: search_height(fits?, low, high)
      end

    starts = lines |> column_starts(height, h, top0, forced, sliced?) |> Enum.map(&round/1)
    ends = Enum.drop(starts, 1) ++ [:infinity]
    cols = starts |> Enum.zip(ends) |> Enum.with_index()

    rows = if wrap?, do: max(div(length(cols) + n - 1, n), 1), else: 1

    used =
      cond do
        wrap? ->
          rows * colh + (rows - 1) * rowgap

        fixed ->
          fixed

        true ->
          starts
          |> Enum.zip(Enum.drop(starts, 1) ++ [height])
          |> Enum.map(fn {a, b} -> b - a end)
          |> Enum.max(fn -> 0 end)
      end

    # where column k goes: its place in the row, and the rows above it
    slot = fn k ->
      if wrap?,
        do: {rem(k, n) * (colw + gap), div(k, n) * (colh + rowgap)},
        else: {k * (colw + gap), 0}
    end

    placed =
      Enum.flat_map(items, fn it ->
        if sliced? and it.type in [:rect, :box] and not Map.get(it, :mono, false) and
             Map.get(it, :h, 0) > 0 do
          cut_rect(it, cols, slot)
        else
          {{start, _}, k} =
            cols |> Enum.filter(fn {{s, _}, _} -> s <= it.y end) |> List.last() || {{0, 0}, 0}

          {dx, dy} = slot.(k)
          [column_move(it, dx, dy - start)]
        end
      end)

    used = round(used)

    {placed ++
       column_rules(cs, if(wrap?, do: min(length(cols), n), else: length(cols)), colw, used),
     used}
  end

  # a background or border box cut into the part that lies in each column
  defp cut_rect(it, cols, slot) do
    top = it.y
    bottom = it.y + it.h

    pieces =
      for {{s, e}, k} <- cols, top < ((e == :infinity && bottom + 1) || e), bottom > s do
        y0 = max(top, s)
        y1 = if e == :infinity, do: bottom, else: min(bottom, e)
        piece = %{it | y: y0, h: y1 - y0}

        piece =
          case piece do
            %{border: %{w: {bt, br, bb, bl}} = b} ->
              bt = if y0 > top, do: 0, else: bt
              bb = if y1 < bottom, do: 0, else: bb
              %{piece | border: %{b | w: {bt, br, bb, bl}}}

            _ ->
              piece
          end

        {dx, dy} = slot.(k)
        column_move(piece, dx, dy - s)
      end

    if pieces == [], do: [it], else: pieces
  end

  # a box moved to its column keeps its edges on whole pixels: both sides are rounded from the
  # exact position, so neighbours that touch in layout still touch on the screen
  defp column_move(%{type: type, x: x, w: w} = it, dx, dy)
       when type in [:rect, :box] and is_number(w) and is_float(dx) do
    left = round(x + dx)
    moved = move(it, round(dx), dy)
    %{moved | x: left, w: round(x + dx + w) - left}
  end

  defp column_move(it, dx, dy), do: move(it, round(dx), dy)

  # a rule down the middle of the gap between each two columns that have content
  defp column_rules(%{rule: nil}, _count, _colw, _h), do: []

  defp column_rules(%{rule: {w, color}, gap: gap}, count, colw, h) do
    for k <- 1..(count - 1)//1 do
      x = k * (colw + gap) - gap / 2 - w / 2
      %{type: :rect, x: round(x), y: 0, w: round(w), h: round(h), color: color, rr: 0}
    end
  end

  # the least height in low..high at which the lines fit the columns (fits? is monotonic)
  defp search_height(_fits?, low, high) when low >= high, do: high

  defp search_height(fits?, low, high) do
    mid = div(low + high, 2)
    if fits?.(mid), do: search_height(fits?, low, mid), else: search_height(fits?, mid + 1, high)
  end

  # where each column starts when content is poured into columns of height `h`: the first at
  # the top; a line that straddles the end of a column goes to the next, which starts as far
  # above that line as the first column's first line (`top0`) is below its top
  defp column_starts(lines, total, h, top0, forced, sliced?) do
    if sliced?, do: do_starts(lines, total, h, top0, forced, 0, [0]), else: line_starts(lines, h)
  end

  # without a height of its own only lines break (what has no line is not cut: it may be
  # unsplittable)
  defp line_starts([], _h), do: [0]

  defp line_starts([{top0, _} | _] = lines, h) do
    {breaks, _} =
      Enum.reduce(lines, {[], top0}, fn {t, b}, {breaks, start} ->
        if b - start > h and t > start, do: {[t | breaks], t}, else: {breaks, start}
      end)

    [0 | breaks |> Enum.reverse() |> Enum.map(&(&1 - top0))]
  end

  defp do_starts(lines, total, h, top0, forced, start, acc) do
    edge = start + h
    force = Enum.find(forced, &(&1 > start))

    cond do
      force != nil and force <= edge ->
        do_starts(lines, total, h, top0, forced, force, [force | acc])

      edge >= total ->
        Enum.reverse(acc)

      true ->
        next =
          case Enum.find(lines, fn {t, b} -> t < edge and b > edge and t > start + top0 end) do
            {t, _} -> t - top0
            nil -> edge
          end

        next = if next <= start, do: edge, else: next
        do_starts(lines, total, h, top0, forced, next, [next | acc])
    end
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
      scroll?: false,
      mta: false,
      mba: false,
      collapsed: false,
      minh: nil,
      hpct: nil,
      fit?: false
    }
  end

  # A child of a flex container: laid out on its own as a block (like an inline-block),
  # with its horizontal margins and its width taken over by the container.
  defp flex_element_item({:element, tag, attrs, kids} = el, c, style) do
    # a collapsed item is a strut: no main size, but it still counts for the cross size
    collapsed? = c["visibility"] == "collapse"

    c =
      if collapsed?,
        do:
          Map.merge(c, %{
            "width" => 0.0,
            "min-width" => 0.0,
            "flex-grow" => "0",
            "flex-shrink" => "0",
            "flex-basis" => "auto",
            "margin-left" => 0.0,
            "margin-right" => 0.0,
            "padding-left" => 0.0,
            "padding-right" => 0.0,
            "border-left-width" => 0.0,
            "border-right-width" => 0.0
          }),
        else: c

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
      # a picture that a column stretches across takes the width that is left (its height
      # follows its ratio)
      restretch: if(tag == "img", do: build, else: nil),
      grow: nonneg(flex_number(c["flex-grow"], 0.0), 0.0),
      shrink: nonneg(flex_number(c["flex-shrink"], 1.0), 1.0),
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
      # a flex item with a `z-index` is a stacking context even when it is not positioned
      zi: if(c["position"] in [nil, "static"] and c["z-index"] != nil, do: z_index(c)),
      # (the height `contain-intrinsic-size` gives is an automatic one: it stretches)
      auto_height?: c["height"] in [nil, :auto] or c["@cis_h"] != nil,
      fit?: c["width"] in [:fit, :minc, :maxc] or fitc?(c["width"]),
      ratio: aspect_ratio(c["aspect-ratio"]),
      ch: num(c["height"]),
      chp: pct_of(c["height"]),
      collapsed: collapsed?,
      minh: num(c["min-height"]),
      scroll?:
        c["overflow-x"] in ~w(hidden scroll auto) or
          (c["overflow-x"] in [nil, "visible"] and c["overflow-y"] in ~w(hidden scroll auto)),
      mta: c["margin-top"] == :auto,
      mba: c["margin-bottom"] == :auto,
      hpct:
        case c["height"] do
          {:pct, f} -> f
          _ -> nil
        end,
      hpad: box.pl + box.pr + bl + br
    }
  end

  # the border-box width a flex item's height and aspect ratio give it
  defp ratio_border_width(%{ratio: {r, kind}, hpad: hpad, vextra: vextra} = it, h) do
    content_h = if it.sizing == :border, do: max(h - vextra, 0), else: h

    if ratio_sizing(it, kind) == :border,
      do: round((content_h + vextra) * r),
      else: round(content_h * r) + hpad
  end

  # the height a flex item has for its aspect ratio: its own, or the cross size of a row
  # container with a height that stretches it
  defp ratio_item_height(%{ch: ch}, _cs) when is_number(ch), do: ch

  # (a percentage of a container height that is known)
  defp ratio_item_height(%{chp: f, ratio: ratio}, %{height: h})
       when ratio != nil and is_number(f) and is_number(h),
       do: f * h

  defp ratio_item_height(%{ratio: ratio, align: own} = it, %{height: h, dir: dir} = cs)
       when ratio != nil and is_number(h) and dir in [:row, :row_reverse] do
    align = if own == "auto", do: cs.align, else: own
    margins = [it.mt, it.mb]

    if not cs.wrap and it.auto_height? and align in ["stretch", "normal"] and
         :auto not in margins and not it.mta and not it.mba,
       do: h - Enum.sum(margins)
  end

  defp ratio_item_height(_, _), do: nil

  defp build_flex_item(tag, _el, c, attrs, kids, style, extra_props) do
    if tag in ~w(img svg) do
      attrs =
        if extra_props == %{},
          do: attrs,
          else: List.keyreplace(attrs, "@computed", 0, {"@computed", Map.merge(c, extra_props)})

      {:element, tag, attrs, kids} |> walk(style, []) |> Enum.reverse()
    else
      own =
        c
        |> resolve_box_pct(containing_width())
        |> Map.drop(~w(width min-width max-width flex-basis))
        |> Map.merge(%{"margin-left" => 0.0, "margin-right" => 0.0})
        # an item the author gave no width is as wide as the flex algorithm makes it
        |> then(&if(c["width"] in [nil, :auto], do: Map.put(&1, "@flex_sized", true), else: &1))
        # a height the author gave is definite for what is inside
        |> then(
          &if(
            is_number(c["height"]) and c["flex-basis"] != "content" and
              flex_number(c["flex-grow"], 0.0) == 0.0,
            do: Map.put(&1, "@definite", true),
            else: &1
          )
        )
        |> Map.merge(extra_props)

      attrs = List.keyreplace(attrs, "@computed", 0, {"@computed", own})

      {:element, tag, attrs, kids}
      |> walk_element(style, [], :inline_inner)
      |> Enum.reverse()
    end
  end

  # (an infinite factor takes all the room, whatever the other factors are)
  defp flex_number("calc(infinity)", _default), do: 1.0e12

  defp flex_number(v, default) when is_binary(v) do
    v = if String.starts_with?(v, "."), do: "0" <> v, else: v

    case Float.parse(v) do
      {n, ""} -> n
      _ -> default
    end
  end

  defp flex_number(_v, default), do: default

  # (a negative factor is not valid: the property keeps its initial value)
  defp nonneg(n, default), do: if(n < 0, do: default, else: n)

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

  # the narrowest room that holds the sizes in `lines` lines (taken in order)
  defp balanced_width(sizes, gap, lines) do
    pseudo = for w <- sizes, do: %{hw: w * 1.0, ml: 0, mr: 0}
    widest = round(Enum.max(sizes, fn -> 0 end))
    total = round(Enum.sum(sizes) + gap * (length(sizes) - 1))

    Enum.find(widest..max(total, widest), total, fn room ->
      length(flex_break(pseudo, gap, room)) <= lines
    end)
  end

  defp flex_widest(st, cs, items, avail) do
    items
    |> Enum.map(fn it ->
      clamp_width(
        flex_base(st, it, avail, cs),
        %{maxw: it.maxw, minw: it.minw, extra: it.extra, mextra: 0},
        avail
      ) + auto_zero(it.ml) + auto_zero(it.mr)
    end)
    |> Enum.max(fn -> 0 end)
    |> round()
  end

  defp flex_natural_width(st, cs, items, avail) do
    # (in a column the basis is a height: the items are as wide as they are)
    row? = cs.dir in [:row, :row_reverse]

    widths =
      for it <- items,
          it = if(row?, do: it, else: %{it | basis: nil}),
          do:
            clamp_width(
              flex_base(st, it, avail, cs),
              %{maxw: it.maxw, minw: it.minw, extra: it.extra, mextra: 0},
              avail
            ) + auto_zero(it.ml) + auto_zero(it.mr)

    widest = round(Enum.max(widths, fn -> 0 end))

    cond do
      # balanced lines: as narrow as holds the items in that many lines
      row? and cs.wrap and Map.get(cs, :balance) == true and (cs.line_count || 0) > 1 ->
        balanced_width(widths, cs.col_gap, cs.line_count)

      row? ->
        round(Enum.sum(widths) + cs.col_gap * (length(items) - 1))

      # a column that wraps is as wide as the columns it breaks into
      cs.wrap and (cs.height || cs.maxh) ->
        items =
          items
          |> Enum.sort_by(& &1.order)
          |> Enum.map(fn it ->
            st
            |> flex_column_item(cs, %{it | fit?: true}, widest)
            |> then(&flex_column_basis(st, &1))
          end)

        cols = flex_column_break(items, cs.height || cs.maxh, round(cs.row_gap))

        widths =
          for col <- cols,
              do: col |> Enum.map(&(&1.x + &1.w + auto_zero(&1.mr))) |> Enum.max(fn -> 0 end)

        round(Enum.sum(widths) + cs.col_gap * (length(cols) - 1))

      true ->
        widest
    end
  end

  defp flex_layout(_st, _cs, [], _avail), do: {[], 0}

  defp flex_layout(st, cs, items, avail) do
    items = Enum.sort_by(items, & &1.order)
    # a row is reversed line by line, once it has been broken into lines
    # (a wrapping column breaks into columns first, and is reversed column by column)
    items =
      if cs.dir == :column_reverse and not (cs.wrap and (cs.height || cs.maxh) != nil),
        do: Enum.reverse(items),
        else: items

    if cs.dir in [:row, :row_reverse],
      do: flex_row(st, cs, items, avail),
      else: flex_column(st, cs, items, avail)
  end

  defp auto_zero(:auto), do: 0
  defp auto_zero(n), do: n

  # the border-box width an item would like
  defp flex_base(st, it, avail, cs) do
    w =
      cond do
        it.basis != nil ->
          len_px(it.basis, avail) + it.extra

        it.width != nil ->
          resolve(it.width, avail) + it.extra

        # a height and an aspect ratio give the width
        Map.get(it, :ratio) != nil and ratio_item_height(it, cs) != nil ->
          ratio_border_width(it, ratio_item_height(it, cs))

        true ->
          shrink_extent(st, it.sub, @unbounded, it.key)
      end

    # (the flex base size is not limited by `max-width`: that only caps the result)
    clamp_width(w, %{maxw: nil, minw: it.minw, extra: it.extra, mextra: 0}, avail)
  end

  defp flex_row(st, cs, items, avail) do
    items =
      Enum.map(items, fn it ->
        # (a ratio and a definite cross size give an item without a width a minimum width)
        rmin =
          if Map.get(it, :ratio) != nil and it.width == nil and ratio_item_height(it, cs) != nil,
            do: ratio_border_width(it, ratio_item_height(it, cs)) * 1.0,
            else: 0.0

        it |> Map.put(:rmin, rmin) |> Map.put(:hw, flex_base(st, it, avail, cs) * 1.0)
      end)

    lines =
      if cs.wrap, do: flex_lines(items, cs, avail), else: [items]

    lines = if cs.dir == :row_reverse, do: Enum.map(lines, &Enum.reverse/1), else: lines
    # `wrap-reverse` stacks the lines upwards: the first one is last
    lines = if cs.wrap_reverse, do: Enum.reverse(lines), else: lines

    if cs.wrap and cs.height do
      flex_wrapped_rows(st, cs, lines, avail)
    else
      {laid, y} =
        Enum.map_reduce(lines, 0, fn line, y ->
          min_cross = if length(lines) == 1, do: cs.height || 0, else: 0

          {line_items, cross} =
            flex_line(st, cs, line, avail, y, min_cross, length(lines) == 1 and not cs.wrap)

          {line_items, y + cross + round(cs.row_gap)}
        end)

      {List.flatten(laid), max(y - round(cs.row_gap), 0)}
    end
  end

  # lines of a wrapping container with a height share what the lines leave over, by
  # `align-content` (the default, `stretch`, makes every line higher)
  defp flex_wrapped_rows(st, cs, lines, avail) do
    n = length(lines)
    gap = round(cs.row_gap)
    laid = Enum.map(lines, &flex_line(st, cs, &1, avail, 0, 0))
    free = cs.height - Enum.sum(Enum.map(laid, &elem(&1, 1))) - gap * (n - 1)

    {laid, start, between} =
      cond do
        free <= 0 and cs.content in ["stretch", "normal"] ->
          {laid, 0.0, 0.0}

        cs.content in ["stretch", "normal"] ->
          extra = free / n

          laid =
            Enum.map(lines, fn line ->
              {_, cross} = flex_line(st, cs, line, avail, 0, 0)
              flex_line(st, cs, line, avail, 0, cross + round(extra))
            end)

          {laid, 0.0, 0.0}

        true ->
          {start, between} = flex_justify(cs.content, false, free * 1.0, n)
          {laid, start, between}
      end

    {placed, y} =
      Enum.map_reduce(laid, round(start), fn {items, cross}, y ->
        {items |> List.flatten() |> Enum.map(&move(&1, 0, y)), y + cross + gap + round(between)}
      end)

    {List.flatten(placed), max(y - gap - round(between), round(cs.height))}
  end

  # wrapping: a new line when the next item no longer fits
  # `flex-wrap` is `nowrap | wrap | wrap-reverse | balance`, or `balance` with `wrap-reverse`
  defp wrap_words(v) when is_binary(v), do: String.split(v)
  defp wrap_words(_), do: []

  defp wraps?(v), do: Enum.any?(wrap_words(v), &(&1 in ["wrap", "wrap-reverse", "balance"]))

  defp flex_line_count(v) do
    case Integer.parse(to_string(v)) do
      {n, ""} when n > 0 -> n
      _ -> nil
    end
  end

  # `flex-wrap: balance`: as many lines as filling them in order would make, but as evenly
  # filled as the narrowest room that still gives that many
  defp flex_lines(items, %{balance: true, col_gap: gap} = cs, avail) do
    sizes = Enum.map(items, &(&1.hw + auto_zero(&1.ml) + auto_zero(&1.mr)))
    lines = flex_break(items, gap, avail)
    balance_lines(items, sizes, gap, avail, length(lines), cs.line_count) || lines
  end

  defp flex_lines(items, cs, avail), do: flex_break(items, cs.col_gap, avail)

  defp flex_break(items, gap, avail) do
    {lines, current, _used} =
      Enum.reduce(items, {[], [], 0.0}, fn it, {lines, cur, used} ->
        # (an item never takes less than no room on a line)
        outer = max(it.hw + auto_zero(it.ml) + auto_zero(it.mr), 0)
        needed = if cur == [], do: outer, else: used + gap + outer

        if cur != [] and needed > avail,
          do: {[Enum.reverse(cur) | lines], [it], outer},
          else: {lines, [it | cur], needed}
      end)

    Enum.reverse(if current == [], do: lines, else: [Enum.reverse(current) | lines])
  end

  defp flex_line(st, cs, line, avail, top, min_cross, single? \\ false) do
    # collapsed items only keep their cross size, they take no part in the main axis
    {struts, line} = Enum.split_with(line, & &1.collapsed)

    min_cross =
      Enum.reduce(struts, min_cross, fn it, m ->
        {_, h, _} = flex_atom(st, it.sub, 0, it.key)
        max(m, h)
      end)

    if line == [],
      do: {[], min_cross},
      else: flex_line_live(st, cs, line, avail, top, min_cross, single?)
  end

  defp flex_line_live(st, cs, line, avail, top, min_cross, single?) do
    n = length(line)
    gaps = cs.col_gap * (n - 1)
    outer = fn it -> it.hw + auto_zero(it.ml) + auto_zero(it.mr) end
    free = avail - Enum.sum(Enum.map(line, outer)) - gaps

    line = flex_resize(st, line, free, avail)

    # (what is left is held to the min and max widths)
    line =
      Enum.map(line, fn it ->
        c = %{maxw: it.maxw, minw: it.minw, extra: it.extra, mextra: 0}
        %{it | hw: clamp_width(it.hw, c, avail) * 1.0}
      end)

    # an explicit flex-basis below the automatic minimum is raised to it
    line =
      Enum.map(line, fn it ->
        if (it.basis != nil or (it.width == nil and Map.get(it, :ratio) != nil)) and
             flex_auto_min?(it) and it.hw < flex_min(st, it, avail),
           do: %{it | hw: flex_min(st, it, avail)},
           else: it
      end)

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

    {start, between} = flex_justify(cs.justify, cs.dir == :row_reverse, free * 1.0, n)

    # lay every item out at its final width, find the height of the line
    # (a width is the distance between the rounded edges, so that fractions do not add up)
    {sized, _} =
      Enum.map_reduce(line, start, fn it, x ->
        ix = x + it.ml
        right = floor(ix + it.hw + 0.5)
        w = max(right - floor(ix + 0.5), 0)
        {items, h, _base} = flex_row_atom(st, cs, it, w)
        next = ix + it.hw + it.mr + cs.col_gap + floor(between + 0.5)
        {Map.merge(it, %{w: w, items: items, h: h}), next}
      end)

    # items aligned on their baselines hang from the lowest one
    sized = baseline_offsets(sized, cs.align)

    # (the only line of a container with a height is as high as the container)
    cross =
      if single? and cs.height != nil and cs.hdef,
        do: round(min_cross),
        else: sized |> Enum.map(&(&1.h + &1.boff)) |> Enum.max() |> max(round(min_cross))

    {placed, _x} =
      Enum.map_reduce(sized, start, fn it, x ->
        it = flex_stretch(st, it, cs.align, cross)

        dy =
          cond do
            # auto margins take the free space, whatever the alignment
            it.mta and it.mba -> round(max(cross - it.h, 0) / 2)
            it.mta -> max(cross - it.h, 0)
            it.mba -> 0
            it.boff > 0 or baseline_item?(it, cs.align) -> it.boff
            true -> flex_offset(flex_align(it, cs.align), cross, it.h)
          end

        ix = x + it.ml
        # (halves go up, so that a box shifted by -2.5 lands where one at 97.5 would be drawn)
        moved = for item <- z_items(it), do: move(item, floor(ix + 0.5), top + dy)
        {moved, ix + it.hw + it.mr + cs.col_gap + floor(between + 0.5)}
      end)

    {placed, cross}
  end

  # grow into free space, or shrink in proportion to the base size
  defp flex_resize(_st, line, free, avail) when free > 0,
    do: flex_grow(line, free, avail, MapSet.new())

  # shrinking stops at the min-content width (`min-width: auto`); an item that reaches it is
  # frozen there and the others shrink further
  defp flex_resize(st, line, free, avail) when free < 0 do
    line = Enum.map(line, &Map.put(&1, :frozen, false))
    # (factors that add up to less than 1 only take that share of the overflow)
    sum = line |> Enum.map(& &1.shrink) |> Enum.sum()
    flex_shrink(st, line, if(sum < 1, do: free * sum, else: free), avail)
  end

  defp flex_resize(_st, line, _free, _avail), do: line

  # items that reach a max-width are frozen there and the others share what is left
  defp flex_grow(line, free, avail, frozen) do
    live = Enum.filter(line, &(&1.grow > 0 and &1.key not in frozen))
    total = live |> Enum.map(& &1.grow) |> Enum.sum()

    if total > 0 do
      # (factors that add up to less than 1 only take that share of the room)
      room = if total < 1, do: free * total, else: free

      clamped =
        Map.new(live, fn it ->
          w = it.hw + room * it.grow / total
          c = %{maxw: it.maxw, minw: it.minw, extra: it.extra, mextra: 0}
          {it.key, {w, clamp_width(w, c, avail) * 1.0}}
        end)

      violating = for it <- live, {w, c} = clamped[it.key], abs(w - c) > 0.001, do: it

      if violating == [] do
        Enum.map(line, fn it ->
          case clamped[it.key] do
            {_, c} -> %{it | hw: c}
            nil -> it
          end
        end)
      else
        {_, taken} =
          Enum.map_reduce(violating, 0.0, fn it, acc ->
            {_, c} = clamped[it.key]
            {nil, acc + c - it.hw}
          end)

        line =
          Enum.map(line, fn it ->
            if it in violating, do: %{it | hw: elem(clamped[it.key], 1)}, else: it
          end)

        frozen = Enum.reduce(violating, frozen, &MapSet.put(&2, &1.key))
        flex_grow(line, free - taken, avail, frozen)
      end
    else
      line
    end
  end

  defp flex_shrink(st, line, free, avail) do
    live = Enum.reject(line, & &1.frozen)
    total = live |> Enum.map(&(&1.shrink * &1.hw)) |> Enum.sum()

    if total > 0 and free < 0 do
      # items whose share would go below their floor are pinned there
      {pinned, _} =
        Enum.split_with(live, fn it ->
          flex_auto_min?(it) and
            it.hw + free * it.shrink * it.hw / total < flex_min(st, it, avail)
        end)

      if pinned == [] do
        tentative =
          Map.new(live, fn it ->
            w = max(it.hw + free * it.shrink * it.hw / total, it.extra + 0.0)
            c = %{maxw: it.maxw, minw: it.minw, extra: it.extra, mextra: 0}
            {it.key, {w, clamp_width(w, c, avail) * 1.0}}
          end)

        # an item that would end up above its max-width is held there, the rest shrink further
        maxed = for it <- live, {w, c} = tentative[it.key], w > c + 0.001, do: it

        if maxed != [] do
          gained = Enum.sum(for it <- maxed, do: it.hw - elem(tentative[it.key], 1))

          line =
            Enum.map(line, fn it ->
              if it in maxed,
                do: %{it | hw: elem(tentative[it.key], 1), frozen: true},
                else: it
            end)

          flex_shrink(st, line, free + gained, avail)
        else
          Enum.map(line, fn it ->
            case tentative[it.key] do
              {_, c} -> %{it | hw: c}
              nil -> it
            end
          end)
        end
      else
        gained = Enum.sum(for it <- pinned, do: max(it.hw - flex_min(st, it, avail), 0.0))

        line =
          Enum.map(line, fn it ->
            if it in pinned,
              do: %{it | hw: flex_min(st, it, avail), frozen: true},
              else: it
          end)

        flex_shrink(st, line, free + gained, avail)
      end
    else
      line
    end
  end

  # `min-width: auto`: the content's min-content width, but not more than a width that is set
  defp flex_auto_min?(it), do: not it.scroll? and (it.minw in [nil, :auto] or kw?(it.minw))

  defp flex_min(st, it, avail) do
    # (an aspect ratio gives a box its width from its height: the content is measured without it)
    content =
      if Map.get(it, :ratio) != nil and it.rebuild != nil,
        do: shrink_extent(st, it.rebuild.(%{"aspect-ratio" => nil}), 1, nil) * 1.0,
        else: shrink_extent(st, it.sub, 1, it.key) * 1.0

    content = if is_number(it.maxw), do: min(content, it.maxw + it.extra * 1.0), else: content

    case it.width do
      width when width != nil ->
        min(content, resolve(width, avail) + it.extra * 1.0)

      _ ->
        max(content, Map.get(it, :rmin, 0.0))
    end
  end

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
      # with no room left the spaced values fall back to the start (`safe center` for the
      # round ones)
      j when j in ["space-between", "space-around", "space-evenly"] and free < 0 -> {0.0, 0.0}
      "space-between" when n > 1 -> {0.0, free / (n - 1)}
      "space-around" -> {free / n / 2, free / n}
      "space-evenly" -> {free / (n + 1), free / (n + 1)}
      _ -> {0.0, 0.0}
    end
  end

  defp baseline_item?(it, container),
    do: flex_align(it, container) in ["baseline", "first baseline", "first-baseline"]

  # the distance each baseline-aligned item is moved down so that their first baselines meet
  defp baseline_offsets(sized, container) do
    bases =
      for it <- sized, baseline_item?(it, container), do: {it, first_baseline(it.items, it.h)}

    case bases do
      [] ->
        Enum.map(sized, &Map.put(&1, :boff, 0))

      _ ->
        deepest = bases |> Enum.map(&elem(&1, 1)) |> Enum.max()
        offsets = Map.new(bases, fn {it, b} -> {it.key, deepest - b} end)

        Enum.map(sized, fn it ->
          Map.put(it, :boff, if(baseline_item?(it, container), do: offsets[it.key], else: 0))
        end)
    end
  end

  # the baseline of Ahem, the test font, is 0.8em down; other text is taken to sit on the bottom of
  # its box
  defp text_ascent(%{family: family, h: h}) when is_binary(family) do
    if String.contains?(String.downcase(family), "ahem"), do: round(h * 0.8), else: h
  end

  defp text_ascent(%{h: h}), do: h

  # the bottom of the first line of text, or the bottom of the box when there is none
  defp first_baseline(items, height) do
    case Enum.filter(items, &(&1.type == :text)) do
      [] ->
        height

      texts ->
        first = Enum.min_by(texts, & &1.y)
        first.y + text_ascent(first)
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

    if stretch? and it.auto_height? and it.rebuild != nil and it.h > cross and cross >= 0 and
         it.mta == false and it.mba == false do
      # an item taller than the line (of a container with a height) is cut down to it
      box_h = cross - it.mt - it.mb
      h = if it.sizing == :border, do: box_h, else: box_h - it.vextra
      sub = it.rebuild.(%{"height" => max(h, 0) * 1.0})
      {items, h2, _} = flex_atom(st, sub, it.w, {it.key, :cut, h})
      %{it | items: items, h: h2}
    else
      flex_stretch_grow(st, it, stretch?, cross)
    end
  end

  defp flex_stretch_grow(st, it, stretch?, cross) do
    if stretch? and it.auto_height? and it.rebuild != nil and it.h < cross do
      box_h = cross - it.mt - it.mb
      min_h = if it.sizing == :border, do: box_h, else: box_h - it.vextra
      sub = it.rebuild.(%{"min-height" => max(min_h, 0) * 1.0})
      {items, h, _} = flex_atom(st, sub, it.w, {it.key, min_h})
      %{it | items: items, h: max(h, cross)}
    else
      flex_stretch_picture(st, it, stretch?, cross)
    end
  end

  # a picture without a height of its own is stretched to the line like any other item
  defp flex_stretch_picture(st, %{restretch: build} = it, true, cross)
       when build != nil and it.rebuild == nil do
    if it.auto_height? and it.width != nil and it.h < cross do
      h = max(cross - it.mt - it.mb - if(it.sizing == :border, do: 0, else: it.vextra), 0)
      {items, h2, _} = flex_atom(st, build.(%{"height" => h * 1.0}), it.w, {it.key, :stretch, h})
      %{it | items: items, h: max(h2, cross)}
    else
      it
    end
  end

  defp flex_stretch_picture(_st, it, _stretch?, _cross), do: it

  defp flex_column(st, cs, items, avail) do
    sized = Enum.map(items, &flex_column_item(st, cs, &1, avail))

    if cs.wrap and (cs.height || cs.maxh) do
      # a wrapping column breaks into columns when the next item no longer fits the height
      sized = Enum.map(sized, &flex_column_basis(st, &1))
      cols = flex_column_lines(sized, cs, cs.height || cs.maxh, round(cs.row_gap))
      cols = flex_column_stretch(st, cs, cols, avail)
      cols = if cs.dir == :column_reverse, do: Enum.map(cols, &Enum.reverse/1), else: cols
      last = length(cols) - 1

      cols =
        cols
        |> Enum.with_index()
        |> Enum.map(fn {col, i} ->
          Enum.map(col, fn it ->
            it = if i == 0 and :is in cs.trim, do: %{it | x: it.x - auto_zero(it.ml)}, else: it
            if i == last and :ie in cs.trim, do: %{it | mr: 0}, else: it
          end)
        end)

      cols = if cs.wrap_reverse != cs.dir_rtl, do: Enum.reverse(cols), else: cols

      {laid, {x_end, tallest}} =
        Enum.map_reduce(cols, {0, 0}, fn col, {x, tallest} ->
          {items, y} = flex_column_place(st, cs, col)
          width = col |> Enum.map(&(&1.x + &1.w + auto_zero(&1.mr))) |> Enum.max()

          {Enum.map(items, &{&1, y}) |> Enum.map(fn {i, y} -> {move(i, x, 0), y} end),
           {x + width + round(cs.col_gap), max(tallest, y)}}
        end)

      # lines that start at the right edge are packed there
      right_shift =
        if cs.dir_rtl and not cs.wrap_reverse,
          do: max(avail - (x_end - round(cs.col_gap)), 0),
          else: 0

      laid = for col <- laid, do: for({item, y} <- col, do: {move(item, right_shift, 0), y})

      # (a column that packs at the end of an automatic height sits at the bottom)
      end? = cs.justify in ["flex-end", "end"]
      start? = cs.justify in ["flex-start", "start", "normal", "left", "right"]

      at_end? =
        cs.height == nil and
          if(cs.dir == :column_reverse, do: start?, else: end?)

      laid =
        for col <- laid do
          for {item, y} <- col, do: if(at_end?, do: move(item, 0, tallest - y), else: item)
        end

      {List.flatten(laid), round(cs.height || tallest)}
    else
      flex_column_place(st, cs, sized)
    end
  end

  # the lines of a wrapping column share the width that is left (`align-content: stretch`), and
  # the items that stretch fill their line
  defp flex_column_stretch(st, cs, cols, avail) do
    outer = fn it -> it.w + auto_zero(it.ml) + auto_zero(it.mr) end
    widths = Enum.map(cols, fn col -> col |> Enum.map(outer) |> Enum.max() end)
    free = avail - Enum.sum(widths) - round(cs.col_gap) * (length(cols) - 1)

    extra =
      if free > 0 and cs.content in ["stretch", "normal"], do: free / length(cols), else: 0

    cols
    |> Enum.zip(widths)
    |> Enum.map(fn {col, width} ->
      cw = width + extra

      Enum.map(col, fn it ->
        if flex_align(it, cs.align) in ["stretch", "normal"] and it.width == nil and
             not it.fit? and it.ml != :auto and it.mr != :auto do
          w = max(round(cw - auto_zero(it.ml) - auto_zero(it.mr)), 1)

          w =
            max(
              round(
                clamp_width(w, %{maxw: it.maxw, minw: it.minw, extra: it.extra, mextra: 0}, avail)
              ),
              1
            )

          {items, h, _} = flex_atom(st, it.sub, w, it.key)
          it = %{it | w: w, items: items, h: max(h, it.h)}
          %{it | x: column_x(cs, it, flex_align(it, cs.align), w, round(cw))}
        else
          %{it | x: column_x(cs, it, flex_align(it, cs.align), it.w, round(cw))}
        end
      end)
    end)
  end

  # `flex-wrap: balance`: the shortest height that still gives as many columns
  defp flex_column_lines(items, %{balance: true} = cs, height, gap) do
    cols = flex_column_break(items, height, gap)
    sizes = Enum.map(items, & &1.h)
    balance_lines(items, sizes, gap, height, length(cols), cs.line_count) || cols
  end

  defp flex_column_lines(items, _cs, height, gap), do: flex_column_break(items, height, gap)

  # `flex-wrap: balance`: the same number of lines as filling them in order makes (or the
  # `flex-line-count` if that is more), with the items spread over them as evenly as can be:
  # the least sum of squared line sizes, the earlier lines the longer on a tie
  defp balance_lines(items, sizes, gap, avail, n, min_count) do
    count = length(items)
    t = min(max(n, min_count || 0), count)

    if t < 2 or count > 300 do
      nil
    else
      pre = Enum.scan(sizes, 0, &(&1 + &2)) |> then(&List.to_tuple([0 | &1]))
      width = fn i, j -> elem(pre, i + j) - elem(pre, i) + gap * (j - 1) end

      {best, _memo} = balance_cut(0, t, count, width, avail, %{})
      best && cut_lines(items, best)
    end
  end

  defp cut_lines(_items, []), do: []

  defp cut_lines(items, [j | rest]) do
    {line, others} = Enum.split(items, j)
    [line | cut_lines(others, rest)]
  end

  # {line lengths from item i on in k lines | nil, memo}; the cost is the sum of the squares
  defp balance_cut(i, 1, count, width, avail, memo) do
    j = count - i
    {if(j == 1 or width.(i, j) <= avail, do: [j]), memo}
  end

  defp balance_cut(i, k, count, width, avail, memo) do
    case memo do
      %{{^i, ^k} => hit} ->
        {hit, memo}

      _ ->
        most = count - i - (k - 1)

        {best, memo} =
          Enum.reduce(most..1//-1, {nil, memo}, fn j, {best, memo} ->
            if j > 1 and width.(i, j) > avail do
              {best, memo}
            else
              {rest, memo} = balance_cut(i + j, k - 1, count, width, avail, memo)

              if rest do
                total = {line_cost([j | rest], i, width), -j}

                if best == nil or total < elem(best, 0),
                  do: {{total, [j | rest]}, memo},
                  else: {best, memo}
              else
                {best, memo}
              end
            end
          end)

        result = best && elem(best, 1)
        {result, Map.put(memo, {i, k}, result)}
    end
  end

  defp line_cost(lens, i, width) do
    {sum, _} =
      Enum.reduce(lens, {0, i}, fn l, {sum, at} ->
        w = width.(at, l)
        {sum + w * w, at + l}
      end)

    sum
  end

  defp flex_column_break(items, height, gap) do
    {cols, cur, _used} =
      Enum.reduce(items, {[], [], 0}, fn it, {cols, cur, used} ->
        needed = if cur == [], do: it.h, else: used + gap + it.h

        if cur != [] and needed > height,
          do: {[Enum.reverse(cur) | cols], [it], it.h},
          else: {cols, [it | cur], needed}
      end)

    Enum.reverse(if cur == [], do: cols, else: [Enum.reverse(cur) | cols])
  end

  # one column of items: they grow or shrink into the height, then are placed by `justify-content`
  defp flex_column_place(st, cs, sized) do
    gaps = round(cs.row_gap) * max(length(sized) - 1, 0)
    outer = & &1.h
    free = if cs.height, do: cs.height - Enum.sum(Enum.map(sized, & &1.base)) - gaps, else: 0

    sized =
      if cs.height,
        do: flex_column_resize(st, sized, free),
        else: Enum.map(sized, &flex_column_basis(st, &1))

    used = Enum.sum(Enum.map(sized, outer)) + gaps

    {start, between} =
      flex_justify(
        column_justify(cs.justify, cs.dir == :column_reverse),
        cs.dir == :column_reverse,
        ((cs.height || 0) - used) * 1.0,
        length(sized)
      )

    start = if cs.height, do: start, else: 0.0

    {laid, y} =
      Enum.map_reduce(sized, round(start), fn it, y ->
        moved = for item <- z_items(it), do: move(item, round(it.x), y)
        {moved, y + it.h + round(cs.row_gap + between)}
      end)

    y = max(y - round(cs.row_gap + between), 0)
    {List.flatten(laid), if(cs.height, do: max(y, round(cs.height)), else: y)}
  end

  # `left` and `right` are the (writing mode) start of a column, whichever way it runs
  defp column_justify(j, reversed?) when j in ["left", "right"],
    do: if(reversed?, do: "flex-end", else: "flex-start")

  defp column_justify(j, _reversed?), do: j

  # where an item sits across a column `avail` wide
  defp column_x(cs, %{ml: ml, mr: mr}, align, w, avail) do
    cond do
      ml == :auto and mr == :auto -> round((avail - w) / 2)
      ml == :auto -> avail - w - mr
      align in ["center"] -> round((avail - w) / 2)
      align in ["flex-end", "end"] -> if cs.rtl, do: ml, else: avail - w - mr
      cs.rtl -> avail - w - mr
      true -> ml
    end
  end

  # an item in a row with a percentage height takes it from the container's definite height
  defp flex_row_atom(st, cs, %{hpct: pct, rebuild: rebuild} = it, w)
       when pct != nil and rebuild != nil and cs.height != nil and cs.hdef do
    sub = rebuild.(%{"height" => pct * cs.height, "aspect-ratio" => nil})
    flex_atom(st, sub, w, {it.key, :hpct})
  end

  # a picture takes the width the row gave it (its height follows its ratio)
  defp flex_row_atom(st, _cs, %{restretch: build} = it, w)
       when build != nil and it.grow > 0 and it.ratio != nil,
       do: flex_atom(st, build.(%{"width" => w - it.extra * 1.0}), w, {it.key, w})

  defp flex_row_atom(st, _cs, it, w), do: flex_atom(st, it.sub, w, it.key)

  defp flex_column_item(st, cs, it, avail) do
    ml = it.ml
    mr = it.mr
    room = avail - auto_zero(ml) - auto_zero(mr)
    align = flex_align(it, cs.align)
    # (in a wrapping column the lines are as wide as their items, and are stretched later)
    wrapped? = cs.wrap and (cs.height || cs.maxh) != nil

    w =
      cond do
        it.width != nil ->
          resolve(it.width, avail) + it.extra

        align in ["stretch", "normal"] and not it.fit? and not wrapped? ->
          room

        true ->
          max_c = shrink_extent(st, it.sub, @unbounded, it.key)
          if max_c <= room, do: max_c, else: max(room, min_extent(st, it.sub, it.key))
      end

    w = clamp_width(w, %{maxw: it.maxw, minw: it.minw, extra: it.extra, mextra: 0}, avail)
    w = max(round(w), 1)

    it =
      if Map.get(it, :restretch) && it.width == nil && align in ["stretch", "normal"] &&
           not it.fit? && not wrapped? && it.auto_height? do
        %{it | sub: it.restretch.(%{"width" => w - it.extra * 1.0})}
      else
        it
      end

    {items, h, _} = flex_atom(st, it.sub, w, it.key)

    x = column_x(cs, it, align, w, avail)

    # an item starts from its `flex-basis` when it has one (a size of the box, margins apart)
    base =
      case it.basis do
        nil when it.hpct != nil and cs.height != nil and cs.hdef ->
          # a percentage height resolves against the container's definite height
          size = it.hpct * cs.height + if(it.sizing == :border, do: 0, else: it.vextra)
          max(size, it.vextra) + auto_zero(it.mt) + auto_zero(it.mb)

        nil ->
          h

        basis ->
          size = len_px(basis, cs.height || 0) + if(it.sizing == :border, do: 0, else: it.vextra)
          max(size, it.vextra) + auto_zero(it.mt) + auto_zero(it.mb)
      end

    Map.merge(it, %{w: w, items: items, h: h, x: x, base: base})
  end

  # in a column with a height of its own the items grow into what is left, or shrink in
  # proportion to their heights (down to what their content needs)
  defp flex_column_resize(st, sized, free) when free > 0 do
    total = sized |> Enum.map(& &1.grow) |> Enum.sum()

    Enum.map(sized, fn it ->
      share = if total > 0, do: free * it.grow / total, else: 0
      flex_column_height(st, it, it.base + share, true)
    end)
  end

  defp flex_column_resize(st, sized, free) when free < 0 do
    frozen = flex_shrink_frozen(sized, free, MapSet.new())
    # items held at their minimum no longer share the shrinking
    free = free + Enum.sum(for it <- sized, it.key in frozen, do: it.base - it.h)
    total = for(it <- sized, it.key not in frozen, do: it.shrink * it.base) |> Enum.sum()

    if total > 0 do
      Enum.map(sized, fn it ->
        target =
          if it.key in frozen,
            do: it.h,
            else: it.base + free * it.shrink * it.base / total

        flex_column_height(st, it, if(it.shrink > 0, do: target, else: it.base), true)
      end)
    else
      sized
    end
  end

  defp flex_column_resize(st, sized, _free),
    do: Enum.map(sized, &flex_column_height(st, &1, &1.base, true))

  # the items whose share of a shrink goes below what their content needs
  defp flex_shrink_frozen(sized, free, frozen) do
    open = Enum.reject(sized, &(&1.key in frozen))
    give = Enum.sum(for it <- sized, it.key in frozen, do: it.base - it.h)
    total = Enum.sum(for it <- open, do: it.shrink * it.base)

    more =
      if total > 0 do
        for it <- open,
            it.shrink > 0 and it.auto_height? and it.h > 0 and it.minh == nil,
            it.base + (free + give) * it.shrink * it.base / total < it.h,
            do: it.key
      else
        []
      end

    if more == [],
      do: frozen,
      else: flex_shrink_frozen(sized, free, MapSet.union(frozen, MapSet.new(more)))
  end

  # in a column of automatic height an item with a `flex-basis` is as high as that, or as its
  # content needs
  defp flex_column_basis(st, %{basis: basis, rebuild: rebuild} = it)
       when basis != nil and rebuild != nil do
    {_, floor, _} =
      flex_atom(st, rebuild.(%{"height" => nil, "min-height" => nil}), it.w, {it.key, :min})

    # (an item that cannot flex has a definite size when its container has none)
    # (a `min-height` of the item is not part of the floor above: it is added back here)
    floor =
      if it.minh,
        do: max(floor, it.minh + if(it.sizing == :border, do: 0, else: it.vextra)),
        else: floor

    flex_column_height(st, it, max(it.base, floor), it.grow == 0 and it.shrink == 0)
  end

  defp flex_column_basis(_st, it), do: it

  defp flex_column_height(st, it, target, definite?) do
    # an item does not go below what its content needs (`min-height: auto`)
    target =
      if it.rebuild != nil and target < it.h - 0.5 do
        floor =
          if it.minh do
            # a `min-height` of its own replaces the automatic minimum
            it.minh + if(it.sizing == :border, do: 0, else: it.vextra)
          else
            {_, floor, _} =
              flex_atom(
                st,
                it.rebuild.(%{"height" => nil, "min-height" => nil}),
                it.w,
                {it.key, :min}
              )

            floor
          end

        # (a size the item is given caps the automatic minimum)
        floor =
          cond do
            it.minh != nil or it.basis != nil ->
              floor

            is_number(it.ch) ->
              min(floor, it.ch + if(it.sizing == :border, do: 0, else: it.vextra))

            it.hpct != nil ->
              min(floor, it.base)

            true ->
              floor
          end

        max(target, min(floor, it.h))
      else
        target
      end

    if it.rebuild != nil and (it.base != it.h or abs(target - it.h) >= 0.5) do
      # the height of an item includes its margins
      box = target - auto_zero(it.mt) - auto_zero(it.mb)
      content = if it.sizing == :border, do: box, else: box - it.vextra
      props = %{"height" => max(content, 0) * 1.0, "aspect-ratio" => nil}
      props = if definite?, do: Map.put(props, "@definite", true), else: props
      # (an item with a ratio and no width of its own is as wide as its final height makes it)
      w =
        if Map.get(it, :ratio) != nil and it.width == nil,
          do: ratio_border_width(it, max(content, 0)) * 1.0,
          else: it.w

      sub = it.rebuild.(props)
      {items, h, _} = flex_atom(st, sub, w, {it.key, round(target)})
      %{it | items: items, h: max(h, 0), w: w}
    else
      it
    end
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
    %{
      sx: round(sx),
      sy: round(sy),
      collapse?: collapse?,
      sized?: c["@sized"] == true,
      tedges: c["@tedges"],
      h: table_height(c),
      fixed?: fixed_table?(c),
      fixed_css?: c["table-layout"] == "fixed"
    }
  end

  # the height a table is given, which `min-height` raises
  defp table_height(c) do
    case {num(c["height"]), num(c["min-height"])} do
      {nil, nil} -> nil
      {h, min} -> max(h || 0, min || 0)
    end
  end

  @cell_tags ~w(td th)
  @group_tags ~w(thead tbody tfoot)

  # the caption and the rows of a table, in display order: header rows, body rows, footer rows
  defp table_model(kids, style) do
    kids = kids |> flatten_contents() |> anonymous_rows()

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
          if group_kind(tag) == wanted, do: group_rows(kids, style, row_bg(c), c), else: []

        _ ->
          []
      end)
    end

    %{
      caption: caption,
      rows: rows_of.(:head) ++ rows_of.(:body) ++ rows_of.(:foot),
      cols: table_columns_bg(parts)
    }
  end

  # white space between two kids that `loose?` accepts is dropped, so they chunk together
  defp drop_joining_blanks(kids, loose?) do
    blank? = fn
      {:text, t} -> String.trim(t) == ""
      _ -> false
    end

    kids
    |> Enum.chunk_by(blank?)
    |> then(fn chunks ->
      chunks
      |> Enum.with_index()
      |> Enum.flat_map(fn {chunk, i} ->
        before = if i > 0, do: chunks |> Enum.at(i - 1) |> List.last()
        after_ = Enum.at(chunks, i + 1)

        if blank?.(hd(chunk)) and before != nil and after_ != nil and loose?.(before) and
             loose?.(hd(after_)),
           do: [],
           else: chunk
      end)
    end)
  end

  # an element with `display: contents` makes no box: its children take its place
  defp flatten_contents(kids) do
    Enum.flat_map(kids, fn
      {:element, tag, attrs, ekids} = el when tag not in @skip ->
        if computed(attrs)["display"] == "contents",
          do: flatten_contents(ekids),
          else: [el]

      other ->
        [other]
    end)
  end

  # content of a table that is not a row, group, caption or column sits in an anonymous row
  defp anonymous_rows(kids) do
    neutral? = fn
      {:element, tag, _, _} when tag in @skip -> true
      {:text, t} -> String.trim(t) == ""
      {:element, tag, attrs, _} -> kind_of_table_part(tag, computed(attrs)) != :other
      _ -> true
    end

    # (white space between two pieces of loose content stays in the one anonymous row)
    kids = drop_joining_blanks(kids, fn kid -> not neutral?.(kid) end)

    if Enum.all?(kids, neutral?) do
      kids
    else
      kids
      |> Enum.chunk_by(neutral?)
      |> Enum.flat_map(fn chunk ->
        if neutral?.(hd(chunk)),
          do: chunk,
          else: [{:element, "tr", [{"@computed", %{"display" => "table-row"}}], chunk}]
      end)
    end
  end

  # the background of each column, from `col` and `colgroup` (a group's under its columns')
  defp table_columns_bg(parts) do
    span = fn attrs ->
      with v when is_binary(v) <- List.keyfind(attrs, "span", 0) |> then(&(&1 && elem(&1, 1))),
           {n, _} when n >= 1 <- Integer.parse(v) do
        min(n, 1000)
      else
        _ -> 1
      end
    end

    wid = fn c, inherited -> if is_number(c["width"]), do: c["width"], else: inherited end

    capped = fn w, c ->
      if is_number(w) and is_number(c["max-width"]), do: min(w, c["max-width"]), else: w
    end

    col = fn {:element, _, attrs, _}, c, inherited ->
      entry = %{
        bg: row_bg(c) || inherited.bg,
        w: capped.(wid.(c, inherited.w), c),
        mw: num(c["min-width"]) || Map.get(inherited, :mw),
        edges: edges_of(c),
        imgs: Enum.reject([Map.get(inherited, :img), bg_pictures(c)], &is_nil/1)
      }

      List.duplicate(entry, span.(attrs))
    end

    Enum.flat_map(parts, fn
      {:col, el, _tag, c, _kids} ->
        el |> col.(c, %{bg: nil, w: nil}) |> outer_sides()

      {:colgroup, {:element, _, attrs, _}, _tag, c, kids} ->
        gimg = bg_pictures(c)

        inner =
          for {:element, ctag, cattrs, _} = cel <- kids,
              ctag not in @skip,
              cc = computed(cattrs),
              ctag == "col" or cc["display"] == "table-column",
              entry <-
                col.(cel, cc, %{
                  bg: row_bg(c),
                  w: wid.(c, nil),
                  mw: num(c["min-width"]),
                  img: gimg
                }),
              do: entry

        cols =
          if inner == [],
            do:
              List.duplicate(
                %{
                  bg: row_bg(c),
                  w: wid.(c, nil),
                  mw: num(c["min-width"]),
                  edges: edges_of(c),
                  imgs: Enum.reject([gimg], &is_nil/1)
                },
                span.(attrs)
              ),
            else: inner

        group = edges_of(c)

        cols
        |> Enum.with_index()
        |> Enum.map(fn {col, i} ->
          edges = col.edges

          edges = Map.put(edges, :top, best_edge(edges.top, group.top))
          edges = Map.put(edges, :bottom, best_edge(edges.bottom, group.bottom))

          edges =
            if i == 0, do: Map.put(edges, :left, best_edge(edges.left, group.left)), else: edges

          edges =
            if i == length(cols) - 1,
              do: Map.put(edges, :right, best_edge(edges.right, group.right)),
              else: edges

          %{col | edges: edges}
        end)

      _ ->
        []
    end)
  end

  # with collapsed borders the borders of a column (group) join those of the cells at the edges
  defp column_edges(placed, cols, nrows) do
    Enum.map(placed, fn p ->
      spanned = cols |> Enum.slice(p.col, p.cell.colspan) |> Enum.map(&Map.get(&1, :edges))
      best = fn side -> Enum.reduce(spanned, nil, &best_edge(&2, &1 && Map.get(&1, side))) end
      first = Enum.at(cols, p.col)
      last = Enum.at(cols, p.col + p.cell.colspan - 1)

      redges =
        p.redges
        |> Map.put(:left, best_edge(p.redges.left, first && first.edges[:left]))
        |> Map.put(:right, best_edge(p.redges.right, last && last.edges[:right]))

      # (between two columns the border of both is the one the cell on the right draws)
      between =
        if p.col > 0 do
          before = (Enum.at(cols, p.col - 1) || %{})[:edges][:right]
          before = before && %{before | props: left_props(before.props)}
          best_edge(first && first.edges[:left], before)
        end

      %{
        p
        | redges: redges,
          between: between,
          top_edge: if(p.row == 0, do: best_edge(p.top_edge, best.(:top)), else: p.top_edge),
          bottom_edge:
            if(p.row + min(p.cell.rowspan, nrows - p.row) >= nrows,
              do: best_edge(p.bottom_edge, best.(:bottom)),
              else: p.bottom_edge
            )
      }
    end)
  end

  # the border of the table itself is the weakest of those at its edge
  defp table_edges(placed, t, ncols, nrows) do
    Enum.map(placed, fn p ->
      last_col? = p.col + p.cell.colspan >= ncols
      last_row? = p.row + min(p.cell.rowspan, nrows - p.row) >= nrows
      redges = p.redges

      redges =
        if p.col == 0, do: Map.put(redges, :left, best_edge(redges.left, t.left)), else: redges

      redges =
        if last_col?, do: Map.put(redges, :right, best_edge(redges.right, t.right)), else: redges

      %{
        p
        | redges: redges,
          top_edge: if(p.row == 0, do: best_edge(p.top_edge, t.top), else: p.top_edge),
          bottom_edge: if(last_row?, do: best_edge(p.bottom_edge, t.bottom), else: p.bottom_edge)
      }
    end)
  end

  # of the columns of one `col` only the first keeps its left border and the last its right one
  defp outer_sides(cols) do
    last = length(cols) - 1

    cols
    |> Enum.with_index()
    |> Enum.map(fn {col, i} ->
      edges = if i == 0, do: col.edges, else: Map.put(col.edges, :left, nil)
      edges = if i == last, do: edges, else: Map.put(edges, :right, nil)
      %{col | edges: edges}
    end)
  end

  defp kind_of_table_part(tag, c) do
    cond do
      tag == "caption" or c["display"] == "table-caption" ->
        :caption

      tag == "tr" or c["display"] == "table-row" ->
        :row

      tag == "colgroup" or c["display"] == "table-column-group" ->
        :colgroup

      tag == "col" or c["display"] == "table-column" ->
        :col

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

  defp group_rows(kids, style, bg, gc) do
    rows =
      for {:element, tag, attrs, ekids} = el <- loose_cells(kids),
          tag not in @skip,
          c = computed(attrs),
          tag == "tr" or c["display"] == "table-row",
          do: table_row(el, c, ekids, style, bg, num(gc["height"]))

    # with collapsed borders the group's own borders are those of the rows at its edges
    last = length(rows) - 1
    group = edges_of(gc)
    gimg = bg_pictures(gc)

    rows
    |> Enum.with_index()
    |> Enum.map(fn {row, i} ->
      edges = row.edges
      edges = if i == 0, do: Map.put(edges, :top, best_edge(edges.top, group.top)), else: edges

      edges =
        if i == last,
          do: Map.put(edges, :bottom, best_edge(edges.bottom, group.bottom)),
          else: edges

      edges =
        edges
        |> Map.put(:left, best_edge(edges.left, group.left))
        |> Map.put(:right, best_edge(edges.right, group.right))

      %{row | edges: edges, gimg: gimg, shift: add_shift(row.shift, rel_shift(gc))}
    end)
  end

  # cells straight in a row group sit in an anonymous row
  defp loose_cells(kids) do
    cell? = fn
      {:element, tag, attrs, _} -> tag in @cell_tags or computed(attrs)["display"] == "table-cell"
      _ -> false
    end

    kids = kids |> flatten_contents() |> drop_joining_blanks(cell?)

    if Enum.any?(kids, cell?) do
      kids
      |> Enum.chunk_while(
        [],
        fn kid, acc ->
          cond do
            cell?.(kid) -> {:cont, [kid | acc]}
            acc == [] -> {:cont, kid, []}
            true -> {:cont, [anonymous_row(Enum.reverse(acc)), kid], []}
          end
        end,
        fn
          [] -> {:cont, []}
          acc -> {:cont, [anonymous_row(Enum.reverse(acc))], []}
        end
      )
      |> List.flatten()
    else
      kids
    end
  end

  defp anonymous_row(cells),
    do: {:element, "div", [{"@computed", %{"display" => "table-row"}}], cells}

  defp paint_above(items, seq), do: Enum.map(items, &Map.merge(&1, %{over: true, pz: seq}))

  # `position: relative` on a part of a table moves what it holds
  defp rel_shift(c, base \\ nil) do
    if c["position"] == "relative" do
      num = fn
        v when is_number(v) -> round(v)
        {:pct, f} when is_number(base) -> round(f * base)
        _ -> nil
      end

      {num.(c["left"]) || -(num.(c["right"]) || 0), num.(c["top"]) || -(num.(c["bottom"]) || 0)}
    else
      {0, 0}
    end
  end

  defp add_shift({a, b}, {c, d}), do: {a + c, b + d}

  # the properties of a right border as those of the left border it is on the next cell
  defp left_props(props),
    do: Map.new(props, fn {k, v} -> {String.replace(k, "border-right", "border-left"), v} end)

  # the borders an element (a row or a row group) brings to a table with collapsed borders
  defp edges_of(c) do
    for side <- ~w(top bottom left right), into: %{} do
      w = border_w(c, side)

      edge =
        if c["border-#{side}-style"] == "hidden" do
          # (`hidden` removes every border at that edge, whatever their width)
          %{
            w: 0,
            hidden: true,
            props: %{
              "border-#{side}-width" => 0.0,
              "border-#{side}-style" => "hidden"
            }
          }
        else
          if w > 0 do
            %{
              w: w,
              props: %{
                "border-#{side}-width" => w * 1.0,
                "border-#{side}-style" => c["border-#{side}-style"],
                "border-#{side}-color" => c["border-#{side}-color"]
              }
            }
          end
        end

      {String.to_atom(side), edge}
    end
  end

  # the wider border wins, the first of two equals
  defp best_edge(nil, b), do: b
  defp best_edge(a, nil), do: a
  defp best_edge(%{hidden: true} = a, _), do: a
  defp best_edge(_, %{hidden: true} = b), do: b
  defp best_edge(a, b), do: if(b.w > a.w, do: b, else: a)

  defp row_bg(c), do: if(color?(c["background-color"]), do: c["background-color"])

  # a row's background shows behind its cells; a row group's behind its rows
  defp table_row({:element, _tag, _attrs, _}, c, kids, style, group_bg, parent_h \\ nil) do
    cells =
      for {:element, tag, attrs, _} = el <- anonymous_cells(kids, c),
          tag not in @skip,
          cc = computed(attrs),
          tag in @cell_tags or cc["display"] == "table-cell",
          do: table_cell(el, cc, style)

    %{
      cells: cells,
      valign: valign_of(c["vertical-align"]),
      bg: row_bg(c) || group_bg,
      h: num(c["height"]),
      bgimg: bg_pictures(c),
      gimg: nil,
      edges: edges_of(c),
      shift: rel_shift(c, parent_h)
    }
  end

  # the background pictures of a row, row group or column, painted over the cells it holds
  defp bg_pictures(c) do
    with spec when spec != nil <- bgimg_spec(c),
         do: %{spec: spec, color: c["color"] || {0, 0, 0}, ref: make_ref()}
  end

  # whatever else a row holds sits in an anonymous cell
  defp anonymous_cells(kids, row) do
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
        else: [{:element, "div", [{"@computed", anonymous_cell_style(row)}], chunk}]
    end)
  end

  # (the cell takes what the row passes down: its colour, font and so on)
  defp anonymous_cell_style(row),
    do: row |> Map.take(Browser.Style.inherited_props()) |> Map.put("display", "table-cell")

  defp table_caption({:element, tag, attrs, kids}, style) do
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
      minw: num(c["min-width"]),
      # the height of a cell is that of its content (box-sizing decides), the row is as high as
      # the box around it
      minh:
        with h when h != nil <- num(c["height"]) || num(c["min-height"]) do
          if border_box?, do: h, else: h + box.pt + box.pb + bt + bb
        end,
      valign: valign_of(c["vertical-align"]),
      extra: if(border_box?, do: 0, else: box.pl + box.pr + bl + br),
      pt: box.pt,
      # nothing is painted for the cell itself, so its height does not show
      plain:
        box.bg == nil and box.bgimg == nil and box.shadows == [] and box.bw == {0, 0, 0, 0} and
          xform_spec(c) == nil and not clips?(c) and
          c["position"] not in ["relative", "sticky"],
      vextra: box.pt + box.pb + bt + bb,
      bw: box.bw,
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

  defp fixed_table?(c) do
    c["table-layout"] == "fixed" and c["width"] not in [nil, :auto]
  end

  # the pictures of the columns a cell spans, each placed against the column (group) and clipped
  # to the part of the cell in it
  defp column_pictures(_st, _p, _cell, [], _geo), do: []

  defp column_pictures(st, p, {dx, dy, full_h}, cols, {xs, widths, ys, row_heights, spans}) do
    top = Enum.at(ys, 0)
    height = Enum.at(ys, length(row_heights) - 1) + List.last(row_heights) - top

    for i <- p.col..(p.col + p.cell.colspan - 1)//1,
        %{imgs: imgs} <- [Enum.at(cols, i)],
        img <- imgs,
        {first, last} = Map.fetch!(spans, img.ref),
        w = Enum.at(widths, i, 0),
        w > 0 and full_h > 0 do
      left = Enum.at(xs, first)
      width = Enum.at(xs, last) + Enum.at(widths, last) - left
      area = {left - dx, top - dy, width, height}
      clip = {Enum.at(xs, i) - dx, 0, w, full_h}

      layers =
        Backgrounds.paint_layers(
          img.spec,
          area,
          clip,
          st.images,
          color4(img.color),
          viewport_area()
        )

      {clip, layers}
    end
    |> Enum.reject(fn {_, layers} -> layers == [] end)
    |> Enum.map(fn {{x, y, w, h}, layers} ->
      %{type: :bgimage, layers: layers, x: x, y: y, w: w, h: h, radius: nil}
    end)
  end

  # the pictures of a row group and a row, in the coordinates of the cell they are painted for:
  # placed against the box of the row (group), clipped to the cell
  defp row_pictures(st, p, {dx, dy, full_h}, {table_w, sx, ys, row_heights, groups}) do
    box = fn
      %{ref: ref} when is_map_key(groups, ref) ->
        {first, last} = Map.fetch!(groups, ref)
        top = Enum.at(ys, first)
        {sx, top, table_w - 2 * sx, Enum.at(ys, last) + Enum.at(row_heights, last) - top}

      _ ->
        {sx, Enum.at(ys, p.row), table_w - 2 * sx, Enum.at(row_heights, p.row)}
    end

    for img <- [p.grp_img, p.row_img], img != nil, p.w > 0, full_h > 0 do
      {bx, by, bw, bh} = box.(img)
      area = {bx - dx, by - dy, bw, bh}

      layers =
        Backgrounds.paint_layers(
          img.spec,
          area,
          {0, 0, p.w, full_h},
          st.images,
          color4(img.color),
          viewport_area()
        )

      %{type: :bgimage, layers: layers, x: 0, y: 0, w: p.w, h: full_h, radius: nil}
    end
    |> Enum.reject(&(&1.layers == []))
  end

  # -> {items, table width, height}
  defp table_layout(st, ts, model, avail) do
    placed = table_grid(model.rows)
    ncols = placed |> Enum.map(&(&1.col + &1.cell.colspan)) |> Enum.max(fn -> 0 end)
    nrows = length(model.rows)
    placed = if ts.collapse?, do: column_edges(placed, model.cols, nrows), else: placed
    placed = if ts.tedges, do: table_edges(placed, ts.tedges, ncols, nrows), else: placed
    sx = ts.sx
    sy = ts.sy

    if ncols == 0 do
      table_caption_only(st, model, avail)
    else
      natural? = avail > @unbounded / 2
      # a width given to a table with collapsed borders is that of its columns: half of the
      # outermost borders is added to it
      avail =
        if ts.collapse? and ts.sized? and not natural?,
          do: avail + outer_borders(placed, ncols),
          else: avail

      {mins, maxs, pcts} =
        st |> table_columns(placed, ncols, nrows, ts.collapse?) |> column_widths(model.cols)

      # `table-layout: fixed`: the content decides nothing, columns without a width share what is left
      {mins, maxs} =
        if ts.fixed? and not natural?,
          do: {Enum.map(mins, fn _ -> 0 end), Enum.map(maxs, fn _ -> 0 end)},
          else: {mins, maxs}

      exact =
        for i <- 0..(ncols - 1)//1,
            do: with(%{w: w} when is_number(w) <- Enum.at(model.cols, i), do: round(w))

      spacing = sx * (ncols + 1)

      widths =
        if natural? do
          maxs
        else
          table_widths(mins, maxs, pcts, max(avail - spacing, 0), exact)
        end

      # (a caption is as wide as the table, so the table is at least as wide as its content wants)
      {widths, table_w} =
        if natural? do
          cap = if model.caption, do: shrink_extent(st, model.caption, @unbounded, nil), else: 0
          w = Enum.sum(widths) + spacing

          if cap > w,
            do: {List.update_at(widths, ncols - 1, &(&1 + cap - w)), cap},
            else: {widths, w}
        else
          # (a table is never narrower than its columns need, whatever room there is)
          {widths, if(ts.fixed_css?, do: avail, else: max(avail, Enum.sum(widths) + spacing))}
        end

      xs = column_positions(widths, sx)
      span_w = fn col, span -> Enum.sum(Enum.slice(widths, col, span)) + sx * (span - 1) end

      # first pass: the height every cell wants at the width of its columns
      sized =
        Enum.map(placed, fn p ->
          w = max(span_w.(p.col, p.cell.colspan), 0)
          {eprops, vdelta} = if ts.collapse?, do: edge_props(p, ncols, nrows), else: {%{}, 0}
          sub = if eprops == %{}, do: p.cell.sub, else: p.cell.build.(eprops)
          {items0, h, _} = layout_atom(st, sub, w, if(eprops == %{}, do: p.cell.key))
          Map.merge(p, %{w: w, h0: h, items0: items0, eprops: eprops, vdelta: vdelta})
        end)

      row_heights = table_row_heights(sized, nrows, sy)
      # a row is at least as high as its `height`
      row_heights =
        model.rows
        |> Enum.zip(row_heights)
        |> Enum.map(fn {row, h} -> max(h, round(row.h || 0)) end)

      {caption_items, caption_h} = table_caption_items(st, model.caption, table_w)
      top = caption_h
      row_heights = grow_rows(row_heights, ts.h, top + sy + sy * nrows)
      ys = row_positions(row_heights, sy, top)

      # the columns each column (group) with a background picture spans
      spans =
        model.cols
        |> Enum.with_index()
        |> Enum.reduce(%{}, fn {col, i}, acc ->
          Enum.reduce(Map.get(col, :imgs, []), acc, fn %{ref: ref}, acc ->
            Map.update(acc, ref, {i, i}, fn {first, _} -> {first, i} end)
          end)
        end)

      # the rows each row group with a background picture spans
      groups =
        model.rows
        |> Enum.with_index()
        |> Enum.reduce(%{}, fn
          {%{gimg: %{ref: ref}}, r}, acc ->
            Map.update(acc, ref, {r, r}, fn {first, _} -> {first, r} end)

          _, acc ->
            acc
        end)

      cells =
        for p <- sized do
          rs = min(p.cell.rowspan, nrows - p.row)
          full_h = Enum.sum(Enum.slice(row_heights, p.row, rs)) + sy * (rs - 1)
          valign = p.cell.valign || "top"

          extra_top =
            case valign do
              "middle" -> max(div(full_h - p.h0, 2), 0)
              "bottom" -> max(full_h - p.h0, 0)
              _ -> 0
            end

          min_h =
            if p.cell.sizing == :border,
              do: full_h,
              else: max(full_h - p.cell.vextra - p.vdelta - extra_top, 0)

          props =
            Map.merge(p.eprops, %{
              "padding-top" => (p.cell.pt + extra_top) * 1.0,
              "min-height" => min_h * 1.0
            })

          props = if ts.collapse?, do: collapse_borders(props, p, ncols, nrows), else: props
          # a plain cell looks the same at its final height, just lower when it is centred or
          # at the bottom
          items =
            if p.cell.plain and not ts.collapse? and p.eprops == %{} do
              if extra_top == 0, do: p.items0, else: Enum.map(p.items0, &move(&1, 0, extra_top))
            else
              {items, _h, _} = layout_atom(st, p.cell.build.(props), p.w)
              items
            end

          {sdx, sdy} = p.shift
          dx = Enum.at(xs, p.col) + sdx
          dy = Enum.at(ys, p.row) + sdy
          behind = column_backgrounds(model.cols, widths, sx, p, full_h)
          behind = behind ++ if(p.row_bg, do: [rect(0, 0, p.w, full_h, p.row_bg)], else: [])

          behind =
            behind ++
              column_pictures(
                st,
                p,
                {dx, dy, full_h},
                model.cols,
                {xs, widths, ys, row_heights, spans}
              ) ++
              row_pictures(st, p, {dx, dy, full_h}, {table_w, sx, ys, row_heights, groups})

          moved = for item <- behind ++ items, do: move(item, dx, dy)

          # what is moved is positioned: it paints above what is not
          if p.shift == {0, 0},
            do: moved,
            else: paint_above(moved, :erlang.unique_integer([:monotonic]))
        end

      height = top + sy + Enum.sum(row_heights) + sy * nrows
      {List.flatten([caption_items | cells]), table_w, height}
    end
  end

  # a `width` on a `col` or `colgroup` is the least its column can be, and what it wants
  defp column_widths({mins, maxs, pcts}, cols) do
    set = fn list ->
      list
      |> Enum.with_index()
      |> Enum.map(fn {v, i} ->
        col = Enum.at(cols, i) || %{}
        v = if is_number(col[:w]), do: max(v, round(col.w)), else: v
        if is_number(col[:mw]), do: max(v, round(col.mw)), else: v
      end)
    end

    {set.(mins), set.(maxs), pcts}
  end

  # the backgrounds of the columns a cell lies in, behind the row's
  defp column_backgrounds([], _widths, _sx, _p, _h), do: []

  defp column_backgrounds(cols, widths, sx, p, h) do
    {items, _x} =
      Enum.reduce(p.col..(p.col + p.cell.colspan - 1)//1, {[], 0}, fn i, {acc, x} ->
        w = Enum.at(widths, i, 0)
        bg = with %{bg: bg} <- Enum.at(cols, i), do: bg
        acc = if bg && w > 0, do: [rect(x, 0, w, h, bg) | acc], else: acc
        {acc, x + w + sx}
      end)

    Enum.reverse(items)
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

  # the widths of the borders at the left and right edges of a table with collapsed borders
  defp outer_borders(placed, ncols) do
    side = fn edge, own -> max(if(edge, do: edge.w, else: 0), own) end

    left = for p <- placed, p.col == 0, do: side.(p.redges.left, elem(p.cell.bw, 3))

    right =
      for p <- placed,
          p.col + p.cell.colspan >= ncols,
          do: side.(p.redges.right, elem(p.cell.bw, 1))

    div(Enum.max(left, fn -> 0 end) + Enum.max(right, fn -> 0 end), 2)
  end

  # the borders a row or a row group puts on a cell at its edge, where they are wider than the
  # cell's own -> {properties, the height they add}
  defp edge_props(p, ncols, nrows) do
    {tbw, rbw, bbw, lbw} = p.cell.bw
    last_col? = p.col + p.cell.colspan >= ncols
    last_row? = p.row + min(p.cell.rowspan, nrows - p.row) >= nrows

    candidates = [
      {p.top_edge, tbw, :v},
      {if(last_row?, do: p.bottom_edge), bbw, :v},
      {if(p.col == 0, do: p.redges.left, else: p.between), lbw, :h},
      {if(last_col?, do: p.redges.right), rbw, :h}
    ]

    Enum.reduce(candidates, {%{}, 0}, fn
      {nil, _, _}, acc ->
        acc

      {%{hidden: true} = e, own, axis}, {props, v} ->
        {Map.merge(props, e.props), if(axis == :v, do: v - own, else: v)}

      {e, own, _}, acc when e.w <= own ->
        acc

      {e, own, axis}, {props, v} ->
        {Map.merge(props, e.props), if(axis == :v, do: v + e.w - own, else: v)}
    end)
  end

  # the width the borders at the sides of a cell add to its own (or take away, when hidden)
  defp edge_hdelta(p, ncols) do
    {_, rbw, _, lbw} = p.cell.bw
    last_col? = p.col + p.cell.colspan >= ncols
    left = if p.col == 0, do: p.redges.left, else: p.between
    right = if last_col?, do: p.redges.right

    delta = fn
      nil, _ -> 0
      %{hidden: true}, own -> -own
      e, own -> max(e.w - own, 0)
    end

    delta.(left, lbw) + delta.(right, rbw)
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
    nrows = length(rows)
    edges = Enum.map(rows, & &1.edges)

    {placed, _taken} =
      rows
      |> Enum.with_index()
      |> Enum.reduce({[], MapSet.new()}, fn {row, r}, {placed, taken} ->
        {placed, taken, _col} =
          Enum.reduce(row.cells, {placed, taken, 0}, fn cell, {placed, taken, col} ->
            col = next_free(taken, r, col)

            spots =
              for dr <- 0..(cell.rowspan - 1), dc <- 0..(cell.colspan - 1), do: {r + dr, col + dc}

            # a border between two rows is the wider of the one below the upper and the one above
            # the lower
            top =
              if r > 0,
                do: best_edge(row.edges.top, Enum.at(edges, r - 1).bottom),
                else: row.edges.top

            last_row = Enum.at(edges, min(r + cell.rowspan, nrows) - 1)

            entry = %{
              cell: cell,
              row: r,
              col: col,
              row_valign: row.valign,
              row_bg: row.bg,
              row_img: row.bgimg,
              grp_img: row.gimg,
              shift: row.shift,
              redges: row.edges,
              top_edge: top,
              between: nil,
              bottom_edge: last_row.bottom
            }

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
  defp table_columns(st, placed, ncols, nrows, collapse?) do
    measured =
      Enum.map(placed, fn p ->
        cell = p.cell
        # the borders a row, column or the table brings to a cell at its edge take room too
        {eprops, _} = if collapse?, do: edge_props(p, ncols, nrows), else: {%{}, 0}

        {sub, key} =
          if eprops == %{}, do: {cell.sub, cell.key}, else: {cell.build.(eprops), nil}

        min = min_extent(st, sub, key)
        max = shrink_extent(st, sub, @unbounded, key)
        extra = cell.extra + if(eprops == %{}, do: 0, else: edge_hdelta(p, ncols))

        {max, pct} =
          case cell.width do
            w when is_number(w) -> {max(min, round(w) + extra), nil}
            {:pct, f} -> {max, f}
            _ -> {max, nil}
          end

        # `min-width` is the least the cell is, whatever its content
        least = if is_number(cell.minw), do: round(cell.minw) + extra, else: 0
        {min, max} = {max(min, least), max(max, least)}

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
  defp table_widths(mins, maxs, pcts, space, exact) do
    fixed =
      Enum.zip([mins, pcts, exact])
      |> Enum.map(fn
        {mn, _, w} when is_integer(w) -> {max(w, mn), mn}
        {mn, nil, _} -> {nil, mn}
        {mn, pct, _} -> {max(round(pct * space), mn), mn}
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
      |> Enum.take(max(round(missing), 0))

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

  # the height of a cell's box: borders that a row or group brings add to what `height` gives
  defp cell_minh(%{cell: %{minh: nil}}), do: 0

  defp cell_minh(%{cell: cell, vdelta: vdelta}),
    do: round(cell.minh) + if(cell.sizing == :border, do: 0, else: vdelta)

  defp table_row_heights(sized, nrows, sy) do
    base = List.duplicate(0, nrows)

    single =
      sized
      |> Enum.filter(&(min(&1.cell.rowspan, nrows - &1.row) == 1))
      |> Enum.reduce(base, fn p, heights ->
        List.update_at(heights, p.row, &max(&1, max(p.h0, cell_minh(p))))
      end)

    sized
    |> Enum.filter(&(min(&1.cell.rowspan, nrows - &1.row) > 1))
    |> Enum.sort_by(& &1.cell.rowspan)
    |> Enum.reduce(single, fn p, heights ->
      rs = min(p.cell.rowspan, nrows - p.row)
      have = heights |> Enum.slice(p.row, rs) |> Enum.sum() |> Kernel.+(sy * (rs - 1))
      need = max(p.h0, cell_minh(p)) - have
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
        {:calc, px, f} -> Map.put(acc, key, px + f * outer * 1.0)
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

      # squashed flat (`scaleX(0)`): the box and all it holds are not drawn
      :collapsed ->
        %{
          st
          | items: Enum.drop(st.items, st.n - box.n0),
            n: box.n0,
            rects: Enum.drop(st.rects, st.nr - box.nr0),
            nr: box.nr0,
            overlays: Enum.drop(st.overlays, length(st.overlays) - box.ov0)
        }

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
      :collapsed -> []
      matrix -> with_xform(items, matrix)
    end
  end

  # (transformations of boxes inside come first in the list; the outermost last)
  defp with_xform(items, matrix),
    do: Enum.map(items, &Map.update(&1, :xform, [matrix], fn list -> list ++ [matrix] end))

  # -- floats --------------------------------------------------------------------------------

  # the items of a flex or grid item that has a `z-index`: they paint with the positioned boxes
  defp z_items(%{zi: zi, items: items}) when is_integer(zi) do
    layer = if zi < 0, do: :under, else: :over
    seq = :erlang.unique_integer([:monotonic])
    Enum.map(items, &(&1 |> Map.put(layer, true) |> Map.put_new(:pz, z_order(seq, zi))))
  end

  defp z_items(%{items: items}), do: items

  # the paint order of positioned boxes: a bigger `z-index` above, then the order in the tree
  # (`{z, tree order}` when there is a positive `z-index`, else the tree order)
  defp z_order(seq, z) when is_integer(z) and z > 0, do: {z, seq}
  defp z_order(seq, _z), do: seq

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

    spec = spec |> Map.put(:clear, clear_side(c)) |> Map.put(:hpct_atom, pct_of(c["height"]))
    [{:float, side, sub, spec, style} | acc]
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
    # a float is never higher than one that came before it in the source
    y = Enum.reduce(st.floats, y, &max(&1.y0, &2))
    {fl, fr} = float_offsets(st, y, y + max(h, 1))
    overlapping = Enum.filter(st.floats, &(&1.y0 < y + max(h, 1) and &1.y1 > y))
    x = if side == :left, do: left + fl, else: right - fr - w

    # (a float too wide for its container still goes here when the floats beside it are all
    # outside the container, and clear of the space it takes)
    clear_beside? =
      right > left and
        Enum.all?(
          overlapping,
          &(&1.side != side and (&1.x0 >= right or &1.x1 <= left) and
              (&1.x0 >= x + w or &1.x1 <= x))
        )

    if overlapping == [] or w <= right - fr - (left + fl) or clear_beside? do
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
