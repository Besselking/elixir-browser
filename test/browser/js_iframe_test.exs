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
      150 ->
        # (a runtime that was slow, on a busy machine, has sent replies that are still on their
        # way here when the flush is answered: they come before its reply, and before its logs)
        flushed = Runtime.flush(pid)
        drain(pid) ++ for {:log, t} <- flushed.console, do: t
    end
  end

  defp drain(pid) do
    receive do
      {:js_async, ^pid, reply} -> for({:log, t} <- reply.console, do: t) ++ drain(pid)
    after
      0 -> []
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

  # A layout for the scripts of a frame leaves out the other frames (`Browser.JS.DOM.frame_chain/1`):
  # a new element in another frame gets no number and no box there, so a question about it later
  # asks for a layout again, also when nothing changed in between.
  test "a layout for one frame does not answer for a new element of another frame" do
    b =
      ~S|<body><script>var x = document.createElement('div'); document.body.appendChild(x); | <>
        ~S|setTimeout(function () { console.log('B ' + x.getBoundingClientRect().width) }, 150)</script></body>|

    a =
      ~S|<body><script>setTimeout(function () { var y = document.createElement('div'); | <>
        ~S|document.body.appendChild(y); console.log('A ' + y.getBoundingClientRect().width) }, 50)</script></body>|

    {raw, _} =
      ~s|<body><iframe srcdoc="#{a}"></iframe><iframe srcdoc="#{b}"></iframe></body>|
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

    # (each element in the tree gets a box 100 px wider than its number)
    answer = fn answer, acc ->
      receive do
        {:layout_now, ^pid, nil, _tree} ->
          answer.(answer, acc)

        {:layout_now, ^pid, ref, tree} ->
          rects = Map.new(nids(tree), &{&1, {0, 0, 100 + &1, 10}})
          send(pid, {:layout_now_done, ref, rects, {800.0, 600.0}})
          answer.(answer, [:forced | acc])

        {:js_async, ^pid, reply} ->
          logs = for {:log, t} <- reply.console, do: t
          acc = Enum.reverse(logs) ++ acc
          if Enum.any?(logs, &String.starts_with?(&1, "B ")), do: acc, else: answer.(answer, acc)
      after
        5_000 -> flunk("no answer from the frames: #{inspect(Enum.reverse(acc))}")
      end
    end

    events = Enum.reverse(answer.(answer, []))
    Runtime.stop(pid)
    assert [:forced, "A " <> _, :forced, "B " <> w] = events
    assert String.to_integer(w) > 100
  end

  defp nids(nodes) when is_list(nodes), do: Enum.flat_map(nodes, &nids/1)

  defp nids({:element, _, attrs, kids}) do
    case List.keyfind(attrs, "@nid", 0) do
      {_, n} -> [n | nids(kids)]
      nil -> nids(kids)
    end
  end

  defp nids(_), do: []

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

  # The code cache (`Browser.JS.Compile`) keeps the uids of the entries of each realm under
  # `{:jsc_root, root}`. When a frame goes, its entries go with it; the entries of the page
  # stay. (Only rewritten functions compile, so the test reads the cache at level 4 only, and
  # with the compiler on.)
  for remove? <- [false, true] do
    test "the code cache keeps the code of a frame only while the frame is there (remove: #{remove?})" do
      script = ~S"""
      function inc(x) { return x + 1 }
      for (let i = 0; i < 3; i++) inc(i);
      const f = document.createElement("iframe");
      f.srcdoc = "<script>function dbl(x) { return x * 2 } for (let i = 0; i < 3; i++) dbl(i)<\/script>";
      f.onload = () => { if (window.remove) f.remove(); console.log("loaded") };
      document.body.appendChild(f);
      """

      {raw, _} =
        "<body><script>window.remove = #{unquote(remove?)};#{script}</script></body>"
        |> Browser.HTML.parse()
        |> Browser.Forms.index()

      info = %{url: "http://t.test/", width: 800, height: 600, fetch: fn _ -> {:error, "404"} end}
      pid = Runtime.start(raw, info)
      r = Runtime.run_scripts(pid)
      lines = for({:log, t} <- r.console, do: t) ++ collect(pid)
      {:dictionary, dict} = Process.info(pid, :dictionary)
      Runtime.stop(pid)
      assert lines == ["loaded"]

      if Application.get_env(:browser, :js_resolve) == 4 and
           Application.get_env(:browser, :js_compile, true) do
        roots = for {{:jsc_root, _}, uids} <- dict, do: uids
        entries = for {{:jsc, uid}, _} <- dict, do: uid
        assert length(roots) == if(unquote(remove?), do: 1, else: 2)
        assert Enum.sort(entries) == roots |> List.flatten() |> Enum.sort()
      end
    end
  end

  test "an erase of the code cache also erases the uids of the realms" do
    Task.async(fn ->
      Process.put({:jsc_root, 1}, [:a])
      Process.put({:jsc, :a}, {nil, nil})
      Browser.JS.Compile.erase_entries()
      assert Process.get({:jsc_root, 1}) == nil
      assert Process.get({:jsc, :a}) == nil
    end)
    |> Task.await()
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

  # The teardown of a frame takes its nodes, their wrappers and listeners, and the window and
  # location of the frame out of the maps of the document. When the frame has most of the
  # nodes, `DOM.destroy_realm/1` makes the maps again from the entries that stay, else it
  # drops the keys of the frame: both ways must leave the same maps.
  for {name, page, frame} <- [{"most of the nodes", 3, 300}, {"few of the nodes", 300, 3}] do
    test "a frame that goes takes its nodes, wrappers and listeners: it has #{name}" do
      {raw, _} =
        ~s"""
        <body><script>
        for (let i = 0; i < #{unquote(page)}; i++) document.body.appendChild(document.createElement("i"));
        document.body.addEventListener("click", () => console.log("page click"));
        window.addEventListener("ping", () => console.log("page ping"));
        const f = document.createElement("iframe");
        f.srcdoc = "<p>" + "<b>x</b>".repeat(#{unquote(frame)}) + "</p>";
        f.onload = () => {
          const w = f.contentWindow, d = f.contentDocument;
          console.log(w.location.href, d.querySelectorAll("b").length);
          w.addEventListener("ping", () => console.log("frame ping"));
          for (const b of d.querySelectorAll("b")) b.addEventListener("click", () => {});
          f.remove();
          document.body.click();
          window.dispatchEvent(new Event("ping"));
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

      assert logs == ["about:srcdoc #{unquote(frame)}", "page click", "page ping"]
      assert Enum.all?(dom.nodes, fn {_, n} -> n.doc == dom.main end)
      assert map_size(dom.nodes) > unquote(page)

      # (the keys of the nodes, and the window and the location of the frame)
      left =
        for map <- [dom.wrappers, dom.listeners],
            k <- Map.keys(map),
            (is_integer(k) and not is_map_key(dom.nodes, k)) or
              match?({:window, _}, k) or match?({:aux, {w, _}} when w in [:window, :location], k),
            do: k

      assert left == []

      assert Enum.count(dom.wrappers, fn {k, _} -> is_integer(k) end) > unquote(page)
      assert is_map_key(dom.listeners, :window)
    end
  end

  # An `<iframe>` that the page made goes, inside a `<div>` that a frame's document made, into
  # that document (which has no `<iframe>` of its own), then into the page, then back. Each
  # move takes the realm of its frame away and loads a new one, in the document it is now in.
  # At the end there are two frames, the one of `host` and the one of `b`, and no other realm.
  test "an iframe in a subtree that moves between the page and a frame loads in each" do
    {raw, _} =
      ~S"""
      <body><script>
      const host = document.createElement("iframe");
      document.body.appendChild(host);
      const d = host.contentDocument;
      const div = d.createElement("div");
      const sec = document.createElement("section");
      const b = document.createElement("iframe");
      b.srcdoc = "<p id=q>q</p>";
      sec.appendChild(b);
      div.appendChild(sec);
      let n = 0;
      b.onload = () => {
        n++;
        const w = b.contentWindow;
        const at = b.ownerDocument === d ? "frame" : b.ownerDocument === document ? "page" : "?";
        const up = at === "frame" ? host.contentWindow : window;
        console.log(n, at, b.contentDocument.getElementById("q").textContent, w.parent === up, w !== window.last);
        window.last = w;
        if (n === 1) document.body.appendChild(div);
        else if (n === 2) d.body.appendChild(div);
        else if (n === 3) {
          div.remove();
          console.log("out", b.contentWindow, b.contentDocument);
          d.body.appendChild(div);
        }
      };
      console.log("before", b.contentDocument);
      d.body.appendChild(div);
      </script></body>
      """
      |> Browser.HTML.parse()
      |> Browser.Forms.index()

    info = %{url: "http://t.test/", width: 800, height: 600, fetch: fn _ -> {:error, "404"} end}
    pid = Runtime.start(raw, info)
    r = Runtime.run_scripts(pid)
    logs = for({:log, t} <- r.console, do: t) ++ collect(pid)
    errors = for({:error, t} <- r.console, do: t)
    {:dictionary, dict} = Process.info(pid, :dictionary)
    Runtime.stop(pid)
    dom = Keyword.fetch!(dict, :dom)

    assert errors == []

    assert logs == [
             "before null",
             "1 frame q true true",
             "2 page q true true",
             "3 frame q true true",
             "out null null",
             "4 frame q true true"
           ]

    assert map_size(dom.frames) == 2
    assert map_size(dom.realms) == 2
    assert dom.realms |> Map.keys() |> Enum.sort() == dom.frames |> Map.values() |> Enum.sort()
  end

  # A function of the frame (so the realm of the frame runs) takes a `<div>` of the page with a
  # loaded `<iframe>` into the frame's document, which has no `<iframe>` of its own. The frame
  # of that `<iframe>` goes at once as it leaves the page (it has another window then), and a
  # new one loads in the frame's document: no realm is left behind.
  test "a frame's script that takes a loaded iframe from the page ends its frame at once" do
    {raw, _} =
      ~S"""
      <body><script>
      const host = document.createElement("iframe");
      host.srcdoc = "<body><script>window.take = (n) => document.body.appendChild(n);<\/script></body>";
      host.onload = () => {
        const b = document.createElement("iframe");
        b.srcdoc = "<p>b</p>";
        const div = document.createElement("div");
        div.appendChild(b);
        let n = 0;
        b.onload = () => {
          n++;
          console.log(n, b.ownerDocument === host.contentDocument, b.contentDocument.body.textContent);
          if (n === 1) {
            const w = b.contentWindow;
            host.contentWindow.take(div);
            console.log("moved", b.contentWindow !== w);
          }
        };
        document.body.appendChild(div);
      };
      document.body.appendChild(host);
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

    assert logs == ["1 false b", "moved true", "2 true b"]
    assert map_size(dom.frames) == 2
    assert dom.realms |> Map.keys() |> Enum.sort() == dom.frames |> Map.values() |> Enum.sort()
  end

  # A frame's script takes its own `<iframe>` away, through a function of the page (so the
  # realm of the page runs while the frame's realm waits for it). The code after the removal
  # runs to its end, and then the realm goes.
  test "a frame's script that takes its own iframe away runs to its end, then its realm goes" do
    {raw, _} =
      ~S"""
      <body><script>
      const f = document.createElement("iframe");
      f.srcdoc = "<script>Array.prototype.myp = function () { return 1; }; var P = parent; P.out = ['pre'];" +
        "P.document.querySelector('iframe').remove(); P.out.push('post', [].myp());<\/script>";
      document.body.appendChild(f);
      setTimeout(() => console.log(window.out.join(" ")), 20);
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

    assert logs == ["pre post 1"]
    assert dom.frames == %{} and dom.realms == %{}
    assert Keyword.get(dict, :dom_dead, []) == [] and Keyword.get(dict, :dom_stack, []) == []
  end

  # The `<iframe>`s come into a frame's document (that has none before) and into the page by
  # `innerHTML` in the frame, `importNode` of a template's content, the template's content
  # itself, a fragment that the frame's document made, and a shadow root of an element of the
  # frame. Each one loads; then each one goes with the subtree it is in.
  test "iframes that come into a document in a fragment, a template or a shadow root load" do
    {logs, errors} =
      run(
        ~S"""
        const host = document.createElement("iframe");
        document.body.appendChild(host);
        const d = host.contentDocument;
        const seen = [];
        const frames = {};
        const watch = (name, f) => {
          frames[name] = f;
          f.onload = () => {
            const at = f.ownerDocument === d ? ":frame" : f.ownerDocument === document ? ":page" : ":?";
            seen.push(name + at);
            if (seen.length < 5) return;
            console.log(seen.sort().join());
            d.body.innerHTML = "";
            document.getElementById("out").remove();
            frames.shadow.remove();
            console.log(Object.keys(frames).sort().map((k) => k + "=" + frames[k].contentWindow).join());
          };
        };
        d.body.innerHTML = "<div><p><iframe srcdoc='<p>h</p>'></iframe></p></div>";
        watch("html", d.querySelector("iframe"));
        const t = document.getElementById("t");
        const copy = document.importNode(t.content, true);
        watch("import", copy.querySelector("iframe"));
        d.body.appendChild(copy);
        const out = document.getElementById("out");
        watch("content", t.content.querySelector("iframe"));
        out.appendChild(t.content);
        const frag = d.createDocumentFragment();
        const p = d.createElement("p");
        const f4 = document.createElement("iframe");
        f4.srcdoc = "<p>f</p>";
        p.appendChild(f4);
        frag.appendChild(p);
        watch("fragment", f4);
        out.appendChild(frag);
        const h = d.createElement("div");
        d.body.appendChild(h);
        const sr = h.attachShadow({ mode: "open" });
        const f5 = document.createElement("iframe");
        f5.srcdoc = "<p>s</p>";
        const span = d.createElement("span");
        span.appendChild(f5);
        watch("shadow", f5);
        sr.appendChild(span);
        console.log("now", Object.keys(frames).map((k) => frames[k].contentDocument !== null).join());
        """,
        ~S|<div id=out></div><template id=t><section><iframe srcdoc="<p>t</p>"></iframe></section></template>|
      )

    assert errors == []

    assert logs == [
             "now true,true,true,true,true",
             "content:page,fragment:page,html:frame,import:frame,shadow:frame",
             "content=null,fragment=null,html=null,import=null,shadow=null"
           ]
  end

  # A read of a global name in a function (`{:gref}`) takes the value of a variable of the
  # global scope at once (`Interp.ev_own/2`), and any other name by the walk. Each read must
  # see the last write, by any path: a property of the window, `delete`, `defineProperty`, a
  # getter, `var`, `let` and `const` of another script, eval, `with`, and the other realm.
  test "a read of a global name sees each write to the global scope and the window" do
    {logs, errors} =
      run(
        ~S"""
        const log = [];
        function rd() { try { return String(gx) } catch (e) { return e.name } }
        function ry() { try { return String(gy) } catch (e) { return e.name } }
        function rz() { try { return String(gz) } catch (e) { return e.name } }
        function rv() { return gv }
        function rs() { var gv = "local"; return gv }
        log.push(rd());
        window.gx = 1; log.push(rd());
        window.gx = 2; log.push(rd());
        Object.defineProperty(window, "gy", { value: 3, configurable: true, writable: true });
        log.push(ry());
        delete window.gy; log.push(ry());
        var n = 0;
        Object.defineProperty(window, "gz", { get: function () { return "g" + ++n }, configurable: true });
        log.push(rz(), rz());
        delete window.gz; log.push(rz());
        log.push(early, rl(), rc(), rv());
        gv = "v2"; log.push(rv());
        window.gv = "v3"; log.push(rv());
        eval("gv = 'v4'"); log.push(rv());
        eval("var ge = 'e1'"); function re() { return ge } log.push(re());
        eval("ge = 'e2'"); log.push(re());
        with ({ gv: "w" }) { log.push(gv, rv()) }
        log.push(rs(), rv());
        const f = document.createElement("iframe");
        f.srcdoc = "<script>var gv = 'frame'; function fr() { return gv }<\/script>";
        f.onload = () => {
          const w = f.contentWindow;
          log.push(w.fr(), rv());
          w.gv = "frame2"; gv = "page2";
          log.push(w.fr(), rv(), w.eval("parent.rv()"), rl(), rc());
          console.log(log.join(" "));
        };
        document.body.appendChild(f);
        let gl = "l2"; const gc = "c2";
        """,
        ~S"""
        <script>
        var gv = "v1";
        function rl() { try { return gl } catch (e) { return e.name } }
        function rc() { try { return gc } catch (e) { return e.name } }
        var early = rl();
        </script>
        """
      )

    assert errors == []

    assert logs == [
             "ReferenceError 1 2 3 ReferenceError g1 g2 ReferenceError ReferenceError " <>
               "ReferenceError ReferenceError v1 v2 v3 v4 e1 e2 w v4 local v4 frame v4 frame2 page2 page2 l2 c2"
           ]
  end

  # The global variables of a realm are the properties of its window. One that a write made
  # (`window.x = 1`, `x = 1`) is configurable: `delete` takes it away, and `defineProperty`
  # makes it an own property of the window. A `var` or a function declaration is not
  # configurable: `delete` gives false, and it cannot become an accessor.
  test "delete and defineProperty on a window change its global variables" do
    {logs, errors} =
      run(
        ~S"""
        const out = [];
        function rd(n) { try { return String(eval(n)) } catch (e) { return e.name } }
        function rx() { try { return String(gx) } catch (e) { return e.name } }
        window.gx = 1; out.push(rx(), delete window.gx, rx(), "gx" in window);
        gy = 2; out.push(delete window.gy, rd("gy"));
        out.push(delete window.gv, gv, delete window.gf, typeof gf);
        window.gw = 1;
        Object.defineProperty(window, "gw", { value: 2, configurable: true, writable: true });
        out.push(rd("gw"), window.gw);
        gw = 3; out.push(window.gw, rd("gw"));
        window.gg = 1;
        Object.defineProperty(window, "gg", { get: function () { return "g" }, configurable: true });
        out.push(rd("gg"), window.gg);
        Object.defineProperty(window, "gv", { value: 5 }); out.push(gv, window.gv);
        try { Object.defineProperty(window, "gv", { get: function () {} }) } catch (e) { out.push(e.name) }
        const f = document.createElement("iframe");
        f.srcdoc = "<script>var fv = 1; x2 = 2; function fr() { return typeof x2 }<\/script>";
        f.onload = () => {
          const w = f.contentWindow;
          out.push(delete w.x2, w.fr(), delete w.fv, w.fv, rd("gv"));
          console.log(out.join(" "));
        };
        document.body.appendChild(f);
        """,
        "<script>var gv = 1; function gf() {}</script>"
      )

    assert errors == []

    assert logs == [
             "1 true ReferenceError false true ReferenceError false 1 false function 2 2 3 3 " <>
               "g g 5 5 TypeError true undefined false 1 5"
           ]
  end

  # The editing prelude (`Browser.JS.Editing`) runs in each realm that edits. A frame that
  # edits and goes takes the functions of its prelude with it (`Browser.JS.Intrinsics`), so a
  # later frame that edits gets the prelude again, for its own document. (Before, the first
  # frame's prelude stayed loaded, its functions were restored away, and the stubs of the
  # next frame called themselves until the stack was full.)
  test "a frame that edits after another one went gets the editing functions of its own" do
    {logs, errors} =
      run(~S"""
      const out = [];
      const edit =
        "<div id=e contenteditable>ab</div><script>" +
        "var r = document.createRange(); r.selectNodeContents(document.getElementById('e'));" +
        "getSelection().removeAllRanges(); getSelection().addRange(r);" +
        "document.execCommand('bold');" +
        "var n = new Range();" +
        "parent.out.push(r.startContainer.ownerDocument === document, n.startContainer === document," +
        " document.getElementById('e').innerHTML);<\/script>";
      window.out = out;
      const a = document.createElement("iframe");
      a.srcdoc = edit;
      a.onload = () => {
        a.remove();
        const b = document.createElement("iframe");
        b.srcdoc = edit;
        b.onload = () => console.log(out.join(" "));
        document.body.appendChild(b);
      };
      document.body.appendChild(a);
      """)

    assert errors == []
    assert logs == ["true true <b>ab</b> true true <b>ab</b>"]
  end

  test "the page edits again after a frame that also edited went" do
    {logs, errors} =
      run(~S"""
      document.getSelection();
      const f = document.createElement("iframe");
      f.srcdoc = "<p>x</p><script>new Range(); document.getSelection();<\/script>";
      f.onload = () => {
        f.remove();
        setTimeout(() => {
          const out = [];
          try { out.push(document.getSelection() === getSelection()); } catch (e) { out.push(e.name); }
          try { out.push(document.createRange().startContainer === document); } catch (e) { out.push(e.name); }
          try { out.push(new Range().startContainer === document); } catch (e) { out.push(e.name); }
          console.log(out.join(" "));
        }, 0);
      };
      document.body.appendChild(f);
      """)

    assert errors == []
    assert logs == ["true true true"]
  end

  test "delete and defineProperty on the window leave its unforgeable names and let bindings" do
    {logs, errors} =
      run(
        ~S"""
        const out = [];
        out.push(delete window.document, typeof document);
        try { Object.defineProperty(window, "location", { value: 1 }); out.push("defined"); } catch (e) { out.push(e.name); }
        out.push(typeof location, delete window.top, window.top === window);
        out.push(delete window.lx, lx);
        Object.defineProperty(window, "cx", { value: 7, configurable: true });
        out.push(cx, window.cx);
        console.log(out.join(" "));
        """,
        "<script>let lx = 1; const cx = 3;</script>"
      )

    assert errors == []
    assert logs == ["false object TypeError object false true true 1 3 7"]
  end

  test "delete and defineProperty on the window of a frame that went leave the page's globals" do
    {logs, errors} =
      run(~S"""
      yy = 1; zz = 5;
      const f = document.createElement("iframe");
      f.srcdoc = "<p>x</p>";
      f.onload = () => {
        const w = f.contentWindow;
        f.remove();
        setTimeout(() => {
          const out = [delete w.yy, typeof yy];
          Object.defineProperty(w, "zz", { value: 9 });
          out.push(zz, w.zz);
          console.log(out.join(" "));
        }, 0);
      };
      document.body.appendChild(f);
      """)

    assert errors == []
    assert logs == ["true number 5 9"]
  end
end
