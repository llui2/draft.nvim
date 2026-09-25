local M = {}
local preview = { pid = nil, starting = false, generation = 0, buffer = nil, timer = nil, html = nil, binary = nil, state = nil }
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

function M.preview()
  local draft_dir = get_draft_dir()
  if not draft_dir then
    return
  end

  if preview.pid or preview.starting then
    close_preview()
    return
  end

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
  local helper_dir = vim.fs.joinpath(vim.fn.stdpath("cache"), "draft.nvim")
  vim.fn.mkdir(helper_dir, "p")
  preview.binary = vim.fs.joinpath(helper_dir, "draft-preview")
  local buffer = vim.api.nvim_get_current_buf()
  watch_preview(buffer, runtime)

  open_preview_window(preview.binary, preview.html, preview.state, window_script)
end

close_preview = function()
  preview.generation = preview.generation + 1
  if preview.binary and preview.state and vim.fn.executable(preview.binary) == 1 then
    local result = vim.system({ preview.binary, "--close", preview.state }):wait()
    if result.code ~= 0 then
      vim.notify("draft.nvim: could not close the preview helper", vim.log.levels.ERROR)
    end
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
    local process
    process = vim.system({ binary, html, state, tostring(vim.fn.getpid()) }, { detach = true }, function()
      vim.schedule(function()
        if preview.pid == process.pid then
          preview.pid = nil
        end
      end)
    end)
    preview.pid = process.pid
    vim.notify("draft.nvim: preview opened")
    vim.defer_fn(function()
      if vim.g.draft_accessibility_notified or vim.fn.filereadable(state) ~= 1 then
        return
      end
      local ok, layout = pcall(vim.json.decode, table.concat(vim.fn.readfile(state), "\n"))
      if ok and layout.status then
        vim.g.draft_accessibility_notified = true
        vim.notify("draft.nvim: " .. layout.status, vim.log.levels.WARN)
      end
    end, 700)
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
