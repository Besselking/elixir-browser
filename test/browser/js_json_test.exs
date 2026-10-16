defmodule Browser.JSJsonTest do
  use ExUnit.Case, async: true

  alias Browser.JS.{Builtins, Interp, Json}

  # A string that JSON.parse gives must not point into the JSON text: the text can be large and
  # the script can keep the string for a long time.
  test "a long string from JSON.parse does not keep the JSON text" do
    Interp.init(1_000_000)
    Builtins.install()
    long = String.duplicate("abcdefghij", 10)
    text = ~s({"k":"#{long}","pad":"#{String.duplicate("z", 100_000)}"})
    v = Interp.get(Json.parse(text, :undefined), "k")
    assert v == long
    assert :binary.referenced_byte_size(v) == byte_size(long)
  end

  # A short string is one run that this code does not copy: the VM copies a short part of a
  # binary. If the VM changes this, this test fails.
  test "a short string or key from JSON.parse does not keep the JSON text" do
    Interp.init(1_000_000)
    Builtins.install()

    for n <- [1, 63, 64, 65] do
      s = String.duplicate("a", n)
      text = ~s({"#{s}":"#{s}","pad":"#{String.duplicate("z", 100_000)}"})
      o = Json.parse(text, :undefined)
      [key | _] = Interp.own_keys(o)
      v = Interp.get(o, s)
      assert v == s and key == s
      assert :binary.referenced_byte_size(v) == n
      assert :binary.referenced_byte_size(key) == n
    end
  end

  defp js(src) do
    {:ok, value, _console} = Browser.JS.eval(src)
    value
  end

  # The members of an object are collected first, and the object is made from them in one step.
  test "JSON.parse gives the keys in the order of the text, with the index keys first" do
    assert js(~S|Object.keys(JSON.parse('{"b":1,"a":2,"10":3,"1":4,"-1":5,"1.5":6}')).join()|) ==
             "1,10,b,a,-1,1.5"
  end

  test "a key that comes again in JSON keeps its first place and takes the last value" do
    assert js(~S|JSON.stringify(JSON.parse('{"b":1,"a":2,"b":3,"0":4,"0":5,"b":{"c":6}}'))|) ==
             ~s({"0":5,"b":{"c":6},"a":2})
  end

  test "a __proto__ key in JSON is an own data property, not the prototype" do
    assert js(~S"""
           var o = JSON.parse('{"__proto__":{"x":1},"y":2}');
           var d = Object.getOwnPropertyDescriptor(o, "__proto__");
           [Object.getPrototypeOf(o) === Object.prototype, o.x, d.value.x, d.writable,
            d.enumerable, d.configurable, Object.keys(o).join()].join()
           """) == "true,,1,true,true,true,__proto__,y"
  end

  test "an empty object in JSON is a plain object that a script can change" do
    assert js(~S"""
           var o = JSON.parse(' { } ');
           var n = JSON.parse('{"a":{},"b":[{}]}');
           o.x = 1;
           n.a.y = 2;
           [Array.isArray(o), Object.getPrototypeOf(o) === Object.prototype, Object.keys(o).join(),
            Array.isArray(n.a), Object.getPrototypeOf(n.b[0]) === Object.prototype,
            JSON.stringify(n)].join(" ")
           """) == ~s(false true x false true {"a":{"y":2},"b":[{}]})
  end

  test "a reviver sees the members of nested objects first, in the order of the text" do
    assert js(~S"""
           var log = [];
           var o = JSON.parse('{"b":{"c":1,"0":2},"a":"\\u0041\\n","1":3}', function (k, v) {
             log.push(k);
             return k === "c" ? undefined : v;
           });
           log.join() + " " + JSON.stringify(o)
           """) == ~s(1,0,c,b,a, {"1":3,"b":{"0":2},"a":"A\\n"})
  end
end
