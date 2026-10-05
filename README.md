# Elixir Browser

A small native GUI web browser written in Elixir: HTTP(S) fetching, a tolerant HTML parser,
a CSS engine (selectors, cascade, `@media`, custom properties, box model) and a text/box
layout, drawn with Erlang's `:wx`.

```bash
mix run --no-halt            # opens the start page: a few sites and the demo pages in priv/demo
BROWSER_URL=https://example.com mix run --no-halt
mix test
mix app.bundle               # macOS: self-contained dist/"Elixir Browser.app"
```

Requires Elixir 1.20+ and Erlang/OTP 29+ with the `wx` application; only the latest versions are
supported. `scripts/install-toolchain.sh` installs them (Homebrew on macOS, a source build with wx on
Debian/Ubuntu); with asdf or mise, `.tool-versions` pins the same versions.
