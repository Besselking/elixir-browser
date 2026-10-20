defmodule Browser.Archive do
  @moduledoc """
  A page archive: the raw network responses of a page, saved in one file, and a replay mode
  that answers every request from that file with no network.

  An archive is for a site that a cloud session cannot reach. Record it where the site
  loads (`mix browser.archive URL OUT`, or Develop > Record Page Archive in the window),
  and replay it anywhere (`--archive FILE` of `mix browser.screenshot` and `mix
  browser.layout`, or `BROWSER_ARCHIVE=FILE` for the window). The page then gets the bytes
  and headers that the server sent, so its scripts run on the original HTML, not on a
  copy that a browser saved after the scripts had changed it.

  `Browser.Fetch` is the only place that uses this module. While recording, each response
  that comes from the network is kept: the HTML, every subresource and every redirect hop,
  as received (a gzip body stays gzip). The memory cache is skipped, so a reload records
  everything. While replaying, a request is answered from the archive and the network is
  never used (also not for WebSockets). A request that is not in the archive fails. When
  one URL was requested more than once, the answers come in the order they were recorded
  and the last one repeats.

  The file is `"ELIXIR-BROWSER-ARCHIVE 1\\n"` followed by an Erlang term (compressed) of
  `%{version: 1, created: ms, entries: [entry]}`. An entry is `%{method:, url:, body_hash:,
  navigation:, status:, reason:, headers:, body:}`. Request bodies are not kept (only a
  hash, to tell two POSTs to one URL apart), and `Set-Cookie` headers are dropped, so an
  archive holds no cookies. The responses can still hold private data of the page, so do
  not share an archive of a page that you were logged in to.
  """

  use Agent

  @table :browser_archive
  @magic "ELIXIR-BROWSER-ARCHIVE 1\n"
  # recording stops keeping responses at this size
  @max_bytes 256 * 1024 * 1024
  @extension ".ebarchive"

  @doc false
  def start_link(_) do
    Agent.start_link(fn ->
      :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
      :ets.insert(@table, {:mode, :off})

      case System.get_env("BROWSER_ARCHIVE") do
        path when path in [nil, ""] -> :ok
        path -> load_into_table(path)
      end

      nil
    end)
  end

  @doc "`:off`, `:record` or `:replay`."
  @spec mode() :: :off | :record | :replay
  def mode do
    case :ets.lookup(@table, :mode) do
      [{:mode, mode}] -> mode
      _ -> :off
    end
  rescue
    ArgumentError -> :off
  end

  @doc "The file extension of archives."
  def extension, do: @extension

  # ── recording ──────────────────────────────────────────────

  @doc "Starts a new recording (what was kept so far is dropped)."
  @spec record_start() :: :ok
  def record_start do
    clear()
    :ets.insert(@table, [{:mode, :record}, {:seq, 0}, {:bytes, 0}])
    :ok
  end

  @doc """
  Keeps a response. `body` is the body of the request (nil for a GET), `headers` those of the
  response as `:httpc` gives them. Does nothing unless recording.
  """
  def record(method, url, body, status, reason, headers, resp_body, navigation) do
    if mode() == :record do
      bytes = byte_size(resp_body)

      if :ets.lookup_element(@table, :bytes, 2) + bytes <= @max_bytes do
        :ets.update_counter(@table, :bytes, bytes)
        seq = :ets.update_counter(@table, :seq, 1)

        :ets.insert(
          @table,
          {{:rec, seq},
           %{
             method: method,
             url: url,
             body_hash: hash(body),
             navigation: navigation,
             status: status,
             reason: to_string(reason),
             headers: clean_headers(headers),
             body: resp_body
           }}
        )
      end
    end

    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc "How many responses a recording holds."
  def recorded_count do
    :ets.select_count(@table, [{{{:rec, :_}, :_}, [], [true]}])
  rescue
    ArgumentError -> 0
  end

  @doc "Stops recording; returns the archive."
  @spec record_stop() :: map
  def record_stop do
    archive = snapshot()
    clear()
    archive
  end

  @doc "The archive of what is recorded so far, recording goes on."
  @spec snapshot() :: map
  def snapshot do
    entries =
      @table
      |> :ets.select([{{{:rec, :"$1"}, :"$2"}, [], [{{:"$1", :"$2"}}]}])
      |> Enum.sort()
      |> Enum.map(&elem(&1, 1))

    %{version: 1, created: System.system_time(:millisecond), entries: entries}
  end

  # ── replaying ──────────────────────────────────────────────

  @doc "Replays the archive in `path`: from now on no request uses the network."
  @spec replay(Path.t()) :: :ok | {:error, String.t()}
  def replay(path) do
    load_into_table(path)
  end

  @doc "Like `replay/1`, but raises."
  def replay!(path) do
    case replay(path) do
      :ok -> :ok
      {:error, why} -> raise "Cannot replay #{path}: #{why}"
    end
  end

  @doc "Back to the network."
  def stop do
    clear()
    :ok
  end

  @doc """
  The recorded answer to a request: `{:ok, status, reason, headers, body}` with the headers as
  `:httpc` gives them (charlists), or `:miss`.
  """
  def lookup(method, url, body) do
    with [{_, entries}] <- :ets.lookup(@table, {:play, method, url}) do
      hash = hash(body)

      candidates =
        case Enum.filter(entries, &(&1.body_hash == hash)) do
          [] -> entries
          same -> same
        end

      n =
        :ets.update_counter(@table, {:pos, method, url, hash}, 1, {{:pos, method, url, hash}, -1})

      e = Enum.at(candidates, min(n, length(candidates) - 1))

      {:ok, e.status, e.reason,
       for({k, v} <- e.headers, do: {String.to_charlist(k), String.to_charlist(v)}), e.body}
    else
      _ -> :miss
    end
  rescue
    ArgumentError -> :miss
  end

  # ── files ──────────────────────────────────────────────────

  @doc "Writes `archive` to `path`."
  @spec write(map, Path.t()) :: :ok | {:error, String.t()}
  def write(archive, path) do
    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, [@magic, :erlang.term_to_binary(archive, compressed: 6)]) do
      :ok
    else
      {:error, reason} -> {:error, "cannot write #{path}: #{:file.format_error(reason)}"}
    end
  end

  @doc "Reads an archive file."
  @spec read(Path.t()) :: {:ok, map} | {:error, String.t()}
  def read(path) do
    case File.read(path) do
      {:ok, @magic <> term} -> decode(term)
      {:ok, _} -> {:error, "not a page archive"}
      {:error, reason} -> {:error, "cannot read #{path}: #{:file.format_error(reason)}"}
    end
  end

  defp decode(term) do
    case :erlang.binary_to_term(term, [:safe]) do
      %{version: 1, entries: entries} = archive when is_list(entries) -> {:ok, archive}
      _ -> {:error, "unknown archive format"}
    end
  rescue
    ArgumentError -> {:error, "the archive is damaged"}
  end

  @doc """
  Writes the recording to a new file in `dir`, named after the page and the time.
  Returns `{:ok, path, entries}`.
  """
  def save_recording(dir, now \\ NaiveDateTime.utc_now()) do
    archive = record_stop()
    path = Path.join(dir, file_name(archive, now))

    with :ok <- write(archive, path), do: {:ok, path, length(archive.entries)}
  end

  @doc "A file name for `archive`: host and time."
  def file_name(archive, now) do
    host =
      case start_url(archive) && URI.parse(start_url(archive)).host do
        h when is_binary(h) and h != "" -> String.replace(h, ~r/[^A-Za-z0-9.-]/, "_")
        _ -> "page"
      end

    stamp = Calendar.strftime(now, "%Y%m%d-%H%M%S")
    host <> "-" <> stamp <> @extension
  end

  @doc "The address the archive was recorded from: the first page that was navigated to."
  def start_url(%{entries: entries}) do
    case Enum.find(entries, & &1.navigation) || List.first(entries) do
      nil -> nil
      entry -> entry.url
    end
  end

  # ── helpers ────────────────────────────────────────────────

  defp load_into_table(path) do
    with {:ok, archive} <- read(path) do
      clear()

      grouped = Enum.group_by(archive.entries, &{&1.method, &1.url})

      :ets.insert(
        @table,
        for({{method, url}, entries} <- grouped, do: {{:play, method, url}, entries})
      )

      :ets.insert(@table, {:mode, :replay})
      :ok
    end
  end

  defp clear do
    :ets.delete_all_objects(@table)
    :ets.insert(@table, {:mode, :off})
  end

  defp hash(nil), do: nil
  defp hash(""), do: nil
  defp hash(body), do: :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)

  # lower-case names as binaries, without cookies
  defp clean_headers(headers) do
    for {k, v} <- headers,
        name = k |> to_string() |> String.downcase(),
        name not in ["set-cookie", "set-cookie2"],
        do: {name, to_string(v)}
  end
end
