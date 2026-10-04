defmodule Browser.Cookies do
  @moduledoc """
  An in-memory cookie jar (RFC 6265) shared by every request `Browser.Fetch` makes.

  `store/3` takes the `Set-Cookie` headers of a response, `header/2` builds the `Cookie`
  header for a request. Cookies live in a public ETS table owned by this process, keyed by
  `{domain, path, name}`, and last until the browser quits (session cookies and persistent
  ones alike). `Domain`, `Path`, `Expires`, `Max-Age`, `Secure`, `HttpOnly` and `SameSite`
  are parsed.

  Security checks, as in modern browsers:

    * `SameSite`: a cookie without the attribute counts as `Lax`. In a cross-site request
      (the initiator's site differs from the target's, anywhere in a redirect chain) `Strict`
      cookies are neither sent nor set, and `Lax` ones only travel on top-level GET
      navigations. `None` needs `Secure`.
    * the `__Secure-` and `__Host-` name prefixes demand `Secure` (and, for `__Host-`, no
      `Domain` and `Path=/`)
    * `Domain` may not name a public suffix (`Browser.PublicSuffix`) or an IP address
    * an insecure page cannot overwrite a `Secure` cookie
    * size limits, no control characters, and lifetimes capped at 400 days

  Requests describe themselves with `cross_site:` and `navigation:` options, see `header/2`.
  """
  use GenServer

  alias Browser.PublicSuffix

  @table __MODULE__
  @max_per_domain 50
  @max_total 3000
  @max_size 4096
  @max_attr 1024
  @max_age 400 * 86_400

  defmodule Cookie do
    @moduledoc false
    defstruct [
      :name,
      :value,
      :domain,
      :path,
      :expires_at,
      :created_at,
      host_only: true,
      secure: false,
      http_only: false,
      same_site: nil
    ]
  end

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(_) do
    :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
    {:ok, nil}
  end

  @doc "Drops every cookie."
  def clear, do: if(table?(), do: :ets.delete_all_objects(@table))

  @doc "All live cookies."
  def all do
    if table?() do
      now = now()
      for {_, c} <- :ets.tab2list(@table), alive?(c, now), do: c
    else
      []
    end
  end

  @doc """
  Keeps the cookies of the `Set-Cookie` header values `set_cookies` (strings or charlists)
  of a response to `url`. Invalid ones are ignored; an expired one deletes its old self.

  Options: `cross_site: true` when the request was made from another site, `navigation: true`
  for a top-level navigation (together they decide which `SameSite` cookies may be set), and
  `http: false` for `document.cookie` (no `HttpOnly`).
  """
  def store(url, set_cookies, opts \\ []) do
    with true <- table?(),
         %URI{scheme: scheme, host: host} = uri when scheme in ["http", "https"] and host != "" <-
           URI.parse(url) do
      for header <- set_cookies,
          cookie = parse(to_string(header), uri, opts),
          do: put(cookie)
    end

    :ok
  end

  @doc """
  The `Cookie` request header value for `url`, or nil when no cookie applies. `http: false`
  (for `document.cookie`) leaves out `HttpOnly` cookies. `cross_site:`, `navigation:` and
  `method:` (default `:get`) describe the request for `SameSite`, see `store/3`.
  """
  def header(url, opts \\ []) do
    case matching(url, opts) do
      [] -> nil
      cookies -> Enum.map_join(cookies, "; ", &"#{&1.name}=#{&1.value}")
    end
  end

  @doc "The cookies to send with a request for `url`, longest path first, then oldest first."
  def matching(url, opts \\ []) do
    with true <- table?(),
         %URI{host: host} = uri when is_binary(host) <- URI.parse(url),
         true <- uri.scheme in ["http", "https"] do
      host = String.downcase(host)
      path = request_path(uri)
      https? = uri.scheme == "https"
      http? = Keyword.get(opts, :http, true)
      now = now()
      send? = &send_same_site?(&1, opts)

      for {_, c} <- :ets.tab2list(@table),
          alive?(c, now),
          domain_match?(host, c),
          path_match?(path, c.path),
          https? or not c.secure,
          http? or not c.http_only,
          send?.(c) do
        c
      end
      |> Enum.sort_by(&{-String.length(&1.path), &1.created_at})
    else
      _ -> []
    end
  end

  @doc """
  Sets one cookie from the `name=value; attributes` string `header`, as `document.cookie =`
  does for the page at `url`. `HttpOnly` cookies are refused.
  """
  def set_from_script(url, header), do: store(url, [header], http: false)

  # --- parsing ---

  defp parse(header, uri, opts) do
    [pair | attrs] = String.split(header, ";")

    with true <- byte_size(header) <= @max_size,
         [name, value] <- split_pair(pair),
         true <- name != "" or value != "",
         true <- byte_size(name) + byte_size(value) <= @max_size,
         true <- clean?(name) and clean?(value),
         host = String.downcase(uri.host),
         attrs = parse_attrs(attrs),
         true <- Enum.all?(attrs, fn {_, v} -> byte_size(v) <= @max_attr and clean?(v) end),
         {:ok, domain, host_only} <- cookie_domain(attrs["domain"], host),
         secure = Map.has_key?(attrs, "secure"),
         true <- not secure or uri.scheme == "https",
         same_site = same_site(attrs["samesite"]),
         true <- same_site != :none or secure,
         path = cookie_path(attrs["path"], uri),
         true <- prefix_ok?(name, value, secure, host_only, path, attrs),
         true <- not insecure_overwrite?(uri, domain, name, path),
         http_only = Map.has_key?(attrs, "httponly"),
         true <- Keyword.get(opts, :http, true) or not http_only,
         true <- same_site_may_set?(same_site, opts) do
      %Cookie{
        name: name,
        value: value,
        domain: domain,
        host_only: host_only,
        path: path,
        expires_at: expiry(attrs),
        created_at: System.monotonic_time(),
        secure: secure,
        http_only: http_only,
        same_site: same_site
      }
    else
      _ -> nil
    end
  end

  defp split_pair(pair) do
    case String.split(pair, "=", parts: 2) do
      [value] -> if String.trim(value) == "", do: :error, else: ["", String.trim(value)]
      [name, value] -> [String.trim(name), String.trim(value)]
    end
  end

  # lowercased attribute name => value (last one wins)
  defp parse_attrs(attrs) do
    for attr <- attrs, into: %{} do
      case String.split(attr, "=", parts: 2) do
        [k] -> {k |> String.trim() |> String.downcase(), ""}
        [k, v] -> {k |> String.trim() |> String.downcase(), String.trim(v)}
      end
    end
  end

  # no control characters (a `;` or `=` cannot occur: they split the header first)
  defp clean?(str), do: not String.match?(str, ~r/[\x00-\x08\x0A-\x1F\x7F]/)

  # `__Secure-` and `__Host-` (any case); a nameless cookie's value is checked as the name
  defp prefix_ok?(name, value, secure, host_only, path, attrs) do
    name = String.downcase(if name == "", do: value, else: name)

    cond do
      String.starts_with?(name, "__host-") ->
        secure and host_only and path == "/" and not Map.has_key?(attrs, "domain")

      String.starts_with?(name, "__secure-") ->
        secure

      true ->
        true
    end
  end

  # a page on http cannot replace or shadow a Secure cookie of the same name
  defp insecure_overwrite?(%URI{scheme: "https"}, _domain, _name, _path), do: false

  defp insecure_overwrite?(_uri, domain, name, path) do
    overlap = fn a, b ->
      a == b or String.ends_with?(a, "." <> b) or String.ends_with?(b, "." <> a)
    end

    Enum.any?(:ets.tab2list(@table), fn {_, c} ->
      c.secure and c.name == name and alive?(c, now()) and overlap.(c.domain, domain) and
        (path_match?(path, c.path) or path_match?(c.path, path))
    end)
  end

  # SameSite on the way out: unset counts as Lax
  defp send_same_site?(%Cookie{same_site: same_site}, opts) do
    if Keyword.get(opts, :cross_site, false) do
      case same_site || :lax do
        :none -> true
        :strict -> false
        :lax -> Keyword.get(opts, :navigation, false) and Keyword.get(opts, :method, :get) == :get
      end
    else
      true
    end
  end

  # SameSite on the way in: a cross-site response sets only None cookies, plus Lax ones when
  # it answers a top-level navigation
  defp same_site_may_set?(same_site, opts) do
    if Keyword.get(opts, :cross_site, false) do
      case same_site || :lax do
        :none -> true
        :strict -> false
        :lax -> Keyword.get(opts, :navigation, false)
      end
    else
      true
    end
  end

  @doc """
  Whether `a` and `b` (URLs) are the same site: same scheme and registrable domain.
  """
  def same_site?(a, b) do
    with %URI{scheme: sa, host: ha} when is_binary(ha) <- URI.parse(a),
         %URI{scheme: sb, host: hb} when is_binary(hb) <- URI.parse(b) do
      sa == sb and PublicSuffix.registrable(ha) == PublicSuffix.registrable(hb)
    else
      _ -> false
    end
  end

  defp cookie_domain(nil, host), do: {:ok, host, true}
  defp cookie_domain("", host), do: {:ok, host, true}

  defp cookie_domain(domain, host) do
    domain = domain |> String.trim_leading(".") |> String.downcase()

    cond do
      domain == host and PublicSuffix.public_suffix?(domain) -> {:ok, host, true}
      domain == host -> {:ok, host, false}
      PublicSuffix.public_suffix?(domain) -> :error
      ip?(host) -> :error
      String.ends_with?(host, "." <> domain) -> {:ok, domain, false}
      true -> :error
    end
  end

  defp cookie_path("/" <> _ = path, _uri), do: path
  defp cookie_path(_, uri), do: default_path(request_path(uri))

  defp default_path(path) do
    case path |> String.split("/") |> Enum.drop(-1) |> Enum.join("/") do
      "" -> "/"
      dir -> dir
    end
  end

  defp request_path(%URI{path: path}) when path in [nil, ""], do: "/"
  defp request_path(%URI{path: path}), do: path

  # Max-Age beats Expires; a non-positive Max-Age expires the cookie at once
  defp expiry(%{"max-age" => max_age} = attrs) do
    case Integer.parse(max_age) do
      {n, ""} -> if n <= 0, do: 0, else: now() + min(n, @max_age)
      _ -> expiry(Map.delete(attrs, "max-age"))
    end
  end

  defp expiry(%{"expires" => date}) do
    case parse_date(date) do
      nil -> nil
      at -> min(at, now() + @max_age)
    end
  end

  defp expiry(_), do: nil

  defp same_site(nil), do: nil

  defp same_site(v) do
    case String.downcase(v) do
      "strict" -> :strict
      "lax" -> :lax
      "none" -> :none
      _ -> nil
    end
  end

  @months ~w(jan feb mar apr may jun jul aug sep oct nov dec)

  @doc false
  # RFC 6265 5.1.1, loosely: find a time, a day of the month, a month and a year anywhere.
  def parse_date(str) do
    tokens = String.split(str, ~r/[^0-9A-Za-z:]+/, trim: true)

    time = Enum.find_value(tokens, &time_token/1)
    month = Enum.find_value(tokens, &month_token/1)
    day_i = Enum.find_index(tokens, &num_token(&1, 1..2))
    day = day_i && num_token(Enum.at(tokens, day_i), 1..2)

    year =
      tokens
      |> Enum.with_index()
      |> Enum.find_value(fn {t, i} -> if i != day_i, do: num_token(t, 2..4) end)

    with {h, m, s} <- time, true <- month != nil and day != nil and year != nil do
      year = if year in 70..99, do: year + 1900, else: if(year < 70, do: year + 2000, else: year)

      if day in 1..31 and year >= 1601 and h < 24 and m < 60 and s < 60 and
           day <= :calendar.last_day_of_the_month(year, month) do
        secs = :calendar.datetime_to_gregorian_seconds({{year, month, day}, {h, m, s}})
        max(secs - 62_167_219_200, 0)
      else
        0
      end
    else
      _ -> nil
    end
  end

  defp time_token(t) do
    case Regex.run(~r/^(\d{1,2}):(\d{1,2}):(\d{1,2})/, t) do
      [_, h, m, s] -> {String.to_integer(h), String.to_integer(m), String.to_integer(s)}
      _ -> nil
    end
  end

  defp month_token(t) do
    prefix = t |> String.slice(0, 3) |> String.downcase()
    if i = Enum.find_index(@months, &(&1 == prefix)), do: i + 1
  end

  defp num_token(t, len) do
    if Regex.match?(~r/^\d+$/, t) and String.length(t) in len, do: String.to_integer(t)
  end

  # --- matching ---

  defp domain_match?(host, %Cookie{host_only: true, domain: domain}), do: host == domain

  defp domain_match?(host, %Cookie{domain: domain}),
    do: host == domain or String.ends_with?(host, "." <> domain)

  defp path_match?(path, cpath) do
    path == cpath or
      (String.starts_with?(path, cpath) and
         (String.ends_with?(cpath, "/") or String.at(path, String.length(cpath)) == "/"))
  end

  defp ip?(host), do: match?({:ok, _}, :inet.parse_address(String.to_charlist(host)))

  # --- storage ---

  defp put(%Cookie{} = c) do
    key = {c.domain, c.host_only, c.path, c.name}

    case :ets.lookup(@table, key) do
      [{_, old}] -> :ets.insert(@table, {key, %{c | created_at: old.created_at}})
      [] -> :ets.insert(@table, {key, c})
    end

    if expired?(c), do: :ets.delete(@table, key), else: evict(c.domain)
  end

  # keep the jar bounded: oldest cookies of a crowded domain go first, then the oldest overall
  defp evict(domain) do
    now = now()

    for {k, c} <- :ets.tab2list(@table), not alive?(c, now), do: :ets.delete(@table, k)

    trim(fn {_, c} -> c.domain == domain end, @max_per_domain)
    trim(fn _ -> true end, @max_total)
  end

  defp trim(filter, max) do
    rows = :ets.tab2list(@table) |> Enum.filter(filter)

    if length(rows) > max do
      rows
      |> Enum.sort_by(fn {_, c} -> c.created_at end)
      |> Enum.take(length(rows) - max)
      |> Enum.each(fn {k, _} -> :ets.delete(@table, k) end)
    end
  end

  defp alive?(c, now), do: not expired?(c, now)
  defp expired?(c, now \\ now()), do: c.expires_at != nil and c.expires_at <= now

  defp now, do: System.os_time(:second)
  defp table?, do: :ets.whereis(@table) != :undefined
end
