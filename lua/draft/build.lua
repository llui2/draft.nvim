local project = require("draft.project")
local M = {}
local building = false
local build_pending

local function run(draft_dir, automatic)
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
          vim.notify("Draft: could not copy PDF: " .. err, vim.log.levels.ERROR)
        elseif not automatic then
          vim.notify("Draft: PDF generated")
        end
      else
        local output = (result.stderr and result.stderr ~= "") and result.stderr or result.stdout or ""
        local detail = output:match("! [^\n]+") or output:match("main%.tex:%d+:[^\n]+") or "latexmk failed"
        vim.notify("Draft: PDF build failed: " .. detail, vim.log.levels.ERROR)
      end

      building = false
      if build_pending then
        local next_draft_dir = build_pending
        build_pending = false
        run(next_draft_dir.dir, next_draft_dir.automatic)
      end
    end)
  end)
end

function M.build(automatic, path)
  local draft_dir = project.draft_dir(path)
  if not draft_dir then
    return
  end

  vim.fn.mkdir(vim.fs.joinpath(draft_dir, ".build"), "p")
  if building then
    build_pending = { dir = draft_dir, automatic = automatic }
    return
  end
  run(draft_dir, automatic)
end

return M
