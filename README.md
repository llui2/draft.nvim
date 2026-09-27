# Draft

Early experiment in writing LaTeX with Neovim and a separate rendered preview
window. Neovim handles editing; Draft shows a live view of the source.

**Status: beta.** The preview covers a useful subset of LaTeX, and window
pairing and source/preview navigation still need testing. For manuscripts, the
built PDF is the final rendering.

## Current commands

| Command | Action |
| --- | --- |
| `:Dp` | Toggle the live preview for `draft/main.tex`. |
| `:Db` | Build `draft/main.pdf` with `latexmk`. Saving `main.tex` also starts a build. |
| `:DraftNote` | Preview a standalone `.tex` note without a preamble or PDF build. |
| `:Ds` / `:DraftSync` | Sync the source position or selection to the preview. |

With an active preview, `Ctrl-G` syncs positions and selections in either
direction. `Ctrl-W l` moves from Neovim to Draft; `Ctrl-W h` returns to the
paired terminal. The preview also accepts `j`/`k`, `Ctrl-D`/`Ctrl-U`, `gg`,
and `G` for reading.

## Requirements

Install with a Neovim plugin manager. The preview requires macOS and Swift.
The paired terminal layout requires Accessibility access. PDF builds require
`latexmk` and a LaTeX installation. The live preview uses bundled offline
KaTeX.

See `:help draft` for the full command and navigation reference.
