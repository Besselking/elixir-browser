defmodule Mix.Tasks.Browser.Screenshot do
  @shortdoc "Loads a page and saves a screenshot of it, without a window"

  @moduledoc """
  Loads a page, lays it out and draws it as SVG (see `Browser.Screenshot`), then turns the SVG
  into a PNG with headless Chromium when one is found (`CHROME` names the binary).

      mix browser.screenshot URL OUT.png [--width 1000] [--height 800] [--wx]

  With `--wx` the page is painted by the same code as the window, into a bitmap: its fonts,
  pictures and shadows. That needs an Erlang with wx and a display (`xvfb-run -a mix
  browser.screenshot ...` on a machine without one); when wx is not usable the SVG route is
  taken instead.

  The window is not needed, so this works in CI and in cloud sessions. `--height` is the
  top part of the page to keep (default: all of it, at most 6000 px). The SVG is kept next
  to the PNG.
  """
  use Mix.Task

  @chromes [
    "chromium",
    "chromium-browser",
    "google-chrome",
    "/opt/pw-browsers/chromium/chrome-linux/chrome"
  ]

  @impl true
  def run(args) do
    {opts, rest} =
      OptionParser.parse!(args, strict: [width: :integer, height: :integer, wx: :boolean])

    [url, out] = rest

    Application.put_env(:browser, :gui, false)
    Mix.Task.run("app.start")

    width = opts[:width] || 1000

    {:ok, page} = Browser.Page.load(url)

    if opts[:wx] && wx_screenshot(page, out, width, opts[:height]),
      do: Mix.shell().info("Wrote #{out} (painted by wx)"),
      else: svg_screenshot(page, out, width, opts[:height])
  end

  # -> true when the picture was written
  defp wx_screenshot(page, out, width, max_height) do
    measure = Browser.UI.snapshot_start()
    images = fetch_images(page)

    {items, height} =
      Browser.Layout.layout(page.nodes, width, measure, 800,
        images: images,
        svg_defs: page.svg_defs
      )

    height = min(max_height || height, 6000) |> max(1)
    Browser.UI.snapshot(items, width, height, out)
  catch
    kind, reason ->
      Mix.shell().info("wx is not usable here (#{inspect({kind, reason})}); drawing SVG instead")
      false
  end

  # what the session keeps per picture: its size, or the scene of a vector one
  defp fetch_images(page) do
    base = page.base || page.url

    page
    |> Browser.Page.all_image_urls()
    |> Task.async_stream(fn url -> {url, Browser.Images.fetch(url, base)} end,
      max_concurrency: 6,
      timeout: 20_000,
      on_timeout: :kill_task
    )
    |> Enum.reduce(%{}, fn
      {:ok, {url, {:ok, scene, :svg}}}, acc ->
        {w, h} = Browser.Svg.intrinsic(scene)
        Map.put(acc, url, {:svg, max(round(w), 1), max(round(h), 1), scene})

      {:ok, {url, {:ok, bytes, format}}}, acc ->
        case Browser.UI.load_image(url, bytes, format) do
          {:ok, w, h} -> Map.put(acc, url, {:ok, w, h})
          _ -> Map.put(acc, url, :failed)
        end

      {:ok, {url, _}}, acc ->
        Map.put(acc, url, :failed)

      _, acc ->
        acc
    end)
  end

  defp svg_screenshot(page, out, width, max_height) do
    {items, height} =
      Browser.Layout.layout(page.nodes, width, &Browser.Screenshot.measure/2, 800,
        svg_defs: page.svg_defs
      )

    height = min(max_height || height, 6000) |> max(1)

    svg_path = Path.rootname(out) <> ".svg"
    File.write!(svg_path, Browser.Screenshot.svg(items, width, height))

    case chrome() do
      nil ->
        Mix.shell().info("No Chromium found; wrote #{svg_path}")

      chrome ->
        {output, status} =
          System.cmd(
            chrome,
            [
              "--headless",
              "--no-sandbox",
              "--disable-gpu",
              "--hide-scrollbars",
              "--screenshot=#{Path.expand(out)}",
              "--window-size=#{width},#{height + chrome_offset(chrome)}",
              "file://" <> Path.expand(svg_path)
            ],
            stderr_to_stdout: true
          )

        if status == 0,
          do: Mix.shell().info("Wrote #{out}"),
          else: Mix.raise("Chromium failed:\n#{output}")
    end
  end

  # headless_shell's window is the page; the full browser's loses the height of its (hidden) toolbar
  defp chrome_offset(chrome), do: if(Path.basename(chrome) == "headless_shell", do: 0, else: 87)

  defp chrome do
    System.get_env("CHROME") || playwright_shell() ||
      Enum.find_value(@chromes, &System.find_executable/1) ||
      playwright()
  end

  defp playwright_shell,
    do:
      Path.wildcard("/opt/pw-browsers/chromium_headless_shell-*/chrome-linux/headless_shell")
      |> List.first()

  defp playwright,
    do: Path.wildcard("/opt/pw-browsers/chromium-*/chrome-linux/chrome") |> List.first()
end
