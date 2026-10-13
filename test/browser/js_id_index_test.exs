defmodule Browser.JS.IdIndexTest do
  @moduledoc """
  The oracle of the index of the ids (`st().ids` of `Browser.JS.DOM`). A script makes random
  changes to the tree, and after each change it compares each search by id with a walk of
  the tree in JavaScript: `getElementById` of the document, of the fragments and of the
  shadow roots, `querySelector` and `querySelectorAll` with an id, and the named access
  `window[id]`.
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

  @oracle ~S"""
  let seed = SEED;
  const rnd = (n) => { seed = (seed * 1103515245 + 12345) % 2147483648; return seed % n; };
  const ids = ["q0", "q1", "q2", "q3", "q4", "q5", "q6"];
  const pick = (a) => a[rnd(a.length)];
  const els = Array.from(document.querySelectorAll("*")).filter((e) => e.tagName !== "SCRIPT");
  const roots = [document];
  const bad = [];

  // the first element below `root` in tree order with the id, by a walk of the tree
  function walk(root, id, all) {
    for (let c = root.firstChild; c; c = c.nextSibling) {
      if (c.nodeType === 1) {
        if (c.getAttribute("id") === id) all.push(c);
        walk(c, id, all);
      }
    }
    return all;
  }

  function check(step, op) {
    for (const root of roots) {
      for (const id of ids) {
        const all = walk(root, id, []);
        const first = all.length ? all[0] : null;
        const got = root.getElementById(id);
        if (got !== first) bad.push(step + " " + op + " getElementById " + id);
        if (root.querySelector("#" + id) !== first) bad.push(step + " " + op + " querySelector " + id);
        const qa = root.querySelectorAll("div#" + id + ", #" + id);
        const qb = root.querySelectorAll("#" + id);
        if (qb.length !== all.length || all.some((e, i) => qb[i] !== e))
          bad.push(step + " " + op + " querySelectorAll " + id);
        if (qa.length !== all.length) bad.push(step + " " + op + " list " + id);
        if (root === document && window[id] !== (first || undefined))
          bad.push(step + " " + op + " window " + id);
      }
    }
  }

  function make() {
    const e = document.createElement(pick(["div", "span", "p", "section"]));
    if (rnd(2)) e.id = pick(ids);
    els.push(e);
    return e;
  }

  const ops = [
    function setId() { pick(els).setAttribute(rnd(4) ? "id" : "ID", pick(ids)); },
    function removeId() { pick(els).removeAttribute("id"); },
    function idProp() { pick(els).id = pick(ids); },
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
      e.innerHTML = "<p id=" + pick(ids) + "><span id=" + pick(ids) + "></span></p><i id=" + pick(ids) + "></i>";
      for (const k of e.querySelectorAll("*")) els.push(k);
    },
    function outerHTML() {
      const e = pick(els);
      if (e.parentNode && e.parentNode.nodeType === 1) e.outerHTML = "<b id=" + pick(ids) + ">o</b>";
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
      const h = pick(els);
      if (!h.shadowRoot && h.tagName !== "P") {
        const s = h.attachShadow({ mode: "open" });
        s.innerHTML = "<div id=" + pick(ids) + "><em id=" + pick(ids) + "></em></div>";
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
      t.innerHTML = "<div id=" + pick(ids) + "></div>";
      roots.push(t.content);
      document.body.appendChild(t);
    }
  ];

  check(0, "start");
  for (let step = 1; step <= 300; step++) {
    const op = pick(ops);
    // (an insert into its own subtree throws, and the tree does not change)
    try { op(); } catch (e) { if (!/contains the parent/.test(e.message)) bad.push(step + " " + op.name + " threw " + e.message); }
    check(step, op.name);
  }
  console.log(bad.length ? bad.slice(0, 5).join("; ") : "ok " + roots.length);
  """

  @body ~S"""
  <div id=q0><p id=q1>a</p><p id=q1>b</p><section><span id=q2></span></section></div>
  <div><span id=q3></span><div id=q0></div></div>
  """

  for seed <- [1, 7, 42, 2024, 99_991] do
    test "the searches by id agree with a walk of the tree after random changes (seed #{seed})" do
      {logs, errors} = run(String.replace(@oracle, "SEED", to_string(unquote(seed))), @body)
      assert errors == []
      assert [line] = logs
      assert line =~ ~r/^ok \d+$/
    end
  end

  test "document.write adds elements that the index finds" do
    {logs, errors} =
      run(
        ~S"""
        document.write("<p id=w1>one</p><p id=w2>two</p>");
        console.log(document.getElementById("w1").textContent, document.getElementById("old").id);
        setTimeout(() => {}, 0);
        """,
        "<div id=old></div>"
      )

    assert errors == []
    assert logs == ["one old"]
  end

  test "the first element in tree order wins when two elements have the same id" do
    {logs, errors} =
      run(
        ~S"""
        const a = document.getElementById("d");
        const late = document.createElement("i");
        late.id = "d";
        document.body.insertBefore(late, document.body.firstChild);
        console.log(document.getElementById("d") === late, document.querySelectorAll("#d").length);
        late.remove();
        console.log(document.getElementById("d") === a, document.getElementById("d").textContent);
        a.id = "e";
        console.log(document.getElementById("d").textContent, document.getElementById(""));
        """,
        "<p id=d>1</p><p><b id=d>2</b></p>"
      )

    assert errors == []
    assert logs == ["true 3", "true 1", "2 null"]
  end
end
