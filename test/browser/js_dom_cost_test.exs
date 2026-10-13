defmodule Browser.JS.DomCostTest do
  @moduledoc """
  The cost of the DOM searches and reads that the index of the ids, the kept class tokens and
  the reads without a realm swap made cheap. The oracle tests show that the answers are
  correct, but an answer that is correct and slow passes them too. Thus these tests compare
  the reductions of the script process for two pages that differ only in what must not change
  the cost.
  """
  use ExUnit.Case, async: true
  alias Browser.JS.Runtime

  defp start(body, script \\ "") do
    {raw, _} =
      "<body>#{body}<script>#{script}</script></body>"
      |> Browser.HTML.parse()
      |> Browser.Forms.index()

    info = %{url: "http://t.test/", width: 800, height: 600, fetch: fn _ -> {:error, "404"} end}
    pid = Runtime.start(raw, info)
    r = Runtime.run_scripts(pid)
    assert for({:error, t} <- r.console, do: t) == []
    pid
  end

  # the reductions of the script process while it runs `source`
  defp cost(pid, source) do
    {:reductions, r0} = Process.info(pid, :reductions)
    Runtime.eval(pid, source)
    {:reductions, r1} = Process.info(pid, :reductions)
    r1 - r0
  end

  # the value of `source`, as the console shows it
  defp value(pid, source) do
    for {:result, t} <- Runtime.eval(pid, source).console, do: t
  end

  # A node that leaves the tree stays in the node table and in the index of the ids. A page
  # that makes an element with the same id again and again thus gives the id a long list. The
  # lookups must not cost more with the length of that list than a walk of the tree costs.
  test "an id that a page makes again and again does not make its lookups slower" do
    make = fn rounds ->
      ~s"""
      const list = document.getElementById("list");
      for (let i = 0; i < #{rounds}; i++) {
        const e = document.createElement("li");
        e.id = "row";
        list.replaceChildren(e);
      }
      """
    end

    lookups = ~s"""
    let same = 0;
    for (let i = 0; i < 200; i++) if (document.getElementById("row") === list.firstChild) same++;
    for (let i = 0; i < 20; i++) if (document.querySelector("#row") === list.firstChild) same++;
    for (let i = 0; i < 20; i++) if (document.querySelectorAll("#row").length === 1) same++;
    for (let i = 0; i < 20; i++) if (window.row === list.firstChild) same++;
    same
    """

    body = "<ul id=list></ul>" <> String.duplicate("<div><p>x</p><span>y</span></div>", 100)

    [few, many] =
      for rounds <- [20, 2000] do
        pid = start(body, make.(rounds))
        cost = cost(pid, lookups)
        assert value(pid, "same") == ["260"]
        Runtime.stop(pid)
        cost
      end

    assert many < 2 * few
  end
end
