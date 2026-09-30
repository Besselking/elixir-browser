# Elixir Browser

A small native GUI web browser written in Elixir: HTTP(S) fetching, a tolerant HTML parser,
a CSS engine (selectors, cascade, `@media`, custom properties, box model) and a text/box
layout, drawn with Erlang's `:wx`.

```bash
mix run --no-halt            # opens the about:home page
BROWSER_URL=https://example.com mix run --no-halt
mix test
mix app.bundle               # macOS: self-contained dist/"Elixir Browser.app"
```

Requires Elixir 1.15+ and an Erlang/OTP with the `wx` application (Homebrew's `erlang` has it).
