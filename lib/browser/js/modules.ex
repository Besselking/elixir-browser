defmodule Browser.JS.Modules do
  @moduledoc """
  ES modules: records, linking and evaluation, and module namespace objects.

  A module record lives in the process dictionary (key `:js_modules`, by module key: a path or
  URL) and goes through the statuses `:new`, `:loading`, `:loaded`, `:linked`, `:evaluating`,
  then `:evaluated` or `:errored` (the error is thrown again by every later import). Its
  syntax tree is kept apart, under a `:js_hoist` key, which the collector does not walk.

  Loading fetches and parses the whole graph first; linking resolves every import and
  re-export (a missing or ambiguous name is a SyntaxError, before anything runs); evaluating
  runs the bodies depth first, once each, and a cycle just sees the half-run module.

  An imported name is a variable in the importing module's scope holding an alias to the
  variable of the module that really owns it, so it always reads the current value (or a
  ReferenceError while that is still uninitialized) and can not be assigned.

  A host gives `{resolve, fetch}`: `resolve.(specifier, base)` is `{:ok, key}` or
  `{:error, message}`, and `fetch.(key)` is `{:ok, source, base}` or `{:error, message}`.
  """

  alias Browser.JS.{Interp, Parser}

  @tag {:symbol, :toStringTag, "Symbol.toStringTag"}

  # ── records ────────────────────────────────────────────────

  @doc "Forgets every module."
  def reset, do: Process.put(:js_modules, %{})

  defp recs, do: Process.get(:js_modules) || %{}
  defp rec(key), do: Map.fetch!(recs(), key)
  defp put_rec(r), do: Process.put(:js_modules, Map.put(recs(), r.key, r))
  defp set(key, fields), do: put_rec(Map.merge(rec(key), Map.new(fields)))
  defp stmts(key), do: Process.get({:js_hoist, {:module, key}})

  defp syntax_error(msg), do: Interp.throw_error("SyntaxError", msg)

  # creates the record of a parsed module
  defp new(key, base, {:program, stmts}) do
    Process.put({:js_hoist, {:module, key}}, stmts)

    info =
      Enum.reduce(stmts, %{requests: [], imports: [], locals: %{}, indirect: %{}, stars: []}, fn
        {:import, spec, bindings}, acc ->
          imports =
            for b <- bindings do
              case b do
                {:default, l} -> {l, spec, "default"}
                {:ns, l} -> {l, spec, :ns}
                {:named, imported, l} -> {l, spec, imported}
              end
            end

          request(%{acc | imports: acc.imports ++ imports}, spec)

        {:export, {:var, _, decls}}, acc ->
          names = Enum.reduce(decls, [], fn {pat, _}, a -> Interp.pattern_names(pat, a) end)
          Enum.reduce(names, acc, &local(&2, &1, &1))

        {:export, {:fundecl, n, _}}, acc ->
          local(acc, n, n)

        {:export_default, {k, n, _}}, acc when k in [:fundecl, :classdecl] ->
          local(acc, "default", n)

        {:export_default, {:expr, _}}, acc ->
          local(acc, "default", :default_export)

        {:export_names, names}, acc ->
          Enum.reduce(names, acc, fn {l, exported}, a -> local(a, exported, l) end)

        {:export_from, spec, :all}, acc ->
          acc = request(acc, spec)
          %{acc | stars: acc.stars ++ [spec]}

        {:export_from, spec, names}, acc ->
          acc = request(acc, spec)

          Enum.reduce(names, acc, fn
            {:star, exported}, a -> indirect(a, exported, {spec, :ns})
            {imported, exported}, a -> indirect(a, exported, {spec, imported})
          end)

        _, acc ->
          acc
      end)

    put_rec(
      Map.merge(info, %{
        key: key,
        base: base,
        status: :new,
        error: nil,
        deps: %{},
        ns: nil,
        scope: Interp.new_scope(Interp.global())
      })
    )
  end

  defp request(acc, spec),
    do: if(spec in acc.requests, do: acc, else: %{acc | requests: acc.requests ++ [spec]})

  defp local(acc, exported, name), do: %{acc | locals: Map.put(acc.locals, exported, name)}
  defp indirect(acc, exported, ref), do: %{acc | indirect: Map.put(acc.indirect, exported, ref)}

  # ── loading ────────────────────────────────────────────────

  # fetches and parses one module the first time it is asked for
  defp ensure(key, loader) do
    unless Map.has_key?(recs(), key) do
      {_, fetch} = loader

      case fetch.(key) do
        {:ok, src, base} -> parse_new(key, base, src)
        {:error, msg} -> Interp.throw_error("TypeError", "Failed to fetch module #{key}: #{msg}")
      end
    end

    key
  end

  defp parse_new(key, base, src) do
    case Parser.parse(src, module: true) do
      {:ok, program} -> new(key, base, program)
      {:error, msg} -> syntax_error(msg)
    end
  end

  # loads the module and everything it imports; a failure leaves no half-loaded record behind
  defp load(key, loader) do
    if rec(key).status == :new do
      set(key, status: :loading)

      try do
        load_deps(key, loader)
        set(key, status: :loaded)
      catch
        kind, e ->
          unfinished = for {k, %{status: s}} <- recs(), s in [:new, :loading], do: k
          Process.put(:js_modules, Map.drop(recs(), unfinished))
          :erlang.raise(kind, e, __STACKTRACE__)
      end
    end

    :ok
  end

  defp load_deps(key, {resolve, _} = loader) do
    r = rec(key)

    for spec <- r.requests do
      dep =
        case resolve.(spec, r.base) do
          {:ok, k} -> ensure(k, loader)
          {:error, msg} -> Interp.throw_error("TypeError", msg)
        end

      set(key, deps: Map.put(rec(key).deps, spec, dep))
      load(dep, loader)
    end
  end

  # ── export resolution ──────────────────────────────────────

  # the names a module exports, `export *` included (never "default" through a star)
  defp exported_names(key, seen) do
    if key in seen do
      []
    else
      r = rec(key)
      seen = [key | seen]

      starred =
        Enum.flat_map(r.stars, fn spec ->
          for n <- exported_names(r.deps[spec], seen), n != "default", do: n
        end)

      Enum.uniq(Map.keys(r.locals) ++ Map.keys(r.indirect) ++ starred)
    end
  end

  # `{:ok, {module, variable}}`, `{:ok, {:ns, module}}`, `:null` or `:ambiguous`
  defp resolve(key, name, seen) do
    if {key, name} in seen do
      :null
    else
      seen = [{key, name} | seen]
      r = rec(key)

      cond do
        Map.has_key?(r.locals, name) ->
          local = r.locals[name]

          # an imported name that is exported again is a re-export of the original
          case Enum.find(r.imports, fn {l, _, _} -> l == local end) do
            {_, spec, imported} -> through(r, spec, imported, seen)
            _ -> {:ok, {key, local}}
          end

        Map.has_key?(r.indirect, name) ->
          {spec, imported} = r.indirect[name]
          through(r, spec, imported, seen)

        name == "default" ->
          :null

        true ->
          star_resolve(r, name, seen)
      end
    end
  end

  defp through(r, spec, :ns, _seen), do: {:ok, {:ns, r.deps[spec]}}
  defp through(r, spec, imported, seen), do: resolve(r.deps[spec], imported, seen)

  defp star_resolve(r, name, seen) do
    Enum.reduce_while(r.stars, :null, fn spec, acc ->
      case resolve(r.deps[spec], name, seen) do
        :ambiguous -> {:halt, :ambiguous}
        :null -> {:cont, acc}
        {:ok, _} = found when acc == :null -> {:cont, found}
        found when found == acc -> {:cont, acc}
        _ -> {:halt, :ambiguous}
      end
    end)
  end

  # ── linking ────────────────────────────────────────────────

  defp link(key) do
    keys = graph(key, [])
    Enum.each(keys, &init_env/1)
    Enum.each(keys, &set(&1, status: :linked))
  end

  # the loaded modules reachable from `key`, dependencies first
  defp graph(key, acc) do
    r = rec(key)

    if r.status != :loaded or key in acc do
      acc
    else
      acc = [key | acc]
      Enum.reduce(r.requests, acc, fn spec, a -> graph(r.deps[spec], a) end)
    end
    |> Enum.uniq()
  end

  defp init_env(key) do
    r = rec(key)
    scope = r.scope

    # exports must all resolve
    for name <- Map.keys(r.indirect) ++ Map.keys(r.locals) do
      case resolve(key, name, []) do
        {:ok, _} -> :ok
        _ -> syntax_error("Unresolvable export '#{name}'")
      end
    end

    Interp.declare(scope, :this, :undefined)
    Interp.declare(scope, :module_url, r.base)

    for {local, spec, imported} <- r.imports do
      dep = r.deps[spec]

      binding =
        if imported == :ns do
          {:ok, {:ns, dep}}
        else
          resolve(dep, imported, [])
        end

      case binding do
        {:ok, {:ns, k}} ->
          Interp.declare(scope, local, namespace(k), true)

        {:ok, {k, name}} ->
          Interp.declare(scope, local, {:alias, rec(k).scope, name}, true)

        _ ->
          syntax_error(
            "The requested module '#{spec}' does not provide an export named '#{imported}'"
          )
      end
    end

    Interp.module_init(stmts(key), scope)
  end

  # ── evaluating ─────────────────────────────────────────────

  defp evaluate(key) do
    r = rec(key)

    case r.status do
      :errored ->
        throw({:js_error, r.error})

      :linked ->
        set(key, status: :evaluating)

        try do
          for spec <- r.requests, do: evaluate(r.deps[spec])
          Interp.module_exec(stmts(key), r.scope)
          set(key, status: :evaluated)
        catch
          {:js_error, e} = t ->
            set(key, status: :errored, error: e)
            throw(t)
        end

      # evaluated, or running (a cycle)
      _ ->
        :ok
    end

    :ok
  end

  # ── entry points ───────────────────────────────────────────

  @doc """
  Runs `program` as the module `key` (with `base` to resolve its imports against) and returns
  its namespace.
  """
  def run(key, base, program, loader) do
    new(key, base, program)
    ns = finish(key, loader)
    Browser.JS.Promise.run_microtasks()
    ns
  end

  @doc "`import(specifier)` from a module (or script) whose base is `from`: the namespace."
  def import(spec, from, {resolve, _} = loader) do
    key =
      case resolve.(spec, from) do
        {:ok, k} -> ensure(k, loader)
        {:error, msg} -> Interp.throw_error("TypeError", msg)
      end

    finish(key, loader)
  end

  defp finish(key, loader) do
    load(key, loader)
    link(key)
    evaluate(key)
    namespace(key)
  end

  # ── namespace objects ──────────────────────────────────────

  @doc "The namespace object of a module (made once)."
  def namespace(key) do
    case rec(key).ns do
      {obj, _} ->
        obj

      nil ->
        bindings =
          for name <- exported_names(key, []),
              {:ok, b} <- [resolve(key, name, [])],
              into: %{},
              do: {name, b}

        {:obj, id} = obj = Interp.new_host(__MODULE__, {:ns, key}, :null)
        o = Interp.deref(id)

        Interp.store(
          id,
          o
          |> Map.put(:props, %{@tag => "Module"})
          |> Map.put(:attrs, %{@tag => %{w: false, c: false, e: false}})
          |> Map.put(:ext, false)
        )

        set(key, ns: {obj, bindings})
        obj
    end
  end

  defp bindings(key), do: elem(rec(key).ns, 1)

  # the current value of an export (a ReferenceError while it is uninitialized)
  defp read({:ns, k}, _name), do: namespace(k)

  defp read({k, local}, name) do
    case Interp.module_binding(rec(k).scope, local) do
      :tdz ->
        Interp.throw_error("ReferenceError", "Cannot access '#{name}' before initialization")

      v ->
        v
    end
  end

  @doc false
  def host_get({:ns, key}, name, _self) when is_binary(name) do
    case bindings(key) do
      %{^name => b} -> {:ok, read(b, name)}
      _ -> :miss
    end
  end

  def host_get(_, _, _), do: :miss

  @doc false
  # (assigning is a TypeError in strict code, which is not told apart here: it is ignored)
  def host_put({:ns, _}, _key, _v, _self), do: :ok

  @doc false
  def host_has({:ns, key}, name), do: is_binary(name) and is_map_key(bindings(key), name)

  @doc false
  # (each export is read: an uninitialized one is a ReferenceError)
  def host_keys({:ns, key}) do
    names = names(key)
    Enum.each(names, &read(bindings(key)[&1], &1))
    names
  end

  @doc false
  def host_delete({:ns, key}, name) do
    if is_binary(name) and is_map_key(bindings(key), name), do: false, else: :default
  end

  @doc "The exported names, in code unit order."
  def names({:ns, key}), do: names(key)
  def names(key), do: key |> bindings() |> Map.keys() |> Enum.sort()

  @doc false
  # the own property of a namespace: writable, enumerable, not configurable
  def property({:ns, key}, name) do
    case bindings(key) do
      %{^name => b} -> {:data, read(b, name), true, true, false}
      _ -> nil
    end
  end

  @doc false
  # `Object.defineProperty` on an export: only what changes nothing is allowed
  def define_own({:ns, key}, name, desc) do
    case bindings(key) do
      %{^name => b} ->
        current = read(b, name)

        ok? =
          not (Map.has_key?(desc, :get) or Map.has_key?(desc, :set)) and
            Map.get(desc, :configurable) != true and Map.get(desc, :enumerable) != false and
            Map.get(desc, :writable) != false and
            (not Map.has_key?(desc, :value) or same_value?(desc.value, current))

        unless ok?,
          do: Interp.throw_error("TypeError", "Cannot redefine property: #{name}")

        :ok

      _ ->
        :ordinary
    end
  end

  defp same_value?(a, b), do: a === b or (a == :nan and b == :nan)
end
