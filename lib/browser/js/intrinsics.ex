defmodule Browser.JS.Intrinsics do
  @moduledoc """
  The built-in objects that all the realms of a page share, and their state at boot.

  In a browser each frame has its own built-in objects. Here the realms of a page share
  them: a frame's global scope starts with the base realm's names (`Browser.JS.Runtime`),
  so `Function.prototype` of a frame is the one of the page. A frame's script that changes
  a built-in object (a polyfill that replaces `Function.prototype.toString`, or that adds
  `Set.prototype.addAll`) changes it for all the realms. Such a function holds the global
  scope of its frame, and thus the whole page of the frame, also after the frame went.

  `snapshot/0` records, after the boot, the own properties of the shared built-in objects:
  the objects that the base realm's global names hold (the constructors, `Math`, `JSON`
  and so on), their prototypes and the objects of their data properties that are not
  functions, and the prototypes of `Interp.proto/1` (the host interfaces too).
  `restore/1` runs when a frame goes. On each recorded object it gives back the boot state
  of each property whose value, getter or setter is a function of the dead realm, and
  deletes such a property that was not there at boot. It does not touch a property that a
  live realm set. Thus a later page sees the built-in objects as they were at boot, as it
  would in a browser.

  The record has two process keys. `:js_boot_states` holds, for each object, its own
  properties at boot as `Obj.own_state/2` gives them. It is a root of the collector, so a
  boot value that a frame replaced stays for the restore. `:js_boot_marks` holds the
  property part of each record at boot (the shape and the values, or the dictionary). It
  is not a root (the collector skips it), and only an identity compare reads it: an object
  whose part did not change has nothing to restore, so most objects cost one compare.
  """

  require Browser.JS.Obj, as: Obj
  alias Browser.JS.Interp

  @doc "Records the own properties of the shared built-in objects. The boot calls it."
  def snapshot do
    limit = :erlang.get(:js_next)
    vars = Interp.deref(Interp.global()).vars
    starts = for {_, {:obj, id}} <- vars, do: id
    protos = for {{:proto, _}, {:obj, id}} <- Process.get(), do: id
    ids = walk(starts ++ protos, limit, %{})

    Process.put(:js_boot_marks, for(id <- ids, do: {id, part(:erlang.get(id))}))

    Process.put(
      :js_boot_states,
      Map.new(ids, fn id ->
        rec = :erlang.get(id)
        {id, Map.new(Obj.all_keys(rec), &{&1, Obj.own_state(rec, &1)})}
      end)
    )

    :ok
  end

  # The ids of the shared objects from `todo`: an object, its prototype, its `prototype`,
  # and the objects that are not functions in its data properties. Only the objects of the
  # boot (ids below `limit`) and no host objects (a window or a document belongs to a realm).
  defp walk([], _limit, seen), do: Map.keys(seen)

  defp walk([id | todo], limit, seen) when is_integer(id) and id < limit and id >= 0 do
    rec = :erlang.get(id)

    cond do
      is_map_key(seen, id) or not is_map(rec) or part(rec) == nil or
          Map.get(rec, :class) == :host ->
        walk(todo, limit, seen)

      true ->
        next =
          for key <- Obj.all_keys(rec),
              {:data, {:obj, x}, _, _, _} <- [Obj.own_state(rec, key)],
              key == "prototype" or not function?(x),
              do: x

        next = if match?({:obj, _}, rec.proto), do: [elem(rec.proto, 1) | next], else: next
        walk(next ++ todo, limit, Map.put(seen, id, true))
    end
  end

  defp walk([_ | todo], limit, seen), do: walk(todo, limit, seen)

  defp function?(id), do: match?(%{class: :function}, :erlang.get(id))

  # the part of a record that holds its own properties, or nil
  defp part(%{shape: shape, vals: vals}), do: {shape, vals}
  defp part(%{props: props}), do: props
  defp part(_), do: nil

  @doc """
  Gives the shared built-in objects back the boot state of each property that a function
  of the realm with the global scope `global` holds (see the moduledoc). Returns how many
  properties changed.
  """
  def restore(global) do
    case {Process.get(:js_boot_marks), Process.get(:js_boot_states)} do
      {marks, states} when is_list(marks) and is_map(states) ->
        Enum.reduce(marks, 0, fn {id, mark}, n ->
          case :erlang.get(id) do
            rec when is_map(rec) ->
              if part(rec) === mark, do: n, else: n + restore_one(id, rec, states[id], global)

            _ ->
              n
          end
        end)

      _ ->
        0
    end
  end

  defp restore_one(id, rec, boot, global) do
    dead = for key <- Obj.all_keys(rec), dead?(Obj.own_state(rec, key), global), do: key

    if dead == [] do
      0
    else
      rec =
        Enum.reduce(dead, rec, fn key, rec ->
          case boot[key] do
            nil ->
              Obj.own_delete(rec, key)

            {:data, v, w, e, c} ->
              Obj.own_redefine(rec, key, v, %{w: w, c: c}, e)

            {:accessor, g, s, e, c} ->
              Obj.own_redefine(rec, key, {:accessor, g, s}, %{w: true, c: c}, e)
          end
        end)

      Interp.store(id, rec)
      length(dead)
    end
  end

  defp dead?({:data, v, _, _, _}, global), do: of_realm?(v, global)
  defp dead?({:accessor, g, s, _, _}, global), do: of_realm?(g, global) or of_realm?(s, global)
  defp dead?(_, _), do: false

  # true for a JS function whose closure was made in the realm with the global scope `global`
  defp of_realm?({:obj, id}, global) do
    case :erlang.get(id) do
      %{fun: {:closure, %{scope: env}}} when is_integer(env) ->
        :erlang.get(env) != :undefined and Interp.root(env) == global

      _ ->
        false
    end
  end

  defp of_realm?(_, _), do: false
end
