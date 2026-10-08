// WebSocket. Loaded the first time a script uses the name (see Browser.JS.WebSockets). The
// connection and the protocol are native (Browser.WebSocket.Client); this is the API.
(function (g) {
  "use strict";

  var sockets = {}, seq = 0;
  var handlers = new WeakMap();
  var HANDLER_EVENTS = ["open", "message", "error", "close"];

  function handlerOf(w) {
    var h = handlers.get(w);
    if (!h) { h = {}; handlers.set(w, h); }
    return h;
  }

  function utf8Length(s) { return new TextEncoder().encode(s).length; }

  function loopback(host) { return host === "localhost" || host === "127.0.0.1" || host === "[::1]" || /\.localhost$/.test(host); }

  class WebSocket extends EventTarget {
    constructor(url, protocols) {
      if (arguments.length === 0) throw new TypeError("Failed to construct 'WebSocket': 1 argument required, but only 0 present.");
      super();
      var u;
      try { u = new URL(String(url), g.location.href); }
      catch (e) { throw new DOMException("Failed to construct 'WebSocket': The URL '" + url + "' is invalid.", "SyntaxError"); }
      if (u.protocol === "http:") u.protocol = "ws:";
      else if (u.protocol === "https:") u.protocol = "wss:";
      if (u.protocol !== "ws:" && u.protocol !== "wss:")
        throw new DOMException("Failed to construct 'WebSocket': The URL's scheme must be either 'ws' or 'wss'. '" + u.protocol.slice(0, -1) + "' is not allowed.", "SyntaxError");
      if (u.hash) throw new DOMException("Failed to construct 'WebSocket': The URL contains a fragment identifier ('" + u.hash + "'). Fragment identifiers are not allowed in WebSocket URLs.", "SyntaxError");
      if (g.location.protocol === "https:" && u.protocol === "ws:" && !loopback(u.hostname))
        throw new DOMException("Failed to construct 'WebSocket': An insecure WebSocket connection may not be initiated from a page loaded over HTTPS.", "SecurityError");
      var list = protocols === undefined ? [] : typeof protocols === "string" ? [protocols] : Array.prototype.slice.call(protocols).map(String);
      for (var i = 0; i < list.length; i++) {
        if (!/^[\x21\x23-\x27\x2a\x2b\x2d\x2e\x30-\x39\x41-\x5a\x5e-\x7a\x7c\x7e]+$/.test(list[i]))
          throw new DOMException("Failed to construct 'WebSocket': The subprotocol '" + list[i] + "' is invalid.", "SyntaxError");
        if (list.indexOf(list[i]) !== i)
          throw new DOMException("Failed to construct 'WebSocket': The subprotocol '" + list[i] + "' is duplicated.", "SyntaxError");
      }
      var id = ++seq;
      Object.defineProperty(this, "__ws", { value: { id: id, state: 0, protocol: "", binaryType: "blob", url: u.href } });
      sockets[id] = this;
      __ws_start(id, u.href, list, g.location.origin, g.location.href);
    }

    get url() { return this.__ws.url; }
    get readyState() { return this.__ws.state; }
    get protocol() { return this.__ws.protocol; }
    get extensions() { return ""; }
    get bufferedAmount() { return 0; }
    get binaryType() { return this.__ws.binaryType; }
    set binaryType(v) { if (v === "blob" || v === "arraybuffer") this.__ws.binaryType = v; }

    send(data) {
      if (arguments.length === 0) throw new TypeError("Failed to execute 'send' on 'WebSocket': 1 argument required, but only 0 present.");
      var st = this.__ws;
      if (st.state === 0) throw new DOMException("Failed to execute 'send' on 'WebSocket': Still in CONNECTING state.", "InvalidStateError");
      if (st.state !== 1) return;
      if (typeof g.Blob === "function" && data instanceof g.Blob) { __ws_send(st.id, new TextEncoder().encode(data._text).buffer, true); return; }
      if (data instanceof ArrayBuffer) { __ws_send(st.id, data, true); return; }
      if (ArrayBuffer.isView(data)) { __ws_send(st.id, data.buffer.slice(data.byteOffset, data.byteOffset + data.byteLength), true); return; }
      __ws_send(st.id, String(data), false);
    }

    close(code, reason) {
      var st = this.__ws;
      if (code !== undefined) {
        code = Number(code);
        if (code !== 1000 && !(code >= 3000 && code <= 4999))
          throw new DOMException("Failed to execute 'close' on 'WebSocket': The code must be either 1000, or between 3000 and 4999. " + code + " is neither.", "InvalidAccessError");
      }
      if (reason !== undefined) {
        reason = String(reason);
        if (utf8Length(reason) > 123)
          throw new DOMException("Failed to execute 'close' on 'WebSocket': The message must not be greater than 123 bytes.", "SyntaxError");
      }
      if (st.state === 2 || st.state === 3) return;
      st.state = 2;
      __ws_close(st.id, code, reason);
    }
  }

  ["CONNECTING", "OPEN", "CLOSING", "CLOSED"].forEach(function (name, i) {
    Object.defineProperty(WebSocket, name, { value: i, enumerable: true });
    Object.defineProperty(WebSocket.prototype, name, { value: i, enumerable: true });
  });

  HANDLER_EVENTS.forEach(function (type) {
    Object.defineProperty(WebSocket.prototype, "on" + type, {
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
  Object.defineProperty(WebSocket.prototype, Symbol.toStringTag, { value: "WebSocket", configurable: true });

  __ws_hook(function (kind, id, a, b, c) {
    var ws = sockets[id];
    if (!ws) return;
    var st = ws.__ws;
    if (kind === "open") {
      st.state = 1;
      st.protocol = a;
      ws.dispatchEvent(new Event("open"));
    } else if (kind === "message") {
      if (st.state !== 1) return;
      var data = a;
      if (b) data = st.binaryType === "arraybuffer" ? a : new Blob([new Uint8Array(a)]);
      ws.dispatchEvent(new MessageEvent("message", { data: data, origin: new URL(st.url).origin.replace(/^http/, "ws"), lastEventId: "", source: null, ports: [] }));
    } else if (kind === "error") {
      ws.dispatchEvent(new Event("error"));
    } else if (kind === "close") {
      st.state = 3;
      delete sockets[id];
      ws.dispatchEvent(new CloseEvent("close", { wasClean: c, code: a, reason: b }));
    }
  });

  Object.defineProperty(g, "WebSocket", { value: WebSocket, writable: true, configurable: true, enumerable: false });
})(globalThis);
