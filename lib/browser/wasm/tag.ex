defmodule Browser.Wasm.Tag do
  @moduledoc "An exception tag: its identity and the types of the values an exception carries."

  defstruct [:id, :type]

  def new(type), do: %__MODULE__{id: make_ref(), type: type}
end
