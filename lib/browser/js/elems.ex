defmodule Browser.JS.Elems do
  @moduledoc """
  The elements of an array (data-model step B2, `design-shapes.md` 2.7 and
  `design-arrays.md` 2).

  This module is the only module that reads or writes the fields of a heap record that hold
  the elements of an array or of an arguments object: `vec`, `items` and `len`. The other
  modules call the functions, macros and guards here. Thus a change of the representation
  of the elements changes this module alone. The `length` of an arguments object is an
  ordinary own property (`Browser.JS.Obj`), not the length here.

  ## The two forms

  An array record is in the **dense form** or in the **sparse form**:

  * Dense: the field `vec` holds a tuple of the elements. Element `i` is at position
    `i + 1`. Each element is a data value with the default attributes (writable,
    enumerable, configurable), and the tuple has no hole. So the `length` of the array is
    `tuple_size(vec)`, and the record has no field `items` and no field `len`. A tuple
    holds at most `max/0` elements.
  * Sparse: the field `items` holds a map of each index to its item, and the field `len`
    holds the length. An item is a value or an accessor `{:accessor, getter, setter}`. An
    index that is not in the map has no element (a hole). This is the form of the records
    before step B2.

  The two forms hold the same elements, and each function here gives the same result for
  the same elements in the two forms. The store oracle (`test/browser/js_elems_test.exs`)
  compares each function with a plain map, and the form oracle
  (`test/browser/js_elems_form_test.exs`) runs the corpus with all arrays sparse and then
  with the dense form, and compares the results, the console, the heap ids and the heap
  count.

  A dense record has a tuple with no holes, so a read is one `:erlang.element/2`, a write
  in bounds is one `:erlang.setelement/3`, and a literal or a `push` makes no map. The
  record also has two fields less, and the collector visits one word for each element in
  place of a pair of a map.

  ## From the dense form to the sparse form

  A record goes from the dense form to the sparse form once, and it never goes back (step
  B2 has no way back, so that an array that changes form often costs no more than an
  array that is always sparse). These changes make the sparse form:

  * a hole: a write after the end + 1, a `delete` of an element, a `length` that becomes
    larger;
  * an accessor or an attribute that is not the default on an element
    (`Object.defineProperty`, `Browser.JS.Obj.put_element_attrs/3`);
  * `Object.freeze`, `Object.seal` and `Object.preventExtensions`
    (`Browser.JS.Obj.lock/2` and `Browser.JS.Obj.prevent/1`);
  * a `length` that becomes not writable;
  * more than `max/0` elements.

  An arguments object is always sparse: its `length` is an own property, and its mapped
  elements follow the parameters. A shrink of `length` cuts the tuple, and the record stays
  dense.

  Thus a dense record is never frozen, sealed or not extensible, its `length` is writable,
  and it has no attribute of an element. A write in bounds needs no test of these, and an
  append needs only the test of the prototype chain (`std_chain?/1`).

  ## The size limit

  `max/0` is 128. A write copies the whole tuple, and an append makes a new tuple, so the
  cost of a write grows with the size. Measured with limits of 32, 64, 128 and 256: at
  128, a read or a write of an array of 65 to 128 elements is 25 to 35% faster than in the
  sparse form, and a `slice` of such an array is 6 times faster. An array that grows past
  the limit pays for the copies of the appends before it, about 1% more for each push of a
  loop of 1,024 pushes than with a limit of 64. At 256, that cost is 3 times larger.

  ## The form switch

  The process key `:js_elems_sparse` set to `true` makes the functions that make a new
  record (`new/2`, `from_map/3` and `put_empty/1`) give the sparse form. No other function
  reads the key: a record that is sparse stays sparse, so the other functions need not
  read it. The form oracle uses it.

  ## Hot paths

  The guard `dense_index?/2` with the macro `dense_at/2`, and the macro `get/3` with
  `none/0`, let a hot caller read an element inline with no call: the read of an element
  in `Browser.JS.Interp`, a for-of loop, the callbacks of the array methods and
  `ArrayGeneric`. `get/3` searches the map of a sparse record one time. `dense_put/3` and
  `dense_append/2` let the write of an element in bounds and at the end take no call
  either. The other functions are calls.

  ## The grep gate

  No module other than this one names the fields. This command finds the direct uses
  outside this module: a field after a dot, a field as a key of a map or a keyword list,
  and a field atom in any other place. Comment lines do not count, and the last stage
  removes the lines of the allow-list below. So the command prints nothing.
  `test/browser/js_elems_test.exs` runs the same search with the same patterns, and it
  fails when they are not the same as here.

      grep -rnP '\\.(items|len|vec)\\b(?![?!(])|\\b(items|len|vec):|(?<![{\\w:]):(items|len|vec)\\b' lib/browser/js --include=*.ex | grep -vP '^[^:]+:\\d+:\\s*#' | grep -v '^lib/browser/js/elems.ex:' | grep -vP '^lib/browser/js/binary_encoding\\.ex:\\d+:.*(\\bst\\.len\\b|\\blen: (byte_size\\(str\\)|len\\b))'

  The allow-list: the state of the decoder of `lib/browser/js/binary_encoding.ex` has a
  field `len` (the size of the input). It is not a heap record.

  ## The garbage collector

  The collector (`Browser.JS.GC`) walks the tuple `vec` as any tuple: each element is a JS
  value, and a JS value is never a frame or a shape, so the walk sees each element once.
  A dense record has no `len`, so its length is not an integer that the walk reads as a
  heap id.
  """

  require Browser.JS.Obj

  @max 128

  @doc "The most elements that a dense record holds."
  def max, do: @max

  @doc false
  # Whether the functions that make a record give the sparse form (the form switch).
  defmacro sparse_on? do
    quote do: :erlang.get(:js_elems_sparse) == true
  end

  # ── guards and inline reads ──────────────────────────────────

  @doc "Whether the array record `o` is dense."
  defguard dense?(o) when is_map_key(o, :vec)

  @doc """
  Whether the array record `o` is dense and has an element at the index `i` (an integer
  of 0 or more).
  """
  defguard dense_index?(o, i)
           when is_map_key(o, :vec) and i < tuple_size(:erlang.map_get(:vec, o))

  @doc """
  Whether the array record `o` is dense and `i` is its length, which a dense append can
  write.
  """
  defguard dense_append?(o, i)
           when is_map_key(o, :vec) and i == tuple_size(:erlang.map_get(:vec, o)) and
                  i < @max

  @doc "Whether the array record `o` is sparse and has an item at the index `i`."
  defguard sparse_index?(o, i)
           when is_map_key(o, :items) and is_map_key(:erlang.map_get(:items, o), i)

  @doc "Whether the array record `o` has an element (or an item) at the index `i`."
  defguard has?(o, i) when dense_index?(o, i) or sparse_index?(o, i)

  @doc "Whether the array record `o` has no element."
  defguard empty?(o)
           when (is_map_key(o, :vec) and tuple_size(:erlang.map_get(:vec, o)) == 0) or
                  (is_map_key(o, :items) and map_size(:erlang.map_get(:items, o)) == 0)

  @doc "The element at `i` of a record for which `dense_index?/2` is true."
  defmacro dense_at(o, i) do
    quote do: :erlang.element(unquote(i) + 1, :erlang.map_get(:vec, unquote(o)))
  end

  @doc """
  `o` with `v` at the index `i`, for a record for which `dense_index?/2` is true. The
  value must be a data value: the element keeps the default attributes.
  """
  defmacro dense_put(o, i, v) do
    quote bind_quoted: [o: o, i: i, v: v] do
      %{o | vec: :erlang.setelement(i + 1, :erlang.map_get(:vec, o), v)}
    end
  end

  @doc """
  `o` with `v` after its last element, for a record for which `dense_append?/2` is true.
  """
  defmacro dense_append(o, v) do
    quote bind_quoted: [o: o, v: v] do
      %{o | vec: :erlang.append_element(:erlang.map_get(:vec, o), v)}
    end
  end

  @doc """
  The length of the array record `o`. For an arguments object it is the count of the
  arguments when the object was made, or more after `define/3`. It is not the `length` of
  the arguments object (an own property), and it does not bound the own keys, because
  `put/3` can add an element at this length or after it.
  """
  defmacro len(o) do
    quote generated: true do
      case unquote(o) do
        %{vec: vec} -> tuple_size(vec)
        %{len: len} -> len
      end
    end
  end

  @doc "The item at the index `i` of the array record `o`: `{:ok, item}` or `:error`."
  defmacro fetch(o, i) do
    quote generated: true, bind_quoted: [o: o, i: i] do
      case o do
        %{vec: vec} when i < tuple_size(vec) -> {:ok, :erlang.element(i + 1, vec)}
        %{items: %{^i => x}} -> {:ok, x}
        _ -> :error
      end
    end
  end

  @doc """
  An atom that is never a JS value, for the `default` of `get/3`: a caller can match it
  in a pattern and so tell a missing item from any item.
  """
  defmacro none, do: :"$elems_none"

  @doc """
  The item at the index `i` of the array record `o`, or `default`. For a sparse record
  this is one search of the map of the items, where a test of `sparse_index?/2` and a read
  of the item would be two.
  """
  defmacro get(o, i, default) do
    quote generated: true, bind_quoted: [o: o, i: i, default: default] do
      case o do
        %{vec: vec} when i < tuple_size(vec) -> :erlang.element(i + 1, vec)
        %{items: %{^i => x}} -> x
        _ -> default
      end
    end
  end

  @doc """
  Whether the prototype chain of the array record `o` can hold no element: the chain is
  `Array.prototype` and then `Object.prototype`, `Array.prototype` has no element, and
  `Object.prototype` has no key that is an index. Then no element of the chain shows
  through a hole or after the end, and the write of a new element calls no setter there
  and fails at no key that is not writable. A fast record never holds a key that starts
  with a digit (`Browser.JS.Shape`), so a fast `Object.prototype` needs no walk of its
  keys. The process keys of the prototypes and the records are read with no call.
  """
  defmacro std_chain?(o), do: chain_test(o, true)

  @doc """
  `std_chain?/1` without the walk of the names of `Object.prototype`: it is false when
  `Object.prototype` is not a fast record (a dictionary record, after a `delete` of one of its keys or after many
  adds). The write of one element calls it, so that its cost does not grow with the count
  of the keys of `Object.prototype`. A false result costs only speed: the caller takes the
  generic path, which looks for the one index in the chain.
  """
  defmacro std_chain_fast?(o), do: chain_test(o, false)

  defp chain_test(o, walk?) do
    quote do
      {:obj, apid} = ap = :erlang.get({:proto, :array})

      :erlang.map_get(:proto, unquote(o)) == ap and
        case :erlang.get(apid) do
          %{proto: {:obj, opid} = op} = arr when Browser.JS.Elems.empty?(arr) ->
            op == :erlang.get({:proto, :object}) and
              case :erlang.get(opid) do
                op_rec when Browser.JS.Obj.fast?(op_rec) ->
                  true

                op_rec ->
                  unquote(walk?) and
                    Browser.JS.Obj.plain_names?(Browser.JS.Obj.string_keys(op_rec))
              end

          _ ->
            false
        end
    end
  end

  # ── new records ──────────────────────────────────────────────

  @doc """
  A new array record with the elements `list` (data values) and the prototype `proto`. It
  is dense when the list has at most `max/0` elements and the form switch is off.
  """
  def new(list, proto) do
    if length(list) <= @max and not sparse_on?() do
      Browser.JS.Obj.array_record(class: :array, vec: :erlang.list_to_tuple(list), proto: proto)
    else
      Browser.JS.Obj.array_record(
        class: :array,
        items: list_map(list),
        len: length(list),
        proto: proto
      )
    end
  end

  @doc """
  `new/2` with the elements in the tuple `vec`, which has at most `max/0` elements.
  """
  def new_vec(vec, proto) do
    if sparse_on?(),
      do: new(:erlang.tuple_to_list(vec), proto),
      else: Browser.JS.Obj.array_record(class: :array, vec: vec, proto: proto)
  end

  @doc """
  A new array record with the items `items` (a map of each index to its item) and the
  length `len`. It is dense when it has no hole and no accessor, `len` is at most `max/0`
  and the form switch is off.
  """
  def from_map(items, len, proto) do
    case if(sparse_on?(), do: nil, else: map_vec(items, len)) do
      nil -> Browser.JS.Obj.array_record(class: :array, items: items, len: len, proto: proto)
      vec -> Browser.JS.Obj.array_record(class: :array, vec: vec, proto: proto)
    end
  end

  # The tuple of the items `items` with the length `len`, or nil when they have a hole or
  # an accessor, or when `len` is more than `max/0`.
  defp map_vec(items, len) do
    if map_size(items) == len and len <= @max and not any_accessor_in?(items),
      do: :erlang.list_to_tuple(for(i <- 0..(len - 1)//1, do: :erlang.map_get(i, items)))
  end

  @doc """
  The record `o` (a record that has no elements yet, as `Array.prototype` when the realm
  is made) with no element, in the form of `new/2`.
  """
  def put_empty(o) do
    if sparse_on?(),
      do: o |> Map.put(:items, %{}) |> Map.put(:len, 0),
      else: Map.put(o, :vec, {})
  end

  @doc """
  The record `o` (an arguments object that has no elements yet) with the elements `list`,
  in the sparse form: an arguments object is always sparse.
  """
  def put_args(o, list), do: o |> Map.put(:items, list_map(list)) |> Map.put(:len, length(list))

  # (one pass that makes the pairs, then the map BIF: this costs less than `Enum.with_index/1`
  # and `Map.new/2` with a function)
  defp list_map(list), do: :maps.from_list(index_pairs(list, 0))

  defp index_pairs([v | rest], i), do: [{i, v} | index_pairs(rest, i + 1)]
  defp index_pairs([], _), do: []

  # ── the change of form ───────────────────────────────────────

  @doc "The array record `o` in the sparse form (see the moduledoc)."
  def sparse(%{vec: vec} = o) do
    o
    |> Map.delete(:vec)
    |> Map.put(:items, list_map(:erlang.tuple_to_list(vec)))
    |> Map.put(:len, tuple_size(vec))
  end

  def sparse(o), do: o

  # ── reads ────────────────────────────────────────────────────

  @doc "The indices of the elements (and items) of the array record `o`, in ascending order."
  def keys(%{vec: vec}), do: :lists.seq(0, tuple_size(vec) - 1)
  def keys(%{items: items}), do: items |> Map.keys() |> :lists.sort()

  @doc "The count of the elements (and items) of the array record `o`."
  def count(%{vec: vec}), do: tuple_size(vec)
  def count(%{items: items}), do: map_size(items)

  @doc "The items of the array record `o` as a map of each index to its item."
  def to_map(%{vec: vec}), do: list_map(:erlang.tuple_to_list(vec))
  def to_map(%{items: items}), do: items

  @doc """
  The items of the array record `o` from index 0 to its length - 1, with `:undefined` for
  a hole. An accessor stays an accessor.
  """
  def to_list(%{vec: vec}), do: :erlang.tuple_to_list(vec)

  def to_list(%{items: items, len: len}),
    do: for(i <- 0..(len - 1)//1, do: Map.get(items, i, :undefined))

  @doc """
  `{:ok, values}`: the values of the array record `o` at the indices 0 to `n - 1`, when each
  of these indices holds a data value. Else `:error` (a hole or an accessor). The items at
  `n` and after it do not count.
  """
  def values_below(%{vec: vec}, n) when n <= tuple_size(vec),
    do: {:ok, :lists.sublist(:erlang.tuple_to_list(vec), n)}

  def values_below(%{vec: _}, _n), do: :error
  def values_below(%{items: items}, n), do: values_below(items, n - 1, [])

  defp values_below(_items, -1, acc), do: {:ok, acc}

  defp values_below(items, i, acc) do
    case items do
      %{^i => {:accessor, _, _}} -> :error
      %{^i => v} -> values_below(items, i - 1, [v | acc])
      _ -> :error
    end
  end

  @doc "`{index, item}` of each element (and item) of the array record `o`, in no order."
  def to_pairs(o), do: Map.to_list(to_map(o))

  @doc "Whether an element of the array record `o` is an accessor."
  def any_accessor?(%{vec: _}), do: false
  def any_accessor?(%{items: items}), do: any_accessor_in?(items)

  defp any_accessor_in?(items),
    do: Enum.any?(items, fn {_, v} -> match?({:accessor, _, _}, v) end)

  @doc """
  Whether the array record `o` has no hole and no accessor, and its length is `len`: then
  `to_list/1` gives its values.
  """
  def packed?(%{vec: vec}, len), do: tuple_size(vec) == len

  def packed?(%{items: items, len: len} = o, want),
    do: len == want and map_size(items) == len and not any_accessor?(o)

  # ── writes ───────────────────────────────────────────────────

  @doc """
  `o` with the data value `v` at the index `i`, with the default attributes. The length
  becomes `i + 1` when it was less, but not for an arguments object, whose `length` is an
  own property. A write after the end + 1 or past `max/0` makes the record sparse. It is a
  macro: the write to a sparse record is inline, as it was before step B2.
  """
  defmacro put(o, i, v) do
    quote generated: true, bind_quoted: [o: o, i: i, v: v] do
      case o do
        %{items: items, len: len} ->
          len = if is_map_key(o, :arguments), do: len, else: max(len, i + 1)
          %{o | items: :maps.put(i, v, items), len: len}

        _ ->
          Browser.JS.Elems.put_dense(o, i, v)
      end
    end
  end

  @doc false
  # `put/3` for a dense record.
  def put_dense(o, i, v) when dense_index?(o, i), do: dense_put(o, i, v)
  def put_dense(o, i, v) when dense_append?(o, i), do: dense_append(o, v)
  def put_dense(o, i, v), do: put(sparse(o), i, v)

  @doc """
  `o` with the item `item` (a value or an accessor) at the index `i`, as
  `Object.defineProperty` makes it: the length becomes `i + 1` when it was less, also for
  an arguments object. An accessor makes the record sparse.
  """
  def define(%{vec: _} = o, i, {:accessor, _, _} = item), do: define(sparse(o), i, item)
  def define(o, i, v) when dense_index?(o, i), do: dense_put(o, i, v)
  def define(o, i, v) when dense_append?(o, i), do: dense_append(o, v)
  def define(%{vec: _} = o, i, v), do: define(sparse(o), i, v)

  def define(%{items: items, len: len} = o, i, item),
    do: %{o | items: Map.put(items, i, item), len: max(len, i + 1)}

  @doc """
  `o` (an arguments object, which is sparse) with the value `v` at the index `i` of a
  mapped element. The length does not change.
  """
  def put_arg(%{items: items} = o, i, v), do: %{o | items: Map.put(items, i, v)}

  @doc """
  `o` with no element at the index `i`. The length does not change, so a dense record
  becomes sparse when it had an element there.
  """
  def delete(o, i) when dense_index?(o, i), do: delete(sparse(o), i)
  def delete(%{vec: _} = o, _i), do: o
  def delete(%{items: items} = o, i), do: %{o | items: Map.delete(items, i)}

  @doc """
  `o` with the length `stop` and no element at `stop` or after it. A dense record stays
  dense when `stop` is not more than its length (the tuple is cut), and becomes sparse
  when `stop` is more (the new indices are holes).
  """
  def set_len(%{vec: vec} = o, stop) when stop <= tuple_size(vec) do
    if stop == tuple_size(vec),
      do: o,
      else: %{o | vec: :erlang.list_to_tuple(:lists.sublist(:erlang.tuple_to_list(vec), stop))}
  end

  def set_len(%{vec: _} = o, stop), do: set_len(sparse(o), stop)

  def set_len(%{items: items} = o, stop),
    do: %{o | items: Map.filter(items, fn {i, _} -> i < stop end), len: stop}

  @doc """
  `o` with the elements `list` (data values) in place of all its elements. A dense record
  stays dense when the list has at most `max/0` elements, and a sparse record stays sparse.
  """
  def replace(%{vec: _} = o, list) do
    if length(list) <= @max,
      do: %{o | vec: :erlang.list_to_tuple(list)},
      else:
        o |> Map.delete(:vec) |> Map.put(:items, list_map(list)) |> Map.put(:len, length(list))
  end

  def replace(%{items: _} = o, list), do: %{o | items: list_map(list), len: length(list)}

  @doc """
  `o` with the items `items` (a map of each index to its item) and the length `len` in
  place of all its elements. A dense record stays dense when the items have no hole and
  no accessor and `len` is at most `max/0`, and a sparse record stays sparse.
  """
  def replace_map(%{vec: _} = o, items, len) do
    case map_vec(items, len) do
      nil -> o |> Map.delete(:vec) |> Map.put(:items, items) |> Map.put(:len, len)
      vec -> %{o | vec: vec}
    end
  end

  def replace_map(%{items: _} = o, items, len), do: %{o | items: items, len: len}

  @doc """
  `o` (an array for which `std_chain?/1` is true and that is not an arguments object) with
  the values `vs` after its last element, as `Array.prototype.push` adds them. It is a
  macro: the push of one value is inline.
  """
  defmacro push(o, vs) do
    quote generated: true, bind_quoted: [o: o, vs: vs] do
      case vs do
        [v] when Browser.JS.Elems.dense_append?(o, tuple_size(:erlang.map_get(:vec, o))) ->
          Browser.JS.Elems.dense_append(o, v)

        [v] when is_map_key(o, :items) ->
          len = :erlang.map_get(:len, o)
          %{o | items: :maps.put(len, v, :erlang.map_get(:items, o)), len: len + 1}

        _ ->
          Browser.JS.Elems.push_list(o, vs)
      end
    end
  end

  @doc false
  # `push/2` of a list of values that is not one value, or onto a full dense record.
  def push_list(%{vec: vec} = o, vs) do
    if tuple_size(vec) + length(vs) <= @max,
      do: %{o | vec: :erlang.list_to_tuple(:erlang.tuple_to_list(vec) ++ vs)},
      else: push_list(sparse(o), vs)
  end

  def push_list(%{items: items, len: len} = o, vs) do
    {items, len} = Enum.reduce(vs, {items, len}, fn v, {m, i} -> {Map.put(m, i, v), i + 1} end)
    %{o | items: items, len: len}
  end

  @doc """
  `{last, o}`: the last item of `o` (an array with a length of 1 or more, as
  `Array.prototype.pop` reads it, `:undefined` for a hole) and `o` without it, with a
  length one less. It is a macro, as `push/2` is: the pop of a sparse record is inline, as
  it was before step B2, and the pop of a dense record is one call.
  """
  defmacro pop(o) do
    quote generated: true, bind_quoted: [o: o] do
      case o do
        %{items: items, len: len} ->
          {Map.get(items, len - 1, :undefined),
           %{o | items: :maps.remove(len - 1, items), len: len - 1}}

        _ ->
          Browser.JS.Elems.pop_dense(o)
      end
    end
  end

  @doc false
  # `pop/1` for a dense record.
  def pop_dense(%{vec: vec} = o) do
    n = tuple_size(vec)
    {:erlang.element(n, vec), %{o | vec: :erlang.delete_element(n, vec)}}
  end
end
