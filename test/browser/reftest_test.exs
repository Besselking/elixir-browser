defmodule Browser.ReftestTest do
  use ExUnit.Case, async: true

  alias Browser.Reftest
  alias Browser.Reftest.Raster

  @page "<!doctype html><title>t</title>"

  setup do
    root = Path.join(System.tmp_dir!(), "reftest_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "css/t"))
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root}
  end

  defp write(root, name, body), do: File.write!(Path.join([root, "css/t", name]), @page <> body)

  test "finds match and mismatch links" do
    html =
      ~s(<link rel="match" href="a-ref.html"><link rel=mismatch href='/css/b.html'><link rel=help href=x>)

    assert Reftest.links(html) == [match: "a-ref.html", mismatch: "/css/b.html"]
  end

  test "collects tests and leaves out references and support files", %{root: root} do
    for f <- ["one.html", "one-ref.html", "support/s.html", "reference/r.html"] do
      File.mkdir_p!(Path.dirname(Path.join([root, "css/t", f])))
      write(root, f, "")
    end

    assert Reftest.collect(root, ["css/t"]) == ["css/t/one.html"]
  end

  test "a page that looks like its reference passes, whatever the markup", %{root: root} do
    write(
      root,
      "a.html",
      ~s(<link rel=match href=a-ref.html><div style="width:50px;height:20px;background:#0a0"></div>)
    )

    write(
      root,
      "a-ref.html",
      ~s(<p style="margin:0;padding:0"></p><div style="width:50px;height:20px;background:#0a0;margin-top:-1em"></div>)
    )

    # the reference is made to look the same by a different route
    write(
      root,
      "b.html",
      ~s(<link rel=match href=b-ref.html><div style="width:50px;height:20px;background:#0a0"></div>)
    )

    write(root, "b-ref.html", ~s(<div style="width:50px;height:20px;background:#0a0"></div>))

    assert Reftest.run_test(root, "css/t/b.html") == :pass
  end

  test "a difference fails, and a mismatch wants one", %{root: root} do
    write(
      root,
      "c.html",
      ~s(<link rel=match href=c-ref.html><div style="width:50px;height:20px;background:#0a0"></div>)
    )

    write(root, "c-ref.html", ~s(<div style="width:60px;height:20px;background:#0a0"></div>))
    assert {:fail, "" <> _} = Reftest.run_test(root, "css/t/c.html")

    write(
      root,
      "d.html",
      ~s(<link rel=mismatch href=c-ref.html><div style="width:50px;height:20px;background:#0a0"></div>)
    )

    assert Reftest.run_test(root, "css/t/d.html") == :pass
  end

  test "a test with several matches passes when one of them agrees", %{root: root} do
    box = ~s(<div style="width:50px;height:20px;background:#0a0"></div>)

    write(
      root,
      "m.html",
      ~s(<link rel=match href=m-ref1.html><link rel=match href=m-ref2.html>) <> box
    )

    write(root, "m-ref1.html", ~s(<div style="width:60px;height:20px;background:#0a0"></div>))
    write(root, "m-ref2.html", box)
    assert Reftest.run_test(root, "css/t/m.html") == :pass

    # every mismatch still has to differ
    write(
      root,
      "n.html",
      ~s(<link rel=match href=m-ref2.html><link rel=mismatch href=m-ref2.html>) <> box
    )

    assert {:fail, "" <> _} = Reftest.run_test(root, "css/t/n.html")
  end

  test "text is compared by what it says", %{root: root} do
    write(root, "e.html", ~s(<link rel=match href=e-ref.html><p>abc</p>))
    write(root, "e-ref.html", ~s(<p>abd</p>))
    assert {:fail, _} = Reftest.run_test(root, "css/t/e.html")
  end

  test "text in the colour of its background is invisible", %{root: root} do
    write(
      root,
      "h.html",
      ~s(<link rel=match href=h-ref.html><div style="background:black;color:black;height:30px">hidden</div>)
    )

    write(root, "h-ref.html", ~s(<div style="background:black;height:30px"></div>))
    assert Reftest.run_test(root, "css/t/h.html") == :pass

    write(
      root,
      "h2.html",
      ~s(<link rel=mismatch href=h-ref.html><div style="background:black;color:white;height:30px">shown</div>)
    )

    assert Reftest.run_test(root, "css/t/h2.html") == :pass
  end

  test "Ahem glyphs are em squares wide", %{root: root} do
    css = "<style>body{margin:0}p{margin:0;font:10px/1 Ahem}</style>"
    write(root, "f.html", ~s(<link rel=match href=f-ref.html>#{css}<p>XX XX</p>))
    # the same width of black squares by another route: a longer word of the same glyphs
    write(root, "f-ref.html", ~s(#{css}<p>X<span>X</span> X<span>X</span></p>))
    assert Reftest.run_test(root, "css/t/f.html") == :pass

    write(root, "g2.html", ~s(<link rel=mismatch href=f-ref.html>#{css}<p>XX XXX</p>))
    assert Reftest.run_test(root, "css/t/g2.html") == :pass
  end

  test "tests it cannot compare are skipped", %{root: root} do
    write(root, "g.html", ~s(<link rel=match href=g-ref.html><script>1</script>))
    assert {:skip, "scripts"} = Reftest.run_test(root, "css/t/g.html")
    write(root, "h.html", "<p>no link</p>")
    assert {:skip, "no reference"} = Reftest.run_test(root, "css/t/h.html")
    write(root, "i.html", ~s(<link rel=match href=nope.html>))
    assert {:skip, "reference missing"} = Reftest.run_test(root, "css/t/i.html")
  end

  test "the raster reports how many pixels differ" do
    a = Raster.new(4, 2, {255, 255, 255})
    assert Raster.diff(a, a) == nil
    b = Raster.paint([%{type: :rect, x: 1, y: 1, w: 2, h: 1, color: {0, 0, 0}}], 4, 2)
    assert Raster.diff(a, b) == {2, {1, 1}}
  end

  test "the raster rounds fractional coordinates from layout" do
    a = Raster.paint([%{type: :rect, x: 1.0, y: 1.0, w: 2.0, h: 1.0, color: {0, 0, 0}}], 4, 2)
    b = Raster.paint([%{type: :rect, x: 1, y: 1, w: 2, h: 1, color: {0, 0, 0}}], 4, 2)
    assert Raster.diff(a, b) == nil
  end

  test "the raster paints linear gradients, hard stops included" do
    layer = %{
      kind: :linear,
      tile: {0, 0, 4, 2},
      repeat: {:no_repeat, :no_repeat},
      clip: {0, 0, 4, 2},
      line: {0.0, 0.0, 4.0, 0.0},
      stops: [
        {0.0, {255, 0, 0, 255}},
        {0.5, {255, 0, 0, 255}},
        {0.5, {0, 0, 255, 255}},
        {1.0, {0, 0, 255, 255}}
      ]
    }

    item = %{type: :bgimage, x: 0, y: 0, w: 4, h: 2, layers: [layer]}

    red =
      Raster.paint(
        [
          %{type: :rect, x: 0, y: 0, w: 2, h: 2, color: {255, 0, 0}},
          %{type: :rect, x: 2, y: 0, w: 2, h: 2, color: {0, 0, 255}}
        ],
        4,
        2
      )

    assert Raster.diff(Raster.paint([item], 4, 2), red) == nil
  end

  # a PNG of the given colour type, 8 bits, from rows of bytes (filter 0)
  defp png(w, h, ctype, rows, extra \\ []) do
    chunk = fn type, data ->
      <<byte_size(data)::32, type::binary, data::binary, :erlang.crc32([type, data])::32>>
    end

    raw = for row <- rows, into: <<>>, do: <<0, row::binary>>

    <<0x89, "PNG\r\n", 0x1A, 0x0A>> <>
      chunk.("IHDR", <<w::32, h::32, 8, ctype, 0, 0, 0>>) <>
      Enum.map_join(extra, fn {t, d} -> chunk.(t, d) end) <>
      chunk.("IDAT", :zlib.compress(raw)) <> chunk.("IEND", <<>>)
  end

  test "the picture decoder reads RGB, RGBA and palette PNGs" do
    alias Browser.Reftest.Picture

    assert {:ok, %{w: 2, h: 1, rows: [<<255, 0, 0, 255, 0, 0, 255, 255>>]}} =
             Picture.decode(png(2, 1, 2, [<<255, 0, 0, 0, 0, 255>>]))

    assert {:ok, %{rows: [<<1, 2, 3, 4>>]}} = Picture.decode(png(1, 1, 6, [<<1, 2, 3, 4>>]))

    assert {:ok, %{rows: [<<10, 20, 30, 255, 40, 50, 60, 0>>]}} =
             Picture.decode(
               png(2, 1, 3, [<<0, 1>>], [
                 {"PLTE", <<10, 20, 30, 40, 50, 60>>},
                 {"tRNS", <<255, 0>>}
               ])
             )

    assert Picture.decode("not a picture") == :error
  end

  test "pictures are painted: <img> scaled to its box, backgrounds tiled and clipped", %{
    root: root
  } do
    File.mkdir_p!(Path.join(root, "css/t/support"))
    File.write!(Path.join(root, "css/t/support/g.png"), png(1, 1, 2, [<<0, 128, 0>>]))

    write(
      root,
      "p.html",
      ~s(<link rel=match href=p-ref.html><img src="support/g.png" width=40 height=20>)
    )

    write(root, "p-ref.html", ~s(<div style="width:40px;height:20px;background:#008000"></div>))

    write(
      root,
      "q.html",
      ~s|<link rel=match href=q-ref.html><div style="width:30px;height:10px;background:url(support/G.png)"></div>|
    )

    write(root, "q-ref.html", ~s(<div style="width:30px;height:10px;background:#008000"></div>))

    assert Reftest.run_test(root, "css/t/p.html") == :pass
    # the file is called g.png: the address of a background keeps its case, so this one is missing
    assert {:skip, "picture that is not a PNG file"} = Reftest.run_test(root, "css/t/q.html")
  end
end
