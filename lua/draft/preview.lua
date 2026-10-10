local M = {}
local preview = { generation = 0, closing_pid = nil, reopen_after_close = false }
local close_preview, open_preview_window

local function publish_command(action, payload)
  local temporary = preview.command .. ".tmp"
  local command = { action = action, visible = not preview.hidden, nonce = vim.uv.hrtime() }
  if payload then
    command.svg = payload.svg
    command.error = payload.error
    command.changedtick = payload.changedtick
  end
  if vim.fn.writefile({ vim.json.encode(command) }, temporary) ~= 0 then return false end
  local renamed = vim.uv.fs_rename(temporary, preview.command)
  if not renamed then pcall(vim.uv.fs_unlink, temporary) end
  return renamed ~= nil
end

local function unmapped(mode, lhs, buffer)
  local local_map = vim.api.nvim_buf_call(buffer, function() return vim.fn.maparg(lhs, mode, false, true) end)
  return type(local_map) ~= "table" or vim.tbl_isempty(local_map)
end

local function install_keys(buffer)
  preview.keys = {}
  for _, mode in ipairs({ "n", "x" }) do
    if unmapped(mode, "<C-g>", buffer) then
      vim.keymap.set(mode, "<C-g>", "<Plug>(draft-sync)", { buffer = buffer, remap = true, desc = "Sync Draft to source" })
      table.insert(preview.keys, { mode, "<C-g>" })
    end
  end
  if unmapped("n", "<C-w>l", buffer) then
    vim.keymap.set("n", "<C-w>l", function()
      if M.paired() then M.send("focus-preview") else vim.cmd("wincmd l") end
    end, { buffer = buffer, desc = "Focus paired Draft or right Neovim window" })
    table.insert(preview.keys, { "n", "<C-w>l" })
  end
end

local function remove_keys()
  for _, key in ipairs(preview.keys or {}) do
    if preview.buffer and vim.api.nvim_buf_is_valid(preview.buffer) then
      local map = vim.api.nvim_buf_call(preview.buffer, function() return vim.fn.maparg(key[2], key[1], false, true) end)
      local ours = key[2] == "<C-g>" and map.rhs == "<Plug>(draft-sync)"
        or key[2] == "<C-w>l" and map.desc == "Focus paired Draft or right Neovim window"
      if ours then pcall(vim.keymap.del, key[1], key[2], { buffer = preview.buffer }) end
    end
  end
  preview.keys = nil
end

local function mtime(path)
  local stat = vim.uv.fs_stat(path)
  return stat and stat.mtime.sec * 1000000000 + stat.mtime.nsec or 0
end

local function helper_alive(pid)
  if not pid then return false end
  local ok, result = pcall(vim.uv.kill, pid, 0)
  return ok and result ~= nil
end

local function read_state(path)
  if vim.fn.filereadable(path) ~= 1 then
    return nil
  end
  local ok, state = pcall(vim.json.decode, table.concat(vim.fn.readfile(path), "\n"))
  return ok and type(state) == "table" and state or nil
end

local function cleanup_watch()
  if preview.timer then
    preview.timer:stop()
    preview.timer:close()
    preview.timer = nil
  end
  if preview.group then
    pcall(vim.api.nvim_del_augroup_by_id, preview.group)
    preview.group = nil
  end
end

local function cleanup_document_watch()
  if preview.buf_enter then
    pcall(vim.api.nvim_del_autocmd, preview.buf_enter)
    preview.buf_enter = nil
  end
end

local function cleanup_startup_watch()
  for _, key in ipairs({ "startup_event", "startup_timeout" }) do
    local handle = preview[key]
    if handle then
      if key == "startup_event" then pcall(handle.stop, handle) end
      pcall(handle.close, handle)
      preview[key] = nil
    end
  end
end

local function cleanup_state(path, source, pid)
  local state = read_state(path)
  if not pid or (state and tonumber(state.pid) == pid) then
    pcall(vim.uv.fs_unlink, path)
    pcall(vim.uv.fs_unlink, source)
    pcall(vim.uv.fs_unlink, source .. ".tmp")
    if preview.command then
      pcall(vim.uv.fs_unlink, preview.command)
      pcall(vim.uv.fs_unlink, preview.command .. ".tmp")
    end
  end
