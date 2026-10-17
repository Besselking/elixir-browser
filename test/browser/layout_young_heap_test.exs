defmodule Browser.LayoutYoungHeapTest do
  use ExUnit.Case, async: true
  alias Browser.{Layout, Page}

  defp measure(text, style), do: String.length(text) * div(round(style.size), 2)

  # A layout that keeps a lot alive while it places (here the 20,000 words of a scroller in a
  # flex item) makes the young heap of its process larger, and gives the process its old young
  # heap back when the place ends.
  test "the young heap grows with what the layout keeps, and comes back after the layout" do
    words = Enum.map_join(1..2000, " ", &"w#{&1}")

    html =
      ~s(<div style="display:flex;height:300px;overflow:hidden"><div style="overflow:auto">) <>
        String.duplicate("<p>#{words}</p>", 10) <> "</div></div>"

    page = Page.build(html, "about:test")
    test = self()

    pid =
      Browser.Session.spawn_layout(fn ->
        {:min_heap_size, before} = Process.info(self(), :min_heap_size)
        send(test, {:before, before})
        opts = [images: %{}, svg_defs: page.svg_defs]
        Layout.layout_kept(page.nodes, 800, &measure/2, 600, opts, nil)
        {:min_heap_size, after_layout} = Process.info(self(), :min_heap_size)
        send(test, {:done, after_layout})
        receive do: (:stop -> :ok)
      end)

    assert_receive {:before, before}
    {largest, after_layout} = watch(pid, before)
    send(pid, :stop)
    assert after_layout == before
    assert largest > before
  end

  # the largest young heap size of the process until the layout ends, and its size after
  defp watch(pid, largest) do
    receive do
      {:done, after_layout} -> {largest, after_layout}
    after
      1 ->
        {:min_heap_size, size} = Process.info(pid, :min_heap_size)
        watch(pid, max(size, largest))
    end
  end
end
