defmodule Browser.JS.ObjTest.Api do
  # The API of `Browser.JS.Obj` as functions. Most of it is macros, and a macro that a test
  # calls with a literal record expands into code that the type checker can see through.
  # Here the arguments are not known, as in the interpreter.
  @moduledoc false
  require Browser.JS.Obj, as: Obj

  def record(fields, pairs), do: Map.merge(Obj.record([], pairs), Map.new(fields))
  def plain_record(fields, pairs), do: Map.merge(Obj.plain_record([], pairs), Map.new(fields))
  def has_own?(o, k), do: Obj.has_own?(o, k)
  def own_fetch(o, k), do: Obj.own_fetch(o, k)
  def own_value(o, k), do: Obj.own_value(o, k)
  def own_state(o, k), do: Obj.own_state(o, k)
  def own_update(o, k, v), do: Obj.own_update(o, k, v)
  def own_put_value(o, k, v), do: Obj.own_put_value(o, k, v)
  def enum_names(o), do: Obj.enum_names(o)
  def plain_names(o), do: Obj.plain_names(o)
  def element_enumerable?(o, i), do: Obj.element_enumerable?(o, i)
  def default_attrs?(o, k), do: Obj.default_attrs?(o, k)
  def writable?(o, k), do: Obj.writable?(o, k)
  def configurable?(o, k), do: Obj.configurable?(o, k)
  def extensible?(o), do: Obj.extensible?(o)
  def frozen?(o), do: Obj.frozen?(o)
  def sealed?(o), do: Obj.sealed?(o)
  def max_fixed_element(o, len), do: Obj.max_fixed_element(o, len)
  def own_add_assigned(o, k, v), do: Obj.own_add_assigned(o, k, v)
  def define_data(o, k, v), do: Obj.define_data(o, k, v)
  def put_hidden(o, k, v), do: Obj.put_hidden(o, k, v)
  def put_with_attrs(o, k, v, f), do: Obj.put_with_attrs(o, k, v, f)
  def put_attrs(o, k, f), do: Obj.put_attrs(o, k, f)
  def put_element_attrs(o, i, f), do: Obj.put_element_attrs(o, i, f)
  def own_add(o, k, v, f, e), do: Obj.own_add(o, k, v, f, e)
  def own_redefine(o, k, v, f, e), do: Obj.own_redefine(o, k, v, f, e)
  def own_delete(o, k), do: Obj.own_delete(o, k)
  def own_remove(o, k), do: Obj.own_remove(o, k)
  def prevent(o), do: Obj.prevent(o)
  def fill(o, layout, pairs), do: Obj.fill(o, layout, pairs)
  def attr_flags(o, k), do: Obj.attr_flags(o, k)
end

