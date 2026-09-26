if vim.g.loaded_draft_nvim then
  return
end
vim.g.loaded_draft_nvim = true

local commands = {
  { names = { "DraftPreview", "Dp", "Draft" }, action = "preview", desc = "Toggle the live draft preview" },
  { names = { "DraftBuild", "Db" }, action = "build", desc = "Build the draft PDF" },
  { names = { "DraftNote" }, action = "note", desc = "Toggle a lightweight LaTeX note preview" },
  { names = { "Ds", "DraftSync" }, action = "sync", desc = "Sync the preview to the source position" },
  { names = { "DraftFocus" }, action = "focus", desc = "Focus the Draft preview" },
  { names = { "DraftFocusSource" }, action = "focus_source", desc = "Focus the paired source terminal" },
}

for _, command in ipairs(commands) do
  local action = command.action
  for _, name in ipairs(command.names) do
    vim.api.nvim_create_user_command(name, function(opts)
      require("draft")[action](action == "sync" and opts.range > 0)
    end, { desc = command.desc, range = action == "sync" })
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

vim.api.nvim_create_autocmd("VimLeavePre", {
  callback = function()
    require("draft").stop_preview()
  end,
})

for plug, action in pairs({ ["draft-sync"] = "sync", ["draft-focus-preview"] = "focus", ["draft-focus-source"] = "focus_source" }) do
  vim.keymap.set("n", "<Plug>(" .. plug .. ")", function() require("draft")[action]() end)
end

vim.keymap.set("x", "<Plug>(draft-sync)", function() require("draft").sync(true) end)
