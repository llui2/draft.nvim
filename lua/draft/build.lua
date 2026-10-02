local project = require("draft.project")
local M = {}
local building = false
local build_pending = {}

local function failed(detail)
  vim.notify("Draft: build failed\n" .. detail, vim.log.levels.ERROR)
end

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

  local ok, err = pcall(vim.system, command, { cwd = draft_dir, text = true }, function(result)
    vim.schedule(function()
      if result.code == 0 then
        local built_pdf = vim.fs.joinpath(draft_dir, ".build", "main.pdf")
        local final_pdf = vim.fs.joinpath(draft_dir, "main.pdf")
        local copied, err = vim.uv.fs_copyfile(built_pdf, final_pdf)
        if not copied then
          failed("could not copy PDF: " .. err)
        elseif not automatic then
          vim.notify("Draft: PDF generated")
        end
      else
        local output = (result.stdout or "") .. "\n" .. (result.stderr or "")
        local detail = output:match("main%.tex:%d+:[^\n]+") or output:match("! [^\n]+") or output:sub(-1600)
        failed(detail .. "\nLog: " .. vim.fs.joinpath(draft_dir, ".build", "main.log"))
      end

      building = false
      if #build_pending > 0 then
        local next_draft_dir = table.remove(build_pending, 1)
        run(next_draft_dir.dir, next_draft_dir.automatic)
      end
    end)
  end)
  if not ok then building = false; failed(tostring(err)) end
end

function M.build(automatic, path)
  local draft_dir = project.draft_dir(path)
  if not draft_dir then
    return
  end
  if vim.fn.executable("latexmk") ~= 1 then failed("latexmk is not installed"); return end

  vim.fn.mkdir(vim.fs.joinpath(draft_dir, ".build"), "p")
  if building then
    for _, pending in ipairs(build_pending) do
      if pending.dir == draft_dir then
        pending.automatic = pending.automatic and automatic
        return
      end
    end
    table.insert(build_pending, { dir = draft_dir, automatic = automatic })
    return
  end
  run(draft_dir, automatic)
end

return M
