# draft.nvim

A minimal Neovim writing setup for standard LaTeX manuscripts in a research
project's `draft/` directory.

## Commands

- `:DraftPreview`, `:Dp`, or `:Draft` toggles a native macOS companion window
  for the open `draft/main.tex`. It opens beside the terminal running this
  Neovim session when possible, without changing the terminal's size or
  position. The preview can be moved and resized normally; its size is retained
  while it is open. When the terminal moves or resizes, the preview follows
  while keeping its own size. The accessory-style preview hides when another
  app is activated and returns when you switch back to the terminal.
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
Accessibility permission is optional. It lets the helper identify and observe
the terminal window so the preview can follow its movement and resizing;
without permission, the preview still opens at a sensible screen position but
cannot track the terminal.

```sh
nvim --cmd "set runtimepath^=$(pwd)" example/draft/main.tex
```

Run `:Dp` to open the preview, type to update it, and save to build the PDF.
