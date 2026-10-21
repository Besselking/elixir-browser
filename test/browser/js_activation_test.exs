defmodule Browser.JS.ActivationTest do
  use ExUnit.Case, async: true
  alias Browser.JS.Runtime

  # `click()`, the event interfaces and the activation behavior of links, checkboxes, radio
  # buttons, labels and summaries

  defp start(html) do
    {raw, _} = html |> Browser.HTML.parse() |> Browser.Forms.index()

    pid =
      Runtime.start(raw, %{
        url: "http://t.test/dir/page",
        width: 800,
        height: 600,
        fetch: fn _ -> {:error, "404"} end
      })

    {pid, Runtime.run_scripts(pid)}
  end

  defp logs(reply), do: for({:log, t} <- reply.console, do: t)

  # The console of the timers that are left. (The runtime can run a timer that comes due before
  # the flush, and then sends its output as a `:js_async` message before the flush's reply.)
  defp settle(pid) do
    flushed = Runtime.flush(pid).console
    %{console: early_console(pid) ++ flushed}
  end

  defp early_console(pid) do
    receive do
      {:js_async, ^pid, reply} -> reply.console ++ early_console(pid)
    after
      0 -> []
    end
  end

  defp errors(reply), do: for({:error, t} <- reply.console, do: t)

  defp run(body, script) do
    {pid, reply} = start("<body>#{body}<script>#{script}</script></body>")
    Runtime.stop(pid)
    assert errors(reply) == []
    reply
  end

  describe "the event interfaces" do
    test "each interface has its own prototype, in the chain of the specification" do
      r =
        run("", ~S"""
        var p = new PointerEvent("click"), m = new MouseEvent("click"), k = new KeyboardEvent("k");
        var f = new FocusEvent("focus"), i = new InputEvent("input"), u = new UIEvent("u");
        console.log(p.constructor.name, m.constructor.name, k.constructor.name,
          f.constructor.name, i.constructor.name, u.constructor.name, new Event("e").constructor.name);
        console.log(p instanceof MouseEvent, p instanceof UIEvent, p instanceof Event,
          m instanceof PointerEvent, k instanceof UIEvent, k instanceof MouseEvent,
          f instanceof UIEvent, i instanceof UIEvent, u instanceof MouseEvent);
        console.log(Object.getPrototypeOf(MouseEvent.prototype) === UIEvent.prototype,
          Object.getPrototypeOf(UIEvent.prototype) === Event.prototype,
          Object.prototype.toString.call(m));
        """)

      assert logs(r) == [
               "PointerEvent MouseEvent KeyboardEvent FocusEvent InputEvent UIEvent Event",
               "true true true false true false true true false",
               "true true [object MouseEvent]"
             ]
    end

    test "a constructor gives the members of its init dictionary, with their defaults" do
      r =
        run("", ~S"""
        var m = new MouseEvent("click", { button: 2, clientX: 5, ctrlKey: 1, bubbles: true });
        console.log(m.button, m.buttons, m.clientX, m.x, m.ctrlKey, m.shiftKey, m.detail,
          m.view, m.relatedTarget, m.bubbles, m.cancelable, m.composed, m.isTrusted,
          m.getModifierState("Control"));
        var k = new KeyboardEvent("keydown", { key: "a" });
        console.log(k.key, k.code === "", k.repeat, k.keyCode);
        var c = document.createEvent("MouseEvents");
        console.log(c instanceof MouseEvent, c.type === "", c.button);
        """)

      assert logs(r) == [
               "2 0 5 5 true false 0 null null true false false false true",
               "a true false 0",
               "true true 0"
             ]
    end
  end

  describe "dispatchEvent" do
    test "an event that the browser fired can be dispatched again: no stop flag stays, it is not trusted" do
      r =
        run("<div id=a></div><div id=b></div>", ~S"""
        var a = document.getElementById("a"), b = document.getElementById("b"), kept, out = [];
        a.addEventListener("click", function (e) { kept = e; e.stopImmediatePropagation(); });
        b.addEventListener("click", function (e) { out.push("b " + e.isTrusted + " " + e.target.id + " " + e.eventPhase); });
        document.body.addEventListener("click", function (e) { out.push("body " + e.target.id); });
        a.click();
        out.push(b.dispatchEvent(kept));
        out.push(kept.target.id + " " + kept.currentTarget + " " + kept.eventPhase);
        console.log(out.join(" | "));
        """)

      assert logs(r) == ["b false b 2 | body b | true | b null 0"]
    end

    test "composedPath() gives the path while the event is in dispatch, else nothing" do
      r =
        run("<div id=o><span id=i></span></div>", ~S"""
        var i = document.getElementById("i"), e = new Event("x", { bubbles: true }), out = [];
        var path = [];
        for (var n = i; n; n = n.parentNode) path.push(n);
        path.push(window);
        document.getElementById("o").addEventListener("x", function (ev) {
          var p = ev.composedPath();
          out.push(p[0].id + " " + p[1].id + " " + (p.length === path.length) +
            " " + p.every(function (t, k) { return t === path[k]; }));
        });
        i.dispatchEvent(e);
        out.push(e.composedPath().length);
        console.log(out.join(" | "));
        """)

      assert logs(r) == ["i o true true | 0"]
    end

    test "a dispatch of an event in dispatch throws; an event stopped before its dispatch reaches no listener" do
      r =
        run("<div id=a></div><div id=b></div>", ~S"""
        var a = document.getElementById("a"), b = document.getElementById("b"), out = [];
        a.addEventListener("click", function (e) {
          try { b.dispatchEvent(e); } catch (err) { out.push(err.name + " " + e.target.id); }
        });
        a.click();
        var n = 0, d = document.createElement("div");
        d.addEventListener("x", function () { n++; });
        var e = new Event("x");
        e.stopPropagation();
        d.dispatchEvent(e);
        d.dispatchEvent(e);
        out.push(n);
        console.log(out.join(" | "));
        """)

      assert logs(r) == ["InvalidStateError a | 1"]
    end
  end

  describe "click()" do
    test "fires a PointerEvent that a script caused: button 0, no position, it bubbles" do
      r =
        run("<button id=b>x</button>", ~S"""
        var b = document.getElementById("b");
        b.addEventListener("click", function (e) {
          console.log(e.constructor.name, e instanceof MouseEvent, e.type, e.button, e.buttons,
            e.detail, e.bubbles, e.cancelable, e.composed, e.isTrusted, e.view === window,
            e.clientX, e.screenY, e.ctrlKey, e.pointerId, e.pointerType === "");
        });
        document.addEventListener("click", function (e) { console.log("doc", e.target.id); });
        b.click();
        """)

      assert logs(r) == [
               "PointerEvent true click 0 0 0 true true true false true 0 0 false -1 true",
               "doc b"
             ]
    end

    test "on an element that is not connected: the click does not go to the window" do
      r =
        run("<div id=h></div>", ~S"""
        var out = [];
        window.addEventListener("click", function () { out.push("window"); });
        window.addEventListener("x", function () { out.push("window x"); });
        var p = document.createElement("p"), d = document.createElement("div");
        p.appendChild(d);
        p.addEventListener("click", function (e) { out.push("p " + e.target.tagName); });
        d.click();
        var c = document.createElement("input");
        c.type = "checkbox";
        c.addEventListener("change", function () { out.push("change"); });
        c.click();
        out.push("checked " + c.checked);
        // (an event that is not composed stays in the shadow tree)
        var root = document.getElementById("h").attachShadow({ mode: "open" });
        root.innerHTML = "<span>s</span>";
        root.firstChild.dispatchEvent(new Event("x", { bubbles: true }));
        root.firstChild.dispatchEvent(new Event("x", { bubbles: true, composed: true }));
        console.log(out.join(" | "));
        """)

      assert logs(r) == ["p DIV | checked true | window x"]
    end

    test "a disabled control does not click, and a click in its own click() does not click" do
      r =
        run("<button id=b disabled>x</button><div id=d></div>", ~S"""
        var n = 0, b = document.getElementById("b"), d = document.getElementById("d");
        b.addEventListener("click", function () { n++; });
        b.click();
        d.addEventListener("click", function () { n++; d.click(); });
        d.click();
        console.log(n);
        """)

      assert logs(r) == ["1"]
    end
  end

  describe "links" do
    test "a click on a link to a fragment changes location.hash and fires hashchange" do
      {pid, r} =
        start(~S"""
        <body><a id=l href="#/us"><span id=s>US</span></a><script>
        var out = [];
        window.addEventListener("hashchange", function (e) { out.push("hashchange " + location.hash); });
        document.getElementById("s").click();
        out.push("after " + location.hash);
        console.log(out.join(", "));
        </script></body>
        """)

      assert errors(r) == []
      assert logs(r) == ["hashchange #/us, after #/us"]
      assert {:hash, "http://t.test/dir/page#/us", :push} in r.outbox
      Runtime.stop(pid)
    end

    test "preventDefault() stops the link; dispatchEvent of a MouseEvent click follows it" do
      {pid, r} =
        start(~S"""
        <body><a id=a href="#a">a</a><a id=b href="#b">b</a><a id=c href="#c">c</a><script>
        var a = document.getElementById("a");
        a.addEventListener("click", function (e) { e.preventDefault(); });
        a.click();
        console.log(location.hash === "", a.dispatchEvent(new MouseEvent("click", { cancelable: true })));
        // (an Event that is not a MouseEvent has no activation behavior)
        document.getElementById("c").dispatchEvent(new Event("click", { bubbles: true }));
        console.log(location.hash === "");
        var ok = document.getElementById("b").dispatchEvent(new MouseEvent("click", { bubbles: true, cancelable: true }));
        console.log(ok, location.hash);
        </script></body>
        """)

      assert errors(r) == []
      assert logs(r) == ["true false", "true", "true #b"]
      Runtime.stop(pid)
    end

    test "a click that does not bubble runs the activation behavior of its target only; the second summary has none" do
      {pid, r} =
        start(~S"""
        <body><a id=a href="#a"><span id=s>s</span></a><a href="#b"><details id=d><summary>1</summary>
        <summary id=t>2</summary></details></a>
        <script>
        document.getElementById("s").dispatchEvent(new MouseEvent("click"));
        console.log(location.hash === "");
        // (the second summary has no activation behavior: the link has it)
        document.getElementById("t").click();
        console.log(document.getElementById("d").open, location.hash);
        </script></body>
        """)

      assert errors(r) == []
      assert logs(r) == ["true", "false #b"]
      Runtime.stop(pid)
    end

    test "a link that its click handler removes is not followed" do
      {pid, r} =
        start(~S"""
        <body><a id=a href="/next">a</a><script>
        var a = document.getElementById("a");
        a.addEventListener("click", function () { a.remove(); });
        a.click();
        </script></body>
        """)

      assert errors(r) == []
      assert r.outbox == []
      Runtime.stop(pid)
    end

    test "a link to another page navigates, a javascript: or _blank link does not" do
      {pid, r} =
        start(~S"""
        <body><a id=n href="../next?x=1">n</a><a id=j href="javascript:void(0)">j</a>
        <a id=t href="/t" target=_blank>t</a><script>
        document.getElementById("j").click();
        document.getElementById("t").click();
        document.getElementById("n").click();
        </script></body>
        """)

      assert errors(r) == []
      assert r.outbox == [{:navigate, "http://t.test/next?x=1", :push}]
      Runtime.stop(pid)
    end

    test "the router pattern: a handler that checks button 0 cancels the click and pushes" do
      {pid, r} =
        start(~S"""
        <body><a id=l href="/world">World</a><script>
        document.addEventListener("click", function (e) {
          var a = e.target.closest("a");
          if (!a || e.defaultPrevented || e.button !== 0 || e.metaKey || e.altKey || e.ctrlKey || e.shiftKey) return;
          e.preventDefault();
          history.pushState({}, "", a.getAttribute("href"));
        });
        document.getElementById("l").click();
        console.log(location.pathname, history.length);
        </script></body>
        """)

      assert errors(r) == []
      assert logs(r) == ["/world 2"]
      assert {:history, :push, "http://t.test/world"} in r.outbox
      refute Enum.any?(r.outbox, &match?({:navigate, _, _}, &1))
      Runtime.stop(pid)
    end
  end

  describe "checkboxes and radio buttons" do
    test "a checkbox changes before the click is dispatched and fires input and change after" do
      r =
        run("<input type=checkbox id=c>", ~S"""
        var c = document.getElementById("c"), out = [];
        ["click", "input", "change"].forEach(function (t) {
          c.addEventListener(t, function (e) { out.push(t + ":" + c.checked + ":" + e.constructor.name); });
        });
        c.click();
        out.push("now " + c.checked);
        console.log(out.join(" "));
        """)

      assert logs(r) == ["click:true:PointerEvent input:true:Event change:true:Event now true"]
    end

    test "a canceled click puts the checkbox back, and input and change do not fire" do
      r =
        run("<input type=checkbox id=c checked>", ~S"""
        var c = document.getElementById("c"), out = [];
        c.addEventListener("click", function (e) { out.push("click:" + c.checked); e.preventDefault(); });
        c.addEventListener("change", function () { out.push("change"); });
        c.click();
        out.push("now " + c.checked);
        console.log(out.join(" "));
        """)

      assert logs(r) == ["click:false now true"]
    end

    test "a radio button unchecks its group; a canceled click checks the old one again" do
      r =
        run(
          "<input type=radio name=g id=a checked><input type=radio name=g id=b><input type=radio name=h id=c checked>",
          ~S"""
          var a = document.getElementById("a"), b = document.getElementById("b"), c = document.getElementById("c");
          var out = [];
          b.addEventListener("change", function () { out.push("change b"); });
          a.addEventListener("change", function () { out.push("change a"); });
          b.click();
          out.push([a.checked, b.checked, c.checked].join());
          a.click();
          out.push([a.checked, b.checked].join());
          a.click();
          b.addEventListener("click", function (e) { out.push("click " + a.checked + b.checked); e.preventDefault(); });
          b.click();
          out.push([a.checked, b.checked].join());
          console.log(out.join(" | "));
          """
        )

      assert logs(r) == [
               "change b | false,true,true | change a | true,false | click falsetrue | true,false"
             ]
    end

    test "a canceled click on a radio button of a group with no checked button unchecks it again" do
      r =
        run("<input type=radio name=g id=a><input type=radio name=g id=b>", ~S"""
        var a = document.getElementById("a"), out = [];
        a.addEventListener("click", function (e) { out.push(a.checked); e.preventDefault(); });
        a.click();
        out.push(a.checked, document.getElementById("b").checked);
        console.log(out.join());
        """)

      assert logs(r) == ["true,false,false"]
    end

    test "the group of a radio button: the same name in the same form; a radio button with no name is alone" do
      r =
        run(
          ~S"<form><input type=radio name=g id=a checked></form><form><input type=radio name=g id=b checked></form><input type=radio name=g id=c checked><input type=radio id=x checked><input type=radio id=y checked><input type=radio name=g id=d>",
          ~S"""
          var $ = function (id) { return document.getElementById(id); };
          var all = function () { return ["a", "b", "c", "d", "x", "y"].map(function (id) { return $(id).checked ? 1 : 0; }).join(""); };
          $("x").click();
          var out = [all()];
          $("d").click();
          out.push(all());
          $("c").checked = true;
          out.push(all());
          console.log(out.join(" "));
          """
        )

      assert logs(r) == ["111011 110111 111011"]
    end

    test "a click in a label on a field of the label does not click the field again" do
      r =
        run("<label id=l>L <input id=t> <span id=s>s</span></label>", ~S"""
        var t = document.getElementById("t"), n = 0;
        t.addEventListener("click", function () { n++; });
        t.dispatchEvent(new MouseEvent("click", { bubbles: true }));
        var a = n;
        document.getElementById("s").dispatchEvent(new MouseEvent("click", { bubbles: true }));
        console.log(a, n);
        """)

      assert logs(r) == ["1 2"]
    end

    test "a label clicks its control; a summary opens and closes its details" do
      r =
        run(
          ~S"<label id=l for=c>L</label><input type=checkbox id=c><label id=m><input type=checkbox id=d> M</label><details id=dt><summary id=s>S</summary>x</details>",
          ~S"""
          var c = document.getElementById("c"), d = document.getElementById("d"), n = 0;
          d.addEventListener("click", function () { n++; });
          document.getElementById("l").click();
          document.getElementById("m").click();
          d.click();
          document.getElementById("s").click();
          var o = document.getElementById("dt").open;
          document.getElementById("s").click();
          console.log(c.checked, d.checked, n, o, document.getElementById("dt").open);
          """
        )

      assert logs(r) == ["true false 2 true false"]
    end
  end

  describe "buttons" do
    test "a click on a submit button (or in it, or on its label) submits; the event has the submitter" do
      {pid, r} =
        start(~S"""
        <body><form id=f action="/go"><label id=l>Send <button id=b><span id=s>go</span></button></label>
        <input type=reset id=r></form><script>
        var f = document.getElementById("f"), n = 0;
        f.addEventListener("submit", function (e) {
          console.log("submit", e.constructor.name, e.submitter && e.submitter.id);
          if (++n < 3) e.preventDefault();
        });
        f.addEventListener("reset", function () { console.log("reset"); });
        document.getElementById("s").click();
        document.getElementById("l").click();
        document.getElementById("r").click();
        f.requestSubmit();
        </script></body>
        """)

      assert errors(r) == []

      assert logs(r) == [
               "submit SubmitEvent b",
               "submit SubmitEvent b",
               "reset",
               "submit SubmitEvent null"
             ]

      assert r.outbox == [{:submit, 0}]

      # (a submission from the window gives the number of its button)
      reply = Runtime.dispatch(pid, {:form, 0}, "submit", %{"submitter" => 0})
      assert logs(reply) == ["submit SubmitEvent b"]
      Runtime.stop(pid)
    end
  end

  describe "details" do
    test "a summary click, details.open and the open attribute queue one toggle event" do
      {pid, r} =
        start(~S"""
        <body><details id=d><summary id=s>S</summary>x</details><details id=e ontoggle="log(event)">
        <summary>T</summary></details><script>
        var d = document.getElementById("d"), e = document.getElementById("e");
        function log(ev) { console.log(ev.type, ev.target.id, ev.oldState, ev.newState, ev.bubbles); }
        d.addEventListener("toggle", log);
        document.getElementById("s").click();
        console.log("open", d.open);
        e.open = true;
        e.open = true;
        </script></body>
        """)

      assert errors(r) == []
      assert logs(r) == ["open true"]
      assert logs(settle(pid)) == ["toggle d closed open false", "toggle e closed open false"]

      # (two changes before the task: one event, with the first old state and the last new one)
      r =
        Runtime.eval(
          pid,
          ~S"d.removeAttribute('open'); d.open = false; d.setAttribute('open', '');"
        )

      assert logs(r) == []
      assert logs(settle(pid)) == ["toggle d open open false"]
      Runtime.eval(pid, ~S"d.open = false; d.open = false;")
      assert logs(settle(pid)) == ["toggle d open closed false"]
      Runtime.stop(pid)
    end
  end

  describe "the clicks of the window" do
    test "a click of the user is a trusted PointerEvent with the button and the position" do
      {pid, _} =
        start(~S"""
        <body><a id=l href="#x">x</a><input type=checkbox id=c><script>
        window.out = [];
        document.addEventListener("click", function (e) {
          out.push([e.constructor.name, e.isTrusted, e.button, e.buttons, e.detail, e.clientX, e.clientY].join());
        });
        document.addEventListener("mousedown", function (e) {
          out.push([e.constructor.name, e.button, e.buttons].join());
        });
        </script></body>
        """)

      state = %{scroll_x: 10, click: {0, 30, 4, 2}}

      for type <- ["mousedown", "click"] do
        init = Browser.Session.pointer_init(state, 30, 4, type)
        reply = Runtime.dispatch(pid, :document, type, init)
        # (the window follows the link or changes the control itself: the scripts do not)
        assert reply.outbox == []
      end

      r = Runtime.eval(pid, "console.log(out.join(' | '))")
      assert logs(r) == ["MouseEvent,0,1 | PointerEvent,true,0,0,2,20,4"]

      # (a script that dispatches an event of the browser again makes it not trusted)
      r =
        Runtime.eval(pid, ~S"""
        var kept;
        document.addEventListener("mouseup", function (e) { kept = e; });
        """)

      assert errors(r) == []
      Runtime.dispatch(pid, :document, "mouseup", %{})

      r =
        Runtime.eval(
          pid,
          "var t = kept.isTrusted; document.body.dispatchEvent(kept); console.log(t, kept.isTrusted)"
        )

      assert logs(r) == ["true false"]

      reply = Runtime.dispatch(pid, {:control, 0}, "click")
      assert reply.outbox == []
      r = Runtime.eval(pid, "console.log(document.getElementById('c').checked, location.hash)")
      assert logs(r) == ["false "]
      Runtime.stop(pid)
    end
  end

  describe "video elements" do
    test "play(), pause() and a click on a video with controls go to the session" do
      {_pid, r} =
        start(~S"""
        <video id="v" controls></video><video id="w"></video><audio id="a" controls></audio>
        <script>
        var v = document.getElementById("v"), w = document.getElementById("w");
        v.play(); v.pause(); w.play(); v.click(); w.click();
        document.getElementById("a").play();
        </script>
        """)

      media = for {:media, nid, op} <- r.outbox, do: {nid, op}
      [{v, :play}, {v, :pause}, {w, :play}, {v, :toggle}] = media
      assert is_integer(v) and is_integer(w) and v != w
      # (a click on a video without controls and any call on an audio element do nothing)
      assert length(media) == 4
    end

    test "state and events come from the player" do
      {pid, r} =
        start(~S"""
        <video id="v" controls></video>
        <script>
        var v = document.getElementById("v");
        ["loadedmetadata", "play", "pause", "timeupdate", "ended"].forEach(function (t) {
          v.addEventListener(t, function () {
            console.log(t + " " + v.paused + " " + v.currentTime + " " + v.duration);
          });
        });
        console.log("start " + v.paused + " " + v.ended + " " + v.duration + " " + v.readyState);
        v.play();
        </script>
        """)

      assert ["start true false NaN 0"] = logs(r)
      [{:media, nid, :play}] = Enum.filter(r.outbox, &match?({:media, _, _}, &1))

      reply =
        Runtime.media(
          pid,
          nid,
          %{
            "duration" => 12.0,
            "videoWidth" => 320.0,
            "videoHeight" => 180.0,
            "readyState" => 4.0
          },
          ["loadedmetadata"]
        )

      assert ["loadedmetadata true 0 12"] = logs(reply)

      reply = Runtime.media(pid, nid, %{"paused" => false, "currentTime" => 0.5}, ["play"])
      assert ["play false 0.5 12"] = logs(reply)

      reply = Runtime.media(pid, nid, %{"currentTime" => 1.25}, ["timeupdate"])
      assert ["timeupdate false 1.25 12"] = logs(reply)

      reply = Runtime.media(pid, nid, %{"paused" => true, "ended" => true}, ["pause", "ended"])
      assert ["pause true 1.25 12", "ended true 1.25 12"] = logs(reply)
    end
  end
end
