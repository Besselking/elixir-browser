defmodule Browser.JS.Str do
  @moduledoc """
  Character-indexed string operations for the JavaScript runtime. A string is a UTF-8 binary,
  so the position of the n-th character takes a walk from the start, unless every character is
  one byte: then it is a plain offset. Scripts that scan a long string character by character
  (decoders, tokenizers) would otherwise cost the square of its length, so whether the string
  last asked about is plain ASCII is remembered.
  """

  @small 64

  @doc "Is every character of `s` a single byte?"
  def ascii?(s) when byte_size(s) <= @small, do: scan(s)

  def ascii?(s) do
    case Process.get(:js_str_ascii) do
      {^s, flag} ->
        flag

      _ ->
        flag = scan(s)
        Process.put(:js_str_ascii, {s, flag})
        flag
    end
  end

  defp scan(<<c, rest::binary>>) when c < 128, do: scan(rest)
  defp scan(""), do: true
  defp scan(_), do: false

  # a long string with wider characters: its characters as a tuple, for the last one asked about
  defp chars(s) do
    case Process.get(:js_str_chars) do
      {^s, t} ->
        t

      _ ->
        t = s |> String.codepoints() |> List.to_tuple()
        Process.put(:js_str_chars, {s, t})
        t
    end
  end

  def length(s) do
    cond do
      ascii?(s) -> byte_size(s)
      byte_size(s) <= @small -> String.length(s)
      true -> tuple_size(chars(s))
    end
  end

  @doc "The character at `i` (a string of it) or nil."
  def at(s, i) when i < 0,
    do: if(i + __MODULE__.length(s) < 0, do: nil, else: at(s, i + __MODULE__.length(s)))

  def at(s, i) do
    if ascii?(s) do
      if i < byte_size(s), do: binary_part(s, i, 1)
    else
      if byte_size(s) <= @small do
        String.at(s, i)
      else
        t = chars(s)
        if i < tuple_size(t), do: elem(t, i)
      end
    end
  end

  @doc "`count` characters from `from` (`nil`: to the end)."
  def slice(s, from, count) do
    if ascii?(s) do
      size = byte_size(s)
      from = from |> max(0) |> min(size)
      count = if count == nil, do: size - from, else: count |> max(0) |> min(size - from)
      binary_part(s, from, count)
    else
      codepoints = String.codepoints(s)

      case count do
        nil -> codepoints |> Enum.drop(from) |> Enum.join()
        count -> codepoints |> Enum.slice(from, count) |> Enum.join()
      end
    end
  end

  @doc "The character index of the first `needle` at or after `from`, or -1."
  def index_of(s, needle, from) do
    if ascii?(s) do
      size = byte_size(s)
      from = min(from, size)

      case :binary.match(s, needle, scope: {from, size - from}) do
        {pos, _} -> pos
        :nomatch -> -1
      end
    else
      rest = slice(s, from, nil)

      case :binary.match(rest, needle) do
        {pos, _} -> from + String.length(binary_part(rest, 0, pos))
        :nomatch -> -1
      end
    end
  end
end
