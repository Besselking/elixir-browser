# Elixir Browser

A small native GUI web browser written in Elixir: HTTP(S) fetching, a tolerant HTML parser,
a CSS engine (selectors, cascade, `@media`, custom properties, box model) and a text/box
layout, drawn with Erlang's `:wx`.

```bash
mix run --no-halt            # opens the start page: a few sites and the demo pages in priv/demo
BROWSER_URL=https://example.com mix run --no-halt
mix test
mix app.bundle               # macOS: self-contained dist/"Elixir Browser.app"
mix reftest --fetch          # layout/CSS: web-platform-tests reference tests (not part of CI)
```

`mix reftest` lays out each test page and its reference page, paints both with a small
software painter (no window needed) and compares the pixels; `mix help reftest` lists the options
(`--check` against `reftest.baseline`, `--dump DIR` to save the pictures of failing pairs).

Requires Elixir 1.20+ and Erlang/OTP 29+ with the `wx` application; only the latest versions are
supported. `scripts/install-toolchain.sh` installs them (a source build with wx 3.3 on macOS and
Debian/Ubuntu); with asdf or mise, `.tool-versions` pins the same versions.

WebP images need wxWidgets 3.3 or newer with libwebp. With wxWidgets 3.2 the browser shows the alt
text, except on macOS, where it converts WebP with `sips`. Homebrew's `erlang` is linked against
wxWidgets 3.2. On macOS (into `~/.local`) and Debian/Ubuntu, `scripts/install-toolchain.sh` builds wxWidgets 3.3 and OTP's `wx` against it (OTP 29.1.1 needs a few
patches for that, which the script applies).

## Developer console

Press Cmd+Option+J on macOS, or Ctrl+Shift+J on other systems. You can also choose
Develop > Developer Console. A separate window opens.

The window shows the console of the current tab. It shows the output of `console.log`,
`console.info`, `console.warn` and `console.error`. It also shows uncaught errors and
unhandled promise rejections. Each line has a time, and a colour for its level.

Type JavaScript in the input line at the bottom and press Enter. The code runs in the page.
The window shows the value of the code, or the error it threw. The Up and Down keys show the
lines you typed before. The Clear button empties the window.

The console keeps the last 1000 lines of a page. A page that has no scripts has no console.

## Crash reports

Every crash (a process dying, a failing wx callback, `Logger.error`) is saved as a text file with the time, the page that was open, the version and commit, and the stacktrace. They go to `$BROWSER_CRASH_DIR`, else `crashes/` under the user data dir (on macOS `~/Library/Application Support/elixir_browser/crashes`), and the newest 100 are kept. `mix browser.crashes [--show|--clear]` lists, prints or deletes them.

## Proxy

The browser uses a proxy when the usual environment variables are set: `https_proxy`,
`http_proxy` and `no_proxy` (the upper-case names also work). HTTPS pages use a CONNECT
tunnel. Plain HTTP pages use an absolute-form request. A `user:pass@` part in the proxy
URL is sent as `Proxy-Authorization`.

`no_proxy` is a comma-separated list of host names, IP addresses, CIDR ranges or `*`.

TLS checks stay on. If a proxy signs TLS with its own CA, put the CA file in
`SSL_CERT_FILE`. The browser trusts that file and the system store.

## License

[MIT](LICENSE). `priv/public_suffix_list.dat` is the Public Suffix List, licensed under MPL-2.0 (see the header of that file).

## IndexedDB

Pages can use `indexedDB`. Each origin has its own databases. The browser keeps them in memory and writes them to the folder `indexed_db` in the user data directory, one file for each database. A transaction sends only what it changed (the records it put or deleted, and the indexes it touched), not the whole database. Transactions that can write run one after the other, also across the pages (tabs) of one origin, so no update is lost. A page that only reads sees what was committed when its transaction starts.

Data in a database can be of any type that `structuredClone` supports, including `Blob` and `File`. The size limit of one database is 256 MB.

To run the web-platform-tests for IndexedDB, use a sparse checkout of the `IndexedDB` and `resources` folders and run `mix run --no-start scripts/wpt-indexeddb.exs WPT_DIR [FILTER] [--verbose]`. Set `WPT_CALL_TIMEOUT` (in milliseconds) if a test file needs more than 5 minutes.

## Web Workers

Pages can use `new Worker(url, options)`. A worker runs its script in its own Elixir process, with its own JavaScript heap. It can run at the same time as the page.

The page and the worker send messages with `postMessage`. The browser copies each message with the structured clone algorithm. A worker has `importScripts`, `close`, timers, `fetch` and `console`. The browser shows the `console` output of a worker in the console of the page. An uncaught error in a worker becomes an `error` event on the `Worker` object. `worker.terminate()` stops the process.

The options `name` and `type: "module"` work. A blob URL can be the script. A worker has no `window` and no `document`. `SharedWorker`, nested transfer of ports and `SharedArrayBuffer` are not supported.

## WebSocket

Pages can use `WebSocket`. The browser implements the protocol (RFC 6455) in Elixir and uses no library. The code is in `Browser.WebSocket` (handshake and frames) and `Browser.WebSocket.Client` (one connection in one process).

A `wss` address uses TLS with the same trusted roots as the HTTP layer (`SSL_CERT_FILE` is also read). If `https_proxy` or `http_proxy` is set, the browser opens a `CONNECT` tunnel through the proxy, unless `no_proxy` matches the host. The browser sends the cookies of the host in the handshake and keeps the cookies from the answer.

The browser answers `ping` frames, joins fragmented messages, and does the close handshake. It does not support extensions such as `permessage-deflate`. `bufferedAmount` is always 0.
