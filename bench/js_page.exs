# Usage: mix run --no-start bench/js_page.exs [URL]
# Loads a real page headlessly, runs its scripts and timers in the JS runtime and reports the time
# and the size of the script process (needs network).
alias Browser.{Fetch, Page}
alias Browser.JS.Runtime

url = List.first(System.argv()) || "https://elixir-lang.org/"
Application.put_env(:browser, :gui, false)
{:ok, _} = Application.ensure_all_started(:browser)

{:ok, page} = Page.load(url)

info = %{
  url: page.url,
  base: page.base || page.url,
  width: 1000,
  height: 800,
  fetch: &Fetch.load/1
}

t0 = System.monotonic_time(:millisecond)
pid = Runtime.start(page.raw, info)
reply = Runtime.run_scripts(pid)
t1 = System.monotonic_time(:millisecond)

mem = fn -> div(Process.info(pid, :memory) |> elem(1), 1_000_000) end
IO.puts("scripts ran in #{t1 - t0} ms, script process #{mem.()} MB, console #{length(reply.console)} lines")

for {level, text} <- reply.console, do: IO.puts("  console #{level}: #{String.slice(text, 0, 200)}")

# real-time timers keep running in the process: let the page idle and watch it
for sec <- [5, 10, 20] do
  Process.sleep(if sec == 5, do: 5_000, else: 5_000)
  IO.puts("after #{sec} s idle: process #{mem.()} MB")
end

for round <- 1..5 do
  t = System.monotonic_time(:millisecond)
  Runtime.flush(pid)
  IO.puts("flush #{round}: #{System.monotonic_time(:millisecond) - t} ms, process #{mem.()} MB")
end

snap = Runtime.snapshot(pid)
dump = inspect(snap.raw, limit: :infinity, printable_limit: :infinity)
IO.puts("astro islands still unhydrated (ssr attribute): #{length(Regex.scan(~r/"ssr"/, dump))}, DOM dump #{div(byte_size(dump), 1000)} KB")
Runtime.stop(pid)
