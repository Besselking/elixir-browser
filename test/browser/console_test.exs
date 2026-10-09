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

  test "uncaught errors say the file and line they came from" do
    pid =
      start("""
      <script>
      var a = 1;

      function inner() {
        var b = 2;
        null.x;
      }
      function outer() {
        inner();
      }
      outer();
      </script>
      <script>
      throw "plain";
      </script>
      <script>
      function f() {
        if (true) {
          foo.bar();
        }
        return 1;
      }
      setTimeout(f, 0);
      </script>
      """)

    Runtime.flush(pid)
    Process.sleep(50)
    Runtime.flush(pid)
    log = lines(pid)

    assert Enum.any?(log, fn {l, t} ->
             l == :error and t =~ "Uncaught TypeError" and
               t =~ "at inner (inline script 1:6)" and t =~ "at outer (inline script 1:9)" and
               t =~ "at inline script 1:11"
           end)

    assert Enum.any?(log, fn {l, t} ->
             l == :error and t =~ "Uncaught plain (inline script 2:2)"
           end)

    assert Enum.any?(log, fn {l, t} -> l == :error and t =~ "at f (inline script 3:4)" end)
    Runtime.stop(pid)
  end

  test "console methods: formats, groups, counts, timers, table" do
    pid =
      start("""
      <script>
      console.log("%s is %d years and %i, %f; %o %% %c.", "Bo", 42.9, 7.8, 1.5, {a: 1}, "css", "tail");
      console.log("no spec", 1);
      console.log("%s");
      console.group("Outer");
      console.log("one");
      console.group();
      console.warn("two\\nlines");
      console.groupEnd();
      console.groupEnd();
      console.groupEnd();
      console.log("flat");
      console.count(); console.count(); console.count("x"); console.countReset(); console.count();
      console.timeEnd("missing");
      console.time("t"); console.time("t");
      console.timeLog("t", "more");
      console.timeEnd("t");
      console.table([{a: 1, b: "x"}, {a: 2, c: true}]);
      console.table({r1: 5, r2: [1, 2]});
      console.table([{a: 1, b: 2}], ["b"]);
      console.table(3);
      console.assert(true, "fine");
      console.assert(false, "broken", 1);
      console.dir("str");
      console.clear();
      console.log("after");
      </script>
      """)

    log = lines(pid)

    assert {:log, "Bo is 42 years and 7, 1.5; { a: 1 } % . tail"} in log
    assert {:log, "no spec 1"} in log
    assert {:log, "%s"} in log
    assert {:log, "Outer"} in log
    assert {:log, "  one"} in log
    assert {:warn, "    two\n    lines"} in log
    assert {:log, "flat"} in log

    assert Enum.filter(log, fn {_, t} -> t =~ ~r/^(default|x): / end) ==
             [log: "default: 1", log: "default: 2", log: "x: 1", log: "default: 1"]

    assert {:warn, "Timer 'missing' does not exist"} in log
    assert {:warn, "Timer 't' already exists"} in log
    assert Enum.any?(log, fn {l, t} -> l == :log and t =~ ~r/^t: [\d.]+ ms more$/ end)
    assert Enum.any?(log, fn {l, t} -> l == :log and t =~ ~r/^t: [\d.]+ ms$/ end)

    assert {:log,
            Enum.join(
              [
                "┌─────────┬───┬─────┬──────┐",
                "│ (index) │ a │  b  │  c   │",
                "├─────────┼───┼─────┼──────┤",
                "│    0    │ 1 │ 'x' │      │",
                "│    1    │ 2 │     │ true │",
                "└─────────┴───┴─────┴──────┘"
              ],
              "\n"
            )} in log

    assert Enum.any?(log, fn {_, t} -> t =~ "│   r1    │   │   │   5    │" end)
    assert Enum.any?(log, fn {_, t} -> t =~ "│ (index) │ 0 │ 1 │ Values │" end)
    assert Enum.any?(log, fn {_, t} -> t =~ "│ (index) │ b │" and not (t =~ "│ a") end)
    assert {:log, "3"} in log
    refute Enum.any?(log, fn {_, t} -> t =~ "fine" end)
    assert Enum.any?(log, fn {l, t} -> l == :error and t =~ ~r/^Assertion failed: broken 1/ end)
    assert {:log, "'str'"} in log
    assert List.last(lines(pid)) == {:log, "after"}
    assert Enum.any?(Console.since(pid, 0), &(elem(&1, 1) == :clear))
    Runtime.stop(pid)
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
