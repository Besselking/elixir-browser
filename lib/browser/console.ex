defmodule Browser.Console do
  @moduledoc """
  The console log of every page: what `console.log` and friends printed, uncaught errors and
  promise rejections, and what the developer console evaluated.

  A page's JavaScript runtime writes here (see `Browser.JS.Runtime`), keyed by the runtime's
  pid. The console window reads it. The log of a page keeps its newest #{1000} lines and goes
  away when the runtime stops.

  An entry is `{seq, level, text, time}`. `seq` counts up from 1 for one page and is never
  reused, even after `clear/1`, so a reader that remembers the last `seq` it saw gets only
  what is new. `level` is `:log`, `:warn`, `:error`, `:input` (a line typed in the console)
  or `:result` (its value).
  """

  use Agent

  @table :browser_console
  @keep 1000

  @type level :: :log | :warn | :error | :input | :result
  @type entry :: {pos_integer, level, String.t(), integer}

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

  @doc "Adds `[{level, text}]` to the log of `pid`."
  @spec add(pid, [{level, String.t()}]) :: :ok
  def add(_pid, []), do: :ok

  def add(pid, lines) do
    now = System.system_time(:millisecond)
    last = :ets.update_counter(@table, {pid, :n}, {2, length(lines)}, {{pid, :n}, 0})
    first = last - length(lines) + 1

    lines
    |> Enum.with_index(first)
    |> Enum.each(fn {{level, text}, seq} ->
      :ets.insert(@table, {{pid, seq}, {level, text, now}})
    end)

    :ets.select_delete(@table, [{{{pid, :"$1"}, :_}, [{:"=<", :"$1", last - @keep}], [true]}])
    :ok
  rescue
    # the log is not running (the application is stopped)
    ArgumentError -> :ok
  end

  @doc "The entries of `pid` after `seq`, oldest first."
  @spec since(pid | nil, non_neg_integer) :: [entry]
  def since(nil, _seq), do: []

  def since(pid, seq) do
    spec = [
      {{{pid, :"$1"}, {:"$2", :"$3", :"$4"}},
       [{:andalso, {:is_integer, :"$1"}, {:>, :"$1", seq}}], [{{:"$1", :"$2", :"$3", :"$4"}}]}
    ]

    :ets.select(@table, spec)
  rescue
    ArgumentError -> []
  end

  @doc "The newest `seq` of `pid` (0 when nothing was logged)."
  @spec last_seq(pid | nil) :: non_neg_integer
  def last_seq(nil), do: 0

  def last_seq(pid) do
    case :ets.lookup(@table, {pid, :n}) do
      [{_, n}] -> n
      [] -> 0
    end
  rescue
    ArgumentError -> 0
  end

  @doc "Forgets the entries of `pid`; the numbering goes on."
  @spec clear(pid | nil) :: :ok
  def clear(nil), do: :ok

  def clear(pid) do
    :ets.select_delete(@table, [{{{pid, :"$1"}, :_}, [{:is_integer, :"$1"}], [true]}])
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc "Forgets everything about `pid` (its runtime stopped)."
  @spec drop(pid) :: :ok
  def drop(pid) do
    :ets.select_delete(@table, [{{{pid, :_}, :_}, [], [true]}])
    :ok
  rescue
    ArgumentError -> :ok
  end
end
