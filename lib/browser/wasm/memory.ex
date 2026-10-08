defmodule Browser.Wasm.Memory do
  @moduledoc """
  A linear memory. The bytes live in the process dictionary as a tuple of 64 KiB pages, so
  that a store copies one page and not the whole memory. A memory value is the struct, which
  only holds the key and the limit.
  """

  import Bitwise
  alias Browser.Wasm.Error

  @page 65536
  @zero_page <<0::size(524_288)>>
  @max_pages 65536

  defstruct [:id, :max, shared: false, addr: :i32]

  def page_size, do: @page

  @doc "A new memory of `min` pages (zeros) that can grow to `max` pages (`nil`: no limit)."
  def new(min, max, shared \\ false, addr \\ :i32) do
    if min > @max_pages,
      do: Error.fail(:compile, "memory size must be at most 65536 pages (4GiB)")

    id = make_ref()
    Process.put({__MODULE__, id}, Tuple.duplicate(@zero_page, min))
    %__MODULE__{id: id, max: max, shared: shared, addr: addr}
  end

  @doc "The pages as the tuple they are now (it is a new tuple after every change)."
  def pages(%__MODULE__{id: id}), do: Process.get({__MODULE__, id})

  @doc "The size in pages."
  def size(%__MODULE__{id: id}), do: tuple_size(Process.get({__MODULE__, id}))

  @doc "Grows by `delta` pages. Returns the old size in pages, or -1 when it cannot grow."
  def grow(%__MODULE__{id: id, max: max}, delta) do
    pages = Process.get({__MODULE__, id})
    old = tuple_size(pages)
    new = old + delta
    limit = min(max || @max_pages, @max_pages)

    cond do
      new > limit ->
        -1

      delta == 0 ->
        old

      true ->
        grown = Tuple.to_list(pages) ++ List.duplicate(@zero_page, delta)
        Process.put({__MODULE__, id}, List.to_tuple(grown))
        old
    end
  end

  @doc "Reads `n` bytes at `addr` as a binary. Traps when out of bounds."
  def read(%__MODULE__{id: id}, addr, n) do
    pages = Process.get({__MODULE__, id})
    if addr + n > tuple_size(pages) * @page, do: oob()
    page = addr >>> 16
    off = addr &&& 0xFFFF

    if off + n <= @page do
      binary_part(elem(pages, page), off, n)
    else
      first = @page - off

      binary_part(elem(pages, page), off, first) <>
        binary_part(elem(pages, page + 1), 0, n - first)
    end
  end

  @doc "Writes the bytes of `bin` at `addr`. Traps when out of bounds."
  def write(%__MODULE__{id: id}, addr, bin) do
    pages = Process.get({__MODULE__, id})
    n = byte_size(bin)
    if addr + n > tuple_size(pages) * @page, do: oob()
    page = addr >>> 16
    off = addr &&& 0xFFFF

    pages =
      if off + n <= @page do
        put_elem(pages, page, patch(elem(pages, page), off, bin))
      else
        first = @page - off
        <<a::binary-size(^first), b::binary>> = bin

        pages
        |> put_elem(page, patch(elem(pages, page), off, a))
        |> put_elem(page + 1, patch(elem(pages, page + 1), 0, b))
      end

    Process.put({__MODULE__, id}, pages)
    :ok
  end

  defp patch(page, off, bin) do
    n = byte_size(bin)
    <<pre::binary-size(^off), _::binary-size(^n), post::binary>> = page
    <<pre::binary, bin::binary, post::binary>>
  end

  @doc "Sets `n` bytes at `addr` to `byte`."
  def fill(mem, addr, byte, n) do
    size = size(mem) * @page
    if addr + n > size, do: oob()
    if n > 0, do: write(mem, addr, :binary.copy(<<byte>>, n))
    :ok
  end

  @doc "Copies `n` bytes from `src_mem` to `mem` (the ranges may overlap when it is one memory)."
  def copy(mem, dst, src_mem, src, n) do
    if src + n > size(src_mem) * @page or dst + n > size(mem) * @page, do: oob()
    if n > 0, do: write(mem, dst, read(src_mem, src, n))
    :ok
  end

  @doc "All the bytes as one binary."
  def to_binary(%__MODULE__{id: id}) do
    id |> then(&Process.get({__MODULE__, &1})) |> Tuple.to_list() |> IO.iodata_to_binary()
  end

  @doc "Replaces the content with `bin` (a multiple of the page size)."
  def load_binary(%__MODULE__{id: id}, bin) do
    pages = for <<p::binary-size(65536) <- bin>>, do: p
    Process.put({__MODULE__, id}, List.to_tuple(pages))
    :ok
  end

  defp oob, do: Error.fail(:trap, "out of bounds memory access")
end
