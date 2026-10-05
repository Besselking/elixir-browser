defmodule Browser.LocalStorageTest do
  use ExUnit.Case, async: true
  alias Browser.LocalStorage, as: LS

  # a store of its own, so tests don't share items (or the one in the application)
  defp store(opts \\ []) do
    name = :"ls_#{System.unique_integer([:positive])}"
    {:ok, pid} = LS.start_link(Keyword.merge([name: name, path: nil], opts))
    {name, pid}
  end

  test "the origin of a page" do
    assert LS.origin("https://Example.com/a?b#c") == "https://example.com"
    assert LS.origin("http://example.com:8080/") == "http://example.com:8080"
    assert LS.origin("http://example.com:80/") == "http://example.com"
    assert LS.origin("file:///tmp/x.html") == "file://"
    assert LS.origin("about:home") == nil
    assert LS.origin("data:text/html,x") == nil
  end

  test "items are kept per origin, sorted by name" do
    {s, _} = store()
    assert LS.count("http://a.test", s) == 0
    assert LS.get("http://a.test", "k", s) == nil
    :ok = LS.put("http://a.test", "b", "2", s)
    :ok = LS.put("http://a.test", "a", "1", s)
    :ok = LS.put("http://b.test", "a", "other", s)
    assert LS.count("http://a.test", s) == 2
    assert LS.keys("http://a.test", s) == ["a", "b"]
    assert LS.key("http://a.test", 1, s) == "b"
    assert LS.key("http://a.test", 2, s) == nil
    assert LS.get("http://b.test", "a", s) == "other"

    LS.delete("http://a.test", "a", s)
    assert LS.keys("http://a.test", s) == ["b"]
    LS.clear("http://a.test", s)
    assert LS.count("http://a.test", s) == 0
    assert LS.count("http://b.test", s) == 1
  end

  test "an origin cannot hold more than 5 Mi characters" do
    {s, _} = store()
    big = String.duplicate("x", 3 * 1024 * 1024)
    assert LS.put("http://q.test", "a", big, s) == :ok
    assert LS.put("http://q.test", "b", big, s) == {:error, :quota}
    # replacing a value counts only the difference, and other origins have their own quota
    assert LS.put("http://q.test", "a", big <> "y", s) == :ok
    assert LS.put("http://r.test", "b", big, s) == :ok
    LS.delete("http://q.test", "a", s)
    assert LS.put("http://q.test", "b", big, s) == :ok
  end

  test "the store survives a restart" do
    path = Path.join(System.tmp_dir!(), "ls_#{System.unique_integer([:positive])}.etf")
    on_exit(fn -> File.rm(path) end)

    {s, pid} = store(path: path)
    LS.put("http://p.test", "keep", "me", s)
    LS.put("http://p.test", "drop", "me", s)
    LS.delete("http://p.test", "drop", s)
    LS.put("file://", "f", "1", s)
    LS.flush(s)
    GenServer.stop(pid)

    {s2, _} = store(path: path)
    assert LS.get("http://p.test", "keep", s2) == "me"
    assert LS.get("http://p.test", "drop", s2) == nil
    assert LS.get("file://", "f", s2) == "1"
    # the quota accounting is rebuilt too
    assert LS.put("http://p.test", "big", String.duplicate("x", 5 * 1024 * 1024), s2) ==
             {:error, :quota}
  end

  test "a change is saved a moment after, and when the process stops" do
    path = Path.join(System.tmp_dir!(), "ls_#{System.unique_integer([:positive])}.etf")
    on_exit(fn -> File.rm(path) end)
    {s, pid} = store(path: path)
    LS.put("http://p.test", "a", "1", s)
    GenServer.stop(pid)
    assert File.exists?(path)
  end

  test "a damaged file starts an empty store" do
    path = Path.join(System.tmp_dir!(), "ls_#{System.unique_integer([:positive])}.etf")
    on_exit(fn -> File.rm(path) end)
    File.write!(path, "not a term")
    {s, _} = store(path: path)
    assert LS.count("http://p.test", s) == 0
  end

  test "other pages of the origin hear of changes, the one that made them does not" do
    {s, _} = store()
    origin = "http://n.test"
    me = self()

    other =
      spawn_link(fn ->
        LS.subscribe(origin, s)
        send(me, :subscribed)

        receive do
          msg -> send(me, {:other, msg})
        end
      end)

    assert_receive :subscribed
    LS.subscribe(origin, s)
    LS.put(origin, "k", "v", s)
    assert_receive {:other, {:storage, ^origin, "k", nil, "v"}}
    refute_received {:storage, _, _, _, _}
    _ = other
  end
end
