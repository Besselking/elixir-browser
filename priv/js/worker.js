// Worker, the page side. Loaded the first time a script uses the name (see Browser.JS.Workers).
// A worker is a process with a heap of its own; messages cross as the text of a structured clone.
(function (g) {
  "use strict";

  var workers = {}, seq = 0;
  var handlers = new WeakMap();
  var HANDLER_EVENTS = ["message", "messageerror", "error"];

  function handlerOf(w) {
    var h = handlers.get(w);
    if (!h) { h = {}; handlers.set(w, h); }
    return h;
  }

  function baseURL() {
    var base = typeof document === "object" && document ? document.baseURI : "";
    return base || g.location.href;
  }

  class Worker extends EventTarget {
    constructor(url, options) {
      if (arguments.length === 0) throw new TypeError("Failed to construct 'Worker': 1 argument required, but only 0 present.");
      super();
      options = options || {};
      var abs;
      try { abs = new URL(String(url), baseURL()).href; }
      catch (e) { throw new DOMException("Failed to construct 'Worker': Script at '" + url + "' cannot be accessed from origin '" + g.location.origin + "'.", "SyntaxError"); }
      var source;
      if (abs.indexOf("blob:") === 0) {
        source = g.URL.__blobText(abs);
        if (source === undefined) throw new DOMException("Failed to construct 'Worker': the blob could not be found.", "SyntaxError");
      }
      var id = ++seq;
      Object.defineProperty(this, "__id", { value: id });
      workers[id] = this;
      __worker_start(id, abs, source, options.name === undefined ? "" : String(options.name), options.type === "module");
    }

    postMessage(message, transfer) {
      if (arguments.length === 0) throw new TypeError("Failed to execute 'postMessage' on 'Worker': 1 argument required, but only 0 present.");
      if (!workers[this.__id]) return;
      __worker_post(this.__id, g.__structuredEncode(message));
    }

    terminate() {
      if (!workers[this.__id]) return;
      delete workers[this.__id];
      __worker_terminate(this.__id);
    }
  }

  HANDLER_EVENTS.forEach(function (type) {
    Object.defineProperty(Worker.prototype, "on" + type, {
      configurable: true, enumerable: true,
      get: function () { var h = handlerOf(this); return h[type] === undefined ? null : h[type]; },
      set: function (f) {
        var h = handlerOf(this);
        if (!(type in h)) {
          var self = this;
          this.addEventListener(type, function (e) { var cb = handlerOf(self)[type]; if (typeof cb === "function") cb.call(self, e); });
        }
        h[type] = typeof f === "function" || (f !== null && typeof f === "object") ? f : null;
      }
    });
  });
  Object.defineProperty(Worker.prototype, Symbol.toStringTag, { value: "Worker", configurable: true });

  __worker_hook(function (kind, id, a, b) {
    var w = workers[id];
    if (!w) return;
    if (kind === "message") {
      var data;
      try { data = g.__structuredDecode(a); }
      catch (e) { w.dispatchEvent(new MessageEvent("messageerror", { origin: g.location.origin })); return; }
      w.dispatchEvent(new MessageEvent("message", { data: data, origin: g.location.origin, source: null, ports: [] }));
    } else {
      var ev = new ErrorEvent("error", { message: a, filename: b, lineno: 0, colno: 0, cancelable: true });
      if (w.dispatchEvent(ev)) console.error(a);
    }
  });

  Object.defineProperty(g, "Worker", { value: Worker, writable: true, configurable: true, enumerable: false });
})(globalThis);
