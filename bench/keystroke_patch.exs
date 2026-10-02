# Needs a display and D=<dir with 6b7874.html>: xvfb-run -a mix run --no-start bench/keystroke_patch.exs
Application.ensure_all_started(:inets)
Application.ensure_all_started(:ssl)
alias Browser.{Page, Forms, Layout}
wx = :wx.new()
frame = :wxFrame.new(wx, -1, ~c"t", size: {1000, 700})
panel = :wxPanel.new(frame)
:wxFrame.show(frame)
measure = Browser.UI.measurer(%{panel: panel})

page =
  Page.build(
    File.read!(Path.join(System.get_env("D"), "6b7874.html")),
    "https://html.duckduckgo.com/html/"
  )

ctl = page.forms.controls |> Map.values() |> Enum.find(&Forms.editable?/1)
true = MapSet.member?(page.fixed_width, ctl.cid)
st = fn v -> Page.render(page, Forms.put(page.form_state, ctl.cid, value: v)) end

full = fn p, v ->
  Layout.layout(p.nodes, 1000, measure, 700,
    images: %{},
    svg_defs: p.svg_defs,
    focus: %{cid: ctl.cid, caret: {0, String.length(v)}}
  )
end

text = "elixir language tutorial"
{items0, _} = full.(st.("e"), "e")

{us_full, _} =
  :timer.tc(fn ->
    for i <- 2..24,
        do:
          (
            v = String.slice(text, 0, i)
            full.(st.(v), v)
          )
  end)

{us_patch, {_, ok}} =
  :timer.tc(fn ->
    Enum.reduce(2..24, {items0, 0}, fn i, {items, ok} ->
      {o, v} = {String.slice(text, 0, i - 1), String.slice(text, 0, i)}
      _ = st.(v)

      case Layout.patch_field(items, ctl.cid, o, v, %{cid: ctl.cid, caret: {0, i}}, measure) do
        {:ok, new} -> {new, ok + 1}
        :error -> {items, ok}
      end
    end)
  end)

IO.puts(
  "full relayout: #{Float.round(us_full / 23 / 1000, 2)} ms/keystroke; patch: #{Float.round(us_patch / 23 / 1000, 3)} ms/keystroke (#{ok}/23 patched)"
)
