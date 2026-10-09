# Copies Speedometer 3.1 to a folder, so that it can be served locally and run without the network.
#
#     mix run --no-start scripts/mirror-speedometer.exs DIR
#
# DIR/Speedometer3.1 then holds the benchmark. Serve DIR over HTTP (for example with
# `python3 -m http.server 8765` in DIR) and run it with
# `mix run --no-start bench/speedometer.exs http://localhost:8765/Speedometer3.1/`.
#
# The script starts at the index page and `resources/tests.mjs`, reads every script, style sheet and
# page it finds there for more file names, and fetches those too. The files of the Performance
# Dashboard suite that its page names in `fetchedPaths` are fetched as well.
Application.put_env(:browser, :gui, false)
{:ok, _} = Application.ensure_all_started(:browser)

defmodule Mirror do
  @base "https://browserbench.org/Speedometer3.1/"
  @name ~r/(?:from\s*|import\s*\(?\s*|src=|href=|url\(|["'`])["'`]?(\.{0,2}\/?[\w@.\/%-]+\.(?:mjs|js|css|html|json))/
  @dashboard "resources/perf.webkit.org/public/"

  def run(dir) do
    root = Path.join(dir, "Speedometer3.1")
    seeds = ["index.html", "resources/tests.mjs", @dashboard <> "v3/index.html"]
    n = crawl(seeds, MapSet.new(), root)
    log_progress(Path.join(root, "resources/main.mjs"))
    IO.puts("#{n} files in #{root}")
  end

  # The page shows its progress in the window only. A few `console.log` lines make `bench/speedometer.exs`
  # able to follow it: one per step, one at the end, and the stack of an error.
  defp log_progress(file) do
    src = File.read!(file)

    if not String.contains?(src, "console.log(`STEP") do
      src
      |> String.replace(
        "willRunTest(suite, test) {\n",
        "willRunTest(suite, test) {\n        console.log(`STEP ${suite.name} / ${test.name} ${Math.round(performance.now())}`);\n",
        global: false
      )
      |> String.replace(
        "handleError(error) {\n",
        "handleError(error) {\n        console.log(\"ERROR \" + ((error && error.stack) || error));\n",
        global: false
      )
      |> String.replace(
        "didFinishLastIteration(metrics) {\n",
        "didFinishLastIteration(metrics) {\n        console.log(\"DONE\");\n",
        global: false
      )
      |> then(&File.write!(file, &1))
    end
  end

  defp crawl([], seen, _root), do: MapSet.size(seen)

  defp crawl([path | rest], seen, root) do
    if MapSet.member?(seen, path) do
      crawl(rest, seen, root)
    else
      body = get(path, root)
      crawl(names(path, body) ++ rest, MapSet.put(seen, path), root)
    end
  end

  defp get(path, root) do
    file = Path.join(root, path)

    case File.read(file) do
      {:ok, body} ->
        body

      _ ->
        case Browser.Fetch.load(@base <> path, cache: :reload) do
          {:ok, body, _} when is_binary(body) ->
            File.mkdir_p!(Path.dirname(file))
            File.write!(file, body)
            body

          _ ->
            nil
        end
    end
  end

  defp names(_path, nil), do: []

  defp names(path, body) do
    if Regex.match?(~r/\.(mjs|js|css|html)$/, path) do
      found =
        for [_, name] <- Regex.scan(@name, body),
            not String.starts_with?(name, "http"),
            norm =
              Path.join(Path.dirname(path), name) |> Path.expand("/") |> String.trim_leading("/"),
            do: norm

      found ++ dashboard_data(path, body)
    else
      []
    end
  end

  # the data the Performance Dashboard page lists for itself: "/data/…" and "/api/…"
  defp dashboard_data(path, body) do
    if path == @dashboard <> "v3/index.html" do
      for [_, name] <- Regex.scan(~r/"(\/(?:data|api)\/[^"]+)"/, body),
          do: @dashboard <> String.trim_leading(name, "/")
    else
      []
    end
  end
end

case System.argv() do
  [dir] -> Mirror.run(dir)
  _ -> IO.puts("usage: mix run --no-start scripts/mirror-speedometer.exs DIR")
end
