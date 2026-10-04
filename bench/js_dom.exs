# Usage: mix run --no-start bench/js_dom.exs
# A script that loops over a few hundred elements reading and writing attributes, classes, text and
# styles, then builds a list: the cost of the DOM bindings, with the time the script measured itself.
alias Browser.JS.Runtime
items = Enum.map_join(1..600, fn i -> "<li class=\"item c#{rem(i, 7)}\" data-n=\"#{i}\"><a href=\"/p/#{i}\">Item #{i}</a><span>#{i}</span></li>" end)
script = """
var t0 = performance.now();
var lis = document.querySelectorAll('li.item');
var total = 0;
for (var round = 0; round < 5; round++) {
  for (var i = 0; i < lis.length; i++) {
    var li = lis[i];
    total += parseInt(li.getAttribute('data-n'), 10);
    li.classList.toggle('on', i % 2 == 0);
    li.querySelector('span').textContent = String(i * round);
    li.style.color = i % 3 ? 'red' : 'blue';
  }
}
var out = document.createElement('ul');
for (var i = 0; i < 300; i++) { var e = document.createElement('li'); e.textContent = 'n' + i; out.appendChild(e) }
document.body.appendChild(out);
console.log(total, Math.round(performance.now() - t0) + ' ms');
"""
html = "<html><body><ul>#{items}</ul><script>#{script}</script></body></html>"
{raw, _} = html |> Browser.HTML.parse() |> Browser.Forms.index()
t_boot = System.monotonic_time(:millisecond)
pid = Runtime.start(raw, %{url: "http://t.test/", width: 800, height: 600, fetch: fn _ -> {:error, "no"} end})
reply = Runtime.run_scripts(pid)
IO.puts("boot + scripts: #{System.monotonic_time(:millisecond) - t_boot} ms")
IO.puts("script: " <> inspect(for({:log, t} <- reply.console, do: t)))
Runtime.stop(pid)
