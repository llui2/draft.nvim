local M = {}
local preview = { pid = nil, starting = false, generation = 0, buffer = nil, timer = nil, html = nil, binary = nil, state = nil, closing_pid = nil }
local building = false
local build_pending
local close_preview, watch_preview, open_preview_window

local function project_draft_dir()
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
end

local function get_draft_dir()
  local draft_dir = project_draft_dir()
  if not draft_dir then
    vim.notify("draft.nvim: could not find draft/main.tex", vim.log.levels.ERROR)
  end
  return draft_dir
end

local function mtime(path)
  local stat = vim.uv.fs_stat(path)
  if not stat then
    return 0
  end
  return stat.mtime.sec * 1000000000 + stat.mtime.nsec
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
  if ok and type(state) == "table" then
    return state
  end
end

local function clear_stale_state(path)
  local state = read_state(path)
  if state and helper_alive(tonumber(state.pid)) then
    return state
  end
  if vim.fn.filereadable(path) == 1 then
    vim.uv.fs_unlink(path)
  end
end

function M.preview()
  local draft_dir = get_draft_dir()
  if not draft_dir then
    return
  end

  if (preview.pid and helper_alive(preview.pid)) or preview.starting then
    close_preview()
    return
  end
  preview.pid = nil

  local source = vim.api.nvim_buf_get_name(0)
  if vim.fs.basename(source) ~= "main.tex" or vim.fs.dirname(source) ~= draft_dir then
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
  preview.state = vim.fs.joinpath(draft_dir, ".build", "preview-state.json")
  local prior_state = clear_stale_state(preview.state)
  if prior_state then
    local old_pid = tonumber(prior_state.pid)
    if old_pid and old_pid ~= vim.fn.getpid() then
      pcall(vim.uv.kill, old_pid, "sigterm")
    end
    vim.uv.fs_unlink(preview.state)
  end
  local helper_dir = vim.fs.joinpath(vim.fn.stdpath("cache"), "draft.nvim")
  vim.fn.mkdir(helper_dir, "p")
  preview.binary = vim.fs.joinpath(helper_dir, "draft-preview")
  local buffer = vim.api.nvim_get_current_buf()
  watch_preview(buffer, runtime)

  open_preview_window(preview.binary, preview.html, preview.state, window_script)
end

close_preview = function()
  preview.generation = preview.generation + 1
  if preview.pid and helper_alive(preview.pid) then
    preview.closing_pid = preview.pid
    pcall(vim.uv.kill, preview.pid, "sigterm")
  end
  if preview.state then
    pcall(vim.uv.fs_unlink, preview.state)
  end
  preview.pid, preview.starting = nil, false
  if preview.timer then
    preview.timer:stop()
    preview.timer:close()
    preview.timer = nil
  end
  if preview.buffer then
    vim.api.nvim_del_augroup_by_id(preview.buffer)
    preview.buffer = nil
  end
  vim.notify("draft.nvim: preview closed")
end

watch_preview = function(buffer, runtime)
  local function update()
    if not vim.api.nvim_buf_is_valid(buffer) then
      return
    end
    local text = table.concat(vim.api.nvim_buf_get_lines(buffer, 0, -1, false), "\n")
    local template = table.concat(vim.fn.readfile(runtime), "\n")
    local encoded = vim.json.encode(text):gsub("</", "<\\/")
    local html = template:gsub("__SOURCE__", function()
      return encoded
    end)
    vim.fn.writefile(vim.split(html, "\n", { plain = true }), preview.html)
  end

  preview.buffer = vim.api.nvim_create_augroup("DraftPreview", { clear = true })
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = preview.buffer,
    buffer = buffer,
    callback = function()
      if not preview.timer then
        preview.timer = vim.uv.new_timer()
      end
      preview.timer:stop()
      preview.timer:start(100, 0, vim.schedule_wrap(update))
    end,
  })
  update()
end

open_preview_window = function(binary, html, state, window_script)
  local function open()
    vim.uv.fs_unlink(state)
    preview.starting = true
    local notified = false
    local process
    local function fail(message)
      if notified then
        return
      end
      notified = true
      preview.starting = false
      vim.notify("draft.nvim: preview helper failed\n" .. message, vim.log.levels.ERROR)
    end
    process = vim.system({ binary, html, state, tostring(vim.fn.getpid()) }, { detach = true, text = true }, function(result)
      vim.schedule(function()
        local helper_state = read_state(state)
        if helper_state and tonumber(helper_state.pid) == process.pid then
          pcall(vim.uv.fs_unlink, state)
        end
        if preview.pid == process.pid then
          preview.pid = nil
          preview.starting = false
        end
        local intentional = preview.closing_pid == process.pid
        if intentional then
          preview.closing_pid = nil
        end
        if not intentional and result.code ~= 0 then
          local detail = (result.stderr and result.stderr ~= "" and result.stderr)
            or (result.stdout and result.stdout ~= "" and result.stdout)
            or ("helper exited with status " .. tostring(result.code))
          fail(detail)
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
          vim.notify("draft.nvim: preview opened")
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
            vim.notify("draft.nvim: could not sign preview helper\n" .. (signature.stderr or signature.stdout), vim.log.levels.ERROR)
            return
          end
          open()
        end)
      end)
    end)
  end)
end

local function run_build(draft_dir)
  building = true
  local command = {
    "latexmk",
    "-pdf",
    "-interaction=nonstopmode",
    "-file-line-error",
    "-outdir=.build",
    "-auxdir=.build",
    "main.tex",
  }

  vim.system(command, { cwd = draft_dir, text = true }, function(result)
    vim.schedule(function()
      if result.code == 0 then
        local built_pdf = vim.fs.joinpath(draft_dir, ".build", "main.pdf")
        local final_pdf = vim.fs.joinpath(draft_dir, "main.pdf")
        local copied, err = vim.uv.fs_copyfile(built_pdf, final_pdf)
        if not copied then
          vim.notify("draft.nvim: could not copy PDF: " .. err, vim.log.levels.ERROR)
        end
      else
        vim.notify("draft.nvim: latexmk failed\n" .. (result.stderr or result.stdout), vim.log.levels.ERROR)
      end

      building = false
      if build_pending then
        local next_draft_dir = build_pending
        build_pending = false
        run_build(next_draft_dir)
      end
    end)
  end)
end

function M.build()
  local draft_dir = get_draft_dir()
  if not draft_dir then
    return
  end

  vim.fn.mkdir(vim.fs.joinpath(draft_dir, ".build"), "p")
  if building then
    build_pending = draft_dir
    return
  end
  run_build(draft_dir)
end

function M.stop_preview()
  if preview.pid or preview.starting then
    close_preview()
  end
end

return M
