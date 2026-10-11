defmodule Browser.JS.Obj do
  @moduledoc """
  The record API for the own properties of a JavaScript object (data-model step A0a).

  This module is the only module that reads or writes the fields of a heap record that hold
  own properties: `props`, `keys`, `attrs`, `horder`, `hpos`, `ext`, `frozen` and `sealed`.
  The other modules call the functions and macros here. Thus a later step (A1, fast records
  with shapes) can change the representation in this module alone.

  ## The representation of today

  * `props`: a map of each own key to its value, or to `{:accessor, getter, setter}` for an
    accessor. A key is a string, a symbol `{:symbol, id, description}` or a private name
    `{:private, ref}`.
  * `keys`: the enumerable keys, newest first. A string key that an assignment makes is in
    it. A symbol that `defineProperty` makes enumerable is in it too, so the readers filter
    it.
  * `attrs`: a map of a key (or an array element index) to its non-default attributes, a
    map with some of `w`, `c` and `e`. A key that is not in it is writable and
    configurable. A record with no `attrs` field has only default attributes.
  * `horder` and `hpos`: the creation order of the keys that are not enumerable, and the
    count of named enumerable keys at the time that each was made. `Object.getOwnPropertyNames`
    uses them to put a hidden key back among the enumerable keys.
  * `ext: false`: the object is not extensible. `frozen: true` and `sealed: true`: an array
    whose elements are frozen or sealed.

  The elements of an array (`items`, `len`) are not in this API (part B of the shapes
  plan). Their attributes share the `attrs` map, so `attr_map/1`, `attr_flags/2` and
  `put_element_attrs/3` are here.

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
  outside this module (comment lines do not count). Each line that it prints must be in the
  allow-list below. `test/browser/js_obj_test.exs` runs the same search.

      grep -rnP '(?<!Map|Object|Keyword|Reflect|prototype)\\.(props|keys|attrs|horder|hpos)\\b(?!\\()|\\b(props|keys|attrs|horder|hpos|ext|frozen|sealed):|Map\\.\\w+[?!]?\\((?:[^,]*, )?:(props|keys|attrs|horder|hpos|ext|frozen|sealed)\\b|(is_map_key\\([^,]+, |map_get\\(|\\[):(props|keys|attrs|horder|hpos|ext|frozen|sealed)\\b|^\\s+:(props|keys|attrs|horder|hpos|ext|frozen|sealed),?\\s*$' lib/browser/js --include=*.ex | grep -vP '^[^:]+:\\d+:\\s*#' | grep -v '^lib/browser/js/obj.ex:'

  The allow-list (the reason for each):

  * `lib/browser/js/dom.ex`: the maps of DOM nodes have their own `attrs` (the HTML
    attributes) and `props` (the live `value`, `checked` and `open`), and a realm has
    `keys`. These are not JavaScript object records.
  * `lib/browser/js/collections.ex`, `set_record/1` and `each_key/2`: the record of
    GetSetRecord (`%{obj, size, has, keys}`) holds the `keys` method of a set-like object.
    It is not a heap record.

  The garbage collector (`Browser.JS.GC`) walks every map generically and names no field,
  so it is not in the list. The other modules under `lib/browser` (layout, style, HTML,
  cookies, the console of the session) have their own `attrs`, `props` and `hpos`, but they
  never read a heap record, so the gate does not search them.
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
  `pairs` goes into the key order as it is.
  """
  defmacro record(fields, pairs) do
    quote do
      pairs = unquote(pairs)

      %{
        unquote_splicing(fields),
        props: Map.new(pairs),
        keys: pairs |> Enum.map(&elem(&1, 0)) |> Enum.reverse()
      }
    end
  end

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
  """
  defmacro own_case(o, key, do: clauses) do
    {kpat, pre} = key_pattern(key)

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
  The enumerable keys of `o`, newest first (as stored). A symbol that `defineProperty` made
  enumerable can be in the list, so a reader of string keys filters it.
  """
  defmacro enum_rev(o) do
    quote do: :erlang.map_get(:keys, unquote(o))
  end

  @doc """
  The attribute map of `o`: each key or element index with non-default attributes, to a map
  with some of `w`, `c` and `e`. A reader that tests many elements reads it once.
  """
  defmacro attr_map(o) do
    quote do
      case unquote(o) do
        %{attrs: attrs} -> attrs
        _ -> %{}
      end
    end
  end

  @doc "The non-default attributes of `key` (or of an element index) of `o`: a map with some of `w`, `c` and `e`."
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
          e = key in o.keys or (not is_binary(key) and Map.get(attrs, :e, false))
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
  The string keys of `o` for `Object.getOwnPropertyNames`, in three lists:
  `{enumerable, hidden, ordered}`. `enumerable` is in creation order. `hidden` are the
  string keys that are not enumerable: first the ones with a known creation order
  (`ordered`), then the others, sorted.
  """
  defmacro name_lists(o) do
    quote bind_quoted: [o: o] do
      base = o.keys |> Enum.reverse() |> Enum.filter(&is_binary/1)
      hidden0 = (Map.keys(o.props) -- o.keys) |> Enum.filter(&is_binary/1)

      ordered =
        o
        |> Map.get(:horder, [])
        |> Enum.reverse()
        |> Enum.uniq()
        |> Enum.filter(&(&1 in hidden0))

      {base, ordered ++ Enum.sort(hidden0 -- ordered), ordered}
    end
  end

  @doc """
  The keys `rest` (enumerable, in creation order) with the hidden keys `ordered` of `o` put
  where they were made among them, then the other `hidden` keys. A position is only known
  when every hidden key was made by `defineProperty` or `put_hidden/3`.
  """
  def interleave(rest, ordered, o, hidden) do
    pos = Map.get(o, :hpos, %{})

    placed =
      if Enum.all?(ordered, &Map.has_key?(pos, &1)),
        do: for(k <- ordered, do: {pos[k], k}),
        else: []

    done = Enum.map(placed, &elem(&1, 1))

    merged =
      rest
      |> Enum.with_index()
      |> Enum.flat_map(fn {k, i} ->
        [k | for({n, h} <- placed, n == i + 1, do: h)]
      end)

    lead = for {0, h} <- placed, do: h
    lead ++ merged ++ (hidden -- done)
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

  # ── writing ────────────────────────────────────────────────
  # Each writer takes a record and gives the new record. The caller stores it. Most writers
  # are macros: the interpreter calls them on paths that run for each call or each object
  # (an arguments object gets two hidden keys, a literal one key at a time).

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
  key order or of the attributes. A new key made this way is not enumerable and has no
  place in the hidden order. Private names, a write to an own writable data property
  (`Reflect.set`) and an accessor of a private name use it.
  """
  defmacro own_put_value(o, key, v) do
    quote bind_quoted: [o: o, key: key, v: v] do
      %{o | props: Map.put(o.props, key, v)}
    end
  end

  @doc """
  `o` with the new own property `key` that an assignment makes: writable, enumerable and
  configurable. A string key goes to the enumerable keys. A symbol key is marked
  enumerable in its attributes, because the list of enumerable keys is for strings.
  """
  defmacro own_add_assigned(o, key, v) do
    quote bind_quoted: [o: o, key: key, v: v] do
      o2 = %{
        o
        | props: Map.put(o.props, key, v),
          keys: if(is_binary(key), do: [key | o.keys], else: o.keys)
      }

      if is_binary(key),
        do: o2,
        else:
          Map.put(
            o2,
            :attrs,
            Map.put(Browser.JS.Obj.attr_map(o), key, %{e: true, w: true, c: true})
          )
    end
  end

  @doc """
  CreateDataProperty on the record `o`: `key` gets the value `v`. A new key is enumerable
  (also a symbol). An existing key keeps its place and its attributes.
  """
  defmacro define_data(o, key, v) do
    quote bind_quoted: [o: o, key: key, v: v] do
      keys = if Browser.JS.Obj.has_own?(o, key), do: o.keys, else: [key | o.keys]
      %{o | props: Map.put(o.props, key, v), keys: keys}
    end
  end

  @doc """
  `o` with an own property `key` with the value `v` that does not show up in `Object.keys`.
  A new key is writable and configurable, and it gets its place in the hidden order. An
  existing key keeps its attributes and its place.
  """
  defmacro put_hidden(o, key, v) do
    quote bind_quoted: [o: o, key: key, v: v] do
      o =
        if Browser.JS.Obj.has_own?(o, key) do
          o
        else
          # (where it stands among the enumerable names, so `ownKeys` can put it in
          # creation order)
          named = if o.keys == [], do: 0, else: Enum.count(o.keys, &Browser.JS.Obj.named_key?/1)

          o
          |> Map.update(:horder, [key], &[key | &1])
          |> Map.update(:hpos, %{key => named}, &Map.put_new(&1, key, named))
        end

      %{o | props: Map.put(o.props, key, v)}
    end
  end

  @doc false
  # A string key that is not an array index: an index comes first in the key order, so a
  # hidden key counts only the other names before it.
  def named_key?(k) do
    is_binary(k) and
      not (is_integer(Browser.JS.Interp.index(k)) and
             Browser.JS.Interp.index(k) < 4_294_967_295)
  end

  @doc """
  `o` with `key` set to `v` with the attributes `flags` (a map of `w`, `c` and `e`, stored
  as they are). The key does not go into the enumerable keys or into the hidden order.
  Built-ins use it for properties that are not enumerable (`@@toStringTag`, `prototype`).
  """
  defmacro put_with_attrs(o, key, v, flags) do
    quote bind_quoted: [o: o, key: key, v: v, flags: flags] do
      o
      |> Map.put(:props, Map.put(o.props, key, v))
      |> Map.put(:attrs, Map.put(Browser.JS.Obj.attr_map(o), key, flags))
    end
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
  attributes take no entry) and the enumerability `e`. A key that is not enumerable gets
  its place in the hidden order.
  """
  defmacro own_add(o, key, value, flags, e) do
    quote bind_quoted: [o: o, key: key, value: value, flags: flags, e: e] do
      attrs = Browser.JS.Obj.attr_map(o)

      attrs =
        if flags == %{c: true, w: true},
          do: Map.delete(attrs, key),
          else: Map.put(attrs, key, flags)

      keys = if e, do: [key | o.keys], else: o.keys

      o =
        if e do
          o
        else
          named = Enum.count(o.keys, &Browser.JS.Obj.named_key?/1)

          o
          |> Map.update(:horder, [key], &[key | &1])
          |> Map.update(:hpos, %{key => named}, &Map.put_new(&1, key, named))
        end

      o
      |> Map.put(:attrs, attrs)
      |> Map.put(:props, Map.put(o.props, key, value))
      |> Map.put(:keys, keys)
    end
  end

  @doc """
  `o` with the existing own property `key` changed by `defineProperty`: the stored value
  `value`, the attributes `flags` (`%{c, w}`) and the enumerability `e`. A key that
  becomes enumerable goes to the head of the enumerable keys.
  """
  defmacro own_redefine(o, key, value, flags, e) do
    quote bind_quoted: [o: o, key: key, value: value, flags: flags, e: e] do
      attrs = Browser.JS.Obj.attr_map(o)

      attrs =
        if flags == %{c: true, w: true},
          do: Map.delete(attrs, key),
          else: Map.put(attrs, key, flags)

      keys =
        cond do
          e and key in o.keys -> o.keys
          e -> [key | o.keys]
          true -> List.delete(o.keys, key)
        end

      o
      |> Map.put(:attrs, attrs)
      |> Map.put(:props, Map.put(o.props, key, value))
      |> Map.put(:keys, keys)
    end
  end

  @doc """
  `o` with `key` made a writable, enumerable and configurable data property with the value
  `v`, as a sloppy `eval` makes a global function. The record must have attributes.
  """
  defmacro reopen(o, key, v) do
    quote bind_quoted: [o: o, key: key, v: v] do
      attrs = Map.put(Browser.JS.Obj.attr_map(o), key, %{w: true, e: true, c: true})
      keys = if key in o.keys, do: o.keys, else: [key | o.keys]
      %{o | props: Map.put(o.props, key, v), attrs: attrs, keys: keys}
    end
  end

  @doc "`o` without the own key `key`: its value, its place and its attributes go."
  defmacro own_delete(o, key) do
    quote bind_quoted: [o: o, key: key] do
      attrs = Map.delete(Browser.JS.Obj.attr_map(o), key)

      %{o | props: Map.delete(o.props, key), keys: List.delete(o.keys, key)}
      |> Map.put(:attrs, attrs)
    end
  end

  @doc """
  `o` without the own key `key` and without its place in the enumerable keys. The
  attributes stay (a global function declaration replaces the property).
  """
  defmacro own_remove(o, key) do
    quote bind_quoted: [o: o, key: key] do
      %{o | props: Map.delete(o.props, key), keys: List.delete(o.keys, key)}
    end
  end

  @doc "`o` without the stored value of `key` (the `length` of an arguments object)."
  defmacro own_drop(o, key) do
    quote bind_quoted: [o: o, key: key] do
      %{o | props: Map.delete(o.props, key)}
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
