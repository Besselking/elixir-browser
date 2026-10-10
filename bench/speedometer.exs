# Usage: mix run --no-start bench/speedometer.exs URL [SUITES] [TIMEOUT_S]
# Runs Speedometer 3.1 headlessly. URL is the folder with a local mirror, for example
# http://localhost:8765/Speedometer3.1/ . SUITES is a comma separated list of suite names.
# Prints console lines and the time until the run ends.
alias Browser.{Fetch, Page}
alias Browser.JS.Runtime

[url | rest] = System.argv()
suites = if Enum.at(rest, 0) in [nil, "", "all"], do: nil, else: Enum.at(rest, 0)
timeout = String.to_integer(Enum.at(rest, 1) || "300") * 1000
Application.put_env(:browser, :gui, false)

# RESOLVE=1..4|info|off sets the level of the resolver pass (`Browser.JS.Resolve`)
case System.get_env("RESOLVE") do
  nil -> :ok
  "off" -> Application.put_env(:browser, :js_resolve, :off)
  "info" -> Application.put_env(:browser, :js_resolve, :info)
  n -> Application.put_env(:browser, :js_resolve, String.to_integer(n))
end

{:ok, _} = Application.ensure_all_started(:browser)

full =
  url <>
    "index.html?startAutomatically&iterationCount=1" <>
    if(suites, do: "&suites=" <> suites, else: "")

{:ok, page} = Page.load(full)

info = %{
  url: page.url,
  base: page.base || page.url,
  width: 1000,
  height: 800,
  fetch: &Fetch.load/1
}

# LAYOUT=1 answers the scripts' questions about sizes with a real layout (the way the session
# does, but with a fixed width per character), and adds up what those layouts cost
layout? = System.get_env("LAYOUT") != nil
info = if layout?, do: Map.put(info, :layout_now, true), else: info
{:ok, forced} = Agent.start_link(fn -> {0, 0} end)
{:ok, lsamples} = Agent.start_link(fn -> [] end)
# the page the layouts for the scripts start from; each layout hands on what it worked out about
# the sheets and the cascade, as the session does
{:ok, base_agent} = Agent.start_link(fn -> page end)

t0 = System.monotonic_time(:millisecond)
pid = Runtime.start(page.raw, info)

print = fn reply ->
  for {level, text} <- Map.get(reply, :console, []) do
    IO.puts(
      "[#{div(System.monotonic_time(:millisecond) - t0, 1000)}s #{level}] #{String.slice(text, 0, 300)}"
    )
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
                  [{m, f, a, loc} | _] = st

                  {m, f, a} =
                    if System.get_env("PROFLINE"), do: {m, f, {a, loc[:line]}}, else: {m, f, a}

                  fs = st |> Enum.map(fn {m, f, a, _} -> {m, f, a} end) |> Enum.uniq()

                  acc =
                    Enum.reduce(fs, [{:self, {m, f, a}} | acc], fn k, acc ->
                      [{:incl, k} | acc]
                    end)

                  # PROFCALLER=name also counts who called a function with that name (the first
                  # frame above its last call)
                  case System.get_env("PROFCALLER") do
                    nil ->
                      acc

                    name ->
                      rest =
                        fs
                        |> Enum.drop_while(fn {_, f, _} -> Atom.to_string(f) != name end)
                        |> Enum.drop_while(fn {_, f, _} -> Atom.to_string(f) == name end)

                      case rest do
                        [k | _] -> [{:caller, k} | acc]
                        _ -> acc
                      end
                  end

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
t0_us = :os.timestamp()

