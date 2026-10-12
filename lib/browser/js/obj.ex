defmodule Browser.JS.Obj do
  @moduledoc """
  The record API for the own properties of a JavaScript object (data-model steps A0a, A0b
  and A1).

  This module is the only module that reads or writes the fields of a heap record that hold
  own properties: `props`, `keys`, `skeys`, `syms`, `attrs`, `ext`, `frozen`, `sealed`,
  `shape` and `vals`. The other modules call the functions and macros here. Thus a change of
  the representation changes this module alone.

  ## The two modes of a record

  A record is in **fast mode** or in **dictionary mode**. Each function and macro here has
  one clause for each mode, and the two clauses give the same result for the same content.

  A record in fast mode has `shape` and `vals` (step A1). The shape (`Browser.JS.Shape`) is
  a shared, immutable term that holds the keys in creation order, the position of each key
  in the tuple `vals` and the attributes of each key, and the flag of an object that is not
  extensible. `vals` holds the value of each key, or `{:accessor, getter, setter}` for an
  accessor.

  A record in dictionary mode has the fields of before step A1:

  * `props`: a map of each own key to its value, or to `{:accessor, getter, setter}` for an
    accessor. A key is a string, a symbol `{:symbol, id, description}` or a private name
    `{:private, ref}`.
  * `keys`: the enumerable keys, newest first. It holds the enumerable symbols too, so the
    readers of the names filter it.
  * `skeys`: every string key, enumerable or not, newest first. Only a record that got a
    string key that is not enumerable has this field. A record without it has only
    enumerable string keys, so `keys` gives the order of all its string keys.
  * `syms`: every symbol key, newest first. Only a record that got a symbol key has this
    field.
  * `attrs`: a map of a key (or an array element index) to its non-default attributes, a
    map with some of `w`, `c` and `e`. A key that is not in it is writable and
    configurable. A record with no `attrs` field has only default attributes. A key is
    enumerable when it is in `keys`: an `e` in its entry has no effect. An element index has
    no place in `keys`, so its `e` is in `attrs`.
  * `ext: false`: the object is not extensible. `frozen: true` and `sealed: true`: an array
    whose elements are frozen or sealed.

  A private name has no place in the key order, in the two modes.

  ### Which records are fast

  `plain_record/1` and `plain_record/2` make a fast record when the switch `:js_shapes` is
  on (`Browser.JS.Shape.on?/0`). `Interp.new_object/0` and `Interp.new_object/2` use them, so
  plain objects, object literals, the objects of `new` (of a function or of a class),
  `JSON.parse` and error objects are fast. `Interp.new_proto_object/1` uses them too (step
  A2), so the prototype objects that the interpreter makes (`F.prototype`, the prototype of
  a class) are fast, and the inline caches of the compiled code can read their methods.
  `array_record/1` and `function_record/1` make the records of arrays and functions fast
  too (step A4), each from the root shape of its kind (`Browser.JS.Shape`). The elements
  and the `length` of an array are not in its shape, and the `name`, `length` and
  `prototype` of a function stay virtual until a write makes them own keys.
  The built-in objects are made with these functions too: the built-in prototypes, the
  constructors and the other functions, `Math`, `JSON` and `Reflect` are fast
  (`Browser.JS.Builtins.built/1`). `record/1` and `record/2` always make a dictionary record:
  host objects (also the global object and the namespaces of modules), proxies, arguments
  objects and the collections. A function that becomes a proxy goes to dictionary mode
  first (`Browser.JS.Proxy`).

  ### From fast mode to dictionary mode

  A fast record goes to dictionary mode once, and never back (`to_dict/1`). This occurs
  when a change passes a limit of `Browser.JS.Shape` (too many keys, an index-like key, too
  many changes of attributes), at a `delete` of a key that is not the last key, and in the
  functions that only arrays and the global object need (`put_element_attrs/3`,
  `own_remove/2`). The writer then does its change on the dictionary record, and the
  caller stores that record. A reader never changes the mode.

  The elements of an array (`items`, `len`) are not in this API (part B of the shapes
  plan). Their attributes share the `attrs` map, so `attr_flags/2`,
  `element_enumerable?/2` and `put_element_attrs/3` are here. An array with an element
  that does not have the default attributes is a dictionary record
  (`put_element_attrs/3`), because a fast record has no `attrs`. The flags `frozen` and
  `sealed` of an array stay in the record in the two modes.

  ## The order of the keys

  The order is the order of OrdinaryOwnPropertyKeys: the string keys in creation order,
  then the symbols in creation order. The callers put the array indexes first, in
  ascending order. A key keeps its place when its value or its attributes change, also
  when it becomes enumerable again. A key that is deleted loses its place, and a key that
  is made again goes to the end.

  The callers get the order from `enum_names/1` (the enumerable string keys),
  `plain_names/1` (the same list for a plain object, or `nil`), `string_keys/1` (all
  string keys) and `symbol_keys/1` (all symbols). These give the order, not the stored
  lists, so that a change of the stored lists changes this module alone.

  In dictionary mode the lists are separate for the cost. An assignment, a literal,
  `Object.keys` and for-in read and write `keys` alone. Only a record that has a string key
  that is not enumerable pays for `skeys`, and only a record with a symbol pays for `syms`.
  In fast mode the shape holds the order of all keys, and the `enum` list of the shape is
  the list of `Object.keys` (before the index keys, which a fast record does not have).

  ## Cost

  Many callers are hot paths of the interpreter and of the compiled code (a named read, an
  update, an add, a literal, `hasOwnProperty`, `Object.keys`, for-in, the elements of an
  array). A remote call costs one reduction, and a remote BIF call such as `Map.has_key?/2`
  or `Map.get/3` costs four. A macro here expands to code that costs the same as the code
  that it replaces, or less: it uses guard BIFs (`is_map_key/2`, `:erlang.map_get/2`,
  `:erlang.element/2`), pattern matches and map updates, which cost no reduction. A
  function here is used only on a path that is not hot, or where the BIF calls that it
  removes pay for the call. The add of an assignment to a fast record reads the transition
  table in the macro, so an add that finds its shape there makes no call.

  ## The grep gate

  No module other than this one names the fields. This command finds the direct uses
  outside this module: a field after a dot, a field as a key of a map or a keyword list,
  and a field atom in any other place (a call of `Map`, `:maps` or `Access`, a list of
  fields). Comment lines do not count, and the last stage removes the lines of the
  allow-list below. So the command prints nothing. `test/browser/js_obj_test.exs` runs
  the same search with the same patterns, and it fails when they are not the same as here.

      grep -rnP '(?<!Map|Object|Keyword|Reflect|prototype)\\.(props|keys|skeys|syms|attrs|ext|frozen|sealed|shape|vals)\\b(?![?!(])|\\b(props|keys|skeys|syms|attrs|ext|frozen|sealed|shape|vals):|(?<![{\\w:]):(props|keys|skeys|syms|attrs|ext|frozen|sealed|shape|vals)\\b' lib/browser/js --include=*.ex | grep -vP '^[^:]+:\\d+:\\s*#' | grep -v '^lib/browser/js/obj.ex:' | grep -vP '^lib/browser/js/dom\\.ex:\\d+:.*((\\bn|&1)\\.(attrs|props)\\b|node\\(this_nid\\(this\\)\\)\\.attrs\\b|\\b(attrs|props): (\\[\\]|%\\{\\}|%\\{"value"|visible\\b|attrs\\b|props\\b)|%\\{fields: [^}]*keys: )|^lib/browser/js/(collections|typed_arrays)\\.ex:\\d+:(\\s*:keys ->|.*_iterator\\(this, (:\\w+, )?:keys\\))|^lib/browser/js/collections\\.ex:\\d+:.*(has: has, keys: keys\\}|call\\(rec\\.keys, rec\\.obj, \\[\\]\\))'

  The allow-list (the reason for each):

  * `lib/browser/js/dom.ex`, only the lines with a node form (`n.attrs`, `n.props`,
    `&1.props`, `node(this_nid(this)).attrs`, `attrs: []`, `props: %{}`, `attrs: visible`,
    `props: props` and the like) or the realm form (`%{fields: ..., keys: ...}`): a DOM
    node has its own `attrs` (the HTML attributes) and `props` (the live `value`,
    `checked` and `open`), and a realm has `keys`. These are not heap records. A use of a
    heap record in `dom.ex` has none of these forms, so the gate finds it.
  * `lib/browser/js/collections.ex` and `lib/browser/js/typed_arrays.ex`, the lines with the
    iterator kind `:keys` (`:keys ->`, `..._iterator(this, :keys)`): it is the kind of a
    `keys()` iterator, not a field.
  * `lib/browser/js/collections.ex`, `set_record/1` and `each_key/2`: the record of
    GetSetRecord (`%{obj, size, has, keys}`) holds the `keys` method of a set-like object.
    It is not a heap record.

  The garbage collector (`Browser.JS.GC`) names no field. It walks every map generically,
  but for a heap record (`heap_record?/1`) it skips the fields that `no_refs?/1` names,
  because the walk reads each integer as a heap id and these fields hold only keys,
  attributes and shapes (the id of a symbol, the `sid` of a shape and a position are
  integers). It walks `vals`, which holds the values. The shadow run of `Browser.JS.Fast`
  compares two records by `normal/1`, which gives one form for the two modes. The other
  modules under `lib/browser` (layout, style, HTML, cookies, the console of the session)
  have their own `attrs` and `props`, but they never read a heap record, so the gate does
  not search them.

  ## The length of an arguments object

  The `length` of an arguments object is an ordinary own property, as in the spec. The
  interpreter makes it with `put_hidden/3` when it makes the object, and `delete
  arguments.length` removes it with `own_delete/2`, as for any other key. So each key in the
  order has a value, which a fast record needs.
  """

  alias Browser.JS.Shape
  require Browser.JS.Shape

  # The bits of a key with the default attributes, and of a key that is writable and
  # configurable but not enumerable (a hidden key and a private name).
  @default 7
  @hidden 5

  # The shape with no key. The macros below expand to code that tests the bits of a shape
  # with `:erlang.band/2`, and not with the macros of `Browser.JS.Shape`, so that a caller
  # does not have to require that module: writable `1`, enumerable `2`, configurable `4`;
  # the flag `1` of an object that is not extensible and the flag `2` of an enumerable
  # symbol.
  @root Shape.root_shape()
  @array_root Shape.array_root_shape()
  @function_root Shape.function_root_shape()

  # The test of the switch `:js_shapes` (`Browser.JS.Shape.on?/0`), expanded here, so that
  # the macros that make a record put it in the code of the caller, which does not require
  # `Browser.JS.Shape`.
  @on Macro.expand_once(quote(do: Shape.on?()), __ENV__)

  # The new tuple `vals` with the value `v` at the position `pos`, as an expression that
  # the write macros put in their code. `:erlang.setelement/3` is a call of a built-in
  # function, and each call costs one reduction. For a tuple of at most 8 values, the
  # expression first finds the size and the position, and then it calls `setelement` with
  # a literal position on a tuple of a known size. The compiler makes that an
  # `update_record` instruction, which costs no reduction. Thus an update of a fast record
  # costs no more reductions than the update of a map in a dictionary record.
  @put_val (
             sizes =
               for n <- 1..8 do
                 pattern = {:{}, [], List.duplicate({:_, [], nil}, n)}

                 positions =
                   for i <- 1..n do
                     hd(quote do: (unquote(i) -> :erlang.setelement(unquote(i), vals, v)))
                   end

                 hd(quote do: (unquote(pattern) -> case(pos, do: unquote(positions))))
               end

             other = quote do: (_ -> :erlang.setelement(pos, vals, v))
             {:case, [], [quote(do: vals), [do: sizes ++ other]]}
           )

  # ── building ───────────────────────────────────────────────

  @doc """
  A new dictionary record with no own property: the map `fields` (a keyword list in the
  source, for example `class: :object, proto: p`) plus the empty own-property fields. It is
  a macro, so the record is one map literal at the call site.
  """
  defmacro record(fields) do
    quote do
      %{unquote_splicing(fields), props: %{}, keys: []}
    end
  end

  @doc """
  A new dictionary record with the enumerable data properties `pairs` (a list of
  `{key, value}`, in creation order) and the fields of `record/1`. The keys must be
  distinct: each key of `pairs` goes into the key order as it is. A key can be a symbol (the
  rest of an object pattern copies the enumerable symbols too).
  """
  defmacro record(fields, pairs) do
    quote do
      pairs = unquote(pairs)

      case Browser.JS.Obj.pair_names(pairs, []) do
        keys when is_list(keys) ->
          %{unquote_splicing(fields), props: Map.new(pairs), keys: keys}

        :symbols ->
          Enum.reduce(
            pairs,
            %{unquote_splicing(fields), props: %{}, keys: []},
            fn {k, v}, o -> Browser.JS.Obj.define_data(o, k, v) end
          )
      end
    end
  end

  @doc """
  A new record of a plain object with no own property, as `record/1`. It is a fast record
  when the switch `:js_shapes` is on (see the moduledoc), and a dictionary record when it
  is off.
  """
  defmacro plain_record(fields) do
    quote do
      if unquote(@on),
        do: %{unquote_splicing(fields), shape: unquote(Macro.escape(@root)), vals: {}},
        else: %{unquote_splicing(fields), props: %{}, keys: []}
    end
  end

  @doc """
  A new record of a plain object with the enumerable data properties `pairs`, as
  `record/2`. It is a fast record when the switch `:js_shapes` is on.
  """
  defmacro plain_record(fields, pairs) do
    quote do
      if unquote(@on),
        do:
          Browser.JS.Obj.add_pairs(
            %{unquote_splicing(fields), shape: unquote(Macro.escape(@root)), vals: {}},
            unquote(pairs),
            unquote(Macro.escape(@root)),
            []
          ),
        else: Browser.JS.Obj.record(unquote(fields), unquote(pairs))
    end
  end

  @doc """
  A new record of an array with no own named property: the map `fields`, as `record/1`. It
  is a fast record with the root of the arrays (`Browser.JS.Shape`) when the switch
  `:js_shapes` is on. Its elements and its `length` (`items` and `len` in `fields`) are
  not in the shape.
  """
  defmacro array_record(fields) do
    quote do
      if unquote(@on),
        do: %{unquote_splicing(fields), shape: unquote(Macro.escape(@array_root)), vals: {}},
        else: %{unquote_splicing(fields), props: %{}, keys: []}
    end
  end

  @doc """
  A new record of a function with no own property: the map `fields`, as `record/1`. It is
  a fast record with the root of the functions (`Browser.JS.Shape`) when the switch
  `:js_shapes` is on. The `name`, the `length` and the `prototype` of a function stay
  virtual: they are not in the shape until a write makes them own keys.
  """
  defmacro function_record(fields) do
    quote do
      if unquote(@on),
        do: %{unquote_splicing(fields), shape: unquote(Macro.escape(@function_root)), vals: {}},
        else: %{unquote_splicing(fields), props: %{}, keys: []}
    end
  end

  @doc false
  # The string keys of `pairs` (see `record/2`), newest first, or `:symbols` when a key is a
  # symbol. One walk makes the list newest first, which costs less than a map and a
  # reverse.
  def pair_names([{k, _} | rest], acc) when is_binary(k), do: pair_names(rest, [k | acc])
  def pair_names([], acc), do: acc
  def pair_names(_, _acc), do: :symbols

  @doc """
  The key layout of an object literal with the constant keys `keys` (in source order), for
  `fill/3`. The compiler calls it once, when it compiles the literal. It holds the list of
  the distinct keys, newest first (a key that comes two times keeps its first place), the
  keys in source order, the shape of the distinct keys (`nil` when a limit of
  `Browser.JS.Shape` stops it), and for a key that comes two times, the position of the
  last value of each distinct key. It holds no heap id.
  """
  def literal_keys(keys) do
    uniq = Enum.uniq(keys)

    picks =
      if uniq != keys do
        last = keys |> Enum.with_index(1) |> Map.new()
        for k <- uniq, do: Map.fetch!(last, k)
      end

    {Enum.reverse(uniq), keys, Shape.from_keys(uniq), picks}
  end

  @doc """
  The record `o` (a new empty object) with all the properties of an object literal in one
  write: `layout` is from `literal_keys/1`, and `values` gives the value of each key in
  source order. A key that comes two times gets its last value, as with `define_data/3`.
  A fast record with no key that comes two times takes the shape of the layout and the
  values as they are, with no call.
  """
  defmacro fill(o, layout, values) do
    quote bind_quoted: [o: o, layout: layout, values: values] do
      case layout do
        {_, _, {:js_shape, _, _, _, _, _, _} = sh, nil} when is_map_key(o, :shape) ->
          %{o | shape: sh, vals: :erlang.list_to_tuple(values)}

        _ ->
          Browser.JS.Obj.fill_other(o, layout, values)
      end
    end
  end

  @doc """
  A new record of an object literal in one map literal (step A3): the map `fields` (a
  keyword list in the source) plus the shape `sh` of the literal and the tuple `vals` of
  its values in the order of the keys of the shape. The shape comes from `literal_keys/1`
  when the literal compiles, and the literal has no key that comes two times. When the
  switch `:js_shapes` is off, the record is the same record in dictionary mode
  (`to_dict/1`), as `plain_record/2` would make it.
  """
  defmacro shaped_record(fields, sh, vals) do
    quote do
      o = %{unquote_splicing(fields), shape: unquote(sh), vals: unquote(vals)}
      if unquote(@on), do: o, else: Browser.JS.Obj.to_dict(o)
    end
  end

  @doc false
  # `fill/3` for a dictionary record, for a layout with no shape, and for a key that comes
  # two times.
  def fill_other(o, {names, keys, sh, picks}, values) do
    if is_map_key(o, :shape) and sh != nil do
      t = List.to_tuple(values)
      %{o | shape: sh, vals: List.to_tuple(for i <- picks, do: :erlang.element(i, t))}
    else
      o = if is_map_key(o, :shape), do: to_dict(o), else: o
      %{o | props: :maps.from_list(:lists.zip(keys, values)), keys: names}
    end
  end

  # ── reading ────────────────────────────────────────────────

  @doc "Whether the record `o` has the own key `key`. It is a guard."
  defguard has_own?(o, key)
           when (is_map_key(o, :shape) and
                   is_map_key(:erlang.element(3, :erlang.map_get(:shape, o)), key)) or
                  (is_map_key(o, :props) and is_map_key(:erlang.map_get(:props, o), key))

  @doc "Whether `o` is a record of an object (it has own-property fields). It is a guard."
  defguard object?(o) when is_map(o) and (is_map_key(o, :props) or is_map_key(o, :shape))

  @doc """
  Whether `o` is the record of a heap object: a map with own-property fields and a class.
  It is a guard. A DOM node also has a `props` field, but it has no class.
  """
  defguard heap_record?(o) when object?(o) and is_map_key(o, :class)

  @doc """
  Whether the field `field` of a heap record holds no heap id, so that the garbage collector
  does not walk it. It is a guard. These own-property fields hold keys that `props` or the
  shape also holds (or keys that are gone), attributes, and the shape. The collector reads
  each integer as an id, so the integer id of a symbol, the `sid` of a shape or a position
  could keep a dead object alive.
  """
  defguard no_refs?(field) when field in [:keys, :skeys, :syms, :attrs, :shape]

  @doc "Whether `o` is a record in fast mode."
  defguard fast?(o) when is_map_key(o, :shape)

  @doc """
  The stored value of the own key `key` of `o`: `{:ok, value}` or `:error`. An accessor
  gives `{:ok, {:accessor, getter, setter}}`.
  """
  defmacro own_fetch(o, key) do
    quote do
      case unquote(o) do
        %{shape: {:js_shape, _, %{unquote(key) => pos}, _, _, _, _}, vals: vals} ->
          {:ok, :erlang.element(pos, vals)}

        %{props: %{unquote(key) => v}} ->
          {:ok, v}

        _ ->
          :error
      end
    end
    |> pin_key(key)
  end

  @doc "The stored value of the own key `key` of `o`, or `nil` when there is none."
  defmacro own_value(o, key) do
    quote do
      case unquote(o) do
        %{shape: {:js_shape, _, %{unquote(key) => pos}, _, _, _, _}, vals: vals} ->
          :erlang.element(pos, vals)

        %{props: %{unquote(key) => v}} ->
          v

        _ ->
          nil
      end
    end
    |> pin_key(key)
  end

  @doc """
  A `case` on the own property `key` of the record `o`. A clause `{:ok, pattern}` matches
  the stored value of an own key (an accessor is `{:accessor, getter, setter}`), `:error`
  matches when there is no own key, and `_` matches always. Clauses can have guards. It is
  a macro, so a read costs no call:

      Obj.own_case o, key do
        {:ok, {:accessor, g, _}} -> call(g)
        {:ok, v} -> v
        :error -> lookup_proto(o)
      end

  An `:error` clause must come after a clause `{:ok, v}` (or `{:ok, _}`) with no guard.
  The expansion of `:error` is `_`, which also matches a record with the key, so only that
  order makes it match a missing key alone.

  The expansion has first one clause for a fast record with the key, then the clauses of a
  dictionary record as they are. The first clause reads the value from `vals` and has an
  inner `case` with all the clauses in their order, up to the first clause that matches
  every value: `{:ok, pattern}` matches the value with `pattern`, and `:error` and `_`
  match any value. So the bodies of these clauses are in the expansion two times. A fast
  record without the key gets to the clauses of a dictionary record, where only `:error`
  and `_` can match it.
  """
  defmacro own_case(o, key, do: clauses) do
    {kpat, pre} = key_pattern(key)

    Enum.reduce(clauses, false, fn {:->, _, [[head], _]}, all_ok? ->
      check_order(head, all_ok?)
    end)

    pos = Macro.unique_var(:pos, __MODULE__)
    vals = Macro.unique_var(:vals, __MODULE__)

    # (the clause is generated: a caller that knows that its record is not fast, as the
    # inline caches of `Browser.JS.Interp` do, gets no warning that it cannot match)
    fast =
      quote generated: true do
        %{
          shape: {:js_shape, _, %{unquote(kpat) => unquote(pos)}, _, _, _, _},
          vals: unquote(vals)
        } ->
          case :erlang.element(unquote(pos), unquote(vals)) do
            unquote(value_clauses(clauses))
          end
      end

    dict =
      Enum.map(clauses, fn {:->, meta, [[head], body]} ->
        {:->, meta, [[own_head(head, kpat)], body]}
      end)

    quote do
      unquote_splicing(pre)

      case unquote(o) do
        unquote(fast ++ dict)
      end
    end
  end

  # The clauses of `own_case/3` for the value of an own key of a fast record: a clause
  # `{:ok, pattern}` matches the value with `pattern`, and `:error` and `_` match any value
  # (as their expansion `_` does for a dictionary record). The clauses after the first one
  # that matches every value go, because they cannot match.
  defp value_clauses([{:->, meta, [[head], body]} | rest]) do
    clause = {:->, meta, [[value_head(head)], body]}
    if catch_all?(head), do: [clause], else: [clause | value_clauses(rest)]
  end

  defp value_clauses([]), do: []

  defp value_head({:when, meta, [head, guard]}), do: {:when, meta, [value_head(head), guard]}
  defp value_head({:ok, pattern}), do: pattern
  defp value_head(_), do: quote(do: _)

  defp catch_all?({:ok, {name, _, ctx}}) when is_atom(name) and is_atom(ctx), do: true
  defp catch_all?(:error), do: true
  defp catch_all?({:_, _, ctx}) when is_atom(ctx), do: true
  defp catch_all?(_), do: false

  # Whether the clauses up to `head` match every own key (`all_ok?`). An `:error` clause
  # before that point raises (see `own_case/3`).
  defp check_order({:ok, {name, _, ctx}}, _all_ok?) when is_atom(name) and is_atom(ctx),
    do: true

  defp check_order(:error, false), do: own_order_error()
  defp check_order({:when, _, [:error, _]}, false), do: own_order_error()
  defp check_order(_head, all_ok?), do: all_ok?

  defp own_order_error,
    do:
      raise(
        ArgumentError,
        "own_case: an :error clause must come after a clause {:ok, v} with no guard"
      )

  defp own_head({:when, meta, [pattern, guard]}, kpat),
    do: {:when, meta, [own_head(pattern, kpat), guard]}

  defp own_head({:ok, pattern}, kpat),
    do: quote(do: %{props: %{unquote(kpat) => unquote(pattern)}})

  defp own_head(:error, _kpat), do: quote(do: _)
  defp own_head({:_, _, ctx} = any, _kpat) when is_atom(ctx), do: any

  defp own_head(other, _kpat),
    do:
      raise(
        ArgumentError,
        "own_case: a clause must be {:ok, pattern}, :error or _, not #{Macro.to_string(other)}"
      )

  # The pattern of a key in a map pattern: a literal stays as it is, a variable is pinned,
  # and another expression is bound to a variable first (in `pre`).
  defp key_pattern(key) when is_binary(key) or is_atom(key) or is_number(key), do: {key, []}

  defp key_pattern({name, _, ctx} = var) when is_atom(name) and is_atom(ctx),
    do: {{:^, [], [var]}, []}

  defp key_pattern(expr) do
    var = Macro.unique_var(:key, __MODULE__)
    {{:^, [], [var]}, [quote(do: unquote(var) = unquote(expr))]}
  end

  # The quoted `case` of a macro with the key in a map pattern, with the key made a
  # pattern by `key_pattern/1`.
  defp pin_key(ast, key) do
    {kpat, pre} = key_pattern(key)

    ast =
      Macro.prewalk(ast, fn
        {:%{}, m, [{k, v}]} when k === key -> {:%{}, m, [{kpat, v}]}
        node -> node
      end)

    quote do
      unquote_splicing(pre)
      unquote(ast)
    end
  end

  @doc """
  The enumerable string keys of `o` in creation order. A caller puts the index keys first
  when the order of the spec needs it.
  """
  defmacro enum_names(o) do
    quote do
      case unquote(o) do
        %{shape: {:js_shape, _, _, _, _, _, enum}} -> enum
        o -> :erlang.map_get(:keys, o) |> :lists.reverse() |> Enum.filter(&is_binary/1)
      end
    end
  end

  @doc """
  The enumerable keys of `o` in creation order when each one is a plain name, or `nil`. A
  plain name is a string that does not start with a digit, so it cannot be an array index,
  and the list is then the order of `Object.keys` as it is (fast path `:has_own` of
  `Browser.JS.Interp`). A symbol is no plain name. A fast record has no key that starts
  with a digit (`Browser.JS.Shape`), so its `enum` list is the answer when no enumerable key
  is a symbol.
  """
  defmacro plain_names(o) do
    quote do
      case unquote(o) do
        %{shape: {:js_shape, _, _, _, _, flags, enum}} ->
          if :erlang.band(flags, 2) == 0, do: enum

        o ->
          keys = :erlang.map_get(:keys, o)
          if Browser.JS.Obj.plain_names?(keys), do: :lists.reverse(keys)
      end
    end
  end

  @doc false
  # (the test of `plain_names/1`: a function, as the local function of the interpreter
  # was, so that the walk costs the same)
  def plain_names?([<<c, _::binary>> | rest]) when c < ?0 or c > ?9, do: plain_names?(rest)
  def plain_names?(["" | rest]), do: plain_names?(rest)
  def plain_names?([]), do: true
  def plain_names?(_), do: false

  @doc "Whether the element at index `i` of the array `o` is enumerable."
  defmacro element_enumerable?(o, i) do
    quote do
      case unquote(o) do
        %{attrs: %{unquote(i) => %{e: e}}} -> e
        _ -> true
      end
    end
    |> pin_key(i)
  end

  @doc false
  # The attribute map of a dictionary record `o`: each key or element index with
  # non-default attributes, to a map with some of `w`, `c` and `e`. A fast record has none.
  # Only the macros of this module use it: their expansion calls it at the call site, so it
  # must be public.
  defmacro attr_map(o) do
    quote do
      case unquote(o) do
        %{attrs: attrs} -> attrs
        _ -> %{}
      end
    end
  end

  @doc """
  The non-default attributes of `key` (or of an element index) of `o`: a map with some of
  `w`, `c` and `e`. For a key of a fast record it has all three.
  """
  defmacro attr_flags(o, key) do
    quote do
      case unquote(o) do
        %{shape: {:js_shape, _, %{unquote(key) => pos}, _, bits, _, _}} ->
          b = :erlang.element(pos, bits)
          %{w: :erlang.band(b, 1) != 0, c: :erlang.band(b, 4) != 0, e: :erlang.band(b, 2) != 0}

        %{attrs: %{unquote(key) => flags}} ->
          flags

        _ ->
          %{}
      end
    end
    |> pin_key(key)
  end

  @doc "Whether the own key (or element) `key` of `o` is writable, when it exists."
  defmacro writable?(o, key) do
    quote do
      case unquote(o) do
        %{shape: {:js_shape, _, %{unquote(key) => pos}, _, bits, _, _}} ->
          :erlang.band(:erlang.element(pos, bits), 1) != 0

        %{attrs: %{unquote(key) => a}} ->
          match?(%{w: true}, a)

        _ ->
          true
      end
    end
    |> pin_key(key)
  end

  @doc "Whether the own key (or element) `key` of `o` is configurable, when it exists."
  defmacro configurable?(o, key) do
    quote do
      case unquote(o) do
        %{shape: {:js_shape, _, %{unquote(key) => pos}, _, bits, _, _}} ->
          :erlang.band(:erlang.element(pos, bits), 4) != 0

        %{attrs: %{unquote(key) => a}} ->
          match?(%{c: true}, a)

        _ ->
          true
      end
    end
    |> pin_key(key)
  end

  @doc """
  Whether `key` has only the default attributes in `o` (writable and configurable), or `o`
  has no such key. It is a guard, for the fast update of `Browser.JS.Interp`.
  """
  defguard default_attrs?(o, key)
           when (is_map_key(o, :shape) and
                   (not is_map_key(:erlang.element(3, :erlang.map_get(:shape, o)), key) or
                      :erlang.band(
                        :erlang.element(
                          :erlang.map_get(key, :erlang.element(3, :erlang.map_get(:shape, o))),
                          :erlang.element(5, :erlang.map_get(:shape, o))
                        ),
                        5
                      ) == 5)) or
                  (not is_map_key(o, :shape) and
                     not (is_map_key(o, :attrs) and is_map_key(:erlang.map_get(:attrs, o), key)))

  @doc "Whether `o` is extensible."
  defmacro extensible?(o) do
    quote do
      case unquote(o) do
        %{shape: {:js_shape, _, _, _, _, flags, _}} -> :erlang.band(flags, 1) == 0
        %{ext: ext} -> ext
        _ -> true
      end
    end
  end

  @doc "Whether `o` is an array that `Object.freeze` froze (its elements cannot change)."
  defmacro frozen?(o) do
    quote do
      case unquote(o) do
        %{frozen: frozen} -> frozen
        _ -> false
      end
    end
  end

  @doc "Whether `o` is an array that `Object.seal` sealed (its elements cannot go)."
  defmacro sealed?(o) do
    quote do
      case unquote(o) do
        %{sealed: sealed} -> sealed
        _ -> false
      end
    end
  end

  @doc """
  The own property `key` of the record `o` as a state, or `nil`:
  `{:data, value, writable, enumerable, configurable}` or
  `{:accessor, getter, setter, enumerable, configurable}`.
  """
  defmacro own_state(o, key) do
    quote bind_quoted: [o: o, key: key] do
      case o do
        %{shape: {:js_shape, _, %{^key => pos}, _, bits, _, _}, vals: vals} ->
          b = :erlang.element(pos, bits)

          case :erlang.element(pos, vals) do
            {:accessor, g, s} ->
              {:accessor, g, s, :erlang.band(b, 2) != 0, :erlang.band(b, 4) != 0}

            v ->
              {:data, v, :erlang.band(b, 1) != 0, :erlang.band(b, 2) != 0,
               :erlang.band(b, 4) != 0}
          end

        %{props: %{^key => stored}} ->
          attrs =
            case o do
              %{attrs: %{^key => flags}} -> flags
              _ -> %{}
            end

          e = key in o.keys
          c = Map.get(attrs, :c, true)

          case stored do
            {:accessor, g, s} -> {:accessor, g, s, e, c}
            v -> {:data, v, Map.get(attrs, :w, true), e, c}
          end

        _ ->
          nil
      end
    end
  end

  @doc "Every own key of `o` (strings, symbols and private names), in term order."
  defmacro all_keys(o) do
    quote do
      case unquote(o) do
        %{shape: {:js_shape, _, index, _, _, _, _}} -> Map.keys(index)
        o -> Map.keys(:erlang.map_get(:props, o))
      end
    end
  end

  # private names are outside freezing and sealing
  defp public_keys(o), do: Enum.reject(all_keys(o), &match?({:private, _}, &1))

  @doc """
  Every own string key of `o`, enumerable or not, in creation order (the string keys of
  OrdinaryOwnPropertyKeys). The caller puts the index keys first. It also adds the keys
  that the record does not hold (the `length` of an array, the `name` of a function).
  """
  def string_keys(o) do
    case o do
      %{shape: {:js_shape, _, _, keys, _, _, _}} ->
        for k <- Tuple.to_list(keys), is_binary(k), do: k

      %{skeys: skeys} ->
        :lists.reverse(skeys)

      %{keys: keys} ->
        keys |> :lists.reverse() |> Enum.filter(&is_binary/1)
    end
  end

  @doc "Every own symbol key of `o`, enumerable or not, in creation order."
  def symbol_keys(o) do
    case o do
      # (the flag 8 of the shape tells if a key is a symbol, so most records do not look at
      # their keys)
      %{shape: {:js_shape, _, _, keys, _, flags, _}} ->
        if :erlang.band(flags, 8) == 0,
          do: [],
          else: for({:symbol, _, _} = k <- Tuple.to_list(keys), do: k)

      %{syms: syms} ->
        :lists.reverse(syms)

      _ ->
        []
    end
  end

  @doc """
  The highest index at or above `len` of an element of the array `o` that is not
  configurable, or `nil`. A shrink of `length` stops above it.
  """
  defmacro max_fixed_element(o, len) do
    quote bind_quoted: [o: o, len: len] do
      attrs = Browser.JS.Obj.attr_map(o)

      o.items
      |> Map.keys()
      |> Enum.filter(&(&1 >= len and Map.get(Map.get(attrs, &1, %{}), :c, true) == false))
      |> Enum.max(fn -> nil end)
    end
  end

  @doc "Whether `o` is frozen (`freeze?` true) or sealed, for `Object.isFrozen` and `isSealed`."
  def locked?(o, freeze?) do
    not extensible?(o) and
      Enum.all?(public_keys(o), fn key ->
        case own_state(o, key) do
          {:accessor, _, _, _, c} -> c == false
          {:data, _, w, _, c} -> c == false and (not freeze? or w == false)
        end
      end) and
      (o.class != :array or o.items == %{} or
         frozen?(o) or (not freeze? and sealed?(o)))
  end

  @doc """
  The record `o` in its normal form, for a compare of two records. Two records that hold the
  same own properties, in the same order and with the same attributes, have the same normal
  form, in fast mode and in dictionary mode. The normal form has the fields of the record
  that are not own-property fields, and `own` (each string key, then each symbol, with its
  state from `own_state/2`), `private` (each private name with its value, in term order),
  `ext` (whether the object is extensible) and `elements` (the attributes of the elements
  of an array that are not the default). So the shadow run of `Browser.JS.Fast` compares
  what two records hold, not their form. A term that is not a record (`nil` when the shadow
  run has no record) is its own normal form.
  """
  def normal(o) when object?(o) do
    own = for k <- string_keys(o) ++ symbol_keys(o), do: {k, own_state(o, k)}

    private =
      for {:private, _} = k <- Enum.sort(all_keys(o)), do: {k, own_value(o, k)}

    elements =
      for {i, a} when is_integer(i) <- attr_map(o),
          {Map.get(a, :w, true), Map.get(a, :c, true), Map.get(a, :e, true)} !=
            {true, true, true},
          into: %{},
          do: {i, {Map.get(a, :w, true), Map.get(a, :c, true), Map.get(a, :e, true)}}

    o
    |> Map.drop([:props, :keys, :skeys, :syms, :attrs, :ext, :shape, :vals])
    |> Map.merge(%{own: own, private: private, ext: extensible?(o), elements: elements})
  end

  def normal(other), do: other

  @doc """
  The fast record `o` in dictionary mode: the record that the writers of this module make
  for a dictionary record with the same changes. A dictionary record is given as it is.
  """
  def to_dict(%{shape: {:js_shape, _, _, keys, bits, flags, enum}, vals: vals} = o) do
    n = tuple_size(keys)
    o = :maps.remove(:vals, :maps.remove(:shape, o))

    # (the usual record: string keys with the default attributes, no symbol, extensible.
    # Then `enum` holds all the keys in order, and the record needs only `props` and `keys`)
    cond do
      :erlang.band(flags, 9) != 0 ->
        dict_other(o, keys, bits, flags, vals, n)

      n == 0 ->
        :maps.put(:keys, [], :maps.put(:props, %{}, o))

      bits == :erlang.make_tuple(n, @default) ->
        props =
          :maps.from_list(:lists.zip(:erlang.tuple_to_list(keys), :erlang.tuple_to_list(vals)))

        :maps.put(:keys, :lists.reverse(enum), :maps.put(:props, props, o))

      true ->
        dict_other(o, keys, bits, flags, vals, n)
    end
  end

  def to_dict(o), do: o

  # `to_dict/1` for a record with a symbol, a key with other attributes, or the flag of an
  # object that is not extensible.
  defp dict_other(o, keys, bits, flags, vals, n) do
    {props, en, strings, hidden?, syms, attrs} =
      dict_fields(keys, bits, vals, 1, n, {%{}, [], [], false, [], %{}})

    o = Map.merge(o, %{props: props, keys: en})
    o = if hidden?, do: Map.put(o, :skeys, strings), else: o
    o = if syms == [], do: o, else: Map.put(o, :syms, syms)
    o = if attrs == %{}, do: o, else: Map.put(o, :attrs, attrs)
    if Shape.extensible?(flags), do: o, else: Map.put(o, :ext, false)
  end

  # The fields of a dictionary record from the keys `i` to `n` of a fast record: `props`,
  # the enumerable keys and all the string keys (newest first), whether a string key is not
  # enumerable (then the record needs `skeys`), the symbols (newest first) and the
  # attributes that are not the default.
  defp dict_fields(_keys, _bits, _vals, i, n, acc) when i > n, do: acc

  defp dict_fields(keys, bits, vals, i, n, {p, en, st, hidden?, sy, at}) do
    k = :erlang.element(i, keys)
    b = :erlang.element(i, bits)
    p = Map.put(p, k, :erlang.element(i, vals))
    e = Shape.e?(b)

    acc =
      case k do
        {:private, _} -> {p, en, st, hidden?, sy, at}
        {:symbol, _, _} when e -> {p, [k | en], st, hidden?, [k | sy], at}
        {:symbol, _, _} -> {p, en, st, hidden?, [k | sy], at}
        _ when e -> {p, [k | en], [k | st], hidden?, sy, at}
        _ -> {p, en, [k | st], true, sy, at}
      end

    acc =
      if Shape.w?(b) and Shape.c?(b),
        do: acc,
        else: :erlang.setelement(6, acc, Map.put(at, k, %{w: Shape.w?(b), c: Shape.c?(b)}))

    dict_fields(keys, bits, vals, i + 1, n, acc)
  end

  @doc """
  The record `o` with the class `class`. A fast record with no own key gets the root shape
  of the new class (`Browser.JS.Shape`), because a shape belongs to one kind of record. Any
  other fast record goes to dictionary mode. `Browser.JS.Builtins` uses it for
  `Array.prototype`, which it makes as a plain object first.
  """
  def with_class(o, class) do
    case o do
      %{shape: {:js_shape, _, _, {}, _, flags, _}} ->
        sh = Shape.root_of(class)
        sh = if Shape.extensible?(flags), do: sh, else: Shape.prevent(sh)
        %{o | class: class, shape: sh}

      _ ->
        %{to_dict(o) | class: class}
    end
  end

  # ── inline caches ──────────────────────────────────────────
  # The inline caches of the compiled code (step A2, `Browser.JS.Interp.get_ic/3`) read and
  # write a fast record through these macros, so that the fields stay in this module. The
  # cells and the rules of a hit are in the moduledoc of `Browser.JS.Shape`.

  @doc """
  A pattern that matches a record in fast mode. It binds the `sid` of the shape to `sid` and
  the tuple of the values to `vals`. With a pinned `sid` (`^sid`) it matches only a record
  with that shape. It costs no call: it is a match of a map and a tuple.
  """
  defmacro fast_record(sid, vals) do
    quote do
      %{shape: {:js_shape, unquote(sid), _, _, _, _, _}, vals: unquote(vals)}
    end
  end

  @doc "The value at the position `pos` of the fast record `o`."
  defmacro slot(o, pos) do
    quote do: :erlang.element(unquote(pos), :erlang.map_get(:vals, unquote(o)))
  end

  @doc """
  The fast record `o`, whose values are `vals`, with the value at the position `pos` set to
  `v`. It is the write of `own_update/3` without the search of the key: the caller knows
  the position from the shape.
  """
  defmacro put_slot(o, vals, pos, v) do
    quote do
      o = unquote(o)
      vals = unquote(vals)
      pos = unquote(pos)
      v = unquote(v)
      %{o | vals: unquote(@put_val)}
    end
  end

  @doc """
  The fast record `o`, whose values are `vals`, with the shape `child` and the new value `v`
  at the end. It is the add of `add_default/3` without the read of the transition table:
  the add cell of an inline cache (step A3) holds `child`, which is the child of the shape
  of `o` with the new key at the end.
  """
  defmacro put_added(o, child, vals, v) do
    quote do
      %{
        unquote(o)
        | shape: unquote(child),
          vals: :erlang.append_element(unquote(vals), unquote(v))
      }
    end
  end

  @doc "The shape of the fast record `o`."
  defmacro shape(o), do: quote(do: :erlang.map_get(:shape, unquote(o)))

  @doc "The `sid` of the shape of `o`, or `nil` when `o` is not a fast record."
  def shape_id(o) do
    case o do
      %{shape: {:js_shape, sid, _, _, _, _, _}} -> sid
      _ -> nil
    end
  end

  @doc """
  Where the fast record `o` holds the own key `key`: `{pos, bits}`, the position of its value
  and its attribute bits (writable `1`, enumerable `2`, configurable `4`), or `nil` when `o`
  is not a fast record or has no such key. A miss of an inline cache uses it.
  """
  def fast_slot(o, key) do
    case o do
      %{shape: {:js_shape, _, %{^key => pos}, _, bits, _, _}} -> {pos, :erlang.element(pos, bits)}
      _ -> nil
    end
  end

  # ── writing ────────────────────────────────────────────────
  # Each writer takes a record and gives the new record. The caller stores it. The writers
  # of the hot paths (an update, an assignment, a literal one key at a time) are macros. The
  # others are functions, because a function is the same for a key that the caller knows
  # at compile time and for a key that it does not know.

  @doc """
  `o` with the value of its own key `key` changed to `v`. The key must exist and must not
  be an accessor or read-only (the caller tests that). Nothing else changes.
  """
  defmacro own_update(o, key, v) do
    quote do
      o = unquote(o)
      key = unquote(key)
      v = unquote(v)

      case o do
        %{shape: {:js_shape, _, %{^key => pos}, _, _, _, _}, vals: vals} ->
          %{o | vals: unquote(@put_val)}

        _ ->
          %{o | props: %{:erlang.map_get(:props, o) | key => v}}
      end
    end
  end

  @doc """
  `o` with the stored value of `key` set to `v` and nothing else changed: no change of the
  key order or of the attributes. The key must exist, or it must be a private name, which
  has no place in the order. Private names, a write to an own writable data property
  (`Reflect.set`) and an accessor of a private name use it.
  """
  defmacro own_put_value(o, key, v) do
    quote do
      o = unquote(o)
      key = unquote(key)
      v = unquote(v)

      case o do
        %{shape: {:js_shape, _, %{^key => pos}, _, _, _, _}, vals: vals} ->
          %{o | vals: unquote(@put_val)}

        # (a private name: writable and configurable, not in the order)
        %{shape: _} ->
          Browser.JS.Obj.fast_add(o, key, v, unquote(@hidden))

        _ ->
          %{o | props: Map.put(o.props, key, v)}
      end
    end
  end

  @doc """
  `o` with the new own property `key` that an assignment makes: writable, enumerable and
  configurable, at the end of the order.
  """
  defmacro own_add_assigned(o, key, v) do
    quote bind_quoted: [o: o, key: key, v: v] do
      case o do
        %{shape: _} -> Browser.JS.Obj.add_default(o, key, v)
        _ when is_binary(key) -> Browser.JS.Obj.add_name(o, key, v)
        _ -> Browser.JS.Obj.add_symbol(o, key, v)
      end
    end
  end

  @doc false
  # `o` (a fast record without `key`) with the new key `key` with the default attributes and
  # the value `v`. The transition that the table has already costs no call: the macro reads
  # the table of the shape. Only the macros of this module use it.
  defmacro add_default(o, key, v) do
    quote bind_quoted: [o: o, key: key, v: v] do
      %{shape: {:js_shape, sid, _, _, _, _, _}, vals: vals} = o

      # (7 is `@default`, as a literal, because `bind_quoted` turns `unquote` off)
      case :erlang.get({:jst, sid}) do
        %{^key => %{7 => child}} ->
          %{o | shape: child, vals: :erlang.append_element(vals, v)}

        _ ->
          Browser.JS.Obj.fast_add(o, key, v, 7)
      end
    end
  end

  @doc false
  # `o` with the new enumerable string key `key` with the value `v`, at the end of the
  # order. A record without `skeys` needs only the change of `keys`, which is the add of an
  # assignment before the exact order. Only the macros of this module use it.
  defmacro add_name(o, key, v) do
    quote bind_quoted: [o: o, key: key, v: v] do
      case o do
        %{skeys: skeys} ->
          %{o | props: Map.put(o.props, key, v), keys: [key | o.keys], skeys: [key | skeys]}

        _ ->
          %{o | props: Map.put(o.props, key, v), keys: [key | o.keys]}
      end
    end
  end

  @doc false
  # `o` with the new enumerable symbol key `key` with the value `v`, at the end of the
  # symbols. Only the macros of this module use it.
  defmacro add_symbol(o, key, v) do
    quote bind_quoted: [o: o, key: key, v: v] do
      case o do
        %{syms: syms} ->
          %{o | props: Map.put(o.props, key, v), keys: [key | o.keys], syms: [key | syms]}

        _ ->
          Map.put(%{o | props: Map.put(o.props, key, v), keys: [key | o.keys]}, :syms, [key])
      end
    end
  end

  @doc false
  # The fast record `o` with the new key `key` with the attribute bits `b` and the value
  # `v`, or the record in dictionary mode with that key when the add passes a limit of
  # `Browser.JS.Shape`.
  # (an index-like key is past a limit, so the test comes before the reads of the table)
  def fast_add(o, key, v, b)
      when is_binary(key) and byte_size(key) > 0 and binary_part(key, 0, 1) >= "0" and
             binary_part(key, 0, 1) <= "9",
      do: o |> to_dict() |> dict_add(key, v, b)

  def fast_add(%{shape: {:js_shape, sid, _, _, _, _, _} = sh, vals: vals} = o, key, v, b) do
    case :erlang.get({:jst, sid}) do
      %{^key => %{^b => child}} ->
        %{o | shape: child, vals: :erlang.append_element(vals, v)}

      _ ->
        case Shape.add(sh, key, b) do
          :dict -> o |> to_dict() |> dict_add(key, v, b)
          child -> %{o | shape: child, vals: :erlang.append_element(vals, v)}
        end
    end
  end

  # The dictionary record `o` with the new key `key` with the bits `b` and the value `v`.
  defp dict_add(o, key, v, b) do
    o = add_key(o, key, Shape.e?(b))
    put_entry(%{o | props: Map.put(o.props, key, v)}, key, %{c: Shape.c?(b), w: Shape.w?(b)})
  end

  # The fast record `o` with the bits of its own key `key` set to `b`, or the record in
  # dictionary mode with these attributes when the change passes a limit of
  # `Browser.JS.Shape`. The key keeps its place.
  defp fast_reconf(%{shape: {:js_shape, _, index, _, _, _, _} = sh} = o, key, b) do
    case Shape.reconf(sh, :erlang.map_get(key, index), b) do
      :dict ->
        o = to_dict(o)
        o = set_enumerable(o, key, Shape.e?(b))
        put_entry(o, key, %{c: Shape.c?(b), w: Shape.w?(b)})

      new ->
        %{o | shape: new}
    end
  end

  # The attribute bits of a key from its writable, enumerable and configurable values
  # (`Browser.JS.Shape`). It is inline, so that a define costs no more calls than before.
  @compile {:inline, bits: 3}
  defp bits(w, e, c),
    do: if(w, do: 1, else: 0) + if(e, do: 2, else: 0) + if(c, do: 4, else: 0)

  # The bits of the own key `key` of the fast record `o`.
  defp fast_bits(%{shape: {:js_shape, _, index, _, bits, _, _}}, key),
    do: :erlang.element(:erlang.map_get(key, index), bits)

  @doc false
  # `o` with the new key `key` at the end of the order, enumerable when `e`, and with no
  # value or attributes yet. A private name gets no place.
  def add_key(o, key, e) when is_binary(key) do
    case o do
      %{skeys: skeys} when e -> %{o | keys: [key | o.keys], skeys: [key | skeys]}
      %{skeys: skeys} -> %{o | skeys: [key | skeys]}
      _ when e -> %{o | keys: [key | o.keys]}
      _ -> Map.put(o, :skeys, [key | all_names(o)])
    end
  end

  def add_key(o, {:symbol, _, _} = key, e) do
    o = Map.put(o, :syms, [key | Map.get(o, :syms, [])])
    if e, do: %{o | keys: [key | o.keys]}, else: o
  end

  def add_key(o, _private, _e), do: o

  @doc """
  CreateDataProperty on the record `o`: `key` gets the value `v`. A new key is enumerable
  (also a symbol). An existing key keeps its place and its attributes.
  """
  defmacro define_data(o, key, v) do
    quote do
      o = unquote(o)
      key = unquote(key)
      v = unquote(v)

      case o do
        %{shape: {:js_shape, _, %{^key => pos}, _, _, _, _}, vals: vals} ->
          %{o | vals: unquote(@put_val)}

        %{shape: _} ->
          Browser.JS.Obj.add_default(o, key, v)

        %{props: %{^key => _}} ->
          %{o | props: Map.put(o.props, key, v)}

        _ when is_binary(key) ->
          Browser.JS.Obj.add_name(o, key, v)

        _ ->
          Browser.JS.Obj.add_symbol(o, key, v)
      end
    end
  end

  @doc """
  `o` with an own property `key` with the value `v` that does not show up in `Object.keys`.
  A new key is writable and configurable, and it goes to the end of the order. An existing
  key keeps its attributes and its place.
  """
  def put_hidden(o, key, v) do
    cond do
      has_own?(o, key) -> own_put_value(o, key, v)
      fast?(o) -> fast_add(o, key, v, @hidden)
      true -> %{add_key(o, key, false) | props: Map.put(o.props, key, v)}
    end
  end

  @doc """
  `o` with `key` set to `v` with the attributes `flags` (a map of `w`, `c` and `e`, stored
  as they are in a dictionary record). A new key goes to the end of the order, enumerable
  only when `flags` has `e: true`. An existing key keeps its place and its enumerability.
  Built-ins use it for properties that are not enumerable (`@@toStringTag`, `prototype`).
  """
  def put_with_attrs(o, key, v, flags) do
    w = Map.get(flags, :w, true)
    c = Map.get(flags, :c, true)

    cond do
      fast?(o) and has_own?(o, key) ->
        o
        |> own_put_value(key, v)
        |> fast_reconf(key, bits(w, Shape.e?(fast_bits(o, key)), c))

      fast?(o) ->
        fast_add(o, key, v, bits(w, match?(%{e: true}, flags), c))

      true ->
        o = if has_own?(o, key), do: o, else: add_key(o, key, match?(%{e: true}, flags))

        %{o | props: Map.put(o.props, key, v)}
        |> Map.put(:attrs, Map.put(attr_map(o), key, flags))
    end
  end

  @doc "`o` with the attributes of the existing key `key` set to `flags` (stored as they are)."
  def put_attrs(o, key, flags) do
    if fast?(o) and has_own?(o, key) do
      b =
        bits(
          Map.get(flags, :w, true),
          Shape.e?(fast_bits(o, key)),
          Map.get(flags, :c, true)
        )

      fast_reconf(o, key, b)
    else
      o = to_dict(o)
      Map.put(o, :attrs, Map.put(attr_map(o), key, flags))
    end
  end

  @doc """
  `o` with the attributes of the element at index `i` set to `flags` (`%{w, c, e}`). The
  default attributes take no entry.
  """
  def put_element_attrs(o, i, flags) do
    o = to_dict(o)
    attrs = attr_map(o)

    attrs =
      if flags == %{w: true, c: true, e: true},
        do: Map.delete(attrs, i),
        else: Map.put(attrs, i, flags)

    Map.put(o, :attrs, attrs)
  end

  @doc """
  `o` with the new own property `key` that `defineProperty` makes: the stored value `value`
  (an accessor is `{:accessor, g, s}`), the attributes `flags` (`%{c, w}`; the default
  attributes take no entry) and the enumerability `e`. The key goes to the end of the
  order.
  """
  def own_add(o, key, value, flags, e) do
    if fast?(o) do
      fast_add(o, key, value, bits(flags.w, e, flags.c))
    else
      o = add_key(o, key, e)
      put_entry(%{o | props: Map.put(o.props, key, value)}, key, flags)
    end
  end

  @doc """
  `o` with the own property `key` changed by `defineProperty`: the stored value `value`,
  the attributes `flags` (`%{c, w}`) and the enumerability `e`. An existing key keeps its
  place, also when it becomes enumerable again. A key that the record does not hold yet
  (the `name` of a function) goes to the end of the order.
  """
  def own_redefine(o, key, value, flags, e) do
    cond do
      fast?(o) and has_own?(o, key) ->
        o |> own_put_value(key, value) |> fast_reconf(key, bits(flags.w, e, flags.c))

      fast?(o) ->
        fast_add(o, key, value, bits(flags.w, e, flags.c))

      true ->
        o = if has_own?(o, key), do: set_enumerable(o, key, e), else: add_key(o, key, e)
        put_entry(%{o | props: Map.put(o.props, key, value)}, key, flags)
    end
  end

  # Every string key of `o`, newest first: `skeys`, or the names in `keys` when the record
  # has no hidden string key.
  defp all_names(o) do
    case o do
      %{skeys: skeys} -> skeys
      %{keys: []} -> []
      %{keys: keys} -> Enum.filter(keys, &is_binary/1)
    end
  end

  # `o` with the attribute entry of `key` set to the flags `flags` (`%{c, w}`). The default
  # attributes take no entry.
  defp put_entry(o, key, flags) do
    cond do
      flags != %{c: true, w: true} -> Map.put(o, :attrs, Map.put(attr_map(o), key, flags))
      is_map_key(o, :attrs) -> %{o | attrs: Map.delete(o.attrs, key)}
      true -> o
    end
  end

  # `o` with the existing key `key` enumerable (`e`) or not. The key keeps its place in the
  # order. A string key that becomes enumerable again goes back to its place among the
  # enumerable names, which `skeys` gives. The place of a symbol in `keys` has no effect,
  # because the order of the symbols is in `syms`.
  defp set_enumerable(o, key, e) do
    cond do
      e == key in o.keys ->
        o

      e and is_binary(key) ->
        names = Enum.filter(o.skeys, &(&1 == key or &1 in o.keys))
        %{o | keys: names ++ Enum.reject(o.keys, &is_binary/1)}

      e ->
        %{o | keys: [key | o.keys]}

      is_binary(key) ->
        o
        |> Map.put(:skeys, all_names(o))
        |> Map.put(:keys, List.delete(o.keys, key))

      true ->
        %{o | keys: List.delete(o.keys, key)}
    end
  end

  @doc """
  `o` with `key` made a writable, enumerable and configurable data property with the value
  `v`, as a sloppy `eval` makes a global function. The key must exist. It keeps its place.
  """
  def reopen(o, key, v) do
    if fast?(o) do
      o |> own_put_value(key, v) |> fast_reconf(key, @default)
    else
      o = set_enumerable(o, key, true)
      put_entry(%{o | props: Map.put(o.props, key, v)}, key, %{c: true, w: true})
    end
  end

  @doc """
  `o` without the own key `key`: its value, its place and its attributes go. A fast record
  goes back to the shape before the add of its last key. The delete of another key makes
  the record a dictionary.
  """
  def own_delete(o, key) do
    # (the entry `:up` of the table holds the shape before the add of the last key. A shape
    # that a change of attributes or an integrity level made has none, and the table can be
    # erased, so the record then goes to dictionary mode)
    with %{shape: {:js_shape, sid, %{^key => pos}, _, _, _, _}, vals: vals} <- o,
         true <- pos == tuple_size(vals),
         %{up: up} <- :erlang.get({:jst, sid}) do
      %{o | shape: up, vals: :erlang.delete_element(pos, vals)}
    else
      %{shape: {:js_shape, _, index, _, _, _, _}} when not is_map_key(index, key) ->
        o

      _ ->
        o = o |> to_dict() |> own_remove(key)
        if is_map_key(o, :attrs), do: %{o | attrs: Map.delete(o.attrs, key)}, else: o
    end
  end

  @doc """
  `o` without the own key `key` and without its place in the order. The attributes stay (a
  global function declaration replaces the property). The record goes to dictionary mode.
  """
  def own_remove(o, key) do
    o = to_dict(o)
    o = %{o | props: Map.delete(o.props, key), keys: List.delete(o.keys, key)}

    case o do
      %{skeys: skeys} when is_binary(key) -> %{o | skeys: List.delete(skeys, key)}
      %{syms: syms} when not is_binary(key) -> %{o | syms: List.delete(syms, key)}
      _ -> o
    end
  end

  @doc "`o` made not extensible."
  def prevent(o) do
    case o do
      %{shape: sh} -> %{o | shape: Shape.prevent(sh)}
      _ -> Map.put(o, :ext, false)
    end
  end

  @doc """
  `o` sealed (`freeze?` false) or frozen: each public key becomes not configurable (and
  each data property not writable when frozen), the object becomes not extensible, and an
  array gets the element flag.
  """
  def lock(%{shape: sh, vals: vals} = o, freeze?) do
    accessors =
      for i <- 1..tuple_size(vals)//1,
          match?({:accessor, _, _}, :erlang.element(i, vals)),
          do: i

    o = %{o | shape: Shape.lock(sh, freeze?, accessors)}

    # (the elements of an array are not in the shape: the flag of the record locks them,
    # as for a dictionary record)
    cond do
      o.class != :array -> o
      freeze? -> Map.put(o, :frozen, true)
      true -> Map.put(o, :sealed, true)
    end
  end

  def lock(o, freeze?) do
    attrs =
      Enum.reduce(public_keys(o), attr_map(o), fn key, attrs ->
        accessor? = match?({:accessor, _, _}, o.props[key])
        cur = Map.get(attrs, key, %{})
        w = if freeze? and not accessor?, do: false, else: Map.get(cur, :w, true)
        Map.put(attrs, key, %{c: false, w: w})
      end)

    o = o |> Map.put(:attrs, attrs) |> Map.put(:ext, false)
    o = if freeze? and o.class == :array, do: Map.put(o, :frozen, true), else: o
    if not freeze? and o.class == :array, do: Map.put(o, :sealed, true), else: o
  end

  @doc false
  # The fast record `o` with the shape `sh` and the values `acc` (newest first), with the
  # enumerable data properties `pairs` added through the transitions. A key that is there
  # already gets the new value. `plain_record/2` calls it with the empty record and the
  # root. A transition that the table has already costs no call (`add_default/3`), so the
  # build costs one call for each key, as the build of a dictionary record does.
  def add_pairs(o, [{k, v} | rest], {:js_shape, sid, index, _, _, _, _} = sh, acc)
      when not is_map_key(index, k) do
    case :erlang.get({:jst, sid}) do
      %{^k => %{@default => child}} ->
        add_pairs(o, rest, child, [v | acc])

      _ ->
        case Shape.add(sh, k, @default) do
          :dict ->
            o = to_dict(%{o | shape: sh, vals: :erlang.list_to_tuple(:lists.reverse(acc, []))})
            Enum.reduce([{k, v} | rest], o, &put_pair/2)

          child ->
            add_pairs(o, rest, child, [v | acc])
        end
    end
  end

  def add_pairs(o, [_ | _] = pairs, sh, acc) do
    o = %{o | shape: sh, vals: :erlang.list_to_tuple(:lists.reverse(acc, []))}
    Enum.reduce(pairs, o, &put_pair/2)
  end

  def add_pairs(o, [], sh, acc),
    do: %{o | shape: sh, vals: :erlang.list_to_tuple(:lists.reverse(acc, []))}

  # `define_data/3` for `add_pairs/4`, in the two modes.
  defp put_pair({k, v}, o) do
    cond do
      has_own?(o, k) -> own_put_value(o, k, v)
      fast?(o) -> fast_add(o, k, v, @default)
      true -> dict_add(o, k, v, @default)
    end
  end
end
