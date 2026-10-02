# Page load with and without stylesheet prefetch, against a local server that sends the
# HTML slowly (as a slow connection would) and answers each stylesheet after a delay.
#
#   xvfb-run -a mix run bench/stylesheet_prefetch.exs
#   SHEETS=6 SHEET_MS=150 CHUNKS=6 CHUNK_MS=100 xvfb-run -a mix run bench/stylesheet_prefetch.exs
alias Browser.{Fetch, Page}

sheets = String.to_integer(System.get_env("SHEETS", "4"))
sheet_ms = String.to_integer(System.get_env("SHEET_MS", "150"))
chunks = String.to_integer(System.get_env("CHUNKS", "5"))
chunk_ms = String.to_integer(System.get_env("CHUNK_MS", "100"))
runs = String.to_integer(System.get_env("N", "5"))

{:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, packet: :http_bin])
{:ok, port} = :inet.port(listen)

serve = fn serve, listen ->
  {:ok, sock} = :gen_tcp.accept(listen)

  spawn(fn ->
    {:ok, {:http_request, _, {:abs_path, path}, _}} = :gen_tcp.recv(sock, 0)
    :inet.setopts(sock, packet: :httpkind) |> then(fn _ -> :ok end)

    send_ok = fn body, extra ->
      :gen_tcp.send(
        sock,
        "HTTP/1.1 200 OK\r\ncontent-type: text/html\r\nconnection: close\r\ncache-control: no-store\r\n#{extra}\r\n"
      )

      body
    end

    if String.starts_with?(path, "/sheet") do
      Process.sleep(sheet_ms)
      css = "p { color: red } .x#{:erlang.phash2(path)} { margin: 1px }"

      :gen_tcp.send(
        sock,
        "HTTP/1.1 200 OK\r\ncontent-type: text/css\r\ncache-control: no-store\r\ncontent-length: #{byte_size(css)}\r\nconnection: close\r\n\r\n#{css}"
      )
    else
      links =
        for i <- 1..sheets,
            into: "",
            do: ~s|<link rel="stylesheet" href="/sheet#{i}.css?#{path}">\n|

      head = "<html><head><title>t</title>\n#{links}</head><body>\n"
      send_ok.(nil, "transfer-encoding: chunked\r\n")

      chunk = fn data ->
        :gen_tcp.send(sock, "#{Integer.to_string(byte_size(data), 16)}\r\n#{data}\r\n")
      end

      chunk.(head)

      for i <- 1..chunks do
        Process.sleep(chunk_ms)
        chunk.("<p>paragraph #{i}</p>\n")
      end

      chunk.("</body></html>")
      :gen_tcp.send(sock, "0\r\n\r\n")
    end

    :gen_tcp.close(sock)
  end)

  serve.(serve, listen)
end

spawn(fn -> serve.(serve, listen) end)

time = fn f ->
  {us, _} = :timer.tc(f)
  us / 1000
end

without = fn url ->
  {:ok, body, final} = Fetch.load(url)
  Page.build(Page.document(body, final), final)
end

with_prefetch = fn url -> {:ok, _} = Page.load(url) end

median = fn xs -> xs |> Enum.sort() |> Enum.at(div(length(xs), 2)) end

for {name, f} <- [{"sequential (before)", without}, {"prefetch (after)", with_prefetch}] do
  ms =
    for i <- 1..runs,
        do: time.(fn -> f.("http://127.0.0.1:#{port}/page-#{String.first(name)}#{i}") end)

  IO.puts(
    "#{String.pad_trailing(name, 22)} median #{Float.round(median.(ms), 1)} ms  runs #{inspect(Enum.map(ms, &round/1))}"
  )
end
