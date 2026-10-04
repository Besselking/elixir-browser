defmodule Browser.JS.Test262 do
  @moduledoc """
  Runs tests from test262, the ECMAScript conformance suite, against the JavaScript runtime.

  Used by `mix js.test262`; see its documentation for how to get the suite and read the results.

  A test is a JavaScript file with a YAML header (`/*--- ... ---*/`) naming the harness files it
  `includes`, the language `features` it exercises, `flags` (`onlyStrict`, `noStrict`, `raw`,
  `async`, `module`) and, for a test that has to fail, the `negative` error. It passes when it
  runs without throwing (an `async` test when it calls `$DONE()`), and a negative test when it
  fails with the expected error. Each test runs in a process of its own with the harness
  (`assert.js`, `sta.js`, and the included files) in front of it.

  A test is skipped, not failed, when it needs something the runtime is known not to have
  (`unsupported_features/0`) or something the runner does not provide (modules, other realms).
  """

  alias Browser.JS.{Builtins, Interp, Parser}

  # language features that are not there yet: tests that need them are skipped
  @unsupported_features ~w(
    symbols-as-weakmap-keys Proxy proxy-missing-checks BigInt SharedArrayBuffer Atomics
    Atomics.pause Atomics.waitAsync Float16Array resizable-arraybuffer arraybuffer-transfer
    immutable-arraybuffer align-detached-buffer-semantics-with-web-reality WeakRef
    FinalizationRegistry set-methods dynamic-import tail-call-optimization Temporal ShadowRealm
    decorators import-attributes import-text import-bytes json-modules top-level-await
    explicit-resource-management export-star-as-namespace-from-module
    arbitrary-module-namespace-names Array.fromAsync iterator-helpers iterator-chunking
    iterator-sequencing iterator-includes Iterator.prototype.join joint-iteration
    uint8array-base64 upsert await-dictionary regexp-match-indices regexp-v-flag
    regexp-duplicate-named-groups RegExp.escape legacy-regexp Error.isError error-stack-accessor
    json-parse-with-source Math.sumPrecise promise-try nonextensible-applies-to-private
  )

  def unsupported_features, do: @unsupported_features

  @doc "The test files under `paths` (relative to the suite's `test/` directory), sorted."
  def collect(root, paths) do
    paths
    |> Enum.flat_map(fn p ->
      full = Path.join([root, "test", p])

      cond do
        File.regular?(full) -> [full]
        File.dir?(full) -> Path.wildcard(Path.join(full, "**/*.js"))
        true -> []
      end
    end)
    |> Enum.reject(&String.ends_with?(&1, "_FIXTURE.js"))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(&Path.relative_to(&1, Path.join(root, "test")))
  end

  # ── the header ─────────────────────────────────────────────

  @doc "The YAML header of a test as a map (strings, lists of strings, and maps)."
  def parse_meta(source) do
    case Regex.run(~r{/\*---(.*?)---\*/}s, source) do
      [_, yaml] -> yaml |> String.split("\n") |> top(%{})
      _ -> %{}
    end
  end

  defp top([], acc), do: acc

  defp top([line | rest], acc) do
    cond do
      String.trim(line) == "" ->
        top(rest, acc)

      indent(line) > 0 ->
        top(rest, acc)

      true ->
        case Regex.run(~r/^([A-Za-z_][\w-]*):\s*(.*)$/, line) do
          [_, key, ""] ->
            {block, rest} = indented(rest, [])
            top(rest, Map.put(acc, key, block_value(block)))

          [_, key, v] when v in [">", "|", ">-", "|-", ">+", "|+"] ->
            {_, rest} = indented(rest, [])
            top(rest, Map.put(acc, key, ""))

          [_, key, v] ->
            top(rest, Map.put(acc, key, scalar(v)))

          _ ->
            top(rest, acc)
        end
    end
  end

  defp indent(line), do: byte_size(line) - byte_size(String.trim_leading(line))

  defp indented([line | rest] = lines, acc) do
    if String.trim(line) == "" or indent(line) > 0,
      do: indented(rest, [line | acc]),
      else: {Enum.reverse(acc), lines}
  end

  defp indented([], acc), do: {Enum.reverse(acc), []}

  defp block_value(block) do
    items = block |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

    cond do
      items == [] ->
        ""

      Enum.all?(items, &String.starts_with?(&1, "- ")) ->
        Enum.map(items, &scalar(String.trim_leading(&1, "- ")))

      true ->
        top(Enum.map(block, &String.trim_leading/1), %{})
    end
  end

  defp scalar("[" <> rest) do
    rest
    |> String.trim_trailing("]")
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp scalar(v), do: v |> String.trim() |> String.trim("\"") |> String.trim("'")

  defp list(meta, key) do
    case meta[key] do
      l when is_list(l) -> l
      s when is_binary(s) and s != "" -> [s]
      _ -> []
    end
  end

  # ── deciding what to run ───────────────────────────────────

  @doc """
  `:run` or `{:skip, reason}` for a test with this header and source.
  `opts[:features]` is the list of features to skip on (default `unsupported_features/0`).
  """
  def decide(meta, source, opts \\ []) do
    skipped = Keyword.get(opts, :skip_features, @unsupported_features)
    flags = list(meta, "flags")
    features = list(meta, "features")

    cond do
      "module" in flags ->
        {:skip, "module"}

      match?(%{"phase" => "resolution"}, meta["negative"]) ->
        {:skip, "module resolution"}

      (f = Enum.find(features, &(&1 in skipped))) != nil ->
        {:skip, "feature " <> f}

      String.contains?(source, ["$262.createRealm", "$262.agent"]) ->
        {:skip, "$262"}

      true ->
        :run
    end
  end

  # ── running ────────────────────────────────────────────────

  @doc """
  Loads and parses the harness files once: `%{name => program}`; `{:error, name, reason}` if
  one doesn't parse.
  """
  def load_harness(root, names) do
    Map.new(names, fn name ->
      path = Path.join([root, "harness", name])

      case File.read(path) do
        {:ok, src} ->
          case Parser.parse(src) do
            {:ok, program} -> {name, program}
            {:error, msg} -> {name, {:error, msg}}
          end

        {:error, _} ->
          {name, {:error, "missing"}}
      end
    end)
  end

  @doc "Every harness file a test needs, in order."
  def harness_names(meta) do
    flags = list(meta, "flags")

    cond do
      "raw" in flags ->
        []

      true ->
        base = ["assert.js", "sta.js"]
        asyncs = if "async" in flags, do: ["doneprintHandle.js"], else: []
        Enum.uniq(base ++ asyncs ++ list(meta, "includes"))
    end
  end

  @doc """
  Runs one test (its source, header and the parsed harness) in a fresh process.
  Returns `:pass` or `{:fail, reason}`.
  """
  def run_test(source, meta, harness, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 10_000)
    max_steps = Keyword.get(opts, :max_steps, 2_000_000)
    names = harness_names(meta)
    flags = list(meta, "flags")

    case Enum.find(names, &match?({:error, _}, harness[&1])) do
      nil ->
        source = if "onlyStrict" in flags, do: "\"use strict\";\n" <> source, else: source
        negative = meta["negative"]
        async? = "async" in flags
        programs = Enum.map(names, &harness[&1])

        spawn_and_wait(timeout, fn ->
          execute(programs, source, max_steps, async?)
        end)
        |> judge(negative, async?)

      missing ->
        {:fail, "harness file #{missing} unavailable: #{inspect(harness[missing])}"}
    end
  end

  defp spawn_and_wait(timeout, fun) do
    parent = self()
    ref = make_ref()
    {pid, mon} = spawn_monitor(fn -> send(parent, {ref, fun.()}) end)

    receive do
      {^ref, result} ->
        Process.demonitor(mon, [:flush])
        result

      {:DOWN, ^mon, _, _, reason} ->
        {:crash, reason}
    after
      timeout ->
        Process.exit(pid, :kill)
        Process.demonitor(mon, [:flush])
        :timeout
    end
  end

  # -> {:ok, printed} | {:syntax, msg} | {:uncaught, text} | :limit
  defp execute(programs, source, max_steps, async?) do
    Interp.init(max_steps)
    scope = Builtins.install()
    install_host(scope)

    try do
      case Parser.parse(source) do
        {:error, msg} ->
          {:syntax, msg}

        {:ok, program} ->
          Enum.each(programs, &Interp.run_program/1)
          Interp.run_program(program)

          if async?, do: Builtins.run_timers(fn _ -> :ok end)
          {:ok, printed()}
      end
    rescue
      e -> {:uncaught, "internal error: " <> Exception.message(e), printed()}
    catch
      {:js_error, v} -> {:uncaught, describe(v), printed()}
      :js_limit -> :limit
      {:syntax, msg} -> {:syntax, msg}
      other -> {:uncaught, "internal: " <> inspect(other), printed()}
    end
  end

  defp printed, do: Enum.reverse(Process.get(:t262_out, []))

  defp describe(v) when is_binary(v), do: v

  defp describe({:obj, _} = v) do
    name = Interp.get(v, "name")
    msg = Interp.get(v, "message")

    ctor =
      case Interp.get(v, "constructor") do
        {:obj, _} = c -> Interp.get(c, "name")
        _ -> :undefined
      end

    kind = Enum.find([ctor, name], &(is_binary(&1) and &1 != ""))

    cond do
      kind && is_binary(msg) -> kind <> ": " <> msg
      is_binary(msg) -> msg
      true -> Builtins.inspect_js(v, 0, [])
    end
  end

  defp describe(v), do: Builtins.inspect_js(v, 0, [])

  # `print` for the async harness, and a minimal `$262`
  defp install_host(scope) do
    Interp.declare(
      scope,
      "print",
      Interp.native("print", fn _, args ->
        text = args |> Enum.map(&Interp.to_str/1) |> Enum.join(" ")
        Process.put(:t262_out, [text | Process.get(:t262_out, [])])
        :undefined
      end)
    )

    host = Interp.new_object()

    Interp.put_hidden(
      host,
      "evalScript",
      Interp.native("evalScript", fn _, args ->
        case Parser.parse(Interp.to_str(Enum.at(args, 0, ""))) do
          {:ok, program} -> Interp.run_program(program)
          {:error, msg} -> Interp.throw_error("SyntaxError", msg)
        end
      end)
    )

    Interp.put_hidden(
      host,
      "detachArrayBuffer",
      Interp.native("detachArrayBuffer", fn _, args ->
        Browser.JS.TypedArrays.detach(Enum.at(args, 0, :undefined))
      end)
    )

    Interp.put_hidden(host, "gc", Interp.native("gc", fn _, _ -> :undefined end))
    Interp.declare(scope, "$262", host)
  end

  defp judge({:ok, printed}, nil, async?) do
    cond do
      not async? ->
        :pass

      Enum.any?(printed, &(&1 == "Test262:AsyncTestComplete")) ->
        :pass

      failure = Enum.find(printed, &String.starts_with?(&1, "Test262:AsyncTestFailure")) ->
        {:fail, failure}

      true ->
        {:fail, "$DONE was never called"}
    end
  end

  defp judge({:ok, _}, %{"type" => type}, _), do: {:fail, "expected #{type}, but it ran fine"}

  defp judge({:syntax, msg}, nil, _), do: {:fail, "SyntaxError: " <> msg}

  defp judge({:syntax, _}, %{"type" => type, "phase" => phase}, _) do
    if type == "SyntaxError" and phase in ["parse", "early"],
      do: :pass,
      else: {:fail, "expected #{type} (#{phase}), got a parse error"}
  end

  defp judge({:uncaught, text, printed}, nil, async?) do
    failure = async? && Enum.find(printed, &String.starts_with?(&1, "Test262:AsyncTestFailure"))
    {:fail, failure || text}
  end

  defp judge({:uncaught, text, _}, %{"type" => type, "phase" => phase}, _) do
    cond do
      phase in ["parse", "early"] -> {:fail, "expected #{type} at parse time, got: #{text}"}
      String.starts_with?(text, type) -> :pass
      true -> {:fail, "expected #{type}, got: #{text}"}
    end
  end

  defp judge(:limit, _, _), do: {:fail, "step limit"}
  defp judge(:timeout, _, _), do: {:fail, "timeout"}

  defp judge({:crash, reason}, _, _),
    do: {:fail, ("crash: " <> inspect(reason)) |> String.slice(0, 200)}

  defp judge(other, _, _), do: {:fail, ("unexpected: " <> inspect(other)) |> String.slice(0, 200)}

  # ── a whole run ────────────────────────────────────────────

  @doc """
  Runs the tests at `files` (relative to the suite's `test/` directory). Returns
  `%{"path" => :pass | {:fail, reason} | {:skip, reason}}`.

  Options: `:timeout` (ms per test), `:max_steps`, `:skip_features`, `:jobs`, `:on_result`
  (called with `{path, result}` as results come in), `:on_time` (called with `path` and the
  microseconds the test took, from the worker process).
  """
  def run(root, files, opts \\ []) do
    jobs = Keyword.get(opts, :jobs, System.schedulers_online())
    on_result = Keyword.get(opts, :on_result, fn _ -> :ok end)
    on_time = Keyword.get(opts, :on_time)

    # the harness files that any test will want, parsed once
    harness = load_harness(root, harness_universe(root))

    files
    |> Task.async_stream(
      fn rel ->
        started = System.monotonic_time(:microsecond)
        path = Path.join([root, "test", rel])
        source = File.read!(path)
        meta = parse_meta(source)

        result =
          case decide(meta, source, opts) do
            {:skip, _} = skip ->
              skip

            :run ->
              missing = Enum.reject(harness_names(meta), &Map.has_key?(harness, &1))

              if missing == [],
                do: run_test(source, meta, harness, opts),
                else: {:fail, "harness file #{hd(missing)} not in the checkout"}
          end

        if on_time, do: on_time.(rel, System.monotonic_time(:microsecond) - started)
        {rel, result}
      end,
      max_concurrency: jobs,
      timeout: :infinity,
      ordered: false
    )
    |> Enum.reduce(%{}, fn {:ok, {rel, result} = entry}, acc ->
      on_result.(entry)
      Map.put(acc, rel, result)
    end)
  end

  defp harness_universe(root) do
    root |> Path.join("harness") |> File.ls!() |> Enum.filter(&String.ends_with?(&1, ".js"))
  end

  # ── reporting ──────────────────────────────────────────────

  @doc "Counts per directory (two levels below `test/`): `[{dir, %{pass:, fail:, skip:}}]`."
  def summarize(results) do
    results
    |> Enum.group_by(fn {path, _} -> path |> Path.split() |> Enum.take(2) |> Path.join() end)
    |> Enum.map(fn {dir, entries} ->
      counts =
        Enum.reduce(entries, %{pass: 0, fail: 0, skip: 0}, fn {_, r}, acc ->
          case r do
            :pass -> %{acc | pass: acc.pass + 1}
            {:fail, _} -> %{acc | fail: acc.fail + 1}
            {:skip, _} -> %{acc | skip: acc.skip + 1}
          end
        end)

      {dir, counts}
    end)
    |> Enum.sort()
  end

  @doc "The paths that pass, sorted."
  def passing(results),
    do: for({path, :pass} <- results, do: path) |> Enum.sort()
end
