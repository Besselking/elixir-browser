// The global scope of a dedicated worker (see Browser.JS.Worker): what a worker has that the
// page's window does not (postMessage to the page, importScripts, close), and without the
// names that only a page has.
(function (g) {
  "use strict";

  // (plain assignment: the window already has some of these names, and defining over them does not take)
  function hide(name, value) { g[name] = value; }

  hide("postMessage", function postMessage(message, transfer) {
    if (arguments.length === 0) throw new TypeError("Failed to execute 'postMessage' on 'DedicatedWorkerGlobalScope': 1 argument required, but only 0 present.");
    __wk_post(g.__structuredEncode(message));
  });
  hide("close", function close() { __wk_close(); });
  hide("importScripts", function importScripts() {
    for (var i = 0; i < arguments.length; i++) __wk_import(new URL(String(arguments[i]), g.location.href).href);
  });
  hide("name", __wk_name());

  var ctx = g;
  __wk_hook(function (text) {
    var data;
    try { data = g.__structuredDecode(text); }
    catch (e) { g.dispatchEvent(new MessageEvent("messageerror", {})); return; }
    g.dispatchEvent(new MessageEvent("message", { data: data, origin: "", source: null, ports: [] }));
  });
})(globalThis);
