local M = {}

function M.draft_dir(path)
  path = path or vim.api.nvim_buf_get_name(0)
  local directory = path ~= "" and vim.fs.dirname(vim.fs.normalize(path)) or nil
  while directory do
    local candidate = vim.fs.basename(directory) == "draft" and directory or vim.fs.joinpath(directory, "draft")
    local main = vim.fs.joinpath(candidate, "main.tex")
    if vim.fn.filereadable(main) == 1 then
      local source = table.concat(vim.fn.readfile(main), "\n")
      if source:match("\\documentclass[%s%[{]") and source:match("\\begin%s*{document}") then
        return candidate
      end
    end
    local parent = vim.fs.dirname(directory)
    if parent == directory then break end
    directory = parent
  end
  vim.notify("Draft: :Db requires a manuscript at draft/main.tex", vim.log.levels.ERROR)
end

return M
