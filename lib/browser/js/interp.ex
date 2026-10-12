defmodule Browser.JS.Interp do
  @moduledoc """
  A tree-walking evaluator for the syntax tree from `Browser.JS.Parser`.

  Everything runs inside one process, which owns the "heap" (objects and scopes, kept in the
  process dictionary under integer ids). Use `Browser.JS.eval/2` rather than calling this
  directly; it sets that process up, installs the built-ins and tears it down.

  ## Values

  | JavaScript   | Elixir                                              |
  |--------------|-----------------------------------------------------|
  | number       | float, or `:nan` / `:infinity` / `:neg_infinity`    |
  | string       | binary (UTF-8; indices and lengths count code points, not UTF-16 units) |
  | boolean      | `true` / `false`                                    |
  | `undefined`  | `:undefined`                                        |
  | `null`       | `:null`                                             |
  | object, array, function | `{:obj, id}` into the heap               |

  ## Control flow

  Each statement gives a completion:

  | Completion               | Meaning                                                  |
  |--------------------------|----------------------------------------------------------|
  | `:ok`                    | the statement completed normally                         |
  | `{:ret, v}`              | `return v`                                               |
  | `{:brk, label}`          | `break`; `label` is `nil` or a string                    |
  | `{:cont, label}`         | `continue`; `label` is `nil` or a string                 |
  | `{:tail, f, this, args}` | `return f(...)` at a tail site, before the call is made  |

  A statement list stops at the first completion that is not `:ok` and gives it to the
  statement around it. A loop takes the `break` and the `continue` that are for it. The
  function boundary takes the return and the pending call. A strict function that is not a
  constructor gives the pending call to `tail_loop/3`, so the stack does not grow. Other
  functions make the call at the boundary. A statement that must see the call before it
  completes makes the call immediately (see `run_tail/2`): a `try` block, a handler that a
  `finally` follows, the body of a for-in or for-of loop, the rest of a `using` list and a
  `with` body.

  A JS exception is an Elixir throw, `{:js_error, value}`. When a script uses all its
  steps, `:js_limit` is thrown. JavaScript code cannot catch it.

  Only script and eval code have a completion value. It is in `:js_last`, which the
  statements of that code write. The statements of a rewritten function run through
  `fbody/2` and `fstmt/3` and do not write it. The old path writes it as before step 3.
  """

  alias Browser.JS.Num
  alias Browser.JS.Resolve.{Info, Scope}
  require Browser.JS.Fast, as: Fast
  require Browser.JS.Obj, as: Obj

  # `Process.get/1` as a macro: the same result (nil when unset) without a call into Process
  defmacrop pget(key) do
    quote do
      case :erlang.get(unquote(key)) do
        :undefined -> nil
        v -> v
      end
    end
  end

  @max_depth 1000

  @doc false
  # The call depth of a chain in `:js_stack` (step 2f). The depth of the current call is in
  # the head cell. Any other value is the bottom of the chain. This includes `:undefined` in
  # a process that did not call `init/1`.
  defmacro depth_of(chain) do
    quote do
      case unquote(chain) do
        [{_, _, d} | _] -> d
        _ -> 0
      end
    end
  end

  # The position of the first slot in a frame tuple, after the five header elements. The
  # parameters come first, so argument `k` of a function with plain parameters is in slot
  # `@frame_base + k` (`Browser.JS.Resolve.Info`).
  @frame_base 6

  # Check mode (`JS_RESOLVE_CHECK=1`, see `config/config.exs`): every slot access asserts
  # that the hop lands on a scope that owns the name at that index, and every frame is
  # checked at its build. The flag is read at compile time, so without it no check costs
  # anything.
  @check Application.compile_env(:browser, :js_resolve_check, false)

  # a statement's scope element from the resolver: `nil` (nothing to declare) or a frameless
  # `%Scope{}` whose names live in slots of the frame. A framed scope (step 2c) matches the
  # `framed` guard instead: the statement makes a block frame of its own.
  defguardp frameless(sc) when sc == nil or (is_map(sc) and :erlang.map_get(:frame, sc) == false)
  defguardp framed(sc) when is_map(sc) and :erlang.map_get(:frame, sc) == true

  # an anonymous function or class node, or a generator or async wrapper around one: the
  # node shapes that take the name of the binding they are assigned to
  defguardp nameable(e)
            when (elem(e, 0) in [:fn, :class] and elem(e, 1) == nil) or
                   elem(e, 0) in [:gen, :async]

  # ── heap ───────────────────────────────────────────────────

  @doc "Starts a fresh heap in this process. `max_steps` bounds how much work a script may do."
  def init(max_steps) do
    # the heap's objects are entries of the process dictionary under their integer ids: a write
    # replaces one entry in place instead of copying the path to it through a big map
    :erlang.put(:js_heap_n, 0)
    :erlang.put(:js_next, 0)
    :erlang.put(:js_steps, max_steps)
    # The call chain of step 2f: one cell for each active call, with its depth. See
    # `run_frame/6`.
    :erlang.put(:js_stack, [])
    :erlang.put(:js_last, :undefined)
    # The switch of closure compilation (step 5, `Browser.JS.Compile`). Each heap reads the
    # application setting once, so that the differential oracle can run both modes in one
    # VM and a call does not read the application environment. With the switch off, the
    # code that an earlier heap of this process compiled must go: `make_fn` would give it
    # to the new function objects.
    compile? = Application.get_env(:browser, :js_compile, true)
    :erlang.put(:js_compile, compile?)

    if compile? != true do
      # (the cells of the inline caches go with the cache, see `Browser.JS.Shape`)
      Browser.JS.Compile.erase_entries()
      # (the count of the cache goes with the cache, see `Browser.JS.Compile`)
      :erlang.erase(:jsc_budget)
    end

    # A fresh heap gives out the ids from 0 again, so the marks of `frame_done/2` from an
    # earlier heap in this process must go: check mode would read them as the marks of the
    # new frames with the same ids.
    if @check do
      for {{:js_cps_done, _} = key, _} <- :erlang.get(), do: :erlang.erase(key)
      # (the oracle of the call stack, see `check_oracle/3`)
      :erlang.put(:js_check_stack, [])
      :erlang.put(:js_check_depth, 0)
    end

    # (the closure count starts here and only goes up, see `make_fn/3`)
    :erlang.put(:js_fns, 0)
  end

  def alloc(obj) do
    id = :erlang.get(:js_next)
    :erlang.put(:js_next, id + 1)
    :erlang.put(:js_heap_n, :erlang.get(:js_heap_n) + 1)
    :erlang.put(id, obj)
    id
  end

  # an id for an entry that `store/2` fills in later (a scope whose closures need its id first)
  defp reserve do
    id = :erlang.get(:js_next)
    :erlang.put(:js_next, id + 1)
    :erlang.put(:js_heap_n, :erlang.get(:js_heap_n) + 1)
    id
  end

  def deref(id) do
    case :erlang.get(id) do
      :undefined -> raise KeyError, key: id, term: :js_heap
      obj -> obj
    end
  end

  def store(id, obj) do
    :erlang.put(id, obj)
    true
  end

  @doc "How many objects the heap holds."
  def heap_size, do: :erlang.get(:js_heap_n)

  @doc false
  # drops a heap entry (a scope that nothing can reach any more)
  if @check do
    # In check mode a freed frame leaves a tombstone, so that a later use of its id fails
    # with the name of the frame and the dangling scan can find a value that still holds it.
    def free(id) do
      case :erlang.get(id) do
        :undefined ->
          :ok

        {:js_freed, name} ->
          check_fail("a second free of the frame of #{name}")

        f
        when is_tuple(f) and tuple_size(f) >= 5 and
               (is_struct(:erlang.element(2, f), Info) or is_struct(:erlang.element(2, f), Scope)) ->
          :erlang.put(id, {:js_freed, check_name(:erlang.element(2, f))})
          :erlang.put(:js_heap_n, :erlang.get(:js_heap_n) - 1)
          :ok

        _ ->
          :erlang.erase(id)
          :erlang.put(:js_heap_n, :erlang.get(:js_heap_n) - 1)
          :ok
      end
    end
  else
    def free(id) do
      if :erlang.erase(id) != :undefined,
        do: :erlang.put(:js_heap_n, :erlang.get(:js_heap_n) - 1)

      :ok
    end
  end

  @doc "The built-in prototype object registered under `name` (`:object`, `:array`, ...)."
  def proto(name), do: Process.get({:proto, name})
  def put_proto(name, val), do: :erlang.put({:proto, name}, val)

  def global, do: pget(:js_global)

  @doc """
  A plain object with the given `{key, value}` pairs. It is a fast record when the switch
  `:js_shapes` is on (`Browser.JS.Obj.plain_record/1`).
  """
  def new_object, do: {:obj, alloc(Obj.plain_record(class: :object, proto: proto(:object)))}

  def new_object(pairs, proto \\ nil) do
    {:obj,
     alloc(
       Obj.plain_record(
         [class: :object, proto: if(proto == :null, do: nil, else: proto || proto(:object))],
         pairs
       )
     )}
  end

  @doc """
  A plain object with no own property that is to be a prototype (`F.prototype`, the
  prototype of a class). It is a dictionary record also when the switch `:js_shapes` is on:
  in step A1 only the objects that are not prototypes are fast (`Browser.JS.Obj`).
  """
  def new_proto_object(proto \\ nil),
    do:
      {:obj,
       alloc(
         Obj.record(
           class: :object,
           proto: if(proto == :null, do: nil, else: proto || proto(:object))
         )
       )}

  def new_array(list) do
    {:obj,
     alloc(
       Obj.record(class: :array, items: items_map(list), len: length(list), proto: proto(:array))
     )}
  end

  defp items_map(list), do: list |> Enum.with_index() |> Map.new(fn {v, i} -> {i, v} end)

  @doc """
  An object backed by Elixir: reads and writes of its properties go to `mod.host_get/3` and
  `mod.host_put/4` first (`{:ok, value}` / `:ok`, or `:miss` to fall back to ordinary
  properties and the prototype chain, where its methods live).
  """
  def new_host(mod, data, proto) do
    {:obj, alloc(Obj.record(class: :host, host: {mod, data}, proto: proto))}
  end

  def native(name, fun) do
    {:obj,
     alloc(Obj.record(class: :function, fun: {:native, name, fun}, proto: proto(:function)))}
  end

  @doc "`get [Symbol.species]` on a built-in constructor: returns `this`."
  def def_species(ctor) do
    put_hidden(
      ctor,
      {:symbol, :species, "Symbol.species"},
      {:accessor, native("get [Symbol.species]", fn this, _ -> this end), :undefined}
    )
  end

  def make_error(type, message) do
    {:obj, id} = err = new_object([{"message", message}], proto({:error, type}))

    store(
      id,
      deref(id)
      |> Map.put(:errdata, true)
      |> Map.put(:stack_str, stack_string("#{type}: #{message}"))
    )

    err
  end

  @doc "Records the stack string `Error.prototype.stack` reports for an error object."
  def set_stack({:obj, id}, str), do: store(id, Map.put(deref(id), :stack_str, str))

  @doc "Sets the [[ErrorData]] marker `Error.isError` looks for."
  def mark_error({:obj, id} = e) do
    store(id, Map.put(deref(id), :errdata, true))
    e
  end

  @doc """
  `Error.stack`: the header and the functions being run, innermost first, each with the file
  and line it was at (`at name (file:line)`) when the script has a file name.
  """
  def stack_string(header) do
    text = header <> walk(:erlang.get(:js_stack), pget(:js_pos), 0)

    if @check do
      old = check_stack_string(header)
      if text != old, do: check_fail("the stack text #{inspect(text)} is not #{inspect(old)}")
    end

    text
  end

  # One line for each visible cell of the chain, innermost first. The innermost function is
  # at `:js_pos`. Every other function is at the call position of the cell above it. A
  # hidden cell (the sync part of an async call) prints nothing and keeps the position,
  # because an async call had no cell before step 2f. After 12 lines the walk stops and the
  # line of the script is left out, as the text had at most 12 lines before step 2f.
  defp walk([{:hidden, _, _} | below], loc, n), do: walk(below, loc, n)
  defp walk(_, _loc, 12), do: ""

  defp walk([{name, pos, _} | below], loc, n),
    do: frame_line(name, loc) <> walk(below, pos, n + 1)

  # (the bottom of the chain: the line of the script's own code, when it has a position)
  defp walk(_, nil, _), do: ""
  defp walk(_, top, _), do: frame_line(nil, top)

  defp frame_line(name, loc) do
    name =
      case name do
        {:method, n} -> n
        n -> n
      end

    named? = is_binary(name) and name != ""

    case loc do
      {file, line} when named? -> "\n    at #{name} (#{file}:#{line})"
      {file, line} -> "\n    at #{file}:#{line}"
      _ -> "\n    at " <> if(named?, do: name, else: "<anonymous>")
    end
  end

  @doc "`Name: message` of an error object, with the function names it was thrown under."
  def describe_error({:obj, id} = v) do
    case get(v, "message") do
      m when is_binary(m) ->
        head =
          case get(v, "name") do
            n when is_binary(n) -> n <> ": " <> m
            _ -> m
          end

        case deref(id) do
          %{stack_str: s} ->
            case String.split(s, "\n", parts: 2) do
              [_, frames] -> head <> "\n" <> frames
              _ -> head
            end

          _ ->
            head
        end

      _ ->
        nil
    end
  end

  def throw_error(type, message), do: throw({:js_error, make_error(type, message)})

  @doc false
  def new_scope(parent) do
    alloc(%{scope: true, vars: %{}, consts: MapSet.new(), parent: parent})
  end

  @doc false
  # a scope that `var`s declared by eval code land in (a function body's)
  def new_fn_scope(parent, vars \\ %{}) do
    alloc(%{scope: true, fnscope: true, vars: vars, consts: MapSet.new(), parent: parent})
  end

  @doc "A global scope that starts with the variables `vars` (a frame's), not made the current one."
  def new_scope_with(vars),
    do: alloc(%{scope: true, vars: vars, consts: MapSet.new(), parent: nil})

  def new_global_scope do
    id = new_scope(nil)
    :erlang.put(:js_global, id)
    id
  end

  def declare(scope, name, val, const? \\ false) do
    case deref(scope) do
      f when is_tuple(f) ->
        # A frame has a fixed layout: it can take a value for a name it has a slot for, and
        # nothing else. From level 3, `super()` writes the `this` slot of a constructor
        # frame through this clause (step 2d).
        case :erlang.element(2, f).slots do
          %{^name => i} -> slot_put(scope, i, val)
          _ -> raise ArgumentError, "a frame cannot take the new name #{inspect(name)}"
        end

      s ->
        store(scope, %{
          s
          | vars: Map.put(s.vars, name, val),
            consts: if(const?, do: MapSet.put(s.consts, name), else: s.consts)
        })
    end
  end

  # ── frames ─────────────────────────────────────────────────

  # A frame is a tuple `{parent_id, info, chain, call_pos, root_id, slot_6, ...}` in the
  # heap (see `Browser.JS.Resolve.Info`). The hop count of a slot form counts run-time
  # scopes: a frame hops to its parent through its header, a map scope through `.parent`.
  # It is public because the closure compiler (`Browser.JS.Compile`) calls it.
  @doc false
  if @check do
    # (in check mode a hop that lands on a freed frame fails at once)
    def hop(id, 0) do
      check_live(id)
      id
    end
  else
    def hop(id, 0), do: id
  end

  def hop(id, d), do: hop(parent_of(:erlang.get(id)), d - 1)

  if @check do
    defp parent_of({:js_freed, name}), do: check_fail("use of a freed frame of #{name}")
  end

  defp parent_of(f) when is_tuple(f), do: :erlang.element(1, f)
  defp parent_of(%{parent: p}), do: p

  # It is public because the closure compiler (`Browser.JS.Compile`) calls it.
  @doc false
  def slot_put(env, i, v),
    do: :erlang.put(env, :erlang.setelement(i, :erlang.get(env), v))

  # ── check mode ─────────────────────────────────────────────

  # A slot form must land, after its hops, on a frame that owns `name` at index `i`: a
  # function name through `info.slots`, a block name through a block kind in `kinds` (a
  # block name can shadow a function name, so a name in `slots` may still be a block slot).
  # It is public because the closure compiler (`Browser.JS.Compile`) calls it.
  @doc false
  def check_landing({:this, d, i}, env), do: check_slot(hop(env, d), i, :this)

  def check_landing({:mref, d, name}, env) do
    case :erlang.get(hop(env, d)) do
      %{vars: vars} when is_map_key(vars, name) -> :ok
      other -> check_fail("{:mref, #{d}, #{inspect(name)}} lands on #{inspect(other, limit: 3)}")
    end
  end

  def check_landing({:gref, name}, env) do
    case scope_of(env, name) do
      nil ->
        :ok

      sc ->
        if sc == root(env) or body_only_slot?(sc, name),
          do: :ok,
          else: check_fail("{:gref, #{inspect(name)}} is shadowed")
    end
  end

  def check_landing({_k, d, i, name}, env), do: check_slot(hop(env, d), i, name)

  # A write to a mapped parameter lands on the parameter's slot, in a function whose
  # `argmap` maps the name to the same argument index: the sync writes that element.
  def check_landing({:mslot, d, i, name, k}, env) do
    id = hop(env, d)
    check_slot(id, i, name)

    case :erlang.get(id) do
      f when is_tuple(f) ->
        unless match?(%Info{argmap: %{^name => ^k}}, :erlang.element(2, f)),
          do: check_fail("{:mslot} #{inspect(name)} #{k} lands on a frame without that mapping")

      _ ->
        :ok
    end
  end

  # The arguments object form lands on the hidden slot of the object (rule R3 of step 2d):
  # only that slot holds `{:unbuilt, id}` before the first read.
  def check_landing({:aslot, d, i}, env) do
    case :erlang.get(hop(env, d)) do
      f when is_tuple(f) and i <= tuple_size(f) ->
        rec = :erlang.element(2, f)

        unless match?(%Info{}, rec) and
                 (Map.get(rec.slots, :arguments) == i or Map.get(rec.slots, "arguments") == i) and
                 kind_at(rec, i) == :hidden,
               do:
                 check_fail(
                   "{:aslot, #{d}, #{i}} lands on no arguments slot of #{check_name(rec)}"
                 )

      other ->
        check_fail("{:aslot, #{d}, #{i}} lands on #{inspect(other, limit: 3)}")
    end
  end

  # A closure in a parameter expression does not see the body names of its function, so a
  # `{:gref}` there can pass a function frame that has a body slot of the same name. The
  # check cannot tell where the form sits, so it accepts a body slot of a function whose
  # parameters have expressions.
  defp body_only_slot?(sc, name) do
    case :erlang.get(sc) do
      f when is_tuple(f) ->
        rec = :erlang.element(2, f)

        match?(%Info{params: p} when p != :plain, rec) and
          case rec.slots do
            %{^name => i} -> kind_at(rec, i) not in [:param, :self]
            _ -> false
          end

      _ ->
        false
    end
  end

  # It is public because the closure compiler (`Browser.JS.Compile`) calls it.
  @doc false
  def check_slot(id, i, name) do
    case :erlang.get(id) do
      f when is_tuple(f) and i <= tuple_size(f) ->
        rec = :erlang.element(2, f)

        cond do
          match?(%{^name => ^i}, rec.slots) -> :ok
          kind_at(rec, i) in [:let, :const, :using, :fun] -> :ok
          param_own_slot?(rec, i, name) -> :ok
          true -> check_fail("#{inspect(name)} is not slot #{i} of #{check_name(rec)}")
        end

      other ->
        check_fail("#{inspect(name)} at #{i} lands on #{inspect(other, limit: 3)}")
    end
  end

  # A parameter that a closure in a default value captured keeps its own slot when a body
  # `var` or function of the same name takes another one; `slots` names the body slot.
  defp param_own_slot?(%Info{params: :exprs, slots: slots} = rec, i, name) do
    case slots do
      %{^name => j} -> kind_at(rec, i) == :param and kind_at(rec, j) in [:var, :fun]
      _ -> false
    end
  end

  defp param_own_slot?(_rec, _i, _name), do: false

  # A frame as `run_frame/6` built it: the size of the layout, the levels 1 to 3, the
  # free rule of its level, and copies from a parameter slot (or from the hidden slot of
  # the arguments object) to a `var` slot. A leaf has nothing to hoist or copy. Levels 1
  # and 2 have only the hidden slots `:this` and `:self`. From level 3 (step 2d) the
  # hidden slots must fit the function and hold the values of a call entry (see
  # `check_hidden/4`), and `argmap` must describe plain parameters of sloppy code.
  defp check_frame(f, %Info{} = info, id, mode) do
    cond do
      tuple_size(f) != info.size ->
        check_fail("frame of #{check_name(info)} has size #{tuple_size(f)}, not #{info.size}")

      mode == :suspend ->
        check_suspend(f, info, id)

      info.level not in [1, 2, 3] ->
        check_fail("frame of #{check_name(info)} at level #{inspect(info.level)}")

      info.level == 1 and (info.hoist != [] or info.copies != []) ->
        check_fail("leaf frame of #{check_name(info)} has hoist or copies")

      info.free == :always != (info.level == 1) ->
        check_fail("frame of #{check_name(info)} at level #{info.level} frees #{info.free}")

      info.level < 3 and info.hidden -- [:this, :self] != [] ->
        check_fail("frame of #{check_name(info)} has hidden slots #{inspect(info.hidden)}")

      # A copy can land on a `:fun` slot when a `var` and a function declaration share the
      # name: the copy runs first and the hoist then overwrites it, as the spec orders.
      not Enum.all?(info.copies, fn {from, to} ->
        from <= info.size and to <= info.size and
          (kind_at(info, from) == :param or Map.get(info.slots, :arguments) == from) and
            kind_at(info, to) in [:var, :fun]
      end) ->
        check_fail("frame of #{check_name(info)} has copies #{inspect(info.copies)}")

      true ->
        check_argmap(info)
        Enum.each(info.hidden, &check_hidden(&1, f, info, {id, mode}))
    end
  end

  # A frame from `enter_frame/4` (step 2e): a level 4 async function or generator, which
  # frees by the closure counter, makes no tail calls and is never a constructor. Its hidden
  # slots hold the values of a plain call.
  defp check_suspend(f, info, id) do
    cond do
      info.level != 4 or not (info.async? or info.generator?) ->
        check_fail("a suspendable frame of #{check_name(info)} at level #{inspect(info.level)}")

      info.free != :counter ->
        check_fail("a suspendable frame of #{check_name(info)} frees #{info.free}")

      info.tail_sites != 0 or :ctor_fn in info.hidden ->
        check_fail("a suspendable frame of #{check_name(info)} has tail sites or :ctor_fn")

      :new_target in info.hidden and
          :erlang.element(hidden_index(info, :new_target), f) != :undefined ->
        check_fail("a suspendable frame of #{check_name(info)} has a new.target")

      true ->
        check_argmap(info)
        Enum.each(info.hidden, &check_hidden(&1, f, info, {id, :suspend}))
    end
  end

  # `argmap` exists only for sloppy code with plain parameters, and each name maps to the
  # slot of its argument index.
  defp check_argmap(%Info{argmap: nil}), do: :ok

  defp check_argmap(%Info{argmap: argmap} = info) do
    unless not info.strict and info.params == :plain and info.nparams > 0 and
             Enum.all?(argmap, fn {name, k} -> Map.get(info.slots, name) == @frame_base + k end),
           do: check_fail("frame of #{check_name(info)} has argmap #{inspect(argmap)}")
  end

  # One hidden slot of a new frame: the kinds of function that may have it, and the value
  # it must hold at entry.
  defp check_hidden(h, f, info, {id, mode}) do
    v = :erlang.element(hidden_index(info, h), f)
    ctor? = info.kind in [:ctor, :derived_ctor]

    ok? =
      case h do
        # (a derived constructor that runs from a computed key of its own class has no
        # class record yet, so `new` runs it as a plain function; `super()` then throws)
        :this when info.kind == :derived_ctor and mode != :ctor ->
          not Map.has_key?(deref(id), :class_info)

        :this ->
          v == :uninit_this == (info.kind == :derived_ctor and mode == :ctor)

        :args ->
          is_list(v)

        :arguments ->
          v == {:unbuilt, id} and Map.has_key?(info.slots, :args)

        :new_target ->
          v == :undefined or constructor?(v)

        :home ->
          (ctor? or info.kind in [:method, :get, :set]) and
            (v == :undefined or match?({:obj, _}, v))

        :ctor_fn ->
          ctor? and v == {:obj, id}

        :self ->
          v == {:obj, id}
      end

    unless ok?,
      do: check_fail("hidden slot #{inspect(h)} of #{check_name(info)} holds #{inspect(v)}")
  end

  # A by-name read of `this` or `new.target` must not pass a level 3 function frame that
  # is not an arrow: such a function owns both, and the resolver gives it the slot when
  # any code inside it reads the binding by name (step 2d). `:home` and `:ctor_fn` may
  # pass, as on the old path, whose call scopes have them only for methods and class
  # constructors. A level 4 frame (step 2e) gets the same check, because its hidden slots
  # follow the same rules. A level 1 or 2 frame is not checked: no code inside it reads the
  # bindings by name, and the unit tests of the walkers build such frames by hand under
  # map scopes that do not have them.
  defp check_hidden_presence(f, name) when name in [:this, :new_target] do
    case :erlang.element(2, f) do
      %Info{kind: k, level: l} = info when l in [3, 4] and k not in [:arrow, :arrow_expr] ->
        check_fail("a by-name #{inspect(name)} passes the frame of #{check_name(info)}")

      _ ->
        :ok
    end
  end

  defp check_hidden_presence(_f, _name), do: :ok

  # The slot of a hidden binding. The self slot is under the function's name (`info.self`
  # gives its index), and the arguments object is under the name `"arguments"` unless the
  # body takes that name (`Browser.JS.Resolve.Info`).
  defp hidden_index(info, :self), do: info.self

  defp hidden_index(info, :arguments),
    do: Map.get(info.slots, :arguments) || :erlang.map_get("arguments", info.slots)

  defp hidden_index(info, h), do: :erlang.map_get(h, info.slots)

  # The aliasing invariant of a mapped arguments object (step 2d): the object records this
  # frame, maps only parameter indexes, and each mapped element holds the value of its
  # parameter's slot.
  # A builtin can change the elements in bulk without a sync (the Array fast paths, as on
  # the old path), so the value test runs only for the index `k` that was just written.
  defp check_args_alias(frame, k \\ nil) do
    f = :erlang.get(frame)

    with %Info{slots: %{args: ai}} = info <- :erlang.element(2, f),
         {:mapped, aid} <- :erlang.element(ai, f) do
      o = deref(aid)

      cond do
        Map.get(o, :map_scope) != frame or not is_map_key(o, :mapped) ->
          check_fail("the arguments object of #{check_name(info)} does not map its frame")

        Enum.any?(o.mapped, fn {k, _} -> k >= info.nparams end) ->
          check_fail("the arguments object of #{check_name(info)} maps #{inspect(o.mapped)}")

        k != nil and is_map_key(o.mapped, k) and
            Map.get(o.items, k) !== :erlang.element(@frame_base + k, f) ->
          check_fail("an element of the arguments object of #{check_name(info)} is out of sync")

        true ->
          :ok
      end
    end

    :ok
  end

  # A write to the slot of a mapped parameter must go through `{:mslot}` or a by-name
  # write, which sync the arguments object. A plain slot write would skip the sync.
  # It is public because the closure compiler (`Browser.JS.Compile`) calls it.
  @doc false
  def check_unsynced(frame, i) do
    case :erlang.get(frame) do
      f when is_tuple(f) ->
        case :erlang.element(2, f) do
          %Info{argmap: %{}} = info ->
            if kind_at(info, i) == :param,
              do: check_fail("an unsynced write to parameter slot #{i} of #{check_name(info)}")

          _ ->
            :ok
        end

      _ ->
        :ok
    end
  end

  # A statement or a CPS step on the old path makes map scopes. Its `env` must not be a
  # frame, because a rewritten function runs only the forms that carry a resolver scope.
  @doc false
  def check_old_path(env, where) do
    if @check and env != nil and is_tuple(:erlang.get(env)),
      do: check_fail("#{where} on the old path runs in a frame")

    :ok
  end

  @doc false
  # A failed assertion of the CPS evaluator in frame mode (step 2e). `Browser.JS.Async`
  # calls it only from code that its own check flag guards.
  def check_cps(msg), do: check_fail(msg)

  # A block frame is made only inside a rewritten function: its `env` is a live frame, its
  # template fills its size, and the function around it frees by the closure counter.
  defp check_block_env(env, f, sc) do
    check_live(env)

    cond do
      not is_tuple(f) ->
        check_fail("a #{sc.kind} frame under #{inspect(env)}, which is no frame")

      not sc.frame or 5 + length(sc.template) != sc.size ->
        check_fail("a #{sc.kind} frame with size #{sc.size} and #{length(sc.template)} slots")

      match?(%Info{free: :always}, :erlang.element(2, f)) ->
        check_fail("a #{sc.kind} frame under a level 1 frame")

      true ->
        :ok
    end
  end

  # Fails when `id` is the tombstone of a freed frame.
  defp check_live(id) do
    case :erlang.get(id) do
      {:js_freed, name} -> check_fail("use of a freed frame of #{name}")
      _ -> :ok
    end
  end

  @doc false
  # The dangling scan of check mode, at the end of a script: no value that the process
  # can still reach (the roots of the collector and `extra`, the script's result) may hold
  # a freed frame. A wrong free shows here even when no code reads the frame again.
  def check_dangling(extra) do
    if @check do
      case Browser.JS.GC.dangling(extra) do
        [] -> :ok
        names -> check_fail("a live value holds the freed frame of #{Enum.join(names, ", ")}")
      end
    end

    :ok
  end

  @doc false
  # Check mode only (C1, C3, C4 of step 2f). The oracle keeps the call stack as it was before
  # step 2f, in keys of its own: `:js_check_stack` holds `{name, call_pos}` cells, and
  # `:js_check_depth` counts the calls. An async call (`async? = true`) counts but pushes no
  # cell. Each call entry runs its real code as `fun` inside the oracle. Before the call,
  # the real depth and the head of the real stack must equal those of the oracle (C3). Every
  # push is compared, so by induction the whole stacks are equal. After the call, the real
  # stack and position must be as they were (C4). The oracle has its own `try/after` and
  # does not share code with the real entries, so it cannot copy a mistake from them.
  def check_oracle(name, async?, fun) do
    ostack = Process.get(:js_check_stack, [])
    odepth = Process.get(:js_check_depth, 0)
    below = :erlang.get(:js_stack)
    pos = Process.get(:js_pos)
    check_entry(below, ostack, odepth)

    if odepth >= @max_depth do
      # The real entry must refuse the call before it pushes anything.
      try do
        fun.()
      catch
        {:js_error, _} = e ->
          check_restored(below, pos, async?)
          throw(e)
      else
        _ -> check_fail("a call at depth #{odepth} was not refused")
      end
    else
      :erlang.put(:js_check_depth, odepth + 1)
      if not async?, do: :erlang.put(:js_check_stack, [{name, pos} | ostack])

      try do
        fun.()
      after
        :erlang.put(:js_check_depth, odepth)
        :erlang.put(:js_check_stack, ostack)
        check_restored(below, pos, async?)
      end
    end
  end

  # C3: the depth and the innermost visible cell of the real stack equal the oracle's.
  defp check_entry(below, ostack, odepth) do
    depth = depth_of(below)

    if depth != odepth,
      do: check_fail("the call depth is #{inspect(depth)}, and the oracle has #{odepth}")

    head = check_head(below)

    if head != List.first(ostack),
      do: check_fail("the stack head is #{inspect(head)}, and the oracle has #{inspect(ostack)}")
  end

  # (the innermost cell of the real stack that prints a line, as `{name, call_pos}`)
  defp check_head([{:hidden, _, _} | below]), do: check_head(below)
  defp check_head([{name, pos, _} | _]), do: {name, pos}
  defp check_head(_), do: nil

  # C4: a call entry restored the stack, and also the position unless the call is async.
  # An async call does not restore `:js_pos` (row F15 of step 2f).
  defp check_restored(below, pos, async?) do
    now = :erlang.get(:js_stack)

    if now !== below,
      do: check_fail("a call left the stack #{inspect(now)}, not #{inspect(below)}")

    if not async? and Process.get(:js_pos) != pos,
      do:
        check_fail(
          "a call left the position #{inspect(Process.get(:js_pos))}, not #{inspect(pos)}"
        )
  end

  @doc false
  # Check mode only (C6 of step 2f): the state of the call stack, for `check_task_end/1`.
  # Without check mode it is `nil`.
  def check_mark, do: if(@check, do: {:erlang.get(:js_stack), Process.get(:js_check_depth, 0)})

  @doc false
  # Check mode only (C6 of step 2f): at the end of a task, every call has restored the
  # stack. The task ends with the state `mark` from `check_mark/0` at its start. A task that
  # does not run inside JS code ends with the default, an empty stack and depth 0.
  def check_task_end(mark \\ {[], 0}) do
    if @check do
      now = {Process.get(:js_stack, []), Process.get(:js_check_depth, 0)}

      if now !== mark,
        do: check_fail("a task ended with the stack #{inspect(now)}, not #{inspect(mark)}")
    end

    :ok
  end

  # Check mode only (C5 of step 2f): code that runs in a frame of a sync call runs while
  # that call is on top of the stack, so element 3 of the frame is the current chain. This
  # proves at each call and at each JS `catch` that every callee restored the chain, also
  # on the throw path. A CPS frame (`enter_frame/4`), a frame made by hand in a test and a
  # map scope hold no chain and are skipped.
  # It is public because the closure compiler (`Browser.JS.Compile`) calls it.
  @doc false
  def check_link(env) when is_integer(env) do
    case :erlang.get(env) do
      f when is_tuple(f) and tuple_size(f) >= 5 and is_list(:erlang.element(3, f)) ->
        now = :erlang.get(:js_stack)
        chain = :erlang.element(3, f)

        if chain !== now,
          do: check_fail("the frame #{env} has the chain #{inspect(chain)}, not #{inspect(now)}")

      _ ->
        :ok
    end
  end

  def check_link(_env), do: :ok

  # Check mode only (C2 of step 2f): the stack text from the oracle, made with the code from
  # before step 2f. `stack_string/1` must give the same text.
  defp check_stack_string(header) do
    stack = Process.get(:js_check_stack, [])

    {frames, top} =
      Enum.map_reduce(stack, Process.get(:js_pos), fn {name, call_pos}, loc ->
        {frame_line(name, loc), call_pos}
      end)

    frames = Enum.take(frames, 12)

    frames =
      if top != nil and length(stack) < 12, do: frames ++ [frame_line(nil, top)], else: frames

    header <> Enum.join(frames)
  end

  # A closure must not be made in a level 1 frame, also not through a map scope under it
  # (a class scope or a self-name scope): the leaf frame is freed on return whatever the
  # closure count says. This proves the level 1 rule of the resolver.
  defp check_closure_env(env) do
    check_live(env)

    case :erlang.get(env) do
      # (an old-path function scope: no leaf frame is between it and the closure)
      %{fnscope: true} ->
        :ok

      %{parent: p} ->
        check_closure_env(p)

      f when is_tuple(f) ->
        case :erlang.element(2, f) do
          %Info{free: :always} = info ->
            check_fail("a closure made in the leaf #{check_name(info)}")

          %Info{} ->
            :ok

          %Scope{} ->
            check_closure_env(:erlang.element(1, f))
        end

      _ ->
        :ok
    end
  end

  # After `enter_body/3` every hoisted slot holds a function, in a slot of a kind that a
  # function declaration can take.
  defp check_hoisted(frame, %Info{hoist: hoist} = info) do
    f = :erlang.get(frame)

    Enum.each(hoist, fn {i, _} ->
      unless match?({:obj, _}, :erlang.element(i, f)) and
               kind_at(info, i) in [:fun, :var, :param],
             do: check_fail("hoisted slot #{i} of #{check_name(info)} holds no function")
    end)
  end

  defp check_name(%Info{name: name}), do: inspect(name)
  defp check_name(rec), do: inspect(rec.kind)

  defp check_fail(msg), do: raise(ArgumentError, "resolve check: " <> msg)

  # A frameless scope keeps its `let` and `const` names in slots of the frame. At each entry
  # of the statement the slots go back to the temporal dead zone, so a loop body sees its
  # `let` uninitialized again on every iteration.
  defp reset_tdz(_env, nil), do: :ok
  defp reset_tdz(_env, %Browser.JS.Resolve.Scope{tdz: []}), do: :ok

  defp reset_tdz(env, %Browser.JS.Resolve.Scope{tdz: idx}) do
    f = Enum.reduce(idx, :erlang.get(env), fn i, acc -> :erlang.setelement(i, acc, :tdz) end)
    :erlang.put(env, f)
  end

  # A frameless scope that declares functions (a block or a switch, from level 2 on) makes
  # them at each entry, as `hoist_functions` does on the old path. Their slots are in the
  # home frame `env`, and the TDZ reset comes first, so the order of the old path stays.
  # It is public because the closure compiler (`Browser.JS.Compile`) calls it.
  @doc false
  def enter_frameless(env, nil), do: reset_tdz(env, nil)

  def enter_frameless(env, %Scope{hoist: h} = sc) do
    reset_tdz(env, sc)
    hoist_slots(env, h)
  end

  # Makes the block frame of a framed scope: `{env, scope, caller, call_pos, root, slots...}`.
  # The header copies the caller, the call position and the root from `env`, so that a
  # `{:gref}` reads the root of a block frame in one step, as it does for a function frame.
  # The functions the scope declares are made after the frame is stored, because each
  # closure needs the frame's id and `make_fn` reads the root from it.
  defp enter_scope(env, %Scope{template: t, hoist: h} = sc) do
    f = :erlang.get(env)
    if @check, do: check_block_env(env, f, sc)

    id =
      alloc(
        List.to_tuple([
          env,
          sc,
          :erlang.element(3, f),
          :erlang.element(4, f),
          :erlang.element(5, f) | t
        ])
      )

    hoist_slots(id, h)
    id
  end

  # Frees a block frame when no closure was made since `fns` was read: only a closure can
  # hold the id of a frame past the code that made it (see `free_scope/2`).
  defp leave_scope(id, fns) do
    if :erlang.get(:js_fns) == fns, do: free(id)
    :ok
  end

  # Writes the hoisted functions into their slots of frame `id`, with one read and one
  # write of the heap entry. The pairs fold in source order, so the last one for a slot wins.
  defp hoist_slots(_id, []), do: :ok

  defp hoist_slots(id, h) do
    t =
      Enum.reduce(h, :erlang.get(id), fn {i, node}, t ->
        :erlang.setelement(i, t, make_fn(node, id, false))
      end)

    :erlang.put(id, t)
  end

  # The body entry of a function frame, after the parameters are bound: first the copies
  # of the parameter values into the body's own `var` slots, then the function
  # declarations. This is the order of the spec, so a declaration overwrites a copy and
  # never the reverse. A function with neither, and without `var arguments`, pays one
  # clause match.
  #
  # `var arguments` (`args_var`) holds the arguments object from the body entry, as
  # `call_frame` does on the old path. With parameter initializers the object is built into
  # its hidden slot before the copies, because a copy fills the `var` from that slot. The
  # object is then unmapped, so the order against the hoist cannot be seen. Without
  # initializers it is built into the `var` slot after the hoist, so that a mapped element
  # shows a function that a declaration put into its parameter.
  defp enter_body(_frame, %Info{copies: [], hoist: [], args_var: false}, _id), do: :ok

  defp enter_body(frame, %Info{copies: copies, hoist: hoist} = info, id) do
    if info.args_var and info.params == :exprs, do: build_hidden_arguments(frame, info)

    t =
      Enum.reduce(copies, :erlang.get(frame), fn {from, to}, t ->
        :erlang.setelement(to, t, :erlang.element(from, t))
      end)

    t =
      Enum.reduce(hoist, t, fn {i, node}, t ->
        :erlang.setelement(i, t, make_fn(node, frame, false))
      end)

    :erlang.put(frame, t)

    if info.args_var and info.params != :exprs,
      do: build_arguments(frame, :erlang.map_get("arguments", info.slots), id)

    if @check, do: check_args_alias(frame)
    :ok
  end

  # Builds the object in the hidden slot of `var arguments` under parameter initializers,
  # unless a parameter default read `arguments` and built it already.
  defp build_hidden_arguments(frame, %Info{slots: %{arguments: i}}) do
    case :erlang.element(i, :erlang.get(frame)) do
      {:unbuilt, fid} -> build_arguments(frame, i, fid)
      _ -> :ok
    end
  end

  defp build_hidden_arguments(_frame, _info), do: :ok

  # A by-name lookup through a frame: the names of the function are in `info.slots`
  # (block names are not: only slot forms reach those). `:strict` is not a slot, the
  # `Info` answers it. Anything else goes on to the parent. `id` is the frame's own id: a
  # hit on an arguments object that is not built yet builds it into the frame (step 2d).
  # This serves eval code and the functions on the old path inside a frame: a dynamic
  # function, and an async function or a generator when the level is below 4.
  defp lookup_frame(id, f, name) do
    case :erlang.element(2, f) do
      %Info{slots: slots, strict: strict} ->
        case slots do
          %{^name => i} ->
            case :erlang.element(i, f) do
              {:unbuilt, fid} -> {:ok, build_arguments(id, i, fid)}
              v -> {:ok, v}
            end

          _ when name == :strict and strict ->
            {:ok, true}

          _ ->
            if @check, do: check_hidden_presence(f, name)
            lookup_var(:erlang.element(1, f), name)
        end

      # A block frame (step 2c) answers its own names. It has no strictness of its own,
      # so `:strict` goes on to the function frame around it.
      %Scope{slots: slots} ->
        case slots do
          %{^name => i} -> {:ok, :erlang.element(i, f)}
          _ -> lookup_var(:erlang.element(1, f), name)
        end
    end
  end

  # walks the scope chain
  defp lookup_var(nil, _), do: :error

  defp lookup_var(scope, name) do
    if @check, do: check_live(scope)
    s = deref(scope)
    if is_tuple(s), do: lookup_frame(scope, s, name), else: lookup_map(s, name)
  end

  defp lookup_map(s, name) do
    case s.vars do
      %{^name => {:alias, target, var}} ->
        lookup_var(target, var)

      %{^name => v} ->
        {:ok, v}

      _ ->
        case s do
          %{with: obj} when is_binary(name) ->
            if has_property?(obj, name) and not unscopable?(obj, name) do
              # GetBindingValue asks again whether the binding is still there
              if has_property?(obj, name) do
                {:ok, get(obj, name)}
              else
                Process.put(:js_with_gone, name)
                {:ok, :undefined}
              end
            else
              lookup_var(s.parent, name)
            end

          %{parent: nil, vars: %{this: {:obj, gid}}} when is_binary(name) ->
            # a property defined on the global object itself (an accessor, say) is a variable too
            Obj.own_case deref(gid), name do
              {:ok, {:accessor, g, _}} ->
                {:ok, if(function?(g), do: call(g, {:obj, gid}, []), else: :undefined)}

              {:ok, v} ->
                {:ok, v}

              :error ->
                :error
            end

          _ ->
            lookup_var(s.parent, name)
        end
    end
  end

  # `with` skips what the object's Symbol.unscopables lists
  defp unscopable?(obj, name) do
    case get(obj, {:symbol, :unscopables, "Symbol.unscopables"}) do
      {:obj, _} = u -> truthy(get(u, name))
      _ -> false
    end
  end

  @no_consts MapSet.new()

  defp assign_var(scope, name, val) do
    if @check, do: check_live(scope)

    case deref(scope) do
      f when is_tuple(f) -> assign_frame(scope, f, name, val)
      s -> assign_map(scope, s, name, val)
    end
  end

  # A write by name through a frame. The order of the checks is today's: a `const` in its
  # temporal dead zone is a ReferenceError, not a TypeError. The self name of a function
  # expression takes no write; `strict_assign_var` turns that into the TypeError of strict
  # code.
  defp assign_frame(scope, f, name, val) do
    info = :erlang.element(2, f)

    case info.slots do
      %{^name => i} ->
        cond do
          :erlang.element(i, f) == :tdz ->
            throw_error("ReferenceError", "Cannot access '#{name}' before initialization")

          kind_at(info, i) in [:const, :using] ->
            throw_error("TypeError", "Assignment to constant variable.")

          kind_at(info, i) == :self ->
            :fname_ignored

          true ->
            slot_put(scope, i, val)
            sync_by_name(scope, info, name, val)
        end

      _ ->
        case :erlang.element(1, f) do
          nil -> raise ArgumentError, "a frame has no parent to take #{inspect(name)}"
          parent -> assign_var(parent, name, val)
        end
    end
  end

  # A by-name write to a mapped parameter (from eval code or from an old-path function
  # inside a level 3 function) updates the arguments object as a `{:mslot}` write does.
  defp sync_by_name(frame, %Info{argmap: %{} = argmap}, name, val) do
    case argmap do
      %{^name => k} -> sync_mapped(frame, k, val)
      _ -> :ok
    end
  end

  defp sync_by_name(_frame, _rec, _name, _val), do: :ok

  # After a write of `val` to the slot of mapped parameter `k` of `frame`: when the frame
  # built a mapped arguments object (its `:args` slot holds `{:mapped, aid}`) and element
  # `k` is still mapped, the element takes the value too. The sync goes through the object
  # that the build recorded, not through the `arguments` binding, which code may assign.
  defp sync_mapped(frame, k, val) do
    f = :erlang.get(frame)

    case :erlang.element(:erlang.map_get(:args, :erlang.element(2, f).slots), f) do
      {:mapped, aid} ->
        case deref(aid) do
          %{mapped: %{^k => _}} = o -> store(aid, %{o | items: Map.put(o.items, k, val)})
          _ -> :ok
        end

        if @check, do: check_args_alias(frame, k)
        :ok

      _ ->
        :ok
    end
  end

  # The kind of slot `i`. A function keeps its kinds in a tuple with one element per frame
  # position; a block scope keeps them in a map, because its slots can be slots of the
  # home frame and do not start at 6.
  defp kind_at(%Info{kinds: k}, i), do: :erlang.element(i, k)
  defp kind_at(%Scope{kinds: k}, i), do: Map.fetch!(k, i)

  defp assign_map(scope, s, name, val) do
    cond do
      Map.has_key?(s.vars, name) ->
        # (most scopes have no constants: nothing to look up)
        consts? = s.consts != @no_consts

        if consts? and MapSet.member?(s.consts, name),
          do: throw_error("TypeError", "Assignment to constant variable.")

        cond do
          :erlang.map_get(name, s.vars) == :tdz ->
            throw_error("ReferenceError", "Cannot access '#{name}' before initialization")

          consts? and MapSet.member?(s.consts, {:fname, name}) ->
            :fname_ignored

          # the global `undefined`, `NaN` and `Infinity` can not be assigned
          s.parent == nil and name in ["undefined", "NaN", "Infinity"] ->
            :fname_ignored

          true ->
            :erlang.put(scope, %{s | vars: Map.put(s.vars, name, val)})
            sync_argument(s.vars, name, val)
        end

      is_binary(name) and is_map_key(s, :with) and has_property?(s.with, name) and
          not unscopable?(s.with, name) ->
        # SetMutableBinding asks again whether the binding is still there
        _ = has_property?(s.with, name)
        put(s.with, name, val)

      s.parent != nil ->
        assign_var(s.parent, name, val)

      s.parent == nil and is_binary(name) and global_own_property?(s, name) ->
        put(s.vars.this, name, val)

      # `onmessage = f` and `name = "x"` set the window's own property, when it has one
      s.parent == nil and is_binary(name) and window_property?(s, name) ->
        put(s.vars.this, name, val)

      true ->
        # an undeclared variable becomes a global
        store(scope, %{s | vars: Map.put(s.vars, name, val)})
    end
  end

  defp window_property?(%{vars: %{this: {:obj, _} = window}}, name),
    do: has_property?(window, name)

  defp window_property?(_, _), do: false

  defp global_own_property?(%{vars: %{this: {:obj, gid}}}, name),
    do: Obj.has_own?(deref(gid), name)

  defp global_own_property?(_, _), do: false

  # a sloppy function's parameter and the `arguments` element it is mapped to follow each other
  defp sync_argument(%{argmap: {aid, names}}, name, val) do
    with %{^name => idx} <- names,
         %{mapped: %{^idx => ^name}} = o <- deref(aid) do
      store(aid, %{o | items: Map.put(o.items, idx, val)})
    end

    :ok
  end

  defp sync_argument(_, _, _), do: :ok

  @doc false
  # A write to a mapped `arguments` element reaches its parameter. `map_scope` is a map
  # scope on the old path and a frame on the frame path (step 2d): `deref` tells them
  # apart. The frame keeps argument `idx` in slot `@frame_base + idx`. A scope that is gone
  # (a map scope freed after its call) has no reader left that could see the parameter. A
  # frame is never gone here: `free_frame/2` takes `map_scope` away before it frees the
  # frame, so in check mode a tombstone fails.
  def sync_param(%{mapped: mapped, map_scope: scope}, idx, val) do
    case mapped do
      %{^idx => name} ->
        case :erlang.get(scope) do
          :undefined ->
            :ok

          f when is_tuple(f) ->
            if @check, do: check_live(scope)
            slot_put(scope, @frame_base + idx, val)
            if @check, do: check_args_alias(scope, idx)

          _ ->
            assign_var(scope, name, val)
        end

      _ ->
        :ok
    end

    :ok
  end

  @doc false
  # an element that is deleted, made an accessor or made read-only leaves the mapping
  def unmap_argument(id, idx) do
    case deref(id) do
      %{mapped: mapped} = o -> store(id, %{o | mapped: Map.delete(mapped, idx)})
      _ -> :ok
    end
  end

  @doc false
  # A per-iteration copy of a loop scope. A block frame keeps its parent, its record and
  # its header, so the copy is the same tuple under a new id.
  def copy_scope(src, parent) do
    case deref(src) do
      t when is_tuple(t) ->
        if @check and not match?(%Scope{per_iter: true}, :erlang.element(2, t)),
          do: check_fail("a copy of a frame that is not a per-iteration loop frame")

        alloc(t)

      s ->
        alloc(%{s | parent: parent})
    end
  end

  # ── conversions ────────────────────────────────────────────

  def num?(x), do: is_number(x) or x in [:nan, :infinity, :neg_infinity]
  def nullish?(x), do: x == :undefined or x == :null

  def function?({:obj, id}), do: deref(id).class == :function
  def function?(_), do: false

  # `function?/1` without the two calls, for a call site on the hot path.
  # It is public because the closure compiler (`Browser.JS.Compile`) calls it.
  @doc false
  @compile {:inline, callable?: 1}
  def callable?({:obj, id}) do
    case :erlang.get(id) do
      %{class: :function} -> true
      # (a missing entry fails as `deref/1` fails)
      :undefined -> deref(id)
      _ -> false
    end
  end

  def callable?(_), do: false

  def truthy(v) when v in [false, :undefined, :null, :nan, "", {:bigint, 0}], do: false
  def truthy(v) when is_number(v), do: v != 0
  def truthy(_), do: true

  def typeof(:undefined), do: "undefined"
  def typeof(:null), do: "object"
  def typeof(v) when is_boolean(v), do: "boolean"
  def typeof(v) when is_binary(v), do: "string"
  def typeof({:obj, _} = v), do: if(function?(v), do: "function", else: "object")
  def typeof({:symbol, _, _}), do: "symbol"
  def typeof({:bigint, _}), do: "bigint"
  def typeof(v), do: if(num?(v), do: "number", else: "object")

  def to_num(v) when is_number(v), do: v
  def to_num(v) when v in [:nan, :infinity, :neg_infinity], do: v

  def to_num({:symbol, _, _}),
    do: throw_error("TypeError", "Cannot convert a Symbol value to a number")

  def to_num({:bigint, _}),
    do: throw_error("TypeError", "Cannot convert a BigInt value to a number")

  def to_num(:undefined), do: :nan
  def to_num(:null), do: 0.0
  def to_num(true), do: 1.0
  def to_num(false), do: 0.0
  def to_num(v) when is_binary(v), do: Num.parse(v)
  def to_num({:obj, _} = v), do: v |> to_primitive("number") |> to_num()

  # WhiteSpace and LineTerminator of the language: not Unicode's White_Space (U+180E, U+0085)
  @js_space [9, 10, 11, 12, 13, 32, 0xA0, 0x1680, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF] ++
              Enum.to_list(0x2000..0x200A)

  def js_trim_start(<<c::utf8, rest::binary>> = s),
    do: if(c in @js_space, do: js_trim_start(rest), else: s)

  def js_trim_start(s), do: s

  def js_trim_end(s) do
    s
    |> String.codepoints()
    |> Enum.reverse()
    |> Enum.drop_while(fn <<c::utf8>> -> c in @js_space end)
    |> Enum.reverse()
    |> Enum.join()
  end

  def js_trim(s), do: s |> js_trim_start() |> js_trim_end()

  @doc "ToNumeric: a number, or a `{:bigint, n}`."
  def numeric(v) do
    case to_primitive(v, "number") do
      {:bigint, _} = b -> b
      p -> to_num(p)
    end
  end

  def big?({:bigint, _}), do: true
  def big?(_), do: false

  @doc "ToIntegerOrInfinity, clamped to a large integer so callers can compare freely."
  def to_int(v) do
    case to_num(v) do
      :nan -> 0
      :infinity -> 18_014_398_509_481_984
      :neg_infinity -> -18_014_398_509_481_984
      n -> trunc(n)
    end
  end

  @doc "ArraySetLength's value check: ToUint32 and ToNumber must agree, or a RangeError."
  def array_length!(v) do
    u = uint32(to_num(v))

    case to_num(v) do
      n when is_number(n) and n == u -> u
      _ -> throw_error("RangeError", "Invalid array length")
    end
  end

  defp uint32(n) when is_number(n), do: n |> trunc() |> Bitwise.band(0xFFFFFFFF)
  defp uint32(_), do: 0

  def to_str(v) when is_binary(v), do: v

  def to_str({:symbol, _, _}),
    do: throw_error("TypeError", "Cannot convert a Symbol value to a string")

  def to_str({:bigint, n}), do: Integer.to_string(n)
  def to_str(:undefined), do: "undefined"
  def to_str(:null), do: "null"
  def to_str(true), do: "true"
  def to_str(false), do: "false"
  def to_str(v) when is_number(v) or v in [:nan, :infinity, :neg_infinity], do: Num.to_string(v)
  def to_str({:obj, _} = v), do: v |> to_primitive("string") |> to_str()

  def to_key(k) when is_binary(k), do: k
  def to_key({:symbol, _, _} = k), do: k
  def to_key({:private, _} = k), do: k

  def to_key({:obj, _} = o) do
    case to_primitive(o, "string") do
      {:symbol, _, _} = s -> s
      prim -> to_str(prim)
    end
  end

  def to_key(k), do: to_str(k)

  @doc false
  # ToPropertyKey for a key that is used two times, for a read and then a write (`a[i]++`,
  # `a[i] += x`). A number stays a number: its conversion has no side effect, and `get/2` and
  # `put/3` take it as an array index with no string, or convert it with `to_key/1`. Any
  # other key is converted once, so a `toString` runs once.
  # It is public because the closure compiler (`Browser.JS.Compile`) calls it.
  def prop_key(k) when is_number(k), do: k
  def prop_key(k), do: to_key(k)

  def to_primitive({:obj, _} = o, hint) do
    case get(o, {:symbol, :toPrimitive, "Symbol.toPrimitive"}) do
      m when m in [:undefined, :null] ->
        ordinary_to_primitive(o, hint)

      m ->
        unless function?(m),
          do: throw_error("TypeError", "Symbol.toPrimitive is not a function")

        case call(m, o, [hint]) do
          {:obj, _} -> throw_error("TypeError", "Cannot convert object to primitive value")
          prim -> prim
        end
    end
  end

  def to_primitive(v, _), do: v

  @doc false
  def ordinary_to_primitive(o, hint) do
    order = if hint == "string", do: ["toString", "valueOf"], else: ["valueOf", "toString"]

    Enum.find_value(order, fn name ->
      f = get(o, name)

      if function?(f) do
        case call(f, o, []) do
          {:obj, _} -> nil
          prim -> {:ok, prim}
        end
      end
    end)
    |> case do
      {:ok, prim} -> prim
      nil -> throw_error("TypeError", "Cannot convert object to primitive value")
    end
  end

  # ── equality and comparison ────────────────────────────────

  def strict_eq(a, b) do
    if num?(a) and num?(b), do: Num.equal?(a, b), else: a === b
  end

  def loose_eq(a, b) do
    cond do
      nullish?(a) and nullish?(b) -> true
      nullish?(a) or nullish?(b) -> false
      num?(a) and num?(b) -> Num.equal?(a, b)
      big?(a) or big?(b) -> Browser.JS.BigInt.loose_eq(a, b)
      is_binary(a) and is_binary(b) -> a == b
      is_boolean(a) -> loose_eq(to_num(a), b)
      is_boolean(b) -> loose_eq(a, to_num(b))
      num?(a) and is_binary(b) -> Num.equal?(a, to_num(b))
      is_binary(a) and num?(b) -> Num.equal?(to_num(a), b)
      match?({:obj, _}, a) and match?({:obj, _}, b) -> a == b
      match?({:symbol, _, _}, a) and match?({:symbol, _, _}, b) -> a == b
      match?({:obj, _}, a) -> loose_eq(to_primitive(a, "default"), b)
      match?({:obj, _}, b) -> loose_eq(a, to_primitive(b, "default"))
      true -> false
    end
  end

  # SameValueZero, for includes()
  def same_value_zero(a, b) do
    (a == :nan and b == :nan) or strict_eq(a, b)
  end

  defp compare(a, b) do
    a = to_primitive(a, "number")
    b = to_primitive(b, "number")

    cond do
      is_binary(a) and is_binary(b) ->
        cond do
          true -> Browser.JS.Str.compare(a, b)
        end

      big?(a) or big?(b) ->
        Browser.JS.BigInt.compare(a, b)

      true ->
        Num.compare(to_num(a), to_num(b))
    end
  end

  # ── properties ─────────────────────────────────────────────

  # array indices stop below 2^32 - 1; larger integers are ordinary property names
  # It is public because the closure compiler (`Browser.JS.Compile`) calls it when it
  # compiles, to find the constant keys that `get_named/2` and `put_named/3` can take.
  @doc false
  # (the float clause compares a float only with floats: a compare of a float with an
  # integer is slow on the BEAM)
  def index(k) when is_float(k) and k >= 0.0 and k < 4_294_967_295.0 do
    i = trunc(k)
    if i * 1.0 == k, do: i
  end

  def index(k) when is_integer(k) and k >= 0 and k < 4_294_967_295, do: k

  # A canonical index string has no sign, no space and no leading zero, so it starts with a
  # digit, and a digit other than `0` when it has more than one. Other strings (`push`,
  # `length`) need no parse.
  def index(<<c>>) when c >= ?0 and c <= ?9, do: c - ?0

  # (the first byte is 1 to 9, and `Integer.parse/1` takes only ASCII digits after it, so a
  # string that it reads to the end has no sign and no leading zero: it is canonical, and
  # no round trip through `Integer.to_string/1` is necessary)
  def index(<<c, _::binary>> = k) when c >= ?1 and c <= ?9 do
    case Integer.parse(k) do
      {i, ""} when i < 4_294_967_295 -> i
      _ -> nil
    end
  end

  def index(_), do: nil

  def get({:obj, id} = obj, {:private, _} = key) do
    case Obj.own_fetch(deref(id), key) do
      {:ok, {:accessor, g, _}} ->
        if function?(g),
          do: call(g, obj, []),
          else: throw_error("TypeError", "'#x' was defined without a getter")

      {:ok, v} ->
        v

      :error ->
        throw_error(
          "TypeError",
          "Cannot read private member from an object whose class did not declare it"
        )
    end
  end

  def get(_, {:private, _}),
    do: throw_error("TypeError", "Cannot read private member from a non-object")

  def get({:obj, id}, key), do: get_obj(id, deref(id), key, false)

  def get(s, key) when is_binary(s), do: get_str(s, key, false)

  def get(n, key) when is_number(n) or n in [:nan, :infinity, :neg_infinity],
    do: lookup(deref(elem(proto(:number), 1)), to_key(key), n)

  def get({:bigint, _} = n, key), do: lookup(deref(elem(proto(:bigint), 1)), to_key(key), n)
  def get({:symbol, _, _} = s, key), do: lookup(deref(elem(proto(:symbol), 1)), to_key(key), s)

  def get(b, key) when is_boolean(b),
    do: lookup(deref(elem(proto(:boolean), 1)), to_key(key), b)

  def get(v, key),
    do:
      throw_error(
        "TypeError",
        "Cannot read properties of #{to_str(v)} (reading '#{safe_key(key)}')"
      )

  @doc false
  # A property read with a constant key (step 5, `Browser.JS.Compile`). The compiler gives
  # only a string key that is not an array index, so the read skips `index/1` and
  # `to_key/1`. The class dispatch is the one of `get/2`, in `get_obj/4`, so the two reads
  # cannot drift apart. A primitive goes to `get/2`.
  def get_named({:obj, id}, key), do: get_obj(id, deref(id), key, true)
  def get_named(s, key) when is_binary(s), do: get_str(s, key, true)
  def get_named(v, key), do: get(v, key)

  # The read of `key` from the string `s`, for `get/2` and `get_named/2`: an index gives a
  # character, `length` gives the length, and every other key comes from the prototype of
  # strings. `named?` is as in `get_obj/4`. A string receiver is common in compiled code
  # (`s.charAt(i)`, `s.length`), and a named key skips the parse of `index/1`.
  @compile {:inline, get_str: 3}
  defp get_str(s, key, named?) do
    case if(named?, do: nil, else: index(key)) do
      i when is_integer(i) ->
        Browser.JS.Str.at(s, i) || :undefined

      nil ->
        if key == "length",
          do: Browser.JS.Str.length(s) * 1.0,
          else: lookup(deref(elem(proto(:string), 1)), if(named?, do: key, else: to_key(key)), s)
    end
  end

  # The read of `key` from the object `o` with the id `id`: the class dispatch of `get/2`
  # and `get_named/2`. `named?` is true when the key is a string that is not an array
  # index, so `index/1` and `to_key/1` have nothing to do. The function is inline, so each
  # caller has its own copy, in which the compiler removes the tests of the constant
  # `named?`, and a read does not cost one more call.
  @compile {:inline, get_obj: 4}
  defp get_obj(id, o, key, named?) do
    case o.class do
      :array ->
        case if(named?, do: nil, else: index(key)) do
          i when is_integer(i) ->
            case o.items do
              %{^i => {:accessor, g, _}} ->
                if function?(g), do: call(g, {:obj, id}, []), else: :undefined

              %{^i => v} ->
                v

              _ ->
                lookup(o, to_key(key), {:obj, id})
            end

          nil ->
            cond do
              # (the `length` of an arguments object is an ordinary own property)
              key == "length" and is_map_key(o, :arguments) ->
                lookup(o, "length", {:obj, id})

              key == "length" ->
                o.len * 1.0

              true ->
                lookup(o, if(named?, do: key, else: to_key(key)), {:obj, id})
            end
        end

      :function ->
        key = if(named?, do: key, else: to_key(key))

        if Map.has_key?(o, :proxy) do
          Browser.JS.Proxy.get({:obj, id}, key, {:obj, id})
        else
          function_get(id, o, key)
        end

      :host
      when is_number(key) and key >= 0 and key == trunc(key) and
             :erlang.element(1, :erlang.map_get(:host, o)) == Browser.JS.TypedArrays ->
        Browser.JS.TypedArrays.get_index(elem(o.host, 1), trunc(key))

      :host ->
        key = if(named?, do: key, else: to_key(key))
        {mod, data} = o.host

        # the typed array accessors are inherited: an own property of the same name wins
        if key in ["length", "byteLength", "byteOffset", "buffer"] and
             Obj.has_own?(o, key) and match?({Browser.JS.TypedArrays, _}, o.host) do
          lookup(o, key, {:obj, id})
        else
          case mod.host_get(data, key, {:obj, id}) do
            {:ok, v} -> v
            :miss -> lookup(o, key, {:obj, id})
          end
        end

      _ ->
        case o do
          # a String wrapper's characters
          %{prim: str} when is_binary(str) ->
            case if(named?, do: nil, else: index(key)) do
              i when is_integer(i) ->
                Browser.JS.Str.at(str, i) ||
                  lookup(o, to_key(key), {:obj, id})

              _ ->
                lookup(o, if(named?, do: key, else: to_key(key)), {:obj, id})
            end

          _ ->
            lookup(o, if(named?, do: key, else: to_key(key)), {:obj, id})
        end
    end
  end

  # a property found along the prototype chain; a getter is called with the object it was
  # asked of as `this`
  defp lookup(o, key, receiver) do
    Obj.own_case o, key do
      {:ok, {:accessor, getter, _}} ->
        if function?(getter), do: call(getter, receiver, []), else: :undefined

      {:ok, v} ->
        v

      :error ->
        case o do
          # an array further up the prototype chain: its length and elements show through
          %{class: :array} when key == "length" and not is_map_key(o, :arguments) ->
            o.len * 1.0

          # (an array with no elements, as `Array.prototype`, needs no parse of the key)
          %{class: :array, items: items} when is_binary(key) and map_size(items) > 0 ->
            case index(key) do
              i when is_integer(i) and is_map_key(items, i) ->
                case items[i] do
                  {:accessor, getter, _} ->
                    if function?(getter), do: call(getter, receiver, []), else: :undefined

                  v ->
                    v
                end

              _ ->
                lookup_proto(o, key, receiver)
            end

          _ ->
            lookup_proto(o, key, receiver)
        end
    end
  end

  defp lookup_proto(o, key, receiver) do
    case o.proto do
      {:obj, pid} ->
        case deref(pid) do
          %{proxy: _} ->
            Browser.JS.Proxy.get({:obj, pid}, key, receiver)

          %{class: :host, host: {mod, data}} = po ->
            case mod.host_get(data, key, receiver) do
              {:ok, v} -> v
              :miss -> lookup(po, key, receiver)
            end

          po ->
            lookup(po, key, receiver)
        end

      _ ->
        :undefined
    end
  end

  # spec lengths of the built-in functions, by name (a handful of names are shared
  # between objects with different arities; the common one wins)
  @native_lengths %{
    "Array" => 1.0,
    "ArrayBuffer" => 1.0,
    "DataView" => 1.0,
    "SharedArrayBuffer" => 1.0,
    "Boolean" => 1.0,
    "Date" => 7.0,
    "AggregateError" => 2.0,
    "SuppressedError" => 3.0,
    "Error" => 1.0,
    "EvalError" => 1.0,
    "Function" => 1.0,
    "Number" => 1.0,
    "Object" => 1.0,
    "Promise" => 1.0,
    "Proxy" => 2.0,
    "RangeError" => 1.0,
    "ReferenceError" => 1.0,
    "RegExp" => 2.0,
    "String" => 1.0,
    "SyntaxError" => 1.0,
    "TypeError" => 1.0,
    "URIError" => 1.0,
    "UTC" => 7.0,
    "abs" => 1.0,
    "acos" => 1.0,
    "acosh" => 1.0,
    "add" => 1.0,
    "all" => 1.0,
    "allSettled" => 1.0,
    "any" => 1.0,
    "apply" => 2.0,
    "asin" => 1.0,
    "asinh" => 1.0,
    "assign" => 2.0,
    "at" => 1.0,
    "atan" => 1.0,
    "atan2" => 2.0,
    "atanh" => 1.0,
    "bind" => 1.0,
    "catch" => 1.0,
    "cbrt" => 1.0,
    "ceil" => 1.0,
    "charAt" => 1.0,
    "charCodeAt" => 1.0,
    "clz32" => 1.0,
    "codePointAt" => 1.0,
    "concat" => 1.0,
    "construct" => 2.0,
    "copyWithin" => 2.0,
    "cos" => 1.0,
    "cosh" => 1.0,
    "create" => 2.0,
    "decodeURI" => 1.0,
    "decodeURIComponent" => 1.0,
    "defineProperties" => 2.0,
    "defineProperty" => 3.0,
    "delete" => 1.0,
    "deleteProperty" => 2.0,
    "encodeURI" => 1.0,
    "encodeURIComponent" => 1.0,
    "endsWith" => 1.0,
    "eval" => 1.0,
    "every" => 1.0,
    "exp" => 1.0,
    "expm1" => 1.0,
    "fill" => 1.0,
    "filter" => 1.0,
    "finally" => 1.0,
    "find" => 1.0,
    "findIndex" => 1.0,
    "findLast" => 1.0,
    "findLastIndex" => 1.0,
    "flatMap" => 1.0,
    "floor" => 1.0,
    "forEach" => 1.0,
    "freeze" => 1.0,
    "from" => 1.0,
    "groupBy" => 2.0,
    "fromCharCode" => 1.0,
    "fromCodePoint" => 1.0,
    "fromEntries" => 1.0,
    "fround" => 1.0,
    "f16round" => 1.0,
    "get" => 1.0,
    "getOwnPropertyDescriptor" => 2.0,
    "getOwnPropertyDescriptors" => 1.0,
    "getOwnPropertyNames" => 1.0,
    "getOwnPropertySymbols" => 1.0,
    "for" => 1.0,
    "getPrototypeOf" => 1.0,
    "keyFor" => 1.0,
    "has" => 1.0,
    "hasOwn" => 2.0,
    "hasOwnProperty" => 1.0,
    "hypot" => 2.0,
    "sumPrecise" => 1.0,
    "imul" => 2.0,
    "includes" => 1.0,
    "indexOf" => 1.0,
    "is" => 2.0,
    "isArray" => 1.0,
    "isExtensible" => 1.0,
    "isFinite" => 1.0,
    "isFrozen" => 1.0,
    "isInteger" => 1.0,
    "isNaN" => 1.0,
    "isPrototypeOf" => 1.0,
    "isSafeInteger" => 1.0,
    "isSealed" => 1.0,
    "isView" => 1.0,
    "join" => 1.0,
    "lastIndexOf" => 1.0,
    "localeCompare" => 1.0,
    "log" => 1.0,
    "log10" => 1.0,
    "log1p" => 1.0,
    "log2" => 1.0,
    "map" => 1.0,
    "match" => 1.0,
    "matchAll" => 1.0,
    "max" => 2.0,
    "min" => 2.0,
    "padEnd" => 1.0,
    "padStart" => 1.0,
    "parse" => 1.0,
    "parseFloat" => 1.0,
    "parseInt" => 2.0,
    "pow" => 2.0,
    "preventExtensions" => 1.0,
    "propertyIsEnumerable" => 1.0,
    "push" => 1.0,
    "race" => 1.0,
    "raw" => 1.0,
    "reduce" => 1.0,
    "reduceRight" => 1.0,
    "reject" => 1.0,
    "repeat" => 1.0,
    "replace" => 2.0,
    "replaceAll" => 2.0,
    "resolve" => 1.0,
    "round" => 1.0,
    "seal" => 1.0,
    "search" => 1.0,
    "set" => 2.0,
    "setPrototypeOf" => 2.0,
    "sign" => 1.0,
    "sin" => 1.0,
    "sinh" => 1.0,
    "slice" => 2.0,
    "some" => 1.0,
    "sort" => 1.0,
    "splice" => 2.0,
    "split" => 2.0,
    "sqrt" => 1.0,
    "startsWith" => 1.0,
    "stringify" => 3.0,
    "substr" => 2.0,
    "substring" => 2.0,
    "tan" => 1.0,
    "tanh" => 1.0,
    "then" => 2.0,
    "toExponential" => 1.0,
    "toFixed" => 1.0,
    "toPrecision" => 1.0,
    "toSpliced" => 2.0,
    "trunc" => 1.0,
    "unshift" => 1.0,
    "with" => 2.0
  }

  defp function_prop(id, %{generator: true} = o, "prototype") do
    p = new_proto_object(proto(if Map.get(o, :async), do: :async_generator, else: :generator))
    o = deref(id)
    store(id, Obj.put_with_attrs(o, "prototype", p, %{w: true, c: false, e: false}))
    p
  end

  defp function_prop(_id, %{async: true}, "prototype"), do: :undefined

  defp function_prop(id, o, "prototype") do
    case o.fun do
      {:closure, %{name: {:method, _}}} ->
        :undefined

      {:closure, %{mode: mode}} when mode in [false, nil] ->
        p = new_proto_object()
        put_hidden(p, "constructor", {:obj, id})
        o = deref(id)
        store(id, Obj.put_with_attrs(o, "prototype", p, %{w: true, c: false, e: false}))
        p

      {:native, _, _} ->
        :undefined

      _ ->
        :undefined
    end
  end

  defp function_prop(_id, %{fun: {:closure, c}}, "name"),
    do:
      if(is_binary(c.name),
        do: c.name,
        else:
          case c.name do
            {:method, n} when is_binary(n) -> n
            _ -> ""
          end
      )

  defp function_prop(_id, %{fun: {:native, name, _}}, "name"), do: name

  defp function_prop(_id, %{fun: {:closure, c}}, "length"),
    do:
      Enum.count(
        Enum.take_while(
          c.params,
          &(not match?({:rest, _}, &1) and not match?({:default, _, _}, &1))
        )
      ) * 1.0

  defp function_prop(_id, %{fun: {:native, name, _}} = o, "length"),
    do: Map.get(o, :arity) || Map.get(@native_lengths, name, 0.0)

  defp function_prop(_id, _o, _key), do: :undefined

  @doc "Sets an own property without making it show up in `Object.keys`."
  def put_hidden({:obj, id}, key, v), do: store(id, Obj.put_hidden(deref(id), key, v))

  @doc false
  # The end of an object literal with constant keys (`Browser.JS.Compile`): all its
  # properties in one write to the empty object `id`. `layout` is the key layout of
  # `Obj.literal_keys/1`, and `values` gives the value of each key in source order
  # (`Obj.fill/3`).
  def fill_literal(id, layout, values) do
    o = :erlang.get(id)
    :erlang.put(id, Obj.fill(o, layout, values))
  end

  @doc "CreateDataProperty: an own enumerable property, whatever the prototype chain says."
  def define_data({:obj, id}, key, v), do: store(id, Obj.define_data(deref(id), key, v))

  @doc "Sets `@@toStringTag`: not writable or enumerable, but configurable."
  def put_tag({:obj, id}, name) do
    key = {:symbol, :toStringTag, "Symbol.toStringTag"}
    store(id, Obj.put_with_attrs(deref(id), key, name, %{w: false, c: true, e: false}))
  end

  @doc "Overrides the `length` of a native function."
  def set_arity({:obj, id}, n), do: store(id, Map.put(deref(id), :arity, n * 1.0))

  @doc "Sets an own property that is not writable, enumerable or configurable (a built-in's `prototype`)."
  def put_const({:obj, id}, key, v),
    do: store(id, Obj.put_with_attrs(deref(id), key, v, %{w: false, c: false, e: false}))

  # Runs a setter or a proxy trap of a write and puts the flag `:js_put_failed` back as it
  # was. A sloppy write in the callee that fails sets the flag, but that failure is not a
  # failure of this write: the strict write that runs the setter must not throw for it.
  defmacrop keep_put_flag(expr) do
    quote do
      flag = :erlang.get(:js_put_failed)
      result = unquote(expr)
      :erlang.put(:js_put_failed, flag)
      result
    end
  end

  @doc false
  # `keep_put_flag/1` for the other modules (`Browser.JS.Proxy`).
  def keep_put_flag_fun(fun), do: keep_put_flag(fun.())

  def put({:obj, id} = obj, {:private, _} = key, v) do
    o = deref(id)

    case Obj.own_fetch(o, key) do
      {:ok, {:accessor, _, setter}} ->
        if function?(setter),
          do: keep_put_flag(call(setter, obj, [v])),
          else: throw_error("TypeError", "'#x' was defined without a setter")

        :ok

      {:ok, _} ->
        if key in Map.get(o, :pmethods, []),
          do: throw_error("TypeError", "Private methods are not writable")

        store(id, Obj.own_put_value(o, key, v))

      :error ->
        throw_error(
          "TypeError",
          "Cannot write private member to an object whose class did not declare it"
        )
    end
  end

  def put(_, {:private, _}, _),
    do: throw_error("TypeError", "Cannot write private member to a non-object")

  def put({:obj, id}, key, v), do: put_obj(id, deref(id), key, v, false)

  def put(v, key, _) when v in [:undefined, :null],
    do:
      throw_error(
        "TypeError",
        "Cannot set properties of #{to_str(v)} (setting '#{safe_key(key)}')"
      )

  # a primitive has no property of its own to set, but a setter (or proxy) on its prototype
  # chain still runs
  def put(primitive, key, v) do
    primitive_set(primitive, key, v)
    v
  end

  # The guard of the fast update (fast path `:update`): the record `o` is not an array, not
  # a host object and not a proxy, `old` (the stored value of the own key `key`) is not an
  # accessor, and `key` has no attributes, so it is writable. For such a write `put_obj/5`
  # only stores the value: the clauses for arrays, host objects (typed arrays, proxies of
  # plain objects, the global object, module namespaces and DOM objects) and proxies of
  # functions do not match, the clause for the `name` and `length` of a function goes to
  # `put_prop/4` because the record has the own key, and `put_prop/4` stores the value when
  # the own key is not an accessor and `Obj.writable?/2` is true. A change to one of these
  # clauses needs a change to this guard. Today the tests of the class and of `proxy` are
  # also defence in depth: a proxy of a function has no own key, a proxy of a plain object
  # is a host object, and `put_obj/5` stores a named key of an array as this path does.
  # They stay, so that a change to the layout of these records is not a wrong write. The
  # row "dm update guard terms" of the data-model corpus tries each one.
  defmacrop plain_update(o, key, old) do
    quote do
      :erlang.map_get(:class, unquote(o)) != :array and
        :erlang.map_get(:class, unquote(o)) != :host and
        not is_map_key(unquote(o), :proxy) and
        not (is_tuple(unquote(old)) and tuple_size(unquote(old)) == 3 and
               :erlang.element(1, unquote(old)) == :accessor) and
        Obj.default_attrs?(unquote(o), unquote(key))
    end
  end

  # The store of the fast update: the record has `key`, so the map update keeps the key
  # tuple (`Obj.own_update/3`).
  @compile {:inline, update_prop: 4}
  defp update_prop(id, o, key, v) do
    :erlang.put(id, Obj.own_update(o, key, v))
    v
  end

  # The write of `put_named/3` and `strict_put_named/3` to the object with the id `id`, in
  # one place, so that the strict and the sloppy write cannot drift apart. `o` is the entry
  # at `id` (`:undefined` when the heap has none). Only the write that does not take the
  # fast update differs: `strict_put_obj/4` or `put_obj/5`. It is a macro, not an inline
  # function, because the compiler does not inline `put_obj/5` into a function that it
  # inlines, and each write would then pay one more call. `id`, `key` and `v` must be
  # variables. The inline caches use it for the records that are not fast (`put_ic/4`).
  defmacrop named_write(id, o, key, v, strict?) do
    slow = fn o ->
      if strict?,
        do: quote(do: strict_put_obj(unquote(id), unquote(o), unquote(key), unquote(v))),
        else: quote(do: put_obj(unquote(id), unquote(o), unquote(key), unquote(v), true))
    end

    quote do
      o = unquote(o)

      Obj.own_case o, unquote(key) do
        {:ok, old} when plain_update(o, unquote(key), old) ->
          if Fast.on?(:update),
            do:
              Fast.shadow(
                unquote(id),
                update_prop(unquote(id), o, unquote(key), unquote(v)),
                put_obj(unquote(id), o, unquote(key), unquote(v), true)
              ),
            else: unquote(slow.(quote(do: o)))

        # (a second read, so that an id that is not in the heap gives the error of `deref/1`)
        _ ->
          o = deref(unquote(id))
          unquote(slow.(quote(do: o)))
      end
    end
  end

  @doc false
  # A property write with a constant key (step 5, `Browser.JS.Compile`), as `get_named/2`
  # reads one: the key is a string that is not an array index, and the class dispatch is
  # the one of `put/3`, in `put_obj/5`. A primitive goes to `put/3`. The update of an own
  # writable data property reads the record once and does not go through `put_obj/5`
  # (`plain_update/3`).
  def put_named({:obj, id}, key, v), do: named_write(id, :erlang.get(id), key, v, false)
  def put_named(ov, key, v), do: put(ov, key, v)

  @doc false
  # `strict_put/3` with a constant key, as `put_named/3`. A primitive goes to
  # `strict_put/3`, which has a clause of its own for primitives. The update of an own
  # writable data property cannot fail, so the fast update does not set and read the flag
  # `:js_put_failed`: every reader of the flag sets it to false before its own write.
  def strict_put_named({:obj, id}, key, v), do: named_write(id, :erlang.get(id), key, v, true)
  def strict_put_named(ov, key, v), do: strict_put(ov, key, v)

  # ── inline caches (step A2) ────────────────────────────────
  # The named sites of the compiled code read and write through an inline cache. The site
  # number, the cells and the rules of a hit are in the moduledoc of `Browser.JS.Shape`. A
  # record that is not fast, and every record when the fast path `:ic` is off, takes the
  # path of `get_named/2` or `put_named/3`. A hit makes no change of the heap and calls
  # nothing that the generic path would not call, so the steps, the heap ids and the
  # results of the oracles stay the same. In the check build each hit also runs the
  # generic path and compares (`Fast.shadow/3`).

  # The misses that a cell can count before it becomes `:mega`.
  @ic_misses 16

  @doc false
  # A property read with a constant key at the site `site` of the compiled code: the read
  # of `get_named/2` with an inline cache.
  def get_ic({:obj, id} = obj, key, site) do
    case :erlang.get(id) do
      Obj.fast_record(sid, vals) = o ->
        if Fast.on?(:ic) do
          case :erlang.get(site) do
            {^sid, pos, _} ->
              case :erlang.element(pos, vals) do
                {:accessor, _, _} -> get_ic_miss(id, o, key, site)
                v -> Fast.shadow(nil, v, get_obj(id, o, key, true))
              end

            {^sid, _} ->
              get_obj(id, o, key, true)

            {^sid, pid, psid, pos, _} ->
              case ic_proto(o, pid, psid) do
                nil -> get_ic_miss(id, o, key, site)
                p -> ic_data(Obj.slot(p, pos), id, o, key, site)
              end

            {^sid, :get, pos, _} ->
              ic_getter(:erlang.element(pos, vals), obj, o, key, site)

            {^sid, :get, pid, psid, pos, _} ->
              case ic_proto(o, pid, psid) do
                nil -> get_ic_miss(id, o, key, site)
                p -> ic_getter(Obj.slot(p, pos), obj, o, key, site)
              end

            {^sid, pid1, psid1, pid2, psid2, pos, _} ->
              with p1 when p1 != nil <- ic_proto(o, pid1, psid1),
                   p2 when p2 != nil <- ic_proto(p1, pid2, psid2) do
                ic_data(Obj.slot(p2, pos), id, o, key, site)
              else
                _ -> get_ic_miss(id, o, key, site)
              end

            {^sid, :get, pid1, psid1, pid2, psid2, pos, _} ->
              with p1 when p1 != nil <- ic_proto(o, pid1, psid1),
                   p2 when p2 != nil <- ic_proto(p1, pid2, psid2) do
                ic_getter(Obj.slot(p2, pos), obj, o, key, site)
              else
                _ -> get_ic_miss(id, o, key, site)
              end

            :mega ->
              get_obj(id, o, key, true)

            _ ->
              get_ic_miss(id, o, key, site)
          end
        else
          get_obj(id, o, key, true)
        end

      # (an id that is not in the heap gives the error of `deref/1`)
      :undefined ->
        get_obj(id, deref(id), key, true)

      o ->
        get_obj(id, o, key, true)
    end
  end

  def get_ic(s, key, _site) when is_binary(s), do: get_str(s, key, true)
  def get_ic(v, key, _site), do: get(v, key)

  # The record at `pid` when it is the prototype of `o` and has the shape `psid`, or `nil`.
  # A freed id gives `:undefined`, which does not match.
  @compile {:inline, ic_proto: 3}
  defp ic_proto(o, pid, psid) do
    case :erlang.map_get(:proto, o) do
      {:obj, ^pid} ->
        case :erlang.get(pid) do
          Obj.fast_record(^psid, _) = p -> p
          _ -> nil
        end

      _ ->
        nil
    end
  end

  # The hit of a data cell of a prototype: the value `v`, or a miss when the value is now an
  # accessor (`defineProperty` can make a data property an accessor with the same bits).
  @compile {:inline, ic_data: 5}
  defp ic_data(v, id, o, key, site) do
    case v do
      {:accessor, _, _} -> get_ic_miss(id, o, key, site)
      v -> Fast.shadow(nil, v, get_obj(id, o, key, true))
    end
  end

  # The hit of a getter cell: the getter of the stored accessor `stored`, called with the
  # receiver `obj` as `lookup/3` calls it, or a miss when the value is now a data property.
  # The shadow run compares the accessor with the one that the generic read finds
  # (`ic_stored/2`), because the generic read would call the getter a second time.
  defp ic_getter(stored, {:obj, id} = obj, o, key, site) do
    case stored do
      {:accessor, getter, _} ->
        _ = Fast.shadow(nil, stored, ic_stored(o, key))
        if function?(getter), do: call(getter, obj, []), else: :undefined

      _ ->
        get_ic_miss(id, o, key, site)
    end
  end

  # The stored value of `key` that `lookup/3` finds from the record `o`, with no call of a
  # getter: an accessor is `{:accessor, getter, setter}`, and no key gives `:none`. Only the
  # shadow run of a getter cell uses it, and a getter cell holds only plain records, so
  # the walk has no clause for a proxy, a host object or an array.
  defp ic_stored(o, key) do
    Obj.own_case o, key do
      {:ok, v} ->
        v

      :error ->
        case :erlang.map_get(:proto, o) do
          {:obj, pid} -> ic_stored(deref(pid), key)
          _ -> :none
        end
    end
  end

  # A miss of a read: the cell of the site gets the place where the generic read finds the
  # key, and the generic read gives the value.
  defp get_ic_miss(id, o, key, site) do
    ic_learn(site, ic_read_cell(o, key))
    get_obj(id, o, key, true)
  end

  # The cell of a read of `key` from the fast record `o`, without the count of the misses
  # (see `Browser.JS.Shape`): the own key, or the key of the prototype or of its prototype
  # when these are fast plain records, as `lookup/3` and `lookup_proto/3` find it. Any other
  # case is the generic path `{sid}`.
  defp ic_read_cell(o, key) do
    sid = Obj.shape_id(o)

    with true <- ic_plain?(o),
         {where, stored} <- ic_find(o, key, 0) do
      case {where, stored} do
        {{pos}, {:accessor, _, _}} ->
          {sid, :get, pos}

        {{pos}, _} ->
          {sid, pos}

        {{pid, psid, pos}, {:accessor, _, _}} ->
          {sid, :get, pid, psid, pos}

        {{pid, psid, pos}, _} ->
          {sid, pid, psid, pos}

        {{pid1, psid1, pid2, psid2, pos}, {:accessor, _, _}} ->
          {sid, :get, pid1, psid1, pid2, psid2, pos}

        {{pid1, psid1, pid2, psid2, pos}, _} ->
          {sid, pid1, psid1, pid2, psid2, pos}
      end
    else
      _ -> {sid}
    end
  end

  # Where the plain chain from the fast record `o` holds `key`, at the depth `depth` of `o`
  # (0 for the receiver): `{place, stored}`, where `place` is `{pos}`, `{pid, psid, pos}` or
  # `{pid1, psid1, pid2, psid2, pos}`, or `nil`. A prototype counts only when it is a fast
  # plain record, so that its shape tells what it holds.
  defp ic_find(o, key, depth) do
    case Obj.fast_slot(o, key) do
      {pos, _bits} ->
        {{pos}, Obj.slot(o, pos)}

      nil when depth < 2 ->
        with {:obj, pid} <- :erlang.map_get(:proto, o),
             p when is_map(p) <- :erlang.get(pid),
             true <- ic_plain?(p),
             {place, stored} <- ic_find(p, key, depth + 1) do
          {:erlang.insert_element(1, :erlang.insert_element(1, place, Obj.shape_id(p)), pid),
           stored}
        else
          _ -> nil
        end

      nil ->
        nil
    end
  end

  # Whether the record `o` can be in a cell: a fast record of a plain object. Its reads and
  # writes of a named key then take the last clause of `get_obj/4` and `put_obj/5`, which
  # `lookup/3` and `put_prop/4` do. (step A2 makes only plain objects fast; a later step
  # that makes other records fast must look at this test)
  @compile {:inline, ic_plain?: 1}
  defp ic_plain?(o),
    do: Obj.fast?(o) and :erlang.map_get(:class, o) == :object and not is_map_key(o, :proxy)

  # Writes the cell `cell` (without its count) to the site `site`. The count goes up by one
  # for each miss, and past `@ic_misses` the cell becomes `:mega`.
  defp ic_learn(site, cell) do
    n =
      case :erlang.get(site) do
        :undefined -> 0
        old -> :erlang.element(tuple_size(old), old)
      end

    if n >= @ic_misses,
      do: :erlang.put(site, :mega),
      else: :erlang.put(site, :erlang.append_element(cell, n + 1))
  end

  @doc false
  # A property write with a constant key at the site `site` of the compiled code: the write
  # of `put_named/3` with an inline cache.
  def put_ic({:obj, id}, key, v, site) do
    case :erlang.get(id) do
      Obj.fast_record(sid, vals) = o ->
        if Fast.on?(:ic) do
          case :erlang.get(site) do
            {^sid, pos, _} ->
              case :erlang.element(pos, vals) do
                {:accessor, _, _} ->
                  put_ic_miss(id, o, key, v, site)

                _ ->
                  Fast.shadow(id, ic_store(id, o, vals, pos, v), put_obj(id, o, key, v, true))
              end

            {^sid, _} ->
              put_obj(id, o, key, v, true)

            :mega ->
              put_obj(id, o, key, v, true)

            _ ->
              put_ic_miss(id, o, key, v, site)
          end
        else
          named_write(id, o, key, v, false)
        end

      o ->
        named_write(id, o, key, v, false)
    end
  end

  def put_ic(ov, key, v, _site), do: put(ov, key, v)

  @doc false
  # `put_ic/4` for strict code: the write of `strict_put_named/3` with an inline cache. A hit
  # writes a writable data property, which cannot fail, so it does not set and read the
  # flag `:js_put_failed`.
  def strict_put_ic({:obj, id}, key, v, site) do
    case :erlang.get(id) do
      Obj.fast_record(sid, vals) = o ->
        if Fast.on?(:ic) do
          case :erlang.get(site) do
            {^sid, pos, _} ->
              case :erlang.element(pos, vals) do
                {:accessor, _, _} ->
                  strict_put_ic_miss(id, o, key, v, site)

                _ ->
                  Fast.shadow(id, ic_store(id, o, vals, pos, v), put_obj(id, o, key, v, true))
              end

            {^sid, _} ->
              strict_put_obj(id, o, key, v)

            :mega ->
              strict_put_obj(id, o, key, v)

            _ ->
              strict_put_ic_miss(id, o, key, v, site)
          end
        else
          named_write(id, o, key, v, true)
        end

      o ->
        named_write(id, o, key, v, true)
    end
  end

  def strict_put_ic(ov, key, v, _site), do: strict_put(ov, key, v)

  # The store of a write hit: the value at the position `pos` of the fast record `o`.
  @compile {:inline, ic_store: 5}
  defp ic_store(id, o, vals, pos, v) do
    :erlang.put(id, Obj.put_slot(o, vals, pos, v))
    v
  end

  # A miss of a write: the cell of the site gets the position of the key when the record
  # holds it as a writable data property, and the generic write runs.
  defp put_ic_miss(id, o, key, v, site) do
    ic_learn(site, ic_write_cell(o, key))
    put_obj(id, o, key, v, true)
  end

  defp strict_put_ic_miss(id, o, key, v, site) do
    ic_learn(site, ic_write_cell(o, key))
    strict_put_obj(id, o, key, v)
  end

  # The cell of a write of `key` to the fast record `o` (without the count of the misses):
  # `{sid, pos}` when `o` is a plain record that holds `key` as a writable data property.
  # For such a key `put_obj/5` goes to `put_prop/4`, which only stores the value (the own
  # key is not an accessor and `Obj.writable?/2` is true). Any other write is the generic
  # path `{sid}`: an add, a setter, a key that is not writable.
  defp ic_write_cell(o, key) do
    sid = Obj.shape_id(o)

    case Obj.fast_slot(o, key) do
      {pos, bits} ->
        if ic_plain?(o) and Bitwise.band(bits, 1) != 0 and
             not match?({:accessor, _, _}, Obj.slot(o, pos)),
           do: {sid, pos},
           else: {sid}

      nil ->
        {sid}
    end
  end

  defp strict_put_obj(id, o, key, v) do
    :erlang.put(:js_put_failed, false)
    put_obj(id, o, key, v, true)
    strict_done(key, v)
  end

  # The write of `v` to `key` of the object `o` with the id `id`: the class dispatch of
  # `put/3` and `put_named/3`. `named?` is true when the key is a string that is not an
  # array index, as in `get_obj/4`. The function is inline for the same reason.
  @compile {:inline, put_obj: 5}
  defp put_obj(id, o, key, v, named?) do
    case o do
      %{class: :array} ->
        case if(named?, do: nil, else: index(key)) do
          i when is_integer(i) ->
            # (the element at `i` now, read once for all the tests below)
            cur = Map.fetch(o.items, i)

            cond do
              match?({:ok, {:accessor, _, _}}, cur) ->
                {:ok, {:accessor, _, setter}} = cur

                if function?(setter),
                  do: keep_put_flag(call(setter, {:obj, id}, [v])),
                  else: fail_put()

                :ok

              Obj.frozen?(o) ->
                fail_put()

              cur == :error and not Obj.extensible?(o) ->
                fail_put()

              i >= o.len and Map.get(o, :len_ro, false) ->
                fail_put()

              not Obj.writable?(o, i) ->
                fail_put()

              cur == :error and index_hook(o.proto, i) != :none ->
                case index_hook(o.proto, i) do
                  {:setter, setter} ->
                    keep_put_flag(call(setter, {:obj, id}, [v]))

                  {:proxy, proxy} ->
                    unless Browser.JS.Proxy.set(proxy, to_key(key), v, {:obj, id}),
                      do: fail_put()

                  :skip ->
                    :ok
                end

                :ok

              true ->
                # an arguments object's `length` is an ordinary property: it does not grow
                len = if Map.has_key?(o, :arguments), do: o.len, else: max(o.len, i + 1)
                store(id, %{o | items: Map.put(o.items, i, v), len: len})
                if Map.has_key?(o, :mapped), do: sync_param(o, i, v)
            end

          nil ->
            # an arguments object's `length` is an ordinary property that takes any value
            if key == "length" and is_map_key(o, :arguments),
              do: put_prop(id, o, key, v),
              else: put_array_prop(id, o, key, v)
        end

      %{class: :host, host: {Browser.JS.TypedArrays, data}}
      when is_number(key) and key >= 0 and key == trunc(key) ->
        case Browser.JS.TypedArrays.put_index(data, trunc(key), v) do
          :ok -> :ok
          :readonly -> fail_put()
        end

      %{class: :host, host: {mod, data}} ->
        key = if(named?, do: key, else: to_key(key))

        case mod.host_put(data, key, v, {:obj, id}) do
          :ok -> :ok
          :miss -> put_prop(id, o, key, v)
          :readonly -> fail_put()
        end

      %{proxy: _} ->
        unless Browser.JS.Proxy.set(
                 {:obj, id},
                 if(named?, do: key, else: to_key(key)),
                 v,
                 {:obj, id}
               ),
               do: fail_put()

        :ok

      # a function's own name and length are not writable
      %{class: :function} when key in ["name", "length"] ->
        unless Obj.has_own?(o, key) or key in Map.get(o, :gone, []),
          do: fail_put(),
          else: put_prop(id, o, key, v)

      _ ->
        put_prop(id, o, if(named?, do: key, else: to_key(key)), v)
    end

    v
  end

  defp primitive_set(ov, key, v) do
    k = to_key(key)

    case inherited_set(Browser.JS.Builtins.box(ov), k) do
      {:setter, setter} ->
        keep_put_flag(call(setter, ov, [v]))
        :ok

      {:proxy, proxy} ->
        if Browser.JS.Proxy.set(proxy, k, v, ov), do: :ok, else: :fail

      _ ->
        :fail
    end
  end

  # naming a key in an error must not run user code (a toString that throws)
  # It is public because the closure compiler (`Browser.JS.Compile`) calls it.
  @doc false
  def safe_key(key) when is_binary(key), do: key
  def safe_key(key) when is_number(key), do: to_str(key)
  def safe_key(_), do: "?"

  # an assignment: own accessor or non-writable property, inherited ones, then a new property
  defp put_prop(id, o, key, v) do
    Obj.own_case o, key do
      {:ok, {:accessor, _, setter}} ->
        if function?(setter), do: keep_put_flag(call(setter, {:obj, id}, [v])), else: fail_put()
        :ok

      {:ok, _} ->
        if Obj.writable?(o, key),
          do: store(id, Obj.own_update(o, key, v)),
          else: fail_put()

      # a generator function's own `prototype` is made on first use and shadows the one of
      # its kind's prototype object
      :error
      when key == "prototype" and is_map_key(o, :generator) and
             not Obj.has_own?(o, "prototype") ->
        function_prop(id, o, "prototype")
        put({:obj, id}, key, v)

      :error ->
        case inherited_set(o.proto, key) do
          {:setter, setter} ->
            keep_put_flag(call(setter, {:obj, id}, [v]))
            :ok

          :readonly ->
            fail_put()

          {:proxy, proxy} ->
            unless Browser.JS.Proxy.set(proxy, key, v, {:obj, id}), do: fail_put()
            :ok

          {:typed_array, ta} ->
            unless keep_put_flag(Browser.JS.Props.ordinary_set(ta, key, v, {:obj, id})),
              do: fail_put()

            :ok

          :none ->
            if Obj.extensible?(o),
              do: store(id, Obj.own_add_assigned(o, key, v)),
              else: fail_put()
        end
    end
  end

  # a failed [[Set]]: sloppy code ignores it, strict code (`strict_put`) throws
  defp fail_put, do: :erlang.put(:js_put_failed, true)

  # a primitive has no property to set: in strict code only a setter on its prototype chain works
  # It is public because the closure compiler (`Browser.JS.Compile`) calls it.
  @doc false
  def strict_put(ov, key, v)
      when is_binary(ov) or is_number(ov) or is_boolean(ov) or
             (is_tuple(ov) and elem(ov, 0) in [:symbol, :bigint]) do
    case primitive_set(ov, key, v) do
      :ok ->
        v

      # (a number key comes from `prop_key/1`: the message names it as its string)
      :fail ->
        name =
          cond do
            is_binary(key) -> key
            is_number(key) -> to_str(key)
            true -> "#"
          end

        throw_error("TypeError", "Cannot create property '#{name}' on #{typeof(ov)}")
    end
  end

  def strict_put(ov, key, v) do
    :erlang.put(:js_put_failed, false)
    put(ov, key, v)
    strict_done(key, v)
  end

  # The end of a strict write (`strict_put/3`, `strict_put_named/3`): a write that failed
  # throws, and a write that did not fail gives the value.
  @compile {:inline, strict_done: 2}
  defp strict_done(key, v) do
    if :erlang.get(:js_put_failed) == true do
      :erlang.put(:js_put_failed, false)
      throw_error("TypeError", "Cannot assign to read only property '#{to_str(key)}'")
    end

    v
  end

  # an assignment to a name nothing declares is a ReferenceError in strict code
  defp resolvable?(scope, name) do
    case deref(scope) do
      f when is_tuple(f) ->
        if is_map_key(:erlang.element(2, f).slots, name),
          do: true,
          else: resolvable?(:erlang.element(1, f), name)

      s ->
        cond do
          Map.has_key?(s.vars, name) -> true
          is_binary(name) and is_map_key(s, :with) and has_property?(s.with, name) -> true
          s.parent != nil -> resolvable?(s.parent, name)
          is_binary(name) -> global_own_property?(s, name)
          true -> false
        end
    end
  end

  # where a name resolves to: the scope declaring it or the `with` object having it
  defp with_binding(scope, name) do
    case deref(scope) do
      f when is_tuple(f) ->
        if is_map_key(:erlang.element(2, f).slots, name),
          do: {:var, scope},
          else: with_binding(:erlang.element(1, f), name)

      s ->
        cond do
          Map.has_key?(s.vars, name) ->
            {:var, scope}

          is_binary(name) and is_map_key(s, :with) and has_property?(s.with, name) and
              not unscopable?(s.with, name) ->
            {:with, s.with}

          s.parent != nil ->
            with_binding(s.parent, name)

          true ->
            nil
        end
    end
  end

  defp simple_value?({tag, _}) when tag in [:lit, :id, :num, :str], do: true
  defp simple_value?(_), do: false

  defp strict_assign_var(env, name, v, resolved?) do
    unless resolved?, do: throw_error("ReferenceError", "#{name} is not defined")

    if assign_var(env, name, v) == :fname_ignored,
      do: throw_error("TypeError", "Assignment to constant variable.")

    :ok
  end

  defp inherited_set({:obj, pid}, key) do
    p = deref(pid)

    Obj.own_case p, key do
      _ when is_map_key(p, :proxy) ->
        {:proxy, {:obj, pid}}

      {:ok, {:accessor, _, setter}} ->
        if function?(setter), do: {:setter, setter}, else: :readonly

      {:ok, _} ->
        if Obj.writable?(p, key), do: :none, else: :readonly

      :error ->
        if is_binary(key) and typed_array_record?(pid, p) and
             Browser.JS.TypedArrays.numeric_key?(key),
           do: {:typed_array, {:obj, pid}},
           else: inherited_set(p.proto, key)
    end
  end

  defp inherited_set(_, _), do: :none

  # Whether the record `p` at `pid` is a typed array. `TypedArrays.typed_array?/1` is this
  # match on the record, which it reads again; the walk of `inherited_set/2` has the record
  # already (fast path `:add`).
  @compile {:inline, typed_array_record?: 2}
  defp typed_array_record?(pid, p) do
    if Fast.on?(:add),
      do:
        Fast.shadow(
          nil,
          match?(%{host: {Browser.JS.TypedArrays, {:ta, _, _, _, _}}}, p),
          Browser.JS.TypedArrays.typed_array?({:obj, pid})
        ),
      else: Browser.JS.TypedArrays.typed_array?({:obj, pid})
  end

  # a missing array element: an index setter or a proxy further up the prototype chain
  defp put_array_prop(id, o, key, v) do
    if key == "length" do
      new_len = array_length!(v)
      # the coercion may have run code that changed the array
      o = deref(id)

      if Obj.frozen?(o) or Map.get(o, :len_ro, false) do
        fail_put()
      else
        # an element that cannot be deleted stops the array from shrinking past it
        stop =
          o
          |> Obj.max_fixed_element(new_len)
          |> then(&if(&1, do: &1 + 1, else: new_len))

        store(id, %{o | items: Map.filter(o.items, fn {i, _} -> i < stop end), len: stop})
      end
    else
      put_prop(id, o, to_key(key), v)
    end
  end

  defp index_hook({:obj, pid}, i) do
    p = deref(pid)
    k = Integer.to_string(i)

    cond do
      is_map_key(p, :proxy) ->
        {:proxy, {:obj, pid}}

      match?(%{class: :array, items: %{^i => {:accessor, _, _}}}, p) ->
        {:accessor, _, setter} = p.items[i]
        if function?(setter), do: {:setter, setter}, else: :none

      match?(%{class: :array, items: %{^i => _}}, p) ->
        :none

      Browser.JS.TypedArrays.typed_array?({:obj, pid}) ->
        # an index outside a typed array in the chain stops the set without creating it
        if Browser.JS.TypedArrays.invalid_index?({:obj, pid}, k), do: :skip, else: :none

      match?({:ok, {:accessor, _, _}}, Obj.own_fetch(p, k)) ->
        {:ok, {:accessor, _, setter}} = Obj.own_fetch(p, k)
        if function?(setter), do: {:setter, setter}, else: :none

      true ->
        index_hook(p.proto, i)
    end
  end

  defp index_hook(_, _), do: :none

  @doc false
  def array_index(key), do: index(key)

  def delete({:obj, id}, key) do
    o = deref(id)

    case o do
      %{proxy: _} ->
        Browser.JS.Proxy.delete({:obj, id}, to_key(key))

      %{class: :host, host: {mod, data}} ->
        if function_exported?(mod, :host_delete, 2),
          # a host that has nothing to say about `key` answers :default
          do: with(:default <- mod.host_delete(data, to_key(key)), do: delete_plain(id, o, key)),
          else: delete_plain(id, o, key)

      _ ->
        delete_plain(id, o, key)
    end
  end

  def delete(_, _), do: true

  defp delete_plain(id, o, key) do
    i = if o.class == :array, do: index(key)

    cond do
      # the indices and `length` of a String wrapper are not configurable
      match?(%{prim: str} when is_binary(str), o) and
          (to_key(key) == "length" or
             (is_integer(index(key)) and index(key) < Browser.JS.Str.length(o.prim))) ->
        false

      o.class == :function and key in ["name", "length"] and not Obj.has_own?(o, key) ->
        store(id, Map.update(o, :gone, [key], &[key | &1]))
        true

      # the `prototype` a function has of its own cannot be deleted
      o.class == :function and key == "prototype" and not Obj.has_own?(o, key) and
          Browser.JS.Props.has_own?({:obj, id}, key) ->
        false

      i && not Obj.configurable?(o, i) && Map.has_key?(o.items, i) ->
        false

      # a frozen or sealed array keeps its elements, and `length` is never configurable
      i && (Obj.frozen?(o) or Obj.sealed?(o)) && Map.has_key?(o.items, i) ->
        false

      o.class == :array and key == "length" and not Map.has_key?(o, :arguments) ->
        false

      i ->
        store(id, %{o | items: Map.delete(o.items, i)})
        if Map.has_key?(o, :mapped), do: unmap_argument(id, i)
        true

      true ->
        key = to_key(key)

        if Obj.has_own?(o, key) and not Obj.configurable?(o, key) do
          false
        else
          store(
            id,
            o
            |> Obj.own_delete(key)
            |> then(fn o2 ->
              # a function's own `name` or `length` that is gone must not reappear as the virtual one
              if o.class == :function and key in ["name", "length"],
                do: Map.update(o2, :gone, [key], &[key | &1]),
                else: o2
            end)
          )

          true
        end
    end
  end

  def has_property?({:obj, id}, key) do
    o = deref(id)
    key_s = to_key(key)

    cond do
      Map.has_key?(o, :proxy) ->
        Browser.JS.Proxy.has({:obj, id}, key_s)

      # what a host object answers for is there (`"foo" in window`)
      o.class == :host and host_has?(o, id, key_s) ->
        true

      # a typed array never looks past itself for a numeric key
      o.class == :host and match?({Browser.JS.TypedArrays, _}, o.host) and
          Browser.JS.TypedArrays.numeric_key?(key_s) ->
        false

      o.class == :array and key_s == "length" and not is_map_key(o, :arguments) ->
        true

      match?(%{prim: str} when is_binary(str), o) and is_integer(index(key)) and
          index(key) < Browser.JS.Str.length(o.prim) ->
        true

      o.class == :array and is_integer(index(key)) ->
        Map.has_key?(o.items, index(key)) or
          (match?({:obj, _}, o.proto) and has_property?(o.proto, key_s))

      Obj.has_own?(o, key_s) ->
        true

      o.class == :function and key_s in ["name", "length", "prototype"] and
          Browser.JS.Props.has_own?({:obj, id}, key_s) ->
        true

      match?({:obj, _}, o.proto) ->
        has_property?(o.proto, key_s)

      true ->
        false
    end
  end

  def has_property?(_, _),
    do: throw_error("TypeError", "Cannot use 'in' operator to search for a key in a non-object")

  defp host_has?(%{host: {mod, data}}, id, key) do
    if function_exported?(mod, :host_has, 2),
      do: mod.host_has(data, key),
      else: match?({:ok, v} when v != :undefined, mod.host_get(data, key, {:obj, id}))
  end

  @doc "Own enumerable string keys, in insertion order (array indices first)."
  def own_keys({:obj, id}) do
    o = deref(id)

    case o do
      %{proxy: _} ->
        Browser.JS.Proxy.host_keys(id)

      %{class: :host, host: {Browser.JS.TypedArrays, data}} ->
        Browser.JS.TypedArrays.host_keys(data) ++ own_keys_plain(o)

      # what `defineProperty` stored on the global object itself comes after the variables
      %{class: :host, host: {Browser.JS.Global, data}} ->
        Browser.JS.Global.host_keys(data) ++ own_keys_plain(o)

      %{class: :host, host: {mod, data}} ->
        if function_exported?(mod, :host_keys, 1),
          do: with(:default <- mod.host_keys(data), do: own_keys_plain(o)),
          else: own_keys_plain(o)

      _ ->
        own_keys_plain(o)
    end
  end

  def own_keys(s) when is_binary(s),
    do: for(i <- 0..(Browser.JS.Str.length(s) - 1)//1, do: Integer.to_string(i))

  def own_keys(_), do: []

  # The enumerable keys (`Obj.enum_names/1`), with the index keys first. The common case is
  # a plain object whose keys all start with a character that is not a digit. Such a key
  # cannot be an array index, so the sort of the index keys has nothing to do, and the keys
  # are the list as it is (fast path `:has_own`, `Obj.plain_names/1`). A symbol among the
  # enumerable keys is no plain name, and it goes to the long path, which drops it. The
  # other classes are clauses of the same `case`, so that they pay no extra call.
  defp own_keys_plain(o) do
    case o do
      %{class: c} when c != :array and c != :function and not is_map_key(o, :prim) ->
        names = if Fast.on?(:has_own), do: Obj.plain_names(o)

        if names,
          do: Fast.shadow(nil, names, own_keys_index_first(o)),
          else: own_keys_index_first(o)

      %{class: :array} ->
        for(
          i <- o.items |> Map.keys() |> Enum.sort(),
          i < o.len,
          Obj.element_enumerable?(o, i),
          do: Integer.to_string(i)
        ) ++ Obj.enum_names(o)

      %{prim: str} when is_binary(str) ->
        base = Obj.enum_names(o)

        {ints, rest} =
          Enum.split_with(base, &(is_integer(index(&1)) and index(&1) < 4_294_967_295))

        for(i <- 0..(Browser.JS.Str.length(str) - 1)//1, do: Integer.to_string(i)) ++
          Enum.sort_by(ints, &index/1) ++ rest

      _ ->
        base = Obj.enum_names(o)

        {ints, rest} =
          Enum.split_with(base, &(is_integer(index(&1)) and index(&1) < 4_294_967_295))

        rest =
          if o[:class] == :function do
            std = for k <- ["length", "name", "prototype"], k in rest, do: k
            std ++ (rest -- std)
          else
            rest
          end

        Enum.sort_by(ints, &index/1) ++ rest
    end
  end

  # The keys of an object that is not an array, a function or a primitive wrapper, with the
  # index keys first: the last clause of `own_keys_plain/1` for such an object.
  defp own_keys_index_first(o) do
    base = Obj.enum_names(o)

    {ints, rest} =
      Enum.split_with(base, &(is_integer(index(&1)) and index(&1) < 4_294_967_295))

    Enum.sort_by(ints, &index/1) ++ rest
  end

  def array_list({:obj, id}) do
    o = deref(id)

    for i <- 0..(o.len - 1)//1 do
      case Map.get(o.items, i, :undefined) do
        {:accessor, g, _} -> if function?(g), do: call(g, {:obj, id}, []), else: :undefined
        v -> v
      end
    end
  end

  def set_array_list({:obj, id}, list) do
    o = deref(id)
    store(id, %{o | items: items_map(list), len: length(list)})
  end

  def array?({:obj, id}), do: deref(id).class == :array
  def array?(_), do: false

  def iterate({:obj, id} = v) do
    o = deref(id)

    cond do
      o.class == :array -> array_list(v)
      o.class in [:map, :set] -> Browser.JS.Collections.entries(o)
      true -> iterate_protocol(v)
    end
  end

  def iterate(s) when is_binary(s), do: Browser.JS.Str.codepoints(s)
  def iterate(v), do: throw_error("TypeError", "#{to_str(v)} is not iterable")

  @doc false
  # what `for of` loops over: a list that is known up front (arrays, strings, Map, Set), or an
  # iterator object to pull from one value at a time, so that an endless generator can be left
  # with `break`
  def iter_source({:obj, id} = v) do
    o = deref(id)

    if (o.class == :array and array_iteration_pristine?(v)) or o.class in [:map, :set] do
      {:list, iterate(v)}
    else
      proto_source(v)
    end
  end

  def iter_source(v) when is_binary(v) or v in [:undefined, :null], do: {:list, iterate(v)}

  # any other primitive is iterated through its wrapper's `Symbol.iterator`
  def iter_source(v) do
    case get(v, {:symbol, :iterator, "Symbol.iterator"}) do
      f when is_tuple(f) ->
        unless function?(f), do: throw_error("TypeError", "#{to_str(v)} is not iterable")
        it = call(f, v, [])
        {:proto, it, get(it, "next")}

      _ ->
        throw_error("TypeError", "#{to_str(v)} is not iterable")
    end
  end

  defp proto_source(v) do
    case get(v, {:symbol, :iterator, "Symbol.iterator"}) do
      f when is_tuple(f) ->
        unless function?(f), do: throw_error("TypeError", "object is not iterable")
        it = call(f, v, [])
        {:proto, it, get(it, "next")}

      _ ->
        throw_error("TypeError", "object is not iterable")
    end
  end

  @doc false
  # the source of a `for … of` loop: an array or a collection changed by the body is seen
  # changing, so an array is read by index as the loop goes and a Map or Set is pulled
  def for_of_source({:obj, id} = v) do
    o = deref(id)

    cond do
      o.class == :array and array_iteration_pristine?(v) ->
        {:list, Stream.unfold(0, fn i -> for_of_step(id, v, i) end)}

      o.class in [:map, :set] ->
        proto_source(v)

      true ->
        iter_source(v)
    end
  end

  def for_of_source(v), do: iter_source(v)

  # One step of a for-of loop over the array `v` at `id`: `{element, next index}`, or nil
  # after the last element. The record is read again at each step, so the loop sees a body
  # that changes the array. For an array that is not an arguments object, the `length` is
  # `len` (no getter is possible), and an own data element is what the read of the key
  # gives, so the step reads `items` at the integer `i`, with no string key (fast path
  # `:iter`). A hole or an accessor goes to `get/2`. The test for an arguments object is
  # defence in depth today: an arguments object has an own `@@iterator`, so a for-of loop
  # over it does not get to this step.
  @compile {:inline, for_of_step: 3}
  defp for_of_step(id, v, i) do
    if Fast.on?(:iter) do
      case deref(id) do
        %{class: :array, len: len, items: items} = a when not is_map_key(a, :arguments) ->
          if i < len do
            case items do
              %{^i => {:accessor, _, _}} -> {get(v, i * 1.0), i + 1}
              %{^i => x} -> Fast.shadow(id, {x, i + 1}, for_of_step_key(v, i))
              _ -> {get(v, i * 1.0), i + 1}
            end
          end

        _ ->
          for_of_step_key(v, i)
      end
    else
      for_of_step_key(v, i)
    end
  end

  # The step of `for_of_step/3` by the generic read: `length`, then the key as a string.
  defp for_of_step_key(v, i) do
    if i < Browser.JS.ArrayGeneric.len(v), do: {get(v, Integer.to_string(i)), i + 1}
  end

  @doc false
  # one step of an iterator: `{:ok, value}` or `:done`
  def iter_step(it, next) do
    r = call(next, it, [])

    unless match?({:obj, _}, r),
      do: throw_error("TypeError", "Iterator result is not an object")

    if truthy(get(r, "done")), do: :done, else: {:ok, get(r, "value")}
  end

  @doc false
  # leaves an iterator early: calls its `return` method. After a throw the error from `return`
  # is dropped in favour of the original one.
  def iter_close(it, after_throw?) do
    try do
      case get(it, "return") do
        m when m in [:undefined, :null] ->
          :ok

        f ->
          unless function?(f), do: throw_error("TypeError", "Iterator return is not a function")
          r = call(f, it, [])

          unless after_throw? or match?({:obj, _}, r),
            do: throw_error("TypeError", "Iterator return result is not an object")
      end
    catch
      {:js_error, _} when after_throw? -> :ok
    end
  end

  # The fifth element of the spec says where an item runs: `:fresh` makes a scope per item,
  # as a map-scope loop needs; a frameless `%Scope{}` (or `nil`) runs in `env`, a frame, and
  # resets the head's slots to the temporal dead zone for every item; `{:frame, fresh, cur,
  # fns}` runs each item in an item frame of a framed head (`exec_for_each_framed`), where
  # `cur` is the frame of the item before and `fns` the closure count from when it was made.
  defp proto_loop(it, next, {pat, mode, body, env, {:frame, fresh, cur, fns}}, labels) do
    step =
      try do
        iter_step(it, next)
      catch
        k, e ->
          leave_scope(cur, fns)
          :erlang.raise(k, e, __STACKTRACE__)
      end

    case step do
      :done ->
        leave_scope(cur, fns)

      {:ok, item} ->
        tick()
        {cur, fns} = item_frame(fresh, cur, fns)

        result =
          try do
            bind(pat, item, cur, mode)
            # (a pending call runs before the close of the iterator)
            run_tail(run_body(body, cur, labels, :fn), cur)
          catch
            # Only a throw arrives here. An error from `return()` does not replace it, and
            # a JS throw needs no stack trace.
            :throw, e ->
              leave_scope(cur, fns)
              iter_close(it, true)
              throw(e)

            kind, e ->
              leave_scope(cur, fns)
              iter_close(it, true)
              :erlang.raise(kind, e, __STACKTRACE__)
          end

        case result do
          :next ->
            proto_loop(it, next, {pat, mode, body, env, {:frame, fresh, cur, fns}}, labels)

          # A break, a continue to an outer label and a return are normal exits: an error
          # from `return()` replaces them, and its result must be an object.
          :break ->
            leave_scope(cur, fns)
            iter_close(it, false)
            :ok

          c ->
            leave_scope(cur, fns)
            iter_close(it, false)
            loop_exit(c)
        end
    end
  end

  defp proto_loop(it, next, {pat, mode, body, env, scope} = spec, labels) do
    case iter_step(it, next) do
      :done ->
        :ok

      {:ok, item} ->
        tick()

        iter_env =
          if scope == :fresh do
            new_scope(env)
          else
            reset_tdz(env, scope)
            env
          end

        result =
          try do
            bind(pat, item, iter_env, mode)
            # (a pending call runs before the close of the iterator)
            run_tail(run_body(body, iter_env, labels, loop_mode(scope)), iter_env)
          catch
            # Only a throw arrives here. An error from `return()` does not replace it, and
            # a JS throw needs no stack trace.
            :throw, e ->
              iter_close(it, true)
              throw(e)

            kind, e ->
              iter_close(it, true)
              :erlang.raise(kind, e, __STACKTRACE__)
          end

        case result do
          :next ->
            proto_loop(it, next, spec, labels)

          # A break, a continue to an outer label and a return are normal exits: an error
          # from `return()` replaces them, and its result must be an object.
          :break ->
            iter_close(it, false)
            :ok

          c ->
            iter_close(it, false)
            loop_exit(c)
        end
    end
  end

  # (the old path runs each item in a fresh map scope; a rewritten function passes its
  # frameless scope or `nil`)
  defp loop_mode(:fresh), do: :top
  defp loop_mode(_scope), do: :fn

  # anything with a `[Symbol.iterator]` method: call it and pull values until it is done
  @doc false
  # is iterating this array the built-in way (nobody replaced `Array.prototype[@@iterator]`,
  # the array iterator's `next`, or gave the array an iterator of its own)? Then its elements
  # can be read straight from the list.
  def array_iteration_pristine?({:obj, id}) do
    o = deref(id)
    key = {:symbol, :iterator, "Symbol.iterator"}

    o.class == :array and not Obj.has_own?(o, key) and o.proto == proto(:array) and
      Obj.own_value(deref(elem(proto(:array), 1)), key) == Process.get(:js_arr_values) and
      Obj.own_value(deref(elem(proto(:array_iterator), 1)), "next") == Process.get(:js_arr_next)
  end

  @doc false
  # the iteration protocol itself, with no shortcut for arrays (a patched iterator is seen)
  def iterate_protocol_list(v), do: iterate_protocol(v)

  defp iterate_protocol(v) do
    case get(v, {:symbol, :iterator, "Symbol.iterator"}) do
      f when is_tuple(f) ->
        if function?(f) do
          it = call(f, v, [])
          pull(it, get(it, "next"), [])
        else
          throw_error("TypeError", "object is not iterable")
        end

      _ ->
        throw_error("TypeError", "object is not iterable")
    end
  end

  @doc "The values of `v` iterated with an iterator method already looked up."
  def iterate_with(v, f) do
    it = call(f, v, [])
    pull(it, get(it, "next"), [])
  end

  defp pull(it, next, acc) do
    r = call(next, it, [])

    unless match?({:obj, _}, r),
      do: throw_error("TypeError", "Iterator result is not an object")

    if truthy(get(r, "done")) do
      Enum.reverse(acc)
    else
      tick()
      pull(it, next, [get(r, "value") | acc])
    end
  end

  # ── calling ────────────────────────────────────────────────

  def call({:obj, id}, this, args), do: call_obj(id, deref(id), this, args)

  def call(_, _, _), do: throw_error("TypeError", "value is not a function")

  # The call of the function object `o` at heap id `id`. The caller has read `o` already, so
  # a call site that tests the callee first (`ev/2` for a call) reads the heap only once.
  # (inline: `call/3` keeps the cost of one local call)
  @compile {:inline, call_obj: 4}
  defp call_obj(id, o, this, args) do
    case o do
      %{class_info: info} ->
        throw_error(
          "TypeError",
          "Class constructor #{info.name || ""} cannot be invoked without 'new'"
        )

      %{class: :function, fun: {:native, _, fun}} ->
        tick()
        fun.(this, args)

      %{class: :function, fun: {:closure, c}, generator: true, async: true} ->
        tick()
        Browser.JS.Async.call_async_generator({:obj, id}, with_hoist(id, c), this, args)

      %{class: :function, fun: {:closure, c}, generator: true} ->
        tick()
        Browser.JS.Async.call_generator({:obj, id}, with_hoist(id, c), this, args)

      %{class: :function, fun: {:closure, c}, async: true} ->
        tick()
        Browser.JS.Async.call_closure(id, with_hoist(id, c), this, args)

      %{class: :function, fun: {:closure, c}} ->
        tick()
        run_closure(id, c, this, args)

      _ ->
        throw_error("TypeError", "value is not a function")
    end
  end

  def construct(f, args, new_target \\ nil)

  def construct({:obj, id} = f, args, new_target) do
    unless constructor?(f), do: throw_error("TypeError", "value is not a constructor")

    nt = new_target || f

    case deref(id) do
      %{proxy: _} -> Browser.JS.Proxy.construct(f, args, nt)
      _ -> construct_bound(f, id, args, new_target, nt)
    end
  end

  def construct(_, _, _), do: throw_error("TypeError", "value is not a constructor")

  defp construct_bound(f, id, args, new_target, nt) do
    case Map.get(deref(id), :bound) do
      {target, bound_args} ->
        # a bound function constructs what it is bound to
        construct(
          target,
          bound_args ++ args,
          if(new_target in [nil, f], do: nil, else: new_target)
        )

      nil ->
        construct_plain(f, id, nt, new_target, args)
    end
  end

  @doc "IsConstructor: arrows, generators, async functions, methods and built-ins without a `prototype` are not."
  def constructor?({:obj, id} = f) do
    o = deref(id)

    function?(f) and
      case o do
        %{proxy_constructor: c} -> c
        %{proxy_ctor: true} -> true
        %{bound: {target, _}} -> constructor?(target)
        %{generator: true} -> false
        %{fun: {:closure, %{mode: m}}} when m in [:arrow, :arrow_expr] -> false
        %{fun: {:closure, %{name: {:method, _}}}} -> false
        %{fun: {:closure, _}, async: true} -> false
        %{fun: {:native, _, _}} -> Obj.has_own?(o, "prototype")
        _ -> true
      end
  end

  def constructor?(_), do: false

  defp builtin_prototype(%{fun: {:native, _, _}}, f) do
    case get(f, "prototype") do
      {:obj, _} = p -> p
      _ -> proto(:object)
    end
  end

  defp builtin_prototype(_, _), do: proto(:object)

  @late_proto ~w(Promise ArrayBuffer SharedArrayBuffer DataView Int8Array Uint8Array
    Uint8ClampedArray Int16Array Uint16Array Int32Array Uint32Array Float16Array Float32Array
    Float64Array BigInt64Array BigUint64Array)

  @doc """
  Called by a built-in constructor at the point where the spec reads `newTarget.prototype`
  (after the checks that come first): reads it now, and a throw there ends the construction.
  """
  def late_proto do
    case Process.get(:js_late_nt) do
      nil ->
        :ok

      nt ->
        Process.delete(:js_late_nt)

        case get(nt, "prototype") do
          {:obj, _} = p -> Process.put(:js_late_done, {:ok, p})
          _ -> Process.put(:js_late_done, {:ok, :none})
        end

        :ok
    end
  end

  defp construct_plain({:obj, _} = f, id, nt, new_target, args) do
    case Map.get(deref(id), :class_info) do
      nil ->
        # these built-ins read the prototype of the new target themselves, once their
        # arguments have been checked (see `late_proto/0`)
        late_name? = match?(%{fun: {:native, name, _}} when name in @late_proto, deref(id))
        late? = nt != f and late_name?
        if late_name? and not late?, do: Process.delete(:js_late_nt)

        proto =
          case if(late?, do: :undefined, else: get(nt, "prototype")) do
            {:obj, _} = p ->
              p

            # a built-in falls back to its own prototype, a plain function to Object.prototype
            # (the realm of a revoked proxy cannot be found)
            _ ->
              with {:obj, nid} <- nt,
                   %{proxy: :revoked} <- deref(nid),
                   do: throw_error("TypeError", "Cannot perform operation on a revoked proxy")

              builtin_prototype(deref(id), f)
          end

        if Map.get(deref(id), :no_new), do: throw_error("TypeError", "not a constructor")

        this = new_object([], proto)

        if late? do
          Process.delete(:js_late_done)
          Process.put(:js_late_nt, nt)
        end

        result =
          case deref(id) do
            %{fun: {:closure, _}, async: true} ->
              call(f, this, args)

            # (a rewritten function under `new` runs on a frame; a tail site inside it must
            # not leave the frame, so the constructor keeps its line in `Error.stack`)
            %{fun: {:closure, %{info: %Info{rewritten: true}} = c}} ->
              tick()
              run_frame(id, c, this, args, nt, :new)

            %{fun: {:closure, c}} ->
              tick()
              elem(run_closure_scope(with_hoist(id, c), this, args, [{:new_target, nt}]), 0)

            _ ->
              Process.put(:js_native_new, this)
              r = call(f, this, args)
              Process.delete(:js_native_new)
              r
          end

        proto =
          if late? do
            late = Process.delete(:js_late_done)
            Process.delete(:js_late_nt)

            case late do
              {:ok, :none} -> proto
              {:ok, p} -> p
              nil -> with({:obj, _} = p <- get(nt, "prototype"), do: p, else: (_ -> proto))
            end
          else
            proto
          end

        case result do
          {:obj, rid} = result ->
            # a built-in that makes its own object (Error, Array, an element) gets the
            # prototype of the class that extended it
            if new_target != nil and result != this, do: store(rid, %{deref(rid) | proto: proto})
            result

          _ ->
            this
        end

      info ->
        Browser.JS.Classes.construct(f, info, args, nt)
    end
  end

  def instance_of?(o, {:obj, _} = f) do
    case get(f, {:symbol, :hasInstance, "Symbol.hasInstance"}) do
      m when m in [:undefined, :null] ->
        unless function?(f),
          do: throw_error("TypeError", "Right-hand side of 'instanceof' is not callable")

        ordinary_has_instance(f, o)

      m ->
        truthy(call(m, f, [o]))
    end
  end

  def instance_of?(_, _),
    do: throw_error("TypeError", "Right-hand side of 'instanceof' is not an object")

  @doc "OrdinaryHasInstance(c, o)."
  def ordinary_has_instance(c, o) do
    cond do
      not function?(c) ->
        false

      match?(%{bound: {_, _}}, deref(elem(c, 1))) ->
        {target, _} = deref(elem(c, 1)).bound
        instance_of?(o, target)

      not match?({:obj, _}, o) ->
        false

      true ->
        case get(c, "prototype") do
          {:obj, _} = p -> walk_protos(o, p)
          _ -> throw_error("TypeError", "Function has non-object prototype in instanceof check")
        end
    end
  end

  defp walk_protos({:obj, _} = o, target) do
    case Browser.JS.Props.get_prototype_of(o) do
      {:obj, _} = p -> p == target or walk_protos(p, target)
      _ -> false
    end
  end

  @doc false
  def tick do
    n = pget(:js_steps) - 1
    if n < 0, do: throw(:js_limit)
    :erlang.put(:js_steps, n)
  end

  @doc false
  # the scope a function body runs in: `this`, the parameters, hoisted declarations
  def call_scope(c, this, args) do
    if @check and match?(%{info: %Info{rewritten: true}}, c),
      do: check_fail("a rewritten function on the old call path (call_scope)")

    {_, body_scope} = call_frame(c, this, args, [])
    body_scope
  end

  # The scopes of a call: the one the parameters live in and the one the body runs in (one and
  # the same unless a parameter has an initialiser, see `hoist_into_body/4`). The closure
  # comes through `with_hoist/2`, which worked out what the call must know. When every
  # parameter is a plain name, the scope is built as one map before it is stored: `this`,
  # the parameters, the hoisted `var` names, the lexical names and the function declarations.
  # Declaring them one at a time would read and write the heap entry once for each.
  defp call_frame(%{mode: :arrow_expr} = c, _this, args, extra) do
    # (an arrow with an expression body hoists nothing and has no `this` of its own)
    vars = if extra == [], do: %{}, else: Map.new(extra)

    if plain_params?(c.params) do
      scope = alloc(fn_scope(c, bind_plain(c.params, args, vars)))
      {scope, scope}
    else
      scope = alloc(fn_scope(c, vars))
      bind_params(c.params, args, scope)
      {scope, scope}
    end
  end

  defp call_frame(c, this, args, extra) do
    vars =
      if c.mode in [false, nil],
        do: %{this: sloppy_this(strict?(c), this), args: args, new_target: :undefined},
        else: %{}

    vars = if h = Map.get(c, :home), do: Map.put(vars, :home, h), else: vars
    vars = if extra == [], do: vars, else: Enum.into(extra, vars)
    vars = strict_marks(c, vars)
    {names, funs} = c.hoist

    if c.plain? do
      vars = bind_plain(c.params, args, vars)
      # `var arguments;` keeps the arguments object (it only names the binding again)
      args_obj? = c.args_var? and is_map_key(vars, :args) and not is_map_key(vars, "arguments")
      vars = put_new_all(vars, names, :undefined)
      vars = put_all(vars, c.lex, :tdz)

      scope =
        if funs == [] do
          alloc(fn_scope(c, vars))
        else
          # The declarations close over the scope, so its id comes first. When one of
          # them is rewritten, the entry is stored before the functions are made, because
          # `make_fn` reads the chain from the scope to find the root of a rewritten
          # function; the final entry with the functions replaces it.
          scope = reserve()
          if rewritten_funs?(funs), do: store(scope, fn_scope(c, vars))

          vars =
            Enum.reduce(funs, vars, fn {n, f}, m -> Map.put(m, n, make_fn(f, scope, false)) end)

          store(scope, fn_scope(c, vars))
          scope
        end

      if args_obj?, do: lazy_arguments(scope)
      {scope, scope}
    else
      scope = alloc(fn_scope(c, vars))
      bind_params(c.params, args, scope)
      {scope, hoist_into_body(scope, c, names, funs)}
    end
  end

  defp put_new_all(vars, [], _v), do: vars
  defp put_new_all(vars, [n | ns], v), do: put_new_all(Map.put_new(vars, n, v), ns, v)

  defp put_all(vars, [], _v), do: vars
  defp put_all(vars, [n | ns], v), do: put_all(Map.put(vars, n, v), ns, v)

  defp fn_scope(c, vars) do
    %{
      scope: true,
      fnscope: true,
      fid: Map.get(c, :fid),
      vars: vars,
      consts: MapSet.new(),
      parent: c.scope
    }
  end

  # plain parameters, bound in order: a missing argument is undefined, the last of equal names wins
  defp bind_plain([], _args, vars), do: vars

  defp bind_plain([{:id, name} | ps], [a | args], vars),
    do: bind_plain(ps, args, Map.put(vars, name, a))

  defp bind_plain([{:id, name} | ps], [], vars),
    do: bind_plain(ps, [], Map.put(vars, name, :undefined))

  # A parameter list with initialisers closes over a scope of its own: the body's `var`s and
  # functions live in a second scope that starts from the parameters' values. Without
  # initialisers one scope serves both.
  defp hoist_into_body(scope, c, names, funs) do
    lex = c.lex

    if names == [] and funs == [] and lex == [] do
      scope
    else
      if param_exprs?(c.params) do
        s = deref(scope)

        vars =
          Map.new(names, fn n ->
            case s.vars do
              %{^n => v} -> {n, v}
              _ -> {n, :undefined}
            end
          end)

        body =
          alloc(%{
            scope: true,
            fnscope: true,
            fid: Map.get(c, :fid),
            vars: strict_marks(c, vars),
            consts: MapSet.new(),
            parent: scope
          })

        apply_hoist(body, [], funs)
        for name <- lex, do: declare(body, name, :tdz)
        body
      else
        apply_hoist(scope, names, funs)
        for name <- lex, do: declare(scope, name, :tdz)
        scope
      end
    end
  end

  @doc false
  def param_exprs?(params), do: not plain_params?(params) and has_default?(params)

  defp has_default?({:default, _, _}), do: true
  defp has_default?(t) when is_tuple(t), do: t |> Tuple.to_list() |> has_default?()
  defp has_default?(l) when is_list(l), do: Enum.any?(l, &has_default?/1)
  defp has_default?(_), do: false

  # Drops a scope from the heap once its code has run, unless a closure was created since
  # `fns` was read (`make_fn` counts them): only a closure can keep a scope alive past its code.
  defp free_scope(scope, fns) do
    if pget(:js_fns) == fns, do: free(scope)

    :ok
  end

  # A call's scope can only outlive the call through a closure created inside it (a function,
  # method, class or arrow all go through `make_fn`, which counts them). When none was, the
  # scope is garbage on return: dropping it keeps the heap from growing with every call.
  # the closure decides: a function the resolver rewrote runs on a tuple frame
  defp run_closure(id, %{info: %Info{rewritten: true}} = c, this, args),
    do: run_frame(id, c, this, args, :undefined, :call)

  defp run_closure(id, c, this, args) do
    c = with_hoist(id, c)
    before = pget(:js_fns)
    {result, scope} = run_closure_scope(c, this, args, [])
    free_scope(scope, before)

    case result do
      {:tail, f, this, args} -> tail_loop(f, this, args)
      _ -> result
    end
  end

  # A strict function's `return f(x)` hands the call back here instead of nesting it, so a
  # chain of tail calls runs in constant stack depth.
  defp tail_loop({:obj, id} = f, this, args) do
    case deref(id) do
      %{class: :function, fun: {:closure, %{info: %Info{rewritten: true}} = c}} = o
      when not is_map_key(o, :generator) and not is_map_key(o, :async) and
             not is_map_key(o, :class_info) ->
        tick()
        run_frame(id, c, this, args, :undefined, :call)

      %{class: :function, fun: {:closure, c}} = o
      when not is_map_key(o, :generator) and not is_map_key(o, :async) and
             not is_map_key(o, :class_info) ->
        tick()
        c = with_hoist(id, c)
        before = pget(:js_fns)
        {result, scope} = run_closure_scope(c, this, args, [])
        free_scope(scope, before)

        case result do
          {:tail, f, this, args} -> tail_loop(f, this, args)
          _ -> result
        end

      _ ->
        call(f, this, args)
    end
  end

  defp tail_loop(f, this, args), do: call(f, this, args)

  # A pending tail call that must not leave this statement: the call runs here, inside the
  # protection of the statement (a `catch`, a `finally`, the close of an iterator or a
  # disposal), and the statement sees its value as a plain return. These run sites are
  # the places where the resolver marks every `return` as `:plain`, so only the old path
  # gives a `{:tail}` to them.
  @compile {:inline, run_tail: 2}
  defp run_tail({:tail, f, t, a}, env) do
    if @check, do: check_run_tail(env)
    {:ret, call(f, t, a)}
  end

  defp run_tail(c, _env), do: c

  @doc false
  # Check mode only (K3 of step 3): the frame path never needs a run site, because the
  # resolver marks every return under one as `:plain`. The env of both paths is a heap id,
  # so the test looks at the stored value: a frame is a tuple.
  def check_run_tail(env) do
    if is_integer(env) and is_tuple(:erlang.get(env)),
      do: check_fail("a pending tail call at a run site of the frame #{env}")

    :ok
  end

  @doc false
  # runs a function body, also handing back its scope (a constructor reads `this` from it);
  # `extra` are more variables for the scope
  def run_closure_scope(c, this, args, extra) do
    if @check and match?(%{info: %Info{rewritten: true}}, c),
      do: check_fail("a rewritten function on the old call path (run_closure_scope)")

    if @check,
      do: check_oracle(c.name, false, fn -> closure_scope(c, this, args, extra) end),
      else: closure_scope(c, this, args, extra)
  end

  # (the old call path of `run_closure_scope/4`, without the check-mode oracle)
  @compile {:inline, closure_scope: 4}
  defp closure_scope(c, this, args, extra) do
    below = :erlang.get(:js_stack)
    depth = depth_of(below)
    if depth >= @max_depth, do: throw_error("RangeError", "Maximum call stack size exceeded")
    pos = pget(:js_pos)
    # The old path pushes the same cell as `run_frame/6`, so both paths share one chain and
    # one depth (step 2f). The `after` block restores the chain and the position.
    :erlang.put(:js_stack, [{c.name, pos, depth + 1} | below])

    try do
      {scope, body_scope} = call_frame(c, this, args, extra)

      result =
        case c.mode do
          :arrow_expr ->
            ev(c.body, body_scope)

          _ ->
            case exec_fn(c.body, body_scope) do
              {:ret, v} ->
                v

              :ok ->
                :undefined

              # Only a strict function that is not a constructor gives the call back to
              # `tail_loop/3`. Any other function makes the call here, while its own cell
              # is on the chain, so its depth and its line in `Error.stack` stay.
              {:tail, f, t, a} = tc ->
                if extra == [] and strict?(c), do: tc, else: call(f, t, a)

              other ->
                bad_body_completion(other, c.name)
            end
        end

      {result, scope}
    after
      :erlang.put(:js_stack, below)
      :erlang.put(:js_pos, pos)
    end
  end

  # A call of a rewritten function (step 2b). The frame is one tuple
  # `{parent_id, info, chain, call_pos, root_id, params..., hidden..., template...}`. It is
  # built before the body runs. When the call ends, `leave/5` erases it, unless a closure
  # made during the call can hold its id. The resolver marked every return inside the
  # function, so a `{:tail}` completion comes only from a tail site. The function does not
  # tick: its callers tick as they do on the old path, so the step counts stay the same.
  #
  # The call stack (step 2f): `:js_stack` is a chain of cells, innermost first. A call
  # pushes `{name, call_pos, depth}`, and an async call pushes a hidden cell (see
  # `Browser.JS.Async.call_closure/4`). The depth of the current call is in the head cell,
  # so there is no separate counter. A call is refused with a RangeError when the depth
  # of its caller is `@max_depth`, before it pushes. In check mode the frame keeps its own
  # chain in element 3. `:js_stack` gets the chain just before the `try`. `stack_string/1`
  # makes the text of `Error.stack` from the chain only when an error needs it.
  #
  # `nt` is the value of `new.target`, and `mode` (step 2d) says how the call came:
  #
  # - `:call`: a tail call goes to `tail_loop` after the frame is gone.
  # - `:new`: a call through `new`. The callee of a tail site runs inside the frame, so
  #   the constructor keeps its line in `Error.stack`.
  # - `:ctor`: a derived class constructor. It runs as `:new` and gives back
  #   `{value, this}`: the `this` slot is read before the frame is freed, because
  #   `super()` writes it during the body.
  defp run_frame(id, c, this, args, nt, mode) do
    c = with_code(id, c)

    result =
      if @check,
        do: check_oracle(c.name, false, fn -> frame_call(id, c, this, args, nt, mode) end),
        else: frame_call(id, c, this, args, nt, mode)

    case result do
      {:tail, f, t, a} -> tail_loop(f, t, a)
      _ -> result
    end
  end

  # (the call of `run_frame/6` up to its tail call, without the check-mode oracle; a tail
  # call in mode `:call` runs after the frame and the oracle have left the stack)
  @compile {:inline, frame_call: 6}
  defp frame_call(id, c, this, args, nt, mode) do
    below = :erlang.get(:js_stack)
    depth = depth_of(below)
    if depth >= @max_depth, do: throw_error("RangeError", "Maximum call stack size exceeded")
    pos = pget(:js_pos)
    chain = [{c.name, pos, depth + 1} | below]
    info = c.info

    # Only check mode reads the chain in element 3 (C5). In a normal build the element
    # stays `nil`: a frame that a closure keeps would otherwise keep every cell of its
    # callers too, which the collector does not count.
    link = if @check, do: chain

    # A compiled function can have a frame maker (step 5, `Browser.JS.Compile`), which
    # knows the shape of the frame and gives the same tuple as `frame_slots/5`. Check mode
    # uses the maker too, and compares its tuple with the tuple of `frame_slots/5` (S6).
    tuple =
      case c do
        %{mk: mk} when mk != nil ->
          tuple = mk.(c.scope, link, pos, c.root, this, args)
          if @check, do: check_maker(tuple, c, id, this, args, nt)
          tuple

        _ ->
          List.to_tuple([c.scope, info, link, pos, c.root | frame_slots(c, id, this, args, nt)])
      end

    if @check, do: check_frame(tuple, info, id, mode)
    frame = alloc(tuple)
    # A level 2 frame can outlive its call: the closures made in it (also in a parameter
    # default, so the count is read before the parameters are bound) hold its id. The
    # closure count decides, as `free_scope/2` does on the old path. A leaf (`free:
    # :always`) makes no closure and skips the read.
    fns = if info.free == :counter, do: :erlang.get(:js_fns)
    # The chain goes in last, just before the `try`, so that no throw can leave it pushed.
    :erlang.put(:js_stack, chain)

    # One `try` covers the parameters and the body. A return and a tail call are
    # completions (step 3), so only a JS throw, the step limit or an engine error comes to
    # the `catch`. The `try` stays, because it costs no time when nothing is thrown (the
    # step 3 design, section 4) and it leaves the frame on every throw.
    result =
      try do
        if info.params != :plain, do: bind_params_list(c.params, args, frame)
        enter_body(frame, info, id)
        if @check, do: check_hoisted(frame, info)

        case body_value(c, frame) do
          # A plain call gives the pending call back after `leave/5`. `run_frame/6` then
          # calls `tail_loop/3`, so the Elixir stack and the chain do not grow.
          {:tail, _, _, _} = t when mode == :call ->
            if @check, do: check_tail_sites(info, mode)
            t

          # Under `new` the callee runs here, inside the frame and this `try`. The
          # constructor keeps its line in `Error.stack`, and a throw from the callee
          # leaves the frame through the `catch` below.
          {:tail, f, t, a} ->
            if @check, do: check_tail_sites(info, mode)
            ctor_value(mode, call(f, t, a), frame, info)

          v ->
            ctor_value(mode, v, frame, info)
        end
      catch
        # A JS throw, the step limit or an engine error leaves the frame here. The value
        # is thrown again, so the cost is the same as the rethrow of an `after` block.
        :throw, v ->
          leave(frame, info, fns, below, pos)
          throw(v)

        kind, reason ->
          leave(frame, info, fns, below, pos)
          :erlang.raise(kind, reason, __STACKTRACE__)
      end

    leave(frame, info, fns, below, pos)
    result
  end

  # Check mode only (S6 of step 5): the tuple of a frame maker equals the tuple that the
  # frame builder of the tree makes for the same call. The builder gets the value of the
  # `this` slot of the maker's tuple, because a sloppy `this` that is a primitive boxes
  # into a new object, and a second box would change the heap ids. The boxing of a
  # sloppy `this` gives an object, and an object stays as it is, so the test still sees a
  # maker that does not box.
  defp check_maker(tuple, c, id, this, args, nt) do
    info = c.info

    this =
      case info.hidden do
        [:this] -> :erlang.element(6 + info.nparams, tuple)
        _ -> this
      end

    tree =
      List.to_tuple([
        c.scope,
        info,
        :erlang.element(3, tuple),
        :erlang.element(4, tuple),
        c.root | frame_slots(c, id, this, args, nt)
      ])

    if tree != tuple,
      do:
        check_fail(
          "the frame maker of #{check_name(info)} gives #{inspect(tuple)}, not #{inspect(tree)}"
        )

    :ok
  end

  # The closure record with its compiled code (step 5). Every entry to a sync frame
  # (`run_closure/4`, `tail_loop/3`, `new` and the class constructors, and the call fast
  # path of `ev/2`) comes through `run_frame/6`, so the first call of a function object
  # is found here: its record has no `code` key yet. `nil` code means that the function
  # does not compile, and the tree walker runs it.
  @compile {:inline, with_code: 2}
  defp with_code(_id, %{code: _} = c), do: c

  # (with the switch off, the record stays as it is, so that `JS_COMPILE=0` does the work
  # of the tree walker only and is a true baseline for the A/B runs)
  defp with_code(id, c) do
    if :erlang.get(:js_compile) == true, do: first_call(id, c), else: c
  end

  # The first call of a function object: the code comes from the cache or the compiler,
  # and goes into the closure record in the heap, so that the next calls find it there.
  # The record is read again, because the call that got `c` can have changed the object
  # (a `home` or a property) since. The body of a function object never changes, so the
  # code of `c` is the code of the record.
  defp first_call(id, c) do
    {code, mk} =
      case Browser.JS.Compile.code(c) do
        nil -> {nil, nil}
        code_and_maker -> code_and_maker
      end

    case :erlang.get(id) do
      %{fun: {:closure, now}} = o ->
        :erlang.put(id, %{o | fun: {:closure, Map.merge(now, %{code: code, mk: mk})}})

      _ ->
        :ok
    end

    Map.merge(c, %{code: code, mk: mk})
  end

  # The value of the body of a frame call: an arrow with an expression body gives the
  # value of the expression, and a body that ends without `return` gives `undefined`. A
  # tail site gives the pending call `{:tail, f, this, args}`, which no JS value can be.
  # Compiled code (step 5) gives the same value or completion as the tree.
  # (the two clauses repeat the `case` of the completion: an inline function inside an
  # inline function stays a call, which would cost one reduction per JS call)
  @compile {:inline, body_value: 2}
  defp body_value(%{code: code} = c, frame) when code != nil do
    case c.mode do
      :arrow_expr ->
        code.(frame)

      _ ->
        case code.(frame) do
          {:ret, v} -> v
          :ok -> :undefined
          {:tail, _, _, _} = t -> t
          other -> bad_body_completion(other, c.name)
        end
    end
  end

  defp body_value(c, frame) do
    case c.mode do
      :arrow_expr ->
        ev(c.body, frame)

      _ ->
        case fbody(c.body, frame) do
          {:ret, v} -> v
          :ok -> :undefined
          {:tail, _, _, _} = t -> t
          other -> bad_body_completion(other, c.name)
        end
    end
  end

  # Check mode only (K2 and K3 of step 3): a pending tail call comes only from a function
  # with a tail site, and never from a derived class constructor, which has none.
  defp check_tail_sites(info, mode) do
    if info.tail_sites == 0,
      do: check_fail("a tail call from #{check_name(info)}, which has no tail site")

    if mode == :ctor, do: check_fail("a tail call in the constructor #{check_name(info)}")
    :ok
  end

  # (K2 of step 3) A function body completes normally or with a return. A break or a
  # continue cannot leave it, because the parser refuses one without a target.
  defp bad_body_completion(c, name),
    do: check_fail("the body of #{inspect(name)} completed with #{inspect(c)}")

  # A derived class constructor gives back `{value, this}`. The `this` slot is read while
  # the frame is live, because `super()` writes it during the body.
  @compile {:inline, ctor_value: 4}
  defp ctor_value(:ctor, v, frame, info),
    do: {v, :erlang.element(:erlang.map_get(:this, info.slots), :erlang.get(frame))}

  defp ctor_value(_mode, v, _frame, _info), do: v

  # The end of a frame call: the frame is erased unless a closure made during the call can
  # hold its id, and the caller's chain and position come back. The chain holds no frame
  # id, so the order of the erase and the restore does not matter.
  @compile {:inline, leave: 5}
  defp leave(frame, info, fns, below, pos) do
    # (the argument map test stays here, so a frame without one pays only `free/1`)
    if fns == nil or :erlang.get(:js_fns) == fns,
      do: if(info.argmap == nil, do: free(frame), else: free_frame(frame, info))

    :erlang.put(:js_stack, below)
    :erlang.put(:js_pos, pos)
  end

  @doc false
  # The frame call of a rewritten class constructor, for `Classes.construct/4`: `mode` is
  # `:new` for a base class and `:ctor` for a derived class (see `run_frame/6`).
  def run_class_frame(id, c, this, args, nt, mode) when mode in [:new, :ctor],
    do: run_frame(id, c, this, args, nt, mode)

  @doc false
  # The frame of an async function, an async arrow, a generator or an async generator (step
  # 2e). It is built as `run_frame/6` builds a frame, but the body does not run here: the CPS
  # evaluator in `Browser.JS.Async` runs it later and can suspend it. So nothing here frees
  # the frame, except a throw from a parameter, after which no body code can run.
  # `frame_done/2` frees it when the body has ended. The entry does not push a cell on
  # `:js_stack`, and element 3 of the frame is `nil`, because the body can run again after
  # the call has returned, under another chain. `Async.call_closure/4` pushes a hidden cell
  # for the sync part of an async call, so that the call counts for the depth (step 2f).
  # Returns the frame id and the closure count at entry.
  def enter_frame(id, c, this, args) do
    info = c.info

    t =
      List.to_tuple([
        c.scope,
        info,
        nil,
        :erlang.get(:js_pos),
        c.root | frame_slots(c, id, this, args, :undefined)
      ])

    if @check, do: check_frame(t, info, id, :suspend)
    frame = alloc(t)
    # The count is read before the defaults run, because a default can make a closure.
    fns = :erlang.get(:js_fns)

    try do
      if info.params != :plain, do: bind_params_list(c.params, args, frame)
      enter_body(frame, info, id)
      if @check, do: check_hoisted(frame, info)
    catch
      k, e ->
        frame_done(frame, fns)
        :erlang.raise(k, e, __STACKTRACE__)
    end

    {frame, fns}
  end

  @doc false
  # The body of a frame from `enter_frame/4` has ended, so no continuation of it can run
  # again, and only a closure can still hold the frame. The frame is freed when the
  # function makes no closures, or when no closure was made since the entry (the counter
  # rule of step 2c). In all other cases the collector takes it later, as it takes a call
  # scope of the old path.
  def frame_done(frame, fns) do
    if @check, do: check_done_once(frame)
    info = :erlang.element(2, :erlang.get(frame))

    if not info.makes_closures or :erlang.get(:js_fns) == fns,
      do: if(info.argmap == nil, do: free(frame), else: free_frame(frame, info))

    :ok
  end

  @doc false
  # The scope of a statement in a CPS body in frame mode. A frameless scope (or `nil`) resets
  # its TDZ slots and makes its functions in `env`, and the statement runs in `env`. A
  # framed scope gets a block frame, which the statement then uses. The CPS evaluator never
  # frees a block frame early, because each abrupt continuation would then need cleanup
  # code; the collector takes it, as it takes the CPS map scopes of the old path.
  def cps_enter(env, sc) when frameless(sc) do
    enter_frameless(env, sc)
    env
  end

  def cps_enter(env, sc), do: enter_scope(env, sc)

  @doc false
  # The binding of a `using` declaration in a CPS body in frame mode: the slot of the frame
  # takes the value, because a frame cannot take a new name (`declare/4`).
  def using_bind(env, {:slot, 0, i, _name}, v), do: slot_put(env, i, v)

  @doc false
  # Check mode: a CPS body resumes on a frame that is live and whose body has not ended.
  # `nil` is the frame of an old-path body or of a small context with no frame.
  def check_resume(nil), do: :ok

  def check_resume(frame) do
    if @check do
      check_live(frame)

      if :erlang.get({:js_cps_done, frame}) == true,
        do: check_fail("a resume after frame_done of #{check_name(frame_rec(frame))}")
    end

    :ok
  end

  # The record of a frame gives its name to a check-mode message. A tombstone has no
  # record, so it gives a placeholder.
  defp frame_rec(frame) do
    case :erlang.get(frame) do
      f when is_tuple(f) and tuple_size(f) >= 5 -> :erlang.element(2, f)
      _ -> %{kind: :unknown}
    end
  end

  # Check mode: `frame_done/2` runs once for each frame. The process key stays after the
  # free, so a second call fails also when the first call kept the frame.
  defp check_done_once(frame) do
    check_live(frame)

    if :erlang.put({:js_cps_done, frame}, true) == true,
      do: check_fail("a second frame_done of #{check_name(frame_rec(frame))}")
  end

  # Frees a function frame on return. A frame that built a mapped arguments object first
  # detaches the object: it takes away `mapped` and `map_scope`, because `put` tests the
  # first and `sync_param` reads the second. Nobody can see the detach. Without a closure
  # no code can read a parameter after the return, and the object's `items` already hold
  # the values of the mapped parameters. Only a sloppy function with plain parameters has
  # an `argmap`, so every other frame pays one clause match.
  defp free_frame(frame, %Info{slots: %{args: i}}) do
    case :erlang.element(i, :erlang.get(frame)) do
      {:mapped, aid} ->
        if @check, do: check_args_alias(frame)
        o = deref(aid)
        store(aid, o |> Map.delete(:mapped) |> Map.delete(:map_scope))

      _ ->
        :ok
    end

    free(frame)
  end

  # The slots of a frame, from position 6: the parameters, the hidden slots, the template.
  # Plain parameters take the arguments by position (missing ones are `undefined`, extra
  # ones are dropped). Pattern parameters start as `undefined`, parameters with
  # initializers as `:tdz`; `bind_params_list/3` fills them.
  defp frame_slots(c, id, this, args, nt) do
    info = c.info
    rest = hidden_slots(info.hidden, info, c, id, this, args, nt, info.template)

    case info.params do
      :plain -> plain_slots(args, info.nparams, rest)
      :patterns -> List.duplicate(:undefined, c.nnames) ++ rest
      :exprs -> List.duplicate(:tdz, c.nnames) ++ rest
    end
  end

  # It is public because the frame makers of the closure compiler (`Browser.JS.Compile`)
  # call it.
  @doc false
  def plain_slots(_args, 0, rest), do: rest
  def plain_slots([a | args], n, rest), do: [a | plain_slots(args, n - 1, rest)]
  def plain_slots([], n, rest), do: [:undefined | plain_slots([], n - 1, rest)]

  # The values of the hidden slots at entry, in the order of `info.hidden`:
  #
  # - `:this`: the receiver, boxed or replaced by the global `this` in sloppy code. A
  #   derived constructor gets `:uninit_this`, which passes, because class code is strict.
  # - `:args`: the argument list. The arguments object is built from it, and a mapped
  #   build replaces it with `{:mapped, aid}` (see `build_arguments/3`).
  # - `:arguments`: `{:unbuilt, id}`. The object is built at the first read, and `id` gives
  #   its `callee`.
  # - `:new_target`: `nt`, which is `undefined` for every call that is not a `new`.
  # - `:home`: the home object of a method, which `set_home` wrote into the closure.
  # - `:ctor_fn` and `:self`: the function that runs. For a class constructor this is the
  #   class, because `Classes.construct` runs the class's own closure.
  defp hidden_slots([], _info, _c, _id, _this, _args, _nt, rest), do: rest

  defp hidden_slots([:this | hs], info, c, id, this, args, nt, rest),
    do: [sloppy_this(info.strict, this) | hidden_slots(hs, info, c, id, this, args, nt, rest)]

  defp hidden_slots([:self | hs], info, c, id, this, args, nt, rest),
    do: [{:obj, id} | hidden_slots(hs, info, c, id, this, args, nt, rest)]

  defp hidden_slots([:args | hs], info, c, id, this, args, nt, rest),
    do: [args | hidden_slots(hs, info, c, id, this, args, nt, rest)]

  defp hidden_slots([:arguments | hs], info, c, id, this, args, nt, rest),
    do: [{:unbuilt, id} | hidden_slots(hs, info, c, id, this, args, nt, rest)]

  defp hidden_slots([:new_target | hs], info, c, id, this, args, nt, rest),
    do: [nt | hidden_slots(hs, info, c, id, this, args, nt, rest)]

  defp hidden_slots([:home | hs], info, c, id, this, args, nt, rest),
    do: [Map.get(c, :home, :undefined) | hidden_slots(hs, info, c, id, this, args, nt, rest)]

  defp hidden_slots([:ctor_fn | hs], info, c, id, this, args, nt, rest),
    do: [{:obj, id} | hidden_slots(hs, info, c, id, this, args, nt, rest)]

  # `named?: false` makes no self-name scope: a class constructor gets its name
  # from the class scope, so an anonymous class expression must not bind the
  # name it inferred (`let X = class { constructor() { X = 5 } }` writes the `let`).
  @doc false
  def make_function(node, env, named? \\ true), do: make_fn(node, env, named?)

  @doc false
  # sets a field of a function's closure (the `home` object of a method)
  def set_home({:obj, id}, home) do
    o = deref(id)

    case o.fun do
      {:closure, c} -> store(id, %{o | fun: {:closure, Map.put(c, :home, home)}})
      _ -> :ok
    end
  end

  @doc false
  def lookup_scoped(env, name), do: lookup_var(env, name)

  @doc false
  # (the by-name write, for the unit tests of the frame walkers)
  def assign_scoped(env, name, v), do: assign_var(env, name, v)

  # an unresolved name is an element with that id when the page has one, else a ReferenceError
  defp named_global(name) do
    case Browser.JS.DOM.named_element(name) do
      {:ok, v} -> v
      :error -> throw_error("ReferenceError", "#{name} is not defined")
    end
  end

  @doc false
  # the key a private name stands for in the class it is declared in
  def private_key(name, env) do
    case lookup_var(env, {:priv, name}) do
      {:ok, ref} ->
        {:private, ref}

      :error ->
        throw_error(
          "SyntaxError",
          "Private field '#' + #{name} must be declared in an enclosing class"
        )
    end
  end

  @doc false
  # the scope, along the chain from `env`, that holds the variable `name`
  def scope_of(nil, _), do: nil

  def scope_of(env, name) do
    case deref(env) do
      # (a freed frame in check mode: the `{:gref}` landing check stops its walk there)
      {:js_freed, _} ->
        nil

      f when is_tuple(f) ->
        if is_map_key(:erlang.element(2, f).slots, name),
          do: env,
          else: scope_of(:erlang.element(1, f), name)

      s ->
        if Map.has_key?(s.vars, name), do: env, else: scope_of(s.parent, name)
    end
  end

  # a generator or async function's `prototype` is its own (or none), never the one its kind's
  # prototype object carries
  defp function_get(id, o, "prototype")
       when (is_map_key(o, :generator) or is_map_key(o, :async)) and
              not Obj.has_own?(o, "prototype"),
       do: function_prop(id, o, "prototype")

  # the lazily made own `prototype` shadows anything the prototype chain has
  defp function_get(id, o, "prototype") when not Obj.has_own?(o, "prototype") do
    case function_prop(id, o, "prototype") do
      :undefined -> function_get_chain(id, o, "prototype")
      p -> p
    end
  end

  defp function_get(id, o, key), do: function_get_chain(id, o, key)

  defp function_get_chain(id, o, key) do
    case lookup(o, key, {:obj, id}) do
      :undefined ->
        cond do
          # a deleted own `length` or `name` shows what the prototype chain has
          key in ["name", "length"] and key in Map.get(o, :gone, []) ->
            case o.proto do
              {:obj, _} = p -> get(p, key)
              _ -> :undefined
            end

          # `f.prototype = undefined` is a value, not a missing property
          key in ["name", "length", "prototype"] and Obj.has_own?(o, key) ->
            :undefined

          true ->
            function_prop(id, o, key)
        end

      v ->
        v
    end
  end

  @doc "A property read with a given `this` for getters (`super.x`)."
  def get_with_receiver({:obj, id} = obj, key, receiver) do
    case deref(id) do
      %{proxy: _} ->
        Browser.JS.Proxy.get(obj, to_key(key), receiver)

      %{class: class} = o when class in [:array, :function, :host] ->
        if receiver == obj or class == :host or (not is_binary(key) and not is_tuple(key)) do
          get(obj, key)
        else
          key = to_key(key)

          case Browser.JS.Props.own_state(obj, key) do
            nil ->
              case o.proto do
                {:obj, _} = p -> get_with_receiver(p, key, receiver)
                _ -> :undefined
              end

            {:data, v, _, _, _} ->
              v

            {:accessor, g, _, _, _} ->
              if function?(g), do: call(g, receiver, []), else: :undefined
          end
        end

      %{prim: str} = o when is_binary(str) and receiver != obj and is_binary(key) ->
        # a String wrapper's index and `length` properties are its own
        case Browser.JS.Props.own_state(obj, key) do
          nil -> lookup(o, key, receiver)
          {:data, v, _, _, _} -> v
          _ -> lookup(o, key, receiver)
        end

      o ->
        lookup(o, to_key(key), receiver)
    end
  end

  def get_with_receiver(_, _, _), do: :undefined

  # a parameter list with initialisers gets a temporal dead zone: every name
  # reads as uninitialised until its own binding runs
  defp bind_params(params, args, scope) do
    if Enum.any?(params, &match?({:default, _, _}, &1)) do
      for p <- params, name <- pattern_names(p, []), do: declare(scope, name, :tdz)
      # eval code in a default expression cannot declare `arguments` (see `run_eval/3`)
      declare(scope, :in_params, true)
      bind_params_list(params, args, scope)
      s = deref(scope)
      store(scope, %{s | vars: Map.delete(s.vars, :in_params)})
    else
      bind_params_list(params, args, scope)
    end
  end

  defp bind_params_list([], _, _), do: :ok

  defp bind_params_list([{:rest, pat}], args, scope), do: bind(pat, new_array(args), scope, :let)

  defp bind_params_list([p | ps], args, scope) do
    {arg, rest} =
      case args do
        [a | r] -> {a, r}
        [] -> {:undefined, []}
      end

    bind(p, arg, scope, :let)
    bind_params_list(ps, rest, scope)
  end

  # generator, async and async generator functions do not inherit from Function.prototype directly
  defp kind_proto(id) do
    o = deref(id)

    key =
      case o do
        %{generator: true, async: true} -> :async_generator_function
        %{generator: true} -> :generator_function
        %{async: true} -> :async_function
      end

    if p = proto(key), do: store(id, %{o | proto: p})
    :ok
  end

  # true when a hoisted declaration of `funs` was rewritten by the resolver
  defp rewritten_funs?(funs) do
    Enum.any?(funs, fn {_, f} -> match?({:fn, _, _, _, _, %Info{rewritten: true}}, f) end)
  end

  defp make_fn(node, env), do: make_fn(node, env, true)

  # `named?`: a function expression's own name is a binding inside it (a declaration's is not)
  defp make_fn({:gen, fun}, env, named?) do
    {:obj, id} = f = make_fn(fun, env, named?)
    store(id, Map.put(deref(id), :generator, true))
    kind_proto(id)
    f
  end

  defp make_fn({:async, fun}, env, named?) do
    {:obj, id} = f = make_fn(fun, env, named?)
    store(id, Map.put(deref(id), :async, true))
    kind_proto(id)
    f
  end

  defp make_fn({:fn, name, params, body, mode, src}, env, named?) do
    # the resolver, when it ran, left its facts in the place of the source text
    {src, info} = Browser.JS.Resolve.unpack(src)
    rewritten? = match?(%Info{rewritten: true}, info)
    named? = named? and is_binary(name) and mode == false

    # (a self slot exists only for a named function expression; a parameter or a
    # declaration of the same name shadows the self name, which then has no slot)
    if @check, do: check_closure_env(env)

    if @check and rewritten? and info.self != nil and not named?,
      do: check_fail("self slot #{inspect(info.self)} of #{inspect(name)} without a self name")

    # A rewritten function keeps its own name in a slot of its frame (`info.self`), so it
    # must not get the self-name scope: one more map scope would shift every hop count.
    named? = named? and not rewritten?

    env =
      if named? do
        # a function expression can call itself by name
        s = new_scope(env)
        s
      else
        env
      end

    # The closure count only goes up: `run_frame/6`, block frames and `free_scope/2` free a
    # scope when the count did not change, so a write that lowers it would free a scope
    # that a closure still holds.
    :erlang.put(:js_fns, pget(:js_fns) + 1)

    closure =
      if rewritten? do
        # The frame of a call needs the root scope of the closure's own chain (the realm
        # of the function, not the current global) and the number of parameter name slots
        # (the frame size minus the header, the hidden slots and the template). Both are
        # computed once per function object here, not on every call.
        root = root_of(env)

        if @check and not match?(%{parent: nil}, :erlang.get(root)),
          do: check_fail("the root of #{inspect(name)} is #{inspect(root)}, no global scope")

        nnames = info.size - 5 - length(info.hidden) - length(info.template)

        # A function whose body compiled already (step 5) gives its code to each new
        # function object, so that the first call of the object does not read the cache.
        # The key and the value are those of `Browser.JS.Compile`. (each branch builds its
        # map at once: a merge would cost one more call per function object)
        case :erlang.get({:jsc, info.uid}) do
          {code, mk} ->
            %{
              name: name,
              params: params,
              body: body,
              mode: mode,
              scope: env,
              src: src,
              info: info,
              root: root,
              nnames: nnames,
              code: code,
              mk: mk
            }

          _ ->
            %{
              name: name,
              params: params,
              body: body,
              mode: mode,
              scope: env,
              src: src,
              info: info,
              root: root,
              nnames: nnames
            }
        end
      else
        %{name: name, params: params, body: body, mode: mode, scope: env, src: src, info: info}
      end

    fun =
      {:obj,
       alloc(Obj.record(class: :function, fun: {:closure, closure}, proto: proto(:function)))}

    if named? and env != nil do
      declare(env, name, fun)
      # the function's own name cannot be assigned to (sloppy code ignores the attempt)
      s = deref(env)
      store(env, %{s | consts: MapSet.put(s.consts, {:fname, name})})
    end

    fun
  end

  # The root of a scope chain: the scope whose parent is `nil`. A frame keeps its root in
  # its header. With no scope at all (`nil`) or an id that has no entry yet there is no
  # root to give.
  defp root_of(nil), do: nil

  defp root_of(id) do
    if @check, do: check_live(id)

    case :erlang.get(id) do
      f when is_tuple(f) -> :erlang.element(5, f)
      %{parent: nil} -> id
      %{parent: p} -> root_of(p)
      :undefined -> nil
    end
  end

  # strict functions mark their scope, so that eval code called from them is strict too
  defp strict_marks(%{strict?: true}, vars), do: Map.put(vars, :strict, true)
  defp strict_marks(_, vars), do: vars

  # A function that is not strict gets the global object for a `this` that is undefined or null
  # (a plain call): `(function () { this.x = 1 })()` sets a global. Without a global `this`
  # (no page) nothing changes. The first argument is the strictness of the function: a
  # rewritten closure never goes through `with_hoist`, so it has no `strict?` key to match.
  # It is public because the frame makers of the closure compiler (`Browser.JS.Compile`)
  # call it.
  @doc false
  def sloppy_this(true, this), do: this

  def sloppy_this(false, this) do
    cond do
      this in [:undefined, :null] ->
        case deref(global()) do
          %{vars: %{this: w}} -> w
          _ -> this
        end

      is_binary(this) or is_number(this) or is_boolean(this) or
        this in [:nan, :infinity, :neg_infinity] or
          (is_tuple(this) and elem(this, 0) in [:bigint, :symbol]) ->
        Browser.JS.Builtins.box(this)

      true ->
        this
    end
  end

  # true when the nearest function scope owns `:args` but not yet an `arguments` binding
  defp args_shadowed?(scope) when is_integer(scope) or is_reference(scope) or is_tuple(scope) do
    case deref(scope) do
      %{vars: %{"arguments" => _}} -> false
      %{vars: %{args: _}} -> true
      %{parent: nil} -> false
      %{parent: parent} -> args_shadowed?(parent)
      # (a frame: an arrow leaf under a function that owns `arguments` must keep walking)
      f when is_tuple(f) -> frame_args_shadowed?(f)
      _ -> false
    end
  end

  defp args_shadowed?(_), do: false

  defp frame_args_shadowed?(f) do
    case :erlang.element(2, f).slots do
      %{"arguments" => _} -> false
      %{args: _} -> true
      _ -> args_shadowed?(:erlang.element(1, f))
    end
  end

  # It is public because the closure compiler (`Browser.JS.Compile`) calls it.
  @doc false
  def ev_id({:id, name}, env) do
    case lookup_var(env, name) do
      {:ok, :undefined} ->
        # a binding that left the `with` object while its unscopables were read is a missing
        # reference in strict code
        if Process.delete(:js_with_gone) == name and lookup_var(env, :strict) == {:ok, true},
          do: throw_error("ReferenceError", "#{name} is not defined"),
          else: :undefined

      {:ok, :tdz} ->
        throw_error("ReferenceError", "Cannot access '#{name}' before initialization")

      {:ok, v} ->
        v

      :error when name == "arguments" ->
        lazy_arguments(env)

      :error ->
        named_global(name)
    end
  end

  # `arguments` is only built when a function body asks for it: an object of its own with
  # the indices, `length`, `callee` (a poison pill in strict code) and the array iterator
  defp lazy_arguments(env) do
    case lookup_var(env, :args) do
      {:ok, args} ->
        owner = scope_with(env, :args)
        scope = deref(owner)

        # (a frame owner keeps the object in a slot of its own, which `build_arguments/3`
        # fills; resolver rule R2 keeps this path away from frames)
        if @check and is_tuple(scope),
          do:
            check_fail("lazy_arguments on the frame of #{check_name(:erlang.element(2, scope))}")

        callee =
          arguments_callee(
            Map.has_key?(scope.vars, :strict) or not simple_params?(scope),
            Map.get(scope, :fid)
          )

        {:obj, aid} = a = arguments_object(args, callee)
        map_arguments(aid, owner, scope, args)
        declare(owner, "arguments", a)
        a

      :error ->
        throw_error("ReferenceError", "arguments is not defined")
    end
  end

  # The `callee` of an arguments object: the thrower accessor for strict code and for a
  # parameter list that is not plain, else the function itself, or nothing when the
  # function is not known. Without a thrower (no realm set up) the function is used.
  defp arguments_callee(poison?, fid) do
    thrower = :erlang.get(:js_throw_type_error)

    cond do
      poison? and thrower != :undefined -> {:thrower, thrower}
      is_integer(fid) -> {:obj, fid}
      true -> nil
    end
  end

  # The unmapped part of an arguments object, which both paths build: an array of the
  # arguments with `Object.prototype`, and its hidden own properties in the order of the
  # spec: `length`, `Symbol.iterator`, then `callee`. The record is made in one write, and
  # only the thrower accessor of `callee` is a second write.
  defp arguments_object(args, callee) do
    len = length(args)

    o =
      Obj.record(
        class: :array,
        items: items_map(args),
        len: len,
        proto: proto(:object),
        arguments: true
      )
      |> Obj.put_hidden("length", len * 1.0)
      |> Obj.put_hidden({:symbol, :iterator, "Symbol.iterator"}, get(proto(:array), "values"))

    case callee do
      {:thrower, thrower} ->
        a = {:obj, alloc(o)}

        Browser.JS.Props.define_accessor(a, "callee",
          get: thrower,
          set: thrower,
          enumerable: false,
          configurable: false
        )

        a

      {:obj, _} = f ->
        {:obj, alloc(Obj.put_hidden(o, "callee", f))}

      nil ->
        {:obj, alloc(o)}
    end
  end

  # Builds the arguments object of a frame (step 2d) into slot `i` and gives it back. `fid`
  # is the id of the function, for `callee`. The frame is read once.
  #
  # A sloppy function with plain parameters (`argmap`) maps each parameter whose index is
  # below the argument count. `argmap` gives a duplicate name to its last position
  # already. A mapped element takes the current value of its parameter, so a write before
  # the build shows. The object then records `mapped` (index to name, as the old path does)
  # and `map_scope` (the frame), and the `:args` slot takes `{:mapped, aid}`, so that a
  # write to a parameter finds the object (see `sync_mapped/3`). The object and the two
  # slots are written with one `put` of the frame.
  defp build_arguments(frame, i, fid) do
    f = :erlang.get(frame)
    info = :erlang.element(2, f)
    args_slot = :erlang.map_get(:args, info.slots)
    args = :erlang.element(args_slot, f)

    if @check and not is_list(args),
      do: check_fail("a second build of arguments in #{check_name(info)}")

    callee = arguments_callee(info.strict or info.params != :plain, fid)
    {:obj, aid} = a = arguments_object(args, callee)
    mapped = argument_map(info.argmap, length(args))

    if mapped == %{} do
      slot_put(frame, i, a)
    else
      o = deref(aid)

      items =
        Enum.reduce(mapped, o.items, fn {k, _}, acc ->
          Map.put(acc, k, :erlang.element(@frame_base + k, f))
        end)

      store(
        aid,
        o |> Map.put(:items, items) |> Map.put(:mapped, mapped) |> Map.put(:map_scope, frame)
      )

      t = :erlang.get(frame)

      :erlang.put(
        frame,
        :erlang.setelement(args_slot, :erlang.setelement(i, t, a), {:mapped, aid})
      )

      if @check, do: check_args_alias(frame)
    end

    a
  end

  # index to name for the mapped parameters: only the indices below the argument count
  defp argument_map(nil, _argc), do: %{}

  defp argument_map(argmap, argc),
    do: for({name, k} <- argmap, k < argc, into: %{}, do: {k, name})

  # A sloppy function with plain parameters maps `arguments[i]` to the i-th parameter. The
  # last of equal names owns the mapping, and only indices below the argument count map.
  # a function with defaults, a rest parameter or patterns gets an unmapped arguments object
  defp simple_params?(scope) do
    case Map.get(scope, :fid) do
      fid when is_integer(fid) ->
        case deref(fid) do
          %{fun: {:closure, %{params: params}}} -> plain_params?(params)
          _ -> true
        end

      _ ->
        true
    end
  end

  defp map_arguments(aid, owner, scope, args) do
    with false <- Map.has_key?(scope.vars, :strict),
         fid when is_integer(fid) <- Map.get(scope, :fid),
         %{fun: {:closure, %{params: params}}} <- deref(fid),
         true <- params != [] and plain_params?(params) do
      count = length(args)

      {mapped, names} =
        params
        |> Enum.with_index()
        |> Enum.reverse()
        |> Enum.reduce({%{}, %{}}, fn {{:id, name}, idx}, {m, ns} ->
          cond do
            Map.has_key?(ns, name) -> {m, ns}
            idx < count -> {Map.put(m, idx, name), Map.put(ns, name, idx)}
            true -> {m, Map.put(ns, name, :none)}
          end
        end)

      names = Map.reject(names, fn {_, v} -> v == :none end)

      if mapped != %{} do
        o = deref(aid)

        items =
          Enum.reduce(mapped, o.items, fn {idx, name}, acc ->
            case scope.vars do
              %{^name => v} -> Map.put(acc, idx, v)
              _ -> acc
            end
          end)

        store(
          aid,
          o |> Map.put(:items, items) |> Map.put(:mapped, mapped) |> Map.put(:map_scope, owner)
        )

        declare(owner, :argmap, {aid, names})
      end
    else
      _ -> :ok
    end
  end

  defp scope_with(scope, name) do
    case deref(scope) do
      f when is_tuple(f) ->
        if is_map_key(:erlang.element(2, f).slots, name),
          do: scope,
          else: scope_with(:erlang.element(1, f), name)

      s ->
        if Map.has_key?(s.vars, name), do: scope, else: scope_with(s.parent, name)
    end
  end

  # ── hoisting ───────────────────────────────────────────────

  defp hoist_vars(stmts, scope), do: apply_hoist(scope, hoisted_names(stmts), [])

  # declares `var` names (undefined unless already a parameter) and function declarations
  defp apply_hoist(scope, names, funs) do
    if names != [] do
      s = deref(scope)

      # `var arguments;` keeps the arguments object (it only names the binding again)
      if "arguments" in names and is_map_key(s.vars, :args) and
           not is_map_key(s.vars, "arguments") and
           not Enum.any?(funs, &(elem(&1, 0) == "arguments")),
         do: lazy_arguments(scope)

      s = deref(scope)
      vars = Enum.reduce(names, s.vars, fn n, m -> Map.put_new(m, n, :undefined) end)
      store(scope, %{s | vars: vars})
    end

    for {name, fun} <- funs, do: declare(scope, name, make_fn(fun, scope, false))
    :ok
  end

  @doc false
  # What a call must know about a function is worked out from its syntax once per function
  # object and kept in its closure: looking at the body on every call costs time proportional
  # to its size. `hoist` holds the `var` names and the function declarations of the body,
  # `lex` its `let`, `const` and class names, `strict?` whether it begins with "use strict"
  # (the parser puts the directive in every function inside strict code), whether
  # every parameter is a plain name (`plain?`) and whether the body declares `var arguments`.
  # An arrow with an expression body has none of this to know, so its closure stays as it is
  # (`call_frame/4` has a clause for it): the write back to the heap would cost more than it
  # saves for an arrow that is made and called once, as callbacks are.
  # A rewritten closure runs on a frame that the resolver laid out, so nothing here applies:
  # `hoisted_names` over slot forms would even be wrong.
  def with_hoist(_id, %{info: %Info{rewritten: true}} = c), do: c
  def with_hoist(_id, %{hoist: _} = c), do: c
  def with_hoist(_id, %{mode: :arrow_expr} = c), do: c

  def with_hoist(id, c) do
    names = hoisted_names(c.body)
    funs = fundecls(c.body)

    c =
      Map.merge(c, %{
        fid: id,
        hoist: {names, funs},
        lex: for(stmt <- c.body, name <- lexical_names(stmt), do: name),
        strict?: match?([{:expr, {:str, "use strict"}} | _], c.body),
        plain?: plain_params?(c.params),
        args_var?: "arguments" in names and not Enum.any?(funs, &(elem(&1, 0) == "arguments"))
      })

    o = deref(id)
    store(id, %{o | fun: {:closure, c}})
    c
  end

  # every parameter a plain name: no default, pattern or rest parameter
  @doc false
  def plain_params?([{:id, _} | ps]), do: plain_params?(ps)
  def plain_params?([]), do: true
  def plain_params?(_), do: false

  defp strict?(%{strict?: strict?}), do: strict?
  defp strict?(_), do: false

  @doc false
  def fundecls(stmts) do
    Enum.flat_map(stmts, fn
      {:using, _, _, _, rest} -> fundecls(rest)
      stmt -> for {:fundecl, n, f} <- [unexport(stmt)], do: {n, f}
    end)
  end

  # the `var` names of a body, remembered: walking the syntax tree on every call is costly
  defp hoisted_names(stmts) do
    key = {:js_hoist, stmts}

    case pget(key) do
      nil ->
        names = stmts |> var_names([]) |> Enum.uniq()
        :erlang.put(key, names)
        names

      names ->
        names
    end
  end

  @doc false
  def var_names(stmts, acc) when is_list(stmts), do: Enum.reduce(stmts, acc, &var_names/2)

  def var_names({:var, :var, decls}, acc),
    do: Enum.reduce(decls, acc, fn {pat, _}, a -> pattern_names(pat, a) end)

  def var_names({:export, stmt}, acc), do: var_names(stmt, acc)
  def var_names({:using, _, _, _, rest}, acc), do: var_names(rest, acc)
  def var_names({:if, _, a, b}, acc), do: var_names(b, var_names(a, acc))
  def var_names({:for, init, _, _, body}, acc), do: var_names(body, var_names(init, acc))

  def var_names({k, :var, pat, _, body}, acc) when k in [:forin, :forof],
    do: var_names(body, pattern_names(pat, acc))

  def var_names({k, _, _, _, body}, acc) when k in [:forin, :forof], do: var_names(body, acc)
  def var_names({:while, _, body}, acc), do: var_names(body, acc)
  def var_names({:dowhile, body, _}, acc), do: var_names(body, acc)
  def var_names({:block, stmts}, acc), do: var_names(stmts, acc)
  def var_names({:with, _, body}, acc), do: var_names(body, acc)
  def var_names({:labeled, _, s}, acc), do: var_names(s, acc)
  def var_names({:try, b, _, h, f}, acc), do: var_names(f, var_names(h, var_names(b, acc)))

  def var_names({:switch, _, cases}, acc),
    do: Enum.reduce(cases, acc, fn {_, body}, a -> var_names(body, a) end)

  def var_names(_, acc), do: acc

  @doc false
  def pattern_names({:id, n}, acc), do: [n | acc]
  def pattern_names({:default, p, _}, acc), do: pattern_names(p, acc)
  def pattern_names({:rest, p}, acc), do: pattern_names(p, acc)
  def pattern_names({:arrpat, elems}, acc), do: Enum.reduce(elems, acc, &pattern_names/2)

  def pattern_names({:objpat, props, rest}, acc) do
    acc = Enum.reduce(props, acc, fn {_, p}, a -> pattern_names(p, a) end)
    if rest, do: pattern_names(rest, acc), else: acc
  end

  def pattern_names(_, acc), do: acc

  @doc false
  def hoist_functions(stmts, scope) do
    for stmt <- stmts do
      case unexport(stmt) do
        {:fundecl, name, fun} -> declare(scope, name, make_fn(fun, scope, false))
        {:using, _, _, _, rest} -> hoist_functions(rest, scope)
        {:var, kind, _} = d when kind in [:let, :const] -> declare_tdz(d, scope)
        _ -> :ok
      end
    end

    :ok
  end

  # a `let`/`const` name is in its temporal dead zone from the start of its scope
  defp declare_tdz(decl, scope) do
    names = lexical_names(decl)
    for name <- names, do: declare(scope, name, :tdz)

    # remembered so that a direct eval's `var` of the same name can be refused
    unless names == [] do
      sc = deref(scope)
      store(scope, Map.update(sc, :lex, MapSet.new(names), &MapSet.union(&1, MapSet.new(names))))
    end

    :ok
  end

  # does a block declare anything (a function, class, `let`, `const`, `using`) that is its own?
  defp scoped_block?([]), do: false

  defp scoped_block?([stmt | rest]) do
    case stmt do
      {:expr, _} -> scoped_block?(rest)
      {:fundecl, _, _} -> true
      {:var, kind, _} when kind in [:let, :const] -> true
      {:var, :var, _} -> scoped_block?(rest)
      {:using, _, _, _, _} -> true
      {:classdecl, _, _} -> true
      {:export, _} -> true
      {:export_default, _} -> true
      _ -> scoped_block?(rest)
    end
  end

  defp unexport({:export, stmt}), do: stmt
  defp unexport({:export_default, {:fundecl, _, _} = stmt}), do: stmt
  defp unexport(stmt), do: stmt

  # ── statements ─────────────────────────────────────────────

  @doc "Runs a whole program in the global scope; returns the completion value."
  def run_program({:program, stmts}, script? \\ false) do
    # Global code can run inside a JS call (the Function constructor, `$262.evalScript`).
    # It must not change the completion value of the code that called it, so the old value
    # comes back at the end. Since step 3 a rewritten function writes no completion value
    # that could hide such a leak.
    caller_last = :erlang.put(:js_last, :undefined)
    scope = global()

    if script? do
      declare_globals(stmts)
      g = deref(scope)

      vars =
        if match?([{:expr, {:str, "use strict"}} | _], stmts),
          do: Map.put(g.vars, :strict, true),
          else: Map.delete(g.vars, :strict)

      store(scope, %{g | vars: vars})
    end

    hoist_vars(stmts, scope)
    hoist_functions(stmts, scope)
    top_completion(exec_list(stmts, scope))
    # (the process dictionary reports a stored :undefined as missing, hence the default; the
    # microtasks run after the script and must not change its completion value)
    result = Process.get(:js_last, :undefined)
    Browser.JS.Promise.run_microtasks()
    :erlang.put(:js_last, caller_last)
    result
  end

  # GlobalDeclarationInstantiation: a script's `let`/`const`/class names may not collide with
  # an earlier script's declarations, nor `var`/function names with its lexical ones. What it
  # declares with `var` or `function` is a non-configurable property of the global object.
  defp declare_globals(stmts) do
    lex = Enum.flat_map(stmts, &lexical_names/1)
    vars = Enum.uniq(hoisted_names(stmts) ++ Enum.map(fundecls(stmts), &elem(&1, 0)))
    fixed = Process.get(:js_global_fixed) || MapSet.new()
    lexset = Process.get(:js_global_lex) || MapSet.new()

    for n <- lex,
        MapSet.member?(lexset, n) or MapSet.member?(fixed, n) or
          n in ["NaN", "Infinity", "undefined"],
        do: throw_error("SyntaxError", "Identifier '#{n}' has already been declared")

    for n <- vars,
        MapSet.member?(lexset, n),
        do: throw_error("SyntaxError", "Identifier '#{n}' has already been declared")

    check_global_declarable(hoisted_names(stmts), fundecls(stmts))

    # HasRestrictedGlobalProperty: a lexical name may not hide a non-configurable property
    g = Map.get(deref(global()).vars, :this)

    for n <- lex,
        match?({_, _, _, _, false}, Browser.JS.Props.own_state(g, n)),
        do: throw_error("SyntaxError", "Identifier '#{n}' has already been declared")

    # a `var` of a name that already exists leaves that property as it is; a function
    # declaration takes over a configurable property of the global object
    fun_names = Enum.map(fundecls(stmts), &elem(&1, 0))
    {:obj, gid} = g

    before = deref(gid)

    for n <- fun_names, Obj.has_own?(before, n) and not global_fixed?(n) do
      o = deref(gid)

      if match?({_, _, _, _, true}, Browser.JS.Props.own_state(g, n)),
        do: store(gid, Obj.own_remove(o, n))
    end

    gvars = deref(global()).vars

    fresh =
      for n <- vars,
          n in fun_names or not (Map.has_key?(gvars, n) or Obj.has_own?(before, n)),
          do: n

    # a lexical name hides a configurable built-in: the global object keeps its own property
    for n <- lex,
        MapSet.member?(Process.get(:js_builtin_names) || MapSet.new(), n),
        n not in ["NaN", "Infinity", "undefined"],
        Map.has_key?(gvars, n),
        not Obj.has_own?(deref(gid), n),
        do: put_hidden(g, n, Map.fetch!(gvars, n))

    Process.put(:js_global_lex, MapSet.union(lexset, MapSet.new(lex)))
    Process.put(:js_global_fixed, MapSet.union(fixed, MapSet.new(fresh)))
  end

  @doc false
  def global_fixed?(name), do: MapSet.member?(Process.get(:js_global_fixed) || MapSet.new(), name)

  @doc false
  def global_lexical?(name), do: MapSet.member?(Process.get(:js_global_lex) || MapSet.new(), name)

  @doc false
  # declares what a module body brings into its scope: `var` names, `let`/`const`/class names
  # (uninitialized until their declaration runs) and function declarations
  def module_init(stmts, scope) do
    hoist_vars(stmts, scope)

    for stmt <- stmts, name <- lexical_names(unexport(stmt)), do: declare(scope, name, :tdz)
    declare(scope, :default_export, :tdz)
    hoist_functions(stmts, scope)
  end

  @doc false
  def lexical_names({:var, kind, decls}) when kind in [:let, :const],
    do: Enum.reduce(decls, [], fn {pat, _}, a -> pattern_names(pat, a) end)

  def lexical_names({:export_default, {:classdecl, name, _}}), do: [name]
  def lexical_names(_), do: []

  @doc false
  def module_exec(stmts, scope), do: top_completion(exec_list(stmts, scope))

  @doc false
  # The completion of script, eval or module code or of a class static block. Such code
  # cannot complete with a `return`, `break` or `continue`: the parser refuses them. So
  # this is only a safety net. In check mode any other completion is a failure. In a
  # normal build it becomes `{:js_illegal, kind}`, which `Browser.JS` reports as a syntax
  # error, as it did before step 3.
  def top_completion(:ok), do: :ok

  def top_completion(c) do
    if @check, do: check_fail("top-level code completed with #{inspect(c)}")

    kind =
      case c do
        {:brk, _} -> :break
        {:cont, _} -> :continue
        _ -> :return
      end

    throw({:js_illegal, kind})
  end

  # `import.source(x)`: a source text module has no source to give, so the promise rejects
  # with a SyntaxError once the specifier and the options have been converted
  defp import_phase(:source, args, env) do
    [e | rest] = args
    arg = ev(e, env)
    options = if rest == [], do: :undefined, else: ev(hd(rest), env)
    p = Browser.JS.Promise.new()

    try do
      to_str(arg)
      check_import_options(options)
      Browser.JS.Promise.reject(p, make_error("SyntaxError", "Module has no source"))
    catch
      {:js_error, err} -> Browser.JS.Promise.reject(p, err)
    end

    p
  end

  defp import_phase(:defer, [e | rest], env),
    do: import_call(e, if(rest == [], do: nil, else: hd(rest)), env, true)

  defp import_call(e, opts, env, defer? \\ false) do
    arg = ev(e, env)
    options = if opts, do: ev(opts, env), else: :undefined
    p = Browser.JS.Promise.new()

    # the specifier and the options are converted now; the module is loaded in a later job
    try do
      spec = to_str(arg)
      type = check_import_options(options)

      base =
        case lookup_var(env, :module_url) do
          {:ok, b} -> b
          :error -> nil
        end

      hook = pget(:js_import)

      Browser.JS.Promise.enqueue(fn ->
        if hook == nil,
          do:
            Browser.JS.Promise.reject(
              p,
              make_error("TypeError", "Dynamic import is not available")
            ),
          else: hook.(spec, base, p, if(defer?, do: {:defer, type}, else: type))
      end)
    catch
      {:js_error, err} -> Browser.JS.Promise.reject(p, err)
    end

    p
  end

  # `import(spec, { with: { key: "string" } })`: the options are an object, `with` an object of
  # strings (a TypeError, as a rejection, otherwise)
  defp check_import_options(:undefined), do: nil

  defp check_import_options({:obj, _} = options) do
    case get(options, "with") do
      :undefined ->
        nil

      {:obj, _} = attrs ->
        pairs =
          for k <- Browser.JS.Props.enumerable_own_keys(attrs),
              is_binary(k),
              do: {k, get(attrs, k)}

        for {_, v} <- pairs do
          unless is_binary(v),
            do: throw_error("TypeError", "Import attribute value must be a string")
        end

        case pairs do
          [] -> nil
          [{"type", type}] -> type
          _ -> throw_error("SyntaxError", "Unsupported import attribute")
        end

      _ ->
        throw_error("TypeError", "The 'with' option must be an object")
    end
  end

  defp check_import_options(_),
    do: throw_error("TypeError", "The second argument of import() must be an object")

  @doc false
  # the current value of a module's variable (`:tdz` while uninitialized)
  def module_binding(scope, name) do
    case lookup_var(scope, name) do
      {:ok, v} -> v
      :error -> :undefined
    end
  end

  # The keys `for (k in o)` visits: the enumerable string keys of `o`, then of each object on
  # its prototype chain, none twice and none that an object nearer in the chain (enumerable
  # or not) already has.
  @doc false
  # The keys that a for-in loop visits. It is public because the CPS evaluator
  # (`Browser.JS.Async`) runs for-in loops whose bodies await.
  def for_in_keys({:obj, id} = o) do
    if Map.has_key?(deref(id), :proxy) do
      own_keys(o)
    else
      own = own_keys(o)

      case inherited_enumerable(Browser.JS.Props.get_prototype_of(o), []) do
        [] ->
          own

        _ ->
          walk_for_in(o, MapSet.new(), [])
      end
    end
  end

  def for_in_keys(target), do: own_keys(target)

  # The object of `for (k in v)`: a primitive becomes its wrapper object (ToObject), so a
  # string visits its indexes. `null` and `undefined` stay, and the loop visits nothing.
  def for_in_object({:obj, _} = o), do: o
  def for_in_object(v) when v in [:null, :undefined], do: v
  def for_in_object(v), do: Browser.JS.Builtins.box(v)

  # protos on the chain that have an enumerable key of their own
  defp inherited_enumerable({:obj, id} = p, acc) do
    if Map.has_key?(deref(id), :proxy) do
      [p | acc]
    else
      acc = if own_keys(p) == [], do: acc, else: [p | acc]
      inherited_enumerable(Browser.JS.Props.get_prototype_of(p), acc)
    end
  end

  defp inherited_enumerable(_, acc), do: acc

  defp walk_for_in({:obj, id} = o, seen, acc) do
    if Map.has_key?(deref(id), :proxy) do
      new = Enum.reject(own_keys(o), &MapSet.member?(seen, &1))
      acc |> then(&[new | &1]) |> Enum.reverse() |> List.flatten()
    else
      new = Enum.reject(own_keys(o), &MapSet.member?(seen, &1))
      seen = Enum.reduce(Browser.JS.Props.own_names(o), seen, &MapSet.put(&2, &1))
      walk_for_in(Browser.JS.Props.get_prototype_of(o), seen, [new | acc])
    end
  end

  defp walk_for_in(_, _seen, acc), do: acc |> Enum.reverse() |> List.flatten()

  defp exec_list([], _env), do: :ok

  defp exec_list([{:pos, loc} | rest], env) do
    :erlang.put(:js_pos, loc)
    exec_list(rest, env)
  end

  # A statement that does not complete normally ends the list, and its completion is the
  # completion of the list.
  defp exec_list([stmt | rest], env) do
    case exec(stmt, env, []) do
      :ok ->
        exec_list(rest, env)

      c ->
        if @check, do: check_completion(c, stmt)
        c
    end
  end

  # The body of a function on the old path. The `return`, `if` and block statements at the
  # top of the body run here, and a top-level expression statement does not write
  # `:js_last`. Other statements run through `exec/3`, which writes `:js_last` as before
  # step 3, so the completion values at `:off` do not change. A rewritten body runs
  # through `fbody/2`.
  defp exec_fn([], _env), do: :ok

  defp exec_fn([{:pos, loc} | rest], env) do
    :erlang.put(:js_pos, loc)
    exec_fn(rest, env)
  end

  defp exec_fn([stmt | rest], env) do
    case exec_fn_stmt(stmt, env) do
      :ok ->
        exec_fn(rest, env)

      c ->
        if @check, do: check_completion(c, stmt)
        c
    end
  end

  defp exec_fn_stmt({:return, nil}, _env), do: {:ret, :undefined}

  defp exec_fn_stmt({:return, e}, env)
       when not (is_tuple(e) and elem(e, 0) in [:call, :cond, :seq, :logical]),
       do: {:ret, ev(e, env)}

  # (on the old path a call form always goes to `tail_value/2`: the function boundary in
  # `closure_scope/4` decides if the pending call is a tail call)
  defp exec_fn_stmt({:return, e}, env), do: tail_value(e, env)

  # (a statement's completion value only matters outside function bodies: in a script or eval code)
  defp exec_fn_stmt({:expr, e}, env) do
    ev(e, env)
    :ok
  end

  defp exec_fn_stmt({:if, c, a, b}, env) do
    cond do
      truthy(ev(c, env)) -> exec_fn_stmt(a, env)
      b != nil -> exec_fn_stmt(b, env)
      true -> :ok
    end
  end

  defp exec_fn_stmt({:block, stmts}, env) do
    if scoped_block?(stmts), do: exec_other({:block, stmts}, env), else: exec_fn(stmts, env)
  end

  defp exec_fn_stmt(stmt, env), do: exec_other(stmt, env)

  defp exec_other(stmt, env) do
    c = exec(stmt, env, [])
    if @check, do: check_completion(c, stmt)
    c
  end

  # ── statements inside a rewritten function ─────────────────

  # Only script and eval code have a completion value, so the statements of a rewritten
  # function do not write `:js_last` (step 3). `fbody/2` and `fstmt/3` run these
  # statements. `fstmt/3` has its own clauses for the kinds whose `exec/3` clause writes
  # `:js_last` and that occur in both kinds of code: expression statements, `if`,
  # labeled statements, `while` and `do-while`. It also has the blocks and the marked
  # returns. Every other kind goes to `exec/3`, whose clauses for the frame shapes write
  # nothing and run their children through `fstmt/3` and `fbody/2`.

  @doc false
  # (the statement runner of the CPS evaluator for the body of a rewritten async function
  # or generator, see `Browser.JS.Async`)
  def exec_frame_stmt(stmt, env, labels \\ []), do: fstmt(stmt, env, labels)

  # A statement list inside a rewritten function. A statement that does not complete
  # normally ends the list, as in `exec_list/2`.
  defp fbody([], _env), do: :ok

  defp fbody([{:pos, loc} | rest], env) do
    :erlang.put(:js_pos, loc)
    fbody(rest, env)
  end

  defp fbody([stmt | rest], env) do
    case fstmt(stmt, env, []) do
      :ok ->
        fbody(rest, env)

      c ->
        if @check, do: check_completion(c, stmt)
        c
    end
  end

  @doc false
  # A statement of a rewritten function. (public: a statement that `Browser.JS.Compile`
  # does not compile runs through it)
  #
  # A compiled child (step 5): the compiler puts `{:cc, fun}` in the place of a statement
  # child of a node that stays on the tree, so the tree runs the closure.
  def fstmt({:cc, f}, env, _), do: f.(env)

  # (the twin of the `exec/3` clause for `{:expr}`, without the write)
  def fstmt({:expr, e}, env, _) do
    ev(e, env)
    :ok
  end

  # The resolver marked each return of a rewritten function: a tail site gives back a
  # pending call, and every other return is plain.
  def fstmt({:return, e, :plain}, env, _), do: {:ret, ev(e, env)}
  def fstmt({:return, e, :tail}, env, _), do: tail_value(e, env)

  # (the twin of the `exec/3` clause for `{:if}`, without the write)
  def fstmt({:if, c, a, b}, env, _) do
    cond do
      truthy(ev(c, env)) -> fstmt(a, env, [])
      b != nil -> fstmt(b, env, [])
      true -> :ok
    end
  end

  # (the twin of the `exec/3` clause for `{:labeled}`)
  def fstmt({:labeled, l, s}, env, labels) do
    case fstmt(s, env, [l | labels]) do
      {:brk, ^l} -> :ok
      c -> c
    end
  end

  # (the twins of the `exec/3` clauses for `{:while}` and `{:dowhile}`, without the write)
  def fstmt({:while, c, body}, env, labels), do: while_loop(c, body, env, labels, :fn)

  def fstmt({:dowhile, body, c}, env, labels) do
    case run_body(body, env, labels, :fn) do
      :break -> :ok
      :next -> while_loop(c, body, env, labels, :fn)
      exit -> loop_exit(exit)
    end
  end

  # (a block inside a rewritten function: its names are slots of the frame, no scope is made)
  def fstmt({:block, stmts, sc}, env, _) when frameless(sc) do
    enter_frameless(env, sc)
    fbody(stmts, env)
  end

  # (a block whose names a closure captures: the names live in a block frame of their own)
  def fstmt({:block, stmts, sc}, env, _) when framed(sc) do
    fns = :erlang.get(:js_fns)
    b = enter_scope(env, sc)

    try do
      fbody(stmts, b)
    after
      leave_scope(b, fns)
    end
  end

  def fstmt(stmt, env, labels), do: exec(stmt, env, labels)

  # A loop body or a case body in the mode of the loop: `:top` for script, eval and
  # old-path code, which writes `:js_last`, and `:fn` for a rewritten function.
  @compile {:inline, mode_exec: 3, mode_list: 3}
  defp mode_exec(stmt, env, :fn), do: fstmt(stmt, env, [])
  defp mode_exec(stmt, env, :top), do: exec(stmt, env, [])
  defp mode_list(stmts, env, :fn), do: fbody(stmts, env)
  defp mode_list(stmts, env, :top), do: exec_list(stmts, env)

  @doc "Runs statements as a class static block in `scope`: hoists, then executes."
  def run_body(stmts, scope) do
    hoist_vars(stmts, scope)
    hoist_functions(stmts, scope)
    top_completion(exec_list(stmts, scope))
  end

  # Check mode only (K6 of step 3): the `exec/3` clauses that write `:js_last` and have a
  # twin in `fstmt/3` run only in script, eval and old-path code, whose scopes are maps.
  # A frame is a tuple, so a statement of a rewritten function that comes here is a fault.
  defp check_script_env(env, kind) do
    if is_integer(env) and is_tuple(:erlang.get(env)),
      do: check_fail("the statement #{inspect(kind)} of a rewritten function in exec/3")

    :ok
  end

  @doc false
  # Check mode only (K1 of step 3): a statement completes with one of the five completion
  # shapes. Any other value is a clause that gives back a result by accident, and a list
  # would stop on it.
  def check_completion(c, stmt) do
    case c do
      :ok -> :ok
      {:ret, _} -> :ok
      {tag, l} when tag in [:brk, :cont] and (l == nil or is_binary(l)) -> :ok
      {:tail, _, _, _} -> :ok
      _ -> check_fail("the statement #{inspect(elem(stmt, 0))} completed with #{inspect(c)}")
    end
  end

  # ── using declarations ─────────────────────────────────────

  @dispose {:symbol, :dispose, "Symbol.dispose"}
  @async_dispose {:symbol, :asyncDispose, "Symbol.asyncDispose"}

  @doc false
  # what a `using` / `await using` initializer gives: `{:none, mode}` for null and undefined,
  # else `{:res, value, method, mode}` where mode is :sync, :async, or :async_from_sync
  def using_resource(kind, v) when v in [:undefined, :null],
    do: {:none, if(kind == :using, do: :sync, else: :async)}

  def using_resource(kind, v) do
    unless match?({:obj, _}, v),
      do: throw_error("TypeError", "using declaration needs an object, null or undefined")

    case kind do
      :using ->
        {:res, v, dispose_method(v, @dispose) || missing_dispose(), :sync}

      :await_using ->
        case dispose_method(v, @async_dispose) do
          nil -> {:res, v, dispose_method(v, @dispose) || missing_dispose(), :async_from_sync}
          m -> {:res, v, m, :async}
        end
    end
  end

  defp missing_dispose, do: throw_error("TypeError", "object is not disposable")

  defp dispose_method(v, sym) do
    case get(v, sym) do
      m when m in [:undefined, :null] ->
        nil

      m ->
        unless function?(m), do: throw_error("TypeError", "dispose method is not callable")
        m
    end
  end

  @doc false
  # runs the disposal of one resource to its end: :ok or {:error, e}
  def dispose_sync({:none, :sync}), do: :ok
  def dispose_sync({:none, :async}), do: await_catching(:undefined)

  def dispose_sync({:res, v, m, :sync}) do
    call(m, v, [])
    :ok
  catch
    {:js_error, e} -> {:error, e}
  end

  def dispose_sync({:res, v, m, :async}) do
    await_catching(call(m, v, []))
  catch
    {:js_error, e} -> {:error, e}
  end

  def dispose_sync({:res, v, m, :async_from_sync}) do
    call(m, v, [])
    await_catching(:undefined)
  catch
    {:js_error, e} -> {:error, e}
  end

  defp await_catching(value) do
    Browser.JS.Promise.await(value)
    :ok
  catch
    {:js_error, e} -> {:error, e}
  end

  @doc false
  # How the rest of a list ended, `{:done, completion}` or `{:thrown, t}`, together with its
  # disposal. A clean disposal keeps the completion, and an error from the disposal replaces
  # it, also a return or a break.
  def using_finish({:done, c}, :ok), do: c
  def using_finish({:done, _}, {:error, e}), do: throw({:js_error, e})
  def using_finish({:thrown, t}, :ok), do: throw(t)

  def using_finish({:thrown, {:js_error, e}}, {:error, e2}),
    do: throw({:js_error, suppressed_error(e2, e)})

  def using_finish({:thrown, _}, {:error, e2}), do: throw({:js_error, e2})

  @doc false
  def suppressed_error(error, suppressed) do
    err = make_error("SuppressedError", "An error was suppressed during disposal")
    put_hidden(err, "error", error)
    put_hidden(err, "suppressed", suppressed)
    err
  end

  @doc false
  # Runs one statement of old-path code and gives its completion. A statement of a rewritten
  # function runs through `exec_frame_stmt/3`.
  def exec_stmt(stmt, env, labels \\ []), do: exec(stmt, env, labels)

  defp exec(stmt, env), do: exec(stmt, env, [])

  # where the script is: the file and line of the statement that follows (see the parser)
  # A compiled child (step 5), as in `fstmt/3`.
  defp exec({:cc, f}, env, _), do: f.(env)

  defp exec({:pos, loc}, _, _) do
    :erlang.put(:js_pos, loc)
    :ok
  end

  # (the `fstmt/3` clause is the twin of this one for a rewritten function)
  defp exec({:expr, e}, env, _) do
    if @check, do: check_script_env(env, :expr)
    :erlang.put(:js_last, ev(e, env))
    :ok
  end

  defp exec({:var, kind, decls}, env, _) do
    for {pat, init} <- decls do
      cond do
        # `var x = …` inside `with`: the reference is resolved before the initializer runs
        init != nil and kind == :var and match?({:id, _}, pat) and
            Process.get(:js_with_used, false) ->
          {:id, name} = pat
          {_, write} = id_ref(env, name, pat, false)
          write.(ev_named(init, env, pat))

        init != nil ->
          bind(pat, ev_named(init, env, pat), env, kind)

        kind == :var ->
          :ok

        true ->
          bind(pat, :undefined, env, kind)
      end
    end

    :ok
  end

  # `using x = v; rest`: the rest of the list runs, then the resource is disposed, whichever
  # way the rest ended
  defp exec({:using, kind, {:slot, 0, i, name}, init, rest}, env, _) do
    v = ev_named(init, env, {:id, name})
    res = using_resource(kind, v)
    slot_put(env, i, v)

    outcome =
      try do
        {:done, run_tail(fbody(rest, env), env)}
      catch
        t -> {:thrown, t}
      end

    using_finish(outcome, dispose_sync(res))
  end

  defp exec({:using, kind, name, init, rest}, env, _) when is_binary(name) do
    v = ev_named(init, env, {:id, name})
    res = using_resource(kind, v)
    declare(env, name, v, true)

    outcome =
      try do
        {:done, run_tail(exec_list(rest, env), env)}
      catch
        t -> {:thrown, t}
      end

    using_finish(outcome, dispose_sync(res))
  end

  defp exec({:with, obj, body}, env, _) do
    :erlang.put(:js_last, :undefined)
    o = ev(obj, env)

    if o in [:undefined, :null],
      do: throw_error("TypeError", "Cannot convert undefined or null to object")

    Process.put(:js_with_used, true)
    scope = new_scope(env)
    s = deref(scope)
    store(scope, Map.put(s, :with, if(match?({:obj, _}, o), do: o, else: new_object())))
    run_tail(exec(body, scope, []), scope)
  end

  # The CPS evaluator takes every statement that is marked `{:aw}`, so in check mode the
  # sync evaluator fails when it sees the mark.
  if @check do
    defp exec({:aw, s}, _, _), do: check_fail("the sync evaluator meets {:aw, #{elem(s, 0)}}")
  end

  defp exec({:fundecl, _, _}, _, _), do: :ok
  defp exec({:empty}, _, _), do: :ok
  defp exec({:import, _, _}, _, _), do: :ok
  defp exec({:export, stmt}, env, _), do: exec(stmt, env, [])
  defp exec({:export_default, {:fundecl, _, _}}, _, _), do: :ok

  # (`declare/3` gives back a value that is not a completion, so these clauses give `:ok`)
  defp exec({:export_default, {:classdecl, name, node}}, env, _) do
    declare(env, name, ev_named(node, env, {:id, "default"}))
    :ok
  end

  defp exec({:export_default, {:expr, e}}, env, _) do
    declare(env, :default_export, ev_named(e, env, {:id, "default"}))
    :ok
  end

  defp exec({:export_names, _}, _, _), do: :ok
  defp exec({:export_from, _, _}, _, _), do: :ok

  defp exec({:block, stmts}, env, _) do
    if @check, do: check_script_env(env, :block)

    if scoped_block?(stmts) do
      if @check, do: check_old_path(env, "a block")
      fns = pget(:js_fns)
      scope = new_scope(env)
      hoist_functions(stmts, scope)
      result = exec_list(stmts, scope)
      free_scope(scope, fns)
      result
    else
      # nothing in the block binds a name: it needs no scope of its own
      exec_list(stmts, env)
    end
  end

  # (the blocks of a rewritten function, also through `exec_frame_stmt/3`)
  defp exec({:block, _, _} = stmt, env, labels), do: fstmt(stmt, env, labels)

  defp exec({:return, nil}, _, _), do: {:ret, :undefined}

  # (on the old path a call form always goes to `tail_value/2`: a run site or the function
  # boundary in `closure_scope/4` decides what happens with the pending call)
  defp exec({:return, e}, env, _)
       when is_tuple(e) and elem(e, 0) in [:call, :cond, :seq, :logical],
       do: tail_value(e, env)

  defp exec({:return, e}, env, _), do: {:ret, ev(e, env)}

  defp exec({:return, e, :plain}, env, _), do: {:ret, ev(e, env)}
  defp exec({:return, e, :tail}, env, _), do: tail_value(e, env)

  defp exec({:throw, e}, env, _) do
    v = ev(e, env)
    # (a thrown value that is no error object has no stack to say where it was thrown)
    :erlang.put(:js_throw_pos, Process.get(:js_pos))
    throw({:js_error, v})
  end

  defp exec({:break, label}, _, _), do: {:brk, label}
  defp exec({:continue, label}, _, _), do: {:cont, label}

  # (the `fstmt/3` clause is the twin of this one for a rewritten function)
  defp exec({:if, c, a, b}, env, _) do
    if @check, do: check_script_env(env, :if)
    :erlang.put(:js_last, :undefined)

    cond do
      truthy(ev(c, env)) -> exec(a, env)
      b != nil -> exec(b, env)
      true -> :ok
    end
  end

  # A break to this label ends the labeled statement normally. A continue to the label is
  # for the loop that has the label in `labels`.
  # (the `fstmt/3` clause is the twin of this one for a rewritten function)
  defp exec({:labeled, l, s}, env, labels) do
    if @check, do: check_script_env(env, :labeled)

    case exec(s, env, [l | labels]) do
      {:brk, ^l} -> :ok
      c -> c
    end
  end

  # (the `fstmt/3` clauses are the twins of these two for a rewritten function)
  defp exec({:while, c, body}, env, labels) do
    if @check, do: check_script_env(env, :while)
    :erlang.put(:js_last, :undefined)
    while_loop(c, body, env, labels, :top)
  end

  defp exec({:dowhile, body, c}, env, labels) do
    if @check, do: check_script_env(env, :dowhile)
    :erlang.put(:js_last, :undefined)

    case run_body(body, env, labels, :top) do
      :break -> :ok
      :next -> while_loop(c, body, env, labels, :top)
      exit -> loop_exit(exit)
    end
  end

  defp exec({:for, init, test, update, body}, env, labels) do
    :erlang.put(:js_last, :undefined)
    # only `let` and `const` bind names of the loop's own
    lexical? = match?({:var, kind, _} when kind in [:let, :const], init)
    if @check and lexical?, do: check_old_path(env, "a for loop")
    loop_env = if lexical?, do: new_scope(env), else: env
    per_iteration? = match?({:var, :let, _}, init)
    fns = pget(:js_fns)

    case init do
      {:var, _, _} = d -> exec(d, loop_env)
      {:expr, e} -> ev(e, loop_env)
      nil -> :ok
    end

    # each iteration has a copy of the `let` bindings, but only a closure made since can see
    # which one it is: with none, one scope serves every iteration
    first =
      if per_iteration? and pget(:js_fns) != fns, do: copy_scope(loop_env, env), else: loop_env

    for_loop(test, update, body, env, first, per_iteration?, labels, pget(:js_fns), :top)
  end

  # a `for` inside a rewritten function: the head's names are slots of the frame, so the
  # loop runs in `env` with no scope, no copy per iteration and no closure count to read
  defp exec({:for, init, test, update, body, sc}, env, labels) when frameless(sc) do
    enter_frameless(env, sc)

    case init do
      {:var, _, _} = d -> exec(d, env)
      {:expr, e} -> ev(e, env)
      nil -> :ok
    end

    frame_for_loop(test, update, body, env, labels)
  end

  # A `for` whose head names a closure captures. With a `let` head each iteration gets its
  # own copy of the head frame, as on the old path: `for_loop/9` copies the frame only when
  # a closure was made since the last copy, through the tuple clause of `copy_scope/2`.
  # With a `const` head one frame serves every round. The head frame is freed when no
  # closure was made during the whole loop, which also means that no copy was made.
  defp exec({:for, init, test, update, body, sc}, env, labels) when framed(sc) do
    fns = :erlang.get(:js_fns)
    l0 = enter_scope(env, sc)

    try do
      case init do
        {:var, _, _} = d -> exec(d, l0)
        {:expr, e} -> ev(e, l0)
        nil -> :ok
      end

      if sc.per_iter do
        first = if :erlang.get(:js_fns) != fns, do: copy_scope(l0, env), else: l0
        for_loop(test, update, body, env, first, true, labels, :erlang.get(:js_fns), :fn)
      else
        frame_for_loop(test, update, body, l0, labels)
      end
    after
      leave_scope(l0, fns)
    end
  end

  defp exec({kind, _, _, _, _} = node, env, labels) when kind in [:forin, :forof],
    do: exec_for_each(node, env, labels)

  defp exec({kind, _, _, _, _, sc} = node, env, labels)
       when kind in [:forin, :forof] and framed(sc),
       do: exec_for_each_framed(node, env, labels)

  defp exec({kind, _, _, _, _, sc} = node, env, labels)
       when kind in [:forin, :forof] and frameless(sc),
       do: exec_for_each_frame(node, env, labels)

  defp exec({:switch, disc, cases}, env, _) do
    :erlang.put(:js_last, :undefined)
    v = ev(disc, env)
    if @check, do: check_old_path(env, "a switch")
    scope = new_scope(env)
    all = Enum.flat_map(cases, fn {_, body} -> body end)
    hoist_functions(all, scope)

    start =
      Enum.find_index(cases, fn {test, _} ->
        test != :default and strict_eq(v, ev(test, scope))
      end) ||
        Enum.find_index(cases, fn {test, _} -> test == :default end)

    if start, do: run_cases(Enum.drop(cases, start), scope, :top), else: :ok
  end

  # (a switch whose names a closure captures: the discriminant runs outside the switch, the
  # tests and the bodies in its block frame, where every case's functions are already made)
  defp exec({:switch, disc, cases, sc}, env, _) when framed(sc) do
    v = ev(disc, env)
    fns = :erlang.get(:js_fns)
    s = enter_scope(env, sc)

    try do
      start =
        Enum.find_index(cases, fn {test, _} ->
          test != :default and strict_eq(v, ev(test, s))
        end) ||
          Enum.find_index(cases, fn {test, _} -> test == :default end)

      if start, do: run_cases(Enum.drop(cases, start), s, :fn), else: :ok
    after
      leave_scope(s, fns)
    end
  end

  defp exec({:switch, disc, cases, sc}, env, _) when frameless(sc) do
    v = ev(disc, env)
    enter_frameless(env, sc)

    start =
      Enum.find_index(cases, fn {test, _} ->
        test != :default and strict_eq(v, ev(test, env))
      end) ||
        Enum.find_index(cases, fn {test, _} -> test == :default end)

    if start, do: run_cases(Enum.drop(cases, start), env, :fn), else: :ok
  end

  # A `try` inside a rewritten function. The catch parameter is a slot of the frame, or of
  # a catch frame when a closure captures a name of the catch (see `run_handler/6`).
  defp exec({:try, block, param, handler, finalizer, sc}, env, _),
    do: try_statement(block, param, handler, finalizer, sc, env)

  # (a `try` on the old path: the handler runs in a new map scope)
  defp exec({:try, block, param, handler, finalizer}, env, _) do
    :erlang.put(:js_last, :undefined)
    try_statement(block, param, handler, finalizer, :map, env)
  end

  # The cases of a switch run in order from the first match until one does not complete
  # normally. This is the fallthrough of JS. A break without a label ends the switch. A
  # continue without a label goes up to the loop around the switch.
  defp run_cases([], _env, _mode), do: :ok

  defp run_cases([{_, body} | rest], env, mode) do
    case mode_list(body, env, mode) do
      :ok -> run_cases(rest, env, mode)
      {:brk, nil} -> :ok
      c -> c
    end
  end

  # A `try` statement. Without a finalizer, the block and the handler are all of it. With
  # a finalizer, the outcome of the block and the handler is kept as a value, so that the
  # finalizer can run after every way out, as an Elixir `after` block would.
  defp try_statement(block, param, handler, nil, sc, env),
    do: try_part(block, param, handler, false, sc, env)

  defp try_statement(block, param, handler, finalizer, sc, env) do
    outcome =
      try do
        {:done, try_part(block, param, handler, true, sc, env)}
      catch
        :throw, v -> {:thrown, v}
        kind, reason -> {:raised, kind, reason, __STACKTRACE__}
      end

    run_finally(outcome, finalizer, env, try_mode(sc))
  end

  # The block of a `try`, and the handler when the block throws a JS error. The handler
  # runs in the `catch` clause, outside the inner `try`, so a throw from the handler goes
  # to the finalizer. `fin?` says whether a finalizer follows.
  defp try_part(block, param, handler, fin?, sc, env) do
    try do
      # (the block is no tail position: a pending call runs here, where the catch sees it)
      run_tail(mode_exec(block, env, try_mode(sc)), env)
    catch
      {:js_error, v} when handler != nil -> run_handler(v, param, handler, fin?, sc, env)
    end
  end

  # The catch clause. A frameless scope binds the parameter in a slot of the frame. A
  # framed scope makes a catch frame, which is left when the handler ends. The old path
  # (`:map`) makes a map scope.
  defp run_handler(v, param, handler, fin?, sc, env) when frameless(sc) do
    if @check, do: check_link(env)
    enter_frameless(env, sc)
    if param, do: bind(param, v, env, :let)
    handler_body(handler, env, fin?, :fn)
  end

  defp run_handler(v, param, handler, fin?, sc, env) when framed(sc) do
    if @check, do: check_link(env)
    fns = :erlang.get(:js_fns)
    c = enter_scope(env, sc)

    try do
      if param, do: bind(param, v, c, :let)
      handler_body(handler, c, fin?, :fn)
    after
      leave_scope(c, fns)
    end
  end

  defp run_handler(v, param, handler, fin?, :map, env) do
    if @check, do: check_old_path(env, "a catch clause")
    if @check, do: check_link(env)
    scope = new_scope(env)
    if param, do: bind(param, v, scope, :let)

    with {:id, pname} <- param,
         do: declare(scope, :catch_param, pname)

    handler_body(handler, scope, fin?, :top)
  end

  # A handler that a finalizer follows makes no tail call, because the finalizer must run
  # after the call.
  defp handler_body(handler, env, true, mode), do: run_tail(mode_exec(handler, env, mode), env)
  defp handler_body(handler, env, false, mode), do: mode_exec(handler, env, mode)

  # (the 5-tuple `try` of script, eval and old-path code passes `:map`)
  defp try_mode(:map), do: :top
  defp try_mode(_sc), do: :fn

  # The finalizer runs after every way out of the block and the handler. When it completes
  # normally, the statement keeps the outcome of the block and the handler, and its own
  # value. When it completes abruptly, its completion replaces that outcome, also a pending
  # throw or the step limit, as a throw out of an Elixir `after` block did before step 3.
  defp run_finally(outcome, finalizer, env, :top) do
    saved = :erlang.get(:js_last)
    :erlang.put(:js_last, :undefined)

    case exec(finalizer, env, []) do
      :ok ->
        :erlang.put(:js_last, saved)
        finish_outcome(outcome)

      c ->
        c
    end
  end

  # (a rewritten function has no completion value to keep)
  defp run_finally(outcome, finalizer, env, :fn) do
    case fstmt(finalizer, env, []) do
      :ok -> finish_outcome(outcome)
      c -> c
    end
  end

  # The outcome of the block and the handler, after a finalizer that completed normally.
  defp finish_outcome({:done, c}), do: c
  defp finish_outcome({:thrown, v}), do: throw(v)
  defp finish_outcome({:raised, kind, reason, st}), do: :erlang.raise(kind, reason, st)

  @doc false
  # The function and the `this` value of a call site. It is public because the CPS evaluator
  # (`Browser.JS.Async`) settles the callee of an optional call before its arguments await.
  def call_target(callee, env) do
    case callee do
      {:super_member, key} ->
        {home, this} = Browser.JS.Classes.super_base(env)
        {get_with_receiver(home, ev_key(key, env), this), this}

      {:member, o, k, mopt} ->
        ov = ev(o, env)
        if mopt and nullish?(ov), do: throw(:js_short)
        {get(ov, ev_key(k, env)), ov}

      # `(a?.b)()` keeps `a` as `this`; a short-circuited chain is `undefined`
      {:chain, {:member, o, k, mopt}} ->
        try do
          ov = ev(o, env)
          if mopt and nullish?(ov), do: throw(:js_short)
          {get(ov, ev_key(k, env)), ov}
        catch
          :js_short -> {:undefined, :undefined}
        end

      {:id, name} when is_binary(name) ->
        # a function found on a `with` object is called with that object as `this`
        if Process.get(:js_with_used, false) do
          case with_binding(env, name) do
            {:with, obj} ->
              # GetBindingValue asks again whether the binding is still there
              {if(has_property?(obj, name), do: get(obj, name), else: :undefined), obj}

            {:var, sc} ->
              # (an import is a live binding: the slot holds an alias, not the value)
              case lookup_var(sc, name) do
                {:ok, v} when v != :tdz -> {v, :undefined}
                _ -> {ev(callee, env), :undefined}
              end

            _ ->
              {ev(callee, env), :undefined}
          end
        else
          {ev(callee, env), :undefined}
        end

      _ ->
        {ev(callee, env), :undefined}
    end
  end

  defp exec_for_each({kind, decl, pat, obj, body}, env, labels) do
    :erlang.put(:js_last, :undefined)
    if @check, do: check_old_path(env, "a for-in or for-of loop")

    # the head's own names are in their temporal dead zone while the object is evaluated
    target =
      if decl in [:let, :const] do
        tdz = new_scope(env)
        for name <- pattern_names(pat, []), do: declare(tdz, name, :tdz)
        ev(obj, tdz)
      else
        ev(obj, env)
      end

    mode = if decl == nil, do: :assign, else: decl
    target = if kind == :forin, do: for_in_object(target), else: target

    source =
      case kind do
        :forin -> {:list, if(nullish?(target), do: [], else: for_in_keys(target))}
        :forof -> for_of_source(target)
      end

    case source do
      {:proto, it, next} ->
        proto_loop(it, next, {pat, mode, body, env, :fresh}, labels)

      {:list, items} ->
        Enum.reduce_while(items, :ok, fn item, _ ->
          # a key that was deleted before its turn is skipped
          if kind == :forin and not has_property?(target, item) do
            {:cont, :ok}
          else
            tick()
            fns = pget(:js_fns)
            iter_env = new_scope(env)
            bind(pat, item, iter_env, mode)
            outcome = run_tail(run_body(body, iter_env, labels, :top), iter_env)
            free_scope(iter_env, fns)

            case outcome do
              :break -> {:halt, :ok}
              :next -> {:cont, :ok}
              c -> {:halt, loop_exit(c)}
            end
          end
        end)
    end
  end

  # A for-in or for-of inside a rewritten function. The head's names are slots of the frame:
  # they go back to the temporal dead zone before the object is evaluated and again before
  # every item, so a default that reads its own name throws on every round.
  defp exec_for_each_frame({kind, decl, pat, obj, body, sc}, env, labels) do
    reset_tdz(env, sc)
    target = ev(obj, env)
    mode = if decl == nil, do: :assign, else: decl
    target = if kind == :forin, do: for_in_object(target), else: target

    source =
      case kind do
        :forin -> {:list, if(nullish?(target), do: [], else: for_in_keys(target))}
        :forof -> for_of_source(target)
      end

    case source do
      {:proto, it, next} ->
        proto_loop(it, next, {pat, mode, body, env, sc}, labels)

      {:list, items} ->
        Enum.reduce_while(items, :ok, fn item, _ ->
          # a key that was deleted before its turn is skipped
          if kind == :forin and not has_property?(target, item) do
            {:cont, :ok}
          else
            tick()
            reset_tdz(env, sc)
            bind(pat, item, env, mode)

            case run_tail(run_body(body, env, labels, :fn), env) do
              :break -> {:halt, :ok}
              :next -> {:cont, :ok}
              c -> {:halt, loop_exit(c)}
            end
          end
        end)
    end
  end

  # A for-in or for-of whose head names a closure captures. The object runs in a head frame
  # `h`, where the head names are in their TDZ. Each item runs in an item frame: the frame
  # of the item before is renewed in place (one write puts the names back in their TDZ)
  # while no closure was made since it was made, and a new frame is made after one was.
  # `h` is the first item frame, so `for (const k of [() => k]) k()` keeps `h` for the
  # arrow and runs the first item in a new frame.
  defp exec_for_each_framed({kind, decl, pat, obj, body, sc}, env, labels) do
    h = enter_scope(env, sc)
    fresh = :erlang.get(h)
    fns = :erlang.get(:js_fns)
    mode = if decl == nil, do: :assign, else: decl

    {target, source} =
      try do
        target = ev(obj, h)

        source =
          case kind do
            :forin -> {:list, if(nullish?(target), do: [], else: for_in_keys(target))}
            :forof -> for_of_source(target)
          end

        {target, source}
      catch
        k, e ->
          leave_scope(h, fns)
          :erlang.raise(k, e, __STACKTRACE__)
      end

    case source do
      {:proto, it, next} ->
        proto_loop(it, next, {pat, mode, body, env, {:frame, fresh, h, fns}}, labels)

      {:list, items} ->
        last =
          Enum.reduce_while(items, {h, fns, :ok}, fn item, {cur, cur_fns, _} = acc ->
            # a key that was deleted before its turn is skipped
            if kind == :forin and not has_property?(target, item) do
              {:cont, acc}
            else
              tick()
              {cur, cur_fns} = item_frame(fresh, cur, cur_fns)

              outcome =
                try do
                  bind(pat, item, cur, mode)
                  run_tail(run_body(body, cur, labels, :fn), cur)
                catch
                  k, e ->
                    leave_scope(cur, cur_fns)
                    :erlang.raise(k, e, __STACKTRACE__)
                end

              case outcome do
                :break -> {:halt, {cur, cur_fns, :ok}}
                :next -> {:cont, {cur, cur_fns, :ok}}
                c -> {:halt, {cur, cur_fns, loop_exit(c)}}
              end
            end
          end)

        {cur, cur_fns, c} = last
        leave_scope(cur, cur_fns)
        c
    end
  end

  # The frame for the next item of a framed for-in or for-of, and the closure count from
  # when it was made. The frame of the item before is reused when no closure was made
  # since, because then nothing can hold its id.
  defp item_frame(fresh, cur, cur_fns) do
    n = :erlang.get(:js_fns)

    if n == cur_fns do
      :erlang.put(cur, fresh)
      {cur, n}
    else
      {alloc(fresh), n}
    end
  end

  # the loop of a `for` inside a rewritten function: one scope, the frame, for every round
  defp frame_for_loop(test, update, body, env, labels) do
    tick()

    if test == nil or truthy(ev(test, env)) do
      case run_body(body, env, labels, :fn) do
        :break ->
          :ok

        :next ->
          if update, do: ev(update, env)
          frame_for_loop(test, update, body, env, labels)

        c ->
          loop_exit(c)
      end
    else
      :ok
    end
  end

  # The completion of a `return` at a tail site. A call in tail position is not made here:
  # the callee, `this` and the arguments come back as `{:tail, f, this, args}`. A run site
  # or the function boundary makes the call. Anything else comes back as `{:ret, value}`.
  # A call of the name `eval` is a tail call when the callee is not the built-in `eval`. A
  # direct eval runs here, because it needs the scope of this function.
  # It is public because the closure compiler (`Browser.JS.Compile`) calls it for the tail
  # sites that it does not compile.
  @doc false
  def tail_value({:call, {:id, "eval"} = callee, args, false}, env) do
    case eval_call(callee, args, env) do
      {:value, v} -> {:ret, v}
      {:call, f, this, argv} -> {:tail, f, this, argv}
    end
  end

  def tail_value({:call, callee, args, false} = e, env) do
    plain? =
      case callee do
        # (an optional chain and a `super()` call are no tail calls)
        {:chain, _} -> false
        {:super} -> false
        _ -> true
      end

    if plain? do
      {f, this} = call_target(callee, env)
      argv = eval_list(args, env)

      # (the test of `function?/1` inline: `tail_loop/3` reads the callee again to run it,
      # and the error must come here, inside the frame of the caller)
      unless callable?(f),
        do: throw_error("TypeError", "#{describe(callee)} is not a function")

      {:tail, f, this, argv}
    else
      {:ret, ev(e, env)}
    end
  end

  def tail_value({:cond, c, a, b}, env),
    do: tail_value(if(truthy(ev(c, env)), do: a, else: b), env)

  def tail_value({:seq, es}, env) do
    {init, [last]} = Enum.split(es, -1)
    Enum.each(init, &ev(&1, env))
    tail_value(last, env)
  end

  def tail_value({:logical, op, l, r}, env) do
    lv = ev(l, env)

    take_right? =
      case op do
        "&&" -> truthy(lv)
        "||" -> not truthy(lv)
        "??" -> nullish?(lv)
      end

    if take_right?, do: tail_value(r, env), else: {:ret, lv}
  end

  def tail_value(e, env), do: {:ret, ev(e, env)}

  defp while_loop(c, body, env, labels, mode) do
    if truthy(ev(c, env)) do
      tick()

      case run_body(body, env, labels, mode) do
        :break -> :ok
        :next -> while_loop(c, body, env, labels, mode)
        exit -> loop_exit(exit)
      end
    else
      :ok
    end
  end

  # `fns` is the closure count from before this iteration's update expression ran (which
  # evaluates in the iteration's scope), so a closure made there keeps the scope alive too
  defp for_loop(test, update, body, env, iter_env, copy?, labels, fns, mode) do
    tick()

    if test == nil or truthy(ev(test, iter_env)) do
      case run_body(body, iter_env, labels, mode) do
        :break ->
          :ok

        :next ->
          next_env =
            if copy? and pget(:js_fns) != fns, do: copy_scope(iter_env, env), else: iter_env

          next_fns = pget(:js_fns)
          if update, do: ev(update, next_env)
          for_loop(test, update, body, env, next_env, copy?, labels, next_fns, mode)

        c ->
          loop_exit(c)
      end
    else
      :ok
    end
  end

  # What a loop does with the completion of its body: `:next` runs the next round, `:break`
  # ends the loop normally, and any other completion leaves the loop. `labels` are the
  # labels on this loop. A break or continue without a label always belongs to the
  # innermost loop or switch. `mode` says how the body runs (see `mode_exec/3`).
  defp run_body(body, env, labels, mode) do
    case mode_exec(body, env, mode) do
      :ok -> :next
      {:cont, l} = c -> if l == nil or l in labels, do: :next, else: c
      {:brk, l} = c -> if l == nil or l in labels, do: :break, else: c
      c -> c
    end
  end

  # A completion that leaves a loop. In check mode (K7 of step 3) it is never a break or a
  # continue without a label, because `run_body/4` gives these to the innermost loop.
  # It is public because the closure compiler (`Browser.JS.Compile`) calls it.
  @doc false
  @compile {:inline, loop_exit: 1}
  def loop_exit(c) do
    if @check and c in [{:brk, nil}, {:cont, nil}],
      do: check_fail("a loop gave back #{inspect(c)}")

    c
  end

  # ── binding ────────────────────────────────────────────────

  @doc false
  def bind_pattern(pat, v, env, mode), do: bind(pat, v, env, mode)

  defp bind({:id, name}, v, env, mode), do: bind_name(mode, env, name, v)

  # the slot forms as binding targets: a declaration writes the slot, a destructuring
  # assignment is an assignment and checks the temporal dead zone
  defp bind({:slot, d, i, name}, v, env, :assign), do: slot_assign(hop(env, d), i, name, v)

  defp bind({:slot, d, i, name}, v, env, _mode) do
    frame = hop(env, d)
    if @check, do: check_slot(frame, i, name)
    if @check, do: check_unsynced(frame, i)
    slot_put(frame, i, v)
  end

  # A mapped parameter as a binding target (`var a = 2`, `[a] = ...`, `for (a in o)`): the
  # write also reaches the arguments object (step 2d).
  defp bind({:mslot, d, i, name, k}, v, env, :assign),
    do: mslot_assign(hop(env, d), i, name, k, v)

  defp bind({:mslot, d, i, _name, k} = form, v, env, _mode) do
    frame = hop(env, d)
    if @check, do: check_landing(form, env)
    slot_put(frame, i, v)
    sync_mapped(frame, k, v)
  end

  # `arguments` as a binding target in sloppy code replaces the binding; the object and
  # its mapping stay as they are.
  defp bind({:aslot, d, i} = form, v, env, _mode) do
    if @check, do: check_landing(form, env)
    slot_put(hop(env, d), i, v)
  end

  defp bind({:cslot, d, i, name}, _v, env, _mode), do: cslot_assign(hop(env, d), i, name)
  defp bind({:fname, _, _, _}, _v, _env, _mode), do: :ok
  # A destructuring assignment or a for-in/of head takes its strictness from the function
  # that runs it. The root has `:strict` only while a strict script runs, so the write
  # must not read it there.
  defp bind({:gref, name}, v, env, :assign) do
    g = root(env)

    if lookup_var(env, :strict) == {:ok, true},
      do: strict_assign_var(g, name, v, resolvable?(g, name)),
      else: assign_var(g, name, v)
  end

  defp bind({:gref, name}, v, env, mode), do: bind_name(mode, root(env), name, v)
  defp bind({:mref, d, name}, v, env, mode), do: bind_name(mode, hop(env, d), name, v)

  defp bind({:default, pat, e}, v, env, mode),
    do: bind(pat, if(v == :undefined, do: ev_named(e, env, pat), else: v), env, mode)

  defp bind({:arrpat, elems}, v, env, mode) do
    case iter_source(v) do
      {:list, list} -> bind_elems(elems, list, env, mode)
      {:proto, it, next} -> bind_proto(elems, it, next, env, mode, false)
    end
  end

  defp bind({:objpat, props, rest}, v, env, mode) do
    if nullish?(v),
      do: throw_error("TypeError", "Cannot destructure '#{to_str(v)}' as it is #{to_str(v)}.")

    used =
      for {key, pat} <- props do
        k = key_of(key, env)
        ref = target_ref(pat, env, mode)
        bind_to(pat, ref, get(v, k), env, mode)
        k
      end

    if rest do
      pairs =
        for k <- Browser.JS.Props.rest_keys(v, used), do: {k, get(v, k)}

      bind(rest, new_object(pairs), env, mode)
    end

    :ok
  end

  defp bind({:member, _, _, _} = target, v, env, :assign), do: assign_to(target, v, env)

  defp bind_elems([], _, _, _), do: :ok
  defp bind_elems([{:rest, pat}], list, env, mode), do: bind(pat, new_array(list), env, mode)

  defp bind_elems([p | ps], list, env, mode) do
    {v, rest} =
      case list do
        [h | t] -> {h, t}
        [] -> {:undefined, []}
      end

    if p != nil, do: bind(p, v, env, mode)
    bind_elems(ps, rest, env, mode)
  end

  # an iterator object is pulled from one value per element, so that an endless one works
  # and the iterator is closed when the pattern leaves it before it is done
  defp bind_proto([], it, _next, _env, _mode, done?) do
    unless done?, do: iter_close(it, false)
    :ok
  end

  defp bind_proto([{:rest, pat}], it, next, env, mode, done?) do
    ref = guarded_ref(pat, env, mode, it, done?)
    list = if done?, do: [], else: pull(it, next, [])
    bind_to(pat, ref, new_array(list), env, mode)
  end

  defp bind_proto([p | ps], it, next, env, mode, done?) do
    # a property target is evaluated before the iterator is stepped
    ref = guarded_ref(p, env, mode, it, done?)

    {v, done?} =
      if done? do
        {:undefined, true}
      else
        case iter_step(it, next) do
          :done -> {:undefined, true}
          {:ok, item} -> {item, false}
        end
      end

    if p != nil do
      try do
        bind_to(p, ref, v, env, mode)
      catch
        kind, e ->
          unless done?, do: iter_close(it, true)
          :erlang.raise(kind, e, __STACKTRACE__)
      end
    end

    bind_proto(ps, it, next, env, mode, done?)
  end

  # the reference of a property target (`o[k]`, with or without a default), evaluated early;
  # a throw while evaluating it closes the iterator that is still open
  defp guarded_ref(pat, env, mode, it, done?) do
    target_ref(pat, env, mode)
  catch
    kind, e ->
      unless done?, do: iter_close(it, true)
      :erlang.raise(kind, e, __STACKTRACE__)
  end

  # the key is converted only when the value is stored (after the source was read)
  defp target_ref({:member, o, k, _}, env, :assign), do: {ev(o, env), ev_key(k, env), nil}

  defp target_ref({:default, {:member, o, k, _}, e}, env, :assign),
    do: {ev(o, env), ev_key(k, env), e}

  # a name target inside `with` is resolved before the value is read
  defp target_ref({:id, name}, env, mode) when mode not in [:let, :const] do
    if Process.get(:js_with_used, false), do: name_ref(name, env, mode, nil), else: nil
  end

  defp target_ref({:default, {:id, name}, e}, env, mode) when mode not in [:let, :const] do
    if Process.get(:js_with_used, false), do: name_ref(name, env, mode, e), else: nil
  end

  defp target_ref(_, _, _), do: nil

  defp name_ref(name, env, mode, dflt) do
    strict? = mode == :assign and lookup_var(env, :strict) == {:ok, true}
    {_, write} = id_ref(env, name, {:id, name}, strict?)
    {:name, write, dflt}
  end

  defp bind_to(pat, nil, v, env, mode), do: bind(pat, v, env, mode)

  defp bind_to(pat, {:name, write, dflt}, v, env, _mode) do
    v = if dflt != nil and v == :undefined, do: ev_named(dflt, env, pat), else: v
    write.(v)
  end

  defp bind_to(_pat, {ov, key, dflt}, v, env, _mode) do
    v = if dflt != nil and v == :undefined, do: ev(dflt, env), else: v
    put(ov, to_key(key), v)
  end

  defp bind_name(:let, env, name, v), do: declare(env, name, v)
  defp bind_name(:const, env, name, v), do: declare(env, name, v, true)
  # a destructuring assignment in strict code throws on a name that does not resolve
  defp bind_name(:assign, env, name, v) do
    if lookup_var(env, :strict) == {:ok, true},
      do: strict_assign_var(env, name, v, resolvable?(env, name)),
      else: assign_var(env, name, v)
  end

  defp bind_name(_, env, name, v), do: assign_var(env, name, v)

  defp key_of({:str, s}, _), do: s
  defp key_of({:computed, e}, env), do: to_key(ev(e, env))

  defp assign_to({:id, name}, v, env), do: assign_var(env, name, v)

  defp assign_to({:member, o, k, _}, v, env) do
    ov = ev(o, env)
    put(ov, ev_key(k, env), v)
  end

  defp ev_key({:str, s}, _), do: s
  defp ev_key({:priv, name}, env), do: private_key(name, env)
  defp ev_key(k, env), do: ev(k, env)

  # It is public because the closure compiler (`Browser.JS.Compile`) calls it.
  @doc false
  def bump(op, old) do
    case old do
      {:bigint, n} -> {:bigint, if(op == "++", do: n + 1, else: n - 1)}
      _ -> if op == "++", do: Num.add(old, 1.0), else: Num.sub(old, 1.0)
    end
  end

  # It is public because the closure compiler (`Browser.JS.Compile`) calls it.
  @doc false
  def uninit_this_error do
    throw_error(
      "ReferenceError",
      "Must call super constructor in derived class before accessing 'this' or returning from derived constructor"
    )
  end

  # It is public because the closure compiler (`Browser.JS.Compile`) calls it.
  @doc false
  def tdz_error(name),
    do: throw_error("ReferenceError", "Cannot access '#{name}' before initialization")

  defp const_error, do: throw_error("TypeError", "Assignment to constant variable.")

  # The root of the chain `env` is on (its realm's global scope). A frame keeps the root in
  # its header. A `{:gref}` can also run in a map scope under a frame (the class scope of a
  # heritage, a computed key or a field initializer), which must walk to a frame or the root.
  # It is public because the closure compiler (`Browser.JS.Compile`) calls it.
  @doc false
  def root(env) do
    if @check, do: check_live(env)

    case :erlang.get(env) do
      f when is_tuple(f) -> :erlang.element(5, f)
      _ -> root_of(env)
    end
  end

  # A write to a slot by an assignment: a binding still in its temporal dead zone takes no
  # value. A declaration pattern writes with `slot_put/3` directly.
  # It is public because the closure compiler (`Browser.JS.Compile`) calls it.
  @doc false
  def slot_assign(env, i, name, v) do
    if @check, do: check_slot(env, i, name)
    if @check, do: check_unsynced(env, i)

    case :erlang.element(i, :erlang.get(env)) do
      :tdz -> tdz_error(name)
      _ -> slot_put(env, i, v)
    end
  end

  # A write to a mapped parameter by an assignment (step 2d): the slot as `slot_assign/4`
  # writes it, then the element of the arguments object. A plain parameter is never in its
  # temporal dead zone, but the test keeps the order of `slot_assign/4`. The result is a
  # true value, because `compound_assign/5` joins the write and the value with `&&`.
  defp mslot_assign(env, i, name, k, v) do
    if @check, do: check_slot(env, i, name)

    case :erlang.element(i, :erlang.get(env)) do
      :tdz ->
        tdz_error(name)

      _ ->
        slot_put(env, i, v)
        sync_mapped(env, k, v)
    end
  end

  # a write to a `const` slot: the value is evaluated first, as today
  defp cslot_assign(env, i, name) do
    if @check, do: check_slot(env, i, name)

    case :erlang.element(i, :erlang.get(env)) do
      :tdz -> tdz_error(name)
      _ -> const_error()
    end
  end

  # The call fast path (step 5): one read of the heap finds the callee. A plain function
  # that the resolver rewrote runs its frame at once, as `call/3` and `run_closure/4` would
  # run it, but without the second read and the two extra calls. Every other function goes
  # to `call_obj/4` with the object that was read. The test that the callee is a function
  # and its error come first, in the order of `function?/1` and `call/3`. `callee` is the
  # node of the callee, for the text of the error, and `env` is the scope of the call site,
  # for the check build. The tree walker (`ev/2`) and the compiled calls (`ccall/5`) expand
  # this one macro, so the two paths call in the same way. (a macro and not an inline
  # function: `call_obj/4` is inline, and an inline function inside an inline function
  # stays a call, which would cost one reduction per JS call)
  defmacrop call_fast(f, this, argv, callee, env) do
    quote do
      case unquote(f) do
        {:obj, id} ->
          case :erlang.get(id) do
            %{class: :function, fun: {:closure, %{info: %Info{rewritten: true}} = c}} = o
            when not is_map_key(o, :generator) and not is_map_key(o, :async) and
                   not is_map_key(o, :class_info) ->
              if @check, do: check_link(unquote(env))
              tick()
              run_frame(id, c, unquote(this), unquote(argv), :undefined, :call)

            %{class: :function} = o ->
              if @check, do: check_link(unquote(env))
              call_obj(id, o, unquote(this), unquote(argv))

            # (a missing entry fails as `deref/1` fails)
            :undefined ->
              deref(id)

            _ ->
              throw_error("TypeError", "#{describe(unquote(callee))} is not a function")
          end

        _ ->
          throw_error("TypeError", "#{describe(unquote(callee))} is not a function")
      end
    end
  end

  # ── expressions ────────────────────────────────────────────

  # A compiled child (step 5): the compiler puts `{:cc, fun}` in the place of an expression
  # child of a node that stays on the tree, so the tree runs the closure.
  def ev({:cc, f}, env), do: f.(env)

  def ev({:num, n}, _), do: n
  def ev({:bigint, n}, _), do: {:bigint, n}

  def ev({:val, v}, _env), do: v

  # A hole of a compiled lift template (step 5c, `Browser.JS.Async.lifted/5`) in a part of
  # the template that stays on the tree: the value of the leaf `i`, which the process key
  # `:js_cps_vals` holds while the template runs.
  def ev({:cps_leaf, i}, _env), do: :erlang.element(i + 1, :erlang.get(:js_cps_vals))

  def ev({:destructure, pat, right}, env) do
    v = ev(right, env)
    bind(pat, v, env, :assign)
    v
  end

  def ev({:async, fun}, env), do: make_fn({:async, fun}, env)
  def ev({:gen, fun}, env), do: make_fn({:gen, fun}, env)

  if @check do
    # A frame runs its awaits in the CPS evaluator. The one legal sync await in a frame is
    # an await in a default of a catch parameter, which `Browser.JS.Async` marks with the
    # process key around it.
    def ev({:await, e}, env) do
      if is_integer(env) and is_tuple(:erlang.get(env)) and
           Process.get(:js_cps_sync_await) != true,
         do: check_fail("a sync await in a frame")

      Browser.JS.Promise.await(ev(e, env))
    end
  else
    def ev({:await, e}, env), do: Browser.JS.Promise.await(ev(e, env))
  end

  def ev({:regex, source, flags}, _env), do: Browser.JS.RegExp.new(source, flags)
  def ev({:str, s}, _), do: s
  def ev({:lit, v}, _), do: v

  def ev({:new_target}, env) do
    case lookup_var(env, :new_target) do
      {:ok, nt} -> nt
      _ -> :undefined
    end
  end

  def ev({:this}, env) do
    case lookup_var(env, :this) do
      {:ok, :uninit_this} -> uninit_this_error()
      {:ok, v} -> v
      :error -> :undefined
    end
  end

  # `import(specifier)`: a promise for the module's namespace (the host loads it)
  def ev({:import_call, e}, env), do: import_call(e, nil, env)
  def ev({:import_call, e, opts}, env), do: import_call(e, opts, env)
  def ev({:import_phase, phase, args}, env), do: import_phase(phase, args, env)

  def ev({:import_meta}, env) do
    url =
      case lookup_var(env, :module_url) do
        {:ok, b} -> b
        :error -> :undefined
      end

    # one object per module
    metas = Process.get(:js_import_metas) || %{}

    case metas do
      %{^url => meta} ->
        meta

      _ ->
        meta = new_object([{"url", url}])
        Process.put(:js_import_metas, Map.put(metas, url, meta))
        meta
    end
  end

  def ev({:class, _, _, _, _} = c, env), do: Browser.JS.Classes.define(c, env)

  def ev({:call, {:super}, args, _}, env),
    do: Browser.JS.Classes.super_call(eval_list(args, env), env)

  def ev({:super_member, key}, env) do
    {home, this} = Browser.JS.Classes.super_base(env)
    if home == :null, do: throw_error("TypeError", "Cannot read properties of null (super)")
    get_with_receiver(home, ev_key(key, env), this)
  end

  def ev({:id, "arguments"} = e, env) do
    # a cached `arguments` of an outer function must not leak into an inner function
    if args_shadowed?(env), do: lazy_arguments(env), else: ev_id(e, env)
  end

  def ev({:id, _} = e, env), do: ev_id(e, env)

  # The slot forms of the resolver (see `Browser.JS.Resolve`). A read of a slot at depth 0
  # is one `element/2` on the frame; a deeper one hops first. `{:gref}` and `{:mref}` are
  # today's by-name reads from the root or from the map scope the hop lands on, so their
  # semantics are today's by construction.
  def ev({:slot, 0, i, name} = form, env) do
    if @check, do: check_landing(form, env)

    case :erlang.element(i, :erlang.get(env)) do
      :tdz ->
        tdz_error(name)

      v ->
        # (only `{:aslot}` may meet the marker of an arguments object that is not built)
        if @check and match?({:unbuilt, _}, v),
          do: check_fail("{:slot} #{inspect(name)} reads an unbuilt arguments object")

        v
    end
  end

  def ev({:slot, d, i, name}, env), do: ev({:slot, 0, i, name}, hop(env, d))

  # The arguments object of a level 3 function (step 2d, rule R3): its hidden slot holds
  # `{:unbuilt, id}` until the first read, which builds the object into the slot. Only this
  # form reads the slot, so the generic slot read never meets the marker.
  def ev({:aslot, d, i} = form, env) do
    if @check, do: check_landing(form, env)
    frame = hop(env, d)

    case :erlang.element(i, :erlang.get(frame)) do
      {:unbuilt, fid} -> build_arguments(frame, i, fid)
      v -> v
    end
  end

  def ev({:this, d, i} = form, env) do
    if @check, do: check_landing(form, env)

    case :erlang.element(i, :erlang.get(hop(env, d))) do
      :uninit_this -> uninit_this_error()
      v -> v
    end
  end

  def ev({:gref, name} = form, env) do
    if @check, do: check_landing(form, env)
    ev_id({:id, name}, root(env))
  end

  def ev({:mref, d, name} = form, env) do
    if @check, do: check_landing(form, env)
    ev_id({:id, name}, hop(env, d))
  end

  # (the names of a `for (using x of e)` head hold `:tdz` in their own slots already)
  def ev({:in_tdz, _names, e}, env), do: ev(e, env)

  # the strings argument of a tagged template: an array with a `raw` twin
  # (made once for each place in the source and then reused)
  def ev({:tagged_strings, cooked, raw, site}, _env) do
    cache = Process.get(:js_template_sites) || %{}

    case cache do
      %{^site => strings} ->
        strings

      _ ->
        strings = new_array(cooked)
        raw = new_array(raw)
        Browser.JS.Props.lock(raw, true)
        put_hidden(strings, "raw", raw)
        Browser.JS.Props.lock(strings, true)
        Process.put(:js_template_sites, Map.put(cache, site, strings))
        strings
    end
  end

  def ev({:tmpl, parts}, env) do
    parts
    |> Enum.map(fn p -> if is_binary(p), do: p, else: to_str(ev(p, env)) end)
    |> Browser.JS.Str.join()
  end

  # an elision (`[1, , 3]`) leaves a hole: no element, but it counts in the length
  def ev({:array, elems}, env) do
    {items, len} =
      Enum.reduce(elems, {%{}, 0}, fn
        {:spread, e}, {m, i} ->
          vals = iterate(ev(e, env))

          m =
            vals |> Enum.with_index(i) |> Enum.reduce(m, fn {v, j}, acc -> Map.put(acc, j, v) end)

          {m, i + length(vals)}

        :hole, {m, i} ->
          {m, i + 1}

        n, {m, i} ->
          {Map.put(m, i, ev(n, env)), i + 1}
      end)

    {:obj, id} = arr = new_array([])
    store(id, %{deref(id) | items: items, len: len})
    arr
  end

  def ev({:object, props}, env) do
    obj = new_object()

    Enum.each(props, fn
      {:init, key, val} ->
        k = key_of(key, env)
        v = ev_named(val, env, if(fname = key_fn_name(k), do: {:id, fname}))
        if method_node?(val), do: name_fn(v, key_fn_name(k))
        method_home(v, obj)
        define_data(obj, k, v)

      {:proto, e} ->
        case ev(e, env) do
          {:obj, _} = p -> Browser.JS.Props.set_prototype_of(obj, p)
          :null -> Browser.JS.Props.set_prototype_of(obj, :null)
          _ -> :ok
        end

      {:spread, e} ->
        spread_into(obj, ev(e, env))

      {:getter, key, fun} ->
        k = key_of(key, env)
        f = ev(fun, env)
        method_home(f, obj)
        if fname = key_fn_name(k), do: accessor_name(f, "get " <> fname)
        Browser.JS.Props.define_accessor(obj, k, get: f)

      {:setter, key, fun} ->
        k = key_of(key, env)
        f = ev(fun, env)
        method_home(f, obj)
        if fname = key_fn_name(k), do: accessor_name(f, "set " <> fname)
        Browser.JS.Props.define_accessor(obj, k, set: f)
    end)

    obj
  end

  def ev({:fn, _, _, _, _, _} = f, env), do: make_fn(f, env)

  def ev({:seq, es}, env), do: Enum.reduce(es, :undefined, fn e, _ -> ev(e, env) end)

  def ev({:chain, e}, env) do
    ev(e, env)
  catch
    :js_short -> :undefined
  end

  def ev({:cond, c, a, b}, env), do: if(truthy(ev(c, env)), do: ev(a, env), else: ev(b, env))

  def ev({:logical, op, l, r}, env) do
    lv = ev(l, env)

    case op do
      "&&" -> if truthy(lv), do: ev(r, env), else: lv
      "||" -> if truthy(lv), do: lv, else: ev(r, env)
      "??" -> if nullish?(lv), do: ev(r, env), else: lv
    end
  end

  def ev({:unary, "typeof", {:slot, d, i, name} = form}, env) do
    if @check, do: check_landing(form, env)

    case :erlang.element(i, :erlang.get(hop(env, d))) do
      :tdz -> tdz_error(name)
      v -> typeof(v)
    end
  end

  # (an object that is not built yet is an object: the read does not need to build it)
  def ev({:unary, "typeof", {:aslot, d, i} = form}, env) do
    if @check, do: check_landing(form, env)

    case :erlang.element(i, :erlang.get(hop(env, d))) do
      {:unbuilt, _} -> "object"
      v -> typeof(v)
    end
  end

  def ev({:unary, "typeof", {:gref, name}}, env),
    do: ev({:unary, "typeof", {:id, name}}, root(env))

  def ev({:unary, "typeof", {:mref, d, name}}, env),
    do: ev({:unary, "typeof", {:id, name}}, hop(env, d))

  def ev({:unary, "typeof", {:id, name}}, env) do
    case lookup_var(env, name) do
      {:ok, :tdz} ->
        throw_error("ReferenceError", "Cannot access '#{name}' before initialization")

      {:ok, v} ->
        typeof(v)

      :error when name == "arguments" ->
        case lookup_var(env, :args) do
          {:ok, _} -> typeof(ev({:id, "arguments"}, env))
          :error -> "undefined"
        end

      :error ->
        with {:ok, v} <- Browser.JS.DOM.named_element(name),
             do: typeof(v),
             else: (_ -> "undefined")
    end
  end

  def ev({:unary, "delete", {:member, o, k, _}}, env) do
    ov = ev(o, env)
    key = ev_key(k, env)
    delete_base_check(ov, key)
    delete(ov, key)
  end

  # `delete super.x` is always a ReferenceError (the key is evaluated, never converted)
  def ev({:unary, d, {:super_member, key}}, env) when d in ["delete", "sdelete"] do
    Browser.JS.Classes.super_base(env)
    ev_key(key, env)
    throw_error("ReferenceError", "Unsupported reference to 'super'")
  end

  # a binding the resolver found in a frame or a map scope can not be deleted; one it did
  # not find is looked up from the root, as today
  # (`new.target` in a slot is a value, not a binding: `delete` evaluates it and is true)
  def ev({:unary, "delete", {:slot, _, _, :new_target} = e}, env) do
    ev(e, env)
    true
  end

  def ev({:unary, "delete", {k, _, _, _}}, _env) when k in [:slot, :cslot, :fname], do: false
  def ev({:unary, "delete", {:mref, _, _}}, _env), do: false
  def ev({:unary, "delete", {:aslot, _, _}}, _env), do: false

  def ev({:unary, "delete", {:gref, name}}, env),
    do: ev({:unary, "delete", {:id, name}}, root(env))

  # an identifier found on a `with` object is deleted from it
  def ev({:unary, "delete", {:id, name}}, env) do
    case with_binding(env, name) do
      {:with, obj} ->
        delete(obj, name)

      # a declared local binding can not be deleted
      {:var, sc} ->
        cond do
          # (a binding in a frame is a declared local)
          is_tuple(deref(sc)) ->
            false

          deref(sc).parent == nil and name in ["NaN", "Infinity", "undefined"] ->
            false

          # the arguments object of a function is a binding that cannot be deleted
          name == "arguments" and is_map_key(deref(sc).vars, :args) ->
            false

          eval_declared?(sc, name) ->
            st = deref(sc)

            store(sc, %{
              st
              | vars: Map.delete(st.vars, name),
                consts: MapSet.delete(st.consts, name)
            })

            true

          deref(sc).parent != nil ->
            false

          global_fixed?(name) or global_lexical?(name) ->
            false

          true ->
            case Browser.JS.Global.host_delete(:global, name) do
              :default -> delete(Map.get(deref(sc).vars, :this), name)
              r -> r
            end
        end

      # the arguments object that is not built yet is still a binding of the function
      nil when name == "arguments" ->
        not match?({:ok, _}, lookup_var(env, :args))

      _ ->
        true
    end
  end

  def ev({:unary, "delete", e}, env) do
    ev(e, env)
    true
  end

  # in strict code a delete that fails throws
  def ev({:unary, "sdelete", {:member, o, k, _}}, env) do
    ov = ev(o, env)
    key = ev_key(k, env)
    delete_base_check(ov, key)

    if delete(ov, key) == false,
      do: throw_error("TypeError", "Cannot delete property '#{to_str(key)}'"),
      else: true
  end

  def ev({:unary, "sdelete", _}, _), do: true

  def ev({:unary, op, e}, env) do
    v = ev(e, env)

    case op do
      "!" ->
        not truthy(v)

      "-" ->
        case numeric(v) do
          {:bigint, n} -> {:bigint, -n}
          n -> Num.neg(n)
        end

      "+" ->
        to_num(v)

      "~" ->
        case numeric(v) do
          {:bigint, n} -> {:bigint, Bitwise.bnot(n)}
          n -> (Num.int32(n) |> Bitwise.bnot()) * 1.0
        end

      "typeof" ->
        typeof(v)

      "void" ->
        :undefined
    end
  end

  def ev({:binary, "in", {:priv_ref, name}, r}, env) do
    key = private_key(name, env)

    case ev(r, env) do
      {:obj, id} ->
        Obj.has_own?(deref(id), key)

      _ ->
        throw_error(
          "TypeError",
          "Cannot use 'in' operator to search for a private field in a non-object"
        )
    end
  end

  def ev({:binary, op, l, r}, env), do: binop(op, ev(l, env), ev(r, env))

  def ev({:update, op, prefix?, {:super_member, k}}, env),
    do: super_update(op, prefix?, k, env, false)

  def ev({:supdate, op, prefix?, {:super_member, k}}, env),
    do: super_update(op, prefix?, k, env, true)

  def ev({:assign, "=", {:super_member, k}, value}, env), do: super_assign(k, value, env, false)
  def ev({:sassign, "=", {:super_member, k}, value}, env), do: super_assign(k, value, env, true)

  # `++a[k]`: the object and the key are evaluated (and the key converted) once
  def ev({:update, op, prefix?, {:member, o, k, _}}, env) do
    ov = ev(o, env)
    raw = ev_key(k, env)

    if nullish?(ov),
      do: throw_error("TypeError", "Cannot read properties of #{to_str(ov)}")

    key = prop_key(raw)
    old = numeric(get(ov, key))
    new = bump(op, old)
    put(ov, key, new)
    if prefix?, do: new, else: old
  end

  def ev({:update, op, prefix?, {:id, name} = target}, env) do
    if Process.get(:js_with_used, false) do
      {read, write} = id_ref(env, name, target, false)
      old = numeric(read.())
      new = bump(op, old)
      write.(new)
      if prefix?, do: new, else: old
    else
      old = numeric(ev(target, env))
      new = bump(op, old)
      assign_to(target, new, env)
      if prefix?, do: new, else: old
    end
  end

  def ev({:update, op, prefix?, {:slot, d, i, _} = target}, env) do
    old = numeric(ev(target, env))
    new = bump(op, old)
    slot_put(hop(env, d), i, new)
    if prefix?, do: new, else: old
  end

  # A write to a mapped parameter also writes the element of the arguments object that it
  # is mapped to (step 2d).
  def ev({:update, op, prefix?, {:mslot, d, i, name, k}}, env) do
    frame = hop(env, d)
    old = numeric(ev({:slot, 0, i, name}, frame))
    new = bump(op, old)
    mslot_assign(frame, i, name, k, new)
    if prefix?, do: new, else: old
  end

  def ev({:update, op, prefix?, {:aslot, d, i} = target}, env) do
    old = numeric(ev(target, env))
    new = bump(op, old)
    slot_put(hop(env, d), i, new)
    if prefix?, do: new, else: old
  end

  def ev({:update, op, _prefix?, {:cslot, d, i, name}}, env) do
    old = numeric(ev({:slot, d, i, name}, env))
    _new = bump(op, old)
    const_error()
  end

  def ev({:update, op, prefix?, {:fname, d, i, name}}, env) do
    # (a sloppy function's own name takes no write)
    old = numeric(ev({:slot, d, i, name}, env))
    new = bump(op, old)
    if prefix?, do: new, else: old
  end

  def ev({:update, op, prefix?, {:gref, name}}, env),
    do: ev({:update, op, prefix?, {:id, name}}, root(env))

  def ev({:update, op, prefix?, {:mref, d, name}}, env),
    do: ev({:update, op, prefix?, {:id, name}}, hop(env, d))

  # `f()++`: the operand is evaluated, then it is no reference
  def ev({:update, _op, _prefix?, target}, env) do
    ev(target, env)
    throw_error("ReferenceError", "Invalid left-hand side expression in update operation")
  end

  def ev({:assign, "=", {:id, name}, value}, env) do
    if Process.get(:js_with_used, false) do
      {_, write} = id_ref(env, name, {:id, name}, false)
      v = ev_named(value, env, {:id, name})
      write.(v)
      v
    else
      # the reference is made before the right-hand side runs: an `eval("var x")` in it
      # declares a new `x` that this assignment must not reach
      home = if simple_value?(value), do: nil, else: with_binding(env, name)
      v = ev_named(value, env, {:id, name})

      case home do
        {:var, scope} -> assign_var(scope, name, v)
        _ -> assign_var(env, name, v)
      end

      v
    end
  end

  def ev({:unnamed, e}, env), do: ev(e, env)

  # the expression of a `for (using x of …)` head sees `x` uninitialized
  def ev({:tdz_names, names, e}, env) do
    scope = new_scope(env)
    for n <- names, do: declare(scope, n, :tdz)
    ev(e, scope)
  end

  def ev({:assign, "=", {:member, o, k, _}, value}, env) do
    ov = ev(o, env)
    key = ev_key(k, env)
    v = ev(value, env)
    put(ov, key, v)
    v
  end

  def ev({:assign, "=", {:slot, d, i, name} = target, value}, env) do
    v = ev_named(value, env, target)
    slot_assign(hop(env, d), i, name, v)
    v
  end

  def ev({:assign, "=", {:mslot, d, i, name, k} = target, value}, env) do
    v = ev_named(value, env, target)
    mslot_assign(hop(env, d), i, name, k, v)
    v
  end

  # Sloppy code may assign `arguments`: the binding changes, the object and its mapping
  # stay.
  def ev({:assign, "=", {:aslot, d, i} = target, value}, env) do
    v = ev_named(value, env, target)
    if @check, do: check_landing(target, env)
    slot_put(hop(env, d), i, v)
    v
  end

  def ev({:assign, "=", {:cslot, d, i, name} = target, value}, env) do
    ev_named(value, env, target)
    cslot_assign(hop(env, d), i, name)
  end

  def ev({:assign, "=", {:fname, _, _, _} = target, value}, env),
    do: ev_named(value, env, target)

  def ev({:assign, "=", {:gref, name}, value}, env) do
    v = ev_named(value, env, {:id, name})
    assign_var(root(env), name, v)
    v
  end

  def ev({:assign, "=", {:mref, d, name}, value}, env) do
    v = ev_named(value, env, {:id, name})
    assign_var(hop(env, d), name, v)
    v
  end

  def ev({:assign, op, target, value}, env), do: compound_assign(op, target, value, env, false)

  # assignments in strict code: a failed [[Set]] or an undeclared name throws
  def ev({:sassign, "=", {:id, name}, value}, env) do
    if Process.get(:js_with_used, false) do
      {_, write} = id_ref(env, name, {:id, name}, true)
      v = ev_named(value, env, {:id, name})
      write.(v)
      v
    else
      resolved? = resolvable?(env, name)
      v = ev_named(value, env, {:id, name})
      # the binding may have been deleted while the right-hand side ran
      strict_assign_var(
        env,
        name,
        v,
        resolved? and (simple_value?(value) or resolvable?(env, name))
      )

      v
    end
  end

  def ev({:sassign, "=", {:member, o, k, _}, value}, env) do
    ov = ev(o, env)
    key = ev_key(k, env)
    v = ev(value, env)
    strict_put(ov, key, v)
  end

  def ev({:sassign, "=", {k, _, _, _} = target, value}, env) when k in [:slot, :cslot, :fname],
    do: ev({:assign, "=", target, value}, env)

  def ev({:sassign, "=", {:mslot, _, _, _, _} = target, value}, env),
    do: ev({:assign, "=", target, value}, env)

  def ev({:sassign, "=", {:gref, name}, value}, env) do
    root = root(env)
    resolved? = resolvable?(root, name)
    v = ev_named(value, env, {:id, name})
    # the binding may have been deleted while the right-hand side ran
    strict_assign_var(
      root,
      name,
      v,
      resolved? and (simple_value?(value) or resolvable?(root, name))
    )

    v
  end

  def ev({:sassign, "=", {:mref, d, name}, value}, env) do
    target = hop(env, d)
    resolved? = resolvable?(target, name)
    v = ev_named(value, env, {:id, name})

    strict_assign_var(
      target,
      name,
      v,
      resolved? and (simple_value?(value) or resolvable?(target, name))
    )

    v
  end

  def ev({:sassign, op, target, value}, env), do: compound_assign(op, target, value, env, true)

  def ev({:supdate, op, prefix?, {:member, o, k, _}}, env) do
    ov = ev(o, env)
    raw = ev_key(k, env)

    if nullish?(ov),
      do: throw_error("TypeError", "Cannot read properties of #{to_str(ov)}")

    key = prop_key(raw)
    old = numeric(get(ov, key))
    new = bump(op, old)
    strict_put(ov, key, new)
    if prefix?, do: new, else: old
  end

  def ev({:supdate, op, prefix?, {:id, name} = target}, env) do
    old = numeric(ev(target, env))
    new = bump(op, old)
    strict_assign_var(env, name, new, resolvable?(env, name))
    if prefix?, do: new, else: old
  end

  def ev({:supdate, op, prefix?, {k, _, _, _} = target}, env) when k in [:slot, :cslot, :fname],
    do: ev({:update, op, prefix?, target}, env)

  def ev({:supdate, op, prefix?, {:mslot, _, _, _, _} = target}, env),
    do: ev({:update, op, prefix?, target}, env)

  def ev({:supdate, op, prefix?, {:gref, name}}, env),
    do: ev({:supdate, op, prefix?, {:id, name}}, root(env))

  def ev({:supdate, op, prefix?, {:mref, d, name}}, env),
    do: ev({:supdate, op, prefix?, {:id, name}}, hop(env, d))

  def ev({:member, o, k, opt}, env) do
    ov = ev(o, env)
    if opt and nullish?(ov), do: throw(:js_short)
    get(ov, ev_key(k, env))
  end

  # `eval(...)` where `eval` is the built-in function runs in the caller's scope
  def ev({:call, {:id, "eval"} = callee, args, false}, env) do
    case eval_call(callee, args, env) do
      {:value, v} -> v
      {:call, f, this, argv} -> call(f, this, argv)
    end
  end

  def ev({:call, callee, args, opt}, env) do
    {f, this} = call_target(callee, env)

    if opt and nullish?(f), do: throw(:js_short)
    # the arguments are evaluated before the callee is checked
    argv = eval_list(args, env)
    call_fast(f, this, argv, callee, env)
  end

  def ev({:new, callee, args}, env) do
    f = ev(callee, env)
    # the arguments are evaluated before the callee is checked
    argv = eval_list(args, env)

    unless function?(f) and constructor?(f),
      do: throw_error("TypeError", "#{describe(callee)} is not a constructor")

    if @check, do: check_link(env)
    construct(f, argv)
  end

  @doc false
  # The call of `f` with `this` and the argument values `argv` at a call site. It is the
  # code of `call_fast/5` in a function of its own, for the compiled calls of
  # `Browser.JS.Compile`. `callee` is the node of the callee, and `env` is the scope of the
  # call site.
  def ccall(f, this, argv, callee, env), do: call_fast(f, this, argv, callee, env)

  # A call whose callee is the name `eval` (EvaluateCall). The callee is read one time,
  # through `call_target/2`, so a function that a `with` object holds gets that object as
  # `this`. The arguments are evaluated before the callee is examined. When the callee is
  # the built-in `eval`, the call is a direct eval and the result is `{:value, v}`. Else the
  # result is `{:call, f, this, args}`, and the caller makes the call. The plain call and
  # the tail call share this function, so they read the callee the same number of times and
  # give the same `this`.
  defp eval_call(callee, args, env) do
    {f, this} = call_target(callee, env)
    argv = eval_list(args, env)

    if f == :erlang.get(:js_eval_fn) do
      {:value, direct_eval(argv, env)}
    else
      unless function?(f), do: throw_error("TypeError", "eval is not a function")
      {:call, f, this, argv}
    end
  end

  # ── direct eval ────────────────────────────────────────────

  @doc false
  def direct_eval([src | _], env) when is_binary(src) do
    ctx = %{
      strict: lookup_var(env, :strict) == {:ok, true},
      new_target: match?({:ok, _}, lookup_var(env, :new_target)),
      super_prop: match?({:ok, {:obj, _}}, lookup_var(env, :home)),
      super_call: match?({:ok, _}, lookup_var(env, :ctor_fn)),
      private: private_names_in(env, []),
      field_init: in_field_initializer?(env)
    }

    opts = [
      eval: true,
      strict: ctx.strict,
      new_target: ctx.new_target,
      super_prop: ctx.super_prop,
      super_call: ctx.super_call,
      private: ctx.private,
      no_arguments: ctx.field_init
    ]

    case Browser.JS.Parser.parse(src, opts) do
      {:error, msg} -> throw_error("SyntaxError", msg)
      {:ok, {:program, stmts}} -> run_eval(stmts, env, ctx.strict)
    end
  end

  def direct_eval([other | _], _env), do: other
  def direct_eval([], _env), do: :undefined

  # is the code in a class field initializer (arrow functions inside it count, functions do not)?
  defp in_field_initializer?(nil), do: false

  defp in_field_initializer?(env) do
    case deref(env) do
      # A function that is not an arrow ends the walk: its own code is no initializer. An
      # arrow frame and a block frame go on to the parent, as an arrow's map scope does.
      f when is_tuple(f) ->
        case :erlang.element(2, f) do
          %Info{kind: k} when k not in [:arrow, :arrow_expr] -> false
          _ -> in_field_initializer?(:erlang.element(1, f))
        end

      s ->
        cond do
          Map.has_key?(s.vars, :field_init) -> true
          Map.has_key?(s.vars, :args) -> false
          true -> in_field_initializer?(s.parent)
        end
    end
  end

  # the private names (`#x`) declared by the classes around `env` (a frame holds none)
  defp private_names_in(nil, acc), do: acc

  defp private_names_in(env, acc) do
    case deref(env) do
      f when is_tuple(f) ->
        private_names_in(:erlang.element(1, f), acc)

      s ->
        acc = for({:priv, n} <- Map.keys(s.vars), do: n) ++ acc
        private_names_in(s.parent, acc)
    end
  end

  # Runs eval code: `var`s and functions go to the caller's function scope (sloppy code) while
  # `let`, `const` and classes stay in a scope of the eval's own; strict eval keeps everything.
  defp run_eval(stmts, env, caller_strict?) do
    strict? = caller_strict? or match?([{:expr, {:str, "use strict"}} | _], stmts)
    before = pget(:js_fns)
    lex = new_scope(env)
    var_scope = if strict?, do: lex, else: variable_scope(env)

    if strict?, do: declare(lex, :strict, true)

    s = deref(var_scope)

    if not strict? and Map.has_key?(s.vars, :in_params) and Map.has_key?(s.vars, :args) and
         "arguments" in hoisted_names(stmts),
       do: throw_error("SyntaxError", "Identifier 'arguments' has already been declared")

    var_names = hoisted_names(stmts)
    fun_decls = fundecls(stmts)

    # in a parameter expression a `var` may not take the name of a parameter
    if not strict? and Map.has_key?(s.vars, :in_params) do
      for n <- var_names ++ Enum.map(fun_decls, &elem(&1, 0)),
          Map.has_key?(s.vars, n),
          do: throw_error("SyntaxError", "Identifier '#{n}' has already been declared")
    end

    if not strict?, do: eval_declaration_checks(env, var_scope, var_names, fun_decls)

    fresh =
      for n <- var_names ++ Enum.map(fun_decls, &elem(&1, 0)), not Map.has_key?(s.vars, n), do: n

    vars = Enum.reduce(var_names, s.vars, fn n, m -> Map.put_new(m, n, :undefined) end)
    store(var_scope, %{s | vars: vars})

    # what a sloppy eval creates (rather than finds) can be deleted again
    if not strict? and fresh != [] do
      st = deref(var_scope)

      store(
        var_scope,
        Map.put(
          st,
          :evalvars,
          MapSet.union(Map.get(st, :evalvars, MapSet.new()), MapSet.new(fresh))
        )
      )
    end

    for {name, fun} <- fun_decls do
      f = make_fn(fun, lex, false)
      declare(var_scope, name, f)
      if not strict?, do: reopen_global_property(var_scope, name, f)
    end

    for stmt <- stmts, name <- lexical_names(unexport(stmt)), do: declare(lex, name, :tdz)

    # The completion value of the eval code is the result of the call, not a value of the
    # caller: the caller's value comes back, so that an eval inside a function cannot change
    # the completion value of the script.
    caller_last = :erlang.put(:js_last, :undefined)
    top_completion(exec_list(stmts, lex))
    result = Process.get(:js_last, :undefined)
    :erlang.put(:js_last, caller_last)
    free_scope(lex, before)
    result
  end

  @doc false
  # an indirect eval is global code: `var`s and functions go to the global scope (sloppy) and
  # `let`/`const`/class stay in a scope of its own
  def indirect_eval({:program, stmts}), do: run_eval(stmts, global(), false)

  # a function declared by sloppy eval at global level replaces a configurable global property
  # by a fully open data property holding the function
  defp reopen_global_property(scope, name, f) do
    with %{parent: nil, vars: %{this: {:obj, gid}}} <- deref(scope),
         g = deref(gid),
         true <- Obj.has_own?(g, name),
         true <- Obj.configurable?(g, name) do
      store(gid, Obj.reopen(g, name, f))
    end

    :ok
  end

  defp eval_declared?(scope, name),
    do: MapSet.member?(Map.get(deref(scope), :evalvars, MapSet.new()), name)

  # EvalDeclarationInstantiation: a `var` may not hoist over a lexical binding of a block it
  # is written in (or a global `let`/`const`/class), and the global object has to be able to
  # take the declared names
  defp eval_declaration_checks(env, var_scope, var_names, fun_decls) do
    names = var_names ++ Enum.map(fun_decls, &elem(&1, 0))

    clash = fn n ->
      throw_error("SyntaxError", "Identifier '#{n}' has already been declared")
    end

    lower =
      Stream.iterate(env, &deref(&1).parent)
      |> Enum.take_while(&(&1 != var_scope and &1 != nil))

    for sc <- lower, n <- names do
      st = deref(sc)

      if Map.has_key?(st.vars, n) and Map.get(st.vars, :catch_param) != n, do: clash.(n)
    end

    vs = deref(var_scope)
    for n <- names, MapSet.member?(Map.get(vs, :lex, MapSet.new()), n), do: clash.(n)

    # a function body's own let/const/class names (not tracked per call)
    body_lex =
      with false <- Map.has_key?(vs.vars, :in_params),
           fid when fid != nil <- Map.get(vs, :fid),
           %{fun: {:closure, %{body: body}}} when is_list(body) <- deref(fid) do
        Enum.flat_map(body, fn stmt ->
          case unexport(stmt) do
            {:classdecl, name, _} -> [name]
            other -> lexical_names(other)
          end
        end)
      else
        _ -> []
      end

    for n <- names, n in body_lex, do: clash.(n)

    if vs.parent == nil do
      for n <- names, global_lexical?(n), do: clash.(n)
      check_global_declarable(var_names, fun_decls)
    end

    :ok
  end

  # CanDeclareGlobalFunction / CanDeclareGlobalVar: a declaration must not conflict with a
  # property of the global object that cannot be redefined, nor add one to a sealed object
  defp check_global_declarable(var_names, fun_decls) do
    g = Map.get(deref(global()).vars, :this)

    for {n, _} <- fun_decls do
      ok =
        case Browser.JS.Props.own_state(g, n) do
          nil -> Browser.JS.Props.extensible?(g)
          {_, _, _, _, true} -> true
          {:data, _, true, true, _} -> true
          _ -> false
        end

      unless ok, do: throw_error("TypeError", "Cannot declare global function '#{n}'")
    end

    for n <- var_names do
      if Browser.JS.Props.own_state(g, n) == nil and not Browser.JS.Props.extensible?(g),
        do: throw_error("TypeError", "Cannot declare global variable '#{n}'")
    end

    :ok
  end

  # the nearest function scope (or the global one) from `env` outwards
  defp variable_scope(env) do
    case deref(env) do
      # (a function frame is a function scope; a block frame of step 2c is not)
      f when is_tuple(f) ->
        if match?(%Info{}, :erlang.element(2, f)),
          do: env,
          else: variable_scope(:erlang.element(1, f))

      s ->
        if Map.get(s, :fnscope, false) or s.parent == nil,
          do: env,
          else: variable_scope(s.parent)
    end
  end

  # a method written in an object literal finds `super` through the object
  # It is public because the closure compiler (`Browser.JS.Compile`) calls it.
  @doc false
  def method_home({:obj, id} = f, obj) do
    case deref(id) do
      %{fun: {:closure, %{name: {:method, _}}}} -> set_home(f, obj)
      _ -> :ok
    end
  end

  def method_home(_, _), do: :ok

  defp super_assign(k, value, env, strict?) do
    {base, this} = Browser.JS.Classes.super_base(env)
    raw = ev_key(k, env)
    v = ev(value, env)
    key = to_key(raw)

    if base == :null,
      do: throw_error("TypeError", "Cannot set properties of null (setting '#{to_str(key)}')")

    super_put(base, key, v, this, strict?)
  end

  defp super_update(op, prefix?, k, env, strict?) do
    {base, this} = Browser.JS.Classes.super_base(env)
    key = to_key(ev_key(k, env))
    old = numeric(get_with_receiver(base, key, this))

    new =
      case old do
        {:bigint, n} -> {:bigint, if(op == "++", do: n + 1, else: n - 1)}
        _ -> if op == "++", do: Num.add(old, 1.0), else: Num.sub(old, 1.0)
      end

    super_put(base, key, new, this, strict?)
    if prefix?, do: new, else: old
  end

  # [[Set]] on the super base with `this` as the receiver: a setter on the chain runs with
  # `this`; a data property (or none) is written onto the receiver
  defp super_put(base, key, v, this, strict?) do
    if strict?, do: :erlang.put(:js_put_failed, false)
    super_set(base, key, v, this)

    if strict? and :erlang.get(:js_put_failed) == true do
      :erlang.put(:js_put_failed, false)
      throw_error("TypeError", "Cannot assign to read only property '#{to_str(key)}'")
    end

    v
  end

  defp super_set({:obj, id} = o, key, v, this) do
    case Browser.JS.Props.own_state(o, key) do
      nil ->
        super_set(deref(id).proto, key, v, this)

      {:accessor, _, setter, _, _} ->
        if function?(setter), do: keep_put_flag(call(setter, this, [v])), else: fail_put()

      {:data, _, false, _, _} ->
        fail_put()

      {:data, _, _, _, _} ->
        super_receiver_put(this, key, v)
    end
  end

  defp super_set(_, key, v, this), do: super_receiver_put(this, key, v)

  # the receiver is asked for its own property first: that evaluates a deferred namespace
  defp super_receiver_put({:obj, id} = this, key, v) do
    if match?(%{class: :host, host: {Browser.JS.Modules, _}}, deref(id)),
      do: Browser.JS.Props.own_state(this, key)

    put(this, key, v)
  end

  defp super_receiver_put(this, key, v), do: put(this, key, v)

  # the reference of a name, resolved once: a `with` object keeps receiving the write even if
  # the property is gone by then. Returns the reader and the writer.
  defp id_ref(env, name, target, strict?) do
    case with_binding(env, name) do
      {:with, obj} ->
        {fn ->
           # GetBindingValue asks again whether the binding is still there
           cond do
             has_property?(obj, name) -> get(obj, name)
             strict? -> throw_error("ReferenceError", "#{name} is not defined")
             true -> :undefined
           end
         end,
         fn v ->
           # SetMutableBinding asks again whether the binding is still there
           still? = has_property?(obj, name)

           if strict? do
             unless still?, do: throw_error("ReferenceError", "#{name} is not defined")

             strict_put(obj, name, v)
           else
             put(obj, name, v)
           end
         end}

      {:var, sid} ->
        {fn -> ev(target, sid) end,
         fn v ->
           if strict?,
             do: strict_assign_var(sid, name, v, true),
             else: assign_var(sid, name, v)
         end}

      nil ->
        {fn -> ev(target, env) end,
         fn v ->
           if strict?,
             do: strict_assign_var(env, name, v, false),
             else: assign_var(env, name, v)
         end}
    end
  end

  defp compound_assign(op, target, value, env, strict?) do
    # evaluate the target's object and key once
    {read, write} = compound_ref(target, env, strict?)
    old = read.()
    base = binary_part(op, 0, byte_size(op) - 1)

    result =
      case base do
        "&&" -> if truthy(old), do: {:set, ev_named(value, env, target)}, else: :keep
        "||" -> if truthy(old), do: :keep, else: {:set, ev_named(value, env, target)}
        "??" -> if nullish?(old), do: {:set, ev_named(value, env, target)}, else: :keep
        _ -> {:set, binop(base, old, ev(value, env))}
      end

    case result do
      :keep -> old
      {:set, v} -> write.(v) && v
    end
  end

  @doc false
  # The reference of a compound assignment target: a read function and a write function.
  # The object and the key of the target are evaluated here, one time. It is public because
  # the CPS evaluator (`Browser.JS.Async`) reads the target of a logical assignment before
  # its right side awaits.
  def compound_ref(target, env, strict?) do
    case target do
      {:id, name} ->
        id_ref(env, name, target, strict?)

      {:slot, d, i, name} ->
        frame = hop(env, d)
        {fn -> ev({:slot, 0, i, name}, frame) end, fn v -> slot_assign(frame, i, name, v) end}

      {:cslot, d, i, name} ->
        frame = hop(env, d)
        {fn -> ev({:slot, 0, i, name}, frame) end, fn _ -> cslot_assign(frame, i, name) end}

      {:mslot, d, i, name, k} ->
        frame = hop(env, d)

        {fn -> ev({:slot, 0, i, name}, frame) end, fn v -> mslot_assign(frame, i, name, k, v) end}

      {:aslot, d, i} ->
        frame = hop(env, d)
        {fn -> ev({:aslot, 0, i}, frame) end, fn v -> slot_put(frame, i, v) end}

      {:fname, d, i, name} ->
        {fn -> ev({:slot, d, i, name}, env) end, fn _ -> :ok end}

      {:gref, name} ->
        id_ref(root(env), name, {:id, name}, strict?)

      {:mref, d, name} ->
        id_ref(hop(env, d), name, {:id, name}, strict?)

      {:super_member, k} ->
        {base, this} = Browser.JS.Classes.super_base(env)
        key = to_key(ev_key(k, env))

        {fn -> get_with_receiver(base, key, this) end,
         fn v -> super_put(base, key, v, this, strict?) end}

      {:member, o, k, _} ->
        ov = ev(o, env)
        key = ev_key(k, env)

        if nullish?(ov),
          do:
            throw_error(
              "TypeError",
              "Cannot read properties of #{to_str(ov)} (reading '#{safe_key(key)}')"
            )

        # the key is converted once, for the read and for the write
        key = prop_key(key)

        {fn -> get(ov, key) end,
         fn v -> if strict?, do: strict_put(ov, key, v), else: put(ov, key, v) end}
    end
  end

  defp delete_base_check(base, key) when base in [:null, :undefined],
    do:
      throw_error(
        "TypeError",
        "Cannot convert undefined or null to object (delete #{to_str(key)})"
      )

  defp delete_base_check(_, _), do: :ok

  @doc false
  # The name of a callee node in an error text. It is public because the closure compiler
  # (`Browser.JS.Compile`) calls it. (`describe/1` stays private, because modules that
  # import this module have functions of that name)
  def describe_node(e), do: describe(e)

  defp describe({:id, n}), do: n
  defp describe({:member, o, {:str, k}, _}), do: describe(o) <> "." <> k
  defp describe({:member, o, _, _}), do: describe(o) <> "[...]"
  defp describe({:this}), do: "this"
  # (the slot forms of the resolver keep the name, so `g is not a function` keeps it too)
  defp describe({k, _, _, n}) when k in [:slot, :cslot, :fname] and is_binary(n), do: n
  defp describe({:mslot, _, _, n, _}), do: n
  defp describe({:aslot, _, _}), do: "arguments"
  defp describe({:mref, _, n}), do: n
  defp describe({:gref, n}), do: n
  defp describe({:this, _, _}), do: "this"
  defp describe(_), do: "expression"

  # The values of an argument list, from left to right. Each value is bound before the
  # recursive call, because Erlang does not define the order in which the parts of a list
  # expression are evaluated. Plain recursion is faster than `Enum.flat_map/2` with a fun,
  # and a call evaluates an argument list every time.
  @doc false
  # It is public because the closure compiler (`Browser.JS.Compile`) calls it for an
  # argument list with a spread or a hole.
  def eval_list([], _env), do: []

  def eval_list([{:spread, e} | rest], env) do
    vs = iterate(ev(e, env))
    vs ++ eval_list(rest, env)
  end

  def eval_list([:hole | rest], env), do: [:undefined | eval_list(rest, env)]

  def eval_list([n | rest], env) do
    v = ev(n, env)
    [v | eval_list(rest, env)]
  end

  defp spread_into(obj, src) do
    unless nullish?(src) or not match?({:obj, _}, src),
      do:
        for(
          k <- Browser.JS.Props.enumerable_own_keys(src),
          do: define_data(obj, k, get(src, k))
        )

    :ok
  end

  # ── operators ──────────────────────────────────────────────

  # plain numbers (never NaN or infinite: those are atoms) skip the conversions
  def binop("+", a, b) when is_float(a) and is_float(b), do: Num.add(a, b)
  def binop("-", a, b) when is_float(a) and is_float(b), do: Num.add(a, -b)
  def binop("*", a, b) when is_float(a) and is_float(b), do: Num.mul(a, b)
  def binop("<", a, b) when is_float(a) and is_float(b), do: a < b
  def binop(">", a, b) when is_float(a) and is_float(b), do: a > b
  def binop("<=", a, b) when is_float(a) and is_float(b), do: a <= b
  def binop(">=", a, b) when is_float(a) and is_float(b), do: a >= b

  def binop("+", a, b) do
    a = to_primitive(a, "default")
    b = to_primitive(b, "default")

    cond do
      is_binary(a) or is_binary(b) -> Browser.JS.Str.cat(to_str(a), to_str(b))
      big?(a) or big?(b) -> Browser.JS.BigInt.arith("+", a, b)
      true -> Num.add(to_num(a), to_num(b))
    end
  end

  def binop(op, a, b) when op in ["-", "*", "/", "%", "**"] do
    a = numeric(a)
    b = numeric(b)

    if big?(a) or big?(b) do
      Browser.JS.BigInt.arith(op, a, b)
    else
      case op do
        "-" -> Num.sub(a, b)
        "*" -> Num.mul(a, b)
        "/" -> Num.div(a, b)
        "%" -> Num.mod(a, b)
        "**" -> Num.pow(a, b)
      end
    end
  end

  def binop("===", a, b), do: strict_eq(a, b)
  def binop("!==", a, b), do: not strict_eq(a, b)
  def binop("==", a, b), do: loose_eq(a, b)
  def binop("!=", a, b), do: not loose_eq(a, b)
  def binop("<", a, b), do: compare(a, b) == :lt
  def binop(">", a, b), do: compare(a, b) == :gt
  def binop("<=", a, b), do: compare(a, b) in [:lt, :eq]
  def binop(">=", a, b), do: compare(a, b) in [:gt, :eq]

  def binop(op, a, b) when op in ["&", "|", "^", "<<", ">>", ">>>"] do
    a = numeric(a)
    b = numeric(b)

    cond do
      big?(a) or big?(b) -> Browser.JS.BigInt.arith(op, a, b)
      op in ["&", "|", "^"] -> Num.bitop(op, a, b)
      true -> Num.shift(op, a, b)
    end
  end

  def binop("in", a, b), do: has_property?(b, a)
  def binop("instanceof", a, b), do: instance_of?(a, b)
  # an anonymous function or class takes the name of the binding or property it is assigned to
  def ev_named({:fn, nil, _, _, _, _} = e, env, {:id, name}), do: name_fn(ev(e, env), name)

  def ev_named({:class, nil, _, _, _} = e, env, {:id, name}),
    do: Browser.JS.Classes.define(e, env, name)

  def ev_named({k, {:fn, nil, _, _, _, _}} = e, env, {:id, name}) when k in [:gen, :async],
    do: name_fn(ev(e, env), name)

  def ev_named({:async, {:gen, {:fn, nil, _, _, _, _}}} = e, env, {:id, name}),
    do: name_fn(ev(e, env), name)

  # A slot form of the resolver as the hint names the value as `{:id, name}` does. The
  # clauses are limited to the node shapes that can take a name, so no other initializer
  # pays an extra clause.
  def ev_named(e, env, {k, _, _, name})
      when k in [:slot, :cslot, :fname] and is_binary(name) and nameable(e),
      do: ev_named(e, env, {:id, name})

  def ev_named(e, env, {:mslot, _, _, name, _}) when is_binary(name) and nameable(e),
    do: ev_named(e, env, {:id, name})

  def ev_named(e, env, {:aslot, _, _}) when nameable(e), do: ev_named(e, env, {:id, "arguments"})

  def ev_named(e, env, {:mref, _, name}) when is_binary(name) and nameable(e),
    do: ev_named(e, env, {:id, name})

  def ev_named(e, env, {:gref, name}) when is_binary(name) and nameable(e),
    do: ev_named(e, env, {:id, name})

  def ev_named(e, env, _), do: ev(e, env)

  # the name a function gets from the property key it is defined under
  defp key_fn_name(k) when is_binary(k), do: k
  defp key_fn_name({:symbol, _, desc}) when is_binary(desc), do: "[" <> desc <> "]"
  defp key_fn_name({:symbol, _, _}), do: ""
  defp key_fn_name(_), do: nil

  @doc false
  # names a class method or accessor from its key (`kind` is :method, :get or :set)
  def name_method(fun, key, kind) do
    case {key_fn_name(key), kind} do
      {nil, _} -> :ok
      {name, :get} -> accessor_name(fun, "get " <> name)
      {name, :set} -> accessor_name(fun, "set " <> name)
      {name, _} -> name_fn(fun, name)
    end
  end

  defp method_node?({:fn, {:method, _}, _, _, _, _}), do: true
  defp method_node?({k, inner}) when k in [:gen, :async], do: method_node?(inner)
  defp method_node?(_), do: false

  defp accessor_name({:obj, id}, name) do
    case deref(id) do
      %{fun: {:closure, %{name: {:method, _}} = c}} = o ->
        store(id, %{o | fun: {:closure, %{c | name: {:method, name}}}})

      _ ->
        :ok
    end
  end

  defp name_fn(f, nil), do: f

  defp name_fn({:obj, id} = f, name) do
    case deref(id) do
      %{fun: {:closure, %{name: {:method, n}} = c}} = o when not is_binary(n) ->
        store(id, %{o | fun: {:closure, %{c | name: {:method, name}}}})

      %{fun: {:closure, %{name: n} = c}} = o when not is_binary(n) and not is_tuple(n) ->
        store(id, %{o | fun: {:closure, %{c | name: name}}})

      _ ->
        :ok
    end

    f
  end
end
