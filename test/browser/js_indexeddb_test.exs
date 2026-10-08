defmodule Browser.JS.IndexedDBTest do
  use ExUnit.Case, async: true
  alias Browser.JS.Runtime

  # a page of a new origin, so that tests do not see each other's databases
  defp origin, do: "http://idb#{System.unique_integer([:positive])}.test"

  defp start(origin, script) do
    {raw, _} =
      "<body><script>#{script}</script></body>" |> Browser.HTML.parse() |> Browser.Forms.index()

    pid =
      Runtime.start(raw, %{
        url: origin <> "/p",
        width: 800,
        height: 600,
        fetch: fn _ -> {:error, "404"} end
      })

    {pid, Runtime.run_scripts(pid)}
  end

  defp lines(%{console: console}), do: for({k, t} <- console, k in [:log, :error], do: {k, t})

  # everything a page logs, once all of its timers have run (timers also run by themselves, in
  # real time, and then the runtime sends what they logged)
  defp finish(pid, first) do
    flushed = Runtime.flush(pid)
    lines(first) ++ async([]) ++ lines(flushed)
  end

  defp async(acc) do
    receive do
      {:js_async, _, reply} -> async(acc ++ lines(reply))
    after
      0 -> acc
    end
  end

  defp run(script, expected_errors) do
    {pid, first} = start(origin(), script)
    all = finish(pid, first)
    errors = for {:error, t} <- all, do: t
    assert errors == expected_errors
    for {:log, t} <- all, do: t
  end

  @helpers """
  function p(r) { return new Promise(function (res, rej) { r.onsuccess = function () { res(r.result); }; r.onerror = function (e) { e.preventDefault(); rej(r.error); }; }); }
  function txDone(tx) { return new Promise(function (res, rej) { tx.addEventListener("complete", function () { res(); }); tx.addEventListener("abort", function () { rej(tx.error); }); }); }
  function open(name, version, upgrade) {
    return new Promise(function (res, rej) {
      var r = indexedDB.open(name, version);
      r.onupgradeneeded = function (e) { if (upgrade) upgrade(r.result, e, r.transaction); };
      r.onsuccess = function () { res(r.result); };
      r.onerror = function () { rej(r.error); };
    });
  }
  function show(a) { return typeof a === "string" ? a : a === undefined ? "undefined" : JSON.stringify(a, function (k, v) { return typeof v === "number" && !isFinite(v) ? String(v) : v; }); }
  function log() { console.log(Array.prototype.map.call(arguments, show).join(" ")); }
  function fail(e) { console.log("FAILED " + (e && e.name) + ": " + (e && e.message)); }
  """

  defp page(body, expected_errors \\ []),
    do:
      run(
        @helpers <> "\n(async function () {\n" <> body <> "\n})().catch(fail);",
        expected_errors
      )

  describe "object stores" do
    test "put, get, delete and count with out-of-line keys" do
      assert page("""
             var db = await open("d", 1, function (db) { db.createObjectStore("s"); });
             var tx = db.transaction("s", "readwrite");
             var s = tx.objectStore("s");
             s.put("one", 1); s.put("two", 2); s.put({a: [1, 2, {b: 3}]}, "k");
             await txDone(tx);
             var s2 = db.transaction("s").objectStore("s");
             log(await p(s2.get(1)), await p(s2.get(2)), await p(s2.get("k")), await p(s2.get(99)));
             log(await p(s2.count()), await p(s2.getAllKeys()));
             var w = db.transaction("s", "readwrite").objectStore("s");
             await p(w.delete(1));
             log(await p(w.count()), await p(w.clear()), await p(w.count()));
             """) == [
               ~s(one two {"a":[1,2,{"b":3}]} undefined),
               ~s(3 [1,2,"k"]),
               ~s(2 undefined 0)
             ]
    end

    test "keyPath stores take the key from the value, and autoIncrement makes keys" do
      assert page("""
             var db = await open("d", 1, function (db) {
               db.createObjectStore("people", {keyPath: "id"});
               db.createObjectStore("auto", {autoIncrement: true});
               db.createObjectStore("both", {keyPath: "n.id", autoIncrement: true});
             });
             var tx = db.transaction(["people", "auto", "both"], "readwrite");
             var people = tx.objectStore("people"), auto = tx.objectStore("auto"), both = tx.objectStore("both");
             log(await p(people.put({id: 7, name: "x"})));
             log(await p(auto.add("a")), await p(auto.add("b")), await p(auto.put("c", 10)), await p(auto.add("d")));
             var o = {n: {}};
             log(await p(both.add(o)), await p(both.add({n: {id: 5}})), await p(both.add({})));
             log(JSON.stringify(o), await p(both.get(1)), await p(both.get(6)));
             log(people.keyPath, auto.keyPath, both.keyPath, both.autoIncrement);
             """) == [
               "7",
               "1 2 10 11",
               "1 5 6",
               ~s({"n":{}} {"n":{"id":1}} {"n":{"id":6}}),
               ~s(id null n.id true)
             ]
    end

    test "add refuses a key that exists, and the error can be handled" do
      assert page("""
             var db = await open("d", 1, function (db) { db.createObjectStore("s"); });
             var tx = db.transaction("s", "readwrite");
             var s = tx.objectStore("s");
             s.add(1, "k");
             var r = s.add(2, "k");
             r.onerror = function (e) { log("error", r.error.name, e.type, e.defaultPrevented); e.preventDefault(); };
             var r3 = s.put(3, "j");
             r3.onsuccess = function () { log("still going"); };
             tx.oncomplete = function () { log("complete"); };
             tx.onabort = function () { log("abort"); };
             await txDone(tx);
             log(await p(db.transaction("s").objectStore("s").getAll()));
             """) == ["error ConstraintError error false", "still going", "complete", "[3,1]"]
    end

    test "an error that nobody handles aborts the transaction and rolls it back" do
      assert page("""
             var db = await open("d", 1, function (db) { db.createObjectStore("s"); });
             var tx = db.transaction("s", "readwrite");
             var s = tx.objectStore("s");
             s.add(1, "a");
             var r = s.add(2, "a");
             var third = s.add(3, "c");
             r.onerror = function () { log("request error", r.error.name); };
             third.onerror = function () { log("third", third.error.name); };
             tx.onerror = function (e) { log("tx error", e.target === r); };
             tx.onabort = function () { log("abort", tx.error.name); };
             tx.oncomplete = function () { log("complete?"); };
             await new Promise(function (r) { tx.onabort = function () { log("abort", tx.error.name); r(); }; });
             log(await p(db.transaction("s").objectStore("s").count()));
             """) == [
               "request error ConstraintError",
               "tx error true",
               "third AbortError",
               "tx error false",
               "abort ConstraintError",
               "0"
             ]
    end

    test "keys of every type sort the way the specification says" do
      assert page("""
             var db = await open("d", 1, function (db) { db.createObjectStore("s"); });
             var tx = db.transaction("s", "readwrite");
             var s = tx.objectStore("s");
             var keys = [[1, 2], [1], "b", "a", "", 10, -5, -Infinity, Infinity, 0.5, new Date(5), new Date(-1), new Uint8Array([2, 1]).buffer, new Uint8Array([1, 9]).buffer, [[]], []];
             keys.forEach(function (k, i) { s.put(i, k); });
             var all = await p(s.getAllKeys());
             log(all.map(function (k) {
               if (k instanceof Date) return "D" + k.getTime();
               if (k instanceof ArrayBuffer) return "B" + Array.from(new Uint8Array(k)).join(",");
               return typeof k === "number" ? String(k) : JSON.stringify(k);
             }).join(" "));
             log(indexedDB.cmp(1, "1"), indexedDB.cmp([1, 2], [1, 3]), indexedDB.cmp("a", "a"), indexedDB.cmp(new Date(1), 5));
             """) == [
               "-Infinity -5 0.5 10 Infinity D-1 D5 \"\" \"a\" \"b\" B1,9 B2,1 [] [1] [1,2] [[]]",
               "-1 -1 0 1"
             ]
    end

    test "invalid keys and calls throw the right errors" do
      assert page("""
             var db = await open("d", 1, function (db) { db.createObjectStore("s"); db.createObjectStore("k", {keyPath: "id"}); });
             var tx = db.transaction(["s", "k"], "readwrite");
             var s = tx.objectStore("s"), k = tx.objectStore("k");
             function t(f) { try { f(); return "no error"; } catch (e) { return e.name; } }
             log(t(function () { s.put(1); }), t(function () { s.put(1, {}); }), t(function () { s.put(1, NaN); }));
             log(t(function () { k.put({id: 1}, 1); }), t(function () { k.put({}); }), t(function () { k.put({id: {}}); }));
             log(t(function () { s.put(function () {}, 1); }), t(function () { s.put(Symbol(), 1); }), t(function () { s.get(); }));
             log(t(function () { db.transaction("nope"); }), t(function () { db.transaction([]); }), t(function () { tx.objectStore("zzz"); }));
             log(t(function () { db.transaction("s", "bogus"); }), t(function () { db.createObjectStore("x"); }));
             var ro = db.transaction("s").objectStore("s");
             log(t(function () { ro.put(1, 1); }), t(function () { ro.clear(); }));
             await txDone(tx);
             log(t(function () { s.put(1, 1); }), t(function () { tx.abort(); }));
             """) == [
               "DataError DataError DataError",
               "DataError DataError DataError",
               "DataCloneError DataCloneError TypeError",
               "NotFoundError InvalidAccessError NotFoundError",
               "TypeError InvalidStateError",
               "ReadOnlyError ReadOnlyError",
               "TransactionInactiveError InvalidStateError"
             ]
    end

    test "values are cloned: dates, maps, sets, buffers, cycles and undefined survive" do
      assert page("""
             var db = await open("d", 1, function (db) { db.createObjectStore("s"); });
             var cyc = {name: "c"}; cyc.self = cyc;
             var v = {d: new Date(86400000), m: new Map([[1, {a: 1}], ["x", [1, 2]]]), s: new Set([1, "two"]), u: undefined, n: null, nan: NaN, neg0: -0, inf: -Infinity,
               bytes: new Uint8Array([1, 2, 3]), f: new Float64Array([1.5, 2.5]), re: /ab+/gi, cyc: cyc, arr: [1, , 3], big: 12345678901234567890n, str: new String("boxed"), err: new RangeError("bad")};
             var tx = db.transaction("s", "readwrite");
             tx.objectStore("s").put(v, 1);
             await txDone(tx);
             var r = await p(db.transaction("s").objectStore("s").get(1));
             log(r.d instanceof Date, r.d.getTime(), r.m instanceof Map, r.m.get(1).a, r.m.get("x").length, r.s.has("two"), "u" in r, r.u, r.n, Number.isNaN(r.nan), Object.is(r.neg0, -0), r.inf);
             log(Array.from(r.bytes), r.bytes instanceof Uint8Array, Array.from(r.f), r.re.source, r.re.flags, r.cyc.self === r.cyc, r.cyc !== cyc, r.arr.length, 1 in r.arr);
             log(typeof r.big, String(r.big), r.str instanceof String, String(r.str), r.err instanceof RangeError, r.err.message, r !== v);
             """) == [
               ~s(true 86400000 true 1 2 true true undefined null true true "-Infinity"),
               "[1,2,3] true [1.5,2.5] ab+ gi true true 3 false",
               "bigint 12345678901234567890 true boxed true bad true"
             ]
    end

    test "structuredClone works the same way" do
      assert page("""
             var a = {x: new Date(7), y: [1, {z: new Set([1])}]};
             a.me = a;
             var b = structuredClone(a);
             log(b !== a, b.x instanceof Date, b.x.getTime(), b.y[1].z.has(1), b.me === b);
             try { structuredClone({f: function () {}}); } catch (e) { log(e.name); }
             log(structuredClone(undefined), structuredClone(5), structuredClone("s"));
             """) == ["true true 7 true true", "DataCloneError", "undefined 5 s"]
    end
  end

  describe "indexes" do
    @people """
    var db = await open("d", 1, function (db) {
      var s = db.createObjectStore("people", {keyPath: "id"});
      s.createIndex("name", "name");
      s.createIndex("email", "email", {unique: true});
      s.createIndex("tags", "tags", {multiEntry: true});
      s.createIndex("full", ["first", "last"]);
      s.put({id: 1, name: "Ann", email: "a@x", tags: ["x", "y"], first: "A", last: "Z"});
      s.put({id: 2, name: "Bob", email: "b@x", tags: ["y"], first: "B", last: "Y"});
      s.put({id: 3, name: "Ann", email: "c@x", tags: [], first: "A", last: "A"});
      s.put({id: 4, email: "d@x", tags: "z"});
    });
    var people = function (mode) { return db.transaction("people", mode || "readonly").objectStore("people"); };
    """

    test "lookups through an index" do
      assert page(
               @people <>
                 """
                 var n = people().index("name");
                 log(await p(n.get("Ann")), await p(n.getKey("Ann")), await p(n.count()), await p(n.count("Ann")));
                 log((await p(n.getAll("Ann"))).map(function (r) { return r.id; }), await p(n.getAllKeys()), await p(n.getAllKeys(null, 2)));
                 log((await p(people().index("tags").getAll("y"))).map(function (r) { return r.id; }), await p(people().index("tags").getAllKeys()));
                 log(await p(people().index("full").getAllKeys()), (await p(people().index("full").get(["B", "Y"]))).id);
                 log(await p(people().index("email").getKey("b@x")), await p(people().index("email").get("zz")));
                 log(people().indexNames.length, people().indexNames.contains("tags"), people().index("tags").multiEntry, people().index("email").unique, people().index("full").keyPath);
                 """
             ) == [
               ~s({"id":1,"name":"Ann","email":"a@x","tags":["x","y"],"first":"A","last":"Z"} 1 3 2),
               ~s([1,3] [1,3,2] [1,3]),
               ~s([1,2] [1,1,2,4]),
               ~s([3,1,2] 2),
               ~s(2 undefined),
               ~s(4 true true true ["first","last"])
             ]
    end

    test "a unique index refuses a second record with the same key" do
      assert page(
               @people <>
                 """
                 var tx = db.transaction("people", "readwrite");
                 var r = tx.objectStore("people").add({id: 9, email: "a@x"});
                 r.onerror = function (e) { log(r.error.name); };
                 try { await txDone(tx); } catch (e) { log("aborted", e.name); }
                 tx = db.transaction("people", "readwrite");
                 tx.objectStore("people").put({id: 1, name: "Anna", email: "a@x", tags: ["q"]});
                 await txDone(tx);
                 log((await p(people().index("tags").getAll("q"))).length, (await p(people().index("tags").getAll("x"))).length, (await p(people().index("name").getAll("Anna"))).length);
                 """
             ) == ["ConstraintError", "aborted ConstraintError", "1 0 1"]
    end

    test "deleting and clearing take records out of the indexes" do
      assert page(
               @people <>
                 """
                 var w = people("readwrite");
                 await p(w.delete(1));
                 log(await p(w.index("name").count()), await p(w.index("tags").count()));
                 await p(w.clear());
                 log(await p(w.index("name").count()), await p(w.index("email").count()));
                 """
             ) == ["2 2", "0 0"]
    end

    test "createIndex fills the index from the records that exist, deleteIndex removes it" do
      assert page("""
             var db = await open("d", 1, function (db) {
               var s = db.createObjectStore("s", {autoIncrement: true});
               s.put({v: 3}); s.put({v: 1}); s.put({v: 2});
             });
             db = (db.close(), await open("d", 2, function (db, e, tx) {
               var s = tx.objectStore("s");
               s.createIndex("v", "v");
               log(s.indexNames.length);
             }));
             var s = db.transaction("s").objectStore("s");
             log(await p(s.index("v").getAllKeys()), (await p(s.index("v").getAll())).map(function (r) { return r.v; }));
             db.close();
             db = await open("d", 3, function (db, e, tx) { tx.objectStore("s").deleteIndex("v"); });
             log(db.transaction("s").objectStore("s").indexNames.length);
             """) == ["1", "[2,3,1] [1,2,3]", "0"]
    end
  end

  describe "cursors" do
    @numbers """
    var db = await open("d", 1, function (db) {
      var s = db.createObjectStore("s");
      var i = s.createIndex("mod", "m");
      for (var n = 1; n <= 6; n++) s.put({m: n % 3, n: n}, n);
    });
    function walk(source, range, dir) {
      return new Promise(function (res) {
        var out = [];
        source.openCursor(range, dir).onsuccess = function (e) {
          var c = e.target.result;
          if (!c) return res(out.join(" "));
          out.push(c.key + ":" + c.primaryKey + (c.value ? "=" + c.value.n : ""));
          c.continue();
        };
      });
    }
    var store = function (mode) { return db.transaction("s", mode || "readonly").objectStore("s"); };
    """

    test "directions and ranges" do
      assert page(
               @numbers <>
                 """
                 log(await walk(store()));
                 log(await walk(store(), null, "prev"));
                 log(await walk(store(), IDBKeyRange.bound(2, 4)));
                 log(await walk(store(), IDBKeyRange.bound(2, 4, true, true), "prev"));
                 log(await walk(store(), IDBKeyRange.lowerBound(5)), "|", await walk(store(), IDBKeyRange.upperBound(2, true)), "|", await walk(store(), 3));
                 log(await walk(store().index("mod")));
                 log(await walk(store().index("mod"), null, "prev"));
                 log(await walk(store().index("mod"), null, "nextunique"));
                 log(await walk(store().index("mod"), null, "prevunique"));
                 log(await walk(store().index("mod"), IDBKeyRange.only(1)));
                 """
             ) == [
               "1:1=1 2:2=2 3:3=3 4:4=4 5:5=5 6:6=6",
               "6:6=6 5:5=5 4:4=4 3:3=3 2:2=2 1:1=1",
               "2:2=2 3:3=3 4:4=4",
               "3:3=3",
               "5:5=5 6:6=6 | 1:1=1 | 3:3=3",
               "0:3=3 0:6=6 1:1=1 1:4=4 2:2=2 2:5=5",
               "2:5=5 2:2=2 1:4=4 1:1=1 0:6=6 0:3=3",
               "0:3=3 1:1=1 2:2=2",
               "2:2=2 1:1=1 0:3=3",
               "1:1=1 1:4=4"
             ]
    end

    test "advance, continue with a key, continuePrimaryKey" do
      assert page(
               @numbers <>
                 """
                 var out = [];
                 await new Promise(function (res) {
                   var step = 0;
                   store().openCursor().onsuccess = function (e) {
                     var c = e.target.result;
                     if (!c) return res();
                     out.push(c.key);
                     if (step++ === 0) c.advance(2); else if (step === 2) c.continue(5); else c.continue();
                   };
                 });
                 log(out);
                 var seen = [];
                 await new Promise(function (res) {
                   var first = true;
                   store().index("mod").openKeyCursor().onsuccess = function (e) {
                     var c = e.target.result;
                     if (!c) return res();
                     seen.push(c.key + ":" + c.primaryKey + ":" + ("value" in c));
                     if (first) { first = false; c.continuePrimaryKey(1, 4); } else c.continue();
                   };
                 });
                 log(seen);
                 var bad = [];
                 await new Promise(function (res) {
                   store().openCursor().onsuccess = function (e) {
                     var c = e.target.result;
                     if (!c) return;
                     try { c.continue(0); } catch (x) { bad.push(x.name); }
                     try { c.advance(0); } catch (x) { bad.push(x.name); }
                     c.continue();
                     try { c.continue(); } catch (x) { bad.push(x.name); }
                     res();
                   };
                 });
                 log(bad);
                 """
             ) == [
               "[1,3,5,6]",
               ~s(["0:3:false","1:4:false","2:2:false","2:5:false"]),
               ~s(["DataError","TypeError","InvalidStateError"])
             ]
    end

    test "update and delete through a cursor" do
      assert page(
               @numbers <>
                 """
                 var w = store("readwrite");
                 await new Promise(function (res) {
                   w.openCursor().onsuccess = function (e) {
                     var c = e.target.result;
                     if (!c) return res();
                     if (c.key % 2) { c.update({m: 0, n: c.value.n * 10}); } else c.delete();
                     c.continue();
                   };
                 });
                 log(await p(store().getAll()), await p(store().count()), await p(store().index("mod").count()));
                 """
             ) == [
               ~s([{"m":0,"n":10},{"m":0,"n":30},{"m":0,"n":50}] 3 3)
             ]
    end

    test "the request of a cursor is the same object for every step" do
      assert page(
               @numbers <>
                 """
                 var r = store().openCursor();
                 var results = [], reqs = 0, count = 0;
                 await new Promise(function (res) {
                   r.onsuccess = function (e) {
                     reqs += e.target === r ? 1 : 0;
                     var c = r.result;
                     if (!c) return res();
                     results.push(c === c.request.result || c.request === r);
                     count++;
                     c.continue();
                   };
                 });
                 log(count, reqs, results.every(Boolean), r.readyState, r.result);
                 """
             ) == ["6 7 true done null"]
    end
  end

  describe "key ranges" do
    test "bounds, includes and errors" do
      assert page("""
             var r = IDBKeyRange.bound(1, 5, false, true);
             log(r.lower, r.upper, r.lowerOpen, r.upperOpen, r.includes(1), r.includes(5), r.includes(3), r.includes(0));
             var o = IDBKeyRange.only("a"), l = IDBKeyRange.lowerBound(2, true), u = IDBKeyRange.upperBound([1]);
             log(o.includes("a"), l.includes(2), l.includes(3), l.upper, u.includes([0, 9]), u.includes([1]), u.includes([2]));
             function t(f) { try { f(); return "ok"; } catch (e) { return e.name; } }
             log(t(function () { IDBKeyRange.bound(5, 1); }), t(function () { IDBKeyRange.bound(1, 1, true); }), t(function () { IDBKeyRange.only({}); }), t(function () { new IDBKeyRange(); }));
             log(r instanceof IDBKeyRange, Object.prototype.toString.call(r));
             """) == [
               "1 5 false true true false true false",
               "true false true undefined true true false",
               "DataError DataError DataError TypeError",
               "true [object IDBKeyRange]"
             ]
    end
  end

  describe "transactions" do
    test "events come in the order of the requests, and complete comes last" do
      assert page("""
             var db = await open("d", 1, function (db) { db.createObjectStore("s"); });
             var tx = db.transaction("s", "readwrite");
             var s = tx.objectStore("s");
             var order = [];
             s.put(1, 1).onsuccess = function () { order.push("put1"); Promise.resolve().then(function () { order.push("micro"); }); };
             s.put(2, 2).onsuccess = function () { order.push("put2"); };
             s.get(1).onsuccess = function (e) { order.push("get" + e.target.result); };
             tx.oncomplete = function () { order.push("complete"); };
             await txDone(tx);
             log(order);
             """) == [~s(["put1","micro","put2","get1","complete"])]
    end

    test "a transaction is not active outside the task that made it" do
      assert page("""
             var db = await open("d", 1, function (db) { db.createObjectStore("s"); });
             var tx = db.transaction("s", "readwrite");
             var s = tx.objectStore("s");
             s.put(1, 1);
             var finished = txDone(tx);
             await new Promise(function (r) { setTimeout(r, 10); });
             try { s.put(2, 2); log("no error"); } catch (e) { log(e.name); }
             await finished;
             // a request made in a callback, and after an await in it, still works
             var tx2 = db.transaction("s", "readwrite");
             var s2 = tx2.objectStore("s");
             var done = new Promise(function (res) {
               s2.get(1).onsuccess = async function () {
                 await Promise.resolve();
                 await Promise.resolve();
                 s2.put(3, 3).onsuccess = function () { res(); };
               };
             });
             await done;
             await txDone(tx2);
             log(await p(db.transaction("s").objectStore("s").getAllKeys()));
             """) == ["TransactionInactiveError", "[1,3]"]
    end

    test "abort rolls back, and a throwing handler aborts" do
      assert page("""
             var db = await open("d", 1, function (db) { db.createObjectStore("s"); });
             var tx = db.transaction("s", "readwrite");
             tx.objectStore("s").put("a", 1);
             tx.abort();
             var r = tx.objectStore("s");
             """) == ["FAILED InvalidStateError: The transaction has finished."]

      assert page(
               """
               var db = await open("d", 1, function (db) { db.createObjectStore("s"); });
               var tx = db.transaction("s", "readwrite");
               var req = tx.objectStore("s").put("a", 1);
               tx.onabort = function () { log("abort", tx.error); };
               req.onerror = function (e) { log("req error", req.error.name, e.defaultPrevented); };
               tx.abort();
               await new Promise(function (r) { setTimeout(r, 20); });
               log(await p(db.transaction("s").objectStore("s").count()));
               var tx2 = db.transaction("s", "readwrite");
               var r2 = tx2.objectStore("s").put("b", 2);
               r2.onsuccess = function () { throw new Error("handler bug"); };
               tx2.onabort = function () { log("tx2 abort", tx2.error.name); };
               await new Promise(function (r) { setTimeout(r, 20); });
               log(await p(db.transaction("s").objectStore("s").count()));
               """,
               ["Uncaught Error: handler bug"]
             ) == [
               "req error AbortError false",
               "abort null",
               "0",
               "tx2 abort AbortError",
               "0"
             ]
    end

    test "transactions of the same stores run one after the other" do
      assert page("""
             var db = await open("d", 1, function (db) { db.createObjectStore("s"); });
             var a = db.transaction("s", "readwrite"), b = db.transaction("s", "readwrite"), c = db.transaction("s");
             var order = [];
             a.objectStore("s").put("a", "k").onsuccess = function () { order.push("a"); };
             b.objectStore("s").put("b", "k").onsuccess = function () { order.push("b"); };
             c.objectStore("s").get("k").onsuccess = function (e) { order.push("c sees " + e.target.result); };
             a.oncomplete = function () { order.push("a done"); };
             await txDone(c);
             log(order);
             """) == [~s(["a","a done","b","c sees b"])]
    end

    test "transaction properties" do
      assert page("""
             var db = await open("d", 1, function (db) { db.createObjectStore("b"); db.createObjectStore("a"); });
             var tx = db.transaction(["b", "a", "b"], "readwrite");
             log(tx.mode, tx.db === db, Array.from(tx.objectStoreNames), tx.error, db.transaction("a").mode, tx.objectStore("a") === tx.objectStore("a"));
             log(Array.from(db.objectStoreNames), db.objectStoreNames.contains("a"), db.objectStoreNames.item(1), db.name, db.version);
             log(tx.objectStore("a").transaction === tx, tx.objectStore("a").name, tx.objectStore("a").autoIncrement);
             """) == [
               ~s(readwrite true ["a","b"] null readonly true),
               ~s(["a","b"] true b d 1),
               "true a false"
             ]
    end
  end

  describe "databases and versions" do
    test "upgradeneeded runs for a new database and for a higher version" do
      assert page("""
             var seen = [];
             var db = await open("d", 3, function (db, e, tx) { seen.push(e.oldVersion + ">" + e.newVersion + ":" + tx.mode + ":" + db.version); db.createObjectStore("one"); });
             db.close();
             db = await open("d", 5, function (db, e, tx) { seen.push(e.oldVersion + ">" + e.newVersion); db.createObjectStore("two"); db.deleteObjectStore("one"); });
             log(seen, db.version, Array.from(db.objectStoreNames));
             db.close();
             db = await open("d");
             log(db.version);
             db.close();
             try { await open("d", 2); } catch (e) { log(e.name); }
             """) == [~s(["0>3:versionchange:3","3>5"] 5 ["two"]), "5", "VersionError"]
    end

    test "open without a version makes version 1, and the event order is upgradeneeded, complete, success" do
      assert page("""
             var order = [];
             await new Promise(function (res) {
               var r = indexedDB.open("fresh");
               r.onupgradeneeded = function (e) {
                 order.push("upgrade " + e.oldVersion + " " + e.newVersion + " " + r.readyState);
                 r.transaction.oncomplete = function () { order.push("tx complete"); };
               };
               r.onsuccess = function () { order.push("success " + r.result.version + " " + r.transaction); res(); };
             });
             log(order);
             """) == [~s(["upgrade 0 1 done","tx complete","success 1 null"])]
    end

    test "an aborted upgrade leaves the database as it was" do
      assert page("""
             var db = await open("d", 1, function (db) { db.createObjectStore("s"); });
             db.close();
             var r = indexedDB.open("d", 2);
             r.onupgradeneeded = function () {
               r.result.createObjectStore("t");
               r.transaction.abort();
             };
             await new Promise(function (res) { r.onerror = function (e) { log("error", r.error.name); res(); }; });
             db = await open("d");
             log(db.version, Array.from(db.objectStoreNames));
             var r2 = indexedDB.open("brand-new", 1);
             r2.onupgradeneeded = function () { r2.result.createObjectStore("x"); r2.transaction.abort(); };
             await new Promise(function (res) { r2.onerror = function () { res(); }; });
             log(JSON.stringify(await indexedDB.databases()));
             """) == ["error AbortError", "1 [\"s\"]", ~s([{"name":"d","version":1}])]
    end

    test "an error thrown in upgradeneeded fails the open" do
      assert page(
               """
               var r = indexedDB.open("d", 1);
               r.onupgradeneeded = function () { r.result.createObjectStore("s"); throw new Error("oops"); };
               await new Promise(function (res) { r.onerror = function () { log("error", r.error.name); res(); }; });
               log(JSON.stringify(await indexedDB.databases()));
               """,
               ["Uncaught Error: oops"]
             ) == ["error AbortError", "[]"]
    end

    test "deleteDatabase removes the data" do
      assert page("""
             var db = await open("d", 1, function (db) { db.createObjectStore("s"); });
             var tx = db.transaction("s", "readwrite"); tx.objectStore("s").put(1, 1); await txDone(tx);
             db.close();
             log(JSON.stringify(await indexedDB.databases()));
             var r = indexedDB.deleteDatabase("d");
             var e = await new Promise(function (res) { r.onsuccess = res; });
             log(e.type, e.oldVersion, e.newVersion, r.result);
             log(JSON.stringify(await indexedDB.databases()));
             db = await open("d", 1, function (db) { db.createObjectStore("s"); });
             log(await p(db.transaction("s").objectStore("s").count()));
             """) == [~s([{"name":"d","version":1}]), "success 1 null undefined", "[]", "0"]
    end

    test "a second connection gets versionchange, and blocked until the first closes" do
      assert page("""
             var db1 = await open("d", 1, function (db) { db.createObjectStore("s"); });
             var events = [];
             db1.onversionchange = function (e) { events.push("versionchange " + e.oldVersion + ">" + e.newVersion); };
             var r = indexedDB.open("d", 2);
             r.onblocked = function (e) { events.push("blocked " + e.oldVersion + ">" + e.newVersion); setTimeout(function () { db1.close(); }, 5); };
             r.onupgradeneeded = function () { events.push("upgrade"); r.result.createObjectStore("t"); };
             await new Promise(function (res) { r.onsuccess = res; });
             events.push("success " + r.result.version);
             log(events);
             var d = indexedDB.deleteDatabase("d");
             r.result.onversionchange = function (e) { events.push("delete versionchange " + e.oldVersion + ">" + e.newVersion); r.result.close(); };
             await new Promise(function (res) { d.onsuccess = res; });
             log(events[events.length - 1]);
             """) == [
               ~s(["versionchange 1>2","blocked 1>2","upgrade","success 2"]),
               "delete versionchange 2>null"
             ]
    end

    test "close waits for running transactions, and a closed connection refuses new ones" do
      assert page("""
             var db = await open("d", 1, function (db) { db.createObjectStore("s"); });
             var tx = db.transaction("s", "readwrite");
             tx.objectStore("s").put(1, 1);
             db.close();
             try { db.transaction("s"); } catch (e) { log(e.name); }
             await txDone(tx);
             db = await open("d");
             log(await p(db.transaction("s").objectStore("s").get(1)));
             """) == ["InvalidStateError", "1"]
    end

    test "createObjectStore outside an upgrade fails" do
      assert page("""
             var db = await open("d", 1);
             try { db.createObjectStore("s"); } catch (e) { log(e.name); }
             var tx = db.transaction([]);
             """) == [
               "InvalidStateError",
               "FAILED InvalidAccessError: The storeNames parameter is empty."
             ]
    end

    test "stores and indexes can be renamed in an upgrade" do
      assert page("""
             var db = await open("d", 1, function (db) { var s = db.createObjectStore("old", {keyPath: "id"}); s.createIndex("i", "v"); s.put({id: 1, v: 5}); });
             db.close();
             db = await open("d", 2, function (db, e, tx) { var s = tx.objectStore("old"); s.name = "new"; s.index("i").name = "j"; });
             log(Array.from(db.objectStoreNames), Array.from(db.transaction("new").objectStore("new").indexNames));
             log(await p(db.transaction("new").objectStore("new").index("j").get(5)));
             """) == [~s(["new"] ["j"]), ~s({"id":1,"v":5})]
    end
  end

  describe "events and classes" do
    test "requests are event targets: listeners, bubbling, capture and stopPropagation" do
      assert page("""
             var db = await open("d", 1, function (db) { db.createObjectStore("s"); });
             var tx = db.transaction("s", "readwrite");
             var order = [];
             db.addEventListener("error", function (e) { order.push("db bubble " + e.eventPhase); });
             tx.addEventListener("error", function (e) { order.push("tx capture " + e.eventPhase); }, true);
             tx.addEventListener("error", function (e) { order.push("tx bubble " + e.eventPhase + " " + (e.currentTarget === tx) + " " + (e.target !== tx)); });
             var s = tx.objectStore("s");
             s.add(1, "k");
             var r = s.add(2, "k");
             r.addEventListener("error", function (e) { order.push("req " + e.eventPhase + " " + e.bubbles + " " + e.cancelable); });
             r.addEventListener("error", function (e) { order.push("req once"); }, {once: true});
             r.onerror = function (e) { order.push("onerror"); e.preventDefault(); };
             await txDone(tx);
             log(order);
             log(r instanceof IDBRequest, r instanceof EventTarget, tx instanceof IDBTransaction, db instanceof IDBDatabase, s instanceof IDBObjectStore);
             """) == [
               ~s(["tx capture 1","req 2 true true","req once","onerror","tx bubble 3 true true","db bubble 3"]),
               "true true true true true"
             ]
    end

    test "constructors are illegal, the version change event can be built" do
      assert page("""
             function t(f) { try { f(); return "ok"; } catch (e) { return e.name; } }
             log(t(function () { new IDBRequest(); }), t(function () { new IDBDatabase(); }), t(function () { new IDBTransaction(); }));
             var e = new IDBVersionChangeEvent("x", {oldVersion: 2, newVersion: 3});
             log(e.type, e.oldVersion, e.newVersion, e instanceof Event, new IDBVersionChangeEvent("y").newVersion);
             log(indexedDB instanceof IDBFactory, typeof window.indexedDB, window.indexedDB === indexedDB, typeof IDBCursorWithValue, IDBCursorWithValue.prototype instanceof IDBCursor);
             """) == [
               "TypeError TypeError TypeError",
               "x 2 3 true null",
               "true object true function true"
             ]
    end

    test "a request is pending until its event, and then has a result" do
      assert page("""
             var db = await open("d", 1, function (db) { db.createObjectStore("s"); });
             var s = db.transaction("s", "readwrite").objectStore("s");
             var r = s.put("v", 1);
             var before = r.readyState;
             try { r.result; } catch (e) { log(e.name); }
             await p(r);
             log(before, r.readyState, r.result, r.error, r.source === s, r.transaction === s.transaction);
             """) == ["InvalidStateError", "pending done 1 null true true"]
    end
  end

  describe "pages of one origin" do
    test "a second page sees what the first one stored, and hears of its version changes" do
      origin = origin()

      {a, first_a} =
        start(
          origin,
          @helpers <>
            """
            (async function () {
              var db = await open("shared", 1, function (db) { db.createObjectStore("s"); });
              var tx = db.transaction("s", "readwrite");
              tx.objectStore("s").put({from: "page a"}, "k");
              await txDone(tx);
              window.dba = db;
              db.onversionchange = function (e) { log("a: versionchange", e.oldVersion, e.newVersion); db.close(); };
              log("a: stored");
            })().catch(fail);
            """
        )

      assert finish(a, first_a) == [log: "a: stored"]

      {b, first_b} =
        start(
          origin,
          @helpers <>
            """
            (async function () {
              var db = await open("shared", 1);
              log("b: read", await p(db.transaction("s").objectStore("s").get("k")));
              db.close();
              var db2 = await open("shared", 2, function (db) { db.createObjectStore("t"); });
              log("b: upgraded", db2.version, Array.from(db2.objectStoreNames));
            })().catch(fail);
            """
        )

      # b's upgrade waits until a (a separate page) has heard of it and closed its connection
      all = settle([{b, first_b}, {a, %{console: []}}], 20)
      assert {:log, ~s(b: read {"from":"page a"})} in all
      assert {:log, "a: versionchange 1 2"} in all
      assert {:log, "b: upgraded 2 [\"s\",\"t\"]"} in all
    end

    test "databases are kept per origin" do
      a = origin()
      b = origin()

      script =
        @helpers <>
          "(async function () { var db = await open(\"same\", 1, function (db) { log(\"upgrade\"); }); })().catch(fail);"

      {p1, f1} = start(a, script)
      assert finish(p1, f1) == [log: "upgrade"]
      {p2, f2} = start(b, script)
      assert finish(p2, f2) == [log: "upgrade"]
      {p3, f3} = start(a, script)
      assert finish(p3, f3) == []
    end
  end

  # runs the pages in turn until nothing more is logged
  defp settle(pages, rounds) do
    Enum.reduce(
      1..rounds,
      {[], Enum.map(pages, fn {pid, first} -> {pid, lines(first)} end)},
      fn _, {acc, pgs} ->
        {acc, pgs} =
          Enum.reduce(pgs, {acc, []}, fn {pid, pending}, {acc, out} ->
            flushed = lines(Runtime.flush(pid))
            {acc ++ pending ++ async([]) ++ flushed, out ++ [{pid, []}]}
          end)

        {acc, pgs}
      end
    )
    |> elem(0)
  end
end
