local M = {}

function M.enable(buffer)
  vim.bo[buffer].textwidth = 0
  for _, window in ipairs(vim.fn.win_findbuf(buffer)) do
    vim.wo[window].wrap = true
    vim.wo[window].linebreak = true
    vim.wo[window].breakindent = true
  end
  for _, key in ipairs({ "j", "k" }) do
    if not vim.fn.maparg(key, "n", false, true).rhs and not vim.fn.maparg(key, "n", false, true).callback then
      vim.keymap.set("n", key, function()
        return vim.v.count == 0 and "g" .. key or key
      end, { buffer = buffer, expr = true, desc = "Move by visual line without a count" })
    end
  end
end

return M
