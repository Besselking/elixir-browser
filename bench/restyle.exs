# Usage: mix run --no-start bench/restyle.exs FILE [N]
# FILE is a tree that `DUMPRAW=dir bench/speedometer.exs ...` kept. Times `Browser.Page.from_raw/3`
# (the cascade for a tree whose sheets are known, with no memo to start from) and the layout.
# PROF=1 prints the functions that take the time (eprof).
Application.put_env(:browser, :gui, false)
{:ok, _} = Application.ensure_all_started(:browser)
[file | rest] = System.argv()
n = String.to_integer(Enum.at(rest, 0) || "5")
{base, raw, cache} = file |> File.read!() |> :erlang.binary_to_term()
env = %{type: "screen", width: 1000, height: 800, dppx: 1.0, font_units: nil}
base = %{base | sheet_cache: cache}

time = fn f ->
  t = System.monotonic_time(:microsecond)
  r = f.()
  {div(System.monotonic_time(:microsecond) - t, 1000), r}
end

run = fn -> Browser.Page.from_raw(%{base | memo: nil, key: nil, nodes: nil, pruned: nil}, raw, env) end
cold_run = run
# the first call fetches and parses the sheets the tree names
{cold, laid} = time.(run)
IO.puts("cold from_raw ms: #{cold}")
base = %{base | sheet_cache: laid.sheet_cache, sheet_refs: laid.sheet_refs, rules: laid.rules, queries: laid.queries}
run = fn -> Browser.Page.from_raw(%{base | memo: nil, key: nil, nodes: nil, pruned: nil}, raw, env) end

if System.get_env("TPROF") do
  # exact time per function (call_time tracing: slow, but not blind inside a NIF)
  Code.prepend_path(Path.join([to_string(:code.root_dir()), "lib", "tools-4.2.3", "ebin"]))
  :tprof.profile(fn -> run.() end, %{type: :call_time, set_on_spawn: false})
  |> then(fn {_, [{_, res}]} -> res end)
  |> elem(1)
  |> then(&:tprof.format(%{call_time: &1}))
  |> IO.puts()
end

if System.get_env("PROF") do
  # (samples the stack of the process that works, every millisecond)
  me = self()

  worker =
    spawn(fn ->
      for _ <- 1..n, do: run.()
      send(me, :done)
    end)

  sample = fn sample, acc ->
    receive do
      :done ->
        acc
    after
      1 ->
        case Process.info(worker, :current_stacktrace) do
          {_, [{m, f, a, _} | _] = st} ->
            fs = st |> Enum.map(fn {m, f, a, _} -> {m, f, a} end) |> Enum.uniq()
            # (who calls into Regex: the first function above it that is not)
            caller = if m == Regex, do: [{:caller, Enum.find(fs, fn {m, _, _} -> m != Regex end)}], else: []
            sample.(sample, [{:self, {m, f, a}} | Enum.map(fs, &{:incl, &1}) ++ caller ++ acc])

          _ ->
            sample.(sample, acc)
        end
    end
  end

  acc = sample.(sample, [])

  for kind <- [:self, :incl, :caller] do
    IO.puts("-- #{kind}")

    acc
    |> Enum.filter(&match?({^kind, _}, &1))
    |> Enum.frequencies()
    |> Enum.sort_by(&elem(&1, 1), :desc)
    |> Enum.take(32)
    |> Enum.each(fn {{_, {m, f, a}}, c} ->
      IO.puts("#{String.pad_leading(Integer.to_string(c), 6)} #{inspect(m)}.#{f}/#{a}")
    end)
  end
else
  times = for _ <- 1..n, do: elem(time.(run), 0)
  IO.puts("from_raw ms: #{inspect(times)}")
  {_, laid} = time.(run)
  lt = for _ <- 1..3, do: elem(time.(fn -> Browser.Layout.layout(laid.nodes, 1000, &Browser.Screenshot.measure/2, 800, scrollers: true, boxes: true, svg_defs: laid.svg_defs) end), 0)
  IO.puts("layout ms: #{inspect(lt)}")
end
