defmodule Browser.EditingTest do
  use ExUnit.Case, async: true
  alias Browser.Editing

  defp item(text, x), do: %{type: :text, text: text, x: x, y: 0, h: 16, nid: 1, color: {0, 0, 0}}

  test "segments skip the white space the layout collapsed" do
    segs = Editing.segments("a  b\n c", [item("a", 0), item("b", 10), item("c", 20)])

    assert for({i, from, to} <- segs, do: {i.text, from, to}) == [
             {"a", 0, 1},
             {"b", 3, 4},
             {"c", 6, 7}
           ]
  end

  test "index reads the numbered text nodes and hosts" do
    tree = [
      {:element, "div", [{"@nid", 5}, {"@edhost", 1}],
       [{:element, "@t", [{"@nid", 6}, {"@ed", 5}], [{:text, "hi"}]}]}
    ]

    idx = Editing.index(tree)
    assert idx.hosts == [5]
    assert idx.text == %{6 => "hi"}
    assert Editing.host_of(idx, 6) == 5
  end

  test "caret_rect measures the text before the offset" do
    idx = %{text: %{1 => "abc"}, stand_in: %{}}
    measure = fn text, _ -> String.length(text) * 7 end
    assert %{x: 14, y: 0} = Editing.caret_rect(idx, [item("abc", 0)], {1, 2}, measure)
  end
end
