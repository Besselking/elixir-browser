defmodule Browser.JS.WebAPI do
  @moduledoc """
  The web platform pieces that scripts expect beside the DOM: `fetch`, `XMLHttpRequest`, the
  observers, `AbortController`, `atob`/`btoa`, `document.fonts` and a few more. They are
  written in JavaScript (the `@prelude`), on top of one native function, `__fetch`, that does
  a request and hands back what came.
  """

  alias Browser.JS.{Interp, Parser}

  @methods ~w(get head post put patch delete options)

  @doc """
  Declares `__fetch` and runs the prelude. `http` is `(request) -> {:ok, response} | {:error, msg}`;
  see `Browser.JS.Runtime.http/1`.
  """
  def install(scope, http) do
    Interp.declare(
      scope,
      "__fetch",
      Interp.native("__fetch", fn _this, args ->
        arg = &Enum.at(args, &1, :undefined)

        method = arg.(0) |> Interp.to_str() |> String.downcase()
        method = if method in @methods, do: String.to_atom(method), else: :get

        request = %{
          method: method,
          url: arg.(1) |> Interp.to_str(),
          body: body_text(arg.(2)),
          headers: pairs(arg.(3)),
          content_type: body_text(arg.(4)),
          credentials: credentials(arg.(5))
        }

        case http.(request) do
          {:ok, r} ->
            Interp.new_object([
              {"status", r.status * 1.0},
              {"statusText", r.status_text},
              {"url", r.url},
              {"body", r.body},
              {"redirected", r.redirected},
              {"headers", Interp.new_array(for {k, v} <- r.headers, do: Interp.new_array([k, v]))}
            ])

          {:error, msg} ->
            Interp.throw_error("TypeError", "Failed to fetch: #{msg}")
        end
      end)
    )

    case program() do
      {:ok, ast} -> Interp.run_program(ast)
      {:error, msg} -> throw({:syntax, "web api prelude: " <> msg})
    end
  end

  defp pairs({:obj, _} = list) do
    for pair <- Interp.array_list(list),
        [k, v] <- [Interp.array_list(pair)],
        do: {Interp.to_str(k), Interp.to_str(v)}
  end

  defp pairs(_), do: []

  defp credentials(v) do
    case body_text(v) do
      "omit" -> :omit
      "include" -> :include
      _ -> :same_origin
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

    // what a request body is sent as: `[text, content type]`
    function encodeBody(body) {
      if (body === undefined || body === null) return [null, null];
      if (typeof body === "string") return [body, "text/plain;charset=UTF-8"];
      if (typeof URLSearchParams === "function" && body instanceof URLSearchParams) return [body.toString(), "application/x-www-form-urlencoded;charset=UTF-8"];
      if (body instanceof Blob) return [body._text, body.type || null];
      if (body instanceof FormData) {
        var boundary = "----ElixirBrowserFormBoundary" + Math.random().toString(36).slice(2);
        var out = "";
        body._e.forEach(function (e) {
          var v = e[1];
          out += "--" + boundary + "\r\nContent-Disposition: form-data; name=\"" + e[0] + "\"";
          if (v instanceof Blob) out += "; filename=\"" + (v.name || "blob") + "\"\r\nContent-Type: " + (v.type || "application/octet-stream") + "\r\n\r\n" + v._text;
          else out += "\r\n\r\n" + v;
          out += "\r\n";
        });
        return [out + "--" + boundary + "--\r\n", "multipart/form-data; boundary=" + boundary];
      }
      if (typeof ArrayBuffer === "function" && (body instanceof ArrayBuffer || ArrayBuffer.isView(body))) {
        return [new TextDecoder().decode(body), "application/octet-stream"];
      }
      return [String(body), "text/plain;charset=UTF-8"];
    }

    // runs a request now: `{ status, statusText, url, body, headers, redirected }`; a failure throws
    function send(method, url, body, headers, credentials) {
      var enc = encodeBody(body);
      var list = [], ctype = enc[1];
      headers.forEach(function (v, k) { if (k === "content-type") ctype = v; else list.push([k, v]); });
      if (enc[0] === null) ctype = null;
      return __fetch(method, new URL(url, document.baseURI || location.href).href, enc[0], list, ctype, credentials);
    }

    function Response(body, init) {
      init = init || {};
      this._body = body === undefined || body === null ? "" : String(body);
      this.status = init.status === undefined ? 200 : init.status;
      this.ok = this.status >= 200 && this.status < 300;
      this.statusText = init.statusText === undefined ? "" : init.statusText;
      this.url = init.url || "";
      this.type = "default";
      this.redirected = !!init.redirected;
      this.bodyUsed = false;
      this.headers = new Headers(init.headers);
      if (typeof body === "string" && !this.headers.has("content-type")) this.headers.set("content-type", "text/plain;charset=UTF-8");
    }
    Response.prototype._read = function () {
      if (this.bodyUsed) return Promise.reject(new TypeError("body stream already read"));
      this.bodyUsed = true;
      return Promise.resolve(this._body);
    };
    Response.prototype.text = function () { return this._read(); };
    Response.prototype.json = function () { return this._read().then(function (t) { return JSON.parse(t); }); };
    Response.prototype.arrayBuffer = function () { return this._read().then(function (t) { return new TextEncoder().encode(t).buffer; }); };
    Response.prototype.blob = function () { var type = this.headers.get("content-type") || ""; return this._read().then(function (t) { return new Blob([t], { type: type }); }); };
    Response.prototype.formData = function () { return this._read().then(function (t) { var fd = new FormData(); new URLSearchParams(t).forEach(function (v, k) { fd.append(k, v); }); return fd; }); };
    Response.prototype.clone = function () {
      if (this.bodyUsed) throw new TypeError("Response body is already used");
      var r = new Response(this._body, { status: this.status, statusText: this.statusText, url: this.url, headers: this.headers, redirected: this.redirected });
      r.type = this.type;
      return r;
    };
    Response.error = function () { var r = new Response("", { status: 0 }); r.type = "error"; return r; };
    Response.json = function (data, init) { init = init || {}; var r = new Response(JSON.stringify(data), init); r.headers.set("content-type", "application/json"); return r; };

    function Request(input, init) {
      init = init || {};
      var base = input instanceof Request ? input : null;
      this.url = base ? base.url : (typeof input === "string" ? input : (input && input.href) || String(input));
      this.method = String(init.method || (base && base.method) || "GET").toUpperCase();
      this.headers = new Headers(init.headers || (base && base.headers));
      this.body = init.body === undefined ? (base ? base.body : null) : init.body;
      this.signal = init.signal || (base && base.signal) || null;
      this.credentials = init.credentials || (base && base.credentials) || "same-origin";
      this.mode = init.mode || "cors";
      this.cache = init.cache || "default";
      this.redirect = init.redirect || "follow";
      this.referrer = init.referrer || "about:client";
      if (this.body !== null && (this.method === "GET" || this.method === "HEAD")) throw new TypeError("Request with GET/HEAD method cannot have body.");
    }
    Request.prototype.clone = function () { return new Request(this); };
    Request.prototype.text = function () { return Promise.resolve(this.body === null ? "" : encodeBody(this.body)[0]); };
    Request.prototype.json = function () { return this.text().then(function (t) { return JSON.parse(t); }); };

    function abortError(signal) { return signal.reason !== undefined ? signal.reason : new DOMException("The operation was aborted.", "AbortError"); }

    function fetchImpl(input, init) {
      return new Promise(function (resolve, reject) {
        var req;
        try { req = new Request(input, init); } catch (e) { reject(e); return; }
        if (req.signal && req.signal.aborted) { reject(abortError(req.signal)); return; }
        var settled = false;
        function onabort() { if (!settled) { settled = true; reject(abortError(req.signal)); } }
        if (req.signal) req.signal.addEventListener("abort", onabort);
        // the request goes out after the caller has had its turn, so `abort()` right after `fetch()` wins
        setTimeout(function () {
          if (settled) return;
          var r;
          try { r = send(req.method, req.url, req.body, req.headers, req.credentials); }
          catch (e) { settled = true; reject(new TypeError("Failed to fetch")); return; }
          if (settled) return;
          settled = true;
          if (req.signal) req.signal.removeEventListener("abort", onabort);
          var res = new Response(r.body, { status: r.status, statusText: r.statusText, url: r.url, redirected: r.redirected, headers: r.headers });
          res.type = "basic";
          resolve(res);
        }, 0);
      });
    }

    function XMLHttpRequest() {
      this.readyState = 0; this.status = 0; this.statusText = ""; this.responseText = ""; this.response = "";
      this.responseType = ""; this.responseURL = ""; this.responseXML = null; this.timeout = 0; this.withCredentials = false;
      this._l = {}; this._headers = new Headers(); this._method = "GET"; this._url = ""; this._async = true; this._rh = new Headers();
      this.upload = { addEventListener: function () {}, removeEventListener: function () {} };
    }
    XMLHttpRequest.UNSENT = 0; XMLHttpRequest.OPENED = 1; XMLHttpRequest.HEADERS_RECEIVED = 2; XMLHttpRequest.LOADING = 3; XMLHttpRequest.DONE = 4;
    XMLHttpRequest.prototype.open = function (method, url, async) {
      this._method = String(method).toUpperCase(); this._url = String(url); this._async = async !== false;
      this._headers = new Headers(); this._sent = false; this._aborted = false;
      this.readyState = 1; this._fire("readystatechange");
    };
    XMLHttpRequest.prototype.setRequestHeader = function (k, v) {
      if (this.readyState !== 1 || this._sent) throw new DOMException("The object's state must be OPENED.", "InvalidStateError");
      this._headers.append(k, v);
    };
    XMLHttpRequest.prototype.getResponseHeader = function (k) { return this.readyState < 2 ? null : this._rh.get(k); };
    XMLHttpRequest.prototype.getAllResponseHeaders = function () {
      if (this.readyState < 2) return "";
      var out = ""; this._rh.forEach(function (v, k) { out += k + ": " + v + "\r\n"; }); return out;
    };
    XMLHttpRequest.prototype.overrideMimeType = function () {};
    XMLHttpRequest.prototype.abort = function () {
      var was = this.readyState;
      this._aborted = true;
      if (this._sent && was !== 4 && was !== 0) {
        this.readyState = 4; this._fire("readystatechange"); this._fire("abort"); this._fire("loadend");
      }
      this.readyState = 0; this.status = 0;
    };
    XMLHttpRequest.prototype.addEventListener = function (t, f) { (this._l[t] = this._l[t] || []).push(f); };
    XMLHttpRequest.prototype.removeEventListener = function (t, f) { var a = this._l[t]; if (a) { var i = a.indexOf(f); if (i >= 0) a.splice(i, 1); } };
    XMLHttpRequest.prototype._fire = function (type, extra) {
      var ev = { type: type, target: this, currentTarget: this, lengthComputable: false, loaded: 0, total: 0 };
      if (type === "load" || type === "loadend") { ev.loaded = ev.total = this.responseText.length; ev.lengthComputable = true; }
      var h = this["on" + type]; if (typeof h === "function") { try { h.call(this, ev); } catch (e) { console.error(e); } }
      var a = this._l[type]; if (a) a.slice().forEach(function (f) { try { f.call(this, ev); } catch (e) { console.error(e); } }, this);
    };
    XMLHttpRequest.prototype._run = function (body) {
      var self = this;
      if (self._aborted) return;
      var cred = self.withCredentials ? "include" : "same-origin";
      var r = null;
      try { r = send(self._method, self._url, body, self._headers, cred); } catch (e) { r = null; }
      if (self._aborted) return;
      if (r === null) {
        self.readyState = 4; self.status = 0; self.statusText = "";
        self._fire("readystatechange"); self._fire("error"); self._fire("loadend");
        return;
      }
      self.status = r.status; self.statusText = r.statusText; self.responseURL = r.url;
      self._rh = new Headers(r.headers);
      self.readyState = 2; self._fire("readystatechange");
      self.readyState = 3; self._fire("readystatechange");
      self.responseText = r.body;
      var type = self.responseType;
      if (type === "json") { try { self.response = JSON.parse(r.body); } catch (e) { self.response = null; } }
      else if (type === "arraybuffer") self.response = new TextEncoder().encode(r.body).buffer;
      else if (type === "blob") self.response = new Blob([r.body], { type: self._rh.get("content-type") || "" });
      else if (type === "document") { try { self.response = new DOMParser().parseFromString(r.body, "text/html"); } catch (e) { self.response = null; } }
      else self.response = r.body;
      self.readyState = 4;
      self._fire("readystatechange"); self._fire("load"); self._fire("loadend");
    };
    XMLHttpRequest.prototype.send = function (body) {
      var self = this;
      if (self.readyState !== 1 || self._sent) throw new DOMException("The object's state must be OPENED.", "InvalidStateError");
      self._sent = true;
      self._fire("loadstart");
      if (!self._async) { self._run(body); return; }
      setTimeout(function () { self._run(body); }, 0);
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
    AbortSignal.timeout = function (ms) {
      var c = new AbortController();
      setTimeout(function () { c.abort(new DOMException("The operation timed out.", "TimeoutError")); }, ms);
      return c.signal;
    };

    var domCodes = { IndexSizeError: 1, HierarchyRequestError: 3, WrongDocumentError: 4, InvalidCharacterError: 5, NoModificationAllowedError: 7,
      NotFoundError: 8, NotSupportedError: 9, InUseAttributeError: 10, InvalidStateError: 11, SyntaxError: 12, InvalidModificationError: 13,
      NamespaceError: 14, InvalidAccessError: 15, TypeMismatchError: 17, SecurityError: 18, NetworkError: 19, AbortError: 20, URLMismatchError: 21,
      QuotaExceededError: 22, TimeoutError: 23, InvalidNodeTypeError: 24, DataCloneError: 25 };
    function DOMException(message, name) { this.message = message || ""; this.name = name || "Error"; this.code = domCodes[this.name] || 0; }
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

    if (typeof URL === "function") {
      if (!URL.canParse) URL.canParse = function canParse(u, b) { try { new URL(u, b); return true; } catch (e) { return false; } };
      if (!URL.parse) URL.parse = function parse(u, b) { try { return new URL(u, b); } catch (e) { return null; } };
    }

    // indexedDB and its classes are in priv/js/indexeddb.js, which replaces these on first use;
    // so does structuredClone (it needs the same tagged form)
    ["indexedDB", "IDBFactory", "IDBDatabase", "IDBObjectStore", "IDBIndex", "IDBCursor", "IDBCursorWithValue", "IDBRecord", "IDBTransaction",
     "IDBRequest", "IDBOpenDBRequest", "IDBKeyRange", "IDBVersionChangeEvent"].forEach(function (n) {
      Object.defineProperty(g, n, { configurable: true, enumerable: false,
        get: function () { __load_idb(); var d = Object.getOwnPropertyDescriptor(g, n); return d && "value" in d ? d.value : undefined; },
        set: function (v) { Object.defineProperty(g, n, { value: v, writable: true, configurable: true }); } });
    });
    def("structuredClone", function structuredClone(v) {
      if (arguments.length === 0) throw new TypeError("structuredClone requires 1 argument.");
      __load_idb();
      return g.__structuredClone(v);
    });

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

    // ranges, the selection and execCommand are in priv/js/editing.js, loaded on first use
    var editing = (function () {
      var loaded = false;
      function load() { if (!loaded) { loaded = true; __load_editing(); } }
      function lazy(obj, name, onGlobal) {
        Object.defineProperty(obj, name, { value: function () {
          load();
          var real = obj[name];
          return real.apply(onGlobal ? g : this, arguments);
        }, writable: true, configurable: true, enumerable: false });
      }
      lazy(g, "getSelection", true);
      return { load: load, lazy: lazy };
    })();

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
      var nav = navigator;
      function setNav(k, v) { if (nav[k] === undefined) nav[k] = v; }
      var ua = String(nav.userAgent || "");
      setNav("appCodeName", "Mozilla");
      setNav("appName", "Netscape");
      setNav("appVersion", ua.replace(/^Mozilla\//, ""));
      setNav("product", "Gecko");
      setNav("productSub", "20030107");
      setNav("vendorSub", "");
      setNav("cookieEnabled", true);
      setNav("doNotTrack", null);
      setNav("webdriver", false);
      setNav("hardwareConcurrency", 4);
      setNav("deviceMemory", 8);
      setNav("maxTouchPoints", 0);
      setNav("pdfViewerEnabled", false);
      setNav("plugins", []);
      setNav("mimeTypes", []);
      setNav("userAgentData", undefined);
      setNav("javaEnabled", function () { return false; });
      setNav("sendBeacon", function () { return true; });
      setNav("vibrate", function () { return false; });
      setNav("connection", { effectiveType: "4g", downlink: 10, rtt: 50, saveData: false, addEventListener: function () {}, removeEventListener: function () {} });
      // nothing here asks the person for permission, so the answer is always no
      function denied(cb) { return new Promise(function (res, rej) { rej(new DOMException("User denied permission.", "NotAllowedError")); }); }
      setNav("permissions", { query: function (d) { return Promise.resolve({ name: d && d.name, state: "denied", onchange: null, addEventListener: function () {}, removeEventListener: function () {} }); } });
      setNav("geolocation", {
        getCurrentPosition: function (ok, err) { if (typeof err === "function") setTimeout(function () { err({ code: 1, message: "User denied Geolocation", PERMISSION_DENIED: 1, POSITION_UNAVAILABLE: 2, TIMEOUT: 3 }); }, 0); },
        watchPosition: function (ok, err) { if (typeof err === "function") setTimeout(function () { err({ code: 1, message: "User denied Geolocation", PERMISSION_DENIED: 1, POSITION_UNAVAILABLE: 2, TIMEOUT: 3 }); }, 0); return 1; },
        clearWatch: function () {}
      });
      setNav("mediaDevices", { enumerateDevices: function () { return Promise.resolve([]); }, getUserMedia: denied, getSupportedConstraints: function () { return {}; }, addEventListener: function () {}, removeEventListener: function () {} });
      // the clipboard holds what the page wrote to it, until the page is closed
      var clip = "";
      setNav("clipboard", { writeText: function (t) { clip = String(t); return Promise.resolve(); }, readText: function () { return Promise.resolve(clip); }, write: denied, read: denied });
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
    if (!("inert" in EP)) Object.defineProperty(EP, "inert", {
      get: function () { return this.hasAttribute("inert"); },
      set: function (v) { if (v) this.setAttribute("inert", ""); else this.removeAttribute("inert"); },
      configurable: true
    });
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
    ["createRange", "execCommand", "queryCommandState", "queryCommandEnabled", "queryCommandValue", "queryCommandSupported", "queryCommandIndeterm", "getSelection"].forEach(function (n) { editing.lazy(DP, n, false); });
    function Range() { editing.load(); return new g.Range(); }
    function Selection() {}
    def("Range", Range); def("Selection", Selection);
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
    // <dialog>: shown while it has the open attribute; showModal() puts it in the top layer
    // (see Browser.Modal) and makes the rest of the page inert
    if (typeof HTMLDialogElement === "function") {
      var DP = HTMLDialogElement.prototype;
      // the open modal dialogs, oldest first (one whose open attribute was removed is not one)
      var modals = [];
      function openModals() {
        modals = modals.filter(function (d) { return d.matches(":modal"); });
        return modals;
      }
      function fireLater(el, type) {
        setTimeout(function () { el.dispatchEvent(new Event(type, { bubbles: false, cancelable: false })); }, 0);
      }
      function focusable(el) {
        if (el.hasAttribute("disabled") || el.hasAttribute("inert") || el.hidden) return false;
        var t = el.tagName.toLowerCase();
        if (t === "input") return el.getAttribute("type") !== "hidden";
        if (t === "select" || t === "textarea" || t === "button") return true;
        if (t === "a" || t === "area") return el.hasAttribute("href");
        var ce = el.getAttribute("contenteditable");
        if (ce !== null && ce !== "false") return true;
        return el.hasAttribute("tabindex") && Number(el.getAttribute("tabindex")) >= 0;
      }
      // the dialog focusing steps: the first element with autofocus, else the first one that can
      // take focus (a link is not given focus by this browser, so it is only a fallback)
      function focusInto(dlg, modal) {
        if (dlg.closest("[inert]")) {
          var active = document.activeElement;
          if (modal && active && active !== document.body && active.blur) active.blur();
          return;
        }
        var all = dlg.querySelectorAll("*"), first = null, i;
        for (i = 0; i < all.length; i++) {
          if (all[i].hasAttribute("autofocus") && focusable(all[i])) { all[i].focus(); return; }
        }
        for (i = 0; i < all.length; i++) {
          var t = all[i].tagName.toLowerCase();
          if (focusable(all[i]) && t !== "a" && t !== "area") { first = all[i]; break; }
        }
        (first || dlg).focus();
      }
      function closeDialog(dlg, value) {
        if (!dlg.hasAttribute("open")) return;
        if (value !== undefined) returnValues.set(dlg, String(value));
        dlg.__setModal(false);
        dlg.removeAttribute("open");
        fireLater(dlg, "close");
      }
      // the value lives in a slot of its own, so a property a script sets on the element is not hit
      var returnValues = new WeakMap();
      Object.defineProperty(DP, "returnValue", {
        get: function () { return returnValues.has(this) ? returnValues.get(this) : ""; },
        set: function (v) { returnValues.set(this, String(v)); },
        configurable: true
      });
      DP.show = function () {
        if (this.hasAttribute("open")) {
          if (this.matches(":modal")) throw new DOMException("The dialog is already open as a modal dialog.", "InvalidStateError");
          return;
        }
        this.setAttribute("open", "");
        if (this.isConnected) focusInto(this, false);
      };
      DP.showModal = function () {
        if (this.hasAttribute("open")) {
          if (this.matches(":modal")) return;
          throw new DOMException("The dialog is already open as a non-modal dialog.", "InvalidStateError");
        }
        if (!this.isConnected) throw new DOMException("The element is not connected.", "InvalidStateError");
        this.setAttribute("open", "");
        modals.push(this);
        this.__setModal(true);
        focusInto(this, true);
      };
      DP.close = function (value) { closeDialog(this, value); };
      var requesting = new WeakSet();
      DP.requestClose = function (value) {
        if (!this.hasAttribute("open") || !this.isConnected || requesting.has(this)) return;
        var e = new Event("cancel", { bubbles: false, cancelable: true });
        var ok;
        requesting.add(this);
        try { ok = this.dispatchEvent(e); } finally { requesting.delete(this); }
        if (ok) closeDialog(this, value);
      };
      Object.defineProperty(DP, "closedBy", {
        get: function () {
          var v = (this.getAttribute("closedby") || "").toLowerCase();
          return v === "any" || v === "closerequest" || v === "none" ? v : "auto";
        },
        set: function (v) { this.setAttribute("closedby", String(v)); }, configurable: true
      });
      // what the window does for Escape: ask the topmost modal dialog to close
      g.__dialogEscape = function () {
        if (g.__popoverEscape && g.__popoverEscape()) return true;
        var open = openModals(), dlg = open[open.length - 1];
        if (!dlg) return false;
        var by = dlg.closedBy;
        if (by === "none") return true;
        var e = new Event("cancel", { bubbles: false, cancelable: true });
        if (dlg.dispatchEvent(e)) closeDialog(dlg);
        return true;
      };
      // a click on the backdrop: closes a dialog that says closedby="any"
      g.__dialogBackdrop = function (dlg) {
        if (dlg && dlg.closedBy === "any" && dlg.hasAttribute("open")) {
          var e = new Event("cancel", { bubbles: false, cancelable: true });
          if (dlg.dispatchEvent(e)) closeDialog(dlg);
        }
      };
      // <form method="dialog">: the submitter's value closes the dialog
      g.__dialogSubmit = function (form, submitter) {
        var dlg = form.closest("dialog");
        if (!dlg) return;
        var value = submitter && submitter.hasAttribute("value") ? submitter.getAttribute("value") : undefined;
        closeDialog(dlg, value);
      };
    }
    // the Popover API: a `popover` element in the top layer, hidden again by Escape or a click elsewhere
    (function () {
      var stack = [];
      function type(el) {
        var v = el.getAttribute("popover");
        if (v === null) return null;
        v = v.toLowerCase();
        return v === "" || v === "auto" ? "auto" : v === "hint" ? "hint" : "manual";
      }
      function shown() {
        stack = stack.filter(function (p) { return p.matches(":popover-open"); });
        return stack;
      }
      function toggleEvent(el, name, oldState, newState, cancelable) {
        var e = new Event(name, { bubbles: false, cancelable: cancelable });
        e.oldState = oldState; e.newState = newState;
        return el.dispatchEvent(e);
      }
      function later(el, oldState, newState) {
        setTimeout(function () { toggleEvent(el, "toggle", oldState, newState, false); }, 0);
      }
      // false: nothing to do; throws when the element cannot be one
      function valid(el) {
        if (type(el) === null) throw new DOMException("The element has no popover attribute.", "NotSupportedError");
        if (!el.isConnected) throw new DOMException("The element is not connected.", "InvalidStateError");
        if (el.matches("dialog:modal")) throw new DOMException("The element is a modal dialog.", "InvalidStateError");
      }
      function hide(el, fireEvents) {
        if (!el.matches(":popover-open")) return;
        // what was opened above it goes first
        var i = shown().indexOf(el);
        if (i >= 0) stack.slice(i + 1).reverse().forEach(function (p) { hide(p, true); });
        if (fireEvents) toggleEvent(el, "beforetoggle", "open", "closed", false);
        el.__setPopover(false);
        stack = stack.filter(function (p) { return p !== el; });
        if (fireEvents) later(el, "open", "closed");
      }
      function show(el) {
        valid(el);
        if (el.matches(":popover-open") || el.matches("dialog[open]")) return;
        if (!toggleEvent(el, "beforetoggle", "closed", "open", true)) return;
        if (el.matches(":popover-open") || !el.isConnected) return;
        if (type(el) === "auto") {
          shown().slice().reverse().forEach(function (p) {
            if (type(p) === "auto" && !p.contains(el)) hide(p, true);
          });
        }
        el.__setPopover(true);
        // manual popovers are not part of the stack that light dismiss and Escape work on
        if (type(el) !== "manual") stack.push(el);
        var all = el.querySelectorAll("[autofocus]");
        for (var i = 0; i < all.length; i++) { all[i].focus(); break; }
        later(el, "closed", "open");
      }
      var P = Element.prototype;
      P.showPopover = function () { show(this); };
      P.hidePopover = function () { valid(this); hide(this, true); };
      P.togglePopover = function (force) {
        valid(this);
        var open = this.matches(":popover-open");
        if (open && force !== true) hide(this, true);
        else if (!open && force !== false) show(this);
        return this.matches(":popover-open");
      };
      Object.defineProperty(P, "popover", {
        get: function () { var t = type(this); return t; },
        set: function (v) { if (v === null) this.removeAttribute("popover"); else this.setAttribute("popover", String(v)); },
        configurable: true
      });
      // a button with popovertarget
      g.__popoverInvoke = function (button) {
        var target = document.getElementById(button.getAttribute("popovertarget"));
        if (!target || type(target) === null) return;
        var action = (button.getAttribute("popovertargetaction") || "toggle").toLowerCase();
        var open = target.matches(":popover-open");
        if (open && action !== "show") hide(target, true);
        else if (!open && action !== "hide") show(target);
      };
      // a click nothing stopped: the button's target, and light dismiss of the other popovers
      g.__popoverClick = function (target) {
        var button = target && target.closest ? target.closest("[popovertarget]") : null;
        var invoked = button ? document.getElementById(button.getAttribute("popovertarget")) : null;
        var open = shown();
        for (var i = open.length - 1; i >= 0; i--) {
          var p = open[i];
          if (type(p) !== "auto") continue;
          if (p === invoked || (target && p.contains(target))) break;
          hide(p, true);
        }
        if (button && !button.hasAttribute("disabled")) g.__popoverInvoke(button);
      };
      g.__popoverEscape = function () {
        var open = shown();
        for (var i = open.length - 1; i >= 0; i--) {
          if (type(open[i]) !== "manual") { hide(open[i], true); return true; }
        }
        return false;
      };
    })();
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

    ["NodeList", "HTMLCollection", "DOMTokenList", "CSSStyleSheet", "CSSStyleDeclaration", "Window"].forEach(function (n) { def(n, function () {}); });

    // streams: enough of the standard for frameworks that read a body or feed data through one
    function ReadableStream(source, strategy) {
      source = source || {};
      var self = this, queue = [], waiting = [], closed = false, errored = false, error, started = false, pulling = false;
      this._locked = false;
      var hwm = strategy && strategy.highWaterMark !== undefined ? strategy.highWaterMark : 1;
      function size() { return queue.length; }
      function settle() {
        while (waiting.length && (queue.length || closed || errored)) {
          var w = waiting.shift();
          if (errored) w.reject(error);
          else if (queue.length) w.resolve({ value: queue.shift(), done: false });
          else w.resolve({ value: undefined, done: true });
        }
      }
      function pull() {
        if (!started || pulling || closed || errored || !source.pull) return;
        if (queue.length >= hwm && !waiting.length) return;
        pulling = true;
        Promise.resolve().then(function () { return source.pull(controller); }).then(function () { pulling = false; settle(); if (waiting.length) pull(); }, function (e) { pulling = false; controller.error(e); });
      }
      var controller = {
        enqueue: function (chunk) { if (closed || errored) throw new TypeError("The stream is closed or errored"); queue.push(chunk); settle(); },
        close: function () { if (closed) return; closed = true; settle(); },
        error: function (e) { if (errored) return; errored = true; error = e; queue = []; settle(); },
        get desiredSize() { return errored ? null : closed ? 0 : hwm - queue.length; }
      };
      this._read = function () {
        return new Promise(function (resolve, reject) { waiting.push({ resolve: resolve, reject: reject }); settle(); pull(); });
      };
      this._cancel = function (reason) { closed = true; queue = []; settle(); return Promise.resolve(source.cancel ? source.cancel(reason) : undefined); };
      this._state = function () { return errored ? "errored" : closed && !queue.length ? "closed" : "readable"; };
      this._error = function () { return error; };
      try {
        var r = source.start ? source.start(controller) : undefined;
        Promise.resolve(r).then(function () { started = true; pull(); }, function (e) { controller.error(e); });
      } catch (e) { controller.error(e); started = true; }
    }
    Object.defineProperty(ReadableStream.prototype, "locked", { get: function () { return this._locked; } });
    ReadableStream.prototype.getReader = function () {
      var stream = this;
      if (stream._locked) throw new TypeError("ReadableStream is locked");
      stream._locked = true;
      var reader = {
        read: function () { return stream._read(); },
        cancel: function (reason) { return stream._cancel(reason); },
        releaseLock: function () { stream._locked = false; },
        get closed() { return new Promise(function () {}); }
      };
      return reader;
    };
    ReadableStream.prototype.cancel = function (reason) { return this._cancel(reason); };
    ReadableStream.prototype.tee = function () {
      var reader = this.getReader(), a, b, ca, cb;
      function pump() { return reader.read().then(function (r) { if (r.done) { ca.close(); cb.close(); } else { ca.enqueue(r.value); cb.enqueue(r.value); return pump(); } }); }
      a = new ReadableStream({ start: function (c) { ca = c; } });
      b = new ReadableStream({ start: function (c) { cb = c; pump(); } });
      return [a, b];
    };
    ReadableStream.prototype.pipeTo = function (dest) {
      var reader = this.getReader(), writer = dest.getWriter();
      function pump() { return reader.read().then(function (r) { if (r.done) return writer.close(); return writer.write(r.value).then(pump); }); }
      return pump();
    };
    ReadableStream.prototype.pipeThrough = function (pair) { this.pipeTo(pair.writable); return pair.readable; };
    ReadableStream.prototype[Symbol.asyncIterator] = function () {
      var reader = this.getReader();
      return { next: function () { return reader.read(); }, return: function () { reader.releaseLock(); return Promise.resolve({ done: true }); }, [Symbol.asyncIterator]: function () { return this; } };
    };
    ReadableStream.from = function (iterable) {
      var it = iterable[Symbol.asyncIterator] ? iterable[Symbol.asyncIterator]() : iterable[Symbol.iterator]();
      return new ReadableStream({ pull: function (c) { return Promise.resolve(it.next()).then(function (r) { if (r.done) c.close(); else c.enqueue(r.value); }); } });
    };

    function WritableStream(sink) {
      sink = sink || {};
      var self = this, controller = { error: function () {} };
      this._locked = false;
      this._ready = Promise.resolve(sink.start ? sink.start(controller) : undefined);
      this._write = function (chunk) { return self._ready = self._ready.then(function () { return sink.write ? sink.write(chunk, controller) : undefined; }); };
      this._close = function () { return self._ready = self._ready.then(function () { return sink.close ? sink.close() : undefined; }); };
      this._abort = function (reason) { return Promise.resolve(sink.abort ? sink.abort(reason) : undefined); };
    }
    Object.defineProperty(WritableStream.prototype, "locked", { get: function () { return this._locked; } });
    WritableStream.prototype.getWriter = function () {
      var stream = this;
      if (stream._locked) throw new TypeError("WritableStream is locked");
      stream._locked = true;
      return {
        write: function (chunk) { return stream._write(chunk); },
        close: function () { return stream._close(); },
        abort: function (reason) { return stream._abort(reason); },
        releaseLock: function () { stream._locked = false; },
        ready: Promise.resolve(), closed: new Promise(function () {}), desiredSize: 1
      };
    };
    WritableStream.prototype.close = function () { return this._close(); };
    WritableStream.prototype.abort = function (reason) { return this._abort(reason); };

    function TransformStream(transformer) {
      transformer = transformer || {};
      var rc;
      var readable = new ReadableStream({ start: function (c) { rc = c; } });
      var tc = { enqueue: function (chunk) { rc.enqueue(chunk); }, error: function (e) { rc.error(e); }, terminate: function () { rc.close(); } };
      if (transformer.start) transformer.start(tc);
      var writable = new WritableStream({
        write: function (chunk) { return transformer.transform ? transformer.transform(chunk, tc) : tc.enqueue(chunk); },
        close: function () { var r = transformer.flush ? transformer.flush(tc) : undefined; return Promise.resolve(r).then(function () { rc.close(); }); }
      });
      this.readable = readable; this.writable = writable;
    }
    def("ReadableStream", ReadableStream); def("WritableStream", WritableStream); def("TransformStream", TransformStream);

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
