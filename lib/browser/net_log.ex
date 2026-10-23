defmodule Browser.NetLog do
  @moduledoc """
  The network log: one entry for every request the browser makes (documents, stylesheets,
  scripts, images, `fetch` and `XMLHttpRequest`), each hop of a redirect on its own. The
  network window (`Browser.NetworkWindow`) shows it.

  `Browser.Fetch` writes here. An entry is a map with `:seq` (counts up from 1, never
  reused), `:time` (when the request started, in milliseconds), `:method`, `:url`, `:status`
  (nil when the request failed), `:status_text`, `:type` (see `type/3`), `:size` (bytes as
  received), `:ms` (how long it took), `:source` (`:network`, `:cache` for a fresh cached
  copy, `:revalidated` for a cached copy the server confirmed, `:error`), `:error`,
  `:request_headers`, `:response_headers` (lists of `{name, value}`) and `:initiator` (the
  address of the page that asked, nil for the address bar) and `:tab` (the id of the tab that
  made the request, see `put_tab/1`, nil when unknown). The log keeps the newest #{2000}, of all
  tabs; the network window shows the entries of one tab.
  """

  use Agent

  @table :browser_net_log
  @keep 2000

  @doc false
  def start_link(_) do
    Agent.start_link(
      fn ->
        :ets.new(@table, [:named_table, :public, :ordered_set])
        nil
      end,
      name: __MODULE__
    )
  end

  @doc """
  Names the tab that the calling process works for: what it requests is logged for that tab.
  A process started by a `Task` of such a process (a `Task.async_stream` job) works for the
  same tab; one made with `spawn` takes it on with `tag/2`.
  """
  def put_tab(tab), do: Process.put(:net_tab, tab)

  @doc "The tab that the calling process works for (see `put_tab/1`), or nil."
  def tab do
    case Process.get(:net_tab) do
      nil -> Enum.find_value(Process.get(:"$callers", []), &caller_tab/1)
      tab -> tab
    end
  end

  defp caller_tab(pid) do
    with {:dictionary, dict} <- Process.info(pid, :dictionary),
         {:net_tab, tab} when tab != nil <- List.keyfind(dict, :net_tab, 0) do
      tab
    else
      _ -> nil
    end
  end

  @doc "Wraps `fun` so that the process that runs it works for `tab` (for `spawn` and `Task.start`)."
  def tag(tab, fun) do
    fn ->
      put_tab(tab)
      fun.()
    end
  end

  @doc "Adds an entry (a map without `:seq`); returns its number."
  @spec add(map) :: pos_integer | nil
  def add(entry) do
    seq = :ets.update_counter(@table, :n, {2, 1}, {:n, 0})
    :ets.insert(@table, {seq, entry |> Map.put(:seq, seq) |> Map.put_new(:tab, tab())})

    :ets.select_delete(@table, [
      {{:"$1", :_}, [{:is_integer, :"$1"}, {:"=<", :"$1", seq - @keep}], [true]}
    ])

    seq
  rescue
    # the log is not running
    ArgumentError -> nil
  end

  @doc "The entries after `seq`, oldest first; of the tab `tab` only, unless it is `:all`."
  @spec since(non_neg_integer, term) :: [map]
  def since(seq, tab \\ :all) do
    guards = [{:is_integer, :"$1"}, {:>, :"$1", seq}]

    guards =
      if tab == :all,
        do: guards,
        else: guards ++ [{:"=:=", {:map_get, :tab, :"$2"}, {:const, tab}}]

    :ets.select(@table, [{{:"$1", :"$2"}, guards, [:"$2"]}])
  rescue
    ArgumentError -> []
  end

  @doc "The newest number (0 when nothing was logged)."
  @spec last_seq() :: non_neg_integer
  def last_seq do
    case :ets.lookup(@table, :n) do
      [{_, n}] -> n
      [] -> 0
    end
  rescue
    ArgumentError -> 0
  end

  @doc "The entry numbered `seq`, or nil."
  @spec get(pos_integer) :: map | nil
  def get(seq) do
    case :ets.lookup(@table, seq) do
      [{_, entry}] -> entry
      [] -> nil
    end
  rescue
    ArgumentError -> nil
  end

  @doc "Forgets the entries (of the tab `tab` only, unless it is `:all`); the numbering goes on."
  def clear(tab \\ :all) do
    guards = [{:is_integer, :"$1"}]

    guards =
      if tab == :all,
        do: guards,
        else: guards ++ [{:"=:=", {:map_get, :tab, :"$2"}, {:const, tab}}]

    :ets.select_delete(@table, [{{:"$1", :"$2"}, guards, [true]}])
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc """
  What kind of thing a request fetched: `"document"` (a navigation), `"fetch"` (a script's
  `fetch` or `XMLHttpRequest`), else from the `Content-Type` (or the file name): `"html"`,
  `"css"`, `"script"`, `"image"`, `"font"`, `"json"` or `"other"`.
  """
  @spec type(atom, [{String.t(), String.t()}], String.t()) :: String.t()
  def type(kind, headers, url)
  def type(:document, _, _), do: "document"
  def type(:fetch, _, _), do: "fetch"

  def type(_, headers, url) do
    ctype =
      case List.keyfind(headers, "content-type", 0) do
        {_, v} -> v |> String.downcase() |> String.split(";") |> hd() |> String.trim()
        nil -> ""
      end

    ext =
      url |> URI.parse() |> Map.get(:path) |> to_string() |> Path.extname() |> String.downcase()

    cond do
      ctype == "text/html" or ext in [".html", ".htm"] ->
        "html"

      ctype == "text/css" or ext == ".css" ->
        "css"

      String.contains?(ctype, "javascript") or ext in [".js", ".mjs"] ->
        "script"

      String.starts_with?(ctype, "image/") or ext in ~w(.png .jpg .jpeg .gif .webp .svg .ico) ->
        "image"

      String.starts_with?(ctype, "font/") or ext in ~w(.woff .woff2 .ttf .otf) ->
        "font"

      String.contains?(ctype, "json") or ext == ".json" ->
        "json"

      true ->
        "other"
    end
  end
end
