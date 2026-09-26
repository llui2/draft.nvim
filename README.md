# draft.nvim

A minimal Neovim writing setup for standard LaTeX manuscripts in a research
project's `draft/` directory.

## Commands

- `:DraftPreview`, `:Dp`, or `:Draft` toggles a native macOS window
  for the open `draft/main.tex`. With Accessibility access, it arranges the
  terminal and titled “Draft” window across the screen's usable area: terminal
  on the left two-thirds and Draft on the right third. Drag either side of the
  shared divider to resize the split. Closing Draft with `:Dp` or its close
  button restores the terminal's original position and size. Draft remains a
  standard macOS window with normal resizing and minimizing behavior.
- `:DraftBuild` or `:Db` builds `draft/main.tex` in the background.

The preview updates while typing and supports paragraphs, `\section{}`,
`\subsection{}`, inline `$...$`, and display `\[...\]` math. KaTeX is loaded
from jsDelivr, so the first preview requires an internet connection. The
preview is intentionally not a full LaTeX renderer.

Saving `draft/main.tex` starts a background PDF build. Builds are serialized;
after a successful build the PDF is copied to `draft/main.pdf`, while auxiliary
files stay in `draft/.build/`. Project detection walks upward from the current
file or working directory looking for `draft/main.tex`.

## Try it

On macOS, with Neovim, Swift, `latexmk`, and a LaTeX installation available.
Accessibility permission is required to identify, resize, and observe the
terminal for split mode. Without it, Draft warns and opens as a separate normal
window without changing the terminal.

```sh
nvim --cmd "set runtimepath^=$(pwd)" example/draft/main.tex
```

Run `:Dp` to open the preview, type to update it, and save to build the PDF.
