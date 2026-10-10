defmodule Browser.JS.Classes do
  @moduledoc """
  `class` for the JavaScript runtime: construction, `extends`, `super`, static members,
  accessors and public fields.

  A class is a function object with a `class_info` field: its parent class (or nil), whether it
  is derived, its instance fields and the scope they are evaluated in. A derived constructor starts
  with `this` unset (`:uninit_this`); `super(...)` constructs the parent with the same
  `new.target` and sets it. Methods remember the object they were defined on (`home`), which is
  where `super.method` starts looking, one prototype up.

  From resolve level 3 (step 2d) a rewritten constructor runs on a frame (`construct/4`): the
  hidden slots `:this`, `:new_target`, `:home` and `:ctor_fn` take the place of the names of
  the old call scope, and `super(...)` finds them by name through the frames. A class without
  a `constructor` member gets a default constructor in slot form when the resolver put its
  `Info` on the class node. The class scope, the field scope and the static scope stay map
  scopes, and private names stay names in the class scope.
  """

  import Browser.JS.Interp, except: [get: 2, put: 3]
  alias Browser.JS.{Interp, Props}

  # Check mode (`JS_RESOLVE_CHECK=1`), as in `Browser.JS.Interp`: the flag is read at
  # compile time, so without it no check costs anything.
  @check Application.compile_env(:browser, :js_resolve_check, false)

  # a proxy would run its traps while being printed
  defp inspect_heritage(v) do
    if Browser.JS.Proxy.proxy?(v), do: "[proxy]", else: Browser.JS.Builtins.inspect_js(v, 0, [])
  end

  @doc "Evaluates a class definition: the constructor function."
  def define(class, env, inferred \\ nil)

  def define({:class, name, super_node, members, src}, env, inferred) do
    # From resolve level 3 a class without a `constructor` member carries the `Info` of its
    # default constructor in place of the source text (resolver rule R4).
    {class_src, dinfo} = Browser.JS.Resolve.unpack(src)

    # decorators ride along as a last element of the member list; their expressions are
    # evaluated first, in order, class decorators before those of the members
    {members, class_decs, member_decs} =
      case List.last(members) do
        {:decorations, cd, md} -> {Enum.drop(members, -1), cd, md}
        _ -> {members, [], %{}}
      end

    class_decs = eval_decorators(class_decs, env)
    metadata = Interp.new_object([], :null)
    cenv = Interp.new_scope(env)

    # the heritage is evaluated inside the class scope, where the class's own name is still
    # uninitialized
    if name, do: Interp.declare(cenv, name, :tdz)

    parent =
      case super_node do
        nil -> nil
        node -> Interp.ev(node, cenv)
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
        {:cmember, _, _, {:fn, _, params, body, mode, src}, _} ->
          # the constructor's source is the whole class; its resolver facts stay
          {:fn, name, params, body, mode, Browser.JS.Resolve.with_src(src, class_src)}

        nil ->
          default_constructor(name, derived?, class_src, dinfo)
      end

    # each private name of the class gets a key of its own, visible to the class body
    for n <- Enum.uniq(for {:cmember, _, {:priv, n}, _, _} <- members, do: n) do
      Interp.declare(cenv, {:priv, n}, make_ref())
    end

    ctor_node =
      if name == nil and inferred != nil,
        do: put_elem(ctor_node, 1, inferred),
        else: ctor_node

    f = Interp.make_function(ctor_node, cenv, false)
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
      members
      |> Enum.with_index()
      |> Enum.reduce({[], []}, fn
        {{:cmember, :method, {:str, "constructor"}, _, false}, _}, acc ->
          acc

        {{:cmember, :block, _, body, true}, _}, {fields, statics} ->
          {fields, [{:block, body} | statics]}

        {{:cmember, :field, key, init, static?}, idx}, {fields, statics} ->
          k = member_key(key, cenv)
          decs = eval_decorators(Map.get(member_decs, idx, []), cenv)

          if static? and k == "prototype",
            do: throw_error("TypeError", "Classes may not have a static field named 'prototype'")

          fname = field_fn_name(key, k)

          {wrappers, inits} =
            decorate_field(decs, "field", member_name(key, k), static?, key, k, metadata)

          init = if wrappers == [], do: init, else: {:decorated_init, init, wrappers}
          late = for i <- inits, do: {:init_fn, i, :late}

          if static?,
            do: {fields, Enum.reverse(late) ++ [{:field, k, init, fname} | statics]},
            else: {Enum.reverse(late) ++ [{k, init, fname} | fields], statics}

        {{:cmember, :accessor, key, init, static?}, idx}, {fields, statics} ->
          k = member_key(key, cenv)
          decs = eval_decorators(Map.get(member_decs, idx, []), cenv)

          if static? and k == "prototype",
            do: throw_error("TypeError", "Classes may not have a static member named 'prototype'")

          define_auto_accessor(
            {key, k, init, static?, decs},
            {f, proto, metadata},
            {fields, statics}
          )

        {{:cmember, kind, {:priv, _} = key, value, static?}, idx}, {fields, statics} = acc ->
          k = member_key(key, cenv)
          decs = eval_decorators(Map.get(member_decs, idx, []), cenv)
          fun = Interp.ev(value, cenv)
          Interp.set_home(fun, if(static?, do: f, else: proto))
          {:priv, pname} = key
          Interp.name_method(fun, "#" <> pname, kind)

          {fun, inits} =
            decorate_method(decs, kind, fun, "#" <> pname, static?, key, k, metadata)

          early = for i <- inits, do: {:init_fn, i, :early}

          if static? do
            put_private(f, k, kind, fun)
            {fields, Enum.reverse(early) ++ statics}
          else
            _ = acc
            {Enum.reverse(early) ++ [{:private_method, k, kind, fun} | fields], statics}
          end

        {{:cmember, kind, key, value, static?}, idx}, {fields, statics} ->
          target = if static?, do: f, else: proto
          k = member_key(key, cenv)
          decs = eval_decorators(Map.get(member_decs, idx, []), cenv)

          if static? and k == "prototype",
            do: throw_error("TypeError", "Classes may not have a static member named 'prototype'")

          fun = Interp.ev(value, cenv)
          Interp.set_home(fun, target)
          Interp.name_method(fun, k, kind)

          {fun, inits} =
            decorate_method(decs, kind, fun, member_name(key, k), static?, key, k, metadata)

          early = for i <- inits, do: {:init_fn, i, :early}

          case kind do
            :method -> put_hidden(target, k, fun)
            :get -> Props.define_accessor(target, k, get: fun, enumerable: false)
            :set -> Props.define_accessor(target, k, set: fun, enumerable: false)
          end

          if static?,
            do: {fields, Enum.reverse(early) ++ statics},
            else: {Enum.reverse(early) ++ fields, statics}
      end)

    # private methods and accessors are installed before any field is initialised; the
    # initializers methods asked for come next
    {methods, fields} = Enum.split_with(fields, &match?({:private_method, _, _, _}, &1))
    {early, fields} = Enum.split_with(fields, &match?({:init_fn, _, :early}, &1))
    methods = methods ++ early

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

    {early_statics, statics} =
      statics |> Enum.reverse() |> Enum.split_with(&match?({:init_fn, _, :early}, &1))

    run_statics(early_statics ++ statics, f, cenv)

    # the class decorators run last; what they return takes the class's place
    {f, class_inits} = decorate_class(class_decs, f, name, metadata)
    if name && f != nil, do: Interp.declare(cenv, name, f, true)
    for i <- class_inits, do: Interp.call(i, f, [])
    f
  end

  # The default constructor: `constructor() {}` for a base class and
  # `constructor(...args) { super(...args) }` for a derived class. With the `Info` of rule
  # R4 the node is in slot form, so it runs on a frame: the rest parameter `args` is slot 6.
  defp default_constructor(name, false, src, nil), do: {:fn, name, [], [], false, src}

  defp default_constructor(name, true, src, nil) do
    {:fn, name, [{:rest, {:id, "args"}}],
     [{:expr, {:call, {:super}, [{:spread, {:id, "args"}}], false}}], false, src}
  end

  defp default_constructor(name, derived?, _src, %Browser.JS.Resolve.Info{} = dinfo) do
    if @check and dinfo.kind != if(derived?, do: :derived_ctor, else: :ctor),
      do: raise(ArgumentError, "resolve check: a default constructor of kind #{dinfo.kind}")

    if derived? do
      args = {:slot, 0, 6, "args"}

      {:fn, name, [{:rest, args}], [{:expr, {:call, {:super}, [{:spread, args}], false}}], false,
       dinfo}
    else
      {:fn, name, [], [], false, dinfo}
    end
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
      {:init_fn, fun, _} ->
        Interp.call(fun, f, [])

      {:field, key, init, fname} ->
        define_field(f, key, field_value(init, scope, fname, f))

      {:block, body} ->
        inner = Interp.new_fn_scope(scope, %{})
        Interp.run_body(body, inner)
    end)
  end

  # the initial value of a field; decorators may have wrapped the initializer
  defp field_value({:decorated_init, init, wrappers}, scope, fname, this) do
    v = field_value(init, scope, fname, this)
    Enum.reduce(wrappers, v, fn w, v -> Interp.call(w, this, [v]) end)
  end

  defp field_value(nil, _scope, _fname, _this), do: :undefined
  defp field_value(init, scope, fname, _this), do: Interp.ev_named(init, scope, {:id, fname})

  # ── decorators ─────────────────────────────────────────────

  defp eval_decorators(decs, env) do
    for d <- decs do
      v = Interp.ev(d, env)

      unless Interp.function?(v),
        do: throw_error("TypeError", "Decorator must be a function")

      v
    end
  end

  defp member_name({:priv, n}, _), do: "#" <> n
  defp member_name(_, k), do: k

  # the context object a decorator is called with, and the key its `addInitializer` fills
  defp decorator_context(kind, name, static?, private?, access, metadata) do
    ref = make_ref()
    Process.put({:deco_inits, ref}, {:open, []})

    add_initializer =
      native("addInitializer", fn _, args ->
        fun = List.first(args, :undefined)

        case Process.get({:deco_inits, ref}) do
          {:open, list} ->
            unless Interp.function?(fun),
              do: throw_error("TypeError", "addInitializer needs a function")

            Process.put({:deco_inits, ref}, {:open, list ++ [fun]})
            :undefined

          _ ->
            throw_error("TypeError", "addInitializer cannot be called after decoration finished")
        end
      end)

    base = [
      {"kind", kind},
      {"name", name},
      {"metadata", metadata}
    ]

    base =
      if kind == "class",
        do: base ++ [{"addInitializer", add_initializer}],
        else:
          base ++
            [
              {"static", static?},
              {"private", private?},
              {"access", access},
              {"addInitializer", add_initializer}
            ]

    {Interp.new_object(base), ref}
  end

  defp finish_context(ref) do
    {:open, list} = Process.get({:deco_inits, ref})
    Process.put({:deco_inits, ref}, {:closed, list})
    list
  end

  defp key_access(k, parts) do
    has =
      native("has", fn _, args ->
        case List.first(args, :undefined) do
          {:obj, id} = o ->
            case k do
              {:private, _} -> Map.has_key?(deref(id).props, k)
              _ -> Interp.has_property?(o, k)
            end

          _ ->
            throw_error("TypeError", "access.has needs an object")
        end
      end)

    get = native("get", fn _, args -> Interp.get(access_obj(args), k) end)

    set =
      native("set", fn _, args ->
        Interp.put(access_obj(args), k, Enum.at(args, 1, :undefined))
        :undefined
      end)

    pairs =
      for {name, fun} <- [{"has", has}, {"get", get}, {"set", set}],
          name in parts,
          do: {name, fun}

    Interp.new_object(pairs)
  end

  defp access_obj(args) do
    case List.first(args, :undefined) do
      {:obj, _} = o -> o
      _ -> throw_error("TypeError", "access needs an object")
    end
  end

  defp call_decorator(dec, value, ctx) do
    Interp.call(dec, :undefined, [value, ctx])
  end

  # methods, getters and setters: a decorator may return a replacement function
  defp decorate_method([], _kind, fun, _name, _static?, _key, _k, _metadata), do: {fun, []}

  defp decorate_method(decs, kind, fun, name, static?, key, k, metadata) do
    kind_name = Atom.to_string(if kind == :method, do: :method, else: kind) <> ""

    kind_name =
      if kind == :get, do: "getter", else: if(kind == :set, do: "setter", else: kind_name)

    parts = if kind == :set, do: ["has", "set"], else: ["has", "get"]

    decs
    |> Enum.reverse()
    |> Enum.reduce({fun, []}, fn dec, {value, inits} ->
      {ctx, ref} =
        decorator_context(
          kind_name,
          name,
          static?,
          match?({:priv, _}, key),
          key_access(k, parts),
          metadata
        )

      result = call_decorator(dec, value, ctx)
      new_inits = finish_context(ref)

      value =
        cond do
          result == :undefined ->
            value

          Interp.function?(result) ->
            result

          true ->
            throw_error("TypeError", "A method decorator must return a function or undefined")
        end

      {value, inits ++ new_inits}
    end)
  end

  # fields: a decorator may return a function that maps the initial value
  defp decorate_field([], _kind, _name, _static?, _key, _k, _metadata), do: {[], []}

  defp decorate_field(decs, kind, name, static?, key, k, metadata) do
    decs
    |> Enum.reverse()
    |> Enum.reduce({[], []}, fn dec, {wrappers, inits} ->
      {ctx, ref} =
        decorator_context(
          kind,
          name,
          static?,
          match?({:priv, _}, key),
          key_access(k, ["has", "get", "set"]),
          metadata
        )

      result = call_decorator(dec, :undefined, ctx)
      new_inits = finish_context(ref)

      wrappers =
        cond do
          result == :undefined ->
            wrappers

          Interp.function?(result) ->
            wrappers ++ [result]

          true ->
            throw_error("TypeError", "A field decorator must return a function or undefined")
        end

      {wrappers, inits ++ new_inits}
    end)
  end

  # `accessor x = 1`: a getter and a setter over a private slot
  defp define_auto_accessor(
         {key, k, init, static?, decs},
         {f, proto, metadata},
         {fields, statics}
       ) do
    storage = {:private, make_ref()}
    target = if static?, do: f, else: proto
    name = member_name(key, k)
    private? = match?({:priv, _}, key)

    getter =
      native("get " <> to_string_name(name), fn this, _ ->
        accessor_slot!(this, storage)
        Interp.get(this, storage)
      end)

    setter =
      native("set " <> to_string_name(name), fn this, args ->
        accessor_slot!(this, storage)
        Interp.put(this, storage, Enum.at(args, 0, :undefined))
        :undefined
      end)

    Interp.set_home(getter, target)
    Interp.set_home(setter, target)

    {getter, setter, wrappers, inits} =
      decs
      |> Enum.reverse()
      |> Enum.reduce({getter, setter, [], []}, fn dec, {g, s, wrappers, inits} ->
        {ctx, ref} =
          decorator_context(
            "accessor",
            name,
            static?,
            private?,
            key_access(k, ["has", "get", "set"]),
            metadata
          )

        value = Interp.new_object([{"get", g}, {"set", s}])
        result = call_decorator(dec, value, ctx)
        new_inits = finish_context(ref)

        case result do
          :undefined ->
            {g, s, wrappers, inits ++ new_inits}

          {:obj, _} = r ->
            g2 = accessor_part(Interp.get(r, "get"), g)
            s2 = accessor_part(Interp.get(r, "set"), s)

            w =
              case Interp.get(r, "init") do
                :undefined ->
                  wrappers

                i ->
                  if Interp.function?(i),
                    do: wrappers ++ [i],
                    else: throw_error("TypeError", "accessor init must be a function")
              end

            {g2, s2, w, inits ++ new_inits}

          _ ->
            throw_error("TypeError", "An accessor decorator must return an object or undefined")
        end
      end)

    init = if wrappers == [], do: init, else: {:decorated_init, init, wrappers}
    late = for i <- inits, do: {:init_fn, i, :late}
    fname = field_fn_name(key, k)

    cond do
      private? and static? ->
        put_private(f, k, :get, getter)
        put_private(f, k, :set, setter)
        {fields, Enum.reverse(late) ++ [{:field, storage, init, fname} | statics]}

      private? ->
        {Enum.reverse(late) ++
           [
             {storage, init, fname},
             {:private_method, k, :set, setter},
             {:private_method, k, :get, getter} | fields
           ], statics}

      true ->
        Props.define_accessor(target, k, get: getter, set: setter, enumerable: false)

        if static?,
          do: {fields, Enum.reverse(late) ++ [{:field, storage, init, fname} | statics]},
          else: {Enum.reverse(late) ++ [{storage, init, fname} | fields], statics}
    end
  end

  defp accessor_part(:undefined, current), do: current

  defp accessor_part(fun, _current) do
    if Interp.function?(fun),
      do: fun,
      else: throw_error("TypeError", "accessor get and set must be functions")
  end

  defp accessor_slot!({:obj, id}, storage) do
    unless Map.has_key?(deref(id).props, storage),
      do: throw_error("TypeError", "Cannot access an auto-accessor on an object that lacks it")
  end

  defp accessor_slot!(_, _),
    do: throw_error("TypeError", "Cannot access an auto-accessor on a non-object")

  defp to_string_name(n) when is_binary(n), do: n
  defp to_string_name({:symbol, _, d}) when is_binary(d), do: "[" <> d <> "]"
  defp to_string_name(_), do: ""

  # class decorators, last first; each may return a replacement class
  defp decorate_class([], f, _name, _metadata), do: {f, []}

  defp decorate_class(decs, f, name, metadata) do
    decs
    |> Enum.reverse()
    |> Enum.reduce({f, []}, fn dec, {value, inits} ->
      {ctx, ref} =
        decorator_context("class", name || :undefined, false, false, :undefined, metadata)

      result = call_decorator(dec, value, ctx)
      new_inits = finish_context(ref)

      value =
        cond do
          result == :undefined ->
            value

          Interp.constructor?(result) ->
            result

          true ->
            throw_error("TypeError", "A class decorator must return a constructor or undefined")
        end

      {value, inits ++ new_inits}
    end)
  end

  # ── construction ───────────────────────────────────────────

  @doc "`new C(...)` for a class (`nt` is `new.target`)."
  def construct({:obj, id} = f, info, args, nt) do
    case deref(id).fun do
      {:closure, %{info: %Browser.JS.Resolve.Info{rewritten: true}} = c} ->
        construct_frame(id, c, info, args, nt)

      {:closure, c} ->
        construct_scope(f, id, c, info, args, nt)
    end
  end

  # A rewritten constructor (step 2d) runs on a frame. The hidden slots replace the extra
  # names of the old path: `:ctor_fn` is the class itself and `:new_target` is `nt`. The
  # frame hoists for itself, so `with_hoist` is not called. A derived constructor gives
  # back its `this` slot as it was at the end of the body, before the frame is freed.
  defp construct_frame(id, c, info, args, nt) do
    if info.derived? do
      {ret, this} = Interp.run_class_frame(id, c, :uninit_this, args, nt, :ctor)
      derived_result(ret, this)
    else
      this = new_object([], instance_proto(nt))
      init_fields(info, this)
      ret = Interp.run_class_frame(id, c, this, args, nt, :new)
      if match?({:obj, _}, ret), do: ret, else: this
    end
  end

  defp construct_scope(f, id, c, info, args, nt) do
    c = Interp.with_hoist(id, c)
    extra = [{:ctor_fn, f}, {:new_target, nt}]

    if info.derived? do
      {ret, scope} = Interp.run_closure_scope(c, :uninit_this, args, extra)

      this =
        case ret do
          {:obj, _} -> nil
          _ -> elem(Interp.lookup_scoped(scope, :this), 1)
        end

      derived_result(ret, this)
    else
      this = new_object([], instance_proto(nt))
      init_fields(info, this)
      {ret, _} = Interp.run_closure_scope(c, this, args, extra)
      if match?({:obj, _}, ret), do: ret, else: this
    end
  end

  defp instance_proto(nt) do
    case Interp.get(nt, "prototype") do
      {:obj, _} = p -> p
      _ -> proto(:object)
    end
  end

  # The result of a derived constructor, in the order of the checks of the spec: an object
  # result wins, any other value except `undefined` is a TypeError, and a `this` that
  # `super()` never set is a ReferenceError.
  defp derived_result(ret, this) do
    case ret do
      {:obj, _} ->
        ret

      r when r != :undefined ->
        throw_error("TypeError", "Derived constructors may only return object or undefined")

      _ ->
        case this do
          :uninit_this ->
            throw_error(
              "ReferenceError",
              "Must call super constructor in derived class before accessing 'this' or returning from derived constructor"
            )

          this ->
            this
        end
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

        {:init_fn, fun, _} ->
          Interp.call(fun, this, [])

        {key, init, fname} ->
          define_field(this, key, field_value(init, scope, fname, this))
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

    if existing == nil and not Browser.JS.Props.extensible?({:obj, id}),
      do: throw_error("TypeError", "Cannot add a private member to a non-extensible object")

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

  # `super(...)` and `super_base/1` find their bindings by name. From resolve level 3 (step
  # 2d) these bindings can be hidden slots of a constructor or method frame: the by-name
  # walk reads `info.slots` of each frame on the way, also through an arrow frame or a
  # block frame, and `declare/3` writes the `this` slot of the frame.
  @doc "`super(...)` in a constructor."
  def super_call(args, env) do
    with {:ok, f} <- Interp.lookup_scoped(env, :ctor_fn),
         {:ok, nt} <- Interp.lookup_scoped(env, :new_target) do
      {:obj, fid} = f
      info = deref(fid).class_info
      sc = Interp.scope_of(env, :ctor_fn)
      if @check, do: check_super_scope(sc)

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

  # The scope `super()` writes `this` into is a constructor frame or an old-path call scope
  # with `:ctor_fn`.
  defp check_super_scope(sc) do
    ok? =
      case deref(sc) do
        f when is_tuple(f) ->
          match?(%Browser.JS.Resolve.Info{kind: k} when k in [:ctor, :derived_ctor], elem(f, 1))

        %{vars: vars} ->
          is_map_key(vars, :ctor_fn)

        _ ->
          false
      end

    unless ok?, do: raise(ArgumentError, "resolve check: super() lands on #{inspect(sc)}")
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
