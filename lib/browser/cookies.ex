defmodule Browser.Cookies do
  @moduledoc """
  An in-memory cookie jar (RFC 6265) shared by every request `Browser.Fetch` makes.

  `store/3` takes the `Set-Cookie` headers of a response, `header/2` builds the `Cookie`
  header for a request. Cookies live in a public ETS table owned by this process, keyed by
  `{domain, path, name}`, and last until the browser quits (session cookies and persistent
  ones alike). `Domain`, `Path`, `Expires`, `Max-Age`, `Secure`, `HttpOnly` and `SameSite`
  are parsed; `SameSite` is kept but not enforced, as requests do not know their initiator.
  """
  use GenServer

  @table __MODULE__
  @max_per_domain 50
  @max_total 3000
  @max_size 4096

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
  (for `document.cookie`) leaves out `HttpOnly` cookies.
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

      for {_, c} <- :ets.tab2list(@table),
          alive?(c, now),
          domain_match?(host, c),
          path_match?(path, c.path),
          https? or not c.secure,
          http? or not c.http_only do
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
         host = String.downcase(uri.host),
         attrs = parse_attrs(attrs),
         {:ok, domain, host_only} <- cookie_domain(attrs["domain"], host),
         secure = Map.has_key?(attrs, "secure"),
         true <- not secure or uri.scheme == "https",
         http_only = Map.has_key?(attrs, "httponly"),
         true <- Keyword.get(opts, :http, true) or not http_only do
      %Cookie{
        name: name,
        value: value,
        domain: domain,
        host_only: host_only,
        path: cookie_path(attrs["path"], uri),
        expires_at: expiry(attrs),
        created_at: System.monotonic_time(),
        secure: secure,
        http_only: http_only,
        same_site: same_site(attrs["samesite"])
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

  defp cookie_domain(nil, host), do: {:ok, host, true}
  defp cookie_domain("", host), do: {:ok, host, true}

  defp cookie_domain(domain, host) do
    domain = domain |> String.trim_leading(".") |> String.downcase()

    cond do
      domain == host -> {:ok, host, false}
      # no public suffix list: a bare "com" is the one thing we can spot
      not String.contains?(domain, ".") -> :error
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
      {n, ""} -> if n <= 0, do: 0, else: now() + n
      _ -> expiry(Map.delete(attrs, "max-age"))
    end
  end

  defp expiry(%{"expires" => date}), do: parse_date(date)
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
