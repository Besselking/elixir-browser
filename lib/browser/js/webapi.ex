defmodule Browser.JS.WebAPI do
  @moduledoc """
  The web platform pieces that scripts expect beside the DOM: `fetch`, `XMLHttpRequest`, the
  observers, `AbortController`, `atob`/`btoa`, `document.fonts` and a few more. They are
  written in JavaScript (the `@prelude`), on top of one native function, `__fetch`, that does
  a request and hands back what came.
  """

  alias Browser.JS.{Interp, Parser}

  @doc "Declares `__fetch` and runs the prelude. `http` is `(method, url, body) -> {:ok, body, url} | {:error, msg}`."
  def install(scope, http) do
    Interp.declare(
      scope,
      "__fetch",
      Interp.native("__fetch", fn _this, args ->
        method = args |> Enum.at(0, "GET") |> Interp.to_str()
        url = args |> Enum.at(1, "") |> Interp.to_str()
        body = args |> Enum.at(2, :undefined) |> body_text()

        case http.(method, url, body) do
          {:ok, text, final} ->
            Interp.new_object([{"status", 200.0}, {"url", final}, {"body", text}])

          {:error, msg} ->
            Interp.throw_error("TypeError", "Failed to fetch: #{msg}")
        end
      end)
    )

    Browser.JS.Proxy.install(scope)

    case program() do
      {:ok, ast} -> Interp.run_program(ast)
      {:error, msg} -> throw({:syntax, "web api prelude: " <> msg})
    end
  end

  defp body_text(v) when v in [:undefined, :null], do: nil
  defp body_text(v), do: Interp.to_str(v)

  @prelude ~S"""
  (function (g) {
    function def(name, value) { if (!(name in g)) g[name] = value; }

    // ── fetch and XMLHttpRequest ─────────────────────────────
    function Headers(init) {
      this._h = {};
      if (init) {
        if (typeof init.forEach === "function" && !(init instanceof Array)) { var self = this; init.forEach(function (v, k) { self.append(k, v); }); }
        else if (init instanceof Array) { for (var i = 0; i < init.length; i++) this.append(init[i][0], init[i][1]); }
        else { for (var k in init) this.append(k, init[k]); }
      }
    }
    Headers.prototype.append = function (k, v) { k = String(k).toLowerCase(); this._h[k] = this._h[k] === undefined ? String(v) : this._h[k] + ", " + v; };
    Headers.prototype.set = function (k, v) { this._h[String(k).toLowerCase()] = String(v); };
    Headers.prototype.get = function (k) { var v = this._h[String(k).toLowerCase()]; return v === undefined ? null : v; };
    Headers.prototype.has = function (k) { return this._h[String(k).toLowerCase()] !== undefined; };
    Headers.prototype["delete"] = function (k) { delete this._h[String(k).toLowerCase()]; };
    Headers.prototype.forEach = function (cb) { for (var k in this._h) cb(this._h[k], k, this); };
    Headers.prototype.entries = function () { var out = []; for (var k in this._h) out.push([k, this._h[k]]); return out[Symbol.iterator](); };
    Headers.prototype.keys = function () { return Object.keys(this._h)[Symbol.iterator](); };
    Headers.prototype.values = function () { var out = []; for (var k in this._h) out.push(this._h[k]); return out[Symbol.iterator](); };
    Headers.prototype[Symbol.iterator] = Headers.prototype.entries;

    function Response(body, init) {
      init = init || {};
      this._body = body === undefined || body === null ? "" : String(body);
      this.status = init.status === undefined ? 200 : init.status;
      this.ok = this.status >= 200 && this.status < 300;
      this.statusText = init.statusText || "";
      this.url = init.url || "";
      this.type = "basic";
      this.redirected = false;
      this.bodyUsed = false;
      this.headers = new Headers(init.headers);
    }
    Response.prototype.text = function () { this.bodyUsed = true; return Promise.resolve(this._body); };
    Response.prototype.json = function () { var b = this._body; this.bodyUsed = true; return new Promise(function (res, rej) { try { res(JSON.parse(b)); } catch (e) { rej(e); } }); };
    Response.prototype.clone = function () { return new Response(this._body, { status: this.status, statusText: this.statusText, url: this.url, headers: this.headers }); };
    Response.prototype.arrayBuffer = function () { return Promise.resolve(new TextEncoder().encode(this._body).buffer); };
    Response.prototype.blob = function () { return Promise.resolve({ size: this._body.length, type: "", text: function () { return Promise.resolve(this._b); }, _b: this._body }); };
    Response.error = function () { var r = new Response("", { status: 0 }); r.type = "error"; return r; };

    function Request(input, init) {
      init = init || {};
      this.url = typeof input === "string" ? input : (input && input.url) || String(input);
      this.method = (init.method || (input && input.method) || "GET").toUpperCase();
      this.headers = new Headers(init.headers || (input && input.headers));
      this.body = init.body === undefined ? null : init.body;
      this.signal = init.signal || null;
    }

    function fetchImpl(input, init) {
      return new Promise(function (resolve, reject) {
        var req = new Request(input, init);
        if (req.signal && req.signal.aborted) { reject(new DOMException("The operation was aborted.", "AbortError")); return; }
        try {
          var r = __fetch(req.method, new URL(req.url, document.baseURI || location.href).href, req.body);
          var res = new Response(r.body, { status: r.status, url: r.url });
          res.headers.set("content-type", "text/html");
          resolve(res);
        } catch (e) { reject(new TypeError("Failed to fetch")); }
      });
    }

    function XMLHttpRequest() {
      this.readyState = 0; this.status = 0; this.statusText = ""; this.responseText = ""; this.response = "";
      this.responseType = ""; this.responseURL = ""; this.timeout = 0; this.withCredentials = false;
      this._l = {}; this._headers = {}; this._method = "GET"; this._url = "";
      this.upload = { addEventListener: function () {}, removeEventListener: function () {} };
    }
    XMLHttpRequest.UNSENT = 0; XMLHttpRequest.OPENED = 1; XMLHttpRequest.HEADERS_RECEIVED = 2; XMLHttpRequest.LOADING = 3; XMLHttpRequest.DONE = 4;
    XMLHttpRequest.prototype.open = function (method, url) { this._method = String(method).toUpperCase(); this._url = String(url); this.readyState = 1; this._fire("readystatechange"); };
    XMLHttpRequest.prototype.setRequestHeader = function (k, v) { this._headers[k] = v; };
    XMLHttpRequest.prototype.getResponseHeader = function (k) { return String(k).toLowerCase() === "content-type" ? "text/html" : null; };
    XMLHttpRequest.prototype.getAllResponseHeaders = function () { return "content-type: text/html\r\n"; };
    XMLHttpRequest.prototype.overrideMimeType = function () {};
    XMLHttpRequest.prototype.abort = function () { this._aborted = true; this.readyState = 0; };
    XMLHttpRequest.prototype.addEventListener = function (t, f) { (this._l[t] = this._l[t] || []).push(f); };
    XMLHttpRequest.prototype.removeEventListener = function (t, f) { var a = this._l[t]; if (a) { var i = a.indexOf(f); if (i >= 0) a.splice(i, 1); } };
    XMLHttpRequest.prototype._fire = function (type) {
      var ev = { type: type, target: this, currentTarget: this };
      var h = this["on" + type]; if (typeof h === "function") { try { h.call(this, ev); } catch (e) { console.error(e); } }
      var a = this._l[type]; if (a) a.slice().forEach(function (f) { try { f.call(this, ev); } catch (e) { console.error(e); } }, this);
    };
    XMLHttpRequest.prototype.send = function (body) {
      var self = this;
      setTimeout(function () {
        if (self._aborted) return;
        try {
          var r = __fetch(self._method, new URL(self._url, document.baseURI || location.href).href, body);
          self.status = r.status; self.statusText = "OK"; self.responseURL = r.url;
          self.responseText = r.body;
          self.response = self.responseType === "json" ? JSON.parse(r.body) : r.body;
          self.readyState = 4;
          self._fire("readystatechange"); self._fire("load"); self._fire("loadend");
        } catch (e) {
          self.readyState = 4; self.status = 0;
          self._fire("readystatechange"); self._fire("error"); self._fire("loadend");
        }
      }, 0);
    };

    // ── abort ────────────────────────────────────────────────
    function AbortSignal() { this.aborted = false; this.reason = undefined; this._l = []; }
    AbortSignal.prototype.addEventListener = function (t, f) { if (t === "abort") this._l.push(f); };
    AbortSignal.prototype.removeEventListener = function (t, f) { var i = this._l.indexOf(f); if (i >= 0) this._l.splice(i, 1); };
    AbortSignal.prototype.throwIfAborted = function () { if (this.aborted) throw this.reason; };
    function AbortController() { this.signal = new AbortSignal(); }
    AbortController.prototype.abort = function (reason) {
      var s = this.signal; if (s.aborted) return;
      s.aborted = true; s.reason = reason === undefined ? new DOMException("The operation was aborted.", "AbortError") : reason;
      var ev = { type: "abort", target: s };
      if (typeof s.onabort === "function") s.onabort(ev);
      s._l.slice().forEach(function (f) { f(ev); });
    };
    AbortSignal.abort = function (reason) { var c = new AbortController(); c.abort(reason); return c.signal; };
    AbortSignal.timeout = function () { return new AbortController().signal; };

    function DOMException(message, name) { this.message = message || ""; this.name = name || "Error"; this.code = 0; }
    DOMException.prototype = Object.create(Error.prototype);
    DOMException.prototype.constructor = DOMException;

    // ── observers ────────────────────────────────────────────
    function MutationObserver(cb) { this._cb = cb; }
    MutationObserver.prototype.observe = function () {};
    MutationObserver.prototype.disconnect = function () {};
    MutationObserver.prototype.takeRecords = function () { return []; };

    function ResizeObserver(cb) { this._cb = cb; }
    ResizeObserver.prototype.observe = function () {};
    ResizeObserver.prototype.unobserve = function () {};
    ResizeObserver.prototype.disconnect = function () {};

    // there is no viewport to be outside of: what is watched counts as seen, so that what waits
    // for that (lazily hydrated parts of a page) gets going
    function IntersectionObserver(cb, opts) { this._cb = cb; this.root = null; this.rootMargin = "0px"; this.thresholds = [0]; }
    IntersectionObserver.prototype.observe = function (el) {
      var self = this;
      setTimeout(function () {
        var r = el.getBoundingClientRect();
        self._cb([{ target: el, isIntersecting: true, intersectionRatio: 1, boundingClientRect: r, intersectionRect: r, rootBounds: null, time: performance.now() }], self);
      }, 0);
    };
    IntersectionObserver.prototype.unobserve = function () {};
    IntersectionObserver.prototype.disconnect = function () {};
    IntersectionObserver.prototype.takeRecords = function () { return []; };

    // ── timing, idle, encoding ───────────────────────────────
    def("requestIdleCallback", function (cb) { return setTimeout(function () { cb({ didTimeout: false, timeRemaining: function () { return 10; } }); }, 1); });
    def("cancelIdleCallback", function (id) { clearTimeout(id); });

    var B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    def("btoa", function (s) {
      s = String(s); var out = "";
      for (var i = 0; i < s.length; i += 3) {
        var a = s.charCodeAt(i), b = s.charCodeAt(i + 1), c = s.charCodeAt(i + 2);
        if (a > 255 || b > 255 || c > 255) throw new DOMException("The string to be encoded contains characters outside of the Latin1 range.", "InvalidCharacterError");
        var n = (a << 16) | ((b || 0) << 8) | (c || 0);
        out += B64[(n >> 18) & 63] + B64[(n >> 12) & 63] + (i + 1 < s.length ? B64[(n >> 6) & 63] : "=") + (i + 2 < s.length ? B64[n & 63] : "=");
      }
      return out;
    });
    def("atob", function (s) {
      s = String(s).replace(/[\s=]+/g, ""); var out = "", bits = 0, acc = 0;
      for (var i = 0; i < s.length; i++) {
        var v = B64.indexOf(s[i]);
        if (v < 0) throw new DOMException("The string to be decoded is not correctly encoded.", "InvalidCharacterError");
        acc = (acc << 6) | v; bits += 6;
        if (bits >= 8) { bits -= 8; out += String.fromCharCode((acc >> bits) & 255); }
      }
      return out;
    });

    def("structuredClone", function (v) { return v === undefined ? v : JSON.parse(JSON.stringify(v)); });

    // ── performance, selection, fonts, misc ──────────────────
    if (typeof performance === "object") {
      var p = performance;
      if (!p.mark) p.mark = function () {};
      if (!p.measure) p.measure = function () {};
      if (!p.clearMarks) p.clearMarks = function () {};
      if (!p.clearMeasures) p.clearMeasures = function () {};
      if (!p.getEntries) p.getEntries = function () { return []; };
      if (!p.getEntriesByType) p.getEntriesByType = function () { return []; };
      if (!p.getEntriesByName) p.getEntriesByName = function () { return []; };
      if (!p.timing) p.timing = { navigationStart: 0, fetchStart: 0, responseStart: 0, domLoading: 0, domInteractive: 0, domContentLoadedEventEnd: 0, loadEventEnd: 0 };
      if (!p.timeOrigin) p.timeOrigin = Date.now();
    }
    def("PerformanceObserver", function (cb) { this.observe = function () {}; this.disconnect = function () {}; this.takeRecords = function () { return []; }; });
    g.PerformanceObserver.supportedEntryTypes = [];

    def("getSelection", function () { return { rangeCount: 0, isCollapsed: true, removeAllRanges: function () {}, addRange: function () {}, toString: function () { return ""; } }; });

    var fonts = { ready: Promise.resolve(), status: "loaded", load: function () { return Promise.resolve([]); }, check: function () { return true; },
      add: function (f) { return fonts; }, "delete": function () { return false; }, clear: function () {}, forEach: function () {},
      addEventListener: function () {}, removeEventListener: function () {} };
    fonts.ready = Promise.resolve(fonts);
    try { document.fonts = fonts; } catch (e) {}
    function FontFace(family, source, desc) { this.family = family; this.status = "loaded"; this.loaded = Promise.resolve(this); }
    FontFace.prototype.load = function () { return Promise.resolve(this); };
    def("FontFace", FontFace);

    function Image(w, h) { var i = document.createElement("img"); if (w !== undefined) i.setAttribute("width", w); if (h !== undefined) i.setAttribute("height", h); return i; }
    def("Image", Image);

    if (typeof navigator === "object") {
      if (!navigator.sendBeacon) navigator.sendBeacon = function () { return true; };
      if (navigator.cookieEnabled === undefined) navigator.cookieEnabled = false;
      if (navigator.hardwareConcurrency === undefined) navigator.hardwareConcurrency = 4;
      if (navigator.maxTouchPoints === undefined) navigator.maxTouchPoints = 0;
      if (!navigator.userAgentData) navigator.userAgentData = undefined;
    }

    // `crypto.subtle` and `randomUUID` exist in secure contexts only
    var cryptoObj = {
      getRandomValues: function (a) { for (var i = 0; i < a.length; i++) a[i] = Math.floor(Math.random() * 4294967296); return a; }
    };
    if (g.isSecureContext) {
      cryptoObj.randomUUID = function () { return "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx".replace(/[xy]/g, function (c) { var r = Math.random() * 16 | 0; return (c === "x" ? r : (r & 3) | 8).toString(16); }); };
      cryptoObj.subtle = {};
    }
    def("crypto", cryptoObj);

    def("CSS", { supports: function () { return false; }, escape: function (s) { return String(s).replace(/[^a-zA-Z0-9_-]/g, function (c) { return "\\" + c; }); } });

    def("Intl", {
      DateTimeFormat: function () { return { format: function (d) { return new Date(d === undefined ? Date.now() : d).toISOString(); }, resolvedOptions: function () { return { locale: "en-US", timeZone: "UTC" }; }, formatToParts: function () { return []; } }; },
      NumberFormat: function () { return { format: function (n) { return String(n); }, resolvedOptions: function () { return { locale: "en-US" }; } }; },
      Collator: function () { return { compare: function (a, b) { return a < b ? -1 : a > b ? 1 : 0; } }; },
      PluralRules: function () { return { select: function (n) { return n === 1 ? "one" : "other"; } }; },
      RelativeTimeFormat: function () { return { format: function (v, u) { return v + " " + u; } }; },
      ListFormat: function () { return { format: function (l) { return l.join(", "); } }; },
      Segmenter: function () { return { segment: function (s) { return String(s).split("").map(function (c, i) { return { segment: c, index: i }; }); } }; },
      getCanonicalLocales: function (l) { return [].concat(l || []); }
    });

    function WeakRef(target) { this._t = target; }
    WeakRef.prototype.deref = function () { return this._t; };
    def("WeakRef", WeakRef);
    function FinalizationRegistry() {}
    FinalizationRegistry.prototype.register = function () {};
    FinalizationRegistry.prototype.unregister = function () {};
    def("FinalizationRegistry", FinalizationRegistry);

    // there are no big integers here: a BigInt is the (whole) number
    function BigInt(v) { return Math.trunc(Number(v)); }
    BigInt.asUintN = function (bits, v) { var m = Math.pow(2, bits); return ((v % m) + m) % m; };
    BigInt.asIntN = function (bits, v) { var m = Math.pow(2, bits); var r = ((v % m) + m) % m; return r >= m / 2 ? r - m : r; };
    def("BigInt", BigInt);

    ["DateTimeFormat", "NumberFormat", "Collator", "PluralRules", "RelativeTimeFormat", "ListFormat", "Segmenter"].forEach(function (n) {
      Intl[n].supportedLocalesOf = function (l) { return [].concat(l || []); };
    });


    // ── the rest of the DOM scripts reach for ────────────────
    var EP = Element.prototype;
    function addTo(proto, name, fn) { if (!(name in proto)) proto[name] = fn; }
    function getter(proto, name, fn) { if (!(name in proto)) Object.defineProperty(proto, name, { get: fn, configurable: true }); }

    addTo(EP, "setAttributeNS", function (ns, name, v) { this.setAttribute(name, v); });
    addTo(EP, "getAttributeNS", function (ns, name) { return this.getAttribute(name); });
    addTo(EP, "removeAttributeNS", function (ns, name) { this.removeAttribute(name); });
    addTo(EP, "hasAttributeNS", function (ns, name) { return this.hasAttribute(name); });
    addTo(EP, "hasAttributes", function () { return this.attributes.length > 0; });
    addTo(EP, "webkitMatchesSelector", function (s) { return this.matches(s); });
    addTo(EP, "isEqualNode", function (o) { return !!o && this.outerHTML === o.outerHTML; });
    addTo(EP, "getAnimations", function () { return []; });
    addTo(EP, "requestFullscreen", function () { return Promise.reject(new TypeError("Fullscreen is not supported")); });
    addTo(EP, "setPointerCapture", function () {});
    addTo(EP, "releasePointerCapture", function () {});
    addTo(EP, "hasPointerCapture", function () { return false; });
    addTo(EP, "checkVisibility", function () { return true; });
    addTo(EP, "lookupNamespaceURI", function () { return null; });
    getter(EP, "namespaceURI", function () { return "http://www.w3.org/1999/xhtml"; });
    getter(EP, "prefix", function () { return null; });
    getter(EP, "offsetParent", function () { return document.body; });
    getter(EP, "draggable", function () { return false; });
    getter(EP, "spellcheck", function () { return true; });
    getter(EP, "accessKey", function () { return ""; });
    getter(EP, "contentEditable", function () { return "inherit"; });
    getter(EP, "isContentEditable", function () { return false; });
    getter(EP, "inert", function () { return false; });
    getter(EP, "slot", function () { return ""; });
    getter(EP, "assignedSlot", function () { return null; });
    // a shadow root here is a fragment that is kept, but not drawn
    addTo(EP, "attachShadow", function (init) {
      var root = document.createDocumentFragment();
      root.host = this; root.mode = (init && init.mode) || "open";
      this.__shadow = root;
      return root;
    });
    getter(EP, "shadowRoot", function () { return this.__shadow && this.__shadow.mode === "open" ? this.__shadow : null; });

    var DP = Object.getPrototypeOf(document);
    addTo(DP, "createElementNS", function (ns, tag) { return document.createElement(tag); });
    addTo(DP, "importNode", function (n, deep) { return n.cloneNode(deep); });
    addTo(DP, "adoptNode", function (n) { return n; });
    addTo(DP, "elementFromPoint", function () { return null; });
    addTo(DP, "elementsFromPoint", function () { return []; });
    addTo(DP, "getElementsByName", function (n) { return document.querySelectorAll('[name="' + n + '"]'); });
    addTo(DP, "compareDocumentPosition", function (a, b) {
      if (a === b) return 0;
      if (a.contains && a.contains(b)) return 20;
      if (b.contains && b.contains(a)) return 10;
      return 4;
    });
    addTo(DP, "createRange", function () {
      var r = { startContainer: document, endContainer: document, startOffset: 0, endOffset: 0, collapsed: true, commonAncestorContainer: document };
      r.setStart = function (n, o) { r.startContainer = n; r.startOffset = o; };
      r.setEnd = function (n, o) { r.endContainer = n; r.endOffset = o; };
      r.setStartBefore = r.setStartAfter = r.setEndBefore = r.setEndAfter = function () {};
      r.selectNode = r.selectNodeContents = function (n) { r.startContainer = r.endContainer = r.commonAncestorContainer = n; };
      r.collapse = function () {}; r.deleteContents = function () {}; r.detach = function () {};
      r.cloneRange = function () { return document.createRange(); };
      r.getBoundingClientRect = function () { return r.commonAncestorContainer.getBoundingClientRect ? r.commonAncestorContainer.getBoundingClientRect() : { x: 0, y: 0, width: 0, height: 0, top: 0, left: 0, right: 0, bottom: 0 }; };
      r.getClientRects = function () { return []; };
      r.toString = function () { return ""; };
      r.createContextualFragment = function (html) { var t = document.createElement("template"); t.innerHTML = html; var f = document.createDocumentFragment(); while (t.firstChild) f.appendChild(t.firstChild); return f; };
      return r;
    });
    function defDoc(name, fn) { if (!(name in document)) Object.defineProperty(document, name, { get: fn, configurable: true }); }
    defDoc("scrollingElement", function () { return document.documentElement; });
    defDoc("styleSheets", function () { return []; });
    defDoc("adoptedStyleSheets", function () { return []; });
    defDoc("forms", function () { return document.querySelectorAll("form"); });
    defDoc("images", function () { return document.querySelectorAll("img"); });
    defDoc("links", function () { return document.querySelectorAll("a[href], area[href]"); });
    defDoc("scripts", function () { return document.querySelectorAll("script"); });
    defDoc("all", function () { return document.querySelectorAll("*"); });
    defDoc("dir", function () { return "ltr"; });
    defDoc("designMode", function () { return "off"; });
    defDoc("lastModified", function () { return new Date().toString(); });
    defDoc("domain", function () { return location.hostname; });
    defDoc("implementation", function () {
      return {
        hasFeature: function () { return true; },
        createHTMLDocument: function (title) {
          var html = document.createElement("html"), head = document.createElement("head"), body = document.createElement("body");
          html.appendChild(head); html.appendChild(body);
          return { documentElement: html, head: head, body: body, title: title || "",
            createElement: function (t) { return document.createElement(t); }, createTextNode: function (t) { return document.createTextNode(t); },
            createDocumentFragment: function () { return document.createDocumentFragment(); },
            querySelector: function (s) { return html.querySelector(s); }, querySelectorAll: function (s) { return html.querySelectorAll(s); },
            getElementById: function (id) { return html.querySelector("#" + id); }, getElementsByTagName: function (t) { return html.getElementsByTagName(t); },
            implementation: document.implementation };
        }
      };
    });

    // ── window ───────────────────────────────────────────────
    def("cancelAnimationFrame", function (id) { clearTimeout(id); });
    def("postMessage", function (data, origin) { setTimeout(function () { var e = new Event("message"); e.data = data; e.origin = location.origin; e.source = g; g.dispatchEvent(e); }, 0); });
    def("open", function () { return null; });
    def("close", function () {});
    def("stop", function () {});
    def("confirm", function () { return false; });
    def("prompt", function () { return null; });
    def("reportError", function (e) { console.error(e); });
    def("screen", { width: 1440, height: 900, availWidth: 1440, availHeight: 900, colorDepth: 24, pixelDepth: 24, orientation: { type: "landscape-primary", angle: 0 } });
    def("visualViewport", { width: g.innerWidth, height: g.innerHeight, scale: 1, offsetLeft: 0, offsetTop: 0, pageLeft: 0, pageTop: 0, addEventListener: function () {}, removeEventListener: function () {} });
    def("screenX", 0); def("screenY", 0); def("screenLeft", 0); def("screenTop", 0); def("status", ""); def("orientation", 0);
    def("clientInformation", navigator); def("find", function () { return false; });
    def("origin", location.origin);
    def("length", 0);
    def("escape", function (s) { return encodeURIComponent(s).replace(/[!'()*]/g, function (c) { return "%" + c.charCodeAt(0).toString(16).toUpperCase(); }); });
    def("unescape", function (s) { return decodeURIComponent(s); });

    function evClass(name, fields) {
      def(name, function (type, init) {
        var e = new Event(type, init); init = init || {};
        fields.forEach(function (f) { e[f] = init[f] === undefined ? null : init[f]; });
        return e;
      });
    }
    evClass("MessageEvent", ["data", "origin", "source", "lastEventId", "ports"]);
    evClass("ErrorEvent", ["message", "filename", "lineno", "colno", "error"]);
    evClass("PromiseRejectionEvent", ["promise", "reason"]);
    evClass("PopStateEvent", ["state"]);
    evClass("HashChangeEvent", ["oldURL", "newURL"]);
    evClass("PointerEvent", ["pointerId", "pointerType", "clientX", "clientY", "button", "buttons"]);
    evClass("TouchEvent", ["touches", "targetTouches", "changedTouches"]);

    ["NodeList", "HTMLCollection", "DOMTokenList", "CSSStyleSheet", "CSSStyleDeclaration", "Range", "Selection", "Window", "ReadableStream", "WritableStream", "TransformStream"].forEach(function (n) { def(n, function () {}); });

    function Blob(parts, opts) {
      parts = parts || []; var text = "";
      for (var i = 0; i < parts.length; i++) text += typeof parts[i] === "string" ? parts[i] : (parts[i] && parts[i]._text !== undefined ? parts[i]._text : String(parts[i]));
      this._text = text; this.size = text.length; this.type = (opts && opts.type) || "";
    }
    Blob.prototype.text = function () { return Promise.resolve(this._text); };
    Blob.prototype.arrayBuffer = function () { return Promise.resolve(new TextEncoder().encode(this._text).buffer); };
    Blob.prototype.slice = function (a, b, t) { return new Blob([this._text.slice(a, b)], { type: t }); };
    function File(parts, name, opts) { Blob.call(this, parts, opts); this.name = name; this.lastModified = Date.now(); }
    File.prototype = Object.create(Blob.prototype); File.prototype.constructor = File;
    function FileReader() { this.readyState = 0; this.result = null; }
    FileReader.prototype.readAsText = function (b) { var self = this; setTimeout(function () { self.result = b._text; self.readyState = 2; if (self.onload) self.onload({ target: self }); if (self.onloadend) self.onloadend({ target: self }); }, 0); };
    FileReader.prototype.readAsDataURL = function (b) { var self = this; setTimeout(function () { self.result = "data:" + (b.type || "application/octet-stream") + ";base64," + btoa(b._text); self.readyState = 2; if (self.onload) self.onload({ target: self }); if (self.onloadend) self.onloadend({ target: self }); }, 0); };
    FileReader.prototype.addEventListener = function (t, f) { this["on" + t] = f; };
    def("Blob", Blob); def("File", File); def("FileReader", FileReader);

    function FormData(form) {
      this._e = [];
      if (form && form.elements) {
        for (var i = 0; i < form.elements.length; i++) {
          var el = form.elements[i];
          if (!el.name || el.disabled) continue;
          if ((el.type === "checkbox" || el.type === "radio") && !el.checked) continue;
          if (el.type === "submit" || el.type === "button") continue;
          this._e.push([el.name, el.value]);
        }
      }
    }
    FormData.prototype.append = function (k, v) { this._e.push([String(k), v]); };
    FormData.prototype.set = function (k, v) { this["delete"](k); this._e.push([String(k), v]); };
    FormData.prototype.get = function (k) { for (var i = 0; i < this._e.length; i++) if (this._e[i][0] === k) return this._e[i][1]; return null; };
    FormData.prototype.getAll = function (k) { return this._e.filter(function (e) { return e[0] === k; }).map(function (e) { return e[1]; }); };
    FormData.prototype.has = function (k) { return this.get(k) !== null; };
    FormData.prototype["delete"] = function (k) { this._e = this._e.filter(function (e) { return e[0] !== k; }); };
    FormData.prototype.forEach = function (cb) { this._e.forEach(function (e) { cb(e[1], e[0]); }); };
    FormData.prototype.entries = function () { return this._e.slice()[Symbol.iterator](); };
    FormData.prototype[Symbol.iterator] = FormData.prototype.entries;
    def("FormData", FormData);

    def("DOMParser", function () { this.parseFromString = function (html) { var d = document.implementation.createHTMLDocument(""); d.body.innerHTML = html; return d; }; });
    def("XMLSerializer", function () { this.serializeToString = function (n) { return n.outerHTML !== undefined ? n.outerHTML : String(n); }; });
    def("Option", function (text, value) { var o = document.createElement("option"); if (text !== undefined) o.textContent = text; if (value !== undefined) o.value = value; return o; });
    def("Audio", function (src) { var a = document.createElement("audio"); if (src) a.src = src; a.play = function () { return Promise.resolve(); }; a.pause = function () {}; return a; });

    def("Headers", Headers); def("Response", Response); def("Request", Request); def("fetch", fetchImpl);
    def("XMLHttpRequest", XMLHttpRequest);
    def("AbortController", AbortController); def("AbortSignal", AbortSignal); def("DOMException", DOMException);
    def("MutationObserver", MutationObserver); def("ResizeObserver", ResizeObserver); def("IntersectionObserver", IntersectionObserver);
  })(globalThis);
  """

  defp program do
    case :persistent_term.get({__MODULE__, :ast}, nil) do
      nil ->
        with {:ok, ast} <- Parser.parse(@prelude) do
          :persistent_term.put({__MODULE__, :ast}, {:ok, ast})
          {:ok, ast}
        end

      cached ->
        cached
    end
  end
end
