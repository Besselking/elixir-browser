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
end
