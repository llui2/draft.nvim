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
not block Neovim's event loop. `preview.mjs` checks zoom-scaled pixel-to-point
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
