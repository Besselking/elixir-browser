defmodule Browser.JS.ClassTokensTest do
  @moduledoc """
  The tokens of the `class` attribute that `Browser.JS.DOM` keeps on each element. A script
  changes the classes in all the ways that a page can, and after each change it compares the
  class selectors and `classList` with the tokens of `getAttribute("class")`.
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
  const toks = ["a", "b", "c", "on", "x-y"];
  const pick = (a) => a[rnd(a.length)];
  const space = () => pick([" ", "  ", "\t", "\n", " \n "]);
  const value = () => { let v = rnd(3) ? "" : space(); for (let i = rnd(4); i > 0; i--) v += pick(toks) + space(); return v; };
  const els = Array.from(document.body.querySelectorAll("*")).filter((e) => e.tagName !== "SCRIPT");
  const bad = [];

  const tokensOf = (e) => (e.getAttribute("class") || "").split(/[ \t\n\r\f]+/).filter((t) => t !== "");

  function walk(root, t, all) {
    for (let c = root.firstChild; c; c = c.nextSibling) {
      if (c.nodeType === 1) {
        if (tokensOf(c).includes(t)) all.push(c);
        walk(c, t, all);
      }
    }
    return all;
  }

  function check(step, op) {
    for (const t of toks) {
      const all = walk(document.body, t, []);
      const q = document.body.querySelectorAll("." + t);
      if (q.length !== all.length || all.some((e, i) => q[i] !== e)) bad.push(step + " " + op + " querySelectorAll ." + t);
      if (document.body.querySelector("." + t) !== (all[0] || null)) bad.push(step + " " + op + " querySelector ." + t);
      const both = document.body.querySelectorAll("." + t + ".a");
      if (both.length !== all.filter((e) => tokensOf(e).includes("a")).length) bad.push(step + " " + op + " compound ." + t);
    }
    for (const e of els) {
      const tk = tokensOf(e);
      if (e.classList.length !== tk.length) bad.push(step + " " + op + " length " + JSON.stringify(e.getAttribute("class")));
      for (const t of toks) {
        if (e.classList.contains(t) !== tk.includes(t)) bad.push(step + " " + op + " contains " + t);
        if (e.matches("." + t) !== tk.includes(t)) bad.push(step + " " + op + " matches " + t);
      }
      if (tk.length && e.classList[0] !== tk[0]) bad.push(step + " " + op + " item 0");
    }
  }

  const ops = [
    function className() { pick(els).className = value(); },
    function setAttr() { pick(els).setAttribute(rnd(3) ? "class" : "CLASS", value()); },
    function removeAttr() { pick(els).removeAttribute("class"); },
    function add() { pick(els).classList.add(pick(toks)); },
    function remove() { pick(els).classList.remove(pick(toks)); },
    function toggle() { pick(els).classList.toggle(pick(toks)); },
    function replace() { pick(els).classList.replace(pick(toks), pick(toks)); },
    function listValue() { pick(els).classList.value = value(); },
    function innerHTML() {
      const e = pick(els);
      if (e.tagName !== "BODY") {
        e.innerHTML = '<i class="' + value() + '"></i><b class="' + value() + '">x</b>';
        for (const k of e.querySelectorAll("*")) els.push(k);
      }
    },
    function clone() {
      const c = pick(els).cloneNode(true);
      if (c.tagName !== "BODY") {
        els.push(c);
        for (const k of c.querySelectorAll("*")) els.push(k);
        pick(els).appendChild(c);
      }
    },
    function attributeNode() {
      const e = pick(els), a = e.getAttributeNode && e.getAttributeNode("class");
      if (a) a.value = value();
    }
  ];

  check(0, "start");
  for (let step = 1; step <= 250; step++) {
    const op = pick(ops);
    // (an insert into its own subtree throws, and the tree does not change)
    try { op(); } catch (e) { if (!/contains the parent/.test(e.message)) bad.push(step + " " + op.name + " threw " + e.message); }
    check(step, op.name);
  }
  console.log(bad.length ? bad.slice(0, 5).join("; ") : "ok " + els.length);
  """

  @body ~S"""
  <div class="a b"><p class="c">x</p><p class=" on  a ">y</p><span>z</span></div>
  <section class="x-y"><em class="b"></em></section>
  """

  for seed <- [3, 11, 500, 7777] do
    test "class selectors and classList follow every change of the classes (seed #{seed})" do
      {logs, errors} = run(String.replace(@oracle, "SEED", to_string(unquote(seed))), @body)
      assert errors == []
      assert [line] = logs
      assert line =~ ~r/^ok \d+$/
    end
  end
end
