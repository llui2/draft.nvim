if vim.g.loaded_draft_nvim then
  return
end
vim.g.loaded_draft_nvim = true

local commands = {
  { names = { "DraftPreview", "Dp", "Draft" }, action = "preview", desc = "Toggle the live draft preview" },
  { names = { "DraftBuild", "Db" }, action = "build", desc = "Build the draft PDF" },
}

for _, command in ipairs(commands) do
  local action = command.action
  for _, name in ipairs(command.names) do
    vim.api.nvim_create_user_command(name, function()
      require("draft")[action]()
    end, { desc = command.desc })
  end
end

vim.api.nvim_create_autocmd("BufWritePost", {
  pattern = "main.tex",
  callback = function(event)
    local path = vim.api.nvim_buf_get_name(event.buf)
    if vim.fs.basename(vim.fs.dirname(path)) == "draft" then
      require("draft").build()
    end
  end,
})
