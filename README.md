# Draft

Draft pairs Neovim with a native, live LaTeX preview on macOS. Neovim remains the editor; the built PDF is authoritative for manuscripts.

**Status: beta.** The fast preview covers common prose, headings, and math.

| Command | Action |
| --- | --- |
| `:Dp` | Toggle the preview for the current `.tex` file, including standalone fragments. |
| `:Db` | Build a `draft/main.tex` manuscript PDF. Saving that file also builds it quietly. |

With an active preview, `Ctrl-G` synchronizes the other surface to the current cursor, Visual selection, reading mark, or browser text selection. `Ctrl-W l` focuses Draft and `Ctrl-W h` returns to the paired terminal. In Draft, `j`/`k`, `Ctrl-D`/`Ctrl-U`, `gg`, and `G` move the reading position.

Install with a Neovim plugin manager. Preview requires macOS and Swift; paired layout requires Accessibility access. PDF builds require `latexmk` and LaTeX. KaTeX is bundled for offline rendering. See `:help draft`.
