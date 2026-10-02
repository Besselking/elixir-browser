# End-to-end input latency: key, mouse-motion and wheel events through the real
# Browser.Session (event handling, relayout, publish) and, optionally, a synchronous paint.
#
#   xvfb-run -a mix run bench/input_latency.exs            # prints a table
#   N=300 PAINT=0 xvfb-run -a mix run bench/input_latency.exs
#
# Uses only a generated local page (no network, no saved fixtures), so the same file runs
# unchanged on any commit. Needs a display (Xvfb) and wx.
require Browser.UI
import Browser.UI, only: [wx: 1, wxMouse: 1, wxKey: 1]

n = String.to_integer(System.get_env("N", "200"))
paint? = System.get_env("PAINT", "1") != "0"
paras = String.to_integer(System.get_env("PARAS", "120"))

# -- fixture: search-like page: a fixed-width field, a field in a flex row, an auto-width field, many links ----------
results =
  for i <- 1..paras do
    """
    <div class="r"><h2><a href="https://example.com/#{i}">Result #{i} about the Elixir language and its tooling</a></h2>
    <p>Lorem ipsum dolor sit amet <b>consectetur</b> adipiscing elit, sed do eiusmod tempor incididunt ut labore
    et dolore magna aliqua. Ut enim ad minim veniam, quis nostrud exercitation ullamco laboris #{i}.</p></div>
    """
  end

html = """
<html><head><title>bench</title><style>
body{margin:8px;font-family:sans-serif} .r{margin:12px 0;padding:6px;border:1px solid #ddd}
input{border:1px solid #888;background:#fff;padding:2px 4px} #q{width:400px} #fx{width:300px} #fl{display:flex;gap:8px}
</style></head><body>
<form id="plain">Search: <input id="q" name="q" type="text"> <input type="submit" value="Go"></form>
<form id="fl"><input id="fx" name="x" type="text"><input type="submit" value="Go"></form>
<form id="auto"><input id="free" name="f" type="text"></form>
#{results}
</body></html>
"""

path = Path.join(System.tmp_dir!(), "elixir_browser_bench_#{System.unique_integer([:positive])}.html")
File.write!(path, html)
session = Process.whereis(Browser.Session) || raise "Browser.Session not running (config :gui?)"

# a sync barrier: returns once the session has handled everything sent before
barrier = fn -> :ok = :sys.suspend(session); :ok = :sys.resume(session) end
state = fn -> :sys.get_state(session) end

Browser.Session.navigate("file://" <> path)
Enum.reduce_while(1..200, nil, fn _, _ ->
  Process.sleep(50)
  if (s = state.()) && s.url && String.ends_with?(s.url, Path.basename(path)) && s.items != [],
    do: {:halt, :ok}, else: {:cont, nil}
end)
Process.sleep(500) # let images/layout timers settle

ui = state.().ui
# wx calls from this process need the session's wx environment
me = self()
:sys.replace_state(session, fn s -> send(me, {:wx_env, :wx.get_env()}); s end)
receive do {:wx_env, env} -> :wx.set_env(env) end
paint = fn -> if paint?, do: :wxWindow.update(ui.panel) end

send_ev = fn ev -> send(session, wx(event: ev)); barrier.(); paint.() end
key = fn cp -> send_ev.(wxKey(type: :char, keyCode: cp, uniChar: cp, controlDown: false, metaDown: false, shiftDown: false, altDown: false)) end
# hover never invalidates the panel, so no paint here: a paint left pending by the previous
# event would otherwise make the next blocking wx call (setCursor) wait behind it and look slow
motion = fn x, y -> send(session, wx(event: wxMouse(type: :motion, x: x, y: y))); barrier.() end
wheel = fn rot -> send_ev.(wxMouse(type: :mousewheel, wheelRotation: rot, wheelDelta: 120, linesPerAction: 3)) end
click = fn x, y -> send_ev.(wxMouse(type: :left_down, x: x, y: y)) end

# focus a field by clicking its box
focus = fn cid ->
  s = state.()
  box = Browser.Layout.controls(s.items) |> Map.fetch!(cid)
  click.(box.x + div(box.w, 2), box.y - s.scroll + div(box.h, 2))
  s = state.()
  s.focus == cid || raise "failed to focus control #{cid} (focus=#{inspect(s.focus)}, box=#{inspect(box)}, scroll=#{s.scroll}, hit=#{inspect(Browser.UI.control_at(s.controls, box.x + div(box.w, 2), box.y + div(box.h, 2)))})"
end

stats = fn label, samples ->
  sorted = Enum.sort(samples)
  mean = Enum.sum(sorted) / length(sorted)
  pick = fn p -> Enum.at(sorted, min(length(sorted) - 1, trunc(length(sorted) * p))) end
  IO.puts(:io_lib.format("~-34s mean ~7.3f ms  p50 ~7.3f  p95 ~7.3f  max ~7.3f  (n=~b)",
    [label, mean, pick.(0.5), pick.(0.95), Enum.max(sorted), length(sorted)]))
end

time = fn fun -> {us, _} = :timer.tc(fun); us / 1000 end

controls = state.().controls
text_cids = state.().page.forms.controls |> Enum.filter(fn {_, c} -> Browser.Forms.editable?(c) end) |> Enum.map(&elem(&1, 0)) |> Enum.sort()
[fixed_cid, flex_cid, auto_cid | _] = text_cids
_ = controls

IO.puts("page: #{length(state.().items)} items, #{state.().height}px tall, paint=#{paint?}, #{:erlang.system_info(:schedulers_online)} schedulers")

chars = ~c"elixir language tutorial and some more text " |> Stream.cycle() |> Enum.take(n)

# warm up everything (measure cache, JIT) before sampling
focus.(fixed_cid); for c <- Enum.take(chars, 20), do: key.(c); for _ <- 1..20, do: key.(8)

for {label, cid} <- [{"type, fixed-width field", fixed_cid}, {"type, field in flex row", flex_cid}, {"type, auto-width field", auto_cid}] do
  focus.(cid)
  stats.(label, for(c <- chars, do: time.(fn -> key.(c) end)))
  stats.(String.replace(label, "type", "backspace"), for(_ <- chars, do: time.(fn -> key.(8) end)))
end

focus.(fixed_cid)
# a first-time (cold measure cache) keystroke with fresh text
cold = time.(fn -> key.(?é) end)
IO.puts("cold-glyph keystroke               #{Float.round(cold, 3)} ms")

h = Browser.UI.client_height(ui)
w = Browser.UI.client_width(ui)
pts = for i <- 0..(n - 1), do: {rem(i * 37, max(w, 1)), rem(i * 11, max(h, 1))}
stats.("mouse motion (diagonal sweep)", for({x, y} <- pts, do: time.(fn -> motion.(x, y) end)))
stats.("mouse wheel (down then up)", for(i <- 1..n, do: time.(fn -> wheel.(if rem(i, 20) < 10, do: -120, else: 120) end)))

# a trackpad flick: 30 small precise events arrive back to back, then the window paints once
precise = fn rot -> send(session, wx(event: wxMouse(type: :mousewheel, wheelRotation: rot, wheelDelta: 10, linesPerAction: 1))) end
burst = fn ->
  for _ <- 1..30, do: precise.(-3)
  barrier.()
  paint.()
end
stats.("wheel flick (30 events, 1 paint)", for(_ <- 1..max(div(n, 10), 5), do: time.(burst)))

File.rm(path)
System.halt(0)
