defmodule Browser.Wasm.Global do
  @moduledoc "A global variable; the value lives in the process dictionary."

  defstruct [:id, :type, :mut]

  def new(type, mut, value) do
    id = make_ref()
    Process.put({__MODULE__, id}, value)
    %__MODULE__{id: id, type: type, mut: mut}
  end

  def get(%__MODULE__{id: id}), do: Process.get({__MODULE__, id})
  def set(%__MODULE__{id: id}, v), do: Process.put({__MODULE__, id}, v) && :ok
end
