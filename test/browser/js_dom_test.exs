defmodule Browser.JS.DOMTest do
  use ExUnit.Case, async: true
  alias Browser.JS.Runtime

  # runs the page's scripts; `files` maps urls to what fetching them returns
  defp start(html, files \\ %{}) do
    {raw, _} = html |> Browser.HTML.parse() |> Browser.Forms.index()

    fetch = fn url ->
      case Map.fetch(files, url) do
        {:ok, body} -> {:ok, body, url}
        :error -> {:error, "404"}
      end
    end

    pid =
      Runtime.start(raw, %{
        url: "http://t.test/dir/page?a=1#top",
        width: 800,
        height: 600,
        fetch: fetch
      })

    {pid, Runtime.run_scripts(pid)}
  end

  defp logs(reply), do: for({:log, t} <- reply.console, do: t)
  defp errors(reply), do: for({:error, t} <- reply.console, do: t)

  defp run(script, body \\ "<p id=a>x</p>") do
    {_pid, reply} = start("<body>#{body}<script>#{script}</script></body>")
    reply
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
      assert {:navigate, "http://t.test/next"} in r.outbox
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
end
