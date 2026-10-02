# Layout time of table-heavy content (and of any saved page): the narrowest-column calculation.
#
#   mix run --no-start bench/table_min_width.exs            # generated tables
#   F=page.html U=https://example.com/ mix run --no-start bench/table_min_width.exs
#
# Measures with a stub measurer (7 px per character), so the numbers are layout work only.
Application.ensure_all_started(:inets); Application.ensure_all_started(:ssl)
alias Browser.{Page, Layout}
measure = fn t, _s -> String.length(t) * 7 end

time = fn fun, n ->
  fun.()
  {us, _} = :timer.tc(fn -> for _ <- 1..n, do: fun.() end)
  us / n / 1000
end

text = fn i ->
  Enum.map_join(1..40, " ", fn j -> "word#{rem(i * j, 97)}" end)
end

rows = fn cols, n ->
  for i <- 1..n do
    cells = for c <- 1..cols, do: "<td>#{text.(i + c)} <b>bold</b> <a href=\"/x\">link text here</a></td>"
    "<tr>" <> Enum.join(cells) <> "</tr>"
  end
  |> Enum.join()
end

nested = "<table><tr><td>" <> text.(3) <> "</td><td><table><tr><td>" <> text.(5) <> "</td><td>" <> text.(7) <> "</td></tr></table></td></tr></table>"

pages =
  [
    {"table 4x30", "<table>#{rows.(4, 30)}</table>"},
    {"table 8x60", "<table>#{rows.(8, 60)}</table>"},
    {"nested x20", String.duplicate(nested, 20)}
  ] ++
    case System.get_env("F") do
      nil -> []
      f -> [{f, File.read!(f)}]
    end

for {name, body} <- pages do
  html = if String.contains?(body, "<html"), do: body, else: "<html><body>#{body}</body></html>"
  page = Page.build(html, System.get_env("U", "https://example.com/"))
  ms = time.(fn -> Layout.layout(page.nodes, 1000, measure, 768, images: %{}, svg_defs: page.svg_defs) end, 5)
  IO.puts("#{String.pad_trailing(name, 14)} #{Float.round(ms, 1)} ms")
end
