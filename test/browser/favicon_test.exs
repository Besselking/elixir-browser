defmodule Browser.FaviconTest do
  use ExUnit.Case, async: true
  alias Browser.{Favicon, HTML}

  defp icon_url(head, url \\ "https://example.com/a/page.html") do
    "<!doctype html><html><head>#{head}</head><body><p>x</p></body></html>"
    |> HTML.parse_document()
    |> Favicon.url(url)
  end

  test "a link rel=icon is resolved against the page" do
    assert icon_url(~s(<link rel="icon" href="pic.png">)) == "https://example.com/a/pic.png"

    assert icon_url(~s(<link rel="shortcut icon" href="/f.ico">)) ==
             "https://example.com/f.ico"

    assert icon_url(~s(<link rel="Icon" href="//cdn.example.org/i.svg">)) ==
             "https://cdn.example.org/i.svg"
  end

  test "without a link, a site's /favicon.ico; local pages have none" do
    assert icon_url("<title>t</title>") == "https://example.com/favicon.ico"
    assert icon_url("<title>t</title>", "file:///tmp/a.html") == nil
    assert icon_url("<title>t</title>", "about:home") == nil

    assert icon_url(~s(<link rel="icon" href="i.png">), "file:///tmp/a.html") ==
             "file:///tmp/i.png"
  end

  test "a <base href> moves where the icon is looked for" do
    raw =
      HTML.parse_document(~s(<head><base href="https://b.example/x/"><link rel=icon href=i.png>))

    assert Favicon.url(raw, "https://a.example/", "https://b.example/x/") ==
             "https://b.example/x/i.png"
  end

  test "the icon nearest 32 px is picked, then scalable, then unsized, then touch icons" do
    assert icon_url("""
           <link rel="icon" href="big.png" sizes="192x192">
           <link rel="icon" href="16.png" sizes="16x16">
           <link rel="icon" href="32.png" sizes="32x32">
           <link rel="apple-touch-icon" href="touch.png">
           """) =~ "/32.png"

    assert icon_url("""
           <link rel="icon" href="plain.ico">
           <link rel="icon" href="v.svg" type="image/svg+xml">
           <link rel="icon" href="big.png" sizes="192x192">
           """) =~ "/v.svg"

    assert icon_url("""
           <link rel="icon" href="a.ico">
           <link rel="icon" href="b.ico">
           """) =~ "/b.ico"

    assert icon_url(
             ~s(<link rel="icon" href="big.png" sizes="512x512"><link rel="icon" href="m.png" sizes="96x96">)
           ) =~
             "/m.png"

    assert icon_url(~s(<link rel="apple-touch-icon" href="touch.png">)) =~ "/touch.png"

    assert icon_url(~s(<link rel="stylesheet" href="s.css"><link rel="icon" href="">)) =~
             "/favicon.ico"
  end

  test "image formats pass through, SVG is parsed" do
    png = <<0x89, "PNG\r\n", 0x1A, 0x0A, 0::64>>
    assert {:ok, {:image, ^png, :png}} = Favicon.decode(png)
    assert {:ok, {:image, _, :gif}} = Favicon.decode("GIF89a" <> <<0::64>>)

    svg =
      ~s(<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16"><rect width="16" height="16"/></svg>)

    assert {:ok, {:svg, _scene}} = Favicon.decode(svg)
    assert {:error, _} = Favicon.decode("<html>not found</html>")
  end

  # an ICO file of `entries`: `{width, bpp, data}`
  defp ico(entries) do
    header = <<0::little-16, 1::little-16, length(entries)::little-16>>

    {dir, blobs, _} =
      Enum.reduce(entries, {"", "", 6 + 16 * length(entries)}, fn {w, bpp, data},
                                                                  {dir, blobs, at} ->
        entry =
          <<w, w, 0, 0, 1::little-16, bpp::little-16, byte_size(data)::little-32, at::little-32>>

        {dir <> entry, blobs <> data, at + byte_size(data)}
      end)

    header <> dir <> blobs
  end

  defp dib_header(w, h, bpp, colors \\ 0),
    do:
      <<40::little-32, w::little-signed-32, 2 * h::little-signed-32, 1::little-16, bpp::little-16,
        0::little-32, 0::little-32, 0::little-32, 0::little-32, colors::little-32, 0::little-32>>

  test "a 32-bit ICO picture keeps its alpha, rows top down" do
    # 2x2, bottom row first: blue, green / red, half-transparent white
    pixels = <<255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 255, 255, 255, 128>>
    mask = <<0::32, 0::32>>
    data = dib_header(2, 2, 32) <> pixels <> mask

    assert {:ok, {:rgba, 2, 2, rgb, alpha}} = Favicon.decode(ico([{2, 32, data}]))
    assert rgb == <<255, 0, 0, 255, 255, 255, 0, 0, 255, 0, 255, 0>>
    assert alpha == <<255, 128, 255, 255>>
  end

  test "a paletted ICO picture takes its transparency from the mask" do
    # 2x2 at 1 bit: colour 0 black, colour 1 white; the top-left pixel is masked out
    palette = <<0, 0, 0, 0, 255, 255, 255, 0>>
    # bottom row: 1, 0; top row: 0, 1 (each row padded to 4 bytes)
    pixels = <<0b10000000, 0, 0, 0, 0b01000000, 0, 0, 0>>
    mask = <<0, 0, 0, 0, 0b10000000, 0, 0, 0>>
    data = dib_header(2, 2, 1, 2) <> palette <> pixels <> mask

    assert {:ok, {:rgba, 2, 2, rgb, alpha}} = Favicon.decode(ico([{2, 1, data}]))
    assert rgb == <<0, 0, 0, 255, 255, 255, 255, 255, 255, 0, 0, 0>>
    assert alpha == <<0, 255, 255, 255>>
  end

  test "of an ICO's pictures the smallest one at least 16 px wide is used; PNG ones too" do
    png = <<0x89, "PNG\r\n", 0x1A, 0x0A, 1::64>>
    small = dib_header(8, 8, 32) <> :binary.copy(<<0>>, 8 * 8 * 4 + 8 * 4)

    file = ico([{8, 32, small}, {48, 32, <<0x89, "PNG\r\n", 0x1A, 0x0A, 2::64>>}, {32, 32, png}])
    assert {:ok, {:image, ^png, :png}} = Favicon.decode(file)

    # all too small: the largest one
    assert {:ok, {:rgba, 8, 8, _, _}} = Favicon.decode(ico([{8, 32, small}]))
    assert {:error, _} = Favicon.decode(<<0, 0, 1, 0, 1, 0>> <> :binary.copy(<<0>>, 16))
  end
end
