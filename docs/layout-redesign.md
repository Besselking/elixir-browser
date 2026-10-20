# A faster layout engine in Elixir: design and plan

Date: 2026-10-12. Thread: "Layout engine redesign". Status: design complete, ready for
implementation (no code changed yet). Companion files: `notes/layout-redesign/` (MEASUREMENTS.md,
PROFILE.md, BRIEF.md, RUBRIC.md, JUDGE_BRIEF.md, the three competing designs `design-*.md` with
their prototypes and raw outputs in `designs/`, the judges' scores `judge-1.json`/`.md` (Opus) and
`judge-2.json`/`.md` (Fable), and `measurements/` with every script and raw output of section 3).
All line numbers refer to `lib/browser/layout.ex` at `main` (a17db93) on 2026-10-12 unless the
text names another file.

## 1. Summary

**The question.** Bess asked for a rework design of the layout code, done the way the JS
interpreter redesign was done: measure first, write competing designs with prototypes, let two
judges score them, then merge a staged plan. This document is that plan. It changes no browser
code; implementation starts in a new thread.

**What the measurements say** (section 3). A full layout of a realistic page costs 66 to 250 ms
(2.4 to 8.5 million reductions, "Mred") on the cloud VM. There is no single hot function. The
cost is the number of small things done per word, per line and per item, and the number of times
the same content is laid out. Two facts set the direction. First, the engine lays content out to
measure it: shrink-to-fit boxes, floats, flex items, table cells and grid items are laid out at an
unbounded width and at width 1 before their final layout, and those measuring layouts are 38 to
56% of a cold layout on four of the five bench pages. Second, nothing survives from one layout to
the next: the atom memo dies with each `layout/5` call and `Page.render` rebuilds every node, so
every edit, focus change, image load and script question costs a full layout. Text measurement is
not a cost (section 3.4). A keystroke that `patch_field/6` can handle costs 17 to 20 ms, all of
it passes over the flat item list; a keystroke it cannot handle costs a full layout (125 ms p50).

**The three designs** (section 4). A, "incremental": keep the walk's ops, the placed result of
each block and the atom memo between layouts, with term identity as the change signal; an edit
costs 1 to 9% of today, a cold layout does not get faster. B, "evolutionary": stable keys and a
content-keyed atom memo that lives on (an edit or a seen-width resize at 17 to 34% of today),
word walks for intrinsic sizes, and a one-pass typing path (a backspace in a scrolled field 125
to 5 ms). C, "spec-shaped": a sizing fold that computes intrinsic sizes without a layout (a cold
layout -24% in total in its fixed version, -34 to -35% on news and shop), with a box tree,
fragments and modules per formatting context as the long-term shape.

**The verdict** (section 4.5). The judges split: Opus scored A first (20, 19, 14), Fable scored B
first (20, 19, 14); C was last for both because its measured version fails the reftest gate. Both
judges' merged advice is the same plan: A is the spine for edits and typing, B's keys, memo, typing
fixes and layout worker are the first PRs, and C's fold is the only source of a cold and resize
gain and goes in behind a flag once its sweep is clean. Every number in this document was
reproduced by at least one judge unless it says "estimated".

**The plan** (section 7) has six stages and 24 steps; every step is one PR that keeps the 779
layout tests and the 6158 WPT reftest baseline green, and the stages give gains early:

1. Foundations and typing fixes (five S or M PRs, three threads at once): stable walk keys, tree
   identity through `Forms.render`, the one-pass typing path, the session-side typing fixes, and
   the check modes in CI. Gain: the unpatchable backspace 125 to 5 ms; the patched keystroke 17
   to 20 ms to an estimated 6 to 9 ms.
2. One persistent atom memo in a layout worker process per tab. Gain: an edit or a seen-width
   resize at 17 to 34% of today's work; a first resize to a new width -25%.
3. The sizing fold, landed op kind by op kind behind a flag with the check sweep in CI. Gain: a
   cold layout and a resize -24% in total as measured (-14% article, -34% news, -35% shop, -25%
   search, -9% docs), up to -42% on article once one float refusal is narrowed.
4. The retained walk and fragment tables for edits and script layouts. Gain: an edit at 1 to 9%
   of today, a script-forced layout at 20 to 52%; the layout part of a keystroke in any field 8
   to 11 ms.
5. Fragments relative to their box, one emit pass, per-fragment consumers; `patch_field` removed.
   Gain: the warm floor after a hit 19 ms to 1 to 3 ms on article; the end-to-end keystroke to
   about 5 ms (estimated).
6. Tables and the long tail: column lists as tuples, retained column solutions, re-layouts
   without re-walks; the module split only when a CSS feature needs it.

**Expected result** (section 6). A cold page load or a resize at 60 to 75% of today's work; an
edit or a focus change at 1 to 10% of today's work on the bench pages and a script's size
question at 20 to 50%; typing at about 5 ms per keystroke for every field kind. What it does not fix is in section 8: the
per-word cost of the final layout of each atom, which is the real work and stays.

**The first PRs to open** are steps 1, 2 and 3 of stage 1 (stable walk keys, `Forms.render/4`
identity, the one-pass typing path). All three are S, independent, prototyped and reproduced.

## 2. What the layout does today

`Browser.Layout.layout/5` (line 120) turns the styled node tree into a flat list of items for the
painter. It is one module of 10990 lines and 898 functions. The computed style of an element is a
map of CSS property name to value in its `"@computed"` attribute, attached by `Browser.Style.prune`
(`style.ex:1542`). The layout reads it by string key (`c["width"]`).

The layout has two phases.

**Phase 1, `walk` (line 767): the tree becomes a flat list of ops.** `restyle/4` (line 2563) and
`apply_computed/2` (line 2650) fold the computed style into an inline style map of 45 keys that
every word op carries. A block becomes `{:box_start, ref, spec}` ... `{:box_end, ref}` around the
ops of its children (`block_ops_inner`, line 1896), or `{:inset, l, r}` ... `{:inset_end}` when it
has no box of its own. Text becomes one `{:word, text, style}` op per CSS word and `{:space,
style}` ops between them (`walk_plain_text`, line 3078). Inline boxes become `{:inline_open, ref,
spec}` and `{:inline_close, ref, spec}`. Inline-blocks, floats, absolute boxes, flex items, grid
items, table cells, legends and multi-column content are "atoms": ops that carry their own
sub-list of ops (`inline_block_ops`, line 1582, builds it with `walk_element(..., :inline_inner)`).
The walk depends on the available width: percentages and `calc()` are resolved against
`Process.get(:layout_cw)` (`resolve_calc`, line 2607; `with_cw`, line 10762), so a resize redoes
the walk.

