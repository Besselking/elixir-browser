defmodule Browser.ImagesTest do
  # not async: one test changes PATH for the whole VM
  use ExUnit.Case, async: false
  alias Browser.{HTML, Images}

  @dir Path.expand("../../priv/demo/images", __DIR__)
  @base "file://" <> @dir <> "/page.html"

  defp file(name), do: "file://" <> Path.join(@dir, name)

  describe "index/2" do
    defp indexed(html, base \\ "https://example.com/a/b.html") do
      {nodes, urls} = html |> HTML.parse() |> Images.index(base)
      {nodes, urls}
    end

    defp srcs(nodes) do
      Enum.flat_map(nodes, fn
        {:element, "img", attrs, _} ->
          case List.keyfind(attrs, "@src", 0) do
            {_, url} -> [url]
            nil -> [:none]
          end

        {:element, _, _, kids} ->
          srcs(kids)

        _ ->
          []
      end)
    end

    test "images get an absolute @src and the urls come back in order, without duplicates" do
      {nodes, urls} =
        indexed(
          ~s(<p><img src="x.png"><img src="/y.jpg"><img src="x.png"><img src="https://cdn.test/z.gif"></p>)
        )

      assert srcs(nodes) == [
               "https://example.com/a/x.png",
               "https://example.com/y.jpg",
               "https://example.com/a/x.png",
               "https://cdn.test/z.gif"
             ]

      assert urls == [
               "https://example.com/a/x.png",
               "https://example.com/y.jpg",
               "https://cdn.test/z.gif"
             ]
    end

    test "images without a usable source are left alone" do
      {nodes, urls} = indexed(~s(<img><img src=""><img src="  "><img src="#frag" alt="x">))
      assert srcs(nodes) == [:none, :none, :none, :none]
      assert urls == []
    end

    test "data-src and srcset are used when src is missing" do
      {nodes, urls} =
        indexed(
          ~s(<img data-src="lazy.png"><img srcset="small.png 1x, big.png 2x"><img src="s.png" data-src="no.png">)
        )

      assert srcs(nodes) ==
               [
                 "https://example.com/a/lazy.png",
                 "https://example.com/a/small.png",
                 "https://example.com/a/s.png"
               ]

      assert urls == [
               "https://example.com/a/lazy.png",
               "https://example.com/a/small.png",
               "https://example.com/a/s.png"
             ]
    end

    test "srcset candidates may be data URLs with commas" do
      {nodes, _} = indexed(~s(<img srcset="data:image/png;base64,AAA= 1x, b.png 2x">))
      assert srcs(nodes) == ["data:image/png;base64,AAA="]
    end

    test "images nested anywhere are found; other markup is untouched" do
      {nodes, urls} =
        indexed(~s(<div><a href="/"><span><img src="deep.png"></span></a><b>t</b></div>))

      assert urls == ["https://example.com/a/deep.png"]
      assert [{:element, "div", [], [_, {:element, "b", [], [{:text, "t"}]}]}] = nodes
    end

    test "source/1" do
      assert Images.source([{"src", "a.png"}]) == "a.png"
      assert Images.source([]) == nil
      assert Images.source([{"srcset", "  one.png 480w,  two.png 800w "}]) == "one.png"
    end
  end

  describe "sniff/1" do
    test "recognises the formats by their first bytes" do
      assert Images.sniff(File.read!(Path.join(@dir, "photo.png"))) == :png
      assert Images.sniff(File.read!(Path.join(@dir, "photo.jpg"))) == :jpeg
      assert Images.sniff(File.read!(Path.join(@dir, "photo.gif"))) == :gif
      assert Images.sniff(File.read!(Path.join(@dir, "photo.bmp"))) == :bmp
      assert Images.sniff(File.read!(Path.join(@dir, "photo.tiff"))) == :tiff
      assert Images.sniff("RIFF\x10\x00\x00\x00WEBPVP8 ") == :webp
      assert Images.sniff(<<0, 0, 0, 24, "ftypavif", 0, 0>>) == :avif
      assert Images.sniff(<<0, 0, 0, 24, "ftypheic", 0, 0>>) == :heic
    end

    test "anything else is unknown" do
      assert Images.sniff("<html>") == :unknown
      assert Images.sniff("") == :unknown
      assert Images.sniff("GIF") == :unknown
    end
  end

  describe "decode_data_url/1" do
    test "base64 and percent-encoded payloads" do
      assert {:ok, "hello"} = Images.decode_data_url("data:text/plain;base64,aGVsbG8=")
      assert {:ok, "hello"} = Images.decode_data_url("data:text/plain;base64,aGVsbG8")
      assert {:ok, "a b"} = Images.decode_data_url("data:,a%20b")
      assert {:ok, "<svg/>"} = Images.decode_data_url("data:image/svg+xml,%3Csvg/%3E")
    end

    test "malformed ones are errors" do
      assert {:error, _} = Images.decode_data_url("data:nocomma")
      assert {:error, "bad base64"} = Images.decode_data_url("data:;base64,@@@")
    end
  end

  describe "fetch/2" do
    test "formats the toolkit reads come back unchanged" do
      for {name, format} <- [
            {"photo.png", :png},
            {"photo.jpg", :jpeg},
            {"photo.gif", :gif},
            {"photo.bmp", :bmp}
          ] do
        assert {:ok, bytes, ^format} = Images.fetch(file(name), @base)
        assert bytes == File.read!(Path.join(@dir, name))
      end
    end

    test "other formats are converted to PNG with sips, and reported where it is missing" do
      result = Images.fetch(file("photo.tiff"), @base)

      if System.find_executable("sips") do
        assert {:ok, png, :png} = result
        assert Images.sniff(png) == :png
      else
        # not macOS: the image just can't be shown, nothing crashes
        assert {:error, "cannot convert tiff" <> _} = result
      end
    end

    test "data URLs work" do
      png = File.read!(Path.join(@dir, "badge.png"))
      url = "data:image/png;base64," <> Base.encode64(png)
      assert {:ok, ^png, :png} = Images.fetch(url, "https://example.com/")
    end

    test "unknown formats and empty files are errors" do
      path = Path.join(System.tmp_dir!(), "images_test_#{System.unique_integer([:positive])}.bin")
      File.write!(path, "not an image at all")
      assert {:error, "unknown image format"} = Images.fetch("file://" <> path, @base)
      File.write!(path, "")
      assert {:error, "empty image"} = Images.fetch("file://" <> path, @base)
      File.rm!(path)
    end

    test "huge images are refused" do
      path = Path.join(System.tmp_dir!(), "images_test_#{System.unique_integer([:positive])}.bin")
      File.write!(path, :binary.copy(<<0>>, 13 * 1024 * 1024))
      assert {:error, "image too large"} = Images.fetch("file://" <> path, @base)
      File.rm!(path)
    end

    test "missing files are errors" do
      assert {:error, _} = Images.fetch(file("nope.png"), @base)
    end

    test "a web page can't load local files" do
      assert {:error, "blocked: file URL"} =
               Images.fetch(file("photo.png"), "https://example.com/")

      assert {:error, "blocked: relative URL"} = Images.fetch("/x.png", "https://example.com/")
    end

    test "a local page may load local files" do
      assert {:ok, _, :png} = Images.fetch(file("badge.png"), "file:///tmp/page.html")
    end
  end

  describe "convert/2" do
    test "garbage that claims to be an image is an error, not a crash" do
      assert {:error, "cannot convert webp" <> _} = Images.convert("RIFF....WEBPnonsense", :webp)
    end

    test "a missing tool is an error, not a crash" do
      old = System.get_env("PATH")
      System.put_env("PATH", "/nonexistent")

      try do
        assert {:error, "cannot convert tiff" <> _} = Images.convert("II*\0", :tiff)
      after
        System.put_env("PATH", old)
      end
    end
  end
end
