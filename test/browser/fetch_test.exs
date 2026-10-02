defmodule Browser.FetchTest do
  use ExUnit.Case, async: true
  alias Browser.Fetch

  # A one-shot HTTP server: answers each connection with the next canned response and
  # reports every request to the test process as {:request, method, path, headers, body}.
  defp serve(responses) do
    test = self()

    {:ok, listen} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(listen)

    spawn_link(fn ->
      for response <- responses do
        {:ok, sock} = :gen_tcp.accept(listen, 5_000)
        send(test, request(sock))
        :gen_tcp.send(sock, response)
        :gen_tcp.close(sock)
      end

      :gen_tcp.close(listen)
    end)

    "http://127.0.0.1:#{port}"
  end

  defp request(sock), do: read_head(sock, "")

  defp read_head(sock, acc) do
    case String.split(acc, "\r\n\r\n", parts: 2) do
      [head, rest] ->
        [line | header_lines] = String.split(head, "\r\n")
        [method, path | _] = String.split(line, " ")

        headers =
          Map.new(header_lines, fn l ->
            [k, v] = String.split(l, ": ", parts: 2)
            {String.downcase(k), v}
          end)

        len = headers |> Map.get("content-length", "0") |> String.to_integer()
        {:request, method, path, headers, read_body(sock, rest, len)}

      _ ->
        {:ok, more} = :gen_tcp.recv(sock, 0, 5_000)
        read_head(sock, acc <> more)
    end
  end

  defp read_body(_sock, body, len) when byte_size(body) >= len, do: binary_part(body, 0, len)

  defp read_body(sock, body, len) do
    {:ok, more} = :gen_tcp.recv(sock, 0, 5_000)
    read_body(sock, body <> more, len)
  end

  defp ok(body),
    do:
      "HTTP/1.1 200 OK\r\nContent-Length: #{byte_size(body)}\r\nConnection: close\r\n\r\n#{body}"

  defp redirect(status, location),
    do:
      "HTTP/1.1 #{status} Redirect\r\nLocation: #{location}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"

  test "a plain GET" do
    base = serve([ok("hello")])
    assert {:ok, "hello", url} = Fetch.load(base <> "/x?a=1")
    assert url == base <> "/x?a=1"
    assert_receive {:request, "GET", "/x?a=1", %{"user-agent" => "ElixirBrowser/0.1"}, ""}
  end

  test "asks for gzip and unpacks it" do
    body = :zlib.gzip(String.duplicate("squeeze me ", 50))

    base =
      serve([
        "HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\nContent-Length: #{byte_size(body)}\r\nConnection: close\r\n\r\n" <>
          body
      ])

    assert {:ok, text, _} = Fetch.load(base <> "/z")
    assert text == String.duplicate("squeeze me ", 50)
    assert_receive {:request, "GET", "/z", %{"accept-encoding" => "gzip"}, ""}
  end

  test "POST sends the body as a urlencoded form" do
    base = serve([ok("posted")])
    assert {:ok, "posted", _} = Fetch.load(base <> "/submit", method: :post, body: "a=1&b=x+y")

    assert_receive {:request, "POST", "/submit", headers, "a=1&b=x+y"}
    assert headers["content-type"] == "application/x-www-form-urlencoded"
    assert headers["content-length"] == "9"
  end

  test "a 302 or 303 after a POST is followed with a GET and no body" do
    for status <- [302, 303] do
      base = serve([redirect(status, "/done"), ok("landed")])
      assert {:ok, "landed", url} = Fetch.load(base <> "/p", method: :post, body: "x=1")
      assert url == base <> "/done"
      assert_receive {:request, "POST", "/p", _, "x=1"}
      assert_receive {:request, "GET", "/done", _, ""}
    end
  end

  test "a 307 repeats the POST with its body" do
    base = serve([redirect(307, "/again"), ok("again")])
    assert {:ok, "again", _} = Fetch.load(base <> "/p", method: :post, body: "x=1")
    assert_receive {:request, "POST", "/p", _, "x=1"}
    assert_receive {:request, "POST", "/again", _, "x=1"}
  end

  test "HTTP errors and refused connections are reported" do
    base = serve(["HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"])
    assert {:error, "HTTP 404 Not Found"} = Fetch.load(base <> "/missing")
    assert {:error, "Request failed:" <> _} = Fetch.load("http://127.0.0.1:1/")
  end

  test "local files and about pages ignore the method" do
    assert {:ok, _, "about:home"} = Fetch.load("about:home", method: :post, body: "x")
    path = Path.join(System.tmp_dir!(), "fetch_test_#{System.unique_integer([:positive])}.html")
    File.write!(path, "<p>hi</p>")
    assert {:ok, "<p>hi</p>", _} = Fetch.load("file://" <> path, method: :post)
    File.rm!(path)
  end

  describe "the start page" do
    test "links to demo pages that exist" do
      {:ok, html, "about:home"} = Fetch.load("about:home")

      links =
        Regex.scan(~r/href="(file:\/\/[^"]+)"/, html, capture: :all_but_first) |> List.flatten()

      assert length(links) >= 10

      for "file://" <> path <- links do
        assert File.exists?(URI.decode(path)), "#{path} is missing"
      end
    end
  end
end
