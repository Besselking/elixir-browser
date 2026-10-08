defmodule Browser.Wasm.Table do
  @moduledoc """
  A table of references. The entries live in the process dictionary as a tuple.
  `:null` is the null reference.
  """

  alias Browser.Wasm.Error

  defstruct [:id, :type, :max]

  def new(type, min, max, init \\ :null) do
    id = make_ref()
    Process.put({__MODULE__, id}, Tuple.duplicate(init, min))
    %__MODULE__{id: id, type: type, max: max}
  end

  def size(%__MODULE__{id: id}), do: tuple_size(Process.get({__MODULE__, id}))

  def get(%__MODULE__{id: id}, i) do
    t = Process.get({__MODULE__, id})
    if i >= tuple_size(t), do: oob(), else: elem(t, i)
  end

  def set(%__MODULE__{id: id}, i, v) do
    t = Process.get({__MODULE__, id})
    if i >= tuple_size(t), do: oob()
    Process.put({__MODULE__, id}, put_elem(t, i, v))
    :ok
  end

  @doc "Grows by `delta` entries set to `init`. Returns the old size or -1."
  def grow(%__MODULE__{id: id, max: max} = tbl, delta, init) do
    t = Process.get({__MODULE__, id})
    old = tuple_size(t)
    new = old + delta

    if new > (max || 0xFFFFFFFF) or new > 10_000_000 do
      -1
    else
      Process.put(
        {__MODULE__, id},
        List.to_tuple(Tuple.to_list(t) ++ List.duplicate(init, delta))
      )

      _ = tbl
      old
    end
  end

  def fill(tbl, i, v, n) do
    if i + n > size(tbl), do: oob()
    for k <- 0..(n - 1)//1, do: set(tbl, i + k, v)
    :ok
  end

  @doc "Copies `n` entries from `src` (of `from`) to `dst` (of `tbl`)."
  def copy(tbl, dst, from, src, n) do
    if src + n > size(from) or dst + n > size(tbl), do: oob()
    vals = for k <- 0..(n - 1)//1, do: get(from, src + k)
    vals |> Enum.with_index() |> Enum.each(fn {v, k} -> set(tbl, dst + k, v) end)
    :ok
  end

  @doc "Writes `values` (a list) from index `dst`."
  def init(tbl, dst, values) do
    if dst + length(values) > size(tbl), do: oob()
    values |> Enum.with_index() |> Enum.each(fn {v, k} -> set(tbl, dst + k, v) end)
    :ok
  end

  def to_list(%__MODULE__{id: id}), do: Process.get({__MODULE__, id}) |> Tuple.to_list()

  defp oob, do: Error.fail(:trap, "out of bounds table access")
end