end

local function write_source(text)
  local temporary = preview.source .. ".tmp"
  local result = vim.fn.writefile({ vim.json.encode({ text = text, path = vim.api.nvim_buf_get_name(preview.buffer) }) }, temporary)
  if result ~= 0 then
    vim.notify("draft.nvim: could not write preview source", vim.log.levels.ERROR)
    return false
  end
  local renamed, err = vim.uv.fs_rename(temporary, preview.source)
  if not renamed then
    pcall(vim.uv.fs_unlink, temporary)
    vim.notify("draft.nvim: could not publish preview source: " .. err, vim.log.levels.ERROR)
    return false
  end
  return true
end

-- Only the newest requested figure is built after an in-flight compilation.
local function update_figure(source)
  local tikz = require("draft.tikz")
  preview.figure_generation = (preview.figure_generation or 0) + 1
  local generation = preview.figure_generation
  if not tikz.is_standalone(source) then
    preview.queued_figure = nil
    publish_command("reset-figure")
    return
  end
  local state = require("draft.sync").node_edit_state()
  preview.queued_figure = {
    source = source, generation = generation,
    changedtick = state and state.changedtick,
  }
  publish_command("figure") -- Keep the previous valid SVG while compiling.
  if preview.figure_busy then return end
  local pump
  pump = function()
    local request = preview.queued_figure
    if not request or not preview.command then return end
    preview.queued_figure = nil
    preview.figure_busy = true
    tikz.compile(request.source, function(svg, err)
      preview.figure_busy = false
      if request.generation == preview.figure_generation and preview.command then
        publish_command("figure", {
          svg = svg, error = err, changedtick = request.changedtick,
        })
      end
      if preview.queued_figure then pump() end
    end)
  end
  pump()
end

local function watch_preview(buffer)
  cleanup_watch()
  local function update()
    if vim.api.nvim_buf_is_valid(buffer) then
      local source = table.concat(vim.api.nvim_buf_get_lines(buffer, 0, -1, false), "\n")
      if write_source(source) then update_figure(source); return true end
      return false
    end
    return false
  end

  preview.group = vim.api.nvim_create_augroup("DraftPreview", { clear = true })
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = preview.group,
    buffer = buffer,
    callback = function()
      -- Invalidate in-flight output as soon as the buffer changes, before debounce.
      preview.figure_generation = (preview.figure_generation or 0) + 1
      if not preview.timer then
        preview.timer = vim.uv.new_timer()
      end
      preview.timer:stop()
      preview.timer:start(100, 0, vim.schedule_wrap(update))
    end,
  })
  return update()
end

local function finish_close(pid)
  if preview.closing_pid ~= pid then
    return
  end
  preview.closing_pid = nil
  if preview.reopen_after_close then
    preview.reopen_after_close = false
    vim.schedule(M.toggle)
  end
end

local function switch_buffer(buffer)
  if not buffer or not vim.api.nvim_buf_is_valid(buffer) or not vim.api.nvim_buf_is_loaded(buffer) then return false end
  local path = vim.api.nvim_buf_get_name(buffer)
  if not path:match("%.tex$") then return false end
  if preview.buffer == buffer then return true end
  cleanup_watch()
  remove_keys()
  if preview.command then publish_command("reset-figure") end
  preview.buffer = buffer
  require("draft.sync").set_buffer(buffer)
  install_keys(buffer)
  require("draft.prose").enable(buffer)
  watch_preview(buffer)
  return true
end

local function watch_active_document()
  if preview.buf_enter then pcall(vim.api.nvim_del_autocmd, preview.buf_enter) end
  preview.buf_enter = vim.api.nvim_create_autocmd("BufEnter", {
    callback = function(event)
      if preview.pid and helper_alive(preview.pid) then switch_buffer(event.buf) end
    end,
  })
end

