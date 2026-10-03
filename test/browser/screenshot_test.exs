defmodule Browser.ScreenshotTest do
  use ExUnit.Case, async: true

  alias Browser.{Layout, Page, Screenshot}

  defp svg(html) do
    page = Page.build(html, "about:test")
    {items, height} = Layout.layout(page.nodes, 300, &Screenshot.measure/2, 200)
    Screenshot.svg(items, 300, height)
  end

  test "draws text and boxes" do
    out = svg(~s(<div style="border: 1px solid #f00; padding: 4px">a &amp; b</div>))
    assert out =~ ~s(<svg xmlns)
    assert out =~ "rgb(255,0,0)"
    assert out =~ ">a</text>"
    assert out =~ "&amp;"
  end

  test "a rounded dashed border is one dashed stroke" do
    out = svg(~s(<div style="border: 2px dashed #000; border-radius: 4px">x</div>))
    assert out =~ "stroke-dasharray"
    assert out =~ " A"
  end
end
