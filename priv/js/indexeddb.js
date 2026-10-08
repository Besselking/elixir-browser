// indexedDB and the IDB* classes. Loaded the first time a page uses one of the names (see
// Browser.JS.IndexedDB). The storage is native (Browser.IndexedDB): one JSON text per database,
// shared by the pages of an origin. Everything else is here.
//
// How it works:
// - A database is kept in memory as sorted arrays (`records`, and `entries` for every index). A
//   page reads it again when another page has written it (a revision number tells), and writes the
//   whole database when a transaction that changed it commits.
// - Values are kept in a tagged JSON form (`enc`/`dec`), which is also the structured clone: a
//   value goes in as a tree, and every read builds a new object from it.
// - Keys have a normal form (numbers and strings as they are, `{t:"d"}` dates, `{t:"b"}` binary
//   as hex, arrays), which `cmp` orders as the specification says.
// - Every step of the specification that runs "in a task" is a `setTimeout(fn, 0)` here. A
//   transaction runs one request per task, and is active only in the task of the request that
//   is being handled (and its microtasks).
// - Transactions of a page that touch the same database run one after the other. Another page
//   that opens a higher version, or deletes the database, is told with `versionchange` events;
//   the store (Browser.IndexedDB) keeps the connections and the queue of such requests.
(function (g) {
  "use strict";

  var setT = g.setTimeout;
  var DOMEx = g.DOMException;
  var hasOwn = Object.prototype.hasOwnProperty;

  // ── small helpers ─────────────────────────────────────────

  var states = new WeakMap();
  function S(o) {
    var s = (o !== null && typeof o === "object") ? states.get(o) : undefined;
    if (!s) throw new TypeError("Illegal invocation");
    return s;
  }
  function make(proto, state) {
    var o = Object.create(proto);
    states.set(o, state);
    return o;
  }
  function hide(o, n, v) { Object.defineProperty(o, n, { value: v, writable: true, configurable: true, enumerable: false }); }
  function getter(proto, n, fn) { Object.defineProperty(proto, n, { get: fn, configurable: true, enumerable: true }); }
  function tag(proto, name) { Object.defineProperty(proto, Symbol.toStringTag, { value: name, configurable: true }); }
  function task(fn) { setT(fn, 0); }

  var CODES = { IndexSizeError: 1, HierarchyRequestError: 3, WrongDocumentError: 4, InvalidCharacterError: 5, NoModificationAllowedError: 7,
    NotFoundError: 8, NotSupportedError: 9, InvalidStateError: 11, SyntaxError: 12, InvalidModificationError: 13, NamespaceError: 14,
    InvalidAccessError: 15, TypeMismatchError: 17, SecurityError: 18, NetworkError: 19, AbortError: 20, URLMismatchError: 21,
    QuotaExceededError: 22, TimeoutError: 23, InvalidNodeTypeError: 24, DataCloneError: 25 };
  function err(name, msg) {
    var e = new DOMEx(msg || name, name);
    if (CODES[name] !== undefined) { try { e.code = CODES[name]; } catch (x) {} }
    return e;
  }
  function illegal() { throw new TypeError("Illegal constructor"); }
  function toUInt(v, what) {
    var n = Number(v);
    if (n !== n || n === Infinity || n === -Infinity) throw new TypeError("The " + what + " is not a finite number.");
    n = n < 0 ? Math.ceil(n) : Math.floor(n);
    if (n < 0 || n > 4294967295) throw new TypeError("The " + what + " is out of range.");
    return n;
  }
  function need1(args) { if (args.length === 0) throw new TypeError("1 argument required, but only 0 present."); }
  function reportLater(e) { task(function () { throw e; }); }

  // ── events ────────────────────────────────────────────────

  var ETP = Object.create(g.EventTarget.prototype);
  hide(ETP, "constructor", g.EventTarget);

  function newState(extra) {
    extra.l = {};
    extra.h = {};
    return extra;
  }
  function listenerOpts(o) {
    if (typeof o === "boolean") return { capture: o, once: false };
    return { capture: !!(o && o.capture), once: !!(o && o.once) };
  }
  hide(ETP, "addEventListener", function (type, cb, opts) {
    var s = S(this);
    if (cb === null || cb === undefined) return;
    type = String(type);
    var o = listenerOpts(opts);
    var list = s.l[type] || (s.l[type] = []);
    for (var i = 0; i < list.length; i++) if (list[i].cb === cb && list[i].capture === o.capture) return;
    list.push({ cb: cb, capture: o.capture, once: o.once });
  });
  hide(ETP, "removeEventListener", function (type, cb, opts) {
    var s = S(this);
    var list = s.l[String(type)];
    if (!list) return;
    var o = listenerOpts(opts);
    for (var i = 0; i < list.length; i++) if (list[i].cb === cb && list[i].capture === o.capture) { list.splice(i, 1); return; }
  });
  hide(ETP, "dispatchEvent", function (ev) {
    S(this);
    if (!(ev instanceof g.Event)) throw new TypeError("The event is not an Event.");
    dispatch(ev, pathOf(this));
    return !ev.defaultPrevented;
  });

  // `onsuccess` and the like: a handler takes the place in the list of listeners where it was first set
  function handlers(proto, names) {
    names.forEach(function (n) {
      Object.defineProperty(proto, "on" + n, {
        get: function () { var v = S(this).h[n]; return v === undefined ? null : v; },
        set: function (f) {
          var s = S(this);
          if (typeof f === "function" || (f !== null && typeof f === "object")) {
            if (!s.h.hasOwnProperty(n) || s.h[n] === null) {
              var list = s.l[n] || (s.l[n] = []);
              var has = false;
              for (var i = 0; i < list.length; i++) if (list[i].handler) has = true;
              if (!has) list.push({ handler: true, capture: false });
            }
            s.h[n] = f;
          } else {
            s.h[n] = null;
          }
        },
        enumerable: true, configurable: true
      });
    });
  }

  function pathOf(o) {
    var out = [];
    while (o) { out.push(o); o = states.get(o).parent; }
    return out;
  }

  var flagsOf = new WeakMap();
  function setEv(ev, props) {
    for (var k in props) Object.defineProperty(ev, k, { value: props[k], configurable: true, writable: true, enumerable: true });
  }
  function mkEvent(type, bubbles, cancelable) {
    var ev = new g.Event(type, { bubbles: bubbles, cancelable: cancelable });
    var f = { stop: false, stopImm: false };
    flagsOf.set(ev, f);
    hide(ev, "stopPropagation", function () { f.stop = true; });
    hide(ev, "stopImmediatePropagation", function () { f.stop = true; f.stopImm = true; });
    return ev;
  }
  function flagsFor(ev) {
    var f = flagsOf.get(ev);
    if (!f) {
      f = { stop: false, stopImm: false };
      flagsOf.set(ev, f);
      var sp = ev.stopPropagation, si = ev.stopImmediatePropagation;
      hide(ev, "stopPropagation", function () { f.stop = true; if (sp) sp.call(ev); });
      hide(ev, "stopImmediatePropagation", function () { f.stop = true; f.stopImm = true; if (si) si.call(ev); });
    }
    return f;
  }

  // runs the listeners of `t` for the phase; true if one of them threw
  function run(t, ev, phase, flags) {
    var s = states.get(t);
    var list = s.l[ev.type];
    if (!list) return false;
    var threw = false;
    list = list.slice();
    for (var i = 0; i < list.length; i++) {
      if (flags.stopImm) break;
      var l = list[i];
      if (phase === "capture" && !l.capture) continue;
      if (phase === "bubble" && l.capture) continue;
      var cb = l.cb;
      if (l.handler) cb = s.h[ev.type];
      else if (l.once) {
        var cur = s.l[ev.type];
        var at = cur.indexOf(l);
        if (at >= 0) cur.splice(at, 1);
      }
      if (cb === null || cb === undefined) continue;
      try {
        if (typeof cb === "function") cb.call(t, ev);
        else {
          var he = cb.handleEvent;
          if (typeof he !== "function") throw new TypeError("The event listener's handleEvent is not callable.");
          he.call(cb, ev);
        }
      } catch (e) {
        threw = true;
        reportLater(e);
      }
    }
    return threw;
  }

  // the capture phase down to the target, the target, then the bubbling phase; { threw } tells
  // whether a listener threw (the specification aborts the transaction then)
  function dispatch(ev, path) {
    var flags = flagsFor(ev);
    var threw = false;
    setEv(ev, { target: path[0], srcElement: path[0] });
    for (var i = path.length - 1; i > 0 && !flags.stop; i--) {
      setEv(ev, { eventPhase: 1, currentTarget: path[i] });
      if (run(path[i], ev, "capture", flags)) threw = true;
    }
    if (!flags.stop) {
      setEv(ev, { eventPhase: 2, currentTarget: path[0] });
      if (run(path[0], ev, "both", flags)) threw = true;
    }
    if (ev.bubbles) {
      for (var j = 1; j < path.length && !flags.stop; j++) {
        setEv(ev, { eventPhase: 3, currentTarget: path[j] });
        if (run(path[j], ev, "bubble", flags)) threw = true;
      }
    }
    setEv(ev, { eventPhase: 0, currentTarget: null });
    return { threw: threw };
  }

  var VCE = (function () {
    var C = class IDBVersionChangeEvent extends g.Event {
      constructor(type, init) {
        super(type, init);
        var o = init || {};
        var nv = o.newVersion === undefined || o.newVersion === null ? null : toUInt(o.newVersion, "newVersion");
        var ov = o.oldVersion === undefined ? 0 : toUInt(o.oldVersion, "oldVersion");
        Object.defineProperty(this, "oldVersion", { value: ov, enumerable: true, configurable: true });
        Object.defineProperty(this, "newVersion", { value: nv, enumerable: true, configurable: true });
      }
    };
    tag(C.prototype, "IDBVersionChangeEvent");
    return C;
  })();
  function versionEvent(type, oldV, newV) {
    var ev = new VCE(type, { oldVersion: oldV, newVersion: newV });
    var f = { stop: false, stopImm: false };
    flagsOf.set(ev, f);
    hide(ev, "stopPropagation", function () { f.stop = true; });
    hide(ev, "stopImmediatePropagation", function () { f.stop = true; f.stopImm = true; });
    return ev;
  }

  // ── structured clone ──────────────────────────────────────

  function bytesOf(v) {
    return v instanceof ArrayBuffer ? new Uint8Array(v) : new Uint8Array(v.buffer, v.byteOffset, v.byteLength);
  }
  function hexOf(v) {
    return bytesOf(v).toHex();
  }
  function bufOf(hex) {
    return g.__idb_unhex(hex);
  }

  var TYPED = ["Int8Array", "Uint8Array", "Uint8ClampedArray", "Int16Array", "Uint16Array", "Int32Array", "Uint32Array",
    "Float32Array", "Float64Array", "BigInt64Array", "BigUint64Array"];
  var ERRORS = ["Error", "EvalError", "RangeError", "ReferenceError", "SyntaxError", "TypeError", "URIError"];
  function cloneError(what) { return err("DataCloneError", what + " could not be cloned."); }

  function enc(root) {
    var seen = new Map();
    var n = 0;
    function walk(v) {
      switch (typeof v) {
        case "undefined": return { "$": "u" };
        case "boolean": case "string": return v;
        case "number":
          if (v !== v) return { "$": "n", v: "NaN" };
          if (v === Infinity) return { "$": "n", v: "Inf" };
          if (v === -Infinity) return { "$": "n", v: "-Inf" };
          if (v === 0 && 1 / v < 0) return { "$": "n", v: "-0" };
          return v;
        case "bigint": return { "$": "i", v: String(v) };
        case "symbol": throw cloneError("Symbol(" + (v.description || "") + ")");
        case "function": throw cloneError(String(v).slice(0, 40));
      }
      if (v === null) return null;
      if (seen.has(v)) return { "$": "ref", i: seen.get(v) };
      seen.set(v, n++);
      var i;
      if (Array.isArray(v)) {
        var out = [];
        for (i = 0; i < v.length; i++) out.push(i in v ? walk(v[i]) : { "$": "h" });
        return out;
      }
      if (v instanceof Date) { var t = v.getTime(); return { "$": "d", v: t !== t ? "NaN" : t }; }
      if (v instanceof RegExp) return { "$": "r", s: v.source, f: v.flags };
      if (v instanceof ArrayBuffer) return { "$": "ab", v: hexOf(v) };
      if (ArrayBuffer.isView(v)) {
        var kind = "DataView";
        if (!(v instanceof DataView)) {
          kind = null;
          for (i = 0; i < TYPED.length; i++) if (g[TYPED[i]] && v instanceof g[TYPED[i]]) { kind = TYPED[i]; break; }
          if (!kind) throw cloneError("The object");
        }
        return { "$": "ta", t: kind, b: walk(v.buffer), o: v.byteOffset, l: kind === "DataView" ? v.byteLength : v.length };
      }
      if (v instanceof Map) {
        var m = [];
        v.forEach(function (val, key) { m.push([walk(key), walk(val)]); });
        return { "$": "m", v: m };
      }
      if (v instanceof Set) {
        var st = [];
        v.forEach(function (val) { st.push(walk(val)); });
        return { "$": "s", v: st };
      }
      if (v instanceof Error) {
        var name = ERRORS.indexOf(v.name) >= 0 ? v.name : "Error";
        return { "$": "e", n: name, m: v.message === undefined ? undefined : String(v.message) };
      }
      if (Object.prototype.toString.call(v) === "[object BigInt]") return { "$": "w", t: "i", v: String(v.valueOf()) };
      if (g.Blob && v instanceof g.Blob)
        return { "$": "bl", t: v._text, y: v.type, f: g.File && v instanceof g.File ? [v.name, v.lastModified] : null };
      if (v instanceof Boolean) return { "$": "w", t: "b", v: v.valueOf() };
      if (v instanceof Number) return { "$": "w", t: "n", v: walk(v.valueOf()) };
      if (v instanceof String) return { "$": "w", t: "s", v: v.valueOf() };
      if (v === g || (g.Node && v instanceof g.Node) || (g.Promise && v instanceof g.Promise) || (g.WeakMap && v instanceof g.WeakMap) ||
          (g.WeakSet && v instanceof g.WeakSet) || (g.WeakRef && v instanceof g.WeakRef) || states.has(v))
        throw cloneError("#<" + (v.constructor && v.constructor.name || "Object") + ">");
      var o = {}, keys = Object.keys(v);
      for (i = 0; i < keys.length; i++) put(o, keys[i], walk(v[keys[i]]));
      return { "$": "o", v: o };
    }
    return walk(root);
  }

  function dec(root) {
    var objs = [];
    function node(x) {
      if (x === null || typeof x !== "object") return x;
      var i;
      if (Array.isArray(x)) {
        var a = [];
        objs.push(a);
        for (i = 0; i < x.length; i++) {
          var e = x[i];
          if (e !== null && typeof e === "object" && e["$"] === "h") a.length = i + 1;
          else a[i] = node(e);
        }
        a.length = x.length;
        return a;
      }
      switch (x["$"]) {
        case "u": return undefined;
        case "n": return x.v === "NaN" ? NaN : x.v === "Inf" ? Infinity : x.v === "-Inf" ? -Infinity : -0;
        case "i": return g.BigInt(x.v);
        case "ref": return objs[x.i];
        case "d": { var d = new Date(x.v === "NaN" ? NaN : x.v); objs.push(d); return d; }
        case "r": { var r = new RegExp(x.s, x.f); objs.push(r); return r; }
        case "ab": { var b = bufOf(x.v); objs.push(b); return b; }
        case "ta": {
          var slot = objs.length;
          objs.push(null);
          var buf = node(x.b);
          var view = x.t === "DataView" ? new DataView(buf, x.o, x.l) : new g[x.t](buf, x.o, x.l);
          objs[slot] = view;
          return view;
        }
        case "m": {
          var m = new Map();
          objs.push(m);
          for (i = 0; i < x.v.length; i++) { var k = node(x.v[i][0]); m.set(k, node(x.v[i][1])); }
          return m;
        }
        case "s": {
          var s = new Set();
          objs.push(s);
          for (i = 0; i < x.v.length; i++) s.add(node(x.v[i]));
          return s;
        }
        case "e": {
          var C = g[x.n] || Error;
          var er = x.m === undefined ? new C() : new C(x.m);
          objs.push(er);
          return er;
        }
        case "bl": {
          var bl = x.f ? new g.File([x.t], x.f[0], { type: x.y }) : new g.Blob([x.t], { type: x.y });
          if (x.f) bl.lastModified = x.f[1];
          objs.push(bl);
          return bl;
        }
        case "w": {
          if (x.t === "i") { var bw = Object(g.BigInt(x.v)); objs.push(bw); return bw; }
          var w = x.t === "b" ? new Boolean(x.v) : x.t === "s" ? new String(x.v) : new Number(0);
          objs.push(w);
          if (x.t === "n") w = new Number(node(x.v));
          return w;
        }
        default: {
          var o = {};
          objs.push(o);
          for (var key in x.v) Object.defineProperty(o, key, { value: node(x.v[key]), writable: true, enumerable: true, configurable: true });
          return o;
        }
      }
    }
    return node(root);
  }

  function clone(v) { return dec(enc(v)); }
  // `structuredClone` of the web API prelude calls this one
  hide(g, "__structuredClone", function (v) { return clone(v); });

  // ── keys ──────────────────────────────────────────────────

  function isBin(v) { return v instanceof ArrayBuffer || ArrayBuffer.isView(v); }
  // the normal form of a key, or undefined if `v` is not a key
  function toKey(v, seen) {
    var t = typeof v;
    if (t === "number") return v !== v ? undefined : v;
    if (t === "string") return v;
    if (t !== "object" || v === null) return undefined;
    if (v instanceof Date) { var ms = v.getTime(); return ms !== ms ? undefined : { t: "d", v: ms }; }
    if (isBin(v)) return { t: "b", v: hexOf(v) };
    if (Array.isArray(v)) {
      seen = seen || [];
      if (seen.indexOf(v) >= 0) return undefined;
      seen.push(v);
      var out = [];
      for (var i = 0; i < v.length; i++) {
        if (!(i in v)) { seen.pop(); return undefined; }
        var k = toKey(v[i], seen);
        if (k === undefined) { seen.pop(); return undefined; }
        out.push(k);
      }
      seen.pop();
      return out;
    }
    return undefined;
  }
  function needKey(v) {
    var k = toKey(v);
    if (k === undefined) throw err("DataError", "The parameter is not a valid key.");
    return k;
  }
  function rank(k) { return typeof k === "number" ? 1 : typeof k === "string" ? 3 : Array.isArray(k) ? 5 : k.t === "d" ? 2 : 4; }
  function cmp(a, b) {
    var ra = rank(a), rb = rank(b);
    if (ra !== rb) return ra < rb ? -1 : 1;
    switch (ra) {
      case 1: case 3: return a < b ? -1 : a > b ? 1 : 0;
      case 2: case 4: a = a.v; b = b.v; return a < b ? -1 : a > b ? 1 : 0;
      default:
        var n = Math.min(a.length, b.length);
        for (var i = 0; i < n; i++) { var c = cmp(a[i], b[i]); if (c) return c; }
        return a.length < b.length ? -1 : a.length > b.length ? 1 : 0;
    }
  }
  function fromKey(k) {
    if (typeof k === "number" || typeof k === "string") return k;
    if (Array.isArray(k)) return k.map(fromKey);
    if (k.t === "d") return new Date(k.v);
    return bufOf(k.v);
  }
  function keyJSON(k) {
    if (typeof k === "number") return k === Infinity ? { "$": "I" } : k === -Infinity ? { "$": "-I" } : k;
    if (typeof k === "string") return k;
    if (Array.isArray(k)) return k.map(keyJSON);
    return { "$": k.t, v: k.v };
  }
  function keyFromJSON(j) {
    if (typeof j === "number" || typeof j === "string") return j;
    if (Array.isArray(j)) return j.map(keyFromJSON);
    if (j["$"] === "I") return Infinity;
    if (j["$"] === "-I") return -Infinity;
    return { t: j["$"], v: j.v };
  }

  // key paths
  var PATH = /^[\p{L}\p{Nl}_$][\p{L}\p{Nl}\p{Mn}\p{Mc}\p{Nd}\p{Pc}$\u200c\u200d]*(\.[\p{L}\p{Nl}_$][\p{L}\p{Nl}\p{Mn}\p{Mc}\p{Nd}\p{Pc}$\u200c\u200d]*)*$/u;
  function validPath(p) {
    if (typeof p === "string") return p === "" || PATH.test(p);
    if (Array.isArray(p)) {
      if (p.length === 0) return false;
      for (var i = 0; i < p.length; i++) if (typeof p[i] !== "string" || (p[i] !== "" && !PATH.test(p[i]))) return false;
      return true;
    }
    return false;
  }
  function normPath(p) {
    if (p === undefined || p === null) return null;
    if (typeof p !== "string" && !Array.isArray(p) && typeof p === "object" && p !== null && typeof p[Symbol.iterator] === "function") p = Array.from(p);
    if (typeof p !== "string" && !Array.isArray(p)) p = String(p);
    if (Array.isArray(p)) p = Array.prototype.map.call(p, String);
    if (!validPath(p)) throw err("SyntaxError", "The keyPath argument contains an invalid key path.");
    return Array.isArray(p) ? p.slice() : p;
  }
  function evalPath(v, path) {
    if (path === "") return v;
    var parts = path.split("."), cur = v;
    for (var i = 0; i < parts.length; i++) {
      var p = parts[i];
      if (typeof cur === "string" && p === "length") cur = cur.length;
      else if (Array.isArray(cur) && p === "length") cur = cur.length;
      else if (cur === null || (typeof cur !== "object" && typeof cur !== "function")) return undefined;
      else if (!hasOwn.call(cur, p)) {
        if ((cur instanceof g.Blob || cur instanceof g.File) && (p === "size" || p === "type" || p === "name" || p === "lastModified") && p in cur) cur = cur[p];
        else return undefined;
      } else cur = cur[p];
    }
    return cur;
  }
  var NOKEY = { none: true }, INVALID = { invalid: true };
  // the key of a value for a store's key path: a key, NOKEY (the value has none) or INVALID
  function extractKey(v, kp) {
    var i, k;
    if (Array.isArray(kp)) {
      var out = [];
      for (i = 0; i < kp.length; i++) {
        k = toKey(evalPath(v, kp[i]));
        if (k === undefined) return INVALID;
        out.push(k);
      }
      return out;
    }
    var x = evalPath(v, kp);
    if (x === undefined) return NOKEY;
    k = toKey(x);
    return k === undefined ? INVALID : k;
  }
  function canInject(v, kp) {
    var parts = kp.split("."), cur = v;
    if (cur === null || typeof cur !== "object") return false;
    for (var i = 0; i < parts.length - 1; i++) {
      if (!hasOwn.call(cur, parts[i])) return true;
      cur = cur[parts[i]];
      if (cur === null || typeof cur !== "object") return false;
    }
    return true;
  }
  // an own property, whatever the prototypes have for the name
  function put(o, k, v) { Object.defineProperty(o, k, { value: v, writable: true, enumerable: true, configurable: true }); }
  function inject(v, kp, key) {
    var parts = kp.split("."), cur = v;
    for (var i = 0; i < parts.length - 1; i++) {
      if (!hasOwn.call(cur, parts[i])) put(cur, parts[i], {});
      cur = cur[parts[i]];
    }
    put(cur, parts[parts.length - 1], fromKey(key));
  }

  // ── key ranges ────────────────────────────────────────────

  function IDBKeyRange() { illegal(); }
  var KRP = IDBKeyRange.prototype;
  tag(KRP, "IDBKeyRange");
  function makeRange(lower, upper, lo, uo, hasL, hasU) {
    return make(KRP, { lower: lower, upper: upper, lowerOpen: lo, upperOpen: uo, hasLower: hasL, hasUpper: hasU });
  }
  hide(IDBKeyRange, "only", function only(v) { need1(arguments); var k = needKey(v); return makeRange(k, k, false, false, true, true); });
  hide(IDBKeyRange, "lowerBound", function lowerBound(v, open) { need1(arguments); return makeRange(needKey(v), undefined, !!open, true, true, false); });
  hide(IDBKeyRange, "upperBound", function upperBound(v, open) { need1(arguments); return makeRange(undefined, needKey(v), true, !!open, false, true); });
  hide(IDBKeyRange, "bound", function bound(l, u, lo, uo) {
    if (arguments.length < 2) throw new TypeError("2 arguments required, but only " + arguments.length + " present.");
    var a = needKey(l), b = needKey(u), c = cmp(a, b);
    if (c > 0 || (c === 0 && (lo || uo))) throw err("DataError", "The lower key is greater than the upper key.");
    return makeRange(a, b, !!lo, !!uo, true, true);
  });
  getter(KRP, "lower", function () { var s = S(this); return s.hasLower ? fromKey(s.lower) : undefined; });
  getter(KRP, "upper", function () { var s = S(this); return s.hasUpper ? fromKey(s.upper) : undefined; });
  getter(KRP, "lowerOpen", function () { return S(this).lowerOpen; });
  getter(KRP, "upperOpen", function () { return S(this).upperOpen; });
  hide(KRP, "includes", function includes(v) { need1(arguments); return inRange(S(this), needKey(v)); });

  function inRange(r, k) {
    if (!r) return true;
    var c;
    if (r.hasLower) { c = cmp(k, r.lower); if (c < 0 || (c === 0 && r.lowerOpen)) return false; }
    if (r.hasUpper) { c = cmp(k, r.upper); if (c > 0 || (c === 0 && r.upperOpen)) return false; }
    return true;
  }
  // the range a method argument means: null for "everything"
  function toRange(q, required) {
    if (q === undefined || q === null) {
      if (required) throw err("DataError", "A key or key range is required.");
      return null;
    }
    if (q instanceof IDBKeyRange) return S(q);
    var k = needKey(q);
    return { lower: k, upper: k, lowerOpen: false, upperOpen: false, hasLower: true, hasUpper: true };
  }

  // ── the data of a database ────────────────────────────────

  function newDb(name) { return { name: name, version: 0, stores: new Map() }; }
  function newStore(name, keyPath, auto) { return { name: name, keyPath: keyPath, auto: auto, nextKey: 1, records: [], indexes: new Map() }; }
  function newIndex(name, keyPath, unique, multi) { return { name: name, keyPath: keyPath, unique: unique, multi: multi, entries: [] }; }
  function sortedNames(map) { return Array.from(map.keys()).sort(); }

  // records are { k, pk: k, v } (v is the encoded value), index entries { k, pk }; both sorted by (k, pk)
  function entCmp(e, k, pk) {
    var c = cmp(e.k, k);
    if (c || pk === undefined) return c;
    return cmp(e.pk, pk);
  }
  // the first position whose entry is >= (k, pk); with no pk, that is the first with a key >= k
  function LB(list, k, pk) {
    var lo = 0, hi = list.length;
    while (lo < hi) { var m = (lo + hi) >> 1; if (entCmp(list[m], k, pk) < 0) lo = m + 1; else hi = m; }
    return lo;
  }
  // the first position whose entry is > (k, pk); with no pk, the first with a key > k
  function UB(list, k, pk) {
    var lo = 0, hi = list.length;
    while (lo < hi) { var m = (lo + hi) >> 1; if (entCmp(list[m], k, pk) <= 0) lo = m + 1; else hi = m; }
    return lo;
  }
  function findRec(store, k) {
    var i = LB(store.records, k);
    return i < store.records.length && cmp(store.records[i].k, k) === 0 ? i : -1;
  }

  function indexKeys(ix, value) {
    var kp = ix.keyPath, r, i;
    if (Array.isArray(kp)) {
      r = extractKey(value, kp);
      return r === INVALID ? [] : [r];
    }
    var x = evalPath(value, kp);
    if (x === undefined) return [];
    if (ix.multi && Array.isArray(x)) {
      var out = [];
      for (i = 0; i < x.length; i++) {
        var k = toKey(x[i]);
        if (k === undefined) continue;
        var dup = false;
        for (var j = 0; j < out.length; j++) if (cmp(out[j], k) === 0) { dup = true; break; }
        if (!dup) out.push(k);
      }
      return out;
    }
    r = toKey(x);
    return r === undefined ? [] : [r];
  }
  // the indexes a write to the store has to keep up to date: not one that is still being built,
  // but also one that was deleted by a request that has not run yet
  function eachIndex(st, fn) {
    st.indexes.forEach(function (ix) { if (!ix.pending) fn(ix); });
    if (st.dying) st.dying.forEach(fn);
  }
  function allIndexes(st, fn) {
    st.indexes.forEach(fn);
    if (st.dying) st.dying.forEach(fn);
  }
  function idxAdd(ix, pk, keys) {
    ix.dirty = true;
    for (var i = 0; i < keys.length; i++) ix.entries.splice(LB(ix.entries, keys[i], pk), 0, { k: keys[i], pk: pk });
  }
  function idxRemove(ix, pk, keys) {
    ix.dirty = true;
    for (var i = 0; i < keys.length; i++) {
      var at = LB(ix.entries, keys[i], pk);
      if (at < ix.entries.length && cmp(ix.entries[at].k, keys[i]) === 0 && cmp(ix.entries[at].pk, pk) === 0) ix.entries.splice(at, 1);
    }
  }
  function idxConflict(ix, pk, keys) {
    for (var i = 0; i < keys.length; i++) {
      var at = LB(ix.entries, keys[i]);
      while (at < ix.entries.length && cmp(ix.entries[at].k, keys[i]) === 0) {
        if (cmp(ix.entries[at].pk, pk) !== 0) return true;
        at++;
      }
    }
    return false;
  }

  function parseDb(name, text) {
    var j = JSON.parse(text);
    var db = newDb(name);
    db.version = j.v;
    j.s.forEach(function (sj) {
      var st = newStore(sj.n, sj.k, sj.a);
      st.nextKey = sj.g === "inf" ? Infinity : sj.g;
      st.records = sj.r.map(function (r) { var k = keyFromJSON(r[0]); return { k: k, pk: k, v: r[1] }; });
      sj.i.forEach(function (ij) {
        var ix = newIndex(ij.n, ij.k, ij.u, ij.m);
        ix.entries = ij.e.map(function (e) { return { k: keyFromJSON(e[0]), pk: keyFromJSON(e[1]) }; });
        st.indexes.set(ix.name, ix);
      });
      db.stores.set(st.name, st);
    });
    return db;
  }

  // the databases of this page, by name: { rev, data }
  var cache = {};
  // the stored database (read again if another page changed it), or null if there is none
  function freshData(name) {
    var c = cache[name];
    var r = g.__idb_load(name, c ? c.rev : undefined);
    if (r === undefined) { delete cache[name]; return null; }
    if (r === true && c) return c.data;
    var data = parseDb(name, r[2]);
    cache[name] = { rev: r[0], data: data };
    return data;
  }
  // writes what the transaction changed: the schema, the operations on records it made, and the
  // entries of the indexes it touched
  function persist(name, data, ops) {
    var stores = [];
    data.stores.forEach(function (st) {
      var ixs = [];
      st.indexes.forEach(function (ix) {
        ixs.push([ix.name, JSON.stringify({ n: ix.name, k: ix.keyPath, u: ix.unique, m: ix.multi })]);
        if (ix.dirty) {
          ix.dirty = false;
          ops.push(["e", st.name, ix.name, JSON.stringify(ix.entries.map(function (e) { return [keyJSON(e.k), keyJSON(e.pk)]; }))]);
        }
      });
      stores.push([st.name, JSON.stringify({ n: st.name, k: st.keyPath, a: st.auto, g: st.nextKey === Infinity ? "inf" : st.nextKey }), ixs]);
    });
    var rev = g.__idb_save(name, data.version, stores, ops);
    if (rev < 0) return false;
    cache[name] = { rev: rev, data: data };
    return true;
  }
  function clearDirty(data) {
    data.stores.forEach(function (st) { st.indexes.forEach(function (ix) { ix.dirty = false; }); });
  }

  // ── requests ──────────────────────────────────────────────

  function IDBRequest() { illegal(); }
  var RP = IDBRequest.prototype = Object.create(ETP);
  hide(RP, "constructor", IDBRequest);
  tag(RP, "IDBRequest");
  handlers(RP, ["success", "error"]);
  getter(RP, "result", function () {
    var s = S(this);
    if (!s.done) throw err("InvalidStateError", "The request has not finished.");
    return s.result;
  });
  getter(RP, "error", function () {
    var s = S(this);
    if (!s.done) throw err("InvalidStateError", "The request has not finished.");
    return s.error;
  });
  getter(RP, "source", function () { var s = S(this); return s.source === undefined ? null : s.source; });
  getter(RP, "transaction", function () { var s = S(this); return s.transaction === undefined ? null : s.transaction; });
  getter(RP, "readyState", function () { return S(this).done ? "done" : "pending"; });

  function IDBOpenDBRequest() { illegal(); }
  var ORP = IDBOpenDBRequest.prototype = Object.create(RP);
  hide(ORP, "constructor", IDBOpenDBRequest);
  tag(ORP, "IDBOpenDBRequest");
  handlers(ORP, ["blocked", "upgradeneeded"]);

  function makeRequest(source, tx, proto) {
    return make(proto || RP, newState({ done: false, result: undefined, error: null, source: source, transaction: tx, parent: tx, op: null }));
  }

  // ── transactions ──────────────────────────────────────────

  function IDBTransaction() { illegal(); }
  var TP = IDBTransaction.prototype = Object.create(ETP);
  hide(TP, "constructor", IDBTransaction);
  tag(TP, "IDBTransaction");
  handlers(TP, ["abort", "complete", "error"]);

  var runners = {};
  function runner(name) { return runners[name] || (runners[name] = { cur: null, waiting: [] }); }

  function makeTx(conn, names, mode, upgrade) {
    var cs = S(conn);
    var tx = make(TP, newState({
      conn: conn, name: cs.name, mode: mode, names: names, active: true, finished: false, aborted: false, queue: [],
      undo: new Map(), ops: [], schemaUndo: null, dirty: false, error: null, wrappers: new Map(), data: null, ready: false,
      onfinish: null, parent: conn, committing: false
    }));
    var s = S(tx);
    cs.txs.push(tx);
    if (upgrade) {
      s.ready = true;
      runner(cs.name).cur = tx;
    } else {
      runner(cs.name).waiting.push(tx);
      task(function () {
        s.active = false;
        s.ready = true;
        drain(cs.name);
      });
    }
    return tx;
  }

  function drain(name) {
    var r = runner(name);
    while (!r.cur && r.waiting.length && S(r.waiting[0]).ready) {
      var tx = r.waiting.shift();
      r.cur = tx;
      startTx(tx);
    }
  }
  function startTx(tx) {
    var s = S(tx);
    s.data = freshData(s.name);
    task(function () { runNext(tx); });
  }

  // The transaction is active while its callbacks run, with the promise jobs they start. A task
  // that is queued before the callbacks run (so also before the timers they set) makes it inactive.
  function deactivateLater(tx) {
    task(function () {
      var s = S(tx);
      s.active = false;
      // nothing is left to run: the transaction is committing, and can not be aborted any more
      if (!s.finished && s.queue.length === 0) s.committing = true;
    });
  }

  function runNext(tx) {
    var s = S(tx);
    if (s.finished) return;
    s.active = false;
    var req = s.queue.shift();
    if (!req) { commit(tx); return; }
    var rs = S(req);
    if (rs.silent) {
      try {
        rs.op();
      } catch (e) {
        if (e instanceof DOMEx) { abortTx(tx, e); return; }
        abortTx(tx, err("UnknownError", String(e)));
        throw e;
      }
      task(function () { runNext(tx); });
      return;
    }
    s.active = true;
    deactivateLater(tx);
    var error = null, result;
    try {
      result = rs.op();
    } catch (e) {
      if (e instanceof DOMEx) error = e;
      else { abortTx(tx, err("UnknownError", String(e))); throw e; }
    }
    rs.done = true;
    var ev, res;
    if (error) {
      rs.error = error;
      rs.result = undefined;
      ev = mkEvent("error", true, true);
      res = dispatch(ev, pathOf(req));
      if (!s.finished && (res.threw || !ev.defaultPrevented)) abortTx(tx, res.threw ? err("AbortError") : error);
    } else {
      rs.result = result;
      rs.error = null;
      ev = mkEvent("success", false, false);
      res = dispatch(ev, pathOf(req));
      if (res.threw && !s.finished && !s.committing) abortTx(tx, err("AbortError"));
    }
    if (!s.finished) task(function () { runNext(tx); });
  }

  function commit(tx) {
    var s = S(tx);
    s.finished = true;
    if (s.mode === "versionchange") s.names = sortedNames(s.data.stores);
    if (s.dirty && s.mode !== "readonly") {
      if (!persist(s.name, s.data, s.ops)) {
        s.finished = false;
        abortTx(tx, err("QuotaExceededError", "The database is too big."));
        return;
      }
    }
    task(function () {
      s.over = true;
      dispatch(mkEvent("complete", false, false), pathOf(tx));
      finishTx(tx, true);
    });
  }

  function rollback(s) {
    clearDirty(s.data || { stores: new Map() });
    s.undo.forEach(function (u, st) {
      st.records = u.records;
      st.nextKey = u.nextKey;
      u.ix.forEach(function (e) { e.index.entries = e.entries; });
    });
    if (s.schemaUndo) {
      var su = s.schemaUndo, data = s.data;
      data.version = su.version;
      data.stores = su.stores;
      su.indexes.forEach(function (map, st) { st.indexes = map; });
      su.names.forEach(function (n, meta) { meta.name = n; });
      su.created.forEach(function (ix) { ix.deleted = true; });
      su.createdStores.forEach(function (st) { st.deleted = true; st.indexes = new Map(); });
      su.stores.forEach(function (st) { st.deleted = st.gone = false; st.dying = []; st.indexes.forEach(function (ix) { ix.deleted = ix.gone = false; ix.pending = false; }); });
      if (su.isNew) delete cache[s.name];
      clearDirty(data);
    }
  }

  function abortTx(tx, error) {
    var s = S(tx);
    if (s.finished) return;
    s.finished = true;
    s.aborted = true;
    s.active = false;
    s.error = error || null;
    rollback(s);
    if (s.mode === "versionchange") s.names = sortedNames(s.data.stores);
    var pend = s.queue;
    s.queue = [];
    (function next() {
      task(function () {
        var req = pend.shift();
        while (req && S(req).silent) req = pend.shift();
        if (req) {
          var rs = S(req);
          rs.done = true;
          rs.result = undefined;
          rs.error = err("AbortError", "The transaction was aborted.");
          dispatch(mkEvent("error", true, true), pathOf(req));
          next();
        } else {
          s.over = true;
      dispatch(mkEvent("abort", true, false), pathOf(tx));
          finishTx(tx, false);
        }
      });
    })();
  }

  function finishTx(tx, ok) {
    var s = S(tx);
    var cs = S(s.conn);
    var at = cs.txs.indexOf(tx);
    if (at >= 0) cs.txs.splice(at, 1);
    var r = runner(s.name);
    if (r.cur === tx) r.cur = null;
    if (s.onfinish) s.onfinish(ok);
    if (cs.closePending && cs.txs.length === 0) finalClose(s.conn);
    drain(s.name);
  }

  getter(TP, "db", function () { return S(this).conn; });
  getter(TP, "mode", function () { return S(this).mode; });
  getter(TP, "durability", function () { return "default"; });
  getter(TP, "error", function () { return S(this).error; });
  getter(TP, "objectStoreNames", function () {
    var s = S(this);
    return strList(s.mode === "versionchange" && !s.finished ? sortedNames(s.data.stores) : s.names);
  });
  hide(TP, "objectStore", function objectStore(name) {
    var s = S(this);
    name = String(name);
    if (s.finished) throw err("InvalidStateError", "The transaction has finished.");
    var meta = s.mode === "versionchange" ? s.data.stores : S(s.conn).data.stores;
    if ((s.mode !== "versionchange" && s.names.indexOf(name) < 0) || !meta.has(name))
      throw err("NotFoundError", "The object store '" + name + "' is not in the scope of the transaction.");
    return storeWrapper(this, meta.get(name));
  });
  hide(TP, "abort", function abort() {
    var s = S(this);
    if (s.finished || s.committing) throw err("InvalidStateError", "The transaction has " + (s.finished ? "finished" : "started to commit") + ".");
    abortTx(this, null);
  });
  hide(TP, "commit", function commitTx() {
    var s = S(this);
    if (s.finished || !s.active) throw err("InvalidStateError", "The transaction is not active.");
    // nothing more can be added; it commits when the requests so far are done
    s.committing = true;
    s.active = false;
  });

  function DSL() { illegal(); }
  DSL.prototype = Object.create(Array.prototype);
  hide(DSL.prototype, "constructor", DSL);
  tag(DSL.prototype, "DOMStringList");
  hide(DSL.prototype, "contains", function contains(n) { return Array.prototype.indexOf.call(this, String(n)) >= 0; });
  hide(DSL.prototype, "item", function item(i) { var v = this[i >>> 0]; return v === undefined ? null : v; });
  function strList(names) {
    var a = names.slice();
    Object.setPrototypeOf(a, DSL.prototype);
    return a;
  }

  // copy-on-write: the first change of a store in a transaction keeps what it was
  function own(s, st) {
    if (s.undo.has(st)) return;
    var ix = [];
    allIndexes(st, function (index) { ix.push({ index: index, entries: index.entries }); });
    s.undo.set(st, { records: st.records, nextKey: st.nextKey, ix: ix });
    st.records = st.records.slice();
    allIndexes(st, function (index) { index.entries = index.entries.slice(); });
  }
  function snapshotSchema(data, isNew) {
    var indexes = new Map();
    var names = new Map();
    data.stores.forEach(function (st) {
      indexes.set(st, new Map(st.indexes));
      names.set(st, st.name);
      st.indexes.forEach(function (ix) { names.set(ix, ix.name); });
    });
    return { names: names, version: data.version, stores: new Map(data.stores), indexes: indexes, isNew: isNew, created: [], createdStores: [], deleted: [] };
  }

  function enqueue(tx, source, op, existing) {
    var s = S(tx);
    if (s.finished || !s.active || s.committing) throw err("TransactionInactiveError", s.finished ? "The transaction has finished." : "The transaction is not active.");
    var req = existing || makeRequest(source, tx);
    var rs = S(req);
    rs.op = op;
    if (existing) { rs.done = false; rs.result = undefined; rs.error = null; }
    s.queue.push(req);
    return req;
  }

  // a step of a versionchange transaction that is done in the order of the requests, without a
  // request of its own (no events); when it throws, the transaction aborts
  function silent(tx, op) {
    var req = enqueue(tx, null, op);
    S(req).silent = true;
  }

  // ── object stores ─────────────────────────────────────────

  function IDBObjectStore() { illegal(); }
  var OSP = IDBObjectStore.prototype;
  tag(OSP, "IDBObjectStore");

  function storeWrapper(tx, meta) {
    var s = S(tx);
    var w = s.wrappers.get(meta);
    if (!w) {
      w = make(OSP, { tx: tx, meta: meta, ixw: new Map() });
      s.wrappers.set(meta, w);
    }
    return w;
  }

  // The data a request works on when it runs. In a versionchange transaction the metadata the
  // wrappers hold is the live data; otherwise it is looked up again, by name, in the data the
  // transaction loaded.
  function storeFor(ts, meta) {
    if (meta.gone) throw err("InvalidStateError", "The object store has been deleted.");
    if (ts.mode === "versionchange") return meta;
    var st = ts.data.stores.get(meta.name);
    if (!st) throw err("InvalidStateError", "The object store has been deleted.");
    return st;
  }
  function indexFor(ts, smeta, imeta) {
    var st = storeFor(ts, smeta);
    if (imeta.gone) throw err("InvalidStateError", "The index has been deleted.");
    if (ts.mode === "versionchange") return { st: st, ix: imeta };
    var ix = st.indexes.get(imeta.name);
    if (!ix) throw err("InvalidStateError", "The index has been deleted.");
    return { st: st, ix: ix };
  }
  // the list a query looks in, and the store the values are in
  function sourceOf(ts, smeta, imeta) {
    if (!imeta) { var st = storeFor(ts, smeta); return { list: st.records, store: st }; }
    var r = indexFor(ts, smeta, imeta);
    return { list: r.ix.entries, store: r.st };
  }

  // the checks that come first in every method that makes a request: deleted, inactive, read-only
  function pre(tx, smeta, imeta, mutates) {
    if (smeta.deleted) throw err("InvalidStateError", "The object store has been deleted.");
    if (imeta && imeta.deleted) throw err("InvalidStateError", "The index has been deleted.");
    var ts = S(tx);
    if (ts.finished || !ts.active) throw err("TransactionInactiveError", ts.finished ? "The transaction has finished." : "The transaction is not active.");
    if (mutates && ts.mode === "readonly") throw err("ReadOnlyError", "The transaction is read-only.");
    return ts;
  }
  function inVersionChange(w, what) {
    var ts = S(w.tx);
    if (ts.mode !== "versionchange") throw err("InvalidStateError", what + " is only possible in a versionchange transaction.");
    if (w.meta.deleted) throw err("InvalidStateError", "The object store has been deleted.");
    if (ts.finished || !ts.active) throw err("TransactionInactiveError", "The transaction is not active.");
    return ts;
  }

  Object.defineProperty(OSP, "name", {
    get: function () { return S(this).meta.name; },
    set: function (v) {
      var w = S(this);
      v = String(v);
      var ts = inVersionChange(w, "Renaming");
      var data = ts.data;
      if (v === w.meta.name) return;
      if (data.stores.has(v)) throw err("ConstraintError", "An object store with that name already exists.");
      var old = w.meta.name;
      data.stores = new Map(Array.from(data.stores.entries()).map(function (e) { return e[0] === old ? [v, e[1]] : e; }));
      w.meta.name = v;
      ts.dirty = true;
    },
    enumerable: true, configurable: true
  });
  // an array key path is one array for each object that reports it
  function pathOut(w) {
    if (!Array.isArray(w.meta.keyPath)) return w.meta.keyPath;
    return w.kpOut || (w.kpOut = w.meta.keyPath.slice());
  }
  getter(OSP, "keyPath", function () { return pathOut(S(this)); });
  getter(OSP, "indexNames", function () { return strList(sortedNames(S(this).meta.indexes)); });
  getter(OSP, "transaction", function () { return S(this).tx; });
  getter(OSP, "autoIncrement", function () { return S(this).meta.auto; });

  // the value is cloned while the transaction is not active, so that a getter cannot use it
  function cloneInactive(ts, value) {
    var was = ts.active;
    ts.active = false;
    try { return enc(value); } finally { ts.active = was; }
  }

  // checks the arguments of add/put and gets the request going
  function write(self, value, key, noOverwrite, argc) {
    var w = S(self), tx = w.tx, meta = w.meta;
    if (argc === 0) throw new TypeError("1 argument required, but only 0 present.");
    var ts = pre(tx, meta, null, true);
    var k;
    if (meta.keyPath !== null && key !== undefined) throw err("DataError", "The object store uses in-line keys and the key parameter was provided.");
    if (meta.keyPath === null && !meta.auto && key === undefined) throw err("DataError", "The object store uses out-of-line keys and has no key generator and the key parameter was not provided.");
    if (key !== undefined) k = needKey(key);
    var encoded = cloneInactive(ts, value), cloned = null, generate = false;
    if (meta.keyPath !== null) {
      cloned = dec(encoded);
      var r = extractKey(cloned, meta.keyPath);
      if (r === INVALID) throw err("DataError", "The key path yielded an invalid key.");
      if (r === NOKEY) {
        if (!meta.auto) throw err("DataError", "The key path did not yield a value.");
        if (!canInject(cloned, meta.keyPath)) throw err("DataError", "A key could not be injected into the value.");
        generate = true;
      } else k = r;
    } else if (k === undefined) generate = true;
    return enqueue(tx, self, function () {
      return putRecord(ts, storeFor(ts, meta), k, encoded, cloned, generate, noOverwrite);
    });
  }
  // the work of add/put (and of cursor.update): returns the key
  function putRecord(ts, st, k, encoded, cloned, generate, noOverwrite) {
    if (generate) {
      if (!(st.nextKey <= 9007199254740992)) throw err("ConstraintError", "The key generator has reached its limit.");
      k = st.nextKey;
      if (st.keyPath !== null) {
        cloned = cloned || dec(encoded);
        inject(cloned, st.keyPath, k);
        encoded = enc(cloned);
      }
    }
    var at = LB(st.records, k);
    var exists = at < st.records.length && cmp(st.records[at].k, k) === 0;
    if (exists && noOverwrite) throw err("ConstraintError", "A record with the key already exists.");
    var value = null;
    function valueOf() { return value || (value = cloned || dec(encoded)); }
    var newKeys = [];
    eachIndex(st, function (ix) { newKeys.push([ix, indexKeys(ix, valueOf())]); });
    for (var i = 0; i < newKeys.length; i++)
      if (newKeys[i][0].unique && idxConflict(newKeys[i][0], k, newKeys[i][1])) throw err("ConstraintError", "A unique index would have two records with the same key.");
    own(ts, st);
    if (exists) {
      if (newKeys.length) {
        var old = dec(st.records[at].v);
        for (var j = 0; j < newKeys.length; j++) idxRemove(newKeys[j][0], k, indexKeys(newKeys[j][0], old));
      }
      st.records[at] = { k: k, pk: k, v: encoded };
    } else {
      st.records.splice(at, 0, { k: k, pk: k, v: encoded });
    }
    ts.ops.push(["p", st.name, JSON.stringify(keyJSON(k)), JSON.stringify(encoded)]);
    for (var m = 0; m < newKeys.length; m++) idxAdd(newKeys[m][0], k, newKeys[m][1]);
    if (typeof k === "number" && k >= st.nextKey) st.nextKey = k >= 9007199254740992 ? Infinity : Math.floor(k) + 1;
    ts.dirty = true;
    return fromKey(k);
  }
  hide(OSP, "add", function add(value, key) { return write(this, value, key, true, arguments.length); });
  hide(OSP, "put", function put(value, key) { return write(this, value, key, false, arguments.length); });

  function removeRange(ts, st, range) {
    var from = range && range.hasLower ? (range.lowerOpen ? UB(st.records, range.lower) : LB(st.records, range.lower)) : 0;
    var to = range && range.hasUpper ? (range.upperOpen ? LB(st.records, range.upper) : UB(st.records, range.upper)) : st.records.length;
    if (to <= from) return;
    own(ts, st);
    var gone = st.records.splice(from, to - from);
    gone.forEach(function (rec) { ts.ops.push(["d", st.name, JSON.stringify(keyJSON(rec.k))]); });
    gone.forEach(function (rec) {
      var v = null;
      eachIndex(st, function (ix) {
        v = v || dec(rec.v);
        idxRemove(ix, rec.k, indexKeys(ix, v));
      });
    });
    ts.dirty = true;
  }

  hide(OSP, "delete", function (query) {
    if (arguments.length === 0) throw new TypeError("1 argument required, but only 0 present.");
    var w = S(this), meta = w.meta, ts = pre(w.tx, meta, null, true);
    var range = toRange(query, true);
    return enqueue(w.tx, this, function () {
      removeRange(ts, storeFor(ts, meta), range);
      return undefined;
    });
  });
  hide(OSP, "clear", function clear() {
    var w = S(this), meta = w.meta, ts = pre(w.tx, meta, null, true);
    return enqueue(w.tx, this, function () {
      var st = storeFor(ts, meta);
      if (st.records.length) {
        own(ts, st);
        st.records = [];
        ts.ops.push(["c", st.name]);
        eachIndex(st, function (ix) { ix.entries = []; ix.dirty = true; });
        ts.dirty = true;
      }
      return undefined;
    });
  });

  // reading: `list` is the records of a store or the entries of an index
  var CURSOR_DIRS = { next: 1, nextunique: 1, prev: 1, prevunique: 1 };
  function direction(d) {
    d = d === undefined ? "next" : String(d);
    if (!CURSOR_DIRS[d]) throw new TypeError("The provided value '" + d + "' is not a valid enum value of type IDBCursorDirection.");
    return d;
  }
  function countArg(c) {
    if (c === undefined) return 0;
    var n = Number(c);
    if (n !== n || n === Infinity || n === -Infinity) throw new TypeError("The count is not a finite number.");
    n = n < 0 ? Math.ceil(n) : Math.floor(n);
    if (n < 0 || n > 4294967295) throw new TypeError("The count is out of range.");
    return n;
  }
  // the arguments of getAll and the like: (query, count) or ({ query, count, direction })
  function getAllArgs(q, count) {
    if (q !== null && typeof q === "object" && !(q instanceof IDBKeyRange) && toKey(q) === undefined) {
      var dir = q.direction;
      return { range: toRange(q.query, false), count: countArg(q.count), dir: direction(dir) };
    }
    return { range: toRange(q, false), count: countArg(count), dir: "next" };
  }
  function firstIn(list, range) {
    var at = range && range.hasLower ? (range.lowerOpen ? UB(list, range.lower) : LB(list, range.lower)) : 0;
    return at < list.length && inRange(range, list[at].k) ? list[at] : null;
  }
  // the entries in the range, in the order of `dir`, at most `count` (0 is all of them)
  function entriesIn(list, range, dir, count) {
    var out = [];
    var cur = null;
    while (!count || out.length < count) {
      var e = seek(list, range, dir, cur);
      if (!e) break;
      out.push(e);
      cur = e;
    }
    return out;
  }
  function countIn(list, range) {
    var from = range && range.hasLower ? (range.lowerOpen ? UB(list, range.lower) : LB(list, range.lower)) : 0;
    var to = range && range.hasUpper ? (range.upperOpen ? LB(list, range.upper) : UB(list, range.upper)) : list.length;
    return Math.max(0, to - from);
  }
  function valueOfEntry(store, e) {
    return dec(store.records[LB(store.records, e.pk)].v);
  }

  function IDBRecord() { illegal(); }
  var RECP = IDBRecord.prototype;
  tag(RECP, "IDBRecord");
  getter(RECP, "key", function () { return S(this).key; });
  getter(RECP, "primaryKey", function () { return S(this).primaryKey; });
  getter(RECP, "value", function () { return S(this).value; });

  // the query methods of a store (`imeta` is null) or an index
  function queries(self, tx, smeta, imeta) {
    var isIndex = !!imeta;
    return {
      get: function (query, kind) {
        var ts = pre(tx, smeta, imeta, false), range = toRange(query, true);
        return enqueue(tx, self, function () {
          var src = sourceOf(ts, smeta, imeta);
          var e = firstIn(src.list, range);
          if (!e) return undefined;
          return kind === "value" ? valueOfEntry(src.store, e) : fromKey(e.pk);
        });
      },
      getAll: function (query, count, kind, records) {
        var ts = pre(tx, smeta, imeta, false);
        var a = getAllArgs(query, count);
        return enqueue(tx, self, function () {
          var src = sourceOf(ts, smeta, imeta);
          return entriesIn(src.list, a.range, a.dir, a.count).map(function (e) {
            if (records) return make(RECP, { key: fromKey(e.k), primaryKey: fromKey(e.pk), value: valueOfEntry(src.store, e) });
            return kind === "value" ? valueOfEntry(src.store, e) : fromKey(e.pk);
          });
        });
      },
      count: function (query) {
        var ts = pre(tx, smeta, imeta, false), range = toRange(query, false);
        return enqueue(tx, self, function () { return countIn(sourceOf(ts, smeta, imeta).list, range); });
      },
      cursor: function (query, dir, withValue) {
        var ts = pre(tx, smeta, imeta, false);
        var range = toRange(query, false);
        dir = direction(dir);
        var cursor = make(withValue ? CVP : CP, { source: self, tx: tx, smeta: smeta, imeta: imeta, dir: dir, range: range, withValue: withValue,
          key: undefined, pk: undefined, value: undefined, keyOut: undefined, pkOut: undefined, got: false, req: null, isIndex: isIndex });
        var req = enqueue(tx, self, function () { return step(cursor, undefined, undefined, 1); });
        S(cursor).req = req;
        return req;
      }
    };
  }
  function need1(args) { if (args.length === 0) throw new TypeError("1 argument required, but only 0 present."); }
  function storeQ(self) { var w = S(self); return queries(self, w.tx, w.meta, null); }

  hide(OSP, "get", function get(query) { need1(arguments); return storeQ(this).get(query, "value"); });
  hide(OSP, "getKey", function getKey(query) { need1(arguments); return storeQ(this).get(query, "key"); });
  hide(OSP, "getAll", function getAll(query, count) { return storeQ(this).getAll(query, count, "value"); });
  hide(OSP, "getAllKeys", function getAllKeys(query, count) { return storeQ(this).getAll(query, count, "key"); });
  hide(OSP, "getAllRecords", function getAllRecords(options) { return storeQ(this).getAll(options === undefined ? {} : options, undefined, "value", true); });
  hide(OSP, "count", function count(query) { return storeQ(this).count(query); });
  hide(OSP, "openCursor", function openCursor(query, direction) { return storeQ(this).cursor(query, direction, true); });
  hide(OSP, "openKeyCursor", function openKeyCursor(query, direction) { return storeQ(this).cursor(query, direction, false); });

  hide(OSP, "createIndex", function createIndex(name, keyPath, options) {
    if (arguments.length < 2) throw new TypeError("2 arguments required, but only " + arguments.length + " present.");
    var w = S(this);
    name = String(name);
    var ts = inVersionChange(w, "Creating an index");
    var st = w.meta;
    if (st.indexes.has(name)) throw err("ConstraintError", "An index with the name already exists.");
    var kp = normPath(keyPath);
    var unique = !!(options && options.unique), multi = !!(options && options.multiEntry);
    if (multi && Array.isArray(kp)) throw err("InvalidAccessError", "A multiEntry index cannot have an array key path.");
    var ix = newIndex(name, kp, unique, multi);
    ix.dirty = true;
    ix.pending = true;
    own(ts, st);
    st.indexes.set(name, ix);
    ts.schemaUndo.created.push(ix);
    ts.dirty = true;
    // the index is filled when its turn comes: after the requests made before it
    silent(w.tx, function () {
      if (st.deleted || ix.deleted) return;
      ix.pending = false;
      ix.entries = [];
      var bad = false;
      st.records.forEach(function (rec) {
        var keys = indexKeys(ix, dec(rec.v));
        if (unique && idxConflict(ix, rec.k, keys)) bad = true;
        idxAdd(ix, rec.k, keys);
      });
      if (bad) throw err("ConstraintError", "Records already have the same key in a unique index.");
    });
    return indexWrapper(this, ix);
  });
  hide(OSP, "deleteIndex", function deleteIndex(name) {
    need1(arguments);
    var w = S(this);
    name = String(name);
    var ts = inVersionChange(w, "Deleting an index");
    var st = w.meta;
    var ix = st.indexes.get(name);
    if (!ix) throw err("NotFoundError", "There is no index with that name.");
    own(ts, st);
    st.indexes = new Map(st.indexes);
    st.indexes["delete"](name);
    ix.deleted = true;
    // requests made before this one still keep the index up to date (and can fail on it)
    (st.dying || (st.dying = [])).push(ix);
    ts.dirty = true;
    silent(w.tx, function () {
      ix.gone = true;
      var at = st.dying ? st.dying.indexOf(ix) : -1;
      if (at >= 0) st.dying.splice(at, 1);
    });
  });
  hide(OSP, "index", function index(name) {
    need1(arguments);
    var w = S(this);
    name = String(name);
    var ts = S(w.tx);
    if (w.meta.deleted) throw err("InvalidStateError", "The object store has been deleted.");
    if (ts.finished) throw err("InvalidStateError", "The transaction has finished.");
    var ix = w.meta.indexes.get(name);
    if (!ix) throw err("NotFoundError", "There is no index with the name '" + name + "'.");
    return indexWrapper(this, ix);
  });

  // ── indexes ───────────────────────────────────────────────

  function IDBIndex() { illegal(); }
  var IXP = IDBIndex.prototype;
  tag(IXP, "IDBIndex");
  function indexWrapper(store, ix) {
    var sw = S(store);
    var w = sw.ixw.get(ix);
    if (!w) {
      w = make(IXP, { tx: sw.tx, store: store, meta: ix, smeta: sw.meta });
      sw.ixw.set(ix, w);
    }
    return w;
  }
  function ixQ(self) { var w = S(self); return queries(self, w.tx, w.smeta, w.meta); }
  getter(IXP, "objectStore", function () { return S(this).store; });
  getter(IXP, "keyPath", function () { return pathOut(S(this)); });
  getter(IXP, "multiEntry", function () { return S(this).meta.multi; });
  getter(IXP, "unique", function () { return S(this).meta.unique; });
  hide(IXP, "get", function get(query) { need1(arguments); return ixQ(this).get(query, "value"); });
  hide(IXP, "getKey", function getKey(query) { need1(arguments); return ixQ(this).get(query, "key"); });
  hide(IXP, "getAll", function getAll(query, count) { return ixQ(this).getAll(query, count, "value"); });
  hide(IXP, "getAllKeys", function getAllKeys(query, count) { return ixQ(this).getAll(query, count, "key"); });
  hide(IXP, "getAllRecords", function getAllRecords(options) { return ixQ(this).getAll(options === undefined ? {} : options, undefined, "value", true); });
  hide(IXP, "count", function count(query) { return ixQ(this).count(query); });
  hide(IXP, "openCursor", function openCursor(query, direction) { return ixQ(this).cursor(query, direction, true); });
  hide(IXP, "openKeyCursor", function openKeyCursor(query, direction) { return ixQ(this).cursor(query, direction, false); });
  Object.defineProperty(IXP, "name", {
    get: function () { return S(this).meta.name; },
    set: function (v) {
      var w = S(this);
      v = String(v);
      var ts = S(w.tx);
      if (ts.mode !== "versionchange") throw err("InvalidStateError", "Renaming is only possible in a versionchange transaction.");
      if (w.meta.deleted || w.smeta.deleted) throw err("InvalidStateError", "The index has been deleted.");
      if (ts.finished || !ts.active) throw err("TransactionInactiveError", "The transaction is not active.");
      var st = w.smeta;
      if (v === w.meta.name) return;
      if (st.indexes.has(v)) throw err("ConstraintError", "An index with that name already exists.");
      var old = w.meta.name;
      st.indexes = new Map(Array.from(st.indexes.entries()).map(function (e) { return e[0] === old ? [v, e[1]] : e; }));
      w.meta.name = v;
      ts.dirty = true;
    },
    enumerable: true, configurable: true
  });

  // ── cursors ───────────────────────────────────────────────

  // the entry that comes after `cur` in the direction (or at/after a target key), or null
  function seek(list, range, dir, cur, tk, tpk) {
    var up = dir === "next" || dir === "nextunique";
    var uniq = dir.indexOf("unique") >= 0;
    var i, j;
    if (up) {
      i = range && range.hasLower ? (range.lowerOpen ? UB(list, range.lower) : LB(list, range.lower)) : 0;
      if (cur) { j = uniq ? UB(list, cur.k) : UB(list, cur.k, cur.pk); if (j > i) i = j; }
      if (tk !== undefined) { j = LB(list, tk, tpk); if (j > i) i = j; }
      if (i >= list.length || !inRange(range, list[i].k)) return null;
      return list[i];
    }
    i = range && range.hasUpper ? (range.upperOpen ? LB(list, range.upper) - 1 : UB(list, range.upper) - 1) : list.length - 1;
    if (cur) { j = uniq ? LB(list, cur.k) - 1 : LB(list, cur.k, cur.pk) - 1; if (j < i) i = j; }
    if (tk !== undefined) { j = UB(list, tk, tpk) - 1; if (j < i) i = j; }
    if (i < 0 || !inRange(range, list[i].k)) return null;
    return uniq ? list[LB(list, list[i].k)] : list[i];
  }

  function IDBCursor() { illegal(); }
  var CP = IDBCursor.prototype;
  tag(CP, "IDBCursor");
  function IDBCursorWithValue() { illegal(); }
  var CVP = IDBCursorWithValue.prototype = Object.create(CP);
  hide(CVP, "constructor", IDBCursorWithValue);
  tag(CVP, "IDBCursorWithValue");

  // moves the cursor `count` entries on; the result of the request: the cursor, or null at the end
  function step(cursor, tk, tpk, count) {
    var cs = S(cursor), ts = S(cs.tx);
    var src = sourceOf(ts, cs.smeta, cs.imeta);
    var cur = cs.got ? { k: cs.key, pk: cs.pk } : null;
    var e = null;
    for (var n = 0; n < count; n++) {
      e = seek(src.list, cs.range, cs.dir, cur, n === 0 ? tk : undefined, n === 0 ? tpk : undefined);
      if (!e) break;
      cur = e;
    }
    if (!e) {
      cs.got = false;
      cs.key = cs.pk = cs.value = cs.keyOut = cs.pkOut = undefined;
      return null;
    }
    cs.key = e.k;
    cs.pk = e.pk;
    cs.keyOut = fromKey(e.k);
    cs.pkOut = cs.isIndex ? fromKey(e.pk) : cs.keyOut;
    cs.got = true;
    if (cs.withValue) cs.value = valueOfEntry(src.store, e);
    return cursor;
  }
  // the checks of continue, advance and continuePrimaryKey, in the order of the specification
  function cursorCheck(self) {
    var cs = S(self), ts = S(cs.tx);
    if (ts.finished || !ts.active) throw err("TransactionInactiveError", ts.finished ? "The transaction has finished." : "The transaction is not active.");
    if (cs.smeta.deleted || (cs.imeta && cs.imeta.deleted)) throw err("InvalidStateError", "The cursor's source has been deleted.");
    if (!cs.got) throw err("InvalidStateError", "The cursor is being iterated or has iterated past its end.");
    return cs;
  }
  function cursorMove(self, key, pk, count, usePk) {
    var cs = cursorCheck(self);
    var tk, tpk;
    var up = cs.dir === "next" || cs.dir === "nextunique";
    if (key !== undefined) {
      tk = needKey(key);
      var c = cmp(tk, cs.key);
      if (usePk) {
        tpk = needKey(pk);
        if (c === 0) c = cmp(tpk, cs.pk);
      }
      if ((up && c <= 0) || (!up && c >= 0)) throw err("DataError", "The key is not " + (up ? "after" : "before") + " the cursor position.");
    } else if (usePk) {
      throw err("DataError", "The key is not a valid key.");
    }
    var keep = { k: cs.key, pk: cs.pk };
    cs.got = false;
    // the position stays for the step after this request is served
    return enqueue(cs.tx, cs.source, function () {
      cs.got = true;
      cs.key = keep.k;
      cs.pk = keep.pk;
      return step(self, tk, tpk, count);
    }, cs.req);
  }
  getter(CP, "source", function () { return S(this).source; });
  getter(CP, "direction", function () { return S(this).dir; });
  getter(CP, "key", function () { return S(this).keyOut; });
  getter(CP, "primaryKey", function () { return S(this).pkOut; });
  getter(CP, "request", function () { return S(this).req; });
  getter(CVP, "value", function () { return S(this).value; });
  hide(CP, "advance", function advance(n) {
    need1(arguments);
    n = toUInt(n, "count");
    if (n === 0) throw new TypeError("A count of zero is not allowed.");
    return cursorMove(this, undefined, undefined, n, false);
  });
  hide(CP, "continue", function (key) { return cursorMove(this, key, undefined, 1, false); });
  hide(CP, "continuePrimaryKey", function continuePrimaryKey(key, pk) {
    if (arguments.length < 2) throw new TypeError("2 arguments required, but only " + arguments.length + " present.");
    var cs = S(this);
    var ts = S(cs.tx);
    if (ts.finished || !ts.active) throw err("TransactionInactiveError", "The transaction is not active.");
    if (cs.smeta.deleted || (cs.imeta && cs.imeta.deleted)) throw err("InvalidStateError", "The cursor's source has been deleted.");
    if (!cs.isIndex) throw err("InvalidAccessError", "The cursor's source is not an index.");
    if (cs.dir !== "next" && cs.dir !== "prev") throw err("InvalidAccessError", "The cursor's direction is not next or prev.");
    if (!cs.got) throw err("InvalidStateError", "The cursor is being iterated or has iterated past its end.");
    return cursorMove(this, key, pk, 1, true);
  });
  // the checks of update and delete
  function cursorWrite(self) {
    var cs = S(self), ts = S(cs.tx);
    if (ts.finished || !ts.active) throw err("TransactionInactiveError", ts.finished ? "The transaction has finished." : "The transaction is not active.");
    if (cs.smeta.deleted || (cs.imeta && cs.imeta.deleted)) throw err("InvalidStateError", "The cursor's source has been deleted.");
    if (ts.mode === "readonly") throw err("ReadOnlyError", "The transaction is read-only.");
    if (!cs.got || !cs.withValue) throw err("InvalidStateError", "The cursor is not at a value.");
    return cs;
  }
  hide(CP, "update", function update(value) {
    need1(arguments);
    var cs = cursorWrite(this), ts = S(cs.tx), smeta = cs.smeta;
    var encoded = cloneInactive(ts, value), cloned = null;
    if (smeta.keyPath !== null) {
      cloned = dec(encoded);
      var r = extractKey(cloned, smeta.keyPath);
      if (r === INVALID || r === NOKEY || cmp(r, cs.pk) !== 0) throw err("DataError", "The key of the value is not the key of the cursor.");
    }
    var pk = cs.pk;
    return enqueue(cs.tx, this, function () {
      return putRecord(ts, storeFor(ts, smeta), pk, encoded, cloned, false, false);
    });
  });
  hide(CP, "delete", function () {
    var cs = cursorWrite(this), ts = S(cs.tx), pk = cs.pk, smeta = cs.smeta;
    var range = { lower: pk, upper: pk, lowerOpen: false, upperOpen: false, hasLower: true, hasUpper: true };
    return enqueue(cs.tx, this, function () {
      removeRange(ts, storeFor(ts, smeta), range);
      return undefined;
    });
  });

  // ── connections ───────────────────────────────────────────

  function IDBDatabase() { illegal(); }
  var DP = IDBDatabase.prototype = Object.create(ETP);
  hide(DP, "constructor", IDBDatabase);
  tag(DP, "IDBDatabase");
  handlers(DP, ["abort", "close", "error", "versionchange"]);

  var conns = {};
  var nextConn = 1, nextOp = 1;
  var pendingOps = {};

  function makeConn(name, version, data) {
    return make(DP, newState({ name: name, version: version, id: nextConn++, closePending: false, closed: false, registered: false,
      txs: [], data: data, parent: null }));
  }
  function finalClose(conn) {
    var cs = S(conn);
    if (cs.closed) return;
    cs.closed = true;
    var list = conns[cs.name];
    if (list) { var at = list.indexOf(conn); if (at >= 0) list.splice(at, 1); }
    if (cs.registered) g.__idb_close(cs.name, cs.id);
  }
  getter(DP, "name", function () { return S(this).name; });
  getter(DP, "version", function () { return S(this).version; });
  getter(DP, "objectStoreNames", function () {
    var s = S(this);
    return strList(sortedNames(s.data.stores));
  });
  hide(DP, "close", function close() {
    var s = S(this);
    s.closePending = true;
    if (s.txs.length === 0) finalClose(this);
  });
  hide(DP, "transaction", function transaction(storeNames, mode, options) {
    var s = S(this);
    if (arguments.length === 0) throw new TypeError("1 argument required, but only 0 present.");
    var names = typeof storeNames === "string" ? [storeNames] : Array.prototype.slice.call(storeNames).map(String);
    var i;
    for (i = 0; i < s.txs.length; i++) if (S(s.txs[i]).mode === "versionchange" && !S(s.txs[i]).finished) throw err("InvalidStateError", "A version change transaction is running.");
    if (s.closePending) throw err("InvalidStateError", "The database connection is closing.");
    names = names.filter(function (n, at) { return names.indexOf(n) === at; }).sort();
    if (names.length === 0) throw err("InvalidAccessError", "The storeNames parameter is empty.");
    for (i = 0; i < names.length; i++) if (!s.data.stores.has(names[i])) throw err("NotFoundError", "The object store '" + names[i] + "' does not exist.");
    if (mode === undefined) mode = "readonly";
    mode = String(mode);
    if (mode !== "readonly" && mode !== "readwrite") throw new TypeError("The provided value '" + mode + "' is not a valid enum value of type IDBTransactionMode.");
    if (options && options.durability !== undefined && ["default", "strict", "relaxed"].indexOf(String(options.durability)) < 0)
      throw new TypeError("The provided value is not a valid enum value of type IDBTransactionDurability.");
    return makeTx(this, names, mode, false);
  });
  hide(DP, "createObjectStore", function createObjectStore(name, options) {
    var s = S(this);
    var tx = null;
    for (var i = 0; i < s.txs.length; i++) if (S(s.txs[i]).mode === "versionchange" && !S(s.txs[i]).over) tx = s.txs[i];
    if (!tx) throw err("InvalidStateError", "The database is not running a version change transaction.");
    var ts = S(tx);
    if (!ts.active || ts.finished) throw err("TransactionInactiveError", "The transaction is not active.");
    name = String(name);
    var kp = options && options.keyPath !== undefined ? normPath(options.keyPath) : null;
    var auto = !!(options && options.autoIncrement);
    if (s.data.stores.has(name)) throw err("ConstraintError", "An object store with the name '" + name + "' already exists.");
    if (auto && (kp === "" || Array.isArray(kp))) throw err("InvalidAccessError", "An autoIncrement object store cannot have an empty or array key path.");
    var st = newStore(name, kp, auto);
    s.data.stores.set(name, st);
    ts.schemaUndo.createdStores.push(st);
    silent(tx, function () { ts.ops.push(["c", name]); });
    ts.dirty = true;
    return storeWrapper(tx, st);
  });
  hide(DP, "deleteObjectStore", function deleteObjectStore(name) {
    var s = S(this);
    var tx = null;
    for (var i = 0; i < s.txs.length; i++) if (S(s.txs[i]).mode === "versionchange" && !S(s.txs[i]).over) tx = s.txs[i];
    if (!tx) throw err("InvalidStateError", "The database is not running a version change transaction.");
    if (!S(tx).active || S(tx).finished) throw err("TransactionInactiveError", "The transaction is not active.");
    name = String(name);
    if (!s.data.stores.has(name)) throw err("NotFoundError", "The object store '" + name + "' does not exist.");
    var gone = s.data.stores.get(name);
    var goneIx = Array.from(gone.indexes.values());
    s.data.stores["delete"](name);
    gone.deleted = true;
    goneIx.forEach(function (ix) { ix.deleted = true; });
    gone.indexes = new Map();
    // requests made before this one still find the store
    silent(tx, function () {
      gone.gone = true;
      goneIx.forEach(function (ix) { ix.gone = true; });
    });
    S(tx).dirty = true;
  });

  // ── opening, deleting, and the other pages ────────────────

  function IDBFactory() { illegal(); }
  var FP = IDBFactory.prototype;
  tag(FP, "IDBFactory");

  function startOp(kind, name, version) {
    var req = makeRequest(null, null, ORP);
    var op = { id: nextOp++, kind: kind, name: name, version: version, req: req, token: 0, proceeded: false };
    pendingOps[op.id] = op;
    var r = g.__idb_begin(name, kind === "delete" ? "delete" : version, op.id);
    op.token = r[0];
    if (r[1]) task(function () { if (!op.proceeded) proceed(op); });
    return req;
  }
  hide(FP, "open", function open(name, version) {
    S(this);
    if (arguments.length === 0) throw new TypeError("1 argument required, but only 0 present.");
    name = String(name);
    if (version !== undefined) {
      version = Number(version);
      if (version !== version || version === Infinity || version < 0 || version > 9007199254740991) throw new TypeError("The version provided is not valid.");
      version = Math.floor(version);
      if (version === 0) throw new TypeError("The version must be greater than zero.");
    }
    return startOp("open", name, version);
  });
  hide(FP, "deleteDatabase", function deleteDatabase(name) {
    S(this);
    if (arguments.length === 0) throw new TypeError("1 argument required, but only 0 present.");
    return startOp("delete", String(name));
  });
  hide(FP, "cmp", function (a, b) {
    S(this);
    if (arguments.length < 2) throw new TypeError("2 arguments required.");
    return cmp(needKey(a), needKey(b));
  });
  hide(FP, "databases", function databases() {
    S(this);
    return new Promise(function (resolve) {
      resolve(g.__idb_names().map(function (e) { return { name: e[0], version: e[1] }; }));
    });
  });

  function fail(op, error) {
    var rs = S(op.req);
    rs.done = true;
    rs.result = undefined;
    rs.error = error;
    dispatch(mkEvent("error", true, true), pathOf(op.req));
  }

  function proceed(op) {
    op.proceeded = true;
    delete pendingOps[op.id];
    var name = op.name, req = op.req, rs = S(req);
    var data = freshData(name);
    var cur = data ? data.version : 0;
    if (op.kind === "delete") {
      if (data) { g.__idb_delete(name); delete cache[name]; }
      g.__idb_finish(name, op.token, undefined);
      rs.done = true;
      rs.result = undefined;
      dispatch(versionEvent("success", cur, null), pathOf(req));
      return;
    }
    var version = op.version === undefined ? (cur || 1) : op.version;
    if (version < cur) {
      g.__idb_finish(name, op.token, undefined);
      fail(op, err("VersionError", "The requested version (" + version + ") is less than the existing version (" + cur + ")."));
      return;
    }
    var isNew = !data;
    if (isNew) data = newDb(name);
    var conn = makeConn(name, version > cur ? cur : version, data);
    var cs = S(conn);
    if (version === cur) {
      cs.registered = true;
      (conns[name] || (conns[name] = [])).push(conn);
      g.__idb_finish(name, op.token, cs.id);
      rs.done = true;
      rs.result = conn;
      dispatch(mkEvent("success", false, false), pathOf(req));
      return;
    }
    // a higher version: the upgrade runs in a versionchange transaction, in which the script can
    // change the stores
    var tx = makeTx(conn, null, "versionchange", true);
    var ts = S(tx);
    ts.data = data;
    ts.schemaUndo = snapshotSchema(data, isNew);
    data.version = version;
    cs.version = version;
    ts.dirty = true;
    rs.done = true;
    rs.result = conn;
    rs.transaction = tx;
    ts.onfinish = function (ok) {
      rs.transaction = null;
      if (ok && !cs.closePending) {
        cs.registered = true;
        (conns[name] || (conns[name] = [])).push(conn);
        g.__idb_finish(name, op.token, cs.id);
        rs.result = conn;
        dispatch(mkEvent("success", false, false), pathOf(req));
      } else {
        cs.version = cur;
        cs.closePending = true;
        finalClose(conn);
        g.__idb_finish(name, op.token, undefined);
        fail(op, err("AbortError", ok ? "The connection was closed." : "The upgrade transaction was aborted."));
      }
    };
    deactivateLater(tx);
    var res = dispatch(versionEvent("upgradeneeded", cur, version), pathOf(req));
    if (res.threw) abortTx(tx, err("AbortError"));
    task(function () { runNext(tx); });
  }

  // a message from the store: another page (or this one) wants to change a database
  function onMessage(kind, a, b, c, d) {
    if (kind === "ready") {
      var op = pendingOps[a];
      if (op && !op.proceeded) proceed(op);
    } else if (kind === "blocked") {
      var bop = pendingOps[a];
      if (bop) {
        var data = freshData(bop.name);
        dispatch(versionEvent("blocked", data ? data.version : 0, bop.kind === "delete" ? null : bop.version === undefined ? null : bop.version), pathOf(bop.req));
      }
    } else if (kind === "versionchange") {
      // a = name, b = token, c = old version, d = new version
      (conns[a] || []).slice().forEach(function (conn) {
        if (!S(conn).closePending) dispatch(versionEvent("versionchange", c, d), [conn]);
      });
      g.__idb_settled(a, b);
    }
  }
  g.__idb_hook(onMessage);

  // ── the globals ───────────────────────────────────────────

  var factory = make(FP, {});
  function global(name, value) { Object.defineProperty(g, name, { value: value, writable: true, configurable: true, enumerable: false }); }
  global("indexedDB", factory);
  global("IDBFactory", IDBFactory);
  global("IDBDatabase", IDBDatabase);
  global("IDBObjectStore", IDBObjectStore);
  global("IDBIndex", IDBIndex);
  global("IDBCursor", IDBCursor);
  global("IDBRecord", IDBRecord);
  global("IDBCursorWithValue", IDBCursorWithValue);
  global("IDBTransaction", IDBTransaction);
  global("IDBRequest", IDBRequest);
  global("IDBOpenDBRequest", IDBOpenDBRequest);
  global("IDBKeyRange", IDBKeyRange);
  global("IDBVersionChangeEvent", VCE);
})(globalThis);
