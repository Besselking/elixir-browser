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
end
