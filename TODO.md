Draft TODO


Open problems

- Hide the preview's vertical scrollbar.
- Keep the titlebar opaque while scrolling so document text cannot show beneath it.
- Verify and improve Cmd-Tab coupling: sometimes Terminal comes forward without its paired preview.
- Continue testing whether Neovim plus Draft feels comfortable for general prose, LaTeX, quick notes, and AI-assisted research workflows.
- Consider whether a small preview status area would help once TeX/LSP diagnostics are available.
- Evaluate additional scientific-writing motions and keyboard controls only where the current Neovim and preview commands fall short.
- when doing ctrl+g on top of a \text{} the highlighted text on the preview should be what is inside the {} not the full paragraph as it is working now
- doing ctrl+g in the preview window should work this way: we need to put a small mark in the left side of the lines that acts like a cursor not in word by words so we dont have to implement a full nvim motions there but at leas beeing able to jump to the specified line. still the mouse selection should work perfectly as it seems to be working now.
- remove the :Ds :DraftSync that is just now the cntrl+g
- draft build :Db should display a message in the nvim status or under status bar idk what is the natural place that says pdf generated or something
- the draft note thing is just the same as draft preview but for a non main.tex i feel :Dp should work for all .tex and teh Draft build should be specific for main.tex

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

:Dp opens any current .tex file. draft/main.tex uses the manuscript workspace; other files render as fragments without a preamble or PDF build.

:Db builds only draft/main.tex. Explicit builds notify on PDF success or failure; successful save-triggered builds stay quiet.

Ctrl-G synchronizes source cursor or Visual selection to Preview and Preview reading position or browser selection to Neovim. The divider arrows call the same synchronization paths. :Ds, :DraftSync, and :DraftNote are removed.

The preview has a subtle left-margin reading mark. j/k move it through rendered lines, Ctrl-d/Ctrl-u scroll half a viewport and update it, and gg/G go to the ends. Mouse scrolling and clicks update its position. The vertical scrollbar is hidden without disabling scrolling.

The native window has a nontransparent titlebar and places the WebView below it. The native light/dark titlebar toggle remains. The companion window has red close, without minimize or zoom. The divider control is a nonactivating child panel at normal level.

A clean preview shows no diagnostics chrome. The conditional problem dot reports fast-renderer warnings or errors; it is not a TeX/LSP status area. Neovim remains the source of truth.

Open problems

- Cmd-Tab coupling is unresolved. The workspace state machine checks the foreground app and exact AX focused terminal window, but repeated Terminal/Safari/Terminal and Terminal A/B/A cycles have not been observed live after this pass. Terminal can still return without Draft above it; investigate event ordering and window ordering with live instrumentation rather than adding delays.
- Divider arrow focus, visibility, z-order, and smooth movement need live observation during focus changes and divider dragging. Their code paths are shared with Ctrl-G, and the child panel is nonactivating, but the interaction has not been verified in the real workspace.
- The reading mark and source/render correspondence need live tests for wrapped lines, UTF-8, inline commands, math, Visual and multiline selections, and browser mouse selection. Static checks do not establish visual precision.
- Titlebar opacity, theme appearance, and hidden scrollbar need live visual verification in both appearances while scrolling.

Current problems

The above GUI-dependent issues remain unverified and may require corrections. The fast preview renders a useful subset of LaTeX rather than a complete TeX document; the built PDF remains authoritative.

Near-term work

Run a real Neovim/Draft session on the example and a standalone fragment. Record at least ten Cmd-Tab Terminal/Safari/Terminal cycles and Terminal A/B/A cycles, including exact AX focused window and window ordering. Exercise focus shortcuts, divider arrows, shared resizing, hide/reopen, red close, theme, titlebar, reading mark, and mapping cases listed in Open problems. Fix observed failures, then revise this dashboard from those results.

Later ideas

Reader mode attached to the same source session.

Rendered editing translated back into Neovim source transformations, only after mapping is robust.

Texlab diagnostics through Neovim LSP, perhaps using the conditional problem surface. A permanent status area is not justified without real diagnostic data.

Scientific-writing motions for sentences, paragraphs, equations, environments, sections, and citations only where existing Vim/VimTeX behavior falls short.

Shared note/manuscript macros and preview structural reading motions if ordinary navigation proves insufficient.

AI operations on ordinary Neovim ranges rather than a separate editing state.

Decisions

Neovim owns files, edits, projects, Git, saving, and the durable LaTeX source. Draft is its native rendered companion.

Ctrl-G is the primary symmetric synchronization gesture; divider arrows are mouse equivalents. Preview has a visible, line/block-level reading mark, not an editing cursor. Browser selection takes priority for preview-to-source synchronization.

:Dp previews any .tex file. :Db and save-triggered PDF builds apply only to draft/main.tex. Notes need no document boilerplate or PDF.

The companion window is constrained by the paired workspace and shared divider. Reader mode and rendered editing are postponed. The PDF is authoritative for final manuscripts.

Open questions

Which macOS event and window-order sequence can reliably restore Draft beside its exact paired Terminal after Cmd-Tab without stealing focus?

What reader-mode geometry and restoration behavior should eventually be used?

How can future rendered edits preserve arbitrary LaTeX structure? Which Vim/VimTeX motions and Texlab signals are useful enough to expose in Draft?
