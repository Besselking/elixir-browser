defmodule Browser.PageRunJsTest do
  use ExUnit.Case, async: true
  alias Browser.Page

  test "scripts run by run_js/3 read the size of the page, as in the session" do
    html = """
    <html><body><p id=p>x</p><pre id=o></pre>
    <script>
    document.getElementById("o").textContent = "w=" + (document.body.offsetWidth > 0);
    </script></body></html>
    """

    env = Browser.Style.default_env()
    page = "file:///t.html" |> then(&Page.build(html, &1, env)) |> Page.run_js(env)
    assert inspect(page.nodes) =~ "w=true"
  end

  # AO3 fades in its terms prompt (`class="hidden"`) with jQuery, which shows only what
  # getComputedStyle says is `display: none`
  test "getComputedStyle reads the page's style sheets" do
    html = """
    <html><head><style>
    .hidden { display: none } .abs { position: absolute; visibility: hidden }
    </style></head><body>
    <div id=h class=hidden><span id=in>x</span></div><div id=a class=abs>y</div><p id=p>z</p>
    <pre id=o></pre>
    <script>
    const cs = (id) => getComputedStyle(document.getElementById(id));
    const made = document.createElement("div");
    made.className = "hidden";
    document.body.appendChild(made);
    document.getElementById("o").textContent = [
      cs("h").display, cs("a").position, cs("a").visibility, cs("p").display,
      getComputedStyle(made).display, cs("in").display
    ].join(",");
    </script></body></html>
    """

    env = Browser.Style.default_env()
    page = "file:///t.html" |> then(&Page.build(html, &1, env)) |> Page.run_js(env)
    assert inspect(page.nodes) =~ "none,absolute,hidden,block,none,inline"
  end
end