gc_tracer =
  if System.get_env("GCTRACE") do
    tracer =
      spawn(fn ->
        tr = fn tr, start, minor, major, nmin, nmaj ->
          receive do
            {:trace_ts, _, :gc_minor_start, _, ts} ->
              tr.(tr, ts, minor, major, nmin, nmaj)

            {:trace_ts, _, :gc_major_start, info, ts} ->
              Process.put(:last_info, info)
              tr.(tr, ts, minor, major, nmin, nmaj)

            {:trace_ts, _, :gc_minor_end, info, ts} ->
              if System.get_env("GCDETAIL") && diff.(ts, start) > 30_000,
                do:
                  IO.puts(
                    "minor #{div(diff.(ts, start), 1000)} ms at #{div(diff.(ts, t0_us), 1000)} #{inspect(Keyword.take(info, [:heap_size, :old_heap_size, :recent_size, :mbuf_size, :bin_vheap_size]))}"
                  )

              tr.(tr, nil, minor + diff.(ts, start), major, nmin + 1, nmaj)

            {:trace_ts, _, :gc_major_end, info, ts} ->
              d = diff.(ts, start)

              if d > 100_000,
                do:
                  IO.puts(
                    "MAJOR #{div(d, 1000)} ms at #{div(diff.(ts, t0_us), 1000)}: before #{inspect(Process.get(:last_info) |> Keyword.take([:heap_size, :old_heap_size, :bin_vheap_size]))} after #{inspect(Keyword.take(info, [:heap_size, :old_heap_size]))}"
                  )

              tr.(tr, nil, minor, major + d, nmin, nmaj + 1)

            {:stop, from} ->
              send(from, {:gc, minor, nmin, major, nmaj})
          end
        end

        tr.(tr, nil, 0, 0, 0, 0)
      end)

    :erlang.trace(pid, true, [:garbage_collection, :timestamp, {:tracer, tracer}])
    tracer
  end

# TPROF=1 counts every call in the JS modules and the time spent in each (slow, but exact)
js_modules =
  for m <- Application.spec(:browser, :modules),
      String.starts_with?(Atom.to_string(m), "Elixir.Browser.JS"),
      Code.ensure_loaded?(m),
      do: m

if System.get_env("TPROF") do
  sink =
    spawn(fn ->
      Stream.repeatedly(fn ->
        receive do
          _ -> :ok
        end
      end)
      |> Stream.run()
    end)

  for m <- js_modules,
      m in [Browser.JS.Interp],
      do: :erlang.trace_pattern({m, :_, :_}, true, [:call_time, :local])

  :erlang.trace(pid, true, [:call, {:tracer, sink}])
end

# MEM=1 prints the size of the script process every 5 s
if System.get_env("MEM") do
  spawn(fn ->
    mem = fn mem ->
      Process.sleep(5000)

      case Process.info(pid, [:memory, :total_heap_size]) do
        [memory: m, total_heap_size: h] ->
          IO.puts(
            "[#{div(System.monotonic_time(:millisecond) - t0, 1000)}s mem] #{div(m, 1_000_000)} MB, heap #{div(h * 8, 1_000_000)} MB"
          )

          mem.(mem)

        _ ->
          :ok
      end
    end

    mem.(mem)
  end)
end

# (the session runs the scripts in a process of its own, so that it can answer their questions
# about sizes meanwhile)
me = self()
spawn(fn -> send(me, {:scripts_done, Runtime.run_scripts(pid)}) end)

