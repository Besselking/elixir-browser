defmodule Mix.Tasks.Browser.Archive do
  @shortdoc "Saves the network responses of a page in an archive, or lists one"

  @moduledoc """
  Saves a page as a page archive (see `Browser.Archive`): the HTML, every stylesheet, script,
  image and redirect hop, with the headers, as the server sent them. A page can then be
  loaded from the file without a network, so a session that cannot reach the site sees what
  the recording machine saw, scripts included.

      mix browser.archive URL OUT.ebarchive [--js]
      mix browser.archive --show FILE [--extract DIR]

  The first form loads `URL` and records. With `--js` the page's scripts run too, so what
  they request is in the archive. The window does the same with Develop > Record Page
  Archive.

  Replay with `--archive FILE` of `mix browser.screenshot` and `mix browser.layout`, or with
  `BROWSER_ARCHIVE=FILE` for the window.

  `--show` lists the responses of an archive. `--extract DIR` also writes each body to a file
  there (`0001.body`, ...), as received (gzip stays gzip).

  An archive has no cookies, but it holds what the pages sent. Do not share one of a page that
  you were logged in to.
  """
  use Mix.Task

  alias Browser.{Archive, Page}

  @impl true
  def run(args) do
    {opts, rest} =
      OptionParser.parse!(args, strict: [js: :boolean, show: :string, extract: :string])

    case {opts[:show], rest} do
      {nil, [url, out]} -> record(url, out, opts)
      {file, []} when is_binary(file) -> show(file, opts[:extract])
      _ -> Mix.raise("usage: mix browser.archive URL OUT.ebarchive [--js] | --show FILE")
    end
  end

  defp record(url, out, opts) do
    Application.put_env(:browser, :gui, false)
    Mix.Task.run("app.start")

    env = Browser.Style.default_env()
    Archive.record_start()

    case Page.load(Browser.Fetch.normalize(url), env) do
      {:ok, page} ->
        page = if opts[:js], do: Page.run_js(page, env), else: page
        fetch_images(page)
        archive = Archive.record_stop()

        case Archive.write(archive, out) do
          :ok -> Mix.shell().info("Wrote #{out}: #{length(archive.entries)} responses")
          {:error, why} -> Mix.raise(why)
        end

      {:error, why} ->
        Mix.raise("Could not load #{url}: #{inspect(why)}")
    end
  end

  defp fetch_images(page) do
    base = page.base || page.url

    page
    |> Page.all_image_urls()
    |> Task.async_stream(&Browser.Images.fetch(&1, base),
      max_concurrency: 6,
      timeout: 20_000,
      on_timeout: :kill_task
    )
    |> Stream.run()
  end

  defp show(file, extract) do
    case Archive.read(file) do
      {:ok, archive} ->
        Mix.shell().info("#{Archive.start_url(archive)}\n")

        archive.entries
        |> Enum.with_index(1)
        |> Enum.each(fn {e, i} ->
          Mix.shell().info(
            "#{pad(i)} #{e.method |> to_string() |> String.upcase()} #{e.status} #{byte_size(e.body)} bytes #{type(e)} #{e.url}"
          )

          if extract do
            File.mkdir_p!(extract)
            File.write!(Path.join(extract, pad(i) <> ".body"), e.body)
          end
        end)

      {:error, why} ->
        Mix.raise(why)
    end
  end

  defp pad(i), do: i |> Integer.to_string() |> String.pad_leading(4, "0")

  defp type(e) do
    case List.keyfind(e.headers, "content-type", 0) do
      {_, v} -> v |> String.split(";") |> hd()
      nil -> "-"
    end
  end
end
