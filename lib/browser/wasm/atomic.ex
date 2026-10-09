defmodule Browser.Wasm.Atomic do
  @moduledoc """
  The atomic memory instructions of the threads proposal. The engine runs one thread, so an
  atomic access is a plain access that also needs natural alignment. A wait never blocks: when
  the value is equal it times out at once.
  """

  import Bitwise
  alias Browser.Wasm.{Memory, Num}

  @doc "Runs the instruction on its arguments. Returns the result, or `:none` when there is none."
  def exec(op, width, off, mem, [base | rest]) do
    addr = base + off
    if width > 0 and rem(addr, width) != 0, do: Num.trap("unaligned atomic")
    run(op, width, addr, mem, rest)
  end

  defp run(:load, w, addr, mem, []), do: read(mem, addr, w)

  defp run(:store, w, addr, mem, [v]) do
    write(mem, addr, w, v)
    :none
  end

  defp run({:rmw, op}, w, addr, mem, [v]) do
    old = read(mem, addr, w)
    write(mem, addr, w, rmw(op, old, v &&& mask(w)))
    old
  end

  defp run(:cmpxchg, w, addr, mem, [expected, replacement]) do
    old = read(mem, addr, w)
    if old == (expected &&& mask(w)), do: write(mem, addr, w, replacement)
    old
  end

  defp run(:notify, _, addr, mem, [_count]) do
    # an access out of bounds traps; there is no thread to wake
    read(mem, addr, 4)
    0
  end

  defp run(wait, w, addr, mem, [expected, _timeout]) when wait in [:wait32, :wait64] do
    unless mem.shared, do: Num.trap("expected shared memory")
    if read(mem, addr, w) != (expected &&& mask(w)), do: 1, else: 2
  end

  defp mask(w), do: (1 <<< (8 * w)) - 1

  defp rmw(:add, a, b), do: a + b
  defp rmw(:sub, a, b), do: a - b
  defp rmw(:and, a, b), do: a &&& b
  defp rmw(:or, a, b), do: a ||| b
  defp rmw(:xor, a, b), do: bxor(a, b)
  defp rmw(:xchg, _, b), do: b

  defp read(mem, addr, w) do
    bits = w * 8
    <<v::little-size(^bits)>> = Memory.read(mem, addr, w)
    v
  end

  defp write(mem, addr, w, v), do: Memory.write(mem, addr, binary_part(<<v::little-64>>, 0, w))
end
