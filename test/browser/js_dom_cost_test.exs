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

  test "getElementById does not walk the tree" do
    lookups = ~s[for (let i = 0; i < 200; i++) document.getElementById("last");]

    [small, large] =
      for n <- [50, 5000] do
        pid = start(String.duplicate("<div><span>x</span></div>", div(n, 2)) <> "<p id=last></p>")
        cost = cost(pid, lookups)
        Runtime.stop(pid)
        cost
      end

    # (a walk of the tree costs about 100 times more in the large document)
    assert large < 2 * small
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

  test "a class selector does not split the class attributes again for each search" do
    search = ~s[for (let i = 0; i < 100; i++) document.querySelectorAll(".z");]

    [short, long] =
      for tokens <- [1, 50] do
        class = Enum.map_join(1..tokens, " ", &"c#{&1}")
        pid = start(String.duplicate(~s(<p class="#{class}">x</p>), 200))
        cost = cost(pid, search)
        Runtime.stop(pid)
        cost
      end

    assert long < 1.5 * short
  end

  test "the page reads the size of a canvas of a frame as fast as one of its own" do
    pid =
      start("<canvas id=c width=120 height=40></canvas>", ~S"""
      const f = document.createElement("iframe");
      f.srcdoc = "<body><canvas id=c width=120 height=40></canvas></body>";
      document.body.appendChild(f);
      """)

    frame = ~s[document.querySelector("iframe").contentDocument]
    assert value(pid, frame <> ~s[.getElementById("c").width]) == ["120"]

    reads = fn doc ->
      ~s"""
      {
        const c = #{doc}.getElementById("c");
        let s = 0;
        for (let i = 0; i < 10000; i++) s += c.width + c.height;
      }
      """
    end

    own = cost(pid, reads.("document"))
    frame = cost(pid, reads.(frame))
    Runtime.stop(pid)

    # (with a swap of the realm for each read, the frame costs about a third more)
    assert frame < 1.2 * own
  end
end
