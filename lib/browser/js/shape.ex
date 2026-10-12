defmodule Browser.JS.Shape do
  @moduledoc """
  The shapes of the fast records (data-model step A1, `design-shapes.md` 2.1 to 2.3).

  A record in fast mode keeps its own keys in a shape and their values in the tuple `vals`
  (see `Browser.JS.Obj`). A shape is an immutable term that many records share:

      {:js_shape, sid, index, keys, bits, flags, enum}

  * `sid`: a positive integer that no other shape of this process has. The counter
    `:js_shape_next` gives it, and nothing resets the counter, also not `Interp.init/1`.
    The root shapes (no key) have the `sid`s 0 (plain objects), -1 (arrays) and -2
    (functions), see "The roots".
  * `index`: a map of each key to its position in `vals` (1-based). A key is a string, a
    symbol `{:symbol, id, description}` or a private name `{:private, ref}`.
  * `keys`: a tuple of the keys in creation order. Position `i` holds the key of value `i`.
  * `bits`: a tuple of the attributes of each key: writable `1`, enumerable `2`,
    configurable `4`. A key with the default attributes has `7`. A private name has `5`,
    because it is not in the key order.
  * `flags`: `1` when the object is not extensible, `2` when an enumerable key is a symbol
    (then `Obj.plain_names/1` gives `nil`), `8` when a key is a symbol (else
    `Obj.symbol_keys/1` does not look at the keys). The bits `16` to `128` count the
    changes of attributes (`reconf/3`). The bits from `256` up count the new shapes in a
    row that the adds of the chain made (see the limits).
  * `enum`: the enumerable string keys in creation order, which `Object.keys` gives. It is
    made once, when the shape is made.

  A shape holds no heap id, so the garbage collector does not walk it, and the compiled
  code can keep a shape that it made when it compiled: the shape of an object literal
  (`Obj.literal_keys/1`, step A3) and the shape after an add in an add cell. The term
  stays correct after an erase of the transition table and in a new heap, so the closure
  keeps it. After an erase, the next generic add from the root can make a new shape with
  the same keys, which holds the same properties. An accessor is a value
  `{:accessor, getter, setter}` in `vals`, as in a dictionary record, so a shape does not
  tell an accessor from a data property.

  ## The roots

  A record starts with the root of its class (step A4): an array starts with the root
  `-1`, a function with the root `-2`, and every other record with the root `0`. Thus a
  shape belongs to one of these three kinds of records, and two records with the same
  `sid` are of the same kind. An inline cache tests only the `sid`, and this makes the
  test exact: an array reads `length` and a function reads `name`, `length` and
  `prototype` in a different way than a plain object (these keys are not in the shape
  until a write makes them own keys), so a cell that a plain object made must never hit
  on an array or a function.

  ## The transition table

  The process key `{:jst, sid}` holds the transitions of the shape `sid`: a map of a key to
  a map of the bits to the child shape (an add), and the keys `{:reconf, position, bits}`,
  `:prevent` and `{:lock, freeze?, accessors}` for the other changes. The entry of a shape
  that an add made also holds `:up`, the shape before the add, for the `delete` of the last
  key. The key `{:dict, key, bits}` tells that an add of this key went to dictionary mode
  at the limit of new shapes in a row. Two records that get the same keys in the same order
  with the same attributes thus get the same shape.

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
  * the 9th new shape in a row in the chain of a record: an object that is used as a hash
    map gets keys that no other object has, so each add makes a new shape, which costs
    more than the add to a dictionary. The add then leaves the key `{:dict, key, bits}` in
    the table. The next record that makes the same add (the second object of a
    constructor) thus finds the chain used again, and it makes the shape, with the count
    at zero. The shapes of an object literal (`from_keys/1`) have no such limit, because
    their keys come from the source text;
  * more than 8 changes of attributes in the history of a shape.

  The roots have no limit of children: the first keys of the objects of a page are few,
  and the budget below stops a program that gives each object a new first key.

  The adds of the built-in objects have no limit of children and of new shapes in a row
  either (step A4): `Browser.JS.Builtins.built/1` sets the process key
  `:js_shape_realm` while it makes them. A built-in object gets many keys that no other
  object has, and the constructors give many children to the shape of a function with a
  `prototype`, so these limits would make many of them dictionaries. The realm is the
  same in each heap of a process, so its shapes are made once and found in the table
  after that. The limit of 128 keys stays.

  The table is erased when the shapes that it made since the last erase cost more than
  2,000,000 words. A new shape of `n` keys costs about `50 + 8 * n` words with its entries
  in the table (the shape term, the index, the tuples, the `enum` list, the `:up` entry,
  the entry in the table of the parent and the process dictionary). So the table holds at
  most about 16 MB.

  ## The switch

  The process key `:js_shapes` set to `false` turns fast records off: every record is then
  a dictionary record. The macros of `Browser.JS.Obj` that make a record read it (`on?/0`).
  No read of a property reads it. The oracle of `test/browser/js_shapes_test.exs` runs each
  program with the switch off and on, and compares the two runs.

  ## The inline caches (step A2)

  Each named read and write of the compiled code (`o.k`, `o.k = v`, `o.k()`, `o.k += v`,
  `o.k++`) has a site number, which `new_site/0` gives when the site compiles. The number is
  a negative integer, and the cell of the site is the process key with that number. A heap
  id is 0 or more, so a cell is never a heap entry, and a closure that keeps its site
  number keeps no heap id (the capture rule of `Browser.JS.Compile`). The counter
  `:js_ic_next` is never reset, also not by `Interp.init/1` or by an erase of the code
  cache: a live closure keeps its number after an erase, and two sites must never share a
  cell.

  A cell tells where the last record that the site saw holds the key, as the shape of that
  record gives it. The last element of each cell is the count of the misses that wrote
  the cell. `Browser.JS.Interp.get_ic/3`, `put_ic/4` and `strict_put_ic/4` read and write
  the cells:

  | Cell | Kind | A hit needs |
  |---|---|---|
  | `{sid, pos, n}` | own data | the record has the shape `sid`, and value `pos` is not an accessor |
  | `{sid, :get, pos, n}` | own getter | the same, and value `pos` is an accessor |
  | `{sid, pid, psid, pos, n}` | data of the prototype | the record has `sid`, its prototype is `{:obj, pid}`, the record at `pid` has the shape `psid`, and its value `pos` is not an accessor |
  | `{sid, :get, pid, psid, pos, n}` | getter of the prototype | the same, and the value is an accessor |
  | `{sid, pid1, psid1, pid2, psid2, pos, n}` | data of the prototype of the prototype | as above for `pid1`, and the prototype of `pid1` is `{:obj, pid2}` with the shape `psid2` |
  | `{sid, :get, pid1, psid1, pid2, psid2, pos, n}` | a getter there | the same, and the value is an accessor |
  | `{sid, child, protos, n}` | add (step A3) | the record has `sid` and the class `:object`, its prototype chain is the list of ids `protos`, and no record of the chain holds the key or is a proxy |
  | `{:add, sid, n}` | first miss of an add (step A3) | never: the next miss of a record with the shape `sid` makes the add cell |
  | `{sid, n}` | the generic path | the record has `sid`: the site takes the generic path, and it does not look for a cell again |
  | `{nil, n}` | none | never: an add went to dictionary mode at a limit, so the next record of the shape misses again |
  | `:mega` | the generic path | always: the site had 16 misses |

  A write site uses only `{sid, pos, n}` (a writable data property of the record), the add
  cell, `{:add, sid, n}`, `{sid, n}` and `{nil, n}`. An add site gets its add cell at its
  second miss with the same shape, so that a site that runs once (the code of a module,
  the set-up of an object) does not pay for the walk of the chain and for a cell that no
  record uses. An add cell gives the record the shape `child` (the
  shape after the add) and the new value at the end, with no walk of the prototype chain
  and no read of the transition table (the part "add cells" of `Browser.JS.Interp` tells
  why its test of the chain is exact). A read or write cell is made only from fast
  records that read the key as a plain object does: a plain object, an array for a key
  other than `length`, and a function for a key other than `name`, `length` and
  `prototype` (step A4, `Interp.ic_ok?/2`). It is made after the generic path found the
  key there. An add cell is made only from a fast record of the class `:object`; its chain
  can hold any record that is not a proxy, in fast mode or in dictionary mode. From step
  A4 the built-in prototypes are fast, so a read of a method of `Object.prototype`,
  `Array.prototype` or `Function.prototype` hits a cell of a prototype. A dictionary
  record, a host object and a proxy never get a cell, and every operation on them takes
  the generic path. On a miss, the site takes the generic path and writes the cell
  again. After 16 misses the cell becomes `:mega`, so
  that a site that sees many shapes does not pay for the search of a cell at each run.

  The count is of all the misses in the life of the site, not of the misses in a row. A
  hit does not set it back to zero, and `Interp.init/1` does not either. Thus a site that
  sees one shape nearly always, but a different shape now and then, becomes `:mega` after
  16 such misses. A count in a row was measured on TodoMVC-React-Complex-DOM: it got 0.45%
  more hits, but 24 times more misses, because a site that sees a few shapes in turn then
  never becomes `:mega` and a miss is the most expensive read. A read at a `:mega` site
  costs less than the generic read before step A2. Do not change the count to a count in a
  row without a new measurement. In a new heap that keeps the code cache, the prototypes
  have new ids and a record can get a new shape, so a site can count more misses in each
  heap.

  A site that runs only once costs about 10 to 15 reductions more than the generic path:
  the site number and its node of the budget when it compiles, and a miss that writes the
  cell when it runs. A read site pays this back after about 4 or 5 hits.

  A hit is exact because a shape is immutable and a `sid` is never given two times in a
  process. The shape `sid` tells that a record has the key at the position `pos` with the
  same attributes, or that it does not have the key. The shape does not tell an accessor
  from a data property, so each hit looks at the value. The prototype of a record is not
  in its shape, so a cell of a prototype compares the prototype link of each record on the
  path. `Object.setPrototypeOf` changes the link, so the cell misses. A change of the keys
  or of the attributes of a prototype gives it a new shape, so the cell misses. A freed
  prototype gives `:undefined`, because the heap does not give an id two times, so the
  cell misses. A new heap (`Interp.init/1`) gives the ids from 0 again, and a cell can then
  read an object of the new heap with the same id. This is still exact: the cell reads a
  value only of a record with the shape `psid`, and that shape tells what the value is.

  The cells belong to the code cache of `Browser.JS.Compile`. The budget of the cache
  counts each site as one node, and each write of an add cell as the nodes of the shape
  that it keeps (an erase of the transition table does not free that shape). An erase of
  the cache erases all the cells. A cell can
  hold the id of a prototype, but it is not a root of the garbage collector
  (`Browser.JS.GC`), so a cell never keeps an object alive.
  """

  import Bitwise

  @w 1
  @e 2
  @c 4

  @not_ext 1
  @enum_symbol 2
  @symbol 8
  @reconf_one 16
  @run_one 256

  @max_keys 128
  @max_children 64
  @max_reconf 8
  @max_run 8
  @budget 2_000_000

  @root {:js_shape, 0, %{}, {}, {}, 0, []}
  @array_root {:js_shape, -1, %{}, {}, {}, 0, []}
  @function_root {:js_shape, -2, %{}, {}, {}, 0, []}

  @doc "The shape with no key. `Browser.JS.Obj` puts it in its macros as a literal."
  def root_shape, do: @root

  @doc "The shape with no key of an array (see \"The roots\")."
  def array_root_shape, do: @array_root

  @doc "The shape with no key of a function (see \"The roots\")."
  def function_root_shape, do: @function_root

  @doc "The root shape of a record of the class `class` (see \"The roots\")."
  def root_of(:array), do: @array_root
  def root_of(:function), do: @function_root
  def root_of(_class), do: @root

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
  def add(sh, key, b), do: add(sh, key, b, true)

  # `add/3`; `limit?` false for a key from the source text, which the limit of new shapes in
  # a row does not count (`from_keys/1`). (an index-like key never has a transition, so the
  # test comes before the read of the table)
  defp add({:js_shape, sid, _, _, _, _, _} = sh, key, b, limit?) do
    if index_like?(key) do
      :dict
    else
      case :erlang.get({:jst, sid}) do
        %{^key => %{^b => child}} -> child
        :undefined -> make_add(sh, %{}, key, b, limit?)
        t -> make_add(sh, t, key, b, limit?)
      end
    end
  end

  defp make_add({:js_shape, sid, index, keys, bits, flags, enum} = sh, t, key, b, limit?) do
    n = tuple_size(keys)
    # (the adds of the built-in objects have no limit of children and of new shapes in a
    # row, see "The limits"; only an add that makes a new shape reads the process key)
    realm? = :erlang.get(:js_shape_realm) == true
    limit? = limit? and not realm?

    cond do
      n >= @max_keys ->
        :dict

      sid > 0 and map_size(t) > @max_children and not realm? ->
        :dict

      # (the chain made too many new shapes in a row: the first time, the record goes to
      # dictionary mode; the next time, the chain is used again and the count starts again)
      limit? and flags >>> 8 >= @max_run and not is_map_key(t, {:dict, key, b}) ->
        record(sid, t, {:dict, key, b}, true, 10)
        :dict

      true ->
        e = e?(b)

        flags =
          case key do
            {:symbol, _, _} when e -> flags ||| @enum_symbol ||| @symbol
            {:symbol, _, _} -> flags ||| @symbol
            _ -> flags
          end

        flags =
          if limit? and not is_map_key(t, {:dict, key, b}),
            do: flags + @run_one,
            else: flags &&& @run_one - 1

        enum = if e and is_binary(key), do: enum ++ [key], else: enum

        child =
          {:js_shape, next_sid(), Map.put(index, key, n + 1), :erlang.append_element(keys, key),
           :erlang.append_element(bits, b), flags, enum}

        # (the entry `:up` comes first, so that an erase in `record/5` also erases it)
        :erlang.put({:jst, elem(child, 1)}, %{up: sh})
        t = Map.delete(t, {:dict, key, b})
        record(sid, t, key, Map.put(Map.get(t, key, %{}), b, child), 50 + 8 * (n + 1))
        child
    end
  end

  # (a string that starts with a digit can be an array index, see `Obj.plain_names/1`)
  defp index_like?(<<c, _::binary>>) when c >= ?0 and c <= ?9, do: true
  defp index_like?(_), do: false

  @doc """
  The shape `sh` with the bits of the key at the position `pos` changed to `b`, or `:dict`
  when the shape has had too many such changes. The keys keep their positions, so the
  values do not change.
  """
  def reconf({:js_shape, sid, _, keys, bits, flags, _} = sh, pos, b) do
    cond do
      :erlang.element(pos, bits) == b ->
        sh

      (flags >>> 4 &&& 15) >= @max_reconf ->
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
      case add(sh, k, @w ||| @e ||| @c, false) do
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

      with true <- t == %{} and sid > 0,
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

    for sid <- [0, -1, -2], do: :erlang.erase({:jst, sid})
    for sid <- old, do: :erlang.erase({:jst, sid})
    for sid <- first..(next - 1)//1, do: :erlang.erase({:jst, sid})
    :erlang.put(:js_shape_since, {next, []})
    :erlang.erase(:js_shape_n)
    :ok
  end

  @doc """
  A new site number for an inline cache: a negative integer that no other site of this
  process has (see "The inline caches"). The compiler calls it when a named site compiles.
  """
  def new_site do
    n =
      case :erlang.get(:js_ic_next) do
        :undefined -> -1
        n -> n
      end

    :erlang.put(:js_ic_next, n - 1)
    n
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
