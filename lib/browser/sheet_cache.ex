defmodule Browser.SheetCache do
  @moduledoc """
  The parsed rules of big style sheets, shared by all processes (`Browser.Style.parse_sheet/3`).

  Each layout process makes its style from the start. When it gets no style memo, it parses each
  sheet again, and a big sheet takes 100 ms or more. This cache keeps the result in a public ETS
  table that this process owns. The key is `{origin, css, base}`. The parsed value depends on
  the address of the sheet only when a declaration contains `url(`. Thus `base` is `nil` for a
  sheet without one, else `{:base, address}`.
  When the keys pass 32 MB or the table passes 64 MB, the table is cleared.
  """
  use GenServer

  @table __MODULE__
  @max_key_bytes 32 * 1024 * 1024
  @max_words div(64 * 1024 * 1024, :erlang.system_info(:wordsize))

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(_) do
    :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
    {:ok, nil}
  end

  @doc "The rules kept for `key`, or nil. Without the table (the application is not started), nil."
  def get(key) do
    if table?() do
      case :ets.lookup(@table, key) do
        [{_, rules}] -> rules
        [] -> nil
      end
    end
  end

  @doc "Keeps `rules` for `key` (`{origin, css, base}`) and gives them back."
  def put({_origin, css, _base} = key, rules) do
    if table?() do
      bytes = :ets.update_counter(@table, :key_bytes, byte_size(css), {:key_bytes, 0})

      # (other processes can add at the same time: the limits are approximate)
      if bytes > @max_key_bytes or :ets.info(@table, :memory) > @max_words do
        :ets.delete_all_objects(@table)
        :ets.insert(@table, {:key_bytes, byte_size(css)})
      end

      :ets.insert(@table, {key, rules})
    end

    rules
  end

  @doc "Removes all entries."
  def clear, do: if(table?(), do: :ets.delete_all_objects(@table))

  defp table?, do: :ets.whereis(@table) != :undefined
end
