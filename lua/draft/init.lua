local preview = require("draft.preview")
local build = require("draft.build")

return {
  preview = preview.toggle,
  stop_preview = preview.stop,
  build = build.build,
}