**Phase 2, `place` (line 3474): the ops become positioned items.** `run/9` (line 3480) folds the
ops over a state map `st` of about 60 keys (the items so far, the rects, the current line, the
floats, the open boxes, the pending margins, the clips, the sticky limits, ...). There is one
`op/2` clause per op kind. A word goes through `word/6` (line 6412), `plain_word`, `split_point`
and `word_placed` (line 6585), which makes a 30-key item map and pushes it on the line. A line ends
in `flush/1` (line 6887), which places the line's items at their y, handles `vertical-align`,
justification, inline box fragments (`inline_boxes`, line 7074) and relative shifts. A block box is
opened by `start_box`, `place_box` and `open_box` (lines 4713 to 4900) and closed by `finish_box`
(line 4985), which emits its background and border rects behind the items placed inside it, and
applies clips, scrollers, sticky limits and transforms to them.

Every atom is laid out by a nested `run` through `layout_atom/5` (line 6185) at a given width.
Shrink-to-fit (`fit_width`, line 5995; `content_width`, line 6040) lays the atom out at an
unbounded width (`shrink_extent`, line 6083) and at width 1 (`min_extent`, line 6097; a shortcut
measures plain words without a layout), then at the final width. A flex item is measured the same
way for its base size and its automatic minimum (`flex_base`, line 8533; `flex_min`, line 8893),
then laid out at its final width (`flex_line_live`, line 8681), and again when the line stretches
it. A table cell is measured at its minimum and maximum (`table_columns`, line 10498), laid out
at its column width (`table_layout`, line 10152), and again at its row height when it is not
"plain". The results of nested layouts are memoized for the duration of one `layout/5` call in
the process dictionary (`memo/2`, line 6153), under a key that hashes the sub-op list
(`:erlang.phash2(sub)`) or a `make_ref()` made in the walk, plus the width.

Floats are a list in `st.floats`; each line start scans it (`float_offsets`, line 10939).
Absolute boxes are placed when their containing block closes (`place_deferred`, line 5356).
`finalize/1` (line 3583) sorts the items of a run into backgrounds, flow content and positioned
boxes. The parent of an atom moves the atom's items by the atom's position (`move/3`, line 5796),
once per nesting level.

**The output** is a flat list of maps: `%{type: :text | :rect | :box | :image | :svg | :bgimage |
:shadow | :inset_shadow | :hr | :scroller | :bounds | :ring | :caret | :selection | :canvas, x,
y, w, h, ...}` with paint data. There is one `:text` item per word, except for glued words that
`mergeable?/2` (line 6655) joins: the article page has 4633 text items for 4633 words. The
consumers of the list are the painter (`Browser.UI.paint_dc`, `ui.ex:628`; `UI.index_page`,
`ui.ex:196`, bands the items by y for scrolling; `UI.update`, `ui.ex:245`, diffs two lists for a
dirty rect), `Layout.controls/1` (line 491, the boxes of form controls), `Layout.patch_field/6`
(line 427), `Layout.add_focus/3` (line 308, the focus ring, caret and selection), `Browser.Scrollers`,
`Browser.Editing`, `Browser.Selection`, `UI.links` (the hover index), `Browser.Nids.rects/2` (per
element rects for scripts), `Browser.Reftest.Raster`, `Browser.Screenshot` and `mix browser.layout`.

**The callers.** `Browser.Session.relayout/2` (`session.ex:2589`) runs a full layout on every edit,
focus change, image load, resize and script result. `start_layout_job/1` (line 2606) runs the
layout of a page load or resize in a background process with a 2 MB initial heap.
`relayout_edit/3` (line 2819) patches the items of a single-line field whose width does not
depend on its text (`Page.fixed_width`, `page.ex:223`) through `Layout.patch_field/6`; any other
edit is a full layout. `start_layout_for_scripts/4` (line 2326) answers a script's size question
(`offsetWidth`, `getBoundingClientRect`) with a restyle, a full layout with `boxes: true` and
`Browser.Nids.rects/2`. `Page.render/2` (`page.ex:501`) rebuilds the whole node tree through
`Forms.render` (`forms.ex:217`) on every edit, so no subtree of the new tree is the same term as
in the old tree.

## 3. Measurements

All on the cloud VM (4 cores, Elixir 1.20.4, OTP 29.1.1), at `main` a17db93, with the stub text
measurer (7 px per character) unless noted. Scripts and raw outputs: `notes/layout-redesign/measurements/`.

### 3.1 Full layout per page (`bench/layout_pages.exs`, median of 7, ms)

| page | KB | nodes | layout 1000 px | resize 700 px | edit (render + layout) | items | walk / place |
|---|---|---|---|---|---|---|---|
| article | 40 | 1462 | 240 | 230 | 250 | 4989 | 40 / 190 |
| docs | 60 | 2249 | 200 | 195 | 210 | 6161 | 35 / 165 |
| news (table) | 39 | 1962 | 193 | 198 | 217 | 3186 | 38 / 130-180 |
| search | 20 | 716 | 75 | 68 | 70 | 2181 | 15 / 50-60 |
| shop (flex grid) | 22 | 1327 | 241 | 193 | 260 | 1610 | 40 / 140-240 |

The place phase is 80 to 85% of a layout. A resize costs as much as a first layout. An edit costs a
full layout; `Page.render` itself is 0.1 ms. Wall time on the VM varies by 20 to 30% between runs;
reductions (Mred) do not, so the designs report both.

### 3.2 Structural facts (`measurements/facts.txt`)

| page | Mred | minor GCs | heap MB | text items / words | items flat KB | atom layouts / atoms | widths per atom |
|---|---|---|---|---|---|---|---|
| article | 7 | 28 | 30 | 4633 / 4633 | 2819 | 891 / 661 | 1x:541 2x:10 3x:110 |
| docs | 5 | 32 | 26 | 5257 / 5906 | 3468 | 502 / 502 | 1x:502 |
| news | 8 | 26 | 29 | 3178 / 3178 | 1953 | 1279 / 552 | 1x:8 2x:361 3x:183 |
| search | 2 | 39 | 10 | 2149 / 2152 | 1276 | 200 / 108 | 1x:24 2x:76 3x:8 |
| shop | 7 | 49 | 21 | 1123 / 1124 | 1001 | 2928 / 1012 | 1x:387 2x:97 3x:144 4x:5 5x:379 |

