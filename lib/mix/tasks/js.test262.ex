defmodule Mix.Tasks.Js.Test262 do
  @shortdoc "Runs test262 (the ECMAScript conformance suite) against the JavaScript runtime"

  @moduledoc """
  Runs tests from [test262](https://github.com/tc39/test262) against `Browser.JS`.

      mix js.test262 [paths...] [options]

  `paths` are relative to the suite's `test/` directory, either folders or single files, e.g.
  `built-ins/Array` or `language/expressions/addition`. Without paths the default set is run
  (`@default_paths` below: the language and the built-ins the runtime is meant to have).

  ## Getting the suite

  The suite is not part of the repository. `--fetch` makes a shallow, sparse checkout of the
  folders needed (about 50 MB) in `.test262/` (or `--dir`), which is ignored by git. It takes a
  few seconds; run it once, and again to update.

  ## Options

    * `--fetch` - clone or update the suite first
    * `--dir PATH` - where the suite is (default `.test262`)
    * `--check` - compare with the baseline and exit with an error if a test that passed there
      fails now (what CI runs)
    * `--update` - rewrite the baseline for the tests that ran: the passing ones are recorded
    * `--baseline FILE` - default `test262.baseline`
    * `-v`, `--verbose` - list every failing test with its first error
    * `--failures FILE` - write the failures (path, reason) to a file
    * `--all-features` - do not skip the tests that need features the runtime lacks
    * `--timeout MS` - per test, default 10000
    * `--jobs N` - parallel tests, default the number of schedulers
    * `--limit N` - run only the first N tests found (a quick look)

  A test passes when it runs without throwing (`$DONE()` for async ones) or, for a negative
  test, fails with the expected error. Tests needing language features the runtime does not
  have, modules, or other realms are skipped, not failed.
  """
  use Mix.Task

  alias Browser.JS.Test262

  @default_dir ".test262"
  @default_baseline "test262.baseline"

  @default_paths ~w(
    built-ins/Array built-ins/Boolean built-ins/Error built-ins/Function built-ins/Infinity
    built-ins/JSON built-ins/Math built-ins/NaN built-ins/Number built-ins/Object
    built-ins/Promise built-ins/RegExp built-ins/String built-ins/isFinite built-ins/isNaN
    built-ins/parseFloat built-ins/parseInt built-ins/undefined
    language/arguments-object language/asi language/block-scope language/comments
    language/destructuring language/expressions language/function-code language/future-reserved-words
    language/identifiers language/keywords language/literals language/punctuators
    language/reserved-words language/rest-parameters language/statements language/types
    language/white-space
  )

  @sparse_dirs ["harness" | Enum.map(@default_paths, &("test/" <> &1))]

  @impl true
  def run(args) do
    {opts, paths} =
      OptionParser.parse!(args,
        strict: [
          fetch: :boolean,
          dir: :string,
          check: :boolean,
          update: :boolean,
          baseline: :string,
          verbose: :boolean,
          failures: :string,
          all_features: :boolean,
          timeout: :integer,
          jobs: :integer,
          limit: :integer
        ],
        aliases: [v: :verbose]
      )

    root = Path.expand(opts[:dir] || @default_dir)
    baseline_file = opts[:baseline] || @default_baseline

    paths =
      if paths == [], do: @default_paths, else: Enum.map(paths, &String.trim_trailing(&1, "/"))

    if opts[:fetch], do: fetch(root, paths)

    unless File.dir?(Path.join(root, "harness")) do
      Mix.raise("""
      test262 is not at #{root}.
      Run `mix js.test262 --fetch` to download it (a sparse checkout, about 50 MB).
      """)
    end

    # the paths may be outside the default sparse set
    files = Test262.collect(root, paths)
    files = if opts[:limit], do: Enum.take(files, opts[:limit]), else: files

    if files == [] do
      Mix.raise(
        "no tests found under #{Enum.join(paths, ", ")} (is it part of the checkout? try --fetch)"
      )
    end

    Mix.shell().info("Running #{length(files)} tests from #{root} ...")
    started = System.monotonic_time(:millisecond)
    total = length(files)
    counter = :counters.new(1, [])
    # progress is for a terminal, not for a log
    tty? = match?({:ok, _}, :io.columns(:standard_error))

    run_opts =
      [
        timeout: opts[:timeout] || 10_000,
        jobs: opts[:jobs] || System.schedulers_online(),
        on_result: fn _ ->
          :counters.add(counter, 1, 1)
          n = :counters.get(counter, 1)
          if tty? and rem(n, 500) == 0, do: IO.write(:stderr, "\r  #{n}/#{total}")
        end
      ] ++ if(opts[:all_features], do: [skip_features: []], else: [])

    results = Test262.run(root, files, run_opts)
    if tty?, do: IO.write(:stderr, "\r" <> String.duplicate(" ", 30) <> "\r")

    report(results, opts, started)
    baseline(results, paths, baseline_file, opts)
  end

  # ── fetching ───────────────────────────────────────────────

  defp fetch(root, paths) do
    dirs = Enum.uniq(@sparse_dirs ++ Enum.map(paths, &("test/" <> &1)))

    if File.dir?(Path.join(root, ".git")) do
      Mix.shell().info("Updating test262 in #{root} ...")
      git!(root, ["pull", "--quiet", "--depth", "1"])
      git!(root, ["sparse-checkout", "set" | dirs])
    else
      Mix.shell().info("Cloning test262 into #{root} ...")

      git!(File.cwd!(), [
        "clone",
        "--quiet",
        "--depth",
        "1",
        "--filter=blob:none",
        "--sparse",
        "https://github.com/tc39/test262.git",
        root
      ])

      git!(root, ["sparse-checkout", "set" | dirs])
    end
  end

  defp git!(dir, args) do
    case System.cmd("git", args, cd: dir, stderr_to_stdout: true) do
      {_, 0} -> :ok
      {out, code} -> Mix.raise("git #{Enum.join(args, " ")} failed (#{code}):\n#{out}")
    end
  end

  # ── reporting ──────────────────────────────────────────────

  defp report(results, opts, started) do
    summary = Test262.summarize(results)

    width = summary |> Enum.map(fn {d, _} -> String.length(d) end) |> Enum.max(fn -> 10 end)

    Mix.shell().info("")

    Mix.shell().info(
      String.pad_trailing("directory", width) <>
        "   pass   fail   skip   pass rate (of those run)"
    )

    for {dir, c} <- summary do
      ran = c.pass + c.fail
      rate = if ran == 0, do: "-", else: "#{Float.round(c.pass * 100 / ran, 1)}%"

      Mix.shell().info(
        String.pad_trailing(dir, width) <>
          String.pad_leading(Integer.to_string(c.pass), 7) <>
          String.pad_leading(Integer.to_string(c.fail), 7) <>
          String.pad_leading(Integer.to_string(c.skip), 7) <> "   " <> rate
      )
    end

    totals =
      Enum.reduce(summary, %{pass: 0, fail: 0, skip: 0}, fn {_, c}, acc ->
        %{pass: acc.pass + c.pass, fail: acc.fail + c.fail, skip: acc.skip + c.skip}
      end)

    ran = totals.pass + totals.fail
    rate = if ran == 0, do: 0.0, else: Float.round(totals.pass * 100 / ran, 1)
    seconds = Float.round((System.monotonic_time(:millisecond) - started) / 1000, 1)

    Mix.shell().info("")

    Mix.shell().info(
      "#{totals.pass} passed, #{totals.fail} failed, #{totals.skip} skipped " <>
        "(#{rate}% of the #{ran} that ran) in #{seconds}s"
    )

    failures =
      for {path, {:fail, reason}} <- results, do: {path, reason}

    failures = Enum.sort(failures)

    if opts[:verbose] do
      Mix.shell().info("")

      for {path, reason} <- failures,
          do: Mix.shell().info("FAIL #{path}\n     #{first_line(reason)}")
    end

    if file = opts[:failures] do
      File.write!(
        file,
        Enum.map_join(failures, "\n", fn {p, r} -> "#{p}\t#{first_line(r)}" end) <> "\n"
      )

      Mix.shell().info("Failures written to #{file}")
    end

    if failures != [] and opts[:verbose] != true do
      Mix.shell().info("\nMost common reasons:")

      failures
      |> Enum.map(fn {_, r} -> r |> first_line() |> String.slice(0, 70) end)
      |> Enum.frequencies()
      |> Enum.sort_by(&(-elem(&1, 1)))
      |> Enum.take(8)
      |> Enum.each(fn {reason, n} ->
        Mix.shell().info("  #{String.pad_leading(Integer.to_string(n), 6)}  #{reason}")
      end)
    end
  end

  defp first_line(text), do: text |> to_string() |> String.split("\n") |> hd()

  # ── the baseline ───────────────────────────────────────────

  defp baseline(results, paths, file, opts) do
    passing = Test262.passing(results)

    cond do
      opts[:update] ->
        old = read_baseline(file)
        # what was recorded for the folders that ran is replaced
        kept = Enum.reject(old, &in_scope?(&1, paths))
        new = Enum.sort(kept ++ passing)
        File.write!(file, Enum.join(new, "\n") <> "\n")
        Mix.shell().info("Baseline #{file} updated: #{length(new)} passing tests.")

      opts[:check] ->
        expected = file |> read_baseline() |> Enum.filter(&in_scope?(&1, paths))
        regressed = for t <- expected, Map.get(results, t) != :pass, do: t
        gained = passing -- expected

        if gained != [] do
          Mix.shell().info(
            "#{length(gained)} tests pass that are not in the baseline; `mix js.test262 --update` records them."
          )
        end

        if regressed != [] do
          Mix.shell().error("\n#{length(regressed)} tests that passed in the baseline fail now:")

          for t <- Enum.take(regressed, 50) do
            reason =
              case Map.get(results, t) do
                {:fail, r} -> first_line(r)
                {:skip, r} -> "skipped: " <> r
                nil -> "not found"
              end

            Mix.shell().error("  #{t}\n      #{reason}")
          end

          if length(regressed) > 50,
            do: Mix.shell().error("  ... and #{length(regressed) - 50} more")

          Mix.raise("test262 regressions")
        else
          Mix.shell().info("No regressions against #{file} (#{length(expected)} tests).")
        end

      true ->
        :ok
    end
  end

  defp read_baseline(file) do
    case File.read(file) do
      {:ok, text} -> text |> String.split("\n", trim: true)
      {:error, _} -> []
    end
  end

  defp in_scope?(test, paths) do
    Enum.any?(paths, fn p -> test == p or String.starts_with?(test, p <> "/") end)
  end
end
