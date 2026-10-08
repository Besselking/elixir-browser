# Runs the IndexedDB tests of web-platform-tests (the `.any.js` files) in the JS runtime.
#
#     mix run --no-start scripts/wpt-indexeddb.exs WPT_DIR [FILTER] [--verbose]
#
# WPT_DIR is a checkout of https://github.com/web-platform-tests/wpt that has at least the
# `IndexedDB` and `resources` folders (`git clone --depth 1 --filter=blob:none --sparse ...`, then
# `git sparse-checkout set IndexedDB resources`). FILTER keeps the files whose name contains it.
# Every file runs in a page of its own, with testharness.js; the script prints one line per
# file (passed/total subtests) and, with --verbose, every subtest that did not pass.
Application.put_env(:browser, :gui, false)
Application.put_env(:browser, :indexed_db_path, nil)
Application.put_env(:browser, :local_storage_path, nil)
{:ok, _} = Application.ensure_all_started(:browser)

{opts, args} = OptionParser.parse!(System.argv(), strict: [verbose: :boolean, raw: :boolean])
[root | rest] = args
filter = List.first(rest) || ""
dir = Path.join(root, "IndexedDB")

defmodule WPTIdb do
  alias Browser.JS.Runtime

  @report """
  (function () {
    add_result_callback(function (t) {
      console.log("RESULT\\t" + t.status + "\\t" + t.name.replace(/\\s+/g, " ") + "\\t" + String(t.message || "").replace(/\\s+/g, " "));
    });
    add_completion_callback(function (tests, status) {
      console.log("DONE\\t" + status.status + "\\t" + String(status.message || "").replace(/\\s+/g, " "));
    });
  })();
  """

  def scripts_of(source, dir, root) do
    for [_, path] <- Regex.scan(~r{^// META: script=(\S+)}m, source) do
      if String.starts_with?(path, "/"), do: Path.join(root, path), else: Path.join(dir, path)
    end
  end

  def run(file, dir, root, n) do
    source = File.read!(file)

    scripts =
      [Path.join(root, "resources/testharness.js")] ++
        [:report] ++ Enum.filter(scripts_of(source, dir, root), &File.exists?/1) ++ [file]

    body =
      for s <- scripts do
        code = if s == :report, do: @report, else: File.read!(s)
        "<script>" <> String.replace(code, "</script", "<\\/script") <> "</script>"
      end

    {raw, _} = (["<body>"] ++ body) |> Enum.join("\n") |> Browser.HTML.parse() |> Browser.Forms.index()

    pid =
      Runtime.start(raw, %{
        url: "http://wpt#{n}.test/IndexedDB/#{Path.basename(file, ".any.js")}.any.html",
        width: 800,
        height: 600,
        fetch: fn _ -> {:error, "404"} end
      })

    first = Runtime.run_scripts(pid)
    flushed = Runtime.flush(pid)
    out = lines(first) ++ drain([]) ++ lines(flushed)
    Runtime.stop(pid)
    out
  end

  defp lines(%{console: c}), do: for({k, t} <- c, do: {k, t})

  defp drain(acc) do
    receive do
      {:js_async, _, reply} -> drain(acc ++ lines(reply))
    after
      0 -> acc
    end
  end
end

files =
  dir
  |> Path.join("*.any.js")
  |> Path.wildcard()
  |> Enum.filter(&String.contains?(Path.basename(&1), filter))
  |> Enum.sort()

results =
  files
  |> Enum.with_index()
  |> Task.async_stream(
    fn {file, n} ->
      out = WPTIdb.run(file, dir, root, n)
      {file, out}
    end,
    max_concurrency: 6,
    timeout: 120_000,
    on_timeout: :kill_task,
    ordered: true
  )
  |> Enum.zip(files)
  |> Enum.map(fn
    {{:ok, {file, out}}, _} -> {file, out}
    {_, file} -> {file, [error: "timed out"]}
  end)

{passed, total} =
  for {file, out} <- results, reduce: {0, 0} do
    {p, t} ->
      subtests =
        for {:log, "RESULT\t" <> rest} <- out do
          [status, name | msg] = String.split(rest, "\t")
          {status, name, Enum.join(msg, "\t")}
        end

      done = Enum.find_value(out, fn {:log, "DONE\t" <> r} -> r; _ -> nil end)
      errors = for {:error, e} <- out, do: e
      ok = Enum.count(subtests, fn {s, _, _} -> s == "0" end)
      name = Path.basename(file)
      note = cond do
        done == nil and errors != [] -> "  (no result: #{hd(errors) |> String.slice(0, 100)})"
        done == nil -> "  (no result)"
        true -> ""
      end
      IO.puts("#{String.pad_trailing(name, 64)} #{ok}/#{length(subtests)}#{note}")
      if opts[:raw], do: for(l <- out, do: IO.puts("    " <> String.slice(inspect(l), 0, 300)))

      if opts[:verbose] do
        for {s, n, m} <- subtests, s != "0", do: IO.puts("    FAIL[#{s}] #{n}: #{String.slice(m, 0, 160)}")
        for e <- errors, do: IO.puts("    ERROR #{String.slice(e, 0, 200)}")
      end

      {p + ok, t + length(subtests)}
  end

IO.puts("\n#{passed}/#{total} subtests pass in #{length(files)} files")
