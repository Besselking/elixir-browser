defmodule Browser.WebSocket do
  @moduledoc """
  The WebSocket protocol (RFC 6455) without a library: the opening handshake of a client and the
  framing of messages. `Browser.WebSocket.Client` is the connection that uses it.

  A frame is `%{fin: boolean, opcode: integer, payload: binary}`. The opcodes are 0 (continuation),
  1 (text), 2 (binary), 8 (close), 9 (ping) and 10 (pong). No extensions are negotiated, so a
  frame with a reserved bit set is a protocol error.
  """

  import Bitwise

  @guid "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

  # a frame, and so a message, may not be bigger than this
  @max_payload 64 * 1024 * 1024

  def max_payload, do: @max_payload

  # ── the opening handshake ──────────────────────────────────

  @doc "A new random `Sec-WebSocket-Key`."
  def new_key, do: Base.encode64(:crypto.strong_rand_bytes(16))

  @doc "The `Sec-WebSocket-Accept` value that answers `key`."
  def accept_for(key), do: Base.encode64(:crypto.hash(:sha, key <> @guid))

  @doc """
  The upgrade request for `uri` (a `ws` or `wss` URI). Options: `:key`, `:origin`,
  `:protocols` (a list), `:cookie`, `:user_agent` and `:headers` (extra `{name, value}` pairs).
  """
  def request(%URI{} = uri, opts) do
    path = (uri.path || "/") |> then(&if(&1 == "", do: "/", else: &1))
    target = if uri.query, do: path <> "?" <> uri.query, else: path
    default = if uri.scheme == "wss", do: 443, else: 80
    host = if String.contains?(uri.host, ":"), do: "[" <> uri.host <> "]", else: uri.host

    host =
      if uri.port in [nil, default], do: host, else: host <> ":" <> Integer.to_string(uri.port)

    headers =
      [
        {"Host", host},
        {"Upgrade", "websocket"},
        {"Connection", "Upgrade"},
        {"Sec-WebSocket-Key", Keyword.fetch!(opts, :key)},
        {"Sec-WebSocket-Version", "13"}
      ] ++
        optional("Origin", opts[:origin]) ++
        optional("User-Agent", opts[:user_agent]) ++
        optional("Cookie", opts[:cookie]) ++
        case opts[:protocols] || [] do
          [] -> []
          list -> [{"Sec-WebSocket-Protocol", Enum.join(list, ", ")}]
        end ++ (opts[:headers] || [])

    ["GET ", target, " HTTP/1.1\r\n", for({k, v} <- headers, do: [k, ": ", v, "\r\n"]), "\r\n"]
    |> IO.iodata_to_binary()
  end

  defp optional(_name, nil), do: []
  defp optional(_name, ""), do: []
  defp optional(name, value), do: [{name, value}]

  @doc """
  Splits the server's answer off the front of `data`: `{:ok, status, headers, rest}` with
  lower-cased header names (`set-cookie` can repeat), or `:more` if the head is not complete.
  """
  def parse_response(data) do
    case :binary.split(data, "\r\n\r\n") do
      [head, rest] ->
        [status_line | lines] = String.split(head, "\r\n")

        status =
          case String.split(status_line, " ", parts: 3) do
            ["HTTP/1." <> _, code | _] -> Integer.parse(code) |> elem(0)
            _ -> 0
          end

        headers =
          for line <- lines,
              [k, v] <- [String.split(line, ":", parts: 2)],
              do: {k |> String.trim() |> String.downcase(), String.trim(v)}

        {:ok, status, headers, rest}

      [_] ->
        :more
    end
  end

  @doc """
  Checks the answer to the upgrade request: `{:ok, protocol}` (the sub-protocol the server
  chose, `""` for none) or `{:error, reason}`.
  """
  def check_response(status, headers, key, requested) do
    get = fn name -> for({^name, v} <- headers, do: v) end

    cond do
      status != 101 ->
        {:error, "unexpected response status #{status}"}

      not Enum.any?(get.("upgrade"), &(String.downcase(&1) == "websocket")) ->
        {:error, "missing Upgrade: websocket"}

      not Enum.any?(get.("connection"), &token?(&1, "upgrade")) ->
        {:error, "missing Connection: Upgrade"}

      get.("sec-websocket-accept") != [accept_for(key)] ->
        {:error, "wrong Sec-WebSocket-Accept"}

      get.("sec-websocket-extensions") != [] ->
        {:error, "unexpected extension"}

      true ->
        case get.("sec-websocket-protocol") do
          [] -> {:ok, ""}
          [p] -> if p in requested, do: {:ok, p}, else: {:error, "unrequested sub-protocol"}
          _ -> {:error, "more than one sub-protocol"}
        end
    end
  end

  defp token?(value, token),
    do:
      value
      |> String.split(",")
      |> Enum.any?(&(&1 |> String.trim() |> String.downcase() == token))

  # ── frames ─────────────────────────────────────────────────

  @doc """
  The bytes of one frame. A client masks its frames (`mask: true`, the default, with a random
  key); a server does not. `fin: false` starts or continues a fragmented message.
  """
  def encode(opcode, payload, opts \\ []) do
    fin = if Keyword.get(opts, :fin, true), do: 1, else: 0
    mask? = Keyword.get(opts, :mask, true)
    len = byte_size(payload)

    {len7, ext} =
      cond do
        len < 126 -> {len, <<>>}
        len < 65_536 -> {126, <<len::16>>}
        true -> {127, <<len::64>>}
      end

    if mask? do
      key = :crypto.strong_rand_bytes(4)

      <<fin::1, 0::3, opcode::4, 1::1, len7::7, ext::binary, key::binary,
        mask(payload, key)::binary>>
    else
      <<fin::1, 0::3, opcode::4, 0::1, len7::7, ext::binary, payload::binary>>
    end
  end

  @doc "A close frame's payload: the status code and a reason."
  def close_payload(nil, _reason), do: <<>>
  def close_payload(code, reason), do: <<code::16, reason::binary>>

  @doc """
  Reads one frame from the front of `buffer`: `{:ok, frame, rest}`, `:more` when it is not all
  there yet, or `{:error, status_code, reason}` for a protocol error. A masked payload is
  unmasked (`frame.masked` says it was).
  """
  def decode(buffer) do
    case buffer do
      <<fin::1, rsv::3, opcode::4, masked::1, len7::7, rest::binary>> ->
        decode_length(fin, rsv, opcode, masked, len7, rest)

      _ ->
        :more
    end
  end

  defp decode_length(_fin, rsv, _opcode, _masked, _len7, _rest) when rsv != 0,
    do: {:error, 1002, "reserved bits are set"}

  defp decode_length(_fin, _rsv, opcode, _masked, _len7, _rest)
       when opcode not in [0, 1, 2, 8, 9, 10],
       do: {:error, 1002, "unknown opcode #{opcode}"}

  defp decode_length(fin, rsv, opcode, masked, 126, rest) do
    case rest do
      <<len::16, rest::binary>> -> decode_payload(fin, rsv, opcode, masked, len, rest)
      _ -> :more
    end
  end

  defp decode_length(fin, rsv, opcode, masked, 127, rest) do
    case rest do
      <<len::64, rest::binary>> -> decode_payload(fin, rsv, opcode, masked, len, rest)
      _ -> :more
    end
  end

  defp decode_length(fin, rsv, opcode, masked, len, rest),
    do: decode_payload(fin, rsv, opcode, masked, len, rest)

  defp decode_payload(fin, _rsv, opcode, _masked, len, _rest)
       when opcode >= 8 and (len > 125 or fin == 0),
       do: {:error, 1002, "a control frame is too long or fragmented"}

  defp decode_payload(_fin, _rsv, _opcode, _masked, len, _rest) when len > @max_payload,
    do: {:error, 1009, "message too big"}

  defp decode_payload(fin, _rsv, opcode, masked, len, rest) do
    key_size = masked * 4

    case rest do
      <<key::binary-size(^key_size), payload::binary-size(^len), rest::binary>> ->
        payload = if masked == 1, do: mask(payload, key), else: payload
        {:ok, %{fin: fin == 1, opcode: opcode, payload: payload, masked: masked == 1}, rest}

      _ ->
        :more
    end
  end

  @doc "XORs `payload` with the 4-byte `key`, repeated (masking and unmasking are the same)."
  def mask(<<>>, _key), do: <<>>

  def mask(payload, key) do
    size = byte_size(payload)
    stream = binary_part(:binary.copy(key, (size >>> 2) + 1), 0, size)
    :crypto.exor(payload, stream)
  end

  @doc "The status code and reason in the payload of a close frame: `{:ok, code | nil, reason}` or `:error`."
  def parse_close(<<>>), do: {:ok, nil, ""}

  def parse_close(<<code::16, reason::binary>>) do
    if valid_close_code?(code) and String.valid?(reason), do: {:ok, code, reason}, else: :error
  end

  def parse_close(_), do: :error

  defp valid_close_code?(code),
    do: code in 1000..1003 or code in 1007..1014 or code in 3000..4999
end
