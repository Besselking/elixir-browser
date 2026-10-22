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
end