loop = fn loop ->
  left = timeout - (System.monotonic_time(:millisecond) - t0)

  receive do
    {:layout_now, js, ref, raw} ->
      base = Agent.get(base_agent, & &1)

      spawn(fn ->
        Process.flag(:trap_exit, false)
        me = self()
        guard = self()

        spawn(fn ->
          ref = Process.monitor(guard)

          receive do
            {:DOWN, ^ref, _, _, reason} when reason not in [:normal] ->
              IO.puts("LAYOUT CRASHED: #{inspect(reason, limit: 30, printable_limit: 300)}")
          end
        end)

        # LAYOUT=3 also samples the stack of the process that makes the layout
        if System.get_env("LAYOUT") == "3" do
          spawn(fn ->
            sample = fn sample ->
              case Process.info(me, :current_stacktrace) do
                {_, [{m, f, a, _} | _] = st} ->
                  Agent.update(lsamples, fn acc ->
                    fs = st |> Enum.map(fn {m, f, a, _} -> {m, f, a} end) |> Enum.uniq()

                    above =
                      fs
                      |> Enum.drop_while(fn {m, _, _} -> m != Regex end)
                      |> Enum.drop_while(fn {m, _, _} -> m == Regex end)

                    callers =
                      if m == Regex, do: Enum.map(Enum.take(above, 2), &{:caller, &1}), else: []

                    [{:self, {m, f, a}} | Enum.map(fs, &{:incl, &1}) ++ callers ++ acc]
                  end)

                  Process.sleep(1)
                  sample.(sample)

                _ ->
                  :ok
              end
            end

            sample.(sample)
          end)
        end

        t = System.monotonic_time(:microsecond)
        env = %{type: "screen", width: 1000, height: 800, dppx: 1.0, font_units: nil}
        laid = Browser.Page.from_raw(base, raw, env)

        Agent.update(
          base_agent,
          &Browser.Page.adopt_style_state(&1, Browser.Page.style_state(laid))
        )

        # DUMPRAW=dir keeps the trees the scripts ask a layout for, for `bench/restyle.exs`
        if dir = System.get_env("DUMPRAW") do
          File.mkdir_p!(dir)
          n = length(File.ls!(dir))

          File.write!(
            Path.join(dir, "raw#{n}.term"),
            :erlang.term_to_binary({base, raw, laid.sheet_cache})
          )
        end

        t1 = System.monotonic_time(:microsecond)

        {items, height} =
          Browser.Layout.layout(laid.nodes, 1000, &Browser.Screenshot.measure/2, 800,
            scrollers: true,
            boxes: true,
            svg_defs: laid.svg_defs
          )

        t2 = System.monotonic_time(:microsecond)

        # DUMPSLOW=dir,ms keeps the trees whose layout took longer than that
        with spec when is_binary(spec) <- System.get_env("DUMPSLOW"),
             [dir, ms] <- String.split(spec, ","),
             true <- (t2 - t) / 1000 > String.to_integer(ms) do
          File.mkdir_p!(dir)

          File.write!(
            Path.join(dir, "slow#{length(File.ls!(dir))}.term"),
            :erlang.term_to_binary({base, raw, laid.sheet_cache})
          )
        end

        rects = Browser.Nids.rects(items, Browser.Nids.parents(laid.pruned || []))
        Agent.update(forced, fn {n, us} -> {n + 1, us + (t2 - t)} end)

        if System.get_env("LAYOUT") == "2",
          do:
            IO.puts(
              "layout #{div(t1 - t, 1000)} ms style, #{div(t2 - t1, 1000)} ms layout, #{length(items)} items"
            )

        send(js, {:layout_now_done, ref, rects, {1000.0, height}})
      end)

      loop.(loop)

    {:scripts_done, reply} ->
      print.(reply)

      if Enum.any?(reply.console, fn {_, t} -> t == "DONE" or String.starts_with?(t, "ERROR") end),
         do: :done,
         else: loop.(loop)

    {:js_async, ^pid, reply} ->
      print.(reply)

      if Enum.any?(reply.console, fn {_, t} -> t == "DONE" or String.starts_with?(t, "ERROR") end),
         do: :done,
         else: loop.(loop)
  after
    max(left, 0) -> :timeout
  end
end

result = loop.(loop)

# the score the page shows (1000 / the geometric mean of the suites' times in ms)
if result == :done do
  Process.sleep(1500)
  reply = Runtime.eval(pid, "(document.getElementById('result-number') || {}).textContent")
  IO.puts("score: #{inspect(reply.console |> List.last() |> elem(1))}")
end

