# Usage: RESOLVE=4 mix run --no-start bench/js_control_count.exs [name ...]
#        RESOLVE=4 mix run --no-start bench/js_control_count.exs URL [SUITES] [TIMEOUT_S]
#
# This script counts how often the interpreter does the work that step 3 changes (see
# notes/js-step3-design.md, section 1.4). It does not measure time. The counts do not change
# with the speed of the machine, so you can compare two builds with them.
#
# Without a URL, the script runs the nine programs and the five step 3 programs of
# bench/js_runtime.exs one time each. It reads the programs from that file, so the two
# scripts always run the same code. The script takes less than 5 seconds at level 4.
#
# With a URL, the script runs bench/speedometer.exs with the same arguments (URL, SUITES and
# TIMEOUT_S) and prints one row for the whole run.
#
# A run counts the throws, or the writes of `:js_last` when JS_LAST=1 is set. It cannot
# count both (see the trace control word below). The trace of the writes makes a run about
# two times slower, because the JS heap also lives in the process dictionary.
#
# RESOLVE is the resolver level (`off`, `info`, 1, 2, 3 or 4). The default is 4, because
# level 4 is the default of the engine.
#
# The columns:
#
# - `eval_list`: calls of `eval_list/2`, which evaluates the arguments of a call and the
#   items of an array literal. Before commit 4 of step 3 there is one call for each list.
#   From commit 4 the function calls itself for each item, so there is one call for each
#   item and one for the end of the list.
# - `run_body`: calls of `run_body/3` (`run_body/4` from commit 10 of step 3), one for each
#   round of a loop.
# - `throws`: Elixir throws of `{:js_return}`, `{:js_break}`, `{:js_continue}` and
#   `{:js_tail}`. Before step 3, each `return` below the top of a body, each `break` and
#   `continue` and each strict tail call is a throw. After step 3, this column is 0.
# - `js_last`: writes of the completion value `:js_last` to the process dictionary.
# - `tail_value`, `no_tail`, `tail_loop`: calls of these functions.
#
# A function that a build does not have shows `-`. The column that a run does not count
# shows `-` too.
alias Browser.JS
alias Browser.JS.Interp

# The functions that the script counts with `call_count`, each with the arities that a
# build can have. These counts cost little, because the VM keeps them in the function's
# code and sends no message.
counted = [eval_list: [2], run_body: [3, 4], tail_value: [2], no_tail: [1], tail_loop: [3]]

resolve =
  case System.get_env("RESOLVE", "4") do
    "off" -> :off
    "info" -> :info
    "1" -> 1
    "2" -> 2
    "3" -> 3
    "4" -> 4
    other -> raise "RESOLVE takes off, info, 1, 2, 3 or 4, not #{other}"
  end

# The program lists of bench/js_runtime.exs. The script evaluates only the assignments that
# make the lists. It does not run that file, because the file runs every program 5 times.
runtime_programs = fn ->
  path = Path.join(__DIR__, "js_runtime.exs")
  {:__block__, _, exprs} = Code.string_to_quoted!(File.read!(path))
  wanted = [:wrap, :big_body, :programs, :programs_3]

  defs =
    Enum.filter(exprs, fn
      {:=, _, [{name, _, ctx}, _]} when is_atom(ctx) -> name in wanted
      _ -> false
    end)

  {result, _} =
    Code.eval_quoted(
      {:__block__, [], defs ++ [Code.string_to_quoted!("{wrap, programs, programs_3}")]}
    )

  result
end

Code.ensure_loaded!(Interp)

# The arity of each counted function in this build, or `nil` when the build does not have
# the function.
arity =
  Map.new(counted, fn {f, arities} ->
    {f,
     Enum.find(
       arities,
       &(:erlang.trace_pattern({Interp, f, &1}, true, [:local, :call_count]) == 1)
     )}
  end)

