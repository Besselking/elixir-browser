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
supported. `scripts/install-toolchain.sh` installs them (Homebrew on macOS, a source build with wx on
Debian/Ubuntu); with asdf or mise, `.tool-versions` pins the same versions.

## Crash reports

Every crash (a process dying, a failing wx callback, `Logger.error`) is saved as a text file with the time, the page that was open, the version and commit, and the stacktrace. They go to `$BROWSER_CRASH_DIR`, else `crashes/` under the user data dir (on macOS `~/Library/Application Support/elixir_browser/crashes`), and the newest 100 are kept. `mix browser.crashes [--show|--clear]` lists, prints or deletes them.

## License

[MIT](LICENSE). `priv/public_suffix_list.dat` is the Public Suffix List, licensed under MPL-2.0 (see the header of that file).
