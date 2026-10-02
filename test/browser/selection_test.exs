defmodule Browser.SelectionTest do
  use ExUnit.Case, async: true

  alias Browser.Selection

  defp measure(text, _style), do: String.length(text) * 8

  defp item(text, x, y, extra \\ %{}) do
    Map.merge(
      %{
        type: :text,
        text: text,
        x: x,
        y: y,
        w: String.length(text) * 8,
        h: 16,
        cid: nil,
        hidden: false
      },
      extra
    )
  end

  # two lines in one paragraph, then a second paragraph
  defp items do
    [
      item("Hello", 0, 0),
      item("world", 48, 0),
      item("again", 0, 20),
      item("Next", 0, 60),
      item("para", 40, 60)
    ]
  end

  defp texts(items \\ items()), do: Selection.texts(items)

  describe "texts/1" do
    test "reading order, whatever the item order" do
      shuffled = [item("b", 48, 0), item("c", 0, 20), item("a", 0, 0)]
      assert shuffled |> texts() |> Enum.map(& &1.text) == ["a", "b", "c"]
    end

    test "leaves out other items, hidden text and form control text" do
      items = [
        %{type: :rect, x: 0, y: 0, w: 5, h: 5},
        item("hidden", 0, 0, %{hidden: true}),
        item("field", 0, 0, %{cid: 3}),
        item("shown", 0, 0)
      ]

      assert items |> texts() |> Enum.map(& &1.text) == ["shown"]
    end

    test "words of different sizes share a line" do
      items = [item("big", 0, 0, %{h: 32}), item("small", 40, 10, %{h: 12})]
      assert items |> texts() |> Enum.map(& &1.text) == ["big", "small"]
    end
  end

  describe "point_at/4" do
    test "finds the character boundary nearest to the point" do
      assert Selection.point_at(texts(), 20, 5, &measure/2) == {0, 2}
      assert Selection.point_at(texts(), 23, 5, &measure/2) == {0, 3}
      assert Selection.point_at(texts(), 53, 5, &measure/2) == {1, 1}
    end

    test "left of the line is its start, right of it its end" do
      assert Selection.point_at(texts(), -30, 25, &measure/2) == {2, 0}
      assert Selection.point_at(texts(), 500, 5, &measure/2) == {1, 5}
    end

    test "in the gap between two items the nearer one" do
      assert Selection.point_at(texts(), 42, 5, &measure/2) == {0, 5}
      assert Selection.point_at(texts(), 46, 5, &measure/2) == {1, 0}
    end

    test "above the text is the first position, below it the last" do
      assert Selection.point_at(texts(), 30, -50, &measure/2) == {0, 4}
      assert Selection.point_at(texts(), 56, 900, &measure/2) == {4, 2}
    end

    test "between lines the nearer line" do
      assert Selection.point_at(texts(), 0, 38, &measure/2) == {2, 0}
      assert Selection.point_at(texts(), 0, 52, &measure/2) == {3, 0}
    end

    test "nothing to select" do
      assert Selection.point_at([], 1, 1, &measure/2) == nil
    end
  end

  describe "over_text?/3" do
    test "inside a text box only" do
      t = texts()
      assert Selection.over_text?(t, 10, 5)
      assert Selection.over_text?(t, 50, 5)
      refute Selection.over_text?(t, 44, 5)
      refute Selection.over_text?(t, 10, 40)
      refute Selection.over_text?(t, 500, 5)
    end

    test "not outside the box that clips the text" do
      t = texts([item("clipped", 0, 0, %{clip: %{x: 0, y: 0, w: 20, h: 20}})])
      assert Selection.over_text?(t, 10, 5)
      refute Selection.over_text?(t, 40, 5)
    end
  end

  describe "ranges, words and everything" do
    test "range orders positions and drops empty ones" do
      assert Selection.range({1, 2}, {0, 4}) == {{0, 4}, {1, 2}}
      assert Selection.range({1, 2}, {1, 2}) == nil
    end

    test "all" do
      assert Selection.all(texts()) == {{0, 0}, {4, 4}}
      assert Selection.all([]) == nil
    end

    test "word_at inside an item with several words" do
      t = texts([item("one two three", 0, 0)])
      assert Selection.word_at(t, {0, 5}) == {{0, 4}, {0, 7}}
      assert Selection.word_at(t, {0, 4}) == {{0, 4}, {0, 7}}
      assert Selection.word_at(t, {0, 7}) == {{0, 4}, {0, 7}}
      assert Selection.word_at(t, {0, 0}) == {{0, 0}, {0, 3}}
    end

    test "word_at on nothing" do
      t = texts([item("a  b", 0, 0)])
      assert Selection.word_at(t, {0, 2}) == nil
    end
  end

  describe "paragraph_at/2" do
    test "the lines around the position, up to the blank space" do
      assert Selection.paragraph_at(texts(), {0, 2}) == {{0, 0}, {2, 5}}
      assert Selection.paragraph_at(texts(), {2, 1}) == {{0, 0}, {2, 5}}
      assert Selection.paragraph_at(texts(), {4, 0}) == {{3, 0}, {4, 4}}
    end

    test "a lone line" do
      t = texts([item("only", 0, 0)])
      assert Selection.paragraph_at(t, {0, 1}) == {{0, 0}, {0, 4}}
    end
  end

  describe "text/2" do
    test "within one item" do
      assert Selection.text(texts(), {{0, 1}, {0, 4}}) == "ell"
    end

    test "words on a line are joined with a space, lines with a break" do
      assert Selection.text(texts(), {{0, 0}, {2, 5}}) == "Hello world\nagain"
    end

    test "paragraphs are separated by a blank line" do
      assert Selection.text(texts(), Selection.all(texts())) == "Hello world\nagain\n\nNext para"
    end

    test "adjacent fragments of one word are not split" do
      t = texts([item("bo", 0, 0), item("ld", 16, 0)])
      assert Selection.text(t, Selection.all(t)) == "bold"
    end

    test "nothing selected" do
      assert Selection.text(texts(), nil) == ""
    end

    test "counts characters, not bytes" do
      t = texts([item("héllo", 0, 0)])
      assert Selection.text(t, {{0, 1}, {0, 3}}) == "él"
    end
  end

  describe "rects/3" do
    test "a partial item" do
      assert [%{x: 16, y: 0, w: 24, h: 20}] =
               Selection.rects(texts(), {{0, 2}, {0, 5}}, &measure/2)
    end

    test "the space between selected words on a line is covered" do
      [first, second] = Selection.rects(texts(), {{0, 0}, {1, 3}}, &measure/2)
      assert first.x == 0 and first.x + first.w == 48
      assert second.x == 48 and second.w == 24
    end

    test "every line of a multi-line selection" do
      rects = Selection.rects(texts(), Selection.all(texts()), &measure/2)
      assert length(rects) == 5
      assert Enum.map(rects, & &1.y) == [0, 0, 20, 60, 60]
    end

    test "clipped items give clipped highlights" do
      t = texts([item("clipped", 0, 0, %{clip: %{x: 0, y: 0, w: 20, h: 20}})])
      assert [%{clip: %{w: 20}}] = Selection.rects(t, Selection.all(t), &measure/2)
    end

    test "no selection, no rects" do
      assert Selection.rects(texts(), nil, &measure/2) == []
    end
  end
end
