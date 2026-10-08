defmodule Browser.IndexedDB do
  @moduledoc """
  The storage behind `indexedDB`: the databases, kept per origin and name, between runs, and
  shared by every page of the origin. A page writes only what a transaction changed: the schema
  of the database (a JSON text), and a list of operations on records (each record is a key text
  and a value text) and on the entries of indexes. The store puts them together again when a
  page reads the database.

  The store also keeps the list of open connections, because a database can be changed (a
  higher version, or deletion) only when no connection is open. A page that wants to open or
  delete a database asks with `begin/6`. When the answer is `:wait`, the store tells the page
  later with `{:idb, :ready | :blocked, token}`. Before that, it tells the pages with a
  connection to the database with `{:idb, :versionchange, origin, name, token, old, new}`.
  Those pages answer with `settled/4` (and close their connections, or not: then the asking
  page hears `:blocked`). A page that is done with its request calls `finish/6`, which lets the
  next request for the same database start.

  Persistence goes to the folder `:indexed_db_path` (config; `nil` keeps it in memory), one file
  for each database, a moment after the last change. An origin that begins with `opaque:` (pages without an origin) is never
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

  @doc """
  Stores the changes of a transaction. `schema` lists the stores: `[name, meta, indexes]` with
  `meta` the JSON text of the store's key path, generator and so on, and `indexes` a list of
  `[name, meta]`. `ops` are the operations, in order:
  `["p", store, key, value]` (put), `["d", store, key]` (delete), `["c", store]` (empty the
  store), `["e", store, index, entries]` (the new entries of an index, a JSON text). Stores and
  indexes that the schema does not name are dropped. Returns the new revision, or `:quota`.
  """
  def save(origin, name, version, schema, ops \\ [], server \\ __MODULE__),
    do: GenServer.call(server, {:save, origin, name, version, schema, ops})

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

  @doc "The folder where the databases live (config `:indexed_db_path`; nil is memory only)."
  def path do
    case Application.fetch_env(:browser, :indexed_db_path) do
      {:ok, path} ->
        path

      :error ->
        Path.join(:filename.basedir(:user_data, ~c"elixir_browser") |> to_string(), "indexed_db")
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
      for {key, version, schema, recs, idx} <- load_files(path), into: %{} do
        db = %{new_db(version, schema, 1) | recs: recs, idx: idx}
        {key, %{db | bytes: size_of(db)}}
      end

    {:ok, %{path: path, dbs: dbs, timer: nil, dirty: MapSet.new(), monitors: %{}, tokens: 0}}
  end

  defp new_db(version, schema, rev),
    do: %{
      version: version,
      schema: schema,
      recs: %{},
      idx: %{},
      bytes: 0,
      rev: rev,
      conns: [],
      ops: []
    }

  @impl true
  def handle_call({:names, origin}, _from, s) do
    names =
      for {{^origin, name}, %{schema: schema} = db} <- s.dbs,
          schema != nil,
          do: {name, db.version}

    {:reply, Enum.sort(names), s}
  end

  def handle_call({:load, origin, name, rev}, _from, s) do
    reply =
      case s.dbs[{origin, name}] do
        %{schema: schema} = db when schema != nil ->
          if db.rev == rev, do: :same, else: {:ok, db.rev, db.version, assemble(db)}

        _ ->
          :none
      end

    {:reply, reply, s}
  end

  def handle_call({:save, origin, name, version, schema, ops}, _from, s) do
    key = {origin, name}
    old = s.dbs[key] || new_db(0, nil, 0)

    # (what a page sends is not trusted: a bad request refuses the write, and does not end the store)
    try do
      db = old |> apply_ops(ops) |> prune(schema)

      if db.bytes > @quota do
        {:reply, :quota, s}
      else
        db = %{db | version: version, schema: schema, rev: old.rev + 1}
        {:reply, db.rev, changed(%{s | dbs: Map.put(s.dbs, key, db)}, key)}
      end
    rescue
      _ -> {:reply, :quota, s}
    end
  end

  def handle_call({:delete, origin, name}, _from, s) do
    key = {origin, name}

    case s.dbs[key] do
      nil ->
        {:reply, :ok, s}

      db ->
        db = %{db | schema: nil, version: 0, recs: %{}, idx: %{}, bytes: 0}
        {:reply, :ok, changed(%{s | dbs: Map.put(s.dbs, key, db)}, key)}
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

  # ── the data of a database ─────────────────────────────────

  defp apply_ops(db, ops), do: Enum.reduce(ops, db, &apply_op/2)

  defp apply_op(["p", store, key, value], db) do
    recs = db.recs[store] || %{}
    old = Map.get(recs, key)

    delta =
      byte_size(key) + byte_size(value) - if(old, do: byte_size(key) + byte_size(old), else: 0)

    %{db | recs: Map.put(db.recs, store, Map.put(recs, key, value)), bytes: db.bytes + delta}
  end

  defp apply_op(["d", store, key], db) do
    recs = db.recs[store] || %{}

    case Map.pop(recs, key) do
      {nil, _} ->
        db

      {old, recs} ->
        %{
          db
          | recs: Map.put(db.recs, store, recs),
            bytes: db.bytes - byte_size(key) - byte_size(old)
        }
    end
  end

  defp apply_op(["c", store], db) do
    gone =
      Enum.reduce(db.recs[store] || %{}, 0, fn {k, v}, n -> n + byte_size(k) + byte_size(v) end)

    %{db | recs: Map.delete(db.recs, store), bytes: db.bytes - gone}
  end

  defp apply_op(["e", store, index, entries], db) do
    old = Map.get(db.idx, {store, index})
    delta = byte_size(entries) - if(old, do: byte_size(old), else: 0)
    %{db | idx: Map.put(db.idx, {store, index}, entries), bytes: db.bytes + delta}
  end

  defp apply_op(_other, db), do: db

  # drops what the schema no longer names
  defp prune(db, schema) do
    names = for [name, _, _] <- schema, do: name
    ixs = for [name, _, indexes] <- schema, [ix, _] <- indexes, do: {name, ix}

    {recs, rest} = Map.split_with(db.recs, fn {n, _} -> n in names end)
    {idx, gone} = Map.split_with(db.idx, fn {k, _} -> k in ixs end)

    dropped =
      Enum.reduce(rest, 0, fn {_, m}, n -> n + map_size_of(m) end) +
        Enum.reduce(gone, 0, fn {_, e}, n -> n + byte_size(e) end)

    %{db | recs: recs, idx: idx, bytes: db.bytes - dropped}
  end

  defp map_size_of(m), do: Enum.reduce(m, 0, fn {k, v}, n -> n + byte_size(k) + byte_size(v) end)

  defp size_of(db),
    do:
      Enum.reduce(db.recs, 0, fn {_, m}, n -> n + map_size_of(m) end) +
        Enum.reduce(db.idx, 0, fn {_, e}, n -> n + byte_size(e) end)

  # the JSON text `{"v": version, "s": [store with "i": indexes with "e": entries, "r": records]}`
  defp assemble(db) do
    stores =
      for [name, meta, indexes] <- db.schema do
        recs =
          (db.recs[name] || %{})
          |> Enum.sort_by(fn {k, _} -> key_term(k) end)
          |> Enum.map(fn {k, v} -> ["[", k, ",", v, "]"] end)
          |> Enum.intersperse(",")

        ixs =
          for [ix, ix_meta] <- indexes,
              do: [open_object(ix_meta), ",\"e\":", Map.get(db.idx, {name, ix}, "[]"), "}"]

        [open_object(meta), ",\"i\":[", Enum.intersperse(ixs, ","), "],\"r\":[", recs, "]}"]
      end

    IO.iodata_to_binary([
      "{\"v\":",
      Integer.to_string(db.version),
      ",\"s\":[",
      Enum.intersperse(stores, ","),
      "]}"
    ])
  end

  # a JSON object text without its closing brace, so that more members can follow
  defp open_object(json), do: binary_part(json, 0, byte_size(json) - 1)

  # The sort term of a key text (JSON written by the pages): numbers, dates, strings (by UTF-16
  # code unit), binaries, arrays, in that order. The text is read here, not with `JSON`, because
  # it can hold lone surrogates (`"\ud800"`), which `JSON` refuses.
  defp key_term(text) do
    {term, _} = key_value(String.trim_leading(text))
    term
  end

  defp key_value(<<?", rest::binary>>) do
    {units, rest} = key_string(rest, [])
    {{3, 0, units}, rest}
  end

  defp key_value(<<?[, rest::binary>>), do: key_list(String.trim_leading(rest), [])

  defp key_value(<<?{, rest::binary>>) do
    {pairs, rest} = key_members(String.trim_leading(rest), [])

    term =
      case Map.new(pairs) do
        %{<<0, ?$>> => <<0, ?I>>} -> {1, 2, 0}
        %{<<0, ?$>> => <<0, ?-, 0, ?I>>} -> {1, 0, 0}
        %{<<0, ?$>> => <<0, ?d>>, <<0, ?v>> => {1, 1, v}} -> {2, 0, v}
        %{<<0, ?$>> => <<0, ?b>>, <<0, ?v>> => hex} -> {4, 0, hex}
        _ -> {0, 0, 0}
      end

    {term, rest}
  end

  defp key_value(text) do
    [num] = Regex.run(~r/\A-?[0-9][0-9.eE+-]*/, text)
    rest = binary_part(text, byte_size(num), byte_size(text) - byte_size(num))

    n =
      case Integer.parse(num) do
        {int, ""} -> int
        _ -> elem(Float.parse(num), 0)
      end

    {{1, 1, n}, rest}
  end

  defp key_list(<<?], rest::binary>>, acc), do: {{5, 0, Enum.reverse(acc)}, rest}
  defp key_list(<<?,, rest::binary>>, acc), do: key_list(String.trim_leading(rest), acc)

  defp key_list(text, acc) do
    {term, rest} = key_value(text)
    key_list(String.trim_leading(rest), [term | acc])
  end

  defp key_members(<<?}, rest::binary>>, acc), do: {acc, rest}
  defp key_members(<<?,, rest::binary>>, acc), do: key_members(String.trim_leading(rest), acc)

  defp key_members(<<?", rest::binary>>, acc) do
    {{3, 0, name}, rest} = key_value(<<?", rest::binary>>)
    <<?:, rest::binary>> = String.trim_leading(rest)
    {value, rest} = key_value(String.trim_leading(rest))
    key_members(String.trim_leading(rest), [{name, member_value(value)} | acc])
  end

  defp member_value({3, 0, units}), do: units
  defp member_value(term), do: term

  # the characters of a JSON string as a binary of UTF-16 code units (big endian), after the
  # opening quote
  defp key_string(<<?", rest::binary>>, acc), do: {IO.iodata_to_binary(Enum.reverse(acc)), rest}

  defp key_string(<<?\\, ?u, hex::binary-size(4), rest::binary>>, acc),
    do: key_string(rest, [<<String.to_integer(hex, 16)::16>> | acc])

  defp key_string(<<?\\, c, rest::binary>>, acc) do
    char =
      case c do
        ?n -> ?\n
        ?t -> ?\t
        ?r -> ?\r
        ?b -> ?\b
        ?f -> ?\f
        other -> other
      end

    key_string(rest, [<<char::16>> | acc])
  end

  defp key_string(text, acc) do
    case String.next_codepoint(text) do
      {cp, rest} ->
        key_string(rest, [:unicode.characters_to_binary(cp, :utf8, {:utf16, :big}) | acc])

      nil ->
        {IO.iodata_to_binary(Enum.reverse(acc)), ""}
    end
  end

  defp changed(s, {origin, _} = key) do
    if String.starts_with?(origin, "opaque:") do
      s
    else
      s = %{s | dirty: MapSet.put(s.dirty, key)}

      case s.timer do
        nil -> %{s | timer: Process.send_after(self(), :save, @save_after)}
        _ -> s
      end
    end
  end

  # ── disk ───────────────────────────────────────────────────

  defp file_of(path, {origin, name}) do
    Path.join(
      path,
      Base.url_encode64(:crypto.hash(:sha256, [origin, 0, name]), padding: false) <> ".etf"
    )
  end

  defp load_files(nil), do: []

  defp load_files(path) do
    for file <- Path.wildcard(Path.join(path, "*.etf")),
        {:ok, bin} <- [File.read(file)],
        {origin, name, version, schema, recs, idx} when is_list(schema) <- [safe_decode(bin)] do
      {{origin, name}, version, schema, recs, idx}
    end
  end

  defp safe_decode(bin) do
    :erlang.binary_to_term(bin, [:safe])
  rescue
    ArgumentError -> nil
  end

  defp save(%{path: nil} = s), do: %{s | dirty: MapSet.new()}

  defp save(s) do
    for {origin, name} = key <- s.dirty, not String.starts_with?(origin, "opaque:") do
      file = file_of(s.path, key)

      try do
        case s.dbs[key] do
          %{schema: schema} = db when schema != nil ->
            File.mkdir_p!(s.path)
            tmp = file <> ".#{System.unique_integer([:positive])}.tmp"

            File.write!(
              tmp,
              :erlang.term_to_binary({origin, name, db.version, schema, db.recs, db.idx})
            )

            File.rename!(tmp, file)

          _ ->
            File.rm(file)
        end
      rescue
        _ -> :error
      end
    end

    if s.timer, do: Process.cancel_timer(s.timer)
    %{s | dirty: MapSet.new(), timer: nil}
  end
end
