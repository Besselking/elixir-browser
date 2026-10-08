defmodule Browser.PageShadowTest do
  use ExUnit.Case, async: true
  alias Browser.Page

  @html """
  <html><head><style>p { color: red } x-card { margin-left: 7px } .light { font-size: 22px }</style></head><body>
  <x-card id=c><span slot=title class=light>Title</span><i>Body</i></x-card>
  <script>
  const host = document.getElementById("c");
  const root = host.attachShadow({ mode: "open" });
  root.innerHTML = "<style>:host { display: block; padding-left: 5px } :host(.wide) { width: 90px } p { font-size: 30px } ::slotted(b) {}</style>" +
    "<p>shadow</p><slot name=title></slot><div><slot>fallback</slot></div>";
  </script></body></html>
  """

  defp find(nodes, fun) when is_list(nodes), do: Enum.flat_map(nodes, &find(&1, fun))

  defp find({:element, tag, attrs, kids} = el, fun),
    do: if(fun.(tag, Map.new(attrs)), do: [el], else: []) ++ find(kids, fun)

  defp find(_, _), do: []

  defp texts({:text, t}), do: t
  defp texts({:element, _, _, kids}), do: Enum.map_join(kids, &texts/1)

  setup_all do
    env = Browser.Style.default_env()
    page = "file:///t.html" |> then(&Page.build(@html, &1, env)) |> Page.run_js(env)
    {:ok, page: page}
  end

  test "the shadow tree and the nodes a slot shows are in the page", %{page: page} do
    [card] = find(page.nodes, fn t, _ -> t == "x-card" end)
    text = texts(card)
    assert text =~ "shadow"
    assert text =~ "Title"
    assert text =~ "Body"
    refute text =~ "fallback"
  end

  test "sheets in a shadow tree apply inside it, and :host to the host", %{page: page} do
    [card] = find(page.nodes, fn t, _ -> t == "x-card" end)
    {:element, _, attrs, _} = card
    c = Map.new(attrs)["@computed"]
    assert c["display"] == "block"
    assert c["padding-left"] == 5.0
    assert c["margin-left"] == 7.0
    [p] = find(page.nodes, fn t, _ -> t == "p" end)
    {:element, _, pattrs, _} = p
    assert Map.new(pattrs)["@computed"]["font-size"] == 30.0
    assert Map.new(pattrs)["@computed"]["color"] != {255, 0, 0, 255}
  end

  test "a node in a slot is styled by the page's sheets", %{page: page} do
    [span] = find(page.nodes, fn t, a -> t == "span" and a["class"] == "light" end)
    {:element, _, attrs, _} = span
    assert Map.new(attrs)["@computed"]["font-size"] == 22.0
  end
end
