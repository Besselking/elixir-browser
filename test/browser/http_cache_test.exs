defmodule Browser.HttpCacheTest do
  # not async: eviction touches entries other tests may be using
  use ExUnit.Case, async: false
  alias Browser.HttpCache

  test "the cache keeps a bounded number of entries" do
    for i <- 1..300 do
      HttpCache.store("http://cache.test/#{i}", [{~c"cache-control", ~c"max-age=60"}], "x")
    end

    assert :ets.info(HttpCache, :size) <= 256
    HttpCache.clear()
    assert :miss = HttpCache.lookup("http://cache.test/1")
  end

  describe "disk layer" do
    setup do
      dir = Path.join(System.tmp_dir!(), "http_cache_#{System.unique_integer([:positive])}")
      Application.put_env(:browser, :disk_cache_dir, dir)
      HttpCache.clear()

      on_exit(fn ->
        Application.put_env(:browser, :disk_cache_dir, nil)
        File.rm_rf!(dir)
      end)

      %{dir: dir}
    end

    defp memory_forget, do: :ets.delete_all_objects(HttpCache)

    test "an entry survives losing the memory layer", %{dir: dir} do
      url = "http://disk.test/a"
      HttpCache.store(url, [{~c"cache-control", ~c"max-age=60"}, {~c"etag", ~c"\"v1\""}], "body")
      HttpCache.sync()
      assert [_] = Path.wildcard(Path.join(dir, "*.entry"))

      memory_forget()
      assert {:fresh, entry} = HttpCache.lookup(url)
      assert entry.body == "body"
      assert entry.etag == "\"v1\""
      # and it is back in memory
      assert :ets.member(HttpCache, url)
    end

    test "a stale entry comes back stale", %{dir: _} do
      url = "http://disk.test/stale"
      HttpCache.store(url, [{~c"etag", ~c"x"}], "old")
      HttpCache.sync()
      memory_forget()
      assert {:stale, %{body: "old"}} = HttpCache.lookup(url)
    end

    test "Set-Cookie, no-store and private responses are not written", %{dir: dir} do
      ok = [{~c"cache-control", ~c"max-age=60"}]
      HttpCache.store("http://disk.test/c", [{~c"set-cookie", ~c"a=b"} | ok], "x")
      HttpCache.store("http://disk.test/n", [{~c"cache-control", ~c"no-store"}], "x")
      HttpCache.store("http://disk.test/p", [{~c"cache-control", ~c"private, max-age=60"}], "x")
      HttpCache.sync()
      assert Path.wildcard(Path.join(dir, "*.entry")) == []
    end

    test "a response that stops being storable removes the file", %{dir: dir} do
      url = "http://disk.test/r"
      HttpCache.store(url, [{~c"cache-control", ~c"max-age=60"}], "x")
      HttpCache.sync()
      assert [_] = Path.wildcard(Path.join(dir, "*.entry"))
      HttpCache.store(url, [{~c"cache-control", ~c"no-store"}], "x")
      HttpCache.sync()
      assert Path.wildcard(Path.join(dir, "*.entry")) == []
    end

    test "a damaged file is a miss", %{dir: dir} do
      url = "http://disk.test/bad"
      HttpCache.store(url, [{~c"cache-control", ~c"max-age=60"}], "x")
      HttpCache.sync()
      [file] = Path.wildcard(Path.join(dir, "*.entry"))
      File.write!(file, "garbage")
      memory_forget()
      assert :miss = HttpCache.lookup(url)
    end

    test "the folder is kept under its size cap, oldest use first", %{dir: dir} do
      for i <- 1..4 do
        HttpCache.store(
          "http://disk.test/big#{i}",
          [{~c"cache-control", ~c"max-age=60"}],
          String.duplicate("x", 1000)
        )
      end

      HttpCache.sync()
      files = Path.wildcard(Path.join(dir, "*.entry"))
      assert length(files) == 4
      # age the files in a known order
      files
      |> Enum.with_index()
      |> Enum.each(fn {f, i} -> File.touch!(f, 1_700_000_000 + i) end)

      newest = List.last(files)
      HttpCache.prune(2500)
      left = Path.wildcard(Path.join(dir, "*.entry"))
      assert length(left) == 2
      assert newest in left
    end

    test "clear removes the files", %{dir: dir} do
      HttpCache.store("http://disk.test/z", [{~c"cache-control", ~c"max-age=60"}], "x")
      HttpCache.sync()
      HttpCache.clear()
      assert Path.wildcard(Path.join(dir, "*.entry")) == []
      assert :miss = HttpCache.lookup("http://disk.test/z")
    end
  end

  describe "a 304 keeps the fields of the stored response that it does not send" do
    @lm ~c"Mon, 01 Jan 2024 00:00:00 GMT"

    test "no-cache stays: the entry is stale after the 304" do
      url = "http://cache.test/304-no-cache"
      HttpCache.store(url, [{~c"cache-control", ~c"no-cache"}, {~c"last-modified", @lm}], "b")
      assert {:stale, entry} = HttpCache.lookup(url)
      HttpCache.refresh(entry, [], url)
      assert {:stale, _} = HttpCache.lookup(url)
    end

    test "max-age stays" do
      url = "http://cache.test/304-max-age"
      HttpCache.store(url, [{~c"cache-control", ~c"max-age=600"}, {~c"etag", ~c"\"a\""}], "b")
      assert {:fresh, entry} = HttpCache.lookup(url)
      HttpCache.refresh(entry, [], url)
      assert {:fresh, _} = HttpCache.lookup(url)
    end

    test "Expires stays, against the Date of the 304" do
      url = "http://cache.test/304-expires"
      date = :httpd_util.rfc1123_date()
      future = ~c"Fri, 01 Jan 2100 00:00:00 GMT"
      HttpCache.store(url, [{~c"expires", future}, {~c"etag", ~c"\"a\""}], "b")
      assert {:fresh, entry} = HttpCache.lookup(url)
      HttpCache.refresh(entry, [{~c"date", date}], url)
      assert {:fresh, _} = HttpCache.lookup(url)
    end

    test "the fields of the 304 replace the stored ones" do
      url = "http://cache.test/304-replace"
      HttpCache.store(url, [{~c"cache-control", ~c"max-age=600"}, {~c"etag", ~c"\"a\""}], "b")
      assert {:fresh, entry} = HttpCache.lookup(url)
      HttpCache.refresh(entry, [{~c"cache-control", ~c"no-cache"}], url)
      assert {:stale, entry} = HttpCache.lookup(url)
      HttpCache.refresh(entry, [{~c"last-modified", @lm}], url)
      assert {:stale, _} = HttpCache.lookup(url)
    end

    test "a 304 without Last-Modified gets the heuristic lifetime of the stored one" do
      url = "http://cache.test/304-heuristic"
      HttpCache.store(url, [{~c"last-modified", @lm}], "b")
      assert {:fresh, entry} = HttpCache.lookup(url)
      HttpCache.refresh(entry, [], url)
      assert {:fresh, entry} = HttpCache.lookup(url)
      assert entry.last_modified == to_string(@lm)
    end
  end
end