"atom layouts 2928 / 1012" means `layout_atom` ran 2928 times for 1012 distinct sub-op lists: the
same content laid out at up to 5 widths. The `shrink_extent` runs (326 to 916 per page) are full
nested layouts too. The memo lives for one layout call.

### 3.3 Where the time goes (`measurements/prof_all.txt`, tprof own time; PROFILE.md)

There is no single hot spot. Own time by module (article / docs / news / search / shop):

| module | article | docs | news | search | shop |
|---|---|---|---|---|---|
| Browser.Layout | 37.5% | 37.7% | 31.7% | 36.6% | 42.4% |
| Enum | 19.8% | 18.4% | 27.5% | 17.6% | 20.8% |
| String, :binary, :unicode_util | 19.6% | 18.3% | 17.5% | 23.5% | 13.1% |
| Access, Map, :maps | 12.4% | 15.8% | 11.2% | 10.6% | 13.8% |

Nothing in `Browser.Layout` is above 4% except `flush/1` (3 to 5%). The cost is the count of
small things per word and per line: for article.html (12186 words placed, 6832 lines, 1218 nested
runs) there are 231909 `Enum.map` steps, 425206 `Map.get`/`Access.get` calls, 191732
`String.length` calls, 75756 `:binary.match` calls (`String.contains?` for a soft hyphen in
`word/6`, a zero-width space in `spaced/1`, line 196, and "ahem" in `content_factor/1`, line 6276,
on every word), 24320 `content_factor` and 24372 `line_px` calls, 33930 `tail_extents/1` steps
(line 3486, once per nested run over its whole op list), and 6871 `float_offsets/3` calls.
Page-specific: news.html spends 13% in `Enum.drop_list` and `List.do_update_at` (1.17 M and 224 k
calls: `Enum.at`, `Enum.slice` and `List.update_at` on column lists in `table_layout`, line 10152,
`table_widths`, line 10573, `column_positions`, line 10646). shop.html: `run/9` 3845 calls,
`move/3` 30521 calls, `flex_element_item/3` 928 calls at 7.2 ms (a 40-key item map per flex
item, line 8249). Style conversion (`box_spec/4`, `box/2`, `apply_computed/2`) is about 15 us per
element.

### 3.4 Text measurement (`measurements/wx_measure.txt`, real wx under Xvfb, ms)

| page | stub | wx cold cache | wx warm cache | distinct strings | measure calls |
|---|---|---|---|---|---|
| article | 254 | 312 | 243 | 602 | 60169 |
| docs | 192 | 253 | 204 | 550 | 45659 |
| news | 195 | 319 | 291 | 645 | 73514 |
| search | 96 | 155 | 93 | 382 | 26375 |
| shop | 341 | 393 | 323 | 332 | 47697 |

One uncached `wxDC.getTextExtent` costs 57 us, a cached one 0.27 us. The real measurer adds about
60 ms to a cold first layout and nothing to a warm one. Text measurement is not where the time goes.

### 3.5 Typing (`measurements/input_latency.txt`, `bench/input_latency.exs` with a fix, Xvfb, 120-paragraph page, 5178 items, with paint, ms)

| path | mean | p50 | p95 |
|---|---|---|---|
| type, fixed-width field (`patch_field`) | 20.1 | 18.9 | 25.3 |
| type, field in a flex row (width: 300px, patched too) | 25.9 | 21.1 | 35.7 |
| type, auto-width field (an `<input>` with no CSS width has a `size` width: patched too) | 20.8 | 18.1 | 25.3 |
| backspace, flex row / auto-width field (full layout once the text differs from one item) | 87.2 / 103.3 | 117.8 / 126.3 | 172 / 154 |
| cold-glyph keystroke (new text) | 130 | | |

A keystroke that `patch_field` can handle costs about 19 ms with or without paint. The profile of
the session process (`measurements/keystroke_prof.txt`) shows why: about 20 full passes over the
flat list of 5178 item maps per keystroke (`patch_field` 3 passes, `Layout.controls` 1,
`add_focus` 6, `UI.index_page` 6 passes plus a `persistent_term.put` of the whole list at 3.4 ms,
`moved_on_screen?` 1, `UI.diff_items` 1). The layout itself does not run on that path. A
keystroke that cannot be patched is a full layout: 117 to 126 ms p50 on this page. The PR 7
numbers (9 / 30 / 39 ms) were on a faster machine; the shape is the same.

### 3.6 Gates

- `mix test test/browser/layout_test.exs test/browser/patch_field_test.exs test/browser/layout_dump_test.exs`: 779 tests, 1m24s.
- `mix reftest --check` against `reftest.baseline`: 6158 passing WPT reftests (CI: 3 shards).
- Benches: `bench/layout_pages.exs`, `bench/layout_features.exs`, `bench/input_latency.exs` (needs the `controlDown`/`metaDown` fix from `measurements/input_latency_fixed.exs`), `bench/restyle.exs`.

## 4. The competing designs

Three writers got the same brief (`notes/layout-redesign/BRIEF.md`), the same measurements and a
git worktree at `main` a17db93. Each wrote a design and a prototype, and measured the prototype.
The full designs are `notes/layout-redesign/design-incremental.md`, `design-evolutionary.md` and
`design-specshaped.md`. Their prototype diffs, scripts and raw outputs are in
`notes/layout-redesign/designs/<name>/`. The judges' scores are `judge-1.json` (Opus) and
`judge-2.json` (Fable) with their reruns in `judge-1.md` and `judge-2.md`.

### 4.1 Design A: incremental layout on a retained tree

What it keeps between layouts: three tables. The walk table holds the ops of each block, atom,
flex item and cell. The fragment table holds the placed result of each block (its items, its
height and the few state values it leaves for the next block), keyed by the state values the block
reads. The sub-layout table is the atom memo made persistent. The change signal is term identity:
a new `Forms.render/4` rebuilds only the path from an edited control to the root (666 of 670
element nodes stay the same term after an edit), so a block whose subtree is the same term is a
hit. A hit is shifted into place with `move/3`; a miss runs the code of today. A block that holds
a float, a clear, a positioned box or a multi-column box is never replayed.

