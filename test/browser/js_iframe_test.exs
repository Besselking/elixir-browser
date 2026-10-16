defmodule Browser.JS.IframeTest do
  use ExUnit.Case, async: true
  alias Browser.JS.Runtime

  defp run(script, body \\ "", fetch \\ fn _ -> {:error, "404"} end) do
    {raw, _} =
      "<body>#{body}<script>#{script}</script></body>"
      |> Browser.HTML.parse()
      |> Browser.Forms.index()

    info = %{url: "http://t.test/", width: 800, height: 600, fetch: fetch}
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

  # A frame that is parsed asks the host for a prewarm layout (`Browser.JS.DOM.prewarm_layout/0`).
  # The request has no reference: no script waits for it, and the host does not answer it.
  test "a frame asks for a prewarm layout with no reference" do
    {raw, _} =
      ~S|<body><iframe srcdoc="<p id=x>hi</p>"></iframe></body>|
      |> Browser.HTML.parse()
      |> Browser.Forms.index()

    info = %{
      url: "http://t.test/",
      width: 800,
      height: 600,
      layout_now: true,
      fetch: fn _ -> {:error, "404"} end
    }

    pid = Runtime.start(raw, info)
    Runtime.run_scripts(pid)
    # (the frame can send its request after `run_scripts/1` returns)
    assert_receive {:layout_now, ^pid, nil, [_ | _]}, 2_000
    {:messages, msgs} = Process.info(self(), :messages)
    assert for({:layout_now, ^pid, ref, _} <- msgs, ref != nil, do: ref) == []
    Runtime.stop(pid)
  end

  test "a new iframe has an empty document and loads srcdoc" do
    {logs, errors} =
      run(~S"""
      const f = document.createElement("iframe");
      f.srcdoc = "<body><p id=x>hi</p><script>window.mark = 7; parent.seen = document.getElementById('x').textContent<\/script></body>";
      f.onload = () => {
        console.log("loaded", f.contentDocument.getElementById("x").textContent, f.contentWindow.mark, typeof window.mark, window.seen);
        console.log(f.contentDocument !== document, f.contentWindow.parent === window, f.contentDocument.defaultView === f.contentWindow);
      };
      console.log("blank", f.contentDocument === null);
      document.body.appendChild(f);
      console.log("blank2", f.contentDocument.body !== null);
      """)

    assert errors == []

    assert logs == [
             "blank true",
             "blank2 true",
             "loaded hi 7 undefined hi",
             "true true true"
           ]
  end

  test "the page reaches into a frame it made and builds elements there" do
    {logs, errors} =
      run(~S"""
      const f = document.createElement("iframe");
      document.body.appendChild(f);
      const d = f.contentDocument;
      const b = d.createElement("button");
      b.textContent = "go";
      b.addEventListener("click", () => console.log("clicked in frame"));
      d.body.appendChild(b);
      console.log(d.body.children.length, b.ownerDocument === d, document.body.children.length);
      b.click();
      const W = d.defaultView;
      console.log(b instanceof W.HTMLElement, W.document === d, W.location.href);
      W.setTimeout(() => console.log("frame timer", W.document === d), 0);
      """)

    assert errors == []
    assert logs == ["1 true 2", "clicked in frame", "true true about:blank", "frame timer true"]
  end

  test "an iframe with a src loads the page and its scripts" do
    fetch = fn
      "http://t.test/inner.html" ->
        {:ok,
         "<body><div id=a>inner</div><script>document.title='T'; console.log('in', location.pathname, document.title, !!document.head)</script></body>",
         "http://t.test/inner.html"}

      _ ->
        {:error, "404"}
    end

    {logs, errors} =
      run(
        ~S"""
        const f = document.getElementById("f");
        f.addEventListener("load", () => console.log("load", f.contentDocument.getElementById("a").textContent, f.contentDocument.title));
        """,
        ~S|<iframe id=f src="/inner.html"></iframe>|,
        fetch
      )

    assert errors == []
    assert logs == ["in /inner.html T true", "load inner T"]
  end

  test "removing an iframe drops its document" do
    {logs, errors} =
      run(~S"""
      const f = document.createElement("iframe");
      document.body.appendChild(f);
      const w = f.contentWindow;
      f.remove();
      console.log(f.contentWindow, document.body.children.length);
      """)

    assert errors == []
    assert logs == ["null 1"]
  end

  test "document helpers of the web API work for a frame's own document" do
    {logs, errors} =
      run(~S"""
      const f = document.createElement("iframe");
      f.srcdoc = "<form></form><form></form><script>parent.res = [document.forms.length, new Image().ownerDocument === document, new Option('a').ownerDocument === document].join()<\/script>";
      f.onload = () => console.log(window.res, document.forms.length);
      document.body.appendChild(f);
      """)

    assert errors == []
    assert logs == ["2,true,true 0"]
  end

  test "the page reads the nodes of a frame without the realm of the frame, and stays in its own" do
    {logs, errors} =
      run(
        ~S"""
        const f = document.createElement("iframe");
        f.srcdoc = "<body id=fb><canvas id=c width=120 height=40></canvas><p id=p class='a b'>hi <b>x</b></p><input id=i value=v></body>";
        f.onload = () => {
          const d = f.contentDocument, p = d.getElementById("p"), c = d.getElementById("c");
          console.log(p.parentNode === d.body, p.ownerDocument === d, p.isConnected, p.nodeName, p.tagName);
          console.log(p.firstChild.data, p.lastElementChild.localName, p.childElementCount, p.textContent);
          console.log(p.className, p.classList.length, p.id, d.getElementById("i").value, c.width, c.height);
          const ctx = c.getContext("2d");
          ctx.fillRect(0, 0, 10, 10);
          console.log(c.width, typeof ctx.fillRect, d.body.id, document.body.id, document.getElementById("p"));
          console.log(document === window.document, f.contentWindow.document === d, d.defaultView === f.contentWindow);
        };
        document.body.appendChild(f);
        """,
        "<b id=mb></b>"
      )

    assert errors == []

    assert logs == [
             "true true true P P",
             "hi  b 1 hi x",
             "a b 2 p v 120 40",
             "120 function fb  null",
             "true true true"
           ]
  end

  # The frames of a subtree that moves come from a walk of a small subtree, from a list of the
  # `<iframe>` elements for a large one, and from a walk again when the page has made many
  # `<iframe>`s. Each way loads the frames in tree order, also when an `<iframe>` that a script
  # made first comes after the other one in the tree.
  for {name, filler, extra} <- [{"small", 0, 0}, {"large", 100, 0}, {"many", 0, 17}] do
    test "iframes deep in a #{name} subtree load when it goes in and go away when it goes out" do
      {logs, errors} =
        run(~s"""
        window.order = [];
        for (let i = 0; i < #{unquote(extra)}; i++) document.createElement("iframe");
        const late = document.createElement("iframe");
        late.srcdoc = "<script>parent.order.push('late')<\\/script>";
        const div = document.createElement("div");
        div.innerHTML = "#{String.duplicate("<b></b>", unquote(filler))}<section><article><iframe srcdoc=\\"<script>parent.order.push('deep')<\\/script>\\"></iframe></article></section>";
        div.appendChild(late);
        const deep = div.querySelector("iframe");
        let round = 0;
        const loaded = () => {
          if (order.length % 2) return;
          round++;
          console.log(round, order.join(), deep.contentDocument !== null, late.contentDocument !== null);
          div.remove();
          console.log("out", deep.contentDocument, late.contentDocument);
          if (round < 2) setTimeout(() => document.body.appendChild(div), 0);
        };
        deep.onload = loaded;
        late.onload = loaded;
        console.log("in", deep.contentDocument, late.contentDocument);
        document.body.appendChild(div);
        """)

      assert errors == []

      assert logs == [
               "in null null",
               "1 deep,late true true",
               "out null null",
               "2 deep,late,deep,late true true",
               "out null null"
             ]
    end
  end

  # When a frame goes away, its nodes go out of the indexes of the ids and of the attribute
  # values, and its `<iframe>`s go out of the list of the `<iframe>`s.
  test "the indexes do not keep the nodes of a frame that went away" do
    {raw, _} =
      ~S"""
      <body><script>
      const f = document.createElement("iframe");
      f.srcdoc = "<p id=fx data-k=v>x</p><div><iframe></iframe></div>";
      f.onload = () => {
        console.log(document.querySelector('[data-k="none"]'), f.contentDocument.getElementById("fx").id);
        f.remove();
        console.log("out", f.contentDocument);
      };
      document.body.appendChild(f);
      </script></body>
      """
      |> Browser.HTML.parse()
      |> Browser.Forms.index()

    info = %{url: "http://t.test/", width: 800, height: 600, fetch: fn _ -> {:error, "404"} end}
    pid = Runtime.start(raw, info)
    r = Runtime.run_scripts(pid)
    logs = for({:log, t} <- r.console, do: t) ++ collect(pid)
    {:dictionary, dict} = Process.info(pid, :dictionary)
    Runtime.stop(pid)
    dom = Keyword.fetch!(dict, :dom)

    assert logs == ["null fx", "out null"]
    refute Map.has_key?(dom.ids, "fx")
    assert dom.aidx["data-k"] == %{}
    assert map_size(dom.iframes) == 1
    assert Enum.all?(Map.keys(dom.iframes), &Map.has_key?(dom.nodes, &1))
  end
end