defmodule Browser.JS.ObjTest do
  # The record API of the own properties of a JS object (`Browser.JS.Obj`, data-model steps
  # A0a, A0b and A1). The first tests are the grep gate of the moduledoc of `Browser.JS.Obj`: only that
  # module names the own-property fields of a heap record. The other tests use the API on
  # records that no heap holds, so they run without `Interp.init/1`. They test what the API
  # gives (the states, the attributes, the key order), not the fields, so that a change of
  # the representation keeps them. Two records are compared by `Obj.normal/1`. The tests of
  # the API run two times: on dictionary records and on fast records (step A1), which must
  # give the same results.
  use ExUnit.Case, async: true

  require Browser.JS.Obj, as: Obj
  alias Browser.JS.ObjTest.Api

  @fields "props|keys|skeys|syms|attrs|ext|frozen|sealed|shape|vals"

  # The patterns of the grep command in the moduledoc of `Browser.JS.Obj`: `@gate` finds a
  # direct use, and `@allow` is the allow-list. Each is matched against
  # "path:line number:line", as grep prints it.
  @gate "(?<!Map|Object|Keyword|Reflect|prototype)\\.(#{@fields})\\b(?![?!(])" <>
          "|\\b(#{@fields}):|(?<![{\\w:]):(#{@fields})\\b"

  @allow String.trim(~S"""
         ^lib/browser/js/dom\.ex:\d+:.*((\bn|&1)\.(attrs|props)\b|node\(this_nid\(this\)\)\.attrs\b|\b(attrs|props): (\[\]|%\{\}|%\{"value"|visible\b|attrs\b|props\b)|%\{fields: [^}]*keys: )|^lib/browser/js/(collections|typed_arrays)\.ex:\d+:(\s*:keys ->|.*_iterator\(this, (:\w+, )?:keys\))|^lib/browser/js/collections\.ex:\d+:.*(has: has, keys: keys\}|call\(rec\.keys, rec\.obj, \[\]\))
         """)

  defp gate?(line), do: Regex.match?(Regex.compile!(@gate), line)
  defp allowed?(path, n, line), do: Regex.match?(Regex.compile!(@allow), "#{path}:#{n}:#{line}")

  test "the moduledoc gives the patterns of this test" do
    {:docs_v1, _, _, _, %{"en" => doc}, _, _} = Code.fetch_docs(Obj)
    assert doc =~ "grep -rnP '#{@gate}' lib/browser/js"
    assert doc =~ "grep -vP '#{@allow}'"
  end

  test "only obj.ex names the own-property fields of a record" do
    hits =
      for path <- Path.wildcard("lib/browser/js/**/*.ex"),
          path != "lib/browser/js/obj.ex",
          {line, n} <- path |> File.read!() |> String.split("\n") |> Enum.with_index(1),
          not (line =~ ~r/^\s*#/),
          gate?(line),
          not allowed?(path, n, line),
          do: "#{path}:#{n}: #{String.trim(line)}"

    assert hits == []
  end

  test "the gate finds the forms of a direct field use" do
    for line <- [
          "o.props",
          "%{o | keys: [k | o.keys]}",
          "Map.get(o, :attrs, %{})",
          "Map.get(deref(id), :ext, true)",
          "|> Map.update(:skeys, [key], &[key | &1])",
          "Map.get(o, :syms, [])",
          "is_map_key(o, :frozen)",
          ":erlang.map_get(:sealed, o)",
          "        :attrs,",
          ":maps.get(:props, o)",
          "Map.take(o, [:class, :props])",
          "o.ext",
          "o.frozen and o.sealed",
          ":maps.put(:keys, [], o)",
          "Map.get(o,:attrs)",
          "Map.get(o, :proto) || Map.get(o, :props)",
          "Access.key(:props) && o",
          "o.skeys"
        ],
        do: assert(gate?(line), line)

    for line <- [
          "Map.keys(m)",
          "Object.keys(o)",
          "Headers.prototype.keys = f",
          "x.keys()",
          "Obj.frozen?(o)",
          "Obj.extensible?(o)",
          "{:ext, v}",
          "Path.extname(p)"
        ],
        do: refute(gate?(line), line)

    # (the allow-list of dom.ex takes the node forms, not a heap record)
    dom = "lib/browser/js/dom.ex"
    assert allowed?(dom, 1, "    case n.props do")
    assert allowed?(dom, 1, "  update_node(nid, &%{&1 | props: Map.put(&1.props, \"open\", v)})")
    refute allowed?(dom, 1, "    o = deref(id); o.props")
    refute allowed?(dom, 1, "    Map.get(deref(id), :attrs)")
    refute allowed?("lib/browser/js/interp.ex", 1, "    case n.props do")
  end

  # The two forms of a record. `:dict` makes dictionary records, `:fast` makes fast records
  # (the switch `:js_shapes` is on in a process that did not set it).
  defp plain(mode, pairs), do: plain_in(mode, [class: :object, proto: nil], pairs)
  defp plain_in(:dict, fields, pairs), do: Api.record(fields, pairs)
  defp plain_in(:fast, fields, pairs), do: Api.plain_record(fields, pairs)

  for mode <- [:dict, :fast] do
    describe "#{mode} records" do
      @mode mode

      test "a new record has the given properties, enumerable, in creation order" do
        o = plain(@mode, [{"b", 3}, {"a", 2}])
        assert Api.has_own?(o, "a") and Api.has_own?(o, "b")
        refute Api.has_own?(o, "c")
        assert Api.own_fetch(o, "b") == {:ok, 3}
        assert Api.own_fetch(o, "c") == :error
        assert Api.own_value(o, "a") == 2
        assert Api.own_value(o, "c") == nil
        assert Api.own_state(o, "a") == {:data, 2, true, true, true}
        assert Api.own_state(o, "c") == nil
        assert Api.extensible?(o)
        refute Api.frozen?(o) or Api.sealed?(o)
        assert Api.enum_names(o) == ["b", "a"]
        assert Api.plain_names(o) == ["b", "a"]
        assert Obj.string_keys(o) == ["b", "a"]
        assert Obj.symbol_keys(o) == []
        assert Obj.normal(Obj.record(class: :object, proto: nil)) == Obj.normal(plain(@mode, []))

        # (the normal form tells an object that is not extensible, and the symbols)
        refute Obj.normal(o) == Obj.normal(Api.prevent(o))
        refute Obj.normal(o) == Obj.normal(Api.own_add_assigned(o, {:symbol, 1, "s"}, 1))
      end

      test "own_case matches an own value, an accessor and a missing key" do
        o = plain(@mode, [{"a", 1}, {"g", {:accessor, :get, :undefined}}])

        read = fn o, key ->
          Obj.own_case o, key do
            {:ok, {:accessor, g, _}} -> {:getter, g}
            {:ok, v} when is_integer(v) -> {:int, v}
            {:ok, v} -> {:other, v}
            :error -> :missing
          end
        end

        assert read.(o, "a") == {:int, 1}
        assert read.(o, "g") == {:getter, :get}
        assert read.(o, "zz") == :missing
        assert read.(Api.own_update(o, "a", "x"), "a") == {:other, "x"}

        # (a key that is an expression is computed once)
        k = fn ->
          send(self(), :key)
          "a"
        end

        got =
          Obj.own_case o, k.() do
            {:ok, v} -> v
            :error -> nil
          end

        assert got == 1
        assert_received :key
        refute_received :key
      end

      test "own_case refuses an :error clause that can match a record with the key" do
        # (with the accessor clause alone before it, `:error` would also match the data
        # property "a")
        code = """
        require Browser.JS.Obj, as: Obj

        Obj.own_case o, "a" do
          {:ok, {:accessor, _, _}} -> :accessor
          :error -> :missing
        end
        """

        assert_raise ArgumentError, ~r/own_case: an :error clause/, fn ->
          Code.eval_string(code, o: plain(@mode, [{"a", 1}]))
        end

        # (after a guarded clause too, but not after `{:ok, _}`)
        guarded = String.replace(code, "{:accessor, _, _}}", "v} when v == 1")

        assert_raise ArgumentError, fn ->
          Code.eval_string(guarded, o: plain(@mode, [{"a", 1}]))
        end

        fine = String.replace(code, "{:accessor, _, _}}", "_}")
        assert {:accessor, _} = Code.eval_string(fine, o: plain(@mode, [{"a", 1}]))
        assert {:missing, _} = Code.eval_string(fine, o: plain(@mode, []))
      end

      test "an assignment adds an enumerable key, a string or a symbol" do
        sym = {:symbol, 1, "s"}
        o = plain(@mode, [{"a", 1}]) |> Api.own_add_assigned("b", 2)
        assert Api.own_state(o, "b") == {:data, 2, true, true, true}
        assert Api.plain_names(o) == ["a", "b"]
        o = Api.own_add_assigned(o, sym, 3)
        assert Api.own_state(o, sym) == {:data, 3, true, true, true}
        assert Api.enum_names(o) == ["a", "b"]
        assert Obj.string_keys(o) == ["a", "b"]

        # (a symbol among the enumerable keys is no plain name)
        assert Api.plain_names(o) == nil
        o = Obj.own_add(o, {:symbol, 2, "t"}, 4, %{c: true, w: true}, true)
        assert Api.enum_names(o) == ["a", "b"]
        assert Api.own_state(o, {:symbol, 2, "t"}) == {:data, 4, true, true, true}
        assert Api.writable?(o, "b") and Api.configurable?(o, "b")
      end

      test "the symbols come in creation order, not in term order" do
        late = {:symbol, 9, "late"}
        early = {:symbol, 1, "early"}

        o =
          plain(@mode, [])
          |> Api.own_add_assigned(late, 1)
          |> Api.define_data("a", 2)
          |> Api.put_hidden(early, 3)
          |> Api.define_data({:symbol, 5, "five"}, 4)

        assert Obj.symbol_keys(o) == [late, early, {:symbol, 5, "five"}]
        assert Obj.string_keys(o) == ["a"]
        assert Api.own_state(o, early) == {:data, 3, true, false, true}
        assert Api.own_state(o, {:symbol, 5, "five"}) == {:data, 4, true, true, true}

        # (a record with a symbol among its pairs)
        r = plain(@mode, [{"b", 1}, {late, 2}, {"a", 3}])
        assert Obj.string_keys(r) == ["b", "a"] and Obj.symbol_keys(r) == [late]
        assert Api.own_state(r, late) == {:data, 2, true, true, true}
      end

      test "defineProperty adds and changes keys; each key keeps its place" do
        o =
          plain(@mode, [{"a", 1}])
          |> Obj.own_add("h", 2, %{c: false, w: false}, false)
          |> Obj.own_add("b", 3, %{c: true, w: true}, true)

        assert Api.own_state(o, "h") == {:data, 2, false, false, false}
        refute Api.writable?(o, "h") or Api.configurable?(o, "h")
        refute Api.default_attrs?(o, "h")
        assert Api.own_state(o, "b") == {:data, 3, true, true, true}
        assert Api.default_attrs?(o, "b")
        refute o |> Obj.own_add("nc", 4, %{c: false, w: true}, true) |> Api.default_attrs?("nc")
        assert Api.enum_names(o) == ["a", "b"]
        assert Obj.string_keys(o) == ["a", "h", "b"]

        # (a key that becomes enumerable again goes back to its place)
        o = Obj.own_redefine(o, "h", 2, %{c: false, w: false}, true)
        assert Api.own_state(o, "h") == {:data, 2, false, true, false}
        assert Api.enum_names(o) == ["a", "h", "b"]
        o = Obj.own_redefine(o, "a", 1, %{c: true, w: true}, false)
        assert Api.own_state(o, "a") == {:data, 1, true, false, true}
        assert Api.enum_names(o) == ["h", "b"]
        assert Obj.string_keys(o) == ["a", "h", "b"]
        o = Obj.own_redefine(o, "a", 1, %{c: true, w: true}, true)
        assert Api.enum_names(o) == ["a", "h", "b"]

        # (a symbol keeps its place when its enumerability changes)
        s1 = {:symbol, 1, "s1"}
        s2 = {:symbol, 2, "s2"}
        o = o |> Obj.own_add(s1, 1, %{c: true, w: true}, false) |> Api.own_add_assigned(s2, 2)
        o = Obj.own_redefine(o, s1, 1, %{c: true, w: true}, true)
        assert Api.own_state(o, s1) == {:data, 1, true, true, true}
        o = Obj.own_redefine(o, s2, 2, %{c: true, w: false}, false)
        assert Api.own_state(o, s2) == {:data, 2, false, false, true}
        assert Obj.symbol_keys(o) == [s1, s2]
      end

      test "a hidden key has its place in the order of all string keys" do
        o =
          plain(@mode, [{"a", 1}, {"0", 2}]) |> Api.put_hidden("h", 3) |> Api.define_data("b", 4)

        assert Api.own_state(o, "h") == {:data, 3, true, false, true}
        assert Obj.string_keys(o) == ["a", "0", "h", "b"]
        assert Api.enum_names(o) == ["a", "0", "b"]
        assert Api.plain_names(o) == nil

        # (a hidden write to an existing key keeps the key enumerable)
        assert o |> Api.put_hidden("a", 5) |> Api.own_state("a") == {:data, 5, true, true, true}

        # (a key that the record does not hold yet, as the `name` of a function, goes to the end)
        o = Obj.own_redefine(o, "name", "f", %{c: true, w: false}, false)
        assert Obj.string_keys(o) == ["a", "0", "h", "b", "name"]

        # (put_with_attrs/4 on an existing key keeps its enumerability; the record has no
        # index-like key, so that it stays fast in the fast mode)
        o =
          plain(@mode, [{"a", 1}, {"b", 2}])
          |> Api.put_hidden("h", 3)
          |> Obj.own_redefine("name", "f", %{c: true, w: false}, false)

        assert Obj.fast?(o) == (@mode == :fast)

        assert o |> Api.put_with_attrs("h", 6, %{w: false, c: true}) |> Api.own_state("h") ==
                 {:data, 6, false, false, true}

        assert o |> Api.put_with_attrs("b", 7, %{w: false, c: true}) |> Api.own_state("b") ==
                 {:data, 7, false, true, true}

        # (reopen/3, as a sloppy `eval` makes a global function, makes the key a default
        # data property in its place)
        r = Obj.reopen(o, "name", "g")
        assert Api.own_state(r, "name") == {:data, "g", true, true, true}
        assert Api.enum_names(r) == ["a", "b", "name"]
        assert Obj.string_keys(r) == ["a", "b", "h", "name"]

        # (a hidden symbol does not stop the plain names, also after a change of attributes)
        p =
          plain(@mode, [{"a", 1}])
          |> Api.put_hidden({:symbol, 1, "s"}, 2)
          |> Api.put_attrs("a", %{w: false, c: true})

        assert Api.plain_names(p) == ["a"]
      end

      test "a key that is deleted and made again goes to the end" do
        sym = {:symbol, 1, "s"}

        o =
          plain(@mode, [{"a", 1}, {"b", 2}])
          |> Api.put_hidden("h", 3)
          |> Api.own_add_assigned(sym, 4)
          |> Api.own_add_assigned({:symbol, 2, "t"}, 5)

        o = o |> Api.own_delete("a") |> Api.own_delete("h") |> Api.own_delete(sym)
        assert Obj.string_keys(o) == ["b"] and Api.enum_names(o) == ["b"]
        assert Obj.symbol_keys(o) == [{:symbol, 2, "t"}]

        o = o |> Api.own_add_assigned("h", 6) |> Api.own_add_assigned("a", 7)
        o = Api.own_add_assigned(o, sym, 8)
        assert Obj.string_keys(o) == ["b", "h", "a"] and Api.enum_names(o) == ["b", "h", "a"]
        assert Obj.symbol_keys(o) == [{:symbol, 2, "t"}, sym]
        assert Api.own_state(o, "h") == {:data, 6, true, true, true}

        # (the record holds the same as one that never had the hidden key)
        same = plain(@mode, [{"b", 2}, {"h", 6}, {"a", 7}])

        assert Obj.normal(Api.own_delete(Api.own_delete(o, sym), {:symbol, 2, "t"})) ==
                 Obj.normal(same)

        # (the shadow run gives `nil` when it has no record)
        assert Obj.normal(nil) == nil

        refute Api.has_own?(Api.own_remove(o, "a"), "a")
        assert Obj.string_keys(Api.own_remove(o, "a")) == ["b", "h"]

        # (the attributes of a deleted key go: a key that was read-only and is made again by
        # an assignment has the default attributes. "a" is not the last key, so a fast
        # record goes to dictionary mode)
        r =
          plain(@mode, [{"a", 1}, {"b", 2}])
          |> Api.put_attrs("a", %{w: false, c: true})
          |> Api.own_delete("a")
          |> Api.own_add_assigned("a", 5)

        assert Api.own_state(r, "a") == {:data, 5, true, true, true}
        assert Api.writable?(r, "a") and Api.default_attrs?(r, "a")
      end

      test "built-in attributes, freeze and seal" do
        tag = {:symbol, :toStringTag, "Symbol.toStringTag"}

        o =
          plain(@mode, [{"a", 1}]) |> Api.put_with_attrs(tag, "T", %{w: false, c: true, e: false})

        assert Api.own_state(o, tag) == {:data, "T", false, false, true}
        assert Obj.symbol_keys(o) == [tag]

        assert o |> Api.put_attrs("a", %{w: false, c: true}) |> Api.own_state("a") ==
                 {:data, 1, false, true, true}

        # (a new string key with `e: true` is enumerable, one without it is hidden)
        o2 =
          o
          |> Api.put_with_attrs("raw", 2, %{w: false, c: false, e: true})
          |> Api.put_with_attrs("p", 3, %{w: true, c: false, e: false})

        assert Api.enum_names(o2) == ["a", "raw"]
        assert Obj.string_keys(o2) == ["a", "raw", "p"]

        refute o |> Api.prevent() |> Api.extensible?()
        frozen = Obj.lock(o, true)
        assert Obj.locked?(frozen, true) and Obj.locked?(frozen, false)
        sealed = Obj.lock(o, false)
        assert Obj.locked?(sealed, false)
        refute Obj.locked?(sealed, true)
        refute Obj.locked?(o, false)

        # (an enumerable symbol stays enumerable when the object is frozen or when its
        # attributes change)
        sym = {:symbol, 1, "s"}
        s = Api.own_add_assigned(o, sym, 1)
        assert Api.own_state(Obj.lock(s, true), sym) == {:data, 1, false, true, false}

        assert Api.own_state(Api.put_attrs(s, sym, %{w: false, c: true}), sym) ==
                 {:data, 1, false, true, true}

        # (an accessor becomes not configurable; a private name keeps its attributes)
        priv = {:private, make_ref()}

        a =
          o
          |> Obj.own_add("g", {:accessor, :get, :undefined}, %{c: true, w: true}, true)
          |> Api.own_put_value(priv, 2)

        frozen = Obj.lock(a, true)
        assert Api.own_state(frozen, "g") == {:accessor, :get, :undefined, true, false}
        assert Api.own_state(frozen, priv) == {:data, 2, true, false, true}
        assert Obj.locked?(frozen, true)

        assert Api.own_state(Obj.lock(a, false), "g") ==
                 {:accessor, :get, :undefined, true, false}
      end

      test "a literal fills an empty record in one write, as define_data/3 one key at a time" do
        layout = Obj.literal_keys(["a", "b", "a"])
        o = Api.fill(plain(@mode, []), layout, [1, 2, 3])

        one_by_one =
          plain(@mode, [])
          |> Api.define_data("a", 1)
          |> Api.define_data("b", 2)
          |> Api.define_data("a", 3)

        assert Obj.normal(o) == Obj.normal(one_by_one)
        assert Api.enum_names(o) == ["a", "b"]
        assert Obj.fast?(o) == (@mode == :fast)

        assert Api.own_value(o, "a") == 3

        # (with no key two times, and with a key that a fast record cannot hold)
        layout = Obj.literal_keys(["a", "b"])

        assert Obj.normal(Api.fill(plain(@mode, []), layout, [1, 2])) ==
                 Obj.normal(plain(@mode, [{"a", 1}, {"b", 2}]))

        layout = Obj.literal_keys(["a", "0"])
        o = Api.fill(plain(@mode, []), layout, [1, 2])
        assert Obj.normal(o) == Obj.normal(plain(@mode, [{"a", 1}, {"0", 2}]))
        assert Obj.string_keys(o) == ["a", "0"]
      end
    end
  end

  test "to_dict/1 gives the record that the writers make for a dictionary record" do
    sym = {:symbol, 1, "s"}
    hid = {:symbol, 2, "h"}
    priv = {:private, make_ref()}

    make = fn mode ->
      plain(mode, [{"a", 1}, {"b", 2}])
      |> Api.own_add_assigned(sym, 3)
      |> Api.put_hidden(hid, 4)
      |> Obj.own_add("ro", 5, %{c: true, w: false}, true)
      |> Obj.own_add("nc", 6, %{c: false, w: true}, true)
      |> Api.put_hidden("hid", 7)
      |> Obj.own_add("g", {:accessor, :get, :undefined}, %{c: true, w: true}, true)
      |> Api.own_put_value(priv, 8)
    end

    # (the first record makes nine new shapes in a row, so it goes to dictionary mode at
    # the last key; the second record finds the chain in the table)
    refute Obj.fast?(make.(:fast))
    o = make.(:fast)
    assert Obj.fast?(o)
    d = Obj.to_dict(o)
    refute Obj.fast?(d)
    assert Obj.normal(d) == Obj.normal(o)
    assert d == make.(:dict)
    assert Obj.to_dict(Api.prevent(o)) == Api.prevent(make.(:dict))
    assert Obj.to_dict(d) == d

    # (the usual record: string keys with the default attributes)
    u = plain(:fast, [{"a", 1}, {"b", 2}])
    assert Obj.to_dict(u) == plain(:dict, [{"a", 1}, {"b", 2}])
    assert Obj.to_dict(plain(:fast, [])) == plain(:dict, [])
  end

  test "a fast record with a key two times in its pairs gets the last value" do
    o = plain(:fast, [{"a", 1}, {"b", 2}, {"a", 3}])
    assert Api.own_value(o, "a") == 3 and Api.enum_names(o) == ["a", "b"]
  end

  test "attr_flags/2 gives the attributes of a key of a fast record" do
    o =
      plain(:fast, [{"a", 1}, {"b", 2}])
      |> Obj.own_redefine("a", 1, %{c: true, w: false}, false)

    assert Api.attr_flags(o, "a") == %{w: false, c: true, e: false}
    assert Api.attr_flags(o, "b") == %{w: true, c: true, e: true}
    assert Api.attr_flags(o, "zz") == %{}
  end

  test "element attributes and the stop of a shrink" do
    a = Api.record([class: :array, proto: nil], []) |> Browser.JS.Elems.put_args([1, 2, 3])
    assert Api.max_fixed_element(a, 0) == nil
    a = Api.put_element_attrs(a, 1, %{w: true, c: false, e: true})
    assert Api.max_fixed_element(a, 0) == 1
    assert Api.max_fixed_element(a, 2) == nil
    refute Api.configurable?(a, 1)
    assert Api.element_enumerable?(a, 1) and Api.element_enumerable?(a, 0)

    refute a
           |> Api.put_element_attrs(2, %{w: true, c: true, e: false})
           |> Api.element_enumerable?(2)

    assert Api.writable?(a, 1)
    refute Api.default_attrs?(a, 1)
    assert Api.default_attrs?(a, 0)
    a = Api.put_element_attrs(a, 1, %{w: true, c: true, e: true})
    assert Api.configurable?(a, 1) and Api.default_attrs?(a, 1)
    assert Api.max_fixed_element(a, 0) == nil
    a = Obj.lock(a, true)
    assert Api.frozen?(a) and not Api.sealed?(a)
  end
end
