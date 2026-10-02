# Draft

Draft pairs Neovim with a native, live LaTeX preview on macOS. Neovim remains the editor; the built PDF is authoritative for manuscripts.

**Status: beta.** The fast preview covers common prose, headings, and math. Native window coupling still needs live macOS acceptance tests.

| Command | Action |
| --- | --- |
| `:Dp` | Toggle the preview for the current `.tex` file, including standalone fragments. |
| `:Db` | Resolve and asynchronously build the project's `draft/main.tex` to `draft/main.pdf`. Saving the manuscript also builds it quietly. |

With an active preview, `Ctrl-G` synchronizes the other surface to the current cursor, Visual selection, reading mark, or browser text selection. `Ctrl-W l` focuses Draft and `Ctrl-W h` returns to the paired terminal. In Draft, `j`/`k`, `Ctrl-D`/`Ctrl-U`, `gg`, and `G` move the reading position.

Companion mode uses the captured Terminal window's screen: 55/45 panes, a 2 px gap, and a shared divider. Drag Terminal's right edge or the strip inside Draft's left edge. Closing or hiding restores the saved Terminal frame. Cmd-Tab, Terminal A/B isolation, and native resize/focus behavior remain unverified in the current stabilization pass.

Install with a Neovim plugin manager. Preview requires macOS and Swift; paired layout requires Accessibility access. PDF builds require `latexmk` and LaTeX. KaTeX is bundled for offline rendering. See `:help draft`.
