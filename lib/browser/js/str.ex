defmodule Browser.JS.Str do
  @moduledoc """
  Code-unit indexed string operations for the JavaScript runtime.

  A string is a UTF-8 binary, but it is measured and indexed the way JavaScript does it, in
  UTF-16 code units: a character outside the BMP is two units, so `'😀'.length` is 2 and
  `'😀'[0]` is the lone high surrogate. A lone surrogate is kept as its three-byte generalised
  UTF-8 form (`ED A0..BF xx`, WTF-8), which is not valid UTF-8 but which a binary can hold; a
  high surrogate followed by a low one is always stored as the single four-byte character
  (`cat/2` and `from_units/1` take care of that when strings are joined).

  The position of the n-th unit takes a walk from the start, unless every character is one byte:
  then it is a plain offset. Scripts that scan a long string character by character (decoders,
  tokenizers) would otherwise cost the square of its length, so whether the string last asked
  about is plain ASCII, and its units, are remembered.
  """

  import Bitwise

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

  # a long string with wider characters: its code units as a tuple, for the last one asked about
  defp units_tuple(s) do
    case Process.get(:js_str_chars) do
      {^s, t} ->
        t

      _ ->
        t = s |> units() |> List.to_tuple()
        Process.put(:js_str_chars, {s, t})
        t
    end
  end

  @doc "The length in UTF-16 code units."
  def length(s) do
    cond do
      ascii?(s) -> byte_size(s)
      byte_size(s) <= @small -> unit_count(s)
      true -> tuple_size(units_tuple(s))
    end
  end

  # every UTF-8 lead byte starts a character (one unit, two outside the BMP)
  defp unit_count(s) do
    for <<b <- s>>, reduce: 0 do
      n ->
        cond do
          b < 0x80 -> n + 1
          b < 0xC0 -> n
          b < 0xF0 -> n + 1
          true -> n + 2
        end
    end
  end

  @doc "The code units of `s`, as a list of integers."
  def units(s), do: decode(s, [])

  defp decode(<<c, rest::binary>>, acc) when c < 0x80, do: decode(rest, [c | acc])

  defp decode(<<c::utf8, rest::binary>>, acc) when c < 0x10000, do: decode(rest, [c | acc])

  defp decode(<<c::utf8, rest::binary>>, acc) do
    c = c - 0x10000
    decode(rest, [0xDC00 + (c &&& 0x3FF), 0xD800 + (c >>> 10) | acc])
  end

  # a lone surrogate, kept as three bytes
  defp decode(<<0xED, b2, b3, rest::binary>>, acc) when b2 in 0xA0..0xBF and b3 in 0x80..0xBF,
    do: decode(rest, [0xD000 + ((b2 &&& 0x3F) <<< 6) + (b3 &&& 0x3F) | acc])

  # anything else is not text
  defp decode(<<_, rest::binary>>, acc), do: decode(rest, [0xFFFD | acc])
  defp decode(<<>>, acc), do: Enum.reverse(acc)

  @doc "A string from code units: surrogate pairs become one character, a lone one stays lone."
  def from_units(units), do: encode(units, [])

  defp encode([h, l | rest], acc) when h in 0xD800..0xDBFF and l in 0xDC00..0xDFFF do
    cp = 0x10000 + ((h - 0xD800) <<< 10) + (l - 0xDC00)
    encode(rest, [<<cp::utf8>> | acc])
  end

  defp encode([u | rest], acc) when u in 0xD800..0xDFFF,
    do: encode(rest, [<<0xED, 0x80 ||| (u >>> 6 &&& 0x3F), 0x80 ||| (u &&& 0x3F)>> | acc])

  defp encode([u | rest], acc), do: encode(rest, [<<u::utf8>> | acc])
  defp encode([], acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  @doc "The unit at `i` (a string of it) or nil."
  def at(s, i) when i < 0,
    do: if(i + __MODULE__.length(s) < 0, do: nil, else: at(s, i + __MODULE__.length(s)))

  def at(s, i) do
    cond do
      ascii?(s) ->
        if i < byte_size(s), do: binary_part(s, i, 1)

      byte_size(s) <= @small ->
        case Enum.at(units(s), i) do
          nil -> nil
          u -> from_units([u])
        end

      true ->
        t = units_tuple(s)
        if i < tuple_size(t), do: from_units([elem(t, i)])
    end
  end

  @doc "The code unit at `i`, or nil."
  def code_unit_at(s, i) when i >= 0 do
    cond do
      ascii?(s) ->
        if i < byte_size(s), do: :binary.at(s, i)

      byte_size(s) <= @small ->
        Enum.at(units(s), i)

      true ->
        t = units_tuple(s)
        if i < tuple_size(t), do: elem(t, i)
    end
  end

  def code_unit_at(_, _), do: nil

  @doc "The code point at `i` (a pair is read as one), or nil."
  def code_point_at(s, i) do
    case code_unit_at(s, i) do
      h when h in 0xD800..0xDBFF ->
        case code_unit_at(s, i + 1) do
          l when l in 0xDC00..0xDFFF -> 0x10000 + ((h - 0xD800) <<< 10) + (l - 0xDC00)
          _ -> h
        end

      u ->
        u
    end
  end

  @doc "`count` units from `from` (`nil`: to the end)."
  def slice(s, from, count) do
    if ascii?(s) do
      size = byte_size(s)
      from = from |> max(0) |> min(size)
      count = if count == nil, do: size - from, else: count |> max(0) |> min(size - from)
      binary_part(s, from, count)
    else
      us = if byte_size(s) <= @small, do: units(s), else: s |> units_tuple() |> Tuple.to_list()
      from = max(from, 0)

      case count do
        nil -> us |> Enum.drop(from) |> from_units()
        count -> us |> Enum.slice(from, max(count, 0)) |> from_units()
      end
    end
  end

  @doc "The unit index of the first `needle` at or after `from`, or -1."
  def index_of(s, "", from), do: min(from, __MODULE__.length(s))

  def index_of(s, needle, from) do
    cond do
      ascii?(s) ->
        size = byte_size(s)
        from = min(from, size)

        case :binary.match(s, needle, scope: {from, size - from}) do
          {pos, _} -> pos
          :nomatch -> -1
        end

      lone?(needle) or lone?(s) ->
        unit_search(units(s), units(needle), from)

      true ->
        rest = slice(s, from, nil)

        case :binary.match(rest, needle) do
          {pos, _} -> from + unit_count(binary_part(rest, 0, pos))
          :nomatch -> -1
        end
    end
  end

  defp unit_search(hay, want, from) do
    n = Kernel.length(want)

    hay
    |> Enum.drop(from)
    |> Enum.chunk_every(n, 1, :discard)
    |> Enum.find_index(&(&1 == want))
    |> case do
      nil -> -1
      i -> from + i
    end
  end

  @doc "The byte offset of the unit index `n` (the start of a character that `n` falls inside)."
  def byte_offset(s, n) do
    if ascii?(s), do: min(max(n, 0), byte_size(s)), else: walk(s, n, 0)
  end

  defp walk(s, n, acc) when n <= 0 or acc >= byte_size(s), do: acc

  defp walk(s, n, acc) do
    b = :binary.at(s, acc)

    {size, weight} =
      cond do
        b < 0x80 -> {1, 1}
        b < 0xE0 -> {2, 1}
        b < 0xF0 -> {3, 1}
        true -> {4, 2}
      end

    if weight > n, do: acc, else: walk(s, n - weight, acc + size)
  end

  # ── lone surrogates ────────────────────────────────────────

  @doc "Does `s` hold a lone surrogate?"
  def lone?(s) do
    case :binary.match(s, <<0xED>>) do
      :nomatch -> false
      _ -> lone_scan(s)
    end
  end

  defp lone_scan(<<0xED, b2, _, _::binary>>) when b2 >= 0xA0, do: true
  defp lone_scan(<<_, rest::binary>>), do: lone_scan(rest)
  defp lone_scan(<<>>), do: false

  @doc "`s` with every lone surrogate replaced by U+FFFD."
  def well_formed(s) do
    if lone?(s),
      do:
        s |> units() |> Enum.map(&if(&1 in 0xD800..0xDFFF, do: 0xFFFD, else: &1)) |> from_units(),
      else: s
  end

  # ── joining and comparing ──────────────────────────────────

  @doc "`a <> b`, joining a lone high surrogate at the end of `a` to a lone low one at the start of `b`."
  def cat(a, b) when byte_size(a) >= 3 and byte_size(b) >= 3 do
    n = byte_size(a)

    with <<0xED, h2, h3>> when h2 in 0xA0..0xAF <- binary_part(a, n - 3, 3),
         <<0xED, l2, l3, rest::binary>> when l2 in 0xB0..0xBF <- b do
      hi = 0xD000 + ((h2 &&& 0x3F) <<< 6) + (h3 &&& 0x3F)
      lo = 0xD000 + ((l2 &&& 0x3F) <<< 6) + (l3 &&& 0x3F)
      cp = 0x10000 + ((hi - 0xD800) <<< 10) + (lo - 0xDC00)
      binary_part(a, 0, n - 3) <> <<cp::utf8>> <> rest
    else
      _ -> a <> b
    end
  end

  def cat(a, b), do: a <> b

  @doc "Joins a list of strings (with `sep`), merging a high surrogate to a low one at each seam."
  def join(list, sep \\ "")
  def join([], _), do: ""
  def join([h | t], sep), do: Enum.reduce(t, h, fn x, acc -> cat(cat(acc, sep), x) end)

  @doc "Compares two strings by UTF-16 code units: `:lt`, `:eq` or `:gt`."
  def compare(a, a), do: :eq

  def compare(a, b) do
    n = :binary.longest_common_prefix([a, b])

    cond do
      n == byte_size(a) ->
        :lt

      n == byte_size(b) ->
        :gt

      true ->
        n = char_start(a, n)
        ua = first_unit(binary_part(a, n, byte_size(a) - n))
        ub = first_unit(binary_part(b, n, byte_size(b) - n))

        cond do
          ua < ub -> :lt
          ua > ub -> :gt
          true -> if units(a) < units(b), do: :lt, else: :gt
        end
    end
  end

  defp char_start(s, n) when n > 0 do
    if :binary.at(s, n) in 0x80..0xBF, do: char_start(s, n - 1), else: n
  end

  defp char_start(_, n), do: n

  # the first code unit of the character at the start of `s`
  defp first_unit(s) do
    case decode(binary_part(s, 0, min(byte_size(s), 4)) |> first_char(), []) do
      [h, _ | _] -> h
      [u | _] -> u
    end
  end

  defp first_char(<<c, _::binary>> = s) when c < 0xC0, do: binary_part(s, 0, 1)
  defp first_char(<<c, _::binary>> = s) when c < 0xE0, do: binary_part(s, 0, min(2, byte_size(s)))
  defp first_char(<<c, _::binary>> = s) when c < 0xF0, do: binary_part(s, 0, min(3, byte_size(s)))
  defp first_char(s), do: s

  # ── iteration ──────────────────────────────────────────────

  @doc "The code points of `s` as strings; a lone surrogate is a code point of its own."
  def codepoints(s) do
    if String.valid?(s) do
      String.codepoints(s)
    else
      s |> units() |> pair_up([])
    end
  end

  defp pair_up([h, l | rest], acc) when h in 0xD800..0xDBFF and l in 0xDC00..0xDFFF,
    do: pair_up(rest, [from_units([h, l]) | acc])

  defp pair_up([u | rest], acc), do: pair_up(rest, [from_units([u]) | acc])
  defp pair_up([], acc), do: Enum.reverse(acc)
end
