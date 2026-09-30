defmodule Browser.Page do
  @moduledoc """
  Loads a URL into a renderable page: fetch, parse, fetch the stylesheets it
  references, cascade and prune. Runs in a task, never in the UI process.
  """

  alias Browser.{Fetch, HTML, Layout, Style}

  @max_sheets 24
  @sheet_timeout 10_000

  defstruct [:url, :title, :raw, :rules, :queries, :key, :nodes]

  @doc "Fetches and builds `url` for the viewport `env` (see `Browser.MediaQuery`)."
  def load(url, env \\ Style.default_env()) do
    case Fetch.load(url) do
      {:ok, body, final} -> {:ok, build(body, final, env)}
      {:error, _} = err -> err
    end
  end

  @doc "Builds a page from an HTML string fetched from `url`."
  def build(body, url, env \\ Style.default_env()) do
    raw = body |> String.replace_invalid() |> HTML.parse()

    author =
      raw
      |> Style.sheet_refs()
      |> Enum.take(@max_sheets)
      |> fetch_sheets(url)
      |> Enum.map(&{:author, &1})

    rules = Style.parse_sheets([{:ua, Style.ua_css()} | author])
    queries = Style.media_queries(rules)

    restyle(
      %__MODULE__{url: url, title: Layout.title(raw), raw: raw, rules: rules, queries: queries},
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
      %{page | key: key, nodes: Style.prune(page.raw, index)}
    end
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
      {:ok, css} when is_binary(css) -> [css]
      _ -> []
    end)
  end

  defp sheet({:style, css}, _base), do: css

  defp sheet({:link, href}, base) do
    url = Fetch.resolve(base, href)

    if allowed?(base, url) do
      case Fetch.load(url) do
        {:ok, css, _} -> css
        _ -> nil
      end
    end
  end

  # remote pages may not pull in local files
  defp allowed?(base, url) do
    scheme = URI.parse(url).scheme
    if URI.parse(base).scheme == "file", do: scheme in ~w(file http https), else: scheme in ~w(http https)
  end
end
