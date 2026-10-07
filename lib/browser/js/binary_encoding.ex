defmodule Browser.JS.BinaryEncoding do
  @moduledoc """
  The pure part of `Uint8Array.fromBase64`, `fromHex`, `setFromBase64`, `setFromHex`,
  `toBase64` and `toHex`: decoding and encoding between strings and bytes.

  The decoders return `{status, read, bytes}`: `status` is `:ok` or `:error` (a SyntaxError for
  the caller to throw after writing the bytes decoded up to then), `read` the number of
  characters consumed and `bytes` what was decoded.
  """

  @std ~c"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
  @url ~c"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
  @ws [?\t, ?\n, ?\f, ?\r, ?\s]
  @index @std |> Enum.with_index() |> Map.new()

  def encode_base64(bytes, alphabet, omit_padding) do
    table = if alphabet == "base64url", do: @url, else: @std
    t = List.to_tuple(table)
    out = do_encode(bytes, t, [])
    s = IO.iodata_to_binary(out)

    if omit_padding, do: s, else: s <> pad(byte_size(bytes))
  end

  defp pad(n) do
    case rem(n, 3) do
      0 -> ""
      1 -> "=="
      2 -> "="
    end
  end

  defp do_encode(<<a::6, b::6, c::6, d::6, rest::binary>>, t, acc),
    do: do_encode(rest, t, [acc, elem(t, a), elem(t, b), elem(t, c), elem(t, d)])

  defp do_encode(<<a::6, b::2>>, t, acc), do: [acc, elem(t, a), elem(t, b * 16)]

  defp do_encode(<<a::6, b::6, c::4>>, t, acc),
    do: [acc, elem(t, a), elem(t, b), elem(t, c * 4)]

  defp do_encode(<<>>, _t, acc), do: acc

  def encode_hex(bytes), do: Base.encode16(bytes, case: :lower)

  # ── decoding ───────────────────────────────────────────────

  def decode_hex(str, max) do
    if rem(byte_size(str), 2) != 0 do
      {:error, 0, <<>>}
    else
      hex(str, max, 0, [])
    end
  end

  defp hex(<<>>, _max, read, acc), do: {:ok, read, done(acc)}
  defp hex(_, max, read, acc) when length(acc) >= max, do: {:ok, read, done(acc)}

  defp hex(<<a, b, rest::binary>>, max, read, acc) do
    with {:ok, x} <- hexval(a), {:ok, y} <- hexval(b) do
      hex(rest, max, read + 2, [x * 16 + y | acc])
    else
      _ -> {:error, read, done(acc)}
    end
  end

  defp hexval(c) when c in ?0..?9, do: {:ok, c - ?0}
  defp hexval(c) when c in ?a..?f, do: {:ok, c - ?a + 10}
  defp hexval(c) when c in ?A..?F, do: {:ok, c - ?A + 10}
  defp hexval(_), do: :error

  defp done(acc), do: acc |> Enum.reverse() |> :erlang.list_to_binary()

  def decode_base64(_str, _alphabet, _last, 0), do: {:ok, 0, <<>>}

  def decode_base64(str, alphabet, last, max) do
    state = %{
      s: str,
      len: byte_size(str),
      alpha: alphabet,
      last: last,
      max: max,
      read: 0,
      bytes: [],
      nbytes: 0,
      chunk: []
    }

    loop(skip_ws(state, 0), state)
  end

  defp skip_ws(%{s: s, len: len}, i) do
    if i < len and :binary.at(s, i) in @ws, do: skip_ws(%{s: s, len: len}, i + 1), else: i
  end

  defp result(st, status, read), do: {status, read, done(st.bytes)}

  defp add(st, decoded),
    do: %{
      st
      | bytes: Enum.reverse(:binary.bin_to_list(decoded)) ++ st.bytes,
        nbytes: st.nbytes + byte_size(decoded)
    }

  # decode a partial chunk of 2, 3 or 4 characters
  defp chunk_bytes(chunk, strict) do
    vals = chunk |> Enum.reverse() |> Enum.map(&Map.fetch!(@index, &1))
    n = length(vals)
    padded = vals ++ List.duplicate(0, 4 - n)
    [a, b, c, d] = padded
    <<x, y, z>> = <<a::6, b::6, c::6, d::6>>

    case n do
      4 ->
        {:ok, <<x, y, z>>}

      3 ->
        if (strict and z != 0) or (strict and rem(c, 4) != 0),
          do: :error,
          else: {:ok, <<x, y>>}

      2 ->
        if strict and rem(b, 16) != 0, do: :error, else: {:ok, <<x>>}
    end
  end

  defp loop(i, st) do
    cond do
      i >= st.len -> finish(st)
      true -> char(:binary.at(st.s, i), i + 1, st)
    end
  end

  defp finish(st) do
    n = length(st.chunk)

    cond do
      n == 0 ->
        result(st, :ok, st.len)

      st.last == "stop-before-partial" ->
        result(st, :ok, st.read)

      st.last == "loose" and n != 1 ->
        {:ok, d} = chunk_bytes(st.chunk, false)
        st = add(st, d)
        result(st, :ok, st.len)

      true ->
        result(st, :error, st.read)
    end
  end

  defp char(?=, i, st) do
    n = length(st.chunk)

    if n < 2 do
      result(st, :error, st.read)
    else
      i = skip_ws(st, i)

      cond do
        n == 2 and i >= st.len ->
          if st.last == "stop-before-partial",
            do: result(st, :ok, st.read),
            else: result(st, :error, st.read)

        true ->
          i =
            if n == 2 and :binary.at(st.s, i) == ?=, do: skip_ws(st, i + 1), else: i

          if i < st.len do
            result(st, :error, st.read)
          else
            case chunk_bytes(st.chunk, st.last == "strict") do
              {:ok, d} -> result(add(st, d), :ok, st.len)
              :error -> result(st, :error, st.read)
            end
          end
      end
    end
  end

  defp char(c, i, st) do
    c =
      cond do
        st.alpha == "base64url" and c in [?+, ?/] -> nil
        st.alpha == "base64url" and c == ?- -> ?+
        st.alpha == "base64url" and c == ?_ -> ?/
        true -> c
      end

    cond do
      c == nil or not is_map_key(@index, c) ->
        result(st, :error, st.read)

      true ->
        n = length(st.chunk)
        remaining = st.max - st.nbytes

        if (remaining == 1 and n == 2) or (remaining == 2 and n == 3) do
          result(st, :ok, st.read)
        else
          st = %{st | chunk: [c | st.chunk]}

          if n + 1 == 4 do
            {:ok, d} = chunk_bytes(st.chunk, false)
            st = add(%{st | chunk: [], read: i}, d)

            if st.nbytes == st.max,
              do: result(st, :ok, i),
              else: loop(skip_ws(st, i), st)
          else
            loop(skip_ws(st, i), st)
          end
        end
    end
  end
end
