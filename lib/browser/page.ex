defmodule Browser.Page do
  @moduledoc """
  Loads a URL into a renderable page: fetch, parse, fetch the stylesheets it
  references, cascade and prune. Runs in a task, never in the UI process.
  """

  alias Browser.{Fetch, Forms, HTML, Images, Layout, Style}

  @max_sheets 24
  @sheet_timeout 10_000

  # `pruned` is the styled tree before form controls get their content, `nodes`
  # what layout draws: `pruned` rendered with `form_state` (see `Browser.Forms`).
  defstruct [
    :url,
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
    svg_defs: %{}
  ]

  @doc "Fetches and builds `url` for the viewport `env` (see `Browser.MediaQuery`)."
  def load(url, env \\ Style.default_env(), fetch_opts \\ []) do
    case Fetch.load(url, fetch_opts) do
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
    {raw, forms} = body |> String.replace_invalid() |> HTML.parse() |> Forms.index()
    {raw, image_urls} = Images.index(raw, url)

    author =
      raw
      |> Style.sheet_refs()
      |> Enum.take(@max_sheets)
      |> fetch_sheets(url)
      |> Enum.map(fn {css, base} -> {:author, css, base} end)

    rules = Style.parse_sheets([{:ua, Style.ua_css()} | author])
    queries = Style.media_queries(rules)

    restyle(
      %__MODULE__{
        url: url,
        title: Layout.title(raw),
        raw: raw,
        rules: rules,
        queries: queries,
        forms: forms,
        image_urls: image_urls
      },
      env
    )
  end

  @doc """
  Re-runs the cascade for a new viewport. Returns the page unchanged when no
  media query result differs from the last run.
  """
  def restyle(%__MODULE__{} = page, env) do
    key = Style.media_key(page.queries, env)

    if key == page.key and page.nodes != nil do
      page
    else
      index = Style.index_rules(page.rules, env)
      pruned = Style.prune(page.raw, index)
      defs = Browser.Svg.defs(page.raw, pruned)
      render(%{page | key: key, pruned: pruned, svg_defs: defs}, page.form_state)
    end
  end

  @doc """
  Every picture the page needs: its `<img>` sources and the `url()` images its styles
  use as backgrounds (these depend on the cascade, so they change with the viewport).
  """
  def all_image_urls(%__MODULE__{} = page),
    do: Enum.uniq(page.image_urls ++ background_urls(page.pruned || []))

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
  Re-renders the form controls for `form_state`. Cheap: the styled tree is reused,
  so this is what typing, toggling and choosing call.
  """
  def render(%__MODULE__{} = page, form_state) do
    nodes = Forms.render(page.pruned, form_state, page.forms.controls)
    %{page | form_state: form_state, nodes: nodes}
  end

  defp fetch_sheets(refs, base) do
    refs
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

  defp sheet({:style, css}, base), do: {css, base}

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
