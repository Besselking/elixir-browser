defmodule Browser.Favicon do
  @moduledoc """
  The small picture a tab shows for its page: which address it comes from (`url/3`, from the
  page's `<link rel="icon">` elements, else `/favicon.ico` of the site) and how its bytes are
  read (`fetch/2`, `decode/2`). ICO files are read here, the toolkit gets plain pixels.
  """

  alias Browser.{Fetch, Images}

  # the size the strip draws icons at
  @size 16
  @max_bytes 1_000_000

  def size, do: @size

  @doc """
  The address of the icon of the page `raw` (the parsed tree) fetched from `url`, with
  relative addresses resolved against `base`; nil when there is none to fetch.
  """
  def url(raw, url, base \\ nil) do
    base = base || url

    case raw |> links() |> pick() do
      nil -> fallback(url)
      href -> Fetch.resolve(base, href)
    end
  end

  # pages from a server have `/favicon.ico` when they name no icon; local pages have none
  defp fallback(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host}
      when scheme in ["http", "https"] and host not in [nil, ""] ->
        Fetch.resolve(url, "/favicon.ico")

      _ ->
        nil
    end
  end

  defp fallback(_), do: nil

  @doc """
  The `{rel, href, sizes, type}` of each `<link>` in the tree that names an icon, in document
  order (`rel` lower-cased; `sizes` a list of the largest side of each size, `:any` for "any").
  """
  def links(raw) do
    raw |> List.wrap() |> collect([]) |> Enum.reverse()
  end

  defp collect([], acc), do: acc
  defp collect([node | rest], acc), do: collect(rest, collect_node(node, acc))

  defp collect_node({:element, "link", attrs, _}, acc) do
    rel = attr(attrs, "rel") |> String.downcase() |> String.split()
    href = attr(attrs, "href") |> String.trim()

    cond do
      href == "" ->
        acc

      "icon" in rel ->
        [{:icon, href, sizes(attr(attrs, "sizes")), attr(attrs, "type")} | acc]

      "apple-touch-icon" in rel or "apple-touch-icon-precomposed" in rel ->
        [{:touch, href, sizes(attr(attrs, "sizes")), attr(attrs, "type")} | acc]

      true ->
        acc
    end
  end

  # icons belong in the head; scripts and templates in the body are not looked into
  defp collect_node({:element, tag, _, _}, acc) when tag in ["body", "template", "svg"], do: acc
  defp collect_node({:element, _, _, kids}, acc), do: collect(kids, acc)
  defp collect_node(_, acc), do: acc

  defp attr(attrs, name), do: List.keyfind(attrs, name, 0, {nil, ""}) |> elem(1) |> to_string()

  defp sizes(text) do
    text
    |> String.downcase()
    |> String.split()
    |> Enum.flat_map(fn
      "any" ->
        [:any]

      size ->
        case String.split(size, "x") do
          [w, h] ->
            with {w, ""} <- Integer.parse(w),
                 {h, ""} <- Integer.parse(h),
                 do: [max(w, h)],
                 else: (_ -> [])

          _ ->
            []
        end
    end)
  end

  @doc """
  The href of the best icon among `links/1`: a `rel="icon"` before an Apple touch icon; of
  those, one with a size of 16 to 64 px (the nearest to 32), then a scalable one, then one
  without sizes (the last of them, as browsers do), then the smallest.
  """
  def pick(links) do
    icons = Enum.filter(links, &(elem(&1, 0) == :icon))
    from = if icons == [], do: links, else: icons
    if from != [], do: from |> Enum.with_index() |> Enum.min_by(&rank/1) |> elem(0) |> elem(1)
  end

  defp rank({{_, href, sizes, type}, i}) do
    svg? = type == "image/svg+xml" or String.ends_with?(String.downcase(href), ".svg")
    sized = Enum.filter(sizes, &is_integer/1)

    cond do
      Enum.any?(sized, &(&1 in 16..64)) ->
        {0, sized |> Enum.filter(&(&1 in 16..64)) |> Enum.map(&abs(&1 - 32)) |> Enum.min(), i}

      :any in sizes or svg? ->
        {1, 0, -i}

      sized == [] ->
        {2, 0, -i}

      true ->
        {3, Enum.min(sized), i}
    end
  end

  # -- reading ---------------------------------------------------------------------------

  @doc """
  Fetches the icon at `url` for the page at `page_url` (through the HTTP cache) and decodes
  it, see `decode/2`.
  """
  def fetch(url, page_url) do
    load =
      case url do
        "data:" <> _ -> Images.decode_data_url(url)
        _ -> with {:ok, body, _final} <- Fetch.load(url, initiator: page_url), do: {:ok, body}
      end

    with {:ok, bytes} <- load do
      if byte_size(bytes) > @max_bytes, do: {:error, "icon too large"}, else: decode(bytes)
    end
  end

  @doc """
  Reads icon bytes: `{:ok, {:image, bytes, format}}` for a file the toolkit decodes (PNG,
  GIF, JPEG, BMP, WebP), `{:ok, {:rgba, w, h, rgb, alpha}}` for an ICO picture,
  `{:ok, {:svg, scene}}` for SVG, or `{:error, reason}`. Of the pictures in an ICO file, the
  smallest one at least `size` px wide is taken (else the largest).
  """
  def decode(bytes, size \\ @size)

  def decode(<<0, 0, type::little-16, count::little-16, _::binary>> = bytes, size)
      when type in [1, 2] and count > 0 do
    ico(bytes, count, size)
  end

  def decode(bytes, _size) do
    case Images.sniff(bytes) do
      format when format in [:png, :gif, :jpeg, :bmp, :webp] ->
        {:ok, {:image, bytes, format}}

      :svg ->
        with {:ok, scene} <- Browser.Svg.from_source(bytes), do: {:ok, {:svg, scene}}

      _ ->
        {:error, "unknown icon format"}
    end
  end

  # -- ICO -------------------------------------------------------------------------------

  defp ico(bytes, count, size) do
    entries =
      for i <- 0..(count - 1),
          offset = 6 + i * 16,
          offset + 16 <= byte_size(bytes),
          <<w, h, _colors, _, _planes::little-16, bpp::little-16, len::little-32, at::little-32>> =
            binary_part(bytes, offset, 16),
          at + len <= byte_size(bytes) and len > 0 do
        %{
          w: if(w == 0, do: 256, else: w),
          h: if(h == 0, do: 256, else: h),
          bpp: bpp,
          data: binary_part(bytes, at, len)
        }
      end

    {big_enough, small} = Enum.split_with(entries, &(&1.w >= size))

    best =
      case big_enough do
        [] -> Enum.max_by(small, &{&1.w, &1.bpp}, fn -> nil end)
        list -> Enum.min_by(list, &{&1.w, -&1.bpp})
      end

    case best do
      nil -> {:error, "empty icon"}
      %{data: <<0x89, "PNG", _::binary>> = png} -> {:ok, {:image, png, :png}}
      %{data: dib} -> dib(dib)
    end
  end

  # a device-independent bitmap without its file header; its height counts the colour
  # rows and the mask rows below them
  defp dib(
         <<hsize::little-32, w::little-signed-32, h2::little-signed-32, _planes::little-16,
           bpp::little-16, compression::little-32, _::binary>> = dib
       )
       when hsize >= 40 and w > 0 and w <= 256 and h2 > 0 and bpp in [1, 4, 8, 24, 32] and
              compression in [0, 3] do
    h = div(h2, 2)
    colors = if bpp <= 8, do: palette_count(dib, bpp), else: 0
    # BI_BITFIELDS keeps three masks after the header (the usual BGRA order is assumed)
    extra = if compression == 3, do: 12, else: 0
    palette_at = hsize + extra
    pixels_at = palette_at + colors * 4
    stride = div(w * bpp + 31, 32) * 4
    mask_stride = div(w + 31, 32) * 4
    mask_at = pixels_at + stride * h

    if h > 0 and pixels_at + stride * h <= byte_size(dib) do
      palette =
        for i <- 0..(colors - 1)//1, into: %{} do
          <<b, g, r, _>> = binary_part(dib, palette_at + i * 4, 4)
          {i, {r, g, b}}
        end

      has_mask = mask_at + mask_stride * h <= byte_size(dib)

      # rows are stored bottom up
      rows =
        for y <- (h - 1)..0//-1 do
          row = binary_part(dib, pixels_at + y * stride, stride)
          mask = if has_mask, do: binary_part(dib, mask_at + y * mask_stride, mask_stride)
          {row_pixels(row, w, bpp, palette), mask}
        end

      own_alpha? =
        bpp == 32 and Enum.any?(rows, fn {px, _} -> Enum.any?(px, fn {_, a} -> a > 0 end) end)

      {rgb, alpha} =
        Enum.reduce(rows, {[], []}, fn {px, mask}, {rgb, alpha} ->
          bits = mask_bits(mask, w)

          {row_rgb, row_alpha} =
            px
            |> Enum.zip(bits)
            |> Enum.map(fn {{{r, g, b}, a}, bit} ->
              a = if own_alpha?, do: a, else: if(bit == 1, do: 0, else: 255)
              {<<r, g, b>>, a}
            end)
            |> Enum.unzip()

          {[rgb | row_rgb], [alpha | row_alpha]}
        end)

      {:ok, {:rgba, w, h, IO.iodata_to_binary(rgb), :erlang.list_to_binary(alpha)}}
    else
      {:error, "short icon"}
    end
  end

  defp dib(_), do: {:error, "unsupported icon"}

  defp palette_count(<<_::binary-size(32), used::little-32, _::binary>>, bpp),
    do: if(used > 0 and used <= 256, do: used, else: Bitwise.bsl(1, bpp))

  defp row_pixels(row, w, 32, _),
    do: for(<<b, g, r, a <- row>>, do: {{r, g, b}, a}) |> Enum.take(w)

  defp row_pixels(row, w, 24, _),
    do: for(<<b, g, r <- row>>, do: {{r, g, b}, 255}) |> Enum.take(w)

  defp row_pixels(row, w, bpp, palette) do
    for(<<i::size(^bpp) <- row>>, do: {Map.get(palette, i, {0, 0, 0}), 255}) |> Enum.take(w)
  end

  defp mask_bits(nil, w), do: List.duplicate(0, w)
  defp mask_bits(mask, w), do: for(<<bit::1 <- mask>>, do: bit) |> Enum.take(w)
end
