defmodule Browser.NetLogTest do
  use ExUnit.Case, async: true
  alias Browser.{Fetch, NetLog, NetworkWindow}

  # answers each connection with the next canned response
  defp serve(responses) do
    {:ok, listen} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(listen)

    spawn_link(fn ->
      for response <- responses do
        {:ok, sock} = :gen_tcp.accept(listen, 5_000)
        {:ok, _head} = :gen_tcp.recv(sock, 0, 5_000)
        :gen_tcp.send(sock, response)
        :gen_tcp.close(sock)
      end

      :gen_tcp.close(listen)
    end)

    "http://127.0.0.1:#{port}"
  end

  defp response(status, headers, body) do
    head =
      Enum.map_join(headers ++ [{"Content-Length", byte_size(body)}], "", fn {k, v} ->
        "#{k}: #{v}\r\n"
      end)

    "HTTP/1.1 #{status} Reason\r\n#{head}Connection: close\r\n\r\n#{body}"
  end

  defp entries(base), do: Enum.filter(NetLog.since(0), &String.starts_with?(&1.url, base))

  test "every request is logged with its status, type, size and headers" do
    base =
      serve([
        response(302, [{"Location", "/page"}], ""),
        response(
          200,
          [{"Content-Type", "text/html"}, {"Cache-Control", "max-age=60"}],
          "<p>hi</p>"
        ),
        response(200, [{"Content-Type", "text/css"}], "p{}"),
        response(404, [], "no")
      ])

    assert {:ok, _, _} = Fetch.load(base <> "/start", navigation: true)
    # a fresh copy is not asked for again
    assert {:ok, _, _} = Fetch.load(base <> "/page", initiator: "http://t.test/")
    assert {:ok, _, _} = Fetch.load(base <> "/s.css", initiator: "http://t.test/")
    assert {:error, _} = Fetch.load(base <> "/gone")

    assert [redirect, page, cached, css, gone] = entries(base)
    assert %{status: 302, method: "GET", type: "document", source: :network} = redirect
    assert {"location", "/page"} in redirect.response_headers
    assert {"user-agent", _} = List.keyfind(redirect.request_headers, "user-agent", 0)
    assert redirect.initiator == nil

    assert %{status: 200, type: "document", size: 9, source: :network} = page
    assert {"content-type", "text/html"} in page.response_headers

    assert %{status: 200, type: "html", source: :cache, initiator: "http://t.test/"} = cached
    assert cached.url == base <> "/page"
    assert %{status: 200, type: "css", size: 3} = css
    assert %{status: 404, source: :network} = gone

    assert NetworkWindow.row(page) |> Enum.take(4) == ["200", "GET", "document", "9 B"]
    assert NetworkWindow.row(cached) |> Enum.take(4) == ["200 (cache)", "GET", "html", "(cache)"]
    assert NetworkWindow.details_text(page) =~ "Status: 200 Reason (from the network)"
    assert NetworkWindow.details_text(page) =~ "  content-type: text/html"
    assert NetworkWindow.details_text(cached) =~ "from the cache"
  end

  test "a failed request is logged with its error" do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(listen)
    :gen_tcp.close(listen)
    base = "http://127.0.0.1:#{port}"
    assert {:error, _} = Fetch.load(base <> "/x")
    assert [%{status: nil, source: :error, error: error} = entry] = entries(base)
    assert is_binary(error)
    assert NetworkWindow.row(entry) |> hd() == "(failed)"
    assert NetworkWindow.details_text(entry) =~ "Failed: "
  end

  test "the log is numbered, kept to the newest entries, and cleared" do
    seq = NetLog.last_seq()
    a = NetLog.add(%{url: "http://numbered.test/a"})
    b = NetLog.add(%{url: "http://numbered.test/b"})
    assert b > a and a > seq
    assert NetLog.get(a).url == "http://numbered.test/a"
    assert Enum.map(NetLog.since(a), & &1.seq) |> Enum.member?(b)
    refute Enum.map(NetLog.since(a), & &1.seq) |> Enum.member?(a)
  end

  test "request types come from the content type or the file name" do
    assert NetLog.type(:document, [], "http://t.test/") == "document"
    assert NetLog.type(:fetch, [{"content-type", "text/html"}], "http://t.test/") == "fetch"

    assert NetLog.type(
             :resource,
             [{"content-type", "text/javascript; charset=utf-8"}],
             "http://t.test/x"
           ) == "script"

    assert NetLog.type(:resource, [], "http://t.test/a/b.PNG?x=1") == "image"

    assert NetLog.type(:resource, [{"content-type", "application/json"}], "http://t.test/x") ==
             "json"

    assert NetLog.type(:resource, [], "http://t.test/x") == "other"
  end

  test "the filter matches part of the address in any case" do
    entry = %{url: "http://T.test/App.js"}
    assert NetworkWindow.match?(entry, "")
    assert NetworkWindow.match?(entry, "app.JS")
    refute NetworkWindow.match?(entry, "css")
    assert NetworkWindow.size_text(512) == "512 B"
    assert NetworkWindow.size_text(4608) == "4.5 KB"
  end
end
