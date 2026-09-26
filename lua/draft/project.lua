local M = {}

function M.draft_dir()
  local buffer = vim.api.nvim_buf_get_name(0)
  local start = buffer ~= "" and vim.fs.dirname(buffer) or vim.fn.getcwd()

  while start do
    local draft_dir = vim.fs.joinpath(start, "draft")
    if vim.fn.filereadable(vim.fs.joinpath(draft_dir, "main.tex")) == 1 then
      return draft_dir
    end

    local parent = vim.fs.dirname(start)
    if parent == start then
      break
    end
    start = parent
  end

  vim.notify("draft.nvim: could not find draft/main.tex", vim.log.levels.ERROR)
end

return M
