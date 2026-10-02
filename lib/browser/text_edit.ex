defmodule Browser.TextEdit do
  @moduledoc """
  Editing a string with a caret, for text inputs and textareas.

  An edit state is `{value, caret}` where `caret` counts graphemes from the start
  (0 = before the first character), so accented letters and emoji move and delete
  as one character. `apply/3` takes a key and returns the new `{value, caret}`, or
  `:ignored` when the key doesn't edit anything.

  Keys: `{:char, text}` (typed or pasted text), `:backspace`, `:delete`, `:left`,
  `:right`, `:up`, `:down`, `:home`, `:end`, and `:enter` (a newline, in
  multi-line mode only).

  Options: `multiline: true` for textareas, `max: n` for a length limit.
  """

  @type state :: {String.t(), non_neg_integer}

  @spec apply(state, term, keyword) :: state | :ignored
  def apply(state, key, opts \\ [])

  def apply({value, caret}, {:char, text}, opts) do
    case sanitize(text, opts[:multiline] == true) do
      "" -> :ignored
      clean -> insert({value, caret}, clean, opts[:max])
    end
  end

  def apply(state, :enter, opts) do
    if opts[:multiline] == true, do: insert(state, "\n", opts[:max]), else: :ignored
  end

  def apply({_value, 0}, :backspace, _opts), do: :ignored

  def apply({value, caret}, :backspace, _opts) do
    {before, rest} = String.split_at(value, caret)
    {String.slice(before, 0, caret - 1) <> rest, caret - 1}
  end

  def apply({value, caret}, :delete, _opts) do
    if caret >= String.length(value) do
      :ignored
    else
      {before, rest} = String.split_at(value, caret)
      {before <> String.slice(rest, 1..-1//1), caret}
    end
  end

  def apply({value, caret}, :left, _opts), do: moved(value, caret, max(caret - 1, 0))

  def apply({value, caret}, :right, _opts),
    do: moved(value, caret, min(caret + 1, String.length(value)))

  def apply({value, caret}, :home, opts), do: moved(value, caret, line_start(value, caret, opts))
  def apply({value, caret}, :end, opts), do: moved(value, caret, line_end(value, caret, opts))

  def apply({value, caret}, :up, opts) do
    if opts[:multiline] == true,
      do: moved(value, caret, vertical(value, caret, -1)),
      else: moved(value, caret, 0)
  end

  def apply({value, caret}, :down, opts) do
    if opts[:multiline] == true,
      do: moved(value, caret, vertical(value, caret, 1)),
      else: moved(value, caret, String.length(value))
  end

  def apply(_state, _key, _opts), do: :ignored

  # -- selections ----------------------------------------------------------------------

  @doc """
  Like `apply/3` for a field with a selection, which runs from `anchor` to the caret
  (`anchor` is nil when nothing is selected). Returns `{value, caret, anchor}`, or
  `:ignored`.

  Besides the keys of `apply/3` it takes `{:select, direction}` (shift plus an arrow, home
  or end: move the caret, keep the anchor), `:select_all` and `:cut` (delete the
  selection). Typing, pasting, Enter, Backspace and Delete replace the selection; moving
  without shift ends it, going to its start (`:left`) or end (`:right`).
  """
  def apply_sel({value, caret}, anchor, key, opts \\ []) do
    range = selection(caret, anchor)

    case key do
      {:select, dir} ->
        to =
          case __MODULE__.apply({value, caret}, dir, opts) do
            {_value, moved} -> moved
            :ignored -> caret
          end

        anchor = anchor || caret
        if to == caret, do: :ignored, else: {value, to, if(anchor == to, do: nil, else: anchor)}

      :select_all ->
        len = String.length(value)
        if len == 0 or range == {0, len}, do: :ignored, else: {value, len, 0}

      :cut ->
        if range, do: delete_range(value, range), else: :ignored

      key when key in [:left, :right] and range != nil ->
        {from, to} = range
        {value, if(key == :left, do: from, else: to), nil}

      key when key in [:backspace, :delete] and range != nil ->
        delete_range(value, range)

      {:char, _} = key when range != nil ->
        replace(value, range, key, opts)

      :enter when range != nil ->
        replace(value, range, :enter, opts)

      key ->
        case __MODULE__.apply({value, caret}, key, opts) do
          {v, c} -> {v, c, nil}
          :ignored -> if anchor == nil, do: :ignored, else: {value, caret, nil}
        end
    end
  end

  @doc "The `{from, to}` range selected between `anchor` and `caret`, or nil when empty."
  def selection(_caret, nil), do: nil
  def selection(caret, caret), do: nil
  def selection(caret, anchor), do: {min(caret, anchor), max(caret, anchor)}

  @doc "The selected text."
  def selected(_value, nil), do: ""
  def selected(value, {from, to}), do: String.slice(value, from, to - from)

  @doc "The range of the word (run of non-space characters) at caret index `at`, or nil."
  def word_range(value, at) do
    chars = String.graphemes(value)
    space? = fn c -> String.trim(c) == "" end
    i = if at < length(chars) and not space?.(Enum.at(chars, at)), do: at, else: at - 1

    if i < 0 or i >= length(chars) or space?.(Enum.at(chars, i)) do
      nil
    else
      back =
        chars |> Enum.take(i) |> Enum.reverse() |> Enum.take_while(&(not space?.(&1))) |> length()

      fwd = chars |> Enum.drop(i) |> Enum.take_while(&(not space?.(&1))) |> length()
      {i - back, i + fwd}
    end
  end

  defp delete_range(value, {from, to}) do
    {String.slice(value, 0, from) <> String.slice(value, to..-1//1), from, nil}
  end

  # typing over a selection: the selected text goes first, the length limit counts without it
  defp replace(value, {from, _to} = range, key, opts) do
    {rest, _, _} = delete_range(value, range)

    case __MODULE__.apply({rest, from}, key, opts) do
      {v, c} -> {v, c, nil}
      :ignored -> :ignored
    end
  end

  # -- lines -----------------------------------------------------------------------

  @doc "The caret's `{line, column}` (both from 0) in a multi-line value."
  def line_col(value, caret) do
    before = String.slice(value, 0, caret)
    lines = String.split(before, "\n")
    {length(lines) - 1, lines |> List.last() |> String.length()}
  end

  @doc "The caret index for `{line, column}`, clamped to the value and to that line."
  def index_at(value, line, col) do
    lines = String.split(value, "\n")
    line = line |> max(0) |> min(length(lines) - 1)
    col = col |> max(0) |> min(String.length(Enum.at(lines, line)))

    lines
    |> Enum.take(line)
    |> Enum.reduce(0, fn l, acc -> acc + String.length(l) + 1 end)
    |> Kernel.+(col)
  end

  defp line_start(value, caret, opts) do
    if opts[:multiline] == true do
      {line, _} = line_col(value, caret)
      index_at(value, line, 0)
    else
      0
    end
  end

  defp line_end(value, caret, opts) do
    if opts[:multiline] == true do
      {line, _} = line_col(value, caret)
      index_at(value, line, String.length(value))
    else
      String.length(value)
    end
  end

  # move one line up/down keeping the column where possible
  defp vertical(value, caret, delta) do
    {line, col} = line_col(value, caret)
    lines = length(String.split(value, "\n"))

    cond do
      line + delta < 0 -> 0
      line + delta >= lines -> String.length(value)
      true -> index_at(value, line + delta, col)
    end
  end

  # -- editing ---------------------------------------------------------------------

  defp insert({value, caret}, text, max) do
    room = if max, do: max(max - String.length(value), 0), else: String.length(text)

    case String.slice(text, 0, room) do
      "" ->
        :ignored

      kept ->
        {before, rest} = String.split_at(value, caret)
        {before <> kept <> rest, caret + String.length(kept)}
    end
  end

  defp moved(_value, caret, caret), do: :ignored
  defp moved(value, _caret, to), do: {value, to}

  # line breaks only survive in multi-line fields, and other control characters never do
  defp sanitize(text, multiline?) do
    text = String.replace(text, "\r\n", "\n")
    text = if multiline?, do: text, else: String.replace(text, ~r/[\r\n]+/, " ")
    String.replace(text, ~r/[\x00-\x08\x0B-\x1F\x7F]/, "")
  end
end
