defmodule Browser.LayoutEllipsisTest do
  use ExUnit.Case, async: true
  alias Browser.{Layout, Page}

  # (every character is 6 px wide at the base size)
  defp measure(text, style), do: String.length(text) * div(style.size, 2)

  defp run(html, width \\ 400) do
    page = Page.build("<style>body{margin:0}</style>" <> html, "about:home")
    Layout.layout(page.nodes, width, &measure/2)
  end

  defp texts(items), do: for(%{type: :text, text: t} <- items, do: t)

  @nowrap "width:100px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis"

  test "text that is wider than a clipping box ends in an ellipsis" do
    {items, _} = run(~s(<div style="#{@nowrap}">one two three four five six seven</div>))
    assert [first | _] = texts(items)
    assert Enum.any?(texts(items), &String.ends_with?(&1, "…"))

    right =
      items |> Enum.filter(&(&1.type == :text)) |> Enum.map(&(&1.x + &1.w)) |> Enum.max()

    assert right <= 100
    assert first == "one"
  end

  test "text that fits is not changed" do
    {items, _} = run(~s(<div style="#{@nowrap}">short</div>))
    assert texts(items) == ["short"]
  end

  test "without text-overflow nothing is cut" do
    {items, _} =
      run(
        ~s(<div style="width:100px;white-space:nowrap;overflow:hidden">one two three four five six</div>)
      )

    refute Enum.any?(texts(items), &String.contains?(&1, "…"))
  end

  test "-webkit-line-clamp shows that many lines and an ellipsis" do
    html =
      ~s(<p style="width:100px;display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical;overflow:hidden">) <>
        String.duplicate("word ", 30) <> "</p>"

    {items, h} = run(html)
    text = Enum.filter(items, &(&1.type == :text))
    assert text |> Enum.map(& &1.y) |> Enum.uniq() |> length() == 2
    assert List.last(Enum.sort_by(text, &{&1.y, &1.x})).text |> String.ends_with?("…")

    {_, h_full} = run(String.replace(html, "-webkit-line-clamp:2;", ""))
    assert h < h_full
  end

  test "a clamp that is higher than the text changes nothing" do
    {items, _} = run(~s(<p style="-webkit-line-clamp:3;overflow:hidden">a b c</p>))
    assert texts(items) == ["a", "b", "c"]
  end
end