function M.open_link(target, offset)
  if type(target) ~= "string" or target == "" or target:match("^[A-Za-z][A-Za-z0-9+.-]*:") then return false end
  local buffer = preview.buffer or vim.api.nvim_get_current_buf()
  if not buffer or not vim.api.nvim_buf_is_valid(buffer) then return false end
  local path, fragment = target:match("^([^#]*)#?(.*)$")
  if not path or path == "" then return false end
  if not path:match("%.tex$") then return false end
  local base = vim.fs.dirname(vim.api.nvim_buf_get_name(buffer))
  local resolved = vim.fs.normalize(path:sub(1, 1) == "/" and path or vim.fs.joinpath(base, path))
  if vim.fn.filereadable(resolved) ~= 1 then return false end
  if offset ~= nil then
    offset = tonumber(offset)
    if not offset or offset < 0 then return false end
    if not require("draft.sync").set_cursor_offset(buffer, offset) then return false end
  end
  -- Jump to a temporary local mark on this position; Neovim records the
  -- position we are leaving in its native jump list. Restore the user's mark.
  local win = vim.api.nvim_get_current_win()
  local cursor = vim.api.nvim_win_get_cursor(win)
  local mark = vim.api.nvim_buf_get_mark(buffer, "z")
  vim.api.nvim_buf_set_mark(buffer, "z", cursor[1], cursor[2], {})
  vim.cmd("normal! 'z")
  vim.api.nvim_win_set_cursor(win, cursor)
  if mark[1] == 0 then vim.api.nvim_buf_del_mark(buffer, "z")
  else vim.api.nvim_buf_set_mark(buffer, "z", mark[1], mark[2], {}) end
  local ok = pcall(vim.cmd.edit, { args = { resolved } })
  if not ok then return false end
  local target_buffer = vim.api.nvim_get_current_buf()
  if preview.pid and helper_alive(preview.pid) then return switch_buffer(target_buffer) end
  preview.buffer = target_buffer
  require("draft.sync").set_buffer(target_buffer)
  return true
end

local function wait_for_external_close(pid, deadline)
  vim.defer_fn(function()
    if preview.closing_pid ~= pid then
      return
    end
    if helper_alive(pid) then
      if vim.uv.hrtime() >= deadline then
        preview.closing_pid = nil
        preview.reopen_after_close = false
        vim.notify("draft.nvim: existing preview helper did not close", vim.log.levels.ERROR)
      else
        wait_for_external_close(pid, deadline)
      end
      return
    end
    finish_close(pid)
  end, 50)
end

function M.toggle()
  if preview.starting then
    close_preview()
    return
  end
  local source_name = vim.api.nvim_buf_get_name(0)
  if source_name == "" or not source_name:match("%.tex$") then
    vim.notify("Draft: open a .tex file first", vim.log.levels.ERROR)
    return
  end
  if preview.pid and helper_alive(preview.pid) then
    switch_buffer(vim.api.nvim_get_current_buf())
    if preview.hidden then
      preview.hidden = false
      install_keys(preview.buffer)
      write_source(table.concat(vim.api.nvim_buf_get_lines(preview.buffer, 0, -1, false), "\n"))
      if not publish_command("visibility") then
        preview.hidden = true
        remove_keys()
        vim.notify("Draft: could not reopen preview", vim.log.levels.ERROR)
      end
    else
      close_preview()
    end
    return
  end
  if preview.pid then
    preview.pid = nil
    preview.hidden = false
    cleanup_watch()
    remove_keys()
  end
  if preview.closing_pid then
    if helper_alive(preview.closing_pid) then
      preview.reopen_after_close = true
      return
    end
    preview.closing_pid = nil
    preview.reopen_after_close = false
  end

  local draft_dir = vim.fs.basename(source_name) == "main.tex" and vim.fs.basename(vim.fs.dirname(source_name)) == "draft"
    and vim.fs.dirname(source_name) or nil

  local runtime = vim.api.nvim_get_runtime_file("lua/draft/preview.html", false)[1]
  local window_script = vim.api.nvim_get_runtime_file("lua/draft/window.swift", false)[1]
  if not runtime or not window_script then
    vim.notify("draft.nvim: preview assets are missing", vim.log.levels.ERROR)
    return
  end

  local state_dir = draft_dir and vim.fs.joinpath(draft_dir, ".build")
    or vim.fs.joinpath(vim.fn.stdpath("cache"), "draft.nvim")
  vim.fn.mkdir(state_dir, "p")
  local session = tostring(vim.fn.getpid())
  preview.source = vim.fs.joinpath(state_dir, "preview-source-" .. session .. ".json")
  preview.state = vim.fs.joinpath(state_dir, "preview-state-" .. session .. ".json")
  preview.command = vim.fs.joinpath(state_dir, "preview-command-" .. session .. ".json")
  preview.server = vim.v.servername ~= "" and vim.v.servername or vim.fn.serverstart()
  require("draft.sync").set_buffer(vim.api.nvim_get_current_buf())

  local prior_state = read_state(preview.state)
  local prior_pid = prior_state and tonumber(prior_state.pid)
  if prior_pid and helper_alive(prior_pid) then
    preview.closing_pid = prior_pid
    preview.reopen_after_close = true
    pcall(vim.uv.kill, prior_pid, "sigterm")
    wait_for_external_close(prior_pid, vim.uv.hrtime() + 3000000000)
    return
  end
  cleanup_state(preview.state, preview.source)

  preview.hidden = false
  preview.html = runtime
  preview.buffer = vim.api.nvim_get_current_buf()
  watch_active_document()
  install_keys(preview.buffer)
  require("draft.prose").enable(preview.buffer)
  if not watch_preview(vim.api.nvim_get_current_buf()) then
    cleanup_watch()
    remove_keys()
    cleanup_state(preview.state, preview.source)
    return
  end
  local helper_dir = vim.fs.joinpath(vim.fn.stdpath("cache"), "draft.nvim")
  vim.fn.mkdir(helper_dir, "p")
  open_preview_window(vim.fs.joinpath(helper_dir, "draft-preview"), preview.html, preview.source, preview.state, preview.server, vim.v.progpath, window_script)
