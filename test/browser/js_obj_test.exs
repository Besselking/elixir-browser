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
  def enum_rev(o), do: Obj.enum_rev(o)
  def attr_map(o), do: Obj.attr_map(o)
  def attr_flags(o, k), do: Obj.attr_flags(o, k)
  def writable?(o, k), do: Obj.writable?(o, k)
  def configurable?(o, k), do: Obj.configurable?(o, k)
  def extensible?(o), do: Obj.extensible?(o)
  def frozen?(o), do: Obj.frozen?(o)
  def sealed?(o), do: Obj.sealed?(o)
  def name_lists(o), do: Obj.name_lists(o)
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

  @fields "props|keys|attrs|horder|hpos"
  @flags "props|keys|attrs|horder|hpos|ext|frozen|sealed"

  # (the regular expression of the grep command in the moduledoc of `Browser.JS.Obj`)
  @gate Regex.compile!(
          "(?<!Map|Object|Keyword|Reflect|prototype)\\.(#{@fields})\\b(?!\\()" <>
            "|\\b(#{@flags}):" <>
            "|Map\\.\\w+[?!]?\\((?:[^,]*, )?:(#{@flags})\\b" <>
            "|(is_map_key\\([^,]+, |map_get\\(|\\[):(#{@flags})\\b" <>
            "|^\\s+:(#{@flags}),?\\s*$"
        )

  # The allow-list of the moduledoc: the DOM nodes of `dom.ex`, and the record of
  # GetSetRecord in `collections.ex`. Neither is a heap record of an object.
  defp allowed?("lib/browser/js/dom.ex", _line), do: true

  defp allowed?("lib/browser/js/collections.ex", line),
    do: line =~ "has: has, keys: keys}" or line =~ "call(rec.keys, rec.obj, [])"

  defp allowed?(_, _), do: false

  test "only obj.ex names the own-property fields of a record" do
    hits =
      for path <- Path.wildcard("lib/browser/js/**/*.ex"),
          path != "lib/browser/js/obj.ex",
          {line, n} <- path |> File.read!() |> String.split("\n") |> Enum.with_index(1),
          not (line =~ ~r/^\s*#/),
          Regex.match?(@gate, line),
          not allowed?(path, line),
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
          "        :attrs,"
        ],
        do: assert(Regex.match?(@gate, line), line)

    for line <- ["Map.keys(m)", "Object.keys(o)", "Headers.prototype.keys = f", "x.keys()"],
        do: refute(Regex.match?(@gate, line), line)
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
    assert {["b", "a"], [], []} == Api.name_lists(o)
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

  test "an assignment adds an enumerable key; a symbol is enumerable by its attributes" do
    sym = {:symbol, 1, "s"}
    o = plain([{"a", 1}]) |> Api.own_add_assigned("b", 2) |> Api.own_add_assigned(sym, 3)
    assert Api.own_state(o, "b") == {:data, 2, true, true, true}
    assert Api.own_state(o, sym) == {:data, 3, true, true, true}
    assert Api.enum_rev(o) == ["b", "a"]
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
    {base, hidden, ordered} = Api.name_lists(o)
    assert {base, hidden, ordered} == {["a", "b"], ["h"], ["h"]}
    assert Obj.interleave(base, ordered, o, hidden) == ["a", "h", "b"]

    o = Api.own_redefine(o, "h", 2, %{c: false, w: false}, true)
    assert Api.own_state(o, "h") == {:data, 2, false, true, false}
    o = Api.own_redefine(o, "a", 1, %{c: true, w: true}, false)
    assert Api.own_state(o, "a") == {:data, 1, true, false, true}
  end

  test "a hidden key keeps its place among the enumerable names" do
    o = plain([{"a", 1}, {"0", 2}]) |> Api.put_hidden("h", 3) |> Api.define_data("b", 4)
    assert Api.own_state(o, "h") == {:data, 3, true, false, true}
    {base, hidden, ordered} = Api.name_lists(o)
    assert Obj.interleave(base -- ["0"], ordered, o, hidden) == ["a", "h", "b"]

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
    assert Api.enum_rev(d) == []
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
