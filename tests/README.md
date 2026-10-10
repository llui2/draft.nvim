# Draft checks

Run from the repository root:

```sh
luac -p plugin/draft.lua lua/draft/*.lua
nvim --headless -u NONE -i NONE -n -l tests/check.lua
nvim --headless -u NONE -i NONE -n -l tests/navigation.lua
nvim --headless -u NONE -i NONE -n -l tests/build.lua
nvim --headless -u NONE -i NONE -n -l tests/tikz.lua
node tests/preview.mjs
node tests/window.mjs /tmp/draft-window-check.swift
swift /tmp/draft-window-check.swift
swiftc -typecheck lua/draft/window.swift
```

`build.lua` runs real latexmk builds in temporary directories. `check.lua`
mocks helper compilation/lifecycle and build jobs; it does not open native windows.
`navigation.lua` follows a relative `.tex` link and verifies Ctrl-O/Ctrl-I use
Neovim's jump list while restoring the source cursor and preserving a local mark.
`tikz.lua` compiles TikZ diagrams, 2D PGFPlots labels and graphs, and 3D
surfaces. It checks editable SVG labels and arrows, source shift updates, nonblocking compilation,
all nine shipped templates, the Möbius compositing repair, the singular-surface
raster fallback, serial coalescing of 42 rapid requests, cache hits, and cache
invalidation when an external LaTeX input changes. These checks do not establish
native WebKit rendering. `preview.mjs` checks zoom-scaled pixel-to-point
conversion, TeX's vertical sign and cumulative label offsets. Its browser page
also simulates named-label and arrow drags, checks changedtick requests and rollback,
and verifies the label moves before the edit request is released.
`window.mjs` extracts the production geometry and foreground predicates and
exercises them without a desktop session.

For browser range/layout checks, generate a page in a temporary directory,
link its KaTeX assets, then serve it on loopback:

```sh
mkdir -p /tmp/draft-browser
ln -s "$PWD/lua/draft/katex" /tmp/draft-browser/katex
node tests/preview.mjs /tmp/draft-browser/check.html
python3 -m http.server 8765 --bind 127.0.0.1 --directory /tmp/draft-browser
```

Open `http://127.0.0.1:8765/check.html`. The page reports exact DOM range,
selection, incremental-rendering, reading-position, scroll and theme checks.
It also supports the production reading keys for manual inspection.

Native acceptance still requires a real paired Terminal/Draft session: ten
Cmd-Tab cycles through Safari, Terminal A/B isolation, both shared edges,
repeated hide/reopen and red close with frame restoration, divider ordering,
Ctrl-W focus, source/browser selection sync, Spaces and monitors. Passing the
checks above does not establish any of those native outcomes.

The preview checks also cover basic lists and nesting, quote/center, unknown
command argument preservation, bounded positional macros, math operators,
package declarations, UTF-8 declaration masking and diagnostic clipboard text.
The browser page finishes on `tests/fixtures/lightweight.tex`; its test buttons
expose warnings/errors and read back the system clipboard after copy clicks.
These controls belong only to the test page. Native WKWebView clipboard and
window acceptance still require a paired desktop session.

Preview profiling (2026-10-10, Apple Silicon, local TeX/Poppler):

| Measurement | Before | After |
| --- | ---: | ---: |
| TextChanged to atomic source publication | 105 ms | 41–42 ms |
| WebKit render, 200 paragraphs, 30 incremental edits, median / p95 | 1 / 4 ms | 2 / 5 ms |
| Identical complex figure | 2.46 s | 0.47–0.9 ms |
| Complex surface camera edit, two warm edits, total | 2.60–2.66 s | 2.51–2.52 s |
| Same camera edits, latexmk only | 2.55–2.59 s | 2.43–2.44 s |
| Same camera edits, PDF-to-SVG | 43–66 ms | 70–72 ms |

These are observations, not timing assertions. WebKit render times are noisy
at its 1 ms clock resolution; no significant renderer speedup is claimed.
The main prose improvement is earlier, throttled publication, without resetting
WebKit on each prose edit. The helper retains its 25 ms file-read delay; full
keystroke-to-paint latency in a paired Terminal/Draft session was not measured.
First complex compilations still take roughly 2.5–3 s. Higher-resolution shading
makes conversion slightly more expensive; serialization and caching avoid
redundant compilation instead of claiming to accelerate TeX itself.

Live rendering follow-up (2026-10-10): the earlier isolated WKWebView checks
missed failures in the full Draft preview. Each template was opened individually
through the production Neovim plugin, source/command file watchers and native
helper, and visually compared with the PDF from that actual compilation. A
copy of the helper was packaged temporarily as an app, with only its foreground
window bootstrap adjusted for a headless Neovim source; its rendering and
transport code were unchanged. No template mathematics was edited.

| Template | Compilation | Original live display | Final live display |
| --- | --- | --- | --- |
| annotated-curves | Passed | Correct | Correct, SVG |
| flow-schematic | Passed | Correct | Correct, SVG |
| network-diagram | Passed | Correct | Correct, SVG |
| phase-portrait | Passed | Correct | Correct, SVG |
| vector-field-3d | Passed | Correct | Correct, SVG |
| three-dimensional-surface | Passed | Missing shading and clipped axes | Correct, SVG |
| radial-surface | Passed | Missing shading and clipped axes | Correct, SVG |
| mobius-strip | Passed | Blank | Correct, SVG |
| singular-surface | Passed | Correct with existing PDF fallback | Correct with existing PDF fallback |

There are two SVG issues: Cairo's filter inputs need full viewport bounds,
and WKWebView evaluates referenced groups before their embedded PNG shading
is decoded, without repainting those filters when decoding finishes. Decode
the existing images before installing the SVG; retain the last valid figure
until then and discard stale decode completions. Rewriting SVG IDs and forcing
an extra frame did not reliably fix the first display, so those experiments
were removed. Vector axes, labels and paths remain intact in eight templates.
Cairo's PNG shading stays at 300 dpi. The singular surface renders after the
decoding fix but still has visible filter seams absent from its PDF, so its
existing 300 dpi PDF fallback remains necessary. No new renderer or dependency
was added; that fallback has no draggable SVG nodes.

No compilation failure was reproduced in any unchanged template, including
repeated switching. Actual LaTeX logs reported success. An undefined command
in an unsaved test buffer produced a real file/line LaTeX error: Draft now
opens its existing diagnostic panel automatically with that error and source
line, while keeping the valid figure. Correcting the buffer recovered normally.

Latest measurements: source publication 41.8 ms; complete compile/conversion
for Gaussian surface 2.48 s, radial surface 2.33 s, Möbius strip 1.07 s,
vector field 0.73 s and singular surface 3.05 s. The earlier check run before the image-readiness fix
was 2.53 s, 2.42 s, 1.05 s, 0.72 s and 3.07 s respectively; these small differences
are noise, not a compilation speedup. A cached complex figure took 0.33 ms;
42 compile requests produced two serial builds in 4.91 s. Thirty camera edits
at 50 ms intervals through live Draft TextChanged events also produced only
two builds, with maximum concurrent latexmk count one; the latest 75-degree
camera view was inspected in the native window against its PDF.

All nine final native displays were inspected for labels, colors, shape,
clipping and perspective. The existing browser page passed 48 checks, including
node dragging, synchronization, navigation, retained figures during decoding,
stale decode rejection and visible errors. The Neovim navigation/build checks
also passed. This does not establish paired Terminal keyboard typing latency,
physical native label dragging, selection synchronization, focus/Spaces or
monitor/window lifecycle behavior; those macOS acceptance checks remain open.
