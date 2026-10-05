defmodule Mix.Tasks.Reftest do
  @shortdoc "Runs web-platform-tests reference tests (layout and CSS) against the browser"

  @moduledoc """
  Runs the reference tests of web-platform-tests (WPT): pages that must render the same as a
  reference page. See `Browser.Reftest` for how pages are compared.

      mix reftest [--fetch] [paths...] [options]

  `paths` are folders or files under the suite, such as `css/CSS2/floats` (default: the CSS
  folders listed in this task). The suite is not part of the repository; `--fetch` makes a
  sparse checkout of the folders in `.wpt`.

    * `--fetch` - clone or update the suite first (needs git; downloads only what is asked for)
    * `--dir PATH` - where the suite is (default `.wpt`)
    * `--check` - compare with the baseline and exit with an error if a test that passed there
      fails now
    * `--update` - rewrite the baseline for the folders that ran
    * `--baseline FILE` - default `reftest.baseline`
    * `-v`, `--verbose` - list every failing test with its reason
    * `--failures FILE` - write the failures (path, reason) to a file
    * `--dump DIR` - save the two pictures of every failing pair there, as `.ppm` files
    * `--timeout MS` - per test, default 10000
    * `--jobs N` - parallel tests, default the number of schedulers
    * `--limit N` - run only the first N tests found
  """
  use Mix.Task

  alias Browser.Reftest

  @default_dir ".wpt"
  @default_baseline "reftest.baseline"

  @default_paths ~w(
    css/CSS2/normal-flow css/CSS2/positioning css/CSS2/box-display css/CSS2/margin-padding-clear
    css/CSS2/borders css/CSS2/floats css/CSS2/floats-clear css/CSS2/linebox css/CSS2/text
    css/CSS2/backgrounds css/CSS2/visudet css/CSS2/visufx css/CSS2/color css/CSS2/css1
    css/css-flexbox css/css-multicol css/css-position css/css-display css/css-box
    css/css-variables css/selectors css/css-text css/css-sizing
  )

  # what a sparse checkout needs besides the tests
  @always [
    "fonts",
    "common",
    "css/reference",
    "css/support",
    "css/CSS2/support",
    "css/CSS2/reference"
  ]

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
          dump: :string,
          timeout: :integer,
          jobs: :integer,
          limit: :integer
        ],
        aliases: [v: :verbose]
      )

    Application.put_env(:browser, :gui, false)
    Mix.Task.run("app.start")

    root = Path.expand(opts[:dir] || @default_dir)
    baseline_file = opts[:baseline] || @default_baseline

    paths =
      if paths == [], do: @default_paths, else: Enum.map(paths, &String.trim_trailing(&1, "/"))

    if opts[:fetch], do: fetch(root, paths)

    unless File.dir?(Path.join(root, "css")) do
      Mix.raise("""
      web-platform-tests is not at #{root}.
      Run `mix reftest --fetch` to download the CSS folders (a sparse checkout).
      """)
    end

    files = Reftest.collect(root, paths)
    files = if opts[:limit], do: Enum.take(files, opts[:limit]), else: files

    if files == [] do
      Mix.raise("no tests found under #{Enum.join(paths, ", ")} (try --fetch)")
    end

    Mix.shell().info("Running #{length(files)} tests from #{root} ...")
    started = System.monotonic_time(:millisecond)
    total = length(files)
    counter = :counters.new(1, [])
    tty? = match?({:ok, _}, :io.columns(:standard_error))

    results =
      Reftest.run(root, files,
        jobs: opts[:jobs] || System.schedulers_online(),
        timeout: opts[:timeout] || 10_000,
        dump: opts[:dump],
        on_result: fn _ ->
          :counters.add(counter, 1, 1)
          n = :counters.get(counter, 1)
          if tty? and rem(n, 200) == 0, do: IO.write(:stderr, "\r  #{n}/#{total}")
        end
      )

    if tty?, do: IO.write(:stderr, "\r" <> String.duplicate(" ", 30) <> "\r")

    report(results, opts, started)
    baseline(results, paths, baseline_file, opts)
  end

  # ── fetching ───────────────────────────────────────────────

  defp fetch(root, paths) do
    dirs = Enum.uniq(@always ++ paths)

    if File.dir?(Path.join(root, ".git")) do
      Mix.shell().info("Updating web-platform-tests in #{root} ...")
      git!(root, ["sparse-checkout", "set" | dirs])
      # a shallow clone cannot be pulled once upstream has moved on: fetch the tip and reset to it
      git!(root, ["fetch", "--quiet", "--depth", "1", "origin", "HEAD"])
      git!(root, ["reset", "--quiet", "--hard", "FETCH_HEAD"])
    else
      Mix.shell().info(
        "Cloning web-platform-tests into #{root} (only #{length(dirs)} folders) ..."
      )

      git!(File.cwd!(), [
        "clone",
        "--quiet",
        "--depth",
        "1",
        "--filter=blob:none",
        "--sparse",
        "https://github.com/web-platform-tests/wpt.git",
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
    summary = Reftest.summarize(results)
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

    failures = for({path, {:fail, reason}} <- results, do: {path, reason}) |> Enum.sort()

    if opts[:verbose] do
      Mix.shell().info("")
      for {path, reason} <- failures, do: Mix.shell().info("FAIL #{path}\n     #{reason}")
    end

    if file = opts[:failures] do
      File.write!(file, Enum.map_join(failures, "\n", fn {p, r} -> "#{p}\t#{r}" end) <> "\n")
      Mix.shell().info("Failures written to #{file}")
    end

    skips =
      for {_, {:skip, why}} <- results, do: why

    if skips != [] do
      Mix.shell().info("\nSkipped because:")

      skips
      |> Enum.frequencies()
      |> Enum.sort_by(&(-elem(&1, 1)))
      |> Enum.take(6)
      |> Enum.each(fn {why, n} ->
        Mix.shell().info("  #{String.pad_leading(Integer.to_string(n), 6)}  #{why}")
      end)
    end
  end

  # ── the baseline ───────────────────────────────────────────

  defp baseline(results, paths, file, opts) do
    passing = Reftest.passing(results)

    cond do
      opts[:update] ->
        old = read_baseline(file)
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
            "#{length(gained)} tests pass that are not in the baseline; `mix reftest --update` records them."
          )
        end

        if regressed != [] do
          Mix.shell().error("\n#{length(regressed)} tests that passed in the baseline fail now:")

          for t <- Enum.take(regressed, 50) do
            reason =
              case Map.get(results, t) do
                {:fail, r} -> r
                {:skip, r} -> "skipped: " <> r
                nil -> "not found"
              end

            Mix.shell().error("  #{t}\n      #{reason}")
          end

          Mix.raise("reftest regressions")
        else
          Mix.shell().info("No regressions against #{file} (#{length(expected)} tests).")
        end

      true ->
        :ok
    end
  end

  defp read_baseline(file) do
    case File.read(file) do
      {:ok, text} -> String.split(text, "\n", trim: true)
      {:error, _} -> []
    end
  end

  defp in_scope?(test, paths),
    do: Enum.any?(paths, fn p -> test == p or String.starts_with?(test, p <> "/") end)
end
