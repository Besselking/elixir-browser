defmodule Browser.JS.Iterators do
  @moduledoc """
  The `Iterator` constructor and `Iterator.prototype` helpers: `map`, `filter`, `take`, `drop`,
  `flatMap`, `reduce`, `toArray`, `forEach`, `some`, `every`, `find`, `Iterator.from`, and the
  newer `Iterator.concat`, `Iterator.zip`, `Iterator.zipKeyed`, `chunks`, `windows`, `includes`
  and `join`.

  A helper is an object with an Elixir closure behind it: the closure runs one step (`{:yield,
  value}` or `:done`) each time `next` is called. The state (not started, suspended, running,
  finished) lives in the process dictionary, and the closure keeps its own counters there too.
  """

  import Browser.JS.Interp, except: [get: 2, put: 3]
  alias Browser.JS.{Interp, Props}

  @iterator {:symbol, :iterator, "Symbol.iterator"}
  @max_safe 9_007_199_254_740_991

  defp arg(args, i), do: Enum.at(args, i, :undefined)
  defp get(o, k), do: Interp.get(o, k)

  # ── plumbing ───────────────────────────────────────────────

  defp def_fn(obj, name, arity, fun) do
    f = native(name, fun)
    {:obj, fid} = f
    store(fid, Map.put(deref(fid), :arity, arity * 1.0))
    put_hidden(obj, name, f)
  end

  defp result(value, done), do: new_object([{"value", value}, {"done", done}])

  defp object?({:obj, _}), do: true
  defp object?(_), do: false

  defp type_error(msg), do: throw_error("TypeError", msg)

  # a mutable cell for the closures
  defp cell(init) do
    ref = make_ref()
    :erlang.put(ref, init)
    ref
  end

  defp cell_get(ref), do: :erlang.get(ref)
  defp cell_put(ref, v), do: :erlang.put(ref, v)

  # GetMethod(obj, name): nil when undefined or null
  defp get_method(obj, name) do
    case get(obj, name) do
      v when v in [:undefined, :null] ->
        nil

      f ->
        unless function?(f), do: type_error("#{key_text(name)} is not a function")
        f
    end
  end

  defp setter_key_text({:symbol, _, d}), do: "[" <> d <> "]"
  defp setter_key_text(k), do: k

  defp key_text({:symbol, _, d}), do: d
  defp key_text(k), do: k

  # IteratorClose with a normal completion: errors from `return` propagate, and so does a
  # `return` that does not give back an object
  defp close_normal(it) do
    case get_method(it, "return") do
      nil ->
        :ok

      f ->
        unless object?(call(f, it, [])), do: type_error("iterator return result is not an object")
        :ok
    end
  end

  # IteratorClose with a throw completion: whatever `return` does is dropped
  defp close_throw(it) do
    case get_method(it, "return") do
      nil -> :ok
      f -> call(f, it, [])
    end
  catch
    :throw, e when elem(e, 0) == :js_error -> :ok
  end

  # runs `fun`; a JS error closes the iterator on its way out
  defp with_close(it, fun) do
    fun.()
  catch
    :throw, {:js_error, _} = e ->
      close_throw(it)
      throw(e)
  end

  defp fail_closing(it, kind, msg) do
    close_throw(it)
    throw_error(kind, msg)
  end

  # IteratorCloseAll: the last one opened is closed first
  defp close_all(iters, completion) do
    final =
      iters
      |> Enum.reverse()
      |> Enum.reduce(completion, fn it, c ->
        case c do
          :normal ->
            try do
              close_normal(it)
              :normal
            catch
              :throw, {:js_error, _} = e -> {:throw, e}
            end

          {:throw, _} ->
            close_throw(it)
            c
        end
      end)

    case final do
      :normal -> :ok
      {:throw, e} -> throw(e)
    end
  end

  # GetIteratorDirect: the record is `{iterator, next_method}`
  defp direct(o) do
    unless object?(o), do: type_error("not an object")
    {o, get(o, "next")}
  end

  # IteratorStepValue
  defp step({it, next}), do: Interp.iter_step(it, next)

  # GetIteratorFlattenable: an iterator, or whatever has `[Symbol.iterator]`; strings are
  # accepted when `strings?`
  defp flattenable(obj, strings?) do
    unless object?(obj) or (strings? and is_binary(obj)),
      do: type_error("value is not an object")

    it =
      case get_method(obj, @iterator) do
        nil ->
          obj

        m ->
          call(m, obj, [])
      end

    unless object?(it), do: type_error("iterator is not an object")
    direct(it)
  end

  # GetIterator(obj, sync): `[Symbol.iterator]` must exist
  defp get_iterator(obj) do
    m = if object?(obj) or is_binary(obj), do: get(obj, @iterator), else: :undefined

    unless function?(m), do: type_error("object is not iterable")
    it = call(m, obj, [])
    unless object?(it), do: type_error("iterator is not an object")
    direct(it)
  end

  # ── helper objects (the Iterator Helper prototype) ─────────

  # `step` produces the next value, `close` is what `return` does for a helper that is
  # suspended (given :start or :yield)
  defp make_helper(step, close) do
    ref = make_ref()
    :erlang.put({:ihelper, ref}, {:start, step, close})
    o = new_object([], proto(:iterator_helper))
    {:obj, id} = o
    store(id, Map.put(deref(id), :ihelper, ref))
    o
  end

  defp helper_ref(this) do
    case this do
      {:obj, id} ->
        case Map.get(deref(id), :ihelper) do
          nil -> type_error("not an Iterator Helper object")
          ref -> ref
        end

      _ ->
        type_error("not an Iterator Helper object")
    end
  end

  defp helper_next(this) do
    ref = helper_ref(this)

    case :erlang.get({:ihelper, ref}) do
      {:running, _, _} ->
        type_error("Generator is already running")

      {:done, _, _} ->
        result(:undefined, true)

      {_, step, close} ->
        :erlang.put({:ihelper, ref}, {:running, step, close})

        try do
          case step.() do
            {:yield, v} ->
              :erlang.put({:ihelper, ref}, {:yield, step, close})
              result(v, false)

            :done ->
              :erlang.put({:ihelper, ref}, {:done, step, close})
              result(:undefined, true)
          end
        catch
          kind, e ->
            :erlang.put({:ihelper, ref}, {:done, step, close})
            :erlang.raise(kind, e, __STACKTRACE__)
        end
    end
  end

  defp helper_return(this) do
    ref = helper_ref(this)

    case :erlang.get({:ihelper, ref}) do
      {:running, _, _} ->
        type_error("Generator is already running")

      {:done, _, _} ->
        result(:undefined, true)

      {state, step, close} ->
        :erlang.put({:ihelper, ref}, {:done, step, close})
        close.(state)
        result(:undefined, true)
    end
  end

  # ── install ────────────────────────────────────────────────

  def install(scope) do
    iter_proto = proto(:iterator)

    ctor =
      native("Iterator", fn this, _ ->
        unless object?(this), do: type_error("Constructor Iterator requires 'new'")

        {:obj, id} = this

        if deref(id).proto == iter_proto,
          do: type_error("Abstract class Iterator not directly constructable")

        this
      end)

    {:obj, cid} = ctor
    store(cid, Map.put(deref(cid), :arity, 0.0))
    put_const(ctor, "prototype", iter_proto)
    declare(scope, "Iterator", ctor)

    # `constructor` and `@@toStringTag` are accessors that behave like data properties
    tag = {:symbol, :toStringTag, "Symbol.toStringTag"}

    weird = fn key, getter_name, value ->
      Props.define_accessor(iter_proto, key,
        get: native(getter_name, fn _, _ -> value end),
        set:
          native(
            "set " <> setter_key_text(key),
            fn this, args ->
              unless object?(this), do: type_error("not an object")
              if this == iter_proto, do: type_error("Cannot assign to read only property")
              v = arg(args, 0)

              if Props.descriptor(this, key) == :undefined,
                do: Props.define(this, key, descriptor_obj(v)),
                else: Interp.put(this, key, v)

              :undefined
            end
          ),
        enumerable: false
      )
    end

    weird.("constructor", "get constructor", ctor)
    weird.(tag, "get [Symbol.toStringTag]", "Iterator")

    install_helper_proto(iter_proto)
    install_methods(iter_proto)
    install_statics(ctor, iter_proto)
    :ok
  end

  defp descriptor_obj(v) do
    new_object([{"value", v}, {"writable", true}, {"enumerable", true}, {"configurable", true}])
  end

  defp install_helper_proto(iter_proto) do
    hp = new_object([], iter_proto)
    put_proto(:iterator_helper, hp)
    def_fn(hp, "next", 0, fn this, _ -> helper_next(this) end)
    def_fn(hp, "return", 0, fn this, _ -> helper_return(this) end)
    put_tag(hp, "Iterator Helper")

    # what Iterator.from wraps a plain iterator in
    wp = new_object([], iter_proto)
    put_proto(:wrap_iterator, wp)

    def_fn(wp, "next", 0, fn this, _ ->
      {it, next} = wrapped!(this)
      call(next, it, [])
    end)

    def_fn(wp, "return", 0, fn this, _ ->
      {it, _} = wrapped!(this)

      case get_method(it, "return") do
        nil -> result(:undefined, true)
        f -> call(f, it, [])
      end
    end)
  end

  defp wrapped!({:obj, id}) do
    case Map.get(deref(id), :wrapped) do
      nil -> type_error("not a wrapped iterator")
      rec -> rec
    end
  end

  defp wrapped!(_), do: type_error("not a wrapped iterator")

  # ── Iterator.prototype methods ─────────────────────────────

  defp this_object!(this) do
    unless object?(this), do: type_error("Iterator.prototype method called on non-object")
    this
  end

  defp callable_or_close!(o, f) do
    unless function?(f), do: fail_closing(o, "TypeError", "argument is not a function")
  end

  # ToIntegerOrInfinity of a limit for take and drop; a bad one closes the iterator
  defp limit!(o, v) do
    n = with_close(o, fn -> to_num(v) end)

    cond do
      n == :nan -> fail_closing(o, "RangeError", "limit must be a number")
      n == :infinity -> :infinity
      n == :neg_infinity -> fail_closing(o, "RangeError", "limit must not be negative")
      trunc(n) < 0 -> fail_closing(o, "RangeError", "limit must not be negative")
      true -> trunc(n)
    end
  end

  defp install_methods(p) do
    def_fn(p, "map", 1, fn this, args ->
      o = this_object!(this)
      f = arg(args, 0)
      callable_or_close!(o, f)
      rec = {it, _} = direct(o)
      counter = cell(0)

      make_helper(
        fn ->
          case step(rec) do
            :done ->
              :done

            {:ok, v} ->
              i = cell_get(counter)
              cell_put(counter, i + 1)
              {:yield, with_close(it, fn -> call(f, :undefined, [v, i * 1.0]) end)}
          end
        end,
        fn _ -> close_normal(it) end
      )
    end)

    def_fn(p, "filter", 1, fn this, args ->
      o = this_object!(this)
      f = arg(args, 0)
      callable_or_close!(o, f)
      rec = {it, _} = direct(o)
      counter = cell(0)

      make_helper(
        fn -> filter_step(rec, it, f, counter) end,
        fn _ -> close_normal(it) end
      )
    end)

    def_fn(p, "take", 1, fn this, args ->
      o = this_object!(this)
      limit = limit!(o, arg(args, 0))
      rec = {it, _} = direct(o)
      remaining = cell(limit)

      make_helper(
        fn ->
          case cell_get(remaining) do
            0 ->
              close_normal(it)
              :done

            r ->
              if r != :infinity, do: cell_put(remaining, r - 1)

              case step(rec) do
                :done -> :done
                {:ok, v} -> {:yield, v}
              end
          end
        end,
        fn _ -> close_normal(it) end
      )
    end)

    def_fn(p, "drop", 1, fn this, args ->
      o = this_object!(this)
      limit = limit!(o, arg(args, 0))
      rec = {it, _} = direct(o)
      remaining = cell(limit)

      make_helper(
        fn ->
          case drop_skip(rec, remaining) do
            :done ->
              :done

            :ok ->
              case step(rec) do
                :done -> :done
                {:ok, v} -> {:yield, v}
              end
          end
        end,
        fn _ -> close_normal(it) end
      )
    end)

    def_fn(p, "flatMap", 1, fn this, args ->
      o = this_object!(this)
      f = arg(args, 0)
      callable_or_close!(o, f)
      rec = {it, _} = direct(o)
      counter = cell(0)
      inner = cell(nil)

      make_helper(
        fn -> flat_map_step(rec, it, f, counter, inner) end,
        fn _ ->
          case cell_get(inner) do
            nil ->
              close_normal(it)

            {inner_it, _} ->
              cell_put(inner, nil)

              try do
                close_normal(inner_it)
              catch
                :throw, {:js_error, _} = e ->
                  close_throw(it)
                  throw(e)
              end

              close_normal(it)
          end
        end
      )
    end)

    def_fn(p, "reduce", 1, fn this, args ->
      o = this_object!(this)
      f = arg(args, 0)
      callable_or_close!(o, f)
      rec = {it, _} = direct(o)

      {acc, counter} =
        if length(args) >= 2 do
          {arg(args, 1), 0}
        else
          case step(rec) do
            :done -> type_error("Reduce of empty iterator with no initial value")
            {:ok, v} -> {v, 1}
          end
        end

      reduce_loop(rec, it, f, acc, counter)
    end)

    def_fn(p, "toArray", 0, fn this, _ ->
      rec = this |> this_object!() |> direct()
      new_array(collect(rec, []))
    end)

    def_fn(p, "forEach", 1, fn this, args ->
      o = this_object!(this)
      f = arg(args, 0)
      callable_or_close!(o, f)
      rec = {it, _} = direct(o)

      each_value(rec, 0, fn v, i ->
        with_close(it, fn -> call(f, :undefined, [v, i * 1.0]) end)
      end)

      :undefined
    end)

    def_fn(p, "some", 1, fn this, args ->
      predicate_search(
        this,
        arg(args, 0),
        fn selected?, _v -> if selected?, do: {:stop, true} end,
        false
      )
    end)

    def_fn(p, "every", 1, fn this, args ->
      predicate_search(
        this,
        arg(args, 0),
        fn selected?, _v -> if not selected?, do: {:stop, false} end,
        true
      )
    end)

    def_fn(p, "find", 1, fn this, args ->
      predicate_search(
        this,
        arg(args, 0),
        fn selected?, v -> if selected?, do: {:stop, v} end,
        :undefined
      )
    end)

    def_fn(p, "chunks", 1, fn this, args -> chunks(this, arg(args, 0)) end)
    def_fn(p, "windows", 1, fn this, args -> windows(this, arg(args, 0), arg(args, 1)) end)
    def_fn(p, "includes", 1, fn this, args -> includes(this, arg(args, 0), arg(args, 1)) end)
    def_fn(p, "join", 1, fn this, args -> join(this, arg(args, 0)) end)

    dispose_key = {:symbol, :dispose, "Symbol.dispose"}

    put_hidden(
      p,
      dispose_key,
      native("[Symbol.dispose]", fn this, _ ->
        case get_method(this, "return") do
          nil -> :ok
          f -> call(f, this, [])
        end

        :undefined
      end)
    )
  end

  defp filter_step(rec, it, f, counter) do
    case step(rec) do
      :done ->
        :done

      {:ok, v} ->
        i = cell_get(counter)
        cell_put(counter, i + 1)

        if truthy(with_close(it, fn -> call(f, :undefined, [v, i * 1.0]) end)),
          do: {:yield, v},
          else: filter_step(rec, it, f, counter)
    end
  end

  defp drop_skip(rec, remaining) do
    case cell_get(remaining) do
      0 ->
        :ok

      r ->
        if r != :infinity, do: cell_put(remaining, r - 1)

        case step(rec) do
          :done -> :done
          {:ok, _} -> drop_skip(rec, remaining)
        end
    end
  end

  defp flat_map_step(rec, it, f, counter, inner) do
    case cell_get(inner) do
      nil ->
        case step(rec) do
          :done ->
            :done

          {:ok, v} ->
            i = cell_get(counter)
            cell_put(counter, i + 1)

            inner_rec =
              with_close(it, fn ->
                mapped = call(f, :undefined, [v, i * 1.0])
                flattenable(mapped, false)
              end)

            cell_put(inner, inner_rec)
            flat_map_step(rec, it, f, counter, inner)
        end

      {inner_it, _} = inner_rec ->
        case with_close(it, fn -> step(inner_rec) end) do
          :done ->
            cell_put(inner, nil)
            flat_map_step(rec, it, f, counter, inner)

          {:ok, v} ->
            _ = inner_it
            {:yield, v}
        end
    end
  end

  defp reduce_loop(rec, it, f, acc, counter) do
    case step(rec) do
      :done ->
        acc

      {:ok, v} ->
        acc = with_close(it, fn -> call(f, :undefined, [acc, v, counter * 1.0]) end)
        reduce_loop(rec, it, f, acc, counter + 1)
    end
  end

  defp collect(rec, acc) do
    case step(rec) do
      :done -> Enum.reverse(acc)
      {:ok, v} -> collect(rec, [v | acc])
    end
  end

  defp each_value(rec, i, fun) do
    case step(rec) do
      :done ->
        :ok

      {:ok, v} ->
        fun.(v, i)
        each_value(rec, i + 1, fun)
    end
  end

  # some / every / find: `judge.(selected?, value)` returns {:stop, result} to end the search
  defp predicate_search(this, f, judge, default) do
    o = this_object!(this)
    callable_or_close!(o, f)
    rec = {it, _} = direct(o)
    search(rec, it, f, judge, default, 0)
  end

  defp search(rec, it, f, judge, default, i) do
    case step(rec) do
      :done ->
        default

      {:ok, v} ->
        selected? = truthy(with_close(it, fn -> call(f, :undefined, [v, i * 1.0]) end))

        case judge.(selected?, v) do
          {:stop, r} ->
            close_normal(it)
            r

          nil ->
            search(rec, it, f, judge, default, i + 1)
        end
    end
  end

  # ── chunks, windows, includes, join ────────────────────────

  # a size for chunks and windows: a Number with an integer value between 1 and 2^32 - 1
  defp size!(o, v) do
    unless is_number(v) or v in [:nan, :infinity, :neg_infinity],
      do: fail_closing(o, "TypeError", "size must be a number")

    cond do
      v in [:nan, :infinity, :neg_infinity] ->
        fail_closing(o, "TypeError", "size must be an integer")

      v != Float.floor(v * 1.0) ->
        fail_closing(o, "TypeError", "size must be an integer")

      v < 1 or v > 4_294_967_295 ->
        fail_closing(o, "RangeError", "size out of range")

      true ->
        trunc(v)
    end
  end

  defp chunks(this, size) do
    o = this_object!(this)
    n = size!(o, size)
    rec = {it, _} = direct(o)
    buf = cell([])

    make_helper(
      fn -> chunk_step(rec, n, buf) end,
      fn _ -> close_normal(it) end
    )
  end

  defp chunk_step(rec, n, buf) do
    case cell_get(buf) do
      :finished ->
        :done

      acc ->
        case step(rec) do
          :done ->
            cell_put(buf, :finished)
            if acc == [], do: :done, else: {:yield, new_array(Enum.reverse(acc))}

          {:ok, v} ->
            acc = [v | acc]

            if length(acc) == n do
              cell_put(buf, [])
              {:yield, new_array(Enum.reverse(acc))}
            else
              cell_put(buf, acc)
              chunk_step(rec, n, buf)
            end
        end
    end
  end

  defp windows(this, size, undersized) do
    o = this_object!(this)
    n = size!(o, size)

    partial? =
      case undersized do
        :undefined -> false
        "only-full" -> false
        "allow-partial" -> true
        _ -> fail_closing(o, "TypeError", "invalid undersized option")
      end

    rec = {it, _} = direct(o)
    state = cell({[], false})

    make_helper(
      fn -> window_step(rec, n, partial?, state) end,
      fn _ -> close_normal(it) end
    )
  end

  # the buffer is kept newest first
  defp window_step(rec, n, partial?, state) do
    {buf, yielded?} = cell_get(state)

    if buf == :finished do
      :done
    else
      case step(rec) do
        :done ->
          cell_put(state, {:finished, yielded?})

          if partial? and not yielded? and buf != [],
            do: {:yield, new_array(Enum.reverse(buf))},
            else: :done

        {:ok, v} ->
          buf = [v | buf]

          if length(buf) == n do
            cell_put(state, {Enum.take(buf, n - 1), true})
            {:yield, new_array(Enum.reverse(buf))}
          else
            cell_put(state, {buf, yielded?})
            window_step(rec, n, partial?, state)
          end
      end
    end
  end

  defp includes(this, search, skipped) do
    o = this_object!(this)

    skip =
      case skipped do
        :undefined ->
          0

        v when is_number(v) or v in [:nan, :infinity, :neg_infinity] ->
          cond do
            v == :nan ->
              fail_closing(o, "TypeError", "skippedElements must be an integer")

            v == :infinity ->
              :infinity

            v == :neg_infinity ->
              fail_closing(o, "RangeError", "skippedElements out of range")

            v != Float.floor(v * 1.0) ->
              fail_closing(o, "TypeError", "skippedElements must be an integer")

            v < 0 or v > @max_safe ->
              fail_closing(o, "RangeError", "skippedElements out of range")

            true ->
              trunc(v)
          end

        _ ->
          fail_closing(o, "TypeError", "skippedElements must be a number")
      end

    rec = {it, _} = direct(o)

    case skip_values(rec, skip) do
      :done -> false
      :ok -> includes_loop(rec, it, search)
    end
  end

  defp skip_values(_rec, 0), do: :ok

  defp skip_values(rec, n) do
    case step(rec) do
      :done -> :done
      {:ok, _} -> skip_values(rec, if(n == :infinity, do: n, else: n - 1))
    end
  end

  defp includes_loop(rec, it, search) do
    case step(rec) do
      :done ->
        false

      {:ok, v} ->
        if same_value_zero?(v, search) do
          close_normal(it)
          true
        else
          includes_loop(rec, it, search)
        end
    end
  end

  defp same_value_zero?(a, b) when is_number(a) and is_number(b), do: a == b
  defp same_value_zero?(a, b), do: a === b

  defp join(this, separator) do
    o = this_object!(this)

    sep =
      case separator do
        :undefined -> ","
        s -> with_close(o, fn -> to_str(s) end)
      end

    rec = {it, _} = direct(o)
    join_loop(rec, it, sep, [], true)
  end

  defp join_loop(rec, it, sep, acc, first?) do
    case step(rec) do
      :done ->
        acc |> Enum.reverse() |> IO.iodata_to_binary()

      {:ok, v} ->
        text =
          if v in [:undefined, :null], do: "", else: with_close(it, fn -> to_str(v) end)

        acc = if first?, do: [text], else: [text, sep | acc]
        join_loop(rec, it, sep, acc, false)
    end
  end

  # ── Iterator.from, concat, zip ─────────────────────────────

  defp install_statics(ctor, iter_proto) do
    def_fn(ctor, "from", 1, fn _, args ->
      {it, next} = rec = flattenable(arg(args, 0), true)

      if Interp.instance_of?(it, ctor) do
        it
      else
        wrapper = new_object([], proto(:wrap_iterator))
        {:obj, id} = wrapper
        store(id, Map.put(deref(id), :wrapped, {it, next}))
        _ = rec
        wrapper
      end
    end)

    def_fn(ctor, "concat", 0, fn _, args ->
      items =
        for item <- args do
          unless object?(item), do: type_error("Iterator.concat argument is not an object")
          m = get_method(item, @iterator)
          if m == nil, do: type_error("Iterator.concat argument is not iterable")
          {item, m}
        end

      queue = cell(items)
      current = cell(nil)

      make_helper(
        fn -> concat_step(queue, current) end,
        fn
          :start ->
            :ok

          :yield ->
            case cell_get(current) do
              nil -> :ok
              {it, _} -> close_normal(it)
            end
        end
      )
    end)

    def_fn(ctor, "zip", 1, fn _, args -> zip(arg(args, 0), arg(args, 1), false) end)
    def_fn(ctor, "zipKeyed", 1, fn _, args -> zip(arg(args, 0), arg(args, 1), true) end)
    _ = iter_proto
    :ok
  end

  defp concat_step(queue, current) do
    case cell_get(current) do
      nil ->
        case cell_get(queue) do
          [] ->
            :done

          [{item, m} | rest] ->
            cell_put(queue, rest)
            it = call(m, item, [])
            unless object?(it), do: type_error("iterator is not an object")
            cell_put(current, direct(it))
            concat_step(queue, current)
        end

      rec ->
        case step(rec) do
          :done ->
            cell_put(current, nil)
            concat_step(queue, current)

          {:ok, v} ->
            {:yield, v}
        end
    end
  end

  defp zip(iterables, options, keyed?) do
    unless object?(iterables), do: type_error("Iterator.zip argument is not an object")

    opts =
      case options do
        :undefined -> new_object([], :null)
        {:obj, _} = o -> o
        _ -> type_error("options must be an object")
      end

    mode =
      case get(opts, "mode") do
        :undefined -> :shortest
        "shortest" -> :shortest
        "longest" -> :longest
        "strict" -> :strict
        _ -> type_error("invalid mode")
      end

    padding_option =
      if mode == :longest do
        case get(opts, "padding") do
          :undefined -> :undefined
          {:obj, _} = p -> p
          _ -> type_error("padding must be an object")
        end
      else
        :undefined
      end

    {keys, iters} = if keyed?, do: keyed_iters(iterables), else: {nil, list_iters(iterables)}
    count = length(iters)

    padding =
      cond do
        mode != :longest ->
          []

        padding_option == :undefined ->
          List.duplicate(:undefined, count)

        keyed? ->
          with_close_all(iters, fn -> for k <- keys, do: get(padding_option, k) end)

        true ->
          padding_from_iterable(padding_option, count, iters)
      end

    finish =
      if keyed? do
        fn results ->
          o = new_object([], :null)
          for {k, v} <- Enum.zip(keys, results), do: define_data(o, k, v)
          o
        end
      else
        &new_array/1
      end

    open = cell(Enum.map(iters, & &1))
    slots = cell(Enum.map(iters, &{:live, &1}))

    make_helper(
      fn -> zip_step(slots, open, mode, padding, finish, count) end,
      fn _ -> close_all(cell_get(open) |> Enum.map(&elem(&1, 0)), :normal) end
    )
  end

  # runs `fun`; an error closes the given iterator records
  defp with_close_all(iters, fun) do
    fun.()
  catch
    :throw, {:js_error, _} = e ->
      for {it, _} <- Enum.reverse(iters), do: close_throw(it)
      throw(e)
  end

  defp list_iters(iterables) do
    input = get_iterator(iterables)
    collect_inputs(input, [])
  end

  defp collect_inputs(input, iters) do
    # `iters` is newest first
    opened = fn -> iters |> Enum.reverse() |> Enum.map(&elem(&1, 0)) end

    next =
      try do
        step(input)
      catch
        :throw, {:js_error, _} = e -> close_all(opened.(), {:throw, e})
      end

    case next do
      :done ->
        Enum.reverse(iters)

      {:ok, v} ->
        rec =
          try do
            flattenable(v, false)
          catch
            :throw, {:js_error, _} = e ->
              close_all([elem(input, 0) | opened.()], {:throw, e})
          end

        collect_inputs(input, [rec | iters])
    end
  end

  defp keyed_iters(iterables) do
    keys = Props.all_own_keys(iterables)

    {ks, iters} =
      Enum.reduce(keys, {[], []}, fn k, {ks, iters} ->
        desc = guard(iters, fn -> Props.descriptor(iterables, k) end)

        if desc != :undefined and truthy(get(desc, "enumerable")) do
          value = guard(iters, fn -> get(iterables, k) end)

          if value == :undefined do
            {ks, iters}
          else
            rec =
              guard(iters, fn -> flattenable(value, false) end)

            {[k | ks], [rec | iters]}
          end
        else
          {ks, iters}
        end
      end)

    {Enum.reverse(ks), Enum.reverse(iters)}
  end

  # an error while collecting closes the iterators collected so far
  defp guard(iters_rev, fun) do
    fun.()
  catch
    :throw, {:js_error, _} = e ->
      close_all(Enum.map(Enum.reverse(iters_rev), &elem(&1, 0)), {:throw, e})
  end

  defp padding_from_iterable(padding_option, count, iters) do
    pi = guard_all(iters, fn -> get_iterator(padding_option) end)
    {values, using?} = take_padding(pi, count, iters, [], true)

    if using? do
      try do
        close_normal(elem(pi, 0))
      catch
        :throw, {:js_error, _} = e ->
          close_all(Enum.map(iters, &elem(&1, 0)), {:throw, e})
      end
    end

    values
  end

  defp guard_all(iters, fun) do
    fun.()
  catch
    :throw, {:js_error, _} = e ->
      close_all(Enum.map(iters, &elem(&1, 0)), {:throw, e})
  end

  defp take_padding(_pi, 0, _iters, acc, using?), do: {Enum.reverse(acc), using?}

  defp take_padding(pi, n, iters, acc, true) do
    case guard_all(iters, fn -> step(pi) end) do
      :done -> take_padding(pi, n - 1, iters, [:undefined | acc], false)
      {:ok, v} -> take_padding(pi, n - 1, iters, [v | acc], true)
    end
  end

  defp take_padding(pi, n, iters, acc, false),
    do: take_padding(pi, n - 1, iters, [:undefined | acc], false)

  # one round of the zip: a value from each iterator that is still live
  defp zip_step(_slots, _open, _mode, _padding, _finish, 0), do: :done

  defp zip_step(slots, open, mode, padding, finish, count) do
    case zip_collect(Enum.with_index(cell_get(slots)), slots, open, mode, padding, count, []) do
      :done -> :done
      {:ok, results} -> {:yield, finish.(results)}
    end
  end

  defp zip_collect([], _slots, _open, _mode, _padding, _count, acc), do: {:ok, Enum.reverse(acc)}

  defp zip_collect([{slot, i} | rest], slots, open, mode, padding, count, acc) do
    case slot do
      :exhausted ->
        zip_collect(rest, slots, open, mode, padding, count, [Enum.at(padding, i) | acc])

      {:live, rec} ->
        r =
          try do
            step(rec)
          catch
            :throw, {:js_error, _} = e ->
              remove_open(open, rec)
              close_all(open_iters(open), {:throw, e})
          end

        case r do
          {:ok, v} ->
            zip_collect(rest, slots, open, mode, padding, count, [v | acc])

          :done ->
            remove_open(open, rec)
            zip_done(i, rec, rest, slots, open, mode, padding, count, acc)
        end
    end
  end

  defp zip_done(i, _rec, rest, slots, open, mode, padding, count, acc) do
    case mode do
      :shortest ->
        close_all(open_iters(open), :normal)
        :done

      :strict ->
        if i != 0 do
          close_all(
            open_iters(open),
            {:throw, make_type_error("Iterator.zip: iterators have different lengths")}
          )
        end

        strict_check(Enum.with_index(cell_get(slots)) |> Enum.drop(1), open)
        :done

      :longest ->
        if cell_get(open) == [] do
          :done
        else
          slots_list = cell_get(slots) |> List.replace_at(i, :exhausted)
          cell_put(slots, slots_list)
          zip_collect(rest, slots, open, mode, padding, count, [Enum.at(padding, i) | acc])
        end
    end
  end

  defp strict_check([], _open), do: :ok

  defp strict_check([{{:live, rec}, _} | rest], open) do
    r =
      try do
        step(rec)
      catch
        :throw, {:js_error, _} = e ->
          remove_open(open, rec)
          close_all(open_iters(open), {:throw, e})
      end

    case r do
      :done ->
        remove_open(open, rec)
        strict_check(rest, open)

      {:ok, _} ->
        close_all(
          open_iters(open),
          {:throw, make_type_error("Iterator.zip: iterators have different lengths")}
        )
    end
  end

  defp strict_check([_ | rest], open), do: strict_check(rest, open)

  defp make_type_error(msg) do
    try do
      throw_error("TypeError", msg)
    catch
      :throw, {:js_error, _} = e -> e
    end
  end

  defp remove_open(open, rec), do: cell_put(open, List.delete(cell_get(open), rec))
  defp open_iters(open), do: Enum.map(cell_get(open), &elem(&1, 0))
end
