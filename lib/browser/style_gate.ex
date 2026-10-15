defmodule Browser.StyleGate do
  @moduledoc """
  One style run at a time for the prewarm layouts of a tab (`Browser.JS.DOM.prewarm_layout/0`).

  A layout for the scripts first styles the tree (`Browser.Page.from_raw/3`). It starts from the
  style state of the run before it, so an element that did not change is not styled again. Two
  runs that overlap both start from the same state: the second gets no help from the first, and
  each takes CPU from the other and from the scripts.

  * A prewarm (`ref` nil) waits while a run styles. It starts when that run sends its style
    state, or when its process stops: a crash does not keep the gate closed.
  * A newer request of the same script replaces its prewarm that waits: the newer tree comes
    from the same scripts.
  * A request that a script waits for starts at once, as without the gate. To wait for the
    run in flight was slower: in the Speedometer Lit suite the style of the new tree takes
    almost as long with the state of that run as without it.

  The gate is pure. The caller starts the requests that it gives, monitors their processes, and
  tells the gate with `running/3`, `style_done/2` and `down/2`. When it does not start a request
  that the gate gave, it asks for the next one with `next/1`.
  """

  defstruct runs: %{}, queue: [], seq: 0, adopted: 0

  @doc "A gate with no run in flight."
  def new, do: %__MODULE__{}

  @doc """
  A request: a map with `:js` (the script process) and `:ref` (nil for a prewarm), plus what the
  caller needs to start it. Gives the requests to start now, each with its number in `:seq`.
  """
  def request(%__MODULE__{} = gate, %{js: js, ref: ref} = req) do
    seq = gate.seq + 1
    req = Map.put(req, :seq, seq)
    queue = Enum.reject(gate.queue, &(&1.js == js))
    gate = %{gate | seq: seq, queue: queue}

    if ref == nil and map_size(gate.runs) > 0,
      do: {[], %{gate | queue: queue ++ [req]}},
      else: {[req], gate}
  end

  @doc "Tells the gate that the request `seq` styles in a process that the caller monitors with `mon`."
  def running(%__MODULE__{} = gate, seq, mon), do: %{gate | runs: Map.put(gate.runs, seq, mon)}

  @doc """
  The run `seq` sent its style state. Gives whether the caller adopts that state (not when a
  newer request sent its state first), the monitor of the run (for the caller to remove), and
  the requests to start now.
  """
  def style_done(%__MODULE__{} = gate, seq) do
    {mon, runs} = Map.pop(gate.runs, seq)
    adopt? = seq > gate.adopted
    {next, gate} = next(%{gate | runs: runs, adopted: max(seq, gate.adopted)})
    {adopt?, mon, next, gate}
  end

  @doc """
  The process that `mon` monitors stopped. When it stopped before it sent its style state, it
  no longer counts as a run: the next request can start.
  """
  def down(%__MODULE__{} = gate, mon) do
    case Enum.find(gate.runs, fn {_, m} -> m == mon end) do
      nil -> {[], gate}
      {seq, _} -> next(%{gate | runs: Map.delete(gate.runs, seq)})
    end
  end

  @doc """
  The request that waits first, when no run is in flight. The caller asks for it when it did not
  start a request that the gate gave.
  """
  def next(%__MODULE__{runs: runs, queue: [req | rest]} = gate) when map_size(runs) == 0,
    do: {[req], %{gate | queue: rest}}

  def next(%__MODULE__{} = gate), do: {[], gate}
end
