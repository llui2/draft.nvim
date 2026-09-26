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

Neovim is the editor; Draft is its rendered companion. Manuscripts use full LaTeX and PDF builds. Notes use LaTeX fragments with fast rendering and no PDF.


Working principles

Keep source as ordinary LaTeX and Git text. Use Neovim motions, selections, LSP and future AI operations on source ranges. Keep the preview small and offline; the PDF is authoritative for manuscripts. Preserve user thoughts above verbatim.


Current state

:Dp previews draft/main.tex with live local KaTeX, source navigation and a 55/45 split when Accessibility permits. :Db and save build the manuscript. :DraftNote previews an ordinary .tex fragment without a document wrapper or PDF. Previewed buffers gain local prose wrapping and count-aware j/k. Local KaTeX, source range sync and an explicit macOS workspace state are in place.


Current problems

Cmd-Tab pairing may intermittently leave Draft behind; live Terminal/Safari/Terminal and multiple-window testing is needed. macOS does not provide a true cross-process shared window group. Fast preview covers only a useful LaTeX subset.


Near-term work

Exercise the GUI workflow, divider, minimize and close on macOS. Verify selection mapping for Unicode and equations. Add focused tests where they catch real regressions.


Later ideas

Add Texlab through Neovim LSP; Draft may display a small diagnostics count only when useful. Explore sentence, equation, environment, section and citation text objects. Keep AI edits as transparent operations on ordinary Neovim ranges.


Decisions

Prose settings apply only to buffers explicitly previewed by Draft, not every .tex or .md file. Countless j/k use display lines; numeric counts keep logical lines. Existing user mappings take precedence. Explicit :DraftNote selects fragment mode; :Dp remains manuscript-specific. No manifest or new markup language.


Open questions

Can AppKit reliably keep an accessory Draft panel above exactly its paired Terminal window through Cmd-Tab without stealing focus? Should note mode eventually be inferred from fragment structure? What minimal diagnostic signal is worth showing in the companion?
