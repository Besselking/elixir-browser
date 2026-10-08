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
