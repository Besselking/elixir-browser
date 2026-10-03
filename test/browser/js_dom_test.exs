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
      assert {:element, "p", [{"id", "a"}], [{:text, "changed"}]} in kids
      assert {:element, "hr", [], []} in kids
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
      assert {:element, "hr", [], []} = second.raw |> hd() |> elem(3) |> List.last()
    end

    test "an interval keeps going until it is cleared" do
      {pid, _} =
        start(~S"""
        <body><p id=p>0</p><script>
        var n = 0, id = setInterval(() => { n++; document.getElementById("p").textContent = String(n); if (n == 3) clearInterval(id); }, 10);
        </script></body>
        """)

      for expected <- ["1", "2", "3"] do
        assert_receive {:js_async, ^pid, r}, 1000
        assert {:element, "p", _, [{:text, ^expected}]} = hd(r.raw |> hd() |> elem(3))
      end

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
end
