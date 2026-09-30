defmodule Browser.Page do
  @moduledoc """
  Loads a URL into a renderable page: fetch, parse, fetch the stylesheets it
  references, cascade and prune. Runs in a task, never in the UI process.
  """

  alias Browser.{Fetch, HTML, Layout, Style}

  @max_sheets 24
  @sheet_timeout 10_000

  def load(url) do
    case Fetch.load(url) do
      {:ok, body, final} -> {:ok, build(body, final)}
      {:error, _} = err -> err
    end
  end

  @doc "Builds a page from an HTML string fetched from `url`."
  def build(body, url) do
    nodes = body |> String.replace_invalid() |> HTML.parse()

    author =
      nodes
      |> Style.sheet_refs()
      |> Enum.take(@max_sheets)
      |> fetch_sheets(url)
      |> Enum.map(&{:author, &1})

    index = Style.index([{:ua, Style.ua_css()} | author])
    %{url: url, title: Layout.title(nodes), nodes: Style.prune(nodes, index)}
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
