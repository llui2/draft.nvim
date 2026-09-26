local M = { buffer = nil }

function M.source_position()
  local buffer = M.buffer
  if not buffer or not vim.api.nvim_buf_is_valid(buffer) then
    return vim.json.encode({ start = 1, finish = 1 })
  end
  local window = vim.fn.bufwinid(buffer)
  local cursor = window ~= -1 and vim.api.nvim_win_get_cursor(window) or vim.api.nvim_buf_get_mark(buffer, '"')
  local start = math.max(1, cursor[1])
  local finish = start
  if window == vim.api.nvim_get_current_win() and vim.fn.mode():match("^[vV\22]") then
    local first = math.max(1, vim.fn.line("v"))
    local last = math.max(1, vim.fn.line("."))
    start, finish = math.min(first, last), math.max(first, last)
  end
  return vim.json.encode({ start = start, finish = finish })
end

function M.set_buffer(buffer)
  M.buffer = buffer
end

function M.jump_to_source(line)
  local buffer = M.buffer
  line = tonumber(line)
  if not buffer or not line or not vim.api.nvim_buf_is_valid(buffer) then return false end
  local window = vim.fn.bufwinid(buffer)
  if window == -1 then
    vim.api.nvim_set_current_buf(buffer)
    window = vim.api.nvim_get_current_win()
  else
    vim.api.nvim_set_current_win(window)
  end
  local count = vim.api.nvim_buf_line_count(buffer)
  vim.api.nvim_win_set_cursor(window, { math.max(1, math.min(line, count)), 0 })
  vim.cmd("normal! zz")
  return true
end

return M