if sampler do
  send(sampler, {:stop, self()})

  receive do
    {:samples, acc} ->
      n = Enum.count(acc, &match?({:self, _}, &1))
      IO.puts("-- #{n} samples")

      for kind <- [:self, :incl, :caller] do
        IO.puts("-- #{kind}")

        acc
        |> Enum.filter(&match?({^kind, _}, &1))
        |> Enum.frequencies()
        |> Enum.sort_by(&elem(&1, 1), :desc)
        |> Enum.take(45)
        |> Enum.each(fn {{_, {m, f, a}}, c} ->
          IO.puts(
            "#{String.pad_leading(Integer.to_string(c), 6)} #{inspect(m)}.#{f}/#{inspect(a)}"
          )
        end)
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
    for m <- js_modules,
        m in [Browser.JS.Interp],
        {f, a} <- m.module_info(:functions),
        {:call_time, ts} when is_list(ts) <- [:erlang.trace_info({m, f, a}, :call_time)],
        {:call_time, ts} = {:call_time, ts},
        ts != [] do
      {n, t} =
        Enum.reduce(ts, {0, 0}, fn {_, c, s, us}, {n, t} -> {n + c, t + s * 1_000_000 + us} end)

      {"#{inspect(m)}.#{f}/#{a}", n, t}
    end

  IO.puts("-- by time (us, calls)")

  rows
  |> Enum.sort_by(&elem(&1, 2), :desc)
  |> Enum.take(60)
  |> Enum.each(fn {k, n, t} ->
    IO.puts(
      "#{String.pad_leading(Integer.to_string(t), 10)} #{String.pad_leading(Integer.to_string(n), 9)} #{k}"
    )
  end)

  IO.puts("-- by calls")

  rows
  |> Enum.sort_by(&elem(&1, 1), :desc)
  |> Enum.take(40)
  |> Enum.each(fn {k, n, t} ->
    IO.puts(
      "#{String.pad_leading(Integer.to_string(t), 10)} #{String.pad_leading(Integer.to_string(n), 9)} #{k}"
    )
  end)
end

if System.get_env("PDSTAT") do
  {:dictionary, pd} = Process.info(pid, :dictionary)
  ints = Enum.filter(pd, fn {k, _} -> is_integer(k) end)
  IO.puts("pd entries #{length(pd)}, integer keys #{length(ints)}")
  words = Enum.reduce(pd, 0, fn {_, v}, acc -> acc + :erts_debug.flat_size(v) end)
  IO.puts("pd flat words #{words} (#{div(words * 8, 1_000_000)} MB)")

  pd
  |> Enum.map(fn {k, v} -> {k, :erts_debug.flat_size(v)} end)
  |> Enum.reject(fn {k, _} -> is_integer(k) end)
  |> Enum.sort_by(&elem(&1, 1), :desc)
  |> Enum.take(15)
  |> Enum.each(fn {k, w} ->
    IO.puts("  #{w} words  #{inspect(k, limit: 5, printable_limit: 40)}")
  end)

  kinds =
    ints
    |> Enum.map(fn {_, v} ->
      {if(is_map(v),
         do: Map.get(v, :class, if(Map.has_key?(v, :scope), do: :scope, else: :map)),
         else: :other
       ), :erts_debug.flat_size(v)}
    end)
    |> Enum.reduce(%{}, fn {k, w}, acc ->
      Map.update(acc, k, {1, w}, fn {n, t} -> {n + 1, t + w} end)
    end)

  IO.inspect(kinds, label: "heap objects by kind {count, words}")
end

if System.get_env("LAYOUT") == "3" do
  acc = Agent.get(lsamples, & &1)

  for kind <- [:self, :incl, :caller] do
    IO.puts("-- layout process, #{kind}")

    acc
    |> Enum.filter(&match?({^kind, _}, &1))
    |> Enum.frequencies()
    |> Enum.sort_by(&elem(&1, 1), :desc)
    |> Enum.take(40)
    |> Enum.each(fn {{_, {m, f, a}}, c} ->
      IO.puts("#{String.pad_leading(Integer.to_string(c), 6)} #{inspect(m)}.#{f}/#{inspect(a)}")
    end)
  end
end

if layout? do
  {n, us} = Agent.get(forced, & &1)
  IO.puts("forced layouts: #{n}, #{div(us, 1000)} ms")
end

IO.puts("total #{System.monotonic_time(:millisecond) - t0} ms")
Runtime.stop(pid)
