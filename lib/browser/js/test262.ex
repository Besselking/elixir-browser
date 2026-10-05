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

  alias Browser.JS.{Builtins, Interp, Modules, Parser}

  # language features that are not there yet: tests that need them are skipped
  @unsupported_features ~w(
    symbols-as-weakmap-keys proxy-missing-checks
    Atomics.pause Atomics.waitAsync
    immutable-arraybuffer align-detached-buffer-semantics-with-web-reality WeakRef
    FinalizationRegistry set-methods tail-call-optimization Temporal ShadowRealm
    decorators import-attributes import-text import-bytes json-modules top-level-await
    source-phase-imports source-phase-imports-module-source import-defer
    arbitrary-module-namespace-names iterator-helpers iterator-chunking
    iterator-sequencing iterator-includes Iterator.prototype.join joint-iteration
    uint8array-base64 upsert
    regexp-duplicate-named-groups legacy-regexp error-stack-accessor
    json-parse-with-source nonextensible-applies-to-private
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
    features = list(meta, "features")

    cond do
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

        path = Keyword.get(opts, :path)
        module? = "module" in flags

        spawn_and_wait(timeout, fn ->
          execute(programs, source, max_steps, async?, "regExpUtils.js" in names, path, module?)
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
  defp execute(programs, source, max_steps, async?, regexp_utils?, path, module?) do
    Interp.init(max_steps)
    scope = Builtins.install()
    install_host(scope)
    Modules.reset()

    # `import()` (and a module's imports) load files next to the test
    if path,
      do:
        Process.put(:js_import, fn spec, from -> Modules.import(spec, from || path, loader()) end)

    try do
      case Parser.parse(source, module: module?) do
        {:error, msg} ->
          {:syntax, msg}

        {:ok, program} ->
          Enum.each(programs, &Interp.run_program/1)
          if regexp_utils?, do: install_regexp_utils(scope)

          if module?,
            do: Modules.run(path, path, program, loader()),
            else: Interp.run_program(program)

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

  # module files are found next to the module that imports them
  defp loader do
    {fn spec, base -> {:ok, Path.expand(spec, Path.dirname(base))} end,
     fn path ->
       case File.read(path) do
         {:ok, src} -> {:ok, src, path}
         {:error, _} -> {:error, "cannot find #{path}"}
       end
     end}
  end

  # `buildString` and `testPropertyEscapes` of harness/regExpUtils.js, natively: the originals
  # walk every code point of Unicode (over a million loop iterations per test) in the
  # interpreter, which takes minutes for the ~500 property-escape tests. These do the same
  # work (same string, same RegExp test, same assert message on a mismatch) in Elixir.
  defp install_regexp_utils(scope) do
    cp = fn n -> if n in 0xD800..0xDFFF, do: "\uFFFD", else: <<n::utf8>> end

    Interp.declare(
      scope,
      "buildString",
      Interp.native("buildString", fn _, [args | _] ->
        lone = args |> Interp.get("loneCodePoints") |> Interp.array_list()
        ranges = args |> Interp.get("ranges") |> Interp.array_list()

        pieces =
          for r <- ranges do
            [from, to] = r |> Interp.array_list() |> Enum.map(&trunc/1)
            for n <- from..to//1, do: cp.(n)
          end

        IO.iodata_to_binary([Enum.map(lone, &cp.(trunc(&1))), pieces])
      end)
    )

    Interp.declare(
      scope,
      "testPropertyEscapes",
      Interp.native("testPropertyEscapes", fn _, [regexp, string, expression | _] ->
        if Browser.JS.RegExp.exec(regexp, string) == :null do
          Enum.each(String.codepoints(string), fn symbol ->
            if Browser.JS.RegExp.exec(regexp, symbol) == :null do
              <<n::utf8>> = symbol
              hex = n |> Integer.to_string(16) |> String.upcase() |> String.pad_leading(6, "0")
              msg = "`#{expression}` should match U+#{hex} (`#{symbol}`)"
              Interp.declare(scope, "__t262_msg", msg)
              {:ok, call} = Parser.parse("assert(false, __t262_msg);")
              Interp.run_program(call)
            end
          end)
        end

        :undefined
      end)
    )
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
                do: run_test(source, meta, harness, Keyword.put(opts, :path, path)),
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
