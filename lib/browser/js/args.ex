defmodule Browser.JS.Args do
  @moduledoc """
  The read of an argument of a native function: `arg(args, i)` is the argument at the index
  `i` of the list `args`, or `:undefined` when the list is shorter.

  It is a macro. For the index 0, 1 or 2 as a literal it is a match of the list, inline in
  the caller: a callback of an array method reads its arguments for each element, and
  `Enum.at/3` costs several calls. For another index it is `Enum.at/3`.
  """

  @doc "The argument at the index `i` of `args`, or `:undefined`."
  defmacro arg(args, 0) do
    quote generated: true do
      case unquote(args) do
        [a | _] -> a
        _ -> :undefined
      end
    end
  end

  defmacro arg(args, 1) do
    quote generated: true do
      case unquote(args) do
        [_, a | _] -> a
        _ -> :undefined
      end
    end
  end

  defmacro arg(args, 2) do
    quote generated: true do
      case unquote(args) do
        [_, _, a | _] -> a
        _ -> :undefined
      end
    end
  end

  defmacro arg(args, i), do: quote(do: Enum.at(unquote(args), unquote(i), :undefined))
end
