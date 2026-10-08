# Usage: mix run --no-start bench/speedometer.exs URL [SUITES] [TIMEOUT_S]
# Runs Speedometer 3.1 headlessly. URL is the folder with a local mirror, for example
# http://localhost:8765/Speedometer3.1/ . SUITES is a comma separated list of suite names.
# Prints console lines and the time until the run ends.
alias Browser.{Fetch, Page}
alias Browser.JS.Runtime

[url | rest] = System.argv()
suites = Enum.at(rest, 0)
timeout = String.to_integer(Enum.at(rest, 1) || "300") * 1000
Application.put_env(:browser, :gui, false)
{:ok, _} = Application.ensure_all_started(:browser)

full = url <> "index.html?startAutomatically&iterationCount=1" <> if(suites, do: "&suites=" <> suites, else: "")
{:ok, page} = Page.load(full)
info = %{url: page.url, base: page.base || page.url, width: 1000, height: 800, fetch: &Fetch.load/1}
t0 = System.monotonic_time(:millisecond)
pid = Runtime.start(page.raw, info)
print = fn reply ->
  for {level, text} <- Map.get(reply, :console, []) do
    IO.puts("[#{div(System.monotonic_time(:millisecond) - t0, 1000)}s #{level}] #{String.slice(text, 0, 300)}")
  end
end

diff = fn
  _, nil -> 0
  {a1, a2, a3}, {b1, b2, b3} -> ((a1 - b1) * 1_000_000 + (a2 - b2)) * 1_000_000 + (a3 - b3)
end
diff = fn a, b -> div(diff.(a, b), 1) end

# PROF=1 samples the stack of the script process every few ms and prints the hot functions
sampler =
  if System.get_env("PROF") do
    spawn(fn ->
      sample = fn sample, acc ->
        receive do
          {:stop, from} -> send(from, {:samples, acc})
        after
          3 ->
            acc =
              case Process.info(pid, :current_stacktrace) do
                {_, [_ | _] = st} ->
                  [{m, f, a, _} | _] = st
                  fs = st |> Enum.map(fn {m, f, a, _} -> {m, f, a} end) |> Enum.uniq()
                  Enum.reduce(fs, [{:self, {m, f, a}} | acc], fn k, acc -> [{:incl, k} | acc] end)

                _ ->
                  acc
              end

            sample.(sample, acc)
        end
      end

      sample.(sample, [])
    end)
  end

# GCTRACE=1 adds up the time the script process spends in garbage collection
gc_tracer =
  if System.get_env("GCTRACE") do
    tracer =
      spawn(fn ->
        tr = fn tr, start, minor, major, nmin, nmaj ->
          receive do
            {:trace_ts, _, :gc_minor_start, _, ts} -> tr.(tr, ts, minor, major, nmin, nmaj)
            {:trace_ts, _, :gc_major_start, _, ts} -> tr.(tr, ts, minor, major, nmin, nmaj)
            {:trace_ts, _, :gc_minor_end, _, ts} -> tr.(tr, nil, minor + diff.(ts, start), major, nmin + 1, nmaj)
            {:trace_ts, _, :gc_major_end, _, ts} -> tr.(tr, nil, minor, major + diff.(ts, start), nmin, nmaj + 1)
            {:stop, from} -> send(from, {:gc, minor, nmin, major, nmaj})
          end
        end

        tr.(tr, nil, 0, 0, 0, 0)
      end)

    :erlang.trace(pid, true, [:garbage_collection, :timestamp, {:tracer, tracer}])
    tracer
  end

# TPROF=1 counts every call in the JS modules and the time spent in each (slow, but exact)
js_modules = for m <- Application.spec(:browser, :modules), String.starts_with?(Atom.to_string(m), "Elixir.Browser.JS"), Code.ensure_loaded?(m), do: m

if System.get_env("TPROF") do
  sink = spawn(fn -> Stream.repeatedly(fn -> receive do _ -> :ok end end) |> Stream.run() end)
  for m <- js_modules, m in [Browser.JS.Interp], do: :erlang.trace_pattern({m, :_, :_}, true, [:call_time, :local])
  :erlang.trace(pid, true, [:call, {:tracer, sink}])
end

print.(Runtime.run_scripts(pid))

loop = fn loop ->
  left = timeout - (System.monotonic_time(:millisecond) - t0)

  receive do
    {:js_async, ^pid, reply} ->
      print.(reply)
      if Enum.any?(reply.console, fn {_, t} -> t == "DONE" or String.starts_with?(t, "ERROR") end), do: :done, else: loop.(loop)
  after
    max(left, 0) -> :timeout
  end
end

loop.(loop)
if sampler do
  send(sampler, {:stop, self()})

  receive do
    {:samples, acc} ->
      n = Enum.count(acc, &match?({:self, _}, &1))
      IO.puts("-- #{n} samples")
      for kind <- [:self, :incl] do
        IO.puts("-- #{kind}")

        acc
        |> Enum.filter(&match?({^kind, _}, &1))
        |> Enum.frequencies()
        |> Enum.sort_by(&elem(&1, 1), :desc)
        |> Enum.take(45)
        |> Enum.each(fn {{_, {m, f, a}}, c} -> IO.puts("#{String.pad_leading(Integer.to_string(c), 6)} #{inspect(m)}.#{f}/#{a}") end)
      end
  end
end

if gc_tracer do
  send(gc_tracer, {:stop, self()})

  receive do
    {:gc, minor, nmin, major, nmaj} ->
      IO.puts("gc: #{nmin} minor #{div(minor, 1000)} ms, #{nmaj} major #{div(major, 1000)} ms")
  end
end

if System.get_env("TPROF") do
  rows =
    for m <- js_modules, m in [Browser.JS.Interp], {f, a} <- m.module_info(:functions),
        {:call_time, ts} when is_list(ts) <- [:erlang.trace_info({m, f, a}, :call_time)],
        {:call_time, ts} = {:call_time, ts},
        ts != [] do
      {n, t} = Enum.reduce(ts, {0, 0}, fn {_, c, s, us}, {n, t} -> {n + c, t + s * 1_000_000 + us} end)
      {"#{inspect(m)}.#{f}/#{a}", n, t}
    end

  IO.puts("-- by time (us, calls)")
  rows |> Enum.sort_by(&elem(&1, 2), :desc) |> Enum.take(60) |> Enum.each(fn {k, n, t} -> IO.puts("#{String.pad_leading(Integer.to_string(t), 10)} #{String.pad_leading(Integer.to_string(n), 9)} #{k}") end)
  IO.puts("-- by calls")
  rows |> Enum.sort_by(&elem(&1, 1), :desc) |> Enum.take(40) |> Enum.each(fn {k, n, t} -> IO.puts("#{String.pad_leading(Integer.to_string(t), 10)} #{String.pad_leading(Integer.to_string(n), 9)} #{k}") end)
end

IO.puts("total #{System.monotonic_time(:millisecond) - t0} ms")
Runtime.stop(pid)
