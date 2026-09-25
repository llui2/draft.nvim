# draft.nvim

A minimal Neovim writing setup for standard LaTeX manuscripts in a research
project's `draft/` directory.

## Commands

- `:DraftPreview`, `:Dp`, or `:Draft` toggles a borderless macOS preview window
  for the open `draft/main.tex`. With macOS Accessibility permission it tiles
  the active terminal and preview across the usable display (55/45), then
  restores the terminal's prior geometry when toggled closed. Without
  permission the preview still opens, but window tiling is skipped.
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
Allow the preview helper in the macOS Accessibility prompt for window tiling.

```sh
nvim --cmd "set runtimepath^=$(pwd)" example/draft/main.tex
```

Run `:Dp` to open the preview, type to update it, and save to build the PDF.
