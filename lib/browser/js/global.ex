defmodule Browser.JS.Global do
  @moduledoc """
  The global object (`globalThis`, and `this` at the top of a script): a host object whose
  properties are the variables of the global scope.
  """

  alias Browser.JS.Interp

  def new, do: Interp.new_host(__MODULE__, :global, Interp.proto(:object))

  def host_get(:global, key, _self) when is_binary(key) do
    case Interp.lookup_scoped(Interp.global(), key) do
      {:ok, v} -> if Interp.global_lexical?(key), do: :miss, else: {:ok, v}
      :error -> :miss
    end
  end

  def host_get(:global, _key, _self), do: :miss

  # NaN, Infinity and undefined are not writable
  def host_put(:global, key, _v, _self) when key in ["NaN", "Infinity", "undefined"], do: :ok

  def host_put(:global, key, v, _self) when is_binary(key) do
    Interp.declare(Interp.global(), key, v)
    :ok
  end

  def host_put(:global, _key, _v, _self), do: :miss

  def host_has(:global, key),
    do:
      is_binary(key) and Interp.lookup_scoped(Interp.global(), key) != :error and
        not Interp.global_lexical?(key)

  def host_delete(:global, key) do
    scope = Interp.global()
    s = Interp.deref(scope)

    if Map.has_key?(s.vars, key) and not MapSet.member?(s.consts, key) and
         not Interp.global_fixed?(key) do
      Interp.store(scope, %{s | vars: Map.delete(s.vars, key)})
      true
    else
      not Map.has_key?(s.vars, key)
    end
  end

  # the built-ins are not enumerable; what a script declares is
  def host_keys(:global) do
    builtin = :erlang.get(:js_builtin_names)

    for k <- Map.keys(Interp.deref(Interp.global()).vars),
        is_binary(k),
        not MapSet.member?(builtin, k),
        not Interp.global_lexical?(k),
        do: k
  end
end
