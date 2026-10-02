defmodule Browser.HttpCache do
  @moduledoc """
  An in-memory HTTP cache for GET responses, shared by pages, stylesheets and images.

  Entries live in a public ETS table owned by this process, keyed by URL. `lookup/2` says
  whether an entry can be used as is (`{:fresh, entry}`), must be revalidated with the
  server (`{:stale, entry}`) or is absent (`:miss`). `store/3` decides from the response
  headers whether and for how long a response may be kept (`Cache-Control`, `Expires`,
  `ETag`, `Last-Modified`); `refresh/3` renews an entry after a 304.
  """
  use GenServer

  @table __MODULE__
  @max_entries 256
  @max_bytes 64 * 1024 * 1024
  # a single response above this is not worth keeping
  @max_entry_bytes 8 * 1024 * 1024

  defmodule Entry do
    @moduledoc false
    defstruct [:url, :body, :etag, :last_modified, :expires_at, :used_at]
  end

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(_) do
    :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
    {:ok, nil}
  end

  @doc "Drops everything."
  def clear, do: if(table?(), do: :ets.delete_all_objects(@table))

  @doc """
  The cached entry for `url`: `{:fresh, entry}`, `{:stale, entry}` or `:miss`.

  With `use_stale: true` (going back or forward) any entry counts as fresh.
  """
  def lookup(url, opts \\ []) do
    with true <- table?(),
         [{_, entry}] <- :ets.lookup(@table, url) do
      :ets.update_element(@table, url, {2, %{entry | used_at: now()}})

      if Keyword.get(opts, :use_stale, false) or entry.expires_at > now(),
        do: {:fresh, entry},
        else: {:stale, entry}
    else
      _ -> :miss
    end
  end

  @doc """
  Keeps the (decoded) `body` of a 200 response if its `headers` allow it. Responses with
  `no-store`, `private` or `Vary: *`, and ones with neither a lifetime nor a validator,
  are not kept (and replace nothing: any old entry for the URL is dropped).
  """
  def store(url, headers, body) do
    if table?() do
      cc = cache_control(headers)
      etag = header(headers, "etag")
      last_modified = header(headers, "last-modified")

      cond do
        not storable?(headers, cc, body) or
            (is_nil(etag) and is_nil(last_modified) and
               lifetime(headers, cc) in [nil, 0]) ->
          :ets.delete(@table, url)

        true ->
          evict_for(byte_size(body))

          :ets.insert(
            @table,
            {url,
             %Entry{
               url: url,
               body: body,
               etag: etag,
               last_modified: last_modified,
               expires_at: now() + (lifetime(headers, cc) || 0),
               used_at: now()
             }}
          )
      end
    end

    :ok
  end

  @doc "A 304 for a stale `entry`: keeps its body, takes the new lifetime and validators."
  def refresh(entry, headers, url) do
    if table?() do
      cc = cache_control(headers)

      entry = %{
        entry
        | etag: header(headers, "etag") || entry.etag,
          last_modified: header(headers, "last-modified") || entry.last_modified,
          expires_at: now() + (lifetime(headers, cc) || 0),
          used_at: now()
      }

      if storable?(headers, cc, entry.body),
        do: :ets.insert(@table, {url, entry}),
        else: :ets.delete(@table, url)
    end

    :ok
  end

  @doc "The conditional-request headers that revalidate `entry`."
  def validators(entry) do
    for {name, value} <- [
          {~c"if-none-match", entry.etag},
          {~c"if-modified-since", entry.last_modified}
        ],
        value != nil,
        do: {name, String.to_charlist(value)}
  end

  # -- policy --------------------------------------------------------------------

  defp storable?(headers, cc, body) do
    byte_size(body) <= @max_entry_bytes and not Map.has_key?(cc, "no-store") and
      not Map.has_key?(cc, "private") and header(headers, "vary") != "*"
  end

  # seconds the response stays fresh: max-age, else Expires - Date, else nil;
  # `no-cache` means always revalidate
  defp lifetime(_headers, %{"no-cache" => _}), do: 0

  defp lifetime(headers, cc) do
    case cc do
      %{"max-age" => v} ->
        case Integer.parse(v) do
          {n, _} -> max(n, 0)
          :error -> 0
        end

      _ ->
        with exp when exp != nil <- header(headers, "expires"),
             {:ok, exp} <- parse_date(exp) do
          date =
            with d when d != nil <- header(headers, "date"), {:ok, d} <- parse_date(d) do
              d
            else
              _ -> :calendar.universal_time() |> :calendar.datetime_to_gregorian_seconds()
            end

          max(exp - date, 0)
        else
          _ -> nil
        end
    end
  end

  defp parse_date(str) do
    case :httpd_util.convert_request_date(String.to_charlist(str)) do
      :bad_date -> :error
      datetime -> {:ok, :calendar.datetime_to_gregorian_seconds(datetime)}
    end
  end

  defp cache_control(headers) do
    (header(headers, "cache-control") || "")
    |> String.downcase()
    |> String.split(",", trim: true)
    |> Map.new(fn directive ->
      case String.split(String.trim(directive), "=", parts: 2) do
        [k, v] -> {k, String.trim(v, "\"")}
        [k] -> {k, true}
      end
    end)
  end

  defp header(headers, name) do
    case List.keyfind(headers, String.to_charlist(name), 0) do
      {_, v} -> to_string(v)
      nil -> nil
    end
  end

  # -- eviction ------------------------------------------------------------------

  # make room for `incoming` bytes: drop the least recently used entries
  defp evict_for(incoming) do
    entries = :ets.tab2list(@table)
    bytes = Enum.reduce(entries, incoming, fn {_, e}, n -> n + byte_size(e.body) end)

    if length(entries) >= @max_entries or bytes > @max_bytes do
      entries
      |> Enum.sort_by(fn {_, e} -> e.used_at end)
      |> Enum.reduce_while({length(entries), bytes}, fn {url, e}, {count, bytes} ->
        if count < @max_entries and bytes <= @max_bytes do
          {:halt, nil}
        else
          :ets.delete(@table, url)
          {:cont, {count - 1, bytes - byte_size(e.body)}}
        end
      end)
    end
  end

  defp now, do: System.monotonic_time(:second)
  defp table?, do: :ets.whereis(@table) != :undefined
end
