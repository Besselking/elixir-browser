# Speedometer 3.1 in the browser

Status: 2026-10-11 (see the sections at the end for work after 2026-10-08). All work is in the Speedometer PR (branch `claude/speedometer-kd3g59`).

## How to run it

- Speedometer 3.1 is a mirror of https://browserbench.org/Speedometer3.1/ served from a local folder.
  Use URL parameters: `startAutomatically`, `iterationCount=1`, `suites=<name>[,<name>]`.
- The runner loads each test page into an `iframe`, waits for `onload`, and drives the page
  through `contentDocument`. So the browser needs iframes with their own window and document.
- 32 suites exist. Only 20 are on by default. The rest have `disabled: true` in `tests.mjs`.
- A driver script that starts the page, runs the scripts, prints the console, and stops
  was used for all measurements. It is not in the repository.

## Result

- The full default run (20 suites, 58 steps) now finishes. Time: about 200 s on the cloud machine.
  Score: about 0.53 (a real browser scores 20 to 40 times higher).
- Bess saw two problems in the window:
  - "stuck at 14 / 580", then "stuck at 54". Cause of the second: a script kept a node
    of a page frame that was already removed. The DOM raised an internal error for the
    missing node. Now such a node reads as an empty, detached node.
  - "none of the tests render". Cause: frame content was never laid out. Fixed: see below.

## What was missing, and what is fixed

Size: S = under 1 hour, M = a few hours, L = a day or more.

| Item | Size | State |
| --- | --- | --- |
| Iframes: own window, document, location, history, scripts, `load` events (`src`, `srcdoc`, blank) | L | fixed |
| Timers and `fetch` that run in the realm of the frame | M | fixed |
| Frame content shown in the page, with its own style sheets | L | fixed |
| Style sheets that scripts add (`<style>`, `<link>`) now apply (they were ignored) | M | fixed |
| `document.open()` and `document.write()` for a frame | S | fixed |
| Shadow roots: part of the tree of the host, `composed` events leave them | M | fixed (not drawn) |
| Custom elements inside shadow roots are upgraded | S | fixed |
| `EventTarget` as a base class (Lit) | S | fixed |
| Comments kept by `innerHTML`; `<?...>` markers (Lit) | S | fixed |
| Attributes such as `@click` kept on elements | S | fixed |
| `createEvent` and the `init*Event` methods (Svelte) | S | fixed |
| `onclick`-style properties and `'oninput' in document` (React) | S | fixed |
| Selectors: `:nth-child(an+b)`, `:has`, `:nth-of-type`, and more (jQuery) | M | fixed |
| Iterators on `DOMTokenList`, `CSSStyleDeclaration`, `URLSearchParams` | S | fixed |
| `getComputedStyle` with sizes and default values (Stockcharts) | M | fixed |
| `URL.createObjectURL` | S | fixed |
| Unicode `Script=` and binary properties in RegExp | S | fixed |
| `console.assert`, `trace`, `dir`, `table`, and the other console methods | S | fixed |
| Error reports show function names | S | fixed |
| Canvas 2D context: paths, fill/stroke, arcs, text, gradients, transforms, box clips, dashes, `Path2D`, `drawImage` of a canvas; painted in the window, rasterized for `toDataURL` | L | fixed |
| Shadow DOM drawn on screen (Lit and web component suites show blank) | L | open |
| Pointer events and clicks that go into a frame (hit test, links, controls, scrolling) | M | fixed |
| `Worker` (dedicated) | L | fixed (PR 228); `SharedWorker` open |
| `WebSocket` (implement the protocol ourselves, not with a library) | L | fixed (PR 228) |
| `scheduler.postTask` | S | fixed (PR 228) |
| `WebAssembly` | L | open |
| Custom element constructors called from another realm run in the realm of the caller | M | open |
| Canvas: `getImageData`/`putImageData`, `drawImage` of `<img>`, rotated text, shaped clips, shadows | M | open |
| Perf-Dashboard errors (`csvParse is not a function` after a script used `with`; chart size 0; `offsetX`) | M | fixed |
| Perf-Dashboard: 21 "Assertion failed" at `firstPointInTimeRange` (selection start after end) | S | fixed (PR 243) |
| `renderMetricView is not a function` after a run (results page of the runner) | M | open |

## Score and layout for scripts (2026-10-09)

- A full default run with layout now ends with a score (0.15 on the cloud machine, 463 s with layout).
- Causes of the errors Bess saw:
  - `csvParse is not a function`: after any script used `with`, a call to an imported function read the
    import slot (a reference) as the function. Fixed in `Interp.call_target`.
  - Charts of width 0 (`computeTimeGrid`, `xToTime`, `_sampleTimeSeries`, then `reading 'total'`):
    scripts asked for the size of new elements before the background layout had them.
    Now the runtime asks the session for a layout at once (`{:layout_now, ...}`, at most once per
    tree change and about a fifth of the time). Also `height: calc(100% - 2rem)` was dropped.
  - `Layout.layout` option `boxes: true` gives every element a `:bounds` item, so an element that draws
    nothing, or lies below a clipping box, still has a box for `getBoundingClientRect`.
  - Pointer events from scripts now have `offsetX`, `offsetY`, `pageX`, `pageY`.

