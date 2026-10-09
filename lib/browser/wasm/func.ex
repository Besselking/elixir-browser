defmodule Browser.Wasm.Func do
  @moduledoc """
  A function instance. `impl` is `{:wasm, instance_id, code_index}` or `{:host, fun}`, where
  `fun` takes the argument list and returns the list of results.
  """

  defstruct [:id, :type, :impl, :ct]

  def host(type, fun), do: %__MODULE__{id: make_ref(), type: type, impl: {:host, fun}}
end
