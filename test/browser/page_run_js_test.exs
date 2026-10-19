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
end
