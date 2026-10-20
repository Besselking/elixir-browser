defmodule Browser.JS.Global do
  @moduledoc """
  The global object (`globalThis`, and `this` at the top of a script): a host object whose
  properties are the variables of the global scope.
  """

  alias Browser.JS.Interp
  require Browser.JS.Obj, as: Obj

  @unforgeable ~w(window document location top)

  @doc "The names of a window that a script cannot delete or define (`[LegacyUnforgeable]`)."
  def unforgeable, do: @unforgeable

  def new, do: Interp.new_host(__MODULE__, :global, Interp.proto(:object))

  def host_get(:global, key, self) when is_binary(key) do
    # a property `defineProperty` put on the object itself is read from there
    if own_defined?(self, key), do: :miss, else: host_get_var(key)
  end

  def host_get(:global, _key, _self), do: :miss

  defp host_get_var(key) do
    case Interp.lookup_scoped(Interp.global(), key) do
      {:ok, v} -> if Interp.global_lexical?(key), do: :miss, else: {:ok, v}
      :error -> :miss
    end
  end

  # NaN, Infinity and undefined are not writable
  def host_put(:global, key, _v, _self) when key in ["NaN", "Infinity", "undefined"],
    do: :readonly

  def host_put(:global, key, v, self) when is_binary(key) do
    # a property `defineProperty` put on the object itself follows its own attributes
    if own_defined?(self, key) do
      :miss
    else
      Interp.declare(Interp.global(), key, v)
      :ok
    end
  end

  def host_put(:global, _key, _v, _self), do: :miss

  defp own_defined?({:obj, id}, key), do: Obj.has_own?(Interp.deref(id), key)
  defp own_defined?(_, _), do: false

  def host_has(:global, key),
    do:
      is_binary(key) and Interp.lookup_scoped(Interp.global(), key) != :error and
        not Interp.global_lexical?(key)

  def host_delete(:global, key) when key in ["NaN", "Infinity", "undefined"], do: false

  def host_delete(:global, key) do
    scope = Interp.global()
    s = Interp.deref(scope)

    # (a `let`, `const` or class binding is no property: only an own property can go)
    if Map.has_key?(s.vars, key) and not Interp.global_lexical?(key) and
         not MapSet.member?(s.consts, key) and
         not Interp.global_fixed?(key) do
      Interp.store(scope, %{s | vars: Map.delete(s.vars, key)})
      # a property of the same name that `defineProperty` put on the object goes too
      if own_defined?(Map.get(s.vars, :this), key), do: :default, else: true
    else
      # what is no variable may be a property defined on the object itself
      if Map.has_key?(s.vars, key) and not Interp.global_lexical?(key),
        do: false,
        else: :default
    end
  end

  @doc """
  `Object.defineProperty` on the global object (or a window) for the key `key`, when it is a
  variable of the global scope of the running realm. Returns `:ok` when it is done, or the
  descriptor for the ordinary define on the object.

  A `var` or a function declaration is a property that is writable and enumerable but not
  configurable: a new value goes into the variable, and an accessor, `configurable: true` or
  `enumerable: false` is a TypeError. (`writable: false` is not kept.) Any other variable (a
  write to an undeclared name, `window.x = 1`, a built-in) is configurable: it leaves the
  scope and becomes an own property of the object, with the attributes it had (writable,
  enumerable and configurable) where `desc` gives none. A read of the name then finds that
  property (`Interp.lookup_var/2` reads the global object when the scope has no variable).
  """
  def define_var(key, desc) do
    scope = Interp.global()
    s = Interp.deref(scope)

    cond do
      key in ["NaN", "Infinity", "undefined"] or not Map.has_key?(s.vars, key) or
          Interp.global_lexical?(key) ->
        desc

      # (`window`, `document`, `location` and `top` of a window are accessors that are not
      # configurable: a define cannot change them)
      key in @unforgeable and Interp.global_fixed?(key) ->
        if Enum.any?([:value, :writable, :get, :set], &Map.has_key?(desc, &1)) or
             Map.get(desc, :configurable) == true or Map.get(desc, :enumerable) == false,
           do: Interp.throw_error("TypeError", "Cannot redefine property: #{key}")

        :ok

      Interp.global_fixed?(key) ->
        if Map.has_key?(desc, :get) or Map.has_key?(desc, :set) or
             Map.get(desc, :configurable) == true or Map.get(desc, :enumerable) == false,
           do: Interp.throw_error("TypeError", "Cannot redefine property: #{key}")

        if Map.has_key?(desc, :value),
          do: Interp.store(scope, %{s | vars: Map.put(s.vars, key, desc.value)})

        :ok

      true ->
        Interp.store(scope, %{s | vars: Map.delete(s.vars, key)})
        accessor? = Map.has_key?(desc, :get) or Map.has_key?(desc, :set)
        old = %{enumerable: true, configurable: true}

        old =
          if accessor?,
            do: old,
            else: Map.merge(old, %{value: Map.fetch!(s.vars, key), writable: true})

        Map.merge(old, desc)
    end
  end

  # the built-ins are not enumerable; what a script declares is
  @doc "Every own string-keyed property of the global object, built-ins included."
  def all_names do
    for k <- Map.keys(Interp.deref(Interp.global()).vars),
        is_binary(k),
        not Interp.global_lexical?(k),
        do: k
  end

  def host_keys(:global) do
    builtin = :erlang.get(:js_builtin_names)

    for k <- Map.keys(Interp.deref(Interp.global()).vars),
        is_binary(k),
        not MapSet.member?(builtin, k),
        not Interp.global_lexical?(k),
        do: k
  end
end
