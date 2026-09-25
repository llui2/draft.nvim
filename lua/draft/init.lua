local M = {}

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

function M.preview()
  if not get_draft_dir() then
    return
  end
  vim.notify("draft.nvim: live preview is not implemented yet; use :DraftBuild for the PDF")
end

function M.build()
  local draft_dir = get_draft_dir()
  if not draft_dir then
    return
  end

  vim.fn.mkdir(vim.fs.joinpath(draft_dir, ".build"), "p")
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
      if result.code ~= 0 then
        vim.notify("draft.nvim: latexmk failed\n" .. (result.stderr or result.stdout), vim.log.levels.ERROR)
        return
      end

      local built_pdf = vim.fs.joinpath(draft_dir, ".build", "main.pdf")
      local final_pdf = vim.fs.joinpath(draft_dir, "main.pdf")
      local copied, err = vim.uv.fs_copyfile(built_pdf, final_pdf)
      if not copied then
        vim.notify("draft.nvim: could not copy PDF: " .. err, vim.log.levels.ERROR)
        return
      end
      vim.notify("draft.nvim: built " .. final_pdf)
    end)
  end)

  vim.notify("draft.nvim: building PDF in the background")
end

return M
