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

  alias Browser.JS.{Builtins, DOM, Interp, Modules, Parser}

  @steps 5_000_000
  @call_timeout 15_000
  # a page with many scripts takes its time to fetch and run them all
  @scripts_timeout 60_000
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

    :erlang.spawn_opt(
      fn ->
        boot(raw, Map.put(info, :owner, owner))
        loop(System.monotonic_time(:millisecond))
      end,
      Browser.JS.process_opts()
    )
  end

  @doc """
  Tells the page where its elements are (`Browser.Nids.rects/2`), where the window is scrolled to
  and how big the page is, for `getBoundingClientRect` and the like.
  """
  def layout(pid, rects, scroll_x, scroll_y, content),
    do: send(pid, {:layout, rects, scroll_x, scroll_y, content})

  @doc """
  The tab of the page is shown (`true`) or put behind another (`false`): `document.hidden` and
  `visibilityState` change and the page gets `visibilitychange`. A page that is hidden has its
  timers run at most once a second.
  """
  def visible(pid, visible?), do: send(pid, {:visible, visible?})

  @doc "The window was scrolled: scripts see the new position and get a `scroll` event."
  def scrolled(pid, x, y), do: send(pid, {:scrolled, x, y})

  def stop(pid) do
    Process.exit(pid, :kill)
    Browser.Console.drop(pid)
  end

  @doc """
  Runs `source` in the page, as the developer console does: the console shows the line and its
  value (or the error it threw), and the page changes like for any script.
  """
  def eval(pid, source), do: call(pid, {:eval, source})

  def run_scripts(pid), do: call(pid, :run_scripts, @scripts_timeout)

  @doc """
  Hands the editing host that has focus a key or a click: `action` is one of the names
  `__ed_action` in `priv/js/editing.js` knows (`"key"`, `"text"`, `"place"`, ...), with its
  arguments. The reply has `:result` (a string, for copy and cut), `:sel` and `:focus_ed`.
  """
  def edit(pid, action, args \\ []), do: call(pid, {:edit, action, args})

  @doc "The user put focus in the editing host the layout numbers `nid`."
  def edit_focus(pid, nid), do: call(pid, {:edit_focus, nid})

  @doc "The user took focus out of the editing host."
  def edit_blur(pid), do: call(pid, :edit_blur)

  @doc """
  Fires `type` at `target`: `{:control, cid}`, `{:form, fid}`, `:document` or `:window`.
  `controls` holds the live values of the page's controls (`%{cid => %{value:, checked:,
  selected:}}`), which the script reads through `.value` and friends.
  """
  def dispatch(pid, target, type, init \\ %{}, controls \\ %{}),
    do: call(pid, {:dispatch, target, type, init, controls})

  @doc "A form with `method=\"dialog\"` was submitted, by the control `cid` (nil: by script)."
  def dialog_submit(pid, fid, cid), do: call(pid, {:dialog_submit, fid, cid})

  @doc "The pointer moved from the element the layout numbers `old` to `new` (nil for none)."
  def hover(pid, old, new), do: call(pid, {:hover, old, new})

  @doc "Runs every pending timer at once (virtual time), for tests; returns the reply."
  def flush(pid), do: call(pid, :flush)

  @doc """
  `history.go(n)` between the history entries the page made itself (`pushState`, fragments):
  the reply has `moved: true` if the page took `n` steps, with `popstate` fired; otherwise
  the entry is another document's and the caller loads it.
  """
  def traverse(pid, n), do: call(pid, {:traverse, n})

  @doc "The browser followed a link to a fragment of this page, now at `url`."
  def fragment(pid, url), do: call(pid, {:fragment, url})

  @doc """
  A click on the link `href` over the element numbered `nid`: `%{frame: true}` when a frame
  took it (it loads the address itself), else the session follows the link.
  """
  def follow_link(pid, nid, href), do: call(pid, {:follow_link, nid, href})

  @doc "The page as it stands (after changes the session made to control state)."
  def snapshot(pid, controls \\ %{}), do: call(pid, {:snapshot, controls})

  defp call(pid, request, timeout \\ nil) do
    timeout = timeout || Application.get_env(:browser, :js_call_timeout, @call_timeout)
    ref = Process.monitor(pid)
    send(pid, {:call, self(), ref, request})

    receive do
      {^ref, reply} ->
        Process.demonitor(ref, [:flush])
        reply

      {:DOWN, ^ref, _, _, reason} ->
        %{dirty: false, raw: nil, outbox: [], console: [], prevented: false, crashed: reason}
    after
      timeout ->
        Process.demonitor(ref, [:flush])
        Browser.Console.add(pid, [{:error, "script timed out"}])

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

  # (the process of a worker boots the same way, with an empty document)
  @doc false
  def boot(raw, info) do
    Interp.init(@steps)
    Browser.JS.GC.enable()
    scope = Builtins.install()
    DOM.init(raw, info)
    DOM.install(scope)
    Process.put(:rt_info, info)
    Process.put(:js_hidden, info[:hidden] == true)
    Browser.JS.WebAPI.install(scope, &http/1)
    Browser.JS.Editing.install(scope)
    Browser.JS.WebAssembly.install(scope)
    Browser.JS.IndexedDB.install(scope)
    Browser.JS.Workers.install(scope)
    Browser.JS.WebSockets.install(scope)
    Modules.reset()
    Process.put(:js_import, import_fun())
    Process.put(:rt_importmap, %{})
    # what a frame's global scope starts with: the built-ins and the page's own window-level
    # names (`DOM.declare_window/1` gives it its own `window`, `document` and so on)
    Process.put(:rt_base_vars, Interp.deref(Interp.global()).vars)
    Process.put(:rt_load_frame, &load_frame/3)
    Process.put(:rt_blank_frame, &blank_frame/1)
  end

  defp import_fun do
    fn spec, from, p, type ->
      Modules.import(spec, from || base_url(), loader(), p, type)
    end
  end

  # ── frames ─────────────────────────────────────────────────

  # the realm of a new frame: its own global scope, module table and script bookkeeping
  defp make_frame(iframe, html, url) do
    scope = Interp.new_scope_with(Process.get(:rt_base_vars))
    info = Process.get(:rt_info) |> Map.merge(%{url: url, base: url})

    keys = %{
      js_global: scope,
      js_global_fixed: :__unset,
      js_global_lex: :__unset,
      js_modules: %{},
      js_import: import_fun(),
      rt_info: info,
      rt_importmap: %{},
      rt_seen_scripts: :__unset,
      rt_prefetched: %{},
      rt_script: :__unset
    }

    raw = html |> Browser.HTML.parse_document() |> with_head()
    doc = DOM.new_realm(iframe, raw, url, keys)
    DOM.in_realm(doc, fn -> DOM.declare_window(scope) end)
    doc
  end

  # (a page that starts with its `<body>` has no `<head>`: `document.head` is still there)
  defp with_head(raw) do
    Enum.map(raw, fn
      {:element, "html", attrs, kids} ->
        if Enum.any?(kids, &match?({:element, "head", _, _}, &1)),
          do: {:element, "html", attrs, kids},
          else: {:element, "html", attrs, [{:element, "head", [], []} | kids]}

      other ->
        other
    end)
  end

  # `contentDocument` of a frame that has not loaded anything yet: an empty page
  defp blank_frame(iframe), do: make_frame(iframe, "", "about:blank")

  # the load of an `<iframe>`: its page is fetched, parsed and its scripts run; then the element
  # hears `load`
  defp load_frame(iframe, source, page_doc) do
    DOM.in_realm(page_doc, fn ->
      if DOM.frame_doc(iframe) && source != :blank do
        DOM.destroy_realm(DOM.frame_doc(iframe))
      end

      Process.put(:js_steps, @steps)

      {html, url, ok?} =
        case source do
          {:srcdoc, html} ->
            {html, "about:srcdoc", true}

          {:url, url} ->
            case fetch(url) do
              {:ok, body, final} -> {frame_html(body), final, true}
              {:error, msg} -> {"", url, log(:error, "Failed to load #{url}: #{msg}") && false}
            end

          :blank ->
            {"", "about:blank", true}
        end

      doc =
        case DOM.frame_doc(iframe) do
          nil -> make_frame(iframe, html, url)
          d -> d
        end

      if ok? do
        DOM.in_realm(doc, fn ->
          Process.put(:js_steps, @steps)
          run_all_scripts()
        end)
      end

      Process.put(:js_steps, @steps)

      guard(
        fn ->
          DOM.dispatch(iframe, if(ok?, do: "load", else: "error"), %{
            bubbles: false,
            cancelable: false
          })
        end,
        :ok
      )

      Browser.JS.Promise.run_microtasks()
    end)
  end

  defp frame_html(body) when is_binary(body), do: body
  defp frame_html(body), do: IO.iodata_to_binary(body)

  # `t0` is when the runtime started: timers are timed from it
  defp loop(t0) do
    wait =
      case Builtins.next_timer_at() do
        nil -> :infinity
        at -> max(trunc(at - elapsed(t0)), throttle_wait(t0))
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

      {:worker, id, event} ->
        Process.put(:js_now, elapsed(t0))
        Process.put(:js_steps, @steps)
        guard(fn -> Browser.JS.Workers.deliver(id, event) end, :ok)
        Browser.JS.Promise.run_microtasks()
        reply = finish(%{})

        if async?(reply), do: send(Process.get(:rt_info).owner, {:js_async, self(), reply})
        loop(t0)

      {:ws, id, event} ->
        Process.put(:js_now, elapsed(t0))
        Process.put(:js_steps, @steps)
        guard(fn -> Browser.JS.WebSockets.deliver(id, event) end, :ok)
        Browser.JS.Promise.run_microtasks()
        reply = finish(%{})

        if async?(reply), do: send(Process.get(:rt_info).owner, {:js_async, self(), reply})
        loop(t0)

      {:idb, _, _} = msg ->
        idb_message(t0, msg)
        loop(t0)

      {:idb, :versionchange, _, _, _, _, _} = msg ->
        idb_message(t0, msg)
        loop(t0)

      {:visible, visible?} ->
        Process.put(:js_now, elapsed(t0))
        Process.put(:js_steps, @steps)
        guard(fn -> DOM.set_hidden(not visible?) end, :ok)
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

  # another page (or this one) changes a database: the connections hear of it
  defp idb_message(t0, msg) do
    Process.put(:js_now, elapsed(t0))
    Process.put(:js_steps, @steps)
    guard(fn -> Browser.JS.IndexedDB.deliver(msg) end, :ok)
    Browser.JS.Promise.run_microtasks()
    reply = finish(%{})

    if async?(reply), do: send(Process.get(:rt_info).owner, {:js_async, self(), reply})
  end

  # the messages about databases that are waiting, for `flush`
  defp drain_idb do
    receive do
      {:idb, _, _} = msg -> idb_message_now(msg)
      {:idb, :versionchange, _, _, _, _, _} = msg -> idb_message_now(msg)
    after
      0 -> false
    end
  end

  defp idb_message_now(msg) do
    guard(fn -> Browser.JS.IndexedDB.deliver(msg) end, :ok)
    Browser.JS.Promise.run_microtasks()
    true
  end

  defp latest_scroll(x, y) do
    receive do
      {:scrolled, x2, y2} -> latest_scroll(x2, y2)
    after
      0 -> {x, y}
    end
  end

  # A page that is hidden gets its timers once a second at most, however busy they are: the
  # time that is left before the second since they last ran is up (0 for a page that is shown).
  @hidden_interval_ms 1_000

  defp throttle_wait(t0) do
    with true <- Process.get(:js_hidden, false),
         last when is_float(last) <- Process.get(:js_last_fire) do
      max(trunc(last + @hidden_interval_ms - elapsed(t0)), 0)
    else
      _ -> 0
    end
  end

  defp elapsed(t0), do: (System.monotonic_time(:millisecond) - t0) * 1.0

  # the timers that have come due run, then whatever they changed goes to the session
  defp fire_due(t0) do
    now = elapsed(t0)
    Process.put(:js_now, now)
    Process.put(:js_steps, @steps)
    Process.put(:js_last_fire, now)

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

    # every task has the whole budget: a framework's work spread over many tasks is not one script
    Process.put(:js_steps, @steps)

    if System.monotonic_time(:millisecond) < deadline and Builtins.run_next_timer(on_error, now),
      do: while_due(now, deadline)
  end

  defp handle(:flush) do
    run_timers()
    finish(%{})
  end

  defp handle(:run_scripts) do
    run_all_scripts()
    # editing hosts are drawn from the runtime's tree: its text and line breaks are numbered
    finish(%{force_raw: DOM.has_editable?()})
  end

  defp handle({:dispatch, target, type, init, controls}) do
    DOM.apply_controls(controls)

    prevented =
      case resolve_target(target) do
        nil -> :ok
        t -> guard(fn -> DOM.dispatch(t, type, init) end, :ok)
      end

    # what the window does when the page did not stop the event: Escape closes a modal dialog,
    # a click on its backdrop may
    if prevented != :prevented do
      case {type, init, target} do
        {"keydown", %{"key" => "Escape"}, _} ->
          guard(fn -> DOM.call_global("__dialogEscape", []) end, :ok)

        {"click", _, {:numbered, n}} when n < 0 ->
          guard(fn -> DOM.dialog_backdrop(n) end, :ok)

        {"click", _, target} ->
          guard(fn -> DOM.popover_click(target) end, :ok)

        # a form was reset: its controls go back to their markup's values
        {"reset", _, {:form, fid}} ->
          guard(fn -> DOM.reset_form(fid) end, :ok)

        # a `method="dialog"` form was submitted: its dialog closes
        {"submit", %{"submitter" => cid}, {:form, fid}} ->
          guard(fn -> DOM.dialog_submit(fid, cid) end, :ok)

        _ ->
          :ok
      end
    end

    Browser.JS.Promise.run_microtasks()
    finish(%{prevented: prevented == :prevented})
  end

  # the pointer went from one element (by its layout number) to another
  # `<form method="dialog">` was submitted (by the control `cid`, or by script): the dialog closes
  defp handle({:dialog_submit, fid, cid}) do
    guard(fn -> DOM.dialog_submit(fid, cid) end, :ok)
    Browser.JS.Promise.run_microtasks()
    finish(%{})
  end

  defp handle({:hover, old, new}) do
    guard(fn -> DOM.hover(old, new) end, :ok)
    Browser.JS.Promise.run_microtasks()
    finish(%{})
  end

  # the user's keys and clicks in an editing host: the editing prelude does them
  defp handle({:edit, action, args}) do
    guard(fn -> Browser.JS.Editing.load() end, :ok)

    res =
      guard(
        fn ->
          case DOM.ed_call(action, args) do
            v when is_binary(v) -> v
            _ -> nil
          end
        end,
        nil
      )

    Browser.JS.Promise.run_microtasks()
    finish(%{result: res})
  end

  defp handle({:edit_focus, nid}) do
    guard(fn -> DOM.ed_focus(nid) end, :ok)
    Browser.JS.Promise.run_microtasks()
    finish(%{})
  end

  defp handle(:edit_blur) do
    guard(fn -> DOM.ed_blur() end, :ok)
    Browser.JS.Promise.run_microtasks()
    finish(%{})
  end

  defp handle({:traverse, n}) do
    moved = guard(fn -> DOM.traverse(n) end, :out_of_range) == :moved
    Browser.JS.Promise.run_microtasks()
    finish(%{moved: moved})
  end

  defp handle({:follow_link, nid, href}) do
    frame = guard(fn -> DOM.follow_link(nid, href) end, :page) == :frame
    Browser.JS.Promise.run_microtasks()
    finish(%{frame: frame})
  end

  defp handle({:fragment, url}) do
    guard(fn -> DOM.fragment_navigation(url) end, :ok)
    Browser.JS.Promise.run_microtasks()
    finish(%{})
  end

  defp handle({:eval, source}) do
    log(:input, source)

    guard(
      fn ->
        case Parser.parse(source) do
          {:ok, program} -> log(:result, Builtins.inspect_js(Interp.run_program(program), 0, []))
          {:error, msg} -> log(:error, "SyntaxError: " <> msg)
        end
      end,
      :ok
    )

    finish(%{})
  end

  defp handle({:snapshot, controls}) do
    DOM.apply_controls(controls)
    finish(%{force_raw: true})
  end

  defp resolve_target({:control, cid}), do: DOM.control_node(cid)
  defp resolve_target({:form, fid}), do: DOM.form_node(fid)
  defp resolve_target({:edit_host, nid}), do: DOM.node_numbered(nid)
  defp resolve_target({:numbered, nid}), do: DOM.node_numbered(nid)
  defp resolve_target(:document), do: DOM.document()
  defp resolve_target(:window), do: :window

  defp finish(extra) do
    run_new_scripts()

    for {_id, reason} <- Enum.reverse(Process.get(:js_unhandled, [])),
        do: log(:error, "Uncaught (in promise) " <> describe(reason))

    Process.put(:js_unhandled, [])
    # (a frame's document is part of the tree the page shows)
    dirty =
      DOM.dirty?() or MapSet.size(DOM.changed_frames()) > 0 or Map.get(extra, :force_raw, false)

    raw = if dirty, do: DOM.to_raw()
    if raw, do: DOM.sync_cids(raw)
    DOM.clean()

    Map.merge(
      %{
        dirty: dirty,
        raw: raw,
        url: DOM.url(),
        outbox: DOM.take_outbox(),
        sel: DOM.ed_sel(),
        focus_ed: DOM.ed_focus_nid(),
        prevented: false,
        console: take_console()
      },
      Map.delete(extra, :force_raw)
    )
  end

  defp take_console do
    c = Enum.reverse(Process.get(:js_console, []))
    Process.put(:js_console, [])
    Browser.Console.add(self(), c)
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
      log(:error, "Uncaught " <> describe(v) <> thrown_at(v) <> where())
      default

    :js_limit ->
      log(:error, "script ran too long" <> where())
      default

    {:syntax, msg} ->
      log(:error, "SyntaxError: " <> msg <> where())
      default
  end

  # where `throw "text"` was run (an error object has the lines of its stack)
  defp thrown_at({:obj, _} = v) do
    with nil <- Interp.describe_error(v), {file, line} <- Process.get(:js_throw_pos) do
      " (#{file}:#{line})"
    else
      _ -> ""
    end
  end

  defp thrown_at(_) do
    case Process.get(:js_throw_pos) do
      {file, line} -> " (#{file}:#{line})"
      _ -> ""
    end
  end

  # which script was running, for the console
  defp where do
    case Process.get(:rt_script) do
      nil -> ""
      label -> " (in #{label})"
    end
  end

  @doc false
  def describe(v) when is_binary(v), do: v

  def describe({:obj, _} = v), do: Interp.describe_error(v) || Builtins.inspect_js(v, 0, [])

  def describe(v), do: Builtins.inspect_js(v, 0, [])

  # every pending timer, with the database messages that come between them (a message is
  # heard in the task after the one that caused it, as in the loop)
  defp run_timers do
    on_error = fn v -> log(:error, "Uncaught " <> describe(v)) end
    guard(fn -> timers_and_messages(on_error) end, :ok)
  end

  defp timers_and_messages(on_error) do
    drained = drain_idb()

    cond do
      Builtins.run_next_timer(on_error) -> timers_and_messages(on_error)
      drained -> timers_and_messages(on_error)
      true -> :ok
    end
  end

  # ── scripts ────────────────────────────────────────────────

  defp run_all_scripts do
    doc = DOM.document()

    scripts =
      for nid <- DOM.descendants(doc), s = script_info(nid), not DOM.in_template?(nid), do: s

    prefetch(scripts)

    for s <- scripts, s.kind == :importmap, do: add_importmap(s)

    for s <- scripts, s.kind == :classic do
      Process.put(:rt_script, label(s))
      DOM.set_current_script(s.nid)

      with {:ok, src, base} <- script_source(s),
           do: guard(fn -> run_classic(src, file_for(s, base)) end, :ok)

      DOM.set_current_script(nil)
    end

    for s <- scripts, s.kind == :module do
      Process.put(:rt_script, label(s))

      with {:ok, src, base} <- script_source(s) do
        # a module from a file runs once, however often it is imported; an inline one is its own
        key = if is_binary(s.src) and s.src != "", do: base, else: {:inline, make_ref()}
        guard(fn -> run_module_source(src, key, base, file_for(s, base)) end, :ok)
      end
    end

    Process.put(:rt_seen_scripts, MapSet.new(scripts, & &1.nid))
    Process.delete(:rt_script)
    DOM.load_initial_frames()
    guard(fn -> DOM.dispatch(doc, "DOMContentLoaded", %{cancelable: false}) end, :ok)
    guard(fn -> DOM.dispatch(:window, "load", %{bubbles: false, cancelable: false}) end, :ok)
    guard(fn -> DOM.autofocus() end, :ok)
    Browser.JS.Promise.run_microtasks()
  end

  # Scripts that scripts put in the document (a loader adding a chunk with `createElement("script")`)
  # run after the turn that added them, and the element hears `load` (or `error`).
  defp run_new_scripts(rounds \\ 0) do
    seen = Process.get(:rt_seen_scripts)

    if seen != nil and rounds < 20 and DOM.dirty?() do
      fresh =
        for nid <- DOM.descendants(DOM.document()),
            not MapSet.member?(seen, nid),
            s = script_info(nid),
            not DOM.in_template?(nid),
            s.kind in [:classic, :module],
            external?(s) or String.trim(s.text) != "",
            do: s

      if fresh != [] do
        Process.put(:rt_seen_scripts, Enum.reduce(fresh, seen, &MapSet.put(&2, &1.nid)))
        prefetch(fresh)
        Enum.each(fresh, &run_inserted/1)
        Process.put(:js_steps, @steps)
        guard(&Browser.JS.Promise.run_microtasks/0, :ok)
        run_new_scripts(rounds + 1)
      end
    end
  end

  defp external?(%{src: src}), do: is_binary(src) and src != ""

  defp run_inserted(s) do
    Process.put(:rt_script, label(s))
    Process.put(:js_steps, @steps)
    DOM.set_current_script(s.nid)

    loaded? =
      case script_source(s) do
        {:ok, src, base} ->
          guard(fn -> run_source(s.kind, src, base, s) end, :ok)
          true

        :error ->
          false
      end

    DOM.set_current_script(nil)
    Process.delete(:rt_script)

    if external?(s) do
      event = if loaded?, do: "load", else: "error"
      Process.put(:js_steps, @steps)
      guard(fn -> DOM.dispatch(s.nid, event, %{bubbles: false, cancelable: false}) end, :ok)
    end
  end

  defp run_source(:classic, src, base, s), do: run_classic(src, file_for(s, base))

  defp run_source(:module, src, base, s) do
    key = if external?(s), do: base, else: {:inline, make_ref()}
    run_module_source(src, key, base, file_for(s, base))
  end

  # what error stacks call the script: its address, or "inline script" and a number
  defp file_for(s, base) do
    if external?(s) do
      base
    else
      n = Process.get(:rt_inline, 0) + 1
      Process.put(:rt_inline, n)
      "inline script #{n}"
    end
  end

  # the files of external scripts are fetched side by side; `script_source/1` takes them from here
  defp prefetch(scripts) do
    fetch = Process.get(:rt_info)[:fetch]

    urls =
      for %{kind: kind, src: src} = s <- scripts,
          kind in [:classic, :module],
          external?(s),
          url = Browser.Fetch.resolve(base_url(), src),
          allowed_url?(url),
          is_function(fetch, 1),
          uniq: true,
          do: url

    done =
      urls
      |> Task.async_stream(fn url -> {url, fetch.(url)} end,
        max_concurrency: 8,
        timeout: 30_000,
        on_timeout: :kill_task
      )
      |> Enum.flat_map(fn
        {:ok, {url, {:ok, _, _} = ok}} -> [{url, ok}]
        _ -> []
      end)
      |> Map.new()

    Process.put(:rt_prefetched, Map.merge(Process.get(:rt_prefetched, %{}), done))
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

    {pre, rest} = Map.pop(Process.get(:rt_prefetched, %{}), url)
    Process.put(:rt_prefetched, rest)

    case pre || fetch(url) do
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

  defp allowed_url?(url),
    do: page_scheme() == "file" or URI.parse(url).scheme in ["http", "https", "data"]

  defp fetch(url) do
    if allowed_url?(url) do
      case Process.get(:rt_info).fetch.(url) do
        {:ok, body, final} -> {:ok, body, final}
        {:error, msg} -> {:error, to_string(msg)}
      end
    else
      {:error, "blocked"}
    end
  end

  defp page_scheme, do: URI.parse(page_url()).scheme

  defp run_classic(src, file) do
    case Parser.parse(src, file: file) do
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

  defp run_module_source(src, key, base, file) do
    case Parser.parse(src, module: true, file: file) do
      {:ok, program} -> Modules.run(key, base, program, loader())
      {:error, msg} -> throw({:syntax, msg})
    end
  end

  @doc false
  def loader do
    {fn spec, base ->
       try do
         {:ok, resolve_specifier(spec, base)}
       catch
         {:js_error, _} -> {:error, "Failed to resolve module specifier '#{spec}'"}
       end
     end,
     fn url ->
       case fetch(url) do
         {:ok, src, final} -> {:ok, src, final}
         {:error, msg} -> {:error, msg}
       end
     end}
  end
end
