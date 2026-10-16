defmodule Browser.JS.Pos do
  @moduledoc """
  The position of a statement (its file and its line) as one small integer.

  When a script has a file name, the parser puts a node `{:pos, pos}` before a statement
  (`Browser.JS.Parser`). Before the statement runs, the interpreter and the compiled code
  write `pos` to the process key `:js_pos`, and a call keeps it in the cell of the call
  stack. The stack text of an error (`Interp.stack_string/1`) and the console line of an
  uncaught `throw` read it back with `decode/1`.

  An integer is an immediate term. A write of an immediate value over an immediate value
  in the process dictionary allocates no memory. A write of a tuple `{file, line}`
  allocates a new entry each time. The write of `:js_pos` occurs before each statement and
  again after each call, so the tuple form was a large part of the allocation of a script.

  `pos` is `id <<< 28 ||| line`. `id` is the number of the file in a table of the VM
  (`:persistent_term`), so that a parse in one process can run in another process
  (`Browser.JS.eval/2` parses in the caller and runs in a new process). The number of a
  file is a hash of its name. When two names have the same hash, the second name gets the
  next free number. A lock of `:global` makes each new entry, so that two processes cannot
  give one number to two names. The table only grows: a file keeps its number until the VM
  stops. The parser asks for the number once for each parse.
  """

  import Bitwise

  @line_bits 28
  @line_max (1 <<< @line_bits) - 1
  # (with 31 bits for the number, `pos` stays below 2^59, so it is a small integer)
  @ids 1 <<< 31

  @doc "The number of the file `file` in the table of the VM. It adds the file when it is new."
  def file_id(file) do
    case find(file, :erlang.phash2(file, @ids)) do
      {:found, id} ->
        id

      :new ->
        :global.trans({__MODULE__, self()}, fn -> add(file, :erlang.phash2(file, @ids)) end, [
          node()
        ])
    end
  end

  @doc "The position of line `line` of the file with the number `id` (`file_id/1`)."
  def at(id, line), do: id <<< @line_bits ||| min(line, @line_max)

  @doc "The position of line `line` of the file `file`."
  def encode(file, line), do: at(file_id(file), line)

  @doc "The file and the line of the position `pos` as `{file, line}`, or `nil` for no position."
  def decode(pos) when is_integer(pos),
    do: {:persistent_term.get({__MODULE__, pos >>> @line_bits}), pos &&& @line_max}

  def decode(_), do: nil

  # The number of `file` from the number `id` on: `{:found, id}`, or `:new` when the first
  # free number comes before the file.
  defp find(file, id) do
    case :persistent_term.get({__MODULE__, id}, nil) do
      ^file -> {:found, id}
      nil -> :new
      _ -> find(file, rem(id + 1, @ids))
    end
  end

  # (under the lock: an other process can have added the file since `find/2`)
  defp add(file, id) do
    case :persistent_term.get({__MODULE__, id}, nil) do
      ^file ->
        id

      nil ->
        :persistent_term.put({__MODULE__, id}, file)
        id

      _ ->
        add(file, rem(id + 1, @ids))
    end
  end
end
