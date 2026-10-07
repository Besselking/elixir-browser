# Usage: mix run --no-start bench/layout_features.exs
# Parse + style (Page.build) and layout (Layout.layout) time of generated pages that each lean on one
# rendering feature: plain text, flex rows/columns, tables, floats, sticky/transform, fieldsets and
# forms, positioned boxes, lists. Uses a stub measurer (7 px per character), so the numbers are
# layout work only, and no network. N=5 sets the number of timed runs.
Application.ensure_all_started(:inets)
Application.ensure_all_started(:ssl)
alias Browser.{Layout, Page}
measure = fn t, _s -> String.length(t) * 7 end
n = String.to_integer(System.get_env("N", "5"))

text = fn i -> Enum.map_join(1..30, " ", fn j -> "word#{rem(i * j, 97)}" end) end
gen = fn count, fun -> Enum.map_join(1..count, "\n", fun) end

pages = [
  {"plain paragraphs x300", gen.(300, fn i -> "<p>#{text.(i)} <b>bold</b> <a href=\"/x#{i}\">link</a></p>" end)},
  {"flex rows x120",
   "<style>.row{display:flex;gap:8px;align-items:center}.row>div{flex:1 1 100px}.row>span{flex:0 0 60px}</style>" <>
     gen.(120, fn i -> "<div class=row><span>#{i}</span><div>#{text.(i)}</div><div>#{text.(i + 1)}</div><div>short</div></div>" end)},
  {"flex column + wrap x40",
   "<style>.col{display:flex;flex-direction:column;height:300px}.wrap{display:flex;flex-wrap:wrap}.wrap>div{width:120px;margin:4px}</style>" <>
     gen.(40, fn i -> "<div class=col><div>#{text.(i)}</div><div style=\"flex:1\">fill</div></div><div class=wrap>#{gen.(20, fn j -> "<div>cell #{j}</div>" end)}</div>" end)},
  {"tables 6x40",
   "<style>td{padding:2px;border:1px solid #ccc}</style><table>" <>
     gen.(40, fn i -> "<tr>" <> Enum.map_join(1..6, fn c -> "<td>#{text.(i + c)}</td>" end) <> "</tr>" end) <> "</table>"},
  {"tables with colspan/rowspan x20",
   gen.(20, fn i -> "<table border=1><tr><td colspan=2>#{text.(i)}</td><td rowspan=2>r</td></tr><tr><td>a #{i}</td><td>#{text.(i + 2)}</td></tr></table>" end)},
  {"floats x150",
   "<style>.l{float:left;width:90px;margin:4px}.r{float:right;width:70px;margin:4px}</style>" <>
     gen.(150, fn i -> "<div class=l>L#{i}</div><div class=r>R#{i}</div><p>#{text.(i)}</p>" end)},
  {"floats with clear x60",
   gen.(60, fn i -> "<div style=\"float:left;width:100px;height:60px\">f#{i}</div><p>#{text.(i)}</p><div style=\"clear:both\"></div>" end)},
  {"positioned + sticky + transform x100",
   "<style>.rel{position:relative;top:2px}.abs{position:absolute;right:0;top:0}.st{position:sticky;top:0}.tr{transform:rotate(3deg) translate(2px,3px)}</style>" <>
     gen.(100, fn i -> "<div class=rel><span class=abs>x</span><div class=st>#{text.(i)}</div><div class=tr>t#{i}</div></div>" end)},
  {"lists x40 (nested)",
   gen.(40, fn i -> "<ul>" <> gen.(8, fn j -> "<li>item #{i}.#{j}<ol><li>sub a</li><li>sub b</li></ol></li>" end) <> "</ul>" end)},
  {"forms: fieldset/legend/inputs x60",
   gen.(60, fn i -> "<form><fieldset><legend>Group #{i}</legend><label>Name <input name=n#{i}></label> <select><option>a<option>b</select> <textarea>#{text.(i)}</textarea> <button>Go</button></fieldset></form>" end)},
  {"css: 400 rules + descendant selectors",
   "<style>" <> gen.(400, fn i -> ".c#{i} .d#{rem(i, 13)} > span:nth-child(2n+1) { color: #123; margin: #{rem(i, 5)}px }" end) <> "</style>" <>
     gen.(200, fn i -> "<div class=\"c#{i}\"><div class=\"d#{rem(i, 13)}\"><span>a</span><span>b #{i}</span></div></div>" end)},
  {"deep nesting 150",
   String.duplicate("<div style=\"padding:1px;border:1px solid #ddd\">", 150) <> text.(1) <> String.duplicate("</div>", 150)}
]

time = fn fun ->
  fun.()
  {us, _} = :timer.tc(fn -> for _ <- 1..n, do: fun.() end)
  us / n / 1000
end

IO.puts(String.pad_trailing("page", 40) <> String.pad_leading("build ms", 10) <> String.pad_leading("layout ms", 11) <> String.pad_leading("items", 8))

for {name, body} <- pages do
  html = "<html><body>#{body}</body></html>"

  try do
    page = Page.build(html, "https://example.com/")
    build = time.(fn -> Page.build(html, "https://example.com/") end)
    opts = [images: %{}, svg_defs: page.svg_defs]
    layout = time.(fn -> Layout.layout(page.nodes, 1000, measure, 768, opts) end)
    items = length(Layout.layout(page.nodes, 1000, measure, 768, opts) |> elem(0))

    IO.puts(
      String.pad_trailing(name, 40) <>
        String.pad_leading("#{Float.round(build, 1)}", 10) <>
        String.pad_leading("#{Float.round(layout, 1)}", 11) <> String.pad_leading("#{items}", 8)
    )
  rescue
    e -> IO.puts(String.pad_trailing(name, 40) <> "failed: " <> Exception.message(e) |> String.slice(0, 120))
  end
end
