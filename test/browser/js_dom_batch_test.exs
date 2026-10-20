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

  # The indexes must be what a walk of the node table gives: `ids` has each element with an
  # `id` (in any tree), `aidx` each element with a parent and an attribute of an indexed name,
  # and an element with a `class` has the tokens of its value.
  defp assert_indexes(s) do
    ids =
      for {nid, %{kind: :element, attrs: attrs}} <- s.nodes,
          {"id", v} <- [List.keyfind(attrs, "id", 0)],
          v != "",
          reduce: %{} do
        acc -> Map.update(acc, v, [nid], &[nid | &1])
      end

    assert Map.new(s.ids, fn {k, l} -> {k, Enum.sort(l)} end) ==
             Map.new(ids, fn {k, l} -> {k, Enum.sort(l)} end)

    for {name, vals} <- s.aidx do
      walk =
        for {nid, %{kind: :element, attrs: attrs, parent: p}} when p != nil <- s.nodes,
            {_, v} <- [List.keyfind(attrs, name, 0)],
            reduce: %{} do
          acc -> Map.update(acc, v, %{nid => true}, &Map.put(&1, nid, true))
        end

      assert {name, vals} == {name, walk}
    end

    for {_, %{kind: :element, attrs: attrs} = n} <- s.nodes,
        {"class", v} <- [List.keyfind(attrs, "class", 0)] do
      assert n.cls == {v, String.split(v)}
    end
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

  # Runs `script` on the page `body` two times: the second time after an unused registration
  # of a custom element, so that `insert_all/3` takes the path of one node at a time for a
  # connected parent. The state and the console lines must be the same, and the indexes must
  # agree with the node table. Gives the state and the console lines.
  defp both_paths(body, script) do
    [{a, logs}, {b, logs_b}] =
      for define <- ["", "customElements.define('x-unused', class extends HTMLElement {});"] do
        {pid, [], []} = start(body, "")
        # (a frame of the page loads here)
        Runtime.flush(pid)
        # (`eval` adds no node, so the two trees are the same before the changes)
        r = Runtime.eval(pid, define <> script)
        state = state(pid)
        Runtime.stop(pid)
        {state, for({k, t} <- r.console, k in [:log, :error], do: {k, t})}
      end

    assert logs == logs_b
    for k <- Map.keys(a), do: assert({k, a[k]} == {k, b[k]})
    assert_indexes(a)
    {a, logs}
  end

  test "the one-pass paths give the same state as one node at a time" do
    body = ~s(<ul id="list"></ul><div id="box" data-id="0"></div>)
    {a, logs} = both_paths(body, @changes)
    assert for({:error, _} = e <- logs, do: e) == []
    assert a.rev > 100
    assert map_size(a.aidx) == 2
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

  # (the nodes of these documents have the document of the page as their document, so the
  # moves here do not adopt; the next test moves nodes between the page and a frame)
  test "the documents of DOMParser and createHTMLDocument on both paths" do
    {_, logs} =
      both_paths(~s(<div id="m"></div>), ~S"""
      const d = new DOMParser().parseFromString("<p id=a>a</p>", "text/html");
      const m = document.getElementById("m");
      const f = d.createDocumentFragment();
      f.append(d.createElement("em"), d.createTextNode("x"));
      m.appendChild(f);
      const g = document.createDocumentFragment();
      g.append(document.createElement("hr"), "y");
      d.body.appendChild(g);
      d.body.insertAdjacentHTML("beforeend", '<i id="c" data-id="1">c</i>');
      d.body.firstChild.outerHTML = '<u id="o1">1</u><u id="o2">2</u>';
      const h = document.implementation.createHTMLDocument("h");
      h.body.innerHTML = '<p id="hp" class="k">p</p>';
      console.log([m.firstChild.ownerDocument === document, m.lastChild.ownerDocument === document,
        d.body.lastChild.ownerDocument === d, d.getElementById("hp"), h.getElementById("hp") !== null,
        h.body.firstChild.ownerDocument === h, d.body.innerHTML].join());
      """)

    assert logs == [
             log:
               "true,true,false,,true,false,<u id=\"o1\">1</u><u id=\"o2\">2</u><hr>y<i id=\"c\" data-id=\"1\">c</i>"
           ]
  end

  test "the kids of a fragment of a frame's document are adopted, on both paths" do
    {_, logs} =
      both_paths(~s(<div id="box"></div><iframe id="fr" srcdoc="<p>a</p>"></iframe>), ~S"""
      const d = document.getElementById("fr").contentDocument;
      const box = document.getElementById("box");
      const g = d.createDocumentFragment();
      g.append(d.createElement("i"), d.createTextNode("t"));
      const before = g.firstChild.ownerDocument === d;
      box.appendChild(g);
      const f = document.createDocumentFragment();
      f.append(document.createElement("b"), "u");
      d.body.appendChild(f);
      console.log([before, box.firstChild.ownerDocument === document,
        box.lastChild.ownerDocument === document, d.body.lastChild.ownerDocument === d,
        d.body.lastChild.previousSibling.ownerDocument === d, box.innerHTML].join());
      """)

    assert logs == [log: "true,true,true,true,true,<i></i>t"]
  end

  test "some of the kids of a fragment, and a ref in the fragment, take the path of one node" do
    {_, logs} =
      both_paths(~s(<div id="box"><b>old</b></div>), ~S"""
      const box = document.getElementById("box");
      const f = document.createDocumentFragment();
      f.append(document.createElement("i"), document.createElement("s"), "t");
      box.replaceChildren(f.firstChild);
      box.replaceChildren(f.lastChild, f.firstChild, box.firstChild);
      console.log(f.childNodes.length, box.innerHTML);
      const g = document.createDocumentFragment();
      g.append(document.createElement("a"), document.createElement("q"));
      box.insertBefore(g, g.firstChild);
      console.log(g.childNodes.length, box.innerHTML);
      """)

    assert logs == [log: "0 t<s></s><i></i>", log: "0 t<s></s><i></i><q></q><a></a>"]
  end

  test "replaceChildren of a node that is in the fragment throws at that node" do
    {_, logs} =
      both_paths(~s(<div id="box"></div>), ~S"""
      const f = document.createDocumentFragment();
      const inner = document.createElement("div");
      f.append(document.createElement("p"), inner, "t");
      try { inner.replaceChildren(...f.childNodes); console.log("no throw"); }
      catch (e) { console.log(e.message); }
      console.log(f.childNodes.length, inner.childNodes.length, inner.parentNode === f);
      """)

    assert logs == [log: "The new child element contains the parent.", log: "2 1 true"]
  end

  test "a shadow root, a template and a fragment parent on both paths" do
    {_, logs} =
      both_paths(
        ~s(<div id="host"><span slot="a">A</span></div><template id="t"></template>),
        ~S"""
        const host = document.getElementById("host");
        const sr = host.attachShadow({mode: "open"});
        sr.innerHTML = '<p data-id="1">x</p><slot name="a"></slot><slot id="d"></slot>';
        host.innerHTML = '<i slot="a">1</i><u>3</u>';
        sr.querySelector("slot").innerHTML = "<em>fallback</em>";
        sr.firstChild.outerHTML = "<h1>a</h1><h2>b</h2>";
        const t = document.getElementById("t");
        t.innerHTML = '<div id="x" class="a b">y<template><i>q</i></template></div>';
        t.content.firstChild.insertAdjacentHTML("afterbegin", "<b>0</b>");
        document.body.appendChild(t.content.cloneNode(true));
        const f = document.createDocumentFragment();
        const a = f.appendChild(document.createElement("a"));
        f.append("z");
        a.outerHTML = "<b>1</b><b>2</b>";
        document.body.append(f);
        console.log([sr.innerHTML, sr.firstChild.isConnected, t.content.childNodes.length,
          document.getElementById("x").parentNode === document.body, f.childNodes.length,
          document.querySelectorAll(".a").length, document.body.lastChild.textContent].join());
        """
      )

    assert logs == [
             log:
               "<h1>a</h1><h2>b</h2><slot name=\"a\"><em>fallback</em></slot><slot id=\"d\"></slot>,true,1,true,0,1,z"
           ]
  end

  test "the move of a fragment marks the tree of the main document and of a frame" do
    {pid, [], []} = start(~s(<div id="box"></div><iframe id="fr" srcdoc="<p>a</p>"></iframe>), "")
    Runtime.flush(pid)

    r =
      Runtime.eval(pid, ~S"""
      const d = document.getElementById("fr").contentDocument;
      d.body.innerHTML = '<p id="x" data-id="1">x</p><p>y</p>';
      window.f = document.createDocumentFragment();
      f.append(document.createElement("i"), "t");
      window.g = d.createDocumentFragment();
      g.append(d.createElement("i"), "t");
      d.body.innerHTML.length
      """)

    assert for({:result, t} <- r.console, do: t) == ["35"]
    assert r.dirty
    # (the reply of each call takes the marks away)
    assert Runtime.eval(pid, "1").dirty == false
    assert Runtime.eval(pid, ~s{document.getElementById("box").appendChild(f); 1}).dirty
    assert Runtime.eval(pid, "1").dirty == false

    r =
      Runtime.eval(pid, ~s{document.getElementById("fr").contentDocument.body.appendChild(g); 1})

    Runtime.stop(pid)
    assert r.dirty
  end

  # A node of parsed HTML has the fields that `new_node/1` gives (the batch tests compare two
  # paths that both make nodes this way, so they do not see a wrong field)
  test "a node of parsed HTML has the fields of a new node and its class tokens" do
    # (not in the document: the reply gives numbers to new elements of the document)
    {pid, [], []} =
      start("", ~S"""
      document.createElement("div").innerHTML = '<p class="a  b" data-x="1">t</p>';
      """)

    s = state(pid)
    Runtime.stop(pid)
    [{nid, p}] = for {nid, %{tag: "p"} = n} <- s.nodes, do: {nid, n}
    [t] = p.kids

    assert Map.delete(p, :kids) == %{
             id: nid,
             kind: :element,
             tag: "p",
             attrs: [{"class", "a  b"}, {"data-x", "1"}],
             internal: [],
             props: %{},
             parent: p.parent,
             text: "",
             content: nil,
             shost: nil,
             shadow: nil,
             doc: s.nodes[p.parent].doc,
             cls: {"a  b", ["a", "b"]}
           }

    assert s.nodes[t] == %{
             id: t,
             kind: :text,
             tag: nil,
             attrs: [],
             internal: [],
             props: %{},
             kids: [],
             parent: nid,
             text: "t",
             content: nil,
             shost: nil,
             shadow: nil,
             doc: p.doc
           }
  end

  # Parsed HTML with no `<template>` is made on a small state (`build_list_fast/3`), HTML with
  # one by `build_list/3`. A template at the end of the HTML makes the second path make the same
  # nodes first: they must have the same ids, fields, indexes and counts.
  test "parsed HTML with and without a template gives the same nodes" do
    html =
      ~S|<li id="a" class="x  y" data-id="0" @z="1" @click="go()">t<!-- c --><b>1</b></li>\n| <>
        ~S|<li data-id="1"><i id="a">2</i><!--d--></li>text<iframe></iframe><svg><circle r="1"/></svg>|

    [a, b] =
      for tail <- ["", "<template></template>"] do
        # (the box is not in the document: the reply gives numbers to new elements of the
        # document, and the iframe does not load)
        {pid, [], []} =
          start("", ~S"""
          document.querySelector('[data-id="0"]');
          window.box = document.createElement("ul");
          """)

        Runtime.eval(pid, "box.innerHTML = '#{html}' + '#{tail}'; 1")
        s = state(pid)
        Runtime.stop(pid)
        s
      end

    assert_indexes(a)
    assert_indexes(b)
    assert length(a.ids["a"]) == 2
    assert Map.keys(a.aidx["data-id"]) == ["0", "1"]
    # (the template and its content)
    assert b.next == a.next + 2
    assert {b.ids, b.aidx} == {a.ids, a.aidx}
    assert map_size(b.iframes) == map_size(a.iframes) and map_size(a.iframes) > 0
    # (the template: 4 writes as it is made, 2 as it goes into the fragment, 4 as it moves)
    assert b.rev == a.rev + 10
    # (only the kids of the box are not the same)
    [box] = for {nid, n} <- a.nodes, b.nodes[nid] != n, do: nid
    assert b.nodes[box].kids == a.nodes[box].kids ++ [a.next]
    assert b.nodes[a.next].tag == "template"
  end

  test "a template below other elements in innerHTML keeps its content apart" do
    {logs, errors} =
      run(~s(<div id="box"></div>), ~S"""
      const box = document.getElementById("box");
      box.innerHTML = '<div><p><template id="t"><b id="x" class="k">t</b></template></p></div>';
      const t = document.getElementById("t");
      console.log([document.getElementById("x"), box.querySelectorAll("b").length,
        box.getElementsByTagName("b").length, document.getElementsByClassName("k").length,
        t.childNodes.length, t.content.firstChild.id, t.content.firstChild.parentNode === t.content,
        t.innerHTML].join());
      """)

    assert errors == []
    assert logs == [~S|,0,0,0,0,x,true,<b id="x" class="k">t</b>|]
  end

  # The counts that one `innerHTML` adds, as one node at a time gives them: the fragment and
  # each node are new (`next`); `rev` counts each write of a node.
  test "innerHTML adds the same counts as one node at a time" do
    # (the nodes are not in the document: the reply gives numbers to new elements of the
    # document, and that adds to `rev`)
    {pid, [], []} =
      start("", ~S"""
      window.box = document.createElement("div");
      window.lone = document.createElement("p");
      document.createElement("div").append(lone);
      """)

    s0 = state(pid)

    r =
      Runtime.eval(pid, ~S"""
      box.innerHTML = '<p a="1">x</p>text<template><b>t</b></template>';
      1
      """)

    s1 = state(pid)

    r2 =
      Runtime.eval(pid, ~S"""
      lone.insertAdjacentHTML("afterbegin", "<i>1</i><i>2</i>"); 2
      """)

    s2 = state(pid)
    # (HTML for a place that is not there: the nodes are made, and nothing moves)
    r3 =
      Runtime.eval(
        pid,
        ~s{document.createElement("p").insertAdjacentHTML("afterend", "<b>x</b>")}
      )

    Runtime.stop(pid)
    assert r.dirty and r2.dirty and r3.dirty
    # (the fragment of the parse, p, "x", "text", template, its content, b and "t")
    assert s1.next - s0.next == 8
    # (the parse: 1 for the fragment, 3 for p and "x", 1 for "text", 8 for the template, 2
    # for each of the 3 top nodes as they go into the fragment; then 1 for the kids of box,
    # and 4 for each top node as it moves into box)
    assert s1.rev - s0.rev == 19 + 1 + 12
    assert s2.rev - s1.rev == 1 + 2 * 3 + 2 * 2 + 2 * 4
  end
end
