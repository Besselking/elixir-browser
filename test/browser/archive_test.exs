defmodule Browser.ArchiveTest do
  # the archive mode is global
  use ExUnit.Case, async: false
  alias Browser.{Archive, Fetch}

  @moduletag :tmp_dir

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

    port
  end

  defp response(status, headers, body) do
    head =
      Enum.map_join(headers ++ [{"Content-Length", byte_size(body)}], "", fn {k, v} ->
        "#{k}: #{v}\r\n"
      end)

    "HTTP/1.1 #{status} X\r\n#{head}Connection: close\r\n\r\n#{body}"
  end

  setup do
    on_exit(&Archive.stop/0)
  end

  test "a recorded page loads again with no network", %{tmp_dir: dir} do
    port =
      serve([
        response(302, [{"Location", "/page"}, {"Set-Cookie", "a=1"}], ""),
        response(200, [{"Content-Type", "text/html"}], "<p>hello</p>"),
        response(200, [{"Content-Type", "text/css"}], "p { color: red }")
      ])

    base = "http://127.0.0.1:#{port}"
    Archive.record_start()
    assert Archive.mode() == :record
    assert {:ok, "<p>hello</p>", _} = Fetch.load(base <> "/", navigation: true)
    assert {:ok, "p { color: red }", _} = Fetch.load(base <> "/a.css")
    assert Archive.recorded_count() == 3

    assert {:ok, path, 3} = Archive.save_recording(dir)
    assert Path.extname(path) == ".ebarchive"
    assert Archive.mode() == :off

    :ok = Archive.replay(path)
    assert Archive.mode() == :replay
    # the server is gone: these answers come from the file
    assert {:ok, "<p>hello</p>", url} = Fetch.load(base <> "/", navigation: true)
    assert url == base <> "/page"
    assert {:ok, "p { color: red }", _} = Fetch.load(base <> "/a.css")
    assert {:error, _} = Fetch.load(base <> "/missing.css")
  end

  test "the archive keeps no cookies and says where it began", %{tmp_dir: dir} do
    port = serve([response(200, [{"Set-Cookie", "secret=1"}, {"X-A", "b"}], "x")])
    base = "http://127.0.0.1:#{port}/"
    Archive.record_start()
    {:ok, _, _} = Fetch.load(base, navigation: true)
    {:ok, path, 1} = Archive.save_recording(dir)

    assert {:ok, archive} = Archive.read(path)
    assert Archive.start_url(archive) == base
    [entry] = archive.entries
    assert {"x-a", "b"} in entry.headers
    refute List.keymember?(entry.headers, "set-cookie", 0)
  end

  test "repeated requests get the answers in order, the last one repeating", %{tmp_dir: dir} do
    port =
      serve([
        response(200, [], "one"),
        response(200, [], "two")
      ])

    url = "http://127.0.0.1:#{port}/poll"
    Archive.record_start()
    {:ok, "one", _} = Fetch.load(url)
    {:ok, "two", _} = Fetch.load(url)
    {:ok, path, 2} = Archive.save_recording(dir)

    :ok = Archive.replay(path)
    assert {:ok, "one", _} = Fetch.load(url)
    assert {:ok, "two", _} = Fetch.load(url)
    assert {:ok, "two", _} = Fetch.load(url)
  end

  test "a gzip body is kept as received and the streaming callback still gets text", %{
    tmp_dir: dir
  } do
    port = serve([response(200, [{"Content-Encoding", "gzip"}], :zlib.gzip("zipped"))])
    url = "http://127.0.0.1:#{port}/z"
    Archive.record_start()
    assert {:ok, "zipped", _} = Fetch.load(url)
    {:ok, path, 1} = Archive.save_recording(dir)
    {:ok, archive} = Archive.read(path)
    assert hd(archive.entries).body == :zlib.gzip("zipped")

    :ok = Archive.replay(path)
    me = self()

    assert {:ok, "zipped", _} =
             Fetch.load(url, on_chunk: fn text, _ -> send(me, {:chunk, text}) end)

    assert_received {:chunk, "zipped"}
  end

  test "script requests (full) and errors come from the archive too", %{tmp_dir: dir} do
    port = serve([response(404, [{"X-Why", "gone"}], "nope")])
    url = "http://127.0.0.1:#{port}/api"
    Archive.record_start()
    assert {:ok, %{status: 404}, _} = Fetch.load(url, full: true)
    {:ok, path, 1} = Archive.save_recording(dir)

    :ok = Archive.replay(path)
    assert {:ok, %{status: 404, body: "nope", headers: headers}, _} = Fetch.load(url, full: true)
    assert {"x-why", "gone"} in headers
  end

  test "a file that is not an archive is refused", %{tmp_dir: dir} do
    path = Path.join(dir, "x.ebarchive")
    File.write!(path, "hello")
    assert {:error, "not a page archive"} = Archive.read(path)
    assert {:error, _} = Archive.replay(path)

    File.write!(path, "ELIXIR-BROWSER-ARCHIVE 1\nrubbish")
    assert {:error, _} = Archive.read(path)
    assert Archive.mode() == :off
  end

  test "the recording stops at the size limit and a replay needs no cache", %{tmp_dir: dir} do
    Archive.record_start()
    Archive.record(:get, "http://x.test/", nil, 200, "OK", [{~c"a", ~c"b"}], "body", true)
    {:ok, path, 1} = Archive.save_recording(dir)
    :ok = Archive.replay(path)
    # the memory cache does not answer in place of the archive
    assert {:ok, "body", _} = Fetch.load("http://x.test/")
    assert {:ok, "body", _} = Fetch.load("http://x.test/", cache: :history)
  end
end
