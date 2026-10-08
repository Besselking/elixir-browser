defmodule Browser.JS.WebAssemblyTest do
  use ExUnit.Case, async: true
  alias Browser.JS.Runtime

  # base64 of modules made with wabt from the WAT in test/browser/wasm_test.exs
  @prelude ~S"""
  const b64 = (s) => Uint8Array.from(atob(s), (c) => c.charCodeAt(0));
  const FIB = b64("AGFzbQEAAAABBgFgAX8BfwMCAQAHBwEDZmliAAAKHgEcACAAQQJJBH8gAAUgAEEBaxAAIABBAmsQAGoLCw==");
  const MEM = b64("AGFzbQEAAAABDwNgAX8Bf2ACf38AYAABfwMGBQABAAACBQQBAQECBzAGA21lbQIABWxvYWQ4AAAHc3RvcmUzMgABBmxvYWQzMgACBGdyb3cAAwRzaXplAAQKJwUHACAALQAACwkAIAAgATYCAAsHACAAKAIACwYAIABAAAsEAD8ACwsLAQBBCAsFaGVsbG8=");
  const TBL = b64("AGFzbQEAAAABDAJgAX8Bf2ACf38BfwMEAwAAAQQEAXAAAwcOAgN0YmwBAARjYWxsAAIJCAEAQQALAgABChsDBwAgAEECbAsHACAAQQNsCwkAIAEgABEAAAs=");
  const IMP = b64("AGFzbQEAAAABDAJgAn9/AX9gAX8BfwIUAgNlbnYDYWRkAAADZW52AWcDfwEDAgEBBgYBfwFBAAsHDQIDY250AwEDcnVuAAEKFQETACAAIwAQACQAIwFBAWokASMACw==");
  const EXC = b64("AGFzbQEAAAABFgVgAABgAX8AYAF/AX9gAAF/YAACf2kCDwEDZW52B2pzdGhyb3cAAAMHBgECAwEDAQ0FAgABAAAHNwYBZQQAB2NhdGNoSXQAAghjYXRjaEFsbAADCHVuY2F1Z2h0AAQFdmlhSnMABQdyZXRocm93AAYKagYGACAACAALIAEBf0HkACEBAn8ffwEAAABBByEBIAAQAUF/CwsgAWoLEgACQB9AAQIACAELQQAPC0EBCwYAIAAQAQsSAAJAH0ABAgAQAEEADwsLQQELEwACBB8EAQEAACAAEAEACwsKGgs=");
  const CTL = b64("AGFzbQEAAAABIgZgAX8Bf2ACf38Bf2AAAGACf38Cf39gAn19AX1gAn5+AX4DCAcAAAECAwQFBy0HAnN3AAADc3VtAAEDZGl2AAIEdHJhcAADBHN3YXAABAFmAAUGaTY0bXVsAAYKYQcaAAJAAkACQCAADgIAAQILQQoPC0EUDwtBHgshAQF/AkADQCAARQ0BIAEgAGohASAAQQFrIQAMAAsLIAELBwAgACABbQsDAAALBgAgASAACwcAIAAgAZILBwAgACABfgs=");
  """

  defp run(script) do
    {raw, _} =
      "<body><script>#{@prelude}\n#{script}</script></body>"
      |> Browser.HTML.parse()
      |> Browser.Forms.index()

    info = %{url: "http://t.test/", width: 800, height: 600, fetch: fn _ -> {:error, "404"} end}
    pid = Runtime.start(raw, info)
    r = Runtime.run_scripts(pid)
    lines = for({:log, t} <- r.console, do: t) ++ collect(pid)
    Runtime.stop(pid)
    {lines, for({:error, t} <- r.console, do: t)}
  end

  defp collect(pid) do
    receive do
      {:js_async, ^pid, reply} -> for({:log, t} <- reply.console, do: t) ++ collect(pid)
    after
      300 -> for {:log, t} <- Runtime.flush(pid).console, do: t
    end
  end

  test "Module, Instance and exports" do
    {logs, errors} =
      run(~S"""
      console.log(typeof WebAssembly, Object.prototype.toString.call(WebAssembly));
      console.log(WebAssembly.validate(FIB), WebAssembly.validate(new Uint8Array([1, 2, 3])));
      const m = new WebAssembly.Module(FIB);
      console.log(JSON.stringify(WebAssembly.Module.exports(m)), JSON.stringify(WebAssembly.Module.imports(m)));
      const i = new WebAssembly.Instance(m);
      console.log(i.exports.fib(20), i.exports.fib.name, i.exports.fib.length);
      console.log(Object.isFrozen(i.exports), Object.getPrototypeOf(i.exports));
      console.log(i instanceof WebAssembly.Instance, String(i));
      """)

    assert errors == []
    assert Enum.at(logs, 0) =~ "object [object WebAssembly]"
    assert Enum.at(logs, 1) == "true false"
    assert Enum.at(logs, 2) == ~s([{"name":"fib","kind":"function"}] [])
    assert Enum.at(logs, 3) == "6765 0 1"
    assert Enum.at(logs, 4) == "true null"
    assert Enum.at(logs, 5) == "true [object WebAssembly.Instance]"
  end

  test "errors are WebAssembly errors" do
    {logs, errors} =
      run(~S"""
      try { new WebAssembly.Module(new Uint8Array([1, 2, 3, 4])); } catch (e) {
        console.log(e instanceof WebAssembly.CompileError, e instanceof Error, e.name);
      }
      try { new WebAssembly.Module("nope"); } catch (e) { console.log(e.constructor.name); }
      const c = new WebAssembly.Instance(new WebAssembly.Module(CTL)).exports;
      try { c.div(1, 0); } catch (e) { console.log(e instanceof WebAssembly.RuntimeError, e.message); }
      try { c.trap(); } catch (e) { console.log(e.name, e.message); }
      try { new WebAssembly.Instance(new WebAssembly.Module(IMP), {}); } catch (e) { console.log(e.constructor.name); }
      try { new WebAssembly.Instance(new WebAssembly.Module(IMP)); } catch (e) { console.log(e.constructor.name); }
      try {
        new WebAssembly.Instance(new WebAssembly.Module(IMP), { env: { add: 1, g: new WebAssembly.Global({ value: "i32", mutable: true }, 0) } });
      } catch (e) { console.log(e.constructor.name, e.message); }
      """)

    assert errors == []

    assert logs == [
             "true true CompileError",
             "TypeError",
             "true integer divide by zero",
             "RuntimeError unreachable",
             "TypeError",
             "TypeError",
             "LinkError function import requires a callable"
           ]
  end

  test "values: i32 wraps, i64 is BigInt, floats round to f32, multi-value returns an array" do
    {logs, errors} =
      run(~S"""
      const c = new WebAssembly.Instance(new WebAssembly.Module(CTL)).exports;
      console.log(c.div(-7, 2), c.sw(1), c.sum("100"), c.f(1.1, 2.2), c.f(NaN, 1));
      console.log(c.i64mul(3n, -4n), typeof c.i64mul(1n, 1n));
      try { c.i64mul(1, 2); } catch (e) { console.log(e.constructor.name); }
      console.log(JSON.stringify(c.swap(1, 2)));
      """)

    assert errors == []
    assert Enum.at(logs, 0) == "-3 20 5050 3.3000001907348633 NaN"
    assert Enum.at(logs, 1) == "-12n bigint"
    assert Enum.at(logs, 2) == "TypeError"
    assert Enum.at(logs, 3) == "[2,1]"
  end

  test "memory: buffer is shared with the module and detached by grow" do
    {logs, errors} =
      run(~S"""
      const i = new WebAssembly.Instance(new WebAssembly.Module(MEM)).exports;
      const mem = i.mem;
      console.log(mem instanceof WebAssembly.Memory, mem === i.mem, mem.buffer.byteLength);
      const u8 = new Uint8Array(mem.buffer);
      console.log(String.fromCharCode(...u8.slice(8, 13)));
      i.store32(100, 0x01020304);
      console.log(u8[100], u8[103]);
      u8[200] = 7;
      console.log(i.load8(200));
      const old = mem.buffer;
      console.log(mem.grow(1), old.byteLength, mem.buffer.byteLength, i.size());
      console.log(i.grow(1), mem.buffer.byteLength);
      try { mem.grow(1); } catch (e) { console.log(e.constructor.name); }
      const mine = new WebAssembly.Memory({ initial: 1, maximum: 2 });
      console.log(mine.buffer.byteLength, mine.grow(1), mine.buffer.byteLength);
      try { new WebAssembly.Memory({}); } catch (e) { console.log(e.constructor.name); }
      """)

    assert errors == []

    assert logs ==
             [
               "true true 65536",
               "hello",
               "4 1",
               "7",
               "1 0 131072 2",
               "-1 131072",
               "RangeError",
               "65536 1 131072"
             ] ++ ["TypeError"]
  end

  test "table and imports" do
    {logs, errors} =
      run(~S"""
      const t = new WebAssembly.Instance(new WebAssembly.Module(TBL)).exports;
      console.log(t.tbl.length, t.call(0, 21), t.call(1, 21), typeof t.tbl.get(0), t.tbl.get(2));
      console.log(t.tbl.get(0)(5), t.tbl.get(0) === t.tbl.get(0));
      t.tbl.set(2, t.tbl.get(1));
      console.log(t.call(2, 2));
      try { t.tbl.set(0, () => 1); } catch (e) { console.log(e.constructor.name); }
      try { t.tbl.get(9); } catch (e) { console.log(e.constructor.name); }
      console.log(t.tbl.grow(2), t.tbl.length);

      const g = new WebAssembly.Global({ value: "i32", mutable: true }, 5);
      const calls = [];
      const i = new WebAssembly.Instance(new WebAssembly.Module(IMP), {
        env: { add: (a, b) => { calls.push([a, b]); return a + b; }, g },
      }).exports;
      console.log(i.run(10), i.run(10), g.value, i.cnt.value, JSON.stringify(calls));
      g.value = 100;
      console.log(i.run(1));
      """)

    assert errors == []

    assert logs == [
             "3 42 63 function null",
             "10 true",
             "6",
             "TypeError",
             "RangeError",
             "3 5",
             "15 25 25 2 [[10,5],[10,15]]",
             "101"
           ]
  end

  test "promises: compile, instantiate with bytes and with a module" do
    {logs, errors} =
      run(~S"""
      WebAssembly.instantiate(FIB).then((r) => {
        console.log(Object.keys(r).join(), r.instance.exports.fib(10), r.module instanceof WebAssembly.Module);
        return WebAssembly.instantiate(r.module);
      }).then((inst) => console.log(inst instanceof WebAssembly.Instance, inst.exports.fib(7)));
      WebAssembly.compile(new Uint8Array([0, 1])).catch((e) => console.log("rejected", e.constructor.name));
      WebAssembly.instantiate(IMP, {}).catch((e) => console.log("rejected", e.constructor.name));
      """)

    assert errors == []

    assert Enum.sort(logs) ==
             Enum.sort([
               "module,instance 55 true",
               "true 13",
               "rejected CompileError",
               "rejected TypeError"
             ])
  end

  test "SIMD: the module runs, v128 does not cross into JavaScript" do
    {logs, errors} =
      run(~S"""
      const SIMD = b64("AGFzbQEAAAABGAVgAn9/AX9gAX8Bf2AAAX9gAAF9YAABewMHBgABAgIDBAUDAQABBywHA21lbQIABGFkZDQAAARzdW04AAEEbWFzawACBHNodWYAAwJmbAAEAXYABQrNAQYQACAA/REgAf0R/a4B/RsDCyUAQQD9DAECAwQFBgcICQoLDA0ODxD9CwQAQQD9AAQA/X39GQcLFgD9DP8A/wAAAAAAAAAAAAAAAID9ZAs7AP0MAAECAwQFBgcICQoLDA0OD/0MEBESExQVFhcYGRobHB0eH/0NHx4dHAAAAAAAAAAAAAAAAP0bAAssAP0MAADAPwAAIEAAAGBAAACQQP0MAACAPwAAgD8AAIA/AACAP/3kAf0fAgsUAP0MAQAAAAIAAAADAAAABAAAAAs=");
      const i = new WebAssembly.Instance(new WebAssembly.Module(SIMD)).exports;
      console.log(i.add4(40, 2), i.sum8(0), i.mask(), i.fl());
      try { i.v(); } catch (e) { console.log(e.constructor.name); }
      """)

    assert errors == []
    assert logs == ["42 31 32773 4.5", "TypeError"]
  end

  test "exceptions: catch, locals survive, uncaught become WebAssembly.Exception, JS can throw into the module" do
    {logs, errors} =
      run(~S"""
      const jsthrow = () => { throw new WebAssembly.Exception(tagFromModule, [42]); };
      let tagFromModule;
      const m = new WebAssembly.Module(EXC);
      console.log(JSON.stringify(WebAssembly.Module.exports(m).map((e) => e.kind + ":" + e.name)));
      // a module that throws into a catch_all through an import: the import throws a plain Error first
      const inst = new WebAssembly.Instance(m, { env: { jsthrow: () => { throw new WebAssembly.Exception(tagFromModule, [1]); } } });
      tagFromModule = inst.exports.e;
      const x = inst.exports;
      console.log(x.e instanceof WebAssembly.Tag, x.catchIt(5), x.catchAll(), x.viaJs());
      try { x.uncaught(9); } catch (e) {
        console.log(e instanceof WebAssembly.Exception, e.is(x.e), e.getArg(x.e, 0), String(e));
      }
      try { x.rethrow(3); } catch (e) { console.log("rethrown", e.getArg(x.e, 0)); }
      const other = new WebAssembly.Tag({ parameters: ["i32"] });
      const ex = new WebAssembly.Exception(other, [7]);
      console.log(ex.is(other), ex.is(x.e));
      try { ex.getArg(x.e, 0); } catch (e) { console.log(e.constructor.name); }
      try { new WebAssembly.Exception(other, []); } catch (e) { console.log(e.constructor.name); }
      """)

    assert errors == []

    assert logs == [
             ~s(["tag:e","function:catchIt","function:catchAll","function:uncaught","function:viaJs","function:rethrow"]),
             "true 12 1 1",
             "true true 9 [object WebAssembly.Exception]",
             "rethrown 3",
             "true false",
             "TypeError",
             "TypeError"
           ]
  end
end
