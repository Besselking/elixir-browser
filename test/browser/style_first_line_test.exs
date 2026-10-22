defmodule Browser.StyleFirstLineTest do
  use ExUnit.Case, async: true
  alias Browser.{Layout, Page}

  # (every character is 6 px wide at the base size, 7 px when bold)
  defp measure(text, %{bold: true}), do: String.length(text) * 7
  defp measure(text, style), do: String.length(text) * div(style.size, 2)

  defp run(html, width \\ 120) do
    page = Page.build("<style>body{margin:0}</style>" <> html, "about:home")
    {items, _} = Layout.layout(page.nodes, width, &measure/2)
    for %{type: :text} = it <- items, do: it
  end

  test "::first-line styles the words of the first line only" do
    text =
      run("""
      <style>p::first-line { color: #f00; font-weight: bold }</style>
      <p>one two three four five six seven eight</p>
      """)

    first = Enum.min_by(text, & &1.y).y
    {on, off} = Enum.split_with(text, &(&1.y == first))
    assert on != [] and off != []
    assert Enum.all?(on, &(&1.color == {255, 0, 0} and &1.bold))
    assert Enum.all?(off, &(&1.color != {255, 0, 0} and not &1.bold))
  end

  test "the words after a bolder one move by the change of its width" do
    text = run("<style>p::first-line { font-weight: bold }</style><p>ab cd</p>", 400)
    [a, b] = Enum.sort_by(text, & &1.x)
    assert a.w == 14
    assert b.x >= a.x + a.w
  end

  test "a rule with no property the layout can apply changes nothing" do
    text = run("<style>p::first-line { margin: 0 }</style><p>plain text</p>")
    assert Enum.all?(text, &(not &1.bold))
  end

  test "text with a colour rule of its own keeps it on the first line" do
    text =
      run("""
      <style>
        i { color: #0a0 }
        p::first-line { color: #f00 }
      </style>
      <p>one <i>two</i> three</p>
      """)

    colours = Map.new(text, &{&1.text, &1.color})
    assert colours["one"] == {255, 0, 0}
    assert colours["two"] == {0, 170, 0}
    assert colours["three"] == {255, 0, 0}
  end
end
