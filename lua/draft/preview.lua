local project = require("draft.project")
local M = {}
local preview = { generation = 0, closing_pid = nil, reopen_after_close = false }
local close_preview, open_preview_window

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
  local result = vim.fn.writefile({ vim.json.encode(text) }, temporary)
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

local function watch_preview(buffer)
  cleanup_watch()
  local function update()
    if vim.api.nvim_buf_is_valid(buffer) then
      return write_source(table.concat(vim.api.nvim_buf_get_lines(buffer, 0, -1, false), "\n"))
    end
    return false
  end

  preview.group = vim.api.nvim_create_augroup("DraftPreview", { clear = true })
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = preview.group,
    buffer = buffer,
    callback = function()
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

function M.toggle(note)
  if preview.starting then
    close_preview()
    return
  end
  if preview.pid and helper_alive(preview.pid) then
    if preview.hidden then
      preview.hidden = false
      install_keys(preview.buffer)
      write_source(table.concat(vim.api.nvim_buf_get_lines(preview.buffer, 0, -1, false), "\n"))
      pcall(vim.uv.kill, preview.pid, "sigusr2")
    else
      close_preview()
    end
    return
  end
  if preview.pid then
    preview.pid = nil
    preview.hidden = false
    cleanup_watch()
  end
  if preview.closing_pid then
    if helper_alive(preview.closing_pid) then
      preview.reopen_after_close = true
      return
    end
    preview.closing_pid = nil
    preview.reopen_after_close = false
  end

  local source_name = vim.api.nvim_buf_get_name(0)
  local draft_dir
  if note then
    if source_name == "" or not source_name:match("%.tex$") then
      vim.notify("draft.nvim: open a .tex note first", vim.log.levels.ERROR)
      return
    end
  else
    draft_dir = project.draft_dir()
    if not draft_dir then return end
    if vim.fs.basename(source_name) ~= "main.tex" or vim.fs.dirname(source_name) ~= draft_dir then
      vim.notify("draft.nvim: open draft/main.tex to preview it", vim.log.levels.ERROR)
      return
    end
  end

  local runtime = vim.api.nvim_get_runtime_file("lua/draft/preview.html", false)[1]
  local window_script = vim.api.nvim_get_runtime_file("lua/draft/window.swift", false)[1]
  if not runtime or not window_script then
    vim.notify("draft.nvim: preview assets are missing", vim.log.levels.ERROR)
    return
  end

  local state_dir = note and vim.fs.joinpath(vim.fn.stdpath("cache"), "draft.nvim")
    or vim.fs.joinpath(draft_dir, ".build")
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
    if preview.pid then pcall(vim.uv.kill, preview.pid, "sigterm") end
    preview.pid, preview.starting, preview.hidden = nil, false, false
    cleanup_startup_watch()
    cleanup_watch()
    remove_keys()
    cleanup_state(preview.state, preview.source)
    vim.notify("draft.nvim: preview closed")
    return
  end
  local pid = preview.pid
  if pid and helper_alive(pid) then
    preview.hidden = true
    pcall(vim.uv.kill, pid, "sigusr1")
  elseif not pid then
    cleanup_state(preview.state, preview.source)
  end
  preview.starting = false
  remove_keys()
  if not pid then cleanup_watch() end
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
      preview.starting = false
      if result.code ~= 0 then
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
          preview.starting = false
          if signature.code ~= 0 then
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
  local temporary = preview.command .. ".tmp"
  if vim.fn.writefile({ vim.json.encode({ action = action, nonce = vim.uv.hrtime() }) }, temporary) ~= 0 then return false end
  local renamed = vim.uv.fs_rename(temporary, preview.command)
  if not renamed then pcall(vim.uv.fs_unlink, temporary) end
  return renamed ~= nil
end

function M.stop()
  preview.generation = preview.generation + 1
  cleanup_startup_watch()
  if preview.pid then pcall(vim.uv.kill, preview.pid, "sigterm") end
  preview.pid, preview.starting, preview.hidden = nil, false, false
  cleanup_watch()
  remove_keys()
end

return M
