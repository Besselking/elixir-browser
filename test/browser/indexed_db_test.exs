defmodule Browser.IndexedDBTest do
  use ExUnit.Case, async: true
  alias Browser.IndexedDB, as: DB

  @schema []
  @one_store [["s", ~s({"n":"s","k":null,"a":false,"g":1}), []]]

  # a store of its own, so tests don't share databases (or the one in the application)
  defp store(opts \\ []) do
    name = :"idb_#{System.unique_integer([:positive])}"
    {:ok, pid} = DB.start_link(Keyword.merge([name: name, path: nil], opts))
    {name, pid}
  end

  # a process that holds connections, and reports the messages it gets
  defp page(parent) do
    spawn_link(fn -> relay(parent) end)
  end

  defp relay(parent) do
    receive do
      {:call, from, fun} ->
        send(from, {:result, fun.()})
        relay(parent)

      msg ->
        send(parent, {:got, self(), msg})
        relay(parent)
    end
  end

  defp as(page, fun) do
    send(page, {:call, self(), fun})
    assert_receive {:result, result}
    result
  end

  test "databases are kept per origin and name" do
    {s, _} = store()
    assert DB.load("http://a.test", "d", nil, s) == :none
    rev = DB.save("http://a.test", "d", 3, @schema, [], s)
    assert DB.load("http://a.test", "d", nil, s) == {:ok, rev, 3, ~s({"v":3,"s":[]})}
    assert DB.load("http://a.test", "d", rev, s) == :same
    assert DB.load("http://b.test", "d", nil, s) == :none
    assert DB.names("http://a.test", s) == [{"d", 3}]
    assert DB.save("http://a.test", "d", 3, @schema, [], s) == rev + 1
    DB.delete("http://a.test", "d", s)
    assert DB.load("http://a.test", "d", nil, s) == :none
    assert DB.names("http://a.test", s) == []
  end

  test "a database that is too big is refused" do
    {s, _} = store()
    big = String.duplicate("x", 257 * 1024 * 1024)
    assert DB.save("http://a.test", "d", 1, @one_store, [["p", "s", "1", big]], s) == :quota
  end

  test "databases are written to disk, and read again" do
    path = Path.join(System.tmp_dir!(), "idb_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(path) end)
    {s, _} = store(path: path)
    DB.save("http://a.test", "d", 2, @one_store, [["p", "s", "1", ~s("x")]], s)
    DB.save("opaque:#PID<0.1.0>", "mem", 1, @schema, [], s)
    DB.flush(s)
    assert length(File.ls!(path)) == 1
    {s2, _} = store(path: path)
    assert DB.names("http://a.test", s2) == [{"d", 2}]
    assert {:ok, _, 2, text} = DB.load("http://a.test", "d", nil, s2)
    assert JSON.decode!(text)["s"] |> hd() |> Map.get("r") == [[1, "x"]]
    assert DB.names("opaque:#PID<0.1.0>", s2) == []
  end

  test "operations change records and indexes, and the records come back sorted by key" do
    {s, _} = store()
    o = "http://a.test"

    schema = [
      [
        "s",
        ~s({"n":"s","k":null,"a":false,"g":1}),
        [["i", ~s({"n":"i","k":"x","u":false,"m":false})]]
      ]
    ]

    ops = [
      ["p", "s", ~s("b"), ~s({"x":2})],
      ["p", "s", "10", ~s({"x":1})],
      ["p", "s", "2", ~s({"x":3})],
      ["p", "s", ~s([1,"a"]), "0"],
      ["p", "s", ~s({"$":"d","v":5}), "0"],
      ["p", "s", ~s({"$":"I"}), "0"],
      ["p", "s", ~s({"$":"b","v":"00ff"}), "0"],
      ["p", "s", ~s("\u{10000}"), "0"],
      ["p", "s", ~s("\uffff"), "0"],
      ["d", "s", "2"],
      ["e", "s", "i", ~s([[1,10]])]
    ]

    DB.save(o, "d", 1, schema, ops, s)
    {:ok, _, 1, text} = DB.load(o, "d", nil, s)
    [store] = JSON.decode!(text)["s"]

    assert Enum.map(store["r"], &hd/1) == [
             10,
             %{"$" => "I"},
             %{"$" => "d", "v" => 5},
             "b",
             "\u{10000}",
             "\uffff",
             %{"$" => "b", "v" => "00ff"},
             [1, "a"]
           ]

    assert hd(store["i"])["e"] == [[1, 10]]

    # clear, then the store goes
    DB.save(o, "d", 1, schema, [["c", "s"], ["p", "s", "1", "{}"]], s)
    {:ok, _, 1, text} = DB.load(o, "d", nil, s)
    assert [[1, %{}]] = JSON.decode!(text)["s"] |> hd() |> Map.get("r")
    DB.save(o, "d", 1, @schema, [], s)
    DB.save(o, "d", 1, schema, [], s)
    {:ok, _, 1, text} = DB.load(o, "d", nil, s)
    assert JSON.decode!(text)["s"] |> hd() |> Map.get("r") == []
  end

  test "a key with a lone surrogate sorts by its code unit, and does not break the store" do
    {s, _} = store()
    o = "http://a.test"
    keys = [~s("\\uffff"), ~s("\\ud800"), ~s("b"), ~s("\u{10000}")]
    DB.save(o, "d", 1, @one_store, for(k <- keys, do: ["p", "s", k, "0"]), s)
    {:ok, _, 1, text} = DB.load(o, "d", nil, s)
    at = for k <- ~w("b" "\\ud800" "\\uffff"), do: elem(:binary.match(text, "[" <> k <> ","), 0)
    assert at == Enum.sort(at)
    assert text =~ ~s(["\u{10000}",0])
  end

  test "opening needs no wait when no connection is in the way" do
    {s, _} = store()
    assert {:ready, _} = DB.begin("http://a.test", "d", {:open, nil}, 1, s)
  end

  test "a higher version waits for the open connections to close" do
    {s, _} = store()
    a = page(self())
    b = page(self())

    assert {:ready, t1} = as(a, fn -> DB.begin("http://a.test", "d", {:open, 1}, 1, s) end)
    as(a, fn -> DB.finish("http://a.test", "d", t1, 7, s) end)
    DB.save("http://a.test", "d", 1, @schema, [], s)

    assert {:wait, token} = as(b, fn -> DB.begin("http://a.test", "d", {:open, 2}, 5, s) end)
    assert_receive {:got, ^a, {:idb, :versionchange, "http://a.test", "d", ^token, 1, 2}}
    refute_receive {:got, ^b, _}, 50

    # a hears of it and does not close: the request is blocked
    as(a, fn -> DB.settled("http://a.test", "d", token, s) end)
    assert_receive {:got, ^b, {:idb, :blocked, 5}}

    # then it closes
    as(a, fn -> DB.close("http://a.test", "d", 7, s) end)
    assert_receive {:got, ^b, {:idb, :ready, 5}}
  end

  test "deleting waits as well, and requests for one database go one after the other" do
    {s, _} = store()
    a = page(self())
    b = page(self())
    DB.save("http://a.test", "d", 1, @schema, [], s)

    assert {:ready, t1} = as(a, fn -> DB.begin("http://a.test", "d", {:open, nil}, 1, s) end)
    # a second request queues behind the first, which has not finished
    assert {:wait, t2} = as(b, fn -> DB.begin("http://a.test", "d", :delete, 2, s) end)
    refute_receive {:got, ^b, _}, 50

    as(a, fn -> DB.finish("http://a.test", "d", t1, 3, s) end)
    assert_receive {:got, ^a, {:idb, :versionchange, "http://a.test", "d", ^t2, 1, nil}}
    as(a, fn -> DB.close("http://a.test", "d", 3, s) end)
    assert_receive {:got, ^b, {:idb, :ready, 2}}
  end

  test "a page that goes away lets go of its connections" do
    {s, _} = store()
    a = page(self())
    b = page(self())
    DB.save("http://a.test", "d", 1, @schema, [], s)
    assert {:ready, t1} = as(a, fn -> DB.begin("http://a.test", "d", {:open, nil}, 1, s) end)
    as(a, fn -> DB.finish("http://a.test", "d", t1, 3, s) end)

    assert {:wait, _} = as(b, fn -> DB.begin("http://a.test", "d", {:open, 4}, 9, s) end)
    Process.unlink(a)
    Process.exit(a, :kill)
    assert_receive {:got, ^b, {:idb, :ready, 9}}
  end
end
