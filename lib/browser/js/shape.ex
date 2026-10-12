defmodule Browser.JS.Shape do
  @moduledoc """
  The shapes of the fast records (data-model step A1, `design-shapes.md` 2.1 to 2.3).

  A record in fast mode keeps its own keys in a shape and their values in the tuple `vals`
  (see `Browser.JS.Obj`). A shape is an immutable term that many records share:

      {:js_shape, sid, index, keys, bits, flags, enum}

  * `sid`: a positive integer that no other shape of this process has. The counter
    `:js_shape_next` gives it, and nothing resets the counter, also not `Interp.init/1`.
    The root shape (no key) has the `sid` 0.
  * `index`: a map of each key to its position in `vals` (1-based). A key is a string, a
    symbol `{:symbol, id, description}` or a private name `{:private, ref}`.
  * `keys`: a tuple of the keys in creation order. Position `i` holds the key of value `i`.
  * `bits`: a tuple of the attributes of each key: writable `1`, enumerable `2`,
    configurable `4`. A key with the default attributes has `7`. A private name has `5`,
    because it is not in the key order.
  * `flags`: `1` when the object is not extensible, `2` when an enumerable key is a symbol
    (then `Obj.plain_names/1` gives `nil`), `8` when a key is a symbol (else
    `Obj.symbol_keys/1` does not look at the keys). The bits from `16` up count the changes
    of attributes (`reconf/3`).
  * `enum`: the enumerable string keys in creation order, which `Object.keys` gives. It is
    made once, when the shape is made.

  A shape holds no heap id, so the garbage collector does not walk it, and the compiled
  code can keep a shape that it made when it compiled (an object literal). An accessor is a
  value `{:accessor, getter, setter}` in `vals`, as in a dictionary record, so a shape does
  not tell an accessor from a data property.

  ## The transition table

  The process key `{:jst, sid}` holds the transitions of the shape `sid`: a map of a key to
  a map of the bits to the child shape (an add), and the keys `{:reconf, position, bits}`,
  `:prevent` and `{:lock, freeze?, accessors}` for the other changes. The entry of a shape
  that an add made also holds `:up`, the shape before the add, for the `delete` of the last
  key. Two records that get the same keys in the same order with the same attributes thus
  get the same shape.

  The table is only for the sharing. A record keeps its shape term, and the term stays
  correct when the table goes. So `erase/0` can erase the table at any time: the next
  changes make new shapes with new `sid`s. The process key `:js_shape_since` holds the
  first `sid` after the last erase and the older `sid`s that got an entry since then, so
  that `erase/0` finds the entries without a walk of the process dictionary (which holds
  the heap). The table and its process keys are not roots of the garbage collector, because
  they hold no heap id (`Browser.JS.GC`).

  ## The limits

  A record goes from fast mode to dictionary mode once, and never back. A change that
  passes a limit gives `:dict`, and the caller then makes the record a dictionary:

  * more than 128 keys;
  * a string key that starts with a digit (an index-like key; the order of the spec puts
    the index keys first, and an object with such keys is often a hash map);
  * the 65th child of a shape other than the root (an object that is used as a hash
    map must not fill the table);
  * more than 8 changes of attributes in the history of a shape.

  The root has no limit of children: the first keys of the objects of a page are few, and
  the budget below stops a program that gives each object a new first key.

  The table is erased when the shapes that it made since the last erase cost more than
  2,000,000 words. A new shape of `n` keys costs about `50 + 8 * n` words with its entries
  in the table (the shape term, the index, the tuples, the `enum` list, the `:up` entry,
  the entry in the table of the parent and the process dictionary). So the table holds at
  most about 16 MB.

  ## The switch

  The process key `:js_shapes` set to `false` turns fast records off: every record is then
  a dictionary record. The functions that make a record read it (`on?/0`). No read of a
  property reads it. The oracle of `test/browser/js_shapes_test.exs` runs each program with
  the switch off and on, and compares the two runs.
  """

  import Bitwise

  @w 1
  @e 2
  @c 4

  @not_ext 1
  @enum_symbol 2
  @symbol 8
  @reconf_one 16

  @max_keys 128
  @max_children 64
  @max_reconf 8
  @budget 2_000_000

  @root {:js_shape, 0, %{}, {}, {}, 0, []}

  @doc "The shape with no key. `Browser.JS.Obj` puts it in its macros as a literal."
  def root_shape, do: @root

  @doc "Whether the functions that make a record make fast records (the switch `:js_shapes`)."
  defmacro on? do
    quote do: :erlang.get(:js_shapes) != false
  end

  @doc "Whether the bits `b` have the writable bit."
  defmacro w?(b), do: quote(do: (unquote(b) &&& unquote(@w)) != 0)
  @doc "Whether the bits `b` have the enumerable bit."
  defmacro e?(b), do: quote(do: (unquote(b) &&& unquote(@e)) != 0)
  @doc "Whether the bits `b` have the configurable bit."
  defmacro c?(b), do: quote(do: (unquote(b) &&& unquote(@c)) != 0)

  @doc "Whether the flags `f` of a shape let the object get new keys."
  defmacro extensible?(f), do: quote(do: (unquote(f) &&& unquote(@not_ext)) == 0)

  @doc """
  The child of the shape `sh` with the new key `key` with the bits `b` at the end, or
  `:dict` when the add passes a limit. The key must not be in `sh`.
  """
  def add({:js_shape, sid, _, _, _, _, _} = sh, key, b) do
    case :erlang.get({:jst, sid}) do
      %{^key => %{^b => child}} -> child
      :undefined -> make_add(sh, %{}, key, b)
      t -> make_add(sh, t, key, b)
    end
  end

  defp make_add({:js_shape, sid, index, keys, bits, flags, enum} = sh, t, key, b) do
    n = tuple_size(keys)

    cond do
      n >= @max_keys ->
        :dict

      index_like?(key) ->
        :dict

      sid != 0 and map_size(t) > @max_children ->
        :dict

      true ->
        e = e?(b)

        flags =
          case key do
            {:symbol, _, _} when e -> flags ||| @enum_symbol ||| @symbol
            {:symbol, _, _} -> flags ||| @symbol
            _ -> flags
          end

        enum = if e and is_binary(key), do: enum ++ [key], else: enum

        child =
          {:js_shape, next_sid(), Map.put(index, key, n + 1), :erlang.append_element(keys, key),
           :erlang.append_element(bits, b), flags, enum}

        # (the entry `:up` comes first, so that an erase in `record/5` also erases it)
        :erlang.put({:jst, elem(child, 1)}, %{up: sh})
        record(sid, t, key, Map.put(Map.get(t, key, %{}), b, child), 50 + 8 * (n + 1))
        child
    end
  end

  # (a string that starts with a digit can be an array index, see `Obj.plain_names/1`)
  defp index_like?(<<c, _::binary>>) when c >= ?0 and c <= ?9, do: true
  defp index_like?(_), do: false

  @doc """
  The shape before the last add that made `sh`, or `nil`: the shape of a record after the
  `delete` of its last key. A shape that a change of attributes or an integrity level made
  has none, and the table can be erased, so the caller must take `nil`.
  """
  def parent({:js_shape, sid, _, _, _, _, _}) do
    case table(sid) do
      %{up: up} -> up
      _ -> nil
    end
  end

  @doc """
  The shape `sh` with the bits of the key at the position `pos` changed to `b`, or `:dict`
  when the shape has had too many such changes. The keys keep their positions, so the
  values do not change.
  """
  def reconf({:js_shape, sid, _, keys, bits, flags, _} = sh, pos, b) do
    cond do
      :erlang.element(pos, bits) == b ->
        sh

      flags >>> 4 >= @max_reconf ->
        :dict

      true ->
        k = {:reconf, pos, b}

        case table(sid) do
          %{^k => child} ->
            child

          t ->
            bits = :erlang.setelement(pos, bits, b)
            child = remake(keys, bits, flags + @reconf_one)
            record(sid, t, k, child, 50 + 8 * tuple_size(keys))
            child
        end
    end
  end

  @doc "The shape `sh` with the flag of an object that is not extensible."
  def prevent({:js_shape, sid, _, keys, bits, flags, _} = sh) do
    if (flags &&& @not_ext) != 0 do
      sh
    else
      case table(sid) do
        %{prevent: child} ->
          child

        t ->
          child = remake(keys, bits, flags ||| @not_ext)
          record(sid, t, :prevent, child, 50 + 8 * tuple_size(keys))
          child
      end
    end
  end

  @doc """
  The shape `sh` sealed (`freeze?` false) or frozen. Each key that is not a private name
  becomes not configurable, and each data property also not writable when frozen. The
  positions of the accessors are in `accessors`, because the shape does not know them.
  """
  def lock({:js_shape, sid, _, keys, bits, flags, _}, freeze?, accessors) do
    k = {:lock, freeze?, accessors}

    case table(sid) do
      %{^k => child} ->
        child

      t ->
        bits =
          Enum.reduce(1..tuple_size(keys)//1, bits, fn i, bits ->
            case :erlang.element(i, keys) do
              {:private, _} ->
                bits

              _ ->
                b = :erlang.element(i, bits) &&& bnot(@c)
                b = if freeze? and i not in accessors, do: b &&& bnot(@w), else: b
                :erlang.setelement(i, bits, b)
            end
          end)

        child = remake(keys, bits, flags ||| @not_ext)
        record(sid, t, k, child, 50 + 8 * tuple_size(keys))
        child
    end
  end

  @doc """
  The shape of the keys `keys` (distinct, in creation order) with the default attributes,
  through the transitions from the root, or `nil` when a limit stops it. The compiler uses
  it for an object literal.
  """
  def from_keys(keys) do
    Enum.reduce_while(keys, @root, fn k, sh ->
      case add(sh, k, @w ||| @e ||| @c) do
        :dict -> {:halt, nil}
        child -> {:cont, child}
      end
    end)
  end

  # A new shape with the keys `keys`, the bits `bits` and the flags `flags`: the index, the
  # symbol flag and the `enum` list come from the keys and the bits.
  defp remake(keys, bits, flags) do
    list = Tuple.to_list(keys)
    index = Map.new(Enum.with_index(list, 1))

    enum =
      for {k, i} <- Enum.with_index(list, 1),
          is_binary(k) and e?(:erlang.element(i, bits)),
          do: k

    symbol? =
      Enum.any?(Enum.with_index(list, 1), fn {k, i} ->
        match?({:symbol, _, _}, k) and e?(:erlang.element(i, bits))
      end)

    flags = if symbol?, do: flags ||| @enum_symbol, else: flags &&& bnot(@enum_symbol)
    {:js_shape, next_sid(), index, keys, bits, flags, enum}
  end

  # The transitions of the shape `sid`.
  defp table(sid) do
    case :erlang.get({:jst, sid}) do
      :undefined -> %{}
      t -> t
    end
  end

  # Writes the transition `k` of the shape `sid` (its table is `t`) to `child`, and counts
  # the cost `words` of the new entry. Past the budget the whole table goes, and the
  # transition is not written. A shape from before the last erase that gets its first entry
  # goes into the list of `:js_shape_since`, so that the next erase finds it.
  defp record(sid, t, k, child, words) do
    used =
      case :erlang.get(:js_shape_n) do
        :undefined -> words
        used -> used + words
      end

    if used > @budget do
      erase()
    else
      :erlang.put(:js_shape_n, used)

      with true <- t == %{} and sid != 0,
           {first, old} when sid < first <- since() do
        :erlang.put(:js_shape_since, {first, [sid | old]})
      end

      :erlang.put({:jst, sid}, Map.put(t, k, child))
    end
  end

  # The first `sid` after the last erase, and the older `sid`s with an entry.
  defp since do
    case :erlang.get(:js_shape_since) do
      :undefined -> {1, []}
      since -> since
    end
  end

  @doc """
  Erases the transition table. The records keep their shapes, which stay correct, and the
  next changes make new shapes. The `sid`s only go up, so the entries are those of the root,
  of the `sid`s from the first after the last erase, and of the older `sid`s in the list.
  The cost is thus that of the shapes, not that of the heap.
  """
  def erase do
    {first, old} = since()

    next =
      case :erlang.get(:js_shape_next) do
        :undefined -> 1
        n -> n
      end

    :erlang.erase({:jst, 0})
    for sid <- old, do: :erlang.erase({:jst, sid})
    for sid <- first..(next - 1)//1, do: :erlang.erase({:jst, sid})
    :erlang.put(:js_shape_since, {next, []})
    :erlang.erase(:js_shape_n)
    :ok
  end

  defp next_sid do
    n =
      case :erlang.get(:js_shape_next) do
        :undefined -> 1
        n -> n
      end

    :erlang.put(:js_shape_next, n + 1)
    n
  end
end
