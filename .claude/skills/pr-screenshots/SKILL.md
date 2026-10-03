---
name: pr-screenshots
description: Take a screenshot of a page in the browser without a window and show it in a pull request. Use for any visual change (layout, painting, CSS) when working in a headless or cloud session.
---

# Screenshots for pull requests

The app needs a window (wx), so cloud sessions can't run it. `mix browser.screenshot` lays a
page out with the browser's own engine, draws it as SVG (`Browser.Screenshot`) and renders
that to a PNG with headless Chromium (Playwright's, found in `/opt/pw-browsers`, or `CHROME`).

```
mix browser.screenshot URL out.png [--width 1000] [--height 800]
mix browser.screenshot file:///tmp/case.html /tmp/case.png --width 500 --height 260
```

With `--wx` the page is painted by the window's own painter (real fonts, pictures, shadows)
into a bitmap. That needs an Erlang with wx and a display; in a cloud session run it as
`xvfb-run -a mix browser.screenshot URL out.png --wx`. Where wx is missing it says so and falls
back to the SVG route below.

SVG route limits: text uses the system's sans/monospace font squeezed to the layout width, and pictures,
vector graphics and shadows are not drawn. It shows where things are and how borders, boxes and
text line up, not the exact glyphs. Pages whose content comes from scripts needing a server
(Blazor) show only what is in the HTML; write a small HTML file that reproduces the case.

## Putting it in a PR

The GitHub tools here can't attach images, so keep them on a branch of their own:

1. Read the PNG (the Read tool shows it) and check it shows the change.
2. Push it to the `pr-screenshots` branch (create it from main if missing) with
   `mcp__github__create_or_update_file` at `pr-<number>/<name>.png` (base64 content).
3. Reference it in the PR description or a comment, which renders for repo members:
   `![name](https://github.com/Besselking/elixir-browser/blob/pr-screenshots/pr-<number>/<name>.png?raw=true)`

Add a before/after pair when the change fixes how something looks.
