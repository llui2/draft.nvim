-- Run from the repository: nvim --headless -u NONE -i NONE -n -l tests/check.lua
vim.opt.runtimepath:prepend(vim.fn.getcwd())
vim.o.swapfile = false
vim.cmd.runtime("plugin/draft.lua")
local notices = {}
vim.notify = function(message) table.insert(notices, message) end
local function eq(actual, expected)
  assert(vim.deep_equal(actual, expected), vim.inspect(actual) .. " ~= " .. vim.inspect(expected))
end
for _, command in ipairs({ "Dp", "Db" }) do eq(vim.fn.exists(":" .. command), 2) end
for _, command in ipairs({ "Ds", "DraftSync", "DraftNote" }) do eq(vim.fn.exists(":" .. command), 0) end

local root = vim.fn.tempname()
vim.fn.mkdir(root .. "/draft", "p")
vim.fn.mkdir(root .. "/notes", "p")
vim.fn.writefile({ "\\documentclass{article}", "\\begin{document}", "hello", "\\end{document}" }, root .. "/draft/main.tex")
local project = require("draft.project")
eq(project.draft_dir(root .. "/draft/main.tex"), root .. "/draft")
eq(project.draft_dir(root .. "/notes/idea.tex"), root .. "/draft")
local fragment = vim.fn.tempname()
vim.fn.mkdir(fragment .. "/draft", "p")
vim.fn.writefile({ "Just a fragment" }, fragment .. "/draft/main.tex")
eq(project.draft_dir(fragment .. "/draft/main.tex"), nil)
eq(project.draft_dir(fragment .. "/scratch.tex"), nil)

local sync = require("draft.sync")
vim.api.nvim_buf_set_lines(0, 0, -1, false, { "Lluís α 😀", "second line", "third" })
sync.set_buffer(vim.api.nvim_get_current_buf())
vim.api.nvim_win_set_cursor(0, { 1, 7 })
eq(vim.json.decode(sync.source_position()), { start = 7, finish = 9, mode = "cursor" })
vim.api.nvim_win_set_cursor(0, { 1, 10 })
vim.cmd("normal! v")
sync.capture_visual()
local selected = vim.json.decode(sync.source_position_for_sync())
eq(selected, { start = 10, finish = 14, mode = "char" })
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)
-- A selection ending at a line boundary must not include the next line's first byte.
assert(sync.jump_to_source(0, 15, "char"))
eq(vim.api.nvim_win_get_cursor(0), { 1, 14 })
assert(sync.jump_to_source(7, 9, "char"))
eq(vim.api.nvim_win_get_cursor(0), { 1, 7 })
assert(sync.jump_to_source(15, 26, "char"))
eq(vim.api.nvim_win_get_cursor(0), { 2, 10 })
assert(sync.jump_to_source(15, 15, "cursor"))
eq(vim.api.nvim_win_get_cursor(0), { 2, 0 })
assert(sync.jump_to_source(26, 15, "char"))
eq(vim.api.nvim_win_get_cursor(0), { 2, 10 })
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)
sync.set_buffer(vim.api.nvim_get_current_buf())
vim.api.nvim_win_set_cursor(0, { 2, 0 })
vim.cmd("normal! V")
vim.api.nvim_win_set_cursor(0, { 3, 0 })
sync.capture_visual()
eq(vim.json.decode(sync.source_position_for_sync()), { start = 15, finish = 32, mode = "line" })
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)
sync.set_buffer(vim.api.nvim_get_current_buf())
vim.api.nvim_win_set_cursor(0, { 2, 0 })
vim.cmd("normal! v")
vim.api.nvim_win_set_cursor(0, { 2, 5 })
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)
eq(vim.json.decode(sync.source_position_for_sync()), { start = 15, finish = 21, mode = "char" })
eq(vim.json.decode(sync.source_position_for_sync()), { start = 20, finish = 21, mode = "cursor" })

local jobs, copies = {}, {}
local system, copy = vim.system, vim.uv.fs_copyfile
vim.system = function(command, options, callback)
  table.insert(jobs, { command = command, options = options, finish = callback })
  return {}
