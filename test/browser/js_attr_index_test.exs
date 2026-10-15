defmodule Browser.JS.AttrIndexTest do
  @moduledoc """
  The oracle of the index of the attribute values (`st().aidx` of `Browser.JS.DOM`). A script
  makes random changes to the tree, and after each change it compares each search with a
  `[name="v"]` selector with a walk of the tree in JavaScript: `querySelector` and
  `querySelectorAll` of the document, of a frame's document, of the fragments, of the shadow
  roots, of the contents of templates and of elements.
  """
  use ExUnit.Case, async: true
  alias Browser.JS.Runtime

  defp run(script, body) do
    {raw, _} =
      "<body>#{body}<script>#{script}</script></body>"
      |> Browser.HTML.parse()
      |> Browser.Forms.index()

    info = %{url: "http://t.test/", width: 800, height: 600, fetch: fn _ -> {:error, "404"} end}
    pid = Runtime.start(raw, info)
    r = Runtime.run_scripts(pid)
    Runtime.stop(pid)
    {for({:log, t} <- r.console, do: t), for({:error, t} <- r.console, do: t)}
  end

  # (six names: the index has room for four of them, the searches with the other two walk)
  @oracle ~S"""
  let seed = SEED;
  const rnd = (n) => { seed = (seed * 1103515245 + 12345) % 2147483648; return seed % n; };
  const names = ["data-k", "data-j", "name", "title", "lang", "dir"];
  const vals = ["v0", "v1", "v2", ""];
  const pick = (a) => a[rnd(a.length)];
  const els = Array.from(document.body.querySelectorAll("*")).filter((e) => e.tagName !== "SCRIPT");
  const roots = [document];
  const bad = [];
  let frame = null, frameEls = [];

  // the elements below `root` in tree order with the value, by a walk of the tree
  function walk(root, name, v, all) {
    for (let c = root.firstChild; c; c = c.nextSibling) {
      if (c.nodeType === 1) {
        if (c.getAttribute(name) === v) all.push(c);
        walk(c, name, v, all);
      }
    }
    return all;
  }

  function same(list, all) {
    return list.length === all.length && all.every((e, i) => list[i] === e);
  }

  function checkRoot(step, op, root) {
    for (const name of names) {
      for (const v of vals) {
        const all = walk(root, name, v, []);
        const first = all.length ? all[0] : null;
        const sel = "[" + name + '="' + v + '"]';
        if (root.querySelector(sel) !== first) bad.push(step + " " + op + " querySelector " + sel);
        if (!same(root.querySelectorAll(sel), all)) bad.push(step + " " + op + " querySelectorAll " + sel);
        const divs = all.filter((e) => e.tagName === "DIV");
        if (!same(root.querySelectorAll("div" + sel), divs)) bad.push(step + " " + op + " div " + sel);
        const inP = all.filter((e) => e.parentNode && e.parentNode.tagName === "P");
        if (!same(root.querySelectorAll("p > " + sel), inP)) bad.push(step + " " + op + " p > " + sel);
        if (root.querySelectorAll(sel + ", " + sel).length !== all.length)
          bad.push(step + " " + op + " list " + sel);
      }
    }
  }

  function check(step, op) {
    for (const root of roots) checkRoot(step, op, root);
    checkRoot(step, op, pick(els));
  }

  // an element of this document (an element that went to the frame's document has no
  // `dataset` and cannot be a shadow host here, a gap of its own)
  function pickMain() {
    for (let i = 0; i < 50; i++) { const e = pick(els); if (e.ownerDocument === document) return e; }
    return document.body;
  }

  function make() {
    const e = document.createElement(pick(["div", "span", "p", "section"]));
    if (rnd(2)) e.setAttribute(pick(names), pick(vals));
    els.push(e);
    return e;
  }

  function markup() {
    const a = () => " " + pick(names) + "=" + JSON.stringify(pick(vals));
    return "<p" + a() + "><span" + a() + "></span></p><div" + a() + a() + "></div>";
  }

  const ops = [
    function setAttr() { pick(els).setAttribute(pick(names), pick(vals)); },
    function setUpper() { pick(els).setAttribute(pick(names).toUpperCase(), pick(vals)); },
    function removeAttr() { pick(els).removeAttribute(pick(names)); },
    function toggleAttr() { pick(els).toggleAttribute(pick(names)); },
    function dataset() { pickMain().dataset[pick(["k", "j"])] = pick(vals); },
    function datasetDelete() { delete pickMain().dataset[pick(["k", "j"])]; },
    function prop() { const e = pick(els); e.title = pick(vals); e.lang = pick(vals); },
    function append() { pick(els).appendChild(rnd(3) ? pick(els) : make()); },
    function insertBefore() {
      const p = pick(els), ref = p.firstChild;
      p.insertBefore(rnd(2) ? pick(els) : make(), ref);
    },
    function remove() { pick(els).remove(); },
    function replaceChild() {
      const p = pick(els);
      if (p.firstChild) p.replaceChild(make(), p.firstChild);
    },
    function innerHTML() {
      const e = pick(els);
      e.innerHTML = markup();
      for (const k of e.querySelectorAll("*")) els.push(k);
    },
    function outerHTML() {
      const e = pick(els);
      if (e.parentNode && e.parentNode.nodeType === 1)
        e.outerHTML = "<b " + pick(names) + "=" + pick(vals) + ">o</b>";
    },
    function clone() {
      const c = pick(els).cloneNode(true);
      els.push(c);
      for (const k of c.querySelectorAll("*")) els.push(k);
      pick(els).appendChild(c);
    },
    function toBody() { document.body.appendChild(pick(els)); },
    function textContent() { pick(els).textContent = "t"; },
    function shadow() {
      const h = pickMain();
      if (!h.shadowRoot && h.tagName !== "P" && h !== document.body) {
        const s = h.attachShadow({ mode: "open" });
        s.innerHTML = markup();
        roots.push(s);
        for (const k of s.querySelectorAll("*")) els.push(k);
      }
    },
    function fragment() {
      const f = document.createDocumentFragment();
      f.appendChild(make());
      f.appendChild(pick(els));
      roots.push(f);
    },
    function fragmentIn() {
      const f = pick(roots);
      if (f !== document && f.nodeType === 11 && !f.host) pick(els).appendChild(f);
    },
    function template() {
      const t = document.createElement("template");
      t.innerHTML = markup();
      roots.push(t.content);
      document.body.appendChild(t);
    },
    function adopt() {
      if (!frame) return;
      const d = frame.contentDocument;
      if (rnd(2)) {
        const e = pick(els);
        if (!e.contains(frame)) d.body.appendChild(e);
      } else if (frameEls.length) {
        pick(els).appendChild(pick(frameEls));
      }
    },
    function frameMarkup() {
      if (!frame) return;
      const d = frame.contentDocument;
      const e = d.createElement("div");
      e.innerHTML = markup();
      d.body.appendChild(e);
      for (const k of e.querySelectorAll("*")) frameEls.push(k);
      frameEls.push(e);
    },
    function dropFrame() {
      if (!frame) return;
      const d = frame.contentDocument;
      frame.remove();
      roots.splice(roots.indexOf(d), 1);
      // (the elements of the frame's document go with it)
      for (const e of Array.from(els)) if (e.ownerDocument === d) els.splice(els.indexOf(e), 1);
      frame = null;
      frameEls = [];
      newFrame();
    }
  ];

  function newFrame() {
    frame = document.createElement("iframe");
    frame.srcdoc = "<body><p data-k=v1 name=v2>f</p></body>";
    document.body.appendChild(frame);
    roots.push(frame.contentDocument);
  }

  newFrame();
  check(0, "start");
  for (let step = 1; step <= 200; step++) {
    const op = pick(ops);
    // (an insert into its own subtree throws, and the tree does not change)
    try { op(); } catch (e) { if (!/contains the parent/.test(e.message)) bad.push(step + " " + op.name + " threw " + e.message); }
    check(step, op.name);
  }
  console.log(bad.length ? bad.slice(0, 5).join("; ") : "ok " + roots.length);
  """

  @body ~S"""
  <div data-k=v0 name=v1><p data-k=v1>a</p><p data-j=v1 title="">b</p><section><span data-k=v0 lang=v2></span></section></div>
  <div><span dir=v3></span><div data-k=v0 data-j=v0></div></div>
  """

  for seed <- [1, 7, 42, 2024, 99_991] do
    test "the searches by attribute value agree with a walk of the tree after random changes (seed #{seed})" do
      {logs, errors} = run(String.replace(@oracle, "SEED", to_string(unquote(seed))), @body)
      assert errors == []
      assert [line] = logs
      assert line =~ ~r/^ok \d+$/
    end
  end

  test "a list that the page draws again and again gives the element that is in the tree" do
    {logs, errors} =
      run(
        ~S"""
        const ul = document.getElementById("list");
        const draw = (n) => {
          let h = "";
          for (let i = 0; i < n; i++) h += '<li data-id="' + i + '"><i data-id="x"></i></li>';
          ul.innerHTML = h;
        };
        for (let n = 1; n <= 30; n++) draw(n);
        const li = document.querySelector('[data-id="3"]');
        console.log(li === ul.children[3], li.parentNode === ul);
        console.log(document.querySelectorAll('[data-id="x"]').length, ul.querySelector('[data-id="x"]') === ul.children[0].firstChild);
        // (the other operators do not look in the index)
        console.log(document.querySelectorAll('[data-id^="1"]').length, document.querySelectorAll('[data-id~="x"]').length);
        ul.children[3].remove();
        console.log(document.querySelector('[data-id="3"]'), li.querySelector('[data-id="x"]') === li.firstChild);
        ul.children[5].setAttribute("data-id", "4");
        console.log(document.querySelectorAll('[data-id="4"]').length, document.querySelector('[data-id="4"]') === ul.children[3]);
        """,
        "<ul id=list></ul>"
      )

    assert errors == []
    assert logs == ["true true", "30 true", "11 30", "null true", "2 true"]
  end

  # A write of a node that cannot be in the index (a text node, an element with no indexed
  # name, an element with no parent) does not fold over the names. The index term stays the
  # same term, not only an equal one.
  test "a write of a node with no indexed attribute keeps the index term" do
    Task.async(fn ->
      {raw, _} =
        ~S|<body><ul id=list><li data-id=a>a</li></ul></body>|
        |> Browser.HTML.parse()
        |> Browser.Forms.index()

      Runtime.boot(raw, %{url: "http://t.test/", width: 800, height: 600})

      js = fn source ->
        {:ok, program} = Browser.JS.Parser.parse(source)
        Browser.JS.Interp.run_program(program)
      end

      js.(~S|document.querySelector('[data-id="a"]'); document.querySelector('[title="t"]');|)
      aidx = Process.get(:dom).aidx
      assert Map.keys(aidx) |> Enum.sort() == ["data-id", "title"]

      js.(~S"""
      const ul = document.getElementById("list");
      const li = document.createElement("li");
      li.className = "x";
      li.appendChild(document.createTextNode("t"));
      ul.appendChild(li);
      li.setAttribute("lang", "en");
      ul.firstChild.textContent = "b";
      window.d = document.createElement("div");
      d.setAttribute("data-id", "b");
      """)

      assert :erts_debug.same(Process.get(:dom).aidx, aidx)

      # (an element with an indexed name that goes into the tree changes it)
      js.(~S|document.body.appendChild(window.d)|)
      refute :erts_debug.same(Process.get(:dom).aidx, aidx)
      assert Map.keys(Process.get(:dom).aidx["data-id"]) |> Enum.sort() == ["a", "b"]

      # (an element that leaves the tree, or loses its indexed name, leaves the index)
      js.(
        ~S|window.d.remove(); document.querySelector('[data-id="a"]').removeAttribute("data-id")|
      )

      assert Process.get(:dom).aidx["data-id"] == %{}
    end)
    |> Task.await(30_000)
  end
end
