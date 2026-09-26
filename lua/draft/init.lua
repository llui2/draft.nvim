local preview = require("draft.preview")
local build = require("draft.build")

return {
  preview = preview.toggle,
  note = function() preview.toggle(true) end,
  stop_preview = preview.stop,
  build = build.build,
}
