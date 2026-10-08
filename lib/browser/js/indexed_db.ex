defmodule Browser.JS.IndexedDB do
  @moduledoc """
  `indexedDB` and the `IDB*` classes: the JavaScript in `priv/js/indexeddb.js`, run the first
  time a page uses one of the names (the web API prelude defines them as lazy properties of the
  window, which call `__load_idb`). The storage is `Browser.IndexedDB`; this module gives the
  script its few native functions, and hands it the messages that other pages cause.
  """

  alias Browser.JS.{Interp, Parser}

  @source Path.expand("../../../priv/js/indexeddb.js", __DIR__)
  @external_resource @source
  @code File.read!(@source)

  @doc "Declares the natives of the script and `__load_idb`."
  def install(scope) do
    def_fn(scope, "__load_idb", fn _ ->
      load()
      :undefined
    end)

    # the script says which function hears of the messages from the store
    def_fn(scope, "__idb_hook", fn [f | _] ->
      Process.put(:idb_hook, f)
      :undefined
    end)

    def_fn(scope, "__idb_unhex", fn [hex | _] ->
      Browser.JS.TypedArrays.buffer_from_hex(hex)
    end)

    def_fn(scope, "__idb_names", fn _ ->
      Interp.new_array(
        for {name, version} <- Browser.IndexedDB.names(origin()),
            do: Interp.new_array([name, version * 1.0])
      )
    end)

    def_fn(scope, "__idb_load", fn [name, rev | _] ->
      rev = if is_number(rev), do: trunc(rev)

      case Browser.IndexedDB.load(origin(), name, rev) do
        :none -> :undefined
        :same -> true
        {:ok, rev, version, data} -> Interp.new_array([rev * 1.0, version * 1.0, data])
      end
    end)

    # (name, version, [[store, meta, [[index, meta], ...]], ...], [[op, ...], ...]) -> revision, or
    # -1 when the database is too big
    def_fn(scope, "__idb_save", fn [name, version, schema, ops | _] ->
      schema =
        for st <- Interp.array_list(schema) do
          [store, meta, indexes] = Interp.array_list(st)
          [store, meta, for(ix <- Interp.array_list(indexes), do: Interp.array_list(ix))]
        end

      ops = for op <- Interp.array_list(ops), do: Interp.array_list(op)

      case Browser.IndexedDB.save(origin(), name, trunc(version), schema, ops) do
        :quota -> -1.0
        rev -> rev * 1.0
      end
    end)

    def_fn(scope, "__idb_delete", fn [name | _] ->
      Browser.IndexedDB.delete(origin(), name)
      :undefined
    end)

    # (name, version | undefined | "delete", id) -> [token, ready?]
    def_fn(scope, "__idb_begin", fn [name, version, id | _] ->
      kind =
        case version do
          "delete" -> :delete
          v when is_number(v) -> {:open, trunc(v)}
          _ -> {:open, nil}
        end

      {state, token} = Browser.IndexedDB.begin(origin(), name, kind, trunc(id))
      Interp.new_array([token * 1.0, state == :ready])
    end)

    def_fn(scope, "__idb_settled", fn [name, token | _] ->
      Browser.IndexedDB.settled(origin(), name, trunc(token))
      :undefined
    end)

    def_fn(scope, "__idb_finish", fn [name, token, conn | _] ->
      conn = if is_number(conn), do: trunc(conn)
      Browser.IndexedDB.finish(origin(), name, trunc(token), conn)
      :undefined
    end)

    def_fn(scope, "__idb_close", fn [name, conn | _] ->
      Browser.IndexedDB.close(origin(), name, trunc(conn))
      :undefined
    end)
  end

  defp def_fn(scope, name, fun) do
    Interp.declare(
      scope,
      name,
      Interp.native(name, fn _this, args -> fun.(args ++ List.duplicate(:undefined, 4)) end)
    )
  end

  defp origin do
    case Process.get(:idb_origin) do
      nil ->
        o = Browser.IndexedDB.origin(Browser.JS.DOM.page_url())
        Process.put(:idb_origin, o)
        o

      o ->
        o
    end
  end

  @doc "Runs the script once in this runtime."
  def load do
    unless Process.get(:idb_loaded) do
      Process.put(:idb_loaded, true)

      case program() do
        {:ok, ast} -> Interp.run_program(ast)
        {:error, msg} -> throw({:syntax, "indexeddb: " <> msg})
      end
    end

    :ok
  end

  @doc """
  A message from `Browser.IndexedDB` (`{:idb, ...}`) reaches the script, which fires the events
  it means. Does nothing before the script is loaded: no connection of this page can be open then.
  """
  def deliver(msg) do
    with f when f != nil <- Process.get(:idb_hook) do
      args =
        case msg do
          {:idb, :versionchange, _origin, name, token, old, new} ->
            ["versionchange", name, token * 1.0, old * 1.0, if(new, do: new * 1.0, else: :null)]

          {:idb, kind, id} ->
            [Atom.to_string(kind), id * 1.0]
        end

      Interp.call(f, :undefined, args)
    end

    :ok
  end

  defp program do
    case :persistent_term.get({__MODULE__, :ast}, nil) do
      nil ->
        with {:ok, ast} <- Parser.parse(@code) do
          :persistent_term.put({__MODULE__, :ast}, {:ok, ast})
          {:ok, ast}
        end

      cached ->
        cached
    end
  end
end
