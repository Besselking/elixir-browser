defmodule Browser.JS.WebSocketNetTest do
  # these change the proxy settings and the trusted roots, which are global
  use ExUnit.Case, async: false
  alias Browser.JS.Runtime
  alias Browser.WebSocket, as: WS

  setup do
    config = :persistent_term.get({Browser.Proxy, :config}, nil)
    cacerts = :persistent_term.get({Browser.Proxy, :cacerts}, nil)

    on_exit(fn ->
      restore({Browser.Proxy, :config}, config)
      restore({Browser.Proxy, :cacerts}, cacerts)
    end)
  end

  defp restore(key, nil), do: :persistent_term.erase(key)
  defp restore(key, value), do: :persistent_term.put(key, value)

  # a server for one connection: `accept` gives the socket, `proxy: true` answers a CONNECT first
  defp serve(opts) do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(listener)
    test = self()

    spawn_link(fn ->
      {:ok, tcp} = :gen_tcp.accept(listener, 5000)
      sock = {:tcp, tcp}

      sock =
        if opts[:proxy] do
          send(test, {:connect, read_head(sock, "")})
          send_data(sock, "HTTP/1.1 200 Connection established\r\n\r\n")
          sock
        else
          sock
        end

      sock =
        case opts[:tls] do
          nil ->
            sock

          tls ->
            case :ssl.handshake(tcp, tls ++ [mode: :binary, active: false], 5000) do
              {:ok, ssl} -> {:ssl, ssl}
              {:error, _} -> exit(:normal)
            end
        end

      head = read_head(sock, "")
      send(test, {:request, head})
      [key] = Regex.run(~r/Sec-WebSocket-Key: (\S+)/i, head, capture: :all_but_first)

      send_data(
        sock,
        "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" <>
          "Sec-WebSocket-Accept: #{WS.accept_for(key)}\r\n\r\n"
      )

      echo(sock, "")
    end)

    port
  end

  defp send_data({:tcp, s}, data), do: :gen_tcp.send(s, data)
  defp send_data({:ssl, s}, data), do: :ssl.send(s, data)
  defp recv({:tcp, s}), do: :gen_tcp.recv(s, 0, 5000)
  defp recv({:ssl, s}), do: :ssl.recv(s, 0, 5000)

  defp read_head(sock, acc) do
    if String.contains?(acc, "\r\n\r\n") do
      acc
    else
      {:ok, data} = recv(sock)
      read_head(sock, acc <> data)
    end
  end

  defp echo(sock, buf) do
    case WS.decode(buf) do
      {:ok, %{opcode: op, payload: p}, rest} when op in [1, 2] ->
        send_data(sock, WS.encode(op, p, mask: false))
        echo(sock, rest)

      {:ok, %{opcode: 8, payload: p}, _} ->
        send_data(sock, WS.encode(8, p, mask: false))

      {:ok, _, rest} ->
        echo(sock, rest)

      :more ->
        case recv(sock) do
          {:ok, data} -> echo(sock, buf <> data)
          _ -> :ok
        end
    end
  end

  defp run(script, page \\ "https://t.test/") do
    {raw, _} =
      "<body><script>#{script}</script></body>"
      |> Browser.HTML.parse()
      |> Browser.Forms.index()

    info = %{url: page, width: 800, height: 600, fetch: fn _ -> {:error, "404"} end}
    pid = Runtime.start(raw, info)
    r = Runtime.run_scripts(pid)
    lines = for({_, t} <- r.console, do: t) ++ collect(pid, [])
    Runtime.stop(pid)
    lines
  end

  defp collect(pid, acc) do
    receive do
      {:js_async, ^pid, reply} -> collect(pid, acc ++ for({_, t} <- reply.console, do: t))
    after
      600 -> acc
    end
  end

  @script """
  const ws = new WebSocket("%URL%");
  ws.onopen = () => ws.send("hi");
  ws.onmessage = (e) => { console.log("got", e.data); ws.close(); };
  ws.onerror = () => console.log("error");
  ws.onclose = (e) => console.log("close", e.code, e.wasClean);
  """

  test "a connection goes through the proxy with a CONNECT tunnel" do
    port = serve(proxy: true)

    :persistent_term.put({Browser.Proxy, :config}, %{
      http: {"127.0.0.1", port, {~c"user", ~c"pw"}},
      https: nil,
      no_proxy: []
    })

    lines = run(String.replace(@script, "%URL%", "ws://some.test:8081/p"), "http://t.test/")
    assert lines == ["got hi", "close 1005 true"]
    assert_received {:connect, connect}
    assert connect =~ "CONNECT some.test:8081 HTTP/1.1\r\n"
    assert connect =~ "Proxy-Authorization: Basic #{Base.encode64("user:pw")}\r\n"
    assert_received {:request, request}
    assert request =~ "GET /p HTTP/1.1\r\nHost: some.test:8081\r\n"
  end

  test "wss: TLS with a certificate the browser trusts" do
    %{server_config: server, client_config: client} =
      :public_key.pkix_test_data(%{
        server_chain: %{
          root: [key: {:rsa, 2048, 17}],
          peer: [
            key: {:rsa, 2048, 17},
            extensions: [{:Extension, {2, 5, 29, 17}, false, [{:dNSName, ~c"localhost"}]}]
          ]
        },
        client_chain: %{root: [key: {:rsa, 2048, 17}], peer: [key: {:rsa, 2048, 17}]}
      })

    :persistent_term.put({Browser.Proxy, :cacerts}, client[:cacerts])
    port = serve(tls: server)
    lines = run(String.replace(@script, "%URL%", "wss://localhost:#{port}/secure"))
    assert lines == ["got hi", "close 1005 true"]
    assert_received {:request, head}
    assert head =~ "GET /secure HTTP/1.1"
  end

  test "wss with a certificate nobody trusts fails" do
    %{server_config: server} =
      :public_key.pkix_test_data(%{
        server_chain: %{
          root: [key: {:rsa, 2048, 17}],
          peer: [
            key: {:rsa, 2048, 17},
            extensions: [{:Extension, {2, 5, 29, 17}, false, [{:dNSName, ~c"localhost"}]}]
          ]
        },
        client_chain: %{root: [key: {:rsa, 2048, 17}], peer: [key: {:rsa, 2048, 17}]}
      })

    port = serve(tls: server)
    lines = run(String.replace(@script, "%URL%", "wss://localhost:#{port}/secure"))
    assert lines == ["error", "close 1006 false"]
  end
end
