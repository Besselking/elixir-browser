defmodule Browser.PageFramesTest do
  use ExUnit.Case, async: true
  alias Browser.Page

  @html """
  <html><head><style>p { color: red }</style></head><body>
  <p id=outer>outer</p><iframe id=f style="width:300px;height:100px"></iframe>
  <script>
  var d = document.getElementById("f").contentDocument;
  d.open();
  d.write("<html><head><style>p { font-size: 30px }</style></head><body><p>inner</p></body></html>");
  d.close();
  var s = document.createElement("style");
  s.textContent = "#outer { margin-left: 40px }";
  document.head.appendChild(s);
  </script></body></html>
  """

  defp paragraphs(nodes) when is_list(nodes), do: Enum.flat_map(nodes, &paragraphs/1)

  defp paragraphs({:element, "p", attrs, _}), do: [Map.new(attrs)["@computed"]]
  defp paragraphs({:element, _, _, kids}), do: paragraphs(kids)
  defp paragraphs(_), do: []

  setup_all do
    env = Browser.Style.default_env()
    page = "file:///t.html" |> then(&Page.build(@html, &1, env)) |> Page.run_js(env)
    {:ok, page: page}
  end

  test "the document of a frame is shown inside its iframe", %{page: page} do
    assert [outer, inner] = paragraphs(page.pruned)
    assert outer["font-size"] != 30.0
    assert inner["font-size"] == 30.0
  end

  test "the sheets of a frame apply inside it only, the page's do not reach in", %{page: page} do
    assert [outer, inner] = paragraphs(page.pruned)
    assert outer["color"] != nil
    assert inner["color"] != outer["color"]
  end

  test "a sheet a script adds to the page applies", %{page: page} do
    assert [outer, _] = paragraphs(page.pruned)
    assert outer["margin-left"] == 40.0
  end

  defp iframes(nodes) when is_list(nodes), do: Enum.flat_map(nodes, &iframes/1)

  defp iframes({:element, "iframe", attrs, _}), do: [Map.new(attrs)["@computed"]]
  defp iframes({:element, _, _, kids}), do: iframes(kids)
  defp iframes(_), do: []

  test "a frame scrolls its document, unless it says scrolling=no" do
    env = Browser.Style.default_env()

    html = """
    <body><iframe id=a srcdoc="<p>x</p>"></iframe><iframe id=b scrolling=no srcdoc="<p>y</p>"></iframe>
    <script>document.title = "t"</script></body>
    """

    page = "file:///t.html" |> then(&Page.build(html, &1, env)) |> Page.run_js(env)
    assert [a, b] = iframes(page.pruned)
    assert a["overflow-y"] == "auto"
    assert b["overflow-y"] == "hidden"
  end
end
