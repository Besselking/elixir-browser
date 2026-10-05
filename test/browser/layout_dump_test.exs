defmodule Browser.LayoutDumpTest do
  use ExUnit.Case, async: true

  defp dump(html, opts \\ []) do
    page = Browser.Page.build(html, "file:///t.html")
    Mix.Tasks.Browser.Layout.dump(page, 800, 600, opts)
  end

  test "lists elements with ids, classes and boxes" do
    out =
      dump(
        ~s|<style>body{margin:0}#a{margin:10px 5px;width:100px;height:40px;background:#ccc}</style><div id=a class="x y">hi</div>|
      )

    assert out =~ "viewport 800x600"
    assert out =~ "<div>#a.x.y 5,10 100x40"
    assert out =~ ~s|"hi"|
  end

  test "leaves out elements that are not drawn unless asked" do
    html = "<title>t</title><p>x</p>"
    refute dump(html) =~ "<head>"
    assert dump(html, all: true) =~ "<head> (no box)"
  end

  test "--style adds margins, borders and padding" do
    out = dump("<div style='margin:4px;border:1px solid red;padding:2px'>x</div>", style: true)
    assert out =~ "m=4,4,4,4 b=1,1,1,1 p=2,2,2,2"
  end
end
