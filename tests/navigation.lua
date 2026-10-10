-- Run from the repository: nvim --headless -u NONE -i NONE -n -l tests/navigation.lua
vim.opt.runtimepath:prepend(vim.fn.getcwd())
vim.o.hidden = true
local root = vim.fn.resolve(vim.fn.tempname())
vim.fn.mkdir(root .. "/templates", "p")
local index = root .. "/draft.tex"
local target = root .. "/templates/target.tex"
vim.fn.writefile({ "Index", "\\href{templates/target.tex}{Target}", "End" }, index)
vim.fn.writefile({ "Target first line", "Target second line" }, target)
vim.cmd.edit(index)
local source_buffer = vim.api.nvim_get_current_buf()
local source_cursor = { 2, 5 }
vim.api.nvim_win_set_cursor(0, source_cursor)
vim.api.nvim_buf_set_mark(source_buffer, "z", 2, 2, {})

local preview = require("draft.preview")
local opened = preview.open_link("templates/target.tex", 11)
assert(opened, "open link failed from " .. vim.api.nvim_buf_get_name(0) .. " target=" .. target)
assert(vim.fs.normalize(vim.api.nvim_buf_get_name(0)) == vim.fs.normalize(target), "unexpected current buffer: " .. vim.api.nvim_buf_get_name(0))
assert(require("draft.sync").buffer == vim.api.nvim_get_current_buf())
assert(vim.deep_equal(vim.api.nvim_buf_get_mark(source_buffer, "z"), { 2, 2 }))

local function key(sequence)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(sequence, true, false, true), "nx", false)
end
key("<C-O>")
assert(vim.fs.normalize(vim.api.nvim_buf_get_name(0)) == vim.fs.normalize(index), "Ctrl-O should return to the source document")
assert(vim.deep_equal(vim.api.nvim_win_get_cursor(0), source_cursor), vim.inspect(vim.api.nvim_win_get_cursor(0)))
key("<C-I>")
assert(vim.fs.normalize(vim.api.nvim_buf_get_name(0)) == vim.fs.normalize(target), "Ctrl-I should move forward to the linked document")

vim.api.nvim_set_current_buf(source_buffer)
vim.api.nvim_win_set_cursor(0, { 2, 7 })
vim.cmd("normal! gf")
assert(vim.fs.normalize(vim.api.nvim_buf_get_name(0)) == vim.fs.normalize(target), "gf should open the filename inside the LaTeX link")

assert(not preview.open_link("https://example.com", 0), "external links must not be opened as local files")
assert(not preview.open_link("missing.tex", 0), "missing local links must fail safely")
assert(vim.fs.normalize(vim.api.nvim_buf_get_name(0)) == vim.fs.normalize(target))

vim.fn.delete(root, "rf")
print("Draft: linked-document navigation and native jump history passed")