Measured on the prototype (reductions in Mred; stub measurer): an edit costs 1 to 9% of today
(article 0.62 instead of 7.18; shop 0.09 instead of 7.72). The same tree laid out again costs 1
to 8%. A script-forced layout with one text node changed costs 20 to 52%. A resize to a new width
costs 103 to 106% (the tables are filled) and a cold layout 103 to 107%. Typing on the 5178-item
bench page: when a keystroke needs a layout, the layout part is 8.5 to 11.1 ms instead of 69 to
74 ms, for all three field kinds. Gates: 779 of 779 layout tests in check mode (each layout done twice and
compared), 6158 baseline reftests with 0 regressions and 0 check-mode differences. Memory: 4 to
12 MB of tables per page and width.

Weak points: a cold layout and a resize to a new width do not get faster. After a hit, the
per-item passes (`place_atom/2`, `finalize/1`, `add_focus/3`) still cost 1.5 to 19 ms. The
session gets a third layout path (retained) next to the patched and the spawned ones until a late
step folds them into one. The prototype's tables do not key on images or on the measurer.

### 4.2 Design B: evolutionary, remove the measured repeated work

What it keeps: the two phases, the flat item list, the state map and all 898 functions. It
changes three things. First, the atom memo gets stable content keys (`{:k, nid, n}` instead of
`make_ref()`; `phash2` of the sub-op list) and lives from one layout to the next, swept to the
entries the last layout touched. Second, the intrinsic sizes (shrink-to-fit at an unbounded width
and at width 1, 38 to 52% of a cold layout on article, shop and search) come from word walks
(`max_words/9`, `min_words/7`) instead of a layout with one word per line. A check mode
(`LAYOUT_CHECK=1`) runs the layout as well and raises on a difference. Third, the typing path
makes one pass over the items instead of about twelve, and patches an emptied field instead of a
full layout.

Measured on the prototype (Mred): an edit or a resize to a seen width with the kept memo costs 19
to 34% of today (article 1.33 instead of 7.14; shop 1.43 instead of 7.64; ten layouts 14.81
instead of 62.54). A first resize to a new width costs 69 to 94%. A cold layout costs 98% (the
word walks give -2% in total, news -5%). Typing: a backspace in the scrolled auto-width field
takes 6.8 ms instead of 122 ms (p50). Gates: 779 of 779 layout tests, plain and in check mode;
the whole 6158 baseline green in check mode. Memory: 5 to 16 MB of memo per page.

Weak points: the walk runs in full on every layout (24 of 53 ms on a memo-hot article). The
top-level flow of a plain text page gets nothing from the memo. Tables stay a layout for the word
walks. The per-word costs stay. The cold gain of the word walks needs steps that are not
prototyped (walks into inline-blocks, markers, floats and nested flex: an estimated -25 to -45%
cold).

### 4.3 Design C: a spec-shaped engine, started from its sizing pass

What it changes: the engine of the CSS specs. A box tree, an intrinsic sizing pass that computes
min-content and max-content widths bottom-up without a layout, one layout module per formatting
context that makes fragments, and one emit pass that writes the flat item list. The prototype is
the sizing pass only: `fold_at` folds over the op stream with the width rules of `run/9`, and
answers every `shrink_extent` call. The fold refuses what it cannot size (it throws `:layout`,
and the measuring layout of today runs). The old layout stays behind a flag (`LAYOUT_FOLD`), with
a check mode that runs both and compares, and a sweep script that lays out all 11870 WPT files of
the baseline folders in check mode.

Measured on the prototype (Mred, one layout at 1000 px): article 4.17 instead of 7.04 (-41%),
docs 5.43 instead of 5.99 (-9%), news 5.80 instead of 8.52 (-32%), search 1.81 instead of 2.41
(-25%), shop 5.03 instead of 7.88 (-36%). A resize gets the same gain. GC work per layout about
halves on article, news and shop. Gates: 768 of 768 layout tests; 6159 reftest passes against
the baseline of 6158, but `--check` reports 2 regressions in css-flexbox, and the sweep finds 10
files with a wrong fold result. All 10 have one cause (an empty atom's width counted as reach). A
follow-up diff fixes 9 of the 10 but was not measured for speed and was not run through
`--check`; the last file (`floats-131`, a table cell with a float and a margin) needs a fence
that falls back to the layout.

Weak points: the measured version has correctness faults, and the fixed version is not measured.
A wrong width is silent: no fallback fires, so the check mode and the sweep must run on every PR.
The typing path and the per-word costs are not touched. The full design (box tree, fragments,
modules, retained box tree) is XL and gives no gain by itself beyond the sizing pass and the
fragments.

### 4.4 What the three designs agree on

The three writers found the same two facts on their own. First, the measuring layouts
(shrink-to-fit at an unbounded width and at width 1) are 38 to 56% of a cold layout on four of the
five pages, because today the engine lays content out to measure it. Second, the atom memo dies
with every layout; a memo with content keys that lives on gives 66 to 99% less work on a repeated
layout. Both B and C compute intrinsic sizes without a layout: B's word walks and C's fold are the
same idea at two levels of completeness, and C's fold is further along. Both A and C want items
relative to their box and one emit pass instead of `move/3` per nesting level. The merged plan
(section 7) takes each idea once.

### 4.5 What the judges found

Two judges scored the designs with the rubric of `notes/layout-redesign/RUBRIC.md` (five
criteria, 1 to 5 each): judge 1 on Opus (`judge-1.json`, `judge-1.md`), judge 2 on Fable
(`judge-2.json`, `judge-2.md`). Each reran the prototypes' own measurements in their worktrees,
interleaved with `main`, with the machine load under 1.5, and ran the layout tests and reftest
folders in each check mode.

| design | judge 1 (Opus): measurement, risk, landability, gain, memory and complexity | judge 2 (Fable) | sum |
|---|---|---|---|
| A incremental | 5, 4, 4, 4, 3 = 20 (winner) | 4, 4, 4, 4, 3 = 19 | 39 |
| B evolutionary | 4, 3, 5, 3, 4 = 19 | 4, 4, 5, 3, 4 = 20 (winner) | 39 |
| C spec-shaped | 3, 3, 2, 3, 3 = 14 | 3, 2, 3, 3, 3 = 14 | 28 |

What reproduced. Every reduction count of A and B reproduced within 1% (A: edit 0.62 / 0.30 /
0.45 / 0.12 / 0.09 Mred on the five pages; the typing page 2.24 to 0.48 Mred per keystroke;
B: ten layouts 62.5 to 14.7 Mred with the kept memo). C's fold reproduced exactly (article 7.03
to 4.16 Mred, 0 mismatches in check mode) and its two css-flexbox regressions were confirmed by
both judges. Judge 1 also measured C's follow-up diff (`prototype_edges.diff`) in a worktree of
its own: 0 wrong results in the sweep of 11870 files, 779 tests, css-flexbox 670 and
floats-clear 180 clean with `--check`, and -24% in total (47.4 instead of 62.3 Mred for layout
plus resize of the five pages) instead of -31%, because one float rule makes the whole body of
article fall back (article -14% instead of -42%). End to end under Xvfb (N=60, no paint, p50):
a backspace in the scrolled auto-width field is 124.9 ms on `main`, 5.4 ms with B's typing
patches, 17.4 ms with A's tables on; typing in all three fields is 17 to 20 ms on all three.

