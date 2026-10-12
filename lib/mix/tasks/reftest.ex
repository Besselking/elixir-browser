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
    * `--shard N/M` - run only part N of M (1-based) of the tests, for splitting a run over
      several machines. With `--check` only the baseline entries of that part are compared;
      `--update` needs the whole suite.
    * `--limit N` - run only the first N tests found
    * `--sweep` - do not compare pictures: lay out every test file found (also those a reftest
      skips) with the sizing fold in check mode, count per folder the widths the fold found
      and refused, and exit with an error if the fold finds another width than a layout, or
      makes a page crash that does not crash without it
    * `--layout-check` - lay out every page also from the layout memo the page before it left
      and from its own (`LAYOUT_MEMO=check`, see `Browser.Layout.layout_kept/6`), compare each
      with a fresh layout, compare every width the sizing fold finds with the width a layout
      finds (`LAYOUT_FOLD=check`), and exit with an error if one differs. This finds a wrong
      layout that gives the same picture, and also checks pages that fail their reference
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
          shard: :string,
          limit: :integer,
          layout_check: :boolean,
          sweep: :boolean
        ],
        aliases: [v: :verbose]
      )

    Application.put_env(:browser, :gui, false)

    if opts[:layout_check] do
      System.put_env("LAYOUT_MEMO", "check")
      System.put_env("LAYOUT_FOLD", "check")
    end

    Mix.Task.run("app.start")

    root = Path.expand(opts[:dir] || @default_dir)

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

    shard = if opts[:shard], do: Browser.Shard.parse!(opts[:shard])
    if shard && opts[:update], do: Mix.raise("--update needs the whole suite: drop --shard")
    files = if shard, do: Browser.Shard.take(files, shard), else: files

    if files == [] do
      Mix.raise("no tests found under #{Enum.join(paths, ", ")} (try --fetch)")
    end

    if opts[:sweep],
      do: sweep(root, files, paths, opts),
      else: run_tests(root, files, paths, opts)
  end

  defp run_tests(root, files, paths, opts) do
    baseline_file = opts[:baseline] || @default_baseline
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
    differ = layout_check(results, opts)
    baseline(results, paths, baseline_file, opts)
    if differ > 0, do: Mix.raise("layout check: #{differ} pages laid out differently")
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

  # ── the sweep ─────────────────────────────────────────────

  defp sweep(root, files, paths, opts) do
    Mix.shell().info(
      "Laying out #{length(files)} files from #{root} with the fold in check mode ..."
    )

    started = System.monotonic_time(:millisecond)

    one = fn rel ->
      try do
        Reftest.sweep_file(root, rel)
      rescue
        e ->
          message = e |> Exception.message() |> String.split("\n") |> hd()

          cond do
            String.starts_with?(message, "layout check") -> {:wrong, message}
            fold_crash?(root, rel) -> {:wrong, "crash with the fold only: " <> message}
            true -> {:crash, message}
          end
      end
    end

    results =
      files
      |> Task.async_stream(fn rel -> {rel, one.(rel)} end,
        max_concurrency: opts[:jobs] || System.schedulers_online(),
        timeout: opts[:timeout] || 10_000,
        on_timeout: :kill_task,
        ordered: true,
        zip_input_on_exit: true
      )
      |> Enum.map(fn
        {:ok, result} -> result
        {:exit, {rel, _}} -> {rel, {:crash, "timeout"}}
      end)

    groups =
      Enum.group_by(results, fn {rel, _} ->
        Enum.find(paths, rel, &(rel == &1 or String.starts_with?(rel, &1 <> "/")))
      end)

    width = paths |> Enum.map(&String.length/1) |> Enum.max(fn -> 10 end)

    Mix.shell().info(
      "\n" <> String.pad_trailing("folder", width) <> "  files  folded  refused  wrong  crashed"
    )

    for {path, entries} <- Enum.sort(groups) do
      count = fn kind -> Enum.count(entries, fn {_, r} -> elem(r, 0) == kind end) end
      folded = for({_, {:ok, h, _}} <- entries, do: h) |> Enum.sum()
      refused = for({_, {:ok, _, f}} <- entries, do: f) |> Enum.sum()

      Mix.shell().info(
        String.pad_trailing(path, width) <>
          Enum.map_join(
            [
              {length(entries), 7},
              {folded, 8},
              {refused, 9},
              {count.(:wrong), 7},
              {count.(:crash), 9}
            ],
            fn {n, w} -> String.pad_leading(Integer.to_string(n), w) end
          )
      )
    end

    seconds = Float.round((System.monotonic_time(:millisecond) - started) / 1000, 1)
    Mix.shell().info("\n#{length(results)} files in #{seconds}s")
    wrong = for {rel, {:wrong, why}} <- results, do: {rel, why}

    if wrong != [] do
      Mix.shell().error("\nThe fold is wrong in #{length(wrong)} files:")
      for {rel, why} <- Enum.take(wrong, 50), do: Mix.shell().error("  #{rel}\n      #{why}")
      Mix.raise("sweep: the fold is wrong in #{length(wrong)} files")
    end
  end

  defp fold_crash?(root, rel) do
    Reftest.sweep_file(root, rel, :off)
    true
  rescue
    _ -> false
  end

  # -> the number of tests where a layout from the memo differed from a fresh layout
  defp layout_check(results, opts) do
    differ =
      for {path, {:fail, "crash: layout check" <> _ = reason}} <- results,
          do: {path, reason}

    if opts[:layout_check] do
      if differ == [] do
        Mix.shell().info("Layout check: every page is laid out the same from the memo.")
      else
        Mix.shell().error("\nLayout check: #{length(differ)} pages differ from a fresh layout:")

        for {path, reason} <- Enum.sort(differ) |> Enum.take(50),
            do: Mix.shell().error("  #{path}\n      #{reason}")
      end
    end

    length(differ)
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
        expected =
          file
          |> read_baseline()
          |> Enum.filter(&in_scope?(&1, paths))
          |> Enum.filter(&(opts[:shard] == nil or Map.has_key?(results, &1)))

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
