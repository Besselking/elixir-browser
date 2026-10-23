defmodule Browser.ContainerTest do
  use ExUnit.Case, async: true
  alias Browser.{CSS, Layout, Page, Style}

  defp measure(text, style), do: String.length(text) * div(style.size, 2)

  defp settled(html) do
    env = %{Style.default_env() | width: 800, height: 600}
    page = Page.build("<style>body{margin:0}</style>" <> html, "about:home", env)

    {_page, {items, _}} =
      Page.settle(page, env, fn page ->
        Layout.layout(page.nodes, 800, &measure/2, 600, boxes: Page.cq?(page))
      end)

    for %{type: :text} = it <- items, into: %{}, do: {it.text, it}
  end

  defp settled_items(html) do
    env = %{Style.default_env() | width: 800, height: 600}
    page = Page.build("<style>body{margin:0}</style>" <> html, "about:home", env)

    {_page, {items, _}} =
      Page.settle(page, env, fn page ->
        Layout.layout(page.nodes, 800, &measure/2, 600, boxes: Page.cq?(page))
      end)

    for %{type: :text} = it <- items, do: it
  end

  @css """
  <style>
  .card { container-type: inline-size; padding: 10px }
  .t { font-size: 16px }
  @container (min-width: 400px) { .t { font-size: 24px } }
  @container narrow (max-width: 300px) { .t { color: #00f } }
  .named { container: narrow / inline-size }
  </style>
  """

  test "a rule in @container applies when the container is wide enough" do
    words =
      settled(
        @css <>
          ~s(<div class=card style="width:500px"><p class=t>wide</p></div>) <>
          ~s(<div class=card style="width:300px"><p class=t>narrow</p></div>)
      )

    assert words["wide"].size == 24
    assert words["narrow"].size == 16
  end

  test "the size is that of the content box, and a named container is looked up by name" do
    words =
      settled(
        @css <>
          ~s(<div class=card style="width:410px;box-sizing:border-box"><p class=t>edge</p></div>) <>
          ~s(<div class=named style="width:250px"><div class=card style="width:900px"><p class=t>inner</p></div></div>)
      )

    # 410 px wide with 10 px padding on each side: 390 px of content
    assert words["edge"].size == 16
    # the nearest container named "narrow" is the outer one (250 px)
    assert words["inner"].color == {0, 0, 255}
  end

  test "a page without container rules is styled and laid out once" do
    page = Page.build("<p>x</p>", "about:home")
    refute Page.cq?(page)
    me = self()

    Page.settle(page, Style.default_env(), fn page ->
      send(me, :laid_out)
      Layout.layout(page.nodes, 400, &measure/2)
    end)

    assert_received :laid_out
    refute_received :laid_out
  end

  test "@container is parsed with and without a name" do
    [a, b] =
      CSS.parse(
        "@container (min-width: 1px) { p { color: red } } @container side (min-width: 2px) { p { color: red } }"
      )

    assert a.cq == [{nil, "(min-width: 1px)"}]
    assert b.cq == [{"side", "(min-width: 2px)"}]
    assert a.media == []
  end

  describe "container units" do
    @units """
    <style>
    .card { container-type: inline-size }
    .box { container-type: size; height: 200px }
    .w { font-size: 10cqw }
    .i { font-size: 5cqi }
    .h { font-size: 10cqh }
    .m { font-size: calc(2cqmin + 4px) }
    </style>
    """

    test "1cqw is a hundredth of the width of the nearest container" do
      words =
        settled(
          @units <>
            ~s(<div class=card style="width:300px"><p class=w>a</p></div>) <>
            ~s(<div class=card style="width:500px"><p class=i>b</p></div>)
        )

      assert words["a"].size == 30
      assert words["b"].size == 25
    end

    test "cqh and cqmin use the height of a size container" do
      words =
        settled(
          @units <>
            ~s(<div class=box style="width:400px"><p class=h>h</p><p class=m>m</p></div>)
        )

      assert words["h"].size == 20
      # min(4px, 2px) * 2 + 4
      assert words["m"].size == 8
    end

    test "equal elements in containers of different sizes get their own size" do
      card = fn width -> ~s(<div class=card style="width:#{width}px"><p class=w>s</p></div>) end
      items = settled_items(@units <> card.(200) <> card.(500))
      assert [20, 50] = for(%{text: "s", size: size} <- items, do: size)
    end

    test "a style attribute may have them too" do
      html =
        ~s(<div style="container-type:inline-size;width:400px"><p style="font-size:5cqw">i</p></div>)

      assert Page.cq?(Page.build(html, "about:home"))
      assert [20] = for(%{text: "i", size: size} <- settled_items(html), do: size)
    end

    test "without a container the units are the viewport's" do
      words = settled(@units <> ~s(<p class=w>v</p>))
      # 800 px wide window
      assert words["v"].size == 80
    end

    test "the page is styled again when the sizes are known" do
      page = Page.build(@units <> ~s(<div class=card><p class=w>x</p></div>), "about:home")
      assert Page.cq?(page)
    end
  end
end
