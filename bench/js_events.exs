# Usage: mix run --no-start bench/js_events.exs
# Event handling through Browser.JS.Runtime: listeners added by a script and fired from the page
# side (clicks/inputs/keys via Runtime.dispatch, as the session does) and from script
# (dispatchEvent, bubbling through a deep tree, timers, innerHTML rewrites, querySelector).
alias Browser.JS.Runtime
Application.put_env(:browser, :gui, false)
{:ok, _} = Application.ensure_all_started(:browser)

rows =
  Enum.map_join(1..200, fn i ->
    "<li class=\"row\" id=\"r#{i}\"><button class=\"b\">go #{i}</button><span>#{i}</span></li>"
  end)

script = """
var count = 0, last = '';
document.getElementById('f').addEventListener('input', function (e) { count++; last = e.target.value });
document.getElementById('f').addEventListener('keydown', function (e) { count++ });
document.getElementById('form').addEventListener('submit', function (e) { e.preventDefault(); count++ });
document.querySelectorAll('.b').forEach(function (b) { b.addEventListener('click', function (e) { count++; e.stopPropagation() }) });
var list = document.getElementById('list');
list.addEventListener('click', function () { count += 100 });
window.bubble = function (n) {
  var inner = document.getElementById('deep'); var c = 0;
  document.body.addEventListener('ping', function () { c++ });
  for (var i = 0; i < n; i++) inner.dispatchEvent(new CustomEvent('ping', {bubbles: true}));
  return c;
};
window.dom = function (n) {
  var t = 0;
  for (var i = 0; i < n; i++) { list.innerHTML = '<li class="x">' + i + '</li><li>b</li>'; t += list.querySelectorAll('li').length; t += document.querySelector('#list > li.x').textContent.length }
  return t;
};
window.timers = function (n) { var c = 0; for (var i = 0; i < n; i++) setTimeout(function () { c++ }, 0); return function () { return c } };
"""

page = fn extra ->
  "<html><body><form id=\"form\"><input id=\"f\" name=\"f\"></form><ul id=\"list\">#{rows}</ul>" <>
    "<div><div><div><div><div><div><div id=\"deep\"></div></div></div></div></div></div></div>" <>
    "<script>#{script}#{extra}</script></body></html>"
end

html = page.("")

{raw, _} = html |> Browser.HTML.parse() |> Browser.Forms.index()

pid =
  Runtime.start(raw, %{
    url: "http://t.test/",
    width: 800,
    height: 600,
    fetch: fn _ -> {:error, "no"} end
  })

boot = Runtime.run_scripts(pid)
boot[:crashed] && raise "runtime crashed: #{inspect(boot.crashed)}"
for {:error, t} <- boot.console, do: IO.puts("  script error: " <> String.slice(t, 0, 150))

time = fn name, n, fun ->
  fun.()
  {us, _} = :timer.tc(fn -> for _ <- 1..n, do: fun.() end)

  IO.puts(
    String.pad_trailing(name, 36) <>
      String.pad_leading("#{Float.round(us / n / 1000, 3)} ms", 12) <> "  per call (n=#{n})"
  )
end

# controls: cid 0 is the input
ctl = fn v -> %{0 => %{value: v, checked: false, selected: []}} end

time.("dispatch input (1 listener)", 300, fn ->
  Runtime.dispatch(pid, {:control, 0}, "input", %{}, ctl.("hello"))
end)

time.("dispatch keydown", 300, fn ->
  Runtime.dispatch(pid, {:control, 0}, "keydown", %{"key" => "a", "keyCode" => 65}, ctl.("hello"))
end)

time.("dispatch submit (preventDefault)", 200, fn ->
  Runtime.dispatch(pid, {:form, 0}, "submit")
end)

time.("dispatch document click", 200, fn -> Runtime.dispatch(pid, :document, "click") end)

# Calls to window functions go through a one-off script element handled by `eval` in the page.
run = fn src ->
  {raw2, _} = page.("var __r = #{src};") |> Browser.HTML.parse() |> Browser.Forms.index()

  p2 =
    Runtime.start(raw2, %{
      url: "http://t.test/",
      width: 800,
      height: 600,
      fetch: fn _ -> {:error, "no"} end
    })

  {us, reply} = :timer.tc(fn -> Runtime.run_scripts(p2) end)
  {us2, reply2} = :timer.tc(fn -> Runtime.flush(p2) end)
  Runtime.stop(p2)
  reply[:crashed] && raise "runtime crashed: #{inspect(reply.crashed)}"

  for {:error, t} <- reply.console ++ reply2.console,
      do: IO.puts("  script error: " <> String.slice(t, 0, 150))

  (us + us2) / 1000
end

IO.puts(
  String.pad_trailing("boot (parse + listeners, 200 rows)", 36) <>
    String.pad_leading("#{Float.round(run.("0"), 1)} ms", 12)
)

IO.puts(
  String.pad_trailing("bubble 200 events, 7 deep", 36) <>
    String.pad_leading("#{Float.round(run.("bubble(200)") - run.("0"), 1)} ms", 12)
)

IO.puts(
  String.pad_trailing("50 innerHTML rewrites + 2 queries", 36) <>
    String.pad_leading("#{Float.round(run.("dom(50)") - run.("0"), 1)} ms", 12)
)

IO.puts(
  String.pad_trailing("1000 timers + flush", 36) <>
    String.pad_leading("#{Float.round(run.("timers(1000)()") - run.("0"), 1)} ms", 12)
)

Runtime.stop(pid)
