# Draft

Draft makes Neovim comfortable for scientific writing. Neovim remains the
editor; Draft supplies a fast rendered companion for LaTeX manuscripts and
lightweight `.tex` notes.

Install this repository with your Neovim plugin manager. On macOS, the preview
requires Swift. For the paired terminal layout, grant Accessibility access.
Manuscript PDF builds also require `latexmk` and a LaTeX installation.

Open `project/draft/main.tex` and run `:Dp` for the live preview. Save to build
`draft/main.pdf`, or use `:Db`. For a standalone `.tex` fragment with no
preamble or PDF build, run `:DraftNote`.

The live preview uses bundled offline KaTeX and supports common headings,
prose, and math. The manuscript PDF remains the final rendering.

See `:help draft` for commands, prose movement, and navigation.