What the judges found wrong. In A: the tables live in the caller's process dictionary, so the
spawned resize and script jobs get nothing; the fragment keys do not cover images; the read set of
a span (`span_key/1`, about 38 state fields) is hand-written and the same-tree check mode cannot
find a missing read; A's claim that only the fixed-width field takes `patch_field` today is
wrong (all three fields do; the full layouts come from backspaces and scrolled fields); removing
`patch_field` is about 25 lines, not 400. In B: the kept memo keeps the paint-order seqs of the
earlier layout (4 WPT files reorder on the second layout; A found and fixed this class with
`renumber_memo/1`); images are read in the place phase for background pictures, so a kept memo
serves atoms without their pictures after an image loads; the epoch is not prototyped; a 32-bit
`phash2` is the only key, kept for the life of the page; the forced-layout gain is measured by a
proxy, and on a real script-like edit the kept memo costs 36 to 85% of today, not 18 to 34%. In
C: the measured version fails the gate; the fixed version was not measured by the writer; the
fold copies `run`'s width rules, so every later change to a width rule must be made twice, and
only the check mode on the WPT corpus catches a miss; step 1 is one PR of about 1400 lines.

What the judges agreed on, and what section 7 does: take A as the spine for edits and typing;
take B's stable keys, content memo keys without the containing width, the epoch, the typing
fixes and the layout worker process as the first PRs; take C's fold (the edges version) as the
intrinsic sizing pass, landed op kind by op kind behind `LAYOUT_FOLD` with the sweep in CI, and
do not also build B's hand-written word walks; do the "fragments relative to their box and one
emit pass" change once (A step 8 and C step 4 are the same change); add an edit-differential gate
(mutate text nodes and attributes in WPT files and in the bench pages, then compare with a fresh
layout) because the same-tree check mode cannot find a missing read; renumber paint-order seqs on
every memo hit; compare memo keys structurally, not by a 32-bit hash; keep every cache in the
worker, never in the session process; do not start the XL module split as a prerequisite for
gains.

## 5. Target design

The target is one engine that does three things the engine of today does not do: it sizes
content without a layout, it keeps work from one layout to the next, and it moves every item
once. The flat item list and every consumer of it stay as they are. The target is reached in
stages (section 7); each stage is useful on its own and lands green.

### 5.1 Data model

- **Ops** stay the output of the walk: `{:word, text, style}`, `{:box_start, ref, spec}`, atoms
  with sub-op lists (lines 654 to 3470). Two changes. Keys made in the walk are stable:
  `{:k, nid, n}` (`n` counts the keys asked for that node in this walk) instead of `make_ref()`
  at the nine sites that make them (float and absolute specs, inline-block specs, box refs, flex
  item keys, background pictures, cells). A block in flow becomes one op
  `{:span, key, ops, safe?}` with the ops of its children nested in `ops` (stage 4); today
  `block_ops` (line 1890) appends them flat.
- **Intrinsic sizes** are values, not layouts: the min-content and max-content width of a
  sub-op list come from a fold over the ops (`fold_at` of design C) that follows only the width
  rules of `run/9`, memoized by content. A layout at width 1 or at an unbounded width runs only
  when the fold refuses the construct.
- **Items** stay the maps of today (`word_placed`, line 6585). From stage 5 on, a nested run
  returns a fragment (its items relative to its own box, its height, its extent and the state
  values it leaves behind), and one emit pass adds the offsets on the way down.
- **Retained state** between layouts, owned by a layout worker process per tab and never copied
  into the session: the atom memo with content keys (stage 2); the walk table (the ops of each
  block element, atom, flex item and cell) and the fragment table (the placed result of each safe
  span) (stage 4). The memo key is the sub-op list itself or a strong hash of it, not a 32-bit
  `phash2`. An epoch in every key covers what a layout reads outside the ops: the image map
  version (background pictures are read in the place phase), the view height, the measurer and
  metrics function, the SVG defs, the `boxes` flag. The worker bumps the epoch when one of them
  changes, sweeps the tables by generation after each layout, and drops them on navigation.
- **State map** `st` stays (about 60 keys). An optional late step splits the per-word line state
  from the block state if wall time shows the map copies.

### 5.2 Phases

1. **Walk** (line 767): as today, with stable keys and, from stage 4, spans. A walk-table hit
   returns the stored ops of an element whose subtree is the same term (or carries the same
   version stamp), whose inherited style is equal and whose context (containing width, viewport,
   pass flags) is equal.
2. **Size**: `shrink_extent` (line 6083), `min_extent` (6097), `fit_width` (5995), `flex_base`
   (8533), `flex_min` (8893), `track_sizes` (7781), `table_columns` (10498) and `abs_width`
   (5900) ask the fold first. The fold handles words and spaces with the wrap rules of `word/6`,
   markers, insets, boxes with widths and edges (the `rr` rules of `finish_box`, lines 5014 to
   5028, and the items' right edges per atom), inline boxes, images, inline-blocks (through the
   fold of their content), tables (columns sized once per table model), flex rows and columns
   with wrap, grids, multi-column boxes and floats at width 1. It refuses the rest (tabs,
   justified lines that would move words, right-to-left boxes, aspect ratios, percentage heights
   that resolve, clipped content that may reach past its box, fixed table layouts, and the other
   cases of design C section 2.2), and the measuring layout of today answers.
3. **Place** (line 3474): as today, with the memo consulted before every nested run and, from
   stage 4, the fragment table consulted at every safe span whose placer state is plain. A hit is
   replayed: its items are shifted by the difference in y, its positioned items get fresh paint
   order, its left-behind state is merged. A miss runs the ops and captures the fragment when the
   span changed nothing outside the declared state keys; the read set of a span is derived from
   one declared list, and an edit-differential gate checks it.
