defmodule Browser.LocalStorage do
  @moduledoc """
  `localStorage`: string keys and values kept per origin, between runs and shared by every
  page of the origin that is open.

  Reads go straight to a public ETS table (`{{origin, key}, value}`, sorted, so `key/1` is
  stable). Writes go through this process, which enforces the quota (5 Mi characters of keys
  and values per origin, `{:error, :quota}` beyond it), saves the whole store a moment after
  the last change (to `:local_storage_path`, config; `nil` keeps it in memory), and tells the
  other pages of the origin, which `subscribe/2`d, with `{:storage, origin, key, old, new}`
  so they can fire a `storage` event.

  The origin of a page is `origin/1`: `scheme://host[:port]` for web pages, `file://` for
  files and `nil` (no storage) for everything else.
  """
  use GenServer

  @quota 5 * 1024 * 1024
  @save_after 250

  # ── pages ──────────────────────────────────────────────────

  @doc "The storage origin of `url`, or nil if its pages get no `localStorage`."
  def origin(url) do
    case URI.parse(url) do
      %URI{scheme: "file"} ->
        "file://"

      %URI{scheme: scheme, host: host, port: port}
      when scheme in ["http", "https"] and host != nil ->
        default = if scheme == "https", do: 443, else: 80

        scheme <>
          "://" <> String.downcase(host) <> if(port in [nil, default], do: "", else: ":#{port}")

      _ ->
        nil
    end
  end

  @doc "The value of `key`, or nil."
  def get(origin, key, server \\ __MODULE__) do
    case :ets.lookup(server, {origin, key}) do
      [{_, value}] -> value
      [] -> nil
    end
  end

  @doc "The number of items."
  def count(origin, server \\ __MODULE__) do
    :ets.select_count(server, [{{{origin, :_}, :_}, [], [true]}])
  end

  @doc "The name of the `index`th item (sorted by name), or nil."
  def key(origin, index, server \\ __MODULE__) do
    keys(origin, server) |> Enum.at(index)
  end

  @doc "All the names, sorted."
  def keys(origin, server \\ __MODULE__) do
    :ets.select(server, [{{{origin, :"$1"}, :_}, [], [:"$1"]}])
  end

  @doc "Stores `value` under `key`. `{:error, :quota}` when the origin would be over its quota."
  def put(origin, key, value, server \\ __MODULE__),
    do: GenServer.call(server, {:put, origin, key, value, self()})

  @doc "Removes `key`."
  def delete(origin, key, server \\ __MODULE__),
    do: GenServer.call(server, {:delete, origin, key, self()})

  @doc "Removes everything of the origin."
  def clear(origin, server \\ __MODULE__), do: GenServer.call(server, {:clear, origin, self()})

  @doc """
  Makes the calling process hear of changes other processes make to `origin`:
  `{:storage, origin, key, old_value, new_value}` (`key` nil for `clear`).
  """
  def subscribe(origin, server \\ __MODULE__),
    do: GenServer.call(server, {:subscribe, origin, self()})

  @doc "Writes the store to disk now."
  def flush(server \\ __MODULE__), do: GenServer.call(server, :flush)

  @doc "Where the store lives (config `:local_storage_path`; nil is memory only)."
  def path do
    case Application.fetch_env(:browser, :local_storage_path) do
      {:ok, path} ->
        path

      :error ->
        Path.join(
          :filename.basedir(:user_data, ~c"elixir_browser") |> to_string(),
          "local_storage.etf"
        )
    end
  end

  # ── the process ────────────────────────────────────────────

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, Keyword.put_new(opts, :path, path()), name: name)
  end

  def child_spec(opts),
    do: %{id: Keyword.get(opts, :name, __MODULE__), start: {__MODULE__, :start_link, [opts]}}

  @impl true
  def init(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    Process.flag(:trap_exit, true)
    :ets.new(name, [:named_table, :ordered_set, :public, read_concurrency: true])
    path = opts[:path]

    sizes =
      for {origin, items} <- load(path), {k, v} <- items, reduce: %{} do
        sizes ->
          :ets.insert(name, {{origin, k}, v})
          Map.update(sizes, origin, size(k, v), &(&1 + size(k, v)))
      end

    {:ok, %{table: name, path: path, sizes: sizes, subs: %{}, timer: nil, dirty: false}}
  end

  @impl true
  def handle_call({:put, origin, key, value, from}, _from, s) do
    old = get(origin, key, s.table)
    used = Map.get(s.sizes, origin, 0)
    delta = size(key, value) - if(old, do: size(key, old), else: 0)

    cond do
      old == value ->
        {:reply, :ok, s}

      used + delta > @quota ->
        {:reply, {:error, :quota}, s}

      true ->
        :ets.insert(s.table, {{origin, key}, value})
        notify(s, origin, from, key, old, value)
        {:reply, :ok, changed(%{s | sizes: Map.put(s.sizes, origin, used + delta)})}
    end
  end

  def handle_call({:delete, origin, key, from}, _from, s) do
    case get(origin, key, s.table) do
      nil ->
        {:reply, :ok, s}

      old ->
        :ets.delete(s.table, {origin, key})
        notify(s, origin, from, key, old, nil)
        sizes = Map.update(s.sizes, origin, 0, &(&1 - size(key, old)))
        {:reply, :ok, changed(%{s | sizes: sizes})}
    end
  end

  def handle_call({:clear, origin, from}, _from, s) do
    if count(origin, s.table) == 0 do
      {:reply, :ok, s}
    else
      :ets.select_delete(s.table, [{{{origin, :_}, :_}, [], [true]}])
      notify(s, origin, from, nil, nil, nil)
      {:reply, :ok, changed(%{s | sizes: Map.delete(s.sizes, origin)})}
    end
  end

  def handle_call({:subscribe, origin, pid}, _from, s) do
    Process.monitor(pid)
    subs = Map.update(s.subs, origin, MapSet.new([pid]), &MapSet.put(&1, pid))
    {:reply, :ok, %{s | subs: subs}}
  end

  def handle_call(:flush, _from, s), do: {:reply, :ok, save(s)}

  @impl true
  def handle_info(:save, s), do: {:noreply, save(%{s | timer: nil})}

  def handle_info({:DOWN, _, :process, pid, _}, s) do
    subs = for {o, pids} <- s.subs, into: %{}, do: {o, MapSet.delete(pids, pid)}
    {:noreply, %{s | subs: subs}}
  end

  def handle_info(_other, s), do: {:noreply, s}

  @impl true
  def terminate(_reason, s), do: save(s)

  defp notify(s, origin, from, key, old, new) do
    for pid <- Map.get(s.subs, origin, []), pid != from do
      send(pid, {:storage, origin, key, old, new})
    end
  end

  defp changed(%{timer: nil} = s),
    do: %{s | dirty: true, timer: Process.send_after(self(), :save, @save_after)}

  defp changed(s), do: %{s | dirty: true}

  defp size(key, value), do: String.length(key) + String.length(value)

  # ── disk ───────────────────────────────────────────────────

  defp load(nil), do: %{}

  defp load(path) do
    with {:ok, bin} <- File.read(path),
         store when is_map(store) <- safe_decode(bin) do
      store
    else
      _ -> %{}
    end
  end

  defp safe_decode(bin) do
    :erlang.binary_to_term(bin, [:safe])
  rescue
    ArgumentError -> nil
  end

  defp save(%{dirty: false} = s), do: s
  defp save(%{path: nil} = s), do: %{s | dirty: false}

  defp save(s) do
    store =
      for {{origin, key}, value} <- :ets.tab2list(s.table), reduce: %{} do
        acc -> Map.update(acc, origin, %{key => value}, &Map.put(&1, key, value))
      end

    # through a temporary file, so a crash can't leave half a store
    try do
      File.mkdir_p!(Path.dirname(s.path))
      tmp = s.path <> ".#{System.unique_integer([:positive])}.tmp"
      File.write!(tmp, :erlang.term_to_binary(store))
      File.rename!(tmp, s.path)
    rescue
      _ -> :error
    end

    if s.timer, do: Process.cancel_timer(s.timer)
    %{s | dirty: false, timer: nil}
  end
end
