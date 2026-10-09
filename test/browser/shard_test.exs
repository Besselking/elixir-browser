defmodule Browser.ShardTest do
  use ExUnit.Case, async: true

  alias Browser.Shard

  test "parse!" do
    assert Shard.parse!("2/4") == {2, 4}
    assert_raise ArgumentError, fn -> Shard.parse!("5/4") end
    assert_raise ArgumentError, fn -> Shard.parse!("0/4") end
    assert_raise ArgumentError, fn -> Shard.parse!("x") end
  end

  test "shards cover the files once" do
    files = for i <- 1..10, do: "t#{String.pad_leading("#{i}", 2, "0")}.js"
    shards = for n <- 1..3, do: Shard.take(files, {n, 3})
    assert Enum.sort(Enum.concat(shards)) == files
    assert Enum.map(shards, &length/1) == [4, 3, 3]
  end
end