4. **Emit** (stage 5): one pass over the fragment tree that adds offsets and writes the flat
   list; `finalize/1` (line 3583) sorts only the positioned items; `add_focus/3` (line 308),
   `content_bottom/1` and the scroller items fold over fragments, not items.

### 5.3 Check modes and gates

Four checks guard the changes, and all of them run in CI on every layout PR (the CI workflow
edits go through Bess, since cloud sessions cannot push workflow files):

- `LAYOUT_CHECK=1` (sizes): every fold also runs the measuring layout it replaces and records
  or raises on a difference (design C's `LAYOUT_FOLD=check`, design B's `LAYOUT_CHECK`).
- The sweep (design C's `fold_sweep.exs`, moved into `Browser.Reftest` as a `mix reftest`
  option): all 11870 WPT files of the baseline folders laid out in check mode, with a bar of 0
  wrong results and a count of fallbacks per folder. The raster compare does not see a wrong
  width that keeps the picture the same; the sweep does.
- `LAYOUT_RETAIN=check` (retained state): every page laid out twice, cold and from the tables,
  and the two item lists compared with paint-order seqs and box refs left out (design A's
  `check_same!/2`); judge 1's twice-layout sweep over the 11870 files is the CI form of it.
- The edit-differential gate: for the bench pages and a sample of WPT files, mutate a text node
  or an attribute, lay out from the tables, and compare with a fresh layout. This is the only
  check that can find a state value a span reads but does not declare.

The 779 layout tests and `mix reftest --check` against the 6158 baseline stay the gate of every
PR. New layout tests go with the memo: an image that arrives between two layouts; a positioned
box inside an atom laid out twice (the multicol fieldset case); a kept memo across a view height
change.

### 5.4 What stays outside layout

`Browser.Session` gets a layout worker process per tab. `relayout/2` (session.ex:2589),
`start_layout_job/1` (2606) and `start_layout_for_scripts/4` (2326) all send their work to it,
and a stale reply is dropped by ref instead of a killed process. `Forms.render/4` keeps unchanged
nodes identical. `Style.prune/3` keeps a version stamp per element so a restyled tree can hit the
tables without a structural compare. `UI.index_page/1` rebuilds only the bands of changed items,
later per fragment. Scrollers, Editing, Selection, Nids, the reftest raster, screenshots and
`mix browser.layout` read the same flat list and do not change.

## 6. Expected gains

Reductions (Mred) on the five bench pages with the stub measurer, 1000 px. "Measured" means a
writer's prototype measured it and a judge reproduced it; "estimated" means a design derives it
from measured facts and no prototype has it yet. Today's numbers are from section 3 and the
judges' reruns of `main`.

