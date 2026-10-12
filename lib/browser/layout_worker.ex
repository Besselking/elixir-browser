defmodule Browser.LayoutWorker do
  @moduledoc """
  The process that lays the pages of a window out and keeps, per tab, what each layout leaves
  for the next: the memo of `Browser.Layout.layout_kept/6`. The memo stays in this process's
  heap: it is never copied in or out, and it never makes the session's heap bigger.

  The tree goes in and the items come out as messages. A caller that finds the worker busy
  lays the page out itself, without the memo: a layout is not kept waiting behind another one
  (only, rarely, behind one that started as it asked).
  """

  alias Browser.Layout

  defstruct [:pid, :busy]

  @doc """
  Starts the worker, linked to the caller. `measure` is the measurer every layout in the worker
  uses (it is part of what a memo is valid for, so it must be the same function each time);
  `wx_env` is the caller's wx environment (`:wx.get_env/0`) when the measurer needs wx.
  """
  def start(measure, wx_env \\ nil) do
    busy = :atomics.new(1, [])

    # (a layout allocates a lot: a big initial heap saves growing it by many collections)
    pid =
      :erlang.spawn_opt(
        fn ->
          if wx_env, do: :wx.set_env(wx_env)
          loop(%{measure: measure, busy: busy, memos: %{}})
        end,
        [:link, min_heap_size: 2_000_000]
      )

    %__MODULE__{pid: pid, busy: busy}
  end

  @doc """
  Lays `nodes` out for `tab` (any term that names the tab) and returns `{items, height}`: in the
  worker, with what the tab's last layout left, or in the caller, without, when the worker is
  busy. `measure` is the caller's measurer, for when it lays out itself; `opts` are those of
  `Browser.Layout.layout/5` (with `metrics: true` for the measurer's font metrics).
  """
  def layout(%__MODULE__{} = worker, tab, nodes, width, measure, view_h, opts) do
    if busy?(worker) do
      Layout.layout(nodes, width, measure, view_h, metrics(opts, measure))
    else
      ref = Process.monitor(worker.pid)
      send(worker.pid, {:layout, tab, {nodes, width, view_h, opts}, {self(), ref}})

      receive do
        {^ref, {:ok, result}} ->
          Process.demonitor(ref, [:flush])
          result

        {^ref, {:error, kind, reason, stack}} ->
          Process.demonitor(ref, [:flush])
          :erlang.raise(kind, reason, stack)

        {:DOWN, ^ref, _, _, reason} ->
          exit(reason)
      end
    end
  end

  @doc "Forgets what was kept for `tab` (a tab that was closed)."
  def drop(%__MODULE__{pid: pid}, tab), do: send(pid, {:drop, tab})

  defp busy?(worker), do: :atomics.get(worker.busy, 1) == 1

  defp metrics(opts, measure) do
    if opts[:metrics], do: Keyword.put(opts, :metrics, &measure.(:content_height, &1)), else: opts
  end

  defp loop(state) do
    receive do
      {:layout, tab, {nodes, width, view_h, opts}, {pid, ref}} ->
        :atomics.put(state.busy, 1, 1)

        memo =
          try do
            opts = metrics(opts, state.measure)
            memo = Map.get(state.memos, tab)

            {items, height, memo} =
              Layout.layout_kept(nodes, width, state.measure, view_h, opts, memo)

            send(pid, {ref, {:ok, {items, height}}})
            memo
          catch
            # (raised in the caller; the memo of a layout that failed is not trusted)
            kind, reason ->
              send(pid, {ref, {:error, kind, reason, __STACKTRACE__}})
              nil
          end

        :atomics.put(state.busy, 1, 0)
        memos = if memo, do: Map.put(state.memos, tab, memo), else: Map.delete(state.memos, tab)
        loop(%{state | memos: memos})

      {:drop, tab} ->
        loop(%{state | memos: Map.delete(state.memos, tab)})
    end
  end
end
