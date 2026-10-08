defmodule Browser.JS.WebSocketTest do
  use ExUnit.Case, async: true
  alias Browser.JS.Runtime
  alias Browser.WebSocket, as: WS

  # ── a server for one connection ────────────────────────────

  # Starts a server on a free port that does the handshake (choosing the first sub-protocol the
  # client asked for, if `protocol: true`) and then runs `fun.(socket)`. Returns the port.
  defp serve(fun, opts \\ []) do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(listener)
    test = self()

    spawn_link(fn ->
      {:ok, s} = :gen_tcp.accept(listener, 5000)
      head = read_head(s, "")
      send(test, {:request, head})
      [key] = Regex.run(~r/Sec-WebSocket-Key: (\S+)/i, head, capture: :all_but_first)

      protocol =
        with true <- opts[:protocol],
             [_, list] <- Regex.run(~r/Sec-WebSocket-Protocol: ([^\r]+)/i, head) do
          "Sec-WebSocket-Protocol: #{list |> String.split(",") |> hd() |> String.trim()}\r\n"
        else
          _ -> ""
        end

      :gen_tcp.send(
        s,
        "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" <>
          "Sec-WebSocket-Accept: #{WS.accept_for(key)}\r\n#{protocol}\r\n"
      )

      fun.(s)
      :gen_tcp.close(s)
    end)

    port
  end

  defp read_head(s, acc) do
    if String.contains?(acc, "\r\n\r\n") do
      acc
    else
      {:ok, data} = :gen_tcp.recv(s, 0, 5000)
      read_head(s, acc <> data)
    end
  end

  # the next frame the client sent (what came after it waits in the process dictionary)
  defp frame(s) do
    case WS.decode(Process.get(:buffer, "")) do
      {:ok, frame, rest} ->
        Process.put(:buffer, rest)
        assert frame.masked
        frame

      :more ->
        {:ok, data} = :gen_tcp.recv(s, 0, 5000)
        Process.put(:buffer, Process.get(:buffer, "") <> data)
        frame(s)
    end
  end

  defp put(s, opcode, payload, opts \\ []),
    do: :gen_tcp.send(s, WS.encode(opcode, payload, [mask: false] ++ opts))

  # echoes text and binary frames until the client closes
  defp echo(s) do
    case frame(s) do
      %{opcode: op, payload: p} when op in [1, 2] ->
        put(s, op, p)
        echo(s)

      %{opcode: 8, payload: p} ->
        put(s, 8, p)

      _ ->
        echo(s)
    end
  end

  # ── a page ─────────────────────────────────────────────────

  defp run(script, wait \\ 500) do
    {raw, _} =
      "<body><script>#{script}</script></body>"
      |> Browser.HTML.parse()
      |> Browser.Forms.index()

    info = %{url: "http://t.test/", width: 800, height: 600, fetch: fn _ -> {:error, "404"} end}
    pid = Runtime.start(raw, info)
    r = Runtime.run_scripts(pid)
    lines = for({_, t} <- r.console, do: t) ++ collect(pid, wait, [])
    Runtime.stop(pid)
    lines
  end

  defp collect(pid, wait, acc) do
    receive do
      {:js_async, ^pid, reply} -> collect(pid, wait, acc ++ for({_, t} <- reply.console, do: t))
    after
      wait -> acc
    end
  end

  test "text and binary messages, sub-protocol, and a clean close" do
    port = serve(&echo/1, protocol: true)

    lines =
      run("""
      const ws = new WebSocket("ws://127.0.0.1:#{port}/echo?x=1", ["chat", "other"]);
      console.log("state", ws.readyState, WebSocket.CONNECTING, ws.url);
      try { ws.send("early"); } catch (e) { console.log(e.name); }
      ws.binaryType = "arraybuffer";
      ws.onopen = () => {
        console.log("open", ws.readyState, ws.protocol);
        ws.send("héllo ✓");
        ws.send(new Uint8Array([1, 2, 255]));
      };
      ws.addEventListener("message", (e) => {
        if (typeof e.data === "string") console.log("text", e.data);
        else {
          console.log("binary", e.data instanceof ArrayBuffer, Array.from(new Uint8Array(e.data)).join(","));
          ws.close(1000, "done");
          console.log("closing", ws.readyState);
        }
      });
      ws.onclose = (e) => console.log("close", e.code, e.reason, e.wasClean, ws.readyState);
      ws.onerror = () => console.log("error!");
      """)

    assert lines == [
             "state 0 0 ws://127.0.0.1:#{port}/echo?x=1",
             "InvalidStateError",
             "open 1 chat",
             "text héllo ✓",
             "binary true 1,2,255",
             "closing 2",
             "close 1000 done true 3"
           ]

    assert_received {:request, head}
    assert head =~ "GET /echo?x=1 HTTP/1.1\r\n"
    assert head =~ "Origin: http://t.test\r\n"
    assert head =~ "Sec-WebSocket-Version: 13\r\n"
  end

  test "the server closes with a code" do
    port =
      serve(fn s ->
        put(s, 1, "bye now")
        put(s, 8, WS.close_payload(4001, "go away"))
        # the client answers a close with a close
        assert %{opcode: 8, payload: <<4001::16, "go away">>} = frame(s)
      end)

    lines =
      run("""
      const ws = new WebSocket("ws://127.0.0.1:#{port}/");
      ws.onmessage = (e) => console.log("msg", e.data);
      ws.onclose = (e) => console.log("close", e.code, e.reason, e.wasClean);
      """)

    assert lines == ["msg bye now", "close 4001 go away true"]
  end

  test "a refused connection is an error and then a close with code 1006" do
    {:ok, l} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(l)
    :gen_tcp.close(l)

    lines =
      run("""
      const ws = new WebSocket("ws://127.0.0.1:#{port}/");
      ws.onopen = () => console.log("open");
      ws.onerror = (e) => console.log("error", e.type, ws.readyState);
      ws.onclose = (e) => console.log("close", e.code, e.wasClean, ws.readyState);
      """)

    assert lines == ["error error 0", "close 1006 false 3"]
  end

  test "pings are answered, fragments are joined" do
    port =
      serve(fn s ->
        put(s, 9, "are you there")
        assert %{opcode: 10, payload: "are you there"} = frame(s)
        put(s, 1, "frag", fin: false)
        put(s, 9, "")
        assert %{opcode: 10, payload: ""} = frame(s)
        put(s, 0, "men", fin: false)
        put(s, 0, "ts")
        put(s, 8, WS.close_payload(1000, ""))
      end)

    lines =
      run("""
      const ws = new WebSocket("ws://127.0.0.1:#{port}/");
      ws.onmessage = (e) => console.log("msg", e.data);
      ws.onclose = (e) => console.log("close", e.code, e.wasClean);
      """)

    assert lines == ["msg fragments", "close 1000 true"]
  end

  test "invalid text fails the connection" do
    port =
      serve(fn s ->
        put(s, 1, <<0xFF, 0xFE>>)
        # the client sends a close with 1007
        assert %{opcode: 8, payload: <<1007::16>>} = frame(s)
      end)

    lines =
      run("""
      const ws = new WebSocket("ws://127.0.0.1:#{port}/");
      ws.onmessage = () => console.log("msg");
      ws.onerror = () => console.log("error");
      ws.onclose = (e) => console.log("close", e.code, e.wasClean);
      """)

    assert lines == ["error", "close 1006 false"]
  end

  test "a wrong handshake answer fails" do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(listener)

    spawn_link(fn ->
      {:ok, s} = :gen_tcp.accept(listener, 5000)
      _head = read_head(s, "")
      :gen_tcp.send(s, "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n")
      :gen_tcp.close(s)
    end)

    lines =
      run("""
      const ws = new WebSocket("ws://127.0.0.1:#{port}/");
      ws.onopen = () => console.log("open");
      ws.onclose = (e) => console.log("close", e.code, e.wasClean);
      """)

    assert lines == ["close 1006 false"]
  end

  test "constructor and close() checks" do
    lines =
      run("""
      const t = (f) => { try { f(); console.log("ok"); } catch (e) { console.log(e.name); } };
      t(() => new WebSocket("http:"));
      t(() => new WebSocket("ftp://x.test/"));
      t(() => new WebSocket("ws://x.test/#frag"));
      t(() => new WebSocket("ws://x.test/", ["a", "a"]));
      t(() => new WebSocket("ws://x.test/", ["bad proto"]));
      console.log(WebSocket.OPEN, WebSocket.CLOSED, new WebSocket("ws://127.0.0.1:1/").CLOSING);
      const ws = new WebSocket("ws://127.0.0.1:1/");
      t(() => ws.close(1001));
      t(() => ws.close(1000, "x".repeat(124)));
      ws.onclose = (e) => console.log("close", e.code);
      """)

    assert Enum.take(lines, 8) == [
             "SyntaxError",
             "SyntaxError",
             "SyntaxError",
             "SyntaxError",
             "SyntaxError",
             "1 3 2",
             "InvalidAccessError",
             "SyntaxError"
           ]
  end
end
