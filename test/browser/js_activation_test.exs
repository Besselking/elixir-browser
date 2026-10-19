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

      reply = Runtime.dispatch(pid, {:control, 0}, "click")
      assert reply.outbox == []
      r = Runtime.eval(pid, "console.log(document.getElementById('c').checked, location.hash)")
      assert logs(r) == ["false "]
      Runtime.stop(pid)
    end
  end
end
