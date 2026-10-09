defmodule Browser.WebSocketTest do
  use ExUnit.Case, async: true
  alias Browser.WebSocket, as: WS

  test "the accept value of RFC 6455" do
    assert WS.accept_for("dGhlIHNhbXBsZSBub25jZQ==") == "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="
  end

  test "frames of RFC 6455 section 5.7" do
    assert {:ok, %{fin: true, opcode: 1, payload: "Hello", masked: false}, ""} =
             WS.decode(<<0x81, 0x05, 0x48, 0x65, 0x6C, 0x6C, 0x6F>>)

    masked = <<0x81, 0x85, 0x37, 0xFA, 0x21, 0x3D, 0x7F, 0x9F, 0x4D, 0x51, 0x58>>
    assert {:ok, %{opcode: 1, payload: "Hello", masked: true}, ""} = WS.decode(masked)

    # a fragmented message, a ping and a pong
    assert {:ok, %{fin: false, opcode: 1, payload: "Hel"}, rest} =
             WS.decode(<<0x01, 0x03, 0x48, 0x65, 0x6C, 0x80, 0x02, 0x6C, 0x6F>>)

    assert {:ok, %{fin: true, opcode: 0, payload: "lo"}, ""} = WS.decode(rest)
    assert {:ok, %{opcode: 9, payload: "Hello"}, ""} = WS.decode(<<0x89, 0x05, "Hello">>)
  end

  test "length forms and masking round trip" do
    for size <- [0, 1, 125, 126, 300, 65_535, 65_536, 70_000] do
      payload = :crypto.strong_rand_bytes(size)

      for mask <- [true, false] do
        bytes = WS.encode(2, payload, mask: mask)
        assert {:ok, %{opcode: 2, payload: ^payload, masked: ^mask}, ""} = WS.decode(bytes)
        # every shorter prefix is incomplete
        assert WS.decode(binary_part(bytes, 0, byte_size(bytes) - 1)) == :more
      end
    end
  end

  test "protocol errors" do
    assert {:error, 1002, _} = WS.decode(<<0xC1, 0x00>>)
    assert {:error, 1002, _} = WS.decode(<<0x83, 0x00>>)
    # a control frame may not be fragmented or long
    assert {:error, 1002, _} = WS.decode(<<0x09, 0x00>>)
    assert {:error, 1002, _} = WS.decode(<<0x88, 126, 0, 126>>)
    assert {:error, 1009, _} = WS.decode(<<0x82, 127, 0, 0, 0, 0, 0x10, 0, 0, 0>>)
  end

  test "close payloads" do
    assert WS.parse_close(<<>>) == {:ok, nil, ""}
    assert WS.parse_close(WS.close_payload(1000, "bye")) == {:ok, 1000, "bye"}
    assert WS.parse_close(<<1005::16>>) == :error
    assert WS.parse_close(<<1000::16, 0xFF>>) == :error
    assert WS.parse_close(<<1>>) == :error
  end

  test "the upgrade request and the check of its answer" do
    uri = URI.parse("ws://example.test:8080/chat?room=1")
    key = WS.new_key()

    request =
      WS.request(uri,
        key: key,
        origin: "http://page.test",
        protocols: ["a", "b"],
        cookie: "k=v"
      )

    assert request =~ "GET /chat?room=1 HTTP/1.1\r\n"
    assert request =~ "Host: example.test:8080\r\n"
    assert request =~ "Sec-WebSocket-Protocol: a, b\r\n"
    assert request =~ "Origin: http://page.test\r\n"
    assert request =~ "Cookie: k=v\r\n"
    assert String.ends_with?(request, "\r\n\r\n")

    answer =
      "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nconnection: keep-alive, Upgrade\r\n" <>
        "Sec-WebSocket-Accept: #{WS.accept_for(key)}\r\nSec-WebSocket-Protocol: b\r\n\r\nrest"

    assert {:ok, 101, headers, "rest"} = WS.parse_response(answer)
    assert WS.check_response(101, headers, key, ["a", "b"]) == {:ok, "b"}
    assert {:error, _} = WS.check_response(101, headers, key, ["a"])
    assert {:error, _} = WS.check_response(101, headers, WS.new_key(), ["a", "b"])
    assert {:error, _} = WS.check_response(200, headers, key, ["a", "b"])
    assert WS.parse_response("HTTP/1.1 101 x\r\nUpgrade: websocket") == :more
  end
end
