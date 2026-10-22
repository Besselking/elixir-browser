defmodule Mix.Tasks.Browser.Screenshot do
  @shortdoc "Loads a page and saves a screenshot of it, without a window"

  @moduledoc """
  Loads a page, lays it out and draws it as SVG (see `Browser.Screenshot`), then turns the SVG
  into a PNG with headless Chromium when one is found (`CHROME` names the binary).

      mix browser.screenshot URL OUT.png [--width 1000] [--height 800] [--wx] [--js]
          [--window 600 [--scroll 0]] [--box-scroll 0] [--hover X,Y] [--archive FILE]

  With `--wx` the page is painted by the same code as the window, into a bitmap: its fonts,
  pictures and shadows. That needs an Erlang with wx and a display (`xvfb-run -a mix
  browser.screenshot ...` on a machine without one); when wx is not usable the SVG route is
  taken instead.

  With `--js` the page's scripts run first (a page that fills itself in, an editor).

  With `--wx` the scrollbars are drawn too. `--window 600` shows only a window of that height,
  `--scroll` px down the page (as the browser would, with the page's scrollbars), and
  `--box-scroll` scrolls every box that scrolls its content by that many px.

  With `--hover X,Y` the pointer is on the page point `X,Y` (px from the top left of the
  page): the element there and its ancestors match `:hover` (a menu that opens on hover).

  With `--archive FILE` the page loads from a page archive (see `mix browser.archive`) and the
  network is not used.

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
      OptionParser.parse!(args,
        strict: [
          width: :integer,
          height: :integer,
          wx: :boolean,
          js: :boolean,
          window: :integer,
          scroll: :integer,
          box_scroll: :integer,
          hover: :string,
          archive: :string
        ]
      )

    [url, out] = rest

    Application.put_env(:browser, :gui, false)
    Mix.Task.run("app.start")
    if opts[:archive], do: Browser.Archive.replay!(opts[:archive])

    width = opts[:width] || 1000

    # the cascade is for the picture's own viewport: its media queries see this width
    env = %{Browser.Style.default_env() | width: width, height: opts[:height] || 800}
    {:ok, page} = Browser.Page.load(url, env)

    page =
      if opts[:js],
        do: Browser.Page.run_js(page, %{Browser.Style.default_env() | width: width, height: 800}),
        else: page

    page = if opts[:hover], do: hover(page, opts[:hover], env), else: page

    if opts[:wx] && wx_screenshot(page, out, width, opts),
      do: Mix.shell().info("Wrote #{out} (painted by wx)"),
      else: svg_screenshot(page, out, width, opts[:height])
  end

  @doc false
  # the page with the element at the point "x,y" and its ancestors hovered (also for
  # `mix browser.layout --hover`)
  def hover(page, point, env) do
    [x, y] = point |> String.split(",") |> Enum.map(&String.to_integer(String.trim(&1)))
    {items, _} = Browser.Layout.layout(page.nodes, env.width, &Browser.Screenshot.measure/2, 800)
    parents = Browser.Nids.parents(page.pruned || [])

    chain =
      case Browser.UI.nid_at(items, x, y, 0) do
        nil -> []
        nid -> nid |> Stream.iterate(&Map.get(parents, &1)) |> Enum.take_while(&(&1 != nil))
      end

    Browser.Page.set_hover(page, chain, env)
  end

  # -> true when the picture was written
  defp wx_screenshot(page, out, width, opts) do
    alias Browser.{Scrollbars, Scrollers}
    measure = Browser.UI.snapshot_start()
    images = fetch_images(page)

    env = %{Browser.Style.default_env() | width: width, height: 800}

    {_page, {laid_out, page_height}} =
      Browser.Page.settle(page, env, fn page ->
        Browser.Layout.layout(page.nodes, width, measure, 800,
          scrollers: true,
          metrics: &measure.(:content_height, &1),
          images: images,
          svg_defs: page.svg_defs,
          boxes: Browser.Page.cq?(page)
        )
      end)

    {base, scrollers} = Scrollers.index(laid_out)

    soff =
      Scrollers.clamp(
        scrollers,
        Map.new(scrollers, fn {sid, _} -> {sid, {0, opts[:box_scroll] || 0}} end)
      )

    items = Scrollers.apply(base, scrollers, soff)

    height = if opts[:window], do: opts[:window], else: min(opts[:height] || page_height, 6000)
    height = max(height, 1)
    scroll = min(opts[:scroll] || 0, max(page_height - height, 0))

    view = %{
      w: width,
      h: height,
      scroll: scroll,
      scroll_x: 0,
      height: page_height,
      content_w: Browser.Layout.content_width(base, width)
    }

    overlay =
      view
      |> Scrollbars.bars(scrollers, soff)
      |> Scrollbars.items(0, nil, Browser.Scrollbars.dark_page?(items))

    Browser.UI.snapshot(items, width, height, out, overlay, scroll)
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
    env = %{Browser.Style.default_env() | width: width, height: 800}

    {_page, {items, height}} =
      Browser.Page.settle(page, env, fn page ->
        Browser.Layout.layout(page.nodes, width, &Browser.Screenshot.measure/2, 800,
          svg_defs: page.svg_defs,
          boxes: Browser.Page.cq?(page)
        )
      end)

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
