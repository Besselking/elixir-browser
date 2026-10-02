# Needs a display (xvfb-run -a mix run --no-start bench/keystroke_wx.exs) and D=<dir with 6b7874.html>
# real wx measurer, real keystroke path: Page.render + Layout.layout (+ fit_chars), under Xvfb
Application.ensure_all_started(:inets); Application.ensure_all_started(:ssl)
alias Browser.{Page, Forms, Layout, Interact}
wx = :wx.new()
frame = :wxFrame.new(wx, -1, ~c"t", size: {1000, 700})
panel = :wxPanel.new(frame)
:wxFrame.show(frame)
measure = Browser.UI.measurer(%{panel: panel})
body = File.read!(Path.join(System.get_env("D"), "6b7874.html"))
page = Page.build(body, "https://html.duckduckgo.com/html/")
ctl = page.forms.controls |> Map.values() |> Enum.find(&Forms.editable?/1)
keystroke = fn value ->
  fs = Forms.put(page.form_state, ctl.cid, value: value)
  p = Page.render(page, fs)
  Interact.fit_chars(value, String.length(value), 0, 150, %{size: 16, bold: false, italic: false, mono: false}, measure)
  Layout.layout(p.nodes, 1000, measure, 700, images: %{}, svg_defs: p.svg_defs, focus: %{cid: ctl.cid, caret: {0, String.length(value)}})
end
{cold, _} = :timer.tc(fn -> keystroke.("e") end)
IO.puts("first keystroke (cold cache): #{div(cold, 1000)} ms")
text = "elixir language tutorial"
times = for i <- 2..String.length(text) do
  {us, _} = :timer.tc(fn -> keystroke.(String.slice(text, 0, i)) end)
  us / 1000
end
IO.puts("typing #{String.length(text)} chars: mean #{Float.round(Enum.sum(times) / length(times), 1)} ms/keystroke, max #{Float.round(Enum.max(times), 1)} ms")
