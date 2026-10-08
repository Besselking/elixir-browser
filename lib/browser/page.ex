defmodule Browser.Page do
  @moduledoc """
  Loads a URL into a renderable page: fetch, parse, fetch the stylesheets it
  references, cascade and prune. Runs in a task, never in the UI process.
  """

  alias Browser.{Fetch, Forms, HTML, Images, Layout, Prefetch, Style}

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

    refs = raw |> Style.scoped_refs() |> cap_links()
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

  @viewport_unit ~r/\d(vw|vh|vmin|vmax|dvw|dvh|svw|svh|lvw|lvh)\b/i

  defp viewport_units?(rules, raw) do
    Enum.any?(rules, fn rule ->
      Enum.any?(rule.decls, fn {_prop, value, _important} ->
        is_binary(value) and Regex.match?(@viewport_unit, value)
      end)
    end) or inline_viewport_units?(raw)
  end

  defp inline_viewport_units?(nodes) when is_list(nodes),
    do: Enum.any?(nodes, &inline_viewport_units?/1)

  defp inline_viewport_units?({:text, _}), do: false

  defp inline_viewport_units?({:element, _tag, attrs, kids}) do
    case List.keyfind(attrs, "style", 0) do
      {_, css} when is_binary(css) -> Regex.match?(@viewport_unit, css)
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
      {pruned, defs, fixed, cache, memo} =
        case page.style_cache do
          %{^key => {pruned, defs, fixed}} ->
            {pruned, defs, fixed, page.style_cache, page.memo}

          cache ->
            index = Style.index_rules(page.rules, env)
            old = with {^key, memo} <- page.memo, do: memo, else: (_ -> nil)
            {pruned, memo} = Style.prune(page.raw, index, old)
            defs = Browser.Svg.defs(page.raw, pruned)
            fixed = fixed_width(pruned)
            cache = if map_size(cache) >= 4, do: %{}, else: cache
            {pruned, defs, fixed, Map.put(cache, key, {pruned, defs, fixed}), {key, memo}}
        end

      page = %{
        page
        | key: key,
          pruned: pruned,
          svg_defs: defs,
          fixed_width: fixed,
          style_cache: cache,
          memo: memo
      }

      render(page, page.form_state)
    end
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
  def from_raw(%__MODULE__{} = page, raw, env) do
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
            nodes: nil,
            style_cache: %{}
        },
        raw,
        base
      ),
      env
    )
  end

  # A script may add stylesheets (a `<style>`, a `<link>`, the sheets of a frame): the rules
  # follow the sheets the tree has now. Sheets seen before are not fetched or parsed again.
  defp refresh_sheets(page, raw, base) do
    refs = raw |> Style.scoped_refs() |> cap_links()

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
          memo: nil
      }
    end
  end

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

    parsed =
      jobs
      |> Task.async_stream(
        fn {key, ref, at} ->
          {_, scope, _} = key
          sheets = ref |> sheet(at) |> with_imports(0)
          {key, Style.parse_sheets(for {css, from} <- sheets, do: {:author, css, from, scope})}
        end,
        max_concurrency: 8,
        timeout: @sheet_timeout,
        on_timeout: :kill_task,
        ordered: true
      )
      |> Enum.zip(jobs)
      |> Enum.reduce(cache, fn
        {{:ok, {key, rules}}, _}, cache -> Map.put(cache, key, rules)
        {_, {key, _, _}}, cache -> Map.put(cache, key, [])
      end)

    rules = Enum.flat_map([:ua | refs], &Map.get(parsed, &1, []))
    {rules, Map.take(parsed, [:ua | refs])}
  end

  @doc """
  Re-renders the form controls for `form_state`. Cheap: the styled tree is reused,
  so this is what typing, toggling and choosing call.
  """
  def render(%__MODULE__{} = page, form_state) do
    nodes = Forms.render(page.pruned, form_state, page.forms.controls)
    %{page | form_state: form_state, nodes: nodes, ver: make_ref()}
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
