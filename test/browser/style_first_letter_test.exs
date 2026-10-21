defmodule Browser.StyleFirstLetterTest do
  use ExUnit.Case, async: true
  alias Browser.{Layout, Page}

  defp measure(text, style), do: String.length(text) * div(style.size, 2)

  defp run(html) do
    page = Page.build("<style>body{margin:0}</style>" <> html, "about:home")
    {items, _} = Layout.layout(page.nodes, 400, &measure/2)
    for %{type: :text} = it <- items, do: it
  end

  test "::first-letter styles the first letter of a block" do
    text =
      run("<style>p::first-letter { font-size: 32px; color: #f00 }</style><p>Hello world</p>")

    assert %{size: 32, color: {255, 0, 0}} = Enum.find(text, &(&1.text == "H"))
    assert %{size: 16} = Enum.find(text, &(&1.text == "ello"))
  end

  test "the punctuation before the letter goes with it, and a one-colon rule works" do
    text = run(~s(<style>p:first-letter { font-weight: bold }</style><p>"Quote" me</p>))
    assert %{bold: true} = Enum.find(text, &(&1.text == "\"Q"))
  end

  test "it is found in the first inline child, and only there" do
    text =
      run("<style>p::first-letter { color: #00f }</style><p><b>Big</b> two</p><div>No</div>")

    assert %{color: {0, 0, 255}} = Enum.find(text, &(&1.text == "B"))
    assert %{color: {0, 0, 0}} = Enum.find(text, &(&1.text == "two"))
    assert %{color: {0, 0, 0}} = Enum.find(text, &(&1.text == "No"))
  end

  test "a page without a rule has no extra spans" do
    text = run("<p>Hello</p>")
    assert Enum.map(text, & &1.text) == ["Hello"]
  end
end
