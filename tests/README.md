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

`tikz.lua` compiles all nine templates, checks that 3D PGFPlots uses a
300 dpi PNG generated directly from the compiled PDF, and that ordinary 2D
figures remain SVG with source-backed draggable labels and arrows. It also
checks compilation errors, the latest-only queue, caching, and input
invalidation. The preview uses Poppler's `pdftocairo` for both paths.

`preview.mjs` checks rendering logic, figure image mode, compact display
width, pencil visibility, and 2D node drag math. To run browser checks:

```sh
mkdir -p /tmp/draft-browser
ln -s "$PWD/lua/draft/katex" /tmp/draft-browser/katex
node tests/preview.mjs /tmp/draft-browser/check.html
python3 -m http.server 8765 --bind 127.0.0.1 --directory /tmp/draft-browser
```

Open `http://127.0.0.1:8765/check.html` and check the results.

The production Draft preview and macOS WKWebView appearance must still be
verified in a paired Neovim/Draft session, with direct visual comparison to
the compiled PDFs. Headless checks cannot establish that the four reference
3D plots look identical to Overleaf. Native window focus, source sync, and
physical label dragging likewise require macOS acceptance tests.
