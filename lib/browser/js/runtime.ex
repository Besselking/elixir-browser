defmodule Browser.JS.Runtime do
  @moduledoc """
  A page's JavaScript: one process that owns the document (`Browser.JS.DOM`) and the script
  heap for as long as the page is shown.

  `start/2` boots it from the page's parsed HTML; `run_scripts/1` then runs the page's
  `<script>` elements (classic scripts in order, import maps, modules after them, with
  `import` resolved through the import map and fetched like any other resource) and fires
  `DOMContentLoaded` and `load`. After that the session calls `dispatch/5` for events caused by
  the user, e.g. a form's `submit`.

  Every call returns a map: `:dirty` (the tree changed; `:raw` then holds it), `:url` (the
  address as the script sees it), `:outbox` (see `Browser.JS.DOM`), `:prevented` (for an
  event) and `:console`.
  """

  alias Browser.JS.{Builtins, DOM, Interp, Parser}

  @steps 5_000_000
  @call_timeout 15_000
  @slice_ms 30

  # ── API ────────────────────────────────────────────────────

  @doc """
  Boots a runtime for the page. `info` has `:url`, `:width`, `:height` and `:fetch`.

  Timers run in real time. What a timer's callback changes (and a promise that settles later)
  is sent to the process that started the runtime, as `{:js_async, pid, reply}` with a reply
  like the ones the calls return.
  """
  def start(raw, info) do
    owner = self()

    # the heap lives in the process dictionary and only grows, so avoid repeated full sweeps
    :erlang.spawn_opt(
      fn ->
        boot(raw, Map.put(info, :owner, owner))
        loop(System.monotonic_time(:millisecond))
      end,
      min_heap_size: 2_000_000,
      fullsweep_after: 1_000_000
    )
  end

  @doc """
  Tells the page where its elements are (`Browser.Nids.rects/2`), where the window is scrolled to
  and how big the page is, for `getBoundingClientRect` and the like.
  """
  def layout(pid, rects, scroll_x, scroll_y, content),
    do: send(pid, {:layout, rects, scroll_x, scroll_y, content})

  @doc "The window was scrolled: scripts see the new position and get a `scroll` event."
  def scrolled(pid, x, y), do: send(pid, {:scrolled, x, y})

  def stop(pid), do: Process.exit(pid, :kill)

  def run_scripts(pid), do: call(pid, :run_scripts)

  @doc """
  Fires `type` at `target`: `{:control, cid}`, `{:form, fid}`, `:document` or `:window`.
  `controls` holds the live values of the page's controls (`%{cid => %{value:, checked:,
  selected:}}`), which the script reads through `.value` and friends.
  """
  def dispatch(pid, target, type, init \\ %{}, controls \\ %{}),
    do: call(pid, {:dispatch, target, type, init, controls})

  @doc "Runs every pending timer at once (virtual time), for tests; returns the reply."
  def flush(pid), do: call(pid, :flush)

  @doc "The page as it stands (after changes the session made to control state)."
  def snapshot(pid, controls \\ %{}), do: call(pid, {:snapshot, controls})

  defp call(pid, request) do
    ref = Process.monitor(pid)
    send(pid, {:call, self(), ref, request})

    receive do
      {^ref, reply} ->
        Process.demonitor(ref, [:flush])
        reply

      {:DOWN, ^ref, _, _, reason} ->
        %{dirty: false, raw: nil, outbox: [], console: [], prevented: false, crashed: reason}
    after
      @call_timeout ->
        Process.demonitor(ref, [:flush])

        %{
          dirty: false,
          raw: nil,
          outbox: [],
          console: [{:error, "script timed out"}],
          prevented: false
        }
    end
  end

  # ── the process ────────────────────────────────────────────

  defp boot(raw, info) do
    Interp.init(@steps)
    Browser.JS.GC.enable()
    scope = Builtins.install()
    DOM.init(raw, info)
    DOM.install(scope)
    Process.put(:rt_info, info)
    Browser.JS.WebAPI.install(scope, &http/1)
    Process.put(:rt_modules, %{})

    Process.put(:js_import, fn spec, from ->
      load_module(resolve_specifier(spec, from || base_url()))
    end)

    Process.put(:rt_importmap, %{})
  end

  # `t0` is when the runtime started: timers are timed from it
  defp loop(t0) do
    wait =
      case Builtins.next_timer_at() do
        nil -> :infinity
        at -> max(trunc(at - elapsed(t0)), 0)
      end

    receive do
      {:call, from, ref, request} ->
        Process.put(:js_now, elapsed(t0))
        Process.put(:js_steps, @steps)
        reply = handle(request)
        send(from, {ref, reply})
        loop(t0)

      {:layout, rects, sx, sy, content} ->
        DOM.set_layout(rects, sx, sy, content)
        loop(t0)

      {:storage, _origin, key, old, new} ->
        Process.put(:js_now, elapsed(t0))
        Process.put(:js_steps, @steps)
        guard(fn -> DOM.storage_changed(key, old, new) end, :ok)
        Browser.JS.Promise.run_microtasks()
        reply = finish(%{})

        if async?(reply), do: send(Process.get(:rt_info).owner, {:js_async, self(), reply})
        loop(t0)

      {:scrolled, x, y} ->
        # only the newest position matters when several have piled up
        {x, y} = latest_scroll(x, y)
        Process.put(:js_now, elapsed(t0))
        Process.put(:js_steps, @steps)
        DOM.set_scroll(x, y)

        guard(
          fn -> DOM.dispatch(:window, "scroll", %{bubbles: false, cancelable: false}) end,
          :ok
        )

        Browser.JS.Promise.run_microtasks()
        reply = finish(%{})

        if async?(reply), do: send(Process.get(:rt_info).owner, {:js_async, self(), reply})
        loop(t0)
    after
      wait ->
        fire_due(t0)
        loop(t0)
    end
  end

  defp latest_scroll(x, y) do
    receive do
      {:scrolled, x2, y2} -> latest_scroll(x2, y2)
    after
      0 -> {x, y}
    end
  end

  defp elapsed(t0), do: (System.monotonic_time(:millisecond) - t0) * 1.0

  # the timers that have come due run, then whatever they changed goes to the session
  defp fire_due(t0) do
    now = elapsed(t0)
    Process.put(:js_now, now)
    Process.put(:js_steps, @steps)

    # a slice is bounded, so that events (clicks) are served between the slices of a task
    # that keeps rescheduling itself, as a browser's event loop does
    guard(fn -> while_due(now, System.monotonic_time(:millisecond) + @slice_ms) end, :ok)

    Process.put(:js_now, elapsed(t0))
    reply = finish(%{})

    if async?(reply), do: send(Process.get(:rt_info).owner, {:js_async, self(), reply})
  end

  # something the session should hear about
  defp async?(reply), do: reply.dirty or reply.outbox != [] or reply.console != []

  defp while_due(now, deadline) do
    on_error = fn v -> log(:error, "Uncaught " <> describe(v)) end

    if System.monotonic_time(:millisecond) < deadline and Builtins.run_next_timer(on_error, now),
      do: while_due(now, deadline)
  end

  defp handle(:flush) do
    run_timers()
    finish(%{})
  end

  defp handle(:run_scripts) do
    run_all_scripts()
    finish(%{})
  end

  defp handle({:dispatch, target, type, init, controls}) do
    DOM.apply_controls(controls)

    prevented =
      case resolve_target(target) do
        nil -> :ok
        t -> guard(fn -> DOM.dispatch(t, type, init) end, :ok)
      end

    Browser.JS.Promise.run_microtasks()
    finish(%{prevented: prevented == :prevented})
  end

  defp handle({:snapshot, controls}) do
    DOM.apply_controls(controls)
    finish(%{force_raw: true})
  end

  defp resolve_target({:control, cid}), do: DOM.control_node(cid)
  defp resolve_target({:form, fid}), do: DOM.form_node(fid)
  defp resolve_target(:document), do: DOM.document()
  defp resolve_target(:window), do: :window

  defp finish(extra) do
    dirty = DOM.dirty?() or Map.get(extra, :force_raw, false)
    raw = if dirty, do: DOM.to_raw()
    if raw, do: DOM.sync_cids(raw)
    DOM.clean()

    Map.merge(
      %{
        dirty: dirty,
        raw: raw,
        url: DOM.url(),
        outbox: DOM.take_outbox(),
        prevented: false,
        console: take_console()
      },
      Map.delete(extra, :force_raw)
    )
  end

  defp take_console do
    c = Enum.reverse(Process.get(:js_console, []))
    Process.put(:js_console, [])
    c
  end

  defp log(level, text),
    do: Process.put(:js_console, [{level, text} | Process.get(:js_console, [])])

  # runs `fun`, turning a script's uncaught error into a console line
  defp guard(fun, default) do
    fun.()
  rescue
    # a bug in a built-in must not take the page's scripts down with it
    e ->
      log(:error, "internal error: " <> Exception.message(e) <> where())
      default
  catch
    {:js_error, v} ->
      log(:error, "Uncaught " <> describe(v) <> where())
      default

    :js_limit ->
      log(:error, "script ran too long" <> where())
      default

    {:syntax, msg} ->
      log(:error, "SyntaxError: " <> msg <> where())
      default
  end

  # which script was running, for the console
  defp where do
    case Process.get(:rt_script) do
      nil -> ""
      label -> " (in #{label})"
    end
  end

  defp describe(v) when is_binary(v), do: v

  defp describe({:obj, _} = v) do
    case Interp.get(v, "message") do
      m when is_binary(m) ->
        case Interp.get(v, "name") do
          n when is_binary(n) -> n <> ": " <> m
          _ -> m
        end

      _ ->
        Builtins.inspect_js(v, 0, [])
    end
  end

  defp describe(v), do: Builtins.inspect_js(v, 0, [])

  defp run_timers do
    guard(
      fn -> Builtins.run_timers(fn v -> log(:error, "Uncaught " <> describe(v)) end) end,
      :ok
    )
  end

  # ── scripts ────────────────────────────────────────────────

  defp run_all_scripts do
    doc = DOM.document()
    scripts = for nid <- DOM.descendants(doc), s = script_info(nid), do: s

    for s <- scripts, s.kind == :importmap, do: add_importmap(s)

    for s <- scripts, s.kind == :classic do
      Process.put(:rt_script, label(s))
      DOM.set_current_script(s.nid)
      with {:ok, src, base} <- script_source(s), do: guard(fn -> run_classic(src, base) end, :ok)
      DOM.set_current_script(nil)
    end

    for s <- scripts, s.kind == :module do
      Process.put(:rt_script, label(s))

      with {:ok, src, base} <- script_source(s) do
        guard(fn -> run_module_source(src, base) end, :ok)
      end
    end

    Process.delete(:rt_script)
    guard(fn -> DOM.dispatch(doc, "DOMContentLoaded", %{cancelable: false}) end, :ok)
    guard(fn -> DOM.dispatch(:window, "load", %{bubbles: false, cancelable: false}) end, :ok)
    Browser.JS.Promise.run_microtasks()
  end

  defp script_info(nid) do
    n = DOM.node_data(nid)

    if n.kind == :element and n.tag == "script" do
      type = (DOM.get_attr(n, "type") || "") |> String.downcase() |> String.trim()
      text = Enum.map_join(n.kids, fn k -> DOM.node_data(k).text end)

      kind =
        cond do
          type == "importmap" -> :importmap
          type == "module" -> :module
          type in ["", "text/javascript", "application/javascript", "text/ecmascript"] -> :classic
          true -> :other
        end

      %{kind: kind, src: DOM.get_attr(n, "src"), text: text, nid: nid}
    end
  end

  defp label(%{src: src}) when is_binary(src) and src != "", do: src

  defp label(%{text: text}),
    do: "inline script: " <> (text |> String.trim() |> String.slice(0, 50))

  defp script_source(%{src: src}) when is_binary(src) and src != "" do
    url = Browser.Fetch.resolve(base_url(), src)

    case fetch(url) do
      {:ok, body, final} ->
        {:ok, body, final}

      {:error, msg} ->
        log(:error, "Failed to load #{url}: #{msg}")
        :error
    end
  end

  defp script_source(%{text: text}), do: {:ok, text, page_url()}

  defp base_url, do: Process.get(:rt_info)[:base] || page_url()
  defp page_url, do: Process.get(:rt_info).url

  # A request from a script (`fetch`, `XMLHttpRequest`): `req` has `:method`, `:url`, `:body`,
  # `:headers` (`[{name, value}]`), `:content_type` and `:credentials`. The answer is
  # `{:ok, response}` (see `Browser.Fetch.load/2`, `full: true`) or `{:error, message}`.
  # A page's `info.request` (`fn url, opts -> ...`) makes the real request; without one
  # (in tests) the page's `fetch` function answers every request with status 200.
  @doc false
  def http(%{url: url} = req) do
    scheme = URI.parse(url).scheme
    request = Process.get(:rt_info)[:request]

    cond do
      scheme in ["http", "https"] and request != nil ->
        opts = [
          method: req.method,
          body: req.body,
          headers: req.headers,
          content_type: req.content_type,
          credentials: req.credentials,
          full: true
        ]

        case request.(url, opts) do
          {:ok, response, _final} -> {:ok, response}
          {:error, msg} -> {:error, to_string(msg)}
        end

      true ->
        case fetch(url) do
          {:ok, body, final} ->
            {:ok,
             %{
               status: 200,
               status_text: "OK",
               headers: [],
               body: body,
               url: final,
               redirected: false
             }}

          error ->
            error
        end
    end
  end

  defp fetch(url) do
    allowed? = page_scheme() == "file" or URI.parse(url).scheme in ["http", "https", "data"]

    if allowed? do
      case Process.get(:rt_info).fetch.(url) do
        {:ok, body, final} -> {:ok, body, final}
        {:error, msg} -> {:error, to_string(msg)}
      end
    else
      {:error, "blocked"}
    end
  end

  defp page_scheme, do: URI.parse(page_url()).scheme

  defp run_classic(src, _base) do
    case Parser.parse(src) do
      {:ok, program} -> Interp.run_program(program)
      {:error, msg} -> throw({:syntax, msg})
    end
  end

  # ── modules ────────────────────────────────────────────────

  defp add_importmap(%{text: text}) do
    case safe_json(text) do
      %{"imports" => imports} when is_map(imports) ->
        base = base_url()

        resolved =
          Map.new(imports, fn {k, v} ->
            key = if bare?(k), do: k, else: Browser.Fetch.resolve(base, k)
            {key, Browser.Fetch.resolve(base, to_string(v))}
          end)

        Process.put(:rt_importmap, Map.merge(Process.get(:rt_importmap), resolved))

      _ ->
        :ok
    end
  end

  defp safe_json(text) do
    :json.decode(text)
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  defp bare?(spec),
    do:
      not (String.starts_with?(spec, ["./", "../", "/"]) or
             Regex.match?(~r/^[a-z][a-z0-9+.-]*:/i, spec))

  # the address an import specifier stands for
  defp resolve_specifier(spec, base) do
    candidate = if bare?(spec), do: spec, else: Browser.Fetch.resolve(base, spec)
    map = Process.get(:rt_importmap)

    prefix =
      map
      |> Map.keys()
      |> Enum.filter(&(String.ends_with?(&1, "/") and String.starts_with?(candidate, &1)))
      |> Enum.max_by(&String.length/1, fn -> nil end)

    cond do
      Map.has_key?(map, candidate) ->
        Map.fetch!(map, candidate)

      prefix ->
        map[prefix] <> String.replace_prefix(candidate, prefix, "")

      bare?(candidate) ->
        Interp.throw_error("TypeError", "Failed to resolve module specifier '#{spec}'")

      true ->
        candidate
    end
  end

  defp run_module_source(src, base) do
    case Parser.parse(src) do
      {:ok, program} ->
        Interp.run_module(
          program,
          fn spec -> load_module(resolve_specifier(spec, base)) end,
          base
        )

      {:error, msg} ->
        throw({:syntax, msg})
    end
  end

  defp load_module(url) do
    case Process.get(:rt_modules) do
      %{^url => ns} ->
        ns

      modules ->
        # a module that imports itself (through others) sees an empty namespace
        Process.put(:rt_modules, Map.put(modules, url, Interp.new_object()))

        case fetch(url) do
          {:ok, src, final} ->
            ns = run_module_source(src, final)
            Process.put(:rt_modules, Map.put(Process.get(:rt_modules), url, ns))
            ns

          {:error, msg} ->
            Interp.throw_error("TypeError", "Failed to fetch module #{url}: #{msg}")
        end
    end
  end
end
