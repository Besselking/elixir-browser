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
end
