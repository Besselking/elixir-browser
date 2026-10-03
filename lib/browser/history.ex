defmodule Browser.History do
  @moduledoc "Pure back/forward stack."

  defstruct back: [], current: nil, forward: []

  def new, do: %__MODULE__{}

  def visit(%__MODULE__{current: nil} = h, url), do: %{h | current: url}
  def visit(%__MODULE__{current: url} = h, url), do: h

  def visit(%__MODULE__{} = h, url),
    do: %__MODULE__{back: [h.current | h.back], current: url, forward: []}

  @doc "The current entry's address changes without a new entry (`history.replaceState`)."
  def replace(%__MODULE__{} = h, url), do: %{h | current: url}

  def can_back?(%__MODULE__{back: b}), do: b != []
  def can_forward?(%__MODULE__{forward: f}), do: f != []

  def back(%__MODULE__{back: [prev | rest]} = h),
    do: {:ok, %__MODULE__{back: rest, current: prev, forward: [h.current | h.forward]}}

  def back(h), do: {:error, h}

  def forward(%__MODULE__{forward: [next | rest]} = h),
    do: {:ok, %__MODULE__{back: [h.current | h.back], current: next, forward: rest}}

  def forward(h), do: {:error, h}
end
