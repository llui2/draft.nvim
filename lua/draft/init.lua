local preview = require("draft.preview")
local build = require("draft.build")

return {
  preview = preview.toggle,
  stop_preview = preview.stop,
  build = build.build,
  sync = function(selection)
    if preview.active() then
      if selection then require("draft.sync").capture_visual() end
      preview.send("sync-source")
    else
      vim.notify("draft.nvim: no active preview", vim.log.levels.WARN)
    end
  end,
  focus = function()
    if preview.active() then preview.send("focus-preview") else vim.notify("draft.nvim: no active preview", vim.log.levels.WARN) end
  end,
  focus_source = function()
    if preview.active() then preview.send("focus-source") else vim.notify("draft.nvim: no active preview", vim.log.levels.WARN) end
  end,
  active = preview.active,
  paired = preview.paired,
}
