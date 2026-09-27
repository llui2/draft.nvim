local M = {}

function M.draft_dir(path)
  path = path or vim.api.nvim_buf_get_name(0)
  if vim.fs.basename(path) == "main.tex" and vim.fs.basename(vim.fs.dirname(path)) == "draft" then
    return vim.fs.dirname(path)
  end
  vim.notify("Draft: :Db builds only draft/main.tex", vim.log.levels.ERROR)
end

return M
