defmodule Browser.Reftest.Picture do
  @moduledoc """
  A small PNG decoder for reftests: the suite's support pictures are plain PNGs, and painting
  them without a window needs their pixels. Supports every colour type and bit depth of
  non-interlaced pictures (16 bits are cut to 8).
  """

  import Bitwise

  @doc """
  `{:ok, %{w:, h:, rows: [binary]}}` where each row is `w` RGBA pixels (4 bytes each), or
  `:error` for anything else than a PNG this decoder handles.
  """
  def decode(<<0x89, "PNG\r\n", 0x1A, 0x0A, rest::binary>>) do
    with {:ok, chunks} <- chunks(rest, []),
         %{ihdr: <<w::32, h::32, depth, ctype, 0, 0, interlace>>} = parts <- group(chunks),
         true <- interlace in [0, 1],
         true <- w > 0 and h > 0 and depth in [1, 2, 4, 8, 16] and ctype in [0, 2, 3, 4, 6],
         {:ok, raw} <- inflate(parts.idat),
         palette = parts[:plte],
         trns = parts[:trns],
         bits = depth * channels(ctype),
         rows when is_list(rows) <-
           scan(raw, w, h, interlace, bits, fn line, n ->
             rgba_row(line, n, depth, ctype, palette, trns)
           end) do
      {:ok, %{w: w, h: h, rows: rows}}
    else
      _ -> :error
    end
  rescue
    _ -> :error
  end

  def decode(_), do: :error

  defp chunks(
         <<len::32, type::binary-size(4), data::binary-size(len), _crc::32, rest::binary>>,
         acc
       ) do
    if type == "IEND", do: {:ok, Enum.reverse(acc)}, else: chunks(rest, [{type, data} | acc])
  end

  defp chunks(_, acc), do: if(acc == [], do: :error, else: {:ok, Enum.reverse(acc)})

  defp group(chunks) do
    Enum.reduce(chunks, %{idat: []}, fn
      {"IHDR", d}, acc -> Map.put(acc, :ihdr, d)
      {"PLTE", d}, acc -> Map.put(acc, :plte, d)
      {"tRNS", d}, acc -> Map.put(acc, :trns, d)
      {"IDAT", d}, acc -> %{acc | idat: [acc.idat, d]}
      _, acc -> acc
    end)
  end

  defp inflate(idat) do
    {:ok, idat |> IO.iodata_to_binary() |> :zlib.uncompress()}
  rescue
    _ -> :error
  end

  defp channels(0), do: 1
  defp channels(2), do: 3
  defp channels(3), do: 1
  defp channels(4), do: 2
  defp channels(6), do: 4

  # The picture's rows as RGBA binaries. `to_rgba.(line, pixel_count)` turns one unfiltered line.
  defp scan(raw, w, h, 0, bits, to_rgba) do
    stride = div(w * bits + 7, 8)
    bpp = max(div(bits, 8), 1)

    if byte_size(raw) >= (stride + 1) * h,
      do: raw |> unfilter(h, stride, bpp) |> Enum.map(&to_rgba.(&1, w))
  end

  # Adam7: seven passes, each a smaller picture of the pixels at its own offsets and steps
  @passes [
    {0, 0, 8, 8},
    {4, 0, 8, 8},
    {0, 4, 4, 8},
    {2, 0, 4, 4},
    {0, 2, 2, 4},
    {1, 0, 2, 2},
    {0, 1, 1, 2}
  ]

  defp scan(raw, w, h, 1, bits, to_rgba) do
    bpp = max(div(bits, 8), 1)

    {pixels, _} =
      Enum.reduce(@passes, {%{}, raw}, fn {x0, y0, dx, dy}, {acc, data} ->
        pw = div(max(w - x0, 0) + dx - 1, dx)
        ph = div(max(h - y0, 0) + dy - 1, dy)

        if pw == 0 or ph == 0 do
          {acc, data}
        else
          stride = div(pw * bits + 7, 8)
          size = (stride + 1) * ph
          <<pass::binary-size(^size), rest::binary>> = data
          lines = unfilter(pass, ph, stride, bpp)

          acc =
            lines
            |> Enum.with_index()
            |> Enum.reduce(acc, fn {line, j}, acc ->
              row = to_rgba.(line, pw)

              for i <- 0..(pw - 1)//1, reduce: acc do
                acc -> Map.put(acc, {x0 + i * dx, y0 + j * dy}, binary_part(row, i * 4, 4))
              end
            end)

          {acc, rest}
        end
      end)

    for y <- 0..(h - 1),
        do: IO.iodata_to_binary(for(x <- 0..(w - 1), do: Map.fetch!(pixels, {x, y})))
  end

  # -- filters ---------------------------------------------------------------------------

  defp unfilter(raw, h, stride, bpp) do
    zero = :binary.copy(<<0>>, stride)

    {lines, _} =
      Enum.map_reduce(0..(h - 1), {raw, zero}, fn _, {data, prev} ->
        <<f, line::binary-size(^stride), rest::binary>> = data
        out = filter(f, line, prev, bpp)
        {out, {rest, out}}
      end)

    lines
  end

  defp filter(0, line, _prev, _bpp), do: line

  defp filter(f, line, prev, bpp) do
    bytes = :binary.bin_to_list(line)
    above = :binary.bin_to_list(prev)
    left = List.duplicate(0, bpp)
    upleft = List.duplicate(0, bpp)
    out = apply_filter(f, bytes, above, left, upleft, [])
    :erlang.list_to_binary(out)
  end

  # `left` and `upleft` hold the last `bpp` bytes of this line and of the one above (oldest first)
  defp apply_filter(_f, [], _above, _left, _upleft, acc), do: Enum.reverse(acc)

  defp apply_filter(f, [x | xs], [b | bs], left, upleft, acc) do
    [a | left_rest] = left
    [c | upleft_rest] = upleft

    v =
      case f do
        1 -> x + a
        2 -> x + b
        3 -> x + ((a + b) >>> 1)
        4 -> x + paeth(a, b, c)
      end

    v = v &&& 255
    apply_filter(f, xs, bs, left_rest ++ [v], upleft_rest ++ [b], [v | acc])
  end

  defp paeth(a, b, c) do
    p = a + b - c
    pa = abs(p - a)
    pb = abs(p - b)
    pc = abs(p - c)

    cond do
      pa <= pb and pa <= pc -> a
      pb <= pc -> b
      true -> c
    end
  end

  # -- pixels ----------------------------------------------------------------------------

  defp rgba_row(line, w, depth, ctype, palette, trns) do
    samples = samples(line, w * channels(ctype), depth)

    pixels =
      case ctype do
        0 -> gray(samples, depth, trns)
        2 -> rgb(samples, depth, trns)
        3 -> indexed(samples, palette || <<>>, trns || <<>>)
        4 -> gray_alpha(samples, depth)
        6 -> rgba(samples, depth)
      end

    IO.iodata_to_binary(pixels)
  end

  # the samples of a line as integers
  defp samples(line, count, 8), do: line |> :binary.bin_to_list() |> Enum.take(count)

  defp samples(line, count, 16),
    do: for(<<hi, _lo <- line>>, do: hi) |> Enum.take(count)

  defp samples(line, count, depth) do
    for(<<byte <- line>>, shift <- shifts(depth), do: byte >>> shift &&& (1 <<< depth) - 1)
    |> Enum.take(count)
  end

  defp shifts(1), do: [7, 6, 5, 4, 3, 2, 1, 0]
  defp shifts(2), do: [6, 4, 2, 0]
  defp shifts(4), do: [4, 0]

  # a sample as 0..255
  defp scale(v, depth) when depth in [8, 16], do: v
  defp scale(v, depth), do: div(v * 255, (1 <<< depth) - 1)

  defp gray(samples, depth, trns) do
    key = with <<_hi, lo>> <- trns, do: lo

    for s <- samples do
      g = scale(s, depth)
      a = if is_integer(key) and depth == 8 and s == key, do: 0, else: 255
      <<g, g, g, a>>
    end
  end

  defp rgb(samples, depth, _trns) do
    samples
    |> Enum.chunk_every(3)
    |> Enum.map(fn [r, g, b] -> <<scale(r, depth), scale(g, depth), scale(b, depth), 255>> end)
  end

  defp indexed(samples, palette, trns) do
    for i <- samples do
      if (i + 1) * 3 <= byte_size(palette) do
        <<r, g, b>> = binary_part(palette, i * 3, 3)
        a = if i < byte_size(trns), do: :binary.at(trns, i), else: 255
        <<r, g, b, a>>
      else
        <<0, 0, 0, 255>>
      end
    end
  end

  defp gray_alpha(samples, depth) do
    samples
    |> Enum.chunk_every(2)
    |> Enum.map(fn [g, a] ->
      <<scale(g, depth), scale(g, depth), scale(g, depth), scale(a, depth)>>
    end)
  end

  defp rgba(samples, depth) do
    samples
    |> Enum.chunk_every(4)
    |> Enum.map(fn [r, g, b, a] ->
      <<scale(r, depth), scale(g, depth), scale(b, depth), scale(a, depth)>>
    end)
  end
end
