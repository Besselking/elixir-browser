defmodule Browser.JS.DOMApisTest do
  use ExUnit.Case, async: true
  alias Browser.JS.Runtime

  # runs the page's scripts and what timers and messages add afterwards
  defp run(script, body \\ "") do
    {raw, _} =
      "<body>#{body}<script>#{script}</script></body>"
      |> Browser.HTML.parse()
      |> Browser.Forms.index()

    info = %{url: "http://t.test/", width: 800, height: 600, fetch: fn _ -> {:error, "404"} end}
    pid = Runtime.start(raw, info)
    r = Runtime.run_scripts(pid)
    lines = for({:log, t} <- r.console, do: t) ++ collect(pid)
    Runtime.stop(pid)
    {lines, for({:error, t} <- r.console, do: t)}
  end

  defp collect(pid) do
    receive do
      {:js_async, ^pid, reply} -> for({:log, t} <- reply.console, do: t) ++ collect(pid)
    after
      150 -> for {:log, t} <- Runtime.flush(pid).console, do: t
    end
  end

  test "MessageChannel can be constructed and delivers messages in a later task" do
    {logs, errors} =
      run(~S"""
      const mc = new MessageChannel();
      mc.port1.onmessage = (e) => console.log("got", JSON.stringify(e.data), e instanceof MessageEvent);
      mc.port2.postMessage({ a: [1, 2] });
      console.log("sent");
      const c2 = new MessageChannel();
      c2.port1.addEventListener("message", (e) => console.log("listener", e.data));
      c2.port2.postMessage("late");
      c2.port1.start();
      """)

    assert errors == []
    assert logs == ["sent", "got {\"a\":[1,2]} true", "listener late"]
  end

  test "TreeWalker and NodeIterator walk in document order and honour filters" do
    {logs, errors} =
      run(
        ~S"""
        const root = document.getElementById("a");
        const w = document.createTreeWalker(root, NodeFilter.SHOW_ELEMENT);
        const tags = [];
        let n;
        while ((n = w.nextNode())) tags.push(n.tagName);
        console.log(tags.join());
        const skipB = document.createTreeWalker(root, NodeFilter.SHOW_ELEMENT, {
          acceptNode: (x) => (x.tagName === "SPAN" ? NodeFilter.FILTER_REJECT : NodeFilter.FILTER_ACCEPT),
        });
        const t2 = [];
        while ((n = skipB.nextNode())) t2.push(n.tagName);
        console.log(t2.join());
        const it = document.createNodeIterator(root, NodeFilter.SHOW_TEXT);
        const texts = [];
        while ((n = it.nextNode())) texts.push(n.data);
        console.log(texts.join("|"));
        const back = [];
        while ((n = it.previousNode())) back.push(n.data);
        console.log(back.join("|"));
        w.currentNode = root;
        console.log(w.firstChild() && w.currentNode.tagName, w.nextSibling() && w.currentNode.tagName);
        """,
        "<div id=a><p>one</p><!--c--><span>two<b>x</b></span></div>"
      )

    assert errors == []
    assert logs == ["P,SPAN,B", "P", "one|two|x", "x|two|one", "P SPAN"]
  end

  test "constructable style sheets keep their rules, and can be adopted" do
    {logs, errors} =
      run(~S"""
      const s = new CSSStyleSheet();
      s.replaceSync("a { color: red } /* c */ b { margin: 0 }");
      console.log(s.cssRules.length, s.cssRules[0].selectorText);
      s.insertRule("i { top: 0 }", 0);
      s.deleteRule(1);
      console.log(s.cssRules.length, s.cssRules[0].selectorText, s.cssRules[1].selectorText);
      document.adoptedStyleSheets = [s];
      console.log(document.adoptedStyleSheets.length, document.adoptedStyleSheets[0] === s);
      s.replace("p {}").then((x) => console.log("replaced", x === s, x.cssRules.length));
      """)

    assert errors == []
    assert logs == ["2 a", "2 i b", "1 true", "replaced true 1"]
  end

  test "more event constructors and Error.captureStackTrace" do
    {logs, errors} =
      run(~S"""
      const w = new WheelEvent("wheel", { deltaY: -10, clientX: 3, bubbles: true });
      console.log(w.type, w.deltaY, w.clientX, w.bubbles, w instanceof Event);
      class MyError extends Error { constructor(m) { super(m); Error.captureStackTrace(this, MyError); } }
      console.log(new MyError("x").message, typeof new MyError("x").stack);
      """)

    assert errors == []
    assert logs == ["wheel -10 3 true true", "x string"]
  end

  test "Object.prototype.toString names the DOM classes" do
    {logs, errors} =
      run(
        ~S"""
        const t = (x) => Object.prototype.toString.call(x);
        console.log(t(document.getElementById("b")), t(document.getElementById("d")), t(document.body.firstChild), t(document));
        console.log(t(document.createElement("nav")), t(new Event("x")));
        """,
        "<button id=b></button><div id=d></div>"
      )

    assert errors == []

    assert logs == [
             "[object HTMLButtonElement] [object HTMLDivElement] [object HTMLButtonElement] [object HTMLDocument]",
             "[object HTMLElement] [object Event]"
           ]
  end

  test "a template keeps its content in a fragment of its own" do
    {logs, errors} =
      run(
        ~S"""
        const t = document.getElementById("t");
        console.log(t.childNodes.length, t.content.childNodes.length, t.content === t.content);
        console.log(document.querySelectorAll("p").length, t.content.querySelectorAll("p").length);
        document.body.appendChild(document.importNode(t.content, true));
        console.log(document.querySelectorAll("p").length, t.innerHTML);
        const made = document.createElement("template");
        made.innerHTML = "<b>x</b><i>y</i>";
        console.log(made.content.childNodes.length, made.innerHTML, made.cloneNode(true).content.firstChild.tagName);
        """,
        ~S|<template id=t><p>one</p></template>|
      )

    assert errors == []
    assert logs == ["0 1 true", "0 1", "1 <p>one</p>", "2 <b>x</b><i>y</i> B"]
  end

  test "scripts inside a template stay quiet" do
    {logs, errors} =
      run(
        ~S"""
        console.log("main");
        console.log(document.getElementById("t").content.querySelectorAll("script").length);
        """,
        ~S|<template id=t><script>console.log("template script")</script></template>|
      )

    assert errors == []
    assert logs == ["main", "1"]
  end

  test "classList, style and URLSearchParams can be iterated; a shadow root has innerHTML" do
    {logs, errors} =
      run(
        ~S"""
        const el = document.getElementById("a");
        el.style.color = "red";
        const root = el.attachShadow({ mode: "open" });
        root.innerHTML = "<p id=q>hi</p><p></p>";
        console.log([...el.classList].join("|"), el.classList[1], [...el.style].join("|"),
          [...new URLSearchParams("a=1&b=2")].join("|"), root.querySelectorAll("p").length,
          root.getElementById("q").textContent, root.innerHTML);
        """,
        ~S|<div id=a class="x y"></div>|
      )

    assert errors == []
    assert logs == ["x|y y color a,1|b,2 2 hi <p id=\"q\">hi</p><p></p>"]
  end
end
