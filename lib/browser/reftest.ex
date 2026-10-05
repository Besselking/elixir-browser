defmodule Browser.Reftest do
  @moduledoc """
  Runs reference tests from web-platform-tests: a test page and a reference page that must
  look the same (`<link rel="match" href="ref.html">`), or must not (`rel="mismatch"`).

  Both pages are loaded, styled and laid out at 800 x 600 with a fixed-advance font (Ahem, the
  font the suite's layout tests use, is an em square per glyph), painted by
  `Browser.Reftest.Raster`, and the pictures compared pixel for pixel. Nothing needs a window.

  A test is skipped when it needs something the comparison cannot do: scripts, pictures,
  frames, embedded objects, SVG or MathML, `reftest-wait`, or a reference that is missing.
  """

  alias Browser.{Layout, Page}
  alias Browser.Reftest.{Picture, Raster}

  @width 800
  @view_height 600
  @max_height 4000
  @env %{type: "screen", width: @width, height: @view_height, dppx: 1.0}

  @unsupported [
    {~r/<script/i, "scripts"},
    {~r/reftest-wait|test-wait/, "waits for script"},
    {~r/<(video|audio|iframe|object|embed|canvas|svg|math|picture)[\s>]/i,
     "frames, vector pictures or embedded content"},
    {~r/@font-face/i, "web fonts"}
  ]

  # directories that hold support files, not tests
  @support_dirs ~w(support resources reference references tools reftest-html-notes)

  @doc "The test files under `paths` (relative to `root`), as paths relative to `root`."
  def collect(root, paths) do
    paths
    |> Enum.flat_map(fn p ->
      full = Path.join(root, p)

      cond do
        File.regular?(full) -> [full]
        File.dir?(full) -> Path.wildcard(Path.join(full, "**/*.{html,htm,xht,xhtml}"))
        true -> []
      end
    end)
    |> Enum.reject(&support_file?(&1, root))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(&Path.relative_to(&1, root))
  end

  defp support_file?(path, root) do
    rel = Path.relative_to(path, root)
    base = path |> Path.basename() |> Path.rootname()

    Enum.any?(Path.split(rel), &(&1 in @support_dirs)) or
      String.ends_with?(base, ["-ref", "-notref", "_ref", "-ref2", "-ref-001"]) or
      String.starts_with?(base, "ref-")
  end

  @doc "The `rel=match` and `rel=mismatch` links of a test: `[{:match | :mismatch, href}]`."
  def links(source) do
    for [tag] <- Regex.scan(~r/<link\b[^>]*>/i, source),
        rel when rel in ["match", "mismatch"] <- [attr(tag, "rel")],
        href when is_binary(href) <- [attr(tag, "href")] do
      {String.to_existing_atom(rel), href}
    end
  end

  # an attribute's value, quoted or not
  defp attr(tag, name) do
    case Regex.run(~r/\b#{name}\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))/i, tag) do
      [_, v] -> String.downcase(v) |> keep_case(name, v)
      [_, "", v] -> keep_case(String.downcase(v), name, v)
      [_, "", "", v] -> keep_case(String.downcase(v), name, v)
      _ -> nil
    end
  end

  # rel is case-insensitive; an address is not
  defp keep_case(lower, "rel", _v), do: lower
  defp keep_case(_lower, _name, v), do: v

  @doc "Measures text with the fixed advances `Browser.Reftest.Raster` paints."
  def measure(text, %{size: size} = style) do
    advance =
      cond do
        String.contains?(to_string(Map.get(style, :family)), "ahem") -> 1.0
        Map.get(style, :mono) -> 0.6
        true -> 0.52
      end

    round(String.length(text) * size * advance)
  end

  @doc """
  Runs the test at `rel` (relative to `root`): `:pass`, `{:fail, reason}` or `{:skip, reason}`.
  With `dump: dir` a failing pair is saved there as `.ppm` pictures.
  """
  def run_test(root, rel, opts \\ []) do
    path = Path.join(root, rel)
    source = read(path)

    case decide(source) do
      {:skip, _} = skip ->
        skip

      :run ->
        case links(source) do
          [] -> {:skip, "no reference"}
          links -> run_links(root, rel, path, source, links, opts)
        end
    end
  rescue
    e -> {:fail, "crash: " <> (Exception.message(e) |> String.split("\n") |> hd())}
  end

  defp decide(source) do
    Enum.find_value(@unsupported, :run, fn {re, why} ->
      if Regex.match?(re, source), do: {:skip, why}
    end)
  end

  defp run_links(root, rel, path, source, links, opts) do
    case render(root, path, source) do
      {:skip, _} = skip ->
        skip

      {:ok, rendered} ->
        Enum.reduce_while(links, :pass, fn {kind, href}, :pass ->
          case check_link(root, rel, path, rendered, kind, href, opts) do
            :pass -> {:cont, :pass}
            other -> {:halt, other}
          end
        end)
    end
  end

  defp check_link(root, rel, path, {items, h, pics}, kind, href, opts) do
    ref_path = resolve(root, path, href)

    if File.regular?(ref_path) do
      ref_source = read(ref_path)

      case decide(ref_source) do
        {:skip, why} ->
          {:skip, "reference: " <> why}

        :run ->
          case render(root, ref_path, ref_source) do
            {:skip, why} ->
              {:skip, "reference: " <> why}

            {:ok, {ref_items, ref_h, ref_pics}} ->
              compare(kind, rel, {items, h, pics}, {ref_items, ref_h, ref_pics}, opts)
          end
      end
    else
      {:skip, "reference missing"}
    end
  end

  defp compare(kind, rel, {items, h, pics}, {ref_items, ref_h, ref_pics}, opts) do
    height = h |> max(ref_h) |> max(@view_height) |> min(@max_height)
    a = Raster.paint(items, @width, height, pics)
    b = Raster.paint(ref_items, @width, height, ref_pics)
    diff = Raster.diff(a, b)

    case {kind, diff} do
      {:match, nil} ->
        :pass

      {:match, {n, {x, y}}} ->
        dump(opts[:dump], rel, a, b)
        {:fail, "#{n} pixels differ, the first at #{x},#{y}"}

      {:mismatch, nil} ->
        {:fail, "should differ from its reference but looks the same"}

      {:mismatch, _} ->
        :pass
    end
  end

  defp dump(nil, _rel, _a, _b), do: :ok

  defp dump(dir, rel, a, b) do
    base = Path.join(dir, String.replace(rel, "/", "__"))
    File.mkdir_p!(dir)
    File.write!(base <> ".test.ppm", Raster.ppm(a, @width))
    File.write!(base <> ".ref.ppm", Raster.ppm(b, @width))
  end

  # -> {:ok, {items, height, pictures}} | {:skip, why}
  defp render(root, path, source) do
    html = rewrite_absolute(source, root)
    page = Page.build(html, "file://" <> path, @env)

    case load_pictures(Page.all_image_urls(page)) do
      {:ok, pictures} ->
        images = Map.new(pictures, fn {url, p} -> {url, {:ok, p.w, p.h}} end)

        {items, height} =
          Layout.layout(page.nodes, @width, &measure/2, @view_height,
            images: images,
            svg_defs: page.svg_defs
          )

        {:ok, {items, height, pictures}}

      {:error, why} ->
        {:skip, why}
    end
  end

  # The pictures a page uses, decoded: `%{url => picture}`. A picture that is not a PNG file on
  # disk cannot be painted, so a page that needs one is skipped.
  defp load_pictures(urls) do
    Enum.reduce_while(urls, {:ok, %{}}, fn url, {:ok, acc} ->
      with "file://" <> file <- url,
           {:ok, bytes} <- File.read(URI.decode(file)),
           {:ok, picture} <- Picture.decode(bytes) do
        {:cont, {:ok, Map.put(acc, url, picture)}}
      else
        _ -> {:halt, {:error, "picture that is not a PNG file"}}
      end
    end)
  end

  # `/fonts/..` and `/css/..` mean the root of the suite
  defp rewrite_absolute(html, root),
    do: Regex.replace(~r/\b(href|src)=(["'])\/(?!\/)/, html, "\\1=\\2file://#{root}/")

  defp resolve(root, _test_path, "/" <> href), do: Path.join(root, href)
  defp resolve(_root, test_path, href), do: Path.expand(href, Path.dirname(test_path))

  # file contents as UTF-8, whatever the file says (old tests are Latin-1)
  defp read(path) do
    bin = File.read!(path)
    if String.valid?(bin), do: bin, else: :unicode.characters_to_binary(bin, :latin1, :utf8)
  end

  # -- running many ------------------------------------------------------------------------

  @doc """
  Runs `files` (relative to `root`) in parallel. Options: `:jobs`, `:timeout` (per test, ms),
  `:dump`, `:on_result`. -> `%{rel => :pass | {:fail, reason} | {:skip, reason}}`
  """
  def run(root, files, opts \\ []) do
    jobs = Keyword.get(opts, :jobs, System.schedulers_online())
    timeout = Keyword.get(opts, :timeout, 10_000)
    on_result = Keyword.get(opts, :on_result, fn _ -> :ok end)

    files
    |> Task.async_stream(fn rel -> {rel, run_test(root, rel, opts)} end,
      max_concurrency: jobs,
      timeout: timeout,
      on_timeout: :kill_task,
      ordered: true,
      zip_input_on_exit: true
    )
    |> Map.new(fn
      {:ok, {rel, result}} ->
        on_result.(result)
        {rel, result}

      {:exit, {rel, :timeout}} ->
        on_result.(:timeout)
        {rel, {:fail, "timeout"}}

      {:exit, {rel, _}} ->
        on_result.(:crash)
        {rel, {:fail, "crashed"}}
    end)
  end

  @doc "Counts per directory (the first `depth` path components)."
  def summarize(results, depth \\ 3) do
    results
    |> Enum.group_by(fn {path, _} ->
      path |> Path.dirname() |> Path.split() |> Enum.take(depth) |> Path.join()
    end)
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

  @doc "The tests that pass, sorted."
  def passing(results), do: for({path, :pass} <- results, do: path) |> Enum.sort()
end
