defmodule Browser.JS.ObjTest.Api do
  # The API of `Browser.JS.Obj` as functions. Most of it is macros, and a macro that a test
  # calls with a literal record expands into code that the type checker can see through.
  # Here the arguments are not known, as in the interpreter.
  @moduledoc false
  require Browser.JS.Obj, as: Obj

  def record(fields, pairs), do: Map.merge(Obj.record([], pairs), Map.new(fields))
  def has_own?(o, k), do: Obj.has_own?(o, k)
  def own_fetch(o, k), do: Obj.own_fetch(o, k)
  def own_value(o, k), do: Obj.own_value(o, k)
  def own_state(o, k), do: Obj.own_state(o, k)
  def own_update(o, k, v), do: Obj.own_update(o, k, v)
  def enum_names(o), do: Obj.enum_names(o)
  def plain_names(o), do: Obj.plain_names(o)
  def element_enumerable?(o, i), do: Obj.element_enumerable?(o, i)
  def attr_map(o), do: Obj.attr_map(o)
  def attr_flags(o, k), do: Obj.attr_flags(o, k)
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
  def own_drop(o, k), do: Obj.own_drop(o, k)
  def prevent(o), do: Obj.prevent(o)
  def fill(o, layout, pairs), do: Obj.fill(o, layout, pairs)
end