| workload | today | after stage 1 | after stage 2 | after stage 3 | after stage 4 | after stage 5 |
|---|---|---|---|---|---|---|
| cold layout, article / news / shop / search / docs | 7.1 / 8.5 / 7.7 / 2.4 / 5.9 | same | same | 6.1 / 5.6 / 5.0 / 1.8 / 5.4 (measured, C edges version; article 4.2 once the float refusal is narrowed, measured on C's first version) | same | about 5% less (estimated: `move/3`, `finalize`) |
| resize to a new width, article / shop | 7.2 / 6.6 | same | 5.4 / 4.6 (measured, B: width-free entries hit; -25% against main's resize) | about 4 / 3 (estimated: the fold on top) | same | same |
| resize back to a seen width, article / shop | 7.2 / 6.6 | same | 1.3 / 1.3 (measured, B) | | 0.6 / 0.1 (measured, A) | about 0.2 / 0.05 (estimated) |
| edit at the same width, article / shop | 7.1 / 7.6 | same | 1.3 / 1.4 (measured, B) | same | 0.6 / 0.1 (measured, A) | about 0.2 / 0.05 (estimated: A step 8) |
| script-forced layout, one text node changed, article / news | 7.7 / 11.1 | same | 4.3 / 6.5 (measured by judge 1 on the real path: 36 to 85% of today across the five pages) | lower by the fold's share | 1.8 / 5.7 (measured, A, with version stamps standing in for the structural compare) | news to about 2 (estimated: retained column solutions, stage 6) |
| keystroke, patched field, end to end p50 (ms) | 17 to 20 | 6 to 9 (estimated, B step 8) | same | same | same | about 5 (estimated, A step 9) |
| backspace in a scrolled auto-width field, end to end p50 (ms) | 125 | 5.4 (measured, B, reproduced) | same | same | same | same |
| keystroke that needs a layout, layout part (ms) | 69 to 74 | same | about 25 (estimated: the memo) | about 20 | 8.5 to 11 (measured, A) | 1 to 3 (estimated: A step 8) |
| memory retained per page and width | 0 | 0 | 5 to 16 MB (measured, B; swept) | same | 4 to 12 MB of tables (measured, A; swept) | same |

In wall time on the VM: a cold layout of article from about 240 ms to about 150 ms after stage
3 (C measured 152 against 205 ms in the same build; the ratio is what to trust); an edit of
article from 250 ms to about 17 ms after stage 4 (A measured 16.7 ms) and to a few ms after
stage 5. On Bess's Mac the ratios hold and the absolute numbers are about half (the PR 7
numbers).

## 7. Plan

Every step is one PR against `main`. Gates for every step: the three layout test files (779
tests), `mix reftest --check` on the whole baseline (6158), and the checks of section 5.3 that
apply. Sizes: S under an hour, M a few hours, L a day or more, XL several days. Each step names
the measurement its PR reports; the number in brackets is where the step comes from (A, B, C
with the step number of that design). The prototype diffs in `notes/layout-redesign/designs/`
are the first draft of the steps they cover; the instrumentation in them (`stat/2`, `bump/1`,
`:layout_facts`, `retain_deep`) stays out of the PRs.

### Stage 1: foundations and typing fixes

| # | step | size | gate and measurement |
|---|---|---|---|
| 1 | Stable walk keys `{:k, nid, n}` for every `make_ref()` the walk makes; content memo keys `{:atom, sub, width, cbh, flags}` without `containing_width()`; the `boxes` flag in the atom key [B1, C2] | S | items identical with `check_memo.exs` and `check_resize.exs`; cold Mred within +2% |
| 2 | `Forms.render/4` keeps unchanged nodes identical; `Page.render/2` passes the previous tree [A1] | S | `render_identity.exs`: 666 of 670 element nodes identical after an edit; `mix test` |
| 3 | Typing, layout side: one-pass `add_focus/3` and `patch_field/6`; an emptied field is patched (zero-width space); placeholder guard in the session; the `patch_field_test.exs` bound [B7] | S | `patch_field_test.exs` equality for every patched keystroke; `bench/input_latency.exs` under Xvfb (first fix the `controlDown`/`metaDown` fields of its wxMouse record): backspace in the scrolled field 125 to 5 ms p50 |
| 4 | Typing, session side: `fit_scroll` pulls the scroll back on backspace; `UI.index_page/1` rebuilds only the bands of the changed items; `put_items` keeps `controls` and `links` when the patch did not touch them [B8] | M | `bench/input_latency.exs`: patched keystroke p50 without paint 13 to 17 ms to 6 to 9 ms |
| 5 | Check modes in CI: the twice-layout compare (`LAYOUT_RETAIN=check` form) and `LAYOUT_CHECK=1` as a reftest CI shard; the sweep (`fold_sweep.exs`) as a `mix reftest` option; the edit-differential script in `bench/` [A2, B3, C3, judge 1] | M | no gain; the safety net of stages 2 to 4; the workflow file goes to Bess |

Steps 1 and 2 are independent and change no layout output. Steps 3 and 4 are sequential. Step 5
is independent. Three threads at once: (1, 2), (3, 4), (5). First user-visible gain: step 3.

### Stage 2: one persistent atom memo in a layout worker

| # | step | size | gate and measurement |
|---|---|---|---|
| 6 | Kept memo: `layout/5` takes a memo and returns the memo it leaves; a hit renumbers paint-order seqs (`renumber_memo/1`); the epoch in the key (images, view height, metrics and measurer, SVG defs, `boxes`); keys compared structurally; a sweep by generation after each layout; a `keep_memo` switch as the fallback; new tests for an image that arrives between two layouts, a positioned box inside an atom laid out twice, and a view height change [B2, A4] | M | the twice-layout sweep over the 11870 files: 0 differences; `bench_mred.exs` with `KEEP_MEMO=1`: edit and seen-width resize at 17 to 34% of today; first resize article -25%; memo size per page |
| 7 | A layout worker process per tab owns the memo (and later the tables): `relayout/2`, `start_layout_job/1` and `start_layout_for_scripts/4` go through it; a stale reply is dropped by ref; the memo is dropped on navigation [B2, A5] | M to L | `bench/input_latency.exs` for the three fields; `forced_bench.exs` on the real script path (36 to 85% of today); a resize storm by hand; no copy of the memo in or out |

Step 7 needs 6. Stage 2 can run beside stage 3.

### Stage 3: intrinsic sizes without a layout (the fold)

Land the fold of `prototype_edges.diff` op kind by op kind behind `LAYOUT_FOLD`, off by default,
with the check mode and the sweep in CI from the first PR. Each PR extends the fold and refuses
the rest, so every PR is small and the fallback keeps the rest correct. Do not also build B's
hand-written word walks: `max_words`/`min_words` live on only as the plain-words fast path inside
the fold.

| # | step | size | gate and measurement |
|---|---|---|---|
| 8 | The fold core: words and spaces with the wrap rules of `word/6`, markers, anchors, empty inlines, breaks, clears, insets, boxes with and without edges (the `rr` and right-margin rules, the items' right edges per atom capped at the atom's width unless overflow counts), inline boxes, images; `shrink_extent`/`min_extent` ask it first; `LAYOUT_FOLD=check`; letter-spaced words, rtl boxes and the `floats-131` case fall back [C1 edges, B3 to B5] | L | sweep 0 wrong in all ten folders; `fold_check.exs`: fallbacks per page; cold Mred (docs -7%, article -4% expected from this part alone) |
| 9 | Inline-blocks and tables: an inline-block's sizes from the fold of its content plus its edges; the `table_column_sizes` memo per table model; cells folded when their items cannot reach past the table [C1, B6] | M | sweep; news -25% (the two inline-block runs, 2.0 Mred) |
| 10 | Flex, grid, multicol and floats: rows and columns with wrap, `flex_base`/`flex_min`/`track_sizes` through the fold, nested flex containers, floats at width 1 and the float rule at the unbounded width; narrow the float refusal that makes article's body fall back [C1, B6] | L | sweep incl. `css/css-flexbox/intrinsic-size`, `css/CSS2/floats`, `floats-clear`; bar: no fallback on a sub of more than 50 ops on the bench pages; shop -36%, search -25%, article -40% |
| 11 | Turn the fold on by default; remove the measuring-layout path for the constructs the fold handles only when a release has run with the check mode green [C1] | S | the whole baseline with `--check`; `bench/layout_pages.exs` and the five-page reductions in the PR |

Steps 8 to 11 are sequential. Expected after stage 3: the measured numbers of judge 1 on the edges
version (-24% in total) and of C's first version on article (-42%) once the float refusal is
narrowed.

### Stage 4: retained layout for edits and script layouts

| # | step | size | gate and measurement |
|---|---|---|---|
| 12 | Retained walk: the walk table keyed by `{nid, what, cw}` with `ctx`; `{:span, key, ops, safe?}` nesting; `safe_span?/1`; a `Layout.Ops` helper (`any?`, `map`, `reduce`) that looks into spans, used by every scan over a sub-op list; `LAYOUT_RETAIN=check` with `check_same!/2`; the `trim_line_end_spaces` per-block change left out (its own PR with a test if wanted); no fragment table yet [A2] | M | 779 tests and the baseline in check mode; the edit-differential gate; `walk_hit` on an edit; cold cost within +7% |
| 13 | Fragment table: `span_key/1` derived from one declared list, `span_state_ok?/1`, `capture_span/2` with its guard, `replay_span/2` with `renumber_pz/1`; the walk, fragment and memo keys carry the image infos the ops use and the epoch [A3, A4] | M | `bench_retain.exs` `same?` true on the five pages; edit 1 to 9% of today; `edit_bench.exs` 0.48 Mred per keystroke; the edit-differential gate |
| 14 | The tables live in the worker of step 7 as a `%Layout.Retained{}`; dropped on navigation and on a measurer change; swept by generation (four generations, four states per fragment key) [A5, A6] | M | keystroke p50 end to end for a field that needs a layout (A measured 17.4 ms with the tables in the caller); `cache_size.exs` bounded after five resizes |
| 15 | Version stamps: `@ver` kept by `Style.prune/3`'s memo (`memo_put/3`, `unshallow/1`) and by `Forms.render/4`; `retained/4` compares stamps [A7] | M | `forced_bench.exs`: the `same` column equals the `deep` column (20 to 52% of today) |
| 16 | Wider safety: spans whose floats end inside them, first children, transformed and sticky boxes [A10] | M | `frag_skip` 0 on the bench pages; floats and positioning folders in check mode |

Steps 12 and 13 are the critical path and cannot be split. 14, 15 and 16 can run as three
threads after 13.

### Stage 5: fragments, one emit pass, incremental consumers

| # | step | size | gate and measurement |
|---|---|---|---|
| 17 | Items relative to their box: `layout_atom` and a span return a fragment; `place_atom`, floats, cells, flex and grid items hand fragments up; one emit pass at the end of `place`; `finalize/1` sorts only positioned items; `content_bottom/1`, the rejects and `add_focus/3` fold over fragments [A8, C4] | L | the item-level check mode (both paths, lists compared) and the baseline; `move/3` and `finalize` calls; the warm floor of article 19 ms to 1 to 3 ms |
| 18 | Incremental consumers: bands per fragment merged in `UI.index_page/1`; `Layout.controls/1`, `UI.links/1`, `Nids.rects/2` per fragment; the painter's dirty rect from replaced fragments [A9] | L | `bench/input_latency.exs`: keystroke p50 toward 5 ms; `keystroke_prof.exs`: the passes over items gone |
| 19 | Remove `patch_field/6` and the branches of `relayout_edit/3` (about 25 lines plus the test file, which becomes a retained-path test of the same fixtures) [A12] | S | one layout path; the fixed-width field not slower |

### Stage 6: tables and the long tail

| # | step | size | gate and measurement |
|---|---|---|---|
| 20 | Tables as tuples: `table_layout`, `table_widths`, `column_positions` on tuples and maps by column [B10] | L | news: `Enum.drop_list` and `List.do_update_at` gone from the profile (13% of own time) |
| 21 | Retained column solutions: per-row min/max contributions keyed on the cells' keys; rows as spans when the solution is reused [A11] | L | news forced layout 130 ms to about 20 ms |
| 22 | Re-layouts without re-walks: cells at their row height and stretched flex items get a new constraint, not a rebuilt subtree [C7] | M | docs: re-layouts 16.5% of a layout |
| 23 | Optional: split the hot line state from `st`; parallel atom layouts in `Task.async_stream` for cells and flex items [B11, B12] | L each | wall time only; measure first with `LAYOUT_TIMES=1` |
| 24 | Only when a CSS feature needs it: one module per formatting context carved out of `op/2` with no behaviour change, one context per PR, gated by the item-level check mode; a retained box tree with raw lengths so a resize skips the walk, measured against the walk table of step 12 before it starts [C5, C6] | XL | the baseline per PR; no gain by itself; resize -9 to -18% (the walk) |

Steps 20 to 22 are independent; 21 and 22 need 17; 24 needs 17 and 20.

### Order, threads and early gains

Open steps 1, 2 and 3 first: three S PRs on three threads, none of which changes a layout rule.
Then steps 4 and 5 beside step 6. Step 6 (the kept memo) is the first big gain with the least
risk, because it adds a cache and changes no layout rule; its gate is the twice-layout sweep.
Stage 3 (the fold) is the cold gain and the highest risk (a silent wrong width), so step 5 lands
before step 8, and the fold stays off by default until step 11. Stage 4 composes with stage 3:
it caches whatever the placer produces. Stage 5 comes after the tables exist so that its gain
(the warm floor and the consumers' passes) is measurable on the retained path. Every stage ends
with a reply in the implementation thread that reports the measured numbers of its gates.

## 8. What this design does not fix

- The per-word cost of the final layout of each atom: the 30-key item map per word, the three
  `String.contains?` checks per word, `content_factor` and `line_px` per word, the about 20
  `Enum` passes per line in `flush/1`, `tail_extents/1` once per nested run. The first layout of
  every atom is 18 to 39% of a cold layout and stays. Only the optional step 23 touches it, and
  only wall time will show it.
- Real text measurement: 57 us per uncached `getTextExtent`, about 60 ms on a cold first layout,
  nothing warm. It is not a layout problem; the measure cache in `UI.measurer` handles it.
- A resize to a new width keeps most of its cost until the optional retained box tree (step 24):
  the walk resolves percentages against the containing width, and every retained key carries
  the width. Stages 2 and 3 take 25 to 45% off it; the rest is the final layout.
- Script-heavy pages that force a layout per mutation still pay `Page.from_raw/3` (2 to 5 ms on
  the bench pages) and the walk and placement of what changed, per forced layout. A mutation that
  touches many elements (a class on `body`) misses everywhere. Speedometer's layout share (about
  10%) will not fall much below that.
- Memory: 5 to 16 MB of memo and 4 to 12 MB of tables per page and width; the sweeps keep it at
  one layout's working set, and the worker keeps it out of the session's heap. A page with
  thousands of atoms at many widths holds more.
- The fold copies the width rules of `run`. A later change to a width rule in `run` must be made
  in the fold too; the check mode and the sweep catch a miss only where the WPT corpus or the
  bench pages exercise it.
- `Page.render` sharing no subtree is worked around by `Forms.render/4` for edits and by version
  stamps for restyles; the cascade itself is not changed.

## 9. Implementation status (2026-10-12)

- PR 251 (merged): stages 1 to 3, stage 4 steps 12 and 13, part of step 16, the start of steps 17 and 18.
- PR 252 (merged): stage 6 start. Table rows are tuples. Table and atom keys hash cells by their keys. A line's atoms are placed in one pass.
- PR 253: a span that is laid out keeps what it placed as one entry.
- Measured on the bench pages (stub measurer, Mred):
  - Edit layout: 0.1 to 0.3 (was 1.5 to 2.3).
  - Script-forced layout: 0.60 to 1.65 (was 2.6 to 10.6).
  - Cold layout plus resize: about -37% in total (-29% from the fold, then -12%).
  - Keystroke p50 with paint under Xvfb: about 8 ms, mostly the wx paint.
- Not done:
  - Step 16, the rest: floats that end inside spans, transformed and sticky boxes.
  - Step 17: item positions relative to their box, with the painter adding the offsets.
  - Steps 18 and 19: consumers per fragment, and removing `patch_field`.
  - Steps 21 to 24.
