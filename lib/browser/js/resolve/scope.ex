defmodule Browser.JS.Resolve.Scope do
  @moduledoc """
  The facts the resolver knows about one block, loop, for-each head, switch
  or catch clause inside a rewritten function.

  The resolver adds a `Scope` (or `nil`) as the last element of the statement
  node. `nil` means that the statement declares nothing, so the interpreter runs
  it without a scan.

  A scope gets a frame of its own (`frame: true`) only when an inner function
  captures one of its names, or when a dynamic function sits inside it. A
  frameless scope keeps its names in slots of the nearest frame; the statement
  resets those slots to `:tdz` at entry.

  The fields:

  - `kind`: `:block`, `:loop`, `:each`, `:switch` or `:catch`.
  - `frame`: true when the scope has a frame of its own (step 2c).
  - `slots`: name to slot index. For a frameless scope the index is a slot of
    the home frame.
  - `kinds`: slot index to `:let`, `:const`, `:class`, `:using` or `:fun`.
  - `hoist`: `{slot, function_node}` pairs to instantiate at entry.
  - `size`, `template`: the frame size and the initial values of the slots
    from position 6, for a framed scope only.
  - `tdz`: the home-frame slots a frameless scope resets to `:tdz` at entry.
  - `per_iter`: a framed `for` head with `let` copies its frame per iteration.
  """

  defstruct kind: :block,
            frame: false,
            slots: %{},
            kinds: %{},
            hoist: [],
            size: 5,
            template: [],
            tdz: [],
            per_iter: false

  @type t :: %__MODULE__{}
end
