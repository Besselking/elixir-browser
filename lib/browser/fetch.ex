defmodule Browser.Fetch do
  @moduledoc "Loads a URL into `{:ok, body, final_url}`."

  @max_redirects 8

  # the pages in priv/demo, with what each one shows
  @demos [
    {"sample.html", "Sample", "headings, links, lists, preformatted text"},
    {"boxes.html", "Boxes", "borders, widths and centering"},
    {"rounded.html", "Rounded corners", "border-radius"},
    {"backgrounds.html", "Backgrounds and shadows", "images, gradients and box-shadow"},
    {"positioning.html", "Positioning", "absolute and fixed boxes, clipping"},
    {"lineheight.html", "Line height", "line-height and inline boxes"},
    {"hidden.html", "Hidden elements", "display, visibility and hidden content"},
    {"images.html", "Images", "PNG, JPEG, GIF, BMP and TIFF pictures"},
    {"svg.html", "SVG", "inline and linked vector graphics"},
    {"forms.html", "Form controls", "inputs, selects, buttons and text selection"},
    {"selects.html", "Selects", "clipped dropdowns"},
    {"tables.html", "Tables", "borders, spans, collapsing, alignment, nesting"},
    {"floats.html", "Floats", "text flowing around floated boxes, clear, containment"},
    {"margins.html", "Margins", "negative margins, collapsing, percentage margins and padding"},
    {"transforms.html", "Transforms", "rotate, scale, skew, translate and transform-origin"},
    {"sticky.html", "Sticky and fixed",
     "a header and a heading that stay in the window, a fixed badge"},
    {"wide.html", "Wide content", "pages wider than the window scroll sideways"}
  ]

  @doc "The start page: a few sites, and the demo pages that ship with the browser."
  def about_home do
    dir = Application.app_dir(:browser, "priv/demo")

    demos =
      for {file, title, what} <- @demos, File.exists?(Path.join(dir, file)) do
        url = "file://" <> URI.encode(Path.join(dir, file))
        ~s|<li><a href="#{url}">#{title}</a> &ndash; #{what}</li>\n|
      end

    """
    <html><head><title>Elixir Browser</title></head><body>
    <h1>Elixir Browser</h1>
    <p>A tiny browser written in Elixir. Type a URL above and press Enter.</p>
    <h2>Sites</h2>
    <ul>
    <li><a href="https://example.com">example.com</a></li>
    <li><a href="http://info.cern.ch">info.cern.ch</a> (the first website)</li>
    <li><a href="https://elixir-lang.org">elixir-lang.org</a></li>
    <li><a href="https://html.duckduckgo.com/html/">html.duckduckgo.com</a> (search, no JavaScript)</li>
    </ul>
    <h2>Demo pages</h2>
    <p>Pages that exercise what the browser can draw.</p>
    <ul>
    #{demos}</ul>
    </body></html>
    """
  end

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

  @doc """
  Loads `url` into `{:ok, body, final_url}` or `{:error, message}`.

  Options: `method: :get | :post` (default `:get`) and `body:` (a urlencoded form, for
  POST). After a 301/302/303 redirect the request becomes a GET, as browsers do; 307
  and 308 repeat the same request.
  """
  def load(url, opts \\ []),
    do: fetch(url, Keyword.get(opts, :method, :get), Keyword.get(opts, :body), @max_redirects)

  defp fetch("about:home", _, _, _), do: {:ok, about_home(), "about:home"}
  defp fetch("about:" <> _ = url, _, _, _), do: {:ok, "<h1>Unknown page</h1>", url}

  defp fetch("file://" <> path, _, _, _) do
    case File.read(URI.decode(path)) do
      {:ok, body} -> {:ok, body, "file://" <> path}
      {:error, reason} -> {:error, "Cannot read #{path}: #{:file.format_error(reason)}"}
    end
  end

  defp fetch(_url, _method, _body, 0), do: {:error, "Too many redirects"}

  defp fetch(url, method, body, redirects) do
    headers = [{~c"user-agent", ~c"ElixirBrowser/0.1"}]

    request =
      case method do
        :post ->
          {String.to_charlist(url), headers, ~c"application/x-www-form-urlencoded", body || ""}

        _ ->
          {String.to_charlist(url), headers}
      end

    http_opts = [
      autoredirect: false,
      timeout: 15_000,
      ssl: [
        verify: :verify_peer,
        cacerts: :public_key.cacerts_get(),
        customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
      ]
    ]

    case :httpc.request(method, request, http_opts, body_format: :binary) do
      {:ok, {{_, status, _}, headers, _body}} when status in [301, 302, 303, 307, 308] ->
        case List.keyfind(headers, ~c"location", 0) do
          {_, loc} ->
            next = resolve(url, to_string(loc))

            if status in [307, 308],
              do: fetch(next, method, body, redirects - 1),
              else: fetch(next, :get, nil, redirects - 1)

          nil ->
            {:error, "Redirect without Location"}
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
