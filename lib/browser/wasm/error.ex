defmodule Browser.Wasm.Error do
  @moduledoc """
  The error of the WebAssembly engine. `kind` is `:compile` (a binary that is malformed or
  does not validate), `:link` (an import that is missing or has the wrong type) or `:trap`
  (a failure while code runs). The JS API turns them into `CompileError`, `LinkError` and
  `RuntimeError`.
  """
  defexception [:kind, :message]

  @doc "Raises an error of the given kind."
  def fail(kind, message), do: raise(__MODULE__, kind: kind, message: message)
end
