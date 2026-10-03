defmodule Browser.Page do
  @moduledoc """
  Loads a URL into a renderable page: fetch, parse, fetch the stylesheets it
  references, cascade and prune. Runs in a task, never in the UI process.
  """

  alias Browser.{Fetch, Forms, HTML, Images, Layout, Prefetch, Style}

  @max_sheets 24
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

    case Fetch.load(url, [on_chunk: on_chunk] ++ fetch_opts) do
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

  @doc "Builds a page from an HTML string fetched from `url`."
  def build(body, url, env \\ Style.default_env()) do
    parsed = body |> String.replace_invalid() |> HTML.parse()
    # scripts run, so what is meant for browsers without them is not shown
    parsed = if has_tag?(parsed, "script"), do: empty_tag(parsed, "noscript"), else: parsed
    {raw, forms} = Forms.index(parsed)
    raw = Browser.Nids.index(raw)
    base = base_href(raw, url)
    {raw, image_urls} = Images.index(raw, base)

    author =
      raw
      |> Style.sheet_refs()
      |> Enum.take(@max_sheets)
      |> fetch_sheets(base)
      |> Enum.map(fn {css, base} -> {:author, css, base} end)

    rules = Style.parse_sheets([{:ua, Style.ua_css()} | author])
    queries = Style.media_queries(rules)

    restyle(
      %__MODULE__{
        url: url,
        base: base,
        title: Layout.title(raw),
        raw: raw,
        rules: rules,
        queries: queries,
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

  @doc "True when the page has a `<script>` element."
  def scripts?(%__MODULE__{raw: raw}), do: has_tag?(raw, "script")

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
      env
    )
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
  defp fetch_sheets(refs, base) do
    refs
    |> Enum.map(&prefetched(&1, base))
    |> Task.async_stream(&sheet(&1, base),
      max_concurrency: 8,
      timeout: @sheet_timeout,
      on_timeout: :kill_task,
      ordered: true
    )
    |> Enum.flat_map(fn
      {:ok, {css, _base} = sheet} when is_binary(css) -> [sheet]
      _ -> []
    end)
  end

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
      case Fetch.load(url) do
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