end
vim.uv.fs_copyfile = function(from, to) table.insert(copies, { from, to }); return true end
local build = require("draft.build")
build.build(false, root .. "/draft/main.tex")
eq(#jobs, 1) -- Returns before completion.
eq(jobs[1].options.cwd, root .. "/draft")
build.build(false, root .. "/draft/main.tex")
build.build(true, root .. "/draft/main.tex") -- A save cannot silence the queued manual build.
jobs[1].finish({ code = 0 })
assert(vim.wait(1000, function() return #jobs == 2 end))
eq(copies[1], { root .. "/draft/.build/main.pdf", root .. "/draft/main.pdf" })
jobs[2].finish({ code = 0 })
assert(vim.wait(1000, function() return #copies == 2 end))
eq(notices[#notices], "Draft: PDF generated")
local count = #notices
build.build(true, root .. "/draft/main.tex")
jobs[3].finish({ code = 0 })
assert(vim.wait(1000, function() return #copies == 3 end))
eq(#notices, count)
build.build(false, root .. "/draft/main.tex")
jobs[4].finish({ code = 1, stdout = "main.tex:8: Undefined control sequence.", stderr = "latexmk failed" })
assert(vim.wait(1000, function() return #notices > count end))
assert(notices[#notices]:match("^Draft: build failed\nmain.tex:8:"))
assert(notices[#notices]:find("main.log", 1, true))
vim.system = function() error("spawn failed") end
build.build(false, root .. "/draft/main.tex")
assert(notices[#notices]:match("^Draft: build failed"))
vim.system, vim.uv.fs_copyfile = system, copy
-- A toggle during asynchronous codesigning cancels startup instead of launching
-- a second helper. Both manuscript and plaintex fragments enter this same path.
local preview = require("draft.preview")
local startup = {}
local serverstart = vim.fn.serverstart
vim.fn.serverstart = function() return "/tmp/draft-test.socket" end
vim.system = function(command, options, callback)
  table.insert(startup, { command = command, finish = callback })
  return { pid = 999999 }
end
vim.api.nvim_set_current_buf(vim.api.nvim_create_buf(true, false))
vim.api.nvim_buf_set_name(0, fragment .. "/scratch.tex")
vim.bo.filetype = "plaintex"
vim.api.nvim_buf_set_lines(0, 0, -1, false, { "A preamble-free note." })
preview.toggle()
eq(startup[1].command[1], "swiftc")
startup[1].finish({ code = 0 })
assert(vim.wait(1000, function() return #startup == 2 end))
eq(startup[2].command[1], "codesign")
preview.toggle()
startup[2].finish({ code = 0 })
vim.wait(20)
eq(#startup, 2)
eq(preview.active(), false)
eq(vim.fn.maparg("<C-w>l", "n"), "")
vim.api.nvim_buf_set_name(0, root .. "/draft/main.tex")
preview.toggle()
eq(startup[3].command[1], "swiftc")
preview.toggle()
startup[3].finish({ code = 0 })
vim.wait(20)
eq(#startup, 3)
local kill = vim.uv.kill
vim.uv.kill = function(pid, signal) if pid == 999999 then return true end; return kill(pid, signal) end
preview.toggle()
startup[4].finish({ code = 0 })
assert(vim.wait(1000, function() return #startup == 5 end))
startup[5].finish({ code = 0 })
assert(vim.wait(1000, function() return #startup == 6 end))
local helper = startup[6]
vim.fn.writefile({ vim.json.encode({ pid = 999999, terminalPID = 100, status = "visible" }) }, helper.command[4])
assert(vim.wait(1000, function() return notices[#notices] == "draft.nvim: preview opened" end))
assert(preview.paired())
for _, visible in ipairs({ false, true, false, true }) do
  preview.toggle()
  local command = vim.json.decode(table.concat(vim.fn.readfile(helper.command[8])))
  eq(command.visible, visible)
  eq(preview.active(), visible)
  eq(#startup, 6) -- Reuses the warm helper.
end
assert(preview.send("sync-source"))
eq(vim.json.decode(table.concat(vim.fn.readfile(helper.command[8]))).visible, true)
preview.stop()
helper.finish({ code = 0 })
vim.wait(20)
vim.uv.kill = kill
vim.system = system
vim.fn.serverstart = serverstart
vim.fn.delete(root, "rf")
vim.fn.delete(fragment, "rf")
print("Draft: commands, project, UTF-8/range sync, asynchronous builds and preview startup cancellation passed")
