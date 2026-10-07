defmodule Browser.Interact do
  @moduledoc """
  The parts of keyboard and mouse interaction that don't need a window.

  The session turns wx events into plain data and calls these functions, which makes
  them testable: key normalization, tab order, placing the caret from a click, and
  scrolling a field so its caret stays visible.
  """

  alias Browser.TextEdit

  @zero_width "​"

  # -- keys ------------------------------------------------------------------------

  @doc """
  Normalizes a key event given as `%{code:, char:, ctrl?:, meta?:, shift?:, alt?:}`
  (wx key code, unicode character, modifier flags) to:

    * `{:char, text}` for typed text
    * `:backspace`, `:delete`, `:enter`, `:tab`, `:shift_tab`, `:escape`
    * `:left`, `:right`, `:up`, `:down`, `:home`, `:end`, `:page_up`, `:page_down`
    * `{:select, :left | :right | :up | :down | :home | :end}` for shift and a movement key
    * `:paste`, `:copy`, `:cut` and `:select_all` for those shortcuts
    * `{:shortcut, letter}` for the control or command key with `b`, `i`, `u`, `z` or `y` (and
      `"Z"` for shift with `z`), which an editing region takes for formatting and undo
    * `:ignore` for everything else
  """
  def key(%{ctrl?: ctrl, meta?: meta, alt?: alt} = event) when ctrl or meta or alt do
    cond do
      (ctrl or meta) and not alt and paste_key?(event) -> :paste
      (ctrl or meta) and not alt and letter_key?(event, [?c, ?C, 3]) -> :copy
      (ctrl or meta) and not alt and letter_key?(event, [?a, ?A, 1]) -> :select_all
      (ctrl or meta) and not alt and letter_key?(event, [?x, ?X, 24]) -> :cut
      (ctrl or meta) and not alt -> shortcut(event)
      alt and not (ctrl or meta) -> printable(event)
      true -> :ignore
    end
  end

  # shift plus a movement key selects while moving
  def key(%{code: code, shift?: true}) when code in 312..317 do
    case key(%{code: code, shift?: false}) do
      dir when is_atom(dir) -> {:select, dir}
    end
  end

  def key(%{code: 8}), do: :backspace
  def key(%{code: 127}), do: :delete
  def key(%{code: code}) when code in [13, 370], do: :enter
  def key(%{code: 9, shift?: true}), do: :shift_tab
  def key(%{code: 9}), do: :tab
  def key(%{code: 27}), do: :escape
  def key(%{code: 312}), do: :end
  def key(%{code: 313}), do: :home
  def key(%{code: 314}), do: :left
  def key(%{code: 315}), do: :up
  def key(%{code: 316}), do: :right
  def key(%{code: 317}), do: :down
  def key(%{code: 366}), do: :page_up
  def key(%{code: 367}), do: :page_down
  def key(event), do: printable(event)

  # a letter with the command/control key that an editing region uses
  defp shortcut(%{shift?: shift} = event) do
    Enum.find_value(~w(b i u z y), :ignore, fn letter ->
      if ctrl_letter?(event, letter) do
        if letter == "z" and shift, do: {:shortcut, "Z"}, else: {:shortcut, letter}
      end
    end)
  end

  # the letter as a character, a control code (Ctrl+B is 2) or the key code of the capital; Tab
  # is also code 9, so Ctrl+I only counts as the letter
  defp ctrl_letter?(%{char: char, code: code}, <<l>>) do
    (char in [l, l - 32, l - 96] and code != 9) or code == l - 32
  end

  # `v` pressed with the command/control key (some platforms send the control code 22)
  defp paste_key?(event), do: letter_key?(event, [?v, ?V, 22])

  # a letter pressed with the command/control key, as a character or as its control code
  defp letter_key?(%{char: char, code: code}, keys), do: char in keys or code in keys

  defp printable(%{char: char}) when is_integer(char) and char >= 32 and char != 127 do
    if char in 0xD800..0xDFFF or char > 0x10FFFF, do: :ignore, else: {:char, <<char::utf8>>}
  end

  defp printable(_event), do: :ignore

  # -- focus -----------------------------------------------------------------------

  @doc "The control after (`:forward`) or before (`:backward`) `current` in `order`, wrapping."
  def next_focus([], _current, _direction), do: nil

  def next_focus(order, nil, :forward), do: hd(order)
  def next_focus(order, nil, :backward), do: List.last(order)

  def next_focus(order, current, direction) do
    case Enum.find_index(order, &(&1 == current)) do
      nil ->
        next_focus(order, nil, direction)

      i ->
        step = if direction == :forward, do: 1, else: -1
        Enum.at(order, Integer.mod(i + step, length(order)))
    end
  end

  # -- the caret -------------------------------------------------------------------

  @doc """
  The caret's `{line, column}` as laid out: relative to what is shown, i.e. after the
  field's scroll (characters for a single line, lines for a textarea).
  """
  def caret_position(value, caret, scroll, true = _multiline) do
    {line, col} = TextEdit.line_col(value, caret)
    {line - scroll, col}
  end

  def caret_position(_value, caret, scroll, false = _multiline), do: {0, max(caret - scroll, 0)}

  @doc """
  The caret index for a click at page position `{x, y}` in a field, given the laid out
  `items` (text items with the field's `cid`). `measure` is `(text, item) -> width`.
  """
  def caret_at(items, cid, value, scroll, multiline?, {x, y}, measure) do
    texts =
      items
      |> Enum.filter(&(&1.type == :text and Map.get(&1, :cid) == cid))
      |> Enum.sort_by(&{&1.y, &1.x})

    case texts do
      [] ->
        0

      _ ->
        {item, line} = nearest_line(texts, y)
        col = if value == "", do: 0, else: column_at(item, x, measure)

        if multiline? do
          TextEdit.index_at(value, line + scroll, col)
        else
          min(scroll + col, String.length(value))
        end
    end
  end

  defp nearest_line(texts, y) do
    texts
    |> Enum.with_index()
    |> Enum.min_by(fn {it, _} -> distance(y, it.y, it.y + round(it.h * 1.25)) end)
  end

  defp distance(y, top, bottom) do
    cond do
      y < top -> top - y
      y > bottom -> y - bottom
      true -> 0
    end
  end

  # the character boundary closest to x
  defp column_at(%{text: @zero_width}, _x, _measure), do: 0

  defp column_at(item, x, measure) do
    len = String.length(item.text)

    0..len
    |> Enum.min_by(fn i ->
      width = if i == 0, do: 0, else: measure.(String.slice(item.text, 0, i), item)
      abs(item.x + width - x)
    end)
  end

  # -- scrolling a field to keep the caret in view ---------------------------------

  @doc """
  The smallest scroll (in characters) of a single-line field for which the text from
  the scroll to the caret fits into `inner_width`, never scrolling past the caret.
  """
  def fit_chars(value, caret, scroll, inner_width, font, measure) do
    scroll = min(scroll, caret)

    Enum.find(scroll..caret//1, caret, fn s ->
      s == caret or measure.(String.slice(value, s, caret - s), font) <= inner_width
    end)
  end

  @doc "The scroll (in lines) of a textarea that keeps `caret_line` among `visible` lines."
  def fit_lines(caret_line, scroll, visible) when visible > 0 do
    cond do
      caret_line < scroll -> caret_line
      caret_line >= scroll + visible -> caret_line - visible + 1
      true -> scroll
    end
  end

  def fit_lines(_caret_line, scroll, _visible), do: scroll
end
