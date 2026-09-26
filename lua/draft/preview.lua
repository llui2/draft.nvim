local project = require("draft.project")
local M = {}
local preview = { generation = 0, closing_pid = nil, reopen_after_close = false }
local close_preview, open_preview_window

local function mtime(path)
  local stat = vim.uv.fs_stat(path)
  return stat and stat.mtime.sec * 1000000000 + stat.mtime.nsec or 0
end

local function helper_alive(pid)
  if not pid or not pcall(vim.uv.kill, pid, 0) then
    return false
  end
  local result = vim.system({ "ps", "-p", tostring(pid), "-o", "comm=" }, { text = true }):wait()
  return result.code == 0 and vim.fs.basename(vim.trim(result.stdout or "")) == "draft-preview"
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

local function cleanup_state(path, source, clicked, pid)
  local state = read_state(path)
  if not pid or (state and tonumber(state.pid) == pid) then
    pcall(vim.uv.fs_unlink, path)
    pcall(vim.uv.fs_unlink, source)
    pcall(vim.uv.fs_unlink, source .. ".tmp")
    pcall(vim.uv.fs_unlink, clicked)
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

function M.toggle()
  if preview.starting or (preview.pid and helper_alive(preview.pid)) then
    close_preview()
    return
  end
  if preview.pid then
    preview.pid = nil
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

  local draft_dir = project.draft_dir()
  if not draft_dir then
    return
  end
  local source_name = vim.api.nvim_buf_get_name(0)
  if vim.fs.basename(source_name) ~= "main.tex" or vim.fs.dirname(source_name) ~= draft_dir then
    vim.notify("draft.nvim: open draft/main.tex to preview it", vim.log.levels.ERROR)
    return
  end

  local runtime = vim.api.nvim_get_runtime_file("lua/draft/preview.html", false)[1]
  local window_script = vim.api.nvim_get_runtime_file("lua/draft/window.swift", false)[1]
  if not runtime or not window_script then
    vim.notify("draft.nvim: preview assets are missing", vim.log.levels.ERROR)
    return
  end

  vim.fn.mkdir(vim.fs.joinpath(draft_dir, ".build"), "p")
  preview.html = vim.fs.joinpath(draft_dir, ".build", "preview.html")
  local session = tostring(vim.fn.getpid())
  preview.source = vim.fs.joinpath(draft_dir, ".build", "preview-source-" .. session .. ".json")
  preview.state = vim.fs.joinpath(draft_dir, ".build", "preview-state-" .. session .. ".json")
  preview.clicked = vim.fs.joinpath(draft_dir, ".build", "preview-click-" .. session .. ".json")
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
  cleanup_state(preview.state, preview.source, preview.clicked)

  local copied, err = vim.uv.fs_copyfile(runtime, preview.html)
  if not copied then
    vim.notify("draft.nvim: could not prepare preview page: " .. err, vim.log.levels.ERROR)
    return
  end
  if not watch_preview(vim.api.nvim_get_current_buf()) then
    cleanup_watch()
    cleanup_state(preview.state, preview.source, preview.clicked)
    return
  end
  local helper_dir = vim.fs.joinpath(vim.fn.stdpath("cache"), "draft.nvim")
  vim.fn.mkdir(helper_dir, "p")
  open_preview_window(vim.fs.joinpath(helper_dir, "draft-preview"), preview.html, preview.source, preview.state, preview.clicked, preview.server, vim.v.progpath, window_script)
end

close_preview = function()
  preview.generation = preview.generation + 1
  local pid = preview.pid
  if pid and helper_alive(pid) then
    preview.closing_pid = pid
    pcall(vim.uv.kill, pid, "sigterm")
  elseif not pid then
    cleanup_state(preview.state, preview.source, preview.clicked)
  end
  preview.pid, preview.starting = nil, false
  cleanup_watch()
  vim.notify("draft.nvim: preview closed")
end

open_preview_window = function(binary, html, source, state, clicked, server, nvim, window_script)
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

    process = vim.system({ binary, html, source, state, clicked, server, nvim, tostring(vim.fn.getpid()) }, { detach = true, text = true }, function(result)
      vim.schedule(function()
        local current = preview.pid == process.pid
        cleanup_state(state, source, clicked, process.pid)
        if current then
          preview.pid = nil
          preview.starting = false
          cleanup_watch()
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
    preview.starting = false
    local deadline = vim.uv.hrtime() + 5000000000
    local function check_startup()
      if preview.pid ~= process.pid or notified then
        return
      end
      local helper_state = read_state(state)
      if helper_state and tonumber(helper_state.pid) == process.pid then
        if helper_state.status == "visible" then
          notified = true
          opened = true
          if helper_state.warning then
            vim.notify("draft.nvim: preview opened; " .. helper_state.warning, vim.log.levels.WARN)
          else
            vim.notify("draft.nvim: preview opened")
          end
          return
        elseif helper_state.status == "failed" then
          fail(helper_state.error or "the helper could not show its window")
          return
        end
      end
      if not helper_alive(process.pid) then
        fail("helper process exited before the Draft window became visible")
        return
      end
      if vim.uv.hrtime() >= deadline then
        preview.closing_pid = process.pid
        pcall(vim.uv.kill, process.pid, "sigterm")
        fail("timed out waiting for the Draft window to become visible")
        return
      end
      vim.defer_fn(check_startup, 100)
    end
    vim.defer_fn(check_startup, 50)
  end

  if vim.fn.executable(binary) == 1 and mtime(binary) >= mtime(window_script) then
    open()
    return
  end

  preview.starting = true
  preview.generation = preview.generation + 1
  local generation = preview.generation
  vim.system({ "swiftc", "-O", window_script, "-o", binary }, { text = true }, function(result)
    vim.schedule(function()
      if generation ~= preview.generation then
        return
      end
      preview.starting = false
      if result.code ~= 0 then
        cleanup_watch()
        cleanup_state(state, source, clicked)
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
            cleanup_state(state, source, clicked)
            vim.notify("draft.nvim: could not sign preview helper\n" .. (signature.stderr or signature.stdout), vim.log.levels.ERROR)
            return
          end
          open()
        end)
      end)
    end)
  end)
end

function M.stop()
  if preview.pid or preview.starting then
    close_preview()
  end
end

return M
