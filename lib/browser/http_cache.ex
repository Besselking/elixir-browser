defmodule Browser.HttpCache do
  @moduledoc """
  An in-memory HTTP cache for GET responses, shared by pages, stylesheets and images.

  Entries live in a public ETS table owned by this process, keyed by URL. `lookup/2` says
  whether an entry can be used as is (`{:fresh, entry}`), must be revalidated with the
  server (`{:stale, entry}`) or is absent (`:miss`). `store/3` decides from the response
  headers whether and for how long a response may be kept (`Cache-Control`, `Expires`,
  `ETag`, `Last-Modified`); `refresh/3` renews an entry after a 304.

  Under the memory layer sits a disk layer that survives restarts. Every stored response is
  also written (by this process, in the background) to a file in the cache folder, except
  ones with `Set-Cookie`. A memory miss reads the file and puts the entry back in memory.
  The folder is config `:disk_cache_dir`, else `http_cache/` under the user cache folder;
  `nil` turns the disk layer off. When the files together pass 256 MB, the ones used least
  recently go first (a file's modification time is its last use).
  """
  use GenServer

  @table __MODULE__
  @max_entries 256
  @max_bytes 64 * 1024 * 1024
  # a single response above this is not worth keeping
  @max_entry_bytes 8 * 1024 * 1024
  @max_disk_bytes 256 * 1024 * 1024
  # prune the folder after this many writes
  @prune_every 32

  defmodule Entry do
    @moduledoc false
    defstruct [:url, :body, :etag, :last_modified, :expires_at, :used_at, :content_type]
  end

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(_) do
    :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
    {:ok, 0}
  end

  @impl true
  def handle_cast({:write, dir, url, record}, writes) do
    write_file(dir, url, record)
    writes = writes + 1

    if rem(writes, @prune_every) == 0,
      do: prune_dir(dir)

    {:noreply, writes}
  end

  def handle_cast({:delete, dir, url}, writes) do
    File.rm(file(dir, url))
    {:noreply, writes}
  end

  @impl true
  def handle_call(:sync, _from, writes), do: {:reply, :ok, writes}

  def handle_call({:prune, dir, cap}, _from, writes) do
    prune_dir(dir, cap)
    {:reply, :ok, writes}
  end

  @doc "Waits until the background disk writes queued so far are done."
  def sync, do: GenServer.call(__MODULE__, :sync)

  @doc "Brings the disk folder under its size cap now."
  def prune(cap \\ @max_disk_bytes),
    do: if(dir(), do: GenServer.call(__MODULE__, {:prune, dir(), cap}))

  @doc "The disk cache folder; `nil` when the disk layer is off."
  def dir do
    case Application.fetch_env(:browser, :disk_cache_dir) do
      {:ok, dir} ->
        dir

      :error ->
        Path.join(:filename.basedir(:user_cache, ~c"elixir_browser") |> to_string(), "http_cache")
    end
  end

  @doc "Drops everything, on disk too."
  def clear do
    if table?(), do: :ets.delete_all_objects(@table)

    with dir when dir != nil <- dir(), {:ok, names} <- File.ls(dir) do
      sync()
      for name <- names, String.ends_with?(name, ".entry"), do: File.rm(Path.join(dir, name))
    end

    :ok
  end

  @doc """
  The cached entry for `url`: `{:fresh, entry}`, `{:stale, entry}` or `:miss`.

  With `use_stale: true` (going back or forward) any entry counts as fresh.
  """
  def lookup(url, opts \\ []) do
    with true <- table?(),
         [{_, entry}] <- :ets.lookup(@table, url) do
      :ets.update_element(@table, url, {2, %{entry | used_at: now()}})
      classify(entry, opts)
    else
      _ ->
        case table?() && read_disk(url) do
          %Entry{} = entry ->
            evict_for(byte_size(entry.body))
            :ets.insert(@table, {url, entry})
            classify(entry, opts)

          _ ->
            :miss
        end
    end
  end

  defp classify(entry, opts) do
    if Keyword.get(opts, :use_stale, false) or entry.expires_at > now(),
      do: {:fresh, entry},
      else: {:stale, entry}
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
          drop(url)

        true ->
          evict_for(byte_size(body))

          entry = %Entry{
            url: url,
            body: body,
            etag: etag,
            last_modified: last_modified,
            expires_at: now() + (lifetime(headers, cc) || 0),
            used_at: now(),
            content_type: header(headers, "content-type")
          }

          :ets.insert(@table, {url, entry})

          if header(headers, "set-cookie") == nil, do: persist(entry), else: drop_disk(url)
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

      if storable?(headers, cc, entry.body) do
        :ets.insert(@table, {url, entry})
        if header(headers, "set-cookie") == nil, do: persist(entry), else: drop_disk(url)
      else
        drop(url)
      end
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

  # -- disk ----------------------------------------------------------------------

  defp drop(url) do
    :ets.delete(@table, url)
    drop_disk(url)
  end

  defp drop_disk(url) do
    if dir = dir(), do: GenServer.cast(__MODULE__, {:delete, dir, url})
  end

  # queue the entry for the background writer; the expiry goes to the file as wall-clock time
  defp persist(entry) do
    if dir = dir() do
      record = %{
        v: 1,
        url: entry.url,
        body: entry.body,
        etag: entry.etag,
        last_modified: entry.last_modified,
        content_type: entry.content_type,
        expires_at: System.os_time(:second) + (entry.expires_at - now())
      }

      GenServer.cast(__MODULE__, {:write, dir, entry.url, record})
    end
  end

  defp file(dir, url),
    do: Path.join(dir, Base.encode16(:crypto.hash(:sha256, url), case: :lower) <> ".entry")

  defp write_file(dir, url, record) do
    path = file(dir, url)
    File.mkdir_p!(dir)
    tmp = path <> ".#{System.unique_integer([:positive])}.tmp"
    File.write!(tmp, :erlang.term_to_binary(record))
    File.rename!(tmp, path)
  rescue
    _ -> :ok
  end

  defp read_disk(url) do
    with dir when dir != nil <- dir(),
         path = file(dir, url),
         {:ok, bin} <- File.read(path),
         %{v: 1, url: ^url} = r <- safe_decode(bin) do
      File.touch(path)

      %Entry{
        url: url,
        body: r.body,
        etag: r.etag,
        last_modified: r.last_modified,
        content_type: r.content_type,
        expires_at: now() + (r.expires_at - System.os_time(:second)),
        used_at: now()
      }
    else
      _ -> nil
    end
  end

  defp safe_decode(bin) do
    :erlang.binary_to_term(bin, [:safe])
  rescue
    ArgumentError -> nil
  end

  # delete the least recently used files until the folder is under its cap
  defp prune_dir(dir, cap \\ @max_disk_bytes) do
    with {:ok, names} <- File.ls(dir) do
      files =
        for name <- names,
            String.ends_with?(name, ".entry"),
            path = Path.join(dir, name),
            {:ok, %File.Stat{size: size, mtime: mtime}} <- [File.stat(path, time: :posix)] do
          {path, size, mtime}
        end

      total = Enum.reduce(files, 0, fn {_, size, _}, n -> n + size end)

      files
      |> Enum.sort_by(fn {_, _, mtime} -> mtime end)
      |> Enum.reduce_while(total, fn {path, size, _}, total ->
        if total <= cap do
          {:halt, total}
        else
          File.rm(path)
          {:cont, total - size}
        end
      end)
    end

    :ok
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
          _ -> heuristic(headers)
        end
    end
  end

  # No lifetime was given: a browser takes a tenth of the time since the file last changed (at most
  # a day) as the time the response stays fresh, so that a file nobody changed for hours is not asked
  # for again with every page that uses it.
  @max_heuristic 86_400

  defp heuristic(headers) do
    with lm when lm != nil <- header(headers, "last-modified"),
         {:ok, lm} <- parse_date(lm) do
      date =
        with d when d != nil <- header(headers, "date"), {:ok, d} <- parse_date(d) do
          d
        else
          _ -> :calendar.universal_time() |> :calendar.datetime_to_gregorian_seconds()
        end

      min(div(max(date - lm, 0), 10), @max_heuristic)
    else
      _ -> nil
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
