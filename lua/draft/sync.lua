local M = { buffer = nil }
local namespace = vim.api.nvim_create_namespace("draft.sync")
local generation = 0
local pending_visual
local recent_visual

vim.api.nvim_create_autocmd("ModeChanged", {
  callback = function(event)
    if not event.match:match("^[vV\22]:") or vim.api.nvim_get_current_buf() ~= M.buffer then return end
    local first, last = vim.fn.getpos("'<"), vim.fn.getpos("'>")
    if first[2] == 0 or last[2] == 0 then return end
    recent_visual = {
      buffer = M.buffer,
      tick = vim.api.nvim_buf_get_changedtick(M.buffer),
      cursor = vim.api.nvim_win_get_cursor(0),
      range = { first[2], first[3] - 1, last[2], last[3] - 1, event.match:sub(1, 1) },
    }
  end,
})

vim.api.nvim_set_hl(0, "DraftSyncTarget", { default = true, bg = "#dce8f2", underline = true })

local function lines_and_starts(buffer)
  local lines = vim.api.nvim_buf_get_lines(buffer, 0, -1, false)
  local starts, offset = {}, 0
  for row, line in ipairs(lines) do
    starts[row] = offset
    offset = offset + #line + (row < #lines and 1 or 0)
  end
  return lines, starts, offset
end

local function absolute(starts, row, col)
	return (starts[row] or 0) + col
end

local function position(starts, offset)
  local row = 1
  for i = 1, #starts do
    if starts[i] > offset then break end
    row = i
  end
  return row, math.max(0, offset - starts[row])
end

local function highlight(buffer, start_offset, end_offset)
  if not vim.api.nvim_buf_is_valid(buffer) then return end
  generation = generation + 1
  local current = generation
  vim.api.nvim_buf_clear_namespace(buffer, namespace, 0, -1)
  local lines, starts = lines_and_starts(buffer)
  local sr, sc = position(starts, start_offset)
  local er, ec = position(starts, end_offset)
  if sr > #lines then return end
  vim.api.nvim_buf_set_extmark(buffer, namespace, sr - 1, sc, {
    end_row = er - 1, end_col = ec, hl_group = "DraftSyncTarget", hl_eol = sr == er and sc == ec,
    priority = 120,
  })
  vim.defer_fn(function()
    if current == generation and vim.api.nvim_buf_is_valid(buffer) then
      vim.api.nvim_buf_clear_namespace(buffer, namespace, 0, -1)
    end
  end, 1800)
end

function M.capture_visual()
  local mode = vim.fn.mode()
  local a, b
  if mode:match("^[vV\22]") then
    a = vim.fn.getpos("v")
    local cursor = vim.api.nvim_win_get_cursor(0)
    b = { 0, cursor[1], cursor[2] + 1 }
  else
    a, b = vim.fn.getpos("'<"), vim.fn.getpos("'>")
    mode = vim.fn.visualmode()
  end
  pending_visual = { a[2], a[3] - 1, b[2], b[3] - 1, mode }
end

function M.source_position_for_sync()
  if vim.fn.mode():match("^[vV\22]") and not pending_visual then
    M.capture_visual()
  elseif not pending_visual and recent_visual then
    local visual = recent_visual
    recent_visual = nil
    local buffer = M.buffer
    local cursor = buffer and vim.fn.bufwinid(buffer) == vim.api.nvim_get_current_win() and vim.api.nvim_win_get_cursor(0)
    if cursor and visual.buffer == buffer and visual.tick == vim.api.nvim_buf_get_changedtick(buffer)
      and cursor[1] == visual.cursor[1] and cursor[2] == visual.cursor[2] then
      pending_visual = visual.range
    end
  end
  return M.source_position()
end

