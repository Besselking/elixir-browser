defmodule Browser.JS.Worker do
  @moduledoc """
  The process of one dedicated worker (see `Browser.JS.Workers` for the page side).

  It boots like a page runtime, with an empty document, then takes the page-only names away
  (`document`, `localStorage`, ...) and runs the script from `priv/js/worker_scope.js`, which gives
  the global scope `postMessage`, `importScripts` and `close`. Then it runs the worker's script
  and serves messages and timers until the page ends it, the page's process exits, or the script
  calls `close()`.
  """

  alias Browser.JS.{Builtins, Interp, Parser, Runtime}

  @steps 5_000_000
  @slice_ms 30

  # what only a page has
  @page_only ~w(window document localStorage sessionStorage history parent top frames opener
    innerWidth innerHeight outerWidth outerHeight devicePixelRatio scrollX scrollY pageXOffset
    pageYOffset screen screenX screenY screenLeft screenTop alert confirm prompt getSelection
    getComputedStyle matchMedia open customElements visualViewport requestAnimationFrame
    cancelAnimationFrame find stop status orientation length)

  @source Path.expand("../../../priv/js/worker_scope.js", __DIR__)
  @external_resource @source
  @code File.read!(@source)

  @doc "Starts the process of worker `id` for the page process `parent`; `info` is the page's."
  def start(parent, id, spec, info) do
    info = Map.merge(info, %{url: spec.url, base: nil, owner: parent})
    :erlang.spawn_opt(fn -> run(parent, id, spec, info) end, Browser.JS.process_opts())
  end

  defp run(parent, id, spec, info) do
    Process.monitor(parent)
    Process.put(:wk_parent, parent)
    Process.put(:wk_id, id)
    {raw, _} = "<body></body>" |> Browser.HTML.parse() |> Browser.Forms.index()
    Runtime.boot(raw, info)
    install(spec)
    t0 = System.monotonic_time(:millisecond)
    Process.put(:js_now, 0.0)
    Process.put(:js_steps, @steps)
    guarded(fn -> main(spec) end)
    settle()
    loop(t0)
  end

  defp main(spec) do
    case spec.source || fetch(spec.url) do
      src when is_binary(src) ->
        if spec.module? do
          case Parser.parse(src, module: true) do
            {:ok, program} ->
              Browser.JS.Modules.run(spec.url, spec.url, program, Runtime.loader())

            {:error, msg} ->
              throw({:syntax, msg})
          end
        else
          run_classic(src)
        end

      {:error, msg} ->
        report("Failed to load worker script #{spec.url}: #{msg}")
    end
  end

  defp fetch(url) do
    case Process.get(:rt_info).fetch.(url) do
      {:ok, body, _final} -> body
      {:error, msg} -> {:error, to_string(msg)}
    end
  end

  defp run_classic(src) do
    case Parser.parse(src) do
      {:ok, program} -> Interp.run_program(program)
      {:error, msg} -> throw({:syntax, msg})
    end
  end

  # ── the global scope ───────────────────────────────────────

  defp install(spec) do
    scope = Interp.global()

    def_fn(scope, "__wk_post", fn [text | _] ->
      send(
        Process.get(:wk_parent),
        {:worker, Process.get(:wk_id), {:message, Interp.to_str(text)}}
      )

      :undefined
    end)

    def_fn(scope, "__wk_close", fn _ ->
      Process.put(:wk_closed, true)
      :undefined
    end)

    def_fn(scope, "__wk_hook", fn [f | _] ->
      Process.put(:wk_hook, f)
      :undefined
    end)

    # importScripts: each file is fetched and run in the global scope, in order
    def_fn(scope, "__wk_import", fn [url | _] ->
      url = Interp.to_str(url)

      case Process.get(:rt_info).fetch.(url) do
        {:ok, body, _} ->
          case Parser.parse(body) do
            {:ok, program} -> Interp.run_program(program)
            {:error, msg} -> Interp.throw_error("SyntaxError", msg)
          end

        {:error, msg} ->
          Interp.throw_error("NetworkError", "Failed to execute 'importScripts': #{msg} (#{url})")
      end

      :undefined
    end)

    def_fn(scope, "__wk_name", fn _ -> spec.name end)

    {:ok, ast} = Parser.parse(@code)
    Interp.run_program(ast)

    s = Interp.deref(scope)
    Interp.store(scope, %{s | vars: Map.drop(s.vars, @page_only)})
  end

  defp def_fn(scope, name, fun), do: Browser.JS.Workers.def_fn(scope, name, fun)

  # ── the loop ───────────────────────────────────────────────

  defp loop(t0) do
    if Process.get(:wk_closed) do
      :ok
    else
      wait =
        case Builtins.next_timer_at() do
          nil -> :infinity
          at -> max(trunc(at - elapsed(t0)), 0)
        end

      parent = Process.get(:wk_parent)

      receive do
        {:message, text} ->
          task(t0, fn -> deliver(text) end)
          loop(t0)

        {:worker, id, event} ->
          task(t0, fn -> Browser.JS.Workers.deliver(id, event) end)
          loop(t0)

        {:DOWN, _, :process, ^parent, _} ->
          :ok

        _other ->
          loop(t0)
      after
        wait ->
          task(t0, fn -> due(t0) end)
          loop(t0)
      end
    end
  end

  defp elapsed(t0), do: (System.monotonic_time(:millisecond) - t0) * 1.0

  defp deliver(text) do
    with f when f != nil <- Process.get(:wk_hook), do: Interp.call(f, :undefined, [text])
  end

  # timers that have come due, for one slice
  defp due(t0) do
    now = elapsed(t0)
    deadline = System.monotonic_time(:millisecond) + @slice_ms
    on_error = fn v -> report("Uncaught " <> Runtime.describe(v), v) end
    Process.put(:js_now, now)
    while_due(now, deadline, on_error)
  end

  defp while_due(now, deadline, on_error) do
    Process.put(:js_steps, @steps)

    if System.monotonic_time(:millisecond) < deadline and Builtins.run_next_timer(on_error, now),
      do: while_due(now, deadline, on_error)
  end

  defp task(t0, fun) do
    Process.put(:js_now, elapsed(t0))
    Process.put(:js_steps, @steps)
    guarded(fun)
    settle()
  end

  # microtasks, unhandled rejections, and the console go to the page
  defp settle do
    guarded(&Browser.JS.Promise.run_microtasks/0)

    for {_id, reason} <- Enum.reverse(Process.get(:js_unhandled, [])),
        do: log("Uncaught (in promise) " <> Runtime.describe(reason))

    Process.put(:js_unhandled, [])
    lines = Enum.reverse(Process.get(:js_console, []))
    Process.put(:js_console, [])

    if lines != [],
      do: send(Process.get(:wk_parent), {:worker, Process.get(:wk_id), {:console, lines}})

    Browser.JS.GC.maybe_collect()
  end

  defp guarded(fun) do
    fun.()
  rescue
    e -> log("internal error in worker: " <> Exception.message(e), :error)
  catch
    {:js_error, v} -> report("Uncaught " <> Runtime.describe(v), v)
    :js_limit -> report("script ran too long")
    {:syntax, msg} -> report("SyntaxError: " <> msg)
  end

  # an uncaught error: the page's `Worker` object hears an `error` event
  defp report(message, _value \\ nil) do
    send(
      Process.get(:wk_parent),
      {:worker, Process.get(:wk_id), {:error, message, Process.get(:rt_info).url}}
    )
  end

  defp log(text, level \\ :error),
    do: Process.put(:js_console, [{level, text} | Process.get(:js_console, [])])
end
