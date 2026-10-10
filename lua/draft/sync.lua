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

function M.set_cursor_offset(buffer, offset)
  if not buffer or not vim.api.nvim_buf_is_valid(buffer) or type(offset) ~= "number" or offset < 0 then return false end
  local lines, starts, length = lines_and_starts(buffer)
  local row, col = position(starts, math.min(offset, length))
  local window = vim.fn.bufwinid(buffer)
  if window == -1 then
    vim.api.nvim_set_current_buf(buffer)
    window = vim.api.nvim_get_current_win()
  else
    vim.api.nvim_set_current_win(window)
  end
  vim.api.nvim_win_set_cursor(window, { row, col })
  return true
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

local function trim_bounds(text, first, last)
  while first <= last and text:sub(first, first):match("%s") do first = first + 1 end
  while last >= first and text:sub(last, last):match("%s") do last = last - 1 end
  return first, last
end

local function skip_space_and_comments(source, index)
  while index <= #source do
    local char = source:sub(index, index)
    if char:match("%s") then
      index = index + 1
    elseif char == "%" then
      local newline = source:find("\n", index, true)
      if not newline then return #source + 1 end
      index = newline + 1
    else
      break
    end
  end
  return index
end

local function node_option_range(source, index)
  local depth, braces, escaped = 1, 0, false
  local cursor = index + 1
  while cursor <= #source do
    local char = source:sub(cursor, cursor)
    if escaped then
      escaped = false
    elseif char == "\\" then
      escaped = true
    elseif char == "%" then
      local newline = source:find("\n", cursor, true)
      if not newline then return nil end
      cursor = newline
    elseif char == "{" then
      braces = braces + 1
    elseif char == "}" and braces > 0 then
      braces = braces - 1
    elseif braces == 0 and char == "[" then
      depth = depth + 1
    elseif braces == 0 and char == "]" then
      depth = depth - 1
      if depth == 0 then return index, cursor end
    end
    cursor = cursor + 1
  end
  return nil
end

local function option_segments(source, first, last)
  local segments, segment_start = {}, first
  local braces, brackets, escaped = 0, 0, false
  local cursor = first
  while cursor <= last do
    local char = source:sub(cursor, cursor)
    if escaped then
      escaped = false
    elseif char == "\\" then
      escaped = true
    elseif char == "%" then
      local newline = source:find("\n", cursor, true)
      if not newline or newline > last then break end
      cursor = newline
    elseif char == "{" then
      braces = braces + 1
    elseif char == "}" and braces > 0 then
      braces = braces - 1
    elseif braces == 0 and char == "[" then
      brackets = brackets + 1
    elseif braces == 0 and char == "]" and brackets > 0 then
      brackets = brackets - 1
    elseif braces == 0 and brackets == 0 and char == "," then
      table.insert(segments, { segment_start, cursor - 1 })
      segment_start = cursor + 1
    end
    cursor = cursor + 1
  end
  table.insert(segments, { segment_start, last })
  return segments
end

local function parse_option(source, first, last)
  local braces, brackets, escaped = 0, 0, false
  for cursor = first, last do
    local char = source:sub(cursor, cursor)
    if escaped then
      escaped = false
    elseif char == "\\" then
      escaped = true
    elseif char == "{" then
      braces = braces + 1
    elseif char == "}" and braces > 0 then
      braces = braces - 1
    elseif braces == 0 and char == "[" then
      brackets = brackets + 1
    elseif braces == 0 and char == "]" and brackets > 0 then
      brackets = brackets - 1
    elseif char == "=" and braces == 0 and brackets == 0 then
      local key_first, key_last = trim_bounds(source, first, cursor - 1)
      local value_first, value_last = trim_bounds(source, cursor + 1, last)
      return source:sub(key_first, key_last), value_first, value_last
    end
  end
  local key_first, key_last = trim_bounds(source, first, last)
  return source:sub(key_first, key_last), nil, nil
end

local function number_text(value)
  if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge or math.abs(value) > 1000000 then
    return nil
  end
  if value == 0 then value = 0 end
  local result = string.format("%.9f", value):gsub("0+$", ""):gsub("%.$", "")
  return result
end

local function find_named_nodes(source, name)
  local found, cursor = {}, 1
  while cursor <= #source do
    local char = source:sub(cursor, cursor)
    if char == "%" then
      local newline = source:find("\n", cursor, true)
      if not newline then break end
      cursor = newline + 1
    elseif source:sub(cursor, cursor + 4) == "\\node"
      and not source:sub(cursor + 5, cursor + 5):match("[%a@]") then
      local bracket = skip_space_and_comments(source, cursor + 5)
      if source:sub(bracket, bracket) == "[" then
        local option_first, option_last = node_option_range(source, bracket)
        if option_first then
          local fields = {}
          for _, segment in ipairs(option_segments(source, option_first + 1, option_last - 1)) do
            local key, value_first, value_last = parse_option(source, segment[1], segment[2])
            if key == "name" and value_first then
              local candidate = source:sub(value_first, value_last)
              if candidate:match("^[%a_][%w_%-]*$") and candidate == name then
                table.insert(fields, { first = option_first, last = option_last })
                break
              end
            end
          end
          for _, field in ipairs(fields) do table.insert(found, field) end
          cursor = option_last + 1
        else
          cursor = bracket + 1
        end
      else
        cursor = cursor + 5
      end
    else
      cursor = cursor + 1
    end
  end
  return found
