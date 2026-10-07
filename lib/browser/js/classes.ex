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

  # a proxy would run its traps while being printed
  defp inspect_heritage(v) do
    if Browser.JS.Proxy.proxy?(v), do: "[proxy]", else: Browser.JS.Builtins.inspect_js(v, 0, [])
  end

  @doc "Evaluates a class definition: the constructor function."
  def define(class, env, inferred \\ nil)

  def define({:class, name, super_node, members}, env, inferred) do
    cenv = Interp.new_scope(env)

    parent =
      case super_node do
        nil -> nil
        node -> Interp.ev(node, env)
      end

    if super_node != nil and parent != :null and not Interp.constructor?(parent),
      do:
        throw_error(
          "TypeError",
          "Class extends value #{inspect_heritage(parent)} is not a constructor or null"
        )

    parent_proto =
      cond do
        parent == nil -> proto(:object)
        parent == :null -> :null
        true -> Interp.get(parent, "prototype")
      end

    unless match?({:obj, _}, parent_proto) or parent_proto == :null,
      do:
        throw_error(
          "TypeError",
          "Class extends value does not have valid prototype property"
        )

    proto = new_object([], parent_proto)
    parent = if parent == :null, do: nil, else: parent
    derived? = super_node != nil

    ctor_node =
      case Enum.find(members, &match?({:cmember, :method, {:str, "constructor"}, _, false}, &1)) do
        {:cmember, _, _, {:fn, _, params, body, mode}, _} -> {:fn, name, params, body, mode}
        nil -> default_constructor(name, derived?)
      end

    # each private name of the class gets a key of its own, visible to the class body
    for n <- Enum.uniq(for {:cmember, _, {:priv, n}, _, _} <- members, do: n) do
      Interp.declare(cenv, {:priv, n}, make_ref())
    end

    ctor_node =
      if name == nil and inferred != nil,
        do: put_elem(ctor_node, 1, inferred),
        else: ctor_node

    f = Interp.make_function(ctor_node, cenv)
    if name, do: Interp.declare(cenv, name, f, true)
    Interp.set_home(f, proto)
    put_hidden(f, "prototype", proto)
    put_hidden(proto, "constructor", f)

    {:obj, fid} = f
    fobj = deref(fid)
    fobj = Map.put(fobj, :class_ctor, true)

    fobj =
      Map.update(
        fobj,
        :attrs,
        %{"prototype" => %{w: false, c: false}},
        &Map.put(&1, "prototype", %{w: false, c: false})
      )

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

          if static? and k == "prototype",
            do: throw_error("TypeError", "Classes may not have a static field named 'prototype'")

          fname = field_fn_name(key, k)

          if static?,
            do: {fields, [{:field, k, init, fname} | statics]},
            else: {[{k, init, fname} | fields], statics}

        {:cmember, kind, {:priv, _} = key, value, static?}, {fields, statics} = acc ->
          k = member_key(key, cenv)
          fun = Interp.ev(value, cenv)
          Interp.set_home(fun, if(static?, do: f, else: proto))
          {:priv, pname} = key
          Interp.name_method(fun, "#" <> pname, kind)

          if static? do
            put_private(f, k, kind, fun)
            acc
          else
            {fields, statics} = {fields, statics}
            {[{:private_method, k, kind, fun} | fields], statics}
          end

        {:cmember, kind, key, value, static?}, acc ->
          target = if static?, do: f, else: proto
          k = member_key(key, cenv)

          if static? and k == "prototype",
            do: throw_error("TypeError", "Classes may not have a static member named 'prototype'")

          fun = Interp.ev(value, cenv)
          Interp.set_home(fun, target)
          Interp.name_method(fun, k, kind)

          case kind do
            :method -> put_hidden(target, k, fun)
            :get -> Props.define_accessor(target, k, get: fun, enumerable: false)
            :set -> Props.define_accessor(target, k, set: fun, enumerable: false)
          end

          acc
      end)

    # private methods and accessors are installed before any field is initialised
    {methods, fields} = Enum.split_with(fields, &match?({:private_method, _, _, _}, &1))

    info = %{
      parent: parent,
      derived?: derived?,
      fields: Enum.reverse(methods) ++ Enum.reverse(fields),
      env: cenv,
      name: name,
      proto: proto
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

  # the name an anonymous function takes from the field it initializes
  defp field_fn_name({:priv, n}, _), do: "#" <> n
  defp field_fn_name(_, k) when is_binary(k), do: k
  defp field_fn_name(_, {:symbol, _, d}) when is_binary(d), do: "[" <> d <> "]"
  defp field_fn_name(_, _), do: ""

  defp member_key({:str, s}, _), do: s
  defp member_key({:priv, n}, env), do: Interp.private_key(n, env)
  defp member_key({:computed, e}, env), do: to_key(Interp.ev(e, env))

  defp run_statics(statics, f, cenv) do
    scope =
      Interp.new_fn_scope(cenv, %{this: f, home: f, new_target: :undefined, field_init: true})

    Enum.each(statics, fn
      {:field, key, init, fname} ->
        v = if init, do: Interp.ev_named(init, scope, {:id, fname}), else: :undefined
        define_field(f, key, v)

      {:block, body} ->
        inner = Interp.new_fn_scope(scope, %{})
        Interp.run_body(body, inner)
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

        r when r != :undefined ->
          throw_error("TypeError", "Derived constructors may only return object or undefined")

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
    scope =
      Interp.new_fn_scope(info.env, %{
        this: this,
        home: info.proto,
        new_target: :undefined,
        field_init: true
      })

    for field <- info.fields do
      case field do
        {:private_method, key, kind, fun} ->
          put_private(this, key, kind, fun)

        {key, init, fname} ->
          v = if init, do: Interp.ev_named(init, scope, {:id, fname}), else: :undefined
          define_field(this, key, v)
      end
    end

    :ok
  end

  # a private field is an own property that is not listed; a public one is defined (a setter on
  # the prototype chain does not run, and a frozen object throws)
  defp define_field(obj, {:private, _} = key, v), do: put_private(obj, key, :field, v)

  defp define_field(obj, key, v) do
    Browser.JS.Props.define(
      obj,
      key,
      Interp.new_object([
        {"value", v},
        {"writable", true},
        {"enumerable", true},
        {"configurable", true}
      ])
    )
  end

  # stores a private method, accessor half or field value on an object
  defp put_private({:obj, id}, key, kind, value) do
    o = deref(id)
    existing = Map.get(o.props, key)

    duplicate? =
      case {kind, existing} do
        {_, nil} -> false
        {:get, {:accessor, g, _}} -> g != :undefined
        {:set, {:accessor, _, s}} -> s != :undefined
        _ -> true
      end

    if duplicate?,
      do: throw_error("TypeError", "Cannot initialize a private member twice on the same object")

    stored =
      case {kind, existing} do
        {:get, {:accessor, _, s}} -> {:accessor, value, s}
        {:get, _} -> {:accessor, value, :undefined}
        {:set, {:accessor, g, _}} -> {:accessor, g, value}
        {:set, _} -> {:accessor, :undefined, value}
        _ -> value
      end

    o = if kind == :method, do: Map.update(o, :pmethods, [key], &[key | &1]), else: o
    store(id, %{o | props: Map.put(o.props, key, stored)})
  end

  @doc "`super(...)` in a constructor."
  def super_call(args, env) do
    with {:ok, f} <- Interp.lookup_scoped(env, :ctor_fn),
         {:ok, nt} <- Interp.lookup_scoped(env, :new_target) do
      {:obj, fid} = f
      info = deref(fid).class_info
      sc = Interp.scope_of(env, :ctor_fn)

      unless info.parent,
        do:
          throw_error(
            "TypeError",
            "Super constructor null of anonymous class is not a constructor"
          )

      # the parent is the constructor's current prototype
      parent = Browser.JS.Props.get_prototype_of(f)

      unless Interp.constructor?(parent),
        do: throw_error("TypeError", "Super constructor is not a constructor")

      result = Interp.construct(parent, args, nt)

      case Interp.lookup_scoped(sc, :this) do
        {:ok, :uninit_this} -> :ok
        _ -> throw_error("ReferenceError", "Super constructor may only be called once")
      end

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
      if this == :uninit_this,
        do:
          throw_error(
            "ReferenceError",
            "Must call super constructor in derived class before accessing 'this'"
          )

      parent = deref(hid).proto
      {parent || :null, this}
    else
      _ -> throw_error("SyntaxError", "'super' keyword unexpected here")
    end
  end
end
