# What a picture that arrives after the first layout costs: the time from the picture's
# arrival until the session is idle again (no layout job, no pending image-layout timer),
# for pictures with a declared width and height (their box does not depend on the file)
# and without (the page has to move around them).
#
#   xvfb-run -a mix run bench/image_relayout.exs
#   N=20 PARAS=300 xvfb-run -a mix run bench/image_relayout.exs
#
# Uses a generated local page and generated PNGs (no network, no fixtures).
n = String.to_integer(System.get_env("N", "10"))
paras = String.to_integer(System.get_env("PARAS", "150"))

png = fn w, h ->
  chunk = fn type, data ->
    body = type <> data
    <<byte_size(data)::32, body::binary, :erlang.crc32(body)::32>>
  end

  row = <<0>> <> :binary.copy(<<200, 100, 50>>, w)
  raw = :binary.copy(row, h)

  <<0x89, "PNG\r\n", 0x1A, 0x0A>> <>
    chunk.("IHDR", <<w::32, h::32, 8, 2, 0, 0, 0>>) <>
    chunk.("IDAT", :zlib.compress(raw)) <> chunk.("IEND", "")
end

dir = Path.join(System.tmp_dir!(), "elixir_browser_img_bench_#{System.unique_integer([:positive])}")
File.mkdir_p!(dir)
File.write!(Path.join(dir, "pic.png"), png.(120, 80))
File.write!(Path.join(dir, "late.png"), png.(60, 40))

body =
  for i <- 1..paras do
    img =
      cond do
        rem(i, 10) == 0 -> ~s(<img src="pic.png?#{i}" width="120" height="80" alt="">)
        rem(i, 10) == 5 -> ~s(<img src="pic.png?#{i}" style="max-width:100%" alt="">)
        true -> ""
      end

    """
    <div class="r"><h2><a href="https://example.com/#{i}">Result #{i} about the Elixir language</a></h2>
    <p>Lorem ipsum dolor sit amet <b>consectetur</b> adipiscing elit, sed do eiusmod tempor incididunt ut labore
    et dolore magna aliqua. Ut enim ad minim veniam, quis nostrud exercitation ullamco laboris #{i}.</p>#{img}</div>
    """
  end

html = """
<html><head><title>bench</title><style>
body{margin:8px;font-family:sans-serif} .r{margin:12px 0;padding:6px;border:1px solid #ddd}
</style></head><body>#{body}
<img id="sized" src="late.png?sized" width="60" height="40" alt="">
<img id="free" src="late.png?free" alt="">
</body></html>
"""

path = Path.join(dir, "page.html")
File.write!(path, html)
session = Process.whereis(Browser.Session) || raise "Browser.Session not running (config :gui?)"
state = fn -> :sys.get_state(session) end

Browser.Session.navigate("file://" <> path)

idle? = fn s -> s.layout_job == nil and s.layout_timer == nil end

Enum.reduce_while(1..400, nil, fn _, _ ->
  Process.sleep(50)
  s = state.()
  if s.url && String.ends_with?(s.url, "page.html") && s.items != [] && idle?.(s) &&
       map_size(s.images) > 0,
     do: {:halt, :ok}, else: {:cont, nil}
end)

Process.sleep(500)
IO.puts("page: #{length(state.().items)} items, #{state.().height}px tall, #{map_size(state.().images)} images")

late = File.read!(Path.join(dir, "late.png"))

# the picture "arrives again": forget it, then deliver it, and wait for the session to settle
arrive = fn tag ->
  url = "file://" <> URI.encode(Path.join(dir, "late.png")) <> "?" <> tag
  s = :sys.replace_state(session, fn s -> %{s | images: Map.delete(s.images, url)} end)
  before = s.items
  t0 = System.monotonic_time(:microsecond)
  send(session, {:image, s.nonce, url, {:ok, late, :png}})

  Enum.reduce_while(1..2000, nil, fn _, _ ->
    s = state.()
    if idle?.(s), do: {:halt, s}, else: (Process.sleep(1); {:cont, nil})
  end)
  |> then(fn s ->
    {(System.monotonic_time(:microsecond) - t0) / 1000, s.items === before}
  end)
end

for {label, tag} <- [{"declared width+height", "sized"}, {"no declared size", "free"}] do
  arrive.(tag)
  runs = for _ <- 1..n, do: arrive.(tag)
  ms = Enum.map(runs, &elem(&1, 0))
  same = Enum.count(runs, &elem(&1, 1))
  mean = Enum.sum(ms) / n
  IO.puts(:io_lib.format("~-24s mean ~8.2f ms  min ~8.2f  max ~8.2f  items unchanged ~b/~b",
    [label, mean, Enum.min(ms), Enum.max(ms), same, n]))
end

File.rm_rf(dir)
System.halt(0)
