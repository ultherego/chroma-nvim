-- The modules an enabled selection brings up. Its own file rather than three
-- lines in init.lua, which is the one file a test cannot load.

local M = {}

---Sets up every module the enabled components contribute, in name order.
---
---Name order because none of these looks at another. A module that one day
---depends on another belongs in `requires`, and this loop would have to walk
---the graph rather than a sorted list.
---@param opts table|nil passed to each module's setup
---@return string[] names the modules that were set up
function M.setup(opts)
  local names = require("chroma.components").contributions("modules", (require("chroma.state").enabled_ids()))

  for _, name in ipairs(names) do
    require(name).setup(opts)
  end

  return names
end

return M
