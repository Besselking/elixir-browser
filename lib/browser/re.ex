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

  @doc false
  def keep(key, regex) do
    :persistent_term.put(key, regex)
    regex
  end
end
