# CLAUDE.md

Native GUI web browser in Elixir (`:wx`): HTTP(S), HTML parser, CSS engine, layout, painter, and its own JavaScript engine (`lib/browser/js/`, a tree-walker with a resolver and closure compiler). See README.md for user features. Work list: `TASKS.md` (in this repo; tick items and add new ones in the PR that does the work; re-read just before editing).

## Toolchain
- Only the LATEST Elixir/OTP are supported (`.tool-versions`: Erlang 29.1.1, Elixir 1.20.4-otp-29). No compatibility workarounds for older versions; fix the toolchain instead.
- `scripts/install-toolchain.sh` installs OTP + wxWidgets 3.3 (needed for WebP) + Elixir. It downloads a prebuilt archive from this repo's `toolchain` release when it can, else builds from source (30+ min). `--pack OUT.tar.gz` makes the archive (the `toolchain-release.yml` workflow does it). On toolchain bumps rerun that.
- Set `ELIXIR_ERL_OPTIONS="+fnu"` for UTF-8 file names. Do not use ppa:rabbitmq (stops at OTP 27).
- No Hex dependencies (`deps: []`). Keep it that way: implement things ourselves (WebSocket, cookies, Public Suffix List are in-tree). No NIFs, no QuickJS: JS stays in Elixir.

## Checks (what CI runs, `.github/workflows/ci.yml`)
1. `mix format --check-formatted`
2. `mix compile --force --warnings-as-errors`
3. `mix test --warnings-as-errors`, and again with `JS_RESOLVE=off mix test`
4. `mix js.test262 --fetch --check --timeout 30000 [--shard N/4]`: a test in `test262.baseline` must keep passing. CI skips it for PRs that touch nothing JS-related.
5. `mix reftest --fetch --check --layout-check [--shard N/3]` against `reftest.baseline` (WPT reftests of layout/paint; `--sweep`, `--dump DIR`, `-v`, `--failures FILE`; `mix help reftest`). The WPT pass count is the layout regression check.
- `--update` rewrites a baseline. Do NOT commit a baseline from a local `js.test262 --update`: local PCRE/OTP differs for RegExp tests (~388 spurious "regressions" locally, extra passing RegExp entries that fail on CI). Take `origin/main`'s baseline plus only the new non-RegExp entries. `--update` refuses `--shard`.
- Memory: `mix test` alone peaks about 11 GB RSS. Never run two test VMs, or tests plus test262, at the same time (OOM kill).
- Workflow files: cloud sessions cannot push `.github/workflows` edits; propose the file and let Bess apply it.

## Run things
- `mix run --no-halt` (start page), `BROWSER_URL=... mix run --no-halt`, `mix app.bundle` (macOS .app; starts the VM with the ERL_FLAGS memory flags from the README; set the same ERL_FLAGS for `mix run` benchmarks).
- Headless: `mix browser.screenshot URL OUT.png [--wx] [--js]` (`--wx` needs a display: `xvfb-run -a`), `mix browser.layout URL`.
- Page archives (raw responses, replay without network): `mix browser.archive URL OUT.ebarchive`, `--archive FILE` / `BROWSER_ARCHIVE=FILE`; see README. Use for sites a machine cannot reach.
- `mix browser.crashes [--show|--clear]`, `mix wasm.spec`.

## Benchmarks and the A/B method
- Layout: `mix run --no-start bench/layout_pages.exs` (pages in `bench/pages/`), `bench/layout_features.exs`, `bench/layout_edits.exs`. Input: `bench/input_latency.exs`, `keystroke_*.exs`, `hover.exs`. JS: `bench/js_runtime.exs` and the other `js_*.exs`.
- Speedometer 3.1: `docs/speedometer.md`. Mirror the site with `mix run --no-start scripts/mirror-speedometer.exs DIR`, serve it with `python3 bench/serve.py DIR 8765` (not `http.server`), then `mix run --no-start bench/speedometer.exs http://localhost:8765/Speedometer3.1/ [SUITES]`. It prints a `MRED` line (exact VM reductions) and the score. `LAYOUT_DIRECT=1` = old layout mode (numbers not comparable with later runs).
- Machine speed varies 20 %+ between days and runs. Compare builds only with interleaved runs: `elixir bench/ab.exs DIR_A DIR_B --rounds N` (two worktrees; `--speedometer SUITE`, `--env-a/--env-b K=V`). Judge by wins per pair (e.g. 5/6) plus the median, not one run.
- Reductions are not time. Rank changes by time A/Bs. Hidden costs on OTP 29: a bare `~r` literal calls `:re.import` on each run and `String.split/1` builds its pattern per call. Use `Browser.Re.re(~r/.../)`, `Browser.Re.compiled/2`, `Browser.Re.split_words/1` on hot paths.
- Turn the shared on-disk HTTP cache (`~/.cache/elixir_browser/http_cache`) off in bench copies: modified mirror files leak between runs.

## Design docs (read before big changes)
`docs/js-redesign.md` (JS engine: resolver, slot frames, closure compiler, shapes), `docs/layout-redesign.md` (layout design; remaining steps in TASKS.md), `docs/speedometer.md`, `docs/web-apis.md` (list of supported web APIs).

## Preferences
- Larger bundled PRs are welcome; bundle several commits per push to cut CI waits. After a merge, go on with the next fix.
- Update existing scripts rather than adding near-duplicates.
- Support only latest toolchain; keep the browser dependency-free.
- Documentation (README, docs for users) is written in ASD-STE100 Simple Technical English. This file and code comments need not be.
- Another developer may work locally on main (often perf): rebase on `origin/main` and check `git log` first.
- WPT reftest fix series is paused: restart it only when asked.
