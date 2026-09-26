local project = require("draft.project")
local M = {}
local building = false
local build_pending

local function run(draft_dir)
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
        run(next_draft_dir)
      end
    end)
  end)
end

function M.build()
  local draft_dir = project.draft_dir()
  if not draft_dir then
    return
  end

  vim.fn.mkdir(vim.fs.joinpath(draft_dir, ".build"), "p")
  if building then
    build_pending = draft_dir
    return
  end
  run(draft_dir)
end

return M
