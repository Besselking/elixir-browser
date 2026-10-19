# Usage: mix run --no-start bench/speedometer.exs URL [SUITES] [TIMEOUT_S]
# Runs Speedometer 3.1 headlessly. URL is the folder with a local mirror, for example
# http://localhost:8765/Speedometer3.1/ . Serve the mirror with bench/serve.py
# (`python3 bench/serve.py DIR 8765`), not with `python3 -m http.server`: the listen backlog of
# that server is 5, and a burst of connections then adds 1 s to a page change.
# SUITES is a comma separated list of suite names.
# The app bundle starts the VM with memory flags (see the README). To measure as the app runs,
# set the same flags: ERL_FLAGS="+MMscs 2048 +MMscrpm false +MHsbct 262144 +MHlmbcs 1048576".
# Prints console lines, the time until the run ends and a `MRED` line with the exact
# reductions of the whole VM and of the run phase.
alias Browser.{Fetch, Page}
alias Browser.JS.Runtime

# The reductions and the CPU time of the whole VM are counted from here, so that the
# `MRED` line at the end of the run can compare two builds on a noisy machine.
{red_start, _} = :erlang.statistics(:exact_reductions)
{cpu_start, _} = :erlang.statistics(:runtime)

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
# does, but with a fixed width per character), and adds up what those layouts cost. As in the
# session, the layouts go through a layout worker that keeps the memo of the last layout
# (`Browser.LayoutWorker`), and a prewarm lays out in the worker too. LAYOUT_DIRECT=1 gives the
# old mode, to compare with older numbers: each request lays out in its own process with no
# memo, and a prewarm only styles. (A tree with no layout worker always uses the old mode)
layout? = System.get_env("LAYOUT") != nil
info = if layout?, do: Map.put(info, :layout_now, true), else: info
{:ok, forced} = Agent.start_link(fn -> {0, 0} end)
{:ok, lsamples} = Agent.start_link(fn -> [] end)
# the page the layouts for the scripts start from; each layout hands on what it worked out about
# the sheets and the cascade, as the session does
# (the loop keeps the page with the style memo; each layout sends its style state back, as the session does)
Process.put(:bench_base, page)
bench_loop = self()

t0 = System.monotonic_time(:millisecond)
# (the run phase starts with the script process; the page load and the start of the
# application before it are in the whole-VM count only)
{red_run, _} = :erlang.statistics(:exact_reductions)
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

# TPROF2=1 traces every function of the script process (call time, own time) and prints the
# heaviest at the end; slow, so use a suite or two
tprof2 =
  if System.get_env("TPROF2") do
    Code.prepend_path(Path.join([to_string(:code.root_dir()), "lib", "tools-4.2.3", "ebin"]))
    {:ok, _} = :tprof.start(%{type: :call_time})
    :tprof.set_pattern(:_, :_, :_)
    :tprof.enable_trace(pid)
    true
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

# (a layout starts with the heap the session gives the process: `Browser.Session.spawn_layout/1`.
# An older tree has no such function, and `bench/ab.exs` runs this file in both trees, so such a
# tree starts its layouts as its own session does)
Code.ensure_loaded(Browser.Session)

# (the layout worker of the bench, nil in the old mode: see LAYOUT_DIRECT above)
bench_lw =
  if System.get_env("LAYOUT_DIRECT") == nil and Code.ensure_loaded?(Browser.LayoutWorker),
    do: Browser.LayoutWorker.start(&Browser.Screenshot.measure/2)

layout_opts = fn laid -> [scrollers: true, boxes: true, svg_defs: laid.svg_defs] end

spawn_layout =
  if function_exported?(Browser.Session, :spawn_layout, 1),
    do: &Browser.Session.spawn_layout/1,
    else: &spawn/1

# (the session stops a layout that the script no longer waits for, and lets one prewarm style
# at a time: `Browser.StyleGate`. In an older tree, each request starts at once and runs to its end)
watch_layout =
  if function_exported?(Browser.Session, :watch_layout, 1),
    do: &Browser.Session.watch_layout/1,
    else: fn _ -> :ok end

if Code.ensure_loaded?(Browser.StyleGate), do: Process.put(:bench_gate, Browser.StyleGate.new())

# (a forced layout also goes to the prewarm of the same script and sheets that styles now, its
# twin: `Browser.StyleGate`. An older tree has no twins)
twins? = function_exported?(Browser.Session, :won_style?, 2)

