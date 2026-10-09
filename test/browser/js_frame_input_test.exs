defmodule Browser.JS.FrameInputTest do
  use ExUnit.Case, async: true
  alias Browser.JS.Runtime

  @inner """
  <body><button id=b>go</button><input id=i><a id=l href="/two.html">next</a>
  <a id=top href="/top.html" target="_top">top</a>
  <script>
  document.getElementById("b").addEventListener("click", e => console.log("click", e.target.id, location.pathname));
  document.getElementById("b").addEventListener("mouseover", () => console.log("over b"));
  document.getElementById("i").addEventListener("keydown", e => console.log("key", e.key, e.target.id));
  </script></body>
  """

  defp fetch("http://t.test/one.html"), do: {:ok, @inner, "http://t.test/one.html"}

  defp fetch("http://t.test/two.html"),
    do:
      {:ok,
       "<body><p id=p>two</p><script>console.log('two loaded', location.pathname)</script></body>",
       "http://t.test/two.html"}

  defp fetch(_), do: {:error, "404"}

  defp start do
    {raw, _} =
      ~S|<body><iframe id=f src="/one.html"></iframe><script>console.log("page")</script></body>|
      |> Browser.HTML.parse()
      |> Browser.Forms.index()

    pid = Runtime.start(raw, %{url: "http://t.test/", width: 800, height: 600, fetch: &fetch/1})
    r = Runtime.run_scripts(pid)
    {pid, r}
  end

  defp logs(reply), do: for({:log, t} <- reply.console, do: t)

  # the layout number of the element with this id in the exported tree
  defp nid(pid, id) do
    raw = Runtime.snapshot(pid).raw
    find(raw, id) || flunk("no element #{id}")
  end

  defp find(nodes, id) when is_list(nodes), do: Enum.find_value(nodes, &find(&1, id))
  defp find({:text, _}, _), do: nil

  defp find({:element, _, attrs, kids}, id) do
    if List.keyfind(attrs, "id", 0) == {"id", id},
      do: elem(List.keyfind(attrs, "@nid", 0), 1),
      else: find(kids, id)
  end

  test "a click on an element of a frame reaches the frame's scripts, in the frame's window" do
    {pid, _} = start()
    b = nid(pid, "b")
    reply = Runtime.dispatch(pid, {:numbered, b}, "click")
    assert "click b /one.html" in logs(reply)
    Runtime.stop(pid)
  end

  test "a key typed into a control of a frame is heard by the frame" do
    {pid, _} = start()
    {raw, _} = pid |> Runtime.snapshot() |> Map.fetch!(:raw) |> Browser.Forms.index()
    cid = cid_of(raw, "i")
    reply = Runtime.dispatch(pid, {:control, cid}, "keydown", %{"key" => "a"})
    assert "key a i" in logs(reply)
    Runtime.stop(pid)
  end

  defp cid_of(nodes, id) when is_list(nodes), do: Enum.find_value(nodes, &cid_of(&1, id))
  defp cid_of({:text, _}, _), do: nil

  defp cid_of({:element, _, attrs, kids}, id) do
    if List.keyfind(attrs, "id", 0) == {"id", id},
      do: elem(List.keyfind(attrs, "@cid", 0), 1),
      else: cid_of(kids, id)
  end

  test "the pointer going over an element of a frame is heard there" do
    {pid, _} = start()
    reply = Runtime.hover(pid, nil, nid(pid, "b"))
    assert "over b" in logs(reply)
    Runtime.stop(pid)
  end

  test "a link in a frame is followed by the frame" do
    {pid, _} = start()
    l = nid(pid, "l")
    reply = Runtime.follow_link(pid, l, "/two.html")
    assert reply.frame
    assert reply.outbox == []
    # the frame loads the new document (in a timer)
    Process.sleep(100)
    all = logs(Runtime.flush(pid)) ++ for {:js_async, ^pid, r} <- drain(), t <- logs(r), do: t
    assert "two loaded /two.html" in all
    Runtime.stop(pid)
  end

  test "a link in a frame with target=_top takes the page" do
    {pid, _} = start()
    reply = Runtime.follow_link(pid, nid(pid, "top"), "/top.html")
    assert reply.frame
    assert [{:navigate, "http://t.test/top.html", :push}] = reply.outbox
    Runtime.stop(pid)
  end

  test "a link of the page itself is left to the session" do
    {raw, _} =
      ~S|<body><a id=a href="/x">x</a></body>| |> Browser.HTML.parse() |> Browser.Forms.index()

    pid = Runtime.start(raw, %{url: "http://t.test/", width: 800, height: 600, fetch: &fetch/1})
    Runtime.run_scripts(pid)
    refute Runtime.follow_link(pid, nid(pid, "a"), "/x").frame
    Runtime.stop(pid)
  end

  defp drain do
    receive do
      {:js_async, _, _} = m -> [m | drain()]
    after
      50 -> []
    end
  end
end
