# Draft checks

Run from the repository root:

```sh
luac -p plugin/draft.lua lua/draft/*.lua
nvim --headless -u NONE -i NONE -n -l tests/check.lua
nvim --headless -u NONE -i NONE -n -l tests/build.lua
node tests/preview.mjs
node tests/window.mjs /tmp/draft-window-check.swift
swift /tmp/draft-window-check.swift
swiftc -typecheck lua/draft/window.swift
```

`build.lua` runs real latexmk builds in temporary directories. `check.lua`
mocks helper compilation/lifecycle and build jobs; it does not open native windows.
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
