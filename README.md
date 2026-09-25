# draft.nvim

A small Neovim plugin foundation for writing standard LaTeX in a research
project's `draft/` directory. The live rendered preview is not implemented yet.

## Current commands

- `:Draft` or `:DraftPreview` detects the project and reports that live preview
  is not available yet.
- `:DraftBuild` runs `latexmk` asynchronously for `draft/main.tex`. Auxiliary
  files go in `draft/.build/`; on success, the generated PDF is copied to
  `draft/main.pdf`.

Project detection walks upward from the current file (or working directory)
looking for `draft/main.tex`. The expected manuscript files are
`draft/main.tex` and `draft/references.bib`.

## Try it

Open Neovim in this repository with the plugin on the runtime path, for example:

```sh
nvim --cmd "set runtimepath^=$(pwd)" example/draft/main.tex
```

Then run `:DraftBuild`. The example requires `latexmk` and a LaTeX installation
with `pdflatex`.
