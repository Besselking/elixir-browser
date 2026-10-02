# Usage: D=<dir with saved html.duckduckgo.com pages> mix run --no-start bench/keystroke_layout.exs
# (6b7874.html = /html/?q=..., 8bcc97.html = /html/)
Application.ensure_all_started(:inets); Application.ensure_all_started(:ssl)
alias Browser.{Page, Forms, Layout, Interact}
dir = System.get_env("D")
counter = :counters.new(1, [])
measure = fn t, _s -> :counters.add(counter, 1, 1); String.length(t) * 7 end

time = fn fun, n ->
  fun.()
  {us, _} = :timer.tc(fn -> for _ <- 1..n, do: fun.() end)
  us / n / 1000
end

for {name, file} <- [{"ddg results (33KB)", "6b7874.html"}, {"ddg home (3KB)", "8bcc97.html"}] do
  body = File.read!(Path.join(dir, file))
  {build_us, page} = :timer.tc(fn -> Page.build(body, "https://html.duckduckgo.com/html/") end)
  ctl = page.forms.controls |> Map.values() |> Enum.find(&Forms.editable?/1)
  IO.puts("\n== #{name}: build #{div(build_us, 1000)} ms, #{map_size(page.forms.controls)} controls")

  value = String.duplicate("elixir browser ", 3)
  fs = Forms.put(page.form_state, ctl.cid, value: value)
  render_ms = time.(fn -> Page.render(page, fs) end, 50)
  p2 = Page.render(page, fs)

  lay = fn width -> Layout.layout(p2.nodes, width, measure, 768, images: %{}, svg_defs: p2.svg_defs, focus: %{cid: ctl.cid, caret: {0, 5}}) end
  :counters.put(counter, 1, 0)
  lay.(1000)
  calls = :counters.get(counter, 1)
  layout_ms = time.(fn -> lay.(1000) end, 30)

  fit_ms = time.(fn -> Interact.fit_chars(value, String.length(value), 0, 20, %{size: 16}, measure) end, 50)
  :counters.put(counter, 1, 0)
  Interact.fit_chars(value, String.length(value), 0, 20, %{size: 16}, measure)
  fit_calls = :counters.get(counter, 1)

  restyle_ms = time.(fn -> Page.restyle(%{page | key: nil}, %{type: "screen", width: 1000, height: 700, dppx: 1.0}) end, 5)

  IO.puts("render forms:      #{Float.round(render_ms, 2)} ms")
  IO.puts("layout (stub meas):#{Float.round(layout_ms, 2)} ms, #{calls} measure calls")
  IO.puts("fit_chars:         #{Float.round(fit_ms, 3)} ms, #{fit_calls} measure calls")
  IO.puts("restyle (resize):  #{Float.round(restyle_ms, 2)} ms")
  IO.puts("=> per keystroke ≈ render+layout = #{Float.round(render_ms + layout_ms, 2)} ms + #{calls + fit_calls} measure calls * wx round-trip")
end
