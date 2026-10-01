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
