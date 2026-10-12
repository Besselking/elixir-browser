defmodule Browser.LayoutWorkerTest do
  use ExUnit.Case, async: true
  alias Browser.{Layout, LayoutWorker, Page}

  defp measure(:content_height, style), do: round(style.size)
  defp measure(text, style), do: String.length(text) * div(round(style.size), 2)

  @html """
  <div style="display:flex"><div>one</div><div>two <b>items</b></div></div>
  <div style="float:left;width:100px">a float</div><p>text</p>
  """

  test "lays out as Layout.layout does, from the tab's memo the second time" do
    page = Page.build(@html, "about:test")
    worker = LayoutWorker.start(&measure/2)
    opts = [svg_defs: page.svg_defs, metrics: true]

    plain =
      Layout.layout(
        page.nodes,
        400,
        &measure/2,
        600,
        Keyword.put(opts, :metrics, &measure(:content_height, &1))
      )

    for _ <- 1..2 do
      {items, height} = LayoutWorker.layout(worker, :tab, page.nodes, 400, &measure/2, 600, opts)

      assert {Layout.memo_norm(items), height} ==
               {Layout.memo_norm(elem(plain, 0)), elem(plain, 1)}
    end

    # another tab, and a tab that was dropped
    assert {_, _} = LayoutWorker.layout(worker, :other, page.nodes, 400, &measure/2, 600, opts)
    LayoutWorker.drop(worker, :tab)
    assert {_, _} = LayoutWorker.layout(worker, :tab, page.nodes, 400, &measure/2, 600, opts)
  end

  test "a busy worker leaves the layout to the caller" do
    page = Page.build(@html, "about:test")
    worker = LayoutWorker.start(&measure/2)
    :atomics.put(worker.busy, 1, 1)
    me = self()

    spy = fn text, style ->
      send(me, :measured_here)
      measure(text, style)
    end

    assert {_, _} = LayoutWorker.layout(worker, :tab, page.nodes, 400, spy, 600, [])
    assert_received :measured_here
  end

  test "a layout that fails raises in the caller, and the worker goes on" do
    worker = LayoutWorker.start(fn _, _ -> raise "no fonts" end)

    assert_raise RuntimeError, "no fonts", fn ->
      LayoutWorker.layout(worker, :tab, [{:text, "x"}], 400, &measure/2, 600, [])
    end

    assert Process.alive?(worker.pid)
  end
end
