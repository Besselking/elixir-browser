Code.require_file("js_compile_corpus.ex", __DIR__)
Code.require_file("js_heap_oracle.ex", __DIR__)

defmodule Browser.JS.ElemsFormTest do
  # The form oracle of the elements of the arrays (data-model step B2, `Browser.JS.Elems`).
  # The process key `:js_elems_sparse` set to `true` makes each new array sparse (a map of
  # the elements), as before step B2. The key is read only where a record is made, so this
  # oracle runs in the normal build and in the check build.
  #
  # Each program of the compile corpus and of the data-model corpus
  # (`Browser.JS.DatamodelCorpus`, with the rows of step B2 for each change of form) runs
  # two times in one VM: with all arrays sparse, and with the dense form. The result, the
  # console, the steps left, the positions, the ordered export of the heap
  # (`Browser.JS.HeapOracle`), the heap ids and the heap count must agree: a dense record
  # holds the same elements as a sparse record, and it makes no object. The comparison runs
  # one more time with a forced collection before each top-level statement, so that a
  # dense store that the collector does not walk shows up as a freed object.
  use ExUnit.Case, async: false

  @moduletag timeout: 1_800_000

  alias Browser.JS.HeapOracle
  alias Browser.JS.CompileTest.Corpus

  @programs Corpus.programs(__DIR__)

  defp sparse(on?), do: fn -> Process.put(:js_elems_sparse, on?) end

  test "all arrays sparse, then dense: the outcomes, the heap ids and the heap count agree" do
    assert length(@programs) > 600

    HeapOracle.assert_same(
      HeapOracle.both(@programs, sparse(true), sparse(false), ids: true),
      "with the dense form"
    )
  end

  test "the same with a forced collection before each top-level statement" do
    HeapOracle.assert_same(
      HeapOracle.both(@programs, sparse(true), sparse(false), ids: true, gc: true),
      "with the dense form and forced collections"
    )
  end

  test "the rows of step B2 give the output of node with all arrays sparse" do
    # (the shapes oracle compares the rows with node in the dense form)
    rows = Map.new(Browser.JS.DatamodelCorpus.rows(), fn {name, src, _} -> {name, src} end)

    expected =
      for {"dm elems" <> _ = name, out} <- Browser.JS.DatamodelCorpus.node_output(),
          do: {name, out}

    assert length(expected) >= 15
    programs = for {name, _} <- expected, do: {name, Map.fetch!(rows, name), []}

    outputs =
      for out <- HeapOracle.run_all(programs, sparse(true), []),
          do: Enum.map_join(out.console, "\n", fn {_, text} -> text end)

    for {{name, want}, got} <- Enum.zip(expected, outputs),
        do: assert({name, got} == {name, want})
  end
end
