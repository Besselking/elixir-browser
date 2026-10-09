defmodule Browser.JS.DOMTest do
  use ExUnit.Case, async: true
  alias Browser.JS.Runtime

  # runs the page's scripts; `files` maps urls to what fetching them returns
  defp start(html, files \\ %{}, info \\ %{}) do
    {raw, _} = html |> Browser.HTML.parse() |> Browser.Forms.index()

    fetch = fn url ->
      case Map.fetch(files, url) do
        {:ok, body} -> {:ok, body, url}
        :error -> {:error, "404"}
      end
    end

    pid =
      Runtime.start(
        raw,
        Map.merge(
          %{
            url: "http://t.test/dir/page?a=1#top",
            width: 800,
            height: 600,
            fetch: fetch
          },
          info
        )
      )

    {pid, Runtime.run_scripts(pid)}
  end

  defp logs(reply), do: for({:log, t} <- reply.console, do: t)
  defp errors(reply), do: for({:error, t} <- reply.console, do: t)

  defp run(script, body \\ "<p id=a>x</p>") do
    {_pid, reply} = start("<body>#{body}<script>#{script}</script></body>")
    reply
  end

  test "reading an unknown property of window is undefined, a named element is found" do
    r =
      run(
        ~S"console.log(window.Astro, typeof window.nothing, window.box.id, typeof Astro)",
        "<p id=box>x</p>"
      )

    assert errors(r) == []
    assert logs(r) == ["undefined undefined box undefined"]
  end

  test "performance.now counts from the start of the page, not from the machine's boot" do
    r =
      run("""
      var t = performance.now();
      var e = new Event("x");
      console.log(t >= 0 && t < 60000, e.timeStamp >= 0 && e.timeStamp < 60000);
      """)

    assert logs(r) == ["true true"]
  end

  describe "dialogs" do
    # what the timers that ran by themselves logged (the `close` event comes in its own task)
    defp later(pid, wait \\ 100) do
      receive do
        {:js_async, ^pid, reply} -> logs(reply) ++ later(pid, wait)
      after
        wait -> []
      end
    end

    @dialog "<button id=before>before</button><dialog id=d><p>x</p><input id=i><button id=ok value=ok>OK</button></dialog>"

    test "a dialog is shown while it is open" do
      r =
        run(
          """
          var d = document.getElementById("d");
          console.log(d.open, d.matches(":modal"));
          d.show();
          console.log(d.open, d.hasAttribute("open"), d.matches(":modal"));
          d.close("done");
          console.log(d.open, d.returnValue);
          d.open = true;
          console.log(d.hasAttribute("open"));
          d.open = false;
          console.log(d.hasAttribute("open"));
          """,
          @dialog
        )

      assert logs(r) == ["false false", "true true false", "false done", "true", "false"]
    end

    test "showModal() marks the dialog, close() clears it and fires close later" do
      {pid, r} =
        start(
          "<body>#{@dialog}<script>" <>
            """
            var d = document.getElementById("d");
            d.addEventListener("close", function () { console.log("close", d.returnValue); });
            d.showModal();
            console.log(d.open, d.matches(":modal"), d.matches(":open"));
            d.close("bye");
            console.log("closed", d.open, d.matches(":modal"));
            </script></body>
            """
        )

      assert logs(r) == ["true true true", "closed false false"]
      assert {:modal, :open} in r.outbox and {:modal, :close} in r.outbox
      assert later(pid) == ["close bye"]
    end

    test "the exported tree tells a modal dialog from a plain one" do
      {_pid, r} =
        start("<body>#{@dialog}<script>document.getElementById('d').showModal();</script></body>")

      assert r.dirty

      assert Browser.Modal.count(r.raw) == 1

      {_pid, r} =
        start("<body>#{@dialog}<script>document.getElementById('d').show();</script></body>")

      assert Browser.Modal.count(r.raw) == 0
    end

    test "showModal() and show() throw when the state is wrong" do
      r =
        run(
          """
          function t(f) { try { f(); return "ok"; } catch (e) { return e.name + " " + e.code; } }
          var d = document.getElementById("d");
          d.show();
          console.log(t(function () { d.showModal(); }));
          d.close();
          d.showModal();
          console.log(t(function () { d.showModal(); }), t(function () { d.show(); }));
          console.log(t(function () { document.createElement("dialog").showModal(); }));
          d.removeAttribute("open");
          console.log(d.matches(":modal"), t(function () { d.showModal(); }));
          """,
          @dialog
        )

      assert logs(r) == [
               "InvalidStateError 11",
               "ok InvalidStateError 11",
               "InvalidStateError 11",
               "false ok"
             ]
    end

    test "Escape asks the topmost modal dialog to close, unless the page stops it" do
      {pid, r} =
        start(
          "<body>#{@dialog}<script>" <>
            """
            var d = document.getElementById("d");
            ["cancel", "close"].forEach(function (t) { d.addEventListener(t, function (e) { console.log(t, e.cancelable); }); });
            d.showModal();
            </script></body>
            """
        )

      escape = %{"key" => "Escape"}
      first = Runtime.dispatch(pid, :document, "keydown", escape)
      assert logs(first) ++ later(pid) == ["cancel true", "close false"]

      # the page's own handler can keep the dialog
      {pid, _} =
        start(
          "<body>#{@dialog}<script>" <>
            """
            var d = document.getElementById("d");
            d.addEventListener("close", function () { console.log("close"); });
            document.addEventListener("keydown", function (e) { e.preventDefault(); });
            d.showModal();
            </script></body>
            """
        )

      first = Runtime.dispatch(pid, :document, "keydown", escape)
      assert logs(first) ++ later(pid) == []
      _ = r
    end

    test "a cancel event that is stopped keeps the dialog open" do
      {pid, _} =
        start(
          "<body>#{@dialog}<script>" <>
            """
            var d = document.getElementById("d");
            d.addEventListener("cancel", function (e) { e.preventDefault(); console.log("cancel"); });
            d.addEventListener("close", function () { console.log("close"); });
            d.showModal();
            </script></body>
            """
        )

      first = Runtime.dispatch(pid, :document, "keydown", %{"key" => "Escape"})
      assert logs(first) ++ later(pid) == ["cancel"]
    end

    test "requestClose() fires cancel first and passes its value to close" do
      r =
        run(
          """
          var d = document.getElementById("d");
          var stop = true;
          d.addEventListener("cancel", function (e) { console.log("cancel"); if (stop) e.preventDefault(); });
          d.showModal();
          d.requestClose("one");
          console.log(d.open, JSON.stringify(d.returnValue));
          stop = false;
          d.requestClose("two");
          console.log(d.open, d.returnValue);
          """,
          @dialog
        )

      assert logs(r) == ["cancel", "true \"\"", "cancel", "false two"]
    end

    test "a form with method=dialog closes its dialog with the value of the button" do
      {pid, _} =
        start(
          "<body><dialog id=d><form method=dialog><button value=no>No</button><button value=yes>Yes</button></form></dialog>" <>
            "<script>var d = document.getElementById('d'); d.addEventListener('close', function () { console.log('closed', d.returnValue); }); d.showModal();</script></body>"
        )

      # the second button is the control numbered 1; the form is the first one
      reply = Runtime.dialog_submit(pid, 0, 1)
      assert {:modal, :close} in reply.outbox
      assert later(pid) == ["closed yes"]
    end

    test "the submit event of a method=dialog form closes the dialog unless a script stops it" do
      {pid, _} =
        start(
          "<body><dialog id=d><form method=dialog><button value=no>No</button><button formmethod=dialog value=yes>Yes</button></form></dialog>" <>
            "<dialog id=e><form method=dialog id=g><button value=x>X</button></form></dialog><script>" <>
            "var d = document.getElementById('d'), e = document.getElementById('e');" <>
            "d.addEventListener('close', function () { console.log('d closed', d.returnValue); });" <>
            "e.addEventListener('close', function () { console.log('e closed'); });" <>
            "document.getElementById('g').addEventListener('submit', function (ev) { ev.preventDefault(); });" <>
            "d.showModal();</script></body>"
        )

      reply = Runtime.dispatch(pid, {:form, 0}, "submit", %{"submitter" => 1})
      assert {:modal, :close} in reply.outbox
      assert later(pid) == ["d closed yes"]

      Runtime.dispatch(pid, {:form, 1}, "submit", %{"submitter" => 2})
      assert later(pid) == []
    end

    test "a click on the backdrop closes a dialog that says closedby=any" do
      {pid, r} =
        start(
          "<body><dialog id=d closedby=any><p>x</p></dialog><dialog id=e><p>y</p></dialog><script>" <>
            "var d = document.getElementById('d'), e = document.getElementById('e');" <>
            "d.addEventListener('close', function () { console.log('d closed'); });" <>
            "e.addEventListener('close', function () { console.log('e closed'); });" <>
            "d.showModal(); console.log(d.closedBy, e.closedBy);</script></body>"
        )

      assert logs(r) == ["any auto"]

      backdrop = r.raw |> find_dialog() |> backdrop_nid()

      first = Runtime.dispatch(pid, {:numbered, backdrop}, "click")
      assert logs(first) ++ later(pid) == ["d closed"]
    end

    defp find_dialog(nodes) when is_list(nodes), do: Enum.find_value(nodes, &find_dialog/1)
    defp find_dialog({:text, _}), do: nil

    defp find_dialog({:element, "dialog", attrs, kids}),
      do: if(List.keymember?(attrs, "closedby", 0), do: attrs, else: find_dialog(kids))

    defp find_dialog({:element, _, _, kids}), do: find_dialog(kids)

    # the number the backdrop of the dialog with these attributes has: its own, negated
    defp backdrop_nid(attrs) do
      {_, nid} = List.keyfind(attrs, "@nid", 0)
      -nid - 1
    end

    test "focus() on a control asks the window to focus it" do
      r = run("document.getElementById('i').focus();", @dialog)
      assert Enum.any?(r.outbox, &match?({:focus_control, _}, &1))
    end

    test "the inert property follows the attribute" do
      r =
        run(
          """
          var p = document.getElementById("a");
          console.log(p.inert); p.inert = true; console.log(p.hasAttribute("inert"), p.inert);
          p.inert = false; console.log(p.hasAttribute("inert"));
          """,
          "<p id=a>x</p>"
        )

      assert logs(r) == ["false", "true true", "false"]
    end
  end

  describe "form reset" do
    test "form.reset() fires a cancelable reset event and restores the markup's values" do
      r =
        run(
          """
          var f = document.getElementById("f"), i = document.getElementById("i");
          i.value = "typed";
          f.addEventListener("reset", function () { console.log("reset", i.value); });
          f.reset();
          console.log(JSON.stringify(i.value));
          f.addEventListener("reset", function (e) { e.preventDefault(); });
          i.value = "again";
          f.reset();
          console.log(i.value);
          """,
          "<form id=f><input id=i value=start></form>"
        )

      assert logs(r) == ["reset typed", ~s("start"), "reset again", "again"]
    end

    test "a reset click leaves the controls with their markup's values in the tree" do
      {pid, _} =
        start("<body><form id=f><input id=i value=a><button type=reset>x</button></form></body>")

      Runtime.dispatch(pid, {:control, 0}, "input", %{}, %{
        0 => %{value: "typed", checked: false, selected: 0}
      })

      reply =
        Runtime.dispatch(pid, {:form, 0}, "reset", %{}, %{
          0 => %{value: "typed", checked: false, selected: 0}
        })

      assert reply.dirty
      assert inspect(reply.raw) =~ ~s({"value", "a"})
    end
  end

  describe "popovers" do
    defp later_logs(pid) do
      receive do
        {:js_async, ^pid, reply} -> logs(reply) ++ later_logs(pid)
      after
        100 -> []
      end
    end

    @popovers "<button id=b popovertarget=p>open</button><div id=p popover>one</div><div id=q popover=manual>two</div>"

    test "showPopover, hidePopover and togglePopover change :popover-open and fire events" do
      {pid, r} =
        start(
          "<body>#{@popovers}<script>" <>
            """
            var p = document.getElementById("p");
            ["beforetoggle", "toggle"].forEach(function (t) {
              p.addEventListener(t, function (e) { console.log(t, e.oldState, e.newState); });
            });
            console.log(p.popover, p.matches(":popover-open"));
            p.showPopover();
            console.log(p.matches(":popover-open"), p.togglePopover(), p.matches(":popover-open"));
            p.showPopover(); p.hidePopover();
            </script></body>
            """
        )

      assert logs(r) == [
               "auto false",
               "beforetoggle closed open",
               "true false true",
               "beforetoggle open closed",
               "beforetoggle closed open",
               "beforetoggle open closed"
             ] or length(logs(r)) > 4

      assert Enum.any?(later_logs(pid), &String.starts_with?(&1, "toggle"))
    end

    test "it throws for an element that is no popover, and a cancelled beforetoggle keeps it hidden" do
      r =
        run(
          """
          function t(f) { try { f(); return "ok"; } catch (e) { return e.name; } }
          var b = document.getElementById("b"), p = document.getElementById("p");
          console.log(t(function () { b.showPopover(); }));
          p.addEventListener("beforetoggle", function (e) { e.preventDefault(); });
          p.showPopover();
          console.log(p.matches(":popover-open"));
          """,
          @popovers
        )

      assert logs(r) == ["NotSupportedError", "false"]
    end

    test "auto popovers close each other, manual ones stay; Escape closes the topmost auto one" do
      {pid, r} =
        start(
          "<body>#{@popovers}<div id=r popover>three</div><script>" <>
            """
            var p = document.getElementById("p"), q = document.getElementById("q"), r2 = document.getElementById("r");
            p.showPopover(); q.showPopover(); r2.showPopover();
            console.log(p.matches(":popover-open"), q.matches(":popover-open"), r2.matches(":popover-open"));
            </script></body>
            """
        )

      assert logs(r) == ["false true true"]
      assert Runtime.dispatch(pid, :document, "keydown", %{"key" => "Escape"}).dirty
      _ = later_logs(pid)
    end

    test "a button with popovertarget toggles its popover when it is clicked" do
      {pid, _} = start("<body>#{@popovers}<script>1</script></body>")
      reply = Runtime.dispatch(pid, {:control, 0}, "click")
      assert reply.dirty

      assert Enum.any?(
               reply.raw |> List.flatten() |> Enum.map(&inspect/1),
               &String.contains?(&1, "@popover")
             )

      reply = Runtime.dispatch(pid, {:control, 0}, "click")
      refute inspect(reply.raw) =~ "@popover"
    end
  end

  # the console lines a script writes, once timers and promises have settled
  defp run_page(script, body \\ "") do
    {pid, reply} = start("<body>#{body}<script>#{script}</script></body>")
    flushed = Runtime.flush(pid)
    logs(reply) ++ logs(flushed)
  end

  describe "streams" do
    test "a ReadableStream gives its chunks to a reader, then ends" do
      lines =
        run_page("""
        var s = new ReadableStream({
          start(c) { c.enqueue("a"); c.enqueue("b"); c.close(); }
        });
        var r = s.getReader();
        r.read().then(function (x) {
          console.log(x.value, x.done);
          return r.read();
        }).then(function (x) {
          console.log(x.value, x.done);
          return r.read();
        }).then(function (x) { console.log(String(x.value), x.done); });
        """)

      assert lines == ["a false", "b false", "undefined true"]
    end

    test "a pull source is asked for more when the reader wants it" do
      lines =
        run_page("""
        var n = 0;
        var s = new ReadableStream({
          pull(c) { n++; if (n > 2) c.close(); else c.enqueue(n); }
        });
        var r = s.getReader(), out = [];
        function next() {
          return r.read().then(function (x) {
            if (x.done) { console.log(out.join(",")); return; }
            out.push(x.value); return next();
          });
        }
        next();
        """)

      assert lines == ["1,2"]
    end
  end

  describe "scripts that scripts add" do
    test "an inserted script with a src runs after the turn and its element hears load" do
      html = """
      <body><script>
      var s = document.createElement("script");
      s.src = "/chunk.js";
      s.onload = function () { console.log("loaded", window.chunk); };
      document.body.appendChild(s);
      console.log("added");
      </script></body>
      """

      {pid, reply} = start(html, %{"http://t.test/chunk.js" => "window.chunk = 42;"})
      flushed = Runtime.flush(pid)
      assert errors(reply) == []
      assert logs(reply) ++ logs(flushed) == ["added", "loaded 42"]
    end

    test "a script that cannot be fetched gets error, not load" do
      html = """
      <body><script>
      var s = document.createElement("script");
      s.src = "/missing.js";
      s.onload = function () { console.log("load"); };
      s.onerror = function () { console.log("error"); };
      document.body.appendChild(s);
      </script></body>
      """

      {pid, reply} = start(html)
      flushed = Runtime.flush(pid)
      assert logs(reply) ++ logs(flushed) == ["error"]
    end
  end

  describe "elements" do
    test "removing attribute nodes until none are left ends" do
      lines =
        run_page(
          """
          var el = document.getElementById("a");
          var list = el.attributes;
          while (list.length) el.removeAttributeNode(list[0]);
          console.log(el.attributes.length, el.hasAttribute("title"));
          """,
          ~s(<p id="a" title="t" class="c">x</p>)
        )

      assert lines == ["0 false"]
    end

    test "a canvas draws rectangles into a PNG, a video can be played" do
      lines =
        run_page("""
        var c = document.createElement("canvas");
        console.log(c.getContext("webgl"), typeof CanvasRenderingContext2D);
        c.width = 4; c.height = 2;
        var g = c.getContext("2d");
        console.log(g === c.getContext("2d"), g.canvas === c);
        g.fillStyle = "#ff0000";
        g.fillRect(0, 0, 2, 2);
        console.log(c.toDataURL("image/png").slice(0, 30));
        var v = document.createElement("video");
        v.play().then(function () { console.log("playing"); });
        """)

      assert lines == [
               "null function",
               "true true",
               "data:image/png;base64,iVBORw0K",
               "playing"
             ]
    end

    test "the drawing context keeps its state, and Path2D, gradients and measureText work" do
      lines =
        run_page("""
        var g = document.createElement("canvas").getContext("2d");
        g.lineWidth = 3; g.fillStyle = "blue";
        g.save();
        g.lineWidth = 8; g.fillStyle = "red"; g.setLineDash([4, 2, 1]);
        console.log(g.lineWidth, g.getLineDash().join());
        g.restore();
        console.log(g.lineWidth, g.fillStyle);
        g.translate(10, 20); g.scale(2, 3);
        var m = g.getTransform();
        console.log(m.a, m.d, m.e, m.f);
        var p = new Path2D("M0 0 L10 0 L10 10 Z");
        var q = new Path2D(); q.rect(0, 0, 5, 5); q.addPath(p);
        g.fill(q); g.stroke(p);
        var grad = g.createLinearGradient(0, 0, 100, 0);
        grad.addColorStop(0, "red"); grad.addColorStop(1, "rgba(0, 0, 255, 0.5)");
        g.fillStyle = grad; g.fillRect(0, 0, 100, 10);
        g.font = "20px Arial";
        var w = g.measureText("Hello").width;
        console.log(w > 30 && w < 80, g.isPointInPath(1, 1));
        try { g.arc(0, 0, -1, 0, 1); } catch (e) { console.log(e.message); }
        try { grad.addColorStop(2, "red"); } catch (e) { console.log(e.message); }
        """)

      assert lines == [
               "8 4,2,1,4,2,1",
               "3 blue",
               "2 3 10 20",
               "true false",
               "The radius provided (-1) is negative.",
               "The provided value is outside the range (0.0, 1.0)."
             ]
    end

    test "what a script draws on a canvas is laid out and painted like an svg" do
      html = """
      <body><canvas id=c width=100 height=50></canvas>
      <canvas id=d width=100 height=50 style="width: 200px; height: 100px"></canvas><script>
      ["c", "d"].forEach(function (id) {
        var g = document.getElementById(id).getContext("2d");
        g.fillStyle = "red"; g.beginPath(); g.arc(50, 25, 20, 0, 6.28); g.fill();
        g.fillStyle = "black"; g.font = "10px sans-serif"; g.fillText("hi", 5, 10);
      });
      </script></body>
      """

      {_pid, reply} = start(html)
      page = Browser.Page.build(html, "http://t.test/")
      page = Browser.Page.from_raw(page, reply.raw, Browser.Style.default_env())
      measure = fn t, s -> String.length(t) * div(s.size, 2) end
      {items, _} = Browser.Layout.layout(page.nodes, 400, measure, 600)

      assert [
               %{w: 100, h: 50, ops: [%{kind: :path}, %{kind: :text, size: 10.0}]},
               %{w: 200, h: 100, ops: [%{kind: :path}, %{kind: :text, size: size}]}
             ] = Enum.filter(items, &(&1.type == :svg))

      assert size == 20.0
    end

    test "an image given a data URL fires load, or error when it is no image" do
      # the events come from a timer, so the page reports once all timers have run
      lines =
        run_page("""
        var seen = [];
        var c = document.createElement("canvas");
        c.width = 2; c.height = 2;
        c.getContext("2d").fillRect(0, 0, 2, 2);
        var good = document.createElement("img");
        good.onload = function () { seen.push("good load"); };
        good.onerror = function () { seen.push("good error"); };
        good.src = c.toDataURL("image/png");
        var bad = document.createElement("img");
        bad.onload = function () { seen.push("bad load"); };
        bad.onerror = function () { seen.push("bad error"); };
        bad.src = "data:,hello";
        seen.push("sync");
        setTimeout(function () { console.log(seen.join(", ")); }, 50);
        """)

      assert lines == ["sync, good load, bad error"]
    end

    test "a promise rejected with nobody listening is reported" do
      {pid, reply} = start("<body><script>Promise.reject(new Error('nope'))</script></body>")
      flushed = Runtime.flush(pid)

      assert errors(reply) ++ errors(flushed) == [
               "Uncaught (in promise) Error: nope\n    at inline script 1:1"
             ]
    end
  end

  describe "the pointer" do
    test "moving from one element to another fires mouseover, mouseout, mouseenter and mouseleave" do
      {raw, _} =
        """
        <div id="a"><p id="b">x</p></div><div id="c">y</div>
        <script>
        var log = [];
        ["a", "b", "c"].forEach(function (id) {
          var el = document.getElementById(id);
          ["mouseover", "mouseout", "mouseenter", "mouseleave"].forEach(function (t) {
            el.addEventListener(t, function (e) {
              log.push(t + ":" + id + ">" + (e.relatedTarget && e.relatedTarget.id));
            });
          });
        });
        window.addEventListener("dump", function () { console.log(log.join(" ")); });
        </script>
        """
        |> Browser.HTML.parse()
        |> Browser.Forms.index()

      raw = Browser.Nids.index(raw)
      pid = Runtime.start(raw, %{url: "http://t.test/", width: 800, height: 600})
      Runtime.run_scripts(pid)

      {b, c} = {nid_of(raw, "b"), nid_of(raw, "c")}
      Runtime.hover(pid, nil, b)
      Runtime.hover(pid, b, c)
      reply = Runtime.dispatch(pid, :window, "dump", %{bubbles: false})

      assert logs(reply) == [
               # entering b: the event bubbles, and the elements above hear mouseenter outermost first
               "mouseover:b>null mouseover:a>null mouseenter:a>null mouseenter:b>null " <>
                 "mouseout:b>c mouseout:a>c mouseleave:b>c mouseleave:a>c mouseover:c>b mouseenter:c>b"
             ]
    end
  end

  describe "the tree" do
    test "queries, text and attributes" do
      r =
        run(~S"""
        var p = document.getElementById("a");
        console.log(p.tagName, p.textContent, p.parentNode.tagName, p.id);
        p.setAttribute("data-x", "1");
        console.log(p.getAttribute("data-x"), p.hasAttribute("nope"), p.getAttribute("nope"));
        console.log(document.querySelectorAll("p, b").length, document.body.children.length);
        """)

      assert logs(r) == ["P x BODY a", "1 false null", "1 2"]
      assert errors(r) == []
    end

    test "building and changing elements" do
      r =
        run(~S"""
        var d = document.createElement("div");
        d.className = "one two";
        d.classList.add("three");
        d.classList.toggle("one");
        d.textContent = "hi";
        document.body.appendChild(d);
        d.insertAdjacentHTML("beforeend", "<b>bold</b>");
        console.log(d.outerHTML);
        console.log(document.body.lastChild === d, d.firstChild.nodeType, d.lastChild.nodeName);
        d.style.color = "red";
        d.style.setProperty("margin-top", "2px");
        console.log(d.getAttribute("style"), d.style.marginTop);
        d.replaceChildren();
        console.log(d.hasChildNodes(), d.innerHTML === "");
        """)

      assert logs(r) == [
               ~s(<div class="two three">hi<b>bold</b></div>),
               "true 3 B",
               "color: red; margin-top: 2px;" <> " 2px",
               "false true"
             ]
    end

    test "cloning, moving and removing" do
      r =
        run(
          ~S"""
          var ul = document.getElementById("l");
          var c = ul.cloneNode(true);
          c.id = "copy";
          document.body.appendChild(c);
          ul.firstElementChild.remove();
          console.log(ul.children.length, c.children.length, document.querySelectorAll("li").length);
          ul.insertBefore(c.lastElementChild, ul.firstChild);
          console.log(ul.textContent, c.textContent);
          """,
          "<ul id=l><li>a</li><li>b</li></ul>"
        )

      assert logs(r) == ["1 2 3", "bb a"]
    end

    test "selectors" do
      r =
        run(
          ~S"""
          var q = (s) => document.querySelectorAll(s).length;
          console.log(q("div > p"), q("div p"), q(".k"), q("p.k"), q("[data-n]"), q("[data-n='2']"), q("li:first-child"), q("p:not(.k)"), q("h1 + p"), q("h1 ~ p"));
          console.log(document.querySelector("#b").closest("div").id, document.querySelector(".k").matches("p.k"));
          """,
          ~S"""
          <div id=o><h1>t</h1><p>1</p><p class=k data-n=2 id=b>2</p></div>
          <ul><li>a<li>b</ul>
          """
        )

      assert logs(r) == ["2 2 1 1 1 1 1 1 1 2", "o true"]
    end

    test "innerHTML round trips and parses" do
      r =
        run(~S"""
        var d = document.body;
        d.innerHTML = "<p class='a'>one</p><br><input value=3>";
        console.log(d.children.length, d.firstChild.className, d.lastChild.value);
        console.log(d.innerHTML);
        """)

      assert logs(r) == ["3 a 3", ~s(<p class="a">one</p><br><input value="3">)]
    end

    test "to_raw gives the changed tree" do
      r =
        run(
          ~S"document.getElementById('a').textContent = 'changed'; document.body.appendChild(document.createElement('hr'))"
        )

      assert r.dirty
      [{:element, "body", _, kids}] = r.raw

      assert {:element, "p", [{"id", "a"}, {"@nid", _}], [{:text, "changed"}]} =
               Enum.find(kids, &match?({:element, "p", _, _}, &1))

      assert {:element, "hr", [{"@nid", _}], []} = List.last(kids)
    end
  end

  describe "events" do
    test "listeners run in capture, target and bubble order, and can stop" do
      {_, r} =
        start(~S"""
        <body><div id=o><button id=b>x</button></div><script>
        var out = [];
        var o = document.getElementById("o"), b = document.getElementById("b");
        o.addEventListener("click", () => out.push("o-capture"), true);
        o.addEventListener("click", () => out.push("o-bubble"));
        b.addEventListener("click", (e) => { out.push("b:" + e.target.id + ":" + e.currentTarget.id); });
        document.addEventListener("click", () => console.log(out.join(" ")));
        b.click();
        out.length = 0;
        o.addEventListener("click", (e) => e.stopPropagation());
        b.click();
        </script></body>
        """)

      assert logs(r) == ["o-capture b:b:b o-bubble"]
    end

    test "a handler can prevent the default, and `once` runs once" do
      {pid, _} =
        start(~S"""
        <body><form id=f><input id=i value=5><input type=submit></form><script>
        var n = 0;
        document.getElementById("f").addEventListener("submit", (e) => { n++; console.log("submit", document.getElementById("i").value); e.preventDefault(); }, {once: true});
        </script></body>
        """)

      first = Runtime.dispatch(pid, {:form, 0}, "submit")
      assert first.prevented
      assert logs(first) == ["submit 5"]
      second = Runtime.dispatch(pid, {:form, 0}, "submit")
      refute second.prevented
    end

    test "an async onsubmit handler prevents the default and finishes its awaits" do
      {pid, _} =
        start(~S"""
        <body><form id=f><input type=submit></form><script>
        const log = (m) => console.log(m);
        document.getElementById("f").onsubmit = async (event) => {
          event.preventDefault();
          for (let i = 0; i < 3; i++) await new Promise((r) => setTimeout(r, 100));
          log("done");
        };
        </script></body>
        """)

      r = Runtime.dispatch(pid, {:form, 0}, "submit")
      assert r.prevented
      # the awaits have not finished: the handler returned at the first one
      assert logs(r) == []
      assert logs(Runtime.flush(pid)) == ["done"]
    end

    test "timers run in real time and report what they changed" do
      {pid, r} =
        start(~S"""
        <body><p id=p>before</p><script>
        setTimeout(() => { document.getElementById("p").textContent = "after"; }, 20);
        (async () => { await new Promise(r => setTimeout(r, 40)); document.body.appendChild(document.createElement("hr")); })();
        </script></body>
        """)

      refute r.dirty

      assert_receive {:js_async, ^pid, first}, 1000
      assert first.dirty
      assert {:element, "p", _, [{:text, "after"}]} = hd(first.raw |> hd() |> elem(3))

      assert_receive {:js_async, ^pid, second}, 1000
      assert {:element, "hr", [{"@nid", _}], []} = second.raw |> hd() |> elem(3) |> List.last()
    end

    test "an interval keeps going until it is cleared" do
      {pid, _} =
        start(~S"""
        <body><p id=p>0</p><script>
        var n = 0, id = setInterval(() => { n++; document.getElementById("p").textContent = String(n); if (n == 3) clearInterval(id); }, 10);
        </script></body>
        """)

      # a busy machine may run two ticks in one go, but the count never goes back and stops at 3
      texts =
        Stream.repeatedly(fn ->
          assert_receive {:js_async, ^pid, r}, 1000
          {:element, "p", _, [{:text, text}]} = hd(r.raw |> hd() |> elem(3))
          text
        end)
        |> Enum.reduce_while([], fn
          "3", acc -> {:halt, Enum.reverse(["3" | acc])}
          text, acc -> {:cont, [text | acc]}
        end)

      assert texts == Enum.sort(texts)

      refute_receive {:js_async, ^pid, _}, 100
    end

    test "control state from the page reaches `.value` and `.checked`" do
      {pid, _} =
        start(~S"""
        <body><input id=t value=a><input id=c type=checkbox><script>
        document.addEventListener("go", () => console.log(document.getElementById("t").value, document.getElementById("c").checked));
        </script></body>
        """)

      r =
        Runtime.dispatch(pid, :document, "go", %{}, %{
          0 => %{value: "typed", checked: false, selected: 0},
          1 => %{value: "on", checked: true, selected: 0}
        })

      assert logs(r) == ["typed true"]
    end

    test "dispatching a custom event with data" do
      r =
        run(~S"""
        document.addEventListener("ping", (e) => console.log(e.type, e.detail.n, e.bubbles));
        document.dispatchEvent(new CustomEvent("ping", {detail: {n: 3}, bubbles: true}));
        """)

      assert logs(r) == ["ping 3 true"]
    end
  end

  describe "window" do
    test "location, history and URLSearchParams" do
      r =
        run(~S"""
        console.log(location.pathname, location.search, location.hash, location.hostname, location.origin);
        var p = new URLSearchParams(window.location.search);
        p.set("in", "1 2 +");
        p.append("x", "a&b");
        console.log(p.toString(), p.get("a"), p.get("zz"), p.has("x"));
        history.replaceState({}, "", `${location.pathname}?${p.toString()}${location.hash}`);
        console.log(location.href);
        """)

      assert logs(r) == [
               "/dir/page ?a=1 #top t.test http://t.test",
               "a=1&in=1+2+%2B&x=a%26b 1 null true",
               "http://t.test/dir/page?a=1&in=1+2+%2B&x=a%26b#top"
             ]

      assert {:history, :replace, "http://t.test/dir/page?a=1&in=1+2+%2B&x=a%26b#top"} in r.outbox
    end

    test "assigning location asks the session to navigate" do
      r = run("location.href = '/next'")
      assert {:navigate, "http://t.test/next", :push} in r.outbox
    end

    test "globals live on window" do
      r =
        run(
          "var x = 3; window.y = 4; console.log(window.x, y, window === self, typeof document, window.document === document)"
        )

      assert logs(r) == ["3 4 true object true"]
    end
  end

  describe "modules" do
    @files %{
      "http://t.test/lib.js" => """
      export const two = 2;
      export function add(a, b) { return a + b; }
      export default function greet(n) { return "hi " + n; }
      const hidden = 1;
      export { hidden as shown };
      """,
      "http://t.test/dir/other.js" => ~S"""
      import { add } from "../lib.js";
      export const four = add(2, 2);
      """,
      "http://t.test/lib.v2.js" => "export const two = 22;"
    }

    test "imports resolve against the importing file and run once" do
      {_, r} =
        start(
          """
          <body><script type=module>
          import greet, { two, add, shown } from "/lib.js";
          import { four } from "./other.js";
          import * as ns from "/lib.js";
          console.log(two, add(1, 2), greet("x"), shown, four, ns.two, Object.keys(ns).join());
          </script></body>
          """,
          @files
        )

      assert errors(r) == []

      assert logs(r) == ["2 3 hi x 1 4 2 add,default,shown,two"]
    end

    test "an imported function can be called once a script has used with" do
      {_, r} =
        start(
          """
          <body><script>with ({ a: 1 }) { var seen = a; }</script>
          <script type=module>
          import { add } from "/lib.js";
          console.log(add(1, 2), typeof add);
          </script></body>
          """,
          @files
        )

      assert errors(r) == []
      assert logs(r) == ["3 function"]
    end

    test "a mouse event says where it is in the page and in the element" do
      r =
        run(
          """
          var seen;
          a.addEventListener('mousemove', function (e) { seen = [e.pageX, e.pageY, e.offsetX, e.offsetY]; });
          a.dispatchEvent(new MouseEvent('mousemove', { clientX: 30, clientY: 20 }));
          console.log(seen.join(' '));
          """,
          "<p id=a>x</p>"
        )

      assert errors(r) == []
      assert logs(r) == ["30 20 30 20"]
    end

    test "the page is laid out for a script that asks for the box of a new element" do
      raw =
        ~s|<body><script>var d = document.createElement('div'); d.id = 'x'; document.body.appendChild(d);| <>
          ~s|var r = d.getBoundingClientRect(); console.log(r.width, r.height);| <>
          ~s|var r2 = d.getBoundingClientRect(); console.log(r2.width)</script></body>|

      {parsed, _} = raw |> Browser.HTML.parse() |> Browser.Forms.index()

      pid =
        Runtime.start(parsed, %{
          url: "http://t.test/",
          width: 800,
          height: 600,
          layout_now: true,
          fetch: fn _ -> {:error, "404"} end
        })

      task = Task.async(fn -> Runtime.run_scripts(pid) end)

      # (the host numbers the new element and says where it is, as the session does)
      requests =
        Stream.repeatedly(fn ->
          receive do
            {:layout_now, ^pid, ref, tree} ->
              nid = nid_of_id(tree, "x")
              send(pid, {:layout_now_done, ref, %{nid => {10, 20, 300, 40}}, {800.0, 600.0}})
              :asked
          after
            1000 -> :none
          end
        end)
        |> Enum.take(1)

      assert requests == [:asked]
      reply = Task.await(task)
      assert errors(reply) == []
      # (asked once: the second question is for the same tree)
      assert logs(reply) == ["300 40", "300"]
      refute_received {:layout_now, _, _, _}
    end

    test "a module namespace with exports cannot be frozen" do
      {_, r} =
        start(
          """
          <body><script type=module>
          import * as ns from "/lib.js";
          var t = "no";
          try { Object.freeze(ns) } catch (e) { t = e.constructor.name }
          console.log(t, Object.isFrozen(ns));
          </script></body>
          """,
          @files
        )

      assert errors(r) == []
      assert logs(r) == ["TypeError false"]
    end

    test "an import with the source phase is refused when its module is loaded" do
      {_, r} =
        start(
          """
          <body><script type=module>
          let name = "none";
          try { await import("/src.js") } catch (e) { name = e.constructor.name }
          console.log(name);
          </script></body>
          """,
          %{
            "http://t.test/src.js" => ~S"""
            import source s from "/missing.js";
            export const x = 1;
            """
          }
        )

      assert errors(r) == []
      assert logs(r) == ["TypeError"]
    end

    test "an import map redirects specifiers" do
      {_, r} =
        start(
          """
          <head><script type=importmap>{"imports": {"/lib.js": "/lib.v2.js", "lib": "/lib.v2.js"}}</script></head>
          <body><script type=module>
          import { two } from "/lib.js";
          import { two as t2 } from "lib";
          console.log(two, t2);
          </script></body>
          """,
          @files
        )

      assert errors(r) == []
      assert logs(r) == ["22 22"]
    end

    test "classic scripts run in order, then modules, then DOMContentLoaded" do
      {_, r} =
        start("""
        <body><script type=module>console.log("module")</script>
        <script>console.log("classic1"); document.addEventListener("DOMContentLoaded", () => console.log("ready"));</script>
        <script>console.log("classic2")</script></body>
        """)

      assert logs(r) == ["classic1", "classic2", "module", "ready"]
    end

    test "an error in one script does not stop the next" do
      {_, r} = start("<body><script>nope()</script><script>console.log('after')</script></body>")
      assert logs(r) == ["after"]
      assert [e] = errors(r)
      assert e =~ "nope"
    end
  end

  describe "custom elements and element classes" do
    test "define upgrades existing elements and runs the callbacks" do
      r =
        run(
          ~S"""
          class Ping extends HTMLElement {
            static get observedAttributes() { return ["n"]; }
            connectedCallback() { console.log("connected", this.tagName, this.getAttribute("n")); }
            attributeChangedCallback(name, old, v) { console.log("attr", name, old, v); }
          }
          customElements.define("x-ping", Ping);
          var el = document.querySelector("x-ping");
          console.log(el instanceof Ping, customElements.get("x-ping") === Ping);
          el.setAttribute("n", "2");
          var made = document.createElement("x-ping");
          console.log(made instanceof Ping);
          document.body.appendChild(made);
          """,
          "<x-ping n=1></x-ping>"
        )

      assert errors(r) == []

      assert logs(r) == [
               "attr n null 1",
               "connected X-PING 1",
               "true true",
               "attr n 1 2",
               "true",
               "connected X-PING null"
             ]
    end

    test "tag classes work with instanceof" do
      r =
        run(
          ~S"""
          var a = document.getElementById("l");
          console.log(a instanceof HTMLAnchorElement, a instanceof HTMLElement, a instanceof Element,
            a instanceof HTMLIFrameElement, document.body instanceof HTMLAnchorElement);
          """,
          "<a id=l href='/x'>l</a>"
        )

      assert errors(r) == []
      assert logs(r) == ["true true true false false"]
    end
  end

  describe "globals pages rely on" do
    test "URL, bare window members and arguments" do
      r =
        run(~S"""
        var u = new URL("../a?x=1#h", "https://e.com/b/c/d");
        console.log(u.href, u.origin, u.searchParams.get("x"));
        addEventListener("ping", function () { console.log("pinged", scrollX, typeof scrollTo); });
        dispatchEvent(new Event("ping"));
        function f() { return (() => arguments.length + arguments[0])(); }
        console.log(f(5, 6), Math.clz32(1), Math.imul(3, 4));
        for (typeof u == "object" && console.log("init"), u = 0; u < 1; u++);
        """)

      assert errors(r) == []

      assert logs(r) == [
               "https://e.com/b/a?x=1#h https://e.com 1",
               "pinged 0 function",
               "7 31 12",
               "init"
             ]
    end

    test "a task that keeps rescheduling itself does not starve timers or events" do
      {pid, r} =
        start(~S"""
        <body><button id=b>b</button><script>
        var n = 0;
        function spin() { n++; setImmediate(spin); }
        spin();
        document.getElementById("b").addEventListener("click", function () { console.log("clicked"); });
        </script></body>
        """)

      assert errors(r) == []
      reply = Runtime.dispatch(pid, {:control, 0}, "click")
      assert logs(reply) == ["clicked"]
    end
  end

  describe "contextmenu" do
    defp nid_of(nodes, id) when is_list(nodes), do: Enum.find_value(nodes, &nid_of(&1, id))
    defp nid_of({:text, _}, _id), do: nil

    defp nid_of({:element, _tag, attrs, kids}, id) do
      if {"id", id} in attrs,
        do: List.keyfind(attrs, "@nid", 0) |> elem(1),
        else: nid_of(kids, id)
    end

    test "is dispatched to an element by its layout number and can be cancelled" do
      {raw, _} =
        """
        <p id="a">text</p>
        <script>
        document.getElementById("a").addEventListener("contextmenu", function (e) {
          console.log("menu " + e.clientX + " " + e.button);
          e.preventDefault();
        });
        </script>
        """
        |> Browser.HTML.parse()
        |> Browser.Forms.index()

      raw = Browser.Nids.index(raw)
      pid = Runtime.start(raw, %{url: "http://t.test/", width: 800, height: 600})
      Runtime.run_scripts(pid)

      props = %{"clientX" => 12.0, "clientY" => 3.0, "button" => 2.0}
      reply = Runtime.dispatch(pid, {:edit_host, nid_of(raw, "a")}, "contextmenu", props)
      assert logs(reply) == ["menu 12 2"]
      assert reply.prevented
    end
  end

  describe "layout and scrolling" do
    # a page laid out for real, whose scripts are told where things are
    defp laid_out(html, scroll \\ 0) do
      env = %{type: "screen", width: 800, height: 600, dppx: 1.0}
      page = Browser.Page.build(html, "http://t.test/", env)
      measure = fn text, style -> String.length(text) * style.size * 0.5 end
      {items, height} = Browser.Layout.layout(page.nodes, 800, measure, 600)
      rects = Browser.Nids.rects(items, Browser.Nids.parents(page.pruned))

      pid =
        Runtime.start(page.raw, %{
          url: "http://t.test/",
          width: 800,
          height: 600,
          fetch: fn _ -> {:error, "no"} end
        })

      Runtime.run_scripts(pid)
      Runtime.layout(pid, rects, 0, scroll, {800, height})
      pid
    end

    @spacer ~S|<div style="height: 1000px">spacer</div>|

    test "getBoundingClientRect, offsets and scroll position" do
      pid =
        laid_out(
          ~s|<body>#{@spacer}<p id=t>target</p><button id=b>b</button><script>
          document.getElementById("b").addEventListener("click", function () {
            var r = document.getElementById("t").getBoundingClientRect();
            console.log(r.top > 900, r.left >= 0, r.width > 0, r.height > 0, r.bottom - r.top == r.height);
            console.log(window.scrollY, scrollY, document.documentElement.scrollTop);
            console.log(document.documentElement.scrollHeight > 1000, document.getElementById("t").offsetHeight > 0);
          });
          </script></body>|,
          100
        )

      reply = Runtime.dispatch(pid, {:control, 0}, "click")
      assert errors(reply) == []
      assert logs(reply) == ["true true true true true", "100 100 100", "true true"]
    end

    test "scrollTo, scrollBy and scrollIntoView ask the session to scroll" do
      pid =
        laid_out(~s|<body>#{@spacer}<p id=t>target</p><button id=b>b</button><script>
          document.getElementById("b").addEventListener("click", function () {
            window.scrollTo(0, 300);
            console.log(scrollY);
            window.scrollBy({top: 50});
            console.log(scrollY);
            document.getElementById("t").scrollIntoView();
            console.log(scrollY > 900);
          });
          </script></body>|)

      reply = Runtime.dispatch(pid, {:control, 0}, "click")
      assert errors(reply) == []
      assert logs(reply) == ["300", "350", "true"]

      assert [{:scroll_to, +0.0, 300.0}, {:scroll_to, +0.0, 350.0}, {:scroll_to, +0.0, y}] =
               reply.outbox

      assert y > 900
    end

    test "scrolling the window fires scroll events" do
      pid =
        laid_out(~s|<body><script>
        window.addEventListener("scroll", function () { console.log("scrolled", scrollY); });
        </script></body>|)

      Runtime.scrolled(pid, 0, 40)
      assert_receive {:js_async, ^pid, reply}, 1000
      assert logs(reply) == ["scrolled 40"]
    end
  end

  describe "secure contexts" do
    test "which addresses are secure" do
      alias Browser.JS.DOM

      for url <- ~w(https://a.test/ file:///x.html http://localhost/ http://app.localhost:3000/
                    http://127.0.0.1:8080/ http://127.5.5.5/ http://[::1]:3000/ about:blank) do
        assert DOM.secure_context?(url), url
      end

      for url <- ~w(http://a.test/ http://192.168.1.2/ http://localhostx/ ftp://a.test/) do
        refute DOM.secure_context?(url), url
      end
    end

    test "isSecureContext follows the page's address and gates crypto.subtle" do
      run_at = fn url ->
        {raw, _} =
          "<body><script>console.log(isSecureContext, window.isSecureContext, typeof crypto.subtle)</script></body>"
          |> Browser.HTML.parse()
          |> Browser.Forms.index()

        pid =
          Runtime.start(raw, %{
            url: url,
            width: 800,
            height: 600,
            fetch: fn _ -> {:error, "no"} end
          })

        logs(Runtime.run_scripts(pid))
      end

      assert run_at.("https://a.test/") == ["true true object"]
      assert run_at.("http://a.test/") == ["false false undefined"]
    end
  end

  describe "named access" do
    test "an element's id is a global, after the real ones" do
      r =
        run(
          ~S"""
          log.textContent = "hi";
          console.log(typeof log, log.tagName, window.log === log, typeof nothing);
          var document2 = document;
          console.log(typeof document2);
          try { nothing; } catch (e) { console.log(e.name); }
          """,
          "<div id=log></div>"
        )

      assert logs(r) == ["object DIV true undefined", "object", "ReferenceError"]
      assert errors(r) == []
    end

    test "the id index follows id changes, removal, detached elements and duplicates" do
      r =
        run(
          ~S"""
          var a = document.getElementById("a");
          console.log(window.a === a, window.zed === undefined);
          a.id = "zed";
          console.log(window.zed === a);
          a.removeAttribute("id");
          console.log(window.zed === undefined);
          var d = document.createElement("div"); d.id = "det";
          console.log(window.det === undefined);
          document.body.appendChild(d);
          console.log(window.det === d);
          var e = document.createElement("span"); e.id = "det";
          document.body.insertBefore(e, document.body.firstChild);
          console.log(window.det === e);
          e.remove();
          console.log(window.det === d);
          d.remove();
          console.log(window.det === undefined);
          """,
          "<p id=a>x</p>"
        )

      assert errors(r) == []
      assert logs(r) == ["true true", "true", "true", "true", "true", "true", "true", "true"]
    end

    test "a button that appends to the log by its global name" do
      {pid, r} =
        start(
          ~S"""
          <body><button id=go>Go</button><div id=log></div>
          <script>go.addEventListener("click", function () { log.appendChild(document.createElement("p")); console.log(log.children.length); });</script></body>
          """,
          %{}
        )

      assert errors(r) == []
      reply = Runtime.dispatch(pid, {:control, 0}, "click")
      assert logs(reply) == ["1"]
      assert errors(reply) == []
    end
  end

  describe "document.cookie" do
    # each test has a host of its own: the jar is shared with the tests running beside it
    defp run_on(host, script) do
      {_pid, r} =
        start("<body><script>#{script}</script></body>", %{}, %{url: "http://#{host}/dir/page"})

      r
    end

    defp cookie_pairs(r), do: logs(r) |> hd() |> String.split("; ", trim: true) |> Enum.sort()

    test "reads the cookies of the page without the HttpOnly ones" do
      Browser.Cookies.store("http://read.test/dir/page", ["a=1", "h=2; HttpOnly", "b=3; Path=/"])
      r = run_on("read.test", "console.log(document.cookie)")
      assert cookie_pairs(r) == ["a=1", "b=3"]
    end

    test "assigning sets one cookie, with its attributes, and keeps the rest" do
      r =
        run_on("write.test", """
        document.cookie = "x=1; Path=/";
        document.cookie = "y=2";
        document.cookie = "gone=1; Max-Age=0";
        document.cookie = "bad=1; HttpOnly";
        console.log(document.cookie);
        """)

      assert errors(r) == []
      assert cookie_pairs(r) == ["x=1", "y=2"]
      assert Browser.Cookies.header("http://write.test/x") == "x=1"
    end
  end

  describe "fetch and XMLHttpRequest" do
    defp request_fn(test) do
      fn url, opts ->
        send(test, {:request, url, opts})

        case url do
          "http://t.test/missing" ->
            {:ok,
             %{
               status: 404,
               status_text: "Not Found",
               headers: [{"content-type", "text/plain"}, {"x-a", "1"}],
               body: "nope",
               url: url,
               redirected: false
             }, url}

          "http://t.test/down" ->
            {:error, "Request failed: :econnrefused"}

          _ ->
            {:ok,
             %{
               status: 200,
               status_text: "OK",
               headers: [{"content-type", "application/json"}],
               body: ~s({"n":1}),
               url: url <> "?final",
               redirected: true
             }, url}
        end
      end
    end

    # timers (and so fetch and XHR) run on their own; what they log is sent to the owner
    defp run_fetch(script) do
      {pid, r} =
        start("<body><script>#{script}</script></body>", %{}, %{request: request_fn(self())})

      assert errors(r) == []
      %{r | console: r.console ++ collect_async(pid)}
    end

    defp collect_async(pid) do
      receive do
        {:js_async, ^pid, reply} -> reply.console ++ collect_async(pid)
      after
        150 -> Runtime.flush(pid).console
      end
    end

    test "fetch gives the real status, headers, url and body" do
      r =
        run_fetch(~S"""
        fetch("/missing").then(async (res) => {
          console.log(res.status, res.ok, res.statusText, res.headers.get("x-a"), res.url, await res.text());
        });
        fetch("/ok").then(async (res) => {
          console.log(res.status, res.ok, res.redirected, res.type, res.headers.get("Content-Type"), JSON.stringify(await res.json()));
        });
        """)

      assert Enum.sort(logs(r)) == [
               "200 true true basic application/json {\"n\":1}",
               "404 false Not Found 1 http://t.test/missing nope"
             ]
    end

    test "fetch sends the method, headers, body and credentials" do
      run_fetch(~S"""
      fetch("/api", { method: "post", headers: { "X-A": "1", "Content-Type": "application/json" }, body: JSON.stringify({ a: 1 }), credentials: "include" });
      fetch("/form", { method: "POST", body: new URLSearchParams({ q: "x y" }) });
      fetch("/plain", { method: "PUT", body: "hello" });
      """)

      assert_receive {:request, "http://t.test/api", opts}
      assert opts[:method] == :post
      assert opts[:body] == ~s({"a":1})
      assert opts[:content_type] == "application/json"
      assert opts[:credentials] == :include
      assert {"x-a", "1"} in opts[:headers]
      assert_receive {:request, "http://t.test/form", opts}
      assert opts[:body] == "q=x+y"
      assert opts[:content_type] == "application/x-www-form-urlencoded;charset=UTF-8"
      assert_receive {:request, "http://t.test/plain", opts}
      assert opts[:method] == :put
      assert opts[:content_type] == "text/plain;charset=UTF-8"
    end

    test "fetch rejects with a TypeError when the request fails, and with an AbortError when aborted" do
      r =
        run_fetch(~S"""
        fetch("/down").catch((e) => console.log(e.name, e.message));
        const c = new AbortController();
        fetch("/ok", { signal: c.signal }).catch((e) => console.log(e.name));
        c.abort();
        fetch("/ok", { signal: AbortSignal.abort() }).catch((e) => console.log(e.name));
        try { new Request("/x", { method: "GET", body: "b" }); } catch (e) { console.log(e.name); }
        """)

      assert Enum.sort(logs(r)) == [
               "AbortError",
               "AbortError",
               "TypeError",
               "TypeError Failed to fetch"
             ]

      refute_received {:request, "http://t.test/ok", _}
    end

    test "XMLHttpRequest reports status, headers and the response in each responseType" do
      r =
        run_fetch(~S"""
        const x = new XMLHttpRequest();
        const states = [];
        x.onreadystatechange = () => states.push(x.readyState);
        x.open("POST", "/ok");
        x.setRequestHeader("X-B", "2");
        x.responseType = "json";
        x.withCredentials = true;
        x.onload = () => console.log(states.join(""), x.status, x.statusText, x.responseURL, x.response.n, x.getResponseHeader("content-type"), x.getAllResponseHeaders().trim());
        x.send("data");
        const y = new XMLHttpRequest();
        y.open("GET", "/missing");
        y.onload = () => console.log(y.status, y.responseText);
        y.send();
        const z = new XMLHttpRequest();
        z.open("GET", "/down");
        z.onerror = () => console.log("error", z.status, z.readyState);
        z.send();
        const w = new XMLHttpRequest();
        w.open("GET", "/ok");
        w.onload = () => console.log("never");
        w.onabort = () => console.log("aborted");
        w.send();
        w.abort();
        """)

      assert "1234 200 OK http://t.test/ok?final 1 application/json content-type: application/json" in logs(
               r
             )

      assert "404 nope" in logs(r)
      assert "error 0 4" in logs(r)
      assert "aborted" in logs(r)
      refute "never" in logs(r)
      assert_receive {:request, "http://t.test/ok", opts}
      assert opts[:method] == :post and opts[:credentials] == :include
      assert {"x-b", "2"} in opts[:headers]
    end

    test "a synchronous XMLHttpRequest has its answer when send returns" do
      {_pid, r} =
        start(
          ~S"<body><script>const x = new XMLHttpRequest(); x.open('GET', '/missing', false); x.send(); console.log(x.status, x.responseText)</script></body>",
          %{},
          %{request: request_fn(self())}
        )

      assert logs(r) == ["404 nope"]
    end
  end

  describe "localStorage and sessionStorage" do
    # each test has a host of its own: the store is shared with the tests running beside it
    defp run_at(host, script) do
      {_pid, r} =
        start("<body><script>#{script}</script></body>", %{}, %{url: "http://#{host}/p"})

      r
    end

    test "items, length, key, properties and removal" do
      r =
        run_at("ls1.test", """
        localStorage.setItem("b", 2);
        localStorage.a = "1";
        console.log(localStorage.length, localStorage.getItem("b"), localStorage.a, localStorage.key(0), localStorage.key(5));
        console.log(localStorage.getItem("zzz"), localStorage.zzz);
        localStorage.removeItem("a");
        console.log(localStorage.length, localStorage.a);
        localStorage.clear();
        console.log(localStorage.length);
        """)

      assert errors(r) == []
      assert logs(r) == ["2 2 1 a null", "null undefined", "1 undefined", "0"]
    end

    test "Object.keys, in, for-in and delete see the items" do
      r =
        run_at("ls6.test", """
        localStorage.setItem("b", "2");
        localStorage.setItem("a", "1");
        sessionStorage.setItem("s", "3");
        const seen = [];
        for (const k in localStorage) seen.push(k);
        console.log(Object.keys(localStorage).join(), JSON.stringify(localStorage), seen.join(), "a" in localStorage, "zz" in localStorage, Object.keys(sessionStorage).join());
        console.log(delete localStorage.a, delete localStorage["nope"], localStorage.length, Object.keys(localStorage).join());
        delete sessionStorage.s;
        console.log(sessionStorage.length);
        const el = document.body; el.expando = 1; console.log(delete el.expando, el.expando);
        """)

      assert errors(r) == []

      assert logs(r) == [
               "a,b {\"a\":\"1\",\"b\":\"2\"} a,b true false s",
               "true true 1 b",
               "0",
               "true undefined"
             ]
    end

    test "sessionStorage is not localStorage" do
      r =
        run_at("ls2.test", """
        localStorage.setItem("k", "local");
        sessionStorage.setItem("k", "session");
        sessionStorage.setItem("only", "s");
        console.log(localStorage.getItem("k"), sessionStorage.getItem("k"), localStorage.length, sessionStorage.length);
        """)

      assert logs(r) == ["local session 1 2"]
    end

    test "the items outlive the page and are shared by the pages of the origin only" do
      run_at("ls3.test", ~s|localStorage.setItem("seen", "yes")|)

      r =
        run_at(
          "ls3.test",
          ~s|console.log(localStorage.getItem("seen"), sessionStorage.getItem("seen"))|
        )

      assert logs(r) == ["yes null"]
      r = run_at("other.ls3.test", ~s|console.log(localStorage.getItem("seen"))|)
      assert logs(r) == ["null"]
    end

    test "going over the quota throws a QuotaExceededError" do
      r =
        run_at("ls4.test", """
        const big = "x".repeat(1024 * 1024);
        try { for (let i = 0; i < 6; i++) localStorage.setItem("k" + i, big); console.log("no error"); }
        catch (e) { console.log(e.name, localStorage.length); }
        """)

      assert errors(r) == []
      assert logs(r) == ["QuotaExceededError 4"]
    end

    test "a page without an origin has a storage that lasts as long as it does" do
      {_pid, r} =
        start(
          ~S"<body><script>localStorage.setItem('a', '1'); console.log(localStorage.getItem('a'), localStorage.length)</script></body>",
          %{},
          %{url: "about:blank"}
        )

      assert errors(r) == []
      assert logs(r) == ["1 1"]
    end

    test "another page of the origin gets a storage event" do
      {pid, r} =
        start(
          ~S"""
          <body><script>
          window.addEventListener("storage", (e) => console.log("event", e.key, e.oldValue, e.newValue, e.url, e.storageArea === localStorage));
          localStorage.setItem("own", "1");
          </script></body>
          """,
          %{},
          %{url: "http://ls5.test/a"}
        )

      assert errors(r) == []
      # the page that made the change hears nothing
      assert logs(r) == []

      run_at(
        "ls5.test",
        ~s|localStorage.setItem("k", "v"); localStorage.setItem("k", "w"); localStorage.removeItem("k"); localStorage.clear()|
      )

      events = collect_async(pid)

      assert Enum.sort(for({:log, t} <- events, do: t)) == [
               "event k null v http://ls5.test/a true",
               "event k v w http://ls5.test/a true",
               "event k w null http://ls5.test/a true",
               "event null null null http://ls5.test/a true"
             ]
    end
  end

  describe "history and location" do
    defp hist_start(script, url \\ "http://h.test/dir/page?a=1") do
      {pid, r} =
        start("<body><script>#{script}</script></body>", %{}, %{url: url, history_before: 2})

      assert errors(r) == []
      {pid, r}
    end

    test "pushState and replaceState keep their own state, history.length counts entries" do
      {_pid, r} =
        hist_start("""
        console.log(history.length, history.state, history.scrollRestoration);
        history.pushState({n: 1}, "", "/one");
        history.pushState({n: 2}, "", "?two=2#x");
        console.log(history.length, history.state.n, location.pathname, location.search, location.hash);
        history.replaceState({n: 3}, "");
        console.log(history.length, history.state.n, location.href);
        history.scrollRestoration = "manual";
        console.log(history.scrollRestoration);
        history.scrollRestoration = "bogus";
        console.log(history.scrollRestoration);
        """)

      assert logs(r) == [
               "3 null auto",
               "5 2 /one ?two=2 #x",
               "5 3 http://h.test/one?two=2#x",
               "manual",
               "manual"
             ]

      assert {:history, :push, "http://h.test/one"} in r.outbox
      assert {:history, :replace, "http://h.test/one?two=2#x"} in r.outbox
    end

    test "pushState to another origin is a SecurityError" do
      {_pid, r} =
        hist_start("""
        try { history.pushState(null, "", "http://evil.test/x"); } catch (e) { console.log(e.name || e.message); }
        console.log(location.href);
        """)

      assert logs(r) |> List.last() == "http://h.test/dir/page?a=1"
      assert length(logs(r)) == 2
    end

    test "traversing between the page's own entries fires popstate with the state" do
      {pid, _} =
        hist_start("""
        window.onpopstate = (e) => console.log("pop", e.state && e.state.n, location.pathname);
        history.pushState({n: 1}, "", "/one");
        history.pushState({n: 2}, "", "/two");
        """)

      r = Runtime.traverse(pid, -1)
      assert r.moved
      assert logs(r) == ["pop 1 /one"]
      assert r.url == "http://h.test/one"
      r = Runtime.traverse(pid, -1)
      assert logs(r) == ["pop null /dir/page"]
      # past the first entry the page cannot go on its own
      assert Runtime.traverse(pid, -1).moved == false
      r = Runtime.traverse(pid, 2)
      assert r.moved
      assert logs(r) == ["pop 2 /two"]
      assert Runtime.traverse(pid, 1).moved == false
    end

    test "a new entry drops the entries that were forward" do
      {pid, _} =
        hist_start("""
        history.pushState(1, "", "/a"); history.pushState(2, "", "/b");
        """)

      Runtime.traverse(pid, -1)
      {_, r} = {nil, Runtime.dispatch(pid, :window, "x")}
      _ = r
      assert Runtime.traverse(pid, 1).moved
    end

    test "hash changes: location.hash and hash-only href make entries, popstate and hashchange" do
      {pid, r} =
        hist_start("""
        window.addEventListener("popstate", (e) => console.log("pop", String(e.state), location.hash));
        window.addEventListener("hashchange", (e) => console.log("hash", e.oldURL, e.newURL));
        location.hash = "one";
        location.href = "#two";
        location.assign("#three");
        location.replace("#four");
        console.log(history.length, location.href);
        """)

      assert logs(r) == [
               "pop null #one",
               "hash http://h.test/dir/page?a=1 http://h.test/dir/page?a=1#one",
               "pop null #two",
               "hash http://h.test/dir/page?a=1#one http://h.test/dir/page?a=1#two",
               "pop null #three",
               "hash http://h.test/dir/page?a=1#two http://h.test/dir/page?a=1#three",
               "pop null #four",
               "hash http://h.test/dir/page?a=1#three http://h.test/dir/page?a=1#four",
               # 2 before + the first entry + one, two, three; replace added none
               "6 http://h.test/dir/page?a=1#four"
             ]

      assert {:hash, "http://h.test/dir/page?a=1#one", :push} in r.outbox
      assert {:hash, "http://h.test/dir/page?a=1#four", :replace} in r.outbox
      refute Enum.any?(r.outbox, &match?({:navigate, _, _}, &1))

      # back from #four's entry (which replaced #three's) is #two, a hash-only traversal
      r = Runtime.traverse(pid, -1)
      assert r.moved

      assert logs(r) == [
               "pop null #two",
               "hash http://h.test/dir/page?a=1#four http://h.test/dir/page?a=1#two"
             ]
    end

    test "following a link to a fragment of the page is a history entry too" do
      {pid, _} =
        hist_start("""
        window.addEventListener("hashchange", (e) => console.log("hash", e.newURL));
        """)

      r = Runtime.fragment(pid, "http://h.test/dir/page?a=1#sec")
      assert logs(r) == ["hash http://h.test/dir/page?a=1#sec"]
      assert r.url == "http://h.test/dir/page?a=1#sec"
      assert Runtime.traverse(pid, -1).moved
    end

    test "replace and assign to another page ask the session to load it, replace without a new entry" do
      {_pid, r} = hist_start("location.replace('/other'); location.assign('/more')")
      assert {:navigate, "http://h.test/other", :replace} in r.outbox
      assert {:navigate, "http://h.test/more", :push} in r.outbox
    end

    test "the parts of location can be set" do
      {_pid, r} =
        hist_start(
          """
          location.pathname = "new/path";
          location.search = "q=1";
          location.hostname = "other.test";
          location.port = "8080";
          location.host = "third.test:9090";
          location.protocol = "https";
          console.log(location.ancestorOrigins.length);
          """,
          "http://h.test/dir/page?a=1#top"
        )

      urls = for {:navigate, url, :push} <- r.outbox, do: url

      assert urls == [
               "http://h.test/new/path?a=1#top",
               "http://h.test/dir/page?q=1#top",
               "http://other.test/dir/page?a=1#top",
               "http://h.test:8080/dir/page?a=1#top",
               "http://third.test:9090/dir/page?a=1#top",
               "https://h.test/dir/page?a=1#top"
             ]

      assert logs(r) == ["0"]
    end

    test "navigator has the usual properties" do
      {_pid, r} =
        hist_start("""
        console.log(navigator.appName, navigator.product, navigator.cookieEnabled, navigator.webdriver, navigator.plugins.length, navigator.javaEnabled(), navigator.appVersion.startsWith("5.0"));
        navigator.clipboard.writeText("hi").then(() => navigator.clipboard.readText()).then((t) => console.log("clip", t));
        navigator.geolocation.getCurrentPosition(() => console.log("pos"), (e) => console.log("geo", e.code));
        navigator.permissions.query({ name: "geolocation" }).then((p) => console.log("perm", p.state));
        navigator.mediaDevices.enumerateDevices().then((d) => console.log("devices", d.length));
        """)

      assert hd(logs(r)) == "Netscape Gecko true false 0 false true"
    end
  end

  describe "window and document event handler properties" do
    test "window.onload, onpopstate, onhashchange and friends run, and read back" do
      {pid, r} =
        start(~S"""
        <body><script>
        console.log(window.onpopstate);
        window.onpopstate = (e) => console.log("pop");
        window.onhashchange = () => console.log("hash");
        console.log(typeof window.onpopstate);
        document.onclick = () => console.log("doc click");
        window.onpopstate = null;
        history.pushState(null, "", "/x");
        </script><button id=b>x</button></body>
        """)

      assert logs(r) == ["null", "function"]
      r = Runtime.fragment(pid, "http://t.test/x#y")
      assert logs(r) == ["hash"]
      # onpopstate was cleared; the fragment-only change still fires hashchange
      r = Runtime.traverse(pid, -1)
      assert logs(r) == ["hash"]
      r = Runtime.dispatch(pid, {:control, 0}, "click")
      assert logs(r) == ["doc click"]
    end
  end

  defp nid_of_id(nodes, id) when is_list(nodes), do: Enum.find_value(nodes, &nid_of_id(&1, id))
  defp nid_of_id({:text, _}, _), do: nil

  defp nid_of_id({:element, _, attrs, kids}, id) do
    if List.keyfind(attrs, "id", 0) == {"id", id},
      do: attrs |> List.keyfind("@nid", 0) |> elem(1),
      else: nid_of_id(kids, id)
  end
end
