defmodule Browser.Page do
  @moduledoc """
  Loads a URL into a renderable page: fetch, parse, fetch the stylesheets it
  references, cascade and prune. Runs in a task, never in the UI process.
  """

  alias Browser.{Fetch, Forms, HTML, Layout, Style}

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
    form_state: %{}
  ]

  @doc "Fetches and builds `url` for the viewport `env` (see `Browser.MediaQuery`)."
  def load(url, env \\ Style.default_env(), fetch_opts \\ []) do
    case Fetch.load(url, fetch_opts) do
      {:ok, body, final} -> {:ok, build(body, final, env)}
      {:error, _} = err -> err
    end
  end

  @doc "Builds a page from an HTML string fetched from `url`."
  def build(body, url, env \\ Style.default_env()) do
    {raw, forms} = body |> String.replace_invalid() |> HTML.parse() |> Forms.index()

    author =
      raw
      |> Style.sheet_refs()
      |> Enum.take(@max_sheets)
      |> fetch_sheets(url)
      |> Enum.map(&{:author, &1})

    rules = Style.parse_sheets([{:ua, Style.ua_css()} | author])
    queries = Style.media_queries(rules)

    restyle(
      %__MODULE__{
        url: url,
        title: Layout.title(raw),
        raw: raw,
        rules: rules,
        queries: queries,
        forms: forms
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
      render(%{page | key: key, pruned: Style.prune(page.raw, index)}, page.form_state)
    end
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

    if URI.parse(base).scheme == "file",
      do: scheme in ~w(file http https),
      else: scheme in ~w(http https)
  end
end
