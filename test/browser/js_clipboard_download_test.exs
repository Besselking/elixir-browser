defmodule Browser.JS.ClipboardDownloadTest do
  use ExUnit.Case, async: true
  alias Browser.JS.Runtime

  # (as on the results page of Speedometer 3.1: a link to a blob with `download`, and a
  # button that copies the text)
  @page ~S"""
  <body><a id=dl download="speedometer-3.json">Download</a>
  <a id=plain href="/x">x</a>
  <button id=copy onclick="navigator.clipboard.writeText('{&quot;a&quot;:1}')">Copy</button>
  <script>
  const text = JSON.stringify({ score: 42 });
  document.getElementById("dl").href = URL.createObjectURL(new Blob([text], { type: "application/json" }));
  </script></body>
  """

  defp start(html, info \\ %{}) do
    {raw, _} = html |> Browser.HTML.parse() |> Browser.Forms.index()

    info =
      Map.merge(
        %{url: "http://t.test/", width: 800, height: 600, fetch: fn _ -> {:error, "404"} end},
        info
      )

    pid = Runtime.start(raw, info)
    {pid, Runtime.run_scripts(pid)}
  end

  defp logs(reply), do: for({:log, t} <- reply.console, do: t)

  # the layout number of the element with this id in the exported tree
  defp nid(pid, id), do: find(Runtime.snapshot(pid).raw, id) || flunk("no element #{id}")

  defp find(nodes, id) when is_list(nodes), do: Enum.find_value(nodes, &find(&1, id))
  defp find({:text, _}, _), do: nil

  defp find({:element, _, attrs, kids}, id) do
    if List.keyfind(attrs, "id", 0) == {"id", id},
      do: elem(List.keyfind(attrs, "@nid", 0), 1),
      else: find(kids, id)
  end

  describe "navigator.clipboard" do
    test "writeText asks the session to put the text on the clipboard" do
      {pid, _} = start(@page)
      reply = Runtime.dispatch(pid, {:control, 0}, "click")
      assert {:clipboard, ~S|{"a":1}|} in reply.outbox
      Runtime.stop(pid)
    end

    test "without a window, readText gives what the page wrote" do
      {_pid, reply} =
        start(
          ~S|<body><script>navigator.clipboard.writeText("abc").then(() => navigator.clipboard.readText()).then(t => console.log("read " + t))</script></body>|
        )

      assert logs(reply) == ["read abc"]
      assert {:clipboard, "abc"} in reply.outbox
    end

    test "with a window, readText reads the system clipboard" do
      me = self()

      clipboard = fn ->
        send(me, :clipboard_read)
        "from the system"
      end

      {_pid, reply} =
        start(
          ~S|<body><script>navigator.clipboard.readText().then(t => console.log("read " + t))</script></body>|,
          %{clipboard: clipboard}
        )

      assert logs(reply) == ["read from the system"]
      assert_received :clipboard_read
    end
  end

  describe "links with download" do
    test "a click on the link gives the blob to the session to save, and is not followed" do
      {pid, _} = start(@page)
      href = Runtime.eval(pid, ~S|console.log(document.getElementById("dl").href)|)
      assert ["blob:http://t.test/" <> _ = url] = logs(href) |> Enum.take(-1)

      reply = Runtime.follow_link(pid, nid(pid, "dl"), url)
      assert reply.frame
      assert [{:download, ^url, "speedometer-3.json", ~S|{"score":42}|}] = reply.outbox
      Runtime.stop(pid)
    end

    test "a link without download is left to the session" do
      {pid, _} = start(@page)
      reply = Runtime.follow_link(pid, nid(pid, "plain"), "/x")
      refute reply.frame
      assert reply.outbox == []
      Runtime.stop(pid)
    end

    test "a.click() from a script downloads too; a cancelled click does not" do
      html = ~S"""
      <body><a id=d download href="data:text/plain,hi">d</a><script>
      const a = document.getElementById("d");
      a.click();
      a.addEventListener("click", e => e.preventDefault());
      a.click();
      </script></body>
      """

      {_pid, reply} = start(html)
      assert reply.outbox == [{:download, "data:text/plain,hi", "", nil}]
    end
  end
end
