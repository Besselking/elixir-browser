defmodule Browser.PrefetchTest do
  use ExUnit.Case, async: true

  alias Browser.{Fetch, Page, Prefetch}

  # serves `routes` ("/path" => {content_type, body}) and the hits it saw, in order
  defp serve(routes) do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)
    test = self()

    spawn_link(fn -> accept(listen, routes, test) end)
    "http://127.0.0.1:#{port}"
  end

  defp accept(listen, routes, test) do
    {:ok, sock} = :gen_tcp.accept(listen)

    spawn(fn ->
      {:ok, req} = :gen_tcp.recv(sock, 0)
      [_, path] = Regex.run(~r{^GET (\S+)}, req)
      send(test, {:hit, path})

      case routes[path] do
        {type, chunks} ->
          :gen_tcp.send(
            sock,
            "HTTP/1.1 200 OK\r\ncontent-type: #{type}\r\ncache-control: no-store\r\ntransfer-encoding: chunked\r\nconnection: close\r\n\r\n"
          )

          for chunk <- List.wrap(chunks) do
            :gen_tcp.send(sock, "#{Integer.to_string(byte_size(chunk), 16)}\r\n#{chunk}\r\n")
            Process.sleep(50)
          end

          :gen_tcp.send(sock, "0\r\n\r\n")

        nil ->
          :gen_tcp.send(
            sock,
            "HTTP/1.1 404 Not Found\r\ncontent-length: 0\r\nconnection: close\r\n\r\n"
          )
      end

      :gen_tcp.close(sock)
    end)

    accept(listen, routes, test)
  end

  defp feed(chunks, base \\ "http://x.test/") do
    Prefetch.reset()
    Enum.each(chunks, &Prefetch.feed(&1, base, fn _ -> true end))
    Process.get({Prefetch, :state}).started |> MapSet.to_list() |> Enum.sort()
  end

  test "finds stylesheet links, also when a tag is split between pieces" do
    assert feed([
             "<html><head><link rel=stylesheet hre",
             "f=/a.css><link rel=\"stylesheet\" href=\"b.css\">"
           ]) ==
             ["http://x.test/a.css", "http://x.test/b.css"]
  end

  test "ignores other links, alternate and print sheets, and repeats" do
    assert feed([
             ~s|<link rel="icon" href="/i.png"><link rel="alternate stylesheet" href="/alt.css">|,
             ~s|<link rel="stylesheet" media="print" href="/p.css"><link rel=stylesheet href=/a.css>|,
             ~s|<link rel=stylesheet href=/a.css>|
           ]) == ["http://x.test/a.css"]
  end

  test "a page's stylesheet is requested before its HTML has finished arriving" do
    base =
      serve(%{
        "/" =>
          {"text/html",
           [
             "<html><head><link rel=stylesheet href=/s.css></head>",
             "<body><p>hi</p>",
             "</body></html>"
           ]},
        "/s.css" => {"text/css", "p { color: red }"}
      })

    assert {:ok, page} = Page.load(base <> "/")
    assert_receive {:hit, "/"}
    assert_receive {:hit, "/s.css"}
    refute_receive {:hit, "/s.css"}, 100
    assert Enum.any?(page.rules, &(&1.origin == :author))
  end

  test "chunks reach on_chunk while the body is still arriving" do
    base = serve(%{"/" => {"text/html", ["one", "two", "three"]}})
    me = self()

    assert {:ok, "onetwothree", _} =
             Fetch.load(base <> "/", on_chunk: fn chunk, _url -> send(me, {:chunk, chunk}) end)

    assert_received {:chunk, _}
  end
end
