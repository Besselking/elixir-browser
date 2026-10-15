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
  * A run that a script waits for sends its style state after its answer, so that the copy of
    the state does not delay the answer. The script can ask again before that state arrives.
    Then the new request waits for that state (or for the stop of that run): else it starts
    from an older state and styles again what that run styled. When the script asked after the
    deadline of that run (no answer came), the new request starts at once.

  The gate is pure. The caller starts the requests that it gives, monitors their processes, and
  tells the gate with `running/3`, `style_done/2` and `down/2`. When it does not start a request
  that the gate gave, it asks for the next one with `next/1`.
  """

  # `waited`: the runs that a script waits for, `seq => {js, deadline}`; `given`: the same for
  # the requests that the gate gave to start (`running/3` moves them to `waited`); `held`: the
  # requests that wait for the style state of such a run
  defstruct runs: %{}, queue: [], seq: 0, adopted: 0, waited: %{}, given: %{}, held: []

  @doc "A gate with no run in flight."
  def new, do: %__MODULE__{}

  @doc """
  A request: a map with `:js` (the script process) and `:ref` (nil for a prewarm), plus what the
  caller needs to start it. It can have a `:deadline` (monotonic ms) for a request that a script
  waits for. Gives the requests to start now, each with its number in `:seq`.
  """
  def request(%__MODULE__{} = gate, %{js: js, ref: ref} = req) do
    seq = gate.seq + 1
    req = Map.put(req, :seq, seq)
    queue = Enum.reject(gate.queue, &(&1.js == js))
    held = Enum.reject(gate.held, &(&1.js == js))
    gate = %{gate | seq: seq, queue: queue, held: held}

    cond do
      ref == nil and map_size(gate.runs) > 0 -> {[], %{gate | queue: queue ++ [req]}}
      ref != nil and answered?(gate, req) -> {[], %{gate | held: held ++ [req]}}
      true -> {[req], give(gate, req)}
    end
  end

  # whether a run that `req`'s script waited for has answered and has not sent its style state
  # yet: the script asks again before the deadline of that run
  defp answered?(gate, %{js: js} = req) do
    wait = Browser.JS.DOM.layout_wait()

    Enum.any?(gate.waited, fn {_, {j, deadline}} ->
      j == js and (deadline == nil or req[:deadline] == nil or req.deadline - wait < deadline)
    end)
  end

  defp give(gate, %{ref: nil}), do: gate

  defp give(gate, %{js: js, seq: seq} = req),
    do: %{gate | given: Map.put(gate.given, seq, {js, req[:deadline]})}

  @doc "Tells the gate that the request `seq` styles in a process that the caller monitors with `mon`."
  def running(%__MODULE__{} = gate, seq, mon) do
    {waiter, given} = Map.pop(gate.given, seq)
    waited = if waiter, do: Map.put(gate.waited, seq, waiter), else: gate.waited
    %{gate | runs: Map.put(gate.runs, seq, mon), given: given, waited: waited}
  end

  @doc """
  The run `seq` sent its style state. Gives whether the caller adopts that state (not when a
  newer request sent its state first), the monitor of the run (for the caller to remove), and
  the requests to start now.
  """
  def style_done(%__MODULE__{} = gate, seq) do
    {mon, runs} = Map.pop(gate.runs, seq)
    adopt? = seq > gate.adopted
    gate = %{gate | runs: runs, waited: Map.delete(gate.waited, seq)}
    {next, gate} = next(%{gate | adopted: max(seq, gate.adopted)})
    {adopt?, mon, next, gate}
  end

  @doc """
  The process that `mon` monitors stopped. When it stopped before it sent its style state, it
  no longer counts as a run: the next request can start.
  """
  def down(%__MODULE__{} = gate, mon) do
    case Enum.find(gate.runs, fn {_, m} -> m == mon end) do
      nil ->
        {[], gate}

      {seq, _} ->
        next(%{gate | runs: Map.delete(gate.runs, seq), waited: Map.delete(gate.waited, seq)})
    end
  end

  @doc """
  The requests to start now: those that waited for the style state of a run that is no longer
  in flight, else the prewarm that waits first, when no run is in flight. The caller asks for
  them when it did not start a request that the gate gave.
  """
  def next(%__MODULE__{} = gate) do
    {free, held} = Enum.split_with(gate.held, &(not answered?(gate, &1)))
    gate = Enum.reduce(free, %{gate | held: held}, &give(&2, &1))
    if free == [], do: next_prewarm(gate), else: {free, gate}
  end

  defp next_prewarm(%__MODULE__{runs: runs, queue: [req | rest]} = gate)
       when map_size(runs) == 0,
       do: {[req], %{gate | queue: rest}}

  defp next_prewarm(%__MODULE__{} = gate), do: {[], gate}
end
