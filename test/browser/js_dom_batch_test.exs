defmodule Browser.JS.DomBatchTest do
  @moduledoc """
  The one-pass paths of `Browser.JS.DOM` for many new nodes: the nodes of parsed HTML are made
  on one state (`build_all/2`, `parse_fragment/1`), and the kids of a fragment go into their
  new parent in one pass (`insert_all/3`). They must give the same node table, indexes and
  counts as `insert/3` of one node at a time. A page that registers a custom element makes
  `insert_all/3` take the path of one node at a time (a connected node can then be a custom
  element), so the same script with and without an unused registration compares the two paths.
  """
  use ExUnit.Case, async: true
  alias Browser.JS.Runtime

  defp start(body, script) do
    {raw, _} =
      "<body>#{body}<script>#{script}</script></body>"
      |> Browser.HTML.parse()
      |> Browser.Forms.index()

    info = %{url: "http://t.test/", width: 800, height: 600, fetch: fn _ -> {:error, "404"} end}
    pid = Runtime.start(raw, info)
    r = Runtime.run_scripts(pid)
    {pid, for({:log, t} <- r.console, do: t), for({:error, t} <- r.console, do: t)}
  end

  defp run(body, script) do
    {pid, logs, errors} = start(body, script)
    Runtime.stop(pid)
    {logs, errors}
  end

  # the parts of the DOM state that the node writes change
  defp state(pid) do
    {:dictionary, pd} = Process.info(pid, :dictionary)

    pd
    |> Keyword.fetch!(:dom)
    |> Map.take([:nodes, :ids, :aidx, :rev, :next, :iframes, :dirty, :fdirty, :ce_done])
  end

  @changes ~S"""
  // (the first searches give the attribute names an index)
  document.querySelector('[data-id="0"]');
  document.querySelector('[data-k="x"]');
  const list = document.getElementById("list");
  for (let n = 0; n < 6; n++) {
    let h = "";
    for (let i = 0; i < n; i++)
      h += '<li id="i' + (i % 3) + '" class="a b' + (i % 2 ? " c" : "") + '" data-id="' + i +
        '"><input class="t" data-k="x"><label>t' + i + '</label></li>\n';
    list.innerHTML = h;
  }
  const box = document.getElementById("box");
  box.insertAdjacentHTML("beforeend", '<p id="i1" data-id="9">e</p><!-- c -->t');
  box.insertAdjacentHTML("afterbegin", '<p class="first" data-k="x">s</p>');
  box.insertAdjacentHTML("beforebegin", '<hr id="before">');
  box.insertAdjacentHTML("afterend", '<hr id="after" data-id="1">');
  box.firstChild.outerHTML = '<span id="o1">x</span><span id="o2" data-id="2">y</span>';
  box.insertAdjacentHTML("beforeend",
    '<template id="t1"><div id="in" data-id="3"><template><b id="deep">d</b></template></div></template>');
  const t1 = document.getElementById("t1");
  box.appendChild(t1.content.cloneNode(true));
  const frag = document.createDocumentFragment();
  frag.appendChild(document.createElement("em")).id = "f1";
  frag.appendChild(document.createTextNode("ft"));
  box.insertBefore(frag, box.firstChild);
  const div = document.createElement("div");
  div.innerHTML = '<i id="det" data-id="4">detached</i>';
  box.appendChild(div);
  list.textContent = "";
  list.innerHTML = '<li data-id="0" class="z">only</li>';
  """

  test "the one-pass paths give the same state as one node at a time" do
    body = ~s(<ul id="list"></ul><div id="box" data-id="0"></div>)

    [a, b] =
      for define <- ["", "customElements.define('x-unused', class extends HTMLElement {});"] do
        {pid, [], []} = start(body, "")
        # (`eval` adds no node, so the two trees are the same before the changes)
        r = Runtime.eval(pid, define <> @changes)
        assert for({:error, t} <- r.console, do: t) == []
        state = state(pid)
        Runtime.stop(pid)
        state
      end

    for k <- Map.keys(a), do: assert({k, a[k]} == {k, b[k]})
    assert a.rev > 100
  end

  test "the nodes, the indexes and the class tokens after innerHTML and insertAdjacentHTML" do
    {logs, errors} =
      run(~s(<ul id="list"></ul><div id="box"></div>), ~S"""
      const list = document.getElementById("list");
      document.querySelector('[data-id="0"]');
      for (let r = 0; r < 3; r++)
        list.innerHTML = '<li id="a" class="x y" data-id="' + r + '">1</li>\n<li class="y" data-id="b' + r + '">2</li>';
      const li = list.children;
      console.log([li.length, list.childNodes.length, li[0].parentNode === list, li[1].previousSibling.nodeType,
        document.getElementById("a") === li[0], document.querySelectorAll("#a").length,
        document.querySelector('[data-id="2"]') === li[0], document.querySelector('[data-id="1"]'),
        document.querySelectorAll(".y").length, document.querySelectorAll(".x.y").length,
        li[0].classList.contains("x"), li[0].ownerDocument === document].join());
      const box = document.getElementById("box");
      box.insertAdjacentHTML("beforeend", "<b>2</b><b>3</b>");
      box.insertAdjacentHTML("afterbegin", "<b>0</b><b>1</b>");
      box.lastChild.insertAdjacentHTML("beforebegin", "<i>a</i>");
      box.firstChild.insertAdjacentHTML("afterend", "<i>b</i><i>c</i>");
      console.log(box.innerHTML);
      box.children[1].outerHTML = "<u>x</u><u>y</u>";
      console.log(box.innerHTML);
      """)

    assert errors == []

    assert logs == [
             "2,3,true,3,true,1,true,,2,1,true,true",
             "<b>0</b><i>b</i><i>c</i><b>1</b><b>2</b><i>a</i><b>3</b>",
             "<b>0</b><u>x</u><u>y</u><i>c</i><b>1</b><b>2</b><i>a</i><b>3</b>"
           ]
  end

  test "a fragment is empty after its kids move, and a template keeps its content apart" do
    {logs, errors} =
      run(~s(<div id="box"></div>), ~S"""
      const box = document.getElementById("box");
      box.innerHTML = '<template id="t"><p id="in">a<template><b id="deep">d</b></template></p></template>';
      const t = document.getElementById("t");
      const c = t.content;
      console.log([document.getElementById("in"), c.getElementById("in") !== null,
        c.firstChild.lastChild.content.firstChild.id, c.firstChild.parentNode === c].join());
      const copy = c.cloneNode(true);
      box.appendChild(copy);
      console.log([copy.childNodes.length, document.getElementById("in").parentNode === box,
        c.childNodes.length, document.getElementById("deep")].join());
      const f = document.createDocumentFragment();
      f.append("x", document.createElement("hr"), "y");
      box.prepend(f);
      console.log([f.childNodes.length, box.childNodes.length, box.firstChild.data, box.childNodes[1].tagName].join());
      """)

    assert errors == []
    assert logs == [",true,deep,true", "0,true,1,", "0,5,x,HR"]
  end

  test "a fragment that holds its new parent throws and keeps its kids" do
    {logs, errors} =
      run("", ~S"""
      const f = document.createDocumentFragment();
      f.append(document.createElement("p"), document.createElement("div"));
      const inner = f.lastChild;
      try { inner.appendChild(f); console.log("no throw"); } catch (e) { console.log(e.message); }
      console.log([f.childNodes.length, inner.childNodes.length, inner.parentNode === f].join());
      """)

    assert errors == []
    assert logs == ["The new child element contains the parent.", "2,0,true"]
  end

  test "an iframe in innerHTML loads, and leaves with its parent's kids" do
    {pid, [], []} =
      start(~s(<div id="box"></div>), ~S"""
      document.getElementById("box").innerHTML = '<p>a</p><iframe srcdoc="<p id=x>hi</p>"></iframe><p>b</p>';
      """)

    Runtime.flush(pid)

    r =
      Runtime.eval(pid, ~S"""
      const box = document.getElementById("box");
      const f = box.querySelector("iframe");
      const d = f.contentDocument;
      const before = [box.childNodes.length, d !== null && d.getElementById("x").textContent].join();
      box.innerHTML = "<p>c</p>";
      [before, box.childNodes.length, f.parentNode, f.contentDocument].join(" ")
      """)

    Runtime.stop(pid)
    assert for({:result, t} <- r.console, do: t) == ["'3,hi 1  '"]
  end

  test "custom elements in innerHTML are upgraded and connected in tree order" do
    {logs, errors} =
      run(~s(<div id="box"></div>), ~S"""
      const seen = [];
      class XA extends HTMLElement { connectedCallback() { seen.push("c" + this.id + this.parentNode.id); } }
      customElements.define("x-a", XA);
      const box = document.getElementById("box");
      box.innerHTML = '<x-a id="1"></x-a><p id="p"><x-a id="2"></x-a></p><x-a id="3"></x-a>';
      console.log(seen.join(), document.getElementById("2") instanceof XA);
      const d = document.createElement("div");
      d.id = "d";
      d.innerHTML = '<x-a id="4"></x-a>';
      console.log(seen.length);
      box.appendChild(d);
      console.log(seen.join());
      """)

    assert errors == []
    assert logs == ["c1box,c2p,c3box true", "3", "c1box,c2p,c3box,c4d"]
  end

  test "a connectedCallback that throws stops innerHTML after that node" do
    {logs, _errors} =
      run(~s(<div id="box"></div>), ~S"""
      customElements.define("x-bad", class extends HTMLElement { connectedCallback() { throw new Error("bad"); } });
      const box = document.getElementById("box");
      try { box.innerHTML = '<p id="a"></p><x-bad></x-bad><p id="b"></p>'; console.log("no throw"); }
      catch (e) { console.log(e.message); }
      console.log([...box.childNodes].map((n) => n.id || n.tagName).join());
      """)

    assert logs == ["no throw", "a,X-BAD,b"]
  end
end
