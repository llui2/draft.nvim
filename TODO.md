Draft TODO


User thoughts

- the cmd+shift coupling still doesnt work perfectly some times wwhen i tab only the terminal window gets carried to the front and the preview window it left behind.
- i am still not sure if it is best to treat the preview window as a fully independent window or to constrain what kind of actions one can do there, i think minimize and move resize motions dont make a lot of sense, but the close red one does.
- there is a lot of stuff of interplay with the nvim system of this software that i should consider and i am not yet. neovim seems to me a very good system for coding but can it also be a very good system for general text editing. specially with latex or quick note taking.
- one of the main problems with plain text is that a line is wraped over different nvim lines, that makes sense for code and probably there is a way of thinking that it also makes sense for text but then jumpping from word to word vertically feels very unnatural proabably there is a nvim setting to make it so that inside .tex or .md files one can use a configuration of the lines such that when moving in a small window with a line of text wrapped one can move freely with the h j k l movements between words more natural.
- i think i would like to consider a system on the preview where one can also visualize some usefull info at the top if needed. probably the tex lsp should be implemented at some point so one can track errors.
- also i should probably create a documentation for all the commands and stuff one can do.
- also think about how much sense a software like this for researchers in this new era of heavely ai usage + nvim for latex fit. the personalization allowed on nvim is huge so probably there is a way to make this a sort of software that is comfortable.
- also it might make sense to integrate a .tex system that is not based for the final rendering but rater as just note taking without generating the .pdf one might want to have some latex text without having to define \document having to start the full configuration more like a .md note with equations but the fact is that most of .md equations need to use $$ and dont allow for more advanced configuration of nvim operators etc. latex allos a rich amout of things that probably are not configured in obsidian and oder .md editors (actually this might be a strong point for why building this)


Current direction

Neovim owns the workflow. Draft owns the rendered surface.

Draft should extend the normal Neovim workflow used for code, repositories, notes and scientific writing rather than becoming an autonomous editor or document application. Files, projects, Git, LSP, AI tools, editing, undo and saving remain Neovim concerns.

Draft is a native macOS rendered companion attached to an exact Neovim session and source buffer. Its own window is valuable because rendering, reading and future richer interaction need a real native surface, but Draft should not grow its own file browser, project model or independent document lifecycle.

The default experience is companion mode: Neovim and Draft are coupled side by side, with keyboard navigation and bidirectional source/render synchronization.

A future reader mode may temporarily release the constrained side-by-side geometry so the same rendered note or manuscript can be read or studied comfortably. It still belongs to the active Neovim source/session and should return to companion mode cleanly.

A much later experiment may allow direct rendered editing, somewhat like a Word-style scientific text view. Any such edit should become a source transformation applied back into the Neovim buffer so Neovim remains the source of truth. Do not build this until source/render synchronization is extremely solid.


Working principles

Keep ordinary LaTeX and Git text as the durable representation.

Use Neovim for editing, motions, selections, text objects, snippets, completion, LSP, Git and future AI actions.

Use Draft for rendering, reading, source/render correspondence and lightweight interaction with the rendered document.

Do not create a Draft-specific markup language.

Do not duplicate features that Neovim already handles well.

The preview should be keyboard-first. Mouse controls are useful secondary representations of the same underlying operations.

The source/render mapping should be treated as a central primitive that future diagnostics, equations, citations, search, reader mode and AI actions can reuse.

The PDF remains authoritative for final manuscript rendering.


Interaction model

Moving between the two surfaces should feel closer to moving between Neovim splits than switching between unrelated applications.

From Neovim, Ctrl-w l should focus the paired Draft surface when appropriate. From Draft, Ctrl-w h should return to the exact paired Terminal/Neovim window. Normal Neovim behavior must remain available when no Draft companion is active.

The main synchronization action should be one symmetric keyboard command usable from both surfaces.

Preferred primary chord: Ctrl-G.

From Neovim, Ctrl-G means: synchronize Draft to the current cursor or Visual selection.

From Draft, Ctrl-G means: synchronize Neovim to the current preview reading position or browser text selection.

This should call one underlying sync primitive. Divider arrows and any colon-command aliases must use the same implementation.

:Ds or :DraftSync may remain as fallback/discoverable aliases if useful, but they are not the primary interaction.

Draft preview does not need a fake editing cursor for this. It has a reading position.

Preview reading position priority:

active browser text selection
last clicked mapped rendered element
mapped rendered element nearest the vertical center of the viewport

The reading position is normally invisible. When synchronization is invoked, a short transient highlight may show the mapped destination.

Preview keyboard reading motions should stay small and Vim-like:

j and k scroll approximately one rendered line
Ctrl-d and Ctrl-u move roughly half a viewport
gg goes to the top
G goes to the bottom
Ctrl-w h returns to Neovim

Do not implement a full Vim emulator in the preview.


Window model

Draft should remain a native window because that leaves room for a strong rendered reading surface and future rendered interaction.

However the default mode is still tightly coupled to Neovim.

Companion mode should constrain geometry and make the shared divider the normal resizing mechanism. Red close makes sense. Independent minimize, zoom, moving and arbitrary resizing are not important in this mode.

