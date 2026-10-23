defmodule Browser.JS.PopupTest do
  use ExUnit.Case, async: true
  alias Browser.JS.Runtime

  # `window.open` with features (a popup with a handle), `window.opener` and the messages that
  # travel between the two; the session makes the window and passes the messages on

  defp start(html, popup \\ nil) do
    {raw, _} = html |> Browser.HTML.parse() |> Browser.Forms.index()

    pid =
      Runtime.start(raw, %{
        url: "http://t.test/page",
        width: 800,
        height: 600,
        popup: popup,
        fetch: fn _ -> {:error, "404"} end
      })

    {pid, Runtime.run_scripts(pid)}
  end

  defp logs(reply), do: for({:log, t} <- reply.console, do: t)

  # what the runtime sends on its own (a window event's reply) arrives as `:js_async`
  defp async_reply(pid) do
    receive do
      {:js_async, ^pid, reply} -> reply
    after
      1000 -> flunk("no reply from the runtime")
    end
  end

  test "features open a popup and give a handle; without them a tab opens" do
    {_pid, reply} =
      start("""
      <script>
      var w = window.open("/login", "auth", "width=400,height=300");
      console.log(typeof w.postMessage, w.closed, w.name);
      window.open("/plain");
      </script>
      """)

    assert logs(reply) == ["function false auth"]

    assert [{:popup, "open", _id, "http://t.test/login", "width=400,height=300", "auth"}] =
             for(item <- reply.outbox, match?({:popup, _, _, _, _, _}, item), do: item)

    assert {:open_tab, "http://t.test/plain"} in reply.outbox
  end

  test "a named popup that is open is used again" do
    {_pid, reply} =
      start("""
      <script>
      var a = window.open("/one", "auth", "width=400");
      var b = window.open("/two", "auth", "width=400");
      console.log(a === b);
      </script>
      """)

    assert logs(reply) == ["true"]

    assert [{:popup, "open", id, _, _, _}, {:popup, "navigate", id, "http://t.test/two", _, _}] =
             for(item <- reply.outbox, match?({:popup, _, _, _, _, _}, item), do: item)
  end

  test "postMessage of the handle queues the message as JSON with the origin" do
    {_pid, reply} =
      start("""
      <script>
      var w = window.open("/p", "", "width=1");
      w.postMessage({a: [1, 2]}, "http://t.test");
      </script>
      """)

    assert [{:popup, "post", _id, payload, _, _}] =
             for(item <- reply.outbox, match?({:popup, "post", _, _, _, _}, item), do: item)

    assert %{"d" => %{"a" => [1, 2]}, "o" => "http://t.test", "t" => "http://t.test"} =
             JSON.decode!(payload)
  end

  test "a popup has an opener; a message from it arrives as a message event" do
    {pid, reply} =
      start(
        """
        <script>
        console.log(typeof window.opener.postMessage);
        window.addEventListener("message", function (e) {
          console.log("got", e.data.n, e.origin, e.source === window.opener);
        });
        </script>
        """,
        "pid1"
      )

    assert logs(reply) == ["function"]
    payload = ~s({"d":{"n":7},"o":"http://other.test","t":"*"})

    Runtime.window_event_async(pid, "__popup_message", %{"from" => "opener", "payload" => payload})

    assert logs(async_reply(pid)) == ["got 7 http://other.test true"]
  end

  test "a message for another origin is dropped, a closed popup is marked" do
    {pid, _} =
      start("""
      <script>
      var w = window.open("/p", "", "width=1");
      var seen = 0;
      window.addEventListener("message", function (e) { seen++; });
      </script>
      """)

    drop = ~s({"d":1,"o":"http://t.test","t":"http://elsewhere.test"})
    Runtime.window_event_async(pid, "__popup_message", %{"from" => "x", "payload" => drop})
    Runtime.window_event_async(pid, "__popup_closed", %{"id" => "nothing"})
    assert [input: _, result: "'0 false'"] = Runtime.eval(pid, "seen + ' ' + w.closed").console

    [input: _, result: quoted] = Runtime.eval(pid, "w._id").console
    id = String.trim(quoted, "'")
    Runtime.window_event_async(pid, "__popup_closed", %{"id" => id})
    assert [input: _, result: "'0 true'"] = Runtime.eval(pid, "seen + ' ' + w.closed").console
  end
end
