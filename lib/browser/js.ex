defmodule Browser.JS do
  @moduledoc """
  A small JavaScript runtime written in Elixir: a lexer, a parser for a practical subset of
  ES2015+, a tree-walking interpreter and a handful of built-ins (see `Browser.JS.Builtins`).

  It is a standalone engine for now: it knows nothing about the DOM, `<script>` elements or
  the page. `eval/2` runs a program in a fresh, isolated process, so a script can neither hang
  the caller (it has a step budget and a wall-clock timeout) nor leak state between runs.

      iex> Browser.JS.eval("[1, 2, 3].map(x => x * 2).join('-')")
      {:ok, "2-4-6", []}

  Timers (`setTimeout`/`setInterval`) run after the main script finishes, in virtual time.
  `console` output is returned alongside the result as `{level, text}` pairs, oldest first.
  """

  alias Browser.JS.{Builtins, Interp, Parser}

  @type result :: term
  @type console :: [{:log | :warn | :error, String.t()}]

  @doc "Parses `source`: `{:ok, {:program, statements}}` or `{:error, message}`; `module: true` allows import and export."
  def parse(source, opts \\ []), do: Parser.parse(source, opts)

  @doc """
  Runs `source` and returns `{:ok, value, console}` or `{:error, reason, console}`.

  `reason` is `{:syntax, message}`, `{:uncaught, message}` (a `throw` nobody caught),
  `:step_limit` or `:timeout`. The value is plain Elixir data: numbers as floats (or `:nan`,
  `:infinity`, `:neg_infinity`), strings, booleans, `:undefined`, `nil` for `null`, lists for
  arrays, maps for objects and `:function` for functions.

  Options: `:max_steps` (calls and loop iterations, default 1,000,000) and `:timeout` in ms
  (default 5,000).
  """
  @spec eval(String.t(), keyword) :: {:ok, result, console} | {:error, term, console}
  def eval(source, opts \\ []) do
    case Parser.parse(source) do
      {:error, msg} -> {:error, {:syntax, msg}, []}
      {:ok, program} -> run(program, opts)
    end
  end

  @doc """
  The options a process that runs scripts is spawned with. The JS heap lives in the process
  dictionary, which every collection of the process walks in full, so collections should be
  rare: a big young heap, a high threshold for the garbage that binaries (big strings, typed
  array contents) account for, and no full sweeps.
  """
  def process_opts do
    [min_heap_size: 2_000_000, min_bin_vheap_size: 1_000_000, fullsweep_after: 1_000_000]
  end

  defp run(program, opts) do
    max_steps = Keyword.get(opts, :max_steps, 1_000_000)
    timeout = Keyword.get(opts, :timeout, 5_000)
    parent = self()
    ref = make_ref()

    {pid, mon} =
      :erlang.spawn_opt(
        fn -> send(parent, {ref, execute(program, max_steps)}) end,
        [:monitor | process_opts()]
      )

    receive do
      {^ref, result} ->
        Process.demonitor(mon, [:flush])
        result

      {:DOWN, ^mon, _, _, reason} ->
        {:error, {:crash, reason}, []}
    after
      timeout ->
        Process.exit(pid, :kill)
        Process.demonitor(mon, [:flush])
        {:error, :timeout, []}
    end
  end

  defp execute(program, max_steps) do
    Interp.init(max_steps)
    Builtins.install()

    try do
      value = Interp.run_program(program, true)

      try do
        Builtins.run_timers(&report_uncaught/1)
      catch
        :js_limit -> report_uncaught("step limit reached while running timers", :warn)
      end

      {:ok, export(value, 0), console()}
    catch
      {:js_error, v} -> {:error, {:uncaught, describe(v)}, console()}
      :js_limit -> {:error, :step_limit, console()}
      {:js_break, _} -> {:error, {:syntax, "illegal break"}, console()}
      {:js_continue, _} -> {:error, {:syntax, "illegal continue"}, console()}
      {:js_return, _} -> {:error, {:syntax, "illegal return"}, console()}
      :js_short -> {:error, {:uncaught, "optional chain"}, console()}
    end
  end

  defp console, do: Enum.reverse(Process.get(:js_console, []))

  defp report_uncaught(v), do: report_uncaught("Uncaught " <> describe(v), :error)

  defp report_uncaught(text, level) do
    Process.put(:js_console, [{level, text} | Process.get(:js_console, [])])
  end

  defp describe(v) when is_binary(v), do: v
  defp describe(v), do: Builtins.inspect_js(v, 0, [])

  # JavaScript values out of the heap as plain data
  defp export({:obj, _} = v, depth) do
    cond do
      depth > 20 -> :truncated
      Interp.function?(v) -> :function
      Interp.array?(v) -> v |> Interp.array_list() |> Enum.map(&export(&1, depth + 1))
      true -> Map.new(Interp.own_keys(v), &{&1, export(Interp.get(v, &1), depth + 1)})
    end
  end

  defp export(:null, _), do: nil
  defp export(v, _), do: v
end
