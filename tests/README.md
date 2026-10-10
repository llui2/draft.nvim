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
`tikz.lua` compiles a TikZ diagram, a 2D PGFPlots label, a 2D graph and a 3D
surface, checks SVG node IDs and saved offsets, and verifies compilation does
not block Neovim's event loop. It also compiles all nine shipped templates,
checks the Möbius compositing repair and singular-surface raster fallback,
coalesces 42 rapid requests into two serial builds, measures cached output,
and invalidates that cache when an external LaTeX input changes. `preview.mjs` checks zoom-scaled pixel-to-point
conversion, TeX's vertical sign and cumulative label offsets. Its browser page
also simulates a named-label drag, checks the changedtick request and rollback,
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

The comparison used unmodified PDFs from all five 3D templates and snapshots
of the production preview page in a temporary native WKWebView. The Möbius
PDF and Chrome SVG were correct, but WebKit dropped its empty Cairo filter
destination. A transparent bounding rectangle restores SVG compositing.
Cairo's multiple shading tiles introduce visible seams in the singular surface;
that case alone uses a 300 dpi raster of the original PDF. Other figures retain
SVG axes, labels, paths and editable node IDs. Cairo's embedded interpolated
shading images are also generated at 300 dpi. Raster fallbacks do not expose
draggable SVG nodes. Templates and their mathematical content are unchanged.

The native snapshots were checked against PDF renders for labels, colors,
surface shape, clipping and perspective. They validate rendering, not the
paired window's focus, positioning, live typing or synchronization behavior.
The existing browser regression page covers dragging, rejected-edit rollback,
UTF-8 synchronization, document navigation and DOM retention during compilation.
