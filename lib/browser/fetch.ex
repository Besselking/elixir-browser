defmodule Browser.Fetch do
  @moduledoc "Loads a URL into `{:ok, body, final_url}`."

  @max_redirects 8

  @about_home """
  <html><body>
  <h1>Elixir Browser</h1>
  <p>A tiny browser written in Elixir. Type a URL above and press Enter.</p>
  <ul>
  <li><a href="https://example.com">example.com</a></li>
  <li><a href="http://info.cern.ch">info.cern.ch</a> (the first website)</li>
  <li><a href="https://elixir-lang.org">elixir-lang.org</a></li>
  </ul>
  </body></html>
  """

  @doc "Turn what the user typed into an absolute URL."
  def normalize(input) do
    input = String.trim(input)

    cond do
      input == "" -> "about:home"
      String.starts_with?(input, ["http://", "https://", "file://", "about:"]) -> input
      String.starts_with?(input, ["/", "./", "~"]) -> "file://" <> Path.expand(input)
      true -> "https://" <> input
    end
  end

  def resolve(base, href) do
    base |> URI.merge(href) |> URI.to_string()
  rescue
    _ -> href
  end

  def load(url), do: load(url, @max_redirects)

  defp load("about:home", _), do: {:ok, @about_home, "about:home"}
  defp load("about:" <> _ = url, _), do: {:ok, "<h1>Unknown page</h1>", url}

  defp load("file://" <> path, _) do
    case File.read(URI.decode(path)) do
      {:ok, body} -> {:ok, body, "file://" <> path}
      {:error, reason} -> {:error, "Cannot read #{path}: #{:file.format_error(reason)}"}
    end
  end

  defp load(_url, 0), do: {:error, "Too many redirects"}

  defp load(url, redirects) do
    request = {String.to_charlist(url), [{~c"user-agent", ~c"ElixirBrowser/0.1"}]}

    http_opts = [
      autoredirect: false,
      timeout: 15_000,
      ssl: [
        verify: :verify_peer,
        cacerts: :public_key.cacerts_get(),
        customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
      ]
    ]

    case :httpc.request(:get, request, http_opts, body_format: :binary) do
      {:ok, {{_, status, _}, headers, _body}} when status in [301, 302, 303, 307, 308] ->
        case List.keyfind(headers, ~c"location", 0) do
          {_, loc} -> load(resolve(url, to_string(loc)), redirects - 1)
          nil -> {:error, "Redirect without Location"}
        end

      {:ok, {{_, status, _}, _headers, body}} when status in 200..299 ->
        {:ok, body, url}

      {:ok, {{_, status, reason}, _, _}} ->
        {:error, "HTTP #{status} #{reason}"}

      {:error, reason} ->
        {:error, "Request failed: #{inspect(reason)}"}
    end
  end
end
