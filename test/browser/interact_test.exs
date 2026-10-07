defmodule Browser.InteractTest do
  use ExUnit.Case, async: true
  alias Browser.Interact

  defp ev(code, opts \\ []) do
    Map.merge(
      %{code: code, char: code, ctrl?: false, meta?: false, shift?: false, alt?: false},
      Map.new(opts)
    )
  end

  describe "key/1" do
    test "special keys" do
      assert Interact.key(ev(8)) == :backspace
      assert Interact.key(ev(127)) == :delete
      assert Interact.key(ev(13)) == :enter
      assert Interact.key(ev(370)) == :enter
      assert Interact.key(ev(9)) == :tab
      assert Interact.key(ev(9, shift?: true)) == :shift_tab
      assert Interact.key(ev(27)) == :escape
      assert Interact.key(ev(314)) == :left
      assert Interact.key(ev(316)) == :right
      assert Interact.key(ev(315)) == :up
      assert Interact.key(ev(317)) == :down
      assert Interact.key(ev(313)) == :home
      assert Interact.key(ev(312)) == :end
      assert Interact.key(ev(366)) == :page_up
      assert Interact.key(ev(367)) == :page_down
    end

    test "printable characters, including space and unicode" do
      assert Interact.key(ev(?a)) == {:char, "a"}
      assert Interact.key(ev(?A, shift?: true)) == {:char, "A"}
      assert Interact.key(ev(32)) == {:char, " "}
      assert Interact.key(ev(0, char: 0xE9)) == {:char, "é"}
      assert Interact.key(ev(0, char: 0x1F44D)) == {:char, "👍"}
    end

    test "control codes and unknown keys are ignored" do
      assert Interact.key(ev(0, char: 0)) == :ignore
      assert Interact.key(ev(0, char: 7)) == :ignore
      assert Interact.key(ev(345, char: 0)) == :ignore
      assert Interact.key(ev(0, char: 0xD800)) == :ignore
    end

    test "the copy and select-all shortcuts" do
      assert Interact.key(ev(?c, meta?: true)) == :copy
      assert Interact.key(ev(?C, ctrl?: true)) == :copy
      assert Interact.key(ev(3, ctrl?: true, char: 3)) == :copy
      assert Interact.key(ev(?a, meta?: true)) == :select_all
      assert Interact.key(ev(1, ctrl?: true, char: 1)) == :select_all
      assert Interact.key(ev(?c, meta?: true, alt?: true)) != :copy
    end

    test "formatting and undo shortcuts" do
      assert Interact.key(ev(?b, ctrl?: true)) == {:shortcut, "b"}
      assert Interact.key(ev(?z, meta?: true)) == {:shortcut, "z"}
      assert Interact.key(ev(?z, meta?: true, shift?: true)) == {:shortcut, "Z"}
    end

    test "cut, and shift with movement keys" do
      assert Interact.key(ev(?x, meta?: true)) == :cut
      assert Interact.key(ev(24, ctrl?: true, char: 24)) == :cut
      assert Interact.key(ev(316, shift?: true)) == {:select, :right}
      assert Interact.key(ev(314, shift?: true)) == {:select, :left}
      assert Interact.key(ev(313, shift?: true)) == {:select, :home}
      assert Interact.key(ev(312, shift?: true)) == {:select, :end}
      assert Interact.key(ev(315, shift?: true)) == {:select, :up}
      assert Interact.key(ev(316)) == :right
    end

    test "the paste shortcut, with command or control" do
      assert Interact.key(ev(?V, meta?: true)) == :paste
      assert Interact.key(ev(?v, ctrl?: true)) == :paste
      assert Interact.key(ev(22, ctrl?: true, char: 22)) == :paste
    end

    test "other shortcuts do nothing, and alt keeps typing characters" do
      assert Interact.key(ev(?q, meta?: true)) == :ignore
      assert Interact.key(ev(?k, ctrl?: true)) == :ignore
      assert Interact.key(ev(?e, alt?: true, char: 0xE9)) == {:char, "é"}
    end
  end

  describe "next_focus/3" do
    test "moves through the order and wraps" do
      order = [2, 5, 9]
      assert Interact.next_focus(order, 2, :forward) == 5
      assert Interact.next_focus(order, 9, :forward) == 2
      assert Interact.next_focus(order, 5, :backward) == 2
      assert Interact.next_focus(order, 2, :backward) == 9
    end

    test "from nothing it starts at the first or last" do
      assert Interact.next_focus([2, 5, 9], nil, :forward) == 2
      assert Interact.next_focus([2, 5, 9], nil, :backward) == 9
    end

    test "a control no longer in the order counts as nothing" do
      assert Interact.next_focus([2, 5], 7, :forward) == 2
    end

    test "an empty order has nowhere to go" do
      assert Interact.next_focus([], nil, :forward) == nil
      assert Interact.next_focus([], 3, :backward) == nil
    end
  end

  describe "caret_position/4" do
    test "single line: the column after the scroll" do
      assert Interact.caret_position("hello", 3, 0, false) == {0, 3}
      assert Interact.caret_position("hello", 4, 2, false) == {0, 2}
      assert Interact.caret_position("hello", 1, 3, false) == {0, 0}
    end

    test "multi-line: line and column, minus the line scroll" do
      assert Interact.caret_position("ab\ncd\nef", 4, 0, true) == {1, 1}
      assert Interact.caret_position("ab\ncd\nef", 7, 1, true) == {1, 1}
    end
  end

  describe "caret_at/7" do
    # every character is 10px wide
    defp measure(text, _item), do: String.length(text) * 10

    defp item(text, x, y, opts \\ []) do
      Map.merge(%{type: :text, text: text, x: x, y: y, h: 16, size: 16, cid: 7}, Map.new(opts))
    end

    test "a click lands on the nearest character boundary" do
      items = [item("hello", 100, 20)]
      at = fn x -> Interact.caret_at(items, 7, "hello", 0, false, {x, 25}, &measure/2) end
      assert at.(100) == 0
      assert at.(104) == 0
      assert at.(106) == 1
      assert at.(125) in [2, 3]
      assert at.(150) == 5
      assert at.(400) == 5
      assert at.(10) == 0
    end

    test "the field's scroll is added back" do
      items = [item("cdef", 100, 20)]
      assert Interact.caret_at(items, 7, "abcdef", 2, false, {120, 25}, &measure/2) == 4
    end

    test "an empty field puts the caret at 0" do
      items = [item("Search", 100, 20)]
      assert Interact.caret_at(items, 7, "", 0, false, {150, 25}, &measure/2) == 0
    end

    test "a textarea's line comes from the click's height" do
      text = "one\ntwo\nthree"
      items = [item("one", 100, 20), item("two", 100, 40), item("three", 100, 60)]
      at = fn y, x -> Interact.caret_at(items, 7, text, 0, true, {x, y}, &measure/2) end
      assert at.(22, 100) == 0
      assert at.(45, 120) == 4 + 2
      assert at.(65, 130) == 8 + 3
      # below the last line and above the first clamp to them
      assert at.(500, 100) == 8
      assert at.(0, 100) == 0
    end

    test "a scrolled textarea adds the hidden lines" do
      text = "a\nb\nc\nd"
      items = [item("c", 100, 20), item("d", 100, 40)]
      assert Interact.caret_at(items, 7, text, 2, true, {100, 42}, &measure/2) == 6
    end

    test "only the field's own text counts" do
      items = [item("other", 100, 20, cid: 3), item("mine", 100, 60)]
      assert Interact.caret_at(items, 7, "mine", 0, false, {140, 25}, &measure/2) == 4
      assert Interact.caret_at([], 7, "mine", 0, false, {140, 25}, &measure/2) == 0
    end
  end

  describe "fit_chars/6" do
    defp fit(value, caret, scroll, width),
      do: Interact.fit_chars(value, caret, scroll, width, %{}, &measure/2)

    test "no scrolling while the text fits" do
      assert fit("hello", 5, 0, 100) == 0
    end

    test "scrolls forward just enough to show the caret" do
      assert fit("abcdefghij", 10, 0, 50) == 5
      assert fit("abcdefghij", 8, 0, 50) == 3
    end

    test "scrolls back when the caret moves left of the visible part" do
      assert fit("abcdefghij", 2, 5, 50) == 2
      assert fit("abcdefghij", 6, 5, 50) == 5
    end

    test "keeps an existing scroll while the caret is still visible" do
      assert fit("abcdefghij", 9, 5, 50) == 5
    end

    test "always leaves the caret reachable even in a tiny field" do
      assert fit("abc", 3, 0, 0) == 3
    end
  end

  describe "fit_lines/3" do
    test "keeps the caret line among the visible lines" do
      assert Interact.fit_lines(0, 0, 3) == 0
      assert Interact.fit_lines(2, 0, 3) == 0
      assert Interact.fit_lines(3, 0, 3) == 1
      assert Interact.fit_lines(9, 0, 3) == 7
      assert Interact.fit_lines(1, 4, 3) == 1
      assert Interact.fit_lines(5, 4, 3) == 4
    end

    test "no visible lines changes nothing" do
      assert Interact.fit_lines(5, 2, 0) == 2
    end
  end
end
