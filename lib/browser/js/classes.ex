defmodule Browser.JS.Classes do
  @moduledoc """
  `class` for the JavaScript runtime: construction, `extends`, `super`, static members,
  accessors and public fields.

  A class is a function object with a `class_info` field: its parent class (or nil), whether it
  is derived, its instance fields and the scope they are evaluated in. A derived constructor starts
  with `this` unset (`:uninit_this`); `super(...)` constructs the parent with the same
  `new.target` and sets it. Methods remember the object they were defined on (`home`), which is
  where `super.method` starts looking, one prototype up.
  """

  import Browser.JS.Interp, except: [get: 2, put: 3]
  alias Browser.JS.{Interp, Props}

  @doc "Evaluates a class definition: the constructor function."
  def define({:class, name, super_node, members}, env) do
    cenv = Interp.new_scope(env)

    parent =
      case super_node do
        nil -> nil
        node -> Interp.ev(node, env)
      end

    if super_node != nil and parent != :null and not function?(parent),
      do:
        throw_error(
          "TypeError",
          "Class extends value #{Browser.JS.Builtins.inspect_js(parent, 0, [])} is not a constructor or null"
        )

    parent_proto =
      cond do
        parent == nil -> proto(:object)
        parent == :null -> :null
        true -> Interp.get(parent, "prototype")
      end

    proto = new_object([], parent_proto)
    parent = if parent == :null, do: nil, else: parent
    derived? = super_node != nil

    ctor_node =
      case Enum.find(members, &match?({:cmember, :method, {:str, "constructor"}, _, false}, &1)) do
        {:cmember, _, _, {:fn, _, params, body, mode}, _} -> {:fn, name, params, body, mode}
        nil -> default_constructor(name, derived?)
      end

    f = Interp.make_function(ctor_node, cenv)
    if name, do: Interp.declare(cenv, name, f, true)
    Interp.set_home(f, proto)
    put_hidden(f, "prototype", proto)
    put_hidden(proto, "constructor", f)

    {:obj, fid} = f
    fobj = deref(fid)
    store(fid, if(parent, do: %{fobj | proto: parent}, else: fobj))

    # members, in order; static fields and blocks run once everything is defined
    {fields, statics} =
      Enum.reduce(members, {[], []}, fn
        {:cmember, :method, {:str, "constructor"}, _, false}, acc ->
          acc

        {:cmember, :block, _, body, true}, {fields, statics} ->
          {fields, [{:block, body} | statics]}

        {:cmember, :field, key, init, static?}, {fields, statics} ->
          k = member_key(key, cenv)

          if static?,
            do: {fields, [{:field, k, init} | statics]},
            else: {[{k, init} | fields], statics}

        {:cmember, kind, key, value, static?}, acc ->
          target = if static?, do: f, else: proto
          k = member_key(key, cenv)
          fun = Interp.ev(value, cenv)
          Interp.set_home(fun, target)

          case kind do
            :method -> put_hidden(target, k, fun)
            :get -> Props.define_accessor(target, k, get: fun, enumerable: false)
            :set -> Props.define_accessor(target, k, set: fun, enumerable: false)
          end

          acc
      end)

    info = %{
      parent: parent,
      derived?: derived?,
      fields: Enum.reverse(fields),
      env: cenv,
      name: name
    }

    obj = deref(fid)
    store(fid, Map.put(obj, :class_info, info))

    run_statics(Enum.reverse(statics), f, cenv)
    f
  end

  defp default_constructor(name, false), do: {:fn, name, [], [], false}

  defp default_constructor(name, true) do
    {:fn, name, [{:rest, {:id, "args"}}],
     [{:expr, {:call, {:super}, [{:spread, {:id, "args"}}], false}}], false}
  end

  defp member_key({:str, s}, _), do: s
  defp member_key({:computed, e}, env), do: to_key(Interp.ev(e, env))

  defp run_statics(statics, f, cenv) do
    scope = Interp.new_scope(cenv)
    Interp.declare(scope, :this, f)
    Interp.declare(scope, :home, f)

    Enum.each(statics, fn
      {:field, key, init} ->
        v = if init, do: Interp.ev(init, scope), else: :undefined
        Interp.put(f, key, v)

      {:block, body} ->
        inner = Interp.new_scope(scope)
        Interp.exec_stmt({:block, body}, inner)
    end)
  end

  # ── construction ───────────────────────────────────────────

  @doc "`new C(...)` for a class (`nt` is `new.target`)."
  def construct({:obj, id} = f, info, args, nt) do
    {:closure, c} = deref(id).fun
    extra = [{:ctor_fn, f}, {:new_target, nt}]

    if info.derived? do
      {ret, scope} = Interp.run_closure_scope(c, :uninit_this, args, extra)

      case ret do
        {:obj, _} ->
          ret

        _ ->
          case Interp.lookup_scoped(scope, :this) do
            {:ok, :uninit_this} ->
              throw_error(
                "ReferenceError",
                "Must call super constructor in derived class before accessing 'this' or returning from derived constructor"
              )

            {:ok, this} ->
              this
          end
      end
    else
      proto =
        case Interp.get(nt, "prototype") do
          {:obj, _} = p -> p
          _ -> proto(:object)
        end

      this = new_object([], proto)
      init_fields(info, this)
      {ret, _} = Interp.run_closure_scope(c, this, args, extra)
      if match?({:obj, _}, ret), do: ret, else: this
    end
  end

  # an instance gets the class's public fields, in order, as its own properties
  defp init_fields(%{fields: []}, _this), do: :ok

  defp init_fields(info, this) do
    scope = Interp.new_scope(info.env)
    Interp.declare(scope, :this, this)

    for {key, init} <- info.fields do
      v = if init, do: Interp.ev(init, scope), else: :undefined
      Interp.put(this, key, v)
    end

    :ok
  end

  @doc "`super(...)` in a constructor."
  def super_call(args, env) do
    with {:ok, f} <- Interp.lookup_scoped(env, :ctor_fn),
         {:ok, nt} <- Interp.lookup_scoped(env, :new_target) do
      {:obj, fid} = f
      info = deref(fid).class_info
      sc = Interp.scope_of(env, :ctor_fn)

      case Interp.lookup_scoped(sc, :this) do
        {:ok, :uninit_this} -> :ok
        _ -> throw_error("ReferenceError", "Super constructor may only be called once")
      end

      unless info.parent,
        do: throw_error("SyntaxError", "'super' keyword unexpected here")

      result = Interp.construct(info.parent, args, nt)
      Interp.declare(sc, :this, result)
      init_fields(info, result)
      result
    else
      _ -> throw_error("SyntaxError", "'super' keyword unexpected here")
    end
  end

  @doc "The object `super.x` reads from, and the current `this`."
  def super_base(env) do
    with {:ok, {:obj, hid}} <- Interp.lookup_scoped(env, :home),
         {:ok, this} <- Interp.lookup_scoped(env, :this) do
      parent = deref(hid).proto
      {parent || :null, this}
    else
      _ -> throw_error("SyntaxError", "'super' keyword unexpected here")
    end
  end
end
