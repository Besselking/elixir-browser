defmodule Browser.Re do
  @moduledoc """
  Regular expressions that are compiled one time only.

  A `~r` literal (and a module attribute that holds one) loads its pattern again each time it
  runs. On a hot path this costs more than the match. `re/1` keeps the pattern in
  `:persistent_term` after the first use:

      import Browser.Re
      Regex.match?(re(~r/\\A\\d+\\z/), v)

  The key is the text and the modifiers of the regex, so two equal literals share one entry.
  """

  @doc "The compiled regex of a `~r` literal, from `:persistent_term` after the first use."
  defmacro re({:sigil_r, _, [{:<<>>, _, [source]}, mods]} = regex) when is_binary(source) do
    key = {__MODULE__, source, mods}

    quote do
      case :persistent_term.get(unquote(Macro.escape(key)), nil) do
        nil -> Browser.Re.keep(unquote(Macro.escape(key)), unquote(regex))
        compiled -> compiled
      end
    end
  end

  defmacro re(other) do
    raise ArgumentError,
          "re/1 takes a ~r literal with no interpolation, got: #{Macro.to_string(other)}"
  end

  @doc """
  The regex of a `source` that is made at compile time (from module attributes), with the
  modifiers `mods` (such as `~c"u"`). As for `re/1`, it is compiled at the first use only and
  kept in `:persistent_term`, under the key that `re/1` uses for the same literal. A module
  attribute that holds a regex loads its pattern again each time it runs.
  """
  def compiled(source, mods) when is_binary(source) and is_list(mods) do
    case :persistent_term.get({__MODULE__, source, mods}, nil) do
      nil -> keep({__MODULE__, source, mods}, Regex.compile!(source, List.to_string(mods)))
      compiled -> compiled
    end
  end

  @doc false
  def keep(key, regex) do
    :persistent_term.put(key, regex)
    regex
  end

  # The white space that `String.split/1` splits at: the Unicode white space without the
  # no-break spaces (U+00A0, U+2007, U+202F)
  @spaces [" ", "\t", "\n", "\v", "\f", "\r"] ++
            Enum.map(
              [0x85, 0x1680] ++
                Enum.to_list(0x2000..0x2006) ++
                [0x2008, 0x2009, 0x200A, 0x2028, 0x2029, 0x205F, 0x3000],
              &<<&1::utf8>>
            )

  @doc """
  The words of `text`, as `String.split/1` gives them. `String.split/1` makes its pattern again
  on each call (about 5 µs), and the style and the layout split the class and some properties of
  each element. Here the pattern is compiled one time and kept in `:persistent_term`.
  """
  def split_words(""), do: []

  def split_words(text) when is_binary(text),
    do: :binary.split(text, spaces(), [:global, :trim_all])

  defp spaces do
    case :persistent_term.get({__MODULE__, :spaces}, nil) do
      nil ->
        pattern = :binary.compile_pattern(@spaces)
        :persistent_term.put({__MODULE__, :spaces}, pattern)
        pattern

      pattern ->
        pattern
    end
  end
end