# A throw and a write of `:js_last` are calls of the BIFs `erlang:throw/1` and
# `erlang:put/2`. A `call_count` pattern takes no match spec, so it cannot select the calls
# with a given argument. A trace message for each call is too slow: 60,000 messages take
# more than 30 seconds. So the match spec adds 1 to the trace control word, a global
# counter of the VM, and sends no message. There is only one such word, so one run counts
# only one of the two kinds.
bump = [{:set_tcw, {:+, {:get_tcw}, 1}}, {:message, false}]

count_throws = fn on ->
  pats = [{:js_return, :_}, {:js_break, :_}, {:js_continue, :_}, {:js_tail, :_, :_, :_}]
  ms = if on, do: for(pat <- pats, do: {[pat], [], bump}), else: false
  :erlang.trace_pattern({:erlang, :throw, 1}, ms, [:local])
end

count_js_last = fn on ->
  ms = if on, do: [{[:js_last, :_], [], bump}], else: false
  :erlang.trace_pattern({:erlang, :put, 2}, ms, [:local])
end

# Every JS run happens in a new process (`JS.eval` and the runtime of a page spawn one), so
# only new processes get the call trace. The match specs send no message, so the tracer
# gets nothing.
:erlang.trace(:new_processes, true, [:call, :arity, {:tracer, self()}])

# Sets every count back to 0.
reset = fn ->
  :erlang.system_flag(:trace_control_word, 0)

  for {f, a} <- arity,
      a != nil,
      do: :erlang.trace_pattern({Interp, f, a}, :restart, [:local, :call_count])
end

# The counts of `call_count` since the last reset.
calls = fn ->
  Map.new(arity, fn {f, a} ->
    n =
      if a do
        {:call_count, n} = :erlang.trace_info({Interp, f, a}, :call_count)
        n
      end

    {f, n}
  end)
end

tcw = fn -> :erlang.system_info(:trace_control_word) end

columns = [
  eval_list: "eval_list",
  run_body: "run_body",
  throws: "throws",
  js_last: "js_last",
  tail_value: "tail_value",
  no_tail: "no_tail",
  tail_loop: "tail_loop"
]

widths = Enum.map(columns, fn {_, h} -> max(String.length(h), 8) + 2 end)

print_row = fn name, counts ->
  cells =
    columns
    |> Enum.zip(widths)
    |> Enum.map(fn {{k, _}, w} ->
      v =
        case Map.get(counts, k) do
          nil -> "-"
          n -> Integer.to_string(n)
        end

      String.pad_leading(v, w)
    end)

  IO.puts(String.pad_trailing(name, 16) <> Enum.join(cells))
end

IO.puts(
  String.pad_trailing("program", 16) <>
    (columns |> Enum.zip(widths) |> Enum.map_join(fn {{_, h}, w} -> String.pad_leading(h, w) end))
)

js_last? = System.get_env("JS_LAST") == "1"
count_throws.(not js_last?)
count_js_last.(js_last?)
key = if js_last?, do: :js_last, else: :throws

case System.argv() do
  ["http" <> _ | _] = argv ->
    reset.()
    # The Speedometer script reads its own arguments. It loads the page and runs the suites
    # until they end.
    System.argv(argv)
    Code.eval_file(Path.join(__DIR__, "speedometer.exs"))
    print_row.("speedometer", Map.put(calls.(), key, tcw.()))

  filter ->
    {wrap, programs, programs_3} = runtime_programs.()
    opts = [max_steps: 1_000_000_000, timeout: 300_000, resolve: resolve]

    for {id, _name, _qjs, expected, body} <- programs ++ programs_3,
        filter == [] or Enum.any?(filter, &String.contains?(id, &1)) do
      reset.()
      {:ok, value, _} = JS.eval(wrap.(body), opts)
      if value != expected, do: raise("#{id}: #{inspect(value)}, expected #{inspect(expected)}")
      print_row.(id, Map.put(calls.(), key, tcw.()))
    end
end
