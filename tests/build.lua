-- Real latexmk success/failure, publication and asynchronous callback checks.
vim.opt.runtimepath:prepend(vim.fn.getcwd())
vim.o.swapfile = false
local notices = {}
vim.notify = function(message) notices[#notices + 1] = message end
local root = vim.fn.tempname()
vim.fn.mkdir(root .. "/draft", "p")
local main = root .. "/draft/main.tex"
local function manuscript(body)
  vim.fn.writefile({ "\\documentclass{article}", "\\begin{document}", body, "\\end{document}" }, main)
end
local build = require("draft.build")
manuscript("Hello Draft.")
local responsive = false
build.build(false, main)
vim.schedule(function() responsive = true end)
assert(vim.wait(1000, function() return responsive end))
assert(vim.wait(15000, function() return #notices > 0 end))
assert(notices[#notices] == "Draft: PDF generated", vim.inspect(notices))
local pdf = root .. "/draft/main.pdf"
assert(vim.fn.filereadable(pdf) == 1)
local digest = vim.fn.sha256(table.concat(vim.fn.readfile(pdf, "b")))
notices = {}
manuscript("\\undefinedDraftCommand")
build.build(false, main)
assert(vim.wait(15000, function() return #notices > 0 end))
assert(notices[#notices]:match("^Draft: build failed"), vim.inspect(notices))
assert(notices[#notices]:find("main.log", 1, true))
assert(vim.fn.sha256(table.concat(vim.fn.readfile(pdf, "b"))) == digest, "failure replaced valid PDF")
local standalone = vim.fn.tempname() .. ".tex"
notices = {}
build.build(false, standalone)
assert(notices[#notices]:match("requires a manuscript"))
vim.fn.delete(root, "rf")
print("Draft: real latexmk success/failure, unchanged PDF on failure, asynchronous event loop and standalone rejection passed")