end

local function find_node_shifts(source, first, last)
  local shifts = { name = 0, xshift = 0, yshift = 0 }
  for _, segment in ipairs(option_segments(source, first + 1, last - 1)) do
    local key, value_first, value_last = parse_option(source, segment[1], segment[2])
    if shifts[key] ~= nil then
      shifts[key] = shifts[key] + 1
      if not value_first then return nil, "node option " .. key .. " must have a value" end
      if key ~= "name" then
        local value = source:sub(value_first, value_last)
        if not (value:match("^[+-]?%d+%.?%d*pt$") or value:match("^[+-]?%.%d+pt$")) then
          return nil, "node option " .. key .. " must be a decimal TeX point value"
        end
        shifts[key .. "_range"] = { value_first, value_last }
      end
    end
  end
  if shifts.name ~= 1 then return nil, "node must have exactly one name option" end
  if shifts.xshift ~= 1 or shifts.yshift ~= 1 then return nil, "node must have exactly one xshift and yshift option" end
  return shifts
end

-- The preview can pass arguments through luaeval's _A list, then JSON-encode
-- the returned table; identifiers never need to be interpolated as Lua code.
-- Returns the source version that a preview should pass back with an edit.
function M.node_edit_state()
  local buffer = M.buffer
  if not buffer or not vim.api.nvim_buf_is_valid(buffer) then return nil end
  return { changedtick = vim.api.nvim_buf_get_changedtick(buffer) }
end

-- Only the small, explicit syntax `\\node[name=id, xshift=...pt, yshift=...pt]`
-- is editable. Replacing the option list in one API call keeps the edit atomic
-- for Neovim undo while preserving every byte outside the two numeric values.
function M.update_node_shift(name, dx_pt, dy_pt, expected_tick)
  local buffer = M.buffer
  if not buffer or not vim.api.nvim_buf_is_valid(buffer) then return { ok = false, error = "no source buffer" } end
  if not vim.api.nvim_buf_is_loaded(buffer) or not vim.bo[buffer].modifiable then
    return { ok = false, error = "source buffer is not modifiable" }
  end
  if type(name) ~= "string" or not name:match("^[%a_][%w_%-]*$") then
    return { ok = false, error = "invalid node identifier" }
  end
  if type(expected_tick) ~= "number" or expected_tick ~= vim.api.nvim_buf_get_changedtick(buffer) then
    return { ok = false, error = "stale source edit" }
  end
  local dx, dy = number_text(dx_pt), number_text(dy_pt)
  if not dx or not dy then return { ok = false, error = "displacements must be finite numbers within +/-1000000 pt" } end

  local lines, starts = lines_and_starts(buffer)
  local source = table.concat(lines, "\n")
  local nodes = find_named_nodes(source, name)
  if #nodes == 0 then return { ok = false, error = "named node not found" } end
  if #nodes > 1 then return { ok = false, error = "duplicate node name" } end
  local node = nodes[1]
  local shifts, problem = find_node_shifts(source, node.first, node.last)
  if not shifts then return { ok = false, error = problem } end

  local edits = {
    { shifts.xshift_range[1], shifts.xshift_range[2], dx .. "pt" },
    { shifts.yshift_range[1], shifts.yshift_range[2], dy .. "pt" },
  }
  local option_text = source:sub(node.first, node.last)
  for i = #edits, 1, -1 do
    local edit = edits[i]
    local a, b = edit[1] - node.first + 1, edit[2] - node.first + 1
    option_text = option_text:sub(1, a - 1) .. edit[3] .. option_text:sub(b + 1)
  end
  local start_row, start_col = position(starts, node.first - 1)
  local end_row, end_col = position(starts, node.last)
  local replacement = vim.split(option_text, "\n", { plain = true })
  vim.api.nvim_buf_set_text(buffer, start_row - 1, start_col, end_row - 1, end_col, replacement)
  return { ok = true, changedtick = vim.api.nvim_buf_get_changedtick(buffer) }
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
    er, ec = position(starts, end_offset - 1)
    local end_line = lines[er] or ""
    local end_col = math.max(0, math.min(#end_line, ec))
    while end_col > 0 and end_col < #end_line and end_line:byte(end_col + 1) >= 128 and end_line:byte(end_col + 1) < 192 do end_col = end_col - 1 end
    vim.api.nvim_win_set_cursor(window, { er, end_col })
  end
  vim.cmd("normal! zz")
  highlight(buffer, start_offset, end_offset)
  return true
end

return M
