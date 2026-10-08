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
end
