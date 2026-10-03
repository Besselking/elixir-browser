defmodule Mix.Tasks.Browser.Screenshot do
  @shortdoc "Loads a page and saves a screenshot of it, without a window"

  @moduledoc """
  Loads a page, lays it out and draws it as SVG (see `Browser.Screenshot`), then turns the SVG
  into a PNG with headless Chromium when one is found (`CHROME` names the binary).

      mix browser.screenshot URL OUT.png [--width 1000] [--height 800]

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
    {opts, rest} = OptionParser.parse!(args, strict: [width: :integer, height: :integer])
    [url, out] = rest

    Application.put_env(:browser, :gui, false)
    Mix.Task.run("app.start")

    width = opts[:width] || 1000

    {:ok, page} = Browser.Page.load(url)

    {items, height} =
      Browser.Layout.layout(page.nodes, width, &Browser.Screenshot.measure/2, 800,
        svg_defs: page.svg_defs
      )

    height = min(opts[:height] || height, 6000) |> max(1)

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
