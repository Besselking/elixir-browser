# Usage: mix run --no-start bench/layout_pages.exs [pages...]
# Layout cost of realistic pages: the local HTML files in bench/pages/ (article, search results,
# news table, product grid, docs, a comment thread in nested tables). No network. Where
# bench/layout_features.exs times one feature per generated page, this times whole pages, per
# phase:
#
#   parse    Browser.HTML.parse (HTML text -> tree)
#   build    Browser.Page.build (parse + stylesheets + cascade)
#   restyle  Browser.Page.restyle at a new viewport width (media queries, cache cold)
#   layout   Browser.Layout.layout at 1000 px, cold
#   resize   Browser.Layout.layout at 700 px (what a window resize costs)
#   render   Browser.Page.render + layout with a changed form value (what an edit costs)
#
# Uses a stub measurer (7 px per character), so the numbers are layout work only. N=7 sets the
# number of timed runs (the table shows the median). Give file names (e.g. article.html) to run a subset.
Application.ensure_all_started(:inets)
Application.ensure_all_started(:ssl)
alias Browser.{Forms, HTML, Layout, Page}

measure = fn t, _s -> String.length(t) * 7 end
n = String.to_integer(System.get_env("N", "7"))
dir = Path.join(__DIR__, "pages")

files =
  case System.argv() do
    [] -> dir |> File.ls!() |> Enum.filter(&String.ends_with?(&1, ".html")) |> Enum.sort()
    names -> names
  end

# median of n runs in ms (one untimed warm-up run first)
time = fn fun ->
  fun.()
  samples = for _ <- 1..n, do: elem(:timer.tc(fun), 0)
  Enum.at(Enum.sort(samples), div(n, 2)) / 1000
end

fmt = fn ms -> ms |> Float.round(1) |> to_string() |> String.pad_leading(9) end
cols = ["parse", "build", "restyle", "layout", "resize", "render"]

IO.puts(
  String.pad_trailing("page", 14) <>
    String.pad_leading("KB", 5) <>
    Enum.map_join(cols, &String.pad_leading(&1, 9)) <>
    String.pad_leading("items", 8) <> String.pad_leading("height", 8)
)

totals =
  for file <- files do
    html = File.read!(Path.join(dir, file))
    url = "file://" <> Path.join(dir, file)
    env = fn w -> %{Browser.Style.default_env() | width: w} end
    page = Page.build(html, url, env.(1000))
    opts = fn p -> [images: %{}, svg_defs: p.svg_defs] end
    lay = fn p, w -> Layout.layout(p.nodes, w, measure, 768, opts.(p)) end

    parse = time.(fn -> HTML.parse(html) end)
    build = time.(fn -> Page.build(html, url, env.(1000)) end)

    restyle =
      time.(fn -> Page.restyle(%{page | key: nil, style_cache: %{}, memo: nil}, env.(700)) end)

    layout = time.(fn -> lay.(page, 1000) end)
    resize = time.(fn -> lay.(page, 700) end)

    # an edit: a text control gets a new value, then the page is rendered and laid out again
    ctl = page.forms.controls |> Map.values() |> Enum.find(&Forms.editable?/1)

    render =
      time.(fn ->
        fs =
          if ctl,
            do: Forms.put(page.form_state, ctl.cid, value: "elixir browser #{:rand.uniform(99)}"),
            else: page.form_state

        lay.(Page.render(page, fs), 1000)
      end)

    {items, height} = lay.(page, 1000) |> then(fn r -> {length(elem(r, 0)), elem(r, 1)} end)

    IO.puts(
      String.pad_trailing(file, 14) <>
        String.pad_leading("#{div(byte_size(html), 1024)}", 5) <>
        Enum.map_join([parse, build, restyle, layout, resize, render], fmt) <>
        String.pad_leading("#{items}", 8) <> String.pad_leading("#{height}", 8)
    )

    layout + resize
  end

IO.puts("\nlayout + resize total: #{Float.round(Enum.sum(totals), 1)} ms")
