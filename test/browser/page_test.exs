defmodule Browser.PageTest do
  use ExUnit.Case, async: true
  alias Browser.Page

  @dir Path.expand("../../priv/demo/images", __DIR__)

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

  describe "restyling" do
    @narrow %{type: "screen", width: 500, height: 600, dppx: 1.0}
    @wide %{type: "screen", width: 1000, height: 600, dppx: 1.0}
    @html "<style>@media (min-width: 800px) { p { color: red } }</style><p>x</p>"

    test "a size seen before comes from the cache with the same result" do
      narrow = Page.build(@html, @url, @narrow)
      wide = Page.restyle(narrow, @wide)
      assert map_size(wide.style_cache) == 2
      back = Page.restyle(wide, @narrow)
      assert back.nodes == narrow.nodes
      assert Page.restyle(back, @wide).nodes == wide.nodes
      assert map_size(back.style_cache) == 2
    end

    test "every render is a new version of the page" do
      page = Page.build(@html, @url, @narrow)
      assert page.ver != nil
      assert Page.render(page, page.form_state).ver != page.ver
      assert Page.restyle(page, @wide).ver != page.ver
    end
  end

  describe "from_raw/3" do
    test "indexes the controls again and keeps the values written into the tree" do
      page = Page.build(~s|<input value=a><p>x</p>|, @url, @narrow)
      assert map_size(page.forms.controls) == 1

      raw = [
        {:element, "input", [{"value", "typed"}], []},
        {:element, "p", [], [{:text, "changed"}]},
        {:element, "input", [{"type", "checkbox"}, {"checked", ""}], []}
      ]

      changed = Page.from_raw(page, raw, @narrow)
      assert map_size(changed.forms.controls) == 2
      assert changed.forms.controls[0].value == "typed"
      assert changed.forms.controls[1].checked
      assert changed.form_state == %{}
      assert changed.ver != page.ver
    end

    test "scripts? looks for a script element" do
      assert Page.scripts?(Page.build("<script>1</script>", @url))
      refute Page.scripts?(Page.build("<p>no</p>", @url))
    end
  end

  describe "viewport units" do
    defp page_height(page), do: div_height(page.nodes)

    defp div_height(nodes) do
      Enum.find_value(nodes, fn
        {:element, "div", attrs, _} ->
          attrs |> List.keyfind("@computed", 0) |> elem(1) |> Map.get("height")

        {:element, _, _, kids} ->
          div_height(kids)

        _ ->
          nil
      end)
    end

    test "restyle follows the window size, only for pages that use them" do
      html = ~s|<body style="margin:0"><div style="height: 50vh">x</div></body>|
      env = fn w, h -> %{type: "screen", width: w, height: h, dppx: 1.0} end
      page = Page.build(html, "about:home", env.(800, 600))
      assert page.viewport_units
      assert page_height(Page.restyle(page, env.(800, 400))) == 200.0

      plain = Page.build("<div>x</div>", "about:home", env.(800, 600))
      refute plain.viewport_units
      assert Page.restyle(plain, env.(800, 400)) == plain
    end
  end
end
