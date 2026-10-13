defmodule Browser.SessionLayoutHeapTest do
  use ExUnit.Case, async: true

  # The style and the layout of a page allocate a lot: the process that makes them starts with a
  # large heap, so that the heap does not grow by many collections.
  test "a process that styles and lays out a page starts with a large heap" do
    test = self()
    Browser.Session.spawn_layout(fn -> send(test, Process.info(self(), :min_heap_size)) end)
    assert_receive {:min_heap_size, words}
    assert words >= 2_000_000
  end
end
