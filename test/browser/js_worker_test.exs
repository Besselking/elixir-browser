defmodule Browser.JS.WorkerTest do
  use ExUnit.Case, async: true
  alias Browser.JS.Runtime

  @files %{
    "http://t.test/echo.js" => ~S"""
    onmessage = (e) => postMessage({ echo: e.data, inWorker: typeof document + "/" + typeof window });
    """,
    "http://t.test/lib.js" => "self.libLoaded = 'yes'; function twice(x) { return x * 2; }",
    "http://t.test/main.js" => ~S"""
    importScripts('lib.js');
    self.addEventListener('message', (e) => {
      postMessage([libLoaded, twice(e.data), self.name, location.href]);
      if (e.data === 21) close();
    });
    """,
    "http://t.test/boom.js" => "throw new Error('boom');",
    "http://t.test/timer.js" =>
      "setTimeout(() => postMessage('tick'), 10); console.log('hello from worker');",
    "http://t.test/mod.mjs" => "import { n } from './dep.mjs'; postMessage(n + 1);",
    "http://t.test/dep.mjs" => "export const n = 41;"
  }

  defp run(script) do
    {raw, _} =
      "<body><script>#{script}</script></body>"
      |> Browser.HTML.parse()
      |> Browser.Forms.index()

    info = %{
      url: "http://t.test/",
      width: 800,
      height: 600,
      fetch: fn url ->
        case @files do
          %{^url => body} -> {:ok, body, url}
          _ -> {:error, "404"}
        end
      end
    }

    pid = Runtime.start(raw, info)
    r = Runtime.run_scripts(pid)
    lines = for({_, t} <- r.console, do: t) ++ collect(pid, [])
    Runtime.stop(pid)
    lines
  end

  # what the worker caused, until things go quiet
  defp collect(pid, acc) do
    receive do
      {:js_async, ^pid, reply} -> collect(pid, acc ++ for({_, t} <- reply.console, do: t))
    after
      400 -> acc
    end
  end

  test "a worker echoes messages and has no document" do
    lines =
      run(~S"""
      const w = new Worker('echo.js');
      w.onmessage = (e) => console.log(JSON.stringify(e.data));
      w.postMessage({ a: [1, 'x', null], d: new Date(0) });
      """)

    assert lines == [
             ~S|{"echo":{"a":[1,"x",null],"d":"1970-01-01T00:00:00.000Z"},"inWorker":"undefined/undefined"}|
           ]
  end

  test "importScripts, addEventListener, name, location and close" do
    lines =
      run(~S"""
      const w = new Worker('main.js', { name: 'calc' });
      w.addEventListener('message', (e) => console.log(JSON.stringify(e.data)));
      w.postMessage(5);
      w.postMessage(21);
      w.postMessage(7);
      """)

    assert lines == [
             ~S|["yes",10,"calc","http://t.test/main.js"]|,
             ~S|["yes",42,"calc","http://t.test/main.js"]|
           ]
  end

  test "an uncaught error in the worker is an error event" do
    lines =
      run(~S"""
      const w = new Worker('boom.js');
      w.onerror = (e) => { e.preventDefault(); console.log('error:', e.message); };
      """)

    assert lines == ["error: Uncaught Error: boom"]
  end

  test "worker timers and console reach the page" do
    lines =
      run(~S"""
      const w = new Worker('timer.js');
      w.onmessage = (e) => console.log('got', e.data);
      """)

    assert "hello from worker" in lines
    assert "got tick" in lines
  end

  test "module workers and blob workers" do
    lines =
      run(~S"""
      const m = new Worker('mod.mjs', { type: 'module' });
      m.onmessage = (e) => console.log('module', e.data);
      const url = URL.createObjectURL(new Blob(['postMessage("from blob")'], { type: 'text/javascript' }));
      const b = new Worker(url);
      b.onmessage = (e) => console.log(e.data);
      """)

    assert "module 42" in lines
    assert "from blob" in lines
  end

  test "terminate stops delivery" do
    lines =
      run(~S"""
      const w = new Worker('echo.js');
      w.onmessage = () => console.log('should not happen');
      w.postMessage(1);
      w.terminate();
      w.postMessage(2);
      """)

    assert lines == []
  end
end
