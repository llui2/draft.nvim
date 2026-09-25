if vim.g.loaded_draft_nvim then
  return
end
vim.g.loaded_draft_nvim = true

vim.api.nvim_create_user_command("Draft", function()
  require("draft").preview()
end, { desc = "Open the draft live preview" })

vim.api.nvim_create_user_command("DraftPreview", function()
  require("draft").preview()
end, { desc = "Open the draft live preview" })

vim.api.nvim_create_user_command("DraftBuild", function()
  require("draft").build()
end, { desc = "Build the draft PDF in the background" })
