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
    ver: nil
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
        raw: raw,
        rules: rules,
        queries: queries,
        sheet_refs: refs,
        sheet_cache: sheet_cache,
        forms: forms,
        image_urls: image_urls,
        viewport_units: viewport_units?(rules, raw)
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

  @doc """
  Re-runs the cascade for a new viewport. Returns the page unchanged when no
  media query result differs from the last run.
  """
  def restyle(%__MODULE__{} = page, env) do
    key = {Style.media_key(page.queries, env), page.viewport_units && {env.width, env.height}}

    if key == page.key and page.nodes != nil do
      page
    else
      {key, pruned, defs, fixed, cache, memo} =
        case page.style_cache do
          %{^key => {pruned, defs, fixed}} ->
            {key, pruned, defs, fixed, page.style_cache, page.memo}

          cache ->
            index = Style.index_rules(page.rules, env)

            old =
              case page.memo do
                {old_key, memo} -> if memo_fits?(old_key, env), do: memo
                nil -> nil
              end

            Process.delete(:style_vu)
            {pruned, memo} = Style.prune(Browser.Modal.backdrops(page.raw), index, old)

            # (a new style attribute with viewport units: the memo and the cache now hold for
            # this window size only)
            key =
              if Process.delete(:style_vu) == true and not page.viewport_units,
                do: {elem(key, 0), {env.width, env.height}},
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

  # The memo holds for `env` when each media query it was made with gives the same result now,
  # and, when the styles used viewport units, the window has the same size. (A query that only
  # new rules use does not matter: those rules reach no element that the memo holds, see
  # `refresh_sheets/3`.)
  defp memo_fits?({media, size}, env) do
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
        fetch: &Browser.Fetch.load(&1, initiator: initiator),
        request: &Browser.Fetch.load(&1, [initiator: initiator] ++ &2)
      }

      pid = Runtime.start(page.raw, info)
      Runtime.run_scripts(pid)
      Runtime.flush(pid)
      fun.(pid)
      reply = Runtime.snapshot(pid)
      Runtime.stop(pid)
      if reply.raw, do: from_raw(page, reply.raw, env), else: page
    else
      page
    end
  end

  @doc "True when the page has a `<script>` element or something editable (the runtime holds its document)."
  def scripts?(%__MODULE__{raw: raw}), do: has_tag?(raw, "script") or editable?(raw)

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
        {key, if(scope == nil, do: prefetched(ref, at), else: ref), at}
      end)

    # (a `<style>` has its text at hand, and a page may have hundreds of them: only what has to be
    # fetched, or may import something, goes to a task of its own. Then each different text is parsed
    # once, however many trees have it)
    {inline, remote} =
      Enum.split_with(jobs, fn
        {_key, {:style, css}, _at} -> not String.contains?(css, "@import")
        _ -> false
      end)

    fetched =
      Enum.map(inline, fn {{_, scope, _} = key, {:style, css}, at} ->
        {key, scope, [{css, at}]}
      end) ++
        (remote
         |> Task.async_stream(
           fn {key, ref, at} ->
             {_, scope, _} = key
             {key, scope, ref |> sheet(at) |> with_imports(0)}
           end,
           max_concurrency: 8,
           timeout: @sheet_timeout,
           on_timeout: :kill_task,
           ordered: true
         )
         |> Enum.zip(remote)
         |> Enum.map(fn
           {{:ok, got}, _} -> got
           {_, {key, _, _}} -> {key, nil, []}
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
      Enum.flat_map_reduce(refs, MapSet.new(), fn
        {{:link, href}, scope, from} = ref, seen ->
          key = {href, scope, from}

          if MapSet.member?(seen, key) or MapSet.size(seen) >= @max_sheets,
            do: {[], seen},
            else: {[ref], MapSet.put(seen, key)}

        ref, seen ->
          {[ref], seen}
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