# (the style state leaves out the sheets that the loop has already: `Browser.Page.style_state/2`)
style_state =
  if function_exported?(Browser.Page, :style_state, 2),
    do: &Browser.Page.style_state/2,
    else: fn laid, _base -> Browser.Page.style_state(laid) end

# The style of a request in the process of the layout; `job` is from `start_layout`. Gives
# `{:layout, laid, job, t, base}` for a request that goes on to its layout (`t`: when its style
# started), `{:twin, base, twin}` for a prewarm that has a twin to style next, else `:ok`.
run_style = fn base, job ->
  %{ref: ref, raw: raw, refs: refs, seq: seq} = job
  t = System.monotonic_time(:microsecond)
  env = %{type: "screen", width: 1000, height: 800, dppx: 1.0, font_units: nil}

  laid =
    if refs,
      do: apply(Browser.Page, :from_raw, [base, raw, env, refs]),
      else: Browser.Page.from_raw(base, raw, env)

  # (of a request and its twin, the first to end its style goes on)
  won? =
    not twins? or
      apply(Browser.Session, :won_style?, [job.race, if(job.cold, do: :twin, else: :run)])

  if not won?, do: exit(:normal)
  send(bench_loop, {:bench_style, seq, style_state.(laid, base)})
  if job.cold, do: Process.exit(job.cold, :kill)

  # DUMPRAW=dir keeps the trees the scripts ask a layout for, for `bench/restyle.exs`
  if dir = System.get_env("DUMPRAW") do
    File.mkdir_p!(dir)
    n = length(File.ls!(dir))

    File.write!(
      Path.join(dir, "raw#{n}.term"),
      :erlang.term_to_binary({base, raw, laid.sheet_cache})
    )
  end

  # A prewarm (`ref` is nil) makes the style memo, and with the layout worker it also lays out
  # there, as in the session: no script reads its boxes, but the worker keeps the memo of that
  # layout. A twin that came while it styled starts from the style memo.
  twin = (ref == nil and twins?) && apply(Browser.Session, :take_twin, [])

  cond do
    twin && apply(Browser.Session, :twin_wanted?, [twin]) ->
      {base, refs} = apply(Browser.Session, :twin_base, [laid, twin])
      {:twin, base, %{twin | refs: refs}}

    ref == nil and bench_lw != nil ->
      {:prewarm_layout, laid}

    ref == nil ->
      :ok

    true ->
      {:layout, laid, job, t, if(System.get_env("DUMPSLOW"), do: base)}
  end
end

# (a prewarm styles the twin that came while it styled)
twin_style = fn
  {:twin, base, twin} -> run_style.(base, twin)
  step -> step
end

# A layout through the worker (when the worker is busy, in the caller with no memo, as in the
# session), or in the old mode in the caller
layout_of = fn laid ->
  if bench_lw,
    do:
      Browser.LayoutWorker.layout(
        bench_lw,
        :bench_tab,
        laid.nodes,
        1000,
        &Browser.Screenshot.measure/2,
        800,
        layout_opts.(laid)
      ),
    else:
      Browser.Layout.layout(
        laid.nodes,
        1000,
        &Browser.Screenshot.measure/2,
        800,
        layout_opts.(laid)
      )
end

# The layout of a request after its style. The watchdog stops a layout that the script no longer
# waits for. Gives `{:twin, base, twin}` for a prewarm that has a twin to style next (one that
# came while the prewarm laid out, as in the session), else something else.
lay_out = fn
  {:layout, laid, %{js: js, ref: ref, raw: raw, deadline: deadline} = job, t, base} ->
    watch_layout.(deadline)

    t1 = System.monotonic_time(:microsecond)

    {items, height} = layout_of.(laid)

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
          "layout #{div(t1 - t, 1000)} ms style, #{div(t2 - t1, 1000)} ms layout, #{length(items)} items#{if job.cold, do: " (twin)"}"
        )

    send(js, {:layout_now_done, ref, rects, {1000.0, height}})

  {:prewarm_layout, laid} ->
    t1 = System.monotonic_time(:microsecond)
    {items, _height} = layout_of.(laid)

    if System.get_env("LAYOUT") == "2",
      do:
        IO.puts(
          "prewarm layout #{div(System.monotonic_time(:microsecond) - t1, 1000)} ms, #{length(items)} items"
        )

    twin = twins? && apply(Browser.Session, :take_twin, [])

    if twin && apply(Browser.Session, :twin_wanted?, [twin]) do
      {base, refs} = apply(Browser.Session, :twin_base, [laid, twin])
      {:twin, base, %{twin | refs: refs}}
    end

  _ ->
    :ok