## Slow places

How to measure (PR 234):

- `mix run --no-start scripts/mirror-speedometer.exs DIR` copies Speedometer to `DIR/Speedometer3.1`.
- Serve `DIR` with `python3 -m http.server 8765`.
- `mix run bench/speedometer.exs SUITE` runs one suite. Use `all` for the default run.
- Options (environment variables): `PROF=1` stack sampler, `GCTRACE=1` GC time, `MEM=1` memory, `PDSTAT=1` heap statistics, `TPROF=1` call counts.
- Timing noise is about 3% for a suite and 30% for a micro-benchmark. Compare against a build of `main`.

Full default run, 4 cores: 266 s before PR 234, about 174 s after (`PROFCALLER=name` shows the callers of a function in the sampler).
Slowest suites after PR 234: Stockcharts 36.6 s, Perf-Dashboard 29.4 s, React-Redux 20.4 s,
Angular-Complex 17.8 s, React-Complex 15.8 s, jQuery 12.3 s.

Round 2 (PR 242). Use `LAYOUT=1` to answer the size questions of scripts with a real layout, as the session does.
`LAYOUT=1` adds up the cost of the forced layouts. `LAYOUT=3` also samples the process that makes the layout.
Full run with forced layout: 192 s before PR 242, about 147 s after. 36 forced layouts cost 5.9 s in total.
Always profile the whole run with `LAYOUT=1`. A page with no sizes (width 0) does less work and hides real costs.

Findings:

- Parse a colour, a line number or a text node with a regular expression in a hot path, and it shows in the profile at once.
  Look at the callers of `Regex.run` with `PROFCALLER=run`.

- After each major GC, the BEAM does an expensive minor GC that copies all live data again.
  A larger young heap gives fewer major GCs. `Browser.JS.GC` now grows `min_heap_size` with the process.
- The stack sampler is biased toward BIF yield points. Use it for relative numbers only.
- Strings are indexed by UTF-16 unit. Long strings with wide characters need the index in `Browser.JS.Str`.

Open ideas, from most to least promising:

1. Cheaper variable lookup and scope chain in the interpreter.
2. Cheaper calls: `hoist_functions`, `make_fn`, `try/after` for each call.
3. `Props.try_define` in the chartjs suite (about 11%).
4. jQuery `parse_fragment`, `nth_match` and `String.downcase`.
5. Closure-compile step: measured at 10 to 15% (25 to 30% with slot resolution), high risk.

## Notes for later

- Frame content is exported as children of the `<iframe>` element. Its sheets get a scope:
  a rule from a frame sheet matches only inside that frame. Sheets of the page do not
  reach into the frame (only the user agent rules do).
- Every frame change now marks the page as changed, so the page is laid out again.
  If this is too slow in the window, limit it to frames that are visible.
- A remote branch `claude/speedometer-kd3g59-small` was pushed by mistake. It can be deleted on GitHub.

## Perf-Dashboard chart assertions (PR 243)

- Cause 1: boxes from a layout for the scripts were replaced by the page's older layout.
  `set_layout` now merges them.
- Cause 2: the main chart (`interactive-time-series-chart`) has `display:block` only from the
  `:host` rule of its shadow tree. Asked before the shadow tree exists, it has no box, and the
  answer stayed "no box". A missing box now asks for a new layout again.
- Cause 3: a layout for the scripts exported the whole page, with all earlier suite frames
  (1 to 5 MB). The budget (2 s + a third of the run time) was spent before Perf-Dashboard.
  Now the budget is kept for each document, and only the asking frame and the frames it is in
  are sent. Boxes of the left-out frames are kept.
- Driver note: a host that answers `layout_now` must do it in its own process, not in the
  loop that also does page layouts, or the 5 s wait ends first.
- Result: full run, no assertions (also not at `firstPointInTimeRange`), score 0.17, 193 s.

## Local session round (Bess, 2026-10-10, commits 3441193 to c4b7d48)

- Bess worked in a local session and the commits are on main (merged with PR 243).
- Memory: the cascade memo names children and custom property sets by reference. A page copied to the page job
  or the layout process was 1.7 GB, and the session grew to 12 GB. Now it is a few MB.
  A full run in the window takes 2 minutes, not more than 10.
- Cascade: rules are indexed by tree; like elements share results; sheets with equal text are parsed once.
  Lit TodoMVC cascade 1240 ms -> 175 ms. A page with many custom properties 2.5 s -> 0.38 s.
- Frames: the layout request carries the frame's own address; frame sheets are fetched with its scripts.
  ES6 Webpack TodoMVC first layout wait 1.1 s -> 0.17 s.
- Session: hover goes to the scripts without waiting; the session serves script requests while the scripts wait
  for a layout (Editor-TipTap lost 4 s of 8 s to this).
- Cache: a response with only `Last-Modified` stays fresh for a tenth of its age (at most a day).
- New bench options: `TPROF2=1` (own time per function and module), `RESOLVE=level`, `DUMPRAW=dir`, `DUMPSLOW`,
  and `bench/restyle.exs` (times the cascade and layout of a kept tree). The bench prints the score at the end.
- JS interpreter work after this date: see js-redesign.md (PRs 244 to 248).
