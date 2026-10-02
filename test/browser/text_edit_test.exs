defmodule Browser.TextEditTest do
  use ExUnit.Case, async: true
  alias Browser.TextEdit

  defp ed(state, key, opts \\ []), do: TextEdit.apply(state, key, opts)

  describe "typing" do
    test "inserts at the caret and moves it" do
      assert {"ab", 2} = ed({"", 0}, {:char, "a"}) |> ed({:char, "b"})
      assert {"axb", 2} = ed({"ab", 1}, {:char, "x"})
      assert {"xab", 1} = ed({"ab", 0}, {:char, "x"})
    end

    test "pasted multi-character text moves the caret past it" do
      assert {"hello world", 11} = ed({"hello ", 6}, {:char, "world"})
    end

    test "unicode characters count as one" do
      assert {"héllo", 2} = ed({"hllo", 1}, {:char, "é"})
      assert {"a👍🏽b", 2} = ed({"ab", 1}, {:char, "👍🏽"})
      assert {"ab", 1} = ed({"a👍🏽b", 2}, :backspace)
      assert {"ab", 1} = ed({"a👍🏽b", 1}, :delete)
    end

    test "control characters are dropped" do
      assert :ignored = ed({"", 0}, {:char, "\u0007"})
      assert {"ab", 2} = ed({"", 0}, {:char, "a\u0000b"})
    end

    test "line breaks become a space in single-line fields and survive in textareas" do
      assert {"a b", 3} = ed({"", 0}, {:char, "a\nb"})
      assert {"a b", 3} = ed({"", 0}, {:char, "a\r\nb"})
      assert {"a\nb", 3} = ed({"", 0}, {:char, "a\nb"}, multiline: true)
      assert {"a\nb", 3} = ed({"", 0}, {:char, "a\r\nb"}, multiline: true)
    end

    test "maxlength truncates typed and pasted text" do
      assert {"abc", 3} = ed({"ab", 2}, {:char, "cdef"}, max: 3)
      assert :ignored = ed({"abc", 3}, {:char, "d"}, max: 3)
      assert {"abXc", 3} = ed({"abc", 2}, {:char, "X"}, max: 4)
    end

    test "enter inserts a newline only in multi-line fields" do
      assert {"a\nb", 2} = ed({"ab", 1}, :enter, multiline: true)
      assert :ignored = ed({"ab", 1}, :enter)
    end
  end

  describe "deleting" do
    test "backspace removes the character before the caret" do
      assert {"ac", 1} = ed({"abc", 2}, :backspace)
      assert :ignored = ed({"abc", 0}, :backspace)
      assert {"ab", 2} = ed({"abc", 3}, :backspace)
    end

    test "delete removes the character after the caret" do
      assert {"ac", 1} = ed({"abc", 1}, :delete)
      assert :ignored = ed({"abc", 3}, :delete)
      assert {"bc", 0} = ed({"abc", 0}, :delete)
    end

    test "deleting a newline joins the lines" do
      assert {"ab", 1} = ed({"a\nb", 2}, :backspace)
      assert {"ab", 1} = ed({"a\nb", 1}, :delete)
    end
  end

  describe "moving" do
    test "left and right stop at the ends" do
      assert {"abc", 1} = ed({"abc", 2}, :left)
      assert :ignored = ed({"abc", 0}, :left)
      assert {"abc", 3} = ed({"abc", 2}, :right)
      assert :ignored = ed({"abc", 3}, :right)
    end

    test "home and end in a single line go to the ends" do
      assert {"hello", 0} = ed({"hello", 3}, :home)
      assert {"hello", 5} = ed({"hello", 3}, :end)
      assert :ignored = ed({"hello", 0}, :home)
    end

    test "up and down in a single line go to the start or end" do
      assert {"hello", 0} = ed({"hello", 3}, :up)
      assert {"hello", 5} = ed({"hello", 3}, :down)
    end
  end

  describe "multi-line" do
    @text "abc\nde\nfghij"

    test "line and column of the caret" do
      assert {0, 0} = TextEdit.line_col(@text, 0)
      assert {0, 3} = TextEdit.line_col(@text, 3)
      assert {1, 0} = TextEdit.line_col(@text, 4)
      assert {1, 2} = TextEdit.line_col(@text, 6)
      assert {2, 5} = TextEdit.line_col(@text, 12)
    end

    test "index of a line and column, clamped" do
      assert 0 = TextEdit.index_at(@text, 0, 0)
      assert 4 = TextEdit.index_at(@text, 1, 0)
      assert 6 = TextEdit.index_at(@text, 1, 99)
      assert 12 = TextEdit.index_at(@text, 99, 99)
      assert 0 = TextEdit.index_at(@text, -1, -1)
    end

    test "home and end go to the ends of the current line" do
      assert {@text, 4} = ed({@text, 6}, :home, multiline: true)
      assert {@text, 6} = ed({@text, 4}, :end, multiline: true)
      assert {@text, 12} = ed({@text, 8}, :end, multiline: true)
    end

    test "up and down keep the column, clamped to the shorter line" do
      # column 4 of the last line ("fghij"), one line up is "de": clamped to its end
      from = TextEdit.index_at(@text, 2, 4)
      {_, up} = ed({@text, from}, :up, multiline: true)
      assert {1, 2} = TextEdit.line_col(@text, up)

      # column 1 of the first line, down to "de", down again to "fghij"
      {_, d1} = ed({@text, 1}, :down, multiline: true)
      assert {1, 1} = TextEdit.line_col(@text, d1)
      {_, d2} = ed({@text, d1}, :down, multiline: true)
      assert {2, 1} = TextEdit.line_col(@text, d2)
    end

    test "up on the first line goes to the start, down on the last to the end" do
      assert {@text, 0} = ed({@text, 2}, :up, multiline: true)
      assert {@text, 12} = ed({@text, 9}, :down, multiline: true)
    end

    test "down then up returns to the same column when it fits" do
      {_, down} = ed({@text, 2}, :down, multiline: true)
      assert {1, 2} = TextEdit.line_col(@text, down)
      {_, down2} = ed({@text, down}, :down, multiline: true)
      assert {2, 2} = TextEdit.line_col(@text, down2)
    end
  end

  test "unknown keys are ignored" do
    assert :ignored = ed({"a", 0}, :f5)
    assert :ignored = ed({"a", 0}, {:other, 1})
  end

  describe "selections" do
    # "hello world", the selection "llo w" is anchor 2, caret 7
    @v "hello world"

    test "selection/2 and selected/2" do
      assert TextEdit.selection(7, 2) == {2, 7}
      assert TextEdit.selection(2, 7) == {2, 7}
      assert TextEdit.selection(3, 3) == nil
      assert TextEdit.selection(3, nil) == nil
      assert TextEdit.selected(@v, {2, 7}) == "llo w"
      assert TextEdit.selected(@v, nil) == ""
    end

    test "shift plus a movement grows the selection from the anchor" do
      assert TextEdit.apply_sel({@v, 3}, nil, {:select, :right}) == {@v, 4, 3}
      assert TextEdit.apply_sel({@v, 4}, 3, {:select, :right}) == {@v, 5, 3}
      assert TextEdit.apply_sel({@v, 4}, 3, {:select, :left}) == {@v, 3, nil}
      assert TextEdit.apply_sel({@v, 4}, 3, {:select, :home}) == {@v, 0, 3}
      assert TextEdit.apply_sel({@v, 4}, 3, {:select, :end}) == {@v, 11, 3}
    end

    test "selecting past either end is ignored" do
      assert TextEdit.apply_sel({@v, 0}, nil, {:select, :left}) == :ignored
      assert TextEdit.apply_sel({@v, 11}, nil, {:select, :right}) == :ignored
    end

    test "select all" do
      assert TextEdit.apply_sel({@v, 3}, nil, :select_all) == {@v, 11, 0}
      assert TextEdit.apply_sel({@v, 11}, 0, :select_all) == :ignored
      assert TextEdit.apply_sel({"", 0}, nil, :select_all) == :ignored
    end

    test "typing replaces the selection" do
      assert TextEdit.apply_sel({@v, 7}, 2, {:char, "X"}) == {"heXorld", 3, nil}
      assert TextEdit.apply_sel({@v, 2}, 7, {:char, "XY"}) == {"heXYorld", 4, nil}
    end

    test "backspace, delete and cut remove it" do
      for key <- [:backspace, :delete, :cut] do
        assert TextEdit.apply_sel({@v, 7}, 2, key) == {"heorld", 2, nil}
      end
    end

    test "cut with nothing selected does nothing" do
      assert TextEdit.apply_sel({@v, 3}, nil, :cut) == :ignored
    end

    test "arrows end the selection at its edges, other movements from the caret" do
      assert TextEdit.apply_sel({@v, 7}, 2, :left) == {@v, 2, nil}
      assert TextEdit.apply_sel({@v, 2}, 7, :right) == {@v, 7, nil}
      assert TextEdit.apply_sel({@v, 7}, 2, :end) == {@v, 11, nil}
      assert TextEdit.apply_sel({@v, 7}, 2, :home) == {@v, 0, nil}
    end

    test "without a selection it is plain editing" do
      assert TextEdit.apply_sel({@v, 5}, nil, {:char, "!"}) == {"hello! world", 6, nil}
      assert TextEdit.apply_sel({@v, 5}, nil, :left) == {@v, 4, nil}
      assert TextEdit.apply_sel({@v, 0}, nil, :left) == :ignored
    end

    test "the length limit counts without the selected text" do
      assert TextEdit.apply_sel({"abcde", 4}, 1, {:char, "XYZ"}, max: 5) == {"aXYZe", 4, nil}
      assert TextEdit.apply_sel({"abcde", 4}, 1, {:char, "XYZW"}, max: 5) == {"aXYZe", 4, nil}
    end

    test "typing nothing keeps the selection" do
      assert TextEdit.apply_sel({@v, 7}, 2, {:char, ""}) == :ignored
    end

    test "enter replaces the selection in a textarea only" do
      assert TextEdit.apply_sel({@v, 7}, 2, :enter, multiline: true) == {"he\norld", 3, nil}
      assert TextEdit.apply_sel({@v, 7}, 2, :enter) == :ignored
    end

    test "counts graphemes" do
      assert TextEdit.apply_sel({"héllo", 3}, 1, :backspace) == {"hlo", 1, nil}
    end

    test "word_range" do
      assert TextEdit.word_range("one two  three", 5) == {4, 7}
      assert TextEdit.word_range("one two  three", 7) == {4, 7}
      assert TextEdit.word_range("one two  three", 8) == nil
      assert TextEdit.word_range("one", 0) == {0, 3}
      assert TextEdit.word_range("", 0) == nil
    end
  end
end