end

# starts the style and the layout of a request in a process of its own
start_layout = fn %{js: js, ref: ref, raw: raw, deadline: deadline, seq: seq} ->
  # (as the session does: the process gets no memo when the tree has other sheets,
  # `Browser.Page.layout_base/2`. An older tree copies the whole page)
  {base, refs} =
    if function_exported?(Browser.Page, :layout_base, 2),
      do: Browser.Page.layout_base(Process.get(:bench_base), raw),
      else: {Process.get(:bench_base), nil}

  job = %{
    js: js,
    ref: ref,
    raw: raw,
    refs: refs,
    deadline: deadline,
    seq: seq,
    race: if(twins? and ref != nil, do: :atomics.new(1, [])),
    cold: nil
  }

  pid =
    spawn_layout.(fn ->
      Process.flag(:trap_exit, false)
      me = self()
      guard = self()

      spawn(fn ->
        ref = Process.monitor(guard)

        receive do
          # (`:killed`: the watchdog stopped a layout that no script waits for)
          {:DOWN, ^ref, _, _, reason} when reason not in [:normal, :killed] ->
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

      # (This file is not compiled: a function keeps all its values while it calls another one.
      # Each step goes as an argument into the next, so that the layout does not keep what the
      # style worked with, as in the session)
      # (a prewarm that lays out can give a twin to style and lay out next)
      lay_out.(twin_style.(lay_out.(twin_style.(run_style.(base, job)))))
    end)

  # (the gate opens also when the process stops before it sends its style state)
  if gate = Process.get(:bench_gate) do
    mon = :erlang.monitor(:process, pid, tag: :bench_gate_down)

    if twins? do
      twin = if ref != nil, do: Browser.StyleGate.twin(gate, {js, refs})
      light = if twin, do: apply(Browser.Page, :without_style, [base])
      if twin, do: send(twin, {:style_twin, Map.merge(job, %{cold: pid, base: light})})
      key = if ref == nil, do: {{js, refs}, pid}
      Process.put(:bench_gate, apply(Browser.StyleGate, :running, [gate, seq, mon, key]))
    else
      Process.put(:bench_gate, Browser.StyleGate.running(gate, seq, mon))
    end
  end
end

loop = fn loop ->
  left = timeout - (System.monotonic_time(:millisecond) - t0)

  receive do
    {:layout_now, js, ref, raw} ->
      # (the script waits 5 s for the answer, see `Browser.JS.DOM.layout_now/0`)
      deadline = System.monotonic_time(:millisecond) + 5_000
      req = %{js: js, ref: ref, raw: raw, deadline: deadline}

      case Process.get(:bench_gate) do
        nil ->
          start_layout.(Map.put(req, :seq, 0))

        gate ->
          {start, gate} = Browser.StyleGate.request(gate, req)
          Process.put(:bench_gate, gate)
          Enum.each(start, start_layout)
      end

      loop.(loop)

    {:bench_style, seq, st} ->
      {adopt?, next} =
        case Process.get(:bench_gate) do
          nil ->
            {true, []}

          gate ->
            {adopt?, mon, next, gate} = Browser.StyleGate.style_done(gate, seq)
            if mon, do: Process.demonitor(mon, [:flush])
            Process.put(:bench_gate, gate)
            {adopt?, next}
        end

      if adopt?,
        do: Process.put(:bench_base, Browser.Page.adopt_style_state(Process.get(:bench_base), st))

      Enum.each(next, start_layout)
      loop.(loop)

    {:bench_gate_down, mon, :process, _, _} ->
      {next, gate} = Browser.StyleGate.down(Process.get(:bench_gate), mon)
      Process.put(:bench_gate, gate)
      Enum.each(next, start_layout)
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

# One line with the exact reductions in millions (the whole VM and the run phase), the wall
# time of the run phase and the CPU time of the whole VM in ms. The reductions do not depend
# on the speed of the machine, so an A/B comparison (`bench/ab.exs`) reads this line.
{red_end, _} = :erlang.statistics(:exact_reductions)
{cpu_end, _} = :erlang.statistics(:runtime)

IO.puts(
  "MRED whole #{:erlang.float_to_binary((red_end - red_start) / 1.0e6, decimals: 3)}" <>
    " run #{:erlang.float_to_binary((red_end - red_run) / 1.0e6, decimals: 3)}" <>
    " ms #{System.monotonic_time(:millisecond) - t0} cpu #{cpu_end - cpu_start}"
)

# the score the page shows (1000 / the geometric mean of the suites' times in ms)
if result == :done do
  Process.sleep(1500)
  reply = Runtime.eval(pid, "(document.getElementById('result-number') || {}).textContent")
  IO.puts("score: #{inspect(reply.console |> List.last() |> elem(1))}")
end

if tprof2 do
  :tprof.disable_trace(pid)
  samples = :tprof.collect()

  {_, {:call_time, total, traces}} =
    :tprof.inspect(samples, :process, :measurement)
    |> Enum.to_list()
    |> Enum.max_by(fn {_, {:call_time, total, _}} -> total end)

  IO.puts("-- own time (us, calls), total #{total} us")

  IO.puts("-- by module")

  traces
  |> Enum.group_by(fn {m, _, _, _, _, _} -> m end, fn {_, _, _, us, _, _} -> us end)
  |> Enum.map(fn {m, l} -> {m, Enum.sum(l)} end)
  |> Enum.sort_by(&(-elem(&1, 1)))
  |> Enum.take(14)
  |> Enum.each(fn {m, us} ->
    IO.puts("#{String.pad_leading(Integer.to_string(us), 9)} #{inspect(m)}")
  end)

  IO.puts("-- by function")

  traces
  |> Enum.sort_by(fn {_, _, _, us, _, _} -> -us end)
  |> Enum.take(45)
  |> Enum.each(fn {m, {f, a}, calls, us, _, _} ->
    IO.puts(
      "#{String.pad_leading(Integer.to_string(us), 9)} #{String.pad_leading(Integer.to_string(calls), 9)} #{inspect(m)}.#{f}/#{a}"
    )
  end)
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

# PDSTAT=1 prints the process dictionary of the script process. A heap object is a key
# that is an integer of 0 or more. A negative integer key is the cell of an inline cache
# (step A2, the moduledoc of `Browser.JS.Shape`), so it has a line of its own: the number
# of cells, their words (the value plus 3 words for each entry), and the number of sites
# that the compiler gave.
if System.get_env("PDSTAT") do
  {:dictionary, pd} = Process.info(pid, :dictionary)
  ints = Enum.filter(pd, fn {k, _} -> is_integer(k) and k >= 0 end)
  cells = Enum.filter(pd, fn {k, _} -> is_integer(k) and k < 0 end)
  IO.puts("pd entries #{length(pd)}, heap objects #{length(ints)}")
  words = Enum.reduce(pd, 0, fn {_, v}, acc -> acc + :erts_debug.flat_size(v) end)
  IO.puts("pd flat words #{words} (#{div(words * 8, 1_000_000)} MB)")
  cell_words = Enum.reduce(cells, 0, fn {_, v}, acc -> acc + :erts_debug.flat_size(v) + 3 end)

  sites =
    case Enum.find_value(pd, fn {k, v} -> k == :js_ic_next && v end) do
      nil -> 0
      next -> -next - 1
    end

  IO.puts("ic cells #{length(cells)}, words #{cell_words}, sites #{sites}")

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

# JSC=1 prints the code cache of the closure compiler (step 5) in the script process: the
# number of entries, the count of nodes against the budget, the number of times the
# budget erased the cache, and the size of the code in words now (after an erase, this is
# less than the count). The count of the budget includes one node for each site of an
# inline cache (step A2), and the cells belong to the cache, so the line also gives the
# number of cells and their words (the value plus 3 words for each entry). The copy of the
# process dictionary is large, so the option is off by default.
if System.get_env("JSC") do
  case Process.info(pid, :dictionary) do
    {:dictionary, dict} ->
      codes = for {{:jsc, _}, code} <- dict, do: code
      cells = for {k, cell} <- dict, is_integer(k) and k < 0, do: cell
      cell_words = Enum.reduce(cells, 0, &(:erts_debug.flat_size(&1) + 3 + &2))

      {counted, erases} =
        Enum.find_value(dict, {0, 0}, fn {k, v} -> k == :jsc_budget && v end)

      IO.puts(
        "JSC entries #{length(codes)} counted #{counted} erases #{erases} words #{:erts_debug.size(codes)} cells #{length(cells)} cell words #{cell_words}"
      )

    _ ->
      IO.puts("JSC the script process is gone")
  end
end

Runtime.stop(pid)
