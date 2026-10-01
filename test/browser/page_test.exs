defmodule Browser.PageTest do
  use ExUnit.Case, async: true
  alias Browser.Page

  @dir Path.expand("../fixtures/images", __DIR__)

  defp texts(nodes) do
    Enum.flat_map(nodes, fn
      {:text, t} -> [t]
      {:element, _, _, kids} -> texts(kids)
    end)
  end

  describe "document/2" do
    test "markup is shown as it is" do
      assert Page.document("<p>hi</p>", "http://x.test/") == "<p>hi</p>"
      assert Page.document("plain text with é", "http://x.test/") == "plain text with é"
    end

    test "a picture becomes a page that shows it" do
      png = File.read!(Path.join(@dir, "badge.png"))
      html = Page.document(png, "http://x.test/pics/a&b.png")
      assert html =~ ~s(<img src="http://x.test/pics/a&amp;b.png")
      assert html =~ "<title>a&amp;b.png</title>"
    end

    test "other binary files are explained instead of dumped" do
      html = Page.document(<<0, 1, 2, 3, "PK">>, "http://x.test/archive.zip")
      assert html =~ "This file can't be shown"
      assert html =~ "6 bytes"
      refute html =~ <<0>>
    end

    test "a NUL after the first kilobyte doesn't make text binary" do
      body = String.duplicate("a", 2000) <> <<0>>
      assert Page.document(body, "http://x.test/") == body
    end
  end

  describe "load/3" do
    test "loading a picture file gives an image page with the picture to fetch" do
      url = "file://" <> Path.join(@dir, "photo.jpg")
      assert {:ok, page} = Page.load(url)
      assert page.image_urls == [url]
      assert page.title == "photo.jpg"
    end

    test "loading a binary file gives the explanation page" do
      path = Path.join(System.tmp_dir!(), "page_test_#{System.unique_integer([:positive])}.bin")
      File.write!(path, <<0, 0, 0, 0>>)
      assert {:ok, page} = Page.load("file://" <> path)
      assert Enum.any?(texts(page.nodes), &(&1 =~ "binary file"))
      File.rm!(path)
    end

    test "errors pass through" do
      assert {:error, _} = Page.load("file:///no/such/file.html")
    end
  end

  describe "all_image_urls/1" do
    @url "http://h.test/dir/p.html"

    test "includes background images from style elements, style attributes and external rules" do
      html = """
      <html><head><style>body { background: url(bg.png) } .x { background-image: linear-gradient(red, blue), url("/deep/y.png") }</style></head>
      <body><img src="a.png"><div class="x">t</div>
      <div style="background: url('inline.png')">u</div></body></html>
      """

      page = Page.build(html, @url)

      assert Page.all_image_urls(page) |> Enum.sort() ==
               Enum.sort([
                 "http://h.test/dir/a.png",
                 "http://h.test/dir/bg.png",
                 "http://h.test/deep/y.png",
                 "http://h.test/dir/inline.png"
               ])
    end

    test "no duplicates, and nothing for pages without pictures" do
      page =
        Page.build(
          ~s|<style>p { background: url(a.png) }</style><p>x</p><img src="a.png"><p>y</p>|,
          @url
        )

      assert Page.all_image_urls(page) == ["http://h.test/dir/a.png"]
      assert Page.all_image_urls(Page.build("<p>no pictures</p>", @url)) == []
    end

    test "backgrounds that only apply at some widths follow the media queries" do
      html =
        "<style>@media (min-width: 800px) { p { background-image: url(wide.png) } }</style><p>x</p>"

      narrow = Page.build(html, @url, %{type: "screen", width: 500, height: 600, dppx: 1.0})
      wide = Page.restyle(narrow, %{type: "screen", width: 1000, height: 600, dppx: 1.0})
      assert Page.all_image_urls(narrow) == []
      assert Page.all_image_urls(wide) == ["http://h.test/dir/wide.png"]
    end
  end
end
