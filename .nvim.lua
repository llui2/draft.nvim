-- Load draft.nvim directly from this repository without a plugin manager.
local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)
vim.cmd("runtime plugin/draft.lua")
