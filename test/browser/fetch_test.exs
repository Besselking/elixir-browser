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
    assert_receive {:request, "GET", "/x?a=1", %{"user-agent" => ua}, ""}
    assert ua == Fetch.user_agent()
    assert ua =~ "Mozilla/5.0" and ua =~ "ElixirBrowser"
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

  describe "cookies" do
    test "Set-Cookie on a redirect is sent on the next request and later ones" do
      Browser.Cookies.clear()

      base =
        serve([
          "HTTP/1.1 302 Found\r\nLocation: /next\r\nSet-Cookie: a=1\r\nSet-Cookie: b=2; Path=/\r\nContent-Length: 0\r\n\r\n",
          "HTTP/1.1 200 OK\r\nSet-Cookie: c=3\r\nContent-Length: 2\r\n\r\nok",
          "HTTP/1.1 200 OK\r\nCache-Control: no-store\r\nContent-Length: 2\r\n\r\nok"
        ])

      assert {:ok, "ok", _} = Fetch.load(base <> "/start")
      assert_receive {:request, "GET", "/start", h1, _}
      refute Map.has_key?(h1, "cookie")
      assert_receive {:request, "GET", "/next", %{"cookie" => "a=1; b=2"}, _}

      assert {:ok, "ok", _} = Fetch.load(base <> "/more", cache: :reload)
      assert_receive {:request, "GET", "/more", %{"cookie" => cookie}, _}
      assert cookie == "a=1; b=2; c=3"
    end
  end

  describe "SameSite" do
    test "a cookie is held back from a cross-site subresource, and from a cross-site POST" do
      Browser.Cookies.clear()
      base = serve(["HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok"])
      Browser.Cookies.store(base <> "/", ["lax=1", "none=2; SameSite=None; Secure"], [])
      # Secure needs https, so only the Lax one exists
      assert Enum.map(Browser.Cookies.all(), & &1.name) == ["lax"]

      assert {:ok, "ok", _} = Fetch.load(base <> "/img", initiator: "http://other.test/")
      assert_receive {:request, "GET", "/img", headers, _}
      refute Map.has_key?(headers, "cookie")
    end

    test "a top-level navigation from another site sends Lax cookies, a same-site initiator sends all" do
      Browser.Cookies.clear()

      base = serve(["HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok"])

      Browser.Cookies.store(base <> "/", ["lax=1", "strict=2; SameSite=Strict"])

      assert {:ok, "ok", _} =
               Fetch.load(base <> "/nav", initiator: "http://other.test/", navigation: true)

      assert_receive {:request, "GET", "/nav", %{"cookie" => "lax=1"}, _}
    end
  end

  describe "caching" do
    defp response(body, headers),
      do:
        "HTTP/1.1 200 OK\r\nContent-Length: #{byte_size(body)}\r\nConnection: close\r\n" <>
          Enum.map_join(headers, "", fn h -> h <> "\r\n" end) <> "\r\n" <> body

    @not_modified "HTTP/1.1 304 Not Modified\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"

    test "a fresh response is served from memory, without a request" do
      base = serve([response("once", ["Cache-Control: max-age=60"])])
      assert {:ok, "once", _} = Fetch.load(base <> "/a")
      assert_receive {:request, "GET", "/a", _, ""}
      assert {:ok, "once", _} = Fetch.load(base <> "/a")
      refute_receive {:request, _, _, _, _}, 50
    end

    test "a stale response is revalidated with its ETag, and a 304 reuses the body" do
      base =
        serve([
          response("body", ["ETag: \"v1\"", "Cache-Control: max-age=0"]),
          @not_modified
        ])

      assert {:ok, "body", _} = Fetch.load(base <> "/e")
      assert_receive {:request, "GET", "/e", headers, ""}
      refute Map.has_key?(headers, "if-none-match")

      assert {:ok, "body", _} = Fetch.load(base <> "/e")
      assert_receive {:request, "GET", "/e", %{"if-none-match" => "\"v1\""}, ""}
    end

    test "Last-Modified revalidates with If-Modified-Since, and a 200 replaces the entry" do
      lm = "Mon, 01 Jan 2024 00:00:00 GMT"

      base =
        serve([
          response("old", ["Last-Modified: #{lm}", "Cache-Control: no-cache"]),
          response("new", [])
        ])

      assert {:ok, "old", _} = Fetch.load(base <> "/m")
      assert {:ok, "new", _} = Fetch.load(base <> "/m")
      assert_receive {:request, "GET", "/m", _, ""}
      assert_receive {:request, "GET", "/m", %{"if-modified-since" => ^lm}, ""}
    end

    test "a response with only Last-Modified stays fresh for a tenth of its age" do
      lm = "Mon, 01 Jan 2024 00:00:00 GMT"
      base = serve([response("old", ["Last-Modified: #{lm}"]), response("new", [])])

      assert {:ok, "old", _} = Fetch.load(base <> "/h")
      assert {:ok, "old", _} = Fetch.load(base <> "/h")
      assert_receive {:request, "GET", "/h", _, ""}
      refute_receive {:request, "GET", "/h", _, ""}, 50

      # (changed a moment ago: nothing to go by, so it is asked for again)
      now = :httpd_util.rfc1123_date() |> to_string()
      base = serve([response("a", ["Last-Modified: #{now}"]), response("b", [])])
      assert {:ok, "a", _} = Fetch.load(base <> "/h2")
      assert {:ok, "b", _} = Fetch.load(base <> "/h2")
    end

    test "Expires sets the lifetime when there is no max-age" do
      expires = :httpd_util.rfc1123_date() |> to_string()
      future = "Fri, 01 Jan 2100 00:00:00 GMT"

      base =
        serve([response("a", ["Expires: #{future}"]), response("b", ["Expires: #{expires}"])])

      assert {:ok, "a", _} = Fetch.load(base <> "/future")
      assert {:ok, "a", _} = Fetch.load(base <> "/future")
      assert {:ok, "b", _} = Fetch.load(base <> "/past")
    end

    test "no-store, no-cache and responses with no lifetime or validator are not reused" do
      for headers <- [["Cache-Control: no-store"], ["Cache-Control: no-cache"], []] do
        base = serve([response("1", headers), response("2", headers)])
        assert {:ok, "1", _} = Fetch.load(base <> "/n")
        assert {:ok, "2", _} = Fetch.load(base <> "/n")
      end
    end

    test "private responses and Vary: * are not stored" do
      for header <- ["Cache-Control: private, max-age=60", "Vary: *"] do
        base = serve([response("1", [header, "Cache-Control: max-age=60"]), response("2", [])])
        assert {:ok, "1", _} = Fetch.load(base <> "/p")
        assert {:ok, "2", _} = Fetch.load(base <> "/p")
      end
    end

    test "cache: :reload always asks the server" do
      base = serve([response("1", ["Cache-Control: max-age=60", "ETag: \"a\""]), @not_modified])
      assert {:ok, "1", _} = Fetch.load(base <> "/r")
      assert {:ok, "1", _} = Fetch.load(base <> "/r", cache: :reload)
      assert_receive {:request, "GET", "/r", _, ""}
      assert_receive {:request, "GET", "/r", %{"if-none-match" => "\"a\""}, ""}
    end

    test "cache: :history reuses a stale entry" do
      base = serve([response("1", ["Cache-Control: max-age=0", "ETag: \"a\""])])
      assert {:ok, "1", _} = Fetch.load(base <> "/h")
      assert {:ok, "1", _} = Fetch.load(base <> "/h", cache: :history)
      assert_receive {:request, "GET", "/h", _, ""}
      refute_receive {:request, _, _, _, _}, 50
    end

    test "POSTs are neither cached nor served from the cache" do
      base =
        serve([response("get", ["Cache-Control: max-age=60"]), response("post", [])])

      assert {:ok, "get", _} = Fetch.load(base <> "/q")
      assert {:ok, "post", _} = Fetch.load(base <> "/q", method: :post, body: "a=1")
      assert_receive {:request, "POST", "/q", _, "a=1"}
    end
  end

  describe "full responses for scripts" do
    test "any status comes back with its reason, headers and body" do
      base =
        serve([
          "HTTP/1.1 404 Not Found\r\nX-Thing: a\r\nSet-Cookie: s=1\r\nContent-Length: 4\r\nConnection: close\r\n\r\nnope"
        ])

      assert {:ok, response, url} = Fetch.load(base <> "/missing", full: true)
      assert url == base <> "/missing"
      assert response.status == 404
      assert response.status_text == "Not Found"
      assert response.body == "nope"
      assert response.redirected == false
      assert {"x-thing", "a"} in response.headers
      refute Enum.any?(response.headers, fn {k, _} -> k == "set-cookie" end)
    end

    test "a redirect is followed and marked" do
      base = serve([redirect(302, "/b"), ok("there")])

      assert {:ok, %{status: 200, body: "there", redirected: true}, url} =
               Fetch.load(base <> "/a", full: true)

      assert url == base <> "/b"
    end

    test "method, headers and content type are sent, the ones a script may not set are not" do
      base = serve([ok("")])

      Fetch.load(base <> "/r",
        full: true,
        method: :put,
        body: ~s({"a":1}),
        content_type: "application/json",
        initiator: "http://page.test/",
        headers: [{"X-Token", "abc"}, {"Host", "evil.test"}, {"Cookie", "x=1"}]
      )

      assert_receive {:request, "PUT", "/r", headers, ~s({"a":1})}
      assert headers["content-type"] == "application/json"
      assert headers["x-token"] == "abc"
      assert headers["accept"] == "*/*"
      assert headers["origin"] == "http://page.test"
      refute headers["host"] == "evil.test"
      refute headers["cookie"]
    end

    test "DELETE and HEAD are made as such" do
      base =
        serve([
          ok(""),
          "HTTP/1.1 200 OK\r\nX-Len: 5\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        ])

      assert {:ok, %{status: 200}, _} = Fetch.load(base <> "/d", full: true, method: :delete)
      assert {:ok, %{headers: headers}, _} = Fetch.load(base <> "/h", full: true, method: :head)
      assert_receive {:request, "DELETE", "/d", _, ""}
      assert_receive {:request, "HEAD", "/h", _, ""}
      assert {"x-len", "5"} in headers
    end

    test "credentials: :omit sends and stores no cookies" do
      Browser.Cookies.clear()

      base =
        serve([
          ok("1"),
          ok("2"),
          "HTTP/1.1 200 OK\r\nSet-Cookie: k=v\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        ])

      Browser.Cookies.store(base <> "/", ["omitme=1"])
      on_exit(fn -> Browser.Cookies.store(base <> "/", ["omitme=; Max-Age=0"]) end)

      Fetch.load(base <> "/a", full: true, credentials: :omit)
      assert_receive {:request, "GET", "/a", headers, _}
      refute headers["cookie"]

      Fetch.load(base <> "/b", full: true, credentials: :include)
      assert_receive {:request, "GET", "/b", %{"cookie" => cookie}, _}
      assert cookie =~ "omitme=1"

      Fetch.load(base <> "/c", full: true, credentials: :omit)
      refute Browser.Cookies.header(base <> "/") =~ "k=v"
    end

    test "same-origin credentials leave cookies out of a cross-origin request" do
      base = serve([ok("1")])
      Browser.Cookies.store(base <> "/", ["crossme=1"])
      on_exit(fn -> Browser.Cookies.store(base <> "/", ["crossme=; Max-Age=0"]) end)
      Fetch.load(base <> "/a", full: true, initiator: "http://page.test/")
      assert_receive {:request, "GET", "/a", headers, _}
      refute headers["cookie"]
    end
  end
end
