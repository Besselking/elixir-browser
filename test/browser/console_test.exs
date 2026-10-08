defmodule Browser.ConsoleTest do
  use ExUnit.Case, async: true
  alias Browser.{Console, JS.Runtime}

  defp start(html) do
    {raw, _} = html |> Browser.HTML.parse() |> Browser.Forms.index()
    pid = Runtime.start(raw, %{url: "http://t.test/", width: 800, height: 600})
    Runtime.run_scripts(pid)
    pid
  end

  defp lines(pid, seq \\ 0),
    do: for({_, level, text, _} <- Console.since(pid, seq), do: {level, text})

  test "entries are numbered, read from a given number on, and cleared" do
    pid = self()
    Console.add(pid, [{:log, "a"}, {:warn, "b"}])
    Console.add(pid, [{:error, "c"}])
    assert lines(pid) == [log: "a", warn: "b", error: "c"]
    assert Console.last_seq(pid) == 3
    assert lines(pid, 2) == [error: "c"]
    Console.clear(pid)
    assert lines(pid) == []
    Console.add(pid, [{:log, "d"}])
    assert [{4, :log, "d", _}] = Console.since(pid, 0)
    Console.drop(pid)
    assert Console.last_seq(pid) == 0
  end

  test "only the newest 1000 entries stay" do
    pid = self()
    Console.add(pid, for(i <- 1..1100, do: {:log, "n#{i}"}))
    entries = Console.since(pid, 0)
    assert length(entries) == 1000
    assert {101, :log, "n101", _} = hd(entries)
    Console.drop(pid)
  end

  test "a page's console output, uncaught errors and rejections reach the log" do
    pid =
      start("""
      <script>
      console.log("hello", 1, {a: 2});
      console.warn("careful");
      console.error("bad");
      Promise.reject(new Error("nope"));
      setTimeout(function () { null.x; }, 0);
      </script>
      """)

    Runtime.flush(pid)
    Process.sleep(50)
    Runtime.flush(pid)
    log = lines(pid)
    assert {:log, "hello 1 { a: 2 }"} in log
    assert {:warn, "careful"} in log
    assert {:error, "bad"} in log

    assert Enum.any?(log, fn {l, t} ->
             l == :error and t =~ "Uncaught (in promise) Error: nope"
           end)

    assert Enum.any?(log, fn {l, t} -> l == :error and t =~ "Uncaught" and t =~ "null" end)
    Runtime.stop(pid)
    assert Console.last_seq(pid) == 0
  end

  test "eval logs the line and its value, and changes the page" do
    pid = start("<p id=a>x</p>")
    reply = Runtime.eval(pid, "document.getElementById('a').textContent = 'changed'; 1 + 2")
    assert reply.dirty

    assert lines(pid) == [
             input: "document.getElementById('a').textContent = 'changed'; 1 + 2",
             result: "3"
           ]

    Runtime.eval(pid, "'str'")
    Runtime.eval(pid, "let q = 5; q * 2")
    Runtime.eval(pid, "q")
    Runtime.eval(pid, "nope()")
    Runtime.eval(pid, "1 +")
    log = lines(pid, 2)
    assert {:result, "'str'"} in log
    assert {:result, "10"} in log
    assert {:result, "5"} in log
    assert Enum.any?(log, fn {l, t} -> l == :error and t =~ "nope" end)
    assert Enum.any?(log, fn {l, t} -> l == :error and t =~ "SyntaxError" end)
    Runtime.stop(pid)
  end
end
