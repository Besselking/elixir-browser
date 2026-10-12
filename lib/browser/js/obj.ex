defmodule Browser.JS.Obj do
  @moduledoc """
  The record API for the own properties of a JavaScript object (data-model steps A0a and
  A0b).

  This module is the only module that reads or writes the fields of a heap record that hold
  own properties: `props`, `keys`, `skeys`, `syms`, `attrs`, `ext`, `frozen` and `sealed`.
  The other modules call the functions and macros here. Thus a later step (A1, fast records
  with shapes) can change the representation in this module alone.

  ## The representation of today

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

  A private name is in `props` alone: it has no place in the key order.

  The elements of an array (`items`, `len`) are not in this API (part B of the shapes
  plan). Their attributes share the `attrs` map, so `attr_flags/2`,
  `element_enumerable?/2` and `put_element_attrs/3` are here.

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

  The lists are separate for the cost. An assignment, a literal, `Object.keys` and for-in
  read and write `keys` alone, as before the exact order. Only a record that has a string
  key that is not enumerable pays for `skeys`, and only a record with a symbol pays for
  `syms`.

  ## Cost

  Many callers are hot paths of the interpreter and of the compiled code (a named read, an
  update, an add, a literal, `hasOwnProperty`, `Object.keys`, for-in, the elements of an
  array). A remote call costs one reduction, and a remote BIF call such as `Map.has_key?/2`
  or `Map.get/3` costs four. A macro here expands to code that costs the same as the code
  that it replaces, or less: it uses guard BIFs (`is_map_key/2`, `:erlang.map_get/2`),
  pattern matches and map updates, which cost no reduction. A function here is used only on
  a path that is not hot, or where the BIF calls that it removes pay for the call.

  ## The grep gate

  No module other than this one names the fields. This command finds the direct uses
  outside this module: a field after a dot, a field as a key of a map or a keyword list,
  and a field atom in any other place (a call of `Map`, `:maps` or `Access`, a list of
  fields). Comment lines do not count, and the last stage removes the lines of the
  allow-list below. So the command prints nothing. `test/browser/js_obj_test.exs` runs
  the same search with the same patterns, and it fails when they are not the same as here.

      grep -rnP '(?<!Map|Object|Keyword|Reflect|prototype)\\.(props|keys|skeys|syms|attrs|ext|frozen|sealed)\\b(?![?!(])|\\b(props|keys|skeys|syms|attrs|ext|frozen|sealed):|(?<![{\\w:]):(props|keys|skeys|syms|attrs|ext|frozen|sealed)\\b' lib/browser/js --include=*.ex | grep -vP '^[^:]+:\\d+:\\s*#' | grep -v '^lib/browser/js/obj.ex:' | grep -vP '^lib/browser/js/dom\\.ex:\\d+:.*((\\bn|&1)\\.(attrs|props)\\b|node\\(this_nid\\(this\\)\\)\\.attrs\\b|\\b(attrs|props): (\\[\\]|%\\{\\}|%\\{"value"|visible\\b|attrs\\b|props\\b)|%\\{fields: [^}]*keys: )|^lib/browser/js/(collections|typed_arrays)\\.ex:\\d+:(\\s*:keys ->|.*_iterator\\(this, (:\\w+, )?:keys\\))|^lib/browser/js/collections\\.ex:\\d+:.*(has: has, keys: keys\\}|call\\(rec\\.keys, rec\\.obj, \\[\\]\\))'

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
  because the walk reads each integer as a heap id and these fields hold only keys and
  attributes (the id of a symbol can be an integer). A1 must change these two guards for
  its record: a shape id and a slot position are integers too.
  The shadow run of `Browser.JS.Fast` compares two records by `normal/1`, which A1 must
  also change. The other modules under `lib/browser` (layout, style, HTML, cookies, the
  console of the session) have their own `attrs` and `props`, but they never read a
  heap record, so the gate does not search them.

  ## A known gap before A1

  The `length` of an arguments object is not an ordinary own property: `delete
  arguments.length` removes the value and the place with `own_drop/2` and keeps the
  attributes, and the interpreter marks the record with `len_gone`. A record of A1 cannot
  hold attributes without a value. So before A1, `arguments.length` must become an ordinary
  own property (made with `put_hidden/3`, removed with `own_delete/2`), and `own_drop/2`
  must go. This also corrects two results that differ from the spec today: after a delete,
  a new `arguments.length` is not enumerable, and `Object.defineProperty(arguments,
  "length", {enumerable: true})` throws.
  """

  # ── building ───────────────────────────────────────────────

  @doc """
  A new record with no own property: the map `fields` (a keyword list in the source, for
  example `class: :object, proto: p`) plus the empty own-property fields. It is a macro,
  so the record is one map literal at the call site.
  """
  defmacro record(fields) do
    quote do
      %{unquote_splicing(fields), props: %{}, keys: []}
    end
  end

  @doc """
  A new record with the enumerable data properties `pairs` (a list of `{key, value}`, in
  creation order) and the fields of `record/1`. The keys must be distinct: each key of
  `pairs` goes into the key order as it is. A key can be a symbol (the rest of an object
  pattern copies the enumerable symbols too).
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

  @doc false
  # The string keys of `pairs` (see `record/2`), newest first, or `:symbols` when a key is a
  # symbol. One walk makes the list newest first, which costs less than a map and a
  # reverse.
  def pair_names([{k, _} | rest], acc) when is_binary(k), do: pair_names(rest, [k | acc])
  def pair_names([], acc), do: acc
  def pair_names(_, _acc), do: :symbols

  @doc """
  The key layout of an object literal with the constant keys `keys` (in source order), for
  `fill/3`. The compiler calls it once, when it compiles the literal. Today it is the list
  of the distinct keys, newest first: a key that comes two times keeps its first place.
  """
  def literal_keys(keys), do: keys |> Enum.uniq() |> Enum.reverse()

  @doc """
  The record `o` (a new empty object) with all the properties of an object literal in one
  write: `layout` is from `literal_keys/1`, and `pairs` gives each value in source order.
  `:maps.from_list/1` keeps the last value of a key, as `define_data/3` does.
  """
  defmacro fill(o, layout, pairs) do
    quote do
      %{unquote(o) | props: :maps.from_list(unquote(pairs)), keys: unquote(layout)}
    end
  end

  # ── reading ────────────────────────────────────────────────

  @doc "Whether the record `o` has the own key `key`. It is a guard."
  defguard has_own?(o, key) when is_map_key(:erlang.map_get(:props, o), key)

  @doc "Whether `o` is a record of an object (it has own-property fields). It is a guard."
  defguard object?(o) when is_map(o) and is_map_key(o, :props)

  @doc """
  Whether `o` is the record of a heap object: a map with own-property fields and a class.
  It is a guard. A DOM node also has a `props` field, but it has no class.
  """
  defguard heap_record?(o) when object?(o) and is_map_key(o, :class)

  @doc """
  Whether the field `field` of a heap record holds no heap id, so that the garbage collector
  does not walk it. It is a guard. These own-property fields hold keys that `props` also
  holds (or keys that are gone) and attributes. The collector reads each integer as an id,
  so the integer id of a symbol could keep a dead object alive.
  """
  defguard no_refs?(field) when field in [:keys, :skeys, :syms, :attrs]

  @doc """
  The stored value of the own key `key` of `o`: `{:ok, value}` or `:error`. An accessor
  gives `{:ok, {:accessor, getter, setter}}`.
  """
  defmacro own_fetch(o, key) do
    quote do
      case unquote(o) do
        %{props: %{unquote(key) => v}} -> {:ok, v}
        _ -> :error
      end
    end
    |> pin_key(key)
  end

  @doc "The stored value of the own key `key` of `o`, or `nil` when there is none."
  defmacro own_value(o, key) do
    quote do
      case unquote(o) do
        %{props: %{unquote(key) => v}} -> v
        _ -> nil
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
  order makes it match a missing key alone. A representation that gets `{:ok, v}` or
  `:error` first and then matches would otherwise give a different result.
  """
  defmacro own_case(o, key, do: clauses) do
    {kpat, pre} = key_pattern(key)

    Enum.reduce(clauses, false, fn {:->, _, [[head], _]}, all_ok? ->
      check_order(head, all_ok?)
    end)

    clauses =
      Enum.map(clauses, fn {:->, meta, [[head], body]} ->
        {:->, meta, [[own_head(head, kpat)], body]}
      end)

    quote do
      unquote_splicing(pre)

      case unquote(o) do
        unquote(clauses)
      end
    end
  end

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
      :erlang.map_get(:keys, unquote(o)) |> :lists.reverse() |> Enum.filter(&is_binary/1)
    end
  end

  @doc """
  The enumerable keys of `o` in creation order when each one is a plain name, or `nil`. A
  plain name is a string that does not start with a digit, so it cannot be an array index,
  and the list is then the order of `Object.keys` as it is (fast path `:has_own` of
  `Browser.JS.Interp`). A symbol is no plain name.
  """
  defmacro plain_names(o) do
    quote do
      keys = :erlang.map_get(:keys, unquote(o))
      if Browser.JS.Obj.plain_names?(keys), do: :lists.reverse(keys)
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
  # The attribute map of `o`: each key or element index with non-default attributes, to a
  # map with some of `w`, `c` and `e`. Only the macros of this module use it: their
  # expansion calls it at the call site, so it must be public.
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
  `w`, `c` and `e`.
  """
  defmacro attr_flags(o, key) do
    quote do
      case unquote(o) do
        %{attrs: %{unquote(key) => flags}} -> flags
        _ -> %{}
      end
    end
    |> pin_key(key)
  end

  @doc "Whether the own key (or element) `key` of `o` is writable, when it exists."
  defmacro writable?(o, key) do
    quote do
      case unquote(o) do
        %{attrs: %{unquote(key) => a}} -> match?(%{w: true}, a)
        _ -> true
      end
    end
    |> pin_key(key)
  end

  @doc "Whether the own key (or element) `key` of `o` is configurable, when it exists."
  defmacro configurable?(o, key) do
    quote do
      case unquote(o) do
        %{attrs: %{unquote(key) => a}} -> match?(%{c: true}, a)
        _ -> true
      end
    end
    |> pin_key(key)
  end

  @doc """
  Whether `key` has only the default attributes in `o` (writable and configurable). It is
  a guard, for the fast update of `Browser.JS.Interp`.
  """
  defguard default_attrs?(o, key)
           when not (is_map_key(o, :attrs) and is_map_key(:erlang.map_get(:attrs, o), key))

  @doc "Whether `o` is extensible."
  defmacro extensible?(o) do
    quote do
      case unquote(o) do
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
        %{props: %{^key => stored}} ->
          attrs = Browser.JS.Obj.attr_flags(o, key)
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
    quote do: Map.keys(:erlang.map_get(:props, unquote(o)))
  end

  # private names are outside freezing and sealing
  defp public_keys(o), do: Enum.reject(Map.keys(o.props), &match?({:private, _}, &1))

  @doc """
  Every own string key of `o`, enumerable or not, in creation order (the string keys of
  OrdinaryOwnPropertyKeys). The caller puts the index keys first. It also adds the keys
  that the record does not hold (the `length` of an array, the `name` of a function).
  """
  def string_keys(o) do
    case o do
      %{skeys: skeys} -> :lists.reverse(skeys)
      %{keys: keys} -> keys |> :lists.reverse() |> Enum.filter(&is_binary/1)
    end
  end

  @doc "Every own symbol key of `o`, enumerable or not, in creation order."
  def symbol_keys(o) do
    case o do
      %{syms: syms} -> :lists.reverse(syms)
      _ -> []
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
        a = attr_flags(o, key)
        accessor? = match?({:accessor, _, _}, o.props[key])

        Map.get(a, :c, true) == false and
          (not freeze? or accessor? or Map.get(a, :w, true) == false)
      end) and
      (o.class != :array or o.items == %{} or
         frozen?(o) or (not freeze? and sealed?(o)))
  end

  @doc """
  The record `o` in its normal form, for a compare of two records. Two records that hold the
  same own properties, in the same order and with the same attributes, have the same normal
  form. A record has some forms for the same content: `skeys` can be equal to `keys` (all
  the hidden keys are gone or enumerable again), and `syms` and `attrs` can be empty (all
  the symbols or all the attributes are gone). The normal form has no such field. A
  representation with two forms of a record (in A1, a fast record and a dictionary record)
  gives one form here, so that the shadow run of `Browser.JS.Fast` compares what two
  records hold, not their form. A term that is not a map (`nil` when the shadow run has no
  record) is its own normal form.
  """
  def normal(o) when is_map(o) do
    o = if is_map_key(o, :skeys) and o.skeys == o.keys, do: Map.delete(o, :skeys), else: o
    o = if Map.get(o, :syms) == [], do: Map.delete(o, :syms), else: o
    if Map.get(o, :attrs) == %{}, do: Map.delete(o, :attrs), else: o
  end

  def normal(other), do: other

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
    quote bind_quoted: [o: o, key: key, v: v] do
      %{o | props: %{:erlang.map_get(:props, o) | key => v}}
    end
  end

  @doc """
  `o` with the stored value of `key` set to `v` and nothing else changed: no change of the
  key order or of the attributes. The key must exist, or it must be a private name, which
  has no place in the order. Private names, a write to an own writable data property
  (`Reflect.set`) and an accessor of a private name use it.
  """
  defmacro own_put_value(o, key, v) do
    quote bind_quoted: [o: o, key: key, v: v] do
      %{o | props: Map.put(o.props, key, v)}
    end
  end

  @doc """
  `o` with the new own property `key` that an assignment makes: writable, enumerable and
  configurable, at the end of the order.
  """
  defmacro own_add_assigned(o, key, v) do
    quote bind_quoted: [o: o, key: key, v: v] do
      if is_binary(key),
        do: Browser.JS.Obj.add_name(o, key, v),
        else: Browser.JS.Obj.add_symbol(o, key, v)
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
    quote bind_quoted: [o: o, key: key, v: v] do
      cond do
        Browser.JS.Obj.has_own?(o, key) -> %{o | props: Map.put(o.props, key, v)}
        is_binary(key) -> Browser.JS.Obj.add_name(o, key, v)
        true -> Browser.JS.Obj.add_symbol(o, key, v)
      end
    end
  end

  @doc """
  `o` with an own property `key` with the value `v` that does not show up in `Object.keys`.
  A new key is writable and configurable, and it goes to the end of the order. An existing
  key keeps its attributes and its place.
  """
  def put_hidden(o, key, v) do
    o = if has_own?(o, key), do: o, else: add_key(o, key, false)
    %{o | props: Map.put(o.props, key, v)}
  end

  @doc """
  `o` with `key` set to `v` with the attributes `flags` (a map of `w`, `c` and `e`, stored
  as they are). A new key goes to the end of the order, enumerable only when `flags` has
  `e: true`. An existing key keeps its place and its enumerability. Built-ins use it for
  properties that are not enumerable (`@@toStringTag`, `prototype`).
  """
  def put_with_attrs(o, key, v, flags) do
    o = if has_own?(o, key), do: o, else: add_key(o, key, match?(%{e: true}, flags))
    %{o | props: Map.put(o.props, key, v)} |> Map.put(:attrs, Map.put(attr_map(o), key, flags))
  end

  @doc "`o` with the attributes of the existing key `key` set to `flags` (stored as they are)."
  defmacro put_attrs(o, key, flags) do
    quote bind_quoted: [o: o, key: key, flags: flags] do
      Map.put(o, :attrs, Map.put(Browser.JS.Obj.attr_map(o), key, flags))
    end
  end

  @doc """
  `o` with the attributes of the element at index `i` set to `flags` (`%{w, c, e}`). The
  default attributes take no entry.
  """
  defmacro put_element_attrs(o, i, flags) do
    quote bind_quoted: [o: o, i: i, flags: flags] do
      attrs = Browser.JS.Obj.attr_map(o)

      attrs =
        if flags == %{w: true, c: true, e: true},
          do: Map.delete(attrs, i),
          else: Map.put(attrs, i, flags)

      Map.put(o, :attrs, attrs)
    end
  end

  @doc """
  `o` with the new own property `key` that `defineProperty` makes: the stored value `value`
  (an accessor is `{:accessor, g, s}`), the attributes `flags` (`%{c, w}`; the default
  attributes take no entry) and the enumerability `e`. The key goes to the end of the
  order.
  """
  def own_add(o, key, value, flags, e) do
    o = add_key(o, key, e)
    put_entry(%{o | props: Map.put(o.props, key, value)}, key, flags)
  end

  @doc """
  `o` with the own property `key` changed by `defineProperty`: the stored value `value`,
  the attributes `flags` (`%{c, w}`) and the enumerability `e`. An existing key keeps its
  place, also when it becomes enumerable again. A key that the record does not hold yet
  (the `name` of a function) goes to the end of the order.
  """
  def own_redefine(o, key, value, flags, e) do
    o = if has_own?(o, key), do: set_enumerable(o, key, e), else: add_key(o, key, e)
    put_entry(%{o | props: Map.put(o.props, key, value)}, key, flags)
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
    o = set_enumerable(o, key, true)
    put_entry(%{o | props: Map.put(o.props, key, v)}, key, %{c: true, w: true})
  end

  @doc "`o` without the own key `key`: its value, its place and its attributes go."
  def own_delete(o, key) do
    o = own_remove(o, key)
    if is_map_key(o, :attrs), do: %{o | attrs: Map.delete(o.attrs, key)}, else: o
  end

  @doc """
  `o` without the stored value of `key` (the `length` of an arguments object). Its place
  goes too, and its attributes stay.
  """
  def own_drop(o, key), do: own_remove(o, key)

  @doc """
  `o` without the own key `key` and without its place in the order. The attributes stay (a
  global function declaration replaces the property).
  """
  def own_remove(o, key) do
    o = %{o | props: Map.delete(o.props, key), keys: List.delete(o.keys, key)}

    case o do
      %{skeys: skeys} when is_binary(key) -> %{o | skeys: List.delete(skeys, key)}
      %{syms: syms} when not is_binary(key) -> %{o | syms: List.delete(syms, key)}
      _ -> o
    end
  end

  @doc "`o` made not extensible."
  defmacro prevent(o) do
    quote do: Map.put(unquote(o), :ext, false)
  end

  @doc """
  `o` sealed (`freeze?` false) or frozen: each public key becomes not configurable (and
  each data property not writable when frozen), the object becomes not extensible, and an
  array gets the element flag.
  """
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
end
