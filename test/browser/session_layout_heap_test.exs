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

  # The session starts these processes for the page jobs, for the layouts after a resize and
  # for the layouts that the scripts wait for. It needs a window to do that, so a test can not
  # start them. Thus this test reads the source of the session: each function that styles or
  # lays out a page in a process of its own must go to `spawn_layout/1`. A `spawn/1` there
  # gives the process the default heap, and the other tests do not see it.
  test "the session starts each process that styles and lays out a page with spawn_layout/1" do
    {:ok, ast} =
      "lib/browser/session.ex"
      |> File.read!()
      |> Code.string_to_quoted()

    {_, spawns} =
      Macro.prewalk(ast, [], fn
        {name, _, args} = call, acc when is_atom(name) and is_list(args) ->
          lays_out? = Enum.any?(args, &(match?({:fn, _, _}, &1) and lays_out?(&1)))
          {call, if(lays_out?, do: [name | acc], else: acc)}

        other, acc ->
          {other, acc}
      end)

    assert length(spawns) >= 3
    assert Enum.uniq(spawns) == [:spawn_layout]
  end

  # whether the code calls `Page.from_raw`, `Page.restyle` or `LayoutWorker.layout`
  defp lays_out?(code) do
    {_, found} =
      Macro.prewalk(code, false, fn
        {{:., _, [{:__aliases__, _, [mod]}, fun]}, _, _} = call, found ->
          {call,
           found or
             {mod, fun} in [{:Page, :from_raw}, {:Page, :restyle}, {:LayoutWorker, :layout}]}

        other, found ->
          {other, found}
      end)

    found
  end
end