end

close_preview = function()
  if preview.starting then
    preview.generation = preview.generation + 1
    preview.figure_generation = (preview.figure_generation or 0) + 1
    preview.queued_figure = nil
    if preview.pid then pcall(vim.uv.kill, preview.pid, "sigterm") end
    preview.pid, preview.starting, preview.hidden = nil, false, false
    cleanup_startup_watch()
    cleanup_watch()
    cleanup_document_watch()
    remove_keys()
    cleanup_state(preview.state, preview.source)
    vim.notify("draft.nvim: preview closed")
    return
  end
  local pid = preview.pid
  if pid and helper_alive(pid) then
    preview.hidden = true
    if not publish_command("visibility") then
      preview.hidden = false
      vim.notify("Draft: could not hide preview", vim.log.levels.ERROR)
      return
    end
  elseif not pid then
    cleanup_state(preview.state, preview.source)
  end
  preview.starting = false
  cleanup_startup_watch()
  remove_keys()
  if not pid then cleanup_watch(); cleanup_document_watch() end
  vim.notify("draft.nvim: preview hidden")
end

open_preview_window = function(binary, html, source, state, server, nvim, window_script)
  local function open()
    local notified = false
    local opened = false
    local process
    local function fail(message)
      if notified then
        return
      end
      notified = true
      preview.starting = false
      cleanup_startup_watch()
      cleanup_watch()
      cleanup_document_watch()
      remove_keys()
      if process and helper_alive(process.pid) then
        preview.closing_pid = process.pid
        pcall(vim.uv.kill, process.pid, "sigterm")
      end
      vim.notify("draft.nvim: preview helper failed\n" .. message, vim.log.levels.ERROR)
    end

    process = vim.system({ binary, html, source, state, server, nvim, tostring(vim.fn.getpid()), preview.command }, { detach = true, text = true }, function(result)
      vim.schedule(function()
        local current = preview.pid == process.pid
        cleanup_state(state, source, process.pid)
        if current then
          preview.pid = nil
          preview.starting = false
          cleanup_watch()
          cleanup_document_watch()
          remove_keys()
        end
        local intentional = preview.closing_pid == process.pid
        if intentional then
          finish_close(process.pid)
        elseif not intentional and result.code ~= 0 then
          local detail = (result.stderr and result.stderr ~= "" and result.stderr)
            or (result.stdout and result.stdout ~= "" and result.stdout)
            or ("helper exited with status " .. tostring(result.code))
          if opened then
            vim.notify("draft.nvim: preview helper exited unexpectedly\n" .. detail, vim.log.levels.ERROR)
          elseif not notified then
            fail(detail)
          end
        end
      end)
    end)
    preview.pid = process.pid
    preview.starting = true
    local deadline = vim.uv.hrtime() + 5000000000
    local function check_startup()
      if preview.pid ~= process.pid or notified then
        return
      end
      local helper_state = read_state(state)
      if helper_state and tonumber(helper_state.pid) == process.pid then
        if helper_state.status == "visible" then
          cleanup_startup_watch()
          preview.starting = false
          notified = true
          opened = true
          if helper_state.warning then
            vim.notify("draft.nvim: preview opened; " .. helper_state.warning, vim.log.levels.WARN)
          else
            vim.notify("draft.nvim: preview opened")
          end
          return
        elseif helper_state.status == "failed" then
          cleanup_startup_watch()
          fail(helper_state.error or "the helper could not show its window")
          return
        end
      end
      if not helper_alive(process.pid) then
        cleanup_startup_watch()
        fail("helper process exited before the Draft window became visible")
        return
      end
      if vim.uv.hrtime() >= deadline then
        cleanup_startup_watch()
        preview.closing_pid = process.pid
        pcall(vim.uv.kill, process.pid, "sigterm")
        fail("timed out waiting for the Draft window to become visible")
        return
      end
    end
    preview.startup_event = vim.uv.new_fs_event()
    preview.startup_event:start(vim.fs.dirname(state), {}, vim.schedule_wrap(check_startup))
    preview.startup_timeout = vim.uv.new_timer()
    preview.startup_timeout:start(5000, 0, vim.schedule_wrap(function()
      check_startup()
      if preview.starting and preview.pid == process.pid then
        preview.closing_pid = process.pid
        pcall(vim.uv.kill, process.pid, "sigterm")
        fail("timed out waiting for the Draft window to become visible")
      end
    end))
    vim.schedule(check_startup)
  end

  if vim.fn.executable(binary) == 1 and mtime(binary) >= mtime(window_script) then
    open()
    return
  end

  preview.starting = true
  preview.generation = preview.generation + 1
  local generation = preview.generation
  vim.system({ "swiftc", "-Onone", window_script, "-o", binary }, { text = true }, function(result)
    vim.schedule(function()
      if generation ~= preview.generation then
        return
      end
      if result.code ~= 0 then
        preview.starting = false
        cleanup_watch()
        remove_keys()
        cleanup_state(state, source)
        vim.notify("draft.nvim: could not compile preview window\n" .. (result.stderr or result.stdout), vim.log.levels.ERROR)
        return
      end
      vim.system({
        "codesign", "--force", "--sign", "-", "--identifier", "com.llui2.draft.nvim.preview",
        "--options", "runtime", "--timestamp=none", binary,
      }, { text = true }, function(signature)
        vim.schedule(function()
          if generation ~= preview.generation then
            return
          end
          if signature.code ~= 0 then
            preview.starting = false
            cleanup_watch()
            remove_keys()
            cleanup_state(state, source)
            vim.notify("draft.nvim: could not sign preview helper\n" .. (signature.stderr or signature.stdout), vim.log.levels.ERROR)
            return
          end
          open()
        end)
      end)
    end)
  end)
end

function M.active()
  return preview.pid and not preview.hidden and helper_alive(preview.pid) or false
end

function M.paired()
  if not M.active() then return false end
  local state = read_state(preview.state)
  return state and state.status == "visible" and not (state.warning or ""):match("split mode unavailable") or false
end

function M.send(action)
  if not M.active() then return false end
  return publish_command(action)
end

function M.stop()
  preview.generation = preview.generation + 1
  preview.figure_generation = (preview.figure_generation or 0) + 1
  preview.queued_figure = nil
  cleanup_startup_watch()
  if preview.pid then pcall(vim.uv.kill, preview.pid, "sigterm") end
  preview.pid, preview.starting, preview.hidden = nil, false, false
  cleanup_watch()
  cleanup_document_watch()
  remove_keys()
end

return M
