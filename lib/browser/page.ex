defmodule Browser.Page do
  @moduledoc """
  Loads a URL into a renderable page: fetch, parse, fetch the stylesheets it
  references, cascade and prune. Runs in a task, never in the UI process.
  """

  alias Browser.{Fetch, Forms, HTML, Images, Layout, MediaQuery, Prefetch, Style}

  @max_sheets 64
  @sheet_timeout 10_000

  # `pruned` is the styled tree before form controls get their content, `nodes`
  # what layout draws: `pruned` rendered with `form_state` (see `Browser.Forms`).
  defstruct [
    :url,
    # what relative addresses resolve against: the url, or the page's `<base href>`
    :base,
    :title,
    # the address of the icon the tab shows (`Browser.Favicon.url/3`), or nil
    :favicon,
    :raw,
    :rules,
    :queries,
    :key,
    :pruned,
    :nodes,
    forms: %{controls: %{}, forms: %{}},
    form_state: %{},
    # `pruned` and the elements in it that hold a control (`Browser.Forms.hot/1`)
    form_hot: nil,
    image_urls: [],
    # whether styles use vw/vh units: then the window size is part of the cascade
    viewport_units: false,
    # a `style` attribute has a length in container units (the rules say it themselves)
    cq_inline: false,
    svg_defs: %{},
    fixed_width: MapSet.new(),
    # the stylesheets the rules came from (`Browser.Style.scoped_refs/1`) and what each one
    # parsed to: a tree that kept its sheets keeps its rules, a script's new sheet is added
    sheet_refs: [],
    sheet_cache: %{},
    # the cascade for the window sizes seen so far, by media key: resizing back is free
    style_cache: %{},
    # what the cascade worked out per element (`Browser.Style.prune/3`), for the media key it
    # was run for: a changed tree only has its changed elements styled afresh
    memo: nil,
    # changes whenever the page is rebuilt or re-rendered, so a copy can be told from the original
    ver: nil,
    # the element under the pointer and its ancestors (layout numbers, `Browser.Nids`): these
    # match `:hover` (see `set_hover/3`)
    hover: [],
    # what of the rules can match `:hover` (`hover_rules/1`): nil before it is worked out
    hover_rules: nil,
    # the content sizes of the query containers of the last layout (`Browser.Container`): what
    # the `@container` rules were matched against
    cq_sizes: %{}
  ]

  @doc "Fetches and builds `url` for the viewport `env` (see `Browser.MediaQuery`)."
  def load(url, env \\ Style.default_env(), fetch_opts \\ []) do
    Prefetch.reset()

    on_chunk = fn chunk, from -> Prefetch.feed(chunk, from, &allowed?(from, &1)) end

    case Fetch.load(url, [on_chunk: on_chunk, navigation: true] ++ fetch_opts) do
      {:ok, body, final} -> {:ok, build(document(body, final), final, env)}
      {:error, _} = err -> err
    end
  end

  @doc """
  The HTML to show for fetched bytes. Markup is shown as is; a picture becomes a page
  holding just that picture; any other binary file gets a short explanation instead of
  its bytes drawn as text.
  """
  def document(body, url) do
    cond do
      Images.sniff(body) != :unknown -> image_document(url)
      binary?(body) -> binary_document(url, byte_size(body))
      true -> body
    end
  end

  defp image_document(url) do
    name = url |> URI.parse() |> Map.get(:path) |> Kernel.||("") |> Path.basename()

    """
    <!doctype html><html><head><title>#{escape(name)}</title></head>
    <body style="margin:0; background:#202124; text-align:center">
    <img src="#{escape(url)}" alt="#{escape(name)}" style="max-width:100%; height:auto">
    </body></html>
    """
  end

  defp binary_document(url, size) do
    """
    <!doctype html><html><head><title>#{escape(Path.basename(url))}</title></head>
    <body><h1>This file can't be shown</h1>
    <p>#{escape(url)} is a binary file of #{size} bytes. This browser can only show web pages and pictures.</p>
    </body></html>
    """
  end

  # a NUL byte near the start means it is not text
  defp binary?(body),
    do: body |> binary_part(0, min(byte_size(body), 1024)) |> :binary.match(<<0>>) != :nomatch

  defp escape(s),
    do:
      s
      |> String.replace("&", "&amp;")
      |> String.replace("<", "&lt;")
      |> String.replace("\"", "&quot;")

  defp xml_url?(url) when is_binary(url) do
    path = url |> String.split(["?", "#"]) |> hd() |> String.downcase()
    String.ends_with?(path, [".xht", ".xhtml", ".xml"])
  end

  defp xml_url?(_url), do: false

  @doc "Builds a page from an HTML string fetched from `url`."
  def build(body, url, env \\ Style.default_env()) do
    parsed = body |> String.replace_invalid() |> HTML.parse_document(xml: xml_url?(url))
    # scripts run, so what is meant for browsers without them is not shown
    parsed = if has_tag?(parsed, "script"), do: empty_tag(parsed, "noscript"), else: parsed
    {raw, forms} = Forms.index(parsed)
    raw = Browser.Nids.index(raw)
    base = base_href(raw, url)
    {raw, image_urls} = Images.index(raw, base)

    refs = sheet_refs(raw)
    {rules, sheet_cache} = sheet_rules(refs, base, %{})
    queries = Style.media_queries(rules)

    restyle(
      %__MODULE__{
        url: url,
        base: base,
        title: Layout.title(raw),
        favicon: Browser.Favicon.url(raw, url, base),
        raw: raw,
        rules: rules,
        queries: queries,
        sheet_refs: refs,
        sheet_cache: sheet_cache,
        forms: forms,
        image_urls: image_urls,
        viewport_units: viewport_units?(rules, raw),
        cq_inline: inline_cq_units?(raw)
      },
      env
    )
  end

  @doc "The address relative references resolve against: the first `<base href>`, or `url`."
  def base_href(raw, url) do
    case find_base(raw) do
      nil -> url
      href -> Fetch.resolve(url, href)
    end
  end

  defp find_base(nodes) when is_list(nodes), do: Enum.find_value(nodes, &find_base/1)
  defp find_base({:text, _}), do: nil

  defp find_base({:element, "base", attrs, _}) do
    case List.keyfind(attrs, "href", 0) do
      {_, href} when is_binary(href) and href != "" -> href
      _ -> nil
    end
  end

  defp find_base({:element, _, _, kids}), do: find_base(kids)

  defp viewport_units?(rules, raw) do
    Enum.any?(rules, fn rule ->
      Enum.any?(rule.decls, fn {_prop, value, _important} ->
        is_binary(value) and Style.viewport_unit?(value)
      end)
    end) or inline_viewport_units?(raw)
  end

  defp inline_viewport_units?(nodes) when is_list(nodes),
    do: Enum.any?(nodes, &inline_viewport_units?/1)

  defp inline_viewport_units?({:text, _}), do: false

  defp inline_viewport_units?({:element, _tag, attrs, kids}) do
    case List.keyfind(attrs, "style", 0) do
      {_, css} when is_binary(css) -> Style.viewport_unit?(css)
      _ -> false
    end or inline_viewport_units?(kids)
  end

  defp inline_cq_units?(nodes) when is_list(nodes), do: Enum.any?(nodes, &inline_cq_units?/1)
  defp inline_cq_units?({:text, _}), do: false

  defp inline_cq_units?({:element, _tag, attrs, kids}) do
    case List.keyfind(attrs, "style", 0) do
      {_, css} when is_binary(css) -> Style.cq_unit?(css)
      _ -> false
    end or inline_cq_units?(kids)
  end

  @doc """
  Re-runs the cascade for a new viewport. Returns the page unchanged when no
  media query result differs from the last run.
  """
  def restyle(%__MODULE__{} = page, env) do
    key =
      {Style.media_key(page.queries, env), page.viewport_units && {env.width, env.height},
       page.hover, page.cq_sizes}

    if key == page.key and page.nodes != nil do
      page
    else
      {key, pruned, defs, fixed, cache, memo} =
        case page.style_cache do
          %{^key => {pruned, defs, fixed}} ->
            {key, pruned, defs, fixed, page.style_cache, page.memo}

          cache ->
            index = Style.index_rules(page.rules, env)
            index = if page.cq_inline, do: Style.with_cq_units(index), else: index

            old =
              case page.memo do
                {old_key, memo} -> if memo_fits?(old_key, env), do: memo
                nil -> nil
              end

            # (what a container query matches is not in the memo's key)
            old = if Map.get(index, :cq), do: nil, else: old
            Process.put(:style_container_sizes, page.cq_sizes)

            Process.delete(:style_vu)
            raw = page.raw |> Browser.Modal.backdrops() |> mark_hover(MapSet.new(page.hover))
            {pruned, memo} = Style.prune(raw, index, old)
            Process.delete(:style_container_sizes)

            # (a new style attribute with viewport units: the memo and the cache now hold for
            # this window size only)
            key =
              if Process.delete(:style_vu) == true and not page.viewport_units,
                do: {elem(key, 0), {env.width, env.height}, page.hover, page.cq_sizes},
                else: key

            defs = Browser.Svg.defs(page.raw, pruned)
            fixed = fixed_width(pruned)
            cache = if map_size(cache) >= 4, do: %{}, else: cache
            {key, pruned, defs, fixed, Map.put(cache, key, {pruned, defs, fixed}), {key, memo}}
        end

      page = %{
        page
        | key: key,
          viewport_units: page.viewport_units or elem(key, 1) != false,
          pruned: pruned,
          svg_defs: defs,
          fixed_width: fixed,
          style_cache: cache,
          memo: memo
      }

      render(page, page.form_state)
    end
  end

  @doc "Does a rule of the page depend on the size of a container (`@container`, or lengths in `cqw`...)?"
  def cq?(%__MODULE__{rules: rules, cq_inline: inline?}),
    do: inline? or Enum.any?(rules, &(Map.has_key?(&1, :cq) or Map.has_key?(&1, :cqu)))

  @doc """
  Lays `page` out with `layout` (a function from a page to `{items, height}`, run with the
  `boxes: true` option) and, when it has `@container` rules, styles it again with the sizes of its
  containers that the layout gave, until they stop changing (three times at most). Returns
  `{page, {items, height}}`.
  """
  def settle(%__MODULE__{} = page, env, layout), do: settle(page, env, layout, layout.(page), 0)

  defp settle(page, env, layout, {items, _height} = laid_out, round) do
    sizes = if round < 3 and cq?(page), do: Browser.Container.sizes(page.pruned || [], items)

    if sizes == nil or sizes == page.cq_sizes do
      {page, laid_out}
    else
      page = restyle(%{page | cq_sizes: sizes}, env)
      settle(page, env, layout, layout.(page), round + 1)
    end
  end

  @doc """
  The page with `chain` (the element under the pointer and its ancestors, as layout numbers;
  `[]` when the pointer is on no element) matching `:hover`, styled again when that changes
  what the rules match.
  """
  def set_hover(%__MODULE__{hover: chain} = page, chain, _env), do: page

  def set_hover(%__MODULE__{} = page, chain, env) do
    page = %{page | hover_rules: {page.rules, hover_rules(page)}}

    if hover_changes?(page, chain),
      do: restyle(%{page | hover: chain}, env),
      else: %{page | hover: chain}
  end

  @doc """
  Whether moving the pointer so that `chain` is hovered can change the page: some rule with
  `:hover` might match an element that starts or stops being hovered. (What the selector asks
  of the element itself, its tag, id and classes, is checked; the rest is taken to hold.)
  """
  def hover_changes?(%__MODULE__{} = page, chain) do
    case hover_rules(page) do
      [] ->
        false

      compounds ->
        changed = MapSet.symmetric_difference(MapSet.new(page.hover), MapSet.new(chain))
        elements = hover_elements(page.pruned || [], changed, [])
        Enum.any?(elements, fn el -> Enum.any?(compounds, &hover_candidate?(&1, el)) end)
    end
  end

  # the compound selectors with `:hover` in the rules (in `:not()` and the like too), worked out
  # once for a set of rules
  defp hover_rules(%__MODULE__{rules: rules, hover_rules: {cached, compounds}})
       when cached === rules,
       do: compounds

  defp hover_rules(%__MODULE__{rules: rules}),
    do: (rules || []) |> Enum.flat_map(&hover_compounds(&1.selector)) |> Enum.uniq()

  defp hover_compounds(parts) when is_list(parts),
    do: Enum.flat_map(parts, fn {c, _} -> hover_compounds(c) end)

  defp hover_compounds(%{pseudos: pseudos} = c) do
    inner =
      Enum.flat_map(pseudos, fn
        {:fn, _, cmps} -> Enum.flat_map(cmps, &hover_compounds/1)
        {:has, rels} -> Enum.flat_map(rels, fn {_, parts} -> hover_compounds(parts) end)
        {:nth_of, _, _, sels} -> Enum.flat_map(sels, &hover_compounds/1)
        _ -> []
      end)

    if :hover in pseudos, do: [Map.take(c, [:tag, :id, :classes]) | inner], else: inner
  end

  defp hover_compounds(_), do: []

  defp hover_candidate?(c, {tag, attrs}) do
    classes =
      case List.keyfind(attrs, "class", 0) do
        {_, v} when is_binary(v) -> String.split(v)
        _ -> []
      end

    (c.tag in [nil, :any] or c.tag == tag) and
      (c.id == nil or List.keyfind(attrs, "id", 0) == {"id", c.id}) and
      Enum.all?(c.classes, &(&1 in classes))
  end

  # `{tag, attrs}` of the elements of a styled tree whose numbers are in `nids`
  defp hover_elements(nodes, nids, acc) when is_list(nodes),
    do: Enum.reduce(nodes, acc, &hover_elements(&1, nids, &2))

  defp hover_elements({:element, tag, attrs, kids}, nids, acc) do
    acc =
      case List.keyfind(attrs, "@nid", 0) do
        {_, nid} -> if MapSet.member?(nids, nid), do: [{tag, attrs} | acc], else: acc
        nil -> acc
      end

    if MapSet.size(nids) == length(acc), do: acc, else: hover_elements(kids, nids, acc)
  end

  defp hover_elements(_, _nids, acc), do: acc

  # Marks the elements of `chain` with `"@hover"`. The chain runs from the root down, so the
  # walk only goes into a marked element: the rest of the tree stays as it is (the same terms).
  defp mark_hover(nodes, chain) do
    if MapSet.size(chain) == 0, do: nodes, else: Enum.map(nodes, &mark_hover_node(&1, chain))
  end

  defp mark_hover_node({:element, tag, attrs, kids} = node, chain) do
    case List.keyfind(attrs, "@nid", 0) do
      {_, nid} ->
        if MapSet.member?(chain, nid),
          do: {:element, tag, [{"@hover", true} | attrs], mark_hover(kids, chain)},
          else: node

      # (an element with no number, from the page itself: its content may be in the chain)
      nil ->
        {:element, tag, attrs, mark_hover(kids, chain)}
    end
  end

  defp mark_hover_node(node, _chain), do: node

  # The memo holds for `env` when each media query it was made with gives the same result now,
  # and, when the styles used viewport units, the window has the same size. (A query that only
  # new rules use does not matter: those rules reach no element that the memo holds, see
  # `refresh_sheets/3`.)
  # (the hovered elements do not matter: they are marked in the tree, and a changed mark is a
  # changed element)
  defp memo_fits?({media, size, _hover, _cq}, env) do
    (size == false or size == {env.width, env.height}) and
      Enum.all?(media, fn {query, result} -> MediaQuery.eval(query, env) == result end)
  end

  # The controls whose box width doesn't depend on their content (a length or a
  # percentage, not `auto`): typing in one can't move anything else on the page.
  defp fixed_width(nodes, acc \\ MapSet.new())

  defp fixed_width(nodes, acc) when is_list(nodes),
    do: Enum.reduce(nodes, acc, &fixed_width/2)

  defp fixed_width({:element, _tag, attrs, kids}, acc) do
    acc =
      with {_, cid} <- List.keyfind(attrs, "@cid", 0),
           {_, %{"width" => w}} <- List.keyfind(attrs, "@computed", 0),
           true <- is_number(w) or match?({:pct, _}, w) do
        MapSet.put(acc, cid)
      else
        _ -> acc
      end

    fixed_width(kids, acc)
  end

  defp fixed_width(_text, acc), do: acc

  @doc """
  Every picture the page needs: its `<img>` sources and the `url()` images its styles
  use as backgrounds (these depend on the cascade, so they change with the viewport).
  """
  def all_image_urls(%__MODULE__{} = page),
    do: Enum.uniq(page.image_urls ++ background_urls(page.pruned || []))

  @doc "True when a style of the page uses `url` as a background image."
  def background_url?(%__MODULE__{pruned: pruned}, url),
    do: url in background_urls(pruned || [])

  defp background_urls(nodes) do
    Enum.flat_map(nodes, fn
      {:element, _tag, attrs, kids} ->
        own =
          case List.keyfind(attrs, "@computed", 0) do
            {_, %{"background-image" => images}} -> Images.background_urls(images)
            _ -> []
          end

        own ++ background_urls(kids)

      _ ->
        []
    end)
  end

  @doc "The address of the video element with element number `nid` (`\"@media\"`), or nil."
  def media_url(%__MODULE__{raw: raw}, nid), do: find_media(raw, nid, fn _attrs, url -> url end)

  @doc "The attributes of the video element with element number `nid`, or nil."
  def media_attrs(%__MODULE__{raw: raw}, nid),
    do: find_media(raw, nid, fn attrs, _url -> attrs end)

  @doc """
  The videos a page starts a player for when it is shown: `[{element number, :play | :preload}]`.
  A video with `autoplay` plays; one with `controls` (and no `preload="none"`) is opened so its
  length is known before the first play.
  """
  def start_videos(%__MODULE__{raw: raw}), do: start_videos(raw, [])

  defp start_videos(nodes, acc) when is_list(nodes), do: Enum.reduce(nodes, acc, &start_videos/2)

  defp start_videos({:element, "video", attrs, kids}, acc) do
    acc =
      with {_, nid} <- List.keyfind(attrs, "@nid", 0),
           true <- List.keymember?(attrs, "@media", 0) do
        cond do
          List.keymember?(attrs, "autoplay", 0) ->
            acc ++ [{nid, :play}]

          List.keymember?(attrs, "controls", 0) and not preload_none?(attrs) ->
            acc ++ [{nid, :preload}]

          true ->
            acc
        end
      else
        _ -> acc
      end

    start_videos(kids, acc)
  end

  defp start_videos({:element, _tag, _attrs, kids}, acc), do: start_videos(kids, acc)
  defp start_videos(_other, acc), do: acc

  defp preload_none?(attrs) do
    case List.keyfind(attrs, "preload", 0) do
      {_, v} -> String.downcase(String.trim(v)) == "none"
      nil -> false
    end
  end

  @doc """
  The pseudo image URL (`"media:..."`) of the picture of the video with element number `nid`:
  where the frames of its player are drawn. nil when the video shows a poster instead.
  """
  def media_picture(%__MODULE__{raw: raw}, nid) do
    find_media(raw, nid, fn attrs, _url ->
      case {List.keyfind(attrs, "@frame", 0), List.keyfind(attrs, "@src", 0)} do
        {{_, "media:" <> _ = pic}, _} -> pic
        {_, {_, "media:" <> _ = pic}} -> pic
        _ -> nil
      end
    end)
  end

  defp find_media(nodes, nid, pick) do
    Enum.find_value(nodes, fn
      {:element, "video", attrs, kids} ->
        with {_, ^nid} <- List.keyfind(attrs, "@nid", 0),
             {_, url} <- List.keyfind(attrs, "@media", 0) do
          pick.(attrs, url)
        else
          _ -> find_media(kids, nid, pick)
        end

      {:element, _tag, _attrs, kids} ->
        find_media(kids, nid, pick)

      _ ->
        nil
    end)
  end

  @doc """
  `%{control id => element number}` (`"@nid"`) of the page's controls: how a control is found
  again in a page a script has changed, where the ids may have been dealt out afresh.
  """
  def cid_nids(%__MODULE__{raw: raw}), do: cid_nids(raw, %{})

  defp cid_nids(nodes, acc) when is_list(nodes), do: Enum.reduce(nodes, acc, &cid_nids/2)
  defp cid_nids({:text, _}, acc), do: acc

  defp cid_nids({:element, _tag, attrs, kids}, acc) do
    acc =
      with {_, cid} <- List.keyfind(attrs, "@cid", 0),
           {_, nid} <- List.keyfind(attrs, "@nid", 0) do
        Map.put(acc, cid, nid)
      else
        _ -> acc
      end

    cid_nids(kids, acc)
  end

  @doc """
  Runs the page's scripts in a runtime of its own, lets `fun` do something with the runtime
  (`Browser.JS.Runtime`) and returns the page as the scripts left it. For tools that have no
  window (`mix browser.screenshot --js`, `mix browser.layout --js`) and tests; the session keeps
  a runtime for as long as the page is shown instead.
  """
  def run_js(%__MODULE__{} = page, env, fun \\ fn _pid -> :ok end) do
    if scripts?(page) do
      alias Browser.JS.Runtime
      # (a closure that named `page` would carry the whole page into the runtime's process)
      initiator = page.url

      info = %{
        url: page.url,
        base: page.base || page.url,
        width: env.width,
        height: env.height,
        history_before: 0,
        layout_now: true,
        fetch: &Browser.Fetch.load(&1, initiator: initiator),
        request: &Browser.Fetch.load(&1, [initiator: initiator] ++ &2)
      }

      # (the scripts ask where things are, as `offsetWidth`: like the session, answer with a
      # layout of the tree as it is)
      Process.put(:layout_serve, &serve_layout(page, env, &1))
      pid = Runtime.start(page.raw, info)
      Runtime.run_scripts(pid)
      Runtime.flush(pid)
      fun.(pid)
      reply = Runtime.snapshot(pid)
      Runtime.stop(pid)
      Process.delete(:layout_serve)
      if reply.raw, do: from_raw(page, reply.raw, env), else: page
    else
      page
    end
  end

  # a layout for the scripts of `run_js/3` (a request with no reference is a prewarm: no answer)
  defp serve_layout(page, env, {:layout_now, js, ref, raw}) do
    if ref != nil do
      laid = from_raw(page, raw, env)

      {items, height} =
        Layout.layout(laid.nodes, env.width, &Browser.Screenshot.measure/2, env.height,
          svg_defs: laid.svg_defs,
          boxes: true,
          metrics: fn _style -> 16 end
        )

      rects =
        items
        |> Browser.Nids.rects(Browser.Nids.parents(laid.pruned || []))
        |> Browser.Nids.with_styles(laid.pruned || [])

      send(js, {:layout_now_done, ref, rects, {env.width * 1.0, height * 1.0}})
    end

    :ok
  end

  @doc "True when the page has a `<script>` element or something editable (the runtime holds its document)."
  def scripts?(%__MODULE__{raw: raw}),
    do: has_tag?(raw, "script") or editable?(raw) or frames?(raw)

  # an `<iframe>` with a `src` or `srcdoc` is a document of its own: the runtime loads it
  defp frames?(nodes) when is_list(nodes), do: Enum.any?(nodes, &frames?/1)

  defp frames?({:element, "iframe", attrs, kids}) do
    case {List.keyfind(attrs, "srcdoc", 0), List.keyfind(attrs, "src", 0)} do
      {nil, nil} -> frames?(kids)
      {nil, {_, v}} -> String.trim(to_string(v)) not in ["", "about:blank"] or frames?(kids)
      _ -> true
    end
  end

  defp frames?({:element, _tag, _attrs, kids}), do: frames?(kids)
  defp frames?(_), do: false

  defp editable?(nodes) when is_list(nodes), do: Enum.any?(nodes, &editable?/1)

  defp editable?({:element, _tag, attrs, kids}) do
    case List.keyfind(attrs, "contenteditable", 0) do
      {_, v} when v in ["", "true", "plaintext-only"] -> true
      _ -> editable?(kids)
    end
  end

  defp editable?(_), do: false

  # the element stays (scripts and frameworks expect it in the tree), its content does not
  defp empty_tag(nodes, tag) when is_list(nodes), do: Enum.map(nodes, &empty_tag(&1, tag))
  defp empty_tag({:element, tag, attrs, _kids}, tag), do: {:element, tag, attrs, []}

  defp empty_tag({:element, el, attrs, kids}, tag),
    do: {:element, el, attrs, empty_tag(kids, tag)}

  defp empty_tag(other, _tag), do: other

  defp has_tag?(nodes, tag) when is_list(nodes), do: Enum.any?(nodes, &has_tag?(&1, tag))
  defp has_tag?({:element, tag, _, _}, tag), do: true
  defp has_tag?({:element, _, _, kids}, tag), do: has_tag?(kids, tag)
  defp has_tag?(_, _), do: false

  @doc """
  The page for a tree a script has changed (see `Browser.JS.DOM.to_raw/0`): forms and pictures
  are indexed again and the cascade runs afresh. Control state is not kept: the tree carries
  the values the controls have.
  """
  def from_raw(%__MODULE__{} = page, raw, env), do: from_raw(page, raw, env, nil)

  @doc """
  `from_raw/3` with the sheet refs of `raw` that `layout_base/2` gave (nil: `from_raw/4` finds
  them).
  """
  def from_raw(%__MODULE__{} = page, raw, env, refs) do
    {raw, forms} = Forms.index(raw)
    raw = Browser.Nids.index(raw)
    base = base_href(raw, page.url)
    {raw, image_urls} = Images.index(raw, base)

    restyle(
      refresh_sheets(
        %{
          page
          | raw: raw,
            base: base,
            title: Layout.title(raw),
            favicon: Browser.Favicon.url(raw, page.url, base),
            forms: forms,
            image_urls: image_urls,
            form_state: %{},
            key: nil,
            pruned: nil,
            # (kept: `render/2` gives back the subtrees of it that the new tree has unchanged,
            # and the layout keeps what it worked out for them)
            style_cache: %{}
        },
        raw,
        refs || sheet_refs(raw),
        base
      ),
      env
    )
  end

  @doc """
  The page that a layout of the tree `raw` in another process starts from, and the sheet refs of
  `raw`: give both to `from_raw/4`. What `from_raw/4` makes again is not in the page, so the copy
  into the process is small. When `raw` has other sheets than the page, the memo of the cascade
  is not in it either when `from_raw/4` cannot keep that memo (see `kept_memo/3`).
  """
  def layout_base(%__MODULE__{} = page, raw) do
    refs = sheet_refs(raw)
    base = %{page | raw: nil, nodes: nil, pruned: nil, style_cache: %{}}
    keep = refs == page.sheet_refs or elem(new_trees(page.sheet_refs, refs), 0) != []
    {if(keep, do: base, else: %{base | memo: nil}), refs}
  end

  @doc """
  What `from_raw/3` worked out about the style sheets and the cascade, to be handed to another copy
  of the page (`adopt_style_state/2`) so that the next tree it is given starts from it: the sheets
  that were parsed and the memo of the cascade.

  `base` is the page that the run started from (`layout_base/2`). When the tree has the sheets of
  `base`, the rules and the parsed sheets are not in the state: the receiver has them already, and
  they are a large part of the copy (in the Speedometer Lit suite, two thirds).
  """
  def style_state(page, base \\ nil)

  def style_state(%__MODULE__{sheet_refs: refs} = page, %__MODULE__{sheet_refs: refs}),
    do: Map.take(page, [:sheet_refs, :viewport_units, :memo])

  def style_state(%__MODULE__{} = page, _base),
    do: Map.take(page, [:rules, :queries, :sheet_refs, :sheet_cache, :viewport_units, :memo])

  @doc """
  Puts a `style_state/2` of a later tree in `page` (its rules, sheets and memo go together). A state
  without the rules is put in only when `page` has the same sheets: else `page` stays as it is (its
  rules do not agree with the memo).
  """
  def adopt_style_state(%__MODULE__{} = page, %{rules: _} = style) do
    # (only the sheets of that tree stay: the cache would hold every tree there was, and be
    # copied whole into every process that lays out a page)
    cache = page.sheet_cache |> Map.merge(style.sheet_cache) |> Map.take([:ua | style.sheet_refs])
    struct(page, %{style | sheet_cache: cache})
  end

  def adopt_style_state(%__MODULE__{sheet_refs: refs} = page, %{sheet_refs: refs} = style),
    do: struct(page, style)

  def adopt_style_state(%__MODULE__{} = page, _style), do: page

  @doc """
  Gives `page` with `viewport_units` true also when a style attribute in `raw` has viewport
  units. (`from_raw/4` looks at the style attributes only when the sheets change.)
  """
  def inline_viewport_units(%__MODULE__{} = page, raw),
    do: %{page | viewport_units: page.viewport_units || inline_viewport_units?(raw)}

  @doc """
  `page` without what `style_state/2` holds: small to copy into another process, which puts a
  style state in it with `adopt_style_state/2`.
  """
  def without_style(%__MODULE__{} = page),
    do: %{page | rules: nil, queries: nil, sheet_cache: %{}, memo: nil}

  # A script may add stylesheets (a `<style>`, a `<link>`, the sheets of a frame): the rules
  # follow the sheets the tree has now. Sheets seen before are not fetched or parsed again.
  # (`refs`: the sheets of `raw`, see `sheet_refs/1`)
  defp refresh_sheets(page, raw, refs, base) do
    if refs == page.sheet_refs do
      page
    else
      {rules, cache} = sheet_rules(refs, base, page.sheet_cache)

      %{
        page
        | rules: rules,
          queries: Style.media_queries(rules),
          sheet_refs: refs,
          sheet_cache: cache,
          viewport_units: viewport_units?(rules, raw),
          memo: kept_memo(page, refs, cache)
      }
    end
  end

  # the style sheets of the tree `raw`: `{ref, scope, base}`, in document order
  defp sheet_refs(raw), do: raw |> Style.scoped_refs() |> cap_links()

  # The memo stays when the new sheets are all in new trees (shadow trees or frames): a tree is
  # new when no element that the memo holds has its name. The rules of such a tree reach only
  # the elements in it and its host, and these are not in the memo as they are now, so they are
  # styled afresh. Each other sheet must stay as it was. `@property` and cascade layers can
  # change the rules of more than one tree, so a new rule of these makes a new memo.
  defp kept_memo(%{memo: {_key, entries} = memo} = page, refs, cache) do
    {added, trees} = new_trees(page.sheet_refs, refs)

    if added != [] and
         not Enum.any?(added, fn ref -> Enum.any?(Map.get(cache, ref, []), &wide_rule?/1) end) and
         not Enum.any?(entries, &memo_in_trees?(&1, trees)),
       do: memo
  end

  defp kept_memo(_page, _refs, _cache), do: nil

  # The sheets of `refs` in trees that `old` has no sheet in, and the names of those trees,
  # when each sheet of `old` stays as it was; else no sheets
  defp new_trees(old, refs) do
    old_trees = MapSet.new(old, fn {_, scope, _} -> scope end)

    {added, kept} =
      Enum.split_with(refs, fn {_, scope, _} -> scope != nil and scope not in old_trees end)

    if kept == old,
      do: {added, MapSet.new(added, fn {_, scope, _} -> scope end)},
      else: {[], MapSet.new()}
  end

  defp wide_rule?(rule), do: Map.get(rule, :registered, false) or Map.get(rule, :layer) != nil

  defp memo_in_trees?({nid, {%{attrs: attrs}, _node}}, trees) when is_integer(nid) do
    case List.keyfind(attrs, "data-b-frame", 0) do
      {_, name} -> MapSet.member?(trees, name)
      nil -> false
    end
  end

  defp memo_in_trees?(_entry, _trees), do: false

  # the rules of `refs` (`{ref, scope, base}`, in document order), the user agent's first;
  # `cache` has what earlier calls parsed
  defp sheet_rules(refs, base, cache) do
    cache =
      Map.put_new_lazy(cache, :ua, fn -> Style.parse_sheets([{:ua, Style.ua_css()}]) end)

    missing = Enum.reject(refs, &Map.has_key?(cache, &1))

    # (the prefetch results belong to this process)
    jobs =
      Enum.map(missing, fn {ref, scope, from} = key ->
        at = from || base
        {ref, media} = media_split(ref)
        {key, if(scope == nil, do: prefetched(ref, at), else: ref), at, media}
      end)

    # (a `<style>` has its text at hand, and a page may have hundreds of them: only what has to be
    # fetched, or may import something, goes to a task of its own. Then each different text is parsed
    # once, however many trees have it)
    {inline, remote} =
      Enum.split_with(jobs, fn
        {_key, {:style, css}, _at, _media} -> not String.contains?(css, "@import")
        _ -> false
      end)

    fetched =
      Enum.map(inline, fn {{_, scope, _} = key, {:style, css}, at, media} ->
        {key, scope, [{media_wrap(css, media), at}]}
      end) ++
        (remote
         |> Task.async_stream(
           fn {key, ref, at, media} ->
             {_, scope, _} = key
             sheets = ref |> sheet(at) |> with_imports(0)
             {key, scope, for({css, from} <- sheets, do: {media_wrap(css, media), from})}
           end,
           max_concurrency: 8,
           timeout: @sheet_timeout,
           on_timeout: :kill_task,
           ordered: true
         )
         |> Enum.zip(remote)
         |> Enum.map(fn
           {{:ok, got}, _} -> got
           {_, {key, _, _, _}} -> {key, nil, []}
         end))

    texts =
      fetched
      |> Enum.flat_map(fn {_, _, sheets} -> sheets end)
      |> Enum.uniq()
      |> Task.async_stream(
        fn {css, from} -> {{css, from}, Style.parse_sheet(:author, css, from)} end,
        max_concurrency: 8,
        timeout: @sheet_timeout,
        on_timeout: :kill_task,
        ordered: true
      )
      |> Enum.flat_map(fn
        {:ok, parsed} -> [parsed]
        _ -> []
      end)
      |> Map.new()

    parsed =
      Enum.reduce(fetched, cache, fn {key, scope, sheets}, cache ->
        rules = Enum.flat_map(sheets, &(texts |> Map.get(&1, []) |> Style.scope_rules(scope)))
        Map.put(cache, key, rules)
      end)

    rules = Enum.flat_map([:ua | refs], &Map.get(parsed, &1, []))
    {rules, Map.take(parsed, [:ua | refs])}
  end

  @doc """
  Re-renders the form controls for `form_state`. Cheap: the styled tree is reused,
  so this is what typing, toggling and choosing call.
  """
  def render(%__MODULE__{} = page, form_state) do
    # (the tree of the last render: the subtrees the change left alone are given back as they were)
    hot =
      case page.form_hot do
        {pruned, hot} -> if :erts_debug.same(pruned, page.pruned), do: hot
        nil -> nil
      end || Forms.hot(page.pruned || [])

    nodes = Forms.render(page.pruned, form_state, page.forms.controls, page.nodes, hot)

    %{
      page
      | form_state: form_state,
        nodes: nodes,
        ver: make_ref(),
        form_hot: {page.pruned, hot}
    }
  end

  # Sheets `Browser.Prefetch` started while the HTML arrived are collected here, in the
  # process that received it; the rest are fetched in parallel now.
  # at most @max_sheets different linked sheets are fetched; a sheet linked again (frameworks
  # that add their stylesheet once per component do) is applied once, and costs no slot.
  # inline <style> blocks cost nothing, so all stay
  defp cap_links(refs) do
    {kept, _} =
      Enum.flat_map_reduce(refs, MapSet.new(), fn {sheet, scope, from} = ref, seen ->
        case media_split(sheet) do
          {{:link, href}, media} ->
            key = {href, media, scope, from}

            if MapSet.member?(seen, key) or MapSet.size(seen) >= @max_sheets,
              do: {[], seen},
              else: {[ref], MapSet.put(seen, key)}

          _ ->
            {[ref], seen}
        end
      end)

    kept
  end

  @max_import_depth 4

  # The `@import`s at the top of a sheet are fetched and come before it, with the statements
  # themselves removed; an `@import` after any other rule is ignored (so it is left for the
  # parser to skip). -> [{css, base}]
  defp with_imports({css, base}, depth) when is_binary(css) do
    {imports, rest} = leading_imports(css)

    imported =
      if depth < @max_import_depth do
        for {href, media} <- imports,
            url = Fetch.resolve(base, href),
            allowed?(base, url),
            {:ok, imported_css, final} <- [Fetch.load(url, initiator: base)],
            {css, base} <- with_imports({imported_css, final}, depth + 1),
            do: {media_wrap(css, media), base}
      else
        []
      end

    imported ++ [{rest, base}]
  end

  defp with_imports(_, _depth), do: []

  @import_re ~r/\A(?:\s|\/\*.*?\*\/|<!--|-->)*@import\s*(?:url\(\s*(?:"([^"]*)"|'([^']*)'|([^)\s]*))\s*\)|"([^"]*)"|'([^']*)')\s*([^;{]*);/is
  @charset_re ~r/\A\s*@charset\s*"[^"]*"\s*;/i

  defp leading_imports(css),
    do: leading_imports(Regex.replace(@charset_re, css, "", global: false), [])

  defp leading_imports(css, acc) do
    case Regex.run(@import_re, css) do
      [whole | groups] ->
        href = groups |> Enum.take(5) |> Enum.find("", &(&1 != ""))
        media = groups |> Enum.at(5, "") |> String.trim()

        leading_imports(binary_part(css, byte_size(whole), byte_size(css) - byte_size(whole)), [
          {href, media} | acc
        ])

      nil ->
        {Enum.reverse(acc), css}
    end
  end

  # (a sheet with a `media` attribute: `Browser.Style.sheet_refs/1`)
  defp media_split({:media, media, ref}), do: {ref, media}
  defp media_split(ref), do: {ref, ""}

  # the layer or supports part of an `@import` is not supported: a plain media list is
  defp media_wrap(css, ""), do: css
  defp media_wrap(css, media), do: "@media " <> media <> " {" <> css <> "}"

  defp prefetched({:link, href} = ref, base) do
    url = Fetch.resolve(base, href)

    case Prefetch.take(url, @sheet_timeout) do
      :none -> ref
      result -> {:prefetched, result}
    end
  end

  defp prefetched(ref, _base), do: ref

  defp sheet({:style, css}, base), do: {css, base}
  defp sheet({:prefetched, {:ok, css, final}}, _base), do: {css, final}
  defp sheet({:prefetched, _}, _base), do: nil

  defp sheet({:link, href}, base) do
    url = Fetch.resolve(base, href)

    if allowed?(base, url) do
      case Fetch.load(url, initiator: base) do
        {:ok, css, final} -> {css, final}
        _ -> nil
      end
    end
  end

  # remote pages may not pull in local files
  defp allowed?(base, url) do
    scheme = URI.parse(url).scheme

    if URI.parse(base).scheme == "file",
      do: scheme in ~w(file http https),
      else: scheme in ~w(http https)
  end
end
