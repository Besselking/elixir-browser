defmodule Browser.IndexedDB do
  @moduledoc """
  The storage behind `indexedDB`: one text per database (the pages' JavaScript writes the
  whole database as JSON), kept per origin and name, between runs, and shared by every page of
  the origin.

  The store also keeps the list of open connections, because a database can be changed (a
  higher version, or deletion) only when no connection is open. A page that wants to open or
  delete a database asks with `begin/6`. When the answer is `:wait`, the store tells the page
  later with `{:idb, :ready | :blocked, token}`. Before that, it tells the pages with a
  connection to the database with `{:idb, :versionchange, origin, name, token, old, new}`.
  Those pages answer with `settled/4` (and close their connections, or not: then the asking
  page hears `:blocked`). A page that is done with its request calls `finish/6`, which lets the
  next request for the same database start.

  Persistence goes to `:indexed_db_path` (config; `nil` keeps it in memory), a moment after
  the last change. An origin that begins with `opaque:` (pages without an origin) is never
  written to disk.
  """
  use GenServer

  @save_after 250
  # a database is the JSON of everything in it
  @quota 256 * 1024 * 1024

  # ── pages ──────────────────────────────────────────────────

  @doc "The origin under which the page at `url` keeps its databases, or an origin of its own."
  def origin(url, pid \\ self()) do
    Browser.LocalStorage.origin(url) || "opaque:" <> inspect(pid)
  end

  @doc "`[{name, version}]` of the origin's databases, sorted by name."
  def names(origin, server \\ __MODULE__), do: GenServer.call(server, {:names, origin})

  @doc """
  What is stored for the database: `:none` (no such database), `:same` (it is still at `rev`)
  or `{:ok, rev, version, data}`.
  """
  def load(origin, name, rev \\ nil, server \\ __MODULE__),
    do: GenServer.call(server, {:load, origin, name, rev})

  @doc "Stores a database. Returns the new revision, or `:quota`."
  def save(origin, name, version, data, server \\ __MODULE__),
    do: GenServer.call(server, {:save, origin, name, version, data})

  @doc """
  Asks to open (`{:open, version | nil}`) or delete (`:delete`) a database; `token` is the page's
  own number for the request. `:ready` means go on, `:wait` means the store will send a message.
  """
  def begin(origin, name, kind, token, server \\ __MODULE__),
    do: GenServer.call(server, {:begin, origin, name, kind, token, self()})

  @doc "The page has dealt with a `versionchange` message of the request that has `token`."
  def settled(origin, name, token, server \\ __MODULE__),
    do: GenServer.call(server, {:settled, origin, name, token, self()})

  @doc """
  The request of the page with `token` is over; when it opened a database, the connection `conn`
  is open from now on. The next request for the database can start.
  """
  def finish(origin, name, token, conn, server \\ __MODULE__),
    do: GenServer.call(server, {:finish, origin, name, token, conn, self()})

  @doc "The connection `conn` of this page is closed."
  def close(origin, name, conn, server \\ __MODULE__),
    do: GenServer.call(server, {:close, origin, name, conn, self()})

  @doc "Removes a database (when the request to delete it has its turn)."
  def delete(origin, name, server \\ __MODULE__),
    do: GenServer.call(server, {:delete, origin, name})

  @doc "Writes the databases to disk now."
  def flush(server \\ __MODULE__), do: GenServer.call(server, :flush)

  @doc "Where the databases live (config `:indexed_db_path`; nil is memory only)."
  def path do
    case Application.fetch_env(:browser, :indexed_db_path) do
      {:ok, path} ->
        path

      :error ->
        Path.join(
          :filename.basedir(:user_data, ~c"elixir_browser") |> to_string(),
          "indexed_db.etf"
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
    Process.flag(:trap_exit, true)
    path = opts[:path]

    dbs =
      for {{_o, _n} = key, {version, data}} <- load_file(path), into: %{} do
        {key, new_db(version, data, 1)}
      end

    {:ok, %{path: path, dbs: dbs, timer: nil, dirty: false, monitors: %{}, tokens: 0}}
  end

  defp new_db(version, data, rev),
    do: %{version: version, data: data, rev: rev, conns: [], ops: []}

  @impl true
  def handle_call({:names, origin}, _from, s) do
    names =
      for {{^origin, name}, %{data: data} = db} <- s.dbs, data != nil, do: {name, db.version}

    {:reply, Enum.sort(names), s}
  end

  def handle_call({:load, origin, name, rev}, _from, s) do
    reply =
      case s.dbs[{origin, name}] do
        %{data: data} = db when data != nil ->
          if db.rev == rev, do: :same, else: {:ok, db.rev, db.version, data}

        _ ->
          :none
      end

    {:reply, reply, s}
  end

  def handle_call({:save, origin, name, version, data}, _from, s) do
    key = {origin, name}
    db = s.dbs[key] || new_db(0, nil, 0)

    if byte_size(data) > @quota do
      {:reply, :quota, s}
    else
      db = %{db | version: version, data: data, rev: db.rev + 1}
      {:reply, db.rev, changed(%{s | dbs: Map.put(s.dbs, key, db)}, origin)}
    end
  end

  def handle_call({:delete, origin, name}, _from, s) do
    key = {origin, name}

    case s.dbs[key] do
      nil ->
        {:reply, :ok, s}

      db ->
        {:reply, :ok,
         changed(
           %{s | dbs: Map.put(s.dbs, key, %{db | data: nil, version: 0}), dirty: true},
           origin
         )}
    end
  end

  def handle_call({:begin, origin, name, kind, id, pid}, _from, s) do
    s = monitor(s, pid)
    key = {origin, name}
    db = s.dbs[key] || new_db(0, nil, 0)
    token = s.tokens + 1
    op = %{token: token, id: id, pid: pid, kind: kind, state: :queued, waiting: MapSet.new()}
    db = %{db | ops: db.ops ++ [op]}
    s = %{s | tokens: token, dbs: Map.put(s.dbs, key, db)}
    s = advance(s, key, false)
    state = hd(s.dbs[key].ops).state

    reply =
      if hd(s.dbs[key].ops).token == token and state == :ready,
        do: {:ready, token},
        else: {:wait, token}

    {:reply, reply, s}
  end

  def handle_call({:finish, origin, name, token, conn, pid}, _from, s) do
    key = {origin, name}

    case s.dbs[key] do
      nil ->
        {:reply, :ok, s}

      db ->
        db = %{db | ops: Enum.reject(db.ops, &(&1.token == token))}
        db = if conn, do: %{db | conns: db.conns ++ [{pid, conn}]}, else: db
        s = %{s | dbs: Map.put(s.dbs, key, db)}
        {:reply, :ok, advance(s, key, true)}
    end
  end

  def handle_call({:close, origin, name, conn, pid}, _from, s) do
    key = {origin, name}

    case s.dbs[key] do
      nil ->
        {:reply, :ok, s}

      db ->
        db = %{db | conns: List.delete(db.conns, {pid, conn})}
        {:reply, :ok, advance(%{s | dbs: Map.put(s.dbs, key, db)}, key, true)}
    end
  end

  def handle_call(:flush, _from, s), do: {:reply, :ok, save(s)}

  def handle_call({:settled, origin, name, token, pid}, _from, s) do
    key = {origin, name}

    case s.dbs[key] do
      %{ops: [%{token: ^token} = op | rest]} = db ->
        op = %{op | waiting: MapSet.delete(op.waiting, pid)}
        s = %{s | dbs: Map.put(s.dbs, key, %{db | ops: [op | rest]})}
        {:reply, :ok, advance(s, key, true)}

      _ ->
        {:reply, :ok, s}
    end
  end

  @impl true
  def handle_info(:save, s), do: {:noreply, save(%{s | timer: nil})}

  def handle_info({:DOWN, _, :process, pid, _}, s) do
    s = %{s | monitors: Map.delete(s.monitors, pid)}

    dbs =
      for {key, db} <- s.dbs, into: %{} do
        {key,
         %{
           db
           | conns: Enum.reject(db.conns, fn {p, _} -> p == pid end),
             ops: Enum.reject(db.ops, &(&1.pid == pid))
         }}
      end

    s = %{s | dbs: dbs}
    {:noreply, Enum.reduce(Map.keys(dbs), s, &advance(&2, &1, true))}
  end

  def handle_info(_other, s), do: {:noreply, s}

  @impl true
  def terminate(_reason, s), do: save(s)

  defp monitor(s, pid) do
    if Map.has_key?(s.monitors, pid),
      do: s,
      else: %{s | monitors: Map.put(s.monitors, pid, Process.monitor(pid))}
  end

  # Looks at the request at the head of the queue of a database, and tells its page what to do
  # next. `notify?` is false inside `begin`, whose reply carries the answer.
  defp advance(s, key, notify?) do
    {origin, name} = key

    case s.dbs[key] do
      %{ops: [op | rest]} = db ->
        change? =
          case op.kind do
            :delete -> true
            {:open, v} -> v != nil and v > db.version
          end

        {op, send?} =
          cond do
            op.state == :ready ->
              {op, nil}

            not change? or db.conns == [] ->
              {%{op | state: :ready}, :ready}

            op.state == :queued ->
              pids = db.conns |> Enum.map(&elem(&1, 0)) |> Enum.uniq()

              for p <- pids do
                send(
                  p,
                  {:idb, :versionchange, origin, name, op.token, db.version, version_of(op)}
                )
              end

              {%{op | state: :waiting, waiting: MapSet.new(pids)}, nil}

            op.state == :waiting and MapSet.size(op.waiting) == 0 ->
              {%{op | state: :blocked}, :blocked}

            true ->
              {op, nil}
          end

        if send? && (notify? or send? != :ready), do: send(op.pid, {:idb, send?, op.id})

        %{s | dbs: Map.put(s.dbs, key, %{db | ops: [op | rest]})}

      _ ->
        s
    end
  end

  defp version_of(%{kind: {:open, v}}), do: v
  defp version_of(_), do: nil

  defp changed(s, origin) do
    if String.starts_with?(origin, "opaque:") do
      s
    else
      case s.timer do
        nil -> %{s | dirty: true, timer: Process.send_after(self(), :save, @save_after)}
        _ -> %{s | dirty: true}
      end
    end
  end

  # ── disk ───────────────────────────────────────────────────

  defp load_file(nil), do: %{}

  defp load_file(path) do
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
      for {{origin, _} = key, %{data: data} = db} <- s.dbs,
          data != nil,
          not String.starts_with?(origin, "opaque:"),
          into: %{},
          do: {key, {db.version, data}}

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