Reader mode is a future presentation mode, not a separate application. In reader mode, normal movement, resizing and fullscreen may make sense because the purpose is reading/studying rather than side-by-side editing.

Do not confuse a native Draft window with an autonomous Draft workflow. Neovim should still launch it, own the source buffer and determine its lifecycle.

The current Cmd-Tab problem should not be papered over with more arbitrary delays. The exact paired Terminal window and the Draft companion should have a clear state model. If macOS cross-process ordering prevents perfect automatic coupling, document the limitation rather than accumulating fragile activation hacks.

Keyboard navigation inside the writing workspace should be reliable even if Cmd-Tab remains inherently imperfect.


Manuscripts and notes

Manuscript mode uses full LaTeX projects and PDF builds.

Note mode uses lightweight LaTeX fragments without document boilerplate or a required PDF.

Both should use the same scientific writing language and as much of the same Neovim tooling as possible.

A note should be able to graduate into a manuscript largely by moving LaTeX source rather than converting formats.

Shared mathematical macros between notes and manuscripts may become valuable later.


Current state

:Dp previews draft/main.tex with local live rendering and a paired 55/45 workspace when Accessibility permits.

:Db and save build the manuscript PDF.

:DraftNote previews ordinary .tex fragments without document boilerplate or PDF generation.

Previewed buffers use prose-oriented wrapping and count-aware j/k movement.

Source ranges and rendered ranges already have bidirectional mapping foundations.

The native preview is implemented with AppKit/WKWebView and local KaTeX.

The example manuscript and Neovim help should increasingly serve as the reliable description of features that actually work on main.


Current problems

Cmd-Tab / macOS foreground ordering is still not fully reliable and must not be described as solved until repeatedly tested on the real machine.

The divider arrow control has also felt clunky and should be treated as a secondary UI for the same keyboard sync primitives rather than unique navigation logic.

The fast renderer supports only a useful LaTeX subset and should add syntax only when it materially improves the writing workflow.

Source/render selection behavior, Unicode offsets and equations need continued real-world testing.

The distinction between companion mode and a future reader mode still needs a clean implementation design.


Near-term work

Make Ctrl-G the primary symmetric synchronization action on both Neovim and Draft, scoped so it does not disrupt unrelated buffers or sessions.

Make Ctrl-w l and Ctrl-w h reliable for moving between the paired Neovim and Draft surfaces.

Keep :Ds / :DraftSync only as optional aliases or debugging/discoverability paths.

Polish preview reading motions: j, k, Ctrl-d, Ctrl-u, gg and G.

Make divider arrows use exactly the same synchronization primitives as the keyboard path.

Keep improving the paired-window state model, but stop adding arbitrary Cmd-Tab timing hacks.

Keep example/draft/main.tex as a compact live tutorial and manual integration test for behavior that actually works.

Keep doc/draft.txt synchronized with the implemented command/motion surface.

Render common commands such as \texttt{...} correctly in the fast preview without breaking source mapping.

After interaction is solid, consider Texlab diagnostics through Neovim LSP and only a minimal conditional status surface in Draft.


Later ideas

Reader mode: temporarily release companion geometry for clean reading/studying while remaining attached to the same Neovim source/session.

Rendered editing experiment: allow direct prose edits in Draft and translate them back into source edits in the Neovim buffer. Raw LaTeX remains available for precise structural work. This could eventually offer a Word-like scientific writing surface without abandoning Neovim. The difficult problem is preserving arbitrary LaTeX structure while mapping rich-text edits back safely.

Texlab diagnostics sourced from Neovim LSP, possibly summarized by a very small status strip only when errors or warnings exist.

Scientific-writing text objects and motions for sentences, paragraphs, equations, environments, sections and citations where existing Neovim/VimTeX behavior is insufficient.

Shared note/manuscript macros.

Preview structural reading motions such as next/previous section or equation, only if normal scrolling proves insufficient.

AI actions as transparent transformations of ordinary Neovim ranges rather than a separate chat/editor state.


Decisions

Neovim is the source of truth and remains the primary editor.

Draft is not intended to become a fully autonomous application with its own files/projects.

A native Draft window is still important and should remain.

Companion mode is the default writing mode.

Reader mode is a possible future presentation mode attached to the same Neovim session.

Future rendered editing, if attempted, must write back through Neovim rather than creating an independent Draft document state.

The preferred symmetric source/render synchronization gesture is Ctrl-G on both sides.

Preview uses a reading anchor rather than a fake editing cursor.

Keyboard interactions are primary; divider arrows are secondary controls.

Prose settings apply only to buffers explicitly participating in Draft rather than all .tex/.md files globally.

Notes remain LaTeX-native. No new markup language or note database.


Open questions

What is the cleanest macOS implementation for maintaining the companion relationship while still keeping Draft as a genuine native window?

How much Cmd-Tab coupling is realistically reliable across separate processes without stealing focus or introducing fragile ordering hacks?

What exact behavior should reader mode use for entering, leaving and restoring companion geometry?

How far can rendered editing go while keeping arbitrary LaTeX source structurally safe and Neovim-native?

Which existing Vim/VimTeX prose and LaTeX motions should Draft simply expose/document rather than reimplement?

What is the smallest useful diagnostic signal to mirror from Neovim into Draft?
