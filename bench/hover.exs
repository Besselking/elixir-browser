# Usage: mix run --no-start bench/hover.exs [paragraphs]
# Times the hit tests a mouse-motion event performs (UI.link_at + UI.control_at) on a big page.
alias Browser.{Page, Layout, UI}
n = String.to_integer(List.first(System.argv()) || "400")
measure = fn t, _s -> String.length(t) * 7 end

para = fn i ->
  "<p>Paragraph #{i} with some words and <a href=\"/a#{i}\">a link #{i}</a> then more text, <a href=\"/b#{i}\">another</a> and trailing prose to wrap the line a few times over.</p>" <>
    if(rem(i, 20) == 0, do: "<form><input name=q#{i}><input type=checkbox><button>Go</button></form>", else: "")
end

html = "<html><body>" <> Enum.map_join(1..n, para) <> "</body></html>"
page = Page.build(html, "https://example.com/")
page = Page.render(page, page.form_state)
{items, height} = Layout.layout(page.nodes, 1000, measure, 768, images: %{}, svg_defs: page.svg_defs)
controls = Layout.controls(items)
links = UI.links(items)
IO.puts("#{n} paragraphs: #{length(items)} items, #{map_size(controls)} controls, height #{height}")

time = fn fun, k ->
  fun.()
  {us, _} = :timer.tc(fn -> for _ <- 1..k, do: fun.() end)
  us / k
end

pts = for y <- 0..(height - 1)//div(height, 50), x <- [30, 400, 900], do: {x, y}
per_event = fn f -> time.(fn -> Enum.each(pts, fn {x, y} -> f.(x, y) end) end, 20) / length(pts) end

old = fn x, y ->
  Enum.find_value(items, fn
    %{type: t, href: h} = it when t in [:text, :image, :svg] and is_binary(h) ->
      if x >= it.x and x <= it.x + it.w and y >= it.y and y <= it.y + it.h + 4, do: h
    _ -> nil
  end)
end
for {x, y} <- pts, do: ^x = (if old.(x, y) == UI.link_at(links, x, y), do: x, else: raise("index disagrees with scan at #{x},#{y}"))
IO.puts("old link_at (scan all items): #{Float.round(per_event.(old), 1)} us/event")
IO.puts("link_at (banded index): #{Float.round(per_event.(fn x, y -> UI.link_at(links, x, y) end), 1)} us/event")
IO.puts("control_at: #{Float.round(per_event.(fn x, y -> UI.control_at(controls, x, y) end), 1)} us/event")
IO.puts("motion total: #{Float.round(per_event.(fn x, y -> UI.link_at(links, x, y); UI.control_at(controls, x, y) end), 1)} us/event")