defmodule Browser.JS.ObjTest do
  # The record API of the own properties of a JS object (`Browser.JS.Obj`, data-model step
  # A0a). The first test is the grep gate of the moduledoc of `Browser.JS.Obj`: only that
  # module names the own-property fields of a heap record. The other tests use the API on
  # records that no heap holds, so they run without `Interp.init/1`. They test what the API
  # gives, not the fields, so that a change of the representation keeps them.
  use ExUnit.Case, async: true

  require Browser.JS.Obj, as: Obj
  alias Browser.JS.ObjTest.Api

  @fields "props|keys|attrs|horder|hpos|ext|frozen|sealed"

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
          "|> Map.update(:horder, [key], &[key | &1])",
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
          "o.hpos[k]"
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

  defp plain(pairs \\ []), do: Api.record([class: :object, proto: nil], pairs)

  test "a new record has the given properties, enumerable, in creation order" do
    o = plain([{"b", 3}, {"a", 2}])
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
    assert Obj.own_names(o, []) == {[], ["b", "a"]}
    assert Obj.record(class: :object, proto: nil) == plain()
  end

  test "own_case matches an own value, an accessor and a missing key" do
    o = plain([{"a", 1}, {"g", {:accessor, :get, :undefined}}])

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
      Code.eval_string(code, o: plain([{"a", 1}]))
    end

    # (after a guarded clause too, but not after `{:ok, _}`)
    guarded = String.replace(code, "{:accessor, _, _}}", "v} when v == 1")
    assert_raise ArgumentError, fn -> Code.eval_string(guarded, o: plain([{"a", 1}])) end
    fine = String.replace(code, "{:accessor, _, _}}", "_}")
    assert {:accessor, _} = Code.eval_string(fine, o: plain([{"a", 1}]))
    assert {:missing, _} = Code.eval_string(fine, o: plain())
  end

  test "an assignment adds an enumerable key; a symbol is enumerable by its attributes" do
    sym = {:symbol, 1, "s"}
    o = plain([{"a", 1}]) |> Api.own_add_assigned("b", 2) |> Api.own_add_assigned(sym, 3)
    assert Api.own_state(o, "b") == {:data, 2, true, true, true}
    assert Api.own_state(o, sym) == {:data, 3, true, true, true}
    assert Api.enum_names(o) == ["a", "b"]
    assert Api.plain_names(o) == ["a", "b"]

    # (a symbol that defineProperty makes enumerable is no plain name)
    o = Api.own_add(o, {:symbol, 2, "t"}, 4, %{c: true, w: true}, true)
    assert Api.enum_names(o) == ["a", "b"]
    assert Api.plain_names(o) == nil
    assert Api.writable?(o, "b") and Api.configurable?(o, "b")
  end

  test "defineProperty adds and changes keys with their attributes and order" do
    o =
      plain([{"a", 1}])
      |> Api.own_add("h", 2, %{c: false, w: false}, false)
      |> Api.own_add("b", 3, %{c: true, w: true}, true)

    assert Api.own_state(o, "h") == {:data, 2, false, false, false}
    refute Api.writable?(o, "h") or Api.configurable?(o, "h")
    assert Api.attr_flags(o, "h") == %{c: false, w: false}
    assert Api.attr_flags(o, "b") == %{}
    assert Obj.split_names(o) == {["a", "b"], ["h"]}
    assert Obj.own_names(o, []) == {[], ["a", "h", "b"]}
    assert Obj.own_names(o, ["h"]) == {[], ["a", "b"]}

    o = Api.own_redefine(o, "h", 2, %{c: false, w: false}, true)
    assert Api.own_state(o, "h") == {:data, 2, false, true, false}
    o = Api.own_redefine(o, "a", 1, %{c: true, w: true}, false)
    assert Api.own_state(o, "a") == {:data, 1, true, false, true}
  end

  test "a hidden key keeps its place among the enumerable names" do
    o = plain([{"a", 1}, {"0", 2}]) |> Api.put_hidden("h", 3) |> Api.define_data("b", 4)
    assert Api.own_state(o, "h") == {:data, 3, true, false, true}
    assert Obj.own_names(o, []) == {["0"], ["a", "h", "b"]}
    assert Api.enum_names(o) == ["a", "0", "b"]
    assert Api.plain_names(o) == nil

    # (a hidden write to an existing key keeps the key enumerable)
    assert o |> Api.put_hidden("a", 5) |> Api.own_state("a") == {:data, 5, true, true, true}
  end

  test "built-in attributes, delete, freeze and seal" do
    tag = {:symbol, :toStringTag, "Symbol.toStringTag"}
    o = plain([{"a", 1}]) |> Api.put_with_attrs(tag, "T", %{w: false, c: true, e: false})
    assert Api.own_state(o, tag) == {:data, "T", false, false, true}

    assert o |> Api.put_attrs("a", %{w: false, c: true}) |> Api.own_state("a") ==
             {:data, 1, false, true, true}

    d = Api.own_delete(o, "a")
    refute Api.has_own?(d, "a")
    assert Api.enum_names(d) == []
    refute Api.has_own?(Api.own_remove(o, "a"), "a")
    refute Api.has_own?(Api.own_drop(o, "a"), "a")

    refute o |> Api.prevent() |> Api.extensible?()
    frozen = Obj.lock(o, true)
    assert Obj.locked?(frozen, true) and Obj.locked?(frozen, false)
    sealed = Obj.lock(o, false)
    assert Obj.locked?(sealed, false)
    refute Obj.locked?(sealed, true)
    refute Obj.locked?(o, false)
  end

  test "element attributes and the stop of a shrink" do
    a = Api.record([class: :array, items: %{0 => 1, 1 => 2, 2 => 3}, len: 3, proto: nil], [])
    assert Api.max_fixed_element(a, 0) == nil
    a = Api.put_element_attrs(a, 1, %{w: true, c: false, e: true})
    assert Api.max_fixed_element(a, 0) == 1
    assert Api.max_fixed_element(a, 2) == nil
    refute Api.configurable?(a, 1)
    assert Api.element_enumerable?(a, 1) and Api.element_enumerable?(a, 0)

    refute a
           |> Api.put_element_attrs(2, %{w: true, c: true, e: false})
           |> Api.element_enumerable?(2)

    assert Api.attr_map(a) == %{1 => %{w: true, c: false, e: true}}
    a = Api.put_element_attrs(a, 1, %{w: true, c: true, e: true})
    assert Api.attr_map(a) == %{}
    a = Obj.lock(a, true)
    assert Api.frozen?(a) and not Api.sealed?(a)
  end

  test "a literal fills an empty record in one write, as define_data/3 one key at a time" do
    layout = Obj.literal_keys(["a", "b", "a"])
    o = Api.fill(plain(), layout, [{"a", 1}, {"b", 2}, {"a", 3}])

    assert o ==
             plain()
             |> Api.define_data("a", 1)
             |> Api.define_data("b", 2)
             |> Api.define_data("a", 3)

    assert Api.own_value(o, "a") == 3
  end
end
