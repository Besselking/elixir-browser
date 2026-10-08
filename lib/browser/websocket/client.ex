defmodule Browser.WebSocket.Client do
  @moduledoc """
  One WebSocket connection of a page, in a process of its own (see `Browser.WebSocket` for the
  protocol).

  `start/4` connects (through the proxy of `Browser.Proxy`, if there is one, with a `CONNECT`
  tunnel; `wss` addresses get TLS with the same trust as the HTTP layer), does the opening
  handshake, and then tells the process that started it what happens, as `{:ws, id, event}`:

    * `{:open, protocol}`
    * `{:message, :text | :binary, data}`
    * `:error` (the connection failed or broke; `:closed` follows)
    * `{:closed, code, reason, clean?}` (the last event)

  The owner sends `{:send, :text | :binary, data}` and `{:close, code | nil, reason}` to the
  process. When the owner exits the connection is dropped.
  """

  alias Browser.{Cookies, Proxy, WebSocket}

  @connect_timeout 15_000
  @close_timeout 5_000

  @doc """
  Starts a connection to `url` for `owner`. Options: `:protocols` (list), `:origin` and
  `:page_url` (the page that opens the connection; sets `Origin` and decides cookies).
  """
  def start(owner, id, url, opts) do
    :erlang.spawn_opt(fn -> run(owner, id, url, opts) end, [])
  end

  defp run(owner, id, url, opts) do
    Process.monitor(owner)
    Application.ensure_all_started(:ssl)

    case connect(URI.parse(url), opts) do
      {:ok, sock, protocol, rest} ->
        emit(owner, id, {:open, protocol})
        activate(sock)

        st = %{
          owner: owner,
          id: id,
          sock: sock,
          buffer: <<>>,
          frag: nil,
          close_sent: false,
          deadline: nil
        }

        frames(st, rest)

      {:error, message} ->
        _ = message
        emit(owner, id, :error)
        emit(owner, id, {:closed, 1006, "", false})
    end
  end

  defp emit(owner, id, event), do: send(owner, {:ws, id, event})

  # ── connecting ─────────────────────────────────────────────

  defp connect(uri, opts) do
    port = uri.port || if(uri.scheme == "wss", do: 443, else: 80)
    key = WebSocket.new_key()
    protocols = opts[:protocols] || []
    http_url = to_string(%{uri | scheme: if(uri.scheme == "wss", do: "https", else: "http")})
    cookie_opts = [cross_site: cross_site?(opts[:page_url], http_url), navigation: false]

    request =
      WebSocket.request(uri,
        key: key,
        origin: opts[:origin],
        protocols: protocols,
        user_agent: Browser.Fetch.user_agent(),
        cookie: Cookies.header(http_url, cookie_opts)
      )

    with {:ok, tcp} <- tcp(uri, port),
         {:ok, sock} <- tls(tcp, uri),
         :ok <- send_data(sock, request),
         {:ok, status, headers, rest} <- read_head(sock, <<>>),
         :ok <- store_cookies(http_url, headers, cookie_opts),
         {:ok, protocol} <- WebSocket.check_response(status, headers, key, protocols) do
      {:ok, sock, protocol, rest}
    else
      {:error, _} = error ->
        error
    end
  end

  defp cross_site?(nil, _url), do: false
  defp cross_site?(page_url, url), do: not Cookies.same_site?(page_url, url)

  defp store_cookies(url, headers, opts) do
    case for({"set-cookie", v} <- headers, do: v) do
      [] -> :ok
      set -> Cookies.store(url, set, opts)
    end
  end

  # a TCP connection to the server, or to the proxy and through it
  defp tcp(uri, port) do
    case Proxy.tunnel(uri) do
      nil ->
        tcp_connect(uri.host, port)

      {phost, pport, auth} ->
        with {:ok, tcp} <- tcp_connect(phost, pport),
             :ok <- :gen_tcp.send(tcp, connect_request(uri.host, port, auth)),
             {:ok, status, _headers, _rest} <- read_head({:tcp, tcp}, <<>>) do
          if status == 200 do
            {:ok, tcp}
          else
            :gen_tcp.close(tcp)
            {:error, "proxy answered #{status}"}
          end
        end
    end
  end

  defp connect_request(host, port, auth) do
    target = if String.contains?(host, ":"), do: "[#{host}]:#{port}", else: "#{host}:#{port}"

    credentials =
      case auth do
        {user, pass} ->
          [
            "Proxy-Authorization: Basic ",
            Base.encode64(to_string(user) <> ":" <> to_string(pass)),
            "\r\n"
          ]

        nil ->
          []
      end

    IO.iodata_to_binary([
      "CONNECT ",
      target,
      " HTTP/1.1\r\nHost: ",
      target,
      "\r\n",
      credentials,
      "\r\n"
    ])
  end

  defp tcp_connect(host, port) do
    opts = [:binary, active: false, packet: :raw, nodelay: true]
    charlist = String.to_charlist(host)

    case :gen_tcp.connect(charlist, port, opts, @connect_timeout) do
      {:ok, tcp} ->
        {:ok, tcp}

      {:error, :nxdomain} ->
        to_error(:gen_tcp.connect(charlist, port, [:inet6 | opts], @connect_timeout))

      other ->
        to_error(other)
    end
  end

  defp to_error({:ok, tcp}), do: {:ok, tcp}
  defp to_error({:error, reason}), do: {:error, "connection failed: #{inspect(reason)}"}

  defp tls(tcp, %URI{scheme: "ws"}), do: {:ok, {:tcp, tcp}}

  defp tls(tcp, %URI{scheme: "wss", host: host}) do
    sni =
      case :inet.parse_address(String.to_charlist(host)) do
        {:ok, _} -> []
        _ -> [server_name_indication: String.to_charlist(host)]
      end

    options =
      [
        verify: :verify_peer,
        cacerts: Proxy.cacerts(),
        customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
      ] ++ sni

    case :ssl.connect(tcp, options, @connect_timeout) do
      {:ok, ssl} -> {:ok, {:ssl, ssl}}
      {:error, reason} -> {:error, "TLS failed: #{inspect(reason)}"}
    end
  end

  defp tls(tcp, _uri) do
    :gen_tcp.close(tcp)
    {:error, "not a WebSocket address"}
  end

  # reads until the blank line that ends the head of a response
  defp read_head(sock, acc) do
    case WebSocket.parse_response(acc) do
      {:ok, _, _, _} = ok ->
        ok

      :more ->
        if byte_size(acc) > 65_536 do
          {:error, "response head too long"}
        else
          case recv(sock, @connect_timeout) do
            {:ok, data} -> read_head(sock, acc <> data)
            {:error, reason} -> {:error, "no response: #{inspect(reason)}"}
          end
        end
    end
  end

  # ── the socket ─────────────────────────────────────────────

  defp send_data({:tcp, s}, data), do: :gen_tcp.send(s, data)
  defp send_data({:ssl, s}, data), do: :ssl.send(s, data)
  defp recv({:tcp, s}, timeout), do: :gen_tcp.recv(s, 0, timeout)
  defp recv({:ssl, s}, timeout), do: :ssl.recv(s, 0, timeout)
  defp activate({:tcp, s}), do: :inet.setopts(s, active: :once)
  defp activate({:ssl, s}), do: :ssl.setopts(s, active: :once)
  defp close_socket({:tcp, s}), do: :gen_tcp.close(s)
  defp close_socket({:ssl, s}), do: :ssl.close(s)

  # ── the open connection ────────────────────────────────────

  # `data` came in: whole frames are handled, the rest waits for more
  defp frames(st, data) do
    case WebSocket.decode(st.buffer <> data) do
      {:ok, %{masked: true}, _} ->
        fail(st, 1002)

      {:ok, frame, rest} ->
        case frame(st, frame) do
          {:continue, st} -> frames(%{st | buffer: <<>>}, rest)
          :done -> :ok
        end

      :more ->
        loop(%{st | buffer: st.buffer <> data})

      {:error, code, _reason} ->
        fail(st, code)
    end
  end

  defp loop(st) do
    {tag, closed, error} = tags(st.sock)
    {_, s} = st.sock
    owner = st.owner

    timeout =
      case st.deadline do
        nil -> :infinity
        at -> max(at - System.monotonic_time(:millisecond), 0)
      end

    receive do
      {^tag, ^s, data} ->
        activate(st.sock)
        frames(%{st | buffer: <<>>}, st.buffer <> data)

      {^closed, ^s} ->
        broken(st)

      {^error, ^s, _reason} ->
        broken(st)

      {:send, kind, data} ->
        if st.close_sent do
          loop(st)
        else
          opcode = if kind == :text, do: 1, else: 2
          send_data(st.sock, WebSocket.encode(opcode, data))
          loop(st)
        end

      {:close, code, reason} ->
        if st.close_sent do
          loop(st)
        else
          send_data(st.sock, WebSocket.encode(8, WebSocket.close_payload(code, reason)))

          loop(%{
            st
            | close_sent: true,
              deadline: System.monotonic_time(:millisecond) + @close_timeout
          })
        end

      {:DOWN, _, :process, ^owner, _} ->
        close_socket(st.sock)
    after
      timeout ->
        broken(st)
    end
  end

  defp tags({:tcp, _}), do: {:tcp, :tcp_closed, :tcp_error}
  defp tags({:ssl, _}), do: {:ssl, :ssl_closed, :ssl_error}

  # a data frame is part of a message; control frames may come in between
  defp frame(st, %{opcode: op, fin: fin, payload: payload}) when op in [0, 1, 2] do
    case {op, st.frag} do
      {0, nil} ->
        fail(st, 1002)

      {op, frag} when op in [1, 2] and frag != nil ->
        fail(st, 1002)

      _ ->
        {kind, chunks, size} = st.frag || {if(op == 1, do: :text, else: :binary), [], 0}
        size = size + byte_size(payload)

        cond do
          size > WebSocket.max_payload() ->
            fail(st, 1009)

          fin ->
            data = IO.iodata_to_binary(Enum.reverse([payload | chunks]))

            if kind == :text and not String.valid?(data) do
              fail(st, 1007)
            else
              emit(st.owner, st.id, {:message, kind, data})
              {:continue, %{st | frag: nil}}
            end

          true ->
            {:continue, %{st | frag: {kind, [payload | chunks], size}}}
        end
    end
  end

  defp frame(st, %{opcode: 9, payload: payload}) do
    unless st.close_sent, do: send_data(st.sock, WebSocket.encode(10, payload))
    {:continue, st}
  end

  defp frame(st, %{opcode: 10}), do: {:continue, st}

  defp frame(st, %{opcode: 8, payload: payload}) do
    case WebSocket.parse_close(payload) do
      {:ok, code, reason} ->
        # the answer to a close is a close with the same status
        unless st.close_sent, do: send_data(st.sock, WebSocket.encode(8, payload))
        finish(st, code || 1005, reason, true)
        :done

      :error ->
        fail(st, 1002)
    end
  end

  # a protocol error: the server is told, and the connection is dropped
  defp fail(st, code) do
    unless st.close_sent,
      do: send_data(st.sock, WebSocket.encode(8, WebSocket.close_payload(code, "")))

    broken(st)
  end

  # the connection broke without a close handshake: the page hears `error` and then `close`
  # with code 1006
  defp broken(st) do
    emit(st.owner, st.id, :error)
    finish(st, 1006, "", false)
  end

  defp finish(st, code, reason, clean?) do
    close_socket(st.sock)
    emit(st.owner, st.id, {:closed, code, reason, clean?})
    :done
  end
end
