defmodule Browser.Fetch do
  @moduledoc "Loads a URL into `{:ok, body, final_url}`."

  alias Browser.{Cookies, HttpCache}

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
    {"fonts.html", "Fonts", "font-family lists: generic families and installed fonts"},
    {"whitespace.html", "White space", "normal, nowrap, pre, pre-wrap and pre-line"},
    {"script.html", "Scripts", "JavaScript modules, events, the DOM, forms, history"},
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

  defp pad_base64(s), do: s <> String.duplicate("=", rem(4 - rem(byte_size(s), 4), 4))

  # Sites send the page a browser gets to what the user agent says it is. Naming only ourselves
  # earns the plain, scriptless fallback page of some of them.
  @user_agent "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36 ElixirBrowser/0.1"

  @doc "The `User-Agent` of requests, and of `navigator.userAgent`."
  def user_agent, do: @user_agent

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

  GET responses go through `Browser.HttpCache`. `cache:` is `:normal` (the default: use
  fresh entries, revalidate stale ones), `:reload` (always ask the server, revalidating
  with `ETag`/`Last-Modified`) or `:history` (back/forward: use any cached entry).

  `full: true` is for scripts (`fetch`, `XMLHttpRequest`): every status that is not a
  redirect comes back, errors included, as `{:ok, response, final_url}` where `response` is
  `%{status:, status_text:, headers: [{name, value}], body:, url:, redirected:}` (header
  names lower-cased, `Set-Cookie` left out), and the cache is not consulted. They may also
  give `method:` (`:get`, `:head`, `:post`, `:put`, `:patch`, `:delete`, `:options`),
  `headers:` (`[{name, value}]`, forbidden names dropped), `content_type:` for a body and
  `credentials: :omit | :same_origin | :include` (default `:same_origin`).

  Cookies follow `Browser.Cookies`. For `SameSite`, `initiator:` is the URL of the page making
  the request (nil for the address bar and reloads, which are never cross-site) and
  `navigation: true` marks a top-level navigation. A redirect chain is cross-site once any
  hop is.

  `on_chunk:` is a `fn text, url -> any end` called, in the calling process, with each
  piece of a GET response as it arrives (already gunzipped) and the URL it came from,
  so a caller can start on a document before it is complete. Cached responses arrive
  whole and call it never.
  """
  def load(url, opts \\ []) do
    # a fragment is for the browser, not the server: the page is the same with or without it
    {url, fragment} = split_fragment(url)

    result =
      fetch(
        url,
        Keyword.get(opts, :method, :get),
        Keyword.get(opts, :body),
        @max_redirects,
        %{
          cache: Keyword.get(opts, :cache, :normal),
          on_chunk: opts[:on_chunk],
          initiator: opts[:initiator],
          navigation: Keyword.get(opts, :navigation, false),
          cross_site: false,
          full: Keyword.get(opts, :full, false),
          headers: Keyword.get(opts, :headers, []),
          content_type: opts[:content_type],
          credentials: Keyword.get(opts, :credentials, :same_origin)
        }
      )

    case result do
      {:ok, body, final} when fragment != nil -> {:ok, body, put_fragment(final, fragment)}
      other -> other
    end
  end

  @doc "`{url without its fragment, fragment or nil}`."
  def split_fragment(url) do
    case :binary.split(url, "#") do
      [base, fragment] -> {base, fragment}
      [base] -> {base, nil}
    end
  end

  defp put_fragment(url, fragment) do
    case split_fragment(url) do
      {base, nil} -> base <> "#" <> fragment
      _ -> url
    end
  end

  defp fetch("about:home", _, _, _, _), do: {:ok, about_home(), "about:home"}
  defp fetch("about:" <> _ = url, _, _, _, _), do: {:ok, "<h1>Unknown page</h1>", url}

  # `data:[<mediatype>][;base64],<data>`
  defp fetch("data:" <> rest = url, _, _, _, _) do
    case :binary.split(rest, ",") do
      [meta, payload] ->
        body =
          if String.ends_with?(meta, ";base64") do
            payload
            |> URI.decode()
            |> String.replace(~r/\s+/, "")
            |> pad_base64()
            |> Base.decode64(ignore_whitespace: true)
          else
            {:ok, URI.decode(payload)}
          end

        case body do
          {:ok, text} -> {:ok, text, url}
          :error -> {:error, "Bad data: URL"}
        end

      _ ->
        {:error, "Bad data: URL"}
    end
  end

  defp fetch("file://" <> path, _, _, _, _) do
    case File.read(URI.decode(path)) do
      {:ok, body} -> {:ok, body, "file://" <> path}
      {:error, reason} -> {:error, "Cannot read #{path}: #{:file.format_error(reason)}"}
    end
  end

  defp fetch(_url, _method, _body, 0, _cache), do: {:error, "Too many redirects"}

  defp fetch(url, :get, body, redirects, %{full: false, cache: cache} = ctx) do
    case lookup(url, cache) do
      {:fresh, entry} when cache != :reload -> {:ok, entry.body, url}
      {_, entry} -> request(url, :get, body, redirects, ctx, entry)
      :miss -> request(url, :get, body, redirects, ctx, nil)
    end
  end

  defp fetch(url, method, body, redirects, ctx),
    do: request(url, method, body, redirects, ctx, nil)

  defp lookup(url, :history), do: HttpCache.lookup(url, use_stale: true)
  defp lookup(url, _), do: HttpCache.lookup(url)

  # `entry`: a stale cached response to revalidate, or nil
  defp request(url, method, body, redirects, ctx, entry) do
    ctx = %{ctx | cross_site: ctx.cross_site or cross_site?(ctx.initiator, url)}
    cookie_opts = [cross_site: ctx.cross_site, navigation: ctx.navigation, method: method]
    cookies? = send_cookies?(ctx, url)

    headers =
      [{~c"user-agent", String.to_charlist(user_agent())}, {~c"accept-encoding", ~c"gzip"}] ++
        script_headers(ctx, method) ++
        if(cookies?, do: cookie_header(url, cookie_opts), else: []) ++
        if(entry, do: HttpCache.validators(entry), else: [])

    request = build_request(url, method, body, headers, ctx)

    http_opts = [
      autoredirect: false,
      timeout: 15_000,
      ssl: [
        verify: :verify_peer,
        cacerts: :public_key.cacerts_get(),
        customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
      ]
    ]

    result =
      if method == :get and ctx.on_chunk,
        do: stream_get(request, http_opts, url, ctx.on_chunk),
        else: :httpc.request(method, request, http_opts, body_format: :binary)

    with true <- cookies?, {:ok, {_, resp_headers, _}} <- result do
      store_cookies(url, resp_headers, cookie_opts)
    end

    case result do
      {:ok, {{_, 304, _}, headers, _body}} when entry != nil ->
        HttpCache.refresh(entry, headers, url)
        {:ok, entry.body, url}

      {:ok, {{_, status, _}, headers, _body}} when status in [301, 302, 303, 307, 308] ->
        case List.keyfind(headers, ~c"location", 0) do
          {_, loc} ->
            next = resolve(url, to_string(loc))

            new = if status in [307, 308], do: method, else: redirect_method(method, status)
            fetch(next, new, if(new == method, do: body), redirects - 1, ctx)

          nil ->
            {:error, "Redirect without Location"}
        end

      {:ok, {{_, status, reason}, headers, body}} when ctx.full ->
        with {:ok, body, _} <- decode_body(headers, body, url) do
          {:ok,
           %{
             status: status,
             status_text: to_string(reason),
             headers: response_headers(headers),
             body: to_text(body),
             url: url,
             redirected: redirects < @max_redirects
           }, url}
        end

      {:ok, {{_, 200, _}, headers, body}} ->
        with {:ok, body, _} = ok <- decode_body(headers, body, url) do
          if method == :get, do: HttpCache.store(url, headers, body)
          ok
        end

      {:ok, {{_, status, _}, headers, body}} when status in 201..299 ->
        decode_body(headers, body, url)

      {:ok, {{_, status, reason}, _, _}} ->
        {:error, "HTTP #{status} #{reason}"}

      {:error, reason} ->
        {:error, "Request failed: #{inspect(reason)}"}
    end
  end

  # 301/302 turn a POST into a GET and 303 turns anything but HEAD into a GET
  defp redirect_method(:head, _), do: :head
  defp redirect_method(:post, _), do: :get
  defp redirect_method(method, 303) when method != :get, do: :get
  defp redirect_method(method, _), do: method

  defp build_request(url, method, body, headers, ctx) do
    if method in [:post, :put, :patch] or (method == :delete and body != nil) do
      ctype = String.to_charlist(ctx.content_type || "application/x-www-form-urlencoded")
      {String.to_charlist(url), headers, ctype, body || ""}
    else
      {String.to_charlist(url), headers}
    end
  end

  # Request headers a script may not set (the browser owns them)
  @forbidden ~w(accept-encoding connection content-length content-type cookie cookie2 host
                origin referer te trailer transfer-encoding upgrade via user-agent)

  # `fetch` and `XMLHttpRequest` headers, plus the `Origin` a browser adds to cross-site and
  # non-GET requests and a default `Accept`
  defp script_headers(%{full: false}, _method), do: []

  defp script_headers(ctx, method) do
    custom =
      for {k, v} <- ctx.headers,
          name = k |> to_string() |> String.downcase(),
          name not in @forbidden and not String.starts_with?(name, "proxy-") and
            not String.starts_with?(name, "sec-"),
          do: {String.to_charlist(name), String.to_charlist(to_string(v))}

    accept = if List.keymember?(custom, ~c"accept", 0), do: [], else: [{~c"accept", ~c"*/*"}]

    origin =
      case origin(ctx.initiator) do
        nil -> []
        o when method != :get and method != :head -> [{~c"origin", String.to_charlist(o)}]
        o -> if ctx.cross_site, do: [{~c"origin", String.to_charlist(o)}], else: []
      end

    custom ++ accept ++ origin
  end

  defp origin(nil), do: nil

  defp origin(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host, port: port}
      when scheme in ["http", "https"] and host != nil ->
        default = if scheme == "https", do: 443, else: 80
        scheme <> "://" <> host <> if(port in [nil, default], do: "", else: ":#{port}")

      _ ->
        nil
    end
  end

  # navigations and page loads always carry cookies; `credentials` is for scripts
  defp send_cookies?(%{full: false}, _url), do: true
  defp send_cookies?(%{credentials: :omit}, _url), do: false

  defp send_cookies?(%{credentials: :same_origin, initiator: initiator}, url)
       when initiator != nil,
       do: origin(initiator) == origin(url)

  defp send_cookies?(_ctx, _url), do: true

  # lower-cased names, no `Set-Cookie` (scripts never see it)
  defp response_headers(headers) do
    for {k, v} <- headers,
        name = k |> to_string() |> String.downcase(),
        name not in ["set-cookie", "set-cookie2"],
        do: {name, to_string(v)}
  end

  # a body that is not UTF-8 is read as Latin-1, as a script that asks for text would
  defp to_text(body) do
    if String.valid?(body),
      do: body,
      else: :unicode.characters_to_binary(body, :latin1, :utf8)
  end

  defp cross_site?(nil, _url), do: false
  defp cross_site?(initiator, url), do: not Cookies.same_site?(initiator, url)

  defp cookie_header(url, opts) do
    case Cookies.header(url, opts) do
      nil -> []
      value -> [{~c"cookie", String.to_charlist(value)}]
    end
  end

  # every response may set cookies, redirects and errors included
  defp store_cookies(url, headers, opts) do
    case for({k, v} <- headers, k == ~c"set-cookie", do: v) do
      [] -> :ok
      set_cookies -> Cookies.store(url, set_cookies, opts)
    end
  end

  # A GET answered in pieces: each is handed to `on_chunk` (gunzipped on the side) while the
  # raw body is collected, so the result looks like a plain `:httpc.request` reply.
  # Anything but a 200 is not streamed by httpc and arrives whole.
  defp stream_get(request, http_opts, url, on_chunk) do
    case :httpc.request(:get, request, http_opts,
           sync: false,
           stream: :self,
           body_format: :binary
         ) do
      {:ok, ref} -> stream_loop(ref, url, on_chunk, nil, [], nil)
      {:error, _} = err -> err
    end
  end

  defp stream_loop(ref, url, on_chunk, z, acc, headers) do
    receive do
      {:http, {^ref, :stream_start, hs}} ->
        z =
          case List.keyfind(hs, ~c"content-encoding", 0) do
            {_, enc} when enc in [~c"gzip", ~c"x-gzip"] ->
              z = :zlib.open()
              :zlib.inflateInit(z, 31)
              z

            _ ->
              nil
          end

        stream_loop(ref, url, on_chunk, z, acc, hs)

      {:http, {^ref, :stream, chunk}} ->
        notify(on_chunk, z, chunk, url)
        stream_loop(ref, url, on_chunk, z, [acc | chunk], headers)

      {:http, {^ref, :stream_end, hs}} ->
        z && :zlib.close(z)
        {:ok, {{~c"HTTP/1.1", 200, ~c"OK"}, headers ++ hs, IO.iodata_to_binary(acc)}}

      {:http, {^ref, {:error, reason}}} ->
        z && :zlib.close(z)
        {:error, reason}

      {:http, {^ref, {_status, _headers, _body} = whole}} ->
        {:ok, whole}
    after
      20_000 ->
        :httpc.cancel_request(ref)
        z && :zlib.close(z)
        {:error, :timeout}
    end
  end

  defp notify(on_chunk, nil, chunk, url), do: on_chunk.(chunk, url)

  defp notify(on_chunk, z, chunk, url) do
    on_chunk.(IO.iodata_to_binary(:zlib.inflate(z, chunk)), url)
  rescue
    _ -> :ok
  end

  # servers send gzip when asked: several times fewer bytes for HTML and CSS
  defp decode_body(headers, body, url) do
    case List.keyfind(headers, ~c"content-encoding", 0) do
      {_, enc} when enc in [~c"gzip", ~c"x-gzip"] ->
        try do
          {:ok, :zlib.gunzip(body), url}
        rescue
          _ -> {:error, "Bad gzip data"}
        end

      _ ->
        {:ok, body, url}
    end
  end
end