function M.source_position()
  local buffer = M.buffer
  if not buffer or not vim.api.nvim_buf_is_valid(buffer) then
    return vim.json.encode({ start = 0, finish = 0, mode = "cursor" })
  end
  local lines, starts = lines_and_starts(buffer)
  local window = vim.fn.bufwinid(buffer)
  local cursor = window ~= -1 and vim.api.nvim_win_get_cursor(window) or vim.api.nvim_buf_get_mark(buffer, '"')
  local row, col = math.max(1, cursor[1]), math.max(0, cursor[2])
  local mode = "cursor"
  local first, last
  if pending_visual or (window ~= -1 and window == vim.api.nvim_get_current_win() and vim.fn.mode():match("^[vV\22]")) then
    local visual = pending_visual
    pending_visual = nil
    recent_visual = nil
    local visual_mode = visual and visual[5] or vim.fn.mode()
    mode = visual_mode == "V" and "line" or (visual_mode:byte() == 22 and "block" or "char")
    local anchor = visual and { 0, visual[1], visual[2] + 1 } or vim.fn.getpos("v")
    local arow, acol = anchor[2], math.max(0, anchor[3] - 1)
    local crow, ccol = visual and visual[3] or row, visual and visual[4] or col
    if mode == "block" then
      arow, crow, acol, ccol = math.min(arow, crow), math.max(arow, crow), math.min(acol, ccol), math.max(acol, ccol)
    elseif arow > crow or (arow == crow and acol > ccol) then
      arow, crow, acol, ccol = crow, arow, ccol, acol
    end
    first = absolute(starts, arow, mode == "line" and 0 or acol)
    local last_line = lines[crow] or ""
    local finish_col = mode == "line" and #last_line or math.min(#last_line, ccol + 1)
    if mode == "char" and finish_col > 0 then
      while finish_col < #last_line and last_line:byte(finish_col + 1) >= 128 and last_line:byte(finish_col + 1) < 192 do finish_col = finish_col + 1 end
    end
    last = absolute(starts, crow, finish_col)
  else
    first = absolute(starts, row, col)
    local byte = (lines[row] or ""):byte(col + 1) or 0
    local width = byte >= 240 and 4 or byte >= 224 and 3 or byte >= 192 and 2 or byte > 0 and 1 or 0
    last = first + width
  end
  highlight(buffer, first, math.max(first, last))
  return vim.json.encode({ start = first, finish = math.max(first, last), mode = mode })
end

function M.set_buffer(buffer)
  M.buffer = buffer
  pending_visual = nil
  recent_visual = nil
end

function M.jump_to_source(start_offset, end_offset, mode)
  local buffer = M.buffer
  start_offset, end_offset = tonumber(start_offset), tonumber(end_offset)
  if not buffer or not start_offset or not end_offset or not vim.api.nvim_buf_is_valid(buffer) then return false end
  local lines, starts, length = lines_and_starts(buffer)
  start_offset, end_offset = math.max(0, math.min(start_offset, length)), math.max(0, math.min(end_offset, length))
  if end_offset < start_offset then start_offset, end_offset = end_offset, start_offset end
  local window = vim.fn.bufwinid(buffer)
  if window == -1 then vim.api.nvim_set_current_buf(buffer); window = vim.api.nvim_get_current_win()
  else vim.api.nvim_set_current_win(window) end
  if vim.fn.mode():match("^[vV\22]") then
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)
  end
  local sr, sc = position(starts, start_offset)
  local er, ec = position(starts, end_offset)
  vim.api.nvim_win_set_cursor(window, { sr, sc })
  if mode == "line" then
    local last_row = end_offset > start_offset and position(starts, end_offset - 1) or er
    vim.cmd("normal! V")
    vim.api.nvim_win_set_cursor(window, { last_row, 0 })
  elseif mode ~= "cursor" and end_offset > start_offset then
    vim.cmd("normal! v")
    local end_line = lines[er] or ""
    local end_col = math.max(0, math.min(#end_line, ec - 1))
    while end_col > 0 and end_col < #end_line and end_line:byte(end_col + 1) >= 128 and end_line:byte(end_col + 1) < 192 do end_col = end_col - 1 end
    vim.api.nvim_win_set_cursor(window, { er, end_col })
  end
  vim.cmd("normal! zz")
  highlight(buffer, start_offset, end_offset)
  return true
end

return M
