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

  # The reductions of the script process while it runs `source`. (A garbage collection also
  # counts reductions, for each word that it keeps. The collection first makes the count not
  # depend on how full the heap was after the page was made.)
  defp cost(pid, source) do
    :erlang.garbage_collect(pid)
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

  test "a search by attribute value does not walk the tree" do
    # The first search makes the index of the name, with one pass over the node table. That
    # pass is linear in the size of the document, so it runs before the measure: with it in
    # the measure, a fall of the fixed cost of a query moves the ratio to 2.
    first = ~s|document.querySelector('[data-id="0"]')|

    lookups = ~s"""
    for (let i = 0; i < 200; i++) {
      document.querySelector('[data-id="last"]');
      document.querySelectorAll('li[data-id="' + (i % 20) + '"]');
    }
    """

    [small, large] =
      for n <- [50, 5000] do
        items = Enum.map_join(0..(div(n, 2) - 1), &~s(<li data-id="#{&1}"><span>x</span></li>))
        pid = start("<ul>" <> items <> ~s(</ul><p data-id="last"></p>))
        Runtime.eval(pid, first)
        cost = cost(pid, lookups)
        assert value(pid, ~s{document.querySelectorAll('[data-id="7"]').length}) == ["1"]
        Runtime.stop(pid)
        cost
      end

    # (a walk of the tree costs about 100 times more in the large document)
    assert large < 2 * small
  end

  # A list that a page draws again and again (`innerHTML`) gives an attribute value many
  # elements, and only the newest is in the document. An old item is the top of its tree, and
  # the index does not keep it. But its children keep their parent, and the index keeps them.
  # A lookup of a value that more than a few elements have walks the tree at once, so it does
  # not cost much more than a walk.
  test "a value that a page sets again and again does not make its lookups slower" do
    make = fn rounds ->
      ~s"""
      const list = document.getElementById("list");
      for (let i = 0; i < #{rounds}; i++)
        list.innerHTML = '<li data-id="row"><i data-id="in">a</i></li><li data-id="b">b</li>';
      """
    end

    lookups = fn op, v, want ->
      ~s"""
      var same = 0;
      for (let i = 0; i < 100; i++) if (document.querySelector('[data-id#{op}"#{v}"]') === #{want}) same++;
      for (let i = 0; i < 20; i++) if (document.querySelectorAll('[data-id#{op}"#{v}"]').length === 1) same++;
      same
      """
    end

    body = "<ul id=list></ul>" <> String.duplicate("<div><p>x</p><span>y</span></div>", 100)

    costs =
      for rounds <- [20, 2000] do
        pid = start(body, make.(rounds))
        # (the first search makes the index; `~=` has no index and walks the tree)
        assert value(pid, ~s{document.querySelector('[data-id="b"]').textContent}) == ["'b'"]

        [row, inner, walk] =
          for {op, v, want} <- [
                {"=", "row", "list.firstChild"},
                {"=", "in", "list.firstChild.firstChild"},
                {"~=", "in", "list.firstChild.firstChild"}
              ] do
            cost = cost(pid, lookups.(op, v, want))
            assert value(pid, "same") == ["120"]
            cost
          end

        Runtime.stop(pid)
        assert row < walk / 2
        assert inner < 1.5 * walk
        row
      end

    [few, many] = costs
    assert many < 1.5 * few
  end

  # Many elements can have one value (`role="option"`). The index of the name must not make a
  # change of one of them cost more with the number of the others.
  test "a value that many elements have does not make the changes of the tree slower" do
    draw = ~s"""
    const ul = document.getElementById("l");
    let h = "";
    for (let i = 0; i < 2000; i++) h += '<li role="option">x</li>';
    for (let r = 0; r < 2; r++) ul.innerHTML = h;
    """

    [plain, indexed] =
      for search <- ["div", ~s([role="option"])] do
        pid = start(~s(<ul id="l">) <> String.duplicate(~s(<li role="option">x</li>), 2000))
        # (the search by the value makes the index of the name)
        value(pid, ~s{document.querySelectorAll('#{search}').length})
        cost = cost(pid, draw)
        assert value(pid, ~s{document.querySelectorAll('[role="option"]').length}) == ["2000"]
        Runtime.stop(pid)
        cost
      end

    assert indexed < 1.5 * plain
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

  # `innerHTML` moves the new nodes into their parent in one pass. A page that registers a
  # custom element makes it take the path of one node at a time (a node can then be a custom
  # element that must be told it was connected), so the two pages compare the two paths.
  test "innerHTML moves a long list in one pass" do
    draw = ~S"""
    const list = document.getElementById("list");
    let h = "";
    for (let i = 0; i < 500; i++) h += '<li class="item" data-id="' + i + '"><span>' + i + '</span></li>';
    for (let r = 0; r < 4; r++) list.innerHTML = h;
    """

    [fast, one] =
      for define <- ["", "customElements.define('x-unused', class extends HTMLElement {});"] do
        pid = start("<ul id=list></ul>", define)
        cost = cost(pid, draw)
        Runtime.stop(pid)
        cost
      end

    # (one pass costs about 0.6 of the other path, with the reply that exports the list)
    assert fast < 0.8 * one
  end
end
